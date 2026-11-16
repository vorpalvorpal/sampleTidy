# Helpers for the PLAN-23 (site feature register) tests. Only DEFINES things.
#
# The fixture DDL for the register lives in helper-db.R (`.st_test_core_ddl$feature`
# and `$feature_geometry`, LITERAL copies of PLAN-23 sections 2.1 and 2.2) so that
# every test that is not about the register still has a working database before
# the package constants exist. test-feature-register-ddl.R pins that the package
# constants (`.st_core_ddl_*`) and these copies describe the same tables.

# PLAN-23 section 2.3 verbatim (the reference `v_feature_location`). Used ONLY by
# the db-checks fixture (so `view_nonempty` sees the view). The view tests
# (test-feature-location-view.R) build the view from the package constant
# `.st_view_feature_location_sql`, never from this copy.
.t23_view_feature_location_sql <- r"---(CREATE VIEW v_feature_location AS
WITH loc AS (
  SELECT g.uuid AS uuid_geometry, g.uuid_feature, g.quality, g.source, g.source_crs,
         g.date_start, g.date_end, g.recorded,
         TRY_CAST(regexp_extract(upper(g.geom_wkt),
           '^\s*POINT\s*\(\s*([-+0-9.E]+)\s+([-+0-9.E]+)\s*\)\s*$', 1) AS DOUBLE) AS easting,
         TRY_CAST(regexp_extract(upper(g.geom_wkt),
           '^\s*POINT\s*\(\s*([-+0-9.E]+)\s+([-+0-9.E]+)\s*\)\s*$', 2) AS DOUBLE) AS northing
  FROM feature_geometry g
  WHERE g.role = 'location' AND g.superseded IS NULL
  QUALIFY row_number() OVER (
    PARTITION BY g.uuid_feature
    ORDER BY (g.date_end IS NULL) DESC, g.date_end DESC NULLS LAST, g.recorded DESC, g.uuid) = 1
),
k AS (
  -- GRS80; MGA2020 zone 56 (EPSG:7856): k0 0.9996, E0 500000, N0 10000000, CM 153
  SELECT (1 / 298.257222101) / (2 - 1 / 298.257222101) AS n
),
t1 AS (
  SELECT loc.*, k.n,
    (northing - 10000000) / (0.9996 * 6378137 / (1 + k.n) * (1 + k.n^2 / 4 + k.n^4 / 64)) AS xi1,
    (easting - 500000)    / (0.9996 * 6378137 / (1 + k.n) * (1 + k.n^2 / 4 + k.n^4 / 64)) AS eta1,
    k.n / 2 - 2 * k.n^2 / 3 + 37 * k.n^3 / 96 - k.n^4 / 360 AS b1,
    k.n^2 / 48 + k.n^3 / 15 - 437 * k.n^4 / 1440            AS b2,
    17 * k.n^3 / 480 - 37 * k.n^4 / 840                      AS b3,
    4397 * k.n^4 / 161280                                    AS b4
  FROM loc, k
),
t2 AS (
  SELECT *,
    xi1 - (b1 * sin(2 * xi1) * cosh(2 * eta1) + b2 * sin(4 * xi1) * cosh(4 * eta1)
         + b3 * sin(6 * xi1) * cosh(6 * eta1) + b4 * sin(8 * xi1) * cosh(8 * eta1)) AS xi,
    eta1 - (b1 * cos(2 * xi1) * sinh(2 * eta1) + b2 * cos(4 * xi1) * sinh(4 * eta1)
          + b3 * cos(6 * xi1) * sinh(6 * eta1) + b4 * cos(8 * xi1) * sinh(8 * eta1)) AS eta
  FROM t1
),
t3 AS (
  SELECT *, asin(sin(xi) / cosh(eta)) AS chi, atan2(sinh(eta), cos(xi)) AS dlon FROM t2
)
SELECT t3.uuid_feature, f.name, f.site, f.class, t3.uuid_geometry,
       t3.easting, t3.northing,
       153 + degrees(t3.dlon) AS lon,
       degrees(t3.chi
         + (2 * n - 2 * n^2 / 3 - 2 * n^3 + 116 * n^4 / 45) * sin(2 * t3.chi)
         + (7 * n^2 / 3 - 8 * n^3 / 5 - 227 * n^4 / 45)    * sin(4 * t3.chi)
         + (56 * n^3 / 15 - 136 * n^4 / 35)                 * sin(6 * t3.chi)
         + (4279 * n^4 / 630)                               * sin(8 * t3.chi)) AS lat,
       t3.quality, t3.source, t3.source_crs, t3.date_start, t3.date_end, t3.recorded
FROM t3 JOIN feature f ON f.uuid = t3.uuid_feature;)---"


# ---- small utilities ---------------------------------------------------------

