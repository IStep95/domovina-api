# Inventura potrošača ticketinga u `pinka_finance` (read-only, 2026-11-25)

Kratice repoa: **api** = `domovinatv/domovina-api` (main, a871b65), **ul** = `domovinatv/domovina-ulaznice` (`ivan/main`),
**safe** = `safe-global/safe-wallet-monorepo`, **cc** = `domovinatv/campaign-core`, **cf** = `domovinatv/crowdfund.domovina.ai`.
Putanje edge funkcija su relativne na `supabase/functions/`.

---

## 1. Edge funkcije u domovina-api

### 1a. `events-*` (8 funkcija)

Zajedničko: svaka radi `createClient(SUPABASE_URL, …)` i eksplicitno `.schema("pinka_finance")`. Nijedna ne koristi
storage. Nijedna ne zove Stripe ni mail izravno (Stripe zove Worker, `events-stripe-intent/index.ts:7`).

| Funkcija | Ključ / auth | Čita | Piše (RPC) | Env | Vanjsko |
|---|---|---|---|---|---|
| events-feed | SERVICE (api:events-feed/index.ts:22-23) | `campaigns` + embed `events!inner(...)` + `campaign_tiers(...)`, filtri `type='tickets'`, `visibility='public'`, `state in (active,funded)`, `deleted_at is null` (api:events-feed/index.ts:40-54); filtri na `events.venue_city/starts_at` (:57-59) | — | SUPABASE_URL, SERVICE_ROLE | — |
| events-checkin | ANON + korisnički JWT (api:events-checkin/index.ts:17-18) | — | RPC `redeem_ticket(p_qr_token)` (:47-49) | SUPABASE_URL, ANON | — |
| events-order | ANON (create) + SERVICE (besplatne) (api:events-order/index.ts:25-27) | — | RPC `create_ticket_order` (:68-69), `confirm_ticket_order_offchain` (:90), `deliver_ticket_orders` (:101) | URL, SERVICE, ANON | — |
| events-confirm | SERVICE (api:events-confirm/index.ts:18-19) | `contributions` (id,state,amount_cents,destination_address,tier_id,reserved,forward_tx_hash,onchain_log_index) (:47-52) | RPC `confirm_ticket_order` (:90-97) | URL, SERVICE, GNOSIS_RPC_URL, EURE_CONTRACT, RAIL_SAFE_ADDRESS (:20-23) | Gnosis JSON-RPC `fetch(RPC)` (:106) |
| events-stripe-intent | SERVICE + HMAC (`EVENTS_STRIPE_CONFIRM_SECRET`) (api:events-stripe-intent/index.ts:20-22) | `contributions` (:49-52), `campaign_tiers` (:66), `campaigns` (:68), `events` (:70), `organizer_payment_rails` (stripe_account_id, stripe_charges_enabled, invoice_provider) (:76-78) | RPC `expire_stale_ticket_orders` (:46) | URL, SERVICE, SECRET | — (vraća Workeru `order_id`, `tier.id`, `event.campaign_id`, `slug`, `stripe_account_id` (:85-107)) |
| events-stripe-confirm | SERVICE + HMAC (api:events-stripe-confirm/index.ts:27-29) | — | RPC `confirm_ticket_order_offchain(p_rail='stripe', …)` (:71-77), `deliver_ticket_orders` (:92-93) | URL, SERVICE, SECRET | — (ulaz: `order_id`, `external_ref`, `amount_cents`, `payer_email` (:45-50)) |
| events-tickets | SERVICE (api:events-tickets/index.ts:16-17) | — | RPC `deliver_ticket_orders(p_order_ids)` (:37-39) | URL, SERVICE | — |
| events-organizer | ANON + korisnički JWT (api:events-organizer/index.ts:35-36) | `campaigns.state` (:71) | RPC preko `rpc()` helpera (:67): `organizer_overview` (:94), `create_event` (:103), `update_event` (:140), `delete_event_draft` (:165), `publish_event` (:172), `upsert_organizer_record` (DAC7) (:181); izravno `campaign_tiers` DELETE (:74), `events` UPDATE (:81), `event_access` UPSERT (:85-87) | URL, ANON | — (prima `cover_image_url` kao string, https ≤1000 (:117, :153, :202) — upload radi klijent) |

