# PLAN-23 3.3: the five geometry functions. A geometry row is NEVER edited in
# place: a correction supersedes, a drawing error is withdrawn, a change on the
# ground end-dates (and, when the new shape is known, replaces).
#   R-23.8   add_feature_geometry(): one current row; each refusal
#   R-23.9   the in-use location rule
#   R-23.10  supersede_feature_geometry()
#   R-23.11  following `supersedes` back yields every earlier version in order
#   R-23.12  withdraw_feature_geometry()
#   R-23.13  end_feature_geometry()
#   R-23.14  replace_feature_geometry()
#   R-23.15  a failure inside a call rolls back every write of that call
#   R-23.7   on a pre-117 database every function aborts with the "migration 117" message
# Seed (helper-db.R, PLAN-23 3.8): g-0001 superseded location of f-0001 and its
# successor g-0002; g-0003 in-use location of f-0002 (no dates); g-0004 f-0003;
# g-0005 end-dated location of f-0004 (2020-01-01..2022-12-31) and its in-use
# g-0006 (from 2023-01-01); g-0007/8/9 location/route/outline of f-0005;
# f-0013 (Q.S01) has no geometry. Every successful call here names `db =` the
# throwaway path explicitly.

ACT <- list(actor = "tester", reason = "geometry test")

call_geom <- function(fn, s, ...) do.call(fn, c(list(...), ACT, list(db = s$path)))

new_loc <- function(s, feature = "f-0013", wkt = "POINT (300000.000 6300000.000)", ...) {
  call_geom(add_feature_geometry, s, uuid_feature = feature, role = "location", geom_wkt = wkt,
            source = "fixture", source_crs = "EPSG:7856", quality = "field_gps", ...)
}

chain_back <- function(con, uuid) {
  out <- uuid
  repeat {
    p <- DBI::dbGetQuery(con, "SELECT supersedes FROM feature_geometry WHERE uuid = ?", params = list(out[length(out)]))$supersedes
    if (length(p) == 0 || is.na(p)) break
    out <- c(out, p)
  }
  out
}

# ---- R-23.8 ---------------------------------------------------------------------------------

test_that("R-23.8: add_feature_geometry() inserts one current row with `recorded` set, returns its uuid invisibly, and logs one insert", {
  s <- t23_setup()
  before <- t23_fingerprint(s$con)
  expect_invisible(u <- new_loc(s, comments = "a note"))
  expect_type(u, "character"); expect_length(u, 1L)
  g <- t23_geom(s$con, u)
  expect_equal(nrow(g), 1L)
  expect_identical(g$uuid_feature, "f-0013")
  expect_identical(g$role, "location")
  expect_identical(g$geom_wkt, "POINT (300000.000 6300000.000)")
  expect_identical(g$source, "fixture")
  expect_identical(g$source_crs, "EPSG:7856")
  expect_identical(g$quality, "field_gps")
  expect_identical(g$comments, "a note")
  expect_true(is.na(g$supersedes))
  expect_true(is.na(g$superseded))
  expect_true(is.na(g$date_start)); expect_true(is.na(g$date_end))
  expect_false(is.na(g$recorded))
  expect_lt(abs(as.numeric(difftime(g$recorded, Sys.time(), units = "secs"))), 300)
  expect_equal(nrow(t23_fingerprint(s$con)$geometry), nrow(before$geometry) + 1L)
  lg <- t23_geom_log(s$con)
  expect_equal(nrow(lg), 1L)
  expect_identical(lg$action, "insert")
  expect_identical(lg$uuid_row, u)
  expect_identical(lg$actor, "tester")
  expect_identical(lg$reason, "geometry test")
  expect_equal(DBI::dbGetQuery(s$con, "SELECT count(*) AS n FROM change_log")$n, before$log + 1)
})

test_that("R-23.8: dates may be Date or YYYY-MM-DD strings; NA means unknown", {
  s <- t23_setup()
  u <- new_loc(s, date_start = as.Date("2024-02-03"), date_end = "2025-04-05")
  g <- t23_geom(s$con, u)
  expect_equal(g$date_start, as.Date("2024-02-03"))
  expect_equal(g$date_end, as.Date("2025-04-05"))
  u2 <- new_loc(s, feature = "f-0002", wkt = "POINT (300210 6300210)", date_start = "2010-01-01", date_end = "2011-01-01")
  expect_equal(t23_geom(s$con, u2)$date_end, as.Date("2011-01-01"))
})

