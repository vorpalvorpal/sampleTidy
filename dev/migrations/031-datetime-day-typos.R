# Operator-run migration: fix the month/day typo in the `datetime` of three
# legacy samples whose Sydney day disagrees with their `date`
# (scratchpad/2026-10-17-dtmismatch/PROPOSAL.md and proposed_fixes.csv).
#
# Decided by the main session, 2026-10-17, on that proposal. Marker 1031.
# Requires 1030. Rehearsal: scratchpad/2026-10-17-mig031/.
#
# Of 15,164 timed samples exactly 4 have a Sydney `datetime` day that differs
# from the `date` day. Three are typos (this migration); the fourth, K.MW11B
# (b7286aa9), is deliberate and self-documented and is NOT touched.
#
#   sample    point  order      stored (UTC)        -> new (UTC)          Sydney after
#   81d163ca  B.MW02 ES2236704  2022-11-11 22:30:00 -> 2022-10-11 22:30:00  2022-10-12 09:30
#   66154ebb  B.S03  ES2237712  2022-11-18 21:00:00 -> 2022-10-18 21:00:00  2022-10-19 08:00
#   8d9ef8a9  B.S01  ES2315749  2023-05-08 22:30:00 -> 2023-05-09 22:30:00  2023-05-10 08:30
# The ALS COAs, ENMRGs and ACIRL sheets all give the `date` day; the time of
# day has no source and is kept. `date` is correct and is not touched.
# `datetime_start` equals `datetime` on all three, so it moves with it.
# (The proposal's 8d9ef8a9 line "2022-05-09" was a typo; 2023-05-09 is right.)
# The same-day B.S01 of WO 2400-7286-05-04 sits at 22:30:30 (ruling 9
# separator), so the new value does not collide.
#
# THE INDEX: as 021 and 030. `ux_sample_identity` covers `datetime`, and an
# UPDATE of an indexed column is delete+insert, which the analysis -> sample
# FK refuses. Three separate commits: DROP INDEX (autocommit); BEGIN; updates +
# change_log + marker + verify; COMMIT; then CREATE UNIQUE INDEX in a finally
# inside a FUNCTION (a top-level on.exit() is inert under Rscript). A
# precondition proves the post-update key set has no duplicate.
#
# Every changed field is logged through db_update() (actor
# "031-datetime-day-typos"): 6 change_log rows. Everything else is
# checksummed before and after.
#
# BACKUP OF THE ROWS (written on apply, beside this file):
# `031-datetime-day-typos-BACKUP-sample.csv`, plus the verified whole-file
# backup in `snapshot_dir`.
#
# Idempotent: marker present -> re-verify, no-op.
#
#   devtools::load_all(".")
#   env <- new.env()
#   sys.source("dev/migrations/031-datetime-day-typos.R", envir = env)
#   env$mig031_run(db = st_config("live_db"),
#                  snapshot_dir = st_config("snapshot_dir"), dry_run = TRUE)

.mig031_marker_version <- 1031L
.mig031_requires <- 1030L
.mig031_name <- "031-datetime-day-typos"
.mig031_actor <- .mig031_name
.mig031_index_name <- "ux_sample_identity"
.mig031_index_sql <- 'CREATE UNIQUE INDEX ux_sample_identity ON "sample"(uuid_feature_alias, datetime, uuid_project);'

.mig031_utc <- function(x) as.POSIXct(x, tz = "UTC")
.mig031_fixes <- data.frame(
  prefix = c("81d163ca", "66154ebb", "8d9ef8a9"),
  point = c("B.MW02", "B.S03", "B.S01"),
  project = c("ES2236704", "ES2237712", "ES2315749"),
  old = c("2022-11-11 22:30:00", "2022-11-18 21:00:00", "2023-05-08 22:30:00"),
  new = c("2022-10-11 22:30:00", "2022-10-18 21:00:00", "2023-05-09 22:30:00"),
  date_utc = c("2022-10-11 13:00:00", "2022-10-18 13:00:00", "2023-05-09 14:00:00"),
  sydney_day = c("2022-10-12", "2022-10-19", "2023-05-10"),
  sydney_new = c("2022-10-12 09:30", "2022-10-19 08:00", "2023-05-10 08:30"),
  why = c("month typo (Nov for Oct); ALS COA/ENMRG/ACIRL xls say 12-Oct-2022",
          "month typo (Nov for Oct); ALS COA/ENMRG/ACIRL xls say 19-Oct-2022",
          "day typo (09 for 10 local); ALS COA/ENMRG/ACIRL pdf say 10-May-2023"),
  stringsAsFactors = FALSE)

