-- =============================================================================
-- Događaji: galerija slika
--
-- Izvor: domovina-ulaznice, Ivanov zahtjev 2026-11-20 (stranica događaja dobiva
-- malu galeriju ispod „Dodaj u kalendar”).
--
--   gallery  jsonb — lista `{"url": "https://…", "alt": "…"}` redom prikaza,
--            najviše 20 stavki. Naslovna slika ostaje u `cover_image_url`;
--            galerija je dodatak, ne zamjena.
--
-- Not null s defaultom `[]`, pa postojeći događaji i klijenti (mobilne
-- aplikacije, React SPA) rade nepromijenjeno; `events-feed` ga vraća aditivno.
-- Kao i kod S2b (odluka 250 u domovina-ulaznice) RPC-ovi `create_event` /
-- `update_event` se ne mijenjaju: galeriju postavlja seed izravnim `update`.
--
-- Provjera oblika je namjerno plitka (lista objekata s tekstualnim `url`);
-- klijent ionako filtrira nesigurne URL-ove.
--
-- Idempotentno: stupac s `if not exists`, ograničenja samo ako ne postoje.
-- Drugi run = no-op.
-- =============================================================================

alter table pinka_finance.events
  add column if not exists gallery jsonb not null default '[]'::jsonb;

create or replace function pinka_finance.events_gallery_valid(g jsonb)
returns boolean
language sql
immutable
as $$
  select jsonb_typeof(g) = 'array'
     and jsonb_array_length(g) <= 20
     and not exists (
       select 1 from jsonb_array_elements(g) s
       where jsonb_typeof(s) <> 'object'
          or jsonb_typeof(s -> 'url') is distinct from 'string'
          or char_length(s ->> 'url') not between 1 and 2000
          or (s ? 'alt' and jsonb_typeof(s -> 'alt') not in ('string', 'null'))
          or char_length(coalesce(s ->> 'alt', '')) > 300
     );
$$;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'pinka_finance.events'::regclass and conname = 'events_gallery_shape'
  ) then
    alter table pinka_finance.events
      add constraint events_gallery_shape check (pinka_finance.events_gallery_valid(gallery));
  end if;
end;
$$;

comment on column pinka_finance.events.gallery is
  'Galerija slika događaja: [{"url": "https://…", "alt": "…"}], ≤ 20, redom prikaza. Naslovna je cover_image_url.';

notify pgrst, 'reload schema';

select 'OK events_gallery' as status;
