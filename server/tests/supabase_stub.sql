-- ============================================================================
-- supabase_stub.sql — the parts of Supabase that schema.sql leans on.
--
-- Enough of auth and storage to run schema.sql against a plain local Postgres,
-- so the access rules can be tested without touching a real project. See
-- run_tests.sh.
--
-- This file is for testing only. Never run it against a Supabase project — it
-- would collide with the real auth and storage schemas.
-- ============================================================================

create extension if not exists pgcrypto;
create schema if not exists auth;
create schema if not exists storage;

-- Supabase's user table, reduced to the columns the signup trigger reads.
create table if not exists auth.users (
    id                 uuid primary key default gen_random_uuid(),
    email              text unique,
    raw_user_meta_data jsonb default '{}'::jsonb
);

-- In Supabase this reads the caller's JWT. Here it reads a session variable, so a
-- test can act as different people:  set test.uid = '<uuid>';
create or replace function auth.uid() returns uuid
language sql stable as $$
    select nullif(current_setting('test.uid', true), '')::uuid;
$$;

create table if not exists storage.buckets (
    id     text primary key,
    name   text not null,
    public boolean not null default false
);

create table if not exists storage.objects (
    id        uuid primary key default gen_random_uuid(),
    bucket_id text references storage.buckets (id),
    name      text not null,
    owner     uuid
);
alter table storage.objects enable row level security;

-- The two roles every Supabase request arrives as.
do $$ begin create role anon;          exception when duplicate_object then null; end $$;
do $$ begin create role authenticated; exception when duplicate_object then null; end $$;
