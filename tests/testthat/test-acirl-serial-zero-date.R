# tests/testthat/test-acirl-serial-zero-date.R
#
# 2026-10-19 corpus finding (PLAN-06 R-6.3c): the Katoomba quarterlies
# `2400-7223-09-1` (Sep 2022) and `24006990-11` (Nov 2020) carry, on their
# `Groundwater Sites` sheet, a `Date of Sample` row holding the visit's serial
# in every sample column EXCEPT the last (`MP # 4`, cell K11), which holds 0 -
# Excel's rendering of a formula over an empty cell. The adapter converted it
# with excel_date(0) = 1899-12-30 and emitted `sample_datetime_raw =
# "30/12/1899"`; both workbooks then collided on (MP # 4, 1899-12-30): five
# field readings committed under ES2233700 against a date that does not exist,
# plus three false value_conflicts from the Nov 2020 file.
#
# Decided behaviour: a date-row serial <= 0 is not a date - it is treated
# exactly as an EMPTY date cell, so the existing fill-down rule (PLAN-06
# layout facts: "the same sheet can hold multiple visits (date filled down)")
# gives the column the last real date to its left. With no real date to the
# left, the column's date is NA (-> reconcile's R-8.5 datetime parse_error
# path), never 1899-12-30.
#
# Fixture: fixtures/corpus-2026-10-19/2400-9999-16_SerialZeroDate_WMF.xlsx - the real
# Sep 2022 `Front Page` + `Groundwater Sites` sheets, anonymized
# (generate-serial-zero.R). Date row: 44823 in D11:J11, 0 in K11.

acirl_adapter <- function() sampleTidy:::adapter_registry()[["acirl_field_xlsx"]]
serial0_path <- test_path("fixtures", "corpus-2026-10-19", "2400-9999-16_SerialZeroDate_WMF.xlsx")

parse_acirl <- function(p) {
  suppressMessages(acirl_adapter()$parse(p, sampleTidy:::file_meta(p)))
}

test_that("fixture precondition: the date row really holds 44823 ... 0", {
  g <- suppressMessages(readxl::read_excel(serial0_path, sheet = "Groundwater Sites",
                                           col_names = FALSE, col_types = "text"))
  expect_identical(g[[2]][[11]], "Date of Sample")
  expect_identical(g[[10]][[11]], "44823")
  expect_identical(g[[11]][[11]], "0")
  expect_identical(g[[11]][[12]], "PZ # 4")
})

test_that("R-6.3c: no sample or result is ever dated 1899-12-30 (Excel serial 0)", {
  out <- parse_acirl(serial0_path)
  expect_identical(acirl_adapter()$match(sampleTidy:::file_meta(serial0_path)), "format")
  expect_false(any(out$samples$sample_datetime_raw %in% "30/12/1899", na.rm = TRUE))
  expect_false(any(grepl("1899", out$samples$sample_datetime_raw)))
})

test_that("R-6.3c: a serial-0 date cell fills from the last real date to its left", {
  out <- parse_acirl(serial0_path)
  s <- out$samples
  pz4 <- s[s$feature_raw == "PZ # 4", ]
  expect_equal(nrow(pz4), 1)
  expect_identical(pz4$source_ref, "Groundwater Sites!c11")
  # 44823 is the date every other column of this sheet carries.
  left <- s$sample_datetime_raw[s$source_ref == "Groundwater Sites!c10"]
  expect_identical(left, format(sampleTidy:::excel_date(44823), "%d/%m/%Y"))
  expect_identical(pz4$sample_datetime_raw, left)
  expect_identical(length(unique(s$sample_datetime_raw)), 1L)
})

test_that("R-6.3c: the serial-0 column's field readings are still emitted (data kept, only the date fixed)", {
  out <- parse_acirl(serial0_path)
  r <- out$results[out$results$lab_sample_id == "Groundwater Sites!c11", ]
  expect_equal(nrow(r), 5)
  vals <- stats::setNames(r$value_raw, r$analyte_raw)
  expect_identical(unname(vals[grepl("^pH$", names(vals))]), "6.8")
  expect_identical(unname(vals[grepl("Conductivity", names(vals))]), "508")
  expect_identical(unname(vals[grepl("Water Height", names(vals))]), "2.22")
})

test_that("R-6.3c: a serial-0 date with no real date to its left yields NA, not 1899-12-30", {
  # Same real sheet, with the FIRST sample column's date cell (D11) also set
  # to 0: there is nothing to fill from, so that column's date is unknown.
  dir <- withr::local_tempdir()
  p <- file.path(dir, basename(serial0_path))
  wb <- openxlsx::loadWorkbook(serial0_path)
  openxlsx::writeData(wb, "Groundwater Sites", x = 0, startRow = 11, startCol = 4,
                      colNames = FALSE, rowNames = FALSE)
  openxlsx::saveWorkbook(wb, p, overwrite = TRUE)

  out <- parse_acirl(p)
  s <- out$samples
  first <- s[s$source_ref == "Groundwater Sites!c4", ]
  expect_equal(nrow(first), 1)
  expect_true(is.na(first$sample_datetime_raw))
  # The columns to its right still carry their own real date.
  second <- s$sample_datetime_raw[s$source_ref == "Groundwater Sites!c5"]
  expect_false(is.na(second))
  expect_false(grepl("1899", second))
  expect_false(any(grepl("1899", s$sample_datetime_raw)))
})
