#!/usr/bin/env bash
# =============================================================================
# Ulaznice: izvršni curl scenarij edge funkcija events-* nad shemom `ulaznice`,
# LOKALNO. Izvodi docs/events-ticketing-curl-scenario.md (§1–§11) redom.
#
# Ne radi ništa prema produkciji ni prema Stripeu: zove samo lokalni stack
# (API 127.0.0.1:55321, DB 127.0.0.1:55322). Ne ovisi o seedu: sve fixture
# (korisnike kroz GoTrue admin API, org račune, KYC, allowlistu, Stripe rail)
# stvara sama, s jedinstvenim sufiksom po prolazu. Na početku briše fixture
# prethodnih prolaza (sve s prefiksom `ulz-scen-`), pa je ponovljiva.
#
# Pretpostavlja da edge funkcije rade (`supabase start` ih servira; ili
# `supabase functions serve` u drugom terminalu) i da imaju
# EVENTS_STRIPE_CONFIRM_SECRET iz supabase/functions/.env (gitignored).
# Tajnu skripta čita iz okoline ili iz te datoteke i nikad je ne ispisuje.
#
# Usage:  bash scripts/ulaznice-curl-scenario.sh
#         VERBOSE=1 bash scripts/ulaznice-curl-scenario.sh   # ispiši i tijela odgovora
#
# Ishod: svaka provjera ispisuje "OK — <opis>"; prva neuspjela ispisuje što je
# dobila i izlazi s kodom 1. Na kraju "SVE PROVJERE PROŠLE (N provjera)".
# Ovisnosti: curl, jq, psql, openssl, supabase CLI.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DB_URL="${LOCAL_DB_URL:-postgresql://postgres:postgres@127.0.0.1:55322/postgres}"
API="${LOCAL_API_URL:-http://127.0.0.1:55321}"
case "$DB_URL $API" in
  *@127.0.0.1:*127.0.0.1:*|*@localhost:*localhost:*) ;;
  *) echo "✗ DB_URL/API nisu lokalni ($DB_URL, $API) — odbijam." >&2; exit 2 ;;
esac
FN="$API/functions/v1"
VERBOSE="${VERBOSE:-0}"

for bin in curl jq psql openssl supabase; do
  command -v "$bin" >/dev/null || { echo "✗ nedostaje $bin" >&2; exit 2; }
done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ulz-scen.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# ── pomoćnici ────────────────────────────────────────────────────────────────
N_OK=0
CODE=""
BODY=""

fail() {
  echo "✗ PALO: $1" >&2
  [ -n "${2:-}" ] && echo "  dobiveno: $2" >&2
  exit 1
}
ok() { N_OK=$((N_OK + 1)); echo "OK — $1"; }

# psql: jedna vrijednost (zadnji redak), greška = kraj skripte
q() { psql "$DB_URL" -X -Atq -v ON_ERROR_STOP=1 -c "$1" | tail -n 1; }
# psql koji SMIJE pasti: ispis stderr+stdout, exit 0
q_err() { psql "$DB_URL" -X -Atq -v ON_ERROR_STOP=1 -c "$1" 2>&1 || true; }

# req METHOD URL [Authorization-vrijednost|""] [tijelo|""] [header ...]
req() {
  local method="$1" url="$2" auth="${3:-}" data="${4:-}"
  shift 4 2>/dev/null || shift $#
  local args=(-s -m 60 -o "$TMP/body" -w '%{http_code}' -X "$method" "$url")
  [ -n "$auth" ] && args+=(-H "Authorization: $auth")
  local h
  for h in "$@"; do args+=(-H "$h"); done
  [ -n "$data" ] && args+=(-H 'content-type: application/json' --data-binary "$data")
  CODE="$(curl "${args[@]}")" || CODE="000"
  BODY="$(cat "$TMP/body" 2>/dev/null || true)"
  [ "$VERBOSE" = "1" ] && echo "    $method ${url#"$API"} → $CODE $BODY" >&2
  return 0
}
# PostgREST nad shemom ulaznice: rest METHOD putanja ključ [JWT|""] [tijelo]
rest() {
  local method="$1" path="$2" key="$3" jwt="${4:-}" data="${5:-}"
  local prof="Accept-Profile: ulaznice"
  [ "$method" = "POST" ] && prof="Content-Profile: ulaznice"
  req "$method" "$API/rest/v1/$path" "${jwt:+Bearer $jwt}" "$data" "apikey: $key" "$prof"
}

# HMAC potpis nad sirovim tijelom (kao Worker domovina-ulaznice)
sign() { printf '%s' "$1" | openssl dgst -sha256 -hmac "$SECRET" -hex | sed 's/^.*= //'; }
# spost URL tijelo — potpisan POST
spost() { req POST "$1" "" "$2" "x-ulaznice-signature: sha256=$(sign "$2")"; }

# expect HTTP_KOD 'jq filter koji vraća true' 'opis'
expect() {
  local code="$1" filter="$2" desc="$3"
  [ "$CODE" = "$code" ] || fail "$desc (HTTP $CODE, očekivano $code)" "$BODY"
  if [ -n "$filter" ]; then
    local r
    r="$(printf '%s' "$BODY" | jq -e "$filter" 2>/dev/null)" || fail "$desc (uvjet: $filter)" "$BODY"
    [ "$r" = "true" ] || fail "$desc (uvjet: $filter → $r)" "$BODY"
  fi
  ok "$desc"
}

# expect_sql 'sql' 'očekivano' 'opis'
expect_sql() {
  local got
  got="$(q "$1")"
  [ "$got" = "$2" ] || fail "$3 (SQL: $1; očekivano: $2)" "$got"
  ok "$3"
}

# expect_sql_err 'sql' 'dio poruke' 'opis'
expect_sql_err() {
  local got
  got="$(q_err "$1")"
  case "$got" in
    *"$2"*) ok "$3" ;;
    *) fail "$3 (SQL: $1; očekivana greška: $2)" "$got" ;;
  esac
}

uuid() { uuidgen 2>/dev/null | tr 'A-Z' 'a-z' || cat /proc/sys/kernel/random/uuid; }

