# Operator-run migration: re-date the four "year-out" legacy dust samples
# (B.D07 and B.D08, stored at 2021-02-01 and 2021-03-01) to the Jan- and
# Feb-2020 exposures they actually hold, and set their values to the 2 dp
# workbook figures.
#
# Authorised by Robin, 2026-10-17: "The legacy dust rows dated 2021-02 and
# 2021-03 on both gauges actually hold the Jan- and Feb-2020 exposures. Re-date
# them: exposure (date_start) 2020-01-01 / 2020-02-01 and collection (date)
# 2020-02-01 / 2020-03-01 ... Set 8c8aef7a's 13.1 to the workbook's 13.06. Also
# set any other value in these 4 samples to the workbook's 2-dp figure where it
# differs."
#
# Dating convention (Robin, 2026-10-16; 015): EXPOSURE date = `date_start`,
# COLLECTION date = `date`. Gauges go out on the 1st and come in on the 1st of
# the next month.
#
# ---- WHAT THE EVIDENCE SAYS -----------------------------------------------
#
# "Blaxland WMF Dust Results Database.xlsx" (ACIRL 2400-6989; DG #1 = B.D07,
# DG #2 = B.D08), sheet "Dust ", prints for these exposures:
#   exposed 2020-01-01, collected 2020-02-01: DG #1 5.4 / 1.1 / 4.3
#                                             DG #2 13.06 / 2.3 / 10.8
#   exposed 2020-02-01, collected 2020-03-01: DG #1 1.03 / 0.2 / 0.8
#                                             DG #2 3.06 / 0.7 / 2.4
# (total / combustible / incombustible, g/m2.month). The four legacy rows hold
# exactly these figures (8c8aef7a's 13.06 at 1 dp, 13.1), and the analyses'
# `comments` carry the workbook's Jan/Feb-2020 Observations text verbatim. They
# were loaded a year late: date == date_start == 2021-02-01 / 2021-03-01.
# Only 8c8aef7a dust-total differs from the workbook; every other value equals it.
#
# THE REAL JAN-2021 AND FEB-2021 EXPOSURES ARE MISSING FROM EVERY FILE FOUND
# (the Dust Results Database ends at exposure Dec-2020; 2400-7127-06 starts at
# exposure Mar-2021; nothing else covers them). After 018 there is no B.D07 or
# B.D08 sample for exposures Jan-2021 or Feb-2021.
#
# REPRESENTATION / INDEX: as 015-017. The new dates are Sydney midnight held as
# the UTC instant (the legacy form). Only `date` and `date_start` are written;
# `datetime` (in 009's ux_sample_identity) and `datetime_start` stay as loaded
# (2021-02-01 / 2021-03-01 11:00 Sydney). All four link to the root
# "Dust monitoring" project (230bd429), which has no period: no project moves.
#
# BACKUP OF THE ROWS: `018-legacy-dust-year-out-2020-BACKUP-{sample,analysis}.csv`
# beside this file (the 4 samples and their 12 analyses), plus the verified
# whole-file backup in `snapshot_dir`.
#
# Marker 1018. Requires 1017. Idempotent: marker present -> re-verify, no-op.
#
#   devtools::load_all(".")
#   env <- new.env()
#   sys.source("dev/migrations/018-legacy-dust-year-out-2020.R", envir = env)
#   env$mig018_run(db = st_config("live_db"),
#                  snapshot_dir = st_config("snapshot_dir"), dry_run = TRUE)

.mig018_marker_version <- 1018L
.mig018_requires <- 1017L
.mig018_actor <- "018-legacy-dust-year-out-2020"
.mig018_expected_legacy_n <- 100L
.mig018_source <- "Dust Results Database (2400-6989)"

.mig018_targets <- data.frame(
  uuid = c("0763faf8-1f05-45bd-8847-6540309f53b8", "8c8aef7a-b9b8-45bc-bc17-36b561b57ff5",
           "4735d1dd-b8b8-4a29-b18c-08cc8f7e1b2c", "20fda4f9-ee18-40e5-844f-26947d1a91fb"),
  gauge = c("B.D07", "B.D08", "B.D07", "B.D08"),
  old = c("2021-02-01", "2021-02-01", "2021-03-01", "2021-03-01"),
  exposed = c("2020-01-01", "2020-01-01", "2020-02-01", "2020-02-01"),
  collected = c("2020-02-01", "2020-02-01", "2020-03-01", "2020-03-01"),
  stringsAsFactors = FALSE
)