**Što bi se slomilo / promjena:** svih 8 ima tvrdo `.schema("pinka_finance")` + stara imena tablica (`campaigns`,
`campaign_tiers`, `contributions`) → svaka linija gore se mijenja u `.schema("ulaznice")` + nova imena. Ulazni/izlazni
HTTP ugovor (`order_id`, `campaign_id`, `tier.id`, `qr_token`) ostaje isti ako UUID-ovi ostaju isti. `ulaznice` shema
mora biti u PostgREST `db-schemas` (`PGRST_DB_SCHEMAS`) jer i supabase-js `.schema()` ide kroz PostgREST.
`events-feed` filtar `.eq("type","tickets")` (:51) postaje suvišan. `events-stripe-intent` čita
`organizer_payment_rails` — treba odlučiti ostaje li u `pinka_finance` (dijeljena s donacijama?) ili seli.

### 1b. `_shared`

| Datoteka | Veza s ticketingom | Napomena |
|---|---|---|
| `_shared/ulaznice-hmac.ts` | HMAC gate za events-stripe-* (api:_shared/ulaznice-hmac.ts:1-5) | bez DB, ne mijenja se |
| `_shared/cors.ts` | koriste events-feed/checkin/tickets | ne mijenja se |
| `_shared/sponsor.ts` | NE (sponzorski trenuci): `pinka_finance.sponsor_invoice_lease/record`, `contributions`, `campaigns` (api:_shared/sponsor.ts:83-94, 257-258, 323-333); Resend (:26-28, :345) | ne dira ulaznice |
| `_shared/og-image-cache.ts` | NE: bucket `pinka-og-cache` (api:_shared/og-image-cache.ts:2, :53-62) + RPC `set_contribution_link_preview_image` (:80) — za link-preview doprinosa | ticketing ne koristi og cache |
| `_shared/guest.ts` | RPC `pinka_finance.guest_rate_hit` (api:_shared/guest.ts:63), Turnstile | koristi ga pinka-contribute, ne events-* (nijedan `events-*` ne importa guest) |

### 1c. `pinka-*` funkcije — grane za ticketing

Nijedna nema eksplicitnu `type='tickets'` granu (grep `tickets|ticket|tier|reserved` samo `p_tier_id` u
api:pinka-contribute/index.ts:165). Ali postoje **implicitne** veze:

| Funkcija | Što dira | Veza s ulaznicama | Što bi se slomilo / promjena |
|---|---|---|---|
| pinka-onchain-ingest GET | `campaigns` (id, destination_address) gdje public + active/funded, **bez filtra po `type`** (api:pinka-onchain-ingest/index.ts:30-41) | watchlist indexera danas uključuje Safe adrese ticket kampanja | nakon seljenja ticket Safeovi ispadaju iz watchliste (poželjno; kreditiranje ide kroz events-confirm). Provjeriti da indexer nema svoju kopiju liste. |
| pinka-onchain-ingest POST | `campaigns` mapiranje adresa→id bez filtra (:70-78), RPC `record_onchain_contribution` (:94-101) | danas uplata na Safe eventa može biti kreditirana kao generička donacija; `confirm_ticket_order` to izričito tretira (api:supabase/migrations/20260716120200_events_ticketing_rpcs.sql:501-506) | nakon seljenja nema mapiranja → `no_campaign` (ispravno). Generičke donacije već upisane na ticket kampanje (ako ih ima) ostaju u `pinka_finance.contributions` s `campaign_id` eventa — FK/čišćenje u S2. |
| pinka-onchain-confirm | `campaigns` po id (api:pinka-onchain-confirm/index.ts:44-50), RPC `confirm_slot_contribution` / `record_onchain_contribution` (:75-83) | može se pozvati s campaign_id eventa | nakon seljenja → `unknown_campaign` 404 (ispravno) |
| pinka-contribute | RPC `create_contribution(p_tier_id)` / `create_sponsor_contribution`, `attach_intent`, slot holds (api:pinka-contribute/index.ts:137-217) | ne za ulaznice (ulaznice idu kroz `create_ticket_order`) | ništa; provjeriti da `create_contribution` odbija `type='tickets'` danas (SQL, nije u opsegu) |
| pinka-webhook | `record_sepa_contribution`, `mark_contribution_paid`, `og.image_backfill` nad `contributions` (api:pinka-webhook/index.ts:58-188) | ulaznice nemaju SEPA/Monerium rail | ništa |
| pinka-link-preview | `pinka-og-cache` (api:pinka-link-preview/index.ts:12) | samo linkovi u porukama doprinosa | ništa |

