# TDD-Plan Skill Improvements: Test Correctness & Robustness

Research report on hardening `.claude/skills/tdd-plan/SKILL.md` so the test suites it
produces are more correct, robust, and trustworthy. Grounded in the seven abstracted
failure classes supplied, **and** cross-checked against this project's own build
history — `dev/plans/CONTRACT.md` adjudications A38–A44 turn out to be the *literal,
unabstracted instances* of six of the seven classes. That log is cited throughout as
primary evidence; it is stronger evidence than any external source because it is this
skill, on this codebase, failing this way.

---

## 1. Failure taxonomy → root causes

| # | Failure (as given) | Real instance in this repo (CONTRACT.md) | Root cause |
|---|---|---|---|
| 1a | Reconciler treats missing key as phantom match | **A44.1**: `.rc_feature_candidates(NA)` → `uuid[c(NA,NA,NA)]` → `unique()` collapses to one `NA`, read as a length-1 "hit"; orphan `uuid_feature = NA` rows reached commit. Only caught by the e2e "no orphan uuids" test (PLAN-10 R-10.2). | Unit tests for `reconcile.R` built candidate vectors by hand and never passed a genuinely-NA key through the *real* upstream lookup path. |
| 1b | Assembly step drops a field across a join | **A44.2**: `.st_join_samples_onto_results()` copied datetime/type/sampler/matrix/parent but not `feature_raw`; every real-format (ESdat) result stayed feature-less, masked by 1a. | Unit tests for `assemble.R` fed hand-built sample/result frames that happened to already carry `feature_raw`-equivalent data on both sides — no test ran the *real* ESdat adapter's actual output (which sets `feature_raw = NA`) through the real join. |
| 1c | Commit step stores dates in local time; UTC-shift breaks idempotency | **A44.3**: `.ct_find_or_create_sample()` built `as.POSIXct(..., tz="Australia/Sydney")`; duckdb writes POSIXct as UTC, so midnight AEST landed as the previous day, breaking `CAST(date AS DATE)` round-trip and re-ingest idempotency. | No round-trip test wrote a timestamp through the *real* DB driver and read it back before Phase 6; the bug was invisible to any test that only inspected the R value pre-write. |
| 2 | Tests that can't run (unquoted reserved word `ORDER BY at`) | **A40**, **A42**: `test-mutate.R` and `test-commit.R:181` both used unquoted `ORDER BY at DESC` (`at` is a DuckDB reserved word) — hard parser errors, same bug twice. | Phase 4's cheap writer never executed the suite it wrote; Phase 5's audit verified red/green *counts*, not that every failure was TDD-red for the *expected* reason. A parser syntax error and "module doesn't exist yet" both register as "red." |
| 3 | Non-deterministic `ORDER BY … LIMIT 1` tie assertion | Not yet hit in this repo (A42 explicitly *confirms* determinism by construction — `db_update` lists `value` first, DuckDB returns first-inserted among `at`-ties) — i.e. this project got lucky once and had to reason about it after the fact rather than by rule. | No standing rule that every `ORDER BY … LIMIT 1` assertion must carry an explicit uniqueness/tiebreak guarantee; correctness was established ad hoc, per-instance, by the orchestrator. |
| 4 | Fixture/harness lifetime bug recurring 4+ times (`withr` scoping) | **A38** (`seed_db()`), **A41** (three separate plan-09 setup helpers: `archive_test_setup`, `commit_test_setup`, `ingest_test_setup`), **A43** (`helper-corpus.R`'s `build_e2e_input_dir()`) — same root cause five times: a bare `withr::local_tempdir()`/`local_options()` used as a **default argument** or **inside a helper** binds its deferred cleanup to the *helper's own frame*, tearing resources down the instant the helper returns, before the test body runs. | Phase 4 has no requirement for a single, shared, audited fixture-helper library — each new helper re-implements the same pattern from scratch, so a language-specific footgun (R's promise-evaluates-in-callee-frame semantics) gets rediscovered and re-fixed per file instead of fixed once centrally. |
| 5 | NA/edge-unsafe test assertions (phantom all-NA row) | **A43**: `test-ingest.R` filtered with bare `states$filename == "x"` against a seeded `filename = NA` row; base-R `df[<logical with NA>, ]` splices in a phantom all-NA row, inflating row counts and silently selecting the wrong row (`legacy-hash-XX`) in one test. | The *test code itself* was written with the same NA-unsafety bug it should have been designed to catch in production code — no discipline requiring test-side filters to be NA-safe by default. |
| 6 | Cross-file global-state leakage, order-dependent pass/fail | Not yet manifested as a *found* bug in this repo, but the mechanism (A38/A41 cleanup timing) is exactly the shape of bug that produces it, and the skill has no standing gate that would catch it if it recurs elsewhere (e.g. the adapter registry noted in CONTRACT.md: `register_builtin_adapters()` is deliberately idempotent specifically *because* a prior test's `clear_adapters()` could otherwise leave the registry empty for a later file). | No mechanical check that the suite passes in more than one execution order. Per-file gates ("Per-plan: `testthat::test_file()` green") say nothing about whether the full-suite order matters. |
| 7 | Weak/vacuous assertions | Not directly instanced with a filed A#, but structurally invited by Phase 4's current instructions, which specify only "real assertions" with no positive list of what counts as weak, and by Phase 5's audit question ("does every criterion have a test that asserts what the plan actually says") which is judged prose-by-prose rather than against a checklist of banned patterns. | No blocklist of known-weak assertion idioms; audit relies entirely on the Opus-class reader's judgement with no mechanical backstop. |

**Pattern across the whole log:** every defect that survived to Phase 9/e2e (A44.1–3) is a
**seam** defect — it lives in the handoff between two modules' real implementations, not
inside either module considered alone. Every defect that was *merely annoying* (A38–43) is
a **test-code** defect — bugs in the harness/assertions, not in production code. The skill
currently has strong protocol for judging production code (Phases 5–8) but only prose
guidance, not mechanical checks, for either category above.

---

## 2. Practices & sources

**Hermeticity / test isolation.** "A test should contain all of the information
necessary to set up, execute, and tear down its environment... Tests should assume as
little as possible about the outside environment, such as the order in which tests are
run." Shared mutable state accessible across test files is the primary cause of
order-dependent flakiness ("polluter"/"victim" pattern). — [Software Engineering at
Google, ch. 11](https://abseil.io/resources/swe-book/html/ch11.html); [Reduction of Test
Re-runs by Prioritizing Potential Order Dependent Flaky
Tests](https://arxiv.org/html/2510.26171). *Prevents #4, #6.*

**Determinism (time, ordering, ties).** Flakiness is dominated by nondeterminism sources:
clock time, thread scheduling, unordered-collection iteration, network latency. A test
that only accepts a subset of otherwise-valid behaviors (e.g. one specific row among
several equally-valid tied rows) is itself the bug, even though the code may be correct.
— [Google Testing Blog: Flaky Tests at Google](https://testing.googleblog.com/2016/05/flaky-tests-at-google-and-how-we.html);
[Effective Testing — Reducing Non-determinism](https://jivimberg.io/blog/2020/07/27/effective-testing-reducing-non-determinism/).
*Prevents #3; contributes to #6.*

**Tests-before-code can themselves be wrong; verify the fail-for-the-right-reason
property.** Core TDD discipline: "If you don't start with a test that fails for the
right reason, you are not doing TDD" — a parse error, import error, or harness crash is
*not* evidence the test exercises the intended behavior. — [obra/superpowers:
test-driven-development](https://skills.sh/obra/superpowers/test-driven-development);
canonical Kent Beck TDD red-green-refactor discipline. *Prevents #2 directly, and
underlies why Phase 5 must inspect failure *messages*, not just red/green counts.*

**Test pyramid / why hand-built-input unit tests miss integration defects.** A unit
test proves a component is correct *given the inputs you handed it*; it says nothing
about what happens wired to a real collaborator. "Write integration tests for all
pieces of code where you either serialize or deserialize data" — narrow integration
tests should sit at the boundary between two real components. Google's own size
categories (small/medium/large) map to this: small (unit) tests are deliberately
forbidden from I/O precisely because that's where seam bugs live, and Google explicitly
recommends the great majority of coverage be unit tests *plus* a meaningful minority of
integration tests at real boundaries — over-indexing on either extreme is a documented
antipattern. — [Martin Fowler: The Practical Test
Pyramid](https://martinfowler.com/articles/practical-test-pyramid.html); [Software
Engineering at Google, ch. 11](https://abseil.io/resources/swe-book/html/ch11.html);
[Testing on the Toilet: What Makes a Good End-to-End
Test?](https://testing.googleblog.com/2016/09/testing-on-toilet-what-makes-good-end.html).
*Prevents #1 (all three sub-cases) directly — this is the taxonomy's deepest class.*

**Consumer-driven contract testing.** When two modules are built by different
workers/agents against a shared digest, a contract test — run the real producer, assert
the real consumer accepts and correctly interprets its output — catches drift that unit
tests on either side, built against a hand-typed stand-in for the other side, cannot.
— [Pactflow: Contract Testing vs Integration
Testing](https://pactflow.io/blog/contract-testing-vs-integration-testing/); Fowler,
op. cit. *Directly maps onto this skill's CONTRACT-digest module boundaries; prevents
#1.*

**Testing on realistic/production-like data.** This project independently rediscovered
this: per `real-corpus-and-fixtures.md`, synthetic fixtures passed while masking two
real defects (ESdat latin-1 encoding, real crosstab layout) later exposed only by
anonymized real files (A34, A35). This is the same argument the sources make: synthetic
fixtures encode the author's *model* of the data, which can be wrong in exactly the way
the real data would expose. *Prevents #1-class defects that depend on real-world data
shape, and is already validated empirically in this repo.*

**Over-mocking / "don't mock what you don't own."** Mocks encode assumptions about a
collaborator's behavior; if those assumptions are wrong, the mock enshrines the bug and
the test passes while production fails. The fix is either real components/fakes with
real semantics, or narrow integration tests at the boundary — not deeper mocking. —
[Martin Fowler, op. cit.](https://martinfowler.com/articles/practical-test-pyramid.html)
(WireMock-drift example); [Don't Mock What You Don't
Own](https://dev.to/satansdeer/dont-mock-what-you-dont-own-cd6). *Reinforces #1: a
hand-built "upstream module's output" fixture is functionally a hand-rolled mock of
that module, with exactly this risk.*

**Property-based testing.** Generates inputs (including NA/empty/duplicate/boundary
values a human wouldn't think to write) from a declared strategy and checks an
invariant across all of them, with automatic shrinking to a minimal failing case. —
[Hypothesis docs](https://hypothesis.readthedocs.io/); QuickCheck (Claessen & Hughes).
*Would have surfaced #1a (NA key), #3 (duplicate timestamps → tie), #5 (NA-in-filter-
column) as a matter of course rather than requiring a human to think of the case.*

**Mutation testing as a suite-quality amplifier.** Introduces small code mutants and
checks whether the existing suite kills them; a surviving mutant means some code path is
exercised but not actually *asserted on* — the exact shape of failure class #7 (vacuous
assertions). — [PIT (pitest)](https://www.triology.de/en/blog/mutation-testing-with-pitest);
[mutmut](https://calmops.com/software-engineering/mutation-testing/). *Prevents #7; also
a mechanical way to catch "tests that pass regardless of the answer" without relying on
an auditor's prose judgement.*

**Assertion specificity / weak-assertion test smells.** "Tests should assert on a
specific outcome — not just a type, and not just 'some error happened.'" Named smells:
*Sensitive Equality* (asserting a whole object when only one field matters — the
opposite failure, worth noting as a trap in the other direction), *Missing Assertion*,
weak existence checks (`assertNotNull`, `expect_type`) standing in for a behavioral
assertion. — [Google Testing Blog: To Assert or Not To
Assert](https://testing.googleblog.com/2009/02/to-assert-or-not-to-assert.html);
[testsmells.org](https://testsmells.org/pages/testsmells.html). *Prevents #7.*

**NA/edge-unsafe filtering is a well-documented R footgun.** `df[df$col == x, ]` returns
a phantom all-`NA` row whenever any row has `NA` in the filtered column, because base R
subsetting treats `NA` in a logical index as "include, but blank." Canonical fix:
`df[!is.na(df$col) & df$col == x, ]`, or use `dplyr::filter()` (which drops `NA` by
default). — [R-bloggers: Subsetting in the presence of
NAs](https://www.r-bloggers.com/2018/10/subsetting-in-the-presence-of-nas/).
*Prevents #5 exactly — this is not a one-off mistake, it's a known-named R pitfall the
skill can name explicitly.*

**Scoped-cleanup idiom for R test fixtures.** `withr`'s documented pattern for helper
functions: take `env = parent.frame()` and thread it through as the *second* argument to
`withr::defer()`/`local_*()`. Skipping this makes cleanup fire when the *helper* returns,
not when the *test* returns — precisely the A38/A41/A43 bug, reproduced independently in
the `testthat` docs as the canonical anti-example. — [testthat: Test
fixtures](https://testthat.r-lib.org/articles/test-fixtures.html). *Prevents #4 —
and gives the skill a citable, exact idiom to mandate rather than leaving it to each
worker to rediscover.*

---

## 3. Prioritized SKILL.md edits

Ordered by (severity of failure class prevented) × (how cheaply the edit is enforced).
Each entry quotes the current anchor text and gives exact language to add.

### P1 — Phase 4: require a real seam test per module boundary (prevents #1a/#1b/#1c — the deepest class)

Anchor (current Phase 4 text):
> "A **Sonnet-class** agent writes the complete failing test suite directly from the
> plans and CONTRACT digest — full tests, real assertions, fixtures, helpers, one
> write."

Add immediately after:
> **Seam requirement.** For every producer→consumer boundary named in the CONTRACT
> digest (e.g. adapter→assemble, assemble→reconcile, reconcile→commit), write at least
> one integration test that invokes the real upstream module and feeds its *actual
> output* into the real downstream module — never a hand-built structure standing in
> for another module's output. Hand-built fixtures remain the norm for a module's own
> unit tests, but they may not be the *only* coverage of a seam. Any field the plan
> requires to survive a join/transform (e.g. "X carries `feature_raw` through
> assembly") gets an assertion on that specific field using the real joined output, not
> a synthetic frame that already has the field pre-populated on both sides. Any
> timestamp/date value that crosses a persistence boundary (DB write, file write) gets a
> round-trip test: write via the real driver, read back, assert the calendar
> day/instant survives — do not assert only on the pre-write in-memory value.

This directly targets the three real defects found here (A44.1–3), which every
per-module unit test passed.

### P2 — Phase 5: audit must confirm every red is red *for the expected reason* (prevents #2)

Anchor:
> "Then verify the red/green state yourself: every failure must be TDD-red (missing
> modules/exports), the pre-existing suite must still pass, and the harness (fixtures,
> helpers) must hold."

Replace/extend with:
> Then verify the red/green state yourself by **running the suite and reading every
> failure message**, not just the red/green count: each failure must show a missing
> module/export/symbol, never a parse error, collection error, or harness crash (e.g.
> "syntax error at or near", "could not find function", "object not found" pointing at
> test infrastructure rather than the module under test). A test file that fails to
> *collect* is not TDD-red, it is broken, and must be fixed before Phase 6 starts —
> unrunnable test files silently reduce coverage to zero for everything they were meant
> to check.

This is exactly the A40/A42 bug (`ORDER BY at DESC`), which happened twice under the
current wording because "TDD-red" was being confirmed by count, not by reading messages.

### P3 — Phase 5 (or a new Phase 6 pre-gate): run the suite twice, in two different orders (prevents #6)

Add as a new bullet in Phase 5's verification step:
> Run the full suite once in default order and once in shuffled or reversed file order
> (most test runners support this — e.g. `testthat::test_dir(..., shuffle = TRUE)`,
> `pytest -p randomly`). Any pass/fail delta between the two runs is an
> order-dependence defect (shared mutable state, un-deferred cleanup) and must be filed
> and fixed before Phase 6, not discovered later when a full-suite run happens to differ
> from a per-file run.

This is cheap (a second bash invocation, no extra model spend) and directly targets the
mechanism behind A38/A41 (and the reason `register_builtin_adapters()` had to be made
defensively idempotent against a prior test's `clear_adapters()`).

### P4 — Phase 4: mandate one shared, audited fixture-helper library with the correct scoped-cleanup idiom (prevents #4)

Anchor:
> "...full tests, real assertions, fixtures, helpers, one write."

Add:
> **One helper library, not N.** Stateful test helpers (tempdirs, DB seeding, option
> scoping) live in a single shared helper file, written and reviewed once, not
> reinvented per test file. Every helper that registers cleanup must accept the calling
> frame explicitly and thread it through: in R, `env = parent.frame()` passed as
> `withr::local_*(..., .local_envir = env)` or `withr::defer(expr, envir = env)` — never
> a bare `withr::local_tempdir()`/`on.exit()` called as a default argument or from
> inside the helper's own body, which binds cleanup to the helper's frame and tears
> resources down before the caller's test body runs. (Analogous "cleanup fires in the
> wrong scope" bugs exist in other languages' fixture systems — pytest fixture
> `yield`-before-`teardown` ordering, Go `t.Cleanup` registered on the wrong `*testing.T`
> — the instruction to the writing agent should name the language's specific idiom.)

Evidence: this exact bug (A38) was fixed once, then independently reintroduced in three
more helpers (A41) and a fourth (A43) because each new plan wrote its own setup helper
from scratch instead of reusing an audited one. One fix, applied centrally, would have
prevented all five occurrences.

### P5 — Phase 4 + Phase 5: ban non-deterministic and vacuous assertion patterns (prevents #3, #7)

Anchor (Phase 4, "Instructions to the agent"):
> "every correctness criterion gets a recognisably-named test; where a plan is
> ambiguous, take the best reading and file a plan-change request rather than inventing
> semantics"

Add two blocklist items to the Phase 4 instructions, and mirror them as Phase 5 audit
checks:
> - **No tie-dependent assertions.** Any `ORDER BY … LIMIT 1` (or language equivalent —
>   sort-then-take-first) assertion must either include a column set that provably makes
>   the row unique, or the test fixture must guarantee uniqueness on the sort key(s)
>   used. If uniqueness can't be proven, the test must assert on the *set* of tied rows,
>   not a single arbitrary one. No assertion may depend on wall-clock time or on
>   iteration order of an explicitly-unordered structure (hash map/set).
> - **No vacuous assertions.** Forbidden as the *sole* check for a criterion: "runs
>   without error," `expect_type()`/`is.list()`-only checks, "succeeds even if empty."
>   Every test asserts the specific value(s)/row(s)/count the plan specifies, not merely
>   that some result of the right shape came back.

Phase 5's audit prompt should include: "grep the suite for `ORDER BY.*LIMIT 1` and
`expect_type\(` (or the language equivalent) and manually verify each hit against the
two rules above" — this is mechanical enough to hand to the same read-only auditor
without extra cost.

### P6 — Phase 4: NA/empty-input discipline for the *test code itself* (prevents #5, contributes to #1a)

Add to Phase 4 instructions:
> Any assertion or fixture-filter that indexes/subsets by equality on a nullable column
> must be NA-safe (e.g. in R, `!is.na(df$col) & df$col == x`, never a bare
> `df$col == x`) — the test harness is code and inherits the same NA-safety obligations
> as production code. Additionally, for any module that accepts an optional/nullable key
> (feature id, join key, lookup key), Phase 4 must include at least one test that passes
> an explicit `NA`/`NULL`/missing value for that key and asserts the module's documented
> behavior (typically: excluded from the match, not silently coerced into a spurious
> match).

This targets A43 directly (the NA-unsafe `states$filename == "x"` filter) and would
also have forced a direct test of A44.1's actual defect (`.rc_feature_candidates(NA)`)
at the unit level, independent of whether the Phase 4(P1) seam test also caught it.

### P7 — Phase 7: add a cheap, targeted mutation-testing spot-check (prevents residual #7, backstops P5)

Anchor:
> "Goals, in priority order: requirements coverage (spot-check that coverage-map claims
> are true and tests aren't weaker than the plan); silent deviations; scope creep;
> atomicity/failure-path tracing..."

Add a new goal:
> **Targeted mutation spot-check.** For the 2–3 modules the plans themselves flag as
> highest-risk (typically anything doing matching/reconciliation, joins, or
> serialization), hand-introduce one small mutation each (flip a comparison operator,
> remove a null-guard, swap `==` for an NA-unsafe equivalent) and confirm the existing
> suite fails. A mutation the suite doesn't catch is evidence of a weak-assertion defect
> (class #7) that coverage-map inspection alone won't surface, since the coverage map
> only proves a test *exists*, not that it *discriminates*. This is a few minutes of
> read-mostly, terse-output work — well inside this phase's existing cost profile.

This operationalizes mutation testing within the existing cost model (expensive model,
tiny writes, terse verdict) rather than requiring a full mutation-testing tool/pipeline.

### P8 — Phase 7: name serialization/boundary-crossing fidelity as its own audit category (prevents #1c specifically)

Anchor:
> "atomicity/failure-path tracing (throw-after-partial-write is where real defects
> hide)"

Extend to:
> atomicity/failure-path tracing (throw-after-partial-write is where real defects hide)
> **and boundary-crossing data fidelity** (timezone/locale conversions, encoding, and
> type coercion at every serialize/deserialize call or driver boundary — a value can be
> correct in memory and wrong the instant it crosses a process/format boundary; trace
> every `write`/`read` pair through the real driver, not the in-memory representation).

The current "atomicity" framing would not have prompted an auditor to look for A44.3
specifically (nothing throws, nothing partially writes — the value is simply wrong after
a silent timezone conversion); it needs its own named category.

---

## 4. Other skill weaknesses (non-testing)

- **CONTRACT digest granularity is under-specified for seams.** "One-page... pinned
  module APIs, file layout, conventions, gates" doesn't require a *field-level* schema
  per producer→consumer boundary. A44.2 (dropped `feature_raw`) is exactly a field-level
  contract violation the digest, as currently scoped, would not have caught even if read
  carefully. Recommend the digest include a small seam table: producer function →
  consumer function → required fields (name, nullability, source). This is cheap (a
  table, not prose) and gives Phase 4's new seam tests (P1) something concrete to assert
  against.

- **Circuit breaker tracks per-item attempts, not failure *signatures* across items.**
  "If the same failure survives 3 remediation attempts... stop... escalate" is scoped to
  one item. The withr bug (A38/A41/A43) never tripped this because each occurrence was a
  *different* file failing *once or twice*, not the same file failing three times — the
  systemic pattern was invisible to a per-file counter. Recommend tracking failure
  *signatures* (e.g. normalized error message / stack shape) across workers; when the
  same signature recurs on ≥2 different files, escalate immediately as a harness-level
  defect rather than treating each as independent local noise, regardless of per-file
  attempt count.

- **No "generalize recurring defects" protocol.** None of the cross-cutting protocols
  ([CHECKPOINT], [SALVAGE], [CONTEXT SHIELD], [MEASURE TWICE], [NO SILENT DEVIATION])
  cover the case where the *same* defect class is independently rediscovered and
  independently patched multiple times (exactly what happened with A38→A41→A43).
  Recommend a new protocol, e.g. **[GENERALIZE]**: when a defect signature recurs ≥2
  times across files, the fix is not "patch this file" but "fix the shared
  helper/pattern and grep the whole tree for the same anti-pattern" — this is what
  eventually happened manually here (A41's note "same mechanical fix applied to the
  commit/ingest helpers") but only after three separate discoveries; making it a named
  rule would trigger the grep on the *first* recurrence instead of the third.

- **No environment-reproducibility pinning for the gates.** A44.3 (the timezone bug) is
  the textbook case of a defect that's invisible unless the test *environment's*
  timezone differs from the value's source timezone — if CI/the dev box happens to run
  in UTC, `tz="Australia/Sydney"` vs `tz="UTC"` can look identical for some inputs.
  Recommend Phase 6/9 gates explicitly run the suite (or at least the persistence-layer
  tests) under a non-UTC `TZ` environment variable at least once, precisely because
  "works in the timezone the developer/CI happens to be in" is a known trap class. The
  "Gates" section of CONTRACT.md already runs the e2e idempotency test twice for a
  different reason (mtime-vs-hash) — the same instinct (run under a perturbed
  environment, not just twice identically) should extend to timezone.

- **Fixture realism is a Phase-9-discovered lesson, not a Phase-2/4 default.** This
  project's own memory (`real-corpus-and-fixtures.md`) records that synthetic fixtures
  masked two real defects (A34 crosstab layout, A35 latin-1 encoding) and that the fix
  was adopting anonymized real files as the *primary* fixtures — a decision made
  mid-project, overriding an earlier contract clause (A3). SKILL.md currently says
  nothing about fixture provenance. Recommend Phase 2 (or Phase 4's instructions)
  explicitly ask: "does real-world sample data exist for this domain? If so, Phase 4's
  seam/integration tests (P1 above) should run against anonymized real data, not only
  synthetic fixtures the writing agent invents" — turning this project's
  hard-won, mid-course correction into a standing default for the next one.

- **Phase 4 is a single write with no self-check gate.** "Full tests... one write" is
  correct as cost-model doctrine (don't have Sonnet draft then have Opus rewrite), but
  it currently stops at "files land on disk as written" with no requirement that the
  *writing* agent itself run `test_dir()`/`pytest`/etc. once before handing off to
  Phase 5. Confirming red-for-the-right-reason (P2) is currently entirely Phase 5's
  job; pushing a first pass of it into Phase 4 (agent runs its own suite, reports which
  files fail to *collect* vs fail on missing-export) would catch A40/A42-class bugs one
  phase earlier, before they cost the expensive auditor's attention at all.

- **Sequencing has no walking-skeleton checkpoint for the highest-risk seam.** Phase 1
  spikes de-risk *architecture* unknowns; nothing de-risks whether the CONTRACT digest's
  seam contract (the exact shape of data crossing the riskiest boundary) is actually
  correct before Phase 4 writes a full suite against it. This is a bigger process change
  than the others above and may not be worth it for small projects, but for a plan set
  where one seam is flagged as highest-risk (e.g. "the reconciler's matching semantics"
  here), a thin real-code spike through just that seam, before full Phase 4 writing,
  would validate the digest's seam table (see CONTRACT-digest recommendation above)
  empirically rather than by inspection alone.

---

## Sources

- [The Practical Test Pyramid — Martin Fowler](https://martinfowler.com/articles/practical-test-pyramid.html)
- [Software Engineering at Google, ch. 11 (Testing Overview)](https://abseil.io/resources/swe-book/html/ch11.html)
- [Testing on the Toilet: What Makes a Good End-to-End Test?](https://testing.googleblog.com/2016/09/testing-on-toilet-what-makes-good-end.html)
- [Google Testing Blog: Flaky Tests at Google and How We Mitigate Them](https://testing.googleblog.com/2016/05/flaky-tests-at-google-and-how-we.html)
- [Google Testing Blog: To Assert or Not To Assert](https://testing.googleblog.com/2009/02/to-assert-or-not-to-assert.html)
- [Reduction of Test Re-runs by Prioritizing Potential Order Dependent Flaky Tests (arXiv)](https://arxiv.org/html/2510.26171)
- [Pactflow: Contract Testing vs Integration Testing](https://pactflow.io/blog/contract-testing-vs-integration-testing/)
- [Don't Mock What You Don't Own](https://dev.to/satansdeer/dont-mock-what-you-dont-own-cd6)
- [Hypothesis documentation (property-based testing)](https://hypothesis.readthedocs.io/)
- [Mutation Testing with Pitest](https://www.triology.de/en/blog/mutation-testing-with-pitest)
- [testsmells.org — Test Smell Types](https://testsmells.org/pages/testsmells.html)
- [R-bloggers: Subsetting in the presence of NAs](https://www.r-bloggers.com/2018/10/subsetting-in-the-presence-of-nas/)
- [testthat: Test fixtures (withr scoped-cleanup idiom)](https://testthat.r-lib.org/articles/test-fixtures.html)
- [obra/superpowers: test-driven-development](https://skills.sh/obra/superpowers/test-driven-development)
- Primary evidence: `dev/plans/CONTRACT.md` adjudications A34–A44 (this repository);
  `real-corpus-and-fixtures.md` (project memory); `dev/plans/PLAN-10-e2e-corpus.md`.
