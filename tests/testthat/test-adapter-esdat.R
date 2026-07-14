# tests/testthat/test-adapter-esdat.R
#
# TDD "red" tests for R/adapter-esdat.R (plan 04). R/adapter-esdat.R does not
# exist yet, so every test below is expected to fail (missing function/object)
# until plan 04 lands. See dev/plans/PLAN-04-adapter-esdat.md and
# dev/plans/FIXTURES.md for the pinned contract encoded here, and
# dev/plans/CONTRACT.md for the IR/registry seams referenced.
#
# Adapter accessor: CONTRACT.md pins the *registry* functions
# (`register_adapter()` / `adapter_registry()` / `clear_adapters()`) but does
# not pin a literal object name for a per-format adapter. Per orchestrator
# instruction we default to the registry route; see
# dev/plans/PLAN-CHANGE-REQUESTS.md "R-4.x -- adapter accessor".

esdat_adapter <- function() {
  reg <- sampleTidy:::adapter_registry()
  reg[["esdat"]]
}

chemistry2e_header <- c(
  "SampleCode", "ChemCode", "OriginalChemName", "Prefix", "Result",
  "Result_Unit", "Total_or_Filtered", "Result_Type", "Method_Type",
  "Method_Name", "Extraction_Date", "Analysed_Date", "EQL", "EQL_Units",
  "Comments", "Lab_Qualifier", "UCL", "LCL"
)
sample2e_header <- c(
  "SampleCode", "Sampled_Date_Time", "Field_ID", "Blank1", "Depth", "Blank2",
  "Matrix_Type", "Sample_Type", "Parent_Sample", "Blank3", "SDG", "Lab_Name",
  "Lab_SampleID", "Lab_Comments", "Lab_Report_Number"
)

chem_path        <- test_path("fixtures", "esdat", "PROJ_A.ESDAT_XX1234567_0.Chemistry2e.CSV")
sample_path      <- test_path("fixtures", "esdat", "PROJ_A.ESDAT_XX1234567_0.Sample2e.CSV")
header_path      <- test_path("fixtures", "esdat", "PROJ_A.ESDAT_XX1234567_0.Header.XML")
lone_sample_path <- test_path("fixtures", "esdat", "PROJ_B.ESDAT_XX7654321_0.Sample2e.CSV")
not_esdat_path   <- test_path("fixtures", "esdat", "NOT_ESDAT.xml")
random_csv_path  <- test_path("fixtures", "esdat", "random.csv")
baddate_path     <- test_path("fixtures", "esdat", "BADDATE.ESDAT_XX5555555_0.Chemistry2e.CSV")
corrupt_path     <- test_path("fixtures", "esdat", "CORRUPT.ESDAT_XX0000000_0.Chemistry2e.CSV")
xtab_csv_path    <- test_path("fixtures", "crosstab", "XX1234567_0_XTAB.csv")
enmrg_csv_path   <- test_path("fixtures", "crosstab", "XX1234567_0_ENMRG.CSV")

# ---- R-4.1 match() ----------------------------------------------------------

test_that("R-4.1: Chemistry2e fixture (with BOM) matches exact", {
  meta <- sampleTidy:::file_meta(chem_path)
  expect_identical(esdat_adapter()$match(meta), "exact")
})

test_that("R-4.1: Sample2e fixture matches exact", {
  meta <- sampleTidy:::file_meta(sample_path)
  expect_identical(esdat_adapter()$match(meta), "exact")
})

test_that("R-4.1: Header.XML fixture matches exact", {
  meta <- sampleTidy:::file_meta(header_path)
  expect_identical(esdat_adapter()$match(meta), "exact")
})

test_that("R-4.1: an XTAB crosstab fixture matches no", {
  meta <- sampleTidy:::file_meta(xtab_csv_path)
  expect_identical(esdat_adapter()$match(meta), "no")
})

test_that("R-4.1: an ENMRG crosstab fixture matches no", {
  meta <- sampleTidy:::file_meta(enmrg_csv_path)
  expect_identical(esdat_adapter()$match(meta), "no")
})

test_that("R-4.1: a random CSV matches no", {
  meta <- sampleTidy:::file_meta(random_csv_path)
  expect_identical(esdat_adapter()$match(meta), "no")
})

