-- SQL-only TAP suite. Run against a disposable local Supabase database.
-- Every fixture and test helper is removed by ROLLBACK.
begin;

-- Exercise production duration authorization even if this disposable local
-- project was explicitly configured for developer fixtures. ROLLBACK restores it.
update private.project_settings
set is_development = false, project_environment = 'production'
where singleton;

create temporary table test_results (
  number integer generated always as identity,
  passed boolean not null,
  label text not null,
  detail text
);
create temporary table test_ids (key text primary key, id uuid not null);
create temporary table test_claims (like public.exposure_claims);
grant select, insert on pg_temp.test_ids to authenticated, anon, service_role;
grant select, insert on pg_temp.test_claims to authenticated, anon, service_role;

-- Only this helper is privileged. It records an already evaluated assertion;
-- it never evaluates supplied SQL or reads protected application data.
create function pg_temp.record_result(p_passed boolean, p_label text, p_detail text default null)
returns void language sql security definer set search_path = pg_catalog, pg_temp
as $function$
  insert into pg_temp.test_results (passed, label, detail)
  values (coalesce(p_passed, false), p_label, p_detail);
$function$;

create function pg_temp.expect_error(p_sql text, p_label text, p_state text default null)
returns void language plpgsql security invoker set search_path = pg_catalog, pg_temp
as $function$
declare v_state text; v_message text;
begin
  begin
    execute p_sql;
    -- Roll back an unexpected successful mutation before recording failure.
    raise exception using errcode = 'Z0001', message = 'statement unexpectedly succeeded';
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_message = message_text;
  end;
  perform pg_temp.record_result(
    v_state <> 'Z0001' and (p_state is null or v_state = p_state),
    p_label, format('SQLSTATE %s: %s', v_state, v_message)
  );
end;
$function$;

-- A forbidden UPDATE/DELETE may raise 42501 or affect zero rows under RLS.
-- Execute with the caller's privileges and always roll back any mutation.
create function pg_temp.expect_no_change(p_sql text, p_label text)
returns void language plpgsql security invoker set search_path = pg_catalog, pg_temp
as $function$
declare v_count bigint; v_state text; v_message text;
begin
  begin
    execute p_sql;
    get diagnostics v_count = row_count;
    raise exception using errcode = 'Z0001', message = 'rollback test statement';
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_message = message_text;
  end;
  perform pg_temp.record_result(
    v_state = '42501' or (v_state = 'Z0001' and v_count = 0),
    p_label, format('SQLSTATE %s; affected rows %s: %s', v_state, v_count, v_message)
  );
end;
$function$;

select pg_temp.record_result(
  (select project_environment = 'production' and not is_development
   from private.project_settings where singleton),
  'database suite marks its fixture as production before testing duration guards');

do $grant$
declare v_namespace text;
begin
  select n.nspname into v_namespace from pg_catalog.pg_namespace n
  where n.oid = pg_catalog.pg_my_temp_schema();
  execute format('grant usage on schema %I to authenticated, anon, service_role', v_namespace);
end;
$grant$;

insert into auth.users (id, aud, role, email, raw_app_meta_data, raw_user_meta_data)
values
  ('10000000-0000-0000-0000-000000000001', 'authenticated', 'authenticated', 'film-test-owner@example.invalid', '{}', '{"display_name":"Test owner"}'),
  ('10000000-0000-0000-0000-000000000002', 'authenticated', 'authenticated', 'film-test-member@example.invalid', '{}', '{"display_name":"Test member"}'),
  ('10000000-0000-0000-0000-000000000003', 'authenticated', 'authenticated', 'film-test-outsider@example.invalid', '{}', '{"display_name":"Test outsider"}');

select pg_temp.record_result(
  (select count(*) = 3 from public.profiles where id in (
    '10000000-0000-0000-0000-000000000001',
    '10000000-0000-0000-0000-000000000002',
    '10000000-0000-0000-0000-000000000003'
  )), 'auth signup creates profiles');
select pg_temp.record_result(
  (select not public from storage.buckets where id = 'film-originals'),
  'film-originals bucket is private');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000001', true);
