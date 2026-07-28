# Plan 02 - R-2.3 parse_value(value_raw): vectorised successor to
# cleanBDLvalues(). Returns a tibble with columns value_num (dbl),
# value_chr (chr), quantified (lgl), rl_low (dbl), rl_high (dbl),
# skip_reason (chr, NA unless skipped).

# The pinned table from PLAN-02-primitives.md R-2.3, encoded row-by-row.
cases <- tibble::tribble(
  ~input,             ~value_num, ~quantified, ~rl_low,  ~rl_high, ~value_chr,        ~skip_reason,
  "2.3",               2.3,        TRUE,        NA_real_, NA_real_, NA_character_,     NA_character_,
  "<0.01",             0.01,       FALSE,       0.01,     NA_real_, NA_character_,     NA_character_,
  ">2000",             2000,       FALSE,       NA_real_, 2000,     NA_character_,     NA_character_,
  "BDL",               NA_real_,   FALSE,       NA_real_, NA_real_, NA_character_,     NA_character_,
  "NS",                NA_real_,   NA,          NA_real_, NA_real_, NA_character_,     "no_sample",
  "----",              NA_real_,   NA,          NA_real_, NA_real_, NA_character_,     "not_computable",
  # quantified NA, not TRUE, for text: changed 2026-07-23 (Robin) - see
  # PLAN-CHANGE-REQUESTS.md. A qualitative observation is not a measurement,
  # so no detection state is true of it.
  "Clear, low flow",   NA_real_,   NA,          NA_real_, NA_real_, "Clear, low flow", NA_character_,
  "",                  NA_real_,   NA,          NA_real_, NA_real_, NA_character_,     "empty"
)

for (i in seq_len(nrow(cases))) {
  row <- cases[i, ]
  test_that(sprintf("R-2.3: parse_value() table row %d: %s", i, encodeString(row$input)), {
    result <- parse_value(row$input)
    expect_equal(result$value_num[[1]], row$value_num[[1]])
    expect_equal(result$quantified[[1]], row$quantified[[1]])
    expect_equal(result$rl_low[[1]], row$rl_low[[1]])
    expect_equal(result$rl_high[[1]], row$rl_high[[1]])
    expect_equal(result$value_chr[[1]], row$value_chr[[1]])
    expect_equal(result$skip_reason[[1]], row$skip_reason[[1]])
  })
}

test_that("R-2.3: NA input behaves like empty input (skip_reason = 'empty')", {
  result <- parse_value(NA_character_)
  expect_true(is.na(result$value_num[[1]]))
  expect_equal(result$skip_reason[[1]], "empty")
})

test_that("R-2.3: numeric strings with thousands commas parse correctly ('1,320' -> 1320)", {
  result <- parse_value("1,320")
  expect_equal(result$value_num[[1]], 1320)
  expect_true(result$quantified[[1]])
})

test_that("R-2.3: whitespace around a value is tolerated", {
  result <- parse_value("  2.3  ")
  expect_equal(result$value_num[[1]], 2.3)
  expect_true(result$quantified[[1]])
})

test_that("R-2.3: whitespace around a below-detection value is tolerated", {
  result <- parse_value(" <0.01 ")
  expect_equal(result$value_num[[1]], 0.01)
  expect_false(result$quantified[[1]])
  expect_equal(result$rl_low[[1]], 0.01)
})

test_that("R-2.3: parse_value() is vectorised and returns one row per input, in order", {
  result <- parse_value(c("2.3", "<0.01", "NS"))
  expect_equal(nrow(result), 3)
  expect_equal(result$value_num, c(2.3, 0.01, NA_real_))
  expect_equal(result$skip_reason, c(NA_character_, NA_character_, "no_sample"))
})

# ---- quantified is a tri-state, and NA is meaningful ------------------------
# Ruled by Robin 2026-07-23: `quantified` describes a MEASUREMENT. A qualitative
# observation is not one, so it must be NA - neither TRUE nor FALSE. TRUE is the
# dangerous error: in the live registry 23 of the 315 text rows record that no
# sample was taken ("Could not find due to long grass"), and marking those
# quantified asserts an observation that never happened.

test_that("R-2.3: a text result is quantified = NA, not TRUE", {
  for (txt in c("Cloudy", "Dry", "Low flow Clear", "Non Discharge",
                "Could not find due to long grass", "Decomissioned")) {
    result <- parse_value(txt)
    expect_true(is.na(result$quantified[[1]]),
                info = paste("text result should be NA-quantified:", txt))
    expect_equal(result$value_chr[[1]], txt)
    expect_true(is.na(result$value_num[[1]]))
  }
})