**QR (za točku 5):** token je slučajnih 32 bajta hex (api:supabase/migrations/20260716120200_events_ticketing_rpcs.sql:559),
u bazi trajno samo `qr_token_hash` = sha256 (:571; schema 20260716120000_events_ticketing_schema.sql:126), plaintext
`qr_token_once` samo do prve dostave (:589-643). QR payload = `dgdj1:<64 hex>` (api:events-checkin/index.ts:20-21).
QR **ne sadrži nijedan UUID** → kopija `qr_token_hash` 1:1 pokriva sve izdane ulaznice.

---

## 2. domovina-ulaznice (`ivan/main` = 3ca4908)

Grane: `ivan/main` 3ca4908 / 15be170 / 691edc5; lokalni `main` 0f4ea7f / c65f348 / 5594dfd. Lokalni `main` je
**~45 commita iza** `ivan/main` (`git log main..ivan/main`), ništa ispred (`ivan/main..main` prazno). Checkoutana je
`feat/prijava-google`. Sve dolje je s `ivan/main` (pročitano `git show`/`git grep`, bez checkouta; `git fetch ivan` je
povukao 691edc5..3ca4908).

### 2a. `worker/api.ts` — izravni pozivi prema api.domovina.ai

Helperi: `rest()` = GET `/rest/v1/<path>` sa **service ključem** i `Accept-Profile: pinka_finance` (ul:worker/api.ts:85-96);
`restRpc()` = POST `/rest/v1/rpc/<fn>` sa service ključem i `Content-Profile: pinka_finance` (:103-112);
`korisnickiRpc()` / `korisnickiRest()` = isto, ali korisnikovim JWT-om (:496-507, :519-524); `callFunction()` =
POST `/functions/v1/<name>` samo s `apikey` (:38-65).

| Poziv (ul:worker/api.ts) | Metoda | Cilj u `pinka_finance` | Ključ |
|---|---|---|---|
| `bezSkrivenih` :281-290 | GET | `campaigns?select=id,account_id&id=in.(…)&account_id=in.(…)` | service |
| `organizerRail` :331-355 | GET | `campaigns?select=id,account_id&id=eq.…` (:342), `organizer_payment_rails?select=stripe_account_id,stripe_charges_enabled,invoice_provider…` (:352) | service |
| `onlineLink` :315-320 | GET | `event_access?campaign_id=eq.…&select=online_url` | service |
| `orderStatus` :367-384 | GET | `contributions?select=id,campaign_id,tier_id,state,quantity,amount_cents,currency,reserve_expires_at,payment_rail,external_payment_ref,buyer_email,paid_at,holders&id=eq.…` (:373), `tickets?select=serial,holder_name,state,checked_in_at&contribution_id=eq.…` (:380) | service |
| `rotate…` :396-403 | POST rpc | `rotate_ticket_tokens(p_order_id)` | service |
| `refundOrder` :705-714 | POST rpc | `refund_ticket_order(p_order_id,p_amount_cents,p_reason,p_external_ref)` | service |
| `upsertOrganizerRail` :717-735 | PATCH | `organizer_payment_rails?stripe_account_id=eq.…` (stripe_charges_enabled, stripe_payouts_enabled) s `Content-Profile: pinka_finance` (:729) | service |
| `ucitajSliku` :662-694 | POST storage | `/storage/v1/object/pinka-covers/{uid}/{uuid}.{ext}` (:671), vraća javni URL `…/object/public/pinka-covers/…` (:694); ograničenja bucketa preslikana (:635-643) | korisnički JWT |
| korisnickiRpc iz ul:worker/index.ts:664-668 | POST rpc | `organizer_overview` | JWT |
| korisnickiRest iz ul:worker/index.ts:685-697 | GET | `tickets?select=serial,holder_name,holder_email,state,checked_in_at&campaign_id=eq.…` (CSV holdera) | JWT |
| korisnickiRest iz ul:worker/index.ts:764-775 | GET | `campaigns?id=eq.…&type=eq.tickets&select=id,account_id,slug,title,state,events(…cover_image_url,gallery…,attendance_mode),event_access(online_url),campaign_tiers(…)` (učitavanje skice za uređivanje), s fallbackom bez `attendance_mode`/`event_access` (:776-778) | JWT |