# ── 0. okruženje ─────────────────────────────────────────────────────────────
echo "== 0. okruženje"
cd "$REPO_ROOT"
STATUS_ENV="$(supabase status -o env 2>/dev/null)" || { echo "✗ lokalni stack ne radi: supabase start" >&2; exit 2; }
ANON="$(printf '%s\n' "$STATUS_ENV" | sed -n 's/^ANON_KEY="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p')"
SERVICE="$(printf '%s\n' "$STATUS_ENV" | sed -n 's/^SERVICE_ROLE_KEY="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p')"
[ -n "$ANON" ] && [ -n "$SERVICE" ] || { echo "✗ nema ANON_KEY/SERVICE_ROLE_KEY u supabase status" >&2; exit 2; }

SECRET="${EVENTS_STRIPE_CONFIRM_SECRET:-}"
if [ -z "$SECRET" ] && [ -f supabase/functions/.env ]; then
  SECRET="$(sed -n 's/^EVENTS_STRIPE_CONFIRM_SECRET=//p' supabase/functions/.env | tail -n 1 | tr -d '"' | tr -d "'")"
fi
[ -n "$SECRET" ] || { echo "✗ EVENTS_STRIPE_CONFIRM_SECRET nije postavljen (env ili supabase/functions/.env)" >&2; exit 2; }

req POST "$FN/events-confirm" "" '{}'
if [ "$CODE" = "000" ] || [ "$CODE" = "502" ] || [ "$CODE" = "503" ] || [ "$CODE" = "404" ]; then
  echo "✗ edge funkcije ne odgovaraju na $FN (HTTP $CODE)." >&2
  echo "  Pokreni ih: supabase start (servira functions) ili supabase functions serve." >&2
  exit 2
fi
q "select 1 from information_schema.schemata where schema_name = 'ulaznice'" | grep -q 1 \
  || { echo "✗ shema ulaznice ne postoji (migracije 20261125150000–170000)" >&2; exit 2; }

# tajna na serveru = tajna ovdje? (ispravan potpis na neispravnom tijelu → 400, ne 401)
spost "$FN/events-stripe-confirm" '{"order_id":"x"}'
[ "$CODE" = "400" ] || { echo "✗ events-stripe-confirm ne prihvaća potpis lokalne tajne (HTTP $CODE $BODY) — tajna u serveu i u supabase/functions/.env se razlikuju?" >&2; exit 2; }

# čišćenje fixtura prethodnih prolaza (samo prefiks ulz-scen-)
# (redoslijed: članstva pa activity_events pa računi — trigger log_membership_event
#  inače piše member.removed s FK-om na račun koji se upravo briše)
q "begin;
   create temp table ulz_scen_ids on commit drop as
     select id from public.accounts
      where slug like 'ulz-scen-%'
         or primary_owner_user_id in (select id from auth.users where email like 'ulz-scen-%@example.test');
   delete from public.accounts_memberships where account_id in (select id from ulz_scen_ids);
   delete from public.activity_events where target_account_id in (select id from ulz_scen_ids);
   delete from public.accounts where id in (select id from ulz_scen_ids);
   delete from public.identity_verifications where oib_hash like 'ulz-scen-%';
   delete from auth.users where email like 'ulz-scen-%@example.test';
   commit;" >/dev/null
ok "stack, ključevi, edge funkcije, HMAC tajna; stare fixture obrisane"

RUN="$(openssl rand -hex 4)"
CITY="Scenarijgrad-$RUN"
PW="Scenarij-$RUN-Lozinka!"
FAR="$(q "select to_char((now() + interval '60 days') at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:00:00\"Z\"')")"
FAR_END="$(q "select to_char((now() + interval '61 days') at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:00:00\"Z\"')")"
NEAR="$(q "select to_char((now() + interval '20 days') at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:00:00\"Z\"')")"
NEAR_END="$(q "select to_char((now() + interval '21 days') at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:00:00\"Z\"')")"
echo "   prolaz $RUN, grad $CITY"

# ── 1. priprema ──────────────────────────────────────────────────────────────
echo "== 1. priprema: korisnici, org račun, KYC, allowlist, Stripe rail, create_event, publish"

new_user() { # email → id
  req POST "$API/auth/v1/admin/users" "Bearer $SERVICE" \
    "{\"email\":\"$1\",\"password\":\"$PW\",\"email_confirm\":true}" "apikey: $SERVICE"
  [ "$CODE" = "200" ] || fail "GoTrue admin: korisnik $1 (HTTP $CODE)" "$BODY"
  printf '%s' "$BODY" | jq -r .id
}
login() { # email → access_token
  req POST "$API/auth/v1/token?grant_type=password" "" \
    "{\"email\":\"$1\",\"password\":\"$PW\"}" "apikey: $ANON"
  [ "$CODE" = "200" ] || fail "GoTrue login $1 (HTTP $CODE)" "$BODY"
  printf '%s' "$BODY" | jq -r .access_token
}

ADMIN_EMAIL="ulz-scen-$RUN-admin@example.test"
CLAN_EMAIL="ulz-scen-$RUN-clan@example.test"
ADMIN_ID="$(new_user "$ADMIN_EMAIL")"
CLAN_ID="$(new_user "$CLAN_EMAIL")"
ADMIN_JWT="$(login "$ADMIN_EMAIL")"
CLAN_JWT="$(login "$CLAN_EMAIL")"
ok "GoTrue: admin i običan član stvoreni, JWT-ovi dobiveni"

ORG="$(uuid)"    # glavni organizator: allowlist + Stripe Connect
ORG2="$(uuid)"   # organizator za §9: na početku bez allowliste i bez raila
ACCT="acct_1Scen${RUN}"
q "insert into public.accounts (id, primary_owner_user_id, is_personal_account, slug, name)
   values ('$ORG',  '$ADMIN_ID', false, 'ulz-scen-$RUN-org',  'Scenarij org $RUN'),
          ('$ORG2', '$ADMIN_ID', false, 'ulz-scen-$RUN-org2', 'Scenarij org2 $RUN');
   insert into public.accounts_memberships (account_id, user_id, account_role)
   values ('$ORG', '$ADMIN_ID', 'owner'), ('$ORG2', '$ADMIN_ID', 'owner'), ('$ORG', '$CLAN_ID', 'member')
   on conflict (account_id, user_id) do update set account_role = excluded.account_role;
   insert into public.identity_verifications (user_id, oib_ciphertext, oib_hash)
   values ('$ADMIN_ID', '\\x00'::bytea, 'ulz-scen-$RUN-admin'),
          ('$CLAN_ID',  '\\x00'::bytea, 'ulz-scen-$RUN-clan');
   insert into ulaznice.organizer_allowlist (account_id, note) values ('$ORG', 'curl scenarij $RUN');
   insert into ulaznice.organizer_payment_rails
     (account_id, stripe_account_id, stripe_charges_enabled, stripe_payouts_enabled, invoice_provider)
   values ('$ORG', '$ACCT', true, true, 'fira');" >/dev/null