test_that("R-2.3: among COMMITTED rows, quantified IS NA iff value_chr IS NOT NA", {
  # Scope matters: skipped inputs ("NS", "----", "") are NA on BOTH columns and
  # never reach the database, so the equivalence is asserted over the rows that
  # actually get committed. Skips are included here to prove they are excluded
  # by skip_reason and not by luck.
  inputs <- c("2.3", "<0.01", ">2000", "BDL", "1,320", "  2.3  ",
              "Cloudy", "Dry", "Clear, low flow", "Non Discharge",
              "NS", "----", "")
  result <- parse_value(inputs)
  kept <- result[is.na(result$skip_reason), ]

  expect_identical(is.na(kept$quantified), !is.na(kept$value_chr))

  # Not vacuous: both sides of the equivalence must be exercised, and the
  # skipped rows must really have been removed.
  expect_gt(sum(is.na(kept$quantified)), 0)
  expect_gt(sum(!is.na(kept$quantified)), 0)
  expect_equal(nrow(kept), length(inputs) - 3L)
})

test_that("R-2.3: a numeric result is still quantified = TRUE (no over-correction)", {
  result <- parse_value(c("2.3", "1,320", "0"))
  expect_true(all(result$quantified))
  expect_true(all(is.na(result$value_chr)))
})

# ---- F15: a below/above-detection marker whose remaining text does not -----
# parse to a finite number is refused, not committed as a below/above row
# with a fabricated or missing reporting limit.

test_that("F15: '<0.01 mg/L' (embedded unit) is refused, not committed as below-detection", {
  result <- parse_value("<0.01 mg/L")
  expect_true(is.na(result$value_num[[1]]))
  expect_true(is.na(result$rl_low[[1]]))
  expect_true(is.na(result$quantified[[1]]))
  expect_true(is.na(result$value_chr[[1]]))
  expect_true(is.na(result$skip_reason[[1]]))
  expect_equal(result$parse_error[[1]], "unparseable_limit_value")
})

test_that("F15: '>2000 ug/L' (embedded unit, above-detection) is refused the same way", {
  result <- parse_value(">2000 ug/L")
  expect_true(is.na(result$value_num[[1]]))
  expect_true(is.na(result$rl_high[[1]]))
  expect_equal(result$parse_error[[1]], "unparseable_limit_value")
})

test_that("F15: a bare '<' or '>' with nothing after it is refused, not a phantom zero-RL row", {
  for (marker in c("<", ">")) {
    result <- parse_value(marker)
    expect_true(is.na(result$value_num[[1]]), info = marker)
    expect_true(is.na(result$rl_low[[1]]), info = marker)
    expect_true(is.na(result$rl_high[[1]]), info = marker)
    expect_equal(result$parse_error[[1]], "unparseable_limit_value", info = marker)
  }
})

test_that("F15: a valid below-detection marker is unaffected by the refusal path", {
  result <- parse_value(c("<0.01", ">2000", "  <  0.01  "))
  expect_equal(result$value_num, c(0.01, 2000, 0.01))
  # expect_identical (not all(is.na(...))): a missing `parse_error` column
  # would make `result$parse_error` NULL, and all(is.na(NULL)) is vacuously
  # TRUE - that would let this assertion pass even without the column.
  expect_identical(result$parse_error, rep(NA_character_, 3))
})

# ---- F16: a comma whose thousands-vs-decimal reading is genuinely ---------
# ambiguous is refused, not guessed at as one convention or the other.

test_that("F16: '1,5' and '0,5' (too few digits to be a thousands group) are refused", {
  result <- parse_value(c("1,5", "0,5"))
  expect_true(all(is.na(result$value_num)))
  expect_true(all(is.na(result$quantified)))
  expect_equal(result$parse_error, rep("ambiguous_number_format", 2))
})

test_that("F16: '2,5,7' and '1,23,456' (non-3-digit groups) are refused, not mis-grouped", {
  result <- parse_value(c("2,5,7", "1,23,456"))
  expect_true(all(is.na(result$value_num)))
  expect_equal(result$parse_error, rep("ambiguous_number_format", 2))
})

test_that("F16: an unambiguous thousands separator ('1,234', '1,234,567') still parses", {
  result <- parse_value(c("1,234", "1,234,567"))
  expect_equal(result$value_num, c(1234, 1234567))
  expect_true(all(result$quantified))
  expect_identical(result$parse_error, rep(NA_character_, 2))
})

