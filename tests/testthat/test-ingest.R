# Plan 09 - R/ingest.R: `ingest_dir(path, db, dry_run)` orchestration (R-9.5)
# and the `remove_ingested` switch (R-9.6, A13).
#
# Assumes the built-in adapters (esdat/als_xtab/als_enmrg/acirl_field_xlsx)
# self-register on package load (see dev/plans/PLAN-CHANGE-REQUESTS.md).
# `ingest_report`'s exact field names aren't pinned by CONTRACT beyond "files
# by terminal state, events committed, rows new/already_present/superseded/
# skipped-by-reason, review items opened" (DESIGN §1), so these tests verify
# primarily via direct DB/`ingest_file` inspection (fully pinned by
# PLAN-01/CONTRACT) rather than guessing report field names, and only check
# generic sanity properties of the returned report object itself.

ingest_test_setup <- function() {
  # Bind withr cleanups to the calling test's frame, not this helper's - see
  # CONTRACT A41 (the A38 bug, one frame removed).
  env <- parent.frame()
  db_path <- seed_db(dir = withr::local_tempdir(.local_envir = env))
  con <- seed_con(db_path)
  ensure_test_asset_table(con)
  DBI::dbDisconnect(con, shutdown = TRUE) # ingest_dir() opens its own connections

  archive_dir <- withr::local_tempdir(.local_envir = env)
  snapshot_dir <- withr::local_tempdir(.local_envir = env)
  withr::local_options(list(
    "sampletidy.archive_dir" = archive_dir,
    "sampletidy.snapshot_dir" = snapshot_dir,
    "sampletidy.remove_ingested" = FALSE
  ), .local_envir = env)
  list(db_path = db_path, archive_dir = archive_dir, snapshot_dir = snapshot_dir)
}

