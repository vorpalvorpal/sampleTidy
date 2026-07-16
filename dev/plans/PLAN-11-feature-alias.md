# PLAN 11 — commit-everything, resolve unknown feature & analyte names later

**Owns:** `R/feature-alias.R` (new — the resolve API), `R/pending.R` (new —
backlog readers), `tests/testthat/test-feature-alias.R` (new),
`tests/testthat/test-pending.R` (new),
`dev/migrations/001-alias-indirection.R` (new).
**Amends:** `R/reconcile.R` (`.rc_key`, `.rc_load_registry`,
`.rc_feature_candidates`, `.rc_resolve_features`, `.rc_resolve_analytes`,
`.rc_resolve_units_values`, `.rc_find_existing`, `reconcile_event`),
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
- **D6 — a row that is feature/analyte-dangling AND hits a "must hold" kind**
  (`unknown_unit`, `value_conflict`, `sample_datetime_mismatch`) **is held**, as
  today (user). Commit-everything covers "we know the number, just not where it
  goes" — not "we don't trust the number".
- **D7 — `analysis.units_raw` is added** (orchestrator; flagged for override).
  Forced: see R-11.2. Units live *only* on `analyte.units`; a dangling analysis
  has no analyte, so its value cannot be converted and its reported units have
  nowhere to live. Without this column, confirming an analyte could never
  convert the values it just linked.
- **D8 — reconcile stays read-only** (orchestrator, from A32). Reconcile decides
  *status*; **commit** creates the pending alias / dangling `lab_method` rows
  through the mutation layer. The draft blurred this.

## Evidence (measured against the live `monitoring.duckdb`, duckdb 1.4.1)

Verified directly this session (re-check before relying on any of it):

- `v_measurement` is `analysis INNER JOIN sample INNER JOIN feature INNER JOIN
  lab_method INNER JOIN analyte`. The `v_measurement_*` family is identical
  through `v_feature_*`/`v_analyte_*`. **Dangling rows auto-hide.**
- `feature` = 894, `sample` = 15,113, `analysis` = 95,737, `lab_method` = 360 →
  245 analytes, 14 views.
- `sample.uuid_feature` is **NOT NULL** with a **FK → feature(uuid)**.
  `lab_method.uuid_analyte` is **NOT NULL** with 0 dangling rows.
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
| `.rc_resolve_features` | `.rc_resolve_analytes` → `.rc_three_way` | `uuid_feature_alias` (chr, NA ⇒ pending), `feature_pending` (lgl), `feature_raw`, `alias_key` |
| `.rc_resolve_analytes` | `.rc_resolve_units_values` | `uuid_lab` (chr, NA ⇒ pending), `analyte_pending` (lgl), `uuid_analyte` (chr, NA when pending), `analyte_raw`, `org`, `method_raw` |
| `.rc_resolve_units_values` | `.rc_three_way` | `value` (canonical **iff** `!analyte_pending`), `units_raw` (always), `rl_low` |
| `reconcile_event` | `commit_event` | `clean` carries **all** of the above; dropping any one silently strands a dangling row |
| `commit_event` R-11.8 | `.ct_resolve_samples` | `uuid_feature_alias` now **always non-NA** (pending materialised) |
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
name breaks it. NA/blank → NA (the A44 guard). Existing analyte/method matching
that shares `.rc_key` is re-verified (its tests must stay green — the fold is
now more aggressive on that side too, which is the risk).

## R-11.4 Alias matching + narrowing (`.rc_feature_candidates`, amended)

`.rc_load_registry()` gains `feature_alias`. Because every feature has a
self-alias, a direct name match **is** an alias hit: the two-source lookup
(`feature.name` then `feature_mask.name`) collapses to **one** lookup against
`feature_alias`. **No longer joins `feature_mask`** (its `long` names are
imported by R-11.13; `EPA`/`old` must never match).

```r
.rc_feature_candidates(feature_raw, sample_date, site, registry)
# -> tibble(uuid_alias, uuid_feature) of surviving candidates
```

Procedure: key ← `.rc_key(feature_raw)`; NA → zero rows (A44 guard). Collect
`feature_alias` rows with `alias_key == key` **and `auto_assign`**; resolve to
distinct `uuid_feature`; if >1 distinct feature, narrow by `date_end` then site;
assign iff exactly one distinct feature survives.

Note: several aliases may survive pointing at the **same** feature — that is a
hit, not an ambiguity. Ambiguity is >1 distinct *feature*.

Criteria: one surviving feature → assign (via self-alias or a resolved alias);
zero → `unknown`; >1 distinct feature after narrowing → `ambiguous`; the A44 NA
guard holds; a re-drilled well's old name (`B.G005`) resolves to the live
`B.G005`; a reused code with two live same-site features stays `ambiguous`; a
reused code where one candidate is defunct at `sample_date` auto-resolves to the
live one; `auto_assign = FALSE` aliases never enter the candidate set.

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

## R-11.6 Reconciler: dangling analytes

`.rc_resolve_analytes()` likewise keeps misses: `uuid_lab = NA`,
`uuid_analyte = NA`, `analyte_pending = TRUE`. `.rc_lab_method_candidates()` is
unchanged; only the miss path changes.

`.rc_resolve_units_values()` **must not attempt conversion** for
`analyte_pending` rows — there is no analyte, so no canonical units exist. It
passes `value` through unconverted and leaves `units_raw` set (R-11.2). The
`known_analyte_no_method` (CAS-hit) path is unchanged.

