#!/usr/bin/env bash
# =============================================================================
# Ulaznice S2/S3: probni prolaz migracija 20261125150000/150100/150200/160000 nad podacima
# pinka_finance, LOKALNO (docs/ulaznice-shema/, docs/migration-testing-playbook.md).
#
# Ne radi ništa prema produkciji: nema ssh-a, nema remote psql-a, čita samo
# lokalnu datoteku dumpa i piše samo u lokalni Supabase stack (127.0.0.1:55322).
# RESETIRA LOKALNU BAZU (supabase db reset).
#
# Usage:
#   scripts/ulaznice-prod-dump-test.sh <dump.sql>   # dump S PODACIMA pinka_finance
#   scripts/ulaznice-prod-dump-test.sh --prod-oblik # bez dumpa: fixture po
#                                                  # brojevima inventure §2
#
# Dump s podacima nastaje s `./scripts/db-dump.sh --schemas pinka_finance --data`
# (to čita produkciju i NIJE dio ove skripte). `pre-migrate-*.sql` iz
# db-migrate.sh su schema-only i ovdje se odbijaju.
#
# Postupak:
#   1. supabase db reset --no-seed --version 20261125120000 (stanje prije S2)
#   2. podaci: COPY blokovi pinka_finance.* iz dumpa uz
#      session_replication_role=replica (bez trigera i FK provjera, kao restore),
#      zatim STUB redci za auth.users / public.accounts koje podaci referenciraju
#      (dump pinka_finance ne nosi račune; nove FK-ove ulaznice → public.accounts
#      migracija provjerava normalno). Ili: fixture --prod-oblik.
#   3. tri migracije kao scripts/db-migrate.sh (single transaction + red u
#      supabase_migrations.schema_migrations), pa kopija još jednom (idempotencija)
#   4. brojevi i provjere; u --prod-oblik načinu i usporedba s očekivanim.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DB_URL="${LOCAL_DB_URL:-postgresql://postgres:postgres@127.0.0.1:55322/postgres}"
case "$DB_URL" in
  *@127.0.0.1:*|*@localhost:*) ;;
  *) echo "✗ DB_URL nije lokalan ($DB_URL) — odbijam." >&2; exit 2 ;;
esac

MODE="${1:-}"
DUMP=""
if [[ "$MODE" == "--prod-oblik" ]]; then
  :
elif [[ -n "$MODE" && -f "$MODE" ]]; then
  DUMP="$MODE"
  n=$(grep -c '^COPY pinka_finance\.' "$DUMP" || true)
  if [[ "$n" -eq 0 ]]; then
    echo "✗ $DUMP nema podataka pinka_finance (0 redaka '^COPY pinka_finance.') — schema-only dump." >&2
    echo "  Treba dump s --data ili --prod-oblik." >&2
    exit 3
  fi
  echo "→ dump: $DUMP ($n COPY blokova pinka_finance)"
else
  sed -n '10,14p' "$0" >&2
  exit 2
fi

export PGOPTIONS="-c client_min_messages=warning"
PSQL=(psql "$DB_URL" -X -q -v ON_ERROR_STOP=1)
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
MIG="$REPO_ROOT/supabase/migrations"
NOVE=(20261125150000_ulaznice_shema 20261125150100_ulaznice_media_bucket 20261125150200_ulaznice_kopija_podataka 20261125160000_ulaznice_rpc_narudzbe 20261125170000_ulaznice_rpc_eventi)

echo "→ 1. supabase db reset --no-seed --version 20261125120000"
(cd "$REPO_ROOT" && supabase db reset --no-seed --version 20261125120000 >"$TMP/reset.log" 2>&1) || {
  tail -20 "$TMP/reset.log" >&2; exit 1; }

