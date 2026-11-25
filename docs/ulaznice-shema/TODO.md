# TODO — odvajanje ulaznica u shemu `ulaznice`

Radna lista. Čuva se u repou da napredak preživi između sesija. Označene stavke su gotove
i provjerene (zelen „Gotovo kad” iz [plana](plan.md)). Odluke idu u [decisions.md](decisions.md).

Plan po sesijama: [plan.md](plan.md). Handoff po sesiji: [handoffs/](handoffs/).

Legenda: `[x]` gotovo · `[ ]` otvoreno · `[~]` u radu · `(!)` traži korisnika · `→ Sn` planirana sesija

## F0 — Inventura i odluke (ništa se ne mijenja)

- [x] Popis svih objekata u `pinka_finance` koje ticketing koristi: tablice, kolone, ograničenja, trigeri, RLS politike, grantovi, RPC-i, viewovi (`campaign_stats`…), pg_cron poslovi (`expire_stale_ticket_orders`?) → S1
- [x] Popis svih potrošača: 8 funkcija `events-*`, `pinka-*` grane za `type='tickets'`, `domovina-ulaznice` (worker, web, mobile, worker-tests), `safe-wallet-monorepo/apps/mobile/src/custom/events`, `campaign-core`, `crowdfund.domovina.ai` → S1
- [x] Gdje se ID-jevi narudžbi/kampanja zapisuju izvan baze (Stripe metadata, QR, mailovi, D1 u Workeru, linkovi) → S1
- [x] Stanje produkcije naredbom: broj eventa, tiera, narudžbi po railu, ulaznica, objekata u `pinka-covers` po vlasniku → S1
- [x] Tablica mapiranja staro → novo (tablica, kolona, RPC) i popis onoga što ostaje u `pinka_finance` → S1
- [ ] (!) Korisnik odlučio: onchain rail za ulaznice (prenijeti / ukinuti), dvije neprimijenjene migracije iz 9/2026, dogovor s Ivanom o zamrzavanju backend rada na `events-*` → vrata nakon S1 (pitanja na vrhu `handoffs/S2.md`)

## F1 — Nova shema lokalno

- [ ] Migracija: shema `ulaznice`, tablice, ograničenja, trigeri, RLS, grantovi → S2
- [ ] Migracija: bucket `ulaznice-media` s politikama kao `pinka-covers` → S2
- [ ] Migracija: kopija podataka iz `pinka_finance` uz iste UUID-ove (idempotentna) → S2
- [ ] SQL test sheme i kopije (`supabase/tests/`), prolazi nad `supabase db reset` i nad vraćenim prod dumpom → S2
- [ ] RPC-i narudžbi i ulaznica u `ulaznice` s istim potpisima i JSON odgovorima → S3
- [ ] RPC-i organizatora i eventa u `ulaznice` → S3b
- [ ] Postojeći SQL testovi ticketinga prepisani na `ulaznice` → S3, S3b

## F2 — Potrošači lokalno

- [ ] 8 funkcija `events-*` čita i piše `ulaznice`; HTTP ugovor nepromijenjen → S4
- [ ] `docs/events-ticketing-curl-scenario.md` prepisan i prolazi lokalno → S4
- [ ] `domovina-ulaznice` worker i web: `Accept/Content-Profile: ulaznice`, upload u `ulaznice-media`; `npm test` i `web` `npm run check` zeleni → S5
- [ ] Runbook prebacivanja produkcije (`research/`), s rollbackom → S5

## F3 — Produkcija

- [ ] (!) Korisnik odobrio prebacivanje → vrata prije S6
- [ ] Backup, zamrzavanje pisanja u stare tablice, migracije pojedinačno, `PGRST_DB_SCHEMAS` + `ulaznice`, deploy funkcija, ops-verify, journal → S6
- [ ] Worker ulaznica deployan (staging pa prod) i smoke test prošao → S6

## F4 — Čišćenje

- [ ] (!) Korisnik odobrio brisanje starih objekata nakon razdoblja promatranja → vrata prije S7
- [ ] Ticketing objekti uklonjeni iz `pinka_finance`, `campaigns.type` bez `'tickets'` (ako potrošači dopuštaju), dokumentacija osvježena → S7
