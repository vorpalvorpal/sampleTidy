# Operator-run migration: correct ONE ACIRL transcription typo. Blaxland B.MW02,
# field electrical conductivity on the sampling visit of 2026-01-05 (Sydney
# day), project ES2600194, is stored as 130 uS/cm; it is 1300. Marker 1036.
# Requires 1035.
#
# Authority: Robin's ruling 2026-10-18, option (b): "change 130 to 1300".
# Evidence: ALS's own lab EC (EA010P) on the same sample/visit is 1300, and
# every other B.MW02 EC reading (field and lab) is 1,280 - 2,000 uS/cm. The
# ACIRL Jan-2026 Blaxland workbook (report 2400-7538-01 family) dropped a zero.
#
# THE ROW. analysis 26ed7d34-89f9-4929-a593-2ee51b9b0c7e: sample
# 8b9dc7df-4379-47ef-ae85-53ea37726c18 (feature B.MW02, project ES2600194,
# date 2026-01-05 Sydney, datetime NULL), lab_method eaf02028-... (ACIRL
# "Electrical Conductivity", method field, analyte EC, uS/cm). Columns before:
# value 130, value_chr NULL, quantified TRUE, rl_low NULL, rl_high NULL,
# purpose NULL, comments NULL. The lab EC on the same visit (analysis
# fbf73705-57e7-422a-a10f-d0fc498f29a2, value 1300, ES2600194001) is NOT
# touched.
#
# WHAT CHANGES. Only analysis.value: 130 -> 1300. The other value
# representations (value_chr, rl_low, rl_high, quantified) are NULL / NULL /
# NULL / TRUE on this row and remain so: there is no text or detection-limit
# prefix to keep consistent. (Checked, and asserted in the preconditions.)
#
# HOW. A plain db_update of `value` (as 029 did for its 37 field values): the
# column is not an FK and not indexed, so there is no stale-index problem and
# no delete + re-insert is needed. One change_log row (field value, old 130,
# new 1300). Preconditions refuse unless exactly one analysis matches
# (B.MW02, Sydney day 2026-01-05, field method, analyte EC, value 130) and it
# is the planned uuid. ONE transaction: update, marker, verify, checksum of
# everything else (analysis minus the row; every other table whole).
#
# BACKUP OF THE ROW (written on apply, beside this file):
# `036-blaxland-mw02-ec-typo-BACKUP-analysis.csv`, plus the verified
# whole-file backup in `snapshot_dir`.
#
# Idempotent: marker present -> re-verify, no-op.
#
#   devtools::load_all(".")
#   env <- new.env()
#   sys.source("dev/migrations/036-blaxland-mw02-ec-typo.R", envir = env)
#   env$mig036_run(db = st_config("live_db"),
#                  snapshot_dir = st_config("snapshot_dir"), dry_run = TRUE)

.mig036_marker_version <- 1036L
.mig036_requires <- 1035L
.mig036_name <- "036-blaxland-mw02-ec-typo"
.mig036_actor <- .mig036_name

.mig036_uuid <- "26ed7d34-89f9-4929-a593-2ee51b9b0c7e"
.mig036_lab_uuid <- "fbf73705-57e7-422a-a10f-d0fc498f29a2"   # ALS EC, same visit: must stay 1300
.mig036_feature <- "B.MW02"
.mig036_day <- "2026-01-05"
.mig036_old <- 130
.mig036_new <- 1300
.mig036_reason <- paste0(
  "036 (Robin, 2026-10-18, option b): B.MW02 field EC 2026-01-05 stored 130 is an ACIRL transcription typo for 1300 ",
  "(ALS lab EC for the same visit is 1300; all other B.MW02 EC 1280-2000 uS/cm); value 130 -> 1300")

.mig036_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = list(...))[[1]][[1]])
.mig036_fail <- function(msg) cli::cli_abort(paste0(.mig036_name, ": ", msg), class = "sampletidy_error")
.mig036_num_eq <- function(a, b) !is.na(a) && !is.na(b) && abs(a - b) < 1e-9

