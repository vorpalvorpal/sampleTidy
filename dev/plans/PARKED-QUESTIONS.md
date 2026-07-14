# Parked questions for Robin

Decisions I made autonomously to keep the build moving, where your domain
knowledge could override. None block the MVP; each notes what (if anything)
would change if you decide differently. Raised during Phase 4/5 of the TDD
build; full detail in `PLAN-CHANGE-REQUESTS.md`, decisions recorded in
`CONTRACT.md` A-log.

## 1. ACIRL crosstab column layout (R-5.1) — needs a real file to confirm
The plan pins that the `ALS Sample Number:` label sits at column index 3
(XTAB) vs 4 (ENMRG) and that the header row reads `Analyte grouping/Analyte`,
but I had no captured real ACIRL crosstab to resolve whether `Analyte
grouping` is a separate category column or a second analyte-name column. The
fixture (`fixtures/crosstab/`) commits to a documented interpretation and the
**parser locates labels by regex, not fixed indices**, so a different real
layout changes only the fixture data, not the parser or its tests. **Blocks:**
nothing now; the plan-10 corpus gate re-checks this against real files.
→ If you can drop one real XTAB + one real ENMRG into the corpus dir, the gate
will confirm or flag it automatically.

## 2. QC sample types LAB_D / MS at the adapter (R-4.3) — probably moot
PLAN-04 prose mentioned all five QC types (LCS/MB/LAB_D/MS/NCP); FIXTURES.md
pinned only LCS/MB/NCP. Since the adapter copies `sample_type` verbatim and
the reconciler filters everything ≠ `Normal` anyway (QC is out of MVP scope),
LCS/MB/NCP already prove the pass-through. **Blocks:** nothing.
→ Only matters when QC ingestion is built (post-MVP); revisit then.

## 3. Domain-helper connection handling (A16) — confirm the ergonomics
I made `add_feature()`/`add_analyte()`/`add_project()`/`correct_value()`
resolve their own DB connection from `st_config("live_db")` (so they're
callable by a human at the console with no `con`), while the generic
`db_append/update/delete` take an explicit `con`. **Blocks:** nothing; it's an
API-ergonomics choice consistent with DESIGN §9.3.
→ Say if you'd rather every mutation helper take an explicit `con`.

## 4. Assembly→review interface (A22)
Assembly flags review-worthy rows inline on `event$results`
(`needs_review`/`review_kind`/`review_payload`), which the reconciler folds
into its review output — rather than assembly emitting its own review bucket.
**Blocks:** nothing; internal seam only.

## 5. `Method_Type` (A15) — resolved, FYI only
FIXTURES.md had dropped the `Method_Type` column that real ALS ESdat files
carry; since `match()` fingerprints the header, this would have made the
adapter reject every real file. Fixed (fixture + spec now 18 columns, verified
against the live corpus). No decision needed — flagging because it was a real
defect in my own spec.
