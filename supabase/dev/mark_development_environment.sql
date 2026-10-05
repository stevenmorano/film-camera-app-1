-- Apply as a database administrator only after verifying this is the intended
-- dedicated development project. Short durations remain disabled until this
-- explicit marker and the separate enable script have both been applied.
begin;

update private.project_settings
set project_environment = 'development'
where singleton and project_environment = 'unknown';

do $guard$
begin
  if not exists (
    select 1 from private.project_settings
    where singleton and project_environment = 'development'
  ) then
    raise exception using errcode = '42501',
      message = 'Only an unknown project can be explicitly marked as development.';
  end if;
end;
$guard$;

commit;