select set_config('request.jwt.claim.role', 'authenticated', true);
insert into pg_temp.test_ids select 'active', r.id from public.create_roll('Active test roll') r;
insert into pg_temp.test_ids select 'capacity', r.id from public.create_roll('Capacity test roll') r;
insert into pg_temp.test_ids select 'release', r.id from public.create_roll('Release test roll', 1) r;
select pg_temp.record_result(
  (select count(*) = 1 from public.rolls where id = (select id from pg_temp.test_ids where key = 'active')),
  'owner can create a roll and read it');
select pg_temp.record_result(
  (select total_exposures = 32 and development_seconds = 604800 and exposure_mode = 'shared_pool'
   from public.rolls where id = (select id from pg_temp.test_ids where key = 'active')),
  'production roll defaults are 32 exposures and seven days in shared_pool mode');
select pg_temp.record_result(
  (select count(*) = 1 from public.roll_members where roll_id = (select id from pg_temp.test_ids where key = 'active')
    and user_id = auth.uid() and role = 'owner'),
  'roll creation adds owner membership atomically');
select pg_temp.expect_error(
  $$select public.create_roll('Invalid roll', 0)$$,
  'zero exposure capacity is rejected', '22023');
select pg_temp.expect_error(
  $$select public.create_roll('Invalid roll', 32, 'shared', 30)$$,
  'public create_roll accepts no client development duration', '42883');

reset role;
insert into public.roll_members (roll_id, user_id, role)
select id, '10000000-0000-0000-0000-000000000002', 'member'
from pg_temp.test_ids where key in ('active', 'release');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"10000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000002', true);
select pg_temp.record_result(
  (select count(*) = 1 from public.rolls where id = (select id from pg_temp.test_ids where key = 'active')),
  'current member can read their roll');
with claimed as (
  insert into pg_temp.test_claims
  select c.* from public.claim_exposure(
    (select id from pg_temp.test_ids where key = 'active'), '20000000-0000-0000-0000-000000000001') c
  returning id
)
insert into pg_temp.test_ids select 'active_claim', id from claimed;
select pg_temp.record_result(
  (select exposure_number = 1 and photographer_id = auth.uid() and state = 'pending'
   from pg_temp.test_claims where id = (select id from pg_temp.test_ids where key = 'active_claim')),
  'member can claim one exposure');
select pg_temp.expect_error(
  $$select * from public.exposure_claims where id = (select id from pg_temp.test_ids where key = 'active_claim')$$,
  'claim metadata is available only through the authorized claim RPC', '42501');
select pg_temp.record_result(
  (select id = (select id from pg_temp.test_ids where key = 'active_claim')
   from public.claim_exposure((select id from pg_temp.test_ids where key = 'active'),
     '20000000-0000-0000-0000-000000000001')),
  'duplicate request UUID returns the existing claim');
select pg_temp.record_result(
  (select exposures_used = 1 from public.rolls where id = (select id from pg_temp.test_ids where key = 'active')),
  'duplicate request UUID does not consume a second exposure');
select pg_temp.expect_error(
  $$select public.claim_exposure((select id from pg_temp.test_ids where key = 'release'), '20000000-0000-0000-0000-000000000001')$$,
  'reusing an idempotency UUID for another roll is rejected', '22023');

select set_config('storage.operation', 'storage.object.sign_upload_url', true);
select pg_temp.expect_error(
  $$insert into storage.objects (bucket_id, name, owner_id, metadata)
    select 'film-originals', storage_path, auth.uid()::text, '{"mimetype":"image/jpeg","size":128}'::jsonb
    from pg_temp.test_claims where id = (select id from pg_temp.test_ids where key = 'active_claim')$$,
  'pending upload cannot authorize minting a signed upload capability', '42501');
select set_config('storage.operation', 'storage.object.upload', true);
select pg_temp.expect_error(
  $$insert into storage.objects (bucket_id, name, owner_id) values ('film-originals', 'unclaimed.jpg', auth.uid()::text)$$,
  'unclaimed storage upload path is rejected', '42501');
insert into storage.objects (bucket_id, name, owner_id, metadata)
select 'film-originals', storage_path, auth.uid()::text, '{"mimetype":"image/jpeg","size":128}'::jsonb
from pg_temp.test_claims where id = (select id from pg_temp.test_ids where key = 'active_claim');
select pg_temp.record_result(true, 'photographer can upload at the exact pending claim path');
select pg_temp.record_result(
  (select count(*) = 0 from storage.objects where bucket_id = 'film-originals'),
  'photographer cannot list or SELECT active storage objects for download or signing');
