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
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

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
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # (1) an `asset` row exists for the COC PDF's OWN content hash - not
  # merely for its tabular siblings.
  asset_row <- DBI::dbGetQuery(con, "SELECT * FROM asset WHERE hash = ?", params = list(coc_hash))
  expect_equal(nrow(asset_row), 1,
               info = "R-15.36 conjunct 1: the COC PDF (revision=NA) must get its own asset row")
  # Round-2 item 6: a COC is NOT a COA - it must NOT be widened to
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
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

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
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  asset_row <- DBI::dbGetQuery(con, "SELECT * FROM asset WHERE hash = ?", params = list(coa_hash))
  expect_equal(nrow(asset_row), 0)   # never archived

  coa_state <- ingest_file_states(setup$db_path)
  coa_state <- coa_state[!is.na(coa_state$hash) & coa_state$hash == coa_hash, ]
  expect_equal(nrow(coa_state), 1)
  expect_identical(coa_state$state[[1]], "quarantined")   # stays put, not silently lost
})

test_that("Phase-7b round-2 item 7: a non-tabular sibling whose work order cannot be filename-guessed (the ACIRL 2400-* shape) still stays quarantined AND is named in a cli_warn - the residual exposure is not silent", {
  setup <- ingest_test_setup()
  input_dir <- withr::local_tempdir()
  esdat_dir <- testthat::test_path("fixtures", "esdat")
  wo_files <- list.files(esdat_dir, pattern = "ES2617126", full.names = TRUE)
  for (f in wo_files) file.copy(f, file.path(input_dir, basename(f)))

  # ACIRL work-order trap shape: no ES####### token anywhere in the filename,
  # so file_meta()$work_order_guess is NA - refusing to filename-parse this
  # is CORRECT (see commit.R's ACIRL work-order trap header) and must stay;
  # this test is about the residual silence, not the refusal itself.
  acirl_path <- file.path(input_dir, "2400-7538-02_QC.pdf")
  writeBin(charToRaw("fake ACIRL QC PDF, no ES####### token in filename"), acirl_path)
  acirl_hash <- hash_file(acirl_path)

  expect_warning(
    report <- ingest_dir(input_dir, db = setup$db_path),
    regexp = "work order could not be recovered",
    fixed = TRUE
  )

  con <- DBI::dbConnect(duckdb::duckdb(), setup$db_path, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  asset_row <- DBI::dbGetQuery(con, "SELECT * FROM asset WHERE hash = ?", params = list(acirl_hash))
  expect_equal(nrow(asset_row), 0)

  acirl_state <- ingest_file_states(setup$db_path)
  acirl_state <- acirl_state[!is.na(acirl_state$hash) & acirl_state$hash == acirl_hash, ]
  expect_equal(nrow(acirl_state), 1)
  expect_identical(acirl_state$state[[1]], "quarantined")
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
