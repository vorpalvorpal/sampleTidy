# CONTRACT — stage obligations for plans 11–14 (DERIVED, do not hand-edit)

Mechanically extracted from `dev/plans/CONTRACT.md`: the adjudication log from **A48
onward**, i.e. exactly the decisions that plans 11–14 are accountable for. A1–A47 are
the adjudications of plans 01–10, which are landed, green, and not subjects of this
stage — including them would manufacture an "unowned obligation" for every one of them.

Regenerate with `dev/tdd-run/make-stage-obligations.sh`.

## Adjudicated decisions (A48–A71; do not re-litigate)

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
    capitalisations actually used in reports). But `.rc_key()` folds them
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

