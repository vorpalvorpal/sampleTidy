# Operator-run migration: record detection limits for the ACIRL field-gas and
# dust methods whose non-detects carry none.
#
# Robin's instruction (2026-10-16). `rl_low` is the lower reporting limit; per
# CONTRACT A57 `rl_high` is populated for `>`-notation rows only, so it stays
# NULL throughout. NO VALUE CHANGES: only `rl_low` is written.
#
#   1. H2S  (lab_method `H2S Reading % v/v`, ACIRL, analyte H2S). Values
#      are 0 / 1e-6 / 2e-6 (0, 1, 2 ppm as an L/L fraction). rl_low = the lowest
#      non-zero H2S value, 1e-6, on the lab_method AND on the 61 analysis rows
#      with quantified FALSE and rl_low NULL.
#      UNITS: asked to set lab_method.units to "the CH4 method's units". Both
#      methods have units NULL and inherit analyte.units = L/L (CH4 and H2S
#      alike), so they already agree; nothing is written to `units`.
#   2. CH4  (lab_method `CH4 Reading % v/v`, ACIRL). The lowest non-zero CH4
#      value is COMPUTED at run time and must be 1e-4 (0.01 %); the method
#      already carries rl_low = 1e-4, so only the analysis rows change: the
#      quantified FALSE / rl_low NULL rows (all value 0).
#   3. dust-combustible (lab_method `*COMBUSTIBLE MATTER`, ACIRL). rl_low = 0.1 on
#      the method and on the quantified FALSE / value 0.1 / rl_low NULL rows (4).
#      dust-incombustible is DELIBERATELY NOT TOUCHED (pending Robin's ruling).
#
# Marker 1012. Independent of 011. Idempotent: marker present -> re-verify, no-op.
#
#   devtools::load_all(".")
#   env <- new.env()
#   sys.source("dev/migrations/012-detection-limits.R", envir = env)
#   env$mig012_run(db = st_config("live_db"),
#                  snapshot_dir = st_config("snapshot_dir"), dry_run = TRUE)

.mig012_marker_version <- 1012L
.mig012_actor <- "012-detection-limits"

.mig012_default <- function(x, default) if (is.null(x)) default else x

# kind: how the nondetect rows are selected. `zero` = value 0; `value` = value == rl.
.mig012_specs <- list(
  list(key = "H2S", lab = "c4b6059b-cf8b-442e-a5ae-bc2dddc3ed12",
       lab_name = "H2S Reading % v/v", analyte = "H2S",
       rl = 1e-6, derive = "min_nonzero", nd_where = "value = 0", n_nd = 61L),
  list(key = "CH4", lab = "76dbf4d5-a33a-4b7f-b201-86cb8ca59b5b",
       lab_name = "CH4 Reading % v/v", analyte = "CH4",
       rl = 1e-4, derive = "min_nonzero", nd_where = "value = 0", n_nd = 11536L),
  list(key = "dust-combustible", lab = "734a6092-0af8-4019-841d-86f529109d86",
       lab_name = "*COMBUSTIBLE MATTER", analyte = "dust-combustible",
       rl = 0.1, derive = "fixed", nd_where = "value = 0.1", n_nd = 4L)
)

.mig012_nd_sql <- function(spec) {
  sprintf("FROM analysis WHERE uuid_lab = ? AND quantified = FALSE AND rl_low IS NULL AND %s",
          spec$nd_where)
}

