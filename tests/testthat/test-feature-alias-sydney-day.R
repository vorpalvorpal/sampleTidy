# Same-day sample collision checks in R/feature-alias.R must compare the
# Australia/Sydney calendar day, not CAST(date AS DATE) (cf. commit 7986ee3,
# .ct_sydney_day_sql). Legacy rows store Sydney midnight as a plain TIMESTAMP
# holding the UTC instant (06-09 14:00 = 06-10 00:00 Sydney); pipeline-written
# rows store naive midnight (06-10 00:00 = Sydney day 06-10).
#
# Drives: .fa_find_collisions() (cross-alias; confirm_feature_aliases() aborts
# without override = TRUE) and .fa_find_self_collisions() (same dangling alias;
# opens a sample_collision/same_alias review row).

fasd_db <- function(existing_date, incoming_date, same_alias = FALSE) {
  env <- parent.frame()
  path <- seed_db(dir = withr::local_tempdir(.local_envir = env))
  withr::local_options(list("sampletidy.live_db" = path), .local_envir = env)
  con <- seed_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE), envir = env)
  # fa-0002 is already confirmed to f-0002; fa-9801 is a pending alias.
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign,
     first_seen, last_seen, confirmed_by) VALUES
    ('fa-9801', NULL, 'T.SYDDAY', 'tsydday', 'pending', 0, FALSE,
     TIMESTAMP '2025-06-01 08:00:00', TIMESTAMP '2025-06-01 08:00:00', NULL)")
  first_alias <- if (same_alias) "fa-9801" else "fa-0002"
  DBI::dbExecute(con, sprintf("INSERT INTO \"sample\"
    (uuid, uuid_feature_alias, uuid_project, date, datetime, organisation) VALUES
    ('s-exist', '%s', 'p-0001', TIMESTAMP '%s', NULL, 'ALS'),
    ('s-incom', 'fa-9801', 'p-0001', TIMESTAMP '%s', NULL, 'ACIRL')",
    first_alias, existing_date, incoming_date))
  con
}

n_collisions <- function(con) nrow(sampleTidy:::.fa_find_collisions(con, "fa-9801", "f-0002"))
n_self <- function(con) nrow(sampleTidy:::.fa_find_self_collisions(con, "fa-9801"))
n_review <- function(con) {
  DBI::dbGetQuery(con, "SELECT count(*) AS n FROM review_queue
                        WHERE kind = 'sample_collision'")$n
}

# ---- cross-alias: .fa_find_collisions() / confirm_feature_aliases() ---------

test_that("sydney-day: legacy Sydney-midnight sample and incoming naive-midnight sample on the same Sydney day collide", {
  con <- fasd_db("2025-06-09 14:00:00", "2025-06-10 00:00:00")
  expect_equal(n_collisions(con), 1L)
})

test_that("sydney-day: confirm_feature_aliases() aborts on that collision unless override = TRUE", {
  con <- fasd_db("2025-06-09 14:00:00", "2025-06-10 00:00:00")
  expect_error(
    confirm_feature_aliases("fa-9801", "f-0002", confirmed_by = "alice"),
    class = "sampletidy_error"
  )
})

test_that("sydney-day: two samples on the same UTC day but different Sydney days do NOT collide", {
  # naive 06-09 00:00 = Sydney day 06-09; legacy 06-09 14:00 = Sydney day 06-10
  con <- fasd_db("2025-06-09 14:00:00", "2025-06-09 00:00:00")
  expect_equal(n_collisions(con), 0L)
  expect_no_error(confirm_feature_aliases("fa-9801", "f-0002", confirmed_by = "alice"))
})

test_that("sydney-day: the cross-alias answer does not depend on the DuckDB session TimeZone", {
  for (tz in c("UTC", "Australia/Sydney", "America/New_York")) {
    con <- fasd_db("2025-06-09 14:00:00", "2025-06-10 00:00:00")
    DBI::dbExecute(con, sprintf("SET TimeZone = '%s'", tz))
    expect_equal(n_collisions(con), 1L, info = tz)
    con2 <- fasd_db("2025-06-09 14:00:00", "2025-06-09 00:00:00")
    DBI::dbExecute(con2, sprintf("SET TimeZone = '%s'", tz))
    expect_equal(n_collisions(con2), 0L, info = tz)
  }
})

test_that("sydney-day (guard): naive-midnight pipeline rows collide on the same day and not on adjacent days", {
  con <- fasd_db("2025-06-10 00:00:00", "2025-06-10 00:00:00")
  expect_equal(n_collisions(con), 1L)
  con2 <- fasd_db("2025-06-10 00:00:00", "2025-06-11 00:00:00")
  expect_equal(n_collisions(con2), 0L)
})

test_that("sydney-day (guard): two legacy Sydney-midnight rows on the same Sydney day still collide", {
  con <- fasd_db("2025-06-09 14:00:00", "2025-06-09 14:00:00")
  expect_equal(n_collisions(con), 1L)
})

# ---- same dangling alias: .fa_find_self_collisions() -------------------------

test_that("sydney-day: legacy + naive samples on one dangling alias, same Sydney day, are a self-collision and open a review row", {
  con <- fasd_db("2025-06-09 14:00:00", "2025-06-10 00:00:00", same_alias = TRUE)
  expect_equal(n_self(con), 1L)
  before <- n_review(con)
  confirm_feature_aliases("fa-9801", "f-0002", confirmed_by = "alice")
  expect_equal(n_review(con), before + 1)
})

test_that("sydney-day: same-UTC-day, different-Sydney-day samples on one dangling alias are NOT a self-collision", {
  con <- fasd_db("2025-06-09 14:00:00", "2025-06-09 00:00:00", same_alias = TRUE)
  expect_equal(n_self(con), 0L)
  before <- n_review(con)
  confirm_feature_aliases("fa-9801", "f-0002", confirmed_by = "alice")
  expect_equal(n_review(con), before)
})

test_that("sydney-day (guard): naive-midnight same-alias same-day pair is still a self-collision", {
  con <- fasd_db("2025-06-10 00:00:00", "2025-06-10 00:00:00", same_alias = TRUE)
  expect_equal(n_self(con), 1L)
  con2 <- fasd_db("2025-06-10 00:00:00", "2025-06-11 00:00:00", same_alias = TRUE)
  expect_equal(n_self(con2), 0L)
})