echo "→ 2. podaci pinka_finance"
if [[ -n "$DUMP" ]]; then
  {
    echo "set session_replication_role = replica;"
    awk '/^COPY pinka_finance\./{p=1} p{print} p&&/^\\\.$/{p=0}' "$DUMP"
  } >"$TMP/data.sql"
  "${PSQL[@]}" --single-transaction -f "$TMP/data.sql"
  # STUB-ovi: jedan stub vlasnik, račun po referenciranom account_id, korisnik
  # po referenciranom user id. Pod replica nema handle_new_user ni drugih trigera.
  "${PSQL[@]}" --single-transaction <<'SQL'
set session_replication_role = replica;
insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
select u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       'stub-' || left(u::text, 8) || '@stub.invalid', now(), now()
  from (select created_by from pinka_finance.organizer_allowlist
        union select checked_in_by from pinka_finance.tickets
        union select '00000000-0000-4000-8000-00000057b000'::uuid) s(u)
 where u is not null
on conflict (id) do nothing;
insert into public.accounts (id, primary_owner_user_id, is_personal_account, slug, name)
select a, '00000000-0000-4000-8000-00000057b000', false, 'stub-' || left(md5(a::text), 12), 'stub'
  from (select account_id from pinka_finance.campaigns
        union select contributor_account_id from pinka_finance.contributions
        union select account_id from pinka_finance.organizer_allowlist
        union select account_id from pinka_finance.organizer_records
        union select account_id from pinka_finance.organizer_payment_rails) s(a)
 where a is not null
on conflict (id) do nothing;
SQL
else
  "${PSQL[@]}" --single-transaction <<'SQL'
-- Fixture po inventuri §2 (2026-11-25): tickets 4 (active/public 1, draft 1,
-- obrisana skica 2), tierova 6, narudžbe paid/stripe 1 (40 €) + expired/onchain
-- 2 (65 €), ulaznica 1, event_access 1, organizer_payment_rails 1,
-- contribution_events ticket narudžbi 7; donation 1 kampanja / 70 doprinosa,
-- crowdfund 1 / 1. Covers: 2 eventa s coverom u pinka-covers, 3 slike galerije.
create function pg_temp.id(p text) returns uuid language sql as $$
  select ('00000000-0000-4000-8000-0000005' || p)::uuid $$;
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
                        created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
select pg_temp.id(n), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       'prod-oblik-' || n || '@example.com', '', now(), now(), now(), '{}', '{}'
  from unnest(array['7b001', '7b002']) n;
insert into public.accounts (id, primary_owner_user_id, is_personal_account, slug, name)
values (pg_temp.id('7a001'), pg_temp.id('7b001'), false, 'prod-oblik-org', 'Prod oblik org');
create function pg_temp.kupac() returns uuid language sql as $$
  select id from public.accounts where primary_owner_user_id = pg_temp.id('7b002') and is_personal_account $$;

insert into pinka_finance.campaigns (id, account_id, slug, type, title, subject_type, min_contribution_cents,
                                     currency, destination_address, chain, state, visibility, deleted_at, cover_image_url)
select pg_temp.id(v.id), pg_temp.id('7a001'), v.slug, v.t::pinka_finance.campaign_type, v.slug, 'event', 100, 'eur',
       '0x0000000000000000000000000000000000000000', 'gnosis', v.s::pinka_finance.campaign_state,
       v.vis::pinka_finance.campaign_visibility, case when v.del then now() end, v.cover
  from (values
    ('7c001', 'po-aktivan',   'tickets',   'active', 'public',  false, 'https://api.domovina.ai/storage/v1/object/public/pinka-covers/u1/a.jpg'),
    ('7c002', 'po-skica',     'tickets',   'draft',  'private', false, 'https://api.domovina.ai/storage/v1/object/public/pinka-covers/u1/b.png'),
    ('7c003', 'po-obrisana1', 'tickets',   'draft',  'private', true,  null),
    ('7c004', 'po-obrisana2', 'tickets',   'draft',  'private', true,  null),
    ('7c0d0', 'po-donacija',  'donation',  'active', 'public',  false, null),
    ('7c0c0', 'po-crowdfund', 'crowdfund', 'active', 'public',  false, null)) v(id, slug, t, s, vis, del, cover);
