# PLAN-23 3.4: the WKT reader (plain R, no sf). "Valid" means WELL-FORMED, not
# OGC-valid (no GEOS, no self-intersection test).
#   R-23.16 .st_wkt_check() accepts and rejects the cases of 3.4, table-driven,
#           and checks the type against the role.
# .st_wkt_check(wkt, role = NULL) is vectorised over wkt (role recycled) and
# returns NA for fine, else the problem; .st_wkt_parse(wkt) returns
# list(type, coords, parts, problem).

ok <- NA_character_

wkt_accept <- c(
  "POINT (1 2)",
  "point(1 2)",
  "Point  (  1.5   -2.5 )",
  "POINT (300000.123 6300000.456)",
  "POINT (1e3 -2E-2)",
  "POINT (+1 2)",
  "POINT (1E+3 2e-3)",
  "LINESTRING (0 0, 1 1)",
  "LINESTRING(0 0,1 1,2 0)",
  "linestring (0 0, 1 1)",
  "POLYGON ((0 0, 1 0, 1 1, 0 0))",
  "POLYGON((0 0,4 0,4 4,0 4,0 0),(1 1,2 1,2 2,1 1))",
  "MULTILINESTRING ((0 0, 1 1), (2 2, 3 3))",
  "MULTIPOLYGON (((0 0, 1 0, 1 1, 0 0)), ((5 5, 6 5, 6 6, 5 5)))"
)
wkt_reject <- c(
  "POINT Z (1 2 3)", "POINT (1 2 3)", "POINT M (1 2 3)", "POINT ZM (1 2 3 4)",
  "POINT EMPTY", "LINESTRING EMPTY", "POLYGON EMPTY", "MULTILINESTRING EMPTY",
  "MULTIPOINT ((1 2))", "MULTIPOINT (1 2, 3 4)",
  "GEOMETRYCOLLECTION (POINT (1 2))",
  "POINT (1 2) x", "POINT (1 2))", "POINT (1 2) POINT (3 4)",
  "POINT (1)", "POINT ()", "POINT (a b)", "POINT (1 2", "POINT 1 2",
  "POINT (Inf 2)", "POINT (NaN 2)", "POINT (NA 2)", "POINT (1e999 2)", "POINT (.5 2)", "POINT (1. 2)",
  "POINT (1,2)",
  "CIRCLE (1 2, 3)", "", "   ",
  "LINESTRING (0 0)", "LINESTRING (1 1, 1 1)", "LINESTRING (1 1, 1 1, 1 1)", "LINESTRING (0 0, 1)",
  "POLYGON ((0 0, 1 0, 0 0))", "POLYGON ((0 0, 1 0, 1 1, 0 1))", "POLYGON ((0 0, 1 0, 1 1, 0 0), (1 1, 2 1, 2 2))",
  "POLYGON (0 0, 1 0, 1 1, 0 0)", "POLYGON ()",
  "MULTILINESTRING ()", "MULTILINESTRING ((0 0))", "MULTILINESTRING ((0 0, 1 1), (2 2, 2 2))",
  "MULTIPOLYGON ()", "MULTIPOLYGON (((0 0, 1 0, 1 1, 0 1)))",
  "MULTIPOLYGON (((0 0, 1 0, 1 1, 0 0)), ((5 5, 6 5, 6 6)))"
)

test_that("R-23.16: .st_wkt_check() returns NA for every well-formed case of 3.4 (any letter case, optional whitespace)", {
  res <- .st_wkt_check(wkt_accept)
  expect_length(res, length(wkt_accept))
  expect_true(is.character(res))
  bad <- wkt_accept[!is.na(res)]
  expect_identical(bad, character(0), info = paste(bad, collapse = " | "))
})

test_that("R-23.16: .st_wkt_check() returns a non-empty problem string for every malformed case of 3.4", {
  res <- .st_wkt_check(wkt_reject)
  expect_length(res, length(wkt_reject))
  expect_true(is.character(res))
  miss <- wkt_reject[is.na(res)]
  expect_identical(miss, character(0), info = paste("accepted but should be refused:", paste(miss, collapse = " | ")))
  expect_true(all(nzchar(res[!is.na(res)])))
})

