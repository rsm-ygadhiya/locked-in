# /// script
# requires-python = ">=3.10"
# dependencies = [
#   "opencv-python>=4.9",
#   "numpy>=1.26",
#   "pyobjc-framework-AVFoundation>=10.0; sys_platform == 'darwin'",
# ]
# ///
"""
student_session.py — the check-in a student goes through before the lockdown starts.

This is the gate. It runs *before* guided-access.command takes over the machine, and
the lockdown only starts if this exits 0:

    1. sign in            campus ID + password (or register a new account)
    2. join               type the exam's join code
    3. consent            plain language about what is recorded and who sees it
    4. photograph the ID  the physical student card, held up to the webcam
    5. selfie             the person holding it
    6. wait               faculty sees both photos and approves or rejects

On approval it writes two files into the session folder and exits 0:

    handoff.json   what the lockdown needs: session id, the exam's allowed URL
    token.json     the access token uploader.py will use, deleted once read

On rejection, or if the student closes the window, it exits non-zero and the
lockdown never starts. That ordering is the whole point — a student who was not
admitted should not end up in a locked-down browser at all.

Run it directly to check the flow without a lockdown:

    uv run --script src/student_session.py --session-dir /tmp/test-session

Why Tk: it is in the standard library, so the check-in cannot fail because a UI
toolkit did not install on a student's laptop five minutes before an exam. The
webcam preview goes through cv2 -> PNG -> Tk PhotoImage, which avoids a Pillow
dependency for the same reason.

The camera is chosen by what it is, not by index: with an iPhone nearby macOS
offers Continuity Camera too, and it can take index 0, which would film the desk
instead of the student. See recorder.camera_candidates.
"""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import json
import platform
import socket
import sys
import threading
import time
import tkinter as tk
from pathlib import Path
from tkinter import font as tkfont
from typing import Any, Callable

import lockedin_cloud

# The launcher's palette, so the check-in looks like part of the same app.
BG = "#06120b"
PANEL = "#0b1c12"
ACCENT = "#4ade80"
TEXT = "#eafff0"
MUTED = "#7fe0a0"
DANGER = "#f87171"

POLL_SECONDS = 3.0          # how often the approval screen asks the server
# Preview refresh and size. Every frame costs a PNG encode (see to_photo), so this is
# deliberately 15fps at 560px rather than a full-rate viewfinder — it is there to
# help someone line up a card, and CPU spent here is CPU taken from the machine
# that is about to record an exam.
PREVIEW_MS = 66
PREVIEW_WIDTH = 560


def now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def machine_label() -> str:
    """A short description of this computer, for the proctor's record."""
    return f"{socket.gethostname()} ({platform.system()} {platform.release()})"


# ---------------------------------------------------------------------------
# small Tk helpers
# ---------------------------------------------------------------------------

