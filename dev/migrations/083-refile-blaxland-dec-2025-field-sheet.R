# Operator-run migration: move one misattached ACIRL field-sheet scan, "Quarterly 2-12.pdf",
# from the July 2026 Blaxland work order (ES2623357) to the December 2025 Blaxland quarterly
# work order it belongs to (ES2538342). Marker 1083. Requires 1082.
#
# Authority: Robin, 2026-10-26 (approved the correction of this one asset).
#
# ---- WHY ------------------------------------------------------------------------------
# The scan arrived on 2026-10-19 in the "Blaxland WMF - missing reports and data file" email
# and was archived as a retained sibling (ingest_file 53b1d5e8..., no uuid_asset, as for 57 of
# the 59 retained siblings). It was attached to ES2623357 (July 2026 Blaxland round), whose
# other scans (e.g. "23. WMF Monthly 20-07.pdf") are July 2026 sheets. Page 1 is in fact the
# ACIRL field sheet for the Blaxland WMF quarterly sampled on 2 December 2025 (handwritten
# date "2/12/25"; the PDF was created on 5 Dec 2025).
#
# ---- WHERE (and why not 2400-7453-12-01) ---------------------------------------------
# The ACIRL job 2400-7453-12 has two kinds of child project in live:
#   * ES2538342, a Work order (parent: the ACIRL report project 2400-7453-12, date_start =
#     date_end = 2025-12-02): the 30 water/dust samples of the quarterly, and its files (ALS
#     COA/XTAB/ENMRG and the ACIRL report PDF "2400-7453-12 December 2025 Quarterly Blaxland
#     WMF.pdf").
#   * 2400-7453-12-01, a "Monthly gas monitoring" project (202 gas samples, 2025-12-02), which
#     already holds the December gas field sheet "Gas December 2-12.pdf".
# The live convention for scanned field sheets is: a quarterly/monthly water sheet goes with
# the ALS work order that holds its water samples (2400-7453-09 Quarterly -> ES2528155;
# "20. Quarterly 02-06.pdf" -> ES2617789; "30. Quarterly 28-09.pdf" -> ES2631587;
# "2400-7399-12 ... Quarterly" -> ES2439599 ...), a "Gas ..." sheet with the gas project.
# This is a quarterly water sheet, so it goes to ES2538342, not to the gas project.
#
# ---- WHAT (frozen in 083-refile-blaxland-dec-2025-field-sheet-INPUT.csv) -----------------
#   asset 2c5acb02-423f-408c-9500-57fb5570148b "Quarterly 2-12.pdf"
#     uuid_project 2a398160 (ES2623357) -> fa806613 (ES2538342); comments gets a 083 note.
# (The asset_filing table does not exist in live yet; the precondition checks it only if present.)
# Nothing else references the asset or its hash except its own ingest_file row (hash PK) and
# change_log: no review_queue, no asset_filing, no lab_qc_report. ingest_file is left alone
# (its state is archived/retained_sibling, uuid_asset NULL, as for the other retained siblings).
# No file moves: an archived file lives at <archive_dir>/<asset uuid>/<filename> (A70).
#
# ---- CHECKS ---------------------------------------------------------------------------
# Row sha1 of the asset, the anchor (ES2538342's report PDF) and both projects as frozen; the
# asset is under the source project and the anchor under the target. In one transaction:
# db_checks("migration") baseline, whole-table checksums of everything else, counts
# (change_log +2, schema_version +1), mig_db_checks_gate(), and no all-tier check gains an
# offender. Backups: verified whole-file snapshot; BACKUP CSVs of the asset and both projects
# (untracked), and the SKIPPED CSV. Idempotent: marker present -> re-verify, no-op.
#
#   Rscript dev/migrations/apply-083-refile-blaxland-dec-2025-field-sheet.R

.mig083_marker_version <- 1083L
.mig083_requires <- 1082L
.mig083_name <- "083-refile-blaxland-dec-2025-field-sheet"
.mig083_actor <- .mig083_name
.mig083_reason <- "083 (Robin 2026-10-26: December 2025 Blaxland quarterly field sheet re-filed under its work order)"
.mig083_cols <- c("gid", "op", "tbl", "id", "label", "from_value", "to_value", "anchor", "row_sha1")
.mig083_pk <- c(asset = "uuid", project = "uuid")
.mig083_note <- paste0(
  "2026-10-26 083: moved from ES2623357 (July 2026 Blaxland round) to ES2538342, the December 2025 Blaxland ",
  "quarterly work order (samples 1-2 Dec 2025). Page 1 is the ACIRL field sheet dated 2/12/25 (PDF created ",
  "5 Dec 2025), received 2026-10-19 with the missing-reports email (Robin, 2026-10-26)")

