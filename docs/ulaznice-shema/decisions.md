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
