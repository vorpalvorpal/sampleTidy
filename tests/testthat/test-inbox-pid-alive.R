# PLAN-21 phase (b), item b5 (sampleTidy half): a portable process-liveness check.
#
# tools::pskill(pid, 0L) tests a pid on Unix, but on Windows R's help says pskill "will
# always use the Windows system call TerminateProcess": the inbox lock's staleness check
# would kill the lock holder (or an unrelated process that reused the pid). The check is
# now `.st_pid_alive(pid)`, built on ps::ps_is_running(ps::ps_handle(pid)): FALSE on an
# error or an NA, never a signal. These tests run on any OS; the mocked `tools::pskill`
# errors if called, which proves it is never used.

pa_forbid_pskill <- function(env = parent.frame()) {
  testthat::local_mocked_bindings(
    pskill = function(...) stop("tools::pskill must not be used to test a pid"),
    .package = "tools", .env = env)
}

pa_sleeper <- function(env = parent.frame()) {
  skip_if_not_installed("processx")
  p <- processx::process$new(if (.Platform$OS.type == "windows") "ping" else "sleep",
                             if (.Platform$OS.type == "windows") c("-n", "120", "127.0.0.1") else "120",
                             stdout = NULL, stderr = NULL)
  withr::defer(if (p$is_alive()) p$kill(), envir = env)
  p
}

test_that(".st_pid_alive is TRUE for this process and for another live process", {
  skip_if_not_installed("ps")
  expect_true(.st_pid_alive(Sys.getpid()))
  p <- pa_sleeper()
  expect_true(.st_pid_alive(p$get_pid()))
})

test_that(".st_pid_alive is FALSE for a process that has exited", {
  skip_if_not_installed("ps")
  p <- pa_sleeper()
  pid <- p$get_pid()
  p$kill(); p$wait(5000)
  expect_false(.st_pid_alive(pid))
})

test_that(".st_pid_alive is FALSE for a pid that never existed, NA, and junk", {
  skip_if_not_installed("ps")
  expect_false(.st_pid_alive(99999999L))
  expect_false(.st_pid_alive(NA_integer_))
  expect_false(.st_pid_alive(NA))
  expect_false(.st_pid_alive("not-a-pid"))
  expect_false(.st_pid_alive(NULL))
  expect_false(.st_pid_alive(integer()))
  expect_false(.st_pid_alive(-1L))
})

test_that(".st_pid_alive never calls tools::pskill, and never signals the process it tests", {
  skip_if_not_installed("ps")
  pa_forbid_pskill()
  p <- pa_sleeper()
  expect_true(.st_pid_alive(p$get_pid()))
  expect_true(p$is_alive())
})

test_that(".inbox_pid_alive (the lock's stale check) uses it: no pskill, same answers, nobody killed", {
  skip_if_not_installed("ps")
  pa_forbid_pskill()
  p <- pa_sleeper()
  expect_true(.inbox_pid_alive(p$get_pid()))
  expect_true(p$is_alive())
  expect_false(.inbox_pid_alive(99999999L))
  expect_false(.inbox_pid_alive(NA))
  expect_false(.inbox_pid_alive(0L))
})

test_that(".inbox_lock_acquire leaves a live lock holder alone and respects its lock", {
  skip_if_not_installed("ps")
  pa_forbid_pskill()
  p <- pa_sleeper()
  db <- file.path(withr::local_tempdir(), "monitoring.duckdb")
  now <- Sys.time()
  jsonlite::write_json(list(pid = p$get_pid(), started_at = format(now, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")),
                       .inbox_lock_path(db), auto_unbox = TRUE)
  got <- .inbox_lock_acquire(db, now)
  expect_false(got$acquired)
  expect_true(p$is_alive())
})

test_that("R/ no longer calls pskill anywhere", {
  r_dir <- testthat::test_path("..", "..", "R")
  skip_if(!dir.exists(r_dir), "the package source is not beside the tests")
  hits <- unlist(lapply(list.files(r_dir, pattern = "\\.[Rr]$", full.names = TRUE), function(f) {
    l <- readLines(f, warn = FALSE)
    l <- l[!grepl("^\\s*#", l)]
    grep("pskill\\s*\\(", l, value = TRUE)
  }))
  expect_length(hits, 0L)
})
