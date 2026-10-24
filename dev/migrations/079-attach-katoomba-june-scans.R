# REHEARSED, NOT APPLIED (rehearsed 2026-10-25 on a plain-cp copy of live at marker 1078). See
# dev/MIGRATIONS.md row 1079.
# Operator-run migration: attach four Katoomba files that 077 left quarantined/unclaimed, to
# projects named explicitly by Robin. Marker 1079. Requires 1078.
#
# Authority: Robin, 2026-10-25, after the main session opened the scans.
#
# ---- WHY ------------------------------------------------------------------------------
# All four come from the delivery folder "input2026-09-28 0937 EXTERNAL  Katoomba reports",
# which holds TWO ALS work orders (ES2620363 and ES2624617). 077's folder inference is
# therefore ambiguous and left them quarantined/unclaimed. Robin read the scans and ruled:
#   "7. Quarterly 23-06.pdf"  Katoomba quarterly surface sampling field sheet dated 23/06/26.
#       ES2620363 was sampled 2026-06-23           -> project ES2620363,       type QA.
#   "8. Gas 23-06.pdf"        Katoomba gas sampling sheet dated 23/06/2026; it belongs to the
#       June 2026 Katoomba gas report             -> project 2400-7539-06-02, type QA.
#   "9. Monthly 30-07.pdf"    Katoomba monthly sampling sheet dated 30/7/26 with "ES2624617"
#       handwritten on it; ES2624617 was sampled 2026-07-30 -> project ES2624617, type QA.
#   "2400-7539-06 June 2026 Quarterly Katoomba WMF.pdf"  the ACIRL June quarterly report. No
#       project 2400-7539-06 exists; the quarterly it reports is the June quarterly ALS work
#       order                                      -> project ES2620363, type Chemical analysis
#       (the ACIRL-report type rule, .ig_retained_asset_type()).
# No project is minted: each must already exist exactly once.
#
# ---- WHAT (frozen in 079-attach-katoomba-june-scans-INPUT.csv; one group per file) -------
# For each file, the 077 mechanics: archive_file() (copies the bytes to
# <archive_dir>/<new uuid>/<filename>, writes the asset row via db_append) and the ingest_file
# row quarantined/unclaimed -> archived/retained_sibling (db_update, so change_log records
# it), both in ONE db_transaction. Then marker 1079 and, in the outer transaction: the
# migration-tier db_checks baseline + mig_db_checks_gate(), no all-tier check gains an
# offender, whole-table checksums of everything outside the planned rows, table counts.
# Guards per file (a failure skips that file): ingest_file row sha1 as frozen and still
# quarantined/unclaimed; file located (stat only) at path_first_seen or
# <assets>/processed/_emails/<folder>[ (n)]/ and its xxHash128 equals ingest_file.hash;
# project exists exactly once; no asset holds the hash.
# Backups: verified whole-file snapshot; BACKUP CSVs (-ingest_file rows before, -copies with
# the new asset uuids) and a SKIPPED CSV, written at run time (untracked).
#
# Rehearse:  env$mig079_run(db = <copy>, snapshot_dir = ..., archive_dir = <scratch>, dry_run = TRUE)

.mig079_marker_version <- 1079L
.mig079_requires <- 1078L
.mig079_name <- "079-attach-katoomba-june-scans"
.mig079_actor <- .mig079_name
.mig079_reason <- "079 (Robin 2026-10-25: Katoomba June scans attached by explicit ruling)"
.mig079_assets_default <- "/Users/rjs/Library/CloudStorage/OneDrive-BlueMountainsCityCouncil/Sharepoint/waste_data - Environmental monitoring/assets"
.mig079_folder <- "input2026-09-28 0937 EXTERNAL  Katoomba reports"
.mig079_cols <- c("gid", "hash", "filename", "folder", "project", "type", "row_sha1")
# The ruling.
.mig079_ruling <- data.frame(
  gid = c("K1", "K2", "K3", "K4"),
  filename = c("7. Quarterly 23-06.pdf", "8. Gas 23-06.pdf", "9. Monthly 30-07.pdf",
               "2400-7539-06 June 2026 Quarterly Katoomba WMF.pdf"),
  project = c("ES2620363", "2400-7539-06-02", "ES2624617", "ES2620363"),
  type = c("QA", "QA", "QA", "Chemical analysis"),
  stringsAsFactors = FALSE)

