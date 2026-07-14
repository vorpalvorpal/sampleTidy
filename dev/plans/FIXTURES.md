# FIXTURES — the synthetic universe (shared contract for all test agents)

Every test fixture and seed DB uses **exactly** these values so adapter output,
reconciler seed data, and e2e assertions line up. No real lab data (A3). All
fixtures are synthetic but structurally exact. When a plan criterion needs a
number, it is pinned here; tests assert the pinned number.

Prefix all synthetic UUIDs with a fixed literal (they are just VARCHARs):
features `f-000N`, analytes `a-000N`, lab_methods `lm-000N`, projects
`p-000N`, samples `s-000N`, analyses `an-000N`.

## Seed DB (`tests/testthat/helper-db.R`, owned by the core-tests agent)

`seed_db(dir = withr::local_tempdir())` creates a DuckDB file, runs
`ensure_schema()`, creates the **core** tables with the CONTRACT columns, and
inserts exactly the rows below. Returns the db path. `seed_con(path)` opens RW.
Helpers must not depend on the live monitoring.duckdb.

### feature
| uuid | name | site | flow | matrix |
|---|---|---|---|---|
| f-0001 | T.S01 | TestSite | surface | water |
| f-0002 | T.S02 | TestSite | surface | water |
| f-0003 | T.MW01 | TestSite | (NA) | groundwater |

### feature_mask
| uuid_feature | variant | name |
|---|---|---|
| f-0001 | long | Test Surface 01 |   (alias → resolves to f-0001)
| f-0002 | epa | AMBIG |            (ambiguity fixture …)
| f-0003 | long | AMBIG |           (… "AMBIG" matches f-0002 AND f-0003)

### analyte  (canonical units deliberately differ from reported units to force conversion)
| uuid | name | units | type | CAS |
|---|---|---|---|---|
| a-0001 | pH | pH | field | (NA) |
| a-0002 | Fluoride | µg/L | anion | 16984-48-8 |
| a-0003 | Electrical Conductivity | mS/cm | field | (NA) |
| a-0004 | Temperature | °C | field | (NA) |

### lab_method  (analyte_raw + organisation → uuid_lab → uuid_analyte)
| uuid | uuid_analyte | name | method | organisation | rl_low |
|---|---|---|---|---|---|
| lm-0001 | a-0001 | pH Value | EA005P: pH by PC Titrator | ALS | 0.01 |
| lm-0002 | a-0002 | Fluoride | EK040P: Fluoride by PC Titrator | ALS | 0.1 |
| lm-0003 | a-0003 | Electrical Conductivity @ 25°C | EA010P: Conductivity by PC Titrator | ALS | 1 |
| lm-0004 | a-0002 | Fluoride | EK040T: Fluoride by alt method | ALS | 0.5 |
| lm-0005 | a-0001 | pH | (NA) | ACIRL | (NA) |
| lm-0006 | a-0003 | EC | (NA) | ACIRL | (NA) |
| lm-0007 | a-0004 | Temperature | (NA) | ACIRL | (NA) |

`lm-0002`/`lm-0004` are the duplicate-method pair (R-8.6): same analyte, ALS;
lm-0002 has the lower rl_low (0.1) so it wins.

### project
| uuid | name | type |
|---|---|---|
| p-0001 | XX1234567 | Work order |

### Pre-existing sample + analysis (the "old pipeline already committed this" rows for three-way tests)
sample `s-0001`: uuid_feature f-0001, uuid_project p-0001,
date `2025-05-24`, datetime `2025-05-24 11:45:00` (Australia/Sydney), organisation ALS.
analysis `an-0001`: uuid_sample s-0001, uuid_lab lm-0002, value `100`,
quantified FALSE, rl_low `100`, comments NA.
(That is the converted form of "Fluoride <0.1 mg/L" — see conversions below.)

`ingest_file` seed for the supersede test: a row hash `legacy-hash-XX`,
work_order `XX1234567`, revision `0`, state `archived`.

## Unit conversions (pinned expected numbers)

