-- =============================================================================
-- Ulaznice: RPC-i narudžbi i ulaznica (S3, skupina A)
--
-- Lanac „odvajanje ulaznica iz pinka_finance”, docs/ulaznice-shema/. Port iz
-- pinka_finance u shemu `ulaznice` (20261125150000). Ova migracija ne dira
-- ništa u pinka_finance; stari RPC-i ostaju do S7.
--
-- Izvori (zadnja definicija svake funkcije):
--   create_ticket_order, confirm_ticket_order_offchain  20261125120000_events_free_online.sql
--   expire_stale_ticket_orders, deliver_ticket_orders,
--   list_my_tickets                                     20260716120200_events_ticketing_rpcs.sql
--   refund_ticket_order                                 20260803130000_events_stripe_refund.sql
--   redeem_ticket, void_ticket                          20260717120000_events_checkin.sql
--   rotate_ticket_tokens                                git show e77f9ae:…/20260903120100_events_rotate_ticket_tokens.sql
--                                                       (nikad primijenjen na pinka_finance; odluka 111)
--   tg_order_state                                      reserved grane iz tg_contribution_state (pinka_finance),
--                                                       20260722120000_pinka_slots.sql:841-888
--
-- Mapiranje (odluke 100, 113): campaigns+events → events; campaign_tiers →
-- ticket_tiers; contributions → orders; contribution_events → order_events;
-- campaign_id → event_id, contribution_id → order_id, contributor_account_id →
-- buyer_account_id. Imena RPC-a, parametri (i p_campaign_id) i oblik JSON-a
-- ostaju isti (odluka 3), uključujući ključeve kojima vrijednost više ne postoji
-- (destination_address, tx_hash → null) i imena stupaca list_my_tickets.
--
-- Odstupanja od originala (prijedlog odluka 300+, detalj uz svaku funkciju):
--   * onchain ukinut (odluka 110): nema confirm_ticket_order; create_ticket_order
--     zadržava parametar p_payer_address radi potpisa, ali ne-null vrijednost
--     baca 'onchain_rail_removed';
--   * create_ticket_order postavlja payment_rail sam ('free' za 0 €, inače
--     'stripe'; odluka 201); provjere type='tickets' i kind='ticket' otpadaju
--     (svaki event/tier u ulaznice je ticketing); rate limit samo po računu;
--   * confirm_ticket_order_offchain: rail 'stripe' na narudžbi od 0 € baca
--     'invalid_rail' (u pinka_finance je prolazio; ovdje bi pao na CHECK
--     orders_amount_free);
--   * tg_order_state NEMA granu expired→paid iz pinka_slots: confirm sam
--     re-rezervira istekle narudžbe (korak 5, s provjerom overselle), pa je
--     ta grana u pinka_finance dvaput brojala inventar (provjereno: 2 ulaznice
--     → inventory_claimed 4);
--   * refund_ticket_order ne piše campaign_stats (odluka 104);
--   * advisory lock serijala: ključ 'ulaznice_tickets_' || event_id.
-- =============================================================================

-- ----- expire_stale_ticket_orders (rezervacija s TTL-om — otpuštanje) ---------
-- Inventar otpušta ulaznice.tg_order_state (pending→expired, reserved).
create or replace function ulaznice.expire_stale_ticket_orders()
returns integer
language plpgsql security definer set search_path = ''
as $$
declare v_expired integer;
begin
  update ulaznice.orders
     set state = 'expired', updated_at = now()
   where state = 'pending'
     and reserved
     and reserve_expires_at is not null
     and reserve_expires_at < now();
  get diagnostics v_expired = row_count;
  return v_expired;
end;
$$;

revoke execute on function ulaznice.expire_stale_ticket_orders() from public, anon, authenticated;
grant execute on function ulaznice.expire_stale_ticket_orders() to service_role;

