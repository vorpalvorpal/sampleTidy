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

test_that("R-2.4: 'esdat' short-date dialect '07-May-24 11:30' parses (corpus-confirmed 2026-07-23)", {
  withr::local_locale(c(LC_TIME = "C"))
  # Real ESdat exports (e.g. the BWMF April 2024 rain-event files) render the
  # sample datetime as hyphen/2-digit-year rather than space/4-digit-year;
  # before this was accepted the reconciler flagged 443 spurious parse_errors.
  dt <- parse_lab_datetime("07-May-24 11:30", formats = "esdat")
  expect_equal(format(dt, "%Y-%m-%d %H:%M:%S", tz = "Australia/Sydney"), "2024-05-07 11:30:00")
  # Date-only short form falls through to midnight, never dropping a clock time.
  d <- parse_lab_datetime("07-May-24", formats = "esdat")
  expect_equal(format(d, "%Y-%m-%d %H:%M:%S", tz = "Australia/Sydney"), "2024-05-07 00:00:00")
})

test_that("R-2.4: the short-date ESdat dialect parses under every sample-datetime format list", {
  withr::local_locale(c(LC_TIME = "C"))
  # `.lab_datetime_formats$esdat`, `.st_join_datetime_formats` (assemble) and
  # `.rc_datetime_formats` (reconcile) are three independent literal lists that
  # each parse `sample_datetime_raw`; this guards them against drifting apart
  # (only one of the three raised the corpus parse_errors, but all three must
  # accept the dialect for the join key, reconcile and preset paths to agree).
  lists <- list(
    esdat_preset = .lab_datetime_formats$esdat,
    assemble     = .st_join_datetime_formats,
    reconcile    = .rc_datetime_formats
  )
  for (nm in names(lists)) {
    dt <- parse_lab_datetime("07-May-24 11:30", lists[[nm]])
    expect_equal(format(dt, "%Y-%m-%d %H:%M:%S", tz = "Australia/Sydney"),
                 "2024-05-07 11:30:00",
                 info = nm)
  }
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

test_that("R-2.4: a DST spring-forward gap time is NA, never silently reinterpreted (Phase-8b fix)", {
  withr::local_locale(c(LC_TIME = "C"))
  # 05 Oct 2025 is the first Sunday of October - Australia/Sydney's
  # spring-forward date; 02:00-02:59 local does not exist that day.
  result <- parse_lab_datetime(
    c("05 Oct 2025 01:30", "05 Oct 2025 02:30", "05 Oct 2025 03:30"),
    formats = "esdat"
  )
  expect_true(is.na(result[2]))
  expect_false(is.na(result[1]))
  expect_false(is.na(result[3]))
  # Valid times either side of the gap are unaffected and sort correctly -
  # the gap time must NOT have been silently normalised to that day's
  # midnight (which would sort BEFORE 01:30).
  expect_true(result[3] > result[1])

  # An ambiguous fall-back time (occurs twice; 06 Apr 2025 is 2025's first
  # Sunday of April) is a different case entirely and must still be
  # accepted, non-NA.
  fallback <- parse_lab_datetime("06 Apr 2025 02:30", formats = "esdat")
  expect_false(is.na(fallback))

  # A non-zero-padded valid time must still parse (guards against a
  # string-round-trip detection approach, which would wrongly NA this).
  non_padded <- parse_lab_datetime("5 Oct 2025 3:30", formats = "esdat")
  expect_false(is.na(non_padded))
  expect_equal(format(non_padded, "%Y-%m-%d %H:%M:%S", tz = "Australia/Sydney"),
               "2025-10-05 03:30:00")
})
