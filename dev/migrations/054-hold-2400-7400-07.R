# Operator-run migration: seed THREE `ingest_file` rows (state `ignored`) that keep
# three files out of the import permanently (Robin's D11 ruling), and append the
# ruling to project ES2006927's comments. Marker 1054. Requires 1053.
#
# ---- WHY -----------------------------------------------------------------------
# D11, RULED by Robin 2026-10-21: keep live as it is (all six ES2006927 samples on
# 27 Feb 2020) and ignore the ESdat revision-1 files for good. The revision-1
# files of ALS ES2006927 (Chemistry2e.CSV, Header.XML, Sample2e.CSV;
# Date_Reported 2020-03-10) put K.S01A/S03/S05/S09/TS01 and the lined stormwater
# dam on 25 Feb 2020. Revision 0 (reported 2020-03-06) already had the rest on
# 25 Feb 18:34, so revision 1 only re-dates S3 and the dam, to match the date the
# COC recorded - which is wrong. Live holds ES2006927 on 27 Feb with the comment
# "COC incorrectly recorded date as 25-02-2020" (both revisions' COC number is
# "ALSE-Sydney 27-Feb-20"); that comment is untouched. The chemistry of revision 1
# is byte-identical to revision 0's and is already in live, so ignoring revision 1
# loses nothing; importing it would duplicate ES2006927's results onto 25 Feb.
# Revision 1 is not a repeat of ES2006494 either (the detected values differ at
# every point). NB the hash keys content: the revision-0 Chemistry2e.CSV is
# byte-identical to the revision-1 one, so it is ignored too (the revision-0
# Header.XML and Sample2e.CSV differ and are not; without the chemistry file
# they import no results).
# The ruling is also appended (never replacing) to project ES2006927's comments.
# D1 (2400-7400-07 July 2024 Monthly Katoomba WMF.xls, d1597914...) was held here
# until Robin ruled (2026-10-20): the file is right (1 Jul 2024) and live is
# wrong; migration 056 moves live's ES2421689 ALS results to 1 Jul 2024, so the
# workbook is no longer held.
#
# ---- REVERSIBLE ----------------------------------------------------------------
# Should the ruling ever change, reset the rows with
# ingest_file_set_state(..., reset = TRUE) (as migration 040 did) and re-ingest;
# the project comment's old value is in change_log and the BACKUP CSV.
#
# ---- WHAT ----------------------------------------------------------------------
#   file                                                    xxHash128 (ingest_file key)
#   Katoomba Incident.ESDAT_ES2006927_1.Chemistry2e.CSV     07bcecfc6312255ae6f21cc6c977daaa
#     size 200204, md5 8682f959da29a700f97b8761c88ed5ab
#   Katoomba Incident.ESDAT_ES2006927_1.Header.XML          e11b438cfd496070dc2fef28effdbbe3
#     size 786, md5 7850eed5c30adb385ac063095d5175e9
#   Katoomba Incident.ESDAT_ES2006927_1.Sample2e.CSV        b66193946f485819e4b0e1451f1e70ac
#     size 16381, md5 7882107fe8bec58f1f8a179965a2bd0c
#   (ESdat rows: adapter esdat / tier exact, per the B1 rehearsal DB.)
#   * project ES2006927 (2b34a4fb-1cca-4ba5-b7b4-98205bcc70e6): comments <-
#     the existing text + "; " + the ruling note (.mig054_project_note), or the
#     note alone if the comments are blank; one change_log update row.
#   * state = 'ignored', in the shape of 047's rows: filename, path_first_seen
#     (the OneDrive path where the file sits, assets/unprocessed/), size,
#     first_seen_at = updated_at = the migration time, adapter/tier = what the
#     current registry claims it with (esdat / exact; B1 rehearsal),
#     work_order/revision/org/uuid_asset/registry_fingerprint NULL. The router
#     looks a file up by content hash ONLY; `ignored` is terminal, outside the
#     reconsider and fingerprint re-decision sets, and an inbox done state.
#
# ---- PRECONDITIONS (any failure aborts; nothing is written) ---------------------
#   * marker 1053 present;
#   * no ingest_file row for any of the three hashes or filenames;
#   * project ES2006927 exists (that uuid and name) and its comments do not yet
#     carry the note;
#   * its six samples are on 27 Feb 2020 and each carries the comment
#     "COC incorrectly recorded date as 25-02-2020" (the ruling keeps them so).
#
# Writes, in one transaction: db_append of the three ingest_file rows (change_log
# inserts, uuid_row NULL, source_hash = the file's hash), db_update of the project
# comments (one change_log update, old/new), actor "054-hold-2400-7400-07", and the
# marker; every other table, row and column is checksummed before and after.
# Backups: verified whole-file snapshot, plus
# `054-hold-2400-7400-07-BACKUP-ingest_file.csv` (header-only: the rows do not
# exist yet) and `054-hold-2400-7400-07-BACKUP-project.csv` (the project row, before).
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
  hash = c("07bcecfc6312255ae6f21cc6c977daaa",
           "e11b438cfd496070dc2fef28effdbbe3", "b66193946f485819e4b0e1451f1e70ac"),
  md5 = c("8682f959da29a700f97b8761c88ed5ab",
          "7850eed5c30adb385ac063095d5175e9", "7882107fe8bec58f1f8a179965a2bd0c"),
  filename = c("Katoomba Incident.ESDAT_ES2006927_1.Chemistry2e.CSV",
               "Katoomba Incident.ESDAT_ES2006927_1.Header.XML",
               "Katoomba Incident.ESDAT_ES2006927_1.Sample2e.CSV"),
  size = c(200204, 786, 16381),
  adapter = c("esdat", "esdat", "esdat"),
  tier = c("exact", "exact", "exact"),
  decision = c("D11", "D11", "D11"),
  stringsAsFactors = FALSE)
