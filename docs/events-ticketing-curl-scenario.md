# Ulaznice (shema `ulaznice`) — curl test scenarij

> Izvršna verzija: **`scripts/ulaznice-curl-scenario.sh`** izvodi ovaj dokument redom (§0–§11)
> nad lokalnim stackom; svaka provjera ispisuje `OK — <opis>`, prva neuspjela izlazi s kodom ≠ 0
> i ispisuje što je dobila, kraj je `SVE PROVJERE PROŠLE (N provjera)`. Isječci ispod su ti isti
> pozivi, pisani za ručno ponavljanje.
>
> Shema: `ulaznice` (lanac `docs/ulaznice-shema/`, S4). Migracije `20261125150000_ulaznice_shema`,
> `20261125160000_ulaznice_rpc_narudzbe`, `20261125170000_ulaznice_rpc_eventi`; odluke u
> `docs/ulaznice-shema/decisions.md` (110 onchain ukinut, 300–309, 350–361).
> Funkcije: `events-order`, `events-confirm` (ukinuta, 410), `events-tickets`, `events-feed`,
> `events-checkin`, `events-organizer`, `events-stripe-intent`, `events-stripe-confirm`.
>
> ⚠ **Na produkciji ništa od ovoga prije S6 lanca** (migracije `20261125150000`+ i
> `PGRST_DB_SCHEMAS` s `ulaznice`, v. `docs/ulaznice-shema/research/2026-11-25-pgrst-db-schemas.md`).

**Mapiranje iz stare sheme** (`pinka_finance` → `ulaznice`): `campaigns` + `events` →
`ulaznice.events` (id = stari campaign id, jedan red nosi glavu i detalje); `campaign_tiers` →
`ticket_tiers` (bez `kind`); `contributions` → `orders` (`campaign_id` → `event_id`,
`contributor_account_id` → `buyer_account_id`, nema `destination_address`/`forward_tx_hash`);
`contribution_events` → `order_events`; `tickets.contribution_id` → `order_id`;
`event_access.campaign_id` → `event_id`. Imena RPC-a i parametri su isti (`p_campaign_id`), HTTP
ugovor funkcija isti; ključ `destination_address` u odgovorima ostaje, uvijek `null` (odluka 3).

**Onchain rail je ukinut** (odluka 110): nema EURe uplate na Safe, nema `confirm_ticket_order`
RPC-a, nema Safe adrese organizatora. Plaćeno = Stripe Connect (§11), besplatno = rail `free`
(§3b). Publish gating = allowlist + rail (Stripe Connect s `charges_enabled` ILI samo besplatni
tierovi), odluka 352.

## 0. Okruženje

Lokalni stack (`supabase start`, API `:55321`, DB `:55322`). `supabase start` servira i edge
funkcije (kontejner `supabase_edge_runtime_<projekt>`) s tajnama iz `supabase/functions/.env`
(gitignored); `supabase functions serve` je alternativa. Bez seeda (`supabase db reset --no-seed`
stanje je dovoljno): skripta sve fixture stvara sama.

```bash
eval "$(supabase status -o env | sed 's/^/export /')"   # ANON_KEY, SERVICE_ROLE_KEY, API_URL…
export API=http://127.0.0.1:55321 FN=http://127.0.0.1:55321/functions/v1
alias lpsql='psql "postgresql://postgres:postgres@127.0.0.1:55322/postgres"'
# HMAC tajna za Stripe funkcije: ista vrijednost kao u supabase/functions/.env (NE u repo)
export SECRET="$(sed -n 's/^EVENTS_STRIPE_CONFIRM_SECRET=//p' supabase/functions/.env)"
sign() { printf '%s' "$1" | openssl dgst -sha256 -hmac "$SECRET" -hex | sed 's/^.*= /sha256=/'; }
spost() { curl -s -X POST "$1" -H 'content-type: application/json' \
               -H "x-ulaznice-signature: $(sign "$2")" --data-binary "$2" | jq; }
```

Provjera da funkcije rade i nose S4 kod: `curl -s -X POST $FN/events-confirm -d '{}'` →
`{"error":"onchain_rail_removed"}` (HTTP 410).

## 1. Priprema: korisnici, org račun, KYC, allowlist, rail, create_event, publish

Korisnici idu kroz GoTrue admin API (service ključ), JWT kroz password grant:

```bash
curl -s -X POST "$API/auth/v1/admin/users" -H "apikey: $SERVICE_ROLE_KEY" \
  -H "Authorization: Bearer $SERVICE_ROLE_KEY" -H 'content-type: application/json' \
  -d '{"email":"admin@momo.test","password":"…","email_confirm":true}' | jq -r .id   # → ADMIN_ID
# isto za clan@momo.test (običan član, za 403 provjere) → CLAN_ID

export ADMIN_JWT=$(curl -s -X POST "$API/auth/v1/token?grant_type=password" \
  -H "apikey: $ANON_KEY" -H 'content-type: application/json' \
  -d '{"email":"admin@momo.test","password":"…"}' | jq -r .access_token)
```

