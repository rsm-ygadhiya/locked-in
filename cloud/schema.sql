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
-- Row Level Security
-- ---------------------------------------------------------------------------

alter table public.profiles    enable row level security;
alter table public.exams       enable row level security;
alter table public.sessions    enable row level security;
alter table public.live_frames enable row level security;
alter table public.events      enable row level security;

-- Re-runnable: drop before create.
drop policy if exists profiles_read_self       on public.profiles;
drop policy if exists profiles_read_faculty    on public.profiles;
drop policy if exists profiles_update_self     on public.profiles;
drop policy if exists exams_read_open          on public.exams;
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
-- ---------------------------------------------------------------------------

insert into storage.buckets (id, name, public)
values ('identity', 'identity', false), ('live', 'live', false)
on conflict (id) do update set public = false;

drop policy if exists identity_student_write on storage.objects;
drop policy if exists identity_read          on storage.objects;
drop policy if exists live_student_write     on storage.objects;
drop policy if exists live_student_update    on storage.objects;
drop policy if exists live_read              on storage.objects;

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


-- ---------------------------------------------------------------------------
-- Retention
--
-- ID photos and selfies are identity documents belonging to real students, and
-- keeping them forever is the wrong default. Run this after grades are in, or
-- schedule it with pg_cron if the project has it enabled:
--
--     select public.purge_old_sessions(30);
--
-- It deletes the storage objects and the session rows (frames and events cascade).
-- ---------------------------------------------------------------------------

create or replace function public.purge_old_sessions(older_than_days int default 30)
returns integer
language plpgsql security definer set search_path = public, storage, pg_temp as $$
declare
    removed integer;
begin
    delete from storage.objects
    where bucket_id in ('identity', 'live')
      and public.path_session(name) in (
          select id from public.sessions
          where requested_at < now() - make_interval(days => older_than_days)
      );

    with gone as (
        delete from public.sessions
        where requested_at < now() - make_interval(days => older_than_days)
        returning 1
    )
    select count(*) into removed from gone;

    return removed;
end;
$$;

revoke all on function public.purge_old_sessions(int) from anon, authenticated;
