# Plan 09 - R/snapshot.R: `snapshot_db()` / `prune_snapshots()` (DESIGN §9.1).

test_that("R-9.4: a snapshot opens read-only with a matching analysis count, and leaves no .tmp behind", {
  db_path <- seed_db()
  dest_dir <- withr::local_tempdir()

  snap_path <- snapshot_db(db = db_path, dest_dir = dest_dir)

  expect_true(file.exists(snap_path))
  expect_match(basename(snap_path), "^monitoring_\\d{4}-\\d{2}-\\d{2}\\.duckdb$")

  live_con <- DBI::dbConnect(duckdb::duckdb(), db_path, read_only = TRUE)
  live_count <- DBI::dbGetQuery(live_con, "SELECT count(*) AS n FROM analysis")$n
  DBI::dbDisconnect(live_con, shutdown = TRUE)

  snap_con <- DBI::dbConnect(duckdb::duckdb(), snap_path, read_only = TRUE)
  snap_count <- DBI::dbGetQuery(snap_con, "SELECT count(*) AS n FROM analysis")$n
  DBI::dbDisconnect(snap_con, shutdown = TRUE)

  expect_equal(snap_count, live_count)

  tmp_files <- list.files(dest_dir, pattern = "\\.tmp$")
  expect_length(tmp_files, 0)
})

# ---- prune_snapshots(): tiered retention (7 days all / 8 weeks weekly / monthly forever) ----

prune_mk <- function(dir, dates) {
  for (d in as.character(as.Date(dates, origin = "1970-01-01"))) {
    writeLines("", file.path(dir, sprintf("monitoring_%s.duckdb", d)))
  }
  invisible(dir)
}
prune_left <- function(dir) {
  f <- list.files(dir, pattern = "^monitoring_\\d{4}-\\d{2}-\\d{2}\\.duckdb$")
  sort(as.Date(sub("^monitoring_(\\d{4}-\\d{2}-\\d{2})\\.duckdb$", "\\1", f)))
}
# Independent oracle: dates (Date vector) -> retained Dates.
prune_oracle <- function(dates, today, keep_days = 7, keep_weeks = 8) {
  dates <- sort(unique(dates))
  age <- as.numeric(today - dates)
  z1 <- dates[age <= keep_days]
  z2 <- dates[age > keep_days & age <= keep_days + 7 * keep_weeks]
  z3 <- dates[age > keep_days + 7 * keep_weeks]
  newest_per <- function(x, key) {
    if (length(x) == 0) return(x[0])
    as.Date(vapply(split(as.numeric(x), key), max, numeric(1)), origin = "1970-01-01")
  }
  sort(c(z1, newest_per(z2, format(z2, "%G-W%V")), newest_per(z3, format(z3, "%Y-%m"))))
}
prune_run <- function(dir, ...) {
  prune_snapshots(dir, ...)
  prune_left(dir)
}
# Newest date (weekday == target, 1=Monday) with age >= min_age.
prune_weekday_at_or_older <- function(wday, min_age, today = Sys.Date()) {
  cand <- today - (min_age:(min_age + 6))
  cand[as.integer(format(cand, "%u")) == wday]
}

test_that("R-9.4: prune_snapshots() default policy matches the oracle on 400 consecutive daily files", {
  d <- withr::local_tempdir()
  today <- Sys.Date()
  all_dates <- today - 0:399
  prune_mk(d, all_dates)
  got <- prune_run(d)
  expect_equal(as.character(got), as.character(prune_oracle(all_dates, today)))
})

test_that("R-9.4: prune_snapshots() keeps every file aged <= 7 days, and the age-7 file survives", {
  d <- withr::local_tempdir()
  today <- Sys.Date()
  prune_mk(d, today - 0:7)
  got <- prune_run(d)
  expect_equal(as.character(got), as.character(sort(today - 0:7)))
})

test_that("R-9.4: age 7 is kept, age 8 falls under the weekly rule (oracle over ages 5..12)", {
  d <- withr::local_tempdir()
  today <- Sys.Date()
  all_dates <- today - 5:12
  prune_mk(d, all_dates)
  got <- prune_run(d)
  expect_true((today - 7) %in% got)
  expect_true((today - 8) %in% got) # newest of the zone-2 files, always retained
  expect_equal(as.character(got), as.character(prune_oracle(all_dates, today)))
})

