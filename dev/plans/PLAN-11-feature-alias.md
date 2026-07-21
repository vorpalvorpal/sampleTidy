# PLAN 11 — commit-everything, resolve unknown feature & analyte names later

**Owns:** `R/feature-alias.R` (new — the resolve API), `R/pending.R` (new —
backlog readers), `tests/testthat/test-feature-alias.R` (new),
`tests/testthat/test-pending.R` (new).

**Amends** — *this list is the worker's file allowlist; it was stale from
2026-07-19 to 2026-07-22 and is now reconciled with the fold-in section below.*

| file | owner | functions |
|---|---|---|
| `R/reconcile.R` | 08 | `.rc_key`, `.rc_load_registry`, `.rc_feature_candidates`, `.rc_lab_method_candidates` (A65), `.rc_resolve_features`, `.rc_resolve_analytes`, `.rc_resolve_units_values`, `.rc_method_preference`, `.rc_three_way`, `.rc_find_existing`, `.rc_proto_review`, **`.rc_proto_skip`** (F3), `reconcile_event` (incl. the new stage-0) |
| `R/commit.R` | 09 | `.ct_find_or_create_sample`, `.ct_resolve_samples`, `.ct_commit_analyses`, `commit_event`, + the new `.ct_materialise_*` |
| `R/mutate.R` | 09 | `.st_mutate_allowlist`; **`add_feature()`** (R-11.17/A58) |
| `R/assemble.R` | 07 | synthetic `lab_sample_id` join seam (R-11.15) |
| `R/adapter-acirl-field.R` | 06 | emits the synthetic `lab_sample_id` (R-11.15) |
| `tests/testthat/helper-db.R` | **11** | core DDL + seed |
| `dev/plans/FIXTURES.md` | **11** | the seed-DB contract `helper-db.R` implements |
| `tests/testthat/test-reconcile.R` | 08 | regressions |
| `tests/testthat/test-commit.R` | 09 | regressions |
| `tests/testthat/test-mutate.R` | 09 | `add_feature()` (R-11.17) |
| `tests/testthat/test-assemble.R` | 07 | R-11.15 seam |
| `tests/testthat/test-adapter-acirl.R` | 06 | R-11.15 synthetic id |
| `tests/testthat/test-e2e-pipeline.R` | **10** | R-11.15 two-visit assertion + T-1 review gate |

Every row above whose owner is not 11 is an **adjudicated cross-plan edit**
(A52), not an ownership transfer.

**Depends on:** plans 01–10 landed and green.
**Migration split out (A68).** `dev/migrations/001-alias-indirection.R` is no
longer this plan's — it is **PLAN-13**. Its ordering constraint still binds:
plan 11's code must not run against the live DB until plan 13 has landed.
Live-DB **data** fixes are **PLAN-14** (A69).

**Test-file ownership note.** `helper-db.R` has no owner in the CONTRACT's
partition. Plan 11 takes ownership; it is the only plan amending it (see A52).

**`FIXTURES.md` moves with `helper-db.R` (orchestrator, 2026-07-17).** Not caught
by the cold review — it is a doc coupling, not code. `helper-db.R`'s header
states it implements `dev/plans/FIXTURES.md`'s "Seed DB" section *exactly*, and
FIXTURES.md calls itself "the synthetic universe (**shared contract for all test
agents**)". This plan rewrites that seed, so FIXTURES.md is amended in the **same
change** — otherwise every future test agent reads a universe that no longer
exists, and the drift is silent because nothing tests a doc. Its §"Cross-plan
expectations" needs the new dispositions too (a `T.S0l` typo no longer strands —
it commits dangling).

<!-- block: B-11-why -->
## Why

Sampling-point codes **and** analyte names are almost always transcribed or
labelled inconsistently between the bottle, the COC and the lab's report.
Unknown feature and unknown analyte are the two *common* review causes; the
other three (`value_conflict`, `sample_datetime_mismatch`, `unknown_unit`) are
rare. Today an unresolved name **strands the data**, and resolving requires
replaying the file through a pipeline that cannot replay (`route_files()` never
re-decides a routed hash).

This plan inverts that (user direction, 2026-07-16): **commit the data always,
resolve the name afterwards as a pure database operation.** A measurement is
real and its numbers are good even when we are unsure which feature or analyte
it belongs to; those identities are separately-resolvable pointers, not a commit
gate. Review stops being "re-run the pipeline" and becomes an `UPDATE`.

Background and domain rules: `dev/DESIGN.md`, and the `cypher-and-feature-alias`
memory. Those are context, not authority — **this plan and `CONTRACT.md` are.**

<!-- block: B-11-model-full-indirection -->
## Model — (P) full indirection (settled; do not re-litigate)

A `sample` **does not point at a feature**. It points at the *alias it arrived
under*; the alias points at a feature, nullably:

```
sample.uuid_feature_alias  ->  feature_alias.uuid          (NOT NULL)
feature_alias.uuid_feature ->  feature.uuid                (NULLABLE; NULL = dangling)
analysis.uuid_lab          ->  lab_method.uuid             (NOT NULL, unchanged)
lab_method.uuid_analyte    ->  analyte.uuid                (NULLABLE; NULL = dangling)
```

`sample.uuid_feature` is **dropped**. Every feature is given a **self-alias**
(894 rows, `kind = "self"`) so a correctly-labelled sample points at an alias
too — the model is uniform, with no special case for "arrived correct".

Consequences, and why this shape:
- **Resolution is one single-row `UPDATE`** on `feature_alias.uuid_feature`.
  There is no propagation step and no denormalised copy to keep in sync,
  because the fact lives in exactly one place.
- **Dangling auto-hides.** Every measurement view `INNER JOIN`s through to
  `feature`/`analyte` (verified below), so a dangling sample or analysis is
  invisible to `v_measurement` and every EPA report until resolved. No view
  needs to become dangling-aware.
- **Self-aliases carry signal, not noise.** A self-alias's `n_seen` is how often
  the feature was labelled *correctly* — the largest real counts in `cypher` are
  exactly this (`B.S01` ← `B.S01`, 131×).
- **No provisional features.** `feature` is NOT NULL on `name, site, lon, lat`
  and all 894 rows are `virtual = FALSE`; a placeholder would need fabricated
  coordinates and would land in EPA reports. Unresolved data hangs off a
  dangling alias instead.

The earlier draft recommended a denormalised variant (D) — keep
`sample.uuid_feature` as a nullable resolved pointer alongside the alias — on
the grounds that (P) "adds ~15k self-alias rows" and a view rewrite. **Both
grounds were wrong** (D3, D4 below). (P) is the normalised model; (D) was the
denormalisation.

<!-- block: B-11-decisions-settled-in-review -->
## Decisions settled in review (2026-07-16)

- **D1 — (P), not (D)** (user). Rationale above.
- **D2 — `sample.uuid_feature` is dropped in this plan** (user). The dashboard
  repo reads it in ~4 places, all inside its own `etl/views.sql` /
  `build_duckdb.R:710` view definitions; it rebuilds its duckdb independently
  from `.qs` files, so it does not break in the meantime and is updated
  separately. Out of scope here.
- **D3 — the "15k self-alias rows" claim was false.** Measured: **894**
  features → 894 self-aliases. 15,113 is the number of `sample` rows the
  migration *repoints* (an `UPDATE`), not rows inserted.
- **D4 — the "~12 views rewritten" claim was false.** Measured: **6** views
  reference `sample.uuid_feature` (`v_feature_dates`, `v_measurement`,
  `v_measurement_{epa,gas_report,long,old}`). The four `v_feature_*` views are
  `FROM feature LEFT JOIN feature_mask` and never touch `sample`.
- **D5 — confirmation collisions abort unless `override = TRUE`** (user). A
  collision is *evidence the operator picked the wrong feature*, so the default
  is to refuse and report, not to merge silently. See R-11.10.
- **D6 — a row that is feature-dangling AND hits a "must hold" kind**
  (`unknown_unit`, `value_conflict`, `sample_datetime_mismatch`) **is held**, as
  today (user). Commit-everything covers "we know the number, just not where it
  goes" — not "we don't trust the number".
  **Restated after cold review (C9):** the rule binds on **feature**-pending
  rows only. A feature-pending row still has a known analyte, so
  `.rc_resolve_units_values()` evaluates its units and drops it on failure →
  held, for free, with no new code. An **analyte**-pending row never evaluates
  units at all (R-11.6), so `unknown_unit` *cannot fire* for it — the D6 ×
  analyte-pending cell is empty, not a contradiction. The earlier wording
  ("feature/analyte-dangling") implied a conflict with R-11.6's "a pending row
  is not skipped for an unconvertible unit". There is none; they address
  different rows.
- **D7 — REVERSED by the user (2026-07-22). `analysis` gains NO units column;
  units live on the METHOD.** The original D7 added `analysis.units_raw` on the
  premise that "a dangling analysis has no analyte, so its reported units have
  nowhere to live". **That premise was false** — a dangling row still knows its
  *method*, and `lab_method` is where units belong (it had a `units` column in
  WEM.data's `labDF`; the column was lost in a schema edit, not designed away).
  So `lab_method` regains **`units`** and **`conversion_constant`** (A63), and
  `analysis` is untouched.
  **Measured before deciding** (3,624 committable `Normal` rows, 90 events, real
  corpus): **221 of 222 distinct (method, analyte) pairs report exactly one
  units string.** The sole exception is `sodium adsorption ratio`, whose two
  values are `-` and NA — both meaning *dimensionless*. Units are a function of
  the method. ⚠️ A first cut of this measurement said 95 of 354 triples varied;
  that was **QC rows** (LCS/MB recoveries report in `%`), which the reconciler
  filters before anything commits. **Do not re-derive this without the `Normal`
  filter** — the unfiltered number would have wrongly justified the old D7.
  Also: the naming was wrong on its own terms. This schema reads `<col>_<table>`
  (`uuid_feature` = the uuid from `feature`), so `units_raw` parses as "units
  from the raw table". `lab_method.units` matches `analyte.units`.
  **`units` is a FALLBACK, not a guarantee** (user, binding): it says how to
  interpret a value when nothing better is known; it does **not** assert that
  any given report used that unit. Pinned as a `COMMENT ON COLUMN` so the rule
  travels with the schema instead of living only here.
  **Units are NOT part of a method's identity** — identity stays
  `(organisation, name, method)`. A units change must never spawn a second
  `lab_method` row: `.rc_find_existing()` keys on `a.uuid_lab`, so a new row
  would mean a lab reissuing a report with corrected units does **not**
  supersede — it commits a **second analysis**, and both appear in
  `v_measurement`, wrong and corrected side by side, nothing flagged. (Verified:
  `.rc_three_way()` reaches the supersede branch only through
  `.rc_find_existing()`.) The drift is surfaced at **confirmation** instead —
  R-11.11.
  On ingest, a matched row's value is multiplied by the method's
  `conversion_constant` when non-NA, and *that* is what `analysis.value` stores.
- **D8 — reconcile stays read-only** (orchestrator, from A32). Reconcile decides
  *status*; **commit** creates the pending alias / dangling `lab_method` rows
  through the mutation layer. The draft blurred this.
  **Upheld against cold review (orchestrator, 2026-07-17).** The review found
  three consumers needing the alias's identity at reconcile time (review payload,
  `.rc_find_existing`, `.rc_method_preference`) and read that as evidence D8 is
  wrong. It is not. The actual defect was keying those consumers on a
  **surrogate uuid that does not exist yet** instead of on the **natural key that
  does** (`alias_key`; `(organisation, .rc_key(name), .rc_key(method))`). D8
  stands; R-11.5a, R-11.7 and R-11.9 below are re-specified around the natural
  key. Every fix is a `SELECT`, so A32 holds.
