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
  if (!file.exists(path)) {
    # Phase-5 audit B5: a `skip_if_not()` here made this ENTIRE file produce
    # zero results (R-15.35 green-by-skip forever if 004 is never written) -
    # the sibling test-migration-003.R got this right at `.mig003_load()`. A
    # clean, single, named ERROR (never `testthat::fail()`, which records a
    # failure but does not halt execution, so the next line would throw a
    # SECOND redundant condition for the same missing-file cause) - the
    # correct TDD-red state, showing up as exactly one red result per test.
    stop(sprintf("migration file not found (expected TDD-red until Phase 6): %s", path))
  }
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
#' `datetime` is seeded at `2024-06-14 23:00:00` (naive/UTC), which is
#' `2024-06-15 09:00` in `Australia/Sydney` (UTC+10 in June, no DST) - one
#' hour before local midnight, so the naive calendar date and the Sydney
#' calendar date fall on different days. `sample.date` is separately seeded
#' at `2024-06-10`, a third distinct day. This is the F.12(b) DECOUPLED
#' rule's own footgun (language-footguns.md / brief): the restored `date`
#' projection must derive from `datetime`, via the Sydney-local calendar
#' day, never select `sample.date` and never take a timezone-naive
#' `CAST(datetime AS DATE)`. This fixture makes BOTH violations provably
#' wrong rather than accidentally correct: selecting raw `sample.date` lands
#' on 2024-06-10, and a timezone-naive cast of `datetime` lands on
#' 2024-06-14 - only the mandated Sydney-local derivation lands on
#' 2024-06-15 (23:00 UTC + 10h = 09:00 the next Sydney day).
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
    ('s-epa-201', 'f-201', TIMESTAMP '2024-06-10 00:00:00', TIMESTAMP '2024-06-14 23:00:00', 'ALS')")

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

# =============================================================================
# Phase 7b Tier-3: DROP VIEW IF EXISTS - 004 is a VIEW-REPAIR migration, so "a
# view is already missing" is precisely its own use case, not an error.
# =============================================================================

test_that("004-view-repair: runs to completion (does not raw-error) when one of the 5 views is already missing before it runs", {
  mig1 <- .mig001_load()
  mig4 <- .mig004_load()

  path <- seed_pre_migration_db()
  con0 <- pre_migration_con(path)
  .seed_004_epa_case_fixture(con0)
  DBI::dbDisconnect(con0, shutdown = TRUE)

  mig1$mig001_run(db = path, snapshot_dir = withr::local_tempdir(), dry_run = FALSE)

  # Simulate the view-repair use case directly: one of the 5 views 004 owns
  # is already gone by the time 004 runs (e.g. a prior partial repair, or an
  # operator DROPping it by hand).
  con1 <- pre_migration_con(path)
  DBI::dbExecute(con1, "DROP VIEW v_measurement_epa")
  DBI::dbDisconnect(con1, shutdown = TRUE)

  snap_dir <- withr::local_tempdir()
  result <- expect_no_error(
    mig4$mig004_run(db = path, snapshot_dir = snap_dir, dry_run = FALSE)
  )
  expect_equal(result$status, "migrated")

  con2 <- pre_migration_con(path)
  withr::defer(DBI::dbDisconnect(con2, shutdown = TRUE))
  # The view was recreated, not left missing.
  view_n <- DBI::dbGetQuery(con2, "SELECT COUNT(*) n FROM v_measurement_epa")$n
  expect_true(view_n >= 0)
})

# =============================================================================
# Phase 7b round 2, item 1 [RANK 2, orchestrator-verified]: mig004_verify()
# alone compares only the 6 base tables 004 never writes - blind to whether
# .mig004_rebuild_views() did anything. Reproduced: with the rebuild step
# replaced by a no-op, mig004_run() used to return status = "migrated" and
# commit the 1004 marker with the views left unrepaired, permanently (every
# later run then returns "already_migrated"). The fix is a second gate,
# .mig004_verify_views(), that must now throw instead.
# =============================================================================

