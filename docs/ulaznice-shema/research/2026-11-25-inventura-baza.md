# Inventura baznih objekata ticketinga (ulaznice) u `pinka_finance`

Read-only inventura, 2026-11-25. Izvor: `supabase/migrations/` (kratice niže), `supabase/tests/`, uz kratak pogled u `supabase/functions/events-*` samo da se vidi tko što zove.
Sve putanje su relativne na `supabase/migrations/`, osim ako nije drukčije navedeno.

Kratice migracija:

| kratica | datoteka | redaka | prod |
|---|---|---|---|
| E-SCH | 20260716120000_events_ticketing_schema.sql | 157 | da |
| E-RLS | 20260716120100_events_ticketing_rls.sql | 74 | da |
| E-RPC | 20260716120200_events_ticketing_rpcs.sql | 682 | da |
| E-CHK | 20260717120000_events_checkin.sql | 205 | da |
| E-ORG | 20260717130000_events_organizer.sql | 634 | da |
| E-STR | 20260803120000_events_stripe_rail.sql | 298 | da |
| E-REF | 20260803130000_events_stripe_refund.sql | 131 | da |
| **E-GATE** | 20260903120000_events_publish_rail_gate.sql | 226 | **NE (namjerno)** |
| **E-ROT** | 20260903120100_events_rotate_ticket_tokens.sql | 150 | **NE (namjerno)** |
| E-GEO | 20261120120000_events_venue_geo.sql | 69 | da |
| E-GAL | 20261120170000_events_gallery.sql | 60 | da |
| E-DEL | 20261124170000_events_delete_draft.sql | 58 | da |
| E-FREE | 20261125120000_events_free_online.sql | 397 | da |
| P-SCH | 20260530120100_pinka_finance_schema.sql | 280 | dijeljeno |
| P-RLS | 20260530120200_pinka_finance_rls.sql | 210 | dijeljeno |
| P-HARD | 20260611120000_pinka_campaign_hardening.sql | 358 | dijeljeno |
| P-SLOT | 20260722120000_pinka_slots.sql | 1037 | dijeljeno |
| P-ID | 20260721120000_pinka_contributor_identity.sql | 150 | dijeljeno |

Ukupno 13 event migracija = 3141 redak (`wc -l`).

---

## 1. Tablice, kolone, ograničenja, indeksi, trigeri

### 1.1 Tablice koje pripadaju SAMO ticketingu (5)

#### `pinka_finance.events` (1:1 uz `campaigns`): E-SCH:40-72, proširenja E-GEO, E-GAL, E-FREE

| kolona | tip | null / default | izvor |
|---|---|---|---|
| campaign_id | uuid | PK, FK → campaigns(id) on delete cascade | E-SCH:41 |
| event_type | text | not null, default 'ostalo' | E-SCH:42 |
| venue_name | text | not null | E-SCH:43 |
| venue_address | text | null | E-SCH:44 |
| venue_city | text | not null | E-SCH:45 |
| starts_at / ends_at | timestamptz | null | E-SCH:46-47 |
| timezone | text | not null, default 'Europe/Zagreb' | E-SCH:48 |
| description_hr / description_en | text | null | E-SCH:49-50 |
| cover_image_url | text | null | E-SCH:51 |
| organizer_name | text | not null | E-SCH:52 |
| organizer_email / organizer_web | text | null | E-SCH:53-54 |
| created_at / updated_at | timestamptz | not null, now() | E-SCH:55-56 |
| venue_lat / venue_lon | numeric(9,6) | null | E-GEO:24-25 |
| cover_image_alt | text | null | E-GEO:26 |
| gallery | jsonb | not null, default '[]' | E-GAL:24 |
| attendance_mode | text | not null, default 'physical' | E-FREE:31 |

CHECK-ovi: `events_type_format` (`^[a-z0-9_]{1,40}$`), `events_venue_name_len` (1–160), `events_venue_address_len` (≤200), `events_venue_city_len` (1–80), `events_timezone_len` (1–64), `events_description_hr_len` / `_en_len` (≤20000), `events_cover_url_format` (https, ≤1000), `events_organizer_name_len` (1–160), `events_organizer_email_len` / `_web_len` (≤200), `events_dates_order` (ends > starts) (sve E-SCH:57-71); `events_venue_geo_pair`, `events_venue_geo_range`, `events_cover_image_alt_len` (1–300) (E-GEO:28-57, `do`-blok s provjerom `pg_constraint`); `events_gallery_shape` = `events_gallery_valid(gallery)` (E-GAL:44-53); `events_attendance_mode_chk` in ('physical','online') (E-FREE:32-34).
Indeksi: samo PK.
Trigger: `trg_events_updated` BEFORE UPDATE → `public.touch_updated_at()` (E-SCH:74-77).
RLS uključen: E-SCH:154.

#### `pinka_finance.tickets` (jedan red = jedna ulaznica): E-SCH:118-137, + P-SLOT:205-206

