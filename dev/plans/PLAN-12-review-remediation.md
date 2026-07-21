# PLAN 12 — whole-package code-review remediation

**Owns:** no new `R/` module — this plan is a set of adjudicated fixes to landed
code. `dev/CODE-REVIEW-2026-07-19-TRIAGE.md` is its rationale of record.
**Amends (adjudicated cross-plan edits, not ownership transfers — like A52):**
`R/router.R`, `R/ir.R` (03); `R/adapter-crosstab.R` (05); `R/mutate.R`,
`R/commit.R`, `R/ingest.R`, `R/archive.R`, `R/snapshot.R` (09); `R/db-schema.R`,
`R/config.R` (01); `R/adapter-registry.R` (03); plus regression tests in the
matching `test-<module>.R` files, and one fixture each for T-2 M1 / M7.
**Depends on:** plans 01–10 landed and green. **Independent of PLAN-11** — these
touch functions PLAN-11 does *not* rewrite (the entangled findings F1–F5/F9/T-1
went into PLAN-11 instead; see its "Whole-package code-review fold-ins" section).

<!-- block: B-12-why -->
## Why

The 2026-07-19 whole-package review (`dev/CODE-REVIEW-2026-07-19.md`) found, on
the green surface, a set of defects in landed code that PLAN-11 does not touch.
They are too many for the A44/A46 "one delta + one A-log line" precedent to stay
legible, and several want a real test-first pass, so they are collected here as a
proper tdd-plan plan (R-12.x criteria → Phase-4 tests → Phase-6 impl → Phase-7
audit). Each is validated against source in the triage doc; nothing here is a
speculative cleanup.

Two findings carry a genuine **domain/policy decision** that is the user's to make
(`⚑`); they are pinned as requirements *and* filed in `PLAN-CHANGE-REQUESTS.md`,
and must not be resolved silently.

<!-- block: B-12-ordering-vs-plan-11 -->
## Ordering vs PLAN-11

Mostly independent — but **two requirements are NOT, and the manifest encodes the
dependency the prose below used to deny**: **R-12.13** must be keyed on
`uuid_feature_alias`, and **R-12.16** says explicitly "do this after R-11.3/R-11.4
land". Both therefore land AFTER PLAN-11's reconcile work (`after = ["P11-reconcile"]`
in `dev/tdd-run/manifest.toml`). Everything else is genuinely independent:
R-12.1 (router), R-12.3/R-12.8 (crosstab),
R-12.4/R-12.5/R-12.6 (mutate/ir/archive/snapshot) share no functions with
PLAN-11. R-12.7/R-12.13 touch `ingest.R`/`commit.R` regions adjacent to PLAN-11's
edits but not the same functions; land whichever plan is ready and rebase the
other's tests. Prefer landing R-12.1 (poison-run aborts) early — it is a
data-availability bug on the very first real ingest.

---

<!-- block: B-12.1 -->
## R-12.1 Router validates every `match()` return; contained registry lookup (F6)

`route_files()` never validates what an adapter `match()` returns. A `match()`
that **returns** (not throws) `NA` — or any value outside the tier vocabulary —
makes `claims[[id]] = NA` (`router.R:121`); `names(claims)[claims == t]`
(`:127`) then yields a length-1 `NA` "winner", so the file is recorded
`state = "claimed", adapter = NA`. `.ig_parse_claimed()` then evaluates
`adapter_registry()[[NA]]` (`ingest.R:65`) **outside** its `tryCatch` (`:68`) →
subscript error → the whole `ingest_dir()` run aborts. `register_adapter()` is
exported, so third-party adapters that misbehave are in scope (A27's contract is
per-file containment).

**Fix:**
- in `.st_route_one_file()`, validate each adapter's `match(fm)` return: it must
  be a length-1, non-NA string in `c("exact","format","fallback","no")`. Anything
  else is treated exactly like a thrown `match()` — that file → `state="failed"`
  with a message naming the adapter and the bad value; routing of other files
  continues.
- belt-and-braces: move the `adapter_registry()[[adapter_id]]` lookup in
  `.ig_parse_claimed()` **inside** the per-file `tryCatch`, so a stray bad
  `adapter_id` there fails that file, not the run.