Reported → canonical (`unify_value`):
- Fluoride `mg/L` → `µg/L`: **× 1000**. `0.1 mg/L → 100 µg/L`; `2.3 → 2300`.
- EC `µS/cm` → `mS/cm`: **× 0.001**. `185 µS/cm → 0.185 mS/cm`; `965 → 0.965`.
- pH `pH` → `pH`: unchanged (dimensionless alias).
- Temperature `°C` → `°C`: unchanged.

## Work orders & files

### ESdat (plan 04, `fixtures/esdat/`)
Stem `PROJ_A.ESDAT_XX1234567_0` with three parts; plus lone
`PROJ_B.ESDAT_XX7654321_0.Sample2e.CSV`.

**Chemistry2e** columns exactly: `SampleCode,ChemCode,OriginalChemName,Prefix,
Result,Result_Unit,Total_or_Filtered,Result_Type,Method_Name,Extraction_Date,
Analysed_Date,EQL,EQL_Units,Comments,Lab_Qualifier,UCL,LCL`. Rows for XX1234567
(3 samples × the analytes) plus 2 QC rows and 1 NCP row. Pin these data rows:

| SampleCode | ChemCode | OriginalChemName | Prefix | Result | Result_Unit | T/F | Method_Name | EQL |
|---|---|---|---|---|---|---|---|---|
| XX1234567001 | (blank) | pH Value | (blank) | 6.40 | pH Unit | T | EA005P: pH by PC Titrator | 0.01 |
| XX1234567001 | 16984-48-8 | Fluoride | < | 0.1 | mg/L | T | EK040P: Fluoride by PC Titrator | 0.1 |
| XX1234567001 | (blank) | Electrical Conductivity @ 25°C | (blank) | 185 | µS/cm | T | EA010P: Conductivity by PC Titrator | 1 |
| XX1234567002 | 16984-48-8 | Fluoride | (blank) | 2.3 | mg/L | T | EK040P: Fluoride by PC Titrator | 0.1 |
| XX1234567002 | (blank) | Electrical Conductivity @ 25°C | (blank) | 965 | µS/cm | T | EA010P: Conductivity by PC Titrator | 1 |
| XX1234567003 | (blank) | Fluoride | > | 2000 | mg/L | T | EK040P: Fluoride by PC Titrator | 0.1 |
| XX1234567003 | (blank) | Observation | (blank) | Clear, low flow | (blank) | T | (blank) | (blank) |
| QC-000001 | 16984-48-8 | Fluoride | (blank) | 0.5 | mg/L | T | EK040P: Fluoride by PC Titrator | 0.1 |
| QC-000002 | (blank) | pH Value | (blank) | 7.00 | pH Unit | T | EA005P: pH by PC Titrator | 0.01 |
| YY0000001 | 16984-48-8 | Fluoride | (blank) | 1.0 | mg/L | T | EK040P: Fluoride by PC Titrator | 0.1 |

Analysed_Date `26 May 2025` for all; Extraction_Date blank or `26 May 2025`.
The `Observation` row is the text-value branch. The QC rows' Sample_Type comes
from Sample2e (below); the `YY0000001` row is the NCP/foreign-work-order row.

**Sample2e** columns exactly: `SampleCode,Sampled_Date_Time,Field_ID,Blank1,
Depth,Blank2,Matrix_Type,Sample_Type,Parent_Sample,Blank3,SDG,Lab_Name,
Lab_SampleID,Lab_Comments,Lab_Report_Number`. Rows:

| SampleCode | Sampled_Date_Time | Field_ID | Matrix_Type | Sample_Type | Parent_Sample | Lab_Report_Number |
|---|---|---|---|---|---|---|
| XX1234567001 | 24 May 2025 11:45 | T.S01 | WATER | Normal | | XX1234567 |
| XX1234567002 | 24 May 2025 11:10 | T.S02 | WATER | Normal | | XX1234567 |
| XX1234567003 | 24 May 2025 11:00 | T.MW01 | WATER | Normal | | XX1234567 |
| QC-000001 | | | WATER | LCS | | XX1234567 |
| QC-000002 | | | WATER | MB | | XX1234567 |
| YY0000001 | 20 May 2025 09:00 | (other) | WATER | NCP | | YY0000001 |

