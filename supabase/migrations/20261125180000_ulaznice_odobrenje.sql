-- =============================================================================
-- Ulaznice: odobravanje događaja (organizator šalje skicu, admin platforme odobrava)
--
-- Izvor: domovina-ulaznice, Ivanov zahtjev 2026-11-25. Do sada je objava išla
-- kroz publish_event, a smio ju je samo organizator s računa na
-- organizer_allowlist (upisuje operater ručno). Sada:
--
--   skica ──submit_event_for_review──▶ skica + submitted_at (čeka odobrenje)
--         ◀──────reject_event───────── (submitted_at = null, review_note)
--   čeka odobrenje ──approve_event──▶ active + public (vidljiv u feedu)
--
-- Admin platforme je novi pojam: ulaznice.platform_admins (user_id). Upis samo
-- operater (service_role/psql), kao allowlist. Odobrenje admina zamjenjuje
-- allowlist za taj događaj: events_write_guard ne traži allowlist kad stanje
-- mijenja admin platforme. Rail gate (Stripe ili samo besplatne ulaznice)
-- vrijedi i za admina: događaj koji nitko ne može platiti se ne objavljuje.
--
-- publish_event ostaje netaknut (allowlistani organizatori i dalje mogu sami).
--
-- Organizator i dalje smije uređivati skicu dok čeka odobrenje (update_event
-- traži samo state='draft'); admin odobrava ono što je u bazi u trenutku klika.
--
-- Idempotentno: if not exists, create or replace, drop policy if exists.
-- =============================================================================

-- ----- admini platforme -------------------------------------------------------
create table if not exists ulaznice.platform_admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  note text,
  created_at timestamptz not null default now(),
  constraint platform_admins_note_len check (note is null or char_length(note) <= 500)
);
comment on table ulaznice.platform_admins is
  'Admini platforme ulaznica: odobravaju događaje (approve_event / reject_event). '
  'Upis isključivo operater (service_role/psql).';

alter table ulaznice.platform_admins enable row level security;
revoke all on ulaznice.platform_admins from public, anon, authenticated;
grant all on ulaznice.platform_admins to service_role;

create or replace function ulaznice.is_platform_admin()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from ulaznice.platform_admins pa where pa.user_id = (select auth.uid())
  );
$$;

revoke execute on function ulaznice.is_platform_admin() from public, anon;
grant execute on function ulaznice.is_platform_admin() to authenticated, service_role;

-- ----- stupci na događaju -----------------------------------------------------
alter table ulaznice.events add column if not exists submitted_at timestamptz;
alter table ulaznice.events add column if not exists reviewed_at timestamptz;
alter table ulaznice.events add column if not exists review_note text;

do $$ begin
  alter table ulaznice.events add constraint events_review_note_len
    check (review_note is null or char_length(review_note) <= 1000);
exception when duplicate_object then null;
end $$;

comment on column ulaznice.events.submitted_at is
  'Skica poslana na odobrenje (submit_event_for_review); null = nije poslana ili vraćena.';
comment on column ulaznice.events.review_note is
  'Napomena admina pri vraćanju na doradu (reject_event).';

create index if not exists ix_events_review_queue
  on ulaznice.events (submitted_at)
  where state = 'draft' and submitted_at is not null and deleted_at is null;

