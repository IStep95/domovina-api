-- Port testa starog ponašanja (20261125_ulaznice_rpc_narudzbe_staro.sql) na shemu
-- ulaznice (lanac docs/ulaznice-shema/, S3): ISTI scenariji 1–8 nad RPC-ima iz
-- 20261125160000_ulaznice_rpc_narudzbe.sql, plus 9. rotate_ticket_tokens (port
-- dijela o rotaciji iz git show e77f9ae:supabase/tests/20260903_rail_gate_i_rotacija.sql;
-- rail gate je S3b).
--
-- Pravilo: isti scenarij daje isti rezultat kao nad pinka_finance, osim namjernih
-- razlika porta; svaka je označena „-- RAZLIKA (odluka 30x):” uz provjeru:
--   300 onchain ukinut: p_payer_address ≠ null → onchain_rail_removed;
--       destination_address u odgovoru create = null; tx_hash u deliver = null
--   301 payment_rail 'free' (0 €) / 'stripe' već na create; nema campaign_not_tickets
--       ni tier_not_ticket (donacije i tier kind ne postoje u ulaznice); rate limit
--       samo po buyer_account_id
--   302 confirm s railom 'stripe' na narudžbi od 0 € → invalid_rail
--   303 expired→paid: claimed raste točno za quantity (original +2× — BUG ORIGINALA)
--   304 audit 'contribution.<state>' ostaje, payload bez tx_hash
--   305 list_my_tickets: ključevi contribution_id/campaign_id/campaign_title ostaju (ISTO)
--   306 nema campaign_stats (provjere agregata → provjera da tablica ne postoji);
--       void_ticket i dalje ne vraća inventar (ISTO kao original)
--   307 ključ advisory locka serijala 'ulaznice_tickets_' || event_id (nije vidljivo testom)
--
-- Pokretanje nad lokalnim stackom (sve u jednoj transakciji s ROLLBACK-om):
--   psql postgresql://postgres:postgres@127.0.0.1:55322/postgres -v ON_ERROR_STOP=1 \
--        -f supabase/tests/20261125_ulaznice_rpc_narudzbe.sql
--
-- Očekivano: NOTICE redci "OK — …" i na kraju NOTICE "SVE PROVJERE PROŠLE (N provjera)".
--
-- STRUKTURA (kao u staro.sql): A. pomoćnici (doslovno) | B. ADAPTER (ulaznice) |
-- C. fixture (ulaznice) | D. scenariji 1–8 (doslovno osim RAZLIKA) | 9. rotacija.
\set ON_ERROR_STOP on
\timing off
\pset pager off

begin;

-- ════════════════════════════════════════════════════════════════════════════
-- A. generički pomoćnici
-- ════════════════════════════════════════════════════════════════════════════

-- Testni ID: 4 hex znaka iza prefiksa (drugi prefiks nego 20261125_ulaznice_shema.sql).
create function pg_temp.id(p text) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-00000012' || p)::uuid
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

-- Element jsonb niza s danim order_id.
create function pg_temp.po_narudzbi(j jsonb, p_order uuid) returns jsonb language sql immutable as $$
  select e from jsonb_array_elements(j) e where (e->>'order_id')::uuid = p_order
$$;

-- QR tokeni dobiveni jednokratnom dostavom (deliver), po serialu.
create temp table tokeni (serial text primary key, ticket_id uuid not null, token text not null)
  on commit drop;

-- ════════════════════════════════════════════════════════════════════════════
-- B. ADAPTER — jedino mjesto s nazivima shema/tablica/RPC-a (ulaznice)
-- ════════════════════════════════════════════════════════════════════════════

-- ── pozivi RPC-a (vraćaju SQL koji daje jedan jsonb) ──
-- Parametar ostaje p_campaign_id (odluka 3), poziv je pozicijski.
create function pg_temp.q_create(p_order uuid, p_event uuid, p_tier uuid, p_qty integer,
                                 p_holders jsonb default '[]'::jsonb) returns text language sql as $$
  select format('select ulaznice.create_ticket_order(%L::uuid, %L::uuid, %L::uuid, %L::integer, %L::jsonb)',
                p_order, p_event, p_tier, p_qty, p_holders)
$$;
-- RAZLIKA (odluka 300): p_payer_address ostaje u potpisu, ne-null vrijednost baca onchain_rail_removed.
create function pg_temp.q_create_payer(p_order uuid, p_event uuid, p_tier uuid, p_qty integer,
                                       p_payer text) returns text language sql as $$
  select format('select ulaznice.create_ticket_order(%L::uuid, %L::uuid, %L::uuid, %L::integer, %L::jsonb, %L::text)',
                p_order, p_event, p_tier, p_qty, '[]', p_payer)
$$;
create function pg_temp.q_confirm(p_order uuid, p_rail text, p_ref text, p_amount bigint,
                                  p_email text default null) returns text language sql as $$
  select format('select ulaznice.confirm_ticket_order_offchain(%L::uuid, %L::text, %L::text, %L::bigint, %L::text)',
                p_order, p_rail, p_ref, p_amount, p_email)
$$;
create function pg_temp.q_expire() returns text language sql as $$
  select 'select to_jsonb(ulaznice.expire_stale_ticket_orders())'
$$;
create function pg_temp.q_deliver(p_orders uuid[]) returns text language sql as $$
  select format('select ulaznice.deliver_ticket_orders(%L::uuid[])', p_orders)
$$;
-- list_my_tickets vraća TABLE → jsonb niz redaka, sortiran po serialu.
create function pg_temp.q_list_my() returns text language sql as $$
  select 'select coalesce(jsonb_agg(to_jsonb(x) order by x.serial), ''[]''::jsonb) from ulaznice.list_my_tickets() x'
$$;
create function pg_temp.q_redeem(p_token text) returns text language sql as $$
  select format('select ulaznice.redeem_ticket(%L::text)', p_token)
$$;
create function pg_temp.q_void(p_ticket uuid) returns text language sql as $$
  select format('select ulaznice.void_ticket(%L::uuid)', p_ticket)
$$;
create function pg_temp.q_refund(p_order uuid, p_amount bigint default null, p_reason text default null,
                                 p_ref text default null) returns text language sql as $$
  select format('select ulaznice.refund_ticket_order(%L::uuid, %L::bigint, %L::text, %L::text)',
                p_order, p_amount, p_reason, p_ref)
$$;
create function pg_temp.q_rotate(p_order uuid) returns text language sql as $$
  select format('select ulaznice.rotate_ticket_tokens(%L::uuid)', p_order)
$$;

-- ── poznate razlike oblika odgovora ──
-- RAZLIKA (odluka 300): ključ destination_address ostaje, vrijednost je null (onchaina nema).
create function pg_temp.a_create_extra() returns jsonb language sql as $$
  select jsonb_build_object('destination_address', null)
$$;
-- deliver_ticket_orders: ključ tx_hash ostaje (odluka 3); vrijednost v. RAZLIKA 300 u scenariju 5.
create function pg_temp.a_deliver_extra_kljucevi() returns jsonb language sql as $$
  select '["tx_hash"]'::jsonb
$$;
-- ISTO (odluka 305): list_my_tickets zadržava contribution_id/campaign_id/campaign_title.
create function pg_temp.a_list_kljucevi() returns jsonb language sql as $$
  select '["campaign_id","campaign_title","checked_in_at","contribution_id","created_at","holder_name","serial","state","ticket_id"]'::jsonb
$$;

-- ── čitanje stanja ──
create function pg_temp.narudzba(p_order uuid) returns jsonb language sql as $$
  select jsonb_build_object(
    'state', o.state, 'event_id', o.event_id, 'tier_id', o.tier_id,
    'buyer', o.buyer_account_id, 'amount_cents', o.amount_cents,
    'amount_received_cents', o.amount_received_cents, 'quantity', o.quantity,
    'reserved', o.reserved, 'reserve_expires_at', o.reserve_expires_at,
    'payment_rail', o.payment_rail, 'external_payment_ref', o.external_payment_ref,
    'buyer_email', o.buyer_email, 'paid_at', o.paid_at, 'holders', o.holders,
    'verified', o.contributor_verified)
  from ulaznice.orders o where o.id = p_order
$$;
create function pg_temp.stanje(p_order uuid) returns text language sql as $$
  select state from ulaznice.orders where id = p_order
$$;
create function pg_temp.claimed(p_tier uuid) returns integer language sql as $$
  select inventory_claimed from ulaznice.ticket_tiers where id = p_tier
$$;
-- Simulacija isteka TTL-a: rezervacija istekla prije minutu.
create function pg_temp.istekni(p_order uuid) returns void language sql as $$
  update ulaznice.orders
     set reserve_expires_at = now() - interval '1 minute' where id = p_order
$$;
create function pg_temp.broj_ulaznica(p_order uuid, p_state text default null) returns integer language sql as $$
  select count(*)::integer from ulaznice.tickets
   where order_id = p_order and (p_state is null or state::text = p_state)
$$;
create function pg_temp.ulaznice_narudzbe(p_order uuid) returns jsonb language sql as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', t.id, 'serial', t.serial, 'state', t.state::text, 'tier_id', t.tier_id,
           'event_id', t.event_id, 'holder_name', t.holder_name, 'holder_email', t.holder_email,
           'qr_token_hash', t.qr_token_hash, 'qr_token_once', t.qr_token_once,
           'checked_in_at', t.checked_in_at, 'checked_in_by', t.checked_in_by) order by t.serial), '[]'::jsonb)
    from ulaznice.tickets t where t.order_id = p_order
$$;
create function pg_temp.ulaznica(p_serial text) returns jsonb language sql as $$
  select jsonb_build_object('id', t.id, 'state', t.state::text, 'checked_in_at', t.checked_in_at,
                            'checked_in_by', t.checked_in_by)
    from ulaznice.tickets t where t.serial = p_serial and t.event_id = pg_temp.id('c001')
$$;
-- event_type 'contribution.<state>' ostaje (odluka 304).
create function pg_temp.audit(p_order uuid, p_type text) returns integer language sql as $$
  select count(*)::integer from ulaznice.order_events
   where order_id = p_order and event_type = p_type
$$;
create function pg_temp.audit_payload(p_order uuid, p_type text) returns jsonb language sql as $$
  select payload from ulaznice.order_events
   where order_id = p_order and event_type = p_type order by created_at desc, id desc limit 1
$$;
-- RAZLIKA (odluka 306): ulaznice nema campaign_stats; provjere agregata postaju
-- provjera da tablica ne postoji.
create function pg_temp.nema_statistike() returns boolean language sql as $$
  select to_regclass('ulaznice.campaign_stats') is null