ok "psql: 2 org računa, članstva, KYC, allowlist i Stripe rail za ORG"

EV="$(uuid)"
EV_BODY='{"action":"create","event_id":"'$EV'","account_id":"'$ORG'",
  "title":"Money Motion '$RUN' (test)","venue_name":"Zagrebački velesajam","venue_city":"'$CITY'",
  "event_type":"konferencija","starts_at":"'$FAR'","ends_at":"'$FAR_END'",
  "description_hr":"Testni event","organizer_name":"Money Motion","organizer_email":"tickets@example.test",
  "tiers":[
    {"title":"Super Early Bird","price_cents":14900,"inventory_total":3,"imenska":true},
    {"title":"Studentska","price_cents":4900,"inventory_total":100,"imenska":true,"sale_end":"2026-01-01T00:00:00Z"},
    {"title":"Besplatna","price_cents":0,"inventory_total":50,"imenska":false},
    {"title":"Mala","price_cents":1000,"inventory_total":1,"imenska":false},
    {"title":"Redovna","price_cents":14900,"inventory_total":20,"imenska":true}
  ]}'
req POST "$FN/events-organizer" "Bearer $ADMIN_JWT" "$EV_BODY"
expect 200 '.id == "'$EV'" and .existing == false and .event_created == true' "create_event (events-organizer create): nova skica"
SLUG="$(printf '%s' "$BODY" | jq -r .slug)"
req POST "$FN/events-organizer" "Bearer $ADMIN_JWT" "$EV_BODY"
expect 200 '.existing == true and .event_created == false' "create_event idempotencija: isti event_id → existing"
expect_sql "select state || '|' || visibility from ulaznice.events where id = '$EV'" "draft|private" "event je skica + private"

req POST "$FN/events-organizer" "Bearer $ADMIN_JWT" '{"action":"publish","campaign_id":"'$EV'"}'
expect 200 '.state == "active" and .visibility == "public"' "publish (allowlist + Stripe rail) → active/public"

tier() { q "select id from ulaznice.ticket_tiers where event_id = '$EV' and title = '$1'"; }
T_SEB="$(tier 'Super Early Bird')"; T_STUD="$(tier 'Studentska')"; T_FREE="$(tier 'Besplatna')"
T_MALA="$(tier 'Mala')"; T_RED="$(tier 'Redovna')"

# ── 2. feed ──────────────────────────────────────────────────────────────────
echo "== 2. feed"
req GET "$FN/events-feed?grad=$CITY"
expect 200 '.events | length == 1 and .[0].campaign_id == "'$EV'" and .[0].slug == "'$SLUG'"
  and .[0].destination_address == null and (.[0].tiers | length == 5)
  and (.[0].tiers[0] | has("price_cents") and has("imenska") and has("sale_end"))
  and .[0].event.attendance_mode == "physical"' "feed: objavljeni event, 5 tierova, destination_address null"

# ── 3. narudžba ──────────────────────────────────────────────────────────────
echo "== 3. narudžba (rezervacija s TTL-om)"
ORDER="$(uuid)"
O_BODY='{"order_id":"'$ORDER'","campaign_id":"'$EV'","tier_id":"'$T_SEB'","quantity":2,
  "holders":[{"full_name":"Ana Anić","email":"ana@example.test"},{"full_name":"Ivo Ivić"}]}'
req POST "$FN/events-order" "" "$O_BODY"
expect 200 '.state == "pending" and .amount_cents == 29800 and .destination_address == null and .existing == false and .expires_at != null' "events-order: pending, 29800, rezervacija"
expect_sql "select inventory_claimed from ulaznice.ticket_tiers where id = '$T_SEB'" "2" "rezervacija vidljiva odmah (inventory_claimed 2)"
expect_sql "select payment_rail || '|' || state || '|' || (buyer_account_id is null) from ulaznice.orders where id = '$ORDER'" "stripe|pending|true" "ulaznice.orders: rail stripe, pending, gost"
req POST "$FN/events-order" "" "$O_BODY"
expect 200 '.existing == true and .order_id == "'$ORDER'"' "idempotencija: isti payload → existing:true"
expect_sql "select inventory_claimed from ulaznice.ticket_tiers where id = '$T_SEB'" "2" "idempotencija: inventory ne raste"
req POST "$FN/events-order" "" '{"order_id":"'"$(uuid)"'","campaign_id":"'$EV'","tier_id":"'$T_SEB'","quantity":2,"holders":[{"full_name":"X"},{"full_name":"Y"}]}'
expect 400 '.error == "tier_sold_out"' "oversell odbijen (3 − 2 < 2) → tier_sold_out"
req POST "$FN/events-order" "" '{"order_id":"'"$(uuid)"'","campaign_id":"'$EV'","tier_id":"'$T_SEB'","quantity":1,"holders":[]}'
expect 400 '.error == "holders_incomplete"' "imenska bez imena → holders_incomplete"
req POST "$FN/events-order" "" '{"order_id":"'"$(uuid)"'","campaign_id":"'$EV'","tier_id":"'$T_STUD'","quantity":1,"holders":[{"full_name":"Student"}]}'
expect 400 '.error == "sale_ended"' "tier izvan prodajnog prozora → sale_ended"
req POST "$FN/events-order" "" '{"order_id":"'"$(uuid)"'","campaign_id":"'$EV'","tier_id":"'$T_RED'","quantity":1,"holders":[{"full_name":"Z"}],"payer_address":"0x2222222222222222222222222222222222222222"}'
expect 400 '.error == "onchain_rail_removed"' "payer_address (onchain) → onchain_rail_removed"

