begin read only;
-- otisak izvora (SRC_Q iz scripts/ulaznice-prod-dump-test.sh): mora biti isti od T2 nadalje
select (select count(*) from pinka_finance.campaigns) || '/' ||
       (select count(*) from pinka_finance.contributions) || '/' ||
       (select count(*) from pinka_finance.contribution_events) || '/' ||
       (select count(*) from pinka_finance.events) || '/' ||
       (select md5(string_agg(coalesce(cover_image_url, '-') || gallery::text, ',' order by campaign_id)) from pinka_finance.events) as otisak;
rollback;