Edge funkcije koje Worker zove (ugovor ostaje): `events-feed` GET (:253-257), `events-order` (:304),
`events-stripe-intent` (HMAC, :307), `events-stripe-confirm` (HMAC, :312), `events-tickets` (:328, samo iz dostave),
`events-checkin` s JWT-om (:553-554), `events-organizer` s JWT-om (:598-604).

**Što bi se slomilo:** svaki gornji PostgREST poziv (8 mjesta + 3 iz index.ts) — profil `pinka_finance` i imena
`campaigns`/`contributions` (+ embed imena `events(…)`, `campaign_tiers(…)`, `event_access(…)`, filtar `type=eq.tickets`).
Ako se profil promijeni a tablice preimenuju (`events`, `orders`, `tiers`…), PostgREST embedovi u :764-775 se mijenjaju
po FK imenima. `ucitajSliku` → `ulaznice-media` (i test). `rotate_ticket_tokens`, `refund_ticket_order` moraju postojati
u `ulaznice`. **Prijelazni rizik:** Worker i jezgra deployaju se odvojeno (Ivan sam deploya Worker) — između deploya
jedan od njih gađa krivu shemu. Treba ili kompatibilni prijelaz (view-ovi u `pinka_finance` ili Worker s fallbackom),
ili strogo koordiniran redoslijed.

### 2b. `worker/index.ts` — rute, Stripe webhook, D1

Rute (ul:worker/index.ts): `/api/dogadjaji` :194, `/api/dogadjaj/:slug` :209 (čita D1 `event_pages` po
`campaign_id` :219), `/api/narudzba` POST :232, `/api/ulaznice/:order_id` :351 (D1 :360), `…/ponovna-dostava` :430,
`…/preuzmi` :510 (D1 `pending_deliveries` DELETE :539, `sent_emails` INSERT :540-541), `/api/organizator/{prijava,google,kod,potvrdi,pregled,holderi.csv,dogadjaj,dogadjaj/:id (GET/PUT/DELETE),slika}` :578-833,
`/api/skener/sken` :849, `/webhook/stripe` :870.

D1 `domovina-ulaznice` (ul:wrangler.jsonc:47-50; staging `domovina-ulaznice-staging` :103-106) — tablice i ID-jevi:

| D1 tablica | ID iz jezgre | Izvor |
|---|---|---|
| `webhook_events` | `order_id` (UUID iz Stripe metadata), `id` = Stripe `evt_…` | ul:migrations/0001_init.sql:13-21 |
| `sent_emails` | `order_id` | :30-39 |
| `payment_log` | `order_id`, `stripe_account`, `payment_intent` | :46-55 |
| `event_pages` | `campaign_id` PK „= pinka_finance.campaigns.id”, `slug`, `logo_url`, `hero_url` | :60-71 |
| `pending_deliveries` | `order_id` PK | :77-83 |
| `invoices` | `order_id` | ul:migrations/0002_racuni_i_alarmi.sql:19-30 |
| `alarms` | — | 0002 :39 |

