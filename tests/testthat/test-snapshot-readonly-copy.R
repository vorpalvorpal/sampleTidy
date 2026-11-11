# snapshot_db() copies the file through a READ-ONLY connection held during the
# copy, after the write connection is closed (Windows refuses to copy a file
# its own process holds open read-write). Seam: `file.copy` is mocked inside
# the sampleTidy namespace with testthat::local_mocked_bindings().

sr_sha <- function(p) digest::digest(file = p, algo = "sha256")

sr_write_extras <- function(db_path) {
  con <- DBI::dbConnect(duckdb::duckdb(), db_path, read_only = FALSE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbExecute(con, "CREATE SEQUENCE sr_seq START 100")
  DBI::dbExecute(con, "SELECT nextval('sr_seq')")
  DBI::dbExecute(con, "SELECT nextval('sr_seq')")
  DBI::dbExecute(con, "CREATE TABLE sr_t (id INTEGER, v VARCHAR)")
  DBI::dbExecute(con, "INSERT INTO sr_t VALUES (1, 'a'), (2, 'b'), (3, 'c')")
  DBI::dbExecute(con, "COMMENT ON TABLE sr_t IS 'snapshot comment survives'")
  invisible(NULL)
}

sr_catalog <- function(path) {
  con <- DBI::dbConnect(duckdb::duckdb(), path, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  list(
    tables = DBI::dbGetQuery(con, "SELECT table_name, column_name, data_type
                                   FROM information_schema.columns
                                   WHERE table_schema = 'main'
                                   ORDER BY table_name, ordinal_position"),
    db_meta = DBI::dbGetQuery(con, "SELECT * FROM db_meta ORDER BY 1"),
    schema_version = DBI::dbGetQuery(con, "SELECT * FROM schema_version ORDER BY 1")
  )
}

test_that("snapshot_db(): the snapshot is byte-identical to the source file", {
  db_path <- seed_db()
  dest_dir <- withr::local_tempdir()
  snap <- snapshot_db(db = db_path, dest_dir = dest_dir)
  # Computed after the call, with no connection open on either file.
  expect_identical(sr_sha(snap), sr_sha(db_path))
})

test_that("snapshot_db(): writes still in the WAL (rows, sequence value, comment) are in the snapshot", {
  db_path <- seed_db()
  dest_dir <- withr::local_tempdir()
  sr_write_extras(db_path)
  snap <- snapshot_db(db = db_path, dest_dir = dest_dir)

  con <- DBI::dbConnect(duckdb::duckdb(), snap, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  expect_equal(DBI::dbGetQuery(con, "SELECT count(*) AS n FROM sr_t")$n, 3)
  expect_equal(DBI::dbGetQuery(con, "SELECT last_value FROM duckdb_sequences()
                        WHERE sequence_name = 'sr_seq'")$last_value, 102)  # after two nextval() calls from 100, a reload reports the next value
  expect_identical(
    DBI::dbGetQuery(con, "SELECT comment FROM duckdb_tables() WHERE table_name = 'sr_t'")$comment,
    "snapshot comment survives")
})

test_that("snapshot_db(): leaves no connection open - a fresh read-write connect succeeds in-process", {
  db_path <- seed_db()
  dest_dir <- withr::local_tempdir()
  snapshot_db(db = db_path, dest_dir = dest_dir)
  con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), db_path, read_only = FALSE),
                  error = function(e) e)
  expect_false(inherits(con, "error"))
  if (!inherits(con, "error")) DBI::dbDisconnect(con, shutdown = TRUE)
})

test_that("snapshot_db(): the snapshot's catalog, db_meta and schema_version equal the source's", {
  db_path <- seed_db()
  dest_dir <- withr::local_tempdir()
  sr_write_extras(db_path)
  snap <- snapshot_db(db = db_path, dest_dir = dest_dir)
  expect_equal(sr_catalog(snap), sr_catalog(db_path))
})

test_that("snapshot_db(): a failed copy leaves no .tmp and raises the existing error", {
  db_path <- seed_db()
  dest_dir <- withr::local_tempdir()
  testthat::local_mocked_bindings(
    file.copy = function(from, to, overwrite = FALSE, ...) {
      file.create(to)  # what Windows leaves behind: a 0-byte tmp
      FALSE
    },
    .package = "base"
  )
  err <- tryCatch(snapshot_db(db = db_path, dest_dir = dest_dir), error = function(e) e)
  expect_s3_class(err, "sampletidy_error")
  expect_match(conditionMessage(err), "Failed to snapshot")
  expect_length(list.files(dest_dir, all.files = TRUE, no.. = TRUE), 0)
})

test_that("snapshot_db(): the copy runs while a READ-ONLY connection is held, not a read-write one", {
  db_path <- seed_db()
  dest_dir <- withr::local_tempdir()
  seen <- new.env()
  seen$called <- FALSE
  real_copy <- base::file.copy  # captured before the mock replaces it
  # duckdb shares one instance per path in-process, so a connection opened
  # during the copy sees the held instance's mode: probe it with a write.
  testthat::local_mocked_bindings(
    file.copy = function(from, to, overwrite = FALSE, ...) {
      seen$called <- TRUE
      pc <- DBI::dbConnect(duckdb::duckdb(), db_path, read_only = TRUE)
      seen$mode <- tryCatch({
        DBI::dbExecute(pc, "CREATE TABLE sr_probe (i INTEGER)")
        DBI::dbExecute(pc, "DROP TABLE sr_probe")
        "writable"
      }, error = function(e) "read-only")
      DBI::dbDisconnect(pc, shutdown = FALSE)
      real_copy(from, to, overwrite = overwrite, ...)
    },
    .package = "base"
  )
  snapshot_db(db = db_path, dest_dir = dest_dir)
  expect_true(seen$called)
  expect_identical(seen$mode, "read-only")
})
