# PLAN 06 — `acirl_field_xlsx` adapter

**Owns:** `R/adapter-acirl-field.R`, `tests/testthat/test-adapter-acirl.R`,
`tests/testthat/fixtures/acirl/…`. **Depends on:** 01–03. Parallel-safe with
04/05.

Source: the ACIRL monthly workbook (`2400-*.xls`), human-edited. Contains a
front-page sheet (report metadata), method sheets, optional dust sheets, and
per-visit "water" sheets holding a transposed field-data block **plus copies
of ALS lab results which must be dropped at the adapter** (DESIGN §2.3).
Reference implementation: `WEM.data/R/new/import/read_ACIRL_field_data.R`
(`tidy_ACIRL_field_data`) and `read_ACIRL_front_page.R` — port the layout
logic, not the GlobalEnv/auto-add behaviour.

Layout facts (from the old reader; fixtures must reproduce): sheet names —
front page matches `(?i)front`, dust `(?i)dust`, methods `(?i)method`, all
other sheets are water sheets. Water sheet: a marker cell `Units`; a header
row matching `^Site Name`; a date row (`(?i)date`); the field-data block ends
at the last row matching
`(^pH$|Temperature|Conductivity$|^EC$|Comments|Water)`; below/right of that
sit ALS lab-result copies (ignore). After transposition the block yields
columns `(date, name.feature, <one col per row-label>)`; a units row is the
one where date is NA; dates are Excel serials; the same sheet can hold
multiple visits (date filled down). Front page: `REPORT NO:` / `SAMPLED BY:`
/ `SAMPLE DATE:` values sit to the right of their key cells
(`vector_from_key(direction = "right")`).

## R-6.1 `match()`

`format` when ext ∈ {xls, xlsx} and `sheet_names` contains a front-page match
`(?i)front` **and** any sheet has a `Units` marker cell in its first 15 rows
(cheap `readxl` range read). `no` otherwise. Criteria: ACIRL fixture →
`format`; a random xlsx and the plan-05 `.XLS` crosstab → `no`.

## R-6.2 Front page → report + samples context

Extract `report_no` (verbatim, e.g. `2400-7539-05`), `sampled_by` (strip
trailing `&…`, squish), `sample_date`. Emit `report$header` and use as
defaults for water sheets missing values. **No site-name regex** — the old
`Blaxland|Katoomba|…` hardcoding must not be ported (CONTRACT conventions);
site resolution is the reconciler's job via feature masks. Criteria: fixture
front page yields the three values; missing `REPORT NO:` → parse continues,
warning recorded, `work_order = NA`.

## R-6.3 Water sheets → `ir_results` + `ir_samples`

For each water sheet: locate block, transpose, identify units row, pivot to
long `(date, feature_raw, analyte_raw, value_raw)`. Keep **only** rows whose
`analyte_raw` (after `normalise_lab_text()`) matches the configured field-
analyte allowlist `st_config("field_analytes")` (exact match after squish,
case-insensitive); everything else → `report$skipped` reason
`"lab_data_dropped"`. `Comments` rows attach to `ir_samples$comments`, not as
results.

Mapping: `work_order` ← `report_no`; `revision` 0; `org = "ACIRL"`;
`sample_type = "Normal"`; `units_raw` ← units row for that analyte with the
old reader's repairs (Temperature → `°C`, `pH Units` → `pH`, strip leading
junk before `µ`); `sample_datetime_raw` ← Excel serial → `dd/mm/YYYY` string
(date-only; A11 — clock time comes post-MVP); `sampler` ← `sampled_by`;
`feature_raw` ← site-name column value.

Criteria (fixture: 2 water sheets, 2 visits each, 3 features, field block =
pH/EC/Temperature/Comments + 4 fake ALS analyte rows below):
- every fixture ALS row is skipped with `lab_data_dropped` — **zero** of the
  fake lab values appear in results;
- results = features × visits × 3 field analytes minus genuinely empty cells
  (empties in `skipped`, reason `empty`);
- units: `EC` row with `µS/cm` mojibake variant normalises; Temperature gets
  `°C` even when the sheet writes `oC`;
- date fill-down: second visit rows carry the second date;
- Comments cell text lands on the matching `ir_samples` row;
- `>20`-row block emits a warning (old reader's sanity check), still parses;
- a sheet with no `Units` marker → sheet skipped, `report$warnings` entry,
  other sheets still parse (fail loud per sheet, not per file).

## R-6.4 Dust sheets (A10)

Detected by name, **not parsed**: `report$skipped` one entry per dust sheet,
reason `"dust_sheet_ignored"`. Criterion: fixture with one dust sheet records
exactly one such skip and no dust-derived rows.

## Fixtures

`fixtures/acirl/2400-9999-01 Test Month WMF.xls` — build as `.xlsx` with the
same structure if writing legacy `.xls` proves impractical, and note it in
the fixture README; `match()` and tests then cover both extensions. Synthetic
sites/features consistent with plans 04/05 (`T.S01`…). README records the
provenance of every structural property ([MEASURE TWICE]).