Svi ID-jevi u D1 su `contributions.id` (narudžba) ili `campaigns.id` (event) → pokriveni odlukom „isti UUID-ovi”.
`event_pages.logo_url/hero_url` su slobodni URL-ovi — **ako** pokazuju na `pinka-covers`, prepisivanje URL-ova u bazi ih
neće uhvatiti (provjeriti sadržaj D1 prod i staging).

### 2c. Stripe, mail, QR, računi (Worker strana)

- Stripe Checkout (direct charge na organizatorov `acct_`): `metadata: { order_id, campaign_id }` i na sessionu i na
  `payment_intent_data` (ul:worker/stripe.ts:135-137); `success_url` = `${base}/ulaznice/${orderId}?placeno=1` (:138),
  `cancel_url` = `${base}/dogadjaj/${eventSlug}?otkazano=1` (:139). Webhook čita samo `metadata.order_id`
  (ul:worker/webhooks.ts:122-124, :477-478); `campaign_id` iz narudžbe kroz `orderStatus` (:388-390, :425).
- Mail: link `orderUrl` („Pregled narudžbe”, ul:worker/mail.ts:140) i online link iz `event_access` (:134; webhooks.ts:437).
  Nema slika iz `pinka-covers` u mailu (grep `cover|hero|logo` u mail.ts prazan).
- QR: `dgdj1:` + token (ul:worker/qr.ts:14, :24-64) — isti format kao jezgra, bez UUID-a.
- Fira račun: `webshopOrderId = parseInt(order_id bez crtica [0:12], 16)` (ul:worker/racun-fira.ts:63-64, :91) i
  `internalNote` s `order_id` (:147) → deterministički iz UUID-a narudžbe; isti UUID = isti broj.
- `SKRIVENI_ORGANIZATORI` (ul:wrangler.jsonc:79) je `public.accounts.id` — ne mijenja se, ali `bezSkrivenih` traži
  `account_id` na tablici eventa.

### 2d. `web/src`, `mobile/`, `worker-tests/`, `seeds/`

| Dio | Čita / piše | Što bi se slomilo / promjena |
|---|---|---|
| web/src | ne zove Supabase izravno (grep `supabase|/rest/v1|createClient` prazan); upload ide kroz Worker `POST /api/organizator/slika` (ul:web/src/lib/slika.ts:5, ul:web/src/lib/auth.ts:288) | samo komentari s `pinka-covers` (ul:web/src/components/NoviDogadjaj.tsx:736). **Nacrt u localStorageu** drži URL-ove slika (`galerija`, `slika`) (ul:web/src/lib/nacrt.ts:80-92, NoviDogadjaj.tsx:763) — nespremljeni nacrti s `pinka-covers` URL-ovima puknu ako se objekti obrišu. |
| mobile (iOS/Android) | samo Worker `/api/*` (ul:mobile/ios/Ulaznice/Net/ApiClient.swift:1-57, ul:mobile/android/.../data/ApiClient.kt:1-38); lokalno pamti order ID-jeve (`OrderStore`) | ništa dok UUID-ovi ostaju isti |
| worker-tests | harness mocka storage `pinka-covers` (ul:worker-tests/harness/env.ts:72, :121); test putanje (ul:worker-tests/organizator.test.ts:334-342) | testovi se mijenjaju uz `ucitajSliku` |
| seeds | `insert into pinka_finance.{campaigns,campaign_tiers,events,organizer_payment_rails}` i `pinka_finance.create_event` (seeds/demo-dom-sportova.sql:57, prilika-za-susret-2026.sql:209, staging-web-pregled.sql:76, susret-zagreb-2027.sql:83; ukupno 32 pojave) | seedovi se prepisuju na `ulaznice` |

---

## 3. safe-wallet-monorepo `apps/mobile/src/custom/events` (grana `custom`, dc61b860c)

Zove **samo edge funkcije**, nikad PostgREST izravno. Bazni URL iz branda `events.apiBaseUrl`
(safe:apps/mobile/src/custom/events/api/config.ts:8-11).