Org račun, članstvo, KYC, allowlist i Stripe stanje postavlja operater (psql; osobni račun
korisnika stvara `public.handle_new_user`):

```sql
-- lpsql
insert into public.accounts (id, primary_owner_user_id, is_personal_account, slug, name)
values ('<ORG>', '<ADMIN_ID>', false, 'momo-org', 'Money Motion');
insert into public.accounts_memberships (account_id, user_id, account_role)
values ('<ORG>', '<ADMIN_ID>', 'owner'), ('<ORG>', '<CLAN_ID>', 'member')
on conflict (account_id, user_id) do update set account_role = excluded.account_role;

-- KYC: public.is_identity_verified() gleda auth.uid() (pozivatelja), ne vlasnika računa
insert into public.identity_verifications (user_id, oib_ciphertext, oib_hash)
values ('<ADMIN_ID>', '\x00'::bytea, 'test-oib-hash-admin');

-- moderacija (pilot flag, upis isključivo operater / service)
insert into ulaznice.organizer_allowlist (account_id, note) values ('<ORG>', 'pilot');

-- Stripe Connect stanje organizatora (u produkciji piše Worker iz account.updated webhooka)
insert into ulaznice.organizer_payment_rails
  (account_id, stripe_account_id, stripe_charges_enabled, stripe_payouts_enabled, invoice_provider)
values ('<ORG>', 'acct_1TestOrganizator', true, true, 'fira');
```

Kreiranje i objava idu kroz `events-organizer` (kao editor u `domovina-ulaznice`):

```bash
export EV=$(uuidgen | tr 'A-Z' 'a-z')
curl -s -X POST $FN/events-organizer -H "Authorization: Bearer $ADMIN_JWT" \
  -H 'content-type: application/json' -d '{
  "action":"create", "event_id":"'$EV'", "account_id":"<ORG>",
  "title":"Money Motion 2027 (test)", "venue_name":"Zagrebački velesajam", "venue_city":"Zagreb",
  "event_type":"konferencija", "starts_at":"2027-03-10T08:00:00+01", "ends_at":"2027-03-11T20:00:00+01",
  "description_hr":"Testni event", "organizer_name":"Money Motion", "organizer_email":"tickets@money-motion.eu",
  "tiers":[
    {"title":"Super Early Bird","price_cents":14900,"inventory_total":3,"imenska":true},
    {"title":"Studentska","price_cents":4900,"inventory_total":100,"imenska":true,"sale_end":"2026-01-01T00:00:00Z"},
    {"title":"Besplatna","price_cents":0,"inventory_total":50,"imenska":false},
    {"title":"Mala","price_cents":1000,"inventory_total":1,"imenska":false},
    {"title":"Redovna","price_cents":14900,"inventory_total":20,"imenska":true}
  ]}' | jq
# → {"id":…, "slug":"money-motion-2027-test", "existing":false, "event_created":true}
# isti poziv drugi put → {"existing":true, "event_created":false}
# lpsql: select state, visibility from ulaznice.events where id='<EV>';  → draft | private

curl -s -X POST $FN/events-organizer -H "Authorization: Bearer $ADMIN_JWT" \
  -H 'content-type: application/json' -d '{"action":"publish","campaign_id":"'$EV'"}' | jq
# → {"campaign_id":…, "state":"active", "visibility":"public"}

# tier id-evi za nastavak:
# lpsql: select id, title, price_cents, imenska, inventory_total, inventory_claimed, sale_end
#          from ulaznice.ticket_tiers where event_id = '<EV>' order by sort;
```

`create_event` je od S3b DEFINER s vlastitom provjerom admin + KYC (odluka 350); service_role
(psql) i dalje može izravno (`select ulaznice.create_event(p_id => …, p_account_id => …, …)`),
ali `p_destination_address` se samo validira i odbacuje (odluka 351).

## 2. Feed (javni katalog)

```bash
curl -s "$FN/events-feed?grad=Zagreb" | jq
# events[]: campaign_id = EV, slug, state "active", destination_address null,
#   event {…, gallery, attendance_mode "physical"}, tiers[5] s price_cents/imenska/sale_*
```

## 3. Narudžba (rezervacija s TTL-om)

```bash
export TIER=<SUPER_EARLY_BIRD_TIER_UUID>
export ORDER=$(uuidgen | tr 'A-Z' 'a-z')
curl -s -X POST $FN/events-order -H 'content-type: application/json' -d '{
  "order_id": "'$ORDER'", "campaign_id": "'$EV'", "tier_id": "'$TIER'", "quantity": 2,
  "holders": [{"full_name":"Ana Anić","email":"ana@example.com"}, {"full_name":"Ivo Ivić"}]
}' | jq
# → {"order_id":…, "state":"pending", "amount_cents":29800, "currency":"eur",
#    "destination_address":null, "expires_at":…, "existing":false}
```

Provjere:

