# Code-review triage & routing — 2026-07-19

Disposition of every finding in [`CODE-REVIEW-2026-07-19.md`](CODE-REVIEW-2026-07-19.md).
For each: **verdict** (verified against source unless noted), the **fix**, and
**where it lands** in the tdd-plan workflow.

**Method.** Every P1/P2 finding and the load-bearing P3s were re-verified against
the exact cited lines (not taken on the review's word). The live `feature`/
`sample`/`lab_method` schema was probed directly against
`/Users/rjs/Documents/dashboard/data/monitoring.duckdb` (read-only) to settle F5
/ A-4. Every finding checked was **confirmed**; nothing was rejected. A handful
carry genuine *design* decisions that are the user's to make — these are flagged
`⚑ DECISION` and filed in `PLAN-CHANGE-REQUESTS.md`, not silently resolved.

## Routing model (the answer to "new plan? deltas?")

Two vehicles, split on one principle: **a finding folds into PLAN-11 iff it edits
a function PLAN-11 is already rewriting (or a decision PLAN-11 pins), so the
Phase-6 implementer writes that code correctly *once*** (the cost model's
"write once" rule). Everything else — independent defects in landed code PLAN-11
never touches — goes to a new **PLAN-12**, a proper tdd-plan plan (R-12.x criteria
→ Phase-4 tests → Phase-6 impl → Phase-7 audit), because there are too many for
the A44/A46 "one delta + one A-log line" precedent to stay legible.

PLAN-11 is mid-Phase-4: its production amendments to `reconcile.R`/`commit.R` are
**not written yet**, so folding in now costs nothing and avoids a later two-plans-
edit-one-function merge conflict. This is *the* reason the reconcile/commit-side
findings go to PLAN-11 rather than a delta against the (about-to-be-rewritten)
current code.

| bucket | findings |
|---|---|
| **Fold into PLAN-11** (reconcile/commit/helper-db rework, "write once") | F1, F2, F3, F4, F5, F9⚑, T-1(e2e half); adjudications A-1, A-2, A-3, A-4, A-5 |
| **New PLAN-12** (independent landed-code defects) | F6, F7⚑, F8, F10, F11, F12, F13, F14, F15, F16⚑, F17, F18, F19; A-6, A-7; T-2 M1, T-2 M7, T-1(sweep); PERF-1/2 |
| **CONTRACT edits** | correct the `feature` schema block (A-4); A56 (A22 consumer seam), A57 (quantified/rl_high), A58 (add_feature signature) |
| **Already logged — no new action** | the five "known issues" (dry_run state, orphan project NA, UTC wall-clock, `.XLS` unclaimed, OneDrive hydration) |

---

## P1

### F1 — assembly's inline review flags never consumed ✅ VALID → PLAN-11 (new R-11.14)
Confirmed: `assemble.R:164-172,330-338` set `needs_review`/`review_kind`/
`review_payload`; `reconcile_event()` (`reconcile.R:594-667`) has no stage that
reads them — the QC filter keys on `sample_type` only. A flagged row whose
feature/analyte/units resolve lands in `clean` and commits with no review item.
**Fix:** add a stage-0 to `reconcile_event()` that partitions
`needs_review == TRUE` rows out of `active` into `review` (mapping
`review_kind`/`review_payload`), counted like R-8.2's `add_review`. Lands as
PLAN-11 R-11.14 — it *is* the R-11.5 funnel→conveyor rework, so it belongs in
that rewrite, plus the missing seam test. Resolves A-1.

### F2 — ACIRL multi-visit visit-2 committed with visit-1's date ✅ VALID → PLAN-11 (new R-11.15, cross-plan)
Confirmed structurally: `assemble.R:148` fallback-joins by feature key only;
`:174-179` fills `sample_datetime_raw` from the *first* non-NA match; `:162-172`
flags every such row `needs_review` (which F1 then discards). Review verified
behaviourally against the shipped `2400-9999-01_Test_WMF.xlsx` fixture (all 23
rows re-dated to 24 May). **Fix (recommended):** ACIRL adapter emits a synthetic
per-column `lab_sample_id` (`"<sheet>!c<col>"`) on **both** results and samples
rows → flows through the existing exact-match join, no IR schema change, kills the
spurious flags. Coupled to F1 (review priority #1); shares the T-1 e2e regression.
Cross-plan edit to `adapter-acirl-field.R` (06) + `assemble.R` (07). Resolves A-5.

### F3 — `already_present` provenance written with `source_hash = NA` ✅ VALID → PLAN-11 (extend R-11.9)
Confirmed: `.rc_proto_skip()` (`reconcile.R:35-37`) has no `source_hash` column,
so `.ct_record_already_present()` (`commit.R:274`) reads `NA`. **Fix:** add
`source_hash` to `.rc_proto_skip()` and populate it in the `already_present`
branch of `.rc_three_way()` (`reconcile.R:542-546`, the row's `source_hash` is in
scope). PLAN-11 R-11.9 already adds `source_hash` to the *review* proto; this is
the same one-column change on the *skip* proto. Resolves A-3.

---

## P2

### F4 — `quantified` re-derived from `below_detection`; `rl_high` dropped ✅ VALID → PLAN-11 (new R-11.16)
Confirmed: `parse_value()` (`values.R:62`) sets `quantified=FALSE` for `>`/`BDL`,
but `reconcile.R:285` and `commit.R:187` re-derive `quantified` from
`below_detection` alone → a `>2000` row (`below_detection=FALSE`) commits
`quantified=TRUE`. `rl_high` is parsed (`values.R:69`) but never written —
`commit.R:195` writes only `rl_low`. **Fix:** carry `parsed$quantified` through
`.rc_resolve_units_values()` onto `kept$quantified` (already a column) and have
`.ct_commit_analyses()` use `clean$quantified` instead of re-deriving; add an
`above_detection`/`rl_high` path and write `analysis.rl_high`. Folds into
PLAN-11's R-11.6/R-11.8 seam (those functions are being rewritten anyway).

### F5 — `add_feature()` cannot run against the live DB ✅ VALID → PLAN-11 (new R-11.17 + A-4)
Confirmed against live schema (probed directly): `feature` has **18 columns**,
`name`/`site`/**`lon`/`lat` all NOT NULL**, `geom_wkt` nullable, and **no
`virtual` column**. `add_feature()` (`mutate.R:324-338`) builds a `virtual`
column (fails column validation) and omits `lon`/`lat` (NOT NULL violation). Green
only because `helper-db.R`'s test DDL still has `virtual` and lacks `lon`/`lat`.
**Fix:** signature `add_feature(name, site, lon, lat, flow=NA, matrix=NA,
geom_wkt=NA, actor, reason)` — drop `virtual`; reconcile the test DDL to the live
18-column shape. Bundled with A-4's DDL reconciliation; PLAN-11 owns `helper-db.R`
and has the `mutate.R` cross-plan edit. **The CONTRACT `feature` schema line is
itself wrong** (hides `lon`/`lat` behind `…`, never says NOT NULL) — corrected as
part of this.

### F6 — bad adapter `match()` return claims the file then aborts the run ✅ VALID → PLAN-12
Confirmed: `route_files()` never validates `match()`'s return. A `match()`
returning `NA` (not throwing) makes `claims[[id]]=NA` (`router.R:121`);
`names(claims)[claims==t]` (`:127`) yields a length-1 `NA` "winner" →
`state="claimed", adapter=NA`; `.ig_parse_claimed()` then does
`adapter_registry()[[NA]]` (`ingest.R:65`) **outside** its tryCatch → subscript
error aborts the whole run. **Fix:** validate each `match()` return against
`c("exact","format","fallback","no")` (length-1, non-NA) in `.st_route_one_file()`
— anything else → that file `failed`; belt-and-braces, move the `ingest.R:65`
registry lookup inside the tryCatch.

### F7 — one poison event aborts the whole ingest run ✅ VALID → PLAN-12 R-12.2 ✅ DECIDED
Confirmed: `reconcile_event()`/`commit_event()` run bare in the loop
(`ingest.R:121-152`), no per-event tryCatch. A single always-failing event
permanently blocks everything routed after it. R-9.5 specced containment for
*parse* only. **DECIDED (user 2026-07-19): contain, loudly** — per-event tryCatch
(kept files → `failed`, `cli_warn`, `events_failed` counted, continue); abort
`sampletidy_error` only if *every* event fails. PLAN-12 R-12.2 + CONTRACT A60.

### F8 — crosstab two silent-drop paths ✅ VALID → PLAN-12
Confirmed both: (1) `adapter-crosstab.R:386-393` — an unsupported `…Matrix:`
section `next`s every following row with no `skipped`/warning until the next
dialect marker (could over-skip real data); (2) `:501-509` — a missing `ALS
Sample Number` row leaves `sample_cols` empty, so every analyte row is
misclassified as a method-group row and the section emits zero results / zero
skips / zero warnings (a label typo blanks a whole file). Violates CONTRACT's "no
silent drops". **Fix:** one `report$warnings` entry (with row range) on entering
an unsupported section, and a warning when an analyte header is reached with
`length(sample_cols)==0`.

### F9 — same feature+date, different clock time silently reuses the first sample ✅ VALID → PLAN-11 R-11.18 ✅ DECIDED
Confirmed: `.ct_find_or_create_sample()` (`commit.R:95-104`) narrows by datetime
only `if (nrow(cand)>1)` and, on no datetime match, returns `cand$uuid[[1]]`
regardless — a 09:00 and a 15:00 reading at one feature+date collapse to one
sample. A11 says "date first, then datetime when both have it"; it never says a
*non-matching* datetime should reuse. **DECIDED (user 2026-07-19): two distinct
samplings.** Pinned as PLAN-11 R-11.18 + CONTRACT A62 — the split applies at both
`.rc_find_existing` (R-11.7) and `.ct_find_or_create_sample` (R-11.8), firing only
when distinctness is provable (both sides non-NA and differing).

---

## P3 (all → PLAN-12 unless noted)

- **F10** ✅ `archive_file()` (`archive.R:52`) and `snapshot_db()`
  (`snapshot.R:28,33`) ignore `file.copy`/`file.rename` returns → a failed copy
  still "succeeds" and returns a snapshot path that doesn't exist. **Fix:** check
  both returns; abort (`sampletidy_error`) on FALSE.
- **F11** ✅ `ir_results()`/`ir_samples()` subset to pinned columns *before*
  `ir_validate()` (`ir.R:74-77`) → extra-column check is dead; a missing required
  column throws a vctrs subscript error, not `sampletidy_ir_error`. **Fix:**
  validate before subsetting.
- **F12** ✅ `db_update()` logs every field with no old≠new check
  (`mutate.R:243-259`); `db_delete()` writes a change_log row even for a 0-row
  DELETE (`:288-301`); `DBI::dbCommit()` sits outside the tryCatch
  (`:118`). **Fix:** skip unchanged fields; guard delete on rowcount; move
  `dbCommit` inside the tryCatch.
- **F13** ✅ `ingest_report$files_by_state` uses `routed$state` (route-time)
  (`ingest.R:222`), so committed/archived files read as `"claimed"`. R-9.5 says
  terminal state. **Fix:** re-query `ingest_file` for the routed hashes.
- **F14** ✅ (hardening) crosstab `match()` peeks a fixed 2048-byte
  `file_meta()` slice (`adapter-crosstab.R:125-131`) — a very wide header past 2
  KiB unclaims; a UTF-8 BOM defeats `^Matrix:`. **Fix:** read first N *lines*;
  BOM-strip line 1.
- **F15** ✅ (guard) `ingest_file_upsert()` unconditionally overwrites
  `filename`/`size` on re-sight (`db-schema.R:184-188`). All current callers pass
  both, but a defaulted call would null a real filename. **Fix:** COALESCE-guard.
- **F16** ✅ (low, DECIDED) `st_config()` env-var values are always strings, so
  `SAMPLETIDY_FIELD_ANALYTES` shrinks the ACIRL allowlist to one entry.
  **DECIDED (user 2026-07-19): string-only + guard** — list-valued keys set in
  code only; `st_config()` aborts if one is sourced from env. PLAN-12 R-12.11.
- **F17** ✅ (doc) stale comment `db-schema.R:126-130` cites a report that no
  longer exists; the discrepancy is adjudicated as A31. **Fix:** cite A31.
- **F18** ✅ (UX) `register_builtin_adapters()` emits four "Overwriting existing
  adapter registration" informs every `ingest_dir()` run
  (`adapter-registry.R:53`). **Fix:** suppress the inform when a built-in
  re-registers itself.
- **F19** ✅ (low) `.ct_resolve_samples()` always writes the adapter org as
  `sample.organisation` (`commit.R:116/161`); R-9.2 step 2 says "sampler org if
  known else org". Minor; note for the datetime-convention revisit.

---

## T — test-suite strength (→ PLAN-12, except T-1's e2e half → PLAN-11)

- **T-1** ✅ the R-10.2 "review_queue holds the engineered unknowns" test asserts
  only `nrow(reviews) >= 0` + `expect_type(report,"list")`
  (`test-e2e-pipeline.R:195-196`) — a tautology, the fifth "gate that cannot fail"
  (cf. A46/A47). It's exactly the gate that would have caught F1/F2.
  **Two parts:** (a) make that e2e gate assert the pinned contract — folds into
  PLAN-11 with F1/F2 (they must be green together); (b) a **suite-wide sweep** for
  `>= 0`, `expect_type(<report>,"list")`, and other no-op assertions → PLAN-12,
  feeds `dev/tdd-skill-improvements.md`.
- **T-2 M1** ✅ removing assemble's A44.2 `is.na()` feature_raw guard SURVIVES the
  suite — no test distinguishes guarded from unguarded fill. **Fix:** add a case
  where a crosstab row's inline `feature_raw` differs from a joinable sample's.
  → PLAN-12 (plan-07 test).
- **T-2 M7** ✅ disabling `.st_esdat_check_parseable`'s zero-row abort SURVIVES —
  the CORRUPT fixture aborts through a different path, so the A35 "data lines but
  zero parsed rows" check has no test. **Fix:** a fixture (or temp-file unit test)
  that produces the readr swallow-to-zero-rows behaviour. → PLAN-12 (plan-04 test).

---

## A — architectural / plan-level

- **A-1** ✅ the A22 seam (plan-07 marks, plan-08 folds) was never assigned to a
  plan → root cause of F1. Resolved by R-11.14 + CONTRACT A56; workflow lesson
  recorded (both plans' criteria must name a cross-plan CONTRACT adjudication).
- **A-2** ✅ PLAN-11's premise that `sample_datetime_mismatch` "stays held" is
  false today (F1 discards it). Correct PLAN-11's Open/deferred wording; the D6
  "held" logic depends on R-11.14 existing. → PLAN-11.
- **A-3** ✅ PLAN-11's C18/`source_hash` fix covers review only; the skipped side
  (F3) stays broken. → folded into R-11.9 (see F3).
- **A-4** ✅ the test core-DDL drifts from live and the drift masks F5. Live
  `feature` probed and pinned above. **Fix:** reconcile `.st_test_core_ddl` to the
  live 18-column shape; a `skip_if`-gated test diffing test-DDL vs
  `information_schema` when `SAMPLETIDY_CORPUS_DB` is set. → PLAN-11 (owns
  `helper-db.R`) + CONTRACT schema correction.
- **A-5** ✅ the IR can't express a result→sample linkage for column-shaped
  sources → root cause of F2. The synthetic `lab_sample_id` (R-11.15) is the
  minimal expression; a first-class `sample_ref` IR column is the post-MVP shape
  if more such sources arrive. → PLAN-11 note.
- **A-6** ✅ matrix is in no identity key — a WATER+SOIL crosstab measuring one
  analyte at one feature+date+method lands two indistinguishable analyses on one
  sample. Rare (multi-section is legacy per A34). → PLAN-12 known-limitation doc.
- **A-7** ✅ no within-batch duplicate guard before commit — two identical-key
  rows from one method in one batch each pass the DB-only three-way and commit as
  two analyses. F2's fix removes its main trigger (mis-dated visits); a cheap
  `duplicated()` over (feature,date,analyte,method) in `clean` closes the rest.
  → PLAN-12.

---

## PERF (none load-bearing today → PLAN-12, optional)

Worth doing because the reconciler is the hot path: **PERF-1** precompute
`.rc_key()` of registry feature/method names once in `.rc_load_registry()`
(currently re-normalised per row, `reconcile.R:77-78,162`); **PERF-2** cache
`.rc_recorded_revision()` per (event, work_order) (`:549`). PERF-3..6 (double
hashing, ESdat triple header read, per-cell tibble construction, `which()` scans)
noted but deferred — fixture-scale only.

## Known issues — confirmed present, no new action

`dry_run` persists ingest_file state; orphan events → project `name = NA`;
`sample.datetime` stored UTC-shifted wall clock (A44 note); SpreadsheetML `.XLS`
unclaimed by design (A37); OneDrive hydration hazard (the loud-fail
`corpus_files()` guard is still worth doing — optional PLAN-12 item).
