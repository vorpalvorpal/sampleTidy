# Plan 02 - R-2.4 parse_lab_datetime(x, formats, tz = "Australia/Sydney") and
# excel_date(n). Month-name parsing assumes English locale - guarded per
# CONTRACT conventions with withr::local_locale(c(LC_TIME = "C")).
#
# Numeric claim verified independently before baking in ([MEASURE TWICE]):
# as.Date(45802, origin = "1899-12-30") == as.Date("2025-05-25").

test_that("R-2.4: 'esdat' format with clock time parses to the correct Australia/Sydney wall time", {
  withr::local_locale(c(LC_TIME = "C"))
  result <- parse_lab_datetime("24 May 2025 11:45", formats = "esdat")
  expect_equal(format(result, "%Y-%m-%d %H:%M:%S", tz = "Australia/Sydney"), "2025-05-24 11:45:00")
})

test_that("R-2.4: 'esdat' date-only format parses to midnight", {
  withr::local_locale(c(LC_TIME = "C"))
  result <- parse_lab_datetime("26 May 2025", formats = "esdat")
  expect_equal(format(result, "%Y-%m-%d %H:%M:%S", tz = "Australia/Sydney"), "2025-05-26 00:00:00")
})

test_that("R-2.4: 'crosstab' format is d/m/y - '05/01/2026' parses as 5 January (load-bearing)", {
  result <- parse_lab_datetime("05/01/2026", formats = "crosstab")
  expect_equal(format(result, "%Y-%m-%d", tz = "Australia/Sydney"), "2026-01-05")
})

test_that("R-2.4: an invalid date '13/13/2025' is NA, not silently reinterpreted", {
  result <- parse_lab_datetime("13/13/2025", formats = "crosstab")
  expect_true(is.na(result))
})

test_that("R-2.4: a mixed vector parses element-wise", {
  withr::local_locale(c(LC_TIME = "C"))
  result <- parse_lab_datetime(c("24 May 2025 11:45", "26 May 2025"), formats = "esdat")
  expect_length(result, 2)
  expect_equal(format(result, "%Y-%m-%d %H:%M:%S", tz = "Australia/Sydney"),
               c("2025-05-24 11:45:00", "2025-05-26 00:00:00"))
})

test_that("R-2.4: empty string input is NA", {
  result <- parse_lab_datetime("", formats = "crosstab")
  expect_true(is.na(result))
})

test_that("R-2.4: 'iso' format parses both date-time and date-only forms", {
  result_dt <- parse_lab_datetime("2025-05-24 11:45", formats = "iso")
  result_d <- parse_lab_datetime("2025-05-24", formats = "iso")
  expect_equal(format(result_dt, "%Y-%m-%d %H:%M:%S", tz = "Australia/Sydney"), "2025-05-24 11:45:00")
  expect_equal(format(result_d, "%Y-%m-%d %H:%M:%S", tz = "Australia/Sydney"), "2025-05-24 00:00:00")
})

test_that("R-2.4: has_clock_time() is TRUE iff a time component was present in the source string", {
  withr::local_locale(c(LC_TIME = "C"))
  expect_true(has_clock_time("24 May 2025 11:45"))
  expect_false(has_clock_time("26 May 2025"))
  expect_equal(has_clock_time(c("24 May 2025 11:45", "26 May 2025")), c(TRUE, FALSE))
})

test_that("R-2.4: excel_date(45802) == as.Date('2025-05-25')", {
  expect_equal(excel_date(45802), as.Date("2025-05-25"))
})
