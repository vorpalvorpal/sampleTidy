# Coverage map

Criterion → test name(s), per plan. Append-only; each worker adds its own
section.

# Core (plans 01-03)

## Plan 01 - foundations

### R-1.1 `st_config()`
- unset key, no default, aborts naming the key → `tests/testthat/test-config.R`
  "R-1.1: unset key with no default aborts naming the key"
- set → get round-trip → "R-1.1: set then get round-trips through options"
- env var wins over built-in default → "R-1.1: env var wins over built-in default"
- option wins over env var → "R-1.1: option wins over env var"
- `live_db` default under `R_user_dir` → "R-1.1: live_db default lives under R_user_dir, never a cloud-sync path"
- `field_analytes` pinned default → "R-1.1: field_analytes default is the pinned vector"
- ALS-transcribed labels stay off the allowlist (A76) → "R-1.1: the ALS-transcribed labels are NOT on the field allowlist"
- `acirl_transcription_labels` pinned default (was `field_analytes_diff_required`; A75's value comparison was replaced and measurement settled the pair as transcriptions, 2026-08-02) → "R-1.1: acirl_transcription_labels default is the pinned TSS set"
- list-key env-var guard covers the new key → "R-12.11: acirl_transcription_labels is guarded as list-valued too"
- widened allowlist imports EC / SWL (A76) → "R-6.6: the widened allowlist imports Electrical Conductivity and Standing Water Level"
- a name-colliding transcription label never imports on its name; its values (including ALS's own `<5` limit) survive parse → "R-6.6: a transcription label is never imported on its name alone"
- observation → qualitative Stage/Appearance (A76) → "R-6.6: observations split into one Stage and one Appearance qualitative row"
- one Stage + one Appearance per column (A76 dedupe) → "R-6.6: at most one Stage and one Appearance row per sample column"
- raw observation text preserved on the sample → "R-6.6: the raw observation text still reaches the sample, unsplit"
- splitter matches the measured vocabulary → "R-6.6: the observation splitter reproduces the measured corpus vocabulary"
- `remove_ingested` default TRUE (supersedes A13's FALSE, 2026-07-23) → "R-1.1: remove_ingested default is TRUE (supersedes A13's FALSE, 2026-07-23)"
- `corpus_dir` special default via `Sys.getenv("SAMPLETIDY_CORPUS")` → "R-1.1: corpus_dir defaults from Sys.getenv(SAMPLETIDY_CORPUS)", "R-1.1: corpus_dir defaults to empty string when SAMPLETIDY_CORPUS unset"

### R-1.2 `hash_file()`
- known 3-byte file hashes to precomputed digest → `tests/testthat/test-hash.R`
  "R-1.2: known 3-byte fixture file hashes to its precomputed digest"
- identical bytes, different name/mtime, hash equal → "R-1.2: two files with identical bytes but different names/mtimes hash equal"
- missing file aborts (sampletidy_error) → "R-1.2: missing file aborts with class sampletidy_error"

### R-1.3 `with_db_write()`
- returns `fn(con)`'s value; connection closed after → `tests/testthat/test-db-connect.R`
  "R-1.3: with_db_write() returns fn(con)'s value; the connection is truly closed after (cross-process check)"
- busy: retries then aborts after max_wait with "busy" message → "R-1.3: retries then aborts after max_wait with a busy message when RW-locked by another process"
- non-lock connect error aborts immediately, elapsed < 2s → "R-1.3: a non-lock connect error (path is a directory) aborts immediately, not after max_wait"
- `fn` throwing still closes the connection → "R-1.3: fn throwing still closes the connection (on.exit) - error surfaces and lock releases (cross-process check)"

### R-1.4 `st_connect()`
- read-only connection cannot write → "R-1.4: read-only connection cannot write", "R-1.4: read_only defaults to TRUE"
- nonexistent file + read_only=TRUE aborts with path in message → "R-1.4: nonexistent file with read_only = TRUE aborts with the path in the message"
- read_only=FALSE creates the file if absent → "R-1.4: read_only = FALSE creates the file if absent"

### R-1.5 `ensure_schema()`
- fresh DB creates all five ops objects → `tests/testthat/test-db-schema.R`
  "R-1.5: ensure_schema() creates all five ops objects on a fresh DB"
- schema_version holds every migration version → "R-1.5: schema_version holds every migration version applied"
- calling twice is a no-op → "R-1.5: calling ensure_schema() twice is a no-op (row counts and versions unchanged, no error)"
- never drops/narrows existing core-table columns → "R-1.5: ensure_schema() never drops or narrows existing core-table columns"

### R-1.6 state transitions
- legal path walks end to end → "R-1.6: a legal state path walks end to end"
- illegal jump (seen→committed) aborts naming both states → "R-1.6: an illegal jump (seen -> committed) aborts naming both states"
- any state → failed → "R-1.6: any state can transition to failed"
- terminal states cannot transition further → "R-1.6: terminal states (e.g. archived) cannot transition further without reset = TRUE"
- upsert updates updated_at; sighting only when path differs from path_first_seen → "R-1.6: upsert on an existing hash updates updated_at, preserves path_first_seen, and appends a sighting only when the path differs"

## Plan 02 - primitives

### R-2.1 `normalise_lab_text()`
- each `.lab_text_mojibake_fixes` table entry round-trips (7 verbatim + MacRoman
  degree + 3 cp1252 pairs = 11 parametrised cases) → `tests/testthat/test-text-normalise.R`
  "R-2.1: mojibake table entry round-trips: ..." (one per case)
- unmatched U+FFFD warns (class sampletidy_warning), returned unchanged → "R-2.1: text containing an unmatched U+FFFD warns (class sampletidy_warning) and is returned unchanged"
- NULL input returned as-is → "R-2.1: NULL input is returned as-is"
- empty character input returned as-is → "R-2.1: empty character input is returned as-is"
- NA elements stay NA, no warning → "R-2.1: NA elements stay NA, no warning, alongside real substitutions"

### R-2.2 unit engine
- `unify_value(1, "mg/L", "µg/L") == 1000` → `tests/testthat/test-units.R`
  "R-2.2: unify_value(1, 'mg/L', 'ug/L') == 1000"
- vectorised mixed groups, order preserved → "R-2.2: unify_value() vectorised over mixed unit groups preserves input order"
- identical from/to unchanged, no round-trip → "R-2.2: identical from/to units returns the input unchanged (no units round-trip)"
- invalid unit aborts with string in message, class sampletidy_units_error → "R-2.2: invalid unit aborts with the offending string in the message, class sampletidy_units_error"
- `are_compatible_units("mg/L","°C")` FALSE → "R-2.2: are_compatible_units('mg/L', 'degC') is FALSE"
- `are_compatible_units("mg/L","g/m3")` TRUE → "R-2.2: are_compatible_units('mg/L', 'g/m3') is TRUE"
- `is_valid_unit()` accepts known / rejects gibberish → "R-2.2: is_valid_unit() accepts a known unit and rejects gibberish"
- NA semantics: both NA unchanged → "R-2.2: NA semantics - both units NA leaves value unchanged"
- NA semantics: from NA unchanged → "R-2.2: NA semantics - units_from NA leaves value unchanged"
- NA semantics: to NA while from set aborts → "R-2.2: NA semantics - units_to NA while units_from is set aborts"
- pH/pH Unit/pH_Units unitless aliases → "R-2.2: pH / pH Unit / pH_Units are registered as valid dimensionless unitless aliases", "R-2.2: unify_value() converts between pH unitless aliases without changing the value"

### R-2.3 `parse_value()`
- exactly the pinned table (8 rows, parametrised) → `tests/testthat/test-values.R`
  "R-2.3: parse_value() table row 1..8: ..."
- NA input like empty input → "R-2.3: NA input behaves like empty input (skip_reason = 'empty')"
- thousands commas ("1,320" → 1320) → "R-2.3: numeric strings with thousands commas parse correctly ('1,320' -> 1320)"
- whitespace tolerated → "R-2.3: whitespace around a value is tolerated", "R-2.3: whitespace around a below-detection value is tolerated"
- vectorised, one row per input in order → "R-2.3: parse_value() is vectorised and returns one row per input, in order"

### R-2.4 `parse_lab_datetime()` / `excel_date()`
- esdat clock time → `tests/testthat/test-dates.R`
  "R-2.4: 'esdat' format with clock time parses to the correct Australia/Sydney wall time"
- esdat date-only → midnight → "R-2.4: 'esdat' date-only format parses to midnight"
- crosstab d/m/y, "05/01/2026" → 5 January (load-bearing) → "R-2.4: 'crosstab' format is d/m/y - '05/01/2026' parses as 5 January (load-bearing)"
- invalid date NA, not reinterpreted → "R-2.4: an invalid date '13/13/2025' is NA, not silently reinterpreted"
- mixed vector parses element-wise → "R-2.4: a mixed vector parses element-wise"
- empty string → NA → "R-2.4: empty string input is NA"
- iso format (bonus, not explicitly required) → "R-2.4: 'iso' format parses both date-time and date-only forms"
- `has_clock_time()` → "R-2.4: has_clock_time() is TRUE iff a time component was present in the source string"
- `excel_date(45802) == as.Date('2025-05-25')` → "R-2.4: excel_date(45802) == as.Date('2025-05-25')"

### R-2.5 spreadsheet tools
- `str_which_df()` exact single-cell match → `tests/testthat/test-spreadsheet-tools.R`
  "R-2.5: str_which_df() finds the exact cell for a single match"
- `multiple_matches = FALSE` two hits aborts → "R-2.5: str_which_df() with multiple_matches = FALSE (default) aborts on two hits"
- zero hits → zero-row tibble → "R-2.5: str_which_df() returns a zero-row tibble for zero hits"
- `vector_from_key()` direction="right" → "R-2.5: vector_from_key() direction = 'right' returns the cell(s) to the key's right"
- direction="down" → "R-2.5: vector_from_key() direction = 'down' returns the cell(s) below the key"
- remove_na=TRUE drops NA before length check → "R-2.5: vector_from_key() remove_na = TRUE drops NAs before length-checking"
- remove_na=FALSE keeps NA → "R-2.5: vector_from_key() remove_na = FALSE keeps NAs, matching the un-trimmed length"
- wrong length aborts → "R-2.5: vector_from_key() aborts when the extracted vector doesn't match vector_length"

## Plan 03 - IR, registry, router

### R-3.1 IR constructors
- `ir_results()`/`ir_samples()` zero-row prototype, exact cols/order/types → `tests/testthat/test-ir.R`
  "R-3.1: ir_results() with no args returns the zero-row prototype with exact columns, order and types",
  "R-3.1: ir_samples() with no args returns the zero-row prototype with exact columns, order and types"
- prototype round-trips validation → "R-3.1: the zero-row prototypes round-trip ir_validate()"
- constructor with named args → "R-3.1: ir_results(...) constructs a validated single-row tibble from named column args"
- missing column → "R-3.1: ir_validate() aborts on a missing column, naming it"
- extra column → "R-3.1: ir_validate() aborts on an extra column, naming it"
- wrong type → "R-3.1: ir_validate() aborts on a wrong-typed column, naming it"
- NA in source_hash → "R-3.1: ir_validate() aborts on NA in required field source_hash, naming it" (+ samples variant)
- NA in org → "R-3.1: ir_validate() aborts on NA in required field org, naming it"
- NA in adapter → "R-3.1: ir_validate() aborts on NA in required field adapter, naming it"
- NA in analyte_raw (results only) → "R-3.1: ir_validate() aborts on NA in required field analyte_raw (results only), naming it"
- NA in value_raw (results only) → "R-3.1: ir_validate() aborts on NA in required field value_raw (results only), naming it"
- sample_type not in allowed set → "R-3.1: ir_validate() aborts when sample_type is not in the allowed set" (+ samples variant)
- revision < 0 → "R-3.1: ir_validate() aborts when revision < 0"

### R-3.2 `file_meta()`
- "ES2600194_0_XTAB.csv" → work_order/revision → `tests/testthat/test-file-meta.R`
  "R-3.2: clean filename yields the correct work order and revision guesses"
- junk prefix → "R-3.2: a junk prefix before the work order does not throw off the guess"
- ESdat dotted-prefix filename → "R-3.2: an ESdat-style dotted-prefix filename parses work order and revision"
- no matching work order → NA → "R-3.2: a filename with no matching work-order pattern yields NA"
- revision anchored immediately after work order (A12) → "R-3.2: revision_guess anchors immediately after the work order (A12) - 'ES2131134_COC_1.pdf' yields NA, not 1"
- ext lower-cased, no dot → "R-3.2: ext is lower-cased with no leading dot"
- size/hash match file → "R-3.2: size and hash match the underlying file (hash reuses R-1.2 hash_file())"
- sheet_names populated for real xlsx → "R-3.2: sheet_names is populated for a real xlsx via readxl::excel_sheets()"
- sheet_names NULL for non-spreadsheet → "R-3.2: sheet_names is NULL for a non-spreadsheet file"
- xls unreadable → NULL sheet_names, no error → "R-3.2: an .xls without readxl-readable sheets yields NULL sheet_names and does not error"
- peek never errors on binary → "R-3.2: peek does not error on a binary (PDF-like) file and returns decoded text"

### R-3.3 adapter registry
- register/retrieve/clear round-trip → `tests/testthat/test-adapter-registry.R`
  "R-3.3: register/retrieve/clear round-trips through the registry"
- duplicate id overwrites with cli_inform → "R-3.3: registering a duplicate id overwrites with a cli_inform message"
- missing `parse` aborts naming defect → "R-3.3: an adapter missing `parse` aborts naming the defect"
- `match` wrong formals aborts naming defect → "R-3.3: an adapter whose `match` has the wrong formals aborts naming the defect"
- missing `id` aborts naming defect → "R-3.3: an adapter missing `id` aborts naming the defect"
- missing `version` aborts naming defect → "R-3.3: an adapter missing `version` aborts naming the defect"
- registry returns named list keyed by id → "R-3.3: adapter_registry() returns adapters as a named list keyed by id"

### R-3.4 ignore rules
- ext bak/tmp ignored → `tests/testthat/test-router.R`
  "R-3.4: files with ext bak/tmp are ignored"
- `.DS_Store` ignored → "R-3.4: .DS_Store is ignored"
- `[N]` duplicate-download marker NOT ignored → "R-3.4: a '[N]' duplicate-download marker filename is NOT ignored (content-hash dedup handles those)"
- zero-byte file → "empty_file" → "R-3.4: a zero-byte file is ignored with reason 'empty_file'"
- normal file not ignored (negative case) → "R-3.4: a normal nonzero-byte file with an unmatched extension is not ignored"

### R-3.5 `route_files()`
- one-exact-one-format claims exact → `tests/testthat/test-router.R`
  "R-3.5: exactly one adapter at the winning tier claims the file"
- tie at winning tier quarantines adapter_tie, both ids in payload → "R-3.5: a tie at the winning tier quarantines with reason adapter_tie and both ids in the review_queue payload"
- unclaimed → quarantined "unclaimed" → "R-3.5: a file no adapter claims quarantines with reason unclaimed"
- re-routing same path is a no-op → "R-3.5: re-routing the same path is a no-op (state unchanged, no new sighting)"
- different path, same hash → sighting, no re-claim → "R-3.5: a different path with an identical file (same hash) records a sighting and does not re-claim"
- match() throwing marks only that file failed, continues → "R-3.5: match() throwing inside an adapter marks only that file failed and continues with remaining files"

### R-3.6 `router_matrix()`
- smoke test, two dummy adapters × two paths → `tests/testthat/test-router.R`
  "R-3.6: router_matrix() returns (path, adapter, tier) for every adapter x path, with no state changes"

### R-3.7 `reconsider` (registry verdicts are re-decidable) - added 2026-07-28
Every arm below pairs the `reconsider = TRUE` assertion with a
`reconsider = FALSE` control on the same setup, so a green result cannot come
from the file being claimed for some unrelated reason.
- unclaimed → claimed once an adapter exists; control leaves it unclaimed → `tests/testthat/test-router.R`
  "R-3.7: an unclaimed file is re-decided under reconsider = TRUE once an adapter claims it, and is NOT re-decided under reconsider = FALSE"
- router-`failed` → claimed once `match()` stops throwing; control leaves it failed → "R-3.7: a router-failed file whose match() no longer throws is re-decided under reconsider = TRUE"
- adapter_tie re-decided; a still-tied re-pass opens NO second review item → "R-3.7: an adapter_tie file is re-decided under reconsider = TRUE, and a still-tied re-pass opens no SECOND review_queue item"
- `ignored`/`archived` never reconsidered, even with a greedy adapter registered → "R-3.7: `ignored` and `archived` are NEVER reconsidered - they are facts about the file, not about the registry"
- `reconsider` + `dry_run` writes nothing, and does not strand the row at `seen` → "R-3.7: reconsider = TRUE under dry_run = TRUE writes nothing - the stored verdict is unchanged"
- still-unclaimed after reconsideration ends terminal, never `seen` → "R-3.7: a file still unclaimed after reconsideration ends terminal (quarantined/unclaimed), never stranded at `seen`"
- a `claimed` file mid-pipeline is never reconsidered; the registry is emptied before the reconsidering pass so a wrongly-reset row cannot be re-claimed back into looking correct (mutation-verified) → "R-3.7: a `claimed` file mid-pipeline is NEVER reconsidered - reconsideration must not reset work already in flight"


# Adapters (plans 04-06)

## PLAN-04 esdat (`test-adapter-esdat.R`)

- **R-4.1** — R-4.1: Chemistry2e fixture (with BOM) matches exact
- **R-4.1** — R-4.1: Sample2e fixture matches exact
- **R-4.1** — R-4.1: Header.XML fixture matches exact
- **R-4.1** — R-4.1: an XTAB crosstab fixture matches no
- **R-4.1** — R-4.1: an ENMRG crosstab fixture matches no
- **R-4.1** — R-4.1: a random CSV matches no
- **R-4.1** — R-4.1: corrupted Chemistry2e fixture still matches exact (header-only fingerprint)
- **R-4.2** — R-4.2: Chemistry2e row count equals source data rows; none silently dropped
- **R-4.2** — R-4.2: multi-work-order rows are not filtered by the adapter
- **R-4.6** — R-4.6: a compound `<orig>001_<home>` SampleCode parses sample_type = NCP; plain codes stay unknown
- **R-4.2** — R-4.2: '<'-prefixed Fluoride row: value_raw '<0.1', below_detection TRUE, rl 0.1
- **R-4.2** — R-4.2: '>'-prefixed Fluoride row: value_raw '>2000', quantified FALSE, rl_high semantics
- **R-4.2** — R-4.2: text 'Observation' result keeps its value_chr, not coerced to numeric
- **R-4.2** — R-4.2: micro (mu) sign in Result_Unit survives byte-exact (UTF-8 handling)
- **R-4.2** — R-4.2: ir_validate() passes on Chemistry2e output
- **R-4.2** — R-4.2: lab_qualifier and comments pass through verbatim
- **R-4.2** — R-4.2: corrupted Chemistry2e data causes parse() to abort loudly (plan-09/10 fixture)
- **R-4.3** — R-4.3: Sample2e fixture maps 1:1 (6 rows)
- **R-4.3** — R-4.3: Sample_Type values pass through verbatim
- **R-4.3** — R-4.3: ir_validate() passes on Sample2e output
- **R-4.3** — R-4.3: lone Header-less/Chemistry-less Sample2e parses fine
- **R-4.4** — R-4.4: Header.XML yields the pinned report metadata
- **R-4.4** — R-4.4: a non-ESdat XML aborts with sampletidy_parse_error
- **R-4.5** — R-4.5: QC/NCP rows appear in n_by_sample_type, not in skipped
- **R-4.5** — R-4.5: an unparseable Analysed_Date lands in warnings; row still emitted with NA

## PLAN-05 crosstab (`test-adapter-crosstab.R`)

- **R-5.2** — R-5.2: XTAB fixture claimed only by als_xtab (format tier)
- **R-5.2** — R-5.2: ENMRG fixture claimed only by als_enmrg (format tier)
- **R-5.2** — R-5.2: ESdat Chemistry2e fixture matches no from both crosstab adapters
- **R-5.2** — R-5.2: random CSV matches no from both crosstab adapters
- **R-5.2** — R-5.2: .xlsx XTAB fixture (binary) matches format and parses equal to its .csv twin
- **R-5.1** — R-5.1: XTAB results count = sum of valid analyte x sample cells across both sections
- **R-5.1** — R-5.1: '----' and empty XTAB cells land in report$skipped with correct reasons and source_ref
- **R-5.1** — R-5.1: method-group rows produce zero result rows and set method_raw for following rows
- **R-5.1** — R-5.1: a second method-group row resets method_raw (EC gets its own method)
- **R-5.1** — R-5.1: two-section fixture - rows carry their own section's matrix and date
- **R-5.1** — R-5.1: mojibake analyte normalised - '25<0xA1>C' becomes '25°C' in analyte_raw
- **R-5.1** — R-5.1: cross-format equivalence - XTAB WATER-section values equal ESdat for XX1234567001-003
- **R-5.1** — R-5.1: d/m/y - '05/01/2026' Sample Date is kept verbatim and parses as 5 January
- **R-5.1** — R-5.1: ENMRG fixture - 2 QC sample columns emitted (not dropped), counted by sample_type
- **R-5.1** — R-5.1: ir_validate() passes on both XTAB and ENMRG outputs
- **R-5.3** — R-5.3: Workgroup cell wins over filename guess on mismatch, with a warning

## PLAN-06 acirl-field (`test-adapter-acirl.R`)

- **R-6.1** — R-6.1: main ACIRL workbook matches format
- **R-6.1** — R-6.1: a random xlsx matches no
- **R-6.1** — R-6.1: the plan-05 XTAB xlsx crosstab fixture matches no
- **R-6.2** — R-6.2: front page yields REPORT NO / SAMPLED BY (stripped) / SAMPLE DATE
- **R-6.2** — R-6.2: missing REPORT NO: continues parsing with a warning, work_order NA
- **R-6.3** — R-6.3: every fake ALS row is dropped - zero fake lab values appear in results
- **R-6.3** — R-6.3: results = features x visits x 3 field analytes minus the one empty cell
- **R-6.3** — R-6.3: EC mojibake unit variant and Temperature 'oC' both normalise correctly
- **R-6.3** — R-6.3: date fill-down - second-visit rows carry the second date (25/05/2025)
- **R-6.3** — R-6.3: Comments cell text lands on the matching ir_samples row, not as a result
- **R-6.3** — R-6.3: sampler is recorded from the front page on water-sheet samples
- **R-6.3** — R-6.3: ir_validate() passes on the main workbook's output
- **R-6.3** — R-6.3: a >20-row field block emits a warning but still parses
- **R-6.3** — R-6.3: a water sheet with no Units marker is skipped; sibling sheets still parse
- **R-6.4** — R-6.4: dust sheet is detected and skipped, no dust-derived rows

### R-6.7 site-metadata labels are not analytes - added 2026-08-01
- the three measured metadata labels yield no result and no ALS candidate, and record a skip reason → "R-6.7: a site-metadata label yields no result and no ALS candidate"
- the point-code → name mapping survives on `report$feature_aliases`, deduped → "R-6.7: the point-code -> name mapping is kept, not discarded"
- an ordinary analyte label is untouched - exact match, not prefix/substring → "R-6.7: an ordinary analyte label is untouched by the metadata rule"

### R-6.5 / R-6.5b the ALS cross-reference - added 2026-08-01, re-purposed for A80 2026-08-02
Written for A74's gate; A79 withdrew the gate but not these two fields, which are
now what A80 files an ACIRL workbook by (the cited order becomes a CHILD project;
no citation means no child).
- a two-order citation surfaces exactly, and EVERY `ALS ... Report No` row is scanned rather than only the first (the real `ALS Lithogw Report No` shadowing case) → "R-6.5: als_work_orders is exposed, including a two-order citation"
- `report$n_water_sheets` separates a dust-only workbook from one whose water sheets cite nothing, which `als_work_orders` alone cannot say → "A73/A80: a dust-only workbook imports and cites nothing", "A79/A80: a WATER workbook that cites NO ALS report imports too"

<!-- 55 adapter tests -->
# Pipeline (plans 07-10)

Events/`resolved` objects are built directly against the pinned shapes
(R-7.5, R-8.8) rather than by routing real files through adapters, except
the plan-09/10 e2e suites, which exercise the real router/adapters/pipeline
end to end by design. See `dev/plans/PLAN-CHANGE-REQUESTS.md` for all
ambiguity notes referenced below.

## Plan 07 - assembly (`R/assemble.R`)

### R-7.1 grouping
- three files sharing a work order form one event → `tests/testthat/test-assemble.R`
  "R-7.1: three files sharing a work order form one event"
- a lone Sample2e forms its own event → "R-7.1: a lone Sample2e forms its own event"
- NA-work-order file forms an orphan event without error → "R-7.1: an NA-work-order file forms an orphan event without error"

### R-7.2 source preference
- ESdat+XTAB: XTAB dropped/ignored, ESdat kept → "R-7.2: ESdat + XTAB in one event keeps ESdat, drops XTAB as superseded_by_better_source"
- event with only XTAB keeps it → "R-7.2: event with only XTAB keeps XTAB results"
- ACIRL field survives alongside ESdat (rank-exempt) → "R-7.2: ACIRL field results survive alongside ESdat lab results"
- equal-rank, different revision keeps the higher → "R-7.2: equal-rank duplicate renderings keep the higher revision"
- equal-rank, same revision keeps either + warns with both hashes → "R-7.2: equal-rank same-revision duplicates keep either and warn with both hashes"

### R-7.3 sample-metadata join
- ESdat event gains datetime/sample_type, "unknown"s gone → "R-7.3: ESdat event gains Sample2e datetime and sample_type, unknowns gone"
- fallback join on feature_raw (single-visit case; see ambiguity note on the "date part") → "R-7.3: fallback join matches on feature_raw when lab_sample_id is absent"
- engineered datetime mismatch → exactly one review flag, rest of event unblocked (assumes a `needs_review` column - ambiguity noted) → "R-7.3: an engineered sample_datetime_raw mismatch flags exactly one row for review without blocking the rest"
- **R-7.3a** results but no sample metadata AND no feature_raw → warns and names the work order; either source of a point name suppresses the warning → "R-7.3a: an event with results but no sample metadata AND no feature_raw warns and names the work order; an event with either source of a point name does not" (`test-assemble.R`). Recorded at Phase-9 sign-off: the test existed throughout, only this map entry was missing, which is why R-7.3a carried an UNKNOWN coverage status.
- **R-7.3 (sample_type conflicts)** a `sample_type` disagreement among matched rows is flagged for review under BOTH row orders → "R-7.3: a sample_type disagreement among matched sample rows is flagged for review regardless of row order" (`test-assemble.R`)

### R-7.4 multi-work-order ESdat partitioning
- event contains only its own work order's rows → "R-7.4: multi-work-order ESdat file contributes only its own work order's rows to the event"
- NCP counted in n_ncp_foreign, absent from results, not flagged for review → "R-7.4: NCP rows are counted in n_ncp_foreign, absent from results, and not flagged for review"
- non-NCP foreign row flagged for review → "R-7.4: a non-NCP foreign-work-order row is flagged for review"
- seam (real ESdat parser → assemble_events): compound-SampleCode NCP row counted/dropped/not-flagged, plain foreign row flagged → "R-7.4 (seam: real ESdat parser -> assemble_events): a compound-SampleCode NCP row is counted in n_ncp_foreign, dropped from results, and NOT flagged, while a plain foreign row IS flagged"

### R-7.5 event object shape
- shape validated on every constructive test above via the local `expect_valid_event()` helper (not a separate test - used inline)
- states tibble covers every input hash exactly once → "R-7.5: assemble_events() states tibble covers every input hash exactly once"

## Plan 08 - reconciler (`R/reconcile.R`)

### R-8.1 QC filter
- LCS/MB skipped with reasons, counts match → `tests/testthat/test-reconcile.R`
  "R-8.1: LCS/MB rows are skipped with reasons qc_LCS/qc_MB and counts match"
- "unknown" sample_type rows not skipped → "R-8.1: unknown sample_type rows are not skipped"
- NCP defensively still skipped (never reaches here per plan 07) → "R-8.1: an NCP row, if somehow present, is still skipped as QC-like (defensive)"

### R-8.2 feature resolution
- direct name resolves → "R-8.2: direct feature name resolves"
- a mask-only name does NOT resolve (the `feature_mask` join was removed by R-11.4; this line previously recorded the opposite, pre-R-11.4 behaviour) → "R-8.2: a mask-only name does not resolve (feature_mask join removed, R-11.4)"
- typo queues one grouped review item covering all rows → "R-8.2: a typo feature queues one grouped review item covering all its rows"
- ambiguity queues both candidate uuids → "R-8.2: an ambiguous feature name queues review listing both candidate uuids"
- no fuzzy matching (Levenshtein-1 miss stays unknown) → "R-8.2: no fuzzy matching - a Levenshtein-1 miss stays unknown_feature"

### R-8.3 analyte/method resolution
- org-scoped name hit resolves → "R-8.3: org-scoped analyte name hit resolves"
- same name, different org, does not cross-resolve → "R-8.3: the same name under a different org does not cross-resolve"
- CAS fallback finds analyte but still queues (known_analyte_no_method) → "R-8.3: CAS fallback finds the analyte but still queues (known_analyte_no_method)"
- full miss queues grouped by (analyte_raw, org) → "R-8.3: a full analyte miss queues grouped by (analyte_raw, org)"

### R-8.4 units & value
- mg/L→µg/L multiplies value+rl by 1000 → "R-8.4: mg/L to ug/L multiplies value and rl by 1000"
- pH dimensionless passes → "R-8.4: pH (dimensionless) passes unit resolution"
- "banana/L" queues unknown_unit → "R-8.4: an invalid unit string queues unknown_unit"
- NS lands in skipped, not review → "R-8.4: an NS row lands in skipped, not review"
- BDL row keeps quantified FALSE with converted rl → "R-8.4: a BDL row keeps quantified FALSE with a converted rl"
- (bonus) text-only results pass through, quantified NA → "R-8.4: text-only results pass through unconverted with quantified NA"

### R-8.5 sample datetime
- ESdat row yields date + datetime → "R-8.5: an ESdat-format datetime yields both sample_date and sample_datetime"
- crosstab/ACIRL row yields date only → "R-8.5: a crosstab-format (date-only) datetime yields date only"
- garbage queues parse_error → "R-8.5: a garbage datetime queues a parse_error"

### R-8.6 method preference
- duplicate-method pair keeps lower-RL row, skip references winner → "R-8.6: the duplicate-method pair keeps the lower-RL row"
- tie keeps higher value (supplements the seed DB locally with a tied lab_method row - see ambiguity note) → "R-8.6: a tied rl_low keeps the higher value"

### R-8.7 three-way outcome vs DB
- fresh row is new → "R-8.7: a fresh row is new/clean"
- identical re-ingest → already_present → "R-8.7: an identical re-ingest row is already_present"
- 1e-12 relative diff → already_present (tolerance) → "R-8.7: a value differing at 1e-12 relative is already_present (tolerance)"
- 1e-3 relative diff → conflict → "R-8.7: a value differing at 1e-3 relative is a conflict"
- recorded rev 0, incoming rev 1 → supersede → "R-8.7: conflict with recorded revision 0 and incoming revision 1 becomes a supersede row"
- no recorded revision → review (A12) → "R-8.7: conflict with no recorded revision queues for review"
- equal value, different quantified → conflict → "R-8.7: equal values but different quantified is a conflict"
- (bonus) equal text value, quantified NA on both sides → already_present, not a second commit (A14) → "A14/R-8.7: a re-ingested TEXT result matches as already_present and does NOT commit twice (quantified NA compares equal to NA)"

### R-8.8 output contract
- disjoint + complete over a mixed event (every R-8.x case at once) → "R-8.8: clean/review/skipped are disjoint and complete over a mixed event"
- reconcile is pure (DB row counts unchanged) → "R-8.7/R-8.8: reconcile_event() is pure - DB row counts are unchanged after a run"

## Plan 09 - mutation/commit/archive/snapshot/ingest

### R-9.1 mutation layer (`tests/testthat/test-mutate.R`)
- append 2 rows → 2 change_log rows, shared `at`, actor recorded → "R-9.1: db_append() of 2 rows writes 2 change_log rows with one shared `at` and the actor recorded"
- update 2 fields → 2 log rows old/new → "R-9.1: db_update() changing 2 fields writes 2 change_log rows with correct old/new"
- failing update rolls back the log (atomicity) → "R-9.1: a failing update (bad column) rolls back the change_log too (atomicity)"
- db_delete() removes row + logs delete (bonus, not explicitly required) → "R-9.1: db_delete() removes the row and writes a change_log delete entry"
- lint guard (fails gracefully on empty R/) → "R-9.1: direct-write bypass is lint-guarded - no forbidden raw SQL writes in R/ (comment/string-aware, continuation-line-aware; Phase-7b round-2 item 9)"
- add_feature()/add_analyte()/add_project()/correct_value() row+log each (con-less signature assumption - see ambiguity note) → "R-9.1: add_feature() inserts a row and a change_log entry", "R-9.1: add_analyte() inserts a row and a change_log entry", "R-9.1: add_project() inserts a row and a change_log entry", "R-9.1: correct_value() updates the analysis and logs the old value"
- review_queue() filters by status → "R-9.1: review_queue() filters by status"
- review_queue() zero-row stable columns → "R-9.1: review_queue() has stable columns on a zero-row result"

### R-9.2 `commit_event()` (`tests/testthat/test-commit.R`)
- row counts match clean → "R-9.2: committing new clean rows creates exactly matching sample/analysis counts"
- second call on already-terminal files aborts → "R-9.2: a second commit_event() call on already-terminal files aborts"
- mid-commit failure leaves zero new rows (atomicity, mocked UUID collision) → "R-9.2: mid-commit failure leaves zero new rows anywhere (atomicity)"
- supersede updates in place, no duplicate row → "R-9.2: supersede updates the analysis in place with no duplicate row"
- provenance chain (change_log source_hash ↔ asset.hash) → "R-9.2: provenance chain - every committed analysis has a change_log insert row whose source_hash matches an archived asset"
- superseded-rendering files also archived (asset rows + copies) → "R-9.2: superseded-rendering files (state ignored) also get asset rows and archive copies"
- already_present → provenance-only change_log row (assumed `existing_uuid` skipped column - see ambiguity note) → "R-9.2: already_present rows get no new analysis but a provenance change_log row"

### R-9.3 archive (`tests/testthat/test-archive.R`)
- copy exists, byte-identical → "R-9.3: the archive copy exists and is byte-identical to the source"
- asset row fields correct → "R-9.3: the asset row fields are correct"
- same-hash second call: no second copy/row → "R-9.3: a second call with the same hash creates no second copy or row"
- source untouched → "R-9.3: the source file is untouched by archiving"
- asset visible to ingest_file.uuid_asset → "R-9.3: the archived asset is visible for ingest_file.uuid_asset to reference"

### R-9.4 snapshot (`tests/testthat/test-snapshot.R`)
- read-only, count matches live, no .tmp left → "R-9.4: a snapshot opens read-only with a matching analysis count, and leaves no .tmp behind"
- prune keeps ≤60-day dailies + each month's final → "R-9.4: prune_snapshots() keeps <=60-day dailies plus each month's final snapshot"
- same-day re-snapshot overwrites → "R-9.4: a same-day re-snapshot overwrites (single file per day)"

### R-9.5 `ingest_dir()` (`tests/testthat/test-ingest.R`)
- subdirectory untouched, cruft ignored → "R-9.5: subdirectory content is untouched and cruft files are ignored"
- adapter families commit, report reconciles with DB deltas → "R-9.5: every landed adapter family commits and report numbers reconcile with DB deltas"
- dry_run: report, zero writes, no snapshot → "R-9.5: dry_run = TRUE produces a report with zero core-table DB writes and no snapshot"
- adapter crash on one file → failed, run completes → "R-9.5: an adapter crash on one file is recorded as failed and the run completes"
- second run over same dir → zero new rows/review items → "R-9.5: a second run over the same directory is a no-op (idempotent at the orchestration level)"

### R-9.6 remove switch (`tests/testthat/test-ingest.R`)
- default FALSE: sources present → "R-9.6: default (remove_ingested = FALSE) leaves all sources present"
- TRUE: verified sources removed, quarantined/failed/cruft kept → "R-9.6: remove_ingested = TRUE removes verified sources but keeps quarantined/failed/cruft"
- TRUE + injected snapshot failure: nothing removed (mocked `snapshot_db()`) → "R-9.6: remove_ingested = TRUE with an injected snapshot failure removes nothing"
- TRUE + missing archive copy: source kept → "R-9.6: a source with a missing archive copy is kept, never deleted without a verified copy"
- subsequent run over emptied dir: no-op → "R-9.6: a subsequent run over the emptied directory is a clean no-op"

### R-9.7 `ingest_inbox()` (`tests/testthat/test-ingest.R`) - added 2026-07-28
- two folders, two batches, no cross-contamination of either report → "R-9.7: two email folders each ingest as their own batch, and neither folder's files appear in the other's report"
- one folder throws, the others still commit (asserts the good folder LANDED, not merely that nothing propagated) → "R-9.7: a folder whose ingest throws is reported as failed and the OTHER folders still commit"
- loose root-level files neither routed nor deleted → "R-9.7: loose files sitting directly in the root are neither routed nor deleted"
- dry_run propagates to every folder, zero writes → "R-9.7: dry_run propagates to every folder - zero DB writes across all of them"
- empty root → empty roll-up, no error → "R-9.7: an empty root returns an empty roll-up without error"

### R-9.8 folder-sibling work-order inference (`tests/testthat/test-ingest.R`) - added 2026-07-28
- token-less deliverable in a single-WO folder is attached to that WO → "R-9.8: a deliverable with NO work-order token, in a folder belonging to exactly one work order, is retained and attached to it"
- same file in a TWO-WO folder is not attached, stays quarantined, warns → "R-9.8: the same token-less deliverable in a folder resolving to TWO work orders is NOT attached, stays quarantined, and warns"
- a filename that DOES carry a WO always wins over the folder → "R-9.8: inference never overrides a filename that DOES carry a work order"
- the residual-silence test, RE-POINTED at the ambiguous folder (its single-WO case became R-9.12's retain case) → "Phase-7b round-2 item 7 (RE-POINTED R-9.12): an ACIRL deliverable in an AMBIGUOUS folder stays quarantined AND is named in a cli_warn - the residual exposure is not silent"

### R-9.12 ACIRL reports retained and attached to the ALS work order (`tests/testthat/test-ingest.R`) - added 2026-07-28
- real-shaped ACIRL report in a single-WO folder is retained, attached, typed "Chemical analysis" → "R-9.12: a real-shaped ACIRL report in a folder belonging to one ALS work order is retained and attached to it"
- ACIRL report with no resolvable WO stays quarantined, warns, mints no project → "R-9.12: an ACIRL report whose folder resolves to NO committed work order stays quarantined and warns - inference never invents a target"
- cruft still neither retained nor warned about (round-3 commit-5 regression guard) → "R-9.12: ordinary non-deliverable cruft is still NOT retained and still draws no warning - widening the gate must not re-open the round-3 noise"

### R-7.5b per-file provenance carry-through (`tests/testthat/test-assemble.R`) - added 2026-08-02
- an ACIRL file's report number, ALS citation and alias mapping all survive assembly -> "R-7.5b: an ACIRL file's report number, ALS citation and alias mapping survive assembly"
- every member hash gets an entry, `character(0)` not NULL, whatever its adapter exposes -> "R-7.5b: every member hash gets a source entry, including files whose adapter exposes none of it"
- two files in ONE event keep their OWN report numbers and citations - what A80's duplicate detection rests on -> "R-7.5b: two files in ONE event keep their OWN report numbers - A80 cannot detect a duplicate otherwise"
- driven once through the REAL adapter, so a `report$header$report_no` path mismatch cannot hide behind hand-built input -> "R-7.5b: the real ACIRL adapter's report reaches assembly intact - not just a hand-built one"

### R-9.13 the ALS-source gate: WITHDRAWN by A79 (`tests/testthat/test-ingest.R`) - added 2026-08-01, retargeted 2026-08-02
A74 quarantined an ACIRL water sheet whose cited ALS report we did not hold. A79
withdrew that - ACIRL data is NATA-certified and imports on its own; an ALS row
supersedes an ACIRL transcription at reconcile instead. Every test below was
**retargeted, not deleted**: each owned a fixture reaching a distinct corner of
the citation logic, and those corners are now A80's filing inputs
(`als_work_orders` -> the CHILD project, `n_water_sheets` -> dust has no child).
The suite's job is now the reverse of A74's: prove these files IMPORT, so that a
gate growing back anywhere fails loudly.
- cited work order held -> the workbook imports -> "A79: an ACIRL workbook whose cited ALS work order IS held imports"
- **the headline**: the same workbook imports IDENTICALLY (events, rows, review items, `analysis`, `sample`) and QUIETLY when the order is not held -> "A79: the SAME workbook imports IDENTICALLY when the ALS report is NOT held"
- a workbook citing TWO orders imports with neither held; both citations still parse out for A80 -> "A79/A80: a workbook citing TWO ALS orders imports with NEITHER held, and both citations survive"
- dust-only workbook imports and cites nothing (`n_water_sheets == 0`, so A80 gives it no child) -> "A73/A80: a dust-only workbook imports and cites nothing"
- a WATER workbook citing nothing imports too (the `2400-7483-01` bare-`ES` case) -> "A79/A80: a WATER workbook that cites NO ALS report imports too"
- ACIRL + its ALS sibling in one batch both import, in either file order -> "A79: an ACIRL workbook and its ALS sibling in one batch both import, in either order"
- an ACIRL workbook with no held source does not hold up the rest of the batch -> "A79: an ACIRL workbook with no held ALS source does not hold up the rest of the batch"
- an ESdat report carries no `als_work_orders`, so ACIRL filing must not claim it -> "A80: an ESdat report carries no als_work_orders, so ACIRL filing must not claim it"
- `dry_run` previews the import and writes nothing -> "A79: a dry run of an ACIRL workbook with no held source writes nothing"
- anti-regression sweep: every ACIRL shape A74 governed, one DB each, none quarantined, no `als_gated` field on the report -> "A79: nothing is withheld for a missing ALS source, and the report says nothing about gating"
- re-running does not double-import -> "A79: re-running does not import the same workbook twice"
- an ACIRL workbook has no home work order (R-9.12's filename trap), which is *why* A80 files by report number -> "A80: an ACIRL workbook has no home work order - it must be filed by report number"
- the inversion of "gating takes no snapshot": an imported workbook IS snapshotted and its source removed -> "A79: an imported ACIRL workbook IS snapshotted and its source removed"

### R-8.9 ACIRL transcription supersession (`tests/testthat/test-reconcile.R`) - added 2026-08-02
A79's split: a `field` (or `EN67`) lab_method is a real field measurement, a
NULL-method ACIRL lab_method is a hand transcription of an ALS number, and a
real ACIRL method code is ACIRL's own dust lab work. Matched on the resolved
ANALYTE uuid, never the raw label. All 14 mutations killed
(`scratchpad/a79_supersede_mutations.R`); two of them found real defects
(A79's "every other ACIRL row" wording, and EN67).
- incoming transcription with a committed ALS twin is dropped, both values on the skip row -> "R-8.9: an incoming ACIRL transcription whose ALS twin is already committed is dropped, carrying both values"
- incoming ALS row marks the committed transcription, reason carries the transcribed value -> "R-8.9: an incoming ALS row marks the committed ACIRL transcription for deletion, with both values in the reason"
- commit performs the delete and `change_log` records the value -> "R-8.9: commit_event() performs the deletion and change_log records the transcribed value"
- a committed ACIRL FIELD reading is never superseded -> "R-8.9: an ACIRL FIELD reading is never superseded - it is a different measurement, not a copy"
- an incoming ACIRL FIELD row is kept even when its ALS twin exists -> "R-8.9: an incoming ACIRL FIELD row is kept even when its ALS twin is already committed"
- ACIRL's own DUST lab work is never superseded, committed side -> "R-8.9: ACIRL's own DUST lab work is never superseded - it is not a transcription"
- ACIRL's own DUST lab work is never superseded, incoming side -> "R-8.9: an incoming ACIRL DUST row is kept even when an ALS twin is already committed"
- an ALS EN67 row does not supersede - it IS the field reading -> "R-8.9: an ALS `EN67 - Client Supplied Data` row does NOT supersede - it IS the field reading"
- a committed EN67 row is not an ALS twin either -> "R-8.9: a committed EN67 row is not an ALS twin either - an incoming transcription survives it"
- only ALS supersedes; a legacy lab row does not -> "R-8.9: only an ALS row supersedes - a legacy lab row leaves the transcription alone"
- a dangling ACIRL method has no analyte, so nothing twins -> "R-8.9: a DANGLING ACIRL method has no analyte, so nothing twins and nothing is deleted"
- the twin is found on the ANALYTE across two different labels -> "R-8.9: the twin is found on the ANALYTE, across two different labels"
- a different analyte at the same feature and date is not a twin -> "R-8.9: a different analyte at the same feature and date is not a twin"
- a date-only ACIRL sample twins with a TIMED ALS sample on the same day -> "R-8.9: a date-only ACIRL sample twins with a TIMED ALS sample on the same day"
- two provably distinct times on one day are not twins -> "R-8.9: two provably distinct sampling times on one day are NOT twins"
- a different date is not a twin -> "R-8.9: a different date is not a twin"
- two rows naming one transcription yield ONE delete (driven directly - the pipeline cannot reach it, and routing it through produced a vacuous test) -> "R-8.9: two rows naming ONE committed transcription yield ONE delete, not two"
- two incoming ALS rows delete it once, end to end -> "R-8.9: two incoming ALS rows naming ONE transcription delete it once, not twice"
- a uuid already deleted by another event is skipped, not an abort -> "R-8.9: a supersede uuid already deleted by another event is skipped, not an abort"
- an already_present row deletes nothing -> "R-8.9: an already_present ALS row deletes nothing - the delete needs a real commit"

### R-9.14 the A80 project hierarchy (`tests/testthat/test-commit.R`) - added 2026-08-02
`campaign -> ACIRL report -> ALS work order`, built at commit time from
`event$report$sources`. Every case below was measured off the real corpus and the
live registry first (`scratchpad/a80_cardinality_probe.R`, `a80_tree_probe.R`) -
A80 taken literally would have overwritten the campaign on 116 of 129 cited
orders. All 12 mutations killed (`scratchpad/a80_mutations.R`).
- the report is INSERTED between campaign and work order; `uuid_root` is the campaign for both; samples attach to the CHILD -> "A80: an ACIRL event with a cited ALS order builds campaign -> report -> work order, and its samples attach to the CHILD"
- the displaced campaign survives in `change_log` -> "A80: the displaced campaign survives in change_log, so the move is recoverable"
- a dust-only workbook files under the report itself, its own root, and mints no anonymous orphan row -> "A80: a dust-only workbook (no ALS citation) files under the report project itself, as its own root"
- a cited order we have never seen is created as a child -> "A80: a cited ALS order we have never seen is created as a child of the report"
- a colliding report number MERGES, its parent untouched, and raises no duplicate flag; its non-work-order children are not read as ALS orders -> "A80: a report number colliding with an existing project MERGES into it and never touches its parent"
- a number reused for a DIFFERENT sampling event flags and still imports, leaving one parent with two children -> "A80: a report number reused for a DIFFERENT sampling event raises duplicate_report_number - and still imports"
- a re-save flags nothing and re-points nothing the second time (no `change_log` churn per retry) -> "A80: a re-saved report (same number, same cited order) does NOT raise duplicate_report_number"
- an order already claimed by another ACIRL report keeps its parent and flags; its samples still attach to it -> "A80: an ALS order already claimed by ANOTHER ACIRL report keeps its parent and raises project_parent_conflict"
- two citations in one file make two children, samples on the PARENT, no duplicate flag -> "A80: a workbook citing TWO orders makes both children, attaches its samples to the PARENT, and raises no duplicate flag"
- two campaigns, no consensus: both campaigns intact, both flagged -> "A80: two cited orders under DIFFERENT campaigns leave both campaigns intact and flag both"
- a non-ACIRL event is untouched - same project, no review rows -> "A80: an event with no ACIRL report number is untouched - same project, no review rows"
- the archived workbook lands on its report project, not the orphan row -> "A80: the archived ACIRL workbook lands on its report project, not the anonymous orphan row"

### R-9.9 empty-folder cleanup (`tests/testthat/test-ingest.R`) - added 2026-07-28
- emptied folder deleted, and a `.DS_Store` does not keep it alive → "R-9.9: a folder emptied by a clean run is deleted, and a .DS_Store does not keep it alive"
- folder holding a kept-back (quarantined) file survives → "R-9.9: a folder still holding a quarantined file survives"
- nothing deleted when `remove_ingested` is FALSE → "R-9.9: nothing is deleted when remove_ingested is FALSE"

### R-9.10 retention alone earns a snapshot (`tests/testthat/test-ingest.R`) - added 2026-07-28
- retain-only run snapshots and removes its source (asserted inside the R-15.36a cross-run test, which is the only place a retain-only run occurs naturally) → "R-15.36a: a COA arriving in a LATER run, in its own directory, attaches to the work order committed by an earlier run"
- a run that neither commits nor retains produces NO snapshot and removes nothing → "R-9.10: a run that neither commits nor retains produces NO snapshot and removes nothing"

### R-9.11 `quarantine_report()` (`tests/testthat/test-ingest.R`) - added 2026-07-28
- exactly the non-archived terminal rows, derived work_order_guess, no writes → "R-9.11: quarantine_report() returns exactly the non-archived terminal rows, with a derived work_order_guess and no writes"
- clean DB → zero-ROW tibble with every column, not NULL → "R-9.11: quarantine_report() on a clean DB returns a zero-ROW tibble with the full column set, not NULL"
- works when the quarantined files are gone from disk → "R-9.11: quarantine_report() works when the quarantined files no longer exist on disk"

### R-15.36a / R-15.36b retention rulings (`tests/testthat/test-ingest.R`) - added 2026-07-28
- cross-run COA attaches to the earlier run's WO, adds no project row → "R-15.36a: a COA arriving in a LATER run, in its own directory, attaches to the work order committed by an earlier run"
- unknown WO creates no project row and stays quarantined (asserts the project COUNT, not just the asset's absence) → "R-15.36a: a COA for a work order that has NEVER committed creates no project row and stays quarantined"
- all five deliverable kinds land their ruled `asset.type`, asserted per token → "R-15.36b: each retained deliverable kind lands its ruled asset.type (COA/QC/QCI/COC/XTAB asserted per-token)"

### Test-suite hygiene lint (`tests/testthat/test-mock-scope-lint.R`) - added 2026-07-28, rewritten same day
Not a criterion of any plan - a guard on the SUITE. An `on.exit()` without
`add = TRUE` REPLACES every handler already on the frame. Two different things
register handlers there and are silently discarded: `local_mocked_bindings()`'s
restore handler (leaking the mock into every later test in the file), and the
`withr` cleanups a setup helper binds to the CALLING test's frame via
`.local_envir` (leaking global options and temp directories).
- rule 1, mocks, scanning test-*.R AND helper-*.R → "no on.exit() discards a local_mocked_bindings() restore handler registered on the same frame"
- rule 2, frame-borrowing setup helpers, ratcheted against `.ST_RULE2_BASELINE` → "no on.exit() discards the withr cleanups a setup helper bound to the calling test's frame"
- calibration: the real bareness detector, over a battery incl. `add = FALSE`, positional `add`, `rm(add)`, and an inner call's `add = TRUE` → "calibration: the bareness detector reads on.exit()'s add argument semantically, not textually"
- calibration: both rules fire on known-bad snippets, incl. a helper function with NO enclosing test_that, plus the nested-function negative control → "calibration: both rules fire on a known-bad snippet, including inside a helper function with no enclosing test_that()"

The first version of this lint shipped two holes of its own, both fixed here
and both worth recording as the generic ways a source lint rots. It decided
bareness with `!grepl("\\badd\\b", ...)`, so `on.exit(..., add = FALSE)` - the
same thing as a bare call - read as safe; and its "calibration control" never
invoked the bareness check at all, which is exactly how that hole survived
being written. Rule 2 exists because auditing the lint, not running it, is what
found the second leak class: eleven blocks in `test-ingest.R` wiped
`ingest_test_setup()`'s cleanups (measured: 3 options left set globally and 47
temp dirs leaked per file run; 0 and 0 after). A further 400 instances across 14
other files were recorded in `.ST_RULE2_BASELINE` as a ratchet rather than swept
on the spot, because converting them changes real behaviour - the leaked options
and temp dirs start actually being cleaned up, and any test that had come to
depend on the leak would begin failing. **Swept 2026-07-29**, smallest file
first, each tier run before the next; no fallout materialised. The baseline is
now `integer(0)`: every file must have zero, and any entry added back is a
regression being tolerated.

Chasing the three temp directories that STILL survived a full run after the
sweep found a hole in the rule itself: it only knew the indirect carrier (a
setup helper binding via `.local_envir`) and never the direct one (a
`withr::local_*()` call written straight into the test body, binding to that
very frame). `test-pending.R` had exactly that shape and nothing fired. Rule 2
now collects both kinds of carrier, with a calibration pinning that a bare
`local_*()` counts for its own frame while one passing `.local_envir` does not.
The other two were a different class entirely - a bare `tempfile()` in
`test-db-connect.R`'s subprocess helper that registered no cleanup at all.
Suite-wide after both fixes: **no `sampletidy.*` option leaks out of a full run,
and a full run leaves zero temp directories behind** (measured 0 before / 0
after, against 47 from `test-ingest.R` alone before any of this).

### Traceability lint (`tests/testthat/test-coverage-map-lint.R`) - added 2026-07-28
Not a criterion of any plan - a guard on THIS document. Every test name quoted
on a mapping line must resolve to a real `test_that()` description, or the map
claims coverage that does not exist and a name-anchored criterion sweep skips
the entry in silence. Three stale quotes were found the expensive way (by a
reviewer reading the map), two of which recorded behaviour the codebase had
since reversed: `remove_ingested`'s default (FALSE → TRUE, 2026-07-23) and
R-8.2's mask alias (R-11.4 removed the `feature_mask` join, so the real test
now pins the opposite). Non-test literals live in an explicit
`.ST_COVMAP_LITERALS` allowlist, which is itself checked for rot.
- every quoted name resolves; the allowlist holds nothing stale → "every test name quoted in COVERAGE-MAP.md resolves to a real test_that() description"
- calibration: a fabricated map entry naming a non-existent test IS reported, and a quoted phrase on a non-mapping line is not → "calibration: the traceability check reports a quoted name that does not exist"

### Audit-round regression tests (`tests/testthat/test-ingest.R`) - added 2026-07-28
From the four-way Fable audit of this session's changes. Each fails against the
code as it was written, verified by mutation, not by assertion.
- an ACIRL selector matching both dialects and no non-ACIRL scan → "AUDIT-1: the ACIRL selector matches the unhyphenated dialect and does NOT match an unrelated year range or a scanner timestamp"
- a zero-byte file keeps its folder alive (mutation-verified: without the guard the folder is unlinked AND the in-flight attachment destroyed) → "AUDIT-2: a folder holding a ZERO-BYTE file is never deleted - an attachment mid-delivery must not be unlinked with the folder"
- folder ambiguity is counted BEFORE the project lookup (mutation-verified: filter-then-count files the anonymous COA under the wrong work order) → "AUDIT-3: a folder naming TWO work orders declines inference even when only ONE of them has a project row"
- an interrupted run's sources are removed on the NEXT run, and the trigger is self-limiting → "AUDIT-4: a run interrupted before its snapshot still removes its sources on the NEXT run, instead of stalling forever"
- a cruft-only folder is removed even though this run removed nothing from it → "AUDIT-5: a folder holding only ignorable cruft is removed even though this run removed nothing from it"
- a folder holding a SUBDIRECTORY survives with its unrouted contents intact (R-9.5); written against the behaviour, not the `dir.exists` line, which measurement showed is redundant defence-in-depth → "AUDIT-6: a folder containing a SUBDIRECTORY is never removed, even when everything else in it is spent"
- R-9.10's third criterion, previously declared and untested: R-9.6's snapshot gate holds on the RETAIN-ONLY path, with a reachability arm proving an unmocked re-run does remove → "AUDIT-7: R-9.6's snapshot gate still holds on the RETAIN-ONLY path - an injected snapshot failure removes nothing"

## Plan 10 - e2e / router matrix / corpus gates

### R-10.1 router cross-match matrix (`tests/testthat/test-e2e-pipeline.R`)
- every fixture claimed once at winning tier; cruft/random claim none (informative failure message via `testthat::expect()`) → "R-10.1: router_matrix() claims every fixture at exactly one winning tier; cruft/random files claim none"

### R-10.2 full-pipeline e2e (`tests/testthat/test-e2e-pipeline.R`)
- pinned <0.1 fluoride row matches pre-existing analysis → "R-10.2: the pinned <0.1 mg/L fluoride row matches the pre-existing analysis (idempotency backbone)"
- µS/cm→mS/cm EC row lands converted → "R-10.2: the uS/cm to mS/cm EC row lands converted on a new analysis"
- no orphan uuids (substitutes for v_measurement - see ambiguity note) → "R-10.2: every new analysis joins cleanly to a sample and a feature (no orphan uuids)"
- provenance chain intact, archive copy byte-identical → "R-10.2: the provenance chain is intact - source_hash matches an archived asset byte-identical to the input file"
- ACIRL field rows date-only, sampler on sample.person → "R-10.2: ACIRL field rows are date-only with the sampler recorded on sample.person"
- QC skip counts / review_queue engineered unknowns → "R-10.2: QC rows are skipped with the fixture's known counts and review_queue holds the engineered unknowns"

### R-10.3 idempotency (`tests/testthat/test-e2e-pipeline.R`)
- repeat run, touched-mtime run: zero deltas; renamed-copy run: +1 sighting only (dedup-by-hash+path resolution - see ambiguity note) → "R-10.3: repeat ingests over an unchanged (or touched) directory produce zero deltas; a byte-identical rename adds exactly one sighting"

### R-10.4 revision supersede e2e (`tests/testthat/test-e2e-pipeline.R`)
- _1_ XTAB after _0_ updates value in place, no duplicate, v0 state unchanged (requires a plan-10-only supplementary fixture - see ambiguity note) → "R-10.4: ingesting a _1_ revision XTAB after the _0_ updates the changed value in place"

### R-10.5 real-corpus gates (`tests/testthat/test-e2e-corpus.R`) - all corpus-gated (skipped without `SAMPLETIDY_CORPUS`)
- route sweep, no ties → "R-10.5: route sweep - router_matrix() over the corpus has no adapter tie"
- parse sweep, ir_validate() passes, skip reasons tabulated → "R-10.5: parse sweep - every corpus file claimed at exact/format parses without error and validates"
- cross-format equivalence, diff on mismatch → "R-10.5: cross-format equivalence holds for Normal rows shared between ESdat and crosstab work orders"
- dry-run vs real DB copy, already_present, zero writes (additionally gated on `SAMPLETIDY_CORPUS_DB` - see ambiguity note) → "R-10.5: a dry run against a copy of the real DB completes, finds already_present rows, and writes nothing"

### R-10.6 package gates (`tests/testthat/test-e2e-pipeline.R`)
- NAMESPACE exports == CONTRACT public API → "R-10.6: NAMESPACE exports equal the CONTRACT-pinned public API exactly"
- DESCRIPTION Imports == CONTRACT-pinned set → "R-10.6: DESCRIPTION Imports equal the CONTRACT-pinned set"
- devtools::check() clean: **not encoded as a testthat assertion** - CI/manual gate only (rcmdcheck isn't a pinned dependency; see ambiguity note) - not tested here