# EC analyses at B.MW02 on the Sydney day, with method, organisation and value.
.mig036_candidates <- function(con) {
  DBI::dbGetQuery(con, sprintf(
    "SELECT a.uuid, a.uuid_sample, a.uuid_lab, a.value, a.value_chr, a.quantified, a.rl_low, a.rl_high,
            a.purpose, a.comments, lm.method, lm.organisation
     FROM analysis a
     JOIN \"sample\" s ON s.uuid = a.uuid_sample
     JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
     JOIN feature f ON f.uuid = fa.uuid_feature
     JOIN lab_method lm ON lm.uuid = a.uuid_lab
     JOIN analyte an ON an.uuid = lm.uuid_analyte
     WHERE f.name = ? AND an.name = 'EC' AND %s = ?
     ORDER BY a.uuid", .ct_sydney_day_sql("s.date")),
    params = list(.mig036_feature, .mig036_day))
}

.mig036_row <- function(con) {
  DBI::dbGetQuery(con, "SELECT * FROM analysis WHERE uuid = ?", params = list(.mig036_uuid))
}

.mig036_counts <- function(con) {
  tabs <- c("analysis", "sample", "feature", "feature_alias", "analyte", "lab_method", "project",
            "review_queue", "change_log", "schema_version")
  stats::setNames(lapply(tabs, function(t) .mig036_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
}

# Everything 036 must not touch.
.mig036_checksum <- function(con) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  tabs <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  touched <- c("analysis", "change_log", "schema_version")
  out <- lapply(setdiff(tabs, touched), function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- setdiff(tabs, touched)
  out$analysis_rest <- q(sprintf("SELECT * FROM analysis WHERE uuid <> '%s' ORDER BY uuid", .mig036_uuid))
  out$analysis_fixed <- q(sprintf("SELECT * EXCLUDE (value) FROM analysis WHERE uuid = '%s'", .mig036_uuid))
  out$change_log_rest <- q(sprintf("SELECT * FROM change_log WHERE actor <> '%s' ORDER BY ALL", .mig036_actor))
  out$schema_version_rest <- q(sprintf("SELECT * FROM schema_version WHERE version <> %d ORDER BY ALL", .mig036_marker_version))
  out$views <- q("SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
  out$indexes <- q("SELECT index_name, sql FROM duckdb_indexes() ORDER BY index_name")
  out
}

# NULL when the row is exactly the planned one (value = `value`), else the problem.
.mig036_row_problem <- function(con, value) {
  cand <- .mig036_candidates(con)
  field <- cand[cand$method == "field" & cand$organisation == "ACIRL", , drop = FALSE]
  hit <- field[!is.na(field$value) & abs(field$value - value) < 1e-9, , drop = FALSE]
  if (nrow(hit) != 1L)
    return(sprintf("%d field EC analyses at %s on %s have value %s (expected exactly 1)",
                   nrow(hit), .mig036_feature, .mig036_day, format(value)))
  if (!identical(hit$uuid, .mig036_uuid)) return(sprintf("the matching analysis is %s, not the planned %s", hit$uuid, .mig036_uuid))
  if (!is.na(hit$value_chr) || !isTRUE(hit$quantified) || !is.na(hit$rl_low) || !is.na(hit$rl_high) ||
      !is.na(hit$purpose) || !is.na(hit$comments))
    return("the field EC row carries a value_chr / rl / purpose / comments / not-quantified that this migration did not plan for")
  lab <- cand[cand$uuid == .mig036_lab_uuid, , drop = FALSE]
  if (nrow(lab) != 1L || !.mig036_num_eq(lab$value, 1300) || lab$method == "field")
    return("the ALS lab EC for the same visit is not the expected single 1300 row")
  if (.mig036_scalar(con, "SELECT COUNT(*) FROM analysis WHERE uuid_sample = ? AND uuid_lab = ?", hit$uuid_sample, hit$uuid_lab) != 1L)
    return("the sample holds more than one reading of this method")
  NULL
}

.mig036_done_problem <- function(con) {
  p <- .mig036_row_problem(con, .mig036_new)
  if (!is.null(p)) return(p)
  if (.mig036_scalar(con, "SELECT COUNT(*) FROM analysis WHERE uuid <> ? AND uuid IN (SELECT uuid_row FROM change_log WHERE actor = ?)",
                     .mig036_uuid, .mig036_actor)) return("036 change_log names another analysis")
  cl <- DBI::dbGetQuery(con, "SELECT tbl, action, field, uuid_row FROM change_log WHERE actor = ?", params = list(.mig036_actor))
  if (nrow(cl) != 1L || cl$tbl != "analysis" || cl$action != "update" || cl$field != "value" || cl$uuid_row != .mig036_uuid)
    return(sprintf("036 change_log is %d row(s), expected 1 analysis/update/value row for the planned uuid", nrow(cl)))
  NULL
}

.mig036_verify <- function(con) {
  p <- .mig036_done_problem(con)
  if (!is.null(p)) cli::cli_abort(paste0("036 verify failed: ", p), class = "sampletidy_error")
  invisible(TRUE)
}

.mig036_check_preconditions <- function(con) {
  if (.mig036_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig036_requires) == 0L)
    .mig036_fail(sprintf("marker %d (035) is required first.", .mig036_requires))
  p <- .mig036_row_problem(con, .mig036_old)
  if (!is.null(p)) .mig036_fail(sprintf("%s. Nothing written.", p))
  invisible(TRUE)
}

mig036_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- if (is.null(.now)) Sys.time() else .now
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig036_name, ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig036_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig036_counts(verify_con)))
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  dest
}

