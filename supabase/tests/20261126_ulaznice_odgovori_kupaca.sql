-- Odgovori kupca na dodatna polja (20261126120000_ulaznice_odgovori_kupaca.sql):
-- tko smije pisati i čitati, idempotentan upis, red za prosljeđivanje u Google
-- obrazac i rok čuvanja.
--
-- Pokretanje nad lokalnim stackom (sve u jednoj transakciji s ROLLBACK-om):
--   psql postgresql://postgres:postgres@127.0.0.1:55322/postgres -v ON_ERROR_STOP=1 \
--        -f supabase/tests/20261126_ulaznice_odgovori_kupaca.sql
--
-- Očekivano: NOTICE redci "OK — …" i na kraju NOTICE "SVE PROVJERE PROŠLE (N provjera)".
\set ON_ERROR_STOP on
\timing off
\pset pager off

begin;

-- ════════════════════════════════════════════════════════════════════════════
-- A. generički pomoćnici (doslovno iz 20261125_ulaznice_rpc_eventi.sql, drugi prefiks ID-a)
-- ════════════════════════════════════════════════════════════════════════════

create function pg_temp.id(p text) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-00000014' || p)::uuid
$$;

create function pg_temp.osobni(p_user text) returns uuid language sql as $$
  select id from public.accounts
   where primary_owner_user_id = pg_temp.id(p_user) and is_personal_account
$$;

create function pg_temp.kao(p text) returns void language plpgsql as $$
begin
  if p = 'postgres' then
    perform set_config('request.jwt.claims', '', true);
    perform set_config('role', 'postgres', true);
  elsif p = 'anon' then
    perform set_config('request.jwt.claims', '{"role":"anon"}', true);
    perform set_config('role', 'anon', true);
  elsif p = 'service' then
    perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
    perform set_config('role', 'service_role', true);
  else
    perform set_config('request.jwt.claims',
      jsonb_build_object('sub', pg_temp.id(p), 'role', 'authenticated')::text, true);
    perform set_config('role', 'authenticated', true);
  end if;
end $$;

create function pg_temp.broji() returns void language plpgsql as $$
begin
  perform set_config('test.provjere',
    (coalesce(nullif(current_setting('test.provjere', true), ''), '0')::integer + 1)::text, true);
end $$;

-- Izvrši SQL kao zadana uloga, vrati prvi stupac prvog retka kao jsonb.
create function pg_temp.rpc(p_kao text, p_sql text) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.kao(p_kao);
  execute p_sql into v;
  perform pg_temp.kao('postgres');
  return v;
exception when others then
  perform pg_temp.kao('postgres');
  raise exception 'PAO TEST: [%] neočekivana greška [%] % (SQL: %)', p_kao, sqlstate, sqlerrm, p_sql;
end $$;

-- Očekivana greška: SQLSTATE točno, poruka prefiksom (null = bilo koja).
-- Ako naredba NE padne, sentinel-greška poništi i njezin učinak (subtransakcija).
create function pg_temp.pada(p_kao text, p_sql text, p_state text, p_poruka text, p_opis text)
returns void language plpgsql as $$
declare v_state text; v_msg text;
begin
  begin
    perform pg_temp.kao(p_kao);
    execute p_sql;
    raise exception using errcode = 'XX999', message = 'NIJE_PALO';
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
  end;
  perform pg_temp.kao('postgres');
  if v_state = 'XX999' and v_msg = 'NIJE_PALO' then
    raise exception 'PAO TEST: % — prošlo bez greške (očekivano [%] %)', p_opis, p_state, p_poruka;
  end if;
  if v_state <> p_state or (p_poruka is not null and v_msg not like p_poruka || '%') then
    raise exception 'PAO TEST: % — pala s [%] %, očekivano [%] %', p_opis, v_state, v_msg, p_state, p_poruka;
  end if;
  perform pg_temp.broji();
  raise notice 'OK — % (odbijeno [%] %)', p_opis, v_state, v_msg;
end $$;

