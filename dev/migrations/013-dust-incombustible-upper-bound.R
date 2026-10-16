# Operator-run migration: re-mark dust-incombustible as a non-detect upper bound
# in the months where dust-combustible is itself a non-detect.
#
# Robin's instruction (2026-10-16). ACIRL reports INSOLUBLE SOLIDS (dust-total),
# COMBUSTIBLE MATTER and INCOMBUSTIBLE MATTER for each dust gauge. Where
# combustible is `<0.1` the lab computed incombustible = total - combustible with
# combustible taken as the reporting limit or zero, so the figure is an artefact of
# arithmetic on a non-detect, not a measurement. The most the incombustible
# fraction can be is the whole of the total: a "< total" upper bound.
#
# Per CONTRACT A57 a `<x` row is `quantified = FALSE` with `rl_low = x` (the value
# column carries x too - that is the shape 012 left the combustible rows in).
# For each of the 4 samples where dust-combustible is quantified FALSE:
#   dust-incombustible.value      := that sample's dust-total value
#   dust-incombustible.quantified := FALSE
#   dust-incombustible.rl_low     := that sample's dust-total value
#   dust-incombustible.rl_high    stays NULL
# Nothing else moves. The lab_method `INCOMBUSTIBLE MATTER` is left alone (its
# limit varies by sample, so it has no single rl_low).
#
# Samples (B.D07 / B.D08, exposure start -> collected):
#   B.D08 2023-07 ; B.D07 2023-09 ; B.D07 2024-07/08 ; B.D08 2025-02.
#
# BACKUP OF THE ROWS: the 4 old incombustible rows are dumped to
# `013-dust-incombustible-upper-bound-BACKUP-analysis.csv` beside this file, in
# addition to the verified whole-file backup in `snapshot_dir`.
#
# Marker 1013. Independent of 011/014 (needs 012 only for its combustible rl_low;
# does not read it). Idempotent: marker present -> re-verify, no-op.
#
#   devtools::load_all(".")
#   env <- new.env()
#   sys.source("dev/migrations/013-dust-incombustible-upper-bound.R", envir = env)
#   env$mig013_run(db = st_config("live_db"),
#                  snapshot_dir = st_config("snapshot_dir"), dry_run = TRUE)

.mig013_marker_version <- 1013L
.mig013_actor <- "013-dust-incombustible-upper-bound"
.mig013_lab_comb  <- "734a6092-0af8-4019-841d-86f529109d86"  # *COMBUSTIBLE MATTER
.mig013_lab_incomb <- "e6019d73-d6d8-4b64-806a-d4a647a1da9d" # INCOMBUSTIBLE MATTER
.mig013_lab_total <- "83282ca2-596d-43f5-ac3e-4d01412c167b"  # INSOLUBLE SOLIDS
.mig013_expected_n <- 4L

.mig013_default <- function(x, default) if (is.null(x)) default else x
.mig013_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = list(...))[[1]][[1]])

