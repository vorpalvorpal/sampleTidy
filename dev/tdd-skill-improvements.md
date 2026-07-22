# TDD-plan skill improvement log

Findings that feed back into the `tdd-plan` skill's own lessons. Append-only;
this file (not the skill tree) is the writable landing spot for these per the
skill's standing instructions.

## R-12.15 T-1: vacuous-assertion sweep (fifth instance)

Unit P12-test-strength (`dev/tdd-run/briefs/P12-test-strength.md`, block
B-12.15) ran the suite-wide grep for the vacuous-assertion anti-pattern
(`>= 0`, `expect_type(<x>, "list")` as a sole check, bare `expect_no_error`
with no following state assertion) mandated by `phase4-test-authoring.md`'s
"No vacuous assertions `[#7]`" rule. This is at least the **fifth** time this
exact anti-pattern class has turned up in this project (see the R-10.2 e2e
gate this same brief cites as the fourth, "fixed in PLAN-11").

**Grep results, whole suite:**
- `tests/testthat/test-assemble.R`, `tests/testthat/test-adapter-esdat.R`
  (this unit's own target files): every `expect_type(...)`/`expect_no_error`
  hit is accompanied by a specific-value assertion in the same test body
  (either inline or via the shared `expect_valid_event()` helper, which
  itself checks field-by-field structure, not just top-level type) - **no
  fix needed**, verified by reading each hit in context.
- `tests/testthat/test-e2e-pipeline.R:195-196` (`R-10.2` test): still has
  `expect_true(nrow(reviews) >= 0) # sanity: query succeeds even if empty`
  and a bare `expect_type(report, "list")` as the test's ONLY assertions on
  `reviews`/`report` - i.e. the exact pattern this brief says was "fixed in
  PLAN-11". **This looks unfixed as of this unit's run** (2026-07-22) -
  flagged as a plan-change/escalation item in this unit's report rather than
  edited directly (that file is outside this unit's target-file contract).
- `tests/testthat/test-ingest.R:63,113`, `tests/testthat/test-e2e-corpus.R:267`:
  bare `expect_type(report, "list")` hits - not evaluated for sole-check
  status in this pass (out of this unit's target-file scope; recorded here
  for whichever unit next touches those files).

**Skill lesson candidate:** a gate that cannot fail is worse than no gate.
Five recurrences of the same class in one project's history suggests
`phase4-test-authoring.md`'s "No vacuous assertions" rule needs a mechanical
grep step added to Phase 5's audit protocol (checks 4/5 already grep for
`ORDER BY ... LIMIT 1` and type-only assertions - consider pinning the exact
`>= 0` / `expect_type(x, "list")`-as-sole-check patterns as a named,
repeatable grep invocation in that doc, rather than relying on each Phase-4
writer to rediscover the pattern by prose alone).

- **Completed (5th-instance T-1 sweep, 2026-07-22):** the 4 sites above are
  strengthened - `test-e2e-pipeline.R:195-196`, `test-ingest.R:63,113`,
  `test-e2e-corpus.R:267`. All 3 non-corpus-gated sites self-run
  correctly-RED: `ingest_dir()` itself errors (`Binder Error: Table "s" does
  not have a column named "uuid_feature"`, wants `uuid_feature_alias`) in
  `R/reconcile.R` `.rc_find_existing()` / `R/commit.R`
  `.ct_find_or_create_sample()` before reaching the strengthened lines - a
  genuine pre-existing production gap (plan-11/A48-A55 feature_alias
  migration not yet propagated into reconcile/commit), not caused by this
  delta, and much wider than these 4 sites (also breaks R-10.2/10.3/10.4 and
  most of test-ingest.R). Escalated separately; not fixed here (test-only
  delta). `test-e2e-corpus.R:267` is corpus-gated and was SKIPPED
  (`SAMPLETIDY_CORPUS`/`SAMPLETIDY_CORPUS_DB` unset). Re-grep of
  `tests/testthat/` for the T-1 signatures found only 2 further
  `expect_type(x, "list")` hits (`test-assemble.R:55,68`), both inside a
  multi-field `expect_valid_event()` structural validator followed by many
  specific field assertions - not a sole-check vacuous pattern, left as-is.
