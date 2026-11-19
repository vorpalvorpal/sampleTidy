# PLAN-23 3.2 / 2.6 (D17-75, D17-78, D17-81, D17-84): the predecessor and
# flow links.
#   R-23.27  add_feature_predecessor() writes one row; refuses a self-link, a
#            repeated pair, a blank source, a link that closes a loop, and a
#            missing feature
#   R-23.28  add_feature_flow() writes one row; refuses a self-link, a bad drive,
#            a blank source, an overlapping window on the same pair, and a
#            missing feature; end_feature_flow() sets date_end once
# Seed (helper-db.R): fp-0001 says f-0007 (T.S07) continues f-0006 (T.S06) from
# 2020-07-01; ff-0001 is water from f-0005 to f-0007, gravity, from 2024-01-01,
# open.

ACT_LINK <- list(actor = "tester", reason = "link test")

call_pred <- function(s, ...) do.call(add_feature_predecessor, c(list(...), ACT_LINK, list(db = s$path)))
call_flow <- function(s, ...) do.call(add_feature_flow, c(list(...), ACT_LINK, list(db = s$path)))
call_end_flow <- function(s, ...) do.call(end_feature_flow, c(list(...), ACT_LINK, list(db = s$path)))

# ---- R-23.27 add_feature_predecessor() ---------------------------------------------------------

test_that("R-23.27: add_feature_predecessor() writes one row with the given fields and returns its uuid; one change_log insert", {
  s <- t23_setup()
  u <- call_pred(s, uuid = "f-0004", uuid_predecessor = "f-0003", date_break = as.Date("2023-01-01"),
                 source = "test drawing 7", comments = "replacement beside the destroyed one")
  expect_type(u, "character")
  r <- DBI::dbGetQuery(s$con, "SELECT * FROM feature_predecessor WHERE uuid = ?", params = list(u))
  expect_equal(nrow(r), 1L)
  expect_identical(r$uuid_feature, "f-0004")
  expect_identical(r$uuid_predecessor, "f-0003")
  expect_equal(r$date_break, as.Date("2023-01-01"))
  expect_identical(r$source, "test drawing 7")
  expect_identical(r$comments, "replacement beside the destroyed one")
  lg <- t23_log_rows(s$con, "feature_predecessor")
  expect_equal(nrow(lg), 1L)
  expect_identical(lg$action, "insert")
  expect_identical(lg$uuid_row, u)
  expect_identical(lg$actor, "tester")
  expect_identical(lg$reason, "link test")
})

test_that("R-23.27: date_break may be NA (unknown); a YYYY-MM-DD string is accepted", {
  s <- t23_setup()
  u1 <- call_pred(s, uuid = "f-0004", uuid_predecessor = "f-0003", date_break = as.Date(NA), source = "doc")
  expect_true(is.na(DBI::dbGetQuery(s$con, "SELECT date_break FROM feature_predecessor WHERE uuid = ?",
                                    params = list(u1))$date_break))
  u2 <- call_pred(s, uuid = "f-0005", uuid_predecessor = "f-0003", date_break = "2024-02-01", source = "doc")
  expect_equal(DBI::dbGetQuery(s$con, "SELECT date_break FROM feature_predecessor WHERE uuid = ?",
                               params = list(u2))$date_break, as.Date("2024-02-01"))
})

test_that("R-23.27: a predecessor may have several successors and a feature several predecessors (gas points replaced in pairs)", {
  s <- t23_setup()
  expect_no_error(call_pred(s, uuid = "f-0004", uuid_predecessor = "f-0003", date_break = "2023-01-01", source = "doc"))
  expect_no_error(call_pred(s, uuid = "f-0005", uuid_predecessor = "f-0003", date_break = "2023-01-01", source = "doc"))
  expect_no_error(call_pred(s, uuid = "f-0005", uuid_predecessor = "f-0002", date_break = "2023-01-01", source = "doc"))
  expect_equal(DBI::dbGetQuery(s$con, "SELECT count(*) AS n FROM feature_predecessor")$n, 4)
})

