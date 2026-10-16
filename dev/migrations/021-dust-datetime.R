# Operator-run migration: give every dust sample (B.D07 / B.D08) a `datetime`
# and `datetime_start` equal to its `date` and `date_start`.
#
# Authorised by Robin, 2026-10-17 (021 "dust datetime"): "For all dust samples
# (B.D07/B.D08; include the 22 imported by 020 and the 4 from 018), set
# datetime = date and datetime_start = date_start, in the same representation."
#
# ---- WHY ----------------------------------------------------------------------
#
# Every v_measurement* view derives its `date` column and its preference_rank
# partition from `sample.datetime`. 015-020 re-dated the legacy dust `date` /
# `date_start` (collection / exposure) but - because of 009's unique index, see
# below - never touched `datetime` / `datetime_start`, which still hold the
# dates as first loaded. Measured on a copy of live (2026-10-17,
# scratchpad/2026-10-17-datetime/q1-q8.R): 116 of the 122 dust samples have a
# Sydney day in `datetime` or `datetime_start` that disagrees with `date` /
# `date_start` (2021-22 rows a month out, 2020-02/-03 a year out, the 2024
# "+1 day" rows, 020's datetime_start = collection instead of exposure), 2 have
# NULL `datetime` (96c5e696, e732697d), and 9 dust rows are wrongly ranked 2
# in v_measurement. The other 6 agree on the Sydney day but not on the instant
# (11:00 vs midnight), so all 122 are rewritten: after 021, `datetime` IS
# `date` and `datetime_start` IS `date_start`, byte-for-byte, for every dust
# sample. Dust has no time of collection worth keeping: the gauges go out on
# the 1st and come in on the 1st (Robin, 2026-10-16), and `date` is the
# authoritative collection date.
#
# REPRESENTATION: `date` holds Sydney midnight as the UTC instant (legacy form,
# e.g. 2020-01-31 13:00:00 = 2020-02-01 Sydney). `datetime` is copied from it
# verbatim, so both carry the same instant and the same Sydney day.
#
# ---- THE INDEX ----------------------------------------------------------------
#
# 009's `ux_sample_identity` covers `datetime`. duckdb runs an UPDATE of an
# indexed column as delete+insert, which the analysis -> sample FK refuses, so
# the UPDATE cannot run while the index exists. The tested sequence (copy of
# live, scratchpad/2026-10-17-datetime/q8.R) is three SEPARATE commits:
#   1. DROP INDEX ux_sample_identity                 (autocommit)
#   2. BEGIN; the updates + change_log + marker; COMMIT
#   3. CREATE UNIQUE INDEX ux_sample_identity ...    (EXACT original definition,
#      read from duckdb_indexes() before the drop and checked against 009's)
# CRASH SAFETY: steps 2-3 run inside tryCatch(finally = ...) in a FUNCTION -
# a top-level on.exit() is inert under Rscript - and the finally re-creates the
# index whenever it is missing, whether step 2 committed or rolled back. A
# precondition proves the post-update key set has no duplicate, so the
# re-create cannot be refused by the new data. (A killed process between 1 and
# 3 is the one case this cannot cover; re-running 021 then refuses at the
# index precondition and says so.)
#
# Every changed field is logged through db_update() (actor
# "021-dust-datetime"). No other column, row or table moves (checksummed).
#
# BACKUP OF THE ROWS: `021-dust-datetime-BACKUP-sample.csv` beside this file
# (the 122 dust samples as they were), plus the verified whole-file backup in
# `snapshot_dir`.
#
# Marker 1021. Requires 1020. Idempotent: marker present -> re-verify, no-op.
#
#   devtools::load_all(".")
#   env <- new.env()
#   sys.source("dev/migrations/021-dust-datetime.R", envir = env)
#   env$mig021_run(db = st_config("live_db"),
#                  snapshot_dir = st_config("snapshot_dir"), dry_run = TRUE)

.mig021_marker_version <- 1021L
.mig021_requires <- 1020L
.mig021_actor <- "021-dust-datetime"
.mig021_expected_dust_n <- 122L
.mig021_gauges <- c("B.D07", "B.D08")
.mig021_index_name <- "ux_sample_identity"
# 009's definition, as duckdb_indexes() renders it.
.mig021_index_sql <- 'CREATE UNIQUE INDEX ux_sample_identity ON "sample"(uuid_feature_alias, datetime, uuid_project);'

.mig021_default <- function(x, default) if (is.null(x)) default else x
.mig021_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = list(...))[[1]][[1]])
.mig021_fail <- function(msg) cli::cli_abort(paste0("021-dust-datetime: ", msg), class = "sampletidy_error")
.mig021_syd <- function(col) sprintf("CAST(timezone('Australia/Sydney', timezone('UTC', %s)) AS DATE)", col)

.mig021_dust_sql <- "
  SELECT DISTINCT a.uuid_sample AS uuid FROM analysis a
  JOIN lab_method lm ON lm.uuid = a.uuid_lab JOIN analyte an ON an.uuid = lm.uuid_analyte
  WHERE an.name LIKE 'dust-%'"

