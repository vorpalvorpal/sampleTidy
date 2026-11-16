# PLAN-23 (the site feature register), sampleTidy part: the DDL constants, the
# write allowlist, and the pre-117 guard.
#   R-23.1  .st_core_ddl_feature / _feature_mask / _feature_geometry
#   R-23.2  "feature_geometry" on .st_mutate_allowlist; db_append() logs it
#   R-23.7  .st_has_feature_register() (the guard every later test leans on)
# plus the vocabulary constants of PLAN-23 3.1 / 2.4.
# Throwaway databases only: in-memory, or seed_db() in a temp dir.

# ---- the vocabulary and range constants (PLAN-23 3.1, 2.4) ------------------------------

test_that("R-23.1: the geometry constants have the values PLAN-23 3.1 pins", {
  expect_identical(.st_geometry_epsg, 7856L)
  expect_identical(.st_geometry_roles, c("location", "extent", "route", "outline"))
  expect_identical(.st_geometry_qualities,
                   c("surveyed", "field_gps", "plan", "imagery", "inferred", "approximate"))
  expect_equal(.st_geometry_grid_range,
               c(xmin = 100000, ymin = 1000000, xmax = 900000, ymax = 10000000))
  expect_identical(names(.st_geometry_grid_range), c("xmin", "ymin", "xmax", "ymax"))
})

test_that("R-23.1: .st_geometry_role_types maps each role to the WKT types it allows (2.4)", {
  rt <- .st_geometry_role_types
  expect_type(rt, "list")
  expect_setequal(names(rt), c("location", "extent", "route", "outline"))
  expect_setequal(rt$location, "POINT")
  expect_setequal(rt$route, c("LINESTRING", "MULTILINESTRING"))
  expect_setequal(rt$extent, c("POLYGON", "MULTIPOLYGON"))
  expect_setequal(rt$outline, c("POLYGON", "MULTIPOLYGON"))
})

test_that("R-23.1: .st_feature_classes holds the generic vocabulary of 2.4 (a deployment extends it, it never shrinks)", {
  want <- c("bore", "gas_well", "gas_point", "dust_gauge", "weather_station", "surface_point",
            "seep", "tap", "dam", "pond", "cell", "landfill", "gas_field", "wall", "sump", "pit",
            "pump", "valve", "meter", "pipe", "drain", "culvert", "inlet", "headwall", "aerator",
            "dosing_unit", "tank", "switchboard", "telemetry", "building", "cable")
  expect_type(.st_feature_classes, "character")
  expect_false(anyNA(.st_feature_classes))
  expect_false(anyDuplicated(.st_feature_classes) > 0)
  # [to confirm] vocabulary: pin that every listed word is present, not that no other is.
  expect_true(all(want %in% .st_feature_classes), info = paste(setdiff(want, .st_feature_classes), collapse = ","))
  # generic words only: lower-case snake_case, no digits, no site-style codes.
  expect_true(all(grepl("^[a-z]+(_[a-z]+)*$", .st_feature_classes)))
})

# ---- R-23.1: DDL of feature -----------------------------------------------------------

feature_17 <- c("uuid", "name", "site", "class", "flow", "matrix", "depth", "installed_by",
                "permanent", "reference", "date_start", "date_end", "cypher", "elevation",
                "uuid_project", "comments", "virtual")

test_that("R-23.1: .st_core_ddl_feature creates the 17 columns of 2.1 in order; no lon/lat/geom_wkt; class present", {
  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  expect_type(.st_core_ddl_feature, "character")
  expect_length(.st_core_ddl_feature, 1L)
  DBI::dbExecute(con, .st_core_ddl_feature)
  cols <- t23_coltypes(con, "feature")
  expect_identical(cols$column_name, feature_17)
  expect_length(cols$column_name, 17L)
  expect_false(any(c("lon", "lat", "geom_wkt") %in% cols$column_name))
  expect_true("class" %in% cols$column_name)
  ty <- stats::setNames(cols$data_type, cols$column_name)
  expect_identical(unname(ty[c("uuid", "name", "site", "class", "flow", "matrix", "installed_by",
                               "cypher", "uuid_project", "comments")]), rep("VARCHAR", 10))
  expect_identical(unname(ty[c("depth", "elevation")]), c("DOUBLE", "DOUBLE"))
  expect_identical(unname(ty[c("permanent", "reference", "virtual")]), rep("BOOLEAN", 3))
  expect_identical(unname(ty[c("date_start", "date_end")]), c("DATE", "DATE"))
  # idx_feature_site
  idx <- DBI::dbGetQuery(con, "SELECT index_name FROM duckdb_indexes() WHERE table_name = 'feature'")$index_name
  expect_true("idx_feature_site" %in% idx)
})