test_that("R-9.4: within one ISO week of the weekly zone only the newest snapshot survives", {
  d <- withr::local_tempdir()
  today <- Sys.Date()
  mon <- prune_weekday_at_or_older(1, 15) # Monday aged 15..21, so Mon..Sun all in zone 2
  expect_true(as.numeric(today - (mon + 6)) >= 9)
  prune_mk(d, mon + 0:6)
  got <- prune_run(d)
  expect_equal(as.character(got), as.character(mon + 6))
})

test_that("R-9.4: ISO-week boundary - Sunday and the following Monday are each their own week's newest", {
  d <- withr::local_tempdir()
  today <- Sys.Date()
  mon <- prune_weekday_at_or_older(1, 22) # Monday aged 22..28
  sun <- mon - 1
  prune_mk(d, c(sun - 2, sun, mon, mon + 2))
  got <- prune_run(d)
  # sun-2 (Fri) shares a week with sun -> removed; mon and mon+2 share a week -> only mon+2
  expect_equal(as.character(got), as.character(sort(c(sun, mon + 2))))
  # and Sunday + Monday alone are both retained
  d2 <- withr::local_tempdir()
  prune_mk(d2, c(sun, mon))
  expect_equal(as.character(prune_run(d2)), as.character(sort(c(sun, mon))))
})

test_that("R-9.4: weekly selection is computed among weekly-zone files only (newer zone-1 files in the same week do not displace it)", {
  d <- withr::local_tempdir()
  today <- Sys.Date()
  mon <- prune_weekday_at_or_older(1, 8) # Monday aged 8..14
  a <- as.numeric(today - mon)
  kd <- a - 1 # Monday is the very first zone-2 day; Tue..Sun of that week are zone 1
  all_dates <- c(mon + 1:6, mon, mon - 1, mon - 3)
  all_dates <- all_dates[all_dates <= today]
  prune_mk(d, all_dates)
  got <- prune_run(d, keep_days = kd)
  expect_true(mon %in% got)
  expect_true(all(all_dates[as.numeric(today - all_dates) <= kd] %in% got))
  expect_true((mon - 1) %in% got)
  expect_false((mon - 3) %in% got)
  expect_equal(as.character(got), as.character(prune_oracle(all_dates, today, keep_days = kd)))
})

test_that("R-9.4: weekly/monthly zone boundary - age 63 is weekly, age 64 is monthly (custom keep_days placing it on a Monday)", {
  d <- withr::local_tempdir()
  today <- Sys.Date()
  cand <- today - (57:120)
  e <- cand[as.integer(format(cand, "%u")) == 1 & as.integer(format(cand, "%d")) >= 4][1]
  age_e <- as.numeric(today - e)
  kd <- age_e - 56 # zone 2 ends exactly at e (a Monday); e-1 and e-2 are monthly
  expect_gte(kd, 1)
  prune_mk(d, c(e, e - 1, e - 2))
  got <- prune_run(d, keep_days = kd)
  # e is the sole weekly-zone file -> kept. e-1 is the newest monthly-zone file -> kept.
  # e-2 is same month as e-1 (day-of-month of e >= 4) -> removed.
  expect_equal(as.character(got), as.character(sort(c(e, e - 1))))
})

test_that("R-9.4: default boundary ages 60..68 agree with the oracle (age 63 weekly, 64 monthly)", {
  d <- withr::local_tempdir()
  today <- Sys.Date()
  all_dates <- today - 56:70
  prune_mk(d, all_dates)
  got <- prune_run(d)
  expect_equal(as.character(got), as.character(prune_oracle(all_dates, today)))
})

test_that("R-9.4: monthly zone keeps the last-of-month and first-of-next-month separately and drops mid-month older files", {
  d <- withr::local_tempdir()
  today <- Sys.Date()
  # smallest last-day-of-month with age >= 70
  cand <- today - 70:110
  last <- cand[format(cand + 1, "%d") == "01"][1]
  expect_gte(as.numeric(today - (last + 1)), 64)
  older_month_last <- as.Date(format(last, "%Y-%m-01")) - 1
  prune_mk(d, c(last + 1, last, last - 1, last - 10, older_month_last))
  got <- prune_run(d)
  expect_equal(as.character(got), as.character(sort(c(last + 1, last, older_month_last))))
})

