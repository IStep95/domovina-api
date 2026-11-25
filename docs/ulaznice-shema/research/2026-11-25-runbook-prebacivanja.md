# Runbook prebacivanja produkcije na shemu `ulaznice` (S5 piše, S6 izvodi)

Za sesiju S6 nakon vrata (korisnik odobrio termin). Napisano 2026-11-25 iz repoa, **bez ijednog
poziva prema produkciji**: sve „živo” stanje S6 čita samo, prije prozora. Tajne su placeholderi
(`<ANON>`, `<SERVICE>`, `<CF_ACCOUNT_ID>`); nikad ih ne upisivati u repo.

## Sažetak

1. Prozor: zamrzni pisanje ticketinga u `pinka_finance` **triggerom** (ne `revoke`: RPC-i su `security definer`,
   a `campaigns`/`campaign_tiers`/`contributions` dijele donacije), prod Worker stavi u `NAJAVA`.
2. Pet migracija `20261125150000`–`170000` pojedinačno (dry-run mora pokazati točno njih 5), kopija podataka unutar zamrzavanja.
3. Kopija 5 referenciranih objekata `pinka-covers` → `ulaznice-media` kroz Storage API, pa `PGRST_DB_SCHEMAS += ulaznice`.
4. Deploy 8 `events-*` funkcija, provjere, journal; zatim Ivan: Worker staging → smoke → prod (bez `NAJAVA`).
5. Do koraka 6 rollback je bez gubitka; od koraka 6 (pisanje u `ulaznice`) rollback gubi nove narudžbe. Procjena prozora ~1,5–2 h, kupcu nedostupno ~1–1,5 h.

## Otvorena pitanja za korisnika (vrata prije S6)

1. **Inventar (odluka 309, vrh `S6.md`).** Prenijeti nekonzistentan `inventory_claimed` kako jest ili normalizirati
   (`reserved=false` za `expired`; `claimed` = zbroj rezerviranih)? Ako normalizirati, to je nova migracija iza
   `150200` (S6 je piše i testira nad svježim dumpom prije prozora); runbook je dolje označava kao korak 3.3a.
   Upit za odluku je u koraku 0.4.
2. **Održavanje za kupce.** Prijedlog: prod Worker za vrijeme prozora u `NAJAVA` načinu (`--var NAJAVA:1`, statična
   stranica, `/api/*` i `/webhook/*` → 404, Stripe ponavlja webhook). Alternativa: stari Worker ostaje živ i kupac
   dobiva greške pri kupnji. Treba li i Ivanova potvrda?
3. **Tko deploya Worker u prozoru** (odluka 114: Ivan ili uz njegov dogovor). Ivan mora biti dostupan cijeli prozor,
   jer korak 9 (i 2.3 ako se bira `NAJAVA`) traži deploy.
