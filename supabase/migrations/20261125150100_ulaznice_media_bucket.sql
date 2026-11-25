-- =============================================================================
-- Ulaznice: storage bucket `ulaznice-media` (S2, odluka 6)
--
-- Naslovne slike i galerija događaja. Ista ograničenja kao `pinka-covers`
-- (20260611120000_pinka_campaign_hardening.sql §5, :316-356): javno čitljiv,
-- 5 MB, jpeg/png/webp/avif; upload samo prijavljeni korisnik s provjerenim
-- identitetom (KYC) i isključivo u vlastitu mapu ({auth.uid()}/...).
--
-- `pinka-covers` ostaje netaknut (kampanje ga i dalje koriste; objekti eventa
-- ostaju u njemu do S7, odluka 105). Objekte kopira operater (S6 runbook), ne
-- ova migracija; URL-ove u ulaznice.events prepisuje 20261125150200.
--
-- Idempotentno: on conflict + drop/create policyja.
-- =============================================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'ulaznice-media', 'ulaznice-media', true, 5242880,
  array['image/jpeg', 'image/png', 'image/webp', 'image/avif']
)
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists ulaznice_media_insert on storage.objects;
create policy ulaznice_media_insert on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'ulaznice-media'
    and (storage.foldername(name))[1] = (select auth.uid())::text
    and public.is_identity_verified()
  );

drop policy if exists ulaznice_media_update on storage.objects;
create policy ulaznice_media_update on storage.objects
  for update to authenticated
  using (
    bucket_id = 'ulaznice-media'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  )
  with check (
    bucket_id = 'ulaznice-media'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

drop policy if exists ulaznice_media_delete on storage.objects;
create policy ulaznice_media_delete on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'ulaznice-media'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

select 'OK ulaznice_media_bucket' as status;
