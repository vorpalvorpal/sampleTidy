# Dispatch 1 — PLAN-11 shared fixture foundation — run evidence

## Self-check: seed_db() builds and every sample resolves through an alias

```
=== every sample resolves through its alias (join check) ===
  sample_uuid uuid_feature_alias alias_found
1      s-0001            fa-0001     fa-0001
2      s-0002            fa-0003     fa-0003
3      s-0003            fa-0010     fa-0010
4      s-0004            fa-0001     fa-0001
```
No orphaned `uuid_feature_alias` (LEFT JOIN found a match for all 4 rows).

## Self-check: fixture reachability

- Ambiguous key `tambig2`: `SELECT DISTINCT uuid_feature ... WHERE alias_key
  = 'tambig2' AND auto_assign` returns **2** distinct features (f-0004,
  f-0005) — genuinely ambiguous, never narrows (both `date_end` NULL).
- Reused key `treused`: same query joined to `feature.date_end` returns
  f-0006 (`date_end` 2020-06-30, defunct at any plausible fixture date) and
  f-0007 (`date_end` NULL, live) — narrows to exactly one survivor (f-0007)
  at any date after 2020-06-30.
- Dangling `lab_method` rows (`uuid_analyte IS NULL`): lm-0008, lm-0009 —
  both present, both isolated from the R-8.6 duplicate-method pair
  (lm-0002/lm-0004) and from each other by distinct `(organisation, name,
  method)`.
- `analysis.units_raw` populated on new rows (an-0002 'µS/cm', an-0003 'pH',
  an-0004 'mg/L'); an-0001 (pre-plan-11 history) left NULL per the migration's
  documented backfill behaviour.

## Full-suite self-run: failure classification

Ran `devtools::load_all(); testthat::test_local()` against the amended
`helper-db.R`. Every one of the 24 existing test files **collected and
executed successfully** — every file printed its header + dot/failure
sequence in the compact reporter; none halted with a parse/source error. No
harness defect found; nothing needed the [HARNESS ROUTING] carve-out.

**All failures are expected TDD-red — missing planned symbol / changed
fixture shape — not collection failures:**

1. **Root cause A — dominant, ~44 of ~45 failing tests** (`test-ingest.R`,
   `test-reconcile.R` [22], `test-commit.R` [5], `test-e2e-pipeline.R` [8]):
   every failure traces to the identical DuckDB Binder Error:
   ```
   Referenced column "uuid_feature" not found in FROM clause!
   Candidate bindings: "uuid_feature_alias", "uuid", "uuid_project", ...
   ```
   `R/reconcile.R` (`.rc_find_existing`, `.rc_three_way`) and `R/commit.R`
   (`.ct_find_or_create_sample`) still query `sample.uuid_feature`, which
   R-11.2/A48 correctly drops from the DDL. This is exactly the plan's
   predicted mass-red state — those modules are amended by a **later**
   dispatch (R-11.5a/R-11.7/R-11.8), not this one.

2. **Root cause B — 1 test** (`test-mutate.R:48`, "R-9.1: db_append() of 2
   rows writes 2 changes"): asserts `n_features == 5` after appending 2 rows;
   now gets 9, because the seed's base `feature` count grew from 3 to 7 (the
   4 new alias-narrowing fixture features, f-0004..f-0007). A changed-
   fixture-shape ripple into a pinned count owned by plan 09's test file —
   flagging for the orchestrator rather than editing `test-mutate.R` myself
   (out of my two-file scope). The fix is a one-line pinned-count update
   (`5` → `9`) whenever that file is next touched.

No other distinct root causes were found among the sampled error messages
(all `test-reconcile.R`/`test-ingest.R`/`test-e2e-pipeline.R` samples showed
the identical "uuid_feature not found" message; `test-commit.R`'s 5 failures
are the same root cause via a different query site inside a
`db_transaction()` rollback).

## [MERI]
Most budget went to reading PLAN-11 (1053 lines) and CONTRACT.md's A48-A55 in
full before touching anything, plus one detour: an initial `Write` of
`helper-db.R` broke R's parser because a SQL comment inside a DDL string used
literal double quotes ("Existing DB schema") that terminated the enclosing R
string early — caught immediately by the self-check `load_all()`, one-line
fix (single quotes), no repeat cost. Otherwise no avoidable cost: the full
suite self-run was needed once and only once, per the brief.