# one row each, so a failure names the case
all_cases <- data.frame(wkt = c(wkt_accept, wkt_reject), ok = rep(c(TRUE, FALSE), c(length(wkt_accept), length(wkt_reject))),
                        stringsAsFactors = FALSE)
for (i in seq_len(nrow(all_cases))) local({
  w <- all_cases$wkt[[i]]; want_ok <- all_cases$ok[[i]]
  test_that(sprintf("R-23.16: .st_wkt_check(%s) is %s", encodeString(w, quote = "'"), if (want_ok) "fine (NA)" else "a problem"), {
    r <- .st_wkt_check(w)
    expect_length(r, 1L)
    if (want_ok) expect_true(is.na(r), info = r) else expect_false(is.na(r))
  })
})

test_that("R-23.16: NA wkt is a problem, reported as 'missing'", {
  r <- .st_wkt_check(NA_character_)
  expect_identical(r, "missing")
  r2 <- .st_wkt_check(c("POINT (1 2)", NA, "POINT (3 4)"))
  expect_identical(is.na(r2), c(TRUE, FALSE, TRUE))
  expect_identical(r2[[2]], "missing")
})

test_that("R-23.16: .st_wkt_check() is vectorised over wkt and keeps order", {
  r <- .st_wkt_check(c("POINT (1 2)", "POINT (1)", "LINESTRING (0 0, 1 1)", "junk"))
  expect_identical(is.na(r), c(TRUE, FALSE, TRUE, FALSE))
})

# ---- type against role (2.4) ---------------------------------------------------------------

role_cases <- data.frame(
  wkt = c("POINT (1 2)", "POINT (1 2)", "POINT (1 2)", "POINT (1 2)",
          "LINESTRING (0 0, 1 1)", "LINESTRING (0 0, 1 1)", "LINESTRING (0 0, 1 1)", "LINESTRING (0 0, 1 1)",
          "MULTILINESTRING ((0 0, 1 1), (2 2, 3 3))", "MULTILINESTRING ((0 0, 1 1), (2 2, 3 3))",
          "POLYGON ((0 0, 1 0, 1 1, 0 0))", "POLYGON ((0 0, 1 0, 1 1, 0 0))", "POLYGON ((0 0, 1 0, 1 1, 0 0))", "POLYGON ((0 0, 1 0, 1 1, 0 0))",
          "MULTIPOLYGON (((0 0, 1 0, 1 1, 0 0)))", "MULTIPOLYGON (((0 0, 1 0, 1 1, 0 0)))", "MULTIPOLYGON (((0 0, 1 0, 1 1, 0 0)))"),
  role = c("location", "route", "extent", "outline",
           "location", "route", "extent", "outline",
           "route", "location",
           "location", "route", "extent", "outline",
           "extent", "outline", "location"),
  ok = c(TRUE, FALSE, FALSE, FALSE,
         FALSE, TRUE, FALSE, FALSE,
         TRUE, FALSE,
         FALSE, FALSE, TRUE, TRUE,
         TRUE, TRUE, FALSE),
  stringsAsFactors = FALSE
)
for (i in seq_len(nrow(role_cases))) local({
  w <- role_cases$wkt[[i]]; r <- role_cases$role[[i]]; want_ok <- role_cases$ok[[i]]
  test_that(sprintf("R-23.16: a %s as role '%s' is %s", sub(" .*$", "", w), r, if (want_ok) "fine" else "a problem"), {
    res <- .st_wkt_check(w, r)
    if (want_ok) expect_true(is.na(res), info = res) else expect_false(is.na(res))
  })
})