.mig079_fail <- function(msg) cli::cli_abort(paste0(.mig079_name, ": ", msg), class = "sampletidy_error")
.mig079_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = if (length(list(...))) list(...) else NULL)[[1]][[1]])
.mig079_inlist <- function(x) if (!length(x)) "('')" else paste0("(", paste0("'", gsub("'", "''", unique(x)), "'", collapse = ","), ")")
.mig079_assets <- function() Sys.getenv("SAMPLETIDY_MIG079_ASSETS_DIR", unset = .mig079_assets_default)

# ---- rows, sha1 -------------------------------------------------------------------------

.mig079_rows <- function(con, hashes) {
  DBI::dbGetQuery(con, sprintf('SELECT hash AS ".id", * FROM ingest_file WHERE hash IN %s ORDER BY hash',
                               .mig079_inlist(hashes)))
}

.mig079_df_sha <- function(df) {
  out <- character(nrow(df))
  cols <- setdiff(names(df), ".id")
  for (i in seq_len(nrow(df))) {
    v <- vapply(cols, function(f) { s <- .st_changelog_str(df[[f]][i]); if (is.na(s)) "<NA>" else s }, "")
    out[[i]] <- digest::digest(paste(cols, v, sep = "=", collapse = "\u001f"), algo = "sha1", serialize = FALSE)
  }
  stats::setNames(out, df[[".id"]])
}

.mig079_row_sha <- function(con, hashes) {
  out <- stats::setNames(rep(NA_character_, length(hashes)), hashes)
  if (!length(hashes)) return(out)
  s <- .mig079_df_sha(.mig079_rows(con, hashes))
  out[names(s)] <- s
  out[hashes]
}

# ---- locating a file (stat only) ---------------------------------------------------------

# path_first_seen if it exists, else <assets>/processed/_emails/<folder>[ (n)]/<filename>.
.mig079_locate <- function(path_first_seen, filename) {
  if (file.exists(path_first_seen)) return(path_first_seen)
  root <- file.path(.mig079_assets(), "processed", "_emails")
  for (n in 1:20) {
    p <- file.path(root, if (n == 1L) .mig079_folder else sprintf("%s (%d)", .mig079_folder, n), filename)
    if (file.exists(p)) return(p)
  }
  NA_character_
}

# ---- plan, freeze, inputs ----------------------------------------------------------------

