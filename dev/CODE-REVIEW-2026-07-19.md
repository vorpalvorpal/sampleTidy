# sampleTidy — whole-package code review (2026-07-19)

> **STATUS — TRIAGED & ROUTED (2026-07-19). Nothing here is outstanding as a
> loose finding; every item has been moved into a plan.** This document is now the
> *evidence of record*, not a worklist. See
> [`CODE-REVIEW-2026-07-19-TRIAGE.md`](CODE-REVIEW-2026-07-19-TRIAGE.md) for the
> per-finding verdict + fix + destination. Routing:
> - **F1–F5, F9, T-1 (e2e), A-1..A-5** → folded into **PLAN-11** (its
>   "Whole-package code-review fold-ins" section: R-11.14–R-11.18, R-11.9
>   extension, A56–A58/A62) — they edit functions PLAN-11 already rewrites, so
>   they land in that single Phase-6 rewrite.
> - **F6–F8, F10–F19, A-6/A-7, T-2, T-1 (sweep), PERF** → new
>   **[`PLAN-12-review-remediation.md`](plans/PLAN-12-review-remediation.md)**
>   (R-12.1–R-12.16, A59–A61).
> - **CONTRACT** `feature` schema line corrected; cross-plan edits recorded.
> - **Three design decisions resolved by the user (2026-07-19):** F9 → two
>   distinct samplings when datetimes differ; F7 → contain per-event ingest
>   failures loudly (abort only if all fail); F16 → env vars string-only with a
>   guard. All logged ✅ RESOLVED in `plans/PLAN-CHANGE-REQUESTS.md`.
> - Every finding was verified valid; **none were rejected.**

**Scope:** every file in `R/`, the test helpers and suites, and the plans/CONTRACT
as the spec baseline. Plans 10 and 11 are known to be partially implemented —
that incompleteness is *not* reported as defect; the review focuses on what is
wrong in the code that exists, on places where the plans themselves are wrong,
and on test-suite strength.

**Method:** adapted from the code-review skill at high effort — line-by-line
correctness scan, invariant tracing against CONTRACT A1–A55, cross-file seam
tracing (producer→consumer column contracts), reuse/simplification/efficiency
angles — run inline over the whole package rather than a diff. Suspect findings
were verified behaviourally with throwaway scripts (no changes to the repo), and
suite strength was probed with 8 targeted mutations on a temporary side branch
(`review/mutation-testing`, created in an isolated worktree and deleted after).

**Baseline at HEAD (`40f9fba`):** 928 pass / 1 fail / 43 errors / 4 skips.
Every red test (test-reconcile 22, test-commit 5, test-e2e-pipeline 8,
test-ingest 9) fails with the same binder error — `Table "s" does not have a
column named "uuid_feature"` — i.e. the expected consequence of plan-11
Phase 4 landing the new `helper-db.R` schema (sample → `uuid_feature_alias`)
before the production `reconcile.R`/`commit.R` amendments. **No unexpected red.**
Everything below was found on the green surface or verified independently of
that schema mismatch.

---

## Severity key

- **P1** — wrong data lands in (or is missing from) the database, silently.
- **P2** — real defect; wrong behaviour, broken API, or a broken invariant, but
  bounded or unlikely to corrupt data silently.
- **P3** — robustness / convention / minor-correctness issues.
- **T** — test-suite strength findings.
- **A** — architectural / plan-level issues (the plan is wrong, not the code).
- **PERF** — easy performance wins noticed in passing.

---

## P1 — Silent data corruption / loss

### F1. Assembly's inline review flags are never consumed — A22 is unimplemented on the consumer side

`assemble.R` marks review-worthy rows inline per CONTRACT A22
([assemble.R:163–172](../R/assemble.R) sets `needs_review`/`review_kind`/
`review_payload` for `sample_datetime_mismatch`; [assemble.R:330–338](../R/assemble.R)
for `foreign_work_order`). A22 pins: *"Reconcile folds them into its own review
output."* **Nothing does.** `grep -rn needs_review R/` shows the columns are set
in `assemble.R` and read nowhere; `reconcile_event()` treats a flagged row as an
ordinary row, so if its feature/analyte/units resolve it lands in `clean` and is
**committed with no review item** — the flag is silently discarded at the
plan-07→plan-08 seam.