test_that("R-23.8: add_feature_geometry() accepts every role with a suitable type, and every quality and source_crs form", {
  s <- t23_setup()
  poly <- "POLYGON ((300000 6300000, 300010 6300000, 300010 6300010, 300000 6300000))"
  line <- "LINESTRING (300000 6300000, 300010 6300010)"
  for (cs in list(list("extent", poly), list("outline", poly), list("route", line))) {
    u <- call_geom(add_feature_geometry, s, uuid_feature = "f-0002", role = cs[[1]], geom_wkt = cs[[2]],
                   source = "plan", source_crs = "unknown", quality = "approximate")
    expect_identical(t23_geom(s$con, u)$role, cs[[1]])
  }
  for (q in c("surveyed", "field_gps", "plan", "imagery", "inferred", "approximate")) {
    u <- call_geom(add_feature_geometry, s, uuid_feature = "f-0002", role = "route", geom_wkt = line,
                   source = "s", source_crs = "EPSG:28356", quality = q)
    expect_identical(t23_geom(s$con, u)$quality, q)
  }
})

refusals <- list(
  list(label = "uuid_feature is not a feature.uuid", args = list(uuid_feature = "f-nope")),
  list(label = "role outside the vocabulary", args = list(role = "centre")),
  list(label = "quality outside the vocabulary", args = list(quality = "great")),
  list(label = "source_crs outside EPSG:<digits>/unknown (lower case)", args = list(source_crs = "epsg:7856")),
  list(label = "source_crs outside EPSG:<digits>/unknown (a name)", args = list(source_crs = "WGS84")),
  list(label = "source_crs 'EPSG:' with no digits", args = list(source_crs = "EPSG:")),
  list(label = "source NA", args = list(source = NA_character_)),
  list(label = "source blank", args = list(source = "   ")),
  list(label = "geom_wkt malformed", args = list(geom_wkt = "POINT (300000)")),
  list(label = "geom_wkt NA", args = list(geom_wkt = NA_character_)),
  list(label = "geometry type not allowed for the role (LINESTRING as a location)",
       args = list(geom_wkt = "LINESTRING (300000 6300000, 300010 6300010)")),
  list(label = "a vertex outside the grid range (a point in degrees)", args = list(geom_wkt = "POINT (150.6 -33.7)")),
  list(label = "a vertex outside the grid range (northing too large)", args = list(geom_wkt = "POINT (300000 12000000)")),
  list(label = "date_end before date_start", args = list(date_start = "2026-02-01", date_end = "2026-01-31")),
  list(label = "an in-use location when the feature already has one (f-0002)",
       args = list(uuid_feature = "f-0002"), pattern = "supersede")
)
for (cs in refusals) local({
  cs <- cs
  test_that(sprintf("R-23.8: add_feature_geometry() refuses %s; nothing written", cs$label), {
    s <- t23_setup()
    before <- t23_fingerprint(s$con)
    base <- list(uuid_feature = "f-0013", role = "location", geom_wkt = "POINT (300000.000 6300000.000)",
                 source = "fixture", source_crs = "EPSG:7856", quality = "field_gps")
    args <- utils::modifyList(base, cs$args)
    t23_expect_refused(do.call(add_feature_geometry, c(args, ACT, list(db = s$path))), cs$pattern)
    now <- t23_fingerprint(s$con)
    expect_identical(now$geometry, before$geometry)
    expect_identical(now$log, before$log)
  })
})

# ---- R-23.9 ---------------------------------------------------------------------------------

