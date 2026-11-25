# Handoffi — odvajanje ulaznica (S1–S7)

Plan je u [../plan.md](../plan.md). Svaka sesija ima svoj handoff `SN.md`, koji je gotov prompt
za prazan session. Korisnik nakon `/clear` kaže „nastavi ulaznice shemu” ili zalijepi prompt
iz clipboarda; to znači prvi otvoreni red u „Stanje lanca”.

## Lanac

1. Sesija N počinje iz `docs/ulaznice-shema/handoffs/SN.md`.
2. Sesija N radi svoj paket po pravilima ispod.
3. Na kraju sesija N:
   - označi `SN` kao gotov u „Stanje lanca” (commit, testovi, kratka napomena) i stavke u
     [../TODO.md](../TODO.md);
   - **ako je naučila nešto što mijenja sljedeće pakete, uredi `S(N+1).md`** (po potrebi i
     kasnije handoffe i plan). Nedovršeni dio paketa N ide na **vrh** `S(N+1).md`;
   - u `S(N+1).md` upiše polazni commit i brojke;
   - pozove `/wrap-up`. Handoff prompt je **sadržaj `S(N+1).md`**.
4. Ako sesija ostane bez konteksta usred paketa, nastavak je opet `SN` s popisom ostatka na
   vrhu datoteke. Broj se ne povećava.
5. **Vrata** (nakon S1, prije S6, prije S7): pitanje je upisano na vrh sljedećeg handoffa.
   Lanac staje dok korisnik ne odgovori; odgovor ide u [../decisions.md](../decisions.md).
6. Handoff se mijenja samo prema naprijed: gotovi `SN` se ne prepisuju.

## Stanje lanca

| Sesija | Paket | Stanje | Commit | Testovi | Napomena |
| --- | --- | --- | --- | --- | --- |
| S0 | Plan | gotovo | 3b60081 | — | odluke 1–9 |
| S1 | Inventura i mapiranje | gotovo | bea1684 | `db reset` ✓; katalog lokalno = prod osim 2 migracije | odluke 100–107; pitanja na vrhu S2.md |
| S2 | Shema, bucket, kopija podataka | gotovo | 543ec66, 85f3bad | `db reset` ✓; `20261125_ulaznice_shema.sql` 45 OK ×2; prod dump 25. 11. = inventura | odluke 200–210 |
| S3 | RPC-i narudžbi i ulaznica | otvoreno | | | |
| S3b | RPC-i organizatora i eventa | | | | |
| S4 | Edge funkcije | | | | paralelno sa S5 |
| S5 | domovina-ulaznice + runbook | | | | paralelno sa S4; iza S5 vrata |
| S6 | Prebacivanje produkcije | čeka vrata | | | |
| S7 | Brisanje starog | čeka vrata | | | |

## Zajednička pravila (vrijede u svakoj sesiji)

- **Polazak:** `git fetch` i `git log origin/main..HEAD` / `HEAD..origin/main` (Ivan i druge
  sesije mergeaju u isti repo); `ls -lt ~/.claude/projects/-Users-ms-git-domovinatv-domovina-api/*.jsonl | head -3`
  za paralelne sesije. Lokalni stack: `scripts/dev-local.sh restart`, pa `supabase db reset --no-seed`
  mora proći. Ako ne prolazi, prvo to popravi.
- **Opseg:** smije se dirati `supabase/migrations/` (samo nove datoteke), `supabase/tests/`,
  `supabase/functions/events-*`, `supabase/config.toml`, `docs/ulaznice-shema/`. Pinka funkcije
  (`pinka-*`) i donacijske migracije samo u S7. `domovina-ulaznice` samo u S5/S6, na grani od
  `ivan/main`.
- **Produkcija:** samo S6 i S7, tek nakon vrata. Čitanje produkcije (read-only, `begin read only; … rollback;`)
  smije svaka sesija, obrascem SQL u datoteku → `cat file | ssh_remote "docker exec -i $C psql …"`
  (`. scripts/lib/db-env.sh` unutar `bash -c`, vidi `docs/migration-testing-playbook.md`).
  `db-migrate.sh` se nikad ne pokreće bez `--dry-run`.
- **Orkestracija:** posao rade Opus 5.5 subagenti, glavna sesija orkestrira. Paket razbij na
  (a) implementaciju i (b) testove i spajanje. `effort` uvijek eksplicitno: `high` za kod,
  `medium` za čitanje. Najviše 2–3 agenta paralelno. Fable samo kad korisnik to izričito traži.
- **Agentima zabrani** `TODO.md`, `plan.md`, `decisions.md` i handoffe; orkestrator ih ažurira.
- **Testovi:** bez mreže prema produkciji; SQL test ispisuje `OK —` po provjeri i
  „SVE PROVJERE PROŠLE”; ništa preskočeno. Migracija prolazi i nad vraćenim prod dumpom
  (`docs/migration-testing-playbook.md`).
- **Trošak:** prije posla s više od ~100 poziva procjena korisniku; nikad `claude -p` petlja.
- **Brojke** uvijek s naredbom kojom su dobivene.
- **Autonomno:** odluči sam i zapiši odluku u svom bloku brojeva; commitaj svaki zeleni korak
  na `main` (samo imenovane datoteke, nikad `git add -A`). Nepovratno i vanjsko (produkcija,
  Coolify env, deploy Workera, poruka Ivanu) ostavi korisniku.
- **Token budget:** bez Monitora za napredak; duge jobove `run_in_background` i javi se na kraju.
  Oko 150k konteksta zatvori sesiju po koraku 3.
- **Istraživanja** u `docs/ulaznice-shema/research/YYYY-MM-DD-*.md`.
- **Commit trailer** po pravilima sesije (Co-Authored-By + Claude-Session).
- **Tajne** se nikad ne upisuju u repo ni u memoriju (repo je javan).