test_that("R-23.1: feature.name and feature.site are NOT NULL, class is nullable, virtual defaults FALSE, uuid is the primary key", {
  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbExecute(con, .st_core_ddl_feature)
  nn <- stats::setNames(t23_coltypes(con, "feature")$is_nullable, feature_17)
  expect_identical(unname(nn[c("name", "site")]), c("NO", "NO"))
  expect_identical(unname(nn["class"]), "YES")
  expect_error(DBI::dbExecute(con, "INSERT INTO feature (uuid, name, site) VALUES ('f1', NULL, 'X')"))
  expect_error(DBI::dbExecute(con, "INSERT INTO feature (uuid, name, site) VALUES ('f2', 'X.A', NULL)"))
  DBI::dbExecute(con, "INSERT INTO feature (uuid, name, site) VALUES ('f3', 'X.A', 'X')")
  row <- DBI::dbGetQuery(con, "SELECT virtual, class FROM feature WHERE uuid = 'f3'")
  expect_identical(row$virtual, FALSE)
  expect_true(is.na(row$class))
  expect_error(DBI::dbExecute(con, "INSERT INTO feature (uuid, name, site) VALUES ('f3', 'X.B', 'X')"))
  # No CHECK on class (2.1 [proposed]): the vocabulary is enforced by add_feature() and a check, not the table.
  expect_no_error(DBI::dbExecute(con, "INSERT INTO feature (uuid, name, site, class) VALUES ('f4', 'X.C', 'X', 'anything')"))
})

test_that("R-23.1: .st_core_ddl_feature_mask recreates feature_mask as live has it: PK (uuid_feature, variant), FK to feature, variant index", {
  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbExecute(con, .st_core_ddl_feature)
  DBI::dbExecute(con, .st_core_ddl_feature_mask)
  expect_identical(t23_cols(con, "feature_mask"), c("uuid_feature", "variant", "name"))
  k <- DBI::dbGetQuery(con, "SELECT constraint_type, constraint_column_names FROM duckdb_constraints()
                             WHERE table_name = 'feature_mask'")
  expect_true("PRIMARY KEY" %in% k$constraint_type)
  pk <- k$constraint_column_names[k$constraint_type == "PRIMARY KEY"][[1]]
  expect_setequal(unlist(pk), c("uuid_feature", "variant"))
  expect_true("FOREIGN KEY" %in% k$constraint_type)
  idx <- DBI::dbGetQuery(con, "SELECT index_name FROM duckdb_indexes() WHERE table_name = 'feature_mask'")$index_name
  expect_true("idx_feature_mask_variant" %in% idx)
  # FK enforced
  expect_error(DBI::dbExecute(con, "INSERT INTO feature_mask VALUES ('no-such', 'long', 'x')"))
  DBI::dbExecute(con, "INSERT INTO feature (uuid, name, site) VALUES ('f1', 'X.A', 'X')")
  DBI::dbExecute(con, "INSERT INTO feature_mask VALUES ('f1', 'long', 'x')")
  expect_error(DBI::dbExecute(con, "INSERT INTO feature_mask VALUES ('f1', 'long', 'again')"))  # PK
})

# ---- R-23.1: DDL of feature_geometry -------------------------------------------------

geom_13 <- c("uuid", "uuid_feature", "role", "geom_wkt", "source", "source_crs", "quality",
             "date_start", "date_end", "recorded", "supersedes", "superseded", "comments")

g_insert <- function(con, uuid, ..., date_start = "NULL", date_end = "NULL", supersedes = "NULL") {
  DBI::dbExecute(con, sprintf(
    "INSERT INTO feature_geometry (uuid, uuid_feature, role, geom_wkt, source, source_crs, quality,
                                   date_start, date_end, recorded, supersedes)
     VALUES ('%s', 'f1', 'location', 'POINT (300000 6300000)', 'fixture', 'EPSG:7856', 'surveyed',
             %s, %s, TIMESTAMP '2026-01-01 00:00:00', %s)",
    uuid, date_start, date_end, supersedes))
}