select pg_temp.expect_error(
  $$select public.confirm_exposure((select id from pg_temp.test_ids where key = 'active_claim'), now())$$,
  'mobile client cannot call the trusted upload confirmation RPC', '42501');
select pg_temp.expect_error(
  $$select private.confirm_exposure((select id from pg_temp.test_ids where key = 'active_claim'), now())$$,
  'mobile client cannot bypass RPC restrictions through its private confirmer', '42501');
select pg_temp.expect_error(
  $$select private.start_development_if_ready((select id from pg_temp.test_ids where key = 'active'))$$,
  'mobile client cannot invoke the privileged development transition helper', '42501');

set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select set_config('request.jwt.claim.sub', '', true);
select set_config('request.jwt.claim.role', 'service_role', true);
insert into pg_temp.test_ids
select 'active_photo', p.id from public.confirm_exposure(
  (select id from pg_temp.test_ids where key = 'active_claim'), clock_timestamp()) p;
select pg_temp.record_result(
  (select id = (select id from pg_temp.test_ids where key = 'active_photo')
   from public.confirm_exposure((select id from pg_temp.test_ids where key = 'active_claim'), clock_timestamp())),
  'trusted confirmation is idempotent');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"10000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000002', true);
select set_config('request.jwt.claim.role', 'authenticated', true);
select pg_temp.record_result(
  (select count(*) = 0 from public.film_photos where roll_id = (select id from pg_temp.test_ids where key = 'active')),
  'photographer cannot read confirmed photo metadata while roll is active');
select pg_temp.expect_no_change(
  $$update public.rolls set exposures_used = 0 where id = (select id from pg_temp.test_ids where key = 'active')$$,
  'mobile client cannot decrement consumed exposures');
select pg_temp.expect_no_change(
  $$update public.exposure_claims set state = 'pending' where id = (select id from pg_temp.test_ids where key = 'active_claim')$$,
  'mobile client cannot change claim state');
select pg_temp.expect_no_change(
  $$delete from public.exposure_claims where id = (select id from pg_temp.test_ids where key = 'active_claim')$$,
  'mobile client cannot delete an exposure claim');
select pg_temp.expect_no_change(
  $$update public.film_photos set storage_path = 'replacement.jpg' where id = (select id from pg_temp.test_ids where key = 'active_photo')$$,
  'mobile client cannot rewrite a confirmed film photo storage path');
select pg_temp.expect_no_change(
  $$delete from public.film_photos where id = (select id from pg_temp.test_ids where key = 'active_photo')$$,
  'mobile client cannot delete a captured photo record');
select pg_temp.expect_no_change(
  $$update storage.objects set metadata = '{"size":1}'::jsonb where bucket_id = 'film-originals'$$,
  'mobile client cannot overwrite an active stored photo');
select pg_temp.expect_no_change(
  $$delete from storage.objects where bucket_id = 'film-originals'$$,
  'mobile client cannot delete an active stored photo');
select pg_temp.expect_error(
  $$select public.finish_roll((select id from pg_temp.test_ids where key = 'active'))$$,
  'member cannot finish a roll owned by another user', '42501');

select set_config('request.jwt.claims', '{"sub":"10000000-0000-0000-0000-000000000003","role":"authenticated"}', true);
select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000003', true);
select pg_temp.record_result(
  (select count(*) = 0 from public.rolls where id = (select id from pg_temp.test_ids where key = 'active')),
  'outsider cannot read a private roll');
select pg_temp.expect_error(
  $$select public.claim_exposure((select id from pg_temp.test_ids where key = 'active'), '20000000-0000-0000-0000-000000000099')$$,
  'outsider cannot claim an exposure', '42501');
select pg_temp.record_result(
  (select count(*) = 0 from public.film_photos where roll_id = (select id from pg_temp.test_ids where key = 'active'))
  and (select count(*) = 0 from storage.objects where bucket_id = 'film-originals'),
  'outsider cannot read active photo metadata or objects');
select pg_temp.expect_error(
  $$insert into storage.objects (bucket_id, name, owner_id)
    values ('film-originals',
      (select id::text from pg_temp.test_ids where key = 'active') || '/' ||
      (select id::text from pg_temp.test_ids where key = 'active_claim') || '.jpg', auth.uid()::text)$$,
  'outsider cannot upload into another photographer claim', '42501');

