-- ============================================================================
-- schema.sql — the Locked In proctoring backend, for a free Supabase project.
--
-- Paste this whole file into the Supabase SQL editor and run it once. It is
-- idempotent: running it again after a change is safe.
--
-- The shape of the thing:
--
--   profiles      one row per account, carrying the role (student / faculty)
--   exams         a faculty-owned exam with a join code students type in
--   sessions      one student's attempt at one exam — this is what gets approved
--   live_frames   the newest screen and camera thumbnail per session
--   snapshots     kept frames, one row per stored image, for review afterwards
--   events        an append-only log: heartbeats, blocked sites, focus loss
--
-- Every table has Row Level Security on, and the app only ever holds the anon
-- key. That matters: the anon key ships inside a desktop app a student can open,
-- so it must be assumed public. All real access control is the policies below.
--
-- The service_role key must NEVER go in the desktop app or the dashboard. It
-- bypasses every policy here.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Roles
-- ---------------------------------------------------------------------------

do $$ begin
    create type user_role as enum ('student', 'faculty');
exception
    when duplicate_object then null;
end $$;


-- ---------------------------------------------------------------------------
-- profiles
--
-- Mirrors auth.users with the fields the app needs. The role lives here rather
-- than in the JWT so faculty can be promoted without the user re-authenticating.
-- ---------------------------------------------------------------------------

create table if not exists public.profiles (
    id          uuid primary key references auth.users (id) on delete cascade,
    role        user_role   not null default 'student',
    full_name   text,
    -- The campus ID the person types at the login screen (student ID, employee
    -- ID). Kept so faculty can match it against the photographed card.
    campus_id   text,
    created_at  timestamptz not null default now()
);

comment on column public.profiles.role is
    'Promote a faculty member with: update public.profiles set role = ''faculty'' where campus_id = ''...'';';


-- ---------------------------------------------------------------------------
-- exams
-- ---------------------------------------------------------------------------

create table if not exists public.exams (
    id           uuid primary key default gen_random_uuid(),
    faculty_id   uuid        not null references public.profiles (id) on delete cascade,
    title        text        not null,
    -- The one site the lockdown pins Chrome to for this exam. Overrides the
    -- machine's local config, so the exam decides, not the student's laptop.
    allowed_url  text        not null,
    -- Short code a student types to join. Case-insensitive by convention:
    -- always stored and compared uppercase.
    join_code    text        not null unique,
    -- Students can only request a seat while this is true. Flipping it false is
    -- how faculty closes the door once the exam has started.
    is_open      boolean     not null default true,
    created_at   timestamptz not null default now()
);

create index if not exists exams_faculty_idx on public.exams (faculty_id);


-- ---------------------------------------------------------------------------
-- exam_secrets
--
-- The exit code: what a proctor types on a student's machine to end the
-- lockdown. It is deliberately NOT a column on exams.
--
-- Students can read the exams table — that is how a join code is resolved — and
-- Row Level Security is row-level, not column-level, so anything stored there is
-- readable by every student in the room. A separate table with its own policy is
-- what keeps the exit code out of their reach.
--
-- Only the hash is stored, via pgcrypto's crypt(), so the code cannot be read
-- back out even by the proctor who set it. Verification goes through
-- verify_exit_code() below, which answers yes or no and never returns the hash.
-- ---------------------------------------------------------------------------

create table if not exists public.exam_secrets (
    exam_id        uuid primary key references public.exams (id) on delete cascade,
    exit_code_hash text        not null,
    updated_at     timestamptz not null default now()
);


-- ---------------------------------------------------------------------------
-- sessions
--
-- One row per student per attempt. This is the object the whole approval flow
-- turns on, so the status values are worth reading carefully:
--
--   pending    student logged in, submitted ID photo + selfie, waiting
--   approved   faculty admitted them; the lockdown is allowed to start
--   rejected   faculty refused; reject_reason says why
--   active     the lockdown is running and uploading frames
--   ended      the session finished (or was terminated by faculty)
-- ---------------------------------------------------------------------------

