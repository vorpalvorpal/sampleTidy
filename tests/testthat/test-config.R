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

test_that("R-1.1: remove_ingested default is FALSE (A13)", {
  withr::local_options(list("sampletidy.remove_ingested" = NULL))
  withr::local_envvar(c(SAMPLETIDY_REMOVE_INGESTED = NA))
  expect_identical(st_config("remove_ingested"), FALSE)
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
