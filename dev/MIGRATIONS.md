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

Verified 2026-08-09 against the live file, read-only; 011-016 rows added 2026-10-16; 016 applied and 017 added 2026-10-17; 018-022 applied 2026-10-17; 024 applied 2026-10-17.

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
| 1018 | `018-legacy-dust-year-out-2020.R` | Robin, 2026-10-17 | 2026-10-17 |
| 1019 | `019-legacy-dust-load-a-2dp.R` | Robin, 2026-10-17 | 2026-10-17 |
| 1020 | `020-import-dust-2019-20.R` | Robin, 2026-10-17 | 2026-10-17 |
| 1021 | `021-dust-datetime.R` | Robin, 2026-10-17 | 2026-10-17 |
| 1022 | `022-view-date-coalesce.R` | Robin, 2026-10-17 | 2026-10-17 |
| 1023 | `023-registry-fingerprint.R` | Robin, 2026-10-17 (R-3.8 / A90) | **NOT APPLIED** |
| 1024 | `024-merge-aug24-water-duplicates.R` | Robin, 2026-10-17 (rulings 1-5) | 2026-10-17 |

**001-022 and 024 are applied; 023 is written and rehearsed but NOT APPLIED.** 011 deleted the derived LMF analyte, its method and 2,267
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
018 re-dates those 4 year-out samples to exposure 2020-01-01 / 2020-02-01, collection 2020-02-01 /
2020-03-01 (Dust Results Database, 2400-6989), and sets 8c8aef7a dust-total 13.1 -> 13.06 (the only value
that differed from the workbook). The real Jan-2021 and Feb-2021 exposures are in no file found, so both
gauges have a gap there. `datetime`/`datetime_start` stay 2021-02/-03 as loaded. Row backups
`018-legacy-dust-year-out-2020-BACKUP-{sample,analysis}.csv`. 019 replaces 16 load-A values with the Dust
Results Database's 2 dp figures (the 10 samples collected 2020-09..2021-01; every one of the 30 workbook
values rounds to the stored 1 dp value, none shows `<`; incombustible is 1 dp in the workbook, so none
moves). The 12 load-A samples collected 2021-04..09 have only the 1 dp pdfs and are untouched. Row backup
`019-legacy-dust-load-a-2dp-BACKUP-analysis.csv`. 020 inserts the 22 missing Jul-2019..Jul-2020 exposures
(22 samples, 66 analyses; fixed uuids) mirroring the load-A rows from the same workbook: self aliases,
the ROOT "Dust monitoring" project 230bd429 (not a child project - those carry only the 2022-08+ per-report
rows), organisation/person NULL, Sydney-midnight `date_start`/`date`, `datetime` = `datetime_start` =
collection 11:00 Sydney, Observations text in `analysis.comments`, sample comment "imported 2026-10-17 from
Dust Results Database workbook, migration 020". B.D07 Jul-2019 combustible `<0.1` is stored per 012 and its
incombustible as the 013 `<dust-total` bound (0.64; printed 0.6). Not imported: Days Exposed and the mg
mass columns. Inserted rows dumped to `020-import-dust-2019-20-INSERTED-{sample,analysis}.csv`.
021 ends the "datetime stays as loaded" caveat of 015-020: for all 122 dust samples (61 B.D07, 61 B.D08,
incl. 018's 4 and 020's 22) it sets `datetime` = `date` and `datetime_start` = `date_start`, byte-for-byte
(Sydney midnight held as the UTC instant). Before it, all 122 differed exactly, 116 on the Sydney day, 2 had
NULL `datetime`, and 9 dust rows ranked 2 in `v_measurement`; after it, 0. 009's `ux_sample_identity` blocks
the UPDATE, so 021 drops it (own commit), updates in one transaction (244 `change_log` rows via `db_update`,
actor `021-dust-datetime`), and re-creates it with the exact `duckdb_indexes()` definition inside a
tryCatch/finally that re-creates it on any failure (tested by forcing a mid-transaction abort). A
precondition proves the post-update key set is unique; the index was re-proved to reject a duplicate. Row
backup `021-dust-datetime-BACKUP-sample.csv`.
022 redefines the 5 `v_measurement*` views (the only views whose SQL mentions `datetime`) so that the `date`
column and the `preference_rank` partition use `COALESCE(s.datetime, s.date)`: exactly 2 text substitutions
per view in the `duckdb_views()` SQL, everything else byte-identical, re-read SQL checked equal to the plan.
The `s.datetime AS datetime` output column is deliberately unchanged. After it no view row has a NULL `date`.
Old definitions in `022-view-date-coalesce-BACKUP-views.csv`. Measured effect (021+022 vs before, on
`v_measurement`; `_long` identical, `_epa` 433/133/47, `_gas_report` and `_old` unchanged): 451 rows changed -
372 dust rows (own date/datetime), 46 rows of the 10 pipeline-ingested 2024-08-07 Blaxland water samples that
have NULL `datetime` (now dated), and 33 rank-only changes on non-NULL-datetime water rows in the same
2024-08-07 partitions (those 10 samples duplicate the field readings of that visit; they now compete in the
ranking, winning on field-beats-lab or on the uuid tiebreak). `dev/epa-monitoring-report.R` reads base
tables, not the views: its 2023-24, 2024-25 and 2025-26 Katoomba workbooks are value-identical before/after.
023 adds the nullable `ingest_file.registry_fingerprint` (also ops-schema version 8 in
`ensure_schema()`), no backfill: every existing row is NULL and its registry verdict is re-decided
once on the next route (A90). Rehearsed twice on a copy of live (dry run, migrate, re-run = no-op);
a dry-run route against the migrated copy succeeds.
024 merges the 10 duplicate 2024-08-07 Blaxland water samples (B.MW02/08/09, S01/03/05/06/10/22, E01 via
alias B.EO1; NULL `datetime`, project ES2425916) that the 2026-08-09 ingest of 2400-7399-08 created beside
their legacy twins: 28 pure-duplicate analyses deleted, 13 new ones (field EC x9, Stage x4) re-pointed onto the
twins, and for the 5 Appearance conflicts (S01/S03 "Low flow clear", S05 "Mod Level Clear", S22 "cloudy", E01
"Slightly Cloudy") the pipeline's A76-split value re-pointed onto the twin and the legacy row deleted; then the
10 emptied samples deleted in a separately committed step. It also merges ACIRL lab_method 45a8fbd1 "Standing
water level" into 68484c79 "Standing Water Level" (3 2023-10-10 analyses moved by delete + same-uuid re-insert,
because duckdb 1.4.1 keeps a stale FK index key after per-row deletes/updates of `analysis.uuid_lab` and then
refuses the lab_method delete; the 6 rows go in one set-based DELETE). B.EO1 alias, projects and assets kept.
After it a dry-run re-ingest of the archived workbook (its `ingest_file` row removed, copy only) yields 0 new
rows. Row backups `024-merge-aug24-water-duplicates-BACKUP-{analysis,sample,lab_method}.csv`.
Pre-migration snapshots are in `snapshot_dir` (`monitoring_pre-<name>_<ts>.duckdb`).

## Ordering constraints (enforced in code, not by memory)

    004 ──requires 1001
    005 ──requires 1004
    007 ──requires 1005
    006 ──requires 1007        (and refuses if 1005 is absent)
    016 ──requires 1015
    017 ──requires 1016
    018 ──requires 1017
    019 ──requires 1018
    020 ──requires 1019
    021 ──requires 1020
    022 ──requires 1005, 1021
    023 ──independent
    024 ──requires 1022
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

Plans 13 and 14 own migrations 001 and 002. **003–022 belong to no plan** — they were
authorised by rulings and A-numbers recorded in `dev/plans/OPERATING-RULES.md`. That is
deliberate as of 2026-08-09: the plan-driven build closed 2026-07-28, and migrations are
now operational work. The `authorised by` column above is the substitute for plan
ownership, and it is the thing to keep current.