Consequences (both verified — see F2 for the demonstration):

- a non-NCP **foreign work-order** row (R-7.4: "lands in review") commits
  silently into the home event;
- a **sample-datetime mismatch** row (a "must hold" kind per plan-11 D6)
  commits silently with an arbitrarily chosen date.

Root cause is in the *plan*, not the worker: PLAN-08's R-8.1–R-8.8 never mention
the inline flag columns, so the plan-08 test-writer wrote no folding tests and
the implementer wrote no folding code — both were green "per plan" while A22's
seam requirement fell in the gap between plan 07 and plan 08 (see A-1).

**Fix:** add a stage-0 to `reconcile_event()` (before the QC filter): partition
rows with `needs_review == TRUE` out of `active` into `review`, mapping
`review_kind`/`review_payload` into the review tibble (grouped like R-8.2 does),
and count them. Add the missing seam test: an event with one flagged row →
`reconcile_event()` review output contains it and `clean` does not. Plan 11's
amendments to `reconcile_event()` are the natural vehicle since that funnel is
being reworked anyway — but note D6's "held" logic *depends* on this existing
(see A-2).

### F2. ACIRL multi-visit workbooks: visit-2 measurements are committed with visit-1's date

The ACIRL adapter parses each water-sheet column's own date correctly, but
`ir_results` has no column that can carry it (no `sample_datetime_raw`, no
per-column linkage), and ACIRL results have `lab_sample_id = NA`. Assembly's
fallback join ([assemble.R:148](../R/assemble.R)) then matches results to
samples by **feature name only** — the docstring itself admits *"the 'date
part' side of the fallback key is left unresolved"*. A feature sampled at two
visits therefore matches both sample rows, and the fill takes the **first**
non-NA datetime ([assemble.R:174–179](../R/assemble.R)).

**Verified against the shipped fixture** (`2400-9999-01_Test_WMF.xlsx`, which
has T.S01/T.S02 sampled 24 *and* 25 May): after `assemble_events()`, **all 23
result rows carry `sample_datetime_raw = "24/05/2025"`** — the 25-May
measurements are re-dated to 24 May — and all 23 rows are flagged
`needs_review/value_conflict`, which F1 then silently discards. Downstream (in
the pre-plan-11 green MVP) this commits two pH analyses onto the *same* sample
(same feature/date/method — nothing dedups within-batch same-method rows), one
of them mis-dated, and the 25-May sampling event never exists in the DB.

The green e2e never noticed because its ACIRL test asserts only "date non-NA,
datetime NA, some person non-NA" ([test-e2e-pipeline.R:171–183](../tests/testthat/test-e2e-pipeline.R))
— never *which* dates — and the review-queue gate cannot fail (T-1).

**Fix (recommended):** make the ACIRL adapter emit a synthetic per-column
`lab_sample_id` (e.g. `"<sheet>!c<col>"`) on **both** its results and samples
rows. That flows through the existing exact-match join, needs no IR schema
change, gives every result its own visit's date, and eliminates the spurious
mismatch flags. (`lab_sample_id` is IR-internal for ACIRL — it is not part of
any DB key — so nothing else changes.) Alternatively extend the fallback join
key with the date part, but the adapter has strictly more information than the
join can ever recover. Then add an e2e assertion that pins both visit dates.

### F3. `already_present` provenance rows are written with `source_hash = NA` — A1's row-exact provenance is broken at the seam

A1 pins that provenance for an `already_present` row is a `change_log` row
linking the existing analysis **to this source_hash**. The real
`reconcile_event()` skipped shape is `(source_ref, reason, payload)`
([reconcile.R:35–37](../R/reconcile.R)) — **no `source_hash` column** — so
`.ct_record_already_present()`'s fallback ([commit.R:274](../R/commit.R))
writes every real provenance row with `source_hash = NA`. The uuid linkage
works (payload carries it); the *hash* linkage — the point of A1 — is lost.