create table if not exists public.sessions (
    id            uuid primary key default gen_random_uuid(),
    exam_id       uuid        not null references public.exams (id) on delete cascade,
    student_id    uuid        not null references public.profiles (id) on delete cascade,
    status        text        not null default 'pending'
                  check (status in ('pending', 'approved', 'rejected', 'active', 'ended')),

    -- Storage paths in the private 'identity' bucket, not public URLs. The
    -- dashboard mints a short-lived signed URL when it needs to show them.
    id_photo_path text,
    selfie_path   text,

    -- Recorded when the student ticks the consent box. A session with no
    -- consent_at was never agreed to, and the dashboard flags it.
    consent_at    timestamptz,

    -- Which machine, for the record. Not a security control — a student can say
    -- anything here — but useful when two sessions claim the same person.
    machine       text,

    requested_at  timestamptz not null default now(),
    decided_at    timestamptz,
    decided_by    uuid references public.profiles (id) on delete set null,
    reject_reason text,
    started_at    timestamptz,
    ended_at      timestamptz,
    -- Bumped by the student app every few seconds. The dashboard reads this to
    -- show "last seen 2s ago" and to grey out students whose app has died.
    heartbeat_at  timestamptz,

    -- One live attempt per student per exam. A retry after a rejection means
    -- faculty deletes the row or flips it back to pending, which is deliberate:
    -- a student should not be able to spam the approval queue with new rows.
    unique (exam_id, student_id)
);

create index if not exists sessions_exam_status_idx on public.sessions (exam_id, status);
create index if not exists sessions_student_idx     on public.sessions (student_id);


-- ---------------------------------------------------------------------------
-- live_frames
--
-- Deliberately one row per (session, kind), upserted in place, rather than an
-- append-only stream of every thumbnail. A 40-minute exam at one frame every
-- 3 seconds is 800 frames per student per stream; keeping only the newest is
-- what makes this fit in a free tier. The full-rate video stays on the
-- student's own disk for later review.
-- ---------------------------------------------------------------------------

create table if not exists public.live_frames (
    session_id   uuid        not null references public.sessions (id) on delete cascade,
    kind         text        not null check (kind in ('screen', 'camera')),
    storage_path text        not null,
    captured_at  timestamptz not null default now(),
    primary key (session_id, kind)
);


-- ---------------------------------------------------------------------------
-- snapshots
--
-- The opposite trade to live_frames, and the two exist side by side on purpose.
-- live_frames answers "what is on this student's screen right now" and is
-- overwritten forever; this answers "what did the exam look like" and is kept
-- until the proctor deletes the exam.
--
-- One row per stored image, so the table is also the list of files to delete —
-- there is no fixed set of names to cross join, the way there is for the four
-- objects a session always owns. That matters at deletion time: a file whose row
-- is gone can no longer be found by anyone.
--
-- Cadence is a client setting (cloud.snapshot_interval, default 60s), not a
-- server one, because the free tier's 1 GB is spent here and the person choosing
-- how fast to spend it is the one setting up the machines.
-- ---------------------------------------------------------------------------

create table if not exists public.snapshots (
    id           bigserial   primary key,
    session_id   uuid        not null references public.sessions (id) on delete cascade,
    kind         text        not null check (kind in ('screen', 'camera')),
    storage_path text        not null,
    captured_at  timestamptz not null default now()
);

create index if not exists snapshots_session_idx
    on public.snapshots (session_id, captured_at desc);


-- ---------------------------------------------------------------------------
-- events
--
-- Append-only. The lockdown writes here when something worth noticing happens,
-- so faculty has a timeline instead of only a wall of thumbnails.
-- ---------------------------------------------------------------------------

create table if not exists public.events (
    id         bigserial primary key,
    session_id uuid        not null references public.sessions (id) on delete cascade,
    kind       text        not null,
    detail     text,
    at         timestamptz not null default now()
);

