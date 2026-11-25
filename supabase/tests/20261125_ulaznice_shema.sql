-- Provjera migracija 20261125150000_ulaznice_shema, 20261125150100_ulaznice_media_bucket
-- i 20261125150200_ulaznice_kopija_podataka (S2 lanca „odvajanje ulaznica”,
-- docs/ulaznice-shema/).
--
-- Pokretanje nad lokalnim stackom (ponovljivo, bez mreže):
--   supabase db reset --no-seed
--   psql "postgresql://postgres:postgres@127.0.0.1:55322/postgres" \
--        -f supabase/tests/20261125_ulaznice_shema.sql
--
-- Očekivano: NOTICE redci "OK — …" i na kraju NOTICE "SVE PROVJERE PROŠLE".
-- Svaki drugi ishod je pad (ON_ERROR_STOP).
--
-- Kopija se NE duplicira u testu: tijelo migracije 20261125150200 izvodi se
-- izravno (`\ir`), dvaput zaredom, nad pinka_finance fixtureom ovog testa.
-- Migracija kopira SVE ticket kampanje u bazi, pa test sve brojeve ograničava
-- na svoje ID-jeve (prefiks 00000000-0000-4000-8000-00000011….).
--
-- Trag se briše na POČETKU: ulaznice.events (kaskadno tierovi, narudžbe,
-- ulaznice, audit, event_access), pinka_finance.campaigns (kaskadno sve) i
-- organizer_* oba schema za testne org račune. Korisnici, računi, članstva i
-- KYC redak se upsertaju. Pozitivni upis u storage.objects se poništava
-- (subtransakcija), pa u storageu ne ostaje ništa.
\set ON_ERROR_STOP on
\timing off
\pset pager off

-- ── pomoćnici ───────────────────────────────────────────────────────────────
-- Testni ID: 4 hex znaka iza prefiksa.
create or replace function pg_temp.id(p text) returns uuid language sql as $$
  select ('00000000-0000-4000-8000-00000011' || p)::uuid
$$;

-- Osobni račun korisnika (stvara ga public.handle_new_user).
create or replace function pg_temp.osobni(p_user text) returns uuid language sql as $$
  select id from public.accounts
   where primary_owner_user_id = pg_temp.id(p_user) and is_personal_account
$$;

-- Uloga + JWT za ostatak transakcije: 'postgres' | 'anon' | 'service' | uuid korisnika.
create or replace function pg_temp.kao(p text) returns void language plpgsql as $$
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
      jsonb_build_object('sub', p::uuid, 'role', 'authenticated')::text, true);
    perform set_config('role', 'authenticated', true);
  end if;
end $$;

-- Izvrši SQL kao zadana uloga i vrati prvi stupac prvog retka kao text.
create or replace function pg_temp.izvrsi(p_kao text, p_sql text) returns text language plpgsql as $$
declare v text;
begin
  perform pg_temp.kao(p_kao);
  execute p_sql into v;
  perform pg_temp.kao('postgres');
  return v;
exception when others then
  perform pg_temp.kao('postgres');
  raise exception 'PAO TEST: [%] neočekivana greška: % (SQL: %)', p_kao, sqlerrm, p_sql;
end $$;

-- Očekivan pad. p_err: prefiks poruke ili '#SQLSTATE'; više alternativa s '|'.
-- Ako naredba NE padne, sentinel-greška poništi i njezin učinak (subtransakcija).
create or replace function pg_temp.pada(p_kao text, p_sql text, p_err text, p_opis text)
returns void language plpgsql as $$
declare v_state text; v_msg text; v_alt text; v_ok boolean := false;
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
    raise exception 'PAO TEST: % — prošlo bez greške (očekivano %)', p_opis, p_err;
  end if;
  foreach v_alt in array string_to_array(p_err, '|') loop
    if (v_alt like '#%' and v_state = substr(v_alt, 2))
       or (v_alt not like '#%' and v_msg like v_alt || '%') then
      v_ok := true;
    end if;
  end loop;
  if not v_ok then
    raise exception 'PAO TEST: % — pala s [%] %, očekivano %', p_opis, v_state, v_msg, p_err;
  end if;
  raise notice 'OK — % (odbijeno: %)', p_opis, v_msg;
end $$;

-- Očekivan prolaz, ali bez trajnog učinka: naredba se izvrši pa poništi.
create or replace function pg_temp.prolazi(p_kao text, p_sql text, p_opis text)
returns void language plpgsql as $$
declare v_state text; v_msg text;
begin
  begin
    perform pg_temp.kao(p_kao);
    execute p_sql;
    raise exception using errcode = 'XX999', message = 'PONISTI';
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
  end;
  perform pg_temp.kao('postgres');
  if not (v_state = 'XX999' and v_msg = 'PONISTI') then
    raise exception 'PAO TEST: % — pala s [%] %', p_opis, v_state, v_msg;
  end if;
  raise notice 'OK — % (prošlo, poništeno)', p_opis;
end $$;

-- ── 0. brisanje traga prethodnog prolaza ────────────────────────────────────
-- Org računi: a001 (organizator A), a002 (organizator B).
-- Korisnici: 0001 vlasnik A s KYC-om | 0002 admin A bez KYC-a | 0003 kupac |
--            0004 vlasnik B i drugi kupac | 0005 običan član A.
-- pinka_finance: c001 aktivan/javan (cover + galerija + event_access),
--   c002 skica, c003 obrisana skica, c004 funded/javan, c005 aktivan/javan
--   organizatora B, c0d0 DONACIJA (ne smije se kopirati).
-- c0f1 je event koji authenticated upisuje izravno u ulaznice.events.
delete from ulaznice.events
 where id in (select pg_temp.id(x) from unnest(array['c001','c002','c003','c004','c005','c0d0','c0f1']) x);
delete from pinka_finance.campaigns
 where id in (select pg_temp.id(x) from unnest(array['c001','c002','c003','c004','c005','c0d0']) x);
