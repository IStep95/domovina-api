-- Grane kopije koje moraju glasno pasti (dug iz S2, odluka 202):
-- 20261125150200_ulaznice_kopija_podataka.sql korak 0 odbija kopiju ako u
-- pinka_finance postoji:
--   1. ticket kampanja bez retka u pinka_finance.events
--   2. ticket kampanja u stanju koje ulaznice ne poznaju (cancelled)
--   3. narudžba bez tiera (siroče onchain ingesta)
--   4. narudžba u stanju failed (contribution_state nema 'cancelled', pa je
--      failed jedino nepoznato stanje narudžbe)
--   5. plaćena onchain narudžba (> 0 €)
--   6. refundirana onchain narudžba (> 0 €)
-- plus kontrola: bez loših redaka ista kopija prolazi (i mapira railove).
--
-- Kako: psql učita CIJELU migraciju u varijablu (\set s backtickom, `cat`), pa je
-- pg_temp.kopija_pada izvrši EXECUTE-om unutar plpgsql bloka s exception
-- handlerom. Loš redak se ubacuje u istom bloku, pa ga pad (ili sentinel-greška
-- kad kopija NE padne) vraća zajedno s eventualnim učinkom kopije. Migracija je
-- idempotentna (on conflict do nothing), pa ponovno izvođenje nad bazom na kojoj
-- je već primijenjena ne mijenja ništa osim testnih redaka.
--
-- Pokretanje IZ KORIJENA REPOA (put do migracije je relativan na cwd):
--   psql postgresql://postgres:postgres@127.0.0.1:55322/postgres -v ON_ERROR_STOP=1 \
--        -f supabase/tests/20261125_ulaznice_kopija_greske.sql
--
-- Očekivano: NOTICE "OK — …" po grani i na kraju "SVE PROVJERE PROŠLE (N provjera)".
-- Cijeli test je jedna transakcija s ROLLBACK-om (jedini trajni trag: setval
-- sekvence ulaznice.order_events u kontroli, koji je netransakcijski i samo raste).
\set ON_ERROR_STOP on
\timing off
\pset pager off
\set kopija `cat supabase/migrations/20261125150200_ulaznice_kopija_podataka.sql`

begin;

create function pg_temp.id(p text) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-00000013' || p)::uuid
$$;

create function pg_temp.broji() returns void language plpgsql as $$
begin
  perform set_config('test.provjere',
    (coalesce(nullif(current_setting('test.provjere', true), ''), '0')::integer + 1)::text, true);
end $$;

create temp table kopija (sql text not null) on commit drop;
insert into kopija values (:'kopija');

do $$
begin
  if (select position('ulaznice_kopija:' in sql) = 0 or length(sql) < 1000 from kopija) then
    raise exception 'PAO TEST: migracija kopije nije učitana (pokreni iz korijena repoa)';
  end if;
  perform pg_temp.broji();
  raise notice 'OK — migracija kopije učitana (% znakova)', (select length(sql) from kopija);
end $$;

-- Ubaci loše retke (p_priprema), izvrši kopiju; mora pasti s P0001 i porukom
-- koja počinje s p_poruka. Sve unutar subtransakcije, koja se uvijek vraća.
create function pg_temp.kopija_pada(p_priprema text, p_poruka text, p_opis text)
returns void language plpgsql as $$
declare v_state text; v_msg text;
begin
  begin
    execute p_priprema;
    execute (select sql from kopija);
    raise exception using errcode = 'XX999', message = 'NIJE_PALO';
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
  end;
  if v_state = 'XX999' and v_msg = 'NIJE_PALO' then
    raise exception 'PAO TEST: % — kopija prošla bez greške (očekivano %)', p_opis, p_poruka;
  end if;
  if v_state <> 'P0001' or v_msg not like p_poruka || '%' then
    raise exception 'PAO TEST: % — pala s [%] %, očekivano [P0001] %', p_opis, v_state, v_msg, p_poruka;
  end if;
  perform pg_temp.broji();
  raise notice 'OK — % (odbijeno: %)', p_opis, v_msg;
end $$;

-- ── fixture: ispravna ticket kampanja (c001) s tierom i plaćenom stripe narudžbom ──
insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                        email_confirmed_at, created_at, updated_at,
                        raw_app_meta_data, raw_user_meta_data)
values (pg_temp.id('0001'), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
        'test-ulaznice-kopija-0001@example.com', crypt('demo1234', gen_salt('bf')),
        now(), now(), now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb);

insert into public.accounts (id, primary_owner_user_id, is_personal_account, slug, name)
values (pg_temp.id('a001'), pg_temp.id('0001'), false, 'test-ulaznice-kopija-org', 'Test kopija');

create function pg_temp.kampanja(p_id text, p_state text default 'active') returns void language sql as $$
  insert into pinka_finance.campaigns (id, account_id, slug, type, title, subject_type, min_contribution_cents,
                                       currency, destination_address, chain, state, visibility)
  values (pg_temp.id(p_id), pg_temp.id('a001'), 'test-kopija-' || p_id, 'tickets', 'Test kopija ' || p_id,
          'event', 100, 'eur', '0x00000000000000000000000000000000000013c1', 'gnosis',
          p_state::pinka_finance.campaign_state, 'public')