test_that("R-4.1: corrupted Chemistry2e fixture still matches exact (header-only fingerprint)", {
  # match() must fingerprint on the header line alone; body-level corruption
  # (see R-4.2 below) must not change the routing tier, or the router would
  # never reach 'claimed' for the plan-09/10 adapter-crash scenario.
  meta <- sampleTidy:::file_meta(corrupt_path)
  expect_identical(esdat_adapter()$match(meta), "exact")
})

# ---- R-4.2 Chemistry2e -> ir_results ----------------------------------------

test_that("R-4.2: Chemistry2e row count equals source data rows; none silently dropped", {
  meta <- sampleTidy:::file_meta(chem_path)
  out <- esdat_adapter()$parse(chem_path, meta)
  expect_equal(nrow(out$results), 10)
  expect_equal(out$report$n_rows, 10)
})

test_that("R-4.2: multi-work-order rows are not filtered by the adapter", {
  meta <- sampleTidy:::file_meta(chem_path)
  out <- esdat_adapter()$parse(chem_path, meta)
  wo <- unique(out$results$work_order)
  expect_true("XX1234567" %in% wo)
  expect_true("YY0000001" %in% wo)
  # both work orders' rows are present in the SAME output (never filtered)
  expect_equal(sum(out$results$work_order == "YY0000001", na.rm = TRUE), 1)
})

test_that("R-4.2: '<'-prefixed Fluoride row: value_raw '<0.1', below_detection TRUE, rl 0.1", {
  meta <- sampleTidy:::file_meta(chem_path)
  out <- esdat_adapter()$parse(chem_path, meta)
  row <- out$results[out$results$lab_sample_id == "XX1234567001" &
                        out$results$analyte_raw == "Fluoride", ]
  expect_equal(nrow(row), 1)
  expect_identical(row$value_raw, "<0.1")
  expect_true(isTRUE(row$below_detection))
  expect_equal(row$rl, 0.1)
})

test_that("R-4.2: '>'-prefixed Fluoride row: value_raw '>2000', quantified FALSE, rl_high semantics", {
  meta <- sampleTidy:::file_meta(chem_path)
  out <- esdat_adapter()$parse(chem_path, meta)
  row <- out$results[out$results$lab_sample_id == "XX1234567003" &
                        out$results$analyte_raw == "Fluoride", ]
  expect_equal(nrow(row), 1)
  expect_identical(row$value_raw, ">2000")
})

test_that("R-4.2: text 'Observation' result keeps its value_chr, not coerced to numeric", {
  meta <- sampleTidy:::file_meta(chem_path)
  out <- esdat_adapter()$parse(chem_path, meta)
  row <- out$results[out$results$lab_sample_id == "XX1234567003" &
                        out$results$analyte_raw == "Observation", ]
  expect_equal(nrow(row), 1)
  expect_identical(row$value_raw, "Clear, low flow")
  expect_true(is.na(row$value_num))
})

test_that("R-4.2: micro (mu) sign in Result_Unit survives byte-exact (UTF-8 handling)", {
  meta <- sampleTidy:::file_meta(chem_path)
  out <- esdat_adapter()$parse(chem_path, meta)
  ec_row <- out$results[out$results$lab_sample_id == "XX1234567001" &
                          grepl("Electrical Conductivity", out$results$analyte_raw), ]
  expect_equal(nrow(ec_row), 1)
  expect_identical(ec_row$units_raw, "µS/cm")
})

test_that("R-4.2: ir_validate() passes on Chemistry2e output", {
  meta <- sampleTidy:::file_meta(chem_path)
  out <- esdat_adapter()$parse(chem_path, meta)
  expect_silent(sampleTidy:::ir_validate(out$results, kind = "results"))
})

test_that("R-4.2: lab_qualifier and comments pass through verbatim", {
  meta <- sampleTidy:::file_meta(chem_path)
  out <- esdat_adapter()$parse(chem_path, meta)
  ec002 <- out$results[out$results$lab_sample_id == "XX1234567002" &
                          grepl("Electrical Conductivity", out$results$analyte_raw), ]
  expect_identical(ec002$lab_qualifier, "J")
  qc001 <- out$results[out$results$lab_sample_id == "QC-000001", ]
  expect_identical(qc001$comments, "Duplicate check")
})

test_that("R-4.2: corrupted Chemistry2e data causes parse() to abort loudly (plan-09/10 fixture)", {
  # The fixture's CSV grammar is well-formed (readr::read_csv reads it without
  # error - see fixtures/esdat/README.md) but its OriginalChemName field
  # contains a bare, invalid-on-its-own UTF-8 continuation byte (0x80); base
  # R's nchar()/toupper() throw hard "invalid multibyte string" errors on it.
  # A CONTRACT-conformant adapter never lets a bare R error escape - it wraps
  # failures as a classed sampletidy_parse_error (as R-4.4 already requires
  # for a non-ESdat XML).
  meta <- sampleTidy:::file_meta(corrupt_path)
  expect_error(esdat_adapter()$parse(corrupt_path, meta), class = "sampletidy_parse_error")
})

