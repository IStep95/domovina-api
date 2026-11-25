# Odluke — odvajanje ulaznica

Svaka odluka ima broj, datum, razlog i uvjet revizije. Odluka se ne briše: kad se promijeni,
dopiše se nova koja je zamjenjuje („zamjenjuje N”). Blokovi brojeva po sesiji su u
[plan.md](plan.md) (S1 od 100, S2 od 200…), da se paralelni rad ne sudari.

## S0 (2026-11-25)

1. **Opseg.** Ticketing (eventi, tierovi, narudžbe, ulaznice, organizatori, online pristup)
   seli iz `pinka_finance` u novu shemu `ulaznice`. Donacije, crowdfunding, sponzorski trenuci,
   slotovi i yield ostaju gdje jesu i ne mijenjaju se osim uklanjanja ticketing grana u F4.
   Razlog: polazna pretpostavka iz 7/2026 (onchain EURe i Safe po kampanji čine ~80 %
   ticketinga, `safe-wallet-monorepo/docs/whitelabel-wallet/11-dogadjaji-p2p-ticketing.md` §3.2)
   više ne vrijedi: 25. 11. 2026. od 4 eventa samo 1 ima Safe, jedina plaćena narudžba je
   Stripe, a migracije ulaznica mijenjaju ograničenja na `contributions` na kojima stoje donacije.
   Revizija: ako se pokaže da ulaznice moraju dijeliti narudžbe s Pinkom (npr. jedinstvena košarica).

2. **Isti UUID-ovi.** `campaigns.id` postaje `ulaznice.events.id`, `contributions.id`
   postaje `ulaznice.orders.id`, tier i ulaznica zadržavaju svoje. Razlog: ID-jevi žive izvan
   baze (QR, Stripe metadata, mailovi, linkovi, D1 Workera); promjena bi ih razbila.

3. **HTTP ugovor edge funkcija se ne mijenja.** Putanje, tijela i odgovori `events-*`
   ostaju isti; RPC-i u `ulaznice` zadržavaju imena, potpise i oblik JSON-a gdje je moguće.
   Razlog: mobilne aplikacije i Worker se tada mijenjaju minimalno (samo profil sheme kod
   izravnih PostgREST poziva). Revizija: ako S1 nađe ime koje je samo po sebi zbunjujuće,
   preimenovanje ide kao zasebna odluka s popisom potrošača.

4. **Expand → cutover → contract.** Nova shema i kopija podataka nastaju uz staru (F1),
   potrošači se prebace (F2–F3), stara se briše tek nakon razdoblja promatranja i odobrenja (F4).
   Za vrijeme prebacivanja pisanje u stare ticketing tablice se zamrzava (revoke), da se podaci
   ne razilaze.

5. **Bez nove konsolidirane povijesti.** Postojećih 13 migracija `*event*` ostaje u repou kao
   povijest; nove migracije grade `ulaznice` od nule. Ne prepisuju se primijenjene migracije.

6. **Bucket `ulaznice-media`.** Novi uploadi idu u njega, s istim ograničenjima kao
   `pinka-covers` (javan, 5 MB, isti MIME tipovi, mapa po korisniku). Objekti eventa iz
   `pinka-covers` kopiraju se i URL-ovi u `ulaznice.events` (cover, galerija) prepisuju.
   R2 ispod Supabase Storagea se ne dira (`scripts/storage-r2-switch.sh`).

7. **Testiranje.** Svaka migracija prolazi `supabase db reset` lokalno i primjenu nad vraćenim
   prod dumpom po `docs/migration-testing-playbook.md`. SQL testovi u `supabase/tests/` ispisuju
   `OK —` po provjeri i završavaju sa „SVE PROVJERE PROŠLE”. Testovi ne gađaju produkciju.

8. **Produkcija samo kroz vrata.** Primjena na `api.domovina.ai` je nepovratna i vanjska:
   sesija pripremi runbook, korisnik odobri, migracije se primjenjuju pojedinačno (ne
   `db-migrate.sh` naslijepo, jer na produkciji namjerno stoje dvije neprimijenjene migracije
   iz 9/2026).

9. **Ivanov repo.** Promjene u `domovina-ulaznice` idu na granu od `ivan/main` i kao PR
   Ivanu (IStep95); deploy Workera radi on ili uz njegov dogovor.

## S1 (2026-11-25)

