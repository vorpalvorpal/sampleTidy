# Operator-run migration: seed `ingest_file` rows (state `ignored`) for two
# historical Blaxland ACIRL gas workbooks that duplicate visits already in live
# under wrong header dates, and correct the date of project 2400-7286-12.
# Marker 1047. Requires 1046.
#
# Authority: Robin, 2026-10-19 (investigation: two workbooks' readings are
# identical point-by-point to the live visits; the live dates are right; the
# ACIRL header dates are wrong).
#
# ---- WHAT ----------------------------------------------------------------------
#   file (xxHash128 = ingest_file key; md5)          header      same visit as live
#   2400-7286-03-01 March 2023 Monthly Gas ... .xls  2023-04-15  2023-03-15
#     5755b9b9ed6a57b6bbc0fee5d822004d  (md5 f5b5015d6e9bac85750e4d18521ebf01)
#   2400-7286-12 December 2023 Monthly Gas ... .xls  2023-12-08  2023-12-18
#     7a4b94c9cde7fc65216c5246e7056f50  (md5 5f5d872f872764ab52298fd3817aeed6)
#
#   * one ingest_file row per file, state = 'ignored', in the shape of the
#     live claimed-then-ignored rows (the superseded ALS XTABs): filename,
#     path_first_seen (the OneDrive asset path), size, first_seen_at =
#     updated_at = the migration time, adapter/tier = what the current registry
#     claims it with (acirl_gas_xlsx / format), work_order/revision/org/
#     uuid_asset/registry_fingerprint NULL. The router (.st_route_one_file)
#     looks a file up by content hash ONLY; a stored non-`seen` state is read
#     back and never re-decided - `ignored` is terminal, is excluded from both
#     the reconsider set (.st_is_registry_verdict) and the fingerprint
#     re-decision set (.st_is_router_verdict), and the inbox counts it as done
#     (.inbox_find_work: no work; .inbox_done_states). So the file is skipped
#     wherever, and under whatever name, it is dropped.
#   * project 2400-7286-12: date_start AND date_end 2023-12-08 -> 2023-12-18
#     (00:00 UTC, the row's existing time-of-day convention; its 178 samples
#     are all Sydney 2023-12-18). date_end moves too: it equals date_start on
#     every one-visit gas project and would otherwise precede it.
#   * project 2400-7286-03-01 date_start is already 2023-03-15 (not the 15 Apr
#     header date): asserted, untouched.
#
# ---- PRECONDITIONS (any failure aborts; nothing is written) ---------------------
#   * marker 1046 present;
#   * no ingest_file row for either hash, nor for either filename;
#   * project 2400-7286-12 is one row with date_start = date_end = 2023-12-08
#     00:00 UTC, and every one of its samples is Sydney 2023-12-18;
#   * project 2400-7286-03-01 is one row with date_start = 2023-03-15 00:00 UTC
#     and every one of its samples is Sydney 2023-03-15.
#
# Writes, in one transaction: db_append of the two ingest_file rows
# (change_log insert rows, uuid_row NULL, source_hash = the file's hash),
# db_update of the project dates, actor "047-blaxland-gas-duplicate-workbooks-
# ignored", and the marker; every other table, row and column is checksummed
# before and after. Backups: verified whole-file snapshot, plus
# `047-...-BACKUP-{project,ingest_file}.csv` (touched rows, before; the
# ingest_file file is header-only, as the rows do not exist yet).
#
# Idempotent: marker present -> re-verify, no-op.
#
#   devtools::load_all(".")
#   env <- new.env()
#   sys.source("dev/migrations/047-blaxland-gas-duplicate-workbooks-ignored.R", envir = env)
#   env$mig047_run(db = st_config("live_db"),
#                  snapshot_dir = st_config("snapshot_dir"), dry_run = TRUE)

.mig047_marker_version <- 1047L
.mig047_requires <- 1046L
.mig047_name <- "047-blaxland-gas-duplicate-workbooks-ignored"
.mig047_actor <- .mig047_name
.mig047_assets <- paste0("/Users/rjs/Library/CloudStorage/OneDrive-BlueMountainsCityCouncil/Sharepoint/",
                         "waste_data - Environmental monitoring/assets/processed/")
