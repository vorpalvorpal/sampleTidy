# Operator-run migration: reset ONE ingest_file row so the next ingest
# re-routes it - the ALS XTAB of work order ES2623357 (Blaxland, July 2026),
# ES2623357_0_XTAB.XLS, hash b27ec761bfac521faf6dffa8012048c6. Marker 1040.
# Requires 1039. Authority: Robin's ruling 2026-10-18 - narrow the re-ingest
# guard so retained siblings do not count as prior-ingest evidence, then
# re-import this XTAB (171 ALS rows, 9 samples).
#
# ---- WHY -------------------------------------------------------------------------
# The 2026-10-17 email import routed this XTAB as a retained sibling of the
# ACIRL workbook in the same folder: it was archived (asset b56e3eea, under
# ES2623357) and its ingest_file row closed as archived / retained_sibling,
# with no ALS data committed. `archived` is terminal, so the router returns the
# stored verdict on every later sight (R-3.7/R-3.8 only re-decide router
# verdicts - quarantined / router-failed - and this is neither). Without a
# reset, re-dropping the file is a silent no-op.
#
# ---- HOW (the package's own reset, not a hand-rolled one) -------------------------
# ingest_file_set_state(con, hash, "seen", reason = NA, reset = TRUE) - exactly
# the call .st_route_one_file() makes when it re-decides a verdict (router.R,
# `reconsidering`). `seen` is the state the router treats as fresh
# (`already_routed` is FALSE only for `seen`), and reset = TRUE is the
# documented override for a terminal state. It writes state, state_reason and
# updated_at only; adapter / tier / work_order / revision / org / uuid_asset /
# registry_fingerprint are left as they are, as the router's own reset leaves
# them (all but the fingerprint are NULL on this row anyway). Proved on a copy
# by the xtabdiag repro (scratchpad xtabdiag/scripts/repro.R, guardfix.R).
#
# The asset row is NOT deleted: archive_file() dedupes on hash, so the re-import
# reuses asset b56e3eea. ingest_sighting is not touched.
#
# change_log: ingest_file_set_state() writes none (ops-table helper), so 040
# writes the two field changes itself, shaped as the existing ingest_file
# change_log rows (tbl ingest_file, action update, uuid_row NULL - the table is
# keyed on hash, not uuid): state archived -> seen, state_reason
# retained_sibling -> NULL. source_hash = the XTAB's hash.
#
# Preconditions: marker 1039; the row exists exactly as described (filename,
# state archived, state_reason retained_sibling, adapter/tier/work_order/
# uuid_asset NULL); exactly one asset of that hash, b56e3eea, under project
# ES2623357 (a Work order); and NO non-ACIRL sample under ES2623357 (the ALS
# data has not arrived by some other route - only the 13 ACIRL samples).
#
# Writes: one transaction (1 ingest_file update, 2 change_log rows, marker
# 1040), counts and checksums of everything else checked inside it. BACKUP CSV
# of the row before: 040-reset-es2623357-xtab-BACKUP-ingest_file.csv. Plus the
# verified whole-file backup in snapshot_dir.
#
# Idempotent: marker present -> re-verify, no-op. The row is expected to MOVE
# after 040: once the guard change lands, the next ingest imports the XTAB and
# closes the row as archived / "commit_event: ES2623357". The re-verify
# accepts seen / NULL (not yet re-ingested), archived / commit_event
# (re-imported), or needs_review / commit_event (re-ingested, held for review:
# what an ingest BEFORE the guard change produces - the work_order_reingest
# guard blocks all 171 rows; the router will not re-decide a needs_review row,
# so that case is finished by resolving the review item, not by re-dropping
# the file), and says which. Anything else is reported as a failure.
#
#   devtools::load_all(".")
#   env <- new.env()
#   sys.source("dev/migrations/040-reset-es2623357-xtab.R", envir = env)
#   env$mig040_run(db = st_config("live_db"),
#                  snapshot_dir = st_config("snapshot_dir"), dry_run = TRUE)

