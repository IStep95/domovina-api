-- „Prvo test na starom ponašanju”: fiksira ponašanje TRENUTNIH RPC-a narudžbi i
-- ulaznica u shemi pinka_finance, tako da se isti scenarij kasnije pusti nad
-- shemom ulaznice (lanac docs/ulaznice-shema/).
--
-- RPC-i (zadnje definicije):
--   create_ticket_order, confirm_ticket_order_offchain  20261125120000_events_free_online.sql
--   expire_stale_ticket_orders, deliver_ticket_orders,
--   list_my_tickets                                     20260716120200_events_ticketing_rpcs.sql
--   refund_ticket_order                                 20260803130000_events_stripe_refund.sql
--   redeem_ticket, void_ticket                          20260717120000_events_checkin.sql
--   tg_contribution_state (inventar, audit)             20260722120000_pinka_slots.sql:841
-- Onchain grane (confirm_ticket_order, p_payer_address) se NE testiraju — ukidaju se.
--
-- Pokretanje nad lokalnim stackom (sve u jednoj transakciji s ROLLBACK-om, u
-- bazi ne ostaje ništa; NE treba db reset):
--   psql postgresql://postgres:postgres@127.0.0.1:55322/postgres -v ON_ERROR_STOP=1 \
--        -f supabase/tests/20261125_ulaznice_rpc_narudzbe_staro.sql
--
-- Očekivano: NOTICE redci "OK — …" i na kraju NOTICE "SVE PROVJERE PROŠLE (N provjera)".
-- Svaki drugi ishod je pad (ON_ERROR_STOP; prekinuta transakcija se odbacuje).
--
-- STRUKTURA (radi porta na ulaznice):
--   A. generički pomoćnici (bez naziva tablica)       — port: ne dira se
--   B. ADAPTER: pozivi RPC-a + čitanje stanja          — port: prepisati SAMO ovo
--   C. fixture: korisnici, računi, event, tierovi      — port: prepisati (MAPIRANJE)
--   D. scenariji 1–8: asertacije                       — port: doslovno, osim redaka
--      označenih „-- PORT:” (poznate razlike) i „-- BUG ORIGINALA:”.
--
-- MAPIRANJE pinka_finance → ulaznice (vrijedi za cijelu datoteku):
--   campaigns + events → ulaznice.events | campaign_tiers → ticket_tiers
--   contributions → orders | contribution_events → order_events | tickets → tickets
--   campaign_id → event_id | contribution_id → order_id
--   contributor_account_id → buyer_account_id | stanje kampanje `funded` → `closed`
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
-- B. ADAPTER — jedino mjesto s nazivima shema/tablica/RPC-a (port: prepisati)
-- ════════════════════════════════════════════════════════════════════════════

-- ── pozivi RPC-a (vraćaju SQL koji daje jedan jsonb) ──
-- PORT: p_campaign_id → p_event_id; p_payer_address ne postoji (onchain se ukida).
create function pg_temp.q_create(p_order uuid, p_event uuid, p_tier uuid, p_qty integer,
                                 p_holders jsonb default '[]'::jsonb) returns text language sql as $$
  select format('select pinka_finance.create_ticket_order(%L::uuid, %L::uuid, %L::uuid, %L::integer, %L::jsonb)',
                p_order, p_event, p_tier, p_qty, p_holders)
$$;
create function pg_temp.q_confirm(p_order uuid, p_rail text, p_ref text, p_amount bigint,
                                  p_email text default null) returns text language sql as $$
  select format('select pinka_finance.confirm_ticket_order_offchain(%L::uuid, %L::text, %L::text, %L::bigint, %L::text)',
                p_order, p_rail, p_ref, p_amount, p_email)
$$;
create function pg_temp.q_expire() returns text language sql as $$
  select 'select to_jsonb(pinka_finance.expire_stale_ticket_orders())'
$$;
create function pg_temp.q_deliver(p_orders uuid[]) returns text language sql as $$
  select format('select pinka_finance.deliver_ticket_orders(%L::uuid[])', p_orders)
