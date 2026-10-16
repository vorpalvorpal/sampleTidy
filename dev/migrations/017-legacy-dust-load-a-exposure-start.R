# Operator-run migration: give the 2020-21 "load A" legacy dust samples (B.D07
# and B.D08) their EXPOSURE date in `date_start`.
#
# Authorised by Robin, 2026-10-17 (ruling 2): "Load A has date_start holding the
# COLLECTION month. Set date_start = collection - 1 month, in the same storage
# representation the rows use. Leave `date` alone unless it is also wrong per
# the workbooks. EXCLUDE the 2021-02 and 2021-03 rows."
#
# Dating convention (Robin, 2026-10-16; 015): EXPOSURE date = `date_start`,
# COLLECTION date = `date`. Gauges go out on the 1st and come in on the 1st of
# the next month.
#
# ---- WHAT THE EVIDENCE SAYS -----------------------------------------------
#
# LOAD A (016's header) is the legacy rows dated 2020-09..2021-07 plus the
# 01:01 UTC rows of 2021-08 and 2021-09: 13 labels x 2 gauges = 26 rows, each
# with date == date_start == the 1st of the COLLECTION month.
#
# Every one of the 22 rows 017 moves has a workbook, and each workbook prints
# the exposure AND collection dates, all on the 1st:
#   DB  "Blaxland WMF Dust Results Database.xlsx" (2400-6852/6989, 2 dp):
#       exposures Aug-20..Dec-20, collected Sep-20..Jan-21 (5 per gauge).
#   P6  2400-7127-06 pdf (1 dp): exposures Mar..May-21, collected Apr..Jun-21.
#   P7  2400-7127-07 pdf (1 dp): exposures Jun..Aug-21, collected Jul..Sep-21.
# Each row's dust-total equals its workbook's (DB at 1 dp). DG #1 = B.D07,
# DG #2 = B.D08. So the stored `date` IS the collection date on all 22 rows and
# is left alone; only `date_start` moves back one month. No row here is
# inferred: there is no row without a workbook.
#
# EXCLUDED (ruling 3, investigated separately, not touched): 0763faf8 / 8c8aef7a
# (2021-02-01) and 4735d1dd / 20fda4f9 (2021-03-01), which hold the DB's
# Jan-2020 and Feb-2020 exposures.
#
# REPRESENTATION / INDEX: as 015 and 016. The new date_start is Sydney midnight
# held as the UTC instant (the legacy form these rows already use). Only
# `date_start` is written; `date`, `datetime` (in 009's ux_sample_identity) and
# `datetime_start` stay as loaded. No project row moves (all 22 link to the
# root "Dust monitoring" project, which has no period). No analysis is touched.
#
# BACKUP OF THE ROWS: `017-legacy-dust-load-a-exposure-start-BACKUP-sample.csv`
# beside this file (the 22 samples), plus the verified whole-file backup in
# `snapshot_dir`.
#
# Marker 1017. Requires 1016. Idempotent: marker present -> re-verify, no-op.
#
#   devtools::load_all(".")
#   env <- new.env()
#   sys.source("dev/migrations/017-legacy-dust-load-a-exposure-start.R", envir = env)
#   env$mig017_run(db = st_config("live_db"),
#                  snapshot_dir = st_config("snapshot_dir"), dry_run = TRUE)

.mig017_marker_version <- 1017L
.mig017_requires <- 1016L
.mig017_actor <- "017-legacy-dust-load-a-exposure-start"
.mig017_expected_legacy_n <- 100L

