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

<!-- block: B-13-the-ordering-constraint -->
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

<!-- block: B-13-which-database -->
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

<!-- block: B-13.1 -->
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
     `<snapshot_dir>/monitoring_pre-001-alias-indirection_<UTC timestamp>.duckdb`,
     the timestamp formatted **`%Y%m%dT%H%M%OS3Z` (millisecond precision)** —
     second precision would let two runs inside one second collide while the
     "same-day second run does not overwrite" criterion below still passed
     (Phase-3 D19).
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
   > `n_seen = 0` here is **deliberate and is not an inconsistency** — see
   > `PLAN-11-feature-alias.md` item **(c)** ("`n_seen` has exactly one unit").
   > Self-aliases seed at 0 and are then incremented by step 4's fold of
   > self-name cypher entries, so the Why's "131x correct-label count" is the
   > **post-step-4** value, never a seeded one. Do not "fix" this to a sample
   > count: at ingest the unit is +1 per newly-pointing sample, and at migration
   > it is +1 per historical sighting — the same quantity counted retrospectively.
4. Import **`cypher`**: split on `,`, trim, drop empties, **count** duplicates
   into `n_seen`. ~370 rows; self-name entries fold into the self-alias via the
   upsert.
   **Both predicates are defined here (Phase-3 D7 — they were mandated but left
   undefined, and `auto_assign` is load-bearing: R-11.4 pins that an
   `auto_assign = FALSE` alias never enters the candidate set):**
   - `kind = "historical_code"` iff the trimmed entry **contains no whitespace
     AND contains at least one digit** (`B.S01`, `BH12a`); otherwise
     `kind = "descriptive"` (`old landfill bore`, `the swamp outlet`).
   - an alias is **ambiguous** iff its `alias_key` resolves to **more than one
     distinct `uuid_feature`** across the whole import. Ambiguous aliases get
     `auto_assign = FALSE` and are listed in the run report. The expected count
     is **31**; a different count is not a failure but **must be printed and
     reviewed** before the real run (it means the live cypher bag has changed).

   Criteria: a whitespace-free entry containing a digit lands
   `historical_code` and a multi-word entry lands `descriptive`; an
   `alias_key` reaching two features lands `auto_assign = FALSE` on **both**
   rows and appears in the report; a single-feature key stays
   `auto_assign = TRUE`; the ambiguous count is printed.
5. Import **`long` mask names**: `kind = "mask_long"`; overlaps with `cypher`
   collapse via the same upsert (increment `n_seen`), never error.
   **Not imported:** `old`, `gas_report`, `EPA`.
6. `DROP VIEW` the 6 views referencing `sample.uuid_feature`.
7. Dump `analysis` to a temp table; `DROP TABLE analysis` (this frees both
   `sample` and `lab_method` from their inbound FK).
8. Rebuild `sample` with the new shape, backfilling
   `uuid_feature_alias` from each row's old `uuid_feature` → that feature's
   self-alias; rebuild `lab_method` with `uuid_analyte` nullable.
9. Rebuild `analysis` **with its existing columns unchanged** — it is rebuilt
   only to restore the FKs freed in step 7, **not** to gain a units column.
   A51's `analysis.units_raw` was reversed by **A63**: units live on
   `lab_method` (restored by R-13.2 below), and `analysis` gains nothing.
   Re-declare its FKs against the rebuilt `sample`/`lab_method`.
10. Recreate the 6 views, joining `sample → feature_alias → feature`.
11. **Verify**: row counts and checksum identical to (2); `sample.uuid_feature`
    gone; **zero** NULL `uuid_feature_alias`; every self-alias reachable; **all
    six dropped views exist again by name AND each returns without error**
    (Phase-3 D20 — the verify previously pinned only `v_measurement`, so five of
    the six could have vanished in step 10 and the gate would still have gone
    green); and the `v_measurement` row count is **unchanged** (the migration
    must not hide or reveal a single measurement).

