# PLAN 13 — the alias-indirection migration (operator-run, one-off)

**Owns:** `dev/migrations/001-alias-indirection.R` (new),
`tests/testthat/test-migration-001.R` (new).
**Amends:** nothing. This plan adds no package code and changes no package
behaviour.
**Depends on:** PLAN-11's schema decisions (A48–A51 as amended by A63) being
settled. It does **not** depend on plan 11's code being written, and plan 11
does not depend on this script existing.

Split out of PLAN-11 on 2026-07-22 (A68, user). Plan 11 itself argued the
migration was separable; it has its own procedure and criteria, it is the only
piece that touches the live database, and it named no test file while carrying
test-shaped criteria. It is now a plan.

## The ordering constraint (binding, in both directions)

> **PLAN-11's code must not be run against `monitoring.duckdb` until this plan
> has landed.** Green plan-11 tests are not evidence that it is safe to point the
> new code at the live DB.

- **(a)** R-11.4 removes the `feature_mask` lookup (`R/reconcile.R:76`) on the
  explicit grounds that its `long` names are imported by **step 5** below. Land
  plan 11 without step 5 and every live `mask_long` match regresses to
  `unknown`.
- **(b)** Without this migration the live DB has no `feature_alias` and no
  self-aliases, so `.rc_feature_candidates()` returns zero rows for
  *everything* — **100% of live data would commit dangling.**

Conversely, the plan-11 **test suite** never runs this script (`helper-db.R`
builds its DDL directly and seeds aliases itself), which is what makes the split
safe.

## Which database

Operate only on the authoritative copy (A67), quoting the absolute path in every
log line the script emits:

```
/Users/rjs/OneDrive - Blue Mountains City Council/Sharepoint/
  waste_data - Environmental monitoring/data/monitoring.duckdb
```

Its true shape (A67, re-measured 2026-07-22): 894 features (**19 columns,
including `virtual`**), 15,113 samples, 95,737 analyses, **360** lab_methods,
247 analytes, **14** views of which exactly **6** reference
`sample.uuid_feature`. Do **not** take these from the dashboard's derived copy.

## R-13.1 The migration script


**Operator-run**, with a dry-run mode, never invoked by the package: it is not
called from `ensure_schema()`, `ingest_dir()`, or any package code path (A50).
It **takes a verified backup before it writes anything** (step 1), and is
rehearsed on a copy before the real run — see the two protections below.

Forced into a **table rebuild** by duckdb 1.4.1's inability to drop a constraint
(Evidence), and the `analysis` FK graph means `analysis` must be rebuilt too.
Order matters:

1. **Back up the DB, and verify the backup, before any write** — the first
   action of the script, and a hard precondition for every later step.
   - Copy the live DB to
     `<snapshot_dir>/monitoring_pre-001-alias-indirection_<UTC timestamp>.duckdb`.
     **Do not use `snapshot_db()`**: it is date-keyed
     (`monitoring_YYYY-MM-DD.duckdb`) and R-9.4 pins that a same-day re-snapshot
     **overwrites**, so a second run on the same day would replace the
     pre-migration backup with post-migration state — destroying the only thing
     a restore could use. The timestamped, migration-specific name cannot
     collide with a daily snapshot or with an earlier run of this script.
   - `CHECKPOINT` first so the copy is consistent, and take it while holding the
     `with_db_write()` lock so nothing writes mid-copy.
   - **Verify** the copy: open it read-only and check it reports the same
     `feature`/`sample`/`analysis`/`lab_method` row counts as the live DB.
   - **Abort** — writing nothing — if the copy or the verification fails. No
     backup, no migration.
   - Print the backup's absolute path, and the exact command to restore from it,
     before proceeding.
2. Record `feature`/`sample`/`analysis`/`lab_method` row counts plus a value
   checksum, for the step-11 verify.
3. Create `feature_alias`; insert **894 self-aliases** (`kind = "self"`,
   `auto_assign = TRUE`, `n_seen = 0`).
4. Import **`cypher`**: split on `,`, trim, drop empties, **count** duplicates
   into `n_seen`. ~370 rows: `kind = "historical_code"` (code-shaped) or
   `"descriptive"` (phrases); self-name entries fold into the self-alias via the
   upsert. The **31 ambiguous aliases** get `auto_assign = FALSE` and are
   reported — they must never auto-resolve.