.mig021_dust_rows <- function(con) {
  DBI::dbGetQuery(con, sprintf("
    SELECT s.*, f.name AS gauge FROM \"sample\" s
    JOIN (%s) d ON d.uuid = s.uuid
    JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias JOIN feature f ON f.uuid = fa.uuid_feature
    ORDER BY s.uuid", .mig021_dust_sql))
}

.mig021_index_def <- function(con) {
  DBI::dbGetQuery(con, "SELECT sql FROM duckdb_indexes() WHERE index_name = ?",
                  params = list(.mig021_index_name))$sql
}

.mig021_counts <- function(con) {
  list(
    analysis = .mig021_scalar(con, "SELECT COUNT(*) FROM analysis"),
    sample = .mig021_scalar(con, "SELECT COUNT(*) FROM \"sample\""),
    project = .mig021_scalar(con, "SELECT COUNT(*) FROM project"),
    feature_alias = .mig021_scalar(con, "SELECT COUNT(*) FROM feature_alias")
  )
}

# Everything 021 must not touch: every sample column but the two datetimes, the
# two datetimes on every non-dust sample, and all of analysis / project.
.mig021_checksum <- function(con) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  list(
    sample_rest = q("SELECT uuid, uuid_feature_alias, uuid_project, date, date_start, organisation, person, purpose, comments FROM \"sample\" ORDER BY uuid"),
    sample_dt_other = q(sprintf("SELECT uuid, datetime, datetime_start FROM \"sample\" WHERE uuid NOT IN (%s) ORDER BY uuid", .mig021_dust_sql)),
    analysis = q("SELECT * FROM analysis ORDER BY uuid"),
    project = q("SELECT * FROM project ORDER BY uuid")
  )
}

# Post-update key collisions: (alias, date, project) for dust + (alias, datetime,
# project) for everything else must stay unique, or the index re-create fails.
.mig021_post_collisions <- function(con) {
  .mig021_scalar(con, sprintf("
    WITH k AS (
      SELECT s.uuid_feature_alias, CASE WHEN d.uuid IS NULL THEN s.datetime ELSE s.date END AS dt, s.uuid_project
      FROM \"sample\" s LEFT JOIN (%s) d ON d.uuid = s.uuid)
    SELECT COUNT(*) FROM (SELECT 1 FROM k WHERE uuid_feature_alias IS NOT NULL AND dt IS NOT NULL
      AND uuid_project IS NOT NULL GROUP BY uuid_feature_alias, dt, uuid_project HAVING COUNT(*) > 1)",
    .mig021_dust_sql))
}

.mig021_check_preconditions <- function(con) {
  fail <- .mig021_fail
  if (.mig021_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig021_requires) == 0L) {
    fail(sprintf("marker %d (020) is required first.", .mig021_requires))
  }
  rows <- .mig021_dust_rows(con)
  if (nrow(rows) != .mig021_expected_dust_n) fail(sprintf("%d samples carry a dust analysis, expected %d.", nrow(rows), .mig021_expected_dust_n))
  bad <- setdiff(unique(rows$gauge), .mig021_gauges)
  if (length(bad)) fail(sprintf("dust samples at unexpected features: %s.", paste(bad, collapse = ", ")))
  if (anyNA(rows$date)) fail("a dust sample has a NULL date.")
  def <- .mig021_index_def(con)
  if (length(def) != 1L) fail(sprintf("index %s is missing - 009's index must exist before 021 drops and re-creates it. If a previous 021 run was killed mid-way, re-create it with: %s", .mig021_index_name, .mig021_index_sql))
  if (!identical(def, .mig021_index_sql)) fail(sprintf("index %s is defined as %s, not 009's %s.", .mig021_index_name, def, .mig021_index_sql))
  n_coll <- .mig021_post_collisions(con)
  if (n_coll > 0L) fail(sprintf("%d (alias, datetime, project) groups would collide after the update; the index could not be re-created.", n_coll))
  invisible(rows)
}

.mig021_verify <- function(con) {
  fail <- function(msg) cli::cli_abort(paste0("021 verify failed: ", msg), class = "sampletidy_error")
  n <- DBI::dbGetQuery(con, sprintf("
    SELECT COUNT(*) AS n,
           SUM(CASE WHEN s.datetime IS DISTINCT FROM s.date THEN 1 ELSE 0 END) AS dt_ne,
           SUM(CASE WHEN s.datetime_start IS DISTINCT FROM s.date_start THEN 1 ELSE 0 END) AS dts_ne,
           SUM(CASE WHEN %s IS DISTINCT FROM %s THEN 1 ELSE 0 END) AS dt_day_ne,
           SUM(CASE WHEN %s IS DISTINCT FROM %s THEN 1 ELSE 0 END) AS dts_day_ne
    FROM \"sample\" s JOIN (%s) d ON d.uuid = s.uuid",
    .mig021_syd("s.datetime"), .mig021_syd("s.date"),
    .mig021_syd("s.datetime_start"), .mig021_syd("s.date_start"), .mig021_dust_sql))
  if (n$n != .mig021_expected_dust_n) fail(sprintf("%d dust samples, expected %d.", n$n, .mig021_expected_dust_n))
  if (n$dt_ne + n$dts_ne + n$dt_day_ne + n$dts_day_ne > 0) {
    fail(sprintf("datetime != date on %d, datetime_start != date_start on %d, Sydney day %d / %d.",
                 n$dt_ne, n$dts_ne, n$dt_day_ne, n$dts_day_ne))
  }
  invisible(TRUE)
}

.mig021_verify_index <- function(con) {
  def <- .mig021_index_def(con)
  if (length(def) != 1L || !identical(def, .mig021_index_sql)) {
    cli::cli_abort(sprintf("021 verify failed: index %s is %s, expected %s.", .mig021_index_name,
                           if (length(def)) def else "MISSING", .mig021_index_sql), class = "sampletidy_error")
  }
  invisible(TRUE)
}

mig021_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- .mig021_default(.now, Sys.time())
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-021-dust-datetime_%sZ.duckdb", ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig021_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig021_counts(verify_con))) {
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  }
  dest
}