# Stored value (`old`) and the workbook's figure (`wb`) for every analysis on
# the four samples. A row is updated only where they differ.
.mig018_values <- data.frame(
  sample = rep(.mig018_targets$uuid, each = 3),
  analyte = rep(c("dust-total", "dust-combustible", "dust-incombustible"), 4),
  old = c(5.4, 1.1, 4.3,   13.1, 2.3, 10.8,   1.03, 0.2, 0.8,   3.06, 0.7, 2.4),
  wb  = c(5.4, 1.1, 4.3,   13.06, 2.3, 10.8,  1.03, 0.2, 0.8,   3.06, 0.7, 2.4),
  stringsAsFactors = FALSE
)
.mig018_changes <- function() .mig018_values[abs(.mig018_values$old - .mig018_values$wb) > 1e-9, ]

.mig018_default <- function(x, default) if (is.null(x)) default else x
.mig018_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = list(...))[[1]][[1]])
.mig018_sydney_midnight <- function(day) as.POSIXct(paste(day, "00:00:00"), tz = "Australia/Sydney")
.mig018_ids_sql <- function(ids) paste(sprintf("'%s'", ids), collapse = ", ")
.mig018_syd <- function(col) sprintf("CAST(CAST(timezone('Australia/Sydney', timezone('UTC', %s)) AS DATE) AS VARCHAR)", col)
.mig018_fail <- function(msg) cli::cli_abort(paste0("018-legacy-dust-year-out-2020: ", msg), class = "sampletidy_error")

.mig018_rows <- function(con) {
  DBI::dbGetQuery(con, sprintf("
    SELECT s.uuid, f.name AS gauge, s.date, s.date_start, %s AS sd, %s AS sds
    FROM \"sample\" s
    JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
    JOIN feature f ON f.uuid = fa.uuid_feature
    WHERE s.uuid IN (%s) ORDER BY s.uuid", .mig018_syd("s.date"), .mig018_syd("s.date_start"),
    .mig018_ids_sql(.mig018_targets$uuid)))
}