| kolona | tip | null / default | izvor |
|---|---|---|---|
| id | uuid | PK, gen_random_uuid() | E-SCH:119 |
| contribution_id | uuid | not null, FK → contributions on delete cascade | E-SCH:120 |
| campaign_id | uuid | not null, FK → campaigns on delete cascade | E-SCH:121 |
| tier_id | uuid | null, FK → campaign_tiers on delete set null | E-SCH:122 |
| serial | text | not null | E-SCH:123 |
| holder_name / holder_email | text | null (PII) | E-SCH:124-125 |
| qr_token_hash | text | not null **unique** | E-SCH:126 |
| qr_token_once | text | null (tranzijentni plaintext) | E-SCH:127 |
| state | `pinka_finance.ticket_state` | not null, default 'issued' | E-SCH:128 |
| checked_in_at | timestamptz | null | E-SCH:129 |
| checked_in_by | uuid | FK → auth.users on delete set null | E-SCH:130 |
| created_at / updated_at | timestamptz | not null, now() | E-SCH:131-132 |
| slot_id | uuid | null, FK → pinka_finance.slots on delete set null | **P-SLOT:205-206** („faza sjedala; sad samo stoji”) |

CHECK-ovi: `tickets_serial_len` (1–40), `tickets_holder_name_len` (≤120), `tickets_holder_email_len` (≤200); UNIQUE (campaign_id, serial) (E-SCH:133-136).
Indeksi: `ix_tickets_contribution(contribution_id)`, `ix_tickets_campaign(campaign_id, state)` (E-SCH:139-140).
Trigger: `trg_tickets_updated` → `public.touch_updated_at()` (E-SCH:142-145). RLS: E-SCH:155.
Enum `pinka_finance.ticket_state` = ('issued','checked_in','void') (E-SCH:34-36).

#### `pinka_finance.organizer_allowlist`: E-ORG:31-37
account_id uuid PK FK → public.accounts on delete cascade; note text; created_by uuid FK → auth.users set null; created_at. CHECK `organizer_allowlist_note_len` ≤500. Bez triggera. RLS E-ORG:44.

#### `pinka_finance.organizer_records` (DAC7, osjetljivo): E-ORG:58-83
account_id PK FK → public.accounts cascade; legal_name, oib, address_line, city, postal_code (not null); country_code default 'HR'; contact_email; financial_identifier_type default 'safe_address'; financial_identifier not null; created_at/updated_at.
CHECK-ovi: `_legal_name_len`, `_oib_format` (`^\d{11}$`), `_address_len`, `_city_len`, `_postal_len`, `_country_format`, `_email_len`, `_fin_type` in ('iban','safe_address'), `_fin_format` (IBAN regex ili 0x40hex) (E-ORG:70-82).
Trigger `trg_organizer_records_updated` → touch_updated_at (E-ORG:91-94). RLS E-ORG:96.

#### `pinka_finance.organizer_payment_rails` (Stripe Connect): E-STR:45-60
account_id PK FK → public.accounts cascade; stripe_account_id text **unique**; stripe_charges_enabled / stripe_payouts_enabled bool not null default false; invoice_provider text not null default 'organizator'; invoice_config jsonb; created_at/updated_at.
CHECK: `opr_stripe_acct_format` (`^acct_…`), `opr_invoice_provider_chk` in ('organizator','fira','domovina_fiskal'), `opr_invoice_config_size` ≤8192 (E-STR:54-59).
Trigger `trg_organizer_payment_rails_updated` → touch_updated_at (E-STR:68-71). RLS E-STR:73.

#### `pinka_finance.event_access` (link online događaja): E-FREE:39-44
campaign_id uuid PK FK → campaigns cascade; online_url text; updated_at not null now(). CHECK `event_access_online_url_chk` (https, ≤1000). **Nema** triggera za updated_at (edge funkcija ga sama postavlja, `functions/events-organizer/index.ts:86-87`). RLS E-FREE:49.

> Napomena: zadatak spominje 5, ali ticketing-only tablica je **6**: events, tickets, organizer_allowlist, organizer_records, organizer_payment_rails, event_access.

### 1.2 Dijeljene tablice koje je ticketing PROŠIRIO

`campaign_tiers` (bazno P-SCH:114-131):
- + `imenska bool not null default false`, `sale_start timestamptz`, `sale_end timestamptz` (E-SCH:80-83)
- + CHECK `tiers_sale_window_order` NOT VALID (E-SCH:85-88)
- ticketing koristi bazne: `kind='ticket'` (enum `tier_kind`, P-SCH:47), `price_cents`, `inventory_total`, `inventory_claimed`, `unit='seat'`, `sort`, `title`, `description`.

