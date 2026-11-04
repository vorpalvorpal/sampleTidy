# .st_esdat_read_csv(): extra trailing fields that are empty on every affected
# row must not trigger vroom's parsing-issues warning; any other problem must.

sample_hdr <- function() paste(sampleTidy:::.st_esdat_sample_header, collapse = ",")
chem_hdr <- function() paste(sampleTidy:::.st_esdat_chem_header, collapse = ",")

# Build a data row of `n` fields (f1..fn), optionally with a suffix string.
row_n <- function(n, tag, suffix = "") {
  paste0(paste0(tag, "_", seq_len(n), collapse = ","), suffix)
}

write_csv_fixture <- function(lines, name, env = parent.frame()) {
  p <- withr::local_tempfile(fileext = name, .local_envir = env)
  writeLines(lines, p)
  p
}

read_it <- function(p) sampleTidy:::.st_esdat_read_csv(p, basename(p))

test_that("clean Sample2e file reads silently and intact", {
  p <- write_csv_fixture(
    c(sample_hdr(), row_n(15, "a"), row_n(15, "b")), ".Sample2e.CSV"
  )
  expect_no_warning(df <- read_it(p))
  expect_identical(names(df), sampleTidy:::.st_esdat_sample_header)
  expect_equal(nrow(df), 2L)
  expect_identical(df[[1]], c("a_1", "b_1"))
  expect_identical(df[[15]], c("a_15", "b_15"))
})

test_that("Sample2e rows with one trailing empty field read silently", {
  p <- write_csv_fixture(
    c(sample_hdr(), row_n(15, "a", ","), row_n(15, "b", ","), row_n(15, "c")),
    ".Sample2e.CSV"
  )
  expect_no_warning(df <- read_it(p))
  expect_identical(names(df), sampleTidy:::.st_esdat_sample_header)
  expect_equal(nrow(df), 3L)
  expect_identical(df[[1]], c("a_1", "b_1", "c_1"))
  expect_identical(df[[15]], c("a_15", "b_15", "c_15"))
})

test_that("all rows with trailing comma, and multiple empty trailing fields", {
  p <- write_csv_fixture(
    c(sample_hdr(), row_n(15, "a", ",,"), row_n(15, "b", ",")),
    ".Sample2e.CSV"
  )
  expect_no_warning(df <- read_it(p))
  expect_equal(ncol(df), 15L)
  expect_equal(nrow(df), 2L)
  expect_identical(df[[15]], c("a_15", "b_15"))
})

test_that("Chemistry2e rows with trailing empty field read silently", {
  p <- write_csv_fixture(
    c(chem_hdr(), row_n(18, "a", ","), row_n(18, "b")), ".Chemistry2e.CSV"
  )
  expect_no_warning(df <- read_it(p))
  expect_identical(names(df), sampleTidy:::.st_esdat_chem_header)
  expect_equal(nrow(df), 2L)
  expect_identical(df[[18]], c("a_18", "b_18"))
})

test_that("extra field WITH content still warns", {
  p <- write_csv_fixture(
    c(sample_hdr(), row_n(15, "a", ",extra"), row_n(15, "b")), ".Sample2e.CSV"
  )
  expect_warning(read_it(p))
})

test_that("extra field with content still warns on Chemistry2e", {
  p <- write_csv_fixture(
    c(chem_hdr(), row_n(18, "a", ",extra"), row_n(18, "b")), ".Chemistry2e.CSV"
  )
  expect_warning(read_it(p))
})

test_that("row with too few columns still warns", {
  p <- write_csv_fixture(
    c(sample_hdr(), row_n(15, "a"), row_n(12, "b")), ".Sample2e.CSV"
  )
  expect_warning(read_it(p))
})

test_that("too few columns still warns on Chemistry2e", {
  p <- write_csv_fixture(
    c(chem_hdr(), row_n(18, "a"), row_n(14, "b")), ".Chemistry2e.CSV"
  )
  expect_warning(read_it(p))
})

test_that("mix of trailing-empty and content-extra rows still warns", {
  p <- write_csv_fixture(
    c(sample_hdr(), row_n(15, "a", ","), row_n(15, "b", ",extra"),
      row_n(15, "c")),
    ".Sample2e.CSV"
  )
  expect_warning(read_it(p))
})

test_that("mix of trailing-empty and too-few-columns rows still warns", {
  p <- write_csv_fixture(
    c(sample_hdr(), row_n(15, "a", ","), row_n(12, "b")), ".Sample2e.CSV"
  )
  expect_warning(read_it(p))
})
