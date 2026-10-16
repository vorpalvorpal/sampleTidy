# Operator-run migration: give the "load A" legacy dust values that the Dust
# Results Database workbook covers their 2 dp workbook figures.
#
# Authorised by Robin, 2026-10-17: "The Load A legacy dust values (2020-09..
# 2021-09 collection, both gauges) are stored at 1 dp, while the Dust Results
# Database workbook gives 2 dp. Replace each value with the workbook figure, but
# only where the workbook value rounds to the stored value at 1 dp. List any
# that don't round, and leave them unchanged. Keep quantified/rl as they are,
# unless the workbook shows a `<`, in which case report it."
#
# ---- WHAT THE EVIDENCE SAYS -----------------------------------------------
#
# "Blaxland WMF Dust Results Database.xlsx" (ACIRL 2400-6989; DG #1 = B.D07,
# DG #2 = B.D08) ends at exposure Dec-2020 (collected 2021-01-01). It therefore
# covers only the 10 load-A samples COLLECTED 2020-09-01..2021-01-01 (5 per
# gauge, 30 values). The other 12 load-A samples (collected 2021-04..2021-09)
# are sourced from the 2400-7127-06 / -07 pdfs, which print 1 dp: nothing to
# replace, untouched. (2021-02/-03 were the year-out rows, re-dated by 018.)
#
# Of the 30 workbook values, every one rounds (half away from zero) to the
# stored 1 dp value; 16 differ from it at 2 dp and are replaced, 14 already
# equal it. No workbook cell in this range carries a `<`; every row stays
# quantified TRUE with rl_low / rl_high NULL. The workbook's INCOMBUSTIBLE
# MATTER column is itself 1 dp, so no incombustible value moves.
# The run re-proves the rounding at run time; a value that failed it would be
# logged and left unchanged (per the ruling), not replaced.
#
# Only `analysis.value` is written. No sample, project or other column moves.
#
# BACKUP OF THE ROWS: `019-legacy-dust-load-a-2dp-BACKUP-analysis.csv` beside
# this file (the 30 analyses), plus the verified whole-file backup in
# `snapshot_dir`.
#
# Marker 1019. Requires 1018. Idempotent: marker present -> re-verify, no-op.
#
#   devtools::load_all(".")
#   env <- new.env()
#   sys.source("dev/migrations/019-legacy-dust-load-a-2dp.R", envir = env)
#   env$mig019_run(db = st_config("live_db"),
#                  snapshot_dir = st_config("snapshot_dir"), dry_run = TRUE)

.mig019_marker_version <- 1019L
.mig019_requires <- 1018L
.mig019_actor <- "019-legacy-dust-load-a-2dp"
.mig019_expected_legacy_n <- 100L
.mig019_source <- "Dust Results Database (2400-6989)"

