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
| 11 | `R/feature-alias.R`, `R/pending.R`, `tests/testthat/test-feature-alias.R`, `tests/testthat/test-pending.R`, `tests/testthat/helper-db.R` + `dev/plans/FIXTURES.md` (A52) |
| 13 | `dev/migrations/001-alias-indirection.R`, `tests/testthat/test-migration-001.R` (split out of plan 11, 2026-07-22 — A68) |
| 14 | `dev/migrations/002-registry-remediation.R`, `tests/testthat/test-migration-002.R` (live-DB data fixes — A69) |

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
review_queue_candidates(con, uuid_review) # read an item's candidates, rank order
snapshot_db(db, dest_dir); prune_snapshots(dest_dir, keep_days)

# plan 11 — the resolve API (A55). This IS the resolution API; the earlier
# "post-MVP" note on review_queue() is struck. No UI is specified or built:
# the UI presents and executes, the human decides, the API records the human
# as confirmed_by. An LLM-driven UI may propose, never confirm.
confirm_feature_aliases(uuid_alias, uuid_feature, confirmed_by,
                        override = FALSE, db = st_config("live_db"),
                        kind = NULL, date_start = NULL, date_end = NULL)
confirm_analyte_methods(uuid_lab, uuid_analyte, confirmed_by,
                        db = st_config("live_db"))
pending_features(con); pending_analytes(con)   # dangling backlog readers

# plan 15 E.8 — registry hygiene, added 2026-07-26. EXPORTED because it is an
# operator-run tool (a `dry_run` argument and a `db` default are the
# human-callable A16 convention), and E.8 pins it as public. Merges a
# duplicate identity arm into the feature's self arm, deletes the duplicate,
# and repoints dependent samples.
merge_identity_aliases(db = st_config("live_db"), actor, dry_run = FALSE)

# phase-7b round 3 — the review CLOSE API, added 2026-07-26 (Robin's ruling).
# EXPORTED because round 3 found the queue could only ever GROW: the internal
# review_queue_close() has one production call site, filtered to
# kind = "unknown_feature", so a `sample_collision` row -- opened on every
# colliding confirm -- had no close path at all, exported or internal, while
# review_queue()/review_queue_candidates() are read-only. Targets a row by its
# own PRIMARY KEY (not the polymorphic uuid_target, which closes across
# producers), and records the human in `resolved_by` per A55.
resolve_review(uuid, resolution, resolved_by, db = st_config("live_db"))

# plan 09 R-9.7 / R-9.11, added 2026-07-28 (Robin's ruling). Both operator-run
# tools, hence the A16 human-callable convention.
#
# ingest_inbox(): PowerAutomate saves one lab email's attachments into their
# own folder under the inbox root, and ingest_dir() is deliberately
# NON-recursive (A8/R-9.5) - so without this there is no entry point for that
# layout at all. One ingest_dir() batch per folder, contained per folder, and
# the only layer that may delete an emptied folder (R-9.9): the folder is
# ingest_dir()'s own root, and a function must not delete its own root.
ingest_inbox(root, db = st_config("live_db"), dry_run = FALSE,
             reconsider = FALSE)

# quarantine_report(): every ingest_file row in a terminal state that is not
# `archived` (quarantined, failed) - `ignored` excluded, since a .bak is a
# decision, not a backlog. EXPORTED because nothing surfaced these rows: 19 sat
# unnoticed in the live DB from 2026-07-23 until they were found by hand. Same
# reasoning as resolve_review() above - a backlog nobody can list is a backlog
# nobody drains. Read-only, and derives work_order_guess from the STORED
# filename (the file itself is routinely gone by report time).
quarantine_report(db = st_config("live_db"))   # -> tibble
```

`ingest_dir()` gained a fourth argument in the same change:
`reconsider = FALSE` (R-3.7). When TRUE, files whose stored state is an
adapter-**registry verdict** (`unclaimed`, `adapter_tie`, router-`failed`) are
re-decided against the current registry instead of read back. Those three are
statements about the registry at the moment of the call, not facts about the
file — add a missing adapter or fix a buggy one and the same file should be
reconsidered. `ignored` and `archived` are never reconsidered at any setting,
and this is **not** an R-1.6 change: the terminal set and the transition graph
are untouched, and `reset = TRUE` is the existing override this is the case for.

`confirm_feature_aliases()`'s `kind` defaults to `transcription_error` on a
non-identity confirmation (Robin's ruling 2026-07-26, overriding PCR-5's
non-identity half — see the comment at `R/feature-alias.R`'s `is_identity`
branch). `kind` is provenance only: the sole production branch on it anywhere
is `kind == "self"`.

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
  `rlang`, `digest`, `uuid`, `fs`, `jsonlite` (Suggests: `withr`, `ellmer`,
  `processx`, `sf`). Do not add others without a plan-change request.
  (`tidyr` was pinned here but never used by any module - dropped in A47.)
  (`jsonlite` added by plan-change request, Robin 2026-07-25. PLAN-16 stores
  `review_queue.payload` as JSON and had added it to DESCRIPTION without
  amending this list, claiming it was "a dependency already present" - it was
  not, and R-10.6 was red as a result. Ratified rather than removed: it is
  used at exactly ONE production call site, the single diagnostics
  serialiser, and no other pinned Import offers JSON serialisation, so
  removing it would mean hand-writing escaping and full-precision number
  formatting - the defect class PLAN-16 exists to eliminate.)

## Existing DB schema (authoritative, from live monitoring.duckdb)

```
analysis(uuid, uuid_sample, uuid_lab, value DOUBLE, value_chr, quantified BOOL,
         rl_low, rl_high, purpose, comments)            # 95,737 rows
       # quantified is NULLABLE and used as a tri-state (A14): live invariant
       # `quantified IS NULL` ⟺ `value_chr IS NOT NULL`, 0 violations over all
       # 15,149 samples' analyses (315 text rows, 23 of them "no sample taken").
sample(uuid, uuid_feature, uuid_project, date TS, date_start TS, datetime TS,
       datetime_start TS, organisation, person, purpose, comments)  # 15,113
       # A48: uuid_feature is DROPPED and replaced by uuid_feature_alias.
feature(uuid, name NOT NULL, site NOT NULL, flow, matrix, depth, installed_by,
        permanent, reference, date_start DATE, date_end DATE, cypher, elevation,
        uuid_project, lon DOUBLE NOT NULL, lat DOUBLE NOT NULL, geom_wkt,
        comments, virtual BOOLEAN)                                   # 894, 19 cols
       # RE-CORRECTED 2026-07-22 (A67). The 2026-07-17 and 2026-07-19 edits both
       # claimed "18 cols, NO `virtual` column, verified against
       # information_schema". Both were probed against
       # /Users/rjs/Documents/dashboard/data/monitoring.duckdb — the DASHBOARD's
       # DERIVED copy, which that repo rebuilds independently from .qs files
       # (plan-11 D2), not the live DB. Against the authoritative DB the live
       # `feature` table HAS 19 columns INCLUDING `virtual BOOLEAN` (894 rows,
       # all FALSE). `virtual` marks a non-physical feature — WEM.data uses it
       # for SILO-grid weather stations (L.WS01/BH.WS01), which have real
       # (grid-centre) coordinates. It is NOT a placeholder mechanism, so plan
       # 11's "no provisional features" argument is unaffected.
       # STILL TRUE from those edits: `lon`/`lat` ARE DOUBLE NOT NULL and
       # add_feature() omits them, so it genuinely cannot insert live (F5's real
       # half) — see A58. `date_start`/`date_end` do exist live.
       # AUTHORITATIVE DB (quote the absolute path with any measurement, A67):
       # /Users/rjs/OneDrive - Blue Mountains City Council/Sharepoint/
       #   waste_data - Environmental monitoring/data/monitoring.duckdb
analyte(uuid, name, units, conversion_constant, type, …, CAS)        # 247
lab_method(uuid, uuid_analyte, name, method, organisation, rl_low, rl_high,
           reported_as, api, uuid_project, uuid_feature, comments)   # 360
       # RE-CORRECTED 2026-07-22 (A67): 360, not 365. The "365" came from the
       # dashboard's derived copy, whose 5 extra rows are MOJIBAKE TWINS of rows
       # the live DB already holds clean (EC @25<c2><a1>C / @25<ef><bf><bd>C,
       # Suspended Solids, TDS @180…) — the exact corruption class A25/A35 exist
       # to repair. 360 is the clean, authoritative count.
       # `reported_as` is NOT dead — see A64. It records the *basis* a result is
       # reported on (ammonium as N vs as NH3; hardness as CaCO3). It is NULL in
       # all 360 rows, which is a DATA GAP to be backfilled (plan 14), not a
       # dead column. Do NOT drop it.
       # MISSING vs the original design (A63): `units` and `conversion_constant`
       # were both in WEM.data's labDF ("make new dfs.R":63) and were lost when
       # this duckdb was built. Plan 13 restores them.
       # A48: uuid_analyte becomes NULLABLE.
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
- **A5** File hash = xxHash128 (`rlang::hash_file()`), a 32-char hex digest.
  CHANGED 2026-07-23 (was SHA-256 via `digest::digest(algo = "sha256")`): the
  pre-package system wrote xxHash128 into `asset.hash`, so 2,407 of 2,433
  hashed rows already used it and only 26 were SHA-256. Stored SHA-256 values
  were migrated. Non-cryptographic by design - this is a content-addressing
  key, not tamper-evidence. See PLAN-CHANGE-REQUESTS.md.
