-- =============================================================================
-- Ulaznice: nova shema `ulaznice` (S2, paket a)
--
-- Lanac „odvajanje ulaznica iz pinka_finance”, docs/ulaznice-shema/ (plan.md,
-- decisions.md). Faza F1 (expand): shema i tablice nastaju UZ postojeće
-- pinka_finance tablice; podatke kopira 20261125150200, potrošači se prebacuju
-- tek u S4–S6. Ova migracija ne dira ništa u pinka_finance.
--
-- Mapiranje (odluke 100, 113): campaigns(type='tickets') + events → events;
-- campaign_tiers → ticket_tiers; contributions → orders; contribution_events →
-- order_events; tickets, event_access, organizer_allowlist, organizer_records,
-- organizer_payment_rails zadržavaju ime. campaign_id → event_id,
-- contribution_id → order_id, contributor_account_id → buyer_account_id.
--
-- Bez onchain raila (odluka 110): nema onchain stupaca narudžbe ni
-- events.destination_address; payment_rail 'onchain' dopušten je samo uz
-- state='expired' (povijest dviju isteklih narudžbi s produkcije).
--
-- Enumi pinka_finance se ne koriste (odluka 102): stanja su text + CHECK,
-- ticket_state ima vlastiti enum. Pomoćne funkcije su kopije (odluka 103).
--
-- Namjerno NIJE ovdje (S3/S3b): RPC-i, trigger inventara narudžbe
-- (tg_order_state), rotacija QR tokena, rail gate pri objavi.
--
-- CHECK-ovi su preslikani 1:1 iz pinka_finance (izvori u komentarima; kratice
-- kao u docs/ulaznice-shema/research/2026-11-25-inventura-baza.md). U pinka_finance
-- su neki NOT VALID; ovdje su svi validni jer je tablica nova (kopija podataka
-- ih mora zadovoljiti).
--
-- Shema nema default privileges (za razliku od pinka_finance, P-RLS:46-49):
-- svaki grant je eksplicitan.
-- =============================================================================

create schema if not exists ulaznice;
comment on schema ulaznice is
  'Ticketing domovina.* (eventi, tierovi, narudžbe, ulaznice, organizatori). '
  'Odvojeno iz pinka_finance 2026-11 (docs/ulaznice-shema/).';

revoke all on schema ulaznice from public;
grant usage on schema ulaznice to anon, authenticated, service_role;

-- ----- enum ------------------------------------------------------------------
do $$ begin
  create type ulaznice.ticket_state as enum ('issued', 'checked_in', 'void');
exception when duplicate_object then null;
end $$;

-- ----- pomoćne funkcije (kopije, odluka 103) ----------------------------------
-- E-ORG:111-119. Uklanja C0 kontrolne znakove (osim \n i \t) + trim; prazno → null.
create or replace function ulaznice.sanitize_ugc(p text)
returns text
language sql
immutable
set search_path = ''
as $$
  select nullif(
    btrim(regexp_replace(coalesce(p, ''), '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]', '', 'g')),
    ''
  );
$$;

-- P-HARD:139-154. Zrcali lib/format.ts slugify (lowercase, hr dijakritici,
-- alfanum + crtice, max 60, rubovi alfanum).
create or replace function ulaznice.slugify(p text)
returns text
language sql
immutable
set search_path = ''
as $$
  select regexp_replace(
    left(
      regexp_replace(
        regexp_replace(
          translate(lower(coalesce(p, '')), 'čćžšđ', 'cczsd'),
          '[^a-z0-9]+', '-', 'g'),
        '(^-+|-+$)', '', 'g'),
      60),
    '-+$', '');
$$;

