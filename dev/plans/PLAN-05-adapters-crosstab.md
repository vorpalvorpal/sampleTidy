# PLAN 05 — ALS crosstab adapters: `als_xtab`, `als_enmrg`

**Owns:** `R/adapter-crosstab.R` (shared core + both adapters),
`tests/testthat/test-adapter-crosstab.R`, `tests/testthat/fixtures/crosstab/…`.
**Depends on:** 01–03. Parallel-safe with 04/06.

Both formats are the same crosstab family: metadata rows, then an analyte
header, then method-group rows and analyte rows; samples are columns.
Differences (observed):

| | XTAB | ENMRG |
|---|---|---|
| label cell | `ALS Sample Number:` | `ALS Sample number:` |
| label col index | 3 (0-based) | 4 |
| first row label | `Matrix:` | `Client - Matrix:` |
| encoding | legacy (latin-1/MacRoman bytes) | UTF-8 |
| QC columns | absent | present (extra sample columns) |
| file ext | `.csv` / `.XLS` | `.CSV` |

Layout facts to encode (do not fix column indices — **locate labels by
regex** in each row; observed files vary): rows `Matrix:`, `Workgroup:`
(value = work order), `Project name/number:`, `Sample Type:` (per-column,
`REG` for regular), `Sample Date:` (d/m/y), `Client sample ID (1st):`
(= feature_raw), `Depth…`, then header row starting `Analyte
grouping/Analyte` with columns `CAS Number, Unit, Limit of reporting`, then:
method-group rows (non-empty first cell, **no values** in sample columns,
e.g. `EA005P: pH by PC Titrator`) and analyte rows (values present). A file
may contain **multiple stacked Matrix: sections** (old reader handled
several). `----` = not computable. Values may carry `<`/`>` prefixes.

## R-5.1 Shared parser `parse_crosstab(path, dialect)`

`dialect = list(id, label_regex = "(?i)^ALS Sample num", first_row_regex,
encoding)`. Reads csv (with `readr::read_csv(col_types = cols(.default =
"c"), col_names = FALSE, locale = locale(encoding = dialect$encoding))`) or
XLS (via `readxl`, all-text). Emits `ir_results` + `ir_samples` + report.

Mapping — results: `work_order` ← Workgroup value; `revision` ← filename
`revision_guess` (default 0 with warning if absent); `lab_sample_id` ← sample-
number row; `feature_raw` ← client-sample-ID row; `analyte_raw` ← analyte-row
first cell after `normalise_lab_text()`; `cas_number` ← CAS col;
`method_raw` ← **current method-group row** text; `units_raw` ← Unit col;
`rl` ← Limit-of-reporting col; `value_raw` ← cell verbatim; parse via
`parse_value()`; `sample_type` ← Sample-Type row value for that column
(`REG` → `"Normal"`, others verbatim); `total_or_filtered`, `lab_qualifier`,
`analysed_date` NA (not in format); `org = "ALS"`. Samples: one row per
sample column: `feature_raw`, `sample_datetime_raw` ← Sample-Date cell
(d/m/y, date only), `matrix_raw` ← section Matrix value, `sample_type` as
above.

Criteria (shared fixture pair encoding the table above, incl. a two-section
WATER+SOIL fixture and a `25¡C` mojibake cell in the XTAB one):
- results count = Σ per section (analyte rows × sample cols with non-empty,
  non-`----` cells); `----` and empty cells land in `report$skipped` with
  reasons (`not_computable`, `empty`) and correct `source_ref` (`r<row>c<col>`);
- method-group rows produce **zero** result rows but populate `method_raw`
  of following analyte rows; a second group resets it;
- two-section fixture: rows carry their own section's matrix and dates;
- mojibake analyte normalised (`25°C` in output);
- d/m/y: `05/01/2026` → January 5 in `samples`' parsed check (raw string kept
  verbatim in `sample_datetime_raw`);
- ENMRG fixture with 2 QC columns (`Sample Type:` = `LCS`, `MB`): their rows
  emitted with those `sample_type` values (not dropped), counted in
  `report$n_by_sample_type`.

## R-5.2 `als_xtab` / `als_enmrg` adapters

`match()`: `format` (not `exact`) when peek matches the dialect's
`first_row_regex` **and** contains `Workgroup:`; `no` otherwise. (`format`,
because ESdat must outrank crosstabs at source-preference time; router tier
only resolves per-file claims — both crosstab adapters must never claim the
same file: XTAB requires `^Matrix:`, ENMRG requires `^Client - Matrix:`.)
`parse()` delegates to `parse_crosstab` with its dialect.

Criteria: XTAB fixture → only `als_xtab` claims (`format`); ENMRG fixture →
only `als_enmrg`; ESdat/random fixtures → `no` from both; `.XLS` XTAB fixture
(binary) parses equal to its `.csv` twin (same IR, ignoring source_ref).

## R-5.3 Filename robustness

Work order resolution precedence: Workgroup cell > filename guess; mismatch
between the two → parse succeeds but `report$warnings` records it and the
Workgroup value wins. Criterion: fixture named `ZZ9999999_0_XTAB.csv`
containing Workgroup `XX1234567` yields work_order `XX1234567` + warning.

## Fixtures

`fixtures/crosstab/XX1234567_0_XTAB.csv` (latin-1 bytes, two sections),
`…_XTAB.XLS` (same content), `XX1234567_0_ENMRG.CSV` (UTF-8, +2 QC cols),
`ZZ9999999_0_XTAB.csv` (mismatch case). Same synthetic features/analytes as
plan 04 so cross-format equivalence can be asserted in plan 07/10. Fixture
README records provenance of each structural property.