- **A6** *(amended by A54 — read A54 with this.)* Unknown feature/analyte/unit never auto-adds registry rows (old code
  auto-added); always a `review_queue` item.
- **A7** Migrations: additive-only, idempotent, recorded in `schema_version`.
- **A8** MVP is synchronous, single-process `ingest_dir()`; no watcher.
- **A9** Naive local civil time stored; canonical tz Australia/Sydney.
- **A10** *(REVERSED by A73, 2026-08-01 — read A73 instead.)* ACIRL dust sheets:
  detected, counted, state `ignored` in MVP.
- **A11** *(refined by A62 — read A62 with this.)* `sample.date` always set
  (midnight-truncated); `sample.datetime` only when clock time known.
  Existing-row matching is at date granularity first, then datetime when both
  sides have it.
- **A12** Supersede fires automatically only when incoming `revision` >
  **recorded revision** = max over (i) `ingest_file.revision` of
  committed/archived files of the work order and (ii) `revision_guess`
  parsed from `asset.filename` of the work order's project (legacy files —
  verified present, e.g. `ES2107571_1_COA.pdf`; the regex anchors the
  revision immediately after the work order so `ES2131134_COC_1.pdf` yields
  NA, not 1). Equal revision or no recorded revision → review.
- **A13** *(its layout claim is FALSE — see A70.)* Archiving copies **every file
  of a committed event** (kept, superseded renderings, metadata) to
  `<archive_dir>/<asset uuid>`
  (extensionless — ~~matches existing `processed/`~~ **it does not**). Sources stay in `input/`
  unless `st_config("remove_ingested")` is TRUE (default FALSE — the tested
  switch): then sources whose hash has a verified asset copy are deleted
  after a successful run; quarantined/failed/cruft files are never deleted.
- **A14** Value-equality for already-present: numeric within
  `abs(a-b) <= 1e-9 * max(1, abs(a), abs(b))` after unit conversion, plus
  equal `quantified` flag; else conflict. `quantified` is a **tri-state**
  (TRUE plain numeric, FALSE below/above detection, NA text result), so
  "equal" here is NA-aware: **NA equals NA** — two identical text results
  are `already_present`, not a second commit — while NA against TRUE or
  FALSE is a difference. (`.rc_values_equal()` used to return FALSE on any
  NA, which would have re-committed every re-ingested observation.)

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
- **A22** *(consumer half implemented by A56 — read A56 with this.)* Assembly
  marks review-worthy rows **inline** on `event$results` with columns
  `needs_review` (lgl, default FALSE), `review_kind`, `review_payload`; the
  event shape (R-7.5) gains these. Reconcile folds them into its own `review`
  output. Assembly does not emit a separate review bucket. **The "reconcile
  folds them" half was never assigned to a plan and nothing did it until
  A56/R-11.14** — flagged rows were silently discarded.
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
  **Encoding correction (root-caused 2026-07-22):** XTAB.csv is NOT legacy
  latin-1 — it is valid **UTF-8** whose degree/micro signs arrive already
  destroyed on disk to a single U+FFFD replacement char (bytes `ef bf bd`).
  Reading it under a latin-1 locale SHATTERS that one U+FFFD into three chars
  (`ï¿½`) that defeat `normalise_lab_text()`'s single-U+FFFD repair table (so
  `Electrical Conductivity @ 25°C` became `unknown_analyte`). The `als_xtab`
  dialect now declares `encoding = "UTF-8"`; both crosstab and ESdat CSV reads
  gained a **symmetric UTF-8↔latin1 quality fallback** (probe = residual
  mojibake cells after `normalise_lab_text()`; a clean read scores 0 and is
  never re-read, so it is a no-op for correctly-encoded files).
- **A35** ESdat CSV encoding (drives PLAN-04 fix; reconciles A27). Real
  Chemistry2e/Sample2e CSVs carry **latin-1** bytes (e.g. `0xB0` = `°`); the
  adapter MUST read them with a latin-1 locale (latin-1 stays the ESdat
  **primary** encoding under the A34 symmetric fallback — note the XTAB dialect
  itself is now UTF-8, not latin-1) then let `normalise_lab_text()` repair the
  mojibake — reading as UTF-8 makes `gsub()` abort on valid legacy files. **A27 refined:** a file is `failed`
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
  - **A51** *(SUPERSEDED by A63 — `analysis.units_raw` is NOT added. Read A63
    instead; the invariant below survives, its storage location changed.)*
    `analysis.value` is in canonical units **iff** the row's
    `lab_method.uuid_analyte` is non-NULL; when dangling, `value` is in the
    **method's** units. Safe **because** a dangling analysis is invisible to
    every view (all INNER JOIN through `analyte`) — the invariant and the
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