create function pg_temp.ok(p_uvjet boolean, p_opis text, p_detalj text default null)
returns void language plpgsql as $$
begin
  if p_uvjet is not true then
    raise exception 'PAO TEST: % (%)', p_opis, coalesce(p_detalj, 'uvjet nije ispunjen');
  end if;
  perform pg_temp.broji();
  raise notice 'OK — %', p_opis;
end $$;

create function pg_temp.isto_j(p_opis text, p_dobiveno jsonb, p_ocekivano jsonb)
returns void language plpgsql as $$
begin
  if p_dobiveno is distinct from p_ocekivano then
    raise exception E'PAO TEST: %\n  dobiveno:  %\n  očekivano: %', p_opis, p_dobiveno, p_ocekivano;
  end if;
  perform pg_temp.broji();
  raise notice 'OK — %', p_opis;
end $$;

create function pg_temp.isto_n(p_opis text, p_dobiveno bigint, p_ocekivano bigint)
returns void language plpgsql as $$
begin
  perform pg_temp.isto_j(p_opis, to_jsonb(p_dobiveno), to_jsonb(p_ocekivano));
end $$;

create function pg_temp.isto_t(p_opis text, p_dobiveno text, p_ocekivano text)
returns void language plpgsql as $$
begin
  perform pg_temp.isto_j(p_opis, to_jsonb(p_dobiveno), to_jsonb(p_ocekivano));
end $$;

-- ════════════════════════════════════════════════════════════════════════════
-- C. fixture
-- ════════════════════════════════════════════════════════════════════════════
-- Korisnici: 0001 vlasnik org A | 0002 običan član org A | 0003 vlasnik org B.
-- Eventi org A: c001 za 30 dana | c002 završio prije 100 dana.
-- Narudžbe: f001 paid c001 | f002 pending c001 | f003 paid c002 | f004 paid c001 (bez obrasca).
insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                        email_confirmed_at, created_at, updated_at,
                        raw_app_meta_data, raw_user_meta_data)
select pg_temp.id(n), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       'test-ulaznice-odgovori-' || n || '@example.com', crypt('demo1234', gen_salt('bf')),
       now(), now(), now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb
  from unnest(array['0001','0002','0003']) n;

insert into public.accounts (id, primary_owner_user_id, is_personal_account, slug, name)
values (pg_temp.id('a001'), pg_temp.id('0001'), false, 'test-ulaznice-odgovori-org-a', 'Test odgovori A'),
       (pg_temp.id('a002'), pg_temp.id('0003'), false, 'test-ulaznice-odgovori-org-b', 'Test odgovori B');

insert into public.accounts_memberships (account_id, user_id, account_role)
values (pg_temp.id('a001'), pg_temp.id('0001'), 'owner'),
       (pg_temp.id('a001'), pg_temp.id('0002'), 'member'),
       (pg_temp.id('a002'), pg_temp.id('0003'), 'owner')
on conflict (account_id, user_id) do update set account_role = excluded.account_role;

insert into ulaznice.events (id, account_id, slug, title, currency, state, visibility,
                             event_type, venue_name, venue_city, starts_at, ends_at, organizer_name)
select pg_temp.id(v.id), pg_temp.id('a001'), v.slug, v.title, 'eur', 'active', 'public',
       'radionica', 'Testna dvorana', 'Zagreb', now() + v.pomak, now() + v.pomak + interval '3 hours', 'Test'
  from (values
    ('c001', 'test-odgovori-buduci', 'Test odgovori: budući', interval '30 days'),
    ('c002', 'test-odgovori-prosli', 'Test odgovori: prošli', interval '-100 days')
  ) v(id, slug, title, pomak);

insert into ulaznice.ticket_tiers (id, event_id, title, price_cents, inventory_total, sort, imenska)
values (pg_temp.id('d001'), pg_temp.id('c001'), 'Redovna', 1000, 100, 0, false),
       (pg_temp.id('d002'), pg_temp.id('c002'), 'Redovna', 1000, 100, 0, false);

insert into ulaznice.orders (id, event_id, tier_id, amount_cents, currency, quantity, state, payment_rail,
                             buyer_email, paid_at)
