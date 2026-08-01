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
  # `review_queue` and `change_log` are here deliberately. Every "this call
  # writes NOTHING" assertion resting on this function is only as strong as
  # this list, and a call that quietly opened a review item or logged a
  # mutation would have passed against the core-data tables alone.
  #
  # `ingest_file` is deliberately NOT here, and adding it is a mistake worth
  # not repeating: `route_files()` always upserts a row to record the sighting,
  # so it grows even on a dry run BY DESIGN - see `.dry_run_exempt_tables`
  # below for the full reasoning. Callers that really do write nothing at all
  # (`quarantine_report()`) assert with `all_table_counts()` instead, which
  # covers every base table including that one.
  tables <- c("feature", "feature_mask", "analyte", "lab_method", "project",
              "sample", "analysis", "asset", "review_queue", "change_log")
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

# Fixture builders live HERE, above every test, deliberately. testthat sources
# a test file top-to-bottom and runs each `test_that()` as it reaches it, so a
# helper defined below its first caller does not exist when that caller runs -
# which is exactly how AUDIT-2 came to fail with "could not find function".

# A COA PDF for `wo`, written to `dir`, with enough filler that it is not a
# degenerate file. Returns path/hash/bytes, all captured BEFORE ingest, since
# a remove_ingested pass deletes the source out from under the assertions.
write_coa_fixture <- function(dir, wo) {
  path <- file.path(dir, sprintf("%s_0_COA.pdf", wo))
  bytes <- charToRaw(paste(
    c(sprintf("%%PDF-1.4 fake Certificate of Analysis for work order %s", wo),
      sprintf("line %02d: filler so this is not a degenerate file", 1:20)),
    collapse = "\n"
  ))
  writeBin(bytes, path)
  list(path = path, hash = hash_file(path), bytes = bytes)
}

# Copy one work order's esdat triple into `dir`, returning the file count.
seed_wo_folder <- function(dir, wo) {
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  files <- list.files(testthat::test_path("fixtures", "esdat"), pattern = wo, full.names = TRUE)
  for (f in files) file.copy(f, file.path(dir, basename(f)))
  length(files)
}

# ---- R-9.5: end-to-end orchestration ---------------------------------------

test_that("R-9.5: subdirectory content is untouched and cruft files are ignored", {
  setup <- ingest_test_setup()
  input_dir <- build_e2e_input_dir()

  report <- ingest_dir(input_dir, db = setup$db_path)
  # R-12.15 T-1 sweep (5th instance): assert the report's own files_by_state
  # reflects a specific, fixture-derived count rather than merely existing as
  # a list. Since R-12.7 makes files_by_state a TERMINAL-state tally (not the
  # route-time snapshot), `ignored` is the two cruft files (old_export.bak,
  # .DS_Store) PLUS the four XX1234567 crosstab/enmrg sources that
  # assemble_events() supersede-drops to a better source (route-time
  # reporting counted those four as `claimed`): 2 + 4 = 6.
  expect_true(report$n_files_routed > 0)
  expect_equal(unname(report$files_by_state[["ignored"]]), 6L)

  # the subdirectory and its contents are never touched
  subdir <- file.path(input_dir, "subdir")
  expect_true(dir.exists(subdir))
  expect_true(length(list.files(subdir)) >= 1)

  states <- ingest_file_states(setup$db_path)
  # nothing under subdir/ was ever routed (paths recorded, if any, would
  # contain "subdir")
  expect_false(any(grepl("subdir", states$filename, fixed = TRUE)))

  # cruft is ignored. NA-safe filter: seed_db() seeds a legacy ingest_file row
  # (legacy-hash-XX) with filename = NA; a bare `== "x"` yields NA for it and
  # base-R row-subsetting would splice in a phantom all-NA row (CONTRACT A43).
  bak_state <- states[!is.na(states$filename) & states$filename == "old_export.bak", ]
  expect_equal(nrow(bak_state), 1)
  expect_identical(bak_state$state, "ignored")
  ds_state <- states[!is.na(states$filename) & states$filename == ".DS_Store", ]
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

  # R-12.15 T-1 sweep (5th instance): pin dry_run's own documented contract
  # (ingest_dir() roxygen: "dry_run = TRUE still routes, parses, assembles
  # and reconciles ... but skips commit_event() ... entirely") rather than
  # just checking `report` exists.
  expect_true(isTRUE(report$dry_run))
  expect_true(report$n_files_routed > 0)
  expect_equal(report$n_events_committed, 0L)
  expect_equal(after, before)
  expect_length(list.files(setup$snapshot_dir), 0)
})

# ---- generic dry-run purity guard: EVERY base table, not a named list -----
#
# `all_core_counts()` above only enumerates the core business tables by
# name, so a write to any other table (ops or otherwise) is invisible to it.
# `all_table_counts()` instead discovers every base table from
# `information_schema` at call time, so a table a later migration adds is
# covered automatically without this file needing to be touched again.

