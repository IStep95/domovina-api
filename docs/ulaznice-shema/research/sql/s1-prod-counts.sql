begin read only;
\echo '== narudzbe po stanju i railu (tickets)'
select co.state, co.payment_rail, co.reserved, count(*), sum(co.amount_cents) from pinka_finance.contributions co join pinka_finance.campaigns c on c.id=co.campaign_id where c.type='tickets' group by 1,2,3 order by 1,2,3;
\echo '== narudzbe ukupno po tipu kampanje'
select c.type, count(*) from pinka_finance.contributions co join pinka_finance.campaigns c on c.id=co.campaign_id group by 1;
\echo '== tickets po stanju'
select state, count(*) from pinka_finance.tickets group by 1;
\echo '== event_access, organizer_*'
select (select count(*) from pinka_finance.event_access) ea, (select count(*) from pinka_finance.organizer_allowlist) oal, (select count(*) from pinka_finance.organizer_payment_rails) opr, (select count(*) from pinka_finance.organizer_records) orc;
\echo '== eventi detalj'
select c.id, c.slug, c.state, c.visibility, c.deleted_at is not null del, c.safe_address is not null has_safe, c.account_id, e.event_type, e.attendance_mode, e.starts_at::date, (e.cover_image_url is not null) cover, jsonb_array_length(coalesce(e.gallery,'[]')) gal from pinka_finance.campaigns c left join pinka_finance.events e on e.campaign_id=c.id where c.type='tickets' order by c.created_at;
\echo '== tier/ticket/contribution veze na ne-ticket kampanje (ocekivano 0)'
select (select count(*) from pinka_finance.tickets t join pinka_finance.campaigns c on c.id=t.campaign_id where c.type<>'tickets') t_x, (select count(*) from pinka_finance.events e join pinka_finance.campaigns c on c.id=e.campaign_id where c.type<>'tickets') e_x;
\echo '== pinka-covers objekti'
select count(*) total, count(*) filter (where name in (
  select regexp_replace(u,'^.*/pinka-covers/','') from (
    select cover_image_url u from pinka_finance.events where cover_image_url like '%pinka-covers%'
    union all select g->>'url' from pinka_finance.events, jsonb_array_elements(coalesce(gallery,'[]')) g where g->>'url' like '%pinka-covers%'
  ) x)) event_obj from storage.objects where bucket_id='pinka-covers';
\echo '== event URL-ovi u pinka-covers'
select count(*) from (select cover_image_url u from pinka_finance.events where cover_image_url like '%pinka-covers%' union all select g->>'url' from pinka_finance.events, jsonb_array_elements(coalesce(gallery,'[]')) g) x;
\echo '== kampanje cover url pinka-covers (ne-ticket)'
select c.type, count(*) from pinka_finance.campaigns c where c.cover_image_url like '%pinka-covers%' group by 1;
\echo '== og cache'
select count(*) from storage.objects where bucket_id='pinka-og-cache';
rollback;