$$;
-- list_my_tickets vraća TABLE → jsonb niz redaka, sortiran po serialu.
create function pg_temp.q_list_my() returns text language sql as $$
  select 'select coalesce(jsonb_agg(to_jsonb(x) order by x.serial), ''[]''::jsonb) from pinka_finance.list_my_tickets() x'
$$;
create function pg_temp.q_redeem(p_token text) returns text language sql as $$
  select format('select pinka_finance.redeem_ticket(%L::text)', p_token)
$$;
create function pg_temp.q_void(p_ticket uuid) returns text language sql as $$
  select format('select pinka_finance.void_ticket(%L::uuid)', p_ticket)
$$;
create function pg_temp.q_refund(p_order uuid, p_amount bigint default null, p_reason text default null,
                                 p_ref text default null) returns text language sql as $$
  select format('select pinka_finance.refund_ticket_order(%L::uuid, %L::bigint, %L::text, %L::text)',
                p_order, p_amount, p_reason, p_ref)
$$;

-- ── poznate razlike oblika odgovora (port: vratiti '{}' / prilagoditi) ──
-- PORT: create_ticket_order vraća destination_address kampanje; ulaznice.events ga nema.
create function pg_temp.a_create_extra() returns jsonb language sql as $$
  select jsonb_build_object('destination_address', '0x00000000000000000000000000000000000012c1')
$$;
-- PORT: deliver_ticket_orders vraća tx_hash (= contributions.forward_tx_hash, onchain).
create function pg_temp.a_deliver_extra_kljucevi() returns jsonb language sql as $$
  select '["tx_hash"]'::jsonb
$$;
-- PORT: list_my_tickets vraća contribution_id/campaign_id/campaign_title (→ order_id/event_id/event_title?).
create function pg_temp.a_list_kljucevi() returns jsonb language sql as $$
  select '["campaign_id","campaign_title","checked_in_at","contribution_id","created_at","holder_name","serial","state","ticket_id"]'::jsonb
$$;

-- ── čitanje stanja ──
-- MAPIRANJE: contributions → orders; contributor_account_id → buyer_account_id;
--            campaign_id → event_id; contributor_verified (ostaje).
create function pg_temp.narudzba(p_order uuid) returns jsonb language sql as $$
  select jsonb_build_object(
    'state', c.state::text, 'event_id', c.campaign_id, 'tier_id', c.tier_id,
    'buyer', c.contributor_account_id, 'amount_cents', c.amount_cents,
    'amount_received_cents', c.amount_received_cents, 'quantity', c.quantity,
    'reserved', c.reserved, 'reserve_expires_at', c.reserve_expires_at,
    'payment_rail', c.payment_rail, 'external_payment_ref', c.external_payment_ref,
    'buyer_email', c.buyer_email, 'paid_at', c.paid_at, 'holders', c.holders,
    'verified', c.contributor_verified)
  from pinka_finance.contributions c where c.id = p_order
$$;
create function pg_temp.stanje(p_order uuid) returns text language sql as $$
  select state::text from pinka_finance.contributions where id = p_order   -- MAPIRANJE: contributions → orders
$$;
create function pg_temp.claimed(p_tier uuid) returns integer language sql as $$
  select inventory_claimed from pinka_finance.campaign_tiers where id = p_tier   -- MAPIRANJE: campaign_tiers → ticket_tiers
$$;
-- Simulacija isteka TTL-a: rezervacija istekla prije minutu.
create function pg_temp.istekni(p_order uuid) returns void language sql as $$
  update pinka_finance.contributions                                           -- MAPIRANJE: contributions → orders
     set reserve_expires_at = now() - interval '1 minute' where id = p_order
$$;
-- MAPIRANJE: tickets.contribution_id → tickets.order_id
create function pg_temp.broj_ulaznica(p_order uuid, p_state text default null) returns integer language sql as $$
  select count(*)::integer from pinka_finance.tickets
   where contribution_id = p_order and (p_state is null or state::text = p_state)