insert into pinka_finance.events (campaign_id, event_type, venue_name, venue_city, organizer_name, cover_image_url, gallery)
select pg_temp.id(v.id), 'koncert', 'Dvorana', 'Zagreb', 'Org', v.cover, v.gal::jsonb
  from (values
    ('7c001', 'https://api.domovina.ai/storage/v1/object/public/pinka-covers/u1/a.jpg',
     '[{"url":"https://api.domovina.ai/storage/v1/object/public/pinka-covers/u1/g1.jpg"},
       {"url":"https://api.domovina.ai/storage/v1/object/public/pinka-covers/u1/g2.jpg","alt":"x"}]'),
    ('7c002', 'https://api.domovina.ai/storage/v1/object/public/pinka-covers/u1/b.png',
     '[{"url":"https://api.domovina.ai/storage/v1/object/public/pinka-covers/u1/g3.webp"}]'),
    ('7c003', null, '[]'), ('7c004', null, '[]')) v(id, cover, gal);
insert into pinka_finance.campaign_tiers (id, campaign_id, title, price_cents, kind, sort)
select pg_temp.id(v.id), pg_temp.id(v.c), v.id, v.p, 'ticket', 0
  from (values ('7d001', '7c001', 2000), ('7d002', '7c001', 2500), ('7d003', '7c002', 1000),
               ('7d004', '7c002', 0), ('7d005', '7c003', 500), ('7d006', '7c004', 500)) v(id, c, p);
insert into pinka_finance.contributions (id, campaign_id, tier_id, contributor_account_id, amount_cents, currency,
                                         quantity, state, destination_address, payment_rail, external_payment_ref,
                                         reserved, paid_at)
values (pg_temp.id('7f001'), pg_temp.id('7c001'), pg_temp.id('7d001'), pg_temp.kupac(), 4000, 'eur', 2, 'paid',
        '0x0000000000000000000000000000000000000000', 'stripe', 'pi_prodoblik001', true, now()),
       (pg_temp.id('7f002'), pg_temp.id('7c001'), pg_temp.id('7d002'), null, 2500, 'eur', 1, 'expired',
        '0x0000000000000000000000000000000000000000', 'onchain', null, true, null),
       (pg_temp.id('7f003'), pg_temp.id('7c001'), pg_temp.id('7d001'), null, 4000, 'eur', 2, 'expired',
        '0x0000000000000000000000000000000000000000', 'onchain', null, true, null);
insert into pinka_finance.contributions (campaign_id, amount_cents, currency, state, destination_address, paid_at)
select pg_temp.id('7c0d0'), 500 + g, 'eur', 'paid', '0x0000000000000000000000000000000000000000', now()
  from generate_series(1, 70) g;
insert into pinka_finance.contributions (campaign_id, amount_cents, currency, state, destination_address, paid_at)
values (pg_temp.id('7c0c0'), 10000, 'eur', 'paid', '0x0000000000000000000000000000000000000000', now());
-- 3 'contribution.created' dolaze iz trigera; još 4 da ih bude 7
insert into pinka_finance.contribution_events (contribution_id, campaign_id, event_type, payload)
values (pg_temp.id('7f001'), pg_temp.id('7c001'), 'contribution.paid', '{}'),
       (pg_temp.id('7f001'), pg_temp.id('7c001'), 'ticket.issued', '{}'),
       (pg_temp.id('7f002'), pg_temp.id('7c001'), 'contribution.expired', '{}'),
       (pg_temp.id('7f003'), pg_temp.id('7c001'), 'contribution.expired', '{}');
insert into pinka_finance.tickets (contribution_id, campaign_id, tier_id, serial, qr_token_hash)
values (pg_temp.id('7f001'), pg_temp.id('7c001'), pg_temp.id('7d001'), 'PO-000001',
        encode(sha256('prod-oblik'::bytea), 'hex'));
insert into pinka_finance.event_access (campaign_id, online_url)
values (pg_temp.id('7c001'), 'https://meet.example.test/x');
insert into pinka_finance.organizer_payment_rails (account_id, stripe_account_id)
values (pg_temp.id('7a001'), 'acct_prodOblik');
SQL
fi

