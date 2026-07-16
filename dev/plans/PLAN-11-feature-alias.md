# PLAN 11 — commit-everything, resolve unknown feature & analyte names later

**Owns:** `R/feature-alias.R` (new), `tests/testthat/test-feature-alias.R`
(new), `tests/testthat/test-resolve.R` (new),
`dev/migrations/001-cypher-to-feature-alias.R` (new). **Amends:**
`R/db-schema.R` (`ensure_schema`, `sample` + `lab_method` DDL),
`R/reconcile.R` (`.rc_key`, `.rc_load_registry`, `.rc_feature_candidates`,
`.rc_resolve_features`, `.rc_lab_method_candidates`, `.rc_resolve_analytes`),
`R/commit.R` (feature-unknown *and* analyte-unknown rows now commit),
`R/mutate.R` (write/resolve API). **Depends on:** plans 01–10 landed and green.

## Why

Sampling-point codes **and** analyte names are almost always transcribed or
labelled inconsistently somewhere between the bottle, the COC and the lab's
report. Unknown feature and unknown analyte are the two *common* review causes
(the other three — `value_conflict`, `sample_datetime_mismatch`,
`unknown_unit` — are, or should be, rare). Today an unresolved name **strands
the data** — the rows are held out of the DB (or, worse, the file is archived
terminally with the good rows committed and the bad one lost; see PLAN-10
handover). Resolving then requires *replaying the file through the pipeline*,
which the pipeline cannot do: `route_files()` never re-decides a routed hash.

This plan inverts that (user direction, 2026-07-16): **commit the data always,
resolve the name afterwards as a pure database operation.** A measurement is
real and its numbers are good even when we are unsure which feature or analyte
it belongs to; those identities are separately-resolvable pointers, not a
commit gate. This decouples resolution from ingestion — review stops being
"re-run the pipeline" and becomes an `UPDATE` — which sidesteps the replay gap
entirely and keeps idempotency clean.

**Feature and analyte are the same archetype but need different amounts of new
machinery**, because feature has no indirection layer today (a sample points
straight at a feature) while analyte already has one:
- **Feature:** `sample.uuid_feature → feature`. Needs a NEW alias table
  (`feature_alias`) to remember the wild 1:many mis-transcriptions a single
  sampling point accretes (max 149 junk names for one feature). The old
  `feature.cypher` VARCHAR is migrated into it.
- **Analyte:** `analysis.uuid_lab → lab_method → analyte`. **`lab_method` is
  already the 1:many alias layer** (360 lab_methods → 245 analytes); "the same
  substance under several lab names/methods" is what it already models. So an
  unknown analyte needs **no new table** — just the ability for a `lab_method`
  to exist before it is linked to an analyte. Analyte naming does not have the
  wild variation feature codes do, so there is **no `n_seen`/frequency
  machinery** on this side.

## Model (the one decision to review first)

Both sides share one shape: **the dangling pointer sits on the row that owns
the identity, nullable; a consumer view's `INNER JOIN` hides dangling rows
until resolved; resolution is one propagating `UPDATE`.**

**Feature — denormalised indirection (D, recommended).**
`sample.uuid_feature` stays the resolved pointer (made **nullable**); a new
`sample.uuid_feature_alias` records the raw label **only when it was not a
direct name match**. An unresolved sample commits with `uuid_feature = NULL`
and `uuid_feature_alias` set. Every consumer view `INNER JOIN`s `feature`
(verified: `v_measurement` and the `v_measurement_*`/`v_feature_*` family), so
a `NULL`-feature sample **auto-excludes itself from every measurement view and
EPA report until resolved** — needs no view rewrite. Resolution sets
`feature_alias.uuid_feature` and propagates with one
`UPDATE sample SET uuid_feature = ? WHERE uuid_feature_alias = ?`.

**Analyte — the same shape, on `lab_method` (no new table).**
`lab_method.uuid_analyte` is currently NOT NULL (verified: 0 dangling rows
today, like features). Make it **nullable**. An unknown analyte commits its
analysis pointing at a `lab_method` (created/reused from the file's
`name, org, method, rl_low, rl_high`) whose `uuid_analyte = NULL`. Because
`v_measurement` **`INNER JOIN`s analyte through lab_method** (verified), that
analysis auto-excludes until resolved. Resolution sets
`lab_method.uuid_analyte`; every analysis using that method lands at once. The
`lab_method` row IS the provenance ("what the lab called it") — no separate
alias column needed on `analysis`.

