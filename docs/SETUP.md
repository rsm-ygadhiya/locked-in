# Setting up proctored exams

Locked In works two ways. Out of the box it is a standalone lockdown: no accounts,
nothing leaves the machine. Follow this file and it becomes a proctored system —
students sign in, photograph their student ID, and wait for a proctor to admit them,
and the proctor watches a live grid of everyone's screen and webcam.

Everything here fits inside Supabase's free tier. Budget about 20 minutes.

You need: a Supabase account (free, no card), and the ability to run one SQL script.

---

## 1. Create the project

1. Go to <https://supabase.com>, sign in, **New project**.
2. Name it whatever you like, pick the region closest to your campus, and set a
   database password. You will not need that password again for this — Locked In
   never connects to Postgres directly — but save it anyway.
3. Wait for it to finish provisioning, about two minutes.

## 2. Create the tables

1. In the project, open **SQL Editor** → **New query**.
2. Paste the entire contents of [`server/schema.sql`](../server/schema.sql) and press **Run**.
3. It should finish with *Success. No rows returned*.

That creates six tables, the Row Level Security policies that decide who can see
what, two private storage buckets, the trigger that stops a student from approving
themselves, and the functions behind exit codes and adding proctors.

Running it a second time is safe — it drops and recreates the policies rather than
erroring.

If you want to satisfy yourself that the access rules hold before trusting them with
a class, `test/run_tests.sh` runs the schema against a local Postgres and then tries
nine ways to break it — self-approval, reading another student's session, uploading
into someone else's folder, forging the proctor's decision:

```bash
brew install postgresql@16 && brew services start postgresql@16
./server/tests/run_tests.sh
```

It uses a throwaway database and never touches your Supabase project.

## 3. Turn off email confirmation

Students sign in with their campus ID, which Locked In turns into an address like
`A12345678@ucsd.edu`. Those are not real mailboxes, so a confirmation email would
never arrive and nobody could log in.

**Authentication** → **Sign In / Providers** → **Email**:

- turn **Confirm email** OFF
- leave **Enable email provider** ON

If you would rather use real, deliverable addresses, leave confirmation on and set
`id_email_domain` to your actual mail domain — but then every student has to click a
link in an email before their first exam, which is a bad thing to discover five
minutes before a midterm.

## 4. Copy the two values Locked In needs

**Project Settings** → **API**:

| Value | Where it goes |
| --- | --- |
| **Project URL** — `https://xxxxxxxx.supabase.co` | admin panel, and the dashboard file |
| **anon public** key | admin panel, and the dashboard file |

The anon key is meant to be published — it ships inside a desktop app that students
can open, and Supabase designs it that way. Every real access rule is enforced by the
policies in `schema.sql`.

**Never use the `service_role` key.** It bypasses all of them. The admin panel
refuses it if you paste it in, but the dashboard file cannot check, so be careful
there.

## 5. Make yourself a proctor

There is no self-service faculty signup, on purpose: anyone who could grant
themselves the faculty role could watch every student in the system.

1. **Authentication** → **Users** → **Add user** → **Create new user**.
2. Email: your campus ID plus the domain — `yourid@ucsd.edu` — or a real address.
   Set a password. Tick **Auto Confirm User**.
3. Back in **SQL Editor**, promote that account:

```sql
update public.profiles p
set    role      = 'faculty',
       full_name = 'Your Name',
       campus_id = 'yourid'
from   auth.users u
where  u.id = p.id
  and  u.email = 'yourid@ucsd.edu';
```

4. Confirm it took:

```sql
select u.email, p.role, p.full_name from public.profiles p
join auth.users u on u.id = p.id order by p.created_at desc;
```

You only have to do this **once**. After the first proctor exists, add the rest from
the dashboard — **Add proctor** in the header — which creates the account and grants
the role in one step. Students never need any of this: they register themselves from
the check-in screen and land as students automatically.

> **If you create an account with SQL instead of the dashboard**, set the token
> columns to `''` and not `NULL`:
>
> ```sql
> update auth.users set
>     confirmation_token = '', recovery_token = '', email_change = '',
>     email_change_token_new = '', email_change_token_current = '',
>     phone_change = '', phone_change_token = '', reauthentication_token = ''
> where email = 'yourid@ucsd.edu';
> ```
>
> GoTrue reads those columns into plain strings, so a `NULL` makes every sign-in
> for that account fail with a misleading `500 Database error querying schema`.
> The dashboard's own **Add user** sets them to `''`; hand-written SQL usually
> forgets. Nothing else about the account looks wrong, which is what makes this
> one expensive to debug.