.mig040_marker_version <- 1040L
.mig040_requires <- 1039L
.mig040_name <- "040-reset-es2623357-xtab"
.mig040_actor <- .mig040_name

.mig040_hash <- "b27ec761bfac521faf6dffa8012048c6"
.mig040_filename <- "ES2623357_0_XTAB.XLS"
.mig040_asset <- "b56e3eea-7842-423d-b23a-9cac48395658"
.mig040_proj <- list(uuid = "2a398160-1ca5-48ab-b8a8-c515f3749ccf", name = "ES2623357")
.mig040_old <- list(state = "archived", state_reason = "retained_sibling")
.mig040_new <- list(state = "seen", state_reason = NA_character_)
.mig040_reason <- paste0(
  "040 (Robin, 2026-10-18: narrow the re-ingest guard; re-import ES2623357 XTAB): reset the ES2623357 ALS XTAB ",
  "from archived/retained_sibling to seen (ingest_file_set_state reset = TRUE) so the next ingest re-routes it")

.mig040_default <- function(x, default) if (is.null(x)) default else x
.mig040_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = list(...))[[1]][[1]])
.mig040_fail <- function(msg) cli::cli_abort(paste0(.mig040_name, ": ", msg), class = "sampletidy_error")

.mig040_counts <- function(con) {
  tabs <- c("feature", "feature_alias", "analyte", "lab_method", "analysis", "sample", "project", "asset",
            "review_queue", "review_queue_candidate", "ingest_file", "ingest_sighting", "change_log", "schema_version")
  stats::setNames(lapply(tabs, function(t) .mig040_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
}

.mig040_row <- function(con) DBI::dbGetQuery(con, "SELECT * FROM ingest_file WHERE hash = ?", params = list(.mig040_hash))

# commit_event()'s state_reason for this work order (R/commit.R: paste0("commit_event: ", work_order)).
.mig040_commit_reason <- "commit_event: ES2623357"

# The states the row may legitimately be in after 040, by what has happened since:
# "reset" (no ingest yet), "held" (re-ingested, every row held for review - e.g. the
# work_order_reingest guard blocked it; resolving the review item completes it, but
# the router will NOT re-decide a needs_review row on a later sight), "imported".
.mig040_later_state <- function(r) {
  if (identical(r$state, "seen") && is.na(r$state_reason)) return("reset")
  if (identical(r$state, "needs_review") && identical(r$state_reason, .mig040_commit_reason)) return("held")
  if (identical(r$state, "archived") && identical(r$state_reason, .mig040_commit_reason)) return("imported")
  NULL
}

.mig040_eq <- function(x, y) (is.na(x) && is.na(y)) || (!is.na(x) && !is.na(y) && identical(x, y))

# The identity of the row and its asset - must hold before AND after 040.
.mig040_identity_problem <- function(con) {
  r <- .mig040_row(con)
  if (nrow(r) != 1L) return(sprintf("%d ingest_file rows for hash %s, expected 1", nrow(r), .mig040_hash))
  if (!identical(r$filename, .mig040_filename)) return(sprintf("the row's filename is %s, not %s", r$filename, .mig040_filename))
  p <- DBI::dbGetQuery(con, "SELECT name, type FROM project WHERE uuid = ?", params = list(.mig040_proj$uuid))
  if (nrow(p) != 1L || !identical(p$name, .mig040_proj$name) || !identical(p$type, "Work order"))
    return("project ES2623357 is missing or not a Work order")
  as <- DBI::dbGetQuery(con, "SELECT uuid, uuid_project, filename FROM asset WHERE hash = ?", params = list(.mig040_hash))
  if (nrow(as) != 1L || !identical(as$uuid, .mig040_asset) || !identical(as$uuid_project, .mig040_proj$uuid) ||
      !identical(as$filename, .mig040_filename))
    return(sprintf("expected exactly one asset of the XTAB's hash (%s, under ES2623357); found %d", .mig040_asset, nrow(as)))
  NULL
}

.mig040_n_non_acirl <- function(con) {
  .mig040_scalar(con, "SELECT COUNT(*) FROM \"sample\" WHERE uuid_project = ? AND COALESCE(organisation, '') <> 'ACIRL'",
                 .mig040_proj$uuid)
}

.mig040_check_preconditions <- function(con) {
  if (.mig040_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig040_requires) == 0L)
    .mig040_fail(sprintf("marker %d (039) is required first.", .mig040_requires))
  p <- .mig040_identity_problem(con)
  if (!is.null(p)) .mig040_fail(sprintf("%s. Nothing written.", p))
  r <- .mig040_row(con)
  if (!identical(r$state, .mig040_old$state) || !.mig040_eq(r$state_reason, .mig040_old$state_reason))
    .mig040_fail(sprintf("the row is %s / %s, expected archived / retained_sibling. Nothing written.", r$state, r$state_reason))
  if (!is.na(r$adapter) || !is.na(r$tier) || !is.na(r$work_order) || !is.na(r$uuid_asset))
    .mig040_fail("the row carries an adapter / tier / work_order / uuid_asset this migration did not plan for. Nothing written.")
  n <- .mig040_n_non_acirl(con)
  if (n != 0L)
    .mig040_fail(sprintf("%d non-ACIRL sample(s) already exist under ES2623357 - the ALS data has arrived some other way. Nothing written.", n))
  invisible(TRUE)
}

.mig040_done_problem <- function(con) {
  if (.mig040_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig040_marker_version) != 1L) return("marker 1040 missing")
  p <- .mig040_identity_problem(con)
  if (!is.null(p)) return(p)
  r <- .mig040_row(con)
  if (is.null(.mig040_later_state(r)))
    return(sprintf(paste0("the row is now %s / %s - not seen (reset, not yet re-ingested), needs_review / %s (re-ingested, ",
                          "held for review) or archived / %s (re-imported): a later ingest moved it somewhere 040 did not plan for"),
                   r$state, r$state_reason, .mig040_commit_reason, .mig040_commit_reason))
  cl <- DBI::dbGetQuery(con, "SELECT tbl, action, uuid_row, field, old, new, source_hash FROM change_log WHERE actor = ? ORDER BY field",
                        params = list(.mig040_actor))
  ok <- nrow(cl) == 2L && all(cl$tbl == "ingest_file") && all(cl$action == "update") && all(is.na(cl$uuid_row)) &&
    all(cl$source_hash == .mig040_hash) && identical(cl$field, c("state", "state_reason")) &&
    identical(cl$old, c("archived", "retained_sibling")) && identical(cl$new[[1]], "seen") && is.na(cl$new[[2]])
  if (!ok) return(sprintf("040 change_log is %d row(s), expected the 2 planned ingest_file updates", nrow(cl)))
  NULL
}