.mig017_row <- function(uuid, gauge, collected, exposed, total, source) {
  data.frame(uuid = uuid, gauge = gauge, collected = collected, exposed = exposed,
             total = total, source = source, stringsAsFactors = FALSE)
}
# `collected` is the stored Sydney day of BOTH date and date_start today, and
# stays as `date`; `exposed` becomes `date_start`.
.mig017_rows_def <- rbind(
  .mig017_row("c0ff1df3-5abe-45b2-9237-7863d666e0e8", "B.D07", "2020-09-01", "2020-08-01", 0.8,  "Dust Results Database (2400-6989)"),
  .mig017_row("7a18a71c-ccad-4aa7-b5d9-3460dd5d71af", "B.D07", "2020-10-01", "2020-09-01", 1.6,  "Dust Results Database (2400-6989)"),
  .mig017_row("5e848448-1c22-4320-8de8-641ba707f26e", "B.D07", "2020-11-01", "2020-10-01", 1.3,  "Dust Results Database (2400-6989)"),
  .mig017_row("79efc3c9-abfa-49a3-af10-43a59a31e9a7", "B.D07", "2020-12-01", "2020-11-01", 2.9,  "Dust Results Database (2400-6989)"),
  .mig017_row("7c1829e0-0fc9-4483-b24f-2ba81fe2a0b8", "B.D07", "2021-01-01", "2020-12-01", 2.3,  "Dust Results Database (2400-6989)"),
  .mig017_row("2837712e-dc29-4be6-914a-6b786fe6121b", "B.D07", "2021-04-01", "2021-03-01", 0.7,  "2400-7127-06"),
  .mig017_row("80652255-3f2e-4c79-9a96-c96c5496a25c", "B.D07", "2021-05-01", "2021-04-01", 10.3, "2400-7127-06"),
  .mig017_row("5c0e1294-cafd-440d-af89-28346af713ea", "B.D07", "2021-06-01", "2021-05-01", 0.5,  "2400-7127-06"),
  .mig017_row("df41bcb3-2582-4926-b0f1-8bc4bad0aed0", "B.D07", "2021-07-01", "2021-06-01", 0.5,  "2400-7127-07"),
  .mig017_row("0924301a-6f45-4a34-a22b-55d4a9c9a6c9", "B.D07", "2021-08-01", "2021-07-01", 1.3,  "2400-7127-07"),
  .mig017_row("145bd575-ceb0-442d-8fdd-8b72f07d1ba8", "B.D07", "2021-09-01", "2021-08-01", 1.0,  "2400-7127-07"),
  .mig017_row("b08ce40d-d9a8-4568-9672-d602958b621d", "B.D08", "2020-09-01", "2020-08-01", 1.7,  "Dust Results Database (2400-6989)"),
  .mig017_row("2c440426-ffd2-4b6f-9850-91d920db1c69", "B.D08", "2020-10-01", "2020-09-01", 1.9,  "Dust Results Database (2400-6989)"),
  .mig017_row("1fa19238-8227-4c96-b700-2422274719b0", "B.D08", "2020-11-01", "2020-10-01", 2.9,  "Dust Results Database (2400-6989)"),
  .mig017_row("19e12727-31a8-433d-951e-220d9c7c0db0", "B.D08", "2020-12-01", "2020-11-01", 2.0,  "Dust Results Database (2400-6989)"),
  .mig017_row("6864e822-c9df-42dc-99cb-693831f70853", "B.D08", "2021-01-01", "2020-12-01", 3.2,  "Dust Results Database (2400-6989)"),
  .mig017_row("0728b550-6031-4da6-b05a-d98c5e47440f", "B.D08", "2021-04-01", "2021-03-01", 59.4, "2400-7127-06"),
  .mig017_row("ad49a843-193f-4c9a-b3a6-d59250b5bfde", "B.D08", "2021-05-01", "2021-04-01", 1.3,  "2400-7127-06"),
  .mig017_row("955da689-6189-445b-bc28-afaab4f96e2f", "B.D08", "2021-06-01", "2021-05-01", 2.0,  "2400-7127-06"),
  .mig017_row("1cab686d-17d9-45ce-b998-b76f3227daf7", "B.D08", "2021-07-01", "2021-06-01", 0.9,  "2400-7127-07"),
  .mig017_row("ca99940b-b238-4e56-baa8-79e119f78e74", "B.D08", "2021-08-01", "2021-07-01", 1.0,  "2400-7127-07"),
  .mig017_row("9708cb86-4616-4030-8999-6c1d9358f35d", "B.D08", "2021-09-01", "2021-08-01", 1.7,  "2400-7127-07")
)

.mig017_default <- function(x, default) if (is.null(x)) default else x
.mig017_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = list(...))[[1]][[1]])
.mig017_sydney_midnight <- function(day) as.POSIXct(paste(day, "00:00:00"), tz = "Australia/Sydney")
.mig017_ids_sql <- function(ids) paste(sprintf("'%s'", ids), collapse = ", ")
.mig017_syd <- function(col) sprintf("CAST(CAST(timezone('Australia/Sydney', timezone('UTC', %s)) AS DATE) AS VARCHAR)", col)
.mig017_fail <- function(msg) cli::cli_abort(paste0("017-legacy-dust-load-a-exposure-start: ", msg), class = "sampletidy_error")

