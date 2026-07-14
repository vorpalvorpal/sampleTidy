# Plan 01 - R-1.2 hash_file(): SHA-256 of file contents (A5).

test_that("R-1.2: known 3-byte fixture file hashes to its precomputed digest", {
  dir <- withr::local_tempdir()
  path <- st_test_write_file(dir, "foo.txt", raw = charToRaw("foo"))
  # sha256("foo") - verified independently via digest::digest(algo = "sha256")
  # before being baked into this assertion.
  expect_identical(
    hash_file(path),
    "2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae"
  )
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