create index if not exists events_session_idx on public.events (session_id, at desc);


-- ---------------------------------------------------------------------------
-- Helpers used by the policies
--
-- All are security definer with a pinned search_path: they read tables that the
-- calling user cannot read directly, and a mutable search_path on a definer
-- function is a privilege-escalation hole.
-- ---------------------------------------------------------------------------

create or replace function public.is_faculty()
returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
    select exists (
        select 1 from public.profiles
        where id = auth.uid() and role = 'faculty'
    );
$$;

-- True when the current user is the student the session belongs to.
create or replace function public.owns_session(sid uuid)
returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
    select exists (
        select 1 from public.sessions
        where id = sid and student_id = auth.uid()
    );
$$;

-- True when the current user is the faculty member who owns the session's exam.
create or replace function public.proctors_session(sid uuid)
returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
    select exists (
        select 1
        from public.sessions s
        join public.exams e on e.id = s.exam_id
        where s.id = sid and e.faculty_id = auth.uid()
    );
$$;

-- The first path segment of a storage object name, which by convention is the
-- session id: '<session-uuid>/selfie.jpg'.
create or replace function public.path_session(name text)
returns uuid
language plpgsql immutable as $$
begin
    return (split_part(name, '/', 1))::uuid;
exception
    -- A malformed path is simply not a session, rather than an error that would
    -- fail the whole policy evaluation.
    when others then return null;
end;
$$;


-- ---------------------------------------------------------------------------
-- New accounts
--
-- A profile row is created by trigger rather than by the client, so an account
-- can never exist without one, and a student cannot choose their own role at
-- signup. Role always starts as 'student'; faculty is granted by a human
-- running an UPDATE (see the comment on profiles.role).
-- ---------------------------------------------------------------------------

create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
    insert into public.profiles (id, full_name, campus_id)
    values (
        new.id,
        nullif(new.raw_user_meta_data ->> 'full_name', ''),
        nullif(new.raw_user_meta_data ->> 'campus_id', '')
    )
    on conflict (id) do nothing;
    return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
    after insert on auth.users
    for each row execute function public.handle_new_user();


-- ---------------------------------------------------------------------------
-- Transition guard
--
-- The one rule the whole approval gate rests on: a student cannot approve
-- themselves. RLS alone cannot say this, because a policy sees only the row
-- being written, and the rule is about the change — who is making it, and what
-- the status was before. So it lives in a trigger, which sees OLD and NEW.
--
-- Faculty decisions are stamped here too, rather than trusted from the client,
-- so decided_by can't be forged.
-- ---------------------------------------------------------------------------

create or replace function public.guard_session_update()
returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare
    acting_faculty boolean := exists (
        select 1 from public.exams e
        where e.id = old.exam_id and e.faculty_id = auth.uid()
    );
begin
    -- Nobody reassigns a session to a different student or a different exam.
    if new.student_id <> old.student_id or new.exam_id <> old.exam_id then
        raise exception 'a session cannot be moved to another student or exam';
    end if;

    if acting_faculty then
        if new.status <> old.status
           and new.status in ('approved', 'rejected', 'ended') then
            new.decided_at := coalesce(new.decided_at, now());
            new.decided_by := auth.uid();
        end if;
        return new;
    end if;

    -- Everyone else here is the student, by RLS. Their allowed moves:
    --   pending  -> pending   (attaching photos, consent, heartbeat)
    --   approved -> active    (the lockdown actually starting)
    --   active   -> ended     (a clean exit)
    if new.status <> old.status then
        if not ((old.status = 'pending'  and new.status = 'pending')
             or (old.status = 'approved' and new.status = 'active')
             or (old.status = 'active'   and new.status = 'ended')) then
            raise exception
                'a student cannot move a session from % to %', old.status, new.status;
        end if;
    end if;

    -- A rejected session is final until faculty deletes it. Without this, a
    -- student could keep writing heartbeats to a session they were refused.
    if old.status = 'rejected' then
        raise exception 'this session was rejected; ask the proctor to reset it';
    end if;

    -- The decision fields are the proctor's record, not the student's.
    new.decided_at    := old.decided_at;
    new.decided_by    := old.decided_by;
    new.reject_reason := old.reject_reason;

    return new;