.mig019_s <- function(uuid, gauge, exposed, collected, old, wb) {
  data.frame(sample = uuid, gauge = gauge, exposed = exposed, collected = collected,
             analyte = c("dust-total", "dust-combustible", "dust-incombustible"),
             old = old, wb = wb, stringsAsFactors = FALSE)
}
# old = stored today (total / combustible / incombustible); wb = the workbook cell.
.mig019_values <- rbind(
  .mig019_s("c0ff1df3-5abe-45b2-9237-7863d666e0e8", "B.D07", "2020-08-01", "2020-09-01", c(0.8, 0.2, 0.6), c(0.83, 0.2, 0.6)),
  .mig019_s("7a18a71c-ccad-4aa7-b5d9-3460dd5d71af", "B.D07", "2020-09-01", "2020-10-01", c(1.6, 0.5, 1.1), c(1.64, 0.54, 1.1)),
  .mig019_s("5e848448-1c22-4320-8de8-641ba707f26e", "B.D07", "2020-10-01", "2020-11-01", c(1.3, 0.6, 0.7), c(1.28, 0.58, 0.7)),
  .mig019_s("79efc3c9-abfa-49a3-af10-43a59a31e9a7", "B.D07", "2020-11-01", "2020-12-01", c(2.9, 1.6, 1.3), c(2.89, 1.59, 1.3)),
  .mig019_s("7c1829e0-0fc9-4483-b24f-2ba81fe2a0b8", "B.D07", "2020-12-01", "2021-01-01", c(2.3, 0.6, 1.7), c(2.33, 0.63, 1.7)),
  .mig019_s("b08ce40d-d9a8-4568-9672-d602958b621d", "B.D08", "2020-08-01", "2020-09-01", c(1.7, 0.3, 1.4), c(1.73, 0.3, 1.4)),
  .mig019_s("2c440426-ffd2-4b6f-9850-91d920db1c69", "B.D08", "2020-09-01", "2020-10-01", c(1.9, 0.4, 1.5), c(1.9, 0.4, 1.5)),
  .mig019_s("1fa19238-8227-4c96-b700-2422274719b0", "B.D08", "2020-10-01", "2020-11-01", c(2.9, 0.5, 2.4), c(2.93, 0.53, 2.4)),
  .mig019_s("19e12727-31a8-433d-951e-220d9c7c0db0", "B.D08", "2020-11-01", "2020-12-01", c(2.0, 0.6, 1.4), c(2.04, 0.64, 1.4)),
  .mig019_s("6864e822-c9df-42dc-99cb-693831f70853", "B.D08", "2020-12-01", "2021-01-01", c(3.2, 2.0, 1.2), c(3.18, 1.98, 1.2))
)

# Half-away-from-zero rounding to 1 dp, immune to binary representation (0.25 -> 0.3).
.mig019_round1 <- function(x) sign(x) * floor(abs(x) * 10 + 0.5 + 1e-9) / 10
.mig019_rounds <- function() abs(.mig019_round1(.mig019_values$wb) - .mig019_values$old) < 1e-9
.mig019_changes <- function() .mig019_values[.mig019_rounds() & abs(.mig019_values$wb - .mig019_values$old) > 1e-9, ]
.mig019_nonrounding <- function() .mig019_values[!.mig019_rounds(), ]

.mig019_default <- function(x, default) if (is.null(x)) default else x
.mig019_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = list(...))[[1]][[1]])
.mig019_ids_sql <- function(ids) paste(sprintf("'%s'", ids), collapse = ", ")
.mig019_syd <- function(col) sprintf("CAST(CAST(timezone('Australia/Sydney', timezone('UTC', %s)) AS DATE) AS VARCHAR)", col)
.mig019_fail <- function(msg) cli::cli_abort(paste0("019-legacy-dust-load-a-2dp: ", msg), class = "sampletidy_error")

