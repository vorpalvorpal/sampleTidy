# Operator-run migration: the PLAN-20 phase 1 external filing table (asset_filing).
# Marker 1060. Requires 1052.
#
# Authority: dev/plans/PLAN-20-phase1-spec.md (P20.5, P20.M).
#
# ---- WHAT ----------------------------------------------------------------------
# Schema only. No data row is written except this migration's markers.
#   * asset_filing  one row per (asset, external system) the asset was filed into:
#                   uuid_asset, system, external_id, external_uri, container,
#                   filed_at, title, comments; PK (uuid_asset, system).
#   * schema_version 10 (ops-schema ladder, R/db-schema.R) if absent, and 1060.
#
# This is the same table ensure_schema() creates as ops-schema version 10 on any
# fresh DB, as v8 was also created on live by migration 023. There is no declared
# FOREIGN KEY on uuid_asset: a declared FK onto asset would make DuckDB refuse
# later DELETEs of asset rows; register_filing() checks the asset exists.
#
# ---- PRECONDITIONS (any failure aborts; nothing is written) ---------------------
#   * marker 1052 present;
#   * an `asset` table exists;
#   * if asset_filing already exists (ensure_schema() v10 got there first) it has
#     exactly the spec's columns, in order, and 0 rows (it is then adopted).
#
# Writes, in one transaction: CREATE TABLE IF NOT EXISTS, schema_version 10 (if
# absent) and the marker. Every other table's row count is checksummed before and
# after. Backup: a verified whole-file snapshot in `snapshot_dir`.
#
# Idempotent: marker present -> re-verify, no-op.
#
#   devtools::load_all(".")
#   env <- new.env()
#   sys.source("dev/migrations/060-asset-filing.R", envir = env)
#   env$mig060_run(db = st_config("live_db"),
#                  snapshot_dir = st_config("snapshot_dir"), dry_run = TRUE)

.mig060_marker_version <- 1060L
.mig060_ladder_version <- 10L
.mig060_requires <- 1052L
.mig060_name <- "060-asset-filing"

.mig060_ddl <- "
  CREATE TABLE IF NOT EXISTS asset_filing (
    uuid_asset   VARCHAR NOT NULL,
    system       VARCHAR NOT NULL,
    external_id  VARCHAR NOT NULL,
    external_uri VARCHAR,
    container    VARCHAR,
    filed_at     TIMESTAMP NOT NULL,
    title        VARCHAR,
    comments     VARCHAR,
    PRIMARY KEY (uuid_asset, system))"

.mig060_cols <- c("uuid_asset", "system", "external_id", "external_uri", "container",
                  "filed_at", "title", "comments")

.mig060_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = list(...))[[1]][[1]])
.mig060_fail <- function(msg) cli::cli_abort(paste0(.mig060_name, ": ", msg), class = "sampletidy_error")

.mig060_tables <- function(con) {
  DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
                         WHERE table_schema = 'main' AND table_type = 'BASE TABLE'
                         ORDER BY table_name")$table_name
}

.mig060_columns <- function(con, tbl) {
  DBI::dbGetQuery(con, "SELECT column_name FROM information_schema.columns
                         WHERE table_schema = 'main' AND table_name = ? ORDER BY ordinal_position",
                  params = list(tbl))$column_name
}

