# CLAUDE.md — domovina-api

Supabase self-hosted (Coolify) za domovina.* ekosustav. Opći backlog: `docs/TODO.md`.
Deploy i migracije: `docs/deployment-runbook.md`, `docs/migration-testing-playbook.md`, `deploys/INDEX.md`.

## Lanac sesija: odvajanje ulaznica u shemu `ulaznice` (od 2026-11-25)

Plan, odluke i handoffi su u `docs/ulaznice-shema/` (`plan.md`, `decisions.md`, `TODO.md`,
`handoffs/`). „Nastavi ulaznice shemu” znači: otvori prvi neoznačeni red u „Stanje lanca” u
`docs/ulaznice-shema/handoffs/README.md` i kreni iz pripadnog `SN.md`.

**⚠ Migracije `20261125150000`–`20261125160000` (`ulaznice`, i svaka sljedeća iz lanca) ne smiju na produkciju prije S6 lanca.**
`db-migrate.sh` bi ih povukao: uvijek `--dry-run`, pa ostale migracije pojedinačno.