- **A56..A58, A62** (plan 11 — the 2026-07-19 whole-package-review fold-ins).
  Landed 2026-07-22. **A59–A61 are reserved for PLAN-12** (adapter `match()`
  contract; ingest containment; checked file operations) and are not repeated
  here — see `PLAN-12-review-remediation.md`.
  - **A56** The A22 consumer seam is now implemented (plan 11 R-11.14):
    `reconcile_event()` gains a **stage-0**, before the R-8.1 QC filter, that
    partitions `needs_review == TRUE` rows out of `active` into `review`,
    mapping `review_kind` → `kind` and `review_payload` → `payload`, counted
    exactly like `add_review()` so R-8.8 completeness still reconciles. Such a
    row does **not** also flow to `clean` — these are "we don't trust this row"
    flags, distinct from the commit-everything feature/analyte-pending rows,
    which **do** commit. **Workflow lesson:** a CONTRACT adjudication spanning a
    producer and a consumer must be named in **both** plans' criteria, or
    nothing tests the seam.
  - **A57** Value semantics: `analysis.quantified` is `parse_value()`'s
    `quantified` (**never** re-derived from `below_detection`), and
    `analysis.rl_high` is populated for `>`-notation rows. Corrects the old
    re-derivation, which committed `>`/`BDL` rows as `quantified = TRUE`.
  - **A58** `add_feature()` is aligned to the **live** `feature` schema:
    required `name`/`site`/`lon`/`lat` (all NOT NULL live). **`virtual` is
    KEPT** — the 2026-07-19 "drop it" instruction rested on the dashboard-copy
    misreading (A67); the column exists live and `add_feature()` may be called
    by code that uses it. It stays optional, defaulting FALSE.
    `.st_test_core_ddl`'s `feature` is reconciled to the live **19**-column
    shape (this is A-4's DDL reconciliation), removing the test-only drift that
    let the missing `lon`/`lat` stay green.
  - **A62** **A11 refined** (user, 2026-07-19): two readings at one feature+date
    with **different non-NA datetimes are distinct samplings** — distinct
    `sample` rows, not one. Governs both `.rc_find_existing` and
    `.ct_find_or_create_sample`, which must agree or reconcile flags the second
    reading `already_present` and it never reaches commit. The split fires only
    when distinctness is **provable**: incoming datetime non-NA **and every**
    candidate non-NA **and** differing. A NA on either side falls back to
    date-granularity reuse, so A11's rule governs every uncertain case.

- **A63..A69** (plan 11 second review, 2026-07-22 — user decisions + the
  authoritative-DB re-measurement).
  - **A63** **A51 reversed — `analysis` gains NO units column.** Units live on
    the **method**: `lab_method` regains `units` and `conversion_constant`
    (both were in WEM.data's `labDF` and were lost when this duckdb was built —
    a schema regression, not a design change). Restored by plan 13.
    **Measured** (3,624 committable `Normal` rows, 90 events, real corpus):
    **221 of 222 distinct (method, analyte) pairs report exactly one units
    string**; the sole exception is `sodium adsorption ratio`, whose two values
    are `-` and NA — both meaning *dimensionless*. Units are a function of the
    method. (A first cut said 95 of 354 varied; that was QC rows — LCS/MB
    recoveries report in `%` — which the reconciler filters before commit. Do
    not re-derive this number without the `Normal` filter.)
    **`lab_method.units` is a FALLBACK, not a guarantee** (user, binding): it is
    how to interpret a value when nothing better is known; it does **not**
    assert that any particular report used that unit. Record this as a
    `COMMENT ON COLUMN` so it travels with the schema.
    **Units are NOT part of a method's identity.** Identity stays
    `(organisation, name, method)`. A units change on an existing identity must
    **never** spawn a second `lab_method` row: `.rc_find_existing()` keys on
    `a.uuid_lab`, so a new row means a lab reissuing a report with corrected
    units would not supersede — the row would commit as a **second analysis**,
    and both would show in `v_measurement` (verified: `.rc_three_way()` reaches
    the supersede branch only via `.rc_find_existing()`). Instead the drift is
    surfaced at **confirmation** time (see plan 11 R-11.11).
    On ingest, a matched row's value is multiplied by the method's
    `conversion_constant` when it is non-NA, and *that* is what `analysis.value`
    stores.
  - **A64** **`lab_method.reported_as` is NOT dead** — the earlier "NULL in all
    rows, candidate for removal" note is **struck**. It records the *basis* a
    result is reported on: ammonium as `N` vs as `NH3`; alkalinity/hardness as
    `CaCO3`. It being NULL in all 360 rows is a **data gap**, not evidence of
    disuse (plan 14 backfills it). The basis is currently carried in the
    `lab_method.name` string instead (ALS's own naming: `Ammonia as N`,
    `Ammonia as NH3`, `Total Alkalinity as CaCO3`). **Do not drop this column.**
  - **A65** Lab-method candidate resolution (fixes a live defect). Two
    `lab_method` rows may legitimately differ only in how the lab spelled the
    name (`Standing Water Level` vs `Standing water level`, both ALS, both
    method `field`, both → one analyte) — those are **genuinely different
    methods** and both rows are kept (user, binding: methods retain the
    capitalisations actually used in reports). But `.rc_method_key()` folds them
    together, `.rc_lab_method_candidates()` returns 2, and
    `.rc_resolve_analytes()` requires exactly 1 — so **every ACIRL standing
    water level reading currently strands as `unknown_analyte`** (verified
    against the live registry). New rule:
    1. **exact raw-name match** (case-sensitive) on `(name, organisation,
       method)` wins — the report said `Standing Water Level`, so it matches
       that row. This is not attempted today; the code folds first.
    2. else the folded match; if all survivors resolve to **one** analyte it is
       a **hit**, not an ambiguity (the parallel of R-11.4's feature rule), with
       a deterministic pick.
    3. else (survivors span >1 analyte) → ambiguous → review.
  - **A66** **Plan-11 D10 reversed** (user, 2026-07-22): a CAS-hit
    (`known_analyte_no_method`) row **commits dangling like any other unknown
    analyte**, with the CAS-matched analyte carried on its review item as a
    **suggestion**. This is consistent with A54 — a dangling `lab_method`
    (`uuid_analyte IS NULL`) is exactly what A54 licenses, no **resolved** row
    is created, and the CAS evidence is preserved in the payload rather than
    discarded. One rule for every unknown analyte; the carve-out is gone.
  - **A67** **Evidence-DB provenance (binding on every measurement).** Three
    monitoring.duckdb copies exist and **their schemas differ**. Only
    `…/OneDrive - Blue Mountains City Council/Sharepoint/waste_data -
    Environmental monitoring/data/monitoring.duckdb` is authoritative.
    `/Users/rjs/Documents/dashboard/data/monitoring.duckdb` is the dashboard's
    **derived** copy (rebuilt independently from `.qs` files — plan-11 D2);
    `/Users/rjs/Documents/leachatetools/test data/monitoring.duckdb` is stale.
    `st_config("live_db")` does not exist on this machine. Row counts agree
    across copies (894/15,113/95,737/247), which is exactly why the wrong one
    passed as interchangeable and produced three false CONTRACT "corrections"
    (`feature` 18 cols/no `virtual`; `lab_method` 365; "60 views"). All three
    are reverted. **Quote the absolute path with any measurement.**
    *Also corrected: the "60 views" figure was `duckdb_views()` counting
    DuckDB's internal catalog views. Both copies have **14** real views, and on
    both, exactly **6** reference `sample.uuid_feature` — plan-11 D4 stands.*
  - **A68** Plan 11's migration is **split into PLAN-13** (user, 2026-07-22).
    Plan 11 itself argued it was separable, it has its own 11-step procedure and
    criteria, and it named no test file. Plan 13 owns
    `dev/migrations/001-alias-indirection.R` + `test-migration-001.R`. The
    ordering constraint is unchanged and binding: **plan 11's code must not be
    run against the live DB until plan 13 has landed** (R-11.4 drops the
    `feature_mask` lookup on the grounds that plan 13 step 5 imports its `long`
    names; and without the migration there are no self-aliases, so 100% of live
    data would commit dangling).
  - **A69** Live-DB **data** remediation is **PLAN-14**, distinct from plan 13's
    **schema** migration and dependent on it. Three items, none of them applied
    yet, all behind the same backup-verify-rehearse gate and all routed through
    the plan-09 mutation layer (never raw SQL) so each lands in `change_log`:
    (a) merge the duplicate `Carbophenothion` **analyte** rows — keep
    `31b21bfa…` (221 analyses), repoint `d0dc5ac3…`'s `lab_method` and its two
    `analyte_mask` rows, then delete it; no `analysis` row is touched, since
    analyses reach the analyte through `lab_method`;
    (b) backfill `reported_as` (`N` / `NH3` / `CaCO3` …) and the matching
    `conversion_constant` per A63/A64;
    (c) **CLOSED — no action. The 12 `Ammonia as NH3` analyses are already
    correct.** Resolved 2026-07-22 by reading the archived source: the DB names
    the asset uuid, and
    `assets/processed/08f1555c-…/ES2415638_0_XTAB.csv` (work order ES2415638)
    reports **both** bases in one file — `Ammonia as N` on samples 001–003 and
    `Ammonia as NH3` on 004–015. Every stored value is the reported as-NH3
    figure **× 0.8224428** (the NH3→N mass ratio), max deviation 1.4e-06 across
    all 12. **The old pipeline already applied the conversion; it just never
    recorded the constant** — and the 7 significant figures that made the values
    look "derived" are the signature of that multiplication. The dates match the
    source exactly in `Australia/Sydney` (they look a day early only under
    `CAST(date AS DATE)`, which shows the UTC calendar day). Both fixes
    considered would have corrupted good data: ×1.216 ⇒ ~21.6% high, ×0.8225 ⇒
    double-converted ~18% low. R-14.2 records the constant; it must **not**
    re-apply it to these rows.
  - **A70** **A13's archive-layout justification is false.** A13 writes each
    archived file as an *extensionless file* named `<asset uuid>`, on the stated
    grounds that this "matches existing `processed/`". Measured 2026-07-22
    against the real archive: `processed/` holds **1,565 directories** named
    `<asset uuid>`, each containing the original file under its real name
    (`08f1555c-…/ES2415638_0_XTAB.csv`), versus **33** extensionless files.
    The dominant existing convention is **directory-per-asset**, and
    `archive_file()` (`R/archive.R:50-52`) writes the minority shape.
    Two consequences: the real archive would become half one shape and half the
    other, so anything walking it must handle both; and A13's own wording —
    "copies **every file** of a committed event" — is unsatisfiable with a
    single extensionless file per asset uuid, whereas a directory holds many.
    **Not fixed here** (`R/archive.R` is plan 09's file and PLAN-12 R-12.4
    already amends it). Routed to **PLAN-12 R-12.17**; A13's layout is re-pinned
    once decided. Nothing is stranded meanwhile — sampleTidy has not written to
    the real archive yet.

- **A71** **Tooling latitude (user, 2026-07-22 — binding on every worker).** Where the
  tdd-plan skill asks for **stellwerk**, it may be skipped: stellwerk is not part of
  this project (it is the skill's other host project, and `scripts/bindings/stellwerk.toml`
  is *its* binding, not ours). **Use the project's own tools instead** — the R suite is
  the gate:
  `Rscript -e 'devtools::load_all(); testthat::test_dir("tests/testthat")'`.
  Concretely, Phase 7a mutation testing is run by the **`tdd-mutator` agent** (which the
  skill already names as the fallback for "stellwerk cannot run the suite"), or inline by
  the orchestrator. **This generalises:** any skill-named tool that does not work
  reliably here may be replaced by one that does — say so in the report rather than
  stalling on it. It is never a reason to skip the *check* itself, only the tool.

- **A72** **`db_delete()` on a nonexistent uuid ABORTS** `cli::cli_abort(class =
  "sampletidy_error")`, and writes no `change_log` row. (Pinned 2026-07-22, Phase-3 D2 —
  PLAN-12 R-12.6 explicitly left the choice open and said "pin which".) Rationale: R-12.6
  exists to stop the mutation layer recording things that did not happen, and a silent
  no-op delete is that same defect wearing the other hat; it also matches `db_update()`'s
  existing no-row behaviour and the house fail-loud style (A4). **Consequence, and the
  reason this needed pinning before PLAN-14 was written:** PLAN-14 R-14.1 deletes an
  `analyte` row and must stay idempotent, so it carries an explicit existence pre-check
  rather than relying on a tolerant delete.
- **A73** **A10 IS REVERSED (user, 2026-08-01): ACIRL dust sheets are parsed, not
  ignored.** Both `Dust Results` and `Dust Observations`. Dust has no ALS counterpart
  (every `lab_method` ever recorded against `B.D07`/`B.D08` is ACIRL, method
  AS3580.10.1), so dust was **exempt from the ALS-linkage gate (A74)** — which A79
  has since withdrawn entirely, making the exemption moot — 6 workbooks
  are dust-only and have no water sheet at all. Analytes already exist:
  `dust-total` ← `INSOLUBLE SOLID`, `dust-combustible` ← `*COMBUSTIBLE MATTER`,
  `dust-incombustible` ← `INCOMBUSTIBLE MATTER`, and `Appearance` ←
  `ANALYSIS OBSERVATIONS` for the observation text.
- **A74** ⚠️ **WITHDRAWN by A79 on 2026-08-02 — do not implement.** The gate was
  built (PLAN-09 R-9.13), measured, and then removed: `.ig_als_gate()`,
  `report$als_gated`, the `als_source_missing` retry path and the
  `parsed -> quarantined` transition are all gone. The distrust it encoded is real
  but now acts one stage later and one row at a time — an ACIRL *transcription* is
  superseded at reconcile when the ALS row arrives. The citation it introduced
  (`report$als_work_orders`, `report$n_water_sheets`) is KEPT and is now A80's
  filing input. The original ruling and its measurements follow, because they are
  why A79 went the way it did.

  **ACIRL water sheets require their ALS source (user, 2026-08-01).** Most of
  an ACIRL water sheet is ALS lab data copied by hand; we do not trust the transcription,
  and it drops reporting limits. Every water sheet declares an `ALS Sydney Report No.`
  (present in 640/640 real sheets). **If any cited `ES#######` work order is not held,
  the file is quarantined with reason `als_source_missing`, per file — not a run-level
  abort**, so the rest of the batch proceeds and the file re-processes naturally when the
  ALS report arrives (ACIRL routinely arrives first). A sheet may cite **two** work
  orders; **all** must be held. Measured cost: 74 of 640 sheets, 19 of 147 workbooks.
  **Enforced in `ingest_dir()` (PLAN-09), not in the adapter** — `parse()` sees one
  file and no database. The adapter only exposes `report$als_work_orders`.
  **Implementation notes added 2026-08-01** (PLAN-09 R-9.13, PLAN-06 R-6.5b), all
  measured rather than assumed:
  (a) the gate runs as its own pass **between parse and assemble** — after, because
  "held" includes an ALS sibling arriving in the same batch and parse order within a
  batch is arbitrary; before, because a gated file must contribute no rows, no events
  and no review items.
  (b) **"held" = a `project` row for the `ES#######`, OR that work order arriving in
  this same batch.** ACIRL and ALS routinely land in one PowerAutomate folder; without
  the same-batch arm the ordinary case would need two runs.
  (c) **Citing nothing is a gate failure, not an exemption.** The A73 dust exemption is
  keyed on `report$n_water_sheets == 0`, NOT on an empty citation. Measured: of the 8
  claimed workbooks citing nothing, 7 are dust-only but 1 (`2400-7483-01 May 2025
  Lawson Landfill.xls`, 30 rows) has eight water sheets whose ALS cell reads a bare
  `ES`. Reading "cites nothing" as "must be dust" would have imported it with no
  traceable source.
  (d) `als_source_missing` is **re-decided on every ordinary run**, with no
  `reconsider` flag — it is a fact about the world, not about the file or the adapter
  registry, and A74's "re-processes naturally when the ALS report arrives" is otherwise
  unreachable. Safe (a gated file committed nothing) and self-limiting.
  (e) Measured cost against the live DB's 423 held work orders: **17 of 154 workbooks,
  644 rows** — 16 citing an unheld order, 1 citing nothing. 13 distinct work orders
  missing, of which 11 are pre-2025 and out of scope, leaving `ES2503724` and
  `ES2522505`. This **supersedes the "19 of 147 workbooks" above**, which predates
  both the A76 allowlist widening (which changed which workbooks yield rows) and the
  R-6.5b extractor fix (which moved `2400-7223-12-01`, 57 rows, out of the gated set
  by finding the citation it had been shadowing).
- **A75** **Field-vs-ALS selection is by value, not position (user, 2026-08-01).**
  Position is unsafe — 74 of 190 real sheets interleave ALS-copied rows among the field
  rows. Per label row: (i) no value in any sample column → heading, drop silently;
  (ii) values equal the ALS values for the same feature+analyte → ALS copy, drop
  (`lab_data_dropped`); (iii) on the field allowlist and not matching ALS → import as a
  field reading; (iv) has values but neither allowlisted nor ALS-matched → **review
  queue**, never a silent import or a silent drop; (v) `----` means "not analysed".
  Rule (ii) **must exclude** ALS rows whose method is `EN67 - Client Supplied Data` (or
  any `field`-flagged method): there ALS is carrying the field reading itself, and
  treating it as a copy would discard genuine field data. Where both sides hold the same
  field reading, **exactly one row is written** — dedupe on
  feature + datetime + analyte + `method = 'field'`.
  **Enforced where the ALS data is visible — `assemble_events()` for same-batch
  siblings, `reconcile(con)` for already-committed ALS — not in the adapter.** The
  adapter must therefore *keep* ALS-looking rows, tagged `als_candidate`, rather
  than dropping them at parse: the old drop-at-adapter behaviour destroyed the very
  values this test needs to compare. Steps (i) heading-drop and (v) `----` are
  decidable per-file and stay in the adapter.
  **Implementation notes added 2026-08-02 (Robin's question: use the
  `lab_method -> analyte` map), all measured over 38,450 real candidate rows**
  (that row count DOUBLE COUNTS — 10 workbooks sit in both `unprocessed/` and
  `processed/`, so only 34,024 (file, source_ref) pairs are distinct, and 34,137
  is the `unprocessed/` figure a 6c ingest would see. Noted and RE-DERIVED
  2026-08-03, `scratchpad/m6a_a79_basis.R`: every figure below reproduces
  exactly on the 38,450 basis as quoted, and shifts only slightly on the
  deduplicated one — twins by analyte **76.1% → 75.1%**, and the
  `Total Suspended Solids` case **605 rows / 468 twins → 545 / 413**. The
  conclusions are unaffected; only the row counts are inflated):
  (a) **The comparison keys on the RESOLVED ANALYTE, not the label.** ACIRL and ALS
  name the same analyte differently — ACIRL writes `Total Suspended Solids`, ALS's
  method is `Suspended Solids (SS)`, canonical `TSS`. Resolving both sides through
  `lab_method.uuid_analyte` fixes it: those 605 rows go from **0 twins by label to
  468 by analyte**. Keyed on the label, all 605 would have read as "no ALS twin ->
  field estimate -> import", i.e. importing transcribed ALS values as field
  readings — exactly what A75 exists to prevent.
  (b) **The map is safe as a key.** Of 271 folded `lab_method` names, exactly **one**
  is ambiguous: `>C10 - C16 Fraction` -> `TRH-C11-C16` or `TRH-F2`, two ALS rows
  differing only by `method` (`EP080/071:` vs `EP071:`), which an ACIRL sheet cannot
  supply. Ambiguous keys must route to review, never guess — note the label key
  "found" those 123 twins only by coin-flipping between the two analytes.
  (c) Coverage: **97.0%** of candidate labels resolve; **76.1%** have an ALS twin.
  (d) **Both A75 arms need the database, so both belong in `reconcile(con)`.**
  `assemble_events()` has no connection and so cannot resolve an analyte at all. The
  same-batch case then needs no separate mechanism — it only needs the ALS event to
  reconcile *before* the ACIRL event, which is an event-ORDERING guarantee (ACIRL
  events are orphans, home work order `NA`, so ordering is not currently guaranteed).
  This supersedes A75's "assemble for same-batch siblings" split: not because the
  split is wrong, but because ordering makes one mechanism serve both.
  (e) **The residual review load is a FEATURE problem, not an analyte one.** Of the
  9,205 no-twin rows, **5,018 fail on the feature**: 36 of 104 ACIRL point codes match
  neither a `feature` nor a `feature_alias`. They fall in two groups — human names
  the R-6.7 alias mapping already recovers (`EFFLUENT`, `BORE 2`,
  `CRIPPLE CREEK INLET`), and letter-**O**-for-**zero** codes (`B.EO1`, `B.SO1`,
  `B.SO5`, `B.LO1`, `K.SO6`, plus unpadded `B.MW2`). **Not auto-mapped** — the alias
  domain rule is old != misspelling, no fuzzy — so these need Robin's ruling.
  Only **3,016** rows are genuinely "ALS did not measure that analyte at that point",
  plus **1,171** analyte registry gaps (`Total Hardness` 438, `Nitrite` 260, the
  EC-@-25 mojibake 150, `Nitrite + Nitrate` 60, ...).

  **Risks of the reconcile-only design, measured 2026-08-02 before building.** The
  design is sound but has two failure modes that must be built out from the start, not
  patched later:
  (i) **The twin test is an ABSENCE test, and absence is not evidence when the data may
  be incomplete.** 5,094 of the 9,205 no-twin rows sit on a feature that does not
  resolve — no twin could have been found there whatever the truth. Most go safely to
  review under rule (iv), but rule (iii) rows *import* on absence: **70 diff-required
  TSS rows would silently import an ALS copy as a field reading**, which is precisely
  the failure A75 exists to prevent, delivered by A75 itself. **Mitigation: a row may
  never take the absence branch unless its feature resolved. Unresolved feature →
  review, always.**
  (ii) **Order-dependence is a silent-corruption coupling.** Making correctness depend
  on ALS events reconciling before ACIRL ones is a hidden temporal dependency: a later
  reorder (parallelism, performance, refactor) flips verdicts silently and no test
  notices unless written for it. **Mitigation: do not rely on ordering — CHECK it.**
  The ACIRL branch asserts the cited work order has *visible analyses*, not merely a
  `project` row; project-but-no-analyses (the same-batch, not-yet-committed case) →
  review. Ordering then becomes an optimisation, not a correctness requirement.
  (iii) **`als_candidates` does not currently reach reconcile.** `.st_build_event()`
  builds a fresh `report` with five fields; `als_candidates`, `als_work_orders`,
  `feature_aliases` and `n_water_sheets` are all dropped at assemble. So the unit is
  *not* reconcile-local — assemble must be changed to carry them onto the event.
  (iv) The verdict becomes a function of **(file, database state)**, not of the file
  alone: the same workbook re-processed later can decide differently. Inherent to A75,
  but it means provenance must record *why* each row was dropped or imported, or the
  decision is unauditable afterwards.
  (v) **Sequencing.** Feature aliasing is now load-bearing for A75's correctness, so
  the alias work (A78 + the 9 descriptive codes) should land first — or (i) must gate
  it. A third outcome, *undecidable*, is also needed for the one ambiguous analyte
  (`>C10 - C16 Fraction`, 148 rows); rules (i)–(v) do not name it.
- **A76** **The ACIRL field set is maximal (user, 2026-08-01):** Temperature, pH, EC,
  Standing water level, DO, ORP, turbidity, flow, and **TSS** — TSS being a *field
  estimate* whenever it is not on the ALS results, and the one field analyte with a real
  ALS twin, so it separates on A75's value test rather than on name. Writes go to the
  existing `lab_method` convention `method = 'field'`, `organisation = 'ACIRL'` (already
  populated: pH 1026 rows, Temperature 965, EC 856, Standing water level 260; TSS/DO/ORP
  have the `lab_method` row but zero analyses). **`Turbidity` does not exist and is to be
  created** (NTU, type `quality`) with its ACIRL `field` lab_method. Observation labels
  are qualitative (`value_chr`): `General Comments/ Observations` and
  `Observations / Comments` → `Appearance` via lab_method `Comments`;
  `Flow Observation / Appearance` is **split** into `Stage` (flow) + `Appearance`
  (clarity). Historical rows that conflate the two are **left alone**. The 6
  `Standing water level` lab_method name variants (`Water Height`, `Water Depth`,
  `Standing Water Height`, …) are **preserved as received**, not consolidated.

  *Implementation notes added 2026-08-01 after measuring the corpus (see PLAN-06
  R-6.6); none of these change the ruling, they record what honouring it meant:*

  - The allowlist is built from **measured labels**, not from the analyte names
    above. `st_config("field_analytes")` matches a label exactly (squished,
    upper-cased); the sheets say `Electrical Conductivity`, never `EC`.
  - **TSS is not on the allowlist and must not be.** Its ACIRL label *is* the ALS
    analyte's name, so the name cannot separate them. It has its own key,
    `field_analytes_diff_required`; the adapter routes those rows to
    `report$als_candidates` with `diff_required = TRUE` and skip reason
    `diff_required`, and **only A75's value comparison may promote one to a field
    result**. This makes the A75-before-import ordering structural rather than a
    promise: 678 real rows currently sit behind it.
  - **turbidity, DO, ORP and flow occur zero times** in the 213-workbook corpus —
    DO/ORP are allowlisted anyway (they are registered ACIRL `field` methods), and
    `Turbidity` still needs creating, but neither will import anything today.
  - `Electrical Conductivity @ 25°C` is the ALS value transcribed into the
    sheet, never a field reading, and is deliberately excluded from the
    allowlist. ACIRL owned a `field` lab_method under the **mojibake** spelling
    of that label carrying **zero analyses**; it was **deleted from the live
    database on 2026-08-01** (`db_delete()`, `change_log` uuid_row `9f59b10a`,
    backup `monitoring_pre-ec25-fix_20260801T213736.duckdb`). The clean-named
    row is correct and untouched — org ALS, `EA010P: Conductivity by PC
    Titrator`, 1272 analyses. With the mojibake row gone, an ACIRL sheet
    carrying that label resolves to nothing under org ACIRL and lands in
    review, which is the correct loud failure mode.
  - The **`Flow Observation / Appearance` split applies to all three observation
    labels**, not just that one — the value text, not the label, carries the
    stage/appearance distinction. A third class ("could not locate", "no access",
    "decommissioned") describes no water at all and correctly yields neither
    analyte; its raw text is preserved on `sample.comments`, as is every
    observation's, split or not.
  - The three observation labels **never co-occur on a real sheet** (0 of 578
    measured), so the "one Stage + one Appearance per sample column" dedupe is
    defensive only.
- **A77** **Dust exposure dating is cross-checked, never assumed.** `Dust Results.Month`
  and `Dust Observations.EXPOSURE DATE` disagree in 8 of 64 real gauge-blocks; in 6 of
  those `Month` holds the *collection* date instead, but in `2400-7538-02` the
  Observations sheet is stale by two years while `Month` is right. **Neither sheet is
  authoritative** — parse both, and route every disagreement to review rather than
  auto-preferring one. (This is what turned an apparent 2025-06 duplicate plus an
  apparent 2025-05 gap into a single data-entry error.)

- **A78** **ACIRL point-code spelling variants are MISSPELLINGS, not old names
  (user, 2026-08-02).** The letter-O-for-zero codes and the padding/dot drift on ACIRL
  water sheets (`B.EO1`, `K.SO6`, `KS07`, `B.MW2`, …) are transcription errors, so they
  take `feature_alias.kind = 'transcription_error'` — **not** `historical_code`, which
  is reserved for a genuinely different former identifier. This resolves 1,375 of the
  5,018 rows that were failing the A75 twin test on the feature rather than the analyte.

  **No hand-written alias rows.** The existing machinery already covers this end to
  end: an unresolved `feature_raw` mints a `feature_alias` row with `kind = 'pending'`
  at commit (`.ct_materialise_feature_aliases()`), it surfaces as an `unknown_feature`
  review item, and an operator attaches it with
  `confirm_feature_aliases(..., kind = "transcription_error")`. Pre-creating the rows
  by hand would bypass that flow and skip the `date_start` bookkeeping the commit path
  does. This ruling is therefore the **answer sheet** for the confirmation step, not a
  migration.

  Verified determinate (each correction lands on exactly ONE feature *uuid* — several
  candidate spellings are already registered `historical_code` aliases of the same
  point, so name-uniqueness is the wrong test):

  | ACIRL code | → feature | rule | rows |
  |---|---|---|---|
  | `B.EO1` | `B.E01` | O→0 | 290 |
  | `KS07` | `K.S07` | insert dot | 309 |
  | `K.SO9` | `K.S09` | O→0 | 285 |
  | `K.SO6` | `K.S06` | O→0 | 188 |
  | `B.LO1` | `B.L01` | O→0 | 132 |
  | `B.SO5` | `B.S05` | O→0 | 76 |
  | `KS05` | `K.S05` | insert dot | 41 |
  | `K.SO7` | `K.S07` | O→0 | 28 |
  | `B.MW2` | `B.MW02` | zero-pad | 14 |
  | `KE01` | `K.E01` | insert dot | 12 |

  **`B.LO2` → `B.L02`; the registry was wrong (ruled 2026-08-02, then verified).**
  `B.LO02` had been registered as a `historical_code` alias of **`B.E01`**. That was a
  registry defect, not a historical fact, and three independent checks agree:
  * **matrix** — `B.E01` is *stormwater*; `B.L01`/`B.L02` are *leachate*. An `L` code
    cannot sensibly be a former name for a stormwater point, and the sibling
    `B.LO01` correctly points at `B.L01`.
  * **chemistry, decisive** — ACIRL writes `B.LO2` on two 2024 Blaxland quarterlies
    citing `ES2419948`/`ES2429912`. The ALS data for `B.L02` under those exact work
    orders matches the sheet **value for value** on three analytes: Ammonia 96.9/77.4,
    Alkalinity 454, TOC 40/139. `B.E01` has **eight** analyses across both work orders
    (Appearance, Temperature, pH) and was recorded `Dry` — no ammonia, alkalinity or
    TOC at all, so the block cannot be its data.
  * **volume** — the ACIRL `B.LO2` block is 66 rows per file, matching `B.L02`'s 41–44
    analyses per work order, not `B.E01`'s 4.

  Repointed via `confirm_feature_aliases()` to `B.L02` with
  `kind = 'transcription_error'`, `confirmed_by = 'R. Shannon'`. No `sample` rows were
  attached to that alias, so no committed data moved: `sample` 15149, `analysis` 97118
  and `feature_alias` 1994 all unchanged, three `change_log` update rows.
  Backup `monitoring_pre-blo02_20260802T073257.duckdb`.

  **Applied to the whole O-form family (2026-08-02).** `B.EO01` and `B.LO01` were
  re-kinded from `historical_code` to `transcription_error` (targets already correct
  and passed back unchanged, so `kind` was the only field to move). All three now read
  `B.EO01 → B.E01`, `B.LO01 → B.L01`, `B.LO02 → B.L02`, all `transcription_error`,
  `confirmed_by = 'R. Shannon'`; `sample` 15149, `analysis` 97118 and `feature_alias`
  1994 unchanged. Backup `monitoring_pre-okind_20260802T074215.duckdb`.

  **Not covered by this ruling:** the 25 remaining unmatched codes (3,587 rows) are not
  spelling variants at all — they are descriptive human names (`EFFLUENT`, `BORE 2`,
  `CRIPPLE CREEK INLET`, `LEACHATE DAM 1`, `MP # 1`…) plus a few odd forms
  (`B.SO1 S1`, `S1`, `S22`, `E1`, `BORE10A`, `BORE12`). Those take
  `kind = 'descriptive'`, and R-6.7's `report$feature_aliases` mapping (91 point→name
  pairs recovered from the sheets themselves) is the evidence for them.

  Measurement: `scratchpad/feature_misspell3.R` → `feature_misspell.rds`.

- **A79** **ACIRL data imports unconditionally; ALS supersedes transcriptions (user,
  2026-08-02).** Supersedes A75's drop/review scheme and **relaxes A74**.
  * **A74's whole-file quarantine is withdrawn.** A missing ALS source no longer holds
    back a workbook (17 files / 644 rows). ACIRL data is NATA-certified and is imported
    on its own; the ALS citation is still recorded, it just no longer gates.
  * **Two categories, already encoded in the data — no new column, no migration:**
    an ACIRL row on a `method = 'field'` lab_method is a **field measurement** (kept
    permanently, ranked ABOVE lab — the sample degasses before the lab sees it); every
    other ACIRL row is a **transcription** of an ALS-reported value (one measurement,
    two records) and is **provisional — deleted when the ALS equivalent commits**.
    `db_delete()` writes the old row to `change_log`, so a transcription discrepancy
    stays auditable without duplicate rows in `analysis`.
  * "Calculated" values are NOT a third category (user): SAR, Ionic Balance, the
    alkalinity speciation trio and calculated TDS are all reported BY ALS under ALS
    method codes (`EA006`, `EN055`, `ED037P`, `EA016`), so ACIRL copying them is an
    ordinary transcription.
  * **Matching keys on feature + datetime + resolved ANALYTE UUID, never the raw
    label** (ACIRL writes `Total Suspended Solids`, ALS `Suspended Solids (SS)`, both
    → `TSS`). Exactly one folded `lab_method` name is ambiguous
    (`>C10 - C16 Fraction` → `TRH-C11-C16` / `TRH-F2`); ambiguous keys go to review.
  * **Read-time ranking**, one ordering for both levels:
    `ORDER BY (lm.method = 'field') DESC, (lm.organisation = 'ALS') DESC`.
    `EN67 - Client Supplied Data` ranks as field. Only six analytes have both a field
    and a lab method — pH, EC, DO, TDS, TSS, Appearance — so it is a no-op elsewhere.
  * Note the **legacy system already implemented A75's policy**: zero existing
    (feature, date, analyte) triples carry both an ALS row and a non-field ACIRL row.
    So this is a deliberate change of policy, starting from a base with no duplicates.
  **Two corrections and one open question, from implementing R-8.9 (Claude,
  2026-08-02, all measured — flagged here for Robin).**

  1. **"Every other ACIRL row is a transcription" is wrong as written.** All
     four of ACIRL's non-field `lab_method` rows in the live registry are
     **dust** (`AS3580.10.1-2003` — 310 analyses). ALS does not run deposition
     gauges, so ACIRL dust is ACIRL's OWN lab measurement: a third category,
     never superseded. The discriminator used is the method code, and it is
     measured rather than invented — **zero** ACIRL lab_methods have a NULL
     `method` today and ACIRL water sheets carry no method codes at all, so the
     rule is a provable no-op on every row now in the database.
  2. **`EN67 - Client Supplied Data` must rank as field on BOTH sides.** A75
     already said it ranks as field for the read-time preference; it matters
     here too. EN67 is an *ALS* method (`pH`, one row) meaning the client
     supplied the number and ALS reported it back — our own field reading
     round-tripped. Treated as an ordinary ALS lab row it would delete a
     committed ACIRL pH transcription: a field reading superseding a field
     reading.
  3. **The TSS pair — MEASURED AND SETTLED as transcription; the remaining
     question is only what to do about the registry.** `Total Suspended Solids`
     is both the ACIRL sheet label and the ALS analyte name, so no name test
     separates a field estimate from a transcription. A75's value comparison
     was the mechanism and A79 removed it as a *runtime* rule — but nothing
     stopped running it **once**, off the saved corpus measurement, to settle
     the classification. Two independent lines of evidence, and they agree
     (`scratchpad/a79_tss_verdict2.R`):

     * **These values carry ALS's own reporting limit.** 284 of the 678 rows
       (41.9%) are written `<5`, and `<5` is the *only* `<` value that appears.
       ALS's TSS method (`EA025: Total Suspended Solids dried at 104 ± 2°C`)
       has `rl_low = 5`, and 345 of its recorded non-detects sit at exactly
       that limit. A field estimate cannot produce "<5 mg/L" — that is a
       laboratory reporting limit, and it is *ALS's*.
     * **Where the values can be compared they are identical.** 362 of the 678
       have an ALS TSS row at the same cited work order and feature;
       **355 (98.1%) match exactly**. And the 7 that do not are not
       independent measurements — they are *permutations of the ALS numbers*:
       `B.S01`/`B.S03` carry each other's values (`<5`/`68` against ALS's
       `68`/`5`), as do `B.MW08`/`B.MW11` (`30`/`118` against `118`/`30`), plus
       one single-digit misread (`6` for `8`). Even the mismatches prove
       copying.

     TSS is gravimetric — filter a known volume, dry at 104°C, weigh — so this
     is also what the method implies. And the registry already agrees: ACIRL's
     `Total Suspended Solids` and `Suspended Solids (SS)` **`field`** methods
     both carry **zero analyses**, so the legacy import never treated an ACIRL
     TSS row as a field measurement either.

     **Incidental, and worth keeping: this is the first measurement of ACIRL's
     transcription error rate — 7 of 362, ~1.9%** — and every one of them is
     the kind of error (a column offset) that a per-value audit trail catches
     and a whole-file gate never would.

     **RULED (Robin, 2026-08-02): option (a) — DONE.** The two unused ACIRL
     `field` TSS `lab_method` rows were deleted from the live database
     (`29cfea72…`, `c8b85ce2…`; `lab_method` 361 → 359, every other table
     unchanged, 0 orphans, backup
     `monitoring_pre-tss-field-methods_20260802T073901.duckdb`, verified by md5
     *and* row counts). Both carried **zero** analyses and were referenced by
     nothing. `Total Suspended Solids` can no longer resolve to a field method
     at all, so an incoming row mints a NULL-method dangling method and R-8.9
     supersedes it like any other transcription.

     The config key `field_analytes_diff_required` is renamed
     **`acirl_transcription_labels`** — its old name encoded A75's value
     comparison, which no longer exists and whose question is now answered.
     Behaviour is unchanged (the labels still take the ALS-candidate path); the
     name and the skip reason (`transcription_label`) now say why.

     This does foreclose A76's "field-estimated TSS" should ACIRL ever start
     doing it. That is deliberate and cheap to reverse: re-registering an ACIRL
     `field` TSS method restores the old behaviour, and the evidence would be a
     TSS value that is *not* `<5` and *not* equal to ALS's.

  **"Repair the database where ACIRL disagrees with ALS" — MEASURED, and there
  is nothing to repair (Claude, 2026-08-02, `scratchpad/repair00_measure.R`,
  `repair01_identical.R`).** Robin asked for this on the premise that ALS is
  right and ACIRL is wrong. The premise is correct *for transcriptions* — and
  the database contains none:

  * **Zero** ACIRL analyses sit on a NULL-method (transcription) `lab_method`.
    Every one of the 16,420 ACIRL analyses is either a `field` reading (16,110)
    or ACIRL's own dust lab work (310, `AS3580.10.1*`). Cross-checked two ways:
    by the triple-collision query (0 pairs) and by enumerating every ACIRL
    method that carries analyses at all.
  * The **898** (feature, date, analyte) triples carrying both an ACIRL row and
    an ALS lab row are all `field`-vs-lab — pH 517, EC 381 — and they are
    **genuinely different measurements**, exactly as A79 says: median absolute
    difference **0.52 pH units (7.8% relative)** and **22 µS/cm (8.1%)**.
    Overwriting them with the lab number would destroy 898 real field readings
    and do precisely what A79 exists to prevent.
  * Only **9** of the 898 have identical values (7 EC, 2 pH). They are
    coincidences, not copies: **every one matches on a single analyte of the
    two measured on that visit** — not one visit matches on both pH and EC,
    which is what a copy would look like. The matching EC values are whole
    numbers (775, 96, 230, 225, 82, 29, 212) and 984 of 1,026 ACIRL pH readings
    carry one decimal place, so chance agreement across 898 pairs is expected.

  So the repair was not made, because making one would have been the damage.
  The transcription errors that *do* exist (the TSS transpositions, ~1.9%) are
  in the ACIRL **workbooks**, which have never been ingested — no ACIRL file has
  ever reached this database. They will be caught at import by R-8.9, one value
  at a time, with the discrepancy preserved in `change_log`.

  **SEQUENCING, measured and load-bearing: the dangling-method confirmation
  pass must precede the transcription import, not follow it.** 215 of the 218
  transcription labels have no ACIRL `lab_method` at all today. Importing them
  first mints dangling methods, and a dangling method has no `uuid_analyte`, so
  R-8.9's twin test cannot fire for any of them — leaving ~38,000 provisional
  rows nothing can ever supersede. That is the silent-duplicate failure mode
  A79 inverts. This reorders steps 4 and 6 of the ACIRL plan.