delete from ulaznice.organizer_allowlist     where account_id in (pg_temp.id('a001'), pg_temp.id('a002'));
delete from ulaznice.organizer_records       where account_id in (pg_temp.id('a001'), pg_temp.id('a002'));
delete from ulaznice.organizer_payment_rails where account_id in (pg_temp.id('a001'), pg_temp.id('a002'));
delete from pinka_finance.organizer_allowlist     where account_id in (pg_temp.id('a001'), pg_temp.id('a002'));
delete from pinka_finance.organizer_records       where account_id in (pg_temp.id('a001'), pg_temp.id('a002'));
delete from pinka_finance.organizer_payment_rails where account_id in (pg_temp.id('a001'), pg_temp.id('a002'));

-- ── 1. struktura ────────────────────────────────────────────────────────────
\echo '--- 1. struktura sheme ulaznice'
do $$
declare
  t text; n integer; v text[];
begin
  foreach t in array array['events','ticket_tiers','orders','tickets','order_events','event_access',
                           'organizer_allowlist','organizer_records','organizer_payment_rails'] loop
    if to_regclass('ulaznice.' || t) is null then
      raise exception 'PAO TEST: nema tablice ulaznice.%', t;
    end if;
    if not (select relrowsecurity from pg_class where oid = ('ulaznice.' || t)::regclass) then
      raise exception 'PAO TEST: ulaznice.% nema uključen RLS', t;
    end if;
  end loop;
  raise notice 'OK — 9 tablica postoji, sve s RLS-om';

  select array_agg(enumlabel::text order by enumsortorder) into v
    from pg_enum where enumtypid = to_regtype('ulaznice.ticket_state');
  if v is distinct from array['issued','checked_in','void'] then
    raise exception 'PAO TEST: enum ulaznice.ticket_state = %', v;
  end if;
  raise notice 'OK — enum ticket_state (issued, checked_in, void)';

  foreach t in array array['ulaznice.sanitize_ugc(text)','ulaznice.slugify(text)',
                           'ulaznice.events_gallery_valid(jsonb)','ulaznice.guard_immutable_slug()',
                           'ulaznice.events_write_guard()'] loop
    if to_regprocedure(t) is null then
      raise exception 'PAO TEST: nema funkcije %', t;
    end if;
  end loop;
  if ulaznice.slugify('Čakovečki Đir 2026!') <> 'cakovecki-dir-2026'
     or ulaznice.sanitize_ugc(E'  a\x01b  ') <> 'ab' or ulaznice.sanitize_ugc('   ') is not null
     or not ulaznice.events_gallery_valid('[{"url":"https://x/y.jpg","alt":null}]')
     or ulaznice.events_gallery_valid('[{"alt":"bez url-a"}]') then
    raise exception 'PAO TEST: kopije pomoćnih funkcija ne rade kao izvornik';
  end if;
  raise notice 'OK — funkcije sanitize_ugc, slugify, events_gallery_valid, guard_immutable_slug, events_write_guard';

  select count(*) into n from pg_default_acl where defaclnamespace = 'ulaznice'::regnamespace;
  if n <> 0 then raise exception 'PAO TEST: shema ulaznice ima % default privileges', n; end if;
  -- ni globalni default ACL ne smije anonu dati ništa osim izričitog SELECT-a na events/ticket_tiers
  select count(*) into n
    from pg_class c cross join lateral aclexplode(c.relacl) a
   where c.relnamespace = 'ulaznice'::regnamespace and c.relkind in ('r', 'S', 'v', 'm')
     and (a.grantee = 0 or a.grantee = 'anon'::regrole)
     and not (c.relname in ('events', 'ticket_tiers') and a.privilege_type = 'SELECT');
  if n <> 0 then raise exception 'PAO TEST: anon/PUBLIC ima % suvišnih grantova u ulaznice', n; end if;
  if has_function_privilege('anon', 'ulaznice.slugify(text)', 'execute')
     or has_function_privilege('authenticated', 'ulaznice.events_write_guard()', 'execute') then
    raise exception 'PAO TEST: execute na pomoćnim/trigger funkcijama nije zatvoren';
  end if;
  raise notice 'OK — bez default privileges; anon ima samo SELECT na events i ticket_tiers';

  select count(*) into n from information_schema.columns
   where table_schema = 'ulaznice' and table_name = 'orders'
     and column_name in ('destination_address','chain','forward_tx_hash','onchain_from','onchain_log_index',
                         'declared_payer_address','underpaid','monerium_order_id','payment_intent_sid',
                         'desired_slot_keys','sold_slots');
  if n <> 0 then raise exception 'PAO TEST: ulaznice.orders ima % onchain/slot stupaca', n; end if;
  select count(*) into n from information_schema.columns
   where table_schema = 'ulaznice' and table_name = 'events'
     and column_name in ('destination_address','chain','safe_deployed_at');
  if n <> 0 then raise exception 'PAO TEST: ulaznice.events ima % onchain stupaca', n; end if;
  raise notice 'OK — orders bez onchain stupaca, events bez destination_address/chain/safe_deployed_at';
end $$;

-- ── 2. fixture: korisnici, računi, članstva, KYC ────────────────────────────
insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                        email_confirmed_at, created_at, updated_at,
                        raw_app_meta_data, raw_user_meta_data)
select pg_temp.id(n), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       'test-ulaznice-' || n || '@example.com', crypt('demo1234', gen_salt('bf')),
       now(), now(), now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb
  from unnest(array['0001','0002','0003','0004','0005']) n
on conflict (id) do nothing;

insert into public.accounts (id, primary_owner_user_id, is_personal_account, slug, name)
values (pg_temp.id('a001'), pg_temp.id('0001'), false, 'test-ulaznice-org-a', 'Test ulaznice A'),
       (pg_temp.id('a002'), pg_temp.id('0004'), false, 'test-ulaznice-org-b', 'Test ulaznice B')
on conflict (id) do nothing;