`contributions` (= narudžba; bazno P-SCH:135-158):
- + `holders jsonb`, `reserved bool not null default false`, `reserve_expires_at timestamptz`, `declared_payer_address text` (E-SCH:97-101)
- + CHECK `contributions_declared_payer_format` (0x40hex) NOT VALID, `contributions_holders_size` (≤16 KB) NOT VALID (E-SCH:103-111)
- + parcijalni indeks `ix_contributions_reservation_expiry (reserve_expires_at) where state='pending' and reserved` (E-SCH:113-115)
- + `payment_rail text not null default 'onchain'`, `external_payment_ref text`, `buyer_email text` (E-STR:90-93)
- + CHECK `contributions_external_ref_format`, `contributions_buyer_email_len` NOT VALID (E-STR:95-106)
- + UNIQUE parcijalni `ux_contributions_external_payment (payment_rail, external_payment_ref) where external_payment_ref is not null` (E-STR:110-112)
- `contributions_payment_rail_chk`: E-STR:101 ('onchain','stripe') → **zamijenjen** E-FREE:70-73 ('onchain','stripe','free') NOT VALID
- `amount_positive`: bazno `amount_cents > 0` (P-SCH:156) → **zamijenjen** E-FREE:76-78 `amount_cents > 0 or (amount_cents = 0 and tier_id is not null)`, i to **bez NOT VALID** (validira cijelu tablicu pri migraciji; relaksacija pa prolazi)

`contribution_events` (P-SCH:168-179): ticketing piše audit (`contribution.*`, `ticket.*`, …) iz confirm/redeem/void/refund. E-ROT dodaje indeks `ix_contribution_events_rotate (contribution_id, event_type, created_at desc)` (E-ROT:149-150, **neprimijenjeno**).

`campaigns`: ticketing ne dodaje kolone. Koristi `type='tickets'` (enum `campaign_type`, P-SCH:29).

### 1.3 Trigeri koji diraju ticketing a nisu njegovi

| trigger | tablica | funkcija (zadnja verzija) | ticketing grane |
|---|---|---|---|
| `trg_contribution_state` | contributions AFTER UPDATE OF state (20260530120300_pinka_finance_rpcs.sql:262-265) | `tg_contribution_state()`, zadnja verzija **P-SLOT:841-964** (124 retka); prije E-RPC:197-287, P-ID:25 | `expired` + `reserved` → vraća inventory (P-SLOT:864); `paid` + `not reserved` → uzima inventory (P-SLOT:873); `expired→paid` + `reserved` → ponovno uzima (P-SLOT:883-888) |
| `campaigns_write_guard` | campaigns BEFORE INS/UPD | P-HARD:70-129 (prod); E-GATE:78-143 (neprimijenjeno) | aktivacija traži pravi Safe; zaključava `destination_address` nakon prve `paid` |
| `guard_immutable_slug` | campaigns | P-SCH:257-269 | slug immutable |
| touch_updated_at | campaigns, campaign_tiers, contributions | P-SCH:229-242 | |

---

## 2. RLS politike i grantovi

| objekt | politika / grant | izvor |
|---|---|---|
| events | GRANT select → anon, authenticated, service_role; insert/update/delete → authenticated, service_role | E-RLS:19-20 |
| events | `events_select` (anon, authenticated): kampanja živa i (public/unlisted + active/funded/closed) **ili** `is_account_member(account_id)` | E-RLS:22-35 |
| events | `events_write` FOR ALL authenticated: `has_role_on_account(c.account_id,'admin')` (using + with check) | E-RLS:37-51 |
| tickets | REVOKE all od public, anon; revoke i/u/d od authenticated; GRANT select → authenticated; sve → service_role | E-RLS:54-57 |
| tickets | `tickets_select` (authenticated): kupac (`is_account_member(ct.contributor_account_id)`) ili org admin | E-RLS:59-72 |
| organizer_allowlist | revoke all public/anon; select → authenticated; sve → service_role | E-ORG:47-50 |
| organizer_allowlist | `organizer_allowlist_select`: `is_account_member(account_id)` | E-ORG:52-55 |
| organizer_records | revoke all public/anon; select → authenticated; sve → service_role | E-ORG:98-101 |
| organizer_records | `organizer_records_select`: `has_role_on_account(account_id,'admin')` | E-ORG:103-106 |
| organizer_payment_rails | revoke all public/anon; select → authenticated; sve → service_role | E-STR:77-80 |
| organizer_payment_rails | `organizer_payment_rails_select`: `has_role_on_account(account_id,'admin')` | E-STR:82-86 |
| event_access | revoke all public/anon; **select/insert/update/delete → authenticated**, service_role | E-FREE:50-51 |
| event_access | `event_access_admin` FOR ALL authenticated: admin računa kampanje | E-FREE:53-67 |
| storage `pinka-covers` | v. §5 | P-HARD:316-356 |

Dijeljeno (P-RLS, zadnje verzije):
- `campaigns_select` / `campaigns_update` P-ADMIN (20260603130000):87, :100; `campaigns_insert` 20260610120000_pinka_campaign_kyc.sql:30 (admin + KYC); `campaigns_delete` P-RLS:79.
- `tiers_select` P-RLS:86; `tiers_write` 20260603130000:117.
- `contributions_select` 20260603130000:140; `contrib_events_select` P-RLS:130; `stats_select` P-RLS:171.
- GRANT-ovi: campaigns/tiers select → anon (P-RLS:23-24), i/u/d → authenticated (P-RLS:27-28); contributions/contribution_events select → authenticated, sve → service_role (P-RLS:32-37).
- **Default privileges** sheme `pinka_finance` (P-RLS:46-49): select na nove tablice → anon, authenticated; i/u/d → service_role; **execute na nove funkcije → authenticated, service_role**. Zato svaka ticketing tablica eksplicitno revokea anon. Nova shema `ulaznice` neće imati ove defaulte; treba ih postaviti ili revoke/grant pisati eksplicitno.