.mig012_check_preconditions <- function(con) {
  fail <- function(msg) cli::cli_abort(paste0("012-detection-limits: ", msg),
                                       class = "sampletidy_error")
  for (spec in .mig012_specs) {
    lm <- DBI::dbGetQuery(
      con, "SELECT lm.name, lm.organisation, lm.rl_high, lm.rl_low, a.name AS an
              FROM lab_method lm JOIN analyte a ON a.uuid = lm.uuid_analyte WHERE lm.uuid = ?",
      params = list(spec$lab))
    if (nrow(lm) != 1L || !identical(lm$name[[1]], spec$lab_name) ||
        !identical(lm$an[[1]], spec$analyte) || !identical(lm$organisation[[1]], "ACIRL")) {
      fail(sprintf("lab_method %s is not exactly ACIRL `%s` on analyte %s.",
                   spec$lab, spec$lab_name, spec$analyte))
    }
    if (!is.na(lm$rl_high[[1]])) fail(sprintf("`%s` already has an rl_high; A57 says rl_high is for `>` rows only.", spec$lab_name))
    if (!is.na(lm$rl_low[[1]]) && !isTRUE(all.equal(lm$rl_low[[1]], spec$rl))) {
      fail(sprintf("`%s` already has rl_low %s, not NULL or %s. Someone decided otherwise; refusing.",
                   spec$lab_name, lm$rl_low[[1]], spec$rl))
    }
    if (spec$derive == "min_nonzero") {
      got <- DBI::dbGetQuery(con, "SELECT MIN(value) AS m FROM analysis WHERE uuid_lab = ? AND value > 0",
                             params = list(spec$lab))$m[[1]]
      if (!isTRUE(all.equal(got, spec$rl))) {
        fail(sprintf("lowest non-zero %s value is %s, not the expected %s.", spec$key, format(got), spec$rl))
      }
    }
    n <- .mig012_scalar(con, paste("SELECT COUNT(*)", .mig012_nd_sql(spec)), spec$lab)
    done <- .mig012_scalar(con, paste0("SELECT COUNT(*) FROM analysis WHERE uuid_lab = ? AND quantified = FALSE AND rl_low = ", format(spec$rl, scientific = FALSE, digits = 15), " AND ", spec$nd_where), spec$lab)
    if (n != spec$n_nd && !(n == 0L && done == spec$n_nd)) {
      fail(sprintf("%s: %d non-detect rows lack rl_low, expected %d.", spec$key, n, spec$n_nd))
    }
    # Every other quantified-FALSE row on the method must be accounted for.
    other <- .mig012_scalar(con,
      paste0("SELECT COUNT(*) FROM analysis WHERE uuid_lab = ? AND quantified = FALSE AND NOT (", spec$nd_where, ")"),
      spec$lab)
    if (other != 0L) fail(sprintf("%s has %d non-detect rows outside the expected value pattern.", spec$key, other))
  }
  invisible(TRUE)
}

.mig012_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = list(...))[[1]][[1]])

.mig012_counts <- function(con) {
  list(
    analysis = .mig012_scalar(con, "SELECT COUNT(*) FROM analysis"),
    analyte = .mig012_scalar(con, "SELECT COUNT(*) FROM analyte"),
    lab_method = .mig012_scalar(con, "SELECT COUNT(*) FROM lab_method"),
    sample = .mig012_scalar(con, "SELECT COUNT(*) FROM \"sample\"")
  )
}

