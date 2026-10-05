-- Development-only durations require both an explicit project classification
-- and the separate administrator-controlled opt-in.
alter table private.project_settings
  add column project_environment text not null default 'unknown'
    check (project_environment in ('unknown', 'development', 'production'));

create function private.guard_project_settings() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'UPDATE'
    and old.project_environment = 'production'
    and new.project_environment <> 'production' then
    raise exception using errcode = '42501',
      message = 'A production project cannot be reclassified as development.';
  end if;

  if new.is_development and new.project_environment <> 'development' then
    raise exception using errcode = '42501',
      message = 'Development tools require an explicitly marked development project.';
  end if;

  return new;
end;
$$;
create trigger guard_project_settings
  before insert or update on private.project_settings
  for each row execute function private.guard_project_settings();

create or replace function private.guard_development_speed() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.development_seconds <> 604800
    and not coalesce((
      select s.is_development and s.project_environment = 'development'
      from private.project_settings s where s.singleton
    ), false)
  then
    raise exception using errcode = '42501',
      message = 'Test development speeds require an enabled development project.';
  end if;
  return new;
end;
$$;

-- Revoke any opt-in created by the pre-marker development script. Projects
-- must be explicitly classified and re-enabled after this migration.
update private.project_settings
set is_development = false
where singleton;

drop function if exists public.create_development_roll(text, integer, integer, text);
drop function if exists private.create_development_roll(text, integer, integer, text);
