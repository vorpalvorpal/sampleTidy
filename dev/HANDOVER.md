# sampleTidy — build handover

_Last updated: 2026-07-15. Branch: `tdd-mvp-implementation` (pushed to `origin`)._

## What we're building

**sampleTidy** ingests environmental-monitoring lab data — ALS **ESdat** EDD
files, ALS **crosstab** exports (XTAB/ENMRG), and human-edited **ACIRL** field
workbooks — into an existing DuckDB monitoring database (`monitoring.duckdb`:
`feature`/`analyte`/`sample`/`analysis`/… ~95k analyses). The public entry point
is `ingest_dir(path, db, dry_run)`: hash-track files → route to a format adapter
→ parse to a common IR → assemble per-work-order events → reconcile against the
live DB (new / already-present / conflict / review) → commit atomically with a
`change_log` audit trail and file archival. Design authority: `dev/DESIGN.md`
(= GitHub issue #1 v2).

## How we're building it — the TDD-plan workflow

Using `.claude/skills/tdd-plan`: collaborative design → explicit per-plan specs
with correctness criteria → a full failing test suite written **before** code →
cheap models implement, expensive models audit/adjudicate. Key artifacts in
`dev/plans/`:

| file | role |
|---|---|
| `CONTRACT.md` | **single source of truth**: pinned APIs, file-ownership partition, conventions, and the **adjudication log (A1–A37)**. Read this + your own plan, not the whole corpus. |
| `PLAN-0N-*.md` | per-plan specs with correctness criteria |
| `PARKED-QUESTIONS.md` | questions raised for Robin — **all resolved** (see below) |
| `PLAN-CHANGE-REQUESTS.md` | append-only ambiguity log from the test-writing phase |
| `FIXTURES.md` | the synthetic fixture spec (now largely superseded by real fixtures) |
| `COVERAGE-MAP.md` | criterion → test map |

Tests: `tests/testthat/test-<module>.R`, one per `R/` file. Fixtures in
`tests/testthat/fixtures/<adapter>/`.

## Where we're up to

**Plans 01–09 are DONE and green. Only plan 10 remains (TDD-red).**

| plan | module(s) | status |
|---|---|---|
| 01 | config, db-connect, db-schema, hash | ✅ green |
| 02 | text-normalise, units, values, dates, spreadsheet-tools | ✅ green |
| 03 | ir, adapter-registry, file-meta, router | ✅ green |
| 04 | **adapter-esdat** | ✅ green — **reworked** for real files (latin-1) |
| 05 | **adapter-crosstab** (als_xtab/als_enmrg) | ✅ green — **reworked** for real layout |
| 06 | adapter-acirl-field | ✅ green |
| 07 | assemble | ✅ green |
| 08 | reconcile | ✅ green |
| 09 | mutate, commit, archive, snapshot, ingest | ✅ green |
| 10 | e2e-pipeline, e2e-corpus | 🔴 not started |

Full suite: **298 tests green across plans 01–09** (0 fail/0 error). The only
red file is `test-e2e-pipeline.R` (plan 10, 22F/8E) — and those failures are all
the **same A41/A43 `withr` frame bug in plan 10's own `e2e_setup()` helper**
(`cannot open '.../seed.duckdb'`), NOT missing code: plan 09 already shipped the
production functions plan 10's e2e tests exercise. `test-e2e-corpus.R` is
green-by-skip (needs `SAMPLETIDY_CORPUS`). `ingest_dir()` was independently
validated end-to-end over the full fixture corpus by direct probe (see A43).

Recent commits: `6b3ccc0` (plan 07 assemble) → `d21c386` (plan 08 reconcile) →
`d2e510e` (plan 09 mutate) → `+3` (plan 09 archive/snapshot, commit, ingest).

## The big arc of this session

Robin pointed us at the **real** lab corpus. That immediately exposed that
**the synthetic fixtures mis-modelled reality** — two "green" adapters could not
parse real files:

1. **ESdat (04):** real Chemistry2e/Sample2e CSVs are **latin-1** (byte `0xB0`=`°`,
   `0xB5`=`µ`); the adapter read them as UTF-8 and aborted in
   `normalise_lab_text()`'s `gsub()`. Fixed: read with a latin-1 locale.
2. **Crosstab (05):** the WIP parser inspected only column 0 and matched a bare
   `^Analyte$`; real files put per-sample metadata at col 3 (XTAB) / 4 (ENMRG),
   multiple labels per row, and the analyte header is the combined
   `Analyte grouping/Analyte`. Rewrote the row-walk to the real layout.
3. **Crosstab `.XLS`:** real XTAB "XLS" files are **SpreadsheetML XML**, not
   binary — `readxl` can't read them. **Parked** for MVP (A37).

**Decision (Robin): commit anonymized real files as the primary fixtures** —
the data is EPA-required-public, so this overrides A3. Anonymization is
byte-level (ASCII identifiers only) so latin-1 bytes survive; only
sampling-point codes and place/person names change, all analytical data is
byte-identical. Map + provenance: `tests/testthat/fixtures/REAL-FIXTURES.md`.
Real corpus lives at
`…/OneDrive-…/waste_data - Environmental monitoring/assets/input`
(and Robin's curated `…/assets/input/sampleTidy example`).

Both reworks were **validated against the whole real corpus**, not just tests:
94/94 real ESdat CSVs parse; all 4 real XTAB + 9 real ENMRG parse with 0 NA
analytes and matching cross-format counts. (This directly caught a bad worker
patch — a raw quote-parity guard that would have wrongly failed a valid real
file — which was replaced with an encoding-safe corruption check.)

## Parked questions — all resolved

1. **Crosstab layout** → `Analyte grouping/Analyte` is ONE column in both
   dialects (grouping is by method-group rows). Resolved from real files.
2. **QC types** → real Sample2e carry all five (LAB_D/LCS/MB/MS/NCP); `MS`
   confirmed present. Fixture covers them.
3. **Write-API `con`** → keep the split (A16): `add_feature/analyte/project` +
   `correct_value` self-resolve `st_config("live_db")`; `db_append/update/delete`
   take explicit `con`.
4. **Assembly→review seam** → inline flags on `event$results` (A22).

Adjudications across the build: **A29 (resolved), A34** (crosstab real layout),
**A35** (ESdat latin-1 + CORRUPT), **A36** (QC types), **A37** (SpreadsheetML
parked). Plan 08–09 build: **A38** (`seed_db()` withr default-arg), **A39**
(reconcile fixture feature_raw), **A40** (`db_transaction` hook + `"at"` quoting),
**A41** (the plan-09 setup helpers re-triggered A38 one frame removed), **A42**
(test-commit.R `ORDER BY "at"`), **A43** (test-ingest NA-safe filtering + the
`build_e2e_input_dir` withr bug). See `CONTRACT.md`.

## Loose ends / next steps

**To resume the build — only plan 10 remains:**
- **Plan 10 — e2e** (`test-e2e-pipeline.R` R-10.1..R-10.6; `test-e2e-corpus.R`
  R-10.5). The production chain it exercises (router→adapters→assemble→reconcile→
  commit→ingest) is all built and green. **Fix its harness first**: `e2e_setup()`
  in `test-e2e-pipeline.R` carries the *same* A41/A43 `withr` default-arg /
  frame-lifetime bug (every failure is `cannot open '.../seed.duckdb'`); apply the
  `parent.frame()` / `.local_envir` fix before assuming any real e2e defect.
- **Recreate the plan-10 rev-1 fixture** `XX1234567_1_XTAB.csv` (dropped in the
  crosstab regen) for the R-10.4 revision-supersede e2e.
- Green ≠ correct on real data — **validate against the real corpus** (set
  `SAMPLETIDY_CORPUS`, wire `test-e2e-corpus.R`), not only synthetic fixtures.

**Plan-09 follow-ups worth a look:**
- **`dry_run` persists `ingest_file` state transitions** (ops-table only — the
  tested "zero core writes" holds). Harmless for MVP, but a `dry_run` followed by
  a real run would find files already past `seen`, so `route_files` no-ops them
  and the real run does nothing. Consider making `dry_run` non-persistent (or
  `reset`) if that flow matters.
- **Orphan/no-work-order events** commit with a project named `NA`
  (`commit_event: NA` in `state_reason`). Fine for the fixtures; decide the
  intended behaviour for genuinely orphan lab files.

**Deferred / to revisit:**
- **Real ACIRL fixture:** Robin's `2400-7399-08…Blaxland WMF.xls` is genuine
  binary BIFF (`readxl` reads it: sheets Front Page / Sampling Sites 1–4 / Dust /
  Water Methodology). Not yet anonymized/pinned — needs `readxl`→anonymize
  grid→`openxlsx` (`.xlsx`), preserving cell types (date serials!). The ACIRL
  adapter is green on its synthetic fixture but **unvalidated against a real
  workbook**.
- **SpreadsheetML `.XLS` parsing (A37):** parked. Adapter returns `match()=="no"`
  gracefully; `.csv` twin carries the data. `ES2600185_0_XTAB.XLS` fixture is
  pinned for the post-MVP path (parse via `xml2`, not `readxl`).
- **Plan-10 rev-1 fixture:** `XX1234567_1_XTAB.csv` (revision-supersede) was
  dropped in the crosstab fixture regen — plan 10 must recreate it in the real
  layout.
- **XTAB U+FFFD quirk:** `ES2600185_0_XTAB.csv`'s degree sign is the UTF-8
  replacement char `EF BF BD` (already lost upstream), so it reads as `ï¿½` under
  the latin-1 dialect and `normalise_lab_text()` doesn't repair it. Data is
  genuinely lost in the source; revisit whether XTAB encoding should be per-file
  detected.
- **Crosstab QC-block skip:** the rework added a mechanism to skip any
  non-dialect `…Matrix:` section (e.g. a trailing `QC - Matrix:` block) from that
  row on. Works for observed files; re-check it can't over-skip a mid-file block
  followed by real data.

## Handy commands

```r
# load + run one plan's tests
Rscript -e 'devtools::load_all(); testthat::test_file("tests/testthat/test-<x>.R", reporter="summary")'
# regenerate a fixture set
Rscript tests/testthat/fixtures/<adapter>/generate.R
```

Adapter self-registration lives in `R/zzz.R` (`register_builtin_adapters()`),
called from `.onLoad()` and at the start of `ingest_dir()` (A33).