.mig031_default <- function(x, default) if (is.null(x)) default else x
.mig031_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = list(...))[[1]][[1]])
.mig031_fail <- function(msg) cli::cli_abort(paste0(.mig031_name, ": ", msg), class = "sampletidy_error")
.mig031_inlist <- function(ids) paste0("(", paste(DBI::dbQuoteString(DBI::ANSI(), ids), collapse = ", "), ")")
.mig031_fmt <- function(x) format(x, "%Y-%m-%d %H:%M:%S", tz = "UTC")

# One uuid per prefix, or a failure. Returns the 3 full uuids in table order.
.mig031_uuids <- function(con) {
  vapply(.mig031_fixes$prefix, function(p) {
    u <- DBI::dbGetQuery(con, "SELECT uuid FROM \"sample\" WHERE starts_with(CAST(uuid AS VARCHAR), ?)",
                         params = list(p))$uuid
    if (length(u) != 1L) .mig031_fail(sprintf("prefix %s resolves to %d samples, expected exactly 1.", p, length(u)))
    as.character(u)
  }, character(1), USE.NAMES = FALSE)
}

.mig031_samples <- function(con) {
  ids <- .mig031_uuids(con)
  s <- DBI::dbGetQuery(con, sprintf("
    SELECT s.*, f.name AS point, p.name AS project FROM \"sample\" s
    JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias JOIN feature f ON f.uuid = fa.uuid_feature
    LEFT JOIN project p ON p.uuid = s.uuid_project
    WHERE CAST(s.uuid AS VARCHAR) IN %s", .mig031_inlist(ids)))
  s[match(ids, as.character(s$uuid)), , drop = FALSE]
}

.mig031_index_def <- function(con) {
  DBI::dbGetQuery(con, "SELECT sql FROM duckdb_indexes() WHERE index_name = ?",
                  params = list(.mig031_index_name))$sql
}

.mig031_counts <- function(con) {
  tabs <- c("feature", "feature_alias", "analysis", "sample", "project", "review_queue", "change_log", "schema_version")
  stats::setNames(lapply(tabs, function(t) .mig031_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
}

.mig031_checksum <- function(con) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  tabs <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  whole <- setdiff(tabs, c("sample", "change_log", "schema_version"))
  out <- lapply(whole, function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- whole
  ids <- .mig031_inlist(.mig031_uuids(con))
  out$sample_rest <- q(sprintf("SELECT * FROM \"sample\" WHERE CAST(uuid AS VARCHAR) NOT IN %s ORDER BY uuid", ids))
  out$sample_fixed <- q(sprintf("SELECT * EXCLUDE (datetime, datetime_start) FROM \"sample\" WHERE CAST(uuid AS VARCHAR) IN %s ORDER BY uuid", ids))
  out$change_log_rest <- q(sprintf("SELECT * FROM change_log WHERE actor <> '%s' ORDER BY ALL", .mig031_actor))
  out$schema_version_rest <- q(sprintf("SELECT * FROM schema_version WHERE version <> %d ORDER BY ALL", .mig031_marker_version))
  out$views <- q("SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
  out
}
.mig031_index_sums <- function(con) {
  digest::digest(DBI::dbGetQuery(con, "SELECT index_name, sql FROM duckdb_indexes() ORDER BY index_name"), algo = "sha1")
}

# Post-update (alias, datetime, project) collisions over the whole table.
.mig031_post_collisions <- function(con) {
  vals <- paste(sprintf("('%s', TIMESTAMP '%s')", .mig031_uuids(con), .mig031_fixes$new), collapse = ", ")
  .mig031_scalar(con, sprintf("
    WITH n(uuid, dt) AS (VALUES %s),
    k AS (SELECT s.uuid_feature_alias, COALESCE(n.dt, s.datetime) AS dt, s.uuid_project
          FROM \"sample\" s LEFT JOIN n ON CAST(n.uuid AS VARCHAR) = CAST(s.uuid AS VARCHAR))
    SELECT COUNT(*) FROM (SELECT 1 FROM k WHERE uuid_feature_alias IS NOT NULL AND dt IS NOT NULL
      AND uuid_project IS NOT NULL GROUP BY uuid_feature_alias, dt, uuid_project HAVING COUNT(*) > 1)", vals))
}

# NULL when the 3 samples are in the state `done` selects, else the problem.
.mig031_samples_problem <- function(con, done) {
  s <- .mig031_samples(con)
  t <- .mig031_fixes
  if (!identical(s$point, t$point) || !identical(s$project, t$project))
    return("the 3 samples are not at the expected point / project")
  if (any(.mig031_fmt(s$date) != t$date_utc))
    return("the 3 samples' date is not as found (it must stay unchanged)")
  dsyd <- format(s$date, "%Y-%m-%d", tz = "Australia/Sydney")
  if (!identical(dsyd, t$sydney_day)) return(sprintf("date Sydney days are %s", paste(dsyd, collapse = ", ")))
  want <- if (done) t$new else t$old
  if (anyNA(s$datetime) || any(.mig031_fmt(s$datetime) != want))
    return(sprintf("the 3 datetimes are not %s (%s)", if (done) "the corrected values" else "as found",
                   paste(.mig031_fmt(s$datetime), collapse = ", ")))
  if (anyNA(s$datetime_start) || any(.mig031_fmt(s$datetime_start) != want))
    return(sprintf("the 3 datetime_start values are not %s", if (done) "equal to the corrected datetime" else "equal to datetime as found"))
  if (done) {
    loc <- format(s$datetime, "%Y-%m-%d %H:%M", tz = "Australia/Sydney")
    if (!identical(loc, t$sydney_new)) return(sprintf("Sydney local times are %s", paste(loc, collapse = ", ")))
    if (!identical(format(s$datetime, "%Y-%m-%d", tz = "Australia/Sydney"), dsyd))
      return("a corrected datetime's Sydney day differs from its date's Sydney day")
  }
  NULL
}

.mig031_verify <- function(con) {
  p <- .mig031_samples_problem(con, TRUE)
  if (!is.null(p)) cli::cli_abort(paste0("031 verify failed: ", p), class = "sampletidy_error")
  invisible(TRUE)
}

.mig031_verify_index <- function(con) {
  def <- .mig031_index_def(con)
  if (length(def) != 1L || !identical(def, .mig031_index_sql)) {
    cli::cli_abort(sprintf("031 verify failed: index %s is %s, expected %s.", .mig031_index_name,
                           if (length(def)) def else "MISSING", .mig031_index_sql), class = "sampletidy_error")
  }
  invisible(TRUE)
}

.mig031_check_preconditions <- function(con) {
  if (.mig031_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig031_requires) == 0L) {
    .mig031_fail(sprintf("marker %d (030) is required first.", .mig031_requires))
  }
  def <- .mig031_index_def(con)
  if (length(def) != 1L) .mig031_fail(sprintf("index %s is missing - 009's index must exist before 031 drops and re-creates it. If a previous 031 run was killed mid-way, re-create it with: %s", .mig031_index_name, .mig031_index_sql))
  if (!identical(def, .mig031_index_sql)) .mig031_fail(sprintf("index %s is defined as %s, not 009's %s.", .mig031_index_name, def, .mig031_index_sql))
  p <- .mig031_samples_problem(con, FALSE)
  if (!is.null(p)) .mig031_fail(sprintf("the database is not in the pre-031 state (%s). Nothing written.", p))
  n_coll <- .mig031_post_collisions(con)
  if (n_coll > 0L) .mig031_fail(sprintf("%d (alias, datetime, project) groups would collide after the update; the index could not be re-created.", n_coll))
  invisible(list(samples = .mig031_samples(con)))
}

mig031_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- .mig031_default(.now, Sys.time())
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig031_name, ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig031_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig031_counts(verify_con))) {
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  }
  dest
}

.mig031_write_csv <- function(df, path) {
  out <- df
  for (f in names(out)) if (inherits(out[[f]], c("POSIXct", "Date"))) out[[f]] <- .st_changelog_str(out[[f]])
  utils::write.csv(out, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8", colClasses = "character")
  if (nrow(back) != nrow(df) || !identical(back$uuid, as.character(out$uuid))) {
    cli::cli_abort("031: CSV backup {basename(path)} did not round-trip.", class = "sampletidy_error")
  }
}

# Steps 1-3 (see header). A function, so the finally actually runs under Rscript.
.mig031_apply <- function(con, recorded_at, logf) {
  counts_before <- .mig031_counts(con)
  sums_before <- .mig031_checksum(con)
  idx_before <- .mig031_index_sums(con)
  ids <- .mig031_uuids(con)
  DBI::dbExecute(con, sprintf("DROP INDEX %s", .mig031_index_name))
  logf("Dropped %s (committed).", .mig031_index_name)
  tryCatch({
    db_transaction(con, function(con) {
      t <- .mig031_fixes
      for (i in seq_len(nrow(t))) {
        nv <- .mig031_utc(t$new[[i]])
        db_update(con, "sample", uuid = ids[[i]],
                  changes = list(datetime = nv, datetime_start = nv),
                  actor = .mig031_actor,
                  reason = sprintf("031 (main session, 2026-10-17; dtmismatch): %s %s: %s; time of day kept; Sydney %s; UTC %s -> %s",
                                   t$point[[i]], t$project[[i]], t$why[[i]], t$sydney_new[[i]], t$old[[i]], t$new[[i]]))
      }
      DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                     params = list(.mig031_marker_version, recorded_at))
      .mig031_verify(con)
      after <- .mig031_counts(con)
      n_cl <- .mig031_scalar(con, "SELECT COUNT(*) FROM change_log WHERE actor = ?", .mig031_actor)
      want <- counts_before
      want$change_log <- want$change_log + 6L
      want$schema_version <- want$schema_version + 1L
      if (n_cl != 6L || !identical(after, want)) {
        cli::cli_abort("031 verify failed: table counts are not before plus exactly the planned rows (6 change_log, 1 marker).", class = "sampletidy_error")
      }
      if (!identical(sums_before, .mig031_checksum(con))) {
        cli::cli_abort("031 verify failed: something outside the planned fields moved.", class = "sampletidy_error")
      }
      NULL
    })
    logf("Updated 3 sample datetimes (committed).")
  }, finally = {
    if (length(.mig031_index_def(con)) == 0L) {
      DBI::dbExecute(con, .mig031_index_sql)
      logf("Re-created %s.", .mig031_index_name)
    }
  })
  .mig031_verify_index(con)
  if (!identical(idx_before, .mig031_index_sums(con))) {
    cli::cli_abort("031 verify failed: the index set differs from before.", class = "sampletidy_error")
  }
  invisible(TRUE)
}

mig031_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(
    DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                    params = list(.mig031_marker_version)),
    finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch({ .mig031_verify(check_con); .mig031_verify_index(check_con) },
             finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("031 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  pre <- tryCatch(.mig031_check_preconditions(pre_con), finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  logf("Plan: 3 sample datetime/datetime_start -> %s. No (alias, datetime, project) collision.",
       paste(sprintf("%s %s %s", .mig031_fixes$point, .mig031_fixes$project, .mig031_fixes$new), collapse = "; "))
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition passed. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = NA)))
  }

  .mig031_write_csv(pre$samples[, setdiff(names(pre$samples), c("point", "project"))],
                    file.path(csv_dir, sprintf("%s-BACKUP-sample.csv", .mig031_name)))
  logf("Row backup written to %s", csv_dir)
  backup_path <- mig031_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- .mig031_default(.now, Sys.time())

  with_db_write(function(con) {
    .mig031_check_preconditions(con)   # re-read under the write lock
    .mig031_apply(con, recorded_at, logf)
  }, db = db)

  logf("%s migrated successfully (marker %d).", .mig031_name, .mig031_marker_version)
  invisible(list(status = "migrated", backup_path = backup_path,
                 restore_command = restore_command, recorded_at = recorded_at))
}
