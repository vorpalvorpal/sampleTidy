# PLAN-19 — QC: field QC samples and ALS laboratory QC

_Status: **PLANNED** 2026-10-19, nothing built. Rulings are Robin's (2026-10-19) unless
marked **[proposed]** (main session's, open to his ruling) or **[to confirm]** (a list or
value Robin must confirm before it is applied live). Migrations start at **048** (046/047
are taken). The first field-QC round is the Blaxland quarterly of **28 Sep 2026**. Its
results have not arrived yet and are due about 30 Oct 2026. Phase 1 (section 9) must be
live before they are imported._

Inputs: SQMP (draft) §2.2 step 6 and §8; Results Received Checklist (draft) §5, §6 and
§8.4–8.5; the Council-only note *QC Sample Codes - Blaxland* (vault, 51.16). The
code→point table in that note is **never** copied into this repo (section 3).
Corpus measurements are in Appendix A.

## 0. Rulings

- **R19-1 (Robin) Proposal A: a QC code is a feature of its own.** It is not an
  attribute of the parent point's sample. A QC sample is an ordinary `sample` row on
  its own QC feature, so it never reaches the EPA return, licence limits, missing
  points or site history.
- **R19-2 (Robin) Pass/fail is computed, not stored.** The flag checks work QC out on
  every refresh. Only the inputs are stored: QC features, the parent links and ALS's
  own reported outliers.
- **R19-3 (Robin) The code→parent mapping is confidential.** It lives only in the
  local DB, Council-side, and never goes to ALS. The status note and
  `.import-status.json` may name the parent point.
- **R19-4 (Robin) Organic vs inorganic** comes from `analyte.type`: `'organic'` is
  organic and everything else is inorganic. Common lab contaminants come from the
  analyte table too, via a new boolean column `analyte.lab_contaminant` (section 2.4).
- **R19-5 (Robin) ALS lab QC is parsed now, not deferred.** Robin: "a failed QC can mean we
  need to redo a point".
- **R19-6 (Robin) Aug 2026 pre-scheme blanks (ES2626883, sampled 2026-08-19).** The
  COC and field sheet record no point. So:
  - `Sealed` (Secondary ID "Trip Blank") becomes an alias of **B.JT00**.
  - `Bailer/Scoop` ("Field Blank") and `Lab sample` ("Lab Blank") become **type-only
    QC features with no parent point**.
  - All three were analysed for NT-14, dissolved/ferrous/ferric Fe and TDS, the same
    suite as B.MW02/08/09.
- **R19-7 (Robin) Later phase:** sampleTidy becomes the source of truth for the
  sampling schedule and produces the schedule xlsx for ACIRL (section 10). This does
  not block the QC alerts.
- **R19-8 [proposed] Channel-A gap.** On routine rounds ALS is subcontracted by ACIRL,
  and Council receives no ALS QC report. That gap is flagged, every round, until the
  reports arrive (`lab_qc_missing`). Robin will ask ACIRL/ALS for the QC Report, the
  QA/QC Compliance Assessment (QCI) and the Sample Receipt Notification.
- **R19-9 [proposed] The ENMRG "QC - Matrix" block stays skipped.** Measured
  unusable: it has no limits, never references our samples, has unreliable units
  and is often empty.

## 1. What exists today (verified on a copy of live at marker 1045)

- `.rc_qc_filter()` (R/reconcile.R ~333) drops every IR row with `sample_type` other
  than `Normal`/`unknown`/NA: LCS, MB, LAB_D, MS, NCP. **Unchanged.** Field QC samples
  arrive as `REG` (that is, `Normal`), so they are committed like any other sample.
- `.ig_retain_siblings()` archives `_QC.pdf` and `_QCI.pdf` as `asset` rows of type
  `QC` (`.ST_RETAINED_ASSET_TYPES`). None is parsed. Live holds 222 QC assets over 110
  work orders, 111 of them QCI.
- The crosstab adapter captures the ALS sample number per column (`lab_sample_id`,
  IR-internal only, A45). It consumes the `Client sample ID (Secondary)` row and
  discards it (~587).
- **No lab sample number is stored in the DB.** `sample` has no such column, and
  `change_log` holds no source refs. A link from an ALS QC row to our sample therefore
  goes through (work order, client sample ID) or a new stored lab ID (section 2.3).
- `analyte.type` has 16 values. 141 analytes are `organic`, and 16 are `QC`
  (surrogates, stored in %). There is no lab-contaminant column.
- `feature.virtual` exists (BOOLEAN). No QC feature exists. The three Aug-2026 blank
  labels are `feature_alias` rows with `kind = 'pending'`, `uuid_feature` NULL and
  `n_seen` 1. Three open `unknown_feature` items on ES2626883 hold the blocked rows,
  30 per label.
- DuckDB 1.4.1 `ALTER TABLE … ADD COLUMN` succeeds on `analyte`, `feature` and
  `sample`. This was tested on a scratch copy.
- **The repo is PUBLIC on GitHub**, and migration `*-BACKUP-*.csv` files are tracked
  (55 of them). This drives section 3.

## 2. Data model

### 2.1 QC features (R-19.1–R-19.4)

- **R-19.1** New table `qc_feature`:

  | column | type | rule |
  |---|---|---|
  | `uuid_feature` | VARCHAR | PK; FK → `feature.uuid` |
  | `qc_type` | VARCHAR NOT NULL | one of `duplicate`, `field_blank`, `rinsate_blank`, `transport_blank`, `filter_blank`, `source_blank` |
  | `uuid_parent` | VARCHAR | FK → `feature.uuid`; NULL for a code tied to no point (B.JT00, B.JL00, the type-only features) |
  | `date_start`, `date_end` | DATE | when the code→parent pairing holds; NULL means open |
  | `comments` | VARCHAR | |

  It is a separate table, not new columns on `feature`, so that "is this a QC feature"
  is one join and the pairing can carry its own dates. A row whose `uuid_feature` is
  itself in `qc_feature` as a parent is an error.
