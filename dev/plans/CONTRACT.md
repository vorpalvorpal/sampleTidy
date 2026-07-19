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
| 11 | `R/feature-alias.R`, `R/pending.R`, `dev/migrations/001-alias-indirection.R`, `tests/testthat/test-feature-alias.R`, `tests/testthat/test-pending.R`, `tests/testthat/helper-db.R` + `dev/plans/FIXTURES.md` (A52) |

**Cross-plan edits (A52).** Plan 11 amends `R/reconcile.R` (owned by 08) and
`R/commit.R` / `R/mutate.R` (owned by 09). These are **adjudicated cross-plan
edits, not ownership transfers** — 08 and 09 keep their files. Plan 11 also takes
adjudicated cross-plan edits to `R/adapter-acirl-field.R` (06) and `R/assemble.R`
(07) for the ACIRL synthetic `lab_sample_id` (R-11.15/F2).

**Plan 12 (`PLAN-12-review-remediation.md`, 2026-07-19).** Owns no new files —
it is the whole-package code-review remediation set (F6–F19, A-6/A-7,
test-strength), landing as **adjudicated cross-plan edits** to files owned by
plans 01/03/05/09 plus their `test-<module>.R` files. Triage of record:
`dev/CODE-REVIEW-2026-07-19-TRIAGE.md`. The reconcile/commit-entangled findings
(F1–F5, F9, T-1) went into plan 11's fold-in section instead, to keep the
Phase-6 rewrite single-pass.

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
review_queue(con, status = "open")        # read
snapshot_db(db, dest_dir); prune_snapshots(dest_dir, keep_days)

# plan 11 — the resolve API (A55). This IS the resolution API; the earlier
# "post-MVP" note on review_queue() is struck. No UI is specified or built:
# the UI presents and executes, the human decides, the API records the human
# as confirmed_by. An LLM-driven UI may propose, never confirm.
confirm_feature_aliases(uuid_alias, uuid_feature, confirmed_by,
                        override = FALSE, db = st_config("live_db"))
confirm_analyte_methods(uuid_lab, uuid_analyte, confirmed_by,
                        db = st_config("live_db"))
pending_features(con); pending_analytes(con)   # dangling backlog readers
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
- New Imports allowed: `readxl`, `readr`, `xml2`, `stringr`,
  `rlang`, `digest`, `uuid`, `fs` (Suggests: `withr`, `ellmer`, `processx`,
  `sf`). Do not add others without a plan-change request. (`tidyr` was
  pinned here but never used by any module - dropped in A47.)

## Existing DB schema (authoritative, from live monitoring.duckdb)

