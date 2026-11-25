begin read only;
with u as (
  select cover_image_url as url from ulaznice.events where cover_image_url is not null
  union all
  select g->>'url' from ulaznice.events, jsonb_array_elements(coalesce(gallery, '[]'::jsonb)) g
)
select distinct (regexp_match(url, '/public/ulaznice-media/([^?#]+)'))[1] as kljuc
from u where url like '%/public/ulaznice-media/%' order by 1;
rollback;