# ── 3b. besplatna narudžba ───────────────────────────────────────────────────
echo "== 3b. besplatna narudžba (rail free)"
FREE_ORDER="$(uuid)"
F_BODY='{"order_id":"'$FREE_ORDER'","campaign_id":"'$EV'","tier_id":"'$T_FREE'","quantity":2,"buyer_email":"gost@example.test"}'
req POST "$FN/events-order" "" "$F_BODY"
expect 200 '.state == "paid" and .free == true and .status == "paid" and .amount_cents == 0
  and (.tickets | length == 2) and all(.tickets[]; .qr_token | test("^[0-9a-f]{64}$"))' "besplatna: odmah paid + 2 ulaznice s QR tokenom"
expect_sql "select payment_rail || '|' || external_payment_ref || '|' || buyer_email from ulaznice.orders where id = '$FREE_ORDER'" \
  "free|free_${FREE_ORDER//-/}|gost@example.test" "besplatna: rail free, ref free_<id>, buyer_email"
req POST "$FN/events-order" "" "$F_BODY"
expect 200 '.existing == true and .state == "paid" and (has("tickets") | not)' "besplatna idempotencija: existing, bez novih tokena"
expect_sql "select count(*) || '|' || count(qr_token_once) from ulaznice.tickets where order_id = '$FREE_ORDER'" "2|0" "besplatna: 2 ulaznice, tokeni već isporučeni"
expect_sql_err "set role service_role; select ulaznice.confirm_ticket_order_offchain('$ORDER', 'free', 'free_x123456', 0, null)" "order_not_free" "rail free na plaćenoj narudžbi → order_not_free"

# ── 4. uplata ────────────────────────────────────────────────────────────────
echo "== 4. uplata: onchain ukinut, potvrda kao Worker (psql)"
req POST "$FN/events-confirm" "" '{"order_id":"'$ORDER'","tx_hash":"0xabc"}'
expect 410 '.error == "onchain_rail_removed"' "events-confirm → 410 onchain_rail_removed"
PI1="pi_Scen${RUN}A"
R="$(q "set role service_role; select ulaznice.confirm_ticket_order_offchain('$ORDER', 'stripe', '$PI1', 29800, 'ana@example.test')")"
BODY="$R"; CODE=200
expect 200 '.status == "paid" and (.serials | length == 2)' "confirm_ticket_order_offchain (service) → paid + 2 seriala"
R="$(q "set role service_role; select ulaznice.confirm_ticket_order_offchain('$ORDER', 'stripe', '$PI1', 29800, 'ana@example.test')")"
BODY="$R"
expect 200 '.status == "already_paid"' "isti (rail, ref) ponovno → already_paid"
expect_sql "select state || '|' || payment_rail || '|' || external_payment_ref from ulaznice.orders where id = '$ORDER'" "paid|stripe|$PI1" "orders: paid | stripe | pi_…"
expect_sql "select count(*) || '|' || count(qr_token_once) || '|' || bool_and(qr_token_hash ~ '^[0-9a-f]{64}$') from ulaznice.tickets where order_id = '$ORDER'" "2|2|true" "tickets: 2 izdane, hash + nedostavljeni token"

# ── 5. dostava ───────────────────────────────────────────────────────────────
echo "== 5. dostava ulaznica (QR jednokratno)"
req POST "$FN/events-tickets" "" '{"order_ids":["'$ORDER'"]}'
expect 200 '.orders[0].state == "paid" and .orders[0].tx_hash == null and (.orders[0].tickets | length == 2)
  and all(.orders[0].tickets[]; .qr_token | test("^[0-9a-f]{64}$"))' "events-tickets 1. poziv: 64-hex tokeni"
QR1="$(printf '%s' "$BODY" | jq -r '.orders[0].tickets[] | select(.holder_name == "Ana Anić") | .qr_token')"
T2_ID="$(printf '%s' "$BODY" | jq -r '.orders[0].tickets[] | select(.holder_name == "Ivo Ivić") | .id')"
QR2="$(printf '%s' "$BODY" | jq -r '.orders[0].tickets[] | select(.holder_name == "Ivo Ivić") | .qr_token')"
req POST "$FN/events-tickets" "" '{"order_ids":["'$ORDER'"]}'
expect 200 'all(.orders[0].tickets[]; .qr_token == null)' "events-tickets 2. poziv: qr_token null (samo hash u bazi)"

# ── 6. TTL istek ─────────────────────────────────────────────────────────────
echo "== 6. TTL istek oslobađa rezervaciju"
ORDER2="$(uuid)"
req POST "$FN/events-order" "" '{"order_id":"'$ORDER2'","campaign_id":"'$EV'","tier_id":"'$T_SEB'","quantity":1,"holders":[{"full_name":"Kasni Kupac"}]}'
expect 200 '.state == "pending"' "narudžba qty 1 (zadnje mjesto)"
expect_sql "select inventory_claimed from ulaznice.ticket_tiers where id = '$T_SEB'" "3" "tier pun (3/3)"
q "update ulaznice.orders set reserve_expires_at = now() - interval '1 minute' where id = '$ORDER2'" >/dev/null
req POST "$FN/events-tickets" "" '{"order_ids":["'$ORDER2'"]}'
expect 200 '.orders[0].state == "expired"' "nakon isteka: events-tickets → expired"
expect_sql "select inventory_claimed from ulaznice.ticket_tiers where id = '$T_SEB'" "2" "inventory_claimed vraćen (2)"