```
analysis(uuid, uuid_sample, uuid_lab, value DOUBLE, value_chr, quantified BOOL,
         rl_low, rl_high, purpose, comments)            # 95,737 rows
sample(uuid, uuid_feature, uuid_project, date TS, date_start TS, datetime TS,
       datetime_start TS, organisation, person, purpose, comments)  # 15,113
       # A48: uuid_feature is DROPPED and replaced by uuid_feature_alias.
feature(uuid, name NOT NULL, site NOT NULL, flow, matrix, depth, installed_by,
        permanent, reference, date_start DATE, date_end DATE, cypher, elevation,
        uuid_project, lon DOUBLE NOT NULL, lat DOUBLE NOT NULL, geom_wkt,
        comments)                                                    # 894, 18 cols
       # CORRECTED 2026-07-17 (plan-11 cold review): this line previously listed
       # a `virtual` column. The live table HAS NO `virtual` COLUMN — verified
       # against information_schema. (helper-db.R's *test* DDL does declare one;
       # that is test-only drift, not the live shape.) `date_start`/`date_end`
       # DO exist live and were missing from this line; plan 11's date_end
       # narrowing depends on them.
       # CORRECTED 2026-07-19 (whole-package review, F5/A-4): the full live
       # 18-column shape is now listed. `lon`/`lat` are DOUBLE NOT NULL and were
       # hidden behind `…`; add_feature() omitted them (and carried a phantom
       # `virtual`), so it could never run against the live DB — plan 11 R-11.17
       # fixes the signature and reconciles the test DDL. Probed directly against
       # /Users/rjs/Documents/dashboard/data/monitoring.duckdb.
analyte(uuid, name, units, conversion_constant, type, …, CAS)        # 247
lab_method(uuid, uuid_analyte, name, method, organisation, rl_low, rl_high,
           reported_as, api, uuid_project, uuid_feature, comments)   # 365
       # CORRECTED 2026-07-17: 365, not 360. `reported_as` is NULL in all 365
       # rows (dead). A48: uuid_analyte becomes NULLABLE.
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
- **A6** *(amended by A54 — read A54 with this.)* Unknown feature/analyte/unit never auto-adds registry rows (old code
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
- **A37** Real ALS XTAB "`.XLS`" files are **SpreadsheetML XML**, not binary
  BIFF — `readxl` cannot read them (verified: `xml2` parses ~146 `Row`
  elements; `readxl::read_excel` errors). **Decision (Robin, 2026-07-15):
  SpreadsheetML parsing is PARKED post-MVP** — the `.csv` is the primary
  export and carries the same data (in WEM.data the `.XLS` was handled by an
  external automated-Excel workflow, not R). **MVP behaviour:** the crosstab
  `match()` already returns `"no"` for a SpreadsheetML `.XLS` (its `readxl`
  peek fails), so the router leaves it **unclaimed (cruft)** and no data is
  lost — the `.csv` twin is ingested. The crosstab rework must only guarantee
  this stays graceful (no crash) and add a test asserting `match() == "no"` on
  the real anonymized `ES2600185_0_XTAB.XLS`; the fixture is retained for the
  post-MVP SpreadsheetML path. **R-5.2's "xls twin" (`.XLS` parses equal to
  `.csv`) is deferred to post-MVP.** Genuine binary `.xls` (BIFF, magic
  `D0CF11E0`) is still required for **ACIRL** — its workbook IS BIFF and
  `readxl` reads it; that real ACIRL fixture is anonymized via
  `readxl`→`openxlsx`→`.xlsx`.
- **A38** (plan-08 build) `helper-db.R`'s `seed_db()` had a latent harness bug:
  a bare `withr::local_tempdir()` used as a **default argument** binds its
  deferred cleanup to `seed_db()`'s own frame (default-arg promises evaluate in
  the function's frame), so the tempdir was deleted the instant `seed_db()`
  returned — every caller got a **dead path**. Latent because all
  `seed_db()`-using tests (plans 08/09) were already TDD-red, so the
  `seed_con()` crash looked like just another red failure. **Fixed:**
  `seed_db(dir = NULL)` + `if (is.null(dir)) dir <- withr::local_tempdir(.local_envir = parent.frame())`,
  binding cleanup to the calling test. Reproduced and verified directly
  (`file.exists()` FALSE→TRUE). This unblocks plans 08 **and** 09.
- **A39** (plan-08 build) Ten `test-reconcile.R` fixtures signalled "a fresh
  sample" via `lab_sample_id = "XX1234567002"` (or used the default row) but
  left `feature_raw` at the default `"T.S01"`, so R-8.7's three-way match
  (feature+date+analyte — `lab_sample_id` is **not** a DB column, so it can
  **never** be part of the match) correctly routed them to
  `already_present`/`value_conflict` instead of `clean`. Confirmed a
  **fixture** bug, not a reconciler bug: FIXTURES.md L118/L140/L168 map
  `XX1234567002 = T.S02` and "`2.3 mg/L (no seed) → new`", and the dedicated
  R-8.7 `already_present` test (using the identical default collision row)
  **passes** — two tests can't both be right about the same row. **Fixed** by
  adding the intended `feature_raw = "T.S02"` (or, for the two feature/datetime-
  under-test cases, a non-colliding date) so each row is genuinely fresh; **no
  assertion was weakened**. Reconciler R-8.7 verified correct.
- **A40** (plan-09 mutate build) Two `test-mutate.R` verification queries
  (`db_delete`, `correct_value`) used `ORDER BY at DESC` with **unquoted** `at`
  — a self-inflicted A30 violation (verified: DuckDB throws `syntax error at or
  near "DESC"`). Fixed to `ORDER BY "at" DESC`; `mutate.R` itself quotes `"at"`
  correctly. Separately, the R-9.1 direct-write lint's bare `dbAppendTable`
  alternative false-positived on a **comment** in `reconcile.R` (which listed
  the forbidden function names to say it uses none). Reworded the comment to
  "no raw table-write calls"; the lint is now clean and still guards real
  writes. `mutate.R`'s transaction hook for `commit.R` is `db_transaction(con,
  fn)`: it tags a copy of `con` (sharing the same underlying pointer) so nested
  `db_append/update/delete` participate without a second `BEGIN` —
  `commit_event()` must run its whole body inside one `db_transaction()` and
  use the con handed to `fn`.
- **A41** (plan-09 archive/commit/ingest build) The three plan-09 test setup
  helpers — `archive_test_setup()` (test-archive.R), `commit_test_setup()`
  (test-commit.R), `ingest_test_setup()` (test-ingest.R) — re-triggered the A38
  `withr` frame bug **one level removed**: a bare `withr::local_tempdir()` /
  `withr::local_options()` / `seed_db()` (whose A38 fix binds to
  `parent.frame()`) called *inside a helper* registers its cleanup on the
  **helper's** frame, so the temp dirs and the `sampletidy.archive_dir` /
  `snapshot_dir` options were torn down the instant the helper returned —
  before the test body ran. Symptom: `archive_file()` aborted with
  `st_config("archive_dir")` "No value is set" (verified directly — 5/5
  test-archive.R errors, all in `st_config`, with a correct `archive_file()`).
  **Fixed** (harness only, no assertion touched) by capturing
  `env <- parent.frame()` in each helper and threading `.local_envir = env`
  through every `withr::local_*()` call plus `seed_db(dir =
  withr::local_tempdir(.local_envir = env))`. Verified: test-archive.R 5/5
  green after the fix. Same mechanical fix applied to the commit/ingest helpers
  so those suites aren't blocked by the harness.
- **A42** (plan-09 commit build) `test-commit.R:181` (the supersede test's final
  verification query) used unquoted `ORDER BY at DESC` — the identical A40 bug
  (`at` is a DuckDB reserved word; unquoted it is a parser syntax error,
  reproduced directly). The earlier assertions in the same `test_that`
  (`count_rows` unchanged, `updated$value == 300`) already pass, proving
  `commit_event()`'s supersede logic is correct — only the trailing raw-SQL
  read was broken. Fixed to `ORDER BY "at" DESC` (trivial test typo, no
  assertion weakened); test-commit.R now 8/8 green. Determinism confirmed: the
  supersede `db_update` lists `value` first, and DuckDB returns the
  first-inserted row among equal-`"at"` ties, so `LIMIT 1` deterministically
  yields the `value` row (`old="100"`, `new="300"`).
- **A43** (plan-09 ingest build) All 9 initial `test-ingest.R` failures were an
  A39-class fixture/harness collision, NOT an `ingest_dir()` defect: `seed_db()`
  seeds a legacy `ingest_file` row (`legacy-hash-XX`, `state='archived'`,
  `filename=NA`) for the supersede fixture. The ingest tests filtered
  `ingest_file` rows with bare `states$filename == "x"` / `states$state %in% ...`;
  the NA filename makes the comparison `NA`, and base-R `df[<logical with NA>, ]`
  splices in a phantom all-NA row — inflating `nrow(bak_state)`/`ds_state`/
  `corrupt_state` to 2 (`actual: NA "ignored"` etc.) and, in the missing-copy
  test, making `committed$hash[[1]]` select `legacy-hash-XX` (an archived row
  with no asset of its own). **Verified `ingest_dir()` is correct** by direct
  probe over the full fixture corpus: `.DS_Store`/`.bak` → `ignored`, XTAB/ENMRG
  twins → `ignored`/`superseded_by_better_source`, corrupt ESdat → `failed` with
  a real reason, unmatched → `quarantined`, review-only events → `needs_review`,
  real data committed + archived, snapshot written. **Fixed** the three affected
  filters to be NA-safe (`!is.na(states$filename) & ...`) — no assertion
  weakened. Also: `helper-corpus.R`'s `build_e2e_input_dir()` had the same A41
  `withr` default-arg bug (`dest = withr::local_tempdir()` deleting the returned
  dir on the helper's own return); fixed identically (`dest = NULL` +
  `.local_envir = parent.frame()`). test-ingest.R now 10/10.

- **A44** (plan-10 e2e — two real defects found by the synthetic e2e run, fixed
  in their owning plans per PLAN-10's "defects go back as a delta"):
  1. **reconcile.R (plan 08):** `.rc_feature_candidates(NA)` returned a phantom
     single `NA` candidate (`uuid[c(NA,NA,NA)]` → NAs → `unique()` collapses to
     one `NA`), which `.rc_resolve_features()` mis-read as a length-1 "hit" and
     kept in `clean` with `uuid_feature = NA` — an orphan sample/analysis at
     commit (the e2e "no orphan uuids" test found 8). Fixed: NA-key guard →
     `character(0)`, drop stray NA candidates, and map NA feature_raw to a
     sentinel group key so those rows still reach review (R-8.8 completeness).
  2. **assemble.R (plan 07):** `.st_join_samples_onto_results()` copied
     datetime/type/sampler/matrix/parent from the matched sample but **not
     `feature_raw`**. Real ESdat Chemistry2e sets `feature_raw = NA` (the feature
     is only on Sample2e), so every ESdat result stayed feature-less — masked
     until now by defect #1. Fixed: fill `feature_raw` from the matched sample,
     `is.na()`-guarded so crosstab results (feature inline) are not clobbered.
  3. **commit.R (plan 09)** — `.ct_find_or_create_sample()` built the stored
     sample `date` as `as.POSIXct(..., tz = "Australia/Sydney")`. The duckdb
     driver writes a POSIXct as UTC, so midnight AEST was stored as the
     *previous* day's 14:00 and `CAST(date AS DATE)` read back one day early —
     misaligned with the naive-literal seed dates, so a re-ingest (R-10.4)
     couldn't find the day-early sample and duplicated it. Fixed: build midnight
     with `tz = "UTC"` so the calendar day survives the round-trip (verified
     empirically). Regression test in test-commit.R.
  All three landed with regression tests (test-reconcile/assemble/commit.R).
  After the fixes, ESdat features resolve, the µS/cm→mS/cm EC conversion runs,
  and revision-supersede re-ingest is duplicate-free. Note the e2e R-10.2 EC
  test's *pinned* f-0001 row is a legitimate `value_conflict` (the ACIRL field
  fixture measures EC — analyte a-0003 — at the same feature+date as the ESdat
  lab EC), correct design behaviour, not a defect. Follow-up: commit stores the
  sample `datetime` as a correct instant but a UTC-shifted wall clock (e.g.
  11:45 AEST reads back 01:45) — a display/convention wart, not a matching bug
  (comparisons are instant-based); revisit the naive-AEST storage convention.
- **A45** (plan-10 e2e — domain correction from the user; amends A11/A14) The
  analysis uniqueness key is **(sampling location, datetime, analyte, method)** —
  **method included**. A field measurement (e.g. ACIRL field EC, method lm-0006)
  and a lab measurement (ALS lab EC, method lm-0003) resolve to the *same*
  analyte (a-0003) at the same feature+date, but are DISTINCT measurements, not a
  conflict — the DB legitimately holds both a field and a lab version. The
  reconciler's three-way match (`.rc_find_existing`, R-8.7) previously keyed on
  (feature, date, analyte) only, so it wrongly flagged the second source as a
  `value_conflict` (the plan-10 R-10.2 EC test exposed this: the ESdat lab EC
  couldn't commit because the ACIRL field EC already occupied the
  feature+date+analyte slot). **Fixed:** added `a.uuid_lab = ?` (method) to the
  match, so different methods are distinct rows. R-8.6's within-file duplicate-
  method dedup is unaffected (it collapses same-analyte/different-method rows
  *within one report* before the DB match). After the fix all 11 e2e tests pass,
  including R-10.2 EC as originally pinned (0.185 mS/cm at f-0001/lm-0003).
  Regression test in test-reconcile.R (field EC vs lab EC → two rows).

- **A46** (plan-10 R-10.5 real-corpus gate — a real production defect) Two
  files in **one** `ingest_dir()` run can carry **identical bytes**. The real
  corpus holds 11 such pairs: browser duplicate-download twins
  (`…Chemistry2e[96].CSV` beside `…Chemistry2e.CSV`). `ignore_rule()`
  deliberately passes `[N]` markers through, because content-hash dedup
  (A20), not filename guesswork, is meant to handle them — and
  `route_files()` re-decides nothing for an already-routed hash, so it
  records a sighting and returns the *stored* `claimed` state for **both**
  rows. `.ig_parse_claimed()` then looped over claimed **rows**, parsed the
  same content twice and drove an illegal `parsed -> parsed` transition,
  which **aborted the entire run** — the first real ingest of the real corpus
  would have died. **Fixed:** dedup `claimed_idx` by hash, parsing once per
  distinct content (`R/ingest.R`, plan 09's file — plan 10 is tests-only).
  `.ig_remove_verified()` stays per-path and is correct: both copies are
  deleted, each verified against the same `asset` row. Regression test in
  test-ingest.R (a `[65]` twin ingests once, without aborting).

- **A47** (plan-10 R-10.6 `devtools::check()` — the gate's first real run)
  Running the full check for the first time surfaced four things the
  `devtools::test()`-only workflow structurally could not:
  1. **The R-10.6 DESCRIPTION drift-guard test was itself broken under
     `check()`.** It located DESCRIPTION by walking `test_path()/../..`,
     which exists under `load_all()` but not under `R CMD check` (tests run
     from `<pkg>.Rcheck/tests/testthat`), so the gate erroring *was* the
     first check run. Fixed to read `packageDescription("sampleTidy")`.
  2. **`tidyr`** was a CONTRACT-pinned Import that no module ever used.
     Dropped from DESCRIPTION, the pinned set above, and the drift-guard
     test (user-approved).
  3. **Non-ASCII literals in R code** (`°`/`µ`/`→`/U+FEFF BOM/U+FFFD in
     `adapter-esdat.R`, `adapter-acirl-field.R`, `text-normalise.R`,
     `units.R`) → rewritten as `\uxxxx` escapes, value-identical and pinned
     by test-text-normalise.R. Non-ASCII in *comments* is tolerated by the
     check and left alone.
  4. **`ir_results.Rd`/`ir_samples.Rd` linked to `ir_validate()`**, which is
     `@noRd` and so has no help page → dead link; now plain `\code{}`.
  Remaining WARNING: **non-portable fixture file names**. The over-100-byte
  tarball paths were fixed by shortening the ESdat fixture prefix, but
  `R CMD check` flags **any space** in a file name, and the anonymized real
  fixtures keep one deliberately (every real ESdat file has spaces). See the
  gate note below.

- **A48..A55** (plan 11 — commit-everything / feature_alias indirection).
  Landed 2026-07-17 after a cold fresh-eyes review of PLAN-11
  (`dev/tdd-run/plan11-cold-review.md`). **Plan 11 is the detail; these are the
  pinned points.**
  - **A48** Model (P), full indirection. `sample.uuid_feature` is **dropped**;
    `sample.uuid_feature_alias` → `feature_alias.uuid` (NOT NULL).
    `feature_alias.uuid_feature` → `feature.uuid` is **NULLABLE** (NULL =
    dangling). Every feature gets a **self-alias** (894, `kind = "self"`), so
    there is no special case for "arrived correctly labelled". Resolution is one
    single-row `UPDATE`. An alias name is **not unique** — identity is the
    alias's own `uuid`; no DB uniqueness on `name`/`alias_key`.
  - **A49** DuckDB 1.4.1 **cannot drop a constraint at all**
    (`ALTER TABLE … DROP CONSTRAINT` → "No support for that ALTER TABLE option
    yet!"), and dropping dependent views does not help. Core-schema changes to
    `sample`/`lab_method` therefore need a **table rebuild**, cascading through
    `analysis` via its FK graph.
  - **A50** **A7 amended.** Plan 11's core-schema migration is **not**
    additive-only and is **not** run by `ensure_schema()`, which stays
    ops-tables-only. It is an **operator-run one-off** against a verified backup
    (never invoked by package code).
  - **A51** `analysis.units_raw` added. `analysis.value` is in canonical units
    **iff** the row's `lab_method.uuid_analyte` is non-NULL; when dangling,
    `value` is in `units_raw`. Safe **because** a dangling analysis is invisible
    to every view (all INNER JOIN through `analyte`) — the invariant and the
    visibility rule are the same rule.
  - **A52** File-ownership: plan 11's row is in the partition table above;
    `helper-db.R` is owned by plan 11; its edits to plans 08/09's files are
    adjudicated cross-plan edits.
  - **A53** `.rc_find_existing` drops its `lm.uuid_analyte = ?` clause as
    redundant — `a.uuid_lab = ?` pins the `lab_method`, which determines its
    analyte (verified, `R/reconcile.R:428-440`). A45's (feature, date, analyte,
    method) key is **unchanged**.
  - **A54** **A6 amended.** An unknown name **may** auto-create a **dangling**
    `feature_alias` (`uuid_feature IS NULL`) or **dangling** `lab_method`
    (`uuid_analyte IS NULL`), both `auto_assign = FALSE`; it may **never**
    auto-create a `feature`, an `analyte`, or a **resolved** `lab_method`; the
    `review_queue` item stays **mandatory**. A6's intent is preserved: a dangling
    row is invisible to every view, cannot auto-assign, and asserts no identity —
    it records the *question*, where the old code invented an *answer*. The
    CAS-hit path is barred precisely because it would create a **resolved** row
    (plan-11 D10).
  - **A55** The pinned public-API block gains `confirm_feature_aliases()`,
    `confirm_analyte_methods()`, `pending_features()`, `pending_analytes()`.
    `review_queue()`'s "resolution API post-MVP" note is **struck** — this is
    that API. The API is the authority; **no UI is specified or built**. A UI
    (including an LLM-driven one) may propose and may call these functions, but
    **never confirms on its own**: the human decides, the API records them as
    `confirmed_by`. Guesses never launder into ground truth.

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