Odluke sesije bez korisnika. Pitanja koja traže korisnika su na vrhu [handoffs/S2.md](handoffs/S2.md).
Izvor svih brojki: [research/2026-11-25-inventura.md](research/2026-11-25-inventura.md).

100. **Mapiranje.** `campaigns`(`type='tickets'`) + `events` → `ulaznice.events`; `campaign_tiers` →
     `ulaznice.ticket_tiers`; `contributions` → `ulaznice.orders`; `contribution_events` →
     `ulaznice.order_events`; `tickets`, `event_access`, `organizer_allowlist`, `organizer_records`,
     `organizer_payment_rails` zadržavaju ime u `ulaznice`. Stupci `campaign_id` → `event_id`,
     `contribution_id` → `order_id`. Imena i parametri RPC-a se ne mijenjaju (odluka 3), pa ni
     `p_campaign_id`. Razlog: HTTP ugovor je isti, a edge funkcije i Worker se ionako mijenjaju zbog
     sheme. Revizija: ako korisnik na vratima odluči zadržati stara imena tablica (pitanje 5 u S2.md).
101. **`organizer_payment_rails`, `organizer_records`, `organizer_allowlist` sele u `ulaznice`.** Koristi ih
     samo ticketing (Stripe Connect i DAC7 organizatora); donacije ih ne čitaju.
102. **Enumi `pinka_finance` se ne koriste u `ulaznice`.** Stanja i vidljivost su `text` s CHECK-om;
     `ticket_state` dobiva vlastiti enum u `ulaznice`. Razlog: S7 mora moći brisati bez ovisnosti.
103. **`sanitize_ugc`, `slugify` i `events_gallery_valid` dobivaju kopije u `ulaznice` (S2).**
     `pinka_finance.sanitize_ugc` koriste sponzorski trenuci i postavke kanala, pa ne seli.
104. **Ne sele:** `tickets.slot_id` (0 redaka, FK na `pinka_finance.slots`), `campaign_stats` (pregled
     se računa iz `orders`), donacijski stupci `contributions` (popis u inventuri §4.3).
105. **Kopiraju se samo objekti `pinka-covers` koje referencira event** (5 od 10: 2 cover, 3 galerija).
     Original ostaje u `pinka-covers` do S7 zbog URL-ova izvan baze (D1 `event_pages`, nacrti, og:image).
106. **Podjela S3/S3b ostaje** (A: 9 RPC-a, 798 redaka; B: 6 RPC-a, 630 redaka). Pomoćne funkcije i
     `touch_updated_at` trigeri idu u S2; trigger inventara narudžbe u S3; SQL testovi primijenjenog
     ticketinga pišu se od nule (danas ih nema).
107. **Migracije = produkcija** osim dviju iz 9/2026 (katalog uspoređen, 5 redaka razlike). S2 gradi iz
     migracija bez dodatnog usklađivanja.

## Vrata nakon S1 (2026-11-25, odgovori korisnika)

Pitanja i posljedice su na vrhu [handoffs/S2.md](handoffs/S2.md).

110. **Onchain rail za ulaznice se ukida** (pitanje 1). `ulaznice` nema `confirm_ticket_order`,
     onchain stupce narudžbe ni `events.destination_address`; `create_ticket_order` gubi granu
     `p_payer_address`. `events-confirm` vraća grešku „rail ukinut” (S4), pa onchain plaćanje u
     safe-wallet mobile prestaje raditi. Dvije istekle onchain narudžbe kopiraju se kao povijest:
     `payment_rail='onchain'` dopušten samo uz `state='expired'`.
111. **Rujanske migracije se ugrađuju u `ulaznice`** (pitanje 2). `rotate_ticket_tokens` ide u S3,
     rail gate u `ulaznice.publish_event` u S3b, s pravilom „Stripe Connect aktivan ili samo besplatni
     tierovi”. Na `pinka_finance` se nikad ne primjenjuju; S2 uklanja `20260903120000_events_publish_rail_gate.sql`,
     `20260903120100_events_rotate_ticket_tokens.sql` i njihov test `supabase/tests/20260903_rail_gate_i_rotacija.sql`
     (logiku testa S3/S3b prepisuje na `ulaznice`). Posljedica: do S6 na produkciji ne rade Stripe-only
     objava ni Workerova rotacija QR-a.
112. **Prijelaz deploya u S6 je koordinirani prozor uz zamrzavanje pisanja** (pitanje 4), bez
     kompatibilnih viewova u `pinka_finance`.
