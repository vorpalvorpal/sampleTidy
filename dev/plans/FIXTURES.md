# FIXTURES — the synthetic universe (shared contract for all test agents)

Every test fixture and seed DB uses **exactly** these values so adapter output,
reconciler seed data, and e2e assertions line up. No real lab data (A3). All
fixtures are synthetic but structurally exact. When a plan criterion needs a
number, it is pinned here; tests assert the pinned number.

Prefix all synthetic UUIDs with a fixed literal (they are just VARCHARs):
features `f-000N`, feature_aliases `fa-000N`, analytes `a-000N`, lab_methods
`lm-000N`, projects `p-000N`, samples `s-000N`, analyses `an-000N`.

## Seed DB (`tests/testthat/helper-db.R`, owned by plan 11 — A52)

`seed_db(dir = withr::local_tempdir())` creates a DuckDB file, runs
`ensure_schema()`, creates the **core** tables with the CONTRACT columns, and
inserts exactly the rows below. Returns the db path. `seed_con(path)` opens RW.
Helpers must not depend on the live monitoring.duckdb.

**Plan 11 (A48–A51) reshapes this seed.** `sample` no longer points at
`feature` directly — every sample carries `uuid_feature_alias` (NOT NULL),
which nullably resolves to a `feature`. `feature` gains `date_start DATE,
date_end DATE`. `lab_method.uuid_analyte` is nullable (dangling = unresolved
analyte).

> ### Three corrections (2026-07-22) — RESOLVED, `helper-db.R` now matches
>
> `helper-db.R` and this document landed together on 2026-07-17 (`40f9fba`),
> **before** the 2026-07-19 fold-ins and the 2026-07-22 review, and left three
> things wrong. All three are now applied to both files. Authority:
> `PLAN-11-feature-alias.md` §Fixtures + CONTRACT A63/A67.
>
> 1. **`analysis.units_raw` REMOVED** (D7 reversed / A63). Measured over
>    3,624 committable rows: units are a function of the method, so they live on
>    `lab_method`, which gains **`units`** and **`conversion_constant`**.
>    `analysis` gets no units column at all.
> 2. **`feature` gains `lon DOUBLE NOT NULL, lat DOUBLE NOT NULL`**
>    (R-11.17), added to the table below. `virtual BOOLEAN` is **NOT**
>    "test-only drift" — the live table *does* have it (19 columns, all 894
>    rows FALSE). That claim came from probing the dashboard's *derived*
>    copy, not the live DB (A67). The column stays; the drift comment is gone.
> 3. **The seed carries the R-11.19 fixture**: two `lab_method` rows
>    (`lm-0010`/`lm-0011`) differing only in name capitalisation, same
>    organisation, same method, one analyte — mirroring the live
>    `Standing Water Level` / `Standing water level` pair that currently
>    strands every ACIRL reading of it (A65).

### feature
`lon`/`lat` are DOUBLE NOT NULL live (R-11.17); every seeded row carries a
placeholder value so the NOT NULL constraint is satisfied.

| uuid | name | site | flow | matrix | date_end | lon | lat |
|---|---|---|---|---|---|---|---|
| f-0001 | T.S01 | TestSite | surface | water | (NA) | 150.0001 | -33.0001 |
| f-0002 | T.S02 | TestSite | surface | water | (NA) | 150.0002 | -33.0002 |
| f-0003 | T.MW01 | TestSite | (NA) | groundwater | (NA) | 150.0003 | -33.0003 |
| f-0004 | T.S04 | TestSite | surface | water | (NA) | 150.0004 | -33.0004 |
| f-0005 | T.S05 | TestSite | surface | water | (NA) | 150.0005 | -33.0005 |
| f-0006 | T.S06 | TestSite | surface | water | 2020-06-30 (defunct) | 150.0006 | -33.0006 |
| f-0007 | T.S07 | TestSite | surface | water | (NA) | 150.0007 | -33.0007 |

f-0004..f-0007 exist only to host the plan-11 alias-narrowing fixtures below
(f-0001..f-0003 are unchanged and keep serving every pre-plan-11 fixture use).