# Everything except rl_low must be byte-identical: checksum with rl_low blanked
# for the target rows; lab_method with rl_low blanked for the three methods.
.mig012_checksum <- function(con) {
  labs <- paste(sprintf("'%s'", vapply(.mig012_specs, function(s) s$lab, "")), collapse = ", ")
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  list(
    analysis = q(sprintf("SELECT uuid, uuid_sample, uuid_lab, value, value_chr, quantified,
        CASE WHEN uuid_lab IN (%s) THEN NULL ELSE rl_low END AS rl_low, rl_high, purpose, comments
        FROM analysis ORDER BY uuid", labs)),
    lab_method = q(sprintf("SELECT uuid, uuid_analyte, name, method, organisation,
        CASE WHEN uuid IN (%s) THEN NULL ELSE rl_low END AS rl_low, rl_high, reported_as, api,
        uuid_project, uuid_feature, comments, units, conversion_constant, preference
        FROM lab_method ORDER BY uuid", labs)),
    analyte = q("SELECT * FROM analyte ORDER BY uuid"),
    sample = q("SELECT * FROM \"sample\" ORDER BY uuid")
  )
}

.mig012_verify <- function(con) {
  fail <- function(msg) cli::cli_abort(paste0("012-detection-limits verify failed: ", msg),
                                       class = "sampletidy_error")
  for (spec in .mig012_specs) {
    lm <- DBI::dbGetQuery(con, "SELECT rl_low, rl_high, units FROM lab_method WHERE uuid = ?",
                          params = list(spec$lab))
    if (!isTRUE(all.equal(lm$rl_low[[1]], spec$rl))) fail(sprintf("%s method rl_low is %s.", spec$key, format(lm$rl_low[[1]])))
    if (!is.na(lm$rl_high[[1]])) fail(sprintf("%s method rl_high is set.", spec$key))
    if (!is.na(lm$units[[1]])) fail(sprintf("%s method units were written.", spec$key))
    left <- .mig012_scalar(con, paste("SELECT COUNT(*)", .mig012_nd_sql(spec)), spec$lab)
    if (left != 0L) fail(sprintf("%s: %d non-detect rows still lack rl_low.", spec$key, left))
    bad <- .mig012_scalar(con,
      "SELECT COUNT(*) FROM analysis WHERE uuid_lab = ? AND quantified = FALSE AND (rl_low IS NULL OR rl_low <> ?)",
      spec$lab, spec$rl)
    if (bad != 0L) fail(sprintf("%s: %d non-detect rows carry the wrong rl_low.", spec$key, bad))
    hi <- .mig012_scalar(con, "SELECT COUNT(*) FROM analysis WHERE uuid_lab = ? AND rl_high IS NOT NULL", spec$lab)
    if (hi != 0L) fail(sprintf("%s: rl_high set on %d analysis rows.", spec$key, hi))
  }
  # dust-incombustible untouched
  # (013, marker 1013, later re-marked 4 of its rows as `<total` upper bounds with
  # an rl_low; once it has run, this check is moot.)
  if (.mig012_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = 1013") > 0L) return(invisible(TRUE))
  inc <- .mig012_scalar(con, "SELECT COUNT(*) FROM analysis WHERE uuid_lab = 'e6019d73-d6d8-4b64-806a-d4a647a1da9d' AND rl_low IS NOT NULL")
  inc2 <- .mig012_scalar(con, "SELECT COUNT(*) FROM lab_method WHERE uuid = 'e6019d73-d6d8-4b64-806a-d4a647a1da9d' AND rl_low IS NOT NULL")
  if (inc != 0L || inc2 != 0L) fail("dust-incombustible acquired an rl_low; it is pending Robin's ruling.")
  invisible(TRUE)
}

mig012_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- .mig012_default(.now, Sys.time())
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-012-detection-limits_%sZ.duckdb", ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig012_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig012_counts(verify_con))) {
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  }
  dest
}

mig012_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(
    DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                    params = list(.mig012_marker_version)),
    finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch(.mig012_verify(check_con), finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("012-detection-limits already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  tryCatch(.mig012_check_preconditions(pre_con), finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))

  if (isTRUE(dry_run)) {
    for (spec in .mig012_specs) logf("DRY RUN: %s rl_low = %s on the method and %d non-detect rows.", spec$key, format(spec$rl), spec$n_nd)
    logf("DRY RUN: every precondition passed. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = NA)))
  }

  backup_path <- mig012_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- .mig012_default(.now, Sys.time())

  with_db_write(function(con) {
    counts_before <- .mig012_counts(con)
    sums_before <- .mig012_checksum(con)
    db_transaction(con, function(con) {
      for (spec in .mig012_specs) {
        reason <- sprintf("012: %s non-detects have no recorded limit; rl_low = %s (%s) (Robin, 2026-10-16)",
                          spec$key, format(spec$rl),
                          if (spec$derive == "min_nonzero") "lowest non-zero value in the DB" else "ruled value")
        db_update(con, "lab_method", uuid = spec$lab, changes = list(rl_low = spec$rl),
                  actor = .mig012_actor, reason = reason)
        ids <- DBI::dbGetQuery(con, paste("SELECT uuid", .mig012_nd_sql(spec), "ORDER BY uuid"),
                               params = list(spec$lab))$uuid
        for (u in ids) {
          db_update(con, "analysis", uuid = u, changes = list(rl_low = spec$rl),
                    actor = .mig012_actor, reason = reason)
        }
        logf("%s: rl_low = %s on the method and %d analysis row(s).", spec$key, format(spec$rl), length(ids))
      }
      DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                     params = list(.mig012_marker_version, recorded_at))
      .mig012_verify(con)
      if (!identical(counts_before, .mig012_counts(con)) ||
          !identical(sums_before, .mig012_checksum(con))) {
        cli::cli_abort("012-detection-limits verify failed: something other than rl_low moved.",
                       class = "sampletidy_error")
      }
      NULL
    })
    invisible(TRUE)
  }, db = db)

  logf("012-detection-limits migrated successfully.")
  invisible(list(status = "migrated", backup_path = backup_path,
                 restore_command = restore_command, recorded_at = recorded_at))
}