.mig054_state <- "ignored"
.mig054_state_reason <- function(i) {
  paste0("ignored permanently (D11, Robin 2026-10-21: keep live's 27 Feb 2020): ES2006927 revision 1 (reported 2020-03-10) only re-dates S3 and the dam to 25 Feb to match the COC date, which is wrong (live comment: COC incorrectly recorded date as 25-02-2020; COC number ALSE-Sydney 27-Feb-20); its chemistry is byte-identical to revision 0's and already in live; importing would duplicate ES2006927 onto 25 Feb - migration 054")
}
.mig054_reason_file <- function(i) sprintf("054 (%s): kept out of the import by Robin's 2026-10-21 ruling; seeded ignored so the router skips it",
                                           .mig054_files$decision[[i]])
.mig054_project <- "2b34a4fb-1cca-4ba5-b7b4-98205bcc70e6"
.mig054_project_name <- "ES2006927"
.mig054_project_note <- paste0(
  "2026-10-21 054 (D11): Robin ruled to keep these samples on 27 Feb 2020 as they are and to ignore ",
  "the ESdat revision-1 files (reported 2020-03-10) permanently. Revision 1 only re-dates S3 and the ",
  "dam to 25 Feb to match the COC date, which is wrong (see the samples' comment); its chemistry is ",
  "byte-identical to revision 0's and already held here.")
.mig054_append_note <- function(existing) {
  if (is.na(existing) || !nzchar(trimws(existing))) .mig054_project_note
  else paste0(existing, "; ", .mig054_project_note)
}
.mig054_sample_comment <- "COC incorrectly recorded date as 25-02-2020"
.mig054_reason_project <- "054 (D11): Robin's 2026-10-21 ruling appended to the project comments (keep 27 Feb; ignore revision 1)"
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
  pr <- DBI::dbGetQuery(con, "SELECT name, comments FROM project WHERE uuid = ?", params = list(.mig054_project))
  if (nrow(pr) != 1L || !identical(pr$name[[1]], .mig054_project_name))
    return(sprintf("project %s (%s) not found", .mig054_project_name, .mig054_project))
  if (!is.na(pr$comments[[1]]) && grepl(.mig054_project_note, pr$comments[[1]], fixed = TRUE))
    return("project ES2006927 already carries the 054 note")
  probs <- .mig054_sample_problem(con)
  if (!is.null(probs)) return(probs)
  character(0)
}

