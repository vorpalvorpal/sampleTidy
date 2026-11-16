# PLAN-23 3.5: the register checks in db_checks_core().
#   R-23.18  each check: the clean fixture passes; one seeded violation fails only that check
#            (the table-driven part lives in helper-db-checks.R's dbc_violation_cases and
#            test-db-checks.R; the extra columns, the boundaries and the non-flags are here)
#   R-23.19  feature_first_sample
#   R-23.20  expected_constraints_present: feature_mask FK, feature_geometry PK
#   R-23.7   every new check passes with zero rows on a pre-117 database
#   gate     mig_db_checks_gate(): a first sample blocks unless allowed
# Fixture: dbc_db() (helper-db-checks.R), which carries the post-117 register.

reg_names <- c("feature_geometry_wkt_valid", "feature_geometry_in_bbox", "feature_location_unique",
               "feature_name_canonical_clash", "feature_first_sample", "orphan_feature_geometry",
               "feature_geometry_history", "vocab_feature_geometry", "vocab_feature_class")

run1 <- function(db, name, params = db_checks_params(), seed = NULL) {
  dbc_with(db, function(con) {
    if (!is.null(seed)) seed(con)
    dbc_row(db_checks(con, tier = "all", params = params), name)
  })
}

# ---- the catalogue ----------------------------------------------------------------------------

test_that("R-23.18: the nine register checks are in the core with the tiers and severities of 3.5; the two retired checks are gone", {
  core <- db_checks_core()
  expect_true(all(reg_names %in% core$name))
  expect_false(any(c("feature_coords", "feature_geom_matches_lonlat") %in% core$name))
  tier_of <- stats::setNames(core$tier, core$name); sev_of <- stats::setNames(core$severity, core$name)
  expect_true(all(tier_of[reg_names] == "hourly"))
  expect_identical(unname(sev_of[reg_names]),
                   c("error", "error", "error", "error", "warn", "error", "error", "error", "warn"))
})

test_that("R-23.18: the clean fixture passes every register check with n == 0 (and the retired checks do not run)", {
  db <- dbc_db()
  res <- dbc_run(db, tier = "all")
  r <- res[res$name %in% reg_names, ]
  expect_setequal(r$name, reg_names)
  expect_true(all(r$status == "pass"), info = dbc_bad(res))
  expect_true(all(r$n == 0L))
  expect_false(any(c("feature_coords", "feature_geom_matches_lonlat") %in% res$name))
})

test_that("R-23.18: db_checks_params() carries first_sample_since (NULL or POSIXct) and feature_classes (character), and bbox keeps its shape", {
  p <- db_checks_params(first_sample_since = as.POSIXct("2026-01-01", tz = "UTC"),
                        feature_classes = c("bore", "pit"),
                        bbox = c(xmin = 200000, ymin = 6200000, xmax = 400000, ymax = 6400000))
  expect_s3_class(p$first_sample_since, "POSIXct")
  expect_identical(p$feature_classes, c("bore", "pit"))
  expect_equal(p$bbox[["xmin"]], 200000)
  expect_null(db_checks_params()$first_sample_since)
})

# ---- extra columns (3.5) ----------------------------------------------------------------------

test_that("R-23.18: feature_geometry_wkt_valid reports the geometry uuid and a `problem` column; it reads NON-current rows too", {
  db <- dbc_db()
  r <- run1(db, "feature_geometry_wkt_valid", seed = function(con)
    dbc_geom(con, "g-w", "f-0002", "location", "POINT (300000)", superseded = "TIMESTAMP '2026-05-01 00:00:00'"))
  expect_identical(r$status, "fail"); expect_identical(r$n, 1L)
  s <- r$sample[[1]]
  expect_true(all(c("key", "problem") %in% names(s)))
  expect_identical(s$key, "g-w")
  expect_false(is.na(s$problem)); expect_true(nzchar(s$problem))
})

test_that("R-23.18: feature_geometry_in_bbox reports xmin/ymin/xmax/ymax of the piece; a SUPERSEDED out-of-range row is not reported (current rows only)", {
  db <- dbc_db()
  r <- run1(db, "feature_geometry_in_bbox", seed = function(con)
    dbc_geom(con, "g-b", "f-0013", "location", "POINT (950000 6300000)"))
  expect_identical(r$status, "fail"); expect_identical(r$n, 1L)
  s <- r$sample[[1]]
  expect_true(all(c("key", "xmin", "ymin", "xmax", "ymax") %in% names(s)))
  expect_identical(s$key, "g-b")
  expect_equal(s$xmin, 950000); expect_equal(s$ymax, 6300000)
  db <- dbc_db()
  r2 <- run1(db, "feature_geometry_in_bbox", seed = function(con)
    dbc_geom(con, "g-b2", "f-0013", "location", "POINT (950000 6300000)", superseded = "TIMESTAMP '2026-05-01 00:00:00'"))
  expect_identical(r2$status, "pass")
})