---

## 3. Funkcije / RPC

Brojevi redaka = od `create or replace function` do `$$;` zadnje (prod) definicije. Gdje kasnija definicija postoji samo u neprimijenjenoj migraciji, navedene su obje.

### (A) Narudžbe / ulaznice / plaćanje / check-in / refund / rezervacije

| RPC | potpis | DEFINER | search_path | čita / piše | grant execute | izvor zadnje def. | redaka |
|---|---|---|---|---|---|---|---|
| create_ticket_order | (p_order_id uuid, p_campaign_id uuid, p_tier_id uuid, p_quantity int, p_holders jsonb='[]', p_payer_address text=null) → jsonb | da | '' | R: campaigns, campaign_tiers, contributions, public.accounts, public.identity_verifications; W: campaign_tiers (inventory_claimed), contributions (insert); poziva expire_stale_ticket_orders | authenticated, service_role (revoke public, anon) | E-FREE:80-229 (grant :388-389); prije E-RPC:295-443 | 150 |
| confirm_ticket_order (onchain) | (p_order_id uuid, p_tx_hash text, p_log_index int, p_from text, p_amount_cents bigint) → jsonb | da | '' | R/W: contributions (for update, forward_tx_hash/onchain_*), campaign_tiers, tickets (insert), contribution_events, campaigns (slug) | **samo service_role** | E-RPC:457-582 (grant :584-585) | 126 |
| confirm_ticket_order_offchain | (p_order_id uuid, p_rail text, p_external_ref text, p_amount_cents bigint, p_payer_email text=null) → jsonb | da | '' | isto kao gore, ključ (payment_rail, external_payment_ref), buyer_email; rail 'free' samo za 0 centi | samo service_role | E-FREE:231-386 (grant :390-393); prije E-STR:141-291 | 156 |
| expire_stale_ticket_orders | () → integer | da | '' | W: contributions (pending+reserved → expired; inventory vraća trigger) | samo service_role | E-RPC:173-188 (:190-191) | 16 |
| deliver_ticket_orders | (p_order_ids uuid[]) → jsonb | da | '' | R: contributions, tickets; W: tickets (qr_token_once := null); poziva expire | samo service_role | E-RPC:591-647 (:649-650) | 57 |
| list_my_tickets | () → table(ticket_id, contribution_id, campaign_id, campaign_title, serial, holder_name, state, checked_in_at, created_at) | da (sql stable) | '' | R: tickets, contributions, campaigns; `is_account_member` | authenticated, service_role | E-RPC:655-677 (:679-680) | 23 |
| redeem_ticket | (p_qr_token text) → jsonb | da | '' | R: tickets, campaigns, campaign_tiers, auth.users; W: tickets (checked_in), contribution_events; `has_role_on_account` | authenticated, service_role | E-CHK:29-138 (:140-141) | 110 |
| void_ticket | (p_ticket_id uuid) → jsonb | da | '' | R: tickets, campaigns; W: tickets (void), contribution_events | authenticated, service_role | E-CHK:144-200 (:202-203) | 57 |
| refund_ticket_order | (p_order_id uuid, p_amount_cents bigint=null, p_reason text=null, p_external_ref text=null) → jsonb | da | '' | W: contributions (refunded), tickets (void), campaign_tiers (inventory), contribution_events, campaign_stats (re-sum) | samo service_role | E-REF:22-124 (:126-129) | 103 |
| *rotate_ticket_tokens* (**neprimijenjeno**) | (p_order_id uuid) → jsonb | da | '' | W: tickets (novi hash + qr_token_once), contribution_events (limit 5/24 h) | samo service_role | E-ROT:44-137 (:145-146) | 94 |

**Zbroj (A), prod: 9 RPC-a, 798 redaka.** S neprimijenjenim `rotate_ticket_tokens`: 10 RPC-a, 892 retka.
Uz to dijeljeni trigger `tg_contribution_state` (124 retka, P-SLOT:841-964), od čega su ticketing grane ~20 redaka (P-SLOT:864-888).

### (B) Organizator / event / tierovi / objava / galerija / brisanje