.mig021_write_csv <- function(df, path) {
  out <- df
  for (f in names(out)) if (inherits(out[[f]], "POSIXct")) out[[f]] <- .st_changelog_str(out[[f]])
  utils::write.csv(out, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8")
  if (nrow(back) != nrow(df) || !identical(back$uuid, out$uuid)) {
    cli::cli_abort("021: CSV backup {basename(path)} did not round-trip.", class = "sampletidy_error")
  }
}

# Steps 1-3 (see header). A function, so the finally actually runs under Rscript.
.mig021_apply <- function(con, rows, recorded_at, logf) {
  counts_before <- .mig021_counts(con)
  sums_before <- .mig021_checksum(con)
  DBI::dbExecute(con, sprintf("DROP INDEX %s", .mig021_index_name))
  logf("Dropped %s (committed).", .mig021_index_name)
  tryCatch({
    db_transaction(con, function(con) {
      for (i in seq_len(nrow(rows))) {
        r <- rows[i, ]
        db_update(con, "sample", uuid = r$uuid,
                  changes = list(datetime = r$date, datetime_start = r$date_start),
                  actor = .mig021_actor,
                  reason = sprintf("021: dust datetime = date, datetime_start = date_start (Robin, 2026-10-17); %s exposed %s collected %s",
                                   r$gauge, format(r$date_start, tz = "Australia/Sydney", "%Y-%m-%d"),
                                   format(r$date, tz = "Australia/Sydney", "%Y-%m-%d")))
      }
      DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                     params = list(.mig021_marker_version, recorded_at))
      .mig021_verify(con)
      if (!identical(counts_before, .mig021_counts(con)) || !identical(sums_before, .mig021_checksum(con))) {
        cli::cli_abort("021 verify failed: something outside the dust datetimes moved.", class = "sampletidy_error")
      }
      NULL
    })
    logf("Updated %d dust samples (committed).", nrow(rows))
  }, finally = {
    if (length(.mig021_index_def(con)) == 0L) {
      DBI::dbExecute(con, .mig021_index_sql)
      logf("Re-created %s.", .mig021_index_name)
    }
  })
  .mig021_verify_index(con)
  invisible(TRUE)
}

mig021_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(
    DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                    params = list(.mig021_marker_version)),
    finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch({ .mig021_verify(check_con); .mig021_verify_index(check_con) },
             finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("021 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  rows <- tryCatch(.mig021_check_preconditions(pre_con), finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  n_dt <- sum(is.na(rows$datetime) | rows$datetime != rows$date)
  n_dts <- sum(is.na(rows$datetime_start) | is.na(rows$date_start) | rows$datetime_start != rows$date_start)
  logf("%d dust samples (%s); datetime differs from date on %d, datetime_start from date_start on %d.",
       nrow(rows), paste(sprintf("%s %d", names(table(rows$gauge)), table(rows$gauge)), collapse = ", "), n_dt, n_dts)
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition passed. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = NA)))
  }

  .mig021_write_csv(rows[, setdiff(names(rows), "gauge")], file.path(csv_dir, "021-dust-datetime-BACKUP-sample.csv"))
  logf("Row backup written to %s", csv_dir)
  backup_path <- mig021_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- .mig021_default(.now, Sys.time())

  with_db_write(function(con) {
    # Re-read under the write lock; the planned set must not have moved.
    again <- .mig021_check_preconditions(con)
    if (!identical(again$uuid, rows$uuid)) cli::cli_abort("021: the dust sample set changed since the dry check.", class = "sampletidy_error")
    .mig021_apply(con, again, recorded_at, logf)
  }, db = db)

  logf("021-dust-datetime migrated successfully.")
  invisible(list(status = "migrated", backup_path = backup_path,
                 restore_command = restore_command, recorded_at = recorded_at))
}
