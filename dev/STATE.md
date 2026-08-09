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

The package is built and signed off, the registry has been repaired by ten applied
migrations, and the first batch has now been ingested for real — but **the corpus has
still not been ingested**, and that is the next milestone.

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

    analysis 97,153 · sample 15,154 · analyte 248 · lab_method 570 · project 560
    markers  1..7, 1001, 1003..1010   (all ten migrations applied)
    review_queue  9 open  (see "The input batch is ingested" below)
    ingest_file   36 rows — 20 quarantined, 14 archived, 1 needs_review, 1 ignored

Project types: 423 `Work order`, 71 `Monthly gas monitoring`, 22 `Dust monitoring`,
12 `Budget line`, 31 NULL.

## The gap that matters

**Almost nothing has been through the pipeline.** `ingest_file` holds 36 rows against a
corpus of ~265 files and 213 ACIRL workbooks. 97,105 of the 97,153 analyses are legacy
pre-package data, loaded before the 2026-07-23 cutover; the pipeline itself has
committed 48. The migration campaign cleared the runway and the first batch has now
flown, but the corpus run has not happened.

## The input batch is ingested (2026-08-09) — the first real pipeline run

The input queue held one example batch of 6 files: ALS work order ES2425916
(XTAB / ENMRG / COA) plus ACIRL report 2400-7399-08 (xls + pdf) and a scanned monthly
PDF. Rehearsed on a sandboxed copy first, then run live. The queue is now empty and
both batch folders were removed by `.ig_remove_spent_folder()`.

    +48 analysis · +10 sample · +1 project · +1 asset · +9 review_queue

The 48 committed rows are **ACIRL field data only** — Appearance 11, pH 9, Temperature
9, EC 9, Stage 7, Standing water level 3. No ALS-copied lab analyte was imported, which
is A75/A79 working as ruled.

**ES2425916 was correctly BLOCKED by the F.10 guard** — it was already loaded (241
analyses, 21 samples, 5 prior ingested files). 202 clean rows and 25 conflicting rows
were all withheld, because F.10 blocks at work-order granularity. The files were still
archived and removed from the input folder, which is F.17 working: the deliverable is
retained even when the data is not committed.

**The 9 open review items — four need a ruling:**

| n | item | needs |
|---|---|---|
| 6 | `value_conflict/measurement` — dust | a ruling: which source wins |
| 1 | `unknown_feature/structural` — `B.EO1` | one alias arm; A78 already covers it |
| 1 | `unknown_feature/self_precedence_note` — `B.S22` | nothing; informational, resolved |
| 1 | `work_order_reingest/blocked` — ES2425916 | nothing; correct refusal |

1. **The six dust conflicts are real disagreements, not arithmetic.** Two gauges × three
   analytes in `Dust Results` rows 11–12. Existing vs incoming: 1.53/0.97, 0.33/0.37,
   1.2/0.6, 0.57/1.09, 0.27/0.39, 0.3/0.7. **Both sides are internally consistent** —
   total = combustible + incombustible holds for the existing triple and the incoming
   triple independently — so neither is a transcription slip. The likeliest cause is
   A77: `Dust Results.Month` and `Dust Observations.EXPOSURE DATE` disagree in 8 of 64
   real gauge-blocks, so this may be one month's gauge compared against another's.
2. **`B.EO1` has no alias.** `B.EO01` exists and auto-assigns; `B.EO1` — the exact
   string in the workbook — does not. A78 ruled the letter-O-for-zero codes are
   misspellings; this member of the family was never enumerated. 5 rows are held.
3. **Project filing is CORRECT — a near-duplicate I reported was my error.** The ingest
   created `2400-7399-08` (type `ACIRL report`) alongside the existing
   `2400-7399-08-01` (type `Monthly gas monitoring`), which looked like the same month
   filed twice. It is not. **The `-01` suffix denotes the GAS report, a physically
   separate workbook** (`2400-7399-08-01 August 2024 Monthly Gas Monitoring Blaxland
   WMF.xls`). `-08` is the water/dust monthly, `-08-01` is the gas monthly. A80 was
   applied correctly and no decision is needed.

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

1. **ACIRL gas readings** (requested 2026-08-09) — scoped below, no blockers found.
2. **The corpus run** — ~265 files, 213 ACIRL workbooks.
3. Rule on the six dust conflicts and add the `B.EO1` alias, then resolve the held rows
   through the PLAN-11 resolve API — no re-ingest needed, and no re-ingest is possible
   anyway now the sources are archived and removed.

## ACIRL gas readings — scoping (measured 2026-08-09, nothing built)

**The source is its own workbook family**, not the monthly water/dust one: 16 `.xls`
and 43 `.pdf` under `assets/unprocessed`, named `… Monthly Gas Monitoring …`, filed
under the `-01`-suffixed report number. Sheets: `Front Page`, `Gas Landfil #1`,
`Gas Landfil #2`, `Gas Buildings`, `MAP`.

Gas data already exists in the DB — **12,656 analyses** under `Monthly gas monitoring`
projects, analytes **`CH4`** (12,478) and **`H2S`** (178). The registry holds no
`Methane` or `Carbon dioxide` analyte; the bare formulae are the canonical names.

Three things the adapter will have to handle, none of which the ACIRL water parser does:

- **Two distinct sheet geometries.** `Gas Landfil #*` is a *wide repeating block* —
  four side-by-side `(Location, CH4 Reading % v/v)` column pairs. `Gas Buildings` is a
  three-column `(Location, Building Reference, CH4 Reading % v/v)` with the `Location`
  cell filled down (blank means "same as above"), so a naive read drops the grouping.
- **Locations are gas probes (`G182`…`G265`), not `B.*` sampling points.** They will
  need their own feature/alias treatment; do not assume the water registry covers them.
- **Float noise in the source** — `0.0299999999999999` appears literally. Rounding must
  be decided rather than inherited, and `0` vs a non-detect is a real distinction here.

Report number lives in a labelled cell (`REPORT NO. :`) on every sheet, so A80 filing
works the same way it does for water. Per [[acirl-work-order-numbering]] it must be read
from that cell, never parsed from the filename.

## Deliberately not done

Carry-forward reasons are in `dev/tdd-run/8a-FINDINGS.md`. The open ones: whether
`unclaimed`/`failed` routing states stay terminal for a real run (Robin's call — it
changes the R-1.6 state machine); a shared find-by-nullable-key helper; a detector for
already-broken alias arms. F.17 is realised, not hypothetical — the deliverables of
five quarantined work orders are gone from the tree entirely.
