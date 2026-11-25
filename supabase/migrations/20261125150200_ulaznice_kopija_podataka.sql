-- =============================================================================
-- Ulaznice: kopija podataka iz pinka_finance (S2, faza F1 „expand”)
--
-- Kopira ticketing iz pinka_finance u ulaznice s ISTIM UUID-ovima (odluka 2).
-- pinka_finance se ne mijenja (brisanje je S7).
--
-- Opseg: kampanje type='tickets' (uključujući obrisane skice, deleted_at se
-- čuva), njihovi tierovi, narudžbe (contributions), ulaznice, audit
-- (contribution_events → order_events), event_access, te sve organizer_*
-- tablice (koristi ih samo ticketing, odluka 101).
--
-- Idempotentno: svaki insert je `on conflict do nothing` na izvornom ključu,
-- pa ponovni run ne duplicira. NAPOMENA: ponovni run NE osvježava redove koji
-- su već kopirani (npr. inventory_claimed, stanje narudžbe). Završna kopija
-- mora se zato izvesti u prozoru zamrzavanja pisanja (odluka 112).
--
-- Mapiranja:
--   * campaigns.state 'funded' → 'closed' (prodaja stoji, event ostaje javan;
--     za evente ne nastaje jer je goal_cents null). 'cancelled' → greška.
--   * contributions.payment_rail: pinka_finance puni default 'onchain' i za
--     narudžbe koje nikad nisu plaćene onchain (rail se upisuje tek pri potvrdi).
--     Zato: 0 € → 'free'; onchain + expired → 'onchain' (povijest, odluka 110);
--     onchain + pending → 'stripe' (onchain rail više ne postoji);
--     onchain + paid/refunded → greška (ne bi smjelo postojati, provjeriti ručno).
--   * contribution_state 'failed' → greška (ticketing ga ne koristi).
--   * narudžba bez tiera (siroče pinka-onchain-ingest) → greška: to je stvarna
--     uplata bez narudžbe i ne smije tiho nestati (na produkciji 0, inventura §2).
--   * ticket campaign bez retka u pinka_finance.events → greška.
--   * URL-ovi u cover_image_url i gallery[].url: '/public/pinka-covers/' →
--     '/public/ulaznice-media/' (ista putanja objekta; objekte kopira operater).
--   * contribution_events.id se zadržava (overriding system value); identity
--     sekvenca se zatim podiže iznad najvećeg id-a u obje tablice.
-- =============================================================================

-- ----- 0. preduvjeti: jasne greške umjesto tihog gubitka ------------------------
do $$
declare
  v_n integer;
begin
  select count(*) into v_n
  from pinka_finance.campaigns c
  where c.type = 'tickets'
    and not exists (select 1 from pinka_finance.events e where e.campaign_id = c.id);
  if v_n > 0 then
    raise exception 'ulaznice_kopija: % ticket kampanja nema redak u pinka_finance.events', v_n;
  end if;

  select count(*) into v_n
  from pinka_finance.campaigns c
  where c.type = 'tickets' and c.state not in ('draft', 'active', 'closed', 'funded');
  if v_n > 0 then
    raise exception 'ulaznice_kopija: % ticket kampanja u stanju koje ulaznice ne poznaju (npr. cancelled)', v_n;
  end if;

  select count(*) into v_n
  from pinka_finance.contributions ct
  join pinka_finance.campaigns c on c.id = ct.campaign_id and c.type = 'tickets'
  where ct.tier_id is null;
  if v_n > 0 then
    raise exception 'ulaznice_kopija: % narudžbi bez tiera na ticket kampanjama (siročad onchain ingesta) — riješiti ručno prije kopije', v_n;
  end if;

  select count(*) into v_n
  from pinka_finance.contributions ct
  join pinka_finance.campaigns c on c.id = ct.campaign_id and c.type = 'tickets'
  where ct.state not in ('pending', 'paid', 'expired', 'refunded');
  if v_n > 0 then
    raise exception 'ulaznice_kopija: % narudžbi u stanju koje ulaznice ne poznaju (npr. failed)', v_n;
  end if;

  select count(*) into v_n
  from pinka_finance.contributions ct
  join pinka_finance.campaigns c on c.id = ct.campaign_id and c.type = 'tickets'
  where ct.payment_rail = 'onchain' and ct.amount_cents > 0 and ct.state in ('paid', 'refunded');
  if v_n > 0 then
    raise exception 'ulaznice_kopija: % plaćenih/refundiranih onchain narudžbi — onchain je dopušten samo uz expired (odluka 110)', v_n;
  end if;
