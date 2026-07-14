# CONTRACT digest — sampleTidy MVP

Single source of truth for module APIs, layout, conventions, and adjudicated
decisions. Workers read **this file + their own plan only**. When a plan and a
test disagree, tests win pending orchestrator adjudication. Design authority:
`dev/DESIGN.md` (= GitHub issue #1 v2).

## File layout (ownership partition — one plan per row group)

| plan | owns files |
|---|---|
| 01 | `R/config.R`, `R/db-connect.R`, `R/db-schema.R`, `R/hash.R` |
| 02 | `R/text-normalise.R`, `R/units.R`, `R/values.R`, `R/dates.R`, `R/spreadsheet-tools.R` |
| 03 | `R/ir.R`, `R/adapter-registry.R`, `R/file-meta.R`, `R/router.R` |
| 04 | `R/adapter-esdat.R` |
| 05 | `R/adapter-crosstab.R` (shared core + `als_xtab` + `als_enmrg`) |
| 06 | `R/adapter-acirl-field.R` |
| 07 | `R/assemble.R` |
| 08 | `R/reconcile.R` |
| 09 | `R/mutate.R`, `R/commit.R`, `R/archive.R`, `R/snapshot.R`, `R/ingest.R` |
| 10 | `tests/testthat/test-e2e-*.R`, `tests/testthat/helper-corpus.R` |

Tests: `tests/testthat/test-<module>.R`, one per R file, named
`"R-x.y: <criterion>"`. Fixtures: `tests/testthat/fixtures/<adapter>/…`.

## Pinned public API (exported)

```r
ingest_dir(path, db = st_config("live_db"), dry_run = FALSE)  # -> ingest_report
register_adapter(adapter); adapter_registry(); clear_adapters()
ir_results(...); ir_samples(...)          # validated zero-row prototypes / constructors
st_config(key, value)                     # get/set config (options-backed)
with_db_write(fn, db, max_wait, every)
ensure_schema(con)                        # idempotent migrations
correct_value(uuid_analysis, new_value, reason, actor)
add_feature(...); add_analyte(...); add_project(...)
db_append(con, table, df, actor, reason); db_update(...); db_delete(...)
review_queue(con, status = "open")        # read; resolution API post-MVP
snapshot_db(db, dest_dir); prune_snapshots(dest_dir, keep_days)
```

Internal seams (not exported, stable for tests via `:::`):
`file_meta()`, `route_files()`, `assemble_events()`, `reconcile_event()`,
`commit_event()`, `parse_value()`, `parse_lab_datetime()`,
`normalise_lab_text()`, `unify_value()`, `str_which_df()`, `vector_from_key()`.

## Conventions (all plans)

- R ≥ 4.2, native pipe `|>`, tidyverse style, roxygen2 markdown, testthat 3e.
- Errors via `cli::cli_abort(class = "sampletidy_error")`; never `stop()` bare.
- No interactive prompts anywhere (`ask`, `readline` forbidden).
- No site-specific strings (site names, orgs beyond format constants, paths)
  in `R/` — config or DB only.
- Timezone: `Australia/Sydney` for all naive lab datetimes. Month-name parsing
  assumes English locale (`Sys.setlocale` guard in tests).
- All DB writes go through the plan-09 mutation layer; adapters/reconciler
  never call `dbExecute`/`dbAppendTable` directly.
- Every function that skips/drops a row must return counts of what it skipped
  and why. Silent drops are defects.
- New Imports allowed: `readxl`, `readr`, `xml2`, `stringr`, `tidyr`,
  `rlang`, `digest`, `uuid`, `fs` (Suggests: `withr`, `ellmer`, `processx`,
  `sf`). Do not add others without a plan-change request.

## Existing DB schema (authoritative, from live monitoring.duckdb)

```
analysis(uuid, uuid_sample, uuid_lab, value DOUBLE, value_chr, quantified BOOL,
         rl_low, rl_high, purpose, comments)            # 95,737 rows
sample(uuid, uuid_feature, uuid_project, date TS, date_start TS, datetime TS,
       datetime_start TS, organisation, person, purpose, comments)  # 15,113
feature(uuid, name, site, flow, matrix, …, geom_wkt, virtual)        # 894
analyte(uuid, name, units, conversion_constant, type, …, CAS)        # 247
lab_method(uuid, uuid_analyte, name, method, organisation, rl_low, rl_high,
           reported_as, api, uuid_project, uuid_feature, comments)   # 360
project(uuid, uuid_parent, uuid_root, uuid_project, name, type, purpose,
        date_start, date_end, regulated_by, cypher, site, value)     # 551
asset(uuid, name, date, file_format, type, purpose, organisation, person,
      uuid_project, uuid_feature, filename, hash, comments)          # 2,530
analyte_mask(uuid_analyte, variant, name, units, conversion_constant)
feature_mask(uuid_feature, variant, name)
guideline(…); lab_invoice(…); views v_measurement*, v_analyte_*, v_feature_*
```

Vocab facts: `project.type = 'Work order'`, `project.name = <work order id>`
for lab reports; `sample.organisation ∈ {ACIRL, Internal, ALS}`;
`lab_method.organisation ∈ {ALS, ACIRL, eagle.io, legacy, Internal}`;
`sample.purpose` / `analysis.purpose` are free text, usually NA.

## Adjudicated decisions (A-log; do not re-litigate)

- **A1** Archived inbound files are `asset` rows using the **existing** type
  vocabulary (`type = 'Chemical analysis'` for MVP files). **No
  `analysis.uuid_asset` column**: provenance is (a) transitive —
  asset → project ← sample ← analysis — and (b) row-exact via
  `change_log.source_hash`, which every mutation records in-transaction.
  File-level linkage via `ingest_file.uuid_asset`.
- **A2** Ops tables (plan 01): `ingest_file` (hash-keyed state machine),
  `ingest_sighting` (duplicate-hash sightings), `review_queue`, `change_log`,
  `schema_version`. All additive; created by `ensure_schema()`.
- **A3** Public repo ⇒ **no real lab data committed**. In-repo fixtures are
  synthetic but structurally exact. Real-corpus tests read
  `Sys.getenv("SAMPLETIDY_CORPUS")` and `skip_if` unset.
- **A4** `NS` ("no sample") values are recorded skips with reason, never
  silent drops (deviation from old `cleanBDLvalues`).
- **A5** File hash = SHA-256 (`digest::digest(file = TRUE, algo = "sha256")`).
- **A6** Unknown feature/analyte/unit never auto-adds registry rows (old code
  auto-added); always a `review_queue` item.
- **A7** Migrations: additive-only, idempotent, recorded in `schema_version`.
- **A8** MVP is synchronous, single-process `ingest_dir()`; no watcher.
- **A9** Naive local civil time stored; canonical tz Australia/Sydney.
- **A10** ACIRL dust sheets: detected, counted, state `ignored` in MVP.
- **A11** `sample.date` always set (midnight-truncated); `sample.datetime`
  only when clock time known. Existing-row matching is at date granularity
  first, then datetime when both sides have it.
- **A12** Supersede fires automatically only when incoming `revision` >
  **recorded revision** = max over (i) `ingest_file.revision` of
  committed/archived files of the work order and (ii) `revision_guess`
  parsed from `asset.filename` of the work order's project (legacy files —
  verified present, e.g. `ES2107571_1_COA.pdf`; the regex anchors the
  revision immediately after the work order so `ES2131134_COC_1.pdf` yields
  NA, not 1). Equal revision or no recorded revision → review.
- **A13** Archiving copies **every file of a committed event** (kept,
  superseded renderings, metadata) to `<archive_dir>/<asset uuid>`
  (extensionless — matches existing `processed/`). Sources stay in `input/`
  unless `st_config("remove_ingested")` is TRUE (default FALSE — the tested
  switch): then sources whose hash has a verified asset copy are deleted
  after a successful run; quarantined/failed/cruft files are never deleted.
- **A14** Value-equality for already-present: numeric within
  `abs(a-b) <= 1e-9 * max(1, abs(a), abs(b))` after unit conversion, plus
  equal `quantified` flag; else conflict.

## Gates

- Per-plan: `testthat::test_file()` green for the plan's own test file(s).
- Global (before merge of plans 07–10): full `devtools::test()` green,
  `devtools::check()` no errors/warnings, and the e2e idempotency test
  (plan 10) passes twice in a row.
- Any empirical claim about file formats used in code must have a fixture
  test reproducing it ([MEASURE TWICE]).

## Build order & parallelism

01 → 02 → 03 → {04, 05, 06 in parallel} → 07 → 08 → 09 → 10.
Plans 04/05/06 are file-disjoint and share only plan-03 contracts.
