# Plan 15 - dev/migrations/004-view-repair.R (R-15.35 / plan block B-15.F12).
#
# TARGET FILE CONTRACT (the target file is TDD-red/unwritten; this is the
# interface Phase 6 must implement so these tests pass - not part of the
# package NAMESPACE, so tests `sys.source()` it directly via `.mig004_load()`
# below, mirroring test-migration-001.R / test-migration-002.R's idiom
# exactly):
#
#   mig004_run(db, snapshot_dir, dry_run = FALSE, .now = NULL)
#     -> invisible list(status = "migrated" | "already_migrated" | "dry_run",
#        backup_path = chr or NA, restore_command = chr or NA, ...)
#     Repairs the two F.12 defects left by 001's view rebuild:
#       (a) the `fm.variant = 'epa'` (lowercase) vs `'EPA'` (the case
#           `feature_mask.variant` actually stores) mismatch, which makes
#           `v_measurement_epa` silently return zero rows;
#       (b) the 4/5-column projection gutting on `v_measurement` /
#           `v_measurement_epa` / `_old` / `_long` / `_gas_report`.
#     ORCHESTRATOR RULING 2026-07-24 (recorded in the plan, DECOUPLED from
#     F.11): the restored `date` projection is derived from `datetime` (the
#     Sydney calendar date) and MUST NEVER select the raw `sample.date`
#     column. 004 is a NEW migration - it must DROP + recreate the affected
#     views itself (never edit 001).
#
# Every test sources the target file inside its own `test_that()` (never at
# file top level), so a missing/broken target file surfaces as an ordinary
# per-test failure - not a whole-file collection error that would silently
# zero out every other test's coverage. Every test here is also gated on 001
# actually existing and applying cleanly first: 004 repairs 001's OUTPUT, so
# testing it against a hand-built post-001 DDL would hide the exact
# case-mismatch defect it exists to fix (same rationale as
# test-migration-002.R's dependency on 001).

.mig004_load <- function() {
  env <- new.env(parent = globalenv())
  path <- testthat::test_path("..", "..", "dev", "migrations", "004-view-repair.R")
  skip_if_not(file.exists(path), "dev/migrations/004-view-repair.R not yet written (expected pre-Phase-6)")
  sys.source(path, envir = env)
  env
}

.mig001_load <- function() {
  env <- new.env(parent = globalenv())
  path <- testthat::test_path("..", "..", "dev", "migrations", "001-alias-indirection.R")
  skip_if_not(file.exists(path), "dev/migrations not in built package (run via devtools::test)")
  sys.source(path, envir = env)
  env
}

