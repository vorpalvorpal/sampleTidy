# Operator-run migration: the PLAN-19 QC schema (field QC samples and ALS lab QC).
# Marker 1048. Requires 1047.
#
# Authority: Robin, 2026-10-19 (PLAN-19 rulings R19-1..R19-12; section 8).
#
# ---- WHAT ----------------------------------------------------------------------
# Schema only. No data row is written except this migration's marker.
#   * qc_feature      (R-19.1)  one row per field QC code: uuid_feature PK,
#                               qc_type NOT NULL, uuid_parent (NULL = tied to no
#                               point), date_start/date_end of the pairing, comments.
#   * sample_lab_id   (R-19.6)  stored ALS lab sample numbers: uuid_sample,
#                               work_order, lab_id (<WO>-<nnn>), client_id,
#                               source_hash; PK (work_order, lab_id).
#   * lab_qc_report   (R-19.8)  one row per parsed ALS QC asset; uuid_asset UNIQUE.
#   * lab_qc_outlier  (R-19.9)  one row per ALS-reported outlier record.
#   * analyte.lab_contaminant BOOLEAN DEFAULT FALSE (R-19.7). Every existing
#     analyte is FALSE (R19-10 (2): no lab contaminants for now).
#
# The "FK" columns of the plan (qc_feature.uuid_feature/uuid_parent -> feature,
# sample_lab_id.uuid_sample -> sample, lab_qc_report.uuid_asset -> asset,
# lab_qc_outlier.uuid_report -> lab_qc_report, .uuid_sample -> sample) are NOT
# declared as DuckDB FOREIGN KEYs: a declared FK onto feature/sample/asset
# would make DuckDB refuse later UPDATE/DELETE of the referenced rows (the
# registry migrations do both), and DuckDB cannot drop a constraint. The
# checks read them as plain join keys; migration 049 verifies its own.
#
# ---- PRECONDITIONS (any failure aborts; nothing is written) ---------------------
#   * marker 1047 present;
#   * none of the four tables exists; analyte has no lab_contaminant column.
#
# Writes, in one transaction: the four CREATE TABLEs, the ALTER TABLE, the
# marker. Every pre-existing table's row count and the analyte table's
# pre-existing columns are checksummed before and after. Backup: a verified
# whole-file snapshot in `snapshot_dir`. No row backups (no rows are touched).
#
# Idempotent: marker present -> re-verify, no-op.
#
#   devtools::load_all(".")
#   env <- new.env()
#   sys.source("dev/migrations/048-qc-schema.R", envir = env)
#   env$mig048_run(db = st_config("live_db"),
#                  snapshot_dir = st_config("snapshot_dir"), dry_run = TRUE)

.mig048_marker_version <- 1048L
.mig048_requires <- 1047L
.mig048_name <- "048-qc-schema"

.mig048_ddl <- list(
  qc_feature = "
    CREATE TABLE qc_feature (
      uuid_feature VARCHAR PRIMARY KEY,
      qc_type VARCHAR NOT NULL,
      uuid_parent VARCHAR,
      date_start DATE,
      date_end DATE,
      comments VARCHAR)",
  sample_lab_id = "
    CREATE TABLE sample_lab_id (
      uuid_sample VARCHAR,
      work_order VARCHAR NOT NULL,
      lab_id VARCHAR NOT NULL,
      client_id VARCHAR,
      source_hash VARCHAR,
      PRIMARY KEY (work_order, lab_id))",
  lab_qc_report = "
    CREATE TABLE lab_qc_report (
      uuid VARCHAR PRIMARY KEY,
      uuid_asset VARCHAR UNIQUE,
      work_order VARCHAR,
      kind VARCHAR,
      issue_date DATE,
      n_received INTEGER,
      n_analysed INTEGER,
      summary VARCHAR,
      status VARCHAR,
      message VARCHAR,
      parser_version VARCHAR,
      parsed_at TIMESTAMP)",
  lab_qc_outlier = "
    CREATE TABLE lab_qc_outlier (
      uuid VARCHAR PRIMARY KEY,
      uuid_report VARCHAR,
      work_order VARCHAR,
      kind VARCHAR,
      method VARCHAR,
      method_name VARCHAR,
      analyte_raw VARCHAR,
      cas VARCHAR,
      lab_id VARCHAR,
      qc_lot VARCHAR,
      client_id VARCHAR,
      uuid_sample VARCHAR,
      data_raw VARCHAR,
      value_pct DOUBLE,
      limit_low DOUBLE,
      limit_high DOUBLE,
      comment VARCHAR,
      days_overdue INTEGER,
      date_analysed DATE,
      due_analysis DATE,
      date_extracted DATE,
      due_extraction DATE,
      source_page INTEGER)"
)

