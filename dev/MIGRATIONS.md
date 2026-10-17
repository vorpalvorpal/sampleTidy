# Migration register

Every operator migration, its marker, what authorised it, and whether it has been
applied to the live database. **This file is the answer to "has 006 been applied?"** —
previously that fact was spread across ten file headers, a scratchpad checkpoint and
`schema_version`, and the three disagreed.

Migrations are **operator-run**: never invoked by package code, `sys.source()`d into a
fresh environment with the package loaded via `pkgload::load_all(".")`. Each takes its
own verified backup to `st_config("snapshot_dir")` before writing.

Live database: `st_config("live_db")` =
`/Users/rjs/Library/Application Support/org.R-project.R/R/sampleTidy/monitoring.duckdb`.
Sharepoint is a **snapshot destination only** — nothing is ever copied back.

## State of the live database

Verified 2026-08-09 against the live file, read-only; 011-016 rows added 2026-10-16; 016 applied and 017 added 2026-10-17; 018-022 applied 2026-10-17; 024 applied 2026-10-17; 023 applied 2026-10-17 (after 024).

| marker | migration | authorised by | applied |
|---|---|---|---|
| 1–7 | `ensure_schema()` ops tables (not a migration) | A2 | 2026-07-23 / 2026-07-26 |
| 1001 | `001-alias-indirection.R` | PLAN-13 | 2026-07-23 |
| *(none)* | `002-registry-remediation.R` | PLAN-14 | 2026-07-23 |
| 1003 | `003-alias-date-bounds.R` | PLAN-15 | 2026-08-08 |
| 1004 | `004-view-repair.R` | PLAN-15 R-15.35 | 2026-08-02 |
| 1005 | `005-preference-rank.R` | A82 | 2026-08-08 |
| 1006 | `006-acirl-transcription-methods.R` | A83 | 2026-08-08 |
| 1007 | `007-registry-rulings.R` | rulings 2026-08-08 | 2026-08-08 |
| 1008 | `008-duplicate-samples.R` | ruling 9, 2026-08-08 | 2026-08-08 |
| 1009 | `009-sample-identity-index.R` | A84 | 2026-08-08 |
| 1010 | `010-aroclor-mixture-names.R` | rulings 2026-08-08 | 2026-08-09 |
| 1011 | `011-delete-lmf.R` | Robin, 2026-10-16 (incl. the LSI mask + 4 guideline rows) | 2026-10-16 |
| 1012 | `012-detection-limits.R` | Robin, 2026-10-16 | 2026-10-16 |
| 1013 | `013-dust-incombustible-upper-bound.R` | Robin, 2026-10-16 | 2026-10-16 |
| 1014 | `014-gas-registry-additions.R` | Robin, 2026-10-16 | 2026-10-16 |
| 1015 | `015-redate-legacy-dust.R` | Robin, 2026-10-16 (dust exposure/collection ruling) | 2026-10-16 |
| 1016 | `016-redate-legacy-dust-2021-22.R` | Robin, 2026-10-16 ("workbook wins; re-date"); applied per ruling 1, 2026-10-17 | 2026-10-17 |
| 1017 | `017-legacy-dust-load-a-exposure-start.R` | Robin, 2026-10-17 (ruling 2) | 2026-10-17 |
| 1018 | `018-legacy-dust-year-out-2020.R` | Robin, 2026-10-17 | 2026-10-17 |
| 1019 | `019-legacy-dust-load-a-2dp.R` | Robin, 2026-10-17 | 2026-10-17 |
| 1020 | `020-import-dust-2019-20.R` | Robin, 2026-10-17 | 2026-10-17 |
| 1021 | `021-dust-datetime.R` | Robin, 2026-10-17 | 2026-10-17 |
| 1022 | `022-view-date-coalesce.R` | Robin, 2026-10-17 | 2026-10-17 |
| 1023 | `023-registry-fingerprint.R` | Robin, 2026-10-17 (R-3.8 / A90) | 2026-10-17 (applied after 024) |
| 1024 | `024-merge-aug24-water-duplicates.R` | Robin, 2026-10-17 (rulings 1-5) | 2026-10-17 |
| 1025 | `025-split-legacy-appearance.R` | Robin, 2026-10-17 (convert legacy ACIRL Appearance to the A76 split) | 2026-10-17 (applied by Robin; rehearsed twice on copies) |
| 1026 | `026-dust-date-start-and-appearance-fixes.R` | Robin, 2026-10-17 (rulings A, B1-B4) | 2026-10-17 (rehearsed twice on copies) |
| 1027 | `027-dedupe-legacy-field-readings.R` | Robin, 2026-10-17 ("Fix those 16 legacy days"; keep rule and exclusions proposed in the file header) | 2026-10-17 (rehearsed twice on copies) |
| 1028 | `028-gas-building-features.R` | Robin, 2026-10-17 (gas-building rulings 1-4) | 2026-10-17, after 027 (rehearsed twice on copies) |
| 1029 | `029-legacy-field-corrections.R` | main session, 2026-10-17, under Robin's "the workbook wins" precedent (016, 019) | 2026-10-17 (rehearsed twice on copies) |
| 1030 | `030-precorpus-fixes.R` | main session, 2026-10-17, on scratchpad/2026-10-17-precorpus/PROPOSAL.md (issues 2, 3) | 2026-10-17 (rehearsed twice on copies) |
| 1031 | `031-datetime-day-typos.R` | main session, 2026-10-17, on scratchpad/2026-10-17-dtmismatch/PROPOSAL.md (3 month/day typos in `datetime`; K.MW11B left) | 2026-10-17 (rehearsed twice on copies) |
| 1032 | `032-letter-o-aliases-and-gas-template-slots.R` | Robin, 2026-10-17 (letter-O codes: "I'm happy for them to be registered now"; B.G201/K.G365/K.G366: "If not, we don't want them") | 2026-10-17 (rehearsed twice on copies, the second interrupted at step B and resumed) |
| 1033 | `033-kl01-alias.R` | main session, 2026-10-17, following Robin's 032 ruling (ALS ES2620363 carries 40 KL01 rows) | 2026-10-17 (rehearsed twice on copies) |
| 1034 | `034-gas-slots-again-and-blaxland-epa-masks.R` | Robin, 2026-10-17 (032 ruling on K.G365/K.G366 re-applied; "Phosphate = P-reactive"); main session for the B.L04 mask and the DO / faecal-coliform masks | 2026-10-17 (rehearsed twice on copies). Deleted the 2 K.G365/K.G366 pending aliases, 4 samples and 4 CH4 0-readings that the 2026-10-17 pending-documents import re-minted (2400-7539-06-02, 2400-7539-09-01) and closed their 4 review items; B.L04 EPA feature_mask name '' -> NULL; EPA analyte_mask rows DO "Dissolved Oxygen" mg/L x1, Faecal Coliforms "Faecal Coliforms" CFU/100mL x100 (stored CFU/mL), P-reactive "Phosphate" mg/L x1. No data-only way exists to make the gas importer skip these labels: the next import of such a workbook re-mints them. 021's re-verify fails on its fixed count (124 dust samples, expected 122) because the same import added 2 ES2531465 dust samples with datetime NULL; not caused by 034 |
| 1035 | `035-dust-release.R` | main session, 2026-10-17, on scratchpad/2026-10-17-dust/PLAN.md (A77 release for the Blaxland 2025/26 return) | 2026-10-18 by Robin (rehearsed twice on copies; independent review). Released 10 A77 dust blocks (2400-7453-08 already_present as a duplicate of ES2525054; 7453-11/-12, 7538-01, 7538-02 medium confidence), re-filed the released samples under ALS ES2537534/ES2538342/ES2600194/ES2604522, relinked the 2025 annual dust off ES2608464 to ES2506846 and reset ES2608464's date_start + 5 asset dates to 2026-03-16, set datetime = date on 10 NULL-datetime dust samples. B.D07/B.D08 now have 5 events each in 2025-08-22..2026-08-21. 021's fixed-count re-verify is now stale (needs "at least 122") |