test_that("R-23.1: .st_core_ddl_feature_geometry creates the 13 columns of 2.2, in order, with the right types and NOT NULLs", {
  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  expect_type(.st_core_ddl_feature_geometry, "character")
  expect_length(.st_core_ddl_feature_geometry, 1L)
  DBI::dbExecute(con, .st_core_ddl_feature_geometry)
  cols <- t23_coltypes(con, "feature_geometry")
  expect_identical(cols$column_name, geom_13)
  ty <- stats::setNames(cols$data_type, cols$column_name)
  expect_identical(unname(ty[c("date_start", "date_end")]), c("DATE", "DATE"))
  expect_identical(unname(ty[c("recorded", "superseded")]), c("TIMESTAMP", "TIMESTAMP"))
  expect_identical(unname(ty[setdiff(geom_13, c("date_start", "date_end", "recorded", "superseded"))]),
                   rep("VARCHAR", 9))
  nn <- stats::setNames(cols$is_nullable, cols$column_name)
  expect_identical(unname(nn[c("uuid_feature", "role", "geom_wkt", "source", "source_crs", "quality", "recorded")]),
                   rep("NO", 7))
  expect_identical(unname(nn[c("date_start", "date_end", "supersedes", "superseded", "comments")]),
                   rep("YES", 5))
  idx <- DBI::dbGetQuery(con, "SELECT index_name FROM duckdb_indexes() WHERE table_name = 'feature_geometry'")$index_name
  expect_true("idx_feature_geometry_feature" %in% idx)
})