113. **Tablice i stupci se preimenuju** po odluci 100 (pitanje 5): `orders`, `ticket_tiers`,
     `order_events`, `event_id`, `order_id`, `buyer_account_id`. RPC-i i HTTP ugovor ostaju isti.

114. **S5 radi ova strana** (pitanje 3): grana od `ivan/main` u `domovina-ulaznice`, PR Ivanu, on
     pregledava i deploya Worker. Backend rad na `events-*` i ticketing migracijama zamrzava se od S2
     do S6. Poruku Ivanu šalje korisnik.

## S2 (2026-11-25)

Commitovi `543ec66` (migracije) i `85f3bad` (test, skripta). Migracije `20261125150000_ulaznice_shema`,
`20261125150100_ulaznice_media_bucket`, `20261125150200_ulaznice_kopija_podataka`.

200. **CHECK-ovi i stupci slijede stvarno stanje `pinka_finance`, ne nacrt §5**, gdje se razlikuju: `currency`
     default `'eur'`, `quantity > 0` default 1 (granicu 1–10 drži RPC), `reserved` default `false`,
     `events.account_id` i `orders.event_id` `on delete cascade`, bez CHECK-a `claimed <= total` na tierovima.
     Svi CHECK-ovi su validni (nova tablica, bez `NOT VALID`).
201. **`orders.payment_rail` nema default** (u `pinka_finance` je `onchain`). `create_ticket_order` u S3 ga
     postavlja sam. CHECK: `onchain` samo uz `state='expired'`; `amount_cents > 0 or payment_rail='free'`.
202. **Mapiranje u kopiji:** 0 € → `free`; `onchain`+`expired` ostaje; `onchain`+`pending` → `stripe`;
     `funded` → `closed`. Kopija **pada glasno** na: ticket kampanju bez `events` retka, `cancelled`,
     narudžbu bez tiera, `failed`, plaćenu/refundiranu onchain narudžbu. Prava uplata ne smije tiho nestati.
203. **`order_events` zadržava izvorne ID-jeve** (`overriding system value`, `on conflict (id)`); sekvence se
     dižu iznad najvećeg ID-a u obje sheme.
204. **Kopija je idempotentna ali ne osvježava** već kopirane retke (`on conflict do nothing`). Završna kopija
     zato mora ići unutar zamrzavanja pisanja u S6 (odluka 112); migracija 150200 to i jest, jer se primjenjuje
     tek u prozoru.
205. **`ulaznice.events_write_guard`** (iz `campaigns_write_guard`, bez Safe dijela): za `authenticated` insert
     forsira skicu i 20 eventa / 24 h, `account_id` nepromjenjiv. Okida se i unutar DEFINER RPC-a
     (`auth.role()` ostaje `authenticated`), što S3b mora uzeti u obzir. Do S3b admin izravno može postaviti
     `state='active'` (nema rail gatea); ništa još ne čita `ulaznice`.
206. **URL-ovi:** `/public/pinka-covers/` → `/public/ulaznice-media/` u `cover_image_url` i svakom `gallery[].url`
     (pokriva `object` i `render/image`); vanjski URL-ovi se ne diraju.
207. **„Anon ne čita X” znači bez granta** (42501), ne samo 0 redaka: `orders`, `tickets`, `order_events`,
     `event_access`, `organizer_*`.
208. **Storage RLS se testira u SQL-u** insertom u `storage.objects` uz rollback.
209. **Probni prolaz nad prod podacima:** `pre-migrate-*` backupi iz `db-migrate.sh` su schema-only, pa je
     S2 povukao read-only dump s podacima (`./scripts/db-dump.sh --schemas pinka_finance --data` →
     `backups/20261125-145048-pinka_finance-full.sql`, 20 `COPY` blokova) i pustio
     `scripts/ulaznice-prod-dump-test.sh <dump>`: lokalni reset na `20261125120000`, `COPY` blokovi uz
     `session_replication_role=replica`, stub `auth.users`/`public.accounts`, tri migracije pa kopija još
     jednom. Rezultat = inventura: events 4, ticket_tiers 6, orders 3 (paid/stripe 1 = 4000; expired/onchain
     2 = 6500), tickets 1, event_access 1, organizer_payment_rails 1, organizer_records 0, organizer_allowlist 0,
     order_events 7; isti ID-jevi; 2 cover + 3 galerija prepisana; `pinka_finance` netaknut. S6 to ponavlja
     sa svježim dumpom neposredno prije prozora.
