-- Membership helpers bypass recursive RLS internally, never through an exposed definer RPC.
revoke create on schema public from public, anon, authenticated;
grant usage on schema private to authenticated, service_role;

create function private.is_member(p_roll_id uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select auth.uid() is not null and exists (
    select 1 from public.roll_members m
    where m.roll_id = p_roll_id and m.user_id = auth.uid() and m.removed_at is null
  );
$$;

create function private.may_read_profile(p_user_id uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select auth.uid() is not null and (p_user_id = auth.uid() or exists (
    select 1 from public.roll_members mine
    join public.roll_members theirs on theirs.roll_id = mine.roll_id
    where mine.user_id = auth.uid() and mine.removed_at is null
      and theirs.user_id = p_user_id and theirs.removed_at is null
  ));
$$;

create function private.may_view_roll(p_roll_id uuid) returns boolean
language sql volatile security definer set search_path = '' as $$
  select private.is_member(p_roll_id) and exists (
    select 1 from public.rolls r where r.id = p_roll_id and r.status = 'developed'
      and r.develops_at is not null and pg_catalog.clock_timestamp() >= r.develops_at
  );
$$;

create function private.claim_is_stored(p_claim_id uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.exposure_claims c
    where c.id = p_claim_id and c.state = 'stored' and private.is_member(c.roll_id));
$$;

grant select on public.profiles, public.rolls, public.roll_members, public.film_photos to authenticated;
grant update (display_name) on public.profiles to authenticated;
grant select (id, roll_id, created_by, expires_at, max_uses, uses_count, revoked_at, created_at)
  on public.invitations to authenticated;

create policy profiles_visible on public.profiles for select to authenticated
  using (private.may_read_profile(id));
create policy profile_name_edit on public.profiles for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));
create policy member_roll_read on public.rolls for select to authenticated
  using (private.is_member(id));
create policy member_list_read on public.roll_members for select to authenticated
  using (private.is_member(roll_id));
create policy developed_photo_read on public.film_photos for select to authenticated
  using (private.may_view_roll(roll_id) and private.claim_is_stored(claim_id));
create policy owner_invitation_metadata on public.invitations for select to authenticated
  using (private.is_member(roll_id) and created_by = (select auth.uid())
    and exists (select 1 from public.rolls r where r.id = roll_id and r.owner_id = (select auth.uid())));

create function private.create_roll(p_name text, p_total_exposures integer, p_roll_type text)
returns public.rolls language plpgsql security definer set search_path = '' as $$
declare v_user uuid := auth.uid(); v_roll public.rolls;
begin
  if v_user is null then
    raise exception using errcode = '28000', message = 'Authentication required.';
  end if;
  if p_name is null or length(btrim(p_name)) not between 1 and 100
    or p_total_exposures is null or p_total_exposures not between 1 and 256
    or p_roll_type is null or p_roll_type not in ('personal', 'shared') then
    raise exception using errcode = '22023', message = 'Invalid roll settings.';
  end if;
  if not exists (select 1 from public.profiles p where p.id = v_user) then
    raise exception using errcode = '42501', message = 'A registered profile is required.';
  end if;
  insert into public.rolls(owner_id, name, total_exposures, roll_type, max_members)
  values (v_user, btrim(p_name), p_total_exposures, p_roll_type,
    case when p_roll_type = 'personal' then 1 else 4 end) returning * into v_roll;
  insert into public.roll_members(roll_id, user_id, role) values (v_roll.id, v_user, 'owner');
  return v_roll;
end;
$$;

create function private.claim_exposure(p_roll_id uuid, p_request_id uuid)
returns public.exposure_claims language plpgsql security definer set search_path = '' as $$
declare v_user uuid := auth.uid(); v_roll public.rolls; v_claim public.exposure_claims;
  v_claim_id uuid := pg_catalog.gen_random_uuid();
