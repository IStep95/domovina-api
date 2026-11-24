-- =============================================================================
-- Događaji: brisanje skice
--
-- Izvor: domovina-ulaznice, Ivanov zahtjev 2026-11-24 („obriši skicu” u
-- pregledu prodaje i editoru, /organizator).
--
-- Organizator (admin računa) briše SVOJU SKICU događaja. Brisanje je meko
-- (`campaigns.deleted_at`), kao za ostale kampanje; organizer_overview,
-- events-feed i RLS select je ionako preskaču.
--
-- Zašto RPC, a ne PATCH kroz PostgREST: RLS `campaigns_update` provjerava
-- novi red i protiv `campaigns_select` (`deleted_at is null`), pa korisnikov
-- soft-delete pada na „new row violates row-level security policy”.
-- DEFINER s istim provjerama kao `publish_event` (admin računa), uz uvjet da
-- je kampanja skica (`draft`) bez ijedne narudžbe. Objavljen ili zatvoren
-- događaj se ovdje ne briše (kupci, ulaznice, računi).
--
-- Idempotentno: `create or replace`, revoke/grant. Drugi run = no-op.
-- =============================================================================

create or replace function pinka_finance.delete_event_draft(p_campaign_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_campaign pinka_finance.campaigns;
begin
  if (select auth.uid()) is null then raise exception 'not_authenticated'; end if;

  select * into v_campaign from pinka_finance.campaigns
    where id = p_campaign_id and deleted_at is null
    for update;
  if not found then raise exception 'campaign_not_found'; end if;
  if v_campaign.type <> 'tickets' then raise exception 'campaign_not_tickets'; end if;
  if not public.has_role_on_account(v_campaign.account_id, 'admin') then
    raise exception 'not_authorized';
  end if;
  if v_campaign.state <> 'draft' then raise exception 'event_not_draft'; end if;
  if exists (select 1 from pinka_finance.contributions c where c.campaign_id = p_campaign_id) then
    raise exception 'event_has_orders';
  end if;

  update pinka_finance.campaigns
    set deleted_at = now(), updated_at = now()
    where id = p_campaign_id;

  return jsonb_build_object('campaign_id', p_campaign_id, 'deleted', true);
end;
$$;

revoke execute on function pinka_finance.delete_event_draft(uuid) from public, anon;
grant execute on function pinka_finance.delete_event_draft(uuid) to authenticated, service_role;

notify pgrst, 'reload schema';

select 'OK events_delete_draft' as status;