```bash
# rezervacija vidljiva ODMAH:
# lpsql: select inventory_claimed from ulaznice.ticket_tiers where id = '<TIER>';          → 2
# lpsql: select payment_rail, state, buyer_account_id from ulaznice.orders where id = '<ORDER>';
#        → stripe | pending | null   (gost; s pinka JWT-om bi bio osobni račun)

# idempotencija: ISTI payload → existing:true, inventory NE raste

# oversell (inventory_total 3, claimed 2, qty 2)         → 400 {"error":"tier_sold_out"}
# imenska bez imena ("holders": [])                       → 400 {"error":"holders_incomplete"}
# Studentska (sale_end u prošlosti)                       → 400 {"error":"sale_ended"}
# payer_address (stari onchain klijent):
curl -s -X POST $FN/events-order -H 'content-type: application/json' -d '{
  "order_id":"'$(uuidgen | tr A-Z a-z)'", "campaign_id":"'$EV'", "tier_id":"<REDOVNA>",
  "quantity":1, "holders":[{"full_name":"Z"}],
  "payer_address":"0x2222222222222222222222222222222222222222"}' | jq
# → 400 {"error":"onchain_rail_removed"}
```

## 3b. Besplatna narudžba (rail `free`)

Tier s cijenom 0 → narudžba od 0 centi. `events-order` je potvrđuje odmah (service klijent,
`confirm_ticket_order_offchain` s railom `free`) i u istom odgovoru isporuči QR tokene
(jednokratno, `deliver_ticket_orders`). Stripe ne sudjeluje.

```bash
export FREE_ORDER=$(uuidgen | tr 'A-Z' 'a-z')
curl -s -X POST $FN/events-order -H 'content-type: application/json' -d '{
  "order_id":"'$FREE_ORDER'", "campaign_id":"'$EV'", "tier_id":"<BESPLATNA>",
  "quantity":2, "buyer_email":"gost@example.com"}' | jq
# → {"state":"paid", "free":true, "status":"paid", "amount_cents":0, "serials":[…2…],
#    "tickets":[{"serial":…, "state":"issued", "qr_token":"<64-hex>"}, …]}
# lpsql: select payment_rail, external_payment_ref, buyer_email from ulaznice.orders where id='<FREE_ORDER>';
#        → free | free_<order id bez crtica> | gost@example.com

# isti poziv ponovno → {"existing":true, "state":"paid", …} bez "tickets" (tokeni su već isporučeni)
# rail free na plaćenoj narudžbi (service psql):
#   select ulaznice.confirm_ticket_order_offchain('<ORDER>','free','free_x123456',0,null);
#   → ERROR order_not_free   (otvorena funkcija ne može izdati plaćenu ulaznicu)
```

## 4. Uplata

**Onchain je ukinut.** `events-confirm` za svaki POST vraća `410 {"error":"onchain_rail_removed"}`
(ruta ostaje da stari klijent dobije trajnu 4xx grešku). Nekadašnji koraci „EURe tx → confirm”,
`tx_hash`/`log_index` i simulacija kroz `confirm_ticket_order` više ne postoje.

Plaćena narudžba se potvrđuje Stripeom: Worker nakon webhooka zove `events-stripe-confirm` (§11.4).
Ovdje, da §5–§7 imaju plaćenu narudžbu, potvrda ide izravno RPC-om, kao što bi to Worker učinio
service ključem:

```sql
-- lpsql
set role service_role;
select ulaznice.confirm_ticket_order_offchain('<ORDER>'::uuid, 'stripe', 'pi_TEST_1', 29800, 'ana@example.com');
-- → {"status":"paid","order_id":…,"serials":["MON-000001","MON-000002"]}
-- isti poziv ponovno → {"status":"already_paid", …}
reset role;

select state, payment_rail, external_payment_ref from ulaznice.orders where id = '<ORDER>';
-- → paid | stripe | pi_TEST_1
select serial, holder_name, state, qr_token_hash is not null as has_hash, qr_token_once is not null as undelivered
  from ulaznice.tickets where order_id = '<ORDER>';
-- → 2 reda, issued, has_hash t, undelivered t  (RPC ne isporučuje tokene; §5 hoće)
```

## 5. Dostava ulaznica (QR tokeni jednokratno)

```bash
curl -s -X POST $FN/events-tickets -H 'content-type: application/json' \
  -d '{"order_ids":["'$ORDER'"]}' | jq
# 1. poziv: orders[0].state "paid", tx_hash null (ključ ostaje), tickets[].qr_token = 64-hex
# 2. poziv: tickets[].qr_token = null — u bazi je ostao samo sha256 hash
```

## 6. TTL istek oslobađa rezervaciju

```bash
export ORDER2=$(uuidgen | tr 'A-Z' 'a-z')
# narudžba qty=1 na Super Early Bird (zadnje mjesto, claimed 3/3), zatim:
# lpsql: update ulaznice.orders set reserve_expires_at = now() - interval '1 minute' where id = '<ORDER2>';
# svaki sljedeći events-order / events-tickets / events-stripe-intent poziv pokreće expire:
curl -s -X POST $FN/events-tickets -H 'content-type: application/json' \
  -d '{"order_ids":["'$ORDER2'"]}' | jq '.orders[0].state'
# → "expired"; inventory_claimed 3 → 2
```