# One row per sample where combustible is a non-detect: incombustible + total.
.mig013_targets <- function(con) {
  DBI::dbGetQuery(con, "
    SELECT c.uuid_sample, c.value AS comb_value,
           i.uuid AS uuid_incomb, i.value AS incomb_value, i.quantified AS incomb_quantified,
           i.rl_low AS incomb_rl_low, i.rl_high AS incomb_rl_high,
           t.uuid AS uuid_total, t.value AS total_value, t.quantified AS total_quantified
    FROM analysis c
    LEFT JOIN analysis i ON i.uuid_sample = c.uuid_sample AND i.uuid_lab = ?
    LEFT JOIN analysis t ON t.uuid_sample = c.uuid_sample AND t.uuid_lab = ?
    WHERE c.uuid_lab = ? AND c.quantified = FALSE
    ORDER BY c.uuid_sample", params = list(.mig013_lab_incomb, .mig013_lab_total, .mig013_lab_comb))
}

.mig013_counts <- function(con) {
  list(
    analysis = .mig013_scalar(con, "SELECT COUNT(*) FROM analysis"),
    analyte = .mig013_scalar(con, "SELECT COUNT(*) FROM analyte"),
    lab_method = .mig013_scalar(con, "SELECT COUNT(*) FROM lab_method"),
    sample = .mig013_scalar(con, "SELECT COUNT(*) FROM \"sample\"")
  )
}

# Everything outside the 4 incombustible rows must be byte-identical.
.mig013_checksum <- function(con, ids) {
  q <- function(sql, ...) digest::digest(DBI::dbGetQuery(con, sql, params = list(...)), algo = "sha1")
  list(
    analysis_other = q(sprintf("SELECT * FROM analysis WHERE uuid NOT IN (%s) ORDER BY uuid",
                               paste(sprintf("'%s'", ids), collapse = ", "))),
    lab_method = q("SELECT * FROM lab_method ORDER BY uuid"),
    sample = q("SELECT * FROM \"sample\" ORDER BY uuid")
  )
}

.mig013_check_preconditions <- function(con) {
  fail <- function(msg) cli::cli_abort(paste0("013-dust-incombustible-upper-bound: ", msg),
                                       class = "sampletidy_error")
  for (u in c(.mig013_lab_comb, .mig013_lab_incomb, .mig013_lab_total)) {
    lm <- DBI::dbGetQuery(con, "SELECT lm.name, lm.organisation, a.name AS an FROM lab_method lm
                                JOIN analyte a ON a.uuid = lm.uuid_analyte WHERE lm.uuid = ?",
                          params = list(u))
    want <- c("734a6092-0af8-4019-841d-86f529109d86" = "dust-combustible",
              "e6019d73-d6d8-4b64-806a-d4a647a1da9d" = "dust-incombustible",
              "83282ca2-596d-43f5-ac3e-4d01412c167b" = "dust-total")[[u]]
    if (nrow(lm) != 1L || !identical(lm$an[[1]], want) || !identical(lm$organisation[[1]], "ACIRL")) {
      fail(sprintf("lab_method %s is not ACIRL / analyte %s.", u, want))
    }
  }
  tg <- .mig013_targets(con)
  if (nrow(tg) != .mig013_expected_n) {
    fail(sprintf("%d samples have a non-detect dust-combustible, expected %d.", nrow(tg), .mig013_expected_n))
  }
  if (anyNA(tg$uuid_incomb) || anyNA(tg$uuid_total)) fail("a target sample lacks a dust-incombustible or dust-total analysis.")
  if (anyDuplicated(tg$uuid_sample)) fail("a target sample has more than one incombustible/total/combustible row.")
  if (anyNA(tg$total_value) || !all(tg$total_quantified)) fail("a target sample's dust-total is NULL or itself a non-detect.")
  if (any(!is.na(tg$incomb_rl_high))) fail("a target incombustible row already carries rl_high.")
  invisible(tg)
}

.mig013_verify <- function(con) {
  fail <- function(msg) cli::cli_abort(paste0("013-dust-incombustible-upper-bound verify failed: ", msg),
                                       class = "sampletidy_error")
  tg <- .mig013_targets(con)
  if (nrow(tg) != .mig013_expected_n) fail(sprintf("%d target samples, expected %d.", nrow(tg), .mig013_expected_n))
  bad <- tg$incomb_quantified | is.na(tg$incomb_rl_low) | tg$incomb_rl_low != tg$total_value |
    is.na(tg$incomb_value) | tg$incomb_value != tg$total_value | !is.na(tg$incomb_rl_high)
  if (any(bad)) fail("an incombustible row is not `< dust-total` (quantified FALSE, value = rl_low = total, rl_high NULL).")
  other <- .mig013_scalar(con,
    "SELECT COUNT(*) FROM analysis WHERE uuid_lab = ? AND quantified = FALSE", .mig013_lab_incomb)
  if (other != .mig013_expected_n) fail(sprintf("%d non-detect incombustible rows, expected %d.", other, .mig013_expected_n))
  invisible(TRUE)
}

mig013_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- .mig013_default(.now, Sys.time())
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-013-dust-incombustible-upper-bound_%sZ.duckdb", ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig013_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig013_counts(verify_con))) {
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  }
  dest
}

mig013_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(
    DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                    params = list(.mig013_marker_version)),
    finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch(.mig013_verify(check_con), finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("013 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  tg <- tryCatch(.mig013_check_preconditions(pre_con), finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  for (r in seq_len(nrow(tg))) {
    logf("sample %s: incombustible %s (quantified %s) -> `<%s`", tg$uuid_sample[[r]],
         format(tg$incomb_value[[r]]), tg$incomb_quantified[[r]], format(tg$total_value[[r]]))
  }
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition passed. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = NA)))
  }

  # Row backup (CSV) of the old incombustible rows; never overwrite a real one with an empty one.
  csv_path <- file.path(csv_dir, "013-dust-incombustible-upper-bound-BACKUP-analysis.csv")
  with_db_write(function(con) {
    df <- DBI::dbGetQuery(con, sprintf("SELECT * FROM analysis WHERE uuid IN (%s) ORDER BY uuid",
                                       paste(sprintf("'%s'", tg$uuid_incomb), collapse = ", ")))
    if (all(df$quantified)) {   # not yet migrated: these are the original values
      utils::write.csv(df, csv_path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
      back <- utils::read.csv(csv_path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8")
      if (nrow(back) != nrow(df)) cli::cli_abort("013: CSV backup did not round-trip.", class = "sampletidy_error")
    }
  }, db = db)
  logf("Row backup written: %s", basename(csv_path))
  backup_path <- mig013_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- .mig013_default(.now, Sys.time())

  with_db_write(function(con) {
    counts_before <- .mig013_counts(con)
    sums_before <- .mig013_checksum(con, tg$uuid_incomb)
    db_transaction(con, function(con) {
      for (r in seq_len(nrow(tg))) {
        tot <- tg$total_value[[r]]
        db_update(con, "analysis", uuid = tg$uuid_incomb[[r]],
                  changes = list(value = tot, quantified = FALSE, rl_low = tot),
                  actor = .mig013_actor,
                  reason = sprintf("013: dust-combustible is a non-detect in this sample, so incombustible = total - combustible is meaningless; re-marked as the upper bound `<%s` (= dust-total) per A57 (Robin, 2026-10-16)", format(tot)))
      }
      DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                     params = list(.mig013_marker_version, recorded_at))
      .mig013_verify(con)
      if (!identical(counts_before, .mig013_counts(con)) ||
          !identical(sums_before, .mig013_checksum(con, tg$uuid_incomb))) {
        cli::cli_abort("013 verify failed: something other than the 4 incombustible rows moved.",
                       class = "sampletidy_error")
      }
      NULL
    })
    invisible(TRUE)
  }, db = db)

  logf("013-dust-incombustible-upper-bound migrated successfully.")
  invisible(list(status = "migrated", backup_path = backup_path,
                 restore_command = restore_command, recorded_at = recorded_at))
}