# ── 7. check-in ──────────────────────────────────────────────────────────────
echo "== 7. check-in"
req POST "$FN/events-checkin" "" '{"qr_token":"'$QR1'"}'
expect 401 '.error == "not_authenticated"' "bez JWT → 401 not_authenticated"
req POST "$FN/events-checkin" "Bearer $CLAN_JWT" '{"qr_token":"'$QR1'"}'
expect 403 '.error == "not_authorized"' "član koji nije admin → 403 not_authorized"
req POST "$FN/events-checkin" "Bearer $ADMIN_JWT" '{"qr_token":"dgdj1:'$QR1'"}'
expect 200 '.status == "checked_in" and .holder_name == "Ana Anić" and .tier_title == "Super Early Bird" and .checked_in_count == 1' "prvi sken (s dgdj1: prefiksom) → checked_in"
FIRST_AT="$(printf '%s' "$BODY" | jq -r .checked_in_at)"
req POST "$FN/events-checkin" "Bearer $ADMIN_JWT" '{"qr_token":"'$QR1'"}'
expect 200 '.status == "already_checked_in" and .checked_in_at == "'$FIRST_AT'" and .checked_in_by_email == "'$ADMIN_EMAIL'" and .checked_in_count == 1' "drugi sken → already_checked_in s vremenom prvog ulaza"
req POST "$FN/events-checkin" "Bearer $ADMIN_JWT" '{"qr_token":"nije-token"}'
expect 400 '.error == "invalid_token"' "krivi format → 400 invalid_token"
req POST "$FN/events-checkin" "Bearer $ADMIN_JWT" '{"qr_token":"'"$(openssl rand -hex 32)"'"}'
expect 200 '.status == "not_found"' "nepoznat token → not_found"
asadmin="select set_config('request.jwt.claims', '{\"sub\":\"$ADMIN_ID\",\"role\":\"authenticated\"}', true); set local role authenticated;"
R="$(q "begin; $asadmin select ulaznice.void_ticket('$T2_ID'); commit;")"; BODY="$R"; CODE=200
expect 200 '.status == "voided"' "void_ticket (org admin, psql) → voided"
req POST "$FN/events-checkin" "Bearer $ADMIN_JWT" '{"qr_token":"'$QR2'"}'
expect 200 '.status == "void"' "sken poništene ulaznice → void"
T1_ID="$(q "select id from ulaznice.tickets where order_id = '$ORDER' and holder_name = 'Ana Anić'")"
R="$(q "begin; $asadmin select ulaznice.void_ticket('$T1_ID'); commit;")"; BODY="$R"
expect 200 '.status == "already_checked_in"' "void iskorištene → already_checked_in"
expect_sql "select string_agg(event_type, ',' order by id) from ulaznice.order_events where order_id = '$ORDER' and event_type like 'ticket.%'" \
  "ticket.checked_in,ticket.checkin_duplicate,ticket.voided" "audit u ulaznice.order_events (uklj. dvostruki sken)"

# ── 8. (ukinuto) nesparena onchain uplata — v. §11.5 tx_already_credited ─────

# ── 9. organizator self-service ──────────────────────────────────────────────
echo "== 9. organizator self-service"
org() { req POST "$FN/events-organizer" "Bearer $ADMIN_JWT" "$1"; }
req POST "$FN/events-organizer" "" '{"action":"overview"}'
expect 401 '.error == "not_authenticated"' "events-organizer bez JWT → 401"
org '{"action":"overview"}'
expect 200 '(.accounts | map(select(.id == "'$ORG2'"))[0] | .allowlisted == false and .has_record == false)
  and (.accounts | map(select(.id == "'$ORG'"))[0].allowlisted == true)
  and (.events | map(.campaign_id) | index("'$EV'") != null)' "overview: ORG2 nije na allowlisti, ORG jest, event vidljiv"

EV2="$(uuid)"
org '{"action":"create","event_id":"'$EV2'","account_id":"'$ORG2'","title":"BlockSplit '$RUN'",
  "venue_name":"MEDILS","venue_city":"Split-'$RUN'","event_type":"kamp","description_hr":"Unconference.",
  "gallery":[{"url":"https://example.test/g1.jpg"},{"url":"https://example.test/g2.jpg"}],
  "tiers":[{"title":"Stay paket","price_cents":39900,"inventory_total":40,"imenska":true},
           {"title":"Dnevna","price_cents":5000,"inventory_total":100,"imenska":false}]}'
expect 200 '.existing == false and .event_created == true' "create (ORG2) s galerijom i 2 plaćena tiera"
expect_sql "select jsonb_array_length(gallery) || '|' || (gallery->1->>'url') || '|' || state from ulaznice.events where id = '$EV2'" \
  "2|https://example.test/g2.jpg|draft" "galerija spremljena (2 slike), skica"
org '{"action":"update","campaign_id":"'$EV2'","gallery":[]}'
expect 200 '' "update s gallery: []"
expect_sql "select gallery::text from ulaznice.events where id = '$EV2'" "[]" "galerija obrisana"
org '{"action":"create","event_id":"'"$(uuid)"'","account_id":"'$ORG2'","title":"Loša galerija","venue_name":"X","venue_city":"Y","gallery":[{"url":"http://nije-https"}]}'
expect 400 '.error == "invalid_gallery_url"' "galerija s http:// → invalid_gallery_url"

T_DNEVNA="$(q "select id from ulaznice.ticket_tiers where event_id = '$EV2' and title = 'Dnevna'")"
T_STAY="$(q "select id from ulaznice.ticket_tiers where event_id = '$EV2' and title = 'Stay paket'")"
org '{"action":"update","campaign_id":"'$EV2'","remove_tier_ids":["'$T_DNEVNA'"]}'
expect 200 '' "remove_tier_ids na skici"
expect_sql "select count(*) from ulaznice.ticket_tiers where event_id = '$EV2'" "1" "tier obrisan (ostao 1)"

# narudžba na tieru skice: kroz API nemoguća (create_ticket_order traži active) — fixture psql-om
HOLD="$(uuid)"
q "insert into ulaznice.orders (id, event_id, tier_id, amount_cents, currency, quantity, state, payment_rail)
   values ('$HOLD', '$EV2', '$T_STAY', 39900, 'eur', 1, 'pending', 'stripe')" >/dev/null
org '{"action":"update","campaign_id":"'$EV2'","remove_tier_ids":["'$T_STAY'"]}'
expect 400 '.error == "tier_has_orders"' "brisanje tiera s narudžbom → tier_has_orders"
org '{"action":"delete","campaign_id":"'$EV2'"}'
expect 400 '.error == "event_has_orders"' "brisanje skice s narudžbom → event_has_orders"
q "delete from ulaznice.orders where id = '$HOLD'" >/dev/null

org '{"action":"publish","campaign_id":"'$EV2'"}'
expect 400 '.error == "organizer_not_allowlisted"' "publish bez allowliste → organizer_not_allowlisted"
q "insert into ulaznice.organizer_allowlist (account_id, note) values ('$ORG2', 'curl scenarij $RUN')" >/dev/null
org '{"action":"publish","campaign_id":"'$EV2'"}'
expect 400 '.error == "event_no_working_rail"' "publish s plaćenim tierom bez Stripe raila → event_no_working_rail"
expect_sql "select state from ulaznice.events where id = '$EV2'" "draft" "event ostao skica"
org '{"action":"delete","campaign_id":"'$EV2'"}'
expect 200 '.deleted == true' "delete skice bez narudžbi → deleted"