.mig019_analysis <- function(con, sample, analyte) {
  DBI::dbGetQuery(con, "
    SELECT a.uuid, a.value, a.quantified, a.rl_low, a.rl_high FROM analysis a
    JOIN lab_method lm ON lm.uuid = a.uuid_lab JOIN analyte an ON an.uuid = lm.uuid_analyte
    WHERE a.uuid_sample = ? AND an.name = ?", params = list(sample, analyte))
}

.mig019_legacy_dust_n <- function(con) {
  .mig019_scalar(con, "
    SELECT COUNT(DISTINCT a.uuid_sample) FROM analysis a
    JOIN lab_method lm ON lm.uuid = a.uuid_lab JOIN analyte an ON an.uuid = lm.uuid_analyte
    WHERE an.name LIKE 'dust-%'")
}

.mig019_counts <- function(con) {
  list(
    analysis = .mig019_scalar(con, "SELECT COUNT(*) FROM analysis"),
    sample = .mig019_scalar(con, "SELECT COUNT(*) FROM \"sample\""),
    feature_alias = .mig019_scalar(con, "SELECT COUNT(*) FROM feature_alias"),
    project = .mig019_scalar(con, "SELECT COUNT(*) FROM project")
  )
}

# Everything the transaction must not touch: all of sample/project, every
# analysis column but `value`, and `value` on every row outside the planned ones.
.mig019_checksum <- function(con, changed_uuids) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  list(
    sample = q("SELECT * FROM \"sample\" ORDER BY uuid"),
    project = q("SELECT * FROM project ORDER BY uuid"),
    analysis_rest = q("SELECT uuid, uuid_sample, uuid_lab, value_chr, quantified, rl_low, rl_high, purpose, comments FROM analysis ORDER BY uuid"),
    analysis_value_other = q(sprintf("SELECT uuid, value FROM analysis WHERE uuid NOT IN (%s) ORDER BY uuid",
                                     .mig019_ids_sql(changed_uuids)))
  )
}

.mig019_check_preconditions <- function(con) {
  fail <- .mig019_fail
  if (.mig019_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig019_requires) == 0L) {
    fail(sprintf("marker %d (018) is required first.", .mig019_requires))
  }
  n_leg <- .mig019_legacy_dust_n(con)
  if (n_leg != .mig019_expected_legacy_n) fail(sprintf("%d samples carry a dust analysis, expected %d.", n_leg, .mig019_expected_legacy_n))
  ids <- unique(.mig019_values$sample)
  rows <- DBI::dbGetQuery(con, sprintf("
    SELECT s.uuid, f.name AS gauge, %s AS sd, %s AS sds FROM \"sample\" s
    JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias JOIN feature f ON f.uuid = fa.uuid_feature
    WHERE s.uuid IN (%s)", .mig019_syd("s.date"), .mig019_syd("s.date_start"), .mig019_ids_sql(ids)))
  if (nrow(rows) != length(ids)) fail(sprintf("%d of %d samples found.", nrow(rows), length(ids)))
  for (i in seq_len(nrow(.mig019_values))) {
    v <- .mig019_values[i, ]; row <- rows[rows$uuid == v$sample, ]
    if (row$gauge != v$gauge || !identical(row$sd, v$collected) || !identical(row$sds, v$exposed)) {
      fail(sprintf("%s is %s %s/%s, expected %s %s/%s.", v$sample, row$gauge, row$sds, row$sd, v$gauge, v$exposed, v$collected))
    }
    a <- .mig019_analysis(con, v$sample, v$analyte)
    if (nrow(a) != 1L || abs(a$value - v$old) > 1e-9 || !isTRUE(a$quantified) || !is.na(a$rl_low) || !is.na(a$rl_high)) {
      fail(sprintf("%s %s is %s (quantified %s), expected quantified %s with no rl.", v$sample, v$analyte,
                   paste(format(a$value), collapse = ","), paste(a$quantified, collapse = ","), format(v$old)))
    }
  }
  invisible(rows)
}

.mig019_verify <- function(con) {
  fail <- function(msg) cli::cli_abort(paste0("019 verify failed: ", msg), class = "sampletidy_error")
  ok <- .mig019_rounds()
  for (i in seq_len(nrow(.mig019_values))) {
    v <- .mig019_values[i, ]; a <- .mig019_analysis(con, v$sample, v$analyte)
    want <- if (ok[[i]]) v$wb else v$old
    if (nrow(a) != 1L || abs(a$value - want) > 1e-9 || !isTRUE(a$quantified)) {
      fail(sprintf("%s %s is %s, expected %s.", v$sample, v$analyte, paste(format(a$value), collapse = ","), format(want)))
    }
  }
  n_leg <- .mig019_legacy_dust_n(con)
  if (n_leg != .mig019_expected_legacy_n) fail(sprintf("%d dust samples.", n_leg))
  invisible(TRUE)
}

mig019_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- .mig019_default(.now, Sys.time())
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-019-legacy-dust-load-a-2dp_%sZ.duckdb", ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig019_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig019_counts(verify_con))) {
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  }
  dest
}