begin
  if v_user is null then
    raise exception using errcode = '28000', message = 'Authentication required.';
  end if;
  if p_roll_id is null or p_request_id is null then
    raise exception using errcode = '22023', message = 'Roll and request UUIDs are required.';
  end if;
  -- Serialize the global user/request key, even if incorrectly reused across different rolls.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_user::text || ':' || p_request_id::text, 0));
  select * into v_roll from public.rolls r where r.id = p_roll_id for update;
  if not found then
    raise exception using errcode = '42501', message = 'Roll membership required.';
  end if;
  perform 1 from public.roll_members m where m.roll_id = p_roll_id
    and m.user_id = v_user and m.removed_at is null for update;
  if not found then
    raise exception using errcode = '42501', message = 'Roll membership required.';
  end if;
  select * into v_claim from public.exposure_claims c
    where c.photographer_id = v_user and c.request_id = p_request_id;
  if found then
    if v_claim.roll_id <> p_roll_id then
      raise exception using errcode = '22023', message = 'Request UUID belongs to a different roll.';
    end if;
    return v_claim;
  end if;
  if v_roll.status <> 'active' or v_roll.finish_requested_at is not null then
    raise exception using errcode = '55000', message = 'Roll is not accepting exposures.';
  end if;
  if v_roll.exposure_mode <> 'shared_pool' then
    raise exception using errcode = '55000', message = 'Exposure mode is not supported.';
  end if;
  if v_roll.exposures_used >= v_roll.total_exposures then
    raise exception using errcode = 'P0001', message = 'No exposures remain.';
  end if;
  insert into public.exposure_claims(id, roll_id, photographer_id, request_id, exposure_number, storage_path)
  values (v_claim_id, p_roll_id, v_user, p_request_id, v_roll.exposures_used + 1,
    p_roll_id::text || '/' || v_claim_id::text || '.jpg') returning * into v_claim;
  update public.rolls set exposures_used = exposures_used + 1 where id = p_roll_id;
  update public.roll_members set exposures_used = exposures_used + 1
    where roll_id = p_roll_id and user_id = v_user and removed_at is null;
  return v_claim;
end;
$$;

