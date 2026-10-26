# Operator-run migration: re-hash the ACIRL `.xls` assets that SharePoint rewrote after
# archiving (the 39 of 085's finding), so `asset.hash` verifies the stored file again.
# Marker 1087. Requires 1086. (085 is spent and was never written.)
#
# Authority: Robin, 2026-10-26 (approved re-hashing, as 055 did, after 085 showed that
# restoring the archived bytes cannot hold).
#
# ---- WHY ------------------------------------------------------------------------------
# SharePoint rewrites the `MsoDataStore` metadata storage (directory timestamps, child
# storage names, content-type `ma:versionID`) of old-format Office files 3-35 s after they
# land in the synced asset store; archive_file() hashes the local copy before that. The
# `Workbook`, `SummaryInformation` and `DocumentSummaryInformation` streams are
# byte-identical to the surviving source file (checked 2026-10-26 for every row below by
# parsing the OLE/CFB structure: only the MsoDataStore `Item`/`Properties` streams differ),
# so the data is unchanged. Restoring the bytes does not stick (SharePoint rewrites them
# again within 35 s), so the hash follows the file, as in 055.
#
# ---- WHAT (frozen in 087-rehash-sharepoint-rewritten-xls-INPUT.csv) --------------------
# Per row: asset.hash <- rlang::hash_file() (xxHash128) of processed/<uuid>/<filename> as it
# is now (read three times over more than 2 minutes before freezing; only files whose hash
# was identical every time are in INPUT); asset.comments gets "087: hash was <old> ..."
# appended. `ingest_file` is NOT touched (as 055): its old-hash rows stay as the record of
# the bytes as received, and keep change_log provenance hashes resolving. No other table
# stores these hashes except ingest_file / change_log.source_hash, which 055 left alone too.
# The BACKUP asset CSV carries the full old row plus old_hash and new_hash columns; it is
# the source for any future "as-received hash" column.
#
# ---- CHECKS ---------------------------------------------------------------------------
# Pre-flight (a row failing is SKIPPED, written to SKIPPED.csv, and reported): row sha1 as
# frozen; asset.hash = old hash; the stored file hashes to the frozen new hash and size;
# no asset / ingest_file / ingest_sighting row holds a new hash. Then ONE transaction:
# db_checks baseline, whole-table checksums of everything else, counts, mig_db_checks_gate(),
# no all-tier check gains an offender (change_log_dangling_source_hash may gain the old
# hashes, though the kept ingest_file rows should make that moot). Idempotent: marker
# present -> re-verify, no-op.
#
#   Rscript dev/migrations/apply-087-rehash-sharepoint-rewritten-xls.R

.mig087_marker_version <- 1087L
.mig087_requires <- 1086L
.mig087_name <- "087-rehash-sharepoint-rewritten-xls"
.mig087_actor <- .mig087_name
.mig087_date <- "2026-10-26"
.mig087_reason <- "087 (Robin 2026-10-26): SharePoint rewrote the archived .xls after archiving; asset.hash re-computed from the file as it now is"
.mig087_cols <- c("uuid", "filename", "old_hash", "new_hash", "size", "row_sha1")

.mig087_fail <- function(msg) cli::cli_abort(paste0(.mig087_name, ": ", msg), class = "sampletidy_error")
.mig087_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = if (length(list(...))) list(...) else NULL)[[1]][[1]])
.mig087_inlist <- function(x) if (!length(x)) "('')" else paste0("(", paste0("'", gsub("'", "''", unique(x)), "'", collapse = ","), ")")
.mig087_note <- function(old_hash) sprintf("087: hash was %s before SharePoint rewrote the file (Office metadata only; workbook data unchanged) (Robin, %s)", old_hash, .mig087_date)
.mig087_append <- function(old, note) if (is.na(old) || !nzchar(trimws(old))) note else paste0(old, "; ", note)
.mig087_hash <- function(path) if (file.exists(path)) rlang::hash_file(path) else NA_character_

.mig087_sha <- function(df) {
  if (nrow(df) != 1L) return(NA_character_)
  cols <- names(df)
  v <- vapply(cols, function(f) { s <- .st_changelog_str(df[[f]][1]); if (is.na(s)) "<NA>" else s }, "")
  digest::digest(paste(cols, v, sep = "=", collapse = "\u001f"), algo = "sha1", serialize = FALSE)
}
.mig087_row <- function(con, id) DBI::dbGetQuery(con, "SELECT * FROM asset WHERE uuid = ?", params = list(id))

