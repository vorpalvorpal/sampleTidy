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

### Phase 5 adjudications (from the test-suite audit; binding on implementation)

- **A15** ESdat Chemistry2e header is **18 columns incl. `Method_Type`**
  (between `Result_Type` and `Method_Name`) — verified against the live
  corpus. `match()` fingerprints the full 18-col header; `Method_Type` is a
  human method name, `Method_Name` the coded one. `Method_Type` is not mapped
  into the IR (adapter maps `method_raw ← Method_Name`).
- **A16** Domain write helpers `add_feature()`/`add_analyte()`/`add_project()`/
  `correct_value()` resolve their own connection via
  `with_db_write(st_config("live_db"))` (human-callable, no `con` arg). The
  generic `db_append()`/`db_update()`/`db_delete()` take an explicit `con`
  first arg and participate in the caller's open transaction.
- **A17** The four built-in adapters self-register in `.onLoad()` via
  `register_adapter()`; ids `esdat`, `als_xtab`, `als_enmrg`,
  `acirl_field_xlsx`; reached through `adapter_registry()[[id]]`. `ingest_dir()`
  works with zero setup.
- **A18** `with_db_write()` lock contention is **cross-process only** — duckdb
  1.4.1's per-process instance cache shares a same-process RW handle, so the
  DESIGN §9.2 same-process test can't reproduce a busy lock. Tests use
  `processx` to hold the lock in a separate OS process; the implementation is
  unchanged (the real contention is poller-vs-human, i.e. two processes).
- **A19** Non-lock connect errors in `with_db_write()` are wrapped in
  `cli::cli_abort(class = "sampletidy_error")` with the original as parent —
  never bare `stop()`. Lock errors are matched by message and retried.
- **A20** `ingest_sighting` is deduped by **(hash, path)**: re-routing the
  identical path adds no sighting; a different path with the same hash adds
  exactly one. R-3.5's "one new sighting" for same-path re-route was a slip;
  R-1.6's rule (append only when path ≠ `path_first_seen`) governs.
- **A21** `route_files(paths, con)` takes a connection (it persists to
  `ingest_file`). `ingest_file_upsert(con, hash, path, filename = NA,
  size = NA)`; `path_first_seen` is set once, on first insert.
- **A22** Assembly marks review-worthy rows **inline** on `event$results`
  with columns `needs_review` (lgl, default FALSE), `review_kind`,
  `review_payload`; the event shape (R-7.5) gains these. Reconcile folds them
  into its own `review` output. Assembly does not emit a separate review
  bucket.
- **A23** Assembly groups a zero-row (metadata-only) parsed file by
  `report$header$work_order` when present, else `meta$work_order_guess`.
- **A24** The throwaway test schema does **not** create the live views
  (`v_measurement*` etc.); e2e tests assert the equivalent join directly.
  `devtools::check()` is a Phase-6/9 CI-level gate, not a `test_that()`.
- **A25** `normalise_lab_text()` ports the WEM.data table **verbatim** (it maps
  literal `<XX>` hex-escape strings) **and** adds real-character entries for
  the bytes real files carry: latin-1/MacRoman `¡`(0xA1)→`°`, and the cp1252
  `°`/`µ` pairs. Both layers ship.
