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
`(?i)front` **and** *either*

- any sheet has a `Units` marker cell in its first 15 rows (the water-sheet
  fingerprint, cheap `readxl` range read), **or**
- **(added 2026-08-01, A73)** any sheet matching `(?i)dust results` carries the
  dust fingerprint `GAUGE NO.` + `INSOLUBLE SOLIDS`.

`no` otherwise.

**Why the second arm is required.** A `Units` marker only ever occurs on a water
sheet. The 6 real dust-only workbooks (`2400-7286-10-02 Dust Blaxland WMF.xls`
and siblings) have a front page and dust sheets but no water sheet, so all 6
measured `match() == "no"` — the adapter never claims them. Reversing A10
without widening `match()` would therefore recover **no dust at all** from those
workbooks. Verified 2026-08-01 against all 6.

Criteria: ACIRL fixture → `format`; **the dust-only fixture
`2400-9999-12_DustOnly_WMF.xlsx` → `format`** (it is `no` under the old rule —
this is the regression guard); a random xlsx and the plan-05 `.XLS` crosstab →
`no`.

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

**IMPLEMENTED 2026-08-01.** Measured on the real corpus after the rewrite:

| | before | after |
|---|---|---|
| workbooks matched | 147 | **154** (the 7 dust-only ones now claimed) |
| workbooks yielding ≥1 row | **0 of 147** | **146 of 154** |
| total result rows | **0** | **2138** |
| sheets skipped `no_field_block` | 612 | **0** |

The 8 workbooks still at zero are the 7 dust-only ones (dust parsing is R-6.4,
not yet implemented) and `2400-7453-03 Annual March 2025 Blaxland WMF .xls`,
whose field labels are not on the un-widened allowlist — that resolves with A76.
2138 rows is with the **old** 4-entry allowlist still in force; A76 widens it.

Two criteria are **RETIRED** by this rewrite:

- *"a >20-row field block emits a warning but still parses"* — the warning
  measured the size of the terminator-bounded block, and there is no terminator
  any more (A75 classifies rows individually). Real sheets routinely carry ~50
  labelled rows, so the warning would now fire on essentially every sheet.
  Replaced by the positive property that a large sheet parses in full.
- *"a water sheet with no `Units` marker is skipped"* — the marker is now only
  the `match()` fingerprint and never locates the block, so such a sheet parses
  (with `units_raw` NA). The real skip is **`no_site_row`** — no `Site Name`
  anchor — which 70 real sheets take. `no_units_marker` and `no_field_block` no
  longer occur.

Mutation-verified: reverting `label_col` to the hardcoded `1L`, or searching for
the date row only *below* the header, each turns 12 tests red.

### Layer note — A74/A75 are NOT adapter concerns

An adapter's `parse(path, file_meta)` sees **one file and no database**, so it
cannot decide whether an ALS work order is held (A74) nor compare a value against
ALS results (A75). Enforcement is split, and this plan owns only the first row:

| concern | where it can see what it needs | plan |
|---|---|---|
| extract the ALS reference; classify rows; drop headings | per-file — **adapter** | R-6.3b below |
| decide the ALS source is missing → quarantine | needs the DB + batch — **`ingest_dir()`** | PLAN-09 |
| compare ACIRL values against ALS results | batch: `assemble_events(parsed)`; already-committed: `reconcile(con)` | PLAN-07 / PLAN-08 |

The adapter therefore **defers, never guesses**: it emits every candidate row
tagged with its classification and lets a later stage that can see the ALS data
make the call.

### R-6.3b Row classification, adapter side (A75 steps i/v, A76)

- a row with **no value in any sample column** (`Dissolved Major Cations`,
  `Total Hardness`, …) is dropped as a heading, emits **no** result and **no**
  review item — this is decidable per-file, so the adapter does it;
- `----` is recorded as "not analysed" (`skipped`), never parsed as a value;
- a row whose label is on A76's field allowlist → emitted tagged
  `field_candidate`;
- any other valued row → emitted tagged `als_candidate`, **not dropped** — the
  old behaviour of dropping it as `lab_data_dropped` at the adapter is what made
  A75's value test impossible, since the values never survived to be compared;
- observation labels split per A76: flow → `Stage`, clarity → `Appearance`, both
  carried as `value_chr`;
- `report$als_work_orders` lists every `ES#######` found in the
  `ALS Sydney Report No.` row (empty when the row is absent or unparseable).

Criteria: a heading row yields nothing; a `----` cell is skipped not valued; both
`pH` and `pH Value` survive parse as `field_candidate`/`als_candidate`
respectively; `report$als_work_orders` is exact for a two-order citation
(`ES2110541/ES2111935`) and empty for a bare `ES`.

### R-6.5 Expose the ALS reference (gate itself is PLAN-09)

Water sheets only. The adapter surfaces `als_work_orders` per R-6.3b and takes no
action on it. **PLAN-09 owns the gate**: if any cited order is not held, the file
is quarantined `als_source_missing` naming the unresolved orders; a workbook
citing two orders with only one held is quarantined; a dust-only workbook is
**never** gated; the rest of the batch still processes; an unparseable reference
quarantines rather than silently passing.

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
