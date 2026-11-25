begin;
do $$ declare t text; begin
  foreach t in array array['events','tickets','event_access','organizer_allowlist','organizer_records','organizer_payment_rails','campaigns','campaign_tiers','contributions','contribution_events','campaign_stats'] loop
    execute format('drop trigger if exists ulaznice_zamrznuto on pinka_finance.%I', t);
  end loop;
end $$;
drop function if exists pinka_finance.ulaznice_zamrznuto();
commit;