end;
$$;

drop trigger if exists guard_session_update on public.sessions;
create trigger guard_session_update
    before update on public.sessions
    for each row execute function public.guard_session_update();


-- ---------------------------------------------------------------------------
-- Files are NOT deleted by deleting a session
--
-- Worth stating plainly, because it is the one place where the obvious thing does
-- not work. storage.objects cannot carry a foreign key to sessions, and a trigger
-- that deletes from it does not work either: Supabase guards that table with
-- storage.protect_delete(), so the delete raises and takes the whole session
-- delete down with it.
--
-- The guard is right. Removing a row from storage.objects only drops the metadata
-- — the actual file stays in the storage backend, orphaned where nothing can find
-- it. Deletion has to go through the Storage API, which removes both.
--
-- So it is the client's job, and the delete policies further down are what let it
-- happen: the dashboard deletes a student's files through the API before deleting
-- their session row, and purge.py does the same in bulk. session_files() below is
-- how either one finds out what to delete.
-- ---------------------------------------------------------------------------

create or replace function public.session_files(older_than_days int default 30)
returns table (bucket text, path text)
language sql stable security definer set search_path = public, pg_temp as $$
    -- Only for exams the caller proctors: this is called with a faculty token, and
    -- it must not become a way to enumerate the whole project's files.
    select b.bucket, s.id::text || '/' || b.name
    from   public.sessions s
    join   public.exams e on e.id = s.exam_id
    cross join (values ('identity', 'id.jpg'), ('identity', 'selfie.jpg'),
                       ('live', 'screen.jpg'), ('live', 'camera.jpg'))
               as b(bucket, name)
    where  e.faculty_id = auth.uid()
      and  s.requested_at < now() - make_interval(days => older_than_days)
    union all
    -- The kept snapshots. No fixed list of names to cross join here — however
    -- many were stored is however many rows there are, which is exactly why the
    -- table exists.
    select 'live'::text, sn.storage_path
    from   public.snapshots sn
    join   public.sessions s on s.id = sn.session_id
    join   public.exams e on e.id = s.exam_id
    where  e.faculty_id = auth.uid()
      and  s.requested_at < now() - make_interval(days => older_than_days);
$$;


-- ---------------------------------------------------------------------------
-- Exit codes, proctor accounts
--
-- All three run as security definer because each one needs to touch something
-- the caller cannot reach directly — that is the point of them.
-- ---------------------------------------------------------------------------

create extension if not exists pgcrypto;

-- Set (or change) an exam's exit code. Proctor of that exam only.
create or replace function public.set_exit_code(p_exam uuid, p_code text)
returns void
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
begin
    if not exists (select 1 from public.exams e
                   where e.id = p_exam and e.faculty_id = auth.uid()) then
        raise exception 'not your exam';
    end if;
    if p_code is null or length(btrim(p_code)) < 4 then
        raise exception 'an exit code needs at least 4 characters';
    end if;

    insert into public.exam_secrets (exam_id, exit_code_hash, updated_at)
    values (p_exam, crypt(btrim(p_code), gen_salt('bf')), now())
    on conflict (exam_id) do update
        set exit_code_hash = excluded.exit_code_hash, updated_at = now();
end;
$$;

-- Answer whether a typed code is this exam's exit code. Returns a boolean and
-- nothing else, so the hash never leaves the database.
--
-- Restricted to people already involved in the exam: the student sitting it, or
-- its proctor. Without that, any signed-in account could sit and guess at every
-- exam in the project.
create or replace function public.verify_exit_code(p_exam uuid, p_code text)
returns boolean
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare
    allowed boolean;
    stored  text;
