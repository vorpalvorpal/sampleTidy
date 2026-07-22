# Plan 13 - PRE-migration DDL fixture for dev/migrations/001-alias-indirection.R
# (Phase-3 D3 / brief "Fixtures" block). `helper-db.R` (plan 11) is the
# POST-migration shape and cannot serve here (its own header says
# `sample.uuid_feature` is DROPPED, it puts `cypher` on `project`, and it has
# no `analyte_mask`). This file builds the shape the migration script must
# read and rewrite: `feature.cypher` populated, `sample.uuid_feature`
# NOT NULL + FK'd straight at `feature`, `lab_method` with no `units` /
# `conversion_constant` and `uuid_analyte` NOT NULL, six views that reference
# `sample.uuid_feature` directly, and an `analyte_mask` table (PLAN-14
# R-14.1's only testable fixture, per the brief - not exercised by this
# plan's own tests).
#
# Deliberately NOT wired into `seed_db()` (helper-db.R): the two DDLs
# describe different epochs of the same tables and merging them would
# reintroduce exactly the drift A-4 / R-11.17 exist to catch.

# Pre-migration DDL, named list keyed by table name. Declares the
# constraints (`sample.uuid_feature` NOT NULL + FK straight at `feature`;
# `lab_method.uuid_analyte` NOT NULL + FK) that duckdb 1.4.1 cannot drop via
# ALTER TABLE (A49) - the reason R-13.1 steps 7-9 must dump/drop/rebuild
# `sample`, `lab_method` and `analysis` rather than ALTER them in place.
.st_pre_migration_ddl <- list(
  feature = "
    CREATE TABLE feature (
      uuid VARCHAR PRIMARY KEY,
      name VARCHAR,
      site VARCHAR,
      flow VARCHAR,
      matrix VARCHAR,
      geom_wkt VARCHAR,
      virtual BOOLEAN,
      date_start DATE,
      date_end DATE,
      lon DOUBLE NOT NULL,
      lat DOUBLE NOT NULL,
      -- The pre-migration source the script imports FROM (step 4). Left
      -- untouched by this migration (retiring it is a later step) - the
      -- criterion 'feature.cypher left untouched' is meaningless without a
      -- populated column to check post-migration.
      cypher VARCHAR
    )",
  feature_mask = "
    CREATE TABLE feature_mask (
      uuid_feature VARCHAR,
      variant VARCHAR,               -- long | old | gas_report | epa
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
  # PLAN-14 R-14.1's fixture (absent from every other test DDL); not
  # exercised by this plan's own tests, but this is the only fixture that
  # makes R-14.1 testable at all (brief 'Fixtures' block), so it must exist
  # here rather than be invented later.
  analyte_mask = "
    CREATE TABLE analyte_mask (
      uuid_analyte VARCHAR,
      variant VARCHAR,
      name VARCHAR
    )",
  lab_method = "
    CREATE TABLE lab_method (
      uuid VARCHAR PRIMARY KEY,
      -- R-13.2 adds units/conversion_constant; NEITHER column exists yet.
      -- uuid_analyte is NOT NULL pre-migration (R-11.2 makes it nullable,
      -- but that is plan 11's code change, not this migration's job) - kept
      -- NOT NULL + FK'd here on purpose, so the fixture matches what the
      -- live pre-migration DB actually enforces today.
      uuid_analyte VARCHAR NOT NULL REFERENCES analyte(uuid),
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
  sample = "
    CREATE TABLE \"sample\" (
      uuid VARCHAR PRIMARY KEY,
      -- The column this migration drops. NOT NULL + FK'd straight at
      -- `feature` - the constraint duckdb 1.4.1 cannot ALTER TABLE ... DROP
      -- CONSTRAINT away (A49), forcing the table rebuild.
      uuid_feature VARCHAR NOT NULL REFERENCES feature(uuid),
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
      -- Wired to both `sample` and `lab_method`, so dropping `analysis` to
      -- free their inbound FKs (step 7) and rebuilding it after (step 9,
      -- 'existing columns unchanged') is exercised for real.
      uuid_sample VARCHAR REFERENCES \"sample\"(uuid),
      uuid_lab VARCHAR REFERENCES lab_method(uuid),
      value DOUBLE,
      value_chr VARCHAR,
      quantified BOOLEAN,
      rl_low DOUBLE,
      rl_high DOUBLE,
      purpose VARCHAR,
      comments VARCHAR
    )"
)

# The six views that reference `sample.uuid_feature` (D4: v_feature_dates,
# v_measurement, v_measurement_{epa,gas_report,long,old}). Each joins
# `sample`/`feature` directly (never through another view of this set), so
# drop/recreate order in steps 6/10 can't accidentally depend on one of
# these views existing. Simplified relative to the live definitions (their
# exact SQL is not given anywhere in the plan) but structurally exact in the
# one way every criterion here cares about: each names `sample.uuid_feature`
# in its FROM/JOIN, so step 6 must drop it and step 10 must recreate it
# joining `sample -> feature_alias -> feature` instead.
.st_pre_migration_views <- c(
  v_feature_dates = "
    CREATE VIEW v_feature_dates AS
      SELECT f.uuid AS uuid_feature, MIN(s.date) AS date_start, MAX(s.date) AS date_end
      FROM \"sample\" s JOIN feature f ON s.uuid_feature = f.uuid
      GROUP BY f.uuid",
  v_measurement = "
    CREATE VIEW v_measurement AS
      SELECT a.uuid AS uuid_analysis, s.uuid AS uuid_sample, f.uuid AS uuid_feature,
             f.name AS feature_name, a.value
      FROM analysis a
      JOIN \"sample\" s ON a.uuid_sample = s.uuid
      JOIN feature f ON s.uuid_feature = f.uuid
      JOIN lab_method lm ON a.uuid_lab = lm.uuid
      JOIN analyte an ON lm.uuid_analyte = an.uuid",
  v_measurement_epa = "
    CREATE VIEW v_measurement_epa AS
      SELECT a.uuid AS uuid_analysis, s.uuid AS uuid_sample, f.uuid AS uuid_feature, a.value
      FROM analysis a
      JOIN \"sample\" s ON a.uuid_sample = s.uuid
      JOIN feature f ON s.uuid_feature = f.uuid
      JOIN feature_mask fm ON fm.uuid_feature = f.uuid AND fm.variant = 'epa'",
  v_measurement_gas_report = "
    CREATE VIEW v_measurement_gas_report AS
      SELECT a.uuid AS uuid_analysis, s.uuid AS uuid_sample, f.uuid AS uuid_feature, a.value
      FROM analysis a
      JOIN \"sample\" s ON a.uuid_sample = s.uuid
      JOIN feature f ON s.uuid_feature = f.uuid
      JOIN feature_mask fm ON fm.uuid_feature = f.uuid AND fm.variant = 'gas_report'",
  v_measurement_long = "
    CREATE VIEW v_measurement_long AS
      SELECT a.uuid AS uuid_analysis, s.uuid AS uuid_sample, f.uuid AS uuid_feature, a.value
      FROM analysis a
      JOIN \"sample\" s ON a.uuid_sample = s.uuid
      JOIN feature f ON s.uuid_feature = f.uuid
      JOIN feature_mask fm ON fm.uuid_feature = f.uuid AND fm.variant = 'long'",
  v_measurement_old = "
    CREATE VIEW v_measurement_old AS
      SELECT a.uuid AS uuid_analysis, s.uuid AS uuid_sample, f.uuid AS uuid_feature, a.value
      FROM analysis a
      JOIN \"sample\" s ON a.uuid_sample = s.uuid
      JOIN feature f ON s.uuid_feature = f.uuid
      JOIN feature_mask fm ON fm.uuid_feature = f.uuid AND fm.variant = 'old'"
)

#' Create a throwaway PRE-migration DuckDB for the R-13.1/R-13.2 test suite
#'
#' Small but structurally exact (brief's "Fixtures" block):
#'  - `feature.cypher` populated with a self-name entry (f-101, must fold
#'    into the self-alias), a duplicated code-shaped entry (f-102, so
#'    `n_seen` counting is observable), a descriptive entry (f-103), and an
#'    `alias_key` reaching TWO features (f-104/f-105 share `AMBIG.KEY1`).
#'  - `feature_mask` with a `long` row that overlaps f-102's cypher entry
#'    (so the upsert-collapse is observable), plus one `old`/`gas_report`/
#'    `epa` row each, which step 5 must NOT import.
#'  - `sample.uuid_feature` NOT NULL + FK'd at `feature` (the column/
#'    constraint this migration drops).
#'  - `lab_method` with no `units`/`conversion_constant`, `uuid_analyte`
#'    NOT NULL.
#'  - `analysis` wired to both, exercising the steps 7-9 FK rebuild.
#'  - `analyte_mask` (empty; PLAN-14 R-14.1's fixture, not this plan's).
#'  - the six views referencing `sample.uuid_feature` (steps 6/10, D20).
#'
#' Does NOT call `ensure_schema()`'s ops migrations beyond creating
#' `schema_version` - the live DB always has the ops tables by the time an
#' operator runs this migration (they only run against a DB `ingest_dir()`
#' has already touched), and the migration's step-0 idempotency marker reads
#' `schema_version`, so it must exist pre-migration for that check to be
#' exercised at all.
#'
#' @param dir directory to hold the DB file (defaults to a fresh withr temp
#'   dir scoped to the calling test).
#' @return path to the seeded, closed, pre-migration DuckDB file.
seed_pre_migration_db <- function(dir = NULL) {
  # Thread the CALLER's frame through explicitly (language-footguns.md R
  # section): a bare/default-arg `withr::local_tempdir()` would bind
  # teardown to this helper's own frame and delete the dir the instant this
  # function returns.
  if (is.null(dir)) dir <- withr::local_tempdir(.local_envir = parent.frame())
  path <- file.path(dir, "pre-migration.duckdb")
  con <- DBI::dbConnect(duckdb::duckdb(), path, read_only = FALSE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  # schema_version only (not the full ops-table set) - the one table the
  # migration's step-0 idempotency marker depends on. Real production
  # `ensure_schema()` is reused rather than re-derived, since a live DB
  # always has this table by the time the migration runs.
  ensure_schema(con)

  for (ddl in .st_pre_migration_ddl) DBI::dbExecute(con, ddl)

  # feature. f-101: self-name fold target. f-102: duplicated code-shaped
  # cypher entry (n_seen counting). f-103: descriptive cypher entry.
  # f-104/f-105: share one cypher entry (`AMBIG.KEY1`) - the ambiguous-key
  # fixture (auto_assign = FALSE on both).
  DBI::dbExecute(con, "INSERT INTO feature
    (uuid, name, site, flow, matrix, lon, lat, cypher) VALUES
    ('f-101', 'PM01', 'PreMigSite', 'surface', 'water', 150.1001, -33.1001, 'PM01'),
    ('f-102', 'PM02', 'PreMigSite', 'surface', 'water', 150.1002, -33.1002, 'B.S02a, B.S02a'),
    ('f-103', 'PM03', 'PreMigSite', 'surface', 'water', 150.1003, -33.1003, 'old landfill bore'),
    ('f-104', 'PM04', 'PreMigSite', 'surface', 'water', 150.1004, -33.1004, 'AMBIG.KEY1'),
    ('f-105', 'PM05', 'PreMigSite', 'surface', 'water', 150.1005, -33.1005, 'AMBIG.KEY1')")

  # feature_mask: 'long' on f-102 overlaps its cypher entry's normalised key
  # (upsert-collapse, never error); 'old'/'gas_report'/'epa' rows step 5
  # must NOT import.
  DBI::dbExecute(con, "INSERT INTO feature_mask (uuid_feature, variant, name) VALUES
    ('f-102', 'long', 'B.S02a'),
    ('f-103', 'old', 'Old PM Three Name'),
    ('f-101', 'gas_report', 'GR-PM01'),
    ('f-104', 'epa', 'EPA-PM04')")

  DBI::dbExecute(con, "INSERT INTO analyte (uuid, name, units, type, CAS) VALUES
    ('a-901', 'Analyte X', 'mg/L', 'anion', NULL)")

  DBI::dbExecute(con, "INSERT INTO lab_method
    (uuid, uuid_analyte, name, method, organisation, rl_low) VALUES
    ('lm-901', 'a-901', 'Analyte X by IC', 'EK-X', 'ALS', 0.1)")

  # sample: one per feature f-101..f-103 (f-104/f-105 left sample-free -
  # they only need to exist for the ambiguous-cypher-key test). All wired to
  # `feature` directly via the pre-migration `uuid_feature` column.
  DBI::dbExecute(con, "INSERT INTO \"sample\"
    (uuid, uuid_feature, date, datetime, organisation) VALUES
    ('s-901', 'f-101', TIMESTAMP '2024-01-10 00:00:00', TIMESTAMP '2024-01-10 09:00:00', 'ALS'),
    ('s-902', 'f-102', TIMESTAMP '2024-01-11 00:00:00', TIMESTAMP '2024-01-11 09:00:00', 'ALS'),
    ('s-903', 'f-103', TIMESTAMP '2024-01-12 00:00:00', TIMESTAMP '2024-01-12 09:00:00', 'ALS')")

  # analysis: one row per sample, all resolved (quantified), so
  # `v_measurement` has a nonzero, stable row count to compare pre/post
  # migration (R-13.1 step-11 verify / D20).
  DBI::dbExecute(con, "INSERT INTO analysis
    (uuid, uuid_sample, uuid_lab, value, quantified, rl_low) VALUES
    ('an-901', 's-901', 'lm-901', 1.1, TRUE, 0.1),
    ('an-902', 's-902', 'lm-901', 2.2, TRUE, 0.1),
    ('an-903', 's-903', 'lm-901', 3.3, TRUE, 0.1)")

  for (view_ddl in .st_pre_migration_views) DBI::dbExecute(con, view_ddl)

  path
}

#' Open a read-write connection to a seeded pre-migration DuckDB
#'
#' @param path path returned by `seed_pre_migration_db()`.
#' @return an open DBI connection (caller must disconnect).
pre_migration_con <- function(path) {
  DBI::dbConnect(duckdb::duckdb(), path, read_only = FALSE)
}

# ---- PLAN-14 (dev/migrations/002-registry-remediation.R) additions --------
# "This plan's own additions to it" (P14-migration brief, Fixtures block).
# Additive only - never touches a row `seed_pre_migration_db()` already
# inserted - so PLAN-13's own pinned counts (e.g. test-migration-001.R's
# hardcoded v_measurement `3L`) stay untouched by this plan's fixture.

#' Add PLAN-14 R-14.1's duplicate-`Carbophenothion` fixture rows
#'
#' Two byte-identical-name `analyte` rows (the live shape: same units, CAS,
#' `conversion_constant`), one `lab_method` each, two `analyte_mask` rows on
#' the doomed uuid (one with a NULL `name` - the live shape), and analyses
#' reaching each analyte through its own `lab_method` - "many" on the
#' survivor, "few" on the doomed row (brief's Fixtures block; the live
#' 221/2 split is out of scope for a fixture, only the shape matters).
#' New `sample` rows reuse feature `f-101` (already seeded by
#' `seed_pre_migration_db()`) so this stays additive.
#'
#' @param con an open read-write DBI connection to a DB seeded by
#'   `seed_pre_migration_db()`.
#' @return invisible(NULL).
seed_carbophenothion_duplicate <- function(con) {
  DBI::dbExecute(con, "INSERT INTO analyte (uuid, name, units, conversion_constant, type, CAS) VALUES
    ('carb-survivor', 'Carbophenothion', 'mg/L', 1, 'pesticide', '786-19-6'),
    ('carb-doomed',   'Carbophenothion', 'mg/L', 1, 'pesticide', '786-19-6')")

  DBI::dbExecute(con, "INSERT INTO lab_method
    (uuid, uuid_analyte, name, method, organisation, rl_low) VALUES
    ('lm-carb-survivor', 'carb-survivor', 'Carbophenothion by GC', 'ORG-CARB', 'ALS', 0.01),
    ('lm-carb-doomed',   'carb-doomed',   'Carbophenothion by GC', 'ORG-CARB', 'ALS', 0.01)")

  # 'long' + an 'EPA' row with a NULL name - the exact live shape quoted in
  # the plan block (R-14.1: "long on both; EPA with a NULL name on d0dc5ac3").
  DBI::dbExecute(con, "INSERT INTO analyte_mask (uuid_analyte, variant, name) VALUES
    ('carb-doomed', 'long', 'Carbophenothion (long)'),
    ('carb-doomed', 'EPA', NULL)")

  DBI::dbExecute(con, "INSERT INTO \"sample\"
    (uuid, uuid_feature, date, datetime, organisation) VALUES
    ('s-carb-1', 'f-101', TIMESTAMP '2024-02-01 00:00:00', TIMESTAMP '2024-02-01 09:00:00', 'ALS'),
    ('s-carb-2', 'f-101', TIMESTAMP '2024-02-02 00:00:00', TIMESTAMP '2024-02-02 09:00:00', 'ALS'),
    ('s-carb-3', 'f-101', TIMESTAMP '2024-02-03 00:00:00', TIMESTAMP '2024-02-03 09:00:00', 'ALS'),
    ('s-carb-4', 'f-101', TIMESTAMP '2024-02-04 00:00:00', TIMESTAMP '2024-02-04 09:00:00', 'ALS'),
    ('s-carb-5', 'f-101', TIMESTAMP '2024-02-05 00:00:00', TIMESTAMP '2024-02-05 09:00:00', 'ALS')")

  # survivor: 3 analyses ("many"); doomed: 2 analyses ("few").
  DBI::dbExecute(con, "INSERT INTO analysis
    (uuid, uuid_sample, uuid_lab, value, quantified, rl_low) VALUES
    ('an-carb-s1', 's-carb-1', 'lm-carb-survivor', 0.02, TRUE, 0.01),
    ('an-carb-s2', 's-carb-2', 'lm-carb-survivor', 0.03, TRUE, 0.01),
    ('an-carb-s3', 's-carb-3', 'lm-carb-survivor', 0.04, TRUE, 0.01),
    ('an-carb-d1', 's-carb-4', 'lm-carb-doomed',   0.05, TRUE, 0.01),
    ('an-carb-d2', 's-carb-5', 'lm-carb-doomed',   0.06, TRUE, 0.01)")

  invisible(NULL)
}

#' Add PLAN-14 R-14.2's `reported_as` backfill fixture rows
#'
#' One `lab_method` row per name in the plan's enumerated seven (the four
#' "... Alkalinity as CaCO3" names, "Total Hardness as CaCO3", "Ammonia as
#' N", and "Ammonia as NH3" - whose analyte is named `NH3-N`, per the plan
#' text, so a mass-ratio conversion onto the N basis makes sense), plus one
#' EIGHTH row (`Total Recoverable Zinc as Zn`) that matches the `(?i) as
#' (\\w+)$` pattern but is NOT one of the seven - the "reported and left
#' alone, no constant invented" case (Phase-3 D6). The base fixture's
#' existing `lm-901` ("Analyte X by IC") already covers the non-matching
#' case, so it is not duplicated here.
#'
#' `an-carb-*`/`s-carb-*` from `seed_carbophenothion_duplicate()` are reused
#' as the `NH3-N` analysis's sample so this stays additive; call that
#' function on the same connection first if both fixtures are needed.
#'
#' @param con an open read-write DBI connection to a DB seeded by
#'   `seed_pre_migration_db()` (and, if both fixtures are used,
#'   `seed_carbophenothion_duplicate()`, for the reused sample rows).
#' @return invisible(NULL).
seed_reported_as_fixture <- function(con) {
  DBI::dbExecute(con, "INSERT INTO analyte (uuid, name, units, type, CAS) VALUES
    ('an-n', 'N', 'mg/L', 'nutrient', NULL),
    ('an-nh3n', 'NH3-N', 'mg/L', 'nutrient', NULL),
    ('an-caco3', 'CaCO3', 'mg/L', 'physical', NULL),
    ('an-zn', 'Zn', 'mg/L', 'metal', NULL)")

  DBI::dbExecute(con, "INSERT INTO lab_method
    (uuid, uuid_analyte, name, method, organisation, rl_low) VALUES
    ('lm-nh-n',       'an-n',     'Ammonia as N',                     'EK055G', 'ALS', 0.01),
    ('lm-nh-nh3',     'an-nh3n',  'Ammonia as NH3',                   'EK055G', 'ALS', 0.01),
    ('lm-alk-total',  'an-caco3', 'Total Alkalinity as CaCO3',        'ED037P', 'ALS', 1),
    ('lm-alk-bicarb', 'an-caco3', 'Bicarbonate Alkalinity as CaCO3',  'ED037P', 'ALS', 1),
    ('lm-alk-carb',   'an-caco3', 'Carbonate Alkalinity as CaCO3',    'ED037P', 'ALS', 1),
    ('lm-alk-hydrox', 'an-caco3', 'Hydroxide Alkalinity as CaCO3',    'ED037P', 'ALS', 1),
    ('lm-hardness',   'an-caco3', 'Total Hardness as CaCO3',          'EA065',  'ALS', 1),
    ('lm-zn-extra',   'an-zn',    'Total Recoverable Zinc as Zn',     'EG020',  'ALS', 0.001)")

  # An existing as-NH3 analysis, already on the recovered constant
  # (0.8224428 x 2.14 = 1.76002759, R-14.3's own worked example) - the
  # before/after row this plan's row-count-and-checksum invariant must prove
  # untouched. Reuses 's-carb-1' (seeded by `seed_carbophenothion_duplicate()`).
  DBI::dbExecute(con, "INSERT INTO analysis
    (uuid, uuid_sample, uuid_lab, value, quantified, rl_low) VALUES
    ('an-nh3-existing', 's-carb-1', 'lm-nh-nh3', 1.76002759, TRUE, 0.01)")

  invisible(NULL)
}
