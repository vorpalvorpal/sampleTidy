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

### R-6.5b What the A74 gate needs from the adapter (MEASURED 2026-08-01)

Written while implementing PLAN-09's gate. Two things the adapter exposed were
not enough, and both were found by measuring the corpus rather than by reading
this plan.

**1. Every `ALS … Report No` row is scanned, not just the first.** The extractor
took the first label row matching `ALS.*report\s*no` and stopped. `2400-7223-12-01
2022 December Quarterly Katoomba WMF.xls` carries two such rows on each water
sheet:

```
ALS Lithogw Report No | 2400-7223-12-01      <- matched first; no ES number
ALS Sydney Report No. | ES2246297            <- never reached
```

so the file reported citing **nothing**. Harmless while nobody acted on the
field; under the gate it is the difference between importing its 57 rows and
quarantining them. All matching rows are now scanned — a row with no `ES#######`
contributes nothing, so this costs only the loop. Pinned by a shadowing
`ALS Lithogw Report No` row on `2400-9999-13_AlsRefs`'s first sheet; restoring
the `break` turns that test red with `als_work_orders` empty.

**2. `report$n_water_sheets` is exposed.** An empty `als_work_orders` is
ambiguous on its own, and the two readings need opposite treatment. Measured
over the 154 claimed workbooks, 8 cite nothing:

| | count | correct treatment |
|---|---|---|
| no water sheet at all — dust-only | 7 | **exempt** (A73) |
| water sheets, but the ALS row reads a bare `ES` | 1 | **quarantine** |

The one is `2400-7483-01 May 2025 Lawson Landfill.xls`, whose eight water sheets
each carry `ALS Sydney Report No. | ES` — the number was never filled in. Had
the gate read "cites nothing → exempt", that file's 30 rows would have imported
with no traceable ALS source, which is precisely what A74 exists to stop.

`n_water_sheets` counts sheets **attempted** as water sheets, not sheets that
yielded rows. That direction is deliberate: a future parser bug then closes the
gate (quarantine, loud) instead of opening it (silent import).

### R-6.7 Site-metadata labels are not analytes (MEASURED 2026-08-01)

Found while measuring A75's value comparison, not by reading a sheet. A water
sheet may carry the sampling point's *alternative name* as an ordinary label
row. Measured over all 154 claimed workbooks there are exactly three such
labels, and their values are 100% non-numeric:

| label | rows | files |
|---|---|---|
| `Other Sample Id` | 2604 | 97 |
| `Other Site Name` | 26 | — |
| `Other Site ID` | 5 | — |

Values are things like `BORE 2`, `Cripple creek DS`, `EFFLUENT` — site names,
against the point code (`B.MW02`, `B.S01`, `B.EO1`) in the header row.

They previously took the `als_candidate` path, so under A75 rule (iv) — "has
values but neither allowlisted nor ALS-matched → review queue" — they would have
opened **~2,635 review items of pure noise, 21% of the entire no-twin
population**. They are now recognised by exact label match and skipped with
reason `site_metadata_label`.

**They are not discarded.** The point-code → name mapping is real evidence for
the feature-alias subsystem, so it is carried on `report$feature_aliases`
(`source_ref`, `feature_raw`, `label`, `alias`), deduped. Nothing consumes it
yet. Corpus effect: `als_candidates` 41,085 → **38,450**; result rows unchanged
at 5,704 (a metadata row was never a result); **91 distinct point → name pairs**
recovered.

The set is pinned in the adapter rather than in `st_config()` because, unlike
the field allowlist, it is not a policy choice — it is a fact about the sheet
layout, and a site name is never an analyte under any ruling.

Criteria: none of the three labels yields a result or an ALS candidate; the
skip reason is recorded; the alias mapping survives with a non-NA
`feature_raw`, deduped; and an ordinary analyte label is untouched (the match
is exact, never a prefix or substring).

### R-6.6 The widened field set and the observation split (A76, IMPLEMENTED 2026-08-01)

R-6.3b named A76's allowlist and split; this section is what implementing them
actually required, all of it measured before it was written.