- **R-19.2** Each QC code is a `feature` row: `name` = the code (e.g. `B.JDxx`),
  `site = 'B'`, `matrix` = the parent's (water), `virtual = TRUE`, `permanent = TRUE`.
  It has **no** `feature_mask` rows of any variant, so no EPA, gas or report view maps
  it. It has a self alias (`kind = 'self'`, `auto_assign = TRUE`), as every feature
  has.
- **R-19.3** **Type-only features** (R19-6), with names **[to confirm]**:
  - `B.JF00`: field blank, no point;
  - `B.JA00`: `source_blank`, the "Lab Blank". This is blank water kept back at the lab,
    portion A of AS/NZS 5667.1 cl 5.2.2.

  The `00` suffix follows the scheme's not-tied-to-a-point rule. Neither name can clash
  with the 42–99 point numbers.
- **R-19.4** Helper `.qc_features(con)` returns `data.frame(uuid_feature, name, site,
  qc_type, uuid_parent, parent_name, date_start, date_end)`. Every flag check and the QC
  checks read QC membership only through it.

### 2.2 QC never leaks (R-19.5)

- **R-19.5** In `.flags_load()`, a sample whose feature is in `qc_feature` is marked
  `qc = TRUE`. These checks never see a `qc` sample: `missing_point`,
  `missing_analytes`, `licence_limit`, `gas_criterion`, `site_history`, `rl_change` and
  `unit_change`. A `qc` sample still evidences delivery for `overdue` and
  `invoiced_not_received`. Test: a QC duplicate whose value breaches a licence limit
  gives no `licence_limit` flag. A blank with a raised RL gives no `rl_change` flag.
  `dev/epa-monitoring-report.R` excludes QC through `feature_mask` (R-19.2). Checking
  that is a calibration step, not a unit test.

### 2.3 Stored lab sample numbers (R-19.6)

- **R-19.6** New table `sample_lab_id(uuid_sample FK → sample, work_order VARCHAR, lab_id
  VARCHAR, client_id VARCHAR, source_hash VARCHAR)`, PK (`work_order`, `lab_id`).
  - The commit stage writes one row per committed sample from the IR's
    `lab_sample_id` and `feature_raw`, but only for adapters whose `lab_sample_id` is a
    real lab number: crosstab and ESdat. ACIRL's synthetic `<sheet>!c<col>` id is
    excluded (A45 stands: this table is a lookup and never an identity key).
  - `lab_id` is normalised to `<WO>-<nnn>`. The corpus has three spellings:
    `ES2626883001` in ENMRG/XTAB, `ES2609437-001` in QC.pdf and `ES2609442--001` in QCI.
    `.qc_norm_lab_id()` maps all three to `ES2609442-001`.
  - A sample that merges rows from two work orders gets two rows. This table is new
    because a sample can carry several lab numbers.

### 2.4 `analyte.lab_contaminant` (R-19.7)

- **R-19.7** `ALTER TABLE analyte ADD COLUMN lab_contaminant BOOLEAN DEFAULT FALSE`
  (migration 048). The blank check uses factor 10 where it is TRUE and 5 otherwise.
- **Measured: the analyte table holds none of the usual lab contaminants.** There is no
  acetone, methylene chloride/dichloromethane, 2-butanone (MEK) or phthalate ester. Of
  the USEPA-convention list, only **Toluene** is present.
- Proposed set for migration 051 **[to confirm]**: `Toluene`. Migration 051 sets
  nothing until Robin confirms.
- When an analyte from the convention list is registered later (acetone, 2-butanone,
  methylene chloride, bis(2-ethylhexyl) phthalate, di-n-butyl phthalate), its
  registering migration sets the flag.

### 2.5 ALS lab QC storage: **stored rows, parsed once at ingest** (R-19.8–R-19.9)

**Decision.** Parse each QCI (and later each QC.pdf) once, when it is archived, and store
the rows. Re-parsing every run was rejected, for three reasons:
- the archived PDFs sit on OneDrive Files-On-Demand, so every hourly refresh would
  hydrate them;
- parsing would make PDF tooling a runtime dependency of a read-only status refresh;
- a parse failure would surface as a flag error every hour instead of once.

Storing outliers is not storing pass/fail (R19-2). These rows are ALS's reported facts.
The checks decide what they mean.

- **R-19.8** `lab_qc_report`, one row per parsed asset: `uuid` PK, `uuid_asset` FK →
  `asset` (UNIQUE), `work_order`, `kind` (`QCI` | `QC`), `issue_date` DATE,
  `n_received` INT, `n_analysed` INT, `summary` VARCHAR (JSON: one boolean per
  Summary-of-Outliers bullet, keys `mb, dup, lcs, ms, surrogate, holding_time,
  frequency`), `status` (`parsed` | `partial` | `unreadable`), `message`,
  `parser_version`, `parsed_at`.
- **R-19.9** `lab_qc_outlier`, one row per outlier record: `uuid` PK, `uuid_report` FK,
  `work_order`, `kind`, `method` (the method code, e.g. `EK055G`), `method_name`,
  `analyte_raw`, `cas`, `lab_id` (normalised, or NULL), `qc_lot` (e.g.
  `QC-MRG2-4858132002`, or NULL), `client_id`, `uuid_sample` (FK, NULL when unlinked),
  `data_raw`, `value_pct` DOUBLE, `limit_low`, `limit_high`, `comment`,
  `days_overdue` INT, `date_analysed`/`due_analysis`, `date_extracted`/`due_extraction`
  DATE, `source_page` INT.
  - `kind` ∈ `ms`, `lcs`, `mb`, `dup`, `surrogate`, `holding_time`, `frequency`. `mb`,
    `dup` and `surrogate` never occur in the corpus, but the parser accepts them.
  - **Re-parse rule:** a newer `parser_version` deletes and re-inserts the report's
    rows in one transaction. This is the one place rows are replaced.

