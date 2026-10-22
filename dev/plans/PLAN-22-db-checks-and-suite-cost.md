# PLAN-22 — Standing DB checks, and the cost of the test suite

_Status: **SCOPED** 2026-10-22, nothing built. Measured on live at marker 1072 (570 MiB,
111,642 analyses) and on a full serial suite run (729 s, 2,029 tests)._

Why: `v_measurement_epa` returned 0 rows for months and nothing noticed. Nothing checks the
live DB's invariants between migrations. Each migration hand-writes its own post-checks, and
those decay: once 072 dropped a view, the already-migrated re-verify of 022 and 070 stopped
passing.

## Part A — `db_checks()`

### A1. Shape
- New `R/db-checks.R`. A check is data: `db_check(name, sql, description, tier, severity)`.
  Its SQL returns the offending rows, and zero rows is a pass.
- `db_checks_core()` returns the generic set.
- `db_checks(con, tier = "hourly", extra = NULL, params = db_checks_params(), sample_n = 5)`.
  - Tiers nest: `hourly` ⊂ `migration` ⊂ `all`.
  - `extra` is how a deployment adds its own set. A duplicate name is an error.
- It returns one row per check: `name, tier, severity, status (pass|fail|error), n, ms`, the
  first `sample_n` offenders as a list column, and `message`. It never aborts; a SQL error
  becomes `status = "error"`.
- `{param}` tokens are filled from `db_checks_params()`: `min_date`, `bbox` (empty by
  default, so no coordinates are hard-coded), `tz` and `mask_variants`.
- Vocabularies are interpolated from the R constants that already define them
  (`.st_ingest_transitions`, the alias kinds), so each has one source.
- Two rules are computed in R rather than copied into SQL, so they stay single-sourced: alias
  key normalisation (`.rc_feature_key()`) and fraction from method code
  (`.rc_method_code_raw()`).

### A2. Checks and cost (warm median on live)

| Tier | Checks | Cost | Runs |
|---|---|---|---|
| hourly | 28 + `view_nonempty` | 77 ms + 150 ms | in `import_status()`, which refreshes on the first check of a Sydney day or when the DB changed |
| migration | the hourly set + view coverage/fan-out/rank-1 uniqueness, `expected_constraints_present`, `schema_version_*`, `fraction_matches_code` | ~0.6 s | before and after every migration apply |
| on-demand | resolved-review and change_log dangling refs, `change_log_shape`, `alias_window_ambiguous`, `sample_in_feature_window`, geometry vs lon/lat | ~30 ms | by hand or weekly |

- **Hourly checks:**
  - orphan references the DB does not enforce: alias→feature, sample→project, project
    refs, asset/ingest_file/lab_qc links, open review-item refs;
  - duplicates: analysis on the same sample + lab_method, asset hash, lab_method key, and
    sample identity where `datetime` is NULL (the case `ux_sample_identity` cannot see);
  - alias invariants: exactly one self alias per feature, and a pending alias always has a
    NULL feature and an open review item;
  - vocabularies: fraction, alias kind, ingest state, review status, mask variant, flow;
  - analysis value shape;
  - hash format;
  - date sanity, and that date windows are ordered;
  - coordinates are finite and inside the bbox;
  - the core schema version.
- **Excluded:** FKs DuckDB already enforces. Re-checking them gains nothing.
  `expected_constraints_present` instead catches a constraint lost when a table is rebuilt.
- Cost is not a concern at any tier. No hourly check takes more than 20 ms. The views are the
  only expensive part (~125 ms each for `v_measurement*`, since the window is computed in
  full), and their cost grows linearly with the number of analyses.

### A3. Where failures surface
- **Hourly:**
  - The checks run inside `import_status()` on the connection it already has open.
  - Error-level failures go to `problems`, warnings to a `## DB checks` count, and the full
    result to `.import-status.json`.
  - **Failures never block an import.** The write path's guards already refuse bad writes,
    and a failure is usually old state that needs curating.
- **Migrations:** a shared helper, `mig_db_checks_gate()`.
  - It takes a baseline before the change.
  - It re-runs the checks inside the transaction, before COMMIT.
  - It rolls back only on a **new** failure: a check that wasn't failing before, or a key
    that newly offends. Failures already present are printed but don't block.
  - `allow =` covers a migration that changes an invariant on purpose.
  - This replaces each migration's hand-written generic re-verify. Plan-specific sha1 and
    count checks stay in the migration.
