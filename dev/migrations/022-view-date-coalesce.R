# Operator-run migration: the v_measurement* views take their `date` and their
# preference_rank partition from COALESCE(s.datetime, s.date), not s.datetime.
#
# Authorised by Robin, 2026-10-17 (022 "views"): "Redefine every v_measurement*
# view ... to use COALESCE(s.datetime, s.date) wherever s.datetime is used as
# the measurement date or partition key. Keep every other part of each
# definition byte-identical; take the current definitions from duckdb_views()."
#
# ---- WHY ----------------------------------------------------------------------
#
# 005 built the five views with
#     CAST(timezone('Australia/Sydney', timezone('UTC', s.datetime)) AS DATE)
# as both the `date` column and the PARTITION BY key of preference_rank. A
# sample with a NULL `datetime` - every date-only reading the pipeline commits
# (dust, gas) - therefore shows a NULL `date` and is ranked in a (feature, NULL,
# analyte) partition of its own. COALESCE falls back to `sample.date`, which is
# always populated (Sydney midnight held as the UTC instant, or the pipeline's
# date-only midnight; either way the Sydney-day expression gives its day).
#
# WHAT CHANGES, EXACTLY: in each view's stored SQL the text
#     main.timezone('UTC', s.datetime)
# appears exactly twice (the `date` projection and the partition key) and
# becomes
#     main.timezone('UTC', COALESCE(s.datetime, s.date))
# Nothing else in the SQL is touched: the `s.datetime AS datetime` output column
# is deliberately left as the raw sample column (it is the measurement instant,
# not the date). The new SQL is generated from duckdb_views() at run time, and
# the re-read definition is required to equal it byte-for-byte. The only views
# whose SQL mentions `datetime` are these five; any other is a hard refusal.
#
# No table row is written except this migration's `schema_version` marker.
# Every base table is checksummed before and after; every view keeps its row
# count.
#
# BACKUP: the five old definitions in `022-view-date-coalesce-BACKUP-views.csv`
# beside this file, plus the verified whole-file backup in `snapshot_dir`.
#
# Marker 1022. Requires 1021 (so dust `date` is right the moment the views read
# it) and 1005 (whose views it edits). Idempotent: marker present -> re-verify,
# no-op.
#
#   devtools::load_all(".")
#   env <- new.env()
#   sys.source("dev/migrations/022-view-date-coalesce.R", envir = env)
#   env$mig022_run(db = st_config("live_db"),
#                  snapshot_dir = st_config("snapshot_dir"), dry_run = TRUE)

.mig022_marker_version <- 1022L
.mig022_requires <- c(1005L, 1021L)
.mig022_views <- c("v_measurement", "v_measurement_epa", "v_measurement_gas_report",
                   "v_measurement_long", "v_measurement_old")
.mig022_old <- "main.timezone('UTC', s.datetime)"
.mig022_new <- "main.timezone('UTC', COALESCE(s.datetime, s.date))"

.mig022_default <- function(x, default) if (is.null(x)) default else x
.mig022_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = list(...))[[1]][[1]])
.mig022_fail <- function(msg) cli::cli_abort(paste0("022-view-date-coalesce: ", msg), class = "sampletidy_error")
.mig022_count_fixed <- function(x, pat) lengths(regmatches(x, gregexpr(pat, x, fixed = TRUE)))

.mig022_ensure_icu <- function(con) {
  DBI::dbExecute(con, "INSTALL icu")
  DBI::dbExecute(con, "LOAD icu")
  invisible(NULL)
}

