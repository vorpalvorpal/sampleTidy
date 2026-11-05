# Crosstab fixtures (plan 05: `als_xtab`, `als_enmrg`)

Every file here is SYNTHETIC and generated deterministically by
`generate.R` (re-run with `Rscript tests/testthat/fixtures/crosstab/generate.R`).
CONTRACT A34 (2026-07-15): the primary fixtures for this adapter are two
full-shape ALS crosstab exports (a whole routine water suite, with the
format quirks of ALS's own exports) whose work orders, purchase orders,
dates and results are invented. A small set of minimal fixtures cover only
the criteria the two full-shape files do not exercise. An earlier fixture
set encoded the WRONG layout (column 0 only for per-sample metadata, a bare
`Analyte` header) and has been deleted/regenerated in the CORRECT layout
described below.

## Full-shape fixtures

| file | notes |
|---|---|
| `ES2670610_0_XTAB.csv` | single `Matrix: WATER` section, 3 REG samples (`ES2670610001-003`), 26 distinct analytes. Exercises: the per-sample-label row layout (col 3, values from col 5), the combined `Analyte grouping/Analyte` header, `Unit`/`Limit of reporting` spellings, `----` skips (24 of them, no genuinely blank cells), multi-analyte method groups (e.g. `ED037P: Alkalinity by PC Titrator` covers 4 analyte rows), and the degree/micro mojibake ALS's XTAB.csv export carries (see below). |
| `ES2670610_0_XTAB.XLS` | SpreadsheetML 2003 XML twin of the above (A37): ISO-8859-1, raw `0xB0`/`0xB5`, per-sample labels merged across columns 3-4, plus a second worksheet `QC WATER - 1` of QC lots and other clients' samples (e.g. `ES2670702010`) that must never be ingested. |
| `ES2570540_0_ENMRG.CSV` | genuine UTF-8, single `Client - Matrix: WATER` section, 7 REG samples (`ES2570540001-007`), 27 distinct analytes, `Units`/`LOR` header spellings, no mojibake (already correct Unicode). Also carries a trailing `QC - Matrix:` reconciliation block that reuses/extends the same sample-column indices for QC codes AND for other, unrelated work orders' primary samples - see "Unsupported trailing section" below. `../qc/secondary/` holds the same report with edited client-ID rows (`test-qc-ingest.R`). |

### XTAB.csv mojibake is a UTF-8-encoded U+FFFD, not a raw latin-1 byte

`ES2670610_0_XTAB.csv`'s only two non-ASCII byte runs (the EC analyte name's
degree sign and its unit's micro sign) are each the 3-byte sequence
`EF BF BD` - the valid UTF-8 encoding of U+FFFD (REPLACEMENT CHARACTER), not
a single raw latin-1 high byte (e.g. `0xB0`), as in ALS's own XTAB.csv
exports. The dialect reads UTF-8 and `normalise_lab_text()` repairs the
lone U+FFFD (`\ufffdC` -> degree-C, `\ufffdS/cm` -> micro-S/cm);
`test-adapter-crosstab.R` asserts the repaired values.

### Unsupported trailing section ("QC - Matrix:")

`ES2570540_0_ENMRG.CSV` carries a second block, headed `QC - Matrix:`
(not `Client - Matrix:`), whose own `ALS Sample number:` row reuses the
SAME column indices as the primary section for a much wider set of QC codes
and other work orders' primary samples (`ES2570701005`, `EN2570703006`,
...). This is not one of the two dialects' recognised section markers,
its shape doesn't match the documented single-Matrix:-section norm (CONTRACT
A34d), and blindly parsing it would corrupt the primary section's
already-emitted per-column state by reusing the same column indices for
unrelated samples. The parser's `.ST_CROSSTAB_ANY_MARKER_RE` mechanism
detects any `...Matrix:`-suffixed cell; if it isn't the dialect's own
recognised marker, that row and everything after it (until a recognised
marker reappears, if ever) is skipped outright - never treated as data.
This is why, from the adapter's perspective, `ES2570540_0_ENMRG.CSV` is
"all-REG, no QC" even though the file contains a QC-labelled block.

## Minimal fixtures (correct layout)

Column layout used by every file below (0-based, the same as the
full-shape files): section-scalar labels (`Matrix:`/`Client - Matrix:`,
`Workgroup:`, `Project name/number:`) at column 0, value at column 1.
Per-sample labels (`Sample Type:`, `ALS Sample Number:`/`ALS Sample
number:`, `Sample Date:`, `Client sample ID (1st)`/`(Primary)`, `Site:`/
`Sample Site:`) at column 3 (XTAB) / column 4 (ENMRG); XTAB's per-sample
values start two columns after the label (column 5 - one empty gap
column), ENMRG's start immediately the next column (no gap). The analyte
header is always the single combined `Analyte grouping/Analyte` column.