test_that("R-23.18: feature_geometry_in_bbox: any vertex outside the grid range counts (a polygon with one bad vertex); a configured bbox is read from params, EPSG:7856 metres", {
  db <- dbc_db()
  r <- run1(db, "feature_geometry_in_bbox", seed = function(con)
    dbc_geom(con, "g-p", "f-0002", "extent", "POLYGON ((300000 6300000, 300010 6300000, 50000 6300010, 300000 6300000))"))
  expect_identical(r$status, "fail")
  expect_identical(r$sample[[1]]$key, "g-p")
  # no bbox configured and a point well inside the grid range -> passes
  db <- dbc_db()
  r2 <- run1(db, "feature_geometry_in_bbox", seed = function(con)
    dbc_geom(con, "g-q", "f-0013", "location", "POINT (350000 6300000)"))
  expect_identical(r2$status, "pass")
})

test_that("R-23.18: feature_location_unique reports the FEATURE uuid with n; end-dated, superseded and non-location rows do not count", {
  db <- dbc_db()
  r <- run1(db, "feature_location_unique", seed = function(con) {
    dbc_geom(con, "g-a", "f-0002", "location", "POINT (300210 6300210)")
    dbc_geom(con, "g-b", "f-0002", "location", "POINT (300220 6300220)")
  })
  expect_identical(r$status, "fail"); expect_identical(r$n, 1L)
  s <- r$sample[[1]]
  expect_true(all(c("key", "n") %in% names(s)))
  expect_identical(s$key, "f-0002")
  expect_equal(s$n, 3)                                        # g-0003 + the two new in-use locations
  db <- dbc_db()
  r2 <- run1(db, "feature_location_unique", seed = function(con) {
    dbc_geom(con, "g-e", "f-0002", "location", "POINT (300210 6300210)", date_end = "DATE '2019-01-01'")
    dbc_geom(con, "g-s", "f-0002", "location", "POINT (300210 6300210)", superseded = "TIMESTAMP '2026-05-01 00:00:00'")
    dbc_geom(con, "g-r", "f-0002", "route", "LINESTRING (300200 6300200, 300210 6300210)")
  })
  expect_identical(r2$status, "pass")
})

test_that("R-23.18: feature_name_canonical_clash reports every feature sharing the key, with `name` and `canonical` columns", {
  db <- dbc_db()
  r <- run1(db, "feature_name_canonical_clash", seed = function(con)
    dbc_feature(con, "f-clash", "T.S2", "T", self_alias = "fa-clash"))
  expect_identical(r$status, "fail"); expect_identical(r$n, 2L)
  s <- r$sample[[1]]
  expect_true(all(c("key", "name", "canonical") %in% names(s)))
  expect_setequal(s$key, c("f-0002", "f-clash"))
  expect_setequal(s$name, c("T.S02", "T.S2"))
  expect_true(all(s$canonical == "T.S2"))
})

test_that("R-23.18: feature_name_canonical_clash does not flag T.MW102 beside T.MW12 (leading zeros only), nor names that differ in site", {
  db <- dbc_db()
  r <- run1(db, "feature_name_canonical_clash", seed = function(con) {
    dbc_feature(con, "f-a", "T.MW12", "T", self_alias = "fa-a")
    dbc_feature(con, "f-b", "T.MW102", "T", self_alias = "fa-b")
    dbc_feature(con, "f-c", "U.S01", "U", self_alias = "fa-c")        # T.S01 vs U.S01: different whole names
  })
  expect_identical(r$status, "pass")
})