test_that("R-9.4: non-snapshot files in the dest_dir are never touched", {
  d <- withr::local_tempdir()
  today <- Sys.Date()
  others <- c("monitoring_pre-001-x_2026-01-01.duckdb", "monitoring_2020-01-01.duckdb.tmp",
              "monitoring_2020-01-02.duckdb.bak", "notes.txt", "monitoring_latest.duckdb")
  for (o in others) writeLines("", file.path(d, o))
  prune_mk(d, today - c(300, 301, 302))
  prune_snapshots(d)
  expect_true(all(file.exists(file.path(d, others))))
  expect_length(prune_left(d), 1)
})

test_that("R-9.4: custom keep_days / keep_weeks are honoured", {
  d <- withr::local_tempdir()
  today <- Sys.Date()
  all_dates <- today - 0:200
  prune_mk(d, all_dates)
  got <- prune_run(d, keep_days = 14, keep_weeks = 2)
  expect_equal(as.character(got), as.character(prune_oracle(all_dates, today, 14, 2)))
  d2 <- withr::local_tempdir()
  prune_mk(d2, all_dates)
  got2 <- prune_run(d2, keep_days = 0, keep_weeks = 3)
  expect_true(today %in% got2)
  expect_equal(as.character(got2), as.character(prune_oracle(all_dates, today, 0, 3)))
})

test_that("R-9.4: keep_weeks = 0 removes the weekly zone - files past keep_days follow the monthly rule", {
  d <- withr::local_tempdir()
  today <- Sys.Date()
  all_dates <- today - 0:120
  prune_mk(d, all_dates)
  got <- prune_run(d, keep_weeks = 0)
  expect_equal(as.character(got), as.character(prune_oracle(all_dates, today, 7, 0)))
  older <- got[as.numeric(today - got) > 7]
  expect_false(anyDuplicated(format(older, "%Y-%m")) > 0)
})

test_that("R-9.4: prune_snapshots() validates keep_days and keep_weeks", {
  d <- withr::local_tempdir()
  expect_error(prune_snapshots(d, keep_days = -1))
  expect_error(prune_snapshots(d, keep_weeks = -1))
  expect_error(prune_snapshots(d, keep_days = "a"))
  expect_error(prune_snapshots(d, keep_weeks = "a"))
  expect_error(prune_snapshots(d, keep_days = c(1, 2)))
  expect_error(prune_snapshots(d, keep_weeks = NA_real_))
  expect_error(prune_snapshots(d, keep_days = NULL))
})

test_that("R-9.4: prune_snapshots() on an empty directory, and always, returns NULL invisibly", {
  d <- withr::local_tempdir()
  expect_invisible(res <- prune_snapshots(d))
  expect_null(res)
  prune_mk(d, Sys.Date() - 0:30)
  expect_invisible(res2 <- prune_snapshots(d))
  expect_null(res2)
})

test_that("R-9.4: prune_snapshots() is idempotent - a second run removes nothing", {
  d <- withr::local_tempdir()
  prune_mk(d, Sys.Date() - 0:400)
  first <- prune_run(d)
  second <- prune_run(d)
  expect_equal(as.character(second), as.character(first))
})

test_that("R-9.4: a same-day re-snapshot overwrites (single file per day)", {
  db_path <- seed_db()
  dest_dir <- withr::local_tempdir()

  path1 <- snapshot_db(db = db_path, dest_dir = dest_dir)
  path2 <- snapshot_db(db = db_path, dest_dir = dest_dir)

  expect_identical(path1, path2)
  today_files <- list.files(dest_dir, pattern = sprintf("^monitoring_%s\\.duckdb$", Sys.Date()))
  expect_length(today_files, 1)
})

test_that("R-12.4: snapshot_db() into a non-existent snapshot_dir aborts sampletidy_error and writes no snapshot file", {
  db_path <- seed_db()
  # Never created (no mkdir) - the CHECKPOINT-and-copy step's file.copy() into
  # it must fail, and that failure must be checked (R-12.4), not silently
  # ignored the way the pre-fix code does (which would file.rename() a .tmp
  # that was never actually written and "succeed").
  missing_dir <- file.path(withr::local_tempdir(), "does-not-exist")

  err <- tryCatch(snapshot_db(db = db_path, dest_dir = missing_dir), error = function(e) e)
  expect_s3_class(err, "sampletidy_error")

  final_name <- sprintf("monitoring_%s.duckdb", format(Sys.Date(), "%Y-%m-%d"))
  expect_false(file.exists(file.path(missing_dir, final_name)))
  expect_false(file.exists(file.path(missing_dir, paste0(final_name, ".tmp"))))
})

