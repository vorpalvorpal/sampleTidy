# PLAN 02 — Ported primitives: text, units, values, dates, spreadsheet tools

**Owns:** `R/text-normalise.R`, `R/units.R`, `R/values.R`, `R/dates.R`,
`R/spreadsheet-tools.R` + matching test files. **Depends on:** 01.
**Blocks:** 04–08.

Ports come from `~/Desktop/WEM.data` (read-only reference; copy code in, then
adapt). Ported code must satisfy CONTRACT conventions: no `.GlobalEnv`, no
interactive prompts, no `<<-`, snake_case DB names.

## R-2.1 `normalise_lab_text(x)`

Port from `WEM.data/R/new/data/normalise_lab_text.R` **with its
`.lab_text_mojibake_fixes` table verbatim**, plus entries for the observed
MacRoman degree byte (`\xA1` read as latin-1 → `¡`; `25¡C` → `25°C`) and the
classic cp1252 pairs (`�S/cm`→`µS/cm`, `�g/L`→`µg/L`, `�C`→`°C`) from old
`unify_value()`. Criteria:
- each mojibake table entry round-trips in a parametrised test;
- text containing U+FFFD warns (class `sampletidy_warning`) and is returned
  otherwise unchanged;
- NULL/empty input returned as-is; NA elements stay NA, no warning.

## R-2.2 Unit engine

Port `is_valid_unit()`, `are_compatible_units()` and rebuild `unify_value()`
from `WEM.data/R/new/helpers/unify_value.R` as a **pure vectorised function**:

```r
unify_value(value, units_from, units_to)  # -> dbl, same length as value
```

Drop: analyte lookups (callers resolve units first), the `ask::ask()`
interactive repair (invalid units abort listing the offending strings — the
reconciler catches and queues them), GlobalEnv reads. Keep: NA semantics
(both NA → unchanged; from NA → unchanged; to NA while from set → abort),
group-wise `units::set_units(mode = "standard")` conversion, input order
preserved. `pH`/`pH Unit`/`pH_Units` are registered as valid dimensionless
units (udunits doesn't know them; maintain a package-level
`.unitless_aliases` set).

Criteria: `unify_value(1, "mg/L", "µg/L") == 1000`;
`unify_value(c(2, 5), c("mg/L", "µS/cm"), c("µg/L", "mS/cm")) ==
c(2000, 0.005)` (mixed groups, order preserved); identical from/to returns
input unchanged (no units round-trip); invalid unit aborts with the string in
the message and class `sampletidy_units_error`; `are_compatible_units("mg/L",
"°C")` is FALSE, `("mg/L","g/m3")` TRUE.

## R-2.3 `parse_value(value_raw)`

Vectorised successor to `cleanBDLvalues()`
(`WEM.data/R/new/import/cleanBDLvalues.R` is the semantic reference).
Returns tibble: `value_num` (dbl), `value_chr` (chr), `quantified` (lgl),
`rl_low` (dbl), `rl_high` (dbl), `skip_reason` (chr, NA unless skipped).

| input | value_num | quantified | rl_low | rl_high | other |
|---|---|---|---|---|---|
| `"2.3"` | 2.3 | TRUE | NA | NA | |
| `"<0.01"` | 0.01 | FALSE | 0.01 | NA | |
| `">2000"` | 2000 | FALSE | NA | 2000 | |
| `"BDL"` | NA | FALSE | NA | NA | |
| `"NS"` | NA | NA | NA | NA | skip_reason=`"no_sample"` (A4) |
| `"----"` | NA | NA | NA | NA | skip_reason=`"not_computable"` |
| `"Clear, low flow"` | NA | TRUE | NA | NA | value_chr keeps text |
| `""`/NA | NA | NA | NA | NA | skip_reason=`"empty"` |

Criteria: exactly this table (parametrised test); numeric strings with
commas (`"1,320"`) parse as 1320; whitespace tolerated.

## R-2.4 `parse_lab_datetime(x, formats, tz = "Australia/Sydney")`

Accepted named formats (pin): `esdat` = `"%d %b %Y %H:%M"`, `"%d %b %Y"`,
`"%d-%b-%y %H:%M"`, `"%d-%b-%y"` (real ESdat exports render sample/analysed
dates in both the long `"07 May 2024 11:30"` and the short `"07-May-24 11:30"`
dialect — corpus-confirmed 2026-07-23); `crosstab` = `"%d/%m/%Y"`; `iso` =
`"%Y-%m-%d %H:%M"` and `"%Y-%m-%d"`. Within a preset, datetime forms precede
their date-only counterpart so a clock time is never dropped to midnight.
Returns POSIXct in tz. Criteria:
- `"24 May 2025 11:45"` → 2025-05-24 11:45 AEST; `"26 May 2025"` → midnight;
- `"07-May-24 11:30"` → 2024-05-07 11:30 AEST; `"07-May-24"` → midnight;
- `"05/01/2026"` parses as **5 January** (d/m/y — the load-bearing assertion);
- `"13/13/2025"` → NA (not silently reinterpreted); mixed vector parses
  element-wise; empty string → NA;
- `has_clock_time(x)` helper returns TRUE iff a time component was present in
  the source string (drives A11 date-vs-datetime split).

Excel serials: `excel_date(n)` converts using origin `1899-12-30`
(criterion: `excel_date(45802) == as.Date("2025-05-25")` — verify constant
with R before writing the test; [MEASURE TWICE]).

## R-2.5 Spreadsheet tools

Port `str_which_df(df, pattern, multiple_matches = FALSE)` and
`vector_from_key(df, key, direction, remove_na, vector_length)` from
`WEM.data/R/new/import/read_ACIRL_front_page.R` (defs at lines ~110/~216),
generalised: pure functions of a data frame, regex against all character
cells, returning `tibble(row, col)` / extracted vector. Criteria:
- on a fixture grid, `str_which_df(g, "^Units$")` returns the exact cell;
  `multiple_matches = FALSE` with two hits aborts; zero hits returns
  zero-row tibble;
- `vector_from_key(g, "REPORT NO:", "right", vector_length = 1)` returns the
  cell to the key's right; `direction = "down"` returns below; `remove_na`
  drops NAs before length-checking; wrong length aborts.