test_that("004-view-repair: mig004_run() throws (and commits no 1004 marker) when .mig004_rebuild_views() is a no-op - the verify gate must catch an unrepaired view, not just an untouched base table", {
  mig1 <- .mig001_load()
  mig4 <- .mig004_load()

  path <- seed_pre_migration_db()
  con0 <- pre_migration_con(path)
  .seed_004_epa_case_fixture(con0)
  DBI::dbDisconnect(con0, shutdown = TRUE)

  mig1$mig001_run(db = path, snapshot_dir = withr::local_tempdir(), dry_run = FALSE)

  # Reproduce the audit's exact mutation: .mig004_rebuild_views() becomes a
  # no-op inside the loaded environment - mig004_run()'s own lexical scope
  # is `mig4`, so this reassignment is picked up by the unqualified call
  # inside it.
  mig4$.mig004_rebuild_views <- function(con) invisible(NULL)

  snap_dir <- withr::local_tempdir()
  err <- tryCatch(
    mig4$mig004_run(db = path, snapshot_dir = snap_dir, dry_run = FALSE),
    error = function(e) e
  )
  expect_s3_class(err, "sampletidy_error")

  con <- pre_migration_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  marker_n <- DBI::dbGetQuery(con, "SELECT count(*) n FROM schema_version WHERE version = 1004")$n
  expect_equal(marker_n, 0)
  # The pre-existing (001-only, unrepaired) view is still there, still
  # broken - the transaction rolled back, it did not half-apply.
  epa_n <- DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM v_measurement_epa")$n
  expect_equal(epa_n, 0L)
})

# =============================================================================
# Phase 7b round 3, S1: the count oracle used to cover v_measurement_epa
# ONLY - re-introducing the F.12(a) case defect on v_measurement_gas_report
# (Phase-7a mutation S-M1-GAP) used to SURVIVE the full suite. Reproduce the
# exact mutation and require it to now be caught.
# =============================================================================

test_that("004-view-repair (S1): a re-introduced F.12(a) case defect on v_measurement_gas_report is caught by the verify gate, not just v_measurement_epa", {
  mig1 <- .mig001_load()
  mig4 <- .mig004_load()

  path <- seed_pre_migration_db()
  con0 <- pre_migration_con(path)
  .seed_004_epa_case_fixture(con0)
  DBI::dbDisconnect(con0, shutdown = TRUE)
  mig1$mig001_run(db = path, snapshot_dir = withr::local_tempdir(), dry_run = FALSE)

  # Phase-7a mutation S-M1-GAP, reproduced verbatim: the gas_report literal
  # regresses to lowercase, so UPPER(fm.variant) = 'gas_report' matches
  # nothing (feature_mask.variant is always stored/compared uppercase).
  mig4$.mig004_variant_literal[["v_measurement_gas_report"]] <- "gas_report"

  snap_dir <- withr::local_tempdir()
  err <- tryCatch(
    mig4$mig004_run(db = path, snapshot_dir = snap_dir, dry_run = FALSE),
    error = function(e) e
  )
  expect_s3_class(err, "sampletidy_error")

  con <- pre_migration_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  marker_n <- DBI::dbGetQuery(con, "SELECT count(*) n FROM schema_version WHERE version = 1004")$n
  expect_equal(marker_n, 0)
})

# =============================================================================
# Phase 7b round 3, S2: a count-EQUALITY gate alone passes vacuously at
# 0 == 0 on a genuinely variant-free database - indistinguishable from a
# rebuild that silently regressed to matching nothing. Make that a hard
# failure.
# =============================================================================

test_that("004-view-repair (S2): a genuinely variant-free view (independent base-table oracle == 0) is a HARD FAILURE, not a silent pass", {
  mig1 <- .mig001_load()
  mig4 <- .mig004_load()

  path <- seed_pre_migration_db()
  con0 <- pre_migration_con(path)
  .seed_004_epa_case_fixture(con0)
  # Remove the ONLY 'long' feature_mask row in this fixture - v_measurement_long
  # is base-truthfully empty here, not a defect, just an empty variant.
  DBI::dbExecute(con0, "DELETE FROM feature_mask WHERE variant = 'long'")
  DBI::dbDisconnect(con0, shutdown = TRUE)
  mig1$mig001_run(db = path, snapshot_dir = withr::local_tempdir(), dry_run = FALSE)

  snap_dir <- withr::local_tempdir()
  err <- tryCatch(
    mig4$mig004_run(db = path, snapshot_dir = snap_dir, dry_run = FALSE),
    error = function(e) e
  )
  expect_s3_class(err, "sampletidy_error")
  expect_match(conditionMessage(err), "ZERO", fixed = TRUE)

  con <- pre_migration_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  marker_n <- DBI::dbGetQuery(con, "SELECT count(*) n FROM schema_version WHERE version = 1004")$n
  expect_equal(marker_n, 0)
})

