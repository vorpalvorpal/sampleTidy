# Operator-run migration: re-hash the 18 archived ACIRL `.xls` assets that
# SharePoint rewrote (Office metadata) after they were archived, so `asset.hash`
# verifies the archive copy again and a re-import dedupes onto the existing asset.
# Marker 1055. Requires 1054.
#
# Authority: Robin, 2026-10-19 (archive audit, issue 3:
# hist/audit/sharepoint_rewritten_reimports.csv).
#
# ---- WHAT ----------------------------------------------------------------------
#   For each of the 18 asset rows below (uuid, filename, old hash all asserted):
#     asset.hash     <- rlang::hash_file() (xxHash128) of the file as it now is on
#                       OneDrive (processed/<uuid>/<filename>); the hashes and sizes
#                       are computed once, from the local mirror copy
#                       (scratchpad/2026-10-19-corpus/src/processed/, byte-sizes
#                       equal to the OneDrive stat sizes), and frozen here as literals;
#     asset.comments <- existing comments (if any), then
#                       "055: hash was <old> before SharePoint rewrote the file (2026-10-19)".
#   `ingest_file` rows are NOT touched: their old-hash rows stay as the record of the
#   bytes that were actually ingested. The router looks a file up by content hash
#   only, so a re-dropped copy of the rewritten file (new hash, no ingest_file row)
#   routes as a new file; its samples already exist (rows_already_present) and
#   archive_file() finds the asset by hash and reuses it instead of archiving a
#   second copy (verified in the E2E, see MIGRATIONS.md).
#
# ---- PRECONDITIONS (any failure aborts; nothing is written) ---------------------
#   * marker 1054 present;
#   * each asset row exists exactly once with that uuid, filename and old hash;
#   * no asset row and no ingest_file row already has any of the new hashes;
#   * the 18 new hashes are distinct (and differ from the old ones).
#
# Writes, in one transaction: 18 x db_update(asset, hash + comments) = 36
# change_log rows (actor "055-rehash-sharepoint-rewritten-assets", source_hash NA)
# and the marker; every other table, row and column is checksummed before and
# after. Backups: verified whole-file snapshot, plus
# `055-...-BACKUP-asset.csv` (the 18 asset rows, before).
#
# Idempotent: marker present -> re-verify, no-op.
#
#   devtools::load_all(".")
#   env <- new.env()
#   sys.source("dev/migrations/055-rehash-sharepoint-rewritten-assets.R", envir = env)
#   env$mig055_run(db = st_config("live_db"),
#                  snapshot_dir = st_config("snapshot_dir"), dry_run = TRUE)