$$;
create function pg_temp.stanje_eventa(p_event uuid) returns text language sql as $$
  select state from ulaznice.events where id = p_event
$$;

-- ════════════════════════════════════════════════════════════════════════════
-- C. fixture
-- ════════════════════════════════════════════════════════════════════════════
-- Korisnici: 0001 vlasnik org A (KYC) | 0002 admin org A | 0003 kupac K1 |
--            0004 vlasnik org B (drugi korisnik/kupac) | 0005 običan član org A |
--            0006 kupac za rate limit.
-- Org računi: a001 (A), a002 (B).
-- Eventi: c001 aktivan A | c002 skica A | c004 closed A (u staro.sql funded) | c005 aktivan B.
--   c0d0 (donacija u staro.sql) se NE stvara: donacije nisu u ulaznice (odluka 301).
-- Tierovi c001: d001 Redovna 20 € inv 5 | d002 Besplatna 0 € inv 100 | d003 Mala 15 € inv 1 |
--   d004 Imenska 30 € neograničena | d005 prodaja još nije počela | d006 prodaja završila |
--   d007 (kind=reward u staro.sql; ovdje običan tier, odluka 301) | d008 5 € neograničena.
--   d009 tier eventa c005 | d00a tier skice c002 | d00b tier closed c004.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                        email_confirmed_at, created_at, updated_at,
                        raw_app_meta_data, raw_user_meta_data)
select pg_temp.id(n), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       'test-ulaznice-rpc-' || n || '@example.com', crypt('demo1234', gen_salt('bf')),
       now(), now(), now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb
  from unnest(array['0001','0002','0003','0004','0005','0006']) n;

insert into public.accounts (id, primary_owner_user_id, is_personal_account, slug, name)
values (pg_temp.id('a001'), pg_temp.id('0001'), false, 'test-ulaznice-rpc-org-a', 'Test RPC A'),
       (pg_temp.id('a002'), pg_temp.id('0004'), false, 'test-ulaznice-rpc-org-b', 'Test RPC B');

insert into public.accounts_memberships (account_id, user_id, account_role)
values (pg_temp.id('a001'), pg_temp.id('0001'), 'owner'),
       (pg_temp.id('a001'), pg_temp.id('0002'), 'admin'),
       (pg_temp.id('a001'), pg_temp.id('0005'), 'member'),
       (pg_temp.id('a002'), pg_temp.id('0004'), 'owner')
on conflict (account_id, user_id) do update set account_role = excluded.account_role;

insert into public.identity_verifications (user_id, oib_ciphertext, oib_hash)
values (pg_temp.id('0001'), '\x00'::bytea, 'test-ulaznice-rpc-oib-hash-0001');

-- slugovi počinju s „test” → prefiks serijala TES (kao u staro.sql)
insert into ulaznice.events (id, account_id, slug, title, currency, state, visibility,
                             event_type, venue_name, venue_city, starts_at, ends_at, organizer_name)
select pg_temp.id(v.id), pg_temp.id(v.acc), v.slug, v.title, 'eur', v.state, 'public',
       'koncert', 'Testna dvorana', 'Zagreb', now() + interval '30 days',
       now() + interval '30 days 3 hours', 'Testni organizator'
  from (values
    ('c001', 'a001', 'test-rpc-novo-aktivan', 'Test RPC: aktivan', 'active'),
    ('c002', 'a001', 'test-rpc-novo-skica',   'Test RPC: skica',   'draft'),
    ('c004', 'a001', 'test-rpc-novo-closed',  'Test RPC: funded',  'closed'),
    ('c005', 'a002', 'test-rpc-novo-tudji',   'Test RPC: org B',   'active')
  ) v(id, acc, slug, title, state);

insert into ulaznice.ticket_tiers (id, event_id, title, price_cents, inventory_total, sort,
                                   imenska, sale_start, sale_end)
select pg_temp.id(v.id), pg_temp.id(v.c), v.title, v.price, v.inv, v.sort, v.imenska, v.ss, v.se
  from (values
    ('d001', 'c001', 'Redovna',    2000, 5,    0, false, null::timestamptz, null::timestamptz),
    ('d002', 'c001', 'Besplatna',     0, 100,  1, false, null, null),
    ('d003', 'c001', 'Mala',       1500, 1,    2, false, null, null),
    ('d004', 'c001', 'Imenska',    3000, null, 3, true,  null, null),
    ('d005', 'c001', 'Buduća',     1000, 10,   4, false, now() + interval '1 day', null),
    ('d006', 'c001', 'Prošla',     1000, 10,   5, false, null, now() - interval '1 day'),
    ('d007', 'c001', 'Nagrada',    1000, 10,   6, false, null, null),
    ('d008', 'c001', 'Neograničena', 500, null, 7, false, null, null),
    ('d009', 'c005', 'Tier B',     1500, 10,   0, false, null, null),
    ('d00a', 'c002', 'Skica tier', 1000, 10,   0, false, null, null),
    ('d00b', 'c004', 'Funded tier',1000, 10,   0, false, null, null)
  ) v(id, c, title, price, inv, sort, imenska, ss, se);

-- Normalizacija: istekle tuđe rezervacije u lokalnoj bazi (unutar ove transakcije)
-- oslobodi odmah, da kasnije brojanje expire_stale_ticket_orders bude točno.
select ulaznice.expire_stale_ticket_orders() >= 0 as normalizirano;

-- ════════════════════════════════════════════════════════════════════════════
-- D. scenariji (doslovno iz staro.sql osim redaka „-- RAZLIKA (odluka 30x):”)
-- ════════════════════════════════════════════════════════════════════════════

\echo '--- 1. rezervacija: create_ticket_order'
do $$
declare r jsonb; ocek jsonb;
begin
  perform pg_temp.isto_n('fixture: d001 claimed = 0', pg_temp.claimed(pg_temp.id('d001')), 0);

  r := pg_temp.rpc('0003', pg_temp.q_create(pg_temp.id('e001'), pg_temp.id('c001'), pg_temp.id('d001'), 2));
  ocek := jsonb_build_object('order_id', pg_temp.id('e001'), 'state', 'pending', 'amount_cents', 4000,
                             'currency', 'eur', 'expires_at', now() + interval '20 minutes',
                             'existing', false) || pg_temp.a_create_extra();
  perform pg_temp.isto_j('create e001 (2 × 20 €): odgovor', r, ocek);
  perform pg_temp.isto_j('create e001: stanje narudžbe',
    pg_temp.narudzba(pg_temp.id('e001')) - 'paid_at',
    jsonb_build_object('state', 'pending', 'event_id', pg_temp.id('c001'), 'tier_id', pg_temp.id('d001'),
      'buyer', pg_temp.osobni('0003'), 'amount_cents', 4000, 'amount_received_cents', null,
      'quantity', 2, 'reserved', true, 'reserve_expires_at', now() + interval '20 minutes',
      -- RAZLIKA (odluka 301): rail se postavlja već na create ('stripe' za > 0 €); staro: default 'onchain'
      'payment_rail', 'stripe',
      'external_payment_ref', null, 'buyer_email', null, 'holders', '[]'::jsonb, 'verified', false));
  perform pg_temp.isto_n('create e001: d001 claimed 0 → 2 (rezervacija odmah)', pg_temp.claimed(pg_temp.id('d001')), 2);
  perform pg_temp.isto_n('create e001: 0 ulaznica dok je pending', pg_temp.broj_ulaznica(pg_temp.id('e001')), 0);
  perform pg_temp.isto_n('create e001: audit contribution.created ×1', pg_temp.audit(pg_temp.id('e001'), 'contribution.created'), 1);
  perform pg_temp.isto_j('create e001: payload contribution.created',
    pg_temp.audit_payload(pg_temp.id('e001'), 'contribution.created'),
    jsonb_build_object('amount_cents', 4000, 'tier_id', pg_temp.id('d001'), 'quantity', 2));

  -- idempotencija: isti id (i s DRUGIM parametrima!) vraća postojeću, ništa ne rezervira
  r := pg_temp.rpc('0003', pg_temp.q_create(pg_temp.id('e001'), pg_temp.id('c001'), pg_temp.id('d001'), 3));
  perform pg_temp.isto_j('create e001 ponovno (qty 3): existing=true, isti podaci', r,
    ocek || '{"existing": true}');
  perform pg_temp.isto_n('create e001 ponovno: claimed ostaje 2', pg_temp.claimed(pg_temp.id('d001')), 2);
  -- isti id kao drugi korisnik također vraća postojeću (bearer capability)
  r := pg_temp.rpc('0004', pg_temp.q_create(pg_temp.id('e001'), pg_temp.id('c005'), pg_temp.id('d009'), 1));
  perform pg_temp.isto_j('create e001 kao drugi korisnik/drugi event: vraća e001 (existing)', r,
    ocek || '{"existing": true}');
end $$;

-- greške ulaza i poslovna pravila (exception → P0001 s porukom)
select pg_temp.pada('0003', pg_temp.q_create(pg_temp.id('e002'), pg_temp.id('c001'), pg_temp.id('d001'), 4),
  'P0001', 'tier_sold_out', 'create: prekoračenje kapaciteta (2 + 4 > 5)');
select pg_temp.pada('0003', pg_temp.q_create(pg_temp.id('e002'), pg_temp.id('c001'), pg_temp.id('d001'), 0),
  'P0001', 'invalid_quantity', 'create: quantity 0');
select pg_temp.pada('0003', pg_temp.q_create(pg_temp.id('e002'), pg_temp.id('c001'), pg_temp.id('d001'), 11),
  'P0001', 'invalid_quantity', 'create: quantity 11');
select pg_temp.pada('0003', pg_temp.q_create(pg_temp.id('e002'), pg_temp.id('c001'), pg_temp.id('d001'), null),
  'P0001', 'invalid_quantity', 'create: quantity null');
select pg_temp.pada('0003', pg_temp.q_create(null, pg_temp.id('c001'), pg_temp.id('d001'), 1),
  'P0001', 'order_id_required', 'create: order_id null');
select pg_temp.pada('anon', pg_temp.q_create(pg_temp.id('e002'), pg_temp.id('c001'), pg_temp.id('d001'), 1),
  '42501', 'permission denied for function create_ticket_order', 'create: anon nema EXECUTE');
select pg_temp.pada('0003', pg_temp.q_create(pg_temp.id('e002'), pg_temp.id('cfff'), pg_temp.id('d001'), 1),
  'P0001', 'campaign_not_found', 'create: nepostojeći event');
-- RAZLIKA (odluka 301): nema campaign_not_tickets — donacija c0d0 ne postoji u ulaznice.events
select pg_temp.pada('0003', pg_temp.q_create(pg_temp.id('e002'), pg_temp.id('c0d0'), pg_temp.id('d001'), 1),
  'P0001', 'campaign_not_found', 'create: donacija (nije u ulaznice) → campaign_not_found');