.mig087_counts <- function(con) {
  tabs <- c("analysis", "sample", "feature", "lab_method", "analyte", "asset", "ingest_file", "ingest_sighting",
            "project", "review_queue", "lab_qc_report", "lab_qc_outlier", "change_log", "schema_version")
  stats::setNames(lapply(tabs, function(t) .mig087_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
}

.mig087_read_inputs <- function(input_dir = "dev/migrations") {
  p <- file.path(input_dir, sprintf("%s-INPUT.csv", .mig087_name))
  if (!file.exists(p)) .mig087_fail(sprintf("input %s not found.", p))
  x <- utils::read.csv(p, colClasses = "character", na.strings = "", encoding = "UTF-8")
  if (!identical(names(x), .mig087_cols)) .mig087_fail("INPUT columns are not as planned.")
  if (!nrow(x) || anyNA(x) || anyDuplicated(x$uuid) || anyDuplicated(x$new_hash) || any(x$old_hash == x$new_hash))
    .mig087_fail("INPUT is empty, has gaps, repeats a row, or a new hash equals an old one.")
  x$size <- as.numeric(x$size)
  x
}

# Per-row problems; named by uuid. Names appear only for rows that fail.
.mig087_problems <- function(con, x, archive_dir) {
  out <- character(0)
  add <- function(id, msg) out[[id]] <<- if (id %in% names(out)) paste(out[[id]], msg, sep = "; ") else msg
  for (i in seq_len(nrow(x))) {
    id <- x$uuid[[i]]
    r <- .mig087_row(con, id)
    if (nrow(r) != 1L) { add(id, "asset row missing"); next }
    if (!identical(.mig087_sha(r), x$row_sha1[[i]])) add(id, "asset row is not as frozen")
    if (!identical(r$hash[[1]], x$old_hash[[i]])) add(id, sprintf("asset.hash is %s, expected %s", r$hash[[1]], x$old_hash[[i]]))
    if (!identical(r$filename[[1]], x$filename[[i]])) add(id, "filename differs")
    p <- file.path(archive_dir, id, x$filename[[i]])
    if (!file.exists(p)) { add(id, "stored file missing"); next }
    if (file.size(p) != x$size[[i]]) add(id, sprintf("stored file is %s bytes, expected %s", file.size(p), x$size[[i]]))
    h <- .mig087_hash(p)
    if (!identical(h, x$new_hash[[i]])) add(id, sprintf("stored file hashes to %s, not the frozen %s (still changing?)", h, x$new_hash[[i]]))
  }
  for (tb in c("asset", "ingest_file", "ingest_sighting")) {
    hit <- DBI::dbGetQuery(con, sprintf('SELECT hash FROM "%s" WHERE hash IN %s', tb, .mig087_inlist(x$new_hash)))$hash
    for (h in hit) add(x$uuid[match(h, x$new_hash)], sprintf("%s already holds the new hash", tb))
  }
  out
}

# Build INPUT from a settled hash table (uuid, filename, h, sz) and the live rows.
mig087_freeze <- function(db, settled, input_dir = "dev/migrations") {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  x <- data.frame(uuid = settled$uuid, filename = settled$filename, stringsAsFactors = FALSE)
  rows <- lapply(x$uuid, function(id) .mig087_row(con, id))
  if (any(vapply(rows, nrow, 1L) != 1L)) .mig087_fail("an asset row is missing at freeze.")
  x$old_hash <- vapply(rows, function(r) r$hash[[1]], "")
  x$new_hash <- settled$h
  x$size <- settled$sz
  x$row_sha1 <- vapply(rows, .mig087_sha, "")
  x <- x[order(x$uuid), .mig087_cols]
  utils::write.csv(x, file.path(input_dir, sprintf("%s-INPUT.csv", .mig087_name)), row.names = FALSE, na = "",
                   fileEncoding = "UTF-8")
  invisible(x)
}

.mig087_done_problem <- function(con, x, archive_dir) {
  if (.mig087_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig087_marker_version) != 1L)
    return("marker 1087 missing")
  cl <- DBI::dbGetQuery(con, "SELECT tbl, action, field, uuid_row, old, new FROM change_log WHERE actor = ?",
                        params = list(.mig087_actor))
  if (nrow(cl) != 2L * nrow(x) || any(cl$tbl != "asset") || any(cl$action != "update") ||
      !setequal(cl$field, c("hash", "comments")) || !all(table(cl$field) == nrow(x)))
    return(sprintf("087 change_log is %d row(s), not %d asset hash + comments updates", nrow(cl), 2L * nrow(x)))
  for (i in seq_len(nrow(x))) {
    r <- .mig087_row(con, x$uuid[[i]])
    if (nrow(r) != 1L) return(sprintf("asset %s missing", x$uuid[[i]]))
    if (!identical(r$hash[[1]], x$new_hash[[i]])) return(sprintf("asset %s hash is %s, expected %s", x$uuid[[i]], r$hash[[1]], x$new_hash[[i]]))
    c1 <- cl[cl$uuid_row == x$uuid[[i]], , drop = FALSE]
    h <- c1[c1$field == "hash", , drop = FALSE]; m <- c1[c1$field == "comments", , drop = FALSE]
    if (nrow(h) != 1L || nrow(m) != 1L || !identical(h$old, x$old_hash[[i]]) || !identical(h$new, x$new_hash[[i]]))
      return(sprintf("asset %s change_log hash row is wrong", x$uuid[[i]]))
    if (!identical(r$comments[[1]], .mig087_append(m$old, .mig087_note(x$old_hash[[i]]))) || !identical(m$new, r$comments[[1]]))
      return(sprintf("asset %s comments are not the old comments + the 087 note", x$uuid[[i]]))
    if (!is.null(archive_dir)) {
      fh <- .mig087_hash(file.path(archive_dir, x$uuid[[i]], x$filename[[i]]))
      if (!identical(fh, x$new_hash[[i]])) return(sprintf("asset %s: stored file hashes to %s, not the recorded %s", x$uuid[[i]], fh, x$new_hash[[i]]))
    }
  }
  if (.mig087_scalar(con, sprintf("SELECT COUNT(*) FROM ingest_file WHERE hash IN %s", .mig087_inlist(x$new_hash))) != 0L)
    return("an ingest_file row carries a new hash")
  NULL
}

.mig087_checksum <- function(con, x) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  tabs <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  touched <- c("asset", "change_log", "schema_version")
  out <- lapply(setdiff(tabs, touched), function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- setdiff(tabs, touched)
  u <- .mig087_inlist(x$uuid)
  out$asset_rest <- q(sprintf("SELECT * FROM asset WHERE uuid NOT IN %s ORDER BY uuid", u))
  out$asset_cols <- q(sprintf("SELECT * EXCLUDE (hash, comments) FROM asset WHERE uuid IN %s ORDER BY uuid", u))
  out$change_log_rest <- q(sprintf("SELECT * FROM change_log WHERE actor <> '%s' ORDER BY ALL", .mig087_actor))
  out$schema_version_rest <- q(sprintf("SELECT * FROM schema_version WHERE version <> %d ORDER BY ALL", .mig087_marker_version))
  out$views <- q("SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
  out$indexes <- q("SELECT index_name, sql FROM duckdb_indexes() ORDER BY index_name")
  out
}

.mig087_checks_problem <- function(before, after, allow = list()) {
  for (i in seq_len(nrow(after))) {
    nm <- after$name[[i]]
    b <- before[before$name == nm, , drop = FALSE]
    if (after$status[[i]] == "error") {
      if (!nrow(b) || b$status[[1]] != "error") return(sprintf("check %s now errors: %s", nm, after$message[[i]]))
      next
    }
    added <- setdiff(after$keys[[i]], c(if (nrow(b)) b$keys[[1]] else character(), allow[[nm]]))
    if (length(added)) return(sprintf("check %s gains offender(s) %s", nm, paste(utils::head(added, 3), collapse = ", ")))
  }
  NULL
}

.mig087_apply <- function(con, x, archive_dir, recorded_at, logf) {
  db_transaction(con, function(con) {
    baseline <- db_checks(con, tier = "migration")
    before_all <- db_checks(con, tier = "all")
    sums_before <- .mig087_checksum(con, x)
    want <- .mig087_counts(con)
    want$change_log <- want$change_log + 2L * nrow(x)
    want$schema_version <- want$schema_version + 1L
    for (i in seq_len(nrow(x))) {
      old <- .mig087_row(con, x$uuid[[i]])$comments[[1]]
      db_update(con, "asset", uuid = x$uuid[[i]],
                changes = list(hash = x$new_hash[[i]], comments = .mig087_append(old, .mig087_note(x$old_hash[[i]]))),
                actor = .mig087_actor, reason = .mig087_reason)
    }
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig087_marker_version, recorded_at))
    pr <- .mig087_done_problem(con, x, archive_dir)
    if (!is.null(pr)) .mig087_fail(paste0("verify failed: ", pr))
    got <- .mig087_counts(con)
    if (!identical(got, want))
      .mig087_fail(sprintf("table counts are not as planned: %s",
                           paste(names(got), unlist(got), unlist(want), sep = ":", collapse = ", ")))
    if (!identical(sums_before, .mig087_checksum(con, x))) .mig087_fail("something outside the planned rows/columns moved.")
    mig_db_checks_gate(con, baseline)
    after_all <- db_checks(con, tier = "all")
    pr <- .mig087_checks_problem(before_all, after_all, allow = list(change_log_dangling_source_hash = x$old_hash))
    if (!is.null(pr)) .mig087_fail(paste0("standing checks: ", pr))
    logf("Re-hashed %d asset(s).", nrow(x))
    NULL
  })
  invisible(NULL)
}

