# ACIRL fixtures (plan 06: `acirl_field_xlsx`)

Synthetic, structurally-exact fixtures for the ACIRL monthly-workbook adapter
(A3 - no real lab data committed). Generated deterministically by
`generate.R`; re-run with `Rscript tests/testthat/fixtures/acirl/generate.R`.

## xlsx-for-xls substitution

The real ACIRL source files are legacy `2400-*.xls` workbooks. Writing
genuine binary `.xls` proved impractical in this environment, so all ACIRL
fixtures here are built as `.xlsx` via `openxlsx`, per PLAN-06's own
contingency ("build as `.xlsx` ... if writing legacy `.xls` proves
impractical, and note it in the fixture README"). `match()`/tests must accept
both extensions once implemented; only `.xlsx` fixtures exist on disk.

## Water-sheet layout (transposed field block)

Reproducing PLAN-06's documented old-reader layout: rows = field parameters,
columns = samples (one column per feature x visit) - the "transposed" shape
that must be pivoted to long/tidy form:

- row `Site Name`: col A = `Site Name`, col B = the **`Units` marker cell**
  (the match()-fingerprint cell PLAN-06 R-6.1 requires within the first 15
  rows), col C.. = feature names, one column per (feature, visit).
- row `Date`: col A = `Date`, col B = blank (no date - this is *why* "the
  units row is the one where date is NA" after transposition), col C.. =
  **Excel serial** dates (verified against the PLAN-02-pinned fact
  `excel_date(45802) == as.Date("2025-05-25")`; `24/05/2025` = serial
  `45801`), filled across repeated columns per visit ("date fill-down").
- rows `pH` / `EC` / `Temperature`: col A = label, col B = units, col C.. =
  values.
- row `Comments`: col A = `Comments`, col B = blank, col C.. = free text -
  the **block terminator** (last row matching PLAN-06's terminator regex);
  attaches to `ir_samples$comments`, never emitted as a result row.
- below the terminator: 4 fake ALS analyte rows (`Fluoride`, `Sulphate`,
  `Total Dissolved Solids`, `Alkalinity`) that must be dropped
  (`lab_data_dropped`) - none of these labels match the terminator regex, so
  they can't be mistaken for the end of the field block.

## Files pinned by `dev/plans/FIXTURES.md`

`2400-9999-01 Test Month WMF.xlsx` - the one pinned workbook, exactly 5
sheets:

| sheet | role | structural property |
|---|---|---|
| `Front Page` | front page (`(?i)front` match) | `REPORT NO:` -> `2400-9999-01`, `SAMPLED BY:` -> `J. Tester & offsider` (adapter must strip the trailing `& offsider`, squish -> `J. Tester`), `SAMPLE DATE:` -> `24/05/2025`; all values sit one cell to the right of their key (`vector_from_key(direction = "right")`) |
| `Methods` | methods sheet (`(?i)method` match) | ignored; minimal method-code table |
| `Dust Sheet` | dust sheet (`(?i)dust` match) | detected & skipped (A10 / R-6.4); minimal unrelated PM10 content |
| `Field Data 1` | water sheet, visit 1 | 2 features (`T.S01`, `T.S02`) x 2 visits (`24/05/2025`, `25/05/2025`) = 4 sample columns; `EC` units clean `µS/cm`; **one genuinely empty cell** (Temperature, `T.S02`/25 May) -> `skipped` reason `empty`; comments on 2 of 4 columns |
| `Field Data 2` | water sheet, visit 2 | same 4-column shape; `EC` units written as the **mojibake variant `<U+FFFD>S/cm`** (PLAN-02's cp1252-style mojibake-table entry, `�` stored as ordinary UTF-8 text - xlsx is natively Unicode, so this is a literal already-mojibake string rather than a raw-byte encoding artifact like the crosstab CSV's) - must normalise to `µS/cm`; no empty cells; comments on 2 of 4 columns |

Each water sheet also carries its own 4 fake-ALS-analyte rows below the
`Comments` terminator (16 cells per sheet, all of which must be dropped).

## Additions beyond FIXTURES.md's pinned list (documented, see `PLAN-CHANGE-REQUESTS.md`)

FIXTURES.md pins only the one core workbook; several PLAN-06 R-6.x criteria
have no data to exercise them there, so three small auxiliary workbooks were
added:

| file | purpose |
|---|---|
| `EDGECASES.xlsx` | `Front Page` + `Field Data Big` (24-row field block: `Site Name` + `Date` + 18 filler `Note N` rows + `pH`/`EC`/`Temperature`/`Comments`, exceeding the old reader's 20-row sanity-check threshold - R-6.3 "`>20`-row block emits a warning ... still parses") + `Field Data NoUnits` (2 sample columns, **no `Units` marker anywhere in the sheet** - R-6.3 "a sheet with no `Units` marker -> sheet skipped, `report$warnings` entry, other sheets still parse") |
| `NO_REPORT_NO.xlsx` | `Front Page` with `REPORT NO:` entirely absent (row left blank) + one minimal water sheet, for R-6.2's "missing `REPORT NO:` -> parse continues, warning recorded, `work_order = NA`" negative case |
| `random.xlsx` | trivial unrelated workbook (`Sheet1`, no front page, no `Units` cell anywhere), for R-6.1's "a random xlsx -> `no`" negative match() case |

## Verification performed

`generate.R`'s fixtures round-trip via `readxl::read_excel()` /
`openxlsx::loadWorkbook()` (see `test-adapter-acirl.R`): sheet names match
the pinned front/method/dust/water roles; the `Date` row's cells read back as
the exact numeric strings `"45801"`/`"45802"` (i.e. stored as plain numbers,
not pre-formatted date cells - matching PLAN-02 R-2.4's own `excel_date()`
serial-based conversion, not `readxl`'s automatic date detection);
`Field Data 2`'s EC-units cell contains the literal `U+FFFD` replacement
character (`ef bf bd` in UTF-8); `Field Data Big` has 28 rows total (24-row
field block + 4 fake-ALS rows); `Field Data NoUnits`'s Site-Name row has no
"Units" text in any cell.
