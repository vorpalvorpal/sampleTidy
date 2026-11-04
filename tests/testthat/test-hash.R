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
  path_b <- st_test_write_file(dir, "totally_different_name.csv", raw = charToRaw("identical content"))
  # ensure a distinguishable mtime (set, rather than slept for)
  Sys.setFileTime(path_a, Sys.time() - 3600)
  expect_false(file.mtime(path_a) == file.mtime(path_b))
  expect_identical(hash_file(path_a), hash_file(path_b))
})

test_that("R-1.2: missing file aborts with class sampletidy_error", {
  dir <- withr::local_tempdir()
  missing_path <- file.path(dir, "does-not-exist.csv")
  err <- tryCatch(hash_file(missing_path), error = function(e) e)
  expect_s3_class(err, "sampletidy_error")
})

# ---- unreadable file must not hash as empty (2026-10-26 incident) -----------
# A cloud-only OneDrive file reads as 0 bytes, so rlang::hash_file() returned the
# xxHash128 of empty input for every such file. rlang::hash_file is mocked here
# to simulate the unreadable read (local_mocked_bindings(.package = "rlang")).

st_empty_hash <- "99aa06d3014798d86001c324468d497f"

test_that("hash_file(): a genuinely empty file hashes to the empty hash without error", {
  dir <- withr::local_tempdir()
  path <- st_test_write_file(dir, "empty.csv", raw = raw(0))
  expect_identical(hash_file(path), st_empty_hash)
})

test_that("hash_file(): a non-empty file whose read yields the empty hash aborts with sampletidy_error", {
  dir <- withr::local_tempdir()
  path <- st_test_write_file(dir, "WO-TEST-001.csv", raw = charToRaw("a,b\n1,2\n"))
  testthat::local_mocked_bindings(
    hash_file = function(...) "99aa06d3014798d86001c324468d497f",
    .package = "rlang"
  )
  expect_error(hash_file(path), class = "sampletidy_error")
  expect_error(hash_file(path), "could not be read|read 0 bytes")
})