.mig047_files <- data.frame(
  hash = c("5755b9b9ed6a57b6bbc0fee5d822004d", "7a4b94c9cde7fc65216c5246e7056f50"),
  md5 = c("f5b5015d6e9bac85750e4d18521ebf01", "5f5d872f872764ab52298fd3817aeed6"),
  filename = c("2400-7286-03-01 March 2023 Monthly Gas Monitoring Blaxland WMF.xls",
               "2400-7286-12 December 2023 Monthly Gas Monitoring Blaxland WMF.xls"),
  asset_dir = c("0d82022d-0103-4a07-8a88-958573967939", "abdbe50c-c851-496f-9a74-92b730d1b632"),
  size = c(2989568, 2989056),
  project = c("2400-7286-03-01", "2400-7286-12"),
  header = c("2023-04-15", "2023-12-08"),
  live = c("2023-03-15", "2023-12-18"),
  stringsAsFactors = FALSE)
.mig047_adapter <- "acirl_gas_xlsx"
.mig047_tier <- "format"
.mig047_state <- "ignored"
.mig047_state_reason <- function(i) {
  sprintf("same visit as live %s (ACIRL header date error, header %s); readings identical - migration 047",
          .mig047_files$live[[i]], .mig047_files$header[[i]])
}
.mig047_proj_fix <- "2400-7286-12"
.mig047_proj_old <- as.POSIXct("2023-12-08 00:00:00", tz = "UTC")
.mig047_proj_new <- as.POSIXct("2023-12-18 00:00:00", tz = "UTC")
.mig047_proj_keep <- "2400-7286-03-01"
.mig047_proj_keep_start <- as.POSIXct("2023-03-15 00:00:00", tz = "UTC")
.mig047_n_samples <- c(`2400-7286-03-01` = 178L, `2400-7286-12` = 178L)
.mig047_reason_file <- "047 (Robin, 2026-10-19): duplicate of a live visit under a wrong ACIRL header date; seeded ignored so the router skips it"
.mig047_reason_proj <- "047 (Robin, 2026-10-19): 2400-7286-12 samples are dated 18 Dec 2023 (Sydney); the 2023-12-08 came from the ACIRL header date error"

.mig047_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = list(...))[[1]][[1]])
.mig047_fail <- function(msg) cli::cli_abort(paste0(.mig047_name, ": ", msg), class = "sampletidy_error")
.mig047_inlist <- function(x) if (!length(x)) "('')" else paste0("(", paste0("'", x, "'", collapse = ","), ")")
.mig047_syd <- function(x) format(x, "%Y-%m-%d", tz = "Australia/Sydney")
.mig047_utc <- function(x) format(x, "%Y-%m-%d %H:%M:%S", tz = "UTC")

