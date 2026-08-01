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

> **GEOMETRY SUPERSEDED BY R-6.3a (2026-08-01), SELECTION BY R-6.3b.** The
> layout described in this section and in the "Layout facts" preamble was never
> measured against a real workbook and is wrong in three independent ways; it
> yielded zero rows from all 147 real ACIRL workbooks. The mapping and the units
> repairs below still stand. The allowlist rule below is replaced by A75's
> value-based test — `field_analytes` was `c("pH","Temperature","Conductivity",
> "EC")` matched exactly, which drops `Electrical Conductivity` (217 real
> occurrences) and `Standing Water Level` (87).

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

### R-6.3a Real-workbook geometry (REWRITE, 2026-08-01)

**The geometry above was wrong and is superseded.** It was reproduced from this
plan's prose into synthetic fixtures, never from a real workbook, so the adapter
passed 100% of its tests while extracting **zero rows from all 147 real ACIRL
workbooks** (612 water sheets skipped `no_field_block`). Measured over 986 real
water sheets:

| property | what the old fixtures encoded | real workbooks |
|---|---|---|
| `Units` marker shares a row with `Site Name` | yes | **never** (0 of 640) |
| field-label column | column 1 (hardcoded `mat[, 1]`) | the `Site Name` column — 2 dominant, also 1/3/7 |
| `Date` row | below the header row | **above** the `Site Name` row (640 of 640) |

`Site Name` is always exactly one column left of the `Units` marker (1→2, 2→3,
3→4), so the geometry is recoverable. **Anchor on the `Site Name` row for feature
names and on `Date of Sample`/`Date` for dates; derive the label and units
columns from the `Site Name` position. Never hardcode a column index.**

Criteria: fixtures re-cut from real geometry (anonymised per A3) must include a
`Units` marker on its own row, a date row *above* the site row, and interleaved
ALS rows; the adapter extracts a non-zero row count from **every** structural
variant present in the corpus.

### R-6.3b Field-vs-ALS selection by value (A75, A76)

Implements A75's five-step rule and A76's field set. Criteria:

- a row with no value in any sample column (`Dissolved Major Cations`,
  `Total Hardness`, …) is dropped as a heading and emits **no** review item;
- where a sheet carries both `pH` (field) and `pH Value` (ALS copy), and the
  latter equals the ALS value, **only the field row is imported** — same for
  `Electrical Conductivity` vs `Electrical Conductivity @ 25°C`;
- a value-matching row whose ALS twin is `EN67 - Client Supplied Data` is **kept
  as a field reading**, and produces exactly one row, not two (A75 dedupe key);
- a valued row that is neither allowlisted nor ALS-matched raises a
  **review_queue** item (never a silent import, never a silent drop);
- `----` is recorded as "not analysed", not parsed as a value;
- observation labels split per A76: flow → `Stage`, clarity → `Appearance`, both
  as `value_chr`.

### R-6.5 ALS-linkage gate (A74)

Water sheets only. Extract every `ES#######` from the `ALS Sydney Report No.`
row; if any is not held, quarantine the **file** with reason
`als_source_missing` naming the unresolved orders. Criteria: a workbook citing
two orders with only one held is quarantined; a dust-only workbook is **never**
gated; the rest of the batch still processes; an unparseable reference (bare
`ES`, blank, or an ACIRL number in the ALS field) quarantines rather than
silently passing.

## R-6.4 Dust sheets — PARSED (A73, supersedes A10)

Both dust sheets are parsed. `Dust Results` → `dust-total` ←
`INSOLUBLE SOLID`, `dust-combustible` ← `*COMBUSTIBLE MATTER`,
`dust-incombustible` ← `INCOMBUSTIBLE MATTER` (units `g/m2/month`).
`Dust Observations` → `Appearance` via lab_method `ANALYSIS OBSERVATIONS`
(`value_chr`). Exempt from R-6.5.

Structural facts measured across all 50 real dust-results sheets (every one
carries every anchor; all use gauges `B.D07`/`B.D08`):

- **quarterly sheets repeat the month-block** — 2 gauge rows + one
  `Exposure Days` row, up to 4 blocks; `Exposure Days` rows are not results;
- **the last analyte is column-shifted**: `INCOMBUSTIBLE MATTER`'s values sit one
  column right of its header (merged-cell artifact; the legacy reader used
  `coalesce(last_col, last_col - 1)`);
- **below-detection values** appear as `<0.1`, making the column text →
  `below_detection = TRUE`, value stripped of `<`;
- **exposure dating is cross-checked per A77** — parse both `Month` and
  `EXPOSURE DATE`/`COLLECTION DATE`, and route disagreements to review.

Criteria: a quarterly fixture with 3 month-blocks yields 3 × 2 × 3 results and no
`Exposure Days` row; the shifted incombustible column is read from the correct
cell; `<0.1` sets `below_detection`; a fixture whose `Month` contradicts its
`EXPOSURE DATE` raises a review item rather than silently picking one.

## Fixtures

**Re-cut from real geometry (2026-08-01)** — see R-6.3a. The previous synthetic
fixtures encoded a layout that occurs zero times in the real corpus and must not
be used as the model. Anonymise per A3 (synthetic site/feature names), but
preserve every structural property measured above: column offsets, the `Units`
marker on its own row, the date row above the site row, interleaved ALS rows, the
`ALS Sydney Report No.` row, a repeated quarterly dust month-block, and the
column-shifted incombustible values. README records the provenance of every
structural property ([MEASURE TWICE]) **and cites the real workbook each property
was measured from**.
