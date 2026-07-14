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
