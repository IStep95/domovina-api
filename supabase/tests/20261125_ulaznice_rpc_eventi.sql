-- Port testa starog ponašanja (20261125_ulaznice_rpc_eventi_staro.sql) na shemu
-- ulaznice (lanac docs/ulaznice-shema/, S3b): ISTI scenariji 1–11 nad RPC-ima iz
-- 20261125170000_ulaznice_rpc_eventi.sql, plus 12. rail gate (port rail dijela iz
-- git show e77f9ae:supabase/tests/20260903_rail_gate_i_rotacija.sql, bez onchain/Safe
-- grana) i ispravci 357/359 na izravnim pisovima tierova.
--
-- Pravilo: isti scenarij daje isti rezultat kao nad pinka_finance, osim namjernih
-- razlika porta; svaka je označena „-- RAZLIKA (odluka 3xx):” uz provjeru:
--   350 create_event DEFINER s vlastitom provjerom admin + KYC: ista RLS poruka (42501),
--       ali za tablicu "events"; ne-admin član s postojećim id-em → RLS greška (staro existing)
--   351 p_destination_address se validira i odbacuje; nema campaign_destination_missing /
--       _locked; destination_address u overviewu i u čitanju događaja = null
--   352 publish rail gate: Stripe Connect (charges_enabled) ILI nema plaćenih tierova
--       (event_no_working_rail); event_rail_ready samo za service_role
--   353 izravni UPDATE u 'active' kao authenticated traži allowlist i rail (staro: BUG
--       ORIGINALA zaobilaženja allowliste)
--   354 update_event: p_gallery, p_attendance_mode, p_venue_lat/lon, p_cover_image_alt
--   355 nema campaign_not_tickets (donacija c0d0 ne postoji → campaign_not_found)
--   357 plaćeni tier na događaju koji nije skica traži radni rail (insert / cijena 0 → > 0)
--   358 rate limit broji i obrisane skice (staro: BUG ORIGINALA, brisanje oslobađa mjesto)
--   359 izravno brisanje tiera: samo skica (event_not_draft), bez narudžbi (tier_has_orders)
--   360 create_event sanitizira opis (staro: BUG ORIGINALA, kontrolni znak ostaje)
--   361 imenska koja nije boolean → invalid_tier_imenska (staro: BUG ORIGINALA, 22P02)
-- „-- ČUDNO:” ponašanja originala (validacija prije prava, termin u prošlosti, KYC samo
-- kod kreiranja, javascript: URL izravnim pisom, overview bez novih polja) ostaju ista.
--
-- Pokretanje nad lokalnim stackom (sve u jednoj transakciji s ROLLBACK-om):
--   psql postgresql://postgres:postgres@127.0.0.1:55322/postgres -v ON_ERROR_STOP=1 \
--        -f supabase/tests/20261125_ulaznice_rpc_eventi.sql
--
-- Očekivano: NOTICE redci "OK — …" i na kraju NOTICE "SVE PROVJERE PROŠLE (N provjera)".
--
-- STRUKTURA (kao u staro.sql): A. generički pomoćnici (doslovno) | B. ADAPTER (ulaznice) |
-- C. fixture (ulaznice) | D. scenariji 1–11 (doslovno osim RAZLIKA) | 12. rail gate.
\set ON_ERROR_STOP on
\timing off
\pset pager off

begin;

-- ════════════════════════════════════════════════════════════════════════════
-- A. generički pomoćnici
-- ════════════════════════════════════════════════════════════════════════════

-- Testni ID: 4 hex znaka iza prefiksa (drugi prefiks nego ostali ulaznice testovi).
create function pg_temp.id(p text) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-00000013' || p)::uuid
$$;

-- Osobni račun korisnika (stvara ga public.handle_new_user).
create function pg_temp.osobni(p_user text) returns uuid language sql as $$
  select id from public.accounts
   where primary_owner_user_id = pg_temp.id(p_user) and is_personal_account
$$;

-- Uloga + JWT do kraja transakcije: 'postgres' | 'anon' | 'service' | 4-hex kod korisnika.
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

-- Sortirani ključevi jsonb objekta.
create function pg_temp.kljucevi(j jsonb) returns jsonb language sql immutable as $$
  select coalesce(jsonb_agg(k order by k), '[]'::jsonb) from jsonb_object_keys(j) k
$$;

-- Podskup ključeva jsonb objekta.
create function pg_temp.dio(j jsonb, variadic p_k text[]) returns jsonb language sql immutable as $$
  select coalesce(jsonb_object_agg(k, j->k), '{}'::jsonb) from unnest(p_k) k
$$;

-- Sortirane vrijednosti ključa p_key iz jsonb niza objekata (usporedba kao skup).
create function pg_temp.vrijednosti(j jsonb, p_key text) returns jsonb language sql immutable as $$
  select coalesce(jsonb_agg(e->p_key order by e->>p_key), '[]'::jsonb) from jsonb_array_elements(j) e
$$;

-- Sortirani niz testnih UUID-ova (za usporedbu s pg_temp.vrijednosti).
create function pg_temp.uuidi(variadic p text[]) returns jsonb language sql immutable as $$
  select coalesce(jsonb_agg(to_jsonb(pg_temp.id(x)) order by pg_temp.id(x)::text), '[]'::jsonb) from unnest(p) x
$$;

-- Element jsonb niza čiji ključ p_key ima vrijednost p_val.
create function pg_temp.element(j jsonb, p_key text, p_val text) returns jsonb language sql immutable as $$
  select e from jsonb_array_elements(j) e where e->>p_key = p_val
$$;

-- Poziv funkcije s imenovanim argumentima iz jsonb objekta. Tip po imenu:
-- *_id → uuid, *_at → timestamptz, p_tiers → jsonb, inače text; json null → NULL.
create function pg_temp.poziv(p_fn text, a jsonb) returns text language sql immutable as $$
  select format('select %s(%s)', p_fn, coalesce(string_agg(
           format('%I => %L::%s', e.key, e.value,
                  case when e.key like '%\_id' then 'uuid'
                       when e.key like '%\_at' then 'timestamptz'
                       when e.key = 'p_tiers' then 'jsonb'
                       else 'text' end), ', ' order by e.key), ''))
    from jsonb_each_text(a) e
$$;

-- Adrese: nulta (draft bez Safe-a, kao ZERO_ADDRESS u edgeu) i dvije „prave”.
create function pg_temp.nulta() returns text language sql immutable as $$
  select '0x0000000000000000000000000000000000000000'
$$;
create function pg_temp.adresa(p text) returns text language sql immutable as $$
  select '0x' || lpad(p, 40, '0')
$$;

-- ════════════════════════════════════════════════════════════════════════════
-- B. ADAPTER — jedino mjesto s nazivima shema/tablica/RPC-a (ulaznice)
-- ════════════════════════════════════════════════════════════════════════════

-- ── pozivi RPC-a (vraćaju SQL koji daje jedan jsonb) ──
create function pg_temp.q_create_event(a jsonb) returns text language sql as $$
  select pg_temp.poziv('ulaznice.create_event', a)
$$;
-- update_event: kao pg_temp.poziv, uz tipove novih parametara (odluka 354):
-- p_gallery → jsonb, p_venue_lat/lon → numeric.
create function pg_temp.q_update_event(a jsonb) returns text language sql as $$
  select format('select ulaznice.update_event(%s)', coalesce(string_agg(
           format('%I => %L::%s', e.key, e.value,
                  case when e.key like '%\_id' then 'uuid'
                       when e.key like '%\_at' then 'timestamptz'
                       when e.key in ('p_tiers', 'p_gallery') then 'jsonb'
                       when e.key in ('p_venue_lat', 'p_venue_lon') then 'numeric'
                       else 'text' end), ', ' order by e.key), ''))
    from jsonb_each_text(a) e
$$;
create function pg_temp.q_publish(p_event uuid, p_target text default 'active') returns text language sql as $$
  select format('select ulaznice.publish_event(%L::uuid, %L::text)', p_event, p_target)
$$;
create function pg_temp.q_delete_draft(p_event uuid) returns text language sql as $$
  select format('select ulaznice.delete_event_draft(%L::uuid)', p_event)
$$;
create function pg_temp.q_overview() returns text language sql as $$
  select 'select ulaznice.organizer_overview()'
$$;
create function pg_temp.q_upsert_record(a jsonb) returns text language sql as $$
  select pg_temp.poziv('ulaznice.upsert_organizer_record', a)
$$;
-- RAZLIKA (odluka 352): event_rail_ready(account_id, event_id); grant samo service_role.
create function pg_temp.q_rail_ready(p_account uuid, p_event uuid) returns text language sql as $$
  select format('select to_jsonb(ulaznice.event_rail_ready(%L::uuid, %L::uuid))', p_account, p_event)
$$;

-- ── izravni pisovi korisnikovim klijentom (edge mimo RPC-a; vraćaju broj redaka) ──
create function pg_temp.q_mediji(p_event uuid, p_set jsonb) returns text language sql as $$
  select format('with u as (update ulaznice.events set %s where id = %L::uuid returning 1) '
                'select to_jsonb(count(*)) from u',
                string_agg(format('%I = %L::%s', e.key, e.value,
                                  case e.key when 'gallery' then 'jsonb'
                                             when 'venue_lat' then 'numeric'
                                             when 'venue_lon' then 'numeric'
                                             else 'text' end), ', '),
                p_event)
    from jsonb_each_text(p_set) e
$$;
create function pg_temp.q_obrisi_tierove(p_event uuid, p_ids uuid[]) returns text language sql as $$
  select format('with d as (delete from ulaznice.ticket_tiers where event_id = %L::uuid '
                'and id = any(%L::uuid[]) returning 1) select to_jsonb(count(*)) from d', p_event, p_ids)
$$;
-- supabase-js upsert = insert … on conflict (pk) do update svih poslanih stupaca.
create function pg_temp.q_pristup(p_event uuid, p_url text) returns text language sql as $$
  select format('with u as (insert into ulaznice.event_access (event_id, online_url, updated_at) '
                'values (%L::uuid, %L::text, now()) on conflict (event_id) do update set '
                'online_url = excluded.online_url, updated_at = excluded.updated_at returning 1) '
                'select to_jsonb(count(*)) from u', p_event, p_url)
$$;
create function pg_temp.q_vidi_pristup(p_event uuid) returns text language sql as $$
  select format('select to_jsonb(count(*)) from ulaznice.event_access where event_id = %L::uuid', p_event)
$$;
create function pg_temp.q_vidi_zapis(p_account uuid) returns text language sql as $$
  select format('select to_jsonb(count(*)) from ulaznice.organizer_records where account_id = %L::uuid', p_account)
