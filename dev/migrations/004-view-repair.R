# PLAN-15 (B-15.F12, R-15.35) - operator-run migration: repair the two
# defects 001-alias-indirection.R's view rebuild left behind in the
# reporting views.
#
#  (a) `fm.variant = 'epa'` (lowercase) vs the `'EPA'` (uppercase) that
#      `feature_mask.variant` actually stores - `v_measurement_epa` silently
#      returns ZERO rows. The other three mask-filtered views (`_old`,
#      `_gas_report`, `_long`) are checked for the same case mismatch and
#      made case-insensitive too (via `UPPER(fm.variant) = '<VARIANT>'`), a
#      strict superset of an exact-lowercase match, so this cannot regress a
#      variant that was already stored consistently in lowercase.
#  (b) the 4/5-column projection gutting on `v_measurement` /
#      `v_measurement_epa` / `_old` / `_long` / `_gas_report` - 001's rebuild
#      preserved join topology but dropped almost every column.
#
# ORCHESTRATOR RULING 2026-07-24 (DECOUPLED from F.11, recorded in the plan):
# the restored `date` projection is derived from `datetime` - the Sydney
# calendar date - and NEVER selects the raw `sample.date` column (F.11,
# blocked on F.13, is free to drop `sample.date` later without this
# migration standing in the way). The timezone conversion happens entirely
# in SQL, inside the view definition itself:
#   CAST(s.datetime AT TIME ZONE 'UTC' AT TIME ZONE 'Australia/Sydney' AS DATE)
# `s.datetime` is stored UTC-naive (confirmed by dev/epa-monitoring-report.R
# assumption B, which uses this exact idiom against the live DB). The first
# `AT TIME ZONE 'UTC'` reinterprets the naive timestamp as an instant in UTC
# (a TIMESTAMPTZ); the second `AT TIME ZONE 'Australia/Sydney'` projects that
# instant onto the Sydney local wall-clock; `CAST(... AS DATE)` then takes
# the Sydney calendar day. None of this touches the R session's `Sys.time()`
# / `Sys.timezone()` in any way - it is pure SQL evaluated by DuckDB, so the
# result is identical regardless of the R process's `TZ` env var. Requires
# the `icu` extension for the named-zone `AT TIME ZONE`; INSTALL/LOAD it
# explicitly (idempotent, matching dev/epa-monitoring-report.R's own
# comment: autoload does not reliably fire on every connection mode).
#
# 001 is pinned and already applied - this migration does not edit it. It
# DROPs and recreates the 5 mask/measurement views itself (never
# `v_feature_dates` - PLAN-15's own audit found exactly ONE date-referencing
# view, and it is not one of these five; F.11, not F.12, owns it).
#
# NEVER invoked by package code (A50) - an operator runs it directly, e.g.:
#   env <- new.env()
#   sys.source("dev/migrations/004-view-repair.R", envir = env)
#   env$mig004_run(db = "/path/to/monitoring.duckdb",
#                   snapshot_dir = "/path/to/snapshots", dry_run = TRUE)
#
# Depends on 001-alias-indirection.R having already run against `db` (004
# repairs 001's OWN rebuilt views; there is nothing to repair pre-001).
#
# Pure view DDL, like 001's own step 6/10 view rebuild - no base-table row is
# read, written or logged, so there is no `change_log` entry to write (the
# same reasoning 001 applies to its view section). The verify gate instead
# proves the one thing that matters for a view-only migration: every
# base-table row count and a value checksum over stable columns is BYTE
# IDENTICAL before and after (mirrors `mig001_counts_checksum()` /
# `mig001_verify()`, reused in shape, not by reference, since each migration
# file is `sys.source()`d standalone).

.mig004_marker_version <- 1004L

# The 5 views this migration drops + recreates - deliberately NOT
# `v_feature_dates` (the one date-referencing view F.11, not F.12, owns).
.mig004_five_views <- c(
  "v_measurement", "v_measurement_epa",
  "v_measurement_gas_report", "v_measurement_long", "v_measurement_old"
)

# variant -> the uppercase literal its case-insensitive filter compares
# against. Applied to every mask-filtered view, not just `_epa` - brief
# B-15.F12(a)'s own instruction ("Check the other masked variants ... for
# the same case mismatch").
.mig004_variant_literal <- c(
  v_measurement_epa = "EPA",
  v_measurement_old = "OLD",
  v_measurement_gas_report = "GAS_REPORT",
  v_measurement_long = "LONG"
)

.mig004_default <- function(x, default) if (is.null(x)) default else x