.mig048_cols <- list(
  qc_feature = c("uuid_feature", "qc_type", "uuid_parent", "date_start", "date_end", "comments"),
  sample_lab_id = c("uuid_sample", "work_order", "lab_id", "client_id", "source_hash"),
  lab_qc_report = c("uuid", "uuid_asset", "work_order", "kind", "issue_date", "n_received",
                    "n_analysed", "summary", "status", "message", "parser_version", "parsed_at"),
  lab_qc_outlier = c("uuid", "uuid_report", "work_order", "kind", "method", "method_name",
                     "analyte_raw", "cas", "lab_id", "qc_lot", "client_id", "uuid_sample",
                     "data_raw", "value_pct", "limit_low", "limit_high", "comment",
                     "days_overdue", "date_analysed", "due_analysis", "date_extracted",
                     "due_extraction", "source_page")
)

.mig048_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = list(...))[[1]][[1]])
.mig048_fail <- function(msg) cli::cli_abort(paste0(.mig048_name, ": ", msg), class = "sampletidy_error")

.mig048_tables <- function(con) {
  DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
                         WHERE table_schema = 'main' AND table_type = 'BASE TABLE'
                         ORDER BY table_name")$table_name
}

.mig048_columns <- function(con, tbl) {
  DBI::dbGetQuery(con, "SELECT column_name FROM information_schema.columns
                         WHERE table_schema = 'main' AND table_name = ? ORDER BY ordinal_position",
                  params = list(tbl))$column_name
}