# izvor prije migracija (nikad se ne smije promijeniti)
SRC_Q="select (select count(*) from pinka_finance.campaigns) || '/' ||
              (select count(*) from pinka_finance.contributions) || '/' ||
              (select count(*) from pinka_finance.contribution_events) || '/' ||
              (select count(*) from pinka_finance.events) || '/' ||
              (select md5(string_agg(coalesce(cover_image_url, '-') || gallery::text, ',' order by campaign_id)) from pinka_finance.events)"
SRC_PRIJE=$("${PSQL[@]}" -At -c "$SRC_Q")

echo "→ 3. migracije (kao db-migrate.sh), pa kopija još jednom"
for m in "${NOVE[@]}"; do
  {
    echo "begin;"
    cat "$MIG/$m.sql"
    echo ""
    echo "insert into supabase_migrations.schema_migrations (version, name) values ('${m%%_*}', '${m#*_}');"
    echo "commit;"
  } >"$TMP/m.sql"
  "${PSQL[@]}" -At -f "$TMP/m.sql" >"$TMP/out.txt"
  grep -E '^OK ' "$TMP/out.txt" | sed 's/^/  /'
done
"${PSQL[@]}" -At --single-transaction -f "$MIG/20261125150200_ulaznice_kopija_podataka.sql" >"$TMP/out.txt"
grep -E '^OK ' "$TMP/out.txt" | sed 's/^/  (drugi prolaz) /'

echo "→ 4. brojevi"
"${PSQL[@]}" -P footer=off <<'SQL'
with t as (select c.id from pinka_finance.campaigns c where c.type = 'tickets')
select 'events' tablica, (select count(*) from ulaznice.events) ulaznice,
       (select count(*) from t) izvor
union all select 'ticket_tiers', (select count(*) from ulaznice.ticket_tiers),
       (select count(*) from pinka_finance.campaign_tiers where campaign_id in (select id from t))
union all select 'orders', (select count(*) from ulaznice.orders),
       (select count(*) from pinka_finance.contributions where campaign_id in (select id from t))
union all select 'tickets', (select count(*) from ulaznice.tickets),
       (select count(*) from pinka_finance.tickets where campaign_id in (select id from t))
union all select 'event_access', (select count(*) from ulaznice.event_access),
       (select count(*) from pinka_finance.event_access where campaign_id in (select id from t))
union all select 'organizer_payment_rails', (select count(*) from ulaznice.organizer_payment_rails),
       (select count(*) from pinka_finance.organizer_payment_rails)
union all select 'organizer_records', (select count(*) from ulaznice.organizer_records),
       (select count(*) from pinka_finance.organizer_records)
union all select 'organizer_allowlist', (select count(*) from ulaznice.organizer_allowlist),
       (select count(*) from pinka_finance.organizer_allowlist)
union all select 'order_events', (select count(*) from ulaznice.order_events),
       (select count(*) from pinka_finance.contribution_events where campaign_id in (select id from t));

select state || '/' || payment_rail as narudzbe, count(*), sum(amount_cents) from ulaznice.orders group by 1 order by 1;
select state || '/' || visibility || case when deleted_at is not null then '/obrisan' else '' end as eventi, count(*)
  from ulaznice.events group by 1 order by 1;
SQL

