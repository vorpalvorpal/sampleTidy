# A88 (dev/plans/OPERATING-RULES.md): adapters may attach optional review
# columns to `results` ONLY when a row is flagged. ir_validate() must accept
# them (needs_review logical, review_kind character, review_payload LIST,
# review_withhold logical) yet still reject unknown extras / wrong types.
# NOTE: the pipeline never calls ir_validate() on adapter output after the
# columns are attached (only the ir_results()/ir_samples() constructors do,
# before attachment), so the e2e review tests pass; the gated real-corpus test
# in test-adapter-acirl-gas.R is the only caller that hits this.

rv_noop <- function() NULL
# The gas e2e builders (gas_db_setup, gas_ingest, gas_e2e_workbook, ...) live
# in test-acirl-gas-e2e.R, not a helper: evaluate only its top-level
# assignments (never its test_that blocks) so this file stands alone.
local({
  src <- file.path(testthat::test_path(), "test-acirl-gas-e2e.R")
  if (!file.exists(src)) src <- "test-acirl-gas-e2e.R"
  for (e in parse(src)) {
    if (is.call(e) && identical(e[[1]], as.name("<-"))) eval(e, envir = environment(rv_noop))
  }
})

rv_one_row <- function() {
  x <- ir_results()
  x[1, ] <- NA
  x$source_hash <- "h"; x$org <- "ACIRL"; x$adapter <- "t"
  x$analyte_raw <- "CH4"; x$value_raw <- "0.125"
  x
}

rv_flag <- function(x, n = nrow(x)) {
  x$needs_review <- rep(TRUE, n)
  x$review_kind <- rep("k", n)
  x$review_payload <- rep(list(list(a = 1)), n)
  x$review_withhold <- rep(TRUE, n)
  x
}

test_that("A88: ir_validate accepts the four review columns on a flagged row", {
  x <- rv_flag(rv_one_row())
  expect_no_error(ir_validate(x, "results"))
})

test_that("A88: ir_validate accepts the review columns on a zero-row results tibble", {
  expect_no_error(ir_validate(rv_flag(ir_results()), "results"))
})

test_that("A88: review columns with NA kind / NULL payload / FALSE flag (mixed rows) validate", {
  x <- rv_one_row()[c(1, 1), ]
  x$needs_review <- c(TRUE, FALSE)
  x$review_kind <- c("k", NA_character_)
  x$review_payload <- list(list(a = 1), NULL)
  x$review_withhold <- c(FALSE, TRUE)
  expect_no_error(ir_validate(x, "results"))
})

test_that("A88: a genuinely unknown extra column is still rejected", {
  x <- rv_flag(rv_one_row())
  x$bogus_column <- "z"
  expect_error(ir_validate(x, "results"), "bogus_column", class = "sampletidy_ir_error")
  y <- rv_one_row(); y$bogus_column <- "z"
  expect_error(ir_validate(y, "results"), "bogus_column", class = "sampletidy_ir_error")
})

test_that("A88: review columns are not allowed on `samples`", {
  s <- ir_samples()
  s$needs_review <- logical(0)
  expect_error(ir_validate(s, "samples"), "needs_review", class = "sampletidy_ir_error")
})

test_that("A88: a wrong-typed review column is rejected, naming the column", {
  for (bad in list(
    list("needs_review", "yes"),
    list("review_kind", 1L),
    list("review_payload", "not a list"),
    list("review_withhold", "TRUE")
  )) {
    x <- rv_flag(rv_one_row())
    x[[bad[[1]]]] <- bad[[2]]
    expect_error(ir_validate(x, "results"), bad[[1]], class = "sampletidy_ir_error",
                 info = bad[[1]])
  }
})

test_that("A88: results WITHOUT review columns still validate; the prototype is unchanged", {
  expect_no_error(ir_validate(rv_one_row(), "results"))
  proto <- ir_results()
  expect_equal(nrow(proto), 0)
  expect_false(any(c("needs_review", "review_kind", "review_payload", "review_withhold") %in% names(proto)))
  expect_length(names(proto), 23)
})

test_that("A88: a flagged gas workbook (>2 dp reading) runs through ingest_dir without an IR error", {
  # Pins the pipeline end to end; passes today because the pipeline does not
  # validate after attachment. Guards against anyone adding a strict validate.
  db <- gas_db_setup()
  expect_no_error(suppressMessages(gas_ingest(db, g185 = 0.125)))
})

test_that("A88: the gas adapter's flagged parse() output passes ir_validate", {
  d <- withr::local_tempdir()
  p <- gas_e2e_workbook(d, g185 = 0.125)
  out <- gas_parse(if (length(p) && is.character(p) && file.exists(p[[1]])) p[[1]] else list.files(d, full.names = TRUE, pattern = "xlsx$")[[1]])
  expect_true("needs_review" %in% names(out$results))
  expect_no_error(sampleTidy:::ir_validate(out$results, "results"))
})
