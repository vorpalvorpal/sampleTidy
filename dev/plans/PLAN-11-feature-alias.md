# PLAN 11 — commit-everything, resolve unknown feature & analyte names later

**Owns:** `R/feature-alias.R` (new — the resolve API), `R/pending.R` (new —
backlog readers), `tests/testthat/test-feature-alias.R` (new),
`tests/testthat/test-pending.R` (new),
`dev/migrations/001-alias-indirection.R` (new).
**Amends:** `R/reconcile.R` (`.rc_key`, `.rc_load_registry`,
`.rc_feature_candidates`, `.rc_resolve_features`, `.rc_resolve_analytes`,
`.rc_resolve_units_values`, `.rc_method_preference`, `.rc_three_way`,
`.rc_find_existing`, `.rc_proto_review`, `reconcile_event`),
`R/commit.R` (`.ct_find_or_create_sample`, `.ct_resolve_samples`,
`.ct_commit_analyses`, `commit_event`), `R/mutate.R` (allowlist),
`tests/testthat/helper-db.R` (core DDL + seed), plus regression tests in
`test-reconcile.R` / `test-commit.R`.
**Depends on:** plans 01–10 landed and green.

**Test-file ownership note.** `helper-db.R` has no owner in the CONTRACT's
partition. Plan 11 takes ownership; it is the only plan amending it (see A52).

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
- **D7 — `analysis.units_raw` is added** (orchestrator; flagged for override).
  Forced: see R-11.2. Units live *only* on `analyte.units`; a dangling analysis
  has no analyte, so its value cannot be converted and its reported units have
  nowhere to live. Without this column, confirming an analyte could never
  convert the values it just linked.
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
- **D10 — the CAS-hit (`known_analyte_no_method`) path stays held; explicit
  carve-out** (orchestrator, from cold review C10; **flagged for user
  override**). `R/reconcile.R:196-201` sets `uuid_analyte` from a CAS match with
  `status = "cas"`, which is not in `hit_idx` (`:204`), so the row is dropped to
  review — it strands today and continues to. This sits awkwardly beside the
  plan's headline that unknown analyte now commits, so it is pinned rather than
  left implicit. Rationale for holding: a CAS hit knows the *analyte* but not the
  *method*, so materialising it would auto-create a **resolved** `lab_method`
  (`uuid_analyte` set) — exactly what A6 forbids, and not what A54 licenses
  (which is *dangling* rows only). Committing it dangling instead would discard
  the CAS evidence. Either direction is a real design choice; the status quo is
  the conservative one. **A test pins that a CAS-hit row is held**, so the
  carve-out cannot rot silently. Revisit alongside the prefix-map/suggestion
  work.

## Evidence (measured against `monitoring.duckdb`, duckdb 1.4.1)

**Which DB.** `st_config("live_db")`
(`~/Library/Application Support/org.R-project.R/R/sampleTidy/monitoring.duckdb`)
**does not exist on this machine.** The numbers below were measured against
`/Users/rjs/Documents/dashboard/data/monitoring.duckdb`, re-verified in cold
review (2026-07-17); `/Users/rjs/Documents/leachatetools/test data/monitoring.duckdb`
is a third copy. Row counts agree across feature/sample/analysis/lab_method, so
it is the same lineage. **Name the absolute path when quoting any of this** — the
ambiguity cost the reviewer real time.

Verified directly (re-check before relying on any of it):

- `v_measurement` is `analysis INNER JOIN sample INNER JOIN feature INNER JOIN
  lab_method INNER JOIN analyte`. The `v_measurement_*` family is identical
  through `v_feature_*`/`v_analyte_*`. **Dangling rows auto-hide.**
- `feature` = 894, `sample` = 15,113, `analysis` = 95,737, **`lab_method` = 365**
  → **247** analytes, **60** views. (Corrected in cold review: the draft said
  `lab_method` = 360 here and 365 below, and 245/14 for analytes/views. **Do not
  encode any of these as test constants** except the 894 of R-11.3, which is
  pinned deliberately.)
- `sample.uuid_feature` is **NOT NULL** with a **FK → feature(uuid)**.
  `lab_method.uuid_analyte` is **NOT NULL** with 0 dangling rows.