**The full-indirection variant (P) for features** — every sample routed
through the alias layer, all 15,113 samples migrated, ~12 views made
dangling-aware — was the user's initial pick. Recommend against: it delivers
the *same* two wins (keep-both-names, resolve-all-at-once) as (D), because the
provenance lives in `uuid_feature_alias` either way and the `INNER JOIN`
already excludes dangling rows. What (P) adds is ~15k **self-alias** rows
(`B.S03` is an alias for `B.S03`) that identify nothing, plus a rewrite of
every view and every `sample.uuid_feature = feature.uuid` join. (D) is the
properly-normalised model, not the "lite" one. **This plan is written for (D);
overrule in review if you want (P).**

## Evidence (measured against the live `monitoring.duckdb`, 2026-07-16)

`feature.cypher`: 117/894 features, 2062 raw entries → 370 unique
`(feature, alias)` pairs (case/punct-folded), of which 72 are the feature's
own name and **298 are genuine wrong labels** (222 seen once, 38 seen 2–4×, 38
seen 5+, max 38). **Repeats are frequency, not bloat**: a label was appended
every time it was seen, so the count is a use count (→ `n_seen`).

Wrong labels: 62% are words/phrases (`B.L01` ← `BDISCHARGE`), 24% are code-shape
explained by a derivable prefix map (`B`=Bore → `MW`=monitoring well; also
`BORE→MW`, `BS→S`), 14% code-shape not so explained.

Schema facts that shape the design:
- `feature` is **NOT NULL on `name, site, lon, lat`** — a provisional feature
  row is impossible without fabricated coordinates, and all 894 features are
  `virtual = FALSE` (no "not-a-real-place" precedent). This is why we do **not**
  mint placeholder features; unresolved data hangs off a dangling alias instead.
- All consumer views `INNER JOIN feature` — the property that makes (D) cheap.
  `v_measurement` also `INNER JOIN`s analyte *through* `lab_method`, so the
  same dangling-hides-itself trick works for unknown analytes.
- `lab_method.uuid_analyte` is **NOT NULL** with 0 dangling rows today; it is
  already the analyte alias layer (360 methods → 245 analytes).
- `sample` = 15,113 rows, `analysis` = 95,737; 14 views, 12 touching
  feature/sample.
- 31 aliases map to >1 feature. Date (`date_end`) + site disambiguation
  resolves only **4** of them (1 by date, 3 by site); the other 27 are
  non-identifying descriptors (`B.BORE` → 8 features) that *should* stay in
  review. So date/site is a **correctness guard for reused specific codes**,
  not a bulk auto-resolver.

## Domain rules (user, 2026-07-16)

- **`old` must NOT be imported** from `feature_mask`: 363 of its 373 names ARE
  another live feature's real name (`B.G189`'s old name is `B.G005`, a live
  feature), and `old` means a *different physical feature* (a destroyed,
  re-dug bore). Import **`long` only** (smallest blast radius; `gas_report` is
  safe and can be added later on evidence; `EPA` is bare numbers).
- **An alias name is NOT unique.** The same string can legitimately map to
  different features at different times. The alias's identity is its **own
  `uuid`**; `name`/`alias_key` carry no uniqueness constraint.
- **Auto-assign** an alias only when it resolves to exactly one feature *after*
  narrowing:
  1. collect candidate features (direct `feature.name` + `auto_assign` aliases);
  2. drop features defunct at the sample's date (`date_end < sample_date`);
  3. if the file's site is known, drop features not at that site;
  4. exactly one survivor → assign; else → review.
- **Frequency ranks, never decides.** Worst real tie: `KBORE` → `K.MW08` 15× vs
  `K.MW10A` 14×.
- **No fuzzy auto-assign** — real codes differ by one character (`B.S01` vs
  `B.S04`). Fuzzy/prefix-map/LLM outputs are **suggestions only**, never the
  commit path (an LLM there would break plan-10 idempotency).
- **Guesses never launder into ground truth**: an unconfirmed guess is reported
  every run until a human confirms it; only confirmation writes a
  `confirmed_by` alias.
- **Review UX is bulk confirmation** — "here are N we guessed, say yes-to-all or
  all-except-this"; no per-feature clicking.

## The API is the authority; the UI is a thin, deferred, swappable layer

