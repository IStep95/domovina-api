begin;
create or replace function pinka_finance.ulaznice_zamrznuto() returns trigger
language plpgsql security definer set search_path = '' as $$
declare j_old jsonb; j_new jsonb; v_hit boolean;
begin
  if tg_op <> 'INSERT' then j_old := to_jsonb(old); end if;
  if tg_op <> 'DELETE' then j_new := to_jsonb(new); end if;
  if tg_argv[0] = 'sve' then
    v_hit := true;
  elsif tg_table_name = 'campaigns' then
    v_hit := coalesce(j_old->>'type', '') = 'tickets' or coalesce(j_new->>'type', '') = 'tickets';
  else  -- dijeljena tablica s campaign_id; definer jer RLS pozivatelja može sakriti skicu
    v_hit := exists (select 1 from pinka_finance.campaigns c
                     where c.type = 'tickets'
                       and c.id in ((j_old->>'campaign_id')::uuid, (j_new->>'campaign_id')::uuid));
  end if;
  if v_hit then
    raise exception using errcode = 'P0001',
      message = format('ulaznice_zamrznuto: %s.%s %s', tg_table_schema, tg_table_name, tg_op),
      hint = 'Ticketing seli u shemu ulaznice (docs/ulaznice-shema, S6).';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;
revoke execute on function pinka_finance.ulaznice_zamrznuto() from public, anon, authenticated;

do $$ declare t text; begin
  foreach t in array array['events','tickets','event_access','organizer_allowlist','organizer_records','organizer_payment_rails'] loop
    execute format('create trigger ulaznice_zamrznuto before insert or update or delete on pinka_finance.%I
                    for each row execute function pinka_finance.ulaznice_zamrznuto(%L)', t, 'sve');
  end loop;
  foreach t in array array['campaigns','campaign_tiers','contributions','contribution_events','campaign_stats'] loop
    execute format('create trigger ulaznice_zamrznuto before insert or update or delete on pinka_finance.%I
                    for each row execute function pinka_finance.ulaznice_zamrznuto(%L)', t, 'kampanja');
  end loop;
end $$;
select 'OK zamrzavanje, triggera: ' || count(*) from pg_trigger where tgname = 'ulaznice_zamrznuto';
commit;
