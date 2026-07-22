# tests/testthat/test-read-encoding.R
#
# Tests for R/read-encoding.R: the mojibake quality probe
# (`.st_mojibake_probe`) and the symmetric encoding fallback
# (`.st_read_grid_with_encoding_fallback`) that both the crosstab (PLAN-05
# R-5.4) and ESdat (A34/A35) CSV read paths use. Root-caused 2026-07-22: XTAB
# .csv is valid UTF-8 with a pre-destroyed single U+FFFD; reading it as latin-1
# shatters that into the three-char "ix-triple" that the repair table cannot
# fix. All non-ASCII markers below are written as \u escapes (R CMD check
# requires ASCII source).

probe   <- function(x) sampleTidy:::.st_mojibake_probe(x)
fallback <- sampleTidy:::.st_read_grid_with_encoding_fallback

# A single-U+FFFD cell that normalise_lab_text() CAN repair (-> probe 0).
utf8_cells   <- c("Electrical Conductivity @ 25\ufffdC", "\ufffdS/cm")
# The shattered latin-1 triple that normalise_lab_text() CANNOT repair.
triple_cells <- c("Electrical Conductivity @ 25\u00ef\u00bf\u00bdC", "\u00ef\u00bf\u00bdS/cm")

# ---- .st_mojibake_probe ------------------------------------------------------

test_that("probe is 0 for clean ASCII text and for NULL/empty/NA", {
  expect_identical(probe(c("pH Value", "mg/L", "25")), 0L)
  expect_identical(probe(NULL), 0L)
  expect_identical(probe(character(0)), 0L)
  expect_identical(probe(c(NA_character_, NA_character_)), 0L)
})

test_that("probe is 0 AFTER normalise repairs a single U+FFFD (degree/micro)", {
  # `<U+FFFD>C` -> degree-C and `<U+FFFD>S/cm` -> micro-S/cm are in the repair
  # table, so the correct (single-U+FFFD) read scores 0.
  expect_identical(probe(utf8_cells), 0L)
})

test_that("probe counts cells the repair table cannot fix (the shattered triple)", {
  # The three-char latin-1 mis-decode of U+FFFD is unrepairable -> both cells
  # still carry a marker.
  expect_identical(probe(triple_cells), 2L)
})

# ---- .st_read_grid_with_encoding_fallback ------------------------------------

test_that("(a) a bad-default read is rescued by the strictly-cleaner alternate", {
  calls <- character(0)
  primary_mat <- matrix(triple_cells, ncol = 1) # latin-1 read: shattered, probe 2
  alt_mat     <- matrix(utf8_cells, ncol = 1)   # UTF-8 read: single U+FFFD, probe 0
  read_fn <- function(enc) {
    calls <<- c(calls, enc)
    if (identical(enc, "latin1")) primary_mat else alt_mat
  }

  expect_message(
    result <- fallback(read_fn, "latin1", "UTF-8", function(m) as.vector(m), "ES9999999_0_XTAB.csv"),
    "UTF-8"
  )
  expect_identical(result, alt_mat)      # adopted the cleaner alternate
  expect_true("UTF-8" %in% calls)        # the alternate WAS read
})

test_that("(b) a clean primary read is returned immediately and NEVER re-read", {
  calls <- character(0)
  clean_mat <- matrix(utf8_cells, ncol = 1) # probe 0
  read_fn <- function(enc) {
    calls <<- c(calls, enc)
    clean_mat
  }

  result <- fallback(read_fn, "latin1", "UTF-8", function(m) as.vector(m), "clean.csv")
  expect_identical(result, clean_mat)
  expect_identical(calls, "latin1")       # exactly one read, primary only
})

test_that("(c) irrecoverable: alternate no cleaner keeps the primary (no swap, no message)", {
  primary_mat <- matrix(triple_cells, ncol = 1) # probe 2
  alt_mat     <- matrix(triple_cells, ncol = 1) # also probe 2 -> not strictly better
  read_fn <- function(enc) if (identical(enc, "latin1")) primary_mat else alt_mat

  expect_no_message(
    result <- fallback(read_fn, "latin1", "UTF-8", function(m) as.vector(m), "stuck.csv")
  )
  expect_identical(result, primary_mat)
})

test_that("(c) irrecoverable: a different row count keeps the primary even if the alternate is cleaner", {
  primary_mat <- matrix(triple_cells, ncol = 1)        # nrow 2, probe 2
  alt_mat     <- matrix(utf8_cells[1], ncol = 1)       # nrow 1, probe 0 but WRONG shape
  read_fn <- function(enc) if (identical(enc, "latin1")) primary_mat else alt_mat

  expect_no_message(
    result <- fallback(read_fn, "latin1", "UTF-8", function(m) as.vector(m), "wrongshape.csv")
  )
  expect_identical(result, primary_mat)
})

test_that("(c) irrecoverable: an error on the alternate read is swallowed, primary kept", {
  primary_mat <- matrix(triple_cells, ncol = 1)
  read_fn <- function(enc) {
    if (identical(enc, "latin1")) return(primary_mat)
    stop("boom")
  }
  expect_no_message(
    result <- fallback(read_fn, "latin1", "UTF-8", function(m) as.vector(m), "boom.csv")
  )
  expect_identical(result, primary_mat)
})
