# The ACIRL job prefix is deployment config, st_config("acirl_job_prefix"), not
# a constant in the ingest code.
#
#   NULL (the default)  no name is ACIRL-shaped; the type table has no ACIRL row.
#   one string of 1-8 ASCII digits   names carrying `<prefix>-?NNNN` (not preceded
#                       by another digit) are ACIRL-shaped.
#   anything else       (letters, "", NA, wrong length, a number) aborts with
#                       sampletidy_error, naming the key.
#
# The setup file pins "2400" for the older suites; these tests set their own.

is_acirl <- function(x) sampleTidy:::.ig_is_acirl_shaped(x)

test_that("acirl_job_prefix NULL: nothing is ACIRL-shaped and st_config() is NULL", {
  withr::local_options(list(sampletidy.acirl_job_prefix = NULL))
  withr::local_envvar(c(SAMPLETIDY_ACIRL_JOB_PREFIX = NA))
  expect_null(st_config("acirl_job_prefix"))
  expect_false(is_acirl("2400-9001-01 x.xls"))
  expect_false(is_acirl("24009001-01 x.xls"))
  expect_false(is_acirl("7310-1234 x.xls"))
})

test_that("acirl_job_prefix NULL: the type table has no ACIRL-prefix rule (fallback type only)", {
  withr::local_options(list(sampletidy.acirl_job_prefix = NULL))
  withr::local_envvar(c(SAMPLETIDY_ACIRL_JOB_PREFIX = NA))
  # No token, no prefix rule: the name falls through to the documented fallback.
  expect_identical(sampleTidy:::.ig_retained_asset_type("2400-9001-01 x.xls"),
                   "Chemical analysis")
})

test_that("acirl_job_prefix set to another value: that prefix matches and 2400 does not", {
  withr::local_options(list(sampletidy.acirl_job_prefix = "7310"))
  expect_true(is_acirl("7310-1234 x.xls"))
  expect_false(is_acirl("2400-1234 x.xls"))
  expect_identical(sampleTidy:::.ig_retained_asset_type("7310-1234 x.xls"),
                   "Chemical analysis")
})

test_that("acirl_job_prefix '2400': hyphenated, unhyphenated and the digit guard behave as before", {
  withr::local_options(list(sampletidy.acirl_job_prefix = "2400"))
  expect_true(is_acirl("2400-9001-01 x.xls"))
  expect_true(is_acirl("24009001-01 x.xls"))
  expect_true(is_acirl("Report 2400-9001 x.xls"))
  expect_false(is_acirl("12400-1234 not an acirl job.pdf"))
  expect_false(is_acirl("2400-123 short.pdf"))
})

test_that("acirl_job_prefix: a shorter prefix and an 8-digit prefix are valid", {
  withr::local_options(list(sampletidy.acirl_job_prefix = "99"))
  expect_true(is_acirl("99-1234 x.xls"))
  expect_false(is_acirl("199-1234 x.xls"))
  withr::local_options(list(sampletidy.acirl_job_prefix = "12345678"))
  expect_true(is_acirl("12345678-1234 x.xls"))
})

test_that("acirl_job_prefix: an invalid value aborts with sampletidy_error naming the key", {
  for (bad in list("abcd", "24a0", "", NA_character_, c("2400", "7310"),
                   "123456789", 2400, TRUE, list("2400"))) {
    withr::local_options(list(sampletidy.acirl_job_prefix = bad))
    expect_error(is_acirl("2400-9001-01 x.xls"), class = "sampletidy_error",
                 regexp = "acirl_job_prefix",
                 info = paste(deparse(bad), collapse = ""))
  }
})

test_that("acirl_job_prefix: SAMPLETIDY_ACIRL_JOB_PREFIX is honoured when the option is unset, and the option beats it", {
  withr::local_options(list(sampletidy.acirl_job_prefix = NULL))
  withr::local_envvar(c(SAMPLETIDY_ACIRL_JOB_PREFIX = "7310"))
  expect_identical(st_config("acirl_job_prefix"), "7310")
  expect_true(is_acirl("7310-1234 x.xls"))
  expect_false(is_acirl("2400-1234 x.xls"))

  withr::local_options(list(sampletidy.acirl_job_prefix = "2400"))
  expect_identical(st_config("acirl_job_prefix"), "2400")
  expect_true(is_acirl("2400-1234 x.xls"))
})

test_that("acirl_job_prefix: an invalid environment value aborts naming the key", {
  withr::local_options(list(sampletidy.acirl_job_prefix = NULL))
  withr::local_envvar(c(SAMPLETIDY_ACIRL_JOB_PREFIX = "abc"))
  expect_error(is_acirl("2400-1234 x.xls"), class = "sampletidy_error",
               regexp = "acirl_job_prefix")
})

test_that("acirl_job_prefix: a valid value round-trips through st_config()", {
  withr::local_options(list(sampletidy.acirl_job_prefix = NULL))
  st_config("acirl_job_prefix", "7310")
  expect_identical(st_config("acirl_job_prefix"), "7310")
})
