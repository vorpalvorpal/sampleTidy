# PLAN-23 3.2 (D17-64, D17-77, 2.5 rule 5): set_feature_mask() - dated mask
# rows, and common names that are also alias arms.
#   R-23.26  ends the current row at date_start - 1 and inserts the new one (one
#            update, one insert in change_log); with date_start NA it replaces an
#            undated current row in place; name = NA only ends the current row;
#            for `common` it adds the alias arm when missing, and refuses a
#            common name another feature holds on an overlapping window, or
#            equal to another feature's name; refuses a variant outside the core
#            plus st_config("mask_variants_extra")
# Seed (helper-db.R): fm-0001 f-0001 long 'Test Surface 01' (undated);
# fm-0003 f-0003 long 'AMBIG' (undated); the common name T.SN01 is held by
# f-0002 until 2024-12-31 (fm-0004, arm fa-0025) and by f-0007 from 2025-01-01
# (fm-0005, arm fa-0026). f-0004 and f-0005 have no mask rows.

ACT_MASK <- list(actor = "tester", reason = "mask test")

call_mask <- function(s, ...) do.call(set_feature_mask, c(list(...), ACT_MASK, list(db = s$path)))

masks <- function(con, feature, variant) {
  DBI::dbGetQuery(con, "SELECT * FROM feature_mask WHERE uuid_feature = ? AND variant = ?
                        ORDER BY date_start NULLS FIRST, uuid", params = list(feature, variant))
}

# ---- the dated move ------------------------------------------------------------------------

test_that("R-23.26: set_feature_mask() ends the current row at date_start - 1 and inserts the new row from date_start; returns the new row's uuid", {
  s <- t23_setup()
  DBI::dbExecute(s$con, "UPDATE feature_mask SET date_start = DATE '2020-01-01' WHERE uuid = 'fm-0001'")
  u <- call_mask(s, uuid = "f-0001", variant = "long", name = "Test Surface One (new sign)",
                 date_start = as.Date("2026-04-01"))
  expect_type(u, "character")
  expect_length(u, 1L)
  m <- masks(s$con, "f-0001", "long")
  expect_equal(nrow(m), 2L)
  old <- m[m$uuid == "fm-0001", ]
  new <- m[m$uuid == u, ]
  expect_equal(old$date_end, as.Date("2026-03-31"))
  expect_identical(old$name, "Test Surface 01")            # the old row is otherwise untouched
  expect_equal(old$date_start, as.Date("2020-01-01"))
  expect_identical(new$name, "Test Surface One (new sign)")
  expect_equal(new$date_start, as.Date("2026-04-01"))
  expect_true(is.na(new$date_end))
})

test_that("R-23.26: the move writes one update (date_end on the old row) and one insert (the new row) in change_log", {
  s <- t23_setup()
  n0 <- DBI::dbGetQuery(s$con, "SELECT count(*) AS n FROM change_log")$n
  u <- call_mask(s, uuid = "f-0001", variant = "long", name = "Test Surface One", date_start = "2026-04-01")
  lg <- t23_log_rows(s$con, "feature_mask")
  expect_equal(nrow(lg), 2L)
  upd <- lg[lg$action == "update", ]
  ins <- lg[lg$action == "insert", ]
  expect_equal(nrow(upd), 1L)
  expect_identical(upd$uuid_row, "fm-0001")
  expect_identical(upd$field, "date_end")
  expect_equal(nrow(ins), 1L)
  expect_identical(ins$uuid_row, u)
  expect_true(all(lg$actor == "tester" & lg$reason == "mask test"))
  expect_identical(DBI::dbGetQuery(s$con, "SELECT count(*) AS n FROM change_log")$n, n0 + 2)
})

test_that("R-23.26: with no current row of the variant, set_feature_mask() only inserts (comments round-trip)", {
  s <- t23_setup()
  u <- call_mask(s, uuid = "f-0004", variant = "long", name = "Fourth creek", date_start = as.Date("2025-07-01"),
                 comments = "from the 2025 sign survey")
  m <- masks(s$con, "f-0004", "long")
  expect_equal(nrow(m), 1L)
  expect_identical(m$uuid, u)
  expect_equal(m$date_start, as.Date("2025-07-01"))
  expect_identical(m$comments, "from the 2025 sign survey")
  lg <- t23_log_rows(s$con, "feature_mask")
  expect_identical(lg$action, "insert")
})

test_that("R-23.26: with date_start NA an undated current row is replaced IN PLACE (same uuid, new name, one update)", {
  s <- t23_setup()
  u <- call_mask(s, uuid = "f-0003", variant = "long", name = "Monitoring bore one")
  m <- masks(s$con, "f-0003", "long")
  expect_equal(nrow(m), 1L)
  expect_identical(m$uuid, "fm-0003")
  expect_identical(u, "fm-0003")
  expect_identical(m$name, "Monitoring bore one")
  expect_true(is.na(m$date_start))
  expect_true(is.na(m$date_end))
  lg <- t23_log_rows(s$con, "feature_mask")
  expect_identical(lg$action, "update")
  expect_identical(lg$field, "name")
  expect_identical(lg$old, "AMBIG")
})

test_that("R-23.26: name = NA only ends the current row (no insert)", {
  s <- t23_setup()
  call_mask(s, uuid = "f-0001", variant = "long", name = NA_character_, date_start = as.Date("2026-04-01"))
  m <- masks(s$con, "f-0001", "long")
  expect_equal(nrow(m), 1L)
  expect_equal(m$date_end, as.Date("2026-03-31"))
  lg <- t23_log_rows(s$con, "feature_mask")
  expect_identical(lg$action, "update")
})

test_that("R-23.26: a variant added through st_config('mask_variants_extra') is accepted (a deployment's EPA number)", {
  s <- t23_setup()
  withr::local_options(list("sampletidy.mask_variants_extra" = "EPA"))
  u <- call_mask(s, uuid = "f-0004", variant = "EPA", name = "26", date_start = as.Date("2026-04-01"))
  expect_identical(masks(s$con, "f-0004", "EPA")$uuid, u)
})

# ---- common names --------------------------------------------------------------------------

test_that("R-23.26: a common name gets a historical_code alias arm of the same key from date_start when none exists", {
  s <- t23_setup()
  u <- call_mask(s, uuid = "f-0004", variant = "common", name = "T.C04", date_start = as.Date("2026-04-01"))
  a <- DBI::dbGetQuery(s$con, "SELECT * FROM feature_alias WHERE alias_key = ?", params = list(.rc_feature_key("T.C04")))
  expect_equal(nrow(a), 1L)
  expect_identical(a$uuid_feature, "f-0004")
  expect_identical(a$kind, "historical_code")
  expect_identical(a$name, "T.C04")
  expect_equal(a$date_start, as.Date("2026-04-01"))
  expect_true(is.na(a$date_end))
  expect_true(a$auto_assign)                 # "so a sample labelled with it still resolves" (2.5 rule 5)
  expect_true(is.na(a$confirmed_by))         # machine-created: never confirmed (A55)
  # the arm and the mask row are both logged
  expect_equal(nrow(t23_log_rows(s$con, "feature_alias", a$uuid)), 1L)
  expect_equal(nrow(t23_log_rows(s$con, "feature_mask", u)), 1L)
})

test_that("R-23.26: a sample labelled with the new common name resolves to the feature through that arm", {
  s <- t23_setup()
  call_mask(s, uuid = "f-0004", variant = "common", name = "T.C04", date_start = as.Date("2026-04-01"))
  registry <- .rc_load_registry(s$con)
  cand <- .rc_feature_candidates("T.C04", as.Date("2026-05-01"), registry)
  expect_identical(unique(cand$uuid_feature), "f-0004")
})

test_that("R-23.26: no second arm is added when the feature already has an arm of that key covering the new window", {
  s <- t23_setup()
  DBI::dbExecute(s$con, "INSERT INTO feature_alias (uuid, uuid_feature, name, alias_key, kind, auto_assign)
                         VALUES ('fa-old4', 'f-0004', 'T.C04', 't.c04', 'historical_code', TRUE)")
  call_mask(s, uuid = "f-0004", variant = "common", name = "T.C04", date_start = as.Date("2026-04-01"))
  a <- DBI::dbGetQuery(s$con, "SELECT uuid FROM feature_alias WHERE alias_key = 't.c04'")
  expect_identical(a$uuid, "fa-old4")
  expect_equal(nrow(t23_log_rows(s$con, "feature_alias")), 0L)
})

test_that("R-23.26: a common name can move by dated rows: the old holder's row ends first, then the new holder takes it from the next day", {
  s <- t23_setup()
  # T.SN01 is held by f-0007 from 2025-01-01. End it at 2026-03-31, give it to f-0005 from 2026-04-01.
  call_mask(s, uuid = "f-0007", variant = "common", name = NA_character_, date_start = as.Date("2026-04-01"))
  expect_equal(DBI::dbGetQuery(s$con, "SELECT date_end FROM feature_mask WHERE uuid = 'fm-0005'")$date_end,
               as.Date("2026-03-31"))
  u <- call_mask(s, uuid = "f-0005", variant = "common", name = "T.SN01", date_start = as.Date("2026-04-01"))
  m <- masks(s$con, "f-0005", "common")
  expect_identical(m$uuid, u)
  expect_equal(m$date_start, as.Date("2026-04-01"))
})

common_refusals <- list(
  list(label = "a common name another feature holds on an overlapping window (T.SN01 is f-0007's from 2025-01-01)",
       args = list(uuid = "f-0005", variant = "common", name = "T.SN01", date_start = as.Date("2026-04-01")),
       pattern = "T.SN01"),
  list(label = "a common name another feature held on a day of an OPEN-START window (f-0002 held T.SN01 until 2024-12-31)",
       args = list(uuid = "f-0005", variant = "common", name = "T.SN01"),
       pattern = "T.SN01",
       prep = function(con) DBI::dbExecute(con, "UPDATE feature_mask SET date_end = DATE '2025-06-30' WHERE uuid = 'fm-0005'")),
  list(label = "a common name equal to another feature's systematic name",
       args = list(uuid = "f-0005", variant = "common", name = "T.S02", date_start = as.Date("2026-04-01")),
       pattern = "T.S02"),
  list(label = "a common name equal to another feature's systematic name up to the canonical key (T.S2 against T.S02)",
       args = list(uuid = "f-0005", variant = "common", name = "T.S2", date_start = as.Date("2026-04-01")),
       pattern = NULL),
  list(label = "a common name equal to an ENDED feature's systematic name (names are never reused)",
       args = list(uuid = "f-0005", variant = "common", name = "T.S06", date_start = as.Date("2026-04-01")),
       pattern = "T.S06")
)
for (cs in common_refusals) local({
  cs <- cs
  test_that(sprintf("R-23.26: set_feature_mask() refuses %s; nothing written", cs$label), {
    s <- t23_setup()
    if (!is.null(cs$prep)) cs$prep(s$con)
    before <- t23_reg_fingerprint(s$con)
    t23_expect_refused(do.call(call_mask, c(list(s), cs$args)), cs$pattern)
    t23_expect_unchanged(s$con, before)
  })
})

test_that("R-23.26: a common name held by another feature only BEFORE the new window does not block it", {
  s <- t23_setup()
  # f-0002 held T.SN01 until 2024-12-31; f-0007 holds it from 2025-01-01, here only
  # until 2025-06-30. A window for f-0005 that starts after both have ended is free.
  DBI::dbExecute(s$con, "UPDATE feature_mask SET date_end = DATE '2025-06-30' WHERE uuid = 'fm-0005'")
  expect_no_error(call_mask(s, uuid = "f-0005", variant = "common", name = "T.SN01",
                            date_start = as.Date("2025-07-01")))
})

# ---- other refusals -------------------------------------------------------------------------

mask_refusals <- list(
  list(label = "a variant outside the core vocabulary", pattern = "variant",
       args = list(uuid = "f-0001", variant = "nickname", name = "x", date_start = as.Date("2026-04-01"))),
  list(label = "the withdrawn variant 'old' (predecessors are links now, D17-75)", pattern = "variant",
       args = list(uuid = "f-0001", variant = "old", name = "T.S00", date_start = as.Date("2026-04-01"))),
  list(label = "a deployment variant while mask_variants_extra is unset", pattern = "variant",
       args = list(uuid = "f-0001", variant = "EPA", name = "26", date_start = as.Date("2026-04-01"))),
  list(label = "a feature that does not exist", pattern = "f-none",
       args = list(uuid = "f-none", variant = "long", name = "x", date_start = as.Date("2026-04-01"))),
  list(label = "a date_start on or before the current row's date_start (the old row cannot end before it began)",
       pattern = "date_start",
       args = list(uuid = "f-0007", variant = "common", name = "T.C07", date_start = as.Date("2025-01-01")))
)
for (cs in mask_refusals) local({
  cs <- cs
  test_that(sprintf("R-23.26: set_feature_mask() refuses %s with sampletidy_error; nothing written", cs$label), {
    s <- t23_setup()
    withr::local_options(list("sampletidy.mask_variants_extra" = NULL))
    before <- t23_reg_fingerprint(s$con)
    t23_expect_refused(do.call(call_mask, c(list(s), cs$args)), cs$pattern)
    t23_expect_unchanged(s$con, before)
  })
})

test_that("R-23.26: atomic - when the insert of the new row fails, the current row is not ended and change_log is unchanged", {
  s <- t23_setup()
  before <- t23_reg_fingerprint(s$con)
  testthat::local_mocked_bindings(db_append = function(...) stop("boom: insert failed"))
  expect_error(call_mask(s, uuid = "f-0001", variant = "long", name = "Test Surface One", date_start = "2026-04-01"),
               "boom")
  t23_expect_unchanged(s$con, before)
})

test_that("R-23.26: the result passes the checks it must keep true (feature_mask_overlap, feature_common_unique, feature_common_alias)", {
  s <- t23_setup()
  call_mask(s, uuid = "f-0001", variant = "long", name = "Test Surface One", date_start = "2026-04-01")
  call_mask(s, uuid = "f-0004", variant = "common", name = "T.C04", date_start = "2026-04-01")
  call_mask(s, uuid = "f-0007", variant = "common", name = NA_character_, date_start = "2026-04-01")
  call_mask(s, uuid = "f-0005", variant = "common", name = "T.SN01", date_start = "2026-04-01")
  res <- db_checks(s$con, tier = "hourly")
  for (nm in c("feature_mask_overlap", "feature_common_unique", "feature_common_alias")) {
    r <- res[res$name == nm, ]
    expect_equal(nrow(r), 1L, info = nm)
    expect_identical(r$status, "pass", info = nm)
  }
})
