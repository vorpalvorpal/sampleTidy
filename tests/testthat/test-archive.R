# Plan 09 - R/archive.R: `archive_file(con, path, hash, event)` (A1, A13).
#
# Copies a source file to `file.path(st_config("archive_dir"), <new asset
# uuid>)` (no extension), inserts the `asset` row, and skips the copy (reuse
# the uuid) when an asset with the same hash already exists.
#
# GAP: seed_db() doesn't create an `asset` table (see
# dev/plans/PLAN-CHANGE-REQUESTS.md) - `ensure_test_asset_table()` (from
# helper-corpus.R) adds it locally for these tests.
#
# `event` here is treated minimally as `list(work_order = ...)`, matching
# commit_event()'s own step 1 ("project: look up project by name =
# work_order") - archive_file() is assumed to resolve `uuid_project` the
# same way. FIXTURES.md's project p-0001 (name "XX1234567") is already
# seeded, so `event <- list(work_order = "XX1234567")` resolves to it.

archive_test_setup <- function() {
  # Bind every withr cleanup to the *calling test's* frame (parent.frame()),
  # not this helper's frame. A bare withr::local_*() / seed_db() here tears its
  # resource down the instant archive_test_setup() returns - the A38 bug, one
  # frame removed - so the archive_dir option would be unset before the test
  # body ever calls archive_file(). See CONTRACT A41.
  env <- parent.frame()
  db_path <- seed_db(dir = withr::local_tempdir(.local_envir = env))
  con <- seed_con(db_path)
  ensure_test_asset_table(con)
  archive_dir <- withr::local_tempdir(.local_envir = env)
  withr::local_options(list("sampletidy.archive_dir" = archive_dir), .local_envir = env)
  list(con = con, archive_dir = archive_dir)
}

test_that("R-9.3: the archive copy exists and is byte-identical to the source", {
  setup <- archive_test_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  src_dir <- withr::local_tempdir()
  src_path <- file.path(src_dir, "PROJ_A.ESDAT_XX1234567_0.Chemistry2e.CSV")
  writeBin(charToRaw("SampleCode,ChemCode\nXX1234567001,16984-48-8\n"), src_path)
  hash <- hash_file(src_path)

  archive_file(con, src_path, hash, event = list(work_order = "XX1234567"))

  asset_row <- DBI::dbGetQuery(con, sprintf("SELECT * FROM asset WHERE hash = '%s'", hash))
  expect_equal(nrow(asset_row), 1)
  copy_path <- file.path(setup$archive_dir, asset_row$uuid[[1]])
  expect_true(file.exists(copy_path))
  expect_identical(readBin(copy_path, "raw", file.size(copy_path)),
                    readBin(src_path, "raw", file.size(src_path)))
})

test_that("R-9.3: the asset row fields are correct", {
  setup <- archive_test_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  src_dir <- withr::local_tempdir()
  src_path <- file.path(src_dir, "PROJ_A.ESDAT_XX1234567_0.Chemistry2e.CSV")
  writeLines("dummy content", src_path)
  hash <- hash_file(src_path)

  archive_file(con, src_path, hash, event = list(work_order = "XX1234567"))

  asset_row <- DBI::dbGetQuery(con, sprintf("SELECT * FROM asset WHERE hash = '%s'", hash))
  expect_equal(nrow(asset_row), 1)
  expect_identical(asset_row$type, "Chemical analysis")
  expect_identical(asset_row$filename, "PROJ_A.ESDAT_XX1234567_0.Chemistry2e.CSV")
  expect_identical(asset_row$uuid_project, "p-0001")
  expect_identical(asset_row$hash, hash)
})

test_that("R-9.3: a second call with the same hash creates no second copy or row", {
  setup <- archive_test_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  src_dir <- withr::local_tempdir()
  src_path <- file.path(src_dir, "PROJ_A.ESDAT_XX1234567_0.Chemistry2e.CSV")
  writeLines("dummy content", src_path)
  hash <- hash_file(src_path)

  first <- archive_file(con, src_path, hash, event = list(work_order = "XX1234567"))
  second <- archive_file(con, src_path, hash, event = list(work_order = "XX1234567"))

  asset_rows <- DBI::dbGetQuery(con, sprintf("SELECT * FROM asset WHERE hash = '%s'", hash))
  expect_equal(nrow(asset_rows), 1)
  n_copies <- length(list.files(setup$archive_dir))
  expect_equal(n_copies, 1)
})

test_that("R-9.3: the source file is untouched by archiving", {
  setup <- archive_test_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  src_dir <- withr::local_tempdir()
  src_path <- file.path(src_dir, "PROJ_A.ESDAT_XX1234567_0.Chemistry2e.CSV")
  writeLines("dummy content", src_path)
  hash <- hash_file(src_path)

  archive_file(con, src_path, hash, event = list(work_order = "XX1234567"))
  expect_true(file.exists(src_path))
})