-- ----- tg_order_state — audit tranzicije + inventar rezervacija ---------------
-- Iz tg_contribution_state (pinka_finance) uzete su samo ticketing grane:
--   * svaka tranzicija stanja → order_events 'contribution.<state>' (isti
--     event_type kao kopirana povijest; payload bez tx_hash, nema onchaina)
--   * pending→expired, reserved: rezervacija se OTPUŠTA (floor 0)
--   * →paid, NE reserved: inventar se uzima sada (rezervirane su ubrojane na
--     create_ticket_order; grana ostaje radi vjernosti, RPC uvijek stavlja reserved)
-- Grana expired→paid (pinka_slots §16) namjerno NIJE prenesena: confirm_ticket_
-- order_offchain korak 5 već re-rezervira uz provjeru kapaciteta.
-- Donacijski dio (campaign_stats, funded, token_positions, slotovi) otpada.
create or replace function ulaznice.tg_order_state() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.state = old.state then
    return new;
  end if;

  insert into ulaznice.order_events (order_id, event_id, event_type, payload)
  values (
    new.id, new.event_id, 'contribution.' || new.state,
    jsonb_build_object(
      'from', old.state,
      'amount_received_cents', new.amount_received_cents
    )
  );

  if new.state = 'expired' and old.state = 'pending' and new.reserved then
    update ulaznice.ticket_tiers
       set inventory_claimed = greatest(inventory_claimed - new.quantity, 0),
           updated_at = now()
     where id = new.tier_id;
  end if;

  if new.state = 'paid' and not new.reserved then
    update ulaznice.ticket_tiers
       set inventory_claimed = inventory_claimed + new.quantity,
           updated_at = now()
     where id = new.tier_id;
  end if;

  return new;
end;
$$;

revoke execute on function ulaznice.tg_order_state() from public, anon, authenticated;

drop trigger if exists trg_order_state on ulaznice.orders;
create trigger trg_order_state
  after update of state on ulaznice.orders
  for each row execute function ulaznice.tg_order_state();

