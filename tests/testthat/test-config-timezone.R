# Stage 1 of the layer move: the time zone is configuration, not a constant.
#
#   st_config("timezone")   option `sampletidy.timezone` > env SAMPLETIDY_TIMEZONE > "UTC"
#   .st_tz()                the validated zone, read at CALL time everywhere
#
# helper-aaa-isolation.R pins the option to Australia/Sydney for the rest of
# the suite; every test here clears or sets it itself.

tz_clean <- function(env = parent.frame()) {
  withr::local_options(list(sampletidy.timezone = NULL), .local_envir = env)
  withr::local_envvar(c(SAMPLETIDY_TIMEZONE = NA), .local_envir = env)
}

# ---- resolution --------------------------------------------------------------

test_that("timezone: with the option and the env var unset the default is UTC", {
  tz_clean()
  expect_identical(st_config("timezone"), "UTC")
})

test_that("timezone: the env var is used when no option is set; an option beats the env var", {
  tz_clean()
  withr::local_envvar(c(SAMPLETIDY_TIMEZONE = "Europe/London"))
  expect_identical(st_config("timezone"), "Europe/London")
  withr::local_options(list(sampletidy.timezone = "Asia/Tokyo"))
  expect_identical(st_config("timezone"), "Asia/Tokyo")
})

# ---- read at call time -----------------------------------------------------------

test_that("timezone: parse_lab_datetime reads the zone at call time (same string, different instants)", {
  tz_clean()
  fmts <- sampleTidy:::.rc_datetime_formats
  withr::local_options(list(sampletidy.timezone = "UTC"))
  utc <- sampleTidy:::parse_lab_datetime("01 Jun 2026 09:30", fmts)
  withr::local_options(list(sampletidy.timezone = "Pacific/Auckland"))
  akl <- sampleTidy:::parse_lab_datetime("01 Jun 2026 09:30", fmts)
  expect_identical(attr(utc, "tzone"), "UTC")
  expect_identical(attr(akl, "tzone"), "Pacific/Auckland")
  # 09:30 NZST (UTC+12) is 21:30 UTC the day before: 12 hours earlier.
  expect_equal(as.numeric(utc) - as.numeric(akl), 12 * 3600)
})

test_that("timezone: an explicit tz argument still wins over the configured zone", {
  tz_clean()
  withr::local_options(list(sampletidy.timezone = "Pacific/Auckland"))
  x <- sampleTidy:::parse_lab_datetime("01 Jun 2026 09:30", sampleTidy:::.rc_datetime_formats,
                                       tz = "UTC")
  expect_identical(attr(x, "tzone"), "UTC")
})

test_that("timezone: db_checks_params()$tz follows the option", {
  tz_clean()
  withr::local_options(list(sampletidy.timezone = "Pacific/Auckland"))
  expect_identical(db_checks_params()$tz, "Pacific/Auckland")
  withr::local_options(list(sampletidy.timezone = "Europe/London"))
  expect_identical(db_checks_params()$tz, "Europe/London")
  withr::local_options(list(sampletidy.timezone = NULL))
  expect_identical(db_checks_params()$tz, "UTC")
})

# ---- validation ---------------------------------------------------------------------

test_that("timezone: an invalid zone aborts with sampletidy_error before it can reach a parser or SQL", {
  tz_clean()
  for (bad in c("Mars/Base", "", "UTC'; x")) {
    withr::local_options(list(sampletidy.timezone = bad))
    expect_error(sampleTidy:::parse_lab_datetime("01 Jun 2026 09:30", sampleTidy:::.rc_datetime_formats),
                 class = "sampletidy_error", info = bad)
    expect_error(sampleTidy:::.ct_local_day_sql("d"), class = "sampletidy_error", info = bad)
  }
})

test_that("timezone: a valid zone is embedded in the local-day SQL", {
  tz_clean()
  withr::local_options(list(sampletidy.timezone = "Europe/London"))
  sql <- sampleTidy:::.ct_local_day_sql("d")
  expect_match(sql, "'Europe/London'", fixed = TRUE)
  expect_no_match(sql, "Australia/Sydney", fixed = TRUE)
})

# ---- the flags "today" ----------------------------------------------------------------

test_that("timezone: import_flags 'today' is the local date in the configured zone", {
  tz_clean()
  db <- fl_db()
  # 2026-01-31 20:00 UTC is still 31 Jan in UTC and already 1 Feb (09:00) in Auckland.
  now <- as.POSIXct("2026-01-31 20:00:00", tz = "UTC")
  ch <- sx_checks(
    streams = sx_streams(list(stream = "s1", organisation = "FIELDCO", kind = "field")),
    schedule = fl_schedule(list(site = "N", stream = "s1", months = "all", due_days = "31")))
  # December 2025 is due 2025-12-31 + 31 days = 2026-01-31: overdue only once
  # "today" is after it.
  withr::local_options(list(sampletidy.timezone = "UTC"))
  utc <- sx_raw_flags(db, ch, now = now)
  expect_false("overdue|N|s1|2025-12" %in% utc$key)
  withr::local_options(list(sampletidy.timezone = "Pacific/Auckland"))
  akl <- sx_raw_flags(db, ch, now = now)
  expect_true("overdue|N|s1|2025-12" %in% akl$key)
})
