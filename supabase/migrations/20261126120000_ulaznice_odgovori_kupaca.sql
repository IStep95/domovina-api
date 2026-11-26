-- =============================================================================
-- Ulaznice: odgovori kupca na dodatna polja (2026-11-26)
--
-- Izvor: domovina-ulaznice, Ivanov zahtjev 2026-11-26. Organizator uz događaj
-- zalijepi link na javni Google obrazac (spol, godište…); kupnja prikaže
-- njegova pitanja kao „Dodatna polja”. Worker odgovore sprema OVDJE (izvor
-- istine, organizator ih dobiva u CSV-u sudionika) i prosljeđuje ih u Google
-- obrazac organizatora. Link obrasca je u D1 Workera (prezentacija), ne ovdje.
--
-- 1. `order_answers` — jedan redak po narudžbi, zasebna tablica (ne stupac u
--    `orders`): strože čitanje, brisanje po roku ne dira narudžbu ni ulaznice.
--    `answers` = [{id, pitanje, odgovor}] — tekst pitanja se sprema uz odgovor,
--    pa odgovori ostaju čitljivi i kad organizator promijeni obrazac.
--    Pitanja su slobodna, pa odgovori mogu biti i posebne kategorije podataka
--    (čl. 9 GDPR-a: vjera, zdravlje). Zato: čita samo admin računa događaja,
--    piše samo service_role, rok čuvanja je ograničen (3).
--
-- 2. RPC-ovi samo za service_role (Worker):
--    save_order_answers              — upis uz narudžbu (idempotentno)
--    order_answers_to_forward        — plaćene narudžbe kojima odgovori još
--                                      nisu stigli u Google obrazac (cron)
--    mark_order_answers_forwarded    — ishod prosljeđivanja
--    purge_order_answers             — rok čuvanja (3), zove ga cron Workera
--
-- 3. Rok čuvanja: neplaćena narudžba (pending/expired) 24 h nakon upisa;
--    inače 90 dana nakon kraja događaja (ends_at, bez njega starts_at).
--
-- Idempotentno: `if not exists`, `create or replace`, drop/create policyja.
-- Drugi run = no-op.
-- =============================================================================

-- ----- 1. order_answers ----------------------------------------------------------
create table if not exists ulaznice.order_answers (
  order_id uuid primary key references ulaznice.orders(id) on delete cascade,
  event_id uuid not null references ulaznice.events(id) on delete cascade,
  answers jsonb not null,
  -- Google obrazac u koji se odgovori prosljeđuju (null = samo kod nas)
  form_url text,
  forwarded_at timestamptz,
  forward_attempts integer not null default 0,
  forward_error text,
  created_at timestamptz not null default now(),
  constraint order_answers_array check (jsonb_typeof(answers) = 'array' and jsonb_array_length(answers) <= 100),
  constraint order_answers_size check (pg_column_size(answers) <= 65536),
  constraint order_answers_form_url check (
    form_url is null or (form_url ~ '^https://docs\.google\.com/forms/d/e/[A-Za-z0-9_-]+/viewform$'
                         and char_length(form_url) <= 500)
  ),
  constraint order_answers_forward_error_len check (forward_error is null or char_length(forward_error) <= 200)
);
create index if not exists ix_order_answers_event on ulaznice.order_answers (event_id);
create index if not exists ix_order_answers_to_forward on ulaznice.order_answers (created_at)
  where forwarded_at is null and form_url is not null;

comment on table ulaznice.order_answers is
  'Odgovori kupca na dodatna polja (Google obrazac organizatora). Moguće posebne kategorije '
  'podataka (čl. 9 GDPR-a): čita samo admin računa, rok čuvanja purge_order_answers().';

alter table ulaznice.order_answers enable row level security;
revoke all on ulaznice.order_answers from public, anon, authenticated;
grant select on ulaznice.order_answers to authenticated;
grant select, insert, update, delete on ulaznice.order_answers to service_role;