select pg_temp.pada('0003', pg_temp.q_create(pg_temp.id('e002'), pg_temp.id('c002'), pg_temp.id('d00a'), 1),
  'P0001', 'campaign_not_active', 'create: event je skica');
select pg_temp.pada('0003', pg_temp.q_create(pg_temp.id('e002'), pg_temp.id('c004'), pg_temp.id('d00b'), 1),
  'P0001', 'campaign_not_active', 'create: event je closed (staro: funded)');
select pg_temp.pada('0003', pg_temp.q_create(pg_temp.id('e002'), pg_temp.id('c001'), pg_temp.id('d009'), 1),
  'P0001', 'tier_not_found', 'create: tier drugog eventa');
-- RAZLIKA (odluka 301): nema tier_not_ticket — ticket_tiers nema kind, d007 je običan tier i create
-- prolazi (zaseban id e0d7, da e002 ostane neupisan; kupcu 0003 broji se umjesto donacije f0d0)
do $$
declare r jsonb;
begin
  r := pg_temp.rpc('0003', pg_temp.q_create(pg_temp.id('e0d7'), pg_temp.id('c001'), pg_temp.id('d007'), 1));
  perform pg_temp.isto_t('create: tier d007 (staro kind=reward) → pending', r->>'state', 'pending');
end $$;
-- RAZLIKA (odluka 300): p_payer_address ≠ null → onchain_rail_removed (staro: onchain narudžba)
select pg_temp.pada('0003', pg_temp.q_create_payer(pg_temp.id('e002'), pg_temp.id('c001'), pg_temp.id('d001'), 1,
                                                   '0x00000000000000000000000000000000000012c1'),
  'P0001', 'onchain_rail_removed', 'create: p_payer_address zadan → onchain_rail_removed');
select pg_temp.pada('0003', pg_temp.q_create(pg_temp.id('e002'), pg_temp.id('c001'), pg_temp.id('d005'), 1),
  'P0001', 'sale_not_started', 'create: prodaja još nije počela');
select pg_temp.pada('0003', pg_temp.q_create(pg_temp.id('e002'), pg_temp.id('c001'), pg_temp.id('d006'), 1),
  'P0001', 'sale_ended', 'create: prodaja završila');
select pg_temp.pada('0003', pg_temp.q_create(pg_temp.id('e002'), pg_temp.id('c001'), pg_temp.id('d004'), 2,
                                             '[{"full_name":"Ana Anić"}]'),
  'P0001', 'holders_incomplete', 'create: imenska, manje imena nego komada');
select pg_temp.pada('0003', pg_temp.q_create(pg_temp.id('e002'), pg_temp.id('c001'), pg_temp.id('d004'), 1,
                                             '[{"full_name":"   "}]'),
  'P0001', 'holders_incomplete', 'create: imenska, prazno ime');
select pg_temp.pada('0003', pg_temp.q_create(pg_temp.id('e002'), pg_temp.id('c001'), pg_temp.id('d004'), 1,
                                             jsonb_build_array(jsonb_build_object('full_name', repeat('a', 121)))),
  'P0001', 'invalid_holder', 'create: imenska, ime > 120 znakova');

do $$
declare r jsonb;
begin
  perform pg_temp.ok(pg_temp.stanje(pg_temp.id('e002')) is null, 'create: odbijene narudžbe nisu upisane (e002 ne postoji)');
  perform pg_temp.isto_n('create: nakon odbijenih d001 claimed i dalje 2', pg_temp.claimed(pg_temp.id('d001')), 2);

  -- imenska: imena se trimaju, prazan e-mail → null, višak holdera se odbacuje
  r := pg_temp.rpc('0003', pg_temp.q_create(pg_temp.id('e003'), pg_temp.id('c001'), pg_temp.id('d004'), 2,
         '[{"full_name":"  Ana Anić ","email":" ana@example.com "},{"full_name":"Ivo Ivić","email":"  "},{"full_name":"Višak"}]'));
  perform pg_temp.isto_j('create e003 imenska (2 × 30 €): odgovor', r,
    jsonb_build_object('order_id', pg_temp.id('e003'), 'state', 'pending', 'amount_cents', 6000, 'currency', 'eur',
                       'expires_at', now() + interval '20 minutes', 'existing', false) || pg_temp.a_create_extra());
  perform pg_temp.isto_j('create e003: holders normalizirani', pg_temp.narudzba(pg_temp.id('e003'))->'holders',
    '[{"full_name":"Ana Anić","email":"ana@example.com"},{"full_name":"Ivo Ivić","email":null}]');
  perform pg_temp.isto_n('create e003: neograničeni tier d004 ipak broji claimed = 2', pg_temp.claimed(pg_temp.id('d004')), 2);

  -- service_role (bez auth.uid) = narudžba gosta bez kupca
  r := pg_temp.rpc('service', pg_temp.q_create(pg_temp.id('e004'), pg_temp.id('c001'), pg_temp.id('d001'), 1));
  perform pg_temp.isto_j('create e004 kao service_role (gost): odgovor', r,
    jsonb_build_object('order_id', pg_temp.id('e004'), 'state', 'pending', 'amount_cents', 2000, 'currency', 'eur',
                       'expires_at', now() + interval '20 minutes', 'existing', false) || pg_temp.a_create_extra());
  perform pg_temp.ok(pg_temp.narudzba(pg_temp.id('e004'))->'buyer' = 'null'::jsonb, 'create e004: gost nema kupca (buyer null)');
  perform pg_temp.isto_n('create e004: d001 claimed 2 → 3', pg_temp.claimed(pg_temp.id('d001')), 3);

  -- rate limit: max 10 narudžbi / h po kupcu
  for i in 1..10 loop
    r := pg_temp.rpc('0006', pg_temp.q_create(pg_temp.id('e1' || lpad(to_hex(i), 2, '0')), pg_temp.id('c001'),
                                              pg_temp.id('d008'), 1));
  end loop;
  perform pg_temp.isto_n('rate limit: 10 narudžbi kupca 0006 prošlo, d008 claimed = 10', pg_temp.claimed(pg_temp.id('d008')), 10);
end $$;

select pg_temp.pada('0006', pg_temp.q_create(pg_temp.id('e1ff'), pg_temp.id('c001'), pg_temp.id('d008'), 1),
  'P0001', 'order_rate_limited', 'rate limit: 11. narudžba u sat vremena');
do $$
declare r jsonb;
begin
  r := pg_temp.rpc('0006', pg_temp.q_create(pg_temp.id('e101'), pg_temp.id('c001'), pg_temp.id('d008'), 1));
  perform pg_temp.isto_t('rate limit: retry postojećeg id-a i dalje prolazi (existing)', r->>'existing', 'true');
end $$;

\echo '--- 2. TTL / istek rezervacije'
select pg_temp.pada('0003', pg_temp.q_expire(), '42501',
  'permission denied for function expire_stale_ticket_orders', 'expire: authenticated nema EXECUTE');
select pg_temp.pada('anon', pg_temp.q_expire(), '42501',
  'permission denied for function expire_stale_ticket_orders', 'expire: anon nema EXECUTE');
do $$
declare r jsonb;
begin
  r := pg_temp.rpc('service', pg_temp.q_expire());
  perform pg_temp.isto_j('expire: bez isteklih → 0', r, '0');

  r := pg_temp.rpc('0003', pg_temp.q_create(pg_temp.id('e005'), pg_temp.id('c001'), pg_temp.id('d001'), 1));
  perform pg_temp.isto_n('create e005: d001 claimed 3 → 4', pg_temp.claimed(pg_temp.id('d001')), 4);
  perform pg_temp.istekni(pg_temp.id('e005'));
  r := pg_temp.rpc('service', pg_temp.q_expire());
  perform pg_temp.isto_j('expire: istekla 1 narudžba → vraća 1', r, '1');
  perform pg_temp.isto_t('expire: e005 pending → expired', pg_temp.stanje(pg_temp.id('e005')), 'expired');
  perform pg_temp.isto_n('expire: d001 claimed 4 → 3 (inventar vraćen)', pg_temp.claimed(pg_temp.id('d001')), 3);
  perform pg_temp.ok((pg_temp.narudzba(pg_temp.id('e005'))->>'reserved')::boolean, 'expire: reserved ostaje true');
  perform pg_temp.isto_n('expire: audit contribution.expired ×1', pg_temp.audit(pg_temp.id('e005'), 'contribution.expired'), 1);
  perform pg_temp.isto_j('expire: payload contribution.expired',
    pg_temp.audit_payload(pg_temp.id('e005'), 'contribution.expired'),
    '{"from":"pending","amount_received_cents":null}');  -- RAZLIKA (odluka 304): payload bez tx_hash
  r := pg_temp.rpc('service', pg_temp.q_expire());
  perform pg_temp.isto_j('expire: drugi poziv → 0 (idempotentno)', r, '0');
  perform pg_temp.isto_n('expire: drugi poziv ne dira claimed', pg_temp.claimed(pg_temp.id('d001')), 3);
  perform pg_temp.isto_t('expire: e001 (TTL u budućnosti) ostaje pending', pg_temp.stanje(pg_temp.id('e001')), 'pending');

  r := pg_temp.rpc('0003', pg_temp.q_create(pg_temp.id('e005'), pg_temp.id('c001'), pg_temp.id('d001'), 1));
  perform pg_temp.isto_j('create e005 ponovno: vraća istekle (state expired, existing)',
    r - 'expires_at',
    jsonb_build_object('order_id', pg_temp.id('e005'), 'state', 'expired', 'amount_cents', 2000, 'currency', 'eur',
                       'existing', true) || pg_temp.a_create_extra());

  -- lijeni istek: create_ticket_order najprije poziva expire_stale_ticket_orders
  r := pg_temp.rpc('0003', pg_temp.q_create(pg_temp.id('e006'), pg_temp.id('c001'), pg_temp.id('d001'), 1));
  perform pg_temp.isto_n('create e006: d001 claimed 3 → 4', pg_temp.claimed(pg_temp.id('d001')), 4);
  perform pg_temp.istekni(pg_temp.id('e006'));
  r := pg_temp.rpc('0003', pg_temp.q_create(pg_temp.id('e007'), pg_temp.id('c001'), pg_temp.id('d002'), 1));
  perform pg_temp.isto_t('lijeni istek: create e007 istekne e006', pg_temp.stanje(pg_temp.id('e006')), 'expired');
  perform pg_temp.isto_n('lijeni istek: d001 claimed 4 → 3', pg_temp.claimed(pg_temp.id('d001')), 3);