-- E-GAL:26-41. Plitka provjera oblika galerije: lista ≤ 20 objekata s url-om.
create or replace function ulaznice.events_gallery_valid(g jsonb)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select jsonb_typeof(g) = 'array'
     and jsonb_array_length(g) <= 20
     and not exists (
       select 1 from jsonb_array_elements(g) s
       where jsonb_typeof(s) <> 'object'
          or jsonb_typeof(s -> 'url') is distinct from 'string'
          or char_length(s ->> 'url') not between 1 and 2000
          or (s ? 'alt' and jsonb_typeof(s -> 'alt') not in ('string', 'null'))
          or char_length(coalesce(s ->> 'alt', '')) > 300
     );
$$;

revoke execute on function ulaznice.sanitize_ugc(text) from public, anon;
revoke execute on function ulaznice.slugify(text) from public, anon;
revoke execute on function ulaznice.events_gallery_valid(jsonb) from public, anon;
grant execute on function ulaznice.sanitize_ugc(text) to authenticated, service_role;
grant execute on function ulaznice.slugify(text) to authenticated, service_role;
grant execute on function ulaznice.events_gallery_valid(jsonb) to authenticated, service_role;

-- ----- events (campaigns type='tickets' + pinka_finance.events) ---------------
create table if not exists ulaznice.events (
  id uuid primary key default gen_random_uuid(),            -- = campaigns.id (odluka 2)
  account_id uuid not null references public.accounts(id) on delete cascade,  -- P-SCH:73
  slug citext not null unique,                              -- nepromjenjiv (trigger niže)
  title text not null,
  description text,                                         -- kopija description_hr (create_event)
  currency text not null default 'eur',                     -- P-SCH:83 (malim slovima)
  state text not null default 'draft',
  visibility text not null default 'private',
  event_type text not null default 'ostalo',
  attendance_mode text not null default 'physical',
  venue_name text not null,
  venue_address text,
  venue_city text not null,
  venue_lat numeric(9,6),
  venue_lon numeric(9,6),
  starts_at timestamptz,                                    -- null = najavljen bez termina
  ends_at timestamptz,
  timezone text not null default 'Europe/Zagreb',
  description_hr text,
  description_en text,
  cover_image_url text,
  cover_image_alt text,
  gallery jsonb not null default '[]'::jsonb,
  organizer_name text not null,
  organizer_email text,
  organizer_web text,
  deleted_at timestamptz,                                   -- soft-delete skice (delete_event_draft)
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- campaigns (P-SCH:97-99, P-HARD:44-47)
  constraint events_slug_format check (
    slug ~ '^[a-z0-9][a-z0-9-]{0,62}[a-z0-9]$' or length(slug) = 1
  ),
  constraint events_title_len check (char_length(title) between 1 and 160),
  constraint events_description_len check (description is null or char_length(description) <= 20000),
  -- enumi campaign_state / campaign_visibility → text (odluka 102); 'funded' i
  -- 'cancelled' se za evente ne koriste (inventura §4.2)
  constraint events_state_chk check (state in ('draft', 'active', 'closed')),
  constraint events_visibility_chk check (visibility in ('private', 'unlisted', 'public')),
  -- events (E-SCH:57-71)
  constraint events_type_format check (event_type ~ '^[a-z0-9_]{1,40}$'),
  constraint events_venue_name_len check (char_length(venue_name) between 1 and 160),
  constraint events_venue_address_len check (venue_address is null or char_length(venue_address) <= 200),
  constraint events_venue_city_len check (char_length(venue_city) between 1 and 80),
  constraint events_timezone_len check (char_length(timezone) between 1 and 64),
  constraint events_description_hr_len check (description_hr is null or char_length(description_hr) <= 20000),
  constraint events_description_en_len check (description_en is null or char_length(description_en) <= 20000),
  constraint events_cover_url_format check (
    cover_image_url is null
    or (char_length(cover_image_url) <= 1000 and cover_image_url ~* '^https://')
  ),
  constraint events_organizer_name_len check (char_length(organizer_name) between 1 and 160),
  constraint events_organizer_email_len check (organizer_email is null or char_length(organizer_email) <= 200),
  constraint events_organizer_web_len check (organizer_web is null or char_length(organizer_web) <= 200),
  constraint events_dates_order check (starts_at is null or ends_at is null or ends_at > starts_at),
  -- E-GEO:28-57
  constraint events_venue_geo_pair check ((venue_lat is null) = (venue_lon is null)),
  constraint events_venue_geo_range check (
    (venue_lat is null or venue_lat between -90 and 90)
    and (venue_lon is null or venue_lon between -180 and 180)
  ),
  constraint events_cover_image_alt_len check (
    cover_image_alt is null or char_length(cover_image_alt) between 1 and 300
  ),
  -- E-GAL:44-53
  constraint events_gallery_shape check (ulaznice.events_gallery_valid(gallery)),
  -- E-FREE:32-34
  constraint events_attendance_mode_chk check (attendance_mode in ('physical', 'online'))
);