$$;
create function pg_temp.ulaznice_narudzbe(p_order uuid) returns jsonb language sql as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', t.id, 'serial', t.serial, 'state', t.state::text, 'tier_id', t.tier_id,
           'event_id', t.campaign_id, 'holder_name', t.holder_name, 'holder_email', t.holder_email,
           'qr_token_hash', t.qr_token_hash, 'qr_token_once', t.qr_token_once,
           'checked_in_at', t.checked_in_at, 'checked_in_by', t.checked_in_by) order by t.serial), '[]'::jsonb)
    from pinka_finance.tickets t where t.contribution_id = p_order
$$;
create function pg_temp.ulaznica(p_serial text) returns jsonb language sql as $$
  select jsonb_build_object('id', t.id, 'state', t.state::text, 'checked_in_at', t.checked_in_at,
                            'checked_in_by', t.checked_in_by)
    from pinka_finance.tickets t where t.serial = p_serial and t.campaign_id = pg_temp.id('c001')
$$;
-- MAPIRANJE: contribution_events → order_events; contribution_id → order_id.
-- PORT: nazivi event_type 'contribution.<state>' (trigger) mogu postati 'order.<state>'.
create function pg_temp.audit(p_order uuid, p_type text) returns integer language sql as $$
  select count(*)::integer from pinka_finance.contribution_events
   where contribution_id = p_order and event_type = p_type
$$;
create function pg_temp.audit_payload(p_order uuid, p_type text) returns jsonb language sql as $$
  select payload from pinka_finance.contribution_events
   where contribution_id = p_order and event_type = p_type order by created_at desc, id desc limit 1
$$;
-- PORT: ulaznice nema campaign_stats — provjere agregata otpadaju (vraćati null i preskočiti).
create function pg_temp.statistika(p_event uuid) returns jsonb language sql as $$
  select jsonb_build_object('total', total_raised_cents, 'count', contribution_count,
                            'contributors', contributor_count)
    from pinka_finance.campaign_stats where campaign_id = p_event
$$;
create function pg_temp.stanje_eventa(p_event uuid) returns text language sql as $$
  select state::text from pinka_finance.campaigns where id = p_event            -- MAPIRANJE: campaigns → ulaznice.events
$$;

-- ════════════════════════════════════════════════════════════════════════════
-- C. fixture
-- ════════════════════════════════════════════════════════════════════════════
-- Korisnici: 0001 vlasnik org A (KYC) | 0002 admin org A | 0003 kupac K1 |
--            0004 vlasnik org B (drugi korisnik/kupac) | 0005 običan član org A |
--            0006 kupac za rate limit.
-- Org računi: a001 (A), a002 (B).
-- Eventi (MAPIRANJE: campaigns + events → ulaznice.events):
--   c001 aktivan A | c002 skica A | c004 funded A (MAPIRANJE: funded → closed) |
--   c005 aktivan B | c0d0 DONACIJA A (u ulaznice ne postoji — PORT: provjere s njom otpadaju).
-- Tierovi c001 (MAPIRANJE: campaign_tiers → ticket_tiers; kind ne postoji u ulaznice):
--   d001 Redovna 20 € inv 5 | d002 Besplatna 0 € inv 100 | d003 Mala 15 € inv 1 |
--   d004 Imenska 30 € neograničena | d005 prodaja još nije počela | d006 prodaja završila |
--   d007 kind=reward (PORT: otpada) | d008 5 € neograničena (rate limit).
--   d009 tier eventa c005 | d00a tier skice c002 | d00b tier funded c004.
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

-- MAPIRANJE: campaigns → ulaznice.events (destination_address/chain/type/subject_type ne postoje)
insert into pinka_finance.campaigns (id, account_id, slug, type, title, subject_type, min_contribution_cents,
                                     currency, destination_address, chain, state, visibility)
select pg_temp.id(v.id), pg_temp.id(v.acc), v.slug, v.type::pinka_finance.campaign_type, v.title, v.st, 100,
       'eur', '0x00000000000000000000000000000000000012c1', 'gnosis',
       v.state::pinka_finance.campaign_state, 'public'
  from (values
    ('c001', 'a001', 'test-rpc-staro-aktivan', 'tickets',  'Test RPC: aktivan',   'event',           'active'),
    ('c002', 'a001', 'test-rpc-staro-skica',   'tickets',  'Test RPC: skica',     'event',           'draft'),
    ('c004', 'a001', 'test-rpc-staro-funded',  'tickets',  'Test RPC: funded',    'event',           'funded'),  -- MAPIRANJE: funded → closed
    ('c005', 'a002', 'test-rpc-staro-tudji',   'tickets',  'Test RPC: org B',     'event',           'active'),
    ('c0d0', 'a001', 'test-rpc-staro-donacija','donation', 'Test RPC: donacija',  'podcast_channel', 'active')
  ) v(id, acc, slug, type, title, st, state);