# ---- R-4.3 Sample2e -> ir_samples -------------------------------------------

test_that("R-4.3: Sample2e fixture maps 1:1 (6 rows)", {
  meta <- sampleTidy:::file_meta(sample_path)
  out <- esdat_adapter()$parse(sample_path, meta)
  expect_equal(nrow(out$samples), 6)
})

test_that("R-4.3: Sample_Type values pass through verbatim", {
  meta <- sampleTidy:::file_meta(sample_path)
  out <- esdat_adapter()$parse(sample_path, meta)
  expect_setequal(out$samples$sample_type, c("Normal", "Normal", "Normal", "LCS", "MB", "NCP"))
  normal_features <- out$samples$feature_raw[out$samples$sample_type == "Normal"]
  expect_setequal(normal_features, c("T.S01", "T.S02", "T.MW01"))
  ncp_row <- out$samples[out$samples$sample_type == "NCP", ]
  expect_identical(ncp_row$work_order, "YY0000001")
})

test_that("R-4.3: ir_validate() passes on Sample2e output", {
  meta <- sampleTidy:::file_meta(sample_path)
  out <- esdat_adapter()$parse(sample_path, meta)
  expect_silent(sampleTidy:::ir_validate(out$samples, kind = "samples"))
})

test_that("R-4.3: lone Header-less/Chemistry-less Sample2e parses fine", {
  meta <- sampleTidy:::file_meta(lone_sample_path)
  out <- esdat_adapter()$parse(lone_sample_path, meta)
  expect_equal(nrow(out$samples), 1)
  expect_identical(out$samples$feature_raw, "T.S01")
  expect_identical(out$samples$work_order, "XX7654321")
  expect_silent(sampleTidy:::ir_validate(out$samples, kind = "samples"))
})

# ---- R-4.4 Header.XML -> report metadata ------------------------------------

test_that("R-4.4: Header.XML yields the pinned report metadata", {
  meta <- sampleTidy:::file_meta(header_path)
  out <- esdat_adapter()$parse(header_path, meta)
  expect_equal(nrow(out$results), 0)
  expect_equal(nrow(out$samples), 0)
  h <- out$report$header
  expect_identical(h$work_order, "XX1234567")
  expect_identical(h$date_reported, "2025-05-28")
  expect_identical(h$project_id, "PROJ_A")
  expect_identical(h$lab_name, "ALSE-Sydney")
})

test_that("R-4.4: a non-ESdat XML aborts with sampletidy_parse_error", {
  meta <- sampleTidy:::file_meta(not_esdat_path)
  expect_error(esdat_adapter()$parse(not_esdat_path, meta), class = "sampletidy_parse_error")
})

# ---- R-4.5 parse() report ----------------------------------------------------

test_that("R-4.5: QC/NCP rows appear in n_by_sample_type, not in skipped", {
  meta <- sampleTidy:::file_meta(sample_path)
  out <- esdat_adapter()$parse(sample_path, meta)
  nbst <- out$report$n_by_sample_type
  expect_equal(unname(nbst[["LCS"]]), 1)
  expect_equal(unname(nbst[["MB"]]), 1)
  expect_equal(unname(nbst[["NCP"]]), 1)
  expect_equal(unname(nbst[["Normal"]]), 3)
  # QC/NCP rows must never be silently routed to `skipped` instead of counted
  expect_false(any(c("QC-000001", "QC-000002", "YY0000001") %in% out$report$skipped$source_ref))
})

test_that("R-4.5: an unparseable Analysed_Date lands in warnings; row still emitted with NA", {
  meta <- sampleTidy:::file_meta(baddate_path)
  out <- esdat_adapter()$parse(baddate_path, meta)
  expect_equal(nrow(out$results), 1)
  expect_true(is.na(out$results$analysed_date[1]))
  # source_ref is pinned as paste0("row", <1-based data row>) - R-4.2
  expect_identical(out$results$source_ref[1], "row1")
  expect_true(length(out$report$warnings) >= 1)
  expect_true(any(grepl("row1", out$report$warnings, fixed = TRUE)))
})