insert into public.accounts_memberships (account_id, user_id, account_role)
values (pg_temp.id('a001'), pg_temp.id('0001'), 'owner'),
       (pg_temp.id('a001'), pg_temp.id('0002'), 'admin'),
       (pg_temp.id('a001'), pg_temp.id('0005'), 'member'),
       (pg_temp.id('a002'), pg_temp.id('0004'), 'owner')
on conflict (account_id, user_id) do update set account_role = excluded.account_role;

insert into public.identity_verifications (user_id, oib_ciphertext, oib_hash)
values (pg_temp.id('0001'), '\x00'::bytea, 'test-ulaznice-oib-hash-0001')
on conflict (user_id) do nothing;

-- ── 3. fixture: pinka_finance (izvor kopije) ────────────────────────────────
insert into pinka_finance.campaigns (id, account_id, slug, type, title, subject_type, min_contribution_cents,
                                     currency, destination_address, chain, state, visibility, deleted_at,
                                     cover_image_url)
select pg_temp.id(v.id), pg_temp.id(v.acc), v.slug, v.type::pinka_finance.campaign_type, v.title, v.st, 100,
       'eur', '0x00000000000000000000000000000000000011c1', 'gnosis',
       v.state::pinka_finance.campaign_state, v.vis::pinka_finance.campaign_visibility,
       case when v.obrisan then now() - interval '1 day' end, v.cover
  from (values
    ('c001', 'a001', 'test-ulaznice-aktivan', 'tickets', 'Test ulaznice: aktivan', 'event', 'active', 'public', false,
     'https://api.example.test/storage/v1/object/public/pinka-covers/00000000-0000-4000-8000-000000110001/cover.jpg'),
    ('c002', 'a001', 'test-ulaznice-skica', 'tickets', 'Test ulaznice: skica', 'event', 'draft', 'private', false, null),
    ('c003', 'a001', 'test-ulaznice-obrisana', 'tickets', 'Test ulaznice: obrisana skica', 'event', 'draft', 'private', true, null),
    ('c004', 'a001', 'test-ulaznice-funded', 'tickets', 'Test ulaznice: funded', 'event', 'funded', 'public', false, null),
    ('c005', 'a002', 'test-ulaznice-tudji', 'tickets', 'Test ulaznice: organizator B', 'event', 'active', 'public', false, null),
    ('c0d0', 'a001', 'test-ulaznice-donacija', 'donation', 'Test ulaznice: donacija', 'podcast_channel', 'active', 'public', false, null)
  ) v(id, acc, slug, type, title, st, state, vis, obrisan, cover);

insert into pinka_finance.events (campaign_id, event_type, venue_name, venue_city, starts_at, ends_at,
                                  organizer_name, cover_image_url, gallery)
select pg_temp.id(v.id), 'koncert', 'Testna dvorana', 'Zagreb', now() + interval '30 days',
       now() + interval '30 days 3 hours', 'Testni organizator', v.cover, v.gal::jsonb
  from (values
    ('c001',
     'https://api.example.test/storage/v1/object/public/pinka-covers/00000000-0000-4000-8000-000000110001/cover.jpg',
     '[{"url":"https://api.example.test/storage/v1/object/public/pinka-covers/00000000-0000-4000-8000-000000110001/g1.jpg","alt":"prva"},
       {"url":"https://vanjski.example.test/slika.jpg","alt":null},
       {"url":"https://api.example.test/storage/v1/object/public/pinka-covers/00000000-0000-4000-8000-000000110001/g2.webp"}]'),
    ('c002', null, '[]'),
    ('c003', null, '[]'),
    ('c004', null, '[]'),
    ('c005', null, '[]')
  ) v(id, cover, gal);

insert into pinka_finance.campaign_tiers (id, campaign_id, title, price_cents, inventory_total, sort, kind)
select pg_temp.id(v.id), pg_temp.id(v.c), v.title, v.price, 100, v.sort, 'ticket'
  from (values ('d001', 'c001', 'Redovna', 2000, 0),
               ('d002', 'c001', 'Besplatna', 0, 1),
               ('d003', 'c002', 'Skica tier', 1000, 0),
               ('d004', 'c005', 'Tier B', 1500, 0)) v(id, c, title, price, sort);

-- Narudžbe: f001 stripe paid (0003) | f002 0 € s defaultnim railom onchain (0003)
-- | f003 onchain expired (0004) | f004 onchain pending gost | f005 stripe paid
-- na eventu organizatora B (0003) | f0d0 DONACIJA.
insert into pinka_finance.contributions (id, campaign_id, tier_id, contributor_account_id, amount_cents, currency,
                                         quantity, state, destination_address, payment_rail, external_payment_ref,
                                         reserved, paid_at)
select pg_temp.id(v.id), pg_temp.id(v.c), case when v.t is not null then pg_temp.id(v.t) end,
       case when v.kupac is not null then pg_temp.osobni(v.kupac) end, v.iznos, 'eur', v.kol,
       v.state::pinka_finance.contribution_state, '0x00000000000000000000000000000000000011c1', v.rail, v.ref,
       v.t is not null, case when v.state = 'paid' then now() end
  from (values ('f001', 'c001', 'd001', '0003', 4000, 2, 'paid',    'stripe',  'pi_test_ulaznice_f001'),
               ('f002', 'c001', 'd002', '0003',    0, 1, 'paid',    'onchain', null),
               ('f003', 'c001', 'd001', '0004', 6500, 1, 'expired', 'onchain', null),
               ('f004', 'c001', 'd001', null,   2000, 1, 'pending', 'onchain', null),
               ('f005', 'c005', 'd004', '0003', 1500, 1, 'paid',    'stripe',  'pi_test_ulaznice_f005'),
               ('f0d0', 'c0d0', null,   '0003',  500, 1, 'paid',    'onchain', null)
  ) v(id, c, t, kupac, iznos, kol, state, rail, ref);