begin
    select exists (
        select 1 from public.sessions s
        where s.exam_id = p_exam and s.student_id = auth.uid()
    ) or exists (
        select 1 from public.exams e
        where e.id = p_exam and e.faculty_id = auth.uid()
    ) into allowed;

    if not allowed then
        raise exception 'not your exam';
    end if;

    select exit_code_hash into stored
    from public.exam_secrets where exam_id = p_exam;

    -- No exit code set for this exam is a "no", not an error: the lockdown falls
    -- back to the machine's local passcode, so a student is never trapped.
    if stored is null then
        return false;
    end if;
    return stored = crypt(btrim(p_code), stored);
end;
$$;

-- Whether an exam has an exit code at all. The student's app asks this so it can
-- tell the student who to fetch, rather than silently rejecting what they type.
create or replace function public.has_exit_code(p_exam uuid)
returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
    select exists (select 1 from public.exam_secrets where exam_id = p_exam);
$$;

-- Promote an existing account to proctor. Faculty only — this is the one action
-- that hands someone the ability to see every student's identity documents, so
-- it deliberately cannot be reached by a student, and cannot create an account
-- (the dashboard registers it through the normal signup first).
create or replace function public.promote_to_faculty(p_email text)
returns text
language plpgsql security definer set search_path = public, auth, pg_temp as $$
declare
    target uuid;
begin
    if not public.is_faculty() then
        raise exception 'only a proctor can add another proctor';
    end if;

    select id into target from auth.users where lower(email) = lower(btrim(p_email));
    if target is null then
        raise exception 'no account exists for %', p_email;
    end if;

    update public.profiles set role = 'faculty' where id = target;
    return p_email;
end;
$$;

revoke all on function public.set_exit_code(uuid, text)      from anon;
revoke all on function public.verify_exit_code(uuid, text)   from anon;
revoke all on function public.promote_to_faculty(text)       from anon;


-- ---------------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------------

alter table public.profiles     enable row level security;
alter table public.exams        enable row level security;
alter table public.exam_secrets enable row level security;
alter table public.sessions    enable row level security;
alter table public.live_frames enable row level security;
alter table public.snapshots   enable row level security;
alter table public.events      enable row level security;

-- Re-runnable: drop before create.
drop policy if exists profiles_read_self       on public.profiles;
drop policy if exists profiles_read_faculty    on public.profiles;
drop policy if exists profiles_update_self     on public.profiles;
drop policy if exists exams_read_open          on public.exams;
drop policy if exists secrets_owner_all         on public.exam_secrets;
drop policy if exists exams_owner_all          on public.exams;
drop policy if exists sessions_student_insert  on public.sessions;
drop policy if exists sessions_student_read    on public.sessions;
drop policy if exists sessions_student_update  on public.sessions;
drop policy if exists sessions_faculty_read    on public.sessions;
drop policy if exists sessions_faculty_update  on public.sessions;
drop policy if exists sessions_faculty_delete  on public.sessions;
drop policy if exists frames_student_write     on public.live_frames;
drop policy if exists frames_student_update    on public.live_frames;
drop policy if exists frames_read              on public.live_frames;
drop policy if exists snapshots_student_insert on public.snapshots;
drop policy if exists snapshots_read           on public.snapshots;
drop policy if exists snapshots_faculty_delete on public.snapshots;
drop policy if exists events_student_insert    on public.events;
drop policy if exists events_read              on public.events;

-- profiles ------------------------------------------------------------------

create policy profiles_read_self on public.profiles
    for select using (id = auth.uid());

-- Faculty can see every profile: they need the name and campus ID of whoever is
-- asking to be let in.
create policy profiles_read_faculty on public.profiles
    for select using (public.is_faculty());

-- Note the with-check on role: a student may fix their own name, but cannot
-- promote themselves to faculty.
create policy profiles_update_self on public.profiles
    for update using (id = auth.uid())
    with check (
        id = auth.uid()
        and role = (select role from public.profiles where id = auth.uid())
    );

-- exams ---------------------------------------------------------------------