values (pg_temp.id('f001'), pg_temp.id('c001'), pg_temp.id('d001'), 1000, 'eur', 1, 'paid', 'stripe', 'ana@example.com', now()),
       (pg_temp.id('f002'), pg_temp.id('c001'), pg_temp.id('d001'), 1000, 'eur', 1, 'pending', 'stripe', null, null),
       (pg_temp.id('f003'), pg_temp.id('c002'), pg_temp.id('d002'), 1000, 'eur', 1, 'paid', 'stripe', 'ivo@example.com', now()),
       (pg_temp.id('f004'), pg_temp.id('c001'), pg_temp.id('d001'), 1000, 'eur', 1, 'paid', 'stripe', 'eva@example.com', now());

create function pg_temp.spremi(p_order text, p_form text default 'https://docs.google.com/forms/d/e/1FAIpQLSeTEST/viewform')
returns text language sql as $$
  select format(
    'select ulaznice.save_order_answers(%L::uuid, %L::jsonb, %L)',
    pg_temp.id(p_order),
    '[{"id":"101","pitanje":"Spol","odgovor":"Žensko"},{"id":"106","pitanje":"Interesi","odgovor":["Glazba"]}]',
    p_form)
$$;

-- ════════════════════════════════════════════════════════════════════════════
-- D. scenariji
-- ════════════════════════════════════════════════════════════════════════════

\echo '--- 1. upis: samo service_role, idempotentno, provjera oblika'
do $$
declare r jsonb;
begin
  perform pg_temp.pada('anon', pg_temp.spremi('f001'), '42501', null, 'anon ne smije upisivati odgovore');
  perform pg_temp.pada('0001', pg_temp.spremi('f001'), '42501', null, 'ni admin računa (piše samo Worker)');

  r := pg_temp.rpc('service', pg_temp.spremi('f001'));
  perform pg_temp.isto_j('prvi upis', r->'saved', 'true');
  r := pg_temp.rpc('service', pg_temp.spremi('f001'));
  perform pg_temp.isto_j('drugi upis iste narudžbe je no-op', r->'saved', 'false');
  perform pg_temp.isto_t('event_id iz narudžbe',
    (select event_id::text from ulaznice.order_answers where order_id = pg_temp.id('f001')), pg_temp.id('c001')::text);

  perform pg_temp.pada('service',
    format('select ulaznice.save_order_answers(%L::uuid, %L::jsonb)', pg_temp.id('f009'), '[]'),
    'P0001', 'order_not_found', 'nepostojeća narudžba');
  perform pg_temp.pada('service',
    format('select ulaznice.save_order_answers(%L::uuid, %L::jsonb)', pg_temp.id('f002'), '{"101":"x"}'),
    'P0001', 'invalid_answers', 'objekt umjesto niza');
  perform pg_temp.pada('service',
    format('select ulaznice.save_order_answers(%L::uuid, %L::jsonb)', pg_temp.id('f002'), '[{"pitanje":"Spol","odgovor":5}]'),
    'P0001', 'invalid_answers', 'odgovor mora biti tekst ili niz');
  perform pg_temp.pada('service',
    format('select ulaznice.save_order_answers(%L::uuid, %L::jsonb, %L)', pg_temp.id('f002'), '[]', 'https://evil.example/forma'),
    'P0001', 'invalid_answers', 'form_url samo Google viewform');

  perform pg_temp.rpc('service', pg_temp.spremi('f002'));
  perform pg_temp.rpc('service', pg_temp.spremi('f003'));
  perform pg_temp.rpc('service', format('select ulaznice.save_order_answers(%L::uuid, %L::jsonb)', pg_temp.id('f004'), '[]'));
end $$;

