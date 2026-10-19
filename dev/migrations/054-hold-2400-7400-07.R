# Operator-run migration: seed ONE `ingest_file` row (state `ignored`) that holds
# the ACIRL Katoomba field workbook "2400-7400-07 July 2024 Monthly Katoomba
# WMF.xls" out of the import until Robin rules (D1). Marker 1054. Requires 1053.
#
# ---- WHY -----------------------------------------------------------------------
# The workbook, its sheets and ALS ES2421689 all say 1 Jul 2024, but live
# already holds ES2421689's ALS values on 19 Jun 2024 samples. Importing the
# workbook would split one visit across two days. Held pending Robin (D1).
#
# ---- REVERSIBLE ----------------------------------------------------------------
# Once Robin rules, reset the row with ingest_file_set_state(..., reset = TRUE)
# (as migration 040 did) and re-ingest the file; or delete nothing by hand.
#
# ---- WHAT ----------------------------------------------------------------------
#   file                                                    xxHash128 (ingest_file key)
#   2400-7400-07 July 2024 Monthly Katoomba WMF.xls         d1597914e52ce9077f376b8ded30791c
#     size 205824, md5 ccfafa7626d57cf853aa7061838f6c7a
#   * state = 'ignored', in the shape of 047's rows: filename, path_first_seen
#     (the OneDrive path where the file sits, assets/unprocessed/), size,
#     first_seen_at = updated_at = the migration time, adapter/tier = what the
#     current registry claims it with (acirl_field_xlsx / format; B1 rehearsal),
#     work_order/revision/org/uuid_asset/registry_fingerprint NULL. The router
#     looks a file up by content hash ONLY; `ignored` is terminal, outside the
#     reconsider and fingerprint re-decision sets, and an inbox done state.
#
# ---- PRECONDITIONS (any failure aborts; nothing is written) ---------------------
#   * marker 1053 present;
#   * no ingest_file row for the hash or the filename.
#
# Writes, in one transaction: db_append of the ingest_file row (change_log
# insert, uuid_row NULL, source_hash = the hash), actor "054-hold-2400-7400-07",
# and the marker; every other table, row and column is checksummed before and
# after. Backups: verified whole-file snapshot, plus
# `054-hold-2400-7400-07-BACKUP-ingest_file.csv` (header-only: the row does not
# exist yet).
#
# Idempotent: marker present -> re-verify, no-op.
#
#   devtools::load_all(".")
#   env <- new.env()
#   sys.source("dev/migrations/054-hold-2400-7400-07.R", envir = env)
#   env$mig054_run(db = st_config("live_db"),
#                  snapshot_dir = st_config("snapshot_dir"), dry_run = TRUE)

.mig054_marker_version <- 1054L
.mig054_requires <- 1053L
.mig054_name <- "054-hold-2400-7400-07"
.mig054_actor <- .mig054_name
.mig054_hash <- "d1597914e52ce9077f376b8ded30791c"
.mig054_md5 <- "ccfafa7626d57cf853aa7061838f6c7a"
.mig054_filename <- "2400-7400-07 July 2024 Monthly Katoomba WMF.xls"
.mig054_path <- paste0("/Users/rjs/Library/CloudStorage/OneDrive-BlueMountainsCityCouncil/Sharepoint/",
                       "waste_data - Environmental monitoring/assets/unprocessed/", .mig054_filename)
.mig054_size <- 205824
.mig054_adapter <- "acirl_field_xlsx"
.mig054_tier <- "format"
.mig054_state <- "ignored"
.mig054_state_reason <- paste0("held pending Robin (D1): file, sheets and ALS ES2421689 say 1 Jul 2024 but live files ",
                               "ES2421689's ALS values on 19 Jun 2024 samples; importing would split one visit across two days - migration 054")
.mig054_reason_file <- "054 (D1): held out of the import pending Robin's ruling; seeded ignored so the router skips it"

