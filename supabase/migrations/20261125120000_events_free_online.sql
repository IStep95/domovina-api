-- =============================================================================
-- Događaji: besplatni i online
--
-- Izvor: domovina-ulaznice, Ivanov zahtjev 2026-11-25 („event može biti
-- komercijalni ili besplatan, fizički ili virtualni”).
--
-- 1. `events.attendance_mode` ('physical' | 'online', default 'physical').
--    Javno polje (feed ga vraća). Online događaj i dalje ima venue_name i
--    venue_city (NOT NULL); events-organizer im daje „Online” kad ih
--    organizator ne upiše, pa feed, mail i filtar po gradu rade bez izmjena.
--
-- 2. `event_access` — link za pristup online događaju. Namjerno NIJE stupac
--    u `events`: anon ima select na objavljene događaje, a link smiju vidjeti
--    samo vlasnici ulaznica. Čita ga admin računa (editor) i service_role
--    (Worker ga šalje u mailu s ulaznicama i na stranici narudžbe).
--
-- 3. Besplatne ulaznice: `create_ticket_order` prima tier s cijenom 0 (prije
--    `tier_price_missing`; `amount_positive` sada dopušta 0 za narudžbu s
--    tierom), a `confirm_ticket_order_offchain` prima rail
--    'free' — samo za narudžbu od 0 centi (`order_not_free`). Potvrđuje je
--    events-order odmah nakon rezervacije (service klijent); Stripe ne
--    sudjeluje. Tijela obiju funkcija su doslovne kopije (20260716120200 i
--    20260803120000) s izmjenama samo u redovima označenim „2026-11-25”.
--
-- Idempotentno: `if not exists`, drop/add ograničenja, `create or replace`,
-- drop/create policyja. Drugi run = no-op.
-- =============================================================================

-- ----- 1. attendance_mode -----------------------------------------------------
alter table pinka_finance.events
  add column if not exists attendance_mode text not null default 'physical';
alter table pinka_finance.events drop constraint if exists events_attendance_mode_chk;
alter table pinka_finance.events
  add constraint events_attendance_mode_chk check (attendance_mode in ('physical', 'online'));
comment on column pinka_finance.events.attendance_mode is
  'physical | online. Link online događaja je u event_access (nije javan).';

-- ----- 2. event_access ----------------------------------------------------------
create table if not exists pinka_finance.event_access (
  campaign_id uuid primary key references pinka_finance.campaigns(id) on delete cascade,
  online_url text,
  updated_at timestamptz not null default now(),
  constraint event_access_online_url_chk
    check (online_url is null or (online_url ~ '^https://\S+$' and char_length(online_url) <= 1000))
);
comment on table pinka_finance.event_access is
  'Podaci samo za vlasnike ulaznica (link online događaja). Bez anon pristupa.';

alter table pinka_finance.event_access enable row level security;
revoke all on pinka_finance.event_access from public, anon;
grant select, insert, update, delete on pinka_finance.event_access to authenticated, service_role;

drop policy if exists event_access_admin on pinka_finance.event_access;
create policy event_access_admin on pinka_finance.event_access
  for all to authenticated
  using (
    exists (
      select 1 from pinka_finance.campaigns c
      where c.id = campaign_id and public.has_role_on_account(c.account_id, 'admin')
    )
  )
  with check (
    exists (
      select 1 from pinka_finance.campaigns c
      where c.id = campaign_id and public.has_role_on_account(c.account_id, 'admin')
    )
  );

-- ----- 3. besplatne ulaznice ----------------------------------------------------
alter table pinka_finance.contributions drop constraint if exists contributions_payment_rail_chk;
alter table pinka_finance.contributions
  add constraint contributions_payment_rail_chk
    check (payment_rail in ('onchain', 'stripe', 'free')) not valid;

-- Narudžba ulaznica (tier_id) smije biti 0 centi; donacije i dalje > 0.
alter table pinka_finance.contributions drop constraint if exists amount_positive;
alter table pinka_finance.contributions
  add constraint amount_positive check (amount_cents > 0 or (amount_cents = 0 and tier_id is not null));

