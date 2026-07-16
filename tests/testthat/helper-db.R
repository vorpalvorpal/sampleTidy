# Seed database helpers for the sampleTidy test suite.
#
# Defines seed_db() and seed_con() exactly per dev/plans/FIXTURES.md
# "Seed DB" section. This file only DEFINES functions - no top-level calls -
# so it can be sourced even before any production R/ functions exist.
#
# seed_db() creates a throwaway DuckDB file, runs the plan-01 ensure_schema()
# migrations (ops tables), creates the CONTRACT core tables (feature,
# feature_alias, feature_mask, analyte, lab_method, project, sample, analysis)
# and inserts exactly the rows pinned in FIXTURES.md. Helpers must not depend
# on the live monitoring.duckdb.
#
# Plan 11 (feature_alias indirection, A48-A55): `sample` no longer points at
# `feature` directly - it points at the alias it arrived under
# (`uuid_feature_alias`, NOT NULL), which nullably resolves to a `feature`.
# Every feature has a self-alias. `lab_method.uuid_analyte` and
# `feature_alias.uuid_feature` are both nullable (dangling = unresolved).
# `analysis.units_raw` records the lab-reported units as provenance (A51).

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
      -- `virtual` is TEST-ONLY drift: the live table has NO `virtual` column
      -- (CONTRACT.md's 'Existing DB schema' block, corrected 2026-07-17).
      -- Left in place - out of scope here, other plans' fixtures may rely on
      -- it - but it is not part of the live shape.
      virtual BOOLEAN,
      -- date_start/date_end DO exist live (CONTRACT.md, corrected block) and
      -- were missing from the test DDL (plan-11 cold review C11). With
      -- site-narrowing deferred (D9), date_end is the ONLY narrowing rule
      -- left in R-11.4 - without this column that criterion is unreachable.
      date_start DATE,
      date_end DATE
    )",
  feature_alias = "
    CREATE TABLE feature_alias (
      uuid VARCHAR PRIMARY KEY,
      uuid_feature VARCHAR,               -- NULLABLE: NULL = dangling
      name VARCHAR NOT NULL,              -- raw, as seen ('bs03alt')
      alias_key VARCHAR NOT NULL,         -- .rc_key(name); NOT unique
      kind VARCHAR,                       -- self | historical_code |
                                           --   descriptive | transcription_error |
                                           --   mask_long | pending
      n_seen INTEGER DEFAULT 0,
      auto_assign BOOLEAN DEFAULT TRUE,   -- FALSE = suggest only, never resolve
      first_seen TIMESTAMP,
      last_seen TIMESTAMP,
      source_hash VARCHAR,
      confirmed_by VARCHAR,               -- NULL = unconfirmed guess
      comments VARCHAR
    )
    -- No DB uniqueness on name/alias_key (R-11.1): the domain forbids it -
    -- the same string may legitimately map to different features at
    -- different times. Identity is the alias's own uuid.
  ",
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
      -- uuid_analyte is nullable (R-11.2): NULL = dangling (unknown analyte).
      -- No NOT NULL was ever declared here, so no DDL change was needed for
      -- this - the test schema was already permissive; noted per the plan.
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
      -- R-11.2/A48: uuid_feature is DROPPED. A sample points at the alias it
      -- arrived under, never at a feature directly; the alias resolves
      -- (nullably) to a feature. Every feature has a self-alias, so a
      -- correctly-labelled sample points at an alias too.
      uuid_feature_alias VARCHAR NOT NULL,
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
      -- R-11.2/A51 (D7): the lab-reported units string, populated always as
      -- provenance. `value` is canonical iff the row's lab_method.uuid_analyte
      -- is non-NULL; when dangling, value is in units_raw and canonical units
      -- are undefined (safe because a dangling analysis is invisible to every
      -- view - INNER JOIN through analyte).
      units_raw VARCHAR,
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
  # pre-existing live monitoring.duckdb business schema). feature_alias is
  # NOT in ensure_schema() either (A50: ops-tables-only); it is declared here
  # for tests and created live by the plan-11 migration.
  for (ddl in .st_test_core_ddl) DBI::dbExecute(con, ddl)

  # feature. f-0001..f-0003 are the original three (unchanged uuids/names).
  # f-0004..f-0007 are added for the plan-11 alias-narrowing fixtures below:
  #  - f-0004/f-0005: the ambiguous-key pair (never narrows - both live).
  #  - f-0006/f-0007: the reused-key pair where f-0006 is defunct
  #    (date_end 2020-06-30, long before any fixture sample date) and
  #    f-0007 is still live - the date_end narrowing auto-resolve case.
  DBI::dbExecute(con, "INSERT INTO feature (uuid, name, site, flow, matrix, date_end) VALUES
    ('f-0001', 'T.S01', 'TestSite', 'surface', 'water', NULL),
    ('f-0002', 'T.S02', 'TestSite', 'surface', 'water', NULL),
    ('f-0003', 'T.MW01', 'TestSite', NULL, 'groundwater', NULL),
    ('f-0004', 'T.S04', 'TestSite', 'surface', 'water', NULL),
    ('f-0005', 'T.S05', 'TestSite', 'surface', 'water', NULL),
    ('f-0006', 'T.S06', 'TestSite', 'surface', 'water', DATE '2020-06-30'),
    ('f-0007', 'T.S07', 'TestSite', 'surface', 'water', NULL)")

  # feature_alias. Every feature gets a self-alias (fa-0001..fa-0003,
  # fa-0011..fa-0014; kind = 'self'), uniform with no special case for
  # "arrived correctly labelled". Plus the plan-11 Fixtures-section fixtures:
  #  - fa-0004 'bs03alt' -> f-0003: a resolved alt-label alias for the
  #    "two different incoming labels for one feature share one sample" test
  #    (R-11.7) - a HIT alongside f-0003's self-alias, not an ambiguity.
  #  - fa-0005/fa-0006 'T.AMBIG2' -> f-0004 AND f-0005: the ambiguous-key
  #    fixture (R-11.4/R-11.10) - both features are live at every fixture
  #    date, so this key never narrows to one.
  #  - fa-0007/fa-0008 'T.REUSED' -> f-0006 (defunct) AND f-0007 (live): the
  #    same-key-one-defunct fixture - narrows to f-0007 at any date after
  #    2020-06-30.
  #  - fa-0009 'T.BORE' -> f-0003, auto_assign FALSE: a non-identifying
  #    descriptive alias that must never enter the candidate set - a
  #    suggestion source only.
  #  - fa-0010 'T.S09', uuid_feature NULL, kind 'pending': an EXISTING
  #    dangling alias a second event re-encounters (R-11.5a natural-key
  #    lookup) - paired with sample s-0003/analysis an-0003 below.
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign,
     first_seen, last_seen, source_hash, confirmed_by) VALUES
    ('fa-0001', 'f-0001', 'T.S01', 'ts01', 'self', 0, TRUE,
     TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00', NULL, NULL),
    ('fa-0002', 'f-0002', 'T.S02', 'ts02', 'self', 0, TRUE,
     TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00', NULL, NULL),
    ('fa-0003', 'f-0003', 'T.MW01', 'tmw01', 'self', 0, TRUE,
     TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00', NULL, NULL),
    ('fa-0004', 'f-0003', 'bs03alt', 'bs03alt', 'transcription_error', 0, TRUE,
     TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-05-01 00:00:00', NULL, NULL),
    ('fa-0005', 'f-0004', 'T.AMBIG2', 'tambig2', 'descriptive', 0, TRUE,
     TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-05-01 00:00:00', NULL, NULL),
    ('fa-0006', 'f-0005', 'T.AMBIG2', 'tambig2', 'descriptive', 0, TRUE,
     TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-05-01 00:00:00', NULL, NULL),
    ('fa-0007', 'f-0006', 'T.REUSED', 'treused', 'historical_code', 0, TRUE,
     TIMESTAMP '2018-01-01 00:00:00', TIMESTAMP '2020-01-01 00:00:00', NULL, NULL),
    ('fa-0008', 'f-0007', 'T.REUSED', 'treused', 'historical_code', 0, TRUE,
     TIMESTAMP '2024-01-01 00:00:00', TIMESTAMP '2025-05-01 00:00:00', NULL, NULL),
    ('fa-0009', 'f-0003', 'T.BORE', 'tbore', 'descriptive', 0, FALSE,
     TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00', NULL, NULL),
    ('fa-0010', NULL, 'T.S09', 'ts09', 'pending', 0, FALSE,
     TIMESTAMP '2025-05-10 08:00:00', TIMESTAMP '2025-05-10 08:00:00',
     'seed-hash-pending-feature', NULL),
    ('fa-0011', 'f-0004', 'T.S04', 'ts04', 'self', 0, TRUE,
     TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00', NULL, NULL),
    ('fa-0012', 'f-0005', 'T.S05', 'ts05', 'self', 0, TRUE,
     TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00', NULL, NULL),
    ('fa-0013', 'f-0006', 'T.S06', 'ts06', 'self', 0, TRUE,
     TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00', NULL, NULL),
    ('fa-0014', 'f-0007', 'T.S07', 'ts07', 'self', 0, TRUE,
     TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00', NULL, NULL)")

  # feature_mask (f-0001/long is an alias; f-0002/epa and f-0003/long both
  # resolve the string "AMBIG" - the deliberate ambiguity fixture). Untouched
  # by plan 11: R-11.4 stops joining feature_mask for candidate matching, but
  # the table and these rows stay for other plans' pre-existing tests.
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
  # lm-0008/lm-0009 are new, dangling (uuid_analyte NULL), plan-11 fixtures:
  #  - lm-0008: paired with sample s-0002/analysis an-0002 (units_raw
  #    'µS/cm', value 965 unconverted) for the R-11.11 confirm-and-convert
  #    test - reuses the pinned 965 -> 0.965 mS/cm conversion already in
  #    FIXTURES.md's "Unit conversions" section.
  #  - lm-0009: an EXISTING dangling method a second event re-encounters
  #    (R-11.5a natural-key lookup) - paired with sample s-0004/analysis
  #    an-0004 below.
  DBI::dbExecute(con, "INSERT INTO lab_method
    (uuid, uuid_analyte, name, method, organisation, rl_low) VALUES
    ('lm-0001', 'a-0001', 'pH Value', 'EA005P: pH by PC Titrator', 'ALS', 0.01),
    ('lm-0002', 'a-0002', 'Fluoride', 'EK040P: Fluoride by PC Titrator', 'ALS', 0.1),
    ('lm-0003', 'a-0003', 'Electrical Conductivity @ 25°C', 'EA010P: Conductivity by PC Titrator', 'ALS', 1),
    ('lm-0004', 'a-0002', 'Fluoride', 'EK040T: Fluoride by alt method', 'ALS', 0.5),
    ('lm-0005', 'a-0001', 'pH', NULL, 'ACIRL', NULL),
    ('lm-0006', 'a-0003', 'EC', NULL, 'ACIRL', NULL),
    ('lm-0007', 'a-0004', 'Temperature', NULL, 'ACIRL', NULL),
    ('lm-0008', NULL, 'EC New Method', 'EA010Z: Conductivity by new method', 'ALS', 1),
    ('lm-0009', NULL, 'Sulphate', 'EA045: Sulphate by IC', 'ALS', 0.5)")

  # project
  DBI::dbExecute(con, "INSERT INTO project (uuid, name, type) VALUES
    ('p-0001', 'XX1234567', 'Work order')")

  # Pre-existing sample + analysis: the "old pipeline already committed this"
  # rows for three-way reconciliation tests. s-0001 / an-0001 is the
  # converted form of "Fluoride <0.1 mg/L" (0.1 mg/L -> 100 µg/L). s-0001 now
  # points at fa-0001 (f-0001's self-alias) rather than at f-0001 directly
  # (R-11.2 drops sample.uuid_feature).
  #
  # s-0002/an-0002: dangling-analyte fixture for R-11.11 (lm-0008, units_raw
  # 'µS/cm', unconverted value 965).
  # s-0003/an-0003: the sample a second event re-encounters via fa-0010's
  # natural key (R-11.5a, feature-pending path) - an-0003 uses an already-
  # resolved lab_method (pH) since only the feature side is dangling here.
  # s-0004/an-0004: the sample a second event re-encounters via lm-0009's
  # natural key (R-11.5a, analyte-pending path) - the feature side is
  # already resolved (fa-0001) since only the analyte side is dangling here.
  DBI::dbExecute(con, "INSERT INTO \"sample\"
    (uuid, uuid_feature_alias, uuid_project, date, datetime, organisation) VALUES
    ('s-0001', 'fa-0001', 'p-0001', TIMESTAMP '2025-05-24 00:00:00',
     TIMESTAMP '2025-05-24 11:45:00', 'ALS'),
    ('s-0002', 'fa-0003', 'p-0001', TIMESTAMP '2025-05-25 00:00:00',
     TIMESTAMP '2025-05-25 09:30:00', 'ALS'),
    ('s-0003', 'fa-0010', 'p-0001', TIMESTAMP '2025-05-10 00:00:00',
     TIMESTAMP '2025-05-10 08:00:00', 'ALS'),
    ('s-0004', 'fa-0001', 'p-0001', TIMESTAMP '2025-05-12 00:00:00',
     TIMESTAMP '2025-05-12 08:15:00', 'ALS')")

  DBI::dbExecute(con, "INSERT INTO analysis
    (uuid, uuid_sample, uuid_lab, value, quantified, rl_low, units_raw) VALUES
    ('an-0001', 's-0001', 'lm-0002', 100, FALSE, 100, NULL),
    ('an-0002', 's-0002', 'lm-0008', 965, TRUE, 1, 'µS/cm'),
    ('an-0003', 's-0003', 'lm-0001', 7.10, TRUE, 0.01, 'pH'),
    ('an-0004', 's-0004', 'lm-0009', 12, TRUE, 0.5, 'mg/L')")

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