| RPC | potpis | DEFINER | search_path | čita / piše | grant | izvor | redaka |
|---|---|---|---|---|---|---|---|
| create_event | (p_id uuid, p_account_id uuid, p_title, p_destination_address, p_venue_name, p_venue_city text, p_event_type='ostalo', p_venue_address, p_starts_at, p_ends_at timestamptz, p_timezone='Europe/Zagreb', p_description_hr, p_description_en, p_cover_image_url, p_organizer_name, p_organizer_email, p_organizer_web, p_visibility='private' text, p_tiers jsonb='[]') → jsonb | **ne (INVOKER)** | nije postavljen | poziva `pinka_finance.create_campaign` (P-HARD:154-303, dijeljeno); W: events, campaign_tiers | authenticated, service_role | E-RPC:29-158 (:160-167) | 130 |
| update_event | (p_campaign_id uuid, p_title, p_destination_address, p_event_type, p_venue_name, p_venue_address, p_venue_city text, p_starts_at, p_ends_at timestamptz, p_timezone, p_description_hr, p_description_en, p_cover_image_url, p_organizer_name, p_organizer_email, p_organizer_web text, p_tiers jsonb) → jsonb, sve default null | **ne (INVOKER)** | nije postavljen | R/W: campaigns, events, campaign_tiers; `sanitize_ugc`, `public.log_event` | authenticated, service_role | E-ORG:131-365 (:367-374) | 235 |
| publish_event | (p_campaign_id uuid, p_target_state text='active') → jsonb | da | '' | R: campaigns, organizer_allowlist; W: campaigns (state, visibility='public'); traži pravi Safe | authenticated, service_role | prod E-ORG:380-447 (:449-450); **neprimijenjeno** E-GATE:152-223 (72 retka) | 68 |
| organizer_overview | () → jsonb | da (stable) | '' | R: public.accounts, campaigns, events, campaign_tiers, organizer_allowlist, organizer_records | authenticated, service_role | E-ORG:455-536 (:538-539) | 82 |
| upsert_organizer_record | (p_account_id uuid, p_legal_name, p_oib, p_address_line, p_city, p_postal_code text, p_country_code='HR', p_contact_email=null, p_financial_identifier_type='safe_address', p_financial_identifier=null) → jsonb | da | '' | W: organizer_records | authenticated, service_role | E-ORG:542-625 (:627-632) | 84 |
| delete_event_draft | (p_campaign_id uuid) → jsonb | da | '' | R: campaigns, contributions; W: campaigns.deleted_at | authenticated, service_role | E-DEL:21-51 (:53-54) | 31 |

**Zbroj (B), prod: 6 RPC-a, 630 redaka.**

Pomoćne funkcije (nisu RPC za klijente):

| funkcija | izvor | redaka | napomena |
|---|---|---|---|
| events_gallery_valid(g jsonb) → boolean, sql immutable, INVOKER | E-GAL:26-41 | 16 | koristi je CHECK `events_gallery_shape`; nema revoke (execute PUBLIC + default privileges) |
| sanitize_ugc(p text) → text, sql immutable | E-ORG:111-119 | 9 | **dijeljeno**: koriste je i 20261007120000_sponzorski_trenuci.sql i 20261111120000_postavke_kanala.sql |
| *event_rail_ready(uuid, text, text) → boolean*, DEFINER, stable | E-GATE:44-64 | 21 | **neprimijenjeno** |
| *campaigns_write_guard()* nova verzija | E-GATE:78-143 | 66 | **neprimijenjeno**; dijeljeni trigger |

Tko zove (edge funkcije, `supabase/functions/`): events-organizer → organizer_overview, create_event, update_event, delete_event_draft, publish_event, upsert_organizer_record (`events-organizer/index.ts:94-181`), plus izravni `update` na `events`, `upsert` na `event_access`, `delete` na `campaign_tiers` (`:74-87`); events-checkin → redeem_ticket (`:49`); events-confirm → confirm_ticket_order; events-stripe-confirm/events-order → confirm_ticket_order_offchain; events-tickets → deliver_ticket_orders; events-stripe-intent → expire_stale_ticket_orders (`:46`) i čita organizer_payment_rails. Bez poziva iz edge funkcija: `list_my_tickets`, `void_ticket`, `refund_ticket_order` (refund zove vanjski Worker domovina-ulaznice, E-REF:13-16).

`update_event` i `create_event` ne znaju za `venue_lat/lon`, `cover_image_alt`, `gallery`, `attendance_mode`: njih edge funkcija piše izravno u `events` pod RLS-om `events_write` (E-GAL:12-13, `events-organizer/index.ts:81`).

---

## 4. Viewovi

`campaign_stats` **nije view nego tablica** (denormalizirani agregat; P-SCH:219-226), select → anon (P-RLS:25, politika `stats_select` P-RLS:171). Ticketing je **piše**: `tg_contribution_state` re-sum na `paid` (P-SLOT:906) i `refund_ticket_order` (E-REF:90-118). Nijedan events RPC je ne čita; nijedna events-* edge funkcija ne čita `campaign_stats` (grep `functions/events-*`).

Viewovi u `pinka_finance`: `public_contributions` (zadnji 20260605140000:141), `subscriptions_view` (20260606130000:256), `public_slots` (P-SLOT:211), `public_sponsor_moments` / `public_live_moments` (zadnje 20261111120000:1016, :1055). **Nijedan nije ticketing-specifičan i nijedan events RPC ni events-* edge funkcija ih ne koristi.** Rizik: `public_contributions` vjerojatno prikazuje i narudžbe ulaznica kao „doprinose” (filtrira li `campaigns.type`: nepotvrđeno).

---

## 5. pg_cron i storage