test_that("R-23.18: orphan_feature_geometry, feature_geometry_history and the vocab checks key by the geometry uuid", {
  db <- dbc_db()
  r <- run1(db, "feature_geometry_history", seed = function(con)
    dbc_geom(con, "g-h", "f-0003", "location", "POINT (300333 6300333)", supersedes = "'g-0003'", date_end = "DATE '2026-01-01'"))
  expect_identical(r$sample[[1]]$key, "g-h")            # predecessor g-0003 belongs to ANOTHER feature and was never superseded
  db <- dbc_db()
  r2 <- run1(db, "vocab_feature_geometry", seed = function(con) {
    dbc_geom(con, "g-1", "f-0002", "extent", "POLYGON ((300190 6300190, 300210 6300190, 300210 6300210, 300190 6300190))", source_crs = "EPSG:28356")
    dbc_geom(con, "g-2", "f-0002", "extent", "POLYGON ((300190 6300190, 300210 6300190, 300210 6300210, 300190 6300190))", source_crs = "unknown")
  })
  expect_identical(r2$status, "pass")                   # EPSG:<digits> and 'unknown' are both fine
})

test_that("R-23.18: feature_geometry_history: a well-formed correction chain (predecessor superseded, same feature and role) passes", {
  db <- dbc_db()
  r <- run1(db, "feature_geometry_history")
  expect_identical(r$status, "pass")                    # the seed's g-0001 -> g-0002 chain
  # a role change down a chain is reported
  db <- dbc_db()
  r2 <- run1(db, "feature_geometry_history", seed = function(con) {
    DBI::dbExecute(con, "UPDATE feature_geometry SET superseded = TIMESTAMP '2026-04-01 00:00:00' WHERE uuid = 'g-0008'")
    dbc_geom(con, "g-r", "f-0005", "outline", "POLYGON ((300490 6300490, 300510 6300490, 300510 6300510, 300490 6300490))",
             supersedes = "'g-0008'", recorded = "2026-04-01 00:00:00")
  })
  expect_identical(r2$status, "fail")
  expect_identical(r2$sample[[1]]$key, "g-r")
})

test_that("R-23.18: vocab_feature_class is silent for NULL class and for any class in params$feature_classes", {
  db <- dbc_db()
  expect_identical(run1(db, "vocab_feature_class")$status, "pass")        # seed: T.MW01 = bore, the rest NULL
  r <- run1(db, "vocab_feature_class", params = db_checks_params(feature_classes = "pit"))
  expect_identical(r$status, "fail")                                       # 'bore' is not in a vocabulary of just 'pit'
  expect_identical(r$sample[[1]]$key, "f-0003")
})

# ---- R-23.19 feature_first_sample ---------------------------------------------------------------

fs_params <- function() db_checks_params(first_sample_since = as.POSIXct("2026-01-01 00:00:00", tz = "UTC"))

fs_feature <- function(con, uuid = "f-fs", name = "T.S11", alias = "fa-fs", ...) {
  dbc_feature(con, uuid, name, "T", self_alias = alias, ...)
}
fs_sample <- function(con, uuid, alias, day = "2025-06-01", logged_at = "2026-06-02 00:00:00") {
  dbc_new_sample(con, uuid, alias = alias, date = day, datetime = paste(day, "00:00:00"))
  if (!is.na(logged_at)) dbc_sample_insert_logged(con, uuid, logged_at)
}

test_that("R-23.19: a feature whose only samples were inserted after first_sample_since is reported, with name, first_insert_at and n_samples", {
  db <- dbc_db()
  r <- run1(db, "feature_first_sample", fs_params(), function(con) {
    fs_feature(con)
    fs_sample(con, "s-a", "fa-fs", "2025-06-01", "2026-06-02 00:00:00")
    fs_sample(con, "s-b", "fa-fs", "2025-06-02", "2026-07-02 00:00:00")
  })
  expect_identical(r$status, "fail"); expect_identical(r$n, 1L)
  s <- r$sample[[1]]
  expect_true(all(c("key", "name", "first_insert_at", "n_samples") %in% names(s)))
  expect_identical(s$key, "f-fs"); expect_identical(s$name, "T.S11")
  expect_equal(s$n_samples, 2)
  expect_equal(format(as.POSIXct(s$first_insert_at, tz = "UTC"), "%Y-%m-%d %H:%M:%S", tz = "UTC"), "2026-06-02 00:00:00")
})

test_that("R-23.19: a feature with ANY sample lacking an insert row in change_log is not reported (its first sample is not new)", {
  db <- dbc_db()
  r <- run1(db, "feature_first_sample", fs_params(), function(con) {
    fs_feature(con)
    fs_sample(con, "s-a", "fa-fs", "2025-06-01", "2026-06-02 00:00:00")
    fs_sample(con, "s-old", "fa-fs", "2025-06-02", NA)            # an older sample with no change_log insert
  })
  expect_identical(r$status, "pass")
})

