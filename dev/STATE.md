# sampleTidy — current state

**Read this first on a cold start.** Rewritten, never appended. Last verified
**2026-08-09** against the live database, read-only.

Companion documents, in the order you will want them:

| for | read |
|---|---|
| rules in force today | `dev/plans/OPERATING-RULES.md` (A73+) |
| migrations: what, when, applied? | `dev/MIGRATIONS.md` |
| the frozen build contract (A1–A72) | `dev/plans/CONTRACT.md` |
| design authority | `dev/DESIGN.md` |
| the build itself (all closed) | `dev/plans/PLAN-*.md` — history, not live |

## In one sentence

The package is built and signed off; the registry has been repaired by ten applied
migrations; **the corpus has still not been ingested**, and that is the next milestone.

## Build

Plans 01–16 all closed by 2026-07-28 through Phase 10. Nothing in `dev/plans/` is a
live plan; every file there now carries a `Status:` line saying so. Suite at
**1,286 tests / 6,077 pass / 0 fail / 9 skip** across 52 test files.

Since 2026-07-28 the work has been **operational, not plan-driven**: Robin's rulings,
recorded as A73–A86, and ten migrations repairing the registry ahead of the import.

## Live database

`st_config("live_db")` — a **local** path under `tools::R_user_dir()`, not Sharepoint.
This is correct by design (`DESIGN.md` §9.1): OneDrive does not respect DuckDB's file
lock. Sharepoint receives one-way snapshots; nothing is ever copied back.

    analysis 97,105 · sample 15,144 · analyte 248 · lab_method 570 · project 559
    markers  1..7, 1001, 1003..1010   (all ten migrations applied)
    review_queue  0 rows
    ingest_file   29 rows — 19 quarantined, 10 archived

Project types: 423 `Work order`, 71 `Monthly gas monitoring`, 22 `Dust monitoring`,
12 `Budget line`, 31 NULL.

## The gap that matters

**Almost nothing has been through the pipeline.** `ingest_file` holds 29 rows against a
corpus of ~265 files and 213 ACIRL workbooks. All 97,105 analyses are legacy
pre-package data, loaded before the 2026-07-23 cutover. The migration campaign has been
clearing the runway; the take-off has not happened.

The input queue (`st_config("input_dir")`) currently holds **one example batch of 6
files** — ALS work order ES2425916 (XTAB / ENMRG / COA) plus ACIRL report 2400-7399-08
(xls + pdf) and a scanned monthly PDF. It is not the corpus.

## Standing rules that outlive any one session

- **Never re-ingest a work order already in the DB.** Now enforced in code by
  `.ct_reingest_guard()` (R/commit.R, PLAN-15 F.10) — *this is built*; earlier notes
  saying otherwise are stale. Coverage is **324 of 423** loaded work orders: 99 carry
  no `asset` row, so there is no evidence of a prior ingest to fire on.
- **`remove_ingested` defaults TRUE** — ingested sources are DELETED from `input_dir`
  after the archive copy is re-hashed and matched. Quarantined files are never deleted.
- Migrations, `ensure_schema()` and any other write against the live DB need an
  **explicit instruction**. Read-only inspection is always fine. Copy to `scratchpad/`
  for anything exploratory.
- The Sharepoint tree is **Files-On-Demand**; reading it wholesale silently downloads
  ~1.9 GB. Enumerate with `ls`/`find`, never `grep -r`.
- **A-numbers are decisions; agent numbers are lowercase.** `scratchpad/a79_*.R` is
  *agent* 79 and has nothing to do with *decision* A79. Commit `d9ad9b9` cites an "A87"
  that does not exist — it meant agent 87. Do not write an agent number as `A<n>`.

## Next

1. **Ingest the input batch**, then the corpus. The blocking questions are in the
   session notes: ES2425916 is already loaded, and ACIRL report numbers do not match
   the `project.name` strings already in the DB.
2. **ACIRL gas readings** (requested 2026-08-09). Scoping already measured: gas data
   exists in the DB — 12,656 analyses under `Monthly gas monitoring` projects, analytes
   `CH4` (12,478) and `H2S` (178), no `Methane`/`Carbon dioxide` rows. The
   `2400-7399-*` monthly workbook is **not** the source: its nine sheets are front
   page, four `Sampling Sites` water sheets, dust results/observations and two
   methodology sheets — **no gas sheet**. The gas source has yet to be identified.

## Deliberately not done

Carry-forward reasons are in `dev/tdd-run/8a-FINDINGS.md`. The open ones: whether
`unclaimed`/`failed` routing states stay terminal for a real run (Robin's call — it
changes the R-1.6 state machine); a shared find-by-nullable-key helper; a detector for
already-broken alias arms. F.17 is realised, not hypothetical — the deliverables of
five quarantined work orders are gone from the tree entirely.
