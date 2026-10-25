# Fixture drift guard (2026-10-25). seed_db()'s core DDL (helper-db.R) must
# carry the live schema's columns, with the live types, for the tables that
# downstream consumers read: a derived product (e.g. reference-site selection
# on feature.reference, leachate end-members on feature.matrix) cannot be
# tested against a fixture that lacks the columns it keys on.
#
# The expected shapes below were read from information_schema.columns of a
# read-only copy of the live DB on 2026-10-25 (column order is the live
# ordinal order). Only column names and types are pinned - NOT NULL and
# DEFAULT are not, except where noted. When the live schema changes, change
# this table and helper-db.R together.
#
# Deliberately NOT in the seed (documented, not drift):
#   * analyte.lab_contaminant (migration 048) - the seed is a pre-048 DB;
#     qc_create_tables() (helper-qc.R) adds it.
#   * migration-created tables (qc_feature, sample_lab_id, lab_qc_report,
#     lab_qc_outlier, lab_receipt_*, guideline, analyte_mask) - created by the
#     area helpers (helper-qc.R, helper-flags.R), whose DDL matches live.
#   * lab_invoice - no test or package code uses it.

fs_live_cols <- list(
  feature = c(
    uuid = "VARCHAR", name = "VARCHAR", site = "VARCHAR", flow = "VARCHAR",
    matrix = "VARCHAR", depth = "DOUBLE", installed_by = "VARCHAR",
    permanent = "BOOLEAN", reference = "BOOLEAN", date_start = "DATE",
    date_end = "DATE", cypher = "VARCHAR", elevation = "DOUBLE",
    uuid_project = "VARCHAR", lon = "DOUBLE", lat = "DOUBLE",
    geom_wkt = "VARCHAR", comments = "VARCHAR", virtual = "BOOLEAN"
  ),
  feature_alias = c(
    uuid = "VARCHAR", uuid_feature = "VARCHAR", name = "VARCHAR",
    alias_key = "VARCHAR", kind = "VARCHAR", n_seen = "INTEGER",
    auto_assign = "BOOLEAN", first_seen = "TIMESTAMP", last_seen = "TIMESTAMP",
    confirmed_by = "VARCHAR", comments = "VARCHAR", date_start = "DATE",
    date_end = "DATE"
  ),
  analyte = c(
    uuid = "VARCHAR", name = "VARCHAR", units = "VARCHAR",
    conversion_constant = "DOUBLE", type = "VARCHAR", valence = "DOUBLE",
    atomic_mass = "DOUBLE", reported_as = "VARCHAR", CAS = "VARCHAR",
    comments = "VARCHAR"
    # + lab_contaminant BOOLEAN live (migration 048; see header)
  ),
  lab_method = c(
    uuid = "VARCHAR", uuid_analyte = "VARCHAR", name = "VARCHAR",
    method = "VARCHAR", organisation = "VARCHAR", rl_low = "DOUBLE",
    rl_high = "DOUBLE", reported_as = "VARCHAR", api = "VARCHAR",
    uuid_project = "VARCHAR", uuid_feature = "VARCHAR", comments = "VARCHAR",
    units = "VARCHAR", conversion_constant = "DOUBLE", preference = "INTEGER",
    fraction = "VARCHAR"
  ),
  project = c(
    uuid = "VARCHAR", uuid_parent = "VARCHAR", uuid_root = "VARCHAR",
    uuid_project = "VARCHAR", name = "VARCHAR", type = "VARCHAR",
    purpose = "VARCHAR", date_start = "TIMESTAMP", date_end = "TIMESTAMP",
    regulated_by = "VARCHAR", cypher = "VARCHAR", site = "VARCHAR",
    value = "DOUBLE", comments = "VARCHAR"
  ),
  sample = c(
    uuid = "VARCHAR", uuid_feature_alias = "VARCHAR", uuid_project = "VARCHAR",
    date = "TIMESTAMP", date_start = "TIMESTAMP", datetime = "TIMESTAMP",
    datetime_start = "TIMESTAMP", organisation = "VARCHAR", person = "VARCHAR",
    purpose = "VARCHAR", comments = "VARCHAR"
  ),
  analysis = c(
    uuid = "VARCHAR", uuid_sample = "VARCHAR", uuid_lab = "VARCHAR",
    value = "DOUBLE", value_chr = "VARCHAR", quantified = "BOOLEAN",
    rl_low = "DOUBLE", rl_high = "DOUBLE", purpose = "VARCHAR",
    comments = "VARCHAR"
  )
)

fs_seed_cols <- function(db, table) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  d <- DBI::dbGetQuery(con, "SELECT column_name, data_type, column_default
                             FROM information_schema.columns
                             WHERE table_schema = 'main' AND table_name = ?
                             ORDER BY ordinal_position", params = list(table))
  d
}

test_that("fixture schema: seed_db()'s core tables have the live columns, types and order", {
  db <- seed_db(dir = withr::local_tempdir())
  for (t in names(fs_live_cols)) {
    d <- fs_seed_cols(db, t)
    got <- stats::setNames(d$data_type, d$column_name)
    expect_identical(got, fs_live_cols[[t]], info = t)
  }
})

test_that("fixture schema: feature carries reference, matrix, flow and virtual with the live types; virtual defaults FALSE", {
  db <- seed_db(dir = withr::local_tempdir())
  d <- fs_seed_cols(db, "feature")
  ty <- stats::setNames(d$data_type, d$column_name)
  expect_identical(unname(ty[c("reference", "matrix", "flow", "virtual", "permanent")]),
                   c("BOOLEAN", "VARCHAR", "VARCHAR", "BOOLEAN", "BOOLEAN"))
  con <- DBI::dbConnect(duckdb::duckdb(), db)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbExecute(con, "INSERT INTO feature (uuid, name, site, flow, matrix, reference, lon, lat)
                       VALUES ('f-fs01', 'Q.L01', 'Q', 'groundwater', 'leachate', TRUE, 150.5, -33.5)")
  row <- DBI::dbGetQuery(con, "SELECT reference, matrix, flow, virtual FROM feature WHERE uuid = 'f-fs01'")
  expect_identical(row$reference, TRUE)
  expect_identical(row$matrix, "leachate")
  expect_identical(row$flow, "groundwater")
  expect_identical(row$virtual, FALSE)
})

test_that("fixture schema: the PLAN-19 QC helpers add analyte.lab_contaminant (BOOLEAN) as live has it", {
  db <- qc_db()
  d <- fs_seed_cols(db, "analyte")
  expect_identical(d$data_type[d$column_name == "lab_contaminant"], "BOOLEAN")
})
