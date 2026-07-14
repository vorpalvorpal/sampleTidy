# Plan 03 - R-3.2 file_meta(path): path, filename, ext, size, hash,
# sheet_names, peek, work_order_guess, revision_guess.

test_that("R-3.2: clean filename yields the correct work order and revision guesses", {
  dir <- withr::local_tempdir()
  path <- st_test_write_file(dir, "ES2600194_0_XTAB.csv", content = "a,b\n1,2\n")
  fm <- file_meta(path)
  expect_equal(fm$work_order_guess, "ES2600194")
  expect_equal(fm$revision_guess, 0)
})

test_that("R-3.2: a junk prefix before the work order does not throw off the guess", {
  dir <- withr::local_tempdir()
  path <- st_test_write_file(dir, "1.ES2600185_0_XTAB.csv", content = "a,b\n1,2\n")
  fm <- file_meta(path)
  expect_equal(fm$work_order_guess, "ES2600185")
  expect_equal(fm$revision_guess, 0)
})

test_that("R-3.2: an ESdat-style dotted-prefix filename parses work order and revision", {
  dir <- withr::local_tempdir()
  path <- st_test_write_file(dir, "BWMF x.ESDAT_ES2515460_0.Sample2e.CSV", content = "a,b\n1,2\n")
  fm <- file_meta(path)
  expect_equal(fm$work_order_guess, "ES2515460")
  expect_equal(fm$revision_guess, 0)
})

test_that("R-3.2: a filename with no matching work-order pattern yields NA", {
  dir <- withr::local_tempdir()
  path <- st_test_write_file(dir, "2400-7539-05 May 2026 Monthly Katoomba WMF.xls", raw = charToRaw("not a real xls"))
  fm <- file_meta(path)
  expect_true(is.na(fm$work_order_guess))
})

test_that("R-3.2: revision_guess anchors immediately after the work order (A12) - 'ES2131134_COC_1.pdf' yields NA, not 1", {
  dir <- withr::local_tempdir()
  path <- st_test_write_file(dir, "ES2131134_COC_1.pdf", raw = as.raw(c(0x25, 0x50, 0x44, 0x46)))
  fm <- file_meta(path)
  expect_equal(fm$work_order_guess, "ES2131134")
  expect_true(is.na(fm$revision_guess))
})

test_that("R-3.2: ext is lower-cased with no leading dot", {
  dir <- withr::local_tempdir()
  path <- st_test_write_file(dir, "Test.CSV", content = "a,b\n1,2\n")
  fm <- file_meta(path)
  expect_equal(fm$ext, "csv")
})

test_that("R-3.2: size and hash match the underlying file (hash reuses R-1.2 hash_file())", {
  dir <- withr::local_tempdir()
  path <- st_test_write_file(dir, "sized.csv", content = "abcdef")
  fm <- file_meta(path)
  expect_equal(fm$size, file.size(path))
  expect_equal(fm$hash, hash_file(path))
})

test_that("R-3.2: sheet_names is populated for a real xlsx via readxl::excel_sheets()", {
  dir <- withr::local_tempdir()
  path <- file.path(dir, "real.xlsx")
  openxlsx::write.xlsx(list(Sheet1 = data.frame(a = 1), FrontPage = data.frame(b = 2)), path)
  fm <- file_meta(path)
  expect_setequal(fm$sheet_names, c("Sheet1", "FrontPage"))
})

test_that("R-3.2: sheet_names is NULL for a non-spreadsheet file", {
  dir <- withr::local_tempdir()
  path <- st_test_write_file(dir, "plain.csv", content = "a,b\n1,2\n")
  fm <- file_meta(path)
  expect_null(fm$sheet_names)
})

test_that("R-3.2: an .xls without readxl-readable sheets yields NULL sheet_names and does not error", {
  dir <- withr::local_tempdir()
  path <- st_test_write_file(dir, "bad.xls", content = "this is not a real spreadsheet")
  fm <- NULL
  expect_no_error(fm <- file_meta(path))
  expect_null(fm$sheet_names)
})

test_that("R-3.2: peek does not error on a binary (PDF-like) file and returns decoded text", {
  dir <- withr::local_tempdir()
  raw_bytes <- as.raw(c(0x25, 0x50, 0x44, 0x46, 0x00, 0xFF, 0xC2, 0x10, 0x80, 0x81))
  path <- st_test_write_file(dir, "scan.pdf", raw = raw_bytes)
  fm <- NULL
  expect_no_error(fm <- file_meta(path))
  expect_type(fm$peek, "character")
})