.mig019_write_csv <- function(df, path) {
  out <- df
  for (f in names(out)) if (inherits(out[[f]], "POSIXct")) out[[f]] <- .st_changelog_str(out[[f]])
  utils::write.csv(out, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8")
  if (nrow(back) != nrow(df) || !identical(back$uuid, out$uuid)) {
    cli::cli_abort("019: CSV backup {basename(path)} did not round-trip.", class = "sampletidy_error")
  }
}

mig019_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(
    DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                    params = list(.mig019_marker_version)),
    finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch(.mig019_verify(check_con), finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("019 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  tryCatch(.mig019_check_preconditions(pre_con), finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  ch <- .mig019_changes()
  for (i in seq_len(nrow(ch))) {
    logf("%s %s %s/%s %s: %s -> %s", ch$sample[[i]], ch$gauge[[i]], ch$exposed[[i]], ch$collected[[i]],
         ch$analyte[[i]], format(ch$old[[i]]), format(ch$wb[[i]]))
  }
  nr <- .mig019_nonrounding()
  for (i in seq_len(nrow(nr))) {
    logf("NOT ROUNDING, left unchanged: %s %s %s wb %s stored %s", nr$sample[[i]], nr$gauge[[i]], nr$analyte[[i]],
         format(nr$wb[[i]]), format(nr$old[[i]]))
  }
  logf("%d values replaced, %d already equal the workbook, %d do not round (none expected).",
       nrow(ch), sum(.mig019_rounds()) - nrow(ch), nrow(nr))
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition passed. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = NA)))
  }

  with_db_write(function(con) {
    .mig019_write_csv(DBI::dbGetQuery(con, sprintf("
      SELECT a.* FROM analysis a JOIN lab_method lm ON lm.uuid = a.uuid_lab JOIN analyte an ON an.uuid = lm.uuid_analyte
      WHERE a.uuid_sample IN (%s) AND an.name LIKE 'dust-%%' ORDER BY a.uuid", .mig019_ids_sql(unique(.mig019_values$sample)))),
      file.path(csv_dir, "019-legacy-dust-load-a-2dp-BACKUP-analysis.csv"))
  }, db = db)
  logf("Row backup written to %s", csv_dir)
  backup_path <- mig019_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- .mig019_default(.now, Sys.time())

  with_db_write(function(con) {
    counts_before <- .mig019_counts(con)
    targets <- vapply(seq_len(nrow(ch)), function(i) {
      a <- .mig019_analysis(con, ch$sample[[i]], ch$analyte[[i]])
      if (nrow(a) != 1L) cli::cli_abort("019: {ch$sample[[i]]} {ch$analyte[[i]]} is not one row.", class = "sampletidy_error")
      a$uuid
    }, character(1))
    sums_before <- .mig019_checksum(con, targets)
    db_transaction(con, function(con) {
      for (i in seq_len(nrow(ch))) {
        v <- ch[i, ]
        db_update(con, "analysis", uuid = targets[[i]], changes = list(value = v$wb), actor = .mig019_actor,
                  reason = sprintf("019: workbook wins (Robin, 2026-10-17): %s prints %s at 2 dp for %s exposed %s; legacy load A held %s (1 dp)",
                                   .mig019_source, format(v$wb), v$gauge, v$exposed, format(v$old)))
      }
      DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                     params = list(.mig019_marker_version, recorded_at))
      .mig019_verify(con)
      if (!identical(counts_before, .mig019_counts(con)) || !identical(sums_before, .mig019_checksum(con, targets))) {
        cli::cli_abort("019 verify failed: something outside the planned rows moved.", class = "sampletidy_error")
      }
      NULL
    })
    invisible(TRUE)
  }, db = db)

  logf("019-legacy-dust-load-a-2dp migrated successfully.")
  invisible(list(status = "migrated", backup_path = backup_path,
                 restore_command = restore_command, recorded_at = recorded_at))
}
