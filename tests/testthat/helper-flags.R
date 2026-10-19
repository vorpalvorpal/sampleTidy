# Helpers for test-inbox-flags.R (PLAN-18 section 4 / 4.5: import_flags() and
# the Flags section of the status note). Only DEFINES functions - no top-level
# calls.
#
# fl_db() builds an EMPTY synthetic database with the live shape the checks
# read: ensure_schema() ops tables (review_queue, change_log, ...), the CONTRACT
# core tables from helper-db.R, plus `guideline` and `analyte_mask` (live
# tables that the seed DB does not carry). Rows are added with the fl_*()
# builders, which look things up by name so tests read like the data.

# A fixed "now": 2026-10-19 13:00 Sydney (AEDT, UTC+11). Today = 2026-10-19.
fl_now <- function() as.POSIXct("2026-10-19 02:00:00", tz = "UTC")

fl_ts <- function(x) format(as.POSIXct(x, tz = "UTC"), "%Y-%m-%d %H:%M:%S", tz = "UTC")

fl_db <- function(env = parent.frame()) {
  dir <- withr::local_tempdir(.local_envir = env)
  path <- file.path(dir, "flags.duckdb")
  con <- DBI::dbConnect(duckdb::duckdb(), path, read_only = FALSE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  ensure_schema(con)
  for (ddl in .st_test_core_ddl) DBI::dbExecute(con, ddl)
  DBI::dbExecute(con, "CREATE TABLE guideline (
      uuid VARCHAR PRIMARY KEY, uuid_analyte VARCHAR, guideline VARCHAR,
      level INTEGER, level_name VARCHAR, value DOUBLE, comments VARCHAR)")
  DBI::dbExecute(con, "CREATE TABLE analyte_mask (
      uuid_analyte VARCHAR, variant VARCHAR, name VARCHAR, units VARCHAR,
      conversion_constant DOUBLE)")
  path
}

#' Run `fn(con)` on a write connection that is CLOSED again before returning:
#' duckdb refuses a read-only connection (import_flags()) to a file this process
#' already holds open read-write.
fl_with <- function(path, fn) {
  con <- DBI::dbConnect(duckdb::duckdb(), path, read_only = FALSE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  fn(con)
  invisible(path)
}

fl_uuid <- function() uuid::UUIDgenerate()

fl_one <- function(con, sql, ...) {
  r <- DBI::dbGetQuery(con, sql, params = list(...))
  if (nrow(r) == 0) NA_character_ else r[[1]][[1]]
}

#' Feature (+ self-alias, + optional EPA mask name). Returns the feature uuid.
fl_feature <- function(con, name, site = sub("\\..*$", "", name), matrix = "freshwater",
                       epa = NULL) {
  u <- fl_one(con, "SELECT uuid FROM feature WHERE name = ?", name)
  if (!is.na(u)) return(u)
  u <- fl_uuid()
  DBI::dbExecute(con, "INSERT INTO feature (uuid, name, site, matrix, lon, lat)
                       VALUES (?, ?, ?, ?, 150, -33.7)",
                 params = list(u, name, site, matrix))
  DBI::dbExecute(con, "INSERT INTO feature_alias (uuid, uuid_feature, name, alias_key, kind, auto_assign)
                       VALUES (?, ?, ?, ?, 'self', TRUE)",
                 params = list(fl_uuid(), u, name, tolower(name)))
  if (!is.null(epa)) {
    DBI::dbExecute(con, "INSERT INTO feature_mask (uuid_feature, variant, name) VALUES (?, 'EPA', ?)",
                   params = list(u, as.character(epa)))
  }
  u
}

fl_alias_of <- function(con, feature) {
  fl_one(con, "SELECT fa.uuid FROM feature_alias fa JOIN feature f ON f.uuid = fa.uuid_feature
                WHERE f.name = ? AND fa.kind = 'self'", feature)
}

#' Analyte (+ optional EPA pollutant mask). Returns the analyte uuid.
fl_analyte <- function(con, name, units = "mg/L", epa = NULL) {
  u <- fl_one(con, "SELECT uuid FROM analyte WHERE name = ?", name)
  if (!is.na(u)) return(u)
  u <- fl_uuid()
  DBI::dbExecute(con, "INSERT INTO analyte (uuid, name, units) VALUES (?, ?, ?)",
                 params = list(u, name, units))
  if (!is.null(epa)) {
    DBI::dbExecute(con, "INSERT INTO analyte_mask (uuid_analyte, variant, name, units, conversion_constant)
                         VALUES (?, 'EPA', ?, ?, 1)", params = list(u, epa, units))
  }
  u
}

#' lab_method for (analyte, organisation, name, method, units). Returns uuid.
fl_method <- function(con, analyte, organisation = "ALS", name = analyte,
                      method = NA_character_, units = NA_character_) {
  ua <- fl_analyte(con, analyte)
  u <- fl_one(con, "SELECT uuid FROM lab_method WHERE uuid_analyte = ? AND organisation = ?
                     AND name = ? AND COALESCE(method, '') = COALESCE(?, '')
                     AND COALESCE(units, '') = COALESCE(?, '')",
              ua, organisation, name, method, units)
  if (!is.na(u)) return(u)
  u <- fl_uuid()
  DBI::dbExecute(con, "INSERT INTO lab_method (uuid, uuid_analyte, name, method, organisation, units)
                       VALUES (?, ?, ?, ?, ?, ?)",
                 params = list(u, ua, name, method, organisation, units))
  u
}

#' Project by name (created on first use). Returns uuid.
fl_project <- function(con, name, type = "Work order") {
  u <- fl_one(con, "SELECT uuid FROM project WHERE name = ?", name)
  if (!is.na(u)) return(u)
  u <- fl_uuid()
  DBI::dbExecute(con, "INSERT INTO project (uuid, name, type) VALUES (?, ?, ?)",
                 params = list(u, name, type))
  u
}

#' One sample with results.
#'
#' @param at UTC timestamp string "YYYY-MM-DD HH:MM:SS" (or a date "YYYY-MM-DD",
#'   taken as 02:00 UTC = midday Sydney, so the Sydney day is the same).
#' @param results named list analyte -> value, or a list of lists with fields
#'   analyte, value, quantified, rl, method_name, method, units, lab_org.
#' @param ts_col "datetime" (lab/field water) or "date" (gas/dust: date only).
#' @param ingested change_log `at` of the sample's insert (UTC POSIXct), or NULL
#'   for a legacy row with no provenance.
#' @param actor,source_hash the change_log row's actor and source_hash. The
#'   defaults are a pipeline import (ruling R1); a migration actor looks like
#'   '012-detection-limits' or 'migration-...'.
#' @param log "sample" logs the sample insert; "analysis" logs each analysis
#'   insert instead (results added to a sample by a later import).
fl_sample <- function(con, feature, project, at, org = "ALS", results = list(),
                      type = "Work order", ts_col = "datetime",
                      ingested = fl_now() - 10 * 86400, matrix = NULL, site = NULL,
                      actor = "ingest_dir", source_hash = "0123456789abcdef",
                      log = "sample") {
  fargs <- list(con = con, name = feature)
  if (!is.null(matrix)) fargs$matrix <- matrix
  if (!is.null(site)) fargs$site <- site
  do.call(fl_feature, fargs)
  up <- fl_project(con, project, type)
  # Date-only `at`: ALS at 02:00 UTC, field at 01:00 UTC - both midday on the
  # same Sydney day, and distinct so a field and a lab sample of one visit do
  # not collide on the (alias, datetime, project) unique index.
  if (nchar(at) == 10) {
    at <- paste(at, if (identical(toupper(org), "ALS")) "02:00:00" else "01:00:00")
  }
  su <- fl_uuid()
  sql <- sprintf("INSERT INTO \"sample\" (uuid, uuid_feature_alias, uuid_project, %s, organisation)
                  VALUES (?, ?, ?, CAST(? AS TIMESTAMP), ?)", ts_col)
  DBI::dbExecute(con, sql, params = list(su, fl_alias_of(con, feature), up, at, org))
  log_insert <- function(tbl, row) {
    DBI::dbExecute(con, "INSERT INTO change_log (uuid, \"at\", actor, action, tbl, uuid_row, source_hash)
                         VALUES (?, CAST(? AS TIMESTAMP), ?, 'insert', ?, ?, ?)",
                   params = list(fl_uuid(), fl_ts(ingested), actor, tbl, row, source_hash))
  }
  if (!is.null(ingested) && log == "sample") log_insert("sample", su)
  for (i in seq_along(results)) {
    r <- results[[i]]
    if (!is.list(r)) r <- list(analyte = names(results)[[i]], value = r)
    au <- fl_result(con, su, r, default_org = org)
    if (!is.null(ingested) && log == "analysis") log_insert("analysis", au)
  }
  invisible(su)
}

fl_result <- function(con, sample, r, default_org = "ALS") {
  lab_org <- if (is.null(r$lab_org)) default_org else r$lab_org
  mu <- fl_method(con, r$analyte, organisation = lab_org,
                  name = if (is.null(r$method_name)) r$analyte else r$method_name,
                  method = if (is.null(r$method)) NA_character_ else r$method,
                  units = if (is.null(r$units)) NA_character_ else r$units)
  q <- if (is.null(r$quantified)) TRUE else r$quantified
  rl <- if (is.null(r$rl)) NA_real_ else r$rl
  au <- fl_uuid()
  DBI::dbExecute(con, "INSERT INTO analysis (uuid, uuid_sample, uuid_lab, value, quantified, rl_low)
                       VALUES (?, ?, ?, ?, ?, ?)",
                 params = list(au, sample, mu, as.numeric(r$value), q, rl))
  invisible(au)
}

fl_guideline <- function(con, analyte, guideline, level, level_name, value) {
  DBI::dbExecute(con, "INSERT INTO guideline (uuid, uuid_analyte, guideline, level, level_name, value)
                       VALUES (?, ?, ?, ?, ?, ?)",
                 params = list(fl_uuid(), fl_analyte(con, analyte, units = "L/L"),
                               guideline, as.integer(level), level_name, value))
}

# ---- check inputs -------------------------------------------------------------

fl_schedule <- function(...) {
  rows <- list(...)
  df <- do.call(rbind, lapply(rows, function(r) {
    d <- list(site = "B", stream = "acirl_water", months = "all", features = "",
              due_days = "30", from = "2020-01-01", to = "", source = "test")
    d[names(r)] <- lapply(r, as.character)
    as.data.frame(d, stringsAsFactors = FALSE)
  }))
  df[, c("site", "stream", "months", "features", "due_days", "from", "to", "source")]
}

fl_limits <- function(...) {
  rows <- list(...)
  df <- do.call(rbind, lapply(rows, function(r) {
    d <- list(site = "B", feature_pattern = "^B\\.E01$", analyte = "NH3-N", min = "",
              max = "", unit = "mg/L", factor = "1", condition = "L2.4", note = "")
    d[names(r)] <- lapply(r, as.character)
    as.data.frame(d, stringsAsFactors = FALSE)
  }))
  df[, c("site", "feature_pattern", "analyte", "min", "max", "unit", "factor",
         "condition", "note")]
}

fl_requirements <- function(...) {
  rows <- list(...)
  df <- do.call(rbind, lapply(rows, function(r) {
    d <- list(site = "B", licence = "10039", epa_point = "18", pollutant = "pH",
              licence_pollutant = "pH", frequency = "Monthly", required = "12",
              condition = "M2.3", group_item = "")
    d[names(r)] <- lapply(r, as.character)
    if (is.null(r$licence_pollutant)) d$licence_pollutant <- d$pollutant
    as.data.frame(d, stringsAsFactors = FALSE)
  }))
  df[, c("site", "licence", "epa_point", "pollutant", "licence_pollutant",
         "frequency", "required", "condition", "group_item")]
}

fl_points <- function(...) {
  rows <- list(...)
  do.call(rbind, lapply(rows, function(r) {
    data.frame(site = r[[1]], epa_point = as.character(r[[2]]), role = r[[3]],
               stringsAsFactors = FALSE)
  }))
}

fl_checks <- function(schedule = NULL, limits = NULL, requirements = NULL,
                      points = NULL, invoices = NULL) {
  list(schedule = schedule, limits = limits, requirements = requirements,
       points = points, invoices = invoices)
}

# `source` added by ruling 2026-10-19 R12 (the schedule row's source, overdue only).
# `action` added by PLAN-19 R-19.22 (after `source`; NA for every pre-PLAN-19 check).
fl_flag_cols <- c("check", "site", "feature", "analyte", "date", "value", "unit",
                  "threshold", "detail", "key", "source", "action")

#' import_flags() on a DB, warnings/messages muffled.
fl_run <- function(db, checks, now = fl_now()) {
  suppressWarnings(suppressMessages(import_flags(db = db, now = now, checks = checks)))
}

fl_of <- function(flags, check) flags[flags$check == check, , drop = FALSE]

#' Setup for the status-note tests: a flags DB plus empty inbox/report dirs.
fl_status_setup <- function(env = parent.frame()) {
  db <- fl_db(env = env)
  input_dir <- withr::local_tempdir(.local_envir = env)
  report_dir <- withr::local_tempdir(.local_envir = env)
  backup_dir <- withr::local_tempdir(.local_envir = env)
  archive_dir <- withr::local_tempdir(.local_envir = env)
  withr::local_options(list(
    "sampletidy.archive_dir" = archive_dir,
    "sampletidy.live_db" = db,
    "sampletidy.input_dir" = input_dir
  ), .local_envir = env)
  list(db = db, input_dir = input_dir, report_dir = report_dir, backup_dir = backup_dir)
}

fl_status <- function(s, checks, now = fl_now()) {
  suppressWarnings(suppressMessages(
    import_status(db = s$db, input_dir = s$input_dir, report_dir = s$report_dir,
                  now = now, checks = checks)))
}

fl_status_json <- function(s) {
  jsonlite::fromJSON(file.path(s$report_dir, ".import-status.json"), simplifyVector = FALSE)
}