end;
$$;

-- ----- 1. organizer_* (neovisne o eventima) -------------------------------------
insert into ulaznice.organizer_allowlist (account_id, note, created_by, created_at)
select a.account_id, a.note, a.created_by, a.created_at
from pinka_finance.organizer_allowlist a
on conflict (account_id) do nothing;

insert into ulaznice.organizer_records (
  account_id, legal_name, oib, address_line, city, postal_code, country_code,
  contact_email, financial_identifier_type, financial_identifier, created_at, updated_at
)
select
  r.account_id, r.legal_name, r.oib, r.address_line, r.city, r.postal_code, r.country_code,
  r.contact_email, r.financial_identifier_type, r.financial_identifier, r.created_at, r.updated_at
from pinka_finance.organizer_records r
on conflict (account_id) do nothing;

insert into ulaznice.organizer_payment_rails (
  account_id, stripe_account_id, stripe_charges_enabled, stripe_payouts_enabled,
  invoice_provider, invoice_config, created_at, updated_at
)
select
  p.account_id, p.stripe_account_id, p.stripe_charges_enabled, p.stripe_payouts_enabled,
  p.invoice_provider, p.invoice_config, p.created_at, p.updated_at
from pinka_finance.organizer_payment_rails p
on conflict (account_id) do nothing;

-- ----- 2. events (campaigns type='tickets' + events) ---------------------------
insert into ulaznice.events (
  id, account_id, slug, title, description, currency, state, visibility,
  event_type, attendance_mode, venue_name, venue_address, venue_city,
  venue_lat, venue_lon, starts_at, ends_at, timezone,
  description_hr, description_en, cover_image_url, cover_image_alt, gallery,
  organizer_name, organizer_email, organizer_web,
  deleted_at, created_at, updated_at
)
select
  c.id, c.account_id, c.slug, c.title, c.description, c.currency,
  case c.state::text when 'funded' then 'closed' else c.state::text end,
  c.visibility::text,
  e.event_type, e.attendance_mode, e.venue_name, e.venue_address, e.venue_city,
  e.venue_lat, e.venue_lon, e.starts_at, e.ends_at, e.timezone,
  e.description_hr, e.description_en,
  replace(e.cover_image_url, '/public/pinka-covers/', '/public/ulaznice-media/'),
  e.cover_image_alt,
  coalesce((
    select jsonb_agg(
             case
               when jsonb_typeof(g.item) = 'object' and jsonb_typeof(g.item -> 'url') = 'string'
                 then jsonb_set(g.item, '{url}', to_jsonb(
                        replace(g.item ->> 'url', '/public/pinka-covers/', '/public/ulaznice-media/')))
               else g.item
             end
             order by g.ord)
    from jsonb_array_elements(e.gallery) with ordinality as g(item, ord)
  ), '[]'::jsonb),
  e.organizer_name, e.organizer_email, e.organizer_web,
  c.deleted_at, c.created_at, greatest(c.updated_at, e.updated_at)
from pinka_finance.campaigns c
join pinka_finance.events e on e.campaign_id = c.id
where c.type = 'tickets'
on conflict (id) do nothing;

