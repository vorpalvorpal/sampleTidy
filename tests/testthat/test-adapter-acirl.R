# tests/testthat/test-adapter-acirl.R
#
# TDD "red" tests for R/adapter-acirl-field.R (plan 06: `acirl_field_xlsx`).
# R/adapter-acirl-field.R does not exist yet, so every test below is expected
# to fail (missing function/object) until plan 06 lands. See
# dev/plans/PLAN-06-adapter-acirl-field.md and dev/plans/FIXTURES.md for the
# pinned contract, and tests/testthat/fixtures/acirl/README.md for the
# fixture layout decisions (transposed block, column positions, edge cases).
#
# Adapter accessor: as in the other adapter test files, we use the registry
# route pending adjudication (dev/plans/PLAN-CHANGE-REQUESTS.md).

acirl_adapter <- function() sampleTidy:::adapter_registry()[["acirl_field_xlsx"]]

main_path       <- test_path("fixtures", "acirl", "2400-9999-01 Test Month WMF.xlsx")
edge_path       <- test_path("fixtures", "acirl", "EDGECASES.xlsx")
no_report_path  <- test_path("fixtures", "acirl", "NO_REPORT_NO.xlsx")
random_xlsx_path <- test_path("fixtures", "acirl", "random.xlsx")
xtab_xlsx_path  <- test_path("fixtures", "crosstab", "XX1234567_0_XTAB.xlsx")

fake_als_labels <- c("Fluoride", "Sulphate", "Total Dissolved Solids", "Alkalinity")

# ---- R-6.1 match() ------------------------------------------------------------

test_that("R-6.1: main ACIRL workbook matches format", {
  meta <- sampleTidy:::file_meta(main_path)
  expect_identical(acirl_adapter()$match(meta), "format")
})

test_that("R-6.1: a random xlsx matches no", {
  meta <- sampleTidy:::file_meta(random_xlsx_path)
  expect_identical(acirl_adapter()$match(meta), "no")
})

test_that("R-6.1: the plan-05 XTAB xlsx crosstab fixture matches no", {
  meta <- sampleTidy:::file_meta(xtab_xlsx_path)
  expect_identical(acirl_adapter()$match(meta), "no")
})

# ---- R-6.2 front page ----------------------------------------------------------

test_that("R-6.2: front page yields REPORT NO / SAMPLED BY (stripped) / SAMPLE DATE", {
  meta <- sampleTidy:::file_meta(main_path)
  out <- acirl_adapter()$parse(main_path, meta)
  h <- out$report$header
  expect_identical(h$report_no, "2400-9999-01")
  expect_identical(h$sampled_by, "J. Tester")   # "& offsider" stripped, squished
  expect_identical(h$sample_date, "24/05/2025")
})

test_that("R-6.2: missing REPORT NO: continues parsing with a warning, work_order NA", {
  meta <- sampleTidy:::file_meta(no_report_path)
  out <- acirl_adapter()$parse(no_report_path, meta)
  expect_true(is.na(out$report$header$report_no))
  expect_true(length(out$report$warnings) >= 1)
  expect_true(any(grepl("REPORT NO", out$report$warnings, ignore.case = TRUE)))
  expect_true(nrow(out$results) >= 1)
  expect_true(all(is.na(out$results$work_order)))
})

# ---- R-6.3 water sheets -> ir_results + ir_samples ------------------------------

test_that("R-6.3: every fake ALS row is dropped - zero fake lab values appear in results", {
  meta <- sampleTidy:::file_meta(main_path)
  out <- acirl_adapter()$parse(main_path, meta)
  expect_false(any(out$results$analyte_raw %in% fake_als_labels))
  dropped <- out$report$skipped[out$report$skipped$reason == "lab_data_dropped", ]
  expect_equal(nrow(dropped), 32)  # 4 fake rows x 4 sample cols x 2 water sheets
})

test_that("R-6.3: results = features x visits x 3 field analytes minus the one empty cell", {
  meta <- sampleTidy:::file_meta(main_path)
  out <- acirl_adapter()$parse(main_path, meta)
  # 2 features x 2 visits x 3 analytes x 2 sheets = 24, minus 1 genuinely
  # empty Temperature cell (Field Data 1, T.S02 @ 25 May) = 23
  expect_equal(nrow(out$results), 23)
  expect_true(all(out$results$analyte_raw %in% c("pH", "EC", "Temperature")))
  empty_skips <- out$report$skipped[out$report$skipped$reason == "empty", ]
  expect_equal(nrow(empty_skips), 1)
})

test_that("R-6.3: EC mojibake unit variant and Temperature 'oC' both normalise correctly", {
  meta <- sampleTidy:::file_meta(main_path)
  out <- acirl_adapter()$parse(main_path, meta)
  ec_rows <- out$results[out$results$analyte_raw == "EC", ]
  expect_true(nrow(ec_rows) > 0)
  expect_true(all(ec_rows$units_raw == "µS/cm"))  # both clean and mojibake sheets normalise the same

  temp_rows <- out$results[out$results$analyte_raw == "Temperature", ]
  expect_true(nrow(temp_rows) > 0)
  expect_true(all(temp_rows$units_raw == "°C"))   # 'oC' repaired to the real degree sign
})