.mig017_rows <- function(con) {
  DBI::dbGetQuery(con, sprintf("
    SELECT s.uuid, f.name AS gauge, s.date, s.date_start, %s AS sd, %s AS sds
    FROM \"sample\" s
    JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
    JOIN feature f ON f.uuid = fa.uuid_feature
    WHERE s.uuid IN (%s) ORDER BY s.uuid", .mig017_syd("s.date"), .mig017_syd("s.date_start"),
    .mig017_ids_sql(.mig017_rows_def$uuid)))
}

.mig017_total <- function(con, uuid) {
  v <- DBI::dbGetQuery(con, "
    SELECT a.value FROM analysis a
    JOIN lab_method lm ON lm.uuid = a.uuid_lab JOIN analyte an ON an.uuid = lm.uuid_analyte
    WHERE a.uuid_sample = ? AND an.name = 'dust-total'", params = list(uuid))$value
  if (length(v) != 1L) NULL else v
}

.mig017_legacy_dust_n <- function(con) {
  .mig017_scalar(con, "
    SELECT COUNT(DISTINCT a.uuid_sample) FROM analysis a
    JOIN lab_method lm ON lm.uuid = a.uuid_lab JOIN analyte an ON an.uuid = lm.uuid_analyte
    WHERE an.name LIKE 'dust-%'")
}

.mig017_counts <- function(con) {
  list(
    analysis = .mig017_scalar(con, "SELECT COUNT(*) FROM analysis"),
    sample = .mig017_scalar(con, "SELECT COUNT(*) FROM \"sample\""),
    feature_alias = .mig017_scalar(con, "SELECT COUNT(*) FROM feature_alias"),
    project = .mig017_scalar(con, "SELECT COUNT(*) FROM project")
  )
}

# Everything the transaction must not touch.
.mig017_checksum <- function(con) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  ids <- .mig017_ids_sql(.mig017_rows_def$uuid)
  list(
    sample_other = q(sprintf("SELECT * FROM \"sample\" WHERE uuid NOT IN (%s) ORDER BY uuid", ids)),
    sample_target_rest = q(sprintf("SELECT uuid, uuid_feature_alias, uuid_project, date, datetime, datetime_start,
                                    organisation, person, purpose, comments FROM \"sample\" WHERE uuid IN (%s) ORDER BY uuid", ids)),
    analysis = q("SELECT * FROM analysis ORDER BY uuid"),
    project = q("SELECT * FROM project ORDER BY uuid")
  )
}

.mig017_check_preconditions <- function(con) {
  fail <- .mig017_fail
  if (.mig017_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig017_requires) == 0L) {
    fail(sprintf("marker %d (016) is required first.", .mig017_requires))
  }
  n_leg <- .mig017_legacy_dust_n(con)
  if (n_leg != .mig017_expected_legacy_n) fail(sprintf("%d samples carry a dust analysis, expected %d.", n_leg, .mig017_expected_legacy_n))
  rows <- .mig017_rows(con)
  if (nrow(rows) != nrow(.mig017_rows_def)) fail(sprintf("%d of %d samples found.", nrow(rows), nrow(.mig017_rows_def)))
  for (r in seq_len(nrow(.mig017_rows_def))) {
    tg <- .mig017_rows_def[r, ]; row <- rows[rows$uuid == tg$uuid, ]
    if (row$gauge != tg$gauge) fail(sprintf("%s is on %s, expected %s.", tg$uuid, row$gauge, tg$gauge))
    if (!identical(row$sd, tg$collected) || !identical(row$sds, tg$collected)) {
      fail(sprintf("%s is dated %s / %s (Sydney), expected %s for both.", tg$uuid, row$sds, row$sd, tg$collected))
    }
    if (as.numeric(row$date) != as.numeric(.mig017_sydney_midnight(tg$collected)) ||
        as.numeric(row$date_start) != as.numeric(.mig017_sydney_midnight(tg$collected))) {
      fail(sprintf("%s is not in the legacy representation.", tg$uuid))
    }
    tot <- .mig017_total(con, tg$uuid)
    if (is.null(tot) || abs(tot - tg$total) > 1e-9) fail(sprintf("%s dust-total is %s, expected %s.", tg$uuid, format(tot), format(tg$total)))
  }
  invisible(rows)
}