210. **Rujanske migracije uklonjene** iz `supabase/migrations/` i test iz `supabase/tests/` (odluka 111).
     Izvorni kod za S3/S3b: `git show e77f9ae:supabase/migrations/20260903120000_events_publish_rail_gate.sql`,
     `…120100_events_rotate_ticket_tokens.sql`, `git show e77f9ae:supabase/tests/20260903_rail_gate_i_rotacija.sql`.

## S3 (2026-11-25)

Migracija `20261125160000_ulaznice_rpc_narudzbe.sql`; testovi `20261125_ulaznice_rpc_narudzbe_staro.sql` (218, ponašanje
`pinka_finance`), `20261125_ulaznice_rpc_narudzbe.sql` (246, isti scenariji nad `ulaznice`, svaka razlika označena
`-- RAZLIKA (odluka 30x)`), `20261125_ulaznice_kopija_greske.sql` (9, grane kopije koje padaju, dug iz S2).

300. **`p_payer_address` ostaje u potpisu `create_ticket_order`** (odluka 3), ali ne-null vrijednost baca `onchain_rail_removed`
     (umjesto `invalid_payer_address`). `destination_address` u odgovoru create i `tx_hash` u `deliver_ticket_orders` ostaju
     ključevi s `null`.
301. **`create_ticket_order` sam postavlja rail**: `free` za 0 €, inače `stripe`. Otpadaju `campaign_not_tickets` i
     `tier_not_ticket` (u `ulaznice` je sve ulaznica; donacijski ID daje `campaign_not_found`). Rate limit 10/h samo po
     `buyer_account_id` (bez Safe/payer grane).
302. **`confirm_ticket_order_offchain` s railom `stripe` na narudžbi od 0 € baca `invalid_rail`.** Original je to puštao;
     ovdje bi palo na CHECK `orders_amount_free`.
303. **Ispravljen bug dvostrukog brojanja inventara.** U `pinka_finance` potvrda istekle narudžbe (expired→paid) rezervira
     +quantity u RPC-u (korak 5) i još jednom u `tg_contribution_state`; test starog ponašanja to bilježi (claimed 3→5
     umjesto 4). `ulaznice.tg_order_state` nema tu granu; ponovnu rezervaciju radi samo confirm, uz provjeru kapaciteta.
     Posljedica: izravan `update … set state='paid'` istekle narudžbe kao `service_role` ne rezervira inventar (nitko to ne
     radi). Bug je živ na produkciji do S6; ne popravlja se u `pinka_finance` (odluka 1, S7 ga briše).
304. **Audit događaji zadržavaju imena `contribution.<state>` i ključ `other_contribution_id`** (kopirana povijest ima ista
     imena; Worker/edge ih ne čitaju po imenu). Payload `expired` bez `tx_hash`.
305. **`list_my_tickets` vraća iste ključeve** (`contribution_id`, `campaign_id`, `campaign_title`), odluka 3.
306. **Refund ne piše `campaign_stats`; `void_ticket` i dalje ne vraća inventar** (kao original). Ostala čudna ponašanja
     originala zadržana i označena u testu: refund `voided` 0 pa 1 kod `already_refunded`, idempotentni create vraća
     postojeću narudžbu i uz drukčije parametre, `p_amount_cents` refunda se samo zapisuje.
307. **Advisory lock serijskog broja**: ključ `'ulaznice_tickets_' || event_id`.
308. **`contribution.created` audit piše `create_ticket_order` izravno, ne trigger.** Trigger na insert u `ulaznice.orders`
     trošio je sekvencu `order_events` i sudarao se s kopiranom poviješću (odluka 203). Svaki budući put koji kreira
     narudžbu (S3b nadalje) mora sam upisati taj redak.
309. **Prod podaci imaju nekonzistentan inventar, kopija ga prenosi vjerno** (`scripts/ulaznice-prod-dump-test.sh
     backups/20261125-145048-pinka_finance-full.sql`, pa upit `inventory_claimed` vs `sum(quantity) filter (where reserved)`):
     dvije istekle onchain narudžbe imaju `reserved=true`, tier `9940f…` ima `inventory_claimed=10/10` bez ijedne narudžbe,
     tier `58a12…` claimed 1 uz 1 plaćenu (točno). Migracija to ne normalizira; S6 odlučuje uz svježi dump (pitanje na
     vrhu S6.md).

## S3b (2026-11-25)