### feature_alias (R-11.1)
| uuid | uuid_feature | name | alias_key | kind | auto_assign |
|---|---|---|---|---|---|
| fa-0001 | f-0001 | T.S01 | ts01 | self | TRUE |
| fa-0002 | f-0002 | T.S02 | ts02 | self | TRUE |
| fa-0003 | f-0003 | T.MW01 | tmw01 | self | TRUE |
| fa-0004 | f-0003 | bs03alt | bs03alt | transcription_error | TRUE |
| fa-0005 | f-0004 | T.AMBIG2 | tambig2 | descriptive | TRUE |
| fa-0006 | f-0005 | T.AMBIG2 | tambig2 | descriptive | TRUE |
| fa-0007 | f-0006 | T.REUSED | treused | historical_code | TRUE |
| fa-0008 | f-0007 | T.REUSED | treused | historical_code | TRUE |
| fa-0009 | f-0003 | T.BORE | tbore | descriptive | **FALSE** |
| fa-0010 | (NULL, dangling) | T.S09 | ts09 | pending | FALSE |
| fa-0011 | f-0004 | T.S04 | ts04 | self | TRUE |
| fa-0012 | f-0005 | T.S05 | ts05 | self | TRUE |
| fa-0013 | f-0006 | T.S06 | ts06 | self | TRUE |
| fa-0014 | f-0007 | T.S07 | ts07 | self | TRUE |

Every feature (f-0001..f-0007) has a self-alias (`kind = "self"`), per the
model's "no special case for arrived correctly labelled" invariant. Plus:
- `fa-0004` (`bs03alt` → f-0003): a resolved alt-label alongside f-0003's
  self-alias `fa-0003` — a **hit** (both resolve the same feature), not an
  ambiguity. Exercises "two different incoming labels for one feature share
  one sample" (R-11.7).
- `fa-0005`/`fa-0006` (`T.AMBIG2` → f-0004 **and** f-0005): the **ambiguous**
  fixture. Both features are live (`date_end` NULL) at every fixture date, so
  this key never narrows to one candidate (R-11.4/R-11.10).
- `fa-0007`/`fa-0008` (`T.REUSED` → f-0006 **and** f-0007): the
  reused-key/one-defunct fixture. f-0006's `date_end` (2020-06-30) is long
  before any fixture sample date, so at any such date narrowing drops f-0006
  and auto-resolves to f-0007 — the `date_end`-narrowing criterion (R-11.4).
- `fa-0009` (`T.BORE` → f-0003, `auto_assign = FALSE`): a non-identifying
  descriptive alias that must never enter the candidate set — suggestion-only.
- `fa-0010` (`T.S09`, `uuid_feature` NULL, `kind = "pending"`): an **already
  existing** dangling alias, paired with sample `s-0003`/analysis `an-0003`
  below, that a *second* reconcile event re-encounters via natural-key lookup
  (R-11.5a, feature-pending path).

### feature_mask
| uuid_feature | variant | name |
|---|---|---|
| f-0001 | long | Test Surface 01 |   (alias → resolves to f-0001)
| f-0002 | epa | AMBIG |            (ambiguity fixture …)
| f-0003 | long | AMBIG |           (… "AMBIG" matches f-0002 AND f-0003)

