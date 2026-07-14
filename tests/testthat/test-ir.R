# Plan 03 - R-3.1 IR constructors: ir_results()/ir_samples() build validated
# tibbles with exactly the columns of DESIGN §4.1/§4.2 (names, types, order
# pinned there); ir_validate(x, kind) aborts on structural/content violations.

results_cols <- c(
  "source_hash", "source_ref", "work_order", "revision", "org", "adapter",
  "lab_sample_id", "sample_type", "feature_raw", "analyte_raw", "cas_number",
  "method_raw", "total_or_filtered", "units_raw", "value_raw", "value_num",
  "value_chr", "below_detection", "rl", "lab_qualifier", "analysed_date",
  "comments", "confidence"
)
results_types <- c(
  source_hash = "character", source_ref = "character", work_order = "character",
  revision = "integer", org = "character", adapter = "character",
  lab_sample_id = "character", sample_type = "character", feature_raw = "character",
  analyte_raw = "character", cas_number = "character", method_raw = "character",
  total_or_filtered = "character", units_raw = "character", value_raw = "character",
  value_num = "double", value_chr = "character", below_detection = "logical",
  rl = "double", lab_qualifier = "character", analysed_date = "Date",
  comments = "character", confidence = "double"
)

samples_cols <- c(
  "source_hash", "source_ref", "work_order", "org", "adapter", "lab_sample_id",
  "feature_raw", "sample_datetime_raw", "sample_type", "parent_sample",
  "matrix_raw", "sampler", "comments", "confidence"
)
samples_types <- c(
  source_hash = "character", source_ref = "character", work_order = "character",
  org = "character", adapter = "character", lab_sample_id = "character",
  feature_raw = "character", sample_datetime_raw = "character", sample_type = "character",
  parent_sample = "character", matrix_raw = "character", sampler = "character",
  comments = "character", confidence = "double"
)

check_col_type <- function(col, type) {
  switch(type,
    character = is.character(col),
    integer = is.integer(col),
    double = is.double(col),
    logical = is.logical(col),
    Date = inherits(col, "Date"),
    stop("unknown type in test helper: ", type)
  )
}

# --- prototypes --------------------------------------------------------

test_that("R-3.1: ir_results() with no args returns the zero-row prototype with exact columns, order and types", {
  proto <- ir_results()
  expect_identical(names(proto), results_cols)
  expect_equal(nrow(proto), 0)
  for (col in results_cols) {
    expect_true(check_col_type(proto[[col]], results_types[[col]]), label = paste("column", col))
  }
})

test_that("R-3.1: ir_samples() with no args returns the zero-row prototype with exact columns, order and types", {
  proto <- ir_samples()
  expect_identical(names(proto), samples_cols)
  expect_equal(nrow(proto), 0)
  for (col in samples_cols) {
    expect_true(check_col_type(proto[[col]], samples_types[[col]]), label = paste("column", col))
  }
})

test_that("R-3.1: the zero-row prototypes round-trip ir_validate()", {
  expect_no_error(ir_validate(ir_results(), "results"))
  expect_no_error(ir_validate(ir_samples(), "samples"))
})

# NOTE: the exact argument-passing convention for ir_results(...)/ir_samples(...)
# beyond the zero-arg prototype is not pinned in PLAN-03; we assume named
# arguments matching column names (vectorised, tibble-constructor style).
# See dev/plans/PLAN-CHANGE-REQUESTS.md.
test_that("R-3.1: ir_results(...) constructs a validated single-row tibble from named column args", {
  row <- ir_results(
    source_hash = "hash1", source_ref = "Sheet1!B14", work_order = "XX1234567",
    revision = 0L, org = "ALS", adapter = "esdat:1.0", lab_sample_id = "XX1234567001",
    sample_type = "Normal", feature_raw = "T.S01", analyte_raw = "Fluoride",
    cas_number = "16984-48-8", method_raw = "EK040P: Fluoride by PC Titrator",
    total_or_filtered = "T", units_raw = "mg/L", value_raw = "0.1",
    value_num = 0.1, value_chr = NA_character_, below_detection = TRUE,
    rl = 0.1, lab_qualifier = NA_character_, analysed_date = as.Date("2025-05-26"),
    comments = NA_character_, confidence = 1
  )
  expect_equal(nrow(row), 1)
  expect_identical(names(row), results_cols)
  expect_no_error(ir_validate(row, "results"))
})

# --- ir_validate() violations: results ----------------------------------

valid_results_row <- tibble::tibble(
  source_hash = "hash1", source_ref = "Sheet1!B14", work_order = "XX1234567",
  revision = 0L, org = "ALS", adapter = "esdat:1.0", lab_sample_id = "XX1234567001",
  sample_type = "Normal", feature_raw = "T.S01", analyte_raw = "Fluoride",
  cas_number = "16984-48-8", method_raw = "EK040P: Fluoride by PC Titrator",
  total_or_filtered = "T", units_raw = "mg/L", value_raw = "0.1",
  value_num = 0.1, value_chr = NA_character_, below_detection = TRUE,
  rl = 0.1, lab_qualifier = NA_character_, analysed_date = as.Date("2025-05-26"),
  comments = NA_character_, confidence = 1
)
stopifnot(identical(names(valid_results_row), results_cols))

test_that("R-3.1: ir_validate() sanity-checks the valid_results_row fixture itself passes", {
  expect_no_error(ir_validate(valid_results_row, "results"))
})