insert into pinka_finance.tickets (id, contribution_id, campaign_id, tier_id, serial, holder_name,
                                   qr_token_hash, state)
values (pg_temp.id('b001'), pg_temp.id('f001'), pg_temp.id('c001'), pg_temp.id('d001'), 'TST-000001', 'Ana Test',
        encode(sha256('test-ulaznice-b001'::bytea), 'hex'), 'issued'),
       (pg_temp.id('b002'), pg_temp.id('f005'), pg_temp.id('c005'), pg_temp.id('d004'), 'TSB-000001', null,
        encode(sha256('test-ulaznice-b002'::bytea), 'hex'), 'checked_in');

-- uz automatske 'contribution.created' (trigger) i jedan ručni audit
insert into pinka_finance.contribution_events (contribution_id, campaign_id, event_type, payload)
values (pg_temp.id('f001'), pg_temp.id('c001'), 'ticket.issued', '{"serial":"TST-000001"}');

insert into pinka_finance.event_access (campaign_id, online_url)
values (pg_temp.id('c001'), 'https://meet.example.test/tajni-link');

insert into pinka_finance.organizer_allowlist (account_id, note) values (pg_temp.id('a001'), 'test ulaznice');
insert into pinka_finance.organizer_records (account_id, legal_name, oib, address_line, city, postal_code,
                                             financial_identifier_type, financial_identifier)
values (pg_temp.id('a001'), 'Test Ulaznice d.o.o.', '12345678903', 'Ilica 1', 'Zagreb', '10000',
        'iban', 'HR1210010051863000160');
insert into pinka_finance.organizer_payment_rails (account_id, stripe_account_id, stripe_charges_enabled)
values (pg_temp.id('a001'), 'acct_testUlazniceA', true);

-- brojevi izvora prije kopije (ograničeni na testne ID-jeve)
do $$ begin
  perform set_config('test.pf_contrib_prije', (select count(*) from pinka_finance.contributions)::text, false);
  perform set_config('test.pf_ce_prije', (select count(*) from pinka_finance.contribution_events)::text, false);
end $$;

-- ── 4. kopija: tijelo migracije 20261125150200, dvaput ──────────────────────
\echo '--- 4. kopija podataka (migracija 20261125150200), prvi prolaz'
\ir ../migrations/20261125150200_ulaznice_kopija_podataka.sql
\echo '--- 4. kopija podataka, drugi prolaz (mora biti no-op)'
\ir ../migrations/20261125150200_ulaznice_kopija_podataka.sql

do $$
declare
  n integer; m integer; e ulaznice.events; g jsonb;
  c_tickets uuid[] := array[pg_temp.id('c001'), pg_temp.id('c002'), pg_temp.id('c003'),
                            pg_temp.id('c004'), pg_temp.id('c005')];
