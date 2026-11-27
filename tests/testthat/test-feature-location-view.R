# PLAN-23 2.3: v_feature_location.
#   R-23.17  returns the reference values of 2.3 within 1e-8 degrees, one row per
#            located feature, the in-use piece when there is one, else the
#            latest-ended; an unlocated feature is absent; a superseded piece is
#            never chosen.
# The view is built from the PACKAGE constant `.st_view_feature_location_sql`
# (never from the helper's reference copy). Throwaway databases only.

view_cols <- c("uuid_feature", "name", "site", "class", "uuid_geometry", "easting", "northing", "lon", "lat",
               "quality", "source", "source_crs", "date_start", "date_end", "recorded")

mem_view <- function(env = parent.frame()) {
  con <- t23_mem_con(env)
  DBI::dbExecute(con, .st_view_feature_location_sql)
  con
}

add_f <- function(con, uuid, name = uuid, site = "X", class = NA_character_) {
  DBI::dbExecute(con, "INSERT INTO feature (uuid, name, site, class) VALUES (?, ?, ?, ?)",
                 params = list(uuid, name, site, class))
}
add_g <- function(con, uuid, feature, wkt, role = "location", recorded = "2026-01-01 00:00:00",
                  date_start = NA, date_end = NA, superseded = NA, quality = "surveyed", source = "fixture",
                  source_crs = "EPSG:7856") {
  DBI::dbExecute(con, "INSERT INTO feature_geometry (uuid, uuid_feature, role, geom_wkt, source, source_crs, quality,
                         date_start, date_end, recorded, superseded)
                       VALUES (?, ?, ?, ?, ?, ?, ?, CAST(? AS DATE), CAST(? AS DATE), CAST(? AS TIMESTAMP), CAST(? AS TIMESTAMP))",
                 params = list(uuid, feature, role, wkt, source, source_crs, quality,
                               as.character(date_start), as.character(date_end), recorded, as.character(superseded)))
}

test_that("R-23.17: the constant is one CREATE VIEW statement for v_feature_location", {
  expect_type(.st_view_feature_location_sql, "character")
  expect_length(.st_view_feature_location_sql, 1L)
  expect_match(.st_view_feature_location_sql, "CREATE\\s+(OR\\s+REPLACE\\s+)?VIEW\\s+v_feature_location", ignore.case = TRUE)
})

test_that("R-23.17: v_feature_location has the 15 columns of 2.3 in order, with DOUBLE easting/northing/lon/lat", {
  con <- mem_view()
  cols <- t23_coltypes(con, "v_feature_location")
  expect_identical(cols$column_name, view_cols)
  ty <- stats::setNames(cols$data_type, cols$column_name)
  expect_identical(unname(ty[c("easting", "northing", "lon", "lat")]), rep("DOUBLE", 4))
  expect_identical(unname(ty["recorded"]), "TIMESTAMP")
  expect_identical(unname(ty[c("date_start", "date_end")]), c("DATE", "DATE"))
})

ref <- data.frame(
  e = c(280000, 250000, 500000), n = c(6266000, 6260000, 6300000),
  lon = c(150.6256391718, 150.3004634853, 153.0000000000),
  lat = c(-33.7232246220, -33.7706336213, -33.4393946734)
)
for (i in seq_len(nrow(ref))) local({
  r <- ref[i, ]
  test_that(sprintf("R-23.17: E %s N %s -> lon %.10f lat %.10f within 1e-8 degrees (PROJ 9.5.1 reference)", r$e, r$n, r$lon, r$lat), {
    con <- mem_view()
    add_f(con, "f1")
    add_g(con, "g1", "f1", sprintf("POINT (%.3f %.3f)", r$e, r$n))
    v <- DBI::dbGetQuery(con, "SELECT * FROM v_feature_location")
    expect_equal(nrow(v), 1L)
    expect_equal(v$easting, r$e)
    expect_equal(v$northing, r$n)
    expect_lt(abs(v$lon - r$lon), 1e-8)
    expect_lt(abs(v$lat - r$lat), 1e-8)
  })
})