# The Sydney-calendar-date SQL expression (see file header) - factored into
# one constant so every view derives `date` identically and no view can
# accidentally regress to a raw `sample.date` selection or a timezone-naive
# cast.
.mig004_sydney_date_expr <- "CAST(s.datetime AT TIME ZONE 'UTC' AT TIME ZONE 'Australia/Sydney' AS DATE)"

#' Ensure the `icu` extension (named-zone `AT TIME ZONE`) is available on
#' this connection
#'
#' Idempotent - `INSTALL`/`LOAD` are both safe to repeat. Explicit rather
#' than relying on autoload, matching dev/epa-monitoring-report.R's own
#' documented reason (assumption B): autoload does not reliably fire on
#' every connection mode, and a view that silently fails to bind at CREATE
#' time (or at query time, for a future read-only consumer) is exactly the
#' failure mode this migration exists to close, not reopen.
#'
#' @param con an open DBI connection.
#' @return invisible(NULL).
.mig004_ensure_icu <- function(con) {
  DBI::dbExecute(con, "INSTALL icu")
  DBI::dbExecute(con, "LOAD icu")
  invisible(NULL)
}

# ---- mig004_counts_checksum() -----------------------------------------------

#' Row counts + a value checksum over the base tables this migration never
#' writes to (mirrors `mig001_counts_checksum()`'s shape)
#'
#' This migration only drops and recreates views - every base table
#' (`feature`, `feature_alias`, `feature_mask`, `\"sample\"`, `analysis`,
#' `lab_method`) must come out byte-identical to how it went in. Selects
#' only columns stable across THIS migration (everything - nothing here adds
#' or drops a base-table column).
#'
#' @param con an open DBI connection.
#' @return named list(feature, feature_alias, feature_mask, sample, analysis,
#'   lab_method, checksum).
mig004_counts_checksum <- function(con) {
  feature_n <- DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM feature")$n
  alias_n <- DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM feature_alias")$n
  mask_n <- DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM feature_mask")$n
  sample_n <- DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM \"sample\"")$n
  analysis_n <- DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM analysis")$n
  lab_method_n <- DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM lab_method")$n

  feature_vals <- DBI::dbGetQuery(con, "SELECT uuid, name, site, flow FROM feature ORDER BY uuid")
  alias_vals <- DBI::dbGetQuery(
    con, "SELECT uuid, uuid_feature, alias_key FROM feature_alias ORDER BY uuid"
  )
  mask_vals <- DBI::dbGetQuery(
    con, "SELECT uuid_feature, variant, name FROM feature_mask ORDER BY uuid_feature, variant, name"
  )
  sample_vals <- DBI::dbGetQuery(
    con, "SELECT uuid, uuid_feature_alias, \"date\", datetime FROM \"sample\" ORDER BY uuid"
  )
  analysis_vals <- DBI::dbGetQuery(
    con, "SELECT uuid, uuid_sample, uuid_lab, value FROM analysis ORDER BY uuid"
  )
  lab_method_vals <- DBI::dbGetQuery(
    con, "SELECT uuid, uuid_analyte, name FROM lab_method ORDER BY uuid"
  )

  checksum <- digest::digest(
    list(feature_vals, alias_vals, mask_vals, sample_vals, analysis_vals, lab_method_vals),
    algo = "sha1"
  )

  list(
    feature = as.integer(feature_n),
    feature_alias = as.integer(alias_n),
    feature_mask = as.integer(mask_n),
    sample = as.integer(sample_n),
    analysis = as.integer(analysis_n),
    lab_method = as.integer(lab_method_n),
    checksum = checksum
  )
}

# ---- mig004_verify() ---------------------------------------------------------

#' Step hard verify gate - every base table byte-identical before/after
#'
#' @param before,after `mig004_counts_checksum()`-shaped lists.
#' @return invisible(TRUE) if every field matches; throws otherwise.
mig004_verify <- function(before, after) {
  fields <- c(
    "feature", "feature_alias", "feature_mask", "sample", "analysis",
    "lab_method", "checksum"
  )
  bad <- Filter(function(f) !identical(before[[f]], after[[f]]), fields)
  if (length(bad) > 0) {
    cli::cli_abort(
      "004-view-repair verify failed: mismatch in {paste(bad, collapse = ', ')}.",
      class = "sampletidy_error"
    )
  }
  invisible(TRUE)
}

# ---- mig004_backup() ---------------------------------------------------------

.mig004_backup_counts <- function(con) {
  list(
    feature = DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM feature")$n,
    sample = DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM \"sample\"")$n,
    analysis = DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM analysis")$n,
    lab_method = DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM lab_method")$n
  )
}