.mig047_counts <- function(con) {
  tabs <- c("ingest_file", "ingest_sighting", "project", "sample", "analysis", "asset", "review_queue",
            "change_log", "schema_version")
  stats::setNames(lapply(tabs, function(t) .mig047_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
}

.mig047_project <- function(con, name) {
  DBI::dbGetQuery(con, "SELECT * FROM project WHERE name = ?", params = list(name))
}
.mig047_sample_days <- function(con, name) {
  s <- DBI::dbGetQuery(con, "SELECT s.date FROM sample s JOIN project p ON p.uuid = s.uuid_project WHERE p.name = ?",
                       params = list(name))
  .mig047_syd(s$date)
}

.mig047_problems <- function(con) {
  f <- .mig047_files; probs <- character(0)
  n <- .mig047_scalar(con, sprintf("SELECT COUNT(*) FROM ingest_file WHERE hash IN %s OR filename IN %s",
                                   .mig047_inlist(f$hash), .mig047_inlist(f$filename)))
  if (n != 0L) probs <- c(probs, sprintf("%d ingest_file row(s) already exist for these hashes/filenames", n))
  pf <- .mig047_project(con, .mig047_proj_fix)
  if (nrow(pf) != 1L) {
    probs <- c(probs, sprintf("project %s is %d rows, expected 1", .mig047_proj_fix, nrow(pf)))
  } else if (!identical(.mig047_utc(pf$date_start), .mig047_utc(.mig047_proj_old)) ||
             !identical(.mig047_utc(pf$date_end), .mig047_utc(.mig047_proj_old))) {
    probs <- c(probs, sprintf("project %s dates are %s..%s, expected %s", .mig047_proj_fix,
                              .mig047_utc(pf$date_start), .mig047_utc(pf$date_end), .mig047_utc(.mig047_proj_old)))
  }
  pk <- .mig047_project(con, .mig047_proj_keep)
  if (nrow(pk) != 1L || !identical(.mig047_utc(pk$date_start), .mig047_utc(.mig047_proj_keep_start)))
    probs <- c(probs, sprintf("project %s date_start is not %s", .mig047_proj_keep, .mig047_utc(.mig047_proj_keep_start)))
  for (i in seq_len(nrow(f))) {
    d <- .mig047_sample_days(con, f$project[[i]])
    if (length(d) != .mig047_n_samples[[f$project[[i]]]] || any(d != f$live[[i]]))
      probs <- c(probs, sprintf("project %s has %d samples on Sydney day(s) %s, expected %d on %s", f$project[[i]],
                                length(d), paste(unique(d), collapse = ","), .mig047_n_samples[[f$project[[i]]]], f$live[[i]]))
  }
  probs
}

.mig047_check_preconditions <- function(con) {
  if (.mig047_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig047_requires) == 0L)
    .mig047_fail(sprintf("marker %d (046) is required first.", .mig047_requires))
  probs <- .mig047_problems(con)
  if (length(probs)) .mig047_fail(sprintf("%s. Nothing written.", paste(probs, collapse = " | ")))
  invisible(TRUE)
}

.mig047_rows <- function(at) {
  f <- .mig047_files
  data.frame(hash = f$hash, filename = f$filename,
             path_first_seen = paste0(.mig047_assets, f$asset_dir, "/", f$filename),
             size = f$size, first_seen_at = rep(at, nrow(f)), updated_at = rep(at, nrow(f)),
             state = .mig047_state, state_reason = vapply(seq_len(nrow(f)), .mig047_state_reason, character(1)),
             adapter = .mig047_adapter, tier = .mig047_tier,
             work_order = NA_character_, revision = NA_integer_, org = NA_character_,
             uuid_asset = NA_character_, registry_fingerprint = NA_character_, stringsAsFactors = FALSE)
}

.mig047_checksum <- function(con) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  tabs <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  touched <- c("ingest_file", "project", "change_log", "schema_version")
  out <- lapply(setdiff(tabs, touched), function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- setdiff(tabs, touched)
  h <- .mig047_inlist(.mig047_files$hash)
  out$ingest_file_rest <- q(sprintf("SELECT * FROM ingest_file WHERE hash NOT IN %s ORDER BY hash", h))
  out$project_rest <- q(sprintf("SELECT * FROM project WHERE name <> '%s' ORDER BY uuid", .mig047_proj_fix))
  out$project_fixed <- q(sprintf("SELECT * EXCLUDE (date_start, date_end) FROM project WHERE name = '%s'", .mig047_proj_fix))
  out$change_log_rest <- q(sprintf("SELECT * FROM change_log WHERE actor <> '%s' ORDER BY ALL", .mig047_actor))
  out$schema_version_rest <- q(sprintf("SELECT * FROM schema_version WHERE version <> %d ORDER BY ALL", .mig047_marker_version))
  out$views <- q("SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
  out$indexes <- q("SELECT index_name, sql FROM duckdb_indexes() ORDER BY index_name")
  out
}

.mig047_done_problem <- function(con) {
  f <- .mig047_files
  if (.mig047_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig047_marker_version) != 1L)
    return("marker 1047 missing")
  # The two ingest_file rows, exactly.
  r <- DBI::dbGetQuery(con, sprintf("SELECT * FROM ingest_file WHERE hash IN %s ORDER BY hash", .mig047_inlist(f$hash)))
  if (nrow(r) != 2L) return(sprintf("%d ingest_file rows for the two hashes, expected 2", nrow(r)))
  r <- r[match(f$hash, r$hash), , drop = FALSE]
  for (i in seq_len(nrow(f))) {
    if (!identical(r$state[[i]], .mig047_state) || !identical(r$state_reason[[i]], .mig047_state_reason(i)) ||
        !identical(r$adapter[[i]], .mig047_adapter) || !identical(r$tier[[i]], .mig047_tier))
      return(sprintf("ingest_file %s is %s/%s/%s/%s", f$hash[[i]], r$state[[i]], r$state_reason[[i]], r$adapter[[i]], r$tier[[i]]))
    # Honoured by the router and inbox exactly as their own code reads it:
    # terminal, never reconsidered, never re-decided on a fingerprint change, done to the inbox.
    if (!(r$state[[i]] %in% .st_ingest_terminal_states) ||
        .st_is_registry_verdict(r$state[[i]], r$state_reason[[i]]) ||
        .st_is_router_verdict(r$state[[i]], r$state_reason[[i]], r$adapter[[i]]) ||
        !(r$state[[i]] %in% .inbox_done_states))
      return(sprintf("ingest_file %s would be re-decided by the router or inbox", f$hash[[i]]))
  }
  # change_log: 2 ingest_file inserts (one per hash) + 2 project date updates.
  cl <- DBI::dbGetQuery(con, "SELECT tbl, action, field, uuid_row, old, new, source_hash FROM change_log WHERE actor = ?",
                        params = list(.mig047_actor))
  ins <- cl[cl$tbl == "ingest_file", , drop = FALSE]
  upd <- cl[cl$tbl == "project", , drop = FALSE]
  pf <- .mig047_project(con, .mig047_proj_fix)
  if (nrow(cl) != 4L || nrow(ins) != 2L || any(ins$action != "insert") || !setequal(ins$source_hash, f$hash) ||
      nrow(upd) != 2L || any(upd$action != "update") || !setequal(upd$field, c("date_start", "date_end")) ||
      any(upd$uuid_row != pf$uuid) || any(upd$old != .st_changelog_str(.mig047_proj_old)) ||
      any(upd$new != .st_changelog_str(.mig047_proj_new)))
    return(sprintf("047 change_log is %d row(s), not 2 ingest_file inserts + 2 project date updates as planned", nrow(cl)))
  if (nrow(pf) != 1L || !identical(.mig047_utc(pf$date_start), .mig047_utc(.mig047_proj_new)) ||
      !identical(.mig047_utc(pf$date_end), .mig047_utc(.mig047_proj_new)))
    return(sprintf("project %s dates are not %s", .mig047_proj_fix, .mig047_utc(.mig047_proj_new)))
  if (!identical(.mig047_syd(pf$date_start), "2023-12-18")) return("project 2400-7286-12 is not Sydney 2023-12-18")
  pk <- .mig047_project(con, .mig047_proj_keep)
  if (nrow(pk) != 1L || !identical(.mig047_utc(pk$date_start), .mig047_utc(.mig047_proj_keep_start)))
    return(sprintf("project %s date_start moved", .mig047_proj_keep))
  for (i in seq_len(nrow(f))) {
    d <- .mig047_sample_days(con, f$project[[i]])
    if (length(d) != .mig047_n_samples[[f$project[[i]]]] || any(d != f$live[[i]]))
      return(sprintf("project %s samples moved", f$project[[i]]))
  }
  NULL
}

.mig047_verify <- function(con) {
  p <- .mig047_done_problem(con)
  if (!is.null(p)) cli::cli_abort(paste0("047 verify failed: ", p), class = "sampletidy_error")
  invisible(TRUE)
}

mig047_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- if (is.null(.now)) Sys.time() else .now
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig047_name, ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig047_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig047_counts(verify_con)))
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  dest
}

