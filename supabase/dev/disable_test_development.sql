-- Apply as a database administrator to remove the test RPC and disable overrides.
-- The explicit project_environment marker is retained; is_development=false
-- keeps shortened durations disabled until the admin opt-in is applied again.
begin;
drop function if exists public.create_development_roll(text, integer, integer, text);
drop function if exists private.create_development_roll(text, integer, integer, text);
update private.project_settings set is_development = false where singleton;
commit;