begin
  -- isti ID-jevi i jednaki brojevi, bez duplikata (drugi prolaz)
  select count(*) into n from ulaznice.events where id = any (c_tickets);
  if n <> 5 then raise exception 'PAO TEST: kopirano % eventa, očekivano 5', n; end if;
  select count(*) into n from pinka_finance.campaign_tiers t where t.campaign_id = any (c_tickets)
     and not exists (select 1 from ulaznice.ticket_tiers u where u.id = t.id and u.event_id = t.campaign_id);
  select count(*) into m from ulaznice.ticket_tiers where event_id = any (c_tickets);
  if n <> 0 or m <> 4 then raise exception 'PAO TEST: tierovi: nedostaje %, u ulaznice %', n, m; end if;
  select count(*) into n from pinka_finance.contributions ct where ct.campaign_id = any (c_tickets)
     and not exists (select 1 from ulaznice.orders o where o.id = ct.id and o.event_id = ct.campaign_id
                       and o.tier_id = ct.tier_id and o.buyer_account_id is not distinct from ct.contributor_account_id
                       and o.amount_cents = ct.amount_cents and o.quantity = ct.quantity
                       and o.state = ct.state::text);
  select count(*) into m from ulaznice.orders where event_id = any (c_tickets);
  if n <> 0 or m <> 5 then raise exception 'PAO TEST: narudžbe: neodgovara %, u ulaznice %', n, m; end if;
  select count(*) into n from pinka_finance.tickets t where t.campaign_id = any (c_tickets)
     and not exists (select 1 from ulaznice.tickets u where u.id = t.id and u.order_id = t.contribution_id
                       and u.qr_token_hash = t.qr_token_hash and u.serial = t.serial
                       and u.state::text = t.state::text);
  select count(*) into m from ulaznice.tickets where event_id = any (c_tickets);
  if n <> 0 or m <> 2 then raise exception 'PAO TEST: ulaznice: neodgovara %, u ulaznice %', n, m; end if;
  select count(*) into n from pinka_finance.contribution_events ce where ce.campaign_id = any (c_tickets)
     and not exists (select 1 from ulaznice.order_events u where u.id = ce.id and u.order_id = ce.contribution_id
                       and u.event_type = ce.event_type and u.payload = ce.payload
                       and u.created_at = ce.created_at);
  select count(*) - (select count(*) from pinka_finance.contribution_events where campaign_id = any (c_tickets))
    into m from ulaznice.order_events where event_id = any (c_tickets);
  if n <> 0 or m <> 0 then raise exception 'PAO TEST: order_events: neodgovara %, razlika u broju %', n, m; end if;
  if (select count(*) from ulaznice.order_events where event_id = any (c_tickets)) <> 6 then
    raise exception 'PAO TEST: order_events % (očekivano 5 created + 1 ticket.issued)',
      (select count(*) from ulaznice.order_events where event_id = any (c_tickets));
  end if;
  select count(*) into n from ulaznice.event_access where event_id = pg_temp.id('c001')
     and online_url = 'https://meet.example.test/tajni-link';
  if n <> 1 then raise exception 'PAO TEST: event_access nije kopiran'; end if;
  if (select count(*) from ulaznice.organizer_allowlist where account_id = pg_temp.id('a001')) <> 1
     or (select count(*) from ulaznice.organizer_records where account_id = pg_temp.id('a001')
           and oib = '12345678903') <> 1
     or (select count(*) from ulaznice.organizer_payment_rails where account_id = pg_temp.id('a001')
           and stripe_account_id = 'acct_testUlazniceA' and stripe_charges_enabled) <> 1 then
    raise exception 'PAO TEST: organizer_* nisu kopirani';
  end if;
  raise notice 'OK — kopija nakon 2 prolaza: 5 eventa, 4 tiera, 5 narudžbi, 2 ulaznice, 6 audita, event_access, organizer_* — isti ID-jevi, bez duplikata';

  -- sekvenca order_events iznad svih id-jeva
  if (select last_value from pg_sequences where schemaname = 'ulaznice' and sequencename = 'order_events_id_seq')
     < (select max(id) from pinka_finance.contribution_events) then
    raise exception 'PAO TEST: identity order_events ispod max(contribution_events.id)';
  end if;
  raise notice 'OK — identity order_events podignuta iznad max id-ja';

  -- mapiranja
  select * into e from ulaznice.events where id = pg_temp.id('c004');
  if e.state <> 'closed' then raise exception 'PAO TEST: funded → %, očekivano closed', e.state; end if;
  select * into e from ulaznice.events where id = pg_temp.id('c003');
  if e.deleted_at is null or e.state <> 'draft' then raise exception 'PAO TEST: obrisana skica izgubila deleted_at'; end if;
  select * into e from ulaznice.events where id = pg_temp.id('c002');
  if e.state <> 'draft' or e.visibility <> 'private' or e.deleted_at is not null then
    raise exception 'PAO TEST: skica % / %', e.state, e.visibility;
  end if;
  if (select string_agg(payment_rail, ',' order by id) from ulaznice.orders
       where id in (pg_temp.id('f001'), pg_temp.id('f002'), pg_temp.id('f003'), pg_temp.id('f004')))
     <> 'stripe,free,onchain,stripe' then
    raise exception 'PAO TEST: mapiranje raila %', (select string_agg(payment_rail, ',' order by id)
      from ulaznice.orders where id in (pg_temp.id('f001'), pg_temp.id('f002'), pg_temp.id('f003'), pg_temp.id('f004')));
  end if;
  raise notice 'OK — mapiranja: funded→closed, obrisana skica zadržava deleted_at, rail stripe/0 €→free/onchain+expired→onchain/onchain+pending→stripe';

  -- URL-ovi
  select * into e from ulaznice.events where id = pg_temp.id('c001');
  if e.cover_image_url <> 'https://api.example.test/storage/v1/object/public/ulaznice-media/00000000-0000-4000-8000-000000110001/cover.jpg' then
    raise exception 'PAO TEST: cover nije prepisan: %', e.cover_image_url;
  end if;
  g := e.gallery;
  if jsonb_array_length(g) <> 3
     or g->0->>'url' <> 'https://api.example.test/storage/v1/object/public/ulaznice-media/00000000-0000-4000-8000-000000110001/g1.jpg'
     or g->0->>'alt' <> 'prva'
     or g->1->>'url' <> 'https://vanjski.example.test/slika.jpg'
     or g->2->>'url' <> 'https://api.example.test/storage/v1/object/public/ulaznice-media/00000000-0000-4000-8000-000000110001/g2.webp'
     or g::text like '%pinka-covers%' then
    raise exception 'PAO TEST: galerija nije ispravno prepisana: %', g;
  end if;
  if (select cover_image_url from pinka_finance.events where campaign_id = pg_temp.id('c001')) not like '%/pinka-covers/%' then
    raise exception 'PAO TEST: kopija je promijenila izvor pinka_finance.events';
  end if;
  raise notice 'OK — cover i 2 slike galerije prepisane na ulaznice-media, vanjski URL i redoslijed netaknuti, izvor netaknut';

  -- donacije se ne kopiraju, izvor netaknut
  if exists (select 1 from ulaznice.events where id = pg_temp.id('c0d0'))
     or exists (select 1 from ulaznice.orders where id = pg_temp.id('f0d0'))
     or exists (select 1 from ulaznice.order_events where order_id = pg_temp.id('f0d0')) then
    raise exception 'PAO TEST: donacijska kampanja/doprinos kopiran u ulaznice';
  end if;
  if (select count(*) from pinka_finance.contributions)::text <> current_setting('test.pf_contrib_prije')
     or (select count(*) from pinka_finance.contribution_events)::text <> current_setting('test.pf_ce_prije')
     or not exists (select 1 from pinka_finance.contributions where id = pg_temp.id('f0d0') and state = 'paid') then
    raise exception 'PAO TEST: kopija je promijenila pinka_finance';
  end if;
  raise notice 'OK — donacija (kampanja, doprinos, audit) nije kopirana; pinka_finance brojevi isti prije i poslije';
end $$;

-- ── 5. CHECK-ovi i trigeri ──────────────────────────────────────────────────
\echo '--- 5. CHECK-ovi (onchain samo uz expired, 0 € samo free) i nepromjenjiv slug'
select pg_temp.pada('postgres',
  format($q$insert into ulaznice.orders (id, event_id, tier_id, amount_cents, state, payment_rail)
            values (gen_random_uuid(), %L, %L, 2000, 'pending', 'onchain')$q$, pg_temp.id('c001'), pg_temp.id('d001')),
  '#23514', 'orders: onchain + pending');
select pg_temp.pada('postgres',
  format($q$insert into ulaznice.orders (id, event_id, tier_id, amount_cents, state, payment_rail)
            values (gen_random_uuid(), %L, %L, 2000, 'paid', 'onchain')$q$, pg_temp.id('c001'), pg_temp.id('d001')),
  '#23514', 'orders: onchain + paid');