#' Add one feature/sample/analysis row reached through a feature_mask 'EPA'
#' (uppercase) variant - the exact case stored in production per plan block
#' B-15.F12(a): "feature_mask.variant stores 'EPA'", contrasted with 001's
#' hardcoded lowercase `fm.variant = 'epa'` filter (the defect this
#' criterion targets).
#'
#' `sample.date` is deliberately seeded a day off from the Sydney calendar
#' date implied by `datetime` (2024-06-10 vs the true 2024-06-15, in
#' `Australia/Sydney` = UTC+10 in June, no DST). This is the F.12(b)
#' DECOUPLED rule's own footgun (language-footguns.md / brief): the restored
#' `date` projection must derive from `datetime`, never select
#' `sample.date` - this fixture makes an implementation that violates that
#' rule provably wrong (lands on 2024-06-10) rather than accidentally
#' correct.
#'
#' Reuses `lm-901` (`seed_pre_migration_db()`'s own lab_method fixture) so
#' this stays additive, matching test-migration-002.R's
#' `seed_carbophenothion_duplicate()` / `seed_reported_as_fixture()`
#' convention of adding fixture rows on top of the shared base seed rather
#' than duplicating it.
#'
#' @param con an open read-write DBI connection to a DB seeded by
#'   `seed_pre_migration_db()`.
#' @return invisible(NULL).
.seed_004_epa_case_fixture <- function(con) {
  DBI::dbExecute(con, "INSERT INTO feature
    (uuid, name, site, flow, matrix, lon, lat, cypher) VALUES
    ('f-201', 'PM-EPA-CASE', 'PreMigSite', 'surface', 'water', 150.2001, -33.2001, NULL)")

  DBI::dbExecute(con, "INSERT INTO feature_mask (uuid_feature, variant, name) VALUES
    ('f-201', 'EPA', 'EPA-PM-CASE')")

  DBI::dbExecute(con, "INSERT INTO \"sample\"
    (uuid, uuid_feature, date, datetime, organisation) VALUES
    ('s-epa-201', 'f-201', TIMESTAMP '2024-06-10 00:00:00', TIMESTAMP '2024-06-15 03:00:00', 'ALS')")

  DBI::dbExecute(con, "INSERT INTO analysis
    (uuid, uuid_sample, uuid_lab, value, quantified, rl_low) VALUES
    ('an-epa-201', 's-epa-201', 'lm-901', 7.7, TRUE, 0.1)")

  invisible(NULL)
}

#' Seed a pre-migration DB carrying the R-15.35 EPA-case fixture, then run
#' 001 followed by (the target) 004 against it.
#'
#' Threads the CALLING TEST's frame through explicitly for every
#' `withr::local_tempdir()` used (language-footguns.md R section: the
#' wrong-frame trap) - a bare/default-arg form here would tear the tempdir
#' (and the DB file inside it) down the instant this helper returns, before
#' the calling test's own assertions run. Mirrors test-migration-002.R's
#' `.seed_002_db()`.
#'
#' @param mig1 environment returned by `.mig001_load()`.
#' @param mig4 environment returned by `.mig004_load()`.
#' @return path to the migrated (001 then 004) DB file.
.run_001_then_004 <- function(mig1, mig4) {
  path <- seed_pre_migration_db(dir = withr::local_tempdir(.local_envir = parent.frame()))

  con0 <- pre_migration_con(path)
  .seed_004_epa_case_fixture(con0)
  DBI::dbDisconnect(con0, shutdown = TRUE)

  mig1$mig001_run(
    db = path,
    snapshot_dir = withr::local_tempdir(.local_envir = parent.frame()),
    dry_run = FALSE
  )
  mig4$mig004_run(
    db = path,
    snapshot_dir = withr::local_tempdir(.local_envir = parent.frame()),
    dry_run = FALSE
  )

  path
}

# =============================================================================
# R-15.35: v_measurement_epa returns nonzero, correct rows
# =============================================================================

test_that("R-15.35: v_measurement_epa returns a nonzero row count equal to an independently computed base-table query for the case-insensitive EPA filter", {
  mig1 <- .mig001_load()
  mig4 <- .mig004_load()
  path <- .run_001_then_004(mig1, mig4)

  con <- pre_migration_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  view_n <- DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM v_measurement_epa")$n

  # Independently computed from the BASE tables for the SAME filter -
  # case-insensitive on feature_mask.variant (the fix a bare `>= 0`
  # assertion would never catch, per the plan's own acceptance text) -
  # never re-deriving the view's own SQL.
  base_n <- DBI::dbGetQuery(con, "
    SELECT COUNT(*) n
    FROM analysis a
    JOIN \"sample\" s ON a.uuid_sample = s.uuid
    JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
    JOIN feature f ON fa.uuid_feature = f.uuid
    JOIN feature_mask fm ON fm.uuid_feature = f.uuid AND UPPER(fm.variant) = 'EPA'
  ")$n

  expect_true(view_n > 0)
  expect_identical(view_n, base_n)
  # Non-vacuous: the fixture plants exactly one measurement reachable via an
  # uppercase 'EPA' mask row, so the count is a known, specific value - not
  # merely "greater than zero". `expect_equal()` (not `expect_identical()`),
  # matching test-migration-001.R's own COUNT(*) convention: DuckDB's
  # COUNT(*) comes back as a double, not an integer.
  expect_equal(view_n, 1L)
})

test_that("R-15.35: v_measurement_epa's restored date column is the Sydney calendar date derived from datetime, never the raw sample.date value", {
  mig1 <- .mig001_load()
  mig4 <- .mig004_load()
  path <- .run_001_then_004(mig1, mig4)

  con <- pre_migration_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  view_row <- DBI::dbGetQuery(con, "SELECT * FROM v_measurement_epa WHERE uuid_sample = 's-epa-201'")
  expect_identical(nrow(view_row), 1L)
  expect_true("date" %in% names(view_row))

  sample_row <- DBI::dbGetQuery(con, "SELECT date, datetime FROM \"sample\" WHERE uuid = 's-epa-201'")

  # Independently computed from the BASE `sample` table, never from the
  # view's own SQL - the Sydney calendar date implied by `datetime`.
  expected_date <- as.Date(sample_row$datetime, tz = "Australia/Sydney")
  # The raw, deliberately-mismatched `sample.date` value the fixture
  # planted: an implementation that selects `sample.date` instead of
  # deriving the date from `datetime` lands here instead (a day off).
  wrong_date <- as.Date(format(sample_row$date, "%Y-%m-%d"))
  expect_false(identical(expected_date, wrong_date)) # fixture sanity check

  got_date <- if (inherits(view_row$date, "POSIXct")) {
    as.Date(format(view_row$date, "%Y-%m-%d"))
  } else {
    as.Date(view_row$date)
  }

  expect_identical(got_date, expected_date)
  expect_false(identical(got_date, wrong_date))
})