end $$;

\echo '--- 3. potvrda offchain (Stripe, service_role)'
select pg_temp.pada('0003', pg_temp.q_confirm(pg_temp.id('e001'), 'stripe', 'pi_test_e001', 4000), '42501',
  'permission denied for function confirm_ticket_order_offchain', 'confirm: authenticated nema EXECUTE');
select pg_temp.pada('anon', pg_temp.q_confirm(pg_temp.id('e001'), 'stripe', 'pi_test_e001', 4000), '42501',
  'permission denied for function confirm_ticket_order_offchain', 'confirm: anon nema EXECUTE');
select pg_temp.pada('service', pg_temp.q_confirm(null, 'stripe', 'pi_test_e001', 4000),
  'P0001', 'order_id_required', 'confirm: order_id null');
select pg_temp.pada('service', pg_temp.q_confirm(pg_temp.id('e001'), 'onchain', 'pi_test_e001', 4000),
  'P0001', 'invalid_rail', 'confirm: rail onchain');
select pg_temp.pada('service', pg_temp.q_confirm(pg_temp.id('e001'), null, 'pi_test_e001', 4000),
  'P0001', 'invalid_rail', 'confirm: rail null');
select pg_temp.pada('service', pg_temp.q_confirm(pg_temp.id('e001'), 'STRIPE', 'pi_test_e001', 4000),
  'P0001', 'invalid_rail', 'confirm: rail velikim slovima');
select pg_temp.pada('service', pg_temp.q_confirm(pg_temp.id('e001'), 'stripe', 'pi_1', 4000),
  'P0001', 'invalid_external_ref', 'confirm: ref kraći od 6');
select pg_temp.pada('service', pg_temp.q_confirm(pg_temp.id('e001'), 'stripe', 'pi test e001', 4000),
  'P0001', 'invalid_external_ref', 'confirm: ref s razmakom');
select pg_temp.pada('service', pg_temp.q_confirm(pg_temp.id('e001'), 'stripe', null, 4000),
  'P0001', 'invalid_external_ref', 'confirm: ref null');
select pg_temp.pada('service', pg_temp.q_confirm(pg_temp.id('e001'), 'stripe', 'pi_test_e001', 4000, repeat('a', 201)),
  'P0001', 'invalid_payer_email', 'confirm: e-mail > 200 znakova');
select pg_temp.pada('service', pg_temp.q_confirm(pg_temp.id('efff'), 'stripe', 'pi_test_efff', 4000),
  'P0001', 'order_not_found', 'confirm: nepostojeća narudžba');
-- RAZLIKA (odluka 301): donacija f0d0 ne postoji u ulaznice.orders → order_not_found (staro: not_a_ticket_order)
select pg_temp.pada('service', pg_temp.q_confirm(pg_temp.id('f0d0'), 'stripe', 'pi_test_f0d0', 500),
  'P0001', 'order_not_found', 'confirm: donacija (nije u ulaznice) → order_not_found');

do $$
declare r jsonb; u jsonb; e jsonb;
begin
  r := pg_temp.rpc('service', pg_temp.q_confirm(pg_temp.id('e001'), 'stripe', 'pi_test_e001', 4000, '  Kupac@Example.com '));
  perform pg_temp.isto_j('confirm e001 stripe: odgovor paid + serijali', r,
    jsonb_build_object('status', 'paid', 'order_id', pg_temp.id('e001'), 'serials', '["TES-000001","TES-000002"]'::jsonb));
  perform pg_temp.isto_j('confirm e001: stanje narudžbe',
    pg_temp.narudzba(pg_temp.id('e001')) - 'reserve_expires_at' - 'holders' - 'event_id' - 'tier_id' - 'buyer',
    jsonb_build_object('state', 'paid', 'amount_cents', 4000, 'amount_received_cents', 4000, 'quantity', 2,
      'reserved', true, 'payment_rail', 'stripe', 'external_payment_ref', 'pi_test_e001',
      'buyer_email', 'Kupac@Example.com', 'paid_at', now(), 'verified', false));
  perform pg_temp.isto_n('confirm e001: d001 claimed ostaje 3 (rezervacija već ubrojena)', pg_temp.claimed(pg_temp.id('d001')), 3);
  perform pg_temp.isto_n('confirm e001: izdano 2 ulaznice (= quantity)', pg_temp.broj_ulaznica(pg_temp.id('e001')), 2);
  u := pg_temp.ulaznice_narudzbe(pg_temp.id('e001'));
  for e in select * from jsonb_array_elements(u) loop
    perform pg_temp.ok(e->>'state' = 'issued' and (e->>'tier_id')::uuid = pg_temp.id('d001')
                       and (e->>'event_id')::uuid = pg_temp.id('c001')
                       and e->'holder_name' = 'null'::jsonb and e->'holder_email' = 'null'::jsonb
                       and e->>'qr_token_once' ~ '^[0-9a-f]{64}$'
                       and e->>'qr_token_hash' = encode(extensions.digest(e->>'qr_token_once', 'sha256'), 'hex'),
      'confirm e001: ulaznica ' || (e->>'serial') || ' issued, token 64-hex, hash = sha256(token)', e::text);
  end loop;
  perform pg_temp.isto_n('confirm e001: audit contribution.paid ×1', pg_temp.audit(pg_temp.id('e001'), 'contribution.paid'), 1);
  perform pg_temp.isto_j('confirm e001: payload tickets.issued',
    pg_temp.audit_payload(pg_temp.id('e001'), 'tickets.issued'),
    '{"count":2,"serials":["TES-000001","TES-000002"],"rail":"stripe","external_ref":"pi_test_e001"}');
  -- RAZLIKA (odluka 306): staro campaign_stats {"total":4000,"count":1,"contributors":1}
  perform pg_temp.ok(pg_temp.nema_statistike(), 'confirm e001: campaign_stats ne postoji u ulaznice');

  -- idempotencija: ista uplata = no-op
  r := pg_temp.rpc('service', pg_temp.q_confirm(pg_temp.id('e001'), 'stripe', 'pi_test_e001', 4000));
  perform pg_temp.isto_j('confirm e001 ponovno (isti ref): already_paid + isti serijali', r,
    jsonb_build_object('status', 'already_paid', 'order_id', pg_temp.id('e001'), 'serials', '["TES-000001","TES-000002"]'::jsonb));
  perform pg_temp.isto_n('confirm e001 ponovno: i dalje 2 ulaznice', pg_temp.broj_ulaznica(pg_temp.id('e001')), 2);
  perform pg_temp.isto_n('confirm e001 ponovno: tickets.issued i dalje ×1', pg_temp.audit(pg_temp.id('e001'), 'tickets.issued'), 1);

  -- druga uplata (drugi ref) na plaćenu narudžbu → trag za refund
  r := pg_temp.rpc('service', pg_temp.q_confirm(pg_temp.id('e001'), 'stripe', 'pi_test_e001_dupli', 4000));
  perform pg_temp.isto_j('confirm e001 drugim ref-om: duplicate_payment', r,
    jsonb_build_object('status', 'duplicate_payment', 'order_id', pg_temp.id('e001'), 'credited_ref', 'pi_test_e001'));
  perform pg_temp.isto_j('confirm e001 drugim ref-om: audit ticket_order.duplicate_payment',
    pg_temp.audit_payload(pg_temp.id('e001'), 'ticket_order.duplicate_payment'),
    '{"rail":"stripe","external_ref":"pi_test_e001_dupli","credited_rail":"stripe","credited_ref":"pi_test_e001","amount_cents":4000}');
  perform pg_temp.isto_t('confirm e001 drugim ref-om: ref narudžbe nepromijenjen',
    pg_temp.narudzba(pg_temp.id('e001'))->>'external_payment_ref', 'pi_test_e001');
  perform pg_temp.isto_n('confirm e001 drugim ref-om: i dalje 2 ulaznice', pg_temp.broj_ulaznica(pg_temp.id('e001')), 2);

  -- isti (rail, ref) na drugu narudžbu
  r := pg_temp.rpc('service', pg_temp.q_confirm(pg_temp.id('e004'), 'stripe', 'pi_test_e001', 2000));
  perform pg_temp.isto_j('confirm e004 ref-om od e001: tx_already_credited', r,
    jsonb_build_object('status', 'tx_already_credited', 'order_id', pg_temp.id('e004')));
  perform pg_temp.isto_j('confirm e004 ref-om od e001: audit ticket_order.match_conflict',
    pg_temp.audit_payload(pg_temp.id('e004'), 'ticket_order.match_conflict'),
    jsonb_build_object('rail', 'stripe', 'external_ref', 'pi_test_e001', 'other_contribution_id', pg_temp.id('e001')));  -- ISTO: ključ other_contribution_id ostaje (odluka 3)
  perform pg_temp.isto_t('confirm e004 ref-om od e001: e004 ostaje pending', pg_temp.stanje(pg_temp.id('e004')), 'pending');

  -- premalo uplaćeno
  r := pg_temp.rpc('service', pg_temp.q_confirm(pg_temp.id('e004'), 'stripe', 'pi_test_e004', 1999));
  perform pg_temp.isto_j('confirm e004 s 19,99 €: amount_insufficient', r,
    jsonb_build_object('status', 'amount_insufficient', 'order_id', pg_temp.id('e004'),
                       'expected_cents', 2000, 'received_cents', 1999));
  perform pg_temp.isto_j('confirm e004 s 19,99 €: audit ticket_order.underpaid',
    pg_temp.audit_payload(pg_temp.id('e004'), 'ticket_order.underpaid'),
    '{"rail":"stripe","external_ref":"pi_test_e004","expected_cents":2000,"received_cents":1999}');
  r := pg_temp.rpc('service', pg_temp.q_confirm(pg_temp.id('e004'), 'stripe', 'pi_test_e004', null));
  perform pg_temp.isto_j('confirm e004 bez iznosa: amount_insufficient, received null', r,
    jsonb_build_object('status', 'amount_insufficient', 'order_id', pg_temp.id('e004'),
                       'expected_cents', 2000, 'received_cents', null));
  perform pg_temp.isto_t('confirm e004 premalo: ostaje pending, bez ulaznica',
    pg_temp.stanje(pg_temp.id('e004')) || '/' || pg_temp.broj_ulaznica(pg_temp.id('e004')), 'pending/0');

  -- preplata se prihvaća (≥), bilježi se primljeni iznos
  r := pg_temp.rpc('service', pg_temp.q_confirm(pg_temp.id('e004'), 'stripe', 'pi_test_e004', 2500));
  perform pg_temp.isto_j('confirm e004 s 25 € (preplata): paid', r,
    jsonb_build_object('status', 'paid', 'order_id', pg_temp.id('e004'), 'serials', '["TES-000003"]'::jsonb));
  perform pg_temp.isto_n('confirm e004: amount_received_cents = 2500', (pg_temp.narudzba(pg_temp.id('e004'))->>'amount_received_cents')::bigint, 2500);
  perform pg_temp.ok(pg_temp.narudzba(pg_temp.id('e004'))->'buyer_email' = 'null'::jsonb, 'confirm e004 bez e-maila: buyer_email null');

  -- imenska: holderi se prepisuju na ulaznice po redu
  r := pg_temp.rpc('service', pg_temp.q_confirm(pg_temp.id('e003'), 'stripe', 'pi_test_e003', 6000));
  perform pg_temp.isto_j('confirm e003 imenska: paid', r,
    jsonb_build_object('status', 'paid', 'order_id', pg_temp.id('e003'), 'serials', '["TES-000004","TES-000005"]'::jsonb));
  u := pg_temp.ulaznice_narudzbe(pg_temp.id('e003'));
  perform pg_temp.isto_j('confirm e003: holder_name/holder_email na ulaznicama',
    jsonb_build_array(jsonb_build_object('n', u->0->'holder_name', 'e', u->0->'holder_email'),
                      jsonb_build_object('n', u->1->'holder_name', 'e', u->1->'holder_email')),
    '[{"n":"Ana Anić","e":"ana@example.com"},{"n":"Ivo Ivić","e":null}]');
  perform pg_temp.isto_n('confirm e003: d004 claimed ostaje 2', pg_temp.claimed(pg_temp.id('d004')), 2);

  -- istekla narudžba, uplata stvarno stigla → ponovna rezervacija
  perform pg_temp.isto_n('confirm istekle e005: prije d001 claimed = 3', pg_temp.claimed(pg_temp.id('d001')), 3);
  r := pg_temp.rpc('service', pg_temp.q_confirm(pg_temp.id('e005'), 'stripe', 'pi_test_e005', 2000));
  perform pg_temp.isto_j('confirm istekle e005: paid', r,
    jsonb_build_object('status', 'paid', 'order_id', pg_temp.id('e005'), 'serials', '["TES-000006"]'::jsonb));
  perform pg_temp.isto_t('confirm istekle e005: expired → paid', pg_temp.stanje(pg_temp.id('e005')), 'paid');
  -- RAZLIKA (odluka 303): claimed raste točno za quantity (3 → 4). Staro (BUG ORIGINALA): 3 → 5,
  -- confirm korak 5 re-rezervira +1, a tg_contribution_state na expired→paid doda još +1.
  perform pg_temp.isto_n('confirm istekle e005: d001 claimed 3 → 4 (jednom)', pg_temp.claimed(pg_temp.id('d001')), 4);
  perform pg_temp.isto_n('confirm istekle e005: 1 ulaznica', pg_temp.broj_ulaznica(pg_temp.id('e005')), 1);
  perform pg_temp.isto_n('confirm istekle e005: audit contribution.paid ×1', pg_temp.audit(pg_temp.id('e005'), 'contribution.paid'), 1);

  -- istekla narudžba, a tier se u međuvremenu rasprodao
  r := pg_temp.rpc('0003', pg_temp.q_create(pg_temp.id('e009'), pg_temp.id('c001'), pg_temp.id('d003'), 1));
  perform pg_temp.isto_n('create e009 (tier inv 1): d003 claimed = 1', pg_temp.claimed(pg_temp.id('d003')), 1);
  perform pg_temp.istekni(pg_temp.id('e009'));
  r := pg_temp.rpc('service', pg_temp.q_expire());
  perform pg_temp.isto_n('expire e009: d003 claimed = 0', pg_temp.claimed(pg_temp.id('d003')), 0);
  r := pg_temp.rpc('0004', pg_temp.q_create(pg_temp.id('e00a'), pg_temp.id('c001'), pg_temp.id('d003'), 1));
  perform pg_temp.isto_n('create e00a (drugi kupac uzme zadnje mjesto): d003 claimed = 1', pg_temp.claimed(pg_temp.id('d003')), 1);
  r := pg_temp.rpc('service', pg_temp.q_confirm(pg_temp.id('e009'), 'stripe', 'pi_test_e009', 1500));
  perform pg_temp.isto_j('confirm istekle e009 bez mjesta: expired_sold_out', r,
    jsonb_build_object('status', 'expired_sold_out', 'order_id', pg_temp.id('e009')));
  perform pg_temp.isto_t('confirm e009: ostaje expired, 0 ulaznica, claimed 1',
    pg_temp.stanje(pg_temp.id('e009')) || '/' || pg_temp.broj_ulaznica(pg_temp.id('e009')) || '/' || pg_temp.claimed(pg_temp.id('d003')),
    'expired/0/1');
  perform pg_temp.isto_j('confirm e009: audit ticket_order.expired_sold_out',
    pg_temp.audit_payload(pg_temp.id('e009'), 'ticket_order.expired_sold_out'),
    '{"rail":"stripe","external_ref":"pi_test_e009"}');
  perform pg_temp.ok(pg_temp.narudzba(pg_temp.id('e009'))->'external_payment_ref' = 'null'::jsonb,
    'confirm e009: ref se ne upisuje (Worker radi refund)');

  -- RAZLIKA (odluka 306): staro campaign_stats {"total":14000,"count":4,"contributors":2}
  perform pg_temp.ok(pg_temp.nema_statistike(), 'confirm: campaign_stats ne postoji u ulaznice (nakon e001+e004+e003+e005)');
