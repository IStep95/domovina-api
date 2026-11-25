begin read only;
with refs as (
  select 'events.cover' src, cover_image_url u from pinka_finance.events
  union all select 'events.gallery', g->>'url' from pinka_finance.events, jsonb_array_elements(coalesce(gallery,'[]')) g
  union all select 'campaigns.cover:'||type, cover_image_url from pinka_finance.campaigns
)
select o.created_at::date, split_part(o.name,'/',1)=any(select user_id::text from public.accounts_memberships m join pinka_finance.campaigns c on c.account_id=m.account_id where c.type='tickets') as owner_is_event_member,
  coalesce(string_agg(distinct r.src, ','),'NEREFERENCIRAN') refs
from storage.objects o left join refs r on r.u like '%/pinka-covers/'||o.name
where o.bucket_id='pinka-covers' group by o.id, o.created_at, o.name order by 1;
rollback;