.mig047_write_csv <- function(df, path, key) {
  out <- df
  for (f in names(out)) if (inherits(out[[f]], c("POSIXct", "Date"))) out[[f]] <- .st_changelog_str(out[[f]])
  utils::write.csv(out, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8", colClasses = "character")
  if (nrow(back) != nrow(df) || !identical(back[[key]], as.character(out[[key]])))
    cli::cli_abort("047: CSV {basename(path)} did not round-trip.", class = "sampletidy_error")
}

.mig047_apply <- function(con, recorded_at) {
  sums_before <- .mig047_checksum(con)
  want <- .mig047_counts(con)
  want$ingest_file <- want$ingest_file + 2L
  want$change_log <- want$change_log + 4L
  want$schema_version <- want$schema_version + 1L
  rows <- .mig047_rows(recorded_at)
  db_transaction(con, function(con) {
    for (i in seq_len(nrow(rows))) {
      db_append(con, "ingest_file", rows[i, , drop = FALSE], actor = .mig047_actor,
                reason = .mig047_reason_file, source_hash = rows$hash[[i]])
    }
    pf <- .mig047_project(con, .mig047_proj_fix)
    db_update(con, "project", uuid = pf$uuid[[1]],
              changes = list(date_start = .mig047_proj_new, date_end = .mig047_proj_new),
              actor = .mig047_actor, reason = .mig047_reason_proj)
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig047_marker_version, recorded_at))
    .mig047_verify(con)
    got <- .mig047_counts(con)
    if (!identical(got, want))
      .mig047_fail(sprintf("counts are not before + 2 ingest_file, + 4 change_log, + 1 marker: %s",
                           paste(names(got), unlist(got), unlist(want), sep = ":", collapse = ", ")))
    if (!identical(sums_before, .mig047_checksum(con))) .mig047_fail("something outside the planned rows/columns moved.")
    NULL
  })
  invisible(NULL)
}