test_that("R-23.16: with role = NULL any accepted type passes; role is recycled over a vector of wkt", {
  expect_true(all(is.na(.st_wkt_check(c("POINT (1 2)", "LINESTRING (0 0, 1 1)", "POLYGON ((0 0, 1 0, 1 1, 0 0))"), role = NULL))))
  r <- .st_wkt_check(c("POINT (1 2)", "POINT (3 4)", "LINESTRING (0 0, 1 1)"), "location")
  expect_identical(is.na(r), c(TRUE, TRUE, FALSE))
  r2 <- .st_wkt_check(c("POINT (1 2)", "LINESTRING (0 0, 1 1)"), c("location", "route"))
  expect_identical(is.na(r2), c(TRUE, TRUE))
  r3 <- .st_wkt_check(c("POINT (1 2)", "LINESTRING (0 0, 1 1)"), c("route", "location"))
  expect_identical(is.na(r3), c(FALSE, FALSE))
})

test_that("R-23.16: a malformed wkt is a problem whatever the role", {
  expect_false(is.na(.st_wkt_check("POINT (1", "location")))
})

# ---- .st_wkt_parse() ---------------------------------------------------------------------------

test_that("R-23.16: .st_wkt_parse() of a POINT gives the type, a 1 x 2 numeric matrix and no problem", {
  p <- .st_wkt_parse("POINT (300000.5 6300000.25)")
  expect_named(p, c("type", "coords", "parts", "problem"), ignore.order = TRUE)
  expect_identical(toupper(p$type), "POINT")
  expect_true(is.matrix(p$coords)); expect_true(is.numeric(p$coords))
  expect_equal(dim(p$coords), c(1L, 2L))
  expect_equal(unname(p$coords[1, ]), c(300000.5, 6300000.25))
  expect_true(is.na(p$problem))
})

test_that("R-23.16: .st_wkt_parse() reads a LINESTRING and a POLYGON vertex for vertex; 'parts' counts the lines / rings", {
  l <- .st_wkt_parse("linestring (0 0, 1 2, 3 4)")
  expect_identical(toupper(l$type), "LINESTRING")
  expect_equal(unname(l$coords), matrix(c(0, 1, 3, 0, 2, 4), ncol = 2))
  expect_true(is.na(l$problem))
  expect_length(l$parts, 1L)

  pg <- .st_wkt_parse("POLYGON ((0 0, 4 0, 4 4, 0 0), (1 1, 2 1, 2 2, 1 1))")
  expect_identical(toupper(pg$type), "POLYGON")
  expect_equal(nrow(pg$coords), 8L)
  expect_equal(ncol(pg$coords), 2L)
  expect_length(pg$parts, 2L)
  expect_true(is.na(pg$problem))

  ml <- .st_wkt_parse("MULTILINESTRING ((0 0, 1 1), (2 2, 3 3), (4 4, 5 5))")
  expect_identical(toupper(ml$type), "MULTILINESTRING")
  expect_length(ml$parts, 3L)
  expect_equal(nrow(ml$coords), 6L)
})

test_that("R-23.16: .st_wkt_parse() of a MULTIPOLYGON reads every vertex of every member", {
  mp <- .st_wkt_parse("MULTIPOLYGON (((0 0, 1 0, 1 1, 0 0)), ((5 5, 6 5, 6 6, 5 5)))")
  expect_identical(toupper(mp$type), "MULTIPOLYGON")
  expect_equal(nrow(mp$coords), 8L)
  expect_equal(range(mp$coords[, 1]), c(0, 6))
  expect_true(is.na(mp$problem))
})

test_that("R-23.16: .st_wkt_parse() of malformed text reports a problem (and does not error)", {
  for (w in c("POINT (1", "POINT Z (1 2 3)", "GEOMETRYCOLLECTION (POINT (1 2))", "", NA_character_)) {
    p <- .st_wkt_parse(w)
    expect_false(is.na(p$problem), info = as.character(w))
  }
})

test_that("R-23.16: the parse and the check agree on every case", {
  for (w in all_cases$wkt) {
    expect_identical(is.na(.st_wkt_parse(w)$problem), is.na(.st_wkt_check(w)), info = w)
  }
})
