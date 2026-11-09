# PLAN-21 phase (a), section 1: the `db_meta` table (ops-schema migration 11)
# and its helpers db_meta_get() / db_meta_set() / db_meta_read().
#
#   db_meta (key VARCHAR PRIMARY KEY, value VARCHAR, updated_at TIMESTAMP)
#
# db_meta_get(con, key)        the value, or NA_character_ (no key / no table)
# db_meta_set(con, key, value) upsert; as.character(value); sets updated_at;
#                              ensure_schema() first if the table is absent;
#                              returns value invisibly; joins db_transaction()
# db_meta_read(db)             opens the FILE read-only; named character of
#                              every key; never creates a missing file
#
# The core knows the keys `writer_generation` and `writer_label` but never
# writes them: a deployment does. Synthetic databases only.

# ---- helpers -------------------------------------------------------------------------------

# A fresh database file with the ops schema. Returns the (closed) path.
dm_db <- function(env = parent.frame()) {
  path <- file.path(withr::local_tempdir(.local_envir = env), "meta.duckdb")
  con <- DBI::dbConnect(duckdb::duckdb(), path, read_only = FALSE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  ensure_schema(con)
  path
}

# A database file with one plain table and no ops schema (no db_meta).
dm_bare <- function(env = parent.frame()) {
  path <- file.path(withr::local_tempdir(.local_envir = env), "bare.duckdb")
  con <- DBI::dbConnect(duckdb::duckdb(), path, read_only = FALSE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbExecute(con, "CREATE TABLE t (x INTEGER)")
  path
}

# An open read-write connection, closed when the calling test ends.
dm_con <- function(path, read_only = FALSE, env = parent.frame()) {
  con <- DBI::dbConnect(duckdb::duckdb(), path, read_only = read_only)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE), envir = env)
  con
}

dm_tables <- function(con) DBI::dbListTables(con)

dm_rows <- function(con) {
  DBI::dbGetQuery(con, "SELECT key, value, updated_at FROM db_meta ORDER BY key")
}

# ---- the table: ops-schema migration 11 ---------------------------------------------------

test_that("migration 11 is the last rung of the ladder, and the core schema version is 11", {
  migrations <- get(".st_schema_migrations", envir = asNamespace("sampleTidy"))
  versions <- vapply(migrations, function(m) m$version, integer(1))
  expect_identical(versions[[length(versions)]], 11L)
  expect_identical(sum(versions == 11L), 1L)
  expect_identical(sampleTidy:::.dbc_core_version(), 11L)
})