create index if not exists ix_events_account on ulaznice.events (account_id);
-- javni feed (P-SCH:105-107 ix_campaigns_public_feed)
create index if not exists ix_events_public_feed
  on ulaznice.events (visibility, state, created_at desc)
  where deleted_at is null;

comment on table ulaznice.events is
  'Događaj (spojeni campaigns type=tickets + pinka_finance.events). id = stari campaigns.id.';

-- ----- ticket_tiers (campaign_tiers, kind='ticket') ---------------------------
create table if not exists ulaznice.ticket_tiers (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references ulaznice.events(id) on delete cascade,
  title text not null,
  description text,
  price_cents integer not null default 0,
  inventory_total integer,                                  -- null = neograničeno
  inventory_claimed integer not null default 0,
  sort integer not null default 0,
  imenska boolean not null default false,                   -- holder ime po komadu
  sale_start timestamptz,                                   -- null = prodaja otvorena
  sale_end timestamptz,                                     -- null = bez roka
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- P-SCH:128-130, E-SCH:85-88
  constraint ticket_tiers_price_nonneg check (price_cents >= 0),
  constraint ticket_tiers_inventory_sane check (inventory_total is null or inventory_total >= 0),
  constraint ticket_tiers_claimed_nonneg check (inventory_claimed >= 0),
  constraint ticket_tiers_sale_window_order check (
    sale_start is null or sale_end is null or sale_end > sale_start
  )
);

create index if not exists ix_ticket_tiers_event on ulaznice.ticket_tiers (event_id, sort);

-- ----- orders (contributions na ticket kampanjama) ----------------------------
create table if not exists ulaznice.orders (
  id uuid primary key,                                      -- generira klijent (bearer capability); = contributions.id
  event_id uuid not null references ulaznice.events(id) on delete cascade,
  -- Svaka narudžba ulaznica ima tier (create_ticket_order ga traži). NO ACTION
  -- (ne SET NULL kao u contributions): brisanje tiera s narudžbama pada, umjesto
  -- da plaćene narudžbe ostanu bez tiera. NO ACTION a ne RESTRICT, da kaskadno
  -- brisanje eventa (tierovi + narudžbe u istoj naredbi) prođe.
  tier_id uuid not null references ulaznice.ticket_tiers(id),
  buyer_account_id uuid references public.accounts(id) on delete set null,  -- null = gost
  amount_cents bigint not null,
  amount_received_cents bigint,
  currency text not null default 'eur',
  quantity integer not null default 1,
  state text not null default 'pending',
  payment_rail text not null,                               -- bez defaulta: S3 create_ticket_order ga postavlja
  external_payment_ref text,                                -- pi_… za stripe
  buyer_email text,
  holders jsonb,                                            -- [{full_name, email?}] za imenske tiere
  reserved boolean not null default false,
  reserve_expires_at timestamptz,
  contributor_verified boolean not null default false,
  paid_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- contribution_state → text (odluka 102); 'failed' ticketing ne koristi
  constraint orders_state_chk check (state in ('pending', 'paid', 'expired', 'refunded')),
  -- odluka 110: onchain samo kao povijest isteklih narudžbi
  constraint orders_payment_rail_chk check (
    payment_rail in ('stripe', 'free', 'onchain')
    and (payment_rail <> 'onchain' or state = 'expired')
  ),
  -- E-FREE:76-78 uz tier_id not null = amount_cents >= 0; 0 € samo na free railu
  constraint orders_amount_nonneg check (amount_cents >= 0),
  constraint orders_amount_free check (amount_cents > 0 or payment_rail = 'free'),
  -- P-SCH:157
  constraint orders_quantity_positive check (quantity > 0),
  -- E-SCH:110, E-STR:99-106
  constraint orders_holders_size check (holders is null or pg_column_size(holders) <= 16384),
  constraint orders_external_ref_format check (
    external_payment_ref is null or external_payment_ref ~ '^[A-Za-z0-9_-]{6,255}$'
  ),
  constraint orders_buyer_email_len check (buyer_email is null or char_length(buyer_email) <= 200)
);

