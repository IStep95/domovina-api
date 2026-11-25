-- =============================================================================
-- Ulaznice: RPC-i događaja i organizatora (S3b, skupina B)
--
-- Lanac „odvajanje ulaznica iz pinka_finance”, docs/ulaznice-shema/. Port iz
-- pinka_finance u shemu `ulaznice` (20261125150000). Ova migracija ne dira
-- ništa u pinka_finance; stari RPC-i ostaju do S7. Nijedna funkcija ovdje ne
-- čita ni ne piše pinka_finance.
--
-- Izvori (zadnja definicija svake funkcije; kasnije migracije venue_geo,
-- events_gallery i events_free_online RPC-e ne mijenjaju, nove stupce edge
-- funkcija piše izravno):
--   create_event                 20260716120200_events_ticketing_rpcs.sql:29
--                                + create_campaign 20260611120000_pinka_campaign_hardening.sql:154
--                                + RLS campaigns_insert 20260610120000_pinka_campaign_kyc.sql:30
--   update_event                 20260717130000_events_organizer.sql:131
--   publish_event                git show e77f9ae:…/20260903120000_events_publish_rail_gate.sql
--                                (rail gate; nikad primijenjen na pinka_finance, odluka 111),
--                                prije toga 20260717130000_events_organizer.sql:380
--   event_rail_ready             isti izvor (pravilo prepisano, v. niže)
--   organizer_overview           20260717130000_events_organizer.sql:455
--   upsert_organizer_record      20260717130000_events_organizer.sql:542
--   delete_event_draft           20261124170000_events_delete_draft.sql:21
--   events_write_guard           20261125150000_ulaznice_shema.sql:473 (S2) + aktivacija
--
-- Za organizer_allowlist i organizer_payment_rails u pinka_finance nema RPC-a
-- (upis samo service_role); tablice, grantovi i RLS su već u S2.
--
-- Mapiranje (odluke 100, 113): campaigns+events → events; campaign_tiers →
-- ticket_tiers; contributions → orders; campaign_id → event_id. Imena RPC-a,
-- parametri (i p_campaign_id) i oblik JSON-a ostaju isti (odluka 3), uključujući
-- ključ destination_address (→ null) u organizer_overview.
--
-- Odstupanja od originala (prijedlog odluka 350+, detalj uz svaku funkciju):
--   * create_event i update_event su DEFINER (bili INVOKER); provjeru admin +
--     KYC, koju je radila RLS politika campaigns_insert, create_event radi sam
--     i baca ISTU poruku/kod kao RLS (42501), jer je edge skraćuje u „new”, a
--     Worker (domovina-ulaznice worker/api.ts:558) „new” mapira u 403;
--   * p_destination_address ostaje u potpisu (odluka 3); vrijednost se
--     odbacuje (onchain ukinut, odluka 110), samo pogrešan format i dalje baca
--     invalid_destination; null je dopušten (bio invalid_destination);
--   * provjere type='tickets' (campaign_not_tickets) i event_not_found otpadaju;
--   * publish_event: rail gate „Stripe Connect aktivan ILI samo besplatni
--     tierovi” (odluka 111) umjesto pravog Safe-a; closed samo iz active
--     (funded ne postoji, odluka 202);
--   * events_write_guard dobiva isti gate (allowlist + rail) za izravni
--     PostgREST update u 'active', da admin ne zaobiđe publish_event;
--   * update_event prima i p_gallery, p_attendance_mode, p_venue_lat,
--     p_venue_lon, p_cover_image_alt (svi default null = ne diraj), potpis koji
--     edge zove imenovanim argumentima i dalje vrijedi.
-- =============================================================================

-- ----- event_rail_ready — ima li događaj čime naplatiti ------------------------
-- Pravilo (odluka 111): organizator ima Stripe Connect koji prima uplate
-- (stripe_account_id i stripe_charges_enabled) ILI događaj nema nijedan tier s
-- cijenom > 0. Onchain grana (pravi Safe) otpada (odluka 110). Događaj bez
-- ijednog tiera je „samo besplatni” i prolazi (nema što naplatiti).
-- Potpis se razlikuje od originala (account_id, campaign_type, destination):
-- tip i adresa više ne postoje, a tierovi se čitaju po eventu.
-- DEFINER: zovu ga trigger i publish_event; organizer_payment_rails je za
-- pisanje zaključan na service_role. Vraća samo boolean, acct_… ne izlazi.
create or replace function ulaznice.event_rail_ready(
  p_account_id uuid,
  p_event_id uuid
) returns boolean
language sql stable security definer set search_path = ''
as $$
  select
    exists (
      select 1 from ulaznice.organizer_payment_rails r
       where r.account_id = p_account_id
         and r.stripe_account_id is not null
         and r.stripe_charges_enabled
    )
    or not exists (
      select 1 from ulaznice.ticket_tiers t
       where t.event_id = p_event_id
         and t.price_cents > 0
    );
$$;

comment on function ulaznice.event_rail_ready(uuid, uuid) is
  'Može li događaj biti aktivan: Stripe Connect organizatora prima uplate ILI '
  'događaj ima samo besplatne tierove. Koriste ga events_write_guard i '
  'publish_event. Vraća boolean; acct_… nikad ne izlazi iz funkcije.';