- **pg_cron za istek rezervacija NE postoji.** `expire_stale_ticket_orders()` se zove „lijeno” iz `create_ticket_order` (E-FREE:111; prije E-RPC:326), `deliver_ticket_orders` (E-RPC:606) i edge funkcije `events-stripe-intent/index.ts:46`. Grep `cron.schedule` po migracijama: postoje samo komentari (20260520120500:127, 20260528130000:88, P-SLOT:426) i `sponsor-expire-live` (20261007120000:828), ništa za ulaznice.
- Bucket **`pinka-covers`** (P-HARD:319-327): public, 5 MB, jpeg/png/webp/avif. Politike na `storage.objects`: `pinka_covers_insert` (prva mapa = auth.uid() + `public.is_identity_verified()`), `pinka_covers_update`, `pinka_covers_delete` (prva mapa = auth.uid()) (P-HARD:329-356). Dijeljen s kampanjama; nijedna event migracija ga ne mijenja. `events.cover_image_url` i `gallery[].url` su samo https URL-ovi (nema FK na storage).
- Drugi bucketi (og image 20260928120000:20, sponsor logos 20261007120000:804) nisu ticketing.

---

## 6. Dijeljeni objekti koje ticketing koristi

| objekt | gdje je definiran | kako ga ticketing koristi |
|---|---|---|
| public.accounts | core | FK svih organizer_* tablica; `create_ticket_order` traži osobni account kupca (E-FREE:170-174); organizer_overview |
| public.is_account_member(uuid) | core | RLS events_select, tickets_select, organizer_allowlist_select; list_my_tickets |
| public.has_role_on_account(uuid, text) | core | RLS events_write, tickets_select, organizer_records/payment_rails/event_access; redeem/void/publish/delete RPC-i |
| public.is_identity_verified() | core | pinka-covers insert; campaigns_insert (KYC) koji `create_event` (INVOKER) prolazi |
| public.identity_verifications | core | `contributor_verified` u create_ticket_order |
| public.touch_updated_at() | core | 4 ticketing triggera (events, tickets, organizer_records, organizer_payment_rails) |
| public.log_event | core | update_event / publish_event / upsert_organizer_record (E-ORG, 3 poziva) |
| auth.users, auth.uid(), auth.role() | GoTrue | checked_in_by FK, redeem/void/publish autorizacija, campaigns_write_guard |
| pinka_finance.sanitize_ugc | **E-ORG:111** (ticketing ga je uveo!) | koriste ga i sponzorski trenuci i postavke kanala; ne smije se seliti, samo kopirati ili referencirati |
| pinka_finance.create_campaign | P-HARD:154-303 | `create_event` ga zove s p_type='tickets', p_subject_type='event' (E-RPC:106-118) |
| pinka_finance.slugify, guard_immutable_slug | P-HARD, P-SCH:257 | slug eventa; serial ulaznica koristi `campaigns.slug` (confirm RPC) |
| pinka_finance.campaigns_write_guard | P-HARD:70-133 | rate limit 20/24 h, forsira draft, destination lock, Safe gate za active |
| pinka_finance.tg_contribution_state | P-SLOT:841-964 | inventory za reserved narudžbe, audit, campaign_stats, funded flip (goal_cents null za events → ne okida) |
| pinka_finance.contribution_events | P-SCH:168 | audit svih ticket tokova |
| pinka_finance.campaign_stats | P-SCH:219 | pisano na paid/refund |
| pinka_finance.slots | P-SLOT | FK `tickets.slot_id` |
| enumi campaign_type, campaign_state, campaign_visibility, tier_kind, contribution_state | P-SCH:29-58 | 'tickets', 'ticket', stanja narudžbe |

**CHECK-ovi na `contributions` koje su ticketing migracije mijenjale (rizik za donacije):**

| ograničenje | promjena | rizik |
|---|---|---|
| `amount_positive` | E-FREE:76-78: dopušta 0 kad `tier_id is not null`, **bez NOT VALID** | vrijedi za SVAKU kampanju s tierom (npr. crowdfund 'reward' tier), ne samo za ulaznice; donacijski put s tierom sad u bazi smije upisati 0 €. Štiti li to neki donacijski RPC: nepotvrđeno |
| `contributions_payment_rail_chk` | E-STR:101 → E-FREE:71-73 ('onchain','stripe','free') NOT VALID | donacije koriste default 'onchain'; nizak rizik |
| `contributions_declared_payer_format`, `_holders_size`, `_external_ref_format`, `_buyer_email_len` | E-SCH:106-111, E-STR:99-106, sve NOT VALID | samo na novim kolonama; nizak |
| `ux_contributions_external_payment` | E-STR:110 | parcijalni; donacije ga ne pune |
| `ix_contributions_reservation_expiry` | E-SCH:113 | parcijalni indeks |
| trigger `tg_contribution_state` | ticketing grane u svakoj verziji (E-RPC → P-ID → P-SLOT) | svaki budući rewrite triggera za donacije mora zadržati 3 `reserved` grane, inače oversell ili dvostruko brojanje |

Isti obrazac na `campaign_tiers`: `tiers_sale_window_order` NOT VALID (E-SCH:85-88), donacijama bezopasno.