.mig083_plan_rows <- data.frame(
  gid = "G1", op = "move", tbl = "asset",
  id = "2c5acb02-423f-408c-9500-57fb5570148b",
  label = "Quarterly 2-12.pdf",
  from_value = "2a398160-1ca5-48ab-b8a8-c515f3749ccf",
  to_value = "fa806613-2d8d-4cc6-82c6-e1111dd9712a",
  anchor = "d50c0e4c-4220-4d87-8784-1163c95b3885",
  stringsAsFactors = FALSE)

.mig083_fail <- function(msg) cli::cli_abort(paste0(.mig083_name, ": ", msg), class = "sampletidy_error")
.mig083_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = if (length(list(...))) list(...) else NULL)[[1]][[1]])
.mig083_inlist <- function(x) if (!length(x)) "('')" else paste0("(", paste0("'", gsub("'", "''", unique(x)), "'", collapse = ","), ")")
.mig083_append <- function(old, note) if (is.na(old) || !nzchar(trimws(old))) note else paste0(old, "; ", note)

# ---- rows, sha1 -------------------------------------------------------------------------

.mig083_row <- function(con, tbl, id) {
  DBI::dbGetQuery(con, sprintf('SELECT * FROM "%s" WHERE "%s" = ?', tbl, .mig083_pk[[tbl]]), params = list(id))
}

.mig083_sha <- function(df) {
  if (nrow(df) != 1L) return(NA_character_)
  cols <- names(df)
  v <- vapply(cols, function(f) { s <- .st_changelog_str(df[[f]][1]); if (is.na(s)) "<NA>" else s }, "")
  digest::digest(paste(cols, v, sep = "=", collapse = "\u001f"), algo = "sha1", serialize = FALSE)
}

# Every row the move touches or leans on: the asset, the anchor asset and both projects.
.mig083_frozen_keys <- function(x) {
  k <- rbind(data.frame(tbl = "asset", id = c(x$id, x$anchor)),
             data.frame(tbl = "project", id = c(x$from_value, x$to_value)))
  k$gid <- x$gid[[1]]
  k[!duplicated(k[, c("tbl", "id")]), , drop = FALSE]
}

# ---- plan, freeze, inputs ----------------------------------------------------------------

mig083_plan_con <- function(con) {
  x <- .mig083_plan_rows
  k <- .mig083_frozen_keys(x)
  k$row_sha1 <- vapply(seq_len(nrow(k)), function(i) .mig083_sha(.mig083_row(con, k$tbl[[i]], k$id[[i]])), "")
  if (anyNA(k$row_sha1)) .mig083_fail(sprintf("row(s) missing at freeze: %s", paste(k$id[is.na(k$row_sha1)], collapse = ", ")))
  x$row_sha1 <- k$row_sha1[match(paste(x$tbl, x$id), paste(k$tbl, k$id))]
  extra <- k[!paste(k$tbl, k$id) %in% paste(x$tbl, x$id), , drop = FALSE]
  ex <- data.frame(gid = extra$gid, op = "anchor", tbl = extra$tbl, id = extra$id, label = NA_character_,
                   from_value = NA_character_, to_value = NA_character_, anchor = NA_character_,
                   row_sha1 = extra$row_sha1, stringsAsFactors = FALSE)
  out <- rbind(x[, .mig083_cols], ex)
  rownames(out) <- NULL
  out
}

mig083_freeze <- function(db, input_dir = "dev/migrations") {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  p <- mig083_plan_con(con)
  pr <- .mig083_problems(con, p)
  if (length(pr)) .mig083_fail(sprintf("plan does not hold at freeze: %s", paste(names(pr), unlist(pr), collapse = "; ")))
  utils::write.csv(p, file.path(input_dir, sprintf("%s-INPUT.csv", .mig083_name)), row.names = FALSE, na = "",
                   fileEncoding = "UTF-8")
  invisible(p)
}

.mig083_read_inputs <- function(input_dir = "dev/migrations") {
  p <- file.path(input_dir, sprintf("%s-INPUT.csv", .mig083_name))
  if (!file.exists(p)) .mig083_fail(sprintf("input %s not found.", p))
  x <- utils::read.csv(p, colClasses = "character", na.strings = "", encoding = "UTF-8")
  if (!identical(names(x), .mig083_cols)) .mig083_fail("INPUT columns are not as planned.")
  if (anyNA(x$row_sha1) || anyDuplicated(paste(x$tbl, x$id))) .mig083_fail("INPUT misses or repeats a row.")
  pl <- x[x$op != "anchor", setdiff(.mig083_cols, "row_sha1")]
  rownames(pl) <- NULL
  if (!identical(pl, .mig083_plan_rows)) .mig083_fail("INPUT does not match Robin's ruling.")
  x
}