Migracija `20261125170000_ulaznice_rpc_eventi.sql` (commitovi `b9bfbad`, `007d65b`); testovi `20261125_ulaznice_rpc_eventi_staro.sql`
(213, ponašanje `pinka_finance`) i `20261125_ulaznice_rpc_eventi.sql` (251, isti scenariji nad `ulaznice`, razlike označene
`-- RAZLIKA (odluka 35x/36x)`, plus scenarij 12 s rail gateom iz `e77f9ae`).

350. **`create_event` je DEFINER s vlastitom provjerom admin računa + `public.is_identity_verified()`**, prije idempotencije. Greška
     ostaje 42501 s RLS porukom, sada `for table "events"` (edge je skraćuje, Worker `api.ts:558` mapira na 403). Rate limit 20/24 h
     (`campaign_rate_limited`) i prisilna skica dolaze samo iz `events_write_guard`. `service_role` preskače admin/KYC i rate limit.
     Ne-admin član koji ponovi postojeći id dobiva 42501 umjesto `existing:true`. Čisti kodovi (`not_authorized`/`kyc_required`)
     su prijedlog za S4/S5, ne mijenjaju se sada (odluka 3).
351. **`p_destination_address` ostaje u potpisu, vrijednost se odbacuje** (odluka 110). Krivi format i dalje `invalid_destination`,
     null je dopušten; `organizer_overview` vraća `destination_address: null`; `campaign_destination_*` greške otpadaju.
352. **Rail gate:** `ulaznice.event_rail_ready(account_id, event_id)` = (`stripe_account_id is not null and stripe_charges_enabled`)
     ili nema tiera s `price_cents > 0` (event bez tierova prolazi). Redoslijed grešaka u `publish_event`: `not_authenticated`,
     `invalid_target_state`, `campaign_not_found`, `not_authorized`, `invalid_state_transition`, `organizer_not_allowlisted`,
     `event_no_working_rail`. `closed` samo iz `active`. `event_rail_ready` izvršava samo `service_role` (original i `authenticated`).
353. **`events_write_guard` za izravni `authenticated` UPDATE u `active` traži allowlistu i rail.** Ispravlja bug originala
     (admin je izravnim PATCH-om objavljivao mimo allowliste). U `publish_event` se iste provjere izvrše dvaput s istim ishodom.
354. **`update_event` dobiva `p_gallery`, `p_attendance_mode`, `p_venue_lat`, `p_venue_lon`, `p_cover_image_alt`** na kraju, default
     null; edge s imenovanim argumentima radi i dalje. Kodovi: `invalid_gallery`, `invalid_gallery_url`, `invalid_attendance_mode`,
     `invalid_location` (par i raspon), `invalid_cover_image_alt`. Koordinate se kroz RPC ne mogu obrisati. Izravni pisovi edgea
     (`events`, `ticket_tiers` skice, `event_access`) i dalje rade kroz S2 RLS; nova politika nije trebala.
355. **Otpadaju `campaign_not_tickets` i `event_not_found`.** `update_event` je DEFINER, zaključava red, provjerava admina, a ne-član
     nad tuđom skicom dobiva `campaign_not_found` kao u originalu (provjera vidljivosti po `events_select`).
356. **`events.description` ostaje** (kopija `description_hr`; nijedan JSON ga ne vraća). Brisanje bi slomilo ponovljenu kopiju 150200;
     kandidat za S7.
357. **Rail gate i nakon objave:** trigger `ulaznice.ticket_tiers_write_guard` (DEFINER, before insert/update/delete). Na eventu koji
     nije skica insert plaćenog tiera ili cijena 0 → >0 bez radnog Stripea baca `event_no_working_rail` (i iz `update_event`).
     Plaćena → druga plaćena cijena ne okida (kopirani aktivni eventi bez Stripea ostaju uredivi). `service_role`/`postgres` zaobilaze.
     Gašenje Stripea nakon objave se ne hvata (pada tek `events-stripe-intent`).
358. **Rate limit se ne zaobilazi brisanjem skice.** Brisanje je meko (`deleted_at`), a DEFINER guard broji sve retke. Bug originala
     (INVOKER guard kroz RLS ne vidi obrisane) zabilježen u testu starog ponašanja.
359. **Izravno brisanje tiera izvan skice odbija se:** `event_not_draft` (isti kod kao edge `removeDraftTiers`), tier s narudžbom
     `tier_has_orders` (umjesto sirovog 23503). Original je dopuštao, pa je narudžba ostajala s `tier_id = null`. Kaskada brisanja eventa prolazi.
