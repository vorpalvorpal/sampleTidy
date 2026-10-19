# Operator-run migration: seed FOUR `ingest_file` rows (state `ignored`) that hold
# four files out of the import until Robin rules. Marker 1054. Requires 1053.
#
# ---- WHY -----------------------------------------------------------------------
# D1: the ACIRL Katoomba field workbook "2400-7400-07 July 2024 Monthly Katoomba
# WMF.xls", its sheets and ALS ES2421689 all say 1 Jul 2024, but live already
# holds ES2421689's ALS values on 19 Jun 2024 samples. Importing the workbook
# would split one visit across two days.
# D11: the ESdat revision-1 files of ALS ES2006927 (Chemistry2e.CSV, Header.XML,
# Sample2e.CSV) report K.S01A/S05/S09/TS01 sampled 25 Feb 2020 18:34 with values
# equal to live ES2006494's 25 Feb samples, while live holds ES2006927 on 27 Feb
# with other values; importing would duplicate ES2006494. NB the hash keys
# content: the revision-0 Chemistry2e.CSV is byte-identical to the revision-1
# one, so it is held too (the revision-0 Header.XML and Sample2e.CSV differ and
# are not held).
#
# ---- REVERSIBLE ----------------------------------------------------------------
# Once Robin rules, reset the row with ingest_file_set_state(..., reset = TRUE)
# (as migration 040 did) and re-ingest the file; or delete nothing by hand.
#
# ---- WHAT ----------------------------------------------------------------------
#   file                                                    xxHash128 (ingest_file key)
#   2400-7400-07 July 2024 Monthly Katoomba WMF.xls         d1597914e52ce9077f376b8ded30791c
#     size 205824, md5 ccfafa7626d57cf853aa7061838f6c7a
#   Katoomba Incident.ESDAT_ES2006927_1.Chemistry2e.CSV     07bcecfc6312255ae6f21cc6c977daaa
#     size 200204, md5 8682f959da29a700f97b8761c88ed5ab
#   Katoomba Incident.ESDAT_ES2006927_1.Header.XML          e11b438cfd496070dc2fef28effdbbe3
#     size 786, md5 7850eed5c30adb385ac063095d5175e9
#   Katoomba Incident.ESDAT_ES2006927_1.Sample2e.CSV        b66193946f485819e4b0e1451f1e70ac
#     size 16381, md5 7882107fe8bec58f1f8a179965a2bd0c
#   (ESdat rows: adapter esdat / tier exact, per the B1 rehearsal DB.)
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
#   * no ingest_file row for any of the four hashes or filenames.
#
# Writes, in one transaction: db_append of the four ingest_file rows (change_log
# inserts, uuid_row NULL, source_hash = the file's hash), actor "054-hold-2400-7400-07",
# and the marker; every other table, row and column is checksummed before and
# after. Backups: verified whole-file snapshot, plus
# `054-hold-2400-7400-07-BACKUP-ingest_file.csv` (header-only: the rows do not
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
.mig054_assets <- paste0("/Users/rjs/Library/CloudStorage/OneDrive-BlueMountainsCityCouncil/Sharepoint/",
                         "waste_data - Environmental monitoring/assets/unprocessed/")
.mig054_files <- data.frame(
  hash = c("d1597914e52ce9077f376b8ded30791c", "07bcecfc6312255ae6f21cc6c977daaa",
           "e11b438cfd496070dc2fef28effdbbe3", "b66193946f485819e4b0e1451f1e70ac"),
  md5 = c("ccfafa7626d57cf853aa7061838f6c7a", "8682f959da29a700f97b8761c88ed5ab",
          "7850eed5c30adb385ac063095d5175e9", "7882107fe8bec58f1f8a179965a2bd0c"),
  filename = c("2400-7400-07 July 2024 Monthly Katoomba WMF.xls",
               "Katoomba Incident.ESDAT_ES2006927_1.Chemistry2e.CSV",
               "Katoomba Incident.ESDAT_ES2006927_1.Header.XML",
               "Katoomba Incident.ESDAT_ES2006927_1.Sample2e.CSV"),
  size = c(205824, 200204, 786, 16381),
  adapter = c("acirl_field_xlsx", "esdat", "esdat", "esdat"),
  tier = c("format", "exact", "exact", "exact"),
  decision = c("D1", "D11", "D11", "D11"),
  stringsAsFactors = FALSE)