The deliverable of this plan is the **resolve API** — a small set of R
functions that are the *only* thing that writes a resolution: validating,
idempotent, bulk-capable, and recording provenance (`confirmed_by`,
`change_log`). Get that right and the review UI becomes a cheap layer over it —
swappable, and several can coexist. So **no UI is specified or built here**;
the choice is explicitly deferred and does not gate the API.

The discipline that keeps any UI honest: **the UI presents and executes; the
human decides; the API records the human as `confirmed_by`.** A UI (including
an LLM-driven one) may *propose* and may *call* the resolve functions, but it
never confirms on its own — so no guess launders into ground truth regardless
of which front-end is used.

Front-ends of interest, in likely order (all post-API, none blocking):
1. **Claude Code as review assistant** — zero-build (the resolve functions are
   R); best fit for the judgment/shortlist task; the fastest way to *prove* the
   flow on real items. (Review is human judgment, unlike ingestion, which stays
   deterministic R — the reasons Claude was removed from ingestion do not apply
   to review.)
2. **A dedicated Claude skill** wrapping (1) into a repeatable "run the review"
   workflow.
3. **A Quarto review report** generated after each ingest: renders the queue
   with context, each item embedding the exact resolve call — read-optimised,
   resolve interactively.
4. **A small Shiny app** if review becomes routine enough to want a standing,
   click-driven, unattended-capable front-end.

## R-11.1 Schema: `feature_alias`

`ensure_schema()` creates, idempotently:

```
feature_alias(
  uuid         VARCHAR PRIMARY KEY,   -- the alias's OWN identity (name is not unique)
  uuid_feature VARCHAR,               -- NULLABLE: resolution; NULL = dangling
  name         VARCHAR NOT NULL,      -- raw, as seen ('B..So3')
  alias_key    VARCHAR NOT NULL,      -- .rc_key(name); NOT unique
  kind         VARCHAR,               -- historical_code | descriptive |
                                      --   transcription_error | mask_long | pending
  n_seen       INTEGER DEFAULT 0,     -- samples referencing this alias
  auto_assign  BOOLEAN DEFAULT TRUE,  -- FALSE = suggest only, never resolve
  first_seen   TIMESTAMP,
  last_seen    TIMESTAMP,
  source_hash  VARCHAR,               -- provenance
  confirmed_by VARCHAR,               -- NULL = unconfirmed guess
  comments     VARCHAR
)
```
No DB uniqueness on `name`/`alias_key` (the domain forbids it). Duplicate-row
prevention is by **upsert in code**: writing an alias that already exists as a
`(uuid_feature, alias_key)` pair increments `n_seen`/`last_seen` instead of
inserting; a dangling `(NULL, alias_key)` row is reused rather than duplicated.

Criteria: creating twice is a no-op; an existing DB gains the table; `alias_key`
is always `.rc_key(name)` (one spelling of "normalise", shared with the
reconciler); the same `alias_key` may exist against two different features (a
pinned test); a re-seen alias increments `n_seen`, never inserts a duplicate.

## R-11.2 Schema: `sample` gains the indirection columns

`ensure_schema()` (additive migration, A2/A7): make `sample.uuid_feature`
**nullable** and add `sample.uuid_feature_alias VARCHAR` (nullable) →
`feature_alias.uuid`.

Criteria: the migration is additive and idempotent; existing rows keep their
`uuid_feature` and get `uuid_feature_alias = NULL` (historical samples came in
resolved; their original wrong label, if any, is not reconstructable and is not
backfilled); **an audit of the codebase for code that assumes
`sample.uuid_feature` is non-null is part of this task** (grep the mutation
layer, commit, and any join); `v_measurement` still returns exactly the
resolved rows (a pinned test: a `NULL`-feature sample does not appear).

## R-11.3 Normalisation (`.rc_key`, amended)

`.rc_key()` currently is `tolower(str_squish(normalise_lab_text(x)))`, which
keeps punctuation, so `B.S01` and `B S01` do not match. Extend it to strip all
non-alphanumerics.

Criteria: `B.S01`, `B S01`, `BS01`, `b.s01`, `B..S01` share one key; **all 894
real feature names still yield 894 distinct keys** (pinned regression against a
fixture of the real name list — this collision-free property is what makes the
fold safe to auto-assign on, so it must fail loudly if a future name breaks it);
NA/blank → NA (A44 guard); existing analyte/method matching that shares
`.rc_key` is re-verified.

## R-11.4 Matching + narrowing (`.rc_feature_candidates`)