$$;
-- Izravni insert/update eventa (PostgREST; edge to ne radi, ali RLS dopušta).
-- ulaznice.events nema type/destination_address; venue_name/city i organizer_name su obavezni.
create function pg_temp.q_insert_event_raw(p_event uuid, p_account uuid, p_state text) returns text language sql as $$
  select format('with x as (insert into ulaznice.events '
                '(id, account_id, slug, title, state, visibility, venue_name, venue_city, organizer_name) '
                'values (%L::uuid, %L::uuid, %L, ''Izravni insert'', %L, ''public'', ''Testna dvorana'', '
                '''Zagreb'', ''Testni organizator'') returning state) select to_jsonb(state) from x',
                p_event, p_account, 'test-eventi-staro-izravni', p_state)
$$;
create function pg_temp.q_set_event_raw(p_event uuid, p_set jsonb) returns text language sql as $$
  select format('with u as (update ulaznice.events set %s where id = %L::uuid returning 1) '
                'select to_jsonb(count(*)) from u',
                string_agg(format('%I = %L', e.key, e.value), ', '), p_event)
    from jsonb_each_text(p_set) e
$$;
-- Izravni pisovi tierova (odluke 357, 359).
create function pg_temp.q_insert_tier_raw(p_event uuid, p_tier uuid, p_price integer) returns text language sql as $$
  select format('with x as (insert into ulaznice.ticket_tiers (id, event_id, title, price_cents) '
                'values (%L::uuid, %L::uuid, ''Izravni tier'', %s) returning 1) select to_jsonb(count(*)) from x',
                p_tier, p_event, p_price)
$$;
create function pg_temp.q_set_tier_raw(p_tier uuid, p_price integer) returns text language sql as $$
  select format('with u as (update ulaznice.ticket_tiers set price_cents = %s where id = %L::uuid returning 1) '
                'select to_jsonb(count(*)) from u', p_price, p_tier)
$$;

-- ── stanje Stripe raila organizatora (kao postgres; odluke 352, 357) ──
-- p_charges null = organizator nema Stripe (red se briše).
create function pg_temp.rail(p_account uuid, p_charges boolean) returns void language plpgsql as $$
begin
  if p_charges is null then
    delete from ulaznice.organizer_payment_rails where account_id = p_account;
  else
    insert into ulaznice.organizer_payment_rails (account_id, stripe_account_id, stripe_charges_enabled,
                                                  stripe_payouts_enabled, invoice_provider)
    values (p_account, 'acct_test' || left(md5(p_account::text), 12), p_charges, p_charges, 'fira')
    on conflict (account_id) do update set stripe_charges_enabled = excluded.stripe_charges_enabled,
                                           stripe_payouts_enabled = excluded.stripe_payouts_enabled;
  end if;
end $$;

-- ── poznate razlike oblika odgovora ──
-- create_event vraća ključ `id` (= events.id), isto kao original (odluka 3).

-- ── čitanje stanja (kao postgres, mimo RLS-a) ──
create function pg_temp.dogadjaj(p_event uuid) returns jsonb language sql as $$
  select jsonb_build_object(
    'account_id', e.account_id, 'slug', e.slug::text, 'title', e.title, 'state', e.state,
    'visibility', e.visibility,
    'destination_address', null,  -- RAZLIKA (odluka 351): stupac ne postoji, adresa se odbacuje
    'description', e.description, 'deleted', e.deleted_at is not null,
    'event_type', e.event_type, 'venue_name', e.venue_name, 'venue_address', e.venue_address,
    'venue_city', e.venue_city, 'starts_at', e.starts_at, 'ends_at', e.ends_at, 'timezone', e.timezone,
    'description_hr', e.description_hr, 'description_en', e.description_en,
    'cover_image_url', e.cover_image_url, 'organizer_name', e.organizer_name,
    'organizer_email', e.organizer_email, 'organizer_web', e.organizer_web,
    'gallery', e.gallery, 'attendance_mode', e.attendance_mode,
    'venue_lat', e.venue_lat, 'venue_lon', e.venue_lon, 'cover_image_alt', e.cover_image_alt)
  from ulaznice.events e
  where e.id = p_event
$$;
create function pg_temp.stanje_eventa(p_event uuid) returns text language sql as $$
  select state from ulaznice.events where id = p_event
$$;
create function pg_temp.tierovi(p_event uuid) returns jsonb language sql as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', t.id, 'title', t.title, 'description', t.description, 'price_cents', t.price_cents,
           'inventory_total', t.inventory_total, 'inventory_claimed', t.inventory_claimed,
           'imenska', t.imenska, 'sale_start', t.sale_start, 'sale_end', t.sale_end, 'sort', t.sort)
         order by t.sort, t.title), '[]'::jsonb)
    from ulaznice.ticket_tiers t where t.event_id = p_event
$$;
create function pg_temp.broj_eventa(p_account uuid) returns integer language sql as $$
  select count(*)::integer from ulaznice.events where account_id = p_account
$$;
create function pg_temp.pristup(p_event uuid) returns text language sql as $$
  select online_url from ulaznice.event_access where event_id = p_event
$$;
create function pg_temp.ima_pristup(p_event uuid) returns boolean language sql as $$
  select exists (select 1 from ulaznice.event_access where event_id = p_event)
$$;
create function pg_temp.zapis(p_account uuid) returns jsonb language sql as $$
  select to_jsonb(r) - 'created_at' - 'updated_at' from ulaznice.organizer_records r where r.account_id = p_account
$$;
create function pg_temp.narudzba_tier(p_order uuid) returns uuid language sql as $$
  select tier_id from ulaznice.orders where id = p_order
$$;
-- Audit (public.activity_events; log_event) — ulaznice RPC-i logiraju isto (odluka 304).
create function pg_temp.audit(p_account uuid, p_type text) returns integer language sql as $$
  select count(*)::integer from public.activity_events where target_account_id = p_account and event_type = p_type
$$;
create function pg_temp.audit_payload(p_account uuid, p_type text) returns jsonb language sql as $$
  select payload from public.activity_events where target_account_id = p_account and event_type = p_type
   order by created_at desc, id desc limit 1
$$;

-- ════════════════════════════════════════════════════════════════════════════
-- C. fixture (ulaznice)
-- ════════════════════════════════════════════════════════════════════════════
-- Korisnici: 0001 vlasnik org A (KYC) | 0002 admin org A (KYC) | 0003 admin org A BEZ KYC |
--            0004 običan član org A (KYC) | 0005 vlasnik org B (KYC; ne-član A) |
--            0006 vlasnik org R (KYC; rate limit) | 0007 vlasnik org S (KYC; rail gate, scenarij 12).
-- Org računi: a001 (A, allowlist) | a002 (B, NIJE na allowlisti) | a003 (R, allowlist) |
--             a004 (S, allowlist). Nijedan račun na početku nema Stripe rail.
-- Eventi: c001 aktivan A, javni | c002 skica A | c003 skica B | c004 skica A s narudžbom.
--   MAPIRANJE: c0d0 (donacija) ne postoji u ulaznice.events (odluka 355).
-- Tierovi: d001 c001 20 € inv 10 claimed 3 (plaćena narudžba f001) | d002 c001 0 € inv 100 |
--   d003 c002 10 € inv 10 | d004 c003 15 € | d005 c004 10 €.
-- Narudžbe: f001 paid c001/d001 (stripe) | f002 pending c004/d005 (stripe).
insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                        email_confirmed_at, created_at, updated_at,
                        raw_app_meta_data, raw_user_meta_data)
select pg_temp.id(n), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       'test-ulaznice-eventi-' || n || '@example.com', crypt('demo1234', gen_salt('bf')),
       now(), now(), now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb
  from unnest(array['0001','0002','0003','0004','0005','0006','0007']) n;

insert into public.accounts (id, primary_owner_user_id, is_personal_account, slug, name)
values (pg_temp.id('a001'), pg_temp.id('0001'), false, 'test-ulaznice-eventi-org-a', 'Test eventi A'),
       (pg_temp.id('a002'), pg_temp.id('0005'), false, 'test-ulaznice-eventi-org-b', 'Test eventi B'),
       (pg_temp.id('a003'), pg_temp.id('0006'), false, 'test-ulaznice-eventi-org-r', 'Test eventi R'),
       (pg_temp.id('a004'), pg_temp.id('0007'), false, 'test-ulaznice-eventi-org-s', 'Test eventi S');

insert into public.accounts_memberships (account_id, user_id, account_role)
values (pg_temp.id('a001'), pg_temp.id('0001'), 'owner'),
       (pg_temp.id('a001'), pg_temp.id('0002'), 'admin'),
       (pg_temp.id('a001'), pg_temp.id('0003'), 'admin'),
       (pg_temp.id('a001'), pg_temp.id('0004'), 'member'),
       (pg_temp.id('a002'), pg_temp.id('0005'), 'owner'),
       (pg_temp.id('a003'), pg_temp.id('0006'), 'owner'),
       (pg_temp.id('a004'), pg_temp.id('0007'), 'owner')
on conflict (account_id, user_id) do update set account_role = excluded.account_role;

-- KYC (is_identity_verified gleda auth.uid(), ne vlasnika računa); 0003 namjerno bez.
insert into public.identity_verifications (user_id, oib_ciphertext, oib_hash)
select pg_temp.id(n), '\x00'::bytea, 'test-ulaznice-eventi-oib-hash-' || n
  from unnest(array['0001','0002','0004','0005','0006','0007']) n;

-- MAPIRANJE: pinka_finance.organizer_allowlist → ulaznice.organizer_allowlist
insert into ulaznice.organizer_allowlist (account_id, note)
values (pg_temp.id('a001'), 'test eventi'), (pg_temp.id('a003'), 'test eventi'), (pg_temp.id('a004'), 'test eventi');

-- MAPIRANJE: campaigns + events → ulaznice.events (destination_address/chain/type/subject_type ne postoje);
-- upis kao postgres, pa guard ne prisiljava skicu (c001 ostaje aktivan).
insert into ulaznice.events (id, account_id, slug, title, currency, state, visibility,
                             event_type, venue_name, venue_city, starts_at, ends_at, organizer_name)
select pg_temp.id(v.id), pg_temp.id(v.acc), v.slug, v.title, 'eur', v.state, v.vis,
       'koncert', 'Testna dvorana', 'Zagreb', now() + interval '30 days',
       now() + interval '30 days 3 hours', 'Testni organizator'
  from (values
    ('c001', 'a001', 'test-eventi-staro-aktivan', 'Test eventi: aktivan', 'active', 'public'),
    ('c002', 'a001', 'test-eventi-staro-skica',   'Test eventi: skica',   'draft',  'private'),
    ('c003', 'a002', 'test-eventi-staro-tudji',   'Test eventi: org B',   'draft',  'private'),
    ('c004', 'a001', 'test-eventi-staro-narudzba','Test eventi: narudžba','draft',  'private')
  ) v(id, acc, slug, title, state, vis);

-- MAPIRANJE: campaign_tiers → ticket_tiers; campaign_id → event_id; kind otpada
insert into ulaznice.ticket_tiers (id, event_id, title, price_cents, inventory_total, sort, imenska)
select pg_temp.id(v.id), pg_temp.id(v.c), v.title, v.price, v.inv, v.sort, false
  from (values
    ('d001', 'c001', 'Redovna',    2000, 10,  0),
    ('d002', 'c001', 'Besplatna',     0, 100, 1),
    ('d003', 'c002', 'Skica tier', 1000, 10,  0),
    ('d004', 'c003', 'Tier B',     1500, 10,  0),
    ('d005', 'c004', 'Tier N',     1000, 10,  0)
  ) v(id, c, title, price, inv, sort);

-- MAPIRANJE: contributions → orders; campaign_id → event_id; contributor_account_id → buyer_account_id;
-- destination_address otpada, payment_rail 'stripe' (onchain samo za istekle, odluka 110)
insert into ulaznice.orders (id, event_id, tier_id, buyer_account_id, amount_cents, currency,
                             quantity, state, payment_rail, paid_at)
values (pg_temp.id('f001'), pg_temp.id('c001'), pg_temp.id('d001'), pg_temp.osobni('0004'), 2000, 'eur', 1,
        'paid', 'stripe', now()),
       (pg_temp.id('f002'), pg_temp.id('c004'), pg_temp.id('d005'), pg_temp.osobni('0004'), 1000, 'eur', 1,
        'pending', 'stripe', null);
update ulaznice.ticket_tiers set inventory_claimed = 3 where id = pg_temp.id('d001');

-- ════════════════════════════════════════════════════════════════════════════
-- D. scenariji (doslovno iz staro.sql osim redaka „-- RAZLIKA (odluka 3xx):”)
-- ════════════════════════════════════════════════════════════════════════════

-- Osnovni argumenti create_event (kao ih šalje edge: nulta adresa, visibility private).
create function pg_temp.ev(p_id text, p_acc text, p_title text, p_extra jsonb default '{}'::jsonb)
returns jsonb language sql as $$
  select jsonb_build_object(
    'p_id', pg_temp.id(p_id), 'p_account_id', pg_temp.id(p_acc), 'p_title', p_title,
    'p_destination_address', pg_temp.nulta(), 'p_venue_name', '  Testna dvorana  ',
    'p_venue_city', ' Zagreb ', 'p_event_type', 'koncert',
    'p_starts_at', now() + interval '30 days', 'p_ends_at', now() + interval '30 days 3 hours',
    'p_visibility', 'private', 'p_tiers', '[]'::jsonb) || p_extra
$$;

\echo '--- 1. create_event: uspjeh, oblik odgovora, idempotencija, slug'
do $$
declare r jsonb; ocek jsonb;
begin
  r := pg_temp.rpc('0001', pg_temp.q_create_event(pg_temp.ev('c101', 'a001', ' Testni eventi staro 13 koncert ',
         jsonb_build_object('p_tiers', jsonb_build_array(
           jsonb_build_object('title', ' Redovna ', 'price_cents', 2000, 'inventory_total', 100,
                              'description', ' Ulaz '),
           jsonb_build_object('title', 'Imenska', 'price_cents', '0', 'imenska', true,
                              'sale_start', now() + interval '1 day', 'sale_end', now() + interval '2 days'))))));
  ocek := jsonb_build_object('id', pg_temp.id('c101'), 'slug', 'testni-eventi-staro-13-koncert',
                             'existing', false, 'event_created', true);
  perform pg_temp.isto_j('create c101: odgovor', r, ocek);   -- PORT: ključ `id` (v. adapter)
  perform pg_temp.isto_j('create c101: ključevi odgovora', pg_temp.kljucevi(r),
    '["event_created","existing","id","slug"]');
  perform pg_temp.isto_j('create c101: spremljen event (skica, private, trim, organizer = naslov)',
    pg_temp.dogadjaj(pg_temp.id('c101')),
    jsonb_build_object('account_id', pg_temp.id('a001'), 'slug', 'testni-eventi-staro-13-koncert',
      'title', 'Testni eventi staro 13 koncert', 'state', 'draft', 'visibility', 'private',
      'destination_address', null, 'description', null, 'deleted', false,  -- RAZLIKA (odluka 351): staro nulta adresa
      'event_type', 'koncert', 'venue_name', 'Testna dvorana', 'venue_address', null,
      'venue_city', 'Zagreb', 'starts_at', now() + interval '30 days',
      'ends_at', now() + interval '30 days 3 hours', 'timezone', 'Europe/Zagreb',
      'description_hr', null, 'description_en', null, 'cover_image_url', null,
      'organizer_name', 'Testni eventi staro 13 koncert', 'organizer_email', null, 'organizer_web', null,
      'gallery', '[]'::jsonb, 'attendance_mode', 'physical', 'venue_lat', null, 'venue_lon', null,
      'cover_image_alt', null));
  perform pg_temp.isto_j('create c101: tierovi (trim, sort redom, inventory null = neograničeno)',
    pg_temp.tierovi(pg_temp.id('c101')) #- '{0,id}' #- '{1,id}',
    jsonb_build_array(
      jsonb_build_object('title', 'Redovna', 'description', 'Ulaz', 'price_cents', 2000,
        'inventory_total', 100, 'inventory_claimed', 0, 'imenska', false, 'sale_start', null,
        'sale_end', null, 'sort', 0),
      jsonb_build_object('title', 'Imenska', 'description', null, 'price_cents', 0,
        'inventory_total', null, 'inventory_claimed', 0, 'imenska', true,
        'sale_start', now() + interval '1 day', 'sale_end', now() + interval '2 days', 'sort', 1)));

  -- idempotencija: isti id + isti račun (i s DRUGIM podacima) vraća postojeći, ništa ne dira
  r := pg_temp.rpc('0002', pg_temp.q_create_event(pg_temp.ev('c101', 'a001', 'Sasvim drugi naslov',
         '{"p_tiers":[{"title":"X","price_cents":1}]}')));
  perform pg_temp.isto_j('create c101 ponovno (drugi naslov/tier): existing, event_created=false', r,
    jsonb_build_object('id', pg_temp.id('c101'), 'slug', 'testni-eventi-staro-13-koncert',
                       'existing', true, 'event_created', false));
  perform pg_temp.isto_n('create c101 ponovno: i dalje 2 tiera', jsonb_array_length(pg_temp.tierovi(pg_temp.id('c101'))), 2);
  perform pg_temp.isto_t('create c101 ponovno: naslov nepromijenjen',
    pg_temp.dogadjaj(pg_temp.id('c101'))->>'title', 'Testni eventi staro 13 koncert');

  -- isti naslov → slug s nastavkom -2
  r := pg_temp.rpc('0001', pg_temp.q_create_event(pg_temp.ev('c105', 'a001', 'Testni eventi staro 13 koncert')));
  perform pg_temp.isto_t('create c105 (isti naslov): slug -2', r->>'slug', 'testni-eventi-staro-13-koncert-2');

  -- dijakritici u slugu; bez tierova je dopušteno; organizer_name zadan
  r := pg_temp.rpc('0002', pg_temp.q_create_event(pg_temp.ev('c102', 'a001', 'Testni eventi staro 13: Šibenik',
         jsonb_build_object('p_description_hr', ' Opis' || chr(1) || ' ', 'p_organizer_name', ' Udruga ',
                            'p_venue_address', '  ', 'p_cover_image_url', 'https://cdn.example.com/c102.jpg'))));
  perform pg_temp.isto_t('create c102: slug bez dijakritika', r->>'slug', 'testni-eventi-staro-13-sibenik');
  perform pg_temp.isto_n('create c102: bez tierova', jsonb_array_length(pg_temp.tierovi(pg_temp.id('c102'))), 0);
  perform pg_temp.isto_j('create c102: organizer, prazna adresa → null, cover',
    pg_temp.dio(pg_temp.dogadjaj(pg_temp.id('c102')), 'organizer_name', 'venue_address', 'cover_image_url'),
    '{"organizer_name":"Udruga","venue_address":null,"cover_image_url":"https://cdn.example.com/c102.jpg"}');
  -- RAZLIKA (odluka 360): create_event sanitizira opis kao update_event (ulaznice.sanitize_ugc).
  -- Staro (BUG ORIGINALA): kontrolni znak ostaje, 'Opis' || chr(1).
  perform pg_temp.isto_t('create c102: opis sanitiziran (chr(1) uklonjen) — RAZLIKA 360',
    pg_temp.dogadjaj(pg_temp.id('c102'))->>'description_hr', 'Opis');
  -- RAZLIKA (odluka 356, 360): events.description je kopija sanitiziranog description_hr
  perform pg_temp.isto_t('create c102: zrcalni description (sanitiziran) — RAZLIKA 360',
    pg_temp.dogadjaj(pg_temp.id('c102'))->>'description', 'Opis');

  -- p_visibility public: event je i dalje skica (objava ide kroz publish_event)
  r := pg_temp.rpc('0001', pg_temp.q_create_event(pg_temp.ev('c103', 'a001', 'Testni eventi staro 13 javni',
         '{"p_visibility":"public"}')));
  perform pg_temp.isto_j('create c103 (p_visibility public): skica, public',
    pg_temp.dio(pg_temp.dogadjaj(pg_temp.id('c103')), 'state', 'visibility'),
    '{"state":"draft","visibility":"public"}');
end $$;

-- isti id, drugi račun → pkey sudar (tuđi event s tim id-em)
select pg_temp.pada('0005', pg_temp.q_create_event(pg_temp.ev('c101', 'a002', 'Testni eventi staro 13 B')),
  'P0001', 'campaign_exists', 'create: id postoji na drugom računu');

\echo '--- 2. create_event: prava i validacija'
-- prava: RLS insert policy (admin računa + KYC pozivatelja), INVOKER
-- RAZLIKA (odluka 350): create_event je DEFINER i sam provjerava admin + KYC; ista poruka i kod
-- kao RLS, ali za tablicu "events" (staro "campaigns").
select pg_temp.pada('0004', pg_temp.q_create_event(pg_temp.ev('c110', 'a001', 'Testni eventi staro 13 član')),
  '42501', 'new row violates row-level security policy for table "events"', 'create: običan član (nije admin)');
select pg_temp.pada('0003', pg_temp.q_create_event(pg_temp.ev('c110', 'a001', 'Testni eventi staro 13 bez KYC')),
  '42501', 'new row violates row-level security policy for table "events"', 'create: admin bez KYC');
select pg_temp.pada('0001', pg_temp.q_create_event(pg_temp.ev('c110', 'a002', 'Testni eventi staro 13 tuđi')),
  '42501', 'new row violates row-level security policy for table "events"', 'create: tuđi račun');
-- RAZLIKA (odluka 350): ne-admin član s postojećim id-em → RLS greška (staro: INVOKER idempotencija
-- kroz campaigns_select vraćala je {"existing":true} i članu bez prava kreiranja).
select pg_temp.pada('0004', pg_temp.q_create_event(pg_temp.ev('c101', 'a001', 'Testni eventi staro 13 koncert')),
  '42501', 'new row violates row-level security policy for table "events"', 'create: član ponavlja postojeći c101 — RAZLIKA 350');
select pg_temp.pada('anon', pg_temp.q_create_event(pg_temp.ev('c110', 'a001', 'Testni eventi staro 13 anon')),
  '42501', 'permission denied for function create_event', 'create: anon nema EXECUTE');
-- ČUDNO: validacija event polja ide PRIJE provjere prava (član dobije invalid_venue_name, ne RLS)
select pg_temp.pada('0004', pg_temp.q_create_event(pg_temp.ev('c110', 'a001', 'Testni eventi staro 13',
                                                   '{"p_venue_name":" "}')),
  'P0001', 'invalid_venue_name', 'create: član + loše mjesto → validacija prije prava');
-- ČUDNO: i retry postojećeg id-a s lošim mjestom pada na validaciji (prije idempotencije)
select pg_temp.pada('0001', pg_temp.q_create_event(pg_temp.ev('c101', 'a001', 'Testni eventi staro 13 koncert',
                                                   '{"p_venue_city":""}')),
  'P0001', 'invalid_venue_city', 'create: retry c101 s praznim gradom → validacija prije idempotencije');

-- validacija (strojni kodovi, P0001)
select pg_temp.pada('0001', pg_temp.q_create_event(pg_temp.ev('c110', 'a001', 'Testni eventi', jsonb_build_object('p_venue_name', repeat('a', 161)))),
  'P0001', 'invalid_venue_name', 'create: mjesto > 160');
select pg_temp.pada('0001', pg_temp.q_create_event(pg_temp.ev('c110', 'a001', 'Testni eventi', '{"p_venue_city":null}')),
  'P0001', 'invalid_venue_city', 'create: grad null');
select pg_temp.pada('0001', pg_temp.q_create_event(pg_temp.ev('c110', 'a001', 'Testni eventi', '{"p_event_type":"Koncert"}')),
  'P0001', 'invalid_event_type', 'create: event_type velika slova');
select pg_temp.pada('0001', pg_temp.q_create_event(pg_temp.ev('c110', 'a001', 'Testni eventi', '{"p_timezone":" "}')),
  'P0001', 'invalid_timezone', 'create: prazna vremenska zona');
select pg_temp.pada('0001', pg_temp.q_create_event(pg_temp.ev('c110', 'a001', 'Testni eventi', '{"p_tiers":{}}')),
  'P0001', 'invalid_tiers', 'create: tiers nije niz');
select pg_temp.pada('0001', pg_temp.q_create_event(pg_temp.ev('c110', 'a001', 'Testni eventi', '{"p_tiers":[{"title":" ","price_cents":1}]}')),
  'P0001', 'invalid_tier_title', 'create: tier bez naslova');
select pg_temp.pada('0001', pg_temp.q_create_event(pg_temp.ev('c110', 'a001', 'Testni eventi', '{"p_tiers":[{"title":"A","price_cents":-1}]}')),
  'P0001', 'invalid_tier_price', 'create: tier cijena negativna');
select pg_temp.pada('0001', pg_temp.q_create_event(pg_temp.ev('c110', 'a001', 'Testni eventi', '{"p_tiers":[{"title":"A","price_cents":"1.5"}]}')),
  'P0001', 'invalid_tier_price', 'create: tier cijena decimalna');
select pg_temp.pada('0001', pg_temp.q_create_event(pg_temp.ev('c110', 'a001', 'Testni eventi', '{"p_tiers":[{"title":"A","price_cents":1,"inventory_total":-5}]}')),
  'P0001', 'invalid_tier_inventory', 'create: tier inventory negativan');
select pg_temp.pada('0001', pg_temp.q_create_event(pg_temp.ev('c110', 'a001', 'Testni eventi', '{"p_tiers":[{"title":"A","price_cents":1,"sale_start":"x"}]}')),
  'P0001', 'invalid_tier_sale_window', 'create: tier sale_start nije datum');
select pg_temp.pada('0001', pg_temp.q_create_event(pg_temp.ev('c110', 'a001', 'Testni eventi',
         jsonb_build_object('p_tiers', jsonb_build_array(jsonb_build_object('title', 'A', 'price_cents', 1,
           'sale_start', now() + interval '2 days', 'sale_end', now() + interval '1 day'))))),
  'P0001', 'invalid_tier_sale_window', 'create: tier sale_end prije sale_start');
-- RAZLIKA (odluka 361): imenska koja nije boolean → strojni kod invalid_tier_imenska
-- (staro, BUG ORIGINALA: sirova greška castanja 22P02 'invalid input syntax for type boolean').
select pg_temp.pada('0001', pg_temp.q_create_event(pg_temp.ev('c110', 'a001', 'Testni eventi', '{"p_tiers":[{"title":"A","price_cents":1,"imenska":"da"}]}')),
  'P0001', 'invalid_tier_imenska', 'create: tier imenska nije boolean — RAZLIKA 361');
select pg_temp.pada('0001', pg_temp.q_create_event(pg_temp.ev('c110', 'a001', 'ab')),
  'P0001', 'invalid_title', 'create: naslov < 3 znaka');
select pg_temp.pada('0001', pg_temp.q_create_event(pg_temp.ev('c110', 'a001', 'Testni eventi', '{"p_destination_address":"0x12"}')),
  'P0001', 'invalid_destination', 'create: loša adresa');
select pg_temp.pada('0001', pg_temp.q_create_event(pg_temp.ev('c110', 'a001', 'Testni eventi', '{"p_visibility":"svima"}')),
  'P0001', 'invalid_visibility', 'create: loš visibility');
select pg_temp.pada('0001', pg_temp.q_create_event(pg_temp.ev('c110', 'a001', 'Testni eventi', '{"p_cover_image_url":"http://x.hr/a.jpg"}')),
  'P0001', 'invalid_cover_url', 'create: cover nije https');
select pg_temp.pada('0001', pg_temp.q_create_event(pg_temp.ev('c110', 'a001', 'Testni eventi',
         jsonb_build_object('p_starts_at', now() - interval '2 days', 'p_ends_at', now() - interval '1 day'))),
  'P0001', 'invalid_dates', 'create: završetak u prošlosti');
select pg_temp.pada('0001', pg_temp.q_create_event(pg_temp.ev('c110', 'a001', 'Testni eventi',
         jsonb_build_object('p_ends_at', now() + interval '29 days'))),
  'P0001', 'invalid_dates', 'create: završetak prije početka');
-- ČUDNO: organizer_name/web/adresa nemaju strojnu provjeru u create_event → check constraint (23514)
select pg_temp.pada('0001', pg_temp.q_create_event(pg_temp.ev('c110', 'a001', 'Testni eventi', jsonb_build_object('p_organizer_name', repeat('o', 161)))),
  '23514', 'new row for relation "events" violates check constraint "events_organizer_name_len"', 'create: organizer > 160 → check constraint');
select pg_temp.pada('0001', pg_temp.q_create_event(pg_temp.ev('c110', 'a001', 'Testni eventi', jsonb_build_object('p_venue_address', repeat('v', 201)))),
  '23514', 'new row for relation "events" violates check constraint "events_venue_address_len"', 'create: adresa > 200 → check constraint');

do $$ begin
  perform pg_temp.ok(pg_temp.stanje_eventa(pg_temp.id('c110')) is null, 'create: odbijeni c110 nije upisan');
end $$;

\echo '--- 3. prisilni draft (izravni insert mimo RPC-a)'
do $$
declare v jsonb;
begin
  -- subtransakcija: zapamti rezultat, poništi insert (da ne kvari pregled organizatora)
  begin
    v := pg_temp.rpc('0001', pg_temp.q_insert_event_raw(pg_temp.id('c1f0'), pg_temp.id('a001'), 'active'));
    raise exception using errcode = 'XX998';
  exception when sqlstate 'XX998' then null;
  end;
  perform pg_temp.isto_j('izravni insert state=active kao admin → spremljen kao draft', v, '"draft"');
  perform pg_temp.ok(pg_temp.stanje_eventa(pg_temp.id('c1f0')) is null, 'izravni insert poništen (subtransakcija)');
end $$;
-- RAZLIKA (odluka 350): RLS events_insert, poruka za tablicu "events" (staro "campaigns")
select pg_temp.pada('0004', pg_temp.q_insert_event_raw(pg_temp.id('c1f0'), pg_temp.id('a001'), 'draft'),
  '42501', 'new row violates row-level security policy for table "events"', 'izravni insert: običan član');

\echo '--- 4. rate limit: 20 eventa po računu u 24 h'
do $$
declare i integer; r jsonb;
begin
  perform pg_temp.isto_n('fixture: račun R nema evenata', pg_temp.broj_eventa(pg_temp.id('a003')), 0);
  for i in 1..20 loop
    r := pg_temp.rpc('0006', pg_temp.q_create_event(pg_temp.ev('c2' || lpad(i::text, 2, '0'), 'a003',
           'Testni eventi staro 13 limit ' || i)));
  end loop;
  perform pg_temp.isto_n('rate limit: 20 eventa kreirano', pg_temp.broj_eventa(pg_temp.id('a003')), 20);
end $$;
select pg_temp.pada('0006', pg_temp.q_create_event(pg_temp.ev('c221', 'a003', 'Testni eventi staro 13 limit 21')),
  'P0001', 'campaign_rate_limited', 'rate limit: 21. event pada');
-- RAZLIKA (odluka 358): events_write_guard je DEFINER i broji sve retke računa, i meko obrisane
-- (delete_event_draft postavlja deleted_at, red ostaje), pa brisanje skice NE oslobađa mjesto.
-- Staro (BUG ORIGINALA): INVOKER guard brojao je kroz RLS (deleted_at is null) → 21. event prolazio.
do $$
declare r jsonb;
begin
  r := pg_temp.rpc('0006', pg_temp.q_delete_draft(pg_temp.id('c201')));
  perform pg_temp.pada('0006', pg_temp.q_create_event(pg_temp.ev('c221', 'a003', 'Testni eventi staro 13 limit 21')),
    'P0001', 'campaign_rate_limited', 'rate limit: nakon brisanja skice 21. event i dalje pada — RAZLIKA 358');
  perform pg_temp.isto_n('rate limit: na računu 20 evenata (1 obrisan) — RAZLIKA 358', pg_temp.broj_eventa(pg_temp.id('a003')), 20);
end $$;
select pg_temp.pada('0006', pg_temp.q_create_event(pg_temp.ev('c222', 'a003', 'Testni eventi staro 13 limit 22')),
  'P0001', 'campaign_rate_limited', 'rate limit: 22. (20 vidljivih) opet pada');

\echo '--- 5. update_event'
do $$
declare r jsonb; t0 text; d jsonb;
begin
  t0 := pg_temp.tierovi(pg_temp.id('c101'))->0->>'id';
  r := pg_temp.rpc('0002', pg_temp.q_update_event(jsonb_build_object(
         'p_campaign_id', pg_temp.id('c101'), 'p_title', ' Testni eventi staro 13 novi naslov ',
         'p_venue_name', ' Nova dvorana ', 'p_venue_address', ' Ilica 1 ',
         'p_description_hr', ' Opis' || chr(1) || ' s' || chr(9) || 'tabom' || chr(10) || 'novi red ',
         'p_description_en', '', 'p_cover_image_url', 'https://cdn.example.com/c.jpg',
         'p_organizer_email', ' org@example.com ',
         'p_tiers', jsonb_build_array(
           jsonb_build_object('id', t0, 'title', ' Redovna+ ', 'price_cents', 2500, 'inventory_total', 50,
                              'description', 'A' || chr(2)),
           jsonb_build_object('title', 'Nova', 'price_cents', 900)))));
  perform pg_temp.isto_j('update c101: odgovor', r,
    jsonb_build_object('campaign_id', pg_temp.id('c101'), 'updated', true, 'tiers_updated', 1, 'tiers_added', 1));
  d := pg_temp.dogadjaj(pg_temp.id('c101'));
  perform pg_temp.isto_j('update c101: polja (trim, UGC sanitiziran, prazno → null, slug nepromijenjen)',
    pg_temp.dio(d, 'title', 'slug', 'venue_name', 'venue_address', 'description_hr', 'description',
                'description_en', 'cover_image_url', 'organizer_email', 'organizer_name', 'venue_city'),
    jsonb_build_object('title', 'Testni eventi staro 13 novi naslov', 'slug', 'testni-eventi-staro-13-koncert',
      'venue_name', 'Nova dvorana', 'venue_address', 'Ilica 1',
      'description_hr', 'Opis s' || chr(9) || 'tabom' || chr(10) || 'novi red',
      'description', 'Opis s' || chr(9) || 'tabom' || chr(10) || 'novi red',
      'description_en', null, 'cover_image_url', 'https://cdn.example.com/c.jpg',
      'organizer_email', 'org@example.com', 'organizer_name', 'Testni eventi staro 13 koncert',
      'venue_city', 'Zagreb'));
  perform pg_temp.isto_j('update c101: tierovi (postojeći izmijenjen + sanitiziran opis, novi sort = max+1)',
    pg_temp.tierovi(pg_temp.id('c101')) #- '{0,id}' #- '{1,id}' #- '{2,id}',
    jsonb_build_array(
      jsonb_build_object('title', 'Redovna+', 'description', 'A', 'price_cents', 2500,
        'inventory_total', 50, 'inventory_claimed', 0, 'imenska', false, 'sale_start', null,
        'sale_end', null, 'sort', 0),
      jsonb_build_object('title', 'Imenska', 'description', null, 'price_cents', 0,
        'inventory_total', null, 'inventory_claimed', 0, 'imenska', true,
        'sale_start', now() + interval '1 day', 'sale_end', now() + interval '2 days', 'sort', 1),
      jsonb_build_object('title', 'Nova', 'description', null, 'price_cents', 900,
        'inventory_total', null, 'inventory_claimed', 0, 'imenska', false, 'sale_start', null,
        'sale_end', null, 'sort', 2)));

  -- null = ne diraj; '' = obriši opcionalno polje
  r := pg_temp.rpc('0002', pg_temp.q_update_event(jsonb_build_object(
         'p_campaign_id', pg_temp.id('c101'), 'p_venue_address', '', 'p_cover_image_url', '')));
  perform pg_temp.isto_j('update c101 (samo prazni stringovi): odgovor bez tierova', r,
    jsonb_build_object('campaign_id', pg_temp.id('c101'), 'updated', true, 'tiers_updated', 0, 'tiers_added', 0));
  perform pg_temp.isto_j('update c101: adresa i cover obrisani, ostalo netaknuto',
    pg_temp.dio(pg_temp.dogadjaj(pg_temp.id('c101')), 'venue_address', 'cover_image_url', 'venue_name', 'title'),
    '{"venue_address":null,"cover_image_url":null,"venue_name":"Nova dvorana","title":"Testni eventi staro 13 novi naslov"}');
  perform pg_temp.isto_n('update c101: i dalje 3 tiera', jsonb_array_length(pg_temp.tierovi(pg_temp.id('c101'))), 3);

  -- admin bez KYC smije uređivati (KYC se traži samo na insertu)
  r := pg_temp.rpc('0003', pg_temp.q_update_event(jsonb_build_object(
         'p_campaign_id', pg_temp.id('c101'), 'p_timezone', ' Europe/Zagreb ')));
  perform pg_temp.ok((r->>'updated')::boolean, 'update c101: admin bez KYC smije');

  -- objavljen event: novi tier smije, termin u prošlosti prolazi
  -- RAZLIKA (odluka 357): plaćeni tier na objavljenom eventu traži radni Stripe rail. Org A ga
  -- nema → event_no_working_rail (staro: prolazi). S uključenim railom isti poziv prolazi kao staro;
  -- rail org A ostaje uključen do kraja (publish c101 s plaćenim tierom zato prolazi kao u originalu).
  perform pg_temp.pada('0002', pg_temp.q_update_event(jsonb_build_object(
         'p_campaign_id', pg_temp.id('c001'),
         'p_starts_at', now() - interval '2 days', 'p_ends_at', now() - interval '1 day',
         'p_tiers', jsonb_build_array(jsonb_build_object('title', 'Kasna', 'price_cents', 3000)))),
    'P0001', 'event_no_working_rail', 'update c001 (aktivan) bez Stripea: plaćeni novi tier — RAZLIKA 357');
  perform pg_temp.rail(pg_temp.id('a001'), true);
  r := pg_temp.rpc('0002', pg_temp.q_update_event(jsonb_build_object(
         'p_campaign_id', pg_temp.id('c001'),
         'p_starts_at', now() - interval '2 days', 'p_ends_at', now() - interval '1 day',
         'p_tiers', jsonb_build_array(jsonb_build_object('title', 'Kasna', 'price_cents', 3000)))));
  perform pg_temp.isto_j('update c001 (aktivan): novi tier dopušten', pg_temp.dio(r, 'tiers_added'), '{"tiers_added":1}');
  -- ČUDNO: update_event ne provjerava ends_at > now() (create_event provjerava)
  perform pg_temp.isto_j('update c001: termin u prošlosti prihvaćen (ČUDNO)',
    pg_temp.dio(pg_temp.dogadjaj(pg_temp.id('c001')), 'starts_at', 'ends_at'),
    jsonb_build_object('starts_at', now() - interval '2 days', 'ends_at', now() - interval '1 day'));
  -- objavljen event: isti tier s istom cijenom i manjim/većim inventoryjem ≥ claimed prolazi
  r := pg_temp.rpc('0002', pg_temp.q_update_event(jsonb_build_object(
         'p_campaign_id', pg_temp.id('c001'),
         'p_tiers', jsonb_build_array(jsonb_build_object('id', pg_temp.id('d001'), 'title', 'Redovna',
                                                         'price_cents', 2000, 'inventory_total', 3)))));
  perform pg_temp.isto_j('update c001: d001 inventory = claimed (3) prolazi', pg_temp.dio(r, 'tiers_updated'), '{"tiers_updated":1}');
end $$;

-- prava
select pg_temp.pada('0004', pg_temp.q_update_event(jsonb_build_object('p_campaign_id', pg_temp.id('c101'), 'p_title', 'Član mijenja')),
  'P0001', 'not_authorized', 'update: običan član');
-- ČUDNO: ne-član ne vidi skicu kroz RLS (INVOKER) → campaign_not_found, a ne not_authorized
select pg_temp.pada('0005', pg_temp.q_update_event(jsonb_build_object('p_campaign_id', pg_temp.id('c101'), 'p_title', 'Tuđi mijenja')),
  'P0001', 'campaign_not_found', 'update: ne-član na tuđoj skici');
select pg_temp.pada('0005', pg_temp.q_update_event(jsonb_build_object('p_campaign_id', pg_temp.id('c001'), 'p_title', 'Tuđi mijenja')),
  'P0001', 'not_authorized', 'update: ne-član na tuđem javnom eventu');
select pg_temp.pada('anon', pg_temp.q_update_event(jsonb_build_object('p_campaign_id', pg_temp.id('c101'))),
  '42501', 'permission denied for function update_event', 'update: anon nema EXECUTE');
select pg_temp.pada('0002', pg_temp.q_update_event(jsonb_build_object('p_campaign_id', pg_temp.id('cfff'))),
  'P0001', 'campaign_not_found', 'update: nepostojeći event');
-- RAZLIKA (odluka 355): nema campaign_not_tickets — donacija c0d0 ne postoji u ulaznice.events
select pg_temp.pada('0002', pg_temp.q_update_event(jsonb_build_object('p_campaign_id', pg_temp.id('c0d0'))),
  'P0001', 'campaign_not_found', 'update: donacija (nije u ulaznice) → campaign_not_found');
-- validacija
select pg_temp.pada('0002', pg_temp.q_update_event(jsonb_build_object('p_campaign_id', pg_temp.id('c101'), 'p_title', ' ab ')),
  'P0001', 'invalid_title', 'update: naslov < 3');
select pg_temp.pada('0002', pg_temp.q_update_event(jsonb_build_object('p_campaign_id', pg_temp.id('c101'), 'p_destination_address', '0x12')),
  'P0001', 'invalid_destination', 'update: loša adresa');
select pg_temp.pada('0002', pg_temp.q_update_event(jsonb_build_object('p_campaign_id', pg_temp.id('c101'), 'p_event_type', 'Koncert')),
  'P0001', 'invalid_event_type', 'update: loš event_type');
select pg_temp.pada('0002', pg_temp.q_update_event(jsonb_build_object('p_campaign_id', pg_temp.id('c101'), 'p_venue_name', ' ')),
  'P0001', 'invalid_venue_name', 'update: prazno mjesto');
select pg_temp.pada('0002', pg_temp.q_update_event(jsonb_build_object('p_campaign_id', pg_temp.id('c101'), 'p_venue_city', '')),
  'P0001', 'invalid_venue_city', 'update: prazan grad');
select pg_temp.pada('0002', pg_temp.q_update_event(jsonb_build_object('p_campaign_id', pg_temp.id('c101'), 'p_venue_address', repeat('v', 201))),
  'P0001', 'invalid_venue_address', 'update: adresa > 200');
select pg_temp.pada('0002', pg_temp.q_update_event(jsonb_build_object('p_campaign_id', pg_temp.id('c101'), 'p_description_hr', repeat('d', 20001))),
  'P0001', 'invalid_description', 'update: opis > 20000');
select pg_temp.pada('0002', pg_temp.q_update_event(jsonb_build_object('p_campaign_id', pg_temp.id('c101'), 'p_cover_image_url', 'http://x.hr/a.jpg')),
  'P0001', 'invalid_cover_url', 'update: cover nije https');
select pg_temp.pada('0002', pg_temp.q_update_event(jsonb_build_object('p_campaign_id', pg_temp.id('c101'), 'p_organizer_name', ' ')),
  'P0001', 'invalid_organizer_name', 'update: prazan organizator');
select pg_temp.pada('0002', pg_temp.q_update_event(jsonb_build_object('p_campaign_id', pg_temp.id('c101'), 'p_ends_at', now() + interval '1 day')),
  'P0001', 'invalid_dates', 'update: završetak prije postojećeg početka');
select pg_temp.pada('0002', pg_temp.q_update_event(jsonb_build_object('p_campaign_id', pg_temp.id('c101'), 'p_tiers', '{}'::jsonb)),
  'P0001', 'invalid_tiers', 'update: tiers nije niz');
select pg_temp.pada('0002', pg_temp.q_update_event(jsonb_build_object('p_campaign_id', pg_temp.id('c101'),
         'p_tiers', '[{"id":"abc","title":"A","price_cents":1}]'::jsonb)),
  'P0001', 'invalid_tier_id', 'update: tier id nije uuid');
select pg_temp.pada('0002', pg_temp.q_update_event(jsonb_build_object('p_campaign_id', pg_temp.id('c101'),
         'p_tiers', jsonb_build_array(jsonb_build_object('id', pg_temp.id('d003'), 'title', 'A', 'price_cents', 1)))),
  'P0001', 'tier_not_found', 'update: tier drugog eventa');
-- objavljen event: zaključani tierovi i Safe
select pg_temp.pada('0002', pg_temp.q_update_event(jsonb_build_object('p_campaign_id', pg_temp.id('c001'),
         'p_tiers', jsonb_build_array(jsonb_build_object('id', pg_temp.id('d001'), 'title', 'Redovna', 'price_cents', 2100)))),
  'P0001', 'tier_locked', 'update aktivnog: promjena cijene tiera');
select pg_temp.pada('0002', pg_temp.q_update_event(jsonb_build_object('p_campaign_id', pg_temp.id('c001'),
         'p_tiers', jsonb_build_array(jsonb_build_object('id', pg_temp.id('d001'), 'title', 'Redovna', 'price_cents', 2000, 'imenska', true)))),
  'P0001', 'tier_locked', 'update aktivnog: promjena imenska');
select pg_temp.pada('0002', pg_temp.q_update_event(jsonb_build_object('p_campaign_id', pg_temp.id('c001'),
         'p_tiers', jsonb_build_array(jsonb_build_object('id', pg_temp.id('d001'), 'title', 'Redovna', 'price_cents', 2000, 'inventory_total', 2)))),
  'P0001', 'inventory_below_claimed', 'update aktivnog: inventory ispod claimed');
-- RAZLIKA (odluka 351): adresa se validira i odbacuje — nema campaign_destination_locked
select pg_temp.isto_j('update: promjena Safe-a nakon plaćene narudžbe prihvaćena i odbačena — RAZLIKA 351',
  pg_temp.dio(pg_temp.rpc('0002', pg_temp.q_update_event(jsonb_build_object('p_campaign_id', pg_temp.id('c001'),
    'p_destination_address', pg_temp.adresa('13a2')))), 'updated', 'tiers_added'),
  '{"updated":true,"tiers_added":0}');
-- slug je nepromjenjiv i izravnim updateom
select pg_temp.pada('0001', pg_temp.q_set_event_raw(pg_temp.id('c002'), '{"slug":"test-eventi-staro-novi-slug"}'),
  'P0001', 'slug_immutable', 'izravni update sluga');

\echo '--- 6. izravni pisovi: galerija, geo, alt, online (attendance_mode, event_access), brisanje tiera skice'
do $$
declare r jsonb; g jsonb;
begin
  g := '[{"url":"https://cdn.example.com/1.jpg"},{"url":"https://cdn.example.com/2.jpg","alt":"Pozornica"}]';
  r := pg_temp.rpc('0002', pg_temp.q_mediji(pg_temp.id('c101'), jsonb_build_object('gallery', g)));
  perform pg_temp.isto_j('galerija: admin upisuje (1 red)', r, '1');
  perform pg_temp.isto_j('galerija: spremljena', pg_temp.dogadjaj(pg_temp.id('c101'))->'gallery', g);
  -- ČUDNO (namjerno plitka provjera, v. migraciju): URL nije provjeren (edge provjerava https)
  r := pg_temp.rpc('0002', pg_temp.q_mediji(pg_temp.id('c101'), '{"gallery":[{"url":"javascript:alert(1)","alt":null}]}'));
  perform pg_temp.isto_j('galerija: javascript: URL prihvaćen u bazi (ČUDNO)', r, '1');
  r := pg_temp.rpc('0002', pg_temp.q_mediji(pg_temp.id('c101'), jsonb_build_object('gallery', g)));
  r := pg_temp.rpc('0002', pg_temp.q_mediji(pg_temp.id('c101'), '{"gallery":[]}'));
  perform pg_temp.isto_j('galerija: prazna lista briše', pg_temp.dogadjaj(pg_temp.id('c101'))->'gallery', '[]');
  r := pg_temp.rpc('0002', pg_temp.q_mediji(pg_temp.id('c101'), jsonb_build_object('gallery', g)));
  -- ne-član / član: RLS tiho filtrira (0 redaka, bez greške)
  perform pg_temp.isto_j('galerija: ne-član → 0 redaka',
    pg_temp.rpc('0005', pg_temp.q_mediji(pg_temp.id('c101'), '{"gallery":[]}')), '0');
  perform pg_temp.isto_j('galerija: običan član → 0 redaka',
    pg_temp.rpc('0004', pg_temp.q_mediji(pg_temp.id('c101'), '{"gallery":[]}')), '0');
  perform pg_temp.isto_j('galerija: nakon ne-člana/člana nepromijenjena', pg_temp.dogadjaj(pg_temp.id('c101'))->'gallery', g);

  -- geo + alt (seed/editor)
  r := pg_temp.rpc('0002', pg_temp.q_mediji(pg_temp.id('c101'), '{"venue_lat":45.8131,"venue_lon":15.9775,"cover_image_alt":"Pozornica"}'));
  perform pg_temp.isto_j('geo + alt: admin upisuje', r, '1');
  perform pg_temp.isto_j('geo + alt: spremljeno',
    pg_temp.dio(pg_temp.dogadjaj(pg_temp.id('c101')), 'venue_lat', 'venue_lon', 'cover_image_alt'),
    '{"venue_lat":45.8131,"venue_lon":15.9775,"cover_image_alt":"Pozornica"}');
  perform pg_temp.isto_j('geo: ne-član → 0 redaka',
    pg_temp.rpc('0005', pg_temp.q_mediji(pg_temp.id('c101'), '{"venue_lat":1,"venue_lon":1}')), '0');

  -- online
  r := pg_temp.rpc('0002', pg_temp.q_mediji(pg_temp.id('c101'), '{"attendance_mode":"online"}'));
  perform pg_temp.isto_t('online: attendance_mode = online',
    pg_temp.dogadjaj(pg_temp.id('c101'))->>'attendance_mode', 'online');
  r := pg_temp.rpc('0002', pg_temp.q_pristup(pg_temp.id('c101'), 'https://meet.example.com/abc'));
  perform pg_temp.isto_j('event_access: admin upsert (insert)', r, '1');
  r := pg_temp.rpc('0002', pg_temp.q_pristup(pg_temp.id('c101'), 'https://meet.example.com/xyz'));
  perform pg_temp.isto_j('event_access: admin upsert (update)', r, '1');
  perform pg_temp.isto_t('event_access: novi link', pg_temp.pristup(pg_temp.id('c101')), 'https://meet.example.com/xyz');
  r := pg_temp.rpc('0002', pg_temp.q_pristup(pg_temp.id('c101'), null));
  perform pg_temp.ok(pg_temp.ima_pristup(pg_temp.id('c101')) and pg_temp.pristup(pg_temp.id('c101')) is null,
    'event_access: null link (edge "" → null) ostavlja red s null');
  r := pg_temp.rpc('0002', pg_temp.q_pristup(pg_temp.id('c101'), 'https://meet.example.com/xyz'));
  perform pg_temp.isto_j('event_access: admin vidi red', pg_temp.rpc('0002', pg_temp.q_vidi_pristup(pg_temp.id('c101'))), '1');
  perform pg_temp.isto_j('event_access: običan član ne vidi', pg_temp.rpc('0004', pg_temp.q_vidi_pristup(pg_temp.id('c101'))), '0');
  perform pg_temp.isto_j('event_access: ne-član ne vidi', pg_temp.rpc('0005', pg_temp.q_vidi_pristup(pg_temp.id('c101'))), '0');
end $$;
select pg_temp.pada('0002', pg_temp.q_mediji(pg_temp.id('c101'),
         jsonb_build_object('gallery', (select jsonb_agg(jsonb_build_object('url', 'https://x.hr/' || i)) from generate_series(1, 21) i))),
  '23514', 'new row for relation "events" violates check constraint "events_gallery_shape"', 'galerija: 21 stavka');
select pg_temp.pada('0002', pg_temp.q_mediji(pg_temp.id('c101'), '{"gallery":[{"url":5}]}'),
  '23514', 'new row for relation "events" violates check constraint "events_gallery_shape"', 'galerija: url nije string');
select pg_temp.pada('0002', pg_temp.q_mediji(pg_temp.id('c101'), jsonb_build_object('gallery', jsonb_build_array(jsonb_build_object('url', 'https://x.hr/1', 'alt', repeat('a', 301))))),
  '23514', 'new row for relation "events" violates check constraint "events_gallery_shape"', 'galerija: alt > 300');
select pg_temp.pada('0002', pg_temp.q_mediji(pg_temp.id('c101'), '{"gallery":{"url":"https://x.hr/1"}}'),
  '23514', 'new row for relation "events" violates check constraint "events_gallery_shape"', 'galerija: objekt umjesto niza');
select pg_temp.pada('anon', pg_temp.q_mediji(pg_temp.id('c101'), '{"gallery":[]}'),
  '42501', 'permission denied for table events', 'galerija: anon nema UPDATE');
select pg_temp.pada('0002', pg_temp.q_mediji(pg_temp.id('c101'), '{"venue_lat":null}'),
  '23514', 'new row for relation "events" violates check constraint "events_venue_geo_pair"', 'geo: samo jedna koordinata');
select pg_temp.pada('0002', pg_temp.q_mediji(pg_temp.id('c101'), '{"venue_lat":91,"venue_lon":0}'),
  '23514', 'new row for relation "events" violates check constraint "events_venue_geo_range"', 'geo: lat izvan raspona');
select pg_temp.pada('0002', pg_temp.q_mediji(pg_temp.id('c101'), '{"cover_image_alt":""}'),
  '23514', 'new row for relation "events" violates check constraint "events_cover_image_alt_len"', 'alt: prazan string');
select pg_temp.pada('0002', pg_temp.q_mediji(pg_temp.id('c101'), '{"attendance_mode":"hybrid"}'),
  '23514', 'new row for relation "events" violates check constraint "events_attendance_mode_chk"', 'attendance_mode: hybrid');
select pg_temp.pada('0002', pg_temp.q_pristup(pg_temp.id('c101'), 'http://meet.example.com/abc'),
  '23514', 'new row for relation "event_access" violates check constraint "event_access_online_url_chk"', 'event_access: http link');
select pg_temp.pada('0002', pg_temp.q_pristup(pg_temp.id('c101'), 'https://meet.example.com/a b'),
  '23514', 'new row for relation "event_access" violates check constraint "event_access_online_url_chk"', 'event_access: razmak u linku');
select pg_temp.pada('0005', pg_temp.q_pristup(pg_temp.id('c101'), 'https://meet.example.com/hack'),
  '42501', 'new row violates row-level security policy for table "event_access"', 'event_access: ne-član upsert');
select pg_temp.pada('0004', pg_temp.q_pristup(pg_temp.id('c101'), 'https://meet.example.com/hack'),
  '42501', 'new row violates row-level security policy for table "event_access"', 'event_access: običan član upsert');
select pg_temp.pada('anon', pg_temp.q_pristup(pg_temp.id('c101'), 'https://meet.example.com/hack'),
  '42501', 'permission denied for table event_access', 'event_access: anon');
do $$
declare r jsonb; t2 uuid;
begin
  perform pg_temp.isto_t('event_access: link nepromijenjen nakon odbijenih', pg_temp.pristup(pg_temp.id('c101')), 'https://meet.example.com/xyz');
  -- brisanje tiera skice (edge remove_tier_ids)
  t2 := (pg_temp.element(pg_temp.tierovi(pg_temp.id('c101')), 'title', 'Nova')->>'id')::uuid;
  perform pg_temp.isto_j('brisanje tiera: ne-član → 0 redaka',
    pg_temp.rpc('0005', pg_temp.q_obrisi_tierove(pg_temp.id('c101'), array[t2])), '0');
  perform pg_temp.isto_j('brisanje tiera: običan član → 0 redaka',
    pg_temp.rpc('0004', pg_temp.q_obrisi_tierove(pg_temp.id('c101'), array[t2])), '0');
  perform pg_temp.isto_j('brisanje tiera skice: admin → 1 red',
    pg_temp.rpc('0002', pg_temp.q_obrisi_tierove(pg_temp.id('c101'), array[t2])), '1');
  perform pg_temp.isto_n('brisanje tiera skice: ostala 2 tiera', jsonb_array_length(pg_temp.tierovi(pg_temp.id('c101'))), 2);
end $$;
-- RAZLIKA (odluka 354): update_event prima i p_gallery, p_attendance_mode, p_venue_lat/lon,
-- p_cover_image_alt (staro: samo izravni pis gore). Strojni kodovi kao edge parseMedia.
do $$
declare r jsonb; g jsonb;
begin
  g := '[{"url":"https://cdn.example.com/3.jpg","alt":"Publika"}]';
  r := pg_temp.rpc('0002', pg_temp.q_update_event(jsonb_build_object('p_campaign_id', pg_temp.id('c101'),
         'p_gallery', g, 'p_attendance_mode', 'physical', 'p_venue_lat', 45.5, 'p_venue_lon', 16.1,
         'p_cover_image_alt', ' Dvorana ')));
  perform pg_temp.isto_j('update c101 s medijima: odgovor — RAZLIKA 354', r,
    jsonb_build_object('campaign_id', pg_temp.id('c101'), 'updated', true, 'tiers_updated', 0, 'tiers_added', 0));
  perform pg_temp.isto_j('update c101 s medijima: spremljeno (alt btrim) — RAZLIKA 354',
    pg_temp.dio(pg_temp.dogadjaj(pg_temp.id('c101')), 'gallery', 'attendance_mode', 'venue_lat', 'venue_lon', 'cover_image_alt'),
    jsonb_build_object('gallery', g, 'attendance_mode', 'physical', 'venue_lat', 45.5, 'venue_lon', 16.1,
                       'cover_image_alt', 'Dvorana'));
  r := pg_temp.rpc('0002', pg_temp.q_update_event(jsonb_build_object('p_campaign_id', pg_temp.id('c101'),
         'p_cover_image_alt', '', 'p_gallery', '[]'::jsonb)));
  perform pg_temp.isto_j('update c101: alt "" → null, galerija [] briše, ostalo netaknuto — RAZLIKA 354',
    pg_temp.dio(pg_temp.dogadjaj(pg_temp.id('c101')), 'gallery', 'cover_image_alt', 'venue_lat'),
    '{"gallery":[],"cover_image_alt":null,"venue_lat":45.5}');
end $$;
select pg_temp.pada('0002', pg_temp.q_update_event(jsonb_build_object('p_campaign_id', pg_temp.id('c101'), 'p_gallery', '{"url":"https://x.hr/1"}'::jsonb)),
  'P0001', 'invalid_gallery', 'update: galerija objekt umjesto niza — RAZLIKA 354');
select pg_temp.pada('0002', pg_temp.q_update_event(jsonb_build_object('p_campaign_id', pg_temp.id('c101'), 'p_gallery', '[{"url":"http://x.hr/1"}]'::jsonb)),
  'P0001', 'invalid_gallery_url', 'update: galerija http URL — RAZLIKA 354');
select pg_temp.pada('0002', pg_temp.q_update_event(jsonb_build_object('p_campaign_id', pg_temp.id('c101'), 'p_gallery', '[{"url":"javascript:alert(1)"}]'::jsonb)),
  'P0001', 'invalid_gallery_url', 'update: galerija javascript: URL (izravni pis ga prima, ČUDNO gore) — RAZLIKA 354');
select pg_temp.pada('0002', pg_temp.q_update_event(jsonb_build_object('p_campaign_id', pg_temp.id('c101'), 'p_attendance_mode', 'hybrid')),
  'P0001', 'invalid_attendance_mode', 'update: attendance_mode hybrid — RAZLIKA 354');
select pg_temp.pada('0002', pg_temp.q_update_event(jsonb_build_object('p_campaign_id', pg_temp.id('c101'), 'p_venue_lat', 45)),
  'P0001', 'invalid_location', 'update: samo jedna koordinata — RAZLIKA 354');
select pg_temp.pada('0002', pg_temp.q_update_event(jsonb_build_object('p_campaign_id', pg_temp.id('c101'), 'p_venue_lat', 91, 'p_venue_lon', 0)),
  'P0001', 'invalid_location', 'update: lat izvan raspona — RAZLIKA 354');
select pg_temp.pada('0002', pg_temp.q_update_event(jsonb_build_object('p_campaign_id', pg_temp.id('c101'), 'p_cover_image_alt', repeat('a', 301))),
  'P0001', 'invalid_cover_image_alt', 'update: alt > 300 — RAZLIKA 354');

\echo '--- 7. publish_event'
-- RAZLIKA (odluka 351, 352): Safe-a nema; objavu c101 (plaćeni tier) blokira rail gate. Org A ima
-- Stripe od scenarija 5, pa ga ovdje gasimo (charges_enabled=false). Staro: campaign_destination_missing.
select pg_temp.rail(pg_temp.id('a001'), false);
select pg_temp.pada('0001', pg_temp.q_publish(pg_temp.id('c101')),
  'P0001', 'event_no_working_rail', 'publish: Stripe ne prima uplate (staro: nulta adresa) — RAZLIKA 352');
do $$
declare r jsonb;
begin
  r := pg_temp.rpc('0002', pg_temp.q_update_event(jsonb_build_object(
         'p_campaign_id', pg_temp.id('c101'), 'p_destination_address', pg_temp.adresa('13a1'))));
  -- RAZLIKA (odluka 351): adresa prihvaćena i odbačena (staro: upisan Safe); umjesto Safe-a
  -- organizator ponovno uključuje Stripe.
  perform pg_temp.ok((r->>'updated')::boolean and pg_temp.dogadjaj(pg_temp.id('c101'))->>'destination_address' is null,
    'publish priprema: adresa na c101 odbačena — RAZLIKA 351');
  perform pg_temp.rail(pg_temp.id('a001'), true);
end $$;
select pg_temp.pada('0004', pg_temp.q_publish(pg_temp.id('c101')), 'P0001', 'not_authorized', 'publish: običan član');
select pg_temp.pada('0005', pg_temp.q_publish(pg_temp.id('c101')), 'P0001', 'not_authorized', 'publish: ne-član (DEFINER vidi skicu)');
select pg_temp.pada('anon', pg_temp.q_publish(pg_temp.id('c101')), '42501', 'permission denied for function publish_event', 'publish: anon');
select pg_temp.pada('service', pg_temp.q_publish(pg_temp.id('c101')), 'P0001', 'not_authenticated', 'publish: service_role bez korisnika');
select pg_temp.pada('0001', pg_temp.q_publish(pg_temp.id('c101'), 'funded'), 'P0001', 'invalid_target_state', 'publish: cilj funded');
select pg_temp.pada('0001', pg_temp.q_publish(pg_temp.id('c101'), null), 'P0001', 'invalid_target_state', 'publish: cilj null');
select pg_temp.pada('0001', pg_temp.q_publish(pg_temp.id('cfff')), 'P0001', 'campaign_not_found', 'publish: nepostojeći');
-- RAZLIKA (odluka 355): nema campaign_not_tickets — donacija c0d0 ne postoji u ulaznice.events
select pg_temp.pada('0001', pg_temp.q_publish(pg_temp.id('c0d0')), 'P0001', 'campaign_not_found', 'publish: donacija (nije u ulaznice)');
select pg_temp.pada('0001', pg_temp.q_publish(pg_temp.id('c002'), 'closed'), 'P0001', 'invalid_state_transition', 'publish: skica → closed');
select pg_temp.pada('0005', pg_temp.q_publish(pg_temp.id('c003')), 'P0001', 'organizer_not_allowlisted', 'publish: račun nije na allowlisti');
do $$
declare r jsonb;
begin
  -- c101 ima plaćeni tier (2500) — NEMA rail gatea (Stripe Connect) u pinka_finance: objava prolazi.
  -- RAZLIKA (odluka 352): u ulaznice prolazi jer org A ima Stripe s charges_enabled (gore).
  r := pg_temp.rpc('0001', pg_temp.q_publish(pg_temp.id('c101')));
  perform pg_temp.isto_j('publish c101: odgovor', r,
    jsonb_build_object('campaign_id', pg_temp.id('c101'), 'state', 'active', 'visibility', 'public'));
  perform pg_temp.isto_j('publish c101: active + public (plaćeni tier, Stripe aktivan) — RAZLIKA 352',
    pg_temp.dio(pg_temp.dogadjaj(pg_temp.id('c101')), 'state', 'visibility'), '{"state":"active","visibility":"public"}');
  perform pg_temp.isto_n('publish c101: audit event.published', pg_temp.audit(pg_temp.id('a001'), 'event.published'), 1);
  perform pg_temp.isto_j('publish c101: audit payload', pg_temp.audit_payload(pg_temp.id('a001'), 'event.published'),
    jsonb_build_object('campaign_id', pg_temp.id('c101')));

  -- c102 bez ijednog tiera; objavljuje admin BEZ KYC-a — oboje prolazi
  r := pg_temp.rpc('0003', pg_temp.q_update_event(jsonb_build_object(
         'p_campaign_id', pg_temp.id('c102'), 'p_destination_address', pg_temp.adresa('13a1'))));
  r := pg_temp.rpc('0003', pg_temp.q_publish(pg_temp.id('c102')));
  perform pg_temp.isto_t('publish c102: bez tierova, admin bez KYC → active', r->>'state', 'active');
  perform pg_temp.isto_t('publish c102: stanje', pg_temp.stanje_eventa(pg_temp.id('c102')), 'active');

  -- RAZLIKA (odluka 353): events_write_guard za izravni update u 'active' traži allowlist i rail
  -- kao publish_event. Staro (BUG ORIGINALA): 1 red, c003 javno aktivan mimo allowliste.
  perform pg_temp.pada('0005', pg_temp.q_set_event_raw(pg_temp.id('c003'), '{"state":"active","visibility":"public"}'),
    'P0001', 'organizer_not_allowlisted', 'izravni update c003 → active mimo allowliste odbijen — RAZLIKA 353');
  perform pg_temp.isto_j('c003 (račun bez allowliste) ostaje skica — RAZLIKA 353',
    pg_temp.dio(pg_temp.dogadjaj(pg_temp.id('c003')), 'state', 'visibility'), '{"state":"draft","visibility":"private"}');
end $$;
select pg_temp.pada('0001', pg_temp.q_publish(pg_temp.id('c101')), 'P0001', 'invalid_state_transition', 'publish: active → active');
-- RAZLIKA (odluka 351): nulta adresa se prihvaća i odbacuje (staro: campaign_destination_missing)
select pg_temp.isto_j('update aktivnog: nulta adresa prihvaćena i odbačena — RAZLIKA 351',
  pg_temp.dio(pg_temp.rpc('0002', pg_temp.q_update_event(jsonb_build_object('p_campaign_id', pg_temp.id('c101'),
    'p_destination_address', pg_temp.nulta()))), 'updated'), '{"updated":true}');
-- RAZLIKA (odluka 353): izravni update skice → active prolazi isti gate kao publish_event; bez Safe-a
-- uvjet je radni rail (c002 ima plaćeni tier d003). Staro: campaign_destination_missing.
select pg_temp.rail(pg_temp.id('a001'), false);
select pg_temp.pada('0001', pg_temp.q_set_event_raw(pg_temp.id('c002'), '{"state":"active"}'),
  'P0001', 'event_no_working_rail', 'izravni update skice → active bez radnog raila — RAZLIKA 353');
select pg_temp.rail(pg_temp.id('a001'), true);
do $$
declare r jsonb;
begin
  perform pg_temp.isto_j('izravni update stanja: običan član → 0 redaka (RLS)',
    pg_temp.rpc('0004', pg_temp.q_set_event_raw(pg_temp.id('c002'), '{"state":"active"}')), '0');
  -- zatvaranje: active → closed; visibility ostaje
  r := pg_temp.rpc('0002', pg_temp.q_publish(pg_temp.id('c101'), 'closed'));
  perform pg_temp.isto_j('close c101: odgovor', r,
    jsonb_build_object('campaign_id', pg_temp.id('c101'), 'state', 'closed', 'visibility', 'public'));
  perform pg_temp.isto_t('close c101: stanje', pg_temp.stanje_eventa(pg_temp.id('c101')), 'closed');
  perform pg_temp.isto_n('close c101: audit event.closed', pg_temp.audit(pg_temp.id('a001'), 'event.closed'), 1);
end $$;
select pg_temp.pada('0002', pg_temp.q_publish(pg_temp.id('c101'), 'closed'), 'P0001', 'invalid_state_transition', 'close: closed → closed');
select pg_temp.pada('0002', pg_temp.q_publish(pg_temp.id('c101'), 'active'), 'P0001', 'invalid_state_transition', 'publish: closed → active');

\echo '--- 8. delete_event_draft'
select pg_temp.pada('0002', pg_temp.q_delete_draft(pg_temp.id('c001')), 'P0001', 'event_not_draft', 'delete: aktivan event');
select pg_temp.pada('0002', pg_temp.q_delete_draft(pg_temp.id('c101')), 'P0001', 'event_not_draft', 'delete: zatvoren event');
select pg_temp.pada('0002', pg_temp.q_delete_draft(pg_temp.id('c004')), 'P0001', 'event_has_orders', 'delete: skica s narudžbom');
select pg_temp.pada('0005', pg_temp.q_delete_draft(pg_temp.id('c002')), 'P0001', 'not_authorized', 'delete: tuđa skica (ne-član)');
select pg_temp.pada('0004', pg_temp.q_delete_draft(pg_temp.id('c002')), 'P0001', 'not_authorized', 'delete: običan član');
select pg_temp.pada('anon', pg_temp.q_delete_draft(pg_temp.id('c002')), '42501', 'permission denied for function delete_event_draft', 'delete: anon');
select pg_temp.pada('service', pg_temp.q_delete_draft(pg_temp.id('c002')), 'P0001', 'not_authenticated', 'delete: service_role bez korisnika');
select pg_temp.pada('0002', pg_temp.q_delete_draft(pg_temp.id('cfff')), 'P0001', 'campaign_not_found', 'delete: nepostojeći');
-- RAZLIKA (odluka 355): nema campaign_not_tickets — donacija c0d0 ne postoji u ulaznice.events
select pg_temp.pada('0002', pg_temp.q_delete_draft(pg_temp.id('c0d0')), 'P0001', 'campaign_not_found', 'delete: donacija (nije u ulaznice)');
do $$
declare r jsonb;
begin
  perform pg_temp.isto_n('delete priprema: c103 ima 0 tierova', jsonb_array_length(pg_temp.tierovi(pg_temp.id('c103'))), 0);
  r := pg_temp.rpc('0002', pg_temp.q_update_event(jsonb_build_object('p_campaign_id', pg_temp.id('c103'),
         'p_tiers', '[{"title":"T","price_cents":100}]'::jsonb)));
  r := pg_temp.rpc('0002', pg_temp.q_delete_draft(pg_temp.id('c103')));
  perform pg_temp.isto_j('delete c103: odgovor', r, jsonb_build_object('campaign_id', pg_temp.id('c103'), 'deleted', true));
  perform pg_temp.isto_j('delete c103: meko brisanje (red ostaje, skica, deleted)',
    pg_temp.dio(pg_temp.dogadjaj(pg_temp.id('c103')), 'state', 'deleted'), '{"state":"draft","deleted":true}');
  perform pg_temp.isto_n('delete c103: tierovi ostaju', jsonb_array_length(pg_temp.tierovi(pg_temp.id('c103'))), 1);
end $$;
select pg_temp.pada('0002', pg_temp.q_delete_draft(pg_temp.id('c103')), 'P0001', 'campaign_not_found', 'delete: ponovno brisanje');
select pg_temp.pada('0002', pg_temp.q_update_event(jsonb_build_object('p_campaign_id', pg_temp.id('c103'), 'p_title', 'Uskrsnuće')),
  'P0001', 'campaign_not_found', 'update obrisane skice');
select pg_temp.pada('0001', pg_temp.q_publish(pg_temp.id('c103')), 'P0001', 'campaign_not_found', 'publish obrisane skice');
-- ponovni create s istim id-em: idempotencija ga ne vidi (RLS deleted_at) → pkey sudar
select pg_temp.pada('0001', pg_temp.q_create_event(pg_temp.ev('c103', 'a001', 'Testni eventi staro 13 javni')),
  'P0001', 'campaign_exists', 'create s id-em obrisane skice');

\echo '--- 9. organizer_overview'
do $$
declare r jsonb; e jsonb;
begin
  r := pg_temp.rpc('0001', pg_temp.q_overview());
  perform pg_temp.isto_j('overview 0001: ključevi', pg_temp.kljucevi(r), '["accounts","events"]');
  perform pg_temp.isto_j('overview 0001: računi = osobni + org A',
    pg_temp.vrijednosti(r->'accounts', 'id'),
    (select jsonb_agg(to_jsonb(x) order by x::text) from unnest(array[pg_temp.osobni('0001'), pg_temp.id('a001')]) x));
  perform pg_temp.isto_j('overview 0001: org A (allowlisted, bez DAC7 zapisa)',
    pg_temp.element(r->'accounts', 'id', pg_temp.id('a001')::text),
    jsonb_build_object('id', pg_temp.id('a001'), 'name', 'Test eventi A', 'is_personal', false,
                       'allowlisted', true, 'has_record', false));
  perform pg_temp.isto_j('overview 0001: osobni račun (is_personal, nije allowlisted)',
    pg_temp.element(r->'accounts', 'id', pg_temp.osobni('0001')::text) - 'name' - 'id',
    '{"is_personal":true,"allowlisted":false,"has_record":false}');
  -- svi eventi org A osim obrisane c103 i donacije c0d0; skice uključene
  perform pg_temp.isto_j('overview 0001: eventi (skice da, obrisani i donacija ne)',
    pg_temp.vrijednosti(r->'events', 'campaign_id'),
    pg_temp.uuidi('c001', 'c002', 'c004', 'c101', 'c102', 'c105'));
  e := pg_temp.element(r->'events', 'campaign_id', pg_temp.id('c002')::text);
  perform pg_temp.isto_j('overview 0001: c002 puni oblik', e,
    jsonb_build_object('campaign_id', pg_temp.id('c002'), 'account_id', pg_temp.id('a001'),
      'slug', 'test-eventi-staro-skica', 'title', 'Test eventi: skica', 'state', 'draft',
      'visibility', 'private', 'destination_address', null,  -- RAZLIKA (odluka 351): staro nulta adresa
      'event', jsonb_build_object('event_type', 'koncert', 'venue_name', 'Testna dvorana',
        'venue_address', null, 'venue_city', 'Zagreb', 'starts_at', now() + interval '30 days',
        'ends_at', now() + interval '30 days 3 hours', 'timezone', 'Europe/Zagreb',
        'description_hr', null, 'description_en', null, 'cover_image_url', null,
        'organizer_name', 'Testni organizator', 'organizer_email', null, 'organizer_web', null),
      'tiers', jsonb_build_array(jsonb_build_object('id', pg_temp.id('d003'), 'title', 'Skica tier',
        'description', null, 'price_cents', 1000, 'inventory_total', 10, 'inventory_claimed', 0,
        'imenska', false, 'sale_start', null, 'sale_end', null, 'sort', 0))));
  -- ČUDNO: overview NE vraća gallery, attendance_mode, venue_lat/lon, cover_image_alt ni online_url
  -- (dodani kasnije izravnim pisovima) — editor ih ne može pročitati ovim pozivom.
  e := pg_temp.element(r->'events', 'campaign_id', pg_temp.id('c101')::text);
  perform pg_temp.isto_j('overview 0001: c101 event bez novih polja (ČUDNO)', pg_temp.kljucevi(e->'event'),
    '["cover_image_url","description_en","description_hr","ends_at","event_type","organizer_email","organizer_name","organizer_web","starts_at","timezone","venue_address","venue_city","venue_name"]');
  perform pg_temp.isto_j('overview 0001: c101 stanje i tierovi po sortu',
    jsonb_build_object('state', e->'state', 'tiers', pg_temp.vrijednosti(e->'tiers', 'title')),
    '{"state":"closed","tiers":["Imenska","Redovna+"]}');

  -- običan član: org A nije među računima (traži admin), nijedan event
  r := pg_temp.rpc('0004', pg_temp.q_overview());
  perform pg_temp.isto_j('overview član: samo osobni račun', pg_temp.vrijednosti(r->'accounts', 'id'),
    jsonb_build_array(pg_temp.osobni('0004')));
  perform pg_temp.isto_j('overview član: bez evenata', r->'events', '[]');

  -- admin bez KYC-a vidi isto što i vlasnik
  r := pg_temp.rpc('0003', pg_temp.q_overview());
  perform pg_temp.isto_j('overview admin bez KYC: isti eventi', pg_temp.vrijednosti(r->'events', 'campaign_id'),
    pg_temp.uuidi('c001', 'c002', 'c004', 'c101', 'c102', 'c105'));

  -- ne-član: samo svoj org B
  r := pg_temp.rpc('0005', pg_temp.q_overview());
  perform pg_temp.isto_j('overview org B: računi = osobni + org B', pg_temp.vrijednosti(r->'accounts', 'id'),
    (select jsonb_agg(to_jsonb(x) order by x::text) from unnest(array[pg_temp.osobni('0005'), pg_temp.id('a002')]) x));
  perform pg_temp.isto_j('overview org B: samo c003', pg_temp.vrijednosti(r->'events', 'campaign_id'), pg_temp.uuidi('c003'));
  perform pg_temp.isto_j('overview org B: allowlisted = false',
    pg_temp.element(r->'accounts', 'id', pg_temp.id('a002')::text)->'allowlisted', 'false');
end $$;
select pg_temp.pada('anon', pg_temp.q_overview(), '42501', 'permission denied for function organizer_overview', 'overview: anon');
select pg_temp.pada('service', pg_temp.q_overview(), 'P0001', 'not_authenticated', 'overview: service_role bez korisnika');

\echo '--- 10. upsert_organizer_record'
create function pg_temp.zap(p_acc text, p_extra jsonb default '{}'::jsonb) returns jsonb language sql as $$
  select jsonb_build_object('p_account_id', pg_temp.id(p_acc), 'p_legal_name', ' Test d.o.o. ',
    'p_oib', '12345678901', 'p_address_line', ' Ilica 1 ', 'p_city', ' Zagreb ', 'p_postal_code', ' 10000 ',
    'p_country_code', 'HR', 'p_contact_email', '  ', 'p_financial_identifier_type', 'iban',
    'p_financial_identifier', 'HR1210010051863000160') || p_extra
$$;
do $$
declare r jsonb;
begin
  r := pg_temp.rpc('0001', pg_temp.q_upsert_record(pg_temp.zap('a001')));
  perform pg_temp.isto_j('record a001 (vlasnik): odgovor', r, jsonb_build_object('account_id', pg_temp.id('a001'), 'saved', true));
  perform pg_temp.isto_j('record a001: spremljeno (trim, prazan email → null)', pg_temp.zapis(pg_temp.id('a001')),
    jsonb_build_object('account_id', pg_temp.id('a001'), 'legal_name', 'Test d.o.o.', 'oib', '12345678901',
      'address_line', 'Ilica 1', 'city', 'Zagreb', 'postal_code', '10000', 'country_code', 'HR',
      'contact_email', null, 'financial_identifier_type', 'iban', 'financial_identifier', 'HR1210010051863000160'));
  r := pg_temp.rpc('0002', pg_temp.q_upsert_record(pg_temp.zap('a001',
         jsonb_build_object('p_legal_name', 'Novo ime d.o.o.', 'p_contact_email', ' dac7@example.com ',
                            'p_financial_identifier_type', 'safe_address',
                            'p_financial_identifier', pg_temp.adresa('13a1')))));
  perform pg_temp.isto_j('record a001 (admin): update', pg_temp.dio(pg_temp.zapis(pg_temp.id('a001')),
      'legal_name', 'contact_email', 'financial_identifier_type', 'financial_identifier'),
    jsonb_build_object('legal_name', 'Novo ime d.o.o.', 'contact_email', 'dac7@example.com',
      'financial_identifier_type', 'safe_address', 'financial_identifier', pg_temp.adresa('13a1')));
  perform pg_temp.isto_n('record a001: audit organizer_record.upserted ×2', pg_temp.audit(pg_temp.id('a001'), 'organizer_record.upserted'), 2);
  perform pg_temp.isto_j('record a001: audit bez PII', pg_temp.audit_payload(pg_temp.id('a001'), 'organizer_record.upserted'),
    jsonb_build_object('account_id', pg_temp.id('a001')));
  -- admin bez KYC-a smije
  r := pg_temp.rpc('0003', pg_temp.q_upsert_record(pg_temp.zap('a001', '{"p_legal_name":"Treće ime"}')));
  perform pg_temp.ok((r->>'saved')::boolean, 'record a001: admin bez KYC smije');
  -- operater (service_role) za bilo koji račun
  r := pg_temp.rpc('service', pg_temp.q_upsert_record(pg_temp.zap('a002')));
  perform pg_temp.isto_j('record a002 (service_role): odgovor', r, jsonb_build_object('account_id', pg_temp.id('a002'), 'saved', true));
  -- čitanje (RLS: admin računa)
  perform pg_temp.isto_j('record: admin vidi', pg_temp.rpc('0002', pg_temp.q_vidi_zapis(pg_temp.id('a001'))), '1');
  perform pg_temp.isto_j('record: običan član ne vidi', pg_temp.rpc('0004', pg_temp.q_vidi_zapis(pg_temp.id('a001'))), '0');
  perform pg_temp.isto_j('record: ne-član ne vidi', pg_temp.rpc('0005', pg_temp.q_vidi_zapis(pg_temp.id('a001'))), '0');
  r := pg_temp.rpc('0001', pg_temp.q_overview());
  perform pg_temp.isto_j('overview nakon recorda: has_record = true',
    pg_temp.element(r->'accounts', 'id', pg_temp.id('a001')::text)->'has_record', 'true');
end $$;
select pg_temp.pada('0004', pg_temp.q_upsert_record(pg_temp.zap('a001')), 'P0001', 'not_authorized', 'record: običan član');
select pg_temp.pada('0005', pg_temp.q_upsert_record(pg_temp.zap('a001')), 'P0001', 'not_authorized', 'record: ne-član');
select pg_temp.pada('anon', pg_temp.q_upsert_record(pg_temp.zap('a001')), '42501', 'permission denied for function upsert_organizer_record', 'record: anon');
select pg_temp.pada('0001', pg_temp.q_upsert_record(pg_temp.zap('a001', '{"p_legal_name":" "}')), 'P0001', 'invalid_legal_name', 'record: prazno ime');
select pg_temp.pada('0001', pg_temp.q_upsert_record(pg_temp.zap('a001', '{"p_oib":"1234567890"}')), 'P0001', 'invalid_oib', 'record: OIB 10 znamenki');
select pg_temp.pada('0001', pg_temp.q_upsert_record(pg_temp.zap('a001', '{"p_address_line":""}')), 'P0001', 'invalid_address', 'record: prazna adresa');
select pg_temp.pada('0001', pg_temp.q_upsert_record(pg_temp.zap('a001', '{"p_city":" "}')), 'P0001', 'invalid_city', 'record: prazan grad');
select pg_temp.pada('0001', pg_temp.q_upsert_record(pg_temp.zap('a001', '{"p_postal_code":""}')), 'P0001', 'invalid_postal_code', 'record: prazan poštanski');
select pg_temp.pada('0001', pg_temp.q_upsert_record(pg_temp.zap('a001', '{"p_country_code":"hr"}')), 'P0001', 'invalid_country_code', 'record: država malim slovima');
select pg_temp.pada('0001', pg_temp.q_upsert_record(pg_temp.zap('a001', jsonb_build_object('p_contact_email', repeat('e', 201)))), 'P0001', 'invalid_contact_email', 'record: email > 200');
select pg_temp.pada('0001', pg_temp.q_upsert_record(pg_temp.zap('a001', '{"p_financial_identifier_type":"paypal"}')), 'P0001', 'invalid_financial_identifier_type', 'record: tip identifikatora');
select pg_temp.pada('0001', pg_temp.q_upsert_record(pg_temp.zap('a001', jsonb_build_object('p_financial_identifier', pg_temp.adresa('13a1')))), 'P0001', 'invalid_financial_identifier', 'record: IBAN tip, Safe vrijednost');
select pg_temp.pada('0001', pg_temp.q_upsert_record(pg_temp.zap('a001', '{"p_financial_identifier":null}')), 'P0001', 'invalid_financial_identifier', 'record: identifikator null');
do $$ begin
  perform pg_temp.isto_t('record a001: nakon odbijenih ime i dalje „Treće ime”',
    pg_temp.zapis(pg_temp.id('a001'))->>'legal_name', 'Treće ime');
end $$;

\echo '--- 11. izravno brisanje tiera OBJAVLJENOG eventa (edge provjerava skicu, baza ne)'
do $$
declare r jsonb;
begin
  -- BUG ORIGINALA: RLS tiers_write dopušta adminu brisanje tiera aktivnog eventa, i onog s
  -- plaćenom narudžbom (FK on delete set null → narudžba ostaje bez tiera). Edge
  -- (removeDraftTiers) provjerava „samo skica” tek u TS-u, prije delete-a.
  -- RAZLIKA (odluka 359): trigger ticket_tiers_write_guard odbija brisanje tiera događaja koji
  -- nije skica (event_not_draft, isti kod kao edge). Staro: 1 red; f001 ostaje bez tiera.
  perform pg_temp.pada('0002', pg_temp.q_obrisi_tierove(pg_temp.id('c001'), array[pg_temp.id('d002')]),
    'P0001', 'event_not_draft', 'aktivan c001: admin briše tier bez narudžbi — RAZLIKA 359');
  perform pg_temp.pada('0002', pg_temp.q_obrisi_tierove(pg_temp.id('c001'), array[pg_temp.id('d001')]),
    'P0001', 'event_not_draft', 'aktivan c001: admin briše tier s plaćenom narudžbom — RAZLIKA 359');
  perform pg_temp.ok(pg_temp.narudzba_tier(pg_temp.id('f001')) = pg_temp.id('d001'),
    'plaćena narudžba f001 zadržava tier — RAZLIKA 359');
  perform pg_temp.isto_j('aktivan c001: ne-član briše tier → 0 redaka',
    pg_temp.rpc('0005', pg_temp.q_obrisi_tierove(pg_temp.id('c001'),
      array[(pg_temp.element(pg_temp.tierovi(pg_temp.id('c001')), 'title', 'Kasna')->>'id')::uuid])), '0');
end $$;
-- RAZLIKA (odluka 359): zatvoren događaj isto (event_not_draft); tier skice s narudžbom →
-- tier_has_orders (bez triggera FK orders.tier_id baca sirovi 23503).
select pg_temp.pada('0002', pg_temp.q_obrisi_tierove(pg_temp.id('c101'),
         array[(pg_temp.element(pg_temp.tierovi(pg_temp.id('c101')), 'title', 'Imenska')->>'id')::uuid]),
  'P0001', 'event_not_draft', 'zatvoren c101: admin briše tier — RAZLIKA 359');
select pg_temp.pada('0002', pg_temp.q_obrisi_tierove(pg_temp.id('c004'), array[pg_temp.id('d005')]),
  'P0001', 'tier_has_orders', 'skica c004: admin briše tier s narudžbom — RAZLIKA 359');

\echo '--- 12. rail gate (port rail dijela 20260903_rail_gate_i_rotacija.sql, bez onchain/Safe) i pisovi tierova'
-- RAZLIKA (odluke 352, 353, 357, 359): sve u ovom scenariju je novo ponašanje ulaznice.
-- Org S (a004, allowlist) na početku nema Stripe. c301 i c304 imaju plaćeni tier,
-- c302 samo besplatne, c303 nijedan.
do $$
declare r jsonb;
begin
  r := pg_temp.rpc('0007', pg_temp.q_create_event(pg_temp.ev('c301', 'a004', 'Testni eventi rail placeni',
         '{"p_tiers":[{"title":"Redovna","price_cents":14900,"inventory_total":10}]}')));
  r := pg_temp.rpc('0007', pg_temp.q_create_event(pg_temp.ev('c302', 'a004', 'Testni eventi rail besplatni',
         '{"p_tiers":[{"title":"Besplatna","price_cents":0},{"title":"Gost","price_cents":"0"}]}')));
  r := pg_temp.rpc('0007', pg_temp.q_create_event(pg_temp.ev('c303', 'a004', 'Testni eventi rail bez tierova')));
  r := pg_temp.rpc('0007', pg_temp.q_create_event(pg_temp.ev('c304', 'a004', 'Testni eventi rail patch',
         '{"p_tiers":[{"title":"Redovna","price_cents":900}]}')));
  perform pg_temp.isto_j('rail: event_rail_ready (service_role) bez Stripea — c301 ne, c302 i c303 da',
    jsonb_build_array(pg_temp.rpc('service', pg_temp.q_rail_ready(pg_temp.id('a004'), pg_temp.id('c301'))),
                      pg_temp.rpc('service', pg_temp.q_rail_ready(pg_temp.id('a004'), pg_temp.id('c302'))),
                      pg_temp.rpc('service', pg_temp.q_rail_ready(pg_temp.id('a004'), pg_temp.id('c303')))),
    '[false,true,true]');
end $$;
select pg_temp.pada('0007', pg_temp.q_rail_ready(pg_temp.id('a004'), pg_temp.id('c301')),
  '42501', 'permission denied for function event_rail_ready', 'rail: event_rail_ready nije izložen authenticated');
-- 1. bez Stripe raila: plaćeni tier → event_no_working_rail (RPC i izravni PATCH)
select pg_temp.pada('0007', pg_temp.q_publish(pg_temp.id('c301')),
  'P0001', 'event_no_working_rail', 'rail: plaćeni tier bez Stripea — publish_event');
select pg_temp.pada('0007', pg_temp.q_set_event_raw(pg_temp.id('c301'), '{"state":"active","visibility":"public"}'),
  'P0001', 'event_no_working_rail', 'rail: plaćeni tier bez Stripea — izravni PATCH');
-- 3. charges_enabled = false → i dalje odbijeno
select pg_temp.rail(pg_temp.id('a004'), false);
select pg_temp.pada('0007', pg_temp.q_publish(pg_temp.id('c301')),
  'P0001', 'event_no_working_rail', 'rail: charges_enabled=false — publish_event');
select pg_temp.pada('0007', pg_temp.q_set_event_raw(pg_temp.id('c301'), '{"state":"active"}'),
  'P0001', 'event_no_working_rail', 'rail: charges_enabled=false — izravni PATCH');
do $$
declare r jsonb; t_free uuid;
begin
  perform pg_temp.isto_t('rail: c301 nakon odbijenih i dalje skica', pg_temp.stanje_eventa(pg_temp.id('c301')), 'draft');
  -- samo besplatni tierovi / bez tierova prolaze bez Stripea (red raila obrisan)
  perform pg_temp.rail(pg_temp.id('a004'), null);
  r := pg_temp.rpc('0007', pg_temp.q_publish(pg_temp.id('c302')));
  perform pg_temp.isto_t('rail: samo besplatni tierovi bez Stripea — publish prolazi', r->>'state', 'active');
  r := pg_temp.rpc('0007', pg_temp.q_set_event_raw(pg_temp.id('c303'), '{"state":"active","visibility":"public"}'));
  perform pg_temp.isto_j('rail: bez tierova bez Stripea — izravni PATCH prolazi (1 red)', r, '1');
  perform pg_temp.isto_t('rail: c303 aktivan', pg_temp.stanje_eventa(pg_temp.id('c303')), 'active');

  -- 357: aktivan c302 bez Stripea ne smije postati plaćen
  t_free := (pg_temp.element(pg_temp.tierovi(pg_temp.id('c302')), 'title', 'Besplatna')->>'id')::uuid;
  perform pg_temp.pada('0007', pg_temp.q_update_event(jsonb_build_object('p_campaign_id', pg_temp.id('c302'),
           'p_tiers', '[{"title":"Plaćena","price_cents":500}]'::jsonb)),
    'P0001', 'event_no_working_rail', '357: update_event dodaje plaćeni tier aktivnom eventu bez Stripea');
  perform pg_temp.pada('0007', pg_temp.q_insert_tier_raw(pg_temp.id('c302'), pg_temp.id('d3a1'), 500),
    'P0001', 'event_no_working_rail', '357: izravni insert plaćenog tiera bez Stripea');
  perform pg_temp.pada('0007', pg_temp.q_set_tier_raw(t_free, 500),
    'P0001', 'event_no_working_rail', '357: izravna promjena cijene 0 → 500 bez Stripea');
  perform pg_temp.pada('0007', pg_temp.q_update_event(jsonb_build_object('p_campaign_id', pg_temp.id('c302'),
           'p_tiers', jsonb_build_array(jsonb_build_object('id', t_free, 'title', 'Besplatna', 'price_cents', 500)))),
    'P0001', 'tier_locked', '357: update_event cijena postojećeg tiera aktivnog eventa → tier_locked (prije gatea)');
  r := pg_temp.rpc('0007', pg_temp.q_insert_tier_raw(pg_temp.id('c302'), pg_temp.id('d3a2'), 0));
  perform pg_temp.isto_j('357: besplatni tier na aktivnom eventu bez Stripea smije', r, '1');
  r := pg_temp.rpc('0007', pg_temp.q_update_event(jsonb_build_object('p_campaign_id', pg_temp.id('c303'),
         'p_tiers', '[{"title":"Besplatna 2","price_cents":0}]'::jsonb)));
  perform pg_temp.isto_j('357: update_event besplatni novi tier bez Stripea smije', pg_temp.dio(r, 'tiers_added'), '{"tiers_added":1}');
  r := pg_temp.rpc('service', pg_temp.q_insert_tier_raw(pg_temp.id('c303'), pg_temp.id('d3a3'), 500));
  perform pg_temp.isto_j('357: service_role zaobilazi gate (kao events_write_guard)', r, '1');
  perform pg_temp.isto_n('357: c302 i dalje bez plaćenih tierova',
    (select count(*) from jsonb_array_elements(pg_temp.tierovi(pg_temp.id('c302'))) t where (t->>'price_cents')::integer > 0), 0);

  -- 2. Stripe s charges_enabled = true: objava i plaćeni tierovi prolaze
  perform pg_temp.rail(pg_temp.id('a004'), true);
  perform pg_temp.isto_j('rail: event_rail_ready c301 sa Stripeom',
    pg_temp.rpc('service', pg_temp.q_rail_ready(pg_temp.id('a004'), pg_temp.id('c301'))), 'true');
  r := pg_temp.rpc('0007', pg_temp.q_publish(pg_temp.id('c301')));
  perform pg_temp.isto_j('rail: charges_enabled=true — publish_event prolazi', r,
    jsonb_build_object('campaign_id', pg_temp.id('c301'), 'state', 'active', 'visibility', 'public'));
  r := pg_temp.rpc('0007', pg_temp.q_set_event_raw(pg_temp.id('c304'), '{"state":"active","visibility":"public"}'));
  perform pg_temp.isto_j('rail: charges_enabled=true — izravni PATCH prolazi (1 red)', r, '1');
  r := pg_temp.rpc('0007', pg_temp.q_insert_tier_raw(pg_temp.id('c302'), pg_temp.id('d3a4'), 700));
  perform pg_temp.isto_j('357: sa Stripeom plaćeni tier na aktivnom eventu smije', r, '1');
  r := pg_temp.rpc('0007', pg_temp.q_set_tier_raw(t_free, 500));
  perform pg_temp.isto_j('357: sa Stripeom cijena 0 → 500 smije', r, '1');

  -- 359: brisanje tiera aktivnog eventa i sa Stripeom pada; skica smije
  perform pg_temp.pada('0007', pg_temp.q_obrisi_tierove(pg_temp.id('c302'), array[pg_temp.id('d3a2')]),
    'P0001', 'event_not_draft', '359: izravno brisanje tiera aktivnog eventa');
end $$;

do $$ begin
  raise notice 'SVE PROVJERE PROŠLE (% provjera)', current_setting('test.provjere');
end $$;

rollback;
