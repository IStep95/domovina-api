# S1 — inventura i mapiranje ulaznica (2026-11-25)

Read-only. Ništa u kodu, bazi ni produkciji nije promijenjeno. Detalji s `datoteka:linija` su u dva priloga:

- [2026-11-25-inventura-baza.md](2026-11-25-inventura-baza.md): svaka tablica, kolona, ograničenje, trigger, RLS, grant i RPC iz migracija (točka 1 handoffa).
- [2026-11-25-inventura-potrosaci.md](2026-11-25-inventura-potrosaci.md): edge funkcije, Worker `domovina-ulaznice` (`ivan/main` = 3ca4908), safe-wallet mobile, campaign-core, crowdfund, ID-jevi izvan baze (točke 2 i 3).

Ovaj dokument ima produkcijske brojke, usporedbu migracija s produkcijom, mapiranje staro → novo, nacrt DDL-a, veličinu S3 i otvorena pitanja. SQL upiti su u [sql/](sql/).

**Kako su dobivene produkcijske brojke:** svaki upit je `begin read only; … rollback;` u datoteci, pokrenut kao

```bash
bash -c '. scripts/lib/db-env.sh; C=$(detect_db_container); cat docs/ulaznice-shema/research/sql/<datoteka>.sql | ssh_remote "docker exec -i $C psql -U postgres -d postgres -X"'
```

## 1. Sažetak

1. **Migracije = produkcija**, osim dviju namjerno neprimijenjenih iz 9/2026. Katalog `pinka_finance` (kolone, ograničenja, indeksi, trigeri, politike, funkcije s md5 tijela, grantovi) lokalno nakon `supabase db reset --no-seed` i na produkciji razlikuje se u točno 5 redaka, svi iz tih dviju migracija (§3).
2. **Podataka je malo:** 4 eventa (1 aktivan javni, 1 skica, 2 obrisane skice), 6 tierova, 3 narudžbe (1 plaćena Stripe, 2 istekle onchain), 1 ulaznica, 1 `event_access`, 1 `organizer_payment_rails`, 0 `organizer_records`, 0 `organizer_allowlist`, 7 `contribution_events`, 4 `campaign_stats` (§2).
3. **Ticketing-only tablice: 6** (`events`, `tickets`, `organizer_allowlist`, `organizer_records`, `organizer_payment_rails`, `event_access`) + enum `ticket_state`. Dijeljene i proširene: `campaigns` (glava eventa), `campaign_tiers` (+3 kolone), `contributions` (+7 kolona, 6 CHECK-ova, 2 indeksa), uz pisanje u `contribution_events` i `campaign_stats` (to je tablica, ne view).
4. **RPC-i:** (A) narudžbe/ulaznice 9 RPC-a, 798 redaka (+`rotate_ticket_tokens` 94, neprimijenjen); (B) organizator/event 6 RPC-a, 630 redaka. Uz to inventar rezervacija živi u dijeljenom triggeru `tg_contribution_state`, a `create_event` ovisi o `create_campaign` i `campaigns_write_guard`.
5. **Nijedan SQL test ne pokriva primijenjeni ticketing.** Jedini (`supabase/tests/20260903_rail_gate_i_rotacija.sql`, 239 redaka) testira neprimijenjene migracije. S3/S3b moraju testove napisati, ne prepisati.
6. **Worker na `ivan/main` već zove `rotate_ticket_tokens`**, koji na produkciji ne postoji (ul:worker/api.ts:396-403). Ta funkcija Workera danas na produkciji ne radi.
7. **Na produkciji organizator samo sa Stripeom ne može objaviti event** (Safe gate u `publish_event` i `campaigns_write_guard`). Jedini aktivni event je objavljen s ne-nultom `destination_address` bez deployanog Safe-a.
8. **Isti UUID-ovi + isti slug pokrivaju sve ID-jeve izvan baze** (Stripe metadata, success/cancel URL, D1 Workera, Fira `webshopOrderId`, mailovi, mobilne app). QR ne nosi UUID, nego token; `qr_token_hash` se kopira 1:1. Ne pokrivaju samo URL-ove slika izvan baze (§6).
9. **Nema pg_cron posla za ulaznice.** Istek rezervacija je lijen (3 poziva `expire_stale_ticket_orders`). Na produkciji su samo `sponsor-expire-live` i `sponsor-cron`.
10. **S3/S3b podjela ostaje** (§8), ali S3 dobiva i trigger inventara i SQL testove od nule.

