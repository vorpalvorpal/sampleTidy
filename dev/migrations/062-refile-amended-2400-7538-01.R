# Operator-run migration: re-file the amended ACIRL January 2026 Blaxland report
# under its own ALS job. Marker 1062. Requires 1061.
#
# ---- WHY -----------------------------------------------------------------------
# Robin, 2026-10-21 (problem 1): "2400-7538-01 Amended 01 January Monthly Blaxland
# WMF.pdf" (asset 6e236970-accb-4e5a-b46a-fc448dec80b4, hash
# e81c10d1c192219a9f1501904bca74fb, ingested 2026-10-19) was filed under ES2623357,
# the July 2026 job. It is a re-issue of the January report, whose original
# (asset 4812773b-095c-46a4-bbe6-1fd21c291389) sits under ES2600194; the amended
# report itself prints "ALS Sydney Report No. ES2600194". So it belongs there.
# Amendment 01 (re-issued 19/10/2026) changes one value: B.MW02 field EC, 130 ->
# 1300 uS/cm ("lab tech error"); its table prints 13000, but its amendment text
# and ALS's own result say 1300. Live already holds 1300 (no value changes here).
#
# ---- WHAT ----------------------------------------------------------------------
#   * asset 6e236970: uuid_project 2a398160-... (ES2623357) -> 93f99101-... (ES2600194);
#     comments <- existing; note (.mig062_note), or the note alone if blank.
#   Two change_log update rows (uuid_project, comments). No file moves: an archived
#   file lives at <archive_dir>/<asset uuid>/<filename> (A70, R/archive.R), which
#   does not depend on the project.
#
# ---- PRECONDITIONS (any failure aborts; nothing is written) ---------------------
#   * marker 1061 present;
#   * asset 6e236970 exists with that filename and hash, under ES2623357;
#   * no other asset row carries its hash;
#   * project ES2600194 (93f99101) exists, and the original report asset 4812773b
#     is under it.
#
# Writes, in one transaction, with actor "062-refile-amended-2400-7538-01" and the
# marker; every other table, row and column is checksummed before and after.
# Backups: verified whole-file snapshot, plus
# `062-refile-amended-2400-7538-01-BACKUP-asset.csv` (the row, before).
#
# Idempotent: marker present -> re-verify, no-op.
#
#   devtools::load_all(".")
#   env <- new.env()
#   sys.source("dev/migrations/062-refile-amended-2400-7538-01.R", envir = env)
#   env$mig062_run(db = st_config("live_db"),
#                  snapshot_dir = st_config("snapshot_dir"), dry_run = TRUE)

.mig062_marker_version <- 1062L
.mig062_requires <- 1061L
.mig062_name <- "062-refile-amended-2400-7538-01"
.mig062_actor <- .mig062_name
.mig062_asset <- "6e236970-accb-4e5a-b46a-fc448dec80b4"
.mig062_filename <- "2400-7538-01 Amended 01 January Monthly Blaxland WMF.pdf"
.mig062_hash <- "e81c10d1c192219a9f1501904bca74fb"
.mig062_from <- "2a398160-1ca5-48ab-b8a8-c515f3749ccf"   # ES2623357 (July 2026)
.mig062_from_name <- "ES2623357"
.mig062_to <- "93f99101-88c6-4eae-9145-5788c2ef0988"     # ES2600194 (January 2026)
.mig062_to_name <- "ES2600194"
.mig062_original <- "4812773b-095c-46a4-bbe6-1fd21c291389"
.mig062_note <- paste0(
  "2026-10-21 062: moved from project ES2623357 (the July 2026 job; filed there in error) to ES2600194, ",
  "the January 2026 job this report re-issues (original report: asset 4812773b-095c-46a4-bbe6-1fd21c291389). ",
  "Amendment 01 (re-issued 19/10/2026) changes only B.MW02 field EC, 130 -> 1300 uS/cm; its table prints ",
  "13000, but its amendment text and the ALS result say 1300, which is what is stored (Robin, 2026-10-21)")
.mig062_reason <- "062 (Robin, 2026-10-21): re-file the amended January 2026 report under ES2600194"
.mig062_append <- function(old) if (is.na(old) || !nzchar(trimws(old))) .mig062_note else paste0(old, "; ", .mig062_note)

