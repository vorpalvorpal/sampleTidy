# PLAN 04 — `esdat` adapter

**Owns:** `R/adapter-esdat.R`, `tests/testthat/test-adapter-esdat.R`,
`tests/testthat/fixtures/esdat/…` (synthetic; A3). **Depends on:** 01–03.

ESdat is the EScIS lab EDD (XML namespace `http://www.escis.com.au/2013/XML`,
`fileType="eLabResultsHeader"`). One "delivery" = up to three files sharing a
filename stem `<project>.ESDAT_<workorder>_<rev>.<part>`, `part ∈
{Chemistry2e.CSV, Sample2e.CSV, Header.XML}`. Parts can arrive alone; the
adapter parses **each file independently** (assembly joins them, plan 07).

## Pinned column contracts (observed; fixtures must reproduce exactly)

Chemistry2e: `SampleCode, ChemCode, OriginalChemName, Prefix, Result,
Result_Unit, Total_or_Filtered, Result_Type, Method_Type, Method_Name,
Extraction_Date, Analysed_Date, EQL, EQL_Units, Comments, Lab_Qualifier,
UCL, LCL`. Dates like `26 May 2025`.

**Encoding — CORRECTED (A35, 2026-07-15):** real Chemistry2e/Sample2e CSVs are
**latin-1**, not UTF-8: names such as `Electrical Conductivity @ 25°C` carry the
raw byte `0xB0` (`°`), and `µ` (`0xB5`) appears in units. The adapter MUST read
CSVs with `readr::locale(encoding = "latin1")` (as the XTAB crosstab dialect
does), then `normalise_lab_text()` repairs any residual mojibake. Reading as
UTF-8 makes `normalise_lab_text()`'s `gsub()` abort ("input string is invalid
UTF-8") on ordinary valid files (verified: 17 affected rows in one real file). A
leading UTF-8 BOM may still appear on the first header cell and must be stripped
before the header fingerprint compare (R-4.1).

Sample2e: `SampleCode, Sampled_Date_Time, Field_ID, Blank1, Depth, Blank2,
Matrix_Type, Sample_Type, Parent_Sample, Blank3, SDG, Lab_Name, Lab_SampleID,
Lab_Comments, Lab_Report_Number`. `Sampled_Date_Time` like
`24 May 2025 11:45` — **field collection time** (DESIGN §2.1).

Header.XML: `<ESdat><LabReport Lab_Report_Number=… Date_Reported=…
Project_ID=… Lab_Name=… Lab_Signatory=…>` with nested `eCoCs`.

## R-4.1 `match()`

`exact` when: ext `xml` and peek contains `escis.com.au` **or** ext `csv` and
the header row equals one of the two pinned column lists (compare first-line
field names, case-sensitive). Else `no`. Criteria: all three fixture parts
match `exact`; an XTAB fixture, an ENMRG fixture, and a random CSV match `no`.

## R-4.2 Chemistry2e → `ir_results`

Field mapping (IR ← source): `work_order` ← `SampleCode` prefix
(regex `^[A-Z]{2}\d{7}`) — **not** the filename; `revision` ← filename
`revision_guess`; `lab_sample_id` ← `SampleCode`; `analyte_raw` ←
`OriginalChemName`; `cas_number` ← `ChemCode` when it matches
`^\d{2,7}-\d{2}-\d$` else NA; `method_raw` ← `Method_Name`;
`total_or_filtered` ← as-is; `units_raw` ← `Result_Unit`; `value_raw` ←
`paste0(Prefix, Result)` verbatim; value fields via `parse_value()` on that;
`rl` ← `EQL` numeric; `lab_qualifier`, `comments` ← as-is; `analysed_date` ←
parsed `esdat` format; `org = "ALS"`; `adapter = "esdat/<version>"`;
`source_ref` ← `paste0("row", <1-based data row>)`; `confidence = 1`;
`sample_type` — `"unknown"` for ordinary rows (the adapter parses each file
independently and never reads siblings; assembly, plan 07 R-7.3, fills the
authoritative value from Sample2e), EXCEPT the compound-SampleCode NCP rows of
R-4.6 below, which are marked `"NCP"` at parse time.

## R-4.6 NCP cross-reference detection (Chemistry2e)

