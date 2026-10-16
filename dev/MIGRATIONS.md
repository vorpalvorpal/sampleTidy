# Migration register

Every operator migration, its marker, what authorised it, and whether it has been
applied to the live database. **This file is the answer to "has 006 been applied?"** —
previously that fact was spread across ten file headers, a scratchpad checkpoint and
`schema_version`, and the three disagreed.

Migrations are **operator-run**: never invoked by package code, `sys.source()`d into a
fresh environment with the package loaded via `pkgload::load_all(".")`. Each takes its
own verified backup to `st_config("snapshot_dir")` before writing.

Live database: `st_config("live_db")` =
`/Users/rjs/Library/Application Support/org.R-project.R/R/sampleTidy/monitoring.duckdb`.
Sharepoint is a **snapshot destination only** — nothing is ever copied back.

## State of the live database

Verified 2026-08-09 against the live file, read-only; 011-016 rows added 2026-10-16; 016 applied and 017 added 2026-10-17.

| marker | migration | authorised by | applied |
|---|---|---|---|
| 1–7 | `ensure_schema()` ops tables (not a migration) | A2 | 2026-07-23 / 2026-07-26 |
| 1001 | `001-alias-indirection.R` | PLAN-13 | 2026-07-23 |
| *(none)* | `002-registry-remediation.R` | PLAN-14 | 2026-07-23 |
| 1003 | `003-alias-date-bounds.R` | PLAN-15 | 2026-08-08 |
| 1004 | `004-view-repair.R` | PLAN-15 R-15.35 | 2026-08-02 |
| 1005 | `005-preference-rank.R` | A82 | 2026-08-08 |
| 1006 | `006-acirl-transcription-methods.R` | A83 | 2026-08-08 |
| 1007 | `007-registry-rulings.R` | rulings 2026-08-08 | 2026-08-08 |
| 1008 | `008-duplicate-samples.R` | ruling 9, 2026-08-08 | 2026-08-08 |
| 1009 | `009-sample-identity-index.R` | A84 | 2026-08-08 |
| 1010 | `010-aroclor-mixture-names.R` | rulings 2026-08-08 | 2026-08-09 |
| 1011 | `011-delete-lmf.R` | Robin, 2026-10-16 (incl. the LSI mask + 4 guideline rows) | 2026-10-16 |
| 1012 | `012-detection-limits.R` | Robin, 2026-10-16 | 2026-10-16 |
| 1013 | `013-dust-incombustible-upper-bound.R` | Robin, 2026-10-16 | 2026-10-16 |
| 1014 | `014-gas-registry-additions.R` | Robin, 2026-10-16 | 2026-10-16 |
| 1015 | `015-redate-legacy-dust.R` | Robin, 2026-10-16 (dust exposure/collection ruling) | 2026-10-16 |
| 1016 | `016-redate-legacy-dust-2021-22.R` | Robin, 2026-10-16 ("workbook wins; re-date"); applied per ruling 1, 2026-10-17 | 2026-10-17 |
| 1017 | `017-legacy-dust-load-a-exposure-start.R` | Robin, 2026-10-17 (ruling 2) | 2026-10-17 |