.mig054_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = list(...))[[1]][[1]])
.mig054_fail <- function(msg) cli::cli_abort(paste0(.mig054_name, ": ", msg), class = "sampletidy_error")

.mig054_counts <- function(con) {
  tabs <- c("ingest_file", "ingest_sighting", "project", "sample", "analysis", "asset", "review_queue",
            "change_log", "schema_version")
  stats::setNames(lapply(tabs, function(t) .mig054_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
}

.mig054_problems <- function(con) {
  n <- .mig054_scalar(con, "SELECT COUNT(*) FROM ingest_file WHERE hash = ? OR filename = ?",
                      .mig054_hash, .mig054_filename)
  if (n != 0L) return(sprintf("%d ingest_file row(s) already exist for this hash/filename", n))
  character(0)
}

.mig054_check_preconditions <- function(con) {
  if (.mig054_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig054_requires) == 0L)
    .mig054_fail(sprintf("marker %d (053) is required first.", .mig054_requires))
  probs <- .mig054_problems(con)
  if (length(probs)) .mig054_fail(sprintf("%s. Nothing written.", paste(probs, collapse = " | ")))
  invisible(TRUE)
}

.mig054_row <- function(at) {
  data.frame(hash = .mig054_hash, filename = .mig054_filename, path_first_seen = .mig054_path,
             size = .mig054_size, first_seen_at = at, updated_at = at,
             state = .mig054_state, state_reason = .mig054_state_reason,
             adapter = .mig054_adapter, tier = .mig054_tier,
             work_order = NA_character_, revision = NA_integer_, org = NA_character_,
             uuid_asset = NA_character_, registry_fingerprint = NA_character_, stringsAsFactors = FALSE)
}

.mig054_checksum <- function(con) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  tabs <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  touched <- c("ingest_file", "change_log", "schema_version")
  out <- lapply(setdiff(tabs, touched), function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- setdiff(tabs, touched)
  out$ingest_file_rest <- q(sprintf("SELECT * FROM ingest_file WHERE hash <> '%s' ORDER BY hash", .mig054_hash))
  out$change_log_rest <- q(sprintf("SELECT * FROM change_log WHERE actor <> '%s' ORDER BY ALL", .mig054_actor))
  out$schema_version_rest <- q(sprintf("SELECT * FROM schema_version WHERE version <> %d ORDER BY ALL", .mig054_marker_version))
  out$views <- q("SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
  out$indexes <- q("SELECT index_name, sql FROM duckdb_indexes() ORDER BY index_name")
  out
}

.mig054_done_problem <- function(con) {
  if (.mig054_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig054_marker_version) != 1L)
    return("marker 1054 missing")
  r <- DBI::dbGetQuery(con, "SELECT * FROM ingest_file WHERE hash = ?", params = list(.mig054_hash))
  if (nrow(r) != 1L) return(sprintf("%d ingest_file rows for the hash, expected 1", nrow(r)))
  if (!identical(r$state[[1]], .mig054_state) || !identical(r$state_reason[[1]], .mig054_state_reason) ||
      !identical(r$adapter[[1]], .mig054_adapter) || !identical(r$tier[[1]], .mig054_tier))
    return(sprintf("ingest_file %s is %s/%s/%s/%s", .mig054_hash, r$state[[1]], r$state_reason[[1]], r$adapter[[1]], r$tier[[1]]))
  # Honoured by the router and inbox exactly as their own code reads it:
  # terminal, never reconsidered, never re-decided on a fingerprint change, done to the inbox.
  if (!(r$state[[1]] %in% .st_ingest_terminal_states) ||
      .st_is_registry_verdict(r$state[[1]], r$state_reason[[1]]) ||
      .st_is_router_verdict(r$state[[1]], r$state_reason[[1]], r$adapter[[1]]) ||
      !(r$state[[1]] %in% .inbox_done_states))
    return(sprintf("ingest_file %s would be re-decided by the router or inbox", .mig054_hash))
  cl <- DBI::dbGetQuery(con, "SELECT tbl, action, uuid_row, source_hash FROM change_log WHERE actor = ?",
                        params = list(.mig054_actor))
  if (nrow(cl) != 1L || cl$tbl != "ingest_file" || cl$action != "insert" || !identical(cl$source_hash, .mig054_hash))
    return(sprintf("054 change_log is %d row(s), not 1 ingest_file insert as planned", nrow(cl)))
  NULL
}

.mig054_verify <- function(con) {
  p <- .mig054_done_problem(con)
  if (!is.null(p)) cli::cli_abort(paste0("054 verify failed: ", p), class = "sampletidy_error")
  invisible(TRUE)
}

mig054_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- if (is.null(.now)) Sys.time() else .now
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig054_name, ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig054_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig054_counts(verify_con)))
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  dest
}

