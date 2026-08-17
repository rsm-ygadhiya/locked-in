# /// script
# requires-python = ">=3.10"
# dependencies = [
#   "opencv-python>=4.9",
#   "mss>=9.0",
#   "numpy>=1.26",
#   "sounddevice>=0.4.6",
#   "pyobjc-framework-AVFoundation>=10.0; sys_platform == 'darwin'",
# ]
# ///
"""
recorder.py — screen + camera + microphone recorder for Locked In.

One recorder for both platforms. The macOS (`guided-access.command`) and Windows
(`guided-access.ps1`) lockdowns both start this in the background at the top of a
session and stop it on exit; it writes three files into one session folder:

    <out-dir>/screen.mp4      the whole primary display
    <out-dir>/camera.mp4      the webcam
    <out-dir>/audio.wav       the microphone

With --live-tiles it also keeps two small JPEGs up to date, overwritten in place:

    <out-dir>/live/screen.jpg  newest screen frame, downscaled
    <out-dir>/live/camera.jpg  newest webcam frame, downscaled

That is how proctored sessions feed the faculty dashboard: uploader.py ships those
two files to Supabase every few seconds. The split exists because only one process
can open the webcam, and because an upload stalling on a bad network must not cost
frames of the recording.

Audio is a separate file on purpose — muxing it into the video would mean depending
on ffmpeg, and the whole point of this script is that a student machine needs nothing
but Python. Both video files carry a burnt-in timestamp, and both are written on a
wall-clock lock (slow frames are duplicated rather than dropped), so a 40-minute exam
produces 40 minutes of footage that lines up with the .wav and with the real clock.

Run it:
    uv run recorder.py --out-dir ~/Desktop/LockedIn-Recordings/20260817-120000
uv reads the dependency block above and installs into a cached environment on first
run. With a plain interpreter, install the packages listed above yourself and run:
    python3 recorder.py --out-dir <dir>

Stopping it, in order of preference:
    1. create the file <out-dir>/STOP   (works everywhere, including Windows)
    2. send SIGINT / SIGTERM            (Ctrl+C, or kill -INT)
Either way every file is closed properly. A hard kill loses the tail of the videos.

Permissions on first run:
    macOS   — Screen Recording, Camera, and Microphone for the app that launches this
              (Terminal, for the lockdown), in System Settings > Privacy & Security
    Windows — Camera and Microphone access for desktop apps, in Settings > Privacy
"""

from __future__ import annotations

import argparse
import ctypes
import datetime as dt
import os
import platform
import signal
import sys
import threading
import time
import wave
from pathlib import Path

# Third-party imports are deferred into the workers that need them, so that a missing
# microphone package can't stop the screen from recording.
import numpy as np

STOP = threading.Event()
IS_MAC = platform.system() == "Darwin"
IS_WINDOWS = platform.system() == "Windows"


def log(message: str) -> None:
    """Timestamped line on stdout — the lockdown scripts tee this into the session."""
    print(f"[recorder {dt.datetime.now():%H:%M:%S}] {message}", flush=True)


def stamp_frame(frame, label: str):
    """Burn a wall-clock timestamp into the top-left of a frame (evidence trail)."""
    import cv2

    text = f"{label}  {dt.datetime.now():%Y-%m-%d %H:%M:%S}"
    # Draw the text twice — black underneath, white on top — so it stays readable
    # against both a dark terminal and a white exam page.
    for color, thickness in (((0, 0, 0), 4), ((255, 255, 255), 1)):
        cv2.putText(frame, text, (12, 28), cv2.FONT_HERSHEY_SIMPLEX, 0.6, color,
                    thickness, cv2.LINE_AA)
    return frame


def open_writer(path: Path, fps: float, size: tuple[int, int]):
    """An mp4 writer, or None if OpenCV can't encode here."""
    import cv2

    writer = cv2.VideoWriter(str(path), cv2.VideoWriter_fourcc(*"mp4v"), fps, size)
    if not writer.isOpened():
        log(f"ERROR: could not open {path.name} for writing")
        return None
    return writer


