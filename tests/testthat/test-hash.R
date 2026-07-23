# Plan 01 - R-1.2 hash_file(): xxHash128 of file contents (A5).
# Algorithm changed 2026-07-23 (SHA-256 -> xxHash128) to match the 2,407
# legacy asset rows written by the pre-package system. See PLAN-CHANGE-REQUESTS.

test_that("R-1.2: known 3-byte fixture file hashes to its precomputed digest", {
  dir <- withr::local_tempdir()
  path <- st_test_write_file(dir, "foo.txt", raw = charToRaw("foo"))
  # xxHash128("foo") - verified independently via rlang::hash_file() on a
  # 3-byte file before being baked into this assertion.
  expect_identical(hash_file(path), "79aef92e83454121ab6e5f64077e7d8a")
  # width is part of the contract: 32 hex chars, not 64
  expect_equal(nchar(hash_file(path)), 32L)
})

test_that("R-1.2: two files with identical bytes but different names/mtimes hash equal", {
  dir <- withr::local_tempdir()
  path_a <- st_test_write_file(dir, "a_name.csv", raw = charToRaw("identical content"))
  Sys.sleep(1.1) # ensure a distinguishable mtime
  path_b <- st_test_write_file(dir, "totally_different_name.csv", raw = charToRaw("identical content"))
  expect_false(file.mtime(path_a) == file.mtime(path_b))
  expect_identical(hash_file(path_a), hash_file(path_b))
})

test_that("R-1.2: missing file aborts with class sampletidy_error", {
  dir <- withr::local_tempdir()
  missing_path <- file.path(dir, "does-not-exist.csv")
  err <- tryCatch(hash_file(missing_path), error = function(e) e)
  expect_s3_class(err, "sampletidy_error")
})