mig087_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- if (is.null(.now)) Sys.time() else .now
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig087_name, ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig087_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig087_counts(verify_con)))
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  dest
}

.mig087_write_csv <- function(df, path, key) {
  out <- df
  for (f in names(out)) if (inherits(out[[f]], c("POSIXct", "Date"))) out[[f]] <- .st_changelog_str(out[[f]])
  utils::write.csv(out, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8", colClasses = "character")
  if (nrow(back) != nrow(df) || (nrow(df) && !identical(back[[key]], as.character(out[[key]]))))
    cli::cli_abort("087: CSV {basename(path)} did not round-trip.", class = "sampletidy_error")
}
.mig087_csv <- function(csv_dir, what) file.path(csv_dir, sprintf("%s-%s.csv", .mig087_name, what))

mig087_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL, input_dir = "dev/migrations",
                       archive_dir = st_config("archive_dir")) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir
  x0 <- .mig087_read_inputs(input_dir)

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                                   params = list(.mig087_marker_version)),
                   finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    sk <- .mig087_csv(csv_dir, "SKIPPED")
    skipped_ids <- if (file.exists(sk)) utils::read.csv(sk, colClasses = "character", na.strings = "")$uuid else character()
    x <- x0[!x0$uuid %in% skipped_ids, , drop = FALSE]
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch({
      pr <- .mig087_done_problem(check_con, x, archive_dir)
      if (!is.null(pr)) .mig087_fail(paste0("re-verify: ", pr))
    }, finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("087 already applied at %s; re-verified (DB and file hashes); nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_, restore_command = NA_character_,
                          recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  problems <- tryCatch({
    if (.mig087_scalar(pre_con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig087_requires) == 0L)
      .mig087_fail(sprintf("marker %d is required first.", .mig087_requires))
    if (.mig087_scalar(pre_con, "SELECT COUNT(*) FROM change_log WHERE actor = ?", .mig087_actor) > 0L)
      .mig087_fail("change_log already holds 087 rows but the marker is absent; refusing.")
    .mig087_problems(pre_con, x0, archive_dir)
  }, finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  skipped <- data.frame(uuid = names(problems), problem = unname(problems), stringsAsFactors = FALSE)
  x <- x0[!x0$uuid %in% skipped$uuid, , drop = FALSE]
  logf("Plan: %d of %d asset(s) re-hashed; %d skipped.", nrow(x), nrow(x0), nrow(skipped))
  for (i in seq_len(nrow(x))) logf("  %s (%s): %s -> %s", x$uuid[[i]], x$filename[[i]], x$old_hash[[i]], x$new_hash[[i]])
  for (i in seq_len(nrow(skipped))) logf("SKIP %s: %s", skipped$uuid[[i]], skipped$problem[[i]])
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition checked (files hashed). No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_, restore_command = NA_character_, recorded_at = NA)))
  }
  if (!nrow(x)) .mig087_fail("every row is skipped; nothing to do (no marker written).")

  bk_con <- st_connect(db, read_only = TRUE)
  tryCatch({
    a <- DBI::dbGetQuery(bk_con, sprintf("SELECT * FROM asset WHERE uuid IN %s ORDER BY uuid", .mig087_inlist(x$uuid)))
    m <- match(a$uuid, x$uuid)
    a$old_hash <- x$old_hash[m]
    a$new_hash <- x$new_hash[m]
    if (!identical(a$old_hash, a$hash)) .mig087_fail("backup: asset.hash differs from the frozen old hash.")
    .mig087_write_csv(a, .mig087_csv(csv_dir, "BACKUP-asset"), "uuid")
    .mig087_write_csv(skipped, .mig087_csv(csv_dir, "SKIPPED"), "uuid")
  }, finally = DBI::dbDisconnect(bk_con, shutdown = TRUE))
  logf("Row backups and SKIPPED written to %s", csv_dir)
  backup_path <- mig087_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- if (is.null(.now)) Sys.time() else .now

  with_db_write(function(con) {
    again <- .mig087_problems(con, x, archive_dir)
    if (length(again)) .mig087_fail("a precondition changed since the dry check; re-run.")
    .mig087_apply(con, x, archive_dir, recorded_at, logf)
  }, db = db)

  logf("%s migrated successfully (marker %d): %d asset rows re-hashed.", .mig087_name, .mig087_marker_version, nrow(x))
  invisible(list(status = "migrated", backup_path = backup_path, restore_command = restore_command,
                 recorded_at = recorded_at))
}