-- Original je imao grant authenticated; ovdje ga zovu samo DEFINER funkcije,
-- pa izravni RPC ne treba (inače bi svatko mogao pitati ima li tuđi
-- organizator aktivan Stripe).
revoke execute on function ulaznice.event_rail_ready(uuid, uuid) from public, anon, authenticated;
grant execute on function ulaznice.event_rail_ready(uuid, uuid) to service_role;

-- ----- events_write_guard — S2 + gate aktivacije ------------------------------
-- Puno tijelo iz 20261125150000 (create or replace ne zna djelomičnu izmjenu).
-- Nova je samo zadnja grana: authenticated update koji event prebacuje u
-- 'active' traži allowlist i radni rail, kao publish_event. U pinka_finance je
-- campaigns_write_guard zrcalio samo Safe/rail provjeru; allowlist je ovdje
-- dodan jer bi inače admin računa izravnim PATCH-om (RLS events_update to
-- dopušta) objavio događaj mimo moderacije. Unutar publish_event (DEFINER,
-- auth.role() ostaje 'authenticated') provjera se ponovi s istim ishodom.
-- service_role / psql prolaze netaknuto (kao original).
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

    -- aktivacija (S3b, odluka 111): isti uvjeti kao publish_event
    if new.state = 'active' and old.state is distinct from 'active' then
      if not exists (
        select 1 from ulaznice.organizer_allowlist al
         where al.account_id = new.account_id
      ) then
        raise exception 'organizer_not_allowlisted';
      end if;
      if not ulaznice.event_rail_ready(new.account_id, new.id) then
        raise exception 'event_no_working_rail'
          using hint = 'Događaj s plaćenim ulaznicama treba aktivan Stripe račun organizatora.';
      end if;
    end if;
  end if;

  return new;
end;
$$;

revoke execute on function ulaznice.events_write_guard() from public, anon, authenticated;

