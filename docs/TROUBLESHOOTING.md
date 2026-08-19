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

### On Windows

**The Windows half has not been tested.** Both platforms read the same settings file and
run the same Python helpers, and the Windows launcher and lockdown were written to match
the macOS ones step for step — but they have not been run against a real Windows
machine. Nobody should plan a class around them without someone sitting down at a
Windows box first and going through the whole flow. The parts most likely to need work,
in order of suspicion: the self-elevating UAC prompt, the Chrome registry policy paths,
camera and microphone access for a desktop app, and whether `mshta` runs at all under
your endpoint policy — which is the next item.

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

**Student gets the recording notice instead of the check-in window.** That machine is
in standalone mode: proctored mode switches on only once a project URL and anon key are
in its settings. A fresh clone has neither, even though the dashboard page it ships with
does. Fix it in one line, with the dashboard server running:
`uv run --script src/lockedin_config.py enroll http://127.0.0.1:8765` — or fill the two
fields in under Faculty → Exam settings → Proctoring.

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

### The floating exit button

**It isn't there.** On macOS it is a separate binary, `LockedInOverlay`, built by
`macos/build.sh` and shipped inside the app bundle. Running from a clone without
building it means no pill — the lockdown says so at startup and carries on, and
quitting Chrome still asks for the code. Check `overlay.log` in the session folder:
it records where the pill thinks it put itself.

**The exit code is rejected.** Two codes exist and they are not interchangeable. In a
proctored exam the lockdown wants *that exam's* exit code, checked by the server — the
machine's own passcode is only accepted when the server cannot be reached, or when the
exam has no exit code at all. Look the exam's code up in the dashboard under **Your
exams → Show code**. If it still fails, check the student is sitting the exam you think
they are: the code is per-exam, so the code for `MID24` is not the code for `FINAL`.

**It's off screen, or somewhere annoying.** It remembers where it was last dragged to,
in `~/Library/Application Support/LockedIn/overlay-position.json`. Delete that file and
it goes back to the bottom-right corner.

**The code is rejected there but works in the usual prompt.** They run the same
verifier, so this should be impossible — if you see it, check `overlay.log` and file it,
because it means the two paths have drifted apart.

**Typing into it does nothing.** It is a non-activating panel: it takes keyboard focus
without pulling focus away from Chrome, which is what stops the lockdown's every-0.3s
"put Chrome back in front" pass from fighting it. If a click does not put a cursor in
the field, that mechanism is what to suspect first, and closing Chrome is still the way
out.

**Nobody wants a button students can press.** It only ever ends the lockdown for
someone who knows the exit code, which is the proctor's, and the code is checked by the
server rather than on the machine. If you would still rather not have it, delete
`LockedInOverlay` from the bundle's `Resources/`.

**A student is stuck behind a code nobody set.** Fixed, and worth knowing if you are
running an older copy: an exam created without an exit code answered "no" to every code
typed, and the lockdown treated that as a wrong code rather than as "this exam has no
code", so the machine's own passcode was never tried and Force Quit was the only way
out. The lockdown now asks whether the exam has a code before refusing.

**A student force-quit and nothing was flagged yet.** Give it three minutes. A force
quit writes nothing on the way out, so the only evidence is the silence that follows,
and the silent alert waits three minutes before believing it. That is on purpose: at
twenty seconds — the speed that greys a tile — a closed lid would raise an alert every
time somebody carried a laptop across a room.

**A "silent" alert for a student who is sitting right there.** Their app stopped
checking in: asleep, off the network, or the uploader died while the exam carried on.
The dashboard reports what it saw rather than guessing which. Ending the session
records that it had been quiet, so the timeline keeps the distinction.

**"Ended without the exit code" on somebody who finished normally.** The stamp comes
from the server when a correct exit code is verified, so it means exactly one thing:
that exam's own code was not typed on that machine. The usual innocent explanation is
the machine's local passcode being used instead — which the row says, when the student's
app got far enough to report it. An exam with no exit code set has nowhere to get a
stamp from, so every session on it ends this way.

**A student shows as "stopped checking in" but was fine.** The heartbeat has been quiet
for over 90 seconds. A closed lid, a dead wifi, a sleeping laptop and a force quit look
identical from the server, which is why it says what it saw rather than what it thinks
happened. It clears itself if the app comes back.

### Kept frames

**The filmstrips are empty.** Three things to check in order: `snapshot_interval` is
not 0 in Faculty → Exam settings → Proctoring; `schema.sql` has been re-run against the
project since kept frames existed, so the `snapshots` table is there; and the exam is
long enough to have reached the first interval. `uploader.log` in the session folder
says how many frames it kept.

**Storage is filling up.** Kept frames are never overwritten, so they only grow until
the exam is deleted — roughly 500 MB for forty students over two hours at one a minute,
against a 1 GB free tier. Delete exams once grades are in, lengthen the interval, or set
it to 0.

**A deleted exam left files behind.** It shouldn't: the dashboard reads the snapshot
rows, deletes each file through the Storage API, and only then deletes the exam, because
a file whose row is gone can no longer be named by anyone. If a delete failed halfway it
says so and keeps the rows, so run it again rather than deleting the rows by hand.

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

### Exams

**The join code is taken.** Codes are unique among *live* exams only. Archive the
exam holding it — everything is kept — and the code is free immediately. Restoring
that exam later fails if somebody has since taken the code, and says so.


**"Could not create it" when you press Create.** Almost always the join code: they are
unique across the entire project, not per proctor, so a code another proctor used —
`1111`, `TEST`, `DEMO` — is refused. The dashboard now says so in those words; older
copies showed the raw database error. Pick a less obvious code.

**An exam appears that you did not create.** Fixed. The dashboard used to list every
exam it could *read*, and open exams are readable by anyone signed in, so other
proctors' exams showed up in the picker — and then Delete, Close the door and Exit code
all failed against them, because those are owner-only. It now lists only your own.

**The recording chips do nothing, or a new exam says its database is too old.** Those
five columns arrived after `snapshots` did, so a project migrated once still needs
`server/schema.sql` run again. Everything keeps working meanwhile — the exam is created
without them and each machine falls back to its own settings.

**An exit code shows "set earlier".** That exam's code was set before codes could be
read back, so only its hash exists. It still works; it cannot be shown. **Set a new
one** and it becomes readable.

**The exit code says "set, not readable".** That project's database predates readable
exit codes. Re-run `server/schema.sql` on it; it is idempotent, adds the column, and
does not touch existing exams. Until then you can set a new code but not look up the
old one.

**Deleting an exam does nothing.** You can only delete exams you own. If Delete fails
with a policy error on an exam that looks like yours, check which account created it —
`Your exams` only shows your own, so an exam missing from that list belongs to another
proctor.

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