- **`feature` has no `virtual` column at all** (the draft's "all 894 rows are
  `virtual = FALSE`" was false; CONTRACT's schema block lists it wrongly too, and
  `helper-db.R`'s test DDL *does* have one). The "no provisional features"
  argument is unaffected — it rests on `name`/`site`/`lon`/`lat` being NOT NULL,
  which is verified.
- **DuckDB 1.4.1 cannot drop a constraint at all** (`ALTER TABLE … DROP
  CONSTRAINT` → "No support for that ALTER TABLE option yet!"). Therefore
  neither `DROP COLUMN uuid_feature` nor `ALTER COLUMN … DROP NOT NULL` is
  possible in place on `sample` or `lab_method` — both fail with a dependency /
  FK error, **and dropping the dependent views does not help**. This forces a
  table-rebuild migration (R-11.13). It applies to **(D) as much as (P)**: (D)
  needs `sample.uuid_feature` nullable, which is blocked by the same wall. The
  rebuild is therefore *unavoidable for this plan in any model*, which makes
  (P)'s marginal migration cost ≈ 894 inserts + one backfill expression.
- `analysis` has **no units column**; `lab_method.reported_as` is **NULL in all
  365 rows** (dead). `units_raw` already exists in the IR (`R/ir.R:14`) and
  flows through reconcile — it is simply dropped at commit. (D7.)
- `feature.cypher`: 117/894 features, 2062 raw entries → 370 unique
  `(feature, alias)` pairs (case/punct-folded); 72 are the feature's own name,
  **298 are genuine wrong labels** (222 seen once, 38 seen 2–4×, 38 seen 5+).
  Repeats are **frequency, not bloat** → `n_seen`.
- **31 aliases map to >1 feature.** Date (`date_end`) + site disambiguation
  resolves only **4** (1 by date, 3 by site); the other 27 are non-identifying
  descriptors (`B.BORE` → 8 features) that *should* stay in review. Date/site is
  a **correctness guard**, not a bulk auto-resolver.

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

## The API is the authority; the UI is deferred

The deliverable is the **resolve API**: the only thing that writes a resolution
— validating, idempotent, bulk-capable, recording provenance (`confirmed_by`,
`change_log`). **No UI is specified or built here.** The discipline any UI must
preserve: *the UI presents and executes; the human decides; the API records the
human as `confirmed_by`.* A UI (including an LLM-driven one) may propose and may
call the resolve functions, but never confirms on its own.

## Seam table (producer → consumer; fields that must survive)

| producer | consumer | fields |
|---|---|---|
| `.rc_resolve_features` | `.rc_resolve_analytes` → `.rc_three_way` | `uuid_feature_alias` (chr; NA ⇒ pending **and no existing alias found** — R-11.5a may fill it while `feature_pending` stays TRUE), `feature_pending` (lgl), `feature_raw`, `alias_key` |
| `.rc_resolve_analytes` | `.rc_resolve_units_values` | `uuid_lab` (chr; NA ⇒ pending **and none found** — R-11.5a as above), `analyte_pending` (lgl), `uuid_analyte` (chr, NA when pending), `analyte_raw`, `org`, `method_raw` |
| `.rc_resolve_features` / `.rc_resolve_analytes` | `.rc_method_preference` | resolved `uuid_feature` **or** `uuid_feature_alias`, `sample_date`, `uuid_analyte`; analyte-pending rows excluded (R-11.5b) |
| `reconcile_event` | `.ct_commit_review` | `source_hash` (chr) — a **new `.rc_proto_review()` column**, first of the group (R-11.9/C18) |
| `.rc_resolve_units_values` | `.rc_three_way` | `value` (canonical **iff** `!analyte_pending`), `units_raw` (always), `rl_low` |
| `reconcile_event` | `commit_event` | `clean` carries **all** of the above; dropping any one silently strands a dangling row |
| `commit_event` R-11.8 | `.ct_resolve_samples` | `uuid_feature_alias` now **always non-NA** (pending materialised) |
| `.ct_materialise_*` R-11.8 | `.ct_commit_review` | per-row alias / lab_method **uuid**, used to rewrite the review payload (`alias_uuid=<uuid>`) before it is written — the only point where row, review item and uuid coexist (C2) |
| `confirm_feature_aliases` | `sample` | alias `uuid` → the samples pointing at it |
| `confirm_analyte_methods` | `analysis` | `lab_method.uuid` → its analyses; `units_raw` → conversion |

**Pitfall note (test authors).** The analysis match key is
**(feature, date, analyte, method)** — A45. `lab_sample_id` is *not* a DB column
and can **never** be part of it. A "fresh" fixture row needs a distinct feature,
date, or method — *not* just a distinct lab sample id (this is exactly the A39
fixture bug; do not re-introduce it).

**Pitfall note (test authors).** A pending alias is created **at commit**, not
at reconcile (D8). A reconcile-only test must assert `feature_pending == TRUE`
and `is.na(uuid_feature_alias)`; asserting a `feature_alias` row exists after
`reconcile_event()` alone will fail — correctly.

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

## R-11.2 Schema: `sample`, `lab_method`, `analysis`

- `sample`: **drop** `uuid_feature`; **add** `uuid_feature_alias VARCHAR NOT
  NULL` → `feature_alias.uuid`.
- `lab_method`: `uuid_analyte` becomes **nullable**.
- `analysis`: **add** `units_raw VARCHAR` (D7).

`analysis.units_raw` semantics — pin these, they are the plan's subtlest
invariant:
- It records the units string the lab reported for this analysis. Populated
  **always**, as provenance, resolved or not.
- `analysis.value` is in the analyte's canonical units **iff** the row's
  `lab_method.uuid_analyte` is non-NULL. When dangling, `value` is in
  `units_raw` and canonical units are undefined.
- This is safe precisely because a dangling analysis is invisible to every view
  (INNER JOIN analyte), so **no consumer can ever read a value in the wrong
  units**. The invariant and the visibility rule are the same rule.

Criteria: `seed_db()` produces the new shape; a codebase audit for anything
reading `sample.uuid_feature` is part of this task (grep `R/`, `tests/`);
`v_measurement`'s equivalent join (A24 — the test schema has no views) returns
exactly the resolved rows and a dangling sample does not appear.

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

Criteria: `B.S01`, `B S01`, `BS01`, `b.s01`, `B..S01` share one key; **all 894
real feature names still yield 894 distinct keys** — a pinned regression against
a committed fixture of the real name list. This collision-free property is what
makes the fold safe to auto-assign on, so it must **fail loudly** if a future
name breaks it. NA/blank → NA (the A44 guard).

**The analyte/method side must be pinned identically (cold review C16).** The
draft named this "the risk" and then pinned nothing for it. `.rc_key` is shared
by `.rc_lab_method_candidates()` (`R/reconcile.R:159-166`) for **analyte name and
method** matching, and stripping all punctuation could merge two genuinely
different analytes or methods. Add the same regression, against the same kind of
committed names-only fixture: the **247** real `analyte.name` values yield 247
distinct keys, and the **365** real `(organisation, name, method)` triples stay
distinct under the new key. "The existing tests stay green" is not sufficient —
they were written against the old, weaker fold.

**A44 guard, both halves (cold review C17).** `.rc_key` newly returns NA for
`""`. Today `.rc_feature_candidates()` (`R/reconcile.R:71-79`) survives a blank
*registry* name only via its trailing `cand[!is.na(cand)]` guard: indexing with
an NA on the LHS yields an NA element — the exact A44 phantom-candidate defect.
The new tibble-returning `.rc_feature_candidates()` must retain an equivalent
guard (R-11.4).

## R-11.4 Alias matching + narrowing (`.rc_feature_candidates`, amended)

`.rc_load_registry()` gains `feature_alias`. Because every feature has a
self-alias, a direct name match **is** an alias hit: the two-source lookup
(`feature.name` then `feature_mask.name`) collapses to **one** lookup against
`feature_alias`. **No longer joins `feature_mask`** (its `long` names are
imported by R-11.13; `EPA`/`old` must never match).

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

## R-11.5 Reconciler: the funnel becomes a conveyor (features)

**This is the structural change the draft missed, and the heart of the plan.**
`reconcile_event()` is a funnel: each stage keeps only hits and drops the rest
into `review`, so `active` shrinks. A feature-unknown row is dropped at R-8.2
and **never reaches** `.rc_three_way`, never lands in `clean`, and
`commit_event()` commits only `clean`. Commit-everything is therefore a
**reconciler** change, not a commit change.

`.rc_resolve_features(rows, registry, work_order, site)` now **keeps every row**
and annotates rather than dropping:
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

## R-11.6 Reconciler: dangling analytes

`.rc_resolve_analytes()` likewise keeps misses: `uuid_lab = NA`,
`uuid_analyte = NA`, `analyte_pending = TRUE`. `.rc_lab_method_candidates()` is
unchanged; only the miss path changes.

`.rc_resolve_units_values()` **must not attempt conversion** for
`analyte_pending` rows — there is no analyte, so no canonical units exist. It
passes `value` through unconverted and leaves `units_raw` set (R-11.2).

**The CAS-hit path stays held — explicit carve-out, D10 (cold review C10).** The
draft said "the `known_analyte_no_method` (CAS-hit) path is unchanged", which a
test author cannot act on: `status = "cas"` (`R/reconcile.R:196-201`) is *not* in
`hit_idx` (`:204`), so the row is dropped to review and **stranded** — the very
thing this plan exists to stop. That is deliberate, not an oversight: a CAS hit
identifies the *analyte* but not the *method*, so committing it would auto-create
a **resolved** `lab_method`, which A6 forbids and A54 does not license (A54
covers *dangling* rows only). Committing it dangling would throw away the CAS
evidence. Held is the conservative choice; D10 records it as a real fork.

Criteria: an unknown-analyte row reaches `clean` with `analyte_pending = TRUE`,
`uuid_lab = NA` (or the existing dangling `lab_method`'s uuid, per R-11.5a),
unconverted `value`, and `units_raw` set; a resolved row is still converted
exactly as today (all existing R-8.4 tests stay green); a pending row is **not**
skipped for an unconvertible unit (that check belongs to resolved rows only —
see D6's restatement, which shows this is not the contradiction it looks like);
**a CAS-hit row is still held and does not reach `clean` — pinned, so the D10
carve-out cannot rot silently.**

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
# (name = analyte_raw, organisation = org, method = method_raw, rl_low, rl_high)
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
resolved feature; pending → match by alias uuid). `.ct_commit_analyses()` writes
`units_raw`.

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
- **The alias uuid goes in the payload *string***, as `alias_uuid=<uuid>`, and is
  written **at commit** by the R-11.8 payload rewrite — it does not exist at
  reconcile time (D8).

Criteria: a genuinely novel string yields an item with **no** suggestions and
says so (never a fabricated guess); grouping unchanged (one item per normalised
`feature_raw`; the A44 NA sentinel still groups); every item carries a
resolvable alias uuid; an `unknown_analyte` item names the lab method and any
suggested analyte (fuzzy analyte match is suggestion-only, never auto-link).

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

## R-11.11 `confirm_analyte_methods()` (public)

```r
confirm_analyte_methods(uuid_lab, uuid_analyte, confirmed_by,
                        db = st_config("live_db"))
# -> invisible(tibble(uuid_lab, uuid_analyte, n_analyses, n_converted, action))
```

Sets `lab_method.uuid_analyte` via the mutation layer. **No propagation UPDATE
is needed** — analyses already point at the `lab_method`, so linking it lands
every analysis at once. But the values must now be made canonical (D7): for each
affected analysis, convert `value`/`rl_low` from `units_raw` to the analyte's
units via `unify_value()`.

An analysis whose `units_raw` cannot be converted to the analyte's units is
**not** linked blindly: leave its value alone and open an `unknown_unit` review
item. No collision/merge step is needed here (analyses already share their
sample).

Criteria: confirming resurfaces the analyses in the `v_measurement`-equivalent
join and is idempotent; values are converted (a pinned µS/cm → mS/cm case, per
A44's EC conversion); an unconvertible unit opens `unknown_unit` and does not
corrupt the value; after confirmation the same incoming analyte auto-resolves and
opens no review item.

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

## R-11.13 Migration (one-off, `dev/migrations/001-alias-indirection.R`)

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

**This section is separable from the *test suite*, but is a hard prerequisite for
the *live DB* — the draft's "only coupling is the target schema" was wrong (cold
review C19).**

True and verified: the package's own tests never run the migration
(`helper-db.R` builds the DDL directly), so R-11.1–R-11.12 can be built, tested
and gated green without it. It can be built and reviewed as its own plan.

But two real couplings the draft glossed:
- **(a) R-11.4 removes the `feature_mask` lookup** (`R/reconcile.R:76`) on the
  explicit grounds that "its `long` names are imported by R-11.13". Land
  R-11.1–11.12 without **step 5** and every live `mask_long` match **regresses to
  `unknown`**. That is a hard ordering dependency, not a shared schema.
- **(b) Without the migration the live DB has no `feature_alias` and no
  self-aliases**, so `.rc_feature_candidates()` returns zero rows for
  *everything* — **100% of live data would commit dangling.**

**Therefore, pinned: R-11.1–R-11.12 must not be run against `monitoring.duckdb`
until this migration has landed.** Green tests are not evidence that it is safe
to point the new code at the live DB. If the migration ships as its own plan,
this constraint ships with it.

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

**A real-name regression fixture** for R-11.3: a committed newline-delimited list
of the 894 real `feature.name` values (names only — no data; permitted, they are
EPA-public per the real-corpus decision). The 894-distinct-keys property is
pinned against it.

## Gates

- Per-plan: `testthat::test_file()` green for `test-feature-alias.R`,
  `test-pending.R`, and the amended `test-reconcile.R` / `test-commit.R`.
- Full `devtools::test()` green; `devtools::check()` no new errors/warnings
  (A47's non-portable-fixture WARNING is pre-existing).
- Plan-10 e2e green, **including its idempotency run twice in a row** — the
  property most at risk from this plan.
- The R-9.1 direct-write lint stays clean (`feature-alias.R`/`pending.R` must
  not raw-write; note the A40 comment false-positive).
- Order-shuffled run agrees with default order.

## CONTRACT amendments this plan requires (to be adjudicated on landing)

- **A48** — Model (P): `sample.uuid_feature` dropped; `sample` points at
  `feature_alias`; every feature has a self-alias. Supersedes the pinned schema
  block's `sample` row.
- **A49** — duckdb 1.4.1 cannot drop constraints; core-schema changes to
  `sample`/`lab_method` require a table rebuild cascading through `analysis`.
- **A50** — A7 amended: this plan's core-schema migration is **not**
  additive-only and is **not** run by `ensure_schema()` (which stays
  ops-tables-only). It is an operator-run one-off against a backup.
- **A51** — `analysis.units_raw` added (D7); `analysis.value` is canonical iff
  the row's `lab_method.uuid_analyte` is non-NULL.
- **A52** — `helper-db.R` is owned by plan 11 (the CONTRACT partition had no
  owner for it). **Extended (cold review C8):** the partition table has **no
  plan-11 row at all**. A52 adds one, covering `R/feature-alias.R`, `R/pending.R`,
  `dev/migrations/001-alias-indirection.R`, `test-feature-alias.R`,
  `test-pending.R`, `helper-db.R` — and records that plan 11's amendments to
  `R/reconcile.R` (owned by plan 08) and `R/commit.R` / `R/mutate.R` (owned by
  plan 09) are **adjudicated cross-plan edits**, not ownership transfers.
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

## Open / deferred

- **`sample_datetime_mismatch` may over-flag the legitimate multi-day case.**
  Results tie to samples by `lab_sample_id` first (exact), falling back to
  feature-key only when a result has no `lab_sample_id`. In that fallback, a
  feature sampled on several days matches several sample rows with different
  dates and would false-flag. Verify whether any adapter emits result rows
  without a `lab_sample_id`; out of scope (datetime stays a "must hold" kind).
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
- **`lab_method.reported_as`** is dead (NULL in all 365 rows). Candidate for
  removal whenever `lab_method` is next rebuilt.