- **A80** **ACIRL data is filed against the ACIRL REPORT NUMBER; the ALS work order
  becomes a CHILD project of it (user, 2026-08-02).** The ACIRL report is the parent
  engagement; the ALS job is the lab work within it. `project` already supports this
  via `uuid_parent`/`uuid_root`.
  **The report number is not unique, and the hierarchy is what makes that safe.**
  Measured over 154 workbooks: 132 distinct `REPORT NO:` values, none missing. Of the
  16 numbers appearing on more than one file, **13 are one report re-saved or revised**
  (same sample date and same cited ALS work order — byte-difference alone is NOT a
  discriminator) and **3 are TRUE collisions** — different sampling events sharing a
  number. The clearest is `2400-7430-01`: May 2024 (`ES2417748`) and a year later
  (`ES2515829`).
  So samples must attach to the **child** (the ALS work order) wherever one is cited,
  and to the parent only when none is — a reused ACIRL number then yields one parent
  with two children and the events stay separate, instead of silently merging.
  Dust-only workbooks cite no ALS order and attach to the parent directly.
  The report number is read from the front-page `REPORT NO:` cell, **never from the
  filename** — the ACIRL filename trap is untouched.

  **A repeated report number is an ACIRL DATA-ENTRY ERROR and must be FLAGGED (user,
  2026-08-02)** — not quietly absorbed by the hierarchy. A report arriving with a
  number already used for a different sampling event goes **back to ACIRL to be
  reissued**. Review item: `duplicate_report_number`.

  **The discriminator is (sample date, cited ALS work order) — not repetition of the
  number, and not the content hash.** Of 16 numbers appearing on more than one file,
  **13 are one report re-saved or revised** and are NOT errors; flagging those would
  bury the real ones. Only a *different* sampling event under the same number is the
  defect. Under the A80 hierarchy the trigger is exact and cheap: this ACIRL parent
  already has a child ALS work order, and the incoming workbook cites a different one.

  **The data still imports.** Because samples attach to the CHILD (the ALS work order),
  a reused parent number cannot corrupt the data — the events stay separate either way.
  The flag exists so ACIRL fixes their process, not to withhold the results.

  **Prospective only (user, 2026-08-02): the historical three are NOT to be chased.**
  They are recorded below as evidence for the rule and to explain the collisions in the
  corpus, not as a work list. The flag fires on reports arriving from now on.

  The three already in the corpus, for reference only:

  | report no. | events it was used for | note |
  |---|---|---|
  | `2400-7222-12-05` | 2022-12-21 / `ES2246501` and 2022-12-28 / `ES2246801` | two consecutive "Special Wednesday" reports |
  | `2400-7286-01-03` | 2023-01-11 / `ES2301026` and 2023-01-18 / `ES2301817` | the second file is *named* `…-01-04` — the FILENAME is right and the front-page `REPORT NO:` cell is stale |
  | `2400-7430-01` | 2024-05-29 / `ES2417748` and 2025-05-27 / `ES2515829` | worst of the three: the second is the **May 2025** report carrying both the 2024 filename and the 2024 report number; only its sample date and ALS order are correct |

  **THE CAMPAIGN IS THE GRANDPARENT (user, 2026-08-02).** Measured before
  implementing, and it changed the shape: **116 of the 129 ALS work orders our
  ACIRL workbooks cite already have a `uuid_parent`**, and it is a *campaign* —
  `Monthly monitoring` (27), `2022 March pollution incidents` (27), `EPL quarterly`
  (24), `EPL annual` (12), `Melaleuca swamp groundwater contamination` (11),
  `Cutoff wall failure 2023` (7), `Post-closure monitoring` (7),
  `2021 stormwater dam contamination` (1). A row has one parent, so A80 taken
  literally would have **overwritten** the record of *why the sampling happened* —
  human-curated and not recoverable from anything else we hold.

  Robin's ruling: **insert the ACIRL report between them, do not displace.**

  ```
  Campaign  "EPL quarterly"            uuid_parent = NULL      (root)
    └── 2400-7400-06-01  ACIRL report  uuid_parent = campaign
          └── ES2420251  ALS work order uuid_parent = ACIRL report
  ```

  So the ALS work order's `uuid_parent` moves campaign → ACIRL report, and the
  ACIRL report takes the campaign as *its* parent. Nothing is lost; the campaign is
  one level further up. `uuid_root` stays the topmost ancestor for both. Where a
  cited work order has **no** existing parent (13 of 129), the ACIRL report simply
  becomes the root of that pair.

  This also matches a precedent already in the database that runs against the naive
  reading: **71 projects are already named with ACIRL report numbers**
  (`2400-7222-01`…), all typed `Monthly gas monitoring`, all **children** of a
  campaign of that name, carrying **12,478 samples**. Filing an ACIRL report as a
  project keyed on its report number is established practice here; what A80 adds is
  the level below it.

  **A report number colliding with an existing project MERGES into it (user,
  2026-08-02).** Six of the corpus's 132 report numbers already exist as those gas
  rows — `2400-7222-01`, `2400-7222-02`, `2400-7222-04`, `2400-7222-10`,
  `2400-7286-07`, `2400-7286-09`. The incoming water samples attach to the existing
  project row of that name rather than minting a parallel one or raising a flag:
  `.ct_ensure_project()`'s find-by-name behaviour is already correct and needs no
  namespacing. This does **not** weaken `duplicate_report_number`, which is keyed on
  (sample date, cited ALS work order) and fires prospectively on *newly arriving*
  reports — a pre-existing gas project of the same number is not a new sampling
  event under a reused number.

  **Three cases A80 did not cover, decided at implementation time (Claude,
  2026-08-02, from measurement — flagged here for Robin to overrule).** Built as
  PLAN-09 R-9.14; all three are loud rather than silent, and none destroys data.

  1. **A workbook citing TWO ALS orders** (measured: 5 workbooks, 347 of 6,208
     result rows) makes **both** children, but its samples attach to the
     **parent**. One event resolves to one `uuid_project` and the per-row ALS
     citation is not carried past the sheet, so they cannot be split between the
     two children. Attaching them all to one arbitrarily would assert a lab job
     we cannot evidence. *If this matters, the fix is in the adapter — carry the
     sheet's ALS order onto each row — not here.*
  2. **An ALS order cited by TWO DIFFERENT report numbers** (measured: 4 of 129,
     e.g. `ES2245792` by both `2400-7222-12-01` and `2400-7222-12-04`). A row has
     one parent, so the second report cannot also adopt it. The existing parent
     **stands** and a new `project_parent_conflict` review item is raised. First
     claim wins, and it is visible rather than silent.
  3. **Two cited orders under DIFFERENT campaigns** (measured: exactly one
     workbook, `2400-7286-03` — `EPL annual` and `2022 March pollution
     incidents`). There is no campaign to promote without asserting a membership
     we cannot justify, so the report becomes a **root**, neither order moves,
     and both are flagged. Same principle as the grandparent ruling itself:
     never overwrite a curated parent.

  A parent that is already set is **never overwritten** — that is what makes the
  merge safe, and what makes the whole thing order-independent when
  `archive_file()` mints the report row before any citation is known.

