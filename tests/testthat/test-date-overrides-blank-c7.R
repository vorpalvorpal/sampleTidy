# tests/testthat/test-date-overrides-blank-c7.R
#
# TDD "red" tests for C7: a sample-date override row with a BLANK date_from
# means "rows of this file whose sample date is blank". It sets
# sample_datetime_raw to format(date_to, "%d/%m/%Y") for rows of that hash whose
# raw is NA, "" or whitespace-only. Non-blank raws (even unparseable, e.g.
# "TBC") and other files' rows are untouched. Dated overrides are unchanged.
# Fixtures/helpers follow tests/testthat/test-date-overrides.R (re-declared here
# so this file runs standalone).

bc_csv <- function(rows = character(0), dir = withr::local_tempdir(.local_envir = parent.frame())) {
  p <- file.path(dir, "overrides.csv")
  writeLines(c("hash,date_from,date_to,authority,reason", rows), p)
  p
}
bc_load <- function(p) sampleTidy:::.ig_date_overrides(p)
bc_apply <- function(s, o) sampleTidy:::.ig_apply_date_overrides(s, o)

bc_table <- function(hash, date_from, date_to) {
  data.frame(hash = hash, date_from = as.Date(date_from), date_to = as.Date(date_to),
             authority = rep("test", length(hash)), reason = rep("test", length(hash)),
             stringsAsFactors = FALSE)
}

bc_samples <- function(hash, raw, extra_hash = NULL) {
  n <- length(raw)
  hashes <- rep(hash, n)
  if (!is.null(extra_hash)) hashes <- extra_hash
  ir_samples(
    source_hash = hashes, source_ref = paste0("r", seq_len(n)),
    work_order = rep("WO1", n), org = rep("ACIRL", n), adapter = rep("test", n),
    lab_sample_id = rep(NA_character_, n), feature_raw = paste0("F", seq_len(n)),
    sample_datetime_raw = raw, sample_type = rep("Normal", n),
    parent_sample = rep(NA_character_, n), matrix_raw = rep("water", n),
    sampler = rep(NA_character_, n), comments = rep(NA_character_, n),
    confidence = rep(1, n)
  )
}

BH1 <- "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
BH2 <- "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

# ---- loader -----------------------------------------------------------------

test_that("loader: a blank date_from is accepted and loads as NA Date", {
  p <- bc_csv(paste0(BH1, ",,2024-12-03,ALS ES2439599,blank Date of Sample"))
  o <- expect_no_error(bc_load(p))
  expect_equal(nrow(o), 1L)
  expect_s3_class(o$date_from, "Date")
  expect_true(is.na(o$date_from[[1]]))
  expect_equal(o$date_to[[1]], as.Date("2024-12-03"))
  expect_identical(names(o), c("hash", "date_from", "date_to", "authority", "reason"))
})

test_that("loader: blank date_from coexists with a dated row for the same hash", {
  p <- bc_csv(c(paste0(BH1, ",,2024-12-03,a,blank"),
                paste0(BH1, ",2024-12-05,2024-12-03,a,dated")))
  o <- bc_load(p)
  expect_equal(nrow(o), 2L)
  expect_equal(sum(is.na(o$date_from)), 1L)
})

test_that("loader: a blank date_to is still rejected with sampletidy_error", {
  expect_error(bc_load(bc_csv(paste0(BH1, ",2024-12-05,,a,r"))), class = "sampletidy_error")
  expect_error(bc_load(bc_csv(paste0(BH1, ",,,a,r"))), class = "sampletidy_error")
})

test_that("loader: two blank date_from rows for one hash are a duplicate key", {
  p <- bc_csv(c(paste0(BH1, ",,2024-12-03,a,r"), paste0(BH1, ",,2024-12-04,a,r")))
  expect_error(bc_load(p), class = "sampletidy_error")
})

test_that("loader: a malformed non-blank date_from is still rejected", {
  expect_error(bc_load(bc_csv(paste0(BH1, ",14/04/2023,2023-04-13,a,r"))), class = "sampletidy_error")
})

# ---- applier ----------------------------------------------------------------

test_that("applier: NA, empty and whitespace-only raws take date_to as d/m/Y", {
  s <- bc_samples(BH1, c(NA_character_, "", "   ", "\t "))
  out <- bc_apply(s, bc_table(BH1, NA, "2024-12-03"))
  expect_identical(out$sample_datetime_raw, rep("03/12/2024", 4L))
})

test_that("applier: non-blank raws, including unparseable text, are untouched", {
  s <- bc_samples(BH1, c("TBC", "garbage", "14/04/2023", NA_character_))
  out <- bc_apply(s, bc_table(BH1, NA, "2024-12-03"))
  expect_identical(out$sample_datetime_raw, c("TBC", "garbage", "14/04/2023", "03/12/2024"))
})

