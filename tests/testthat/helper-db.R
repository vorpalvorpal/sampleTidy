# Seed database helpers for the sampleTidy test suite.
#
# Defines seed_db() and seed_con() exactly per dev/plans/FIXTURES.md
# "Seed DB" section. This file only DEFINES functions - no top-level calls -
# so it can be sourced even before any production R/ functions exist.
#
# seed_db() creates a throwaway DuckDB file, runs the plan-01 ensure_schema()
# migrations (ops tables), creates the CONTRACT core tables (feature,
# feature_mask, analyte, lab_method, project, sample, analysis) and inserts
# exactly the rows pinned in FIXTURES.md. Helpers must not depend on the
# live monitoring.duckdb.

# DDL for the CONTRACT core tables, named list keyed by table name.
.st_test_core_ddl <- list(
  feature = "
    CREATE TABLE feature (
      uuid VARCHAR PRIMARY KEY,
      name VARCHAR,
      site VARCHAR,
      flow VARCHAR,
      matrix VARCHAR,
      geom_wkt VARCHAR,
      virtual BOOLEAN
    )",
  feature_mask = "
    CREATE TABLE feature_mask (
      uuid_feature VARCHAR,
      variant VARCHAR,
      name VARCHAR
    )",
  analyte = "
    CREATE TABLE analyte (
      uuid VARCHAR PRIMARY KEY,
      name VARCHAR,
      units VARCHAR,
      conversion_constant DOUBLE,
      type VARCHAR,
      CAS VARCHAR
    )",
  lab_method = "
    CREATE TABLE lab_method (
      uuid VARCHAR PRIMARY KEY,
      uuid_analyte VARCHAR,
      name VARCHAR,
      method VARCHAR,
      organisation VARCHAR,
      rl_low DOUBLE,
      rl_high DOUBLE,
      reported_as VARCHAR,
      api VARCHAR,
      uuid_project VARCHAR,
      uuid_feature VARCHAR,
      comments VARCHAR
    )",
  project = "
    CREATE TABLE project (
      uuid VARCHAR PRIMARY KEY,
      uuid_parent VARCHAR,
      uuid_root VARCHAR,
      uuid_project VARCHAR,
      name VARCHAR,
      type VARCHAR,
      purpose VARCHAR,
      date_start TIMESTAMP,
      date_end TIMESTAMP,
      regulated_by VARCHAR,
      cypher VARCHAR,
      site VARCHAR,
      value VARCHAR
    )",
  sample = "
    CREATE TABLE \"sample\" (
      uuid VARCHAR PRIMARY KEY,
      uuid_feature VARCHAR,
      uuid_project VARCHAR,
      date TIMESTAMP,
      date_start TIMESTAMP,
      datetime TIMESTAMP,
      datetime_start TIMESTAMP,
      organisation VARCHAR,
      person VARCHAR,
      purpose VARCHAR,
      comments VARCHAR
    )",
  analysis = "
    CREATE TABLE analysis (
      uuid VARCHAR PRIMARY KEY,
      uuid_sample VARCHAR,
      uuid_lab VARCHAR,
      value DOUBLE,
      value_chr VARCHAR,
      quantified BOOLEAN,
      rl_low DOUBLE,
      rl_high DOUBLE,
      purpose VARCHAR,
      comments VARCHAR
    )",
  # No rows pinned by FIXTURES.md "Seed DB" for `asset` - empty table only,
  # provided so plan-09/10 tests (archive_file()/commit_event()'s archival
  # step) have a real table to write into. See PLAN-CHANGE-REQUESTS.md
  # [pipeline-tests] R-9.2/R-9.3.
  asset = "
    CREATE TABLE asset (
      uuid VARCHAR PRIMARY KEY,
      name VARCHAR,
      date TIMESTAMP,
      file_format VARCHAR,
      type VARCHAR,
      purpose VARCHAR,
      organisation VARCHAR,
      person VARCHAR,
      uuid_project VARCHAR,
      uuid_feature VARCHAR,
      filename VARCHAR,
      hash VARCHAR,
      comments VARCHAR
    )"
)