FAIL=0
check() { # opis, upit koji vraća 0 kad je u redu
  local v; v=$("${PSQL[@]}" -At -c "$2")
  if [[ "$v" == "0" ]]; then echo "  OK — $1"; else echo "  ✗ $1 ($v)"; FAIL=1; fi
}
echo "→ 5. provjere"
check "isti ID-jevi: eventi"     "select count(*) from pinka_finance.campaigns c where c.type='tickets' and not exists (select 1 from ulaznice.events e where e.id=c.id and e.slug=c.slug and e.account_id=c.account_id)"
check "isti ID-jevi: tierovi"    "select count(*) from pinka_finance.campaign_tiers t join pinka_finance.campaigns c on c.id=t.campaign_id and c.type='tickets' where not exists (select 1 from ulaznice.ticket_tiers u where u.id=t.id and u.event_id=t.campaign_id and u.price_cents=t.price_cents and u.inventory_claimed=t.inventory_claimed)"
check "isti ID-jevi: narudžbe"   "select count(*) from pinka_finance.contributions t join pinka_finance.campaigns c on c.id=t.campaign_id and c.type='tickets' where not exists (select 1 from ulaznice.orders u where u.id=t.id and u.event_id=t.campaign_id and u.tier_id=t.tier_id and u.amount_cents=t.amount_cents and u.state=t.state::text and u.external_payment_ref is not distinct from t.external_payment_ref)"
check "isti ID-jevi: ulaznice"   "select count(*) from pinka_finance.tickets t join pinka_finance.campaigns c on c.id=t.campaign_id and c.type='tickets' where not exists (select 1 from ulaznice.tickets u where u.id=t.id and u.order_id=t.contribution_id and u.qr_token_hash=t.qr_token_hash and u.serial=t.serial)"
check "isti ID-jevi: audit"      "select count(*) from pinka_finance.contribution_events t join pinka_finance.campaigns c on c.id=t.campaign_id and c.type='tickets' where not exists (select 1 from ulaznice.order_events u where u.id=t.id and u.order_id=t.contribution_id and u.event_type=t.event_type and u.created_at=t.created_at)"
check "bez ostataka pinka-covers u ulaznice.events" "select count(*) from ulaznice.events where cover_image_url like '%/pinka-covers/%' or gallery::text like '%/pinka-covers/%'"
check "donacije/crowdfund nisu u ulaznice" "select count(*) from ulaznice.events e join pinka_finance.campaigns c on c.id=e.id where c.type<>'tickets'"
SRC_POSLIJE=$("${PSQL[@]}" -At -c "$SRC_Q")
if [[ "$SRC_PRIJE" == "$SRC_POSLIJE" ]]; then echo "  OK — pinka_finance netaknut (kampanje/doprinosi/audit/eventi/URL-ovi: $SRC_POSLIJE)"
else echo "  ✗ pinka_finance promijenjen: $SRC_PRIJE → $SRC_POSLIJE"; FAIL=1; fi
URL=$("${PSQL[@]}" -At -c "select (select count(*) from ulaznice.events where cover_image_url like '%/public/ulaznice-media/%') || ' cover, ' ||
  (select count(*) from ulaznice.events e, jsonb_array_elements(e.gallery) g where g->>'url' like '%/public/ulaznice-media/%') || ' galerija'")
echo "  URL-ovi prepisani na ulaznice-media: $URL"

if [[ -z "$DUMP" ]]; then
  OCEK="4|6|3|1|1|1|0|0|7|2 cover, 3 galerija|expired/onchain:2,paid/stripe:1"
  STV=$("${PSQL[@]}" -At -c "select concat_ws('|', (select count(*) from ulaznice.events), (select count(*) from ulaznice.ticket_tiers),
    (select count(*) from ulaznice.orders), (select count(*) from ulaznice.tickets), (select count(*) from ulaznice.event_access),
    (select count(*) from ulaznice.organizer_payment_rails), (select count(*) from ulaznice.organizer_records),
    (select count(*) from ulaznice.organizer_allowlist), (select count(*) from ulaznice.order_events), '$URL',
    (select string_agg(k || ':' || n, ',' order by k) from (select state || '/' || payment_rail k, count(*) n from ulaznice.orders group by 1) x))")
  if [[ "$STV" == "$OCEK" ]]; then echo "  OK — brojevi = inventura §2 ($STV)"
  else echo "  ✗ brojevi $STV, očekivano $OCEK"; FAIL=1; fi
fi

if [[ $FAIL -eq 0 ]]; then echo "✓ SVE PROVJERE PROŠLE"; else echo "✗ PROVJERE PALE"; exit 1; fi
echo "Lokalna baza je sada na zadnjoj migraciji s ovim podacima; za čisto stanje: supabase db reset --no-seed"