Criteria: an adapter whose `match()` returns `NA` → that file `failed` (reason
names the adapter), other files route normally, the run completes; an adapter
returning `"weird"` → same; a `match()` that *throws* still → `failed` (unchanged,
regression); an ingest run containing one such file still commits the good files.
Tests in `test-router.R` + `test-ingest.R`.

<!-- block: B-12.2 -->
## R-12.2 Per-event containment in the ingest loop (F7) ✅ DECIDED: contain, loudly

`ingest_dir()` contains adapter *parse* crashes per file (R-9.5), but
`reconcile_event()`/`commit_event()` run **bare** in the loop (`ingest.R:121-152`).
Any per-event failure — an archive-copy failure, a zero-row registry lookup
(`reconcile.R:287-288` does not guard `analyte_row$units[[1]]`), a payload glitch
— kills the run for every event routed after it. Committed events stay committed
(own transactions), so a re-run continues, but a single always-failing event
permanently blocks everything behind it in the run.

**DECIDED (user 2026-07-19): contain, loudly** — extend R-9.5's parse-only
containment to reconcile+commit, but keep the systemic-failure signal.
**Fix:**
- wrap the per-event `reconcile_event()` + `commit_event()` in `tryCatch`; on
  error, mark that event's **kept** files `failed` with the message (leave
  non-kept/`ignored` files alone), emit a `cli::cli_warn` naming the event and
  cause, and continue to the next event;
- add an `events_failed` count to the report (and the per-event outcome tally);
- **if *every* event fails**, abort the run `sampletidy_error` after the loop
  (a total wipe-out is a systemic problem — schema/disk/DB — not a per-event
  fault, and must surface loudly, not as a quiet all-`failed` report).

CONTRACT A60 (now firm, not conditional).

Criteria: a run with one event that throws in reconcile still commits the other
events; the poison event's kept files are `failed` with the message and it is
counted in `events_failed`; a `cli_warn` is emitted for it; a re-run over the same
dir is a clean no-op on the already-committed events and re-attempts the failed
one; **a run where every event throws aborts `sampletidy_error`** (not a silent
all-`failed` report). Test in `test-ingest.R`.

<!-- block: B-12.3 -->
## R-12.3 Crosstab: no silent drops (F8)

CONTRACT: "Every function that skips/drops a row must return counts of what it
skipped and why." Two crosstab paths violate it:
- **Unsupported-section skip** (`adapter-crosstab.R:386-393`): on a foreign
  `…Matrix:` marker, every following row is `next`-ed with no `skipped` entry and
  no warning until the next recognised dialect marker. If real data rows followed
  a foreign block *without* a fresh marker, they would vanish untraced.
- **Missing `ALS Sample Number` row** (`:501-509`): `sample_cols` stays empty, so
  every analyte row is misclassified as a method-group row
  (`has_sample_values` is FALSE with zero sample columns) and the whole section
  emits zero results / zero skips / zero warnings — a label typo blanks a file.

**Fix:** record one `report$warnings` entry (with the row range) when entering an
unsupported section; and warn when an analyte header is reached with
`length(sample_cols) == 0` (naming the section). Neither changes what is parsed —
they make the silence loud.

Criteria: a fixture with a foreign section followed by (would-be) data rows
without a fresh marker → a `report$warnings` entry naming the row range; a
section whose `ALS Sample Number` label is misspelled → a warning, not a silent
zero-row section; the existing two-section (WATER+SOIL) fixture still parses
identically (no new spurious warning). Tests in `test-adapter-crosstab.R`.

<!-- block: B-12.4 -->
## R-12.4 Checked file operations in archive/snapshot (F10)

`archive_file()` (`archive.R:52`) ignores `file.copy()`'s return: a failed copy
(permissions, missing `archive_dir`, disk full) still inserts the `asset` row and
the commit "succeeds" with the archive silently missing. Same pattern in
`snapshot_db()` (`snapshot.R:28,33`): unchecked `file.copy`/`file.rename` mean a
missing `snapshot_dir` yields a "successful" run whose returned snapshot path
does not exist — and R-9.6 then treats the snapshot as having happened (and may
proceed to `remove_ingested`).

**Fix:** check both return values; on FALSE, `cli::cli_abort(class =
"sampletidy_error")` naming the source and destination. In `archive_file()` this
aborts before the `asset` insert (inside the commit transaction, so it rolls
back). In `snapshot_db()` it aborts before returning a path.

