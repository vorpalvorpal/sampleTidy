# Operator-run migration: parse the archived ALS QC reports into lab_qc_report /
# lab_qc_outlier (PLAN-19 R-19.17, section 8). Marker 1052. Requires 1050.
#
# Authority: Robin, 2026-10-19 (PLAN-19 R19-5 "ALS lab QC is parsed now, not
# deferred"; section 8, migration 052).
#
# ---- WHAT ----------------------------------------------------------------------
# Runs the package's own lab-QC parse step (lab_qc_ingest(), via
# .lab_qc_backfill_con(), the body of lab_qc_backfill()) over every `asset` of
# type 'QC' (the retained _QCI.pdf and _QC.pdf siblings) whose archived copy
# `<archive_dir>/<asset uuid>/<filename>` exists and that has no lab_qc_report
# row at the current parser version:
#   * _QCI -> the QCI parser: one lab_qc_report row (status parsed, or partial
#     with the parser's warnings), and its outlier rows linked to our samples
#     (R-19.21: sample_lab_id, then work order + client ID);
#   * _QC  -> one lab_qc_report row, status partial, "QC.pdf not parsed yet"
#     (phase 3), or unreadable when poppler cannot open it;
#   * a PDF that cannot be read -> status unreadable with the message.
# Inserts only, through db_append() (one change_log row per inserted row,
# actor "052-lab-qc-backfill", source_hash = the asset's hash). No row is
# updated or deleted: a report already at the current parser version is left
# alone, and a report at any other version is a precondition failure.
#
# Reads the archived PDFs. On OneDrive Files-On-Demand that hydrates them
# (222 QC assets, ~50 MB, once).
#
# ---- PRECONDITIONS (any failure aborts; nothing is written) ---------------------
#   * marker 1050 present; 1052 absent;
#   * lab_qc_report and lab_qc_outlier exist (048); no lab_qc_report row at a
#     parser version other than the current one; no orphan lab_qc_outlier;
#   * archive_dir exists.
#
# Writes, in ONE transaction: the report and outlier inserts, their change_log
# rows, the marker. Every other table (and change_log outside this actor, and
# lab_qc_report/lab_qc_outlier rows already present) is checksummed before and
# after. Backup: a verified whole-file snapshot in `snapshot_dir`. No row
# backups (no existing row is touched).
#
# After: every QC asset with an archived copy has exactly one current report;
# counts by kind/status, outliers by kind and linked outliers are logged, for
# comparison with PLAN-19 Appendix A (which measured the whole corpus, not only
# the assets live archived).
#
# Idempotent: marker present -> re-verify, no-op.
#
#   devtools::load_all(".")
#   env <- new.env()
#   sys.source("dev/migrations/052-lab-qc-backfill.R", envir = env)
#   env$mig052_run(db = st_config("live_db"),
#                  snapshot_dir = st_config("snapshot_dir"), dry_run = TRUE)

.mig052_marker_version <- 1052L
.mig052_requires <- 1050L
.mig052_name <- "052-lab-qc-backfill"
.mig052_actor <- .mig052_name

.mig052_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = list(...))[[1]][[1]])
.mig052_fail <- function(msg) cli::cli_abort(paste0(.mig052_name, ": ", msg), class = "sampletidy_error")

.mig052_tables <- function(con) {
  DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
}