## 7. Check-in — skener ulaza

`events-checkin` traži GoTrue JWT **admina** računa vlasnika eventa (vlasnik računa također
prolazi); autorizacija je server-side u `ulaznice.redeem_ticket`
(`has_role_on_account(events.account_id, 'admin')`). App šalje goli 64-hex token; funkcija
tolerira i QR payload s prefiksom `dgdj1:`.

```bash
export QR_TOKEN=<64-hex token Ane Anić iz §5>
curl -s -X POST $FN/events-checkin -H 'content-type: application/json' \
  -d '{"qr_token":"'$QR_TOKEN'"}' | jq                                  # → 401 not_authenticated
curl -s -X POST $FN/events-checkin -H "Authorization: Bearer $CLAN_JWT" \
  -H 'content-type: application/json' -d '{"qr_token":"'$QR_TOKEN'"}' | jq  # → 403 not_authorized

# prvi sken → checked_in:
curl -s -X POST $FN/events-checkin -H "Authorization: Bearer $ADMIN_JWT" \
  -H 'content-type: application/json' -d '{"qr_token":"dgdj1:'$QR_TOKEN'"}' | jq
# → {"status":"checked_in","serial":"MON-000001","holder_name":"Ana Anić",
#    "tier_title":"Super Early Bird","event_title":…,"checked_in_at":…,"checked_in_count":1}

# drugi sken ISTOG tokena → already_checked_in s vremenom i skenerom PRVOG ulaza (ništa se ne mijenja):
# → {"status":"already_checked_in","checked_in_at":<prvi ulaz>,"checked_in_by_email":"admin@momo.test",
#    "checked_in_count":1,…}

# krivi format → 400 {"error":"invalid_token"} ; nepoznat 64-hex → {"status":"not_found"}
```

Poništenje (organizator; samo `issued` → `void`) kroz psql kao org admin:

```sql
-- lpsql
begin;
select set_config('request.jwt.claims', '{"sub":"<ADMIN_ID>","role":"authenticated"}', true);
set local role authenticated;
select ulaznice.void_ticket('<TICKET_ID Ive Ivića>');   -- {"status":"voided","serial":…}
select ulaznice.void_ticket('<TICKET_ID Ane Anić>');    -- {"status":"already_checked_in",…} (ulaz se dogodio)
commit;
-- sken poništene ulaznice → {"status":"void"}; ponovni void → {"status":"already_void"}

-- audit (pokušaj dvostrukog ulaza preživi jer je ishod status, ne exception):
select event_type, payload from ulaznice.order_events
 where order_id = '<ORDER>' and event_type like 'ticket.%' order by id;
-- → ticket.checked_in, ticket.checkin_duplicate, ticket.voided
```

## 8. Nesparena onchain uplata — ukinuto

Nekadašnji rub (cron indexer kreditira isti `(tx_hash, log_index)` kao donaciju) ne postoji bez
onchain raila. Stripe ekvivalent je isti `external_ref` na dvije narudžbe → `tx_already_credited`
+ audit `ticket_order.match_conflict` (§11.5).

## 9. Organizator self-service

`events-organizer`: svaka akcija traži GoTrue JWT (bez njega 401); autorizacija je u RPC-ima.
`create_event`/`update_event`/`publish_event`/`delete_event_draft` su DEFINER s provjerom admina
računa (+ KYC kod kreiranja); `publish_event` dodatno allowlist + rail (odluka 352). Primjeri
koriste drugi račun `<ORG2>` (isti admin, KYC), na početku **bez allowliste i bez Stripe raila**.

