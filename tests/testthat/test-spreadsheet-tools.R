# Plan 02 - R-2.5 spreadsheet tools: str_which_df() and vector_from_key(),
# ported (generalised) from WEM.data/R/new/import/read_ACIRL_front_page.R.

grid <- st_test_grid(
  c("REPORT NO:", "2400-9999-01", NA),
  c("SAMPLED BY:", "J. Tester & offsider", NA),
  c("Units", "pH Units", "uS/cm"),
  c("Site Name", "T.S01", "T.S02")
)

# --- str_which_df ----------------------------------------------------------

test_that("R-2.5: str_which_df() finds the exact cell for a single match", {
  hit <- str_which_df(grid, "^Units$")
  expect_equal(nrow(hit), 1)
  expect_equal(hit$row[[1]], 3)
  expect_equal(hit$col[[1]], 1)
})

test_that("R-2.5: str_which_df() with multiple_matches = FALSE (default) aborts on two hits", {
  dup_grid <- st_test_grid(
    c("DUPLICATE", "x"),
    c("y", "DUPLICATE")
  )
  err <- tryCatch(str_which_df(dup_grid, "^DUPLICATE$", multiple_matches = FALSE), error = function(e) e)
  expect_s3_class(err, "sampletidy_error")
})

test_that("R-2.5: str_which_df() returns a zero-row tibble for zero hits", {
  hit <- str_which_df(grid, "^NOPE_NOT_PRESENT_ANYWHERE$")
  expect_equal(nrow(hit), 0)
})

# --- vector_from_key --------------------------------------------------------

test_that("R-2.5: vector_from_key() direction = 'right' returns the cell(s) to the key's right", {
  result <- vector_from_key(grid, "REPORT NO:", direction = "right", vector_length = 1)
  expect_equal(result, "2400-9999-01")
})

test_that("R-2.5: vector_from_key() direction = 'down' returns the cell(s) below the key", {
  result <- vector_from_key(grid, "^Units$", direction = "down", vector_length = 1)
  expect_equal(result, "Site Name")
})

test_that("R-2.5: vector_from_key() remove_na = TRUE drops NAs before length-checking", {
  # raw right-of-key vector is c("2400-9999-01", NA) - length 2; only after
  # dropping the NA does it satisfy vector_length = 1.
  result <- vector_from_key(grid, "REPORT NO:", direction = "right",
                             vector_length = 1, remove_na = TRUE)
  expect_equal(result, "2400-9999-01")
})

test_that("R-2.5: vector_from_key() remove_na = FALSE keeps NAs, matching the un-trimmed length", {
  result <- vector_from_key(grid, "REPORT NO:", direction = "right",
                             vector_length = 2, remove_na = FALSE)
  expect_equal(result, c("2400-9999-01", NA_character_))
})

test_that("R-2.5: vector_from_key() aborts when the extracted vector doesn't match vector_length", {
  err <- tryCatch(
    vector_from_key(grid, "REPORT NO:", direction = "right", vector_length = 5),
    error = function(e) e
  )
  expect_s3_class(err, "sampletidy_error")
})