EV3="$(uuid)"
org '{"action":"create","event_id":"'$EV3'","account_id":"'$ORG2'","title":"Besplatni meetup '$RUN'",
  "venue_name":"Klub","venue_city":"'$CITY'","starts_at":"'$NEAR'","ends_at":"'$NEAR_END'",
  "tiers":[{"title":"Ulaz","price_cents":0,"inventory_total":30,"imenska":false}]}'
expect 200 '.event_created == true' "create (ORG2): samo besplatni tier"
org '{"action":"publish","campaign_id":"'$EV3'"}'
expect 200 '.state == "active"' "publish samo-besplatnog eventa bez Stripe raila → active (odluka 352)"
T_ULAZ="$(q "select id from ulaznice.ticket_tiers where event_id = '$EV3'")"
org '{"action":"update","campaign_id":"'$EV3'","remove_tier_ids":["'$T_ULAZ'"]}'
expect 409 '.error == "event_not_draft"' "remove tier na aktivnom eventu → 409 event_not_draft"
org '{"action":"update","campaign_id":"'$EV3'","tiers":[{"id":"'$T_ULAZ'","title":"Ulaz","price_cents":500,"inventory_total":30}]}'
expect 400 '.error == "tier_locked"' "promjena cijene nakon objave → tier_locked"
org '{"action":"update","campaign_id":"'$EV3'","tiers":[{"title":"VIP","price_cents":2000,"inventory_total":5}]}'
expect 400 '.error == "event_no_working_rail"' "novi plaćeni tier na aktivnom eventu bez raila → event_no_working_rail"
org '{"action":"update","campaign_id":"'$EV3'","tiers":[{"title":"Ulaz 2","price_cents":0,"inventory_total":10}]}'
expect 200 '' "novi besplatni tier na aktivnom eventu smije"
expect_sql "select count(*) from ulaznice.ticket_tiers where event_id = '$EV3'" "2" "aktivni event ima 2 tiera"

req POST "$FN/events-organizer" "Bearer $CLAN_JWT" '{"action":"create","event_id":"'"$(uuid)"'","account_id":"'$ORG'","title":"Član bez prava","venue_name":"X","venue_city":"Y"}'
expect 400 '.error == "new"' "create_event bez admin prava → 400 {\"error\":\"new\"} (RLS poruka, kao prije)"
req POST "$FN/events-organizer" "Bearer $CLAN_JWT" '{"action":"publish","campaign_id":"'$EV3'"}'
expect 403 '.error == "not_authorized"' "publish tuđeg eventa → 403 not_authorized"

org '{"action":"record_upsert","account_id":"'$ORG2'","legal_name":"UBIK udruga","oib":"12345678903","address_line":"Ulica 1","city":"Split","postal_code":"21000","financial_identifier_type":"iban","financial_identifier":"HR1210010051863000160"}'
expect 200 '.saved == true' "DAC7 record_upsert (admin) → saved"
req POST "$FN/events-organizer" "Bearer $CLAN_JWT" '{"action":"record_upsert","account_id":"'$ORG2'","legal_name":"X d.o.o.","oib":"12345678903","address_line":"A","city":"B","postal_code":"10000","financial_identifier_type":"iban","financial_identifier":"HR1210010051863000160"}'
expect 403 '.error == "not_authorized"' "DAC7 ne-admin → 403 not_authorized"
rest GET "organizer_records?select=account_id" "$ANON" "$CLAN_JWT"
expect 200 'length == 0' "DAC7 RLS: drugi authenticated korisnik vidi 0 redaka"
rest GET "organizer_records?select=account_id&account_id=eq.$ORG2" "$ANON" "$ADMIN_JWT"
expect 200 'length == 1' "DAC7 RLS: admin računa vidi svoj zapis"

org '{"action":"publish","campaign_id":"'$EV3'","target_state":"closed"}'
expect 200 '.state == "closed"' "zatvaranje prodaje → closed"
org '{"action":"publish","campaign_id":"'$EV3'","target_state":"closed"}'
expect 400 '.error == "invalid_state_transition"' "closed → closed → invalid_state_transition"

# ── 9b. online event ─────────────────────────────────────────────────────────
echo "== 9b. online event (attendance_mode online, link u event_access)"
EVO="$(uuid)"
ONLINE_URL="https://meet.example.test/scen-$RUN"
org '{"action":"create","event_id":"'$EVO'","account_id":"'$ORG2'","title":"Webinar '$RUN'",
  "attendance_mode":"online","online_url":"'$ONLINE_URL'","starts_at":"'$FAR'","ends_at":"'$FAR_END'",
  "tiers":[{"title":"Online ulaz","price_cents":0,"inventory_total":500,"imenska":false}]}'
expect 200 '.event_created == true' "create online eventa bez mjesta/grada"
expect_sql "select attendance_mode || '|' || venue_name || '|' || venue_city from ulaznice.events where id = '$EVO'" "online|Online|Online" "venue = „Online”, attendance_mode online"
expect_sql "select online_url from ulaznice.event_access where event_id = '$EVO'" "$ONLINE_URL" "online_url u ulaznice.event_access"
org '{"action":"create","event_id":"'"$(uuid)"'","account_id":"'$ORG2'","title":"Krivi link","attendance_mode":"online","online_url":"http://x.test"}'
expect 400 '.error == "invalid_online_url"' "online_url bez https → invalid_online_url"
org '{"action":"publish","campaign_id":"'$EVO'"}'
expect 200 '.state == "active"' "publish online eventa (samo besplatni)"
req GET "$FN/events-feed?grad=Online&limit=100"
expect 200 '(.events | map(select(.campaign_id == "'$EVO'"))[0].event.attendance_mode == "online")
  and (tostring | contains("'$ONLINE_URL'") | not)' "feed: attendance_mode online, link NIJE u feedu"