```bash
org() { curl -s -X POST $FN/events-organizer -H "Authorization: Bearer $ADMIN_JWT" \
             -H 'content-type: application/json' -d "$1" | jq; }

# 9.1 pregled (računi gdje sam admin + allowlist/DAC7 status + moji eventi uklj. skice):
org '{"action":"overview"}'
# → {"accounts":[{"id":"<ORG2>","allowlisted":false,"has_record":false,…},…],"events":[…]}

# 9.2 kreiranje s galerijom (skica + private, ne vidi se u feedu):
export EV2=$(uuidgen | tr 'A-Z' 'a-z')
org '{"action":"create","event_id":"'$EV2'","account_id":"<ORG2>","title":"BlockSplit 2027",
  "venue_name":"MEDILS","venue_city":"Split","event_type":"kamp","description_hr":"Unconference.",
  "gallery":[{"url":"https://example.com/g1.jpg"},{"url":"https://example.com/g2.jpg"}],
  "tiers":[{"title":"Stay paket","price_cents":39900,"inventory_total":40,"imenska":true},
           {"title":"Dnevna","price_cents":5000,"inventory_total":100,"imenska":false}]}'
# → {"id":…, "slug":"blocksplit-2027", "existing":false, "event_created":true}
# lpsql: select jsonb_array_length(gallery), state from ulaznice.events where id='<EV2>';  → 2 | draft
#   (galerija ide drugim pozivom update_event(p_gallery) odmah nakon create_event)
# galerija s http:// URL-om → 400 {"error":"invalid_gallery_url"} (provjera prije ijednog pisa)

# 9.3 update galerije: prazna lista briše
org '{"action":"update","campaign_id":"'$EV2'","gallery":[]}'
# lpsql: select gallery from ulaznice.events where id='<EV2>';  → []

# 9.4 brisanje tiera na skici (remove_tier_ids; samo skica, samo bez narudžbi):
org '{"action":"update","campaign_id":"'$EV2'","remove_tier_ids":["<DNEVNA>"]}'   # → 200, ostao 1 tier
# tier s narudžbom → 400 {"error":"tier_has_orders"} (trigger ticket_tiers_write_guard, odluka 359)
# brisanje skice s narudžbom (action delete) → 400 {"error":"event_has_orders"}
#   Skica kroz API ne može dobiti narudžbu (create_ticket_order traži active); skripta je
#   za ovu provjeru umeće psql-om:
#   insert into ulaznice.orders (id, event_id, tier_id, amount_cents, currency, quantity, state, payment_rail)
#   values ('<HOLD>', '<EV2>', '<STAY>', 39900, 'eur', 1, 'pending', 'stripe');

# 9.5 publish gating:
org '{"action":"publish","campaign_id":"'$EV2'"}'
# → 400 {"error":"organizer_not_allowlisted"}
# operater: insert into ulaznice.organizer_allowlist (account_id, note) values ('<ORG2>', 'pilot');
org '{"action":"publish","campaign_id":"'$EV2'"}'
# → 400 {"error":"event_no_working_rail"} — plaćeni tier, a ORG2 nema Stripe Connect s charges_enabled
# (event ostaje skica). Brisanje skice bez narudžbi:
org '{"action":"delete","campaign_id":"'$EV2'"}'      # → {"campaign_id":…, "deleted":true}

# 9.6 samo besplatni tierovi → publish BEZ Stripe raila prolazi (odluka 352):
export EV3=$(uuidgen | tr 'A-Z' 'a-z')
org '{"action":"create","event_id":"'$EV3'","account_id":"<ORG2>","title":"Besplatni meetup",
  "venue_name":"Klub","venue_city":"Zagreb","tiers":[{"title":"Ulaz","price_cents":0,"inventory_total":30}]}'
org '{"action":"publish","campaign_id":"'$EV3'"}'     # → {"state":"active","visibility":"public"}

# 9.7 aktivni event (kupci su kupovali pod tim uvjetima):
#   remove_tier_ids                         → 409 {"error":"event_not_draft"}
#   promjena price_cents postojećeg tiera   → 400 {"error":"tier_locked"}
#   inventory_total < inventory_claimed     → 400 {"error":"inventory_below_claimed"}
#   novi plaćeni tier bez raila             → 400 {"error":"event_no_working_rail"} (odluka 357)
#   novi besplatni tier (bez "id")          → 200
org '{"action":"update","campaign_id":"'$EV3'","tiers":[{"title":"Ulaz 2","price_cents":0,"inventory_total":10}]}'

# 9.8 zatvaranje prodaje:
org '{"action":"publish","campaign_id":"'$EV3'","target_state":"closed"}'   # → {"state":"closed"}
# closed → closed → 400 {"error":"invalid_state_transition"}; zatvoreni event ispada iz feeda

# 9.9 DAC7 zapis organizatora (SENSITIVE; nikad u feedu):
org '{"action":"record_upsert","account_id":"<ORG2>","legal_name":"UBIK udruga","oib":"12345678903",
  "address_line":"Ulica 1","city":"Split","postal_code":"21000",
  "financial_identifier_type":"iban","financial_identifier":"HR1210010051863000160"}'
# → {"account_id":…, "saved":true}
# financial_identifier_type: iban | safe_address (DAC7 identifikator, ne rail plaćanja)
# RLS: PostgREST GET /rest/v1/organizer_records (Accept-Profile: ulaznice) kao drugi korisnik → []
#      kao admin računa → 1 red; anon → permission denied

# 9.10 bez prava:
#   create na tuđem računu (član, ne admin) → 400 {"error":"new"}  ← RLS poruka
#     'new row violates row-level security policy for table "events"' skraćena na prvu riječ;
#     ponašanje je isto kao prije (odluka 350), v. prijedlog u izvještaju S4/S5
#   publish/update/record_upsert ne-admina  → 403 {"error":"not_authorized"}
```

## 9b. Online event

`attendance_mode: "online"` je javno polje (feed ga vraća). Link (`online_url`, https ≤ 1000)
**nije** u `events` nego u `ulaznice.event_access`: anon ga ne vidi, admin računa ga čita u
editoru (RLS), service_role ga čita za kupca.

