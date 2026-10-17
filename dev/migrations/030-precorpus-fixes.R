# Operator-run migration: two small registry/data fixes found while preparing
# the corpus run (scratchpad/2026-10-17-precorpus/PROPOSAL.md, issues 2 and 3).
#
# Decided by the main session, 2026-10-17, on that proposal. Marker 1030.
# Requires 1029. Rehearsal and research: scratchpad/2026-10-17-mig030/.
#
# (1) TIMES. Four legacy samples of 2023-06-14 hold a `datetime` that does not
#     match the local time in their own comment. Legacy timed samples store the
#     UTC instant in a plain TIMESTAMP (verified against the ES2211331 COC; the
#     weekly series stays continuous in local time across every DST change).
#     14 June is AEST (+10), so local 09:25 is 2023-06-13 23:25 UTC.
#       sample    point  order      stored (UTC)      -> new (UTC)        comment
#       6494ece7  B.S01  ES2320105  2023-06-14 09:30  -> 2023-06-13 23:30  "fabricated ... 9:30"
#       d1fd0ab7  B.S03  ES2320105  2023-06-14 09:15  -> 2023-06-13 23:15  "fabricated ... 9:15"
#       6a463a90  B.S01  ES2320129  2023-06-13 22:25  -> 2023-06-13 23:25  "sampled ... at 9:25"
#       7505ed39  B.S03  ES2320129  2023-06-13 22:10  -> 2023-06-13 23:10  "sampled ... at 9:10"
#     ES2320105: the author typed his fabricated LOCAL time into the UTC column
#     (a 10-hour slip; certain). ES2320129: one hour early, a +11 (AEDT)
#     conversion in June (the comment is the only source). The 5-minute
#     separation between each pair is kept (ruling 9: one sample per point per
#     instant).
#     `datetime_start` equals `datetime` on all four (as on 14,995 of the 15,128
#     timed samples with a start), so it moves with it; otherwise ES2320105's
#     start would be ten hours AFTER its end. `date` / `date_start` are NOT
#     touched: they already hold 2023-06-13 14:00 UTC = 2023-06-14 Sydney
#     midnight, and the new instants keep the Sydney day 2023-06-14.
#     `analysis` has no datetime column, so none of the 94 analyses changes
#     (the views' `datetime` follows the sample).
#     THE INDEX: 009's `ux_sample_identity` covers `datetime`, and duckdb runs
#     an UPDATE of an indexed column as delete+insert, which the analysis ->
#     sample FK refuses. So, exactly as 021, three SEPARATE commits:
#       1. DROP INDEX ux_sample_identity                       (autocommit)
#       2. BEGIN; updates + change_log + marker + verify; COMMIT
#       3. CREATE UNIQUE INDEX ux_sample_identity ...          (009's definition)
#     inside tryCatch(finally = ...) in a FUNCTION (a top-level on.exit() is
#     inert under Rscript); the finally re-creates the index whenever it is
#     missing, whether step 2 committed or rolled back. A precondition proves
#     the post-update (alias, datetime, project) key set has no duplicate, so
#     the re-create cannot be refused. A process killed between 1 and 3 is the
#     one case this cannot cover; a re-run then refuses at the index
#     precondition and prints the CREATE statement.
#
# (2) b.eo1. The `b.eo1` -> B.E01 `transcription_error` alias (4295a6e1,
#     confirmed by R. Shannon) was minted by the 2026-08-09 Aug-2024 test
#     ingest, so the commit path gave it date_start = 2024-08-07. Under A78 a
#     transcription error has no validity window; with the bound, the Feb-May
#     2024 workbooks' "B.EO1" rows (2400-7399-02, -04, -05-01) would hit an
#     expired arm and go to review. date_start is set to NULL (date_end is
#     already NULL). This is the bounds-only confirm: no other column moves
#     (confirmed_by / auto_assign / kind stay). It changes resolution for the
#     key `b.eo1` only, and only for sample dates before 2024-08-07: it is the
#     only row with that key, Layer 1 matches the exact key, and Layer 2/3 are
#     gated off for any key that has an alias row. The rehearsal probed every
#     alias key in the registry at 12 dates before and after (only `b.eo1`
#     before 2024-08-07 changed).
#
# NOT INCLUDED: the gas points B.G201, K.G365, K.G366 (PLAN-17 ruling 8). They
# are not in featureSFC (both scratchpad copies: the Blaxland grid skips
# B.G201, the Katoomba grid stops at K.G364), so there is nothing to place them
# from; their 3 pending aliases and 9 unknown_feature items are left open.
#
# Every changed field is logged through db_update() (actor
# "030-precorpus-fixes"): 8 sample fields + 1 alias field = 9 change_log rows.
# Everything else (all other tables, all other rows, the other columns of the
# touched rows, views, indexes) is checksummed before and after.
#
# BACKUP OF THE ROWS (written on apply, beside this file):
# `030-precorpus-fixes-BACKUP-sample.csv` (the 4 samples as they were) and
# `030-precorpus-fixes-BACKUP-feature_alias.csv` (the b.eo1 row), plus the
# verified whole-file backup in `snapshot_dir`.
#
# Idempotent: marker present -> re-verify, no-op.
#
#   devtools::load_all(".")
#   env <- new.env()
#   sys.source("dev/migrations/030-precorpus-fixes.R", envir = env)
#   env$mig030_run(db = st_config("live_db"),
#                  snapshot_dir = st_config("snapshot_dir"), dry_run = TRUE)