class FlatButton(tk.Frame):
    """
    A button that actually honours the colours it is given.

    tk.Button on macOS ignores bg and fg entirely and draws the system button face,
    so a light-on-dark scheme comes out as near-white text on a near-white button.
    That is not a cosmetic complaint: it made "Cancel" and "I need to create an
    account" genuinely unreadable, because those are the secondary style where the
    text colour is the light one.

    A Frame with a Label inside is drawn by Tk rather than by Aqua, so every colour
    applies on every platform. The API mirrors the part of tk.Button used here:
    configure(text=...), configure(state=...), invoke(), and the geometry methods
    come free from Frame.
    """

    def __init__(self, parent: tk.Misc, text: str, command: Callable[[], None], *,
                 primary: bool = True, **kwargs):
        self.fill = ACCENT if primary else "#13301f"
        self.ink = "#052e16" if primary else TEXT
        self.hover = "#86efac" if primary else "#1b4430"
        self.command = command
        self._state = "normal"

        super().__init__(parent, bg=self.fill, cursor="hand2",
                         highlightthickness=0 if primary else 1,
                         highlightbackground=ACCENT, highlightcolor=ACCENT,
                         **kwargs)
        self.label = tk.Label(self, text=text, bg=self.fill, fg=self.ink,
                              font=("Helvetica", 13, "bold"), padx=22, pady=11,
                              cursor="hand2")
        self.label.pack()

        for widget in (self, self.label):
            widget.bind("<Button-1>", self._clicked)
            widget.bind("<Enter>", self._enter)
            widget.bind("<Leave>", self._leave)

    def _paint(self, colour: str) -> None:
        self.configure(bg=colour)
        self.label.configure(bg=colour)

    def _enter(self, _event=None) -> None:
        if self._state == "normal":
            self._paint(self.hover)

    def _leave(self, _event=None) -> None:
        if self._state == "normal":
            self._paint(self.fill)

    def _clicked(self, _event=None) -> None:
        if self._state == "normal":
            self.command()

    def invoke(self) -> None:
        self._clicked()

    def configure(self, **kwargs):            # type: ignore[override]
        if "text" in kwargs:
            self.label.configure(text=kwargs.pop("text"))
        if "state" in kwargs:
            self._state = kwargs.pop("state")
            disabled = self._state == "disabled"
            self.label.configure(fg="#4b6b58" if disabled else self.ink)
            self._paint("#16241c" if disabled else self.fill)
            cursor = "" if disabled else "hand2"
            super().configure(cursor=cursor)
            self.label.configure(cursor=cursor)
        if kwargs:
            super().configure(**kwargs)
        return None

    config = configure

    def cget(self, key: str):                 # type: ignore[override]
        if key == "text":
            return self.label.cget("text")
        if key == "state":
            return self._state
        return super().cget(key)


def styled_button(parent: tk.Misc, text: str, command: Callable[[], None], *,
                  primary: bool = True, **kwargs) -> FlatButton:
    return FlatButton(parent, text, command, primary=primary, **kwargs)


def label(parent: tk.Misc, text: str, *, size: int = 13, bold: bool = False,
          color: str = TEXT, **kwargs) -> tk.Label:
    return tk.Label(parent, text=text, bg=parent["bg"], fg=color,
                    font=("Helvetica", size, "bold" if bold else "normal"),
                    justify="left", **kwargs)


def entry(parent: tk.Misc, *, show: str = "") -> tk.Entry:
    return tk.Entry(parent, bg="#0f2417", fg=TEXT, insertbackground=ACCENT,
                    relief="flat", bd=0, font=("Helvetica", 14), show=show,
                    highlightthickness=1, highlightbackground="#1d4030",
                    highlightcolor=ACCENT)


def to_photo(frame) -> tk.PhotoImage:
    """
    A BGR OpenCV frame as something Tk can draw, without depending on Pillow.

    PNG, specifically. PhotoImage's `data` option accepts only PNG and GIF — PPM
    works from a *file* but not from base64, which is a trap worth naming: passing
    PPM bytes here raises "data stream does not have a PNG signature" and the
    preview silently never appears.

    PNG costs real time (tens of ms at full size), which is why the callers keep the
    preview small and the refresh modest rather than pushing 25fps.
    """
    import cv2
    ok, buffer = cv2.imencode(".png", frame,
                              [int(cv2.IMWRITE_PNG_COMPRESSION), 1])
    if not ok:
        raise RuntimeError("could not encode the preview frame")
    return tk.PhotoImage(data=base64.b64encode(buffer.tobytes()))


# ---------------------------------------------------------------------------
# the camera, wrapped so the UI never blocks on it
# ---------------------------------------------------------------------------