.mig055_marker_version <- 1055L
.mig055_requires <- 1054L
.mig055_name <- "055-rehash-sharepoint-rewritten-assets"
.mig055_actor <- .mig055_name
.mig055_date <- "2026-10-19"
.mig055_reason <- "055 (Robin, 2026-10-19): SharePoint rewrote the archived file after archiving; asset.hash re-computed from the file as it now is so the archive verifies and a re-import dedupes"
.mig055_assets <- data.frame(
uuid = c("bb579ba6-1685-4748-992d-a131801dc7fb",
  "182f4a9f-94b3-478b-b5a3-4d4e7b4f93ee",
  "5c015059-4d91-4c58-ba4e-424994c1d35d",
  "e2f78ed5-5f77-444f-875e-219b2821cd2c",
  "8b54651b-77f2-4f0a-b6ec-ff6ac58d802e",
  "dce90e2e-2582-4857-88f5-44fca4d16587",
  "4380c908-580e-4e68-9224-2d0a18c97266",
  "675a6935-615f-4b68-a3e3-8b70e93c8b62",
  "26e8e526-2f77-4fbd-93c0-14d668221509",
  "f54f5c80-a48d-472b-b05a-71a7c2787ee7",
  "8efa742b-ce0a-4b6f-b6a7-939ac3331a99",
  "2894ded3-5b3a-47dd-a842-e16925c25cc3",
  "7efbeba2-a5a8-40e4-bbf7-f008fcb7cd0f",
  "5ad69ddb-7cd0-4546-a64d-993bfdcb7770",
  "2819f204-253f-47d0-b70b-68c6eb56a475",
  "a0f55491-5228-4631-810b-e1554a18f941",
  "cb6198f1-32cd-4493-9ea5-abb95867b777",
  "193afc20-77fc-4965-a3e3-da7e5699f260"),
filename = c("2400-7127-05 May 2021 Monthly Gas Monitoring Blaxland WMF.XLS",
  "2400-7399-04 Monthly Blaxland WMF .xls",
  "2400-7399-08 August 2024 Monthly Blaxland WMF .cleaned.xls",
  "2400-7399-08-01 August 2024 Monthly Gas Monitoring Blaxland WMF.xls",
  "2400-7453-03 Annual March 2026 Blaxland WMF  .xls",
  "2400-7453-05-01 May 2025 Monthly Gas Monitoring Blaxland WMF.xls",
  "2400-7453-07-01 July 2025 Monthly Gas Monitoring Blaxland WMF.xls",
  "2400-7453-08 August Monthly Blaxland WMF .xls",
  "2400-7453-08-01 August 2025 Monthly Gas Monitoring Blaxland WMF.xls",
  "2400-7453-10-01 October 2025 Monthly Gas Monitoring Blaxland WMF.xls",
  "2400-7454-06-01 June 2025 Gas Monitoring Katoomba WMF.xls",
  "2400-7454-09-01 September 2025 Gas Monitoring Katoomba WMF.xls",
  "2400-7538 01-01 January 2026 Monthly Gas Monitoring Blaxland WMF.xls",
  "2400-7538-05-02 May Blaxland WMF .xls",
  "2400-7538-06 2026 Quarterly Blaxland WMF.xls",
  "2400-7538-06-01 Monthly Gas Monitoring Blaxland WMF.xls",
  "2400-7538-07 Monthly Blaxland WMF.xls",
  "2400-7538-07-01 Monthly Gas Monitoring Blaxland WMF.xls"),
old_hash = c("408156a26d4f4c8acf2c6405da092abe",
  "0b6a3ffaeb24f540c74a628ee91ba7c4",
  "446f219decfb7580d481a258aefddb68",
  "283fff6659db3c0e09b5069e3b7506a1",
  "545d654b9b560a080ef857275fd7f599",
  "3c56d7e64c54a2f36cfdfb79ffc30d81",
  "6aa86ca728f92e1a19f1bca7eecbacc9",
  "dcbfe003b04bfa538cdc6554be5e15d5",
  "2e2c3c493a9ea607c25beabfe12d833a",
  "cc872f0ec5e2af18d68ef479c7dec9b3",
  "2a9cf972ad8dc8173c25026a3bdec51b",
  "a5827389467db6e478f72a241c21364a",
  "fe29a2cf4918618a90a0aeae1dad205c",
  "35bc65b76300af8d65b09609872e34b8",
  "f6bed14544f6e6d3e5c9a1129be4f6f1",
  "70e8103c3f5d25f7e04d609627dfea88",
  "dfd93dc19f0d2d5023a795e42515b04f",
  "b58ba14981d076d917b3cae3b5665298"),
new_hash = c("90af1b4fb8df4b7c089c59e64b628e5e",
  "42d7e67d13ebc367beda6894562bcaa4",
  "4534bb2668679618f5f87242ece33bb8",
  "3417d1b79d58bd8704cdbee72028df93",
  "6e078db706fb1caf5de9a6a06fc7ea67",
  "4a5a6fd377c96668f2d23b00f2881857",
  "7ceca4466833ed80179cd2ae3a0ba1ca",
  "1d053c4c3788b897d5df8ea91e98108b",
  "3b22ab9e1c9aa46a43ee82a27b57af98",
  "d07d1d73e69f77b08876d29a85b2b80a",
  "6acde1f209c28fe597916a816d3e6074",
  "1587f357c772c9a60f03136081ea471e",
  "66d873e5f2670e8fd3fec185fe463384",
  "ee5a55e5745ebfe3ea6512c838317dd2",
  "49d5ab6eeffda0427ae7836c45fd02a8",
  "8ab68328aaa444e1832fd52bac8868f7",
  "782c36741ab87f2093d1d5d04b81521a",
  "c6f3ebe1235d1395b2d9caa5acdaed8a"),
size = c(24409600, 184320, 172544, 2984448, 297984, 2988032, 2988544, 175104, 2991104, 2988544, 2689024, 2710016, 2991616, 206336, 240640, 2098688, 183808, 3003904),
  stringsAsFactors = FALSE)

.mig055_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = list(...))[[1]][[1]])
.mig055_fail <- function(msg) cli::cli_abort(paste0(.mig055_name, ": ", msg), class = "sampletidy_error")
.mig055_inlist <- function(x) if (!length(x)) "('')" else paste0("(", paste0("'", x, "'", collapse = ","), ")")
.mig055_note <- function(old_hash) sprintf("055: hash was %s before SharePoint rewrote the file (%s)", old_hash, .mig055_date)
.mig055_comment <- function(old_comment, old_hash) {
  if (is.na(old_comment) || !nzchar(old_comment)) .mig055_note(old_hash)
  else paste0(old_comment, "; ", .mig055_note(old_hash))
}