-- Any signed-in user can read open exams, which is how a student resolves a
-- join code into an exam. Closed exams disappear from view.
create policy exams_read_open on public.exams
    for select using (is_open or faculty_id = auth.uid());

create policy exams_owner_all on public.exams
    for all using (faculty_id = auth.uid() and public.is_faculty())
    with check (faculty_id = auth.uid() and public.is_faculty());

-- exam_secrets -------------------------------------------------------------

-- Only the owning proctor, and even they get the hash rather than the code.
-- There is deliberately no student-facing policy here: a student's app learns
-- whether a typed code is right by calling verify_exit_code(), never by reading.
create policy secrets_owner_all on public.exam_secrets
    for all using (
        exists (select 1 from public.exams e
                where e.id = exam_id and e.faculty_id = auth.uid())
    )
    with check (
        exists (select 1 from public.exams e
                where e.id = exam_id and e.faculty_id = auth.uid())
    );

-- sessions ------------------------------------------------------------------

-- A student may only create a pending session for themselves, on an open exam.
-- Forcing status to 'pending' here is what stops a student from inserting a row
-- that is already 'approved'.
create policy sessions_student_insert on public.sessions
    for insert with check (
        student_id = auth.uid()
        and status = 'pending'
        and exists (select 1 from public.exams e where e.id = exam_id and e.is_open)
    );

create policy sessions_student_read on public.sessions
    for select using (student_id = auth.uid());

-- The student app updates its own row to attach photos, record consent,
-- heartbeat, and move approved -> active -> ended. It can never grant itself
-- approval — but that rule is enforced by the guard_session_update trigger
-- below, not here. A policy can only see the NEW row, and "did the status change
-- in a way this user is allowed to make" is a question about OLD *and* NEW.
create policy sessions_student_update on public.sessions
    for update using (student_id = auth.uid())
    with check (student_id = auth.uid());

create policy sessions_faculty_read on public.sessions
    for select using (
        exists (select 1 from public.exams e
                where e.id = exam_id and e.faculty_id = auth.uid())
    );

create policy sessions_faculty_update on public.sessions
    for update using (
        exists (select 1 from public.exams e
                where e.id = exam_id and e.faculty_id = auth.uid())
    )
    with check (
        exists (select 1 from public.exams e
                where e.id = exam_id and e.faculty_id = auth.uid())
    );

-- Deleting a session is how faculty lets a rejected student try again.
create policy sessions_faculty_delete on public.sessions
    for delete using (
        exists (select 1 from public.exams e
                where e.id = exam_id and e.faculty_id = auth.uid())
    );

-- live_frames ---------------------------------------------------------------

create policy frames_student_write on public.live_frames
    for insert with check (public.owns_session(session_id));

create policy frames_student_update on public.live_frames
    for update using (public.owns_session(session_id))
    with check (public.owns_session(session_id));

create policy frames_read on public.live_frames
    for select using (
        public.owns_session(session_id) or public.proctors_session(session_id)
    );

-- snapshots -----------------------------------------------------------------
-- Insert only, for the student: a kept frame that could be edited or removed by
-- the person being watched would not be worth keeping. Deleting them is the
-- proctor's job, and happens when the exam goes.

create policy snapshots_student_insert on public.snapshots
    for insert with check (public.owns_session(session_id));

create policy snapshots_read on public.snapshots
    for select using (
        public.owns_session(session_id) or public.proctors_session(session_id)
    );

create policy snapshots_faculty_delete on public.snapshots
    for delete using (public.proctors_session(session_id));

-- events --------------------------------------------------------------------

create policy events_student_insert on public.events
    for insert with check (public.owns_session(session_id));

create policy events_read on public.events
    for select using (
        public.owns_session(session_id) or public.proctors_session(session_id)
    );


