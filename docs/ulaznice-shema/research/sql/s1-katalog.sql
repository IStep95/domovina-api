begin read only;
\pset format unaligned
\pset fieldsep '|'
\echo '== TABLES+COLS'
select c.relname, c.relkind, a.attnum, a.attname, format_type(a.atttypid,a.atttypmod), a.attnotnull, pg_get_expr(d.adbin,d.adrelid)
from pg_class c join pg_namespace n on n.oid=c.relnamespace join pg_attribute a on a.attrelid=c.oid and a.attnum>0 and not a.attisdropped
left join pg_attrdef d on d.adrelid=c.oid and d.adnum=a.attnum
where n.nspname='pinka_finance' and c.relkind in ('r','v','m','p') order by 1,3;
\echo '== CONSTRAINTS'
select conrelid::regclass, conname, pg_get_constraintdef(oid) from pg_constraint where connamespace='pinka_finance'::regnamespace order by 1,2;
\echo '== INDEXES'
select indexrelid::regclass, pg_get_indexdef(indexrelid) from pg_index i join pg_class c on c.oid=i.indrelid where c.relnamespace='pinka_finance'::regnamespace order by 1;
\echo '== TRIGGERS'
select tgrelid::regclass, tgname, pg_get_triggerdef(oid) from pg_trigger where not tgisinternal and tgrelid in (select oid from pg_class where relnamespace='pinka_finance'::regnamespace) order by 1,2;
\echo '== POLICIES'
select tablename, policyname, cmd, roles, qual, with_check from pg_policies where schemaname='pinka_finance' order by 1,2;
\echo '== FUNCTIONS'
select p.proname, pg_get_function_identity_arguments(p.oid), pg_get_function_result(p.oid), p.prosecdef, p.proconfig, md5(p.prosrc), array_length(string_to_array(p.prosrc,E'\n'),1), p.proacl from pg_proc p where p.pronamespace='pinka_finance'::regnamespace order by 1,2;
\echo '== TABLE GRANTS'
select table_name, grantee, string_agg(privilege_type, ',' order by privilege_type) from information_schema.role_table_grants where table_schema='pinka_finance' and grantee in ('anon','authenticated','service_role') group by 1,2 order by 1,2;
\echo '== CRON'
select jobid, jobname, schedule, command, active from cron.job order by 1;
\echo '== BUCKETS'
select id, public, file_size_limit, allowed_mime_types from storage.buckets order by 1;
\echo '== STORAGE POLICIES'
select policyname, cmd, roles, qual, with_check from pg_policies where schemaname='storage' order by 1;
\echo '== MIGRATIONS (event)'
select version, name from supabase_migrations.schema_migrations where version >= '20260716' order by 1;
rollback;