5. Import **`long` mask names**: `kind = "mask_long"`; overlaps with `cypher`
   collapse via the same upsert (increment `n_seen`), never error.
   **Not imported:** `old`, `gas_report`, `EPA`.
6. `DROP VIEW` the 6 views referencing `sample.uuid_feature`.
7. Dump `analysis` to a temp table; `DROP TABLE analysis` (this frees both
   `sample` and `lab_method` from their inbound FK).
8. Rebuild `sample` with the new shape, backfilling
   `uuid_feature_alias` from each row's old `uuid_feature` → that feature's
   self-alias; rebuild `lab_method` with `uuid_analyte` nullable.
9. Rebuild `analysis` (+ `units_raw`, NULL for history) and re-declare its FKs.
10. Recreate the 6 views, joining `sample → feature_alias → feature`.
11. **Verify**: row counts and checksum identical to (2); `sample.uuid_feature`
    gone; **zero** NULL `uuid_feature_alias`; every self-alias reachable; the
    `v_measurement` row count is **unchanged** (the migration must not hide or
    reveal a single measurement).

Steps 3–10 run inside **one** transaction, so a mid-migration failure rolls back
rather than leaving a half-rebuilt DB — the backup is the second line of
defence, not the first.

Criteria: **the script writes nothing until a verified backup exists (step 1) —
pinned by a test that makes the backup copy fail and asserts zero writes**; a
same-day second run does not overwrite the first run's backup (the `snapshot_db()`
trap — pinned); idempotent (re-run inserts nothing, double-counts nothing);
`feature.cypher` left untouched (retiring it is a later step, once the alias
table has proven itself); dry-run prints the counts it would insert and writes
nothing; the step-11 verify is a hard gate that aborts on any mismatch; a failure
in steps 3–10 leaves the DB unchanged.

**Two distinct protections — the operator needs both, they are not substitutes:**
1. **Rehearse on a copy.** Run the whole script against a copy of the live DB
   first and review the printed counts. This is what catches a *wrong* migration
   (bad `n_seen`, a mis-imported alias) — a backup cannot, because a successful
   restore of a wrong migration still leaves you where you started.
2. **Back up before the real run** (step 1). This is what catches a *failed* or
   interrupted migration. Required even after a clean rehearsal, because the real
   DB is not the copy — it holds rows the rehearsal never saw.


## R-13.2 Restore `lab_method.units` and `lab_method.conversion_constant` (A63)

Both columns were in WEM.data's `labDF` (`make new dfs.R:63`) and were lost when
this duckdb was built — a schema **regression**, not a design decision. Plan 11
(D7 reversed) puts the reported units on the method, so they must exist.

- `ALTER TABLE lab_method ADD COLUMN units VARCHAR` and
  `ADD COLUMN conversion_constant DOUBLE`. Both additive, so unlike the `sample`
  rebuild they need no table rebuild (A49 blocks *dropping* constraints, not
  adding nullable columns) — but they run inside the same transaction and the
  same backup gate.
- `COMMENT ON COLUMN lab_method.units IS '...'` recording the binding rule:
  **a fallback for interpreting a value, NOT a guarantee that any given report
  used this unit; never part of the method's identity** (A63).
- Backfill is **not** part of this plan — populating `units`,
  `conversion_constant` and `reported_as` is PLAN-14 (A69), and its item (c) is
  open pending provenance.

Criteria: both columns exist and are nullable; the `COMMENT` is readable back
via `duckdb_columns()`; every existing `lab_method` row is otherwise byte-
identical; the step is idempotent (re-running adds nothing, and does not clear
a value PLAN-14 has since written).

## Gates

- `testthat::test_file("tests/testthat/test-migration-001.R")` green.
- A full **rehearsal on a copy** of the live DB completes and its printed counts
  are reviewed by the operator before any real run.
- The step-11 verify passes on the rehearsal.
- The R-9.1 direct-write lint: this script is **exempt by design** (it is not
  package code and does not ship in `R/`), but it must live under `dev/` so the
  lint's scope is unchanged. Confirm the lint still passes untouched.