test_that("ensure_schema() creates db_meta (key VARCHAR, value VARCHAR, updated_at TIMESTAMP), empty, and records version 11", {
  con <- dm_con(file.path(withr::local_tempdir(), "fresh.duckdb"))
  ensure_schema(con)
  expect_true("db_meta" %in% dm_tables(con))
  cols <- DBI::dbGetQuery(con, "SELECT column_name, data_type FROM information_schema.columns
                                 WHERE table_name = 'db_meta' ORDER BY ordinal_position")
  expect_identical(cols$column_name, c("key", "value", "updated_at"))
  expect_identical(cols$data_type, c("VARCHAR", "VARCHAR", "TIMESTAMP"))
  expect_identical(DBI::dbGetQuery(con, "SELECT count(*) AS n FROM db_meta")$n, 0)
  expect_true(11 %in% DBI::dbGetQuery(con, "SELECT version FROM schema_version")$version)
})

test_that("db_meta.key is the primary key: a second row with the same key is refused", {
  con <- dm_con(dm_db())
  DBI::dbExecute(con, "INSERT INTO db_meta VALUES ('k', 'a', NULL)")
  expect_error(DBI::dbExecute(con, "INSERT INTO db_meta VALUES ('k', 'b', NULL)"))
})

test_that("a database at version 10 gains db_meta from the next ensure_schema(), recording 11 once; a re-run is a no-op", {
  con <- dm_con(dm_db())
  DBI::dbExecute(con, "DROP TABLE db_meta")
  DBI::dbExecute(con, "DELETE FROM schema_version WHERE version = 11")
  expect_false("db_meta" %in% dm_tables(con))
  ensure_schema(con)
  expect_true("db_meta" %in% dm_tables(con))
  ensure_schema(con)
  v <- DBI::dbGetQuery(con, "SELECT version FROM schema_version WHERE version = 11")$version
  expect_length(v, 1)
})

test_that("the core writes no db_meta keys of its own: a seeded database's db_meta is empty", {
  db <- seed_db()
  con <- dm_con(db, read_only = TRUE)
  expect_identical(DBI::dbGetQuery(con, "SELECT count(*) AS n FROM db_meta")$n, 0)
})

# ---- db_meta_get() ------------------------------------------------------------------------

test_that("db_meta_get, db_meta_set and db_meta_read are exported", {
  ex <- getNamespaceExports("sampleTidy")
  expect_true(all(c("db_meta_get", "db_meta_set", "db_meta_read") %in% ex))
})

test_that("db_meta_get() returns the stored value as one string", {
  con <- dm_con(dm_db())
  DBI::dbExecute(con, "INSERT INTO db_meta VALUES ('writer_label', 'machine-a', TIMESTAMP '2026-11-01 00:00:00')")
  expect_identical(db_meta_get(con, "writer_label"), "machine-a")
})

test_that("db_meta_get() returns NA_character_ for an absent key", {
  con <- dm_con(dm_db())
  expect_identical(db_meta_get(con, "writer_generation"), NA_character_)
})

test_that("db_meta_get() returns NA_character_ when the table is absent, and creates nothing", {
  con <- dm_con(dm_bare())
  expect_identical(db_meta_get(con, "writer_generation"), NA_character_)
  expect_identical(dm_tables(con), "t")
})

test_that("db_meta_get() works on a read-only connection, with and without the table", {
  db <- dm_db()
  rw <- DBI::dbConnect(duckdb::duckdb(), db, read_only = FALSE)
  DBI::dbExecute(rw, "INSERT INTO db_meta VALUES ('writer_generation', '4', NULL)")
  DBI::dbDisconnect(rw, shutdown = TRUE)
  ro <- dm_con(db, read_only = TRUE)
  expect_identical(db_meta_get(ro, "writer_generation"), "4")

  ro2 <- dm_con(dm_bare(), read_only = TRUE)
  expect_identical(db_meta_get(ro2, "writer_generation"), NA_character_)
})

test_that("db_meta_get() refuses a key that is not one non-NA string", {
  con <- dm_con(dm_db())
  expect_error(db_meta_get(con, NA_character_))
  expect_error(db_meta_get(con, c("a", "b")))
  expect_error(db_meta_get(con, 1))
  expect_error(db_meta_get(con, character(0)))
})

# ---- db_meta_set() ------------------------------------------------------------------------

test_that("db_meta_set() inserts a key, then replaces it: one row, the latest value", {
  con <- dm_con(dm_db())
  db_meta_set(con, "writer_label", "machine-a")
  expect_identical(db_meta_get(con, "writer_label"), "machine-a")
  db_meta_set(con, "writer_label", "machine-b")
  expect_identical(db_meta_get(con, "writer_label"), "machine-b")
  rows <- dm_rows(con)
  expect_identical(rows$key, "writer_label")
  expect_identical(rows$value, "machine-b")
})

test_that("db_meta_set() stores the value with as.character(): integer, double and logical", {
  con <- dm_con(dm_db())
  db_meta_set(con, "writer_generation", 3L)
  db_meta_set(con, "a_double", 2.5)
  db_meta_set(con, "a_flag", TRUE)
  expect_identical(db_meta_get(con, "writer_generation"), "3")
  expect_identical(db_meta_get(con, "a_double"), "2.5")
  expect_identical(db_meta_get(con, "a_flag"), "TRUE")
  expect_identical(DBI::dbGetQuery(con, "SELECT typeof(value) AS t FROM db_meta LIMIT 1")$t, "VARCHAR")
})

test_that("db_meta_set() sets updated_at (a timestamp near now) on insert and on update", {
  con <- dm_con(dm_db())
  DBI::dbExecute(con, "INSERT INTO db_meta VALUES ('writer_label', 'old', TIMESTAMP '2001-01-01 00:00:00')")
  db_meta_set(con, "writer_label", "new")
  db_meta_set(con, "writer_generation", 1L)
  rows <- dm_rows(con)
  expect_false(anyNA(rows$updated_at))
  # Generous: duckdb may hand a TIMESTAMP back in UTC or local wall time.
  expect_true(all(abs(as.numeric(difftime(rows$updated_at, Sys.time(), units = "hours"))) < 24))
})

test_that("db_meta_set() returns the value invisibly", {
  con <- dm_con(dm_db())
  expect_invisible(db_meta_set(con, "writer_generation", 7L))
  out <- db_meta_set(con, "writer_label", "machine-a")
  expect_identical(out, "machine-a")
  expect_identical(withVisible(db_meta_set(con, "writer_generation", 8L))$value, 8L)
})

test_that("db_meta_set() refuses a value that is not one non-NA scalar, and a bad key", {
  con <- dm_con(dm_db())
  expect_error(db_meta_set(con, "k", NA))
  expect_error(db_meta_set(con, "k", NA_character_))
  expect_error(db_meta_set(con, "k", c("a", "b")))
  expect_error(db_meta_set(con, "k", NULL))
  expect_error(db_meta_set(con, "k", character(0)))
  expect_error(db_meta_set(con, "k", list("a")))
  expect_error(db_meta_set(con, NA_character_, "v"))
  expect_error(db_meta_set(con, c("a", "b"), "v"))
  expect_identical(DBI::dbGetQuery(con, "SELECT count(*) AS n FROM db_meta")$n, 0)
})

test_that("db_meta_set() on a database with no db_meta runs ensure_schema() first", {
  db <- file.path(withr::local_tempdir(), "empty.duckdb")
  con <- dm_con(db)
  expect_length(dm_tables(con), 0)
  db_meta_set(con, "writer_generation", 1L)
  expect_true(all(c("db_meta", "schema_version", "ingest_file") %in% dm_tables(con)))
  expect_true(11 %in% DBI::dbGetQuery(con, "SELECT version FROM schema_version")$version)
  expect_identical(db_meta_get(con, "writer_generation"), "1")
})

test_that("db_meta_set() joins an open db_transaction(): rolled back with it, committed with it", {
  con <- dm_con(dm_db())
  expect_error(db_transaction(con, function(con) {
    db_meta_set(con, "writer_generation", 2L)
    stop("caller failed after the set")
  }))
  expect_identical(db_meta_get(con, "writer_generation"), NA_character_)

  db_transaction(con, function(con) {
    db_meta_set(con, "writer_generation", 2L)
    db_meta_set(con, "writer_label", "machine-a")
  })
  expect_identical(db_meta_get(con, "writer_generation"), "2")
  expect_identical(db_meta_get(con, "writer_label"), "machine-a")
})

# ---- db_meta_read() -----------------------------------------------------------------------

test_that("db_meta_read() returns every key as a named character vector", {
  db <- dm_db()
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = FALSE)
  DBI::dbExecute(con, "INSERT INTO db_meta VALUES
    ('writer_generation', '3', NULL), ('writer_label', 'machine-a', NULL), ('other', 'x', NULL)")
  DBI::dbDisconnect(con, shutdown = TRUE)

  got <- db_meta_read(db)
  expect_type(got, "character")
  got <- got[order(names(got))]
  expect_identical(got, c(other = "x", writer_generation = "3", writer_label = "machine-a"))
})

test_that("db_meta_read() of a database whose db_meta is empty, or absent, is an empty named character", {
  empty <- stats::setNames(character(0), character(0))
  expect_identical(db_meta_read(dm_db()), empty)
  expect_identical(db_meta_read(dm_bare()), empty)
})

test_that("db_meta_read() aborts sampletidy_error on a missing file and never creates it", {
  dir <- withr::local_tempdir()
  missing <- file.path(dir, "no-such.duckdb")
  err <- tryCatch(db_meta_read(missing), error = function(e) e)
  expect_s3_class(err, "sampletidy_error")
  expect_false(file.exists(missing))
  expect_false(file.exists(paste0(missing, ".wal")))
  expect_length(list.files(dir, all.files = TRUE, no.. = TRUE), 0)
})

test_that("db_meta_read() opens the file read-only: it reads a mode-0444 database and leaves its bytes and mtime alone", {
  skip_on_os("windows")
  skip_if(identical(Sys.info()[["user"]], "root"), "root can write a mode-0444 file")
  db <- dm_db()
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = FALSE)
  DBI::dbExecute(con, "INSERT INTO db_meta VALUES ('writer_label', 'machine-a', NULL)")
  DBI::dbDisconnect(con, shutdown = TRUE)
  Sys.setFileTime(db, Sys.time() - 3600)
  before <- file.info(db)[, c("size", "mtime")]
  md5 <- unname(tools::md5sum(db))
  Sys.chmod(db, "444")
  withr::defer(Sys.chmod(db, "644"))

  expect_identical(db_meta_read(db), c(writer_label = "machine-a"))
  expect_identical(file.info(db)[, c("size", "mtime")], before)
  expect_identical(unname(tools::md5sum(db)), md5)
  expect_false(file.exists(paste0(db, ".wal")))
})
