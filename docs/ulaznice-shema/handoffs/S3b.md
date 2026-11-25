Odvajamo domovina ulaznice iz sheme `pinka_finance` (gdje su izmodelirane kao crowdfunding kampanje) u vlastitu shemu `ulaznice` u Supabaseu na `api.domovina.ai`, uz bucket `ulaznice-media` umjesto `pinka-covers`.

Repo: /Users/ms/git/domovinatv/domovina-api (main, javan, wrap-up pusha main). Frontend: /Users/ms/git/domovinatv/domovina-ulaznice (Ivanov, remote `ivan` = IStep95 fork).

Pročitaj prvo: docs/ulaznice-shema/handoffs/README.md (lanac i pravila), docs/ulaznice-shema/plan.md, docs/ulaznice-shema/decisions.md, docs/ulaznice-shema/TODO.md (F1).

# S3b: RPC-i organizatora i eventa

Polazni commit: (upisuje S3). Provjera: (upisuje S3). Odluke od **350**.

Paket (popis iz inventure S1; okvirno): `create_event`, `update_event`, `publish_event`, `delete_event_draft`, `organizer_overview`, `upsert_organizer_record`, `event_rail_ready`, `events_gallery_valid`, allowlist i payment rails; feed/view za `events-feed`.

1. Port u `ulaznice` po istim pravilima kao S3 (imena, potpisi, JSON, RLS).
2. Testovi: kreiranje skice, uređivanje, galerija, online događaj (`attendance_mode`, `event_access`), objava (rail gate), brisanje skice; organizator bez prava dobiva istu grešku kao danas.

Gotovo kad: testovi „SVE PROVJERE PROŠLE”; `supabase db reset --no-seed` čist; nijedan RPC u `ulaznice` ne piše u `pinka_finance`. Zatim po lancu, `/wrap-up` sa sadržajem `S4.md` (S5 se može voditi paralelno u drugoj sesiji).