create or replace function pinka_finance.create_ticket_order(
  p_order_id uuid,
  p_campaign_id uuid,
  p_tier_id uuid,
  p_quantity integer,
  p_holders jsonb default '[]'::jsonb,
  p_payer_address text default null
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_campaign pinka_finance.campaigns;
  v_tier pinka_finance.campaign_tiers;
  v_existing pinka_finance.contributions;
  v_account uuid;
  v_verified boolean := false;
  v_holders jsonb := '[]'::jsonb;
  v_holder jsonb;
  v_recent integer;
  v_expires timestamptz;
  i integer;
begin
  if p_order_id is null then raise exception 'order_id_required'; end if;
  if p_quantity is null or p_quantity < 1 or p_quantity > 10 then
    raise exception 'invalid_quantity';
  end if;
  if p_payer_address is not null and p_payer_address !~ '^0x[0-9a-fA-F]{40}$' then
    raise exception 'invalid_payer_address';
  end if;

  -- oportunistički housekeeping: oslobodi istekle rezervacije prije checka
  perform pinka_finance.expire_stale_ticket_orders();

  -- ── idempotencija: retry s istim id-em vraća postojeću narudžbu ───────────
  select * into v_existing from pinka_finance.contributions where id = p_order_id;
  if found then
    return jsonb_build_object(
      'order_id', v_existing.id,
      'state', v_existing.state::text,
      'amount_cents', v_existing.amount_cents,
      'currency', v_existing.currency,
      'destination_address', v_existing.destination_address,
      'expires_at', v_existing.reserve_expires_at,
      'existing', true
    );
  end if;

  select * into v_campaign from pinka_finance.campaigns
    where id = p_campaign_id and deleted_at is null;
  if not found then raise exception 'campaign_not_found'; end if;
  if v_campaign.type <> 'tickets' then raise exception 'campaign_not_tickets'; end if;
  if v_campaign.state <> 'active' then raise exception 'campaign_not_active'; end if;

  select * into v_tier from pinka_finance.campaign_tiers
    where id = p_tier_id and campaign_id = p_campaign_id;
  if not found then raise exception 'tier_not_found'; end if;
  if v_tier.kind <> 'ticket' then raise exception 'tier_not_ticket'; end if;
  if v_tier.sale_start is not null and now() < v_tier.sale_start then
    raise exception 'sale_not_started';
  end if;
  if v_tier.sale_end is not null and now() > v_tier.sale_end then
    raise exception 'sale_ended';
  end if;
  -- 2026-11-25: cijena 0 = besplatna ulaznica (potvrđuje je events-order, rail 'free')
  if v_tier.price_cents < 0 then raise exception 'tier_price_missing'; end if;

  -- ── imenska ⇒ qty potpunih imena (trim; višak se odbacuje) ────────────────
  if v_tier.imenska then
    if p_holders is null or jsonb_typeof(p_holders) <> 'array'
       or jsonb_array_length(p_holders) < p_quantity then
      raise exception 'holders_incomplete';
    end if;
    for i in 0..(p_quantity - 1) loop
      v_holder := p_holders->i;
      if jsonb_typeof(v_holder) <> 'object'
         or nullif(btrim(coalesce(v_holder->>'full_name', '')), '') is null then
        raise exception 'holders_incomplete';
      end if;
      if char_length(v_holder->>'full_name') > 120
         or char_length(coalesce(v_holder->>'email', '')) > 200 then
        raise exception 'invalid_holder';
      end if;
      v_holders := v_holders || jsonb_build_object(
        'full_name', btrim(v_holder->>'full_name'),
        'email', nullif(btrim(coalesce(v_holder->>'email', '')), '')
      );
    end loop;
  end if;

  -- doprinositeljev personal account + KYC snapshot (kao create_contribution)
  select id into v_account from public.accounts
    where primary_owner_user_id = (select auth.uid())
      and is_personal_account = true
      and deleted_at is null
    limit 1;
  if (select auth.uid()) is not null then
    select exists(
      select 1 from public.identity_verifications iv
       where iv.user_id = (select auth.uid())
    ) into v_verified;
  end if;

  -- ── rate limit: max 10 narudžbi / h po kupcu (account ili payer Safe) ─────
  select count(*) into v_recent
  from pinka_finance.contributions c
  where c.created_at > now() - interval '1 hour'
    and (
      (v_account is not null and c.contributor_account_id = v_account)
      or (p_payer_address is not null and c.declared_payer_address = lower(p_payer_address))
    );
  if v_recent >= 10 then
    raise exception 'order_rate_limited';
  end if;

  -- ── rezervacija + oversell check u ISTOJ naredbi (row lock na tier) ───────
  update pinka_finance.campaign_tiers
     set inventory_claimed = inventory_claimed + p_quantity,
         updated_at = now()
   where id = p_tier_id
     and (inventory_total is null or inventory_claimed + p_quantity <= inventory_total);
  if not found then
    raise exception 'tier_sold_out';
  end if;

  v_expires := now() + interval '20 minutes';

  insert into pinka_finance.contributions (
    id, campaign_id, tier_id, contributor_account_id,
    amount_cents, currency, quantity, state,
    destination_address, anonymous, contributor_verified,
    holders, reserved, reserve_expires_at, declared_payer_address
  ) values (
    p_order_id, p_campaign_id, p_tier_id, v_account,
    v_tier.price_cents::bigint * p_quantity, v_campaign.currency, p_quantity, 'pending',
    v_campaign.destination_address, false, coalesce(v_verified, false),
    v_holders, true, v_expires,
    case when p_payer_address is null then null else lower(p_payer_address) end
  );

  return jsonb_build_object(
    'order_id', p_order_id,
    'state', 'pending',
    'amount_cents', v_tier.price_cents::bigint * p_quantity,
    'currency', v_campaign.currency,
    'destination_address', v_campaign.destination_address,
    'expires_at', v_expires,
    'existing', false
  );
end;
$$;

create or replace function pinka_finance.confirm_ticket_order_offchain(
  p_order_id uuid,
  p_rail text,
  p_external_ref text,
  p_amount_cents bigint,
  p_payer_email text default null
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_order pinka_finance.contributions;
  v_other uuid;
  v_token text;
  v_serial text;
  v_prefix text;
  v_base integer;
  v_slug text;
  v_holder jsonb;
  v_serials text[] := '{}';
  v_email text;
  i integer;
begin
  -- ── validacija ulaza (strojni kodovi; ovo su programske, ne poslovne greške) ─
  if p_order_id is null then raise exception 'order_id_required'; end if;
  -- 2026-11-25: + 'free'
  if p_rail is null or p_rail not in ('stripe', 'free') then raise exception 'invalid_rail'; end if;
  if p_external_ref is null or p_external_ref !~ '^[A-Za-z0-9_-]{6,255}$' then
    raise exception 'invalid_external_ref';
  end if;
  v_email := nullif(btrim(coalesce(p_payer_email, '')), '');
  if v_email is not null and char_length(v_email) > 200 then
    raise exception 'invalid_payer_email';
  end if;

  select * into v_order from pinka_finance.contributions
    where id = p_order_id
    for update;
  if not found then raise exception 'order_not_found'; end if;
  if v_order.tier_id is null or not v_order.reserved then
    raise exception 'not_a_ticket_order';
  end if;
  -- 2026-11-25: rail 'free' smije potvrditi samo narudžbu od 0 centi
  if p_rail = 'free' and (v_order.amount_cents <> 0 or coalesce(p_amount_cents, -1) <> 0) then
    raise exception 'order_not_free';
  end if;

  -- ── 2. idempotencija: ista uplata na istu narudžbu = no-op ─────────────────
  if v_order.state = 'paid' then
    if v_order.payment_rail = p_rail
       and v_order.external_payment_ref is not distinct from p_external_ref then
      select coalesce(array_agg(t.serial order by t.serial), '{}') into v_serials
        from pinka_finance.tickets t where t.contribution_id = p_order_id;
      return jsonb_build_object('status', 'already_paid', 'order_id', p_order_id, 'serials', v_serials);
    end if;
    -- DRUGA uplata na već plaćenu narudžbu: kupac je naplaćen dvaput →
    -- trag za refund (Worker), ne exception (rollbackao bi trag).
    insert into pinka_finance.contribution_events (contribution_id, campaign_id, event_type, payload)
    values (p_order_id, v_order.campaign_id, 'ticket_order.duplicate_payment',
            jsonb_build_object('rail', p_rail, 'external_ref', p_external_ref,
                               'credited_rail', v_order.payment_rail,
                               'credited_ref', v_order.external_payment_ref,
                               'amount_cents', p_amount_cents));
    return jsonb_build_object('status', 'duplicate_payment', 'order_id', p_order_id,
                              'credited_ref', v_order.external_payment_ref);
  end if;
  if v_order.state not in ('pending', 'expired') then
    raise exception 'order_not_payable';
  end if;

  -- ── 3. (rail, ref) smije kreditirati SAMO jednu narudžbu ───────────────────
  select id into v_other from pinka_finance.contributions
    where payment_rail = p_rail and external_payment_ref = p_external_ref
      and id <> p_order_id;
  if found then
    insert into pinka_finance.contribution_events (contribution_id, campaign_id, event_type, payload)
    values (p_order_id, v_order.campaign_id, 'ticket_order.match_conflict',
            jsonb_build_object('rail', p_rail, 'external_ref', p_external_ref,
                               'other_contribution_id', v_other));
    return jsonb_build_object('status', 'tx_already_credited', 'order_id', p_order_id);
  end if;

  -- ── 4. iznos mora pokriti narudžbu ─────────────────────────────────────────
  if p_amount_cents is null or p_amount_cents < v_order.amount_cents then
    insert into pinka_finance.contribution_events (contribution_id, campaign_id, event_type, payload)
    values (p_order_id, v_order.campaign_id, 'ticket_order.underpaid',
            jsonb_build_object('rail', p_rail, 'external_ref', p_external_ref,
                               'expected_cents', v_order.amount_cents,
                               'received_cents', p_amount_cents));
    return jsonb_build_object('status', 'amount_insufficient', 'order_id', p_order_id,
                              'expected_cents', v_order.amount_cents, 'received_cents', p_amount_cents);
  end if;

  -- ── 5. istekla rezervacija, a uplata je stvarno naplaćena → re-rezerviraj ──
  -- (poznati prozor: Stripe checkout TTL min. 30 min > naša rezervacija 20 min)
  if v_order.state = 'expired' then
    update pinka_finance.campaign_tiers
       set inventory_claimed = inventory_claimed + v_order.quantity,
           updated_at = now()
     where id = v_order.tier_id
       and (inventory_total is null or inventory_claimed + v_order.quantity <= inventory_total);
    if not found then
      insert into pinka_finance.contribution_events (contribution_id, campaign_id, event_type, payload)
      values (p_order_id, v_order.campaign_id, 'ticket_order.expired_sold_out',
              jsonb_build_object('rail', p_rail, 'external_ref', p_external_ref));
      return jsonb_build_object('status', 'expired_sold_out', 'order_id', p_order_id);
    end if;
  end if;

  update pinka_finance.contributions
     set state                 = 'paid',
         payment_rail          = p_rail,
         external_payment_ref  = p_external_ref,
         amount_received_cents = p_amount_cents,
         buyer_email           = coalesce(v_email, buyer_email),
         paid_at               = now(),
         updated_at            = now()
   where id = p_order_id;

  -- ── izdavanje ulaznica: identično confirm_ticket_order ────────────────────
  -- advisory lock po kampanji serijalizira brojač seriala (race dva confirma)
  perform pg_advisory_xact_lock(hashtext('pinka_tickets_' || v_order.campaign_id::text));

  select slug::text into v_slug from pinka_finance.campaigns where id = v_order.campaign_id;
  v_prefix := upper(left(regexp_replace(coalesce(v_slug, ''), '[^a-zA-Z]', '', 'g'), 3));
  if v_prefix = '' then v_prefix := 'EVT'; end if;
  select count(*)::integer into v_base from pinka_finance.tickets where campaign_id = v_order.campaign_id;

  for i in 1..v_order.quantity loop
    v_serial := v_prefix || '-' || lpad((v_base + i)::text, 6, '0');
    v_token := encode(extensions.gen_random_bytes(32), 'hex');
    v_holder := case
      when v_order.holders is not null and jsonb_typeof(v_order.holders) = 'array'
        then v_order.holders->(i - 1)
      else null
    end;
    insert into pinka_finance.tickets (
      contribution_id, campaign_id, tier_id, serial,
      holder_name, holder_email, qr_token_hash, qr_token_once, state
    ) values (
      p_order_id, v_order.campaign_id, v_order.tier_id, v_serial,
      -- holder_email ostaje holderov (kao onchain blizanac); e-mail kupca živi
      -- na contributions.buyer_email i ne upisuje se tuđoj ulaznici
      v_holder->>'full_name', v_holder->>'email',
      encode(extensions.digest(v_token, 'sha256'), 'hex'), v_token, 'issued'
    );
    v_serials := v_serials || v_serial;
  end loop;

  insert into pinka_finance.contribution_events (contribution_id, campaign_id, event_type, payload)
  values (p_order_id, v_order.campaign_id, 'tickets.issued',
          jsonb_build_object('count', v_order.quantity, 'serials', to_jsonb(v_serials),
                             'rail', p_rail, 'external_ref', p_external_ref));

  return jsonb_build_object('status', 'paid', 'order_id', p_order_id, 'serials', v_serials);
end;
$$;

revoke execute on function pinka_finance.create_ticket_order(uuid,uuid,uuid,integer,jsonb,text) from public, anon;
grant execute on function pinka_finance.create_ticket_order(uuid,uuid,uuid,integer,jsonb,text) to authenticated, service_role;
revoke execute on function pinka_finance.confirm_ticket_order_offchain(uuid, text, text, bigint, text)
  from public, anon, authenticated;
grant execute on function pinka_finance.confirm_ticket_order_offchain(uuid, text, text, bigint, text)
  to service_role;

notify pgrst, 'reload schema';

select 'OK events_free_online' as status;