```bash
export EVO=$(uuidgen | tr 'A-Z' 'a-z')
org '{"action":"create","event_id":"'$EVO'","account_id":"<ORG2>","title":"Webinar",
  "attendance_mode":"online","online_url":"https://meet.example.com/webinar",
  "tiers":[{"title":"Online ulaz","price_cents":0,"inventory_total":500}]}'
# lpsql: select attendance_mode, venue_name, venue_city from ulaznice.events where id='<EVO>';
#        → online | Online | Online   (venue polja su NOT NULL; funkcija upiše „Online”)
# lpsql: select online_url from ulaznice.event_access where event_id='<EVO>';
# online_url bez https → 400 {"error":"invalid_online_url"}
org '{"action":"publish","campaign_id":"'$EVO'"}'

curl -s "$FN/events-feed?grad=Online" | jq '.events[] | {campaign_id, mode: .event.attendance_mode}'
# → attendance_mode "online"; online_url se NIGDJE u feedu ne pojavljuje
```

**Gdje kupac dobiva link** (isto kao prije sheme `ulaznice`): ni `events-order`, ni
`events-tickets`, ni `events-stripe-confirm` ga ne vraćaju. Šalje ga Worker `domovina-ulaznice`
u mailu s ulaznicama i prikazuje na stranici narudžbe `/ulaznice/{order_id}`, čitajući
`event_access` service ključem preko PostgREST-a:

```bash
curl -s "$API/rest/v1/event_access?event_id=eq.$EVO&select=online_url" \
  -H "apikey: $SERVICE_ROLE_KEY" -H "Authorization: Bearer $SERVICE_ROLE_KEY" \
  -H 'Accept-Profile: ulaznice' | jq
# → [{"online_url":"https://meet.example.com/webinar"}]
# anon → 401 (bez grantova); authenticated ne-admin → [] (RLS)
# brisanje linka: org '{"action":"update","campaign_id":"'$EVO'","online_url":""}' → online_url null
```

(Worker za to od S6 mora slati `Accept-Profile: ulaznice` i filtrirati `event_id` umjesto
`campaign_id` — v. `docs/ulaznice-shema/research/2026-11-25-inventura-potrosaci.md`.)

## 10. Feed filtriranje/paginacija

```bash
curl -s "$FN/events-feed?grad=zagreb" | jq '.events[].slug'      # case-insensitive substring venue_city
curl -s "$FN/events-feed?from=2027-01-01&to=2027-12-31" | jq     # prozor nad events.starts_at
curl -s "$FN/events-feed?limit=1&offset=1" | jq '.limit, .offset, (.events|length)'
# default limit 50, max 100 (limit=500 → 100); bez parametara: prvih 50
# samo state 'active' + visibility 'public' + nije obrisan (skica, closed i private ispadaju)
```

## 11. Stripe rail — offchain naplata narudžbe

> Funkcije `events-stripe-intent`, `events-stripe-confirm` (`verify_jwt=false` + **HMAC**,
> `_shared/ulaznice-hmac.ts`). RPC `confirm_ticket_order_offchain`, `refund_ticket_order`.

**Backend nikad ne razgovara sa Stripeom.** Stripe zove isključivo Cloudflare Worker
(`domovina-ulaznice`): Worker uzme podatke iz `events-stripe-intent`, kreira Checkout Session /
PaymentIntent kao **direct charge** na Connect računu organizatora (0 % provizije), verificira
webhook potpis i tek onda zove `events-stripe-confirm`.

### 11.0 HMAC

```
header:  x-ulaznice-signature: sha256=<hex(hmac_sha256(EVENTS_STRIPE_CONFIRM_SECRET, RAW_BODY))>
potpis:  nad SIROVIM tijelom (byte-for-byte), usporedba konstantnog vremena
bez tajne na serveru → 503 secret_not_configured (nikad "prolazi jer tajne nema")
bez headera → 401 missing_signature ; krivi potpis → 401 bad_signature ; baza se NE dira
```

Replay se ne brani timestampom: ponovljeni identičan zahtjev je no-op (idempotencija u bazi,
unique `ux_orders_external_payment` na `(payment_rail, external_payment_ref)`).
Lokalna tajna je u `supabase/functions/.env` (gitignored); skripta je čita odande ili iz
`EVENTS_STRIPE_CONFIRM_SECRET` u okolini i nikad je ne ispisuje.

### 11.1 Stripe stanje organizatora

`ulaznice.organizer_payment_rails` piše **samo service_role** (Worker iz `account.updated`);
lokalno psql-om kao u §1. RLS: anon → permission denied; admin računa vidi svoj red, ne smije ga
mijenjati.

### 11.2 Narudžba (isti `events-order` kao §3)

```bash
export SO=$(uuidgen | tr 'A-Z' 'a-z')
curl -s -X POST $FN/events-order -H 'content-type: application/json' -d '{
  "order_id":"'$SO'", "campaign_id":"'$EV'", "tier_id":"<REDOVNA>", "quantity":2,
  "holders":[{"full_name":"Web Kupac","email":"web@example.com"},{"full_name":"Drugi Gost"}]}' | jq
# → pending, amount_cents 29800, payment_rail stripe; rezervacija 20 min
```