#' A seeded DuckDB with `sampletidy.live_db` pointed at it and one read-write
#' connection open for the caller (closed with the calling test).
#' Returns list(path =, con =).
t23_setup <- function(env = parent.frame()) {
  path <- seed_db(dir = withr::local_tempdir(.local_envir = env))
  withr::local_options(list("sampletidy.live_db" = path), .local_envir = env)
  con <- seed_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE), envir = env)
  list(path = path, con = con)
}

#' A seed_db() twin on the PRE-117 shape (PLAN-23 section 3.8): `feature` is the
#' 19-column table with `lon`/`lat` NOT NULL and `geom_wkt`, and there is no
#' `feature_geometry`. Same feature rows as the seed (uuid, name, site, ...),
#' every one at lon 150 / lat -33. Returns the path (closed). The caller's
#' frame owns the temp dir (withr wrong-frame trap: see seed_db()).
local_pre117_db <- function(dir = NULL, env = parent.frame()) {
  if (is.null(dir)) dir <- withr::local_tempdir(.local_envir = env)
  path <- seed_db(dir = dir)
  con <- DBI::dbConnect(duckdb::duckdb(), path, read_only = FALSE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbExecute(con, "DROP TABLE feature_geometry")
  DBI::dbExecute(con, "CREATE TEMP TABLE t23_keep_feature AS SELECT * FROM feature")
  DBI::dbExecute(con, "DROP TABLE feature")
  DBI::dbExecute(con, .st_test_core_ddl_pre117$feature)
  DBI::dbExecute(con, "INSERT INTO feature
    (uuid, name, site, flow, matrix, depth, installed_by, permanent, reference, date_start,
     date_end, cypher, elevation, uuid_project, lon, lat, geom_wkt, comments, virtual)
    SELECT uuid, name, site, flow, matrix, depth, installed_by, permanent, reference, date_start,
     date_end, cypher, elevation, uuid_project, 150.0, -33.0, NULL, comments, virtual
    FROM t23_keep_feature")
  DBI::dbExecute(con, "DROP TABLE t23_keep_feature")
  path
}

#' Column names of a table, in ordinal order.
t23_cols <- function(con, table) {
  DBI::dbGetQuery(con, "SELECT column_name FROM information_schema.columns
                        WHERE table_name = ? ORDER BY ordinal_position",
                  params = list(table))$column_name
}

#' Column name -> type (and nullability) of a table, in ordinal order.
t23_coltypes <- function(con, table) {
  d <- DBI::dbGetQuery(con, "SELECT column_name, data_type, is_nullable FROM information_schema.columns
                             WHERE table_name = ? ORDER BY ordinal_position",
                       params = list(table))
  d
}

#' One feature_geometry row by uuid (a 1-row data.frame, 0 rows when absent).
t23_geom <- function(con, uuid) {
  DBI::dbGetQuery(con, "SELECT * FROM feature_geometry WHERE uuid = ?", params = list(uuid))
}

#' A cheap "nothing was written" fingerprint: row counts of the tables the
#' register touches plus the whole of feature_geometry.
t23_fingerprint <- function(con) {
  list(
    feature = DBI::dbGetQuery(con, "SELECT count(*) AS n FROM feature")$n,
    alias = DBI::dbGetQuery(con, "SELECT count(*) AS n FROM feature_alias")$n,
    log = DBI::dbGetQuery(con, "SELECT count(*) AS n FROM change_log")$n,
    geometry = DBI::dbGetQuery(con, "SELECT * FROM feature_geometry ORDER BY uuid")
  )
}

#' change_log rows for feature_geometry, oldest first.
t23_geom_log <- function(con) {
  DBI::dbGetQuery(con, "SELECT * FROM change_log WHERE tbl = 'feature_geometry' ORDER BY \"at\", action, uuid_row")
}

#' expect_error() on a sampletidy_error whose message matches `pattern` (when
#' given) and which is NOT a bare "could not find function".
t23_expect_refused <- function(expr, pattern = NULL) {
  e <- testthat::expect_error(expr, class = "sampletidy_error")
  if (!is.null(e)) {
    msg <- conditionMessage(e)
    testthat::expect_false(grepl("could not find function", msg, fixed = TRUE), info = msg)
    if (!is.null(pattern)) testthat::expect_match(msg, pattern, ignore.case = TRUE)
  }
  invisible(e)
}

#' An in-memory DuckDB holding only the register tables built from the fixture
#' DDL (no seed rows). Closed with the caller.
t23_mem_con <- function(env = parent.frame()) {
  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE), envir = env)
  DBI::dbExecute(con, .st_test_core_ddl$feature)
  DBI::dbExecute(con, .st_test_core_ddl$feature_geometry)
  con
}