.mig060_counts <- function(con) {
  tabs <- .mig060_tables(con)
  stats::setNames(lapply(tabs, function(t) .mig060_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
}

# Every table's row count except asset_filing (which this migration owns).
.mig060_checksum <- function(con) {
  cnt <- .mig060_counts(con)
  list(counts = cnt[setdiff(names(cnt), "asset_filing")],
       views = digest::digest(DBI::dbGetQuery(con, "SELECT view_name, sql FROM duckdb_views()
                                                     WHERE NOT internal ORDER BY view_name"), algo = "sha1"))
}

.mig060_problems <- function(con) {
  probs <- character(0)
  tabs <- .mig060_tables(con)
  if (!"asset" %in% tabs) probs <- c(probs, "table asset does not exist")
  if ("asset_filing" %in% tabs) {
    got <- .mig060_columns(con, "asset_filing")
    if (!identical(got, .mig060_cols)) {
      probs <- c(probs, sprintf("asset_filing exists with columns %s", paste(got, collapse = ",")))
    } else if (.mig060_scalar(con, "SELECT COUNT(*) FROM asset_filing") != 0L) {
      probs <- c(probs, "asset_filing exists and is not empty")
    }
  }
  probs
}

.mig060_check_preconditions <- function(con) {
  if (.mig060_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig060_requires) == 0L)
    .mig060_fail(sprintf("marker %d (052) is required first.", .mig060_requires))
  probs <- .mig060_problems(con)
  if (length(probs)) .mig060_fail(sprintf("%s. Nothing written.", paste(probs, collapse = " | ")))
  invisible(TRUE)
}

.mig060_done_problem <- function(con) {
  if (.mig060_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig060_marker_version) != 1L)
    return("marker 1060 missing")
  if (.mig060_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig060_ladder_version) < 1L)
    return("ops-schema version 10 missing")
  got <- .mig060_columns(con, "asset_filing")
  if (!identical(got, .mig060_cols))
    return(sprintf("asset_filing columns are %s", paste(got, collapse = ",")))
  pk <- DBI::dbGetQuery(con, "SELECT constraint_type, constraint_column_names FROM duckdb_constraints()
                               WHERE table_name = 'asset_filing'")
  ok <- any(pk$constraint_type == "PRIMARY KEY" &
              vapply(pk$constraint_column_names, function(x) setequal(x, c("uuid_asset", "system")), logical(1)))
  if (!ok) return("asset_filing has no PK (uuid_asset, system)")
  NULL
}

.mig060_verify <- function(con) {
  p <- .mig060_done_problem(con)
  if (!is.null(p)) cli::cli_abort(paste0("060 verify failed: ", p), class = "sampletidy_error")
  invisible(TRUE)
}

mig060_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- if (is.null(.now)) Sys.time() else .now
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig060_name, ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig060_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig060_counts(verify_con)))
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  dest
}

.mig060_apply <- function(con, recorded_at) {
  before <- .mig060_checksum(con)
  need_ladder <- .mig060_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?",
                                .mig060_ladder_version) == 0L
  db_transaction(con, function(con) {
    DBI::dbExecute(con, .mig060_ddl)
    if (need_ladder) {
      DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                     params = list(.mig060_ladder_version, recorded_at))
    }
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig060_marker_version, recorded_at))
    .mig060_verify(con)
    if (.mig060_scalar(con, "SELECT COUNT(*) FROM asset_filing") != 0L) .mig060_fail("asset_filing is not empty.")
    after <- .mig060_checksum(con)
    after$counts$schema_version <- after$counts$schema_version - 1L - as.integer(need_ladder)
    if (!identical(before, after)) .mig060_fail("a pre-existing table or view moved.")
    NULL
  })
  invisible(NULL)
}

mig060_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(
    DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                    params = list(.mig060_marker_version)),
    finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch(.mig060_verify(check_con), finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("060 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  tryCatch(.mig060_check_preconditions(pre_con), finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  logf("Will create asset_filing (empty) and record schema_version %d and %d; no data.",
       .mig060_ladder_version, .mig060_marker_version)
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition passed. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = NA)))
  }

  backup_path <- mig060_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- if (is.null(.now)) Sys.time() else .now

  with_db_write(function(con) {
    .mig060_check_preconditions(con)   # re-read under the write lock
    .mig060_apply(con, recorded_at)
  }, db = db)

  logf("%s migrated successfully (marker %d): 1 table, no data.",
       .mig060_name, .mig060_marker_version)
  invisible(list(status = "migrated", backup_path = backup_path,
                 restore_command = restore_command, recorded_at = recorded_at))
}
