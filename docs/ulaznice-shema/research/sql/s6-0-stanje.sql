begin read only;
-- narudžbe ulaznica po stanju; vrata: 0 redaka pending + reserved + nije isteklo
select c.state, c.payment_rail, c.reserved, count(*), sum(c.amount_cents),
       min(c.reserve_expires_at), max(c.reserve_expires_at)
from pinka_finance.contributions c
join pinka_finance.campaigns ca on ca.id = c.campaign_id and ca.type = 'tickets'
group by 1,2,3 order by 1,2,3;

select count(*) as zive_rezervacije
from pinka_finance.contributions c
join pinka_finance.campaigns ca on ca.id = c.campaign_id and ca.type = 'tickets'
where c.state = 'pending' and c.reserved and c.reserve_expires_at > now();

-- odluka 309: claimed vs zbroj rezerviranih po tieru (prikazuje samo razlike)
select t.id, t.inventory_total, t.inventory_claimed,
       coalesce(sum(c.quantity) filter (where c.reserved), 0) as rezervirano
from pinka_finance.campaign_tiers t
join pinka_finance.campaigns ca on ca.id = t.campaign_id and ca.type = 'tickets'
left join pinka_finance.contributions c on c.tier_id = t.id
group by 1,2,3
having t.inventory_claimed <> coalesce(sum(c.quantity) filter (where c.reserved), 0);
rollback;