#' Back up and VERIFY the live DB before any write (mirrors
#' `mig001_backup()` / `mig002_backup()`)
#'
#' Timestamped (millisecond precision). `CHECKPOINT` flushes to disk before
#' the copy is taken. Verifies the copy by opening it read-only and
#' comparing row counts to the live DB. Throws, writing nothing to `db`, on
#' any failure.
#'
#' @param db path to the live DuckDB file.
#' @param snapshot_dir directory to write the backup into.
#' @param .now inject a POSIXct instead of `Sys.time()`.
#' @return absolute path to the verified backup copy.
mig004_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- .mig004_default(.now, Sys.time())
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  fname <- sprintf("monitoring_pre-004-view-repair_%sZ.duckdb", ts)
  dest <- file.path(snapshot_dir, fname)

  live_counts <- with_db_write(
    function(con) {
      DBI::dbExecute(con, "CHECKPOINT")
      counts <- .mig004_backup_counts(con)
      ok <- tryCatch(
        suppressWarnings(file.copy(db, dest, overwrite = FALSE)),
        error = function(e) FALSE
      )
      if (!isTRUE(ok)) {
        cli::cli_abort(
          "{db}: failed to write backup copy to {dest}.",
          class = "sampletidy_error"
        )
      }
      counts
    },
    db = db
  )

  verify_con <- tryCatch(
    DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE),
    error = function(e) NULL
  )
  if (is.null(verify_con)) {
    cli::cli_abort(
      "{db}: backup verification failed - cannot open {dest} read-only.",
      class = "sampletidy_error"
    )
  }
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)

  backup_counts <- .mig004_backup_counts(verify_con)
  if (!identical(live_counts, backup_counts)) {
    cli::cli_abort(
      "{db}: backup verification failed - row counts differ between live DB and {dest}.",
      class = "sampletidy_error"
    )
  }

  dest
}

# ---- view DDL -----------------------------------------------------------