The unit test is green because it hand-builds a `skipped` tibble with
`source_hash` and `existing_uuid` columns the producer never emits
([test-commit.R:269–271](../tests/testthat/test-commit.R)) — the same
"unit-green, seam-broken" class as A44. The e2e provenance test covers
*committed* analyses only.

**Fix:** add `source_hash` to `.rc_proto_skip()` and populate it in
`.rc_three_way()`'s `already_present` branch (the row's `source_hash` is right
there). Note **plan 11 does not fix this**: R-11.9/C18 adds `source_hash` to
`.rc_proto_review()` only — the skipped side is not mentioned. Fold it into the
same change (see A-3).

---

## P2 — Real defects, bounded blast radius

### F4. `quantified` is derived from `below_detection` alone — `>`-prefixed and `BDL` results commit as `quantified = TRUE`

`parse_value()` correctly returns `quantified = FALSE` for `">2000"` and
`"BDL"`. But the IR has no `quantified` column, and both places that re-derive
it use only `below_detection`:
[reconcile.R:285](../R/reconcile.R) (`!isTRUE(below_detection)`) and
[commit.R:187](../R/commit.R) (same). **Verified:** `">2000"` and `"BDL"` rows
leave `.rc_resolve_units_values()` with `quantified = TRUE`, contradicting
`parse_value()` and DESIGN's semantics. (`parse_value()` is even called inside
that function — its `quantified` column is simply not used.) Related: the
parsed `rl_high` for `>` rows is dropped; commit writes `rl_converted` into
`rl_low` unconditionally and never populates `analysis.rl_high`.

**Fix:** use `parsed$quantified` in `.rc_resolve_units_values()` and carry it
(reconcile already puts `quantified` on `kept`; make `.ct_commit_analyses()`
use `clean$quantified` instead of re-deriving). Either add an `above_detection`
marker to the IR or derive `rl_high` from `value_raw`'s `>` prefix at
reconcile, and write it at commit. Add `">"`-row and literal-`"BDL"`-row
assertions at the DB level (only `<`-rows are pinned today).

### F5. `add_feature()` cannot work against the live database

`add_feature()` ([mutate.R:324–338](../R/mutate.R)) builds a row with a
`virtual` column and no `site`/`lon`/`lat` values. Verified against the real
`monitoring.duckdb` (dashboard copy, read-only): the live `feature` table **has
no `virtual` column**, and `name`, `site`, `lon`, `lat` are **NOT NULL**. So
the call fails column validation live (`virtual` not found), and even without
it the insert violates NOT NULL. It only works against `helper-db.R`'s test
DDL, which still declares `virtual` and omits `lon`/`lat` — the acknowledged
test-only drift is exactly what masks this. `add_feature()` is an exported,
human-callable API (A16), so this is a broken public function, not a latent
edge.

**Fix:** align the signature with the live schema (require `name`, `site`,
`lon`, `lat`; drop `virtual`), and fix the test DDL to match the live shape
(plan 11 chose to leave `virtual` "out of scope" — recommend reversing that;
a test schema that diverges from the live schema is how this bug survived;
see A-4).

### F6. A misbehaving adapter `match()` return claims the file and then aborts the whole run

`route_files()` never validates what `match()` returns. **Verified:** an
adapter whose `match()` returns `NA` produces `state = "claimed"` with
`adapter = NA, tier = "exact"` — the NA propagates through
`names(claims)[claims == t]` ([router.R:126–133](../R/router.R)) into a
length-1 `winners` containing `NA`. `.ig_parse_claimed()` then does
`adapter_registry()[[NA]]` **outside** its tryCatch
([ingest.R:65](../R/ingest.R)) → subscript error → the entire `ingest_dir()`
run aborts. The router's contract is that adapter faults are contained per-file
(A27); `register_adapter()` is exported, so third-party adapters are expected.

**Fix:** in `.st_route_one_file()`, validate each `match()` return against
`c("exact","format","fallback","no")` (length-1, non-NA) and treat anything
else as that file `failed` (like a thrown `match()`); belt-and-braces, move the
registry lookup in `.ig_parse_claimed()` inside the tryCatch.

### F7. One poison event aborts the whole ingest run