class Webcam:
    """
    A webcam that opens lazily and is always released.

    The recorder needs this device the moment check-in finishes, and on macOS a
    camera left open by one process simply cannot be opened by the next. So every
    exit path through this UI closes it.
    """

    def __init__(self, index: int = -1):
        self.index = index
        self.capture: Any = None
        self.error: str | None = None

    def open(self) -> bool:
        """
        True once a camera is delivering frames; otherwise self.error says why.

        Everything in here is wrapped, because the caller turns a False into an
        explanation on screen. An exception escaping instead would leave the student
        looking at a half-drawn capture screen with no button and no message, which
        is the worst possible outcome five minutes before an exam.
        """
        if self.capture is not None:
            return True
        try:
            import recorder
        except ImportError as exc:
            self.error = f"recorder.py is missing next to this script ({exc})"
            return False

        try:
            access = recorder.macos_camera_access()
            if access in ("denied", "restricted"):
                self.error = ("Camera access is " + access + ". Grant Camera access "
                              "to Terminal in System Settings > Privacy & Security > "
                              "Camera, then start again.")
                return False

            capture, first = recorder.open_camera(self.index)
        except ImportError as exc:
            # OpenCV missing entirely — a plain python3 rather than uv. Worth its own
            # message, because "no camera" would send someone hunting the wrong fault.
            self.error = (
                f"The camera library is not installed ({exc}).\n\n"
                "Start Locked In with uv, which installs it automatically:\n"
                "    uv run --script src/student_session.py\n\n"
                "Or install it yourself:  pip3 install opencv-python")
            return False
        except Exception as exc:                  # noqa: BLE001 - reported on screen
            self.error = f"The camera could not be opened: {exc}"
            return False

        if capture is None:
            self.error = ("No camera delivered a picture. Close any app that might be "
                          "using it (Zoom, Photo Booth, FaceTime) and try again.")
            return False
        self.capture = capture
        self.latest = first
        return True

    def read(self):
        if self.capture is None:
            return None
        ok, frame = self.capture.read()
        if ok and frame is not None:
            self.latest = frame
        return getattr(self, "latest", None)

    def jpeg(self, frame, width: int = 1024) -> bytes:
        import cv2
        height, source_width = frame.shape[:2]
        scale = min(1.0, width / source_width)
        if scale < 1.0:
            frame = cv2.resize(frame, (int(source_width * scale), int(height * scale)),
                               interpolation=cv2.INTER_AREA)
        ok, buffer = cv2.imencode(".jpg", frame, [int(cv2.IMWRITE_JPEG_QUALITY), 88])
        if not ok:
            raise RuntimeError("could not encode the photo")
        return buffer.tobytes()

    def close(self) -> None:
        if self.capture is not None:
            try:
                self.capture.release()
            except Exception:                      # noqa: BLE001
                pass
            self.capture = None


# ---------------------------------------------------------------------------
# the app
# ---------------------------------------------------------------------------

