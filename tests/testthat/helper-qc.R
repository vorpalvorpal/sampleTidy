# Helpers for the PLAN-19 phase-1 tests (test-qc-*.R): field QC samples and the
# QC flag checks. Only DEFINES functions - no top-level calls.
#
# CONFIDENTIALITY (PLAN-19 R-19.10, R-19.13): every QC code and parent here is
# INVENTED, at the invented site `Q`. Parents use the invented point type `X`
# (Q.X01, Q.X02, ...), which is not a real point type at any site, so an
# invented code->parent pairing can never coincide with a real one under the
# REAL-FIXTURES.md B->Q anonymisation map. Never write a real B.J code here.
#
# qc_db() is fl_db() (helper-flags.R) plus the PLAN-19 section-2 tables as the
# plan specifies them (migration 048's shape), so the flag checks can be tested
# without depending on the migration file. test-qc-migrations.R checks that
# migration 048 really creates these tables and columns.

.qc_test_ddl <- list(
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
      work_order VARCHAR,
      lab_id VARCHAR,
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
      uuid VARCHAR PRIMARY KEY, uuid_report VARCHAR, work_order VARCHAR, kind VARCHAR,
      method VARCHAR, method_name VARCHAR, analyte_raw VARCHAR, cas VARCHAR,
      lab_id VARCHAR, qc_lot VARCHAR, client_id VARCHAR, uuid_sample VARCHAR,
      data_raw VARCHAR, value_pct DOUBLE, limit_low DOUBLE, limit_high DOUBLE,
      comment VARCHAR, days_overdue INTEGER, date_analysed DATE, due_analysis DATE,
      date_extracted DATE, due_extraction DATE, source_page INTEGER)"
)

#' Add the PLAN-19 tables and `analyte.lab_contaminant` to an open connection.
qc_create_tables <- function(con) {
  for (ddl in .qc_test_ddl) DBI::dbExecute(con, ddl)
  cols <- DBI::dbGetQuery(con, "SELECT column_name FROM information_schema.columns
                                 WHERE table_name = 'analyte'")$column_name
  if (!"lab_contaminant" %in% cols) {
    DBI::dbExecute(con, "ALTER TABLE analyte ADD COLUMN lab_contaminant BOOLEAN DEFAULT FALSE")
  }
  invisible(con)
}

#' fl_db() plus the PLAN-19 tables. `tables = FALSE` gives a pre-048 DB.
qc_db <- function(env = parent.frame(), tables = TRUE) {
  db <- fl_db(env = env)
  if (tables) fl_with(db, qc_create_tables)
  db
}

#' A QC feature: `feature` row (virtual), self alias, and its `qc_feature` row.
#' `parent` is a feature name (created with fl_feature() when missing) or NULL.
#' Returns the QC feature's uuid.
qc_add <- function(con, code, qc_type, parent = NULL, date_start = "2026-09-01",
                   date_end = NA_character_, matrix = "freshwater") {
  u <- fl_feature(con, code, matrix = matrix)
  DBI::dbExecute(con, "UPDATE feature SET virtual = TRUE WHERE uuid = ?", params = list(u))
  up <- if (is.null(parent)) NA_character_ else fl_feature(con, parent, matrix = matrix)
  DBI::dbExecute(con, "INSERT INTO qc_feature (uuid_feature, qc_type, uuid_parent, date_start, date_end)
                       VALUES (?, ?, ?, CAST(? AS DATE), CAST(? AS DATE))",
                 params = list(u, qc_type, up, date_start, date_end))
  invisible(u)
}

qc_set_contaminant <- function(con, analyte) {
  DBI::dbExecute(con, "UPDATE analyte SET lab_contaminant = TRUE WHERE name = ?",
                 params = list(analyte))
}

#' One `lab_qc_report` row for a work order.
qc_report <- function(con, work_order, kind = "QCI", status = "parsed",
                      message = NA_character_) {
  DBI::dbExecute(con, "INSERT INTO lab_qc_report (uuid, uuid_asset, work_order, kind, status,
                                                  message, parser_version, parsed_at)
                       VALUES (?, ?, ?, ?, ?, ?, '1', CAST(? AS TIMESTAMP))",
                 params = list(fl_uuid(), fl_uuid(), work_order, kind, status, message,
                               fl_ts(fl_now() - 86400)))
}