test_that("R-23.9: a second in-use location is refused; once the first is superseded, withdrawn or end-dated a new one is accepted", {
  s <- t23_setup()
  t23_expect_refused(new_loc(s, feature = "f-0002", wkt = "POINT (300220 6300220)"), "supersede")
  # f-0001 has a superseded g-0001 and an in-use g-0002: still refused (the superseded row does not matter, the in-use one does)
  t23_expect_refused(new_loc(s, feature = "f-0001", wkt = "POINT (300220 6300220)"), "supersede")
  # withdraw f-0002's location -> free
  call_geom(withdraw_feature_geometry, s, uuid = "g-0003")
  expect_no_error(new_loc(s, feature = "f-0002", wkt = "POINT (300230 6300230)"))
  # end-date f-0003's location -> free
  call_geom(end_feature_geometry, s, uuid = "g-0004", date_end = "2026-01-01")
  expect_no_error(new_loc(s, feature = "f-0003", wkt = "POINT (300330 6300330)"))
  # and an unlocated feature takes one, once
  expect_no_error(new_loc(s, feature = "f-0013"))
  t23_expect_refused(new_loc(s, feature = "f-0013", wkt = "POINT (300001 6300001)"), "supersede")
})

test_that("R-23.9: an end-dated location is accepted beside an in-use one", {
  s <- t23_setup()
  u <- new_loc(s, feature = "f-0002", wkt = "POINT (300199 6300199)", date_start = "2015-01-01", date_end = "2019-12-31")
  g <- t23_geom(s$con, u)
  expect_equal(g$date_end, as.Date("2019-12-31"))
  expect_true(is.na(g$superseded))
  expect_equal(DBI::dbGetQuery(s$con, "SELECT count(*) AS n FROM feature_geometry
                                       WHERE uuid_feature = 'f-0002' AND role = 'location'")$n, 2)
})

test_that("R-23.9: a route (or any non-location role) is accepted beside an in-use location", {
  s <- t23_setup()
  u <- call_geom(add_feature_geometry, s, uuid_feature = "f-0002", role = "route",
                 geom_wkt = "LINESTRING (300200 6300200, 300260 6300260)",
                 source = "plan", source_crs = "EPSG:7856", quality = "plan")
  expect_identical(t23_geom(s$con, u)$role, "route")
  u2 <- call_geom(add_feature_geometry, s, uuid_feature = "f-0002", role = "extent",
                  geom_wkt = "POLYGON ((300190 6300190, 300210 6300190, 300210 6300210, 300190 6300190))",
                  source = "plan", source_crs = "EPSG:7856", quality = "plan")
  expect_identical(t23_geom(s$con, u2)$role, "extent")
})

# ---- R-23.10 --------------------------------------------------------------------------------

test_that("R-23.10: supersede copies unspecified fields, sets supersedes, stamps the old row's superseded = the new row's recorded; old row otherwise unchanged; one insert + one update in change_log", {
  s <- t23_setup()
  old_before <- t23_geom(s$con, "g-0008")           # f-0005's route, a LINESTRING
  log_before <- nrow(t23_geom_log(s$con))
  expect_invisible(
    new <- call_geom(supersede_feature_geometry, s, uuid = "g-0008",
                     geom_wkt = "LINESTRING (300500 6300500, 300560 6300560)", quality = "imagery",
                     source = "corrected drawing")
  )
  expect_type(new, "character")
  n <- t23_geom(s$con, new)
  o <- t23_geom(s$con, "g-0008")
  # the new row: supplied fields, plus copies of everything else
  expect_identical(n$geom_wkt, "LINESTRING (300500 6300500, 300560 6300560)")
  expect_identical(n$quality, "imagery")
  expect_identical(n$source, "corrected drawing")
  expect_identical(n$uuid_feature, old_before$uuid_feature)
  expect_identical(n$role, "route")
  expect_identical(n$source_crs, old_before$source_crs)
  expect_identical(n$date_start, old_before$date_start)
  expect_identical(n$date_end, old_before$date_end)
  expect_identical(n$supersedes, "g-0008")
  expect_true(is.na(n$superseded))
  expect_false(is.na(n$recorded))
  # the old row: superseded stamped to the SAME instant as the new recorded; nothing else changed
  expect_false(is.na(o$superseded))
  expect_equal(o$superseded, n$recorded)
  keep <- setdiff(names(old_before), "superseded")
  expect_identical(o[keep], old_before[keep])
  # change_log: exactly one insert (the new row) and one update (the old row's superseded)
  lg <- t23_geom_log(s$con)
  expect_equal(nrow(lg) - log_before, 2L)
  ins <- lg[lg$action == "insert", ]; upd <- lg[lg$action == "update", ]
  expect_identical(ins$uuid_row, new)
  expect_identical(upd$uuid_row, "g-0008")
  expect_identical(upd$field, "superseded")
  expect_true(is.na(upd$old))
  expect_true(all(lg$actor == "tester" & lg$reason == "geometry test"))
})

test_that("R-23.10: superseding an in-use location with another location is allowed (the old row is leaving, so it does not count against the in-use rule)", {
  s <- t23_setup()
  new <- call_geom(supersede_feature_geometry, s, uuid = "g-0003", geom_wkt = "POINT (300205 6300205)")
  expect_identical(t23_geom(s$con, new)$role, "location")
  expect_equal(DBI::dbGetQuery(s$con, "SELECT count(*) AS n FROM feature_geometry
                                       WHERE uuid_feature = 'f-0002' AND role = 'location' AND superseded IS NULL
                                         AND date_end IS NULL")$n, 1)
})

test_that("R-23.10: supersede can correct metadata alone (quality), leaving the shape as it was", {
  s <- t23_setup()
  old <- t23_geom(s$con, "g-0004")
  new <- call_geom(supersede_feature_geometry, s, uuid = "g-0004", quality = "approximate")
  n <- t23_geom(s$con, new)
  expect_identical(n$quality, "approximate")
  expect_identical(n$geom_wkt, old$geom_wkt)
})

test_that("R-23.10: supersede refuses an already-superseded row (correct the current version, not history); nothing written", {
  s <- t23_setup()
  before <- t23_fingerprint(s$con)
  t23_expect_refused(call_geom(supersede_feature_geometry, s, uuid = "g-0001", geom_wkt = "POINT (300101 6300101)"))
  expect_identical(t23_fingerprint(s$con)$geometry, before$geometry)
  expect_identical(t23_fingerprint(s$con)$log, before$log)
})

test_that("R-23.10: supersede refuses a no-op: nothing supplied, or every supplied field equal to the old row's; nothing written", {
  s <- t23_setup()
  before <- t23_fingerprint(s$con)
  old <- t23_geom(s$con, "g-0003")
  t23_expect_refused(call_geom(supersede_feature_geometry, s, uuid = "g-0003"))
  t23_expect_refused(call_geom(supersede_feature_geometry, s, uuid = "g-0003", geom_wkt = old$geom_wkt))
  t23_expect_refused(call_geom(supersede_feature_geometry, s, uuid = "g-0003", geom_wkt = old$geom_wkt,
                               quality = old$quality, source = old$source))
  expect_identical(t23_fingerprint(s$con)$geometry, before$geometry)
  expect_identical(t23_fingerprint(s$con)$log, before$log)
})

test_that("R-23.10: supersede refuses a row that does not exist", {
  s <- t23_setup()
  before <- t23_fingerprint(s$con)
  t23_expect_refused(call_geom(supersede_feature_geometry, s, uuid = "g-nope", geom_wkt = "POINT (300101 6300101)"))
  expect_identical(t23_fingerprint(s$con)$geometry, before$geometry)
})

sup_refusals <- list(
  list(label = "a vertex outside the grid range", args = list(geom_wkt = "POINT (150.6 -33.7)")),
  list(label = "a geometry type not allowed for the (copied) role", args = list(geom_wkt = "LINESTRING (300000 6300000, 300010 6300010)")),
  list(label = "a malformed geom_wkt", args = list(geom_wkt = "POINT (")),
  list(label = "a quality outside the vocabulary", args = list(quality = "great")),
  list(label = "a blank source", args = list(source = " ")),
  list(label = "a source_crs outside the form", args = list(source_crs = "GDA2020")),
  list(label = "date_end before date_start", args = list(date_start = "2026-02-01", date_end = "2026-01-01"))
)
for (cs in sup_refusals) local({
  cs <- cs
  test_that(sprintf("R-23.10: supersede refuses a replacement that fails validation (%s); nothing written, old row still current", cs$label), {
    s <- t23_setup()
    before <- t23_fingerprint(s$con)
    do <- function() do.call(supersede_feature_geometry, c(list(uuid = "g-0003"), cs$args, ACT, list(db = s$path)))
    t23_expect_refused(do())
    now <- t23_fingerprint(s$con)
    expect_identical(now$geometry, before$geometry)
    expect_identical(now$log, before$log)
    expect_true(is.na(t23_geom(s$con, "g-0003")$superseded))
  })
})

# ---- R-23.11 --------------------------------------------------------------------------------

test_that("R-23.11: following supersedes back from the newest row yields every earlier version in order (a three-version chain)", {
  s <- t23_setup()
  n0 <- DBI::dbGetQuery(s$con, "SELECT count(*) AS n FROM feature_geometry")$n
  v2 <- call_geom(supersede_feature_geometry, s, uuid = "g-0003", geom_wkt = "POINT (300201 6300201)")
  v3 <- call_geom(supersede_feature_geometry, s, uuid = v2, geom_wkt = "POINT (300202 6300202)")
  expect_identical(chain_back(s$con, v3), c(v3, v2, "g-0003"))
  # only the newest is current; rows are never deleted
  cur <- DBI::dbGetQuery(s$con, "SELECT uuid FROM feature_geometry WHERE uuid_feature = 'f-0002' AND superseded IS NULL")$uuid
  expect_identical(cur, v3)
  expect_equal(DBI::dbGetQuery(s$con, "SELECT count(*) AS n FROM feature_geometry")$n, n0 + 2)
  # the seeded two-version chain reads the same way
  expect_identical(chain_back(s$con, "g-0002"), c("g-0002", "g-0001"))
  # the view serves the newest piece
  DBI::dbExecute(s$con, .st_view_feature_location_sql)
  expect_equal(DBI::dbGetQuery(s$con, "SELECT easting FROM v_feature_location WHERE uuid_feature = 'f-0002'")$easting, 300202)
})

# ---- R-23.12 --------------------------------------------------------------------------------

test_that("R-23.12: withdraw stamps superseded with no successor; the feature then has no location in v_feature_location; one update in change_log", {
  s <- t23_setup()
  DBI::dbExecute(s$con, .st_view_feature_location_sql)
  expect_equal(nrow(DBI::dbGetQuery(s$con, "SELECT * FROM v_feature_location WHERE uuid_feature = 'f-0002'")), 1L)
  old <- t23_geom(s$con, "g-0003")
  expect_invisible(r <- call_geom(withdraw_feature_geometry, s, uuid = "g-0003"))
  expect_identical(r, "g-0003")
  g <- t23_geom(s$con, "g-0003")
  expect_false(is.na(g$superseded))
  keep <- setdiff(names(old), "superseded")
  expect_identical(g[keep], old[keep])
  expect_equal(DBI::dbGetQuery(s$con, "SELECT count(*) AS n FROM feature_geometry WHERE supersedes = 'g-0003'")$n, 0)
  expect_equal(nrow(DBI::dbGetQuery(s$con, "SELECT * FROM v_feature_location WHERE uuid_feature = 'f-0002'")), 0L)
  lg <- t23_geom_log(s$con)
  expect_equal(nrow(lg), 1L)
  expect_identical(lg$action, "update"); expect_identical(lg$uuid_row, "g-0003"); expect_identical(lg$field, "superseded")
})

test_that("R-23.12: withdraw refuses a row that does not exist, and one already superseded; nothing written", {
  s <- t23_setup()
  before <- t23_fingerprint(s$con)
  t23_expect_refused(call_geom(withdraw_feature_geometry, s, uuid = "g-nope"))
  t23_expect_refused(call_geom(withdraw_feature_geometry, s, uuid = "g-0001"))
  expect_identical(t23_fingerprint(s$con)$geometry, before$geometry)
  expect_identical(t23_fingerprint(s$con)$log, before$log)
})

# ---- R-23.13 --------------------------------------------------------------------------------

test_that("R-23.13: end_feature_geometry() sets date_end only; the row stays current; one update in change_log", {
  s <- t23_setup()
  old <- t23_geom(s$con, "g-0004")
  expect_invisible(r <- call_geom(end_feature_geometry, s, uuid = "g-0004", date_end = as.Date("2026-05-31")))
  expect_identical(r, "g-0004")
  g <- t23_geom(s$con, "g-0004")
  expect_equal(g$date_end, as.Date("2026-05-31"))
  expect_true(is.na(g$superseded))
  keep <- setdiff(names(old), "date_end")
  expect_identical(g[keep], old[keep])
  lg <- t23_geom_log(s$con)
  expect_equal(nrow(lg), 1L)
  expect_identical(lg$action, "update"); expect_identical(lg$uuid_row, "g-0004"); expect_identical(lg$field, "date_end")
})

test_that("R-23.13: date_end equal to date_start is accepted (both ends inclusive); a YYYY-MM-DD string works", {
  s <- t23_setup()
  call_geom(end_feature_geometry, s, uuid = "g-0006", date_end = "2023-01-01")   # g-0006 starts 2023-01-01
  expect_equal(t23_geom(s$con, "g-0006")$date_end, as.Date("2023-01-01"))
})

test_that("R-23.13: end refuses a superseded row, an already-ended row, a missing row and date_end < date_start; nothing written", {
  s <- t23_setup()
  before <- t23_fingerprint(s$con)
  t23_expect_refused(call_geom(end_feature_geometry, s, uuid = "g-0001", date_end = "2026-01-01"))   # superseded
  t23_expect_refused(call_geom(end_feature_geometry, s, uuid = "g-0005", date_end = "2026-01-01"))   # already ended
  t23_expect_refused(call_geom(end_feature_geometry, s, uuid = "g-nope", date_end = "2026-01-01"))   # missing
  t23_expect_refused(call_geom(end_feature_geometry, s, uuid = "g-0006", date_end = "2022-12-31"))   # before its date_start
  expect_identical(t23_fingerprint(s$con)$geometry, before$geometry)
  expect_identical(t23_fingerprint(s$con)$log, before$log)
})

# ---- R-23.14 --------------------------------------------------------------------------------

test_that("R-23.14: replace ends the old row at date_changed - 1 and adds the new row from date_changed; both stay current; one update + one insert", {
  s <- t23_setup()
  old <- t23_geom(s$con, "g-0006")                # f-0004's in-use location, from 2023-01-01
  expect_invisible(
    new <- call_geom(replace_feature_geometry, s, uuid = "g-0006", geom_wkt = "POINT (300450 6300450)",
                     date_changed = "2026-06-15", source = "resurvey", source_crs = "EPSG:7856",
                     quality = "surveyed", comments = "moved")
  )
  o <- t23_geom(s$con, "g-0006"); n <- t23_geom(s$con, new)
  expect_equal(o$date_end, as.Date("2026-06-14"))
  expect_true(is.na(o$superseded))
  keep <- setdiff(names(old), "date_end")
  expect_identical(o[keep], old[keep])
  expect_equal(n$date_start, as.Date("2026-06-15"))
  expect_true(is.na(n$date_end))
  expect_identical(n$uuid_feature, "f-0004")
  expect_identical(n$role, "location")
  expect_true(is.na(n$supersedes))
  expect_true(is.na(n$superseded))
  expect_identical(n$geom_wkt, "POINT (300450 6300450)")
  expect_identical(n$source, "resurvey"); expect_identical(n$quality, "surveyed"); expect_identical(n$comments, "moved")
  lg <- t23_geom_log(s$con)
  expect_equal(nrow(lg), 2L)
  expect_identical(lg$field[lg$action == "update"], "date_end")
  expect_identical(lg$uuid_row[lg$action == "update"], "g-0006")
  expect_identical(lg$uuid_row[lg$action == "insert"], new)
  # f-0004 still has exactly one in-use location (the new one)
  expect_identical(DBI::dbGetQuery(s$con, "SELECT uuid FROM feature_geometry WHERE uuid_feature = 'f-0004'
                                           AND role = 'location' AND superseded IS NULL AND date_end IS NULL")$uuid, new)
})

test_that("R-23.14: replace keeps the old row's role (a rerouted pipe: route stays a route)", {
  s <- t23_setup()
  new <- call_geom(replace_feature_geometry, s, uuid = "g-0008",
                   geom_wkt = "LINESTRING (300500 6300500, 300600 6300500)", date_changed = "2026-03-01",
                   source = "as-built", source_crs = "EPSG:7856", quality = "plan")
  expect_identical(t23_geom(s$con, new)$role, "route")
  expect_equal(t23_geom(s$con, "g-0008")$date_end, as.Date("2026-02-28"))
})

test_that("R-23.14: replace works when the old row has no date_start (the date_changed rule only bites when one exists)", {
  s <- t23_setup()
  new <- call_geom(replace_feature_geometry, s, uuid = "g-0003", geom_wkt = "POINT (300250 6300250)",
                   date_changed = "2020-01-01", source = "s", source_crs = "unknown", quality = "plan")
  expect_equal(t23_geom(s$con, "g-0003")$date_end, as.Date("2019-12-31"))
  expect_equal(t23_geom(s$con, new)$date_start, as.Date("2020-01-01"))
})

rep_refusals <- list(
  list(label = "a superseded old row", uuid = "g-0001", args = list(date_changed = "2026-06-15")),
  list(label = "an already-ended old row", uuid = "g-0005", args = list(date_changed = "2026-06-15")),
  list(label = "a missing old row", uuid = "g-nope", args = list(date_changed = "2026-06-15")),
  list(label = "date_changed equal to the old date_start", uuid = "g-0006", args = list(date_changed = "2023-01-01")),
  list(label = "date_changed before the old date_start", uuid = "g-0006", args = list(date_changed = "2022-12-31")),
  list(label = "a new row that fails validation (point in degrees)", uuid = "g-0006",
       args = list(date_changed = "2026-06-15", geom_wkt = "POINT (150.6 -33.7)")),
  list(label = "a new row of the wrong type for the role", uuid = "g-0006",
       args = list(date_changed = "2026-06-15", geom_wkt = "LINESTRING (300000 6300000, 300010 6300010)")),
  list(label = "a new row with a bad quality", uuid = "g-0006",
       args = list(date_changed = "2026-06-15", quality = "great"))
)
for (cs in rep_refusals) local({
  cs <- cs
  test_that(sprintf("R-23.14: replace refuses %s; nothing written, the old row is NOT end-dated (atomic)", cs$label), {
    s <- t23_setup()
    before <- t23_fingerprint(s$con)
    base <- list(uuid = cs$uuid, geom_wkt = "POINT (300450 6300450)", date_changed = "2026-06-15",
                 source = "resurvey", source_crs = "EPSG:7856", quality = "surveyed")
    args <- utils::modifyList(base, cs$args)
    t23_expect_refused(do.call(replace_feature_geometry, c(args, ACT, list(db = s$path))))
    now <- t23_fingerprint(s$con)
    expect_identical(now$geometry, before$geometry)
    expect_identical(now$log, before$log)
  })
})

# ---- R-23.15 --------------------------------------------------------------------------------

# A mutation-layer write (db_append or db_update) that fails from the second one on,
# whichever order the function uses: whatever the first write did must be rolled back.
with_second_write_failing <- function(code) {
  orig_append <- db_append
  orig_update <- db_update
  n <- 0L
  testthat::local_mocked_bindings(
    db_append = function(...) { n <<- n + 1L; if (n >= 2L) stop("boom: second write failed"); orig_append(...) },
    db_update = function(...) { n <<- n + 1L; if (n >= 2L) stop("boom: second write failed"); orig_update(...) },
    .package = "sampleTidy"
  )
  force(code)
}

test_that("R-23.15: a failure on the second write of supersede_feature_geometry() rolls back the first: no new row, old row still current, no change_log row", {
  s <- t23_setup()
  before <- t23_fingerprint(s$con)
  with_second_write_failing(
    expect_error(call_geom(supersede_feature_geometry, s, uuid = "g-0003", geom_wkt = "POINT (300205 6300205)"))
  )
  now <- t23_fingerprint(s$con)
  expect_identical(now$geometry, before$geometry)
  expect_identical(now$log, before$log)
})

test_that("R-23.15: a failure on the second write of replace_feature_geometry() rolls back the first: old row not end-dated, no new row, no change_log row", {
  s <- t23_setup()
  before <- t23_fingerprint(s$con)
  with_second_write_failing(
    expect_error(call_geom(replace_feature_geometry, s, uuid = "g-0006", geom_wkt = "POINT (300450 6300450)",
                           date_changed = "2026-06-15", source = "s", source_crs = "EPSG:7856", quality = "surveyed"))
  )
  now <- t23_fingerprint(s$con)
  expect_identical(now$geometry, before$geometry)
  expect_identical(now$log, before$log)
})

test_that("R-23.15: a refused single-write call (add / withdraw / end) leaves no partial row and no change_log row", {
  s <- t23_setup()
  before <- t23_fingerprint(s$con)
  t23_expect_refused(new_loc(s, wkt = "POINT (1 2)"))
  t23_expect_refused(call_geom(withdraw_feature_geometry, s, uuid = "g-0001"))
  t23_expect_refused(call_geom(end_feature_geometry, s, uuid = "g-0005", date_end = "2026-01-01"))
  now <- t23_fingerprint(s$con)
  expect_identical(now$geometry, before$geometry)
  expect_identical(now$log, before$log)
})

# ---- rows are never deleted -----------------------------------------------------------------

test_that("R-23.6 / 3.3: no function ever deletes a feature_geometry row, and the row count only grows by the inserts", {
  s <- t23_setup()
  n0 <- DBI::dbGetQuery(s$con, "SELECT count(*) AS n FROM feature_geometry")$n
  u1 <- new_loc(s)                                                    # +1
  v2 <- call_geom(supersede_feature_geometry, s, uuid = u1, geom_wkt = "POINT (300001 6300001)")   # +1
  call_geom(withdraw_feature_geometry, s, uuid = v2)                  # +0
  call_geom(end_feature_geometry, s, uuid = "g-0004", date_end = "2026-01-01")   # +0
  call_geom(replace_feature_geometry, s, uuid = "g-0006", geom_wkt = "POINT (300450 6300450)",
            date_changed = "2026-06-15", source = "s", source_crs = "EPSG:7856", quality = "surveyed")   # +1
  expect_equal(DBI::dbGetQuery(s$con, "SELECT count(*) AS n FROM feature_geometry")$n, n0 + 3)
  expect_equal(DBI::dbGetQuery(s$con, "SELECT count(*) AS n FROM change_log WHERE tbl = 'feature_geometry' AND action = 'delete'")$n, 0)
})

# ---- R-23.7 ---------------------------------------------------------------------------------

pre117_calls <- list(
  add_feature_geometry = function(path) add_feature_geometry(
    uuid_feature = "f-0001", role = "location", geom_wkt = "POINT (300000 6300000)", source = "s",
    source_crs = "EPSG:7856", quality = "plan", actor = "tester", reason = "x", db = path),
  supersede_feature_geometry = function(path) supersede_feature_geometry(
    uuid = "g-0001", geom_wkt = "POINT (300001 6300001)", actor = "tester", reason = "x", db = path),
  withdraw_feature_geometry = function(path) withdraw_feature_geometry(
    uuid = "g-0001", actor = "tester", reason = "x", db = path),
  end_feature_geometry = function(path) end_feature_geometry(
    uuid = "g-0001", date_end = "2026-01-01", actor = "tester", reason = "x", db = path),
  replace_feature_geometry = function(path) replace_feature_geometry(
    uuid = "g-0001", geom_wkt = "POINT (300001 6300001)", date_changed = "2026-01-01", source = "s",
    source_crs = "EPSG:7856", quality = "plan", actor = "tester", reason = "x", db = path)
)
for (nm in names(pre117_calls)) local({
  nm <- nm
  test_that(sprintf("R-23.7: on a pre-117 database %s() aborts with the 'migration 117' message and writes nothing", nm), {
    old <- local_pre117_db()
    con <- DBI::dbConnect(duckdb::duckdb(), old, read_only = FALSE)
    withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
    n_log <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM change_log")$n
    t23_expect_refused(pre117_calls[[nm]](old), "migration 117")
    expect_false(DBI::dbExistsTable(con, "feature_geometry"))     # nothing was created either
    expect_identical(DBI::dbGetQuery(con, "SELECT count(*) AS n FROM change_log")$n, n_log)
  })
})