**001-017 are all applied.** 011 deleted the derived LMF analyte, its method and 2,267
analyses, plus (FK-forced, Robin approved) its 4 `Leachate Signature Index` `guideline`
rows and 1 `analyte_mask` row; row backups are `dev/migrations/011-delete-lmf-BACKUP-<table>.csv`.
012 sets `rl_low` on H2S (1e-6, 61 rows), CH4 (1e-4, 11,536 rows) and dust-combustible
(0.1, 4 rows) non-detects; `rl_high` untouched (A57). 013 re-marks the 4 dust-incombustible
rows whose sample has a non-detect dust-combustible as `<dust-total` (quantified FALSE,
value = rl_low = total; old values in `013-...-BACKUP-analysis.csv`); after it, 012's
"incombustible untouched" check is skipped once marker 1013 exists. 014 adds 33 gas
features (B.TG385-405 weekly points; K.G367-378 unlocated biofilter points at `K.centroid`),
their self aliases, `B.Weekly n` / `K.Biofilter ...` / `K.Front of Buildings ...` aliases,
and `B.G179-181` -> B.TG179-181 aliases (bare `G179-181` are mask_long aliases of K.G179-181).
015 re-dates the 4 "+1 day" 2024 dust collections (`date` 2 May -> 1 May, 2 Jul -> 1 Jul), dates the
2 undated July-2024 legacy samples (96c5e696 B.D07, e732697d B.D08: exposure 2024-07-01, collection
2024-08-01), writes the period of their 4 "Dust monitoring" child projects, re-points the 2 July
`Appearance` analyses that the 2026-08-09 ingest of 2400-7399-08 put on the June samples, and closes
that ingest's 6 dust `value_conflict` review items via `resolve_review()`. `datetime` and `uuid_project`
are never written (009's unique index; duckdb runs an indexed UPDATE as delete+insert, which the
analysis FK refuses). Row backups `015-redate-legacy-dust-BACKUP-{sample,project,analysis}.csv`.
016 repairs the 2021-22 "load B" dust block: 22 B.D07/B.D08 re-dates to exposure/collection (16 with no
workbook, placed by the load-B rule and flagged in its header), deletes the 2 copy samples bb955fc9 and
bcf15e0f with their 6 analyses, and sets 6 values to the 2 dp workbook (2400-7222-01-02). Row backups
`016-redate-legacy-dust-2021-22-BACKUP-{sample,analysis}.csv`. 017 sets `date_start` = collection - 1
month on the 22 "load A" legacy dust rows (collected 2020-09..2021-01 and 2021-04..2021-09, both gauges);
every one has a workbook (Dust Results Database, 2400-7127-06, 2400-7127-07) confirming `date` is the
collection date, so `date` is untouched. It EXCLUDES the 2021-02-01 and 2021-03-01 rows (0763faf8,
8c8aef7a, 4735d1dd, 20fda4f9), which hold the Jan/Feb-2020 measurements a year out - open, awaiting a
ruling. Row backup `017-legacy-dust-load-a-exposure-start-BACKUP-sample.csv`. Neither writes `datetime`
or `datetime_start`.
Pre-migration snapshots are in `snapshot_dir` (`monitoring_pre-<name>_<ts>.duckdb`).

## Ordering constraints (enforced in code, not by memory)

    004 ──requires 1001
    005 ──requires 1004
    007 ──requires 1005
    006 ──requires 1007        (and refuses if 1005 is absent)
    016 ──requires 1015
    017 ──requires 1016
    003, 008, 009, 010, 011, 012, 013, 014, 015 ── independent

Each dependent migration checks its predecessor's marker and refuses without it, so
the order is verified rather than remembered. 006 gained its 1007 dependency because
three of its rows cannot exist until 007 runs: two link to analytes 007 creates, and
`Total Dissolved Solids` stays blocked by 006's own collision gate until 007 deletes
the ACIRL `field` method.

## Two traps recorded here because they are invisible from the filenames

**1. `002` MUST NEVER BE RUN AFTER `006`.** 002 writes no marker, so nothing stops a
re-run — and a re-run after 006 rewrites 15 fields, including nulling
`lab_method.conversion_constant` (`0.304466905771112 → NA`) on **both** `Nitrite as NO2`
methods. Found only because a rehearsal deliberately re-ran everything. 002 is applied
and must now be treated as spent. The same marker-less design means a fresh database
rebuilt from these migrations needs 002 run in sequence, before 006.

**2. The number `006` was re-used.** `006-review-queue-payload.R` (PLAN-16) held it,
was retired at `bc3d146` when its rows ceased to exist, and the number was then taken
by `006-acirl-transcription-methods.R` at `8135c36`. The live DB's 1006 is the ACIRL
one (`change_log` actor `006-acirl-transcription-methods`, 212 rows). **Any database
that received the old 006 would silently skip the new one** — it would already carry
marker 1006. Nothing in the tree records this except git history and this file. Do not
re-use a retired migration number again.

## Migrations are not covered by any plan

Plans 13 and 14 own migrations 001 and 002. **003–017 belong to no plan** — they were
authorised by rulings and A-numbers recorded in `dev/plans/OPERATING-RULES.md`. That is
deliberate as of 2026-08-09: the plan-driven build closed 2026-07-28, and migrations are
now operational work. The `authorised by` column above is the substitute for plan
ownership, and it is the thing to keep current.