test_that("R-23.17: the view passes through name, site, class and the piece's own metadata", {
  con <- mem_view()
  add_f(con, "f1", name = "X.A01", site = "X", class = "bore")
  add_g(con, "g1", "f1", "POINT (280000 6266000)", quality = "field_gps", source = "a source", source_crs = "EPSG:28356",
        date_start = "2020-01-01", recorded = "2026-02-03 04:05:06")
  v <- DBI::dbGetQuery(con, "SELECT * FROM v_feature_location")
  expect_identical(v$uuid_feature, "f1"); expect_identical(v$uuid_geometry, "g1")
  expect_identical(v$name, "X.A01"); expect_identical(v$site, "X"); expect_identical(v$class, "bore")
  expect_identical(v$quality, "field_gps"); expect_identical(v$source, "a source"); expect_identical(v$source_crs, "EPSG:28356")
  expect_equal(v$date_start, as.Date("2020-01-01")); expect_true(is.na(v$date_end))
  expect_equal(format(v$recorded, tz = "UTC"), "2026-02-03 04:05:06")
})

test_that("R-23.17: on the seed, one row per located feature; unlocated Q.S01 is absent; superseded g-0001 is never chosen; the in-use piece beats the end-dated one", {
  s <- t23_setup()
  DBI::dbExecute(s$con, .st_view_feature_location_sql)
  v <- DBI::dbGetQuery(s$con, "SELECT * FROM v_feature_location ORDER BY uuid_feature")
  expect_equal(nrow(v), 12L)                       # f-0001 .. f-0012
  expect_false(anyDuplicated(v$uuid_feature) > 0)
  expect_false("f-0013" %in% v$uuid_feature)
  expect_identical(v$uuid_geometry[v$uuid_feature == "f-0001"], "g-0002")    # the successor, not the superseded g-0001
  expect_equal(v$easting[v$uuid_feature == "f-0001"], 300110)
  expect_identical(v$uuid_geometry[v$uuid_feature == "f-0004"], "g-0006")    # in-use beats end-dated g-0005
  expect_equal(v$northing[v$uuid_feature == "f-0004"], 6300410)
  # location only: f-0005 has a route and an outline as well and still gives ONE row, its location
  expect_equal(sum(v$uuid_feature == "f-0005"), 1L)
  expect_identical(v$uuid_geometry[v$uuid_feature == "f-0005"], "g-0007")
  expect_identical(v$class[v$uuid_feature == "f-0003"], "bore")
  expect_true(all(is.finite(v$lon) & is.finite(v$lat)))
  # the seed's synthetic grid (E 300000, N 6300000) is inside zone 56 around 150.85E / 33.42S
  expect_true(all(v$lon > 150.8 & v$lon < 151 & v$lat > -33.5 & v$lat < -33.3))
})

test_that("R-23.17: with no in-use piece the LATEST-ENDED current location is chosen (a removed thing keeps its last position)", {
  con <- mem_view()
  add_f(con, "f1")
  add_g(con, "ga", "f1", "POINT (300100 6300100)", date_start = "2010-01-01", date_end = "2015-12-31")
  add_g(con, "gb", "f1", "POINT (300200 6300200)", date_start = "2016-01-01", date_end = "2020-12-31")
  add_g(con, "gc", "f1", "POINT (300300 6300300)", date_start = "2005-01-01", date_end = "2009-12-31")
  v <- DBI::dbGetQuery(con, "SELECT * FROM v_feature_location")
  expect_equal(nrow(v), 1L)
  expect_identical(v$uuid_geometry, "gb")
  expect_equal(v$easting, 300200)
})

test_that("R-23.17: an in-use piece beats an ended piece even when the ended piece's date_end is later", {
  con <- mem_view()
  add_f(con, "f1")
  add_g(con, "g-old", "f1", "POINT (300100 6300100)", date_end = "2030-12-31")
  add_g(con, "g-open", "f1", "POINT (300200 6300200)")
  expect_identical(DBI::dbGetQuery(con, "SELECT uuid_geometry FROM v_feature_location")$uuid_geometry, "g-open")
})

test_that("R-23.17: ties on date_end break by latest `recorded`, then uuid", {
  con <- mem_view()
  add_f(con, "f1")
  add_g(con, "ga", "f1", "POINT (300100 6300100)", date_end = "2020-12-31", recorded = "2026-01-01 00:00:00")
  add_g(con, "gb", "f1", "POINT (300200 6300200)", date_end = "2020-12-31", recorded = "2026-02-01 00:00:00")
  expect_identical(DBI::dbGetQuery(con, "SELECT uuid_geometry FROM v_feature_location")$uuid_geometry, "gb")
  add_f(con, "f2")
  add_g(con, "gz", "f2", "POINT (300100 6300100)", recorded = "2026-01-01 00:00:00")
  add_g(con, "gy", "f2", "POINT (300200 6300200)", recorded = "2026-01-01 00:00:00")
  expect_identical(DBI::dbGetQuery(con, "SELECT uuid_geometry FROM v_feature_location WHERE uuid_feature = 'f2'")$uuid_geometry, "gy")
})

