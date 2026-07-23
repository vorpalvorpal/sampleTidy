# Plan change requests / ambiguities

Append-only log of ambiguities found while writing tests against the plans.
Never overwrite; each worker appends its own section. Format:
`## [worker-tag] R-x.y — <short title>` followed by the detail.

## [pipeline-tests] R-9.2/R-9.3 — `asset` table missing from `seed_db()`

`tests/testthat/helper-db.R` (`seed_db()`, owned by the core-tests agent per
`dev/plans/FIXTURES.md` "Seed DB") creates the CONTRACT core tables that
FIXTURES.md pins *rows* for: `feature`, `feature_mask`, `analyte`,
`lab_method`, `project`, `sample`, `analysis`. FIXTURES.md's "Seed DB"
section never mentions `asset`, even though `asset` is part of CONTRACT's
"Existing DB schema" and plan 09 (`archive_file()`, `commit_event()`'s
archival step, provenance change_log rows) needs a real `asset` table to
write into.

Resolution taken so the plan-09/10 test suites aren't blocked: added
`ensure_test_asset_table(con)` to `tests/testthat/helper-corpus.R` (my one
owned helper file) — an idempotent `CREATE TABLE IF NOT EXISTS asset (...)`
matching the CONTRACT column list exactly. `test-archive.R`, `test-commit.R`,
`test-ingest.R` and the plan-10 e2e tests call it right after `seed_con()`.

Suggested upstream fix: have `seed_db()` create an empty `asset` table too
(no pinned rows needed — plan 09 tests populate it via `archive_file()`),
at which point `ensure_test_asset_table()` becomes a no-op and can be
deleted.

## [pipeline-tests] R-7.3/R-7.4 — assembly-stage review-marking interface not pinned