select pg_temp.prolazi('postgres',
  format($q$insert into ulaznice.orders (id, event_id, tier_id, amount_cents, state, payment_rail)
            values (gen_random_uuid(), %L, %L, 2000, 'expired', 'onchain')$q$, pg_temp.id('c001'), pg_temp.id('d001')),
  'orders: onchain + expired dopušten');
select pg_temp.pada('postgres',
  format($q$update ulaznice.orders set state = 'pending' where id = %L$q$, pg_temp.id('f003')),
  '#23514', 'orders: expired onchain narudžba se ne vraća u pending');
select pg_temp.pada('postgres',
  format($q$insert into ulaznice.orders (id, event_id, tier_id, amount_cents, state, payment_rail)
            values (gen_random_uuid(), %L, %L, 0, 'paid', 'stripe')$q$, pg_temp.id('c001'), pg_temp.id('d002')),
  '#23514', 'orders: 0 € na stripe railu');
select pg_temp.prolazi('postgres',
  format($q$insert into ulaznice.orders (id, event_id, tier_id, amount_cents, state, payment_rail)
            values (gen_random_uuid(), %L, %L, 0, 'paid', 'free')$q$, pg_temp.id('c001'), pg_temp.id('d002')),
  'orders: 0 € na free railu dopušten');
select pg_temp.pada('postgres',
  format($q$insert into ulaznice.orders (id, event_id, tier_id, amount_cents, state, payment_rail)
            values (gen_random_uuid(), %L, %L, 1000, 'failed', 'stripe')$q$, pg_temp.id('c001'), pg_temp.id('d001')),
  '#23514', 'orders: stanje failed ne postoji');
select pg_temp.pada('postgres',
  format($q$update ulaznice.events set slug = 'test-ulaznice-novi' where id = %L$q$, pg_temp.id('c001')),
  'slug_immutable', 'events: slug je nepromjenjiv (i za postgres)');
select pg_temp.pada('postgres',
  format($q$update ulaznice.events set state = 'cancelled' where id = %L$q$, pg_temp.id('c001')),
  '#23514', 'events: stanje cancelled ne postoji');
select pg_temp.pada('postgres',
  format($q$delete from ulaznice.ticket_tiers where id = %L$q$, pg_temp.id('d001')),
  '#23503', 'ticket_tiers: tier s narudžbama se ne briše');

-- ── 6. RLS ──────────────────────────────────────────────────────────────────
\echo '--- 6. RLS: anon'
select pg_temp.pada('anon', 'select count(*) from ulaznice.' || t, '#42501', 'anon ne čita ulaznice.' || t)
  from unnest(array['event_access','orders','tickets','order_events',
                    'organizer_allowlist','organizer_records','organizer_payment_rails']) t;
do $$
declare v text;
begin
  v := pg_temp.izvrsi('anon', format($q$select string_agg(right(id::text, 4), ',' order by id) from ulaznice.events
                                        where id in (%L, %L, %L, %L, %L)$q$,
    pg_temp.id('c001'), pg_temp.id('c002'), pg_temp.id('c003'), pg_temp.id('c004'), pg_temp.id('c005')));
  if v is distinct from 'c001,c004,c005' then
    raise exception 'PAO TEST: anon vidi evente % (očekivano c001,c004,c005 — bez skice i obrisane)', v;
  end if;
  v := pg_temp.izvrsi('anon', format($q$select string_agg(right(id::text, 4), ',' order by id) from ulaznice.ticket_tiers
                                        where id in (%L, %L, %L)$q$, pg_temp.id('d001'), pg_temp.id('d002'), pg_temp.id('d003')));
  if v is distinct from 'd001,d002' then
    raise exception 'PAO TEST: anon vidi tierove % (očekivano d001,d002 — bez tiera skice)', v;
  end if;
  raise notice 'OK — anon čita javne aktivne/zatvorene evente i njihove tierove, ne skicu ni obrisanu';
end $$;
select pg_temp.pada('anon',
  format($q$insert into ulaznice.events (account_id, slug, title, venue_name, venue_city, organizer_name)
            values (%L, 'test-ulaznice-anon', 'x', 'x', 'x', 'x')$q$, pg_temp.id('a001')),
  '#42501', 'anon ne piše u ulaznice.events');

