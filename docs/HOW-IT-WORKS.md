# How it works

The detail behind the short version in the [README](../README.md): what the recorder
writes, what the passcode does and doesn't buy, how the proctored side hangs together,
and how to get the dashboard in front of a proctor.

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

Full walkthrough: **[docs/SETUP.md](SETUP.md)**. The short version of how it
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
ships with. For anything real, stand up your own ([docs/SETUP.md](SETUP.md)) with a
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
applies `schema.sql` to a throwaway local Postgres and then tries eleven ways to break
it — self-approval, inserting a pre-approved session, self-promotion to faculty,
forging the proctor's decision fields, reading another student's session, uploading
into someone else's storage folder, walking a session backwards, and heartbeating
after a refusal, and deleting a frame kept of you. All eleven are blocked; run it
yourself before trusting it with a
class.