-- idempotencija plaćanja: jedan PaymentIntent kreditira točno jednu narudžbu (E-STR:110-112)
create unique index if not exists ux_orders_external_payment
  on ulaznice.orders (payment_rail, external_payment_ref)
  where external_payment_ref is not null;
-- istek rezervacija (E-SCH:113-115)
create index if not exists ix_orders_reservation_expiry
  on ulaznice.orders (reserve_expires_at)
  where state = 'pending' and reserved;
-- P-SCH:163-165
create index if not exists ix_orders_event on ulaznice.orders (event_id, state);
create index if not exists ix_orders_buyer on ulaznice.orders (buyer_account_id);
create index if not exists ix_orders_tier on ulaznice.orders (tier_id);
-- rate limit narudžbi po kupcu (create_ticket_order: created_at > now() - 1 h)
create index if not exists ix_orders_buyer_created
  on ulaznice.orders (buyer_account_id, created_at desc)
  where buyer_account_id is not null;

comment on table ulaznice.orders is
  'Narudžba ulaznica (bivši contributions na ticket kampanjama). id = stari contributions.id.';

-- ----- tickets ---------------------------------------------------------------
create table if not exists ulaznice.tickets (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references ulaznice.orders(id) on delete cascade,
  event_id uuid not null references ulaznice.events(id) on delete cascade,
  tier_id uuid references ulaznice.ticket_tiers(id) on delete set null,
  serial text not null,                                     -- npr. MON-000042 (unique po eventu)
  holder_name text,                                         -- PII
  holder_email text,                                        -- PII
  qr_token_hash text not null unique,                       -- sha256 hex opaque tokena
  qr_token_once text,                                       -- tranzijentni plaintext do prve dostave
  state ulaznice.ticket_state not null default 'issued',
  checked_in_at timestamptz,
  checked_in_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- E-SCH:133-136
  constraint tickets_serial_len check (char_length(serial) between 1 and 40),
  constraint tickets_holder_name_len check (holder_name is null or char_length(holder_name) <= 120),
  constraint tickets_holder_email_len check (holder_email is null or char_length(holder_email) <= 200),
  constraint tickets_event_serial_key unique (event_id, serial)
);

create index if not exists ix_tickets_order on ulaznice.tickets (order_id);
create index if not exists ix_tickets_event on ulaznice.tickets (event_id, state);

comment on table ulaznice.tickets is
  'Ulaznica-komad. QR = opaque token: trajno samo sha256 hash; qr_token_once je '
  'tranzijentni plaintext od izdavanja do prve dostave, zatim null. Holder polja '
  'su PII — retencija: anonimizirati nakon events.ends_at + 90 dana.';

