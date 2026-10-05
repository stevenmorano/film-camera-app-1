insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values ('film-originals', 'film-originals', false, 10485760, array['image/jpeg'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

create function private.may_upload_film_object(p_path text) returns boolean
language sql stable security definer set search_path = '' as $$
  -- Signed upload tokens can bypass later RLS. Only direct JWT uploads are supported.
  select auth.uid() is not null and storage.allow_only_operation('object.upload') and exists (
    select 1 from public.exposure_claims c join public.rolls r on r.id = c.roll_id
    where c.storage_path = p_path and c.photographer_id = auth.uid()
      and c.state = 'pending' and r.status = 'active' and private.is_member(c.roll_id)
  );
$$;
create function private.may_read_film_object(p_path text) returns boolean
language sql volatile security definer set search_path = '' as $$
  select auth.uid() is not null and exists (
    select 1 from public.film_photos p join public.exposure_claims c on c.id = p.claim_id
    where p.storage_path = p_path and c.state = 'stored' and private.may_view_roll(p.roll_id)
  );
$$;
revoke all on function private.may_upload_film_object(text), private.may_read_film_object(text)
  from public, anon, authenticated, service_role;
grant execute on function private.may_upload_film_object(text), private.may_read_film_object(text) to authenticated;

create policy film_upload_reserved_path on storage.objects for insert to authenticated
  with check (bucket_id = 'film-originals' and private.may_upload_film_object(name));
create policy film_read_after_development on storage.objects for select to authenticated
  using (bucket_id = 'film-originals' and private.may_read_film_object(name));

-- Restrictive guards prevent a broad permissive policy from accidentally widening film access.
-- Other buckets retain their existing policy behavior.
create policy film_no_anonymous_access on storage.objects as restrictive for all to anon
  using (bucket_id <> 'film-originals') with check (bucket_id <> 'film-originals');
create policy film_upload_guard on storage.objects as restrictive for insert to authenticated
  with check (bucket_id <> 'film-originals' or private.may_upload_film_object(name));
create policy film_read_guard on storage.objects as restrictive for select to authenticated
  using (bucket_id <> 'film-originals' or private.may_read_film_object(name));
create policy film_no_replace on storage.objects as restrictive for update to authenticated
  using (bucket_id <> 'film-originals') with check (bucket_id <> 'film-originals');
create policy film_no_delete on storage.objects as restrictive for delete to authenticated
  using (bucket_id <> 'film-originals');
