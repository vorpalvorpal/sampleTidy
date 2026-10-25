# PLAN-20 phase 1, P20.M: operator migration 060 (asset_filing). Spec:
# dev/plans/PLAN-20-phase1-spec.md section P20.M. Pattern: test-qc-migrations.R.
#
#   mig060_run(db, snapshot_dir, dry_run = FALSE, .now = NULL)
#     -> invisible list(status = "dry_run" | "migrated" | "already_migrated", ...)
#
# The live DB sits at marker 1052 with ops-schema versions 1..9 (no asset_filing).
# seed_db() runs the CURRENT ensure_schema(), which (once version 10 exists) already
# creates asset_filing; m60_db() undoes that to simulate the live DB.

m60_load <- function() {
  dir <- test_path("..", "..", "dev", "migrations")
  hits <- list.files(dir, pattern = "^060-.*\\.R$", full.names = TRUE)
  hits <- hits[!grepl("^apply-", basename(hits))]
  if (length(hits) != 1) stop(sprintf("migration 060 not found (or not unique) in %s", dir))
  env <- new.env(parent = globalenv())
  sys.source(hits[[1]], envir = env)
  env
}

m60_query <- function(db, sql) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbGetQuery(con, sql)
}

m60_tables <- function(db) {
  m60_query(db, "SELECT table_name FROM information_schema.tables WHERE table_type = 'BASE TABLE'")$table_name
}

m60_markers <- function(db) m60_query(db, "SELECT version FROM schema_version ORDER BY version")$version

# Row counts of every base table except schema_version and asset_filing.
m60_counts <- function(db) {
  t <- setdiff(sort(m60_tables(db)), c("schema_version", "asset_filing"))
  stats::setNames(vapply(t, function(x) {
    m60_query(db, sprintf('SELECT count(*) AS n FROM "%s"', x))$n
  }, numeric(1)), t)
}

# The live DB at marker 1052, ops versions 1..9, no asset_filing.
m60_db <- function(env = parent.frame(), marker = TRUE, keep_table = FALSE) {
  db <- seed_db(dir = withr::local_tempdir(.local_envir = env))
  con <- seed_con(db)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  if (!keep_table) {
    DBI::dbExecute(con, "DROP TABLE IF EXISTS asset_filing")
    DBI::dbExecute(con, "DELETE FROM schema_version WHERE version = 10")
  }
  if (marker) {
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at)
                         VALUES (1052, TIMESTAMP '2026-10-19 00:00:00')")
  }
  DBI::dbExecute(con, "INSERT INTO asset (uuid, uuid_project, filename, hash)
                       VALUES ('as-1', 'p-0001', 'one.csv', 'h-one')")
  db
}

m60_run <- function(env, db, snap, ...) {
  suppressMessages(env$mig060_run(db = db, snapshot_dir = snap, ...))
}

af_expected_cols <- c("uuid_asset", "system", "external_id", "external_uri", "container",
                      "filed_at", "title", "comments")

test_that("060: dry run checks the preconditions and writes nothing - no table, no marker, no backup", {
  env <- m60_load()
  db <- m60_db()
  snap <- withr::local_tempdir()
  before <- m60_counts(db)
  md5 <- file_md5(db)
  r <- m60_run(env, db, snap, dry_run = TRUE)
  expect_identical(r$status, "dry_run")
  expect_false("asset_filing" %in% m60_tables(db))
  expect_false(1060 %in% m60_markers(db))
  expect_length(list.files(snap), 0)
  expect_identical(m60_counts(db), before)
  expect_identical(file_md5(db), md5)
})

