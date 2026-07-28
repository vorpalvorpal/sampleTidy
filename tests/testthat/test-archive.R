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
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  src_dir <- withr::local_tempdir()
  src_path <- file.path(src_dir, "PROJ_A.ESDAT_XX1234567_0.Chemistry2e.CSV")
  writeBin(charToRaw("SampleCode,ChemCode\nXX1234567001,16984-48-8\n"), src_path)
  hash <- hash_file(src_path)

  archive_file(con, src_path, hash, event = list(work_order = "XX1234567"))

  asset_row <- DBI::dbGetQuery(con, sprintf("SELECT * FROM asset WHERE hash = '%s'", hash))
  expect_equal(nrow(asset_row), 1)
  copy_path <- file.path(setup$archive_dir, asset_row$uuid[[1]], asset_row$filename[[1]])
  expect_true(file.exists(copy_path))
  expect_identical(readBin(copy_path, "raw", file.size(copy_path)),
                    readBin(src_path, "raw", file.size(src_path)))
})

test_that("R-9.3: the asset row fields are correct", {
  setup <- archive_test_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

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
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

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
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

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
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

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
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

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
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

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
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

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

# ---- Phase-7b round-2 item 6: archive_file() takes an explicit `type` -------

test_that("Phase-7b round-2 item 6: archive_file()'s `type` argument controls the newly-inserted asset row's type, defaulting to 'Chemical analysis' when omitted (unchanged behaviour for every pre-existing caller)", {
  setup <- archive_test_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  src_dir <- withr::local_tempdir()

  default_path <- file.path(src_dir, "PROJ_A.ESDAT_XX1234567_0.Chemistry2e.CSV")
  writeLines("default type content", default_path)
  default_hash <- hash_file(default_path)
  archive_file(con, default_path, default_hash, event = list(work_order = "XX1234567"))
  default_row <- DBI::dbGetQuery(con, "SELECT type FROM asset WHERE hash = ?", params = list(default_hash))
  expect_identical(default_row$type[[1]], "Chemical analysis")

  coa_path <- file.path(src_dir, "XX1234567_0_COA.pdf")
  writeLines("coa content", coa_path)
  coa_hash <- hash_file(coa_path)
  archive_file(con, coa_path, coa_hash, event = list(work_order = "XX1234567"),
               type = "Certificate of analysis")
  coa_row <- DBI::dbGetQuery(con, "SELECT type FROM asset WHERE hash = ?", params = list(coa_hash))
  expect_identical(coa_row$type[[1]], "Certificate of analysis")

  # The dedup-reuse path (same hash, second call) never overwrites an
  # existing row's type, even if a DIFFERENT `type` is passed the second time.
  archive_file(con, coa_path, coa_hash, event = list(work_order = "XX1234567"),
               type = "Chemical analysis")
  coa_row_after <- DBI::dbGetQuery(con, "SELECT type FROM asset WHERE hash = ?", params = list(coa_hash))
  expect_identical(coa_row_after$type[[1]], "Certificate of analysis")
})

# ---- orphan (NA work_order) project find-or-create (Phase-8b) --------------
#
# `name = ?` bound to `NA` compiles to `name = NULL`, which SQL's
# three-valued logic never satisfies for any row - a plain lookup keyed off
# `event$work_order` never finds the shared anonymous project row an orphan
# (no work order recorded) event resolves to, so the archived asset silently
# lost its project link (`uuid_project = NA`) even though a matching project
# row exists (`.ct_ensure_project()`, R/commit.R, find-or-creates it).

test_that("archive_file(): an orphan event's asset gets the shared anonymous project's uuid, not NA", {
  setup <- archive_test_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  null_name_count <- function() {
    DBI::dbGetQuery(con, "SELECT count(*) AS n FROM project WHERE name IS NULL")$n
  }
  expect_equal(null_name_count(), 0)

  src_dir <- withr::local_tempdir()
  src_path <- file.path(src_dir, "2400-75301-01_ACIRL_Field.CSV")
  writeLines("orphan field sheet", src_path)
  hash <- hash_file(src_path)

  archive_file(con, src_path, hash, event = list(work_order = NA_character_))

  asset_row <- DBI::dbGetQuery(con, "SELECT uuid_project FROM asset WHERE hash = ?", params = list(hash))
  expect_equal(nrow(asset_row), 1)
  expect_false(is.na(asset_row$uuid_project[[1]]))

  anon_project <- DBI::dbGetQuery(
    con, "SELECT uuid FROM project WHERE name IS NULL AND type = 'Work order'"
  )
  expect_equal(nrow(anon_project), 1)
  expect_identical(asset_row$uuid_project[[1]], anon_project$uuid[[1]])
})

test_that("archive_file(): two DIFFERENT orphan events' assets share ONE anonymous project row, not one each", {
  setup <- archive_test_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  null_name_count <- function() {
    DBI::dbGetQuery(con, "SELECT count(*) AS n FROM project WHERE name IS NULL")$n
  }
  expect_equal(null_name_count(), 0)

  src_dir <- withr::local_tempdir()
  path1 <- file.path(src_dir, "2400-75301-01_ACIRL_Field.CSV")
  writeLines("orphan field sheet 1", path1)
  hash1 <- hash_file(path1)
  path2 <- file.path(src_dir, "2400-75302-01_ACIRL_Field.CSV")
  writeLines("orphan field sheet 2", path2)
  hash2 <- hash_file(path2)

  archive_file(con, path1, hash1, event = list(work_order = NA_character_))
  archive_file(con, path2, hash2, event = list(work_order = NA_character_))

  # Pre-fix: this was 2 - a fresh NULL-name "Work order" project row per
  # orphan archive_file() call, growing without bound and never collapsing.
  expect_equal(null_name_count(), 1)

  assets <- DBI::dbGetQuery(
    con, "SELECT DISTINCT uuid_project FROM asset WHERE hash IN (?, ?)",
    params = list(hash1, hash2)
  )
  expect_equal(nrow(assets), 1)
  expect_false(is.na(assets$uuid_project[[1]]))
})