# =============================================================================
# Phase 7b round 3, S3: .mig004_base_n() must not be a hand-copy of the
# view's own FROM/JOIN clause (the old EPA-only oracle's flaw) - it agrees
# with an independently-written base-table query for every variant, on real
# fixture data.
# =============================================================================

test_that("004-view-repair (S3): .mig004_base_n() is an independently-computed oracle - agrees with a hand-written base-table query for every variant", {
  mig1 <- .mig001_load()
  mig4 <- .mig004_load()
  path <- .run_001_then_004(mig1, mig4)

  con <- pre_migration_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  for (literal in c("EPA", "OLD", "GAS_REPORT", "LONG")) {
    base_n <- mig4$.mig004_base_n(con, literal)
    hand_n <- DBI::dbGetQuery(con, sprintf("
      SELECT COUNT(*) n
      FROM analysis a
      JOIN \"sample\" s ON a.uuid_sample = s.uuid
      JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
      JOIN feature f ON fa.uuid_feature = f.uuid
      JOIN feature_mask fm ON fm.uuid_feature = f.uuid AND UPPER(fm.variant) = '%s'
    ", literal))$n
    expect_equal(base_n, as.integer(hand_n))
    expect_gt(base_n, 0L)
  }
})

# =============================================================================
# Phase 7b round 3, S4: .mig004_verify_views() must iterate .mig004_five_views
# (the ONE canonical view list), not names(.mig004_expected_view_cols) - a
# view added to the former and forgotten in the latter used to be silently
# never verified.
# =============================================================================

test_that("004-view-repair (S4): .mig004_verify_views() iterates .mig004_five_views - a view present there but missing from .mig004_expected_view_cols is a hard internal-consistency failure, not silently skipped", {
  mig1 <- .mig001_load()
  mig4 <- .mig004_load()
  path <- .run_001_then_004(mig1, mig4)

  con <- pre_migration_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  mig4$.mig004_five_views <- c(mig4$.mig004_five_views, "v_measurement_bogus")
  err <- tryCatch(mig4$.mig004_verify_views(con), error = function(e) e)
  expect_s3_class(err, "sampletidy_error")
  expect_match(conditionMessage(err), "drifted", fixed = TRUE)
})

# =============================================================================
# Phase 7b round 3, S5: mig004_run() used to issue a raw
# `DBI::dbExecute(con, "BEGIN TRANSACTION")` outside its own tryCatch, with
# manual ROLLBACK/COMMIT - replaced with db_transaction() (R/mutate.R),
# mirroring mig003_run(). The wrapped error message (only produced by
# db_transaction()'s own rollback handler) is the observable discriminator.
# =============================================================================

test_that("004-view-repair (S5): mig004_run()'s rollback path runs through db_transaction(), not a raw un-caught BEGIN TRANSACTION", {
  mig1 <- .mig001_load()
  mig4 <- .mig004_load()

  path <- seed_pre_migration_db()
  con0 <- pre_migration_con(path)
  .seed_004_epa_case_fixture(con0)
  DBI::dbDisconnect(con0, shutdown = TRUE)
  mig1$mig001_run(db = path, snapshot_dir = withr::local_tempdir(), dry_run = FALSE)

  mig4$.mig004_rebuild_views <- function(con) invisible(NULL)

  snap_dir <- withr::local_tempdir()
  err <- tryCatch(
    mig4$mig004_run(db = path, snapshot_dir = snap_dir, dry_run = FALSE),
    error = function(e) e
  )
  expect_s3_class(err, "sampletidy_error")
  # db_transaction()'s own wrapper message (R/mutate.R) - only present if the
  # transaction genuinely runs through db_transaction(), not a raw
  # BEGIN/tryCatch/stop(e), which used to re-throw the inner error verbatim.
  expect_match(
    conditionMessage(err), "Mutation transaction failed and was rolled back",
    fixed = TRUE
  )
})

# =============================================================================
# Phase 7b round 2, item 2: no schema_version-exists guard - mirrors 003's.
# =============================================================================

test_that("004-view-repair aborts with a classed sampletidy_error (not a raw catalog error) on a database with no schema_version table", {
  mig4 <- .mig004_load()
  dir <- withr::local_tempdir()
  path <- file.path(dir, "no-schema-version.duckdb")
  con <- DBI::dbConnect(duckdb::duckdb(), path, read_only = FALSE)
  DBI::dbExecute(con, "CREATE TABLE placeholder (x INTEGER)")
  DBI::dbDisconnect(con, shutdown = TRUE)

  snap_dir <- withr::local_tempdir()
  err <- tryCatch(
    mig4$mig004_run(db = path, snapshot_dir = snap_dir, dry_run = FALSE),
    error = function(e) e
  )
  expect_s3_class(err, "sampletidy_error")
})

# =============================================================================
# Phase 7b round 2, item 3: 004 does not assert its documented 001
# dependency - reproduced: the backup is taken and written BEFORE the
# failure, on a pre-001 DB. The precondition check must happen before Step
# 1's backup, so a stray backup is never left behind.
# =============================================================================

test_that("004-view-repair aborts with a classed sampletidy_error and writes NO backup when 001 has not yet run against this database", {
  mig4 <- .mig004_load()
  path <- seed_pre_migration_db()

  snap_dir <- withr::local_tempdir()
  err <- tryCatch(
    mig4$mig004_run(db = path, snapshot_dir = snap_dir, dry_run = FALSE),
    error = function(e) e
  )
  expect_s3_class(err, "sampletidy_error")
  expect_match(conditionMessage(err), "001", fixed = TRUE)
  # No stray backup file - the precondition check runs before Step 1.
  expect_equal(length(list.files(snap_dir)), 0L)
})

# =============================================================================
# Phase 7b round 2, item 5 (F.12(b)): no test asserted a single restored
# column on v_measurement, _old, _long or _gas_report. Phase-7a M2 (delete
# the `an.name AS analyte_name,` projection line from v_measurement)
# SURVIVED the full suite as a result.
# =============================================================================

test_that("F.12(b): v_measurement's restored column set includes analyte_name, analyte_units, feature_flow, lon, lat, rl_low, rl_high (Phase-7a M2 killer)", {
  mig1 <- .mig001_load()
  mig4 <- .mig004_load()
  path <- .run_001_then_004(mig1, mig4)

  con <- pre_migration_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  fields <- DBI::dbListFields(con, "v_measurement")
  expected <- c(
    "uuid_analysis", "uuid_sample", "uuid_feature", "feature_name", "value",
    "date", "datetime", "analyte_name", "analyte_units", "site",
    "feature_flow", "lon", "lat", "rl_low", "rl_high"
  )
  expect_setequal(fields, expected)

  # Non-vacuous: a concrete value, not merely "the column exists".
  row <- DBI::dbGetQuery(con, "SELECT * FROM v_measurement WHERE uuid_sample = 's-902'")
  expect_equal(nrow(row), 1L)
  expect_equal(row$analyte_name, "Analyte X")
  expect_equal(row$analyte_units, "mg/L")
})

# =============================================================================
# Phase 7b round 2, items 5 + 6: the four mask views (_epa/_old/_gas_report/
# _long) must all carry their restored projection AND `fm.name AS
# mask_name` (item 6 - the join to feature_mask was already present purely
# as a filter; projecting the one column that is the mask table's whole
# reason to exist).
# =============================================================================

test_that("F.12(b)/item 6: the four mask views (_epa/_old/_gas_report/_long) all carry their restored column set including fm.name AS mask_name", {
  mig1 <- .mig001_load()
  mig4 <- .mig004_load()
  path <- .run_001_then_004(mig1, mig4)

  con <- pre_migration_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  expected <- c(
    "uuid_analysis", "uuid_sample", "uuid_feature", "feature_name", "value",
    "date", "datetime", "site", "feature_flow", "lon", "lat", "mask_name"
  )
  for (v in c("v_measurement_epa", "v_measurement_old", "v_measurement_gas_report", "v_measurement_long")) {
    fields <- DBI::dbListFields(con, v)
    expect_setequal(fields, expected)
  }

  # Non-vacuous mask_name value, for the one view with a planted fixture row.
  row <- DBI::dbGetQuery(con, "SELECT mask_name FROM v_measurement_epa WHERE uuid_sample = 's-epa-201'")
  expect_equal(row$mask_name, "EPA-PM-CASE")
})

# =============================================================================
# Phase 7b round 2, item 5 (Phase-7a M1 killer): the base fixture's own
# 'old'/'gas_report'/'long' feature_mask rows (seed_pre_migration_db(),
# f-101/f-102/f-103) give each of the other 3 mask views a real,
# independently-computable non-zero row, mirroring R-15.35's own oracle
# shape for v_measurement_epa. Phase-7a M1 (v_measurement_old = "OLD" ->
# "old") makes UPPER(fm.variant) = 'old' compare against an always-uppercase
# expression, matching NOTHING - so this is also the M1 killer.
# =============================================================================

test_that("F.12(a)/M1 killer: v_measurement_old returns a nonzero row count equal to an independently computed base-table oracle for its case-insensitive filter", {
  mig1 <- .mig001_load()
  mig4 <- .mig004_load()
  path <- .run_001_then_004(mig1, mig4)

  con <- pre_migration_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  view_n <- DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM v_measurement_old")$n
  base_n <- DBI::dbGetQuery(con, "
    SELECT COUNT(*) n
    FROM analysis a
    JOIN \"sample\" s ON a.uuid_sample = s.uuid
    JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
    JOIN feature f ON fa.uuid_feature = f.uuid
    JOIN feature_mask fm ON fm.uuid_feature = f.uuid AND UPPER(fm.variant) = 'OLD'
  ")$n

  expect_true(view_n > 0)
  expect_identical(view_n, base_n)
  expect_equal(view_n, 1L)
})

# =============================================================================
# Phase 7b round 2, item 9: idempotence and dry-run, for real.
# =============================================================================

test_that("004-view-repair: running mig004_run() a second time returns already_migrated, with v_measurement_epa still returning its repaired row", {
  mig1 <- .mig001_load()
  mig4 <- .mig004_load()
  path <- .run_001_then_004(mig1, mig4)

  con <- pre_migration_con(path)
  epa_n_first <- DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM v_measurement_epa")$n
  DBI::dbDisconnect(con, shutdown = TRUE)
  expect_equal(epa_n_first, 1L)

  snap_dir <- withr::local_tempdir()
  result2 <- mig4$mig004_run(db = path, snapshot_dir = snap_dir, dry_run = FALSE)
  expect_equal(result2$status, "already_migrated")
  expect_true(is.na(result2$backup_path))

  con2 <- pre_migration_con(path)
  withr::defer(DBI::dbDisconnect(con2, shutdown = TRUE))
  epa_n_second <- DBI::dbGetQuery(con2, "SELECT COUNT(*) n FROM v_measurement_epa")$n
  expect_equal(epa_n_second, 1L)
})

test_that("004-view-repair: dry_run = TRUE writes nothing (no backup, no marker, views left unrepaired)", {
  mig1 <- .mig001_load()
  mig4 <- .mig004_load()

  path <- seed_pre_migration_db()
  con0 <- pre_migration_con(path)
  .seed_004_epa_case_fixture(con0)
  DBI::dbDisconnect(con0, shutdown = TRUE)
  mig1$mig001_run(db = path, snapshot_dir = withr::local_tempdir(), dry_run = FALSE)

  snap_dir <- withr::local_tempdir()
  result <- mig4$mig004_run(db = path, snapshot_dir = snap_dir, dry_run = TRUE)
  expect_equal(result$status, "dry_run")
  expect_equal(length(list.files(snap_dir)), 0L)

  con <- pre_migration_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  marker_n <- DBI::dbGetQuery(con, "SELECT count(*) n FROM schema_version WHERE version = 1004")$n
  expect_equal(marker_n, 0)
  # Views left unrepaired - the EPA case-mismatch defect is still present.
  epa_n <- DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM v_measurement_epa")$n
  expect_equal(epa_n, 0L)
})
