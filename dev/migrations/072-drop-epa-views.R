# Operator-run migration: drop the three EPA views from the database.
# Marker 1072. Requires 1071.
#
# Authority: Robin, 2026-10-22: "remove the EPA views from sampleTidy". The NSW EPA
# annual return moved to the private deployment repo (bmcc-monitoring/epa/), which
# queries the base tables, not views (commit 4998ada). Nothing in R/ creates or reads a
# view; no other view references the three.
#
# ---- WHAT -----------------------------------------------------------------------
#   DROP VIEW v_analyte_epa, v_feature_epa, v_measurement_epa.
#   Each one's stored SQL (duckdb_views().sql) is frozen below by sha1; a definition
#   that differs from the freeze refuses the run.
#
# ---- NOT DONE ---------------------------------------------------------------------
#   The feature_mask / analyte_mask rows with variant = 'EPA' STAY: R/flags.R and
#   R/qc.R read them. The siblings v_*_gas_report, v_*_long, v_*_old, v_measurement
#   and v_feature_dates stay, unchanged. No change_log rows: view DDL is not logged
#   (as 004, 005, 022, 070).
#   Already-applied migrations whose ALREADY-MIGRATED re-verify names
#   v_measurement_epa (022 `.mig022_views`, 070 `.mig070_views`) will report "a view
#   is missing" if re-run after 072. Those re-runs are spent; they are not edited.
#
# ---- CHECKS -------------------------------------------------------------------------
#   Before: marker 1071 present, 1072 absent; each of the three views exists and the
#   sha1 of its stored SQL equals the frozen value; no OTHER view's SQL names any of
#   the three (word-bounded, case-insensitive).
#   After (same transaction): the three views are gone; every other view's stored SQL
#   is byte for byte unchanged and each still answers SELECT count(*) with the same
#   count as before; every base table except schema_version checksummed unchanged
#   (schema_version outside the 1072 row); counts as planned (+1 schema_version, no
#   change_log); marker 1072 present.
#
# One transaction: the three DROP VIEWs, the marker, the verify. Backups: verified
# whole-file snapshot, BACKUP CSV of the three view definitions (view_name, sql),
# written before anything is dropped. Idempotent: marker present -> re-verify, no-op.
#
#   devtools::load_all(".")
#   env <- new.env(); sys.source("dev/migrations/072-drop-epa-views.R", envir = env)
#   env$mig072_run(db = <db>, snapshot_dir = <dir>, dry_run = TRUE)

.mig072_marker_version <- 1072L
.mig072_requires <- 1071L
.mig072_name <- "072-drop-epa-views"
.mig072_actor <- .mig072_name

# sha1 (digest, serialize = FALSE) of each view's duckdb_views().sql, frozen from the
# live DB (read-only) on 2026-10-22 at marker 1071.
.mig072_views <- c(
  v_analyte_epa     = "4641b6b2eaa46d827bfcd0fda38baf2e9c26ce0a",
  v_feature_epa     = "de91785b5e8ae6519a1faadf89a71bd926b820db",
  v_measurement_epa = "278257574c5025c769635772addb793ed505e78f"
)

.mig072_fail <- function(msg) cli::cli_abort(paste0(.mig072_name, ": ", msg), class = "sampletidy_error")
.mig072_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = if (length(list(...))) list(...) else NULL)[[1]][[1]])
.mig072_sha <- function(x) vapply(x, digest::digest, "", algo = "sha1", serialize = FALSE, USE.NAMES = FALSE)

# The views use timezone(); DuckDB needs ICU to bind them.
.mig072_ensure_icu <- function(con) {
  DBI::dbExecute(con, "INSTALL icu")
  DBI::dbExecute(con, "LOAD icu")
  invisible(NULL)
}

.mig072_view_defs <- function(con) {
  DBI::dbGetQuery(con, "SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
}

# TRUE where `sql` names view `v` as a whole identifier.
.mig072_mentions <- function(sql, v) {
  grepl(sprintf("(?i)(?<![A-Za-z0-9_])%s(?![A-Za-z0-9_])", v), sql, perl = TRUE)
}

# ---- preconditions -----------------------------------------------------------------

# Returns the three definitions (view_name, sql) in .mig072_views order.
.mig072_check_preconditions <- function(con) {
  fail <- .mig072_fail
  have <- DBI::dbGetQuery(con, "SELECT version FROM schema_version")$version
  miss <- setdiff(.mig072_requires, have)
  if (length(miss)) fail(sprintf("marker(s) %s required first.", paste(miss, collapse = ", ")))
  if (.mig072_marker_version %in% have) fail("marker 1072 already present.")
  defs <- .mig072_view_defs(con)
  want <- names(.mig072_views)
  absent <- setdiff(want, defs$view_name)
  if (length(absent)) fail(sprintf("view(s) %s do not exist.", paste(absent, collapse = ", ")))
  mine <- defs[match(want, defs$view_name), , drop = FALSE]
  rownames(mine) <- NULL
  got <- .mig072_sha(mine$sql)
  bad <- want[got != unname(.mig072_views)]
  if (length(bad)) fail(sprintf("view(s) %s not as frozen (sha1 %s): re-freeze.",
                                paste(bad, collapse = ", "), paste(got[got != unname(.mig072_views)], collapse = ", ")))
  others <- defs[!(defs$view_name %in% want), , drop = FALSE]
  for (v in want) {
    by <- others$view_name[.mig072_mentions(others$sql, v)]
    if (length(by)) fail(sprintf("view %s is referenced by %s.", v, paste(by, collapse = ", ")))
  }
  mine
}

# ---- verify ---------------------------------------------------------------------------

.mig072_done_problem <- function(con) {
  if (.mig072_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig072_marker_version) != 1L)
    return("marker 1072 missing")
  left <- intersect(names(.mig072_views), .mig072_view_defs(con)$view_name)
  if (length(left)) return(sprintf("view(s) %s still exist", paste(left, collapse = ", ")))
  n <- .mig072_scalar(con, "SELECT COUNT(*) FROM duckdb_tables() WHERE lower(table_name) IN ('v_analyte_epa', 'v_feature_epa', 'v_measurement_epa')")
  if (n != 0L) return("a table now carries an EPA view's name")
  NULL
}