-- ----- 3. ticket_tiers --------------------------------------------------------
insert into ulaznice.ticket_tiers (
  id, event_id, title, description, price_cents, inventory_total, inventory_claimed,
  sort, imenska, sale_start, sale_end, created_at, updated_at
)
select
  t.id, t.campaign_id, t.title, t.description, t.price_cents, t.inventory_total, t.inventory_claimed,
  t.sort, t.imenska, t.sale_start, t.sale_end, t.created_at, t.updated_at
from pinka_finance.campaign_tiers t
join pinka_finance.campaigns c on c.id = t.campaign_id and c.type = 'tickets'
on conflict (id) do nothing;

-- ----- 4. orders --------------------------------------------------------------
insert into ulaznice.orders (
  id, event_id, tier_id, buyer_account_id, amount_cents, amount_received_cents,
  currency, quantity, state, payment_rail, external_payment_ref, buyer_email,
  holders, reserved, reserve_expires_at, contributor_verified,
  paid_at, created_at, updated_at
)
select
  ct.id, ct.campaign_id, ct.tier_id, ct.contributor_account_id, ct.amount_cents, ct.amount_received_cents,
  ct.currency, ct.quantity, ct.state::text,
  case
    when ct.payment_rail <> 'onchain' then ct.payment_rail
    when ct.amount_cents = 0 then 'free'
    when ct.state = 'expired' then 'onchain'
    else 'stripe'                                   -- pending; paid/refunded onchain odbija korak 0
  end,
  ct.external_payment_ref, ct.buyer_email,
  ct.holders, ct.reserved, ct.reserve_expires_at, ct.contributor_verified,
  ct.paid_at, ct.created_at, ct.updated_at
from pinka_finance.contributions ct
join pinka_finance.campaigns c on c.id = ct.campaign_id and c.type = 'tickets'
on conflict (id) do nothing;

-- ----- 5. tickets -------------------------------------------------------------
-- slot_id ne seli (odluka 104).
insert into ulaznice.tickets (
  id, order_id, event_id, tier_id, serial, holder_name, holder_email,
  qr_token_hash, qr_token_once, state, checked_in_at, checked_in_by,
  created_at, updated_at
)
select
  t.id, t.contribution_id, t.campaign_id, t.tier_id, t.serial, t.holder_name, t.holder_email,
  t.qr_token_hash, t.qr_token_once, t.state::text::ulaznice.ticket_state, t.checked_in_at, t.checked_in_by,
  t.created_at, t.updated_at
from pinka_finance.tickets t
join pinka_finance.campaigns c on c.id = t.campaign_id and c.type = 'tickets'
on conflict (id) do nothing;

-- ----- 6. order_events (contribution_events narudžbi) ---------------------------
insert into ulaznice.order_events (id, order_id, event_id, event_type, payload, created_at)
overriding system value
select ce.id, ce.contribution_id, ce.campaign_id, ce.event_type, ce.payload, ce.created_at
from pinka_finance.contribution_events ce
join pinka_finance.campaigns c on c.id = ce.campaign_id and c.type = 'tickets'
on conflict (id) do nothing;

-- identity sekvenca iznad svih postojećih id-jeva (i pinka_finance, da se novi
-- redovi u ulaznice nikad ne sudare s id-jem koji bi ponovni run kopirao)
select setval(
  pg_get_serial_sequence('ulaznice.order_events', 'id'),
  greatest(
    coalesce((select max(id) from ulaznice.order_events), 0),
    coalesce((select max(id) from pinka_finance.contribution_events), 0),
    coalesce((select last_value from pg_sequences
               where schemaname = 'ulaznice' and sequencename = 'order_events_id_seq'), 0),
    1
  )
);

-- ----- 7. event_access --------------------------------------------------------
insert into ulaznice.event_access (event_id, online_url, updated_at)
select a.campaign_id, a.online_url, a.updated_at
from pinka_finance.event_access a
join pinka_finance.campaigns c on c.id = a.campaign_id and c.type = 'tickets'
on conflict (event_id) do nothing;

select 'OK ulaznice_kopija_podataka' as status;