class CheckIn(tk.Tk):
    def __init__(self, session_dir: Path, camera_index: int):
        super().__init__()
        self.session_dir = session_dir
        self.webcam = Webcam(camera_index)
        self.cloud: lockedin_cloud.Cloud | None = None
        self.exam: dict | None = None
        self.session_row: dict | None = None
        self.photos: dict[str, bytes] = {}
        self.consented = False
        self.result_code = 1            # non-zero unless we reach approval
        self.polling = False

        self.title("Locked In — check in")
        self.configure(bg=BG)
        self.geometry("900x680")
        self.minsize(820, 620)
        self.protocol("WM_DELETE_WINDOW", self.abandon)
        # Tk's default font is small and inconsistent across platforms.
        tkfont.nametofont("TkDefaultFont").configure(family="Helvetica", size=12)

        self.header = tk.Frame(self, bg=BG)
        self.header.pack(fill="x", padx=32, pady=(26, 0))
        label(self.header, "LOCKED IN 🔒", size=22, bold=True, color=TEXT).pack(anchor="w")
        self.step = label(self.header, "", size=12, color=MUTED)
        self.step.pack(anchor="w", pady=(2, 0))

        self.body = tk.Frame(self, bg=BG)
        self.body.pack(fill="both", expand=True, padx=32, pady=20)

        self.status = label(self, "", size=12, color=MUTED, wraplength=820)
        self.status.pack(fill="x", padx=32, pady=(0, 22))

        self.show_signin()

    # ---------- frame plumbing ----------

    def clear(self) -> str:
        for child in self.body.winfo_children():
            child.destroy()
        return ""

    def say(self, message: str, *, bad: bool = False) -> None:
        self.status.configure(text=message, fg=DANGER if bad else MUTED)
        self.update_idletasks()

    def set_step(self, text: str) -> None:
        self.step.configure(text=text)

    def run_async(self, work: Callable[[], Any], done: Callable[[Any, Exception | None], None],
                  busy: str = "working...") -> None:
        """
        Do something slow off the UI thread, then finish on it.

        Every network call in this file goes through here. Tk is not thread safe, so
        the worker touches nothing but its own result and hands back via after().
        """
        self.say(busy)
        holder: dict[str, Any] = {}

        def worker() -> None:
            try:
                holder["value"] = work()
            except Exception as error:            # noqa: BLE001 - reported in the UI
                holder["error"] = error
            self.after(0, lambda: done(holder.get("value"), holder.get("error")))

        threading.Thread(target=worker, daemon=True).start()

    # ---------- 1. sign in ----------

    def show_signin(self) -> None:
        self.clear()
        self.set_step("Step 1 of 5 — sign in")

        try:
            self.cloud = lockedin_cloud.Cloud.from_config()
        except lockedin_cloud.NotConfigured as error:
            self.show_dead_end("Not set up yet", str(error))
            return

        card = tk.Frame(self.body, bg=PANEL, padx=30, pady=28)
        card.pack(fill="x")

        label(card, "Sign in to check in", size=17, bold=True).pack(anchor="w")
        label(card, f"Project: {self.cloud.url}", size=10, color=MUTED).pack(
            anchor="w", pady=(4, 18))

        label(card, "Campus ID or email", size=11, color=MUTED).pack(anchor="w")
        id_entry = entry(card)
        id_entry.pack(fill="x", pady=(4, 14), ipady=7)
        id_entry.focus_set()

        label(card, "Password", size=11, color=MUTED).pack(anchor="w")
        password_entry = entry(card, show="•")
        password_entry.pack(fill="x", pady=(4, 20), ipady=7)

        name_holder = tk.Frame(card, bg=PANEL)
        name_entry = entry(name_holder)
        registering = tk.BooleanVar(value=False)

        def toggle_register() -> None:
            registering.set(not registering.get())
            if registering.get():
                name_holder.pack(fill="x", pady=(0, 20), before=buttons)
                label(name_holder, "Full name (as it appears on your ID)", size=11,
                      color=MUTED).pack(anchor="w")
                name_entry.pack(fill="x", pady=(4, 0), ipady=7)
                register_link.configure(text="I already have an account")
                submit.configure(text="Create account and continue")
            else:
                name_holder.pack_forget()
                for child in name_holder.winfo_children():
                    child.pack_forget()
                register_link.configure(text="I need to create an account")
                submit.configure(text="Sign in")

        def submit_now() -> None:
            identifier = id_entry.get().strip()
            password = password_entry.get()
            if not identifier or not password:
                self.say("Enter your campus ID and password.", bad=True)
                return
            if registering.get() and not name_entry.get().strip():
                self.say("Enter your full name so the proctor can match your ID.",
                         bad=True)
                return

            full_name = name_entry.get().strip()
            creating = registering.get()
            submit.configure(state="disabled")

            def work() -> Any:
                assert self.cloud is not None
                if creating:
                    return self.cloud.sign_up(identifier, password, full_name)
                return self.cloud.sign_in(identifier, password)

            def done(session: Any, error: Exception | None) -> None:
                submit.configure(state="normal")
                if error is not None:
                    self.say(str(error), bad=True)
                    return
                if session.role == "faculty":
                    self.show_dead_end(
                        "That is a faculty account",
                        "Faculty monitor from the web dashboard, not from this "
                        "check-in. Close this window and use the Faculty button on "
                        "the Locked In start screen.")
                    return
                self.say(f"Signed in as {session.full_name or session.email}.")
                self.show_join()

            self.run_async(work, done, "signing in...")

        buttons = tk.Frame(card, bg=PANEL)
        buttons.pack(fill="x")
        submit = styled_button(buttons, "Sign in", submit_now)
        submit.pack(side="left")
        register_link = styled_button(buttons, "I need to create an account",
                                     toggle_register, primary=False)
        register_link.pack(side="left", padx=(12, 0))

        self.bind("<Return>", lambda _event: submit_now())

    # ---------- 2. join the exam ----------

    def show_join(self) -> None:
        self.clear()
        self.set_step("Step 2 of 5 — join the exam")

        card = tk.Frame(self.body, bg=PANEL, padx=30, pady=28)
        card.pack(fill="x")
        label(card, "Enter the join code", size=17, bold=True).pack(anchor="w")
        label(card, "Your proctor will read this out or write it on the board.",
              size=11, color=MUTED).pack(anchor="w", pady=(4, 18))

        code_entry = entry(card)
        code_entry.pack(fill="x", pady=(0, 20), ipady=9)
        code_entry.configure(font=("Helvetica", 20, "bold"))
        code_entry.focus_set()

        def join_now() -> None:
            code = code_entry.get().strip()
            if not code:
                self.say("Enter the join code.", bad=True)
                return

            def work() -> Any:
                assert self.cloud is not None
                exam = self.cloud.exam_by_code(code)
                if exam is None:
                    raise lockedin_cloud.CloudError(
                        "No open exam has that code. Check the spelling, or ask your "
                        "proctor whether the exam has been opened yet.")
                return exam

            def done(exam: Any, error: Exception | None) -> None:
                if error is not None:
                    self.say(str(error), bad=True)
                    return
                self.exam = exam
                self.say(f"Joining: {exam['title']}")
                self.show_consent()

            self.run_async(work, done, "looking up that code...")

        styled_button(card, "Continue", join_now).pack(anchor="w")
        self.bind("<Return>", lambda _event: join_now())

    # ---------- 3. consent ----------

    def show_consent(self) -> None:
        self.clear()
        self.set_step("Step 3 of 5 — what is recorded")
        assert self.exam is not None

        card = tk.Frame(self.body, bg=PANEL, padx=30, pady=26)
        card.pack(fill="both", expand=True)

        label(card, self.exam["title"], size=17, bold=True).pack(anchor="w")
        label(card, f"Allowed site: {self.exam['allowed_url']}", size=11,
              color=MUTED, wraplength=760).pack(anchor="w", pady=(4, 16))

        # Written plainly and specifically on purpose. A consent screen that hides
        # what it is asking for is not consent.
        terms = (
            "While this exam is running, Locked In will:\n\n"
            "  • record your screen, your webcam, and your microphone to this "
            "computer\n"
            "  • send a small picture of your screen and webcam to your proctor "
            "every few seconds\n"
            "  • keep the photo of your student ID and your check-in photo so your "
            "proctor can confirm who is sitting the exam\n"
            "  • note when the lockdown blocks a site or loses focus\n\n"
            "Your proctor for this exam can see all of the above. The full-length "
            "recordings stay on this computer unless you are asked for them.\n\n"
            "The lockdown pins the browser to the one site above and asks for a "
            "passcode before it will let go. It is not a secure exam browser: "
            "Force Quit, Task Manager or a reboot will end it."
        )
        label(card, terms, size=12, wraplength=780, color=TEXT).pack(anchor="w")

        # The wording lives in its own Label rather than in the Checkbutton's text,
        # for the same reason as FlatButton: Aqua ignores fg on a Checkbutton, so the
        # sentence a student is agreeing to can come out unreadable. Clicking the
        # words toggles the box, as people expect.
        agreed = tk.BooleanVar(value=False)
        consent_row = tk.Frame(card, bg=PANEL)
        consent_row.pack(anchor="w", pady=(20, 18), fill="x")
        check = tk.Checkbutton(
            consent_row, variable=agreed, bg=PANEL, selectcolor="#0f2417",
            activebackground=PANEL, highlightthickness=0, bd=0,
        )
        check.pack(side="left")
        consent_text = label(
            consent_row,
            "I have read this and I agree to be recorded and monitored",
            size=12, bold=True)
        consent_text.pack(side="left", padx=(6, 0))
        consent_text.configure(cursor="hand2")
        consent_text.bind("<Button-1>", lambda _e: check.invoke())

        row = tk.Frame(card, bg=PANEL)
        row.pack(fill="x")

        def proceed() -> None:
            if not agreed.get():
                self.say("You have to agree before the exam can start.", bad=True)
                return
            self.consented = True
            self.say("")
            self.show_capture("id")

        styled_button(row, "I agree — continue", proceed).pack(side="left")
        styled_button(row, "Cancel", self.abandon, primary=False).pack(
            side="left", padx=(12, 0))

    # ---------- 4 & 5. the two photos ----------

    def show_capture(self, which: str) -> None:
        """One screen, used twice: 'id' photographs the card, 'selfie' the person."""
        self.clear()
        self.unbind("<Return>")
        is_id = which == "id"
        self.set_step(f"Step {4 if is_id else 5} of 5 — "
                      + ("photograph your student ID" if is_id else "check-in photo"))

        if not self.webcam.open():
            self.show_dead_end("The camera is not available",
                               self.webcam.error or "unknown camera problem")
            return

        instruction = (
            "Hold your student ID up to the camera. Fill the frame with the card and "
            "make sure the name, photo and ID number are readable."
            if is_id else
            "Now a photo of you. Look at the camera, with your face clearly lit and "
            "nothing covering it."
        )
        label(self.body, instruction, size=13, wraplength=800, color=MUTED).pack(
            anchor="w", pady=(0, 14))

        stage = tk.Frame(self.body, bg="#000", padx=2, pady=2)
        stage.pack()
        view = tk.Label(stage, bg="#000")
        view.pack()

        row = tk.Frame(self.body, bg=BG)
        row.pack(fill="x", pady=(18, 0))

        state = {"frozen": None, "running": True, "warned": False}

        def render(frame) -> None:
            """Draw one frame into the preview, scaled and mirrored as appropriate."""
            import cv2
            # Mirror the selfie: an unmirrored view of yourself is disorienting to
            # line your face up in. The ID is left alone so its text stays readable.
            shown = frame if is_id else cv2.flip(frame, 1)
            height, width = shown.shape[:2]
            scale = min(1.0, PREVIEW_WIDTH / width)
            if scale < 1.0:
                shown = cv2.resize(shown, (int(width * scale), int(height * scale)),
                                   interpolation=cv2.INTER_AREA)
            photo = to_photo(shown)
            view.configure(image=photo)
            view.image = photo              # keep a reference or Tk drops it

        def tick() -> None:
            if not state["running"] or state["frozen"] is not None:
                return
            frame = self.webcam.read()
            if frame is not None:
                try:
                    render(frame)
                except Exception as exc:      # noqa: BLE001 - preview is not the job
                    # A preview that cannot draw must not stop someone taking the
                    # photo: the capture path does not depend on it. Say so once.
                    if not state["warned"]:
                        state["warned"] = True
                        self.say(f"The preview cannot be shown ({exc}). You can still "
                                 "take the photo.", bad=True)
            self.after(PREVIEW_MS, tick)

        def capture() -> None:
            frame = self.webcam.read()
            if frame is None:
                self.say("The camera did not return a picture. Try again.", bad=True)
                return
            state["frozen"] = frame.copy()
            try:
                render(frame)
            except Exception:                 # noqa: BLE001 - same as above
                pass
            # Outside the try: the buttons have to swap over even if the still could
            # not be drawn, or the screen becomes a dead end with no way forward.
            take.pack_forget()
            retake.pack(side="left")
            accept.pack(side="left", padx=(12, 0))
            self.say("Happy with it? Use this photo, or retake.")

        def retake_now() -> None:
            state["frozen"] = None
            retake.pack_forget()
            accept.pack_forget()
            take.pack(side="left")
            self.say("")
            tick()

        def accept_now() -> None:
            frame = state["frozen"]
            if frame is None:
                return
            try:
                self.photos[which] = self.webcam.jpeg(frame)
            except RuntimeError as error:
                self.say(str(error), bad=True)
                return
            state["running"] = False
            if is_id:
                self.show_capture("selfie")
            else:
                self.webcam.close()     # the recorder needs the device next
                self.submit()

        take = styled_button(row, "Take the photo", capture)
        take.pack(side="left")
        retake = styled_button(row, "Retake", retake_now, primary=False)
        accept = styled_button(row, "Use this photo", accept_now)
        styled_button(row, "Cancel", self.abandon, primary=False).pack(side="right")

        tick()

    # ---------- submit and wait ----------

    def submit(self) -> None:
        self.clear()
        self.set_step("Waiting for your proctor")
        assert self.cloud is not None and self.exam is not None

        card = tk.Frame(self.body, bg=PANEL, padx=30, pady=28)
        card.pack(fill="x")
        label(card, "Sent to your proctor", size=17, bold=True).pack(anchor="w")
        detail = label(card, "Uploading your photos...", size=12, color=MUTED,
                       wraplength=760)
        detail.pack(anchor="w", pady=(8, 18))
        styled_button(card, "Cancel and quit", self.abandon, primary=False).pack(
            anchor="w")

        def work() -> Any:
            cloud, exam = self.cloud, self.exam
            assert cloud is not None and exam is not None
            # The session row has to exist first: the storage policies authorise an
            # upload by looking up the session named in the object's path.
            row = cloud.open_session(exam["id"], machine_label())
            session_id = row["id"]
            if row.get("status") == "rejected":
                raise lockedin_cloud.CloudError(
                    "Your last attempt at this exam was refused: "
                    + (row.get("reject_reason") or "no reason given")
                    + ". Ask your proctor to reset it before trying again.")

            id_path = cloud.upload("identity", f"{session_id}/id.jpg",
                                   self.photos["id"], "image/jpeg")
            selfie_path = cloud.upload("identity", f"{session_id}/selfie.jpg",
                                       self.photos["selfie"], "image/jpeg")
            cloud.patch_session(session_id, {
                "id_photo_path": id_path,
                "selfie_path": selfie_path,
                "consent_at": now_iso() if self.consented else None,
                "machine": machine_label(),
                "heartbeat_at": now_iso(),
                "status": "pending",
            })
            cloud.log_event(session_id, "checkin.submitted", machine_label())
            return row

        def done(row: Any, error: Exception | None) -> None:
            if error is not None:
                detail.configure(text=str(error), fg=DANGER)
                self.say("Check-in could not be submitted.", bad=True)
                return
            self.session_row = row
            self.show_waiting(row["id"], card, detail)

        self.run_async(work, done, "uploading...")

    def show_waiting(self, session_id: str, card: tk.Frame, detail: tk.Label) -> None:
        assert self.cloud is not None
        detail.configure(
            text="Your proctor is checking your ID now. Keep this window open — the "
                 "exam will start by itself the moment you are approved.",
            fg=MUTED)

        dots = label(card, "waiting", size=12, color=ACCENT)
        dots.pack(anchor="w", pady=(14, 0))
        self.polling = True
        ticks = {"n": 0}

        def poll() -> None:
            if not self.polling:
                return
            ticks["n"] += 1
            dots.configure(text="waiting" + "." * (ticks["n"] % 4))

            def work() -> Any:
                assert self.cloud is not None
                self.cloud.heartbeat(session_id)
                return self.cloud.session_status(session_id)

            def done(status: Any, error: Exception | None) -> None:
                if not self.polling:
                    return
                if error is not None:
                    # Keep waiting through a network blip rather than failing the
                    # student out of an exam they were about to be admitted to.
                    self.say(f"still trying to reach the server ({error})", bad=True)
                    self.after(int(POLL_SECONDS * 1000), poll)
                    return
                state = (status or {}).get("status", "pending")
                if state == "approved":
                    self.polling = False
                    self.approved(session_id)
                    return
                if state == "rejected":
                    self.polling = False
                    reason = (status or {}).get("reject_reason") or "no reason given"
                    self.show_dead_end("Your proctor did not admit you", reason)
                    return
                self.say("")
                self.after(int(POLL_SECONDS * 1000), poll)

            self.run_async(work, done, "")

        poll()

    def approved(self, session_id: str) -> None:
        """Write what the lockdown needs, then close so it can take over."""
        assert self.cloud is not None and self.exam is not None
        session = self.cloud.session
        assert session is not None

        self.session_dir.mkdir(parents=True, exist_ok=True)

        token_file = self.session_dir / "token.json"
        token_file.write_text(json.dumps({
            "user_id": session.user_id,
            "access_token": session.access_token,
            "refresh_token": session.refresh_token,
            "expires_in": max(60, int(session.expires_at - time.time())),
            "email": session.email,
            "role": session.role,
        }), encoding="utf-8")
        try:
            token_file.chmod(0o600)      # a bearer token, however briefly it lives
        except OSError:
            pass

        handoff = self.session_dir / "handoff.json"
        handoff.write_text(json.dumps({
            "session_id": session_id,
            "exam_id": self.exam["id"],
            "exam_title": self.exam["title"],
            "allowed_url": self.exam["allowed_url"],
            "student": session.full_name or session.email,
            "token_file": str(token_file),
            "approved_at": now_iso(),
        }, indent=2), encoding="utf-8")

        self.cloud.log_event(session_id, "checkin.approved", machine_label())
        self.result_code = 0
        self.clear()
        self.set_step("Approved")
        card = tk.Frame(self.body, bg=PANEL, padx=30, pady=28)
        card.pack(fill="x")
        label(card, "You are approved ✅", size=19, bold=True, color=ACCENT).pack(
            anchor="w")
        label(card, "The lockdown starts in a moment. Do not close this window.",
              size=12, color=MUTED).pack(anchor="w", pady=(8, 0))
        # Long enough for the student to read it, short enough not to feel stuck.
        self.after(1600, self.finish)

    # ---------- exits ----------

    def show_dead_end(self, title: str, detail: str) -> None:
        self.polling = False
        self.clear()
        self.set_step("Cannot continue")
        card = tk.Frame(self.body, bg=PANEL, padx=30, pady=28)
        card.pack(fill="x")
        label(card, title, size=18, bold=True, color=DANGER).pack(anchor="w")
        label(card, detail, size=12, color=TEXT, wraplength=760).pack(
            anchor="w", pady=(10, 20))
        styled_button(card, "Close", self.abandon).pack(anchor="w")

    def abandon(self) -> None:
        self.result_code = 1
        self.finish()

    def finish(self) -> None:
        self.polling = False
        self.webcam.close()
        self.quit()
        self.destroy()


# ---------------------------------------------------------------------------

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Locked In student check-in")
    parser.add_argument("--session-dir", required=True,
                       help="folder for handoff.json, token.json and the recordings")
    parser.add_argument("--camera-index", type=int, default=-1,
                       help="which camera to use for the photos; default -1 picks "
                            "the built-in one over an iPhone on Continuity")
    args = parser.parse_args(argv)

    session_dir = Path(args.session_dir).expanduser()
    session_dir.mkdir(parents=True, exist_ok=True)
    # A handoff left over from a previous run must not be mistaken for this one's.
    (session_dir / "handoff.json").unlink(missing_ok=True)

    app = CheckIn(session_dir, args.camera_index)
    app.mainloop()
    return app.result_code


if __name__ == "__main__":
    sys.exit(main())