\echo '--- 6. RLS: kupac, admin, član'
do $$
declare v text; k text;
begin
  k := format('(%L, %L, %L, %L, %L)', pg_temp.id('f001'), pg_temp.id('f002'), pg_temp.id('f003'),
              pg_temp.id('f004'), pg_temp.id('f005'));
  -- kupac 0003: svoje (f001, f002, f005), ne tuđe (f003) ni gostovu (f004)
  v := pg_temp.izvrsi(pg_temp.id('0003')::text,
    'select string_agg(right(id::text, 4), '','' order by id) from ulaznice.orders where id in ' || k);
  if v is distinct from 'f001,f002,f005' then raise exception 'PAO TEST: kupac vidi narudžbe %', v; end if;
  v := pg_temp.izvrsi(pg_temp.id('0004')::text,
    'select string_agg(right(id::text, 4), '','' order by id) from ulaznice.orders where id in ' || k);
  -- 0004 je kupac f003 i vlasnik organizatora B (f005 je na njegovom eventu)
  if v is distinct from 'f003,f005' then raise exception 'PAO TEST: 0004 vidi narudžbe %', v; end if;
  v := pg_temp.izvrsi(pg_temp.id('0003')::text, format(
    'select string_agg(right(id::text, 4), '','' order by id) from ulaznice.tickets where id in (%L, %L)',
    pg_temp.id('b001'), pg_temp.id('b002')));
  if v is distinct from 'b001,b002' then raise exception 'PAO TEST: kupac vidi ulaznice %', v; end if;
  v := pg_temp.izvrsi(pg_temp.id('0003')::text, format(
    'select count(*) from ulaznice.order_events where order_id = %L', pg_temp.id('f001')));
  if v <> '2' then raise exception 'PAO TEST: kupac vidi % audita svoje narudžbe (očekivano 2)', v; end if;
  v := pg_temp.izvrsi(pg_temp.id('0003')::text, format(
    'select count(*) from ulaznice.order_events where order_id = %L', pg_temp.id('f003')));
  if v <> '0' then raise exception 'PAO TEST: kupac vidi audit tuđe narudžbe'; end if;
  raise notice 'OK — kupac vidi svoje narudžbe, ulaznice i audit; tuđe i gostove ne';

  -- admin A (0002): sve narudžbe svog eventa, ne narudžbu eventa organizatora B
  v := pg_temp.izvrsi(pg_temp.id('0002')::text,
    'select string_agg(right(id::text, 4), '','' order by id) from ulaznice.orders where id in ' || k);
  if v is distinct from 'f001,f002,f003,f004' then raise exception 'PAO TEST: admin A vidi narudžbe %', v; end if;
  v := pg_temp.izvrsi(pg_temp.id('0002')::text, format(
    'select string_agg(right(id::text, 4), '','' order by id) from ulaznice.tickets where id in (%L, %L)',
    pg_temp.id('b001'), pg_temp.id('b002')));
  if v is distinct from 'b001' then raise exception 'PAO TEST: admin A vidi ulaznice %', v; end if;
  v := pg_temp.izvrsi(pg_temp.id('0002')::text, format(
    'select count(*) from ulaznice.order_events where event_id = %L', pg_temp.id('c001')));
  if v <> '5' then raise exception 'PAO TEST: admin A vidi % audita svog eventa (očekivano 5)', v; end if;
  -- vlasnik B (0004) vidi narudžbu svog eventa i svoju kupnju
  v := pg_temp.izvrsi(pg_temp.id('0004')::text, format(
    'select count(*) from ulaznice.orders where event_id = %L', pg_temp.id('c005')));
  if v <> '1' then raise exception 'PAO TEST: vlasnik B vidi % narudžbi svog eventa', v; end if;
  raise notice 'OK — admin organizatora vidi narudžbe, ulaznice i audit svog eventa; tuđeg ne';

  -- običan član A (0005): vidi skicu (član računa), ali ne narudžbe ni DAC7/Stripe
  v := pg_temp.izvrsi(pg_temp.id('0005')::text,
    'select count(*) from ulaznice.orders where id in ' || k);
  if v <> '0' then raise exception 'PAO TEST: običan član vidi % narudžbi', v; end if;
  v := pg_temp.izvrsi(pg_temp.id('0005')::text, format(
    'select count(*) from ulaznice.events where id in (%L, %L)', pg_temp.id('c002'), pg_temp.id('c003')));
  if v <> '1' then raise exception 'PAO TEST: član vidi % (očekivano skica da, obrisana ne)', v; end if;
  v := pg_temp.izvrsi(pg_temp.id('0005')::text, format(
    'select (select count(*) from ulaznice.organizer_records where account_id = %1$L)
          + (select count(*) from ulaznice.organizer_payment_rails where account_id = %1$L)
          + (select count(*) from ulaznice.event_access where event_id = %2$L)',
    pg_temp.id('a001'), pg_temp.id('c001')));
  if v <> '0' then raise exception 'PAO TEST: običan član vidi DAC7/Stripe/event_access (%)', v; end if;
  v := pg_temp.izvrsi(pg_temp.id('0005')::text, format(
    'select count(*) from ulaznice.organizer_allowlist where account_id = %L', pg_temp.id('a001')));
  if v <> '1' then raise exception 'PAO TEST: član ne vidi allowlist svog računa'; end if;
  raise notice 'OK — običan član: skica da, obrisana ne; narudžbe, DAC7, Stripe, event_access ne; allowlist da';

  -- admin A: DAC7, Stripe, event_access; kupac 0003 ništa od toga
  v := pg_temp.izvrsi(pg_temp.id('0002')::text, format(
    'select (select count(*) from ulaznice.organizer_records where account_id = %1$L)
          + (select count(*) from ulaznice.organizer_payment_rails where account_id = %1$L)
          + (select count(*) from ulaznice.event_access where event_id = %2$L)',
    pg_temp.id('a001'), pg_temp.id('c001')));
  if v <> '3' then raise exception 'PAO TEST: admin A vidi % od 3 (DAC7, Stripe, event_access)', v; end if;
  v := pg_temp.izvrsi(pg_temp.id('0003')::text, format(
    'select (select count(*) from ulaznice.organizer_records)
          + (select count(*) from ulaznice.organizer_payment_rails where account_id = %1$L)
          + (select count(*) from ulaznice.organizer_allowlist where account_id = %1$L)
          + (select count(*) from ulaznice.event_access where event_id = %2$L)',
    pg_temp.id('a001'), pg_temp.id('c001')));
  if v <> '0' then raise exception 'PAO TEST: kupac vidi organizer_*/event_access (%)', v; end if;
  raise notice 'OK — organizer_records/payment_rails/event_access: admin da, kupac ne';
end $$;

\echo '--- 6. events_write_guard i politike pisanja'
-- 0001: vlasnik A s KYC-om. Upis s state='active' mora postati skica.
do $$
declare e ulaznice.events;
begin
  perform pg_temp.izvrsi(pg_temp.id('0001')::text, format(
    $q$insert into ulaznice.events (id, account_id, slug, title, state, visibility, venue_name, venue_city, organizer_name)
       values (%L, %L, 'test-ulaznice-izravno', 'Izravni upis', 'active', 'public', 'Dvorana', 'Zagreb', 'Org')
       returning 1$q$, pg_temp.id('c0f1'), pg_temp.id('a001')));
  select * into e from ulaznice.events where id = pg_temp.id('c0f1');
  if e.state <> 'draft' then raise exception 'PAO TEST: authenticated insert ostavio state=%', e.state; end if;
  raise notice 'OK — events_write_guard: authenticated insert s state=active rađa se kao skica';

  perform pg_temp.izvrsi(pg_temp.id('0001')::text, format(
    $q$update ulaznice.events set account_id = %L, title = 'Izravni upis 2' where id = %L returning 1$q$,
    pg_temp.id('a002'), pg_temp.id('c0f1')));
  select * into e from ulaznice.events where id = pg_temp.id('c0f1');
  if e.account_id <> pg_temp.id('a001') or e.title <> 'Izravni upis 2' then
    raise exception 'PAO TEST: update: account_id=% title=%', e.account_id, e.title;
  end if;
  raise notice 'OK — events_write_guard: account_id se ne mijenja (title da)';
