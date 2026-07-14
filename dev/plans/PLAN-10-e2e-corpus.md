# PLAN 10 — End-to-end, idempotency, router matrix, real-corpus gates

**Owns:** `tests/testthat/test-e2e-pipeline.R`, `test-e2e-corpus.R`,
`tests/testthat/helper-corpus.R`. **Depends on:** all previous plans landed
and green. This plan writes tests only — any production defect it finds goes
back to the owning plan as a delta, not fixed here.

## R-10.1 Router cross-match matrix

Using plan-03 `router_matrix()` over **every fixture file** shipped by plans
04/05/06 (glob `tests/testthat/fixtures/*/*`, excluding READMEs): each file
is claimed by exactly one adapter at its winning tier; the corrupted-ESdat
fixture and cruft files are claimed by none. Criterion: the matrix printed on
failure (debuggability requirement — use `testthat::expect()` with an
informative failure message, not bare `expect_true`).

## R-10.2 Full-pipeline e2e (synthetic)

Temp input dir assembled from all fixture families + cruft + subdirectory
(as plan 09 R-9.5 but asserting *DB content*, not just the report):
- committed values spot-checked end to end: the fixture's known `<0.1`
  fluoride row arrives as `analysis.value = 0.1`, `quantified = FALSE`,
  `rl_low` converted to analyte units; the µS/cm→mS/cm case lands converted;
- `v_measurement` joins cleanly for every new analysis (no orphan uuids);
- provenance chain intact (A1): every committed analysis has a change_log
  insert row whose `source_hash` matches an `asset.hash`, and that asset's
  archive copy byte-equals a file in the input dir;
- ACIRL field rows: date-only samples have `datetime` NA, `date` set (A11);
  sampler recorded on `sample.person`;
- QC skip counts in the report equal the fixture's known QC row count;
  review_queue contains exactly the engineered unknowns (typo feature,
  unknown unit) and nothing else.

## R-10.3 Idempotency (the design's load-bearing property)

Run `ingest_dir()` twice on the same temp dir; between runs capture full
table row counts + `change_log` count. Second run: zero deltas everywhere,
report shows all files terminal. Then **third run after
`touch`ing** (mtime bump, content unchanged) every input file: still zero
deltas (hash-keyed, not mtime-keyed). Then copy one input file to a new name
(same bytes): zero deltas, one new `ingest_sighting`.

## R-10.4 Revision supersede e2e

Fixture pair `XX1234567_0_XTAB.csv` then `XX1234567_1_XTAB.csv` (one value
changed). Ingest v0, then add v1 to the dir and re-ingest: the changed value
is updated in place (same analysis uuid), `change_log` holds old/new, the
unchanged values are `already_present`, and no duplicate sample/analysis rows
exist. The v0 file's state stays `archived` (history is not rewritten).

## R-10.5 Real-corpus gates (A3 — skipped unless `SAMPLETIDY_CORPUS` set)

`helper-corpus.R`: `corpus_path()`, `skip_if_no_corpus()`. The env var points
at a local copy of real `input/` files (never committed). Tests, each
`skip_if_no_corpus()`:
- **route sweep:** `router_matrix()` over every corpus file — no adapter tie;
  count of unclaimed files printed for information (fails only on ties, since
  unclaimed-but-real formats are post-MVP work, not defects);
- **parse sweep:** every corpus file claimed at `exact`/`format` parses
  without error; `ir_validate()` passes on every output; aggregate skip
  reasons tabulated to console;
- **cross-format equivalence (the plan-05/02 empirical claims re-verified,
  [MEASURE TWICE]):** for each corpus work order having both ESdat
  Chemistry2e and a crosstab file: `Normal`-row (feature, analyte-normalised,
  value_raw) sets are equal after mojibake normalisation; any inequality
  fails with a diff listing;
- **dry-run against a DB copy:** `ingest_dir(corpus, db = <temp copy of the
  real monitoring.duckdb if SAMPLETIDY_CORPUS_DB also set>, dry_run = TRUE)`
  completes and reports `already_present` > 0 (old-pipeline overlap detected
  — DESIGN §7) with zero writes. This is the pre-first-real-run confidence
  gate.

## R-10.6 Package gates

`devtools::check()` passes with no ERROR/WARNING; `NAMESPACE` exports equal
the CONTRACT public API exactly (test compares sorted export list);
DESCRIPTION Imports equal the CONTRACT-pinned set (drift guard).