- **A26** `pH`/`pH Unit`/`pH_Units` are a dimensionless **identity** in
  `unify_value()` (must NOT trigger udunits' native logarithmic `pH`);
  `is_valid_unit()` TRUE for all three; conversion between them returns the
  value unchanged.
- **A27** Adapter `parse()` aborts with class `sampletidy_parse_error` on a
  malformed file (e.g. the invalid-UTF-8 CORRUPT fixture, or a non-ESdat XML);
  the router marks only that file `failed` and continues.
- **A28** Accepted auxiliary fixtures (beyond FIXTURES.md's pinned set), each
  documented in its dir README: `esdat/BADDATE…` (unparseable date → warning),
  `esdat/CORRUPT…` (parse-crash), `crosstab` WATER+**SOIL** two-section XTAB
  (per-section matrix), `crosstab/XX1234567_1_XTAB.csv` (rev-1 supersede),
  `acirl/EDGECASES.xlsx` + `NO_REPORT_NO.xlsx` + `random.xlsx`. ACIRL
  `report$header` fields: `report_no`, `sampled_by`, `sample_date`.
- **A30** `change_log.at` must be quoted as `"at"` in all SQL — `AT` is a
  DuckDB reserved word (unquoted DDL/DML errors). Applies to plan-09's
  mutation layer especially.
- **A31** `claimed → ignored` is a legal state transition (plan-01 worker
  broadened it to satisfy `test-db-schema.R`'s terminal-state check; tests
  win). Harmless — the router only ever drives `seen → ignored`; assembly
  drives `parsed → ignored`.
- **A32** ALL raw DB writes are confined to two files: `mutate.R` (core data
  tables, audited via change_log) and `db-schema.R` (ops tables + DDL). The
  R-9.1 lint enforces this. Pipeline modules (router, assemble, reconcile,
  ingest) write ops tables only through db-schema.R helpers:
  `ingest_file_upsert()`, `ingest_file_set_state()`, `ingest_file_set_route()`,
  `review_queue_add(con, kind, work_order, source_hash, payload)`. Plans 07/08
  MUST reuse `review_queue_add()` rather than raw `INSERT INTO review_queue`.
- **A33** Built-in adapter registration lives in `R/zzz.R` as
  `register_builtin_adapters()` (registers all four built-ins via
  `register_adapter()`, idempotent since register overwrites by id).
  `.onLoad()` calls it, AND `ingest_dir()` calls it at its start — so a prior
  `clear_adapters()` (e.g. the registry test's deferred cleanup) can't leave
  the pipeline with no adapters. Each adapter plan (04/05/06) adds its
  constructor to this one function; the orchestrator wires it as each lands.
- **A29** ~~Open items still needing Robin~~ **RESOLVED 2026-07-15** against the
  real corpus (`…/assets/input`). (1) The crosstab `Analyte grouping/Analyte`
  header is a **single combined column** in both XTAB and ENMRG — grouping is by
  method-group rows (see A34). (2) All five QC types appear in real Sample2e
  files (LCS/LAB_D/NCP/MB/MS/Normal); `LAB_D`+`MS` added to the Sample2e fixture
  (see A36). A16 (keep the split) and A22 (inline review) confirmed by Robin,
  unchanged. Full write-up: `PARKED-QUESTIONS.md`.
- **A34** Real ALS crosstab layout (supersedes the synthetic fixture's guess;
  drives PLAN-05 rework). Verified against real XTAB + ENMRG files:
  (a) `Analyte grouping/Analyte` is ONE column (col 0) holding both method-group
  rows and analyte rows — never two columns; (b) per-sample metadata labels
  (`Sample Type:`, `ALS Sample Number:`/`ALS Sample number:`, `Sample date:`,
  `Client sample ID (…)`, `Sample Site:`, `Purchase Order:`) sit at **col 3
  (XTAB) / col 4 (ENMRG)**, packed multiple-labels-per-row, with per-sample
  values under the sample columns (col 5+) — so the parser must regex-scan the
  **whole row** for each label and read its values at the sample-column indices,
  not just col 0; (c) header spellings differ — XTAB `Unit`/`Limit of reporting`,
  ENMRG `Units`/`LOR` — match both; (d) recent files carry a single `Matrix:`
  section (keep multi-section support; it is legacy/rare). Section-scalar labels
  (`Matrix:`/`Client - Matrix:`, `Workgroup:`, `Project name/number:`) remain at
  col 0 with value at col 1.
- **A35** ESdat CSV encoding (drives PLAN-04 fix; reconciles A27). Real
  Chemistry2e/Sample2e CSVs carry **latin-1** bytes (e.g. `0xB0` = `°`); the
  adapter MUST read them with a latin-1 locale (as the XTAB dialect does) then
  let `normalise_lab_text()` repair the mojibake — reading as UTF-8 makes
  `gsub()` abort on valid legacy files. **A27 refined:** a file is `failed`
  (parse crash) only on genuine structural failure (unreadable, or invalid even
  under latin-1), NOT merely for containing a non-UTF-8 byte. The CORRUPT
  fixture must be revised to represent true corruption under this rule.
- **A36** Sample2e fixture gains one `LAB_D` and one `MS` row (both `≠ Normal`,
  copied through verbatim by the adapter; still filtered by the reconciler in
  the MVP) so all five real QC types are exercised at the adapter level.

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