---

## 7. Kolone: smisao za event naspram balasta

### `campaigns` (P-SCH:71-101 + kasnija proširenja)

| ima smisla za event | izvor | nema smisla za event | izvor |
|---|---|---|---|
| id (= event id, UUID se čuva) | P-SCH:72 | goal_cents (null; funded flip ne okida) | P-SCH:81 |
| account_id (organizator) | :73 | min_contribution_cents (default 100, ne koristi se) | :82 |
| slug (citext unique, immutable; prefiks seriala) | :74 | subject_type ('event' konstanta) / subject_ref | :79-80 |
| type (= 'tickets', diskriminator) | :75 | chain ('gnosis') | :86 |
| title | :76 | safe_deployed_at | :87 |
| description (kopija description_hr, create_event) | :77 | metadata (whitelist 'safe') | :93 |
| currency | :83 | recurrence, recurrence_anchor_day | 20260606130000:30-31 |
| destination_address (not null; Safe ili nulta placeholder za Stripe/free) | :85 | latitude/longitude/location_name (dupliciraju events.venue_lat/lon/venue_name) | 20260610130000:14-16 |
| state (draft/active/closed) | :88 | youtube_channel_id | 20260603130000:24 |
| visibility | :89 | | |
| cover_image_url (duplikat events.cover_image_url) | :90 | | |
| starts_at / ends_at (duplikat events.starts_at/ends_at) | :91-92 | | |
| deleted_at (soft-delete, delete_event_draft) | :94 | | |
| created_at / updated_at | :95-96 | | |

`destination_address` ima smisla samo za onchain rail; za Stripe/free je obavezan placeholder (not null, P-SCH:85).

### `contributions` kao narudžba

| ima smisla za narudžbu | izvor | nema smisla za narudžbu (donacije/sponzori/sjedala) | izvor |
|---|---|---|---|
| id (order UUID, bearer capability) | P-SCH:136 | payment_intent_sid, monerium_order_id | P-SCH:146-147 |
| campaign_id, tier_id | :137-138 | anonymous (uvijek false), display_name, message | :150-152 |
| contributor_account_id (kupac ili null) | :139 | link_preview, message_hidden | 20260602150000:10-11 |
| amount_cents, amount_received_cents | :140-141 | bank_verified, identity_double_verified, payer_iban_hash | 20260605130000:21-23 |
| currency, quantity | :142-143 | display_name_verified | 20260605140000:19 |
| state (pending/paid/expired/refunded) | :144 | desired_slot_keys, slot_unassigned | P-SLOT:195-196 |
| paid_at, created_at, updated_at | :153-155 | is_sponsor, link_url, logo_path, buyer_company, buyer_oib, buyer_vat_id, buyer_address, buyer_reference, terms_accepted_at, underpaid, owner_notified_at, owner_notify_attempts, sold_slots, invoice_* (8 kolona) | 20261007120000:153-177 |
| contributor_verified | 20260603120000:25 | | |
| holders, reserved, reserve_expires_at | E-SCH:98-100 | | |
| payment_rail, external_payment_ref, buyer_email | E-STR:91-93 | | |
| *onchain-only:* destination_address, forward_tx_hash, onchain_from, onchain_log_index, declared_payer_address | P-SCH:148-149, 20260602130000:14-15, E-SCH:101 | | |

Grubo: narudžba treba ~20 od ~55 kolona `contributions`; ostatak su donacije/SEPA/sponzorski/sjedala.

`campaign_tiers`: smisleno id, campaign_id, title, description, kind, price_cents, inventory_total, inventory_claimed, sort, imenska, sale_start, sale_end, created/updated; balast: unit ('seat' konstanta), metadata.

---

## 8. Onchain rail za ulaznice (samo za plaćanje EURe na Safe)

| komad | izvor | redaka |
|---|---|---|
| RPC `confirm_ticket_order` (cijeli) | E-RPC:457-582 | 126 |
| edge funkcija `events-confirm` (verifikacija receipta na Gnosis RPC-u) | `supabase/functions/events-confirm/index.ts` | nije brojano (izvan DB) |
| grana `p_payer_address` u `create_ticket_order` (validacija + rate limit po `declared_payer_address` + insert) | E-FREE:86, :106-108, :188, :210, :216 | ~6 |
| kolona `contributions.declared_payer_address` + CHECK | E-SCH:101, :106-109 | 4 |
| dijeljene onchain kolone koje narudžba puni: forward_tx_hash, onchain_log_index, onchain_from, destination_address (snapshot) | P-SCH:148-149, 20260602130000:14-15 | (dijeljeno s donacijama) |
| UNIQUE `ux_contributions_onchain (forward_tx_hash, onchain_log_index)` | 20260602130000:18-20 | dijeljeno |
| Safe gate u `publish_event` (prod) | E-ORG:415-418 | ~4 |
| Safe gate u `campaigns_write_guard` za state='active' | P-HARD:118-124 | dijeljeno |
| `create_event` / `update_event` parametar `p_destination_address` (+ regex validacija u update) | E-RPC:33, :111; E-ORG:134, :183, :255 | ~5 |
| `organizer_records.financial_identifier_type = 'safe_address'` (default) + CHECK grana | E-ORG:67, :78-81, :551, :587-596 | ~8 |
| `deliver_ticket_orders` vraća `tx_hash` | E-RPC:617 | 1 |
| `payment_rail = 'onchain'` default | E-STR:91 | 1 |