.mig017_verify <- function(con) {
  fail <- function(msg) cli::cli_abort(paste0("017 verify failed: ", msg), class = "sampletidy_error")
  rows <- .mig017_rows(con)
  if (nrow(rows) != nrow(.mig017_rows_def)) fail("samples missing.")
  for (r in seq_len(nrow(.mig017_rows_def))) {
    tg <- .mig017_rows_def[r, ]; row <- rows[rows$uuid == tg$uuid, ]
    if (!identical(row$sd, tg$collected) || !identical(row$sds, tg$exposed) ||
        as.numeric(row$date) != as.numeric(.mig017_sydney_midnight(tg$collected)) ||
        as.numeric(row$date_start) != as.numeric(.mig017_sydney_midnight(tg$exposed))) {
      fail(sprintf("%s is %s / %s, expected %s / %s.", tg$uuid, row$sds, row$sd, tg$exposed, tg$collected))
    }
  }
  n_leg <- .mig017_legacy_dust_n(con)
  if (n_leg != .mig017_expected_legacy_n) fail(sprintf("%d dust samples.", n_leg))
  invisible(TRUE)
}

mig017_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- .mig017_default(.now, Sys.time())
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-017-legacy-dust-load-a-exposure-start_%sZ.duckdb", ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig017_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig017_counts(verify_con))) {
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  }
  dest
}

.mig017_write_csv <- function(df, path) {
  out <- df
  for (f in names(out)) if (inherits(out[[f]], "POSIXct")) out[[f]] <- .st_changelog_str(out[[f]])
  utils::write.csv(out, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8")
  if (nrow(back) != nrow(df) || !identical(back$uuid, out$uuid)) {
    cli::cli_abort("017: CSV backup {basename(path)} did not round-trip.", class = "sampletidy_error")
  }
}

mig017_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(
    DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                    params = list(.mig017_marker_version)),
    finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch(.mig017_verify(check_con), finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("017 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  tryCatch(.mig017_check_preconditions(pre_con), finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  for (r in seq_len(nrow(.mig017_rows_def))) {
    tg <- .mig017_rows_def[r, ]
    logf("%s %s: date_start %s -> %s (date %s kept; %s)", tg$uuid, tg$gauge, tg$collected, tg$exposed, tg$collected, tg$source)
  }
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition passed. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = NA)))
  }

  with_db_write(function(con) {
    .mig017_write_csv(DBI::dbGetQuery(con, sprintf("SELECT * FROM \"sample\" WHERE uuid IN (%s) ORDER BY uuid",
                                                   .mig017_ids_sql(.mig017_rows_def$uuid))),
                      file.path(csv_dir, "017-legacy-dust-load-a-exposure-start-BACKUP-sample.csv"))
  }, db = db)
  logf("Row backup written to %s", csv_dir)
  backup_path <- mig017_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- .mig017_default(.now, Sys.time())

  with_db_write(function(con) {
    counts_before <- .mig017_counts(con)
    sums_before <- .mig017_checksum(con)
    db_transaction(con, function(con) {
      for (r in seq_len(nrow(.mig017_rows_def))) {
        tg <- .mig017_rows_def[r, ]
        db_update(con, "sample", uuid = tg$uuid,
                  changes = list(date_start = .mig017_sydney_midnight(tg$exposed)),
                  actor = .mig017_actor,
                  reason = sprintf("017: dust %s legacy load A held the collection month in date_start; exposed %s, collected %s per %s. Exposure = date_start, collection = date (Robin, 2026-10-16; 017 ruling 2026-10-17)",
                                   tg$gauge, tg$exposed, tg$collected, tg$source))
      }
      DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                     params = list(.mig017_marker_version, recorded_at))
      .mig017_verify(con)
      if (!identical(counts_before, .mig017_counts(con)) || !identical(sums_before, .mig017_checksum(con))) {
        cli::cli_abort("017 verify failed: something outside the planned rows moved.", class = "sampletidy_error")
      }
      NULL
    })
    invisible(TRUE)
  }, db = db)

  logf("017-legacy-dust-load-a-exposure-start migrated successfully.")
  invisible(list(status = "migrated", backup_path = backup_path,
                 restore_command = restore_command, recorded_at = recorded_at))
}
