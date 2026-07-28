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

test_that("R-9.4: prune_snapshots() keeps <=60-day dailies plus each month's final snapshot", {
  dest_dir <- withr::local_tempdir()
  today <- Sys.Date()
  all_dates <- today - 0:89 # 90 consecutive dates, oldest to newest

  for (i in seq_along(all_dates)) {
    d <- all_dates[i]
    f <- file.path(dest_dir, sprintf("monitoring_%s.duckdb", format(d, "%Y-%m-%d")))
    writeLines("", f)
  }

  prune_snapshots(dest_dir, keep_days = 60)

  remaining_files <- list.files(dest_dir, pattern = "^monitoring_\\d{4}-\\d{2}-\\d{2}\\.duckdb$")
  remaining_dates <- as.Date(sub("^monitoring_(\\d{4}-\\d{2}-\\d{2})\\.duckdb$", "\\1", remaining_files))

  young <- all_dates[as.numeric(today - all_dates) <= 60]
  old <- all_dates[as.numeric(today - all_dates) > 60]
  old_last_per_month <- as.Date(unlist(tapply(old, format(old, "%Y-%m"), function(x) as.numeric(max(x)))),
                                 origin = "1970-01-01")
  expected <- sort(unique(c(young, old_last_per_month)))

  expect_setequal(as.character(remaining_dates), as.character(expected))
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