Criteria: `archive_file()` into a non-existent `archive_dir` aborts
`sampletidy_error` and writes **no** `asset` row; `snapshot_db()` into a
non-existent `snapshot_dir` aborts and returns no path; the happy paths are
unchanged. Tests in `test-archive.R` + `test-snapshot.R`.

<!-- block: B-12.5 -->
## R-12.5 IR constructors validate before subsetting (F11)

`ir_results()`/`ir_samples()` subset to the pinned columns **before** calling
`ir_validate()` (`ir.R:74-77`), so `ir_validate()`'s extra-column check is dead
on the constructor path (a misspelled optional argument is silently dropped) and
a missing required column throws a raw vctrs subscript error, not
`sampletidy_ir_error`.

**Fix:** validate the assembled tibble **before** the column subset (or drop the
subset and let validation enforce exact columns).

Criteria: `ir_results(feature_raw = "x", typpo = 1)` (extra/misspelled column)
aborts `sampletidy_ir_error` naming the unexpected column, not a silent drop; a
call omitting a required column aborts `sampletidy_ir_error`, not a vctrs
subscript error; the zero-arg prototype and a valid full-column call are
unchanged. Tests in `test-ir.R`.

<!-- block: B-12.6 -->
## R-12.6 Mutation-layer correctness (F12)

Three defects in `mutate.R`:
- `db_update()` writes a `change_log` row for **every** field in `changes`, with
  no old≠new comparison (`:243-259`) — logging phantom "updates" of unchanged
  fields.
- `db_delete()` on a nonexistent uuid runs a 0-row DELETE but writes a delete
  `change_log` row anyway (`:288-301`) — a phantom delete record.
- `DBI::dbCommit()` sits **outside** the `tryCatch` in `db_transaction()`
  (`:118`) — a commit-time error escapes unwrapped, with no rollback attempt.

**Fix:** in `db_update()`, skip a field whose `as.character(new)` equals
`as.character(old)` (no UPDATE, no log row); in `db_delete()`, capture
`dbExecute()`'s affected-row count and, when zero, **abort `sampletidy_error`**
(**PINNED 2026-07-22, Phase-3 D2 — CONTRACT A72**; matches `db_update()`'s "no row"
behaviour). Rationale: the whole point of R-12.6 is to stop the mutation layer writing
records for things that did not happen, and a silent no-op delete is that same defect
wearing the other hat. **PLAN-14 R-14.1 depends on this ruling** — it deletes an analyte
row and must stay idempotent, so it carries an explicit existence pre-check; move `dbCommit()` inside the `tryCatch` so a commit error rolls back
and re-throws as `sampletidy_error`.

Criteria: `db_update()` with a changes list where one field equals its current
value writes a `change_log` row only for the *changed* field(s); `db_delete()` on
a nonexistent uuid **aborts `sampletidy_error`** and writes no delete log row (A72);
a forced commit failure rolls back and aborts `sampletidy_error`, leaving no
partial write; existing `test-mutate.R` assertions stay green. Tests in
`test-mutate.R`.

<!-- block: B-12.7 -->
## R-12.7 Ingest report uses terminal file states (F13)

`ingest_report$files_by_state` is built from `routed$state` (`ingest.R:222`) —
the route-time state — so files this run committed/archived report as
`"claimed"`. R-9.5 says "files by terminal state".

**Fix:** in `.ig_build_report()`, re-query `ingest_file.state` for the routed
hashes and tabulate those.

Criteria: after a run that commits an event, `files_by_state` shows its files as
`archived` (or `committed`), not `claimed`; a `needs_review`-only event shows
`needs_review`. (**The dry-run clause is struck, Phase-3 D12**: it depended on
`dry_run` state persistence, which this plan's own "Open / deferred" section lists as a
known-present defect with no action here. A criterion may not rest on a defect the same
plan declines to fix.) Test in
`test-ingest.R` (or `test-e2e-pipeline.R`).

<!-- block: B-12.8 -->
## R-12.8 Crosstab `match()` robustness (F14)

The crosstab `match()` peeks `file_meta()`'s first 2048 bytes
(`adapter-crosstab.R:125-131`): a very wide crosstab whose `Workgroup:` row
starts past 2 KiB silently unclaims, and a UTF-8 BOM on row 1 defeats
`^Matrix:` (ESdat strips BOMs; the crosstab path does not).

