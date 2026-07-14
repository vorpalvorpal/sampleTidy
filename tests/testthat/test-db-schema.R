# Plan 01 - R-1.5 ensure_schema() (ops tables & migrations, A2/A7) and
# R-1.6 state transitions (ingest_file_upsert() / ingest_file_set_state()).

# --- R-1.5 ---------------------------------------------------------------

test_that("R-1.5: ensure_schema() creates all five ops objects on a fresh DB", {
  dir <- withr::local_tempdir()
  db <- file.path(dir, "fresh.duckdb")
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = FALSE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  ensure_schema(con)

  tables <- DBI::dbListTables(con)
  expect_true(all(
    c("ingest_file", "ingest_sighting", "review_queue", "change_log", "schema_version") %in% tables
  ))
})

test_that("R-1.5: schema_version holds every migration version applied", {
  dir <- withr::local_tempdir()
  db <- file.path(dir, "fresh2.duckdb")
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = FALSE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  ensure_schema(con)

  versions <- DBI::dbGetQuery(con, "SELECT version FROM schema_version ORDER BY version")$version
  expect_true(length(versions) >= 1)
  expect_false(anyNA(versions))
  expect_equal(versions, sort(unique(versions)))
})

test_that("R-1.5: calling ensure_schema() twice is a no-op (row counts and versions unchanged, no error)", {
  dir <- withr::local_tempdir()
  db <- file.path(dir, "idempotent.duckdb")
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = FALSE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  ops_tables <- c("ingest_file", "ingest_sighting", "review_queue", "change_log", "schema_version")
  row_counts <- function() {
    vapply(ops_tables, function(t) {
      DBI::dbGetQuery(con, sprintf("SELECT COUNT(*) AS n FROM %s", t))$n
    }, numeric(1))
  }

  ensure_schema(con)
  versions_1 <- DBI::dbGetQuery(con, "SELECT version FROM schema_version ORDER BY version")$version
  counts_1 <- row_counts()

  expect_no_error(ensure_schema(con))

  versions_2 <- DBI::dbGetQuery(con, "SELECT version FROM schema_version ORDER BY version")$version
  counts_2 <- row_counts()

  expect_equal(versions_2, versions_1)
  expect_equal(counts_2, counts_1)
})

test_that("R-1.5: ensure_schema() never drops or narrows existing core-table columns", {
  dir <- withr::local_tempdir()
  db <- seed_db(dir)
  con <- seed_con(db)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  core_tables <- c("feature", "feature_mask", "analyte", "lab_method", "project", "sample", "analysis", "asset")
  fields_before <- lapply(core_tables, function(t) DBI::dbListFields(con, t))
  names(fields_before) <- core_tables

  expect_no_error(ensure_schema(con))

  fields_after <- lapply(core_tables, function(t) DBI::dbListFields(con, t))
  names(fields_after) <- core_tables

  expect_equal(fields_after, fields_before)
})

# --- R-1.6 state transitions ----------------------------------------------
# NOTE: ingest_file_upsert()'s exact argument names beyond `con, hash` are not
# pinned in PLAN-01 (only sketched as `ingest_file_upsert(con, hash, ...)`).
# We take the reading that the current path being observed is passed as
# `path`, stored into `path_first_seen` only on the row's first insert (the
# column name says "first seen" - subsequent upserts with a different path
# must not overwrite it, only add an ingest_sighting row). See
# dev/plans/PLAN-CHANGE-REQUESTS.md.

test_that("R-1.6: a legal state path walks end to end", {
  dir <- withr::local_tempdir()
  db <- seed_db(dir)
  con <- seed_con(db)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  hash <- "walk-hash-01"
  ingest_file_upsert(con, hash, path = "/in/walk.csv", filename = "walk.csv", size = 10)

  path_seq <- c("claimed", "parsed", "assembled", "reconciled", "committed", "archived")
  for (state in path_seq) {
    expect_no_error(ingest_file_set_state(con, hash, state))
  }

  final <- DBI::dbGetQuery(con, "SELECT state FROM ingest_file WHERE hash = ?", params = list(hash))
  expect_equal(final$state, "archived")
})