.mig083_planned <- function(x) x[x$op != "anchor", , drop = FALSE]

# ---- preconditions -----------------------------------------------------------------------

# Named list gid -> problems.
.mig083_problems <- function(con, x) {
  have <- DBI::dbGetQuery(con, "SELECT version FROM schema_version")$version
  miss <- setdiff(.mig083_requires, have)
  if (length(miss)) .mig083_fail(sprintf("marker(s) %s required first.", paste(miss, collapse = ", ")))
  pr <- list()
  add <- function(g, m) pr[[g]] <<- c(pr[[g]], m)
  for (i in seq_len(nrow(x))) {
    s <- .mig083_sha(.mig083_row(con, x$tbl[[i]], x$id[[i]]))
    if (is.na(s) || s != x$row_sha1[[i]]) add(x$gid[[i]], sprintf("%s %s missing or not as frozen", x$tbl[[i]], x$id[[i]]))
  }
  pl <- .mig083_planned(x)
  for (k in seq_len(nrow(pl))) {
    g <- pl$gid[[k]]
    a <- DBI::dbGetQuery(con, "SELECT uuid_project FROM asset WHERE uuid = ?", params = list(pl$anchor[[k]]))
    if (nrow(a) != 1L || !identical(a$uuid_project[[1]], pl$to_value[[k]]))
      add(g, sprintf("anchor asset %s is not under %s", pl$anchor[[k]], pl$to_value[[k]]))
    m <- DBI::dbGetQuery(con, "SELECT uuid_project FROM asset WHERE uuid = ?", params = list(pl$id[[k]]))
    if (nrow(m) != 1L || !identical(m$uuid_project[[1]], pl$from_value[[k]])) add(g, sprintf("asset %s not under its source project", pl$id[[k]]))
    h <- DBI::dbGetQuery(con, "SELECT hash FROM asset WHERE uuid = ?", params = list(pl$id[[k]]))$hash
    if (length(h) == 1L && !is.na(h) &&
        .mig083_scalar(con, "SELECT COUNT(*) FROM review_queue WHERE source_hash = ? AND status = 'open'", h) > 0L)
      add(g, sprintf("asset %s has open review items", pl$id[[k]]))
    if (DBI::dbExistsTable(con, "asset_filing") &&
        .mig083_scalar(con, "SELECT COUNT(*) FROM asset_filing WHERE uuid_asset = ?", pl$id[[k]]) > 0L)
      add(g, sprintf("asset %s has a filing record", pl$id[[k]]))
    if (.mig083_scalar(con, "SELECT COUNT(*) FROM lab_qc_report WHERE uuid_asset = ?", pl$id[[k]]) > 0L)
      add(g, sprintf("asset %s backs a lab_qc_report", pl$id[[k]]))
  }
  pr
}

.mig083_skipped_df <- function(pr) {
  if (!length(pr)) return(data.frame(gid = character(), problem = character(), stringsAsFactors = FALSE))
  data.frame(gid = names(pr), problem = vapply(pr, function(p) paste(unique(p), collapse = "; "), ""),
             stringsAsFactors = FALSE)
}

# ---- verify ------------------------------------------------------------------------------

.mig083_done_problem <- function(con, x) {
  if (.mig083_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig083_marker_version) != 1L)
    return("marker 1083 missing")
  pl <- .mig083_planned(x)
  L <- DBI::dbGetQuery(con, "SELECT tbl, action, uuid_row, field, old, new FROM change_log WHERE actor = ?",
                       params = list(.mig083_actor))
  if (nrow(L) != 2L * nrow(pl)) return(sprintf("083 change_log has %d row(s), not %d", nrow(L), 2L * nrow(pl)))
  for (i in seq_len(nrow(pl))) {
    r <- pl[i, , drop = FALSE]
    a <- DBI::dbGetQuery(con, "SELECT uuid_project, comments FROM asset WHERE uuid = ?", params = list(r$id))
    if (nrow(a) != 1L || !identical(a$uuid_project[[1]], r$to_value)) return(sprintf("asset %s is not under %s", r$id, r$to_value))
    lc <- L[L$tbl == "asset" & L$uuid_row %in% r$id & L$field %in% "comments", , drop = FALSE]
    lp <- L[L$tbl == "asset" & L$uuid_row %in% r$id & L$field %in% "uuid_project", , drop = FALSE]
    if (nrow(lc) != 1L || nrow(lp) != 1L) return(sprintf("asset %s change_log rows not as planned", r$id))
    if (!identical(lp$old[[1]], r$from_value) || !identical(lp$new[[1]], r$to_value))
      return(sprintf("asset %s uuid_project change_log old/new not as planned", r$id))
    if (!identical(a$comments[[1]], .mig083_append(lc$old[[1]], .mig083_note)) || !identical(lc$new[[1]], a$comments[[1]]))
      return(sprintf("asset %s comments are not the old text plus the 083 note", r$id))
    o <- DBI::dbGetQuery(con, "SELECT uuid_project FROM asset WHERE uuid = ?", params = list(r$anchor))$uuid_project
    if (!identical(o, r$to_value)) return(sprintf("anchor asset %s is not under %s", r$anchor, r$to_value))
  }
  NULL
}