.mig055_counts <- function(con) {
  tabs <- c("ingest_file", "ingest_sighting", "project", "sample", "analysis", "asset", "review_queue",
            "change_log", "schema_version")
  stats::setNames(lapply(tabs, function(t) .mig055_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
}

.mig055_problems <- function(con) {
  a <- .mig055_assets; probs <- character(0)
  if (anyDuplicated(a$new_hash) || anyDuplicated(a$uuid) || any(a$new_hash == a$old_hash))
    probs <- c(probs, "the data table's new hashes are not distinct / differ-from-old, or uuids repeat")
  for (i in seq_len(nrow(a))) {
    n <- .mig055_scalar(con, "SELECT COUNT(*) FROM asset WHERE uuid = ? AND filename = ? AND hash = ?",
                        a$uuid[[i]], a$filename[[i]], a$old_hash[[i]])
    if (n != 1L) probs <- c(probs, sprintf("asset %s (%s): %d rows with that uuid/filename/old hash, expected 1",
                                           a$uuid[[i]], a$filename[[i]], n))
  }
  n <- .mig055_scalar(con, sprintf("SELECT COUNT(*) FROM asset WHERE hash IN %s", .mig055_inlist(a$new_hash)))
  if (n != 0L) probs <- c(probs, sprintf("%d asset row(s) already have one of the new hashes", n))
  n <- .mig055_scalar(con, sprintf("SELECT COUNT(*) FROM ingest_file WHERE hash IN %s", .mig055_inlist(a$new_hash)))
  if (n != 0L) probs <- c(probs, sprintf("%d ingest_file row(s) already have one of the new hashes", n))
  probs
}

.mig055_check_preconditions <- function(con) {
  if (.mig055_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig055_requires) == 0L)
    .mig055_fail(sprintf("marker %d (054) is required first.", .mig055_requires))
  probs <- .mig055_problems(con)
  if (length(probs)) .mig055_fail(sprintf("%s. Nothing written.", paste(probs, collapse = " | ")))
  invisible(TRUE)
}

.mig055_checksum <- function(con) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  tabs <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  touched <- c("asset", "change_log", "schema_version")
  out <- lapply(setdiff(tabs, touched), function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- setdiff(tabs, touched)
  u <- .mig055_inlist(.mig055_assets$uuid)
  out$asset_rest <- q(sprintf("SELECT * FROM asset WHERE uuid NOT IN %s ORDER BY uuid", u))
  out$asset_fixed <- q(sprintf("SELECT * EXCLUDE (hash, comments) FROM asset WHERE uuid IN %s ORDER BY uuid", u))
  out$change_log_rest <- q(sprintf("SELECT * FROM change_log WHERE actor <> '%s' ORDER BY ALL", .mig055_actor))
  out$schema_version_rest <- q(sprintf("SELECT * FROM schema_version WHERE version <> %d ORDER BY ALL", .mig055_marker_version))
  out$views <- q("SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
  out$indexes <- q("SELECT index_name, sql FROM duckdb_indexes() ORDER BY index_name")
  out
}

.mig055_done_problem <- function(con) {
  a <- .mig055_assets
  if (.mig055_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig055_marker_version) != 1L)
    return("marker 1055 missing")
  cl <- DBI::dbGetQuery(con, "SELECT tbl, action, field, uuid_row, old, new FROM change_log WHERE actor = ?",
                        params = list(.mig055_actor))
  if (nrow(cl) != 2L * nrow(a) || any(cl$tbl != "asset") || any(cl$action != "update") ||
      !all(table(cl$field) == nrow(a)) || !setequal(cl$field, c("hash", "comments")))
    return(sprintf("055 change_log is %d row(s), not %d asset hash + comments updates", nrow(cl), 2L * nrow(a)))
  for (i in seq_len(nrow(a))) {
    r <- DBI::dbGetQuery(con, "SELECT * FROM asset WHERE uuid = ?", params = list(a$uuid[[i]]))
    if (nrow(r) != 1L || !identical(r$filename[[1]], a$filename[[i]])) return(sprintf("asset %s missing or renamed", a$uuid[[i]]))
    if (!identical(r$hash[[1]], a$new_hash[[i]])) return(sprintf("asset %s hash is %s, expected %s", a$uuid[[i]], r$hash[[1]], a$new_hash[[i]]))
    c1 <- cl[cl$uuid_row == a$uuid[[i]], , drop = FALSE]
    h <- c1[c1$field == "hash", , drop = FALSE]; m <- c1[c1$field == "comments", , drop = FALSE]
    if (nrow(h) != 1L || nrow(m) != 1L || !identical(h$old, a$old_hash[[i]]) || !identical(h$new, a$new_hash[[i]]))
      return(sprintf("asset %s change_log hash row is wrong", a$uuid[[i]]))
    if (!identical(r$comments[[1]], .mig055_comment(m$old, a$old_hash[[i]])) || !identical(m$new, r$comments[[1]]))
      return(sprintf("asset %s comments are not the old comments + the 055 note", a$uuid[[i]]))
    # ingest_file keeps the original-bytes record: the old-hash rows are never touched here
  }
  n <- .mig055_scalar(con, sprintf("SELECT COUNT(*) FROM ingest_file WHERE hash IN %s", .mig055_inlist(a$new_hash)))
  if (n != 0L) return("an ingest_file row carries a new hash")
  NULL
}

.mig055_verify <- function(con) {
  p <- .mig055_done_problem(con)
  if (!is.null(p)) cli::cli_abort(paste0("055 verify failed: ", p), class = "sampletidy_error")
  invisible(TRUE)
}

mig055_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- if (is.null(.now)) Sys.time() else .now
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig055_name, ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig055_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig055_counts(verify_con)))
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  dest
}

