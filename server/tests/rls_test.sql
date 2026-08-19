-- ============================================================================
-- rls_test.sql — proves the access rules in schema.sql actually hold.
--
-- The whole proctoring design rests on one claim: a student in full control of
-- their own laptop, holding the anon key that ships inside the app, still cannot
-- admit themselves to an exam or see anyone else's data. This file tries to break
-- that claim thirteen different ways and expects to fail every time.
--
-- Run it with run_tests.sh. Everything happens inside one transaction that is
-- rolled back at the end, so it leaves no rows behind.
--
-- Reading the output: each ATTACK must be followed by an ERROR. A silent attack is
-- a failing test.
-- ============================================================================

\set ON_ERROR_STOP off
begin;

-- Supabase grants the authenticated role plain table access and lets the policies
-- do the deciding. Same here, or every test would pass for the wrong reason.
grant usage on schema public, storage to anon, authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;
grant select, insert, update, delete on storage.objects to authenticated;
grant usage, select on all sequences in schema public to authenticated;

-- Two students and one proctor. Profiles are not inserted here on purpose: the
-- signup trigger has to create them, and that it does is the first thing tested.
insert into auth.users (id, email, raw_user_meta_data) values
  ('11111111-1111-1111-1111-111111111111', 'prof@ucsd.edu',
   '{"full_name":"Prof Faculty","campus_id":"prof1"}'),
  ('22222222-2222-2222-2222-222222222222', 'stud@ucsd.edu',
   '{"full_name":"Stu Dent","campus_id":"A111"}'),
  ('33333333-3333-3333-3333-333333333333', 'other@ucsd.edu',
   '{"full_name":"Other Student","campus_id":"A222"}');

update public.profiles set role = 'faculty'
where id = '11111111-1111-1111-1111-111111111111';

\echo ''
\echo '### profiles created by the signup trigger, everyone a student by default:'
select campus_id, role from public.profiles order by campus_id;

-- From here on, act as a normal signed-in user rather than the table owner.
set role authenticated;

\echo ''
\echo '### faculty creates an exam'
set test.uid = '11111111-1111-1111-1111-111111111111';
insert into public.exams (id, faculty_id, title, allowed_url, join_code)
values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
        '11111111-1111-1111-1111-111111111111', 'Midterm',
        'https://exam.ucsd.edu/', 'MID24');
\echo '    PASS'

\echo ''
\echo '### student joins, landing as pending'
set test.uid = '22222222-2222-2222-2222-222222222222';
insert into public.sessions (id, exam_id, student_id, status)
values ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
        'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
        '22222222-2222-2222-2222-222222222222', 'pending');
\echo '    PASS'

\echo ''
\echo '### ATTACK 1 — insert a session that is already approved'
savepoint a; insert into public.sessions (exam_id, student_id, status)
  values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
          '22222222-2222-2222-2222-222222222222', 'approved');
rollback to a;

\echo ''
\echo '### ATTACK 2 — approve my own pending session'
savepoint b; update public.sessions set status = 'approved'
  where id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
rollback to b;

\echo ''
\echo '### ATTACK 3 — promote myself to faculty'
savepoint c; update public.profiles set role = 'faculty'
  where id = '22222222-2222-2222-2222-222222222222';
rollback to c;

\echo ''
\echo '### ATTACK 4 — forge the proctor decision fields (must come back null)'
update public.sessions
set    decided_by = '22222222-2222-2222-2222-222222222222',
       reject_reason = 'approved by me', heartbeat_at = now()
where  id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
select coalesce(decided_by::text, 'null') as decided_by,
       coalesce(reject_reason, 'null')    as reject_reason
from   public.sessions where id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';

\echo ''
\echo '### ATTACK 5 — a different student reads that session (must be 0)'
set test.uid = '33333333-3333-3333-3333-333333333333';
select count(*) as sessions_visible from public.sessions;

\echo ''
\echo '### faculty approves — decision fields stamped by the database'
set test.uid = '11111111-1111-1111-1111-111111111111';
update public.sessions set status = 'approved'
where id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
select status,
       decided_by = '11111111-1111-1111-1111-111111111111' as stamped_to_faculty,
       decided_at is not null                              as decided_at_set
from   public.sessions where id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';

\echo ''
\echo '### student moves approved -> active, which is the one step they may take'
set test.uid = '22222222-2222-2222-2222-222222222222';
update public.sessions set status = 'active', started_at = now()
where id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
select status from public.sessions where id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';

\echo ''
\echo '### ATTACK 6 — walk backwards from active to approved'
savepoint d; update public.sessions set status = 'approved'
  where id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
rollback to d;

\echo ''
\echo '### student publishes a frame and an event for their own session'
insert into public.live_frames (session_id, kind, storage_path)
values ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'screen',
        'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb/screen.jpg')
on conflict (session_id, kind) do update set captured_at = now();
insert into public.events (session_id, kind)
values ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'upload.start');
\echo '    PASS'

\echo ''
\echo '### ATTACK 7 — upload into someone else''s storage folder'
savepoint e; insert into storage.objects (bucket_id, name)
  values ('live', '99999999-9999-9999-9999-999999999999/screen.jpg');
