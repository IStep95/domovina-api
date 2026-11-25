# `ulaznice` u PostgREST `db-schemas` — promjena za produkciju (S4, primjenjuje S6)

Lokalno je gotovo: `supabase/config.toml:18` već ima `ulaznice` (S2). Na produkciji **ne
primjenjivati prije S6** (odluka 8, vrata prije S6).

## Zašto

Edge funkcije `events-*` i Worker `domovina-ulaznice` čitaju preko PostgREST-a
(`.schema("ulaznice")` u supabase-js = `Accept-Profile`/`Content-Profile: ulaznice`). Bez sheme u
`PGRST_DB_SCHEMAS` svaki takav poziv vraća 406 `PGRST106`.

## Stanje 25. 11. 2026. (iz repoa, ne s produkcije)

| Izvor | Vrijednost |
| --- | --- |
| `scripts/build-coolify-env.sh:174` | `public,storage,graphql_public,domovina_ai,pinka_finance,vijesti` |
| `coolify-config-overrides.env:22` (CSV_UNION, `scripts/coolify-env-merge.sh:49`) | `public,domovina_ai,storage,graphql_public` |

Živu vrijednost S6 čita prije promjene: `./scripts/coolify-env-get.sh PGRST_DB_SCHEMAS` (ili
`docker inspect` kontejnera `supabase-rest-*`, `grep ^PGRST_DB_SCHEMAS=`).

## Koraci u S6 (redoslijed je bitan)

1. Migracije `20261125150000`–`20261125170000` primijenjene (shema `ulaznice` postoji). Shema u
   listi prije nego postoji nije testirana; ne riskirati.
2. Postaviti **živu vrijednost + `,ulaznice`** (ne prepisivati listu iz repoa, mogla je otići naprijed):
   ```bash
   ./scripts/coolify-env-set.sh PGRST_DB_SCHEMAS=<živa lista>,ulaznice --recreate-service=supabase-rest
   ```
   Recreate treba samo `supabase-rest` (~5 s). Edge runtime i Kong ne čitaju tu varijablu.
3. Provjera (anon ključ iz `docker inspect`, vidi `scripts/coolify-restart.sh:129`):
   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' -H "apikey: $ANON" -H 'Accept-Profile: ulaznice' \
     'https://api.domovina.ai/rest/v1/events?select=id&limit=1'
   ```
   Očekivano `200` (anon vidi objavljene evente kroz RLS). `406` = lista nije primijenjena.
   Ista provjera s `Accept-Profile: pinka_finance` i `domovina_ai` mora ostati `200` (ništa nije ispalo).
4. U repou u istom commitu dopisati `ulaznice` u `scripts/build-coolify-env.sh:174` i
   `coolify-config-overrides.env:22`, da sljedeći merge ne zaboravi shemu.

**Rollback:** isti `coolify-env-set.sh` sa živom listom bez `ulaznice`, `--recreate-service=supabase-rest`.
Uklanjanje sheme iz liste ne dira podatke.

U S7, kad se ticketing makne iz `pinka_finance`, `pinka_finance` **ostaje** u listi (donacije, sponzorski
trenuci).