-- ----- create_event (organizator; DEFINER) -------------------------------------
-- Spaja create_event + create_campaign. Redoslijed provjera kao u originalu:
-- polja događaja i tierova → (ovdje) admin + KYC → idempotencija → polja
-- „kampanje” → upis. U originalu je admin + KYC provjeravala RLS politika
-- campaigns_insert tek pri upisu; ovdje je eksplicitna, prije idempotencije,
-- da DEFINER ne otkrije postojanje tuđeg događaja.
--
-- Greška admin/KYC je doslovno poruka RLS-a (errcode 42501): edge je skraćuje u
-- „new”, Worker to mapira u 403 nema_prava_kreiranja. Čisti kodovi
-- (not_authorized / kyc_required) su prijedlog za S4/S5.
--
-- Rate limit (20 / 24 h, 'campaign_rate_limited') i prisilnu skicu radi
-- trigger ulaznice.events_write_guard, koji se okida i ovdje jer auth.role()
-- ostaje 'authenticated' (odluka 205); RPC ga ne duplicira. service_role
-- (bez korisnika) prolazi bez admin/KYC provjere i bez rate limita, kao
-- original (INVOKER + bypassrls, guard samo za authenticated).
--
-- events.description: kopija description_hr kao campaigns.description. Nijedan
-- JSON odgovor ga ne vraća (feed ga selektira, ali ne ispisuje; overview ga
-- nema), ali kopija 150200 ga puni i skripta ulaznice-prod-dump-test.sh je
-- ponovno pušta nakon ove migracije, pa stupac ostaje do S7.
create or replace function ulaznice.create_event(
  p_id uuid,
  p_account_id uuid,
  p_title text,
  p_destination_address text,
  p_venue_name text,
  p_venue_city text,
  p_event_type text default 'ostalo',
  p_venue_address text default null,
  p_starts_at timestamptz default null,
  p_ends_at timestamptz default null,
  p_timezone text default 'Europe/Zagreb',
  p_description_hr text default null,
  p_description_en text default null,
  p_cover_image_url text default null,
  p_organizer_name text default null,
  p_organizer_email text default null,
  p_organizer_web text default null,
  p_visibility text default 'private',
  p_tiers jsonb default '[]'::jsonb
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_title text := nullif(btrim(coalesce(p_title, '')), '');
  v_tier jsonb;
  v_price bigint;
  v_inventory integer;
  v_sale_start timestamptz;
  v_sale_end timestamptz;
  v_sort integer := 0;
  v_existing record;
  v_base text;
  v_slug text;
  v_constraint text;
  i integer;
begin
  -- ── validacija polja događaja (create_event) ───────────────────────────────
  if p_venue_name is null or btrim(p_venue_name) = '' or char_length(p_venue_name) > 160 then
    raise exception 'invalid_venue_name';
  end if;
  if p_venue_city is null or btrim(p_venue_city) = '' or char_length(p_venue_city) > 80 then
    raise exception 'invalid_venue_city';
  end if;
  if p_event_type is null or p_event_type !~ '^[a-z0-9_]{1,40}$' then
    raise exception 'invalid_event_type';
  end if;
  if p_timezone is null or btrim(p_timezone) = '' or char_length(p_timezone) > 64 then
    raise exception 'invalid_timezone';
  end if;
  if p_tiers is null or jsonb_typeof(p_tiers) <> 'array' or jsonb_array_length(p_tiers) > 50 then
    raise exception 'invalid_tiers';
  end if;

  for v_tier in select * from jsonb_array_elements(p_tiers) loop
    if jsonb_typeof(v_tier) <> 'object'
       or nullif(btrim(coalesce(v_tier->>'title', '')), '') is null
       or char_length(v_tier->>'title') > 160 then
      raise exception 'invalid_tier_title';
    end if;
    if v_tier->>'price_cents' is null or v_tier->>'price_cents' !~ '^\d{1,9}$' then
      raise exception 'invalid_tier_price';
    end if;
    if v_tier ? 'inventory_total'
       and jsonb_typeof(v_tier->'inventory_total') <> 'null'
       and v_tier->>'inventory_total' !~ '^\d{1,7}$' then
      raise exception 'invalid_tier_inventory';
    end if;
    begin
      v_sale_start := (v_tier->>'sale_start')::timestamptz;
      v_sale_end   := (v_tier->>'sale_end')::timestamptz;
    exception when others then
      raise exception 'invalid_tier_sale_window';
    end;
    if v_sale_start is not null and v_sale_end is not null and v_sale_end <= v_sale_start then
      raise exception 'invalid_tier_sale_window';
    end if;
  end loop;

  -- ── admin računa + KYC (bila RLS politika campaigns_insert) ─────────────────
  if coalesce((select auth.role()), '') <> 'service_role'
     and not (public.has_role_on_account(p_account_id, 'admin')
              and public.is_identity_verified()) then
    raise exception 'new row violates row-level security policy for table "events"'
      using errcode = '42501';
  end if;

  -- ── idempotencija: retry s istim client-generated id vraća postojeći ───────
  select id, slug into v_existing
  from ulaznice.events
  where id = p_id and account_id = p_account_id;
  if found then
    return jsonb_build_object('id', v_existing.id, 'slug', v_existing.slug,
                              'existing', true, 'event_created', false);
  end if;

  -- ── validacija polja „kampanje” (create_campaign, samo ono što ostaje) ─────
  if v_title is null or char_length(v_title) < 3 or char_length(v_title) > 160 then
    raise exception 'invalid_title';
  end if;
  if p_description_hr is not null and char_length(p_description_hr) > 20000 then
    raise exception 'invalid_description';
  end if;
  if p_visibility is null or p_visibility not in ('private','unlisted','public') then
    raise exception 'invalid_visibility';
  end if;
  -- onchain ukinut (odluka 110): adresa se ne sprema; edge šalje nultu adresu
  -- kao placeholder, pa format i dalje mora proći, null je dopušten
  if p_destination_address is not null and p_destination_address !~ '^0x[0-9a-fA-F]{40}$' then
    raise exception 'invalid_destination';
  end if;
  if p_cover_image_url is not null
     and (char_length(p_cover_image_url) > 1000 or p_cover_image_url !~* '^https://') then
    raise exception 'invalid_cover_url';
  end if;
  if p_starts_at is not null and p_ends_at is not null and p_ends_at <= p_starts_at then
    raise exception 'invalid_dates';
  end if;
  if p_ends_at is not null and p_ends_at <= now() then
    raise exception 'invalid_dates';
  end if;

  -- ── upis; slug server-side (sudar slugova riješen retryjem na 23505) ──────
  -- state 'draft' postavlja i guard (authenticated); ovdje eksplicitno zbog
  -- service_role puta.
  v_base := coalesce(nullif(ulaznice.slugify(v_title), ''), 'kampanja');
  for i in 0..9 loop
    v_slug := case
      when i = 0 then v_base
      when i < 9 then left(v_base, 58) || '-' || (i + 1)::text
      else left(v_base, 51) || '-' || substr(md5(random()::text), 1, 8)
    end;
    begin
      insert into ulaznice.events (
        id, account_id, slug, title, description, state, visibility,
        event_type, venue_name, venue_address, venue_city,
        starts_at, ends_at, timezone, description_hr, description_en,
        cover_image_url, organizer_name, organizer_email, organizer_web
      ) values (
        p_id, p_account_id, v_slug, v_title,
        nullif(btrim(coalesce(p_description_hr, '')), ''),
        'draft', p_visibility,
        p_event_type, btrim(p_venue_name), nullif(btrim(coalesce(p_venue_address, '')), ''),
        btrim(p_venue_city), p_starts_at, p_ends_at, btrim(p_timezone),
        nullif(btrim(coalesce(p_description_hr, '')), ''),
        nullif(btrim(coalesce(p_description_en, '')), ''),
        p_cover_image_url, coalesce(nullif(btrim(coalesce(p_organizer_name, '')), ''), v_title),
        nullif(btrim(coalesce(p_organizer_email, '')), ''),
        nullif(btrim(coalesce(p_organizer_web, '')), '')
      );
      exit;
    exception when unique_violation then
      get stacked diagnostics v_constraint = CONSTRAINT_NAME;
      -- pkey sudar = tuđi događaj s tim id-em (vlastiti je vraćen gore)
      if v_constraint = 'events_pkey' then
        raise exception 'campaign_exists';
      end if;
      if i = 9 then
        raise exception 'slug_collision';
      end if;
      -- slug zauzet → sljedeći kandidat
    end;
  end loop;

  for v_tier in select * from jsonb_array_elements(p_tiers) loop
    v_price := (v_tier->>'price_cents')::bigint;
    v_inventory := case
      when v_tier ? 'inventory_total' and jsonb_typeof(v_tier->'inventory_total') <> 'null'
        then (v_tier->>'inventory_total')::integer
      else null
    end;
    insert into ulaznice.ticket_tiers (
      event_id, title, description, price_cents, inventory_total,
      imenska, sale_start, sale_end, sort
    ) values (
      p_id, btrim(v_tier->>'title'), nullif(btrim(coalesce(v_tier->>'description', '')), ''),
      v_price::integer, v_inventory,
      coalesce((v_tier->>'imenska')::boolean, false),
      (v_tier->>'sale_start')::timestamptz, (v_tier->>'sale_end')::timestamptz,
      v_sort
    );
    v_sort := v_sort + 1;
  end loop;

  return jsonb_build_object('id', p_id, 'slug', v_slug, 'existing', false, 'event_created', true);
end;
$$;

revoke execute on function ulaznice.create_event(
  uuid, uuid, text, text, text, text, text, text, timestamptz, timestamptz,
  text, text, text, text, text, text, text, text, jsonb
) from public, anon;
grant execute on function ulaznice.create_event(
  uuid, uuid, text, text, text, text, text, text, timestamptz, timestamptz,
  text, text, text, text, text, text, text, text, jsonb
) to authenticated, service_role;

-- ----- update_event (organizator; DEFINER) -------------------------------------
-- null param = polje se ne dira; prazan string = brisanje opcionalnog polja.
-- p_tiers (null = ne diraj): [{id? (postojeći tier), title, price_cents,
--   inventory_total?, imenska?, sale_start?, sale_end?, description?, sort?}]
-- Nakon objave (state <> 'draft'): cijena i imenska postojećeg tiera su
-- zaključane; inventory_total ne smije ispod inventory_claimed; novi tierovi smiju.
--
-- Razlike od originala: DEFINER (bio INVOKER pod RLS-om; admin provjera je
-- ionako bila eksplicitna); bez campaign_not_tickets / event_not_found;
-- p_destination_address se samo validira i odbacuje (odluka 110); red se
-- zaključava (for update) radi provjere tier_locked naspram publish_event.
-- Novi parametri na kraju (default null = ne diraj), da poziv edge funkcije
-- imenovanim argumentima ostane isti:
--   p_gallery          [{url, alt?}] ≤ 20, url https ≤ 1000 ('[]' briše)
--   p_attendance_mode  physical | online
--   p_venue_lat/lon    samo u paru; brisanje koordinata ide izravnim updateom
--   p_cover_image_alt  1–300 znakova, '' briše
-- Edge (S4) ih može slati umjesto izravnog `update events`; izravni pis
-- ostaje dopušten (RLS events_update, admin računa).
create or replace function ulaznice.update_event(
  p_campaign_id uuid,
  p_title text default null,
  p_destination_address text default null,
  p_event_type text default null,
  p_venue_name text default null,
  p_venue_address text default null,
  p_venue_city text default null,
  p_starts_at timestamptz default null,
  p_ends_at timestamptz default null,
  p_timezone text default null,
  p_description_hr text default null,
  p_description_en text default null,
  p_cover_image_url text default null,
  p_organizer_name text default null,
  p_organizer_email text default null,
  p_organizer_web text default null,
  p_tiers jsonb default null,
  p_gallery jsonb default null,
  p_attendance_mode text default null,
  p_venue_lat numeric default null,
  p_venue_lon numeric default null,
  p_cover_image_alt text default null
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_event ulaznice.events;
  v_tier jsonb;
  v_existing ulaznice.ticket_tiers;
  v_tier_id uuid;
  v_price integer;
  v_inventory integer;
  v_sale_start timestamptz;
  v_sale_end timestamptz;
  v_starts timestamptz;
  v_ends timestamptz;
  v_updated integer := 0;
  v_added integer := 0;
begin
  select * into v_event from ulaznice.events
    where id = p_campaign_id and deleted_at is null
    for update;
  if not found then raise exception 'campaign_not_found'; end if;
  if not public.has_role_on_account(v_event.account_id, 'admin') then
    raise exception 'not_authorized';
  end if;

  -- ── validacija (ista pravila kao create_event; strojni kodovi) ────────────
  if p_title is not null and (btrim(p_title) = '' or char_length(btrim(p_title)) < 3 or char_length(p_title) > 160) then
    raise exception 'invalid_title';
  end if;
  if p_destination_address is not null and p_destination_address !~ '^0x[0-9a-fA-F]{40}$' then
    raise exception 'invalid_destination';
  end if;
  if p_event_type is not null and p_event_type !~ '^[a-z0-9_]{1,40}$' then
    raise exception 'invalid_event_type';
  end if;
  if p_venue_name is not null and (btrim(p_venue_name) = '' or char_length(p_venue_name) > 160) then
    raise exception 'invalid_venue_name';
  end if;
  if p_venue_city is not null and (btrim(p_venue_city) = '' or char_length(p_venue_city) > 80) then
    raise exception 'invalid_venue_city';
  end if;
  if p_venue_address is not null and char_length(p_venue_address) > 200 then
    raise exception 'invalid_venue_address';
  end if;
  if p_timezone is not null and (btrim(p_timezone) = '' or char_length(p_timezone) > 64) then
    raise exception 'invalid_timezone';
  end if;
  if p_description_hr is not null and char_length(p_description_hr) > 20000 then
    raise exception 'invalid_description';
  end if;
  if p_description_en is not null and char_length(p_description_en) > 20000 then
    raise exception 'invalid_description';
  end if;
  if p_cover_image_url is not null and p_cover_image_url <> ''
     and (char_length(p_cover_image_url) > 1000 or p_cover_image_url !~* '^https://') then
    raise exception 'invalid_cover_url';
  end if;
  if p_organizer_name is not null and (btrim(p_organizer_name) = '' or char_length(p_organizer_name) > 160) then
    raise exception 'invalid_organizer_name';
  end if;
  if p_organizer_email is not null and char_length(p_organizer_email) > 200 then
    raise exception 'invalid_organizer_email';
  end if;
  if p_organizer_web is not null and char_length(p_organizer_web) > 200 then
    raise exception 'invalid_organizer_web';
  end if;
  -- novi parametri (kodovi kao u edge funkciji events-organizer parseMedia)
  if p_gallery is not null then
    if not ulaznice.events_gallery_valid(p_gallery) then
      raise exception 'invalid_gallery';
    end if;
    if exists (
      select 1 from jsonb_array_elements(p_gallery) s
       where s->>'url' !~* '^https://\S+$' or char_length(s->>'url') > 1000
    ) then
      raise exception 'invalid_gallery_url';
    end if;
  end if;
  if p_attendance_mode is not null and p_attendance_mode not in ('physical', 'online') then
    raise exception 'invalid_attendance_mode';
  end if;
  if (p_venue_lat is null) <> (p_venue_lon is null)
     or (p_venue_lat is not null
         and (p_venue_lat not between -90 and 90 or p_venue_lon not between -180 and 180)) then
    raise exception 'invalid_location';
  end if;
  if p_cover_image_alt is not null and char_length(btrim(p_cover_image_alt)) > 300 then
    raise exception 'invalid_cover_image_alt';
  end if;

  v_starts := coalesce(p_starts_at, v_event.starts_at);
  v_ends   := coalesce(p_ends_at, v_event.ends_at);
  if v_starts is not null and v_ends is not null and v_ends <= v_starts then
    raise exception 'invalid_dates';
  end if;

  -- ── događaj (bivši events + zrcalna polja campaigns u jednom retku) ───────
  update ulaznice.events set
    title           = coalesce(btrim(p_title), title),
    description     = case when p_description_hr is null then description
                           else ulaznice.sanitize_ugc(p_description_hr) end,
    event_type      = coalesce(p_event_type, event_type),
    venue_name      = coalesce(btrim(p_venue_name), venue_name),
    venue_address   = case when p_venue_address is null then venue_address
                           else nullif(btrim(p_venue_address), '') end,
    venue_city      = coalesce(btrim(p_venue_city), venue_city),
    starts_at       = coalesce(p_starts_at, starts_at),
    ends_at         = coalesce(p_ends_at, ends_at),
    timezone        = coalesce(btrim(p_timezone), timezone),
    description_hr  = case when p_description_hr is null then description_hr
                           else ulaznice.sanitize_ugc(p_description_hr) end,
    description_en  = case when p_description_en is null then description_en
                           else ulaznice.sanitize_ugc(p_description_en) end,
    cover_image_url = case when p_cover_image_url is null then cover_image_url
                           else nullif(p_cover_image_url, '') end,
    organizer_name  = coalesce(btrim(p_organizer_name), organizer_name),
    organizer_email = case when p_organizer_email is null then organizer_email
                           else nullif(btrim(p_organizer_email), '') end,
    organizer_web   = case when p_organizer_web is null then organizer_web
                           else nullif(btrim(p_organizer_web), '') end,
    gallery         = coalesce(p_gallery, gallery),
    attendance_mode = coalesce(p_attendance_mode, attendance_mode),
    venue_lat       = coalesce(p_venue_lat, venue_lat),
    venue_lon       = coalesce(p_venue_lon, venue_lon),
    cover_image_alt = case when p_cover_image_alt is null then cover_image_alt
                           else nullif(btrim(p_cover_image_alt), '') end,
    updated_at      = now()
  where id = p_campaign_id;

  -- ── tierovi ─────────────────────────────────────────────────────────────────
  if p_tiers is not null then
    if jsonb_typeof(p_tiers) <> 'array' or jsonb_array_length(p_tiers) > 50 then
      raise exception 'invalid_tiers';
    end if;

    for v_tier in select * from jsonb_array_elements(p_tiers) loop
      if jsonb_typeof(v_tier) <> 'object'
         or nullif(btrim(coalesce(v_tier->>'title', '')), '') is null
         or char_length(v_tier->>'title') > 160 then
        raise exception 'invalid_tier_title';
      end if;
      if v_tier->>'price_cents' is null or v_tier->>'price_cents' !~ '^\d{1,9}$' then
        raise exception 'invalid_tier_price';
      end if;
      if v_tier ? 'inventory_total'
         and jsonb_typeof(v_tier->'inventory_total') <> 'null'
         and v_tier->>'inventory_total' !~ '^\d{1,7}$' then
        raise exception 'invalid_tier_inventory';
      end if;
      begin
        v_sale_start := (v_tier->>'sale_start')::timestamptz;
        v_sale_end   := (v_tier->>'sale_end')::timestamptz;
      exception when others then
        raise exception 'invalid_tier_sale_window';
      end;
      if v_sale_start is not null and v_sale_end is not null and v_sale_end <= v_sale_start then
        raise exception 'invalid_tier_sale_window';
      end if;

      v_price := (v_tier->>'price_cents')::integer;
      v_inventory := case
        when v_tier ? 'inventory_total' and jsonb_typeof(v_tier->'inventory_total') <> 'null'
          then (v_tier->>'inventory_total')::integer
        else null
      end;

      if v_tier ? 'id' and nullif(v_tier->>'id', '') is not null then
        -- postojeći tier
        begin
          v_tier_id := (v_tier->>'id')::uuid;
        exception when others then
          raise exception 'invalid_tier_id';
        end;
        select * into v_existing from ulaznice.ticket_tiers
          where id = v_tier_id and event_id = p_campaign_id
          for update;
        if not found then raise exception 'tier_not_found'; end if;

        -- nakon objave: cijena i imenska su zaključane (kupci kupuju pod tim uvjetima)
        if v_event.state <> 'draft'
           and (v_existing.price_cents <> v_price
                or v_existing.imenska <> coalesce((v_tier->>'imenska')::boolean, v_existing.imenska)) then
          raise exception 'tier_locked';
        end if;
        if v_inventory is not null and v_inventory < v_existing.inventory_claimed then
          raise exception 'inventory_below_claimed';
        end if;

        update ulaznice.ticket_tiers set
          title           = btrim(v_tier->>'title'),
          description     = case when v_tier ? 'description'
                                 then ulaznice.sanitize_ugc(v_tier->>'description')
                                 else description end,
          price_cents     = v_price,
          imenska         = coalesce((v_tier->>'imenska')::boolean, imenska),
          inventory_total = case when v_tier ? 'inventory_total' then v_inventory else inventory_total end,
          sale_start      = case when v_tier ? 'sale_start' then v_sale_start else sale_start end,
          sale_end        = case when v_tier ? 'sale_end' then v_sale_end else sale_end end,
          sort            = coalesce((v_tier->>'sort')::integer, sort),
          updated_at      = now()
        where id = v_tier_id;
        v_updated := v_updated + 1;
      else
        -- novi tier (smije i nakon objave — npr. Early Bird → Regular faza)
        insert into ulaznice.ticket_tiers (
          event_id, title, description, price_cents, inventory_total,
          imenska, sale_start, sale_end, sort
        ) values (
          p_campaign_id, btrim(v_tier->>'title'),
          ulaznice.sanitize_ugc(v_tier->>'description'),
          v_price, v_inventory,
          coalesce((v_tier->>'imenska')::boolean, false),
          v_sale_start, v_sale_end,
          coalesce((v_tier->>'sort')::integer,
                   (select coalesce(max(t.sort), -1) + 1 from ulaznice.ticket_tiers t
                     where t.event_id = p_campaign_id))
        );
        v_added := v_added + 1;
      end if;
    end loop;
  end if;

  return jsonb_build_object(
    'campaign_id', p_campaign_id,
    'updated', true,
    'tiers_updated', v_updated,
    'tiers_added', v_added
  );
end;
$$;

revoke execute on function ulaznice.update_event(
  uuid, text, text, text, text, text, text, timestamptz, timestamptz, text,
  text, text, text, text, text, text, jsonb, jsonb, text, numeric, numeric, text
) from public, anon;
grant execute on function ulaznice.update_event(
  uuid, text, text, text, text, text, text, timestamptz, timestamptz, text,
  text, text, text, text, text, text, jsonb, jsonb, text, numeric, numeric, text
) to authenticated, service_role;

-- ----- publish_event (DEFINER — state machine + allowlist + rail gate) ---------
-- draft → active (objava; postavlja i visibility='public') i active → closed.
-- Aktivacija: admin računa + allowlist + event_rail_ready (Stripe Connect
-- aktivan ILI samo besplatni tierovi, odluka 111). Trigger events_write_guard
-- iste uvjete provjerava i za izravni update. 'funded' ne postoji (odluka 202).
-- Audit događaji i ključ campaign_id ostaju (odluka 304).
create or replace function ulaznice.publish_event(
  p_campaign_id uuid,
  p_target_state text default 'active'
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_event ulaznice.events;
begin
  if (select auth.uid()) is null then raise exception 'not_authenticated'; end if;
  if p_target_state is null or p_target_state not in ('active', 'closed') then
    raise exception 'invalid_target_state';
  end if;

  select * into v_event from ulaznice.events
    where id = p_campaign_id and deleted_at is null
    for update;
  if not found then raise exception 'campaign_not_found'; end if;
  if not public.has_role_on_account(v_event.account_id, 'admin') then
    raise exception 'not_authorized';
  end if;

  if p_target_state = 'active' then
    if v_event.state <> 'draft' then
      raise exception 'invalid_state_transition';
    end if;
    -- moderacija: samo allowlistani organizatori smiju u javni feed (pilot flag)
    if not exists (
      select 1 from ulaznice.organizer_allowlist al
      where al.account_id = v_event.account_id
    ) then
      raise exception 'organizer_not_allowlisted';
    end if;
    -- rail gate: događaj koji nitko ne može platiti se ne objavljuje
    if not ulaznice.event_rail_ready(v_event.account_id, v_event.id) then
      raise exception 'event_no_working_rail';
    end if;

    update ulaznice.events
       set state = 'active', visibility = 'public', updated_at = now()
     where id = p_campaign_id;

    perform public.log_event('event.published', v_event.account_id,
      jsonb_build_object('campaign_id', p_campaign_id));
  else
    if v_event.state <> 'active' then
      raise exception 'invalid_state_transition';
    end if;

    update ulaznice.events
       set state = 'closed', updated_at = now()
     where id = p_campaign_id;

    perform public.log_event('event.closed', v_event.account_id,
      jsonb_build_object('campaign_id', p_campaign_id));
  end if;

  return jsonb_build_object(
    'campaign_id', p_campaign_id,
    'state', p_target_state,
    'visibility', case when p_target_state = 'active' then 'public'
                       else v_event.visibility end
  );
end;
$$;

revoke execute on function ulaznice.publish_event(uuid, text) from public, anon;
grant execute on function ulaznice.publish_event(uuid, text) to authenticated, service_role;

-- ----- organizer_overview (DEFINER — jedan poziv za organizator UI) ------------
-- Moji org računi (admin) s allowlist/DAC7 statusom + moji događaji s
-- tierovima, uključujući skice. Bez PII kupaca. Oblik JSON-a isti kao original;
-- destination_address je uvijek null (odluka 110), filtar kind='ticket' otpada.
create or replace function ulaznice.organizer_overview()
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_accounts jsonb;
  v_events jsonb;
begin
  if (select auth.uid()) is null then raise exception 'not_authenticated'; end if;

  select coalesce(jsonb_agg(a.account_json order by a.name), '[]'::jsonb) into v_accounts
  from (
    select acc.name, jsonb_build_object(
      'id', acc.id,
      'name', acc.name,
      'is_personal', acc.is_personal_account,
      'allowlisted', exists (
        select 1 from ulaznice.organizer_allowlist al where al.account_id = acc.id
      ),
      'has_record', exists (
        select 1 from ulaznice.organizer_records r where r.account_id = acc.id
      )
    ) as account_json
    from public.accounts acc
    where acc.deleted_at is null
      and public.has_role_on_account(acc.id, 'admin')
  ) a;

  select coalesce(jsonb_agg(e.event_json order by e.created_at desc), '[]'::jsonb) into v_events
  from (
    select ev.created_at, jsonb_build_object(
      'campaign_id', ev.id,
      'account_id', ev.account_id,
      'slug', ev.slug,
      'title', ev.title,
      'state', ev.state,
      'visibility', ev.visibility,
      'destination_address', null,
      'event', jsonb_build_object(
        'event_type', ev.event_type,
        'venue_name', ev.venue_name,
        'venue_address', ev.venue_address,
        'venue_city', ev.venue_city,
        'starts_at', ev.starts_at,
        'ends_at', ev.ends_at,
        'timezone', ev.timezone,
        'description_hr', ev.description_hr,
        'description_en', ev.description_en,
        'cover_image_url', ev.cover_image_url,
        'organizer_name', ev.organizer_name,
        'organizer_email', ev.organizer_email,
        'organizer_web', ev.organizer_web
      ),
      'tiers', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', t.id,
          'title', t.title,
          'description', t.description,
          'price_cents', t.price_cents,
          'inventory_total', t.inventory_total,
          'inventory_claimed', t.inventory_claimed,
          'imenska', t.imenska,
          'sale_start', t.sale_start,
          'sale_end', t.sale_end,
          'sort', t.sort
        ) order by t.sort)
        from ulaznice.ticket_tiers t
        where t.event_id = ev.id
      ), '[]'::jsonb)
    ) as event_json
    from ulaznice.events ev
    where ev.deleted_at is null
      and public.has_role_on_account(ev.account_id, 'admin')
  ) e;

  return jsonb_build_object('accounts', v_accounts, 'events', v_events);
