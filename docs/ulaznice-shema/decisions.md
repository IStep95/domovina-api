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
