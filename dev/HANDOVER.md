# sampleTidy — build handover

_Last updated: **2026-07-22**. Branch: `tdd-mvp-implementation`._

## Read this first (2026-07-22 session)

**PLAN 10 IS COMPLETE.** The OneDrive hydration problem is fixed — all 265
corpus files hydrate (verified: zero dataless files, every file's read length
equals its stat size). All four R-10.5 real-corpus gates now pass over the
**full** corpus for the first time: **433 assertions, 0 failures, 0 skips**
(route sweep 265 files / 125 unclaimed — 92 PDF + 21 `.bak` + SpreadsheetML
`.XLS`, all expected; parse sweep 422 assertions; cross-format equivalence 3
comparable work orders, 2 compared, ES2515460 342/342 rows agreeing; dry run
vs a real-DB copy — 90 events, `already_present` > 0, zero writes). R-10.6
(`devtools::check()`) was verified at `33273a1` and no production code has
changed since (`git diff 33273a1..HEAD -- R/ NAMESPACE DESCRIPTION` is empty).

⚠️ **The corpus path in this file's "Running the corpus gates" section below
omits a `Sharepoint/` component** — that is why the folder has looked missing.
The correct root is
`~/OneDrive - Blue Mountains City Council/Sharepoint/waste_data - Environmental monitoring/`.

**The suite is deliberately TDD-red** (1 failure + 43 errors, all `Table "s"
does not have a column named "uuid_feature"`): Phase-4 dispatch 1 landed the new
alias schema in `helper-db.R` ahead of the production amendments. 928 pass.
Not a regression.

**PLAN 11 is mid-Phase-4 and was NOT ready for the skill; it now is.** A second
review found that its whole Evidence block had been measured against the
**wrong database** — `/Users/rjs/Documents/dashboard/data/monitoring.duckdb` is
the dashboard's *derived* copy (rebuilt from `.qs` files, D2), not the live DB.
Row counts agree across copies, which is why it passed as interchangeable.
Three CONTRACT "corrections" made from it are reverted (A67). See
`dev/plans/CONTRACT.md` A63–A69 for everything decided this session.

**Plans 13 and 14 are new:** the migration split out of plan 11 (A68), and a
live-DB data-remediation plan (A69) whose third item is **open pending
provenance** — do not implement it.

## Read this first if you are picking up plan 11

`dev/plans/PLAN-11-feature-alias.md` is fully specced with the user's
decisions and the measured evidence behind them — read it, not this summary.
In one line: `feature.cypher` (a comma-separated bag of every way a sampling
point has ever been mis-transcribed) is replaced by a real `feature_alias`
table and wired into the reconciler, because mis-transcribed sampling points
are *the* reason this pipeline needs a human in the loop.

## What we're building