ESdat bundles "NCP" cross-reference results belonging to OTHER work orders
into a report. Chemistry2e carries no `Sample_Type`/`Lab_Report_Number` column,
so the only parse-time signal is a **compound `SampleCode`** of the shape
`<origWO>001_<homeWO>` — a leading work order + sequence, an underscore, then
the home work order (e.g. `ES2617015001_ES2617126`). The chemistry parser
detects these (regex `^[A-Z]{2}\d{7}\d*_[A-Z]{2}\d{7}$`, whose WO prefix reuses
`.st_esdat_work_order_re`) and sets `sample_type = "NCP"`; `work_order` is left
as the ORIGINATING (foreign) WO so assembly (R-7.4) reads the row as
foreign-AND-NCP — counted in `n_ncp_foreign` and dropped before commit, never
flagged `foreign_work_order`. This detection MUST run before the R-7.4
multi-work-order partition, which operates on this raw parser output BEFORE the
sample-metadata join could fill `sample_type` (that join, "always overrides
sample_type", runs too late for the partition). A plain code with no `_<home>`
suffix stays `"unknown"` — a genuine foreign row remains reviewable. Criterion:
a `<orig>001_<home>` row parses `sample_type = "NCP"` with `work_order` = the
originating WO; plain codes stay `"unknown"`; `ir_validate()` passes.

Criteria (fixture: 2 work orders × 3 samples × 3 analytes + 2 QC rows +
1 plain foreign row + 1 compound-SampleCode NCP row, one `<`-prefixed, one
`>`-prefixed, one text result, one µ-unit):
- row count = source data rows; no row silently dropped;
- multi-work-order partitioning: `work_order` column has both ids; rows are
  NOT filtered by work order (reconciler/assembly decide);
- `value_raw` for the `<` row is `"<0.1"`, `below_detection` TRUE, `rl` 0.1;
- a latin-1 `µ`/`°` in a unit/analyte name is decoded and normalised (A35) —
  `µS/cm` and `25°C` in the output — from a fixture that carries the real raw
  bytes, not pre-decoded Unicode;
- `ir_validate()` passes on the output.

## R-4.3 Sample2e → `ir_samples`

Mapping: `lab_sample_id` ← `SampleCode`; `feature_raw` ← `Field_ID`;
`sample_datetime_raw` ← `Sampled_Date_Time` verbatim; `sample_type`,
`parent_sample`, `matrix_raw` (← `Matrix_Type`), `work_order` ←
`Lab_Report_Number` (fallback SampleCode prefix); `org = "ALS"`; `sampler` NA
(not in ESdat). Criteria: fixture (Normal + one each of `LCS`/`MB`/`LAB_D`/`MS`/
`NCP` — all five confirmed present in the real corpus per A36) maps 1:1;
`Sample_Type` values pass through verbatim; `ir_validate()` passes;
Header-less/Chemistry-less lone Sample2e parses fine. `MS` rows carry a
`Parent_Sample`; the adapter copies it through and never filters QC (the
reconciler filters ≠ `Normal` in the MVP).

## R-4.4 Header.XML → report metadata

Parse with `xml2`; namespace-safe. Emit zero-row `results`/`samples` plus
`report$header = list(work_order, date_reported, project_id, lab_name)`.
Criteria: fixture XML yields the pinned values; a non-ESdat XML aborts with
`sampletidy_parse_error` (router should never send one, but fail loud).

## R-4.5 `parse()` report

Every parse returns `report`: `list(n_rows, n_by_sample_type
(named int), skipped (tibble: source_ref, reason), header (or NULL),
warnings (chr))`. Criterion: QC/NCP rows appear in `n_by_sample_type`, not in
`skipped`; an unparseable date lands in `warnings` with its `source_ref`, the
row still emitted with `analysed_date` NA.

## Fixtures (synthetic, structurally exact)

`fixtures/esdat/PROJ_A.ESDAT_XX1234567_0.{Chemistry2e.CSV,Sample2e.CSV,
Header.XML}` + a lone `PROJ_B.ESDAT_XX7654321_0.Sample2e.CSV`. Feature names
`T.S01/T.S02/T.MW01`; analytes `pH Value`, `Fluoride` (CAS 16984-48-8),
`Electrical Conductivity @ 25°C`; values chosen so every parse_value branch
in the fixture is hit. A `README.md` in the fixture dir records the real-file
provenance of each structural property ([MEASURE TWICE] trace).

**Rework note (A35, 2026-07-15):** the Chemistry2e fixture must be **regenerated
to carry the real raw latin-1 bytes** (`0xB0` in `…25°C`, `0xB5` in a `µS/cm`
unit), so `match()`/parse exercise the latin-1 read path against real-shaped
bytes rather than pre-decoded UTF-8. The Sample2e fixture gains one `LAB_D` and
one `MS` row (A36). The `CORRUPT.…Chemistry2e.CSV` fixture, which currently
relies on a bare non-UTF-8 byte to force an abort, must be revised: under A35 a
non-UTF-8 byte is *normal* and read as latin-1, so genuine corruption must be
represented some other way (e.g. a byte invalid even under latin-1, a truncated
row, or a structurally broken header) — otherwise the "adapter crash → file
`failed`" path (R-9.5) is no longer reachable by that fixture.
