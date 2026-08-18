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
> read [Before you deploy this](#before-you-deploy-this) and [known
> problems](docs/TROUBLESHOOTING.md#known-problems) — and use an official proctoring
> tool (Respondus / Proctorio / Honorlock) if you need real integrity guarantees.

![platform](https://img.shields.io/badge/macOS-tested-brightgreen)
![platform](https://img.shields.io/badge/Windows-written%2C%20not%20tested-orange)

> **Tested on macOS only.** Everything here has been run end to end on an Apple-silicon
> Mac. The Windows half — `LockedIn.hta` and `guided-access.ps1` — is written to do the
> same things and shares the same settings file and the same Python helpers, but it has
> not been run against a real Windows machine. Treat it as a starting point that needs a
> pass from someone with a Windows box, not as a shipped feature. See [what to expect on
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
| **Per-exam exit code** | A code only proctors know ends the lockdown; checked server-side, so it never reaches the student's machine |
| **Proctors add proctors** | From the dashboard; a student cannot promote themselves |
| **Kept frames** | A snapshot every minute is stored and survives the exam, so there is something to review afterwards rather than only a live grid |
| **Finished list** | Students who ended, with how long they sat, their photos and their kept frames |
| **Floating exit button** | A draggable pill on the student's screen: click, type the exit code, done — no attacking the browser to be offered the door |

---

## Repo layout

```
locked-in/
├── src/                      the shared Python helpers — both platforms, both modes
│   ├── recorder.py           screen + webcam + mic recorder
│   ├── lockedin_config.py    settings store, password hashing, and the CLI the
│   │                         lockdown scripts read their settings through
│   ├── admin_panel.py        the exam settings panel (Tk)
│   ├── lockedin_cloud.py     Supabase client — auth, tables, storage, stdlib only
│   ├── student_session.py    the proctored check-in: sign in, ID photo, wait
│   └── uploader.py           publishes live tiles + heartbeat during an exam
├── server/                   everything the proctored mode needs
│   ├── schema.sql            tables, RLS policies, storage buckets, purge function
│   ├── serve.py              publishes the dashboard on your wi-fi, so a proctor
│   │                         can watch from a phone or a second laptop
│   ├── purge.py              retention: delete old sessions and their photos
│   ├── dashboard/
│   │   └── index.html        the faculty dashboard — one self-contained page
│   └── tests/
│       ├── README.md         what the nine attacks prove, and how to read the output
│       ├── run_tests.sh      applies schema.sql to a local Postgres, then attacks it
│       ├── supabase_stub.sql the bits of auth/storage the schema builds on
│       └── rls_test.sql      nine attempts to break the access rules
├── docs/
│   ├── DEMO.md               ten-minute tour for whoever has to approve this
│   ├── SETUP.md              how to stand the backend up on a free Supabase project
│   └── TROUBLESHOOTING.md    known problems, and symptom-by-symptom fixes
├── macos/
│   ├── build.sh              build dist/Locked In.app from source
│   ├── guided-access.command the actual macOS lockdown (bash + AppleScript)
│   └── src/
│       ├── main.swift        the launcher UI (Cocoa + WKWebView, matrix-rain screen)
│       ├── Info.plist        app bundle metadata + permission strings
│       ├── overlay.swift     the floating "End exam" pill drawn over the lockdown
│       ├── mkicon.swift      draws the padlock AppIcon programmatically
│       ├── launcher.applescript   earlier AppleScript-only launcher (superseded)
│       └── lockdown.applescript   the lockdown loop, standalone (reference)
├── windows/
│   ├── LockedIn.hta          the launcher UI (HTA, same screen as the Mac app)
│   ├── exit-button.ps1       the floating "End exam" button, Windows side
│   └── guided-access.ps1     the actual Windows lockdown (PowerShell, self-elevating)
├── assets/
│   └── AppIcon.icns          prebuilt icon
└── dist/
    └── Locked In.app         prebuilt, ad-hoc-signed macOS app (arm64)
```

The launcher's start screen asks **Student** or **Faculty**. Faculty then offers the
two halves of a proctor's job — the web dashboard, and the exam settings — so setup is
no longer a gear icon a student can wander into. Both launchers show the same two
choices, and the exam settings are the same settings on either platform: they live in
one JSON file that both lockdown scripts read.
There is a smaller "on Windows?" link for the other platform's instructions, so you can
copy this whole folder to both machines (USB / iCloud / OneDrive) and use whichever
applies. The helpers in `src/` are shared by both platforms; each launcher and each
lockdown script looks beside itself first, then in `src/` one level up, so a flattened
copy on a USB stick works as well as a clone of the repo does.

Faculty is a web page rather than a desktop screen: the Faculty button opens
`server/dashboard/index.html` at whatever address you published it to, so a proctor can
work from their own laptop instead of a student's machine. If no address is set, or the
saved one is on your own network, the button starts `server/serve.py` and opens the
address that reports — see [proctoring from another
device](#proctoring-from-another-device).

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

To exit: close Chrome, then enter the passcode.

---

## The admin panel

Choose **Faculty → Exam settings** on either launcher, or run it directly:

```bash
uv run --script src/admin_panel.py
```

Sign in with your **proctor account** — the same Supabase account that approves
students in the dashboard. There is no separate admin password. A machine with no
project configured yet opens straight into the settings, since there is nothing to
authenticate against and entering the project is the reason you are there.

The panel keeps warning until the unlock passcode has been changed from the shipped
default.

| Tab | What you set |
|---|---|
| **Allowed sites** | The one URL the session is pinned to, and the hosts Chrome may still load (SSO, 2FA, CDNs). Paste a whole URL into the host box and it keeps just the hostname. |
| **Security** | The unlock passcode that ends a locked session. |
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
uv run --script src/recorder.py --out-dir ~/Desktop/test-session
# stop it with Ctrl+C, or: touch ~/Desktop/test-session/STOP
```

Useful flags: `--no-camera`, `--no-audio`, `--no-screen`, `--screen-fps`, `--camera-fps`,
`--max-width`, `--camera-index` (for a second camera).

Screen capture is the expensive part — it is a pure-Python loop, so 10 fps at 1600px is
a deliberate compromise. Raising `--screen-fps` on an older machine will cost the
student real CPU during their exam.

---

## Proctored exams

Full walkthrough: **[docs/SETUP.md](docs/SETUP.md)**. The short version of how it
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

**Kept frames.** The live thumbnails answer "what is on this screen right now" and are
overwritten forever, which leaves nothing to look at once an exam is over. So on a
slower clock — `snapshot_interval`, a minute by default — one frame of each stream is
also *kept*, and kept frames are never overwritten. They live until you delete the
exam, they show up as a filmstrip under each student in the dashboard, and deleting the
exam deletes every one of them along with the identity photos. That interval is the
setting that spends the free tier's 1 GB: forty students for two hours at one a minute
is roughly 500 MB, and there is no overwriting to save you. Set it to 0 to keep none.

**Ending an exam from the student's screen.** A draggable pill floats above the
lockdown. Click it, type the exit code, and the lockdown ends — the same code, checked
the same way, as the prompt you get by quitting Chrome. On macOS it is a non-activating
panel at screen-saver level so it can draw over Chrome's fullscreen Space without
stealing focus, and it runs as an accessory process so the lockdown's own "quit and
hide everything else" pass leaves it alone. Drag it where you like; it stays there next
time.

**Who finished.** Sessions that ended are listed under Finished, with how long each
student sat, how many frames were kept, and a Review button that opens their photos,
their kept frames and their timeline — all of it still there until the exam is
deleted.

Check a project from the command line without launching anything:

```bash
uv run --script src/lockedin_cloud.py check     # is the URL + key good?
uv run --script src/lockedin_cloud.py login     # sign in, print the account's role
```

### Proctoring from another device

`dashboard/index.html` opened as a file works, but only on the machine holding the
file — no use when you want the live grid on the iPad next to you, or on the laptop at
the front of the room. Serve it on your own network instead:

```bash
uv run --script server/serve.py

Dashboard, on this machine : http://127.0.0.1:8765/
Dashboard, on your wi-fi   : http://192.168.1.23:8765/
                             http://desk-mac.local:8765/
Enrol a student machine    : uv run --script src/lockedin_config.py enroll http://192.168.1.23:8765
```

Open either wi-fi address on any device on the same network. Or press **Serve on this
network** under Faculty → Exam settings → Proctoring, which starts the same server, and
fills the dashboard address in for you — after that the Faculty button opens it, and
starts the server first if nobody has.

The server hands out three things: the dashboard at `/`, the proctoring settings at
`/setup.json`, and `/enroll`, a page of joining instructions you can read off a phone.
The page it serves has this machine's project and key patched into it from the settings
file, so the dashboard and the app can never end up watching different projects.

It does not change how an exam runs. Students still talk to Supabase directly, so their
machines work on wi-fi or cellular, on campus or at home; this only decides who can
reach the page. Anyone on the network can load it without signing in, which is the same
exposure as publishing it to GitHub Pages — the anon key it carries is public by design,
and every access rule lives in the database policies, so a visitor still has to sign in
as a proctor to see a single student. `--local-only` binds it to this machine, and
`--stop` ends it.

### Hosting the dashboard

`serve.py` ties the dashboard to one machine on one network, which is right in a room and
brittle everywhere else. The address is whatever DHCP handed that laptop, so a lease
renewed mid-session moves it and the iPad in the proctor's hand is pointed at an address
nobody answers on any more. `localhost` and `.local` have a quieter version of the same
problem, since the server binds IPv4 only and both of those resolve to IPv6 first.

The page does not need a server of its own to avoid that. It is one file with the project
URL and the anon key already in it, talking to Supabase over HTTPS from the proctor's own
browser — so any static host will serve it, and the proctor gets one address that keeps
working when the network underneath it changes:

```bash
cd server/dashboard
npx vercel deploy --temporary                   # no account: a public HTTPS URL, good for an hour
npx vercel login && npx vercel deploy --prod    # or an address that stays
```

Better than either, once you know you want to keep it: connect the repository to the
Vercel project (**Settings → Git**), and every push to `main` redeploys the page. A
one-shot `vercel deploy` is a copy of the dashboard as it was that afternoon, and the
first thing you notice is a proctor signing in to a page that predates the feature they
were told to look for.

Two ways to point it at the dashboard, and it only matters which you pick because the
page is three directories down:

- **Root Directory `server/dashboard`** — publishes the page and nothing else. The
  cleanest option, and what a one-shot `cd server/dashboard && vercel deploy` already
  did.
- **Root Directory left at the repository root** — `vercel.json` redirects `/` to
  `server/dashboard/`, so the bare domain still lands on the dashboard, one hop later.
  This also publishes the source and the prebuilt app, which is fine for a public repo
  and not for a private one.

  A redirect rather than a rewrite, which is not a detail: Vercel checks the filesystem
  before applying rewrites, and the repository root has an `index.html` of its own —
  the stub that gives GitHub Pages a short address. That file wins any rewrite, so a
  rewrite silently does nothing and the bare domain serves the stub. Redirects are
  evaluated before the filesystem, so they actually happen.

Either way the page is static and talks to Supabase from the proctor's own browser, so
there is no server to configure and no environment variable to set. Signing in needs a
faculty account: a student account is told, in as many words, that there is nothing for
it to proctor.

Two things about a Vercel project that will waste an afternoon each:

- **Turn Vercel Authentication off** (Settings → Deployment Protection). It is on by
  default for new projects, and it means everyone who is not on your Vercel team — every
  proctor, your IT department — gets bounced to a Vercel login page before they ever see
  the dashboard. The page has its own sign-in, and it is the one that matters.
- **The dashboard must not be cached.** It is a single HTML file whose whole content is
  the app, so a CDN holding yesterday's copy is a proctor looking at yesterday's
  dashboard. `server/dashboard/vercel.json` sets `no-store` for exactly that reason, and
  it is why that file exists next to the page rather than at the repository root.

GitHub Pages needs no command at all — turn it on for the repository root, and the
`index.html` at the top of this repo redirects to `server/dashboard/`.

Either way, paste the address into Faculty → Exam settings → Proctoring → dashboard
address. The Faculty button then opens the hosted page instead of starting a server, and
a proctor can watch from a phone on cellular rather than having to be on the students'
wi-fi. Nothing about the exam itself changes: students talk to Supabase directly and
never to this page, so where it is hosted decides only who can load it.

One thing hosting does change is the size of the room. "Anyone on my wi-fi" and "anyone
with the link" are different audiences, and the second one is the whole internet if the
link ever gets out. The anon key on the page is public by design and every access rule
lives in the database policies, so a visitor still has to sign in as a proctor to see a
single student — which means **the password on that proctor account is the only thing
between a stranger and a class's check-in photos.** Do not host a page pointed at a
project whose proctor password is published, and that includes the demo project this repo
ships with. For anything real, stand up your own ([docs/SETUP.md](docs/SETUP.md)) with a
password nobody has read.

### Adding more machines to an exam

Any number of machines can sit the same exam — each one needs the project details, and
retyping a 200-character key on every laptop in a lab is how people end up with one
machine quietly pointed at the wrong place. With the server running on the machine that
already has them, run this on each of the others:

```bash
uv run --script src/lockedin_config.py enroll http://192.168.1.23:8765
```

That copies the project URL, anon key, ID domain and live-monitoring settings across,
and points that machine's Faculty button at your dashboard. Only that block is copied —
the passcode, the allowed site and the recording choices stay whatever that machine has,
because in a proctored exam the site comes from the exam itself.

They only need to share a network for the enrolment. After that each machine talks to
Supabase on its own, so students can be anywhere.

**Verifying the access rules.** The claim the whole design rests on is that a student
with full control of their laptop, holding the anon key that ships inside the app,
still cannot admit themselves or see anyone else's data. `server/tests/run_tests.sh`
applies `schema.sql` to a throwaway local Postgres and then tries nine ways to break
it — self-approval, inserting a pre-approved session, self-promotion to faculty,
forging the proctor's decision fields, reading another student's session, uploading
into someone else's storage folder, walking a session backwards, and heartbeating
after a refusal. All nine are blocked; run it yourself before trusting it with a
class.

---

## Known problems

The full list, with fixes, is in
**[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)**. The ones that change whether
you should use this at all:

- **The lockdown is defeated by Force Quit, Task Manager, a reboot, or a phone.** It
  stops casual tab-switching, and nothing stronger.
- **Recordings are unencrypted on the student's Desktop**, and nothing collects or
  deletes them. Who gathers them and when they are destroyed is work this tool does
  not do for you.
- **A recording failure does not stop the exam.** It is reported and logged, by design
  — so a session can run with no video and only a line in `recorder.log` to say so.
- **macOS permissions are granted to Terminal**, not to the app, because Terminal is
  what runs the lockdown. Anything else run from Terminal inherits them.
- **The Windows launcher is an HTA**, run by `mshta.exe`, which many managed
  environments block outright. Ask your endpoint people before planning around it.
- **Only the primary display is recorded**, and the second monitor is not disabled.
- **Proctored mode needs the internet**, and the free tier's limits are real: roughly
  200 MB of egress for a 40-student, 2-hour exam, dominated by how many people have
  the live grid open.
- **Kept frames are stored, not overwritten**, so they are the one thing here that
  grows without bound until you delete the exam — about 500 MB for a 40-student,
  2-hour exam at one a minute, against a 1 GB free tier. Lengthen the interval or set
  it to 0 if that is not a trade you want.
- **Not security-reviewed.** The access rules have a test suite
  ([server/tests/](server/tests/README.md)); the rest of it has had no outside review.

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
  purged is now your obligation rather than a hypothetical. `server/purge.py` does the
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

If you've lost the passcode as well, delete the settings file and the next run
recreates it with the defaults — including the shipped passcode, `admin`, which the
settings panel then nags you to change.

---

## License

MIT — see [LICENSE](LICENSE).
