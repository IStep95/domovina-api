begin read only;
with t as (select c.id from pinka_finance.campaigns c where c.type = 'tickets')
select 'events' tablica, (select count(*) from ulaznice.events) ulaznice,
       (select count(*) from t) izvor
union all select 'ticket_tiers', (select count(*) from ulaznice.ticket_tiers),
       (select count(*) from pinka_finance.campaign_tiers where campaign_id in (select id from t))
union all select 'orders', (select count(*) from ulaznice.orders),
       (select count(*) from pinka_finance.contributions where campaign_id in (select id from t))
union all select 'tickets', (select count(*) from ulaznice.tickets),
       (select count(*) from pinka_finance.tickets where campaign_id in (select id from t))
union all select 'event_access', (select count(*) from ulaznice.event_access),
       (select count(*) from pinka_finance.event_access where campaign_id in (select id from t))
union all select 'organizer_payment_rails', (select count(*) from ulaznice.organizer_payment_rails),
       (select count(*) from pinka_finance.organizer_payment_rails)
union all select 'organizer_records', (select count(*) from ulaznice.organizer_records),
       (select count(*) from pinka_finance.organizer_records)
union all select 'organizer_allowlist', (select count(*) from ulaznice.organizer_allowlist),
       (select count(*) from pinka_finance.organizer_allowlist)
union all select 'order_events', (select count(*) from ulaznice.order_events),
       (select count(*) from pinka_finance.contribution_events where campaign_id in (select id from t));

select state || '/' || payment_rail as narudzbe, count(*), sum(amount_cents) from ulaznice.orders group by 1 order by 1;
select state || '/' || visibility || case when deleted_at is not null then '/obrisan' else '' end as eventi, count(*)
  from ulaznice.events group by 1 order by 1;
-- §5 provjere: svaka mora biti 0
select 'isti ID-jevi: eventi' as provjera, (select count(*) from pinka_finance.campaigns c where c.type='tickets' and not exists (select 1 from ulaznice.events e where e.id=c.id and e.slug=c.slug and e.account_id=c.account_id)) as mora_biti_0;
select 'isti ID-jevi: tierovi' as provjera, (select count(*) from pinka_finance.campaign_tiers t join pinka_finance.campaigns c on c.id=t.campaign_id and c.type='tickets' where not exists (select 1 from ulaznice.ticket_tiers u where u.id=t.id and u.event_id=t.campaign_id and u.price_cents=t.price_cents and u.inventory_claimed=t.inventory_claimed)) as mora_biti_0;
select 'isti ID-jevi: narudžbe' as provjera, (select count(*) from pinka_finance.contributions t join pinka_finance.campaigns c on c.id=t.campaign_id and c.type='tickets' where not exists (select 1 from ulaznice.orders u where u.id=t.id and u.event_id=t.campaign_id and u.tier_id=t.tier_id and u.amount_cents=t.amount_cents and u.state=t.state::text and u.external_payment_ref is not distinct from t.external_payment_ref)) as mora_biti_0;
select 'isti ID-jevi: ulaznice' as provjera, (select count(*) from pinka_finance.tickets t join pinka_finance.campaigns c on c.id=t.campaign_id and c.type='tickets' where not exists (select 1 from ulaznice.tickets u where u.id=t.id and u.order_id=t.contribution_id and u.qr_token_hash=t.qr_token_hash and u.serial=t.serial)) as mora_biti_0;
select 'isti ID-jevi: audit' as provjera, (select count(*) from pinka_finance.contribution_events t join pinka_finance.campaigns c on c.id=t.campaign_id and c.type='tickets' where not exists (select 1 from ulaznice.order_events u where u.id=t.id and u.order_id=t.contribution_id and u.event_type=t.event_type and u.created_at=t.created_at)) as mora_biti_0;
select 'bez ostataka pinka-covers u ulaznice.events' as provjera, (select count(*) from ulaznice.events where cover_image_url like '%/pinka-covers/%' or gallery::text like '%/pinka-covers/%') as mora_biti_0;
select 'donacije/crowdfund nisu u ulaznice' as provjera, (select count(*) from ulaznice.events e join pinka_finance.campaigns c on c.id=e.id where c.type<>'tickets') as mora_biti_0;
select (select count(*) from ulaznice.events where cover_image_url like '%/public/ulaznice-media/%') as cover_ulaznice_media,
       (select count(*) from ulaznice.events e, jsonb_array_elements(e.gallery) g where g->>'url' like '%/public/ulaznice-media/%') as galerija_ulaznice_media;
rollback;