-- ----- create_ticket_order (narudžba + rezervacija) ---------------------------
-- p_order_id je client-generated random UUID: idempotency ključ i bearer
-- capability. p_holders: [{full_name, email?}] — imenska ⇒ qty potpunih imena.
-- p_payer_address ostaje u potpisu (odluka 3), onchain je ukinut (odluka 110).
create or replace function ulaznice.create_ticket_order(
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
  v_event ulaznice.events;
  v_tier ulaznice.ticket_tiers;
  v_existing ulaznice.orders;
  v_account uuid;
  v_verified boolean := false;
  v_holders jsonb := '[]'::jsonb;
  v_holder jsonb;
  v_recent integer;
  v_expires timestamptz;
  v_amount bigint;
  i integer;
begin
  if p_order_id is null then raise exception 'order_id_required'; end if;
  if p_quantity is null or p_quantity < 1 or p_quantity > 10 then
    raise exception 'invalid_quantity';
  end if;
  -- odluka 110: onchain rail ukinut (bila je grana declared_payer_address)
  if p_payer_address is not null then
    raise exception 'onchain_rail_removed'
      using hint = 'Onchain plaćanje ulaznica je ukinuto; koristi Stripe.';
  end if;

  -- oportunistički housekeeping: oslobodi istekle rezervacije prije checka
  perform ulaznice.expire_stale_ticket_orders();

  -- ── idempotencija: retry s istim id-em vraća postojeću narudžbu ───────────
  select * into v_existing from ulaznice.orders where id = p_order_id;
  if found then
    return jsonb_build_object(
      'order_id', v_existing.id,
      'state', v_existing.state,
      'amount_cents', v_existing.amount_cents,
      'currency', v_existing.currency,
      'destination_address', null,      -- ključ ostaje (odluka 3), onchaina nema
      'expires_at', v_existing.reserve_expires_at,
      'existing', true
    );
  end if;

  select * into v_event from ulaznice.events
    where id = p_campaign_id and deleted_at is null;
  if not found then raise exception 'campaign_not_found'; end if;
  if v_event.state <> 'active' then raise exception 'campaign_not_active'; end if;

  select * into v_tier from ulaznice.ticket_tiers
    where id = p_tier_id and event_id = p_campaign_id;
  if not found then raise exception 'tier_not_found'; end if;
  if v_tier.sale_start is not null and now() < v_tier.sale_start then
    raise exception 'sale_not_started';
  end if;
  if v_tier.sale_end is not null and now() > v_tier.sale_end then
    raise exception 'sale_ended';
  end if;
  -- cijena 0 = besplatna ulaznica (potvrđuje je events-order, rail 'free')
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

  -- kupčev personal account + KYC snapshot
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

  -- ── rate limit: max 10 narudžbi / h po kupčevom računu ────────────────────
  if v_account is not null then
    select count(*) into v_recent
    from ulaznice.orders o
    where o.buyer_account_id = v_account
      and o.created_at > now() - interval '1 hour';
    if v_recent >= 10 then
      raise exception 'order_rate_limited';
    end if;
  end if;

  -- ── rezervacija + oversell check u ISTOJ naredbi (row lock na tier) ───────
  update ulaznice.ticket_tiers
     set inventory_claimed = inventory_claimed + p_quantity,
         updated_at = now()
   where id = p_tier_id
     and (inventory_total is null or inventory_claimed + p_quantity <= inventory_total);
  if not found then
    raise exception 'tier_sold_out';
  end if;

  v_expires := now() + interval '20 minutes';
  v_amount := v_tier.price_cents::bigint * p_quantity;

  insert into ulaznice.orders (
    id, event_id, tier_id, buyer_account_id,
    amount_cents, currency, quantity, state, payment_rail,
    contributor_verified, holders, reserved, reserve_expires_at
  ) values (
    p_order_id, p_campaign_id, p_tier_id, v_account,
    v_amount, v_event.currency, p_quantity, 'pending',
    -- odluka 201: orders.payment_rail nema default
    case when v_amount = 0 then 'free' else 'stripe' end,
    coalesce(v_verified, false), v_holders, true, v_expires
  );

  return jsonb_build_object(
    'order_id', p_order_id,
    'state', 'pending',
    'amount_cents', v_amount,
    'currency', v_event.currency,
    'destination_address', null,
    'expires_at', v_expires,
    'existing', false
  );
end;
$$;

revoke execute on function ulaznice.create_ticket_order(uuid,uuid,uuid,integer,jsonb,text) from public, anon;
grant execute on function ulaznice.create_ticket_order(uuid,uuid,uuid,integer,jsonb,text) to authenticated, service_role;

-- ----- confirm_ticket_order_offchain (service_role; events-stripe-confirm / events-order)
-- Poslovni ishodi kao status jsonb, exceptioni samo za neispravan poziv.
create or replace function ulaznice.confirm_ticket_order_offchain(
  p_order_id uuid,
  p_rail text,
  p_external_ref text,
  p_amount_cents bigint,
  p_payer_email text default null
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_order ulaznice.orders;
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
  -- ── validacija ulaza ───────────────────────────────────────────────────────
  if p_order_id is null then raise exception 'order_id_required'; end if;
  if p_rail is null or p_rail not in ('stripe', 'free') then raise exception 'invalid_rail'; end if;
  if p_external_ref is null or p_external_ref !~ '^[A-Za-z0-9_-]{6,255}$' then
    raise exception 'invalid_external_ref';
  end if;
  v_email := nullif(btrim(coalesce(p_payer_email, '')), '');
  if v_email is not null and char_length(v_email) > 200 then
    raise exception 'invalid_payer_email';
  end if;

  select * into v_order from ulaznice.orders
    where id = p_order_id
    for update;
  if not found then raise exception 'order_not_found'; end if;
  if not v_order.reserved then
    raise exception 'not_a_ticket_order';
  end if;
  -- rail 'free' smije potvrditi samo narudžbu od 0 centi
  if p_rail = 'free' and (v_order.amount_cents <> 0 or coalesce(p_amount_cents, -1) <> 0) then
    raise exception 'order_not_free';
  end if;
  -- ulaznice: 'stripe' na narudžbi od 0 € (u pinka_finance prolazilo; ovdje CHECK orders_amount_free)
  if p_rail = 'stripe' and v_order.amount_cents = 0 then
    raise exception 'invalid_rail';
  end if;

  -- ── 2. idempotencija: ista uplata na istu narudžbu = no-op ─────────────────
  if v_order.state = 'paid' then
    if v_order.payment_rail = p_rail
       and v_order.external_payment_ref is not distinct from p_external_ref then
      select coalesce(array_agg(t.serial order by t.serial), '{}') into v_serials
        from ulaznice.tickets t where t.order_id = p_order_id;
      return jsonb_build_object('status', 'already_paid', 'order_id', p_order_id, 'serials', v_serials);
    end if;
    -- DRUGA uplata na već plaćenu narudžbu → trag za refund, ne exception
    insert into ulaznice.order_events (order_id, event_id, event_type, payload)
    values (p_order_id, v_order.event_id, 'ticket_order.duplicate_payment',
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
  select id into v_other from ulaznice.orders
    where payment_rail = p_rail and external_payment_ref = p_external_ref
      and id <> p_order_id;
  if found then
    insert into ulaznice.order_events (order_id, event_id, event_type, payload)
    values (p_order_id, v_order.event_id, 'ticket_order.match_conflict',
            jsonb_build_object('rail', p_rail, 'external_ref', p_external_ref,
                               'other_contribution_id', v_other));
    return jsonb_build_object('status', 'tx_already_credited', 'order_id', p_order_id);
  end if;

  -- ── 4. iznos mora pokriti narudžbu ─────────────────────────────────────────
  if p_amount_cents is null or p_amount_cents < v_order.amount_cents then
    insert into ulaznice.order_events (order_id, event_id, event_type, payload)
    values (p_order_id, v_order.event_id, 'ticket_order.underpaid',
            jsonb_build_object('rail', p_rail, 'external_ref', p_external_ref,
                               'expected_cents', v_order.amount_cents,
                               'received_cents', p_amount_cents));
    return jsonb_build_object('status', 'amount_insufficient', 'order_id', p_order_id,
                              'expected_cents', v_order.amount_cents, 'received_cents', p_amount_cents);
  end if;

  -- ── 5. istekla rezervacija, a uplata je stvarno naplaćena → re-rezerviraj ──
  -- (jedino mjesto re-rezervacije; tg_order_state za expired→paid ne broji)
  if v_order.state = 'expired' then
    update ulaznice.ticket_tiers
       set inventory_claimed = inventory_claimed + v_order.quantity,
           updated_at = now()
     where id = v_order.tier_id
       and (inventory_total is null or inventory_claimed + v_order.quantity <= inventory_total);
    if not found then
      insert into ulaznice.order_events (order_id, event_id, event_type, payload)
      values (p_order_id, v_order.event_id, 'ticket_order.expired_sold_out',
              jsonb_build_object('rail', p_rail, 'external_ref', p_external_ref));
      return jsonb_build_object('status', 'expired_sold_out', 'order_id', p_order_id);
    end if;
  end if;

  update ulaznice.orders
     set state                 = 'paid',
         payment_rail          = p_rail,
         external_payment_ref  = p_external_ref,
         amount_received_cents = p_amount_cents,
         buyer_email           = coalesce(v_email, buyer_email),
         paid_at               = now(),
         updated_at            = now()
   where id = p_order_id;

  -- ── izdavanje ulaznica ─────────────────────────────────────────────────────
  -- advisory lock po eventu serijalizira brojač seriala (race dva confirma)
  perform pg_advisory_xact_lock(hashtext('ulaznice_tickets_' || v_order.event_id::text));

  select slug::text into v_slug from ulaznice.events where id = v_order.event_id;
  v_prefix := upper(left(regexp_replace(coalesce(v_slug, ''), '[^a-zA-Z]', '', 'g'), 3));
  if v_prefix = '' then v_prefix := 'EVT'; end if;
  select count(*)::integer into v_base from ulaznice.tickets where event_id = v_order.event_id;

  for i in 1..v_order.quantity loop
    v_serial := v_prefix || '-' || lpad((v_base + i)::text, 6, '0');
    v_token := encode(extensions.gen_random_bytes(32), 'hex');
    v_holder := case
      when v_order.holders is not null and jsonb_typeof(v_order.holders) = 'array'
        then v_order.holders->(i - 1)
      else null
    end;
    insert into ulaznice.tickets (
      order_id, event_id, tier_id, serial,
      holder_name, holder_email, qr_token_hash, qr_token_once, state
    ) values (
      p_order_id, v_order.event_id, v_order.tier_id, v_serial,
      -- holder_email ostaje holderov; e-mail kupca živi na orders.buyer_email
      v_holder->>'full_name', v_holder->>'email',
      encode(extensions.digest(v_token, 'sha256'), 'hex'), v_token, 'issued'
    );
    v_serials := v_serials || v_serial;
  end loop;

  insert into ulaznice.order_events (order_id, event_id, event_type, payload)
  values (p_order_id, v_order.event_id, 'tickets.issued',
          jsonb_build_object('count', v_order.quantity, 'serials', to_jsonb(v_serials),
                             'rail', p_rail, 'external_ref', p_external_ref));

  return jsonb_build_object('status', 'paid', 'order_id', p_order_id, 'serials', v_serials);
end;
$$;

revoke execute on function ulaznice.confirm_ticket_order_offchain(uuid, text, text, bigint, text)
  from public, anon, authenticated;
grant execute on function ulaznice.confirm_ticket_order_offchain(uuid, text, text, bigint, text)
  to service_role;

-- ----- deliver_ticket_orders (service_role; poziva events-tickets) ------------
-- QR token se isporučuje JEDNOKRATNO: qr_token_once se briše nakon dostave.
create or replace function ulaznice.deliver_ticket_orders(p_order_ids uuid[])
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_result jsonb;
begin
  if p_order_ids is null or array_length(p_order_ids, 1) is null then
    return '[]'::jsonb;
  end if;
  if array_length(p_order_ids, 1) > 50 then
    raise exception 'too_many_orders';
  end if;

  perform ulaznice.expire_stale_ticket_orders();

  select coalesce(jsonb_agg(o.order_json), '[]'::jsonb) into v_result
  from (
    select jsonb_build_object(
      'order_id', c.id,
      'state', c.state,
      'quantity', c.quantity,
      'amount_cents', c.amount_cents,
      'currency', c.currency,
      'expires_at', c.reserve_expires_at,
      'tx_hash', null,                  -- ključ ostaje (odluka 3), onchaina nema
      'tickets', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', t.id,
          'serial', t.serial,
          'holder_name', t.holder_name,
          'holder_email', t.holder_email,
          'state', t.state::text,
          'checked_in_at', t.checked_in_at,
          'qr_token', t.qr_token_once
        ) order by t.serial)
        from ulaznice.tickets t
        where t.order_id = c.id
      ), '[]'::jsonb)
    ) as order_json
    from ulaznice.orders c
    where c.id = any(p_order_ids)
      and c.reserved
  ) o;

  update ulaznice.tickets
     set qr_token_once = null,
         updated_at = now()
   where order_id = any(p_order_ids)
     and qr_token_once is not null;

  return v_result;