4. **Plaćena narudžba u smoke testu samo na stagingu** (Stripe sandbox). Live Stripe račun još nije Connect platforma
   (`domovina-ulaznice/docs/deploy-dug.md` #10), pa plaćena narudžba na `ulaznice.domovina.ai` nije provediva. Prihvatljivo?
5. **Zamrzavanje kao jednokratni SQL, ne migracija** (obrazloženje u koraku 2). Posljedica za S7: prvi korak S7 mora
   ukloniti triggere zamrzavanja, inače i brisanje `campaigns type='tickets'` pada na njima.
6. **Mobilna aplikacija (safe-wallet)** zove edge funkcije izravno i ne može se staviti u održavanje: od koraka 2 do 6
   njezina pisanja ticketinga padaju, od koraka 6 rade na `ulaznice`, a `events-confirm` vraća 410 (odluka 400).

---

## Konvencije za cijeli runbook

Sve naredbe iz korijena `domovina-api` u **bashu** (ne zsh), s `HEAD` = commit koji se deploya.

```bash
cd /Users/ms/git/domovinatv/domovina-api
W=backups/s6-$(date -u +%Y%m%d)        # radna mapa: backups/ je gitignoran
mkdir -p "$W"

# SQL datoteka → produkcija (obrazac iz handoffs/README.md; stdin ide kroz bash -c u ssh)
prod_sql() { bash -c '. scripts/lib/db-env.sh; C=$(detect_db_container); ssh_remote "docker exec -i $C psql -U $COOLIFY_DB_USER -d $COOLIFY_DB_NAME -X -v ON_ERROR_STOP=1"' < "$1"; }

# JEDNA migracija točno kao db-migrate.sh (begin; datoteka; red u schema_migrations; commit),
# uz zaštitu da već primijenjena ne ide dvaput
prod_migracija() {
  local m="$1" f="supabase/migrations/$1.sql" v="${1%%_*}" n="${1#*_}"
  [ -f "$f" ] || { echo "nema $f" >&2; return 1; }
  { echo "begin;"
    echo "do \$g\$ begin if exists (select 1 from supabase_migrations.schema_migrations where version = '$v') then raise exception 'vec primijenjena: $v'; end if; end \$g\$;"
    cat "$f"; echo
    echo "insert into supabase_migrations.schema_migrations (version, name) values ('$v', '$n');"
    echo "commit;"; } > "$W/$m.run.sql"
  prod_sql "$W/$m.run.sql"
}
```

`db-migrate.sh` nema zastavicu za jednu migraciju (`scripts/db-migrate.sh:24-31`: samo `--no-backup`, `--dry-run`);
`prod_migracija` je ručni obrazac iz memorije deploya (tako su pušteni og-cache, sponzorski trenuci, venue_geo).
Read-only upiti idu u `begin read only; … rollback;`. SQL datoteke iz ovog runbooka S6 sprema u
`docs/ulaznice-shema/research/sql/s6-*.sql` (commit prije prozora), da naredbe budu ponovljive.

Zapisuj vrijeme svakog koraka (`date -u +%FT%TZ`) u `$W/dnevnik.txt`; `T2` = trenutak zamrzavanja, `T6` = deploy funkcija.

---

## 0. Preduvjeti i vrata (prije prozora, ništa se ne mijenja)

**0.1 Vrata.** U `decisions.md` postoji zapis korisnika: odobreno prebacivanje, termin (bez prodaje u tijeku),
odgovori na pitanja 1–6 gore. Ivan potvrdio dostupnost i da je PR iz S5 mergean u `ivan/main`. Bez toga stani.

**0.2 Git.**
```bash
git fetch origin && git status -sb          # čisto, na main
git log --oneline origin/main..HEAD         # prazno (sve pushano; journal bilježi „pushan na origin”)
git log --oneline HEAD..origin/main         # prazno (nitko nije mergeao u međuvremenu)
ls -lt ~/.claude/projects/-Users-ms-git-domovinatv-domovina-api/*.jsonl | head -3   # paralelne sesije
```

**0.3 Dry-run migracija** (read-only; u dry-runu skripta ne stvara ni tracking tablicu, `db-migrate.sh:38-48`):
```bash
./scripts/db-migrate.sh --dry-run
```
Očekivano točno 5 pending: `20261125150000_ulaznice_shema`, `…150100_ulaznice_media_bucket`, `…150200_ulaznice_kopija_podataka`,
`…160000_ulaznice_rpc_narudzbe`, `…170000_ulaznice_rpc_eventi`. Izvor očekivanja: journal `deploys/20261125T110856Z-1564aab.md`
ima 59 živih migracija, repo 64; razlika su točno tih 5 (naredba:
`diff <(grep -E '^[0-9]{14}' deploys/20261125T110856Z-1564aab.md | awk '{print $1}') <(ls supabase/migrations/*.sql | xargs -n1 basename | cut -d_ -f1)`).
Ako se pojavi išta drugo, **stani**: netko je mergeao migraciju koja nije u lancu.

**0.4 Stanje narudžbi i inventara** (`$W/s6-0-stanje.sql`):
```sql
begin read only;
-- narudžbe ulaznica po stanju; vrata: 0 redaka pending + reserved + nije isteklo
select c.state, c.payment_rail, c.reserved, count(*), sum(c.amount_cents),
       min(c.reserve_expires_at), max(c.reserve_expires_at)
from pinka_finance.contributions c
join pinka_finance.campaigns ca on ca.id = c.campaign_id and ca.type = 'tickets'
group by 1,2,3 order by 1,2,3;

select count(*) as zive_rezervacije
from pinka_finance.contributions c
join pinka_finance.campaigns ca on ca.id = c.campaign_id and ca.type = 'tickets'
where c.state = 'pending' and c.reserved and c.reserve_expires_at > now();

-- odluka 309: claimed vs zbroj rezerviranih po tieru (prikazuje samo razlike)
select t.id, t.inventory_total, t.inventory_claimed,
       coalesce(sum(c.quantity) filter (where c.reserved), 0) as rezervirano
from pinka_finance.campaign_tiers t
join pinka_finance.campaigns ca on ca.id = t.campaign_id and ca.type = 'tickets'
left join pinka_finance.contributions c on c.tier_id = t.id
group by 1,2,3
having t.inventory_claimed <> coalesce(sum(c.quantity) filter (where c.reserved), 0);
rollback;
```
```bash
prod_sql "$W/s6-0-stanje.sql"
```
Vrata: `zive_rezervacije = 0`; nema `failed`/`cancelled` (kopija bi pala, odluka 202). Ako ima žive rezervacije,
pričekaj `reserve_expires_at` ili pomakni termin. 25. 11. (S1/S3): paid/stripe 1, expired/onchain 2, razlike na
tierovima `9940f…` (10 vs 0) i dvije istekle s `reserved=true` (odluka 309).

**0.5 Svjež dump i lokalni probni prolaz** (odluka 209). `ulaznice-prod-dump-test.sh` radi
`supabase db reset` **zajedničkog lokalnog stacka**: najprije provjeri da nijedna druga sesija ne koristi lokalnu bazu.
```bash
./scripts/db-dump.sh --schemas pinka_finance --data          # read-only → backups/<ts>-pinka_finance-full.sql
grep -c '^COPY pinka_finance\.' backups/<ts>-pinka_finance-full.sql   # 25. 11.: 20
scripts/ulaznice-prod-dump-test.sh backups/<ts>-pinka_finance-full.sql
```
Mora završiti „✓ SVE PROVJERE PROŠLE”; zapiši tablicu brojeva iz „→ 4. brojevi” u `$W/dnevnik.txt`: to su
očekivani brojevi za korake 3 i 7. Ako je odabrana normalizacija inventara (pitanje 1), ista skripta mora proći s
dodanom migracijom. Pad = termin se pomiče.

**0.6 Edge env.** `EVENTS_STRIPE_CONFIRM_SECRET` mora postojati u edge runtimeu (bez nje `events-stripe-*` vraćaju 503,
`docs/events-ticketing-curl-scenario.md:604`). Samo imena, ne vrijednosti:
```bash
bash -c '. scripts/lib/db-env.sh; E=$(ssh_remote "docker ps --format {{.Names}} | grep ^supabase-edge-functions- | head -1"); ssh_remote "docker exec $E printenv | cut -d= -f1" | grep -E "EVENTS_STRIPE_CONFIRM_SECRET|SERVICE_ROLE|ANON"'
```
Zapiši i točno ime varijable sa service ključem (koristi se u koraku 4).

**0.7 Žive vrijednosti za rollback** (zapiši u `$W/dnevnik.txt`):
```bash
./scripts/coolify-env-get.sh PGRST_DB_SCHEMAS          # živa lista, korak 5
./scripts/deploy-functions.sh --dry-run --only=events-checkin,events-confirm,events-feed,events-order,events-organizer,events-stripe-confirm,events-stripe-intent,events-tickets
```
Ivan (u `domovina-ulaznice`): `npx wrangler deployments list` i `npx wrangler deployments list --env staging` →
ID-jevi trenutačnih verzija (rollback koraka 2.3 i 9).

**0.8 Smoke podaci.** Izaberi i zapiši: postojeću plaćenu narudžbu (`select id from pinka_finance.contributions c join
pinka_finance.campaigns ca on ca.id=c.campaign_id and ca.type='tickets' where c.state='paid'`), event „Webinar”
`90a62354-d072-4d7e-9bc5-c44021437bf5`, i besplatni objavljeni event test organizatora (`…0000000000f2`,
`seeds/staging-web-pregled.sql` u `domovina-ulaznice`) za narudžbe na stagingu. Pravu ulaznicu kupca **ne skenirati**.

---

## 1. Backup (T1)

`db-migrate.sh` backupira samo `public` i `domovina_ai`, i to schema-only (`db-migrate.sh:87-91`), pa ručno:
```bash
./scripts/db-dump.sh --schemas pinka_finance,storage --data
#  → backups/<ts>-pinka_finance_storage-full.sql
./scripts/db-dump.sh --schemas supabase_migrations --data
#  → backups/<ts>-supabase_migrations-full.sql
f=backups/<ts>-pinka_finance_storage-full.sql
du -h "$f"; grep -c '^COPY pinka_finance\.' "$f"; grep -c '^COPY storage\.' "$f"
grep -A3 '^COPY storage.buckets' "$f" | head        # pinka-covers, pinka-og-cache, sponsor-logos
```
Očekivano: `COPY pinka_finance` = broj iz 0.5, `COPY storage` ≥ 2 (`buckets`, `objects`). Ako `pg_dump` padne na
pravima nad nekom `storage` tablicom, ponovi samo potrebno:
`bash -c '. scripts/lib/db-env.sh; C=$(detect_db_container); remote_pg_dump "$C" "--data-only --table=storage.buckets --table=storage.objects"' > "$W/storage-data.sql"`.

`public.accounts` se ne dumpa: nijedna migracija ga ne mijenja (nove tablice ga samo referenciraju FK-om).
Dump `storage` sadrži samo metapodatke; datoteke su u R2 (`scripts/storage-r2-switch.sh`) i nijedan korak ih ne briše ni ne mijenja.

**Rollback:** nema (samo čitanje). Dump je lokalno u `backups/` (gitignoran), ne commitati.

---

## 2. Zamrzavanje pisanja (T2)

### 2.1 Zašto trigger, a ne `revoke`

- Svi ticketing RPC-i su `security definer` s vlasnikom `postgres` (npr. `create_ticket_order`,
  `20261125120000_events_free_online.sql:88`; `deliver_ticket_orders`, `20260716120200_events_ticketing_rpcs.sql:593`).
  `revoke insert, update, delete` na tablicama ne zaustavlja ih; zaustavio bi samo izravne PostgREST pisove (Worker `PATCH organizer_payment_rails`).
- `campaigns`, `campaign_tiers`, `contributions`, `contribution_events` i `campaign_stats` dijele donacije,
  crowdfund i sponzorske trenutke; `revoke` na njima ruši donacije.
- `revoke execute` na ticketing RPC-ima ne pokriva izravne pisove ni trigger `tg_contribution_state`.

Zato `before insert or update or delete` trigger: okida se i unutar definer RPC-a i za `postgres`, a na dijeljenim
tablicama odbija samo retke kampanja `type='tickets'`. Nije migracija: lokalni testovi „staro ponašanje”
(`supabase/tests/20261125_ulaznice_rpc_*_staro.sql`) pišu u `pinka_finance` ticketing i pali bi nakon `db reset`.
Triggere uklanja S7 (ili rollback). Kandidat za odluku 600+.

### 2.2 SQL (`$W/s6-2-zamrzavanje.sql`)

```sql
begin;
create or replace function pinka_finance.ulaznice_zamrznuto() returns trigger
language plpgsql security definer set search_path = '' as $$
declare j_old jsonb; j_new jsonb; v_hit boolean;
begin
  if tg_op <> 'INSERT' then j_old := to_jsonb(old); end if;
  if tg_op <> 'DELETE' then j_new := to_jsonb(new); end if;
  if tg_argv[0] = 'sve' then
    v_hit := true;
  elsif tg_table_name = 'campaigns' then
    v_hit := coalesce(j_old->>'type', '') = 'tickets' or coalesce(j_new->>'type', '') = 'tickets';
  else  -- dijeljena tablica s campaign_id; definer jer RLS pozivatelja može sakriti skicu
    v_hit := exists (select 1 from pinka_finance.campaigns c
                     where c.type = 'tickets'
                       and c.id in ((j_old->>'campaign_id')::uuid, (j_new->>'campaign_id')::uuid));
  end if;
  if v_hit then
    raise exception using errcode = 'P0001',
      message = format('ulaznice_zamrznuto: %s.%s %s', tg_table_schema, tg_table_name, tg_op),
      hint = 'Ticketing seli u shemu ulaznice (docs/ulaznice-shema, S6).';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;
revoke execute on function pinka_finance.ulaznice_zamrznuto() from public, anon, authenticated;

do $$ declare t text; begin
  foreach t in array array['events','tickets','event_access','organizer_allowlist','organizer_records','organizer_payment_rails'] loop
    execute format('create trigger ulaznice_zamrznuto before insert or update or delete on pinka_finance.%I
                    for each row execute function pinka_finance.ulaznice_zamrznuto(%L)', t, 'sve');
  end loop;
  foreach t in array array['campaigns','campaign_tiers','contributions','contribution_events','campaign_stats'] loop
    execute format('create trigger ulaznice_zamrznuto before insert or update or delete on pinka_finance.%I
                    for each row execute function pinka_finance.ulaznice_zamrznuto(%L)', t, 'kampanja');
  end loop;
end $$;
select 'OK zamrzavanje, triggera: ' || count(*) from pg_trigger where tgname = 'ulaznice_zamrznuto';
commit;
```
S6 to prije prozora pusti **lokalno** (uz `begin; … rollback;` ili nad probnom bazom iz 0.5) i provjeri 2.4.

### 2.3 Redoslijed i kupci

1. Ivan: prod Worker u održavanje (ako je odabrano, pitanje 2), npr. s mergeanim kodom:
   `CLOUDFLARE_ACCOUNT_ID=<CF_ACCOUNT_ID> npm run deploy:prod -- --var NAJAVA:1`
   (wrangler 3.114 ima `--var`, provjereno `npx wrangler deploy --help`; NAJAVA vraća statičnu stranicu i ne dira jezgru,
   pa je kod svejedno koji). Provjera: `curl -s -o /dev/null -w '%{http_code}\n' https://ulaznice.domovina.ai/api/dogadjaji` → 404.
2. `prod_sql "$W/s6-2-zamrzavanje.sql"` → `OK zamrzavanje, triggera: 11`.
3. Zapiši `T2`.

Što vidi tko od T2 do koraka 6: prod kupac stranicu najave; staging Worker i mobilna aplikacija greške pri
narudžbi/uređivanju (edge vraća 400/500 s `ulaznice_zamrznuto`); čitanje (feed, pregled) i dalje radi nad
`pinka_finance`. Stripe webhookovi na `/webhook/stripe` dobivaju 404 i Stripe ih ponavlja; uz vrata 0.4 (0 živih
rezervacija) ne bi ih smjelo biti. Donacije, crowdfund i sponzorski trenuci rade.

### 2.4 Provjera (`$W/s6-2-provjera.sql`, piše pa poništava)

```sql
begin;
do $$ begin
  begin
    update pinka_finance.campaign_tiers set sort = sort
     where campaign_id in (select id from pinka_finance.campaigns where type = 'tickets');
    raise exception 'ZAMRZAVANJE NE RADI: tier ulaznice promijenjen';
  exception when others then
    if sqlerrm not like 'ulaznice_zamrznuto%' then raise; end if;
    raise notice 'OK — tierovi ulaznica zamrznuti';
  end;
  begin
    perform pinka_finance.expire_stale_ticket_orders();   -- definer put; 0 redaka ako nema isteklih
    raise notice 'OK — expire_stale_ticket_orders bez pisanja (nema što isteći)';
  exception when others then
    if sqlerrm not like 'ulaznice_zamrznuto%' then raise; end if;
    raise notice 'OK — definer RPC odbijen triggerom';
  end;
  update pinka_finance.contributions set updated_at = updated_at
   where id = (select c.id from pinka_finance.contributions c
               join pinka_finance.campaigns ca on ca.id = c.campaign_id and ca.type <> 'tickets' limit 1);
  raise notice 'OK — donacijska narudžba i dalje pisiva';
end $$;
rollback;
```
Plus „otisak” izvora za korak 7 (isti upit kao `SRC_Q` u `scripts/ulaznice-prod-dump-test.sh:172-176`) u `$W/dnevnik.txt`.

**Rollback 2:** `begin; do $$ declare t text; begin foreach t in array array['events','tickets','event_access','organizer_allowlist','organizer_records','organizer_payment_rails','campaigns','campaign_tiers','contributions','contribution_events','campaign_stats'] loop execute format('drop trigger if exists ulaznice_zamrznuto on pinka_finance.%I', t); end loop; end $$; drop function if exists pinka_finance.ulaznice_zamrznuto(); commit;`
pa Ivan: `npx wrangler rollback <prod version ID iz 0.7>`. Gubitak: ništa (pisanja su odbijena, ne izgubljena).

---

## 3. Migracije pojedinačno (T3)

Redoslijed po imenu datoteke (isti kao probni prolaz, `scripts/ulaznice-prod-dump-test.sh:62`). Svih pet unutar
zamrzavanja: `150200` je završna kopija koja ne osvježava već kopirane retke (odluka 204), a `160000`/`170000` moraju
ići nakon nje kao u testiranom redoslijedu. Nijedna ne mijenja `pinka_finance`; izvan sheme `ulaznice` diraju samo
`storage.buckets` (1 red) i 3 politike na `storage.objects` (`150100`).

| # | Naredba | Očekivani izlaz | Provjera nakon |
| --- | --- | --- | --- |
| 3.1 | `prod_migracija 20261125150000_ulaznice_shema` | `OK ulaznice_shema` | `select count(*) from information_schema.tables where table_schema='ulaznice' and table_type='BASE TABLE'` → 9 (`grep -c '^create table' supabase/migrations/20261125150000_ulaznice_shema.sql`) |
| 3.2 | `prod_migracija 20261125150100_ulaznice_media_bucket` | `OK ulaznice_media_bucket` | `select id, public, file_size_limit, allowed_mime_types from storage.buckets where id='ulaznice-media'` → 1 red, javan, isto kao `pinka-covers`; `select count(*) from pg_policies where schemaname='storage' and policyname like 'ulaznice_media_%'` → 3 |
| 3.3 | `prod_migracija 20261125150200_ulaznice_kopija_podataka` | `OK ulaznice_kopija_podataka` | brojevi = tablica iz 0.5 (upit §4 i provjere §5 iz `scripts/ulaznice-prod-dump-test.sh:194-233`, kopirati u `$W/s6-3-brojevi.sql` unutar `begin read only; … rollback;`) |
| 3.3a | samo ako je odabrana normalizacija (pitanje 1): nova migracija iz S6 | njezin `OK …` | `inventory_claimed` = zbroj rezerviranih po tieru u `ulaznice` |
| 3.4 | `prod_migracija 20261125160000_ulaznice_rpc_narudzbe` | `OK ulaznice_rpc_narudzbe` | `select count(distinct proname) from pg_proc where pronamespace='ulaznice'::regnamespace` raste; trigger `trg_order_state` postoji |
| 3.5 | `prod_migracija 20261125170000_ulaznice_rpc_eventi` | `OK ulaznice_rpc_eventi` | isti upit → 23 imena (`grep -ho "create or replace function ulaznice\.[a-z_]*" supabase/migrations/2026112515*.sql supabase/migrations/2026112516*.sql supabase/migrations/2026112517*.sql \| sort -u \| wc -l`); trigger `trg_ticket_tiers_write_guard` postoji |

Nakon 3.5: `./scripts/db-migrate.sh --dry-run` → „✅ Sve migracije već primijenjene.”; `./scripts/db-status.sh`
pokazuje head `20261125170000`. Kopija pada glasno (odluka 202): ako `150200` baci `ulaznice_kopija: …`, transakcija
je poništena, prekini prozor i idi na rollback 3 pa 2.

**Rollback 3** (`$W/s6-3-rollback.sql`), valjan dok ništa ne piše u `ulaznice` (do koraka 6):
```sql
begin;
drop schema ulaznice cascade;
drop policy if exists ulaznice_media_insert on storage.objects;
drop policy if exists ulaznice_media_update on storage.objects;
drop policy if exists ulaznice_media_delete on storage.objects;
delete from supabase_migrations.schema_migrations
 where version in ('20261125150000','20261125150100','20261125150200','20261125160000','20261125170000');
commit;
```
Bucket se briše kroz Storage API nakon pražnjenja (rollback 4), ne SQL-om, da R2 ne ostane sa siročadi.
Gubitak: ništa (`ulaznice` ima samo kopirane retke).

---

## 4. Kopija objekata `pinka-covers` → `ulaznice-media` (T4)

Mora biti gotovo **prije koraka 6**: novi `events-feed` vraća URL-ove koje je `150200` već prepisao na
`/public/ulaznice-media/` (odluka 206). Kopiraju se samo objekti koje referencira event (odluka 105; 25. 11.: 5 od 10).
Isti ključ (`{uid}/{uuid}.{ext}`) u novom bucketu, jer je prepisan samo naziv bucketa.

Alat: Storage API sa service ključem, ne SQL nad `storage.objects`. Backend je R2 s vlastitim rasporedom ključeva
(`storage-single-tenant/<bucket>/<name>/<version>`, `scripts/storage-r2-switch.sh:15-16`), pa ručno upisani red u
`storage.objects` ne bi imao datoteku.

**4.1 Popis ključeva** (`$W/s6-4-kljucevi.sql`):
```sql
begin read only;
with u as (
  select cover_image_url as url from ulaznice.events where cover_image_url is not null
  union all
  select g->>'url' from ulaznice.events, jsonb_array_elements(coalesce(gallery, '[]'::jsonb)) g
)
select distinct (regexp_match(url, '/public/ulaznice-media/([^?#]+)'))[1] as kljuc
from u where url like '%/public/ulaznice-media/%' order by 1;
rollback;
```
```bash
prod_sql "$W/s6-4-kljucevi.sql" | grep -E '^ [0-9a-f-]+/' | tr -d ' ' > "$W/kljucevi.txt"; wc -l < "$W/kljucevi.txt"
```
Broj = referencirani objekti iz 0.5 (25. 11.: 5). Svaki ključ mora postojati u `pinka-covers`
(`select name from storage.objects where bucket_id='pinka-covers' and name in (…)`).

**4.2 Kopija** na hostu, da service ključ ne izlazi s poslužitelja (obrazac `scripts/ops-verify.sh`):
```bash
bash -c '. scripts/lib/db-env.sh; E=$(ssh_remote "docker ps --format {{.Names}} | grep ^supabase-edge-functions- | head -1");
  ssh_remote "E=$E; K=\$(docker exec \$E printenv <IME_SERVICE_VARIJABLE_IZ_0.6>); while read -r k; do
    printf \"%s \" \"\$k\";
    curl -sS -o /dev/null -w \"%{http_code}\n\" -X POST https://api.domovina.ai/storage/v1/object/copy \
      -H \"apikey: \$K\" -H \"Authorization: Bearer \$K\" -H \"Content-Type: application/json\" \
      -d \"{\\\"bucketId\\\":\\\"pinka-covers\\\",\\\"sourceKey\\\":\\\"\$k\\\",\\\"destinationBucket\\\":\\\"ulaznice-media\\\",\\\"destinationKey\\\":\\\"\$k\\\"}\";
  done"' < "$W/kljucevi.txt"
```
Očekivano `200` po ključu. **Nepotvrđeno iz repoa:** podržava li `storage-api v1.44.2` (journal `1564aab`) polje
`destinationBucket` u `/object/copy`. Prvo probaj s jednim ključem. Ako vrati 400/404, rezerva za isti ključ:
`curl -o f https://api.domovina.ai/storage/v1/object/public/pinka-covers/<k>` pa
`curl -X POST …/storage/v1/object/ulaznice-media/<k> -H "Content-Type: <mime iz storage.objects.metadata>" --data-binary @f`
(sa service ključem, na hostu). Bucket ograničenja (5 MB, MIME) vrijede i za kopiju.

**4.3 Provjera:**
```bash
# svaki URL iz ulaznice.events mora vratiti 200 (javni bucket, bez ključa)
while read -r k; do curl -s -o /dev/null -w "%{http_code} $k\n" "https://api.domovina.ai/storage/v1/object/public/ulaznice-media/$k"; done < "$W/kljucevi.txt"
```
i `select count(*) from storage.objects where bucket_id='ulaznice-media'` = broj ključeva. URL-ove s `render/image`
(odluka 206) provjeri istim ključem kroz `/storage/v1/render/image/public/ulaznice-media/<k>` ako ih ima.

**Rollback 4:** `POST /storage/v1/bucket/ulaznice-media/empty` pa `DELETE /storage/v1/bucket/ulaznice-media`
(service ključ, na hostu). Originali u `pinka-covers` se ne diraju. Gubitak: ništa.

---

## 5. `PGRST_DB_SCHEMAS` + `ulaznice` (T5)

Cijeli korak, provjera i rollback su u [2026-11-25-pgrst-db-schemas.md](2026-11-25-pgrst-db-schemas.md). Ukratko:
tek nakon koraka 3; **živa lista iz 0.7 + `,ulaznice`** (ne lista iz repoa) s
`./scripts/coolify-env-set.sh PGRST_DB_SCHEMAS=<živa lista>,ulaznice --recreate-service=supabase-rest`; recreate
treba samo `supabase-rest` (~5 s; edge runtime i Kong ne čitaju varijablu). Provjera: `Accept-Profile: ulaznice` na
`/rest/v1/events?select=id&limit=1` → 200, a `pinka_finance` i `domovina_ai` i dalje 200. U istom commitu dopisati
`ulaznice` u `scripts/build-coolify-env.sh:174` i `coolify-config-overrides.env:22`.

**Rollback 5:** ista naredba sa živom listom bez `ulaznice`. Gubitak: ništa.

---

## 6. Deploy 8 funkcija `events-*` (T6) — od ovdje se piše u `ulaznice`

Lista iz `ls supabase/functions | grep '^events-'`: `events-checkin`, `events-confirm`, `events-feed`, `events-order`,
`events-organizer`, `events-stripe-confirm`, `events-stripe-intent`, `events-tickets`. `--only` uvijek nosi i `_shared`
(`deploy-functions.sh:81`); `_shared` se od zadnjeg deploya nije mijenjao (`git diff --stat 1564aab..HEAD -- supabase/functions`
pokazuje samo 8 `events-*`), pa `pinka-*` ostaju iste. Restart edge kontejnera prekida sve funkcije nekoliko sekundi.

```bash
./scripts/deploy-functions.sh --only=events-checkin,events-confirm,events-feed,events-order,events-organizer,events-stripe-confirm,events-stripe-intent,events-tickets --restart -y
```
Zapiši `T6`. Provjere (anon ključ na hostu kao u `ops-verify.sh`, ili `<ANON>` lokalno):

| Poziv | Očekivano |
| --- | --- |
| `GET /functions/v1/events-feed` | 200, `{events, limit, offset}`; objavljeni eventi; svaki `cover_image_url`/`gallery[].url` iz bucketa `ulaznice-media` i 200 |
| `POST /functions/v1/events-confirm` `{}` | 410 `{"error":"onchain_rail_removed"}` (odluka 400) |
| `POST /functions/v1/events-stripe-confirm` `{}` | 401 (HMAC; ne 200, ne 503) |
| `POST /functions/v1/events-organizer` bez JWT-a | 401 `not_authenticated` |
| `POST /functions/v1/events-checkin` bez JWT-a | 401 `not_authenticated` |

Svi uz `-H "apikey: <ANON>"` (Kong). `grep -rn pinka_finance supabase/functions/events-*` lokalno prazan (S4).

**Rollback 6:** funkcije iz zadnjeg deployanog commita:
```bash
git worktree add ../domovina-api-1564aab 1564aab
(cd ../domovina-api-1564aab && SECRETS_FILE=/Users/ms/git/domovinatv/domovina-api/.local-secrets.env \
  ./scripts/deploy-functions.sh --only=events-checkin,events-confirm,events-feed,events-order,events-organizer,events-stripe-confirm,events-stripe-intent,events-tickets --restart -y)
git worktree remove ../domovina-api-1564aab
```
(stara skripta u tom commitu možda ne prima listu sa zarezom, memorija: „od 2026-11-25”; tada petlja po jednu, `--restart`
samo na zadnjoj). Zatim rollback 5, 4, 3, 2. **Gubitak:** svaka narudžba, ulaznica, check-in ili izmjena organizatora
upisana u `ulaznice` nakon `T6`. Obrnute kopije nema; prije rollbacka izlistaj ih
(`select id, state, payment_rail, created_at from ulaznice.orders where created_at > '<T6>'`, isto za `order_events`,
`tickets`, `events.updated_at`) i odluči ručno.

---

## 7. ops-verify i usporedba stare i nove sheme

```bash
./scripts/ops-verify.sh            # mora PASS (gleda kontejnere, GoTrue, PostgREST domovina_ai, 3 edge funkcije)
```
`ops-verify` ne gleda `ulaznice` ni `pinka_finance`, zato i (`$W/s6-7-usporedba.sql`, read-only):
- §4 brojevi i §5 provjere iz `scripts/ulaznice-prod-dump-test.sh:194-233` (isti ID-jevi eventa, tierova, narudžbi,
  ulaznica, audita; nema `pinka-covers` u `ulaznice.events`; donacije nisu u `ulaznice`) → jednako 0.5;
- `SRC_Q` (`ulaznice-prod-dump-test.sh:172-176`) → jednako otisku iz 2.4 (`pinka_finance` netaknut od `T2`);
- `select count(*) from pinka_finance.contributions c join pinka_finance.campaigns ca on ca.id=c.campaign_id
  where ca.type <> 'tickets' and c.created_at > '<T2>'` → donacije su se mogle nastaviti (informativno);
- `select j.jobname, d.status, count(*) from cron.job_run_details d join cron.job j using (jobid)
  where d.start_time > '<T2>' group by 1,2` → `sponsor-*` bez `failed`.

---

## 8. Deploy journal

Nakon koraka 7, prije Workera (Worker nije dio journala jezgre), uz čisto stablo i pushan `HEAD`:
```bash
./scripts/deploy-journal.sh --dry-run --verify --note "ulaznice S6: zamrzavanje pinka_finance ticketinga, migracije 20261125150000-170000 pojedinačno, ulaznice-media kopija, PGRST_DB_SCHEMAS+ulaznice, 8 events-*"
./scripts/deploy-journal.sh --verify --note "<ista bilješka>" --commit
```
Očekivano: novi `deploys/<UTC>-<sha>.md`, `count: 64`, head `20261125170000 ulaznice_rpc_eventi`, `ops-verify PASS`,
red na vrhu `deploys/INDEX.md`. Milestone se ne uređuje naknadno; ishod koraka 9–10 ide u S6 zapis (`decisions.md`/handoff),
a po potrebi drugi milestone. Commit samo imenovanih datoteka (journal to radi sam); `git log origin/main..HEAD` prije pusha.

**Rollback:** nema (zapis). Ako se radi rollback jezgre, novi milestone s bilješkom „rollback”.

---

## 9. Worker: staging → prod (Ivan, ili uz njegov dogovor)

Repo `domovina-ulaznice`, mergeani S5 PR na `ivan/main`. D1 se ne mijenja (ID-jevi isti; `migrations/` u PR-u nema
novih datoteka); tajne (`DOMOVINA_API_SERVICE_KEY`, `EVENTS_STRIPE_CONFIRM_SECRET`, `STRIPE_*`, `RESEND_API_KEY`)
i varovi (`DOMOVINA_API_URL`, `SKRIVENI_ORGANIZATORI`) se ne mijenjaju. Oba okruženja gađaju istu jezgru
(`wrangler.jsonc:24-29`), pa je i staging od koraka 6 nad `ulaznice`.

```bash
cd <domovina-ulaznice na mergeanom ivan/main>
npm ci && npm test && npm run test:types
# web/ samo ako PR mijenja web/ funkcionalno (S5 je dirao samo komentare): prvo web, pa Worker
#   npm --prefix web run deploy:staging
CLOUDFLARE_ACCOUNT_ID=<CF_ACCOUNT_ID> npm run deploy          # staging (wrangler deploy --env staging)
```
Provjera staginga: `/api/zdravlje` (`stripe`, `webhook`, `hmac` = true), `/api/dogadjaji` 200 s događajima, zatim smoke
10.1–10.5 na stagingu. Tek tada:
```bash
CLOUDFLARE_ACCOUNT_ID=<CF_ACCOUNT_ID> npm run deploy:prod     # bez --var → NAJAVA nestaje, puna aplikacija
```
Provjera produkcije: `/`, `/organizator`, `/skener`, `/api/dogadjaji` → 200; `/api/zdravlje` kao prije prozora.

**Rollback 9:** `npx wrangler rollback <ID>` (`--env staging` za staging), ID-jevi iz 0.7. Sam za sebe nema smisla:
stari Worker čita `pinka_finance` izravno, pa ide uz rollback 6…2. Od prod deploya pišu pravi kupci → vidi tablicu niže.

---

## 10. Smoke test (zapisati naredbe i ishode)

Na **stagingu** (`ulaznice-staging.domovina.ai`, Stripe sandbox, test organizator):
1. **Besplatna narudžba:** besplatni objavljeni event → „Uzmi ulaznice” → `/ulaznice/<id>?besplatno=1` s QR-om; u bazi
   `select state, payment_rail from ulaznice.orders where id='<id>'` → `paid`/`free`, red u `ulaznice.tickets`.
2. **Plaćena narudžba (§11.8 `docs/events-ticketing-curl-scenario.md`):** Checkout s karticom 4242… na Connect računu
   test organizatora → webhook → `events-stripe-confirm` → `paid` + QR; ponovljena dostava istog eventa (Stripe Dashboard
   „Resend”) → `already_paid`; povrat u Stripeu → `refund_ticket_order` → `refunded`; `account.updated` upiše
   `ulaznice.organizer_payment_rails`.
3. **Skener:** `/skener`, test ulaznica iz 10.1 → prvo skeniranje prolazi, drugo `already_checked_in`. Prava ulaznica kupca se ne skenira.
4. **Organizator:** prijava test organizatora, `/organizator/novi` korak 3 upload slike → URL sadrži `/ulaznice-media/`,
   slika 200; skica se sprema, uređuje i briše.
5. **Feed:** `events-feed` i `/api/dogadjaji` pokazuju objavljene evente (bez test organizatora na produkciji).

Na **produkciji** (`ulaznice.domovina.ai`), bez kupnje:
6. Event „Webinar” `90a62354-d072-4d7e-9bc5-c44021437bf5` i ostali vidljivi organizatoru u `/organizator` (pregled
   kroz `organizer_overview`) — prijavom korisnika.
7. Postojeća plaćena Stripe narudžba iz 0.8: `/ulaznice/<order_id>` otvara narudžbu, ulaznica se preuzima (QR rotacija,
   `rotate_ticket_tokens` sada postoji u `ulaznice`).
8. **Donacije:** `pinka-*` rade: `Accept-Profile: pinka_finance` na javnom viewu donacija 200; nova donacija ako
   korisnik želi pravu (inače usporedba iz koraka 7: donacije nakon `T2` upisane bez greške).

Čišćenje: test narudžbe na stagingu ostaju na test organizatoru s fiksnim UUID-ovima (`seeds/`), ne brišu se ručno u prozoru.

---

## 11. Stare tablice nakon prozora

**Ne odmrzavati.** `pinka_finance` ticketing ostaje zamrznut do S7 (expand → cutover → contract, odluka 4); triggeri
iz koraka 2 su ono što S7 uklanja prvo, pa briše. Stari ticketing RPC-i i dalje postoje i svaki pis kroz njih pada s
`ulaznice_zamrznuto`; to je željeni signal da je neki potrošač ostao na staroj shemi (gledati logove edge funkcija i
Workera u razdoblju promatranja). Donacije, crowdfund i sponzorski trenuci moraju raditi: provjera iz koraka 7 ponovljena
dan nakon prozora i u S7.

Na vrh `S7.md` (S6): datum isteka promatranja (prijedlog 14 dana), pitanje za brisanje, i napomena „prvo
`drop trigger ulaznice_zamrznuto` na 11 tablica i `drop function pinka_finance.ulaznice_zamrznuto()`”.

---

## Točka bez povratka

| Nakon koraka | Rollback | Što se gubi |
| --- | --- | --- |
| 0–1 | ništa za vratiti | ništa |
| 2 zamrzavanje | rollback 2 (+ Worker rollback ako je bio NAJAVA) | ništa; pisanja u prozoru su odbijena |
| 3 migracije | rollback 3, pa 2 | ništa; `ulaznice` ima samo kopiju |
| 4 kopija objekata | rollback 4, 3, 2 | ništa |
| 5 PGRST | rollback 5, 4, 3, 2 | ništa |
| **6 funkcije** | rollback 6, 5, 4, 3, 2 | **sve upisano u `ulaznice` nakon `T6`** (smoke narudžbe, mobilna aplikacija, izmjene organizatora); ručni prijenos |
| 9 Worker prod | rollback 9, 6, 5, 4, 3, 2 | uz gornje, **prave narudžbe kupaca i Stripe uplate** koje postoje u Stripeu i D1, a ne u `pinka_finance`; povrat ili ručni upis |

Formalna točka bez povratka je **korak 6**; praktična (pravi novac) je **prod deploy u koraku 9**. Odluka o rollbacku
nakon 9 ide korisniku, ne sesiji.

## Procjena trajanja

| Dio | Procjena |
| --- | --- |
| 0 (dan prije / sat prije): vrata, dump, probni prolaz | 20–30 min, izvan prozora |
| 1 backup | 2–5 min |
| 2 NAJAVA deploy + zamrzavanje + provjera | 5–10 min |
| 3 pet migracija s provjerama | 10–15 min |
| 4 kopija 5 objekata + provjera | 5–10 min (više ako treba rezervni put) |
| 5 PGRST + provjera | 3–5 min |
| 6 funkcije + provjere | 5–10 min |
| 7–8 usporedba, ops-verify, journal | 10 min |
| 9–10 Worker staging, smoke na stagingu, prod deploy, smoke na produkciji | 30–45 min |

Ukupno ~1,5–2 h; kupcu na `ulaznice.domovina.ai` nedostupno od 2.3 do prod deploya u 9 (~1–1,5 h). Procjena nije
izmjerena; S6 upisuje stvarna vremena iz `$W/dnevnik.txt`.

## Proturječja i napomene nađene pri pisanju

- `handoffs/S5.md` točka 4 i odluka 4 kažu „revoke insert/update na stare ticketing tablice”. To ne bi zaustavilo
  definer RPC-e, a na dijeljenim tablicama srušilo bi donacije; runbook koristi trigger (korak 2).
- `docs/events-ticketing-curl-scenario.md:597-601` deploya funkcije petljom po jednu; `deploy-functions.sh` od 25. 11.
  prima listu sa zarezom (`deploy-functions.sh:23`), pa je ovdje jedan poziv.
- `scripts/ulaznice-prod-dump-test.sh:3` i `:27` spominju „tri”/četiri migracije, a `NOVE` (`:62`) ih ima pet; skripta
  primjenjuje svih pet, opis zaostaje.
- `domovina-ulaznice/docs/deploy-dug.md` #4 i dalje vodi rujanske migracije `20260903*` kao dug za deploy; odlukama 111
  i 210 one se nikad ne primjenjuju (uklonjene iz repoa). Za Ivana/S5.
- `ops-verify.sh` ne provjerava ni `pinka_finance` ni `ulaznice`; dodatne provjere su u koracima 6 i 7.
- `ulaznice-prod-dump-test.sh` resetira zajednički lokalni Supabase; uskladiti s paralelnim sesijama (0.5).