class WallClock:
    """
    Paces a video writer against the real clock.

    A naive capture loop writes one frame per iteration, so if capture can only manage
    7 fps while the file header claims 12, the footage plays back ~1.7x too fast and no
    longer matches the audio or the exam timeline. This hands back how many frames are
    owed at the current instant, so a slow tick duplicates the last frame instead.
    """

    def __init__(self, fps: float):
        self.fps = fps
        self.start = time.perf_counter()
        self.written = 0

    def owed(self) -> int:
        elapsed = time.perf_counter() - self.start
        return max(0, int(elapsed * self.fps) + 1 - self.written)

    def credit(self, frames: int = 1) -> None:
        self.written += frames

    @property
    def seconds(self) -> float:
        return self.written / self.fps if self.fps else 0.0


class LiveTile:
    """
    Publish the newest frame of one stream as a small JPEG, for the uploader.

    Why a file on disk rather than uploading from here: only one process can hold
    the webcam open, so an uploader cannot capture its own tiles — it has to be
    handed them. And the upload must never be in the capture loop's way, because a
    stalled network would then cost frames of the actual exam footage. So the loop
    drops a file and forgets about it; uploader.py picks it up, and if it is
    offline the recording carries on regardless.

    Writes go to a temp name and are then renamed over the target, so a reader
    always sees a complete JPEG rather than a half-written one.
    """

    def __init__(self, out_dir: Path, kind: str, *, interval: float, width: int,
                 enabled: bool):
        self.kind = kind
        self.interval = max(0.5, interval)
        self.width = max(160, width)
        self.enabled = enabled
        self.directory = out_dir / "live"
        self.path = self.directory / f"{kind}.jpg"
        self.temp = self.directory / f".{kind}.jpg.tmp"
        self.due = 0.0
        if self.enabled:
            self.directory.mkdir(parents=True, exist_ok=True)

    def offer(self, frame) -> None:
        """Take this frame if one is due. Cheap and silent when it is not."""
        if not self.enabled:
            return
        now = time.monotonic()
        if now < self.due:
            return
        self.due = now + self.interval
        try:
            import cv2
            height, width = frame.shape[:2]
            scale = min(1.0, self.width / width)
            if scale < 1.0:
                frame = cv2.resize(frame, (int(width * scale), int(height * scale)),
                                   interpolation=cv2.INTER_AREA)
            ok, buffer = cv2.imencode(".jpg", frame,
                                      [int(cv2.IMWRITE_JPEG_QUALITY), 65])
            if not ok:
                return
            self.temp.write_bytes(buffer.tobytes())
            os.replace(self.temp, self.path)
        except Exception as exc:                  # noqa: BLE001 - monitoring is optional
            # Deliberately swallowed: live monitoring is a convenience, and nothing
            # here is worth interrupting a recording for.
            log(f"live[{self.kind}]: {exc}")
            self.enabled = False