**sampleTidy** ingests environmental-monitoring lab data — ALS **ESdat** EDD
files, ALS **crosstab** exports (XTAB/ENMRG), and human-edited **ACIRL** field
workbooks — into an existing DuckDB monitoring database (`monitoring.duckdb`:
`feature`/`analyte`/`sample`/`analysis`/… ~95k analyses). The public entry point
is `ingest_dir(path, db, dry_run)`: hash-track files → route to a format adapter
→ parse to a common IR → assemble per-work-order events → reconcile against the
live DB (new / already-present / conflict / review) → commit atomically with a
`change_log` audit trail and file archival. Design authority: `dev/DESIGN.md`
(= GitHub issue #1 v2).

## How we're building it — the TDD-plan workflow

Using `.claude/skills/tdd-plan`: collaborative design → explicit per-plan specs
with correctness criteria → a full failing test suite written **before** code →
cheap models implement, expensive models audit/adjudicate. Key artifacts in
`dev/plans/`:

| file | role |
|---|---|
| `CONTRACT.md` | **single source of truth**: pinned APIs, file-ownership partition, conventions, and the **adjudication log (A1–A45)**. Read this + your own plan, not the whole corpus. |
| `PLAN-0N-*.md` | per-plan specs with correctness criteria |
| `PARKED-QUESTIONS.md` | questions raised for Robin — **all resolved** (see below) |
| `PLAN-CHANGE-REQUESTS.md` | append-only ambiguity log from the test-writing phase |
| `FIXTURES.md` | the synthetic fixture spec (now largely superseded by real fixtures) |
| `COVERAGE-MAP.md` | criterion → test map |

Tests: `tests/testthat/test-<module>.R`, one per `R/` file. Fixtures in
`tests/testthat/fixtures/<adapter>/`.

## Where we're up to

**All plans 01–10 are DONE and green — the MVP is complete.**

| plan | module(s) | status |
|---|---|---|
| 01 | config, db-connect, db-schema, hash | ✅ green |
| 02 | text-normalise, units, values, dates, spreadsheet-tools | ✅ green |
| 03 | ir, adapter-registry, file-meta, router | ✅ green |
| 04 | **adapter-esdat** | ✅ green — **reworked** for real files (latin-1) |
| 05 | **adapter-crosstab** (als_xtab/als_enmrg) | ✅ green — **reworked** for real layout |
| 06 | adapter-acirl-field | ✅ green |
| 07 | assemble | ✅ green |
| 08 | reconcile | ✅ green |
| 09 | mutate, commit, archive, snapshot, ingest | ✅ green |
| 10 | e2e-pipeline, e2e-corpus | ✅ green |

Full suite: **301 tests, 0 fail / 0 error**, 4 skipped (the `SAMPLETIDY_CORPUS`-
gated real-corpus tests in `test-e2e-corpus.R`, R-10.5). `test-e2e-pipeline.R`
is 11/11.

**Plan 10 (tests-only) surfaced five real defects — all fixed in their owning
plans with regression tests (A44, A45):**
- **A44.1 reconcile:** `.rc_feature_candidates(NA)` returned a phantom NA "hit" →
  orphan `uuid_feature = NA` rows. Fixed with a NA guard + sentinel review group.
- **A44.2 assemble:** the sample→result join never copied `feature_raw`, so every
  ESdat result was feature-less (masked by A44.1). Fixed (guarded fill).
- **A44.3 commit:** sample `date` built in AEST was UTC-shifted to the previous
  day on write, breaking cross-run sample reuse. Fixed (`tz = "UTC"` midnight).
- **A45 reconcile (domain correction from Robin):** the analysis uniqueness key
  is **(feature, datetime, analyte, method)** — a field EC and a lab EC of the
  same analyte are distinct rows, not a `value_conflict`. Added `uuid_lab` to the
  three-way match.
- Plus test-only fixes: the recurring `withr` frame bug in every plan-09/10 setup
  helper (A41/A43), unquoted `ORDER BY "at"` (A40/A42), NA-unsafe row filters
  (A43), a cross-file adapter-registry leak (R-10.1 passed alone, failed in
  suite), export drift trimmed to the CONTRACT's 19 public functions (R-10.6),
  and the plan-10 revision-supersede fixture `XX1234567_1_XTAB.csv`.

The through-line: **every unit suite was green while three real bugs lived in the
module seams** — only the e2e suite over realistic fixtures caught them. That
lesson drove the skill-improvement research in `dev/tdd-skill-improvements.md`.

Recent commits: `6b3ccc0` (plan 07 assemble) → `d21c386` (plan 08 reconcile) →
`d2e510e` (plan 09 mutate) → `+3` (plan 09 archive/snapshot, commit, ingest).

## The big arc of this session

Robin pointed us at the **real** lab corpus. That immediately exposed that
**the synthetic fixtures mis-modelled reality** — two "green" adapters could not
parse real files:

1. **ESdat (04):** real Chemistry2e/Sample2e CSVs are **latin-1** (byte `0xB0`=`°`,
   `0xB5`=`µ`); the adapter read them as UTF-8 and aborted in
   `normalise_lab_text()`'s `gsub()`. Fixed: read with a latin-1 locale.
2. **Crosstab (05):** the WIP parser inspected only column 0 and matched a bare
   `^Analyte$`; real files put per-sample metadata at col 3 (XTAB) / 4 (ENMRG),
   multiple labels per row, and the analyte header is the combined
   `Analyte grouping/Analyte`. Rewrote the row-walk to the real layout.
3. **Crosstab `.XLS`:** real XTAB "XLS" files are **SpreadsheetML XML**, not
   binary — `readxl` can't read them. **Parked** for MVP (A37).

**Decision (Robin): commit anonymized real files as the primary fixtures** —
the data is EPA-required-public, so this overrides A3. Anonymization is
byte-level (ASCII identifiers only) so latin-1 bytes survive; only
sampling-point codes and place/person names change, all analytical data is
byte-identical. Map + provenance: `tests/testthat/fixtures/REAL-FIXTURES.md`.
Real corpus lives at
`…/OneDrive-…/waste_data - Environmental monitoring/assets/input`
(and Robin's curated `…/assets/input/sampleTidy example`).

Both reworks were **validated against the whole real corpus**, not just tests:
94/94 real ESdat CSVs parse; all 4 real XTAB + 9 real ENMRG parse with 0 NA
analytes and matching cross-format counts. (This directly caught a bad worker
patch — a raw quote-parity guard that would have wrongly failed a valid real
file — which was replaced with an encoding-safe corruption check.)

## Parked questions — all resolved

1. **Crosstab layout** → `Analyte grouping/Analyte` is ONE column in both
   dialects (grouping is by method-group rows). Resolved from real files.
2. **QC types** → real Sample2e carry all five (LAB_D/LCS/MB/MS/NCP); `MS`
   confirmed present. Fixture covers them.
3. **Write-API `con`** → keep the split (A16): `add_feature/analyte/project` +
   `correct_value` self-resolve `st_config("live_db")`; `db_append/update/delete`
   take explicit `con`.
4. **Assembly→review seam** → inline flags on `event$results` (A22).

Adjudications across the build: **A29 (resolved), A34** (crosstab real layout),
**A35** (ESdat latin-1 + CORRUPT), **A36** (QC types), **A37** (SpreadsheetML
parked). Plan 08–09 build: **A38** (`seed_db()` withr default-arg), **A39**
(reconcile fixture feature_raw), **A40** (`db_transaction` hook + `"at"` quoting),
**A41** (the plan-09 setup helpers re-triggered A38 one frame removed), **A42**
(test-commit.R `ORDER BY "at"`), **A43** (test-ingest NA-safe filtering + the
`build_e2e_input_dir` withr bug). Plan-10 build: **A44** (three real defects —
reconcile NA-feature, assemble feature-join, commit date-tz), **A45** (uniqueness
key includes method — field vs lab coexist). See `CONTRACT.md`.

## Loose ends / next steps

**The MVP build is complete (plans 01–10 green), and plan 10's two deferred
checks have now run** (`33273a1`) — both found real defects (A46, A47; see
`CONTRACT.md`). The headline: **the first real ingest of the real corpus would
have aborted outright** (A46 — 11 duplicate-download twins in one directory),
and **`devtools::check()`'s first run broke R-10.6's own drift-guard test**,
which had only ever passed under `devtools::test()`.

Current gate state:
- **`devtools::check()`: 0 errors, 0 warnings, 2 notes.** The notes are benign:
  "unable to verify current time" (environmental) and NEWS.md "no news entries
  found" (R's parser wants `# pkg 0.0.0.9000`, not `# pkg (development
  version)`).
- **Suite: 1142 pass / 0 fail**, 4 skips (the corpus gates, correctly skipped
  with no `SAMPLETIDY_CORPUS`).
- **Real corpus (266 files): all four R-10.5 gates green.** No adapter tie;
  every claimed file parses and `ir_validate()`s; cross-format equivalence
  holds *exactly* where the ESdat pair is complete (ES2515446 29/29,
  ES2515460 342/342 Normal rows); the dry run against a copy of the real
  `monitoring.duckdb` finds 27 `already_present` rows and writes nothing.

**Running the corpus gates:**
```sh
ROOT="$HOME/OneDrive - Blue Mountains City Council/Sharepoint/waste_data - Environmental monitoring"
SAMPLETIDY_CORPUS="$ROOT/assets/input" \
SAMPLETIDY_CORPUS_DB="$ROOT/data/monitoring.duckdb" \
  Rscript -e 'devtools::load_all(); testthat::test_dir("tests/testthat")'
```
⚠️ `$ROOT/data/monitoring.duckdb` is the **authoritative** DB (A67). Do **not**
measure schema facts from `~/Documents/dashboard/data/monitoring.duckdb` — it is
a derived copy with a genuinely different schema (19 vs 18 `feature` columns,
360 vs 365 `lab_method` rows), and confusing the two produced three false
CONTRACT entries.
✅ **OneDrive hydration — RESOLVED 2026-07-22.** The corpus lives in OneDrive
Files-On-Demand, and a placeholder used to report a real `size` while **reading
as 0 bytes** (the first read only *starts* an async download), so an adapter saw
empty content, returned `match()=="no"`, and the file landed silently in the
"unclaimed (informational only)" bucket. That moved sweep numbers between runs
(126→145 unclaimed) and at one point **44 of 266 files would not hydrate at
all**. All 265 files now hydrate: **0 dataless** (`stat -f %b` = 0 with
`size > 0`) and **0 read-length mismatches** across the whole corpus. The stable
figure is **125 unclaimed of 265**.

Still worth doing (cheap insurance, not currently biting): a hydration guard in
`corpus_files()` that fails loudly on a `size > 0` file that reads empty, since
"unclaimed" would otherwise absorb a regression silently. Optional PLAN-12 item.

Remaining follow-ups (not blockers):
- **Act on `dev/tdd-skill-improvements.md`** — the research report on hardening
  the tdd-plan skill so its generated suites catch seam bugs, non-determinism,
  and harness-lifetime bugs earlier (its top 5 edits are summarised at the end).
  Plan 10's final checks are fresh evidence for it: **all four corpus gates were
  written in a way that could not verify anything** (wrong `route_files()`
  signature swallowed into `failed` rows; a lone-Chemistry2e comparison that
  could never have `Normal` rows; a test with zero expectations reported as
  "skipped"), and R-10.6's drift guard only worked under the runner it was
  developed with. A gate that cannot fail is worse than no gate.

**Plan-09 follow-ups worth a look:**
- **`dry_run` persists `ingest_file` state transitions** (ops-table only — the
  tested "zero core writes" holds). Harmless for MVP, but a `dry_run` followed by
  a real run would find files already past `seen`, so `route_files` no-ops them
  and the real run does nothing. Consider making `dry_run` non-persistent (or
  `reset`) if that flow matters.
- **Orphan/no-work-order events** commit with a project named `NA`
  (`commit_event: NA` in `state_reason`). Fine for the fixtures; decide the
  intended behaviour for genuinely orphan lab files.
- **Sample `datetime` UTC-shift (A44 note):** commit stores the sample `datetime`
  as the correct *instant* but a UTC-shifted wall clock (11:45 AEST reads back
  01:45). Comparisons are instant-based so matching is unaffected, but the stored
  display is off — revisit whether the schema wants naive-AEST wall-clock storage
  (the `date` column was fixed in A44.3; `datetime` was left as-is deliberately).

**Deferred / to revisit:**
- **Real ACIRL fixture:** Robin's `2400-7399-08…Blaxland WMF.xls` is genuine
  binary BIFF (`readxl` reads it: sheets Front Page / Sampling Sites 1–4 / Dust /
  Water Methodology). Not yet anonymized/pinned — needs `readxl`→anonymize
  grid→`openxlsx` (`.xlsx`), preserving cell types (date serials!). The ACIRL
  adapter is green on its synthetic fixture but **unvalidated against a real
  workbook**.
- **SpreadsheetML `.XLS` parsing (A37):** parked. Adapter returns `match()=="no"`
  gracefully; `.csv` twin carries the data. `ES2600185_0_XTAB.XLS` fixture is
  pinned for the post-MVP path (parse via `xml2`, not `readxl`).
- **Plan-10 rev-1 fixture:** `XX1234567_1_XTAB.csv` (revision-supersede) was
  dropped in the crosstab fixture regen — plan 10 must recreate it in the real
  layout.
- **XTAB U+FFFD quirk:** `ES2600185_0_XTAB.csv`'s degree sign is the UTF-8
  replacement char `EF BF BD` (already lost upstream), so it reads as `ï¿½` under
  the latin-1 dialect and `normalise_lab_text()` doesn't repair it. Data is
  genuinely lost in the source; revisit whether XTAB encoding should be per-file
  detected.
- **Crosstab QC-block skip:** the rework added a mechanism to skip any
  non-dialect `…Matrix:` section (e.g. a trailing `QC - Matrix:` block) from that
  row on. Works for observed files; re-check it can't over-skip a mid-file block
  followed by real data.

## Handy commands

```r
# load + run one plan's tests
Rscript -e 'devtools::load_all(); testthat::test_file("tests/testthat/test-<x>.R", reporter="summary")'
# regenerate a fixture set
Rscript tests/testthat/fixtures/<adapter>/generate.R
```

Adapter self-registration lives in `R/zzz.R` (`register_builtin_adapters()`),
called from `.onLoad()` and at the start of `ingest_dir()` (A33).