OO="$(uuid)"
req POST "$FN/events-order" "" '{"order_id":"'$OO'","campaign_id":"'$EVO'","tier_id":"'"$(q "select id from ulaznice.ticket_tiers where event_id = '$EVO'")"'","quantity":1,"buyer_email":"online@example.test"}'
expect 200 '.state == "paid" and (.tickets | length == 1) and (tostring | contains("'$ONLINE_URL'") | not)' "kupnja online ulaznice: paid, link nije u odgovoru events-order"
rest GET "event_access?event_id=eq.$EVO&select=online_url" "$SERVICE" "$SERVICE"
expect 200 '.[0].online_url == "'$ONLINE_URL'"' "Worker put (service, PostgREST ulaznice.event_access) čita link za mail/stranicu narudžbe"
rest GET "event_access?event_id=eq.$EVO&select=online_url" "$ANON"
[ "$CODE" = "401" ] || [ "$CODE" = "403" ] || fail "anon čita event_access (HTTP $CODE)" "$BODY"
ok "anon nema pristup ulaznice.event_access (HTTP $CODE)"
rest GET "event_access?event_id=eq.$EVO&select=online_url" "$ANON" "$CLAN_JWT"
expect 200 'length == 0' "authenticated ne-admin vidi 0 redaka event_access"
org '{"action":"update","campaign_id":"'$EVO'","online_url":""}'
expect 200 '' "update online_url: \"\" briše link"
expect_sql "select coalesce(online_url, 'null') from ulaznice.event_access where event_id = '$EVO'" "null" "link obrisan"

# ── 10. feed filtriranje / paginacija ────────────────────────────────────────
echo "== 10. feed filtriranje/paginacija"
# u $CITY: EV (aktivan, +60 d) i EV3 (zatvoren → nije u feedu)
req GET "$FN/events-feed?grad=$(printf '%s' "$CITY" | tr 'A-Z' 'a-z')"
expect 200 '[.events[].campaign_id] == ["'$EV'"]' "grad: case-insensitive, samo aktivni (zatvoreni ispada)"
req GET "$FN/events-feed?grad=Online&limit=100"
expect 200 '[.events[].campaign_id] | index("'$EVO'") != null' "grad=Online: online event"
FROM="$(q "select to_char((now() + interval '59 days') at time zone 'UTC', 'YYYY-MM-DD')")"
TO="$(q "select to_char((now() + interval '62 days') at time zone 'UTC', 'YYYY-MM-DD')")"
req GET "$FN/events-feed?grad=$CITY&from=$FROM&to=$TO"
expect 200 '.events | length == 1' "from/to prozor obuhvaća event"
req GET "$FN/events-feed?grad=$CITY&to=$FROM"
expect 200 '.events | length == 0' "to prije početka → prazno"
req GET "$FN/events-feed?limit=1&offset=1"
expect 200 '.limit == 1 and .offset == 1 and (.events | length <= 1)' "limit/offset vraćeni i poštovani"
req GET "$FN/events-feed?limit=500"
expect 200 '.limit == 100' "limit se reže na 100"
req GET "$FN/events-feed"
expect 200 '.limit == 50 and .offset == 0' "bez parametara: limit 50, offset 0"

# ── 11. Stripe rail ──────────────────────────────────────────────────────────
echo "== 11. Stripe rail (HMAC, intent, confirm, ne-uspjesi, refund)"
SO="$(uuid)"
req POST "$FN/events-order" "" '{"order_id":"'$SO'","campaign_id":"'$EV'","tier_id":"'$T_RED'","quantity":2,"holders":[{"full_name":"Web Kupac","email":"web@example.test"},{"full_name":"Drugi Gost"}]}'
expect 200 '.state == "pending" and .amount_cents == 29800' "11.2 narudžba Redovna ×2 (pending)"

req POST "$FN/events-stripe-intent" "" '{"order_id":"'$SO'"}'
expect 401 '.error == "missing_signature"' "11.3 intent bez potpisa → 401 missing_signature"
req POST "$FN/events-stripe-intent" "" '{"order_id":"'$SO'"}' "x-ulaznice-signature: sha256=$(printf 'a%.0s' $(seq 1 64))"
expect 401 '.error == "bad_signature"' "11.3 intent s krivim potpisom → 401 bad_signature"
spost "$FN/events-stripe-intent" '{"order_id":"'$SO'"}'
expect 200 '.amount_cents == 29800 and .currency == "eur" and .quantity == 2 and .stripe_account_id == "'$ACCT'"
  and .charges_enabled == true and .invoice_provider == "fira" and .tier.title == "Redovna" and .event.campaign_id == "'$EV'"' "11.3 intent: podaci za Checkout + stripe_account_id"
q "update ulaznice.organizer_payment_rails set stripe_charges_enabled = false where account_id = '$ORG'" >/dev/null
spost "$FN/events-stripe-intent" '{"order_id":"'$SO'"}'
expect 400 '.error == "organizer_charges_disabled"' "11.3 charges_enabled=false → organizer_charges_disabled"
q "update ulaznice.organizer_payment_rails set stripe_charges_enabled = true where account_id = '$ORG'" >/dev/null
spost "$FN/events-stripe-intent" '{"order_id":"'"$(uuid)"'"}'
expect 404 '.error == "order_not_found"' "11.3 nepostojeća narudžba → 404 order_not_found"

PI2="pi_Scen${RUN}B"
CB='{"order_id":"'$SO'","external_ref":"'$PI2'","amount_cents":29800,"payer_email":"web@example.test"}'
req POST "$FN/events-stripe-confirm" "" "$CB" "x-ulaznice-signature: sha256=$(printf 'a%.0s' $(seq 1 64))"
expect 401 '.error == "bad_signature"' "11.4 confirm s krivim potpisom → 401"
req POST "$FN/events-stripe-confirm" "" "$CB"
expect 401 '.error == "missing_signature"' "11.4 confirm bez potpisa → 401"
expect_sql "select state || '|' || coalesce(external_payment_ref, 'null') || '|' || (select count(*) from ulaznice.tickets where order_id = '$SO') from ulaznice.orders where id = '$SO'" \
  "pending|null|0" "11.4 baza netaknuta nakon odbijenih potpisa"
spost "$FN/events-stripe-confirm" "$CB"
expect 200 '.ok == true and .status == "paid" and (.serials | length == 2) and (.tickets | length == 2)
  and all(.tickets[]; .qr_token | test("^[0-9a-f]{64}$"))' "11.4 valjan potpis → paid + 2 ulaznice s QR tokenom"