test_that("F16: a comma inside genuine free text is not mistaken for an ambiguous number", {
  result <- parse_value("Clear, low flow")
  expect_true(is.na(result$parse_error[[1]]))
  expect_equal(result$value_chr[[1]], "Clear, low flow")
})

test_that("F16: an ambiguous comma inside a below-detection marker is refused too", {
  result <- parse_value("<1,5")
  expect_true(is.na(result$value_num[[1]]))
  expect_equal(result$parse_error[[1]], "ambiguous_number_format")
})

# ---- sweep: other shapes an input can fail to parse in ---------------------

test_that("sweep: a Unicode minus sign (U+2212) parses as an ordinary negative number", {
  result <- parse_value("−0.5")
  expect_equal(result$value_num[[1]], -0.5)
  expect_true(result$quantified[[1]])
  expect_true(is.na(result$parse_error[[1]]))
})

test_that("sweep: a non-breaking space around a number does not block parsing", {
  result <- parse_value("12.5 ")
  expect_equal(result$value_num[[1]], 12.5)
  expect_true(result$quantified[[1]])
})

test_that("sweep: a hex-looking string ('0x10') is kept as free text, not silently read as 16", {
  result <- parse_value("0x10")
  expect_true(is.na(result$value_num[[1]]))
  expect_equal(result$value_chr[[1]], "0x10")
  expect_true(is.na(result$parse_error[[1]]))
})

test_that("sweep: the literal string 'Inf' is kept as free text, not committed as Inf", {
  result <- parse_value("Inf")
  expect_true(is.na(result$value_num[[1]]))
  expect_false(is.infinite(result$value_num[[1]]))
  expect_equal(result$value_chr[[1]], "Inf")
})

test_that("sweep: a plain value with an embedded unit ('0.5 ug/L') is kept as free text, not guessed", {
  result <- parse_value("0.5 ug/L")
  expect_true(is.na(result$value_num[[1]]))
  expect_equal(result$value_chr[[1]], "0.5 ug/L")
})

# ---- F15, end-to-end: the real ingest path, not just parse_value() ---------
# The unit-level refusal above was always visible; what made F15 dangerous
# was that it stayed silent all the way through commit. Reproduces the
# crosstab dialect verbatim, with one cell's value rewritten to carry an
# embedded unit on a below-detection marker.

test_that("F15 end-to-end: '<0.01 mg/L' through ingest_dir() opens a review item, commits no bogus row", {
  env <- parent.frame()
  root <- withr::local_tempdir(.local_envir = env)
  db_path <- seed_db(dir = root)
  con <- seed_con(db_path)
  ensure_test_asset_table(con)
  DBI::dbDisconnect(con, shutdown = TRUE)

  archive_dir <- withr::local_tempdir(.local_envir = env)
  snapshot_dir <- withr::local_tempdir(.local_envir = env)
  withr::local_options(list(
    "sampletidy.archive_dir" = archive_dir,
    "sampletidy.snapshot_dir" = snapshot_dir,
    "sampletidy.remove_ingested" = FALSE
  ), .local_envir = env)

  input_dir <- withr::local_tempdir(.local_envir = env)
  src <- test_path("fixtures", "crosstab", "XX1234567_0_XTAB.csv")
  lines <- readLines(src, warn = FALSE)
  # Line 10 is the WATER-section pH row; rewrite its 2nd sample value to a
  # below-detection marker with an embedded (and, incidentally, wrong-for-pH)
  # unit - exactly the shape a real lab cell can carry.
  expect_match(lines[[10]], "^pH Value,")
  lines[[10]] <- "pH Value,,pH Unit,0.01,,<0.01 mg/L,6.90"
  writeLines(lines[1:10], file.path(input_dir, "XX1234567_0_XTAB.csv"))

  suppressMessages(ingest_dir(input_dir, db = db_path))

  con <- DBI::dbConnect(duckdb::duckdb(), db_path, read_only = TRUE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  review <- DBI::dbGetQuery(
    con, "SELECT kind, subkind, payload FROM review_queue WHERE kind = 'parse_error'"
  )
  expect_equal(nrow(review), 1L)
  expect_equal(review$subkind[[1]], "value")
  expect_match(review$payload[[1]], "unparseable_limit_value", fixed = TRUE)
  expect_match(review$payload[[1]], "<0.01 mg/L", fixed = TRUE)

  # The bogus reading must not have been committed as an analysis row at all
  # - not as a below-detection row with a fabricated/missing RL, not as any
  # other guess.
  bogus <- DBI::dbGetQuery(
    con, "SELECT * FROM analysis WHERE value IS NULL AND rl_low IS NOT NULL"
  )
  expect_equal(nrow(bogus), 0L)
})