**001-024 are applied (023 was applied after 024, 2026-10-17).** 011 deleted the derived LMF analyte, its method and 2,267
analyses, plus (FK-forced, Robin approved) its 4 `Leachate Signature Index` `guideline`
rows and 1 `analyte_mask` row; row backups are `dev/migrations/011-delete-lmf-BACKUP-<table>.csv`.
012 sets `rl_low` on H2S (1e-6, 61 rows), CH4 (1e-4, 11,536 rows) and dust-combustible
(0.1, 4 rows) non-detects; `rl_high` untouched (A57). 013 re-marks the 4 dust-incombustible
rows whose sample has a non-detect dust-combustible as `<dust-total` (quantified FALSE,
value = rl_low = total; old values in `013-...-BACKUP-analysis.csv`); after it, 012's
"incombustible untouched" check is skipped once marker 1013 exists. 014 adds 33 gas
features (B.TG385-405 weekly points; K.G367-378 unlocated biofilter points at `K.centroid`),
their self aliases, `B.Weekly n` / `K.Biofilter ...` / `K.Front of Buildings ...` aliases,
and `B.G179-181` -> B.TG179-181 aliases (bare `G179-181` are mask_long aliases of K.G179-181).
015 re-dates the 4 "+1 day" 2024 dust collections (`date` 2 May -> 1 May, 2 Jul -> 1 Jul), dates the
2 undated July-2024 legacy samples (96c5e696 B.D07, e732697d B.D08: exposure 2024-07-01, collection
2024-08-01), writes the period of their 4 "Dust monitoring" child projects, re-points the 2 July
`Appearance` analyses that the 2026-08-09 ingest of 2400-7399-08 put on the June samples, and closes
that ingest's 6 dust `value_conflict` review items via `resolve_review()`. `datetime` and `uuid_project`
are never written (009's unique index; duckdb runs an indexed UPDATE as delete+insert, which the
analysis FK refuses). Row backups `015-redate-legacy-dust-BACKUP-{sample,project,analysis}.csv`.
016 repairs the 2021-22 "load B" dust block: 22 B.D07/B.D08 re-dates to exposure/collection (16 with no
workbook, placed by the load-B rule and flagged in its header), deletes the 2 copy samples bb955fc9 and
bcf15e0f with their 6 analyses, and sets 6 values to the 2 dp workbook (2400-7222-01-02). Row backups
`016-redate-legacy-dust-2021-22-BACKUP-{sample,analysis}.csv`. 017 sets `date_start` = collection - 1
month on the 22 "load A" legacy dust rows (collected 2020-09..2021-01 and 2021-04..2021-09, both gauges);
every one has a workbook (Dust Results Database, 2400-7127-06, 2400-7127-07) confirming `date` is the
collection date, so `date` is untouched. It EXCLUDES the 2021-02-01 and 2021-03-01 rows (0763faf8,
8c8aef7a, 4735d1dd, 20fda4f9), which hold the Jan/Feb-2020 measurements a year out - open, awaiting a
ruling. Row backup `017-legacy-dust-load-a-exposure-start-BACKUP-sample.csv`. Neither writes `datetime`
or `datetime_start`.
018 re-dates those 4 year-out samples to exposure 2020-01-01 / 2020-02-01, collection 2020-02-01 /
2020-03-01 (Dust Results Database, 2400-6989), and sets 8c8aef7a dust-total 13.1 -> 13.06 (the only value
that differed from the workbook). The real Jan-2021 and Feb-2021 exposures are in no file found, so both
gauges have a gap there. `datetime`/`datetime_start` stay 2021-02/-03 as loaded. Row backups
`018-legacy-dust-year-out-2020-BACKUP-{sample,analysis}.csv`. 019 replaces 16 load-A values with the Dust
Results Database's 2 dp figures (the 10 samples collected 2020-09..2021-01; every one of the 30 workbook
values rounds to the stored 1 dp value, none shows `<`; incombustible is 1 dp in the workbook, so none
moves). The 12 load-A samples collected 2021-04..09 have only the 1 dp pdfs and are untouched. Row backup
`019-legacy-dust-load-a-2dp-BACKUP-analysis.csv`. 020 inserts the 22 missing Jul-2019..Jul-2020 exposures
(22 samples, 66 analyses; fixed uuids) mirroring the load-A rows from the same workbook: self aliases,
the ROOT "Dust monitoring" project 230bd429 (not a child project - those carry only the 2022-08+ per-report
rows), organisation/person NULL, Sydney-midnight `date_start`/`date`, `datetime` = `datetime_start` =
collection 11:00 Sydney, Observations text in `analysis.comments`, sample comment "imported 2026-10-17 from
Dust Results Database workbook, migration 020". B.D07 Jul-2019 combustible `<0.1` is stored per 012 and its
incombustible as the 013 `<dust-total` bound (0.64; printed 0.6). Not imported: Days Exposed and the mg
mass columns. Inserted rows dumped to `020-import-dust-2019-20-INSERTED-{sample,analysis}.csv`.
021 ends the "datetime stays as loaded" caveat of 015-020: for all 122 dust samples (61 B.D07, 61 B.D08,
incl. 018's 4 and 020's 22) it sets `datetime` = `date` and `datetime_start` = `date_start`, byte-for-byte
(Sydney midnight held as the UTC instant). Before it, all 122 differed exactly, 116 on the Sydney day, 2 had
NULL `datetime`, and 9 dust rows ranked 2 in `v_measurement`; after it, 0. 009's `ux_sample_identity` blocks
the UPDATE, so 021 drops it (own commit), updates in one transaction (244 `change_log` rows via `db_update`,
actor `021-dust-datetime`), and re-creates it with the exact `duckdb_indexes()` definition inside a
tryCatch/finally that re-creates it on any failure (tested by forcing a mid-transaction abort). A
precondition proves the post-update key set is unique; the index was re-proved to reject a duplicate. Row
backup `021-dust-datetime-BACKUP-sample.csv`.
022 redefines the 5 `v_measurement*` views (the only views whose SQL mentions `datetime`) so that the `date`
column and the `preference_rank` partition use `COALESCE(s.datetime, s.date)`: exactly 2 text substitutions
per view in the `duckdb_views()` SQL, everything else byte-identical, re-read SQL checked equal to the plan.
The `s.datetime AS datetime` output column is deliberately unchanged. After it no view row has a NULL `date`.
Old definitions in `022-view-date-coalesce-BACKUP-views.csv`. Measured effect (021+022 vs before, on
`v_measurement`; `_long` identical, `_epa` 433/133/47, `_gas_report` and `_old` unchanged): 451 rows changed -
372 dust rows (own date/datetime), 46 rows of the 10 pipeline-ingested 2024-08-07 Blaxland water samples that
have NULL `datetime` (now dated), and 33 rank-only changes on non-NULL-datetime water rows in the same
2024-08-07 partitions (those 10 samples duplicate the field readings of that visit; they now compete in the
ranking, winning on field-beats-lab or on the uuid tiebreak). `dev/epa-monitoring-report.R` reads base
tables, not the views: its 2023-24, 2024-25 and 2025-26 Katoomba workbooks are value-identical before/after.
023 adds the nullable `ingest_file.registry_fingerprint` (also ops-schema version 8 in
`ensure_schema()`), no backfill: every existing row is NULL and its registry verdict is re-decided
once on the next route (A90). Rehearsed twice on a copy of live (dry run, migrate, re-run = no-op);
a dry-run route against the migrated copy succeeds.
024 merges the 10 duplicate 2024-08-07 Blaxland water samples (B.MW02/08/09, S01/03/05/06/10/22, E01 via
alias B.EO1; NULL `datetime`, project ES2425916) that the 2026-08-09 ingest of 2400-7399-08 created beside
their legacy twins: 28 pure-duplicate analyses deleted, 13 new ones (field EC x9, Stage x4) re-pointed onto the
twins, and for the 5 Appearance conflicts (S01/S03 "Low flow clear", S05 "Mod Level Clear", S22 "cloudy", E01
"Slightly Cloudy") the pipeline's A76-split value re-pointed onto the twin and the legacy row deleted; then the
10 emptied samples deleted in a separately committed step. It also merges ACIRL lab_method 45a8fbd1 "Standing
water level" into 68484c79 "Standing Water Level" (3 2023-10-10 analyses moved by delete + same-uuid re-insert,
because duckdb 1.4.1 keeps a stale FK index key after per-row deletes/updates of `analysis.uuid_lab` and then
refuses the lab_method delete; the 6 rows go in one set-based DELETE). B.EO1 alias, projects and assets kept.
After it a dry-run re-ingest of the archived workbook (its `ingest_file` row removed, copy only) yields 0 new
rows. Row backups `024-merge-aug24-water-duplicates-BACKUP-{analysis,sample,lab_method}.csv`.
026 (A) sets `date_start` AND `datetime_start` (021's dust invariant) back one month on the 4 legacy dust samples
of 2400-7453-03 (a0948ef0 B.D07, 3ff06304 B.D08: exposed 2025-02-01) and 2400-7453-08 (f2b590d1, c11dbd53: exposed
2025-07-01); `date`/`datetime` (collection) untouched, Sydney midnight as the UTC instant like every dust row.
After it no dust sample has exposure and collection in the same month. (B1) swaps `value_chr` between the
Appearance and Stage rows of L.L01/L.L02 2023-11-22 into the adapter's terms (L.L01 Stage "Low level" /
Appearance "Slightly cloudy"; L.L02 "Pooled" / "Cloudy"). (B2) deletes the B.S10 2024-08-07 legacy Appearance
"Dry" (11ec50bf; Stage "Dry" kept). (B3) moves the 22 legacy "no water / other" Appearance texts ("Couldnt find",
"Decomissioned", ...) into their sample's `comments` and deletes the rows, leaving those 22 samples with no
analyses. (B4) appends 025's dropped K.S09 2024-03-04 note "Only field data collected, will be sampled in April"
to that sample's comments. 23 deletes in one set-based DELETE. 025's re-verify skips its "excluded pairs
untouched" check once 1026 exists. A dry-run re-ingest of 2400-7346-02 (Lawson Nov-2023) goes from 4
value_conflicts (exactly the 4 swapped rows) to 0; 2400-7399-08, 2400-7453-03 and 2400-7453-08 are unchanged
(the dust rows are A77-withheld, with exposure/collection equal to what 026 writes). Row backups
`026-dust-date-start-and-appearance-fixes-BACKUP-{analysis,sample}.csv`.
027 deletes 16 redundant ACIRL field analyses on 5 legacy feature-days where one visit sits under two ALS
orders and the same field readings were loaded into both samples: 2022-06-22 B.S01/S03/S05 (drop ES2222088, keep ES2222099),
2022-09-07 B.S01 (drop ES2232312, keep ES2232317), 2023-09-13 B.E01 (drop 4 on ES2331527, keep the 5 on ES2331525). Keep rule:
(1) a copy its own order's ACIRL report contradicts goes; (2) else keep the sample holding the visit's complete field set;
(3) else keep the sample at the observed time (the legacy twin is +1 minute); else exclude. Of the 16 MERGED+MERGED days in
`scratchpad/2026-10-17-acirlmatch/DESIGN.md`, 9 hold DIFFERENT readings (two field reports, one per order) and 2 identical ones
are unsettled (2022-09-07 B.S03, 2023-05-10 B.S01); all 11 are excluded and listed in the file header. No sample is emptied or
deleted. One set-based DELETE. 025's re-verify skips the B.E01 pair 027 deleted once marker 1027 exists. Dry-run re-ingests of
2400-7222-09, -09-01, 2400-7286-09, -09-01 give identical outcomes before and after (matches now land on the kept copies).
Row backup `027-dedupe-legacy-field-readings-BACKUP-analysis.csv` (written on apply). Apply with `dev/migrations/apply-027.R`.
028 registers the ACIRL gas-building points (scratchpad/2026-10-17-gasbldg/PROPOSAL.md). (1) 95 new Katoomba features
K.G379-K.G473 in sheet order (`Gas Building 1` -> 379-410, `2` -> 411-446, `3` -> 447-473), copied from 014's biofilter
grids: K/air, permanent, UNLOCATED at the live `K.centroid`, undated, comment naming the sheet, location and reference; each
with its self alias and one `descriptive` alias = the adapter's site-qualified name (e.g. `K.Re-use Center - Toilets-Drain`).
The two repeated references (Re-use Center "Power point back wall" D29/D35 = K.G432/K.G438, Meeting Room "Window wall 2"
D9/D13 = K.G448/K.G452) are told apart only by the adapter's positional `#2`; all 4 comments say so. (2) the 20 pre-Oct-2024
Blaxland building names (May-2021, Aug-2024) become `descriptive` aliases of the existing B.G368-384 (Toilets Right = G373
Women's, Left = G374 Men's, confirmed by Robin). (3) `date_start` 2024-09-01 -> 2021-05-06 and a comment sentence on
B.G368-378/380-383; B.G384 (first named Aug 2024) -> 2024-08-07 (B.G379 untouched). 210 aliases, all unbounded (NULL dates). Requires 1026 only; independent of 027 but
applied after it. A per-file gas ingest of the 16 workbooks on a migrated copy opens 0 building unknown_feature items (control:
316); only B.G201 and K.G365/K.G366 remain. Row backup `028-gas-building-features-BACKUP-feature.csv`; inserted rows in
`028-gas-building-features-INSERTED-{feature,feature_alias}.csv` (both written on apply). Apply with `dev/migrations/apply-028.R`.
029 corrects legacy ACIRL field readings to their own ACIRL report (the report citing the sample's ALS order),
on scratchpad/2026-10-17-fieldconflict/ and scratchpad/2026-10-17-mig029/. (1) 2022-09-07 B.S05 ES2232312 Temperature 14.1 -> 14.7.
(2) Sample 2ad2d3c6 (ES2232312, filed as B.S06) is ALS ES2232312003 = B.S22: the whole sample, with its 3 field and 4 ALS analyses,
is re-pointed to alias B.S22 (e24bdbc4). duckdb refuses the alias UPDATE while analyses reference the sample, so there are two
commits on two connections: (A) one set-based DELETE of its 7 analyses, then (B) the re-point, the re-insert of the 7 with the same
uuids (hard-coded in the file), every value update, the marker. A re-run after a failed B resumes at B. (3) 2023-09-13 ES2331527:
the legacy whole-sample S01/S03 swap (a lab correction) stays, but the 6 T/pH/EC values are swapped back between 63400f6e (B.S01)
and 316ea653 (B.S03). The values are swapped in place, with no row moves; the pairs are identical in every other column.
(4) EC precision: of the 45 legacy field EC values with a fractional part, 30 are set to their own report's cell (29 roundings,
plus 2022-09-07 B.MW09 333.8 -> 339, which is not a rounding). 11 already equal their report and are kept. 4 are excluded: 2022-08-31
B.S01/S03/S05, whose only source is a dehydrated pdf, and 2023-05-15 B.S05, whose report prints 1406, a slipped decimal (ALS 141).
37 value updates in all. Re-verifies of 021 and 024-028 pass unchanged on the migrated copies, so no skip was needed. A dry-run
re-ingest of 20 workbooks takes value_conflicts from 69 to 32; for the original ten workbooks it goes from 38 to 18. Every
planned row comes back already_present, except 3 EC rows where the two reports disagree and `.rc_find_existing()` takes the
other order's copy. Row backups are `029-legacy-field-corrections-BACKUP-{analysis,sample}.csv`, written on apply. Apply with
`dev/migrations/apply-029.R`.
030 fixes two things found before the corpus run (scratchpad/2026-10-17-precorpus/PROPOSAL.md; rehearsal and research in
scratchpad/2026-10-17-mig030/). (1) Four legacy samples of 2023-06-14 get the UTC instant of the local time in their own comment
(AEST, +10): ES2320105 B.S01 6494ece7 09:30 -> 2023-06-13 23:30 and B.S03 d1fd0ab7 09:15 -> 23:15 (the fabricated local time was
stored as UTC, a 10-hour slip); ES2320129 B.S01 6a463a90 22:25 -> 23:25 and B.S03 7505ed39 22:10 -> 23:10 (converted at +11 in
June; comment is the only source). `datetime_start` (equal to `datetime` on all four) moves with it; `date` is unchanged (already
2023-06-14 Sydney midnight); `analysis` has no datetime column, so its 94 rows are untouched. 021's three-commit index sequence:
DROP `ux_sample_identity`, one transaction, re-create it with 009's definition in a finally; a precondition proves no
(alias, datetime, project) collision. (2) `b.eo1` -> B.E01 (transcription_error, 4295a6e1): `date_start` 2024-08-07 -> NULL (A78:
a transcription error has no window), so the Feb-May 2024 B.EO1 rows resolve instead of going to review. A probe of all 1,881
alias keys at 12 dates changes only `b.eo1` before 2024-08-07. The gas points B.G201/K.G365/K.G366 (PLAN-17 ruling 8) are NOT in
030: featureSFC holds none of them. change_log +9. Row backups `030-precorpus-fixes-BACKUP-{sample,feature_alias}.csv` (written on
apply). Re-verifies of 021 and 024-029 pass unchanged on the migrated copies. Apply with `dev/migrations/apply-030.R`.
032 applies two of Robin's 2026-10-17 rulings (rehearsal and research in scratchpad/2026-10-17-mig032/). (1) Nine undated
`transcription_error` aliases, confirmed_by R. Shannon, auto_assign TRUE, n_seen 0: K.SO9 -> K.S09, K.SO6 -> K.S06, K.SO7 -> K.S07,
B.LO1 -> B.L01, B.LO2 -> B.L02, B.SO5 -> B.S05 (letter O for 0) and KS07 -> K.S07, KS05 -> K.S05, KE01 -> K.E01 (dropped dot). They are
registered by hand, which Robin's ruling allows in place of A78's review-and-confirm, and undated so that earlier workbooks resolve (the
b.eo1 trap). Before inserting, the migration checks that no existing key or name (case-insensitive) is taken and that no folded-key twin
(`.rc_method_key`) points at another feature. Excluded as unruled or ambiguous: KL01, "K.E02/K.SO6", "B.SO1 S1", "B.SO3 S3". A resolver
probe of the 111 swept `feature_raw` values at 4 dates changes only these 9 (pending -> hit). (2) B.G201, K.G365 and K.G366 match no
located feature at their site. The same numbers exist at the other site (K.G201 at Katoomba, B.G365/366 at Blaxland), but those are
different probes with their own readings on the same days. So the migration deletes the 9 zero CH4 readings, their 9 samples and the 3
pending aliases, and closes the 9 unknown_feature/structural review items as resolved by R. Shannon, citing the ruling. Three commits
(analyses, then samples, then aliases + inserts + review closes + marker), because duckdb's FK check does not see an earlier delete in
the same transaction. A re-run resumes at the first unfinished step. change_log +66. Row backups
`032-...-BACKUP-{analysis,sample,feature_alias,review_queue}.csv`; inserted aliases `032-...-INSERTED-feature_alias.csv`. Apply with
`dev/migrations/apply-032.R`. No DB change, recorded here (Robin, 2026-10-17): K.MW11B Mar-2023 (b7286aa9) stays as it is ("probably
lost to the sands of time"); the 4 bore-height rows at 2024-08-26 22:00 local (B.MW02/04/08/09) stay ("If they are in the db, assume
they are meant to be there").
033 registers KL01 -> K.L01 as an undated `transcription_error` (dropped dot) alias, the same row shape as 032's KS07/KS05/KE01.
032 had left it out, but ALS ES2620363 (not yet imported) carries 40 KL01 rows. K.L01 is the only `.L01` feature at site K and is in use.
No alias has key or name `kl01`. Its folded-key twin is only K.L01's own self alias `k.l01`, and there is no site `KL`. 1 alias row,
1 change_log row, the marker; nothing else changes (checksummed). A resolver probe changes only KL01 (pending -> K.L01). Inserted row
in `033-kl01-alias-INSERTED-feature_alias.csv`. Apply with `dev/migrations/apply-033.R`.
Pre-migration snapshots are in `snapshot_dir` (`monitoring_pre-<name>_<ts>.duckdb`).

## Ordering constraints (enforced in code, not by memory)

    004 ──requires 1001
    005 ──requires 1004
    007 ──requires 1005
    006 ──requires 1007        (and refuses if 1005 is absent)
    016 ──requires 1015
    017 ──requires 1016
    018 ──requires 1017
    019 ──requires 1018
    020 ──requires 1019
    021 ──requires 1020
    022 ──requires 1005, 1021
    023 ──independent
    024 ──requires 1022
    025 ──requires 1024
    026 ──requires 1025
    027 ──requires 1026
    028 ──requires 1026        (independent of 027; applied after it)
    029 ──requires 1028
    030 ──requires 1029
    031 ──requires 1030
    032 ──requires 1031
    033 ──requires 1032
    034 ──requires 1033
    035 ──requires 1034
    003, 008, 009, 010, 011, 012, 013, 014, 015 ── independent

Each dependent migration checks its predecessor's marker and refuses without it, so
the order is verified rather than remembered. 006 gained its 1007 dependency because
three of its rows cannot exist until 007 runs: two link to analytes 007 creates, and
`Total Dissolved Solids` stays blocked by 006's own collision gate until 007 deletes
the ACIRL `field` method.

## Two traps recorded here because they are invisible from the filenames

**1. `002` MUST NEVER BE RUN AFTER `006`.** 002 writes no marker, so nothing stops a
re-run — and a re-run after 006 rewrites 15 fields, including nulling
`lab_method.conversion_constant` (`0.304466905771112 → NA`) on **both** `Nitrite as NO2`
methods. Found only because a rehearsal deliberately re-ran everything. 002 is applied
and must now be treated as spent. The same marker-less design means a fresh database
rebuilt from these migrations needs 002 run in sequence, before 006.

**2. The number `006` was re-used.** `006-review-queue-payload.R` (PLAN-16) held it,
was retired at `bc3d146` when its rows ceased to exist, and the number was then taken
by `006-acirl-transcription-methods.R` at `8135c36`. The live DB's 1006 is the ACIRL
one (`change_log` actor `006-acirl-transcription-methods`, 212 rows). **Any database
that received the old 006 would silently skip the new one** — it would already carry
marker 1006. Nothing in the tree records this except git history and this file. Do not
re-use a retired migration number again.

## Migrations are not covered by any plan

Plans 13 and 14 own migrations 001 and 002. **003–022 belong to no plan** — they were
authorised by rulings and A-numbers recorded in `dev/plans/OPERATING-RULES.md`. That is
deliberate as of 2026-08-09: the plan-driven build closed 2026-07-28, and migrations are
now operational work. The `authorised by` column above is the substitute for plan
ownership, and it is the thing to keep current.
