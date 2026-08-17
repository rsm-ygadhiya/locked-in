# Locked In 🔒

A cross-platform, single-site study lockdown with session recording, and an optional
proctoring mode. It pins Chrome full-screen to one allowed URL, blocks everything else,
records the screen / webcam / microphone, and won't let you out without a passcode.

It runs in either of two modes:

- **Standalone** (the default, and what it has always been): no accounts, no server,
  nothing leaves the machine. Open it, pick Student, and the lockdown starts.
- **Proctored** ([set it up](cloud/SETUP.md)): students sign in, photograph their
  student ID, and wait for a proctor to admit them; the proctor watches a live grid
  of every screen and webcam from a web dashboard. Filling in a Supabase project in
  the admin panel is what switches this on.

> **This is a focus and monitoring tool, not a secure exam browser.** Force Quit, Task
> Manager, a reboot, or a second device all defeat the lockdown. For a graded exam,
> read [Before you deploy this](#before-you-deploy-this) — and use an official
> proctoring tool (Respondus / Proctorio / Honorlock) if you need real integrity
> guarantees.

![platform](https://img.shields.io/badge/platform-macOS%20%7C%20Windows-black)

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
| **No plaintext passcode** | The passcode is stored as a PBKDF2-SHA256 hash, set in the admin panel |
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

---

## Repo layout

```
locked-in/
├── recorder.py               screen + webcam + mic recorder (both platforms)
├── lockedin_config.py        settings store, password hashing, and the CLI the
│                             lockdown scripts read their settings through
├── admin_panel.py            the admin panel (Tk, both platforms)
├── lockedin_cloud.py         Supabase client — auth, tables, storage, stdlib only
├── student_session.py        the proctored check-in: sign in, ID photo, wait
├── uploader.py               publishes live tiles + heartbeat during an exam
├── cloud/
│   ├── SETUP.md              how to stand the backend up on a free Supabase project
│   ├── schema.sql            tables, RLS policies, storage buckets, purge function
│   ├── purge.py              retention: delete old sessions and their photos
│   ├── dashboard/
│   │   └── index.html        the faculty dashboard — one self-contained page
│   └── test/
│       ├── run_tests.sh      applies schema.sql to a local Postgres, then attacks it
│       ├── supabase_stub.sql the bits of auth/storage the schema builds on
│       └── rls_test.sql      nine attempts to break the access rules
├── macos/
│   ├── build.sh              build dist/Locked In.app from source
│   ├── guided-access.command the actual macOS lockdown (bash + AppleScript)
│   └── src/
│       ├── main.swift        the launcher UI (Cocoa + WKWebView, matrix-rain screen)
│       ├── Info.plist        app bundle metadata + permission strings
│       ├── mkicon.swift      draws the padlock AppIcon programmatically
│       ├── launcher.applescript   earlier AppleScript-only launcher (superseded)
│       └── lockdown.applescript   the lockdown loop, standalone (reference)
├── windows/
│   ├── LockedIn.hta          the launcher UI (HTA, same screen as the Mac app)
│   └── guided-access.ps1     the actual Windows lockdown (PowerShell, self-elevating)
├── assets/
│   └── AppIcon.icns          prebuilt icon
└── dist/
    └── Locked In.app         prebuilt, ad-hoc-signed macOS app (arm64)
```

The launcher's start screen asks **Student** or **Faculty**; there is a smaller
"on Windows?" link for the other platform's instructions, so you can copy this whole
folder to both machines (USB / iCloud / OneDrive) and use whichever applies. The `.py`
files at the top level are shared by both platforms — keep them next to the platform
folder, or in it, and each launcher will find them.

Faculty is a web page rather than a desktop screen: the Faculty button opens
`cloud/dashboard/index.html` at whatever address you published it to, so a proctor can
work from their own laptop instead of a student's machine.

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

To exit: quit Chrome (⌘Q), then enter the passcode.

### Windows

1. Keep **`LockedIn.hta`**, **`guided-access.ps1`** and the three `.py` files together
   (the `.py` files may sit in the folder above, as they do in this repo).
2. Double-click **`LockedIn.hta`**.
3. Click **Windows**, agree to the recording notice, then approve the Administrator
   (UAC) prompt — needed for the Chrome registry policy.

Windows asks for camera and microphone access under Settings → Privacy → Camera /
Microphone; desktop apps must be allowed.

To exit: close Chrome, then enter the passcode.

---

## The admin panel

Click **⚙ Admin** on either launcher, or run it directly:

```bash
uv run --script admin_panel.py
```

Default login is **`admin` / `admin`**, and the panel keeps warning you until both that
password and the unlock passcode have been changed.

| Tab | What you set |
|---|---|
| **Allowed sites** | The one URL the session is pinned to, and the hosts Chrome may still load (SSO, 2FA, CDNs). Paste a whole URL into the host box and it keeps just the hostname. |
| **Security** | The admin password, and the unlock passcode that ends a locked session. |
| **Recording** | Which of screen / webcam / microphone to capture. |
| **Proctoring** | The Supabase project behind proctored exams: project URL, anon key, dashboard address, and how often live thumbnails are published. **Test the connection** checks the two values without saving them. Leave the URL and key blank to run standalone. |

Settings are saved to one JSON file, and the lockdown reads it at the start of every
session:

| Platform | Location |
|---|---|
| macOS | `~/Library/Application Support/LockedIn/config.json` |
| Windows | `%LOCALAPPDATA%\LockedIn\config.json` |

Set `LOCKEDIN_CONFIG` to a path to override it — useful for testing, or for pointing a
whole lab of machines at one prepared file.

### How the passcode is stored

Neither password is written to disk. The file holds a PBKDF2-HMAC-SHA256 hash with a
random 16-byte salt and 200,000 iterations, and the lockdown verifies a typed passcode
by piping it to `lockedin_config.py verify-passcode` on stdin — never as a command-line
argument, which every other process on the machine could read.

**What that buys, and what it doesn't.** It means the passcode is no longer sitting in
plain text in a script that every student can open — which is what it replaced. It is
**not** a security boundary against the person who administers the machine: they can
delete or replace the settings file and set their own passcode, and a short passcode can
still be attacked offline once the file is copied. Choose a passcode you'd be willing to
treat as a real password.

---

## Recording

Each session writes one dated folder to the Desktop:

```
LockedIn-Recordings/20260817-143000/
├── screen.mp4      the primary display, 10 fps, downscaled past 1600px wide
├── camera.mp4      the webcam, 15 fps
├── audio.wav       the microphone, 44.1 kHz mono
└── recorder.log    what the recorder did, including any permission failures
```

Both videos carry a burnt-in wall-clock timestamp. They're written on a wall-clock lock
— when capture falls behind, frames are duplicated rather than dropped — so a
40-minute session produces 40 minutes of footage that lines up with the audio and with
the real clock. Audio is a separate `.wav` on purpose: muxing it into the video would
mean depending on ffmpeg, and the point of `recorder.py` is that a student machine needs
nothing but Python.

Run the recorder on its own to check a machine before an exam:

```bash
uv run --script recorder.py --out-dir ~/Desktop/test-session
# stop it with Ctrl+C, or: touch ~/Desktop/test-session/STOP
```

Useful flags: `--no-camera`, `--no-audio`, `--no-screen`, `--screen-fps`, `--camera-fps`,
`--max-width`, `--camera-index` (for a second camera).

Screen capture is the expensive part — it is a pure-Python loop, so 10 fps at 1600px is
a deliberate compromise. Raising `--screen-fps` on an older machine will cost the
student real CPU during their exam.

---

## Proctored exams

Full walkthrough: **[cloud/SETUP.md](cloud/SETUP.md)**. The short version of how it
hangs together:

```
student's Mac                                  proctor's browser
─────────────                                  ─────────────────
student_session.py  ── sign in, ID photo ──┐
                                           ▼
                                   Supabase (free tier)
                                   auth · Postgres + RLS · storage
                                           ▲
recorder.py ──> live/*.jpg ──> uploader.py ─┘   ──> dashboard/index.html
   (records to disk)          (ships thumbnails)      (approve · live grid)
```

**The approval gate.** `student_session.py` runs *before* the lockdown, and the
lockdown starts only if it exits 0. So a student who is refused never ends up in a
locked-down browser, and nothing on their machine has been changed. A student cannot
approve their own session even with full control of their laptop: the permitted status
transitions are enforced by a Postgres trigger, and the only credential the app holds
is the anon key.

**Why the recorder and the uploader are separate processes.** Only one process can
hold the webcam, so an uploader cannot capture its own frames. And an upload stalling
on bad campus wifi must not cost frames of the actual exam recording. So the recorder
drops small JPEGs in `<session>/live/` and forgets about them; the uploader ships
whatever is there. Kill the uploader and the recording continues intact — the
dashboard just shows that student as stale.

**What is uploaded, and what is not.** Two identity photos once, then two thumbnails
per student overwritten in place every few seconds, plus heartbeats and events. The
full-rate video and all audio never leave the machine. That is what keeps a whole
class inside the free tier — see the cost breakdown in SETUP.md.

Check a project from the command line without launching anything:

```bash
uv run --script lockedin_cloud.py check     # is the URL + key good?
uv run --script lockedin_cloud.py login     # sign in, print the account's role
```

**Verifying the access rules.** The claim the whole design rests on is that a student
with full control of their laptop, holding the anon key that ships inside the app,
still cannot admit themselves or see anyone else's data. `cloud/test/run_tests.sh`
applies `schema.sql` to a throwaway local Postgres and then tries nine ways to break
it — self-approval, inserting a pre-approved session, self-promotion to faculty,
forging the proctor's decision fields, reading another student's session, uploading
into someone else's storage folder, walking a session backwards, and heartbeating
after a refusal. All nine are blocked; run it yourself before trusting it with a
class.

---

## Before you deploy this

Written for the case where an instructor is considering this for a real class. Take
these to whoever approves it at your institution.

**Consent and notice.** Every session opens with a notice listing exactly what is
captured and where it is saved, and the student must agree before anything starts;
declining exits without changing the machine. That is deliberately the first thing that
happens. You can turn it off (`REQUIRE_CONSENT` in the lockdown script), but recording
someone's camera and microphone without notice can be unlawful — several US states
require all-party consent for audio — so only do that where students have already been
told in writing, and where your institution has signed off.

**Get institutional review first.** Recording students' cameras, screens and audio is
covered at most universities by FERPA obligations, an IRB or privacy office, and often a
union or accessibility policy. Things they will ask that this tool does not answer for
you:

- Where do the recordings end up? The full-length video and audio always stay on the
  student's own machine — there is no upload of those, and no retention policy for
  them, so you would have to define how they're collected, who may watch them, and
  when they're deleted.
- In **proctored** mode there is additionally a server, and it holds more sensitive
  material than the videos do: a photograph of each student's ID card, a photograph
  of their face, and rolling thumbnails of their screen. That data lives in your
  Supabase project, and deciding where it may live, who can read it, and when it is
  purged is now your obligation rather than a hypothetical. `cloud/purge.py` does the
  deleting; nothing runs it for you. Note also that deletion has a mandatory order —
  files through the Storage API *first*, rows second — because a file whose session
  row is gone can no longer be deleted by anyone. See SETUP.md.
- Who can access them? The local files land on the Desktop, readable by the student
  and anyone else on that account. The uploaded material is readable by the student it
  belongs to and by the proctor who owns that exam, enforced by database policies —
  and by anyone holding your project's `service_role` key, which is why that key must
  never go near the app.
- What about students who can't comply — no webcam, a shared room, a disability
  accommodation, or reasonable objections to being filmed at home?
- What is the fallback when the recorder fails? It reports the failure and, by design,
  lets the session continue rather than blocking an exam.

**Be honest about the lockdown's strength.** It stops casual tab-switching. It does not
stop Force Quit, Task Manager, a reboot, a phone, or a second laptop. Anyone deciding
whether this is sufficient should know that before they rely on it.

**This has not been through a security review**, and the recordings are unencrypted on
disk.

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

If you've lost the admin password too, delete the settings file and the next run
recreates it with the defaults.

---

## License

MIT — see [LICENSE](LICENSE).
