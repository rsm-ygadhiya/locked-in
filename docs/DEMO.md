# Trying it out

Written for someone who has been handed this repo and asked whether it works, or
whether it should be allowed anywhere near a real exam — a colleague, a supervisor, or
whoever in IT gets to say no. It takes about ten minutes end to end, and you can stop after step 1 if you only want
to see the proctor's side — that step changes nothing on the machine.

The demo credentials below are published in this repo on purpose. **Which is exactly
why the project they belong to must never run a real exam** — see
[what to be careful about](#what-to-be-careful-about) at the bottom.

| | |
| --- | --- |
| Dashboard sign-in | `admin` / `admin123` |
| Student sign-in | `student` / `student123` |
| Unlock passcode (ends a locked session) | `admin`, on a fresh install |

---

## 0. What you need

- **Google Chrome** — the lockdown drives Chrome specifically.
- **[uv](https://docs.astral.sh/uv/)** — one line, no virtualenv to manage:
  ```bash
  curl -LsSf https://astral.sh/uv/install.sh | sh     # macOS
  winget install --id=astral-sh.uv -e                 # Windows
  ```
- **A Mac.** The whole of this has been run end to end on macOS only. The Windows
  launcher and lockdown are written and share the same settings and helpers, but have
  not been tested on a real Windows machine — if that is what you have, expect to be
  the first person to find out what is wrong with it.
- A machine you don't mind having its browser taken over for two minutes. The lockdown
  always cleans up after itself, including on a crash, but it is a fair thing to want
  to be sure of before you start.

If this is a fresh clone pointed at a fresh Supabase project rather than the demo one,
do [docs/SETUP.md](SETUP.md) first — about twenty minutes, all of it in a browser.

---

## 1. Look at the proctor's side (2 minutes, changes nothing)

```bash
uv run --script server/serve.py
```

It prints an address on your own network. Open it — from this machine, or from a phone
or tablet on the same wi-fi, which is the point of serving it rather than opening the
file — and sign in as `admin` / `admin123`.

An empty dashboard is the expected result at this stage: no exam is running. What is
worth looking at is what the page *is*. One HTML file, no build step, no framework, no
backend of its own. Every access decision it appears to make is really made by Postgres
row-level security policies in [`server/schema.sql`](../server/schema.sql); the page
holds only the anon key, which is designed to be public.

**New exam** creates one: a title, the single site students may reach, a **join code**
you read out to the room, and an **exit code** you keep to yourself. Make one called
something like `Demo` with join code `DEMO`, pointed at any site you like.

## 2. Point the machine at the project (30 seconds)

A fresh clone has a working dashboard and an unconfigured machine — the project is
baked into the page, but nothing has told the *app* about it, so it would run in
standalone mode with no check-in and no join code. With the server from step 1 still
running:

```bash
uv run --script src/lockedin_config.py enroll http://127.0.0.1:8765
```

Use the wi-fi address instead of `127.0.0.1` to do the same on any other machine on the
network — that is how you'd set up a second student laptop. It copies the project URL,
the anon key and the ID domain, and touches nothing else. Faculty → Exam settings →
Proctoring shows what it wrote, and **Test the connection** confirms it.

## 3. Sit the exam as a student (5 minutes)

On the same machine, or a different one:

**macOS** — double-click `dist/Locked In.app`. First time only, right-click → **Open**
→ **Open**, because the app is ad-hoc signed rather than notarized.
**Windows** — double-click `windows/LockedIn.hta`. Untested; see the note in step 0.

Then: **Student** → sign in as `student` / `student123` → type the join code → read the
recording notice → agree → photograph an ID (any card will do) → take a check-in photo
→ wait.

Nothing has been changed on the machine yet. That is deliberate: a student who is
refused never ends up in a locked-down browser. Back on the dashboard you are now in
the approval queue, with the ID photo beside the check-in photo. Approve yourself, and
the lockdown starts on the student machine: Chrome full-screen on the one allowed site,
everything else blocked, recording running, and a tile for that student appearing on
the live grid within a few seconds.

Try to get out. Close Chrome and it comes back asking for a code. Try a blocked site
and watch the event show up in the student's timeline on the dashboard.

To end it: click the floating **End exam** pill — drag it anywhere first, it stays
where you put it — and type the **exit code** from step 1, which is checked by the
server and never reaches the student's machine. Quitting Chrome asks for the same
thing, and the local passcode `admin` works either way, as the deliberate fallback for
when the network is down. Chrome goes back to normal, the
policy is removed, and the recording is finalized on the Desktop under
`LockedIn-Recordings/`.

## 4. The part IT usually asks about

Then look at the dashboard again: the student is under **Finished**, with how long they
sat and how many frames were kept. **Review** opens their identity photos, a filmstrip
of everything kept during the exam, and their timeline. That is what survives the exam,
and it survives until somebody presses **Delete exam**.

**What leaves the machine.** In standalone mode, nothing at all. In proctored mode:
two identity photos once, then two ~10 KB thumbnails per student overwritten in place
every few seconds, plus heartbeats and event rows. The full-length screen, camera and
microphone recordings never leave the student's disk — there is no code path that
uploads them.

**What the server enforces, and how to check.** The claim the design rests on is that a
student with full control of their laptop, holding the anon key that ships inside the
app, still cannot admit themselves or read anyone else's data. Don't take that on
trust:

```bash
brew install postgresql@16 && brew services start postgresql@16
./server/tests/run_tests.sh
```

That applies the real schema to a throwaway local database and then tries eleven
documented attacks against it. It never touches the Supabase project. See
[`server/tests/README.md`](../server/tests/README.md) for what each one proves.

**Deleting the data afterwards.** ID photos and check-in photos are identity documents.
`server/purge.py` deletes them in the order that actually works — files through the
Storage API first, rows second:

```bash
uv run --script server/purge.py --days 0 --dry-run   # what would go
uv run --script server/purge.py --days 0             # actually delete
```

**Where the honest limits are written down.** [Before you deploy
this](BEFORE-YOU-DEPLOY.md), and [Known problems](TROUBLESHOOTING.md#known-problems). Read those before deciding
anything; they are the part of this repo most worth your time.

---

## What to be careful about

**The credentials at the top of this page are public.** Anyone who reads this repo can
sign in to the demo project's dashboard as a proctor and see every student in it. That
is fine for a demo project holding photographs of nobody. It would be a serious data
breach in a project holding a real class. So:

- Never point a real exam at the demo project.
- For anything real, stand up your own Supabase project ([SETUP.md](SETUP.md)), make
  yourself a proctor with a real password, and never create an account called `admin`.
- Change the unlock passcode from `admin` under Faculty → Exam settings → Security.
  The settings panel keeps warning you until you do.

**The anon key in this repo is public by design** — it ships inside a desktop app that
students can open, which is why every access rule lives in database policies instead.
The `service_role` key is the opposite of that, and must never appear in this repo, in
the app, or in the dashboard page.

## If the demo login does not work

The `admin` account exists but starts out as a student, because self-promotion to
faculty is blocked by a database trigger — the same rule that stops a student promoting
themselves. Promoting it is one statement in the Supabase **SQL Editor**, run once:

```sql
update public.profiles p
set    role      = 'faculty',
       full_name = 'Demo Proctor',
       campus_id = 'admin'
from   auth.users u
where  u.id = p.id
  and  u.email = 'admin@ucsd.edu';
```

Signing in as `admin` before that runs gets you a student's view: no approval queue, no
grid. After it, the dashboard is a proctor's.