all_table_counts <- function(db_path) {
  con <- DBI::dbConnect(duckdb::duckdb(), db_path, read_only = TRUE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  tables <- sort(DBI::dbGetQuery(
    con, "SELECT table_name FROM information_schema.tables WHERE table_type = 'BASE TABLE'"
  )$table_name)
  rlang::set_names(
    vapply(tables, function(t) DBI::dbGetQuery(con, sprintf('SELECT count(*) AS n FROM "%s"', t))$n, numeric(1)),
    tables
  )
}

# `route_files()` always upserts a fresh hash's `ingest_file` row (at least
# to record the sighting), so `ingest_file` grows even on a dry run - but
# only `claimed` advances that row's STATE on a dry run (T1.2). `unclaimed`,
# `failed` and `adapter_tie` all leave the row at `seen`: each would write a
# TERMINAL state, which is a verdict about the adapter registry at that
# moment, not a durable fact about the file, so persisting it during a
# preview would permanently stop a later run from re-deciding the hash once
# the registry is fixed (see the tie branch in `R/router.R`). `ingest_sighting`
# is the same hash's per-path bookkeeping. Both are ops tables, not core
# data - every OTHER base table must show zero growth from a dry run.
.dry_run_exempt_tables <- c("ingest_file", "ingest_sighting")

expect_dry_run_writes_nothing_but_routing <- function(db_path, run) {
  before <- all_table_counts(db_path)
  run()
  after <- all_table_counts(db_path)[names(before)]
  diff <- after - before
  offenders <- diff[diff != 0 & !(names(diff) %in% .dry_run_exempt_tables)]
  expect_true(
    length(offenders) == 0,
    label = paste(
      "tables grown by a dry run:",
      paste(names(offenders), unname(offenders), sep = "=", collapse = ", ")
    )
  )
}

test_that("generic guard: a dry run over the full e2e corpus grows no base table except the routing ops tables", {
  setup <- ingest_test_setup()
  input_dir <- build_e2e_input_dir()

  expect_dry_run_writes_nothing_but_routing(setup$db_path, function() {
    suppressMessages(ingest_dir(input_dir, db = setup$db_path, dry_run = TRUE))
  })
})

test_that("R-3.5/T1.2: an adapter tie writes nothing (review_queue/change_log, or a stuck quarantined state) under dry_run, and a later real run still resolves it", {
  setup <- ingest_test_setup()
  input_dir <- withr::local_tempdir()

  tie_a_id <- "t8b_tie_a"
  tie_b_id <- "t8b_tie_b"
  register_adapter(list(
    id = tie_a_id, version = "1.0",
    match = function(fm) if (grepl("TIEBAIT", fm$filename)) "exact" else "no",
    parse = function(path, file_meta) stop("never called: file is quarantined, not claimed")
  ))
  register_adapter(list(
    id = tie_b_id, version = "1.0",
    match = function(fm) if (grepl("TIEBAIT", fm$filename)) "exact" else "no",
    parse = function(path, file_meta) stop("never called: file is quarantined, not claimed")
  ))
  withr::defer({
    for (id in c(tie_a_id, tie_b_id)) {
      if (exists(id, envir = sampleTidy:::.st_adapter_registry, inherits = FALSE)) {
        rm(list = id, envir = sampleTidy:::.st_adapter_registry)
      }
    }
  })

  bait <- st_test_write_file(input_dir, "ES1234567_TIEBAIT_0.csv", content = "a,b\n1,2\n")
  bait_hash <- hash_file(bait)

  expect_dry_run_writes_nothing_but_routing(setup$db_path, function() {
    suppressMessages(ingest_dir(input_dir, db = setup$db_path, dry_run = TRUE))
  })

  # the tie is not merely un-persisted in aggregate (the row-count guard
  # above) - the hash itself must still be at `seen`, not stuck `quarantined`
  # (a terminal state route_files() never re-decides), or a later real run
  # would silently skip it forever instead of resolving the tie for real.
  dry_state <- ingest_file_states(setup$db_path)
  dry_row <- dry_state[!is.na(dry_state$hash) & dry_state$hash == bait_hash, ]
  expect_equal(nrow(dry_row), 1)
  expect_identical(dry_row$state, "seen")

  before_review <- count_rows(setup$db_path, "review_queue")
  suppressMessages(ingest_dir(input_dir, db = setup$db_path, dry_run = FALSE))
  after_review <- count_rows(setup$db_path, "review_queue")

  real_state <- ingest_file_states(setup$db_path)
  real_row <- real_state[!is.na(real_state$hash) & real_state$hash == bait_hash, ]
  expect_equal(nrow(real_row), 1)
  expect_identical(real_row$state, "quarantined")
  expect_identical(real_row$state_reason, "adapter_tie")
  expect_equal(after_review, before_review + 1)

  con <- DBI::dbConnect(duckdb::duckdb(), setup$db_path, read_only = TRUE)
  queue <- DBI::dbGetQuery(con, "SELECT kind, status FROM review_queue WHERE kind = 'adapter_tie'")
  DBI::dbDisconnect(con, shutdown = TRUE)
  expect_equal(nrow(queue), 1)
  expect_identical(queue$status[[1]], "open")
})

test_that("R-3.5/T1.2: an unclaimed file writes nothing terminal under dry_run, and a later real run still quarantines it", {
  setup <- ingest_test_setup()
  input_dir <- withr::local_tempdir()

  # No built-in adapter claims a bare `.xyz` file (esdat/crosstab require a
  # matching extension, acirl-field requires xls/xlsx) - a real verdict of
  # `unclaimed`, not a fixture artefact.
  nobody <- st_test_write_file(input_dir, "NOBODY_WANTS_THIS_0.xyz", content = "irrelevant")
  nobody_hash <- hash_file(nobody)

  expect_dry_run_writes_nothing_but_routing(setup$db_path, function() {
    suppressMessages(ingest_dir(input_dir, db = setup$db_path, dry_run = TRUE))
  })

  # the verdict is not merely un-persisted in aggregate (the row-count guard
  # above) - the hash itself must still be at `seen`, not stuck `quarantined`
  # (a terminal state route_files() never re-decides), or adding/fixing an
  # adapter later could never reclaim this file.
  dry_state <- ingest_file_states(setup$db_path)
  dry_row <- dry_state[!is.na(dry_state$hash) & dry_state$hash == nobody_hash, ]
  expect_equal(nrow(dry_row), 1)
  expect_identical(dry_row$state, "seen")

  suppressMessages(ingest_dir(input_dir, db = setup$db_path, dry_run = FALSE))

  real_state <- ingest_file_states(setup$db_path)
  real_row <- real_state[!is.na(real_state$hash) & real_state$hash == nobody_hash, ]
  expect_equal(nrow(real_row), 1)
  expect_identical(real_row$state, "quarantined")
  expect_identical(real_row$state_reason, "unclaimed")
})

test_that("R-3.5/T1.2/R-12.1: a match() crash writes nothing terminal under dry_run, and a later real run still marks the file failed", {
  setup <- ingest_test_setup()
  input_dir <- withr::local_tempdir()

  thrower_id <- "t8b_dryrun_thrower"
  register_adapter(list(
    id = thrower_id, version = "1.0",
    match = function(fm) if (grepl("CRASHME", fm$filename)) stop("kaboom from match()") else "no",
    parse = function(path, file_meta) stop("never called: file is failed, not claimed")
  ))
  withr::defer({
    if (exists(thrower_id, envir = sampleTidy:::.st_adapter_registry, inherits = FALSE)) {
      rm(list = thrower_id, envir = sampleTidy:::.st_adapter_registry)
    }
  })

  crashy <- st_test_write_file(input_dir, "CRASHME_0.csv", content = "a,b\n1,2\n")
  crashy_hash <- hash_file(crashy)

  expect_dry_run_writes_nothing_but_routing(setup$db_path, function() {
    suppressMessages(ingest_dir(input_dir, db = setup$db_path, dry_run = TRUE))
  })

  # as above: the row itself must still be `seen`, not stuck `failed` - a
  # buggy adapter fixed after a dry-run preview must not have permanently
  # condemned every file it crashed on while the bug was live.
  dry_state <- ingest_file_states(setup$db_path)
  dry_row <- dry_state[!is.na(dry_state$hash) & dry_state$hash == crashy_hash, ]
  expect_equal(nrow(dry_row), 1)
  expect_identical(dry_row$state, "seen")

  suppressMessages(ingest_dir(input_dir, db = setup$db_path, dry_run = FALSE))

  real_state <- ingest_file_states(setup$db_path)
  real_row <- real_state[!is.na(real_state$hash) & real_state$hash == crashy_hash, ]
  expect_equal(nrow(real_row), 1)
  expect_identical(real_row$state, "failed")
  expect_match(real_row$state_reason, "kaboom from match()", fixed = TRUE)
})

test_that("R-9.5: an adapter crash on one file is recorded as failed and the run completes", {
  setup <- ingest_test_setup()
  input_dir <- withr::local_tempdir()
  corrupt_src <- testthat::test_path("fixtures", "esdat", "CORRUPT.ESDAT_XX0000000_0.Chemistry2e.CSV")
  expect_true(file.exists(corrupt_src), info = "corrupted ESdat fixture must exist per PLAN-04/FIXTURES.md")
  file.copy(corrupt_src, file.path(input_dir, basename(corrupt_src)))

  expect_no_error(report <- ingest_dir(input_dir, db = setup$db_path))
  states <- ingest_file_states(setup$db_path)
  corrupt_state <- states[!is.na(states$filename) & states$filename == basename(corrupt_src), ]  # NA-safe, A43
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

test_that("R-9.5: two same-byte files in ONE run (a [N] duplicate-download pair) ingest once, without aborting (A46)", {
  setup <- ingest_test_setup()
  input_dir <- build_e2e_input_dir()

  # Reproduces the real-corpus case that exposed A46: a browser
  # duplicate-download twin (`foo[65].CSV`) sitting beside its original in
  # the same directory. `ignore_rule()` passes `[N]` names through on
  # purpose, so both paths reach the parse stage carrying identical bytes.
  original <- list.files(input_dir, pattern = "Chemistry2e\\.CSV$", full.names = TRUE)[[1]]
  twin <- file.path(input_dir, sub("\\.CSV$", "[65].CSV", basename(original)))
  file.copy(original, twin)

  expect_no_error(report <- ingest_dir(input_dir, db = setup$db_path))

  states <- ingest_file_states(setup$db_path)
  twin_hash <- sampleTidy:::hash_file(twin)

  # One ingest_file row per distinct content hash, not per path...
  expect_equal(sum(states$hash == twin_hash), 1L)
  # ...and the duplicate is recorded as a sighting of the same content (A20).
  sightings <- count_rows(setup$db_path, "ingest_sighting")
  expect_true(sightings > 0)
  expect_false(states$state[states$hash == twin_hash] %in% c("failed", "quarantined"))
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
  # Exclude the seeded legacy-hash-XX row (state 'archived', filename NA, no
  # asset of its own) so we tamper with a file actually committed this run (A43).
  committed <- states[!is.na(states$filename) & states$state %in% c("committed", "archived"), ]
  expect_gt(nrow(committed), 0)
  tampered_hash <- committed$hash[[1]]
  tampered_filename <- committed$filename[[1]]

  con <- DBI::dbConnect(duckdb::duckdb(), setup$db_path, read_only = TRUE)
  asset_row <- DBI::dbGetQuery(con, sprintf("SELECT * FROM asset WHERE hash = '%s'", tampered_hash))
  DBI::dbDisconnect(con, shutdown = TRUE)
  expect_gt(nrow(asset_row), 0)
  # Tamper with the archived FILE itself (leaving the uuid directory behind) -
  # matches how .ig_remove_verified() must actually detect the loss (a
  # directory removal here would silently no-op via file.remove() and never
  # exercise the guard at all).
  copy_path <- file.path(setup$archive_dir, asset_row$uuid[[1]], asset_row$filename[[1]])
  expect_true(file.exists(copy_path))
  file.remove(copy_path)

  # A second committing input is required so pass 2 actually snapshots and
  # runs the removal path at all (removal is gated on a snapshot happening -
  # see R/ingest.R .ig_current_states()/snapshot gate); otherwise this test
  # would pass vacuously without ever calling .ig_remove_verified(). A
  # crosstab fixture (unrelated work order/adapter to the esdat pass-1 set)
  # parses and commits cleanly on its own.
  crosstab_dir <- testthat::test_path("fixtures", "crosstab")
  file.copy(file.path(crosstab_dir, "ES2600185_0_XTAB.csv"),
            file.path(input_dir, "ES2600185_0_XTAB.csv"))

  withr::local_options(list("sampletidy.remove_ingested" = TRUE))
  ingest_dir(input_dir, db = setup$db_path)

  # the file whose archive copy is missing must still be present...
  expect_true(file.exists(file.path(input_dir, tampered_filename)))
  # ...while at least one intact-archive sibling actually WAS removed, proving
  # the removal path really executed rather than the test passing because
  # nothing ran.
  states_after <- ingest_file_states(setup$db_path)
  siblings <- states_after[!is.na(states_after$filename) &
                              states_after$state %in% c("committed", "archived") &
                              states_after$filename != tampered_filename, ]
  expect_gt(nrow(siblings), 0)
  expect_true(any(!file.exists(file.path(input_dir, siblings$filename))))
})

test_that("direct: .ig_remove_verified() removes the source only when the archived FILE (not just its uuid dir) exists", {
  db_path <- seed_db(dir = withr::local_tempdir())
  con <- seed_con(db_path)
  ensure_test_asset_table(con)
  DBI::dbDisconnect(con, shutdown = TRUE)

  archive_dir <- withr::local_tempdir()
  withr::local_options(list("sampletidy.archive_dir" = archive_dir))

  src_dir <- withr::local_tempdir()
  src <- file.path(src_dir, "direct_removal_test.csv")
  writeLines("a,b\n1,2\n", src)
  h <- hash_file(src)
  uuid <- "u-direct-removal-test"

  con2 <- DBI::dbConnect(duckdb::duckdb(), db_path, read_only = FALSE)
  DBI::dbExecute(
    con2,
    "INSERT INTO asset (uuid, filename, hash) VALUES (?, ?, ?)",
    params = list(uuid, basename(src), h)
  )
  DBI::dbDisconnect(con2, shutdown = TRUE)

  uuid_dir <- file.path(archive_dir, uuid)
  dir.create(uuid_dir, recursive = FALSE)
  archived_file <- file.path(uuid_dir, basename(src))
  writeLines("a,b\n1,2\n", archived_file)

  routed <- tibble::tibble(path = src, hash = h)

  # Case A: verified archive FILE present -> source is removed.
  removed_a <- sampleTidy:::.ig_remove_verified(db_path, routed)
  expect_identical(removed_a, src)
  expect_false(file.exists(src))

  # Case B: archived FILE removed, but the uuid DIRECTORY still survives -
  # this is exactly the A13/R-9.6 data-loss scenario: a file.exists() check
  # on the directory would wrongly report "verified" and the source would
  # be deleted, leaving zero copies of the data anywhere.
  writeLines("a,b\n1,2\n", src) # recreate the source
  file.remove(archived_file)
  expect_true(dir.exists(uuid_dir))
  expect_false(file.exists(archived_file))

  expect_warning(
    removed_b <- sampleTidy:::.ig_remove_verified(db_path, routed),
    "archive copy"
  )
  expect_identical(removed_b, character(0))
  expect_true(file.exists(src))
})

test_that("direct: .ig_remove_verified() keeps the source when the archive copy EXISTS but its CONTENT differs", {
  # The archive lives on OneDrive, where a dehydrated placeholder, a truncated
  # upload or a conflicted rewrite is still a regular file of the right name.
  # An existence-only check would delete the source and leave corrupt bytes as
  # the only remaining copy.
  db_path <- seed_db(dir = withr::local_tempdir())
  con <- seed_con(db_path)
  ensure_test_asset_table(con)
  DBI::dbDisconnect(con, shutdown = TRUE)

  archive_dir <- withr::local_tempdir()
  withr::local_options(list("sampletidy.archive_dir" = archive_dir))

  src_dir <- withr::local_tempdir()
  src <- file.path(src_dir, "content_check_test.csv")
  writeLines("a,b\n1,2\n", src)
  h <- hash_file(src)
  uuid <- "u-content-check-test"

  con2 <- DBI::dbConnect(duckdb::duckdb(), db_path, read_only = FALSE)
  DBI::dbExecute(
    con2,
    "INSERT INTO asset (uuid, filename, hash) VALUES (?, ?, ?)",
    params = list(uuid, basename(src), h)
  )
  DBI::dbDisconnect(con2, shutdown = TRUE)

  uuid_dir <- file.path(archive_dir, uuid)
  dir.create(uuid_dir, recursive = FALSE)
  archived_file <- file.path(uuid_dir, basename(src))

  routed <- tibble::tibble(path = src, hash = h)

  # Case A: a TRUNCATED archive copy (0 bytes) - the placeholder scenario.
  file.create(archived_file)
  expect_true(utils::file_test("-f", archived_file))
  expect_warning(
    removed_empty <- sampleTidy:::.ig_remove_verified(db_path, routed),
    "does NOT match"
  )
  expect_identical(removed_empty, character(0))
  expect_true(file.exists(src))

  # Case B: a same-size-ish but DIFFERENT archive copy.
  writeLines("a,b\n9,9\n", archived_file)
  expect_false(identical(hash_file(archived_file), h))
  expect_warning(
    removed_wrong <- sampleTidy:::.ig_remove_verified(db_path, routed),
    "does NOT match"
  )
  expect_identical(removed_wrong, character(0))
  expect_true(file.exists(src))

  # Case C: correct bytes -> the source is removed, proving A and B were
  # blocked by the CONTENT check and not by some unrelated failure.
  writeLines("a,b\n1,2\n", archived_file)
  expect_identical(hash_file(archived_file), h)
  expect_identical(sampleTidy:::.ig_remove_verified(db_path, routed), src)
  expect_false(file.exists(src))
})

# ---- R-12.1: adapter match() return-value validation, contained (F6) ------

test_that("R-12.1: an ingest run containing one file whose adapter match() returns NA still commits the other good files (per-file containment, not a whole-run abort)", {
  setup <- ingest_test_setup()
  input_dir <- build_e2e_input_dir()

  bad_adapter_id <- "r121_bad_na_adapter"
  register_adapter(list(
    id = bad_adapter_id, version = "1.0",
    match = function(fm) if (grepl("R121BADFILE", fm$filename)) NA_character_ else "no",
    parse = function(path, file_meta) list(results = ir_results(), samples = ir_samples(), report = list())
  ))
  withr::defer({
    if (exists(bad_adapter_id, envir = sampleTidy:::.st_adapter_registry, inherits = FALSE)) {
      rm(list = bad_adapter_id, envir = sampleTidy:::.st_adapter_registry)
    }
  })

  st_test_write_file(input_dir, "R121BADFILE_0.csv", content = "a,b\n1,2\n")

  expect_no_error(report <- ingest_dir(input_dir, db = setup$db_path))

  states <- ingest_file_states(setup$db_path)
  bad_state <- states[!is.na(states$filename) & states$filename == "R121BADFILE_0.csv", ]
  expect_equal(nrow(bad_state), 1)
  expect_identical(bad_state$state, "failed")
  expect_match(bad_state$state_reason, bad_adapter_id, fixed = TRUE)

  # the good fixture files still land in real terminal states, unaffected by
  # the third-party adapter's bad return value on the unrelated marker file
  good_states <- states[!states$filename %in% c("old_export.bak", ".DS_Store", "R121BADFILE_0.csv"), ]
  expect_true(nrow(good_states) > 0)
  expect_true(all(good_states$state %in%
    c("committed", "archived", "ignored", "quarantined", "failed", "needs_review")))
  expect_true(any(good_states$state %in% c("committed", "archived")))
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

# ---- R-12.2: per-event containment in the ingest loop (F7, A60) -----------
#
# NOTE (PLAN-12 sequencing): reconcile.R still queries the dropped
# `sample.uuid_feature` column (owned by P11-reconcile, not this unit), so
# ANY real event with clean rows currently aborts the instant the real
# `reconcile_event()`/`commit_event()` run over real fixture data - entirely
# independently of whether R-12.2's own containment logic exists yet. To
# isolate the criterion actually under test here (does `ingest_dir()`
# contain a per-event reconcile/commit failure, and does a 100%-failure run
# abort loudly) from that unrelated, already-tracked red, both tests below
# mock `reconcile_event()`/`commit_event()` at the `ingest_dir()` boundary -
# the same fault-injection idiom already used for `snapshot_db()` in the
# R-9.6 tests above - rather than depending on the currently-broken real
# reconcile/commit path. `route_files()`/parse/`assemble_events()` before
# that point are real (real fixtures, real `event$files`).

test_that("R-12.2: a per-event reconcile failure is contained - the poisoned event's kept files are marked failed with events_failed counted and a cli_warn names it, while sibling events still reach committed/archived terminal states", {
  setup <- ingest_test_setup()
  input_dir <- build_e2e_input_dir()

  call_n <- 0L
  poisoned_hashes <- character(0)
  ok_resolved <- list(
    clean = tibble::tibble(source_ref = character(0)),
    skipped = tibble::tibble(source_ref = character(0), reason = character(0)),
    review = tibble::tibble()
  )
  testthat::local_mocked_bindings(
    reconcile_event = function(event, con) {
      call_n <<- call_n + 1L
      if (call_n == 1L) {
        poisoned_hashes <<- event$files$hash[sampleTidy:::.ig_kept_rows(event$files)]
        stop("R-12.2 injected reconcile failure")
      }
      ok_resolved
    },
    commit_event = function(event, resolved, con) {
      for (h in event$files$hash[sampleTidy:::.ig_kept_rows(event$files)]) {
        ingest_file_set_state(con, h, "committed", reset = TRUE)
      }
      invisible(NULL)
    }
  )

  expect_warning(
    report <- ingest_dir(input_dir, db = setup$db_path),
    regexp = "R-12.2 injected reconcile failure",
    fixed = TRUE
  )

  expect_true(length(poisoned_hashes) > 0)
  states <- ingest_file_states(setup$db_path)
  poisoned_states <- states[states$hash %in% poisoned_hashes, ]
  expect_true(nrow(poisoned_states) > 0)
  expect_true(all(poisoned_states$state == "failed"))
  expect_true(all(grepl("R-12.2 injected reconcile failure", poisoned_states$state_reason, fixed = TRUE)))

  expect_identical(report$events_failed, 1L)

  # sibling events (kept files belonging to any OTHER event) still reach a
  # real commit terminal state - the poison event does not block the run.
  sibling_states <- states[!states$hash %in% poisoned_hashes &
                              !states$filename %in% c("old_export.bak", ".DS_Store"), ]
  expect_true(nrow(sibling_states) > 0)
  expect_true(any(sibling_states$state == "committed"))
  expect_true(call_n > 1)
})

test_that("R-12.2: when EVERY event throws in reconcile, ingest_dir() still contains each one (failed + counted) during the loop, then aborts class sampletidy_error after the loop - not a quiet all-failed report and not a bare abort on the first failure", {
  setup <- ingest_test_setup()
  input_dir <- build_e2e_input_dir()

  call_n <- 0L
  event_kept_hashes <- character(0)
  testthat::local_mocked_bindings(
    reconcile_event = function(event, con) {
      call_n <<- call_n + 1L
      event_kept_hashes <<- c(
        event_kept_hashes, event$files$hash[sampleTidy:::.ig_kept_rows(event$files)]
      )
      stop("R-12.2 injected systemic reconcile failure ", call_n)
    }
  )

  caught <- NULL
  warnings_seen <- 0L
  withCallingHandlers(
    tryCatch(
      ingest_dir(input_dir, db = setup$db_path),
      error = function(e) caught <<- e
    ),
    warning = function(w) {
      warnings_seen <<- warnings_seen + 1L
      invokeRestart("muffleWarning")
    }
  )

  # the loop reached every event (not a bare abort on the first failure) ...
  expect_true(call_n > 1,
    info = "abort must happen AFTER the per-event loop, not on the first thrown event")
  expect_true(warnings_seen >= call_n)
  # ... and the run still surfaces the systemic wipe-out loudly.
  expect_false(is.null(caught))
  expect_s3_class(caught, "sampletidy_error")

  states <- ingest_file_states(setup$db_path)
  # every kept file of every event was contained (marked failed) before the
  # abort fired - not left mid-pipeline, and not silently reported as a quiet
  # all-failed report (the abort itself is the loud signal). Assert this
  # against the EXACT set of hashes that entered an event (captured in the
  # mock), not a filename/state heuristic: files that never joined an event -
  # route-time `quarantined` cruft (random.csv, random.xlsx, NOT_ESDAT.xml,
  # ES2600185_0_XTAB.XLS), assemble-stage supersede-dropped `ignored`
  # sources, and the seeded legacy `archived` row - are legitimately not
  # `failed` and must not be swept into this check.
  event_states <- states[states$hash %in% unique(event_kept_hashes), ]
  expect_true(nrow(event_states) > 0)
  expect_true(all(event_states$state == "failed"))
})

# ---- R-12.7: ingest report uses terminal file states (F13) ----------------
#
# Same isolation note as R-12.2 above: `reconcile_event()`/`commit_event()`
# are mocked to produce a controlled, real `ingest_file` terminal state (via
# the real `ingest_file_set_state()`) so `.ig_build_report()`'s own
# re-querying behaviour can be asserted independently of the unrelated
# P11-reconcile `sample.uuid_feature` red.

test_that("R-12.7: files_by_state reports the run's real terminal state (committed) for a run that commits an event, not the route-time 'claimed' state", {
  setup <- ingest_test_setup()
  input_dir <- build_e2e_input_dir()

  ok_resolved <- list(
    clean = tibble::tibble(source_ref = character(0)),
    skipped = tibble::tibble(source_ref = character(0), reason = character(0)),
    review = tibble::tibble()
  )
  testthat::local_mocked_bindings(
    reconcile_event = function(event, con) ok_resolved,
    commit_event = function(event, resolved, con) {
      for (h in event$files$hash[sampleTidy:::.ig_kept_rows(event$files)]) {
        ingest_file_set_state(con, h, "committed", reset = TRUE)
      }
      invisible(NULL)
    }
  )

  report <- ingest_dir(input_dir, db = setup$db_path)

  expect_true(report$n_events > 0)
  expect_false("claimed" %in% names(report$files_by_state))
  expect_true("committed" %in% names(report$files_by_state))
  expect_equal(
    unname(report$files_by_state[["committed"]]),
    sum(ingest_file_states(setup$db_path)$state == "committed")
  )
})

# ---- R-15.36: non-tabular lab deliverables retained and WO-linked (F.17) --
#
# Remediates a REALISED loss, not a hypothetical: the COA/COC/QC/QCI PDFs and
# XTAB.XLS of ES2600185/ES2610538/ES2612444/ES2614070/ES2617126 were
# quarantined `unclaimed`, given no `asset` row, and are absent from the
# archive entirely - harmless while `remove_ingested` defaulted FALSE, now
# load-bearing because it defaults TRUE (A13) and deletes sources with no
# safety net for a file nothing ever claimed. Five conjuncts, all asserted,
# because each cheaper subset already passes while the defect is live: an
# `asset` row can exist unattached; an archive copy can exist unattached; a
# report can look clean while the row still sits quarantined.
#
# Three arms, all real-corpus filename shapes (verified against the live DB:
# 19 quarantined rows, 8 of them .XLS, zero matching any synthetic
# `SITEA_`-prefixed deliverable name - a deliverable PDF never carries a
# site prefix):
#   (1) ES2617126_0_COA.pdf   -> wo=ES2617126 rev=0  (the PDF baseline)
#   (2) ES2617126_COC.pdf     -> wo=ES2617126 rev=NA (the ONLY shape
#       yielding NA; guards against a sibling sweep that filters on
#       `revision == event revision`, which would silently drop this file
#       and still pass conjuncts on the arm-1 fixture alone)
#   (3) ES2617126_0_XTAB.XLS  -> wo=ES2617126 rev=0  (non-PDF deliverable;
#       8 of the 19 real quarantined files are .XLS, and B-15.F17 names
#       XTAB.XLS explicitly; a retain predicate of `ext == "pdf"` would
#       re-lose all eight)

test_that("R-15.36: a work order's non-tabular deliverable (a COA PDF) gets an asset row, a byte-identical archive copy, is reachable from its work order, is removed only after that, and the run reports zero quarantined for it", {
  setup <- ingest_test_setup()
  withr::local_options(list("sampletidy.remove_ingested" = TRUE))

  input_dir <- withr::local_tempdir()
  esdat_dir <- testthat::test_path("fixtures", "esdat")
  wo_files <- list.files(esdat_dir, pattern = "ES2617126", full.names = TRUE)
  expect_true(length(wo_files) == 3,
              info = "ES2617126 esdat fixture triple (Chemistry2e/Sample2e/Header.XML) must exist")
  for (f in wo_files) file.copy(f, file.path(input_dir, basename(f)))

  # The non-tabular sibling this criterion is about - modelled on the real
  # loss (COA/COC/QC/QCI PDFs + XTAB.XLS of the five named work orders, all
  # quarantined then deleted). No adapter claims a PDF today (F.17), so
  # pre-fix this sits `quarantined`/`unclaimed` with no `asset` row.
  # ES2617126_0_COA.pdf is the real-corpus filename shape (work order,
  # revision, deliverable kind) - not a synthetic SITEA_-prefixed name.
  coa_path <- file.path(input_dir, "ES2617126_0_COA.pdf")
  coa_bytes <- charToRaw(paste(
    c("%PDF-1.4 fake Certificate of Analysis for work order ES2617126",
      sprintf("line %02d: non-trivial filler so this is not a degenerate file", 1:20)),
    collapse = "\n"
  ))
  writeBin(coa_bytes, coa_path)

  # Prove the identity check can produce a POSITIVE before trusting any
  # negative result from it (CONTRACT A5: xxHash128 via hash_file(), a
  # 32-char hex digest - NOT SHA-256/64 chars; a length-mismatched digest
  # comparison silently and permanently fails, which already produced a
  # wrong "0 of 1,272 recoverable" conclusion elsewhere in this project).
  # Two copies of the SAME bytes must hash equal; different bytes must not.
  coa_copy_for_positive_control <- withr::local_tempfile()
  writeBin(coa_bytes, coa_copy_for_positive_control)
  expect_identical(nchar(hash_file(coa_path)), 32L)
  expect_identical(hash_file(coa_path), hash_file(coa_copy_for_positive_control))
  different_bytes_path <- withr::local_tempfile()
  writeBin(charToRaw("definitely different bytes, not a COA"), different_bytes_path)
  expect_false(identical(hash_file(coa_path), hash_file(different_bytes_path)))

  # Preserve the pre-ingest hash/bytes - conjunct (4) below deletes the
  # source file itself.
  coa_hash <- hash_file(coa_path)
  coa_bytes_preserved <- readBin(coa_path, "raw", n = file.size(coa_path))

  report <- ingest_dir(input_dir, db = setup$db_path)

  con <- DBI::dbConnect(duckdb::duckdb(), setup$db_path, read_only = TRUE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  # (1) an `asset` row exists for the PDF's OWN content hash - not merely for
  # its tabular siblings.
  asset_row <- DBI::dbGetQuery(con, "SELECT * FROM asset WHERE hash = ?", params = list(coa_hash))
  expect_equal(nrow(asset_row), 1,
               info = "R-15.36 conjunct 1: the COA PDF must get its own asset row")
  # Round-2 item 6 (Robin's ruling 3): a COA gets asset.type = "Certificate
  # of analysis", not the blanket "Chemical analysis" every tabular asset
  # gets - it is evidence, not chemistry data.
  if (nrow(asset_row) == 1) {
    expect_identical(asset_row$type[[1]], "Certificate of analysis")
  }

  # (2) the archived copy is byte-identical to the source. New-ingest code
  # writes only the nested layout <archive_dir>/<uuid>/<filename> (F.18 owns
  # reading the legacy flat layout, not writing this one). Guarded against a
  # missing/absent asset row (conjunct 1 above may already have failed) so
  # this reports as a clean, informative failure rather than an unguarded
  # subscript-out-of-bounds R error masking the real red reason.
  asset_uuid <- if (nrow(asset_row) == 1) asset_row$uuid[[1]] else NA_character_
  asset_filename <- if (nrow(asset_row) == 1) asset_row$filename[[1]] else NA_character_
  archived_path <- if (!is.na(asset_uuid) && !is.na(asset_filename)) {
    file.path(setup$archive_dir, asset_uuid, asset_filename)
  } else {
    NA_character_
  }
  archive_copy_present <- !is.na(archived_path) && utils::file_test("-f", archived_path)
  expect_true(archive_copy_present,
              info = "R-15.36 conjunct 2: archived copy must exist as a regular file")
  if (archive_copy_present) {
    archived_bytes <- readBin(archived_path, "raw", n = file.size(archived_path))
    expect_identical(archived_bytes, coa_bytes_preserved)
    expect_identical(hash_file(archived_path), coa_hash)
  }

  # (3) the row is REACHABLE from its work order - a bare asset-row count
  # would pass while the PDF sat unclaimed/unattached. `archive_file()`
  # already resolves an event's project via `event$work_order` ->
  # `project.name`, so "reachable from the work order" means this asset's
  # `uuid_project` resolves to the project row named for ES2617126, exactly
  # like every tabular asset of the same event already does.
  linked <- DBI::dbGetQuery(
    con,
    "SELECT a.hash FROM asset a JOIN project p ON a.uuid_project = p.uuid
     WHERE p.name = 'ES2617126' AND a.hash = ?",
    params = list(coa_hash)
  )
  expect_equal(nrow(linked), 1,
               info = "R-15.36 conjunct 3: the asset row must be reachable from work order ES2617126, not merely exist")

  # (4) a remove_ingested pass deletes the source - but only after (1)-(3)
  # above are already true, i.e. only once a verified, WO-linked copy
  # exists (the same guard .ig_remove_verified() already enforces for
  # tabular assets, reused here rather than re-derived).
  expect_false(file.exists(coa_path),
               info = "R-15.36 conjunct 4: remove_ingested = TRUE must delete the now-archived+linked source")

  # (5) the run reports ZERO quarantined files for this event - a test that
  # stopped at (1)-(4) would still pass while the PDF's ingest_file row sat
  # quarantined/unclaimed beside a stray retained-but-unclaimed copy. This
  # does NOT collide with A10 (ACIRL dust sheets route to `ignored`, not
  # `quarantined`) - adjudicated already, not re-derived here.
  quarantined_n <- if ("quarantined" %in% names(report$files_by_state)) {
    unname(report$files_by_state[["quarantined"]])
  } else {
    0L
  }
  expect_equal(quarantined_n, 0L,
               info = "R-15.36 conjunct 5: the run must report zero quarantined files for this event")

  states <- ingest_file_states(setup$db_path)
  # NA-safe filter (A43): hash is never NA for a routed file, but match the
  # project's established idiom rather than a bare `==`.
  coa_state <- states[!is.na(states$hash) & states$hash == coa_hash, ]
  expect_equal(nrow(coa_state), 1)
  expect_false(identical(coa_state$state[[1]], "quarantined"))
})

test_that("R-15.36: a work order's revision-less deliverable (a COC PDF, the ONLY shape parsing to revision=NA) gets an asset row, a byte-identical archive copy, is reachable from its work order, is removed only after that, and the run reports zero quarantined for it", {
  setup <- ingest_test_setup()
  withr::local_options(list("sampletidy.remove_ingested" = TRUE))

  input_dir <- withr::local_tempdir()
  esdat_dir <- testthat::test_path("fixtures", "esdat")
  wo_files <- list.files(esdat_dir, pattern = "ES2617126", full.names = TRUE)
  expect_true(length(wo_files) == 3,
              info = "ES2617126 esdat fixture triple (Chemistry2e/Sample2e/Header.XML) must exist")
  for (f in wo_files) file.copy(f, file.path(input_dir, basename(f)))

  # ES2617126_COC.pdf is the real-corpus revision-less deliverable shape -
  # verified against the real production parser: ES2617126_COC.pdf ->
  # wo=ES2617126 rev=NA, the only shape yielding NA. A sibling sweep that
  # filters on `revision == event revision` (a natural implementation) would
  # silently drop this file and still pass the COA arm above in full.
  coc_path <- file.path(input_dir, "ES2617126_COC.pdf")
  coc_bytes <- charToRaw(paste(
    c("%PDF-1.4 fake Chain of Custody for work order ES2617126",
      sprintf("line %02d: non-trivial filler so this is not a degenerate file", 1:20)),
    collapse = "\n"
  ))
  writeBin(coc_bytes, coc_path)

  # Prove the identity check can produce a POSITIVE before trusting any
  # negative result from it (CONTRACT A5: xxHash128 via hash_file(), a
  # 32-char hex digest - NOT SHA-256/64 chars).
  coc_copy_for_positive_control <- withr::local_tempfile()
  writeBin(coc_bytes, coc_copy_for_positive_control)
  expect_identical(nchar(hash_file(coc_path)), 32L)
  expect_identical(hash_file(coc_path), hash_file(coc_copy_for_positive_control))
  different_bytes_path <- withr::local_tempfile()
  writeBin(charToRaw("definitely different bytes, not a COC"), different_bytes_path)
  expect_false(identical(hash_file(coc_path), hash_file(different_bytes_path)))

  # Preserve the pre-ingest hash/bytes - conjunct (4) below deletes the
  # source file itself.
  coc_hash <- hash_file(coc_path)
  coc_bytes_preserved <- readBin(coc_path, "raw", n = file.size(coc_path))

  report <- ingest_dir(input_dir, db = setup$db_path)

  con <- DBI::dbConnect(duckdb::duckdb(), setup$db_path, read_only = TRUE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  # (1) an `asset` row exists for the COC PDF's OWN content hash - not
  # merely for its tabular siblings.
  asset_row <- DBI::dbGetQuery(con, "SELECT * FROM asset WHERE hash = ?", params = list(coc_hash))
  expect_equal(nrow(asset_row), 1,
               info = "R-15.36 conjunct 1: the COC PDF (revision=NA) must get its own asset row")
  # Round-2 item 6: a COC is NOT a COA and must NOT be widened to
  # "Certificate of analysis". That still holds. What has changed is the
  # fallback: this assertion used to pin the PARKED default
  # ("Chemical analysis", pending a ruling), and Robin made the ruling on
  # 2026-07-28 (R-15.36b) - a chain of custody is a QA record, not a result,
  # so it is now "QA" against the live table's existing vocabulary. The
  # negative half of the original assertion is what mattered and is unchanged.
  if (nrow(asset_row) == 1) {
    expect_identical(asset_row$type[[1]], "QA")
    expect_false(identical(asset_row$type[[1]], "Certificate of analysis"))
  }

  # (2) the archived copy is byte-identical to the source.
  asset_uuid <- if (nrow(asset_row) == 1) asset_row$uuid[[1]] else NA_character_
  asset_filename <- if (nrow(asset_row) == 1) asset_row$filename[[1]] else NA_character_
  archived_path <- if (!is.na(asset_uuid) && !is.na(asset_filename)) {
    file.path(setup$archive_dir, asset_uuid, asset_filename)
  } else {
    NA_character_
  }
  archive_copy_present <- !is.na(archived_path) && utils::file_test("-f", archived_path)
  expect_true(archive_copy_present,
              info = "R-15.36 conjunct 2: archived copy must exist as a regular file")
  if (archive_copy_present) {
    archived_bytes <- readBin(archived_path, "raw", n = file.size(archived_path))
    expect_identical(archived_bytes, coc_bytes_preserved)
    expect_identical(hash_file(archived_path), coc_hash)
  }

  # (3) the row is REACHABLE from its work order.
  linked <- DBI::dbGetQuery(
    con,
    "SELECT a.hash FROM asset a JOIN project p ON a.uuid_project = p.uuid
     WHERE p.name = 'ES2617126' AND a.hash = ?",
    params = list(coc_hash)
  )
  expect_equal(nrow(linked), 1,
               info = "R-15.36 conjunct 3: the asset row must be reachable from work order ES2617126, not merely exist")

  # (4) a remove_ingested pass deletes the source - but only after (1)-(3)
  # above are already true.
  expect_false(file.exists(coc_path),
               info = "R-15.36 conjunct 4: remove_ingested = TRUE must delete the now-archived+linked source")

  # (5) the run reports ZERO quarantined files for this event.
  quarantined_n <- if ("quarantined" %in% names(report$files_by_state)) {
    unname(report$files_by_state[["quarantined"]])
  } else {
    0L
  }
  expect_equal(quarantined_n, 0L,
               info = "R-15.36 conjunct 5: the run must report zero quarantined files for this event")

  states <- ingest_file_states(setup$db_path)
  # NA-safe filter (A43): hash is never NA for a routed file, but match the
  # project's established idiom rather than a bare `==`.
  coc_state <- states[!is.na(states$hash) & states$hash == coc_hash, ]
  expect_equal(nrow(coc_state), 1)
  expect_false(identical(coc_state$state[[1]], "quarantined"))
})

test_that("R-15.36: a work order's non-PDF non-tabular deliverable (an XTAB.XLS) gets an asset row, a byte-identical archive copy, is reachable from its work order, is removed only after that, and the run reports zero quarantined for it", {
  setup <- ingest_test_setup()
  withr::local_options(list("sampletidy.remove_ingested" = TRUE))

  input_dir <- withr::local_tempdir()
  esdat_dir <- testthat::test_path("fixtures", "esdat")
  wo_files <- list.files(esdat_dir, pattern = "ES2617126", full.names = TRUE)
  expect_true(length(wo_files) == 3,
              info = "ES2617126 esdat fixture triple (Chemistry2e/Sample2e/Header.XML) must exist")
  for (f in wo_files) file.copy(f, file.path(input_dir, basename(f)))

  # ES2617126_0_XTAB.XLS is the real-corpus non-PDF deliverable shape. 8 of
  # the 19 real quarantined files are .XLS, and B-15.F17 names XTAB.XLS
  # explicitly twice. A retain predicate of `ext == "pdf"` would pass every
  # other conjunct in this file while re-losing all eight of these. This is
  # also the riskiest arm: als_xtab already has an opinion about this
  # extension, so it must not silently claim and mis-route this file either.
  xtab_path <- file.path(input_dir, "ES2617126_0_XTAB.XLS")
  xtab_bytes <- charToRaw(paste(
    c("fake non-SpreadsheetML XTAB.XLS filler for work order ES2617126",
      sprintf("line %02d: non-trivial filler so this is not a degenerate file", 1:20)),
    collapse = "\n"
  ))
  writeBin(xtab_bytes, xtab_path)

  # Prove the identity check can produce a POSITIVE before trusting any
  # negative result from it (CONTRACT A5: xxHash128 via hash_file(), a
  # 32-char hex digest - NOT SHA-256/64 chars).
  xtab_copy_for_positive_control <- withr::local_tempfile()
  writeBin(xtab_bytes, xtab_copy_for_positive_control)
  expect_identical(nchar(hash_file(xtab_path)), 32L)
  expect_identical(hash_file(xtab_path), hash_file(xtab_copy_for_positive_control))
  different_bytes_path <- withr::local_tempfile()
  writeBin(charToRaw("definitely different bytes, not this XTAB.XLS"), different_bytes_path)
  expect_false(identical(hash_file(xtab_path), hash_file(different_bytes_path)))

  # Preserve the pre-ingest hash/bytes - conjunct (4) below deletes the
  # source file itself.
  xtab_hash <- hash_file(xtab_path)
  xtab_bytes_preserved <- readBin(xtab_path, "raw", n = file.size(xtab_path))

  report <- ingest_dir(input_dir, db = setup$db_path)

  con <- DBI::dbConnect(duckdb::duckdb(), setup$db_path, read_only = TRUE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  # (1) an `asset` row exists for the XTAB.XLS's OWN content hash - not
  # merely for its tabular siblings.
  asset_row <- DBI::dbGetQuery(con, "SELECT * FROM asset WHERE hash = ?", params = list(xtab_hash))
  expect_equal(nrow(asset_row), 1,
               info = "R-15.36 conjunct 1: the non-PDF XTAB.XLS deliverable must get its own asset row")
  # Round-2 item 6: XTAB.XLS is NOT a COA - it must NOT be widened to
  # "Certificate of analysis" without a separate ruling; it keeps the
  # existing default.
  if (nrow(asset_row) == 1) {
    expect_identical(asset_row$type[[1]], "Chemical analysis")
  }

  # (2) the archived copy is byte-identical to the source.
  asset_uuid <- if (nrow(asset_row) == 1) asset_row$uuid[[1]] else NA_character_
  asset_filename <- if (nrow(asset_row) == 1) asset_row$filename[[1]] else NA_character_
  archived_path <- if (!is.na(asset_uuid) && !is.na(asset_filename)) {
    file.path(setup$archive_dir, asset_uuid, asset_filename)
  } else {
    NA_character_
  }
  archive_copy_present <- !is.na(archived_path) && utils::file_test("-f", archived_path)
  expect_true(archive_copy_present,
              info = "R-15.36 conjunct 2: archived copy must exist as a regular file")
  if (archive_copy_present) {
    archived_bytes <- readBin(archived_path, "raw", n = file.size(archived_path))
    expect_identical(archived_bytes, xtab_bytes_preserved)
    expect_identical(hash_file(archived_path), xtab_hash)
  }

  # (3) the row is REACHABLE from its work order.
  linked <- DBI::dbGetQuery(
    con,
    "SELECT a.hash FROM asset a JOIN project p ON a.uuid_project = p.uuid
     WHERE p.name = 'ES2617126' AND a.hash = ?",
    params = list(xtab_hash)
  )
  expect_equal(nrow(linked), 1,
               info = "R-15.36 conjunct 3: the asset row must be reachable from work order ES2617126, not merely exist")

  # (4) a remove_ingested pass deletes the source - but only after (1)-(3)
  # above are already true.
  expect_false(file.exists(xtab_path),
               info = "R-15.36 conjunct 4: remove_ingested = TRUE must delete the now-archived+linked source")

  # (5) the run reports ZERO quarantined files for this event.
  quarantined_n <- if ("quarantined" %in% names(report$files_by_state)) {
    unname(report$files_by_state[["quarantined"]])
  } else {
    0L
  }
  expect_equal(quarantined_n, 0L,
               info = "R-15.36 conjunct 5: the run must report zero quarantined files for this event")

  states <- ingest_file_states(setup$db_path)
  # NA-safe filter (A43): hash is never NA for a routed file, but match the
  # project's established idiom rather than a bare `==`.
  xtab_state <- states[!is.na(states$hash) & states$hash == xtab_hash, ]
  expect_equal(nrow(xtab_state), 1)
  expect_false(identical(xtab_state$state[[1]], "quarantined"))
})

test_that("R-12.7: files_by_state shows 'needs_review' for a needs_review-only event, not 'claimed'", {
  setup <- ingest_test_setup()
  input_dir <- build_e2e_input_dir()

  review_resolved <- list(
    clean = tibble::tibble(source_ref = character(0)),
    skipped = tibble::tibble(source_ref = character(0), reason = character(0)),
    review = tibble::tibble(kind = "other")
  )
  testthat::local_mocked_bindings(
    reconcile_event = function(event, con) review_resolved,
    commit_event = function(event, resolved, con) {
      for (h in event$files$hash[sampleTidy:::.ig_kept_rows(event$files)]) {
        ingest_file_set_state(con, h, "needs_review", reset = TRUE)
      }
      invisible(NULL)
    }
  )

  report <- ingest_dir(input_dir, db = setup$db_path)

  expect_true(report$n_events > 0)
  expect_false("claimed" %in% names(report$files_by_state))
  expect_true("needs_review" %in% names(report$files_by_state))
  expect_equal(
    unname(report$files_by_state[["needs_review"]]),
    sum(ingest_file_states(setup$db_path)$state == "needs_review")
  )
})

# ---- Phase-7b round-2 items 5/7: .ig_retain_siblings() containment + the
#      residual ACIRL work-order-guess silence ------------------------------

test_that("Phase-7b round-2 item 5: one unarchivable retained sibling is contained (cli_warn'd and skipped), not thrown all the way out of ingest_dir() after commits have already landed", {
  setup <- ingest_test_setup()
  input_dir <- withr::local_tempdir()
  esdat_dir <- testthat::test_path("fixtures", "esdat")
  wo_files <- list.files(esdat_dir, pattern = "ES2617126", full.names = TRUE)
  for (f in wo_files) file.copy(f, file.path(input_dir, basename(f)))

  # A COA sibling whose retain-archive call is injected to fail (a
  # dehydrated OneDrive placeholder / permission error / rejected filename
  # in production; here a mocked archive_file()).
  coa_path <- file.path(input_dir, "ES2617126_0_COA.pdf")
  writeBin(charToRaw("fake COA, will fail to archive"), coa_path)
  coa_hash <- hash_file(coa_path)

  real_archive_file <- archive_file
  testthat::local_mocked_bindings(
    archive_file = function(con, path, hash, event, type = "Chemical analysis") {
      if (identical(basename(path), "ES2617126_0_COA.pdf")) {
        cli::cli_abort("injected retain-sibling archive failure", class = "sampletidy_error")
      }
      real_archive_file(con, path, hash, event, type = type)
    }
  )

  # Pre-fix: this threw ingest_dir() out entirely AFTER the tabular event had
  # already committed - 0 snapshots produced, no report, remove_ingested
  # never run.
  expect_warning(
    report <- ingest_dir(input_dir, db = setup$db_path),
    regexp = "failed to retain non-tabular deliverable",
    fixed = TRUE
  )

  expect_true(report$n_events_committed > 0)
  expect_false(is.na(report$snapshot_path))

  con <- DBI::dbConnect(duckdb::duckdb(), setup$db_path, read_only = TRUE)
  # withr::defer, NOT on.exit: `on.exit()` defaults to add = FALSE, which
  # REPLACES every handler already registered on this frame - including the one
  # local_mocked_bindings() above registered to undo itself. The bare on.exit()
  # that used to sit here silently leaked the mocked archive_file() into every
  # subsequent test in this file; it went unnoticed for as long as no later
  # test happened to archive a file named ES2617126_0_COA.pdf, and then cost an
  # afternoon when R-15.36a did exactly that.
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  asset_row <- DBI::dbGetQuery(con, "SELECT * FROM asset WHERE hash = ?", params = list(coa_hash))
  expect_equal(nrow(asset_row), 0)   # never archived

  coa_state <- ingest_file_states(setup$db_path)
  coa_state <- coa_state[!is.na(coa_state$hash) & coa_state$hash == coa_hash, ]
  expect_equal(nrow(coa_state), 1)
  expect_identical(coa_state$state[[1]], "quarantined")   # stays put, not silently lost
})

test_that("Phase-7b round-2 item 7 (RE-POINTED R-9.12): an ACIRL deliverable in an AMBIGUOUS folder stays quarantined AND is named in a cli_warn - the residual exposure is not silent", {
  setup <- ingest_test_setup()
  input_dir <- withr::local_tempdir()
  esdat_dir <- testthat::test_path("fixtures", "esdat")

  # RE-POINTED 2026-07-28 (Robin's ruling, R-9.12). This test used to place a
  # `2400-*` deliverable alongside ONE work order's files and assert it stayed
  # quarantined. That is no longer the wanted behaviour: an ACIRL email carries
  # the underlying ALS work order's files too, and the live DB shows the legacy
  # system already filed 104 of 124 ACIRL assets against an `ES#######` project.
  # A single-WO folder is now the RETAIN case (R-9.12), covered below.
  #
  # What survives, and is what this test was always really about, is the
  # residual: a folder that does NOT resolve to exactly one work order gives
  # inference nothing to work with, so the file stays quarantined - and must
  # still SAY so rather than vanishing quietly. Two work orders here.
  copied <- 0L
  for (f in list.files(esdat_dir, full.names = TRUE)) {
    if (grepl("ES2617126|XX1234567", basename(f))) {
      file.copy(f, file.path(input_dir, basename(f)))
      copied <- copied + 1L
    }
  }
  expect_true(copied > 3,
              info = "precondition: the folder must hold TWO work orders, else there is no ambiguity to test")

  acirl_path <- file.path(input_dir, "2400-7538-02 January 2026 Quarterly Katoomba WMF.pdf")
  writeBin(charToRaw("fake ACIRL report, no ES####### token in filename"), acirl_path)
  acirl_hash <- hash_file(acirl_path)

  expect_warning(
    report <- ingest_dir(input_dir, db = setup$db_path),
    regexp = "work order could not be recovered",
    fixed = TRUE
  )

  con <- DBI::dbConnect(duckdb::duckdb(), setup$db_path, read_only = TRUE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  asset_row <- DBI::dbGetQuery(con, "SELECT * FROM asset WHERE hash = ?", params = list(acirl_hash))
  expect_equal(nrow(asset_row), 0)

  acirl_state <- ingest_file_states(setup$db_path)
  acirl_state <- acirl_state[!is.na(acirl_state$hash) & acirl_state$hash == acirl_hash, ]
  expect_equal(nrow(acirl_state), 1)
  expect_identical(acirl_state$state[[1]], "quarantined")
})

# ---- R-9.12: ACIRL reports retained and attached to the ALS work order ----
#
# Robin's ruling, 2026-07-28: "Retain and attach to ALS WO."
#
# Grounded in the live DB rather than in a guess about how the labs work: of
# 124 ACIRL-shaped `asset` rows, **104 are already attached to an `ES#######`
# work-order project**, one report per work order (`2400-7286-01-04` ->
# ES2301817, `2400-7286-01-03` -> ES2301026, ...). The legacy system did
# exactly this; the package had simply stopped doing it.
#
# Two things had to change together, and each alone is inert:
#   * the SELECTION gate, which required a `_(coa|coc|qc|qci|xtab)` token -
#     zero of the 272 real ACIRL files carry one, so they were never even
#     candidates (and, since the same gate narrows the warning, never reported);
#   * the ACIRL block in folder inference, which would then have refused them.

test_that("R-9.12: a real-shaped ACIRL report in a folder belonging to one ALS work order is retained and attached to it", {
  setup <- ingest_test_setup()
  input_dir <- withr::local_tempdir()
  esdat_dir <- testthat::test_path("fixtures", "esdat")
  for (f in list.files(esdat_dir, pattern = "ES2617126", full.names = TRUE)) {
    file.copy(f, file.path(input_dir, basename(f)))
  }

  # A REAL corpus filename shape, not a synthetic `2400-*_QC.pdf`: real ACIRL
  # names are descriptive and carry no COA/COC/QC/QCI/XTAB token at all, which
  # is precisely why the old gate excluded all 272 of them.
  acirl <- file.path(input_dir, "2400-7454-05 May 2025 Monthly Katoomba WMF.pdf")
  writeBin(charToRaw(paste("fake ACIRL monthly report", paste(1:20, collapse = " "))), acirl)
  acirl_hash <- hash_file(acirl)

  expect_true(is.na(file_meta(acirl)$work_order_guess),
              info = "precondition: a 2400-* name must still yield NO parsed work order - the ACIRL trap is unchanged")
  expect_false(grepl("(?i)_(coa|coc|qc|qci|xtab)", basename(acirl), perl = TRUE),
               info = "precondition: the fixture must carry no deliverable token, or it would pass the OLD gate and prove nothing")

  ingest_dir(input_dir, db = setup$db_path)

  con <- DBI::dbConnect(duckdb::duckdb(), setup$db_path, read_only = TRUE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  linked <- DBI::dbGetQuery(
    con,
    "SELECT a.hash, a.type FROM asset a JOIN project p ON a.uuid_project = p.uuid
     WHERE p.name = 'ES2617126' AND a.hash = ?",
    params = list(acirl_hash)
  )
  expect_equal(nrow(linked), 1,
               info = "R-9.12: the ACIRL report must be attached to the folder's ALS work order")
  if (nrow(linked) == 1) {
    # The legacy majority: 108 of 124 ACIRL asset rows are "Chemical analysis".
    expect_identical(linked$type[[1]], "Chemical analysis")
  }

  states <- ingest_file_states(setup$db_path)
  st <- states[!is.na(states$hash) & states$hash == acirl_hash, ]
  expect_identical(st$state[[1]], "archived")
})

test_that("R-9.12: an ACIRL report whose folder resolves to NO committed work order stays quarantined and warns - inference never invents a target", {
  setup <- ingest_test_setup()
  input_dir <- withr::local_tempdir()

  # An ACIRL report on its own, with no ALS siblings at all. Nothing commits,
  # so there is no project to attach to. The file must be kept where a human
  # can find it, not filed against a work order we never saw data for.
  acirl <- file.path(input_dir, "2400-7454-05 May 2025 Monthly Katoomba WMF.pdf")
  writeBin(charToRaw(paste("fake ACIRL monthly report", paste(1:20, collapse = " "))), acirl)
  acirl_hash <- hash_file(acirl)

  con0 <- DBI::dbConnect(duckdb::duckdb(), setup$db_path, read_only = TRUE)
  project_count_before <- DBI::dbGetQuery(con0, "SELECT count(*) AS n FROM project")$n
  DBI::dbDisconnect(con0, shutdown = TRUE)

  expect_warning(
    ingest_dir(input_dir, db = setup$db_path),
    regexp = "work order could not be recovered",
    fixed = TRUE
  )

  con <- DBI::dbConnect(duckdb::duckdb(), setup$db_path, read_only = TRUE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  expect_equal(nrow(DBI::dbGetQuery(con, "SELECT 1 FROM asset WHERE hash = ?", params = list(acirl_hash))), 0)
  expect_equal(DBI::dbGetQuery(con, "SELECT count(*) AS n FROM project")$n, project_count_before,
               info = "R-9.12: a lone ACIRL report must not mint a project row")

  states <- ingest_file_states(setup$db_path)
  st <- states[!is.na(states$hash) & states$hash == acirl_hash, ]
  expect_identical(st$state[[1]], "quarantined")
})

test_that("R-9.12: ordinary non-deliverable cruft is still NOT retained and still draws no warning - widening the gate must not re-open the round-3 noise", {
  setup <- ingest_test_setup()
  input_dir <- withr::local_tempdir()
  esdat_dir <- testthat::test_path("fixtures", "esdat")
  for (f in list.files(esdat_dir, pattern = "ES2617126", full.names = TRUE)) {
    file.copy(f, file.path(input_dir, basename(f)))
  }

  # commit-5 (round 3) narrowed the retention SELECTION to a positive
  # deliverable shape precisely so a stray README/photo/notes file stopped
  # drawing a warning on every run forever. Widening the gate for ACIRL must
  # not undo that - the ACIRL shape is itself a positive token, not a
  # catch-all.
  for (fn in c("README.md", "photo.jpg", "notes.docx")) {
    p <- file.path(input_dir, fn)
    writeBin(charToRaw(paste("ordinary cruft", fn, paste(1:20, collapse = " "))), p)
  }

  w <- NULL
  withCallingHandlers(
    ingest_dir(input_dir, db = setup$db_path),
    warning = function(c) { w <<- c(w, conditionMessage(c)); invokeRestart("muffleWarning") }
  )
  expect_equal(sum(grepl("work order could not be recovered", w, fixed = TRUE)), 0,
               info = "R-9.12: cruft must stay silent - the round-3 fix is not undone by the ACIRL widening")

  con <- DBI::dbConnect(duckdb::duckdb(), setup$db_path, read_only = TRUE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  for (fn in c("README.md", "photo.jpg", "notes.docx")) {
    h <- hash_file(file.path(input_dir, fn))
    expect_equal(nrow(DBI::dbGetQuery(con, "SELECT 1 FROM asset WHERE hash = ?", params = list(h))), 0,
                 info = sprintf("R-9.12: %s must not be retained", fn))
  }
})

# ---- Phase-7b round-2 item 9: ingest_dir()-level coverage for the F.10
#      guard verdict's consumer (commit_event()'s blocked/n_review tally) ---
#
# Nothing in this file previously mentioned `blocked`/`reingest`/
# `work_order_reingest` - the tally logic Phase-7b item 2/9 exists for had
# zero ingest_dir()-level coverage, and two mutations were measured to
# survive the whole suite: M5 (`blocked <- FALSE` unconditionally) and M6
# (`committed_any <- TRUE` -> `committed_any <- !blocked`). This test drives
# the guard through the REAL adapter (route -> parse -> assemble -> reconcile
# -> commit_event()), not a hand-built commit_event() fixture.

test_that("Phase-7b round-2 item 9: ingest_dir() over a differently-named, same-revision re-download of an already-loaded work order commits ZERO new rows, commits ZERO events, opens exactly ONE review item, and still snapshots (committed_any stays TRUE for a blocked-only run)", {
  setup <- ingest_test_setup()
  esdat_dir <- testthat::test_path("fixtures", "esdat")

  input_dir1 <- withr::local_tempdir()
  for (f in c("PROJ_A.ESDAT_XX1234567_0.Chemistry2e.CSV",
              "PROJ_A.ESDAT_XX1234567_0.Sample2e.CSV",
              "PROJ_A.ESDAT_XX1234567_0.Header.XML")) {
    file.copy(file.path(esdat_dir, f), file.path(input_dir1, f))
  }
  report1 <- ingest_dir(input_dir1, db = setup$db_path)
  expect_gt(report1$n_events_committed, 0)

  before_sample <- count_rows(setup$db_path, "sample")
  before_analysis <- count_rows(setup$db_path, "analysis")

  # A differently-named re-download of the SAME work order/revision, whose
  # ONE sample row does NOT match anything already loaded (feature "T.S01"
  # and method/analyte are already resolved from run 1, so this row is
  # genuinely clean/unpending - the ONLY review item this run should open is
  # the guard's own work_order_reingest row, not an unknown_feature one).
  # Self-contained header text (not a copy of the real fixture files) so the
  # header's own hash is guaranteed distinct from run 1's - a byte-identical
  # copy would be recognised as an already-SEEN hash and skipped rather than
  # re-parsed.
  input_dir2 <- withr::local_tempdir()
  chem_header <- paste(
    "SampleCode,ChemCode,OriginalChemName,Prefix,Result,Result_Unit,",
    "Total_or_Filtered,Result_Type,Method_Type,Method_Name,Extraction_Date,",
    "Analysed_Date,EQL,EQL_Units,Comments,Lab_Qualifier,UCL,LCL",
    sep = ""
  )
  samp_header <- paste(
    "SampleCode,Sampled_Date_Time,Field_ID,Blank1,Depth,Blank2,Matrix_Type,",
    "Sample_Type,Parent_Sample,Blank3,SDG,Lab_Name,Lab_SampleID,",
    "Lab_Comments,Lab_Report_Number",
    sep = ""
  )
  chem2 <- c(
    chem_header,
    paste0(
      "XX1234567099,,pH Value,,6.90,pH Unit,T,Numeric,pH by PC Titrator,",
      "EA005P: pH by PC Titrator,,26 May 2025,0.01,pH Unit,,,,"
    )
  )
  samp2 <- c(
    samp_header,
    paste0(
      "XX1234567099,01 Sep 2025 09:00,T.S01,,,,WATER,Normal,,,,ALSE-Sydney,",
      "XX1234567099,,XX1234567"
    )
  )
  hdr2 <- c(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<ESdat xmlns="http://www.escis.com.au/2013/XML" fileType="eLabResultsHeader">',
    paste0(
      '  <LabReport Lab_Report_Number="XX1234567" Date_Reported="2025-09-01" ',
      'Project_ID="PROJ_A" Lab_Name="ALSE-Sydney" Lab_Signatory="J. Signatory">'
    ),
    '    <eCoCs>',
    '      <eCoC COC_Number="COC-0002"/>',
    '    </eCoCs>',
    '  </LabReport>',
    '</ESdat>'
  )
  writeLines(chem2, file.path(input_dir2, "PROJ_A.ESDAT_XX1234567_0_REDL.Chemistry2e.CSV"))
  writeLines(samp2, file.path(input_dir2, "PROJ_A.ESDAT_XX1234567_0_REDL.Sample2e.CSV"))
  writeLines(hdr2, file.path(input_dir2, "PROJ_A.ESDAT_XX1234567_0_REDL.Header.XML"))

  report2 <- ingest_dir(input_dir2, db = setup$db_path)

  expect_equal(report2$rows_new, 0L)
  expect_equal(report2$n_events_committed, 0L)
  expect_equal(report2$review_items_opened, 1L)
  # M6 (`committed_any <- TRUE` -> `committed_any <- !blocked`): this run's
  # ONLY event is the guard-blocked one, so committed_any must still be TRUE
  # (the guard itself writes review_queue/asset/ingest_file rows worth
  # snapshotting) - kill-verified: with M6 applied, snapshot_path is NA here.
  expect_false(is.na(report2$snapshot_path))
  expect_equal(count_rows(setup$db_path, "sample"), before_sample)
  expect_equal(count_rows(setup$db_path, "analysis"), before_analysis)
})

# ---- T1.2 (Robin's ruling): a dry run must make ZERO ingest_file state ----
#      transitions - a following real run must still ingest for real -------

test_that("T1.2: a dry run over a directory, followed by a REAL run over the SAME directory, actually ingests the rows - pre-fix, the dry run silently poisoned every kept file to 'reconciled', the real run's claimed-only parse filter then skipped them, and n_events_committed stayed 0 forever", {
  setup <- ingest_test_setup()
  input_dir <- withr::local_tempdir()
  esdat_dir <- testthat::test_path("fixtures", "esdat")
  for (f in c("PROJ_A.ESDAT_XX1234567_0.Chemistry2e.CSV",
              "PROJ_A.ESDAT_XX1234567_0.Sample2e.CSV",
              "PROJ_A.ESDAT_XX1234567_0.Header.XML")) {
    file.copy(file.path(esdat_dir, f), file.path(input_dir, f))
  }

  dry <- ingest_dir(input_dir, db = setup$db_path, dry_run = TRUE)
  expect_equal(dry$n_events_committed, 0L)
  before_states <- ingest_file_states(setup$db_path)
  # T1.2 main claim: NO ingest_file state transition happened at all under
  # dry_run - every kept file must still be at the router's own first-cut
  # state (`claimed`), not `parsed`/`assembled`/`reconciled`.
  kept <- before_states[!is.na(before_states$filename), ]
  expect_true(all(kept$state == "claimed"))

  real <- ingest_dir(input_dir, db = setup$db_path)
  expect_gt(real$n_events_committed, 0L)
  expect_gt(count_rows(setup$db_path, "sample"), 0)
  after_states <- ingest_file_states(setup$db_path)
  expect_true(all(after_states$state %in% c("committed", "archived")))
})

# ---- T1.2 item 7: a dry run's report must tell the truth about an F.10 ----
#      guard-blocked event, not report what reconcile alone would propose ---

test_that("T1.2 item 7: dry_run's report matches what a real run over the SAME guard-blocked re-download reports (rows_new = 0, review_items_opened = 1) - pre-fix, the dry-run report said rows_new = 1 (the opposite of the truth F.10 exists to inform)", {
  setup <- ingest_test_setup()
  esdat_dir <- testthat::test_path("fixtures", "esdat")

  input_dir1 <- withr::local_tempdir()
  for (f in c("PROJ_A.ESDAT_XX1234567_0.Chemistry2e.CSV",
              "PROJ_A.ESDAT_XX1234567_0.Sample2e.CSV",
              "PROJ_A.ESDAT_XX1234567_0.Header.XML")) {
    file.copy(file.path(esdat_dir, f), file.path(input_dir1, f))
  }
  ingest_dir(input_dir1, db = setup$db_path)

  # A differently-named, same-revision re-download whose one sample row does
  # not match anything already loaded - the classic F.10 block shape (same
  # fixture text as the "Phase-7b round-2 item 9" test above).
  input_dir2 <- withr::local_tempdir()
  chem2 <- c(
    paste0(
      "SampleCode,ChemCode,OriginalChemName,Prefix,Result,Result_Unit,",
      "Total_or_Filtered,Result_Type,Method_Type,Method_Name,Extraction_Date,",
      "Analysed_Date,EQL,EQL_Units,Comments,Lab_Qualifier,UCL,LCL"
    ),
    paste0(
      "XX1234567099,,pH Value,,6.90,pH Unit,T,Numeric,pH by PC Titrator,",
      "EA005P: pH by PC Titrator,,26 May 2025,0.01,pH Unit,,,,"
    )
  )
  samp2 <- c(
    paste0(
      "SampleCode,Sampled_Date_Time,Field_ID,Blank1,Depth,Blank2,Matrix_Type,",
      "Sample_Type,Parent_Sample,Blank3,SDG,Lab_Name,Lab_SampleID,",
      "Lab_Comments,Lab_Report_Number"
    ),
    paste0(
      "XX1234567099,01 Sep 2025 09:00,T.S01,,,,WATER,Normal,,,,ALSE-Sydney,",
      "XX1234567099,,XX1234567"
    )
  )
  hdr2 <- c(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<ESdat xmlns="http://www.escis.com.au/2013/XML" fileType="eLabResultsHeader">',
    paste0(
      '  <LabReport Lab_Report_Number="XX1234567" Date_Reported="2025-09-01" ',
      'Project_ID="PROJ_A" Lab_Name="ALSE-Sydney" Lab_Signatory="J. Signatory">'
    ),
    '    <eCoCs>', '      <eCoC COC_Number="COC-0002"/>', '    </eCoCs>',
    '  </LabReport>', '</ESdat>'
  )
  writeLines(chem2, file.path(input_dir2, "PROJ_A.ESDAT_XX1234567_0_REDL.Chemistry2e.CSV"))
  writeLines(samp2, file.path(input_dir2, "PROJ_A.ESDAT_XX1234567_0_REDL.Sample2e.CSV"))
  writeLines(hdr2, file.path(input_dir2, "PROJ_A.ESDAT_XX1234567_0_REDL.Header.XML"))

  before_sample <- count_rows(setup$db_path, "sample")

  dry_report <- ingest_dir(input_dir2, db = setup$db_path, dry_run = TRUE)
  expect_equal(dry_report$rows_new, 0L)
  expect_equal(dry_report$review_items_opened, 1L)
  expect_equal(count_rows(setup$db_path, "sample"), before_sample)   # dry run wrote nothing

  # The dry run must not have poisoned the directory either - a REAL run
  # right after reports the SAME (correct) numbers.
  real_report <- ingest_dir(input_dir2, db = setup$db_path)
  expect_equal(real_report$rows_new, 0L)
  expect_equal(real_report$review_items_opened, 1L)
  expect_equal(count_rows(setup$db_path, "sample"), before_sample)
})

# ---- commit-3: a half-retained sibling must not report a false diagnostic -

test_that("commit-3: a retained sibling whose state-transition write fails atomically rolls back its asset row too - the ingest_file row stays quarantined, no orphan asset row is created, and the warning does not claim 'unarchived' for a copy that landed", {
  setup <- ingest_test_setup()
  input_dir <- withr::local_tempdir()
  for (f in list.files(testthat::test_path("fixtures", "esdat"), pattern = "ES2617126", full.names = TRUE)) {
    file.copy(f, file.path(input_dir, basename(f)))
  }
  coa <- file.path(input_dir, "ES2617126_0_COA.pdf")
  writeBin(charToRaw("fake COA bytes"), coa)
  h <- hash_file(coa)
  real_set_state <- ingest_file_set_state
  testthat::local_mocked_bindings(
    ingest_file_set_state = function(con, hash, state, reason = NA_character_, ...) {
      if (identical(hash, h) && identical(state, "archived")) {
        cli::cli_abort("injected state-transition failure", class = "sampletidy_error")
      }
      real_set_state(con, hash, state, reason = reason, ...)
    }
  )

  w <- NULL
  withCallingHandlers(
    ingest_dir(input_dir, db = setup$db_path),
    warning = function(c) { w <<- c(w, conditionMessage(c)); invokeRestart("muffleWarning") }
  )

  con <- DBI::dbConnect(duckdb::duckdb(), setup$db_path, read_only = TRUE)
  # withr::defer, not on.exit - see the note in the round-2 item 5 test above:
  # a bare on.exit() here wiped local_mocked_bindings()'s own restore handler
  # and leaked the mocked ingest_file_set_state() into the rest of the file.
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  asset_row <- DBI::dbGetQuery(con, "SELECT uuid FROM asset WHERE hash = ?", params = list(h))
  expect_equal(nrow(asset_row), 0)   # the asset insert rolled back WITH the failed transition

  st <- ingest_file_states(setup$db_path)
  st <- st[!is.na(st$hash) & st$hash == h, ]
  expect_identical(st$state[[1]], "quarantined")

  last_warning <- tail(w, 1)
  expect_true(grepl("quarantined", last_warning, fixed = TRUE))
  expect_false(grepl("unarchived", last_warning, fixed = TRUE))
})

# ---- commit-5: the F.17 sweep must stay silent for ordinary cruft ---------

test_that("commit-5: ordinary unclaimed cruft (README.md, a photo, a stray notes file) never draws the 'non-tabular lab deliverable' retention warning, on this run or a following one", {
  setup <- ingest_test_setup()
  input_dir <- withr::local_tempdir()
  for (f in list.files(testthat::test_path("fixtures", "esdat"), pattern = "ES2617126", full.names = TRUE)) {
    file.copy(f, file.path(input_dir, basename(f)))
  }
  for (nm in c("site notes.docx", "photo.jpg", "README.md")) {
    writeLines("junk", file.path(input_dir, nm))
  }

  grab <- function() {
    w <- NULL
    withCallingHandlers(
      ingest_dir(input_dir, db = setup$db_path),
      warning = function(c) { w <<- c(w, conditionMessage(c)); invokeRestart("muffleWarning") }
    )
    sum(grepl("work order could not be recovered", w, fixed = TRUE))
  }
  expect_equal(grab(), 0)
  expect_equal(grab(), 0)
})

# ---- commit-9: a [N]-marked duplicate-download COA is still a COA ---------

test_that("commit-9: a [N]-marked duplicate-download COA (the ordinary browser-redownload shape ignore_rule() deliberately passes through) is still typed 'Certificate of analysis', not 'Chemical analysis'", {
  # RE-POINTED at .ig_retained_asset_type(). This used to assert against
  # .ig_is_coa_deliverable(), which R-15.36b's lookup table superseded and
  # which then sat with no production caller at all - two predicates for one
  # ruled concept, which is how they drift apart. The behaviour under test is
  # unchanged; it is now asserted against the function that actually decides.
  ty <- sampleTidy:::.ig_retained_asset_type
  expect_identical(ty("ES2617126_0_COA[1].pdf"), "Certificate of analysis")
  expect_identical(ty("ES2617126_0_COA.pdf"), "Certificate of analysis")
  expect_identical(ty("ES2617126_0_COA.PDF"), "Certificate of analysis")
  # COC must NOT be widened by this fix (round-2 item 6's separate ruling).
  expect_false(identical(ty("ES2617126_0_COC[1].pdf"), "Certificate of analysis"))
  expect_identical(ty("ES2617126_0_COC[1].pdf"), "QA")
  # The ordering claim the audit disproved: `_qc` cannot swallow `_QCI`,
  # because it requires the extension dot (or an [N] marker) immediately after.
  expect_identical(ty("ES2617126_0_QCI.pdf"), "QC")
  expect_identical(ty("ES2617126_0_QC.pdf"), "QC")
})

# ---- Fresh-eyes audit remediation, 2026-07-28 ----------------------------
#
# Four defects found by an adversarial audit of this session's own changes.
# Each test below FAILED against the code as first written.

test_that("AUDIT-1: the ACIRL selector matches the unhyphenated dialect and does NOT match an unrelated year range or a scanner timestamp", {
  is_acirl <- sampleTidy:::.ig_is_acirl_shaped

  # Wrong in BOTH directions before the fix. The loose `\d{4}-\d{4}` missed
  # the whole unhyphenated `24006989-01` dialect - 27 real files in the live
  # corpus - because `24006989-10` has only two digits after its hyphen.
  expect_true(is_acirl("24006989-01 Blaxland WMF Groundwater January 2020.pdf"))
  expect_true(is_acirl("24006989 - 06 Quarterly Blaxland WMF June 2020.pdf"))
  expect_true(is_acirl("2400-7454-05 May 2025 Monthly Katoomba WMF.pdf"))
  expect_true(is_acirl("2400-7538 01-01 January 2026 Quarterly Katoomba WMF.xls"))

  # ...and it falsely matched real non-ACIRL files. Since R-9.12 this predicate
  # SELECTS for retention rather than refusing, so a false match means an
  # unrelated document archived as an asset of a work order and its source
  # deleted from the input directory. The first two below are real filenames
  # from the live asset table.
  expect_false(is_acirl("Blx Quarterly 13-06-21062024141257-0001.pdf"))
  expect_false(is_acirl("12012023104213-0001.pdf"))
  expect_false(is_acirl("Annual Report 2023-2024.pdf"))
  expect_false(is_acirl("EPA licence 13089-2026.pdf"))
  expect_false(is_acirl("12400-1234 not an acirl job.pdf"))
})

test_that("AUDIT-2: a folder holding a ZERO-BYTE file is never deleted - an attachment mid-delivery must not be unlinked with the folder", {
  setup <- ingest_test_setup()
  withr::local_options(list("sampletidy.remove_ingested" = TRUE))
  root <- withr::local_tempdir()
  folder <- file.path(root, "email-001")
  seed_wo_folder(folder, "ES2617126")

  # The real failure: OneDrive/PowerAutomate is mid-delivery of a two-attachment
  # email. Attachment 1 commits and is removed, so the run DID remove files;
  # attachment 2 exists but is still 0 bytes. `ignore_rule()` calls a zero-byte
  # file `empty_file`, so treating ignore_rule()'s verdict as "safe to delete"
  # destroyed the only copy of a deliverable before it was ever routed.
  inflight <- file.path(folder, "ES2617126_0_COA.pdf")
  file.create(inflight)
  expect_equal(file.size(inflight), 0,
               info = "precondition: the fixture must really be zero bytes")

  ingest_inbox(root, db = setup$db_path)

  expect_true(dir.exists(folder),
              info = "AUDIT-2: a zero-byte file must keep its folder alive")
  expect_true(file.exists(inflight),
              info = "AUDIT-2: the in-flight attachment must survive")
})

test_that("AUDIT-3: a folder naming TWO work orders declines inference even when only ONE of them has a project row", {
  setup <- ingest_test_setup()
  input_dir <- withr::local_tempdir()
  esdat_dir <- testthat::test_path("fixtures", "esdat")

  # ES2617126's triple commits, so it gets a project row. ES2699999 is named in
  # the folder by a COA that no adapter claims, so it is quarantined and never
  # gets one - but it IS routed, so it is one of the folder's work orders.
  # Filtering candidates to known projects BEFORE the exactly-one test turned
  # that ambiguity into a confident wrong answer: the anonymous deliverable was
  # filed under ES2617126.
  #
  # An earlier draft of this fixture used a lone `XX1234567` Sample2e for the
  # second work order on the assumption that it would not commit. It does, so
  # both work orders had project rows and the test never reached the defect.
  # The precondition assertions below exist to catch exactly that, and did.
  for (f in list.files(esdat_dir, pattern = "ES2617126", full.names = TRUE)) {
    file.copy(f, file.path(input_dir, basename(f)))
  }
  write_coa_fixture(input_dir, "ES2699999")

  renamed <- file.path(input_dir, "Certificate of Analysis_COA.pdf")
  writeBin(charToRaw(paste("fake COA, ambiguous folder", paste(1:20, collapse = " "))), renamed)
  renamed_hash <- hash_file(renamed)

  suppressWarnings(ingest_dir(input_dir, db = setup$db_path))

  con <- DBI::dbConnect(duckdb::duckdb(), setup$db_path, read_only = TRUE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  # Precondition: exactly one of the two work orders has a project row, else
  # this fixture does not exercise the defect at all.
  expect_equal(nrow(DBI::dbGetQuery(con, "SELECT 1 FROM project WHERE name = 'ES2617126'")), 1)
  expect_equal(nrow(DBI::dbGetQuery(con, "SELECT 1 FROM project WHERE name = 'ES2699999'")), 0)

  expect_equal(
    nrow(DBI::dbGetQuery(con, "SELECT 1 FROM asset WHERE hash = ?", params = list(renamed_hash))), 0,
    info = "AUDIT-3: ambiguity is a property of the FOLDER, not of what we managed to commit from it"
  )
})

test_that("AUDIT-4: a run interrupted before its snapshot still removes its sources on the NEXT run, instead of stalling forever", {
  setup <- ingest_test_setup()
  withr::local_options(list("sampletidy.remove_ingested" = TRUE))
  input_dir <- withr::local_tempdir()
  esdat_dir <- testthat::test_path("fixtures", "esdat")
  for (f in list.files(esdat_dir, pattern = "ES2617126", full.names = TRUE)) {
    file.copy(f, file.path(input_dir, basename(f)))
  }

  # Run 1 archives everything, then dies at the snapshot. R-9.6 is explicit
  # that nothing may be removed without a verified snapshot, so run 1 leaving
  # the sources in place is CORRECT.
  local({
    testthat::local_mocked_bindings(
      snapshot_db = function(...) stop("simulated snapshot failure")
    )
    expect_error(ingest_dir(input_dir, db = setup$db_path), "simulated snapshot failure")
  })
  expect_true(all(file.exists(list.files(input_dir, full.names = TRUE))),
              info = "AUDIT-4 precondition: run 1 must leave the sources in place")

  # Run 2 is the defect. Every file is already `archived`, so the run commits
  # nothing and retains nothing - and gating the snapshot on THIS run's commits
  # meant no snapshot, so no removal, so the sources sat there forever, on this
  # run and every run after it, with no warning.
  report2 <- ingest_dir(input_dir, db = setup$db_path)

  expect_false(is.na(report2$snapshot_path),
               info = "AUDIT-4: pending removable work must earn a snapshot")
  expect_true(length(report2$removed_files) > 0,
              info = "AUDIT-4: run 2 must clear the backlog run 1 could not")
  expect_equal(length(list.files(input_dir)), 0)

  # Self-limiting: run 3 has nothing pending, so it does NOT snapshot again.
  report3 <- ingest_dir(input_dir, db = setup$db_path)
  expect_true(is.na(report3$snapshot_path),
              info = "AUDIT-4: the pending-work trigger must not become an always-snapshot")
})

test_that("AUDIT-5: a folder holding only ignorable cruft is removed even though this run removed nothing from it", {
  setup <- ingest_test_setup()
  withr::local_options(list("sampletidy.remove_ingested" = TRUE))
  root <- withr::local_tempdir()
  folder <- file.path(root, "email-spent")
  dir.create(folder)

  # This is `batch-2026-07-23`, the folder the whole design cites as motivating
  # and which is STILL on disk: everything real was consumed long ago and only
  # a .DS_Store remains. Gating cleanup on "this run removed something" meant
  # the one folder R-9.9 was written for could never be cleaned.
  writeBin(charToRaw("finder cruft"), file.path(folder, ".DS_Store"))
  writeBin(charToRaw("stale"), file.path(folder, "old_export.bak"))

  reports <- ingest_inbox(root, db = setup$db_path)

  expect_false(dir.exists(folder),
               info = "AUDIT-5: a cruft-only folder must be removable without a data deletion first")
  expect_true(dir.exists(root))
  expect_equal(reports$n_folders_removed, 1L)

  # ... and it happens with NO snapshot, because there was no data to snapshot:
  # nothing committed, nothing retained. That is correct - R-9.6's gate governs
  # deleting FILES the DB now holds copies of, and there are none here - but it
  # means cruft-only cleanup is genuinely NOT "strictly downstream of R-9.6's
  # gate" the way the rest of R-9.9 is. PLAN-09 claimed it was; asserting it
  # here stops the plan and the code drifting apart again.
  expect_true(is.na(reports$folders[["email-spent"]]$snapshot_path),
              info = "AUDIT-5: a cruft-only folder is cleaned without earning a snapshot")
})

test_that("AUDIT-6: a folder containing a SUBDIRECTORY is never removed, even when everything else in it is spent", {
  setup <- ingest_test_setup()
  withr::local_options(list("sampletidy.remove_ingested" = TRUE))
  root <- withr::local_tempdir()
  folder <- file.path(root, "email-with-subdir")
  dir.create(folder)

  # `.ig_folder_is_spent()` keeps a folder alive when it holds a subdirectory,
  # because ingest is non-recursive (R-9.5) so nothing in there was ever routed
  # and we know nothing about it. That guard was implemented but pinned by no
  # criterion and no test - and losing it would breach R-9.5's "subdirectory
  # content untouched" by deleting the subdirectory outright, which is the
  # worst failure in this file: unlinking data the pipeline never even looked
  # at. AUDIT-5 makes this reachable, because a cruft-only folder is now
  # removable without a deletion happening first.
  #
  # Measured, so the next reader does not over-trust it: deleting the explicit
  # `any(dir.exists(entries))` guard does NOT make this test fail, because
  # `file.size()` on a directory is non-zero and `file_meta()` then errors into
  # the same keep-alive branch. The guard is defence in depth, not the sole
  # mechanism. This test is therefore written against the BEHAVIOUR R-9.5
  # promises rather than that one line, and it does fail (all three assertions)
  # when `.ig_folder_is_spent()` is forced to TRUE.
  writeBin(charToRaw("finder cruft"), file.path(folder, ".DS_Store"))
  nested <- file.path(folder, "attachments")
  dir.create(nested)
  keeper <- file.path(nested, "important.pdf")
  writeBin(charToRaw(paste("a file ingest never routed", paste(1:20, collapse = " "))), keeper)

  reports <- ingest_inbox(root, db = setup$db_path)

  expect_true(dir.exists(folder),
              info = "AUDIT-6: a subdirectory must keep its parent folder alive")
  expect_true(file.exists(keeper),
              info = "AUDIT-6: unrouted subdirectory content must survive - R-9.5")
  expect_equal(reports$n_folders_removed, 0L)
})

test_that("AUDIT-7: R-9.6's snapshot gate still holds on the RETAIN-ONLY path - an injected snapshot failure removes nothing", {
  setup <- ingest_test_setup()

  # R-9.10 widened "something happened" from committed to committed-or-retained
  # so a retain-only run could earn a snapshot. Its third criterion - that
  # R-9.6's "no removal without a verified snapshot" still holds on that NEW
  # path - was declared and never tested. Widening a snapshot trigger is
  # exactly the change that could let removal run ahead of its gate, and the
  # retain-only path is the one with no commit to fall back on.
  run1_dir <- withr::local_tempdir()
  esdat_dir <- testthat::test_path("fixtures", "esdat")
  for (f in list.files(esdat_dir, pattern = "ES2617126", full.names = TRUE)) {
    file.copy(f, file.path(run1_dir, basename(f)))
  }
  expect_true(ingest_dir(run1_dir, db = setup$db_path)$n_events_committed > 0)

  withr::local_options(list("sampletidy.remove_ingested" = TRUE))
  run2_dir <- withr::local_tempdir()
  coa <- write_coa_fixture(run2_dir, "ES2617126")

  local({
    testthat::local_mocked_bindings(
      snapshot_db = function(...) stop("simulated snapshot failure")
    )
    expect_error(ingest_dir(run2_dir, db = setup$db_path), "simulated snapshot failure")
  })

  expect_true(file.exists(coa$path),
              info = "AUDIT-7: no verified snapshot means no removal, retain-only path included")
  expect_equal(length(list.files(run2_dir)), 1)

  # Reachability arm. Without it this test would pass just as happily if the
  # retain-only path never removed anything under ANY circumstances - the file
  # surviving would prove nothing about the gate. Re-run unmocked: the same
  # file, same directory, now does get removed, so the survival above was
  # caused by the injected snapshot failure and nothing else.
  report <- ingest_dir(run2_dir, db = setup$db_path)
  expect_false(is.na(report$snapshot_path))
  expect_false(file.exists(coa$path),
               info = "AUDIT-7 reachability: with a real snapshot the retain-only path DOES remove")
})

# ---- R-15.36a: retention across runs (Robin, 2026-07-28) -------------------
#
# Ruling: a deliverable whose work order committed in an EARLIER run attaches
# to that existing work order, and must NEVER create a project row.
#
# The first arm is a characterisation test - the behaviour already works,
# because .ig_retain_siblings() looks up the PERSISTENT `project` table, not
# anything run-scoped. It is written anyway because nothing pinned it, so the
# find-only lookup could be "tidied" into .ct_ensure_project()'s find-or-create
# by anyone reading the (wrong) comments that said the WO had to commit in the
# same run. The second arm is the one that pins the ruling's teeth.

# (`write_coa_fixture()` is defined with the other fixture builders at the top
# of this file.)

test_that("R-15.36a: a COA arriving in a LATER run, in its own directory, attaches to the work order committed by an earlier run", {
  setup <- ingest_test_setup()

  # Run 1: the data files only. No COA anywhere - so nothing in this run can
  # be what run 2's assertions later observe.
  run1_dir <- withr::local_tempdir()
  esdat_dir <- testthat::test_path("fixtures", "esdat")
  wo_files <- list.files(esdat_dir, pattern = "ES2617126", full.names = TRUE)
  expect_true(length(wo_files) == 3,
              info = "ES2617126 esdat fixture triple must exist")
  for (f in wo_files) file.copy(f, file.path(run1_dir, basename(f)))

  report1 <- ingest_dir(run1_dir, db = setup$db_path)
  expect_true(report1$n_events_committed > 0)

  # The project row now exists and outlives run 1 - that persistence is the
  # whole mechanism, so assert it rather than assuming it.
  con1 <- DBI::dbConnect(duckdb::duckdb(), setup$db_path, read_only = TRUE)
  project_before <- DBI::dbGetQuery(con1, "SELECT uuid FROM project WHERE name = 'ES2617126'")
  project_count_before <- DBI::dbGetQuery(con1, "SELECT count(*) AS n FROM project")$n
  DBI::dbDisconnect(con1, shutdown = TRUE)
  expect_equal(nrow(project_before), 1)

  # Run 2: a SEPARATE ingest_dir() call over a DIFFERENT directory holding
  # only the COA. Nothing here commits; the only work is retention.
  withr::local_options(list("sampletidy.remove_ingested" = TRUE))
  run2_dir <- withr::local_tempdir()
  coa <- write_coa_fixture(run2_dir, "ES2617126")

  report2 <- ingest_dir(run2_dir, db = setup$db_path)
  expect_equal(report2$n_events_committed, 0,
               info = "R-15.36a: run 2 must commit nothing - retention is its only work")

  con <- DBI::dbConnect(duckdb::duckdb(), setup$db_path, read_only = TRUE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  asset_row <- DBI::dbGetQuery(con, "SELECT * FROM asset WHERE hash = ?", params = list(coa$hash))
  expect_equal(nrow(asset_row), 1,
               info = "R-15.36a: the cross-run COA must get an asset row")
  if (nrow(asset_row) == 1) {
    expect_identical(asset_row$type[[1]], "Certificate of analysis")
  }

  # Attached to run 1's project row specifically - not to a new one minted
  # for it, which is the failure the ruling forbids.
  linked <- DBI::dbGetQuery(
    con,
    "SELECT a.hash FROM asset a JOIN project p ON a.uuid_project = p.uuid
     WHERE p.name = 'ES2617126' AND a.hash = ?",
    params = list(coa$hash)
  )
  expect_equal(nrow(linked), 1,
               info = "R-15.36a: the COA must be reachable from the EARLIER run's work order")
  if (nrow(asset_row) == 1) {
    expect_identical(asset_row$uuid_project[[1]], project_before$uuid[[1]])
  }
  expect_equal(
    DBI::dbGetQuery(con, "SELECT count(*) AS n FROM project")$n, project_count_before,
    info = "R-15.36a: retaining a cross-run COA must not add a project row"
  )

  # R-9.10: retention alone must earn a snapshot, or remove_ingested never
  # runs and the source sits there forever.
  expect_false(is.na(report2$snapshot_path),
               info = "R-9.10: a retain-only run must still produce a snapshot")
  expect_false(file.exists(coa$path),
               info = "R-9.10: a retain-only run under remove_ingested = TRUE must delete the source")
})

test_that("R-15.36a: a COA for a work order that has NEVER committed creates no project row and stays quarantined", {
  setup <- ingest_test_setup()
  withr::local_options(list("sampletidy.remove_ingested" = TRUE))

  input_dir <- withr::local_tempdir()
  # ES2699999 appears nowhere in any fixture: there is no data for it and
  # never was. Attaching evidence to it would mean inventing a work order.
  coa <- write_coa_fixture(input_dir, "ES2699999")

  con0 <- DBI::dbConnect(duckdb::duckdb(), setup$db_path, read_only = TRUE)
  project_count_before <- DBI::dbGetQuery(con0, "SELECT count(*) AS n FROM project")$n
  DBI::dbDisconnect(con0, shutdown = TRUE)

  ingest_dir(input_dir, db = setup$db_path)

  con <- DBI::dbConnect(duckdb::duckdb(), setup$db_path, read_only = TRUE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  # The strong assertion, and the reason this arm exists: asserting only that
  # the asset is absent would still pass if we had minted a project row and
  # then failed to archive for some unrelated reason.
  expect_equal(
    DBI::dbGetQuery(con, "SELECT count(*) AS n FROM project")$n, project_count_before,
    info = "R-15.36a: an unknown work order must NOT be created - find-only, never find-or-create"
  )
  expect_equal(
    nrow(DBI::dbGetQuery(con, "SELECT 1 FROM project WHERE name = 'ES2699999'")), 0
  )
  expect_equal(nrow(DBI::dbGetQuery(con, "SELECT 1 FROM asset WHERE hash = ?", params = list(coa$hash))), 0)

  states <- ingest_file_states(setup$db_path)
  coa_state <- states[!is.na(states$hash) & states$hash == coa$hash, ]
  expect_equal(nrow(coa_state), 1)
  expect_identical(coa_state$state[[1]], "quarantined")
  expect_true(file.exists(coa$path),
              info = "R-15.36a: an unattached deliverable must never be deleted from the input dir")
})

# ---- R-15.36b: asset.type per retained kind (Robin, 2026-07-28) -----------

test_that("R-15.36b: each retained deliverable kind lands its ruled asset.type (COA/QC/QCI/COC/XTAB asserted per-token)", {
  setup <- ingest_test_setup()

  input_dir <- withr::local_tempdir()
  esdat_dir <- testthat::test_path("fixtures", "esdat")
  for (f in list.files(esdat_dir, pattern = "ES2617126", full.names = TRUE)) {
    file.copy(f, file.path(input_dir, basename(f)))
  }

  # One file per ruled token, all in one run - a single-arm test would pass
  # while three of the four mappings were wrong.
  expected <- c(
    "ES2617126_0_COA.pdf"  = "Certificate of analysis",
    "ES2617126_0_QC.pdf"   = "QC",
    "ES2617126_0_QCI.pdf"  = "QC",
    "ES2617126_COC.pdf"    = "QA",
    "ES2617126_0_XTAB.XLS" = "Chemical analysis"
  )
  hashes <- vapply(names(expected), function(fn) {
    p <- file.path(input_dir, fn)
    writeBin(charToRaw(paste0("fake ", fn, " payload, non-degenerate filler ",
                              paste(1:20, collapse = " "))), p)
    hash_file(p)
  }, character(1))

  ingest_dir(input_dir, db = setup$db_path)

  con <- DBI::dbConnect(duckdb::duckdb(), setup$db_path, read_only = TRUE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  for (fn in names(expected)) {
    row <- DBI::dbGetQuery(con, "SELECT type FROM asset WHERE hash = ?", params = list(hashes[[fn]]))
    expect_equal(nrow(row), 1, info = sprintf("R-15.36b: %s must be retained at all", fn))
    if (nrow(row) == 1) {
      expect_identical(row$type[[1]], unname(expected[[fn]]),
                       info = sprintf("R-15.36b: %s must be typed %s", fn, expected[[fn]]))
    }
  }
})

# ---- R-9.8: folder-sibling work-order inference ---------------------------

test_that("R-9.8: a deliverable with NO work-order token, in a folder belonging to exactly one work order, is retained and attached to it", {
  setup <- ingest_test_setup()

  input_dir <- withr::local_tempdir()
  esdat_dir <- testthat::test_path("fixtures", "esdat")
  for (f in list.files(esdat_dir, pattern = "ES2617126", full.names = TRUE)) {
    file.copy(f, file.path(input_dir, basename(f)))
  }

  # The real shape this rule is for: PowerAutomate saved the attachment under
  # the name the sender used, which carries no work order at all. Note it is
  # ALSO not ACIRL-shaped - no \d{4}-\d{4} token - so nothing about it declares
  # a work order of its own.
  renamed <- file.path(input_dir, "Certificate of Analysis_COA.pdf")
  writeBin(charToRaw(paste("fake COA saved under the sender's own filename",
                           paste(1:20, collapse = " "))), renamed)
  renamed_hash <- hash_file(renamed)
  expect_true(is.na(file_meta(renamed)$work_order_guess),
              info = "R-9.8 precondition: the fixture must have NO parseable work order, else this tests nothing")

  ingest_dir(input_dir, db = setup$db_path)

  con <- DBI::dbConnect(duckdb::duckdb(), setup$db_path, read_only = TRUE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  linked <- DBI::dbGetQuery(
    con,
    "SELECT a.hash FROM asset a JOIN project p ON a.uuid_project = p.uuid
     WHERE p.name = 'ES2617126' AND a.hash = ?",
    params = list(renamed_hash)
  )
  expect_equal(nrow(linked), 1,
               info = "R-9.8: folder inference must attach the token-less deliverable to the folder's single work order")
})

test_that("R-9.8: the same token-less deliverable in a folder resolving to TWO work orders is NOT attached, stays quarantined, and warns", {
  setup <- ingest_test_setup()

  input_dir <- withr::local_tempdir()
  esdat_dir <- testthat::test_path("fixtures", "esdat")
  copied <- 0L
  for (f in list.files(esdat_dir, full.names = TRUE)) {
    if (grepl("ES2617126|XX1234567", basename(f))) {
      file.copy(f, file.path(input_dir, basename(f)))
      copied <- copied + 1L
    }
  }
  expect_true(copied > 3,
              info = "R-9.8 precondition: the folder must hold TWO work orders' files, else the ambiguity under test does not exist")

  renamed <- file.path(input_dir, "Certificate of Analysis_COA.pdf")
  writeBin(charToRaw(paste("fake COA, ambiguous folder",
                           paste(1:20, collapse = " "))), renamed)
  renamed_hash <- hash_file(renamed)

  expect_warning(
    ingest_dir(input_dir, db = setup$db_path),
    regexp = "work order could not be recovered",
    fixed = TRUE
  )

  con <- DBI::dbConnect(duckdb::duckdb(), setup$db_path, read_only = TRUE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  expect_equal(
    nrow(DBI::dbGetQuery(con, "SELECT 1 FROM asset WHERE hash = ?", params = list(renamed_hash))), 0,
    info = "R-9.8: an ambiguous folder must not pick a work order - eight WOs shared the real batch-2026-07-23 folder"
  )

  states <- ingest_file_states(setup$db_path)
  st <- states[!is.na(states$hash) & states$hash == renamed_hash, ]
  expect_identical(st$state[[1]], "quarantined")
})

# NOTE: the arm that used to sit here asserted the OPPOSITE - that an ACIRL
# 2400-* deliverable is never inferred onto a folder-mate's work order. Robin
# overturned that on 2026-07-28 ("Retain and attach to ALS WO"), and the live
# DB agrees: 104 of 124 ACIRL assets are already filed against an ES#######
# project. The retain case now lives in R-9.12 above; the ambiguity case (two
# work orders, or none) is what still refuses, and is covered there too.

test_that("R-9.8: inference never overrides a filename that DOES carry a work order", {
  setup <- ingest_test_setup()

  input_dir <- withr::local_tempdir()
  esdat_dir <- testthat::test_path("fixtures", "esdat")
  for (f in list.files(esdat_dir, pattern = "ES2617126", full.names = TRUE)) {
    file.copy(f, file.path(input_dir, basename(f)))
  }

  # A COA naming a DIFFERENT, uncommitted work order. The folder resolves
  # cleanly to ES2617126, so a rule that let the folder win would attach this
  # to ES2617126 - silently filing one work order's certificate under another.
  coa <- write_coa_fixture(input_dir, "ES2699999")

  ingest_dir(input_dir, db = setup$db_path)

  con <- DBI::dbConnect(duckdb::duckdb(), setup$db_path, read_only = TRUE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  expect_equal(
    nrow(DBI::dbGetQuery(con, "SELECT 1 FROM asset WHERE hash = ?", params = list(coa$hash))), 0,
    info = "R-9.8: the filename's own work order wins; a folder disagreeing with it must not override it"
  )
  expect_equal(
    nrow(DBI::dbGetQuery(con, "SELECT 1 FROM project WHERE name = 'ES2699999'")), 0
  )
})

# ---- R-9.7: ingest_inbox(), one batch per email folder --------------------
#
# PowerAutomate drops one lab email's attachments into their own folder under
# the input root. ingest_dir() is deliberately non-recursive (R-9.5, and its
# "subdirectory content untouched" criterion is still live), so the inbox needs
# its own entry point rather than a recurse flag.

# (`seed_wo_folder()` is defined with the other fixture builders at the top of
# this file.)

test_that("R-9.7: two email folders each ingest as their own batch, and neither folder's files appear in the other's report", {
  setup <- ingest_test_setup()
  root <- withr::local_tempdir()

  expect_equal(seed_wo_folder(file.path(root, "email-001"), "ES2617126"), 3)
  expect_equal(seed_wo_folder(file.path(root, "email-002"), "XX1234567"), 3)

  reports <- ingest_inbox(root, db = setup$db_path)

  expect_setequal(names(reports$folders), c("email-001", "email-002"))
  expect_equal(reports$n_folders, 2L)

  # Batch isolation is the whole point of per-folder over recurse: each report
  # must account for its OWN three files and no others. A recursive single
  # batch would show 6 in one report and nothing would catch it.
  expect_equal(reports$folders[["email-001"]]$n_files_routed, 3)
  expect_equal(reports$folders[["email-002"]]$n_files_routed, 3)

  con <- DBI::dbConnect(duckdb::duckdb(), setup$db_path, read_only = TRUE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  expect_equal(nrow(DBI::dbGetQuery(con, "SELECT 1 FROM project WHERE name = 'ES2617126'")), 1)
  expect_equal(nrow(DBI::dbGetQuery(con, "SELECT 1 FROM project WHERE name = 'XX1234567'")), 1)
})

test_that("R-9.7: a folder whose ingest throws is reported as failed and the OTHER folders still commit", {
  setup <- ingest_test_setup()
  root <- withr::local_tempdir()
  seed_wo_folder(file.path(root, "email-bad"), "ES2617126")
  seed_wo_folder(file.path(root, "email-good"), "XX1234567")

  real_ingest_dir <- ingest_dir
  testthat::local_mocked_bindings(
    ingest_dir = function(path, ...) {
      if (identical(basename(path), "email-bad")) {
        cli::cli_abort("injected per-folder failure", class = "sampletidy_error")
      }
      real_ingest_dir(path, ...)
    }
  )

  expect_warning(
    reports <- ingest_inbox(root, db = setup$db_path),
    regexp = "email-bad"
  )

  expect_true(reports$folders[["email-bad"]]$failed)
  expect_match(reports$folders[["email-bad"]]$error, "injected per-folder failure", fixed = TRUE)
  expect_equal(reports$n_folders_failed, 1L)

  # Containment is the claim, so assert the good folder actually landed rather
  # than merely that no error propagated.
  con <- DBI::dbConnect(duckdb::duckdb(), setup$db_path, read_only = TRUE)
  # withr::defer, not on.exit - this test mocks ingest_dir() above, and a bare
  # on.exit() would wipe the mock's own restore handler (see the round-2 item 5
  # test earlier in this file).
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  expect_equal(nrow(DBI::dbGetQuery(con, "SELECT 1 FROM project WHERE name = 'XX1234567'")), 1)
})

test_that("R-9.7: loose files sitting directly in the root are neither routed nor deleted", {
  setup <- ingest_test_setup()
  withr::local_options(list("sampletidy.remove_ingested" = TRUE))
  root <- withr::local_tempdir()
  seed_wo_folder(file.path(root, "email-001"), "ES2617126")

  # A stray file at the root - a half-finished download, a note, whatever.
  # Mixing root-level files into the sweep would make the batch boundary
  # ambiguous, so they are ingest_dir()'s job and not ours.
  loose <- file.path(root, "ES2617126_0_COA.pdf")
  writeBin(charToRaw(paste("loose COA at the root", paste(1:20, collapse = " "))), loose)
  loose_hash <- hash_file(loose)

  ingest_inbox(root, db = setup$db_path)

  expect_true(file.exists(loose),
              info = "R-9.7: a root-level file must never be deleted by an inbox sweep")
  states <- ingest_file_states(setup$db_path)
  expect_equal(sum(!is.na(states$hash) & states$hash == loose_hash), 0,
               info = "R-9.7: a root-level file must not be routed at all")
})

test_that("R-9.7: dry_run propagates to every folder - zero DB writes across all of them", {
  setup <- ingest_test_setup()
  root <- withr::local_tempdir()
  seed_wo_folder(file.path(root, "email-001"), "ES2617126")
  seed_wo_folder(file.path(root, "email-002"), "XX1234567")

  before <- all_core_counts(setup$db_path)
  reports <- ingest_inbox(root, db = setup$db_path, dry_run = TRUE)
  after <- all_core_counts(setup$db_path)

  expect_equal(after, before)
  expect_true(all(vapply(reports$folders, function(r) isTRUE(r$dry_run), logical(1))))
})

test_that("R-9.7: an empty root returns an empty roll-up without error", {
  setup <- ingest_test_setup()
  root <- withr::local_tempdir()

  reports <- ingest_inbox(root, db = setup$db_path)
  expect_equal(reports$n_folders, 0L)
  expect_length(reports$folders, 0L)
})

# ---- R-9.9: empty-folder cleanup ------------------------------------------

test_that("R-9.9: a folder emptied by a clean run is deleted, and a .DS_Store does not keep it alive", {
  setup <- ingest_test_setup()
  withr::local_options(list("sampletidy.remove_ingested" = TRUE))
  root <- withr::local_tempdir()
  folder <- file.path(root, "email-001")
  seed_wo_folder(folder, "ES2617126")

  # The trap this criterion exists for: the real batch-2026-07-23 folder is
  # "empty" and still on disk today purely because Finder left a .DS_Store in
  # it. A literal length(dir()) == 0 emptiness test never fires in practice.
  writeBin(charToRaw("finder cruft"), file.path(folder, ".DS_Store"))

  ingest_inbox(root, db = setup$db_path)

  expect_false(dir.exists(folder),
               info = "R-9.9: a folder holding only ignorable cruft after removal must be deleted")
  expect_true(dir.exists(root),
              info = "R-9.9: the inbox root itself must always survive")
})

test_that("R-9.9: a folder still holding a quarantined file survives", {
  setup <- ingest_test_setup()
  withr::local_options(list("sampletidy.remove_ingested" = TRUE))
  root <- withr::local_tempdir()
  folder <- file.path(root, "email-001")
  seed_wo_folder(folder, "ES2617126")

  # An unattachable deliverable: ES2699999 never committed, so this stays
  # quarantined and un-removed. The folder holds a file a human still has to
  # look at, so deleting the folder would delete the only copy.
  orphan <- write_coa_fixture(folder, "ES2699999")

  ingest_inbox(root, db = setup$db_path)

  expect_true(dir.exists(folder),
              info = "R-9.9: a folder holding a kept-back file must survive")
  expect_true(file.exists(orphan$path))
})

test_that("R-9.9: nothing is deleted when remove_ingested is FALSE", {
  setup <- ingest_test_setup()   # remove_ingested defaults FALSE here
  root <- withr::local_tempdir()
  folder <- file.path(root, "email-001")
  seed_wo_folder(folder, "ES2617126")

  ingest_inbox(root, db = setup$db_path)

  expect_true(dir.exists(folder),
              info = "R-9.9: folder cleanup is strictly downstream of R-9.6's remove gate")
  expect_true(length(list.files(folder)) > 0)
})

# ---- R-9.10: retention alone earns a snapshot (negative arm) --------------

test_that("R-9.10: a run that neither commits nor retains produces NO snapshot and removes nothing", {
  setup <- ingest_test_setup()
  withr::local_options(list("sampletidy.remove_ingested" = TRUE))
  input_dir <- withr::local_tempdir()

  # Ordinary cruft: ignored by ignore_rule(), never retained, never committed.
  # Without this arm, "snapshot when anything happened" could degenerate into
  # "always snapshot", and the R-9.6 gate would stop meaning anything.
  bak <- file.path(input_dir, "old_export.bak")
  writeBin(charToRaw("not a deliverable"), bak)

  report <- ingest_dir(input_dir, db = setup$db_path)

  expect_true(is.na(report$snapshot_path),
              info = "R-9.10: no commit and no retention means no snapshot")
  expect_length(report$removed_files, 0L)
  expect_true(file.exists(bak))
})

# ---- R-9.11: quarantine_report() ------------------------------------------

test_that("R-9.11: quarantine_report() returns exactly the non-archived terminal rows, with a derived work_order_guess and no writes", {
  setup <- ingest_test_setup()
  input_dir <- withr::local_tempdir()
  esdat_dir <- testthat::test_path("fixtures", "esdat")
  # TWO work orders, so the folder is ambiguous and R-9.12 inference declines.
  # With only one, the ACIRL report below would be retained and attached (which
  # is now correct), and this report would have nothing ACIRL to show.
  for (f in list.files(esdat_dir, full.names = TRUE)) {
    if (grepl("ES2617126|XX1234567", basename(f))) {
      file.copy(f, file.path(input_dir, basename(f)))
    }
  }

  # One quarantined file we CAN name a work order for, one we deliberately
  # cannot (the ACIRL trap) - the report must show both and guess neither
  # wrongly.
  als <- write_coa_fixture(input_dir, "ES2699999")   # unattachable -> quarantined
  acirl <- file.path(input_dir, "2400-7538-02 January 2026 Quarterly Katoomba WMF.pdf")
  writeBin(charToRaw(paste("fake ACIRL report", paste(1:20, collapse = " "))), acirl)
  acirl_hash <- hash_file(acirl)

  suppressWarnings(ingest_dir(input_dir, db = setup$db_path))

  # `all_table_counts()`, not `all_core_counts()`: this call is a pure read, so
  # the strongest available assertion applies - EVERY base table, including the
  # `ingest_file`/`ingest_sighting` routing tables a dry run is allowed to grow
  # but a report is not.
  before <- all_table_counts(setup$db_path)
  rep <- quarantine_report(db = setup$db_path)
  after <- all_table_counts(setup$db_path)[names(before)]
  expect_equal(after, before, info = "R-9.11: the report must write nothing")

  expect_true(all(c("hash", "filename", "path_first_seen", "state", "state_reason",
                    "work_order_guess", "first_seen_at") %in% names(rep)))

  # Exactly the quarantined pair - the three committed esdat files are
  # `archived` and must NOT appear.
  expect_setequal(rep$hash, c(als$hash, acirl_hash))
  expect_true(all(rep$state %in% c("quarantined", "failed")))

  als_row <- rep[rep$hash == als$hash, ]
  expect_identical(als_row$work_order_guess[[1]], "ES2699999")
  acirl_row <- rep[rep$hash == acirl_hash, ]
  expect_true(is.na(acirl_row$work_order_guess[[1]]),
              info = "R-9.11: a 2400-* name must never be guessed at - the ACIRL trap applies to the report too")
})

test_that("R-9.11: quarantine_report() on a clean DB returns a zero-ROW tibble with the full column set, not NULL", {
  setup <- ingest_test_setup()
  rep <- quarantine_report(db = setup$db_path)

  expect_s3_class(rep, "tbl_df")
  expect_equal(nrow(rep), 0)
  expect_true(all(c("hash", "filename", "path_first_seen", "state", "state_reason",
                    "work_order_guess", "first_seen_at") %in% names(rep)),
              info = "R-9.11: a zero-row result must still carry every column, or downstream code breaks only when there is nothing to report")
})

test_that("R-9.11: quarantine_report() works when the quarantined files no longer exist on disk", {
  setup <- ingest_test_setup()
  input_dir <- withr::local_tempdir()
  coa <- write_coa_fixture(input_dir, "ES2699999")
  ingest_dir(input_dir, db = setup$db_path)

  # By the time anyone runs this report the input folder is routinely gone -
  # a report that re-reads the file to derive its metadata would error, and a
  # report that errors is a report nobody runs.
  file.remove(coa$path)
  expect_false(file.exists(coa$path))

  rep <- quarantine_report(db = setup$db_path)
  expect_equal(nrow(rep), 1)
  expect_identical(rep$work_order_guess[[1]], "ES2699999")
})

# ---- R-9.13: the ALS-source gate (A74) -------------------------------------
#
# Robin's ruling, 2026-08-01: an ACIRL water sheet may only be imported when we
# hold the ALS report it cites, because most of the sheet is ALS data copied by
# hand and the transcription drops reporting limits. Dust is exempt (A73).
#
# Measured over the 154 real workbooks the adapter claims: 16 cite a work order
# the live DB does not hold (614 rows), 1 has water sheets but cites nothing at
# all (30 rows), 7 are dust-only and exempt.

acirl_fx <- function(name) {
  testthat::test_path("fixtures", "acirl", name)
}

# Drop an ACIRL fixture into `dir`. Returns path + hash, captured before ingest.
seed_acirl <- function(dir, name) {
  src <- acirl_fx(name)
  dest <- file.path(dir, name)
  file.copy(src, dest)
  list(path = dest, hash = hash_file(dest), filename = name)
}

# The ESdat PROJ_A triple, rewritten to work order `wo`, so a batch can contain
# a genuine ALS sibling for an arbitrary work order. `XX1234567` appears in the
# filenames AND inside all three files (SampleCode prefix, Lab_Report_Number,
# the XML attribute), so a plain substitution moves the whole bundle.
seed_esdat_as <- function(dir, wo) {
  src <- list.files(testthat::test_path("fixtures", "esdat"),
                    pattern = "PROJ_A", full.names = TRUE)
  stopifnot(length(src) == 3)
  for (f in src) {
    # Byte-wise, not readLines(): the ESdat fixtures deliberately carry
    # non-UTF-8 bytes (they are also the encoding fixtures), and reading them
    # as text fails with "input string is invalid in this locale".
    raw <- readBin(f, "raw", file.size(f))
    txt <- rawToChar(raw)
    Encoding(txt) <- "bytes"
    txt <- gsub("XX1234567", wo, txt, fixed = TRUE, useBytes = TRUE)
    writeBin(charToRaw(txt),
             file.path(dir, gsub("XX1234567", wo, basename(f), fixed = TRUE)))
  }
  invisible(wo)
}

# Give the DB a committed `project` row for `wo` - i.e. "we already hold the
# ALS report". Written through `db_append()`, the mutation layer's own door, so
# it lands in exactly the shape (and with the change_log entry) a real commit
# would leave. `add_project()` itself is not used: it resolves its own
# connection from `st_config("live_db")` rather than taking a `db`.
hold_work_order <- function(db_path, wo) {
  with_db_write(function(con) {
    db_append(con, "project", tibble::tibble(
      uuid = uuid::UUIDgenerate(), name = wo, type = "Work order"
    ), actor = "test", reason = "R-9.13 fixture: we hold this ALS report")
  }, db = db_path)
  invisible(wo)
}

# Does the DB hold a `project` row for `wo`?
holds_work_order <- function(db_path, wo) {
  con <- DBI::dbConnect(duckdb::duckdb(), db_path, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  nrow(DBI::dbGetQuery(con, "SELECT 1 FROM project WHERE name = ?",
                       params = list(wo))) > 0
}

state_of <- function(db_path, hash) {
  s <- ingest_file_states(db_path)
  s <- s[!is.na(s$hash) & s$hash == hash, ]
  if (nrow(s) == 0) return(NULL)
  list(state = s$state[[1]], reason = s$state_reason[[1]])
}

test_that("R-9.13: an ACIRL workbook whose cited ALS work order IS held imports", {
  setup <- ingest_test_setup()
  input_dir <- withr::local_tempdir()
  fx <- seed_acirl(input_dir, "2400-9999-11_Real_WMF.xlsx")
  hold_work_order(setup$db_path, "ES9999001")

  report <- ingest_dir(input_dir, db = setup$db_path)

  expect_identical(report$als_gated, character(0))
  expect_gt(report$rows_new, 0)
  expect_gt(count_rows(setup$db_path, "analysis"), 0)
  expect_identical(state_of(setup$db_path, fx$hash)$state, "archived")
})

test_that("R-9.13: the SAME workbook is quarantined als_source_missing when the work order is not held, and contributes nothing", {
  setup <- ingest_test_setup()
  input_dir <- withr::local_tempdir()
  fx <- seed_acirl(input_dir, "2400-9999-11_Real_WMF.xlsx")
  # deliberately NO hold_work_order() - this is the only difference from the
  # test above, so anything that differs in the outcome is the gate's doing.
  before <- all_core_counts(setup$db_path)

  expect_warning(
    report <- ingest_dir(input_dir, db = setup$db_path),
    regexp = "ES9999001"
  )

  st <- state_of(setup$db_path, fx$hash)
  expect_identical(st$state, "quarantined")
  expect_identical(st$reason, "als_source_missing")
  expect_identical(report$als_gated, fx$hash)

  # zero rows, zero events, zero review items - the file must not reach
  # assemble at all, not merely fail to commit.
  expect_identical(report$n_events, 0L)
  expect_identical(report$rows_new, 0L)
  expect_identical(report$review_items_opened, 0L)
  expect_equal(all_core_counts(setup$db_path), before)
})

test_that("R-9.13: A74 requires ALL cited work orders - one of two held is still gated", {
  setup <- ingest_test_setup()
  input_dir <- withr::local_tempdir()
  # 2400-9999-13 cites ES9999001/ES9999002 on its first sheet.
  fx <- seed_acirl(input_dir, "2400-9999-13_AlsRefs_WMF.xlsx")
  expect_setequal(
    adapter_registry()[["acirl_field_xlsx"]]$parse(fx$path, sampleTidy:::file_meta(fx$path))$report$als_work_orders,
    c("ES9999001", "ES9999002")
  )
  hold_work_order(setup$db_path, "ES9999001")

  expect_warning(
    report <- ingest_dir(input_dir, db = setup$db_path),
    regexp = "ES9999002"
  )
  expect_identical(state_of(setup$db_path, fx$hash)$reason, "als_source_missing")
  expect_identical(report$rows_new, 0L)

  # ...and holding the second one too lets it through, so the gate is keyed on
  # the missing order and not on "this fixture always fails".
  hold_work_order(setup$db_path, "ES9999002")
  report2 <- ingest_dir(input_dir, db = setup$db_path)
  expect_identical(report2$als_gated, character(0))
  expect_gt(report2$rows_new, 0)
})

test_that("R-9.13/A73: a dust-only workbook is NEVER gated, whatever the DB holds", {
  setup <- ingest_test_setup()
  input_dir <- withr::local_tempdir()
  fx <- seed_acirl(input_dir, "2400-9999-12_DustOnly_WMF.xlsx")
  # precondition: it really does cite nothing and really has no water sheet -
  # otherwise this test would pass for the wrong reason.
  rep_parse <- adapter_registry()[["acirl_field_xlsx"]]$parse(fx$path, sampleTidy:::file_meta(fx$path))$report
  expect_identical(rep_parse$als_work_orders, character(0))
  expect_identical(rep_parse$n_water_sheets, 0L)

  report <- ingest_dir(input_dir, db = setup$db_path)

  expect_identical(report$als_gated, character(0))
  expect_false(identical(state_of(setup$db_path, fx$hash)$reason, "als_source_missing"))
})

test_that("R-9.13: water sheets that cite NOTHING are gated, not exempted", {
  setup <- ingest_test_setup()
  input_dir <- withr::local_tempdir()
  # The `2400-7483-01 May 2025 Lawson Landfill.xls` shape: real water data, ALS
  # cell reads a bare "ES". This is the one criterion separating the gate's
  # design from the naive "cites nothing -> must be dust -> exempt".
  fx <- seed_acirl(input_dir, "2400-9999-15_Uncited_WMF.xlsx")
  rep_parse <- adapter_registry()[["acirl_field_xlsx"]]$parse(fx$path, sampleTidy:::file_meta(fx$path))$report
  expect_identical(rep_parse$als_work_orders, character(0))
  expect_gt(rep_parse$n_water_sheets, 0)

  expect_warning(
    report <- ingest_dir(input_dir, db = setup$db_path),
    regexp = "cites no ALS report"
  )
  expect_identical(state_of(setup$db_path, fx$hash)$reason, "als_source_missing")
  expect_identical(report$rows_new, 0L)
})

test_that("R-9.13: an ALS sibling in the SAME batch satisfies the gate, in one run", {
  for (acirl_first in c(TRUE, FALSE)) {
    setup <- ingest_test_setup()
    input_dir <- withr::local_tempdir()
    # File order within the directory is what `fs::dir_ls()` returns, so seed
    # the two in both orders: the gate must not depend on parse order, which is
    # the whole reason it is a separate pass after parsing.
    if (acirl_first) {
      fx <- seed_acirl(input_dir, "2400-9999-11_Real_WMF.xlsx")
      seed_esdat_as(input_dir, "ES9999001")
    } else {
      seed_esdat_as(input_dir, "ES9999001")
      fx <- seed_acirl(input_dir, "2400-9999-11_Real_WMF.xlsx")
    }
    # precondition: the work order is NOT already in the DB, so the same-batch
    # arm is the only thing that can be satisfying the gate here.
    expect_false(holds_work_order(setup$db_path, "ES9999001"),
                 info = "precondition: ES9999001 must not be pre-held")

    report <- ingest_dir(input_dir, db = setup$db_path)

    expect_identical(report$als_gated, character(0),
                     info = paste("acirl_first =", acirl_first))
    expect_identical(state_of(setup$db_path, fx$hash)$state, "archived",
                     info = paste("acirl_first =", acirl_first))
  }
})

test_that("R-9.13: gating one file does not stop the rest of the batch", {
  setup <- ingest_test_setup()
  input_dir <- withr::local_tempdir()
  fx <- seed_acirl(input_dir, "2400-9999-11_Real_WMF.xlsx")   # will be gated
  seed_esdat_as(input_dir, "XX7777777")                        # unrelated, must commit

  expect_warning(report <- ingest_dir(input_dir, db = setup$db_path), regexp = "ES9999001")

  expect_identical(state_of(setup$db_path, fx$hash)$reason, "als_source_missing")
  expect_gt(report$rows_new, 0)
  con <- DBI::dbConnect(duckdb::duckdb(), setup$db_path, read_only = TRUE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  expect_equal(
    nrow(DBI::dbGetQuery(con, "SELECT 1 FROM project WHERE name = 'XX7777777'")), 1
  )
})

test_that("R-9.13: a non-ACIRL adapter family is never gated", {
  setup <- ingest_test_setup()
  input_dir <- withr::local_tempdir()
  seed_esdat_as(input_dir, "ES9999001")
  # An ESdat report's own `report` list carries no `als_work_orders` field, so
  # the gate must not look at it at all - not even to conclude "cites nothing".
  report <- ingest_dir(input_dir, db = setup$db_path)
  expect_identical(report$als_gated, character(0))
  expect_gt(report$rows_new, 0)
})

test_that("R-9.13: dry_run reports the verdict and writes nothing", {
  setup <- ingest_test_setup()
  input_dir <- withr::local_tempdir()
  fx <- seed_acirl(input_dir, "2400-9999-11_Real_WMF.xlsx")
  before <- all_core_counts(setup$db_path)

  expect_warning(
    report <- ingest_dir(input_dir, db = setup$db_path, dry_run = TRUE),
    regexp = "ES9999001"
  )

  # the verdict IS reported...
  expect_identical(report$als_gated, fx$hash)
  expect_identical(report$rows_new, 0L)
  # ...and nothing is persisted: no core-table write, and the file is NOT left
  # sitting in a terminal `quarantined` state a later real run cannot leave.
  expect_equal(all_core_counts(setup$db_path), before)
  expect_false(identical(state_of(setup$db_path, fx$hash)$state, "quarantined"))
})

test_that("R-9.13: a gated file re-processes on the NEXT ordinary run once its ALS report lands - no reconsider flag", {
  setup <- ingest_test_setup()
  input_dir <- withr::local_tempdir()
  fx <- seed_acirl(input_dir, "2400-9999-11_Real_WMF.xlsx")

  expect_warning(ingest_dir(input_dir, db = setup$db_path), regexp = "ES9999001")
  expect_identical(state_of(setup$db_path, fx$hash)$state, "quarantined")

  # ACIRL routinely arrives BEFORE ALS, so this is the normal sequence: the
  # source report shows up later and the workbook must import itself without
  # anyone remembering to pass `reconsider = TRUE`.
  hold_work_order(setup$db_path, "ES9999001")
  report <- ingest_dir(input_dir, db = setup$db_path)

  expect_identical(report$als_gated, character(0))
  expect_gt(report$rows_new, 0)
  expect_identical(state_of(setup$db_path, fx$hash)$state, "archived")
})

test_that("R-9.13: a still-unheld gated file stays quarantined on re-run and imports nothing twice", {
  setup <- ingest_test_setup()
  input_dir <- withr::local_tempdir()
  fx <- seed_acirl(input_dir, "2400-9999-11_Real_WMF.xlsx")

  expect_warning(ingest_dir(input_dir, db = setup$db_path), regexp = "ES9999001")
  after_first <- all_core_counts(setup$db_path)

  # The unconditional re-decision must not turn into a loop that accretes
  # state: a second run re-parses, re-gates, and changes nothing.
  expect_warning(report <- ingest_dir(input_dir, db = setup$db_path), regexp = "ES9999001")
  expect_identical(state_of(setup$db_path, fx$hash)$reason, "als_source_missing")
  expect_identical(report$rows_new, 0L)
  expect_equal(all_core_counts(setup$db_path), after_first)
})

test_that("R-9.13: a file may not vouch for ITSELF - its own work order does not satisfy its own citation", {
  # Unreachable through ingest_dir() today: an ACIRL workbook's home work order
  # is always NA because `2400-*` is never parsed into one (R-9.12's ACIRL
  # trap). So this drives `.ig_als_gate()` directly, with a file whose home work
  # order IS the order it cites - the shape a mis-named workbook would have.
  setup <- ingest_test_setup()

  self_citing <- list(
    ir = list(results = NULL, samples = NULL),
    report = list(als_work_orders = "ES9999001", n_water_sheets = 2L,
                  header = list(work_order = "ES9999001")),
    meta = list(filename = "ES9999001_mislabelled.xlsx",
                work_order_guess = "ES9999001")
  )
  # precondition: it really does look like its own source, so a gate that
  # naively unioned the batch's work orders WOULD pass it.
  expect_identical(
    sampleTidy:::.st_home_work_order(self_citing$report, self_citing$meta),
    "ES9999001"
  )

  out <- with_db_write(function(con) {
    sampleTidy:::.ig_als_gate(con, list(h1 = self_citing), dry_run = TRUE)
  }, db = setup$db_path)

  expect_identical(out$gated, "h1")
  expect_length(out$parsed, 0)
})

test_that("R-9.13: gating alone takes no snapshot and removes no source", {
  setup <- ingest_test_setup()
  input_dir <- withr::local_tempdir()
  fx <- seed_acirl(input_dir, "2400-9999-11_Real_WMF.xlsx")
  withr::local_options(list("sampletidy.remove_ingested" = TRUE))

  expect_warning(report <- ingest_dir(input_dir, db = setup$db_path), regexp = "ES9999001")

  # A quarantined file has no asset row, so there is nothing verified to remove
  # and nothing committed to snapshot. Both must stay untriggered, or a gated
  # run would delete the very source it is waiting to re-process.
  expect_true(is.na(report$snapshot_path))
  expect_identical(report$removed_files, character(0))
  expect_true(file.exists(fx$path))
  expect_equal(length(list.files(setup$snapshot_dir)), 0)
})