-- MAPIRANJE: events (campaign_id) → stupci u ulaznice.events
insert into pinka_finance.events (campaign_id, event_type, venue_name, venue_city, starts_at, ends_at, organizer_name)
select pg_temp.id(c), 'koncert', 'Testna dvorana', 'Zagreb', now() + interval '30 days',
       now() + interval '30 days 3 hours', 'Testni organizator'
  from unnest(array['c001','c002','c004','c005']) c;

-- MAPIRANJE: campaign_tiers → ticket_tiers; campaign_id → event_id; kind otpada
insert into pinka_finance.campaign_tiers (id, campaign_id, title, price_cents, inventory_total, sort, kind,
                                          imenska, sale_start, sale_end)
select pg_temp.id(v.id), pg_temp.id(v.c), v.title, v.price, v.inv, v.sort, v.kind::pinka_finance.tier_kind,
       v.imenska, v.ss, v.se
  from (values
    ('d001', 'c001', 'Redovna',    2000, 5,    0, 'ticket', false, null::timestamptz, null::timestamptz),
    ('d002', 'c001', 'Besplatna',     0, 100,  1, 'ticket', false, null, null),
    ('d003', 'c001', 'Mala',       1500, 1,    2, 'ticket', false, null, null),
    ('d004', 'c001', 'Imenska',    3000, null, 3, 'ticket', true,  null, null),
    ('d005', 'c001', 'Buduća',     1000, 10,   4, 'ticket', false, now() + interval '1 day', null),
    ('d006', 'c001', 'Prošla',     1000, 10,   5, 'ticket', false, null, now() - interval '1 day'),
    ('d007', 'c001', 'Nagrada',    1000, 10,   6, 'reward', false, null, null),
    ('d008', 'c001', 'Neograničena', 500, null, 7, 'ticket', false, null, null),
    ('d009', 'c005', 'Tier B',     1500, 10,   0, 'ticket', false, null, null),
    ('d00a', 'c002', 'Skica tier', 1000, 10,   0, 'ticket', false, null, null),
    ('d00b', 'c004', 'Funded tier',1000, 10,   0, 'ticket', false, null, null)
  ) v(id, c, title, price, inv, sort, kind, imenska, ss, se);

-- Donacija (nije narudžba ulaznica) — PORT: u ulaznice ne postoji, provjere s f0d0 otpadaju.
insert into pinka_finance.contributions (id, campaign_id, contributor_account_id, amount_cents, currency,
                                         quantity, state, destination_address, paid_at)
values (pg_temp.id('f0d0'), pg_temp.id('c0d0'), pg_temp.osobni('0003'), 500, 'eur', 1, 'paid',
        '0x00000000000000000000000000000000000012c1', now());

-- Normalizacija: istekle tuđe rezervacije u lokalnoj bazi (unutar ove transakcije)
-- oslobodi odmah, da kasnije brojanje expire_stale_ticket_orders bude točno.
select pinka_finance.expire_stale_ticket_orders() >= 0 as normalizirano;   -- MAPIRANJE: ulaznice.expire_stale_ticket_orders

-- ════════════════════════════════════════════════════════════════════════════
-- D. scenariji (asertacije; port doslovno osim „-- PORT:” redaka)
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
      'payment_rail', 'onchain',   -- PORT: pinka default rail je 'onchain'; ulaznice.orders nema default (constraint)
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
-- PORT: donacija ne postoji u ulaznice → provjera otpada
select pg_temp.pada('0003', pg_temp.q_create(pg_temp.id('e002'), pg_temp.id('c0d0'), pg_temp.id('d001'), 1),
  'P0001', 'campaign_not_tickets', 'create: kampanja nije tickets (donacija)');