**Ukupno samo-onchain za ulaznice: 1 RPC (126 redaka) + ~30 redaka grana i kolona u drugim objektima + 1 kolona (`declared_payer_address`).** Ostale onchain kolone dijeli s donacijama.

Posljedica na prodi: zbog Safe gatea u `publish_event` (E-ORG:415-418) i `campaigns_write_guard` (P-HARD), organizator **samo sa Stripeom** (bez Safe-a) ne može objaviti događaj. Ispravak je upravo neprimijenjeni E-GATE.

### Dvije namjerno neprimijenjene migracije

- **E-GATE `20260903120000_events_publish_rail_gate.sql`**: uvodi `event_rail_ready(account_id, campaign_type, destination_address)` (DEFINER, stable): pravi Safe **ili** (za `type='tickets'`) `organizer_payment_rails.stripe_charges_enabled` (E-GATE:44-64). Mijenja dijeljeni trigger `campaigns_write_guard` (E-GATE:78-148) i `publish_event` (E-GATE:152-226) da traže „barem jedan radni rail”. Donacije i dalje traže Safe (E-GATE:19-23).
- **E-ROT `20260903120100_events_rotate_ticket_tokens.sql`**: `rotate_ticket_tokens(p_order_id)` (service_role, DEFINER) izdaje nove QR tokene za cijelu narudžbu (osim `checked_in`/`void`), stari hash prestaje vrijediti; limit 5 rotacija / 24 h brojan iz `contribution_events` (E-ROT:1-43); + indeks `ix_contribution_events_rotate` (E-ROT:149-150).
- Obje pokriva test `supabase/tests/20260903_rail_gate_i_rotacija.sql` (239 redaka, „osam NOTICE redaka … SVE PROVJERE PROŠLE”, :7-8).

---

## Testovi (`supabase/tests/`)

| datoteka | redaka | ticketing? |
|---|---|---|
| 20260903_rail_gate_i_rotacija.sql | 239 | **da** (jedini; 18 pogodaka na tickets/ticket_order/organizer_/redeem) |
| 20261007_sponzorski_trenuci.sql | 556 | ne (dijeli contributions/trigger, ali 0 pogodaka) |
| 20261007_sponzorski_trenuci_e2e.sh / _utrka.sh | 225 / 51 | ne |
| 20260925_maksimir_* / 20260926_maksimir_chain.sql | 250 / 313 / 320 | ne |
| 20261111_postavke_kanala.sql | 999 | ne |

**Nijedan SQL test ne pokriva primijenjeni prod ticketing** (create_ticket_order, confirm*, deliver, redeem, void, refund, free/online). Jedini test pokriva dvije neprimijenjene migracije.

---

## Sažetak

1. Ticketing-only tablice: **6** (events, tickets, organizer_allowlist, organizer_records, organizer_payment_rails, event_access) + 1 enum (`ticket_state`).
2. Dijeljene tablice koje je ticketing proširio: **2** (`contributions` +7 kolona, `campaign_tiers` +3 kolone); dodatno piše u `contribution_events` i `campaign_stats` (tablica, ne view).
3. (A) narudžbe/plaćanje/check-in/refund: **9 RPC-a, 798 redaka** na prodi (+ `rotate_ticket_tokens` 94 retka, neprimijenjen).
4. (B) organizator/event/objava/brisanje: **6 RPC-a, 630 redaka** (`create_event` i `update_event` su INVOKER, bez search_path); + `events_gallery_valid` 16 redaka.
5. Dijeljeni trigger `tg_contribution_state` (124 retka, P-SLOT:841) nosi 3 ticketing grane za `reserved`; `sanitize_ugc` je uveo ticketing, a koriste ga sponzorski trenuci i postavke kanala.
6. RLS: 6 politika na ticketing tablicama, sve preko `is_account_member` / `has_role_on_account`; `pinka_finance` default privileges daju anon select i authenticated execute, nova shema ih neće imati.
7. Nema pg_cron posla za istek rezervacija (lijeni poziv iz 3 mjesta); `pinka-covers` je dijeljen i ticketing ga ne mijenja.
8. Rizik za donacije: `amount_positive` (E-FREE:76-78) sad dopušta 0 za svaki contribution s `tier_id`, i to validiran bez NOT VALID.
9. Samo-onchain kod za ulaznice: 1 RPC (126 redaka) + ~30 redaka grana + 1 kolona; Safe gate na prodi blokira objavu organizatoru koji ima samo Stripe (popravak je neprimijenjeni E-GATE).
10. Testovi: samo `20260903_rail_gate_i_rotacija.sql` (239 redaka), i to za neprimijenjene migracije; prod ticketing nema SQL testova.