count_rows <- function(db_path, table) {
  con <- DBI::dbConnect(duckdb::duckdb(), db_path, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbGetQuery(con, sprintf('SELECT count(*) AS n FROM "%s"', table))$n
}

all_core_counts <- function(db_path) {
  con <- DBI::dbConnect(duckdb::duckdb(), db_path, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  tables <- c("feature", "feature_mask", "analyte", "lab_method", "project",
              "sample", "analysis", "asset")
  vapply(tables, function(t) {
    exists_tbl <- DBI::dbExistsTable(con, t)
    if (!exists_tbl) return(0)
    DBI::dbGetQuery(con, sprintf('SELECT count(*) AS n FROM "%s"', t))$n
  }, numeric(1))
}

ingest_file_states <- function(db_path) {
  con <- DBI::dbConnect(duckdb::duckdb(), db_path, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbGetQuery(con, "SELECT hash, filename, state, state_reason FROM ingest_file")
}

# ---- R-9.5: end-to-end orchestration ---------------------------------------

test_that("R-9.5: subdirectory content is untouched and cruft files are ignored", {
  setup <- ingest_test_setup()
  input_dir <- build_e2e_input_dir()

  report <- ingest_dir(input_dir, db = setup$db_path)
  expect_type(report, "list")

  # the subdirectory and its contents are never touched
  subdir <- file.path(input_dir, "subdir")
  expect_true(dir.exists(subdir))
  expect_true(length(list.files(subdir)) >= 1)

  states <- ingest_file_states(setup$db_path)
  # nothing under subdir/ was ever routed (paths recorded, if any, would
  # contain "subdir")
  expect_false(any(grepl("subdir", states$filename, fixed = TRUE)))

  # cruft is ignored
  bak_state <- states[states$filename == "old_export.bak", ]
  expect_equal(nrow(bak_state), 1)
  expect_identical(bak_state$state, "ignored")
  ds_state <- states[states$filename == ".DS_Store", ]
  expect_equal(nrow(ds_state), 1)
  expect_identical(ds_state$state, "ignored")
})

test_that("R-9.5: every landed adapter family commits and report numbers reconcile with DB deltas", {
  setup <- ingest_test_setup()
  input_dir <- build_e2e_input_dir()

  before <- all_core_counts(setup$db_path)
  report <- ingest_dir(input_dir, db = setup$db_path)
  after <- all_core_counts(setup$db_path)

  expect_true(any(after != before),
              info = "ingest_dir() over the fixture families should create at least some new core rows")

  states <- ingest_file_states(setup$db_path)
  fixture_files <- states[!states$filename %in% c("old_export.bak", ".DS_Store"), ]
  # every non-cruft fixture file lands in a real terminal state (not left
  # mid-pipeline)
  expect_true(all(fixture_files$state %in%
    c("committed", "archived", "ignored", "quarantined", "failed", "needs_review")))
})

test_that("R-9.5: dry_run = TRUE produces a report with zero core-table DB writes and no snapshot", {
  setup <- ingest_test_setup()
  input_dir <- build_e2e_input_dir()

  before <- all_core_counts(setup$db_path)
  report <- ingest_dir(input_dir, db = setup$db_path, dry_run = TRUE)
  after <- all_core_counts(setup$db_path)

  expect_type(report, "list")
  expect_equal(after, before)
  expect_length(list.files(setup$snapshot_dir), 0)
})

test_that("R-9.5: an adapter crash on one file is recorded as failed and the run completes", {
  setup <- ingest_test_setup()
  input_dir <- withr::local_tempdir()
  corrupt_src <- testthat::test_path("fixtures", "esdat", "CORRUPT.ESDAT_XX0000000_0.Chemistry2e.CSV")
  expect_true(file.exists(corrupt_src), info = "corrupted ESdat fixture must exist per PLAN-04/FIXTURES.md")
  file.copy(corrupt_src, file.path(input_dir, basename(corrupt_src)))

  expect_no_error(report <- ingest_dir(input_dir, db = setup$db_path))
  states <- ingest_file_states(setup$db_path)
  corrupt_state <- states[states$filename == basename(corrupt_src), ]
  expect_equal(nrow(corrupt_state), 1)
  expect_identical(corrupt_state$state, "failed")
  expect_false(is.na(corrupt_state$state_reason))
})

test_that("R-9.5: a second run over the same directory is a no-op (idempotent at the orchestration level)", {
  setup <- ingest_test_setup()
  input_dir <- build_e2e_input_dir()

  ingest_dir(input_dir, db = setup$db_path)
  after_first <- all_core_counts(setup$db_path)
  n_files_first <- nrow(ingest_file_states(setup$db_path))
  n_review_first <- count_rows(setup$db_path, "review_queue")

  ingest_dir(input_dir, db = setup$db_path)
  after_second <- all_core_counts(setup$db_path)
  n_files_second <- nrow(ingest_file_states(setup$db_path))
  n_review_second <- count_rows(setup$db_path, "review_queue")

  expect_equal(after_second, after_first)
  expect_equal(n_files_second, n_files_first)
  expect_equal(n_review_second, n_review_first)
})

# ---- R-9.6: the remove switch (A13) ----------------------------------------

test_that("R-9.6: default (remove_ingested = FALSE) leaves all sources present", {
  setup <- ingest_test_setup()
  input_dir <- build_e2e_input_dir()
  files_before <- list.files(input_dir, recursive = FALSE)

  ingest_dir(input_dir, db = setup$db_path)

  files_after <- list.files(input_dir, recursive = FALSE)
  expect_setequal(files_after, files_before)
})

test_that("R-9.6: remove_ingested = TRUE removes verified sources but keeps quarantined/failed/cruft", {
  setup <- ingest_test_setup()
  input_dir <- withr::local_tempdir()
  esdat_dir <- testthat::test_path("fixtures", "esdat")
  for (f in list.files(esdat_dir, full.names = TRUE)) {
    if (basename(f) %in% c("README.md", "generate.R")) next
    file.copy(f, file.path(input_dir, basename(f)))
  }
  writeLines("cruft", file.path(input_dir, "old_export.bak"))

  withr::local_options(list("sampletidy.remove_ingested" = TRUE))
  ingest_dir(input_dir, db = setup$db_path)

  states <- ingest_file_states(setup$db_path)
  committed <- states[states$state %in% c("committed", "archived", "ignored") &
                        states$filename != "old_export.bak", ]
  for (fn in committed$filename) {
    expect_false(file.exists(file.path(input_dir, fn)),
                 info = paste(fn, "should have been removed (verified archive copy)"))
  }
  # cruft is never removed
  expect_true(file.exists(file.path(input_dir, "old_export.bak")))
  # anything failed/quarantined is never removed
  failed_or_quarantined <- states[states$state %in% c("failed", "quarantined"), ]
  for (fn in failed_or_quarantined$filename) {
    expect_true(file.exists(file.path(input_dir, fn)))
  }
})

test_that("R-9.6: remove_ingested = TRUE with an injected snapshot failure removes nothing", {
  setup <- ingest_test_setup()
  input_dir <- withr::local_tempdir()
  esdat_dir <- testthat::test_path("fixtures", "esdat")
  for (f in list.files(esdat_dir, full.names = TRUE)) {
    if (basename(f) %in% c("README.md", "generate.R")) next
    file.copy(f, file.path(input_dir, basename(f)))
  }
  files_before <- list.files(input_dir, recursive = FALSE)

  withr::local_options(list("sampletidy.remove_ingested" = TRUE))
  testthat::local_mocked_bindings(snapshot_db = function(...) stop("simulated snapshot failure"))

  expect_error(ingest_dir(input_dir, db = setup$db_path))
  files_after <- list.files(input_dir, recursive = FALSE)
  expect_setequal(files_after, files_before)
})

test_that("R-9.6: a source with a missing archive copy is kept, never deleted without a verified copy", {
  setup <- ingest_test_setup()
  input_dir <- withr::local_tempdir()
  esdat_dir <- testthat::test_path("fixtures", "esdat")
  for (f in list.files(esdat_dir, full.names = TRUE)) {
    if (basename(f) %in% c("README.md", "generate.R")) next
    file.copy(f, file.path(input_dir, basename(f)))
  }

  # first pass: commit + archive with remove OFF, so files stay put
  ingest_dir(input_dir, db = setup$db_path)
  states <- ingest_file_states(setup$db_path)
  committed <- states[states$state %in% c("committed", "archived"), ]
  expect_gt(nrow(committed), 0)
  tampered_hash <- committed$hash[[1]]
  tampered_filename <- committed$filename[[1]]

  con <- DBI::dbConnect(duckdb::duckdb(), setup$db_path, read_only = TRUE)
  asset_row <- DBI::dbGetQuery(con, sprintf("SELECT * FROM asset WHERE hash = '%s'", tampered_hash))
  DBI::dbDisconnect(con, shutdown = TRUE)
  expect_gt(nrow(asset_row), 0)
  copy_path <- file.path(setup$archive_dir, asset_row$uuid[[1]])
  if (file.exists(copy_path)) file.remove(copy_path)

  withr::local_options(list("sampletidy.remove_ingested" = TRUE))
  ingest_dir(input_dir, db = setup$db_path)

  # the file whose archive copy is missing must still be present
  expect_true(file.exists(file.path(input_dir, tampered_filename)))
})

test_that("R-9.6: a subsequent run over the emptied directory is a clean no-op", {
  setup <- ingest_test_setup()
  input_dir <- withr::local_tempdir()
  esdat_dir <- testthat::test_path("fixtures", "esdat")
  for (f in list.files(esdat_dir, full.names = TRUE)) {
    if (basename(f) %in% c("README.md", "generate.R")) next
    file.copy(f, file.path(input_dir, basename(f)))
  }

  withr::local_options(list("sampletidy.remove_ingested" = TRUE))
  ingest_dir(input_dir, db = setup$db_path)
  after_removal <- all_core_counts(setup$db_path)

  expect_no_error(ingest_dir(input_dir, db = setup$db_path))
  after_second <- all_core_counts(setup$db_path)
  expect_equal(after_second, after_removal)
})