end;
$$;

revoke execute on function ulaznice.deliver_ticket_orders(uuid[]) from public, anon, authenticated;
grant execute on function ulaznice.deliver_ticket_orders(uuid[]) to service_role;

-- ----- list_my_tickets (authenticated) ----------------------------------------
-- Imena izlaznih stupaca (contribution_id, campaign_id, campaign_title) ostaju
-- radi odluke 3. BEZ QR tokena.
create or replace function ulaznice.list_my_tickets()
returns table (
  ticket_id uuid,
  contribution_id uuid,
  campaign_id uuid,
  campaign_title text,
  serial text,
  holder_name text,
  state text,
  checked_in_at timestamptz,
  created_at timestamptz
)
language sql stable security definer set search_path = ''
as $$
  select t.id, t.order_id, t.event_id, e.title,
         t.serial, t.holder_name, t.state::text, t.checked_in_at, t.created_at
  from ulaznice.tickets t
  join ulaznice.orders o on o.id = t.order_id
  join ulaznice.events e on e.id = t.event_id
  where o.buyer_account_id is not null
    and public.is_account_member(o.buyer_account_id)
  order by t.created_at desc, t.serial;
$$;

revoke execute on function ulaznice.list_my_tickets() from public, anon;
grant execute on function ulaznice.list_my_tickets() to authenticated, service_role;