## 3. Confidentiality: where the code→point table lives

- **R-19.10** The mapping exists in exactly two places: the Council-only vault note
  and the live DB (with its OneDrive snapshots, which are Council-only). It is
  **never** in git. That covers:
  - code, tests and fixtures;
  - migration headers and `*-BACKUP-*.csv`;
  - MIGRATIONS.md, commit messages, `dev/expected_schedule.csv` and this plan.
- **R-19.11** Migration 049 reads the mapping from a CSV at a path given by the env var
  `SAMPLETIDY_QC_CODES`, with no default. Robin keeps that CSV beside the Council-only
  note in the vault (`51.16 …/attachments/qc-codes.csv`), so it has exactly the
  exposure the note already has.
  - Columns: `code, qc_type, parent, date_start, comments`.
  - The migration aborts if the variable is unset or the file is inside the repo
    (`normalizePath()` prefix check).
  - Its row backups go to `st_config("snapshot_dir")`, never to `dev/migrations/`.
  - Its header and MIGRATIONS.md row state **counts only**: 30 points × 3 + 2 tied to no
    point = 92 codes.
- **R-19.12** `.gitignore` gains `qc-codes*.csv`, `**/qc-codes*.csv` and
  `dev/migrations/049-*-BACKUP-*.csv` as a backstop.
- **R-19.13** Tests use an invented site `Q` with invented codes and parents (fixture
  `tests/testthat/fixtures/qc/qc-codes-FAKE.csv`). No real `B.J…` code may be paired
  with a real point in any committed file. A lint test fails the suite if a committed
  file contains `B\.J[DFR](?!00)[0-9]{2}` (PCRE) within 200 characters of `B\.(MW|S|L|E|CW)[0-9]`.
- Real-fixture anonymisation (REAL-FIXTURES.md) applies to every QCI/QC fixture: point
  and place names are mapped, ALS data are kept byte-for-byte.

## 4. Ingest changes

- **R-19.14 Crosstab Secondary-ID.** The `Client sample ID (2nd|Secondary)` row is
  captured per column into a new IR column `secondary_id` (character, NA when empty) and
  no longer thrown away.
  - Measured: of 43 ENMRG files, only ES2626883 fills it. It holds three blank-type
    labels, then the EPA point numbers `12, 23, 24, 18, 20` for real points.
  - `.qc_secondary_type(x)` maps, case-insensitive and whitespace-trimmed:
    - `Field Blank` → `field_blank`
    - `Trip Blank`, `Transport Blank` → `transport_blank`
    - `Rinsate Blank`, `Equipment Blank` → `rinsate_blank`
    - `Filter Blank` → `filter_blank`
    - `Lab Blank` → `source_blank`
    - `Duplicate`, `Field Duplicate`, `Dup` → `duplicate`
    - anything else → NA.
  - Use 1: when a row's primary ID is unresolved and its secondary type is not NA, the
    `unknown_feature` review payload gains `qc_hint = <qc_type>`.
  - Use 2: when the primary resolves to a **non-QC** feature and the secondary type is
    not NA, a non-blocking review item `qc_label_conflict` is raised. Its payload
    carries `feature_raw`, `secondary_id` and the resolved feature.
  - A numeric secondary ID is never used for resolution.
- **R-19.15 Field QC samples commit as normal samples** once their features exist
  (migration 049): `B.JDxx` resolves through its self alias. Nothing in reconcile or
  commit changes, apart from R-19.6.
- **R-19.16 Lab-QC parse step.** In `.ig_retain_siblings()`, inside the same
  `db_transaction()` that writes a `QC`-typed asset, call `lab_qc_ingest(con,
  uuid_asset, path)`.
  - It reads the text with `pdftools::pdf_text()` (pdftools goes back into `Imports`).
    Its output matches `pdftotext -layout` line for line on ES2609470.
  - It dispatches on the filename token: `_QCI` → the QCI parser (phase 1b), `_QC` →
    the QC parser (phase 3; until then a `lab_qc_report` row with status `partial` and
    message `QC.pdf not parsed yet`).
  - It writes `lab_qc_report` and `lab_qc_outlier` and links the outliers (R-19.20).
  - **A parse failure never blocks retention.** It writes the report row with status
    `unreadable` and the message. The archive and state transition still land.
- **R-19.17** `lab_qc_backfill(db, actor)` (exported, operator-run) applies
  `lab_qc_ingest` to every `QC`-typed asset whose archived copy exists and has no
  `lab_qc_report` row of the current `parser_version`. Migration 052 calls it.
- **R-19.18** The parsers are pure functions of a character vector of lines:
  `.qci_parse(lines) → list(header, summary, outliers, warnings)`. They are tested on
  anonymised `.txt` fixtures, extracted with `pdftotext -layout`. One gated corpus
  test (`SAMPLETIDY_QC_CORPUS`) runs `pdf_text()` on real PDFs.

## 5. QCI parser contract (R-19.19–R-19.21; layouts from Appendix A)

- **R-19.19 Header.** `Work Order`, `Issue Date` (dd-Mon-yyyy), `No. of samples
  received` / `analysed` come from page 1's `key : value` grid, which is two columns per
  line. A `Work Order` that disagrees with the filename's work order is a warning, and
  the header wins (as for crosstab Workgroup).