.mig040_verify <- function(con) {
  p <- .mig040_done_problem(con)
  if (!is.null(p)) cli::cli_abort(paste0("040 verify failed: ", p), class = "sampletidy_error")
  invisible(TRUE)
}

mig040_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- .mig040_default(.now, Sys.time())
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig040_name, ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig040_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig040_counts(verify_con)))
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  dest
}

.mig040_write_csv <- function(df, path) {
  out <- df
  for (f in names(out)) if (inherits(out[[f]], c("POSIXct", "Date"))) out[[f]] <- .st_changelog_str(out[[f]])
  utils::write.csv(out, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8", colClasses = "character")
  if (nrow(back) != nrow(df) || !identical(back$hash, as.character(out$hash)))
    cli::cli_abort("040: CSV {basename(path)} did not round-trip.", class = "sampletidy_error")
}

# Checksums of everything 040 may not touch.
.mig040_checksums <- function(con) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  tabs <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  whole <- setdiff(tabs, c("ingest_file", "change_log", "schema_version"))
  out <- lapply(whole, function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- whole
  out$ingest_file_rest <- q(sprintf("SELECT * FROM ingest_file WHERE hash <> '%s' ORDER BY hash", .mig040_hash))
  out$ingest_file_row_rest <- q(sprintf("SELECT * EXCLUDE (state, state_reason, updated_at) FROM ingest_file WHERE hash = '%s'", .mig040_hash))
  out$change_log_rest <- q(sprintf("SELECT * FROM change_log WHERE actor <> '%s' ORDER BY ALL", .mig040_actor))
  out$schema_version_rest <- q(sprintf("SELECT * FROM schema_version WHERE version <> %d ORDER BY ALL", .mig040_marker_version))
  out$views <- q("SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
  out$indexes <- q("SELECT index_name, sql FROM duckdb_indexes() ORDER BY index_name")
  out
}

.mig040_write <- function(con, recorded_at, logf) {
  .mig040_check_preconditions(con)   # re-read under the write lock
  counts_before <- .mig040_counts(con)
  sums_before <- .mig040_checksums(con)
  db_transaction(con, function(con) {
    ingest_file_set_state(con, .mig040_hash, .mig040_new$state, reason = .mig040_new$state_reason, reset = TRUE)
    for (f in c("state", "state_reason")) {
      .st_write_change_log(con, at = recorded_at, actor = .mig040_actor, action = "update", tbl = "ingest_file",
                           uuid_row = NA_character_, field = f, old = .mig040_old[[f]], new = .mig040_new[[f]],
                           reason = .mig040_reason, source_hash = .mig040_hash)
    }
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig040_marker_version, recorded_at))
    want <- counts_before
    want$change_log <- want$change_log + 2L
    want$schema_version <- want$schema_version + 1L
    got <- .mig040_counts(con)
    if (!identical(got, want)) {
      .mig040_fail(sprintf("counts are not before + 2 change_log + 1 marker: %s",
                           paste(names(got), unlist(got), unlist(want), sep = ":", collapse = ", ")))
    }
    if (!identical(sums_before, .mig040_checksums(con))) .mig040_fail("the write changed something outside the planned row's state.")
    r <- .mig040_row(con)
    if (!identical(r$state, "seen") || !is.na(r$state_reason)) .mig040_fail("the row is not seen / NULL after the reset.")
    .mig040_verify(con)
    NULL
  })
  logf("Reset ingest_file %s (%s) archived/retained_sibling -> seen, marker %d (committed).",
       .mig040_hash, .mig040_filename, .mig040_marker_version)
  .mig040_verify(con)
}