| Poziv (safe:apps/mobile/src/custom/events/api/client.ts) | Funkcija | ID-jevi |
|---|---|---|
| `fetchEventsFeed` :79-80 | `events-feed` | čita `campaign id`, `tier id`, `cover_image_url` (catalog/backendSource.ts:74, api/types.ts:30) |
| `submitTicketOrder` :97-98 | `events-order` | `order_id` generira klijent (`randomUuid`, api/useTicketSync.ts:30) |
| `confirmTicketOrder` :119-122 | `events-confirm` | `{order_id, tx_hash}` |
| `checkinTicket` :142-143 | `events-checkin` | QR token |
| organizer akcije :165-230 (`overview/create/update/publish/record_upsert`) | `events-organizer` | `campaign_id` (:220) |
| `fetchBackendOrders` :232-238 | `events-tickets` | `{order_ids}` |

Lokalno (MMKV `events`, state/useTickets.ts:51; `events-entry-log`, state/useEntryLog.ts:35) pamti order UUID-ove,
tx hash i QR tokene. Katalog tipovi izričito kažu „pinka_finance.campaigns.id / campaign_tiers.id”
(catalog/types.ts:37, :64) — samo komentar.

| Čita | Piše | Što bi se slomilo | Promjena |
|---|---|---|---|
| events-feed, events-tickets, organizer overview | events-order, events-confirm, events-checkin, events-organizer | ništa ako HTTP ugovor i UUID-ovi ostanu; `cover_image_url` stiže iz baze (prepisan URL radi) | nijedna (komentari opcionalno) |

Usput: `custom/donations` koristi `PINKA_SCHEMA='pinka_finance'` (safe:apps/mobile/src/custom/donations/api/config.ts:30)
za `active_campaign_for_subject` i `contribution_status` (donations/api/pinkaClient.ts:56, :106) — donacije, ne ulaznice.

---

## 4. campaign-core i crowdfund.domovina.ai

### campaign-core (main, 0bc0069) — biblioteka, bez pristupa bazi

| Čita | Piše | Što bi se slomilo | Promjena |
|---|---|---|---|
| ništa u runtimeu (grep `supabase|fetch(|rest/v1` u `src/` prazan). `fromPinkaCampaignType('tickets')→'tickets'` (cc:src/mapping.ts:31-35) i obrnuto (:75-79); `CAMPAIGN_TYPES` uključuje `tickets` (cc:src/sets.ts:19) | — | ništa u runtimeu. **Ugovor:** `contract/pinka-columns.json` je snimka `pinka_finance` (cc:scripts/snapshot-pinka.sh:13) s tablicama `events`, `tickets`, `organizer_payment_rails` (cc:contract/pinka-columns.json:617, :1212, :738); `src/contract.ts` mapira na `campaign_tiers.sale_start/sale_end` (cc:src/contract.ts:216-217), stupce koje je dodala ticketing migracija (api:supabase/migrations/20260716120000_events_ticketing_schema.sql:81-83), i `contributions.tier_id/quantity` (cc:src/contract.ts:313-314) | ako S7 iz `pinka_finance` obriše ticketing tablice/stupce, sljedeći `snapshot-pinka.sh` + contract test pada na `sale_start/sale_end`. Ili ne brisati te stupce iz `pinka_finance`, ili ažurirati campaign-core. Mapiranje `tickets` tipa može ostati (jezgra ima vlastiti tip). |

### crowdfund.domovina.ai (main, 95102fc) — vlastiti D1, ne čita `pinka_finance`

`src/lib/db/kampanja.ts` čita D1 (`db.prepare(SELECT … c.type …)`, cf:src/lib/db/kampanja.ts:151-160), tip uključuje
`tickets` (:35; cf:migrations/0001_core.sql:9). Grep `pinka_finance|Accept-Profile|/rest/v1|events-feed|functions/v1`
po `src`, `scripts`, `wrangler*` prazan. **Ne bi se slomio** — njegove „tickets” kampanje su lokalni D1 podaci
(seed: cf:scripts/seed.mjs:181-221), nevezani za ulaznice.domovina.ai.