.mig048_counts <- function(con) {
  tabs <- .mig048_tables(con)
  stats::setNames(lapply(tabs, function(t) .mig048_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
}

# The analyte table over its pre-048 columns, and every other pre-existing
# table's row count.
.mig048_checksum <- function(con, tables) {
  cols <- setdiff(.mig048_columns(con, "analyte"), "lab_contaminant")
  q <- sprintf("SELECT %s FROM analyte ORDER BY uuid", paste(sprintf('"%s"', cols), collapse = ", "))
  list(analyte = digest::digest(DBI::dbGetQuery(con, q), algo = "sha1"),
       counts = .mig048_counts(con)[tables],
       views = digest::digest(DBI::dbGetQuery(con, "SELECT view_name, sql FROM duckdb_views()
                                                     WHERE NOT internal ORDER BY view_name"), algo = "sha1"))
}

.mig048_problems <- function(con) {
  probs <- character(0)
  have <- intersect(names(.mig048_ddl), .mig048_tables(con))
  if (length(have)) probs <- c(probs, sprintf("table(s) already exist: %s", paste(have, collapse = ", ")))
  if (!"analyte" %in% .mig048_tables(con)) probs <- c(probs, "table analyte does not exist")
  if ("lab_contaminant" %in% .mig048_columns(con, "analyte"))
    probs <- c(probs, "analyte.lab_contaminant already exists")
  probs
}

.mig048_check_preconditions <- function(con) {
  if (.mig048_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig048_requires) == 0L)
    .mig048_fail(sprintf("marker %d (047) is required first.", .mig048_requires))
  probs <- .mig048_problems(con)
  if (length(probs)) .mig048_fail(sprintf("%s. Nothing written.", paste(probs, collapse = " | ")))
  invisible(TRUE)
}

.mig048_done_problem <- function(con) {
  if (.mig048_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig048_marker_version) != 1L)
    return("marker 1048 missing")
  for (t in names(.mig048_cols)) {
    got <- .mig048_columns(con, t)
    if (!identical(got, .mig048_cols[[t]]))
      return(sprintf("%s columns are %s", t, paste(got, collapse = ",")))
  }
  ty <- DBI::dbGetQuery(con, "SELECT data_type FROM information_schema.columns
                               WHERE table_name = 'analyte' AND column_name = 'lab_contaminant'")$data_type
  if (!identical(ty, "BOOLEAN")) return("analyte.lab_contaminant is missing or not BOOLEAN")
  # Keys the checks and phase 1b rely on.
  pk <- DBI::dbGetQuery(con, "SELECT table_name, constraint_type, constraint_column_names
                                FROM duckdb_constraints()
                               WHERE table_name IN ('qc_feature', 'sample_lab_id', 'lab_qc_report')")
  has <- function(t, type, cols) any(pk$table_name == t & pk$constraint_type == type &
                                       vapply(pk$constraint_column_names, function(x) setequal(x, cols), logical(1)))
  if (!has("qc_feature", "PRIMARY KEY", "uuid_feature")) return("qc_feature has no PK on uuid_feature")
  if (!has("sample_lab_id", "PRIMARY KEY", c("work_order", "lab_id"))) return("sample_lab_id has no PK (work_order, lab_id)")
  if (!has("lab_qc_report", "UNIQUE", "uuid_asset")) return("lab_qc_report.uuid_asset is not UNIQUE")
  NULL
}

.mig048_verify <- function(con) {
  p <- .mig048_done_problem(con)
  if (!is.null(p)) cli::cli_abort(paste0("048 verify failed: ", p), class = "sampletidy_error")
  invisible(TRUE)
}

mig048_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- if (is.null(.now)) Sys.time() else .now
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig048_name, ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig048_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig048_counts(verify_con)))
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  dest
}

.mig048_apply <- function(con, recorded_at) {
  tables_before <- .mig048_tables(con)
  before <- .mig048_checksum(con, tables_before)
  db_transaction(con, function(con) {
    for (t in names(.mig048_ddl)) DBI::dbExecute(con, .mig048_ddl[[t]])
    DBI::dbExecute(con, "ALTER TABLE analyte ADD COLUMN lab_contaminant BOOLEAN DEFAULT FALSE")
    DBI::dbExecute(con, "UPDATE analyte SET lab_contaminant = FALSE WHERE lab_contaminant IS NULL")
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig048_marker_version, recorded_at))
    .mig048_verify(con)
    n_true <- .mig048_scalar(con, "SELECT COUNT(*) FROM analyte WHERE lab_contaminant IS NOT FALSE")
    if (n_true != 0L) .mig048_fail(sprintf("%d analyte(s) are not lab_contaminant = FALSE.", n_true))
    for (t in names(.mig048_ddl)) {
      if (.mig048_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t)) != 0L) .mig048_fail(sprintf("%s is not empty.", t))
    }
    after <- .mig048_checksum(con, tables_before)
    after$counts$schema_version <- after$counts$schema_version - 1L
    if (!identical(before, after)) .mig048_fail("a pre-existing table, analyte column or view moved.")
    NULL
  })
  invisible(NULL)
}

mig048_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(
    DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                    params = list(.mig048_marker_version)),
    finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch(.mig048_verify(check_con), finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("048 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  n_analyte <- tryCatch({
    .mig048_check_preconditions(pre_con)
    .mig048_scalar(pre_con, "SELECT COUNT(*) FROM analyte")
  }, finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  logf("Will create %s and add analyte.lab_contaminant (FALSE on all %d analytes); no data.",
       paste(names(.mig048_ddl), collapse = ", "), n_analyte)
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition passed. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = NA)))
  }

  backup_path <- mig048_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- if (is.null(.now)) Sys.time() else .now

  with_db_write(function(con) {
    .mig048_check_preconditions(con)   # re-read under the write lock
    .mig048_apply(con, recorded_at)
  }, db = db)

  logf("%s migrated successfully (marker %d): 4 tables, 1 column, no data.",
       .mig048_name, .mig048_marker_version)
  invisible(list(status = "migrated", backup_path = backup_path,
                 restore_command = restore_command, recorded_at = recorded_at))
}
