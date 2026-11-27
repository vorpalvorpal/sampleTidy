# PLAN-23 3.2 (D17-4, 2.5 rule 8): end_feature() - a feature's self alias ends
# with it.
#   R-23.23  end_feature() sets feature.date_end and the self arm's date_end in one
#            transaction, with two change_log updates; refuses an already-ended
#            feature, a date before date_start, a feature with a sample dated
#            after the date (through ANY arm), and a missing feature; nothing
#            written on refusal
# Seed (helper-db.R): f-0001 T.S01 has samples on 2025-05-12 and 2025-05-24 via
# its self arm fa-0001; f-0003 T.MW01 has one on 2025-05-25 via fa-0003 (self)
# and also the arms fa-0004 'bs03alt' (transcription_error) and fa-0009
# 'T.BORE' (descriptive); f-0006 T.S06 is already ended (2020-06-30); f-0013
# Q.S01 has no sample.

ACT_END <- list(actor = "tester", reason = "end test")

call_end <- function(s, ...) do.call(end_feature, c(list(...), ACT_END, list(db = s$path)))

feat <- function(con, uuid) DBI::dbGetQuery(con, "SELECT * FROM feature WHERE uuid = ?", params = list(uuid))
self_arm <- function(con, uuid) {
  DBI::dbGetQuery(con, "SELECT * FROM feature_alias WHERE uuid_feature = ? AND kind = 'self'", params = list(uuid))
}

test_that("R-23.23: end_feature() sets feature.date_end and the self arm's date_end, returns the uuid invisibly", {
  s <- t23_setup()
  expect_invisible(out <- call_end(s, uuid = "f-0013", date_end = as.Date("2026-03-31")))
  expect_identical(out, "f-0013")
  expect_equal(feat(s$con, "f-0013")$date_end, as.Date("2026-03-31"))
  expect_equal(self_arm(s$con, "f-0013")$date_end, as.Date("2026-03-31"))
})

test_that("R-23.23: end_feature() writes exactly two change_log updates (feature.date_end, feature_alias.date_end) under the actor and reason", {
  s <- t23_setup()
  n0 <- DBI::dbGetQuery(s$con, "SELECT count(*) AS n FROM change_log")$n
  call_end(s, uuid = "f-0013", date_end = as.Date("2026-03-31"))
  lg <- DBI::dbGetQuery(s$con, "SELECT * FROM change_log ORDER BY tbl")
  expect_identical(nrow(lg), as.integer(n0 + 2))
  new <- lg[lg$reason %in% "end test", ]
  expect_equal(nrow(new), 2L)
  expect_true(all(new$action == "update"))
  expect_true(all(new$field == "date_end"))
  expect_true(all(new$actor == "tester"))
  expect_setequal(new$tbl, c("feature", "feature_alias"))
  expect_identical(new$uuid_row[new$tbl == "feature"], "f-0013")
  expect_identical(new$uuid_row[new$tbl == "feature_alias"], "fa-0024")
  expect_true(is.na(new$old[new$tbl == "feature"]))
  expect_match(new$new[new$tbl == "feature"], "2026-03-31", fixed = TRUE)
})

test_that("R-23.23: other arms are left alone: a former code and a descriptive arm keep their windows", {
  s <- t23_setup()
  before <- DBI::dbGetQuery(s$con, "SELECT * FROM feature_alias WHERE uuid_feature = 'f-0003' AND kind <> 'self' ORDER BY uuid")
  call_end(s, uuid = "f-0003", date_end = as.Date("2026-01-31"))
  after <- DBI::dbGetQuery(s$con, "SELECT * FROM feature_alias WHERE uuid_feature = 'f-0003' AND kind <> 'self' ORDER BY uuid")
  expect_identical(after, before)
  expect_equal(self_arm(s$con, "f-0003")$date_end, as.Date("2026-01-31"))
})

test_that("R-23.23: a YYYY-MM-DD string is accepted for date_end; a sample ON date_end is fine (ends are inclusive)", {
  s <- t23_setup()
  # T.S01's last sample is 2025-05-24 (Sydney day)
  expect_no_error(call_end(s, uuid = "f-0001", date_end = "2025-05-24"))
  expect_equal(feat(s$con, "f-0001")$date_end, as.Date("2025-05-24"))
})