test_that("R-3.1: ir_validate() aborts on a missing column, naming it", {
  broken <- valid_results_row[, setdiff(names(valid_results_row), "adapter")]
  err <- tryCatch(ir_validate(broken, "results"), error = function(e) e)
  expect_s3_class(err, "sampletidy_ir_error")
  expect_match(conditionMessage(err), "adapter", fixed = TRUE)
})

test_that("R-3.1: ir_validate() aborts on an extra column, naming it", {
  broken <- valid_results_row
  broken$totally_unexpected_column <- "oops"
  err <- tryCatch(ir_validate(broken, "results"), error = function(e) e)
  expect_s3_class(err, "sampletidy_ir_error")
  expect_match(conditionMessage(err), "totally_unexpected_column", fixed = TRUE)
})

test_that("R-3.1: ir_validate() aborts on a wrong-typed column, naming it", {
  broken <- valid_results_row
  broken$revision <- "0" # should be integer
  err <- tryCatch(ir_validate(broken, "results"), error = function(e) e)
  expect_s3_class(err, "sampletidy_ir_error")
  expect_match(conditionMessage(err), "revision", fixed = TRUE)
})

test_that("R-3.1: ir_validate() aborts on NA in required field source_hash, naming it", {
  broken <- valid_results_row
  broken$source_hash <- NA_character_
  err <- tryCatch(ir_validate(broken, "results"), error = function(e) e)
  expect_s3_class(err, "sampletidy_ir_error")
  expect_match(conditionMessage(err), "source_hash", fixed = TRUE)
})

test_that("R-3.1: ir_validate() aborts on NA in required field org, naming it", {
  broken <- valid_results_row
  broken$org <- NA_character_
  err <- tryCatch(ir_validate(broken, "results"), error = function(e) e)
  expect_s3_class(err, "sampletidy_ir_error")
  expect_match(conditionMessage(err), "\\borg\\b")
})

test_that("R-3.1: ir_validate() aborts on NA in required field adapter, naming it", {
  broken <- valid_results_row
  broken$adapter <- NA_character_
  err <- tryCatch(ir_validate(broken, "results"), error = function(e) e)
  expect_s3_class(err, "sampletidy_ir_error")
  expect_match(conditionMessage(err), "adapter", fixed = TRUE)
})

test_that("R-3.1: ir_validate() aborts on NA in required field analyte_raw (results only), naming it", {
  broken <- valid_results_row
  broken$analyte_raw <- NA_character_
  err <- tryCatch(ir_validate(broken, "results"), error = function(e) e)
  expect_s3_class(err, "sampletidy_ir_error")
  expect_match(conditionMessage(err), "analyte_raw", fixed = TRUE)
})

test_that("R-3.1: ir_validate() aborts on NA in required field value_raw (results only), naming it", {
  broken <- valid_results_row
  broken$value_raw <- NA_character_
  err <- tryCatch(ir_validate(broken, "results"), error = function(e) e)
  expect_s3_class(err, "sampletidy_ir_error")
  expect_match(conditionMessage(err), "value_raw", fixed = TRUE)
})

test_that("R-3.1: ir_validate() aborts when sample_type is not in the allowed set", {
  broken <- valid_results_row
  broken$sample_type <- "Weird"
  err <- tryCatch(ir_validate(broken, "results"), error = function(e) e)
  expect_s3_class(err, "sampletidy_ir_error")
  expect_match(conditionMessage(err), "sample_type", fixed = TRUE)
})

test_that("R-3.1: ir_validate() aborts when revision < 0", {
  broken <- valid_results_row
  broken$revision <- -1L
  err <- tryCatch(ir_validate(broken, "results"), error = function(e) e)
  expect_s3_class(err, "sampletidy_ir_error")
  expect_match(conditionMessage(err), "revision", fixed = TRUE)
})

# --- ir_validate() violations: samples -----------------------------------

valid_samples_row <- tibble::tibble(
  source_hash = "hash1", source_ref = "Sheet1!B14", work_order = "XX1234567",
  org = "ALS", adapter = "esdat:1.0", lab_sample_id = "XX1234567001",
  feature_raw = "T.S01", sample_datetime_raw = "24 May 2025 11:45",
  sample_type = "Normal", parent_sample = NA_character_, matrix_raw = "WATER",
  sampler = NA_character_, comments = NA_character_, confidence = 1
)
stopifnot(identical(names(valid_samples_row), samples_cols))

test_that("R-3.1: ir_validate() sanity-checks the valid_samples_row fixture itself passes", {
  expect_no_error(ir_validate(valid_samples_row, "samples"))
})

test_that("R-3.1: ir_validate() aborts on NA in required field source_hash for samples, naming it", {
  broken <- valid_samples_row
  broken$source_hash <- NA_character_
  err <- tryCatch(ir_validate(broken, "samples"), error = function(e) e)
  expect_s3_class(err, "sampletidy_ir_error")
  expect_match(conditionMessage(err), "source_hash", fixed = TRUE)
})

test_that("R-3.1: ir_validate() aborts when sample_type is not in the allowed set for samples", {
  broken <- valid_samples_row
  broken$sample_type <- "Weird"
  err <- tryCatch(ir_validate(broken, "samples"), error = function(e) e)
  expect_s3_class(err, "sampletidy_ir_error")
  expect_match(conditionMessage(err), "sample_type", fixed = TRUE)
})