-- Samo admin računa događaja (kao event_access), ne i kupac ni običan član.
drop policy if exists order_answers_select on ulaznice.order_answers;
create policy order_answers_select on ulaznice.order_answers
  for select to authenticated
  using (
    exists (
      select 1 from ulaznice.events e
      where e.id = event_id and public.has_role_on_account(e.account_id, 'admin')
    )
  );

-- ----- 2. RPC-ovi (service_role) -------------------------------------------------

-- Upis odgovora uz narudžbu. Drugi upis za istu narudžbu je no-op (retry Workera).
create or replace function ulaznice.save_order_answers(
  p_order_id uuid,
  p_answers jsonb,
  p_form_url text default null
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_event uuid;
  v_el jsonb;
begin
  select event_id into v_event from ulaznice.orders where id = p_order_id;
  if not found then raise exception 'order_not_found'; end if;
  if p_answers is null or jsonb_typeof(p_answers) <> 'array' then raise exception 'invalid_answers'; end if;
  for v_el in select * from jsonb_array_elements(p_answers) loop
    if jsonb_typeof(v_el) <> 'object'
       or jsonb_typeof(v_el->'pitanje') <> 'string'
       or jsonb_typeof(v_el->'odgovor') not in ('string', 'array') then
      raise exception 'invalid_answers';
    end if;
  end loop;

  insert into ulaznice.order_answers (order_id, event_id, answers, form_url)
  values (p_order_id, v_event, p_answers, nullif(btrim(p_form_url), ''))
  on conflict (order_id) do nothing;
  return jsonb_build_object('order_id', p_order_id, 'saved', found);
exception
  when check_violation then raise exception 'invalid_answers';
end $$;

-- Plaćene narudžbe čiji odgovori još nisu u Google obrascu (najstarije prve).
create or replace function ulaznice.order_answers_to_forward(p_limit integer default 50)
returns table (order_id uuid, form_url text, answers jsonb, forward_attempts integer, buyer_email text)
language sql security definer set search_path = '' stable
as $$
  select a.order_id, a.form_url, a.answers, a.forward_attempts, o.buyer_email
    from ulaznice.order_answers a
    join ulaznice.orders o on o.id = a.order_id
   where a.forwarded_at is null
     and a.form_url is not null
     and a.forward_attempts < 20
     and o.state = 'paid'
   order by a.created_at
   limit least(greatest(coalesce(p_limit, 50), 1), 200)
$$;

-- Ishod prosljeđivanja: p_error null = stiglo u obrazac.
create or replace function ulaznice.mark_order_answers_forwarded(p_order_id uuid, p_error text default null)
returns void
language sql security definer set search_path = ''
as $$
  update ulaznice.order_answers
     set forward_attempts = forward_attempts + 1,
         forwarded_at = case when p_error is null then now() else forwarded_at end,
         forward_error = left(p_error, 200)
   where order_id = p_order_id and forwarded_at is null
$$;

-- Rok čuvanja (3). Vraća broj obrisanih redaka.
create or replace function ulaznice.purge_order_answers()
returns integer
language plpgsql security definer set search_path = ''
as $$
declare v_n integer;
begin
  delete from ulaznice.order_answers a
   using ulaznice.orders o, ulaznice.events e
   where o.id = a.order_id
     and e.id = a.event_id
     and (
       (o.state in ('pending', 'expired') and a.created_at < now() - interval '24 hours')
       or coalesce(e.ends_at, e.starts_at) < now() - interval '90 days'
     );
  get diagnostics v_n = row_count;
  return v_n;
end $$;

revoke execute on function ulaznice.save_order_answers(uuid, jsonb, text) from public, anon, authenticated;
revoke execute on function ulaznice.order_answers_to_forward(integer) from public, anon, authenticated;
revoke execute on function ulaznice.mark_order_answers_forwarded(uuid, text) from public, anon, authenticated;
revoke execute on function ulaznice.purge_order_answers() from public, anon, authenticated;
grant execute on function ulaznice.save_order_answers(uuid, jsonb, text) to service_role;
grant execute on function ulaznice.order_answers_to_forward(integer) to service_role;
grant execute on function ulaznice.mark_order_answers_forwarded(uuid, text) to service_role;
grant execute on function ulaznice.purge_order_answers() to service_role;