.mig083_counts <- function(con) {
  tabs <- c("analysis", "sample", "feature", "lab_method", "analyte", "asset", "ingest_file", "ingest_sighting",
            "project", "review_queue", "lab_qc_report", "change_log", "schema_version")
  stats::setNames(lapply(tabs, function(t) .mig083_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
}

.mig083_checksum <- function(con, pl) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  tabs <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  touched <- c("asset", "change_log", "schema_version")
  out <- lapply(setdiff(tabs, touched), function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- setdiff(tabs, touched)
  mv <- pl$id
  out$asset_rest <- q(sprintf("SELECT * FROM asset WHERE uuid NOT IN %s ORDER BY ALL", .mig083_inlist(mv)))
  out$asset_cols <- q(sprintf("SELECT * EXCLUDE (uuid_project, comments) FROM asset WHERE uuid IN %s ORDER BY uuid", .mig083_inlist(mv)))
  out$change_log_rest <- q(sprintf("SELECT * FROM change_log WHERE actor <> '%s' ORDER BY uuid", .mig083_actor))
  out$schema_version_rest <- q(sprintf("SELECT * FROM schema_version WHERE version <> %d ORDER BY ALL", .mig083_marker_version))
  out$indexes <- q("SELECT index_name, sql FROM duckdb_indexes() ORDER BY index_name")
  out$views <- q("SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
  out
}

.mig083_checks_problem <- function(before, after) {
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

.mig083_apply <- function(con, x, recorded_at, logf) {
  pl <- .mig083_planned(x)
  db_transaction(con, function(con) {
    baseline <- db_checks(con, tier = "migration")
    before_all <- db_checks(con, tier = "all")
    sums_before <- .mig083_checksum(con, pl)
    want <- .mig083_counts(con)
    want$change_log <- want$change_log + 2L * nrow(pl)
    want$schema_version <- want$schema_version + 1L
    for (i in seq_len(nrow(pl))) {
      r <- pl[i, , drop = FALSE]
      old <- DBI::dbGetQuery(con, "SELECT comments, hash FROM asset WHERE uuid = ?", params = list(r$id))
      db_update(con, "asset", uuid = r$id,
                changes = list(uuid_project = r$to_value, comments = .mig083_append(old$comments[[1]], .mig083_note)),
                actor = .mig083_actor, reason = sprintf("%s [%s]", .mig083_reason, r$gid), source_hash = old$hash[[1]])
    }
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig083_marker_version, recorded_at))
    pr <- .mig083_done_problem(con, x)
    if (!is.null(pr)) .mig083_fail(paste0("verify failed: ", pr))
    got <- .mig083_counts(con)
    if (!identical(got, want))
      .mig083_fail(sprintf("table counts are not as planned: %s",
                           paste(names(got), unlist(got), unlist(want), sep = ":", collapse = ", ")))
    if (!identical(sums_before, .mig083_checksum(con, pl))) .mig083_fail("something outside the planned rows moved.")
    mig_db_checks_gate(con, baseline)
    after_all <- db_checks(con, tier = "all")
    pr <- .mig083_checks_problem(before_all, after_all)
    if (!is.null(pr)) .mig083_fail(paste0("standing checks: ", pr))
    logf("Moved %d asset(s).", nrow(pl))
    NULL
  })
  invisible(NULL)
}

# ---- backups, files ----------------------------------------------------------------------

mig083_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- if (is.null(.now)) Sys.time() else .now
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig083_name, ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig083_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig083_counts(verify_con)))
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  dest
}

