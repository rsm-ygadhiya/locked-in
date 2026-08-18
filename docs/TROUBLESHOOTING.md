# Known problems, and what to do about them

Two halves. The first is what this tool cannot do, by design or by circumstance — read
it before deciding to rely on it. The second is symptoms and fixes, for when something
that should work doesn't.

---

## Known problems

### It is not a secure exam browser

The single most important thing on this page. The lockdown stops casual tab-switching
and idle wandering. It does not stop:

- **Force Quit (⌘⌥Esc) or Task Manager.** Both end the session. The machine is left
  clean, which is the design — failing closed would trap a student in a locked browser
  when something goes wrong at 9am in a room of 200 people.
- **A reboot.** Nothing survives it; nothing is installed to make it survive.
- **A second device.** A phone under the desk defeats every part of this, and no
  amount of work on the software changes that.
- **Anyone with admin rights on the machine**, who can replace the settings file, set
  their own passcode, or read the recordings.

If you need real integrity guarantees, use Respondus, Proctorio or Honorlock. This is a
focus and monitoring tool that happens to be honest about what it is.

### The recordings are not protected

They are written unencrypted to the student's Desktop under `LockedIn-Recordings/`, and
nothing collects, uploads or deletes them. Anyone using that account can watch them.
Deciding who gathers them, who may watch them, and when they are destroyed is work this
tool does not do for you.

### macOS permissions belong to Terminal, not to the app

The lockdown runs as a shell script in Terminal, so Screen Recording, Camera,
Microphone, Accessibility and Automation are all granted to **Terminal** in System
Settings → Privacy & Security. Consequences worth knowing:

- Anything else run from Terminal inherits those permissions.
- Revoking them from Terminal silently disables recording rather than stopping the
  exam — by design, so a permissions mistake doesn't cancel a class, but it does mean
  a session can run with no video and only a line in `recorder.log` to say so.

### The app is not notarized

`dist/Locked In.app` is ad-hoc signed, so the first launch on any machine needs
right-click → **Open** → **Open**. Distributing it to a lab means either doing that on
each machine, or signing it with a paid Developer ID.

### The Windows launcher is an HTA

`LockedIn.hta` runs under `mshta.exe`, which is legacy Windows scripting. Plenty of
managed environments block or alert on `mshta` through AppLocker, WDAC or EDR, and some
antivirus products treat a self-elevating PowerShell script that edits Chrome policy as
suspicious — which, described that way, is fair. Expect to have that conversation with
whoever runs the endpoint policy before deploying on Windows.

### Only the primary display is recorded

A second monitor is not captured, and the lockdown does not disable it.

### Screen capture is a pure-Python loop

10 fps at up to 1600px wide is a deliberate compromise: it costs a student real CPU
during their exam, and raising `--screen-fps` on an older machine costs more. There is
no hardware encoding path.

### Audio is a separate file

`audio.wav` is not muxed into the video, because muxing would mean depending on ffmpeg,
and the point of `recorder.py` is that a student machine needs nothing but Python. Both
tracks are written on a wall-clock lock, so they line up — but you get two files.

### Proctored mode needs the internet, and the free tier has limits

Supabase's free tier is 500 MB of database, 1 GB of storage, 5 GB of egress a month. A
40-student, 2-hour exam costs roughly 200 MB of egress with one proctor watching the
whole time. The dominant cost is people staring at the live grid, not the frame
interval. Several proctors on several dashboards multiply it.

### Student sign-in uses synthetic email addresses

A campus ID becomes `A12345678@ucsd.edu`, which is not a real mailbox, so email
confirmation has to be off in the Supabase project and there is no password reset by
email. A student who forgets their password needs a proctor to set a new one in the
Supabase dashboard.

### One settings file per user account

Settings live in the logged-in user's own directory, so a shared machine configured
under one account is not configured under another. Point a whole lab at one prepared
file with the `LOCKEDIN_CONFIG` environment variable.

---

## When something goes wrong

### The lockdown

**"This machine is set up for proctored exams but student_session.py is missing."**
The `.py` helpers are not where the lockdown looks. It checks beside the script first,
then `../src/`. Keep the repo layout intact, or flatten everything into one folder.