mig079_plan_con <- function(con) {
  rl <- .mig079_ruling
  rows <- DBI::dbGetQuery(con, sprintf(
    "SELECT hash, filename, path_first_seen FROM ingest_file WHERE filename IN %s AND state = 'quarantined'
       AND state_reason = 'unclaimed' ORDER BY filename", .mig079_inlist(rl$filename)))
  rows <- rows[basename(dirname(rows$path_first_seen)) == .mig079_folder, , drop = FALSE]
  if (anyDuplicated(rows$filename) || nrow(rows) != nrow(rl))
    .mig079_fail(sprintf("expected exactly %d quarantined/unclaimed rows in the folder, found %d.", nrow(rl), nrow(rows)))
  x <- merge(rl, rows[, c("hash", "filename")], by = "filename")
  x <- x[match(rl$gid, x$gid), , drop = FALSE]
  x$folder <- .mig079_folder
  x$row_sha1 <- unname(.mig079_row_sha(con, x$hash))
  x[, .mig079_cols]
}

mig079_freeze <- function(db, input_dir = "dev/migrations") {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  p <- mig079_plan_con(con)
  if (!identical(.ig_retained_asset_type(p$filename[4]), "Chemical analysis"))
    .mig079_fail("the ACIRL-report type rule no longer yields Chemical analysis.")
  utils::write.csv(p, file.path(input_dir, sprintf("%s-INPUT.csv", .mig079_name)), row.names = FALSE, na = "",
                   fileEncoding = "UTF-8")
  invisible(p)
}

.mig079_read_inputs <- function(input_dir = "dev/migrations") {
  p <- file.path(input_dir, sprintf("%s-INPUT.csv", .mig079_name))
  if (!file.exists(p)) .mig079_fail(sprintf("input %s not found.", p))
  x <- utils::read.csv(p, colClasses = "character", na.strings = "", encoding = "UTF-8")
  if (!identical(names(x), .mig079_cols)) .mig079_fail("INPUT columns are not as planned.")
  if (anyNA(x) || anyDuplicated(x$hash) || anyDuplicated(x$gid)) .mig079_fail("INPUT misses or repeats a value.")
  if (!identical(x[, c("gid", "filename", "project", "type")], .mig079_ruling[, c("gid", "filename", "project", "type")]))
    .mig079_fail("INPUT does not match Robin's ruling.")
  if (!all(x$folder == .mig079_folder)) .mig079_fail("INPUT folder is not the ruled delivery folder.")
  x
}

# ---- preconditions -----------------------------------------------------------------------

# Named list gid -> problems. Reads the bytes of the files to be retained (hash check) only.
.mig079_problems <- function(con, x) {
  have <- DBI::dbGetQuery(con, "SELECT version FROM schema_version")$version
  miss <- setdiff(.mig079_requires, have)
  if (length(miss)) .mig079_fail(sprintf("marker(s) %s required first.", paste(miss, collapse = ", ")))
  s <- .mig079_row_sha(con, x$hash)
  pr <- list()
  add <- function(g, m) pr[[g]] <<- c(pr[[g]], m)
  for (i in seq_len(nrow(x))) {
    g <- x$gid[[i]]; h <- x$hash[[i]]
    if (is.na(s[[h]]) || s[[h]] != x$row_sha1[[i]]) { add(g, "ingest_file row missing or not as frozen"); next }
    row <- DBI::dbGetQuery(con, "SELECT filename, path_first_seen, state, state_reason FROM ingest_file WHERE hash = ?",
                           params = list(h))
    if (!identical(c(row$state, row$state_reason), c("quarantined", "unclaimed"))) { add(g, "row is not quarantined/unclaimed"); next }
    if (row$filename[[1]] != x$filename[[i]]) { add(g, "filename differs from INPUT"); next }
    p <- .mig079_locate(row$path_first_seen[[1]], x$filename[[i]])
    if (is.na(p)) { add(g, "file not found"); next }
    if (!identical(hash_file(p), h)) add(g, "file bytes no longer hash to ingest_file.hash")
    if (.mig079_scalar(con, "SELECT COUNT(*) FROM project WHERE name = ?", x$project[[i]]) != 1L)
      add(g, "project does not exist exactly once")
    if (.mig079_scalar(con, "SELECT COUNT(*) FROM asset WHERE hash = ?", h) > 0L)
      add(g, "an asset already holds this hash")
  }
  pr
}

.mig079_skipped_df <- function(pr) {
  if (!length(pr)) return(data.frame(gid = character(), problem = character(), stringsAsFactors = FALSE))
  data.frame(gid = names(pr), problem = vapply(pr, function(p) paste(unique(p), collapse = "; "), ""),
             stringsAsFactors = FALSE)
}

# ---- verify ------------------------------------------------------------------------------

.mig079_done_problem <- function(con, x, archive_dir) {
  if (.mig079_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig079_marker_version) != 1L)
    return("marker 1079 missing")
  for (i in seq_len(nrow(x))) {
    a <- DBI::dbGetQuery(con, "SELECT a.uuid, a.filename, a.type, p.name FROM asset a JOIN project p ON p.uuid = a.uuid_project
                                WHERE a.hash = ?", params = list(x$hash[[i]]))
    if (nrow(a) != 1L || a$name[[1]] != x$project[[i]] || a$type[[1]] != x$type[[i]] || a$filename[[1]] != x$filename[[i]])
      return(sprintf("%s: asset row not as planned", x$gid[[i]]))
    f <- file.path(archive_dir, a$uuid[[1]], a$filename[[1]])
    if (!file.exists(f) || !identical(hash_file(f), x$hash[[i]])) return(sprintf("%s: archived copy missing or wrong", x$gid[[i]]))
    st <- DBI::dbGetQuery(con, "SELECT state, state_reason FROM ingest_file WHERE hash = ?", params = list(x$hash[[i]]))
    if (!identical(c(st$state, st$state_reason), c("archived", "retained_sibling"))) return(sprintf("%s: state not archived", x$gid[[i]]))
  }
  L <- DBI::dbGetQuery(con, "SELECT tbl, action, field, count(*) AS n FROM change_log WHERE actor = ? GROUP BY ALL ORDER BY ALL",
                       params = list(.mig079_actor))
  if (!all(L$tbl == "ingest_file") || !all(L$action == "update") || !setequal(L$field, c("state", "state_reason", "updated_at")) ||
      !all(L$n == nrow(x))) return("079 change_log transition rows are not as planned")
  ah <- .mig079_scalar(con, sprintf("SELECT COUNT(*) FROM change_log WHERE actor = 'ingest' AND tbl = 'asset' AND action = 'insert'
                                     AND reason = 'archive source file' AND source_hash IN %s", .mig079_inlist(x$hash)))
  if (ah != nrow(x)) return(sprintf("%d asset insert change_log rows, not %d", ah, nrow(x)))
  NULL
}

.mig079_counts <- function(con) {
  tabs <- c("analysis", "sample", "feature", "lab_method", "analyte", "asset", "ingest_file", "ingest_sighting",
            "project", "review_queue", "lab_qc_report", "change_log", "schema_version")
  stats::setNames(lapply(tabs, function(t) .mig079_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
}

.mig079_checksum <- function(con, touched_hashes) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  tabs <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  touched <- c("asset", "ingest_file", "change_log", "schema_version")
  out <- lapply(setdiff(tabs, touched), function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- setdiff(tabs, touched)
  h <- .mig079_inlist(touched_hashes)
  out$asset_rest <- q(sprintf("SELECT * FROM asset WHERE hash IS NULL OR hash NOT IN %s ORDER BY ALL", h))
  out$ingest_file_rest <- q(sprintf("SELECT * FROM ingest_file WHERE hash NOT IN %s ORDER BY ALL", h))
  out$change_log_rest <- q(sprintf("SELECT * FROM change_log WHERE actor <> '%s' AND NOT (actor = 'ingest' AND tbl = 'asset'
                                    AND source_hash IN %s) ORDER BY uuid", .mig079_actor, h))
  out$schema_version_rest <- q(sprintf("SELECT * FROM schema_version WHERE version <> %d ORDER BY ALL", .mig079_marker_version))
  out$indexes <- q("SELECT index_name, sql FROM duckdb_indexes() ORDER BY index_name")
  out$views <- q("SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
  out
}

.mig079_checks_problem <- function(before, after) {
  for (i in seq_len(nrow(after))) {
    nm <- after$name[[i]]
    b <- before[before$name == nm, , drop = FALSE]
    if (after$status[[i]] == "error") {
      if (!nrow(b) || b$status[[1]] != "error") return(sprintf("check %s now errors: %s", nm, after$message[[i]]))
      next
    }
    added <- setdiff(after$keys[[i]], if (nrow(b)) b$keys[[1]] else character())
    if (length(added)) return(sprintf("check %s gains offender(s) %s", nm, paste(utils::head(added, 3), collapse = ", ")))
  }
  NULL
}

# ---- apply -------------------------------------------------------------------------------

.mig079_apply <- function(con, x, archive_dir, recorded_at, logf) {
  copies <- data.frame(gid = character(), hash = character(), uuid_asset = character(), filename = character(),
                       stringsAsFactors = FALSE)
  db_transaction(con, function(con) {
    baseline <- db_checks(con, tier = "migration")
    before_all <- db_checks(con, tier = "all")
    sums_before <- .mig079_checksum(con, x$hash)
    counts_want <- .mig079_counts(con)
    counts_want$asset <- counts_want$asset + nrow(x)
    counts_want$change_log <- counts_want$change_log + nrow(x) + 3L * nrow(x)
    counts_want$schema_version <- counts_want$schema_version + 1L
    for (i in seq_len(nrow(x))) {
      pfs <- DBI::dbGetQuery(con, "SELECT path_first_seen FROM ingest_file WHERE hash = ?", params = list(x$hash[[i]]))$path_first_seen
      p <- .mig079_locate(pfs, x$filename[[i]])
      # .ig_retain_siblings()'s inner transaction: archive_file() + the terminal transition.
      db_transaction(con, function(con) {
        u <- archive_file(con, p, x$hash[[i]], event = list(work_order = x$project[[i]]), type = x$type[[i]])
        db_update(con, "ingest_file", key = list(hash = x$hash[[i]]),
                  changes = list(state = "archived", state_reason = "retained_sibling", updated_at = recorded_at),
                  actor = .mig079_actor, reason = sprintf("%s [%s]", .mig079_reason, x$gid[[i]]))
        copies[nrow(copies) + 1L, ] <<- list(x$gid[[i]], x$hash[[i]], u, x$filename[[i]])
      })
    }
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig079_marker_version, recorded_at))
    pr <- .mig079_done_problem(con, x, archive_dir)
    if (!is.null(pr)) .mig079_fail(paste0("verify failed: ", pr))
    if (!identical(.mig079_counts(con), counts_want)) .mig079_fail("table counts are not as planned.")
    if (!identical(sums_before, .mig079_checksum(con, x$hash))) .mig079_fail("something outside the planned rows moved.")
    mig_db_checks_gate(con, baseline)
    after_all <- db_checks(con, tier = "all")
    pr <- .mig079_checks_problem(before_all, after_all)
    if (!is.null(pr)) .mig079_fail(paste0("standing checks: ", pr))
    logf("Attached %d file(s) as assets.", nrow(x))
    NULL
  })
  copies
}

# ---- backups, files ----------------------------------------------------------------------

mig079_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- if (is.null(.now)) Sys.time() else .now
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig079_name, ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig079_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig079_counts(verify_con)))
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  dest
}

.mig079_write_csv <- function(df, path, key) {
  utils::write.csv(df, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8", colClasses = "character")
  if (nrow(back) != nrow(df) || (nrow(df) && !identical(back[[key]], as.character(df[[key]]))))
    cli::cli_abort("079: CSV {basename(path)} did not round-trip.", class = "sampletidy_error")
}

.mig079_csv <- function(csv_dir, what) file.path(csv_dir, sprintf("%s-%s.csv", .mig079_name, what))

.mig079_read_skipped <- function(csv_dir) {
  f <- .mig079_csv(csv_dir, "SKIPPED")
  if (!file.exists(f)) return(NULL)
  utils::read.csv(f, colClasses = "character", na.strings = "", encoding = "UTF-8")
}

# ---- run ---------------------------------------------------------------------------------

mig079_run <- function(db, snapshot_dir, archive_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL,
                       input_dir = "dev/migrations") {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  checkmate::assert_directory_exists(archive_dir)
  withr::local_options(sampletidy.archive_dir = archive_dir)
  if (!identical(st_config("archive_dir"), archive_dir)) .mig079_fail("archive_dir did not take.")
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir
  x0 <- .mig079_read_inputs(input_dir)

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                                   params = list(.mig079_marker_version)),
                   finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    sk <- .mig079_read_skipped(csv_dir)
    if (is.null(sk)) .mig079_fail(sprintf("marker present but %s is missing: cannot re-verify.", .mig079_csv(csv_dir, "SKIPPED")))
    x <- x0[!x0$gid %in% sk$gid, , drop = FALSE]
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch({
      pr <- .mig079_done_problem(check_con, x, archive_dir)
      if (!is.null(pr)) .mig079_fail(paste0("re-verify: ", pr))
    }, finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("079 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_, restore_command = NA_character_,
                          recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  problems <- tryCatch({
    if (.mig079_scalar(pre_con, "SELECT COUNT(*) FROM change_log WHERE actor = ?", .mig079_actor) > 0L)
      .mig079_fail("change_log already holds 079 rows but the marker is absent; refusing.")
    if (!identical(.ig_retained_asset_type(x0$filename[4]), "Chemical analysis"))
      .mig079_fail("the ACIRL-report type rule no longer yields Chemical analysis.")
    .mig079_problems(pre_con, x0)
  }, finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  skipped <- .mig079_skipped_df(problems)
  x <- x0[!x0$gid %in% skipped$gid, , drop = FALSE]
  logf("Plan: attach %d of %d file(s); %d group(s) skipped.", nrow(x), nrow(x0), nrow(skipped))
  for (i in seq_len(nrow(skipped))) logf("SKIP %s: %s", skipped$gid[[i]], skipped$problem[[i]])
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition checked. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_, restore_command = NA_character_, recorded_at = NA)))
  }

  bk_con <- st_connect(db, read_only = TRUE)
  tryCatch({
    .mig079_write_csv(.mig079_rows(bk_con, x$hash), .mig079_csv(csv_dir, "BACKUP-ingest_file"), ".id")
    .mig079_write_csv(skipped, .mig079_csv(csv_dir, "SKIPPED"), "gid")
  }, finally = DBI::dbDisconnect(bk_con, shutdown = TRUE))
  logf("Row backup and the SKIPPED plan written to %s", csv_dir)
  backup_path <- mig079_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s (and delete the <archive_dir>/<uuid_asset>/ dirs in the BACKUP-copies CSV)", restore_command)
  recorded_at <- if (is.null(.now)) Sys.time() else .now

  copies <- with_db_write(function(con) {
    again <- .mig079_problems(con, x)
    if (length(again)) .mig079_fail("a precondition changed since the dry check; re-run.")
    .mig079_apply(con, x, archive_dir, recorded_at, logf)
  }, db = db)
  .mig079_write_csv(copies, .mig079_csv(csv_dir, "BACKUP-copies"), "gid")

  logf("%s migrated successfully (marker %d).", .mig079_name, .mig079_marker_version)
  invisible(list(status = "migrated", backup_path = backup_path, restore_command = restore_command,
                 recorded_at = recorded_at))
}