**The allowlist is built from labels, not from analyte names.** A76 lists
analytes ("EC", "turbidity"); `st_config("field_analytes")` matches a *sheet
label* exactly. Two independent measurements ground the list: a census of all
13,768 label rows / 296 distinct labels in the corpus, and the 32 `lab_method`
rows already carrying `method = 'field'`, whose `name` column IS the ACIRL sheet
label. Where they agree the label is allowlisted; the four A76 analytes that
occur **zero** times (turbidity, DO, ORP, flow) are allowlisted anyway where a
`field` lab_method exists, so a future sheet imports rather than silently
routing to review.

**Two labels are deliberately excluded, for opposite reasons:**

- `Electrical Conductivity @ 25°C` is the ALS value transcribed into the sheet,
  never a field reading. Allowlisting it would import ALS data as a field
  reading, exactly what A74/A75 exist to prevent.

  The registry defect behind this was **narrower than first reported, and is now
  fixed.** The row ACIRL owned as `method = 'field'` was the **mojibake**
  spelling `Electrical Conductivity @ 25Â°C`, and it carried **zero analyses** —
  it had never mis-typed a single value. The clean-named row is correct (org
  ALS, `EA010P: Conductivity by PC Titrator`, 1272 analyses). The mojibake row
  was deleted from the live database on 2026-08-01 through the mutation layer
  (`change_log` uuid_row `9f59b10a`), after confirming no column in any of the
  18 tables referenced it. Deleting rather than re-encoding was deliberate:
  repairing the name would leave ACIRL owning a `field` method for an
  ALS-transcribed label, which is the wrong thing stated more explicitly, and
  there is no honest ACIRL `method` value for an ALS result. Note the two names
  do **not** collide under `.rc_method_key()` (`…25âc` vs `…25c`) —
  `normalise_lab_text()` does not repair this mojibake.
- The TSS pair (`Total Suspended Solids`, `Suspended Solids (SS)`) is a genuine
  ACIRL field estimate whose **name is the ALS analyte's**, so no name test can
  separate them. New config key `field_analytes_diff_required` holds them; the
  adapter emits them to `report$als_candidates` with `diff_required = TRUE` and
  skip reason `diff_required`, never as results. **Only A75's value comparison
  may promote one.** This makes "A75 before import" structural rather than a
  sequencing promise — 678 real rows currently sit behind it.

**The observation split applies to all three observation labels**, since the
value text, not the label, carries the distinction.
`.st_acirl_split_observation()` returns at most one `Stage` and one `Appearance`
term; `analyte_raw` is the registered `lab_method.name` (`Flow observation` →
`Stage`, `Comments` → `Appearance`) because reconcile resolves an analyte by
matching `lab_method.name` against `analyte_raw`. Both are qualitative:
`value_chr` holds the canonical term, `value_num` is NA, and `value_raw` keeps
the whole original string so the split is auditable from the row.

Vocabulary and precedence, all calibrated against the 262 distinct real
observation values (`scratchpad/a76_split_result.csv`):

- stage tier 1 — magnitude × noun, `{Very low, Low, Mod, High} × {flow, level,
  discharge}` — wins outright over tier 2, so "Pooled low level Clear" reads as
  `Low level`, not `Pooled`;
- stage tier 2 — standalone `No discharge` / `Pooled` / `Dry`, leftmost wins;
- appearance — `Slightly cloudy` before `Cloudy` before `Clear`;
- misspellings by **explicit alternation only, never fuzzy matching** (celar,
  clouidy, slighlty, "c lear", "high evel", run-together "lowflow"/"modflowClear");
- a third class — "could not locate", "no access", "decommissioned", "too
  dangerous to sample", "blocked" — describes no water and yields **neither**
  analyte. Its raw text still reaches `sample.comments`, as every observation's
  does, split or not.

