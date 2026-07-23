# Plan 01 - R-1.1 st_config(): configuration get/set (options-backed,
# prefix `sampletidy.`), resolution order option > env var
# `SAMPLETIDY_<KEY>` > built-in default.

test_that("R-1.1: unset key with no default aborts naming the key", {
  withr::local_options(list("sampletidy.input_dir" = NULL))
  withr::local_envvar(c(SAMPLETIDY_INPUT_DIR = NA))
  err <- tryCatch(st_config("input_dir"), error = function(e) e)
  expect_s3_class(err, "sampletidy_error")
  expect_match(conditionMessage(err), "input_dir")
})

test_that("R-1.1: set then get round-trips through options", {
  withr::local_options(list("sampletidy.archive_dir" = NULL))
  st_config("archive_dir", "/tmp/archive-test-path")
  expect_equal(st_config("archive_dir"), "/tmp/archive-test-path")
})

test_that("R-1.1: env var wins over built-in default", {
  withr::local_options(list("sampletidy.archive_dir" = NULL))
  withr::local_envvar(c(SAMPLETIDY_ARCHIVE_DIR = "/env/archive/path"))
  expect_equal(st_config("archive_dir"), "/env/archive/path")
})

test_that("R-1.1: option wins over env var", {
  withr::local_envvar(c(SAMPLETIDY_ARCHIVE_DIR = "/env/archive/path"))
  withr::local_options(list("sampletidy.archive_dir" = "/option/archive/path"))
  expect_equal(st_config("archive_dir"), "/option/archive/path")
})

test_that("R-1.1: live_db default lives under R_user_dir, never a cloud-sync path", {
  withr::local_options(list("sampletidy.live_db" = NULL))
  withr::local_envvar(c(SAMPLETIDY_LIVE_DB = NA))
  default_db <- st_config("live_db")
  expect_true(grepl(tools::R_user_dir("sampleTidy", "data"), default_db, fixed = TRUE))
})

test_that("R-1.1: field_analytes default is the pinned vector", {
  withr::local_options(list("sampletidy.field_analytes" = NULL))
  withr::local_envvar(c(SAMPLETIDY_FIELD_ANALYTES = NA))
  expect_equal(st_config("field_analytes"), c("pH", "Temperature", "Conductivity", "EC"))
})

test_that("R-1.1: remove_ingested default is TRUE (supersedes A13's FALSE, 2026-07-23)", {
  withr::local_options(list("sampletidy.remove_ingested" = NULL))
  withr::local_envvar(c(SAMPLETIDY_REMOVE_INGESTED = NA))
  expect_identical(st_config("remove_ingested"), TRUE)
})

test_that("R-1.1: corpus_dir defaults from Sys.getenv(SAMPLETIDY_CORPUS)", {
  withr::local_options(list("sampletidy.corpus_dir" = NULL))
  withr::local_envvar(c(SAMPLETIDY_CORPUS = "/some/corpus/dir", SAMPLETIDY_CORPUS_DIR = NA))
  expect_equal(st_config("corpus_dir"), "/some/corpus/dir")
})

test_that("R-1.1: corpus_dir defaults to empty string when SAMPLETIDY_CORPUS unset", {
  withr::local_options(list("sampletidy.corpus_dir" = NULL))
  withr::local_envvar(c(SAMPLETIDY_CORPUS = NA, SAMPLETIDY_CORPUS_DIR = NA))
  expect_equal(st_config("corpus_dir"), "")
})

# Plan 12 - R-12.11 st_config() env-var typing (F16): DECIDED string-only +
# guard. field_analytes is the one known list-valued key today; sourcing it
# from an env var must abort loud (sampletidy_error) rather than silently
# shrinking the allowlist to a single string. A scalar key must be unaffected
# by the guard, and setting field_analytes via st_config(key, value) in code
# (i.e. through the option) must still round-trip a real vector.

test_that("R-12.11: field_analytes sourced from an env var aborts sampletidy_error, not a silent one-entry allowlist", {
  withr::local_options(list("sampletidy.field_analytes" = NULL))
  withr::local_envvar(c(SAMPLETIDY_FIELD_ANALYTES = "pH"))
  err <- tryCatch(st_config("field_analytes"), error = function(e) e)
  expect_s3_class(err, "sampletidy_error")
  expect_match(conditionMessage(err), "field_analytes", fixed = TRUE)
  # Guidance must point the caller at setting it in code, not just name the key.
  expect_match(conditionMessage(err), "code", ignore.case = TRUE)
  # And the failure must be a hard abort, never a length-1 fallback value.
  expect_error(st_config("field_analytes"), class = "sampletidy_error")
})

test_that("R-12.11: a scalar key still resolves from its env var, unaffected by the list-key guard", {
  withr::local_options(list("sampletidy.archive_dir" = NULL))
  withr::local_envvar(c(SAMPLETIDY_ARCHIVE_DIR = "/env/archive/for-r12.11"))
  expect_equal(st_config("archive_dir"), "/env/archive/for-r12.11")
})

test_that("R-12.11: field_analytes set via st_config(key, value) in code round-trips as a real vector", {
  withr::local_options(list("sampletidy.field_analytes" = NULL))
  withr::local_envvar(c(SAMPLETIDY_FIELD_ANALYTES = NA))
  st_config("field_analytes", c("Arsenic", "Lead", "Cadmium"))
  expect_identical(st_config("field_analytes"), c("Arsenic", "Lead", "Cadmium"))
})

test_that("R-12.11: an option-set field_analytes value wins before the env-var guard is ever consulted", {
  withr::local_options(list("sampletidy.field_analytes" = c("X", "Y")))
  withr::local_envvar(c(SAMPLETIDY_FIELD_ANALYTES = "should-not-be-read"))
  expect_identical(st_config("field_analytes"), c("X", "Y"))
})