.mig054_state <- "ignored"
.mig054_state_reason <- function(i) {
  if (.mig054_files$decision[[i]] == "D1")
    paste0("held pending Robin (D1): file, sheets and ALS ES2421689 say 1 Jul 2024 but live files ES2421689's ALS values on 19 Jun 2024 samples; importing would split one visit across two days - migration 054")
  else
    paste0("held pending Robin (D11): ES2006927 revision 1 reports K.S01A/S05/S09/TS01 sampled 25 Feb 2020 18:34 with values equal to live ES2006494's 25 Feb samples, while live holds ES2006927 on 27 Feb with other values; importing would duplicate ES2006494 - migration 054")
}
.mig054_reason_file <- function(i) sprintf("054 (%s): held out of the import pending Robin's ruling; seeded ignored so the router skips it",
                                           .mig054_files$decision[[i]])
.mig054_inlist <- function(x) paste0("(", paste0("'", x, "'", collapse = ","), ")")

.mig054_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = list(...))[[1]][[1]])
.mig054_fail <- function(msg) cli::cli_abort(paste0(.mig054_name, ": ", msg), class = "sampletidy_error")

.mig054_counts <- function(con) {
  tabs <- c("ingest_file", "ingest_sighting", "project", "sample", "analysis", "asset", "review_queue",
            "change_log", "schema_version")
  stats::setNames(lapply(tabs, function(t) .mig054_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
}

.mig054_problems <- function(con) {
  f <- .mig054_files
  n <- .mig054_scalar(con, sprintf("SELECT COUNT(*) FROM ingest_file WHERE hash IN %s OR filename IN %s",
                                   .mig054_inlist(f$hash), .mig054_inlist(f$filename)))
  if (n != 0L) return(sprintf("%d ingest_file row(s) already exist for these hashes/filenames", n))
  character(0)
}

.mig054_check_preconditions <- function(con) {
  if (.mig054_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig054_requires) == 0L)
    .mig054_fail(sprintf("marker %d (053) is required first.", .mig054_requires))
  probs <- .mig054_problems(con)
  if (length(probs)) .mig054_fail(sprintf("%s. Nothing written.", paste(probs, collapse = " | ")))
  invisible(TRUE)
}

.mig054_rows <- function(at) {
  f <- .mig054_files
  data.frame(hash = f$hash, filename = f$filename, path_first_seen = paste0(.mig054_assets, f$filename),
             size = f$size, first_seen_at = rep(at, nrow(f)), updated_at = rep(at, nrow(f)),
             state = .mig054_state, state_reason = vapply(seq_len(nrow(f)), .mig054_state_reason, character(1)),
             adapter = f$adapter, tier = f$tier,
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
  out$ingest_file_rest <- q(sprintf("SELECT * FROM ingest_file WHERE hash NOT IN %s ORDER BY hash", .mig054_inlist(.mig054_files$hash)))
  out$change_log_rest <- q(sprintf("SELECT * FROM change_log WHERE actor <> '%s' ORDER BY ALL", .mig054_actor))
  out$schema_version_rest <- q(sprintf("SELECT * FROM schema_version WHERE version <> %d ORDER BY ALL", .mig054_marker_version))
  out$views <- q("SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
  out$indexes <- q("SELECT index_name, sql FROM duckdb_indexes() ORDER BY index_name")
  out
}

.mig054_done_problem <- function(con) {
  if (.mig054_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig054_marker_version) != 1L)
    return("marker 1054 missing")
  f <- .mig054_files
  r <- DBI::dbGetQuery(con, sprintf("SELECT * FROM ingest_file WHERE hash IN %s", .mig054_inlist(f$hash)))
  if (nrow(r) != nrow(f)) return(sprintf("%d ingest_file rows for the hashes, expected %d", nrow(r), nrow(f)))
  r <- r[match(f$hash, r$hash), , drop = FALSE]
  for (i in seq_len(nrow(f))) {
    if (!identical(r$state[[i]], .mig054_state) || !identical(r$state_reason[[i]], .mig054_state_reason(i)) ||
        !identical(r$adapter[[i]], f$adapter[[i]]) || !identical(r$tier[[i]], f$tier[[i]]))
      return(sprintf("ingest_file %s is %s/%s/%s/%s", f$hash[[i]], r$state[[i]], r$state_reason[[i]], r$adapter[[i]], r$tier[[i]]))
    # Honoured by the router and inbox exactly as their own code reads it:
    # terminal, never reconsidered, never re-decided on a fingerprint change, done to the inbox.
    if (!(r$state[[i]] %in% .st_ingest_terminal_states) ||
        .st_is_registry_verdict(r$state[[i]], r$state_reason[[i]]) ||
        .st_is_router_verdict(r$state[[i]], r$state_reason[[i]], r$adapter[[i]]) ||
        !(r$state[[i]] %in% .inbox_done_states))
      return(sprintf("ingest_file %s would be re-decided by the router or inbox", f$hash[[i]]))
  }
  cl <- DBI::dbGetQuery(con, "SELECT tbl, action, uuid_row, source_hash FROM change_log WHERE actor = ?",
                        params = list(.mig054_actor))
  if (nrow(cl) != nrow(f) || any(cl$tbl != "ingest_file") || any(cl$action != "insert") || !setequal(cl$source_hash, f$hash))
    return(sprintf("054 change_log is %d row(s), not %d ingest_file inserts as planned", nrow(cl), nrow(f)))
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
  want$ingest_file <- want$ingest_file + nrow(.mig054_files)
  want$change_log <- want$change_log + nrow(.mig054_files)
  want$schema_version <- want$schema_version + 1L
  rows <- .mig054_rows(recorded_at)
  db_transaction(con, function(con) {
    for (i in seq_len(nrow(rows)))
      db_append(con, "ingest_file", rows[i, , drop = FALSE], actor = .mig054_actor,
                reason = .mig054_reason_file(i), source_hash = rows$hash[[i]])
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig054_marker_version, recorded_at))
    .mig054_verify(con)
    got <- .mig054_counts(con)
    if (!identical(got, want))
      .mig054_fail(sprintf("counts are not before + 4 ingest_file, + 4 change_log, + 1 marker: %s",
                           paste(names(got), unlist(got), unlist(want), sep = ":", collapse = ", ")))
    if (!identical(sums_before, .mig054_checksum(con))) .mig054_fail("something outside the planned rows moved.")
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
  for (i in seq_len(nrow(.mig054_files)))
    logf("Seed ingest_file %s (%s) ignored: %s", .mig054_files$hash[[i]], .mig054_files$filename[[i]], .mig054_state_reason(i))
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition passed. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_, restore_command = NA_character_,
                          recorded_at = NA)))
  }

  bk_con <- st_connect(db, read_only = TRUE)
  tryCatch({
    .mig054_write_csv(DBI::dbGetQuery(bk_con, sprintf("SELECT * FROM ingest_file WHERE hash IN %s ORDER BY hash", .mig054_inlist(.mig054_files$hash))),
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

  logf("%s migrated successfully (marker %d): 4 ingest_file rows (ignored).", .mig054_name, .mig054_marker_version)
  invisible(list(status = "migrated", backup_path = backup_path,
                 restore_command = restore_command, recorded_at = recorded_at))
}
