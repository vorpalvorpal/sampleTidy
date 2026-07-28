# Plan 01 - R-1.3 with_db_write() and R-1.4 st_connect().
#
# NOTE [MEASURE TWICE]: the DESIGN §9.2 reference test method ("a second
# connection in the same process") was verified NOT to reproduce RW lock
# contention with the installed duckdb R package (1.4.1): duckdb() now
# caches/reuses one database instance per path per process (see
# `?duckdb::duckdb`: "creates or reuses a database instance"), so two
# same-process connections to the same path silently share state instead of
# racing for the OS file lock - this affects not only the busy-retry test but
# also any "is the connection really closed?" check (a same-process re-open
# would trivially succeed even if with_db_write() leaked its connection). All
# such checks below spawn a genuine second OS process via processx. See
# dev/plans/PLAN-CHANGE-REQUESTS.md.

#' Returns TRUE iff a fresh OS process can immediately open `path` read-write
#' and disconnect cleanly (i.e. no OS-level lock is held on it by us).
subprocess_can_connect_rw <- function(path, timeout_s = 5) {
  # local_tempfile(), not tempfile(): this helper is called once per test that
  # needs a cross-process lock check, and a bare tempfile() registers no cleanup
  # at all, so every call left a 231-byte script behind in tempdir() forever.
  # Cleanup is bound to THIS function's frame, which is safe on both exits below
  # - `p$wait()` has returned or the process has been killed by then, so nothing
  # is still reading the script.
  script <- withr::local_tempfile(fileext = ".R")
  writeLines(c(
    "path <- commandArgs(trailingOnly = TRUE)[1]",
    "res <- tryCatch({",
    "  con <- DBI::dbConnect(duckdb::duckdb(), path, read_only = FALSE)",
    "  DBI::dbDisconnect(con, shutdown = TRUE)",
    "  'OK'",
    "}, error = function(e) conditionMessage(e))",
    "cat(res)"
  ), script)
  p <- processx::process$new(
    file.path(R.home("bin"), "Rscript"),
    args = c(script, path),
    stdout = "|", stderr = "|"
  )
  p$wait(timeout = timeout_s * 1000)
  if (p$is_alive()) {
    p$kill()
    return(FALSE)
  }
  identical(paste(p$read_all_output_lines(), collapse = ""), "OK")
}

test_that("R-1.3: with_db_write() returns fn(con)'s value; the connection is truly closed after (cross-process check)", {
  skip_if_not_installed("processx")
  dir <- withr::local_tempdir()
  db <- file.path(dir, "rw.duckdb")

  result <- with_db_write(function(con) {
    DBI::dbExecute(con, "CREATE TABLE t(x INTEGER)")
    DBI::dbExecute(con, "INSERT INTO t VALUES (42)")
    DBI::dbGetQuery(con, "SELECT x FROM t")$x
  }, db = db)
  expect_equal(result, 42)

  expect_true(subprocess_can_connect_rw(db))
})

test_that("R-1.3: fn throwing still closes the connection (on.exit) - error surfaces and lock releases (cross-process check)", {
  skip_if_not_installed("processx")
  dir <- withr::local_tempdir()
  db <- file.path(dir, "throwing.duckdb")
  # pre-create the file so a leaked lock would be observable
  DBI::dbDisconnect(DBI::dbConnect(duckdb::duckdb(), db, read_only = FALSE), shutdown = TRUE)

  err <- tryCatch(
    with_db_write(function(con) stop("boom from fn"), db = db),
    error = function(e) e
  )
  expect_match(conditionMessage(err), "boom from fn", fixed = TRUE)
  expect_true(subprocess_can_connect_rw(db))
})

test_that("R-1.3: a non-lock connect error (path is a directory) aborts immediately, not after max_wait", {
  dir <- withr::local_tempdir()
  dir_as_db <- file.path(dir, "actually_a_directory")
  dir.create(dir_as_db)

  t0 <- Sys.time()
  err <- tryCatch(
    with_db_write(function(con) 1, db = dir_as_db, max_wait = 60, every = 2),
    error = function(e) e
  )
  elapsed <- as.numeric(Sys.time() - t0, units = "secs")

  expect_match(conditionMessage(err), "directory", ignore.case = TRUE)
  expect_lt(elapsed, 2)
})

test_that("R-1.3: retries then aborts after max_wait with a busy message when RW-locked by another process", {
  skip_if_not_installed("processx")
  dir <- withr::local_tempdir()
  db <- file.path(dir, "locked.duckdb")
  # create the file up front so the holder process can open it
  DBI::dbDisconnect(DBI::dbConnect(duckdb::duckdb(), db, read_only = FALSE), shutdown = TRUE)

  holder_script <- st_test_write_file(dir, "hold_lock.R", content = c(
    "args <- commandArgs(trailingOnly = TRUE)",
    "con <- DBI::dbConnect(duckdb::duckdb(), args[1], read_only = FALSE)",
    "Sys.sleep(8)"
  ))
  holder <- processx::process$new(
    file.path(R.home("bin"), "Rscript"),
    args = c(holder_script, db),
    stdout = "|", stderr = "|"
  )
  withr::defer(try(holder$kill(), silent = TRUE))
  Sys.sleep(2) # let the holder actually open its RW connection

  t0 <- Sys.time()
  err <- tryCatch(
    with_db_write(function(con) 1, db = db, max_wait = 2, every = 1),
    error = function(e) e
  )
  elapsed <- as.numeric(Sys.time() - t0, units = "secs")

  expect_s3_class(err, "sampletidy_error")
  expect_match(conditionMessage(err), "busy", ignore.case = TRUE)
  expect_gte(elapsed, 2)
})

# --- R-1.4 st_connect(db, read_only) ------------------------------------

test_that("R-1.4: read-only connection cannot write", {
  dir <- withr::local_tempdir()
  db <- seed_db(dir)

  con <- st_connect(db, read_only = TRUE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  expect_error(DBI::dbExecute(con, "INSERT INTO project (uuid, name, type) VALUES ('p-9999', 'X', 'Work order')"))
})

test_that("R-1.4: nonexistent file with read_only = TRUE aborts with the path in the message", {
  dir <- withr::local_tempdir()
  missing_path <- file.path(dir, "does-not-exist.duckdb")

  err <- tryCatch(st_connect(missing_path, read_only = TRUE), error = function(e) e)
  expect_s3_class(err, "error")
  expect_match(conditionMessage(err), missing_path, fixed = TRUE)
})

test_that("R-1.4: read_only = FALSE creates the file if absent", {
  dir <- withr::local_tempdir()
  new_path <- file.path(dir, "new.duckdb")
  expect_false(file.exists(new_path))

  con <- st_connect(new_path, read_only = FALSE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  expect_true(file.exists(new_path))
})

test_that("R-1.4: read_only defaults to TRUE", {
  dir <- withr::local_tempdir()
  db <- seed_db(dir)

  con <- st_connect(db)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  expect_error(DBI::dbExecute(con, "INSERT INTO project (uuid, name, type) VALUES ('p-9998', 'X', 'Work order')"))
})