**Dedupe**: at most one Stage and one Appearance row per sample column, first
non-NA wins top-to-bottom (Robin, 2026-08-01: "make sure we don't end up with
duplicate rows for the field rows"). Measured: the three observation labels
**never co-occur** on a real sheet (0 of 578), so this is defensive only — the
main fixture is deliberately stricter than reality in order to pin it.

Criteria (real-geometry fixture):
- `Electrical Conductivity` and `Standing Water Level` import; `Electrical
  Conductivity @ 25°C` stays an ALS candidate;
- `Total Suspended Solids` never appears in results, appears in
  `als_candidates` with `diff_required = TRUE` **and its values intact**, and no
  other candidate is diff-required;
- observation rows produce qualitative rows with `value_num` NA, `units_raw` NA
  and the full original text in `value_raw`;
- at most one Stage and one Appearance per `lab_sample_id`, earlier label wins;
- the splitter reproduces the measured vocabulary, including the misspellings,
  and yields neither analyte for the site-access class;
- "Clear, flow flow" yields **no** stage — the `low` inside `flow` must not
  manufacture a magnitude (this false positive was found by calibration, not by
  the suite, and the leading `\b` that kills it is mutation-verified).

Corpus effect, measured over all 213 workbooks before and after:

| | before step 3 | after |
|---|---|---|
| workbooks matched | 154 | 154 |
| workbooks yielding ≥1 row | 146 | **147** |
| total result rows | 2138 | **5704** |
| rows held for A75's value test | — | 678 |

The 7 workbooks still yielding nothing are all **dust-only** — R-6.4 territory.
Every water-bearing workbook now produces rows.

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

### R-6.4a Dust geometry, RE-MEASURED 2026-08-01 (before implementing)

All 50 real dust-results sheets and all 50 dust-observations sheets re-measured
rather than trusted from the prose above — the same discipline that caught the
water-sheet geometry. Most of R-6.4 holds; **two claims do not**, and both change
the implementation.

**1. The two dates A77 needs are on the OTHER sheet.** R-6.4 above reads as
though `Month` and `EXPOSURE DATE` are both on the results sheet. They are not —
the split is total and consistent:

| anchor | Dust Results | Dust Observations |
|---|---|---|
| `GAUGE NO.` | 50/50 | 0/50 (labelled `GAUGE`) |
| `INSOLUBLE SOLIDS`, `*COMBUSTIBLE MATTER`, `INCOMBUSTIBLE MATTER` | 50/50 | 0/50 |
| `Month` | 50/50 | **0/50** |
| `Exposure Days` | 50/50 | **0/50** |
| `EXPOSURE DATE` | **0/50** | 50/50 |
| `COLLECTION DATE` | **0/50** | 50/50 |
| `ANALYSIS OBSERVATIONS` | 0/50 | 50/50 |

So **A77's cross-check is inherently cross-sheet**: `Month` comes from Results,
`EXPOSURE DATE`/`COLLECTION DATE` from Observations, and they must be joined on
gauge + block before they can be compared. A dust-results sheet parsed alone can
never satisfy A77.

**2. The incombustible column shift is 49 of 50, not 50 of 50.** One sheet has
its `INCOMBUSTIBLE MATTER` values under their own header. The legacy reader's
`coalesce(last_col, last_col - 1)` is therefore load-bearing and must be ported
as a *coalesce*, not as a constant `+1` offset. A fixed offset silently reads
NA for that sheet.

Confirmed unchanged: 50 sheets; every anchor present on every sheet; gauges are
exactly `B.D07`/`B.D08` (50/50 each); month-blocks repeat 1× on 43 sheets, 2× on
3, 3× on 2, 4× on 2, with `Exposure Days` label rows tracking the block count
exactly; 11 of 50 sheets carry a `<` below-detection value.

**Also:** `Other Sample Id` appears on all 50 dust-results sheets too. R-6.7's
site-metadata rule is currently water-sheet only, so the dust parser must handle
it as well or it will re-introduce the same noise.

Measurement scripts: `scratchpad/dust_geometry.R`, `scratchpad/dust_obs_geometry.R`
(saved to `dust_geometry.rds`, `dust_obs_geometry.rds`).

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