test_that("R-23.1: feature_geometry has a primary key on uuid, UNIQUE + a self foreign key on supersedes, and NO foreign key to feature", {
  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbExecute(con, .st_core_ddl_feature_geometry)
  k <- DBI::dbGetQuery(con, "SELECT constraint_type, constraint_column_names, referenced_table
                             FROM duckdb_constraints() WHERE table_name = 'feature_geometry'")
  has <- function(type, col) any(k$constraint_type == type &
                                   vapply(k$constraint_column_names, function(x) col %in% unlist(x), NA))
  expect_true(has("PRIMARY KEY", "uuid"))
  expect_true(has("UNIQUE", "supersedes"))
  expect_true(has("FOREIGN KEY", "supersedes"))
  expect_false(has("FOREIGN KEY", "uuid_feature"))   # 2.2: no FK, an FK would drag the table into the next feature rebuild
  fk <- k[k$constraint_type == "FOREIGN KEY", ]
  expect_true(all(fk$referenced_table == "feature_geometry"))
  # behaviour: a duplicate uuid, a successor naming a missing predecessor, and a second correction of one row are refused
  g_insert(con, "g1")
  expect_error(g_insert(con, "g1"))
  expect_error(g_insert(con, "g-orphan", supersedes = "'g-missing'"))
  g_insert(con, "g2", supersedes = "'g1'")
  expect_error(g_insert(con, "g3", supersedes = "'g1'"))      # UNIQUE: a chain never forks
  # a row for a feature that does not exist is NOT refused by the table (the check orphan_feature_geometry reports it)
  expect_no_error(DBI::dbExecute(con, "INSERT INTO feature_geometry
    (uuid, uuid_feature, role, geom_wkt, source, source_crs, quality, recorded)
    VALUES ('g-nofeat', 'f-nobody', 'location', 'POINT (300000 6300000)', 's', 'unknown', 'plan',
            TIMESTAMP '2026-01-01 00:00:00')"))
})

test_that("R-23.1: feature_geometry's two CHECKs refuse date_end < date_start and supersedes = uuid; date_end == date_start is fine", {
  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbExecute(con, .st_core_ddl_feature_geometry)
  expect_error(g_insert(con, "gd", date_start = "DATE '2026-02-01'", date_end = "DATE '2026-01-31'"), "CHECK")
  # a row naming itself in `supersedes` is refused (DuckDB 1.4.1 reports the foreign key first, as the row
  # is not yet visible to itself, so no message is pinned) and the second CHECK is declared on the table.
  expect_error(g_insert(con, "gs", supersedes = "'gs'"))
  ck <- DBI::dbGetQuery(con, "SELECT expression FROM duckdb_constraints()
                              WHERE table_name = 'feature_geometry' AND constraint_type = 'CHECK'")
  expect_equal(nrow(ck), 2L)
  expect_true(any(grepl("supersedes", ck$expression, fixed = TRUE)))
  expect_true(any(grepl("date_end", ck$expression, fixed = TRUE)))
  expect_no_error(g_insert(con, "ge", date_start = "DATE '2026-02-01'", date_end = "DATE '2026-02-01'"))
  expect_no_error(g_insert(con, "gn", date_end = "DATE '2026-01-31'"))     # open start
  expect_no_error(g_insert(con, "gm", date_start = "DATE '2026-02-01'"))   # open end
  expect_identical(DBI::dbGetQuery(con, "SELECT count(*) AS n FROM feature_geometry")$n, 3)
})

test_that("R-23.1: the helper fixture DDL (helper-db.R, a literal copy) and the package constants describe the same tables", {
  a <- DBI::dbConnect(duckdb::duckdb()); b <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(a, shutdown = TRUE)); withr::defer(DBI::dbDisconnect(b, shutdown = TRUE))
  DBI::dbExecute(a, .st_core_ddl_feature);  DBI::dbExecute(a, .st_core_ddl_feature_geometry)
  DBI::dbExecute(b, .st_test_core_ddl$feature); DBI::dbExecute(b, .st_test_core_ddl$feature_geometry)
  for (t in c("feature", "feature_geometry")) {
    expect_identical(t23_coltypes(a, t), t23_coltypes(b, t), info = t)
  }
  # the constraints agree too
  kq <- "SELECT table_name, constraint_type, list_sort(constraint_column_names) AS cols
         FROM duckdb_constraints() ORDER BY 1, 2, 3"
  ka <- DBI::dbGetQuery(a, kq); kb <- DBI::dbGetQuery(b, kq)
  expect_identical(vapply(ka$cols, paste, "", collapse = ","), vapply(kb$cols, paste, "", collapse = ","))
  expect_identical(ka$constraint_type, kb$constraint_type)
})

# ---- R-23.2: the write allowlist ------------------------------------------------------------

test_that("R-23.2: feature_geometry is in .st_mutate_allowlist and no existing entry is dropped", {
  expect_true("feature_geometry" %in% .st_mutate_allowlist)
  before <- c("feature", "feature_mask", "analyte", "analyte_mask", "lab_method", "project", "sample",
              "analysis", "asset", "review_queue", "review_queue_candidate", "feature_alias",
              "qc_feature", "sample_lab_id", "lab_qc_report", "lab_qc_outlier",
              "lab_receipt_temperature", "lab_receipt_holding_breach", "lab_receipt_comment",
              "feature_role", "feature_dubious", "asset_filing", "db_meta")
  expect_true(all(before %in% .st_mutate_allowlist), info = paste(setdiff(before, .st_mutate_allowlist), collapse = ","))
  expect_no_error(.st_validate_table("feature_geometry"))
})

test_that("R-23.2: db_append(con, 'feature_geometry', ...) writes the row and exactly one change_log insert row with uuid_row = the row's uuid", {
  s <- t23_setup()
  before <- t23_fingerprint(s$con)
  row <- tibble::tibble(
    uuid = "g-new-1", uuid_feature = "f-0013", role = "location",
    geom_wkt = "POINT (300000.000 6300000.000)", source = "fixture", source_crs = "EPSG:7856",
    quality = "field_gps", recorded = as.POSIXct("2026-03-01 00:00:00", tz = "UTC")
  )
  db_append(s$con, "feature_geometry", row, actor = "tester", reason = "append test")
  expect_identical(nrow(t23_geom(s$con, "g-new-1")), 1L)
  expect_identical(DBI::dbGetQuery(s$con, "SELECT count(*) AS n FROM feature_geometry")$n,
                   nrow(before$geometry) + 1)
  lg <- DBI::dbGetQuery(s$con, "SELECT * FROM change_log WHERE tbl = 'feature_geometry'")
  expect_identical(nrow(lg), 1L)
  expect_identical(lg$action, "insert")
  expect_identical(lg$uuid_row, "g-new-1")
  expect_identical(lg$actor, "tester")
  expect_identical(DBI::dbGetQuery(s$con, "SELECT count(*) AS n FROM change_log")$n, before$log + 1)
})

# ---- R-23.7: the pre-117 guard ----------------------------------------------------------------

test_that("R-23.7: .st_has_feature_register() is TRUE on a post-117 database, FALSE on a pre-117 one", {
  s <- t23_setup()
  expect_true(.st_has_feature_register(s$con))
  old <- local_pre117_db()
  con <- DBI::dbConnect(duckdb::duckdb(), old, read_only = TRUE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  expect_false(.st_has_feature_register(con))
})

test_that("R-23.7: .st_has_feature_register() needs BOTH halves: the table feature_geometry AND a feature with no lon column", {
  # feature_geometry exists but feature still has lon
  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbExecute(con, .st_test_core_ddl_pre117$feature)
  DBI::dbExecute(con, .st_test_core_ddl$feature_geometry)
  expect_false(.st_has_feature_register(con))
  # new-shape feature but no feature_geometry table
  con2 <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con2, shutdown = TRUE))
  DBI::dbExecute(con2, .st_test_core_ddl$feature)
  expect_false(.st_has_feature_register(con2))
  # neither table at all
  con3 <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con3, shutdown = TRUE))
  expect_false(.st_has_feature_register(con3))
  # both halves present
  DBI::dbExecute(con2, .st_test_core_ddl$feature_geometry)
  expect_true(.st_has_feature_register(con2))
})