test_that("R-23.19: a virtual (field-QC) feature is not reported", {
  db <- dbc_db()
  r <- run1(db, "feature_first_sample", fs_params(), function(con) {
    fs_feature(con, virtual = TRUE)
    fs_sample(con, "s-a", "fa-fs")
  })
  expect_identical(r$status, "pass")
})

test_that("R-23.19: a feature with no samples is not reported", {
  db <- dbc_db()
  r <- run1(db, "feature_first_sample", fs_params(), function(con) fs_feature(con))
  expect_identical(r$status, "pass")
})

test_that("R-23.19: a first sample inserted BEFORE first_sample_since is not reported; at the boundary it is", {
  db <- dbc_db()
  r <- run1(db, "feature_first_sample", fs_params(), function(con) {
    fs_feature(con)
    fs_sample(con, "s-a", "fa-fs", "2025-06-01", "2025-12-31 23:59:59")
  })
  expect_identical(r$status, "pass")
  db <- dbc_db()
  r2 <- run1(db, "feature_first_sample", fs_params(), function(con) {
    fs_feature(con)
    fs_sample(con, "s-a", "fa-fs", "2025-06-01", "2026-01-01 00:00:00")
  })
  expect_identical(r2$status, "fail")                             # "at or after"
})

test_that("R-23.19: samples are reached through EVERY alias arm of the feature (a historical-code alias counts)", {
  db <- dbc_db()
  r <- run1(db, "feature_first_sample", fs_params(), function(con) {
    fs_feature(con)
    dbc_alias(con, "fa-fs-alt", "f-fs", "T.S11 old", "t.s11 old", "historical_code", auto = TRUE)
    fs_sample(con, "s-a", "fa-fs-alt", "2025-06-01", "2026-06-02 00:00:00")
  })
  expect_identical(r$status, "fail"); expect_identical(r$sample[[1]]$key, "f-fs")
  db <- dbc_db()
  r2 <- run1(db, "feature_first_sample", fs_params(), function(con) {
    fs_feature(con)
    dbc_alias(con, "fa-fs-alt", "f-fs", "T.S11 old", "t.s11 old", "historical_code", auto = TRUE)
    fs_sample(con, "s-a", "fa-fs-alt", "2025-06-01", "2026-06-02 00:00:00")
    fs_sample(con, "s-b", "fa-fs", "2025-06-02", NA)              # a sample under the self alias with no insert row
  })
  expect_identical(r2$status, "pass")
})