Steps 3-10 run inside **one** transaction, so a mid-migration failure rolls back
rather than leaving a half-rebuilt DB - the backup is the second line of
defence, not the first.

**How idempotency is achieved (Phase-3 D11 — the criterion below demanded it but
named no mechanism, leaving the worker to invent the guard that makes its own
criterion true).** A7 already requires migrations to be recorded in
`schema_version`. So: **step 0 reads `schema_version` for
`001-alias-indirection`; if present, the script prints the recorded timestamp and
exits 0 having written nothing** — no backup, no transaction, no probing. Step 10
writes that row inside the same transaction as the rebuild, so the marker and the
migration commit or roll back together. A schema probe ("does `sample` still have
`uuid_feature`?") is **not** sufficient and must not be used instead: it cannot
distinguish "already migrated" from "half-migrated by a build that predates the
marker", and it silently mis-answers on a restored backup.

Criteria: **the script writes nothing until a verified backup exists (step 1) —
pinned by a test that makes the backup copy fail and asserts zero writes**; a
same-day second run does not overwrite the first run's backup (the `snapshot_db()`
trap — pinned); **idempotent via the step-0 `schema_version` marker — a second run
exits 0 having written nothing, asserted by a row-count and checksum comparison,
not merely by "no error"**; **every log line the script emits quotes the absolute
DB path** (Phase-3 D14 — this is the orphan that would let a rehearsal against the
wrong one of A67's three copies pass unnoticed); **all six views exist and return
after step 10**;
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


<!-- block: B-13.2 -->
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

<!-- block: B-13-fixtures -->
## Fixtures (Phase-3 D3 — this plan had none, and could not be tested without them)

**`tests/testthat/helper-migration-db.R` is NEW and is owned by this plan.**
`helper-db.R` cannot serve: it builds the **post**-migration shape (its own
comment says `uuid_feature` is DROPPED), it puts `cypher` on `project` rather
than `feature`, and it has no `analyte_mask` at all. So R-13.1, R-13.2 and
PLAN-14 R-14.1 had no nameable fixture — three criteria that could not have been
written as tests.

`seed_pre_migration_db()` builds a throwaway DuckDB in the **pre**-migration
shape, small but structurally exact:
- `feature` **with `cypher`** populated — including at least one entry that is a
  self-name (must fold into the self-alias), one code-shaped, one descriptive,
  one duplicated (so `n_seen` counting is observable), and one `alias_key`
  reaching **two** features (the ambiguity case, `auto_assign = FALSE`);
- `feature_mask` with `long`, plus at least one `old` / `gas_report` / `EPA`
  row that step 5 must **not** import;
- `sample` **with `uuid_feature`** (the column this migration drops);
- `lab_method` **without** `units` / `conversion_constant` (R-13.2 adds them) and
  with `uuid_analyte` NOT NULL;
- `analysis` wired to both, so the FK rebuild in steps 7–9 is exercised;
- `analyte_mask` (absent from every existing test DDL) — **PLAN-14 R-14.1
  requires it**, and it is the only reason that requirement is testable;
- the **six views** referencing `sample.uuid_feature`, so steps 6/10 and the
  D20 verify are exercised rather than asserted about an empty set.

It is deliberately NOT wired into `seed_db()`: the two DDLs describe different
epochs and merging them would reintroduce exactly the drift A-4 and R-11.17 exist
to catch.

<!-- block: B-13-gates -->
## Gates

- `testthat::test_file("tests/testthat/test-migration-001.R")` green.
- A full **rehearsal on a copy** of the live DB completes and its printed counts
  are reviewed by the operator before any real run.
- The step-11 verify passes on the rehearsal.
- The R-9.1 direct-write lint: this script is **exempt by design** (it is not
  package code and does not ship in `R/`), but it must live under `dev/` so the
  lint's scope is unchanged. Confirm the lint still passes untouched.