## 2. Stanje produkcije (2026-11-25, read-only)

Upiti: `sql/s1-prod-counts.sql`, `sql/s1-prod-counts2.sql`, `sql/s1-prod-covers.sql`, `sql/s1-prod-extra.sql`, `sql/s1-prod-x.sql`.

| Što | Broj | Napomena |
| --- | --- | --- |
| `campaigns` po tipu | donation 1, crowdfund 1, tickets 4 | |
| eventi (`type='tickets'`) | active/public 1; draft/private 1; draft/private obrisan 2 | `deleted_at` postavljen na 2 |
| `pinka_finance.events` | 4 | 1:1 s kampanjama, 0 redaka na ne-ticket kampanjama |
| eventi s deployanim Safe-om (`safe_deployed_at`) | 0 od 4 | 1 ima ne-nultu `destination_address`, svi `chain='gnosis'` |
| `attendance_mode` | physical 4 | |
| tierovi ticket kampanja | 6 | |
| narudžbe (contributions na ticket kampanjama) | paid/stripe 1 (40,00 €); expired/onchain 2 (65,00 €) | sve `reserved=true`, sve imaju `tier_id` |
| narudžbe bez tiera (siročad `pinka-onchain-ingest`) | 0 | |
| `contributions` ukupno po tipu | donation 70, tickets 3, crowdfund 1 | |
| `tickets` | 1 (`issued`) | `slot_id` null 1/1, `qr_token_once` null 1/1 |
| `event_access` | 1 | |
| `organizer_payment_rails` / `organizer_records` / `organizer_allowlist` | 1 / 0 / 0 | |
| `contribution_events` za ticket narudžbe | 7 | |
| `campaign_stats` za ticket kampanje | 4 | |
| `campaign_subjects` / `payouts` / `slot_maps` za ticket kampanje | 0 / 0 / 0 | |
| ne-ticket doprinosi s tierom i 0 € | 0 | relaksirani `amount_positive` dosad nije iskorišten |
| `public_contributions` redaka s ticket kampanja | 1 | javni view donacija danas prikazuje i plaćenu narudžbu ulaznice |
| `pinka-covers` objekti | 10 | 5 referenciraju eventi (2 cover, 3 galerija), 5 nereferencirani (3 iz 6/2026, 2 iz 24. 11.) |
| `campaigns.cover_image_url` u `pinka-covers` | tickets 2, ostali 0 | isti URL kao `events.cover_image_url` |
| `pinka-og-cache` objekti | 12 | ticketing ga ne koristi |
| verifikacijski objekt `scripts/storage-r2-switch.sh:28` | iz 2026-06-11, nije event | S7 ga ne smije brisati |
| pg_cron | `sponsor-expire-live`, `sponsor-cron` | ništa za ulaznice |
| bucketi | `pinka-covers` (javan, 5 MB, jpeg/png/webp/avif), `pinka-og-cache`, `sponsor-logos` | |

Napomena: nereferencirani objekti su po uzorku putanje (`{uid}/{uuid}.{ext}`) uploadi bez spremljenog eventa ili stari cover kampanja. Kopiraju se samo referencirani (5); ostali ostaju u `pinka-covers`.

## 3. Migracije naspram produkcije

