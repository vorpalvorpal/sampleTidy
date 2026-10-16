# Operator-run migration: add `ingest_file.registry_fingerprint` (R-3.8 / A90).
#
# Authorised by Robin, 2026-10-17 (R-3.8): router verdicts on `ingest_file`
# (quarantined/unclaimed, quarantined/adapter_tie, router-written failed) store
# a hash of the registered adapters' ids and versions; a later route re-decides
# any such verdict whose stored fingerprint differs from the current one or is
# NULL.
#
# ---- WHAT ---------------------------------------------------------------------
#
# One nullable VARCHAR column, NO backfill. Every existing row is therefore NULL,
# which the router reads as "stale": the live registry verdicts are re-decided
# once on the next route and take the current fingerprint. Archived, ignored and
# parse-/commit-failed rows are never touched by a fingerprint.
#
# The same column is also ops-schema version 8 in `ensure_schema()`, so a
# package connection that runs `ensure_schema()` first would add it by itself.
# This migration exists so the change is a deliberate, backed-up, recorded
# operator step rather than a side effect of the next ingest. The DDL is
# `ADD COLUMN IF NOT EXISTS` either way, so the two orders agree.
#
# No row is written except this migration's `schema_version` marker. Every
# pre-existing `ingest_file` column is checksummed before and after, and the
# row counts of every ops table must not move.
#
# Marker 1023. Requires nothing. Idempotent: marker present -> re-verify, no-op.
#
#   devtools::load_all(".")
#   env <- new.env()
#   sys.source("dev/migrations/023-registry-fingerprint.R", envir = env)
#   env$mig023_run(db = st_config("live_db"),
#                  snapshot_dir = st_config("snapshot_dir"), dry_run = TRUE)

.mig023_marker_version <- 1023L
.mig023_tables <- c("ingest_file", "ingest_sighting", "review_queue", "change_log")

.mig023_default <- function(x, default) if (is.null(x)) default else x
.mig023_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = list(...))[[1]][[1]])
.mig023_fail <- function(msg) cli::cli_abort(paste0("023-registry-fingerprint: ", msg), class = "sampletidy_error")

.mig023_has_column <- function(con) {
  .mig023_scalar(con, "SELECT COUNT(*) FROM duckdb_columns()
                        WHERE table_name = 'ingest_file' AND column_name = 'registry_fingerprint'") > 0L
}

.mig023_counts <- function(con) {
  tabs <- intersect(.mig023_tables, DBI::dbListTables(con))
  out <- lapply(tabs, function(t) .mig023_scalar(con, sprintf("SELECT COUNT(*) FROM \"%s\"", t)))
  names(out) <- tabs
  out
}

# Checksum of ingest_file over the columns that existed before this migration.
.mig023_checksum <- function(con) {
  cols <- DBI::dbGetQuery(con, "SELECT column_name FROM duckdb_columns()
                                 WHERE table_name = 'ingest_file' AND column_name <> 'registry_fingerprint'
                                 ORDER BY column_index")$column_name
  q <- sprintf("SELECT %s FROM ingest_file ORDER BY hash", paste(sprintf('"%s"', cols), collapse = ", "))
  digest::digest(DBI::dbGetQuery(con, q), algo = "sha1")
}

.mig023_check_preconditions <- function(con) {
  if (!"ingest_file" %in% DBI::dbListTables(con)) .mig023_fail("ingest_file does not exist.")
}

.mig023_verify <- function(con) {
  fail <- function(msg) cli::cli_abort(paste0("023 verify failed: ", msg), class = "sampletidy_error")
  if (!.mig023_has_column(con)) fail("ingest_file.registry_fingerprint is missing.")
  ty <- DBI::dbGetQuery(con, "SELECT data_type FROM duckdb_columns()
                               WHERE table_name = 'ingest_file' AND column_name = 'registry_fingerprint'")$data_type
  if (!identical(ty, "VARCHAR")) fail(sprintf("registry_fingerprint is %s, expected VARCHAR.", ty))
  invisible(TRUE)
}

mig023_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- .mig023_default(.now, Sys.time())
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-023-registry-fingerprint_%sZ.duckdb", ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig023_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig023_counts(verify_con))) {
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  }
  dest
}

mig023_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(
    DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                    params = list(.mig023_marker_version)),
    finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch(.mig023_verify(check_con), finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("023 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  had_column <- tryCatch({
    .mig023_check_preconditions(pre_con)
    .mig023_has_column(pre_con)
  }, finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  logf("Will add ingest_file.registry_fingerprint (already present: %s); no backfill.", had_column)
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition passed. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = NA)))
  }

  backup_path <- mig023_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- .mig023_default(.now, Sys.time())

  with_db_write(function(con) {
    counts_before <- .mig023_counts(con)
    sum_before <- .mig023_checksum(con)
    db_transaction(con, function(con) {
      DBI::dbExecute(con, "ALTER TABLE ingest_file ADD COLUMN IF NOT EXISTS registry_fingerprint VARCHAR")
      DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                     params = list(.mig023_marker_version, recorded_at))
      .mig023_verify(con)
      if (!identical(counts_before, .mig023_counts(con)) || !identical(sum_before, .mig023_checksum(con))) {
        cli::cli_abort("023 verify failed: an ops table row count or an ingest_file value moved.", class = "sampletidy_error")
      }
      if (!had_column) {
        n_set <- .mig023_scalar(con, "SELECT COUNT(*) FROM ingest_file WHERE registry_fingerprint IS NOT NULL")
        if (n_set != 0L) cli::cli_abort("023 verify failed: the new column is not all NULL.", class = "sampletidy_error")
      }
      NULL
    })
    invisible(TRUE)
  }, db = db)

  logf("023-registry-fingerprint migrated successfully.")
  invisible(list(status = "migrated", backup_path = backup_path,
                 restore_command = restore_command, recorded_at = recorded_at))
}