spost "$FN/events-stripe-confirm" "$CB"
expect 200 '.status == "already_paid" and all(.tickets[]; .qr_token == null)' "11.4 isti confirm ponovno → already_paid, tokeni null"
expect_sql "select count(*) || '|' || count(qr_token_once) from ulaznice.tickets where order_id = '$SO'" "2|0" "11.4 2 ulaznice, 0 nedostavljenih tokena"
spost "$FN/events-stripe-intent" '{"order_id":"'$SO'"}'
expect 400 '.error == "order_not_pending" and .state == "paid"' "11.3 intent na plaćenoj → order_not_pending"

SO2="$(uuid)"
req POST "$FN/events-order" "" '{"order_id":"'$SO2'","campaign_id":"'$EV'","tier_id":"'$T_RED'","quantity":1,"holders":[{"full_name":"Treći"}]}'
expect 200 '.state == "pending"' "11.5 druga narudžba (14900)"
spost "$FN/events-stripe-confirm" '{"order_id":"'$SO2'","external_ref":"pi_Scen'$RUN'C","amount_cents":100}'
expect 200 '.ok == true and .status == "amount_insufficient" and .expected_cents == 14900 and .received_cents == 100' "11.5 premali iznos → amount_insufficient"
spost "$FN/events-stripe-confirm" '{"order_id":"'$SO2'","external_ref":"'$PI2'","amount_cents":14900}'
expect 200 '.status == "tx_already_credited"' "11.5 isti external_ref na drugoj narudžbi → tx_already_credited"
spost "$FN/events-stripe-confirm" '{"order_id":"'$SO'","external_ref":"pi_Scen'$RUN'D","amount_cents":29800}'
expect 200 '.status == "duplicate_payment" and .credited_ref == "'$PI2'"' "11.5 druga uplata na plaćenu → duplicate_payment"
expect_sql "select string_agg(event_type, ',' order by id) from ulaznice.order_events where order_id in ('$SO','$SO2') and event_type like 'ticket_order.%'" \
  "ticket_order.underpaid,ticket_order.match_conflict,ticket_order.duplicate_payment" "11.5 audit: underpaid, match_conflict, duplicate_payment"

# expired_sold_out: Mala (inventory 1)
SX="$(uuid)"; SY="$(uuid)"
req POST "$FN/events-order" "" '{"order_id":"'$SX'","campaign_id":"'$EV'","tier_id":"'$T_MALA'","quantity":1}'
expect 200 '.state == "pending"' "11.5 Mala: narudžba A zauzme jedino mjesto"
q "update ulaznice.orders set reserve_expires_at = now() - interval '1 minute' where id = '$SX'" >/dev/null
req POST "$FN/events-order" "" '{"order_id":"'$SY'","campaign_id":"'$EV'","tier_id":"'$T_MALA'","quantity":1}'
expect 200 '.state == "pending"' "11.5 A istekla, narudžba B uzme mjesto"
spost "$FN/events-stripe-intent" '{"order_id":"'$SX'"}'
expect 400 '.error == "order_not_pending" and .state == "expired"' "11.3 intent na isteklu → order_not_pending (expired)"
spost "$FN/events-stripe-confirm" '{"order_id":"'$SX'","external_ref":"pi_Scen'$RUN'E","amount_cents":1000}'
expect 200 '.status == "expired_sold_out"' "11.5 kasna uplata za isteklu, tier pun → expired_sold_out"
spost "$FN/events-stripe-confirm" '{"order_id":"'$SY'","external_ref":"pi_Scen'$RUN'F","amount_cents":1000}'
expect 200 '.status == "paid"' "11.5 narudžba B plaćena"

# RPC rubovi (psql)
expect_sql_err "set role service_role; select ulaznice.confirm_ticket_order_offchain('$SO2', 'onchain', 'pi_X_123', 1, null)" "invalid_rail" "11.5 rail onchain → invalid_rail"
expect_sql_err "set role service_role; select ulaznice.confirm_ticket_order_offchain('$SO2', 'stripe', 'x', 1, null)" "invalid_external_ref" "11.5 kratki ref → invalid_external_ref"
expect_sql_err "set role authenticated; select ulaznice.confirm_ticket_order_offchain('$SO2', 'stripe', 'pi_Y_123', 1, null)" "permission denied" "11.5 authenticated ne smije confirm RPC"
expect_sql_err "update ulaznice.orders set external_payment_ref = '$PI2' where id = '$SO2'" "ux_orders_external_payment" "11.5 idempotencija u bazi: unique (rail, ref)"

# 11.7 refund (Worker put: PostgREST rpc, service ključ)
rest POST "rpc/refund_ticket_order" "$ANON" "" '{"p_order_id":"'$SO'"}'
[ "$CODE" = "401" ] || [ "$CODE" = "403" ] || fail "11.7 anon refund (HTTP $CODE)" "$BODY"
ok "11.7 anon ne smije refund_ticket_order (HTTP $CODE)"
CLAIMED_BEFORE="$(q "select inventory_claimed from ulaznice.ticket_tiers where id = '$T_RED'")"
rest POST "rpc/refund_ticket_order" "$SERVICE" "$SERVICE" '{"p_order_id":"'$SO'","p_reason":"organizator","p_external_ref":"re_Scen'$RUN'"}'
expect 200 '.status == "refunded" and .voided == 2 and .kept_checked_in == 0' "11.7 refund (service, PostgREST) → refunded, 2 void"
expect_sql "select state from ulaznice.orders where id = '$SO'" "refunded" "11.7 narudžba refunded"
expect_sql "select inventory_claimed from ulaznice.ticket_tiers where id = '$T_RED'" "$((CLAIMED_BEFORE - 2))" "11.7 inventory vraćen u prodaju"
rest POST "rpc/refund_ticket_order" "$SERVICE" "$SERVICE" '{"p_order_id":"'$SO'"}'
expect 200 '.status == "already_refunded"' "11.7 ponovni refund → already_refunded"
R="$(q "set role service_role; select ulaznice.refund_ticket_order('$SO2')")"; BODY="$R"
expect 200 '.status == "not_paid"' "11.7 refund pending narudžbe → not_paid"
# refund narudžbe s iskorištenom ulaznicom: ulaz ostaje checked_in
R="$(q "set role service_role; select ulaznice.refund_ticket_order('$ORDER')")"; BODY="$R"
expect 200 '.status == "refunded" and .kept_checked_in == 1' "11.7 refund narudžbe iz §3: iskorištena ulaznica ostaje checked_in"

echo
echo "SVE PROVJERE PROŠLE ($N_OK provjera)"