`ingest_dir()` contains adapter *parse* crashes per-file, but
`reconcile_event()`/`commit_event()` run bare inside the loop
([ingest.R:121–152](../R/ingest.R)). Any per-event failure — an archive copy
failing, a registry FK oddity making `analyte_row$units[[1]]` subscript out of
bounds ([reconcile.R:287–288](../R/reconcile.R) does not guard a zero-row
lookup), a payload glitch — kills the run for every remaining event. Events
already committed stay committed (each has its own transaction), so a re-run
continues, but a single always-failing event permanently blocks everything routed
after it in the same run.

**Fix:** wrap the per-event reconcile+commit in tryCatch, mark that event's
files `failed` with the message, count it in the report, continue. (This is a
design decision the plans never made explicitly — R-9.5 specifies containment
only for parse. Worth a plan-change request rather than a silent fix.)

### F8. Crosstab parser: two silent-drop paths violate the "no silent drops" convention

CONTRACT: *"Every function that skips/drops a row must return counts of what it
skipped and why."*

- **Unsupported-section skip:** once a foreign `…Matrix:` marker is seen,
  every row until the next dialect marker is `next`-ed with no `skipped` entry
  and no warning ([adapter-crosstab.R:383–393](../R/adapter-crosstab.R)). The
  HANDOVER already asks "re-check it can't over-skip"; today, if a mid-file
  foreign block were followed by real data rows *without* a fresh dialect
  marker, that data would vanish without a trace.
- **Missing `ALS Sample Number` row:** `sample_cols` stays empty, so every
  analyte row in the section is classified as a method-group row
  (`has_sample_values` is FALSE with zero sample columns —
  [adapter-crosstab.R:501–509](../R/adapter-crosstab.R)) and the whole section
  emits **zero results, zero skips, zero warnings**. A spelling drift in that
  one label would silently blank entire files.

**Fix:** record one `report$warnings` entry (with the row range) when entering
an unsupported section, and warn when a section reaches its analyte header with
`length(sample_cols) == 0`.

### F9. Same feature+date with a different clock time silently reuses the first sample

`.ct_find_or_create_sample()` ([commit.R:95–104](../R/commit.R)): when
date-level candidates exist, the datetime narrowing only runs `if
(nrow(cand) > 1)`, and when narrowing finds no datetime-equal candidate the
code returns `cand$uuid[[1]]` regardless. Two consequences: (a) an incoming
09:00 measurement and a 15:00 measurement at the same feature+date attach to
**one** sample row (the second sampling's identity is lost — real for
multi-visit-per-day monitoring); (b) with several candidates and no datetime
match, the pick is arbitrary. A11 says matching is "date first, then datetime
when both sides have it" — it never says a *non-matching* datetime should
reuse rather than create.

**Fix:** decide the intended semantics explicitly (plan-change request). If
distinct datetimes are distinct samplings: create a new sample when all
candidates have non-NA datetimes that differ from a non-NA incoming datetime.

---

## P3 — Robustness / conventions / minor correctness

- **F10. `archive_file()` ignores `file.copy()`'s return**
  ([archive.R:52](../R/archive.R)). A failed copy (permissions, missing
  archive_dir, disk full) still inserts the `asset` row and the commit
  "succeeds" — the archive is then silently missing. The remove-switch's
  verify-before-delete catches it later, but the run should fail loudly at the
  copy. Same pattern in `snapshot_db()` ([snapshot.R:28,33](../R/snapshot.R)):
  unchecked `file.copy`/`file.rename` mean a missing `snapshot_dir` yields a
  "successful" run whose returned snapshot path doesn't exist — and R-9.6 then
  treats the snapshot as having happened. Check both returns; abort on FALSE.