test_that("R-1.6: an illegal jump (seen -> committed) aborts naming both states", {
  dir <- withr::local_tempdir()
  db <- seed_db(dir)
  con <- seed_con(db)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  hash <- "illegal-hash-01"
  ingest_file_upsert(con, hash, path = "/in/illegal.csv", filename = "illegal.csv", size = 10)
  # a freshly-upserted hash starts life in "seen"

  err <- tryCatch(ingest_file_set_state(con, hash, "committed"), error = function(e) e)
  expect_s3_class(err, "sampletidy_error")
  expect_match(conditionMessage(err), "seen", ignore.case = TRUE)
  expect_match(conditionMessage(err), "committed", ignore.case = TRUE)
})

test_that("R-1.6: any state can transition to failed", {
  dir <- withr::local_tempdir()
  db <- seed_db(dir)
  con <- seed_con(db)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  hash <- "failed-hash-01"
  ingest_file_upsert(con, hash, path = "/in/f.csv", filename = "f.csv", size = 10)
  ingest_file_set_state(con, hash, "claimed")
  ingest_file_set_state(con, hash, "parsed")

  expect_no_error(ingest_file_set_state(con, hash, "failed", reason = "kaboom"))
  row <- DBI::dbGetQuery(con, "SELECT state, state_reason FROM ingest_file WHERE hash = ?", params = list(hash))
  expect_equal(row$state, "failed")
  expect_equal(row$state_reason, "kaboom")
})

test_that("R-1.6: terminal states (e.g. archived) cannot transition further without reset = TRUE", {
  dir <- withr::local_tempdir()
  db <- seed_db(dir)
  con <- seed_con(db)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  hash <- "terminal-hash-01"
  ingest_file_upsert(con, hash, path = "/in/t.csv", filename = "t.csv", size = 10)
  ingest_file_set_state(con, hash, "claimed")
  ingest_file_set_state(con, hash, "ignored")

  err <- tryCatch(ingest_file_set_state(con, hash, "claimed"), error = function(e) e)
  expect_s3_class(err, "sampletidy_error")
})

test_that("R-1.6: upsert on an existing hash updates updated_at, preserves path_first_seen, and appends a sighting only when the path differs", {
  dir <- withr::local_tempdir()
  db <- seed_db(dir)
  con <- seed_con(db)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  hash <- "sighting-hash-01"
  ingest_file_upsert(con, hash, path = "/in/s.csv", filename = "s.csv", size = 10)
  first <- DBI::dbGetQuery(con, "SELECT updated_at, path_first_seen FROM ingest_file WHERE hash = ?", params = list(hash))
  expect_equal(first$path_first_seen, "/in/s.csv")

  Sys.sleep(1.1)
  ingest_file_upsert(con, hash, path = "/in/s.csv", filename = "s.csv", size = 10)
  second <- DBI::dbGetQuery(con, "SELECT updated_at, path_first_seen FROM ingest_file WHERE hash = ?", params = list(hash))
  expect_gt(as.numeric(second$updated_at), as.numeric(first$updated_at))
  expect_equal(second$path_first_seen, "/in/s.csv")

  sightings_same_path <- DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM ingest_sighting WHERE hash = ?", params = list(hash))$n
  expect_equal(sightings_same_path, 0)

  Sys.sleep(1.1)
  ingest_file_upsert(con, hash, path = "/in/other/s.csv", filename = "s.csv", size = 10)
  third <- DBI::dbGetQuery(con, "SELECT path_first_seen FROM ingest_file WHERE hash = ?", params = list(hash))
  expect_equal(third$path_first_seen, "/in/s.csv") # unchanged - it's the FIRST-seen path

  sightings_diff_path <- DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM ingest_sighting WHERE hash = ?", params = list(hash))$n
  expect_equal(sightings_diff_path, 1)
})