# NOTE (orchestrator fix): date fill-down is a `samples`-level property -
# `sample_datetime_raw` is a samples-only IR column (R/ir.R), not on `results`.
# The original test read `out$results$sample_datetime_raw` (always NULL), a
# copy-paste slip from the results-based tests; test 10 below already asserts
# the same per-visit fill-down correctly via `out$samples`. Retargeted to
# `out$samples` per [NO SILENT DEVIATION] (trivial test bug, fixed with a note).
test_that("R-6.3: date fill-down - second-visit rows carry the second date (25/05/2025)", {
  meta <- sampleTidy:::file_meta(main_path)
  out <- acirl_adapter()$parse(main_path, meta)
  visit1 <- out$samples[out$samples$sample_datetime_raw == "24/05/2025", ]
  visit2 <- out$samples[out$samples$sample_datetime_raw == "25/05/2025", ]
  expect_true(nrow(visit1) > 0)
  expect_true(nrow(visit2) > 0)
  expect_equal(nrow(visit1) + nrow(visit2), nrow(out$samples))
})

test_that("R-6.3: Comments cell text lands on the matching ir_samples row, not as a result", {
  meta <- sampleTidy:::file_meta(main_path)
  out <- acirl_adapter()$parse(main_path, meta)
  expect_false(any(out$results$analyte_raw == "Comments"))
  clear_row <- out$samples[!is.na(out$samples$comments) & out$samples$comments == "Clear", ]
  expect_equal(nrow(clear_row), 1)
  expect_identical(clear_row$feature_raw, "T.S01")
  expect_identical(clear_row$sample_datetime_raw, "24/05/2025")

  turbid_row <- out$samples[!is.na(out$samples$comments) &
                               out$samples$comments == "Slight turbidity", ]
  expect_equal(nrow(turbid_row), 1)
  expect_identical(turbid_row$feature_raw, "T.S01")
  expect_identical(turbid_row$sample_datetime_raw, "25/05/2025")
})

test_that("R-6.3: sampler is recorded from the front page on water-sheet samples", {
  meta <- sampleTidy:::file_meta(main_path)
  out <- acirl_adapter()$parse(main_path, meta)
  expect_true(all(out$samples$sampler == "J. Tester"))
})

test_that("R-6.3: ir_validate() passes on the main workbook's output", {
  meta <- sampleTidy:::file_meta(main_path)
  out <- acirl_adapter()$parse(main_path, meta)
  expect_silent(sampleTidy:::ir_validate(out$results, kind = "results"))
  expect_silent(sampleTidy:::ir_validate(out$samples, kind = "samples"))
})

test_that("R-6.3: a >20-row field block emits a warning but still parses", {
  meta <- sampleTidy:::file_meta(edge_path)
  out <- acirl_adapter()$parse(edge_path, meta)
  expect_true(any(grepl("20", out$report$warnings)))
  big_ph <- out$results[out$results$analyte_raw == "pH" & out$results$value_raw == "7", ]
  # Field Data Big's own pH values (7.00, 7.10, 7.05, 7.15) must appear
  expect_true(any(out$results$value_raw %in% c("7", "7.1", "7.05", "7.15") |
                    out$results$value_num %in% c(7, 7.1, 7.05, 7.15)))
})

test_that("R-6.3: a water sheet with no Units marker is skipped; sibling sheets still parse", {
  meta <- sampleTidy:::file_meta(edge_path)
  out <- acirl_adapter()$parse(edge_path, meta)
  # Field Data NoUnits' own pH values (7.20, 7.35) must be entirely absent
  no_units_present <- any(out$results$value_num %in% c(7.20, 7.35))
  expect_false(no_units_present)
  expect_true(any(grepl("Units", out$report$warnings, ignore.case = TRUE) |
                    grepl("NoUnits", out$report$warnings, fixed = TRUE)))
  # Field Data Big must still have parsed successfully alongside the skip
  expect_true(nrow(out$results) > 0)
})

# ---- R-6.4 dust sheets (A10) -----------------------------------------------------

test_that("R-6.4: dust sheet is detected and skipped, no dust-derived rows", {
  meta <- sampleTidy:::file_meta(main_path)
  out <- acirl_adapter()$parse(main_path, meta)
  dust_skips <- out$report$skipped[out$report$skipped$reason == "dust_sheet_ignored", ]
  expect_equal(nrow(dust_skips), 1)
  expect_false(any(out$results$value_num == 12.4, na.rm = TRUE))
  expect_false(any(grepl("PM10", out$results$analyte_raw, ignore.case = TRUE)))
})