.mig083_write_csv <- function(df, path, key) {
  out <- df
  for (f in names(out)) if (inherits(out[[f]], c("POSIXct", "Date"))) out[[f]] <- .st_changelog_str(out[[f]])
  utils::write.csv(out, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8", colClasses = "character")
  if (nrow(back) != nrow(df) || (nrow(df) && !identical(back[[key]], as.character(out[[key]]))))
    cli::cli_abort("083: CSV {basename(path)} did not round-trip.", class = "sampletidy_error")
}

.mig083_csv <- function(csv_dir, what) file.path(csv_dir, sprintf("%s-%s.csv", .mig083_name, what))

.mig083_read_skipped <- function(csv_dir) {
  f <- .mig083_csv(csv_dir, "SKIPPED")
  if (!file.exists(f)) return(NULL)
  utils::read.csv(f, colClasses = "character", na.strings = "", encoding = "UTF-8")
}

# BACKUP CSVs: the moved asset (before) and the two projects it leaves and joins.
.mig083_write_backups <- function(con, x, csv_dir) {
  pl <- .mig083_planned(x)
  ids <- list(asset = pl$id, project = c(pl$from_value, pl$to_value))
  for (tb in names(ids)) {
    df <- DBI::dbGetQuery(con, sprintf('SELECT * FROM "%s" WHERE "%s" IN %s ORDER BY 1', tb, .mig083_pk[[tb]], .mig083_inlist(ids[[tb]])))
    .mig083_write_csv(df, .mig083_csv(csv_dir, paste0("BACKUP-", tb)), .mig083_pk[[tb]])
  }
}

# ---- run ---------------------------------------------------------------------------------

mig083_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL, input_dir = "dev/migrations") {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir
  x0 <- .mig083_read_inputs(input_dir)

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                                   params = list(.mig083_marker_version)),
                   finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    sk <- .mig083_read_skipped(csv_dir)
    if (is.null(sk)) .mig083_fail(sprintf("marker present but %s is missing: cannot re-verify.", .mig083_csv(csv_dir, "SKIPPED")))
    x <- x0[!x0$gid %in% sk$gid, , drop = FALSE]
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch({
      pr <- .mig083_done_problem(check_con, x)
      if (!is.null(pr)) .mig083_fail(paste0("re-verify: ", pr))
    }, finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("083 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_, restore_command = NA_character_,
                          recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  problems <- tryCatch({
    if (.mig083_scalar(pre_con, "SELECT COUNT(*) FROM change_log WHERE actor = ?", .mig083_actor) > 0L)
      .mig083_fail("change_log already holds 083 rows but the marker is absent; refusing.")
    .mig083_problems(pre_con, x0)
  }, finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  skipped <- .mig083_skipped_df(problems)
  x <- x0[!x0$gid %in% skipped$gid, , drop = FALSE]
  pl <- .mig083_planned(x)
  logf("Plan: %d group(s) of %d; %d skipped.", length(unique(x$gid)), length(unique(x0$gid)), nrow(skipped))
  for (i in seq_len(nrow(pl))) logf("  %s %s %s %s: %s -> %s", pl$gid[[i]], pl$op[[i]], pl$tbl[[i]], pl$label[[i]],
                                    pl$from_value[[i]], pl$to_value[[i]])
  for (i in seq_len(nrow(skipped))) logf("SKIP %s: %s", skipped$gid[[i]], skipped$problem[[i]])
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition checked. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_, restore_command = NA_character_, recorded_at = NA)))
  }
  if (!nrow(pl)) .mig083_fail("every group is skipped; nothing to do (no marker written).")

  bk_con <- st_connect(db, read_only = TRUE)
  tryCatch({
    .mig083_write_backups(bk_con, x, csv_dir)
    .mig083_write_csv(skipped, .mig083_csv(csv_dir, "SKIPPED"), "gid")
  }, finally = DBI::dbDisconnect(bk_con, shutdown = TRUE))
  logf("Row backups and the SKIPPED plan written to %s", csv_dir)
  backup_path <- mig083_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- if (is.null(.now)) Sys.time() else .now

  with_db_write(function(con) {
    again <- .mig083_problems(con, x)
    if (length(again)) .mig083_fail("a precondition changed since the dry check; re-run.")
    .mig083_apply(con, x, recorded_at, logf)
  }, db = db)

  logf("%s migrated successfully (marker %d).", .mig083_name, .mig083_marker_version)
  invisible(list(status = "migrated", backup_path = backup_path, restore_command = restore_command,
                 recorded_at = recorded_at))
}