test_that("R-23.17: the view never fans out, even with two in-use locations (the failing-check state): one row, the latest recorded", {
  con <- mem_view()
  add_f(con, "f1")
  add_g(con, "ga", "f1", "POINT (300100 6300100)", recorded = "2026-01-01 00:00:00")
  add_g(con, "gb", "f1", "POINT (300200 6300200)", recorded = "2026-03-01 00:00:00")
  v <- DBI::dbGetQuery(con, "SELECT * FROM v_feature_location")
  expect_equal(nrow(v), 1L)
  expect_identical(v$uuid_geometry, "gb")
})

test_that("R-23.17: a superseded piece is never chosen, even when it is the only location; a feature with only a route has no row", {
  con <- mem_view()
  add_f(con, "f1"); add_f(con, "f2"); add_f(con, "f3")
  add_g(con, "g1", "f1", "POINT (300100 6300100)", superseded = "2026-02-01 00:00:00")   # withdrawn: no location at all
  add_g(con, "g2", "f2", "LINESTRING (300100 6300100, 300110 6300110)", role = "route")
  add_g(con, "g3a", "f3", "POINT (300100 6300100)", superseded = "2026-02-01 00:00:00")
  add_g(con, "g3b", "f3", "POINT (300999 6300999)", date_end = "2020-01-01")               # ended but current: kept
  v <- DBI::dbGetQuery(con, "SELECT * FROM v_feature_location ORDER BY uuid_feature")
  expect_identical(v$uuid_feature, "f3")
  expect_identical(v$uuid_geometry, "g3b")
})

test_that("R-23.17: a feature with no feature_geometry row at all is absent (join on uuid_feature); a geometry row with no feature is absent too", {
  con <- mem_view()
  add_f(con, "f1"); add_f(con, "f2")
  add_g(con, "g1", "f1", "POINT (300100 6300100)")
  add_g(con, "g-orph", "f-nobody", "POINT (300100 6300100)")
  expect_identical(DBI::dbGetQuery(con, "SELECT uuid_feature FROM v_feature_location")$uuid_feature, "f1")
})

test_that("R-23.17: a location row whose geom_wkt is not a well-formed POINT keeps its row with NULL easting/northing/lon/lat", {
  con <- mem_view()
  add_f(con, "f1"); add_f(con, "f2")
  add_g(con, "g1", "f1", "POINT (abc def)")
  add_g(con, "g2", "f2", "LINESTRING (300100 6300100, 300110 6300110)")     # wrong type for the role
  v <- DBI::dbGetQuery(con, "SELECT * FROM v_feature_location ORDER BY uuid_feature")
  expect_equal(nrow(v), 2L)
  expect_true(all(is.na(v$easting) & is.na(v$northing) & is.na(v$lon) & is.na(v$lat)))
})

test_that("R-23.17: the POINT may be written in lower case or with extra spaces; the coordinates are the same", {
  con <- mem_view()
  add_f(con, "f1")
  add_g(con, "g1", "f1", "  point ( 280000.000   6266000.000 )  ")
  v <- DBI::dbGetQuery(con, "SELECT * FROM v_feature_location")
  expect_equal(v$easting, 280000); expect_equal(v$northing, 6266000)
  expect_lt(abs(v$lon - 150.6256391718), 1e-8)
})

test_that("R-23.17: a join from a fact table to the view cannot duplicate rows (one row per feature, even with two in-use locations)", {
  s <- t23_setup()
  DBI::dbExecute(s$con, .st_view_feature_location_sql)
  DBI::dbExecute(s$con, "INSERT INTO feature_geometry (uuid, uuid_feature, role, geom_wkt, source, source_crs, quality, recorded)
                         VALUES ('g-dup', 'f-0002', 'location', 'POINT (300999 6300999)', 'x', 'EPSG:7856', 'plan',
                                 TIMESTAMP '2026-09-01 00:00:00')")
  n <- DBI::dbGetQuery(s$con, "SELECT count(*) AS n FROM feature f LEFT JOIN v_feature_location l ON l.uuid_feature = f.uuid")$n
  expect_equal(n, DBI::dbGetQuery(s$con, "SELECT count(*) AS n FROM feature")$n)
})