test_that("applier: blank rows of other hashes are untouched", {
  s <- bc_samples(BH1, c(NA_character_, NA_character_, ""), extra_hash = c(BH1, BH2, BH2))
  out <- bc_apply(s, bc_table(BH1, NA, "2024-12-03"))
  expect_identical(out$sample_datetime_raw[[1]], "03/12/2024")
  expect_true(is.na(out$sample_datetime_raw[[2]]))
  expect_identical(out$sample_datetime_raw[[3]], "")
})

test_that("applier: only sample_datetime_raw changes; row order and types are kept", {
  s <- bc_samples(BH1, c("15/04/2023", NA_character_, "TBC"))
  out <- bc_apply(s, bc_table(BH1, NA, "2024-12-03"))
  strip <- function(x) { attr(x, "date_overrides_applied") <- NULL; x }
  expect_identical(names(out), names(s))
  expect_identical(strip(out)[setdiff(names(s), "sample_datetime_raw")],
                   s[setdiff(names(s), "sample_datetime_raw")])
  expect_identical(out$source_ref, s$source_ref)
  expect_identical(typeof(out$sample_datetime_raw), "character")
})

test_that("applier: attribute records the blank row with date_from NA and n_rows", {
  s <- bc_samples(BH1, c(NA_character_, "", "  ", "TBC", "14/04/2023"))
  out <- bc_apply(s, bc_table(BH1, NA, "2024-12-03"))
  applied <- attr(out, "date_overrides_applied")
  expect_s3_class(applied, "data.frame")
  expect_identical(names(applied), c("hash", "date_from", "date_to", "n_rows"))
  expect_equal(nrow(applied), 1L)
  expect_identical(applied$hash, BH1)
  expect_true(is.na(applied$date_from))
  expect_s3_class(applied$date_from, "Date")
  expect_equal(applied$date_to, as.Date("2024-12-03"))
  expect_equal(applied$n_rows, 3L)
})

test_that("applier: a blank row with no blank samples is not recorded", {
  s <- bc_samples(BH1, c("TBC", "14/04/2023"))
  out <- bc_apply(s, bc_table(BH1, NA, "2024-12-03"))
  expect_equal(nrow(attr(out, "date_overrides_applied")), 0L)
  expect_identical(out$sample_datetime_raw, c("TBC", "14/04/2023"))
})

test_that("applier: blank and dated overrides coexist for one hash", {
  s <- bc_samples(BH1, c(NA_character_, "05/12/2024", "", "20/12/2024"))
  o <- rbind(bc_table(BH1, NA, "2024-12-03"),
             bc_table(BH1, "2024-12-05", "2024-12-03"))
  out <- bc_apply(s, o)
  expect_identical(out$sample_datetime_raw,
                   c("03/12/2024", "03/12/2024", "03/12/2024", "20/12/2024"))
  applied <- attr(out, "date_overrides_applied")
  expect_equal(nrow(applied), 2L)
  expect_equal(applied$n_rows[is.na(applied$date_from)], 2L)
  expect_equal(applied$n_rows[!is.na(applied$date_from)], 1L)
})

test_that("applier: a dated override alone leaves blank rows untouched (unchanged behaviour)", {
  s <- bc_samples(BH1, c(NA_character_, "", "14/04/2023"))
  out <- bc_apply(s, bc_table(BH1, "2023-04-14", "2023-04-13"))
  expect_true(is.na(out$sample_datetime_raw[[1]]))
  expect_identical(out$sample_datetime_raw[[2]], "")
  expect_identical(out$sample_datetime_raw[[3]], "13/04/2023")
})

# ---- downstream: reconcile's datetime resolution ------------------------------

test_that("without a blank override, blank-date rows raise parse_error/datetime", {
  s <- bc_samples(BH1, c(NA_character_, "", "  "))
  res <- sampleTidy:::.rc_resolve_datetime(as.data.frame(s))
  expect_equal(nrow(res$kept), 0L)
  expect_equal(sum(res$review$kind == "parse_error" & res$review$subkind == "datetime"), 3L)
})

test_that("with a blank override, blank-date rows resolve to date_to and raise no datetime review", {
  s <- bc_samples(BH1, c(NA_character_, "", "  "))
  out <- bc_apply(s, bc_table(BH1, NA, "2024-12-03"))
  res <- sampleTidy:::.rc_resolve_datetime(as.data.frame(out))
  expect_equal(nrow(res$kept), 3L)
  expect_equal(nrow(res$review), 0L)
  expect_true(all(res$kept$sample_date == as.Date("2024-12-03")))
})