end;
$$;

revoke execute on function ulaznice.organizer_overview() from public, anon;
grant execute on function ulaznice.organizer_overview() to authenticated, service_role;

-- ----- upsert_organizer_record (DEFINER — DAC7 zapis) --------------------------
-- 1:1 port; tablica ulaznice.organizer_records.
create or replace function ulaznice.upsert_organizer_record(
  p_account_id uuid,
  p_legal_name text,
  p_oib text,
  p_address_line text,
  p_city text,
  p_postal_code text,
  p_country_code text default 'HR',
  p_contact_email text default null,
  p_financial_identifier_type text default 'safe_address',
  p_financial_identifier text default null
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
begin
  -- service_role smije izravno (operaterski unos); inače org admin
  if coalesce((select auth.role()), '') <> 'service_role' then
    if (select auth.uid()) is null then raise exception 'not_authenticated'; end if;
    if not public.has_role_on_account(p_account_id, 'admin') then
      raise exception 'not_authorized';
    end if;
  end if;

  if p_legal_name is null or btrim(p_legal_name) = '' or char_length(p_legal_name) > 200 then
    raise exception 'invalid_legal_name';
  end if;
  if p_oib is null or p_oib !~ '^\d{11}$' then
    raise exception 'invalid_oib';
  end if;
  if p_address_line is null or btrim(p_address_line) = '' or char_length(p_address_line) > 200 then
    raise exception 'invalid_address';
  end if;
  if p_city is null or btrim(p_city) = '' or char_length(p_city) > 80 then
    raise exception 'invalid_city';
  end if;
  if p_postal_code is null or btrim(p_postal_code) = '' or char_length(p_postal_code) > 20 then
    raise exception 'invalid_postal_code';
  end if;
  if p_country_code is null or p_country_code !~ '^[A-Z]{2}$' then
    raise exception 'invalid_country_code';
  end if;
  if p_contact_email is not null and char_length(p_contact_email) > 200 then
    raise exception 'invalid_contact_email';
  end if;
  if p_financial_identifier_type is null
     or p_financial_identifier_type not in ('iban', 'safe_address') then
    raise exception 'invalid_financial_identifier_type';
  end if;
  if p_financial_identifier is null
     or (p_financial_identifier_type = 'iban'
         and p_financial_identifier !~ '^[A-Z]{2}\d{2}[A-Z0-9]{1,30}$')
     or (p_financial_identifier_type = 'safe_address'
         and p_financial_identifier !~ '^0x[0-9a-fA-F]{40}$') then
    raise exception 'invalid_financial_identifier';
  end if;

  insert into ulaznice.organizer_records (
    account_id, legal_name, oib, address_line, city, postal_code,
    country_code, contact_email, financial_identifier_type, financial_identifier
  ) values (
    p_account_id, btrim(p_legal_name), p_oib, btrim(p_address_line), btrim(p_city),
    btrim(p_postal_code), p_country_code,
    nullif(btrim(coalesce(p_contact_email, '')), ''),
    p_financial_identifier_type, p_financial_identifier
  )
  on conflict (account_id) do update set
    legal_name                = excluded.legal_name,
    oib                       = excluded.oib,
    address_line              = excluded.address_line,
    city                      = excluded.city,
    postal_code               = excluded.postal_code,
    country_code              = excluded.country_code,
    contact_email             = excluded.contact_email,
    financial_identifier_type = excluded.financial_identifier_type,
    financial_identifier      = excluded.financial_identifier,
    updated_at                = now();

  -- audit bez PII u payloadu
  perform public.log_event('organizer_record.upserted', p_account_id,
    jsonb_build_object('account_id', p_account_id));

  return jsonb_build_object('account_id', p_account_id, 'saved', true);
end;
$$;

revoke execute on function ulaznice.upsert_organizer_record(
  uuid, text, text, text, text, text, text, text, text, text
) from public, anon;
grant execute on function ulaznice.upsert_organizer_record(
  uuid, text, text, text, text, text, text, text, text, text
) to authenticated, service_role;

-- ----- delete_event_draft (DEFINER — meko brisanje skice) ----------------------
-- Admin računa briše svoju skicu bez ijedne narudžbe (deleted_at). RPC jer
-- RLS events_update provjerava i events_select (deleted_at is null), pa
-- korisnikov soft-delete PATCH-om pada. Bez campaign_not_tickets.
create or replace function ulaznice.delete_event_draft(p_campaign_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_event ulaznice.events;
begin
  if (select auth.uid()) is null then raise exception 'not_authenticated'; end if;

  select * into v_event from ulaznice.events
    where id = p_campaign_id and deleted_at is null
    for update;
  if not found then raise exception 'campaign_not_found'; end if;
  if not public.has_role_on_account(v_event.account_id, 'admin') then
    raise exception 'not_authorized';
  end if;
  if v_event.state <> 'draft' then raise exception 'event_not_draft'; end if;
  if exists (select 1 from ulaznice.orders o where o.event_id = p_campaign_id) then
    raise exception 'event_has_orders';
  end if;

  update ulaznice.events
    set deleted_at = now(), updated_at = now()
    where id = p_campaign_id;

  return jsonb_build_object('campaign_id', p_campaign_id, 'deleted', true);
end;
$$;

revoke execute on function ulaznice.delete_event_draft(uuid) from public, anon;
grant execute on function ulaznice.delete_event_draft(uuid) to authenticated, service_role;

-- ----- izravni pisi edge funkcije events-organizer (provjera, bez promjena) ----
-- Edge danas (index.ts:67-90) korisnikovim klijentom: čita state događaja,
-- briše tierove skice, radi `update events` (gallery, attendance_mode) i
-- upsert u event_access. U ulaznice to pokrivaju S2 grantovi i politike:
-- events_select/events_update (član/admin računa), ticket_tiers_write i
-- event_access_admin (admin računa, for all). Nova politika nije potrebna.

notify pgrst, 'reload schema';

select 'OK ulaznice_rpc_eventi' as status;