Katalog (`sql/s1-katalog.sql`: kolone s defaultima, ograničenja, indeksi, trigeri, politike, funkcije s `md5(prosrc)` i ACL-om, grantovi) pokrenut je lokalno nakon `supabase db reset --no-seed` (prošao, 2026-11-25) i na produkciji, pa uspoređen (`git diff --no-index`). Razlika je samo ovo, sve iz dviju neprimijenjenih migracija:

| Objekt | Lokalno | Produkcija | Migracija |
| --- | --- | --- | --- |
| indeks `ix_contribution_events_rotate` | ima | nema | `20260903120100_events_rotate_ticket_tokens` |
| funkcija `rotate_ticket_tokens(uuid)` | ima | nema | isto |
| funkcija `event_rail_ready(uuid,text,text)` | ima | nema | `20260903120000_events_publish_rail_gate` |
| `campaigns_write_guard()` | nova verzija (63 retka) | stara (56) | isto |
| `publish_event(uuid,text)` | nova verzija | stara | isto |

Sve ostale tablice, politike i tijela funkcija u `pinka_finance` su identični. S2 zato smije graditi iz migracija, uz svijest da `publish_event` i write guard na produkciji imaju stariju logiku.

## 4. Mapiranje staro → novo

Načela: isti UUID-ovi (odluka 2), ista imena RPC-a i oblik JSON-a (odluka 3), shema `ulaznice` drži sve što je samo ticketing; zajedničko ostaje u `public`.

### 4.1 Tablice

| Staro (`pinka_finance`) | Novo (`ulaznice`) | Napomena |
| --- | --- | --- |
| `campaigns` (`type='tickets'`) + `events` | `events` | jedna tablica; `id` = `campaigns.id` |
| `campaign_tiers` (kampanja `tickets`) | `ticket_tiers` | isti `id` |
| `contributions` (kampanja `tickets`) | `orders` | isti `id`; ~20 od ~55 kolona |
| `tickets` | `tickets` | isti `id`; `contribution_id` → `order_id`, `campaign_id` → `event_id` |
| `event_access` | `event_access` | `campaign_id` → `event_id` |
| `organizer_allowlist` | `organizer_allowlist` | samo ticketing |
| `organizer_records` | `organizer_records` | samo ticketing (DAC7) |
| `organizer_payment_rails` | `organizer_payment_rails` | samo ticketing (Stripe Connect organizatora); Worker PATCH-a po `stripe_account_id` |
| `contribution_events` (za narudžbe) | `order_events` | audit; i brojač rotacija QR-a |
| `campaign_stats` (za evente) | — | ne seli; pregled organizatora računa iz `orders` |
| enum `ticket_state` | `ulaznice.ticket_state` | |
| enumi `campaign_state`, `campaign_visibility`, `contribution_state`, `tier_kind` | text + CHECK u `ulaznice` | bez ovisnosti o `pinka_finance` tipovima (preduvjet za S7) |

Preimenovanja tablica nisu dio HTTP ugovora: mijenjaju se samo edge funkcije i Worker, koji se ionako mijenjaju zbog sheme (odluka 3 pokriva RPC-e i HTTP, ne imena tablica).

### 4.2 Kolone `ulaznice.events`

| Iz | Kolona | Napomena |
| --- | --- | --- |
| campaigns | `id`, `account_id`, `slug` (citext unique, nepromjenjiv), `title`, `description`, `currency`, `state` (draft/active/closed; `funded` ne postoji za evente), `visibility`, `deleted_at`, `created_at`, `updated_at` | |
| campaigns | `destination_address` | samo ako ostaje onchain rail (pitanje 1); inače otpada |
| events | `event_type`, `venue_name`, `venue_address`, `venue_city`, `venue_lat`, `venue_lon`, `starts_at`, `ends_at`, `timezone`, `description_hr`, `description_en`, `cover_image_url`, `cover_image_alt`, `gallery`, `organizer_name`, `organizer_email`, `organizer_web`, `attendance_mode` | svi CHECK-ovi iz E-SCH/E-GEO/E-GAL/E-FREE |
| — otpada | `campaigns.type`, `subject_type`, `subject_ref`, `goal_cents`, `min_contribution_cents`, `chain`, `safe_deployed_at`, `metadata`, `recurrence`, `recurrence_anchor_day`, `latitude`, `longitude`, `location_name`, `youtube_channel_id`, `campaigns.cover_image_url`, `campaigns.starts_at/ends_at` | duplikati ili donacijski balast; `events.*` je izvor istine |