- **A81** **Feature-alias rulings (user, 2026-08-02).** `BORE 11` → `B.MW11`.
  `CRIPPLE CREEK INLET` → **`B.S04`**, confirmed against the registry rather than
  assumed: `B.S04` already carries the aliases `B.CRIPPLE` and `Diversion pipe inlet`,
  while `B.S12` carries `B.SPURWOOD` and `Upstream Spurwood Creek` — a different
  watercourse. It pairs with `CRIPPLE CREEK OUTLET` → `B.S05`.
  The ~212 dangling ACIRL `lab_method` confirmations are to be done as **one batch
  pass**, not spread across ingests.

- **A82** **The read-time preference is a `preference_rank` COLUMN, not a filter
  and not an `ORDER BY`** (`dev/migrations/005-preference-rank.R`, 2026-08-02).
  A75/A79 settled the *rule* — field beats lab; among lab, ALS beats ACIRL — but
  not the mechanism. Three implementation-time decisions, each forced by
  measurement rather than argued:

  1. **Every row is kept; `preference_rank = 1` marks the canonical one.** The
     alternative (dedupe in the view) would drop 972 of `v_measurement`'s 97,118
     rows. `v_measurement*` has **no in-repo consumer** —
     `dev/epa-monitoring-report.R` builds its own base query and says so at its
     assumption C — so every consumer is external and invisible to us; a column
     is additive for all of them, a row drop silently changes an answer some
     spreadsheet already produces. Both rows are also real data: the out-ranked
     lab pH is not wrong, it is a lab pH. Keeping cardinality identical is
     additionally what lets the verify gate assert "the window function changed
     no view's row count" as a hard failure. Consumers opt in with
     `WHERE preference_rank = 1`.
  2. **The partition is keyed on the SYDNEY CALENDAR DATE, not `datetime`.** The
     design as recorded said "per (feature, datetime, analyte)". Measured
     (`scratchpad/m005_partition_probe.R`): that key finds only **916** of the
     **931** contested partitions, because **54** of them have the field row and
     the lab row at different datetimes on the same day — the observed shape is
     a field reading at 00:00 and its lab twin at 00:01, one visit written by
     two clocks. Keyed on `datetime` those become partitions of one and the
     ranking silently does nothing for exactly the rows a human most expects it
     to. The date expression is 004's `.mig004_sydney_date_expr`, reused from
     one constant so the partition and the projected `date` cannot drift.
  3. **`a.uuid` is a required third ordering key.** **74** live partitions hold
     TWO field rows, which `is_field`/`is_als` cannot separate, so without it
     `preference_rank` is whatever the scan order was — a consumer could get a
     different "canonical" pH on two runs of the same query, which is worse than
     the ambiguity this migration removes. Arbitrary, but the same arbitrary
     answer every time.

  **Two corrections made 2026-08-02 (overnight), after measuring the RANKED
  OUTPUT on a copy of the live database rather than reasoning about the SQL —
  both landed before 005 was ever applied:**
  - **`preference_rank > 1` returns 2,471, not 972**, and conflating the two is
    the easiest mistake to make about this migration. 972 is the FIELD-VS-LAB
    figure; the rank counts every partition holding more than one row, whatever
    the reason. It decomposes exactly (`scratchpad/m6a_972.R`): field-vs-lab 931
    partitions → 972 out-ranked; **two or more LAB rows 706 partitions → 1,460**;
    two or more FIELD rows 39 → 39. The 1,460 were never counted because the
    design question was only ever about field-vs-lab, and **494 of those 706
    partitions hold DIFFERENT values**. `WHERE preference_rank = 1` returns
    94,647 of 97,118, not 96,146.
  - **`s.uuid` was added as the third ordering key, before `a.uuid`.** With the
    analysis uuid as the only tiebreak, each analyte chose its canonical row
    independently, and the analysis uuid bears no relation to the sample — so on
    a feature/date holding two samples, `preference_rank = 1` could select a
    DIFFERENT sample per analyte. **62 live feature/date groups did**
    (`scratchpad/m6a_frankenstein.R`). The dust triple at B.D07 on 2021-08-01 is
    the proof: canonical combustible came from one gauge, incombustible and
    total from the other, so the rank-1 rows read 0.6 + 2.2 against a total of
    4.2. With the sample key they read 0.6 + 0.7 = 1.3 and the triple sums. The
    residual 40 groups are structural — their two samples carry different
    analyte sets, so no ordering can put every analyte on one sample. Pinned by
    fixture P7, which is verified against a mutation applied to the SQL **and**
    its R oracle together (the only case the independent oracle cannot catch —
    the `.RC_FIELD_METHODS` lesson).

  Two corrections to earlier records, both measured:
  - **931, not 898.** The 898 figure was ACIRL-field-vs-ALS-lab joined on the raw
    `sample.date`; 931 is field-vs-lab regardless of organisation, keyed on the
    Sydney date the views actually report — the population the views see. pH 560
    field / 541 lab, EC 406 / 396, nothing else.
  - **`.mig004_base_n()` over-constrained the four mask views**, requiring a
    resolvable `lab_method` they never joined. It has never fired (zero such rows
    live) — a gate correct only because its failing case is empty. `005`'s oracle
    models each view's real join semantics instead; the mask views' new
    `lab_method` join is a **LEFT** join for the same reason, so cardinality
    preservation is structural rather than lucky.

  `EN67 - Client Supplied Data` ranks as field, read from `.RC_FIELD_METHODS`
  (`R/reconcile.R`) rather than copied — the views and R-8.9's supersession test
  must never disagree about what a field reading is. Mutation-confirmed: a
  mutation to that list changes the view AND the migration's own rank oracle
  together, so only the fixture tests catch it.