#' Drop the 5 affected views and recreate them with restored projections and
#' case-insensitive mask filters
#'
#' `v_measurement` keeps 001's join topology (INNER JOIN through
#' `lab_method`/`analyte`) and restores the columns 001's rebuild dropped:
#' `date` (Sydney calendar date, derived from `datetime` - never raw
#' `sample.date`), `datetime`, `analyte_name`, `analyte_units`, `site`,
#' `feature_flow`, `lon`, `lat` and the RL columns (`rl_low`, `rl_high`).
#'
#' The 4 mask-filtered views (`_epa`/`_old`/`_gas_report`/`_long`) keep
#' 001's join topology UNCHANGED (no `lab_method`/`analyte` join - adding
#' one would risk changing the row count, and R-15.35 pins `v_measurement_epa`
#' equal to a base-table count computed over exactly that narrower join set).
#' Their case-sensitive `fm.variant = '<lower>'` filter becomes
#' `UPPER(fm.variant) = '<UPPER>'` (fixes the `EPA`/`epa` defect and
#' future-proofs the other three), and `date`/`datetime`/`site`/
#' `feature_flow`/`lon`/`lat`/`feature_name` are restored - all sourced from
#' tables already in the join (`\"sample\"` s, `feature` f), so restoring them
#' cannot change the row count either.
#'
#' @param con an open read-write DBI connection, inside the caller's
#'   transaction.
#' @return invisible(NULL).
.mig004_rebuild_views <- function(con) {
  for (v in .mig004_five_views) {
    # IF EXISTS: 004 is a VIEW-REPAIR migration, so "a view is missing" is
    # precisely its own use case, not an error condition.
    DBI::dbExecute(con, sprintf("DROP VIEW IF EXISTS %s", v))
  }

  DBI::dbExecute(con, sprintf("
    CREATE VIEW v_measurement AS
      SELECT a.uuid AS uuid_analysis, s.uuid AS uuid_sample, f.uuid AS uuid_feature,
             f.name AS feature_name, a.value,
             %s AS date,
             s.datetime AS datetime,
             an.name AS analyte_name,
             an.units AS analyte_units,
             f.site AS site,
             f.flow AS feature_flow,
             f.lon AS lon,
             f.lat AS lat,
             a.rl_low AS rl_low,
             a.rl_high AS rl_high
      FROM analysis a
      JOIN \"sample\" s ON a.uuid_sample = s.uuid
      JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
      JOIN feature f ON fa.uuid_feature = f.uuid
      JOIN lab_method lm ON a.uuid_lab = lm.uuid
      JOIN analyte an ON lm.uuid_analyte = an.uuid
  ", .mig004_sydney_date_expr))

  for (view_name in names(.mig004_variant_literal)) {
    literal <- .mig004_variant_literal[[view_name]]
    DBI::dbExecute(con, sprintf("
      CREATE VIEW %s AS
        SELECT a.uuid AS uuid_analysis, s.uuid AS uuid_sample, f.uuid AS uuid_feature,
               f.name AS feature_name, a.value,
               %s AS date,
               s.datetime AS datetime,
               f.site AS site,
               f.flow AS feature_flow,
               f.lon AS lon,
               f.lat AS lat
        FROM analysis a
        JOIN \"sample\" s ON a.uuid_sample = s.uuid
        JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
        JOIN feature f ON fa.uuid_feature = f.uuid
        JOIN feature_mask fm ON fm.uuid_feature = f.uuid AND UPPER(fm.variant) = '%s'
    ", view_name, .mig004_sydney_date_expr, literal))
  }

  invisible(NULL)
}

# ---- mig004_run() -------------------------------------------------------

#' Run (or dry-run) the 004-view-repair migration (B-15.F12 / R-15.35)
#'
#' Never invoked by package code (A50). Depends on 001-alias-indirection.R
#' having already applied to `db`.
#'
#' @param db path to the live DuckDB file.
#' @param snapshot_dir directory for the pre-migration backup.
#' @param dry_run if `TRUE`, print what would happen and write nothing.
#' @param .now inject a POSIXct instead of `Sys.time()` (propagated to the
#'   backup filename and the schema_version marker).
#' @return invisible list(status, backup_path, restore_command,
#'   counts_before, counts_after, recorded_at).
mig004_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))

  # ---- Step 0: idempotency guard - read-only, writes nothing. ----
  marker_con <- st_connect(db, read_only = TRUE)
  marker <- tryCatch(
    DBI::dbGetQuery(
      marker_con, "SELECT applied_at FROM schema_version WHERE version = ?",
      params = list(.mig004_marker_version)
    ),
    finally = DBI::dbDisconnect(marker_con, shutdown = TRUE)
  )

  if (nrow(marker) > 0) {
    recorded_at <- marker$applied_at[[1]]
    logf("004-view-repair already applied at %s; nothing to do.", format(recorded_at))
    read_con <- st_connect(db, read_only = TRUE)
    counts <- tryCatch(
      mig004_counts_checksum(read_con),
      finally = DBI::dbDisconnect(read_con, shutdown = TRUE)
    )
    return(invisible(list(
      status = "already_migrated",
      backup_path = NA_character_,
      restore_command = NA_character_,
      counts_before = counts,
      counts_after = counts,
      recorded_at = recorded_at
    )))
  }

  # ---- dry-run: preview only, write nothing (no backup either). ----
  if (isTRUE(dry_run)) {
    preview_con <- st_connect(db, read_only = TRUE)
    counts_before <- tryCatch(
      mig004_counts_checksum(preview_con),
      finally = DBI::dbDisconnect(preview_con, shutdown = TRUE)
    )
    logf("DRY RUN: would drop + recreate %d views: %s.",
      length(.mig004_five_views), paste(.mig004_five_views, collapse = ", "))
    logf("DRY RUN: no backup taken, no writes made to %s.", db)
    return(invisible(list(
      status = "dry_run",
      backup_path = NA_character_,
      restore_command = NA_character_,
      counts_before = counts_before,
      counts_after = NA,
      recorded_at = NA
    )))
  }

  # ---- Step 1: back up and verify, before any write. ----
  backup_path <- mig004_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)

  recorded_at <- .mig004_default(.now, Sys.time())

  result <- with_db_write(
    function(con) {
      .mig004_ensure_icu(con)
      counts_before <- mig004_counts_checksum(con)

      DBI::dbExecute(con, "BEGIN TRANSACTION")

      body <- tryCatch(
        {
          .mig004_rebuild_views(con)

          DBI::dbExecute(
            con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
            params = list(.mig004_marker_version, recorded_at)
          )

          # ---- hard verify gate, before COMMIT (read-your-own-writes). ----
          counts_after <- mig004_counts_checksum(con)
          mig004_verify(counts_before, counts_after)

          list(counts_after = counts_after)
        },
        error = function(e) {
          try(DBI::dbExecute(con, "ROLLBACK"), silent = TRUE)
          stop(e)
        }
      )

      DBI::dbExecute(con, "COMMIT")
      logf("Verify passed: base tables unchanged; views rebuilt.")

      list(counts_before = counts_before, counts_after = body$counts_after)
    },
    db = db
  )

  logf("004-view-repair migrated successfully.")

  invisible(list(
    status = "migrated",
    backup_path = backup_path,
    restore_command = restore_command,
    counts_before = result$counts_before,
    counts_after = result$counts_after,
    recorded_at = recorded_at
  ))
}