pred_refusals <- list(
  list(label = "a self-link", pattern = NULL,
       args = list(uuid = "f-0004", uuid_predecessor = "f-0004", date_break = "2023-01-01", source = "doc")),
  list(label = "a repeated pair (f-0007 already continues f-0006)", pattern = NULL,
       args = list(uuid = "f-0007", uuid_predecessor = "f-0006", date_break = "2021-01-01", source = "doc")),
  list(label = "a blank source", pattern = "source",
       args = list(uuid = "f-0004", uuid_predecessor = "f-0003", date_break = "2023-01-01", source = "   ")),
  list(label = "an NA source", pattern = "source",
       args = list(uuid = "f-0004", uuid_predecessor = "f-0003", date_break = "2023-01-01", source = NA_character_)),
  list(label = "a two-step loop (f-0006 <- f-0007 when f-0007 <- f-0006)", pattern = "loop|cycle",
       args = list(uuid = "f-0006", uuid_predecessor = "f-0007", date_break = as.Date(NA), source = "doc")),
  list(label = "a three-step loop (f-0006 <- f-0004 when f-0004 <- f-0007 <- f-0006)", pattern = "loop|cycle",
       args = list(uuid = "f-0006", uuid_predecessor = "f-0004", date_break = as.Date(NA), source = "doc"),
       prep = function(con) DBI::dbExecute(con, "INSERT INTO feature_predecessor (uuid, uuid_feature, uuid_predecessor, source)
                                                VALUES ('fp-x47', 'f-0004', 'f-0007', 'doc')")),
  list(label = "a missing (later) feature", pattern = "f-none",
       args = list(uuid = "f-none", uuid_predecessor = "f-0003", date_break = "2023-01-01", source = "doc")),
  list(label = "a missing predecessor", pattern = "f-none",
       args = list(uuid = "f-0004", uuid_predecessor = "f-none", date_break = "2023-01-01", source = "doc"))
)
for (cs in pred_refusals) local({
  cs <- cs
  test_that(sprintf("R-23.27: add_feature_predecessor() refuses %s with sampletidy_error; nothing written", cs$label), {
    s <- t23_setup()
    if (!is.null(cs$prep)) cs$prep(s$con)
    before <- t23_reg_fingerprint(s$con)
    t23_expect_refused(do.call(call_pred, c(list(s), cs$args)), cs$pattern)
    t23_expect_unchanged(s$con, before)
  })
})

test_that("R-23.27: a chain that does not loop back is accepted (f-0004 <- f-0007 <- f-0006 is a line, not a loop)", {
  s <- t23_setup()
  expect_no_error(call_pred(s, uuid = "f-0004", uuid_predecessor = "f-0007", date_break = as.Date(NA), source = "doc"))
})

# ---- R-23.28 add_feature_flow() ------------------------------------------------------------------

test_that("R-23.28: add_feature_flow() writes one row with the given fields and returns its uuid; one change_log insert", {
  s <- t23_setup()
  u <- call_flow(s, uuid_from = "f-0001", uuid_to = "f-0002", drive = "pumped", carries = "leachate",
                 date_start = as.Date("2025-03-01"), source = "test pump schedule",
                 comments = "via the rising main")
  expect_type(u, "character")
  r <- DBI::dbGetQuery(s$con, "SELECT * FROM feature_flow WHERE uuid = ?", params = list(u))
  expect_equal(nrow(r), 1L)
  expect_identical(r$uuid_from, "f-0001")
  expect_identical(r$uuid_to, "f-0002")
  expect_identical(r$drive, "pumped")
  expect_identical(r$carries, "leachate")
  expect_equal(r$date_start, as.Date("2025-03-01"))
  expect_true(is.na(r$date_end))
  expect_identical(r$source, "test pump schedule")
  expect_identical(r$comments, "via the rising main")
  lg <- t23_log_rows(s$con, "feature_flow")
  expect_equal(nrow(lg), 1L)
  expect_identical(lg$action, "insert")
  expect_identical(lg$uuid_row, u)
})

test_that("R-23.28: carries and date_start default to NA; links between features at different sites are allowed", {
  s <- t23_setup()
  u <- call_flow(s, uuid_from = "f-0001", uuid_to = "f-0008", drive = "gravity", source = "doc")
  r <- DBI::dbGetQuery(s$con, "SELECT * FROM feature_flow WHERE uuid = ?", params = list(u))
  expect_true(is.na(r$carries))
  expect_true(is.na(r$date_start))
})

test_that("R-23.28: a new link on the same pair after the current one has ENDED is accepted (a change on the ground)", {
  s <- t23_setup()
  DBI::dbExecute(s$con, "UPDATE feature_flow SET date_end = DATE '2025-12-31' WHERE uuid = 'ff-0001'")
  expect_no_error(call_flow(s, uuid_from = "f-0005", uuid_to = "f-0007", drive = "pumped",
                            date_start = as.Date("2026-01-01"), source = "doc"))
})

flow_refusals <- list(
  list(label = "a self-link", pattern = NULL,
       args = list(uuid_from = "f-0001", uuid_to = "f-0001", drive = "gravity", source = "doc")),
  list(label = "a drive outside gravity/pumped", pattern = "drive",
       args = list(uuid_from = "f-0001", uuid_to = "f-0002", drive = "siphon", source = "doc")),
  list(label = "a blank source", pattern = "source",
       args = list(uuid_from = "f-0001", uuid_to = "f-0002", drive = "gravity", source = "  ")),
  list(label = "a window overlapping the current link on the same pair (ff-0001 is open from 2024-01-01)",
       pattern = NULL,
       args = list(uuid_from = "f-0005", uuid_to = "f-0007", drive = "pumped", date_start = as.Date("2025-06-01"),
                   source = "doc")),
  list(label = "an open-start window on a pair that already has a link", pattern = NULL,
       args = list(uuid_from = "f-0005", uuid_to = "f-0007", drive = "gravity", source = "doc")),
  list(label = "a window starting inside an ended link's window on the same pair", pattern = NULL,
       args = list(uuid_from = "f-0005", uuid_to = "f-0007", drive = "pumped", date_start = as.Date("2025-06-01"),
                   source = "doc"),
       prep = function(con) DBI::dbExecute(con, "UPDATE feature_flow SET date_end = DATE '2025-12-31' WHERE uuid = 'ff-0001'")),
  list(label = "a missing feature at the from end", pattern = "f-none",
       args = list(uuid_from = "f-none", uuid_to = "f-0002", drive = "gravity", source = "doc")),
  list(label = "a missing feature at the to end", pattern = "f-none",
       args = list(uuid_from = "f-0001", uuid_to = "f-none", drive = "gravity", source = "doc"))
)
for (cs in flow_refusals) local({
  cs <- cs
  test_that(sprintf("R-23.28: add_feature_flow() refuses %s with sampletidy_error; nothing written", cs$label), {
    s <- t23_setup()
    if (!is.null(cs$prep)) cs$prep(s$con)
    before <- t23_reg_fingerprint(s$con)
    t23_expect_refused(do.call(call_flow, c(list(s), cs$args)), cs$pattern)
    t23_expect_unchanged(s$con, before)
  })
})

# ---- R-23.28 end_feature_flow() ------------------------------------------------------------------

test_that("R-23.28: end_feature_flow() sets date_end only, with one change_log update", {
  s <- t23_setup()
  before <- DBI::dbGetQuery(s$con, "SELECT * FROM feature_flow WHERE uuid = 'ff-0001'")
  call_end_flow(s, uuid = "ff-0001", date_end = as.Date("2026-03-31"))
  after <- DBI::dbGetQuery(s$con, "SELECT * FROM feature_flow WHERE uuid = 'ff-0001'")
  expect_equal(after$date_end, as.Date("2026-03-31"))
  after$date_end <- before$date_end
  expect_identical(after, before)
  lg <- t23_log_rows(s$con, "feature_flow", "ff-0001")
  expect_equal(nrow(lg), 1L)
  expect_identical(lg$action, "update")
  expect_identical(lg$field, "date_end")
})

test_that("R-23.28: end_feature_flow() accepts date_end equal to date_start and a YYYY-MM-DD string", {
  s <- t23_setup()
  expect_no_error(call_end_flow(s, uuid = "ff-0001", date_end = "2024-01-01"))
})

end_flow_refusals <- list(
  list(label = "an already-ended link (date_end is set once)", pattern = "already",
       args = list(uuid = "ff-0001", date_end = as.Date("2026-06-30")),
       prep = function(con) DBI::dbExecute(con, "UPDATE feature_flow SET date_end = DATE '2025-12-31' WHERE uuid = 'ff-0001'")),
  list(label = "a date_end before the link's date_start", pattern = "date_start",
       args = list(uuid = "ff-0001", date_end = as.Date("2023-12-31"))),
  list(label = "a link that does not exist", pattern = "ff-none",
       args = list(uuid = "ff-none", date_end = as.Date("2026-06-30"))),
  list(label = "an NA date_end", pattern = NULL,
       args = list(uuid = "ff-0001", date_end = as.Date(NA)))
)
for (cs in end_flow_refusals) local({
  cs <- cs
  test_that(sprintf("R-23.28: end_feature_flow() refuses %s with sampletidy_error; nothing written", cs$label), {
    s <- t23_setup()
    if (!is.null(cs$prep)) cs$prep(s$con)
    before <- t23_reg_fingerprint(s$con)
    t23_expect_refused(do.call(call_end_flow, c(list(s), cs$args)), cs$pattern)
    t23_expect_unchanged(s$con, before)
  })
})