`description`: `create_event` ga puni kopijom `description_hr`. Ostaje radi oblika JSON-a ako ga neki odgovor vraća; S3b provjerava i briše ako ne.

### 4.3 Kolone `ulaznice.orders`

| Ostaje | Otpada (donacije, SEPA, sponzori, sjedala) |
| --- | --- |
| `id`, `event_id` (← `campaign_id`), `tier_id`, `buyer_account_id` (← `contributor_account_id`), `amount_cents`, `amount_received_cents`, `currency`, `quantity`, `state` (pending/paid/expired/refunded), `paid_at`, `created_at`, `updated_at`, `contributor_verified`, `holders`, `reserved`, `reserve_expires_at`, `payment_rail` (stripe/free[/onchain]), `external_payment_ref`, `buyer_email` | `payment_intent_sid`, `monerium_order_id`, `anonymous`, `display_name`, `message`, `link_preview`, `message_hidden`, `bank_verified`, `identity_double_verified`, `payer_iban_hash`, `display_name_verified`, `desired_slot_keys`, `slot_unassigned`, `is_sponsor`, `link_url`, `logo_path`, `buyer_company`, `buyer_oib`, `buyer_vat_id`, `buyer_address`, `buyer_reference`, `terms_accepted_at`, `underpaid`, `owner_notified_at`, `owner_notify_attempts`, `sold_slots`, `invoice_*` (8) |
| samo uz onchain rail: `destination_address`, `forward_tx_hash`, `onchain_from`, `onchain_log_index`, `declared_payer_address` | |

Ime `contributor_account_id` → `buyer_account_id` mijenja samo Workerov `orderStatus` select (on ga ne bira) i RPC tijela; JSON odgovori ga ne izlažu pod tim imenom (S3 provjerava). Ako se pokaže drukčije, zadržati staro ime.

### 4.4 `ticket_tiers` i `tickets`

- `ticket_tiers`: `id`, `event_id`, `title`, `description`, `price_cents`, `inventory_total`, `inventory_claimed`, `sort`, `imenska`, `sale_start`, `sale_end`, `created_at`, `updated_at`. Otpadaju `kind` (uvijek `ticket`), `unit` (uvijek `seat`), `metadata`.
- `tickets`: sve kolone osim `slot_id` (0 redaka ga koristi; FK na `pinka_finance.slots` bi vezao novu shemu za staru). `serial` ostaje (prefiks iz sluga), `qr_token_hash` unique, `qr_token_once`.

### 4.5 RPC-i

Svi zadržavaju ime, potpis i oblik JSON-a; parametar `p_campaign_id` ostaje tako imenovan (HTTP ugovor i Worker ga šalju).