### Ostali repoi (grep `pinka-covers|events-feed|type=eq.tickets`)

- `domovinatv/*` ostali repoi: nema pogodaka osim `domovina-api-maksimir-chain` — to je drugi klon istog
  `domovinatv/domovina-api` (origin isti, HEAD bf52804) → ista promjena, pazi da se ne deploya stara kopija.
- `pinkainc/*`: nema pogodaka.
- api:supabase/config.toml:18 `schemas = ["public","domovina_ai","pinka_finance","storage","graphql_public"]` — dodati
  `ulaznice` (lokalno), i u prod Coolify `PGRST_DB_SCHEMAS` (inače svi `Accept-Profile: ulaznice` vraćaju 406).
- api:scripts/storage-r2-switch.sh:13, :28 — verifikacijski URL je objekt u `pinka-covers`
  (`13e991a8-…/28a69cc0-….png`); ako je to objekt eventa koji se briše, skripta „pada”. Provjeriti vlasnika.

---

## 5. ID-jevi izvan baze — pokriva li „isti UUID-ovi”?

| Gdje | Koji ID / podatak | Izvor | Pokriveno istim UUID-ovima? |
|---|---|---|---|
| Stripe Checkout session + PaymentIntent metadata (na organizatorovom `acct_`) | `order_id` (= contributions.id), `campaign_id` (= campaigns.id) | ul:worker/stripe.ts:135-137 | **Da**. Webhook koristi samo `order_id` (ul:worker/webhooks.ts:122, :478). |
| Stripe `success_url` / `cancel_url` | `/ulaznice/{order_id}`, `/dogadjaj/{slug}` | ul:worker/stripe.ts:138-139 | Da (UUID), slug mora ostati isti (kopirati `slug`). |
| Stripe `external_payment_ref` (pi_…) u narudžbi | Stripe ID | api:events-stripe-confirm/index.ts:47 | Da, ako se kopira stupac. |
| `organizer_payment_rails.stripe_account_id` | `acct_…` po `account_id` | ul:worker/api.ts:352, :723 | Nije UUID-pitanje: odluka gdje tablica živi. Worker je PATCH-a po `stripe_account_id`. |
| QR | `dgdj1:` + 64 hex slučajni token, u bazi `qr_token_hash` | api:events-checkin/index.ts:20-21; api:…ticketing_rpcs.sql:559-571 | **Da, ako se `qr_token_hash` kopira 1:1** (i `qr_token_once` za još nedostavljene). Nema UUID-a u QR-u. |
| Mail ulaznica | `orderUrl` = `/ulaznice/{order_id}`, online link iz `event_access` | ul:worker/mail.ts:134, :140 | Da. Već poslani mailovi rade dok `order_id` ostaje isti. |
| Fira račun | `webshopOrderId` = prvih 12 hex znakova `order_id`, `internalNote` s `order_id` | ul:worker/racun-fira.ts:63-64, :91, :147 | Da (deterministički iz UUID-a). |
| D1 Workera (`webhook_events`, `sent_emails`, `payment_log`, `pending_deliveries`, `invoices`) | `order_id` | ul:migrations/0001_init.sql:17,32,48,78; 0002:20 | Da. |
| D1 `event_pages` | `campaign_id` PK, `slug`, **`logo_url`, `hero_url`** | ul:migrations/0001_init.sql:62-71; ul:worker/index.ts:219 | ID da; **URL-ovi slika NE** (nisu u bazi koju S2 prepisuje). |
| Mobilne app (iOS/Android Worker klijent; safe-wallet MMKV) | order UUID-ovi, QR tokeni | ul:mobile/.../OrderStore; safe:…/state/useTickets.ts:51 | Da. |
| Javni linkovi | `/dogadjaj/{slug}`, `/ulaznice/{order_id}` | ul:worker/index.ts:209, :351 | Da, uz isti slug. |
| `SKRIVENI_ORGANIZATORI` | `public.accounts.id` | ul:wrangler.jsonc:79; ul:worker/api.ts:281-290 | Nije u shemi koja se seli; treba `account_id` na novoj tablici eventa. |
| og-image cache `pinka-og-cache` | sha256 URL-a, `set_contribution_link_preview_image` | api:_shared/og-image-cache.ts:2, :80 | **Nije relevantno**: ticketing ga ne koristi. |
| Slike `pinka-covers` | URL `…/object/public/pinka-covers/{uid}/{uuid}.{ext}` | ul:worker/api.ts:694 | U `events.cover_image_url`/`gallery` → prepisuje S2. **Izvan baze NIJE pokriveno:** (a) D1 `event_pages.logo_url/hero_url` ako pokazuju na bucket; (b) nacrti u localStorageu organizatora (ul:web/src/lib/nacrt.ts:80-92); (c) CDN/preglednik/OG crawleri (Facebook, WhatsApp) koji su keširali stari URL za `og:image` stranice eventa; (d) api:scripts/storage-r2-switch.sh:28; (e) eventualne kopije opisa/URL-a u već poslanim mailovima (mail ne sadrži slike, pa samo u teoriji). → preporuka: objekte u `pinka-covers` ne brisati odmah (S7 tek nakon prijelaznog razdoblja). |
| Generičke onchain donacije na Safe eventa | `pinka_finance.contributions` s `campaign_id` eventa (kreirao `pinka-onchain-ingest`) | api:pinka-onchain-ingest/index.ts:70-101; api:…ticketing_rpcs.sql:501-506 | **Nije pokriveno odlukom**: ako postoje, ostaju siročad u `pinka_finance` (FK na campaigns) — provjeriti u S1 brojem. |