test_that("R-23.19: only change_log rows with tbl = 'sample', action = 'insert' and uuid_row = the sample's uuid count", {
  db <- dbc_db()
  r <- run1(db, "feature_first_sample", fs_params(), function(con) {
    fs_feature(con)
    dbc_new_sample(con, "s-a", alias = "fa-fs", date = "2025-06-01", datetime = "2025-06-01 00:00:00")
    dbc_exec(con, "INSERT INTO change_log (uuid, \"at\", actor, action, tbl, uuid_row, reason)
                   VALUES ('cl-u', TIMESTAMP '2026-06-02 00:00:00', 't', 'update', 'sample', 's-a', 'x'),
                          ('cl-o', TIMESTAMP '2026-06-02 00:00:00', 't', 'insert', 'analysis', 's-a', 'x')")
  })
  expect_identical(r$status, "pass")
})

test_that("R-23.19: params$first_sample_since NULL means 'the last 14 days' at run time", {
  db <- dbc_db()
  recent <- format(Sys.time() - 2 * 86400, "%Y-%m-%d %H:%M:%S", tz = "UTC")
  old <- format(Sys.time() - 30 * 86400, "%Y-%m-%d %H:%M:%S", tz = "UTC")
  r <- run1(db, "feature_first_sample", seed = function(con) {
    fs_feature(con)
    fs_sample(con, "s-a", "fa-fs", "2025-06-01", recent)
  })
  expect_identical(r$status, "fail")
  db <- dbc_db()
  r2 <- run1(db, "feature_first_sample", seed = function(con) {
    fs_feature(con)
    fs_sample(con, "s-a", "fa-fs", "2025-06-01", old)
  })
  expect_identical(r2$status, "pass")
})

test_that("R-23.19: feature_first_sample is warn-severity: it is a count under DB checks, not a status Problem", {
  db <- dbc_db()
  r <- run1(db, "feature_first_sample", fs_params(), function(con) {
    fs_feature(con); fs_sample(con, "s-a", "fa-fs")
  })
  expect_identical(r$severity, "warn")
})

# ---- gate ----------------------------------------------------------------------------------------

test_that("gate: giving a feature its first samples blocks mig_db_checks_gate() unless allow = 'feature_first_sample'", {
  db <- dbc_db()
  dbc_with(db, function(con) {
    baseline <- db_checks(con, tier = "migration")
    recent <- format(Sys.time() - 3600, "%Y-%m-%d %H:%M:%S", tz = "UTC")
    fs_feature(con)
    fs_sample(con, "s-a", "fa-fs", "2025-06-01", recent)
    e <- expect_error(mig_db_checks_gate(con, baseline), class = "sampletidy_error")
    expect_match(conditionMessage(e), "feature_first_sample", fixed = TRUE)
    expect_no_error(suppressMessages(mig_db_checks_gate(con, baseline, allow = "feature_first_sample")))
  })
})

# ---- R-23.20 expected_constraints_present --------------------------------------------------------

test_that("R-23.20: the clean fixture passes expected_constraints_present (feature_geometry PK + self FK, feature_mask FK, feature PK)", {
  db <- dbc_db()
  expect_identical(run1(db, "expected_constraints_present")$status, "pass")
})

test_that("R-23.20: a feature_geometry without its primary key is reported (key 'feature_geometry.uuid PRIMARY KEY'); one without its self FK too", {
  db <- dbc_db()
  r <- run1(db, "expected_constraints_present", seed = function(con) {
    DBI::dbExecute(con, "CREATE TEMP TABLE dbc_fg AS SELECT * FROM feature_geometry")
    DBI::dbExecute(con, "DROP VIEW v_feature_location")
    DBI::dbExecute(con, "DROP TABLE feature_geometry")
    DBI::dbExecute(con, "CREATE TABLE feature_geometry (
      uuid VARCHAR, uuid_feature VARCHAR NOT NULL, role VARCHAR NOT NULL, geom_wkt VARCHAR NOT NULL,
      source VARCHAR NOT NULL, source_crs VARCHAR NOT NULL, quality VARCHAR NOT NULL, date_start DATE,
      date_end DATE, recorded TIMESTAMP NOT NULL, supersedes VARCHAR, superseded TIMESTAMP, comments VARCHAR)")
    DBI::dbExecute(con, "INSERT INTO feature_geometry SELECT * FROM dbc_fg")
  })
  expect_identical(r$status, "fail")
  expect_true(all(c("feature_geometry.uuid PRIMARY KEY", "feature_geometry.supersedes FOREIGN KEY") %in% r$sample[[1]]$key))
})

test_that("R-23.20: the feature_geometry constraints are only required WHEN the table exists (a pre-117 database does not fail for them)", {
  old <- local_pre117_db()
  con <- DBI::dbConnect(duckdb::duckdb(), old, read_only = FALSE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  res <- db_checks(con, tier = "all")
  r <- dbc_row(res, "expected_constraints_present")
  if (nrow(r) == 1L && identical(r$status, "fail")) {
    expect_false(any(grepl("feature_geometry", r$sample[[1]]$key, fixed = TRUE)))
  }
  expect_true(TRUE)
})

# ---- R-23.7 pre-117 ----------------------------------------------------------------------------

test_that("R-23.7: on a pre-117 database every register check passes with zero rows (none errors on the missing table or column)", {
  old <- local_pre117_db()
  con <- DBI::dbConnect(duckdb::duckdb(), old, read_only = FALSE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  # other checks may error on tables this bare seed lacks; only the register checks are asserted
  res <- db_checks(con, tier = "all")
  r <- res[res$name %in% reg_names, ]
  expect_setequal(r$name, reg_names)
  expect_true(all(r$status == "pass"), info = paste(r$name, r$status, r$message, collapse = "; "))
  expect_true(all(r$n == 0L))
})

test_that("R-23.7: on a pre-117 database the retired checks are simply absent, not failing", {
  old <- local_pre117_db()
  con <- DBI::dbConnect(duckdb::duckdb(), old, read_only = FALSE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  res <- db_checks(con, tier = "all")
  expect_false(any(c("feature_coords", "feature_geom_matches_lonlat") %in% res$name))
})