.mig062_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = list(...))[[1]][[1]])
.mig062_fail <- function(msg) cli::cli_abort(paste0(.mig062_name, ": ", msg), class = "sampletidy_error")

.mig062_counts <- function(con) {
  tabs <- c("ingest_file", "project", "sample", "analysis", "asset", "review_queue", "change_log", "schema_version")
  stats::setNames(lapply(tabs, function(t) .mig062_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
}

.mig062_project_problem <- function(con) {
  p <- DBI::dbGetQuery(con, "SELECT uuid, name FROM project WHERE uuid IN (?, ?)", params = list(.mig062_from, .mig062_to))
  if (!identical(p$name[match(.mig062_to, p$uuid)], .mig062_to_name)) return("project ES2600194 not found")
  o <- DBI::dbGetQuery(con, "SELECT uuid_project FROM asset WHERE uuid = ?", params = list(.mig062_original))
  if (nrow(o) != 1L || !identical(o$uuid_project[[1]], .mig062_to))
    return("the original January report (asset 4812773b) is not under ES2600194")
  NULL
}

.mig062_problems <- function(con) {
  a <- DBI::dbGetQuery(con, "SELECT uuid, filename, hash, uuid_project, comments FROM asset WHERE uuid = ? OR hash = ?",
                       params = list(.mig062_asset, .mig062_hash))
  if (nrow(a) != 1L || !identical(a$uuid[[1]], .mig062_asset))
    return(sprintf("expected exactly asset %s for hash %s, found %d row(s)", .mig062_asset, .mig062_hash, nrow(a)))
  if (!identical(a$filename[[1]], .mig062_filename) || !identical(a$hash[[1]], .mig062_hash))
    return("asset 6e236970 filename/hash are not as planned")
  if (!identical(a$uuid_project[[1]], .mig062_from)) return("asset 6e236970 is not under ES2623357")
  pn <- DBI::dbGetQuery(con, "SELECT name FROM project WHERE uuid = ?", params = list(.mig062_from))$name
  if (!identical(pn, .mig062_from_name)) return("project ES2623357 not found")
  if (!is.na(a$comments[[1]]) && grepl(.mig062_note, a$comments[[1]], fixed = TRUE)) return("asset already carries the 062 note")
  .mig062_project_problem(con)
}

.mig062_check_preconditions <- function(con) {
  if (.mig062_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig062_requires) == 0L)
    .mig062_fail(sprintf("marker %d (061) is required first.", .mig062_requires))
  p <- .mig062_problems(con)
  if (!is.null(p)) .mig062_fail(sprintf("%s. Nothing written.", p))
  invisible(TRUE)
}

.mig062_checksum <- function(con) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  tabs <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  touched <- c("asset", "change_log", "schema_version")
  out <- lapply(setdiff(tabs, touched), function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- setdiff(tabs, touched)
  out$asset_rest <- q(sprintf("SELECT * FROM asset WHERE uuid <> '%s' ORDER BY ALL", .mig062_asset))
  out$asset_cols <- q(sprintf("SELECT * EXCLUDE (uuid_project, comments) FROM asset WHERE uuid = '%s'", .mig062_asset))
  out$change_log_rest <- q(sprintf("SELECT * FROM change_log WHERE actor <> '%s' ORDER BY ALL", .mig062_actor))
  out$schema_version_rest <- q(sprintf("SELECT * FROM schema_version WHERE version <> %d ORDER BY ALL", .mig062_marker_version))
  out$views <- q("SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
  out$indexes <- q("SELECT index_name, sql FROM duckdb_indexes() ORDER BY index_name")
  out
}

.mig062_done_problem <- function(con) {
  if (.mig062_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig062_marker_version) != 1L)
    return("marker 1062 missing")
  a <- DBI::dbGetQuery(con, "SELECT uuid_project, comments, hash, filename FROM asset WHERE uuid = ?", params = list(.mig062_asset))
  if (nrow(a) != 1L || !identical(a$uuid_project[[1]], .mig062_to) || !identical(a$hash[[1]], .mig062_hash))
    return("asset 6e236970 is not under ES2600194")
  cl <- DBI::dbGetQuery(con, "SELECT tbl, action, uuid_row, field, old, new FROM change_log WHERE actor = ? ORDER BY field",
                        params = list(.mig062_actor))
  if (nrow(cl) != 2L || any(cl$tbl != "asset") || any(cl$action != "update") || any(cl$uuid_row != .mig062_asset) ||
      !identical(cl$field, c("comments", "uuid_project")))
    return(sprintf("062 change_log is %d row(s), not the 2 planned asset updates", nrow(cl)))
  if (!identical(cl$old[[2]], .mig062_from) || !identical(cl$new[[2]], .mig062_to))
    return("062 change_log uuid_project old/new are not as planned")
  if (!identical(a$comments[[1]], .mig062_append(cl$old[[1]])) || !identical(cl$new[[1]], a$comments[[1]]))
    return("asset 6e236970 comments are not the old text plus the 062 note")
  .mig062_project_problem(con)
}

.mig062_verify <- function(con) {
  p <- .mig062_done_problem(con)
  if (!is.null(p)) cli::cli_abort(paste0("062 verify failed: ", p), class = "sampletidy_error")
  invisible(TRUE)
}

mig062_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- if (is.null(.now)) Sys.time() else .now
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig062_name, ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig062_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig062_counts(verify_con)))
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  dest
}

