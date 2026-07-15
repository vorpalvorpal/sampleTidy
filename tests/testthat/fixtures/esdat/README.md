# ESdat fixtures (plan 04)

Synthetic, structurally-exact fixtures for the `esdat` adapter (A3 - no real
lab data committed). Generated deterministically by `generate.R`; re-run with
`Rscript tests/testthat/fixtures/esdat/generate.R` from the package root.

## Files pinned by `dev/plans/FIXTURES.md`

| file | structural property | modelled on (real-file provenance) |
|---|---|---|
| `PROJ_A.ESDAT_XX1234567_0.Chemistry2e.CSV` | column header exactly `SampleCode,ChemCode,OriginalChemName,Prefix,Result,Result_Unit,Total_or_Filtered,Result_Type,Method_Name,Extraction_Date,Analysed_Date,EQL,EQL_Units,Comments,Lab_Qualifier,UCL,LCL`; **latin-1 body with a leading UTF-8 BOM** (`EF BB BF`) | Real ALS "ESdat" EDD Chemistry2e exports are latin-1 (A35, corrected 2026-07-15 against the real corpus - see `REAL-FIXTURES.md`), and sometimes carry a stray UTF-8 BOM stapled onto that otherwise latin-1 body; the pinned header list is FIXTURES.md's own literal spec |
| " | 10 data rows: 7 for work order `XX1234567` (3 samples x mixed analytes incl. a `<`-prefixed, a `>`-prefixed, a text "Observation" result, and one µS/cm unit), 2 QC rows (`QC-000001` LCS-linked Fluoride, `QC-000002` MB-linked pH), 1 `YY0000001` foreign/NCP row | FIXTURES.md "Work orders & files -> ESdat" pinned table, reproduced verbatim (values, prefixes, units) |
| " | one embedded comma inside a value (`"Clear, low flow"`, quoted per RFC 4180) | real ESdat "Observation"-type text results routinely contain commas; exercises correct CSV quoting/parsing, not just naive `strsplit(",")` |
| " | `Electrical Conductivity @ 25°C` / `µS/cm` written as raw latin-1 bytes (`0xB0`/`0xB5`), not pre-decoded UTF-8 | A35: real files carry these as single latin-1 bytes; the fixture must exercise the same byte shape the adapter's `readr::locale(encoding = "latin1")` read has to decode, not a shape that's already correct under UTF-8 |
| `PROJ_A.ESDAT_XX1234567_0.Sample2e.CSV` | column header exactly `SampleCode,Sampled_Date_Time,Field_ID,Blank1,Depth,Blank2,Matrix_Type,Sample_Type,Parent_Sample,Blank3,SDG,Lab_Name,Lab_SampleID,Lab_Comments,Lab_Report_Number`; UTF-8, no BOM | FIXTURES.md pinned header + row table |
| " | 6 rows: 3 `Normal` (feature `T.S01`/`T.S02`/`T.MW01`, distinct sampled times all on 24 May 2025), 1 `LCS`, 1 `MB` (both blank Field_ID/time, matching real ESdat QC conventions), 1 `NCP` for a foreign work order `YY0000001` | FIXTURES.md pinned Sample2e table |
| `PROJ_A.ESDAT_XX1234567_0.Header.XML` | `<ESdat xmlns="http://www.escis.com.au/2013/XML" fileType="eLabResultsHeader"><LabReport Lab_Report_Number="XX1234567" Date_Reported="2025-05-28" Project_ID="PROJ_A" Lab_Name="ALSE-Sydney" .../>` with a nested `<eCoCs>` block | PLAN-04's pinned element/attribute shape + FIXTURES.md's pinned header values; namespace URL is the CONTRACT-pinned EScIS namespace |
| `PROJ_B.ESDAT_XX7654321_0.Sample2e.CSV` | lone Sample2e (no sibling Chemistry2e/Header in this delivery), 1 `Normal` row, `Field_ID = T.S01`, `26 May 2025 10:30`, `Lab_Report_Number = XX7654321` | FIXTURES.md "Lone `PROJ_B...XX7654321_0.Sample2e.CSV`" spec; exercises "adapter parses each file independently" (R-4.3: "Header-less/Chemistry-less lone Sample2e parses fine") |