test_that("R-9.3: the archived asset is visible for ingest_file.uuid_asset to reference", {
  setup <- archive_test_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  src_dir <- withr::local_tempdir()
  src_path <- file.path(src_dir, "PROJ_A.ESDAT_XX1234567_0.Chemistry2e.CSV")
  writeLines("dummy content", src_path)
  hash <- hash_file(src_path)
  DBI::dbExecute(con, sprintf(
    "INSERT INTO ingest_file (hash, filename, path_first_seen, state, work_order, revision)
     VALUES ('%s', '%s', '%s', 'reconciled', 'XX1234567', 0)", hash, basename(src_path), src_path))

  archive_file(con, src_path, hash, event = list(work_order = "XX1234567"))
  asset_row <- DBI::dbGetQuery(con, sprintf("SELECT uuid FROM asset WHERE hash = '%s'", hash))

  DBI::dbExecute(con, sprintf(
    "UPDATE ingest_file SET uuid_asset = '%s' WHERE hash = '%s'", asset_row$uuid[[1]], hash))
  linked <- DBI::dbGetQuery(con, sprintf("SELECT uuid_asset FROM ingest_file WHERE hash = '%s'", hash))
  expect_identical(linked$uuid_asset, asset_row$uuid[[1]])
})

# ---- R-12.4 / R-12.17 (PLAN-12 F10/A70): checked file.copy() + directory
# layout. Both criteria touch the same file.copy() call in archive_file(), so
# their tests are grouped here per the plan's coordination note.

test_that("R-12.4: archive_file() into a non-existent archive_dir aborts sampletidy_error and writes no asset row", {
  setup <- archive_test_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # Point archive_dir at a path that is never created (no mkdir) - file.copy()
  # into it must fail, and that failure must be checked (R-12.4), not silently
  # ignored the way the pre-fix code does.
  missing_dir <- file.path(setup$archive_dir, "does-not-exist")
  withr::local_options(list("sampletidy.archive_dir" = missing_dir))

  src_dir <- withr::local_tempdir()
  src_path <- file.path(src_dir, "PROJ_A.ESDAT_XX1234567_0.Chemistry2e.CSV")
  writeLines("dummy content", src_path)
  hash <- hash_file(src_path)

  err <- tryCatch(
    archive_file(con, src_path, hash, event = list(work_order = "XX1234567")),
    error = function(e) e
  )
  expect_s3_class(err, "sampletidy_error")

  asset_row <- DBI::dbGetQuery(con, sprintf("SELECT * FROM asset WHERE hash = '%s'", hash))
  expect_equal(nrow(asset_row), 0)
})

test_that("R-12.17: archive_file() writes <archive_dir>/<uuid>/<original filename>, byte-identical to the source", {
  setup <- archive_test_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  src_dir <- withr::local_tempdir()
  src_path <- file.path(src_dir, "PROJ_A.ESDAT_XX1234567_0.Chemistry2e.CSV")
  writeBin(charToRaw("layout convention test content\n"), src_path)
  hash <- hash_file(src_path)

  archive_file(con, src_path, hash, event = list(work_order = "XX1234567"))

  asset_row <- DBI::dbGetQuery(con, sprintf("SELECT uuid FROM asset WHERE hash = '%s'", hash))
  expect_equal(nrow(asset_row), 1)
  uuid_dir <- file.path(setup$archive_dir, asset_row$uuid[[1]])
  copy_path <- file.path(uuid_dir, basename(src_path))

  expect_true(dir.exists(uuid_dir))
  expect_true(file.exists(copy_path))
  expect_identical(readBin(copy_path, "raw", file.size(copy_path)),
                    readBin(src_path, "raw", file.size(src_path)))
})

test_that("R-12.17: a pre-existing legacy extensionless <uuid> file in archive_dir is left untouched", {
  setup <- archive_test_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # A pre-existing (read-only-history) legacy artifact: one of the 33
  # extensionless files the real archive still has, per A70.
  legacy_uuid <- "legacy-0001"
  legacy_path <- file.path(setup$archive_dir, legacy_uuid)
  writeLines("legacy extensionless content", legacy_path)
  legacy_bytes_before <- readBin(legacy_path, "raw", file.size(legacy_path))

  src_dir <- withr::local_tempdir()
  src_path <- file.path(src_dir, "PROJ_A.ESDAT_XX1234567_0.Chemistry2e.CSV")
  writeLines("new content", src_path)
  hash <- hash_file(src_path)

  archive_file(con, src_path, hash, event = list(work_order = "XX1234567"))

  expect_true(file.exists(legacy_path))
  expect_false(dir.exists(legacy_path))
  expect_identical(readBin(legacy_path, "raw", file.size(legacy_path)), legacy_bytes_before)
})