test_that("Phase-8b C1: snapshot_db() refuses a `db` path that does not exist (typo), and a pre-existing good snapshot is left byte-for-byte intact", {
  db_path <- seed_db()
  dest_dir <- withr::local_tempdir()

  good_path <- snapshot_db(db = db_path, dest_dir = dest_dir)
  good_size <- file.size(good_path)
  good_con <- DBI::dbConnect(duckdb::duckdb(), good_path, read_only = TRUE)
  good_tables <- sort(DBI::dbListTables(good_con))
  good_feature_count <- DBI::dbGetQuery(good_con, "SELECT count(*) AS n FROM feature")$n
  DBI::dbDisconnect(good_con, shutdown = TRUE)
  expect_true(length(good_tables) > 0)
  expect_true(good_feature_count > 0)

  # A path that has never existed - the "typo" case: with_db_write() opens
  # read-write, and DuckDB would otherwise silently CREATE this file on
  # connect.
  typo_path <- file.path(withr::local_tempdir(), "seed.duckd")
  expect_false(file.exists(typo_path))

  err <- tryCatch(snapshot_db(db = typo_path, dest_dir = dest_dir), error = function(e) e)
  expect_s3_class(err, "sampletidy_error")
  expect_match(conditionMessage(err), typo_path, fixed = TRUE)

  # The refusal itself must not conjure the typo'd path into existence.
  expect_false(file.exists(typo_path))

  # The load-bearing assertion (per the finding): the PRE-EXISTING good
  # snapshot is still there, unchanged - not just "an error was raised".
  expect_true(file.exists(good_path))
  expect_equal(file.size(good_path), good_size)
  post_con <- DBI::dbConnect(duckdb::duckdb(), good_path, read_only = TRUE)
  post_tables <- sort(DBI::dbListTables(post_con))
  post_feature_count <- DBI::dbGetQuery(post_con, "SELECT count(*) AS n FROM feature")$n
  DBI::dbDisconnect(post_con, shutdown = TRUE)
  expect_identical(post_tables, good_tables)
  expect_equal(post_feature_count, good_feature_count)

  tmp_files <- list.files(dest_dir, pattern = "\\.tmp$")
  expect_length(tmp_files, 0)
})

test_that("Phase-8b C1: snapshot_db() refuses a copy with zero tables (existing-but-empty db) and leaves the pre-existing good snapshot intact - defense-in-depth beyond the missing-file check", {
  db_path <- seed_db()
  dest_dir <- withr::local_tempdir()

  good_path <- snapshot_db(db = db_path, dest_dir = dest_dir)
  good_size <- file.size(good_path)

  # A db file that genuinely EXISTS (so the missing-file refusal does not
  # fire) but holds zero tables - the same end state a typo produces, reached
  # a different way, so this exercises the post-copy verification layer
  # specifically rather than the existence check.
  empty_dir <- withr::local_tempdir()
  empty_db <- file.path(empty_dir, "empty.duckdb")
  con <- DBI::dbConnect(duckdb::duckdb(), empty_db, read_only = FALSE)
  DBI::dbDisconnect(con, shutdown = TRUE)
  expect_true(file.exists(empty_db))

  # Same dest_dir, same day => same final_path as the good snapshot above;
  # this reproduces the actual clobber scenario, not just a fresh file.
  err <- tryCatch(snapshot_db(db = empty_db, dest_dir = dest_dir), error = function(e) e)
  expect_s3_class(err, "sampletidy_error")

  expect_true(file.exists(good_path))
  expect_equal(file.size(good_path), good_size)
  post_con <- DBI::dbConnect(duckdb::duckdb(), good_path, read_only = TRUE)
  post_feature_count <- DBI::dbGetQuery(post_con, "SELECT count(*) AS n FROM feature")$n
  DBI::dbDisconnect(post_con, shutdown = TRUE)
  expect_true(post_feature_count > 0)

  tmp_files <- list.files(dest_dir, pattern = "\\.tmp$")
  expect_length(tmp_files, 0)
})