.mig030_marker_version <- 1030L
.mig030_requires <- 1029L
.mig030_name <- "030-precorpus-fixes"
.mig030_actor <- .mig030_name
.mig030_index_name <- "ux_sample_identity"
# 009's definition, as duckdb_indexes() renders it.
.mig030_index_sql <- 'CREATE UNIQUE INDEX ux_sample_identity ON "sample"(uuid_feature_alias, datetime, uuid_project);'

.mig030_utc <- function(x) as.POSIXct(x, tz = "UTC")
.mig030_times <- data.frame(
  uuid = c("6494ece7-f63c-4aee-8c88-ed6cd48e1050", "d1fd0ab7-c767-4d6f-abad-6f345406bd39",
           "6a463a90-31d9-452f-ab14-8ee4366a9d63", "7505ed39-cbe4-48dc-8316-a13e3a656bfa"),
  point = c("B.S01", "B.S03", "B.S01", "B.S03"),
  uuid_alias = c("33800c4b-a719-4b26-a6eb-62b6da494456", "4029d8f0-8990-4e6d-9be8-c0e2b7f4d3c5",
                 "33800c4b-a719-4b26-a6eb-62b6da494456", "4029d8f0-8990-4e6d-9be8-c0e2b7f4d3c5"),
  project = c("ES2320105", "ES2320105", "ES2320129", "ES2320129"),
  old = c("2023-06-14 09:30:00", "2023-06-14 09:15:00", "2023-06-13 22:25:00", "2023-06-13 22:10:00"),
  new = c("2023-06-13 23:30:00", "2023-06-13 23:15:00", "2023-06-13 23:25:00", "2023-06-13 23:10:00"),
  local = c("09:30", "09:15", "09:25", "09:10"),
  # the comment text that justifies the new local time
  evidence = c("fabricated sample time of 9:30 for project 'ES2320105'",
               "fabricated sample time of 9:15 for project 'ES2320105'",
               "S01 was sampled twice at 9:25", "S03 was sampled twice at 9:10"),
  why = c("10 h slip: the fabricated local 09:30 was stored as UTC",
          "10 h slip: the fabricated local 09:15 was stored as UTC",
          "1 h early: converted at +11 (AEDT) in June; the comment says 9:25",
          "1 h early: converted at +11 (AEDT) in June; the comment says 9:10"),
  stringsAsFactors = FALSE)
# 2023-06-14 Sydney midnight, as the legacy `date` holds it.
.mig030_date <- "2023-06-13 14:00:00"

.mig030_alias_uuid <- "4295a6e1-696f-4a28-a9c5-b079149444da"
.mig030_alias_key <- "b.eo1"
.mig030_alias_old_start <- as.Date("2024-08-07")

.mig030_default <- function(x, default) if (is.null(x)) default else x
.mig030_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = list(...))[[1]][[1]])
.mig030_fail <- function(msg) cli::cli_abort(paste0(.mig030_name, ": ", msg), class = "sampletidy_error")
.mig030_inlist <- function(ids) paste0("(", paste(DBI::dbQuoteString(DBI::ANSI(), ids), collapse = ", "), ")")
.mig030_fmt <- function(x) format(x, "%Y-%m-%d %H:%M:%S", tz = "UTC")