# The analysis row (uuid, value, quantified, rl_low, rl_high) of one sample + analyte.
.mig018_analysis <- function(con, sample, analyte) {
  DBI::dbGetQuery(con, "
    SELECT a.uuid, a.value, a.quantified, a.rl_low, a.rl_high FROM analysis a
    JOIN lab_method lm ON lm.uuid = a.uuid_lab JOIN analyte an ON an.uuid = lm.uuid_analyte
    WHERE a.uuid_sample = ? AND an.name = ?", params = list(sample, analyte))
}

.mig018_legacy_dust_n <- function(con) {
  .mig018_scalar(con, "
    SELECT COUNT(DISTINCT a.uuid_sample) FROM analysis a
    JOIN lab_method lm ON lm.uuid = a.uuid_lab JOIN analyte an ON an.uuid = lm.uuid_analyte
    WHERE an.name LIKE 'dust-%'")
}

.mig018_counts <- function(con) {
  list(
    analysis = .mig018_scalar(con, "SELECT COUNT(*) FROM analysis"),
    sample = .mig018_scalar(con, "SELECT COUNT(*) FROM \"sample\""),
    feature_alias = .mig018_scalar(con, "SELECT COUNT(*) FROM feature_alias"),
    project = .mig018_scalar(con, "SELECT COUNT(*) FROM project")
  )
}

# Same-gauge groups sharing a Sydney collection day OR a Sydney exposure day.
.mig018_same_day <- function(con) {
  q <- function(col) DBI::dbGetQuery(con, sprintf("
    SELECT f.name AS gauge, %s AS day, COUNT(*) AS n
    FROM \"sample\" s JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias JOIN feature f ON f.uuid = fa.uuid_feature
    WHERE f.name IN ('B.D07', 'B.D08') AND s.%s IS NOT NULL
    GROUP BY ALL HAVING COUNT(*) > 1", .mig018_syd(paste0("s.", col)), col))
  rbind(q("date"), q("date_start"))
}

# Everything the transaction must not touch.
.mig018_checksum <- function(con) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  ids <- .mig018_ids_sql(.mig018_targets$uuid)
  list(
    sample_other = q(sprintf("SELECT * FROM \"sample\" WHERE uuid NOT IN (%s) ORDER BY uuid", ids)),
    sample_target_rest = q(sprintf("SELECT uuid, uuid_feature_alias, uuid_project, datetime, datetime_start,
                                    organisation, person, purpose, comments FROM \"sample\" WHERE uuid IN (%s) ORDER BY uuid", ids)),
    analysis_other = q(sprintf("SELECT * FROM analysis WHERE uuid_sample NOT IN (%s) ORDER BY uuid", ids)),
    analysis_target_rest = q(sprintf("SELECT uuid, uuid_sample, uuid_lab, value_chr, quantified, rl_low, rl_high, purpose, comments
                                      FROM analysis WHERE uuid_sample IN (%s) ORDER BY uuid", ids)),
    project = q("SELECT * FROM project ORDER BY uuid")
  )
}

.mig018_check_preconditions <- function(con) {
  fail <- .mig018_fail
  if (.mig018_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig018_requires) == 0L) {
    fail(sprintf("marker %d (017) is required first.", .mig018_requires))
  }
  n_leg <- .mig018_legacy_dust_n(con)
  if (n_leg != .mig018_expected_legacy_n) fail(sprintf("%d samples carry a dust analysis, expected %d.", n_leg, .mig018_expected_legacy_n))
  rows <- .mig018_rows(con)
  if (nrow(rows) != nrow(.mig018_targets)) fail(sprintf("%d of %d samples found.", nrow(rows), nrow(.mig018_targets)))
  for (r in seq_len(nrow(.mig018_targets))) {
    tg <- .mig018_targets[r, ]; row <- rows[rows$uuid == tg$uuid, ]
    if (row$gauge != tg$gauge) fail(sprintf("%s is on %s, expected %s.", tg$uuid, row$gauge, tg$gauge))
    if (!identical(row$sd, tg$old) || !identical(row$sds, tg$old)) {
      fail(sprintf("%s is dated %s / %s (Sydney), expected %s for both.", tg$uuid, row$sds, row$sd, tg$old))
    }
    if (as.numeric(row$date) != as.numeric(.mig018_sydney_midnight(tg$old)) ||
        as.numeric(row$date_start) != as.numeric(.mig018_sydney_midnight(tg$old))) {
      fail(sprintf("%s is not in the legacy representation.", tg$uuid))
    }
    if (.mig018_scalar(con, "SELECT COUNT(*) FROM analysis WHERE uuid_sample = ?", tg$uuid) != 3L) {
      fail(sprintf("%s does not carry exactly 3 analyses.", tg$uuid))
    }
  }
  for (i in seq_len(nrow(.mig018_values))) {
    v <- .mig018_values[i, ]; a <- .mig018_analysis(con, v$sample, v$analyte)
    if (nrow(a) != 1L || abs(a$value - v$old) > 1e-9 || !isTRUE(a$quantified)) {
      fail(sprintf("%s %s is %s, expected quantified %s.", v$sample, v$analyte, paste(format(a$value), collapse = ","), format(v$old)))
    }
  }
  # The new days must be free on each gauge (collection and exposure).
  others <- DBI::dbGetQuery(con, sprintf("
    SELECT s.uuid, f.name AS gauge, %s AS sd, %s AS sds FROM \"sample\" s
    JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias JOIN feature f ON f.uuid = fa.uuid_feature
    WHERE f.name IN ('B.D07', 'B.D08') AND s.uuid NOT IN (%s)",
    .mig018_syd("s.date"), .mig018_syd("s.date_start"), .mig018_ids_sql(.mig018_targets$uuid)))
  for (r in seq_len(nrow(.mig018_targets))) {
    tg <- .mig018_targets[r, ]
    hit <- others[others$gauge == tg$gauge & (others$sd %in% tg$collected | others$sds %in% tg$exposed), ]
    if (nrow(hit) > 0) fail(sprintf("%s %s/%s is already held by %s.", tg$gauge, tg$exposed, tg$collected, paste(hit$uuid, collapse = ",")))
  }
  invisible(rows)
}

.mig018_verify <- function(con) {
  fail <- function(msg) cli::cli_abort(paste0("018 verify failed: ", msg), class = "sampletidy_error")
  rows <- .mig018_rows(con)
  if (nrow(rows) != nrow(.mig018_targets)) fail("samples missing.")
  for (r in seq_len(nrow(.mig018_targets))) {
    tg <- .mig018_targets[r, ]; row <- rows[rows$uuid == tg$uuid, ]
    if (!identical(row$sd, tg$collected) || !identical(row$sds, tg$exposed) ||
        as.numeric(row$date) != as.numeric(.mig018_sydney_midnight(tg$collected)) ||
        as.numeric(row$date_start) != as.numeric(.mig018_sydney_midnight(tg$exposed))) {
      fail(sprintf("%s is %s / %s, expected %s / %s.", tg$uuid, row$sds, row$sd, tg$exposed, tg$collected))
    }
  }
  for (i in seq_len(nrow(.mig018_values))) {
    v <- .mig018_values[i, ]; a <- .mig018_analysis(con, v$sample, v$analyte)
    if (nrow(a) != 1L || abs(a$value - v$wb) > 1e-9) fail(sprintf("%s %s is not the workbook's %s.", v$sample, v$analyte, format(v$wb)))
  }
  sd <- .mig018_same_day(con)
  if (nrow(sd) > 0) fail(sprintf("%d same-day groups on B.D07/B.D08.", nrow(sd)))
  n_leg <- .mig018_legacy_dust_n(con)
  if (n_leg != .mig018_expected_legacy_n) fail(sprintf("%d dust samples.", n_leg))
  invisible(TRUE)
}

mig018_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- .mig018_default(.now, Sys.time())
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-018-legacy-dust-year-out-2020_%sZ.duckdb", ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig018_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig018_counts(verify_con))) {
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  }
  dest
}

.mig018_write_csv <- function(df, path) {
  out <- df
  for (f in names(out)) if (inherits(out[[f]], "POSIXct")) out[[f]] <- .st_changelog_str(out[[f]])
  utils::write.csv(out, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8")
  if (nrow(back) != nrow(df) || !identical(back$uuid, out$uuid)) {
    cli::cli_abort("018: CSV backup {basename(path)} did not round-trip.", class = "sampletidy_error")
  }
}

mig018_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(
    DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                    params = list(.mig018_marker_version)),
    finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch(.mig018_verify(check_con), finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("018 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  tryCatch(.mig018_check_preconditions(pre_con), finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  for (r in seq_len(nrow(.mig018_targets))) {
    tg <- .mig018_targets[r, ]
    logf("%s %s: %s/%s -> exposed %s, collected %s", tg$uuid, tg$gauge, tg$old, tg$old, tg$exposed, tg$collected)
  }
  ch <- .mig018_changes()
  for (i in seq_len(nrow(ch))) logf("value %s %s %s -> %s", ch$sample[[i]], ch$analyte[[i]], format(ch$old[[i]]), format(ch$wb[[i]]))
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition passed. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = NA)))
  }

  with_db_write(function(con) {
    ids <- .mig018_ids_sql(.mig018_targets$uuid)
    .mig018_write_csv(DBI::dbGetQuery(con, sprintf("SELECT * FROM \"sample\" WHERE uuid IN (%s) ORDER BY uuid", ids)),
                      file.path(csv_dir, "018-legacy-dust-year-out-2020-BACKUP-sample.csv"))
    .mig018_write_csv(DBI::dbGetQuery(con, sprintf("SELECT * FROM analysis WHERE uuid_sample IN (%s) ORDER BY uuid", ids)),
                      file.path(csv_dir, "018-legacy-dust-year-out-2020-BACKUP-analysis.csv"))
  }, db = db)
  logf("Row backups written to %s", csv_dir)
  backup_path <- mig018_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- .mig018_default(.now, Sys.time())

  with_db_write(function(con) {
    counts_before <- .mig018_counts(con)
    sums_before <- .mig018_checksum(con)
    db_transaction(con, function(con) {
      for (r in seq_len(nrow(.mig018_targets))) {
        tg <- .mig018_targets[r, ]
        db_update(con, "sample", uuid = tg$uuid,
                  changes = list(date_start = .mig018_sydney_midnight(tg$exposed),
                                 date = .mig018_sydney_midnight(tg$collected)),
                  actor = .mig018_actor,
                  reason = sprintf("018: dust %s legacy row dated %s holds the %s exposure a year out; exposed %s, collected %s per %s. The real %s exposure is in no file found. Exposure = date_start, collection = date (Robin, 2026-10-16; 018 ruling 2026-10-17)",
                                   tg$gauge, tg$old, substr(tg$exposed, 1, 7), tg$exposed, tg$collected, .mig018_source,
                                   paste0(as.integer(substr(tg$exposed, 1, 4)) + 1L, substr(tg$exposed, 5, 7))))
      }
      for (i in seq_len(nrow(ch))) {
        v <- ch[i, ]; a <- .mig018_analysis(con, v$sample, v$analyte)
        if (nrow(a) != 1L) cli::cli_abort("018: {v$sample} {v$analyte} is not one row.", class = "sampletidy_error")
        db_update(con, "analysis", uuid = a$uuid, changes = list(value = v$wb), actor = .mig018_actor,
                  reason = sprintf("018: workbook wins (Robin, 2026-10-17): %s prints %s at 2 dp; legacy held %s",
                                   .mig018_source, format(v$wb), format(v$old)))
      }
      DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                     params = list(.mig018_marker_version, recorded_at))
      .mig018_verify(con)
      if (!identical(counts_before, .mig018_counts(con)) || !identical(sums_before, .mig018_checksum(con))) {
        cli::cli_abort("018 verify failed: something outside the planned rows moved.", class = "sampletidy_error")
      }
      NULL
    })
    invisible(TRUE)
  }, db = db)

  logf("018-legacy-dust-year-out-2020 migrated successfully.")
  invisible(list(status = "migrated", backup_path = backup_path,
                 restore_command = restore_command, recorded_at = recorded_at))
}
