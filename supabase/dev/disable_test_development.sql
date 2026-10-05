-- Apply as an administrator on the dedicated development project to remove its test RPC.
begin;
drop function if exists public.create_development_roll(text, integer, integer, text);
drop function if exists private.create_development_roll(text, integer, integer, text);
update private.project_settings set is_development = false where singleton;
commit;
