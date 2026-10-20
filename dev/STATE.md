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

The package is built. The registry and the legacy data have been repaired by 29
applied migrations, and ACIRL gas now has an adapter. **The corpus still has not been
ingested**. The ACIRL gas import is done (2026-10-17).

## Live database

`st_config("live_db")` is a **local** path under `tools::R_user_dir()`. Sharepoint only
receives one-way snapshots and backups.

- analysis 97,698 · sample 17,883 · analyte 247 · lab_method 568 · project 571
- feature 1,023 · feature_alias 2,284 (0 pending)
- markers 1..7, 1001, 1003..1033 (every migration in `dev/migrations/` is applied)
- review_queue: 5 open (gas: 2 duplicate_report_number, 1 report_no_mismatch;
  earlier: 1 self_precedence_note, 1 work_order_reingest)
- ingest_file: 52 rows (16 gas workbooks archived 2026-10-17)

Suite: **1,484 tests, 0 failing, 11 skipped**. Gated corpus tests are skipped unless
`SAMPLETIDY_*_CORPUS` is set.

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
3. **The corpus run (2026-10-20): Robin's rulings applied and rehearsed twice; awaiting his go.**
   - Code on main:
     - C1-C5 (placeholder matching, ACIRL site veto, per-file date overrides, archive rollback, units);
     - C6: a blank ALS SAR unit becomes "1";
     - C7: blank-date overrides;
     - C8: reused ACIRL report numbers keyed by year, as `<no> (<yyyy>)`.
   - Migrations 053-059 and 061 are rehearsed and NOT applied. 060 is PLAN-20's. See `dev/MIGRATIONS.md`.
   - Run with `dev/corpus-import/apply-corpus-import.sh live <work_dir>` from the repo root on main. It runs, in order:
     - the migrations;
     - the import;
     - `post-import-review.R`;
     - a dupcheck gate, which must report 0;
     - one Sharepoint snapshot;
     - `processed-dedupe.R --post-import`, which only quarantines and can be undone.
   - Both final rehearsals were identical: +1,885 samples, +7,596 analyses, +643 assets, +770 review items, 0 likely duplicates.
   - Decisions and open asks are in `scratchpad/DECISIONS-FOR-ROBIN.md` (2026-10-20 phase 2). Data is in `scratchpad/2026-10-20-corpus/`.
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
- **Never run `dev/epa-monitoring-report.R` casually**: it overwrites Robin's
  workbooks.
- **A-numbers are decisions; agent numbers are lowercase.** A87 was never assigned.