.mig052_counts <- function(con) {
  tabs <- .mig052_tables(con)
  stats::setNames(lapply(tabs, function(t) .mig052_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
}

# The QC assets and whether each has an archived copy and a current report.
.mig052_assets <- function(con, archive_dir) {
  a <- DBI::dbGetQuery(con, "
    SELECT a.uuid, a.filename, r.parser_version
      FROM asset a LEFT JOIN lab_qc_report r ON r.uuid_asset = a.uuid
     WHERE a.type = 'QC' ORDER BY a.filename, a.uuid")
  a$kind <- vapply(a$filename, function(f) if (is.na(f)) NA_character_ else .lab_qc_kind(f), "")
  a$archived <- !is.na(a$filename) & file.exists(file.path(archive_dir, a$uuid, a$filename))
  a$current <- a$parser_version %in% .qci_parser_version
  a
}

.mig052_plan <- function(con, archive_dir) {
  probs <- character(0)
  tabs <- .mig052_tables(con)
  for (t in c("lab_qc_report", "lab_qc_outlier", "asset"))
    if (!t %in% tabs) probs <- c(probs, sprintf("table %s does not exist (apply 048)", t))
  if (!dir.exists(archive_dir)) probs <- c(probs, sprintf("archive_dir %s does not exist", archive_dir))
  if (length(probs)) return(list(problems = probs))
  stale <- .mig052_scalar(con, "SELECT COUNT(*) FROM lab_qc_report WHERE parser_version IS DISTINCT FROM ?",
                          .qci_parser_version)
  if (stale) probs <- c(probs, sprintf("%d lab_qc_report row(s) at a parser version other than %s", stale,
                                       .qci_parser_version))
  orphan <- .mig052_scalar(con, "SELECT COUNT(*) FROM lab_qc_outlier o
                                  WHERE NOT EXISTS (SELECT 1 FROM lab_qc_report r WHERE r.uuid = o.uuid_report)")
  if (orphan) probs <- c(probs, sprintf("%d lab_qc_outlier row(s) with no report", orphan))
  a <- .mig052_assets(con, archive_dir)
  if (anyNA(a$kind)) probs <- c(probs, sprintf("%d QC asset(s) whose filename is neither _QCI nor _QC", sum(is.na(a$kind))))
  list(problems = probs, assets = a, todo = a[a$archived & !a$current, , drop = FALSE])
}

.mig052_check_preconditions <- function(con, archive_dir) {
  if (.mig052_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig052_requires) == 0L)
    .mig052_fail(sprintf("marker %d (050) is required first.", .mig052_requires))
  p <- .mig052_plan(con, archive_dir)
  if (length(p$problems)) .mig052_fail(sprintf("%s. Nothing written.", paste(p$problems, collapse = " | ")))
  p
}

# Everything but this migration's own inserts.
.mig052_checksum <- function(con, keep_reports) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  inl <- function(x) if (length(x)) paste0("('", paste(x, collapse = "','"), "')") else "(NULL)"
  touched <- c("lab_qc_report", "lab_qc_outlier", "change_log", "schema_version")
  tabs <- setdiff(.mig052_tables(con), touched)
  out <- lapply(tabs, function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- tabs
  out$lab_qc_report_rest <- q(sprintf("SELECT * FROM lab_qc_report WHERE uuid IN %s ORDER BY uuid", inl(keep_reports)))
  out$lab_qc_outlier_rest <- q(sprintf("SELECT * FROM lab_qc_outlier WHERE uuid_report IN %s ORDER BY uuid",
                                       inl(keep_reports)))
  out$change_log_rest <- q(sprintf("SELECT * FROM change_log WHERE actor <> '%s' ORDER BY ALL", .mig052_actor))
  out$schema_version_rest <- q(sprintf("SELECT * FROM schema_version WHERE version <> %d ORDER BY ALL",
                                       .mig052_marker_version))
  out$views <- q("SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
  out
}

# Counts for the log and the MIGRATIONS.md row.
.mig052_summary <- function(con) {
  list(
    reports = DBI::dbGetQuery(con, "SELECT kind, status, COUNT(*) AS n FROM lab_qc_report
                                     GROUP BY ALL ORDER BY ALL"),
    outliers = DBI::dbGetQuery(con, "SELECT kind, COUNT(*) AS n, COUNT(uuid_sample) AS linked,
                                            COUNT(DISTINCT work_order) AS work_orders
                                       FROM lab_qc_outlier GROUP BY ALL ORDER BY ALL"),
    summary_true = DBI::dbGetQuery(con, "
      SELECT k AS bullet, SUM(CASE WHEN json_extract(summary, '$.' || k)::BOOLEAN THEN 1 ELSE 0 END) AS n_true,
             COUNT(*) AS n
        FROM lab_qc_report, (VALUES ('mb'), ('dup'), ('lcs'), ('ms'), ('surrogate'),
                                    ('holding_time'), ('frequency')) v(k)
       WHERE kind = 'QCI' AND status IN ('parsed', 'partial') GROUP BY ALL ORDER BY ALL"),
    partial = DBI::dbGetQuery(con, "SELECT work_order, kind, status, message FROM lab_qc_report
                                     WHERE status <> 'parsed' AND kind = 'QCI' ORDER BY work_order"))
}

.mig052_done_problem <- function(con, archive_dir) {
  if (.mig052_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig052_marker_version) != 1L)
    return("marker 1052 missing")
  a <- .mig052_assets(con, archive_dir)
  miss <- a[a$archived & !a$current, , drop = FALSE]
  if (nrow(miss)) return(sprintf("%d archived QC asset(s) have no current report", nrow(miss)))
  dup <- .mig052_scalar(con, "SELECT COUNT(*) FROM (SELECT uuid_asset FROM lab_qc_report GROUP BY 1 HAVING COUNT(*) > 1)")
  if (dup) return(sprintf("%d asset(s) with more than one report", dup))
  orphan <- .mig052_scalar(con, "SELECT COUNT(*) FROM lab_qc_outlier o
                                  WHERE NOT EXISTS (SELECT 1 FROM lab_qc_report r WHERE r.uuid = o.uuid_report)")
  if (orphan) return(sprintf("%d lab_qc_outlier row(s) with no report", orphan))
  badk <- .mig052_scalar(con, "SELECT COUNT(*) FROM lab_qc_report r JOIN asset a ON a.uuid = r.uuid_asset
                                WHERE (r.kind = 'QCI') <> regexp_matches(a.filename, '(?i)_QCI(\\[[0-9]+\\])?\\.[a-z0-9]+$')")
  if (badk) return(sprintf("%d report(s) whose kind disagrees with the filename", badk))
  badl <- .mig052_scalar(con, "SELECT COUNT(*) FROM lab_qc_outlier o WHERE uuid_sample IS NOT NULL
                                AND NOT EXISTS (SELECT 1 FROM \"sample\" s WHERE s.uuid = o.uuid_sample)")
  if (badl) return(sprintf("%d outlier(s) linked to a sample that does not exist", badl))
  NULL
}

.mig052_verify <- function(con, archive_dir) {
  p <- .mig052_done_problem(con, archive_dir)
  if (!is.null(p)) cli::cli_abort(paste0("052 verify failed: ", p), class = "sampletidy_error")
  invisible(TRUE)
}

mig052_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- if (is.null(.now)) Sys.time() else .now
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig052_name, ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig052_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig052_counts(verify_con)))
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  dest
}

.mig052_apply <- function(con, p, archive_dir, recorded_at) {
  keep <- DBI::dbGetQuery(con, "SELECT uuid FROM lab_qc_report")$uuid
  sums_before <- .mig052_checksum(con, keep)
  before <- .mig052_counts(con)
  db_transaction(con, function(con) {
    res <- .lab_qc_backfill_con(con, actor = .mig052_actor, archive_dir = archive_dir)
    done <- res[res$result %in% c("parsed", "partial", "unreadable"), , drop = FALSE]
    if (nrow(done) != nrow(p$todo) || !setequal(done$uuid_asset, p$todo$uuid))
      .mig052_fail(sprintf("parsed %d asset(s), planned %d.", nrow(done), nrow(p$todo)))
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig052_marker_version, recorded_at))
    .mig052_verify(con, archive_dir)
    got <- .mig052_counts(con)
    n_rep <- got$lab_qc_report - before$lab_qc_report
    n_out <- got$lab_qc_outlier - before$lab_qc_outlier
    n_log <- .mig052_scalar(con, "SELECT COUNT(*) FROM change_log WHERE actor = ?", .mig052_actor)
    if (n_rep != nrow(p$todo)) .mig052_fail(sprintf("%d reports inserted, planned %d.", n_rep, nrow(p$todo)))
    if (n_log != n_rep + n_out) .mig052_fail(sprintf("%d change_log rows for %d inserts.", n_log, n_rep + n_out))
    want <- before
    want$lab_qc_report <- got$lab_qc_report
    want$lab_qc_outlier <- got$lab_qc_outlier
    want$change_log <- before$change_log + n_log
    want$schema_version <- before$schema_version + 1L
    if (!identical(got, want))
      .mig052_fail(sprintf("counts are not as planned: %s",
                           paste(names(got), unlist(got), unlist(want[names(got)]), sep = ":", collapse = ", ")))
    if (!identical(sums_before, .mig052_checksum(con, keep)))
      .mig052_fail("something outside the planned inserts moved.")
    NULL
  })
  invisible(NULL)
}

.mig052_log_summary <- function(con, logf) {
  s <- .mig052_summary(con)
  logf("lab_qc_report: %s", paste(sprintf("%s/%s %d", s$reports$kind, s$reports$status, s$reports$n), collapse = ", "))
  logf("lab_qc_outlier: %s", paste(sprintf("%s %d (%d linked, %d WOs)", s$outliers$kind, s$outliers$n,
                                           s$outliers$linked, s$outliers$work_orders), collapse = ", "))
  logf("QCI Summary bullets TRUE: %s", paste(sprintf("%s %d/%d", s$summary_true$bullet, s$summary_true$n_true,
                                                    s$summary_true$n), collapse = ", "))
  for (i in seq_len(nrow(s$partial))) {
    logf("  QCI %s %s: %s", s$partial$work_order[[i]], s$partial$status[[i]], s$partial$message[[i]])
  }
  invisible(s)
}

mig052_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, archive_dir = st_config("archive_dir")) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(
    DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                    params = list(.mig052_marker_version)),
    finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch({
      .mig052_verify(check_con, archive_dir)
      .mig052_log_summary(check_con, logf)
    }, finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("052 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  p <- tryCatch(.mig052_check_preconditions(pre_con, archive_dir),
                finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  a <- p$assets
  logf("QC assets: %d (%d QCI, %d QC); archived copy present: %d; already current: %d.",
       nrow(a), sum(a$kind %in% "QCI"), sum(a$kind %in% "QC"), sum(a$archived), sum(a$current))
  logf("Will parse %d asset(s) (%d QCI, %d QC) from %s; %d without an archived copy are skipped.",
       nrow(p$todo), sum(p$todo$kind %in% "QCI"), sum(p$todo$kind %in% "QC"), archive_dir,
       sum(!a$archived & !a$current))
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition passed. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_, restore_command = NA_character_,
                          recorded_at = NA)))
  }

  backup_path <- mig052_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- if (is.null(.now)) Sys.time() else .now

  with_db_write(function(con) {
    p2 <- .mig052_check_preconditions(con, archive_dir)   # re-read under the write lock
    .mig052_apply(con, p2, archive_dir, recorded_at)
    .mig052_log_summary(con, logf)
  }, db = db)

  logf("%s migrated successfully (marker %d): %d QC asset(s) parsed.", .mig052_name,
       .mig052_marker_version, nrow(p$todo))
  invisible(list(status = "migrated", backup_path = backup_path,
                 restore_command = restore_command, recorded_at = recorded_at))
}
