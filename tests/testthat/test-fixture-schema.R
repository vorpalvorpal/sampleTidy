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

# PLAN-23 (R-23.1): `feature` is pinned in its POST-migration-117 shape - 17
# columns, `class` new, `lon`/`lat`/`geom_wkt` gone - and `feature_geometry` is
# new. The pre-117 19-column shape is kept in `.st_test_core_ddl_pre117` and
# pinned separately below. (Until 117 is applied live, live is still the old
# shape; this table follows the code, not the live database.)
fs_live_cols <- list(
  feature = c(
    uuid = "VARCHAR", name = "VARCHAR", site = "VARCHAR", class = "VARCHAR",
    flow = "VARCHAR", matrix = "VARCHAR", depth = "DOUBLE",
    installed_by = "VARCHAR", permanent = "BOOLEAN", reference = "BOOLEAN",
    date_start = "DATE", date_end = "DATE", cypher = "VARCHAR",
    elevation = "DOUBLE", uuid_project = "VARCHAR", comments = "VARCHAR",
    virtual = "BOOLEAN"
  ),
  feature_geometry = c(
    uuid = "VARCHAR", uuid_feature = "VARCHAR", role = "VARCHAR",
    geom_wkt = "VARCHAR", source = "VARCHAR", source_crs = "VARCHAR",
    quality = "VARCHAR", date_start = "DATE", date_end = "DATE",
    recorded = "TIMESTAMP", supersedes = "VARCHAR", superseded = "TIMESTAMP",
    comments = "VARCHAR"
  ),
  # PLAN-23 17/18 Nov (D17-64, D17-75, D17-81): the dated mask and the two
  # link tables, as 2.1 and 2.6 define them (post-117).
  feature_mask = c(
    uuid = "VARCHAR", uuid_feature = "VARCHAR", variant = "VARCHAR", name = "VARCHAR",
    date_start = "DATE", date_end = "DATE", comments = "VARCHAR"
  ),
  feature_predecessor = c(
    uuid = "VARCHAR", uuid_feature = "VARCHAR", uuid_predecessor = "VARCHAR",
    date_break = "DATE", source = "VARCHAR", comments = "VARCHAR"
  ),
  feature_flow = c(
    uuid = "VARCHAR", uuid_from = "VARCHAR", uuid_to = "VARCHAR", carries = "VARCHAR",
    drive = "VARCHAR", date_start = "DATE", date_end = "DATE", source = "VARCHAR",
    comments = "VARCHAR"
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
  DBI::dbExecute(con, "INSERT INTO feature (uuid, name, site, flow, matrix, reference)
                       VALUES ('f-fs01', 'Q.L01', 'Q', 'groundwater', 'leachate', TRUE)")
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

test_that("R-23.1 fixture: the pre-117 twin keeps the 19-column shape (lon/lat NOT NULL, geom_wkt, no class) and has no feature_geometry", {
  db <- local_pre117_db()
  d <- fs_seed_cols(db, "feature")
  expect_identical(
    d$column_name,
    c("uuid", "name", "site", "flow", "matrix", "depth", "installed_by", "permanent", "reference",
      "date_start", "date_end", "cypher", "elevation", "uuid_project", "lon", "lat", "geom_wkt",
      "comments", "virtual")
  )
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  expect_false(DBI::dbExistsTable(con, "feature_geometry"))
  expect_gt(DBI::dbGetQuery(con, "SELECT count(*) AS n FROM feature")$n, 0)
  # 17/18 Nov: before 117 the mask is undated and keyless, and there are no link tables
  expect_identical(fs_seed_cols(db, "feature_mask")$column_name, c("uuid_feature", "variant", "name"))
  expect_gt(DBI::dbGetQuery(con, "SELECT count(*) AS n FROM feature_mask")$n, 0)
  expect_false(DBI::dbExistsTable(con, "feature_predecessor"))
  expect_false(DBI::dbExistsTable(con, "feature_flow"))
})

test_that("R-23.29 fixture: the seed's masks have uuids; the common name T.SN01 moves from T.S02 to T.S07 on 2025-01-01, each with a covering alias arm; one predecessor and one flow row", {
  db <- seed_db(dir = withr::local_tempdir())
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  m <- DBI::dbGetQuery(con, "SELECT m.*, f.name AS feature FROM feature_mask m JOIN feature f ON f.uuid = m.uuid_feature")
  expect_false(anyNA(m$uuid))
  expect_false(anyDuplicated(m$uuid) > 0)
  cm <- m[m$variant == "common", ]
  cm <- cm[order(cm$feature), ]
  expect_identical(cm$feature, c("T.S02", "T.S07"))
  expect_true(all(cm$name == "T.SN01"))
  expect_equal(cm$date_end[cm$feature == "T.S02"], as.Date("2024-12-31"))
  expect_true(is.na(cm$date_start[cm$feature == "T.S02"]))
  expect_equal(cm$date_start[cm$feature == "T.S07"], as.Date("2025-01-01"))
  expect_true(is.na(cm$date_end[cm$feature == "T.S07"]))
  a <- DBI::dbGetQuery(con, "SELECT uuid_feature, kind, date_start, date_end FROM feature_alias WHERE alias_key = 't.sn01'")
  expect_setequal(a$uuid_feature, c("f-0002", "f-0007"))
  expect_true(all(a$kind == "historical_code"))
  expect_equal(DBI::dbGetQuery(con, "SELECT count(*) AS n FROM feature_predecessor")$n, 1)
  expect_equal(DBI::dbGetQuery(con, "SELECT count(*) AS n FROM feature_flow")$n, 1)
})

test_that("R-23.1 fixture: the seed enforces name/site NOT NULL on feature, as live does", {
  db <- seed_db(dir = withr::local_tempdir())
  con <- DBI::dbConnect(duckdb::duckdb(), db)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  expect_error(DBI::dbExecute(con, "INSERT INTO feature (uuid, name, site) VALUES ('f-nn1', NULL, 'Q')"))
  expect_error(DBI::dbExecute(con, "INSERT INTO feature (uuid, name, site) VALUES ('f-nn2', 'Q.NN2', NULL)"))
})

test_that("R-23.1 fixture: the seed's feature_geometry rows follow PLAN-23 3.8", {
  db <- seed_db(dir = withr::local_tempdir())
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  g <- DBI::dbGetQuery(con, "SELECT g.*, f.name FROM feature_geometry g JOIN feature f ON f.uuid = g.uuid_feature")
  expect_true(all(g$source == "fixture"))
  expect_true(all(g$source_crs == "EPSG:7856"))
  # one in-use location for every seed feature except Q.S01 (f-0013), which stays unlocated
  inuse <- g[g$role == "location" & is.na(g$superseded) & is.na(g$date_end), ]
  all_f <- DBI::dbGetQuery(con, "SELECT uuid FROM feature")$uuid
  expect_setequal(inuse$uuid_feature, setdiff(all_f, "f-0013"))
  expect_false(any(duplicated(inuse$uuid_feature)))
  expect_false("f-0013" %in% g$uuid_feature)
  # T.S01: a superseded location and its successor
  s01 <- g[g$name == "T.S01" & g$role == "location", ]
  expect_equal(nrow(s01), 2L)
  expect_equal(sum(!is.na(s01$superseded)), 1L)
  expect_identical(s01$supersedes[!is.na(s01$supersedes)], s01$uuid[!is.na(s01$superseded)])
  # T.S04: an end-dated location and its in-use successor (a move on the ground)
  s04 <- g[g$name == "T.S04" & g$role == "location", ]
  expect_equal(nrow(s04), 2L)
  expect_equal(sum(!is.na(s04$date_end)), 1L)
  expect_true(all(is.na(s04$superseded)))
  # T.S05: a route and an outline besides its location
  s05 <- g[g$name == "T.S05", ]
  expect_true(all(c("location", "route", "outline") %in% s05$role))
  expect_match(s05$geom_wkt[s05$role == "route"], "^LINESTRING")
  expect_match(s05$geom_wkt[s05$role == "outline"], "^POLYGON")
  # coordinates near E 300000 / N 6300000
  pts <- g[g$role == "location", ]
  e <- as.numeric(sub("^POINT \\(([-0-9.]+) .*$", "\\1", pts$geom_wkt))
  n <- as.numeric(sub("^POINT \\([-0-9.]+ ([-0-9.]+)\\)$", "\\1", pts$geom_wkt))
  expect_true(all(abs(e - 300000) < 5000 & abs(n - 6300000) < 5000))
  # T.MW01 carries class bore, the others NA
  cl <- DBI::dbGetQuery(con, "SELECT name, class FROM feature")
  expect_identical(cl$class[cl$name == "T.MW01"], "bore")
  expect_true(all(is.na(cl$class[cl$name != "T.MW01"])))
})