test_that("060: migrates a DB at marker 1052 - table, version 10 and marker 1060 recorded, other tables untouched", {
  env <- m60_load()
  db <- m60_db()
  snap <- withr::local_tempdir()
  before <- m60_counts(db)
  r <- m60_run(env, db, snap)
  expect_identical(r$status, "migrated")
  expect_true("asset_filing" %in% m60_tables(db))
  cols <- m60_query(db, "SELECT column_name, data_type, is_nullable FROM information_schema.columns
                          WHERE table_name = 'asset_filing' ORDER BY ordinal_position")
  expect_identical(cols$column_name, af_expected_cols)
  expect_identical(cols$data_type[cols$column_name == "filed_at"], "TIMESTAMP")
  expect_identical(cols$is_nullable,
                   c("NO", "NO", "NO", "YES", "YES", "NO", "YES", "YES"))
  expect_identical(m60_query(db, "SELECT count(*) AS n FROM asset_filing")$n, 0)
  mk <- m60_markers(db)
  expect_true(all(c(10, 1052, 1060) %in% mk))
  expect_identical(sum(mk == 10), 1L)
  expect_identical(sum(mk == 1060), 1L)
  expect_identical(m60_counts(db), before)
})

test_that("060: the migrated table enforces the (uuid_asset, system) primary key", {
  env <- m60_load()
  db <- m60_db()
  m60_run(env, db, withr::local_tempdir())
  con <- seed_con(db)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  ins <- function(a, s) DBI::dbExecute(con, sprintf(
    "INSERT INTO asset_filing (uuid_asset, system, external_id, filed_at)
     VALUES ('%s', '%s', 'x', TIMESTAMP '2026-10-01 00:00:00')", a, s))
  ins("as-1", "TRIM")
  expect_error(ins("as-1", "TRIM"))
  expect_no_error(ins("as-1", "SharePoint"))
})

test_that("060: takes a verified whole-file backup in snapshot_dir that predates the change", {
  env <- m60_load()
  db <- m60_db()
  snap <- withr::local_tempdir()
  r <- m60_run(env, db, snap)
  bk <- list.files(snap, full.names = TRUE)
  expect_length(bk, 1)
  expect_match(basename(bk), "\\.duckdb$")
  if (!is.null(r$backup_path) && !is.na(r$backup_path)) expect_true(file.exists(r$backup_path))
  # the backup is a readable copy of the DB as it was: no asset_filing, no marker 1060
  expect_false("asset_filing" %in% m60_tables(bk))
  expect_false(1060 %in% m60_markers(bk))
  expect_true(1052 %in% m60_markers(bk))
})

test_that("060: a re-run with the marker present is 'already_migrated' and writes nothing (no second backup)", {
  env <- m60_load()
  db <- m60_db()
  snap <- withr::local_tempdir()
  m60_run(env, db, snap)
  md5 <- file_md5(db)
  files <- list.files(snap)
  r2 <- m60_run(env, db, snap)
  expect_identical(r2$status, "already_migrated")
  expect_identical(list.files(snap), files)
  expect_identical(file_md5(db), md5)
  expect_identical(sum(m60_markers(db) == 1060), 1L)
})

test_that("060: requires marker 1052 - without it the run aborts with sampletidy_error and writes nothing (dry run too)", {
  env <- m60_load()
  db <- m60_db(marker = FALSE)
  snap <- withr::local_tempdir()
  md5 <- file_md5(db)
  expect_error(m60_run(env, db, snap), class = "sampletidy_error")
  expect_error(m60_run(env, db, snap, dry_run = TRUE), class = "sampletidy_error")
  expect_false("asset_filing" %in% m60_tables(db))
  expect_false(1060 %in% m60_markers(db))
  expect_length(list.files(snap), 0)
  expect_identical(file_md5(db), md5)
})

test_that("060: a DB with no asset table aborts with sampletidy_error and writes nothing", {
  env <- m60_load()
  db <- m60_db()
  con <- seed_con(db)
  DBI::dbExecute(con, "DROP TABLE asset")
  DBI::dbDisconnect(con, shutdown = TRUE)
  snap <- withr::local_tempdir()
  expect_error(m60_run(env, db, snap), class = "sampletidy_error")
  expect_false("asset_filing" %in% m60_tables(db))
  expect_false(1060 %in% m60_markers(db))
  expect_length(list.files(snap), 0)
})

test_that("060: adopts an empty asset_filing that ensure_schema() version 10 already created - marker 1060 recorded, version 10 not duplicated, table kept", {
  env <- m60_load()
  db <- m60_db(keep_table = TRUE)          # seed_db() ran the current ensure_schema()
  expect_true("asset_filing" %in% m60_tables(db))
  expect_true(10 %in% m60_markers(db))
  snap <- withr::local_tempdir()
  r <- m60_run(env, db, snap)
  expect_identical(r$status, "migrated")
  expect_true("asset_filing" %in% m60_tables(db))
  mk <- m60_markers(db)
  expect_identical(sum(mk == 10), 1L)
  expect_identical(sum(mk == 1060), 1L)
  expect_length(list.files(snap), 1)
  expect_identical(m60_query(db, "SELECT count(*) AS n FROM asset_filing")$n, 0)
})

test_that("060: adopts when the table exists but version 10 is not recorded - version 10 is inserted", {
  env <- m60_load()
  db <- m60_db(keep_table = TRUE)
  con <- seed_con(db)
  DBI::dbExecute(con, "DELETE FROM schema_version WHERE version = 10")
  DBI::dbDisconnect(con, shutdown = TRUE)
  r <- m60_run(env, db, withr::local_tempdir())
  expect_identical(r$status, "migrated")
  expect_true(all(c(10, 1060) %in% m60_markers(db)))
})

test_that("060: refuses (sampletidy_error, nothing written, no backup) an existing asset_filing that has rows", {
  env <- m60_load()
  db <- m60_db(keep_table = TRUE)
  con <- seed_con(db)
  DBI::dbExecute(con, "INSERT INTO asset_filing (uuid_asset, system, external_id, filed_at)
                       VALUES ('as-1', 'TRIM', 'x', TIMESTAMP '2026-10-01 00:00:00')")
  DBI::dbDisconnect(con, shutdown = TRUE)
  snap <- withr::local_tempdir()
  md5 <- file_md5(db)
  expect_error(m60_run(env, db, snap), class = "sampletidy_error")
  expect_error(m60_run(env, db, snap, dry_run = TRUE), class = "sampletidy_error")
  expect_false(1060 %in% m60_markers(db))
  expect_length(list.files(snap), 0)
  expect_identical(file_md5(db), md5)
  expect_identical(m60_query(db, "SELECT count(*) AS n FROM asset_filing")$n, 1)
})

test_that("060: refuses an existing asset_filing whose columns are not exactly the spec's", {
  env <- m60_load()
  for (ddl in c(
    # a column missing
    "CREATE TABLE asset_filing (uuid_asset VARCHAR NOT NULL, system VARCHAR NOT NULL,
       external_id VARCHAR NOT NULL, external_uri VARCHAR, container VARCHAR,
       filed_at TIMESTAMP NOT NULL, title VARCHAR, PRIMARY KEY (uuid_asset, system))",
    # an extra column
    "CREATE TABLE asset_filing (uuid_asset VARCHAR NOT NULL, system VARCHAR NOT NULL,
       external_id VARCHAR NOT NULL, external_uri VARCHAR, container VARCHAR,
       filed_at TIMESTAMP NOT NULL, title VARCHAR, comments VARCHAR, extra VARCHAR,
       PRIMARY KEY (uuid_asset, system))",
    # same columns, wrong order
    "CREATE TABLE asset_filing (system VARCHAR NOT NULL, uuid_asset VARCHAR NOT NULL,
       external_id VARCHAR NOT NULL, external_uri VARCHAR, container VARCHAR,
       filed_at TIMESTAMP NOT NULL, title VARCHAR, comments VARCHAR,
       PRIMARY KEY (uuid_asset, system))"
  )) {
    db <- m60_db()
    con <- seed_con(db)
    DBI::dbExecute(con, ddl)
    DBI::dbDisconnect(con, shutdown = TRUE)
    snap <- withr::local_tempdir()
    expect_error(m60_run(env, db, snap), class = "sampletidy_error", info = ddl)
    expect_false(1060 %in% m60_markers(db), info = ddl)
    expect_length(list.files(snap), 0)
  }
})

test_that("060: the apply script exists and reads SAMPLETIDY_MIG060_DB and SAMPLETIDY_MIG060_SNAPSHOT_DIR", {
  p <- test_path("..", "..", "dev", "migrations", "apply-060-asset-filing.R")
  expect_true(file.exists(p))
  txt <- paste(readLines(p, warn = FALSE), collapse = "\n")
  expect_match(txt, "SAMPLETIDY_MIG060_DB", fixed = TRUE)
  expect_match(txt, "SAMPLETIDY_MIG060_SNAPSHOT_DIR", fixed = TRUE)
})