| file | criterion covered | content |
|---|---|---|
| `XX1234567_0_XTAB.csv` | (a) two-section: rows carry their own section's matrix/date (R-5.1) | `Matrix: WATER` (samples `XX1234567001/002`, features `T.S01/T.S02`, `Sample Date: 24/05/2025`, pH `6.40`/`6.90`) then `Matrix: SOIL` (sample `XX1234567003`, feature `T.S03`, `Sample Date: 25/05/2025`, pH `6.80`). Same `Workgroup: XX1234567` in both sections. 3 results, 3 samples total. |
| `XX1234567_0_XTAB.xlsx` | binary/xlsx twin, kept ONLY so `test-adapter-acirl.R`'s "a foreign xlsx matches no" cross-adapter check has a file to point at (R-5.2's real xls-twin-equals-csv criterion is deferred post-MVP per CONTRACT A37 - not asserted here). Same grid as the two-section csv above. |
| `XX1234567_0_ENMRG.CSV` | (c) ENMRG with QC sample columns (R-5.1) | `Client - Matrix: WATER`, 1 REG sample (`XX1234567001`/`T.S01`) + 2 QC columns (`QC-000001`=`LCS`, `QC-000002`=`MB`), 3 analytes (pH, Fluoride, EC). Results: REG all 3 valid; LCS pH `7.00` + Fluoride `0.5` valid, LCS EC empty (skipped `empty`); MB pH `----` (skipped `not_computable`), MB Fluoride empty (skipped `empty`), MB EC `600` valid. 6 results total, `n_by_sample_type` = Normal 3 / LCS 2 / MB 1. |
| `ZZ9999999_0_XTAB.csv` | (b) Workgroup-cell-vs-filename mismatch (R-5.3) + d/m/y disambiguation (R-5.1) | Filename encodes work order `ZZ9999999`; `Workgroup:` cell says `XX1234567` (must win, with a `report$warnings` entry naming both). Single `Matrix: WATER` section, 1 sample (`ZZ9999999001`/`T.S01`), 1 analyte (pH `6.90`). `Sample Date: 05/01/2026` is unambiguous only under d/m/y (-> 5 January). |

`XX1234567_1_XTAB.csv` (the old revision-1 supersede fixture) has been
deleted - it is not required by any test this rework owns; plan 10's
(currently unimplemented, intentionally red) e2e fixture-existence check is
out of scope here.

## R-12.8 hardening fixtures (PLAN-12, F14; match()-only, never parsed)

| file | criterion covered | content |
|---|---|---|
| `WK7654321_0_XTAB.csv` | dialect marker (`Workgroup:`) past `file_meta()`'s fixed first-2048-byte peek window (R-12.8) | `Matrix: WATER` on line 1 (required), then a single filler row whose one cell is 2200 bytes of `x`, pushing `Workgroup:` (row 3) to start at byte offset 2248 - past `file_meta()`'s 2048-byte `peek`. Otherwise a minimal valid single-section XTAB shape. |
| `BM1122334_0_XTAB.csv` | UTF-8 BOM (`EF BB BF`) prepended before any text (R-12.8) | Identical minimal shape, with a raw UTF-8 BOM written before `Matrix:` on line 1 - under the peek's latin-1 decode this becomes 3 extra leading characters that defeat `^Matrix:` today. |

## Verification performed

Every count/name/value documented above (and asserted in
`test-adapter-crosstab.R`) was derived by actually parsing the fixture with
the corrected adapter and reading off the result - not hand-guessed. See
`generate.R` for the exact synthetic fixture content.

## Latin-1 pair (2026-10-19 corpus finding, PLAN-05 R-5.4a)

| file | notes |
|---|---|
| `../corpus-2026-10-19/latin1/ES2470410_0_XTAB.csv` | XTAB, **genuinely latin-1** (raw `0xB0`/`0xB5`/`0xB1`), the encoding of the 103 corpus crosstabs that failed with "invalid UTF-8"; must parse equal to its twin below. Ends with CRLF. |
| `../corpus-2026-10-19/utf8-twin/ES2470410_0_XTAB.csv` | the same report in UTF-8, no final newline (`iconv -f latin1` of the first is byte-identical to it apart from that newline). Kept in its own directory so both carry the same filename. |

Both written by `generate.R`. So the U+FFFD mojibake above holds only for
some XTAB exports: others are genuinely latin-1. Both kinds occur in the
corpus.