end $$;
select pg_temp.pada(pg_temp.id('0002')::text,
  format($q$insert into ulaznice.events (account_id, slug, title, venue_name, venue_city, organizer_name)
            values (%L, 'test-ulaznice-bez-kyc', 'x', 'x', 'x', 'x')$q$, pg_temp.id('a001')),
  '#42501', 'admin bez KYC-a ne stvara event');
select pg_temp.pada(pg_temp.id('0001')::text,
  format($q$insert into ulaznice.events (account_id, slug, title, venue_name, venue_city, organizer_name)
            values (%L, 'test-ulaznice-tudji-racun', 'x', 'x', 'x', 'x')$q$, pg_temp.id('a002')),
  '#42501', 'event na tuđem računu');
select pg_temp.pada(pg_temp.id('0003')::text,
  format($q$insert into ulaznice.orders (id, event_id, tier_id, amount_cents, payment_rail)
            values (gen_random_uuid(), %L, %L, 2000, 'stripe')$q$, pg_temp.id('c001'), pg_temp.id('d001')),
  '#42501', 'kupac ne piše izravno u orders');
do $$
declare v text;
begin
  -- član bez admin uloge: update eventa ne dira ništa (RLS using)
  v := pg_temp.izvrsi(pg_temp.id('0005')::text, format(
    $q$with u as (update ulaznice.events set title = 'Član mijenja' where id = %L returning 1)
       select count(*) from u$q$, pg_temp.id('c001')));
  if v <> '0' then raise exception 'PAO TEST: običan član je promijenio event'; end if;
  raise notice 'OK — običan član ne mijenja event';
end $$;

-- ── 7. bucket ulaznice-media ────────────────────────────────────────────────
\echo '--- 7. bucket ulaznice-media'
do $$
declare b storage.buckets; p storage.buckets; n integer;
begin
  select * into b from storage.buckets where id = 'ulaznice-media';
  select * into p from storage.buckets where id = 'pinka-covers';
  if b.id is null then raise exception 'PAO TEST: nema bucketa ulaznice-media'; end if;
  if not b.public or b.file_size_limit <> 5242880 then
    raise exception 'PAO TEST: ulaznice-media public=% limit=%', b.public, b.file_size_limit;
  end if;
  if b.allowed_mime_types is distinct from p.allowed_mime_types
     or b.file_size_limit is distinct from p.file_size_limit or b.public is distinct from p.public then
    raise exception 'PAO TEST: ulaznice-media (% %) ≠ pinka-covers (% %)',
      b.file_size_limit, b.allowed_mime_types, p.file_size_limit, p.allowed_mime_types;
  end if;
  raise notice 'OK — ulaznice-media: javan, 5 MB, MIME % (jednako pinka-covers)', b.allowed_mime_types;

  -- politike: iste kao pinka_covers_* do na ime bucketa
  select count(*) into n
    from pg_policies u
    join pg_policies c on c.schemaname = 'storage' and c.tablename = 'objects'
                      and c.policyname = replace(u.policyname, 'ulaznice_media_', 'pinka_covers_')
   where u.schemaname = 'storage' and u.tablename = 'objects' and u.policyname like 'ulaznice_media_%'
     and u.cmd = c.cmd and u.roles = c.roles and u.permissive = c.permissive
     and coalesce(u.qual, '') = replace(coalesce(c.qual, ''), 'pinka-covers', 'ulaznice-media')
     and coalesce(u.with_check, '') = replace(coalesce(c.with_check, ''), 'pinka-covers', 'ulaznice-media');
  if n <> 3 then raise exception 'PAO TEST: % od 3 politika ulaznice_media_* jednako pinka_covers_*', n; end if;
  if (select count(*) from pg_policies where schemaname = 'storage' and tablename = 'objects'
        and policyname like 'ulaznice_media_%') <> 3 then
    raise exception 'PAO TEST: višak politika ulaznice_media_*';
  end if;
  raise notice 'OK — politike insert/update/delete jednake pinka-covers (vlastita mapa, insert uz KYC)';
end $$;
-- RLS na storage.objects izvediv je u SQL-u: upis se poništava, u storageu ne ostaje ništa.
select pg_temp.pada(pg_temp.id('0001')::text,
  format($q$insert into storage.objects (bucket_id, name) values ('ulaznice-media', %L)$q$,
         pg_temp.id('0002')::text || '/tudja.jpg'),
  '#42501', 'storage: upis u tuđu mapu');
select pg_temp.pada(pg_temp.id('0002')::text,
  format($q$insert into storage.objects (bucket_id, name) values ('ulaznice-media', %L)$q$,
         pg_temp.id('0002')::text || '/bez-kyc.jpg'),
  '#42501', 'storage: upis u svoju mapu bez provjerenog identiteta');
select pg_temp.pada('anon',
  format($q$insert into storage.objects (bucket_id, name) values ('ulaznice-media', %L)$q$,
         pg_temp.id('0001')::text || '/anon.jpg'),
  '#42501', 'storage: anon upis');
select pg_temp.prolazi(pg_temp.id('0001')::text,
  format($q$insert into storage.objects (bucket_id, name) values ('ulaznice-media', %L)$q$,
         pg_temp.id('0001')::text || '/cover.jpg'),
  'storage: upis u svoju mapu s provjerenim identitetom');

do $$ begin raise notice 'SVE PROVJERE PROŠLE'; end $$;