def record_screen(out_dir: Path, fps: float, max_width: int,
                  tile: LiveTile | None = None) -> None:
    """Capture the primary display until STOP."""
    import cv2
    import mss

    # mss handles must be created in the thread that uses them.
    with mss.mss() as sct:
        if len(sct.monitors) < 2:
            log("ERROR: no display found for screen capture")
            return
        monitor = sct.monitors[1]   # [0] is the union of all displays; [1] is primary

        first = np.asarray(sct.grab(monitor))
        height, width = first.shape[:2]
        # Retina/4K panels arrive at full physical resolution. Downscaling is what keeps
        # a pure-Python capture loop able to hit its frame rate at all.
        scale = min(1.0, max_width / width)
        size = (int(width * scale) // 2 * 2, int(height * scale) // 2 * 2)
        log(f"screen: {width}x{height} -> {size[0]}x{size[1]} @ {fps:g}fps")

        writer = open_writer(out_dir / "screen.mp4", fps, size)
        if writer is None:
            return

        clock = WallClock(fps)
        try:
            while not STOP.is_set():
                frame = cv2.cvtColor(np.asarray(sct.grab(monitor)), cv2.COLOR_BGRA2BGR)
                if scale != 1.0 or frame.shape[1::-1] != size:
                    frame = cv2.resize(frame, size, interpolation=cv2.INTER_AREA)
                frame = stamp_frame(frame, "SCREEN")

                owed = clock.owed()
                for _ in range(owed):
                    writer.write(frame)
                clock.credit(owed)

                if tile is not None:
                    tile.offer(frame)

                # Yield briefly; the wall clock above absorbs any overshoot.
                STOP.wait(max(0.0, (1.0 / fps) * 0.5))
        finally:
            writer.release()
            log(f"screen: saved {clock.seconds:.0f}s to screen.mp4")


def macos_camera_access() -> str:
    """
    Ask macOS for camera access up front, and report where we stand.

    OpenCV never calls AVCaptureDevice.requestAccess — it just tries to open the device
    — so on a Mac that has never been asked, capture fails silently with no prompt and
    no explanation. Asking explicitly is what makes the permission dialog appear.
    """
    if not IS_MAC:
        return "n/a"
    try:
        import AVFoundation as AVF
    except ImportError:
        return "unknown (pyobjc not installed)"

    labels = {0: "not yet asked", 1: "restricted", 2: "denied", 3: "authorized"}
    status = AVF.AVCaptureDevice.authorizationStatusForMediaType_(AVF.AVMediaTypeVideo)

    if status == 0:
        granted = threading.Event()
        answer = {"ok": False}

        def completion(ok):
            answer["ok"] = bool(ok)
            granted.set()

        AVF.AVCaptureDevice.requestAccessForMediaType_completionHandler_(
            AVF.AVMediaTypeVideo, completion)
        log("camera: waiting for you to allow camera access...")
        granted.wait(120)
        return "authorized" if answer["ok"] else "denied"

    return labels.get(status, "unknown")


def camera_devices() -> list[str]:
    """Device names as AVFoundation sees them, for diagnostics on macOS."""
    if not IS_MAC:
        return []
    try:
        import AVFoundation as AVF
        return [d.localizedName()
                for d in AVF.AVCaptureDevice.devicesWithMediaType_(AVF.AVMediaTypeVideo)]
    except Exception:                             # noqa: BLE001 - diagnostics only
        return []


def open_camera(preferred: int):
    """
    Find a camera that actually delivers frames.

    isOpened() is not good enough: a device can report itself open and then never
    produce a single frame — index 0 under the AVFoundation backend does exactly that
    on some Macs while index 1 works, and OpenCV's own device enumeration is unreliable
    there. So every combination is judged on whether a real frame arrives.
    """
    import cv2

    if IS_WINDOWS:
        # DirectShow first: markedly more reliable than MSMF for plain webcams.
        backends = [(cv2.CAP_DSHOW, "DSHOW"), (cv2.CAP_MSMF, "MSMF")]
    elif IS_MAC:
        backends = [(cv2.CAP_AVFOUNDATION, "AVFOUNDATION")]
    else:
        backends = [(cv2.CAP_V4L2, "V4L2")]
    backends.append((cv2.CAP_ANY, "ANY"))

    # The requested index is tried first, on every backend, before scanning the others.
    indices = [preferred] + [i for i in range(4) if i != preferred]

    for backend, backend_name in backends:
        for index in indices:
            camera = cv2.VideoCapture(index, backend)
            if not camera.isOpened():
                camera.release()
                continue
            camera.set(cv2.CAP_PROP_FRAME_WIDTH, 1280)
            camera.set(cv2.CAP_PROP_FRAME_HEIGHT, 720)
            # Cameras routinely need a moment to warm up before the first good frame.
            for _ in range(10):
                ok, frame = camera.read()
                if ok and frame is not None:
                    log(f"camera: {backend_name} index {index}")
                    return camera, frame
                time.sleep(0.2)
            log(f"camera: {backend_name} index {index} opened but sent no frames — "
                "trying the next one")
            camera.release()

    return None, None


def record_camera(out_dir: Path, fps: float, index: int,
                  tile: LiveTile | None = None) -> None:
    """Capture the webcam until STOP."""
    import cv2

    access = macos_camera_access()
    if access in ("denied", "restricted"):
        log(f"ERROR: camera access {access}. On macOS, grant Camera access to the app "
            "running this (Terminal, for the lockdown) in System Settings > Privacy & "
            "Security > Camera, then run it again.")
        return

    camera, first = open_camera(index)
    if camera is None:
        devices = camera_devices()
        seen = f" AVFoundation sees: {', '.join(devices)}." if devices else ""
        log(f"ERROR: no camera delivered any frames (tried indices 0-3 on every "
            f"backend; access={access}).{seen} Is another app using the camera?")
        return

    size = (first.shape[1] // 2 * 2, first.shape[0] // 2 * 2)
    log(f"camera: {size[0]}x{size[1]} @ {fps:g}fps")

    writer = open_writer(out_dir / "camera.mp4", fps, size)
    if writer is None:
        camera.release()
        return

    clock = WallClock(fps)
    last = cv2.resize(first, size) if first.shape[1::-1] != size else first
    try:
        while not STOP.is_set():
            ok, frame = camera.read()
            if ok and frame is not None:
                last = cv2.resize(frame, size) if frame.shape[1::-1] != size else frame
            # A dropped read reuses the previous frame: a camera that stalls for a
            # moment must not shorten the recording relative to the wall clock.
            stamped = stamp_frame(last.copy(), "CAMERA")

            owed = clock.owed()
            for _ in range(owed):
                writer.write(stamped)
            clock.credit(owed)

            if tile is not None:
                tile.offer(stamped)

            STOP.wait(max(0.0, (1.0 / fps) * 0.5))
    finally:
        writer.release()
        camera.release()
        log(f"camera: saved {clock.seconds:.0f}s to camera.mp4")


def record_audio(out_dir: Path, rate: int) -> None:
    """Capture the default microphone to a 16-bit mono WAV until STOP."""
    import sounddevice as sd

    path = out_dir / "audio.wav"
    wav = wave.open(str(path), "wb")
    wav.setnchannels(1)
    wav.setsampwidth(2)          # int16
    wav.setframerate(rate)

    frames_written = 0

    def on_audio(indata, frame_count, time_info, status):
        nonlocal frames_written
        if status:
            log(f"audio: {status}")
        wav.writeframes(bytes(indata))
        frames_written += frame_count

    try:
        with sd.InputStream(samplerate=rate, channels=1, dtype="int16",
                            callback=on_audio):
            log(f"audio: recording at {rate}Hz mono")
            while not STOP.is_set():
                STOP.wait(0.2)
    except Exception as exc:                      # noqa: BLE001 - mic is best-effort
        log(f"ERROR: microphone unavailable ({exc}) — continuing without audio")
    finally:
        wav.close()
        log(f"audio: saved {frames_written / rate:.0f}s to audio.wav")


def watch_stop_file(path: Path) -> None:
    """
    Poll for a sentinel file and stop when it appears.

    PowerShell has no clean way to raise SIGINT in another process, so on Windows this
    is the graceful shutdown path; on macOS it is a belt-and-braces second route
    alongside the signal handlers.
    """
    while not STOP.is_set():
        if path.exists():
            log("stop file seen — finalizing")
            STOP.set()
            return
        STOP.wait(0.25)


def keep_display_awake() -> None:
    """
    Stop the machine sleeping mid-exam, which would end the recording early.

    macOS gets this from `caffeinate` in the lockdown script; here it covers Windows
    via SetThreadExecutionState.
    """
    if not IS_WINDOWS:
        return
    ES_CONTINUOUS = 0x80000000
    ES_SYSTEM_REQUIRED = 0x00000001
    ES_DISPLAY_REQUIRED = 0x00000002
    try:
        ctypes.windll.kernel32.SetThreadExecutionState(
            ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED)
    except Exception as exc:                      # noqa: BLE001
        log(f"could not block sleep ({exc})")


def main() -> int:
    parser = argparse.ArgumentParser(description="Locked In session recorder")
    parser.add_argument("--out-dir", required=True,
                       help="session folder; screen.mp4 / camera.mp4 / audio.wav land here")
    parser.add_argument("--no-screen", action="store_true", help="skip screen capture")
    parser.add_argument("--no-camera", action="store_true", help="skip webcam capture")
    parser.add_argument("--no-audio", action="store_true", help="skip the microphone")
    parser.add_argument("--screen-fps", type=float, default=10.0,
                       help="screen frame rate (default 10; higher costs real CPU)")
    parser.add_argument("--camera-fps", type=float, default=15.0,
                       help="webcam frame rate (default 15)")
    parser.add_argument("--max-width", type=int, default=1600,
                       help="downscale the screen past this width (default 1600)")
    parser.add_argument("--camera-index", type=int, default=0,
                       help="which camera to use (default 0)")
    parser.add_argument("--audio-rate", type=int, default=44100,
                       help="microphone sample rate (default 44100)")
    parser.add_argument("--live-tiles", action="store_true",
                       help="also drop small JPEGs in <out-dir>/live for uploader.py")
    parser.add_argument("--live-interval", type=float, default=3.0,
                       help="seconds between live tiles (default 3)")
    parser.add_argument("--live-width", type=int, default=640,
                       help="live tile width in pixels (default 640)")
    args = parser.parse_args()

    out_dir = Path(args.out_dir).expanduser()
    out_dir.mkdir(parents=True, exist_ok=True)
    stop_file = out_dir / "STOP"
    # A stale sentinel from a previous session would stop this one instantly.
    stop_file.unlink(missing_ok=True)

    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda *_: (log("signal received — finalizing"), STOP.set()))

    keep_display_awake()
    log(f"session folder: {out_dir}")

    workers: list[threading.Thread] = [
        threading.Thread(target=watch_stop_file, args=(stop_file,), daemon=True)
    ]
    def tile(kind: str) -> LiveTile:
        return LiveTile(out_dir, kind, interval=args.live_interval,
                        width=args.live_width, enabled=args.live_tiles)

    if not args.no_screen:
        workers.append(threading.Thread(
            target=record_screen,
            args=(out_dir, args.screen_fps, args.max_width, tile("screen"))))
    if not args.no_camera:
        workers.append(threading.Thread(
            target=record_camera,
            args=(out_dir, args.camera_fps, args.camera_index, tile("camera"))))
    if not args.no_audio:
        workers.append(threading.Thread(
            target=record_audio, args=(out_dir, args.audio_rate)))

    if len(workers) == 1:
        log("nothing to record — all three streams were disabled")
        return 2

    for worker in workers:
        worker.start()
    # Threads own the capture loops; the main thread only waits, so that a Ctrl+C is
    # handled here and every writer gets closed on the way out.
    try:
        while any(w.is_alive() for w in workers[1:]) and not STOP.is_set():
            time.sleep(0.2)
    except KeyboardInterrupt:
        STOP.set()
    STOP.set()
    for worker in workers[1:]:
        worker.join(timeout=15)

    stop_file.unlink(missing_ok=True)
    written = sorted(p.name for p in out_dir.iterdir() if p.is_file())
    log(f"done — wrote: {', '.join(written) if written else 'nothing'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