end $$;

\echo '--- 4. besplatna narudžba (0 €, rail free)'
do $$
declare r jsonb;
begin
  -- e007 je napravljen u scenariju 2 (d002, 0 €)
  perform pg_temp.isto_j('free e007: nakon create pending, 0 €, rezervirano, NIJE automatski potvrđeno',
    pg_temp.narudzba(pg_temp.id('e007')) - 'event_id' - 'tier_id' - 'buyer' - 'reserve_expires_at' - 'holders' - 'paid_at',
    '{"state":"pending","amount_cents":0,"amount_received_cents":null,"quantity":1,"reserved":true,
      "payment_rail":"free","external_payment_ref":null,"buyer_email":null,"verified":false}');  -- RAZLIKA (odluka 301): rail 'free' već na create (staro 'onchain')
  perform pg_temp.isto_n('free e007: d002 claimed = 1', pg_temp.claimed(pg_temp.id('d002')), 1);
end $$;
select pg_temp.pada('service', pg_temp.q_confirm(pg_temp.id('e007'), 'free', 'free_e007', 1),
  'P0001', 'order_not_free', 'free: rail free s iznosom 1');
select pg_temp.pada('service', pg_temp.q_confirm(pg_temp.id('e007'), 'free', 'free_e007', null),
  'P0001', 'order_not_free', 'free: rail free bez iznosa');
select pg_temp.pada('service', pg_temp.q_confirm(pg_temp.id('e00a'), 'free', 'free_e00a', 0),
  'P0001', 'order_not_free', 'free: rail free na plaćenoj narudžbi (15 €)');
select pg_temp.pada('service', pg_temp.q_confirm(pg_temp.id('e007'), 'free', 'free', 0),
  'P0001', 'invalid_external_ref', 'free: i rail free traži ref ≥ 6 znakova');
do $$
declare r jsonb;
begin
  r := pg_temp.rpc('service', pg_temp.q_confirm(pg_temp.id('e007'), 'free', 'free_e007', 0, 'gost@example.com'));
  perform pg_temp.isto_j('free e007 confirm: paid', r,
    jsonb_build_object('status', 'paid', 'order_id', pg_temp.id('e007'), 'serials', '["TES-000007"]'::jsonb));
  perform pg_temp.isto_t('free e007: rail free, ref, primljeno 0',
    concat_ws('/', pg_temp.narudzba(pg_temp.id('e007'))->>'state', pg_temp.narudzba(pg_temp.id('e007'))->>'payment_rail',
              pg_temp.narudzba(pg_temp.id('e007'))->>'external_payment_ref',
              pg_temp.narudzba(pg_temp.id('e007'))->>'amount_received_cents'),
    'paid/free/free_e007/0');
  perform pg_temp.isto_n('free e007: claimed d002 ostaje 1', pg_temp.claimed(pg_temp.id('d002')), 1);
  perform pg_temp.isto_j('free e007: payload tickets.issued (rail free)',
    pg_temp.audit_payload(pg_temp.id('e007'), 'tickets.issued'),
    '{"count":1,"serials":["TES-000007"],"rail":"free","external_ref":"free_e007"}');
  r := pg_temp.rpc('service', pg_temp.q_confirm(pg_temp.id('e007'), 'free', 'free_e007', 0));
  perform pg_temp.isto_j('free e007 ponovno: already_paid', r,
    jsonb_build_object('status', 'already_paid', 'order_id', pg_temp.id('e007'), 'serials', '["TES-000007"]'::jsonb));

  -- ČUDNO U ORIGINALU: besplatnu narudžbu može potvrditi i rail 'stripe' s iznosom 0.
  r := pg_temp.rpc('0003', pg_temp.q_create(pg_temp.id('e00b'), pg_temp.id('c001'), pg_temp.id('d002'), 2));
  perform pg_temp.isto_j('free e00b (2 × 0 €): odgovor', r,
    jsonb_build_object('order_id', pg_temp.id('e00b'), 'state', 'pending', 'amount_cents', 0, 'currency', 'eur',
                       'expires_at', now() + interval '20 minutes', 'existing', false) || pg_temp.a_create_extra());
  -- RAZLIKA (odluka 302): rail 'stripe' na 0 € → invalid_rail (staro: paid). Da ostatak scenarija
  -- ostane isti (serijali TES-000008/9, claimed), e00b se potvrđuje railom 'free'.
  perform pg_temp.pada('service', pg_temp.q_confirm(pg_temp.id('e00b'), 'stripe', 'pi_test_e00b', 0),
    'P0001', 'invalid_rail', 'free e00b preko rail stripe s 0 € → invalid_rail');
  r := pg_temp.rpc('service', pg_temp.q_confirm(pg_temp.id('e00b'), 'free', 'free_e00b', 0));
  perform pg_temp.isto_j('free e00b preko rail free: paid', r,
    jsonb_build_object('status', 'paid', 'order_id', pg_temp.id('e00b'), 'serials', '["TES-000008","TES-000009"]'::jsonb));
  perform pg_temp.isto_n('free e00b: d002 claimed = 3', pg_temp.claimed(pg_temp.id('d002')), 3);
end $$;