**The lockdown starts but there is no video, or `camera.mp4` is missing.** Read
`recorder.log` in the session folder — it records permission failures verbatim. On
macOS the answer is almost always Screen Recording or Camera not granted to Terminal.
Recording failures never stop the exam, which is why this is easy to miss.

**The webcam films the ceiling, or a desk.** macOS offers an iPhone over Continuity
Camera alongside the built-in one, and it can land at index 0. `recorder.py` ranks
devices so the laptop camera wins, but you can force it: `--camera-index N`.

**Chrome opens on the wrong site, or blocks the exam site.** The allowed hosts list is
hostnames, not URLs, and SSO and 2FA hosts need to be on it too — a login that redirects
through `duosecurity.com` fails without it. Faculty → Exam settings → Allowed sites.

**Chrome is still locked down after the session.** It shouldn't be; cleanup runs even
on Ctrl+C or a crash. If a hard power loss caught it mid-session, remove the policy by
hand: `/Library/Managed Preferences/com.google.Chrome` on macOS, or the
`HKLM\SOFTWARE\Policies\Google\Chrome` URLBlocklist/URLAllowlist keys on Windows, then
restart Chrome.

**Locked out — the passcode isn't accepted.** Ctrl+C in the Terminal window, Force Quit,
or reboot; cleanup still runs. If the passcode is genuinely lost, delete the settings
file (`~/Library/Application Support/LockedIn/config.json`, or `%LOCALAPPDATA%\LockedIn\`)
and the next run recreates it with the default, `admin`.

### The proctor dashboard

**The Faculty button does nothing.** It needs `uv` to start the local server, and a
double-clicked app gets no login shell, so `uv` has to be in one of the standard
locations (`~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`). Failing that, open
`server/dashboard/index.html` in a browser directly.

**Another device on the wi-fi can't reach the dashboard.** In rough order of
likelihood: macOS is asking to allow incoming connections and nobody clicked Allow; the
network has client isolation (most guest and campus wi-fi does) so devices cannot see
each other at all; the other device is on cellular rather than wi-fi; a VPN on either
end is routing around the LAN. Test with the numeric address first —
`http://192.168.x.x:8765/` — because `.local` names need mDNS, which Windows only
resolves from Windows 10 1703 onwards and some networks drop.

**The address worked yesterday and doesn't today.** A new DHCP lease moved the machine.
The Faculty button re-asks the server for its current address every time, so use that
rather than a bookmarked IP, or use the `.local` name.

**Port 8765 is in use.** `serve.py` picks the next free port automatically, up to 12
along, and prints what it chose. `--port N` to pin it.

**The dashboard is empty, or shows a different exam than the students joined.** The
page and the app must point at the same Supabase project. Serving the page rather than
opening the file makes that impossible to get wrong — `serve.py` patches this machine's
project and key into the page as it serves it. Opening `index.html` from disk uses
whatever was typed into the file, which is the copy that drifts.

**Stopping the server.** `uv run --script server/serve.py --stop`, or the **Stop**
button in Faculty → Exam settings → Proctoring. It keeps running after the panel and
the launcher close, which is the point — it should outlive them, not the exam.

### Sign-in and accounts

**`500 Database error querying schema` on every sign-in for one account.** That account
was created with SQL that left the token columns `NULL`. GoTrue reads them as plain
strings and fails. Fix in [SETUP.md](SETUP.md#5-make-yourself-a-proctor) — set them to
`''`. Nothing else about the account looks wrong, which is what makes this one
expensive to debug.

**A student can't sign in and never got a confirmation email.** Email confirmation must
be off: Authentication → Sign In / Providers → Email → **Confirm email** OFF. Campus-ID
addresses are synthetic and no mail will ever arrive at them.

**Signing in as a proctor shows a student's view.** The account exists but has not been
promoted. Use **Add proctor** in the dashboard header, or the SQL in
[SETUP.md](SETUP.md#5-make-yourself-a-proctor). Self-promotion is blocked by a database
trigger, on purpose.

**A tile on the grid has gone red.** The student's app stopped checking in — asleep,
closed, or off the network. The tile deliberately goes stale rather than showing a
frozen image, because a frozen image is indistinguishable from a student sitting still.

**The network dropped mid-exam.** Recording continues locally and loses nothing; the
tile goes stale; the exit-code check falls back to the machine's local passcode so
nobody is trapped. Uploads resume on their own when the network returns.