## 6. Publish the dashboard

`server/dashboard/index.html` is one self-contained file. Open it in an editor and fill in
the two constants at the top of the `<script>` block:

```js
const SUPABASE_URL      = "https://xxxxxxxx.supabase.co";
const SUPABASE_ANON_KEY = "eyJhbGciOi...";
const ID_EMAIL_DOMAIN   = "ucsd.edu";
```

Then get it in front of a browser. In rough order of effort:

- **Serve it on your wi-fi.** Faculty → Exam settings → Proctoring → **Serve on this
  network**, or `uv run --script server/serve.py`. Prints an address like
  `http://192.168.1.23:8765/` that any device on the same network can open — your
  phone, a tablet, the laptop you actually want to sit behind. This is the one to
  pick if you want to watch from somewhere other than the machine holding the file.
- **Just open the file.** Double-click it. Works immediately, and is fine if you
  proctor from one machine and one machine only.
- **GitHub Pages.** Push this repo, enable Pages, and the dashboard is at a URL any
  proctor can open from anywhere. Remember the anon key is in the page — that is
  expected, but it does mean the page should not carry anything else you consider
  private.
- **Supabase Storage.** Create a public bucket, upload `index.html`, use its public
  URL.

Whichever you choose, paste the address into **Faculty → Exam settings →
Proctoring** as the dashboard address — that is what the Faculty button opens. The
**Serve on this network** button fills that in for you.

Two notes on the wi-fi option. It serves the page with the project URL and key from
this machine's settings patched in, so the copy in the file cannot drift out of step
with what the students are uploading to. And anyone on the network can load the page
without signing in — the same exposure as GitHub Pages, since the anon key is public
by design and every access rule is in the policies, but a visitor still has to sign
in as a proctor before they see a single student. `--local-only` binds it to this
machine; `--stop` ends it.

## 7. Point the student machines at the project

The quick way, if the machine with the settings is running the dashboard server
from step 6 and both are on the same network — on each other machine, in the Locked
In folder:

```bash
uv run --script src/lockedin_config.py enroll http://192.168.1.23:8765
```

That copies the project URL, the anon key, the ID domain and the live-monitoring
settings across, and points that machine's Faculty button at your dashboard. Nothing
else is touched: the passcode, the allowed site and the recording choices stay as
that machine has them. They only need to share a network for this one step — after
it, each machine talks to Supabase on its own from wherever it is.

By hand, or on a machine with no terminal: open the Locked In launcher → **Faculty**
→ **Exam settings** → **Proctoring**. It is the same panel on Windows:

- **Project URL** and **Anon key** from step 4
- **Dashboard address** from step 6
- **ID email domain** — `ucsd.edu` unless you changed it
- **Live monitoring** — 3 seconds at 640px is a sensible default; see the bandwidth
  note below before raising it

Press **Test the connection**, then **Save**.

The moment those two fields are filled in, the lockdown stops being able to start on
its own: every session now goes through check-in and needs a proctor's approval.
Clearing them returns the machine to standalone mode.

---

## Running an exam

**Proctor**, a few minutes before:

1. Open the dashboard, sign in.
2. **New exam** — title, the one site students are allowed, a short **join code**,
   and an **exit code**.
3. Read the **join code** out to the room. Keep the **exit code** to yourself.

The two codes do different jobs, and mixing them up defeats the point:

| | Who gets it | What it does |
| --- | --- | --- |
| **Join code** | the whole room | lets a student request a seat |
| **Exit code** | proctors only | ends the lockdown on a student's machine |

The exit code is stored only as a hash, and is checked by the server — it is never
sent to a student's computer, so it cannot be read off their laptop no matter what
they do to it. Each exam has its own, and changing it takes effect immediately on
every machine running that exam.

If the network is down when you try to release a machine, the check falls back to
that machine's local passcode (Faculty → Exam settings → Security). That fallback is
deliberate: failing closed would leave a student trapped in a locked browser.

**Students**:

1. Open Locked In → **Student**.
2. Sign in, or create an account (campus ID, password, full name).
3. Type the join code.
4. Read the recording notice and agree.
5. Photograph the student ID, then take a check-in photo.
6. Wait. The exam starts by itself the moment they are approved.