\echo '--- 5. deliver_ticket_orders (oblik JSON-a, jednokratni QR token)'
select pg_temp.pada('0003', pg_temp.q_deliver(array[pg_temp.id('e001')]), '42501',
  'permission denied for function deliver_ticket_orders', 'deliver: authenticated nema EXECUTE');
select pg_temp.pada('anon', pg_temp.q_deliver(array[pg_temp.id('e001')]), '42501',
  'permission denied for function deliver_ticket_orders', 'deliver: anon nema EXECUTE');
select pg_temp.pada('service', pg_temp.q_deliver(array(select gen_random_uuid() from generate_series(1, 51))),
  'P0001', 'too_many_orders', 'deliver: 51 narudžba');
do $$
declare r jsonb; o jsonb; t jsonb; k jsonb;
begin
  perform pg_temp.isto_j('deliver null → []', pg_temp.rpc('service', pg_temp.q_deliver(null)), '[]');
  perform pg_temp.isto_j('deliver {} → []', pg_temp.rpc('service', pg_temp.q_deliver('{}')), '[]');
  perform pg_temp.isto_j('deliver nepostojeće → []', pg_temp.rpc('service', pg_temp.q_deliver(array[pg_temp.id('efff')])), '[]');

  -- f0d0 (donacija u staro.sql) ovdje ne postoji: ishod isti (filtrira se)
  r := pg_temp.rpc('service', pg_temp.q_deliver(array[pg_temp.id('e001'), pg_temp.id('e003'), pg_temp.id('e00a'),
                                                     pg_temp.id('f0d0'), pg_temp.id('efff')]));
  perform pg_temp.isto_n('deliver [e001,e003,e00a,donacija,nepostojeća]: 3 narudžbe', jsonb_array_length(r), 3);
  k := '["amount_cents","currency","expires_at","order_id","quantity","state","tickets"]'::jsonb;
  select coalesce(jsonb_agg(x order by x), '[]') into k
    from jsonb_array_elements_text(k || pg_temp.a_deliver_extra_kljucevi()) x;
  for o in select * from jsonb_array_elements(r) loop
    perform pg_temp.isto_j('deliver: ključevi narudžbe ' || (o->>'order_id'), pg_temp.kljucevi(o), k);
  end loop;
  o := pg_temp.po_narudzbi(r, pg_temp.id('e001'));
  -- RAZLIKA (odluka 300): tx_hash je uvijek null (staro: forward_tx_hash, za stripe također null)
  perform pg_temp.ok(o->'tx_hash' = 'null'::jsonb, 'deliver e001: tx_hash null');
  perform pg_temp.isto_j('deliver e001: polja narudžbe', o - 'tickets' - 'tx_hash',
    jsonb_build_object('order_id', pg_temp.id('e001'), 'state', 'paid', 'quantity', 2, 'amount_cents', 4000,
                       'currency', 'eur', 'expires_at', now() + interval '20 minutes'));
  perform pg_temp.isto_n('deliver e001: 2 ulaznice', jsonb_array_length(o->'tickets'), 2);
  for t in select * from jsonb_array_elements(o->'tickets') loop
    perform pg_temp.isto_j('deliver e001: ključevi ulaznice ' || (t->>'serial'), pg_temp.kljucevi(t),
      '["checked_in_at","holder_email","holder_name","id","qr_token","serial","state"]');
  end loop;
  perform pg_temp.isto_j('deliver e001: ulaznice sortirane po serialu, issued',
    jsonb_build_array(o->'tickets'->0->'serial', o->'tickets'->0->'state', o->'tickets'->0->'checked_in_at',
                      o->'tickets'->1->'serial', o->'tickets'->1->'state'),
    '["TES-000001","issued",null,"TES-000002","issued"]');
  insert into tokeni (serial, ticket_id, token)
  select t2->>'serial', (t2->>'id')::uuid, t2->>'qr_token'
    from jsonb_array_elements((o->'tickets') || (pg_temp.po_narudzbi(r, pg_temp.id('e003'))->'tickets')) t2;
  perform pg_temp.ok((select bool_and(token ~ '^[0-9a-f]{64}$') and count(*) = 4 from tokeni),
    'deliver prvi put: qr_token 64-hex za 4 ulaznice (e001, e003)', (select jsonb_agg(to_jsonb(x))::text from tokeni x));
  perform pg_temp.ok((select bool_and(pg_temp.ulaznica(serial)->>'id' = ticket_id::text) from tokeni),
    'deliver: id ulaznice odgovara bazi');
  o := pg_temp.po_narudzbi(r, pg_temp.id('e003'));
  perform pg_temp.isto_j('deliver e003: holderi u odgovoru',
    jsonb_build_array(o->'tickets'->0->'holder_name', o->'tickets'->0->'holder_email',
                      o->'tickets'->1->'holder_name', o->'tickets'->1->'holder_email'),
    '["Ana Anić","ana@example.com","Ivo Ivić",null]');
  o := pg_temp.po_narudzbi(r, pg_temp.id('e00a'));
  perform pg_temp.isto_j('deliver e00a (pending): state pending, tickets []',
    jsonb_build_array(o->'state', o->'tickets', o->'amount_cents'), '["pending",[],1500]');

  -- jednokratnost
  perform pg_temp.ok((select bool_and(e->'qr_token_once' = 'null'::jsonb)
                        from jsonb_array_elements(pg_temp.ulaznice_narudzbe(pg_temp.id('e001'))
                                                  || pg_temp.ulaznice_narudzbe(pg_temp.id('e003'))) e),
    'deliver: qr_token_once obrisan u bazi nakon dostave');
  r := pg_temp.rpc('service', pg_temp.q_deliver(array[pg_temp.id('e001')]));
  perform pg_temp.isto_j('deliver e001 drugi put: qr_token null',
    jsonb_build_array(r->0->'tickets'->0->'qr_token', r->0->'tickets'->1->'qr_token'), '[null,null]');

  -- lijeni istek i kroz deliver
  r := pg_temp.rpc('0003', pg_temp.q_create(pg_temp.id('e00c'), pg_temp.id('c001'), pg_temp.id('d008'), 1));
  perform pg_temp.isto_n('create e00c: d008 claimed 10 → 11', pg_temp.claimed(pg_temp.id('d008')), 11);
  perform pg_temp.istekni(pg_temp.id('e00c'));
  r := pg_temp.rpc('service', pg_temp.q_deliver(array[pg_temp.id('e00c')]));
  perform pg_temp.isto_t('deliver e00c (TTL prošao): lijeni istek, state expired', r->0->>'state', 'expired');
  perform pg_temp.isto_n('deliver e00c: d008 claimed 11 → 10', pg_temp.claimed(pg_temp.id('d008')), 10);
end $$;

\echo '--- 6. list_my_tickets'
select pg_temp.pada('anon', pg_temp.q_list_my(), '42501',
  'permission denied for function list_my_tickets', 'list_my_tickets: anon nema EXECUTE');
do $$
declare r jsonb;
begin
  r := pg_temp.rpc('0003', pg_temp.q_list_my());
  -- K1 (0003): e001 (2), e003 (2), e005 (1), e007 (1), e00b (2) = 8; e004 je gost
  perform pg_temp.isto_j('list_my_tickets kupac K1: serijali (bez gostujuće e004)',
    (select jsonb_agg(x->'serial' order by x->>'serial') from jsonb_array_elements(r) x),
    '["TES-000001","TES-000002","TES-000004","TES-000005","TES-000006","TES-000007","TES-000008","TES-000009"]');
  perform pg_temp.isto_j('list_my_tickets: ključevi retka (bez QR tokena)', pg_temp.kljucevi(r->0), pg_temp.a_list_kljucevi());
  perform pg_temp.isto_j('list_my_tickets: redak TES-000004',
    (select x - 'ticket_id' - 'created_at' from jsonb_array_elements(r) x where x->>'serial' = 'TES-000004'),
    jsonb_build_object('contribution_id', pg_temp.id('e003'), 'campaign_id', pg_temp.id('c001'),   -- ISTO (odluka 305): nazivi ključeva
                       'campaign_title', 'Test RPC: aktivan', 'serial', 'TES-000004', 'holder_name', 'Ana Anić',
                       'state', 'issued', 'checked_in_at', null));
  perform pg_temp.isto_j('list_my_tickets drugi korisnik (0004, ima samo pending e00a): []',
    pg_temp.rpc('0004', pg_temp.q_list_my()), '[]');
  perform pg_temp.isto_j('list_my_tickets organizator (0001): ne vidi kupčeve ulaznice',
    pg_temp.rpc('0001', pg_temp.q_list_my()), '[]');
  perform pg_temp.isto_j('list_my_tickets service_role (bez auth.uid): []',
    pg_temp.rpc('service', pg_temp.q_list_my()), '[]');
end $$;

\echo '--- 7. redeem_ticket / void_ticket'
select pg_temp.pada('anon', pg_temp.q_redeem((select token from tokeni where serial = 'TES-000001')), '42501',
  'permission denied for function redeem_ticket', 'redeem: anon nema EXECUTE');
select pg_temp.pada('service', pg_temp.q_redeem((select token from tokeni where serial = 'TES-000001')),
  'P0001', 'not_authenticated', 'redeem: service_role bez auth.uid');
select pg_temp.pada('0002', pg_temp.q_redeem('abc'), 'P0001', 'invalid_token', 'redeem: token nije 64-hex');
select pg_temp.pada('0002', pg_temp.q_redeem(upper((select token from tokeni where serial = 'TES-000001'))),
  'P0001', 'invalid_token', 'redeem: token velikim slovima');
select pg_temp.pada('0002', pg_temp.q_redeem(null), 'P0001', 'invalid_token', 'redeem: token null');
select pg_temp.pada('0003', pg_temp.q_redeem((select token from tokeni where serial = 'TES-000001')),
  'P0001', 'not_authorized', 'redeem: kupac (vlasnik ulaznice) nije organizator');
select pg_temp.pada('0004', pg_temp.q_redeem((select token from tokeni where serial = 'TES-000001')),
  'P0001', 'not_authorized', 'redeem: admin DRUGOG organizatora');
select pg_temp.pada('0005', pg_temp.q_redeem((select token from tokeni where serial = 'TES-000001')),
  'P0001', 'not_authorized', 'redeem: običan član org računa (nije admin)');
