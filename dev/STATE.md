# sampleTidy — current state

**Read this first on a cold start.** This file is rewritten, never appended to.
Last checked **2026-10-17** against the live database, read-only.

The companion documents, in the order you are likely to need them:

| for | read |
|---|---|
| decisions waiting on Robin, and choices made in his absence | `scratchpad/DECISIONS-FOR-ROBIN.md` |
| rules in force today | `dev/plans/OPERATING-RULES.md` (A73+; latest is A92) |
| migrations: what each does, and whether it is applied | `dev/MIGRATIONS.md` |
| the frozen build contract (A1–A72, plus later API notes) | `dev/plans/CONTRACT.md` |
| design authority | `dev/DESIGN.md` |
| the ACIRL gas adapter | `dev/plans/PLAN-17-adapter-acirl-gas.md` |
| field and ALS lab QC (planned) | `dev/plans/PLAN-19-qc.md` |

## In one sentence

The package is built. The registry and the legacy data have been repaired by the
applied migrations, and ACIRL gas now has an adapter. **The historical corpus was
imported to live on 2026-10-21** (with 053-062 before it and 064, 063 after it). The
ACIRL gas import is done (2026-10-17).

## Live database

`st_config("live_db")` is a **local** path under `tools::R_user_dir()`. Sharepoint only
receives one-way snapshots and backups.

As of 2026-10-21, after the corpus import, 064 and 063:

