Odvajamo domovina ulaznice iz sheme `pinka_finance` (gdje su izmodelirane kao crowdfunding kampanje) u vlastitu shemu `ulaznice` u Supabaseu na `api.domovina.ai`, uz bucket `ulaznice-media` umjesto `pinka-covers`.

Repo: /Users/ms/git/domovinatv/domovina-api (main, javan, wrap-up pusha main). Frontend: /Users/ms/git/domovinatv/domovina-ulaznice (Ivanov, remote `ivan` = IStep95 fork).

Pročitaj prvo: docs/ulaznice-shema/handoffs/README.md (lanac i pravila), docs/ulaznice-shema/plan.md, docs/ulaznice-shema/decisions.md, docs/ulaznice-shema/TODO.md (F1).

# S3b: RPC-i organizatora i eventa

**Iz S2 (odluke 205, 210):** `ulaznice.events_write_guard` (trigger na `events`) za `authenticated` insert forsira `state='draft'`, ograničenje 20 eventa / 24 h i nepromjenjiv `account_id`; okida se i unutar `security definer` RPC-a jer `auth.role()` ostaje `authenticated`. `create_event`/`publish_event` moraju računati s tim (npr. publish kao update, ne insert). Rate limit nije testiran u S2: dodaj test. Rail gate izvor: `git show e77f9ae:supabase/migrations/20260903120000_events_publish_rail_gate.sql` i rail dio `git show e77f9ae:supabase/tests/20260903_rail_gate_i_rotacija.sql`; do ovog paketa admin izravno može postaviti `state='active'`.

Polazni commit: (upisuje S3). Provjera: (upisuje S3). Odluke od **350**.

Iz S1 (inventura §4.5, §8): skupina B je 6 RPC-a / 630 redaka. `create_event` i `update_event` su danas INVOKER bez `search_path`, a `create_event` zove `pinka_finance.create_campaign` i prolazi `campaigns_write_guard` (KYC, rate limit 20/24 h, prisilni draft, Safe gate). U `ulaznice` to postaje DEFINER sa `search_path=''` i vlastitom provjerom (bez `create_campaign`). `events-organizer` piše `gallery`, `attendance_mode`, `venue_lat/lon`, `cover_image_alt` izravno u tablicu i radi upsert `event_access` mimo RPC-a (`events-organizer/index.ts:74-87`): RLS `events_write`/`event_access_admin` mora to i dalje dopuštati. Rail gate u `publish_event` po odgovoru s vrata nakon S1.

Paket (popis): `create_event`, `update_event`, `publish_event`, `delete_event_draft`, `organizer_overview`, `upsert_organizer_record`, `event_rail_ready`, `events_gallery_valid`, allowlist i payment rails; feed/view za `events-feed`.

1. Port u `ulaznice` po istim pravilima kao S3 (imena, potpisi, JSON, RLS).
2. Testovi: kreiranje skice, uređivanje, galerija, online događaj (`attendance_mode`, `event_access`), objava (rail gate), brisanje skice; organizator bez prava dobiva istu grešku kao danas.

Gotovo kad: testovi „SVE PROVJERE PROŠLE”; `supabase db reset --no-seed` čist; nijedan RPC u `ulaznice` ne piše u `pinka_finance`. Zatim po lancu, `/wrap-up` sa sadržajem `S4.md` (S5 se može voditi paralelno u drugoj sesiji).