-- Internal operation. Callers must already hold the roll row lock.
create function private.start_development_if_ready(p_roll_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_started timestamptz := pg_catalog.clock_timestamp();
begin
  update public.rolls r set status = 'developing', finished_at = v_started,
    develops_at = v_started + pg_catalog.make_interval(secs => r.development_seconds)
  where r.id = p_roll_id and r.status = 'active'
    and (r.exposures_used = r.total_exposures or r.finish_requested_at is not null)
    and not exists (select 1 from public.exposure_claims c where c.roll_id = r.id and c.state = 'pending');
end;
$$;

-- Service-only: a future Edge Function must validate the caller before invoking this.
-- Inspect Storage metadata only. Never write to storage.objects from application SQL.
create function private.confirm_exposure(p_claim_id uuid, p_captured_at timestamptz)
returns public.film_photos language plpgsql security definer set search_path = '' as $$
declare v_claim public.exposure_claims; v_photo public.film_photos; v_roll_id uuid;
begin
  if p_claim_id is null or p_captured_at is null then
    raise exception using errcode = '22023', message = 'Claim and capture timestamp are required.';
  end if;
  select c.roll_id into v_roll_id from public.exposure_claims c where c.id = p_claim_id;
  if not found then
    raise exception using errcode = '22023', message = 'Unknown exposure claim.';
  end if;
  perform 1 from public.rolls r where r.id = v_roll_id for update;
  select * into v_claim from public.exposure_claims c where c.id = p_claim_id for update;
  select * into v_photo from public.film_photos p where p.claim_id = p_claim_id;
  if found and v_claim.state = 'stored' then return v_photo; end if;
  if v_claim.state <> 'pending' then
    raise exception using errcode = '55000', message = 'Claim cannot be confirmed.';
  end if;
  if not exists (select 1 from storage.objects o
    where o.bucket_id = 'film-originals' and o.name = v_claim.storage_path) then
    raise exception using errcode = '55000', message = 'Storage upload has not been confirmed.';
  end if;
  update public.exposure_claims set state = 'stored', stored_at = pg_catalog.clock_timestamp() where id = p_claim_id;
  insert into public.film_photos(claim_id, roll_id, photographer_id, storage_path, captured_at, exposure_number)
  values (v_claim.id, v_claim.roll_id, v_claim.photographer_id, v_claim.storage_path,
    p_captured_at, v_claim.exposure_number) returning * into v_photo;
  perform private.start_development_if_ready(v_roll_id);
  return v_photo;
end;
$$;

create function private.finish_roll(p_roll_id uuid) returns public.rolls
language plpgsql security definer set search_path = '' as $$
declare v_user uuid := auth.uid(); v_roll public.rolls;
begin
  if v_user is null then raise exception using errcode = '28000', message = 'Authentication required.'; end if;
  select * into v_roll from public.rolls r where r.id = p_roll_id for update;
  if not found or v_roll.owner_id <> v_user then
    raise exception using errcode = '42501', message = 'Current roll owner required.';
  end if;
  perform 1 from public.roll_members m where m.roll_id = p_roll_id
    and m.user_id = v_user and m.removed_at is null for update;
  if not found then raise exception using errcode = '42501', message = 'Current roll owner required.'; end if;
  if v_roll.status <> 'active' then return v_roll; end if;
  if v_roll.exposures_used = 0 then
    raise exception using errcode = '55000', message = 'An empty roll cannot be sent to the lab.';
  end if;
  update public.rolls set finish_requested_at = coalesce(finish_requested_at, pg_catalog.clock_timestamp()) where id = p_roll_id;
  perform private.start_development_if_ready(p_roll_id);
  select * into v_roll from public.rolls r where r.id = p_roll_id;
  return v_roll;
end;
$$;

create function private.refresh_roll_status(p_roll_id uuid) returns public.rolls
language plpgsql security definer set search_path = '' as $$
declare v_roll public.rolls; v_now timestamptz;
begin
  if auth.uid() is null then raise exception using errcode = '28000', message = 'Authentication required.'; end if;
  select * into v_roll from public.rolls r where r.id = p_roll_id for update;
  if not found then
    raise exception using errcode = '42501', message = 'Roll membership required.';
  end if;
  perform 1 from public.roll_members m where m.roll_id = p_roll_id
    and m.user_id = auth.uid() and m.removed_at is null for update;
  if not found then raise exception using errcode = '42501', message = 'Roll membership required.'; end if;
  -- Read the wall clock AFTER any lock wait, not the transaction's starting timestamp.
  v_now := pg_catalog.clock_timestamp();
  if v_roll.status = 'developing' and v_roll.develops_at <= v_now then
    update public.rolls set status = 'developed', developed_at = v_now where id = p_roll_id returning * into v_roll;
  end if;
  return v_roll;
end;
$$;

create function public.create_roll(p_name text, p_total_exposures integer default 32, p_roll_type text default 'shared')
returns public.rolls language sql security invoker set search_path = '' as $$
  select * from private.create_roll(p_name, p_total_exposures, p_roll_type);
$$;
create function public.claim_exposure(p_roll_id uuid, p_request_id uuid)
returns public.exposure_claims language sql security invoker set search_path = '' as $$
  select * from private.claim_exposure(p_roll_id, p_request_id);
$$;
create function public.finish_roll(p_roll_id uuid) returns public.rolls
language sql security invoker set search_path = '' as $$ select * from private.finish_roll(p_roll_id); $$;
create function public.refresh_roll_status(p_roll_id uuid) returns public.rolls
language sql security invoker set search_path = '' as $$ select * from private.refresh_roll_status(p_roll_id); $$;
create function public.confirm_exposure(p_claim_id uuid, p_captured_at timestamptz) returns public.film_photos
language sql security invoker set search_path = '' as $$ select * from private.confirm_exposure(p_claim_id, p_captured_at); $$;

revoke execute on all functions in schema private from public, anon, authenticated, service_role;
grant execute on function private.is_member(uuid), private.may_read_profile(uuid),
  private.may_view_roll(uuid), private.claim_is_stored(uuid), private.create_roll(text, integer, text),
  private.claim_exposure(uuid, uuid), private.finish_roll(uuid), private.refresh_roll_status(uuid) to authenticated;
grant execute on function private.confirm_exposure(uuid, timestamptz) to service_role;
revoke all on function public.create_roll(text, integer, text), public.claim_exposure(uuid, uuid),
  public.finish_roll(uuid), public.refresh_roll_status(uuid), public.confirm_exposure(uuid, timestamptz)
  from public, anon, authenticated, service_role;
grant execute on function public.create_roll(text, integer, text), public.claim_exposure(uuid, uuid),
  public.finish_roll(uuid), public.refresh_roll_status(uuid) to authenticated;
grant execute on function public.confirm_exposure(uuid, timestamptz) to service_role;

comment on column public.rolls.exposures_used is 'Consumed slots, including pending uploads and missing frames; only backend functions write this counter.';
comment on function public.claim_exposure(uuid, uuid) is 'Authenticated member RPC. Idempotency is global per photographer; reusing a request UUID on another roll is rejected.';
