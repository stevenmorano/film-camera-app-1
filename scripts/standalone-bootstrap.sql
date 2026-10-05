-- Minimal Supabase SQL stand-ins for the disposable native PostgreSQL runner.
-- NEVER apply this file to a Supabase project or an existing database.
-- This checks real PostgreSQL grants/RLS/transactions, not GoTrue or Storage HTTP.
create role anon nologin;
create role authenticated nologin;
create role service_role nologin bypassrls;

create schema auth;
create schema storage;
grant usage on schema public, auth, storage to anon, authenticated, service_role;

create table auth.users (
  id uuid primary key,
  instance_id uuid,
  aud text,
  role text,
  email text unique,
  encrypted_password text,
  email_confirmed_at timestamptz,
  raw_app_meta_data jsonb not null default '{}',
  raw_user_meta_data jsonb not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  confirmation_token text,
  recovery_token text,
  email_change_token_new text,
  email_change text
);

create function auth.uid() returns uuid
language sql stable set search_path = pg_catalog as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'
  )::uuid;
$$;
revoke all on function auth.uid() from public;
grant execute on function auth.uid() to anon, authenticated, service_role;

-- Storage tags its database transactions with this operation setting. The SQL
-- stand-in checks the tag exactly; it does not implement any HTTP signing API.
create function storage.allow_only_operation(p_operation text) returns boolean
language sql stable set search_path = pg_catalog as $$
  select coalesce(
    nullif(regexp_replace(current_setting('storage.operation', true), '^storage[.]', ''), '')
      = nullif(regexp_replace(p_operation, '^storage[.]', ''), ''),
    false
  );
$$;
grant execute on function storage.allow_only_operation(text) to public;

create table storage.buckets (
  id text primary key,
  name text not null unique,
  public boolean not null default false,
  file_size_limit bigint,
  allowed_mime_types text[]
);
create table storage.objects (
  id uuid primary key default gen_random_uuid(),
  bucket_id text not null references storage.buckets(id),
  name text not null,
  owner uuid,
  owner_id text,
  metadata jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (bucket_id, name)
);
alter table storage.buckets enable row level security;
alter table storage.objects enable row level security;
-- Supabase's API roles have table privileges; policies authorize individual rows.
grant all on storage.buckets, storage.objects to anon, authenticated, service_role;
