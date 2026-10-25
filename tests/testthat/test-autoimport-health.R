# R-22.H: dev/auto-import.sh health check (Robin 2026-10-25).
#
# The hourly launchd job runs dev/auto-import.sh. These tests pin, with a stub
# RSCRIPT and temp dirs (no R, no DB work):
#   1. an ATOMIC wrapper lock: `mkdir "$REPORT/.imports.lock"` holding the PID in
#      `$REPORT/.imports.lock/pid`; a lock whose PID is dead, or older than 2 h,
#      is taken over; the lock is released when the run ends (any rc).
#   2. a run health record `$REPORT/.imports.health`, a FLAT JSON object:
#        running: {state:"running", started_at, pid}
#        done:    {state:"done", rc, started_at, ended_at, last_success_at, ...}
#      timestamps are UTC ISO-8601, "%Y-%m-%dT%H:%M:%SZ"; last_success_at moves
#      only when rc == 0 (and is null/absent before the first success).
#   3. failed-previous-run handling at start, before the gate: gate bypassed,
#      ONE notification per failed started_at, and the text exported to R as
#      SAMPLETIDY_AUTOIMPORT_PREV_FAILURE (R side: import_status()).
#   4. staleness: last_success_at older than 24 h
#      (SAMPLETIDY_AUTOIMPORT_STALE_HOURS overrides) notifies once per Sydney
#      day even when the gate says nothing changed. No health file: no notify.
#   5. the off switch exits before anything.
# Notifier contract: SAMPLETIDY_AUTOIMPORT_NOTIFY is a command invoked as
#   `$NOTIFY "<title>" "<message>"` (title contains "sampleTidy import").

# ---- helpers -------------------------------------------------------------------

ai_wrapper <- function() normalizePath(testthat::test_path("..", "..", "dev", "auto-import.sh"), mustWork = TRUE)

