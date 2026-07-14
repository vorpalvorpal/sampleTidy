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
- `remove_ingested` default FALSE (A13) → "R-1.1: remove_ingested default is FALSE (A13)"
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

### R-7.4 multi-work-order ESdat partitioning
- event contains only its own work order's rows → "R-7.4: multi-work-order ESdat file contributes only its own work order's rows to the event"
- NCP counted in n_ncp_foreign, absent from results, not flagged for review → "R-7.4: NCP rows are counted in n_ncp_foreign, absent from results, and not flagged for review"
- non-NCP foreign row flagged for review → "R-7.4: a non-NCP foreign-work-order row is flagged for review"

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
- mask alias resolves → "R-8.2: mask alias resolves to the masked feature's uuid"
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
- (bonus) text-only results pass through, quantified TRUE → "R-8.4: text-only results pass through unconverted with quantified TRUE"

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

### R-8.8 output contract
- disjoint + complete over a mixed event (every R-8.x case at once) → "R-8.8: clean/review/skipped are disjoint and complete over a mixed event"
- reconcile is pure (DB row counts unchanged) → "R-8.7/R-8.8: reconcile_event() is pure - DB row counts are unchanged after a run"

## Plan 09 - mutation/commit/archive/snapshot/ingest

### R-9.1 mutation layer (`tests/testthat/test-mutate.R`)
- append 2 rows → 2 change_log rows, shared `at`, actor recorded → "R-9.1: db_append() of 2 rows writes 2 change_log rows with one shared `at` and the actor recorded"
- update 2 fields → 2 log rows old/new → "R-9.1: db_update() changing 2 fields writes 2 change_log rows with correct old/new"
- failing update rolls back the log (atomicity) → "R-9.1: a failing update (bad column) rolls back the change_log too (atomicity)"
- db_delete() removes row + logs delete (bonus, not explicitly required) → "R-9.1: db_delete() removes the row and writes a change_log delete entry"
- lint guard (fails gracefully on empty R/) → "R-9.1: direct-write bypass is lint-guarded - no forbidden raw SQL writes in R/"
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