- **F11. `ir_results()`/`ir_samples()` silently drop extra columns**: the
  constructor subsets to the pinned columns before validating
  ([ir.R:74–75](../R/ir.R)), so `ir_validate()`'s extra-column check is dead on
  the constructor path — a misspelled optional argument vanishes silently. A
  missing required column errors with a vctrs subscript error, not
  `sampletidy_ir_error`. Validate *before* subsetting (or don't subset).
- **F12. `db_update()` logs unchanged fields** as updates (no old≠new check),
  and **`db_delete()` on a nonexistent uuid writes a phantom delete log row**
  (0-row DELETE, log row written anyway) — [mutate.R:243–259, 288–301](../R/mutate.R).
  Also `DBI::dbCommit()` sits outside the tryCatch in `db_transaction()`
  ([mutate.R:118](../R/mutate.R)) — a commit-time error escapes unwrapped with
  no rollback attempt.
- **F13. `ingest_report$files_by_state` reports route-time states**
  ([ingest.R:222](../R/ingest.R) uses `routed$state`), so files this run
  committed/archived show as `"claimed"`. R-9.5 says "files by terminal
  state". Re-query `ingest_file` for the routed hashes when building the
  report.
- **F14. Crosstab `match()` fragility**: the CSV peek is `file_meta()`'s first
  2048 bytes ([adapter-crosstab.R:125–131](../R/adapter-crosstab.R)) — a very
  wide crosstab whose `Workgroup:` row starts past 2 KiB would silently
  unclaim; a UTF-8 BOM on row 1 defeats `^Matrix:` (ESdat strips BOMs, the
  crosstab path doesn't). Cheap hardening: read the first N *lines* of the
  file rather than relying on the fixed-size peek, and BOM-strip line 1.
- **F15. `ingest_file_upsert()` unconditionally overwrites `filename`/`size`**
  on re-sight ([db-schema.R:184–188](../R/db-schema.R)) — a later caller
  passing the defaults would null a real filename. All current callers pass
  both; guard anyway (COALESCE-style) or drop the defaults.
- **F16. `st_config()` env-var values are always strings**: fine for paths and
  for `remove_ingested` (ingest.R coerces), but `SAMPLETIDY_FIELD_ANALYTES`
  would yield a single string, silently shrinking the ACIRL allowlist to one
  entry. Either document env vars as string-only keys or split on a separator.
- **F17. Stale worker comment** at [db-schema.R:126–130](../R/db-schema.R):
  "See final report for this discrepancy" — the discrepancy was adjudicated as
  A31; the comment should cite A31 instead of a report that no longer exists.
- **F18. `cli_inform` noise on every run**: `ingest_dir()` calls
  `register_builtin_adapters()` (A33), which emits four "Overwriting existing
  adapter registration" messages per run ([adapter-registry.R:53](../R/adapter-registry.R)).
  Suppress the inform when the id being overwritten is a built-in re-registering
  itself.
- **F19. `sample.organisation` semantics**: R-9.2 step 2 says "organisation =
  sampler org if known else org"; `.ct_resolve_samples()` always writes the
  adapter org ([commit.R:161](../R/commit.R)). For ESdat samples the collector
  arguably isn't ALS. Low impact; note for the datetime-convention revisit.

---

## T — Test-suite strength

### T-1. The e2e review-queue gate cannot fail (fifth instance of the pattern)

PLAN-10 R-10.2 pins: *"review_queue contains exactly the engineered unknowns
(typo feature, unknown unit) and nothing else"* and *"QC skip counts in the
report equal the fixture's known QC row count"*. The shipped test asserts
([test-e2e-pipeline.R:194–197](../tests/testthat/test-e2e-pipeline.R)):

```r
expect_true(nrow(reviews) >= 0) # sanity: query succeeds even if empty
expect_type(report, "list")
```

`nrow(x) >= 0` is a tautology. This is the exact gate that would have caught
F1 and F2 (23 spurious ACIRL flags dropped; zero datetime-mismatch items ever
created). Given A46/A47's "a gate that cannot fail is worse than no gate"
lesson is already recorded three times over, this one deserves a regression
sweep: **grep the suites for `>= 0`, `expect_type(<report>, "list")`, and
assertions that can't distinguish success from no-op.** Feeds
`dev/tdd-skill-improvements.md`.

### T-2. Mutation results (8 targeted mutations, green areas only)

| # | Mutation | Result |
|---|---|---|
| M1 | assemble: remove the A44.2 `is.na()` guard (feature_raw fill clobbers non-NA) | **SURVIVED** — test-assemble 256/256 green |
| M2 | assemble: never set the datetime-mismatch flag | killed (1 failure — a single thin assertion) |
| M3 | router: adapter tie picks first winner instead of quarantining | killed |
| M4 | values: `<`-rows write `rl_high` instead of `rl_low` | killed |
| M5 | crosstab: foreign QC-block section parsed instead of skipped | killed (real ENMRG fixture earns its keep) |
| M6 | assemble: source-preference rank inverted | killed |
| M7 | esdat: `.st_esdat_check_parseable` zero-row corruption abort disabled | **SURVIVED** — test-adapter-esdat 82/82 green |
| M8 | units: conversion result discarded | killed |

- **M1:** A44.2's HANDOVER entry claims the guarded fill landed "with
  regression tests"; no test distinguishes the guarded from the unguarded fill
  (in the fixtures, the joined sample's feature always equals the row's own
  feature, so the clobber is invisible). Add a case where a crosstab row's
  inline `feature_raw` differs from a joinable sample row's.
- **M7:** the CORRUPT fixture aborts through a different path, so the
  A35-refined "data lines but zero parsed rows" structural check has **no test
  that exercises it** — it is unverified protection. Add a fixture that
  actually produces the readr swallow-to-zero-rows behaviour the comment
  describes (or pin the check with a unit test on a temp file).
- Note the A46 twin-dedup regression test currently sits in red test-ingest —
  inoperative until the plan-11 production amendments land; the protection
  window is open.

---

## A — Architectural / plan-level issues

### A-1. The A22 seam was never assigned to a plan (root cause of F1)

A22 splits one behaviour across two plans: plan 07 *marks*, plan 08 *folds*.
PLAN-07's criteria test the marking; PLAN-08's R-8.1–R-8.8 never mention the
flag columns, so nothing specced the folding and nothing tests the seam. This
is a workflow lesson as much as a code bug: **when a CONTRACT adjudication
spans a producer and a consumer, both plans' criteria must name it.** (Same
genus as the F3 seam: a consumer reads an optional column the producer never
emits, and the consumer's unit test fabricates the producer's shape.)

### A-2. Plan 11's premise that `sample_datetime_mismatch` "stays held" is false

Plan 11 (and D6, and the cypher-and-feature-alias memory) treat
`value_conflict` + `unknown_unit` + `sample_datetime_mismatch` as the review
kinds that *continue to hold data*. Because of F1, `sample_datetime_mismatch`
has **never held anything** — the flag is discarded and the row commits with a
first-match date. D6's criterion "a feature-pending row that also fails
units/value/datetime is held" is only implementable for datetime if the A22
folding exists. Plan 11 should either absorb the folding fix (it is already
amending `reconcile_event()`) or declare the dependency explicitly; the
"over-flagging in the no-lab_sample_id fallback" note in its Open/deferred
section understates the actual state (it isn't over-flagging — it's
mis-dating plus zero flags surviving).

### A-3. Plan 11's C18/`source_hash` fix covers review only; the skipped side (F3) stays broken

R-11.9 adds `source_hash` to `.rc_proto_review()` and stops there. The
`already_present` provenance path reads `skipped$source_hash`
([commit.R:274](../R/commit.R)) and will keep getting `NA` after plan 11 lands.
One extra column in `.rc_proto_skip()` + the `already_present` branch closes it;
fold into the same amendment.

### A-4. The test core-DDL is allowed to drift from the live schema, and that drift masks real bugs

`helper-db.R` keeps `virtual` (live: absent) and omits `lon`/`lat`
(live: NOT NULL) "out of scope" per plan 11 C11's narrow fix. F5 is the direct
cost: an exported function that cannot run against the live DB, green in CI.
Recommend a one-off reconciliation of `.st_test_core_ddl` against
`information_schema` of the live DB (a generated, committed DDL snapshot would
make the drift visible in review), and a `skip_if`-gated test that diffs the
two when `SAMPLETIDY_CORPUS_DB` is set.

### A-5. The IR cannot express a result→sample linkage for column-shaped sources (root cause of F2)

ESdat gets an exact join key for free (`lab_sample_id`); column-shaped sources
(ACIRL; crosstabs without an ALS sample number) rely on a lossy
(feature[, date]) fallback that plan 07 explicitly left date-less
(PLAN-CHANGE-REQUESTS). Any adapter that knows *positionally* which sample a
result belongs to should be able to say so. The synthetic per-column
`lab_sample_id` (F2 fix) is the minimal expression of this; if more such
sources arrive, consider a first-class `sample_ref` IR column instead of
overloading `lab_sample_id`.

### A-6. Matrix is not part of any identity key

A two-section (WATER+SOIL) crosstab measuring the same analyte at the same
feature+date+method yields two rows whose only difference is section matrix —
they land on the **same** sample (matrix isn't in the sample find-or-create
key or the A45 analysis key) as two analyses distinguishable by nothing. Rare
(multi-section files are legacy per A34) but the model can't represent it.
Log as a known limitation or add matrix to the sample identity discussion when
the datetime convention is revisited.

### A-7. No within-batch duplicate guard before commit

R-8.6 dedups across *methods*; two identical-key rows from the same method in
one batch (F2's mis-dated visits; or a lab re-listing a determination) each
pass the three-way (which only consults the DB) and commit as two analyses on
one sample. A cheap `duplicated()` check over (feature, date, analyte, method)
in `clean` before commit — route dupes to review or collapse per A14 — would
close it.

---

## PERF — easy wins (none load-bearing today)

1. **`.rc_feature_candidates()` re-normalises the whole registry per row**
   ([reconcile.R:77–78](../R/reconcile.R)): `.rc_key(registry$feature$name)`
   and the mask equivalent run `normalise_lab_text()` (a 11-pattern gsub chain)
   over every registry name for **every result row**. Precompute the keys once
   in `.rc_load_registry()`. Same for `.rc_lab_method_candidates()`
   ([reconcile.R:162](../R/reconcile.R)). With 894 features × thousands of
   rows this is the reconciler's dominant cost.
2. **`.rc_recorded_revision()` re-queries per conflicting row**
   ([reconcile.R:549](../R/reconcile.R)) — 2–3 queries each time; cache per
   (event, work_order).
3. **Files are SHA-256-hashed twice**: `route_files()` builds `file_meta`, and
   `.ig_parse_claimed()` builds it again ([ingest.R:66](../R/ingest.R)). Pass
   the routed metadata through (or cache by path+mtime).
4. **ESdat reads the header up to three times** per file (match, parse
   dispatch, full read — [adapter-esdat.R:56,138](../R/adapter-esdat.R));
   `readr` spin-up dominates small-file cost.
5. **Crosstab/ACIRL build one `tibble::tibble()` per emitted cell**
   ([adapter-crosstab.R:533](../R/adapter-crosstab.R),
   [adapter-acirl-field.R:157](../R/adapter-acirl-field.R)) — tibble
   construction is ~ms each; accumulate plain vectors/lists and build one
   tibble per file.
6. **`.st_join_samples_onto_results()`** recomputes `which()` scans per result
   row — fine at fixture scale; a keyed lookup (split by key) if corpus files
   grow.

---

## Known issues confirmed as still present (already logged elsewhere — no new action)

- `dry_run` persists `ingest_file` state transitions (HANDOVER; verified in
  code — parse/assemble states are written before the dry-run gate).
- Orphan events commit with a project named `NA` (`.ct_ensure_project` with an
  NA work order inserts `name = NA`).
- `sample.datetime` stored as a UTC-shifted wall clock (A44 note).
- SpreadsheetML `.XLS` unclaimed by design (A37).
- OneDrive hydration hazard for corpus runs (HANDOVER); the suggested
  loud-fail hydration guard in `corpus_files()` is still unimplemented and
  still worth doing.

## Suggested priority order

1. **F2 + F1 together** (adapter join key, then reconcile folding) — they are
   the two halves of the same silent-commit hole, and plan 11's correctness
   arguments assume both are fixed (A-2).
2. **F3** (one column in `.rc_proto_skip()`) — trivial, restores A1; fold into
   plan 11's R-11.9 change (A-3).
3. **T-1** (make the e2e review gate assert the pinned contract) before plan
   11's e2e work builds on it.
4. **F4, F5, F6** — small, isolated, each with a one-file fix.
5. The rest as opportunity allows; A-4's DDL reconciliation is cheap insurance
   before plan 11's migration work makes the schemas diverge further.