### 11.3 `events-stripe-intent` — podaci za Checkout

```bash
spost $FN/events-stripe-intent '{"order_id":"'$SO'"}'
# → {"order_id":…, "amount_cents":29800, "currency":"eur", "quantity":2, "expires_at":…,
#    "buyer_email":null, "tier":{"id":…,"title":"Redovna","price_cents":14900,"imenska":true},
#    "event":{"campaign_id":…,"title":…,"slug":…,"starts_at":…,"ends_at":…,
#             "timezone":"Europe/Zagreb","venue_name":…,"venue_city":…},
#    "stripe_account_id":"acct_1TestOrganizator",   ← JEDINI odgovor koji ga vraća
#    "charges_enabled":true, "invoice_provider":"fira"}

# bez potpisa → 401 missing_signature ; krivi → 401 bad_signature
# nepostojeća narudžba               → 404 {"error":"order_not_found"}
# već plaćena                         → 400 {"error":"order_not_pending","state":"paid"}
# istekla rezervacija                 → 400 {"error":"order_not_pending","state":"expired"}
#   (funkcija prvo pokrene expire_stale_ticket_orders; "order_expired" ostaje samo za utrku)
# organizator bez charges_enabled     → 400 {"error":"organizer_charges_disabled"}
# organizator bez acct_…              → 400 {"error":"organizer_not_connected"}
```

Invariant: bez povezanog računa i bez `charges_enabled` Checkout se **nikad** ne kreira; `acct_…`
ne izlazi nigdje drugdje (feed ga nema).

### 11.4 `events-stripe-confirm` — kreditiranje + izdavanje ulaznica

```bash
CB='{"order_id":"'$SO'","external_ref":"pi_HTTP_1","amount_cents":29800,"payer_email":"web@example.com"}'

# krivi / nedostajući potpis PRVO — baza mora ostati netaknuta:
curl -s -X POST $FN/events-stripe-confirm -H 'content-type: application/json' \
  -H "x-ulaznice-signature: sha256=$(printf 'a%.0s' {1..64})" --data-binary "$CB" | jq   # → 401 bad_signature
# lpsql: select state, external_payment_ref from ulaznice.orders where id='<SO>';  → pending | null, 0 ulaznica

spost $FN/events-stripe-confirm "$CB"
# → {"ok":true,"status":"paid","order_id":…,"serials":["MON-000005","MON-000006"],
#    "tickets":[{"serial":…,"holder_name":"Web Kupac","holder_email":"web@example.com",
#                "state":"issued","qr_token":"<64-hex>"}, …]}

spost $FN/events-stripe-confirm "$CB"
# → {"ok":true,"status":"already_paid","serials":[…isti…],"tickets":[{…,"qr_token":null},…]}
# lpsql: select count(*), count(qr_token_once) from ulaznice.tickets where order_id='<SO>';  → 2 | 0
```

⚠️ QR tokeni su jednokratni: `events-stripe-confirm` ih povlači kroz `deliver_ticket_orders` i na
`already_paid` (crash recovery: ako odgovor nije stigao do Workera, retry webhooka ih još dobije),
ali nakon prve **uspješne** dostave `qr_token` je zauvijek `null`.

### 11.5 Poslovni ne-uspjesi: HTTP 200 + `status` (nikad exception)

Exception bi rollbackao audit u `ulaznice.order_events`; Worker na svaki status reagira
(refund / alarm / ručno sparivanje).

```bash
# premali iznos:
spost $FN/events-stripe-confirm '{"order_id":"'$SO2'","external_ref":"pi_HTTP_2","amount_cents":100}'
# → {"ok":true,"status":"amount_insufficient","expected_cents":14900,"received_cents":100}  audit ticket_order.underpaid

# isti external_ref na DRUGOJ narudžbi:
spost $FN/events-stripe-confirm '{"order_id":"'$SO2'","external_ref":"pi_HTTP_1","amount_cents":14900}'
# → {"ok":true,"status":"tx_already_credited"}   audit ticket_order.match_conflict (other_contribution_id)

# druga uplata na VEĆ plaćenu narudžbu (dvije checkout sesije):
spost $FN/events-stripe-confirm '{"order_id":"'$SO'","external_ref":"pi_HTTP_3","amount_cents":29800}'
# → {"ok":true,"status":"duplicate_payment","credited_ref":"pi_HTTP_1"}  audit ticket_order.duplicate_payment → Worker refunda

# istekla rezervacija + tier u međuvremenu pun (tier „Mala”, inventory 1):
#   narudžba A → istek (reserve_expires_at u prošlost) → narudžba B uzme mjesto → kasna uplata za A:
# → {"ok":true,"status":"expired_sold_out"}   audit ticket_order.expired_sold_out → Worker radi PUN REFUND
#   (istekla narudžba s uplatom se inače re-rezervira i postaje paid, ako mjesta ima)
```

Rubovi RPC-a (psql):

