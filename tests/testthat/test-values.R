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