test_that("R-23.23: date_end equal to the feature's date_start is accepted", {
  s <- t23_setup()
  DBI::dbExecute(s$con, "UPDATE feature SET date_start = DATE '2026-02-01' WHERE uuid = 'f-0013'")
  expect_no_error(call_end(s, uuid = "f-0013", date_end = as.Date("2026-02-01")))
})

# ---- refusals ---------------------------------------------------------------------------------

end_refusals <- list(
  list(label = "a feature that does not exist", uuid = "f-none", date_end = "2026-01-01",
       pattern = "f-none"),
  list(label = "an already-ended feature (T.S06 ended 2020-06-30)", uuid = "f-0006", date_end = "2026-01-01",
       pattern = "already"),
  list(label = "a date_end before the feature's date_start", uuid = "f-0013", date_end = "2026-01-31",
       pattern = "date_start",
       prep = function(con) DBI::dbExecute(con, "UPDATE feature SET date_start = DATE '2026-02-01' WHERE uuid = 'f-0013'")),
  list(label = "a feature with a sample (through its self arm) dated after date_end", uuid = "f-0001",
       date_end = "2025-05-20", pattern = "sample"),
  list(label = "a feature with a sample through a NON-self arm dated after date_end", uuid = "f-0003",
       date_end = "2025-06-01", pattern = "sample",
       prep = function(con) t23_sample(con, "s-arm", "fa-0004", "2025-06-10")),
  list(label = "an NA date_end", uuid = "f-0013", date_end = as.Date(NA), pattern = NULL)
)
for (cs in end_refusals) local({
  cs <- cs
  test_that(sprintf("R-23.23: end_feature() refuses %s with sampletidy_error; nothing written", cs$label), {
    s <- t23_setup()
    if (!is.null(cs$prep)) cs$prep(s$con)
    before <- t23_reg_fingerprint(s$con)
    t23_expect_refused(call_end(s, uuid = cs$uuid, date_end = cs$date_end), cs$pattern)
    t23_expect_unchanged(s$con, before)
  })
})

test_that("R-23.23: the sample guard reads the sample's Sydney day: a sample at 23:30 UTC on date_end is the NEXT local day", {
  s <- t23_setup()
  withr::local_options(list("sampletidy.timezone" = "Australia/Sydney"))
  # 2026-02-10 23:30 UTC is 2026-02-11 10:30 in Sydney (AEDT): after a 2026-02-10 end.
  DBI::dbExecute(s$con, "INSERT INTO \"sample\" (uuid, uuid_feature_alias, uuid_project, date, datetime, organisation)
                         VALUES ('s-tz', 'fa-0024', 'p-0001', TIMESTAMP '2026-02-11 00:00:00',
                                 TIMESTAMP '2026-02-10 23:30:00', 'ALS')")
  before <- t23_reg_fingerprint(s$con)
  t23_expect_refused(call_end(s, uuid = "f-0013", date_end = "2026-02-10"), "sample")
  t23_expect_unchanged(s$con, before)
  expect_no_error(call_end(s, uuid = "f-0013", date_end = "2026-02-11"))
})

test_that("R-23.23: atomic - when the second write (the self arm) fails, feature.date_end is not set and no change_log row is written", {
  s <- t23_setup()
  before <- t23_reg_fingerprint(s$con)
  orig_update <- db_update
  n <- 0L
  testthat::local_mocked_bindings(
    db_update = function(...) { n <<- n + 1L; if (n >= 2L) stop("boom: second write failed"); orig_update(...) }
  )
  expect_error(call_end(s, uuid = "f-0013", date_end = "2026-03-31"), "boom")
  t23_expect_unchanged(s$con, before)
})

test_that("R-23.23: a bounded self arm stops claiming its name (R1a): after end_feature() a later sample labelled with the name is not auto-resolved to the ended feature", {
  s <- t23_setup()
  call_end(s, uuid = "f-0013", date_end = "2026-03-31")
  registry <- .rc_load_registry(s$con)
  later <- .rc_feature_candidates("Q.S01", as.Date("2026-06-01"), registry)
  expect_false("f-0013" %in% later$uuid_feature[!is.na(later$uuid_feature)])
  earlier <- .rc_feature_candidates("Q.S01", as.Date("2026-01-15"), registry)
  expect_true("f-0013" %in% earlier$uuid_feature)
})