select set_config('request.jwt.claims', '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000001', true);
select pg_temp.record_result(
  (select count(*) = 0 from public.film_photos where roll_id = (select id from pg_temp.test_ids where key = 'active'))
  and (select count(*) = 0 from storage.objects where bucket_id = 'film-originals'),
  'roll owner has no early photo access override');
select pg_temp.expect_no_change(
  $$update public.rolls set status = 'developed' where id = (select id from pg_temp.test_ids where key = 'active')$$,
  'owner cannot directly change roll status');
select pg_temp.expect_no_change(
  $$update public.rolls set develops_at = now() - interval '1 day' where id = (select id from pg_temp.test_ids where key = 'active')$$,
  'owner cannot directly change development deadline');
select pg_temp.expect_no_change(
  $$update public.rolls set developed_at = now() where id = (select id from pg_temp.test_ids where key = 'active')$$,
  'owner cannot directly change developed timestamp');
select pg_temp.expect_no_change(
  $$update public.rolls set owner_id = '10000000-0000-0000-0000-000000000002' where id = (select id from pg_temp.test_ids where key = 'active')$$,
  'owner cannot directly transfer roll ownership');
select pg_temp.expect_no_change(
  $$update public.rolls set total_exposures = 99 where id = (select id from pg_temp.test_ids where key = 'active')$$,
  'owner cannot directly increase capacity after creation');
select pg_temp.expect_no_change(
  $$update public.rolls set development_seconds = 30 where id = (select id from pg_temp.test_ids where key = 'active')$$,
  'owner cannot directly shorten production development duration');
select pg_temp.expect_no_change(
  $$insert into public.roll_members (roll_id, user_id, role) select id, '10000000-0000-0000-0000-000000000003', 'member' from pg_temp.test_ids where key = 'active'$$,
  'owner cannot bypass invitation authorization with direct membership writes');
with claimed as (
  insert into pg_temp.test_claims
  select c.* from public.claim_exposure(
    (select id from pg_temp.test_ids where key = 'active'), '20000000-0000-0000-0000-000000000002') c
  returning id
)
insert into pg_temp.test_ids select 'unconfirmed_claim', id from claimed;
insert into storage.objects (bucket_id, name, owner_id, metadata)
select 'film-originals', storage_path, auth.uid()::text, '{"mimetype":"image/jpeg","size":128}'::jsonb
from pg_temp.test_claims where id = (select id from pg_temp.test_ids where key = 'unconfirmed_claim');
select pg_temp.record_result(
  (select status = 'active' and finish_requested_at is not null
   from public.finish_roll((select id from pg_temp.test_ids where key = 'active'))),
  'owner finish closes capture while pending uploads keep the roll active');
select pg_temp.expect_error(
  $$select public.claim_exposure((select id from pg_temp.test_ids where key = 'active'), '20000000-0000-0000-0000-000000000003')$$,
  'owner finish prevents new capture claims before development starts', '55000');