PLAN-07 R-7.3 ("an engineered datetime mismatch produces exactly one review
payload and does not block the rest of the event") and R-7.4 ("an engineered
non-NCP foreign row lands in review") both describe assembly-stage rows being
flagged "for review" — but the pinned event shape (R-7.5) has no `review`
field, only `report$skipped` (file-level skip reasons) and `report$warnings`
(chr). Reconcile (plan 08) is the stage that actually produces a `review`
tibble as an output (R-8's `list(clean, review, skipped, counts)`), so it's
unclear whether:

(a) assembly marks affected rows in-line on the joined `event$results` tibble
    (e.g. a `needs_review` lgl column + a payload column) which reconcile
    later folds into its own `review` output, or
(b) assembly itself exposes a `review`-shaped bucket not mentioned in R-7.5,
    or
(c) something else entirely.

`tests/testthat/test-assemble.R` assumes (a): a `needs_review` (lgl) column
on `event$results`, defaulting FALSE, set TRUE on the affected row(s). The
relevant tests assert on that column's presence/count with an informative
`expect_true(..., info = ...)` message rather than hard-coding a payload
shape, so a differently-shaped real implementation fails loudly with context
instead of silently. Please confirm or correct the interface — the two
affected tests are `"R-7.3: an engineered sample_datetime_raw mismatch..."`
and `"R-7.4: a non-NCP foreign-work-order row is flagged for review"` in
`test-assemble.R`.

## [pipeline-tests] R-7.3 — fallback-join "date part" side unclear when `results` carries no datetime field

R-7.3's fallback join key is "(feature_raw after squish/case-fold, date part
of sample_datetime_raw)" for rows lacking `lab_sample_id`. But
`sample_datetime_raw` is a `samples`-only column (DESIGN §4.2); the `results`
IR (§4.1) has no datetime field of its own pre-join, so it's unclear what the
"date part" on the *results* side of the fallback match is compared against
when a feature has more than one visit in the same event. The fallback-join
test in `test-assemble.R` (`"R-7.3: fallback join matches on feature_raw when
lab_sample_id is absent"`) only exercises the single-visit-per-feature case,
where matching reduces to `feature_raw` alone, to avoid asserting an
unspecified mechanism. If a feature can have multiple visits without
`lab_sample_id` in a single event, the disambiguation mechanism needs pinning
before that case can be tested.

## [pipeline-tests] R-7.1/R-7.4 — how a zero-row (metadata-only) parsed file is keyed for grouping

R-7.1 groups events by `work_order`, but a file like `Header.XML` (ESdat) or
an ACIRL front-page-only parse emits zero result/sample rows (PLAN-04 R-4.4),
so it carries no row-level `work_order` signal for `assemble_events()` to
group on. `test-assemble.R`'s "three files sharing a work order form one
event" test supplies **both** `meta$work_order_guess` and
`report$header$work_order` on the zero-row parsed entry to hedge against
either being the actual signal `assemble_events()` reads. Please confirm
which one (or both) plan-07's implementation actually consults.

## [pipeline-tests] R-10.2 — `v_measurement` view not created by the throwaway test schema

PLAN-10 R-10.2 asserts "`v_measurement` joins cleanly for every new analysis
(no orphan uuids)" but `v_measurement` is a live-DB view (CONTRACT: "views
v_measurement*, v_analyte_*, v_feature_*") that neither `ensure_schema()`
(ops tables only) nor `seed_db()`'s core-table DDL creates. `test-e2e-pipeline.R`
substitutes a manual equivalent (`analysis` LEFT JOIN `sample` LEFT JOIN
`feature`, asserting no NULL `uuid_feature`/`uuid_sample`) rather than
querying a view that won't exist in the test DB. If plan 09/10 wants the
literal view exercised, `seed_db()` (or a plan-09 migration) needs to create
it.

## [pipeline-tests] R-10.6(a) — `devtools::check()` gate not encoded as a testthat assertion

R-10.6 lists three package gates: (a) `devtools::check()` passes with no
ERROR/WARNING, (b) NAMESPACE exports equal the CONTRACT public API, (c)
DESCRIPTION Imports equal the CONTRACT-pinned set. (b) and (c) are
straightforward testthat assertions (`test-e2e-pipeline.R` covers both).
(a) is a whole-package, out-of-process CI/manual gate — running
`devtools::check()` from inside a testthat test is impractical (slow,
recursive: check() itself runs the test suite) and would need `rcmdcheck`,
which isn't in the CONTRACT-pinned Imports/Suggests list. Treated as a CI-level
gate outside the automated suite, not a `test_that()` — flagging per the
"not tested and why" requirement rather than silently dropping it.

## [pipeline-tests] R-7.2/R-8/R-9/R-10 — assembly `parsed` inputs built directly, not via real adapters/router

Following the explicit instruction for plan-08 tests ("construct it directly
with the pinned shape ... so plan-08 tests are independent of the
adapters"), `test-assemble.R` also builds its `parsed` (per-file IR) inputs
directly via `ir_results()`/`ir_samples()` using the pinned FIXTURES.md
values, rather than by routing the real esdat/crosstab/acirl fixture files
through `file_meta()`/`route_files()`/adapter `parse()`. This keeps
`test-assemble.R` decoupled from plans 04-06's implementation and fixture
landing order (crosstab/acirl fixtures aren't present in the repo yet at the
time of writing). `test-commit.R` similarly builds both the `event` (plan-07
shape) and `resolved` (plan-08 shape, R-8.8) objects directly rather than
running real `assemble_events()`/`reconcile_event()`, for the same
independence reason. The plan-09/10 **e2e** tests (`test-ingest.R`,
`test-e2e-pipeline.R`) do the opposite by design — they exercise the real
files/adapters/router end to end, since that integration is exactly what
they're chartered to test, and are expected to fail/be skipped-in-spirit
(not literally skipped — just red) until plans 04-06 land their fixtures and
production code.

## [pipeline-tests] R-9.1 — domain-helper signatures assumed to omit `con`

CONTRACT's pinned API line shows `correct_value(uuid_analysis, new_value,
reason, actor)` with **no** `con`/`db` argument at all, unlike
`db_append(con, table, df, actor, reason)` which lists `con` first.
`add_feature(...)`/`add_analyte()` are shown abbreviated (`...`) and
`add_project(name, type = "Work order", …)` also omits `con` from its shown
signature. `test-mutate.R` assumes all four domain helpers
(`add_feature()`, `add_analyte()`, `add_project()`, `correct_value()`)
resolve their own connection from `st_config("live_db")` (consistent with
DESIGN §9.3 framing them as human-callable, and with `correct_value`'s fully
-spelled, `con`-less signature being the one unambiguous example) rather
than taking an explicit `con` parameter. Tests point `st_config("live_db")`
at the throwaway seeded DB via `withr::local_options(list("sampletidy.live_db"
= path))` before calling them. If the real implementation instead takes an
explicit `con`, these four tests will fail on a signature mismatch rather
than a real defect — please confirm.

## [pipeline-tests] R-10.1 — "corrupted-ESdat fixture claimed by none" conflicts with the actual fixture + PLAN-04's own match() rule

PLAN-10 R-10.1 says the router matrix test should find "the corrupted-ESdat
fixture and cruft files ... claimed by none." But
`tests/testthat/fixtures/esdat/CORRUPT.ESDAT_XX0000000_0.Chemistry2e.CSV`
(built by the plan-04 test-writing agent) has an exact-matching Chemistry2e
header row - only a data-row byte is corrupted (a stray 0x80 byte). PLAN-04
R-4.1's own `match()` rule is header-only ("exact when ... the header row
equals one of the two pinned column lists"), so this fixture should be
claimed `exact`, not unclaimed - the corruption is designed to fail at
`parse()` time (R-9.5's adapter-crash criterion), not at `match()` time.
`test-e2e-pipeline.R`'s router-matrix test follows the concrete, testable
match() rule (treats CORRUPT as claimed exact like any Chemistry2e file) and
only asserts "claimed by none" for `random.csv`/`NOT_ESDAT.xml`
(PLAN-04's own R-4.1 "match no" fixtures). Flagging the prose conflict for
orchestrator adjudication.

## [pipeline-tests] R-10.3 — sighting semantics: per-scan vs per-(hash,path) log

PLAN-03 R-3.5's own bullet says "re-routing the same path is a no-op (state
unchanged, one new sighting)" - taken literally, every re-scan of any
already-terminal file logs a new `ingest_sighting` row, even for the exact
same path. But PLAN-10 R-10.3 explicitly says repeat-scans of an unchanged
(or touched) directory produce "zero deltas everywhere" for the second and
third runs, reserving "one new ingest_sighting" specifically for the
different-path/same-hash (copy/rename) case. These two readings conflict.
`test-e2e-pipeline.R`'s idempotency test follows the more specific/
authoritative PLAN-10 e2e statement: `ingest_sighting` is treated as deduped
by (hash, path) pair (a repeat scan of the identical path adds nothing; a
new path with the same hash adds exactly one row). Please confirm this
against the intended `ingest_sighting` semantics.

## [pipeline-tests] R-10.4 — the "_1_" revision fixture isn't in plan 05's own fixture list

FIXTURES.md's "Cross-plan expectations" pins a supersede e2e fixture pair:
`XX1234567_0_XTAB.csv` then `XX1234567_1_XTAB.csv` (T.S01 Fluoride changed to
`0.3 mg/L`). But PLAN-05's own "Fixtures" section only lists
`XX1234567_0_XTAB.csv`/`.XLS`, `XX1234567_0_ENMRG.CSV`, and
`ZZ9999999_0_XTAB.csv` - no `_1_` revision variant. Since fixture creation
under `tests/testthat/fixtures/crosstab/` is plan 05's ownership (not
plan 10's, per the CONTRACT file-layout table), `test-e2e-pipeline.R`'s
R-10.4 test references the pinned `XX1234567_1_XTAB.csv` path and asserts it
exists rather than creating it itself; that assertion will fail (a
legitimate, informative red) until whoever owns `fixtures/crosstab/` adds
this supplementary revision-1 file.

## [pipeline-tests] R-10.5 — a second, narrower skip for `SAMPLETIDY_CORPUS_DB`

The brief says `skip_if_no_corpus()` is "the ONLY permitted skip." R-10.5's
dry-run-against-a-real-DB-copy gate is additionally conditioned on
`SAMPLETIDY_CORPUS_DB` ("a temp copy of the real monitoring.duckdb if
SAMPLETIDY_CORPUS_DB also set" - FIXTURES.md/PLAN-10 R-10.5), which is an
even more sensitive artifact than the corpus files themselves and is
explicitly optional per the plan text. `test-e2e-corpus.R`'s last test adds
one narrowly-scoped second skip, gated on this second real-data env var,
after the mandatory `skip_if_no_corpus()` already ran. Treated as within the
spirit of the A3 allowance (real, private data availability) rather than a
new category of skip - flagging for confirmation since it's a literal second
`skip()` call in the suite.

## [pipeline-tests] R-9.5/R-9.6 — built-in adapters assumed to self-register on package load

`ingest_dir()` needs `esdat`/`als_xtab`/`als_enmrg`/`acirl_field_xlsx`
registered via `register_adapter()` to do anything. No plan explicitly pins
*where* that registration happens (e.g. a package `.onLoad()` calling
`register_adapter()` once per built-in adapter vs. some other bootstrap).
The e2e ingest tests in `test-ingest.R`/`test-e2e-pipeline.R` assume the
built-ins self-register when the package loads (the standard R package
pattern, and the only reading consistent with `ingest_dir()` being usable
with zero setup per CONTRACT/DESIGN §1). If that's wrong, those tests will
fail for a registration reason rather than a real defect — please confirm
where registration happens.

## [core-tests] R-1.3 — DESIGN §9.2's "second connection, same process" test
method does not reproduce RW lock contention with duckdb 1.4.1 [MEASURE TWICE]

PLAN-01 R-1.3 says to test the busy-retry path "with a second connection in
the same process - duckdb enforces one RW per file across connections via a
second `duckdb::duckdb()` driver instance." Verified empirically before
writing the test: with the installed duckdb R package (1.4.1), two
`duckdb::duckdb()` driver instances opened read-write to the *same path in
the same process* silently succeed and share state (confirmed by writing via
one and reading via the other) - no lock error at all. `?duckdb::duckdb` now
documents this: "`duckdb()` creates or reuses a database instance." A
genuinely separate OS process, however, does reproduce the documented
`Could not set lock on file ...: Conflicting lock is held` error (confirmed
via a two-process shell test).

Resolution taken in `test-db-connect.R`: the busy-retry test spawns a real
second process via `processx::process$new()` to hold the RW lock, then
calls `with_db_write()` in the test process and asserts the retry-then-abort
behaviour. The same instance-cache issue also breaks any "is the connection
really closed?" check done via a same-process reconnect (it would trivially
succeed even if `with_db_write()` leaked its connection), so the "returns
fn(con)'s value; connection closes after" and "fn throwing still closes the
connection" tests also spawn a probe subprocess
(`subprocess_can_connect_rw()`) rather than reconnecting in-process.

## [core-tests] R-1.3 — non-lock connect-error path: CONTRACT's "never
`stop()` bare" vs. DESIGN §9.2's reference `stop(last_err)`

The DESIGN §9.2 reference implementation re-throws a non-lock connect error
via bare `stop(last_err)`, but CONTRACT's blanket convention says "Errors via
`cli::cli_abort(class = "sampletidy_error")`; never `stop()` bare." Plan-01
says to "copy the reference implementation; it is normative," creating a
direct conflict for this one line. Rather than assert a specific error class
for this path (which could be wrong under either reading), `test-db-connect.R`'s
"a non-lock connect error ... aborts immediately" test only asserts on
message content (`"directory"`, matching the underlying DuckDB IO error text
verified empirically) and elapsed time, leaving the class/wrapping choice to
whoever implements it.

## [core-tests] R-1.6 — `ingest_file_upsert()`'s argument names beyond `con,
hash` are not pinned

PLAN-01 only sketches `ingest_file_upsert(con, hash, ...)`. `test-db-schema.R`
assumes the current path being observed is passed as `path` (not
`path_first_seen`, which is the DDL *column* name and — per its name — is
only ever set on a hash's first insert; later upserts with a different path
must not overwrite it, only append an `ingest_sighting` row). Also assumed:
`filename` and `size` as additional named args. If the real signature differs
(e.g. positional, or a single `meta` list), the calls in
`test-db-schema.R`/`test-router.R` will need a mechanical rename, not a
semantic rewrite.

## [core-tests] R-2.1 — mojibake table entries are literal hex-escape-string
patterns, not raw bytes

`WEM.data/R/new/data/normalise_lab_text.R`'s `.lab_text_mojibake_fixes` table
maps literal strings like `"<c2><b0>"` (the nine characters `<`, `c`, `2`,
`>`, ...) to real Unicode characters, not raw UTF-8/cp1252 byte sequences -
presumably reflecting some upstream step in the WEM.data pipeline that
renders unrepresentable bytes as `<XX>` hex-escape text before this function
runs. CONTRACT/PLAN-02 says to port this table "verbatim," so
`test-text-normalise.R` tests the literal hex-escape-string patterns exactly
as written in the source file, alongside the newly-pinned entries that *do*
use real Unicode characters (`¡`, `<U+FFFD>`) for the MacRoman-degree and
cp1252 cases. Confirm this reading is intended (vs. re-deriving the table to
operate on real raw bytes).

## [core-tests] R-2.2 — CONTRACT's claim that udunits doesn't know `pH` is
empirically imprecise, but the pinned *behaviour* is still testable
[MEASURE TWICE]

CONTRACT/PLAN-02 says "`pH`/`pH Unit`/`pH_Units` are registered as valid
dimensionless units (udunits doesn't know them; maintain a package-level
`.unitless_aliases` set)." Verified empirically: raw `units::set_units(1,
"pH", mode = "standard")` already succeeds - udunits2 *does* have a native
(logarithmic) `pH` unit - while `"pH Unit"` and `"pH_Units"` do not resolve.
This doesn't change what's testable: `test-units.R` asserts the pinned
observable behaviour (`is_valid_unit()`/`are_compatible_units()` TRUE for all
three strings, and `unify_value()` converts between them unchanged), which
holds regardless of whether the implementation's `.unitless_aliases` set
needs to shadow udunits' own `pH` entry or just cover the two variant
spellings.

## [core-tests] R-3.1 — `ir_results(...)`/`ir_samples(...)` argument-passing
convention beyond the zero-arg prototype is not pinned

PLAN-03 pins only `ir_results()` (no args) returning the zero-row prototype.
`test-ir.R` additionally exercises one call with named arguments matching the
column names (tibble-constructor style, single values per column) as the
most natural reading of "build validated tibbles ... exactly the columns" —
but this is the only test built on that assumption; every `ir_validate()`
violation test instead builds its fixture row via plain `tibble::tibble()`
so those tests don't depend on the constructor's exact calling convention.

## [core-tests] R-3.5 — `route_files()`'s signature beyond `paths`, and a
wording tension with R-1.6 on same-path re-routing

Two related gaps in PLAN-03/CONTRACT:

1. CONTRACT's bare-call example shows only `route_files(paths)`, but R-3.5
   says it "persists to `ingest_file` via plan-01 helpers," which require a
   connection. `test-router.R` assumes `route_files(paths, con)`.
2. R-3.5 says "re-routing the same path is a no-op (state unchanged, **one
   new sighting**)," but R-1.6 says a sighting is appended only "when the
   path differs from `path_first_seen`." Taken literally, re-routing the
   *same* path should **not** add a sighting under R-1.6's rule, directly
   contradicting R-3.5's parenthetical. `test-router.R` follows R-1.6 (the
   more precise, lower-level spec): re-routing the identical path asserts
   **no new sighting row**; a *different* path with an identical file/hash is
   the one asserted to add exactly one sighting (both plans agree on that
   case). Please confirm R-3.5's wording was a slip, or correct the test if
   sightings are actually meant to accumulate on every re-route regardless of
   path.

## [core-tests] `seed_db()` now creates an empty `asset` table

Per this file's own `[pipeline-tests] R-9.2/R-9.3` entry above requesting it:
added an `asset` table (CONTRACT's full column list, no pinned rows - none
are specified in FIXTURES.md) to `tests/testthat/helper-db.R`'s
`.st_test_core_ddl`. `helper-corpus.R`'s `ensure_test_asset_table()` uses
`CREATE TABLE IF NOT EXISTS` with an identical column list, so it becomes a
harmless no-op wherever `seed_db()` already ran and can be deleted whenever
convenient.

## [adapter-tests] R-4.x/R-5.x/R-6.x — adapter accessor not literally pinned

CONTRACT.md's pinned public API only names the *registry* functions
(`register_adapter()`, `adapter_registry()`, `clear_adapters()`); no CONTRACT
line pins a literal object name for a given built-in adapter (e.g. `esdat` vs
`esdat_adapter`). Per orchestrator instruction, `test-adapter-esdat.R` /
`test-adapter-crosstab.R` / `test-adapter-acirl.R` all default to the
**registry route**: `sampleTidy:::adapter_registry()[["esdat"]]`,
`[["als_xtab"]]`, `[["als_enmrg"]]`, `[["acirl_field_xlsx"]]` (ids per
DESIGN §5's planned-adapters list), assuming the built-ins self-register on
package load (same assumption `[pipeline-tests] R-9.5/R-9.6` already flagged
for `ingest_dir()`). If registration instead happens some other way (e.g. an
explicit bootstrap the caller must invoke), these three test files will fail
on a registration/lookup reason rather than a real adapter defect - please
confirm where/how the four built-ins get registered.

## [adapter-tests] R-4.2 — Chemistry2e pinned header list conflicts between FIXTURES.md and PLAN-04

PLAN-04's prose lists Chemistry2e's columns as `SampleCode, ChemCode,
OriginalChemName, Prefix, Result, Result_Unit, Total_or_Filtered,
Result_Type, Method_Type, Method_Name, Extraction_Date, Analysed_Date, EQL,
EQL_Units, Comments, Lab_Qualifier, UCL, LCL` (18 columns, including
`Method_Type`), while FIXTURES.md's own pinned "Chemistry2e columns exactly"
list omits `Method_Type` entirely (17 columns). Since match() (R-4.1) hinges
on "the header row equals one of the two pinned column lists" byte-for-byte,
these two specs cannot both be followed literally. `fixtures/esdat/generate.R`
and `test-adapter-esdat.R` follow **FIXTURES.md** (the file explicitly
designated "THE synthetic universe" pinning exact columns/rows/values) and
omit `Method_Type`. If `Method_Type` is actually required, the fixture header
and every `match()`/parse() test in `test-adapter-esdat.R` need it re-added.

## [adapter-tests] R-4.3 — Sample2e row/sample-type coverage conflicts between FIXTURES.md and PLAN-04

PLAN-04 R-4.3's criterion describes "fixture (8 Normal + LCS/MB/LAB_D/MS/NCP
rows) maps 1:1," implying 8 `Normal` rows plus all five non-Normal sample
types (`LCS`, `MB`, `LAB_D`, `MS`, `NCP`). FIXTURES.md's own pinned Sample2e
table has only **3** `Normal` rows (`XX1234567001/002/003`) plus one each of
`LCS`, `MB`, `NCP` - 6 rows total, and never mentions `LAB_D` or `MS` at all.
`fixtures/esdat/PROJ_A.ESDAT_XX1234567_0.Sample2e.CSV` and
`test-adapter-esdat.R`'s "R-4.3: Sample2e fixture maps 1:1 (6 rows)" test
follow FIXTURES.md's literal pinned table (6 rows, no `LAB_D`/`MS` coverage).
`LAB_D`/`MS` sample types remain untested at the adapter level as a result -
if that coverage is actually required, FIXTURES.md needs an update pinning
concrete `LAB_D`/`MS` row values before a test can assert on them without
inventing data.

## [adapter-tests] R-4.5 — no fixture data for the "unparseable date -> warnings" criterion

FIXTURES.md's pinned 10-row Chemistry2e table always uses the clean
`26 May 2025` `Analysed_Date`, leaving no data to exercise R-4.5's "an
unparseable date lands in `warnings` with its `source_ref`, the row still
emitted with `analysed_date` NA" criterion. Added a small auxiliary fixture,
`fixtures/esdat/BADDATE.ESDAT_XX5555555_0.Chemistry2e.CSV` (same pinned
header, one row, `Analysed_Date = "31 Undecember 2025"`), documented in
`fixtures/esdat/README.md`.

## [adapter-tests] R-4.2/R-9 — assumed error class `sampletidy_parse_error` for the corrupted-CSV crash fixture

The plan-09/10-requested `CORRUPT.ESDAT_XX0000000_0.Chemistry2e.CSV` fixture
(same pinned header so `match()` still claims it; one data row with a bare
invalid UTF-8 continuation byte `0x80` in `OriginalChemName` - verified to
make base R's `nchar()`/`toupper()` throw "invalid multibyte string," while
`readr::read_csv()` itself reads the row without error - see
`fixtures/esdat/README.md`) needs `parse()` to actually abort for plan-09's
"adapter crash on one file -> that file `failed`" scenario to be reachable.
`test-adapter-esdat.R`'s "R-4.2: corrupted Chemistry2e data causes parse() to
abort loudly" test asserts `class = "sampletidy_parse_error"`, reusing R-4.4's
already-established precedent (non-ESdat XML aborts with that same class) and
CONTRACT's "errors via `cli::cli_abort(class = "sampletidy_error")`" blanket
rule. No plan pins this exact class for this exact scenario - if a differently
-classed (or differently-worded) abort is intended, this one test's `class=`
argument needs updating, not the fixture.

## [adapter-tests] R-5.1/R-5.2 — crosstab column-layout (label positions, "Analyte grouping/Analyte") is under-specified

PLAN-05 explicitly forbids fixing column indices in the *parser* ("do not fix
column indices - locate labels by regex in each row - observed files vary")
but its own layout-facts table pins two very specific real-file *observations*
that fixtures should reproduce: the `ALS Sample Number:`/`ALS Sample number:`
label sits at column index 3 (XTAB) vs 4 (ENMRG) (0-based), and the header row
starts with "`Analyte grouping/Analyte`" (a slash-joined pair, ambiguous
whether that's one column with dialect-dependent wording or two separate
columns). Neither the real ALS crosstab files nor a captured sample were
available to resolve this definitively, so `fixtures/crosstab/generate.R`
commits to one self-consistent, documented interpretation (detailed in
`fixtures/crosstab/README.md`): XTAB has 4 label columns (`Analyte`,
`CAS Number`, `Unit`, `Limit of reporting`) with sample data from column 4;
ENMRG has 5 (`Analyte grouping`, `Analyte`, `CAS Number`, `Unit`,
`Limit of reporting`, as two separate analyte-name columns) with sample data
from column 5 - which reproduces both pinned "label col index" facts (3 vs 4)
exactly. `test-adapter-crosstab.R`'s assertions read `analyte_raw` etc. by
*name*/regex-matched row & column position already implied by the fixture, so
they do not hard-code these indices, but the fixture's own shape is this
chosen interpretation, not a literal capture of a real file. If the real
column layout differs meaningfully (e.g. `Analyte grouping` genuinely holds a
broader category, not a duplicate analyte-name column), the fixture's data
(not the test assertions) would need adjusting.

## [adapter-tests] R-5.1 — FIXTURES.md's "two stacked sections WATER+the same analytes" resolved via PLAN-05's explicit "WATER+SOIL" wording

FIXTURES.md describes the XTAB fixture as having "two stacked sections
WATER+the same analytes," which is ambiguous about whether the second section
is also `WATER` (mere duplication) or a different matrix. PLAN-05 R-5.1's own
criterion is unambiguous: "two-section fixture: rows carry their own
section's matrix and dates" - only meaningfully testable if the two sections
carry *different* matrix values. `fixtures/crosstab/XX1234567_0_XTAB.csv`
therefore has a `WATER` section (the one pinned/cross-checked against the
ESdat fixture's XX1234567001-003 values) followed by a second, independent
`SOIL` section (1 extra sample, plain-ASCII analyte spellings so it can never
be confused with the mojibake-bearing WATER section in test assertions).

## [adapter-tests] R-6.x — several ACIRL criteria have no data in FIXTURES.md's pinned single workbook

FIXTURES.md pins exactly one ACIRL workbook (`2400-9999-01 Test Month
WMF.xlsx`, Front/Method/Dust/two-water-sheet shape) with no genuinely-empty
front-page field, no >20-row field block, and no water sheet lacking a
`Units` marker - so PLAN-06's R-6.1 ("a random xlsx -> `no`"), R-6.2
("missing `REPORT NO:` -> ... `work_order = NA`"), and two of R-6.3's branches
("`>20`-row block emits a warning ... still parses"; "a sheet with no `Units`
marker -> sheet skipped ... other sheets still parse") have no fixture data to
exercise them. Added three small auxiliary workbooks, documented in
`fixtures/acirl/README.md`: `EDGECASES.xlsx` (a 24-row `Field Data Big` sheet
+ a `Field Data NoUnits` sheet with no `Units` cell anywhere, alongside a
normal front page so the file still gets routed), `NO_REPORT_NO.xlsx` (front
page missing `REPORT NO:` entirely), and `random.xlsx` (unrelated trivial
workbook). The pinned main workbook itself is unchanged from FIXTURES.md's
spec (still exactly Front/Methods/Dust/2 water sheets).

## [adapter-tests] R-6.2/R-6.3 — `report$header`/`report$skipped` field names assumed by analogy, not literally pinned

Neither PLAN-06 nor CONTRACT pins the literal field names inside
`report$header` for the ACIRL adapter (only the *values* - report number,
sampled-by, sample date - and their front-page provenance are pinned).
`test-adapter-acirl.R` assumes `report$header$report_no` /
`$sampled_by` / `$sample_date`, matching the front page's own "REPORT NO:" /
"SAMPLED BY:" / "SAMPLE DATE:" terminology (parallel to how R-4.4's ESdat
`report$header` uses `work_order`/`date_reported`/`project_id`/`lab_name`,
matching Header.XML's own attribute names). Similarly, `report$skipped`'s
`reason` values (`"lab_data_dropped"`, `"dust_sheet_ignored"`, `"empty"`,
`"not_computable"`) and its `source_ref` format (`"r<row>c<col>"` for
crosstab, per R-5.1's own explicit text) are asserted verbatim from each
plan's own quoted strings; anywhere a plan doesn't quote an exact string
(e.g. the crosstab mismatch-precedence warning's exact wording), tests assert
on substring content (`grepl()`) rather than an exact message, to avoid
over-fitting an unpinned detail.

## [review-triage] PLAN-11 R-11.8 / F9 — are distinct non-NA sample datetimes distinct samplings? ✅ RESOLVED (user 2026-07-19: TWO distinct samplings)

**RESOLVED — two distinct samplings.** Promoted to PLAN-11 **R-11.18** + CONTRACT
**A62** (A11 refined). The fix lands in both `.rc_find_existing` (R-11.7) and
`.ct_find_or_create_sample` (R-11.8), splitting only when distinctness is provable
(incoming datetime non-NA and every candidate non-NA and differing); a NA datetime
on either side falls back to date-granularity reuse. Original question retained
below for context.


`.ct_find_or_create_sample()` (`commit.R:95-104`) reuses the first date-level
sample when the incoming `sample_datetime` differs from the candidate's (the
datetime narrowing only runs `if (nrow(cand) > 1)`, and on no datetime match it
returns `cand$uuid[[1]]` regardless). Consequence: a 09:00 reading and a 15:00
reading at the **same feature+date** collapse onto **one** sample row — the
second sampling's identity is lost (real for multi-visit-per-day monitoring).
A11 says matching is "date first, then datetime when both sides have it"; it
never says a *non-matching* datetime should reuse rather than create.

**Decision needed (domain):** should two readings at the same feature+date with
**different non-NA clock times** be (a) two distinct samples (distinct
samplings), or (b) one sample (today's behaviour)? PLAN-11 R-11.8 rewrites this
exact function, so the fix — if (a) — lands there for free: create a new sample
when every candidate has a non-NA datetime differing from a non-NA incoming
datetime. Until decided, R-11.8 preserves today's reuse behaviour and does not
regress it. Not resolved silently, per [NO SILENT DEVIATION].

## [review-triage] PLAN-12 R-12.2 / F7 — extend ingest containment to reconcile+commit? ✅ RESOLVED (user 2026-07-19: contain, loudly)

**RESOLVED — contain, loudly.** Per-event tryCatch (kept files → `failed`,
`cli_warn`, `events_failed` counted, continue); a run where **every** event fails
aborts `sampletidy_error` (systemic-failure signal). Pinned in PLAN-12 R-12.2 +
CONTRACT A60. Original context below.


`ingest_dir()` contains adapter *parse* crashes per file (R-9.5), but
`reconcile_event()`/`commit_event()` run bare in the loop (`ingest.R:121-152`),
so one poison event (archive-copy failure, zero-row registry lookup, payload
glitch) aborts the run for every event routed after it. R-9.5 specced
containment for parse **only** — extending it to reconcile+commit is a policy the
plans never made explicit.

**Decision needed:** adopt per-event containment (wrap reconcile+commit in
`tryCatch`, mark that event's files `failed`, count `events_failed`, continue)?
Recommended yes — committed events already have their own transactions, so
containment only changes *how far a single bad event propagates*, and a re-run
still completes the good events. If adopted it lands as PLAN-12 R-12.2 + CONTRACT
A60.

## [review-triage] PLAN-12 R-12.11 / F16 — env-var typing for list-valued config keys ✅ RESOLVED (user 2026-07-19: string-only + guard)

**RESOLVED — string-only + guard.** Env vars are string-only; list-valued keys
(today `field_analytes`) must be set via `st_config(key, value)` in code, and
`st_config()` aborts `sampletidy_error` if such a key is sourced from env (no
silent one-entry allowlist). Pinned in PLAN-12 R-12.11. Original context below.


`st_config()` env-var values are always strings, so `SAMPLETIDY_FIELD_ANALYTES`
would silently shrink the ACIRL field-analyte allowlist to a single entry. No
live deployment sets that env var today. **Decision:** document env-var-settable
keys as string-only (list-valued keys must be set via `st_config(key, value)` in
code), or define a split-on-separator convention for list-valued env vars. Low
impact; pin the chosen behaviour in `test-config.R` once decided.

## [review-triage] F5 / A-4 — live `feature` schema probed directly (informational)

> ⚠️ **SUPERSEDED 2026-07-22 — this entry probed the WRONG DATABASE.** The path
> below is the dashboard's *derived* copy, not the live DB (A67). The live
> `feature` table has **19 columns and DOES have `virtual`**. The `lon`/`lat`
> NOT NULL half of this entry is correct and still stands. See the
> "[plan-11 second review] 2026-07-22" entry at the end of this file.
> *(Append-only log: the original text is left intact below.)*

For the record: the live `feature` table shape (F5's fix depends on it) was
probed read-only against `/Users/rjs/Documents/dashboard/data/monitoring.duckdb`
on 2026-07-19. Result (18 cols): `uuid, name*, site*, flow, matrix, depth,
installed_by, permanent, reference, date_start, date_end, cypher, elevation,
uuid_project, lon*, lat*, geom_wkt, comments` (`*` = NOT NULL). **No `virtual`
column.** This settled the CONTRACT-vs-review disagreement (CONTRACT hid
`lon`/`lat` behind `…`; the review said they were NOT NULL — the review was
right). Folded into PLAN-11 R-11.17 + CONTRACT schema correction + A58. No open
question remains here.

## [plan-11 second review] 2026-07-22 — six user decisions + one wrong-database finding

All resolved in-session; recorded here because each edits a previously-pinned
position. Authority: CONTRACT A63–A69.

1. **D7 REVERSED — no `analysis` units column.** `lab_method` regains `units`
   and `conversion_constant` (both existed in WEM.data's `labDF` and were lost
   in a schema edit). Decided on measurement, not argument: over 3,624
   committable `Normal` rows, **221 of 222 (method, analyte) pairs report
   exactly one units string**; the exception is `sodium adsorption ratio`, whose
   two values both mean *dimensionless*. ⚠️ An unfiltered first cut said 95 of
   354 varied — that was QC rows (`%` recoveries), which never commit. Anyone
   re-deriving this **must** filter to `Normal`.
   `units` is a **fallback, not a guarantee** (user), pinned as a
   `COMMENT ON COLUMN`, and is **not** part of a method's identity: a second row
   per units variant would break revision supersede, because
   `.rc_find_existing()` keys on `a.uuid_lab`.
2. **D10 REVERSED — CAS-hits commit dangling** with the CAS as a review
   suggestion. Consistent with A54 (dangling ≠ resolved), preserves the CAS
   evidence, and removes a carve-out that needed a test to stop it rotting.
3. **D9 CONFIRMED — site-narrowing deferred** (costs 3 of 31 ambiguous keys, all
   to review; re-adding is purely additive).
4. **`add_feature(virtual = )` KEPT.** The 2026-07-19 "drop it" instruction was
   wrong — see 6.
5. **Registry collisions triaged by table** (user rule): duplicates in `analyte`
   are merged; differing capitalisations in `lab_method` are **kept**, because
   they record what reports actually said. So `Carbophenothion` (analyte) →
   merge (PLAN-14 R-14.1); `Standing Water Level`/`Standing water level`
   (lab_method, ACIRL) → keep, and fix the **matcher** instead (A65/R-11.19) —
   it currently returns 2 candidates, requires 1, and strands every such reading.
6. **⚠️ The wrong database was measured.** PLAN-11's Evidence block, the cold
   review, and the 2026-07-19 whole-package review all probed
   `/Users/rjs/Documents/dashboard/data/monitoring.duckdb` — the dashboard's
   **derived** copy (rebuilt from `.qs` files, D2). Row counts agree across
   copies (894/15,113/95,737/247), which is exactly why it passed as
   interchangeable. Three CONTRACT "corrections" made from it are **reverted**
   (A67): `feature` is **19 cols including `virtual`** (not 18/absent);
   `lab_method` is **360** (the copy's 5 extras are mojibake twins); and the
   "60 views" was `duckdb_views()` counting DuckDB's *internal* catalog views —
   both copies have **14**, and on both exactly **6** reference
   `sample.uuid_feature`, so D4 stands.
   **Rule going forward: quote the absolute path with every measurement.**

**Open, deliberately unresolved:** PLAN-14 R-14.3 — the 12 historical
`Ammonia as NH3` analyses. The registry fix is clear (`reported_as` = `N`/`NH3`;
the NH3→N constant is **0.8225**, *not* 1.216, which is the inverse direction).
But the 12 values carry 7 significant figures, NULL `value_chr`, and a daily
cadence at two features over six consecutive days beside a
`Computed: Leachate Mixing Fraction` row — they look **derived**, and if they
are already N-basis any multiplication corrupts them. **Needs provenance from
the user before anything is specced or written.**

## [plan-14] 2026-07-22 — R-14.3 RESOLVED by reading the archived source (no write needed)

The user pointed out that the DB names the asset uuids and the assets are on
disk at `…/waste_data - Environmental monitoring/assets`. That settled it in one
look, and the answer was **do nothing**.

Trace: the 12 analyses → samples `ES2415638004`–`015` → project `ES2415638`
("BWMF Apirl 2024 - Rain Event") → asset
`processed/08f1555c-18be-4167-a051-ba4f9fedea09/ES2415638_0_XTAB.csv`.

The report carries **both bases in one file** — `Ammonia as N` on samples
001–003, `Ammonia as NH3` on 004–015 — which also proves the two `lab_method`
rows are genuinely distinct and both required.

**Every stored value is the reported as-NH3 figure × 0.8224428** (the NH3→N mass
ratio), max deviation 1.4e-06 over all 12. The old pipeline had already applied
the conversion and simply never recorded the constant. The seven significant
figures that made these look "derived" were the *signature of that
multiplication*. All 12 dates match the source exactly in `Australia/Sydney`
(they read a day early only under `CAST(date AS DATE)`, which shows the UTC
calendar day — the known storage convention, not a defect).

**Both candidate fixes would have corrupted good data**: ×1.216 ⇒ ~21.6% high;
×0.8225 ⇒ double-converted, ~18% low. Recorded because the *process* is the
lesson: the anomaly was real, the "derived" inference drawn from it was wrong,
and stopping to ask rather than writing is what prevented the damage.

R-14.2 now pins `conversion_constant = 0.8224428` on `Ammonia as NH3` as
documentation of what was already done — and, per A63, as what converts *future*
as-NH3 rows. The two uses being consistent is the gate: a re-ingest of that file
must reproduce `1.76002759` and report `already_present`.

**Incidental finding, routed to PLAN-12 R-12.17 (A70):** A13 archives each file
as an extensionless `<asset uuid>`, justified as "matches existing
`processed/`". The real archive is **1,565 directories** named `<asset uuid>`
holding the original filename, vs **33** extensionless files — so sampleTidy
writes the minority shape, and A13's own "copies every file of a committed
event" is unsatisfiable with one file per uuid.

**Also good fixture material** (`ES2415638_0_XTAB.csv`): one file carrying two
bases of the same analyte; and `B.TS39`'s cypher holds `B.S39`, `B.E39`, `B.39`,
`B.TS40` — the plan-11 alias problem in miniature, with `B.E39` appearing in the
report itself as a live mis-transcription.

---

## R-2.3 / R-8.4 / R-11.16 — `quantified` is a tri-state; text results are NA, not TRUE (Robin, 2026-07-23)

**Pinned behaviour changed.** PLAN-02's R-2.3 table pinned
`parse_value("Clear, low flow") -> quantified = TRUE`. It is now **NA**.

**Why.** `quantified` states whether an analyte was detected above the reporting
limit — a claim about a *measurement*. A qualitative observation is not a
measurement, so neither TRUE nor FALSE is true of it. TRUE is the more dangerous
error: of the 315 text-valued rows in the live registry, **23 record that no
sample was taken at all** (`No sample due to snakes and over grown grass`,
`Could not find due to long grass`, `Decomissioned`, `No Access`), and marking
those quantified asserts an observation that never happened. A further 50 record
a non-event (`Dry`, `No flow`, `Non Discharge`).

**The live data was already correct** — all 315 rows are NULL, and there are
**zero** rows with `value_chr` set and `quantified` non-NULL. No migration is
needed. Only the write path was wrong, in two places:

| Site | Was | Now |
|---|---|---|
| `R/values.R` | `quantified[is_plain_numeric \| is_text] <- TRUE` | `quantified[is_plain_numeric] <- TRUE` |
| `R/commit.R` | `isTRUE(clean$quantified[[i]])` — maps NA to **FALSE** | NA is preserved |

The `commit.R` half is the worse of the two: it silently recorded an unknown or
non-measurement state as *below detection*.

**Consequential fix in `R/reconcile.R` — this one was a real defect, not a test
update.** `.rc_values_equal()` began `if (is.na(inc_quant) || is.na(exist_quant))
return(FALSE)`. With text now NA on both sides, two identical qualitative results
could never compare equal, so a re-ingested observation would never be recognised
as `already_present` and **would commit a second time**. NA now compares equal to
NA; an NA/non-NA mismatch is still a difference.

**Invariant established, and asserted in the tests:** among committed rows,
`quantified IS NULL` ⟺ `value_chr IS NOT NULL`.

**Two fixtures in `test-reconcile.R` were incoherent and had to change.** The
already_present tests used `value_raw = "7.10 (resent)"` with `value_num = 7.10`
— a string `parse_value()` classifies as TEXT, paired with a numeric value. They
passed only because text used to be quantified TRUE while carrying the adapter's
number. Replaced with genuine numeric restatements (`"7.100"`, `"12.00"`), which
preserves the "different bytes, same measurement" intent — the differing bytes
were always carried by `source_hash`, not by the value string.

Mutation-checked both ways: reverting `values.R` kills 9 assertions; reverting
`commit.R` kills 2.

---

## A5 / R-1.2 — file hash changed from SHA-256 to xxHash128 (Robin, 2026-07-23)

**Pinned contract changed.** A5 was `digest::digest(file = TRUE, algo = "sha256")`.
It is now `rlang::hash_file()` — xxHash128, a 32-character hex digest.

**Why.** The pre-package system already wrote xxHash128 into `asset.hash`. Found
by reading `~/Desktop/WEM.data`: `R/new/import/import_dust.R:319` and
`R/shiny/app.R:1670` write `hash = hash_file(...)`, and `R/new/bmcc/reorient_pdf.R:92`
shows it is `rlang::hash_file()`. **2,407 of the 2,433 hashed asset rows were
xxHash128; only the 26 sampleTidy wrote were SHA-256.** Keeping SHA-256 would have
left 99% of the archive permanently unverifiable — which is exactly what happened
during F.18, where a recovery pass compared SHA-256 against those 32-char values,
could never match, and reported "0 of 1,272 recoverable" as though it were a fact
about the data.

**This is a NON-cryptographic hash.** Appropriate here — it is a content-addressing
and de-duplication key for lab deliverables, not tamper-evidence. Do not reuse it
as such.

**Stored values were migrated by RECOMPUTING from the bytes, never by conversion**,
and only after confirming the stored SHA-256 still reproduced from those same bytes
(26 of 26 asset, 16 of 16 ingest_file passed that gate):

| Table | Migrated | Left as SHA-256 |
|---|---:|---|
| `asset.hash` | 26 | 0 — table is now uniformly xxHash128 (1,464 rows) |
| `ingest_file.hash` | 16 | **13** — bytes no longer exist anywhere, see below |
| `change_log.source_hash` | 0 | **1,412 — deliberately not migrated** |
| `review_queue.source_hash` | 0 | 4 |

**`ingest_file.hash` had to be migrated** — it is the re-ingest identity key, so
leaving it SHA-256 would make every already-ingested file hash differently on the
next run and look new. That is the duplicate-commit hazard F.10 exists to prevent.

**`change_log.source_hash` is deliberately NOT migrated.** `change_log` is not in
`.st_mutate_allowlist` (`R/mutate.R:40`) — the audit log is append-only by design,
and rewriting it would require bypassing the mutation layer, violating A32. Those
1,412 rows keep SHA-256 and remain traceable by recomputing SHA-256 on the archived
file. **Any tool that joins `change_log.source_hash` to `asset.hash` must handle
both widths**: 32 = xxHash128 (current), 64 = SHA-256 (pre-2026-07-23).

### 13 quarantined lab deliverables are LOST — F.17 was not hypothetical

The 13 unmigratable `ingest_file` rows are the COA / COC / QC / QCI PDFs and
`XTAB.XLS` siblings of work orders ES2600185, ES2610538, ES2612444, ES2614070 and
ES2617126. All are `quarantined`, all have `uuid_asset` NULL, and **none exists
anywhere under the SharePoint tree** (searched all 15,045 files by name). Their
data siblings survive because those were archived and have `asset` rows.

They were not removed by the 2026-07-23 deletion pass: that log
(`scratchpad/removed_inputs_2026-07-23.txt`) is 42 files, all `.csv`/`.CSV`/`.XML`,
and `.ig_remove_verified()` skips anything without an `asset` row. So they were
lost by some other route while sitting unarchived in the input directory — which
is precisely the failure mode F.17 describes. **F.17 should be treated as
remediation of a realised loss, not as a precaution.**

---

## PLAN-15 Work E + F.4–F.18 — cold plan audit adjudicated: 21 findings accepted, 3 rejected or corrected (2026-07-23)

A read-only cold audit of PLAN-15 Work E and F.4–F.18 returned **24 findings**.
Per the project rule that reviewer findings are hypotheses to be disproved rather
than verdicts, each was re-verified independently against the code and the live
registry
`/Users/rjs/Library/Application Support/org.R-project.R/R/sampleTidy/monitoring.duckdb`
(read-only) before acceptance. **21 accepted, 3 rejected or corrected.** Evidence
record: `dev/plans/AUDIT-ADJUDICATION-2026-07-23.md`.

**The framing fact behind most of the accepted findings.** Work E's empirical pins
were measured against a **pre-cutover snapshot** — 894 features / 1,989 aliases /
15,113 samples — but are presented in the plan as live-registry facts. Live today
on the path above is **895 features / 1,994 aliases / 15,149 samples**. Anything in
Work E that reads as a measurement needs re-measuring before it is trusted.

### The three corrections to the auditor — what independent verification bought

1. **E.5's stale proxy dates: the finding stands, the auditor's replacements were
   one day late.** Both literals *are* stale, but the corrected values are **not**
   the auditor's 2026-05-26 / 2026-05-05:

   | item | plan pins | auditor says | **actual** |
   |---|---|---|---|
   | `k.e02` → K.S06 | 2025-09-04 | 2026-05-26 | **2026-05-25** |
   | `b.s04` → B.S01 | 2026-03-16 | 2026-05-05 | **2026-05-04** |

   Measured every representation side by side — raw `date`, raw `datetime`,
   `CAST(date AS DATE)` and both Sydney-local conversions all agree. **Why this
   matters:** `sample.date` stores Sydney midnight as a UTC-naive `TIMESTAMP`, so a
   naive cast reads a day out. Writing the auditor's numbers into the plan would
   have planted the same day-early landmine this project was already bitten by
   (see the PLAN-14 R-14.3 entry above). Use **2026-05-25 / 2026-05-04**.

2. **Finding #22 REJECTED on both halves.** (a) F.17's "zero `quarantined` files
   for that event" does **not** collide with A10 — A10 routes ACIRL dust sheets to
   state `ignored`, not `quarantined`. (b) F.17 need **not** carry F.18's
   dual-layout rule: that rule governs *reading legacy* assets, whereas F.17 is
   new-ingest code, which only ever writes `<archive_dir>/<uuid>/<filename>`.
   Neither half survives.

3. **Finding #14's BDL total was wrong; the finding itself stands.** 47,227 is the
   count of *all* `quantified = FALSE` rows. The set where the `value` vs `rl_low`
   comparison is even defined — both non-null — is **35,174**. The **232** rows
   with `value > rl_low`, and **0** below, are correct, so F.16's self-contradiction
   (`:874–875` pins `value == rl_low` as "a testable invariant"; `:893` says the
   opposite) is real.

### Highest-consequence accepted findings

- **Migration 003 as specified would REGRESS Robin's own curation.** E.5's 8 keys
  (`b.s01, b.ts02, b.ts41, b.s22, b.s04, k.e02, b.ts18, b.ts40`) span **19** alias
  arms, not the **17** the plan pins; and `b.s01` and `k.e02` are already
  `auto_assign = TRUE` with `kind = 'transcription_error'`,
  `confirmed_by = 'R. Shannon'`. Run against the real resolver, `B.S01` → n=1 and
  `K.E02` → n=1: both already auto-resolve to exactly one candidate.
- **F.3 is unbuilt and its prescribed parity test now FAILS against shipped F.2**,
  whose Unicode-whitespace divergence was deliberate. The obvious way to make F.3
  pass is to revert F.2 — so the parity oracle has to be restated before F.3 is
  written.
- **F.10 as specified blocks A12 revision supersede and the `already_present`
  path** — `.rc_find_existing()` (`reconcile.R:1009`) and `.rc_recorded_revision()`
  (`:1067`) both depend on the precondition F.10 would block.
- **Two E.6 criteria and one F.4 criterion cannot fail as written.** 003's "aborts
  if a feature lacks a `self` alias" is unfailable (0 of 895 live and 0 of 13
  fixture features lack one); F.4's oracle admits the very mutation it targets
  (`TS1` → TH.S01, `TS01` → {} satisfies "different features", and so would
  `TS01` → T.S01).
- **F.5 and F.7 carry no acceptance criteria at all** — both zero, while six other
  F items have "Acceptance (must be able to FAIL)".
- **`change_log.source_hash` is a mixed-algorithm column nobody migrated** —
  **100% 64-char (SHA-256) over 1,412 rows** while new writes are 32-char
  (xxHash128). Discovered by this audit; consistent with the A5 entry above, but
  the *mixed-width consequence* was not previously pinned anywhere.

### Sequencing constraints newly pinned

`F.9 → 003` · `F.5 → F.6 → E.3` in one pass under a **single `subkind` precedence
table** · `F.11 → F.12` · F.10's supersede exemption before F.10 · F.15's
schema-linkage decision before F.15.

### Open — needs a ruling from Robin

May `b.s01` and `k.e02` regress to review for pre-bound dates, given that both
resolve cleanly today (n=1 each) and both are already curated `auto_assign = TRUE`
by Robin? Migration 003 cannot be written either way until this is answered.