do $$
declare r jsonb; t1 text;
begin
  t1 := (select token from tokeni where serial = 'TES-000001');
  perform pg_temp.isto_t('redeem: neuspjeli pokušaji ne mijenjaju ulaznicu', pg_temp.ulaznica('TES-000001')->>'state', 'issued');
  perform pg_temp.isto_j('redeem: nepostojeći token (ispravan format) → not_found',
    pg_temp.rpc('0002', pg_temp.q_redeem(repeat('0', 64))), '{"status":"not_found"}');

  r := pg_temp.rpc('0002', pg_temp.q_redeem(t1));
  perform pg_temp.isto_j('redeem TES-000001 (admin org A): checked_in', r,
    jsonb_build_object('status', 'checked_in', 'serial', 'TES-000001', 'holder_name', null, 'tier_title', 'Redovna',
                       'event_title', 'Test RPC: aktivan', 'checked_in_at', now(), 'checked_in_count', 1));
  perform pg_temp.isto_j('redeem TES-000001: stanje ulaznice', pg_temp.ulaznica('TES-000001') - 'id',
    jsonb_build_object('state', 'checked_in', 'checked_in_at', now(), 'checked_in_by', pg_temp.id('0002')));
  perform pg_temp.isto_j('redeem TES-000001: audit ticket.checked_in',
    pg_temp.audit_payload(pg_temp.id('e001'), 'ticket.checked_in'),
    jsonb_build_object('serial', 'TES-000001', 'by', pg_temp.id('0002')));

  r := pg_temp.rpc('0001', pg_temp.q_redeem(t1));
  perform pg_temp.isto_j('redeem TES-000001 drugi put (vlasnik org A): already_checked_in s podacima PRVOG ulaska', r,
    jsonb_build_object('status', 'already_checked_in', 'serial', 'TES-000001', 'holder_name', null,
                       'tier_title', 'Redovna', 'event_title', 'Test RPC: aktivan', 'checked_in_at', now(),
                       'checked_in_by_email', 'test-ulaznice-rpc-0002@example.com', 'checked_in_count', 1));
  perform pg_temp.isto_t('redeem drugi put: checked_in_by ostaje prvi skener',
    pg_temp.ulaznica('TES-000001')->>'checked_in_by', pg_temp.id('0002')::text);
  perform pg_temp.isto_j('redeem drugi put: audit ticket.checkin_duplicate',
    pg_temp.audit_payload(pg_temp.id('e001'), 'ticket.checkin_duplicate'),
    jsonb_build_object('serial', 'TES-000001', 'first_checked_in_at', now(), 'attempted_by', pg_temp.id('0001')));
end $$;

select pg_temp.pada('anon', pg_temp.q_void(pg_temp.id('e001')), '42501',
  'permission denied for function void_ticket', 'void: anon nema EXECUTE');
select pg_temp.pada('service', pg_temp.q_void((select ticket_id from tokeni where serial = 'TES-000002')),
  'P0001', 'not_authenticated', 'void: service_role bez auth.uid');
select pg_temp.pada('0001', pg_temp.q_void(null), 'P0001', 'ticket_id_required', 'void: ticket_id null');
select pg_temp.pada('0003', pg_temp.q_void((select ticket_id from tokeni where serial = 'TES-000002')),
  'P0001', 'not_authorized', 'void: kupac nije organizator');
select pg_temp.pada('0004', pg_temp.q_void((select ticket_id from tokeni where serial = 'TES-000002')),
  'P0001', 'not_authorized', 'void: admin drugog organizatora');
do $$
declare r jsonb; t2 text; id2 uuid;
begin
  select token, ticket_id into t2, id2 from tokeni where serial = 'TES-000002';
  perform pg_temp.isto_j('void: nepostojeća ulaznica → not_found',
    pg_temp.rpc('0001', pg_temp.q_void(pg_temp.id('bfff'))), '{"status":"not_found"}');
  r := pg_temp.rpc('0001', pg_temp.q_void(id2));
  perform pg_temp.isto_j('void TES-000002 (vlasnik org A): voided', r, '{"status":"voided","serial":"TES-000002"}');
  perform pg_temp.isto_t('void TES-000002: state void', pg_temp.ulaznica('TES-000002')->>'state', 'void');
  perform pg_temp.isto_j('void TES-000002: audit ticket.voided', pg_temp.audit_payload(pg_temp.id('e001'), 'ticket.voided'),
    jsonb_build_object('serial', 'TES-000002', 'by', pg_temp.id('0001')));
  -- BUG ORIGINALA (ili namjera): void_ticket NE vraća mjesto u inventar — ISTO (odluka 306).
  -- RAZLIKA (odluka 303): vrijednost 4 umjesto 5 jer e005 (expired→paid) više ne broji dvaput.
  perform pg_temp.isto_n('void: d001 claimed ostaje 4 (void ne oslobađa inventar)', pg_temp.claimed(pg_temp.id('d001')), 4);
  perform pg_temp.isto_j('void TES-000002 ponovno: already_void',
    pg_temp.rpc('0002', pg_temp.q_void(id2)), '{"status":"already_void","serial":"TES-000002"}');
  perform pg_temp.isto_j('redeem poništene TES-000002: void, bez ulaska',
    pg_temp.rpc('0002', pg_temp.q_redeem(t2)), '{"status":"void","serial":"TES-000002","event_title":"Test RPC: aktivan"}');
  perform pg_temp.isto_t('redeem poništene: ulaznica ostaje void', pg_temp.ulaznica('TES-000002')->>'state', 'void');
  perform pg_temp.isto_j('void iskorištene TES-000001: already_checked_in',
    pg_temp.rpc('0001', pg_temp.q_void((select ticket_id from tokeni where serial = 'TES-000001'))),
    jsonb_build_object('status', 'already_checked_in', 'serial', 'TES-000001', 'checked_in_at', now()));
  perform pg_temp.isto_t('void iskorištene: ostaje checked_in', pg_temp.ulaznica('TES-000001')->>'state', 'checked_in');
end $$;

\echo '--- 8. refund_ticket_order'
select pg_temp.pada('0003', pg_temp.q_refund(pg_temp.id('e003')), '42501',
  'permission denied for function refund_ticket_order', 'refund: authenticated nema EXECUTE');
select pg_temp.pada('anon', pg_temp.q_refund(pg_temp.id('e003')), '42501',
  'permission denied for function refund_ticket_order', 'refund: anon nema EXECUTE');
select pg_temp.pada('service', pg_temp.q_refund(null), 'P0001', 'order_id_required', 'refund: order_id null');
select pg_temp.pada('service', pg_temp.q_refund(pg_temp.id('e003'), null, repeat('r', 61)),
  'P0001', 'invalid_reason', 'refund: razlog > 60 znakova');
do $$
declare r jsonb;
begin
  perform pg_temp.isto_j('refund nepostojeće: not_found', pg_temp.rpc('service', pg_temp.q_refund(pg_temp.id('efff'))),
    jsonb_build_object('status', 'not_found', 'order_id', pg_temp.id('efff')));
  -- RAZLIKA (odluka 301): donacija f0d0 ne postoji u ulaznice.orders → not_found (staro: not_a_ticket_order)
  perform pg_temp.isto_j('refund donacije (nije u ulaznice): not_found', pg_temp.rpc('service', pg_temp.q_refund(pg_temp.id('f0d0'))),
    jsonb_build_object('status', 'not_found', 'order_id', pg_temp.id('f0d0')));
  r := pg_temp.rpc('service', pg_temp.q_refund(pg_temp.id('e00a'), null, 'organizator', 're_test_e00a'));
  perform pg_temp.isto_j('refund pending e00a: not_paid', r,
    jsonb_build_object('status', 'not_paid', 'order_id', pg_temp.id('e00a'), 'state', 'pending'));
  perform pg_temp.isto_j('refund pending e00a: audit ticket_order.refund_unexpected',
    pg_temp.audit_payload(pg_temp.id('e00a'), 'ticket_order.refund_unexpected'),
    '{"state":"pending","reason":"organizator","external_ref":"re_test_e00a"}');
  perform pg_temp.isto_t('refund pending e00a: ostaje pending', pg_temp.stanje(pg_temp.id('e00a')), 'pending');

  -- e003 (2 ulaznice): jedna iskorištena, druga issued
  r := pg_temp.rpc('0002', pg_temp.q_redeem((select token from tokeni where serial = 'TES-000004')));
  perform pg_temp.isto_t('refund priprema: TES-000004 checked_in', r->>'status', 'checked_in');
  perform pg_temp.isto_n('refund priprema: checked_in_count na eventu = 2', (r->>'checked_in_count')::bigint, 2);
  perform pg_temp.isto_n('refund priprema: d004 claimed = 2', pg_temp.claimed(pg_temp.id('d004')), 2);

  r := pg_temp.rpc('service', pg_temp.q_refund(pg_temp.id('e003'), 3000, 'organizator', 're_test_e003'));
  perform pg_temp.isto_j('refund e003: refunded, 1 poništena, 1 iskorištena zadržana', r,
    jsonb_build_object('status', 'refunded', 'order_id', pg_temp.id('e003'), 'voided', 1, 'kept_checked_in', 1));
  perform pg_temp.isto_t('refund e003: paid → refunded', pg_temp.stanje(pg_temp.id('e003')), 'refunded');
  perform pg_temp.isto_t('refund e003: ulaznice void + checked_in',
    pg_temp.broj_ulaznica(pg_temp.id('e003'), 'void') || '/' || pg_temp.broj_ulaznica(pg_temp.id('e003'), 'checked_in')
      || '/' || pg_temp.broj_ulaznica(pg_temp.id('e003'), 'issued'), '1/1/0');
  perform pg_temp.isto_t('refund e003: TES-000005 void, TES-000004 checked_in',
    (pg_temp.ulaznica('TES-000005')->>'state') || '/' || (pg_temp.ulaznica('TES-000004')->>'state'), 'void/checked_in');
  perform pg_temp.isto_n('refund e003: d004 claimed 2 → 1 (samo poništene)', pg_temp.claimed(pg_temp.id('d004')), 1);
  perform pg_temp.isto_j('refund e003: audit ticket_order.refunded (djelomični iznos samo se bilježi)',
    pg_temp.audit_payload(pg_temp.id('e003'), 'ticket_order.refunded'),
    '{"reason":"organizator","external_ref":"re_test_e003","amount_cents":3000,"voided":1,"kept_checked_in":1,"rail":"stripe"}');
  perform pg_temp.isto_n('refund e003: audit contribution.refunded ×1', pg_temp.audit(pg_temp.id('e003'), 'contribution.refunded'), 1);
  -- RAZLIKA (odluka 306): refund ne piše campaign_stats; staro {"total":8000,"count":5,"contributors":1}
  perform pg_temp.ok(pg_temp.nema_statistike(), 'refund e003: campaign_stats ne postoji u ulaznice');

  r := pg_temp.rpc('service', pg_temp.q_refund(pg_temp.id('e003')));
  perform pg_temp.isto_j('refund e003 ponovno: already_refunded', r,
    jsonb_build_object('status', 'already_refunded', 'order_id', pg_temp.id('e003'), 'voided', 1, 'kept_checked_in', 1));
  perform pg_temp.isto_n('refund e003 ponovno: bez novog audita', pg_temp.audit(pg_temp.id('e003'), 'ticket_order.refunded'), 1);
  perform pg_temp.isto_n('refund e003 ponovno: claimed ostaje 1', pg_temp.claimed(pg_temp.id('d004')), 1);
  perform pg_temp.isto_j('redeem poništene refundom TES-000005: void',
    pg_temp.rpc('0002', pg_temp.q_redeem((select token from tokeni where serial = 'TES-000005'))),
    '{"status":"void","serial":"TES-000005","event_title":"Test RPC: aktivan"}');

  -- e001: TES-000001 iskorištena, TES-000002 već poništena void_ticketom
  r := pg_temp.rpc('service', pg_temp.q_refund(pg_temp.id('e001'), null, 'dispute'));
  perform pg_temp.isto_j('refund e001 (1 checked_in, 1 već void): voided 0', r,
    jsonb_build_object('status', 'refunded', 'order_id', pg_temp.id('e001'), 'voided', 0, 'kept_checked_in', 1));
  -- BUG ORIGINALA: mjesto ulaznice poništene void_ticketom ne vraća se nikad (ni void ni refund) — ISTO (odluka 306).
  -- RAZLIKA (odluka 303): 4 umjesto 5 (v. e005 u scenariju 3).
  perform pg_temp.isto_n('refund e001: d001 claimed ostaje 4 (v. BUG)', pg_temp.claimed(pg_temp.id('d001')), 4);
  perform pg_temp.isto_j('refund e001: payload (amount_cents = puni iznos kad je p_amount null)',
    pg_temp.audit_payload(pg_temp.id('e001'), 'ticket_order.refunded'),
    '{"reason":"dispute","external_ref":null,"amount_cents":4000,"voided":0,"kept_checked_in":1,"rail":"stripe"}');
  -- ČUDNO U ORIGINALU: retry vraća voided = SVE void ulaznice (1), a prvi odgovor je rekao 0.
  perform pg_temp.isto_j('refund e001 ponovno: already_refunded broji i ranije void (voided 1 ≠ 0)',
    pg_temp.rpc('service', pg_temp.q_refund(pg_temp.id('e001'))),
    jsonb_build_object('status', 'already_refunded', 'order_id', pg_temp.id('e001'), 'voided', 1, 'kept_checked_in', 1));
  -- RAZLIKA (odluka 306): staro campaign_stats {"total":4000,"count":4,"contributors":1}
  perform pg_temp.ok(pg_temp.nema_statistike(), 'refund e001: campaign_stats ne postoji u ulaznice');
  perform pg_temp.isto_t('refund: event ostaje active (ticket eventi nemaju goal → nikad funded)',
    pg_temp.stanje_eventa(pg_temp.id('c001')), 'active');