-- ---------------------------------------------------------------------------
-- Storage
--
-- Two private buckets. Nothing here is public: the dashboard reads images
-- through signed URLs that expire, so a leaked image link is not a permanent
-- window into someone's identity documents.
--
--   identity/<session-id>/id.jpg      photo of the physical student ID
--   identity/<session-id>/selfie.jpg  photo of the person holding it
--   live/<session-id>/screen.jpg      newest screen thumbnail, overwritten
--   live/<session-id>/camera.jpg      newest webcam thumbnail, overwritten
--   live/<session-id>/snap/<ms>-<kind>.jpg   kept snapshots, never overwritten
--
-- The snapshots sit under the same session-id prefix on purpose: every storage
-- policy below decides by the first path segment, so kept frames inherit exactly
-- the same access rules as the live ones without a policy of their own.
-- ---------------------------------------------------------------------------

insert into storage.buckets (id, name, public)
values ('identity', 'identity', false), ('live', 'live', false)
on conflict (id) do update set public = false;

drop policy if exists identity_student_write on storage.objects;
drop policy if exists identity_read          on storage.objects;
drop policy if exists identity_delete        on storage.objects;
drop policy if exists live_student_write     on storage.objects;
drop policy if exists live_student_update    on storage.objects;
drop policy if exists live_read              on storage.objects;
drop policy if exists live_delete            on storage.objects;

create policy identity_student_write on storage.objects
    for insert with check (
        bucket_id = 'identity' and public.owns_session(public.path_session(name))
    );

create policy identity_read on storage.objects
    for select using (
        bucket_id = 'identity'
        and (public.owns_session(public.path_session(name))
             or public.proctors_session(public.path_session(name)))
    );

-- The live thumbnail is overwritten in place every few seconds, so the student
-- needs update as well as insert on its own path.
create policy live_student_write on storage.objects
    for insert with check (
        bucket_id = 'live' and public.owns_session(public.path_session(name))
    );

create policy live_student_update on storage.objects
    for update using (
        bucket_id = 'live' and public.owns_session(public.path_session(name))
    )
    with check (
        bucket_id = 'live' and public.owns_session(public.path_session(name))
    );

create policy live_read on storage.objects
    for select using (
        bucket_id = 'live'
        and (public.owns_session(public.path_session(name))
             or public.proctors_session(public.path_session(name)))
    );

-- Delete, for both buckets. Needed because nothing in the database can clean these
-- up (see the note above): the proctor's dashboard and purge.py remove them through
-- the Storage API, and the API applies these policies. The owning student may also
-- delete their own, so a retake is not blocked by a file that already exists.
create policy identity_delete on storage.objects
    for delete using (
        bucket_id = 'identity'
        and (public.owns_session(public.path_session(name))
             or public.proctors_session(public.path_session(name)))
    );

create policy live_delete on storage.objects
    for delete using (
        bucket_id = 'live'
        and (public.owns_session(public.path_session(name))
             or public.proctors_session(public.path_session(name)))
    );


-- ---------------------------------------------------------------------------
-- Retention
--
-- ID photos and selfies are identity documents belonging to real students, and
-- keeping them forever is the wrong default.
--
-- Use purge.py, not this function on its own. The files have to go through the
-- Storage API first (see the note above); this only removes the rows, and calling
-- it by itself would strand every image it was supposed to account for:
--
--     uv run --script server/purge.py --days 30
--
-- That lists the files with session_files(), deletes them through the API, then
-- calls this to drop the rows. Frames and events cascade with the sessions.
-- ---------------------------------------------------------------------------

create or replace function public.purge_old_sessions(older_than_days int default 30)
returns integer
language plpgsql security definer set search_path = public, pg_temp as $$
declare
    removed integer;
begin
    -- Scoped to the caller's own exams, like session_files(), so a purge cannot
    -- reach another proctor's sessions.
    with gone as (
        delete from public.sessions s
        using public.exams e
        where e.id = s.exam_id
          and e.faculty_id = auth.uid()
          and s.requested_at < now() - make_interval(days => older_than_days)
        returning 1
    )
    select count(*) into removed from gone;

    return removed;
end;
$$;