-- Fill one roll to exactly its production capacity. Real overlapping sessions
-- are covered separately; these tests cover the boundary and idempotency.
do $capacity$
begin
  for i in 1..31 loop
    perform public.claim_exposure(
      (select id from pg_temp.test_ids where key = 'capacity'),
      ('30000000-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid);
  end loop;
end;
$capacity$;
with claimed as (
  insert into pg_temp.test_claims
  select c.* from public.claim_exposure(
    (select id from pg_temp.test_ids where key = 'capacity'), '30000000-0000-0000-0000-000000000032') c
  returning id
)
insert into pg_temp.test_ids select 'last_claim', id from claimed;
select pg_temp.record_result(
  (select exposure_number = 32 from pg_temp.test_claims where id = (select id from pg_temp.test_ids where key = 'last_claim')),
  'the 32nd exposure succeeds');
select pg_temp.expect_error(
  $$select public.claim_exposure((select id from pg_temp.test_ids where key = 'capacity'), '30000000-0000-0000-0000-000000000033')$$,
  'the 33rd exposure fails', 'P0001');
select pg_temp.record_result(
  (select exposures_used = total_exposures and exposures_used = 32 from public.rolls
   where id = (select id from pg_temp.test_ids where key = 'capacity')),
  'failed over-capacity claim leaves counter at 32');
reset role;
select pg_temp.record_result(
  (select count(*) = 32 and count(distinct exposure_number) = 32 from public.exposure_claims
   where roll_id = (select id from pg_temp.test_ids where key = 'capacity')),
  'each consumed exposure has a unique exposure number');
set local role authenticated;
select pg_temp.record_result(
  (select id = (select id from pg_temp.test_ids where key = 'last_claim')
   from public.claim_exposure((select id from pg_temp.test_ids where key = 'capacity'),
     '30000000-0000-0000-0000-000000000032')),
  'retry of final claim succeeds after roll capacity is exhausted');

with claimed as (
  insert into pg_temp.test_claims
  select c.* from public.claim_exposure(
    (select id from pg_temp.test_ids where key = 'release'), '40000000-0000-0000-0000-000000000001') c
  returning id
)
insert into pg_temp.test_ids select 'release_claim', id from claimed;
select pg_temp.expect_error(
  $$select public.claim_exposure((select id from pg_temp.test_ids where key = 'release'), '40000000-0000-0000-0000-000000000002')$$,
  'pending last upload prevents another exposure claim', 'P0001');
insert into storage.objects (bucket_id, name, owner_id, metadata)
select 'film-originals', storage_path, auth.uid()::text, '{"mimetype":"image/jpeg","size":128}'::jsonb
from pg_temp.test_claims where id = (select id from pg_temp.test_ids where key = 'release_claim');
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select set_config('request.jwt.claim.sub', '', true);
select set_config('request.jwt.claim.role', 'service_role', true);
insert into pg_temp.test_ids
select 'release_photo', p.id from public.confirm_exposure(
  (select id from pg_temp.test_ids where key = 'release_claim'), clock_timestamp()) p;

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000001', true);
select set_config('request.jwt.claim.role', 'authenticated', true);
select pg_temp.record_result(
  (select status = 'developing' and develops_at >= finished_at + interval '7 days'
   from public.rolls where id = (select id from pg_temp.test_ids where key = 'release')),
  'confirmed final upload starts seven-day server-timed development');
select pg_temp.record_result(
  (select count(*) = 0 from public.film_photos where roll_id = (select id from pg_temp.test_ids where key = 'release'))
  and (select count(*) = 0 from storage.objects where bucket_id = 'film-originals'),
  'owner and photographer cannot read developing photos');
select set_config('request.jwt.claims', '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated","now":"2099-01-01T00:00:00Z","develops_at":"2000-01-01T00:00:00Z"}', true);
select pg_temp.record_result(
  (select status = 'developing' from public.refresh_roll_status((select id from pg_temp.test_ids where key = 'release')))
  and (select count(*) = 0 from public.film_photos where roll_id = (select id from pg_temp.test_ids where key = 'release')),
  'client-provided JWT timestamps cannot unlock developing photos');
select pg_temp.expect_error(
  $$select public.refresh_roll_status((select id from pg_temp.test_ids where key = 'release'), '2099-01-01T00:00:00Z'::timestamptz)$$,
  'refresh RPC accepts no client clock override', '42883');
select pg_temp.expect_error(
  $$select public.claim_exposure((select id from pg_temp.test_ids where key = 'release'), '40000000-0000-0000-0000-000000000003')$$,
  'developing roll rejects new claims', '55000');

reset role;
-- Privileged fixtures simulate elapsed time without exposing a shortening RPC.
update public.rolls
set finished_at = now() - interval '8 days',
    develops_at = now() - interval '1 day'
where id = (select id from pg_temp.test_ids where key = 'release');
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"10000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000002', true);
select pg_temp.record_result(
  (select status = 'developed' from public.refresh_roll_status((select id from pg_temp.test_ids where key = 'release'))),
  'server refresh develops a roll after its deadline');
select pg_temp.record_result(
  (select count(*) = 1 from public.film_photos where roll_id = (select id from pg_temp.test_ids where key = 'release')),
  'member can read confirmed developed photo metadata after deadline');
select pg_temp.record_result(
  (select count(*) = 1 from storage.objects where bucket_id = 'film-originals'),
  'member can SELECT confirmed developed object after deadline');
select pg_temp.expect_no_change(
  $$update storage.objects set metadata = '{"size":1}'::jsonb where bucket_id = 'film-originals'$$,
  'member cannot overwrite a developed stored photo');
select pg_temp.expect_no_change(
  $$delete from storage.objects where bucket_id = 'film-originals'$$,
  'member cannot delete a developed stored photo');
select pg_temp.expect_no_change(
  $$delete from public.film_photos where roll_id = (select id from pg_temp.test_ids where key = 'release')$$,
  'member cannot delete developed photo metadata');
select pg_temp.expect_no_change(
  $$update public.film_photos set storage_path = 'replacement.jpg' where roll_id = (select id from pg_temp.test_ids where key = 'release')$$,
  'member cannot change a developed photo path');

select set_config('request.jwt.claims', '{"sub":"10000000-0000-0000-0000-000000000003","role":"authenticated"}', true);
select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000003', true);
select pg_temp.record_result(
  (select count(*) = 0 from public.film_photos where roll_id = (select id from pg_temp.test_ids where key = 'release'))
  and (select count(*) = 0 from storage.objects where bucket_id = 'film-originals'),
  'outsider cannot read developed photos or stored objects');
select pg_temp.expect_error(
  $$select public.refresh_roll_status((select id from pg_temp.test_ids where key = 'release'))$$,
  'outsider cannot invoke roll refresh', '42501');

reset role;
update public.roll_members set removed_at = clock_timestamp()
where roll_id in (select id from pg_temp.test_ids where key in ('active', 'release'))
  and user_id = '10000000-0000-0000-0000-000000000002';
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"10000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000002', true);
select pg_temp.record_result(
  (select count(*) = 0 from public.rolls where id = (select id from pg_temp.test_ids where key = 'release'))
  and (select count(*) = 0 from public.film_photos where roll_id = (select id from pg_temp.test_ids where key = 'release'))
  and (select count(*) = 0 from storage.objects where bucket_id = 'film-originals'),
  'removed member loses roll, photo, and object access with existing JWT');
select pg_temp.expect_error(
  $$select public.claim_exposure((select id from pg_temp.test_ids where key = 'active'), '20000000-0000-0000-0000-000000000001')$$,
  'removed membership is checked before replaying a capture claim', '42501');

reset role;
update public.rolls
set develops_at = now() + interval '1 day',
    finished_at = now() - interval '6 days',
    developed_at = now() + interval '1 day'
where id = (select id from pg_temp.test_ids where key = 'release');
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000001', true);
select pg_temp.record_result(
  (select count(*) = 0 from public.film_photos where roll_id = (select id from pg_temp.test_ids where key = 'release'))
  and (select count(*) = 0 from storage.objects where bucket_id = 'film-originals'),
  'developed status alone cannot bypass a future server deadline');
select pg_temp.expect_error(
  $$update private.project_settings set is_development = true where singleton$$,
  'mobile client cannot enable the development-only duration mechanism', '42501');
select pg_temp.expect_error(
  $$update private.project_settings set project_environment = 'development' where singleton$$,
  'mobile client cannot mark a project as development', '42501');
reset role;
update public.rolls
set status = 'developed', finished_at = now() - interval '8 days',
    develops_at = now() - interval '1 day', developed_at = now()
where id = (select id from pg_temp.test_ids where key = 'active');
set local role authenticated;
select pg_temp.record_result(
  (select count(*) = 0 from storage.objects where bucket_id = 'film-originals'
   and name = (select id::text from pg_temp.test_ids where key = 'active') || '/' ||
      (select id::text from pg_temp.test_ids where key = 'unconfirmed_claim') || '.jpg'),
  'developed roll cannot expose an object without a confirmed film photo');
select set_config('request.jwt.claims', '{"role":"authenticated"}', true);
select set_config('request.jwt.claim.sub', '', true);
select pg_temp.expect_error(
  $$select public.claim_exposure((select id from pg_temp.test_ids where key = 'active'), '50000000-0000-0000-0000-000000000002')$$,
  'claim RPC requires an authenticated subject even under the authenticated database role', '28000');

set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select set_config('request.jwt.claim.sub', '', true);
select set_config('request.jwt.claim.role', 'anon', true);
select pg_temp.expect_error(
  $$select public.create_roll('Unauthenticated roll')$$,
  'unauthenticated user cannot create a roll', '42501');
select pg_temp.expect_error(
  $$select public.claim_exposure((select id from pg_temp.test_ids where key = 'active'), '50000000-0000-0000-0000-000000000001')$$,
  'unauthenticated user cannot claim exposures', '42501');
select pg_temp.expect_error(
  $$select * from public.film_photos$$,
  'unauthenticated user cannot read film photo metadata', '42501');

reset role;
select pg_temp.expect_error(
  $$update public.rolls set exposures_used = -1 where id = (select id from pg_temp.test_ids where key = 'active')$$,
  'database rejects negative exposure counters', '23514');
select pg_temp.expect_error(
  $$update public.rolls set exposures_used = total_exposures + 1 where id = (select id from pg_temp.test_ids where key = 'active')$$,
  'database rejects exposure counters above capacity', '23514');
select pg_temp.expect_error(
  $$update public.rolls set development_speed = 'test_30s', development_seconds = 30 where id = (select id from pg_temp.test_ids where key = 'active')$$,
  'production project guard rejects shortened development durations', '42501');
select pg_temp.expect_error(
  $$insert into public.roll_members (roll_id, user_id, role) select id, '10000000-0000-0000-0000-000000000001', 'owner' from pg_temp.test_ids where key = 'active'$$,
  'duplicate roll membership violates unique constraint', '23505');
select pg_temp.expect_error(
  $$with candidate as (select gen_random_uuid() as id)
    insert into public.exposure_claims (id, roll_id, photographer_id, request_id, exposure_number, storage_path)
    select candidate.id, existing.roll_id, existing.photographer_id,
      '60000000-0000-0000-0000-000000000001', existing.exposure_number,
      existing.roll_id::text || '/' || candidate.id::text || '.jpg'
    from public.exposure_claims existing cross join candidate
    where existing.id = (select id from pg_temp.test_ids where key = 'active_claim')$$,
  'duplicate roll exposure number violates unique constraint', '23505');
select pg_temp.expect_error(
  $$with candidate as (select gen_random_uuid() as id)
    insert into public.exposure_claims (id, roll_id, photographer_id, request_id, exposure_number, storage_path)
    select candidate.id, existing.roll_id, existing.photographer_id, existing.request_id,
      3, existing.roll_id::text || '/' || candidate.id::text || '.jpg'
    from public.exposure_claims existing cross join candidate
    where existing.id = (select id from pg_temp.test_ids where key = 'active_claim')$$,
  'duplicate photographer request UUID violates unique constraint', '23505');
select pg_temp.expect_error(
  $$insert into public.film_photos (claim_id, roll_id, photographer_id, storage_path, captured_at, exposure_number)
    select claim_id, roll_id, photographer_id, storage_path, captured_at, exposure_number
    from public.film_photos where id = (select id from pg_temp.test_ids where key = 'active_photo')$$,
  'a second film photo for the same exposure claim is prohibited', '23505');
select pg_temp.record_result(
  (select count(*) = 2 from pg_catalog.pg_constraint c
   where c.contype = 'u' and c.conrelid in ('public.exposure_claims'::regclass, 'public.film_photos'::regclass)
     and c.conkey = array[(select a.attnum from pg_catalog.pg_attribute a
       where a.attrelid = c.conrelid and a.attname = 'storage_path')]),
  'both claims and confirmed film photos require unique storage paths');
select pg_temp.expect_error(
  $$update public.roll_members set exposures_used = -1
    where roll_id = (select id from pg_temp.test_ids where key = 'active')
      and user_id = '10000000-0000-0000-0000-000000000001'$$,
  'database rejects negative member exposure counters', '23514');
select pg_temp.expect_error(
  $$update public.roll_members set exposure_allowance = 0, exposures_used = 1
    where roll_id = (select id from pg_temp.test_ids where key = 'active')
      and user_id = '10000000-0000-0000-0000-000000000001'$$,
  'retained per-member allowance fields enforce their capacity constraint', '23514');

-- TAP is emitted once after assertions so no fixture result is interpreted as
-- a test. Storage assertions cover SQL authorization, not the HTTP signer.
select '1..' || count(*)::text from pg_temp.test_results;
select (case when passed then 'ok ' else 'not ok ' end) || number::text || ' - ' || label
  || case when passed or detail is null then '' else E'\n# ' || replace(detail, E'\n', ' ') end
from pg_temp.test_results order by number;
rollback;