\echo '--- 2. čitanje: samo admin računa događaja'
do $$
begin
  perform pg_temp.isto_n('vlasnik org A vidi odgovore svojih događaja',
    (pg_temp.rpc('0001', 'select count(*) from ulaznice.order_answers'))::bigint, 4);
  perform pg_temp.isto_n('običan član org A ne vidi ništa',
    (pg_temp.rpc('0002', 'select count(*) from ulaznice.order_answers'))::bigint, 0);
  perform pg_temp.isto_n('vlasnik drugog računa ne vidi ništa',
    (pg_temp.rpc('0003', 'select count(*) from ulaznice.order_answers'))::bigint, 0);
  perform pg_temp.pada('anon', 'select count(*) from ulaznice.order_answers', '42501', null, 'anon nema select');
  perform pg_temp.pada('0001', format('update ulaznice.order_answers set answers = %L where true', '[]'),
    '42501', null, 'organizator ne može mijenjati odgovore');
  perform pg_temp.pada('0001', 'select ulaznice.purge_order_answers()', '42501', null, 'purge samo service_role');
end $$;

\echo '--- 3. red za prosljeđivanje u Google obrazac'
do $$
declare r jsonb;
begin
  r := pg_temp.rpc('service',
    'select coalesce(jsonb_agg(jsonb_build_object(''o'', order_id, ''e'', buyer_email) order by buyer_email), ''[]'') from ulaznice.order_answers_to_forward(50)');
  perform pg_temp.isto_j('samo plaćene s obrascem (f001, f003; f002 čeka uplatu, f004 bez obrasca)', r,
    jsonb_build_array(jsonb_build_object('o', pg_temp.id('f001'), 'e', 'ana@example.com'),
                      jsonb_build_object('o', pg_temp.id('f003'), 'e', 'ivo@example.com')));

  perform pg_temp.rpc('service', format('select to_jsonb(ulaznice.mark_order_answers_forwarded(%L::uuid, %L))', pg_temp.id('f001'), 'obrazac_odbio_500'));
  perform pg_temp.isto_t('greška: pokušaj zabilježen, ostaje u redu',
    (select forward_attempts || '/' || forward_error || '/' || (forwarded_at is null)
       from ulaznice.order_answers where order_id = pg_temp.id('f001')), '1/obrazac_odbio_500/true');

  perform pg_temp.rpc('service', format('select to_jsonb(ulaznice.mark_order_answers_forwarded(%L::uuid))', pg_temp.id('f001')));
  perform pg_temp.ok((select forwarded_at is not null and forward_error is null and forward_attempts = 2
                        from ulaznice.order_answers where order_id = pg_temp.id('f001')), 'uspjeh: forwarded_at, greška obrisana');
  perform pg_temp.isto_n('proslijeđena izlazi iz reda',
    (pg_temp.rpc('service', 'select count(*) from ulaznice.order_answers_to_forward(50)'))::bigint, 1);

  update ulaznice.order_answers set forward_attempts = 20 where order_id = pg_temp.id('f003');
  perform pg_temp.isto_n('nakon 20 pokušaja red odustaje',
    (pg_temp.rpc('service', 'select count(*) from ulaznice.order_answers_to_forward(50)'))::bigint, 0);
end $$;

\echo '--- 4. rok čuvanja'
do $$
begin
  perform pg_temp.isto_n('svježa neplaćena ostaje (rezervacija još traje)',
    (pg_temp.rpc('service', 'select ulaznice.purge_order_answers()'))::bigint, 1);
  perform pg_temp.ok(not exists (select 1 from ulaznice.order_answers where order_id = pg_temp.id('f003')),
    '90 dana nakon kraja događaja odgovori se brišu');

  update ulaznice.order_answers set created_at = now() - interval '25 hours' where order_id = pg_temp.id('f002');
  perform pg_temp.isto_n('neplaćena starija od 24 h se briše',
    (pg_temp.rpc('service', 'select ulaznice.purge_order_answers()'))::bigint, 1);
  perform pg_temp.ok(exists (select 1 from ulaznice.order_answers where order_id = pg_temp.id('f001')),
    'plaćena narudžba budućeg događaja ostaje');

  delete from ulaznice.orders where id = pg_temp.id('f004');
  perform pg_temp.ok(not exists (select 1 from ulaznice.order_answers where order_id = pg_temp.id('f004')),
    'brisanje narudžbe briše i odgovore (cascade)');
end $$;

do $$ begin
  raise notice 'SVE PROVJERE PROŠLE (% provjera)', current_setting('test.provjere');
end $$;

rollback;