```sql
-- lpsql
set role service_role;
select ulaznice.confirm_ticket_order_offchain('<SO2>'::uuid, 'onchain', 'pi_X_123', 1, null);  -- ERROR invalid_rail
select ulaznice.confirm_ticket_order_offchain('<SO2>'::uuid, 'stripe', 'x', 1, null);          -- ERROR invalid_external_ref
reset role;
set role authenticated;
select ulaznice.confirm_ticket_order_offchain('<SO2>'::uuid, 'stripe', 'pi_Y_123', 1, null);
-- → ERROR permission denied for function confirm_ticket_order_offchain
reset role;
-- idempotencija je u BAZI:
update ulaznice.orders set external_payment_ref = 'pi_HTTP_1' where id = '<SO2>';
-- → ERROR duplicate key value violates unique constraint "ux_orders_external_payment"
-- dodatno u ulaznice: rail 'stripe' na narudžbi od 0 € → ERROR invalid_rail (CHECK orders_amount_free)
```

### 11.6 Onchain put — ukinut

Nekadašnja provjera „onchain put ostaje nepromijenjen” otpada (odluka 110): `orders` dopušta
`payment_rail = 'onchain'` samo za istekle narudžbe (povijest), `events-confirm` vraća 410,
`events-order` s `payer_address` vraća 400 `onchain_rail_removed`.

### 11.7 Povrat plaćene narudžbe (`refund_ticket_order`)

Zove ga **samo Worker** (service_role, PostgREST) nakon što je Stripe povrat izveden.
`void_ticket` za ovo ne služi (traži `auth.uid()` admina; Worker ga nema), a povrat je jedna
transakcija nad narudžbom, ulaznicama, inventoryjem i auditom.

```bash
curl -s -X POST "$API/rest/v1/rpc/refund_ticket_order" \
  -H "apikey: $SERVICE_ROLE_KEY" -H "Authorization: Bearer $SERVICE_ROLE_KEY" \
  -H 'Content-Profile: ulaznice' -H 'content-type: application/json' \
  -d '{"p_order_id":"'$SO'","p_reason":"organizator","p_external_ref":"re_…"}' | jq
# → {"status":"refunded","voided":2,"kept_checked_in":0}; narudžba refunded, ulaznice void,
#   inventory se vraća u prodaju, audit ticket_order.refunded
# ponovno → {"status":"already_refunded",…}; pending narudžba → {"status":"not_paid"}
#   (+ audit ticket_order.refund_unexpected); nepostojeća → not_found
# ulaznica na kojoj je netko VEĆ UŠAO ostaje checked_in i njezino mjesto se ne vraća
#   (narudžba iz §3 → kept_checked_in 1)
# anon → 401 (execute samo service_role)
```

### 11.8 Ručni koraci za S6 (traže pravi Stripe; skripta ih ne izvodi)

1. **Checkout / PaymentIntent na Connect računu** — Worker s odgovorom `events-stripe-intent`
   (`stripe_account_id`, iznos, valuta) kreira Checkout Session kao direct charge
   (`Stripe-Account: acct_…`) u test modu; provjeriti da je naplata na računu organizatora,
   0 % provizije.
2. **Webhook → `events-stripe-confirm`** — stvarna `checkout.session.completed` /
   `payment_intent.succeeded` dostava (Stripe CLI `stripe trigger` ili test kartica 4242…):
   Worker verificira Stripe potpis, potpisuje tijelo HMAC-om i dobiva `paid` + QR tokene;
   ponovljena dostava istog eventa → `already_paid`.
3. **Povrat** — refund u Stripeu pa `refund_ticket_order` iz Workera (§11.7); Worker reagira na
   `duplicate_payment` / `expired_sold_out` stvarnim povratom.
4. **`account.updated`** — Worker upisuje `organizer_payment_rails` (charges_enabled true/false);
   provjeriti da `publish` (odluka 352) i `events-stripe-intent` prate stanje.
5. **Produkcijska tajna** — ista vrijednost `EVENTS_STRIPE_CONFIRM_SECRET` u edge runtimeu i u
   `wrangler secret` Workera; smoke: `curl -s -o /dev/null -w '%{http_code}' -X POST
   https://api.domovina.ai/functions/v1/events-stripe-confirm -d '{}'` → `401` (ne 200, ne 503).

## Deploy (prod — ručni korak, tek u S6)

Redoslijed i vrata su u `docs/ulaznice-shema/plan.md` (S6) i
`docs/ulaznice-shema/research/2026-11-25-pgrst-db-schemas.md`. Ukratko:

```bash
./scripts/db-migrate.sh --dry-run    # ⚠ povukao bi i ulaznice migracije: ne prije S6
# S6: migracije 20261125150000–170000 → PGRST_DB_SCHEMAS += ulaznice → funkcije
for f in events-order events-confirm events-tickets events-checkin events-organizer \
         events-stripe-intent events-stripe-confirm; do
  ./scripts/deploy-functions.sh --only=$f
done
./scripts/deploy-functions.sh --only=events-feed --restart -y
```

`EVENTS_STRIPE_CONFIRM_SECRET` mora biti u env-u edge runtimea prije funkcija (bez nje 503).
