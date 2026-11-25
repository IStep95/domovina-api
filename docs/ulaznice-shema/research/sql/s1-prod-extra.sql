begin read only;
\echo '== ticket kampanje: doprinosi bez tiera (siročad onchain-ingest) i bez ulaznica'
select count(*) filter (where co.tier_id is null) no_tier, count(*) filter (where co.reserved is not true) not_reserved, count(*) from pinka_finance.contributions co join pinka_finance.campaigns c on c.id=co.campaign_id where c.type='tickets';
\echo '== ne-ticket doprinosi s tierom i iznosom 0'
select c.type, count(*) from pinka_finance.contributions co join pinka_finance.campaigns c on c.id=co.campaign_id where c.type<>'tickets' and co.tier_id is not null and co.amount_cents=0 group by 1;
\echo '== contribution_events i campaign_stats za tickets'
select (select count(*) from pinka_finance.contribution_events ce join pinka_finance.contributions co on co.id=ce.contribution_id join pinka_finance.campaigns c on c.id=co.campaign_id where c.type='tickets') ce, (select count(*) from pinka_finance.campaign_stats s join pinka_finance.campaigns c on c.id=s.campaign_id where c.type='tickets') stats;
\echo '== campaign_subjects/payouts/subscriptions/slots/slot_maps za tickets'
select (select count(*) from pinka_finance.campaign_subjects x join pinka_finance.campaigns c on c.id=x.campaign_id where c.type='tickets') subj, (select count(*) from pinka_finance.payouts x join pinka_finance.campaigns c on c.id=x.campaign_id where c.type='tickets') payouts, (select count(*) from pinka_finance.slot_maps x join pinka_finance.campaigns c on c.id=x.campaign_id where c.type='tickets') slotmaps;
rollback;