Criteria: an unknown-analyte row reaches `clean` with `analyte_pending = TRUE`,
`uuid_lab = NA`, unconverted `value`, and `units_raw` set; a resolved row is
still converted exactly as today (all existing R-8.4 tests stay green); a
pending row is **not** skipped for an unconvertible unit (that check belongs to
resolved rows only).

## R-11.7 Three-way match with dangling rows (`.rc_find_existing`)

Today: `WHERE s.uuid_feature = ? AND CAST(s.date AS DATE) = ? AND
lm.uuid_analyte = ? AND a.uuid_lab = ?`. Both key columns break on dangling rows
(`= NULL` never matches), so every run would re-commit the same dangling
measurement.

Two changes:
1. **Feature side** — join through the alias. Resolved: match any sample whose
   alias resolves to the same `uuid_feature` (so two *different* labels for one
   feature share one sample). Pending: match on `s.uuid_feature_alias` directly.
2. **Analyte side** — **drop the `lm.uuid_analyte = ?` clause.** It is redundant:
   `a.uuid_lab = ?` pins the `lab_method` row, which determines its analyte. It
   is also the clause that breaks for a dangling method. Dropping it preserves
   A45's (feature, date, analyte, method) key exactly, because method ⇒ analyte.

Criteria: A45's pinned regression (ACIRL field EC lm-0006 vs ALS lab EC lm-0003
→ two rows, not a conflict) stays green — this is the test that proves the
dropped clause was redundant; a dangling measurement re-ingested from a
**different file** matches itself and is `already_present`, not duplicated; a
resolved sample is reused across two different incoming labels for one feature.

## R-11.8 Commit: materialise pending aliases and dangling methods

New commit step, **before** sample resolution (D8 — reconcile is read-only; all
writes are here, through the mutation layer, never raw `dbExecute`):

```r
.ct_materialise_feature_aliases(con, clean, event, actor, reason)
# for rows with feature_pending: find-or-create a feature_alias by alias_key with
# uuid_feature = NULL, kind = "pending", auto_assign = FALSE, n_seen incremented,
# first_seen/last_seen/source_hash set. Returns clean with uuid_feature_alias filled.

.ct_materialise_lab_methods(con, clean, event, actor, reason)
# for rows with analyte_pending: find-or-create a lab_method from
# (name = analyte_raw, organisation = org, method = method_raw, rl_low, rl_high)
# with uuid_analyte = NULL. Dedup by (organisation, .rc_key(name), method) so two
# files with the same unknown method share ONE dangling lab_method.
# Returns clean with uuid_lab filled.
```

`.ct_find_or_create_sample()` / `.ct_resolve_samples()` re-key from
`uuid_feature` to `uuid_feature_alias` per R-11.7's rule (resolved → match by
resolved feature; pending → match by alias uuid). `.ct_commit_analyses()` writes
`units_raw`.

Criteria: a file with 19 clean rows + 1 unknown-feature row commits **all 20**
(19 resolved, 1 dangling) and archives — nothing stranded; the dangling row is
absent from the `v_measurement`-equivalent join until resolved; the
`ingest_file` state is terminal (`archived`) legitimately, because the data
*did* land; re-ingesting the same bytes → `already_present` (a pinned two-run
idempotency test); two files with the same unknown method reuse **one**
`lab_method` row; two files with the same unknown feature reuse **one** pending
alias; `n_seen` increments per referencing sample.

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

The payload gains the **alias `uuid`** (so confirmation can target it) and
`source_hash`. Note the reconcile review tibble has **no `source_hash` column**,
so `.ct_commit_review()` currently writes `source_hash = NA`; this plan adds
both fields to the payload.

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
3. `db_update` the alias: `uuid_feature`, `kind = "transcription_error"`,
   `confirmed_by`, `auto_assign = TRUE`;
4. **merge** each collision: re-point the newly-resolved sample's analyses onto
   the pre-existing sample and delete the emptied sample. Per analysis, if
   (feature, date, analyte, method) is already occupied — A45's key — compare by
   **A14**: equal → drop the duplicate analysis and log a `provenance`
   `change_log` row (`already_present` semantics); different → **leave the
   existing row untouched** and open a `value_conflict` review item.

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

**This section is separable.** Its only coupling to R-11.1–R-11.12 is the target
schema. It can be built and reviewed as its own plan if that is preferable — the
package's own tests never run it (they build the new shape directly via
`helper-db.R`).

## Fixtures

Extend `seed_db()` (`helper-db.R`) to the new shape. Seeded features keep their
existing uuids; each gains a self-alias. Add:
- a resolved alias (`bs03alt` → `f-0003`) for the two-labels-one-sample test;
- an **ambiguous** key: two aliases with one `alias_key` → two live same-site
  features (for R-11.4 and the R-11.10 ambiguity nuance);
- a same-key pair where one feature is **defunct** at the fixture date
  (`date_end` set) → the narrowing auto-resolve case;
- an `auto_assign = FALSE` alias (never a candidate; a suggestion source);
- a dangling `lab_method` + analysis with `units_raw` (for R-11.11 conversion).

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
  owner for it).
- **A53** — `.rc_find_existing` drops its redundant `lm.uuid_analyte` clause
  (method ⇒ analyte); A45's key is unchanged.

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
- **Site-completion (`S01` → `B.S01`)**: sound (all names are `<site>.<code>`)
  but applies to incoming `feature_raw`, needs the event's site, and does not
  disambiguate. Own plan.
- **Retiring `feature.cypher`** and the `project.cypher` twin: after the
  migration is reviewed.
- **`lab_method.reported_as`** is dead (NULL in all 365 rows). Candidate for
  removal whenever `lab_method` is next rebuilt.