360. **`create_event` sanitizira opise** (`description*` i opise tierova) kroz `ulaznice.sanitize_ugc`, kao `update_event`.
361. **Krivi `imenska` daje `invalid_tier_imenska`** (create i update) umjesto 22P02.

Zadržana „čudna” ponašanja originala (označena `-- ČUDNO:` u oba testa): validacija prije provjere prava, termin u prošlosti u
`update_event`, KYC samo kod kreiranja, `javascript:` URL u galeriji kroz izravni pis, `organizer_overview` bez novih polja.
`create_event` nakon brisanja s istim id-em i dalje daje `campaign_exists` (idempotencija gleda `deleted_at is null`).

## S4 (2026-11-25)

Commitovi `708445c` (funkcije, runbook `research/2026-11-25-pgrst-db-schemas.md`) i `ee1416d` (scenarij + `scripts/ulaznice-curl-scenario.sh`).
Provjere: `cd supabase/functions && deno check events-*/index.ts` zelen; `grep -rn pinka_finance supabase/functions/events-*` prazan;
`bash scripts/ulaznice-curl-scenario.sh` 126 `OK —`, „SVE PROVJERE PROŠLE”, dva prolaza zaredom.

400. **`events-confirm` je stub: svaki POST → 410 `{"error":"onchain_rail_removed"}`** (OPTIONS/405 isti). Jedina namjerna promjena HTTP
     ugovora (odluka 110 je ukinula rail); isti kod kao `create_ticket_order` s `p_payer_address`. Funkcija se briše u S7.
401. **`events-organizer`: `gallery` i `attendance_mode` idu kroz `update_event` (`p_gallery`, `p_attendance_mode`)**, ne izravnim pisom u
     `events`. Update je jedan atomaran poziv; create radi drugi poziv `update_event` samo kad su polja poslana. Preostali izravni
     pisovi: `event_access` upsert i brisanje tierova skice (RLS iz S2).
402. **Koordinate i `cover_image_alt` se ne šalju** — HTTP ugovor organizatora ih nikad nije primao, pa problem brisanja koordinata
     (`update_event` koalescira null) ne nastaje.
403. **`removeDraftTiers` zadržava čitanje stanja prije brisanja** (nevidljiv event → `campaign_not_found`, ne tiho 0 redaka; 409 prije pisa).
     `tier_has_orders` iz triggera izlazi kao 400.
404. **`ZERO_ADDRESS` se i dalje šalje kao `p_destination_address`**; RPC ga odbacuje (odluka 351).
405. **`create_event` bez prava ostaje 400 `{"error":"new"…}`** (Worker `api.ts:558` to mapira na 403). Čisti 403 `not_authorized`
     mijenja ugovor; prijedlog za S5 zajedno s Workerom, ne mijenja se u S4 (odluka 3).
406. **`online_url` kupcu i dalje daje samo Worker** (service ključem iz `ulaznice.event_access`); backend ga ne vraća ni u `events-tickets`.
     Revizija: ako mobilna aplikacija treba link bez Workera.
407. **Create s galerijom/`online_url` nije atomaran** (create_event, update_event, upsert `event_access` — tri poziva; kao i prije S4).
     Kandidat: `p_online_url` u `update_event`. Ne radi se sada.
408. **Curl scenarij se izvodi skriptom nad `supabase start` funkcijama**, ne `supabase functions serve` (koji bi zamijenio kontejner
     drugim paralelnim sesijama). Tajna iz gitignored `supabase/functions/.env`, skripta je ne ispisuje. Pravi Stripe API
     (PaymentIntent na Connect računu, webhook, povrat, `account.updated`) je ručni korak za S6 (§11.8 scenarija).

## S5 (2026-11-25)