Untouched by plan 11 — R-11.4 stops joining `feature_mask` for candidate
matching, but the table and these rows remain for other plans' pre-existing
tests (and for the migration's `long`-name import, R-11.13 step 5).

### analyte  (canonical units deliberately differ from reported units to force conversion)
| uuid | name | units | type | CAS |
|---|---|---|---|---|
| a-0001 | pH | pH | field | (NA) |
| a-0002 | Fluoride | µg/L | anion | 16984-48-8 |
| a-0003 | Electrical Conductivity | mS/cm | field | (NA) |
| a-0004 | Temperature | °C | field | (NA) |

### lab_method  (analyte_raw + organisation → uuid_lab → uuid_analyte)
`units` and `conversion_constant` are plan-11 columns (A63 — restoring two
columns lost from WEM.data's `labDF`). `units` is a **fallback** for
interpreting a value, never an assertion about a particular report, and is
**never** part of the method's identity.

| uuid | uuid_analyte | name | method | organisation | rl_low | units | conv_const |
|---|---|---|---|---|---|---|---|
| lm-0001 | a-0001 | pH Value | EA005P: pH by PC Titrator | ALS | 0.01 | pH | (NA) |
| lm-0002 | a-0002 | Fluoride | EK040P: Fluoride by PC Titrator | ALS | 0.1 | mg/L | (NA) |
| lm-0003 | a-0003 | Electrical Conductivity @ 25°C | EA010P: Conductivity by PC Titrator | ALS | 1 | µS/cm | (NA) |
| lm-0004 | a-0002 | Fluoride | EK040T: Fluoride by alt method | ALS | 0.5 | mg/L | (NA) |
| lm-0005 | a-0001 | pH | (NA) | ACIRL | (NA) | pH | (NA) |
| lm-0006 | a-0003 | EC | (NA) | ACIRL | (NA) | mS/cm | (NA) |
| lm-0007 | a-0004 | Temperature | (NA) | ACIRL | (NA) | deg C | (NA) |
| lm-0008 | **(NULL, dangling)** | EC New Method | EA010Z: Conductivity by new method | ALS | 1 | µS/cm | (NA) |
| lm-0009 | **(NULL, dangling)** | Sulphate | EA045: Sulphate by IC | ALS | 0.5 | mg/L | (NA) |
| lm-0010 | a-0004 | Standing Water Level | field | ACIRL | (NA) | m | (NA) |
| lm-0011 | a-0004 | Standing water level | field | ACIRL | (NA) | m | (NA) |
| lm-0012 | a-0002 | Fluoride as F | EK040P: Fluoride by PC Titrator | ALS | 0.1 | mg/L | **2.0** |

`lm-0002`/`lm-0004` are the duplicate-method pair (R-8.6): same analyte, ALS;
lm-0002 has the lower rl_low (0.1) so it wins.

`lm-0010`/`lm-0011` are the **R-11.19/A65 fixture** — two genuinely distinct
methods differing *only* in name capitalisation, same organisation, same method,
both resolving to one analyte. They mirror the live ACIRL
`Standing Water Level` / `Standing water level` pair, which currently makes
every such reading strand as `unknown_analyte`. An incoming
`Standing Water Level` must resolve to **lm-0010** and `Standing water level` to
**lm-0011** (exact raw name wins); an unseen third spelling must resolve to one
analyte as a *hit* and pick the **same** uuid on a re-run.

`lm-0012` is the **conversion-constant fixture** (A63): its `conversion_constant`
is 2.0, so an incoming value of `3` commits as `analysis.value = 6`. Every other
seeded method has NA, i.e. no conversion — the today-behaviour baseline.

`lm-0008`/`lm-0009` are plan-11 dangling (`uuid_analyte IS NULL`) fixtures:
- `lm-0008` is paired with sample `s-0002`/analysis `an-0002` (method `units`
  `'µS/cm'`, unconverted value `965`) for the R-11.11 confirm-and-convert
  test — reuses the pinned `965 → 0.965 mS/cm` conversion already below.
  Note the units live on **lm-0008**, not on `an-0002`.
- `lm-0009` is an **already existing** dangling method a *second* reconcile
  event re-encounters via natural-key lookup (R-11.5a, analyte-pending path),
  paired with sample `s-0004`/analysis `an-0004` below.

### project
| uuid | name | type |
|---|---|---|
| p-0001 | XX1234567 | Work order |

### Pre-existing sample + analysis (the "old pipeline already committed this" rows for three-way tests)
sample `s-0001`: uuid_feature_alias **fa-0001** (f-0001's self-alias;
plan-11 repoints this from the old `uuid_feature`), uuid_project p-0001,
date `2025-05-24`, datetime `2025-05-24 11:45:00` (Australia/Sydney), organisation ALS.
analysis `an-0001`: uuid_sample s-0001, uuid_lab lm-0002, value `100`,
quantified FALSE, rl_low `100`, comments NA. (No units column — D7 reversed;
the units are on `lm-0002`.)
(That is the converted form of "Fluoride <0.1 mg/L" — see conversions below.)

### Plan-11 additional sample + analysis rows
| sample | uuid_feature_alias | date | datetime | organisation |
|---|---|---|---|---|
| s-0002 | fa-0003 | 2025-05-25 | 2025-05-25 09:30:00 | ALS |
| s-0003 | fa-0010 (pending) | 2025-05-10 | 2025-05-10 08:00:00 | ALS |
| s-0004 | fa-0001 | 2025-05-12 | 2025-05-12 08:15:00 | ALS |

> **Datetime storage convention (tz-faithfulness).** The `datetime` values above
> — and s-0001's — are the **Australia/Sydney wall-clock** sampling times (the
> human-facing meaning). Production commit (`.ct_find_or_create_sample`) stores
> the Sydney-parsed instant, which duckdb persists as its **UTC** equivalent, so
> the `helper-db.R` SQL seed stores each datetime as the **UTC instant** =
> wall-clock **−10h** (AEST = UTC+10 in May, no DST): s-0001 `01:45`, s-0002
> `2025-05-24 23:30`, s-0003 `2025-05-09 22:00`, s-0004 `2025-05-11 22:15`. This
> is required for the R-11.18/A62 datetime-identity predicate: a re-ingest of the
> same sampling (also Sydney-parsed) must epoch-match its stored candidate. The
> `date` column stays the naive midnight-UTC calendar day, matched separately.

**`analysis` has NO units column** (D7 reversed / A63). Each row's units are
those of its `uuid_lab`, shown here in brackets for readability only — they are
**not** stored on these rows.

| analysis | uuid_sample | uuid_lab | value | quantified | rl_low | *(method units)* |
|---|---|---|---|---|---|---|
| an-0002 | s-0002 | lm-0008 (dangling) | 965 | TRUE | 1 | *(µS/cm, on lm-0008)* |
| an-0003 | s-0003 | lm-0001 (resolved) | 7.10 | TRUE | 0.01 | *(pH, on lm-0001)* |
| an-0004 | s-0004 | lm-0009 (dangling) | 12 | TRUE | 0.5 | *(mg/L, on lm-0009)* |

`s-0002`/`an-0002` is the R-11.11 conversion fixture (see `lm-0008` above).
`s-0003`/`an-0003` and `s-0004`/`an-0004` are the R-11.5a "already committed,
a second event re-encounters it" fixtures — the feature side is dangling for
the first pair (`fa-0010`), the analyte side is dangling for the second
(`lm-0009`); each has its counterpart side already resolved, so the two cases
are isolated.

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

**Chemistry2e** columns exactly (18 — matches the real ALS header, incl.
`Method_Type` between Result_Type and Method_Name; A15): `SampleCode,ChemCode,
OriginalChemName,Prefix,Result,Result_Unit,Total_or_Filtered,Result_Type,
Method_Type,Method_Name,Extraction_Date,Analysed_Date,EQL,EQL_Units,Comments,
Lab_Qualifier,UCL,LCL`. `Method_Type` = human method name (e.g. "pH by PC
Titrator"); `Method_Name` = coded method ("EA005P: pH by PC Titrator"). Rows
for XX1234567 (3 samples × the analytes) plus 2 QC rows, 1 plain foreign-work-
order row (`YY0000001`), and 1 compound-SampleCode NCP cross-reference row
(`ZZ9999999001_XX1234567`, PLAN-04 R-4.6). Pin these data rows (Method_Type
omitted from the table below for brevity — the generator derives it from
Method_Name):

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
| ZZ9999999001_XX1234567 | 16984-48-8 | Fluoride | (blank) | 0.8 | mg/L | T | EK040P: Fluoride by PC Titrator | 0.1 |

Analysed_Date `26 May 2025` for all; Extraction_Date blank or `26 May 2025`.
The `Observation` row is the text-value branch. The QC rows' Sample_Type comes
from Sample2e (below). The `YY0000001` row is a **plain** foreign-work-order
row (no `_<home>` suffix) — a genuine foreign result that assembly flags
`foreign_work_order` for review. The `ZZ9999999001_XX1234567` row is a
**compound-SampleCode NCP cross-reference** (PLAN-04 R-4.6): the chemistry
parser marks it `sample_type = "NCP"` from the `<orig>001_<home>` code (there
is no Sample_Type column in Chemistry2e), and assembly (R-7.4) counts it in
`n_ncp_foreign` and drops it before commit, never flagging it.

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

- ESdat XX1234567 Chemistry2e → 11 result rows; the compound-SampleCode NCP
  cross-reference (`ZZ9999999001_XX1234567`) parses `sample_type = "NCP"` and
  is dropped at assembly, leaving 10 rows to the event. After Sample2e join,
  the 3 Normal samples' rows carry datetimes 11:45/11:10/11:00 and sample_type
  Normal; QC rows carry LCS/MB; the plain `YY0000001` row is flagged
  `foreign_work_order`.
- Assembly event `XX1234567`: the compound NCP row is counted
  (`n_ncp_foreign` = 1) and absent from results; the plain `YY0000001` foreign
  row is kept and flagged for review; source-preference keeps ESdat over
  XTAB/ENMRG.
- Reconcile: T.S01/T.S02/T.MW01 resolve to f-0001/f-0002/f-0003 (via their
  self-aliases fa-0001/fa-0002/fa-0003); "AMBIG" would be ambiguous; a typo
  `T.S0l` (lowercase L) → `unknown_feature`, and **under plan 11's
  commit-everything model it no longer strands**: the row commits dangling
  (a new pending `feature_alias`, `feature_pending = TRUE`) and archives —
  only pre-plan-11 the row was dropped to review and held (R-11.5).
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