-- ----- events_write_guard — admin platforme ne treba allowlist ----------------
-- Puno tijelo iz 20261125170000; nova je samo iznimka za admina platforme u
-- grani aktivacije. approve_event je DEFINER, ali auth.role() ostaje
-- 'authenticated', pa ovaj trigger vidi admina koji je kliknuo „Odobri”.
-- Uz to: review_note i reviewed_at smije mijenjati samo admin platforme (RLS
-- events_update inače pušta admina računa da ih izravnim PATCH-om lažira).
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
    new.submitted_at := null;
    new.reviewed_at := null;
    new.review_note := null;

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

    if not ulaznice.is_platform_admin() then
      new.reviewed_at := old.reviewed_at;
      new.review_note := old.review_note;
    end if;

    -- aktivacija (S3b, odluka 111): isti uvjeti kao publish_event; admin
    -- platforme (approve_event) umjesto allowliste
    if new.state = 'active' and old.state is distinct from 'active' then
      if not ulaznice.is_platform_admin() and not exists (
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

-- ----- submit_event_for_review (organizator; DEFINER) --------------------------
create or replace function ulaznice.submit_event_for_review(p_campaign_id uuid)
returns jsonb
language plpgsql security definer set search_path = ''
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
  if not exists (select 1 from ulaznice.ticket_tiers t where t.event_id = v_event.id) then
    raise exception 'event_no_tiers';
  end if;

  -- ponovno slanje je no-op (zadržava prvo vrijeme u redu čekanja)
  if v_event.submitted_at is null then
    update ulaznice.events
       set submitted_at = now(), updated_at = now()
     where id = p_campaign_id;
    perform public.log_event('event.submitted', v_event.account_id,
      jsonb_build_object('campaign_id', p_campaign_id));
  end if;

  return jsonb_build_object(
    'campaign_id', p_campaign_id,
    'state', 'draft',
    'submitted_at', coalesce(v_event.submitted_at, now())
  );
end;
$$;

revoke execute on function ulaznice.submit_event_for_review(uuid) from public, anon;
grant execute on function ulaznice.submit_event_for_review(uuid) to authenticated, service_role;

-- ----- review_queue (admin platforme; DEFINER) --------------------------------
-- Skice poslane na odobrenje, najstarije prve, s računom organizatora,
-- podacima događaja i tierovima; rail_ready kaže hoće li odobrenje proći.
create or replace function ulaznice.review_queue()
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_events jsonb;
begin
  if (select auth.uid()) is null then raise exception 'not_authenticated'; end if;
  if not ulaznice.is_platform_admin() then raise exception 'not_authorized'; end if;

  select coalesce(jsonb_agg(e.event_json order by e.submitted_at), '[]'::jsonb) into v_events
  from (
    select ev.submitted_at, jsonb_build_object(
      'campaign_id', ev.id,
      'account_id', ev.account_id,
      'account_name', acc.name,
      'slug', ev.slug,
      'title', ev.title,
      'state', ev.state,
      'submitted_at', ev.submitted_at,
      'rail_ready', ulaznice.event_rail_ready(ev.account_id, ev.id),
      'event', jsonb_build_object(
        'event_type', ev.event_type,
        'attendance_mode', ev.attendance_mode,
        'venue_name', ev.venue_name,
        'venue_address', ev.venue_address,
        'venue_city', ev.venue_city,
        'starts_at', ev.starts_at,
        'ends_at', ev.ends_at,
        'timezone', ev.timezone,
        'description_hr', ev.description_hr,
        'cover_image_url', ev.cover_image_url,
        'organizer_name', ev.organizer_name,
        'organizer_email', ev.organizer_email,
        'organizer_web', ev.organizer_web
      ),
      'tiers', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', t.id,
          'title', t.title,
          'price_cents', t.price_cents,
          'inventory_total', t.inventory_total,
          'imenska', t.imenska,
          'sort', t.sort
        ) order by t.sort)
        from ulaznice.ticket_tiers t
        where t.event_id = ev.id
      ), '[]'::jsonb)
    ) as event_json
    from ulaznice.events ev
    join public.accounts acc on acc.id = ev.account_id
    where ev.deleted_at is null
      and ev.state = 'draft'
      and ev.submitted_at is not null
  ) e;

  return jsonb_build_object('events', v_events);
end;
$$;

revoke execute on function ulaznice.review_queue() from public, anon;
grant execute on function ulaznice.review_queue() to authenticated, service_role;