- analysis 111,642 · sample 21,983 · analyte 247 · lab_method 573 · project 760 (after 071, 2026-10-22)
- feature 1,119 · feature_alias 2,891
- asset 2,264 · ingest_file 1,547
- highest marker 1082 (072 dropped the EPA views; 073/074 fixed the db_checks findings: PLAN-22 C; 075 mapped ALS Thermotolerant Coliforms; 076 removed derived msPAF; 077 claimed the unclaimed-file backlog; 078 recorded past delivery emails; 079 attached the June 2026 Katoomba scans; 080 re-filed the amended reports; 081 settled files left in needs_review; 082 added the SRN receipt schema) (every migration in `dev/migrations/` is applied except PLAN-20's 060)
- review_queue: 6 open after the 2026-10-21 triage (065-067 closed 785 of 791; evidence and
  Robin's rulings in `scratchpad/2026-10-21-review/`): 2 CW-melaleuca items await a COC,
  the Dec 2024 Blaxland gas workbook (a copy of November) awaits ACIRL, MW09 SWL May 2023
  has no field sheet, and 2 unknown_feature items

Suite: **9,832 expectations, 0 failing, 12 skipped** (2026-10-22). Gated corpus tests are skipped unless
`SAMPLETIDY_*_CORPUS` is set.

## Done 2026-10-26 (branch `archive-settle`, not yet on main)

- **Archive settling.** A file store can rewrite an archived file after the
  fact: SharePoint rewrites a metadata block inside old-format Office files
  (.xls/.doc/.ppt), same size, new bytes (migrations 055 and 087 repaired the
  existing cases by hand). Now:
  - `asset.hash` is the stored copy's **settled** hash; `ingest_file(hash,
    uuid_asset)` is the as-received lookup (no schema bump). `archive_file()`
    writes `uuid_asset` on both its new-asset and reuse paths (and fills a
    missing `ingest_file.size`), and dedups through it.
  - Every consumer that starts from a received hash resolves its asset through
    `uuid_asset` first, then `asset.hash` (`.ar_asset_for_hash()`): source
    removal and `removable_pending`, the folder -> project fallback, the stem
    own-bytes exclusion, `.ct_wo_prior_asset_hashes()`, `completed_work()`.
  - `archive_settle()` (exported) re-hashes copies of configured extensions
    archived within `window_hours` and accepts a same-size rewrite (subject to
    an optional `accept()` predicate) via `db_update()`, with a change_log row
    keeping the old hash (reason "storage rewrite"). `ingest_dir()` calls it
    at the start of each write phase; a settle counts as `did_something`.
  - The inbox source of a configured extension is kept for `hold_secs` after
    archiving, then removed when the copy matches the source hash or the
    current `asset.hash`. Other extensions are removed at once, as before.
  - **Off by default:** `st_config("archive_settle", list())` turns it on with
    `ext = c("xls","doc","ppt")`, `hold_secs = 900`, `window_hours = 72`.
- **Still to do:** the backfill migration that sets `ingest_file.uuid_asset`
  for existing rows (from the 055/087 BACKUP old -> new hashes plus every row
  where `ingest_file.hash = asset.hash`; one `ingest_file` row per old hash;
  061's multi-project hashes go to the SKIPPED CSV - spec in the header of
  `tests/testthat/test-archive-settle.R`), then enabling the setting in the
  run configuration.

## Done 2026-10-22

- Migrations 069 (B.L05 coordinates, ES2512129 times, method repairs), 070 (lab_method.fraction;
  views prefer dissolved at groundwater points, total elsewhere) and 071 (60 results R-8.6 had
  dropped) applied to live.
- Code: ESdat "~<N"/NR placeholders; gas template slots skipped; dust `<total` at import; the
  timed rendering wins in assembly; lab methods resolve by method code ("CODE - CODE:" prefix
  stripped, no fallback onto another code); R-8.6 collapses only same-code rows (total and
  dissolved, EA015/EA016 TDS, both naphthalene methods all kept); new lab_methods get a fraction.
- The EPA annual return left the package (PLAN-20 item 9): its script, template, licence
  tables and returns now live in the deployment repo's `epa/` folder, where it reports one
  fraction per sample, point and pollutant (a `fraction` column in the requirements table;
  blank = dissolved at groundwater, total elsewhere). `dev/auto-import.R` reads the licence
  tables from `SAMPLETIDY_AUTOIMPORT_LICENCE_DIR` (default `~/dev/bmcc-monitoring/epa`).

## Done 2026-10-16/17

**Code**
- Dust dating: exposure date → `date_start`, collection date → `date`; sample identity
  uses the Sydney day.
- A77 dust Month/Observations conflicts are withheld into review.
- The ACIRL gas adapter `acirl_gas_xlsx` (PLAN-17).
- A88 adapter review signals and `release_review()`.
- A89: an adapter can declare `zero_is_nondetect`; only gas does.
- A90/R-3.8: a registry fingerprint, so routing verdicts are re-decided when the
  adapter set changes.
- **A91: samples are matched within a contractor stream** (gas / ACIRL / ALS / …). An
  ambiguous match goes to review as `sample_ambiguous` instead of aborting the file;
  this amends A84 for every adapter.
- The gas `#n` building suffix follows row position.
- The EPA report counts sampling events (feature + Sydney day), not sample records.

**Migrations 011–029**, in order:
- LMF deleted;
- detection limits set;
- incombustible dust stored as `<total`;
- gas registry, then dust re-dating (015–021);
- the views fall back to `date`;
- the registry fingerprint column;
- the Aug-2024 duplicate water samples merged (024);
- legacy Appearance split into Stage/Appearance (025, 026);
- doubled legacy field readings removed (027);
- 95 Katoomba gas building points, K.G379–473, unlocated (028);
- legacy field readings corrected from the ACIRL reports (029).

## Next

1. **Gas review items:** B.G201/K.G365/K.G366 are settled (032 removed them). Weekly gas
   reports are filed under their own report numbers. Run script and results:
   `scratchpad/2026-10-17-gaslive/`.
2. **Existing-row lookup:** when two samples match a reading, prefer the one whose
   value equals the incoming row, then the one under the incoming work order. Today
   the lowest uuid wins, which gives false value_conflicts on legacy visits split
   across two ALS work orders. This is being built tests-first.
3. **The corpus run: DONE on live 2026-10-21.** Robin started it; it finished at 18:30
   local. 053-062 were applied by a first attempt (04:27 UTC), which then stopped on the
   test-helper archive-path bug (fixed in f9815b8); the third attempt imported the corpus.
   Measured from `monitoring_pre-corpus-import_20261021T042728Z.duckdb` the result equals
   both rehearsals exactly (+1,885 samples, +7,596 analyses, +643 assets, +770 review
   items); dupcheck 0; Sharepoint snapshot `monitoring_2026-10-21.duckdb`; the post-import
   dedupe moved 937 paths to `assets/_dedupe_quarantine/20261021/` (undo CSV in the work
   dir). 064's CHECK then passed against live and 064 and 063 were applied (07:31 UTC).
   The history below is kept for reference.
   - Code on main:
     - C1-C5 (placeholder matching, ACIRL site veto, per-file date overrides, archive rollback, units);
     - C6: a blank ALS SAR unit becomes "1";
     - C7: blank-date overrides;
     - C8: reused ACIRL report numbers keyed by year, as `<no> (<yyyy>)`.
   - Migrations 053-059, 061 and 062 are rehearsed and NOT applied. 060 is retired (PLAN-20's asset_filing ships via ensure_schema v10). See `dev/MIGRATIONS.md`.
   - 2026-10-21: 054 now records Robin's D11 ruling (ES2006927 stays on 27 Feb 2020; the rev-1 files are ignored for good; the ruling is appended to the project comment). 062 re-files the amended January 2026 report under ES2600194 and runs after 061. 063 (folding the empty duplicate Mar-2024 dust project) was approved by Robin on 2026-10-21 and now runs after 064 (see below). Full chain re-rehearsed twice: identical, dupcheck 0.
   - Run with `dev/corpus-import/apply-corpus-import.sh live <work_dir>` from the repo root on main. It runs, in order:
     - the migrations;
     - the import;
     - `post-import-review.R`;
     - a dupcheck gate, which must report 0;
     - one Sharepoint snapshot;
     - `processed-dedupe.R --post-import`, which only quarantines and can be undone.
   - Both final rehearsals were identical: +1,885 samples, +7,596 analyses, +643 assets, +770 review items, 0 likely duplicates.
   - Decisions and open asks are in `scratchpad/DECISIONS-FOR-ROBIN.md` (2026-10-20 phase 2). Data is in `scratchpad/2026-10-20-corpus/`.
   - **After the import, as a separate step: migration 064 (rehearsed twice, NOT applied).** It restores 72 asset rows that F.18 deleted (NULL filename/hash) and registers 6 more quarantined files, moving 78 files from `assets/_dedupe_quarantine/20261020/processed/` back to `processed/<uuid>/<filename>`. 43 quarantined files are deliberately not restored, as the import re-archives them or they duplicate an asset (`064-...-SKIPPED.csv`). Run `Rscript dev/migrations/064-restore-quarantined-assets-CHECK.R` (read-only; it must print PASS), then `Rscript dev/migrations/apply-064-restore-quarantined-assets.R`. See `dev/MIGRATIONS.md` (1064).
   - **Then, last: migration 063 (approved 2026-10-21; rehearsed twice after 062 and 064, NOT applied; requires marker 1064).** It folds the empty duplicate Mar-2024 dust project c7b61e56 into ff6f23db (moves its xls and PDF rows), merges the two same-bytes PDF rows that leaves in ff6f23db by 057's rules (survivor 91a9c2de, the earliest archive copy; 5aa0c6df deleted), keeps both xls rows (same cells, different bytes) with comments, and deletes c7b61e56. No file is moved or deleted: processed/5aa0c6df-.../ stays as a byte duplicate. Run `Rscript dev/migrations/apply-063-merge-dup-dust-project-mar-2024.R`. See `dev/MIGRATIONS.md` (1063).
4. **Release the A77 dust blocks** for 2400-7453-02 (Jan-2025) and 2400-7538-02
   (Jan-2026, medium confidence) when the corpus run withholds them.
5. **External:** the list in `DECISIONS-FOR-ROBIN.md`, covering ACIRL (analyser LOD,
   the Jan-2026 xls, a reissue of 2400-7453-03-01, the 7127-02/-03 dust, distinct
   building names) and Jane Manners (locating K.G367–378).

## Standing rules that outlive any one session

- **Never re-ingest a work order already in the DB.** `.ct_reingest_guard()` (F.10)
  enforces this. Gas is not covered, so a re-imported gas month must come back
  `already_present`.
- **`remove_ingested` defaults to TRUE**, so ingested sources are deleted from
  `input_dir`. In any dry run, set it to FALSE and point the archive and snapshot
  directories at scratch.
- **Live-DB writes happen only as numbered migrations.** Rehearse each one twice on
  fresh copies, take a verified backup, write CSV row backups and change_log rows, and
  keep to one writer at a time. Claude has standing permission (2026-10-17) to apply
  rehearsed migrations. Read-only inspection is always fine.
- **DuckDB 1.4.1 quirks:**
  - per-row UPDATE or DELETE on FK columns leaves stale index keys, so use set-based
    deletes and re-insert;
  - FK checks do not see deletes made inside an open transaction;
  - an UPDATE under `ux_sample_identity` (alias, datetime, project) runs as a delete
    plus an insert.
- **The Sharepoint tree is Files-On-Demand.** Enumerate it with `ls`/`find`, never
  `grep -r`, and open only the specific files needed.
- **Never run the EPA return script (deployment repo, `epa/`) casually**: its default
  output overwrites Robin's workbooks. Pass `out=` for anything but a filing run.
- **The hourly job reads the licence tables from the deployment checkout** (working copy,
  not a pinned commit): `SAMPLETIDY_AUTOIMPORT_LICENCE_DIR`, default
  `~/dev/bmcc-monitoring/epa`. Keep that checkout on a branch that has them.
- **A-numbers are decisions; agent numbers are lowercase.** A87 was never assigned.