## Additions beyond FIXTURES.md's pinned list (documented, see `PLAN-CHANGE-REQUESTS.md`)

| file | purpose |
|---|---|
| `NOT_ESDAT.xml` | generic, non-EScIS-namespaced XML, for R-4.4's negative criterion ("a non-ESdat XML aborts with `sampletidy_parse_error`") |
| `random.csv` | arbitrary 3-column CSV unrelated to any pinned adapter header, for R-4.1's "a random CSV matches `no`" criterion (also reused from `test-adapter-crosstab.R`) |
| `BADDATE.ESDAT_XX5555555_0.Chemistry2e.CSV` | single row, same pinned header, `Analysed_Date = "31 Undecember 2025"` (unparseable). FIXTURES.md's pinned 10-row table only uses the clean `26 May 2025` date, leaving no fixture data for R-4.5's "an unparseable date lands in `warnings` ... row still emitted with `analysed_date` NA" criterion |
| `CORRUPT.ESDAT_XX0000000_0.Chemistry2e.CSV` | deliberately corrupted fixture requested for the plan-09/10 "adapter crash on one file" e2e test - see below |

## The CORRUPT fixture, in detail

**REWORKED (A35, 2026-07-15).** The original version of this fixture relied
on a bare, invalid-on-its-own UTF-8 continuation byte (`0x80`) in
`OriginalChemName` to trip base R's `nchar()`/`toupper()` into a hard error.
That premise is now dead: the adapter reads Chemistry2e/Sample2e CSVs with a
**latin-1** locale (A35, required so real ALS files carrying raw `°`/`µ`
bytes parse at all), and under latin-1 every byte `0x00`-`0xFF` is a valid
codepoint, so `0x80` just decodes quietly as U+0080 - nothing errors on it.
A27 was refined accordingly: a file is `failed` only on **genuine structural
failure** (unreadable, or invalid even under latin-1), not merely for
containing a non-UTF-8 byte.

`CORRUPT.ESDAT_XX0000000_0.Chemistry2e.CSV` still has the **exact pinned
Chemistry2e header verbatim** (so `match()` still fingerprints it as an exact
ESdat file and the router *claims* it for the `esdat` adapter - an unclaimed
file would never reach the `claimed -> failed` transition plan-09 needs to
test). Its single data row is now genuinely corrupt CSV *structure*: the
`OriginalChemName` field opens a quoted field (`"`) that is never closed
anywhere else in the file. This is invalid CSV grammar under **any**
encoding - RFC 4180 requires every quoted field's opening quote to be matched
by a closing quote (and an escaped `""` still contributes an even number to
the running total), so a well-formed CSV always has an **even** total count
of `"` bytes; this file's count is **one** (odd), deliberately.

Empirically, `readr::read_csv()` itself does **not** raise an R error for
this on a plain file path - it silently swallows the rest of the file into
one runaway field and returns a suspicious near-empty/zero-row result with no
warning (verified in `generate.R`'s development notes). That silent failure
is exactly the "genuine structural corruption" A27/A35 need surfaced loudly,
so `R/adapter-esdat.R`'s `.st_esdat_check_quote_parity()` checks the raw byte
count explicitly before every ESdat CSV body read (both Chemistry2e and
Sample2e) and aborts with class `sampletidy_parse_error` on an odd count.
Verified in `test-adapter-esdat.R`, "R-4.2: corrupted Chemistry2e data
causes parse() to abort loudly".

## xlsx-for-xls substitution

Not applicable to this adapter family - ESdat deliveries are CSV/XML only, no
legacy binary spreadsheet format is involved.
