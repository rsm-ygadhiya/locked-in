# Locked In 🔒

A cross-platform, single-site study lockdown with session recording, and an optional
proctoring mode. It pins Chrome full-screen to one allowed URL, blocks everything else,
records the screen / webcam / microphone, and won't let you out without a passcode.

It runs in either of two modes:

- **Standalone** (the default, and what it has always been): no accounts, no server,
  nothing leaves the machine. Open it, pick Student, and the lockdown starts.
- **Proctored** ([set it up](docs/SETUP.md)): students sign in, photograph their
  student ID, and wait for a proctor to admit them; the proctor watches a live grid
  of every screen and webcam from a web dashboard. Filling in a Supabase project in
  the exam settings is what switches this on.

> **This is a focus and monitoring tool, not a secure exam browser.** Force Quit, Task
> Manager, a reboot, or a second device all defeat the lockdown. For a graded exam,
> read [before you deploy this](docs/BEFORE-YOU-DEPLOY.md) and [known
> problems](docs/TROUBLESHOOTING.md#known-problems) — and use an official proctoring
> tool (Respondus / Proctorio / Honorlock) if you need real integrity guarantees.

![platform](https://img.shields.io/badge/macOS-tested-brightgreen)
![platform](https://img.shields.io/badge/Windows-written%2C%20not%20tested-orange)

> **Tested on macOS only.** The Windows half is written to do the same things, from the
> same settings file and the same Python helpers, but has never been run on a real
> Windows machine — a starting point, not a shipped feature. [What to expect on
> Windows](docs/TROUBLESHOOTING.md#on-windows).

---

## Try it

This repo is published as a working demo, pointed at a throwaway Supabase project that
holds nobody's data. Everything you need to run a whole exam is here, credentials
included:

| | |
| --- | --- |
| Proctor dashboard | `admin` / `admin123` |
| Student | `student` / `student123` |
| Unlock passcode (ends a locked session) | `admin`, on a fresh install |

```bash
uv run --script server/serve.py                              # the proctor's dashboard
uv run --script src/lockedin_config.py enroll http://127.0.0.1:8765   # then this machine
```

The first line prints an address you can open from any device on your wi-fi. The second
points this machine at the same project, which a fresh clone needs before the student
side does anything but a standalone lockdown.

Or skip the server: the dashboard for this demo project is already hosted at
**<https://temporary-sonic-summit-p4o8yaj.vercel.app/>**.

**[docs/DEMO.md](docs/DEMO.md)** walks through it: look at the proctor's side without
changing anything, then sit a real exam on the same machine and watch yourself appear on
the grid. Ten minutes.

Those credentials are public, which is the whole reason **this project must never run a
real exam**. Stand up your own ([docs/SETUP.md](docs/SETUP.md)) for anything that
involves an actual student.

---

## What it does

| | |
|---|---|
| **Recording notice first** | The session is described up front; declining changes nothing on the machine |
| **Records the session** | Screen, webcam and microphone, to one dated folder per session |
| **Single site** | Chrome opens in kiosk/full-screen at one allowed URL |
| **Everything else blocked** | Chrome managed policy blocklists `*`, allowlists only your hosts |
| **No escape hatches** | Incognito disabled, DevTools disabled |
| **Other apps killed** | Non-system apps are quit; you're snapped back to Chrome |
| **Can't quit** | Closing Chrome relaunches it and demands the passcode — the prompt keeps returning |
| **No plaintext passcode** | The passcode is stored as a PBKDF2-SHA256 hash, set in the exam settings |
| **Always cleans up** | Recordings finalized, policy removed, Chrome unlocked on exit — even on Ctrl+C or crash |

And in proctored mode:

| | |
|---|---|
| **Approval gate** | The lockdown cannot start until a proctor admits the student — checked before anything on the machine is touched |
| **Identity check** | The student photographs their ID and takes a check-in photo; the proctor sees both side by side |
| **Live grid** | Newest screen and webcam thumbnail per student, refreshed every few seconds |
| **Stale detection** | A student whose app stops checking in turns red rather than showing a frozen image |
| **Event timeline** | Per-student log of check-in, start, blocked sites and exit |
| **Students can't self-admit** | Enforced by a database trigger, not by the app asking nicely |
| **Per-exam exit code** | A code only proctors know ends the lockdown; checked server-side, so it never reaches the student's machine — and you can look it up again behind **Show code** |
| **Exams you can manage** | Add and delete exams from the dashboard, with both codes on the row and only your own exams listed |
| **Recording is per exam** | Screen, webcam, microphone, live tiles and how often a frame is kept are set on the exam — not on each machine — so the exam decides what it films |
| **Proctors add proctors** | From the dashboard; a student cannot promote themselves |
| **Kept frames** | A snapshot every minute is stored and survives the exam, so there is something to review afterwards rather than only a live grid |
| **Finished list** | Students who ended, with how long they sat, their photos and their kept frames |
| **Floating exit button** | A draggable pill on the student's screen: click, type the exit code, done — no attacking the browser to be offered the door |

---

## Requirements

- **Google Chrome**
- **Python**, via [uv](https://docs.astral.sh/uv/) — needed for the settings, the admin
  panel, and the recorder. uv reads each script's inline dependency block and installs
  what it needs on first run, so there is no virtualenv to create and no
  `requirements.txt` to get wrong:
  ```bash
  # macOS
  curl -LsSf https://astral.sh/uv/install.sh | sh
  # Windows
  winget install --id=astral-sh.uv -e
  ```
  A plain `python3` also works if `opencv-python`, `mss`, `numpy` and `sounddevice` are
  already installed, but uv is much less trouble — and some system Pythons are built
  without Tk, which the admin panel needs.

---

## Running it

### macOS

1. Double-click **`dist/Locked In.app`**.
   First time only: right-click → **Open** → **Open**, to get past Gatekeeper (the app
   is ad-hoc signed, not notarized).
2. Click **Student**.
3. In proctored mode, the check-in window opens here: sign in, type the join code,
   agree to the notice, photograph your ID, take a check-in photo, and wait to be
   admitted. Closing that window exits without touching anything.
   In standalone mode you get the recording notice instead — **Agree and start**, or
   Cancel to exit without touching anything.
4. Terminal opens and runs the lockdown. Enter your Mac admin password when asked —
   it's needed to write the Chrome managed-preferences policy.

First run also prompts for **Automation**, **Accessibility**, **Screen Recording**,
**Camera** and **Microphone** permission in System Settings → Privacy & Security. These
are all requested for **Terminal**, because Terminal is what runs the lockdown — if the
recorder reports that it can't start, that is almost always the missing piece.

To exit: click the floating **End exam** button and enter the exit code — or quit
Chrome (⌘Q), which asks for the same thing.

### Windows

Untested — see the note at the top. What follows is what it is written to do.

1. Keep **`LockedIn.hta`**, **`guided-access.ps1`** and the `.py` files together
   (the `.py` files may sit in the folder above, as they do in this repo).
2. Double-click **`LockedIn.hta`**.
3. Click **Student**. In proctored mode the check-in opens here, exactly as on a Mac;
   in standalone mode you get the recording notice instead.
4. Approve the Administrator (UAC) prompt — needed for the Chrome registry policy.

**Faculty** offers the same two choices as the Mac launcher: the proctor dashboard,
and the exam settings. Both platforms read and write the same settings file format, so
an exam configured on one is configured the same way on the other.

Windows asks for camera and microphone access under Settings → Privacy → Camera /
Microphone; desktop apps must be allowed.

To exit: click the floating **End exam** button, or close Chrome — either asks for the
exit code.

---

## Repo layout

```
src/        the Python helpers both platforms share — recorder, settings, check-in,
            live uploader, Supabase client, settings panel
server/     the proctored backend: schema.sql, the dashboard, serve.py, purge.py, tests
docs/       setup, a demo walkthrough, how it works, known problems, deployment advice
macos/      build.sh, the lockdown script, and the Swift launcher + floating exit button
windows/    the same two things in HTA and PowerShell — written, not tested
dist/       a prebuilt, ad-hoc-signed Locked In.app
```

Each launcher and lockdown script looks for the helpers beside itself first, then in
`src/` one level up, so a flattened copy on a USB stick works as well as a clone does.

---

## Documentation

| | |
|---|---|
| **[docs/DEMO.md](docs/DEMO.md)** | Ten-minute tour for whoever has to approve this. Start here. |
| **[docs/SETUP.md](docs/SETUP.md)** | Standing up your own Supabase project, and running an exam on it. |
| **[docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md)** | The recorder, the settings, the proctored design, hosting the dashboard. |
| **[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)** | Known problems, and symptom-by-symptom fixes. |
| **[docs/BEFORE-YOU-DEPLOY.md](docs/BEFORE-YOU-DEPLOY.md)** | Consent, FERPA, retention — read before a real class. |

---

## Known problems

The full list, with fixes, is in
**[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)**. The ones that decide whether you
should use this at all:

- **Force Quit, Task Manager, a reboot or a phone all defeat the lockdown.** It stops
  casual tab-switching and nothing stronger.
- **Recordings are unencrypted on the student's Desktop**, and nothing collects or
  deletes them. That is your job to define.
- **A recording failure does not stop the exam** — it is logged and the session
  continues, by design.
- **Only macOS has been tested.** The Windows half is written and unproven.
- **Kept frames grow until you delete the exam** — about 500 MB for forty students over
  two hours, against a 1 GB free tier.
- **Not security-reviewed.** The access rules have a [test
  suite](server/tests/README.md); nothing else has had outside eyes.

Before using this for a graded exam, read
**[docs/BEFORE-YOU-DEPLOY.md](docs/BEFORE-YOU-DEPLOY.md)** — consent, FERPA, retention,
and the questions your institution will ask.

---

## Building the macOS app

Needs the Xcode Command Line Tools (`xcode-select --install`):

```bash
./macos/build.sh           # compile + bundle + ad-hoc sign -> dist/Locked In.app
./macos/build.sh --icon    # also regenerate assets/AppIcon.icns from src/mkicon.swift
```

The build copies the three `.py` helpers into the bundle's `Resources/`, so the app is
self-contained. Windows has no build step — the `.hta` and `.ps1` are the shipped
artifacts.

---

## Emergency exit

If you forget the passcode:

- **macOS** — Ctrl+C in the Terminal window, or Force Quit (⌘⌥Esc), or reboot
- **Windows** — close the PowerShell window, or kill it from Task Manager, or reboot

Cleanup runs automatically on exit either way: the recordings are finalized and the
Chrome policy is removed, so Chrome always goes back to normal. A hard kill (Force Quit,
power loss) loses the last few seconds of video rather than the whole file.

If you've lost the passcode as well, delete the settings file and the next run
recreates it with the defaults — including the shipped passcode, `admin`, which the
settings panel then nags you to change.

---

## License

MIT — see [LICENSE](LICENSE).