end $$;
-- potvrda refundirane narudžbe (i istim ref-om) se odbija exceptionom
select pg_temp.pada('service', pg_temp.q_confirm(pg_temp.id('e003'), 'stripe', 'pi_test_e003', 6000),
  'P0001', 'order_not_payable', 'confirm refundirane e003 istim ref-om');
select pg_temp.pada('service', pg_temp.q_confirm(pg_temp.id('e003'), 'stripe', 'pi_test_e003_novi', 6000),
  'P0001', 'order_not_payable', 'confirm refundirane e003 novim ref-om');

\echo '--- 9. rotate_ticket_tokens (port iz e77f9ae:supabase/tests/20260903_rail_gate_i_rotacija.sql, dio 5–8)'
-- U pinka_finance funkcija nikad nije primijenjena (odluka 111), pa nema starog
-- ponašanja za usporedbu: provjere su one iz testa u e77f9ae, s narudžbom
-- napravljenom kroz RPC-e (e00d, kupac 0004, 2 × 5 €) umjesto ručnog inserta.
select pg_temp.pada('anon', pg_temp.q_rotate(pg_temp.id('e001')), '42501',
  'permission denied for function rotate_ticket_tokens', 'rotate: anon nema EXECUTE');
select pg_temp.pada('0003', pg_temp.q_rotate(pg_temp.id('e001')), '42501',
  'permission denied for function rotate_ticket_tokens', 'rotate: authenticated nema EXECUTE');
do $$
declare r jsonb; v_stari jsonb; v_novi jsonb; t jsonb; v_tok text;
begin
  r := pg_temp.rpc('0004', pg_temp.q_create(pg_temp.id('e00d'), pg_temp.id('c001'), pg_temp.id('d008'), 2));
  r := pg_temp.rpc('service', pg_temp.q_confirm(pg_temp.id('e00d'), 'stripe', 'pi_test_rotacija', 1000, 'kupac@example.com'));
  perform pg_temp.isto_t('rotate priprema: e00d paid', r->>'status', 'paid');
  r := pg_temp.rpc('service', pg_temp.q_deliver(array[pg_temp.id('e00d')]));
  insert into tokeni (serial, ticket_id, token)
  select x->>'serial', (x->>'id')::uuid, x->>'qr_token' from jsonb_array_elements(r->0->'tickets') x;
  v_stari := (select jsonb_agg(e->'qr_token_hash' order by e->>'serial')
                from jsonb_array_elements(pg_temp.ulaznice_narudzbe(pg_temp.id('e00d'))) e);

  -- 5. novi token, stari hash prestaje vrijediti
  r := pg_temp.rpc('service', pg_temp.q_rotate(pg_temp.id('e00d')));
  perform pg_temp.isto_j('rotate e00d: status/state/rotated',
    jsonb_build_array(r->'status', r->'order_id', r->'state', r->'rotated'),
    jsonb_build_array('rotated', pg_temp.id('e00d'), 'paid', 2));
  perform pg_temp.isto_n('rotate e00d: 2 ulaznice u odgovoru', jsonb_array_length(r->'tickets'), 2);
  for t in select * from jsonb_array_elements(r->'tickets') loop
    perform pg_temp.isto_j('rotate e00d: ključevi ulaznice ' || (t->>'serial'), pg_temp.kljucevi(t),
      '["holder_email","holder_name","qr_token","serial","state"]');
    perform pg_temp.ok(t->>'qr_token' ~ '^[0-9a-f]{64}$'
                       and encode(extensions.digest(t->>'qr_token', 'sha256'), 'hex')
                           = (select e->>'qr_token_hash' from jsonb_array_elements(pg_temp.ulaznice_narudzbe(pg_temp.id('e00d'))) e
                               where e->>'serial' = t->>'serial'),
      'rotate e00d: novi token ' || (t->>'serial') || ' 64-hex, hash u bazi = sha256(token)', t::text);
  end loop;
  v_novi := (select jsonb_agg(e->'qr_token_hash' order by e->>'serial')
               from jsonb_array_elements(pg_temp.ulaznice_narudzbe(pg_temp.id('e00d'))) e);
  perform pg_temp.ok(not exists (select 1 from jsonb_array_elements(v_stari) a, jsonb_array_elements(v_novi) b where a = b),
    'rotate e00d: svi hashevi promijenjeni (stari QR mrtav)');
  perform pg_temp.ok((select bool_and(e->'qr_token_once' = 'null'::jsonb)
                        from jsonb_array_elements(pg_temp.ulaznice_narudzbe(pg_temp.id('e00d'))) e),
    'rotate e00d: plaintext obrisan iz baze');
  perform pg_temp.isto_j('rotate e00d: audit ticket.token_rotated',
    pg_temp.audit_payload(pg_temp.id('e00d'), 'ticket.token_rotated'), '{"rotated":2,"rotations_24h":1}');
  v_tok := (select token from tokeni where serial = r->'tickets'->0->>'serial');
  perform pg_temp.isto_j('rotate e00d: stari token → redeem not_found',
    pg_temp.rpc('0002', pg_temp.q_redeem(v_tok)), '{"status":"not_found"}');
  perform pg_temp.isto_t('rotate e00d: novi token → redeem checked_in',
    pg_temp.rpc('0002', pg_temp.q_redeem(r->'tickets'->0->>'qr_token'))->>'status', 'checked_in');
end $$;

-- 6. iskorištena ulaznica se NE rotira (sve iskorištene → nothing_to_rotate)
update ulaznice.tickets set state = 'checked_in', checked_in_at = now()
 where order_id = pg_temp.id('e00d');
do $$
begin
  perform pg_temp.isto_j('rotate e00d sve checked_in: nothing_to_rotate',
    pg_temp.rpc('service', pg_temp.q_rotate(pg_temp.id('e00d'))), '{"status":"nothing_to_rotate"}');
end $$;

-- 7. tvrdi limit 5/24 h (1 rotacija gore + 4 = 5; šesta odbijena)
update ulaznice.tickets set state = 'issued', checked_in_at = null, checked_in_by = null
 where order_id = pg_temp.id('e00d');
do $$
declare r jsonb;
begin
  for i in 2..5 loop
    r := pg_temp.rpc('service', pg_temp.q_rotate(pg_temp.id('e00d')));
    perform pg_temp.isto_t('rotate e00d rotacija ' || i || '/5: rotated', r->>'status', 'rotated');
  end loop;
  perform pg_temp.isto_j('rotate e00d šesta u 24 h: rate_limited',
    pg_temp.rpc('service', pg_temp.q_rotate(pg_temp.id('e00d'))), '{"status":"rate_limited","rotations_24h":5}');
  perform pg_temp.isto_n('rotate e00d: audit ticket.token_rotated ×5', pg_temp.audit(pg_temp.id('e00d'), 'ticket.token_rotated'), 5);
end $$;

-- 8. neplaćena / nepostojeća narudžba se ne rotira
do $$
begin
  perform pg_temp.isto_j('rotate pending e00a: order_not_paid',
    pg_temp.rpc('service', pg_temp.q_rotate(pg_temp.id('e00a'))), '{"status":"order_not_paid","state":"pending"}');
  perform pg_temp.isto_j('rotate refundirane e003: order_not_paid',
    pg_temp.rpc('service', pg_temp.q_rotate(pg_temp.id('e003'))), '{"status":"order_not_paid","state":"refunded"}');
  perform pg_temp.isto_j('rotate nepostojeće: order_not_found',
    pg_temp.rpc('service', pg_temp.q_rotate(pg_temp.id('efff'))), '{"status":"order_not_found"}');
  perform pg_temp.isto_j('rotate null: order_not_found',
    pg_temp.rpc('service', pg_temp.q_rotate(null)), '{"status":"order_not_found"}');
end $$;

do $$ begin
  raise notice 'SVE PROVJERE PROŠLE (% provjera)', current_setting('test.provjere');
end $$;

rollback;