- **Summary of Outliers:** the seven bullets, each led by a stray `l` (a Wingdings
  glyph). Each is either `NO … occur.` / `NO … exist.` (FALSE) or `… exist - please see
  following pages for full details.` (TRUE). Both surrogate phrasings are accepted
  ("For all regular sample matrices, [where applicable to the methodology,] NO surrogate
  recovery outliers occur."). An unrecognised bullet makes the status `partial` with a
  warning, never a guess.
- **R-19.20 Outlier records.**
  - **QC table** (`Outliers : Quality Control Samples`, after page 1):
    - Subsection lines map as follows. `Matrix Spike (MS) Recoveries` → `ms`;
      `Laboratory Control Spike (LCS) Recoveries` → `lcs`; any other `… Recoveries` /
      `Method Blank …` / `… Duplicate …` subsection → `mb`/`dup`/`surrogate` by keyword.
      An unknown one → `partial`.
    - Column x-positions come from that page's header line (`Compound Group Name …
      Comment`). They differ by file, and by page within a file.
    - A record starts at a line whose lab-ID column holds `E[A-Z][0-9]{7}--[0-9]{3}`, a
      `QC-[A-Z0-9-]+` lot or `----`.
    - The method cell (`EK055G: Ammonia …`) may sit on the record's first line or on
      the line before (30 wraps measured). A record with no method of its own inherits
      the previous one.
    - Analyte, Data (`Not` / `Determined`) and Comment wrap onto following lines and are
      joined with one space.
    - `value_pct` is parsed from `NN.N %`. `Limits` `70.0-130%` → 70 and 130; `----`
      → NA.
  - **Holding-time table** (`Outliers : Analysis Holding Time Compliance`, the
    *second* occurrence; the first is the page-1 bullet):
    - A method line `^E…: name`, then a container line with one leading space, then
      client-ID lines with two leading spaces.
    - Client IDs are comma-separated, two per line, continuing until a line without a
      trailing comma.
    - The dates and `Days overdue` sit on the first client line only:
      `Date extracted, Due for extraction, Days, Date analysed, Due for analysis, Days`,
      with `----` for NA.
    - **One outlier row per (method, client ID).**
    - The full "Analysis Holding Time Compliance" listing that follows (✓/✗ per
      sample) is not parsed in phase 1b (phase 3, R-19.36).
  - **Frequency table:** one `frequency` row per QC type × method (method code, QC
    count, regular count, actual %, expected %). It is stored and never flagged.
  - Every repeated page header (`Page : n of m`, Work Order, Client, Project) and any
    `- Continued` suffix is skipped without ending the table.
- **R-19.21 Linking `uuid_sample`**, first match wins:
  1. `lab_id` → `sample_lab_id` (exact). This applies only to a lab ID in the same work
     order; an `Anonymous` row is never linked.
  2. (`work_order`, `client_id`) → the samples of that work order's project whose alias
     resolves from `client_id` by the reconciler's own resolution, live at the sample
     date (`.rc_feature_candidates`). Exactly one sample → linked; zero or several →
     NULL.
  3. Otherwise NULL.

  Measured on the corpus: 140 of 194 holding-time (work order, client ID) pairs in DB
  work orders link by route 2. The misses are mostly 2020-era names, for example
  "Effluent (E1)" and "CW-landslip".

## 6. Flag checks (amends PLAN-18 §4.5)

All of these are read-only and work on the `.flags_load()` image plus QC tables. They
are added to `.flags_checks`, `.flags_meanings` and `.flags_fns` after `unit_change`, in
this order:
`qc_dup_rpd, qc_blank_detect, qc_carryover, qc_missing, qc_unresolved, lab_qc_outlier,
holding_time, lab_qc_missing`.

They assess only **recent deliveries** (R1) and only events on or after the
`qc_requirements.csv` `from` date. A missing `qc_feature` table, or one with no rows,
means no rows and no error; a DB older than 048 still refreshes.

- **R-19.22 New column `action`** goes after `source` in `import_flags()` output and the
  JSON. This amends 4.5's "columns exactly".
  - Values: `resample`, `reanalyse`, `ask_acirl`, `chase`, `qualify`. It is `NA` for
    every pre-existing check.
  - The note line ends with `→ <action text>`, for example `→ resample B.MW04 for
    Ammonia as N`. The text is in `detail`'s last clause, so the line format is
    otherwise unchanged.
  - Every QC flag's `detail` names the **parent point, analyte(s) and round** (`<Mon
    YYYY> quarterly|annual`). This answers "do we need to redo a point?" on the line
    itself.
- **R-19.23 `checks$qc`** is a new element: `list(criteria =, requirements =)`, each a
  CSV path or `data.frame` (section 7). `NULL` disables every `qc_*` check. The
  `lab_qc_*` and `holding_time` checks need only the DB. `dev/auto-import.R` passes the
  `dev/` paths.
- **Pairing a QC sample with its round** applies to every check below. The round is
  the QC sample's work order project together with its site and Sydney month. The
  parent sample is the sample at `uuid_parent` in the same project. If there is none,
  it is the parent's sample at the same site with a Sydney date within ±3 days, in any
  project **[proposed]**. If there is still none, the parent is unresolved.

Examples use the placeholder `B.JDxx` and invented values. Real lines carry the real
code.

- **R-19.24 `qc_dup_rpd`.**
  - For each recent `duplicate` sample with a resolved parent, each analyte with a
    **lab** result in both is compared. The match is on the same `uuid_analyte` and the
    same method code. Field results are never compared **[proposed]**.
  - Let `L` be the larger `rl_low` of the pair. A non-detect's value is its RL
    **[proposed]**.
    - When both values are ≥ `k × L`, the rule is RPD = |A−B| ÷ ((A+B)/2) × 100 ≤ the
      criterion. `k` = 5 and the limit is 30 (inorganic) or 50 (organic), all from the
      criteria table.
    - Otherwise the rule is |A−B| ≤ `m × L`, with `m` = 2.
    - Both values non-detect is a pass.
  - **Mislabel guard:** when more than half of the compared analytes fail, the flag says
    `duplicate does not resemble its parent: check the label with ACIRL before treating
    as a QC failure`, with action `ask_acirl`. This follows the Checklist §8.5 "held"
    row.
  - Otherwise there is one flag per (duplicate sample), listing the failing analytes
    (≤15, then `+m more`), with action `qualify`.
  - Example: `2026-09-28 B B.MW04 — duplicate B.JDxx: Zinc RPD 61% (>30%), Ammonia as N
    |diff| 0.05 > 2×LOR 0.02 — Sep 2026 quarterly → qualify these results at B.MW04
    for the event`.
  - key `qc_dup_rpd|<qc feature>|<date>`.
- **R-19.25 `qc_blank_detect`.**
  - For each recent blank (any `*_blank` or `source_blank` type), a **detection** is
    any quantified lab result. A blank is never subtracted.
  - The **associated samples** are the non-QC samples of the same round (same work
    order project, same site) that have a result for that analyte under the same
    method:
    - `filter_blank`: only field-filtered methods, by the criteria table's
      `filtered_method_regex`;
    - `transport_blank`: only analytes the transport blank was analysed for.
  - An associated result is **qualified** when it is quantified and < `f` × the blank
    value. `f` is 10 when `analyte.lab_contaminant` is TRUE and 5 otherwise.
  - There is one flag per blank sample:
    - `detail` lists each detected analyte as value and LOR, then `qualifies N results
      at P points: <point analyte value, …>`;
    - `feature` = the parent point when there is one, else the code.
  - A `rinsate_blank` detection says `decontamination failed for the apparatus used
    after <parent>; results sampled with it after <parent> are suspect`. Sampling order
    is not recorded, so every associated result in the round is assessed.
  - The action is `resample` when any qualified result also has a `licence_limit` or
    `site_history` flag in this run, because a contaminated exceedance cannot be
    confirmed. The detail then names those points and analytes. Otherwise the action is
    `qualify`.
  - key `qc_blank_detect|<qc feature>|<date>`.
- **R-19.26 `qc_carryover`** **[proposed rule, criteria-table parameters]**.
  - It applies to a `field_blank` or `rinsate_blank` with a resolved parent. It fires
    when the blank has ≥ `min_analytes` (2) detections, and every detected analyte is
    quantified at the parent in the same round at a value ≥ the blank's.
  - So the blank looks like a dilution of point nn.
  - `detail` gives the blank-to-parent ratio per analyte, plus `ask ACIRL how the
    apparatus was cleaned after <parent>`. The action is `ask_acirl`.
  - key `qc_carryover|<qc feature>|<date>`.
- **R-19.27 `qc_missing`.**
  - For each (site, licensed month) row of `qc_requirements.csv` valid in the month,
    a round counts once any recent delivery has a water sample at that site in that
    month.
  - A requirement `(qc_type, n_min)` is short when fewer than `n_min` QC samples of
    that type are dated in that month at that site, in any project.
  - **A `rinsate_blank` counts as not supplied** when it has any result under a
    field-filtered method (`filtered_method_regex`), or has no total-metals or TOC
    result. The detail says `rinsate blank B.JRxx filtered or wrong suite: not a
    decontamination test`.
  - There is one flag per (site, month), listing the short types. The action is
    `chase`.
  - Example: `2026-09 B — Sep 2026 quarterly: no rinsate blank, no filter blank (need
    field blank, rinsate blank, filter blank, duplicate) → chase ACIRL`.
  - key `qc_missing|site|YYYY-MM`.
  - The round's second work order may still be outstanding. The flag clears when it
    lands, because flags are recomputed.
- **R-19.28 `qc_unresolved`**, one flag per recent QC sample whose pairing fails:
  - its code has no `qc_feature` row live at the sample date;
  - its `duplicate`/`field_blank`/`rinsate_blank` has no parent sample in the round
    (the detail says which);
  - or a `qc_label_conflict` review item is open on its work order.

  The action is `ask_acirl`. key `qc_unresolved|<qc feature or label>|<date>`.
- **R-19.29 `lab_qc_outlier`**, from `lab_qc_outlier` rows of recent work orders.
  Which rows are flagged:
  - `ms` / `dup` / `mb` / `surrogate` linked to one of our samples, with
    `value_pct` outside the limits.
  - `lcs` (batch level, no sample): it applies to **every** sample of the work order
    with a lab result under that method code and analyte. The detail lists the points.
  - Never flagged:
    - `Anonymous` rows (another client's matrix);
    - `ms` rows whose comment begins `MS recovery not determined` (the background is
      ≥ 4× the spike, so this is information only);
    - `frequency` rows.

  How the flag reads:
  - The action is `reanalyse` when the sample date plus the method's ALS due date has
    not passed: ask ALS to re-run. Otherwise it is `qualify`.
  - The detail says `ALS QCI <WO>: <method> <analyte> LCS 90.1% (95.0–113%), recovery
    less than lower control limit — affects B.S01, B.S03`.
  - key `lab_qc_outlier|<WO>|<kind>|<method>|<analyte>|<lab_id or lot>`.
- **R-19.30 `holding_time`**, from `holding_time` outlier rows of recent work orders.
  - There is one flag per (work order, method), listing the linked points and the days
    overdue.
  - **Suppressed** for lab pH (method code `EA005*`) at a sample that has a field pH
    result, because the field pH wins (ruling 2026-07-24). In the corpus that is 137 of
    166 QCIs.
  - The action is `resample` when the method's analytes include a licence-required
    pollutant at a linked licence point (via the requirements and points tables) and
    there is no field substitute. Otherwise it is `qualify`.
  - Example: `2026-03-20 B — ES26xxxxx EP030 BOD analysed 3 days late at B.L01 →
    resample B.L01 for BOD`.
  - Unlinked client IDs are shown raw, in quotes.
  - key `holding_time|<WO>|<method>`.
- **R-19.31 `lab_qc_missing`.** For each recent work order with `als_lab` results that
  has no `lab_qc_report` of kind `QCI` with status `parsed`, the detail is one of:
  - `no ALS QC Interpretive report (QCI) received: ask ACIRL/ALS for the QC report and
    QA/QC compliance assessment` (channel A);
  - `QCI received but unreadable: <message>`.

  The action is `chase`. key `lab_qc_missing|<WO>`.
- **R-19.32 "(QC qualified)".**
  - After all checks have run, `import_flags()` builds a qualification set of
    (sample, analyte, reason) from three sources:
    - `qc_dup_rpd` failures (the parent's results);
    - `qc_blank_detect` qualified results;
    - linked `holding_time` and `lab_qc_outlier` rows.
  - For a `licence_limit`, `site_history` or `rl_change` flag on a qualified result,
    `; QC qualified: <reasons>` is appended to `detail`. Its `key` is unchanged.
  - Test: a licence breach whose result is under 5× a field-blank detection carries
    `QC qualified: field blank B.JFxx Ammonia as N 0.05 mg/L`.

## 7. Data tables (dev/, reviewed by Robin, no confidential content)

- **R-19.33 `dev/qc_criteria.csv`**, read with every column as character. Columns:
  `rule, qc_type, analyte_class, param, value, unit, action, source, status`.
  - `rule` ∈ `dup_rpd, dup_absdiff, dup_lor_multiple, blank_detect, blank_factor,
    carryover, filtered_method_regex, completeness`.
  - `qc_type` is a `qc_type` value or `any`.
  - `analyte_class` ∈ `inorganic, organic, lab_contaminant, any`.
  - `status` ∈ `proposed, adopted`.
  - An unknown `rule` or a missing required rule is an error of the `qc_*` checks.
  - First rows, all `status = proposed`, `source` = SQMP section:

  | rule | qc_type | analyte_class | param | value | unit |
  |---|---|---|---|---|---|
  | dup_lor_multiple | duplicate | any | k | 5 | x_LOR |
  | dup_rpd | duplicate | inorganic | max | 30 | percent |
  | dup_rpd | duplicate | organic | max | 50 | percent |
  | dup_absdiff | duplicate | any | max | 2 | x_LOR |
  | blank_detect | any | any | threshold | LOR | — |
  | blank_factor | any | any | f | 5 | x_blank |
  | blank_factor | any | lab_contaminant | f | 10 | x_blank |
  | carryover | field_blank;rinsate_blank | any | min_analytes | 2 | count |
  | filtered_method_regex | any | any | regex | `^(E[A-Z][0-9]{3}[A-Z]?F\|EG053FG[^:]*\|EP002):` | — |
  | completeness | any | any | min | 100 | percent |

  The regex was measured on live ALS methods: EG020F, EG035F, EG050F, ED093F, EG053FG
  and EP002. Re-measure it when implementing.
- **R-19.34 `dev/qc_requirements.csv`**: `site, months, qc_type, n_min, from, to,
  source`.
  - First rows, all Blaxland, from 2026-09-01:
    - months `3;6;9;12`: one each of `duplicate`, `field_blank`, `rinsate_blank`
      and `filter_blank`;
    - month `3` only: one `transport_blank`.
  - These are **types and counts only**, never codes. Which code is due per event
    belongs to section 10.
  - Katoomba gets no rows until a scheme exists there.

## 8. Migrations (operator-run, rehearsed twice on copies, per MIGRATIONS.md)

| no. | what | needs |
|---|---|---|
| **048** | Schema: create `qc_feature`, `sample_lab_id`, `lab_qc_report`, `lab_qc_outlier`; `analyte.lab_contaminant BOOLEAN DEFAULT FALSE`. No data. Marker 1048 | — |
| **049** | QC features from `$SAMPLETIDY_QC_CODES` (R-19.11): 92 `feature` rows (virtual), 92 self aliases and 92 `qc_feature` rows. Parents are resolved by feature name and must exist and be live. Aborts on any unknown parent, a duplicate code, a code already registered, or a count other than 92 | 048, CSV |
| **050** | Aug-2026 blanks (R19-6): create `B.JF00`, `B.JA00` (type-only); point the pending aliases `Sealed`→B.JT00, `Bailer/Scoop`→B.JF00 and `Lab sample`→B.JA00. Each is set `kind = 'descriptive'`, `auto_assign = TRUE` and **date-bounded to 2026-08-19..2026-08-19**, so a later "Sealed" elsewhere never auto-resolves. Then commit the 90 withheld rows and close the three `unknown_feature` items on ES2626883. **Measure first:** whether `release_review()` can release an `unknown_feature` item. If not, re-commit from the archived ENMRG, as 040 did | 049 |
| **051** | `analyte.lab_contaminant = TRUE` for the confirmed list (proposed: Toluene) | Robin's confirmation |
| **052** | `lab_qc_backfill()` over the archived QC assets (111 QCI + 111 QC). Report counts against Appendix A | phase 1b code |

Each migration writes `change_log` rows. Only 049's backups leave the repo (R-19.11).

## 9. Phasing

**Phase 1: before the Sep 2026 quarterly results land (target 2026-10-27).** One
test-writer and one implementer, per the TDD rule.
- 048, 049, 050 applied live. **Without 049**, every `B.J…` sample arrives as a blocking
  `unknown_feature`.
- R-19.1–R-19.7, R-19.10–R-19.15.
- Flags: R-19.5 (exclusion), R-19.22–R-19.25, R-19.27, R-19.28 and R-19.31
  (`lab_qc_missing`, so the channel-A gap shows from the first round).
- `dev/qc_criteria.csv` and `dev/qc_requirements.csv`, wired in `dev/auto-import.R`.

**Phase 1b: in parallel, before the first requested QCI arrives.** A separate
test-writer and implementer.
- The QCI parser and storage: R-19.8, R-19.9, R-19.16–R-19.21.
- Flags R-19.29, R-19.30 and R-19.32.
- Migration 052, after a calibration run on a copy that must reproduce Appendix A's
  counts.

**Phase 2: after the first QC round has been seen.** R-19.26 `qc_carryover`; 051 (on
Robin's confirmation); criteria `status` moves to `adopted` as Robin rules.

**Phase 3: detail.**
- `_QC.pdf` parser (R-19.35).
- Full holding-time listing against SQMP §6.3, where the SQMP limits are shorter than
  ALS's (R-19.36).
- Blank-suite completeness per SQMP §8.3 (a `dev/qc_suites.csv`).
- An ESdat cross-check where Sample2e/Chemistry2e exist (LAB_D/MS `Parent_Sample`,
  UCL/LCL). **[proposed]**: the ESdat QC rows stay filtered (R-8.1) and are used only
  as a cross-check.
- The receipt temperature check, once SRNs are supplied (none exist in the corpus).

- **R-19.35** (phase 3) `.qc_pdf_parse(lines)`: DUP/MB/LCS/MS tables per `(QC Lot:
  nnnnnnn)` method block. `#` marks a failed value. Lab IDs are single-dash
  `ES#######-nnn`. Rows go to `lab_qc_outlier` only when `#`-marked, with `qc_lot` set.
  The lot→sample link is "every sample of the WO with that method", as for LCS.
- **R-19.36** (phase 3) The holding-time full listing gives per-sample analysis dates.
  These are checked against an SQMP §6.3 table (`dev/holding_times.csv`).

## 10. Later phase: the sampling schedule as source of truth (sketch, open)

Today the schedule is `2026-09 Blaxland Schedule.xlsx`, including its tab *QC samples Sep
2026–Jun 2028*, which pairs each event's QC codes with their points. Two derivatives exist:
`dev/expected_schedule.csv` (hand-built) and the codes note. The direction:

- New tables `schedule_event(uuid, site, date_planned, event_type monthly|quarterly|
  annual, status)` and `schedule_item(uuid_event, uuid_feature, suite, qc_feature NULL)`.
  A QC item names its QC feature, so the pairing stays in the DB (R19-3).
- `expected_schedule.csv` and `qc_requirements.csv` become views or exports of these
  tables. `overdue`, `missing_point` and `qc_missing` then compare against the **exact
  codes due** that event, not type counts.
- `schedule_export(site, from, to, path)` writes the xlsx for ACIRL, including the QC
  tab. That file is given to ACIRL, which may hold the pairing, and **never** to ALS.
  It is written outside the repo.
- Open questions:
  - who edits the rotation (an R function, a vault table, or the xlsx round-tripped);
  - Katoomba;
  - how the schedule records "sample only if flowing";
  - whether `expected_schedule.csv` history (the 2025-07 rows) is migrated or kept as
    a CSV.

## 11. Open questions for Robin

1. Names for the type-only features: `B.JF00` (field blank) and `B.JA00` (lab/source
   blank)? (R-19.3)
2. Lab contaminants: the table has only Toluene from the usual list. Is it Toluene
   alone, or none for now? (R-19.7)
3. Duplicate comparison: lab results only, a non-detect taken at its RL, and "> half of
   analytes fail → suspect mislabel". Are these right? (R-19.24)
4. Rinsate and field-blank qualification applies to every sample in the round, since
   sampling order is not recorded. Should the field sheet's sampling order be captured
   instead? (R-19.25)
5. Carry-over rule: ≥2 detections, all ≤ the parent. Adopt as proposed? (R-19.26)
6. Fallback parent pairing within ±3 days when the duplicate and parent arrive in
   different work orders: acceptable? (section 6)
7. Should `qc_missing` wait until the round is "complete" (both water work orders
   received), or flag at the first work order? It is proposed to flag at the first.
   (R-19.27)
8. Frequency outliers (76 of 166 QCIs) are stored and not shown. Is that right? (R-19.20)
9. Should `holding_time` use `resample` only for licence-required pollutants, or for
   any analyte? (R-19.30)

## Appendix A — corpus measurements (2026-10-19, read-only)

**Method.** The QCI and QC PDFs come from `…/waste_data - Environmental
monitoring/assets/{processed,unprocessed}/` (none were in `input/`), converted with
`pdftotext -layout` in the session scratchpad (`plan19/qci/`, `plan19/qc/`). DB facts
come from a copy of live at marker 1045. Scripts: `plan19/q*.R`.

**A.1 Inventory.**
- 171 `*_QCI*.pdf`, 120 in `processed/` and 51 in `unprocessed/`.
- 167 distinct names, 159 distinct work orders, 46 MB in total.
- Bracketed duplicates: `ES2503947_0_QCI[41]`, `ES2509335_0_QCI[7]`,
  `ES2509336_0_QCI[68]`, `ES2515460_0_QCI[1]`, `ES2520710_0_QCI[1]`/`[2]`,
  `ES2609437_0_QCI[26]`.
- One revision `_1`: ES2314369.
- By year: 2020 34, 2021 10, 2022 4, 2023 13, 2024 24, 2025 28, 2026 58.
- **`processed/b7ab659f-…/ES2607384_0_QCI.pdf` is a 0-byte archived copy.** The
  parser must report `unreadable`, not crash.
- `ES2602084_0_QC.pdf` (736 KB) fails in poppler with a corrupt xref.
- 166 QCIs were extracted. They run to 4–14 pages, mostly 7.
- 143 of the 159 work orders are projects in the DB with samples. 16 are not, for
  example ES2110225, ES2310817 and ES2512129.
- Every QCI project is a channel-B (Council-engaged) job: trade waste dam/tanker 27,
  Lawson discharge 30, Katoomba E1/E2 20, rain events 22, and so on. **No routine
  ACIRL-round work order has a QCI.**
- wo-map: 112 work orders have a QCI and 119 ES work orders have none.

**A.2 Summary-of-Outliers bullets, over 166 files.** Each file carries exactly one of
each pair:
| bullet | TRUE ("exist") | FALSE ("NO …") |
|---|---|---|
| Method Blank | 0 | 166 |
| Duplicate | 0 | 166 |
| Laboratory Control | 12 | 154 |
| Matrix Spike | 108 | 58 |
| Surrogate (two phrasings: 92 "where applicable…", 74 short) | 0 | 166 |
| Analysis Holding Time | 143 | 23 |
| QC Sample Frequency | 76 | 90 |

- 159 of 166 have an MS, LCS or holding-time outlier. 7 have none: ES2014537,
  ES2015000, ES2026608, ES2028902, ES2311620, ES2314145, ES2609416.
- LCS outliers are in 12 files: ES2011067, ES2011595, ES2027610, ES2027611, ES2027719,
  ES2027720, ES2028155, ES2028156, ES2028157, ES2028911, ES2303512, ES2401369.

**A.3 QC outlier records.**
- **MS: 184 rows.**
  - 176 are `Not Determined` / "MS recovery not determined, background level greater
    than or equal to 4x spike level".
  - 8 are numeric, all "Recovery less than lower data quality objective", all on
    `Anonymous` samples: ES2238263 Hg 14.6 %, ES2439394 F 28.5 %, ES2512418 F 53.1 %,
    and ES2519223 Be/Cu/Pb/V/NOx.
  - 160 MS rows are on other work orders' samples. **24 are on our own samples, in 17
    work orders, and every one of those is "not determined".**
  - Own-sample client IDs seen include STORMWATER DAM, Attunga Road Seep, Southern
    Batter Seep - Unlined Dam, Old Drain Outlet, K.L04 cutoff wall outlet, B.E01,
    B.S01, Trade Waste Dam and Discharge Point - Lawson STP.
- **LCS: 13 rows in 12 files.** Lab-ID cell `----`. QC lot on the method line, in the
  forms `QC-2947377-002` and `QC-MRG2-3190228002`.
  - 11 are EC low recovery ("Recovery less than lower control limit", 89.8–94.2 % vs
    95.0–113 %).
  - 2 are TKN high (102–103 % vs 69.0–101 %, "Recovery greater than upper control
    limit").
  - **So, in the corpus, the only lab-QC failures that touch our results are
    batch-level LCS failures.**
- **Lab sample ID forms.**
  - In QCI, always a double dash: `ES#######--nnn` (164), `EN…` (12), `ED…` (7),
    `EM…` (1).
  - In QC.pdf, a single dash `ES#######-nnn`.
  - In ENMRG/XTAB, no dash: `ES2626883001`.
  - 30 QCI records have the lab ID alone on its own line, because the method name
    wrapped.
- **Wrapping:** analyte names ("Total Kjeldahl Nitrogen / as N", "Electrical
  Conductivity / @ 25°C"), `Not / Determined` and comments over 2–3 lines.
- **Column x-offsets differ between files and pages.**

**A.4 Holding-time outliers** (143 files). Method blocks by code:

| method | blocks |
|---|---|
| EA005P (lab pH) | 137 |
| EP030 (BOD) | 44 |
| EK057G | 22 |
| EK071G | 17 |
| ED093F | 8 |
| EA065 | 8 |
| EA006 | 8 |
| EP005 | 4 |
| EA025 | 3 |
| EP080/071 | 2 |
| EK067G | 2 |
| EK061G, EK059G, EK055G, EA015 | 1 each |

- 66 of the 143 have a breach other than lab pH.
- 279 client-ID lines carry dates; 114 of them are comma-joined lists.
- Days overdue: 1–16, median 3.
- Layout: method line, then a container line (1-space indent), then client IDs
  (2-space indent), two per line, comma-continued; dates on the first line only.
- Linking: 412 (work order, client ID) pairs. 194 are real IDs in DB work orders, and
  140 of those link through alias→feature sampled in the work order.

**A.5 Frequency outliers** (76 files): MS 66, LCS 23, DUP 14 (+1 continued), MB 1, each
a method × count × rate row.

**A.6 QC.pdf sample** (15 converted). The work orders were chosen to cover every
outlier type:
- ES2011067, ES2015777, ES2027611, ES2028716, ES2234903, ES2238263, ES2303512,
  ES2316355, ES2401369, ES2414680, ES2439394, ES2519223, ES2607367, ES2608963,
  ES2609470.

What they show:
- Sections: `Laboratory Duplicate (DUP) Report` (15), `Matrix Spike (MS) Report` (15),
  and `Method Blank (MB) and Laboratory Control Sample (LCS) Report` (11), spelled
  `… Control Spike (LCS) …` in 4.
- 239 `(QC Lot: nnnnnnn)` method headers.
- `#` marks a failed value; the key reads "# = Indicates failed QC".
- Lab IDs: 537 `ES` rows, plus `EW`, `EN`, `ED`, `EP` and `EB`. 498 rows are
  `Anonymous`.
- Own-sample DUP/MS rows name points, for example B.E01 12, K.S01A 9, B.S01 9 and
  K.E01 8.

**A.7 ENMRG Secondary ID** (43 ENMRG files): it is filled only in ES2626883. The
values are `Lab Blank`, `Field Blank`, `Trip Blank`, then `12, 23, 24, 18, 20` and two
empty.

**A.8 Fixtures for the test-writer** (anonymise per REAL-FIXTURES.md; keep ALS values
byte-for-byte; map point and place names):

| fixture | why |
|---|---|
| ES2609470_0_QCI | MS "not determined" (Anonymous, double-dash ID), pH + BOD holding-time breaches, a frequency outlier |
| ES2027611_0_QCI | LCS low-recovery row with a `QC-MRG2-…` lot, wrapped analyte |
| ES2011067_0_QCI | two LCS rows (EC low, TKN high), the second with no method of its own |
| ES2028911_0_QCI | holding-time multi-ID comma lists over 4 lines |
| ES2028716_0_QCI | own-sample MS rows ("Attunga Road Seep"), lab ID on its own line |
| ES2519223_0_QCI | 5 numeric MS failures, NOx row with no lab ID column value |
| ES2314145_0_QCI | no QC or holding-time outliers, frequency outliers only |
| ES2014537_0_QCI | fully clean |
| ES2607384_0_QCI (0 bytes) | `unreadable` path |
| ES2626883_0_ENMRG.CSV | Secondary-ID row with blank types and EPA numbers |
| ES2609470_0_QC.pdf (phase 3) | DUP/MB/LCS/MS with QC lots, single-dash IDs |
