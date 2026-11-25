begin read only;
select count(*) as donacije_nakon_t2 from pinka_finance.contributions c join pinka_finance.campaigns ca on ca.id=c.campaign_id where ca.type <> 'tickets' and c.created_at > '2026-11-25T16:34:38Z';
select j.jobname, d.status, count(*) from cron.job_run_details d join cron.job j using (jobid) where d.start_time > '2026-11-25T16:34:38Z' group by 1,2 order by 1,2;
select count(*) as nove_narudzbe_ulaznice from ulaznice.orders where created_at > '2026-11-25T16:34:38Z';
rollback;
