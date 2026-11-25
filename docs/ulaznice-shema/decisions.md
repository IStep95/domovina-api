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