**Proctor**, during:

- The approval queue shows each student's ID photo beside their check-in photo, with
  the name on their account. Approve or refuse; a refusal reason is shown to the
  student in their own words.
- The live grid updates every few seconds. A tile turns red when a student's app
  stops checking in — asleep, closed, or offline.
- Click a tile for full-size frames and that student's event timeline.
- **Close the door** stops new students joining without disturbing anyone already
  running.

**Afterwards**: the full-length recordings are on each student's own machine, in
`~/Desktop/LockedIn-Recordings/`. Only the thumbnails and the two identity photos
were ever uploaded.

---

## What this costs

The free tier gives 500 MB of database, 1 GB of storage and 5 GB of egress a month.
The design is built around staying inside that:

- Live thumbnails are **overwritten in place**, not appended. Two objects per
  student for the whole exam, about 10 KB each, no matter how long it runs.
- Uploads are skipped when the image has not changed.
- The full-rate video never leaves the student's disk.

A 40-student, 2-hour exam costs roughly 200 MB of egress if every proctor keeps the
grid open the whole time — the images are what dominates, so the biggest lever is
having fewer people staring at the dashboard, not the interval.

Raising the interval to 1 second triples that. Going the other way, 10 seconds is
still perfectly usable for spotting someone on their phone.

## Deleting the data afterwards

ID photos and check-in photos are identity documents belonging to real students.
Run the purge once grades are in:

```bash
uv run --script server/purge.py --days 30 --dry-run   # see what would go
uv run --script server/purge.py --days 30             # actually delete
uv run --script server/purge.py --days 30 --yes       # for a cron job
```

It signs in as a proctor and only ever touches that account's own exams. No
`service_role` key involved.

**Why a script and not one line of SQL.** Deletion has a mandatory order, and
getting it wrong is unrecoverable:

1. delete the **files** through the Storage API
2. only then delete the **session rows**

Supabase refuses direct `DELETE` on `storage.objects` — removing that row would drop
the metadata and leave the real file orphaned in the storage backend. And the
policies that authorise a file deletion work by looking up the session named in the
file's path. So once the session row is gone, **nobody can ever delete those files
again** — not the student, not the proctor. They are unreachable with anything short
of the `service_role` key.

That is not hypothetical; it happened while this was being built. If you already
have orphans, either use the `service_role` key from the dashboard, or re-insert a
session row with the orphan's UUID, delete the files, then delete the row again.

`purge.py` enforces the order and refuses to delete any rows if a file deletion
failed. The dashboard's "Let them try again" button does the same for one student.

Decide the retention period **before** the first exam, tell students what it is, and
hold to it. That is the part people skip.

## Before you use this on a real class

- This is not a secure exam browser. Force Quit, Task Manager, a reboot, or a second
  device all defeat it. It raises the effort required to cheat casually; it does not
  make cheating impossible.
- You are now collecting photographs of student IDs, photographs of students'
  faces, and a continuous record of their screens. At a US university that is
  covered by FERPA, and campus IT will have a policy about where such data may
  live. A free Supabase project in a region you picked from a dropdown may not
  satisfy it.
- Talk to the instructor of record and to campus IT before pointing this at a
  graded exam. For anything high-stakes, the officially supported proctoring tools
  exist for a reason.
- Tell students, in writing and in advance, exactly what is captured, who can see
  it, and when it gets deleted. The check-in screen says all of this, but a consent
  screen five minutes before an exam is not meaningful notice on its own.

## When something goes wrong

**"That ID and password were not accepted"** — the account does not exist yet, or
email confirmation is still on (step 3). Check **Authentication → Users**.

**"No open exam has that code"** — the code is wrong, or the exam is closed. Codes
are compared in uppercase.

**Approving does nothing** — check the account is actually `faculty`, with the query
in step 5. A student account sees an empty dashboard rather than an error.

**Photos do not appear in the queue** — the session row has to exist before its
photos can be uploaded, which is how the storage policies authorise them. If a
student's card shows "photos missing", have them run check-in again.

**Tiles stay empty but the student is running** — look at `uploader.log` in their
session folder on the Desktop. A missing camera or a denied Screen Recording
permission shows up there.

**Everything is stale at once** — usually the proctor's own network. The dashboard
raises a *Refresh failed* message rather than silently showing you frozen images.
