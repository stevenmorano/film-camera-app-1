-- Core data. Client writes are granted explicitly in the next migration.
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
alter default privileges in schema private revoke execute on functions from public;

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default 'Film Friend'
    check (length(btrim(display_name)) between 1 and 80),
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp()
);

create table public.rolls (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles(id),
  name text not null check (length(btrim(name)) between 1 and 100),
  total_exposures integer not null default 32 check (total_exposures between 1 and 256),
  exposures_used integer not null default 0,
  status text not null default 'active' check (status in ('active', 'developing', 'developed')),
  created_at timestamptz not null default clock_timestamp(),
  finish_requested_at timestamptz,
  finished_at timestamptz,
  develops_at timestamptz,
  developed_at timestamptz,
  development_speed text not null default 'standard_7d',
  development_seconds integer not null default 604800,
  roll_type text not null default 'shared' check (roll_type in ('personal', 'shared')),
  exposure_mode text not null default 'shared_pool' check (exposure_mode = 'shared_pool'),
  max_members integer not null default 4 check (max_members between 1 and 64),
  constraint roll_capacity check (exposures_used between 0 and total_exposures),
  constraint roll_development_speed check (
    (development_speed = 'standard_7d' and development_seconds = 604800)
    or (development_speed = 'test_30s' and development_seconds = 30)
    or (development_speed = 'test_5m' and development_seconds = 300)
    or (development_speed = 'test_1h' and development_seconds = 3600)
  ),
  constraint roll_lifecycle check (
    (status = 'active' and finished_at is null and develops_at is null and developed_at is null)
    or (status = 'developing' and finished_at is not null and develops_at is not null
      and developed_at is null)
    or (status = 'developed' and finished_at is not null and develops_at is not null
      and developed_at is not null and developed_at >= develops_at)
  ),
  constraint roll_deadline check (
    develops_at is null or develops_at = finished_at + make_interval(secs => development_seconds)
  )
);

create table public.roll_members (
  roll_id uuid not null references public.rolls(id),
  user_id uuid not null references public.profiles(id),
  role text not null default 'member' check (role in ('owner', 'member')),
  joined_at timestamptz not null default clock_timestamp(),
  removed_at timestamptz,
  exposure_allowance integer check (exposure_allowance >= 0),
  exposures_used integer not null default 0 check (exposures_used >= 0),
  primary key (roll_id, user_id),
  constraint member_allowance check (exposure_allowance is null or exposures_used <= exposure_allowance)
);
create index roll_members_user_idx on public.roll_members(user_id, roll_id) where removed_at is null;
create unique index roll_one_owner_idx on public.roll_members(roll_id) where role = 'owner';

create table public.exposure_claims (
  id uuid primary key default gen_random_uuid(),
  roll_id uuid not null references public.rolls(id),
  photographer_id uuid not null,
  request_id uuid not null,
  exposure_number integer not null check (exposure_number > 0),
  storage_path text not null unique,
  state text not null default 'pending' check (state in ('pending', 'stored', 'missing')),
  claimed_at timestamptz not null default clock_timestamp(),
  stored_at timestamptz,
  foreign key (roll_id, photographer_id) references public.roll_members(roll_id, user_id),
  unique (roll_id, exposure_number),
  unique (photographer_id, request_id),
  unique (id, roll_id, photographer_id, exposure_number, storage_path),
  constraint claim_path check (storage_path = roll_id::text || '/' || id::text || '.jpg'),
  constraint claim_storage_state check (
    (state = 'stored' and stored_at is not null)
    or (state in ('pending', 'missing') and stored_at is null)
  )
);
create index exposure_claims_pending_idx on public.exposure_claims(roll_id) where state = 'pending';