---

## Sažetak (10 redaka)

1. 8 `events-*` funkcija imaju tvrdo `.schema("pinka_finance")` + imena `campaigns/campaign_tiers/contributions/events/event_access/organizer_payment_rails` → sve se mijenjaju; HTTP ugovor ostaje.
2. Worker (`ivan/main`) ima 11 izravnih PostgREST poziva (8 u api.ts service ključem + 3 korisničkim JWT-om iz index.ts) s `Accept/Content-Profile: pinka_finance`, uključujući PATCH na `organizer_payment_rails` i RPC-e `rotate_ticket_tokens`, `refund_ticket_order`, `organizer_overview`.
3. Upload slika ide samo kroz Worker `ucitajSliku` → `pinka-covers` (ul:worker/api.ts:671, :694); web i mobile ne zovu Supabase izravno.
4. safe-wallet mobile i iOS/Android app zovu samo edge funkcije odnosno Worker → nema promjene ako ugovor i UUID-ovi ostanu.
5. crowdfund.domovina.ai ne dira `pinka_finance` (vlastiti D1). campaign-core nema runtime pristup, ali contract test se sruši ako se iz `pinka_finance` obrišu `campaign_tiers.sale_start/sale_end`.
6. Stripe metadata `{order_id, campaign_id}`, success/cancel URL-ovi, D1 tablice, Fira `webshopOrderId`, mail linkovi: sve izvedeno iz UUID-ova/sluga → „isti UUID-ovi + isti slug” pokriva.
7. QR ne nosi UUID: obavezno 1:1 kopirati `qr_token_hash` (i `qr_token_once`).
8. Nije pokriveno: `pinka-covers` URL-ovi izvan baze (D1 `event_pages.logo_url/hero_url`, nacrti u localStorageu, keširani og:image, `storage-r2-switch.sh`) → objekte ne brisati odmah.
9. Implicitna veza: `pinka-onchain-ingest` danas uključuje Safeove eventa u watchlist i može upisati generičku donaciju na event; nakon seljenja to prestaje, a postojeći takvi redovi postaju siročad.
10. Operativno: `ulaznice` dodati u `PGRST_DB_SCHEMAS` (i config.toml:18), seedove u domovina-ulaznice prepisati, a deploy jezgre i Ivanovog Workera uskladiti (ili privremeni kompatibilni sloj); lokalni `main` u domovina-ulaznice je ~45 commita iza `ivan/main`.