select pg_temp.pada('0003', pg_temp.q_create(pg_temp.id('e002'), pg_temp.id('c002'), pg_temp.id('d00a'), 1),
  'P0001', 'campaign_not_active', 'create: event je skica');
select pg_temp.pada('0003', pg_temp.q_create(pg_temp.id('e002'), pg_temp.id('c004'), pg_temp.id('d00b'), 1),
  'P0001', 'campaign_not_active', 'create: event je funded (MAPIRANJE: closed)');
select pg_temp.pada('0003', pg_temp.q_create(pg_temp.id('e002'), pg_temp.id('c001'), pg_temp.id('d009'), 1),
  'P0001', 'tier_not_found', 'create: tier drugog eventa');
-- PORT: ticket_tiers nema kind → provjera otpada
select pg_temp.pada('0003', pg_temp.q_create(pg_temp.id('e002'), pg_temp.id('c001'), pg_temp.id('d007'), 1),
  'P0001', 'tier_not_ticket', 'create: tier kind=reward');
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
    '{"from":"pending","tx_hash":null,"amount_received_cents":null}');  -- PORT: tx_hash (onchain) vjerojatno otpada
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
-- PORT: donacija ne postoji u ulaznice → provjera otpada
select pg_temp.pada('service', pg_temp.q_confirm(pg_temp.id('f0d0'), 'stripe', 'pi_test_f0d0', 500),
  'P0001', 'not_a_ticket_order', 'confirm: donacija nije narudžba ulaznica');

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
  perform pg_temp.isto_j('confirm e001: campaign_stats', pg_temp.statistika(pg_temp.id('c001')),   -- PORT: otpada
    '{"total":4000,"count":1,"contributors":1}');

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
    jsonb_build_object('rail', 'stripe', 'external_ref', 'pi_test_e001', 'other_contribution_id', pg_temp.id('e001')));  -- PORT: ključ other_contribution_id → other_order_id?
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
  -- BUG ORIGINALA: confirm_ticket_order_offchain (korak 5) re-rezervira +1, a tg_contribution_state
  -- na expired→paid (reserved) doda još +1 → claimed 3 → 5 umjesto 4 (fantomsko mjesto).
  -- PORT: ako port to ispravi, očekivano je 4.
  perform pg_temp.isto_n('confirm istekle e005: d001 claimed 3 → 5 (dvostruki inkrement, v. BUG)', pg_temp.claimed(pg_temp.id('d001')), 5);
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

  perform pg_temp.isto_j('confirm: campaign_stats nakon e001+e004+e003+e005', pg_temp.statistika(pg_temp.id('c001')),  -- PORT: otpada
    '{"total":14000,"count":4,"contributors":2}');   -- re-sum amount_cents (ne received); gost broji kao zaseban kupac
end $$;