**Header.XML**: `Lab_Report_Number="XX1234567"`, `Date_Reported="2025-05-28"`,
`Project_ID="PROJ_A"`, `Lab_Name="ALSE-Sydney"`, EScIS namespace.

Lone `PROJ_B…XX7654321_0.Sample2e.CSV`: 1 Normal row, Field_ID `T.S01`,
`26 May 2025 10:30`, Lab_Report_Number `XX7654321`.

### Crosstab (plan 05, `fixtures/crosstab/`)
`XX1234567_0_XTAB.csv` (latin-1, two stacked sections WATER+the same analytes,
`25¡C` mojibake in the EC group header, no QC), `XX1234567_0_XTAB.xlsx` (same
content — **xlsx substitutes for legacy .xls**; note in README; adapter match
accepts xls|xlsx), `XX1234567_0_ENMRG.CSV` (UTF-8, +2 QC columns Sample Type
`LCS`,`MB`), `ZZ9999999_0_XTAB.csv` (Workgroup cell says `XX1234567` →
mismatch-precedence test). Same samples/analytes/values as ESdat where they
overlap (so cross-format equivalence holds: XTAB regular-sample values equal
ESdat regular-sample values for XX1234567001–003).

Crosstab sample columns = XX1234567001 (T.S01), 002 (T.S02), 003 (T.MW01);
Sample Date `24/05/2025` (d/m/y); values matching the ESdat Result column for
those three samples. `----` in one cell (not-computable branch) and one empty
cell (empty branch).

### ACIRL (plan 06, `fixtures/acirl/`)
`2400-9999-01 Test Month WMF.xlsx` (xlsx substitutes for xls; README notes it):
- front-page sheet (name contains "Front"): `REPORT NO:` → `2400-9999-01`,
  `SAMPLED BY:` → `J. Tester & offsider`, `SAMPLE DATE:` → `24/05/2025`;
- one methods sheet (name contains "Method") — ignored;
- one dust sheet (name contains "Dust") — detected & skipped (R-6.4);
- two water sheets, each: a `Units` marker cell, `^Site Name` header row, a
  date row, field block rows `pH`, `EC`, `Temperature`, `Comments`, then 4
  fake ALS analyte rows **below** the block terminator (these must be dropped,
  `lab_data_dropped`). Two visits (dates `24/05/2025`, `25/05/2025`), features
  `T.S01`, `T.S02`. Units row: pH `pH Units`, EC `µS/cm`, Temperature `oC`.

## Cross-plan expectations (assert these end to end)

- ESdat XX1234567 Chemistry2e → 10 result rows; after Sample2e join, the 3
  Normal samples' rows carry datetimes 11:45/11:10/11:00 and sample_type
  Normal; QC rows carry LCS/MB; YY0000001 carries NCP.
- Assembly event `XX1234567`: NCP row counted (`n_ncp_foreign` = 1), absent
  from results; source-preference keeps ESdat over XTAB/ENMRG.
- Reconcile: T.S01/T.S02/T.MW01 resolve to f-0001/f-0002/f-0003; "AMBIG"
  would be ambiguous; a typo `T.S0l` (lowercase L) → unknown_feature.
  Fluoride `<0.1 mg/L` → value_num 0.1, below_detection TRUE, converted 100
  µg/L, rl 0.1 mg/L → 100 µg/L, quantified FALSE. That row vs seeded an-0001
  (value 100, quantified FALSE) → **already_present**. Fluoride `2.3 mg/L` (no
  seed) → new (2300 µg/L). Fluoride `>2000` → below_detection FALSE via ">",
  quantified FALSE, rl_high 2000, → new. EC 185 µS/cm → 0.185 mS/cm.
- QC filter: LCS + MB rows skipped (`qc_LCS`, `qc_MB`); counts = 1 each.
- Supersede e2e: `XX1234567_1_XTAB.csv` with T.S01 Fluoride changed to
  `0.3 mg/L` → at revision 1 > recorded 0 → supersede an-0001 (or the
  committed row) in place; change_log old/new.

## Fixture README requirement
Each `fixtures/<family>/README.md` records, per structural property, the real
BMCC file it was modelled on (traceability for [MEASURE TWICE]) and notes the
xlsx-for-xls substitution where used.
