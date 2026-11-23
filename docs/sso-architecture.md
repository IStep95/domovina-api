# SSO arhitektura

Cilj: korisnik napravi profil i onboarding **jednom**, koristi ga na svim domovina.* aplikacijama.

## Model: zajednički Supabase projekt, per-app PKCE

Sve aplikacije inicijaliziraju `supabase-js` s istim URL-om i istim anon ključem:

```ts
import { createClient } from '@supabase/supabase-js'

export const supabase = createClient(
  'https://api.domovina.ai',
  process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
  {
    auth: {
      flowType: 'pkce',
      detectSessionInUrl: true,
      persistSession: true,
      autoRefreshToken: true,
    },
  }
)
```

Korisnik s istim email-om je **isti `auth.users.id`** na svim aplikacijama → isti profil → ista DB pravila.

## Cross-domain ograničenje

Domene su različite TLD-ovi (`.ai`, `.energy`, `.tv`), pa cookie-based shared session **ne radi** (browseri ne dijele cookie između različitih registrable domains). Dvije opcije:

### Opcija A — Per-app login (preporučeno za start)

Svaki frontend ima svoj `/login` koji koristi isti Supabase Auth. Korisnik se loguira jednom po domeni; **isti credentijali svuda**.

UX boljitke:
- **Google OAuth** (ili drugi social) — jedan klik, nema friction.
- **Magic link** — email link otvara browser, sesija je instant.
- Lokalni `remember me` (default 1h JWT + refresh token).

Pro: nula custom koda, sve out-of-the-box Supabase.
Kontra: korisnik vidi "Login" stranicu na svakom novom domeni prvi put.

### Opcija B — Centralni `auth.domovina.ai` bridge

Centralni auth UI na `auth.domovina.ai` drži session i propagira token na child apps preko redirect + URL fragment (`#access_token=...`) ili `postMessage`-a iz iframea.

Pro: izgleda kao "pravi SSO".
Kontra: custom kod, više pokretnih dijelova, deeper integration testing, lakše za kvariti.

**Odluka**: krećemo s A. B je nadogradnja kad poslovno opravdamo.

## Profil shema

Migracija `supabase/migrations/0001_profiles.sql` kreira:

```sql
create table public.profiles (
  id uuid primary key references auth.users on delete cascade,
  email text unique not null,
  full_name text,
  avatar_url text,
  locale text default 'hr',
  onboarded_at timestamptz,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

alter table public.profiles enable row level security;

create policy "profiles_select_own" on public.profiles
  for select using (auth.uid() = id);

create policy "profiles_update_own" on public.profiles
  for update using (auth.uid() = id);

-- Auto-create profile on signup
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, email, full_name, avatar_url)
  values (
    new.id,
    new.email,
    new.raw_user_meta_data->>'full_name',
    new.raw_user_meta_data->>'avatar_url'
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();
```

## Per-app dodatne tablice

Svaka aplikacija ima svoje tablice koje refenciraju `profiles.id`:

```sql
-- domovina.ai
create table public.ai_threads (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  ...
);

-- domovina.energy
create table public.energy_meters (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  ...
);
```

RLS uvijek `auth.uid() = user_id`.

## Redirect URL allowlist

`ADDITIONAL_REDIRECT_URLS` (Coolify env; compose iz njega izvodi
`GOTRUE_URI_ALLOW_LIST`) mora pokrivati sve aplikacije. Stanje na produkciji
23. 11. 2026. (26 unosa; mijenja se s `coolify-env-set.sh
ADDITIONAL_REDIRECT_URLS=<cijeli popis> -y --recreate-service=supabase-auth`,
vrijednost je cijeli popis, ne dodatak):

```
https://domovina.ai/**              https://www.domovina.ai/**
https://domovina.energy/**          https://www.domovina.energy/**
https://domovina.tv/**              https://www.domovina.tv/**
ai.domovina://auth/callback
https://pinka-app.pages.dev/**      https://pinka.finance/**
https://www.pinka.finance/**        https://app.pinka.finance/**
https://pinka.io/**                 https://www.pinka.io/**
https://rodjendaonice.domovina.ai/**
https://tehnoetika.domovina.ai/**   https://tehnoetika-app.d-o-m.workers.dev/**
https://tehnoetika.com/**           https://www.tehnoetika.com/**
com.podcasterium://auth/callback    https://podcasterium.com/auth/callback
https://ulaznice.domovina.ai/**     https://ulaznice-staging.domovina.ai/**   (23. 11. 2026, Google prijava ulaznica)
http://localhost:3000/**  http://localhost:5173/**  http://localhost:5181/**  http://localhost:8787/**
```

Origin koji nije na popisu ne dobije grešku: GoTrue nakon prijave tiho vrati
na `GOTRUE_SITE_URL` (`https://domovina.ai`). Trenutni popis:
`docker exec supabase-auth-<id> printenv GOTRUE_URI_ALLOW_LIST`.

Kad dodajemo novu domovina.* aplikaciju, update env var → redeploy GoTrue (Coolify "Restart" je dovoljan).
