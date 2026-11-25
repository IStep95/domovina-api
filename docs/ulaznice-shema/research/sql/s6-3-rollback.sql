begin;
drop schema ulaznice cascade;
drop policy if exists ulaznice_media_insert on storage.objects;
drop policy if exists ulaznice_media_update on storage.objects;
drop policy if exists ulaznice_media_delete on storage.objects;
delete from supabase_migrations.schema_migrations
 where version in ('20261125150000','20261125150100','20261125150200','20261125160000','20261125170000');
commit;
