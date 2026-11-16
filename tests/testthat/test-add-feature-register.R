# PLAN-23 3.2: add_feature() without coordinates, and its refusals.
#   R-23.3  writes a feature (no coordinates) plus its self alias in one transaction
#   R-23.4  lon / lat / geom_wkt abort, naming add_feature_geometry(); nothing written
#   R-23.5  class vocabulary, extended through st_config("feature_classes_extra")
#   R-23.6  canonical-name clash (ended features included); .st_feature_name_key()
#   R-23.7  pre-117 database: aborts with the "migration 117" message
#   R-23.21 the label matcher is unchanged: a non-sampled feature resolves by its self alias (R1)
# Throwaway databases only (seed_db() + sampletidy.live_db option).

nothing_written <- function(con, before) {
  now <- t23_fingerprint(con)
  expect_identical(now$feature, before$feature)
  expect_identical(now$alias, before$alias)
  expect_identical(now$log, before$log)
  expect_identical(now$geometry, before$geometry)
}

# ---- R-23.3 -------------------------------------------------------------------------------

test_that("R-23.3: add_feature() with no coordinates writes the feature and its self alias, returns the uuid invisibly; class, date_start, virtual round-trip", {
  s <- t23_setup()
  expect_invisible(
    new_uuid <- add_feature(name = "T.NEWR1", site = "T", class = "bore", flow = "groundwater",
                            matrix = "groundwater", date_start = as.Date("2026-03-01"), virtual = TRUE,
                            actor = "tester", reason = "register test")
  )
  expect_type(new_uuid, "character")
  expect_length(new_uuid, 1L)
  f <- DBI::dbGetQuery(s$con, "SELECT * FROM feature WHERE uuid = ?", params = list(new_uuid))
  expect_equal(nrow(f), 1L)
  expect_identical(f$name, "T.NEWR1")
  expect_identical(f$site, "T")
  expect_identical(f$class, "bore")
  expect_identical(f$flow, "groundwater")
  expect_identical(f$matrix, "groundwater")
  expect_equal(f$date_start, as.Date("2026-03-01"))
  expect_true(is.na(f$date_end))
  expect_true(f$virtual)
  expect_false(any(c("lon", "lat", "geom_wkt") %in% names(f)))

  a <- DBI::dbGetQuery(s$con, "SELECT * FROM feature_alias WHERE uuid_feature = ?", params = list(new_uuid))
  expect_equal(nrow(a), 1L)
  expect_identical(a$kind, "self")
  expect_true(a$auto_assign)
  expect_true(is.na(a$confirmed_by))                      # never machine-stamped (A55)
  expect_identical(a$name, "T.NEWR1")
  expect_identical(a$alias_key, .rc_feature_key("T.NEWR1"))

  # both rows are in change_log under the actor, with the reason
  lg <- DBI::dbGetQuery(s$con, "SELECT tbl, action, actor, reason FROM change_log
                                WHERE uuid_row IN (?, ?)", params = list(new_uuid, a$uuid))
  expect_setequal(lg$tbl, c("feature", "feature_alias"))
  expect_true(all(lg$action == "insert" & lg$actor == "tester" & lg$reason == "register test"))
  # a feature added without coordinates has NO location until add_feature_geometry() is called
  expect_equal(DBI::dbGetQuery(s$con, "SELECT count(*) AS n FROM feature_geometry WHERE uuid_feature = ?",
                               params = list(new_uuid))$n, 0)
})

test_that("R-23.3: defaults - class NA, date_start NA, virtual FALSE - and no class is needed", {
  s <- t23_setup()
  u <- add_feature(name = "T.NEWR2", site = "T", actor = "tester", reason = "defaults")
  f <- DBI::dbGetQuery(s$con, "SELECT * FROM feature WHERE uuid = ?", params = list(u))
  expect_true(is.na(f$class))
  expect_true(is.na(f$date_start))
  expect_false(f$virtual)
})

test_that("R-23.3: every class in the vocabulary is accepted (one writes, the rest are validated)", {
  s <- t23_setup()
  for (cl in c("bore", "dust_gauge", "weather_station", "tank", "cable")) {
    u <- add_feature(name = paste0("T.CL", toupper(cl)), site = "T", class = cl, actor = "tester", reason = "vocab")
    expect_identical(DBI::dbGetQuery(s$con, "SELECT class FROM feature WHERE uuid = ?", params = list(u))$class, cl)
  }
})

# ---- R-23.4 -------------------------------------------------------------------------------

test_that("R-23.4: add_feature(lon =, lat =) aborts sampletidy_error naming add_feature_geometry(); nothing written", {
  s <- t23_setup()
  before <- t23_fingerprint(s$con)
  e <- t23_expect_refused(
    add_feature(name = "T.NOCOORD", site = "T", lon = 150.1, lat = -33.1, actor = "tester", reason = "x"),
    "add_feature_geometry")
  expect_false(grepl("Mutation transaction failed", conditionMessage(e), fixed = TRUE))
  nothing_written(s$con, before)
})

test_that("R-23.4: add_feature(geom_wkt =) aborts sampletidy_error naming add_feature_geometry(); nothing written", {
  s <- t23_setup()
  before <- t23_fingerprint(s$con)
  t23_expect_refused(
    add_feature(name = "T.NOWKT", site = "T", geom_wkt = "POINT (300000 6300000)", actor = "tester", reason = "x"),
    "add_feature_geometry")
  nothing_written(s$con, before)
})

test_that("R-23.4: each of lon, lat alone is refused too", {
  s <- t23_setup()
  before <- t23_fingerprint(s$con)
  t23_expect_refused(add_feature(name = "T.NOLON", site = "T", lon = 150.1, actor = "tester", reason = "x"),
                     "add_feature_geometry")
  t23_expect_refused(add_feature(name = "T.NOLAT", site = "T", lat = -33.1, actor = "tester", reason = "x"),
                     "add_feature_geometry")
  nothing_written(s$con, before)
})

test_that("R-23.4: any other unnamed or unknown argument aborts sampletidy_error; nothing written", {
  s <- t23_setup()
  before <- t23_fingerprint(s$con)
  t23_expect_refused(add_feature(name = "T.UNK1", site = "T", colour = "red", actor = "tester", reason = "x"))
  # an eighth positional value falls into `...` (the first seven are class..virtual)
  t23_expect_refused(add_feature("T.UNK2", "T", NA_character_, NA_character_, NA_character_,
                                 as.Date(NA), FALSE, "stray", actor = "tester", reason = "x"))
  nothing_written(s$con, before)
})

# ---- R-23.5 -------------------------------------------------------------------------------

test_that("R-23.5: add_feature() refuses a class outside the vocabulary; nothing written", {
  s <- t23_setup()
  before <- t23_fingerprint(s$con)
  t23_expect_refused(add_feature(name = "T.BADCL", site = "T", class = "widget", actor = "tester", reason = "x"),
                     "class")
  nothing_written(s$con, before)
})

test_that("R-23.5: a class added through st_config('feature_classes_extra') is accepted, and only while it is set", {
  s <- t23_setup()
  before <- t23_fingerprint(s$con)
  withr::with_options(list("sampletidy.feature_classes_extra" = c("widget", "gizmo")), {
    u <- add_feature(name = "T.EXTRA1", site = "T", class = "widget", actor = "tester", reason = "extra class")
    expect_identical(DBI::dbGetQuery(s$con, "SELECT class FROM feature WHERE uuid = ?", params = list(u))$class,
                     "widget")
    t23_expect_refused(add_feature(name = "T.EXTRA2", site = "T", class = "sprocket", actor = "tester", reason = "x"),
                       "class")
  })
  # unset again: refused as before. (st_config() aborts on an unset key, so the code must read it only when set.)
  t23_expect_refused(add_feature(name = "T.EXTRA3", site = "T", class = "widget", actor = "tester", reason = "x"),
                     "class")
  expect_identical(t23_fingerprint(s$con)$feature, before$feature + 1L)
})

test_that("R-23.5: with feature_classes_extra unset (the normal case) add_feature() with a valid class does not abort on the missing key", {
  s <- t23_setup()
  expect_false(isTRUE(!is.null(getOption("sampletidy.feature_classes_extra"))))
  expect_no_error(add_feature(name = "T.NOEXTRA", site = "T", class = "pump", actor = "tester", reason = "x"))
})

# ---- R-23.6 -------------------------------------------------------------------------------

test_that("R-23.6: .st_feature_name_key() is .rc_canonical_point() of the WHOLE trimmed name", {
  x <- c("B.S01", "B.MW02A", "B.MW102", "  t.s1 ", "B.MW12", "TH.G001")
  expect_identical(.st_feature_name_key(x), .rc_canonical_point(trimws(x)))
  expect_identical(.st_feature_name_key(c("B.S01", "B.S1", "B.MW2A", "B.MW02A", "b.s01")),
                   c("B.S1", "B.S1", "B.MW2A", "B.MW2A", "B.S1"))
  expect_false(identical(.st_feature_name_key("B.MW102"), .st_feature_name_key("B.MW12")))
})

test_that("R-23.6: add_feature('T.S1') is refused when T.S01 exists (canonical clash); nothing written", {
  s <- t23_setup()
  before <- t23_fingerprint(s$con)
  # the alias keys differ ('t.s1' vs 't.s01'), so ONLY the canonical rule can refuse this.
  expect_false(.rc_feature_key("T.S1") %in% DBI::dbGetQuery(s$con, "SELECT alias_key FROM feature_alias")$alias_key)
  t23_expect_refused(add_feature(name = "T.S1", site = "T", actor = "tester", reason = "x"))
  nothing_written(s$con, before)
})

test_that("R-23.6: the clash is on the whole name: TH.MW2A is refused beside TH.MW02A, and a differently-cased spelling too", {
  s <- t23_setup()
  before <- t23_fingerprint(s$con)
  t23_expect_refused(add_feature(name = "TH.MW2A", site = "TH", actor = "tester", reason = "x"))
  t23_expect_refused(add_feature(name = "th.mw2a", site = "TH", actor = "tester", reason = "x"))
  nothing_written(s$con, before)
})

test_that("R-23.6: the clash holds when the existing feature is END-DATED (T.S06 ended 2020-06-30)", {
  s <- t23_setup()
  expect_false(is.na(DBI::dbGetQuery(s$con, "SELECT date_end FROM feature WHERE name = 'T.S06'")$date_end))
  before <- t23_fingerprint(s$con)
  t23_expect_refused(add_feature(name = "T.S6", site = "T", actor = "tester", reason = "x"))
  nothing_written(s$con, before)
})

test_that("R-23.6: T.MW102 is accepted beside T.MW12 (a digit run is only de-zeroed at its start)", {
  s <- t23_setup()
  a <- add_feature(name = "T.MW12", site = "T", actor = "tester", reason = "first")
  b <- add_feature(name = "T.MW102", site = "T", actor = "tester", reason = "second")
  expect_false(identical(a, b))
  expect_equal(DBI::dbGetQuery(s$con, "SELECT count(*) AS n FROM feature WHERE name IN ('T.MW12', 'T.MW102')")$n, 2)
})

test_that("R-23.6: the existing refusals still stand: a name with no alphanumeric key, and a key already held by a non-dangling alias", {
  s <- t23_setup()
  before <- t23_fingerprint(s$con)
  t23_expect_refused(add_feature(name = "..", site = "T", actor = "tester", reason = "x"), "alphanumeric")
  t23_expect_refused(add_feature(name = "T.S01", site = "T", actor = "tester", reason = "x"))
  nothing_written(s$con, before)
})

# ---- R-23.7 -------------------------------------------------------------------------------

test_that("R-23.7: on a pre-117 database add_feature() aborts with the 'migration 117' message, never the raw NOT NULL error; nothing written", {
  old <- local_pre117_db()
  withr::local_options(list("sampletidy.live_db" = old))
  con <- DBI::dbConnect(duckdb::duckdb(), old, read_only = FALSE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  n_feat <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM feature")$n
  n_log <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM change_log")$n
  e <- t23_expect_refused(add_feature(name = "T.PRE117", site = "T", actor = "tester", reason = "x"),
                          "migration 117")
  expect_false(grepl("NOT NULL constraint", conditionMessage(e), fixed = TRUE))
  expect_identical(DBI::dbGetQuery(con, "SELECT count(*) AS n FROM feature")$n, n_feat)
  expect_identical(DBI::dbGetQuery(con, "SELECT count(*) AS n FROM change_log")$n, n_log)
})

# ---- R-23.21 (matcher unchanged, R1 holds for a non-sampled feature) -----------------------------

test_that("R-23.21: a feature added with no sample and no position resolves by its exact name through its self alias (R1); the matcher needs no new column", {
  s <- t23_setup()
  u <- add_feature(name = "T.PIT01", site = "T", class = "pit", actor = "tester", reason = "infrastructure feature")
  registry <- .rc_load_registry(s$con)
  cand <- .rc_feature_candidates("T.PIT01", as.Date(NA), registry)
  expect_identical(cand$uuid_feature, u)
  # exactly one candidate, via the self arm
  expect_equal(nrow(cand), 1L)
  expect_identical(registry$feature_alias$kind[registry$feature_alias$uuid == cand$uuid_alias], "self")
  # the registry the matcher reads carries no sampling-point column or switch (R23-2)
  expect_false(any(grepl("sampl", names(registry$feature), ignore.case = TRUE)))
  expect_false(any(grepl("sampl", t23_cols(s$con, "feature"), ignore.case = TRUE)))
})