- **A83** **Every ACIRL transcription label gets its own ACIRL `lab_method`,
  minted BEFORE the import, with `method = NULL` and `units = NULL`**
  (`dev/migrations/006-acirl-transcription-methods.R`, 2026-08-02). A79 settled
  that a transcription is superseded by its ALS twin; A83 is what makes that
  reachable.

  **Why it must precede the import.** Analyte resolution is **per organisation** —
  `.rc_resolve_one_analyte()` filters on `organisation == org` in both its exact
  and its folded branch, so an ALS `Calcium` method does not resolve an ACIRL
  `Calcium` row (verified empirically, `scratchpad/m6a_verify_acirl.R`, not read
  off the source). Of the **215** distinct transcription labels the adapter
  emits, exactly **one** has an ACIRL method today. Importing first would mint
  214 dangling methods; a dangling method has no `uuid_analyte`; and A79's twin
  test keys on the resolved analyte uuid — so all **34,137** candidate rows in
  `unprocessed/` would commit as permanent silent duplicates.

  1. **`method = NULL` is the transcription marker, not an omission.**
     `.rc_lab_kind()` returns `acirl_transcription` iff an ACIRL method's
     `method` is NULL; any code makes it `acirl_own_lab` (ACIRL's dust work) and
     exempt from supersession forever. The water sheets carry no method codes —
     `als_candidates` has no `method_raw` column at all — so NULL is also what
     the import itself would have written.
  2. **`units = NULL`, against the first instinct, because measurement said so.**
     `lab_method.units` is INERT for value conversion: `.rc_resolve_units_values()`
     converts from the incoming ROW's `units_raw` to the ANALYTE's units and never
     reads the method's. Its only other use is the units-drift sighting, which
     fires only for DANGLING methods. **358 of the 359 live `lab_method` rows
     carry NULL units**, including all 19 existing ACIRL ones. Recording the
     corpus units would have invented a convention the database does not have,
     for a column nothing reads.
  3. **The mapping is reviewable DATA, not code** — a CSV carrying `label`,
     `analyte`, `uuid_analyte`. The `analyte` NAME is redundant with the uuid
     **deliberately**: it is what a human reviews, and checking the two against
     each other is the only way to catch a hand-edited row whose name and uuid
     drifted apart, which would link a label nobody reviewed.
  4. **The SUCCESS gate asks the PRODUCTION resolver, not the rows it inserted.**
     "Did the INSERT store what I passed it" is not the property that matters;
     "will the import now resolve this label to this analyte, and classify it as
     a transcription" is. `.rc_resolve_one_analyte()` + `.rc_lab_kind()` share no
     mechanism with the INSERT, so the two cannot be wrong together.

  Three findings recorded because they cost real measurement:
  - **A shared folded key is only a defect when the analytes DISAGREE.** The
    obvious gate — refuse any two labels folding to one `.rc_method_key()` — is
    too strict: `.rc_resolve_one_analyte()` returns `ambiguous` only when the
    folded survivors span more than one analyte. The live corpus has exactly one
    such pair (`Azinphos Methyl` / `Azinphos-methyl`, one analyte), and the
    strict gate would have dropped a real label for a danger that is not there.
  - **A "this label already resolves" gate is UNREACHABLE** and was deleted
    rather than shipped. Resolving under ACIRL requires an ACIRL method whose
    folded key equals the label's — which the collision gate already refuses.
    "Already resolved" is a strict subset of "already collides".
  - **`Total Dissolved Solids` is the third unused ACIRL `field` method whose
    name is really a transcription label** (0 analyses, not on the A76
    allowlist, 382 corpus rows), after the mojibake EC (deleted 2026-08-01) and
    the two TSS (deleted 2026-08-02). Its 382 rows would import as FIELD
    readings: never superseded, and ranked ABOVE the real ALS value by 005. A
    sweep of every ACIRL `field` method (`scratchpad/m6a_field_sweep.R`) shows
    it is the **only** one left — the family is closed. Awaiting Robin's ruling;
    not applied.

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

Post-MVP: **11** (feature_alias / commit-everything) and **12** (review
remediation) are independent of each other — land whichever is ready and rebase
the other's tests. **13** (the alias migration) is independent of plan 11's
*code* but is a **hard prerequisite for pointing plan-11 code at the live DB**
(A68). **14** (registry data remediation) depends on 13, because it writes the
`lab_method.units` / `conversion_constant` columns that 13 restores (A69).