.mig062_write_csv <- function(df, path, key) {
  out <- df
  for (f in names(out)) if (inherits(out[[f]], c("POSIXct", "Date"))) out[[f]] <- .st_changelog_str(out[[f]])
  utils::write.csv(out, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8", colClasses = "character")
  if (nrow(back) != nrow(df) || !identical(back[[key]], as.character(out[[key]])))
    cli::cli_abort("062: CSV {basename(path)} did not round-trip.", class = "sampletidy_error")
}

.mig062_apply <- function(con, recorded_at) {
  sums_before <- .mig062_checksum(con)
  want <- .mig062_counts(con)
  want$change_log <- want$change_log + 2L
  want$schema_version <- want$schema_version + 1L
  db_transaction(con, function(con) {
    old <- DBI::dbGetQuery(con, "SELECT comments FROM asset WHERE uuid = ?", params = list(.mig062_asset))$comments[[1]]
    db_update(con, "asset", uuid = .mig062_asset,
              changes = list(uuid_project = .mig062_to, comments = .mig062_append(old)),
              actor = .mig062_actor, reason = .mig062_reason, source_hash = .mig062_hash)
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig062_marker_version, recorded_at))
    .mig062_verify(con)
    got <- .mig062_counts(con)
    if (!identical(got, want))
      .mig062_fail(sprintf("counts are not before + 2 change_log, + 1 marker: %s",
                           paste(names(got), unlist(got), unlist(want), sep = ":", collapse = ", ")))
    if (!identical(sums_before, .mig062_checksum(con))) .mig062_fail("something outside the planned row moved.")
    NULL
  })
  invisible(NULL)
}

mig062_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(
    DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                    params = list(.mig062_marker_version)),
    finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch(.mig062_verify(check_con), finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("062 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  tryCatch(.mig062_check_preconditions(pre_con), finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  logf("Move asset %s (%s) from %s to %s; append: %s", .mig062_asset, .mig062_filename,
       .mig062_from_name, .mig062_to_name, .mig062_note)
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition passed. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_, restore_command = NA_character_,
                          recorded_at = NA)))
  }

  bk_con <- st_connect(db, read_only = TRUE)
  tryCatch(
    .mig062_write_csv(DBI::dbGetQuery(bk_con, "SELECT * FROM asset WHERE uuid = ?", params = list(.mig062_asset)),
                      file.path(csv_dir, sprintf("%s-BACKUP-asset.csv", .mig062_name)), "uuid"),
    finally = DBI::dbDisconnect(bk_con, shutdown = TRUE))
  logf("Row backup written to %s", csv_dir)
  backup_path <- mig062_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- if (is.null(.now)) Sys.time() else .now

  with_db_write(function(con) {
    .mig062_check_preconditions(con)   # re-read under the write lock
    .mig062_apply(con, recorded_at)
  }, db = db)

  logf("%s migrated successfully (marker %d): asset %s now under %s.", .mig062_name, .mig062_marker_version,
       .mig062_asset, .mig062_to_name)
  invisible(list(status = "migrated", backup_path = backup_path,
                 restore_command = restore_command, recorded_at = recorded_at))
}