-- ----- approve_event (admin platforme; DEFINER) --------------------------------
-- čeka odobrenje → active + public. Rail gate provjerava i trigger
-- (events_write_guard); ovdje je eksplicitno da greška bude ista bez obzira
-- na redoslijed.
create or replace function ulaznice.approve_event(p_campaign_id uuid)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_event ulaznice.events;
begin
  if (select auth.uid()) is null then raise exception 'not_authenticated'; end if;
  if not ulaznice.is_platform_admin() then raise exception 'not_authorized'; end if;

  select * into v_event from ulaznice.events
    where id = p_campaign_id and deleted_at is null
    for update;
  if not found then raise exception 'campaign_not_found'; end if;
  if v_event.state <> 'draft' then raise exception 'event_not_draft'; end if;
  if v_event.submitted_at is null then raise exception 'event_not_submitted'; end if;
  if not ulaznice.event_rail_ready(v_event.account_id, v_event.id) then
    raise exception 'event_no_working_rail';
  end if;

  update ulaznice.events
     set state = 'active', visibility = 'public',
         reviewed_at = now(), review_note = null, updated_at = now()
   where id = p_campaign_id;

  perform public.log_event('event.approved', v_event.account_id,
    jsonb_build_object('campaign_id', p_campaign_id, 'by', (select auth.uid())));

  return jsonb_build_object('campaign_id', p_campaign_id, 'state', 'active', 'visibility', 'public');
end;
$$;

revoke execute on function ulaznice.approve_event(uuid) from public, anon;
grant execute on function ulaznice.approve_event(uuid) to authenticated, service_role;

-- ----- reject_event (admin platforme; DEFINER) ---------------------------------
-- čeka odobrenje → skica (submitted_at = null) s napomenom za organizatora.
create or replace function ulaznice.reject_event(p_campaign_id uuid, p_note text default null)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_event ulaznice.events;
  v_note text := ulaznice.sanitize_ugc(p_note);
begin
  if (select auth.uid()) is null then raise exception 'not_authenticated'; end if;
  if not ulaznice.is_platform_admin() then raise exception 'not_authorized'; end if;
  if v_note is not null and char_length(v_note) > 1000 then raise exception 'invalid_review_note'; end if;

  select * into v_event from ulaznice.events
    where id = p_campaign_id and deleted_at is null
    for update;
  if not found then raise exception 'campaign_not_found'; end if;
  if v_event.state <> 'draft' then raise exception 'event_not_draft'; end if;
  if v_event.submitted_at is null then raise exception 'event_not_submitted'; end if;

  update ulaznice.events
     set submitted_at = null, reviewed_at = now(), review_note = v_note, updated_at = now()
   where id = p_campaign_id;

  perform public.log_event('event.rejected', v_event.account_id,
    jsonb_build_object('campaign_id', p_campaign_id, 'by', (select auth.uid())));

  return jsonb_build_object('campaign_id', p_campaign_id, 'state', 'draft', 'review_note', v_note);
end;
$$;

revoke execute on function ulaznice.reject_event(uuid, text) from public, anon;
grant execute on function ulaznice.reject_event(uuid, text) to authenticated, service_role;

-- ----- organizer_overview — + submitted_at, review_note, platform_admin --------
-- Puno tijelo iz 20261125170000; dodana su tri polja događaja i
-- `platform_admin` na vrhu (UI po njemu prikazuje red čekanja).
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
      'submitted_at', ev.submitted_at,
      'reviewed_at', ev.reviewed_at,
      'review_note', ev.review_note,
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

  return jsonb_build_object(
    'accounts', v_accounts,
    'events', v_events,
    'platform_admin', ulaznice.is_platform_admin()
  );
end;
$$;

revoke execute on function ulaznice.organizer_overview() from public, anon;
grant execute on function ulaznice.organizer_overview() to authenticated, service_role;

notify pgrst, 'reload schema';

select 'OK ulaznice_odobrenje' as status;