ai_utc <- function(t) format(t, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")

#' A sandbox: fake DB, input dir, REPORT dir, log, and the two stubs. The stub
#' RSCRIPT appends "run|<pid>|<PREV_FAILURE>" to runs.txt; STUB_SLEEP (seconds),
#' STUB_RC (exit code) and STUB_HEALTH_COPY (path to copy .imports.health to
#' while "running") are read from the environment. The notifier appends one
#' line per call: "<argc>|<arg1>|<arg2>".
ai_setup <- function(env = parent.frame()) {
  skip_on_os("windows")
  skip_if(Sys.which("bash") == "")
  d <- withr::local_tempdir(.local_envir = env)
  s <- list(dir = d, db = file.path(d, "monitoring.duckdb"), input = file.path(d, "in"),
            report = file.path(d, "report"), log = file.path(d, "log", "autoimport.log"),
            off = file.path(d, "off"), runs = file.path(d, "runs.txt"),
            notes = file.path(d, "notes.txt"), copy = file.path(d, "health-copy.json"),
            rscript = file.path(d, "stub-rscript.sh"), notify = file.path(d, "stub-notify.sh"),
            code = file.path(d, "code"))
  writeLines("x", s$db); dir.create(s$input); dir.create(s$report); dir.create(s$code)
  writeLines(c("#!/bin/bash",
               sprintf('echo "run|$$|${SAMPLETIDY_AUTOIMPORT_PREV_FAILURE:-}" >> "%s"', s$runs),
               sprintf('[ -n "${STUB_HEALTH_COPY:-}" ] && cp "%s/.imports.health" "$STUB_HEALTH_COPY"', s$report),
               'sleep "${STUB_SLEEP:-0}"',
               'exit "${STUB_RC:-0}"'), s$rscript)
  writeLines(c("#!/bin/bash",
               sprintf('echo "$#|$1|$2" >> "%s"', s$notes)), s$notify)
  Sys.chmod(c(s$rscript, s$notify), "755")
  withr::local_envvar(c(
    SAMPLETIDY_AUTOIMPORT_DB = s$db, SAMPLETIDY_AUTOIMPORT_INPUT = s$input,
    SAMPLETIDY_AUTOIMPORT_REPORT = s$report, SAMPLETIDY_AUTOIMPORT_RSCRIPT = s$rscript,
    SAMPLETIDY_AUTOIMPORT_LOG = s$log, SAMPLETIDY_AUTOIMPORT_CODE = s$code,
    SAMPLETIDY_AUTOIMPORT_OFF = s$off, SAMPLETIDY_AUTOIMPORT_NOTIFY = s$notify,
    SAMPLETIDY_AUTOIMPORT_STALE_HOURS = NA, SAMPLETIDY_AUTOIMPORT_PREV_FAILURE = NA,
    STUB_SLEEP = NA, STUB_RC = NA, STUB_HEALTH_COPY = NA), .local_envir = env)
  s
}

# Run the wrapper to completion; returns its exit status.
ai_status <- function(s) {
  out <- suppressWarnings(system2("bash", shQuote(ai_wrapper()), stdout = TRUE, stderr = TRUE))
  as.integer(attr(out, "status") %||% 0L)
}

# Start the wrapper in the background; returns its pid.
ai_start_bg <- function(env = parent.frame()) {
  pid <- as.integer(system2("bash", c("-c", shQuote(sprintf("bash %s >/dev/null 2>&1 & echo $!", shQuote(ai_wrapper())))),
                            stdout = TRUE))
  withr::defer(tools::pskill(pid), envir = env)
  pid
}

ai_lines <- function(path) if (file.exists(path)) readLines(path, warn = FALSE) else character()
ai_runs <- function(s) ai_lines(s$runs)
ai_notes <- function(s) ai_lines(s$notes)
ai_log <- function(s) paste(ai_lines(s$log), collapse = "\n")
ai_health_path <- function(s) file.path(s$report, ".imports.health")
ai_health <- function(s) {
  expect_true(file.exists(ai_health_path(s)), info = "the wrapper writes .imports.health")
  if (!file.exists(ai_health_path(s))) return(list())
  jsonlite::fromJSON(ai_health_path(s), simplifyVector = TRUE)
}
ai_write_health <- function(s, ...) {
  jsonlite::write_json(list(...), ai_health_path(s), auto_unbox = TRUE, null = "null")
}
ai_lock <- function(s) file.path(s$report, ".imports.lock")
ai_wait_for_run <- function(s) for (i in 1:50) { if (length(ai_runs(s))) break; Sys.sleep(0.1) }

#' A live PID that is not this wrapper's: a background `sleep`, killed at exit.
ai_live_pid <- function(env = parent.frame()) {
  pid <- as.integer(system2("bash", c("-c", shQuote("sleep 300 >/dev/null 2>&1 & echo $!")), stdout = TRUE))
  withr::defer(tools::pskill(pid), envir = env)
  pid
}
ai_dead_pid <- function() 99999999L

#' One successful run, so a gate exists and the next tick sees "nothing changed".
ai_prime_gate <- function(s) {
  expect_identical(ai_status(s), 0L)
  expect_length(ai_runs(s), 1L)
  writeLines("{}", file.path(s$report, ".imports.state"))   # what R leaves; the gate needs it to hold
  file.remove(s$runs)
  if (file.exists(s$notes)) file.remove(s$notes)
}

# ---- 1. atomic lock --------------------------------------------------------------

test_that("R-22.H: four wrappers started at once never run RSCRIPT more than once", {
  s <- ai_setup()
  withr::local_envvar(STUB_SLEEP = "3")
  cmd <- sprintf('w=%s; for i in 1 2 3 4; do bash "$w" >/dev/null 2>&1 & done; wait', shQuote(ai_wrapper()))
  system2("bash", c("-c", shQuote(cmd)))
  expect_length(ai_runs(s), 1L)
})

test_that("R-22.H: a second wrapper while a run is in progress exits 0 quickly and logs that a run is in progress", {
  s <- ai_setup()
  withr::local_envvar(STUB_SLEEP = "4")
  ai_start_bg()
  ai_wait_for_run(s)
  expect_length(ai_runs(s), 1L)
  t0 <- Sys.time()
  rc <- ai_status(s)
  expect_identical(rc, 0L)
  expect_lt(as.numeric(difftime(Sys.time(), t0, units = "secs")), 2)
  expect_length(ai_runs(s), 1L)
  expect_match(ai_log(s), "in progress", ignore.case = TRUE)
})

test_that("R-22.H: the lock is a directory in the report dir holding the wrapper's PID while it runs, and is gone after the run", {
  s <- ai_setup()
  withr::local_envvar(STUB_SLEEP = "3")
  ai_start_bg()
  ai_wait_for_run(s)
  expect_true(dir.exists(ai_lock(s)))
  pid <- as.integer(trimws(ai_lines(file.path(ai_lock(s), "pid"))[1]))
  expect_false(is.na(pid))
  expect_identical(system2("kill", c("-0", pid), stdout = FALSE, stderr = FALSE), 0L)   # a live process
  for (i in 1:80) { if (!dir.exists(ai_lock(s))) break; Sys.sleep(0.1) }
  expect_false(dir.exists(ai_lock(s)))
})

test_that("R-22.H: the lock is released when RSCRIPT fails, and the next wrapper can run", {
  s <- ai_setup()
  withr::local_envvar(STUB_RC = "3")
  expect_identical(ai_status(s), 3L)
  expect_false(dir.exists(ai_lock(s)))
  withr::local_envvar(STUB_RC = "0")
  ai_status(s)
  expect_length(ai_runs(s), 2L)
})

test_that("R-22.H: a lock whose PID is dead is taken over and the run proceeds", {
  s <- ai_setup()
  dir.create(ai_lock(s)); writeLines(as.character(ai_dead_pid()), file.path(ai_lock(s), "pid"))
  expect_identical(ai_status(s), 0L)
  expect_length(ai_runs(s), 1L)
  expect_false(dir.exists(ai_lock(s)))
})

test_that("R-22.H: a lock older than 2 h is taken over even though its PID is alive", {
  s <- ai_setup()
  dir.create(ai_lock(s)); writeLines(as.character(ai_live_pid()), file.path(ai_lock(s), "pid"))
  old <- format(Sys.time() - 3 * 3600, "%Y%m%d%H%M")
  system2("touch", c("-t", old, shQuote(ai_lock(s))))
  expect_identical(ai_status(s), 0L)
  expect_length(ai_runs(s), 1L)
})

test_that("R-22.H: a fresh lock held by a live PID is respected - no run, exit 0, logged as in progress", {
  s <- ai_setup()
  dir.create(ai_lock(s)); writeLines(as.character(ai_live_pid()), file.path(ai_lock(s), "pid"))
  expect_identical(ai_status(s), 0L)
  expect_length(ai_runs(s), 0L)
  expect_true(dir.exists(ai_lock(s)))
  expect_match(ai_log(s), "in progress", ignore.case = TRUE)
})

# ---- 2. run health record ----------------------------------------------------------

test_that("R-22.H: while RSCRIPT runs the health record says running with the start time and the wrapper's pid", {
  s <- ai_setup()
  withr::local_envvar(STUB_HEALTH_COPY = s$copy)
  ai_status(s)
  expect_true(file.exists(s$copy), info = "the wrapper writes .imports.health before running RSCRIPT")
  h <- if (file.exists(s$copy)) jsonlite::fromJSON(s$copy) else list()
  expect_identical(h$state, "running")
  expect_match(h$started_at, "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z$")
  expect_false(is.na(suppressWarnings(as.integer(h$pid))))
  expect_lt(abs(as.numeric(difftime(Sys.time(), as.POSIXct(h$started_at, format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"), units = "secs"))), 120)
})

test_that("R-22.H: after a successful run the health record is done, rc 0, with start, end and last_success_at", {
  s <- ai_setup()
  ai_status(s)
  h <- ai_health(s)
  expect_identical(h$state, "done")
  expect_identical(as.integer(h$rc), 0L)
  for (k in c("started_at", "ended_at", "last_success_at"))
    expect_match(h[[k]], "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z$", info = k)
  expect_gte(h$ended_at, h$started_at)
  expect_gte(h$last_success_at, h$started_at)
})

test_that("R-22.H: a failed run records its rc and leaves last_success_at at the earlier success", {
  s <- ai_setup()
  prev <- ai_utc(Sys.time() - 3600)
  ai_write_health(s, state = "done", rc = 0L, started_at = prev, ended_at = prev, last_success_at = prev)
  withr::local_envvar(STUB_RC = "3")
  expect_identical(ai_status(s), 3L)
  h <- ai_health(s)
  expect_identical(h$state, "done")
  expect_identical(as.integer(h$rc), 3L)
  expect_identical(h$last_success_at, prev)
  expect_gt(h$started_at, prev)
})

test_that("R-22.H: a later success moves last_success_at forward", {
  s <- ai_setup()
  prev <- ai_utc(Sys.time() - 7200)
  ai_write_health(s, state = "done", rc = 0L, started_at = prev, ended_at = prev, last_success_at = prev)
  ai_status(s)
  expect_gt(ai_health(s)$last_success_at, prev)
})

# ---- 3. previous failure -----------------------------------------------------------

test_that("R-22.H: a previous run that exited non-zero bypasses a matching gate, so the run retries", {
  s <- ai_setup()
  ai_prime_gate(s)
  expect_identical(ai_status(s), 0L)                       # control: gate holds
  expect_length(ai_runs(s), 0L)
  t <- ai_utc(Sys.time() - 600)
  ai_write_health(s, state = "done", rc = 2L, started_at = t, ended_at = t, last_success_at = ai_utc(Sys.time() - 3600))
  expect_identical(ai_status(s), 0L)
  expect_length(ai_runs(s), 1L)
})

test_that("R-22.H: a crashed previous run (state running, dead PID) bypasses a matching gate, so the run retries", {
  s <- ai_setup()
  ai_prime_gate(s)
  ai_write_health(s, state = "running", started_at = ai_utc(Sys.time() - 600), pid = ai_dead_pid(),
                  last_success_at = ai_utc(Sys.time() - 3600))
  expect_identical(ai_status(s), 0L)
  expect_length(ai_runs(s), 1L)
})

test_that("R-22.H: a previous failure raises one notification naming the failed run and the rc", {
  s <- ai_setup()
  t <- "2026-10-25T01:00:00Z"
  ai_write_health(s, state = "done", rc = 2L, started_at = t, ended_at = t, last_success_at = ai_utc(Sys.time()))
  ai_status(s)
  n <- ai_notes(s)
  expect_length(n, 1L)
  expect_match(n, "^2\\|[^|]*sampleTidy import")
  expect_match(n, "2026-10-25")
  expect_match(n, "rc[ =:]*2")
})

test_that("R-22.H: a crashed previous run notifies once, saying it did not finish", {
  s <- ai_setup()
  ai_write_health(s, state = "running", started_at = "2026-10-25T01:00:00Z", pid = ai_dead_pid(),
                  last_success_at = ai_utc(Sys.time()))
  ai_status(s)
  expect_length(ai_notes(s), 1L)
  expect_match(ai_notes(s), "did not finish")
})

test_that("R-22.H: the same failed run (same started_at) never notifies twice", {
  s <- ai_setup()
  t <- "2026-10-25T01:00:00Z"
  rec <- function() ai_write_health(s, state = "done", rc = 2L, started_at = t, ended_at = t,
                                    last_success_at = ai_utc(Sys.time()))
  rec(); ai_status(s)
  rec(); ai_status(s)          # the same failure seen again (e.g. the retry never got to overwrite the record)
  expect_length(ai_notes(s), 1L)
  expect_length(ai_runs(s), 2L)  # but it is still retried each time
})

test_that("R-22.H: a different failed run notifies again", {
  s <- ai_setup()
  rec <- function(t) ai_write_health(s, state = "done", rc = 2L, started_at = t, ended_at = t,
                                     last_success_at = ai_utc(Sys.time()))
  rec("2026-10-25T01:00:00Z"); ai_status(s)
  rec("2026-10-25T02:00:00Z"); ai_status(s)
  expect_length(ai_notes(s), 2L)
})

test_that("R-22.H: the previous failure is passed to RSCRIPT in SAMPLETIDY_AUTOIMPORT_PREV_FAILURE, naming the time and rc", {
  s <- ai_setup()
  t <- "2026-10-25T01:00:00Z"
  ai_write_health(s, state = "done", rc = 2L, started_at = t, ended_at = t, last_success_at = ai_utc(Sys.time()))
  ai_status(s)
  r <- strsplit(ai_runs(s), "|", fixed = TRUE)[[1]]
  expect_match(r[3], "2026-10-25")
  expect_match(r[3], "rc[ =:]*2")
})

test_that("R-22.H: a crashed previous run is passed to RSCRIPT as 'did not finish'", {
  s <- ai_setup()
  ai_write_health(s, state = "running", started_at = "2026-10-25T01:00:00Z", pid = ai_dead_pid(),
                  last_success_at = ai_utc(Sys.time()))
  ai_status(s)
  expect_match(strsplit(ai_runs(s), "|", fixed = TRUE)[[1]][3], "did not finish")
})

test_that("R-22.H: with a healthy previous run, nothing is notified and PREV_FAILURE is empty for RSCRIPT", {
  s <- ai_setup()
  withr::local_envvar(SAMPLETIDY_AUTOIMPORT_PREV_FAILURE = "inherited junk")   # the wrapper must not pass through a stale value
  t <- ai_utc(Sys.time() - 3600)
  ai_write_health(s, state = "done", rc = 0L, started_at = t, ended_at = t, last_success_at = t)
  ai_status(s)
  expect_length(ai_notes(s), 0L)
  expect_identical(ai_runs(s), sprintf("run|%s|", strsplit(ai_runs(s), "|", fixed = TRUE)[[1]][2]))
})

# ---- 4. staleness -------------------------------------------------------------------

test_that("R-22.H: a last success older than 24 h notifies even when the gate says nothing changed, and does not run", {
  s <- ai_setup()
  ai_prime_gate(s)
  old <- ai_utc(Sys.time() - 30 * 3600)
  ai_write_health(s, state = "done", rc = 0L, started_at = old, ended_at = old, last_success_at = old)
  expect_identical(ai_status(s), 0L)
  expect_length(ai_runs(s), 0L)
  expect_length(ai_notes(s), 1L)
  expect_match(ai_notes(s), "sampleTidy import")
  expect_match(ai_notes(s), "success", ignore.case = TRUE)
})

test_that("R-22.H: the staleness notification is raised once per Sydney day, not on every tick", {
  s <- ai_setup()
  ai_prime_gate(s)
  old <- ai_utc(Sys.time() - 30 * 3600)
  ai_write_health(s, state = "done", rc = 0L, started_at = old, ended_at = old, last_success_at = old)
  ai_status(s); ai_status(s); ai_status(s)
  expect_length(ai_notes(s), 1L)
  expect_identical(ai_health(s)$last_success_at, old)      # gate-skipped ticks do not touch it
})

test_that("R-22.H: a last success within the window does not notify, and SAMPLETIDY_AUTOIMPORT_STALE_HOURS moves the window", {
  s <- ai_setup()
  ai_prime_gate(s)
  t <- ai_utc(Sys.time() - 30 * 3600)
  ai_write_health(s, state = "done", rc = 0L, started_at = t, ended_at = t, last_success_at = t)
  withr::local_envvar(SAMPLETIDY_AUTOIMPORT_STALE_HOURS = "48")
  ai_status(s)
  expect_length(ai_notes(s), 0L)
  withr::local_envvar(SAMPLETIDY_AUTOIMPORT_STALE_HOURS = "12")
  ai_status(s)
  expect_length(ai_notes(s), 1L)
})

test_that("R-22.H: a fresh install with no health file does not notify, and then records its first run", {
  s <- ai_setup()
  expect_false(file.exists(ai_health_path(s)))
  ai_status(s)
  expect_length(ai_notes(s), 0L)
  expect_length(ai_runs(s), 1L)
  expect_identical(ai_health(s)$state, "done")
})

# ---- 5. off switch --------------------------------------------------------------------

test_that("R-22.H: the off switch exits before anything - no run, no lock, no health write, no notification", {
  s <- ai_setup()
  t <- "2026-10-25T01:00:00Z"
  ai_write_health(s, state = "done", rc = 2L, started_at = t, ended_at = t, last_success_at = "2026-10-01T00:00:00Z")
  before <- readBin(ai_health_path(s), "raw", 1e5)
  file.create(s$off)
  expect_identical(ai_status(s), 0L)
  expect_length(ai_runs(s), 0L)
  expect_length(ai_notes(s), 0L)
  expect_false(dir.exists(ai_lock(s)))
  expect_identical(readBin(ai_health_path(s), "raw", 1e5), before)
})

# ---- R side: import_status() shows the previous failure ---------------------------------

test_that("R-22.H: import_status() puts SAMPLETIDY_AUTOIMPORT_PREV_FAILURE in the note's Problems list and in the json", {
  s <- inbox_setup()
  local_db_checks_pass()
  now <- as.POSIXct("2026-10-25 02:30:00", tz = "UTC")
  txt <- "The import started 2026-10-25 12:00 failed (rc 2)"
  withr::local_envvar(SAMPLETIDY_AUTOIMPORT_PREV_FAILURE = txt)
  quiet_run(import_status(db = s$db, input_dir = s$input_dir, report_dir = s$report_dir, now = now))
  sec <- md_section(read_status_note(s$report_dir), "Problems")
  expect_true(any(grepl(txt, sec, fixed = TRUE)))
  js <- jsonlite::fromJSON(file.path(s$report_dir, ".import-status.json"), simplifyVector = FALSE)
  expect_true(any(vapply(js$problems, function(p) grepl(txt, p, fixed = TRUE), logical(1))))
})

test_that("R-22.H: import_status() with PREV_FAILURE unset or empty adds no Problems entry", {
  s <- inbox_setup()
  local_db_checks_pass()
  now <- as.POSIXct("2026-10-25 02:30:00", tz = "UTC")
  for (v in list(NA, "")) {
    withr::local_envvar(SAMPLETIDY_AUTOIMPORT_PREV_FAILURE = v)
    quiet_run(import_status(db = s$db, input_dir = s$input_dir, report_dir = s$report_dir, now = now))
    expect_false(any(grepl("^## Problems", read_status_note(s$report_dir))))
    js <- jsonlite::fromJSON(file.path(s$report_dir, ".import-status.json"), simplifyVector = FALSE)
    expect_length(js$problems, 0L)
  }
})
