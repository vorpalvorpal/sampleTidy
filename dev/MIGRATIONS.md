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

Verified 2026-08-09 against the live file, read-only; 011/012 rows added 2026-10-16.

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
| 1011 | `011-delete-lmf.R` | Robin, 2026-10-16 | **PENDING** (rehearsed clean; held for Robin's OK on deleting the 4 LSI `guideline` rows) |
| 1012 | `012-detection-limits.R` | Robin, 2026-10-16 | 2026-10-16 |

**001-010 and 012 are applied.** 011 is pending: it deletes the derived LMF analyte,
its method and 2,267 analyses, and also (FK-forced) its 4 `Leachate Signature Index`
`guideline` rows and 1 `analyte_mask` row. Its row backups are written to
`dev/migrations/011-delete-lmf-BACKUP-<table>.csv` when it runs. 012 sets `rl_low` on
H2S (1e-6, 61 rows), CH4 (1e-4, 11,536 rows; method already had it) and
dust-combustible (0.1, 4 rows) non-detects; `rl_high` untouched (A57); dust-incombustible
deliberately not touched (awaiting ruling). 012 pre-backup:
`monitoring_pre-012-detection-limits_20261016T055834.611Z.duckdb`.

## Ordering constraints (enforced in code, not by memory)

    004 ──requires 1001
    005 ──requires 1004
    007 ──requires 1005
    006 ──requires 1007        (and refuses if 1005 is absent)
    003, 008, 009, 010, 011, 012 ── independent

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

Plans 13 and 14 own migrations 001 and 002. **003–012 belong to no plan** — they were
authorised by rulings and A-numbers recorded in `dev/plans/OPERATING-RULES.md`. That is
deliberate as of 2026-08-09: the plan-driven build closed 2026-07-28, and migrations are
now operational work. The `authorised by` column above is the substitute for plan
ownership, and it is the thing to keep current.