Resolve `feature_raw` (with the sample's date and, if known, the file's site)
against `feature.name` then `auto_assign` `feature_alias` rows. **No longer
joins `feature_mask`** (its `long` names are imported by R-11.8; `EPA`/`old`
must never match).

Procedure: collect distinct candidate `uuid_feature`; if >1, narrow by
`date_end`/site (R-11 domain rules); assign iff exactly one survives.

Criteria: one survivor → assign (via name or alias); zero → `unknown`; >1 after
narrowing → `ambiguous`; the A44 NA guard holds; a re-drilled well's *old* name
(`B.G005`) resolves to the live `B.G005`; the reused-code case (`Bore 1` → two
live features, same site) stays `ambiguous`; the reused-code case where one
candidate is defunct at `sample_date` auto-resolves to the live one.

## R-11.5 Commit-everything for unknown features (the inversion)

Feature-unknown rows are **no longer held**. In the commit path, a row whose
feature did not resolve is committed with `uuid_feature = NULL` and
`uuid_feature_alias` pointing at a dangling `feature_alias` row (created/reused
for its `alias_key`, `kind = "pending"`, `auto_assign = FALSE`), its file
archived normally. A review item is still emitted — but as a **worklist entry
over committed-but-dangling data**, not a commit gate.

Scope: **the feature-unknown and analyte-unknown cases flip to
commit-everything** (analyte via R-11.9). The other three kinds —
`value_conflict`, `sample_datetime_mismatch`, `unknown_unit` — keep their
current held/needs-review behaviour: those are genuine contradictions or
missing conversions, not "we know the number, just not where it goes".

Criteria: a file with 19 clean rows + 1 unknown-feature row commits **all 20**
(19 to features, 1 dangling) and archives — nothing is stranded; the dangling
row is absent from `v_measurement` until resolved; the `ingest_file` state is
terminal (`archived`) legitimately, because the data *did* land; re-ingesting
the same bytes → `already_present` (idempotency preserved, a pinned two-run
test); the review item names the alias and the feature suggestions (R-11.6).

## R-11.6 Review items: guesses and shortlists

Review items name **features**, never bare UUIDs (today the ambiguous payload
carries `candidates=<uuid>|<uuid>`; the 0-hit payload carries nothing).
Required shape:

> Unknown feature 'B..So3' previously found for B.S04 and B.S03

Two tiers, for bulk confirmation:
- **best guess** (single confident candidate from a derived source — prefix
  map / an `auto_assign=FALSE` alias with one owner / LLM against `long`
  names): carries its basis ("prefix map B→MW", "seen 15×") so a bulk
  "yes-to-all" is informed;
- **no confident guess**: optional shortlist ranked by `n_seen` (a ranking,
  never a decision).

Criteria: a genuinely novel string yields an item with **no** suggestions and
says so (never a fabricated guess); grouping unchanged (one item per normalised
`feature_raw`, A44 NA sentinel still groups); the review item carries the
alias's `uuid` (so confirmation can target it) — note the current reconcile
review tibble has **no `source_hash` column**, so `.ct_commit_review` writes
`source_hash = NA`; this plan adds the alias uuid + source_hash to the payload.

## R-11.7 Confirmation (closing the loop as a DB op)

A public bulk API — `confirm_feature_aliases(items, corrections, confirmed_by)`
— accepts a review batch, applies per-item corrections, and for each: sets
`feature_alias.uuid_feature` (kind → `transcription_error`, `confirmed_by`
set) and runs the propagating
`UPDATE sample SET uuid_feature = ? WHERE uuid_feature_alias = ?`, all via the
plan-09 mutation layer (never raw `dbExecute`; A32/A40) with `change_log`
provenance.

Criteria: confirming resurfaces the previously-dangling samples in
`v_measurement` (a pinned before/after test); confirming the same alias→feature
twice is idempotent; confirming a **split** (a genuinely-reused alias whose
samples belong to different features) assigns each subset correctly (creates the
second feature-linked alias row and re-points that subset); confirming to a
*different* feature than an existing `confirmed_by` row is an error, not a
silent second row (a human contradiction must surface); an unconfirmed guess is
never written as confirmed and keeps being reported until confirmed; **after
confirmation, the same incoming label auto-assigns and opens no review item.**

## R-11.8 Migration (one-off, `dev/migrations/`, backup copy first)