mig047_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(
    DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                    params = list(.mig047_marker_version)),
    finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch(.mig047_verify(check_con), finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("047 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  tryCatch(.mig047_check_preconditions(pre_con), finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  for (i in seq_len(nrow(.mig047_files)))
    logf("Seed ingest_file %s (%s) ignored: %s", .mig047_files$hash[[i]], .mig047_files$filename[[i]], .mig047_state_reason(i))
  logf("Project %s date_start/date_end %s -> %s; project %s date_start already %s (untouched).",
       .mig047_proj_fix, .mig047_utc(.mig047_proj_old), .mig047_utc(.mig047_proj_new),
       .mig047_proj_keep, .mig047_utc(.mig047_proj_keep_start))
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition passed. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_, restore_command = NA_character_,
                          recorded_at = NA)))
  }

  bk_con <- st_connect(db, read_only = TRUE)
  tryCatch({
    .mig047_write_csv(DBI::dbGetQuery(bk_con, "SELECT * FROM project WHERE name = ?", params = list(.mig047_proj_fix)),
                      file.path(csv_dir, sprintf("%s-BACKUP-project.csv", .mig047_name)), "uuid")
    .mig047_write_csv(DBI::dbGetQuery(bk_con, sprintf("SELECT * FROM ingest_file WHERE hash IN %s ORDER BY hash",
                                                      .mig047_inlist(.mig047_files$hash))),
                      file.path(csv_dir, sprintf("%s-BACKUP-ingest_file.csv", .mig047_name)), "hash")
  }, finally = DBI::dbDisconnect(bk_con, shutdown = TRUE))
  logf("Row backups written to %s", csv_dir)
  backup_path <- mig047_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- if (is.null(.now)) Sys.time() else .now

  with_db_write(function(con) {
    .mig047_check_preconditions(con)   # re-read under the write lock
    .mig047_apply(con, recorded_at)
  }, db = db)

  logf("%s migrated successfully (marker %d): 2 ingest_file rows (ignored), 1 project (2 dates).",
       .mig047_name, .mig047_marker_version)
  invisible(list(status = "migrated", backup_path = backup_path,
                 restore_command = restore_command, recorded_at = recorded_at))
}
