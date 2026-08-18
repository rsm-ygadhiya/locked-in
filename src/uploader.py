# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""
uploader.py — ships live tiles and heartbeats to Supabase during a proctored exam.

It is the other half of recorder.py's --live-tiles: the recorder keeps two small
JPEGs up to date on disk, and this process publishes them so the faculty dashboard
can show a live grid.

    <session-dir>/live/screen.jpg  --->  live/<session-id>/screen.jpg
    <session-dir>/live/camera.jpg  --->  live/<session-id>/camera.jpg

Those two are overwritten every few seconds, so they only ever answer "what is on
this screen right now". On a slower cadence it also *keeps* a frame —

    <session-dir>/live/screen.jpg  --->  live/<session-id>/snap/<ms>-screen.jpg

— which is what the proctor reviews after the exam. Kept frames are never
overwritten and live until the exam is deleted, so the interval between them is
the setting that spends the free tier: cloud.snapshot_interval, 60s by default,
0 to keep nothing.

Three reasons it is a separate process rather than threads inside the recorder:

  * only one process can hold the webcam, so this one cannot capture its own frames
  * a stalled upload must never cost frames of the actual exam recording
  * if the network dies, this can die with it and the recording continues intact

It also owns two things beyond the images: a heartbeat, so the dashboard can tell a
student whose laptop went to sleep from one who is sitting there working, and the
final status flip to 'ended' when the session stops.

Run it (the lockdown does this for you):

    python3 src/uploader.py --session-dir <dir> --session-id <uuid> --token-file <path>

The access token arrives in a file, not on the command line: every process on the
machine can read another process's arguments, and that token is the student's
credential for the whole session. The file is read once and then deleted.

Stopping it: create <session-dir>/STOP, or send SIGINT/SIGTERM. It is the same
STOP file the recorder watches, so both stop together.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import signal
import sys
import threading
import time
from pathlib import Path

import lockedin_cloud

STOP = threading.Event()
POLL = 0.5              # how often the loop wakes to check the clock and STOP


def log(message: str) -> None:
    stamp = dt.datetime.now().strftime("%H:%M:%S")
    print(f"[uploader {stamp}] {message}", flush=True)


class Tile:
    """One watched file, uploaded only when its contents actually change."""

    def __init__(self, path: Path, kind: str):
        self.path = path
        self.kind = kind
        self.last_mtime = 0.0
        self.failures = 0
        # The most recent bytes seen, whether or not they were new. A student
        # reading a question sits perfectly still for minutes, and a snapshot run
        # that skipped them would leave exactly the stretch worth reviewing blank.
        self.last_data: bytes | None = None

    def fresh_bytes(self) -> bytes | None:
        """The file's contents if it changed since the last upload, else None."""
        try:
            mtime = self.path.stat().st_mtime
        except OSError:
            return None
        if mtime <= self.last_mtime:
            # Unchanged: re-uploading an identical frame would just burn the free
            # tier's bandwidth to tell the dashboard nothing new.
            return None
        try:
            data = self.path.read_bytes()
        except OSError:
            return None
        if not data:
            return None
        self.last_mtime = mtime
        self.last_data = data
        return data

    def current_bytes(self) -> bytes | None:
        """The newest contents, new or not — for the keep-a-frame pass."""
        fresh = self.fresh_bytes()
        return fresh if fresh is not None else self.last_data