-- ----- order_events (contribution_events narudžbi; append-only audit) ---------
create table if not exists ulaznice.order_events (
  id bigint generated always as identity primary key,       -- kopija zadržava stari id (overriding system value)
  order_id uuid not null references ulaznice.orders(id) on delete cascade,
  event_id uuid not null references ulaznice.events(id) on delete cascade,
  event_type text not null,                                 -- contribution.*|ticket.*|…
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

-- P-SCH:175-178
create index if not exists ix_order_events_order on ulaznice.order_events (order_id, created_at desc);
create index if not exists ix_order_events_event on ulaznice.order_events (event_id, created_at desc);
-- brojač rotacija QR-a (bivši E-ROT:149-150, odluka 111; RPC dolazi u S3)
create index if not exists ix_order_events_rotate
  on ulaznice.order_events (order_id, event_type, created_at desc);

-- ----- event_access (link online događaja; nije javan) ------------------------
create table if not exists ulaznice.event_access (
  event_id uuid primary key references ulaznice.events(id) on delete cascade,
  online_url text,
  updated_at timestamptz not null default now(),
  -- E-FREE:44-46
  constraint event_access_online_url_chk check (
    online_url is null or (online_url ~ '^https://\S+$' and char_length(online_url) <= 1000)
  )
);
comment on table ulaznice.event_access is
  'Podaci samo za vlasnike ulaznica (link online događaja). Bez anon pristupa.';

-- ----- organizer_allowlist (E-ORG:31-37) --------------------------------------
create table if not exists ulaznice.organizer_allowlist (
  account_id uuid primary key references public.accounts(id) on delete cascade,
  note text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint organizer_allowlist_note_len check (note is null or char_length(note) <= 500)
);
comment on table ulaznice.organizer_allowlist is
  'Org accounti kojima je dopušten publish eventa. Upis isključivo operater '
  '(service_role/psql); publish_event provjerava članstvo server-side.';

-- ----- organizer_records (DAC7, osjetljivo; E-ORG:58-83) ----------------------
create table if not exists ulaznice.organizer_records (
  account_id uuid primary key references public.accounts(id) on delete cascade,
  legal_name text not null,
  oib text not null,
  address_line text not null,
  city text not null,
  postal_code text not null,
  country_code text not null default 'HR',
  contact_email text,
  financial_identifier_type text not null default 'safe_address',
  financial_identifier text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint organizer_records_legal_name_len check (char_length(legal_name) between 1 and 200),
  constraint organizer_records_oib_format check (oib ~ '^\d{11}$'),
  constraint organizer_records_address_len check (char_length(address_line) between 1 and 200),
  constraint organizer_records_city_len check (char_length(city) between 1 and 80),
  constraint organizer_records_postal_len check (char_length(postal_code) between 1 and 20),
  constraint organizer_records_country_format check (country_code ~ '^[A-Z]{2}$'),
  constraint organizer_records_email_len check (contact_email is null or char_length(contact_email) <= 200),
  constraint organizer_records_fin_type check (financial_identifier_type in ('iban', 'safe_address')),
  constraint organizer_records_fin_format check (
    (financial_identifier_type = 'iban' and financial_identifier ~ '^[A-Z]{2}\d{2}[A-Z0-9]{1,30}$')
    or (financial_identifier_type = 'safe_address' and financial_identifier ~ '^0x[0-9a-fA-F]{40}$')
  )
);
comment on table ulaznice.organizer_records is
  'DAC7 evidencija organizatora. SENSITIVE — čitaju samo service_role i admin '
  'vlastitog org accounta; nikad u javnim viewovima ni feedu.';

-- ----- organizer_payment_rails (Stripe Connect; E-STR:45-60) ------------------
create table if not exists ulaznice.organizer_payment_rails (
  account_id uuid primary key references public.accounts(id) on delete cascade,
  stripe_account_id text unique,                            -- acct_… ; NIKAD u javnom feedu
  stripe_charges_enabled boolean not null default false,
  stripe_payouts_enabled boolean not null default false,
  invoice_provider text not null default 'organizator',
  invoice_config jsonb,                                     -- referenca na tajnu, nikad tajna
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint opr_stripe_acct_format
    check (stripe_account_id is null or stripe_account_id ~ '^acct_[A-Za-z0-9]+$'),
  constraint opr_invoice_provider_chk
    check (invoice_provider in ('organizator', 'fira', 'domovina_fiskal')),
  constraint opr_invoice_config_size
    check (invoice_config is null or pg_column_size(invoice_config) <= 8192)
);
comment on table ulaznice.organizer_payment_rails is
  'Stripe Connect stanje organizatora. Piše isključivo service_role (Worker nakon '
  'verifikacije Stripe webhooka); stripe_account_id nikad u javnim odgovorima.';

-- =============================================================================
-- Trigeri
-- =============================================================================

-- updated_at: public.touch_updated_at() (DEFINER, search_path '') je zajednički
-- (inventura §4.6). event_access ga u pinka_finance nema (edge funkcija sama
-- postavlja updated_at); ovdje ga dobiva, rezultat je isti.
drop trigger if exists trg_events_updated on ulaznice.events;
create trigger trg_events_updated
  before update on ulaznice.events
  for each row execute function public.touch_updated_at();

drop trigger if exists trg_ticket_tiers_updated on ulaznice.ticket_tiers;
create trigger trg_ticket_tiers_updated
  before update on ulaznice.ticket_tiers
  for each row execute function public.touch_updated_at();

drop trigger if exists trg_orders_updated on ulaznice.orders;
create trigger trg_orders_updated
  before update on ulaznice.orders
  for each row execute function public.touch_updated_at();

drop trigger if exists trg_tickets_updated on ulaznice.tickets;
create trigger trg_tickets_updated
  before update on ulaznice.tickets
  for each row execute function public.touch_updated_at();

drop trigger if exists trg_event_access_updated on ulaznice.event_access;
create trigger trg_event_access_updated
  before update on ulaznice.event_access
  for each row execute function public.touch_updated_at();

drop trigger if exists trg_organizer_records_updated on ulaznice.organizer_records;
create trigger trg_organizer_records_updated
  before update on ulaznice.organizer_records
  for each row execute function public.touch_updated_at();

drop trigger if exists trg_organizer_payment_rails_updated on ulaznice.organizer_payment_rails;
create trigger trg_organizer_payment_rails_updated
  before update on ulaznice.organizer_payment_rails
  for each row execute function public.touch_updated_at();

-- nepromjenjivi slug (P-SCH:257-269, kopija)
create or replace function ulaznice.guard_immutable_slug()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.slug is distinct from old.slug then
    raise exception 'slug_immutable';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_events_slug_guard on ulaznice.events;
create trigger trg_events_slug_guard
  before update on ulaznice.events
  for each row execute function ulaznice.guard_immutable_slug();

-- write guard za izravne PostgREST pise (P-HARD:70-133 campaigns_write_guard,
-- bez dijelova koji ovise o Safe-u / destination_address, odluka 110).
-- Samo auth.role() = 'authenticated'; service_role / psql prolaze netaknuto.
--   INSERT: event se uvijek rađa kao skica; najviše 20 eventa po računu u 24 h.
--   UPDATE: vlasništvo (account_id) se ne prenosi.
-- Uvjet za objavu (rail gate „Stripe Connect aktivan ili samo besplatni tierovi”,
-- odluka 111) NIJE ovdje: dolazi u S3b zajedno s ulaznice.publish_event.
create or replace function ulaznice.events_write_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_recent integer;
begin
  if coalesce(auth.role(), '') <> 'authenticated' then
    return new;
  end if;

  if tg_op = 'INSERT' then
    new.state := 'draft';

    select count(*) into v_recent
    from ulaznice.events
    where account_id = new.account_id
      and created_at > now() - interval '24 hours';
    if v_recent >= 20 then
      raise exception 'campaign_rate_limited'
        using hint = 'Dosegnut dnevni limit kreiranja događaja.';
    end if;
  end if;

  if tg_op = 'UPDATE' then
    new.account_id := old.account_id;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_events_write_guard on ulaznice.events;
create trigger trg_events_write_guard
  before insert or update on ulaznice.events
  for each row execute function ulaznice.events_write_guard();

revoke execute on function ulaznice.guard_immutable_slug() from public, anon, authenticated;
revoke execute on function ulaznice.events_write_guard() from public, anon, authenticated;

-- =============================================================================
-- RLS + grantovi
-- =============================================================================

alter table ulaznice.events                  enable row level security;
alter table ulaznice.ticket_tiers            enable row level security;
alter table ulaznice.orders                  enable row level security;
alter table ulaznice.tickets                 enable row level security;
alter table ulaznice.order_events            enable row level security;
alter table ulaznice.event_access            enable row level security;
alter table ulaznice.organizer_allowlist     enable row level security;
alter table ulaznice.organizer_records       enable row level security;
alter table ulaznice.organizer_payment_rails enable row level security;

-- Polazno stanje: nitko ništa, pa eksplicitni grantovi niže.
revoke all on all tables in schema ulaznice from public, anon, authenticated;

-- ----- events (campaigns + events) --------------------------------------------
-- P-RLS:23,27; E-RLS:19-20
grant select on ulaznice.events to anon, authenticated;
grant insert, update, delete on ulaznice.events to authenticated;
grant select, insert, update, delete on ulaznice.events to service_role;

-- campaigns_select (P-RLS:57) ∪ events_select (E-RLS:22-35); bez grane vlasnika
-- YouTube kanala (events nema youtube_channel_id) i bez 'funded'.
drop policy if exists events_select on ulaznice.events;
create policy events_select on ulaznice.events
  for select to anon, authenticated
  using (
    deleted_at is null
    and (
      (visibility in ('public', 'unlisted') and state in ('active', 'closed'))
      or public.is_account_member(account_id)
    )
  );

-- campaigns_insert (20260610120000_pinka_campaign_kyc.sql:30): admin + KYC
drop policy if exists events_insert on ulaznice.events;
create policy events_insert on ulaznice.events
  for insert to authenticated
  with check (
    public.has_role_on_account(account_id, 'admin')
    and public.is_identity_verified()
  );

-- campaigns_update (P-RLS:73) / events_write (E-RLS:37-51): admin računa
drop policy if exists events_update on ulaznice.events;
create policy events_update on ulaznice.events
  for update to authenticated
  using (deleted_at is null and public.has_role_on_account(account_id, 'admin'))
  with check (public.has_role_on_account(account_id, 'admin'));

-- campaigns_delete (P-RLS:79): tvrdo brisanje samo owner; soft-delete ide RPC-om
drop policy if exists events_delete on ulaznice.events;
create policy events_delete on ulaznice.events
  for delete to authenticated
  using (public.has_role_on_account(account_id, 'owner'));

-- ----- ticket_tiers (P-RLS:24,28,86; 20260603130000:117) ----------------------
grant select on ulaznice.ticket_tiers to anon, authenticated;
grant insert, update, delete on ulaznice.ticket_tiers to authenticated;
grant select, insert, update, delete on ulaznice.ticket_tiers to service_role;

drop policy if exists ticket_tiers_select on ulaznice.ticket_tiers;
create policy ticket_tiers_select on ulaznice.ticket_tiers
  for select to anon, authenticated
  using (
    exists (
      select 1 from ulaznice.events e
      where e.id = event_id
        and e.deleted_at is null
        and (
          (e.visibility in ('public', 'unlisted') and e.state in ('active', 'closed'))
          or public.is_account_member(e.account_id)
        )
    )
  );

drop policy if exists ticket_tiers_write on ulaznice.ticket_tiers;
create policy ticket_tiers_write on ulaznice.ticket_tiers
  for all to authenticated
  using (
    exists (
      select 1 from ulaznice.events e
      where e.id = event_id and public.has_role_on_account(e.account_id, 'admin')
    )
  )
  with check (
    exists (
      select 1 from ulaznice.events e
      where e.id = event_id and public.has_role_on_account(e.account_id, 'admin')
    )
  );

-- ----- orders (P-RLS:32,35; contributions_select 20260603130000:140) ----------
-- Nikad anon (holders, buyer_email su PII). Pisanje samo RPC/service_role.
grant select on ulaznice.orders to authenticated;
grant select, insert, update, delete on ulaznice.orders to service_role;

drop policy if exists orders_select on ulaznice.orders;
create policy orders_select on ulaznice.orders
  for select to authenticated
  using (
    public.is_account_member(buyer_account_id)
    or exists (
      select 1 from ulaznice.events e
      where e.id = event_id and public.has_role_on_account(e.account_id, 'admin')
    )
  );

-- ----- tickets (E-RLS:54-72) ---------------------------------------------------
grant select on ulaznice.tickets to authenticated;
grant select, insert, update, delete on ulaznice.tickets to service_role;

drop policy if exists tickets_select on ulaznice.tickets;
create policy tickets_select on ulaznice.tickets
  for select to authenticated
  using (
    exists (
      select 1 from ulaznice.orders o
      where o.id = order_id
        and public.is_account_member(o.buyer_account_id)
    )
    or exists (
      select 1 from ulaznice.events e
      where e.id = event_id and public.has_role_on_account(e.account_id, 'admin')
    )
  );

-- ----- order_events (P-RLS:33,36; contrib_events_select P-RLS:130) ------------
grant select on ulaznice.order_events to authenticated;
grant select, insert, update, delete on ulaznice.order_events to service_role;
grant usage, select on all sequences in schema ulaznice to service_role;

drop policy if exists order_events_select on ulaznice.order_events;
create policy order_events_select on ulaznice.order_events
  for select to authenticated
  using (
    exists (
      select 1 from ulaznice.orders o
      where o.id = order_id
        and (
          public.is_account_member(o.buyer_account_id)
          or exists (
            select 1 from ulaznice.events e
            where e.id = o.event_id and public.has_role_on_account(e.account_id, 'admin')
          )
        )
    )
  );

-- ----- event_access (E-FREE:49-67): samo admin računa eventa, nikad anon --------
grant select, insert, update, delete on ulaznice.event_access to authenticated, service_role;

drop policy if exists event_access_admin on ulaznice.event_access;
create policy event_access_admin on ulaznice.event_access
  for all to authenticated
  using (
    exists (
      select 1 from ulaznice.events e
      where e.id = event_id and public.has_role_on_account(e.account_id, 'admin')
    )
  )
  with check (
    exists (
      select 1 from ulaznice.events e
      where e.id = event_id and public.has_role_on_account(e.account_id, 'admin')
    )
  );

-- ----- organizer_allowlist (E-ORG:47-55) --------------------------------------
grant select on ulaznice.organizer_allowlist to authenticated;
grant select, insert, update, delete on ulaznice.organizer_allowlist to service_role;

drop policy if exists organizer_allowlist_select on ulaznice.organizer_allowlist;
create policy organizer_allowlist_select on ulaznice.organizer_allowlist
  for select to authenticated
  using (public.is_account_member(account_id));

-- ----- organizer_records (E-ORG:98-106) ---------------------------------------
grant select on ulaznice.organizer_records to authenticated;
grant select, insert, update, delete on ulaznice.organizer_records to service_role;

drop policy if exists organizer_records_select on ulaznice.organizer_records;
create policy organizer_records_select on ulaznice.organizer_records
  for select to authenticated
  using (public.has_role_on_account(account_id, 'admin'));

-- ----- organizer_payment_rails (E-STR:77-86) ----------------------------------
grant select on ulaznice.organizer_payment_rails to authenticated;
grant select, insert, update, delete on ulaznice.organizer_payment_rails to service_role;

drop policy if exists organizer_payment_rails_select on ulaznice.organizer_payment_rails;
create policy organizer_payment_rails_select on ulaznice.organizer_payment_rails
  for select to authenticated
  using (public.has_role_on_account(account_id, 'admin'));

notify pgrst, 'reload schema';

select 'OK ulaznice_shema' as status;