#' Create a throwaway seed DuckDB for tests (FIXTURES.md "Seed DB")
#'
#' Creates a DuckDB file in `dir`, runs `ensure_schema()` (the plan-01 ops
#' migrations), creates the CONTRACT core tables, and inserts exactly the
#' rows pinned in dev/plans/FIXTURES.md. Returns the (closed) db path.
#'
#' @param dir directory to hold the DB file (defaults to a fresh withr temp
#'   dir scoped to the calling test)
#' @return path to the seeded DuckDB file
seed_db <- function(dir = NULL) {
  # NB: a bare `withr::local_tempdir()` used as a *default argument* would bind
  # its deferred cleanup to seed_db()'s own frame (default-arg promises evaluate
  # in the function's frame), deleting the tempdir the instant seed_db() returns
  # and handing the caller a dead path. Register the cleanup on the *caller's*
  # frame instead so the DB lives for the whole calling test.
  if (is.null(dir)) dir <- withr::local_tempdir(.local_envir = parent.frame())
  path <- file.path(dir, "seed.duckdb")
  con <- DBI::dbConnect(duckdb::duckdb(), path, read_only = FALSE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  # Plan-01 ops migrations (ingest_file, ingest_sighting, review_queue,
  # change_log, schema_version).
  ensure_schema(con)

  # CONTRACT core tables (not part of ensure_schema() - those mirror the
  # pre-existing live monitoring.duckdb business schema).
  for (ddl in .st_test_core_ddl) DBI::dbExecute(con, ddl)

  # feature
  DBI::dbExecute(con, "INSERT INTO feature (uuid, name, site, flow, matrix) VALUES
    ('f-0001', 'T.S01', 'TestSite', 'surface', 'water'),
    ('f-0002', 'T.S02', 'TestSite', 'surface', 'water'),
    ('f-0003', 'T.MW01', 'TestSite', NULL, 'groundwater')")

  # feature_mask (f-0001/long is an alias; f-0002/epa and f-0003/long both
  # resolve the string "AMBIG" - the deliberate ambiguity fixture)
  DBI::dbExecute(con, "INSERT INTO feature_mask (uuid_feature, variant, name) VALUES
    ('f-0001', 'long', 'Test Surface 01'),
    ('f-0002', 'epa', 'AMBIG'),
    ('f-0003', 'long', 'AMBIG')")

  # analyte (canonical units deliberately differ from reported units, to
  # force conversion in reconciliation tests)
  DBI::dbExecute(con, "INSERT INTO analyte (uuid, name, units, type, CAS) VALUES
    ('a-0001', 'pH', 'pH', 'field', NULL),
    ('a-0002', 'Fluoride', 'µg/L', 'anion', '16984-48-8'),
    ('a-0003', 'Electrical Conductivity', 'mS/cm', 'field', NULL),
    ('a-0004', 'Temperature', '°C', 'field', NULL)")

  # lab_method (analyte_raw + organisation -> uuid_lab -> uuid_analyte).
  # lm-0002/lm-0004 are the duplicate-method pair (R-8.6): same analyte, ALS;
  # lm-0002 has the lower rl_low (0.1) so it wins.
  DBI::dbExecute(con, "INSERT INTO lab_method
    (uuid, uuid_analyte, name, method, organisation, rl_low) VALUES
    ('lm-0001', 'a-0001', 'pH Value', 'EA005P: pH by PC Titrator', 'ALS', 0.01),
    ('lm-0002', 'a-0002', 'Fluoride', 'EK040P: Fluoride by PC Titrator', 'ALS', 0.1),
    ('lm-0003', 'a-0003', 'Electrical Conductivity @ 25°C', 'EA010P: Conductivity by PC Titrator', 'ALS', 1),
    ('lm-0004', 'a-0002', 'Fluoride', 'EK040T: Fluoride by alt method', 'ALS', 0.5),
    ('lm-0005', 'a-0001', 'pH', NULL, 'ACIRL', NULL),
    ('lm-0006', 'a-0003', 'EC', NULL, 'ACIRL', NULL),
    ('lm-0007', 'a-0004', 'Temperature', NULL, 'ACIRL', NULL)")

  # project
  DBI::dbExecute(con, "INSERT INTO project (uuid, name, type) VALUES
    ('p-0001', 'XX1234567', 'Work order')")

  # Pre-existing sample + analysis: the "old pipeline already committed this"
  # rows for three-way reconciliation tests. s-0001 / an-0001 is the
  # converted form of "Fluoride <0.1 mg/L" (0.1 mg/L -> 100 µg/L).
  DBI::dbExecute(con, "INSERT INTO \"sample\"
    (uuid, uuid_feature, uuid_project, date, datetime, organisation) VALUES
    ('s-0001', 'f-0001', 'p-0001', TIMESTAMP '2025-05-24 00:00:00',
     TIMESTAMP '2025-05-24 11:45:00', 'ALS')")

  DBI::dbExecute(con, "INSERT INTO analysis
    (uuid, uuid_sample, uuid_lab, value, quantified, rl_low) VALUES
    ('an-0001', 's-0001', 'lm-0002', 100, FALSE, 100)")

  # ingest_file seed row for the supersede test.
  DBI::dbExecute(con, "INSERT INTO ingest_file (hash, work_order, revision, state) VALUES
    ('legacy-hash-XX', 'XX1234567', 0, 'archived')")

  path
}

#' Open a read-write connection to a seeded DuckDB
#'
#' @param path path returned by `seed_db()`
#' @return an open DBI connection (caller must disconnect)
seed_con <- function(path) {
  DBI::dbConnect(duckdb::duckdb(), path, read_only = FALSE)
}