**Fix (hardening):** read the first *N lines* of the file for the match peek
rather than a fixed byte count, and BOM-strip line 1.

Criteria: a crafted crosstab fixture whose dialect marker sits past 2 KiB still
`match()`es; a BOM-prefixed crosstab still `match()`es; the SpreadsheetML `.XLS`
still returns `"no"` (A37, regression). Tests in `test-adapter-crosstab.R`.

<!-- block: B-12.9 -->
## R-12.9 `ingest_file_upsert()` does not clobber on re-sight (F15)

`ingest_file_upsert()` unconditionally overwrites `filename`/`size` on re-sight
(`db-schema.R:184-188`). All current callers pass both, but a later call taking
the defaults would null a real filename.

**Fix:** COALESCE-guard the update (keep the existing non-NULL value when the new
one is NA), or drop the defaults so the columns are always required.

Criteria: a re-upsert with `filename = NA` leaves the stored filename intact; a
re-upsert with a real filename updates it; `path_first_seen` is still set once
(A21, regression). Test in `test-db-schema.R`.

<!-- block: B-12.10 -->
## R-12.10 Convention/UX polish (F17, F18)

- **F17 (doc):** the stale comment at `db-schema.R:126-130` ("See final report
  for this discrepancy") refers to a report that no longer exists; the discrepancy
  was adjudicated as A31. Rewrite it to cite A31.
- **F18 (UX):** `register_builtin_adapters()` emits four "Overwriting existing
  adapter registration" informs on every `ingest_dir()` run
  (`adapter-registry.R:53`, via A33's defensive re-registration). Suppress the
  inform when the id being overwritten is a built-in re-registering **itself**
  (same adapter object/id); keep it for a genuine third-party clobber.

Criteria: `ingest_dir()` produces no "Overwriting…" informs on a clean run;
registering a third-party adapter over a built-in id still informs; the comment
cites A31. Tests: a `testthat::expect_no_message()`-style check around
`register_builtin_adapters()` in `test-adapter-registry.R`; F17 is doc-only (no
test).

<!-- block: B-12.11 -->
## R-12.11 `st_config()` env-var typing (F16) ✅ DECIDED: string-only + guard (low)

`st_config()` env-var values are always strings — fine for paths and for
`remove_ingested` (coerced), but `SAMPLETIDY_FIELD_ANALYTES` would yield a single
string, silently shrinking the ACIRL allowlist to one entry.

**DECIDED (user 2026-07-19): string-only + a guard.** Env-var overrides are
documented as **string-only**; a **list-valued** config key must be set in code
via `st_config(key, value)`, never via env. **Fix:** maintain the small set of
known list-valued keys (today: `field_analytes`); when `st_config()` would source
one of them from an env var, `cli::cli_abort(class = "sampletidy_error")` telling
the caller to set it in code (fail loud, not silent-shrink). Document the
string-only contract in `st_config()`'s docs. (Env-configurable list keys via a
separator convention stay an additive follow-up if a real need appears.)

Criteria: reading `field_analytes` with `SAMPLETIDY_FIELD_ANALYTES` set aborts
`sampletidy_error` (no silent one-entry allowlist); a scalar key still reads from
its env var unchanged; `field_analytes` set via `st_config("field_analytes", c(...))`
in code round-trips as a vector. Test in `test-config.R`.

<!-- block: B-12.12 -->
## R-12.12 `sample.organisation` provenance (F19) (low)

`.ct_resolve_samples()`/`.ct_find_or_create_sample()` always write the adapter org
as `sample.organisation` (`commit.R:116,161`); R-9.2 step 2 says "organisation =
sampler org if known else org". For ESdat the collector arguably is not ALS. Low
impact; **defer to the datetime-convention revisit** unless trivially fixable
alongside R-12.7. Recorded here so it is not lost; no criterion pinned yet.

<!-- block: B-12.13 -->
## R-12.13 Within-batch duplicate guard before commit (A-7)

R-8.6 dedups across *methods*; two identical-key rows from the **same** method in
one batch (a lab re-listing a determination; historically F2's mis-dated visits)
each pass the three-way (which only consults the DB) and commit as two analyses
on one sample. PLAN-11 R-11.15 removes the ACIRL trigger, but the general case
remains.

**Fix:** a `duplicated()` check over `(uuid_feature/alias, sample_date,
uuid_analyte, uuid_lab)` in `clean` before commit — **route exact dupes to review.
Do NOT collapse** (pinned 2026-07-22, Phase-3 D13): A54's principle is that the
pipeline records the question and never invents the answer, and collapsing silently
picks one of two rows a human has not compared. Coordinate the key with PLAN-11's alias re-keying if that
lands first (use `uuid_feature_alias`).

Criteria: two identical-key same-method rows in one batch → one committed
analysis + one review/skip entry, not two analyses on one sample; distinct-key
rows are unaffected; interacts correctly with R-8.6 (cross-method dedup runs
first). Test in `test-reconcile.R` or `test-commit.R`.

<!-- block: B-12.14 -->
## R-12.14 Matrix-not-in-identity-key — documented limitation (A-6)

A two-section (WATER+SOIL) crosstab measuring the same analyte at one
feature+date+method yields two rows whose only difference is section matrix; they
land on the **same** sample as two analyses distinguishable by nothing (matrix is
in neither the sample find-or-create key nor A45's analysis key). Rare
(multi-section files are legacy per A34) and the model cannot represent it.

**Fix:** document as a known limitation (in `dev/HANDOVER.md` and a comment at the
sample/analysis identity sites); do **not** silently pick one. Revisit "matrix in
the identity key" when the datetime convention is revisited. Doc-only; no test.

<!-- block: B-12.15 -->
## R-12.15 Test-suite strength (T-2 M1, T-2 M7, T-1 sweep)

- **T-2 M1** — removing assemble's A44.2 `is.na()` feature_raw guard SURVIVES the
  suite: no test distinguishes the guarded from the unguarded fill (in the
  fixtures the joined sample's feature always equals the row's own feature).
  **Add** a `test-assemble.R` case where a crosstab row's inline `feature_raw`
  differs from a joinable sample row's, asserting the inline value wins.
- **T-2 M7** — disabling `.st_esdat_check_parseable`'s zero-row abort SURVIVES:
  the CORRUPT fixture aborts through a different path, so the A35 "data lines but
  zero parsed rows" structural check has no test. **Add** a fixture (or a
  temp-file unit test) that actually produces the readr swallow-to-zero-rows
  behaviour, asserting the abort.
- **T-1 sweep** — the R-10.2 e2e vacuous gate is fixed in PLAN-11; **here**, grep
  the whole suite for the same anti-pattern: `>= 0`, `expect_type(<report>,
  "list")`, and assertions that cannot distinguish success from no-op. Fix each
  found (or justify it), and record the finding in `dev/tdd-skill-improvements.md`
  (it is the fifth instance — feeds the skill's "a gate that cannot fail is worse
  than no gate" lesson).

Criteria: the M1 mutation is now KILLED (the new assemble test fails if the guard
is removed); the M7 mutation is now KILLED; the suite-wide grep returns no
un-justified vacuous assertion.

<!-- block: B-12.17 -->
## R-12.17 Archive layout: match the real `processed/` convention (A70)

`archive_file()` (`R/archive.R:50-52`) writes
`file.copy(path, file.path(st_config("archive_dir"), new_uuid))` — an
**extensionless file** named `<asset uuid>` — on A13's stated grounds that this
"matches existing `processed/`". **It does not.** Measured against the real
archive (`…/assets/processed`, 2026-07-22): **1,565 directories** named
`<asset uuid>`, each holding the original file under its real name
(`08f1555c-18be-4167-a051-ba4f9fedea09/ES2415638_0_XTAB.csv`), versus **33**
extensionless files. Directory-per-asset is the convention; sampleTidy writes
the minority shape.

Why it matters beyond tidiness: A13 says archiving copies **every file of a
committed event** to `<archive_dir>/<asset uuid>`. One extensionless file per
uuid can hold exactly one; a directory holds the set. The current shape cannot
express A13's own requirement. And a mixed archive forces every consumer
(including `ingest_dir()`'s own "archive copy byte-equals the input" check in
plan-10 R-10.2) to handle two layouts.

**Fix:** write `<archive_dir>/<asset uuid>/<basename(path)>`, creating the
directory; keep the original filename. Read paths accordingly. Nothing is
stranded by the change — sampleTidy has not written to the real archive yet, and
the 33 legacy extensionless files are read-only history.

Criteria: `archive_file()` creates `<archive_dir>/<uuid>/<original name>` and
the copy byte-equals the source; two files archived under one asset uuid both
land, side by side (A13's "every file", currently unsatisfiable); the plan-10
R-10.2 provenance assertion is updated to the new path shape and still passes;
a pre-existing legacy extensionless `<uuid>` file is left untouched. Tests in
`test-archive.R`; coordinate with R-12.4, which touches the same `file.copy`
call. CONTRACT A13's layout clause is re-pinned on landing.

<!-- block: B-12.16 -->
## R-12.16 Reconciler hot-path precompute (PERF-1, PERF-2) — optional

Not load-bearing at fixture scale, but the reconciler is the corpus hot path:
- **PERF-1:** `.rc_feature_candidates()` / `.rc_lab_method_candidates()`
  re-run `.rc_key()` (an 11-pattern gsub chain) over **every** registry name for
  **every** result row (`reconcile.R:77-78,162`). Precompute the keyed name
  columns once in `.rc_load_registry()`. (Interacts with PLAN-11's `.rc_key`
  change — do this **after** R-11.3/R-11.4 land, keyed on the new `.rc_key`.)
- **PERF-2:** `.rc_recorded_revision()` re-queries per conflicting row
  (`reconcile.R:549`). Cache per `(event, work_order)`.

Criteria: behaviour-identical (existing `test-reconcile.R` green, unchanged
outputs); a micro-benchmark over the real corpus shows the per-row `.rc_key`
normalisation gone. Optional — land only if corpus timing warrants.

---

<!-- block: B-12-fixtures -->
## Fixtures

- **M1:** extend an existing crosstab/ESdat assemble fixture (or add a small one)
  so one result row's inline `feature_raw` differs from its joinable sample's —
  synthetic, per A3.
- **M7:** an ESdat fixture (or temp-file unit input) whose readr read swallows all
  data rows to zero (the behaviour A35's structural check describes), documented
  in `fixtures/esdat/README.md`.
- **R-12.8:** a crafted crosstab whose dialect marker sits past 2 KiB, and a
  BOM-prefixed crosstab — both synthetic, documented in
  `fixtures/crosstab/README.md`.
- All other requirements reuse existing fixtures or build inputs in-test.

<!-- block: B-12-gates -->
## Gates

- Per-plan: `testthat::test_file()` green for every amended `test-<module>.R`.
- Full `devtools::test()` green; `devtools::check()` no new errors/warnings
  (A47's non-portable-fixture WARNING is pre-existing).
- Plan-10 e2e green, including the idempotency run twice in a row.
- The R-9.1 direct-write lint stays clean.
- Order-shuffled run agrees with default order.
- **Mutation re-check:** M1 and M7 now KILLED (Phase-7a spot-check).

<!-- block: B-12-contract-amendments-this-plan -->
## CONTRACT amendments this plan requires (to be adjudicated on landing)

- **A59** — adapter `match()` contract: `match(fm)` must return a length-1
  non-NA string in `c("exact","format","fallback","no")`; the router treats any
  other return as a per-file `failed` (F6). Third-party adapters are bound by
  this.
- **A60** — ingest containment (DECIDED, user 2026-07-19): per-event
  reconcile/commit failures are contained per-event (event's kept files `failed`,
  `cli_warn`, `events_failed` counted, run continues), extending R-9.5's
  parse-only containment; but a run where **every** event fails aborts
  `sampletidy_error` (systemic-failure signal). (F7 / R-12.2.)
- **A61** — file operations that back a persisted record (`archive_file`'s copy,
  `snapshot_db`'s copy/rename) must be checked and abort `sampletidy_error` on
  failure; a record is never written for a file operation that did not happen
  (F10).

<!-- block: B-12-open-deferred -->
## Open / deferred (from the review, no action this plan)

- The five "known issues confirmed present" (dry_run state persistence; orphan
  project `name = NA`; `sample.datetime` UTC-shifted wall clock; SpreadsheetML
  `.XLS` unclaimed by design; OneDrive hydration). The OneDrive loud-fail
  `corpus_files()` hydration guard is "still worth doing" — pick up as a small
  separate item if corpus runs continue to flake.
- PERF-3..6 (double hashing; ESdat triple header read; per-cell tibble
  construction; per-result `which()` scans) — fixture-scale only; revisit if
  corpus timing warrants.