# The six live samples the ruling keeps: on 27 Feb 2020 (Sydney), each with the
# COC comment (preserved; 054 never writes sample).
.mig054_sample_problem <- function(con) {
  s <- DBI::dbGetQuery(con, "SELECT uuid, datetime, comments FROM sample WHERE uuid_project = ?",
                       params = list(.mig054_project))
  day <- format(s$datetime, "%Y-%m-%d", tz = "Australia/Sydney")
  if (nrow(s) != 6L || any(day != "2020-02-27") || any(is.na(s$comments)) ||
      any(s$comments != .mig054_sample_comment))
    return(sprintf("ES2006927's samples are not the six on 27 Feb 2020 with the COC comment (%d rows)", nrow(s)))
  NULL
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
  touched <- c("ingest_file", "project", "change_log", "schema_version")
  out <- lapply(setdiff(tabs, touched), function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- setdiff(tabs, touched)
  out$project_rest <- q(sprintf("SELECT * FROM project WHERE uuid <> '%s' ORDER BY ALL", .mig054_project))
  out$project_cols <- q(sprintf("SELECT * EXCLUDE (comments) FROM project WHERE uuid = '%s'", .mig054_project))
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
  cl <- DBI::dbGetQuery(con, "SELECT tbl, action, uuid_row, field, old, new, source_hash FROM change_log WHERE actor = ?",
                        params = list(.mig054_actor))
  ins <- cl[cl$tbl == "ingest_file", , drop = FALSE]
  upd <- cl[cl$tbl == "project", , drop = FALSE]
  if (nrow(cl) != nrow(f) + 1L || nrow(ins) != nrow(f) || any(ins$action != "insert") || !setequal(ins$source_hash, f$hash))
    return(sprintf("054 change_log is %d row(s), not %d ingest_file inserts + 1 project update as planned", nrow(cl), nrow(f)))
  if (nrow(upd) != 1L || upd$action != "update" || upd$uuid_row != .mig054_project || upd$field != "comments")
    return("054 change_log lacks the one project comments update")
  # The project comments are exactly the old text with the note appended.
  pr <- DBI::dbGetQuery(con, "SELECT comments FROM project WHERE uuid = ?", params = list(.mig054_project))
  if (nrow(pr) != 1L || !identical(pr$comments[[1]], .mig054_append_note(upd$old[[1]])) ||
      !identical(upd$new[[1]], pr$comments[[1]]))
    return("project ES2006927 comments are not the old text plus the 054 note")
  p <- .mig054_sample_problem(con)
  if (!is.null(p)) return(p)
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
  want$change_log <- want$change_log + nrow(.mig054_files) + 1L
  want$schema_version <- want$schema_version + 1L
  rows <- .mig054_rows(recorded_at)
  db_transaction(con, function(con) {
    for (i in seq_len(nrow(rows)))
      db_append(con, "ingest_file", rows[i, , drop = FALSE], actor = .mig054_actor,
                reason = .mig054_reason_file(i), source_hash = rows$hash[[i]])
    old <- DBI::dbGetQuery(con, "SELECT comments FROM project WHERE uuid = ?", params = list(.mig054_project))$comments[[1]]
    db_update(con, "project", uuid = .mig054_project, changes = list(comments = .mig054_append_note(old)),
              actor = .mig054_actor, reason = .mig054_reason_project)
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig054_marker_version, recorded_at))
    .mig054_verify(con)
    got <- .mig054_counts(con)
    if (!identical(got, want))
      .mig054_fail(sprintf("counts are not before + %d ingest_file, + %d change_log, + 1 marker: %s",
                           nrow(.mig054_files), nrow(.mig054_files) + 1L,
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
  logf("Append to project %s comments: %s", .mig054_project_name, .mig054_project_note)
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition passed. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_, restore_command = NA_character_,
                          recorded_at = NA)))
  }

  bk_con <- st_connect(db, read_only = TRUE)
  tryCatch({
    .mig054_write_csv(DBI::dbGetQuery(bk_con, sprintf("SELECT * FROM ingest_file WHERE hash IN %s ORDER BY hash", .mig054_inlist(.mig054_files$hash))),
                      file.path(csv_dir, sprintf("%s-BACKUP-ingest_file.csv", .mig054_name)), "hash")
    .mig054_write_csv(DBI::dbGetQuery(bk_con, "SELECT * FROM project WHERE uuid = ?", params = list(.mig054_project)),
                      file.path(csv_dir, sprintf("%s-BACKUP-project.csv", .mig054_name)), "uuid")
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

  logf("%s migrated successfully (marker %d): %d ingest_file rows (ignored), project %s comment appended.",
       .mig054_name, .mig054_marker_version, nrow(.mig054_files), .mig054_project_name)
  invisible(list(status = "migrated", backup_path = backup_path,
                 restore_command = restore_command, recorded_at = recorded_at))
}