.mig030_samples <- function(con) {
  s <- DBI::dbGetQuery(con, sprintf("
    SELECT s.*, f.name AS point, p.name AS project FROM \"sample\" s
    JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias JOIN feature f ON f.uuid = fa.uuid_feature
    LEFT JOIN project p ON p.uuid = s.uuid_project
    WHERE s.uuid IN %s", .mig030_inlist(.mig030_times$uuid)))
  s[match(.mig030_times$uuid, s$uuid), , drop = FALSE]
}

.mig030_alias <- function(con) {
  DBI::dbGetQuery(con, "SELECT fa.*, f.name AS target FROM feature_alias fa
    LEFT JOIN feature f ON f.uuid = fa.uuid_feature WHERE fa.alias_key = ?", params = list(.mig030_alias_key))
}

.mig030_index_def <- function(con) {
  DBI::dbGetQuery(con, "SELECT sql FROM duckdb_indexes() WHERE index_name = ?",
                  params = list(.mig030_index_name))$sql
}

.mig030_counts <- function(con) {
  tabs <- c("feature", "feature_alias", "analysis", "sample", "project", "review_queue", "change_log", "schema_version")
  stats::setNames(lapply(tabs, function(t) .mig030_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
}

# Everything 030 must not touch. `indexes` is compared after step 3.
.mig030_checksum <- function(con) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  tabs <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  whole <- setdiff(tabs, c("sample", "feature_alias", "change_log", "schema_version"))
  out <- lapply(whole, function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- whole
  ids <- .mig030_inlist(.mig030_times$uuid)
  out$sample_rest <- q(sprintf("SELECT * FROM \"sample\" WHERE uuid NOT IN %s ORDER BY uuid", ids))
  out$sample_fixed <- q(sprintf("SELECT * EXCLUDE (datetime, datetime_start) FROM \"sample\" WHERE uuid IN %s ORDER BY uuid", ids))
  out$feature_alias_rest <- q(sprintf("SELECT * FROM feature_alias WHERE uuid <> '%s' ORDER BY uuid", .mig030_alias_uuid))
  out$feature_alias_fixed <- q(sprintf("SELECT * EXCLUDE (date_start) FROM feature_alias WHERE uuid = '%s'", .mig030_alias_uuid))
  out$change_log_rest <- q(sprintf("SELECT * FROM change_log WHERE actor <> '%s' ORDER BY ALL", .mig030_actor))
  out$schema_version_rest <- q(sprintf("SELECT * FROM schema_version WHERE version <> %d ORDER BY ALL", .mig030_marker_version))
  out$views <- q("SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
  out
}
.mig030_index_sums <- function(con) {
  digest::digest(DBI::dbGetQuery(con, "SELECT index_name, sql FROM duckdb_indexes() ORDER BY index_name"), algo = "sha1")
}

# Post-update (alias, datetime, project) collisions over the WHOLE sample
# table, with the four new instants substituted: must be 0 or step 3 fails.
.mig030_post_collisions <- function(con) {
  vals <- paste(sprintf("('%s', TIMESTAMP '%s')", .mig030_times$uuid, .mig030_times$new), collapse = ", ")
  .mig030_scalar(con, sprintf("
    WITH n(uuid, dt) AS (VALUES %s),
    k AS (SELECT s.uuid_feature_alias, COALESCE(n.dt, s.datetime) AS dt, s.uuid_project
          FROM \"sample\" s LEFT JOIN n ON n.uuid = s.uuid)
    SELECT COUNT(*) FROM (SELECT 1 FROM k WHERE uuid_feature_alias IS NOT NULL AND dt IS NOT NULL
      AND uuid_project IS NOT NULL GROUP BY uuid_feature_alias, dt, uuid_project HAVING COUNT(*) > 1)", vals))
}

# NULL when the 4 samples are in the state `done` selects, else the problem.
.mig030_samples_problem <- function(con, done) {
  s <- .mig030_samples(con)
  t <- .mig030_times
  if (anyNA(s$uuid)) return(sprintf("sample(s) missing: %s", paste(t$uuid[is.na(s$uuid)], collapse = ", ")))
  if (!identical(s$point, t$point) || !identical(s$uuid_feature_alias, t$uuid_alias) || !identical(s$project, t$project))
    return("the 4 samples are not at the expected point / alias / project")
  if (any(.mig030_fmt(s$date) != .mig030_date) || any(.mig030_fmt(s$date_start) != .mig030_date))
    return("the 4 samples' date / date_start are not 2023-06-13 14:00 UTC (2023-06-14 Sydney)")
  for (i in seq_len(nrow(t))) if (!grepl(t$evidence[[i]], s$comments[[i]], fixed = TRUE))
    return(sprintf("sample %s's comment no longer says '%s'", t$uuid[[i]], t$evidence[[i]]))
  want <- if (done) t$new else t$old
  if (anyNA(s$datetime) || any(.mig030_fmt(s$datetime) != want))
    return(sprintf("the 4 datetimes are not %s (%s)", if (done) "the corrected values" else "as found",
                   paste(.mig030_fmt(s$datetime), collapse = ", ")))
  if (anyNA(s$datetime_start) || any(.mig030_fmt(s$datetime_start) != want))
    return(sprintf("the 4 datetime_start values are not %s", if (done) "equal to the corrected datetime" else "equal to datetime as found"))
  if (done) {
    loc <- format(s$datetime, "%Y-%m-%d %H:%M", tz = "Australia/Sydney")
    if (!identical(loc, paste("2023-06-14", t$local))) return(sprintf("Sydney local times are %s", paste(loc, collapse = ", ")))
  }
  NULL
}

.mig030_alias_problem <- function(con, done) {
  a <- .mig030_alias(con)
  if (nrow(a) != 1L) return(sprintf("%d feature_alias rows carry key '%s', expected 1", nrow(a), .mig030_alias_key))
  if (!identical(a$uuid, .mig030_alias_uuid) || !identical(a$kind, "transcription_error") ||
      !identical(a$target, "B.E01") || !identical(a$name, "B.EO1") || is.na(a$confirmed_by) || !isTRUE(a$auto_assign))
    return("b.eo1 is not the confirmed, auto_assign B.EO1 -> B.E01 transcription_error alias 4295a6e1")
  if (!is.na(a$date_end)) return("b.eo1 has a date_end")
  if (done && !is.na(a$date_start)) return("b.eo1 still has a date_start")
  if (!done && !identical(as.Date(a$date_start), .mig030_alias_old_start)) return("b.eo1's date_start is not 2024-08-07")
  NULL
}

.mig030_verify <- function(con) {
  for (p in list(.mig030_samples_problem(con, TRUE), .mig030_alias_problem(con, TRUE)))
    if (!is.null(p)) cli::cli_abort(paste0("030 verify failed: ", p), class = "sampletidy_error")
  invisible(TRUE)
}

.mig030_verify_index <- function(con) {
  def <- .mig030_index_def(con)
  if (length(def) != 1L || !identical(def, .mig030_index_sql)) {
    cli::cli_abort(sprintf("030 verify failed: index %s is %s, expected %s.", .mig030_index_name,
                           if (length(def)) def else "MISSING", .mig030_index_sql), class = "sampletidy_error")
  }
  invisible(TRUE)
}

.mig030_check_preconditions <- function(con) {
  if (.mig030_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig030_requires) == 0L) {
    .mig030_fail(sprintf("marker %d (029) is required first.", .mig030_requires))
  }
  def <- .mig030_index_def(con)
  if (length(def) != 1L) .mig030_fail(sprintf("index %s is missing - 009's index must exist before 030 drops and re-creates it. If a previous 030 run was killed mid-way, re-create it with: %s", .mig030_index_name, .mig030_index_sql))
  if (!identical(def, .mig030_index_sql)) .mig030_fail(sprintf("index %s is defined as %s, not 009's %s.", .mig030_index_name, def, .mig030_index_sql))
  for (p in list(.mig030_samples_problem(con, FALSE), .mig030_alias_problem(con, FALSE)))
    if (!is.null(p)) .mig030_fail(sprintf("the database is not in the pre-030 state (%s). Nothing written.", p))
  n_coll <- .mig030_post_collisions(con)
  if (n_coll > 0L) .mig030_fail(sprintf("%d (alias, datetime, project) groups would collide after the update; the index could not be re-created.", n_coll))
  invisible(list(samples = .mig030_samples(con), alias = .mig030_alias(con)))
}

mig030_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- .mig030_default(.now, Sys.time())
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig030_name, ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig030_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig030_counts(verify_con))) {
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  }
  dest
}

.mig030_write_csv <- function(df, path) {
  out <- df
  for (f in names(out)) if (inherits(out[[f]], c("POSIXct", "Date"))) out[[f]] <- .st_changelog_str(out[[f]])
  utils::write.csv(out, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8", colClasses = "character")
  if (nrow(back) != nrow(df) || !identical(back$uuid, out$uuid) || !identical(back$comments, as.character(out$comments))) {
    cli::cli_abort("030: CSV backup {basename(path)} did not round-trip.", class = "sampletidy_error")
  }
}

# Steps 1-3 (see header). A function, so the finally actually runs under Rscript.
.mig030_apply <- function(con, recorded_at, logf) {
  counts_before <- .mig030_counts(con)
  sums_before <- .mig030_checksum(con)
  idx_before <- .mig030_index_sums(con)
  DBI::dbExecute(con, sprintf("DROP INDEX %s", .mig030_index_name))
  logf("Dropped %s (committed).", .mig030_index_name)
  tryCatch({
    db_transaction(con, function(con) {
      t <- .mig030_times
      for (i in seq_len(nrow(t))) {
        nv <- .mig030_utc(t$new[[i]])
        db_update(con, "sample", uuid = t$uuid[[i]],
                  changes = list(datetime = nv, datetime_start = nv),
                  actor = .mig030_actor,
                  reason = sprintf("030 (main session, 2026-10-17; precorpus issue 2): %s %s sampled 2023-06-14 %s AEST per its own comment ('%s'); %s; UTC %s -> %s",
                                   t$point[[i]], t$project[[i]], t$local[[i]], t$evidence[[i]], t$why[[i]], t$old[[i]], t$new[[i]]))
      }
      db_update(con, "feature_alias", uuid = .mig030_alias_uuid,
                changes = list(date_start = as.Date(NA)),
                actor = .mig030_actor,
                reason = "030 (main session, 2026-10-17; precorpus issue 3): b.eo1 -> B.E01 is a transcription_error, which has no validity window (A78); date_start 2024-08-07 was set by the 2026-08-09 Aug-2024 test ingest and would send the Feb-May 2024 B.EO1 rows to review. Bounds-only: nothing else changes.")
      DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                     params = list(.mig030_marker_version, recorded_at))
      .mig030_verify(con)
      after <- .mig030_counts(con)
      n_cl <- .mig030_scalar(con, "SELECT COUNT(*) FROM change_log WHERE actor = ?", .mig030_actor)
      want <- counts_before
      want$change_log <- want$change_log + 9L
      want$schema_version <- want$schema_version + 1L
      if (n_cl != 9L || !identical(after, want)) {
        cli::cli_abort("030 verify failed: table counts are not before plus exactly the planned rows (9 change_log, 1 marker).", class = "sampletidy_error")
      }
      if (!identical(sums_before, .mig030_checksum(con))) {
        cli::cli_abort("030 verify failed: something outside the planned fields moved.", class = "sampletidy_error")
      }
      NULL
    })
    logf("Updated 4 sample datetimes and cleared b.eo1's date_start (committed).")
  }, finally = {
    if (length(.mig030_index_def(con)) == 0L) {
      DBI::dbExecute(con, .mig030_index_sql)
      logf("Re-created %s.", .mig030_index_name)
    }
  })
  .mig030_verify_index(con)
  if (!identical(idx_before, .mig030_index_sums(con))) {
    cli::cli_abort("030 verify failed: the index set differs from before.", class = "sampletidy_error")
  }
  invisible(TRUE)
}

mig030_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(
    DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                    params = list(.mig030_marker_version)),
    finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch({ .mig030_verify(check_con); .mig030_verify_index(check_con) },
             finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("030 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  pre <- tryCatch(.mig030_check_preconditions(pre_con), finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  logf("Plan: (1) 4 sample datetime/datetime_start -> %s; (2) b.eo1 date_start 2024-08-07 -> NULL. No (alias, datetime, project) collision.",
       paste(sprintf("%s %s %s", .mig030_times$point, .mig030_times$project, .mig030_times$new), collapse = "; "))
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition passed. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = NA)))
  }

  .mig030_write_csv(pre$samples[, setdiff(names(pre$samples), c("point", "project"))],
                    file.path(csv_dir, sprintf("%s-BACKUP-sample.csv", .mig030_name)))
  .mig030_write_csv(pre$alias[, setdiff(names(pre$alias), "target")],
                    file.path(csv_dir, sprintf("%s-BACKUP-feature_alias.csv", .mig030_name)))
  logf("Row backups written to %s", csv_dir)
  backup_path <- mig030_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- .mig030_default(.now, Sys.time())

  with_db_write(function(con) {
    .mig030_check_preconditions(con)   # re-read under the write lock
    .mig030_apply(con, recorded_at, logf)
  }, db = db)

  logf("%s migrated successfully (marker %d).", .mig030_name, .mig030_marker_version)
  invisible(list(status = "migrated", backup_path = backup_path,
                 restore_command = restore_command, recorded_at = recorded_at))
}
