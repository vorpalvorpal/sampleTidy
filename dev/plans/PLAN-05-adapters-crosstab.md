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
| encoding | **UTF-8** (see R-5.4) | UTF-8 |
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
several; recent real files carry a single section — keep support, it is
legacy/rare). `----` = not computable. Values may carry `<`/`>` prefixes.

> **Real-corpus correction (A34, 2026-07-15).** Verified against real (now
> committed, anonymized) XTAB + ENMRG fixtures. The plan above is right; the
> plan-05 **WIP parser silently deviated from it** and the synthetic fixture was
> generated to match the deviated parser, so its green tests were misleading.
> Bring the parser back to this spec:
> - **`Analyte grouping/Analyte` is ONE column** (col 0), holding both
>   method-group rows and analyte rows. The WIP parser located the analyte
>   column with `^Analyte$` (never matches the real combined header); read
>   `analyte_raw` from the `Analyte grouping/Analyte` column instead. Drop the
>   synthetic ENMRG's two-column split.
> - **Locate every metadata label by regex across the WHOLE row**, per this
>   plan's own rule. Real per-sample labels (`Sample Type:`, `ALS Sample
>   Number:`/`number:`, `Sample date:`, `Client sample ID (…)`, `Sample Site:`,
>   `Purchase Order:`) sit at **col 3 (XTAB) / col 4 (ENMRG)**, packed
>   multiple-labels-per-row (`Matrix:`+`Sample Type:` share a row), values under
>   the sample columns (col 5+). The WIP parser inspected only col 0 and so
>   captured no sample type/date/feature on real files. Read each label's
>   per-sample values at the sample-column indices fixed by the `ALS Sample
>   Number` row. Section-scalar labels (`Matrix:`/`Client - Matrix:`,
>   `Workgroup:`, `Project name/number:`) stay at col 0, value at col 1.
> - **Header spellings differ by dialect** (fact absent from the table below):
>   XTAB writes `Unit` / `Limit of reporting`; ENMRG writes `Units` / `LOR`.
>   Match both spellings when locating the unit and reporting-limit columns.

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

## R-5.4 Encoding + symmetric encoding fallback (root-caused 2026-07-22)

**`als_xtab` reads UTF-8, not latin-1.** Real XTAB.csv is valid UTF-8 whose
degree/micro signs arrive already destroyed on disk to a single U+FFFD
replacement char (bytes `ef bf bd`). Reading it under a latin-1 locale SHATTERS
that one U+FFFD into three chars (`ï¿½`) that defeat `normalise_lab_text()`'s
single-U+FFFD repair table — so `Electrical Conductivity @ 25°C` silently
became `unknown_analyte`. The dialect's `encoding` is therefore `"UTF-8"`.

**Symmetric encoding fallback** (`.st_read_grid_with_encoding_fallback`, shared
with the ESdat adapter): every data-file CSV read reads with its declared
primary encoding, then computes a QUALITY PROBE = the number of text cells that
STILL contain a mojibake marker (U+FFFD, the shattered triple `ï¿½`, or the
escape spelling `<ef><bf><bd>`) AFTER `normalise_lab_text()` has run (warnings
suppressed). If the probe is 0 the primary read is returned immediately (a
clean file is NEVER re-read). If the probe is positive the file is re-read with
the alternate encoding, and the alternate is adopted ONLY when it has the same
row count as the primary AND a strictly lower probe; a `cli::cli_inform` note
naming the file and both encodings is emitted. crosstab: primary =
`dialect$encoding`, alternate = the other of {UTF-8, latin1}. ESdat keeps
latin-1 as its primary (those files are genuinely latin-1), so the fallback is
a strict no-op on clean ESdat files.

Criteria: (a) real XTAB fixture (`ES2600185_0_XTAB.csv`) parses to analyte
`Electrical Conductivity @ 25°C` and unit `µS/cm` (not `unknown`, no residual
mojibake marker); (b) a read whose default encoding is wrong is rescued by the
alternate; (c) a clean read is not re-read (probe == 0 path); (d) an
irrecoverable case (alternate no cleaner, or a different row count) keeps the
primary read.

## Fixtures

`fixtures/crosstab/XX1234567_0_XTAB.csv` (latin-1 bytes, two sections),
`…_XTAB.XLS` (same content), `XX1234567_0_ENMRG.CSV` (UTF-8, +2 QC cols),
`ZZ9999999_0_XTAB.csv` (mismatch case). Same synthetic features/analytes as
plan 04 so cross-format equivalence can be asserted in plan 07/10. Fixture
README records provenance of each structural property.