| RPC | Skupina | Sesija | Napomena |
| --- | --- | --- | --- |
| `create_ticket_order` | A | S3 | grana `p_payer_address` ovisi o pitanju 1 |
| `confirm_ticket_order` (onchain) | A | S3 ili ukinuti | pitanje 1 |
| `confirm_ticket_order_offchain` | A | S3 | |
| `expire_stale_ticket_orders` | A | S3 | |
| `deliver_ticket_orders` | A | S3 | vraća `tx_hash` samo uz onchain |
| `list_my_tickets` | A | S3 | nitko ga ne zove iz edge funkcija |
| `redeem_ticket` | A | S3 | |
| `void_ticket` | A | S3 | |
| `refund_ticket_order` | A | S3 | više ne piše `campaign_stats` |
| `rotate_ticket_tokens` | A | S3 | pitanje 2; Worker ga već zove |
| `create_event` | B | S3b | danas INVOKER bez `search_path` i zove `create_campaign`; u `ulaznice` DEFINER s `search_path=''` i vlastitom provjerom (admin računa + KYC + rate limit 20/24 h iz `campaigns_write_guard`) |
| `update_event` | B | S3b | isto; prihvaća i `gallery`, `attendance_mode`, `venue_lat/lon`, `cover_image_alt`, koje sad edge funkcija piše izravno (izravni pisi ostaju mogući preko RLS-a) |
| `publish_event` | B | S3b | rail gate (pitanje 2) |
| `organizer_overview` | B | S3b | |
| `upsert_organizer_record` | B | S3b | |
| `delete_event_draft` | B | S3b | |
| `events_gallery_valid` (pomoćna) | — | S2 | treba je CHECK na `events` |
| trigger inventara narudžbe (iz `tg_contribution_state`: 3 grane `reserved`) | A | S3 | vlastiti `ulaznice.tg_order_state` |
| `slugify`, nepromjenjivi slug | B | S2 | kopija ili poziv `pinka_finance.slugify` do S7; preporuka kopija |

### 4.6 Što ostaje zajedničko

`public.accounts`, `public.accounts_memberships`, `public.is_account_member`, `public.has_role_on_account`, `public.is_identity_verified`, `public.identity_verifications`, `public.touch_updated_at`, `public.log_event`, `auth.*`.

`pinka_finance.sanitize_ugc` koriste i sponzorski trenuci i postavke kanala, pa ne seli: `ulaznice` dobiva vlastitu kopiju (`ulaznice.sanitize_ugc`), da S7 može obrisati ticketing bez ovisnosti u bilo kojem smjeru.

## 5. Nacrt DDL-a (nije migracija)

Uz pretpostavku da se onchain rail ukida (preporuka pitanja 1). Ako ostaje, dodaju se kolone iz §4.3 i `events.destination_address`.