def run(cloud: lockedin_cloud.Cloud, session_id: str, session_dir: Path,
        interval: float, snapshot_interval: float = 0.0) -> int:
    live = session_dir / "live"
    tiles = [Tile(live / "screen.jpg", "screen"), Tile(live / "camera.jpg", "camera")]
    stop_file = session_dir / "STOP"

    log(f"publishing every {interval:g}s for session {session_id}")
    if snapshot_interval > 0:
        log(f"keeping a frame every {snapshot_interval:g}s")
    # approved -> active, so the proctor's grid distinguishes a student who has been
    # let in from one whose lockdown is actually running. The database only permits
    # this exact transition from a student's own credentials.
    try:
        cloud.patch_session(session_id, {
            "status": "active",
            "started_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        })
    except lockedin_cloud.CloudError as error:
        log(f"could not mark the session active: {error}")
    cloud.log_event(session_id, "upload.start", f"watching {live}")

    next_tick = 0.0
    next_snap = 0.0
    sent = kept = snap_failures = 0
    while not STOP.is_set():
        if stop_file.exists():
            log("stop file seen — finishing")
            break

        now = time.monotonic()
        if now >= next_tick:
            next_tick = now + interval
            for tile in tiles:
                data = tile.fresh_bytes()
                if data is None:
                    continue
                try:
                    cloud.put_frame(session_id, tile.kind, data)
                    sent += 1
                    tile.failures = 0
                except lockedin_cloud.CloudError as error:
                    tile.failures += 1
                    # Say it once, then stay quiet: a student on flaky wifi does not
                    # need forty identical lines, and the exam is not affected.
                    if tile.failures in (1, 10, 100):
                        log(f"{tile.kind}: upload failed ({error})")
            cloud.heartbeat(session_id)

        # Kept frames run on their own clock, and deliberately after the live
        # tiles: if the network is only good enough for one of the two, the live
        # grid is the one a proctor is watching right now.
        if snapshot_interval > 0 and now >= next_snap:
            next_snap = now + snapshot_interval
            for tile in tiles:
                data = tile.current_bytes()
                if data is None:
                    continue
                try:
                    cloud.put_snapshot(session_id, tile.kind, data)
                    kept += 1
                except lockedin_cloud.CloudError as error:
                    snap_failures += 1
                    if snap_failures in (1, 10, 100):
                        log(f"{tile.kind}: could not keep a frame ({error})")

        STOP.wait(POLL)

    # Best-effort close-out. If the network is gone, the dashboard will simply see
    # the heartbeat go stale, which reads as "stopped" anyway.
    log(f"sent {sent} frames, kept {kept}; marking the session ended")
    cloud.log_event(session_id, "upload.stop", f"{sent} frames, {kept} kept")
    try:
        cloud.patch_session(session_id, {
            "status": "ended",
            "ended_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        })
    except lockedin_cloud.CloudError as error:
        log(f"could not mark the session ended: {error}")
    return 0


def load_token(path: Path) -> dict:
    """
    Read the credential handed over by student_session.py.

    This used to delete the file straight after reading it. It no longer can: the
    lockdown needs the same token at the very end, to ask the server whether the
    exit code a proctor just typed is correct. The lockdown scrubs it during
    cleanup instead, so it lives exactly as long as the session does.

    Leaving it there is not much of an exposure — it is the student's own token,
    granting the student's own access, on the student's own machine. It cannot
    read the exit code; verify_exit_code only ever answers yes or no.
    """
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise SystemExit(f"uploader: could not read the token file: {error}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Locked In live uploader")
    parser.add_argument("--session-dir", required=True,
                       help="the recorder's session folder (holds live/ and STOP)")
    parser.add_argument("--session-id", required=True,
                       help="the sessions.id row this belongs to")
    parser.add_argument("--token-file", required=True,
                       help="JSON with access_token / refresh_token; the lockdown scrubs it")
    parser.add_argument("--interval", type=float, default=0.0,
                       help="seconds between publishes (default: from the config)")
    parser.add_argument("--snapshot-interval", type=float, default=None,
                       help="seconds between kept frames; 0 keeps none "
                            "(default: from the config)")
    args = parser.parse_args(argv)

    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda *_: (log("signal received"), STOP.set()))

    session_dir = Path(args.session_dir).expanduser()
    if not session_dir.exists():
        log(f"ERROR: no such session folder: {session_dir}")
        return 2

    settings = lockedin_cloud.cloud_settings()
    interval = args.interval or float(settings.get("live_interval") or 3.0)
    snapshot_interval = (args.snapshot_interval if args.snapshot_interval is not None
                         else float(settings.get("snapshot_interval") or 0.0))
    # A snapshot cadence faster than the live one would keep the same frame twice.
    if 0 < snapshot_interval < interval:
        snapshot_interval = interval

    try:
        cloud = lockedin_cloud.Cloud.from_config()
    except lockedin_cloud.NotConfigured as error:
        log(f"ERROR: {error}")
        return 2

    token = load_token(Path(args.token_file).expanduser())
    cloud.session = lockedin_cloud.Session(
        user_id=token.get("user_id", ""),
        access_token=token.get("access_token", ""),
        refresh_token=token.get("refresh_token", ""),
        # Assume it is close to expiry so the first call refreshes if it needs to;
        # an exam outlasts the one-hour token life.
        expires_at=time.time() + float(token.get("expires_in") or 300),
        email=token.get("email", ""),
        role=token.get("role", "student"),
    )
    if not cloud.session.access_token:
        log("ERROR: the token file held no access token")
        return 2

    return run(cloud, args.session_id, session_dir, interval, snapshot_interval)


if __name__ == "__main__":
    sys.exit(main())
