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
| 1036 | `036-blaxland-mw02-ec-typo.R` | Robin, 2026-10-18 (EC 130 → 1300, option b) | 2026-10-18 (rehearsed twice on copies). Corrects one ACIRL transcription typo: Blaxland B.MW02 field EC, 2026-01-05 (ES2600194, analysis 26ed7d34), `value` 130 → 1300 (ALS lab EC for the same visit is 1300; other B.MW02 EC 1,280–2,000). value_chr / rl / purpose / comments are NULL on the row, so nothing else to keep consistent. Plain db_update, 1 change_log row; lab EC row untouched |
| 1037 | `037-dust-release-mar-jul-2026.R` | main session, 2026-10-18 (A77 release for the Blaxland 2025/26 return, as 035) | 2026-10-18 (rehearsed twice on copies). Releases the 8 A77 dust blocks withheld by the 2026-10-17 email import: 2400-7399-04 (exp 2026-03-01, coll 04-01), 2400-7538-05-02 (04-01/05-01), 2400-7538-06 (05-01/06-01), 2400-7538-07 (06-01/07-01), all high confidence (Observations sheet = report-number convention; the Month cell gave the collection month). Files the 8 new samples under their cited ALS work orders ES2610538/ES2614070/ES2617789/ES2623357 and sets datetime = date on them. sample +8, analysis +32; B.D07/B.D08 go to 9 events each in 2025-08-22..2026-08-21 (no Mar-2026 collection: the 2026 annual's dust block is a stale copy of 2025's) |
| 1038 | `038-dust-sep-2025-from-pdf.R` | Robin, 2026-10-18 (enter Sep 2025 dust from the PDF) | 2026-10-18 (rehearsed twice on copies). Enters the Blaxland dust block exposed 2025-08-01, collected 2025-09-01 (31 d) from ACIRL PDF 2400-7453-09 (no workbook received): B.D07 insoluble 0.2 / combustible <0.1 / incombustible 0.2, B.D08 0.6 / <0.1 / 0.6, Observations "Clear, insects, organic matter, fine brown dusts, coarse black dust." for both. Shaped as 037's released dust (same 4 lab_methods, <0.1 = value 0.1 quantified FALSE, naive-midnight dates, datetime = date, ACIRL / B.Collins); filed under the cited ALS work order ES2528155 (no 2400-7453-09 report project exists and none is created). sample.comments "Entered by migration 038 from ACIRL PDF 2400-7453-09 (no workbook received)"; change_log source_hash = the PDF's hash. sample +2, analysis +8; B.D07/B.D08 go to 10 events each in 2025-08-22..2026-08-21 |
| 1039 | `039-swl-sep-2025-from-pdf.R` | Robin, 2026-10-18 (enter Sep 2025 SWL from the PDF) | 2026-10-18 (rehearsed twice on copies). Enters the standing water levels of the Blaxland Sep 2025 quarterly (visit 2025-09-09, ALS ES2528155) from ACIRL PDF 2400-7453-09 page 2 (no workbook received): B.MW02 4.0, B.MW08 2.8, B.MW09 3.1, B.MW04 10.4, B.MW07 4.6, B.MW11 0.9 m - every SWL the PDF reports (B.MW06 not found, B.CW02 dry, B.L01 blank). One analysis per bore on the EXISTING legacy ACIRL field sample (ES2528155001-006, asserted the only sample of that bore on the Sydney day); lab_method 68484c79 (ACIRL Standing Water Level, analyte Standing water level, m), quantified TRUE, as the workbook rows. Convention proved on Dec 2025 (PDF and workbook both held): the PDF's SWL row equals the stored ES2538342 values exactly (depth in m, positive, no conversion); Sep's PDF prints 1 dp. Refuses if any SWL already exists at those bores that day. analysis.comments "Entered by migration 039 from ACIRL PDF 2400-7453-09 (no workbook received)" (samples untouched); change_log source_hash = the PDF's hash. analysis +6; B.MW04/07/11 go to 4 SWL events and B.MW02/08/09 to 11 in 2025-08-22..2026-08-21 |
| 1040 | `040-reset-es2623357-xtab.R` | Robin, 2026-10-18 (narrow the re-ingest guard; re-import ES2623357 XTAB) | 2026-10-18 (rehearsed twice on copies). Resets ONE ingest_file row so the next ingest re-routes it: the ALS XTAB of ES2623357, `ES2623357_0_XTAB.XLS`, hash b27ec761bfac521faf6dffa8012048c6, archived / retained_sibling -> seen / NULL via the package's own `ingest_file_set_state(..., reset = TRUE)` (the router's reconsider reset); 2 change_log rows (state, state_reason; tbl ingest_file, uuid_row NULL, source_hash = the XTAB's). Asset b56e3eea is kept (archive_file dedupes on hash and reuses it). Refuses unless the row is exactly as described and ES2623357 holds no non-ACIRL sample. BACKUP CSV `040-reset-es2623357-xtab-BACKUP-ingest_file.csv`. **Apply only with the narrowed guard in R/, then ingest straight away**: ingested before the guard change, the XTAB is held as needs_review (work_order_reingest/blocked, 171 rows) and the router will not re-route it again. Re-verify accepts seen, needs_review / commit_event: ES2623357, or archived / commit_event: ES2623357 (re-imported: +171 analyses, +9 ALS samples on a copy) |
| 1041 | `041-gas-grid-unpadded-aliases.R` | Robin, 2026-10-19 ("G1 is G001"); bounded to each padded feature's live window per the coordinator, 2026-10-19 | 2026-10-19 (rehearsed twice on fresh copies taken after that day's 11:50 import, from a HEAD worktree; feature_alias 2288 -> 2479). Registers 191 confirmed `transcription_error` aliases (auto_assign, confirmed_by R. Shannon) of the unpadded gas grid spellings onto the zero-padded registered points, derived from the registry (every `B.G<n>` / `K.G<n>` feature, every shorter zero-padded spelling): B 108 (B.G1-B.G9 and B.G01-B.G09, B.G10-B.G99 -> B.G001-B.G099), K 83 (K.G1-K.G9 -> K.G01-K.G09, K.G26-K.G99 -> K.G026-K.G099); 0 skipped (0 or >1 candidates, name collision or existing key would abort). Each alias carries its feature's own date_start/date_end (B.G0xx end 2023-02-08; K.G0x end 2022-01-01; K.G026-099 2022-01-02..2023-03-08), so post-end "B.G1" readings (2023-03..2024-01 Blaxland workbooks) are NOT mapped. Feature bounds and pending aliases untouched. Does not clear the corpus's 2,918 old-grid gas items: those readings post-date the registered grid end (question for Robin). INSERTED CSV `041-gas-grid-unpadded-aliases-INSERTED-feature_alias.csv` |
| 1042 | `042-dust-release-aug-2026.R` | main session, 2026-10-19 (A77 release, as 035/037) | 2026-10-19 (rehearsed twice on copies of live after 041; applied by Robin's instruction). Releases the 2 A77 dust blocks of 2400-7538-08 (Aug 2026; B.D07, B.D08; exposed 2026-07-01, collected 2026-08-01) under ES2626883: +2 samples, +8 analyses; resolves review items 7ca9aa13…, 59b2b7cf…. The 2400-7453-03 Amended 01 a77 items (stale Feb-2025 copy) stay withheld. |
| 1043 | `043-sep-2025-workbook-supersedes-pdf.R` | Robin's standing "workbook wins" ruling (029/036), applied 2026-10-19 | 2026-10-19 (rehearsed twice on fresh copies of live at 1041, from a HEAD worktree). Resolves the 8 open `value_conflict`/`measurement` review items from the ACIRL Sep 2025 Blaxland workbook (ES2528155, hash 81a09202...) against values 038 (dust) and 039 (SWL) entered from the rounded PDF: B.D07 0.2 -> 0.21, B.D08 0.6 -> 0.57, B.MW02 4.0 -> 3.96, B.MW04 10.4 -> 10.41, B.MW07 4.6 -> 4.58, B.MW08 2.8 -> 2.84, B.MW09 3.1 -> 3.05, B.MW11 0.9 -> 0.93. Precondition: each workbook value rounds to the stored one at the PDF's 1 dp (|diff| <= 0.05); all 8 do. Per pair: `db_update` analysis.value (source_hash = workbook's) and the review item to resolved (`superseded: ...`, resolved_by R. Shannon); 40 change_log rows; no other column moves. Requires 1041 only: independent of 042, either order. BACKUP CSVs `043-...-BACKUP-{analysis,review_queue}.csv` |
| 1044 | `044-gas-grid-retirement-dates.R` | Robin, 2026-10-19 (the registry's retirement dates for the old gas grids are wrong) | 2026-10-19 (rehearsed twice on fresh copies of live at 1043, from a HEAD worktree; verified backup `monitoring_pre-044-gas-grid-retirement-dates_20261019T013139.814Z.duckdb`). Moves feature.date_end of the old gas grids to the day before the successor grid's first sample, all derived from data: successors = gas grid features whose feature_mask `old` name is an old-grid point (B.G182-367, K.G186-364); first sampled 2024-02-19 (B) / 2024-03-04 (K), so B.G001-B.G178 (178) 2023-02-08 -> 2024-02-18 and K.G026-K.G185 (160) 2023-03-08 -> 2024-03-03. Each extended point has its own evidence (12 B / 6 K live samples after the old end, last 2024-01-22 / 2023-12-19). The 182 bounded aliases on them (041's unpadded spellings, B 108, K 74) follow; self/mask aliases are unbounded and untouched. K.G01-K.G24 (end 2022-01-01) have no post-end sample and are untouched, as are successor date_start values (B 2023-02-09, K 2022-03-09 - also earlier than first use; the resolver never reads them). Preconditions: plan exactly as measured, no old-grid sample after the new end, no alias key reaching two live auto arms in the window, no structural-key collision. 520 change_log updates. 0 pending samples in the window. Corpus effect: the 32 old gas workbooks' unknown_feature items 2,943 -> 25 (template slots). BACKUP CSVs `044-...-BACKUP-{feature,feature_alias}.csv` |
| 1045 | `045-katoomba-gas-grid-start-dates.R` | Robin, 2026-10-19 ("Correct Katoomba start dates") | 2026-10-19 (rehearsed twice on fresh copies of live at 1044, from a HEAD worktree; verified backup `monitoring_pre-045-katoomba-gas-grid-start-dates_20261019T025021.773Z.duckdb`). Sets feature.date_start of the Katoomba successor gas grid K.G186-K.G364 (179, derived from feature_mask `old` names matched by point number - K.G232's old name is the typo "K.G99", which 044's literal match missed) from the wrong 2022-03-09 to 2024-03-04, their first sample (Sydney) and the day after the old grid's 044 date_end. Precondition: no successor sampled before the new start (0). No dated aliases on the successors (self/mask_long are undated), so 0 alias rows. 179 change_log updates. Blaxland successors (B.G182-367, date_start 2023-02-09, first sampled 2024-02-19) look inconsistent likewise; NOT changed (not asked). BACKUP CSVs `045-...-BACKUP-{feature,feature_alias}.csv` (alias header-only) |
| 1046 | `046-blaxland-gas-grid-start-dates.R` | Robin, 2026-10-19 ("Same fix for Blaxland") | 2026-10-19 (rehearsed twice on fresh copies of live at 1045, from a HEAD worktree; verified backup `monitoring_pre-046-blaxland-gas-grid-start-dates_20261019T025452.285Z.duckdb`). Blaxland twin of 045: sets feature.date_start of the successor gas grid B.G182-B.G367 (185, derived from feature_mask `old` names matched by point number; no typo'd masks in B) from the wrong 2023-02-09 to 2024-02-19, their first sample (Sydney) and the day after the old grid's 044 date_end. Precondition: no successor sampled before the new start (0). No dated aliases on the successors, so 0 alias rows. 185 change_log updates; Katoomba untouched. Requires 1045. |
| 1047 | `047-blaxland-gas-duplicate-workbooks-ignored.R` | Robin, 2026-10-19 (two Blaxland ACIRL gas workbooks duplicate live visits under wrong header dates; the live dates are right) | 2026-10-19 (rehearsed twice on fresh copies of live at 1046, from a HEAD worktree; verified backup `monitoring_pre-047-blaxland-gas-duplicate-workbooks-ignored_20261019T030156.085Z.duckdb`). Seeds one `ingest_file` row per workbook, state `ignored`, so the router reads the stored state back and skips the file forever: `2400-7286-03-01 March 2023 Monthly Gas ...xls` (xxHash128 5755b9b9ed6a57b6bbc0fee5d822004d, md5 f5b5015d...; header 2023-04-15, same visit as live 2023-03-15) and `2400-7286-12 December 2023 Monthly Gas ...xls` (7a4b94c9cde7fc65216c5246e7056f50, md5 5f5d872f...; header 2023-12-08, same visit as live 2023-12-18). Row shape copies the live claimed-then-ignored XTAB rows (adapter acirl_gas_xlsx / tier format, path_first_seen = the OneDrive asset path, work_order/fingerprint/asset NULL). `ignored` is keyed on content hash alone, terminal, outside both the reconsider and the R-3.8 fingerprint re-decision sets, and an inbox done state, so the file is skipped under any name or path. Also project 2400-7286-12 date_start and date_end 2023-12-08 -> 2023-12-18 (its 178 samples are Sydney 18 Dec; date_end moved too so it does not precede the start); 2400-7286-03-01 already 2023-03-15, untouched. 4 change_log rows (2 ingest_file inserts, source_hash = file hash; 2 project updates). E2E on a copy: ingest_dir (original names, and renamed copies with reconsider = TRUE) and inbox_run both skip the files: 0 events, 0 samples, 0 review items, the inbox folder filed; the same ingest on the pre-047 copy commits 386 duplicate samples and opens 2 review items. Requires 1046. BACKUP CSVs `047-...-BACKUP-{project,ingest_file}.csv` (ingest_file header-only) |
| 1048 | `048-qc-schema.R` | Robin, 2026-10-19 (PLAN-19 rulings R19-1..R19-12, section 8) | 2026-10-19 (rehearsed twice on fresh copies of live at 1047 with FAKE codes, then twice more with the real codes, from a HEAD worktree; verified backup `monitoring_pre-048-qc-schema_20261019T075410.746Z.duckdb`). Schema only: creates `qc_feature` (PK uuid_feature, qc_type NOT NULL), `sample_lab_id` (PK work_order, lab_id), `lab_qc_report` (uuid_asset UNIQUE) and `lab_qc_outlier`, and adds `analyte.lab_contaminant BOOLEAN DEFAULT FALSE` (FALSE on all 247 analytes, R19-10 (2)). The plan's FK columns are not declared as DuckDB FOREIGN KEYs (they would block later UPDATE/DELETE of feature/sample/asset rows). No data, no change_log rows; every pre-existing table count, the analyte table's old columns and the views are checksummed. Requires 1047. |
| 1049 | `049-qc-features.R` | Robin, 2026-10-19 (PLAN-19 R19-1, R19-3, R-19.11) | 2026-10-19 (rehearsed twice on copies with the FAKE fixture, then twice on fresh copies of live at 1047 with the real codes, from a HEAD worktree; verified backup `monitoring_pre-049-qc-features_20261019T075413.138Z.duckdb`). Needs `SAMPLETIDY_QC_CODES` = the Council-only codes CSV (columns `code, qc_type, parent, date_start, comments`), kept beside the vault note *QC Sample Codes - Blaxland* as `attachments/qc-codes.csv` (vault-gitignored); only this migration reads it, not the hourly job. Counts applied: 30 duplicate, 30 field_blank, 30 rinsate_blank, 1 transport_blank, 1 filter_blank; 90 tied to a point, 2 to none. Registers 92 field QC codes (30 points x 3 + 2 tied to no point): 92 virtual, permanent `feature` rows (matrix/location of the parent), 92 self aliases, 92 `qc_feature` rows; no feature_mask. Aborts on an unknown, dead or other-site parent, a duplicate or already-registered code, a count other than 92, or a codes file inside the repo. 276 change_log inserts. Its inserted-row record goes to `snapshot_dir`, never to dev/migrations/ (R-19.11). Requires 1048. |
| 1050 | `050-aug-2026-qc-blanks.R` | Robin, 2026-10-19 (PLAN-19 R19-6, R19-10 (1)) | 2026-10-19 (rehearsed twice on copies after 048/049 with FAKE codes, then twice with the real codes; BACKUP CSVs identical across rehearsals and live; verified backup `monitoring_pre-050-aug-2026-qc-blanks_20261019T075416.390Z.duckdb`). Creates type-only B.JF00 (field_blank) and B.JA00 (source_blank), and points the three ES2626883 pending aliases `Sealed` -> B.JT00, `Bailer/Scoop` -> B.JF00, `Lab sample` -> B.JA00 (descriptive, auto_assign, confirmed_by R. Shannon, bounded 2026-08-19..2026-08-19); resolves their 3 unknown_feature items. Measured: the rows were never withheld - each label's sample is committed on its pending alias (27/28/27 analyses), and `release_review()` cannot release an unknown_feature item (it has no payload rows), so no re-commit is needed. The 8 other source rows sit in units_implausible items shared with the real points (SAR, EC <1, Anions-total) and are untouched. 33 change_log rows. Requires 1049 (B.JT00 comes from the codes CSV). BACKUP CSVs `050-...-BACKUP-{feature_alias,review_queue}.csv` |
| 1052 | `052-lab-qc-backfill.R` | Robin, 2026-10-19 (PLAN-19 R19-5, R-19.17, section 8) | Applied to live 2026-10-19 08:46 UTC (backup monitoring_pre-052-lab-qc-backfill_20261019T084636.697Z.duckdb); live counts equal the two rehearsals (rehearsed on fresh copies of live at 1050, from a HEAD worktree). Runs the package's lab-QC parse step (`.lab_qc_backfill_con()`, the body of `lab_qc_backfill()`) over every `asset` of type 'QC' with an archived copy and no current `lab_qc_report`, in one transaction: inserts only (`lab_qc_report`, `lab_qc_outlier`, their change_log rows), every other table checksummed. Reads the archived PDFs from `archive_dir` (hydrates ~222 files). Rehearsal counts: 222 QC assets (111 QCI, 111 QC), all archived; reports QCI parsed 110, QCI unreadable 1 (ES2607384, 0 bytes), QC partial 109 ("QC.pdf not parsed yet"), QC unreadable 2 (ES2602084 corrupt xref, ES2607384 0 bytes); outliers: ms 135 (4 linked), lcs 2, holding_time 344 (261 linked), frequency 89; 792 change_log rows. Aborts if any report is at another parser version. Requires 1050 (051 is independent and awaits Robin). |

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
    036 ──requires 1035
    037 ──requires 1036
    038 ──requires 1037
    039 ──requires 1038
    040 ──requires 1039
    043 ──requires 1041 (not 1042)
    044 ──requires 1043
    045 ──requires 1044
    046 ──requires 1045
    047 ──requires 1046
    048 ──requires 1047
    049 ──requires 1048   (and SAMPLETIDY_QC_CODES)
    050 ──requires 1049
    052 ──requires 1050
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