```sql
create schema ulaznice;
-- Bez default privileges kao u pinka_finance (anon select na sve nove tablice): grantovi eksplicitno po tablici.
grant usage on schema ulaznice to anon, authenticated, service_role;

create type ulaznice.ticket_state as enum ('issued','checked_in','void');

create table ulaznice.events (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.accounts(id) on delete restrict,
  slug extensions.citext not null unique,
  title text not null,
  description text,
  currency text not null default 'EUR',
  state text not null default 'draft' check (state in ('draft','active','closed')),
  visibility text not null default 'private' check (visibility in ('private','unlisted','public')),
  event_type text not null default 'ostalo',
  attendance_mode text not null default 'physical' check (attendance_mode in ('physical','online')),
  venue_name text not null, venue_address text, venue_city text not null,
  venue_lat numeric(9,6), venue_lon numeric(9,6),
  starts_at timestamptz, ends_at timestamptz, timezone text not null default 'Europe/Zagreb',
  description_hr text, description_en text,
  cover_image_url text, cover_image_alt text,
  gallery jsonb not null default '[]',
  organizer_name text not null, organizer_email text, organizer_web text,
  deleted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
  -- + svi CHECK-ovi iz events (E-SCH:57-71, E-GEO, E-GAL events_gallery_valid) i title/slug iz campaigns
);

create table ulaznice.ticket_tiers (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references ulaznice.events(id) on delete cascade,
  title text not null, description text,
  price_cents integer not null check (price_cents >= 0),
  inventory_total integer, inventory_claimed integer not null default 0,
  sort integer not null default 0,
  imenska boolean not null default false,
  sale_start timestamptz, sale_end timestamptz,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  check (inventory_total is null or inventory_claimed <= inventory_total),
  check (sale_end is null or sale_start is null or sale_end > sale_start)
);

create table ulaznice.orders (
  id uuid primary key,                       -- generira klijent (bearer capability)
  event_id uuid not null references ulaznice.events(id) on delete restrict,
  tier_id uuid not null references ulaznice.ticket_tiers(id) on delete restrict,
  buyer_account_id uuid references public.accounts(id) on delete set null,
  quantity integer not null check (quantity between 1 and 10),
  amount_cents bigint not null check (amount_cents >= 0),
  amount_received_cents bigint,
  currency text not null default 'EUR',
  state text not null default 'pending' check (state in ('pending','paid','expired','refunded')),
  payment_rail text not null check (payment_rail in ('stripe','free')),
  external_payment_ref text,
  buyer_email text,
  holders jsonb,
  reserved boolean not null default true,
  reserve_expires_at timestamptz,
  contributor_verified boolean not null default false,
  paid_at timestamptz,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  check (amount_cents > 0 or payment_rail = 'free')
);
create unique index ux_orders_external_payment on ulaznice.orders (payment_rail, external_payment_ref) where external_payment_ref is not null;
create index ix_orders_reservation_expiry on ulaznice.orders (reserve_expires_at) where state = 'pending' and reserved;

create table ulaznice.tickets (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references ulaznice.orders(id) on delete cascade,
  event_id uuid not null references ulaznice.events(id) on delete cascade,
  tier_id uuid references ulaznice.ticket_tiers(id) on delete set null,
  serial text not null, holder_name text, holder_email text,
  qr_token_hash text not null unique, qr_token_once text,
  state ulaznice.ticket_state not null default 'issued',
  checked_in_at timestamptz, checked_in_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique (event_id, serial)
);

create table ulaznice.order_events (
  id bigint generated always as identity primary key,
  order_id uuid not null references ulaznice.orders(id) on delete cascade,
  event_id uuid not null references ulaznice.events(id) on delete cascade,
  event_type text not null, payload jsonb not null default '{}', created_at timestamptz not null default now()
);
create index ix_order_events_rotate on ulaznice.order_events (order_id, event_type, created_at desc);

create table ulaznice.event_access (
  event_id uuid primary key references ulaznice.events(id) on delete cascade,
  online_url text, updated_at timestamptz not null default now()
);
-- organizer_allowlist, organizer_records, organizer_payment_rails: isti stupci i CHECK-ovi kao u pinka_finance.
-- Trigeri: touch_updated_at na svima; ulaznice.tg_order_state (inventar za reserved); nepromjenjivi slug.
-- RLS: events_select / events_write, tickets_select, organizer_* select, event_access_admin, orders_select
--      (kupac ili admin organizatora), preslikano iz §2 priloga baze.
-- Bucket ulaznice-media: kao pinka-covers (odluka 6), politike na storage.objects.
```

`order_events` preslikava `contribution_events` (`id`, `contribution_id`, `campaign_id`, `event_type`, `payload`, `created_at`). CHECK-ovi preslikani 1:1 i RLS su posao S2.

## 6. ID-jevi izvan baze

Detalj je u prilogu potrošača, §5. Zaključak: **odluka 2 (isti UUID-ovi) + isti slug pokrivaju** Stripe metadata `{order_id, campaign_id}` (webhook čita samo `order_id`), `success_url`/`cancel_url`, `external_payment_ref`, svih 5 D1 tablica s `order_id`, D1 `event_pages.campaign_id`, Fira `webshopOrderId` (iz prvih 12 hex znakova `order_id`), mail linkove, javne linkove, mobilne app (MMKV, OrderStore). QR je `dgdj1:` + token; pokriva ga kopija `qr_token_hash`.

**Nisu pokriveni** samo URL-ovi slika iz `pinka-covers` zapisani izvan baze: D1 `event_pages.logo_url`/`hero_url` (sadržaj nije provjeren, S5), nacrti organizatora u localStorageu, keširani `og:image` na mrežama. Zato se objekti eventa u `pinka-covers` kopiraju, a ne premještaju, i brišu tek u S7.

## 7. Potrošači: što se mijenja

