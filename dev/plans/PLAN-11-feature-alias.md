# PLAN 11 — `feature_alias`: commit-everything, resolve feature names later

**Owns:** `R/feature-alias.R` (new), `tests/testthat/test-feature-alias.R`
(new), `dev/migrations/001-cypher-to-feature-alias.R` (new). **Amends:**
`R/db-schema.R` (`ensure_schema`, `sample` DDL), `R/reconcile.R`
(`.rc_key`, `.rc_load_registry`, `.rc_feature_candidates`,
`.rc_resolve_features`), `R/commit.R` (feature-unknown rows now commit),
`R/mutate.R` (write API). **Depends on:** plans 01–10 landed and green.

## Why

Sampling-point codes are almost always transcribed incorrectly somewhere
between the bottle, the COC and the lab's report. That is *the* reason this
pipeline needs a human in the loop. Today an unresolved feature name **strands
the data** — the rows are held out of the DB (or, worse, the file is archived
terminally with the good rows committed and the bad one lost; see PLAN-10
handover). Resolving then requires *replaying the file through the pipeline*,
which the pipeline cannot do: `route_files()` never re-decides a routed hash.

This plan inverts that (user direction, 2026-07-16): **commit the data always,
resolve the feature name afterwards as a pure database operation.** A
measurement is real and its numbers are good even when we are unsure which
feature it belongs to; "which feature exactly" is a separately-resolvable
pointer, not a commit gate. This decouples resolution from ingestion — review
stops being "re-run the pipeline" and becomes an `UPDATE` — which sidesteps
the replay gap entirely and keeps idempotency clean.

The old memory of mis-transcriptions, `feature.cypher` (a comma-separated
`VARCHAR`), is replaced by a real table and wired into both the matcher and
this resolution layer.

## Model (the one decision to review first)

**Recommended — denormalised indirection (D).** `sample.uuid_feature` stays
the resolved pointer (made **nullable**); a new `sample.uuid_feature_alias`
records the raw label **only when it was not a direct name match**. An
unresolved sample commits with `uuid_feature = NULL` and `uuid_feature_alias`
set. Every consumer view `INNER JOIN`s `feature` (verified: `v_measurement`
and the `v_measurement_*`/`v_feature_*` family), so a `NULL`-feature sample
**auto-excludes itself from every measurement view and EPA report until
resolved** — which is exactly correct, and needs no view rewrite. Resolution
sets `feature_alias.uuid_feature` and propagates with one
`UPDATE sample SET uuid_feature = ? WHERE uuid_feature_alias = ?`.

**The full-indirection variant (P)** — every sample routed through the alias
layer, all 15,113 samples migrated, ~12 views made dangling-aware — was the
user's initial pick. Recommend against: it delivers the *same* two wins
(keep-both-names, resolve-all-at-once) as (D), because the provenance lives in
`uuid_feature_alias` either way and the `INNER JOIN` already excludes dangling
rows. What (P) adds is ~15k **self-alias** rows (`B.S03` is an alias for
`B.S03`) that identify nothing, plus a rewrite of every view and every
`sample.uuid_feature = feature.uuid` join in the codebase. (D) is not the "lite"
model; it is the properly-normalised one — you no more store a self-referential
alias than you store "B.S03 is an alias for B.S03". **This plan is written for
(D); overrule in review if you want (P).**

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

Scope: **only the feature-unknown case changes.** Other review kinds
(`value_conflict`, `sample_datetime_mismatch`) keep their current
held/needs-review behaviour — those are genuine contradictions, not "we don't
know where this goes".

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

## Open / deferred

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