.mig022_view_defs <- function(con) {
  DBI::dbGetQuery(con, "SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
}

.mig022_new_sql <- function(sql) gsub(.mig022_old, .mig022_new, sql, fixed = TRUE)

# The base tables the views read, plus project; only those that exist (a test
# seed has no `project`).
.mig022_tables <- function(con) {
  intersect(c("analysis", "sample", "feature", "feature_alias", "feature_mask", "lab_method", "analyte", "project"),
            DBI::dbListTables(con))
}

.mig022_counts <- function(con) {
  tabs <- .mig022_tables(con)
  out <- lapply(tabs, function(t) .mig022_scalar(con, sprintf("SELECT COUNT(*) FROM \"%s\"", t)))
  names(out) <- tabs
  out
}

.mig022_checksum <- function(con) {
  tabs <- .mig022_tables(con)
  out <- lapply(tabs, function(t) digest::digest(DBI::dbGetQuery(con, sprintf("SELECT * FROM \"%s\" ORDER BY ALL", t)), algo = "sha1"))
  names(out) <- tabs
  out
}

.mig022_view_counts <- function(con) {
  out <- lapply(.mig022_views, function(v) .mig022_scalar(con, sprintf("SELECT COUNT(*) FROM %s", v)))
  names(out) <- .mig022_views
  out
}

.mig022_check_preconditions <- function(con) {
  fail <- .mig022_fail
  have <- DBI::dbGetQuery(con, "SELECT version FROM schema_version")$version
  miss <- setdiff(.mig022_requires, have)
  if (length(miss)) fail(sprintf("marker(s) %s required first.", paste(miss, collapse = ", ")))
  defs <- .mig022_view_defs(con)
  reads_dt <- defs$view_name[grepl("datetime", defs$sql, fixed = TRUE)]
  if (!setequal(reads_dt, .mig022_views)) {
    fail(sprintf("views reading datetime are {%s}, expected exactly {%s}.",
                 paste(reads_dt, collapse = ", "), paste(.mig022_views, collapse = ", ")))
  }
  defs <- defs[match(.mig022_views, defs$view_name), ]
  n_old <- .mig022_count_fixed(defs$sql, .mig022_old)
  n_dt <- .mig022_count_fixed(defs$sql, "s.datetime")
  n_new <- .mig022_count_fixed(defs$sql, "COALESCE(s.datetime")
  for (i in seq_len(nrow(defs))) {
    # 2 timezone() uses + the `s.datetime AS datetime` projection, and nothing else.
    if (n_old[[i]] != 2L || n_dt[[i]] != 3L || n_new[[i]] != 0L ||
        !grepl("s.datetime AS datetime", defs$sql[[i]], fixed = TRUE)) {
      fail(sprintf("%s has %d timezone(s.datetime) uses, %d s.datetime mentions, %d COALESCEs; expected 2, 3, 0.",
                   defs$view_name[[i]], n_old[[i]], n_dt[[i]], n_new[[i]]))
    }
  }
  defs
}

.mig022_verify <- function(con) {
  fail <- function(msg) cli::cli_abort(paste0("022 verify failed: ", msg), class = "sampletidy_error")
  defs <- .mig022_view_defs(con)
  defs <- defs[match(.mig022_views, defs$view_name), ]
  if (anyNA(defs$view_name)) fail("a view is missing.")
  for (i in seq_len(nrow(defs))) {
    s <- defs$sql[[i]]
    if (.mig022_count_fixed(s, .mig022_new) != 2L || .mig022_count_fixed(s, .mig022_old) != 0L ||
        .mig022_count_fixed(s, "s.datetime") != 3L) {
      fail(sprintf("%s does not carry exactly 2 COALESCE(s.datetime, s.date) date expressions.", defs$view_name[[i]]))
    }
  }
  n_null <- .mig022_scalar(con, "SELECT COUNT(*) FROM v_measurement WHERE date IS NULL")
  if (n_null > 0L) fail(sprintf("v_measurement still has %d NULL dates.", n_null))
  invisible(defs)
}

mig022_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- .mig022_default(.now, Sys.time())
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-022-view-date-coalesce_%sZ.duckdb", ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig022_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig022_counts(verify_con))) {
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  }
  dest
}

.mig022_write_csv <- function(df, path) {
  utils::write.csv(df, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8")
  if (!identical(back$view_name, df$view_name) || !identical(back$sql, df$sql)) {
    cli::cli_abort("022: CSV backup {basename(path)} did not round-trip.", class = "sampletidy_error")
  }
}

mig022_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(
    DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                    params = list(.mig022_marker_version)),
    finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch({ .mig022_ensure_icu(check_con); .mig022_verify(check_con) },
             finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("022 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  defs <- tryCatch(.mig022_check_preconditions(pre_con), finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  logf("Will redefine %d views: %s.", nrow(defs), paste(defs$view_name, collapse = ", "))
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition passed. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = NA)))
  }

  .mig022_write_csv(defs, file.path(csv_dir, "022-view-date-coalesce-BACKUP-views.csv"))
  logf("View-definition backup written to %s", csv_dir)
  backup_path <- mig022_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- .mig022_default(.now, Sys.time())

  with_db_write(function(con) {
    .mig022_ensure_icu(con)
    again <- .mig022_check_preconditions(con)
    if (!identical(again$sql, defs$sql)) cli::cli_abort("022: view definitions changed since the dry check.", class = "sampletidy_error")
    want <- .mig022_new_sql(again$sql)
    counts_before <- .mig022_counts(con)
    sums_before <- .mig022_checksum(con)
    vc_before <- .mig022_view_counts(con)
    db_transaction(con, function(con) {
      for (i in seq_len(nrow(again))) {
        DBI::dbExecute(con, sub("^CREATE VIEW ", "CREATE OR REPLACE VIEW ", want[[i]]))
      }
      DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                     params = list(.mig022_marker_version, recorded_at))
      now_defs <- .mig022_verify(con)
      if (!identical(now_defs$sql, want)) {
        cli::cli_abort("022 verify failed: a stored view definition is not the planned text.", class = "sampletidy_error")
      }
      if (!identical(counts_before, .mig022_counts(con)) || !identical(sums_before, .mig022_checksum(con)) ||
          !identical(vc_before, .mig022_view_counts(con))) {
        cli::cli_abort("022 verify failed: a base table or a view's row count moved.", class = "sampletidy_error")
      }
      NULL
    })
    invisible(TRUE)
  }, db = db)

  logf("022-view-date-coalesce migrated successfully.")
  invisible(list(status = "migrated", backup_path = backup_path,
                 restore_command = restore_command, recorded_at = recorded_at))
}