mig040_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(
    DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                    params = list(.mig040_marker_version)),
    finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    check_con <- st_connect(db, read_only = TRUE)
    later <- tryCatch({ .mig040_verify(check_con); .mig040_later_state(.mig040_row(check_con)) },
                      finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("040 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    logf("The XTAB row is now: %s.", switch(later,
      reset = "seen (reset; not yet re-ingested)",
      held = paste0("needs_review (re-ingested but held for review - resolve the open review item(s) for ES2623357; ",
                    "re-dropping the file will NOT re-route it)"),
      imported = "archived / commit_event (re-imported)"))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  tryCatch(.mig040_check_preconditions(pre_con), finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  logf("Plan: reset ingest_file %s (%s, ES2623357 ALS XTAB) archived/retained_sibling -> seen (reset = TRUE); asset %s kept.",
       .mig040_hash, .mig040_filename, .mig040_asset)
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition passed. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = NA)))
  }

  bk_con <- st_connect(db, read_only = TRUE)
  tryCatch(.mig040_write_csv(.mig040_row(bk_con), file.path(csv_dir, sprintf("%s-BACKUP-ingest_file.csv", .mig040_name))),
           finally = DBI::dbDisconnect(bk_con, shutdown = TRUE))
  logf("Row backup written to %s", csv_dir)
  backup_path <- mig040_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- .mig040_default(.now, Sys.time())

  with_db_write(function(con) .mig040_write(con, recorded_at, logf), db = db)

  logf("%s migrated successfully (marker %d).", .mig040_name, .mig040_marker_version)
  invisible(list(status = "migrated", backup_path = backup_path,
                 restore_command = restore_command, recorded_at = recorded_at))
}