rollback to e;

\echo ''
\echo '### student uploads under their own session id'
insert into storage.objects (bucket_id, name) values
  ('live',     'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb/screen.jpg'),
  ('identity', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb/id.jpg');
\echo '    PASS'

\echo ''
\echo '### the proctor of this exam can read both (expect 1 frame, 2 objects)'
set test.uid = '11111111-1111-1111-1111-111111111111';
select count(*) as frames_visible  from public.live_frames;
select count(*) as objects_visible from storage.objects;

\echo ''
\echo '### ATTACK 8 — an unrelated student reads them (both must be 0)'
set test.uid = '33333333-3333-3333-3333-333333333333';
select count(*) as frames_visible  from public.live_frames;
select count(*) as objects_visible from storage.objects;

\echo ''
\echo '### the student keeps a frame of their own session'
set test.uid = '22222222-2222-2222-2222-222222222222';
insert into public.snapshots (session_id, kind, storage_path)
values ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'screen',
        'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb/snap/1-screen.jpg');
\echo '    PASS'

\echo ''
\echo '### ATTACK 10 — another student reads those kept frames (must be 0)'
set test.uid = '33333333-3333-3333-3333-333333333333';
select count(*) as snapshots_visible from public.snapshots;

\echo ''
\echo '### ATTACK 11 — the student deletes a frame kept of them'
-- Kept frames are evidence about the person who is being watched, so the person
-- being watched must not be able to remove one. There is no student delete policy,
-- so this deletes nothing rather than raising — which is why it is checked by its
-- result, not by an error.
set test.uid = '22222222-2222-2222-2222-222222222222';
delete from public.snapshots
where session_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
select count(*) as snapshots_surviving from public.snapshots;

\echo ''
\echo '### the proctor of the exam can read them (expect 1)'
set test.uid = '11111111-1111-1111-1111-111111111111';
select count(*) as snapshots_visible from public.snapshots;

\echo ''
\echo '### the exam sets an exit code, and the student types it'
set test.uid = '11111111-1111-1111-1111-111111111111';
select public.set_exit_code('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'letmeout9') is null
       as code_set;
set test.uid = '22222222-2222-2222-2222-222222222222';
update public.sessions set status = 'active'
where id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
select public.verify_exit_code('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'letmeout9')
       as accepted;
-- The stamp is the whole point: it is what tells a proctor this session ended on
-- purpose rather than being force-quit.
-- Printed as a word, not a bare t: an earlier version of this test checked for
-- "^t$" and matched the *previous* query's output, so a stamp that never happened
-- passed for days.
select case when exit_verified_at is not null then 'STAMPED' else 'NOT-STAMPED' end
       as exit_stamp
from public.sessions where id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
\echo '    PASS'

\echo ''
\echo '### ATTACK 12 — the student stamps their own clean exit (must stay as it was)'
-- A wrong code leaves the stamp alone, and so does writing it by hand: a value the
-- student controls would say nothing about how the session really ended.
update public.sessions set exit_verified_at = now() + interval '1 hour'
where id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
select count(*) as forged_stamps from public.sessions
where id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
  and exit_verified_at > now() + interval '1 minute';

\echo ''
\echo '### ATTACK 13 — take a join code a live exam is already using'
-- Not an attack on a student's data; an attack on the one thing a room full of
-- people relies on being unambiguous. Two live exams answering to MID24 means half
-- the room joins the wrong one.
set test.uid = '11111111-1111-1111-1111-111111111111';
savepoint g; insert into public.exams (faculty_id, title, allowed_url, join_code)
  values ('11111111-1111-1111-1111-111111111111', 'Clashing exam',
          'https://exam.ucsd.edu/', 'MID24');
rollback to g;

\echo ''
\echo '### archiving the first one frees the code, and the second can have it'
update public.exams set archived_at = now(), is_open = false
where id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
insert into public.exams (faculty_id, title, allowed_url, join_code)
values ('11111111-1111-1111-1111-111111111111', 'Next quarter',
        'https://exam.ucsd.edu/', 'MID24');
select count(*) as exams_named_mid24 from public.exams where join_code = 'MID24';
\echo '    PASS'

\echo ''
\echo '### a refusal is final until the proctor resets it'
set test.uid = '11111111-1111-1111-1111-111111111111';
update public.sessions set status = 'rejected', reject_reason = 'ID unreadable'
where id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';

\echo ''
\echo '### ATTACK 9 — heartbeat a session that was refused'
set test.uid = '22222222-2222-2222-2222-222222222222';
savepoint f; update public.sessions set heartbeat_at = now()
  where id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
rollback to f;

reset role;
rollback;

\echo ''
\echo '============================================================'
\echo ' Attacks 1, 2, 3, 6, 7, 9 and 13 must each be followed by ERROR.'
\echo ' Attacks 4, 5, 8, 10, 11 and 12 are allowed to run and must have no'
\echo ' effect: 4 prints "null|null", 5 and 8 print 0.'
\echo ' Every PASS line must be present. run_tests.sh checks all'
\echo ' of that rather than leaving it to the eye.'
\echo '============================================================'