.mig072_verify <- function(con) {
  pr <- .mig072_done_problem(con)
  if (!is.null(pr)) cli::cli_abort(paste0("072 verify failed: ", pr), class = "sampletidy_error")
  invisible(TRUE)
}

# ---- counts, checksums ------------------------------------------------------------------

.mig072_counts <- function(con) {
  tabs <- c("analysis", "sample", "feature", "feature_alias", "feature_mask", "analyte_mask", "lab_method",
            "analyte", "project", "change_log", "schema_version")
  tabs <- intersect(tabs, DBI::dbListTables(con))
  stats::setNames(lapply(tabs, function(t) .mig072_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
}

# Every base table except schema_version whole; schema_version outside 1072; indexes.
.mig072_checksum <- function(con) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  tabs <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  rest <- setdiff(tabs, "schema_version")
  out <- lapply(rest, function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- rest
  out$schema_version_rest <- q(sprintf("SELECT * FROM schema_version WHERE version <> %d ORDER BY ALL", .mig072_marker_version))
  out$indexes <- q("SELECT index_name, sql FROM duckdb_indexes() ORDER BY index_name")
  out
}

# The views that stay: name, sha1 of stored SQL, SELECT count(*).
.mig072_other_views <- function(con) {
  d <- .mig072_view_defs(con)
  d <- d[!(d$view_name %in% names(.mig072_views)), , drop = FALSE]
  n <- vapply(d$view_name, function(v) .mig072_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', v)), 0L)
  data.frame(view_name = d$view_name, sha1 = .mig072_sha(d$sql), n = unname(n), stringsAsFactors = FALSE)
}

# ---- apply ---------------------------------------------------------------------------------

.mig072_apply <- function(con, defs, recorded_at, logf) {
  sums_before <- .mig072_checksum(con)
  counts_want <- .mig072_counts(con)
  counts_want$schema_version <- counts_want$schema_version + 1L
  others_before <- .mig072_other_views(con)
  db_transaction(con, function(con) {
    for (v in defs$view_name) DBI::dbExecute(con, sprintf('DROP VIEW "%s"', v))
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig072_marker_version, recorded_at))
    .mig072_verify(con)
    others_after <- .mig072_other_views(con)
    if (!identical(others_before, others_after))
      .mig072_fail("a remaining view's definition or row count changed.")
    if (!identical(.mig072_counts(con), counts_want)) .mig072_fail("table counts are not as planned.")
    if (!identical(sums_before, .mig072_checksum(con))) .mig072_fail("a base table moved.")
    logf("Dropped %s; %d other views unchanged and queryable.", paste(defs$view_name, collapse = ", "), nrow(others_after))
    NULL
  })
  invisible(TRUE)
}

# ---- backups, files ------------------------------------------------------------------------

mig072_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- if (is.null(.now)) Sys.time() else .now
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig072_name, ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig072_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig072_counts(verify_con)))
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  dest
}

.mig072_write_csv <- function(df, path, key) {
  utils::write.csv(df, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8", colClasses = "character")
  if (nrow(back) != nrow(df) || (nrow(df) && !identical(back[[key]], as.character(df[[key]]))) ||
      !identical(.mig072_sha(back$sql), .mig072_sha(df$sql)))
    cli::cli_abort("072: CSV {basename(path)} did not round-trip.", class = "sampletidy_error")
}

.mig072_csv <- function(csv_dir, what) file.path(csv_dir, sprintf("%s-%s.csv", .mig072_name, what))

# ---- run ----------------------------------------------------------------------------------

mig072_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                                   params = list(.mig072_marker_version)),
                   finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch(.mig072_verify(check_con), finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("072 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  defs <- tryCatch({
    .mig072_ensure_icu(pre_con)
    .mig072_check_preconditions(pre_con)
  }, finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  logf("Plan: drop %d views (%s); every frozen definition matches; no other view references them.",
       nrow(defs), paste(defs$view_name, collapse = ", "))
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition passed. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_, restore_command = NA_character_, recorded_at = NA)))
  }

  .mig072_write_csv(defs, .mig072_csv(csv_dir, "BACKUP-views"), "view_name")
  logf("View-definition backup written to %s", .mig072_csv(csv_dir, "BACKUP-views"))
  backup_path <- mig072_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- if (is.null(.now)) Sys.time() else .now

  with_db_write(function(con) {
    .mig072_ensure_icu(con)
    again <- .mig072_check_preconditions(con)
    if (!identical(again$sql, defs$sql)) .mig072_fail("view definitions changed since the dry check; re-run.")
    .mig072_apply(con, again, recorded_at, logf)
  }, db = db)

  logf("%s migrated successfully (marker %d).", .mig072_name, .mig072_marker_version)
  invisible(list(status = "migrated", backup_path = backup_path, restore_command = restore_command,
                 recorded_at = recorded_at))
}