.mig054_write_csv <- function(df, path, key) {
  out <- df
  for (f in names(out)) if (inherits(out[[f]], c("POSIXct", "Date"))) out[[f]] <- .st_changelog_str(out[[f]])
  utils::write.csv(out, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8", colClasses = "character")
  if (nrow(back) != nrow(df) || !identical(back[[key]], as.character(out[[key]])))
    cli::cli_abort("054: CSV {basename(path)} did not round-trip.", class = "sampletidy_error")
}

.mig054_apply <- function(con, recorded_at) {
  sums_before <- .mig054_checksum(con)
  want <- .mig054_counts(con)
  want$ingest_file <- want$ingest_file + 1L
  want$change_log <- want$change_log + 1L
  want$schema_version <- want$schema_version + 1L
  row <- .mig054_row(recorded_at)
  db_transaction(con, function(con) {
    db_append(con, "ingest_file", row, actor = .mig054_actor, reason = .mig054_reason_file, source_hash = .mig054_hash)
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig054_marker_version, recorded_at))
    .mig054_verify(con)
    got <- .mig054_counts(con)
    if (!identical(got, want))
      .mig054_fail(sprintf("counts are not before + 1 ingest_file, + 1 change_log, + 1 marker: %s",
                           paste(names(got), unlist(got), unlist(want), sep = ":", collapse = ", ")))
    if (!identical(sums_before, .mig054_checksum(con))) .mig054_fail("something outside the planned row moved.")
    NULL
  })
  invisible(NULL)
}

mig054_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(
    DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                    params = list(.mig054_marker_version)),
    finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch(.mig054_verify(check_con), finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("054 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  tryCatch(.mig054_check_preconditions(pre_con), finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  logf("Seed ingest_file %s (%s) ignored: %s", .mig054_hash, .mig054_filename, .mig054_state_reason)
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition passed. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_, restore_command = NA_character_,
                          recorded_at = NA)))
  }

  bk_con <- st_connect(db, read_only = TRUE)
  tryCatch({
    .mig054_write_csv(DBI::dbGetQuery(bk_con, "SELECT * FROM ingest_file WHERE hash = ?", params = list(.mig054_hash)),
                      file.path(csv_dir, sprintf("%s-BACKUP-ingest_file.csv", .mig054_name)), "hash")
  }, finally = DBI::dbDisconnect(bk_con, shutdown = TRUE))
  logf("Row backups written to %s", csv_dir)
  backup_path <- mig054_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- if (is.null(.now)) Sys.time() else .now

  with_db_write(function(con) {
    .mig054_check_preconditions(con)   # re-read under the write lock
    .mig054_apply(con, recorded_at)
  }, db = db)

  logf("%s migrated successfully (marker %d): 1 ingest_file row (ignored).", .mig054_name, .mig054_marker_version)
  invisible(list(status = "migrated", backup_path = backup_path,
                 restore_command = restore_command, recorded_at = recorded_at))
}