- **D9 — site-narrowing is deferred out of this plan** (orchestrator, from cold
  review C1/PCR-1; **flagged for user override** — it edits a binding domain
  rule). Narrowing step (3) "if the file's site is known, drop features not at
  that site" has **no input**: `R/ir.R` has no site field, `reconcile_event()`
  calls `.rc_resolve_features(active, registry, event$work_order)` — three args
  (`R/reconcile.R:637`) — and only 2 of the 3 adapter families could even supply
  one (ESdat has no site source). Plumbing it through means amending `R/ir.R`
  plus plans 03–06's files: an undeclared cross-plan ownership conflict.
  Measured cost of deferring: site resolves **3 of 31** ambiguous aliases; those
  3 now go to review instead of auto-assigning. That is the **safe** direction —
  it produces no wrong assignment, only more review — and re-adding site later
  is purely additive. **Narrowing in this plan is `date_end` only.**
- **D10 — REVERSED by the user (2026-07-22). A CAS-hit commits dangling, like
  any other unknown analyte, with the CAS as a review *suggestion*** (A66). The
  earlier carve-out held the row on the grounds that committing it would
  auto-create a **resolved** `lab_method` (A6/A54 forbid that) and that
  committing it dangling would discard the CAS evidence. **Both objections
  dissolve together:** commit a **dangling** `lab_method` (`uuid_analyte IS
  NULL`) — exactly what A54 licenses — and put the CAS-matched analyte in the
  review payload as a suggestion. No resolved row is created, the CAS evidence
  is preserved where a human will act on it, and there is now **one rule for
  every unknown analyte** instead of a carve-out that had to be test-pinned to
  stop it rotting. `R/reconcile.R:196-201`'s `status = "cas"` therefore joins
  `hit_idx`'s disposition as a *pending* row rather than being dropped to
  review-only.

<!-- block: B-11-evidence -->
## Evidence (measured against `monitoring.duckdb`, duckdb 1.4.1)

**Which DB — RE-MEASURED 2026-07-22 against the authoritative copy (A67).**
The numbers in this section were originally taken from
`/Users/rjs/Documents/dashboard/data/monitoring.duckdb`. **That is the wrong
database.** It is the dashboard's *derived* copy, which that repo rebuilds
independently from `.qs` files (D2), so its schema legitimately drifts. Row
counts agree across all copies (894/15,113/95,737/247), which is exactly why it
passed as interchangeable and produced three false "corrections".

**The authoritative DB is:**
```
/Users/rjs/OneDrive - Blue Mountains City Council/Sharepoint/
  waste_data - Environmental monitoring/data/monitoring.duckdb
```
(`~/OneDrive - Blue Mountains City Council` symlinks to
`~/Library/CloudStorage/OneDrive-BlueMountainsCityCouncil`; note the
`Sharepoint/` component — omitting it is why this folder has looked missing.)
`st_config("live_db")` does not exist on this machine.
`…/leachatetools/test data/monitoring.duckdb` is a third, stale copy.
**Name the absolute path when quoting any measurement.**

Three claims previously recorded here as "corrections" are **reverted**:

| claim | was recorded | truth (live) |
|---|---|---|
| `feature` shape | 18 cols, no `virtual` | **19 cols, `virtual BOOLEAN` present**, all 894 FALSE |
| `lab_method` rows | 365 | **360** (the dashboard's 5 extras are mojibake twins — `EC @25<c2><a1>C`, `@25<ef><bf><bd>C`, SS, TDS — the corruption class A25/A35 repair) |
| views | 60 | **14** (the 60 was `duckdb_views()` counting DuckDB's *internal* catalog views — a methodology artefact on **both** copies, not DB drift) |

The plan's original draft was right on all three. **D4 stands unchanged:** on the
live DB exactly **6** of the 14 views reference `sample.uuid_feature`
(`v_feature_dates`, `v_measurement`, `v_measurement_{epa,gas_report,long,old}`),
and `v_measurement` is `analysis INNER JOIN sample INNER JOIN feature INNER JOIN
lab_method INNER JOIN analyte` — so the auto-hide argument holds on the real DB.

**What `virtual` is** (it exists, so the plan must stop claiming it does not):
WEM.data's flag for a **non-physical** feature — SILO-grid weather stations
(`L.WS01`/`BH.WS01`, created at the nearest 0.05° grid centre with *real*
coordinates; `feature_sfc(virtual = )` filters on it). It is **not** a
placeholder mechanism for unknown identity, so the "no provisional features"
argument below is unaffected — if anything it is strengthened: the one existing
escape hatch is for features whose location is known but derived, which is the
opposite of a dangling row.

Verified directly (re-check before relying on any of it):

- `v_measurement` is `analysis INNER JOIN sample INNER JOIN feature INNER JOIN
  lab_method INNER JOIN analyte`. The `v_measurement_*` family is identical
  through `v_feature_*`/`v_analyte_*`. **Dangling rows auto-hide.**
- `feature` = 894, `sample` = 15,113, `analysis` = 95,737, **`lab_method` = 360**
  → **247** analytes, **14** views. **Do not encode any of these as test
  constants** — see R-11.3 for the frozen-fixture / live-property split that
  replaces count-pinning.
- `sample.uuid_feature` is **NOT NULL** with a **FK → feature(uuid)**.
  `lab_method.uuid_analyte` is **NOT NULL** with 0 dangling rows.
- **`feature` DOES have a `virtual` column** and all 894 rows are
  `virtual = FALSE` — the draft was right and the cold review's retraction was
  the dashboard-copy error (A67). `helper-db.R`'s test DDL correctly declares
  it; what the test DDL is actually missing is `lon`/`lat` (R-11.17). The "no
  provisional features" argument rests on `name`/`site`/`lon`/`lat` being NOT
  NULL, which is verified on the live DB.
- **DuckDB 1.4.1 cannot drop a constraint at all** (`ALTER TABLE … DROP
  CONSTRAINT` → "No support for that ALTER TABLE option yet!"). Therefore
  neither `DROP COLUMN uuid_feature` nor `ALTER COLUMN … DROP NOT NULL` is
  possible in place on `sample` or `lab_method` — both fail with a dependency /
  FK error, **and dropping the dependent views does not help**. This forces a
  table-rebuild migration (R-11.13). It applies to **(D) as much as (P)**: (D)
  needs `sample.uuid_feature` nullable, which is blocked by the same wall. The
  rebuild is therefore *unavoidable for this plan in any model*, which makes
  (P)'s marginal migration cost ≈ 894 inserts + one backfill expression.
- `analysis` has **no units column** and (per D7, reversed) gains none.
  `lab_method` has **no `units` and no `conversion_constant`** — both were in
  WEM.data's `labDF` (`make new dfs.R:63`) and were lost when this duckdb was
  built. A schema **regression**, restored by plan 13 (A63).
- `lab_method.reported_as` is NULL in all 360 rows but is **NOT dead** (A64).
  It records the *basis* a result is reported on — ammonium as `N` vs as `NH3`,
  hardness as `CaCO3`. The earlier "candidate for removal" note is **struck**;
  dropping it would destroy the column the basis belongs in. The basis currently
  lives in the `lab_method.name` string instead (ALS's own naming: `Ammonia as
  N`, `Ammonia as NH3`, `Total Alkalinity as CaCO3`). Backfilling it is plan 14.
- `units_raw` already exists in the IR (`R/ir.R:14`) and flows through reconcile;
  it is dropped at commit and, under the reversed D7, that stays correct — the
  units land on the **method**, not the analysis.
- `feature.cypher`: 117/894 features, 2062 raw entries → 370 unique
  `(feature, alias)` pairs (case/punct-folded); 72 are the feature's own name,
  **298 are genuine wrong labels** (222 seen once, 38 seen 2–4×, 38 seen 5+).
  Repeats are **frequency, not bloat** → `n_seen`.
- **31 aliases map to >1 feature.** Date (`date_end`) + site disambiguation
  resolves only **4** (1 by date, 3 by site); the other 27 are non-identifying
  descriptors (`B.BORE` → 8 features) that *should* stay in review. Date/site is
  a **correctness guard**, not a bulk auto-resolver.

<!-- block: B-11-domain-rules -->
## Domain rules (user, 2026-07-16 — binding)

- **`old` must NOT be imported** from `feature_mask`: 363 of its 373 names ARE
  another live feature's real name, and `old` means a *different physical
  feature*. Import **`long` only**.
- **An alias name is NOT unique.** The same string may legitimately map to
  different features at different times. Identity is the alias's **own `uuid`**;
  `name`/`alias_key` carry no uniqueness constraint.
- **Auto-assign** only when exactly one feature survives narrowing: (1) collect
  candidates from `auto_assign` aliases; (2) drop features defunct at the
  sample's date (`date_end < sample_date`); (3) if the file's site is known,
  drop features not at that site; (4) exactly one survivor → assign, else review.
  > **Step (3) is deferred out of plan 11 — see D9** (orchestrator, 2026-07-17;
  > flagged for user override). The rule is recorded here as written and is not
  > retracted; it is unimplementable *today* because no adapter puts a site on
  > the event and `R/ir.R` has no field to carry one. Deferring costs 3 of 31
  > ambiguous keys, which go to review instead — never a wrong assignment.
  > Steps (1), (2) and (4) are implemented in full.
- **Frequency ranks, never decides.** Worst real tie: `KBORE` → `K.MW08` 15× vs
  `K.MW10A` 14×.
- **No fuzzy auto-assign** — real codes differ by one character (`B.S01` vs
  `B.S04`). Fuzzy/prefix-map/LLM outputs are **suggestions only**, never the
  commit path (an LLM there would break plan-10 idempotency).
- **Guesses never launder into ground truth**: an unconfirmed guess is reported
  every run until a human confirms it; only confirmation writes `confirmed_by`.
- **Review UX is bulk confirmation** — no per-feature clicking.

<!-- block: B-11-the-api-is-the -->
## The API is the authority; the UI is deferred

The deliverable is the **resolve API**: the only thing that writes a resolution
— validating, idempotent, bulk-capable, recording provenance (`confirmed_by`,
`change_log`). **No UI is specified or built here.** The discipline any UI must
preserve: *the UI presents and executes; the human decides; the API records the
human as `confirmed_by`.* A UI (including an LLM-driven one) may propose and may
call the resolve functions, but never confirms on its own.

<!-- block: B-11-seam-table -->
## Seam table (producer → consumer; fields that must survive)

| producer | consumer | fields |
|---|---|---|
| `.rc_resolve_features` | `.rc_resolve_analytes` → `.rc_three_way` | `uuid_feature_alias` (chr; NA ⇒ pending **and no existing alias found** — R-11.5a may fill it while `feature_pending` stays TRUE), `feature_pending` (lgl), `feature_raw`, `alias_key` |
| `.rc_resolve_analytes` | `.rc_resolve_units_values` | `uuid_lab` (chr; NA ⇒ pending **and none found** — R-11.5a as above), `analyte_pending` (lgl), `uuid_analyte` (chr, NA when pending), `analyte_raw`, `org`, `method_raw` |
| `.rc_resolve_features` / `.rc_resolve_analytes` | `.rc_method_preference` | resolved `uuid_feature` **or** `uuid_feature_alias`, `sample_date`, `uuid_analyte`; analyte-pending rows excluded (R-11.5b) |
| `reconcile_event` | `.ct_commit_review` | `source_hash` (chr) — a **new `.rc_proto_review()` column**, first of the group (R-11.9/C18) |
| `.rc_resolve_units_values` | `.rc_three_way` | `value` (canonical **iff** `!analyte_pending`, and after the method's `conversion_constant`), `units_raw` (always — IR-internal; it lands on `lab_method.units` at commit, never on `analysis`), `rl_low` |
| `reconcile_event` | `commit_event` | `clean` carries **all** of the above; dropping any one silently strands a dangling row |
| `commit_event` R-11.8 | `.ct_resolve_samples` | `uuid_feature_alias` now **always non-NA** (pending materialised) |
| `.ct_materialise_*` R-11.8 | `.ct_commit_review` | per-row alias / lab_method **uuid**, used to rewrite the review payload (`alias_uuid=<uuid>`) before it is written — the only point where row, review item and uuid coexist (C2) |
| `confirm_feature_aliases` | `sample` | alias `uuid` → the samples pointing at it |
| `confirm_analyte_methods` | `analysis` | `lab_method.uuid` → its analyses; **`lab_method.units`** → conversion to `analyte.units` (D7 reversed — the source units come from the method, not a per-analysis column) |

**Pitfall note (test authors).** The analysis match key is
**(feature, date, analyte, method)** — A45. `lab_sample_id` is *not* a DB column
and can **never** be part of it. A "fresh" fixture row needs a distinct feature,
date, or method — *not* just a distinct lab sample id (this is exactly the A39
fixture bug; do not re-introduce it).

**Pitfall note (test authors).** A pending alias is created **at commit**, not
at reconcile (D8). A reconcile-only test must assert `feature_pending == TRUE`
and `is.na(uuid_feature_alias)`; asserting a `feature_alias` row exists after
`reconcile_event()` alone will fail — correctly.

<!-- block: B-11.1 -->
## R-11.1 Schema: `feature_alias`

```
feature_alias(
  uuid         VARCHAR PRIMARY KEY,   -- the alias's OWN identity (name is not unique)
  uuid_feature VARCHAR,               -- NULLABLE: resolution; NULL = dangling. FK -> feature(uuid)
  name         VARCHAR NOT NULL,      -- raw, as seen ('B..So3')
  alias_key    VARCHAR NOT NULL,      -- .rc_key(name); NOT unique
  kind         VARCHAR,               -- self | historical_code | descriptive |
                                      --   transcription_error | mask_long | pending
  n_seen       INTEGER DEFAULT 0,
  auto_assign  BOOLEAN DEFAULT TRUE,  -- FALSE = suggest only, never resolve
  first_seen   TIMESTAMP,
  last_seen    TIMESTAMP,
  source_hash  VARCHAR,
  confirmed_by VARCHAR,               -- NULL = unconfirmed guess
  comments     VARCHAR
)
```

No DB uniqueness on `name`/`alias_key` (the domain forbids it). Duplicate
prevention is by **upsert in code**: writing an alias that already exists as a
`(uuid_feature, alias_key)` pair increments `n_seen`/`last_seen` instead of
inserting; a dangling `(NULL, alias_key)` row is reused, not duplicated.

Declared in `helper-db.R`'s core DDL (tests) and created by the migration
(live). **Not** in `ensure_schema()` — that is ops-tables-only (A50).
`feature_alias` is added to `.st_mutate_allowlist` in `R/mutate.R`.

Criteria: the table exists after `seed_db()`; `alias_key` is always
`.rc_key(name)`; the same `alias_key` may exist against two different features
(pinned); a re-seen alias increments `n_seen` and never inserts a duplicate; a
dangling row is reused rather than duplicated.

<!-- block: B-11.2 -->
## R-11.2 Schema: `sample`, `lab_method`, `analysis`

- `sample`: **drop** `uuid_feature`; **add** `uuid_feature_alias VARCHAR NOT
  NULL` → `feature_alias.uuid`.
- `lab_method`: `uuid_analyte` becomes **nullable**; **add** `units VARCHAR` and
  `conversion_constant DOUBLE` (D7 reversed / A63 — restoring two columns lost
  from WEM.data's `labDF`, not new design).
- `analysis`: **unchanged.** No `units_raw`, no units column of any kind.

`lab_method.units` semantics — pin these, they are the plan's subtlest
invariant:
- It records how to interpret a value reported under this method. It is a
  **FALLBACK, not a guarantee**: it does *not* assert that any particular report
  used that unit (user, binding). Pin it as a `COMMENT ON COLUMN`, so the rule
  ships with the schema rather than living only in this document.
- `analysis.value` is in the **analyte's** canonical units **iff** the row's
  `lab_method.uuid_analyte` is non-NULL. When dangling, `value` is in the
  **method's** units.
- This is safe precisely because a dangling analysis is invisible to every view
  (INNER JOIN analyte), so **no consumer can ever read a value in the wrong
  units**. The invariant and the visibility rule are the same rule.
- **Units are not part of the method's identity** (`(organisation, name,
  method)`). Never create a second `lab_method` row because the units differ —
  see D7 for why that silently breaks revision supersede.
- On ingest, a matched row's value is multiplied by the method's
  `conversion_constant` when it is non-NA; *that* product is what
  `analysis.value` stores. NA means no conversion.

Criteria: `seed_db()` produces the new shape; a codebase audit for anything
reading `sample.uuid_feature` is part of this task (grep `R/`, `tests/`);
`v_measurement`'s equivalent join (A24 — the test schema has no views) returns
exactly the resolved rows and a dangling sample does not appear; a method with
`conversion_constant = 1.5` stores `1.5 ×` the reported value and one with NA
stores it unchanged; **no `analysis` table in any DDL declares a units column**
(a pinned grep, because the reversed D7 already shipped once in `helper-db.R`).

<!-- block: B-11.3 -->
## R-11.3 Normalisation (`.rc_key`, amended)

`.rc_key()` is `tolower(str_squish(normalise_lab_text(x)))`, which keeps
punctuation, so `B.S01` and `B S01` do not match. Extend it to strip all
non-alphanumerics:

```r
.rc_key <- function(x) {
  k <- tolower(gsub("[^[:alnum:]]", "", normalise_lab_text(x)))
  k[is.na(x) | k == ""] <- NA_character_
  k
}
```

**MEASURED against the live registry, 2026-07-22** (A67's DB). The draft called
the analyte/method side "the risk" and pinned nothing for it; here is the actual
number, and the risk turns out to be zero:

| set | rows | distinct keys, OLD `.rc_key` | distinct keys, NEW `.rc_key` |
|---|---|---|---|
| `feature.name` | 894 | 894 | **894** |
| `analyte.name` | 247 | 246 | **246** |
| `lab_method` `(organisation, name, method)` | 360 | 359 | **359** |

**The new fold introduces zero new collisions.** That — not the absolute counts
— is the property that makes it safe to auto-assign on. The two collisions are
pre-existing and are *not* normalisation artefacts:
- **`Carbophenothion` (`analyte`)** — two rows with **byte-identical** names,
  same units, same CAS, same constant. They collide under *any* key function
  including the identity function. A duplicate registry row; merged by plan 14.
- **`Standing Water Level` (`lab_method`)** — the two **ACIRL** rows
  `Standing Water Level` / `Standing water level`, same org, same method
  `field`, both → one analyte. They differ only in capitalisation, and `.rc_key`
  has always lowercased, so they collide today. **These rows are correct and are
  kept** (user, binding: methods retain the capitalisations reports actually
  use). The defect is in the *matcher* — see A65 / R-11.19.

**Test design — do NOT pin a live count anywhere.** The registry grows; a test
asserting "247 analytes" rots the next time an analyte is added. Two distinct
tests are needed and the draft conflated them:
- **(a) frozen-snapshot regression** (always runs, CI-safe): committed
  names-only fixtures — the 894 `feature.name` values, the 247 `analyte.name`
  values, the 360 `(organisation, name, method)` triples. Asserts the *fold*
  didn't change: `length(unique(key(x)))` equals the number recorded **in the
  fixture's own header**, not a literal in the test. This catches a `.rc_key`
  regression. (Names only, no data — the A3 exception, as for the feature list.)
- **(b) live property check** (corpus-gated like R-10.5, skipped without
  `SAMPLETIDY_CORPUS_DB`): asserts `length(unique(key(names))) == length(names)`
  over the *live* registry **with no numeric literal in it at all**, and reports
  the colliding pairs on failure. This is the one that catches a newly-added
  name breaking the property — which (a) structurally cannot do.
  Seed it with the two known-and-accepted collisions above as an explicit
  allowlist, so it fails on the 3rd, not on the 1st.

Criteria: `B.S01`, `B S01`, `BS01`, `b.s01`, `B..S01` share one key; NA/blank →
NA (the A44 guard); (a) and (b) both exist and (b) contains no count literal;
the OLD-vs-NEW equivalence above is itself pinned in (a) — i.e. the fold is
proven to add no collisions, rather than the counts being asserted blind.

**A44 guard, both halves (cold review C17).** `.rc_key` newly returns NA for
`""`. Today `.rc_feature_candidates()` (`R/reconcile.R:71-79`) survives a blank
*registry* name only via its trailing `cand[!is.na(cand)]` guard: indexing with
an NA on the LHS yields an NA element — the exact A44 phantom-candidate defect.
The new tibble-returning `.rc_feature_candidates()` must retain an equivalent
guard (R-11.4).

<!-- block: B-11.4 -->
## R-11.4 Alias matching + narrowing (`.rc_feature_candidates`, amended)

`.rc_load_registry()` gains `feature_alias`. Because every feature has a
self-alias, a direct name match **is** an alias hit: the two-source lookup
(`feature.name` then `feature_mask.name`) collapses to **one** lookup against
`feature_alias`. **No longer joins `feature_mask`** (its `long` names are
imported by **PLAN-13 R-13.1 step 5** — R-11.13 is now only a pointer stub (A68);
`EPA`/`old` must never match).

```r
.rc_feature_candidates(feature_raw, sample_date, registry)
# -> tibble(uuid_alias, uuid_feature) of surviving candidates
# NOTE: no `site` argument — D9. The event carries no site.
```

Procedure: key ← `.rc_key(feature_raw)`; NA → zero rows (A44 guard). Collect
`feature_alias` rows with `alias_key == key` **and `auto_assign`**; **drop rows
with `is.na(uuid_alias)`** (the A44 registry-row guard, C17); resolve to distinct
`uuid_feature`; if >1 distinct feature, narrow by **`date_end` only** (D9 —
site-narrowing is deferred); assign iff exactly one distinct feature survives.

Note: several aliases may survive pointing at the **same** feature — that is a
hit, not an ambiguity. Ambiguity is >1 distinct *feature*.

**Ordering constraint (cold review C19).** This section removes the
`feature_mask` lookup (`R/reconcile.R:76`) on the grounds that its `long` names
are imported by the migration's step 5. That makes R-11.13 step 5 a **hard
prerequisite** for running R-11.4 against the live DB: land this without the
import and every live `mask_long` match regresses to `unknown`. The test suite is
unaffected (`helper-db.R` seeds aliases directly). See R-11.13's restated
separability.

Criteria: one surviving feature → assign (via self-alias or a resolved alias);
zero → `unknown`; >1 distinct feature after `date_end` narrowing → `ambiguous`;
**both** A44 guards hold (NA key → zero rows; NA registry row → not a candidate);
a re-drilled well's old name resolves to the live feature; a reused code with two
live features stays `ambiguous`; a reused code where one candidate is defunct at
`sample_date` auto-resolves to the live one; `auto_assign = FALSE` aliases never
enter the candidate set.

**Fixture-naming note (test authors, C21).** Real names in this plan's criteria
(`B.G005`, `B.S03`, `B.S04`, `B..So3`) are **illustrative**, not load-bearing —
encode them with the synthetic fixture equivalents from the Fixtures section
(`f-0003`, `bs03alt`, …). A3 forbids real data in fixtures; R-11.3's names-only
list is the single sanctioned exception.

<!-- block: B-11.5 -->
## R-11.5 Reconciler: the funnel becomes a conveyor (features)

**This is the structural change the draft missed, and the heart of the plan.**
`reconcile_event()` is a funnel: each stage keeps only hits and drops the rest
into `review`, so `active` shrinks. A feature-unknown row is dropped at R-8.2
and **never reaches** `.rc_three_way`, never lands in `clean`, and
`commit_event()` commits only `clean`. Commit-everything is therefore a
**reconciler** change, not a commit change.

`.rc_resolve_features(rows, registry, work_order)` — **three arguments, no
`site`** (D9; the signature here previously carried a stale `site` argument that
contradicted D9 and R-11.4's explicit "no `site` argument" note) — now **keeps
every row** and annotates rather than dropping:
- hit → `uuid_feature_alias = <alias uuid>`, `feature_pending = FALSE`;
- `unknown` or `ambiguous` → `uuid_feature_alias = NA`, `feature_pending = TRUE`,
  `alias_key` set. The row **stays in `active`** and flows through R-8.3…R-8.7.

Both dispositions still emit their review item (R-11.9) — now a worklist entry
over committed data, not a commit gate.

**Ambiguous commits dangling too.** We know the measurement; we don't know the
feature — the same archetype as unknown. Its review item carries the candidates.

Criteria: a feature-unknown row appears in `clean` with `feature_pending = TRUE`
and reaches `commit_event()`; the counts in `reconcile_event()`'s `counts` still
reconcile (a dangling row is counted in `clean` **and** has a review item — the
existing `add_review` count path must not double-drop it); R-8.8 completeness
still holds (every input row lands in exactly one of clean/review-held/skipped);
**D6:** a row that is feature-pending *and* fails units/value/datetime is
**held**, not committed — pinned by a test that combines the two.

<!-- block: B-11.5a -->
## R-11.5a Reconcile-side lookup of *existing* pending rows (new; cold review C3)

**This section closes the plan's one genuine design hole.** Without it a dangling
row can never dedup, so every re-ingest of the same measurement duplicates it —
and the plan-10 idempotency gate would fail.

The hole: `.rc_find_existing()` runs *inside* reconcile (`R/reconcile.R:527`),
but the draft created the alias and the dangling `lab_method` at **commit**
(D8/R-11.8). So at match time a pending row has `uuid_feature_alias = NA` **and**
`uuid_lab = NA`, and `= NULL` never matches — R-11.7's "match on
`s.uuid_feature_alias` directly" matches nothing. Dropping the `lm.uuid_analyte`
clause (A53) does not rescue the analyte side either, because `a.uuid_lab = ?` is
*itself* NA for an analyte-pending row.

**The fix is a natural-key lookup, not a relocation of D8.** Reconcile does not
need to *create* the alias; it only needs to know whether one already exists.
That is a `SELECT`, so A32/D8 hold unchanged.

`.rc_load_registry()` already loads `feature_alias` (R-11.4) and `lab_method`.
For each pending row, resolve the surrogate from the natural key **against the
registry already in memory**:
- feature-pending → the `feature_alias` row with `alias_key == .rc_key(feature_raw)`
  **and `uuid_feature IS NULL`**. Among *pending* aliases that pair is unique
  (R-11.1's upsert guarantees it), so this is a well-defined lookup even though
  `alias_key` is not globally unique.
- analyte-pending → the `lab_method` row with `uuid_analyte IS NULL` and matching
  `(organisation, .rc_key(name), .rc_key(method))`.

Found → set `uuid_feature_alias` / `uuid_lab` from it and **keep `*_pending =
TRUE`** (the row is still unresolved; only its *identity* is now known). R-11.8's
find-or-create then finds the same row and is a **no-op** — the two use the same
key by construction.
Not found → the surrogate stays NA, which is **correct**: on a first sighting
there is nothing in the DB to match against, so `.rc_find_existing()` returning
"no match" is the right answer, not a bug. R-11.8 creates it.

**The key must be identical on both sides or this silently breaks.** If reconcile
looks up by `.rc_key(method)` and commit creates by raw `method`, every run
creates a fresh dangling row and nothing ever dedups. Pinned in R-11.8(e).

Criteria: a dangling measurement re-ingested **from a different file** (so hash
dedup cannot mask it) resolves to the same alias and same `lab_method`, matches
itself, and is `already_present` — **not** duplicated; a two-run idempotency test
over an unknown-feature *and* an unknown-analyte file leaves row counts unchanged
on the second run; a *first* sighting correctly finds nothing and commits one new
alias; the lookup issues **no writes** (pinned by the R-9.1 direct-write lint plus
a `db_transaction` spy asserting reconcile writes nothing).

<!-- block: B-11.5b -->
## R-11.5b `.rc_method_preference` re-keying (cold review C4)

**Not in the draft's Amends list, and it breaks silently — the worst failure mode
in this plan.** `R/reconcile.R:386` keys on
`paste(rows$uuid_feature, as.character(rows$sample_date), rows$uuid_analyte, sep = "||")`.
Once R-11.2 drops `uuid_feature`, `rows$uuid_feature` is `NULL`, and `paste()`
recycles a zero-length argument to `""` **rather than erroring** — so the key
silently loses its feature component and R-8.6 deduplicates rows from
**different features** against each other as `method_duplicate`. That is
undetectable data loss, not a crash.

Re-key on the **resolved feature** where known, and the **alias uuid** where
pending — the same resolved/pending split as R-11.7, deliberately, so there is
one rule to remember. Analyte-pending rows (`uuid_analyte = NA`) must be
**excluded from the dedup entirely**: they would otherwise all collapse into one
bogus group keyed on NA.

Criteria: two rows for *different* features on the same date with the same
analyte are **never** method-duplicates (a pinned regression — this is the bug
that would otherwise ship silently); two analyte-pending rows never dedup against
each other; the existing R-8.6 tests stay green.

<!-- block: B-11.6 -->
## R-11.6 Reconciler: dangling analytes

`.rc_resolve_analytes()` likewise keeps misses: `uuid_lab = NA`,
`uuid_analyte = NA`, `analyte_pending = TRUE`. `.rc_lab_method_candidates()` is
unchanged; only the miss path changes.

`.rc_resolve_units_values()` **must not attempt conversion** for
`analyte_pending` rows — there is no analyte, so no canonical units exist. It
passes `value` through unconverted and leaves `units_raw` set (R-11.2).

**The CAS-hit path now commits dangling too — D10 reversed, A66.** `status =
"cas"` (`R/reconcile.R:196-201`) is not in `hit_idx` (`:204`) today, so the row is
dropped to review and **stranded** — the very thing this plan exists to stop.
It now takes the same disposition as any other unknown analyte:
`analyte_pending = TRUE`, a **dangling** `lab_method` materialised at commit
(`uuid_analyte IS NULL` — exactly what A54 licenses, so no **resolved** row is
created and A6's intent is intact), and **the CAS-matched analyte carried on the
review item as a suggestion**, never as a link. That answers both of the old
carve-out's objections at once: nothing auto-resolves, and the CAS evidence is
preserved where a human will act on it rather than discarded. One rule for every
unknown analyte.

Criteria: an unknown-analyte row reaches `clean` with `analyte_pending = TRUE`,
`uuid_lab = NA` (or the existing dangling `lab_method`'s uuid, per R-11.5a) and
an unconverted `value`, and its **method** carries the reported units (D7
reversed — there is no per-analysis units column to set); a resolved row is
still converted exactly as today (all existing R-8.4 tests stay green); a
pending row is **not** skipped for an unconvertible unit (that check belongs to
resolved rows only — see D6's restatement, which shows this is not the
contradiction it looks like); **a CAS-hit row reaches `clean` dangling and its
review item names the CAS-matched analyte as a suggestion — pinned both ways
(it commits, AND it does not link)** (A66).

<!-- block: B-11.7 -->
## R-11.7 Three-way match with dangling rows (`.rc_find_existing`)

Today: `WHERE s.uuid_feature = ? AND CAST(s.date AS DATE) = ? AND
lm.uuid_analyte = ? AND a.uuid_lab = ?`. Both key columns break on dangling rows
(`= NULL` never matches), so every run would re-commit the same dangling
measurement.

**`.rc_three_way()` is amended too (cold review C5).** It is the caller that
passes `rows$uuid_feature[[i]]` / `rows$uuid_analyte[[i]]` into
`.rc_find_existing()` (`R/reconcile.R:527-530`); the draft listed neither. Its
new argument list is pinned here: it passes `uuid_feature_alias`,
`feature_pending`, `sample_date`, `sample_datetime`, `uuid_lab` — and **no
`uuid_analyte`** (dropped per change 2 below). Amending `.rc_find_existing`
alone would leave the call site broken.

Three changes:
1. **Feature side** — join through the alias. Resolved: match any sample whose
   alias resolves to the same `uuid_feature` (so two *different* labels for one
   feature share one sample). Pending: match on `s.uuid_feature_alias` directly —
   which is now meaningful, because R-11.5a has already resolved it from the
   natural key when a pending alias exists. When it is still NA (a genuine first
   sighting) the match correctly finds nothing.
2. **Analyte side** — **drop the `lm.uuid_analyte = ?` clause.** It is redundant:
   `a.uuid_lab = ?` pins the `lab_method` row, which determines its analyte. It
   is also the clause that breaks for a dangling method. Dropping it preserves
   A45's (feature, date, analyte, method) key exactly, because method ⇒ analyte.
   *Verified independently in cold review* (`R/reconcile.R:428-440` — the query
   joins `lab_method lm ON lm.uuid = a.uuid_lab`, so `a.uuid_lab = ?`
   functionally determines `lm.uuid_analyte`). A53 is sound.
3. **Both sides use `IS NULL`, never `= NULL`.** For a still-unmatched pending
   row the predicate must be `s.uuid_feature_alias IS NULL` / `a.uuid_lab IS
   NULL` semantics, not an equality against NA. This is the same silent
   never-matches footgun as R-11.8(a); it is called out in both places on
   purpose.

Criteria: A45's pinned regression (ACIRL field EC lm-0006 vs ALS lab EC lm-0003
→ two rows, not a conflict) stays green — this is the test that proves the
dropped clause was redundant; a dangling measurement re-ingested from a
**different file** matches itself and is `already_present`, not duplicated
(this requires R-11.5a — without it the criterion is unreachable, and the
"same bytes → already_present" test is a **false green** because hash dedup
catches it upstream before reconcile ever runs; the test must therefore use
*different bytes* carrying the *same* measurement); a resolved sample is reused
across two different incoming labels for one feature.

<!-- block: B-11.8 -->
## R-11.8 Commit: materialise pending aliases and dangling methods

New commit step, **before** sample resolution (D8 — reconcile is read-only; all
writes are here, through the mutation layer, never raw `dbExecute`):

```r
.ct_materialise_feature_aliases(con, clean, event, actor, reason)
# for rows with feature_pending: find-or-create a feature_alias, keyed
# `alias_key = ? AND uuid_feature IS NULL` (see (a)), with uuid_feature = NULL,
# kind = "pending", auto_assign = FALSE. Returns clean with uuid_feature_alias
# filled AND an alias uuid per row (for the R-11.9 payload rewrite).

.ct_materialise_lab_methods(con, clean, event, actor, reason)
# for rows with analyte_pending: find-or-create a lab_method from
# (name = analyte_raw, organisation = org, method = method_raw, rl_low, rl_high,
#  units = units_raw)  <- D7 reversed: the reported units land HERE, on the
#                         method, and nowhere else. conversion_constant stays
#                         NA (nothing has established a basis yet).
# with uuid_analyte = NULL. Dedup by (organisation, .rc_key(name), .rc_key(method))
# AND uuid_analyte IS NULL — see (e). Returns clean with uuid_lab filled.
```

**Contract pins (cold review C13) — a literal writer would otherwise guess all
five, and (a) and (e) are silent-corruption bugs, not style choices:**

- **(a) The find key is `uuid_feature IS NULL AND alias_key = ?`.** Never
  `uuid_feature = NULL` — in SQL that matches *nothing*, always, so every file
  would create a fresh pending alias and the "two files reuse ONE pending alias"
  criterion would fail while every individual test still looked green. This is
  the same footgun as R-11.7(3).
- **(b) `name` is the raw `feature_raw` string of the group's first row.** A
  group shares one `alias_key` but may carry several raw spellings (`B..So3`,
  `B. So3`); `alias_key` is the identity, `name` is provenance, so first-wins is
  arbitrary-but-deterministic and that is sufficient. Say so rather than leaving
  the writer to invent a rule.
- **(c) `n_seen` has exactly one unit: +1 per `sample` row that newly points at
  the alias.** The draft used four different units in four places (R-11.1 "a
  re-seen alias increments"; R-11.8 "per referencing sample"; migration step 4
  "per label sighting"; step 3 seeding self-aliases at 0 while the Why describes
  a self-alias's `n_seen` as the 131× correct-label count). **Reconciled:** at
  *ingest*, +1 per newly-pointing sample. At *migration*, +1 per historical
  sighting (step 4) — which is the same quantity counted retrospectively, and is
  why step 3's self-aliases seed at 0 and are then incremented by the step-4
  fold of self-name entries. The Why's 131× is the post-step-4 value, not a
  seeded one.
- **(d) `first_seen` / `last_seen` are `Sys.time()`** at materialisation, not the
  event's file date. They record when *we* saw the label, which is what
  `pending_features()` sorts on; the file date is already on the sample.
- **(e) `lab_method` dedup uses `.rc_key(method)`, not raw `method`.**
  `.rc_lab_method_candidates()` (`R/reconcile.R:161`) already keys on
  `.rc_key(cand$method)`; if commit creates by a raw key while reconcile looks up
  by a folded one, **the row created by one run is invisible to the next**, so
  every run makes a new dangling method and nothing ever dedups. R-11.5a's lookup
  and this create **must use the identical expression** — that is the whole
  contract between them.

**Payload enrichment happens here, not at reconcile (cold review C2).** R-11.9
needs the alias uuid in the review payload, but reconcile builds its review
tibble before the alias exists (D8). Resolution: both `.ct_materialise_*`
functions return a per-row surrogate uuid, and `commit_event()` **rewrites
`resolved$review`'s payloads with it before calling `.ct_commit_review()`**. This
is the only place where the row, its review item, and its alias uuid all exist at
once.

**Concurrency (cold review C22).** The find-or-create is a code-side upsert with
no DB uniqueness (R-11.1 — the domain forbids a unique constraint on
`name`/`alias_key`). It runs inside `commit_event()`'s existing
`db_transaction()` (A40), and **A8 (MVP is single-process) is what makes that
sufficient.** If A8 is ever relaxed, this is the first thing that breaks.

`.ct_find_or_create_sample()` / `.ct_resolve_samples()` re-key from
`uuid_feature` to `uuid_feature_alias` per R-11.7's rule (resolved → match by
resolved feature; pending → match by alias uuid). `.ct_commit_analyses()`
applies the matched method's `conversion_constant` (when non-NA) to `value` and
`rl_low`/`rl_high` before writing, and writes **no** units column (D7 reversed).

**(f) A units mismatch never creates a second `lab_method`.** If a row's
`units_raw` differs from the matched method's recorded `units`, the row still
commits against that **same** method and the mismatch is recorded for
confirmation-time review (R-11.11). Creating a second row would give the same
determination a second `uuid_lab`, and since `.rc_find_existing()` keys on
`a.uuid_lab`, a lab reissuing a report with corrected units would then commit a
**duplicate analysis instead of superseding** — both visible in `v_measurement`,
neither flagged. Units are a property, not an identity (D7/A63).

Criteria: a file with 19 clean rows + 1 unknown-feature row commits **all 20**
(19 resolved, 1 dangling) and archives — nothing stranded; the dangling row is
absent from the `v_measurement`-equivalent join until resolved; the
`ingest_file` state is terminal (`archived`) legitimately, because the data
*did* land; re-ingesting the same measurement **from different bytes** →
`already_present` (a pinned two-run idempotency test — see R-11.7's false-green
note: same-bytes is caught by hash dedup upstream and proves nothing); two files
with the same unknown method reuse **one** `lab_method` row; two files with the
same unknown feature reuse **one** pending alias; `n_seen` increments per
referencing sample (unit (c)).

**No change needed to `.ct_set_file_states()` — but an existing assertion flips
(cold review C20).** `R/commit.R:331` already computes `needs_review_only <-
n_review > 0 && n_clean == 0`, and commit-everything makes `n_clean > 0`, so the
"archives legitimately" criterion falls out for free. The unflagged corollary: an
event whose rows are **all** feature-unknown now flips `needs_review` →
`archived`. Existing `needs_review` assertions in `test-commit.R` and the plan-10
e2e tests **will go red, and that is this plan being right.** Update those
assertions to the new expectation; do **not** weaken them, and do not let a
worker "fix" the code to keep them green — that is exactly the [NO SILENT
DEVIATION] trap this note exists to pre-empt.

<!-- block: B-11.9 -->
## R-11.9 Review items: guesses and shortlists

Review items name **features**, never bare UUIDs (today the ambiguous payload
carries `candidates=<uuid>|<uuid>`; the 0-hit payload carries nothing). Required
shape:

> Unknown feature 'B..So3' previously found for B.S04 and B.S03

Two tiers, for bulk confirmation:
- **best guess** (a single confident candidate from a derived source — prefix
  map / an `auto_assign = FALSE` alias with one owner): carries its basis
  ("prefix map B→MW", "seen 15×") so a bulk yes-to-all is informed;
- **no confident guess**: optional shortlist ranked by `n_seen` (a ranking,
  never a decision).

**The alias uuid and `source_hash` are not the same kind of thing (cold review
C18) — the draft conflated them.** They travel by different routes:
- **`source_hash` is a review *column*.** `.ct_commit_review()`
  (`R/commit.R:298`) **already reads** `review$source_hash` if the column is
  present, so **no commit.R change is needed** — the missing piece is purely
  reconcile-side: add `source_hash` to `.rc_proto_review()`
  (`R/reconcile.R:38-40`), populated with the **first `source_hash` of the
  group**. (Grouping means one review row can span several source hashes; first
  is deterministic and sufficient for provenance.)
  - **The same one-column fix applies to the *skipped* proto (F3 / A-3).**
    `.rc_proto_skip()` (`R/reconcile.R:35-37`) also has no `source_hash` column,
    so `.ct_record_already_present()` (`R/commit.R:274`) writes every
    `already_present` provenance row with `source_hash = NA` — breaking A1's
    row-exact hash linkage. Add `source_hash` to `.rc_proto_skip()` and populate
    it in the `already_present` branch of `.rc_three_way()`
    (`R/reconcile.R:542-546`; the row's own `source_hash` is in scope there). No
    further `commit.R` change is needed — `.ct_record_already_present()` already
    reads the column if present. **Criterion:** an `already_present` skip commits
    a `change_log` provenance row whose `source_hash` is the incoming row's hash,
    not NA (pinned at the DB level, not against a hand-built skipped tibble — the
    unit-green/seam-broken class).
- **The alias uuid goes in the payload *string***, as `alias_uuid=<uuid>`, and is
  written **at commit** by the R-11.8 payload rewrite — it does not exist at
  reconcile time (D8).

Criteria: a genuinely novel string yields an item with **no** suggestions and
says so (never a fabricated guess); grouping unchanged (one item per normalised
`feature_raw`; the A44 NA sentinel still groups); every item carries a
resolvable alias uuid; an `unknown_analyte` item names the lab method and any
suggested analyte (fuzzy analyte match is suggestion-only, never auto-link).

<!-- block: B-11.10 -->
## R-11.10 `confirm_feature_aliases()` (public)

```r
confirm_feature_aliases(uuid_alias, uuid_feature, confirmed_by,
                        override = FALSE, db = st_config("live_db"))
# vectorised over uuid_alias/uuid_feature (bulk confirmation, D-domain rule);
# -> invisible(tibble(uuid_alias, uuid_feature, n_samples, action))
```

Inside one `with_db_write()` transaction, per item, **all** via the plan-09
mutation layer (A32/A40) with `change_log` provenance:
1. validate the alias exists and the feature exists;
2. **collision check** (D5): would linking this alias put two `sample` rows on
   the same (feature, date)? Compute before writing anything.
   - collisions and `override = FALSE` → **abort**, class
     `sampletidy_error`, naming each colliding (feature, date) and its sample
     uuids, and writing **nothing** — a collision usually means the operator
     picked the wrong feature;
   - `override = TRUE` → proceed to (3) and (4);
3. `db_update` the alias: `uuid_feature`, `confirmed_by`, `auto_assign = TRUE`,
   and `kind` **only if the alias's current kind is `"pending"`** → then
   `"transcription_error"`; **otherwise leave `kind` untouched** (cold review
   C15). The draft set `transcription_error` unconditionally, which would relabel
   a confirmed `descriptive` (`B.BORE`), `mask_long`, or `historical_code` alias
   as a transcription error — destroying the classification the migration works
   to assign, and collapsing the `old ≠ misspelling` distinction the domain
   treats as load-bearing.
4. **merge** each collision: re-point the newly-resolved sample's analyses onto
   the pre-existing sample, then delete the emptied sample. Pins (cold review
   C14 — the draft under-specified all three, and the last was a real bug):
   - **Winner = the sample NOT reached through the confirmed alias.** The
     pre-existing sample is the one whose identity was never in doubt; the
     newly-resolved one is the arrival. Deterministic even when both were created
     by plan-11 commits.
   - **The loser's differing `organisation`/`person`/`datetime` are discarded,
     and that is recorded** — log a `provenance` `change_log` row naming the
     loser's uuid and the discarded values, so the merge is reconstructible. Do
     not silently drop them.
   - Per analysis, if (feature, date, analyte, method) is already occupied —
     A45's key — compare by **A14**: equal → drop the duplicate analysis and log
     a `provenance` `change_log` row (`already_present` semantics); different →
     **leave the existing row's value untouched**, but **still re-point the
     duplicate analysis onto the winner sample** and open a `value_conflict`
     review item naming **both** analysis uuids. *The draft said "leave the
     existing row untouched" and deleted the emptied sample in the same step —
     which would **orphan** the conflicting analysis on a deleted sample.* Two
     analyses on one sample with the same key is a state the DB permits and the
     conflict item exists to resolve; an orphan is not.
   - **Delete the emptied sample only after every analysis has moved.**

Criteria: confirming resurfaces the previously-dangling samples in the
`v_measurement`-equivalent join (a pinned before/after test); confirming the
same alias→feature twice is idempotent; a collision with `override = FALSE`
aborts and writes **nothing** (pinned: row counts across every table unchanged —
the throw-after-partial-write test); the same call with `override = TRUE` merges,
and a genuine value difference opens a `value_conflict` item **without**
overwriting the existing value; confirming to a *different* feature than an
existing `confirmed_by` row is an error, not a silent second row; an unconfirmed
guess is never written as confirmed; **after confirmation the same incoming
label auto-assigns and opens no review item.**

**Pin the ambiguity nuance.** That last criterion holds for the *unknown* case
only. Confirming one of a genuinely **ambiguous** key's aliases does **not** stop
future ambiguity: the key still resolves to >1 distinct feature, so narrowing
(date/site) remains the only resolver. Confirmation resolves *those samples*, not
the string. A test must pin this — it is the intuitive-but-wrong expectation a
test author will otherwise encode.

<!-- block: B-11.11 -->
## R-11.11 `confirm_analyte_methods()` (public)

```r
confirm_analyte_methods(uuid_lab, uuid_analyte, confirmed_by,
                        db = st_config("live_db"))
# -> invisible(tibble(uuid_lab, uuid_analyte, n_analyses, n_converted, action))
```

Sets `lab_method.uuid_analyte` via the mutation layer. **No propagation UPDATE
is needed** — analyses already point at the `lab_method`, so linking it lands
every analysis at once. But the values must now be made canonical: for each
affected analysis, convert `value`/`rl_low`/`rl_high` from the **method's**
`units` to the analyte's units via `unify_value()` (D7 reversed — the source
units come from `lab_method.units`, not from a per-analysis column).

An analysis whose method units cannot be converted to the analyte's units is
**not** linked blindly: leave its value alone and open an `unknown_unit` review
item. No collision/merge step is needed here (analyses already share their
sample).

**Units-drift check at confirmation (D7/A63).** Because `lab_method.units` is a
**fallback, not a guarantee**, a bulk conversion of every analysis on the method
can be wrong for some of them. So before converting, check whether this method
has ever been *seen* with units other than its recorded ones (recorded per
R-11.8(f)). If so, **do not convert blind**: surface it — the operator is told
"this method has been seen with units X and Y; check before confirming" and
must resolve it. This is the only moment a human is looking at the method, and
it is the moment the ambiguity matters. It does **not** split the method (D7:
identity excludes units).

Criteria: confirming resurfaces the analyses in the `v_measurement`-equivalent
join and is idempotent; values are converted from `lab_method.units` (a pinned
µS/cm → mS/cm case, per A44's EC conversion); an unconvertible unit opens
`unknown_unit` and does not corrupt the value; **a method seen with two
different units surfaces the drift at confirmation and does not silently
bulk-convert**; after confirmation the same incoming analyte auto-resolves and
opens no review item.

<!-- block: B-11.12 -->
## R-11.12 Pending backlog readers (`R/pending.R`)

A dangling row is invisible to every view **by design** — so without a surface it
is silent work. `ensure_schema()` creates no views (A24), so this is a reader
pair in the existing `review_queue()` style, not a view:

```r
pending_features(con)  # -> tibble(uuid_alias, name, alias_key, n_seen, n_samples, first_seen, last_seen)
pending_analytes(con)  # -> tibble(uuid_lab, name, organisation, method, units_raw, n_analyses)
```

`ingest_dir()`'s report gains two counts: features pending, analytes pending.

Criteria: zero-row results have stable columns; counts match the dangling rows
exactly; the numbers reconcile with `review_queue()`.

<!-- block: B-11.13 -->
## R-11.13 Migration — MOVED to PLAN-13 (A68)

The one-off `dev/migrations/001-alias-indirection.R` is **no longer part of this
plan**. It is `dev/plans/PLAN-13-alias-migration.md`, which owns the script and
`tests/testthat/test-migration-001.R`. Split because it is a separable
deliverable with its own 11-step procedure and criteria, it is the only piece
that touches the live DB, and it named no test file here.

**The ordering constraint travels with the split and still binds:**

> **R-11.1–R-11.12 must not be run against `monitoring.duckdb` until PLAN-13 has
> landed.** Green tests are not evidence that it is safe to point the new code at
> the live DB.

Two hard couplings, not just a shared schema:
- **(a)** R-11.4 removes the `feature_mask` lookup (`R/reconcile.R:76`) on the
  explicit grounds that its `long` names are imported by the migration's step 5.
  Land plan 11 without that step and every live `mask_long` match **regresses to
  `unknown`**.
- **(b)** Without the migration the live DB has no `feature_alias` and no
  self-aliases, so `.rc_feature_candidates()` returns zero rows for *everything*
  — **100% of live data would commit dangling.**

The test suite is unaffected either way: `helper-db.R` builds the DDL directly
and seeds aliases itself, so R-11.1–R-11.12 can be built and gated green with no
migration in existence. That is what makes the split safe.

<!-- block: B-11.19 -->
## R-11.19 Lab-method candidate resolution: exact name first (A65 — live defect)

Two `lab_method` rows may legitimately differ only in how the lab spelled the
name. The live registry has exactly this: `Standing Water Level` and
`Standing water level`, both `organisation = ACIRL`, both `method = field`, both
pointing at the **same** analyte. **These are genuinely different methods and
both rows are kept** (user, binding — methods retain the capitalisations reports
actually use). The bug is in the matcher, not the data.

Today `.rc_key()` folds them together, `.rc_lab_method_candidates()`
(`R/reconcile.R:159-166`) returns **2**, and `.rc_resolve_analytes()` requires
exactly 1 — so it falls through to the CAS branch, finds no CAS, and lands
`unknown_analyte`. **Every ACIRL standing-water-level reading currently strands
in review.** Verified directly against the live registry.

New resolution order:
1. **Exact raw-name match**, case-sensitive, on `(name, organisation, method)` →
   that row wins. The report said `Standing Water Level`, so it matches the
   `Standing Water Level` row. **This is not attempted at all today** — the code
   folds first and then cannot disambiguate. This step is the actual repair.
2. Else the folded match (today's behaviour). If every survivor resolves to
   **one** analyte, it is a **hit**, not an ambiguity — the exact parallel of
   R-11.4's "several aliases pointing at the same feature is a hit". The pick
   must be **deterministic** (A45 keys the analysis on `uuid_lab`, so an
   unstable pick would create a duplicate analysis on the next run).
3. Else (survivors span >1 distinct analyte) → ambiguous → review.

Criteria: an incoming `Standing Water Level` resolves to the row spelled that
way, and `Standing water level` to the other — pinned separately, so a matcher
that always returns the same row fails; a third, unseen spelling
(`STANDING WATER LEVEL`) resolves to one analyte as a hit and picks the same
`uuid_lab` on a re-run (idempotency); two candidates spanning **different**
analytes still go to review; the existing R-8.3 tests stay green.

<!-- block: B-11-fixtures -->
## Fixtures

Extend `seed_db()` (`helper-db.R`) to the new shape. Seeded features keep their
existing uuids; each gains a self-alias.

**First, the test `feature` DDL must gain `date_start DATE, date_end DATE` (cold
review C11).** `helper-db.R:15-24` declares `feature(uuid, name, site, flow,
matrix, geom_wkt, virtual)` — **no `date_end`**. The live table *does* have
`date_start`/`date_end` (verified); the test DDL is a subset. Without this column
the "defunct feature" fixture below and R-11.4's entire `date_end`-narrowing
criterion are **unreachable** — and since D9 makes `date_end` the *only*
narrowing rule left, that would silently reduce R-11.4's narrowing coverage to
zero. The draft never said to add it.

Add:
- a resolved alias (`bs03alt` → `f-0003`) for the two-labels-one-sample test;
- an **ambiguous** key: two aliases with one `alias_key` → two live same-site
  features (for R-11.4 and the R-11.10 ambiguity nuance);
- a same-key pair where one feature is **defunct** at the fixture date
  (`date_end` set) → the narrowing auto-resolve case;
- an `auto_assign = FALSE` alias (never a candidate; a suggestion source);
- a dangling `lab_method` + analysis with `units_raw` (for R-11.11 conversion);
- an **existing pending alias** and an **existing dangling `lab_method`** that a
  second event re-encounters — the R-11.5a natural-key-lookup fixtures. Without
  these, R-11.5a's dedup path is never exercised and the idempotency hole
  reopens untested.

**Constructed inline, not seeded (cold review C12):** the D6 pin needs a row that
is feature-unknown **and** carries an unconvertible unit. `test-reconcile.R`
builds its result rows in-test, so this is reachable — build it there rather than
seeding it. Stated because the draft's criterion had no fixture and a writer
would have assumed one was missing.

**Real-name regression fixtures** for R-11.3 — **three** committed
newline-delimited lists, names only, no data (permitted; EPA-public per the
real-corpus decision, and the single sanctioned A3 exception):
- the 894 `feature.name` values;
- the 247 `analyte.name` values;
- the 360 `(organisation, name, method)` triples.

Each fixture's **header line records its own row count and its distinct-key
count** (894/894, 247/246, 360/359). The test reads those from the file — **no
count literal appears in the test source**, so adding an analyte cannot rot it.
The two known collisions (`Carbophenothion`; the two ACIRL
`Standing Water Level` spellings) are listed in an explicit allowlist in the
fixture header, so the live property check (R-11.3(b)) fails on the *third*
collision, not the first.

**`analysis` must NOT declare a units column** (D7 reversed). `helper-db.R`
already shipped one — see the revision note below.

**⚠️ helper-db.R + FIXTURES.md already landed and must be REVISED, not extended
(2026-07-22).** Phase-4 dispatch 1 (`40f9fba`) landed the fixture foundation on
2026-07-17, *before* the 2026-07-19 fold-ins and this 2026-07-22 review. Three
things in it are now wrong and a resumed Phase 4 must not simply carry on from
dispatch 2:
1. `analysis.units_raw` was added — **remove it** (D7 reversed / A63); the units
   belong on `lab_method`, which needs new `units` and `conversion_constant`
   columns instead.
2. The `feature` DDL is missing `lon`/`lat` (NOT NULL live) — **add them**
   (R-11.17). It correctly keeps `virtual`; the comment calling that column
   "TEST-ONLY drift" is wrong and must be deleted (A67 — the column exists live).
3. The seed needs the R-11.19 fixture: two `lab_method` rows differing only in
   name capitalisation, same org, same method, one analyte.
FIXTURES.md carries the same three corrections in its §"Seed DB".

<!-- block: B-11.20 -->
## R-11.20 `feature_alias` in `.st_mutate_allowlist` (Phase-3 D1 — blocking)

R-11.1 states in passing that "`feature_alias` is added to `.st_mutate_allowlist`
in `R/mutate.R`", but **no criterion pinned it and no manifest unit owned it**
(found by the 2026-07-22 cold review, verified against source). Today
`R/mutate.R:40-43` reads:

```r
.st_mutate_allowlist <- c(
  "feature", "feature_mask", "analyte", "analyte_mask", "lab_method",
  "project", "sample", "analysis", "asset", "review_queue"
)
```

`.st_validate_table()` (`R/mutate.R:47-51`) admits only these plus `^ingest_`.
So **every `db_append()` in R-11.8 and R-11.10 aborts** — the pending-alias
materialisation, i.e. the whole commit-everything path. Nothing catches it until
commit tests run, and it reads as a mysterious mutation-layer refusal rather than
a missing list entry.

**Fix:** add `"feature_alias"` to `.st_mutate_allowlist`.

Criteria: `db_append(con, "feature_alias", ...)` succeeds and writes a
`change_log` row; a table still outside the allowlist (e.g. `"guideline"`) is
still refused with `sampletidy_error`; the existing allowlist entries are
unchanged (regression — the list is a security boundary, not a convenience).
Test in `test-mutate.R`.

<!-- block: B-11-whole-package-code-review -->
## Whole-package code-review fold-ins (2026-07-19)

The 2026-07-19 whole-package review (`dev/CODE-REVIEW-2026-07-19.md`, triaged in
`dev/CODE-REVIEW-2026-07-19-TRIAGE.md`) surfaced five defects that live in the
exact functions this plan is already rewriting. They fold in here — **not** as a
separate plan — so the Phase-6 implementer writes `reconcile_event()` /
`.rc_resolve_units_values()` / `.ct_commit_analyses()` / `.ct_find_or_create_sample()`
correctly *once*. Independent defects PLAN-11 does not touch are in PLAN-12.

**Seam-table deltas** (add to the producer→consumer table above):

| producer | consumer | fields |
|---|---|---|
| `assemble_events` (R-7.3) | `reconcile_event` stage-0 (R-11.14) | `needs_review` (lgl), `review_kind` (chr), `review_payload` (list) — **must be read**; today they are dropped |
| `.rc_resolve_units_values` (R-11.16) | `.rc_three_way` → `.ct_commit_analyses` | `quantified` = `parse_value()`'s value (NOT re-derived from `below_detection`); `rl_high` (dbl, `>`-rows) |
| acirl adapter (R-11.15) | `.st_join_samples_onto_results` | synthetic `lab_sample_id` on **both** results and samples → exact-match join, no feature-only fallback |

<!-- block: B-11.14 -->
### R-11.14 Fold assembly's inline review flags into the reconcile conveyor (F1 / A22 consumer seam)

CONTRACT A22 pins that assembly *marks* review-worthy rows inline
(`needs_review`/`review_kind`/`review_payload` on `event$results`, set at
`assemble.R:164-172` for `sample_datetime_mismatch` and `:330-338` for
`foreign_work_order`) and **"reconcile folds them into its own review output."**
Nothing does today: `reconcile_event()` has no stage that reads those columns, so
a flagged row whose feature/analyte/units all resolve lands in `clean` and
commits with **no review item** — the flag is silently discarded (verified;
root cause is the plan-level gap A-1, not a worker slip).

This is the natural extension of R-11.5's funnel→conveyor rework. Add a
**stage-0** to `reconcile_event()`, run **before** the R-8.1 QC filter: partition
rows with `needs_review == TRUE` out of `active` into `review`, building a review
tibble from `review_kind` (→ `kind`) and `review_payload` (→ `payload`, serialised
deterministically), grouped and counted exactly like `add_review()` so the R-8.8
completeness count still reconciles. The row does **not** also flow to `clean`
(these are "we don't trust this row" flags, distinct from the commit-everything
feature-pending rows, which *do* commit).

Interaction with D6 (restated for A-2): once this exists,
`sample_datetime_mismatch` genuinely *holds* — which is what D6 and the
`cypher-and-feature-alias` memory already assume. **D6 is only implementable for
the datetime kind once R-11.14 lands**; before it, the flag was discarded and the
row committed with a first-match date.

Criteria: an event with one `needs_review` row → `reconcile_event()`'s `review`
output contains it and `clean` does **not**; the item's `kind` is the row's
`review_kind`; `counts` still reconciles (every input row in exactly one of
clean / review / skipped, R-8.8); a `foreign_work_order`-flagged non-NCP row
(A22 / plan-07 R-7.4) lands in review, not committed; a
`sample_datetime_mismatch`-flagged row is held, not committed with an arbitrary
date. **Seam test (mandatory, real upstream):** feed real `assemble_events()`
output (not a hand-built stand-in) carrying a flagged row into the real
`reconcile_event()` — this is the discriminator the read-only audits structurally
miss (A-1).

<!-- block: B-11.15 -->
### R-11.15 ACIRL synthetic per-column `lab_sample_id` (F2 / A-5) — cross-plan edit to `adapter-acirl-field.R` (06) + `assemble.R` (07)

ACIRL water-sheet columns each carry their own visit date, but `ir_results` has
no column to link a result to *which* sample-column it came from, and ACIRL
results have `lab_sample_id = NA`. `.st_join_samples_onto_results()`
(`assemble.R:148`) then falls back to a **feature-name-only** join, so a feature
sampled at two visits matches both sample rows and takes the *first* non-NA
datetime (`:174-179`) — visit-2 measurements are re-dated to visit-1 and flagged
`value_conflict`, which R-11.14/F1 then correctly holds (but the *data* is still
mis-dated at the point it is flagged, and the second sampling event never exists).

**Fix:** the ACIRL adapter emits a **synthetic per-column `lab_sample_id`**
(`"<sheet>!c<col>"`) on **both** the results rows and the samples rows it derives
from that column. This flows through the *existing* exact-match branch of the
join (`assemble.R:146`), needs no IR schema change, gives every result its own
visit's date, and eliminates the spurious mismatch flags. `lab_sample_id` is
IR-internal for ACIRL (not a DB key — A45 pins the analysis key is
feature/date/analyte/method, `lab_sample_id` can never be part of it), so nothing
downstream changes.

This is an **adjudicated cross-plan edit** (extends A52's scope to plans 06/07),
not an ownership transfer — plans 06/07 keep their files.

Pitfall note (test authors): the synthetic id must be **stable across a re-parse
of the same file** (idempotency) and **distinct per column**; key it on the
sheet name + column index, both of which are stable.

Criteria: after `assemble_events()` on the two-visit ACIRL fixture
(`2400-9999-01_Test_WMF.xlsx`, T.S01/T.S02 sampled 24 **and** 25 May), a 25-May
result carries `sample_datetime_raw = "25/05/2025"` (**not** re-dated to 24 May);
**no** ACIRL result is flagged `value_conflict`/`sample_datetime_mismatch` for a
spurious multi-date match; both sampling dates exist as distinct samples in the
committed DB. Pinned by an e2e assertion on **both** visit dates (today's e2e
asserts only "date non-NA" — T-1). Coupled to R-11.14: they are the two halves of
one silent-commit hole and must be green together (review priority #1).

<!-- block: B-11.16 -->
### R-11.16 `quantified` from `parse_value()`; write `rl_high` (F4)

`parse_value()` (`values.R:62,69`) correctly returns `quantified = FALSE` for a
`>`-prefixed or `BDL` reading and a non-NA `rl_high` for `>`-rows. But
`.rc_resolve_units_values()` (`reconcile.R:285`) and `.ct_commit_analyses()`
(`commit.R:187`) both **re-derive** `quantified` from `below_detection` alone, so
a `>2000` row (`below_detection = FALSE`) commits `quantified = TRUE`,
contradicting `parse_value()` and DESIGN's semantics; and `rl_high` is parsed and
then dropped (`commit.R:195` writes only `rl_low`; `analysis.rl_high` — which
exists live — is never populated).

Since R-11.6 already rewrites `.rc_resolve_units_values()` and R-11.8 rewrites
`.ct_commit_analyses()` (adding `units_raw`), fold the fix into those rewrites:
- `.rc_resolve_units_values()` puts `parsed$quantified` onto `kept$quantified`
  (the column already exists) and carries `parsed$rl_high` through as
  `kept$rl_high`;
- `.ct_commit_analyses()` uses `clean$quantified` (no re-derivation) and writes
  `analysis.rl_high` from `clean$rl_high`.

Pending-analyte rows (R-11.6) still skip conversion; `quantified`/`rl_high` are
provenance and pass through unconverted like `value`.

Criteria: a `>2000` DB row has `quantified = FALSE` and `rl_high = 2000`; a
literal `BDL` DB row has `quantified = FALSE`; a `<0.01` row keeps `rl_low = 0.01`
(existing pin) and `quantified = FALSE`; a plain-numeric row stays
`quantified = TRUE`. (Today only `<`-rows are pinned at the DB level.)

<!-- block: B-11.17 -->
### R-11.17 `add_feature()` aligned to the live `feature` schema (F5 / A-4)

**Re-probed 2026-07-22 against the authoritative DB (A67); the 2026-07-19
probe hit the dashboard's derived copy and got this half wrong.** The live
`feature` table has **19 columns**; `name`, `site`, **`lon`, `lat`** are **NOT
NULL**; `geom_wkt` is nullable; and **`virtual BOOLEAN` DOES exist** (all 894
rows FALSE). `add_feature()` (`mutate.R:324-338`) omits `lon`/`lat` and so
violates NOT NULL — it is a **broken exported API** (A16), green only because
`helper-db.R`'s test DDL omits those two columns. Its `virtual` argument is
**fine and stays**; the earlier "drop `virtual`" instruction was the artefact of
the wrong DB.

Fix (cross-plan edit to `mutate.R`, owned by 09; and `helper-db.R`, owned here):
- signature → `add_feature(name, site, lon, lat, flow = NA_character_,
  matrix = NA_character_, geom_wkt = NA_character_, virtual = FALSE, actor,
  reason)`; `checkmate` require `name`/`site` (string) and `lon`/`lat` (number).
  **`virtual` is KEPT** (A58, corrected 2026-07-22): the "drop it" instruction
  rested on the dashboard-copy misreading (A67) — the column **exists live**,
  and `add_feature()` may be called by code that uses it. It stays optional,
  defaulting FALSE. **The real defect is the missing `lon`/`lat`**, which are
  NOT NULL live, so `add_feature()` genuinely cannot insert against the live DB.
- **Reconcile `.st_test_core_ddl`'s `feature` to the live 19-column shape**
  (**keep** `virtual`; **add** `lon`/`lat` NOT NULL + the other live columns) —
  this is A-4's DDL reconciliation, and the missing `lon`/`lat` is what let F5
  stay green. This composes with the plan-11 `feature` seeding (each feature
  still gains a self-alias).
- add a `skip_if`-gated meta-test that diffs `.st_test_core_ddl`'s `feature`
  columns against `information_schema.columns` when `SAMPLETIDY_CORPUS_DB` is set,
  so future drift fails loudly.

Criteria: `add_feature("X","SiteA", lon=150.0, lat=-33.0, ...)` inserts against a
seed DB with the live-shaped DDL and the `feature` row round-trips with those
coordinates; the `skip_if`-gated meta-test above diffs `.st_test_core_ddl`'s `feature`
columns against `information_schema.columns` when `SAMPLETIDY_CORPUS_DB` is set and fails
on any drift (this is the plan's ONLY drift detector — it is a criterion, not a nicety);
omitting `lon`/`lat` is a `sampletidy_error` at the argument check,
not a DB error; **the test DDL DOES declare `virtual`** (A58/A67 — the column
exists live on all 894 rows; the earlier "drop it" reading came from the dashboard's
derived copy);

<!-- block: B-11.18 -->
### R-11.18 Distinct datetimes are distinct samplings (F9 — DECIDED: two samples, user 2026-07-19)

Today a 09:00 reading and a 15:00 reading at the **same feature+date** collapse
onto one sample: `.ct_find_or_create_sample()` (`commit.R:95-104`) narrows by
datetime only `if (nrow(cand) > 1)` and, on no datetime match, returns
`cand$uuid[[1]]` regardless. **User decision: two readings at one feature+date
with different non-NA clock times are distinct samplings → distinct `sample`
rows.** This refines A11 (see A62).

The fix must land in **both** rewrites, consistently, or reconcile and commit
disagree (reconcile would flag the second reading `already_present` and it would
never reach commit to become a new sample):

- **`.rc_find_existing()` (R-11.7 rewrite):** when the incoming `sample_datetime`
  is non-NA **and every** candidate's `s_datetime` is non-NA **and** none equals
  the incoming one → return `NULL` (no existing match → the row is new/clean).
- **`.ct_find_or_create_sample()` (R-11.8 rewrite):** same predicate → **create**
  a new sample rather than reuse.

**The predicate is deliberately narrow (conservative):** create-new fires only
when the distinctness is *provable* — incoming datetime non-NA and **all**
candidates carry a non-NA, differing datetime. If the incoming datetime is NA, or
**any** candidate has a NA datetime (a date-only sample whose time is unknown, so
it might be this very sampling with the time now supplied), fall back to today's
reuse — we never fabricate a duplicate when identity is uncertain. A candidate
whose datetime **equals** the incoming one is still reused (the matching sampling).

`.ct_resolve_samples()`'s in-batch key already includes datetime
(`commit.R:143-147`), so two distinct-time rows in one batch already resolve to
two find-or-create calls; only the DB-candidate reuse needed fixing.

Criteria: a 09:00 and a 15:00 reading of the same analyte at one feature+date →
**two** `sample` rows and two analyses (not one sample, not an `already_present`
skip); a re-ingest of the 15:00 reading matches its own 15:00 sample and is
`already_present` (idempotent — no third sample); a reading with datetime NA at a
feature+date that already has a date-only sample **reuses** it (no new sample); a
reading whose datetime equals an existing sample's datetime reuses that sample.
Pinned in both `test-reconcile.R` (`.rc_find_existing`) and `test-commit.R`
(`.ct_find_or_create_sample`).

### A-2 correction (Open/deferred wording)

The Open/deferred note "`sample_datetime_mismatch` may over-flag the legitimate
multi-day case" **understates the state**: it is not over-flagging, it is
*mis-dating plus zero flags surviving* (F1+F2). R-11.14 makes the flag survive
(hold), and R-11.15 removes the mis-dating at the source for ACIRL. Update that
note when these land.

<!-- block: B-11-gates -->
## Gates

- Per-plan: `testthat::test_file()` green for `test-feature-alias.R`,
  `test-pending.R`, and every amended test file in the `Amends` table above —
  `test-reconcile.R`, `test-commit.R`, `test-mutate.R`, `test-assemble.R`,
  `test-adapter-acirl.R`, `test-e2e-pipeline.R`.
- **Baseline note (2026-07-22).** The suite is currently and legitimately
  TDD-red: 1 failure + 43 errors, all `Table "s" does not have a column named
  "uuid_feature"`, in `test-reconcile.R` (22), `test-e2e-pipeline.R` (8),
  `test-ingest.R` (9), `test-commit.R` (5). That is Phase-4 dispatch 1's schema
  change landing ahead of the production amendments — the expected state, not a
  regression. 928 tests pass. Plan 10's four real-corpus gates are **green over
  the full 265-file corpus** (433 assertions, 0 failures) and were run at this
  same commit; they do not use `seed_db()`.
- **No `analysis` table in any DDL declares a units column** (D7 reversed) —
  a grep, because the reversed decision already shipped once in `helper-db.R`.
- Full `devtools::test()` green; `devtools::check()` no new errors/warnings
  (A47's non-portable-fixture WARNING is pre-existing).
- Plan-10 e2e green, **including its idempotency run twice in a row** — the
  property most at risk from this plan.
- The R-9.1 direct-write lint stays clean (`feature-alias.R`/`pending.R` must
  not raw-write; note the A40 comment false-positive).
- Order-shuffled run agrees with default order.
- **T-1 (review-gate strengthening).** The R-10.2 e2e "review_queue holds the
  engineered unknowns" test (`test-e2e-pipeline.R:185-197`) currently asserts only
  `nrow(reviews) >= 0` + `expect_type(report,"list")` — a tautology (the fifth
  "gate that cannot fail", cf. A46/A47). Replace it with the pinned contract:
  `review_queue` contains **exactly** the engineered unknowns and nothing else,
  and QC skip counts equal the fixture's known QC row count. This is the gate that
  would have caught F1/F2, so it must be strengthened **with** R-11.14/R-11.15,
  green together. (The suite-wide sweep for other vacuous assertions is PLAN-12.)

<!-- block: B-11-contract-amendments-this-plan -->
## CONTRACT amendments this plan requires (to be adjudicated on landing)

- **A48** — Model (P): `sample.uuid_feature` dropped; `sample` points at
  `feature_alias`; every feature has a self-alias. Supersedes the pinned schema
  block's `sample` row.
- **A49** — duckdb 1.4.1 cannot drop constraints; core-schema changes to
  `sample`/`lab_method` require a table rebuild cascading through `analysis`.
- **A50** — A7 amended: this plan's core-schema migration is **not**
  additive-only and is **not** run by `ensure_schema()` (which stays
  ops-tables-only). It is an operator-run one-off against a backup.
- **A51** — ~~`analysis.units_raw` added (D7)~~ **SUPERSEDED by A63**: no
  `analysis` units column; the units live on `lab_method`. The invariant
  survives — `analysis.value` is canonical iff the row's
  `lab_method.uuid_analyte` is non-NULL; when dangling it is in the *method's*
  units.
- **A52** — `helper-db.R` is owned by plan 11 (the CONTRACT partition had no
  owner for it). **Extended (cold review C8):** the partition table has **no
  plan-11 row at all**. A52 adds one, covering `R/feature-alias.R`, `R/pending.R`,
  `test-feature-alias.R`, `test-pending.R`, `helper-db.R` (the migration moved to
  plan 13 — A68) — and records that plan 11's amendments to `R/reconcile.R`
  (owned by 08), `R/commit.R` / `R/mutate.R` (09), `R/assemble.R` (07) and
  `R/adapter-acirl-field.R` (06), plus the matching `test-<module>.R` files and
  plan 10's `test-e2e-pipeline.R`, are **adjudicated cross-plan edits**, not
  ownership transfers. The authoritative list is this plan's `Amends` table.
- **A53** — `.rc_find_existing` drops its redundant `lm.uuid_analyte` clause
  (method ⇒ analyte); A45's key is unchanged. *Independently verified in cold
  review against `R/reconcile.R:428-440`.*
- **A54** — **A6 amended** (cold review C6 — the conflict the draft never
  declared). A6 pins: *"Unknown feature/analyte/unit never auto-adds registry
  rows (old code auto-added); always a `review_queue` item."*
  `.ct_materialise_lab_methods()` auto-inserts into `lab_method`, which **is** a
  registry table (`.rc_load_registry()`, `R/reconcile.R:16-24`), for exactly the
  unknown-analyte case A6 names. A48–A53 do not cover it.
  **A54:** an unknown name may auto-create a **dangling** `feature_alias`
  (`uuid_feature IS NULL`) or a **dangling** `lab_method` (`uuid_analyte IS
  NULL`), both with `auto_assign = FALSE`; it may **never** auto-create a
  `feature`, an `analyte`, or a **resolved** `lab_method`; and the `review_queue`
  item remains **mandatory**, unchanged.
  **Why this preserves A6's intent rather than gutting it:** A6 exists to stop an
  unknown name laundering itself into ground truth. A dangling row is the
  opposite of ground truth — it asserts *no* identity, it is invisible to
  `v_measurement` and every EPA report (the INNER JOIN auto-hide), it cannot
  auto-assign, and it still raises its review item. What A6 forbade was the old
  code *inventing an answer*; A54 permits only recording the *question*. D10's
  CAS carve-out is the boundary case that shows the line is real: CAS is barred
  precisely because it would create a **resolved** row.
- **A55** — the CONTRACT's **pinned public-API block** gains
  `confirm_feature_aliases()`, `confirm_analyte_methods()`, `pending_features()`,
  `pending_analytes()` (cold review C7). The block does not list them today, and
  its `review_queue()` line explicitly reads *"resolution API post-MVP"* — which
  this plan supersedes. That note is struck.
- **A56** — the A22 consumer seam (assembly *marks* → reconcile *folds*) is now
  implemented (R-11.14). A22's "reconcile folds them into its own review output"
  was never assigned to a plan, so nothing tested the seam (A-1). Workflow lesson:
  a CONTRACT adjudication spanning a producer and a consumer must be named in
  **both** plans' criteria.
- **A57** — value semantics: `analysis.quantified` is `parse_value()`'s
  `quantified` (NOT re-derived from `below_detection`), and `analysis.rl_high` is
  populated for `>`-notation rows (R-11.16). Corrects the old re-derivation that
  committed `>`/`BDL` rows as `quantified = TRUE`.
- **A58** — `add_feature()`'s signature is aligned to the **live** `feature`
  schema (R-11.17): required `name`/`site`/`lon`/`lat` (all NOT NULL live).
  **`virtual` is KEPT** — corrected 2026-07-22 (A67): the column *does* exist
  live (19 cols, all 894 rows FALSE), and the earlier "drop it" instruction came
  from probing the dashboard's derived copy. `.st_test_core_ddl`'s `feature` is
  reconciled to the live **19**-column shape (A-4); the drift that masked the
  bug was the **missing `lon`/`lat`**, not the present `virtual`.
- **A62** — **A11 refined** (user, 2026-07-19; R-11.18/F9): two readings at one
  feature+date with **different non-NA datetimes are distinct samplings**
  (distinct `sample` rows), not one sample. Governs both `.rc_find_existing`
  (R-11.7) and `.ct_find_or_create_sample` (R-11.8). The split fires only when
  distinctness is provable (incoming non-NA and every candidate non-NA and
  differing); a NA datetime on either side falls back to date-granularity reuse,
  so A11's "date first, then datetime when both sides have it" is preserved for
  the uncertain cases.
- **A63** — **A51 reversed.** No `analysis` units column; `lab_method` regains
  `units` + `conversion_constant` (D7). `units` is a **fallback**, pinned as a
  `COMMENT ON COLUMN`, and is **not** part of the method's identity.
- **A64** — `lab_method.reported_as` is **not dead**; it records the reported
  *basis* (`N`/`NH3`/`CaCO3`). The "candidate for removal" note is struck.
- **A65** — lab-method candidate resolution: exact raw name first, then folded
  with "all survivors → one analyte is a hit" (R-11.19).
- **A66** — **D10 reversed**: CAS-hits commit dangling with the CAS as a review
  suggestion.
- **A67** — evidence-DB provenance; three false "corrections" reverted
  (`feature` 19 cols with `virtual`; `lab_method` 360; 14 views not 60).
- **A68** — the migration is **PLAN-13**; its ordering constraint still binds.
- **A69** — live-DB **data** remediation is **PLAN-14**, and item (c) — the 12
  ammonia analyses — is **OPEN pending provenance**, not scheduled work.

*(A59–A61 are PLAN-12's and are deliberately not used here.)*

<!-- block: B-11-open-deferred -->
## Open / deferred

- **~~`sample_datetime_mismatch` may over-flag the legitimate multi-day
  case.~~** **Superseded by R-11.14 + R-11.15 (A-2 correction).** The real state
  was worse than "over-flag": the fallback (feature-key) join *mis-dated* visit-2
  rows to visit-1 and then the flag was *discarded* (F1), so nothing held. ACIRL
  is the adapter that emits result rows without a `lab_sample_id`; R-11.15 gives
  it a synthetic one so the exact-match join fires and no spurious flag is raised,
  and R-11.14 makes any genuine mismatch flag actually hold. Datetime stays a
  "must hold" kind.
- **Replay of pre-plan-11 stranded rows.** This plan stops *new* stranding; rows
  already held need a one-off re-ingest (`reset = TRUE` on
  `ingest_file_set_state`). Small, separate.
- **The dashboard repo's `etl/views.sql` + `build_duckdb.R:710`** must be updated
  to join through the alias (D2). Separate repo, separate change.
- **The derived prefix map** (`B→MW`, `BORE→MW`, `BS→S`): explains 71 of 298
  wrong labels; suggestion-only, and must be collision-tested (a mapped code can
  land on a real different feature — the `B.G005` trap).
- **LLM suggestions from `long` names/descriptions** (`ellmer` is in Suggests):
  suggestion side only, never the commit path.
- **Site on the event, and site-narrowing (D9).** Deferred out of this plan: the
  IR has no site field and only 2 of 3 adapter families could supply one (ALS
  crosstab has `Sample Site:` per A34; ESdat and ACIRL have no obvious source).
  Re-adding it is **purely additive** — `.rc_feature_candidates()` gains a
  `site` argument and narrowing step (3) returns. Buys 3 of 31 ambiguous keys.
  Needs a plan-03/04/05/06 change request for `.st_ir_results_types` /
  `.st_ir_samples_types` plus each adapter's header parse.
- **Site-completion (`S01` → `B.S01`)**: sound (all names are `<site>.<code>`)
  but applies to incoming `feature_raw`, needs the event's site (D9), and does
  not disambiguate. Own plan; naturally pairs with the D9 work above.
- **The D10 CAS-hit carve-out.** A CAS-hit row still strands. Revisit with the
  suggestion/prefix-map work: the plausible resolution is a dangling
  `lab_method` carrying the CAS match as a *suggestion* on its review item, which
  `confirm_analyte_methods()` then confirms — keeping A6/A54's line intact.
- **Retiring `feature.cypher`** and the `project.cypher` twin: after the
  migration is reviewed.
- **~~`lab_method.reported_as` is dead. Candidate for removal.~~
  RETRACTED (A64, user 2026-07-22) — do NOT drop this column.** It records the
  *basis* a result is reported on: ammonium as `N` vs as `NH3`, hardness as
  `CaCO3`. NULL in all 360 rows is a **data gap**, not disuse — the basis
  currently rides in the `lab_method.name` string instead (`Ammonia as N`,
  `Ammonia as NH3`, `Total Alkalinity as CaCO3`). Backfilling it is PLAN-14
  R-14.2, together with the `conversion_constant` that makes it actionable.