Into `feature_alias`:
- **`cypher`**: split on `,`, trim, drop empties, **count** duplicates into
  `n_seen`. ~370 rows: `kind = "historical_code"` (code-shaped),
  `"descriptive"` (phrases), self-name entries kept as-is (harmless;
  `feature.name` already matches). The **31 ambiguous aliases**
  (`auto_assign = FALSE`) are imported and reported — they must never
  auto-resolve; the `B.BORE`/`B.BOREHOLE` descriptors are the bulk of them.
- **`long` mask names**: one row each, `kind = "mask_long"`; overlaps with
  `cypher` collapse via the code-upsert (increment `n_seen`), never error.
- **Not imported:** `old`, `gas_report`, `EPA`.

Criteria: idempotent (re-run inserts nothing, double-counts nothing);
`feature.cypher` left untouched (retiring it is a later step, once the alias
table has proven itself); a dry-run mode prints the counts it would insert;
runs against a **copy** with the operator reviewing counts before it ever
touches the real DB.

## R-11.9 Analyte track: the same inversion, on `lab_method`

The unknown-analyte case is the feature case with **no new table** — the
`lab_method` layer already exists (see Model). Three changes:

**Schema.** `ensure_schema()` makes `lab_method.uuid_analyte` **nullable**
(additive migration; A2/A7). No new table, no `analysis` column change.

**Matching.** `.rc_lab_method_candidates()` already resolves
`(analyte_raw, org, method_raw)` against `lab_method`; it is unchanged. What
changes is what happens on a miss.

**Commit-everything.** In the commit path, an analysis whose analyte did not
resolve is committed pointing at a `lab_method` row **created or reused** from
the file's `(name, org, method, rl_low, rl_high)` with `uuid_analyte = NULL`
(reuse deduped by `(org, .rc_key(name), method)` so two files with the same
unknown method share one dangling `lab_method`, not two). A review item
(`kind = "unknown_analyte"`) is emitted as a worklist entry, not a commit gate.

**Confirmation.** A public `confirm_analyte_methods(items, corrections,
confirmed_by)` sets `lab_method.uuid_analyte` via the plan-09 mutation layer
(`change_log` provenance). No propagation UPDATE is needed — analyses already
point at the `lab_method`, so linking the method lands every analysis using it
at once.

Criteria: a file with an unknown analyte commits its analysis (dangling
`lab_method`, `uuid_analyte = NULL`) and archives — nothing stranded; the
analysis is absent from `v_measurement` until resolved; two files with the same
unknown method reuse one `lab_method` row; re-ingesting the same bytes →
`already_present` (idempotency); `confirm_analyte_methods()` resurfaces the
analyses in `v_measurement` and is idempotent; after confirmation, the same
incoming analyte auto-resolves and opens no review item; the review item names
the lab method and any suggested analyte (analyte-name fuzzy match is
suggestion-only, never auto-link). An audit for code assuming
`lab_method.uuid_analyte` is non-null is part of this task.

## Open / deferred

- **`sample_datetime_mismatch` may over-flag the legitimate multi-day case.**
  Results tie to samples by `lab_sample_id` first (exact — multi-day sampling
  is fine), falling back to feature-key only when a result has no
  `lab_sample_id`. In that fallback, a feature sampled on several days matches
  several sample rows with different dates and would false-flag. Verify whether
  any adapter (crosstab?) emits result rows without a `lab_sample_id`; not in
  this plan's scope (datetime stays a "must hold" kind), logged here.

- **Replay of pre-plan-11 stranded rows.** This plan stops *new* stranding, but
  any rows already held by the old behaviour need a one-off re-ingest (the
  `reset = TRUE` escape hatch on `ingest_file_set_state`). Small, separate.
- **The derived prefix map** (`B→MW`, `BORE→MW`, `BS→S`): explains 71 of 298
  wrong labels; suggestion-only, and must be collision-tested (a mapped code can
  land on a real different feature — the `B.G005` trap).
- **LLM suggestions from `long` names/descriptions** (`ellmer` is in Suggests):
  suggestion side only, never commit path.
- **Site-completion (`S01` → `B.S01`)**: sound (all names are `<site>.<code>`)
  but applies to incoming `feature_raw`, needs the event's site, and does not
  disambiguate. Own plan.
- **Retiring `feature.cypher`** and the `project.cypher` twin: after the
  migration is reviewed.
- **Backlog surface**: a `v_sample_pending` (or a count in the ingest report)
  so a dangling sample is visible work, not a silent gap — decide during
  R-11.5.