| Potrošač | Promjena | Sesija |
| --- | --- | --- |
| 8 edge funkcija `events-*` | `.schema("ulaznice")` i nova imena tablica; `events-feed` gubi filtar `type='tickets'`; HTTP ugovor isti | S4 |
| Worker `domovina-ulaznice` | 11 PostgREST poziva (profil, imena, embedovi u `worker/index.ts:764-775`), upload u `ulaznice-media`, seedovi (32 pojave), worker-tests | S5 |
| safe-wallet mobile | ništa (samo edge funkcije); onchain tok `events-confirm` ovisi o pitanju 1 | — |
| campaign-core | contract test pada ako S7 obriše `campaign_tiers.sale_start/sale_end` iz `pinka_finance`; ažurirati snimku ili ostaviti stupce | S7 |
| crowdfund.domovina.ai | ništa (vlastiti D1) | — |
| `pinka-onchain-ingest` | Safeovi eventa ispadaju iz watchliste (poželjno); siročadi nema (0) | — |
| `public_contributions` | plaćena narudžba ulaznice prestaje se prikazivati među donacijama (poželjno) | S7 |
| `supabase/config.toml:18`, Coolify `PGRST_DB_SCHEMAS` | dodati `ulaznice` | S2 lokalno, S6 produkcija |
| klon `domovina-api-maksimir-chain` | isti remote; ne deployati iz njega | S6 |

## 8. Veličina S3

| Skupina | RPC-a | Redaka SQL-a (prod) | Dodatno |
| --- | --- | --- | --- |
| A narudžbe/ulaznice | 9 (+`rotate_ticket_tokens` = 10) | 798 (+94) | trigger inventara (~20 redaka grana iz 124), SQL testovi od nule (nema postojećih) |
| B organizator/event | 6 | 630 | zamjena za `create_campaign` + `campaigns_write_guard` (rate limit, KYC, slug), `events_gallery_valid` |

Procjena: S3 ≈ 900 redaka SQL-a za prepisati + trigger + testovi; S3b ≈ 630 + ~150 iz `create_campaign`/write guarda + testovi. Obje stanu u jednu sesiju orkestratora (agenti čitaju i pišu, orkestrator ne učitava tijela). **Podjela S3/S3b ostaje.** Ako se onchain ukine, S3 gubi `confirm_ticket_order` (126 redaka) i grane (~30).

Jedno pomicanje: `events_gallery_valid`, `slugify` kopija, `sanitize_ugc` kopija i trigeri `touch_updated_at` idu u **S2**, jer ih trebaju CHECK-ovi i tablice. Trigger inventara ide u **S3**, jer bez RPC-a narudžbi nema što testirati.

## 9. Rizici koje je inventura otvorila

1. **`amount_positive` na `contributions`** (`20261125120000_events_free_online.sql:76-78`) dopušta 0 € za svaki doprinos s tierom, ne samo za ulaznice. Danas 0 takvih ne-ticket redaka. Nakon S6 se može vratiti na `amount_cents > 0` (S7).
2. **`tg_contribution_state`** nosi tri grane za `reserved` narudžbe. Dok ticketing živi u `pinka_finance` (do S6), svaki prepis tog triggera za donacije mora ih zadržati. S7 ih briše.
3. **Prijelaz deploya:** jezgru (edge funkcije, migracije) deploya ova strana, Worker Ivan. Između dva deploya jedan gađa krivu shemu. Pitanje 4.
4. **Default privileges:** `pinka_finance` daje anon `select` na nove tablice i authenticated `execute` na nove funkcije. `ulaznice` ih namjerno nema; svaki grant je eksplicitan, a S2 test provjerava da anon ne vidi `orders`, `tickets`, `organizer_*`.
5. **Nema testova za primijenjeni ticketing.** Ponašanje za usporedbu S3 mora se izvesti iz tijela RPC-a i curl scenarija (`docs/events-ticketing-curl-scenario.md`), ne iz postojećih testova.

## 10. Pitanja za korisnika (vrata nakon S1)

Upisana na vrh `handoffs/S2.md`.