.mig036_write_csv <- function(df, path) {
  utils::write.csv(df, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8", colClasses = "character")
  if (nrow(back) != nrow(df) || !identical(back$uuid, as.character(df$uuid)))
    cli::cli_abort("036: CSV {basename(path)} did not round-trip.", class = "sampletidy_error")
}

.mig036_apply <- function(con, recorded_at, logf) {
  sums_before <- .mig036_checksum(con)
  want <- .mig036_counts(con)
  want$schema_version <- want$schema_version + 1L
  want$change_log <- want$change_log + 1L
  db_transaction(con, function(con) {
    db_update(con, "analysis", uuid = .mig036_uuid, changes = list(value = .mig036_new),
              actor = .mig036_actor, reason = .mig036_reason)
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig036_marker_version, recorded_at))
    .mig036_verify(con)
    got <- .mig036_counts(con)
    if (!identical(got, want))
      cli::cli_abort(sprintf("036 verify failed: counts are %s, expected %s.",
                             paste(names(got), unlist(got), sep = "=", collapse = " "),
                             paste(names(want), unlist(want), sep = "=", collapse = " ")), class = "sampletidy_error")
    if (!identical(sums_before, .mig036_checksum(con)))
      cli::cli_abort("036 verify failed: something outside the planned row moved.", class = "sampletidy_error")
    NULL
  })
  logf("Updated analysis %s value %s -> %s, marker %d (committed).", .mig036_uuid,
       format(.mig036_old), format(.mig036_new), .mig036_marker_version)
  invisible(NULL)
}

mig036_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(
    DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                    params = list(.mig036_marker_version)),
    finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch(.mig036_verify(check_con), finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("036 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  tryCatch(.mig036_check_preconditions(pre_con), finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  logf("Plan: B.MW02 field EC %s (analysis %s) value %s -> %s.", .mig036_day, .mig036_uuid,
       format(.mig036_old), format(.mig036_new))
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition passed. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = NA)))
  }

  bk_con <- st_connect(db, read_only = TRUE)
  tryCatch(.mig036_write_csv(.mig036_row(bk_con), file.path(csv_dir, sprintf("%s-BACKUP-analysis.csv", .mig036_name))),
           finally = DBI::dbDisconnect(bk_con, shutdown = TRUE))
  logf("Row backup written to %s", csv_dir)
  backup_path <- mig036_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- if (is.null(.now)) Sys.time() else .now

  with_db_write(function(con) {
    .mig036_check_preconditions(con)   # re-read under the write lock
    .mig036_apply(con, recorded_at, logf)
  }, db = db)

  logf("%s migrated successfully (marker %d).", .mig036_name, .mig036_marker_version)
  invisible(list(status = "migrated", backup_path = backup_path,
                 restore_command = restore_command, recorded_at = recorded_at))
}