$$;
create function pg_temp.event_redak(p_id text) returns void language sql as $$
  insert into pinka_finance.events (campaign_id, event_type, venue_name, venue_city, starts_at, ends_at, organizer_name)
  values (pg_temp.id(p_id), 'koncert', 'Testna dvorana', 'Zagreb', now() + interval '30 days',
          now() + interval '30 days 3 hours', 'Testni organizator')
$$;
-- narudžba na c001: p_tier null = bez tiera
create function pg_temp.narudzba(p_id text, p_tier text, p_state text, p_rail text, p_amount bigint)
returns void language sql as $$
  insert into pinka_finance.contributions (id, campaign_id, tier_id, amount_cents, currency, quantity, state,
                                           destination_address, reserved, payment_rail, paid_at)
  values (pg_temp.id(p_id), pg_temp.id('c001'), pg_temp.id(p_tier), p_amount, 'eur', 1,
          p_state::pinka_finance.contribution_state, '0x00000000000000000000000000000000000013c1',
          p_tier is not null, p_rail, case when p_state in ('paid', 'refunded') then now() end)
$$;

select pg_temp.kampanja('c001');
select pg_temp.event_redak('c001');
insert into pinka_finance.campaign_tiers (id, campaign_id, title, price_cents, inventory_total, sort, kind)
values (pg_temp.id('d001'), pg_temp.id('c001'), 'Redovna', 2000, 10, 0, 'ticket'),
       (pg_temp.id('d002'), pg_temp.id('c001'), 'Besplatna', 0, 10, 1, 'ticket');
select pg_temp.narudzba('e001', 'd001', 'paid', 'stripe', 2000);
-- dopuštene onchain grane: istekla (povijest) i 0 € plaćena (→ free)
select pg_temp.narudzba('e002', 'd001', 'expired', 'onchain', 2000);
select pg_temp.narudzba('e003', 'd002', 'paid', 'onchain', 0);
select pg_temp.narudzba('e004', 'd001', 'pending', 'onchain', 2000);

-- ── kontrola: bez loših redaka kopija prolazi ──
do $$
declare v jsonb;
begin
  begin
    execute (select sql from kopija);
    select jsonb_object_agg(id::text, payment_rail) into v
      from ulaznice.orders where event_id = pg_temp.id('c001');
    raise exception using errcode = 'XX998', message = coalesce(v::text, 'null');
  exception when sqlstate 'XX998' then
    get stacked diagnostics v = message_text;
  end;
  if v is distinct from jsonb_build_object(pg_temp.id('e001')::text, 'stripe', pg_temp.id('e002')::text, 'onchain',
                                           pg_temp.id('e003')::text, 'free', pg_temp.id('e004')::text, 'stripe') then
    raise exception 'PAO TEST: kontrola — kopirane narudžbe/railovi: %', v;
  end if;
  perform pg_temp.broji();
  raise notice 'OK — kontrola: bez loših redaka kopija prolazi (stripe/onchain expired/0 € → free/onchain pending → stripe)';
  if exists (select 1 from ulaznice.orders where event_id = pg_temp.id('c001')) then
    raise exception 'PAO TEST: kontrola — kopija nije vraćena';
  end if;
end $$;

-- ── grane koje moraju pasti ──
select pg_temp.kopija_pada($q$ select pg_temp.kampanja('c0e1') $q$,
  'ulaznice_kopija: 1 ticket kampanja nema redak u pinka_finance.events',
  'ticket kampanja bez events retka');

select pg_temp.kopija_pada($q$ select pg_temp.kampanja('c0e2', 'cancelled'); select pg_temp.event_redak('c0e2') $q$,
  'ulaznice_kopija: 1 ticket kampanja u stanju koje ulaznice ne poznaju',
  'ticket kampanja u stanju cancelled');

select pg_temp.kopija_pada($q$ select pg_temp.narudzba('e0e3', null, 'paid', 'onchain', 2000) $q$,
  'ulaznice_kopija: 1 narudžbi bez tiera',
  'narudžba bez tiera');

select pg_temp.kopija_pada($q$ select pg_temp.narudzba('e0e4', 'd001', 'failed', 'stripe', 2000) $q$,
  'ulaznice_kopija: 1 narudžbi u stanju koje ulaznice ne poznaju',
  'narudžba u stanju failed');

select pg_temp.kopija_pada($q$ select pg_temp.narudzba('e0e5', 'd001', 'paid', 'onchain', 2000) $q$,
  'ulaznice_kopija: 1 plaćenih/refundiranih onchain narudžbi',
  'plaćena onchain narudžba');

select pg_temp.kopija_pada($q$ select pg_temp.narudzba('e0e6', 'd001', 'refunded', 'onchain', 2000) $q$,
  'ulaznice_kopija: 1 plaćenih/refundiranih onchain narudžbi',
  'refundirana onchain narudžba');

do $$
begin
  if exists (select 1 from pinka_finance.contributions where id::text like '00000000-0000-4000-8000-00000013e0e%')
     or exists (select 1 from pinka_finance.campaigns where id in (pg_temp.id('c0e1'), pg_temp.id('c0e2'))) then
    raise exception 'PAO TEST: loši redci nisu vraćeni nakon grane';
  end if;
  perform pg_temp.broji();
  raise notice 'OK — svi loši redci vraćeni (grane su izolirane)';
  raise notice 'SVE PROVJERE PROŠLE (% provjera)', current_setting('test.provjere');
end $$;

rollback;
