-- OPT-IN ONLY: apply as an administrator to an explicitly marked DEVELOPMENT project.
-- This file is intentionally outside migrations and is never run by db push/reset.
begin;

do $guard$
declare v_environment text;
begin
  select s.project_environment into v_environment
  from private.project_settings s where s.singleton;
  if v_environment is distinct from 'development' then
    raise exception using errcode = '42501',
      message = 'Shortened development periods require an explicitly marked development project.';
  end if;
end;
$guard$;

update private.project_settings
set is_development = true
where singleton and project_environment = 'development';

create or replace function private.create_development_roll(
  p_name text, p_development_seconds integer, p_total_exposures integer, p_roll_type text
) returns public.rolls language plpgsql security definer set search_path = '' as $$
declare v_roll public.rolls;
begin
  if auth.uid() is null then raise exception using errcode = '28000', message = 'Authentication required.'; end if;
  if not coalesce((
    select s.is_development and s.project_environment = 'development'
    from private.project_settings s where s.singleton
  ), false) then
    raise exception using errcode = '42501', message = 'Development tools are disabled.';
  end if;
  if p_development_seconds is null or p_development_seconds not in (30, 300, 3600, 604800) then
    raise exception using errcode = '22023', message = 'Unsupported development test duration.';
  end if;
  v_roll := private.create_roll(p_name, p_total_exposures, p_roll_type);
  update public.rolls set development_seconds = p_development_seconds,
    development_speed = case p_development_seconds when 30 then 'test_30s'
      when 300 then 'test_5m' when 3600 then 'test_1h' else 'standard_7d' end
    where id = v_roll.id returning * into v_roll;
  return v_roll;
end;
$$;
create or replace function public.create_development_roll(
  p_name text, p_development_seconds integer default 30,
  p_total_exposures integer default 32, p_roll_type text default 'shared'
) returns public.rolls language sql security invoker set search_path = '' as $$
  select * from private.create_development_roll(p_name, p_development_seconds, p_total_exposures, p_roll_type);
$$;
revoke all on function private.create_development_roll(text, integer, integer, text),
  public.create_development_roll(text, integer, integer, text) from public, anon, authenticated, service_role;
grant execute on function private.create_development_roll(text, integer, integer, text),
  public.create_development_roll(text, integer, integer, text) to authenticated;
commit;