Commitovi `domovina-ulaznice` grana `feat/ulaznice-shema` (od `ivan/main` @3ca4908): `f5e3a40` (Worker, testovi), `747a7d2`
(deploy-dug #21); draft PR https://github.com/domovinatv/domovina-ulaznice/pull/12. Runbook `2c1d6ae`
(`research/2026-11-25-runbook-prebacivanja.md`). Provjere u worktreeju `../domovina-ulaznice-shema`: `npm test` 147/147,
`npm run test:types` čisto, `cd web && npm run check` 0 grešaka, `git grep -n -E "pinka_finance|pinka-covers" -- worker worker-tests web/src src mobile shared` prazan.

500. **PR ide u `domovinatv/domovina-ulaznice` (base `main`), ne u `IStep95`.** IStep95 je fork bez prava pisanja za nas
     (`gh repo view … viewerPermission` = READ), a svi dosadašnji PR-ovi (#7–#11) su u `domovinatv`. `origin/main` = `ivan/main`
     (3ca4908), pa je grana i dalje „od `ivan/main`” (odluka 114). PR je **draft** s upozorenjem „ne mergeati ni deployati
     prije S6”: staging i produkcija dijele jezgru, pa bi Worker bez `ulaznice` u `PGRST_DB_SCHEMAS` dobivao 406 i na stagingu.
501. **Worker zadržava svoj JSON (`campaign_id`)** prema webu i mobileu; `event_id` iz `ulaznice` mapira se natrag. Web i mobile
     se ne mijenjaju funkcionalno (samo komentari), pa web ne treba deploy u prozoru.
502. **Uklonjen Workerov fallback za jezgru bez `events_free_online`** (deploy-dug #18): `ulaznice` uvijek ima `attendance_mode`
     i `event_access`. Greška jezgre sad daje 502 nakon jednog pokušaja.
503. **Harness `worker-tests` odbija svaki `/rest/v1/` poziv bez profila `ulaznice`** (s `pinka_finance` pada 34 testa).
504. **Odluka 405 ostaje:** `create_event` bez prava i dalje 400 `{"error":"new"…}` → Worker 403 `nema_prava_kreiranja`. Ugovor
     se ne mijenja (ni jedna strana); čisti 403 kandidat je za poslije S7.
505. **Zamrzavanje pisanja u S6 je trigger, ne `revoke`** (zamjenjuje način iz odluke 4 i S5.md). Ticketing RPC-i su
     `security definer` (vlasnik `postgres`), pa ih `revoke` ne zaustavlja, a `campaigns`/`campaign_tiers`/`contributions`/
     `contribution_events` dijele donacije. Trigger na dijeljenim tablicama odbija samo retke kampanja `type='tickets'`;
     jednokratni SQL, ne migracija, pa ga S7 prvo uklanja. Runbook §2.
506. **Pojedinačna migracija na produkciju ide pomoćnom funkcijom `prod_migracija` iz runbooka** (isti obrazac kao `db-migrate.sh`:
     `begin`, datoteka, red u `supabase_migrations.schema_migrations`, `commit`, uz zaštitu od dvostruke primjene), jer
     `db-migrate.sh` nema opciju za jednu migraciju. `--dry-run` mora pokazati točno pet migracija `20261125150000`–`170000`.
507. **Kopija slika `pinka-covers` → `ulaznice-media` kroz Storage API service ključem na hostu**; podrška za
     `destinationBucket` u `/object/copy` (storage-api v1.44.2) nije potvrđena iz repoa, rezerva je preuzmi + upload (runbook §4).

## Vrata prije S6 (2026-11-25, odgovori korisnika)

Pitanja su na vrhu [handoffs/S6.md](handoffs/S6.md).

590. **Prebacivanje produkcije odobreno** (pitanje 1). Termin: kad S6 krene, uz provjeru iz runbooka §0 da nema prodaje u
     tijeku (žive `pending`+`reserved` narudžbe = 0).
591. **Worker deploya ova strana (S6), ne Ivan** (pitanje 2; mijenja dio odluke 114 o deployu). Deploy s grane
     `feat/ulaznice-shema` (worktree `domovina-ulaznice-shema`), `CLOUDFLARE_ACCOUNT_ID` D.O.M.-a, staging pa prod (runbook §9).
     PR #12 ostaje Ivanu na pregled i merge nakon prozora; korisnik mu javlja.
592. **Prod Worker je u `NAJAVA` načinu za vrijeme prozora** (pitanje 3, runbook §2.3); izlazi iz njega prod deployem u §9.
593. **Plaćena narudžba u smoke testu samo na stagingu** (pitanje 4); na produkciji besplatna/Webinar, preuzimanje postojeće
     plaćene ulaznice i donacije.
594. **Inventar se prenosi kako jest** (pitanje 5, odluka 309): bez normalizacije, nema koraka 3.3a.

## S6 — prebacivanje produkcije (2026-11-25)

Dnevnik s vremenima je lokalno u `backups/s6-20261125/dnevnik.txt` (gitignoran); SQL u `research/sql/s6-*.sql`.
Vremena (UTC): T1 backup 16:33 · NAJAVA 16:34 · **T2 zamrzavanje 16:34:38** · migracije 16:34:48–16:35:10 · slike 16:35 ·
PGRST 16:36 · **T6 funkcije 16:37:08** · journal 16:37:56 · staging 16:38 · plaćena test narudžba 16:40 · prod Worker ~16:45.
Kupcima nedostupno ~11 min (NAJAVA 16:34 → prod deploy).

600. **Korisnik potvrdio prozor „kreni sad”** uz posljedicu: prod deploy grane `feat/ulaznice-shema` pušta na produkciju i Ivanove
     stavke deploy-dug #15/#16/#18/#20 (dotad samo staging). Ivan se obavještava da ne deploya dok mu se ne javi (korisnik).
601. **`prod_sql` iz runbooka nije radio:** `detect_db_container` zove `ssh`, koji pojede SQL sa stdina, pa psql dobije prazan
     ulaz i tiho završi s 0. Popravak `C=$(detect_db_container </dev/null)` (runbook, `bc8e106`). Isto vrijedi za svaki
     `ssh_remote` unutar skripte kojoj je stdin SQL.
602. **`PGRST_DB_SCHEMAS` se ne mijenja samo kroz `coolify-env-set.sh`:** Coolify vrijednost renderira u
     `/data/coolify/services/<uuid>/docker-compose.yml` (`environment:` na `supabase-rest` i `supabase-studio`), a `environment`
     ima prednost pred `.env`. Uređen compose na hostu (`sudo sed`, backup `docker-compose.yml.bak-ulaznice-<epoch>`), pa
     `coolify-restart.sh supabase-rest --recreate -y`; isti put kao `vijesti` 11. 11. (`.bak-vijesti-*`). Coolify DB ima novu
     vrijednost (API), pa puni deploy daje isto. `coolify-env-set.sh` bez `-y` na praznom stdinu tiho odustane.
603. **Kopija slika kroz `/object/copy` s `destinationBucket` radi** na storage-api produkcije (odluka 507 potvrđena): 5/5 → 200.
604. **Smoke 10.1 (besplatna narudžba) nije proveden:** na jezgri nema besplatnog objavljenog eventa (seed `…f2` ne postoji na
     produkciji), a stvaranje traži prijavu organizatora. Put besplatne narudžbe pokriven je lokalno (S4 curl scenarij, S5 testovi).
605. **Smoke 10.2 na stagingu:** `POST /api/narudzba` (tier `0b8e2f8f…`, 25 €) → `81627af1-ac5f-4129-bfcf-1b205e8d5b1e`
     `pending` u `ulaznice.orders`; korisnik platio Checkout sandbox karticom (Claude ne upisuje kartice) → webhook →
     `events-stripe-confirm` → `paid`, ulaznica `TES-000003`, audit `created/paid/tickets.issued`, `inventory_claimed` 1→2.
     „Resend”, povrat i `account.updated` nisu ponovljeni u prozoru (pokriveni S4 scenarijem).
606. **Produkcija nakon prozora:** `/`, `/api/dogadjaji` (prazno: test organizator skriven), `/api/zdravlje`, postojeća plaćena
     narudžba `ab2e7543…` (API i stranica) → 200. `/organizator` i `/skener` → 404 iz prod Astro weba (`6b996d75`, 23. 11.),
     koji tih stranica nema; **zatečeno stanje, ne posljedica prozora**, prod web je Ivanov (deploy-dug #6/#15). Pregled
     „Webinar” kod organizatora nije provjeren (traži prijavu korisnika i prod web s `/organizator`).
607. **Predmemorija NAJAVA:** prvih nekoliko minuta nakon prod deploya `/api/*` je vraćao predmemorirani 404 iz NAJAVA
     (`cache-control: max-age=300`); s cache-busterom 200. Za sljedeći put: provjere nakon izlaska iz NAJAVA s `?x=$RANDOM`.
608. **Nakon prozora:** `ops-verify` PASS; otisak `pinka_finance` `6/75/139/4/423840d1…` isti od T2; `sponsor-*` cron `succeeded`;
     jedina nova narudžba u `ulaznice` je staging test (605). Rollback ID-jevi Workera: prod `bdddbaaa` (prije prozora),
     staging `d5f9335f`; novi prod `ced9eb6f`, staging `70b6e87c`. Promatranje do **2026-12-09** (14 dana), vrata prije S7.