\echo '--- 4. besplatna narudžba (0 €, rail free)'
do $$
declare r jsonb;
begin
  -- e007 je napravljen u scenariju 2 (d002, 0 €)
  perform pg_temp.isto_j('free e007: nakon create pending, 0 €, rezervirano, NIJE automatski potvrđeno',
    pg_temp.narudzba(pg_temp.id('e007')) - 'event_id' - 'tier_id' - 'buyer' - 'reserve_expires_at' - 'holders' - 'paid_at',
    '{"state":"pending","amount_cents":0,"amount_received_cents":null,"quantity":1,"reserved":true,
      "payment_rail":"onchain","external_payment_ref":null,"buyer_email":null,"verified":false}');  -- PORT: rail 'onchain' → u ulaznice besplatna mora biti 'free' već na create (orders_amount_free)
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
  -- PORT: u ulaznice.orders constraint orders_amount_free (amount 0 ⇒ rail free) to zabranjuje.
  r := pg_temp.rpc('0003', pg_temp.q_create(pg_temp.id('e00b'), pg_temp.id('c001'), pg_temp.id('d002'), 2));
  perform pg_temp.isto_j('free e00b (2 × 0 €): odgovor', r,
    jsonb_build_object('order_id', pg_temp.id('e00b'), 'state', 'pending', 'amount_cents', 0, 'currency', 'eur',
                       'expires_at', now() + interval '20 minutes', 'existing', false) || pg_temp.a_create_extra());
  r := pg_temp.rpc('service', pg_temp.q_confirm(pg_temp.id('e00b'), 'stripe', 'pi_test_e00b', 0));
  perform pg_temp.isto_j('free e00b preko rail stripe s 0 €: paid (v. ČUDNO)', r,
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

  -- PORT: donacija f0d0 ne postoji u ulaznice (filtrira se jer nije narudžba ulaznica)
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
    jsonb_build_object('contribution_id', pg_temp.id('e003'), 'campaign_id', pg_temp.id('c001'),   -- PORT: nazivi ključeva
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
  -- BUG ORIGINALA (ili namjera): void_ticket NE vraća mjesto u inventar.
  perform pg_temp.isto_n('void: d001 claimed ostaje 5 (void ne oslobađa inventar)', pg_temp.claimed(pg_temp.id('d001')), 5);
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
  -- PORT: donacija ne postoji u ulaznice → provjera otpada
  perform pg_temp.isto_j('refund donacije: not_a_ticket_order', pg_temp.rpc('service', pg_temp.q_refund(pg_temp.id('f0d0'))),
    jsonb_build_object('status', 'not_a_ticket_order', 'order_id', pg_temp.id('f0d0')));
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
  -- ČUDNO U ORIGINALU: refund računa contributors samo s kupcem (gost e004 ispada), trigger na paid broji i gosta.
  perform pg_temp.isto_j('refund e003: campaign_stats re-sum (14000 − 6000)', pg_temp.statistika(pg_temp.id('c001')),  -- PORT: otpada
    '{"total":8000,"count":5,"contributors":1}');

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
  -- BUG ORIGINALA: mjesto ulaznice poništene void_ticketom ne vraća se nikad (ni void ni refund).
  perform pg_temp.isto_n('refund e001: d001 claimed ostaje 5 (v. BUG)', pg_temp.claimed(pg_temp.id('d001')), 5);
  perform pg_temp.isto_j('refund e001: payload (amount_cents = puni iznos kad je p_amount null)',
    pg_temp.audit_payload(pg_temp.id('e001'), 'ticket_order.refunded'),
    '{"reason":"dispute","external_ref":null,"amount_cents":4000,"voided":0,"kept_checked_in":1,"rail":"stripe"}');
  -- ČUDNO U ORIGINALU: retry vraća voided = SVE void ulaznice (1), a prvi odgovor je rekao 0.
  perform pg_temp.isto_j('refund e001 ponovno: already_refunded broji i ranije void (voided 1 ≠ 0)',
    pg_temp.rpc('service', pg_temp.q_refund(pg_temp.id('e001'))),
    jsonb_build_object('status', 'already_refunded', 'order_id', pg_temp.id('e001'), 'voided', 1, 'kept_checked_in', 1));
  perform pg_temp.isto_j('refund e001: campaign_stats', pg_temp.statistika(pg_temp.id('c001')),  -- PORT: otpada
    '{"total":4000,"count":4,"contributors":1}');
  perform pg_temp.isto_t('refund: event ostaje active (ticket eventi nemaju goal → nikad funded)',
    pg_temp.stanje_eventa(pg_temp.id('c001')), 'active');   -- MAPIRANJE: funded → closed
end $$;
-- potvrda refundirane narudžbe (i istim ref-om) se odbija exceptionom
select pg_temp.pada('service', pg_temp.q_confirm(pg_temp.id('e003'), 'stripe', 'pi_test_e003', 6000),
  'P0001', 'order_not_payable', 'confirm refundirane e003 istim ref-om');
select pg_temp.pada('service', pg_temp.q_confirm(pg_temp.id('e003'), 'stripe', 'pi_test_e003_novi', 6000),
  'P0001', 'order_not_payable', 'confirm refundirane e003 novim ref-om');

do $$ begin
  raise notice 'SVE PROVJERE PROŠLE (% provjera)', current_setting('test.provjere');
end $$;

rollback;