create table public.film_photos (
  id uuid primary key default gen_random_uuid(),
  claim_id uuid not null unique,
  roll_id uuid not null references public.rolls(id),
  photographer_id uuid not null references public.profiles(id),
  storage_path text not null unique,
  captured_at timestamptz not null,
  exposure_number integer not null,
  created_at timestamptz not null default clock_timestamp(),
  unique (roll_id, exposure_number),
  foreign key (claim_id, roll_id, photographer_id, exposure_number, storage_path)
    references public.exposure_claims(id, roll_id, photographer_id, exposure_number, storage_path)
);
create index film_photos_photographer_idx on public.film_photos(photographer_id);

create table public.invitations (
  id uuid primary key default gen_random_uuid(),
  roll_id uuid not null references public.rolls(id),
  created_by uuid not null references public.profiles(id),
  code_hash text not null unique check (code_hash ~ '^[0-9a-f]{64}$'),
  expires_at timestamptz not null,
  max_uses integer not null default 3 check (max_uses > 0),
  uses_count integer not null default 0 check (uses_count between 0 and max_uses),
  revoked_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  check (expires_at > created_at)
);
create index invitations_roll_idx on public.invitations(roll_id);
create index invitations_creator_idx on public.invitations(created_by);
create index rolls_owner_idx on public.rolls(owner_id);

-- Only an administrator can enable the optional development mechanism.
create table private.project_settings (
  singleton boolean primary key default true check (singleton),
  is_development boolean not null default false
);
insert into private.project_settings(singleton, is_development) values (true, false);
alter table private.project_settings enable row level security;
revoke all on private.project_settings from public, anon, authenticated, service_role;

create function private.guard_development_speed() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.development_seconds <> 604800
    and not coalesce((select s.is_development from private.project_settings s where s.singleton), false)
  then
    raise exception using errcode = '42501', message = 'Test development speeds are disabled in this project.';
  end if;
  return new;
end;
$$;
create trigger guard_development_speed before insert or update of development_seconds, development_speed
  on public.rolls for each row execute function private.guard_development_speed();

create function private.guard_exposure_capacity() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_capacity integer;
begin
  select r.total_exposures into v_capacity from public.rolls r where r.id = new.roll_id;
  if tg_table_name = 'exposure_claims' then
    if new.exposure_number > v_capacity then
      raise exception using errcode = '23514', message = 'Exposure number exceeds roll capacity.';
    end if;
  elsif new.exposures_used > v_capacity then
    raise exception using errcode = '23514', message = 'Member counter exceeds roll capacity.';
  end if;
  return new;
end;
$$;
create trigger guard_claim_capacity before insert or update on public.exposure_claims
  for each row execute function private.guard_exposure_capacity();
create trigger guard_member_capacity before insert or update on public.roll_members
  for each row execute function private.guard_exposure_capacity();

create function private.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles(id, display_name)
  values (new.id, coalesce(nullif(left(btrim(new.raw_user_meta_data ->> 'display_name'), 80), ''), 'Film Friend'));
  return new;
end;
$$;
create trigger film_profile_on_signup after insert on auth.users
  for each row execute function private.handle_new_user();
insert into public.profiles(id, display_name)
select u.id, coalesce(nullif(left(btrim(u.raw_user_meta_data ->> 'display_name'), 80), ''), 'Film Friend')
from auth.users u on conflict (id) do nothing;

create function private.touch_profile() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.updated_at := pg_catalog.clock_timestamp();
  return new;
end;
$$;
create trigger film_profile_updated before update on public.profiles
  for each row execute function private.touch_profile();

alter table public.profiles enable row level security;
alter table public.rolls enable row level security;
alter table public.roll_members enable row level security;
alter table public.exposure_claims enable row level security;
alter table public.film_photos enable row level security;
alter table public.invitations enable row level security;
revoke all on public.profiles, public.rolls, public.roll_members, public.exposure_claims,
  public.film_photos, public.invitations from public, anon, authenticated;
revoke execute on all functions in schema private from public, anon, authenticated;
grant all on public.profiles, public.rolls, public.roll_members, public.exposure_claims,
  public.film_photos, public.invitations to service_role;