.mig055_write_csv <- function(df, path, key) {
  out <- df
  for (f in names(out)) if (inherits(out[[f]], c("POSIXct", "Date"))) out[[f]] <- .st_changelog_str(out[[f]])
  utils::write.csv(out, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8", colClasses = "character")
  if (nrow(back) != nrow(df) || !identical(back[[key]], as.character(out[[key]])))
    cli::cli_abort("055: CSV {basename(path)} did not round-trip.", class = "sampletidy_error")
}

.mig055_apply <- function(con, recorded_at) {
  a <- .mig055_assets
  sums_before <- .mig055_checksum(con)
  want <- .mig055_counts(con)
  want$change_log <- want$change_log + 2L * nrow(a)
  want$schema_version <- want$schema_version + 1L
  db_transaction(con, function(con) {
    for (i in seq_len(nrow(a))) {
      old_c <- DBI::dbGetQuery(con, "SELECT comments FROM asset WHERE uuid = ?", params = list(a$uuid[[i]]))$comments[[1]]
      db_update(con, "asset", uuid = a$uuid[[i]],
                changes = list(hash = a$new_hash[[i]], comments = .mig055_comment(old_c, a$old_hash[[i]])),
                actor = .mig055_actor, reason = .mig055_reason)
    }
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig055_marker_version, recorded_at))
    .mig055_verify(con)
    got <- .mig055_counts(con)
    if (!identical(got, want))
      .mig055_fail(sprintf("counts are not before + %d change_log + 1 marker: %s", 2L * nrow(a),
                           paste(names(got), unlist(got), unlist(want), sep = ":", collapse = ", ")))
    if (!identical(sums_before, .mig055_checksum(con))) .mig055_fail("something outside the planned rows/columns moved.")
    NULL
  })
  invisible(NULL)
}

mig055_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(
    DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                    params = list(.mig055_marker_version)),
    finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch(.mig055_verify(check_con), finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("055 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  tryCatch(.mig055_check_preconditions(pre_con), finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  for (i in seq_len(nrow(.mig055_assets)))
    logf("Re-hash asset %s (%s): %s -> %s (%s bytes)", .mig055_assets$uuid[[i]], .mig055_assets$filename[[i]],
         .mig055_assets$old_hash[[i]], .mig055_assets$new_hash[[i]], format(.mig055_assets$size[[i]], big.mark = ","))
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition passed. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_, restore_command = NA_character_,
                          recorded_at = NA)))
  }

  bk_con <- st_connect(db, read_only = TRUE)
  tryCatch({
    .mig055_write_csv(DBI::dbGetQuery(bk_con, sprintf("SELECT * FROM asset WHERE uuid IN %s ORDER BY uuid",
                                                      .mig055_inlist(.mig055_assets$uuid))),
                      file.path(csv_dir, sprintf("%s-BACKUP-asset.csv", .mig055_name)), "uuid")
  }, finally = DBI::dbDisconnect(bk_con, shutdown = TRUE))
  logf("Row backups written to %s", csv_dir)
  backup_path <- mig055_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- if (is.null(.now)) Sys.time() else .now

  with_db_write(function(con) {
    .mig055_check_preconditions(con)   # re-read under the write lock
    .mig055_apply(con, recorded_at)
  }, db = db)

  logf("%s migrated successfully (marker %d): %d asset rows re-hashed.",
       .mig055_name, .mig055_marker_version, nrow(.mig055_assets))
  invisible(list(status = "migrated", backup_path = backup_path,
                 restore_command = restore_command, recorded_at = recorded_at))
}