- **Deployment:** bmcc-monitoring passes its own set through `extra`:
  - every EPA licence point maps to a feature with an EPA mask, and every licence pollutant
    to an analyte mask;
  - site codes are valid;
  - the site bbox;
  - every schedule and QC-requirement feature exists;
  - the EPA return's queries return rows for the current reporting year.

### A4. Build (TDD)
- A test writer goes first, working from `seed_db()` plus the views from a test migration:
  - The clean fixture passes every check, to catch false positives.
  - One table-driven case per check: seed exactly one violation and assert that only that
    check fails, with `n == 1` and the seeded key in the sample.
  - A SQL error gives status `error`.
  - `extra` merging and duplicate-name rejection.
  - `{param}` substitution.
  - The gate: an old failure is tolerated; a new failure or a new offending key rolls back.
  - Failures appear in `problems` and in the status json.
- Then a separate implementer.

## Part B — test-suite cost

- **Now:** 729 s serial, 317 s with 6 testthat workers (all green).
- Setup is negligible (3 s overall). The time is in test bodies.

| Step | Saves | Loses coverage? |
|---|---|---|
| B1. Ingest the 35-file e2e corpus once per file through a helper memo, and copy the DB, archive and dirs into each read-only test (six e2e R-10.2 tests, three test-ingest tests) | ~85 s | no |
| B2. Give the orchestration-containment tests (R-12.1, R-12.2 ×2, R-12.7 ×2, same-byte twin, Phase-7b item 7) a minimal corpus; reconcile/commit are already mocked in several | ~48 s | no, but each test's pinned counts must be re-checked first |
| B3. Memoise `gas_parse()` per fixture in test-adapter-acirl-gas, keeping direct calls only where parse-time warnings are asserted | ~28 s | no |
| B4. Drop test-ingest R-9.5 "second run is a no-op" (a strict subset of e2e R-10.3), and merge its two full-corpus dry runs | ~19 s | no |
| B5. Gate the replay tests of spent migrations 001–010 and the QC migrations, plus test-processed-dedupe (a dev/ script), behind `SAMPLETIDY_TEST_MIGRATIONS=true`. Every one is applied to live, the files haven't changed since August, and 011–072 have no replay tests | ~100 s | only if someone re-runs a spent migration |
| B6. `Sys.setFileTime()` instead of sleeps; cache parse trees in the source lints | ~10 s | no |
| B7. Batch `change_log` writes in `db_append()` (one INSERT per row today, ~30% of ingest time). This is a production change, so it gets its own TDD round; the live import gets faster too | 60–100 s | no |
| B8. `Config/testthat/parallel: true` | → ~1.5–2 min overall | no; run it 3–5 times first for flakes (db-connect timing, inbox settle gate) |

- **Order:**
  1. B4, B1–B3 and B6, which only touch tests: about 190 s off, with every rule's coverage
     kept.
  2. B5.
  3. B7.
  4. Finally B8.
- **Expected result:** ~350–380 s serial, ~1.5–2 min parallel. test-ingest.R (167 s) caps the
  parallel wall time until B1/B2 shrink it.

## Part C — what the checks already find on live (rulings in DECISIONS-FOR-ROBIN)

1. 4 duplicate field analyses (same sample, method and value). Fix: delete the copies.
2. 4 ACIRL PDF assets sharing a hash across two projects each (the 057/063 class).
3. 53 sample pairs with the same alias, date and project and a NULL datetime, split into a
   field half and a lab half that share no method.
4. 13 quarantined `ingest_file` rows still keyed by SHA-256. Fix: rehash, as 055 did.
5. 3 features with NaN coordinates and `POINT EMPTY`. Fix: set them to NULL.
6. One alias key with two open-start dated arms (`b.s22` before 2021-04-14).
7. 3 samples dated before their feature's `date_start`.
8. 1 sample whose date and datetime fall on different local days.
9. The 1,412 SHA-256 `change_log.source_hash` rows are history from cutover day (2026-07-23),
   not corruption. That check is on-demand, with an allowlist.
