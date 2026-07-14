# Crosstab fixtures (plan 05: `als_xtab`, `als_enmrg`)

Synthetic, structurally-exact fixtures for the shared crosstab parser (A3 -
no real lab data committed). Generated deterministically by `generate.R`; re-
run with `Rscript tests/testthat/fixtures/crosstab/generate.R`.

## Column layout chosen for these fixtures

Real ALS crosstab exports vary in exact column position (PLAN-05: "do not fix
column indices - locate labels by regex in each row"), so the fixtures encode
one concrete, self-consistent, documented layout rather than a literal
capture of a real file:

- **XTAB**: column 0 = row label / `Analyte`, 1 = `CAS Number`, 2 = `Unit`,
  3 = `Limit of reporting`, 4.. = one column per sample. The
  `ALS Sample Number:` label sits at column index **3** (0-based) - matching
  PLAN-05's documented real-file observation - with sample numbers starting
  at column 4.
- **ENMRG**: column 0 = `Analyte grouping`, 1 = `Analyte` (kept as two
  separate columns, unlike XTAB's single combined `Analyte` column - our
  reading of PLAN-05's "header row starting `Analyte grouping/Analyte`"),
  2 = `CAS Number`, 3 = `Unit`, 4 = `Limit of reporting`, 5.. = sample
  columns (3 regular + 2 QC). The `ALS Sample number:` label sits at column
  index **4**, matching PLAN-05's pinned "label col index: 4" fact. This
  column-layout interpretation is flagged as an ambiguity resolution in
  `dev/plans/PLAN-CHANGE-REQUESTS.md`.

## Files

| file | structural property | provenance |
|---|---|---|
| `XX1234567_0_XTAB.csv` | **latin-1 encoded**; two stacked `Matrix:` sections (`WATER` then `SOIL`) | FIXTURES.md "two stacked sections"; PLAN-05's explicit "two-section WATER+SOIL fixture" criterion resolves FIXTURES.md's more ambiguous wording (see `PLAN-CHANGE-REQUESTS.md`) |
| " | WATER section: samples `XX1234567001/002/003` (`T.S01/T.S02/T.MW01`), `Sample Date: 24/05/2025` (d/m/y), analytes `pH`, `Fluoride` (CAS `16984-48-8`), `Electrical Conductivity @ 25<0xA1>C` | FIXTURES.md's pinned crosstab sample/analyte/value table; values for Fluoride (`<0.1`, `2.3`, `>2000`) and EC (`185`, `965`) are **byte-for-byte the same value strings as the ESdat fixture's XX1234567001-003 rows**, so cross-format equivalence (plan 07/10) holds |
| " | the literal byte `0xA1` sits between "25" and "C" in the EC analyte-row cell. Decoded under a **correct latin-1 locale** this reads as `25¡C` - the documented MacRoman-degree-sign mojibake (PLAN-02 R-2.1) that `normalise_lab_text()` must fix to `25°C`. Decoded incorrectly as UTF-8 the byte is not valid UTF-8 at all (verified in `generate.R`'s checks: `read_csv()` without a latin-1 locale throws "invalid multibyte string" warnings) | PLAN-02 R-2.1 / PLAN-05 R-5.1 "mojibake analyte normalised (`25°C` in output)" criterion; FIXTURES.md "`25¡C` mojibake in the EC group header" |
| " | the literal byte `0xB5` (correct latin-1 codepoint for `µ`) in the Unit cell `µS/cm` for the same EC row | native latin-1 micro sign, no mojibake-table fix needed, just correct decoding |
| " | pH row: one `----` cell (not-computable) and one empty cell; EC row: one empty cell (no EC recorded for sample 003, mirroring the ESdat fixture's own gap) | PLAN-05 R-5.1 "`----` and empty cells land in `report$skipped`" criterion |
| " | SOIL section: 1 sample (`XX1234567004`, feature `T.S03`), `Sample Date: 25/05/2025`, plain-ASCII analyte spellings (no mojibake) so the two sections are trivially distinguishable in test assertions | supports R-5.1 "two-section fixture: rows carry their own section's matrix and dates" |
| `XX1234567_0_XTAB.xlsx` | **xlsx substitutes for legacy `.xls`** (writing genuine binary `.xls` was impractical in this environment; `openxlsx` produces `.xlsx` instead - PLAN-05/PLAN-06 both anticipate this substitution). Same logical grid as the `.csv` twin, both sections, **but with the correct Unicode `°`/`µ` characters** instead of the CSV's legacy mojibake bytes - xlsx is natively Unicode and was never subject to the CSV's byte-encoding bug, so "identical content" means the same *data*, not byte-identical raw encoding. Adapter output (IR) from the two files must match after `normalise_lab_text()` fixes the CSV's mojibake (R-5.2: "same IR, ignoring `source_ref`") | task-orchestrator instructions + PLAN-05 fixtures section |
| `XX1234567_0_ENMRG.CSV` | UTF-8, single `WATER` section, same 3 regular samples/analytes/values as the XTAB WATER section (correct Unicode `°`/`µ`, no mojibake - ENMRG is UTF-8 natively) **plus 2 QC sample columns** (`Sample Type:` = `LCS`, `MB`) reusing the same QC codes/values as the ESdat fixture (`QC-000001` Fluoride `0.5`, `QC-000002` pH `7.00`) for cross-format consistency | FIXTURES.md "ENMRG is UTF-8 with 2 extra QC columns" |
| `ZZ9999999_0_XTAB.csv` | filename encodes work order `ZZ9999999`, but the `Workgroup:` cell inside the file says `XX1234567` - single minimal `WATER` section, 1 sample, 1 analyte (`pH`) | FIXTURES.md "mismatch-precedence test"; PLAN-05 R-5.3 "Workgroup cell > filename guess ... mismatch ... `report$warnings` records it" |

## Verification performed

`generate.R`'s companion checks (rerun via `test-adapter-crosstab.R`) confirm:
raw bytes `0xA1` and `0xB5` are present in `XX1234567_0_XTAB.csv` at the
expected offsets; a correct latin-1 locale decodes them to `¡`/`µ`; a UTF-8
locale read of the same file throws/warns on invalid encoding; the `.xlsx`
twin round-trips via `readxl`/`openxlsx` with the clean, non-mojibake text;
the ENMRG and mismatch CSVs are plain UTF-8/ASCII and round-trip via
`readr::read_csv`.