-- ----- refund_ticket_order (service_role; Worker nakon Stripe povrata) --------
-- Bez campaign_stats (odluka 104): pregled organizatora računa iz orders.
create or replace function ulaznice.refund_ticket_order(
  p_order_id uuid,
  p_amount_cents bigint default null,     -- null = pun povrat
  p_reason text default null,             -- expired_sold_out | duplicate_payment | organizator | dispute
  p_external_ref text default null        -- pi_… povrata
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_order ulaznice.orders;
  v_voided integer := 0;
  v_kept integer := 0;
begin
  if p_order_id is null then raise exception 'order_id_required'; end if;
  if p_reason is not null and char_length(p_reason) > 60 then raise exception 'invalid_reason'; end if;

  select * into v_order from ulaznice.orders
    where id = p_order_id
    for update;
  if not found then
    return jsonb_build_object('status', 'not_found', 'order_id', p_order_id);
  end if;
  if not v_order.reserved then
    return jsonb_build_object('status', 'not_a_ticket_order', 'order_id', p_order_id);
  end if;

  if v_order.state = 'refunded' then
    select count(*) filter (where t.state = 'void'),
           count(*) filter (where t.state = 'checked_in')
      into v_voided, v_kept
      from ulaznice.tickets t where t.order_id = p_order_id;
    return jsonb_build_object('status', 'already_refunded', 'order_id', p_order_id,
                              'voided', v_voided, 'kept_checked_in', v_kept);
  end if;
  if v_order.state <> 'paid' then
    insert into ulaznice.order_events (order_id, event_id, event_type, payload)
    values (p_order_id, v_order.event_id, 'ticket_order.refund_unexpected',
            jsonb_build_object('state', v_order.state, 'reason', p_reason,
                               'external_ref', p_external_ref));
    return jsonb_build_object('status', 'not_paid', 'order_id', p_order_id,
                              'state', v_order.state);
  end if;

  -- ── poništi izdane ulaznice; iskorištene ostaju ────────────────────────────
  update ulaznice.tickets
     set state = 'void', updated_at = now()
   where order_id = p_order_id and state = 'issued';
  get diagnostics v_voided = row_count;

  select count(*)::integer into v_kept
    from ulaznice.tickets
   where order_id = p_order_id and state = 'checked_in';

  -- ── oslobodi inventar za poništene komade ─────────────────────────────────
  if v_voided > 0 then
    update ulaznice.ticket_tiers
       set inventory_claimed = greatest(inventory_claimed - v_voided, 0),
           updated_at = now()
     where id = v_order.tier_id;
  end if;

  -- tg_order_state loguje tranziciju (contribution.refunded)
  update ulaznice.orders
     set state = 'refunded', updated_at = now()
   where id = p_order_id;

  insert into ulaznice.order_events (order_id, event_id, event_type, payload)
  values (p_order_id, v_order.event_id, 'ticket_order.refunded',
          jsonb_build_object('reason', p_reason, 'external_ref', p_external_ref,
                             'amount_cents', coalesce(p_amount_cents, v_order.amount_cents),
                             'voided', v_voided, 'kept_checked_in', v_kept,
                             'rail', v_order.payment_rail));

  return jsonb_build_object('status', 'refunded', 'order_id', p_order_id,
                            'voided', v_voided, 'kept_checked_in', v_kept);
end;
$$;

revoke execute on function ulaznice.refund_ticket_order(uuid, bigint, text, text)
  from public, anon, authenticated;
grant execute on function ulaznice.refund_ticket_order(uuid, bigint, text, text)
  to service_role;

-- ----- redeem_ticket (org admin; events-checkin user klijentom) ---------------
-- Poslovni ishodi (not_found / void / already_checked_in) su status jsonb;
-- exceptioni samo invalid_token, not_authenticated, not_authorized.
create or replace function ulaznice.redeem_ticket(p_qr_token text)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_hash text;
  v_ticket ulaznice.tickets;
  v_event ulaznice.events;
  v_tier_title text;
  v_by_email text;
  v_count integer;
  v_now timestamptz;
begin
  if (select auth.uid()) is null then
    raise exception 'not_authenticated';
  end if;
  if p_qr_token is null or p_qr_token !~ '^[0-9a-f]{64}$' then
    raise exception 'invalid_token';
  end if;

  v_hash := encode(extensions.digest(p_qr_token, 'sha256'), 'hex');

  select * into v_ticket
    from ulaznice.tickets
   where qr_token_hash = v_hash
     for update;
  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;

  select * into v_event
    from ulaznice.events
   where id = v_ticket.event_id and deleted_at is null;
  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;

  if not public.has_role_on_account(v_event.account_id, 'admin') then
    raise exception 'not_authorized';
  end if;

  select title into v_tier_title
    from ulaznice.ticket_tiers
   where id = v_ticket.tier_id;

  if v_ticket.state = 'void' then
    return jsonb_build_object(
      'status', 'void',
      'serial', v_ticket.serial,
      'event_title', v_event.title
    );
  end if;

  if v_ticket.state = 'checked_in' then
    select u.email into v_by_email from auth.users u where u.id = v_ticket.checked_in_by;

    insert into ulaznice.order_events (order_id, event_id, event_type, payload)
    values (v_ticket.order_id, v_ticket.event_id, 'ticket.checkin_duplicate',
            jsonb_build_object('serial', v_ticket.serial,
                               'first_checked_in_at', v_ticket.checked_in_at,
                               'attempted_by', (select auth.uid())));

    select count(*)::integer into v_count
      from ulaznice.tickets
     where event_id = v_ticket.event_id and state = 'checked_in';

    return jsonb_build_object(
      'status', 'already_checked_in',
      'serial', v_ticket.serial,
      'holder_name', v_ticket.holder_name,
      'tier_title', v_tier_title,
      'event_title', v_event.title,
      'checked_in_at', v_ticket.checked_in_at,
      'checked_in_by_email', v_by_email,
      'checked_in_count', v_count
    );
  end if;

  v_now := now();
  update ulaznice.tickets
     set state = 'checked_in',
         checked_in_at = v_now,
         checked_in_by = (select auth.uid()),
         updated_at = v_now
   where id = v_ticket.id and state = 'issued';

  insert into ulaznice.order_events (order_id, event_id, event_type, payload)
  values (v_ticket.order_id, v_ticket.event_id, 'ticket.checked_in',
          jsonb_build_object('serial', v_ticket.serial, 'by', (select auth.uid())));

  select count(*)::integer into v_count
    from ulaznice.tickets
   where event_id = v_ticket.event_id and state = 'checked_in';

  return jsonb_build_object(
    'status', 'checked_in',
    'serial', v_ticket.serial,
    'holder_name', v_ticket.holder_name,
    'tier_title', v_tier_title,
    'event_title', v_event.title,
    'checked_in_at', v_now,
    'checked_in_count', v_count
  );
end;
$$;

revoke execute on function ulaznice.redeem_ticket(text) from public, anon;
grant execute on function ulaznice.redeem_ticket(text) to authenticated, service_role;

-- ----- void_ticket (org admin; poništenje evidencija) -------------------------
create or replace function ulaznice.void_ticket(p_ticket_id uuid)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_ticket ulaznice.tickets;
  v_event ulaznice.events;
begin
  if (select auth.uid()) is null then
    raise exception 'not_authenticated';
  end if;
  if p_ticket_id is null then
    raise exception 'ticket_id_required';
  end if;

  select * into v_ticket
    from ulaznice.tickets
   where id = p_ticket_id
     for update;
  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;

  select * into v_event
    from ulaznice.events
   where id = v_ticket.event_id and deleted_at is null;
  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;

  if not public.has_role_on_account(v_event.account_id, 'admin') then
    raise exception 'not_authorized';
  end if;

  if v_ticket.state = 'void' then
    return jsonb_build_object('status', 'already_void', 'serial', v_ticket.serial);
  end if;
  if v_ticket.state = 'checked_in' then
    return jsonb_build_object(
      'status', 'already_checked_in',
      'serial', v_ticket.serial,
      'checked_in_at', v_ticket.checked_in_at
    );
  end if;

  update ulaznice.tickets
     set state = 'void', updated_at = now()
   where id = v_ticket.id and state = 'issued';

  insert into ulaznice.order_events (order_id, event_id, event_type, payload)
  values (v_ticket.order_id, v_ticket.event_id, 'ticket.voided',
          jsonb_build_object('serial', v_ticket.serial, 'by', (select auth.uid())));

  return jsonb_build_object('status', 'voided', 'serial', v_ticket.serial);
end;
$$;

revoke execute on function ulaznice.void_ticket(uuid) from public, anon;
grant execute on function ulaznice.void_ticket(uuid) to authenticated, service_role;

-- ----- rotate_ticket_tokens (service_role; Worker, ponovna dostava QR-a) ------
-- Odluka 111: ugrađuje se ravno u ulaznice. Rotira cijelu narudžbu (samo
-- issued), tvrdi limit 5/24 h iz order_events (indeks ix_order_events_rotate u
-- 20261125150000). Poslovni ishodi su status jsonb.
create or replace function ulaznice.rotate_ticket_tokens(p_order_id uuid)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_order ulaznice.orders;
  v_recent integer;
  v_rotated integer := 0;
  v_ticket record;
  v_token text;
  v_result jsonb;
begin
  if p_order_id is null then
    return jsonb_build_object('status', 'order_not_found');
  end if;

  select * into v_order
    from ulaznice.orders
   where id = p_order_id
   for update;
  if not found then
    return jsonb_build_object('status', 'order_not_found');
  end if;

  if v_order.state <> 'paid' then
    return jsonb_build_object('status', 'order_not_paid', 'state', v_order.state);
  end if;

  select count(*)::integer into v_recent
    from ulaznice.order_events
   where order_id = p_order_id
     and event_type = 'ticket.token_rotated'
     and created_at > now() - interval '24 hours';
  if v_recent >= 5 then
    return jsonb_build_object('status', 'rate_limited', 'rotations_24h', v_recent);
  end if;

  for v_ticket in
    select id from ulaznice.tickets
     where order_id = p_order_id
       and state = 'issued'
     order by serial
  loop
    v_token := encode(extensions.gen_random_bytes(32), 'hex');
    update ulaznice.tickets
       set qr_token_hash = encode(extensions.digest(v_token, 'sha256'), 'hex'),
           qr_token_once = v_token,
           updated_at = now()
     where id = v_ticket.id;
    v_rotated := v_rotated + 1;
  end loop;

  if v_rotated = 0 then
    return jsonb_build_object('status', 'nothing_to_rotate');
  end if;

  insert into ulaznice.order_events (order_id, event_id, event_type, payload)
  values (p_order_id, v_order.event_id, 'ticket.token_rotated',
          jsonb_build_object('rotated', v_rotated, 'rotations_24h', v_recent + 1));

  select jsonb_build_object(
    'status', 'rotated',
    'order_id', p_order_id,
    'state', v_order.state,
    'rotated', v_rotated,
    'tickets', coalesce(jsonb_agg(jsonb_build_object(
      'serial', t.serial,
      'holder_name', t.holder_name,
      'holder_email', t.holder_email,
      'state', t.state::text,
      -- plaintext izlazi iz baze SAMO ovdje i samo u ovom odgovoru
      'qr_token', t.qr_token_once
    ) order by t.serial), '[]'::jsonb)
  ) into v_result
  from ulaznice.tickets t
  where t.order_id = p_order_id;

  update ulaznice.tickets
     set qr_token_once = null, updated_at = now()
   where order_id = p_order_id
     and qr_token_once is not null;

  return v_result;
end;
$$;

comment on function ulaznice.rotate_ticket_tokens(uuid) is
  'Izda NOVE QR tokene za neiskorištene ulaznice plaćene narudžbe i vrati ih '
  'jednokratno (stari QR prestaje vrijediti). service_role only — pozivatelj '
  'mora prije toga dokazati posjedovanje order_id. Tvrdi limit 5/24 h po '
  'narudžbi; poslovni ishodi su status jsonb.';

revoke execute on function ulaznice.rotate_ticket_tokens(uuid) from public, anon, authenticated;
grant execute on function ulaznice.rotate_ticket_tokens(uuid) to service_role;

notify pgrst, 'reload schema';

select 'OK ulaznice_rpc_narudzbe' as status;
