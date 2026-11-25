begin;
do $$ begin
  begin
    update pinka_finance.campaign_tiers set sort = sort
     where campaign_id in (select id from pinka_finance.campaigns where type = 'tickets');
    raise exception 'ZAMRZAVANJE NE RADI: tier ulaznice promijenjen';
  exception when others then
    if sqlerrm not like 'ulaznice_zamrznuto%' then raise; end if;
    raise notice 'OK — tierovi ulaznica zamrznuti';
  end;
  begin
    perform pinka_finance.expire_stale_ticket_orders();   -- definer put; 0 redaka ako nema isteklih
    raise notice 'OK — expire_stale_ticket_orders bez pisanja (nema što isteći)';
  exception when others then
    if sqlerrm not like 'ulaznice_zamrznuto%' then raise; end if;
    raise notice 'OK — definer RPC odbijen triggerom';
  end;
  update pinka_finance.contributions set updated_at = updated_at
   where id = (select c.id from pinka_finance.contributions c
               join pinka_finance.campaigns ca on ca.id = c.campaign_id and ca.type <> 'tickets' limit 1);
  raise notice 'OK — donacijska narudžba i dalje pisiva';
end $$;
rollback;