# ---- lab results ---------------------------------------------------------------

# An ALS lab result under a method code (the dup/blank checks match on
# uuid_analyte + method code).
qc_lab <- function(analyte, value, rl = NA_real_, quantified = TRUE,
                   method = "EG020T: Total Metals by ICP-MS") {
  list(analyte = analyte, value = value, rl = rl, quantified = quantified,
       method = method, lab_org = "ALS")
}

qc_nd <- function(analyte, rl, method = "EG020T: Total Metals by ICP-MS") {
  qc_lab(analyte, rl, rl = rl, quantified = FALSE, method = method)
}

# ---- check inputs ---------------------------------------------------------------

#' PLAN-19 R-19.33's first rows of dev/qc_criteria.csv, all character.
qc_criteria_df <- function() {
  r <- function(rule, qc_type, analyte_class, param, value, unit) {
    data.frame(rule = rule, qc_type = qc_type, analyte_class = analyte_class, param = param,
               value = value, unit = unit, action = "", source = "SQMP s8 (test)",
               status = "proposed", stringsAsFactors = FALSE)
  }
  rbind(
    r("dup_lor_multiple", "duplicate", "any", "k", "5", "x_LOR"),
    r("dup_rpd", "duplicate", "inorganic", "max", "30", "percent"),
    r("dup_rpd", "duplicate", "organic", "max", "50", "percent"),
    r("dup_absdiff", "duplicate", "any", "max", "2", "x_LOR"),
    r("blank_detect", "any", "any", "threshold", "LOR", "—"),
    r("blank_factor", "any", "any", "f", "5", "x_blank"),
    r("blank_factor", "any", "lab_contaminant", "f", "10", "x_blank"),
    r("carryover", "field_blank;rinsate_blank", "any", "min_analytes", "2", "count"),
    r("filtered_method_regex", "any", "any", "regex",
      "^(E[A-Z][0-9]{3}[A-Z]?F|EG053FG[^:]*|EP002):", "—"),
    r("completeness", "any", "any", "min", "100", "percent")
  )
}

#' PLAN-19 R-19.34's rows, for an (invented) site: the four quarterly types in
#' months 3;6;9;12 and a transport blank in month 3, from 2026-09-01.
qc_requirements_df <- function(site = "Q", from = "2026-09-01", to = "") {
  r <- function(months, qc_type) {
    data.frame(site = site, months = months, qc_type = qc_type, n_min = "1", from = from,
               to = to, source = "SQMP s8 (test)", stringsAsFactors = FALSE)
  }
  rbind(r("3;6;9;12", "duplicate"), r("3;6;9;12", "field_blank"),
        r("3;6;9;12", "rinsate_blank"), r("3;6;9;12", "filter_blank"),
        r("3", "transport_blank"))
}

#' fl_checks() plus `qc` (R-19.23). `qc = NULL` leaves the element out entirely.
qc_checks <- function(criteria = qc_criteria_df(), requirements = qc_requirements_df(),
                      qc = list(criteria = criteria, requirements = requirements), ...) {
  ch <- fl_checks(...)
  if (!is.null(qc)) ch$qc <- qc
  ch
}

.qc_phase1_checks <- c("qc_dup_rpd", "qc_blank_detect", "qc_missing", "qc_unresolved",
                       "lab_qc_missing")
.qc_all_checks <- c("qc_dup_rpd", "qc_blank_detect", "qc_carryover", "qc_missing",
                    "qc_unresolved", "lab_qc_outlier", "holding_time", "lab_qc_missing")
