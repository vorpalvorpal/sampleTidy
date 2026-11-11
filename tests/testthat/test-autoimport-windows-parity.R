# PLAN-21 phase (b), work items b1 and b2: the Windows trigger dev/auto-import.ps1
# (PowerShell 7) at behavioural parity with the Mac's dev/auto-import.sh.
#
# Covered here (SPEC-b section 3, tests 1-16): the run-health record, retry after a
# failed or crashed run, the staleness notice, a listing failure (exit 3), an empty
# listing, the post-run re-check, the notify command and its desktop fallback, the
# flush command, --print-config, the pause file (a regular file only), a junk pid in
# the lock, exit codes, R's user environ file, and running main from a detached
# worktree. Cross-script parity tests run the .sh and the .ps1 on one fixture and
# compare what they leave behind.
#
# These tests run on the Mac (and Linux) through pwsh, with bash stubs for RSCRIPT, the
# notify command, the flush command and the desktop notifier. Windows-only facts (the
# balloon, the Documents folder) are not exercised: the laptop checks cover them, so the
# whole file is skipped on Windows, where bash stubs are not available.
#
# ISOLATION. Every path the scripts touch (DB, input, report dir, log, pause file, HOME,
# LOCALAPPDATA, the worktree, the environ file) is inside a temp dir. The child gets a
# CLEAN environment. R_ENVIRON_USER always points into the sandbox, and an `osascript`
# stub sits first on PATH: the Windows trigger must never call it.

# ---- helpers -------------------------------------------------------------------------------

ap_skip <- function() {
  skip_on_os("windows")
  skip_if(Sys.which("pwsh") == "", "no pwsh")
  skip_if(Sys.which("bash") == "", "no bash")
  skip_if(Sys.which("git") == "", "no git")
}

ap_dev <- function(...) normalizePath(testthat::test_path("..", "..", "dev", ...), mustWork = TRUE)

ap_lines <- function(path) if (file.exists(path)) readLines(path, warn = FALSE) else character()

ap_script <- function(s, via) {
  if (via == "sh") ap_dev("auto-import.sh") else (s$script %||% ap_dev("auto-import.ps1"))
}

#' A sandbox. DB, input (one file), watch folder, report dir (created), log, pause file
#' (NOT created), HOME, LOCALAPPDATA, a code dir (CODE override), an empty environ file,
#' and stubs. The RSCRIPT stub appends `run|pid|PREV_FAILURE|arg1|first line of arg1` to
#' runs.txt, and honours STUB_RC, STUB_SLEEP, STUB_HEALTH_COPY and, on its FIRST call only,
#' STUB_ARRIVE_FILE (after a pause, so the file is newer than the run's start). Every stub
#' appends its name to events.txt. notify.txt and desktop.txt hold `argc|title|message`;
#' flush.txt holds `argc|lock-present`.
ap_sandbox <- function(env = parent.frame()) {
  ap_skip()
  d <- normalizePath(withr::local_tempdir(.local_envir = env))
  s <- list(dir = d, home = file.path(d, "home"), lad = file.path(d, "lad"),
            db = file.path(d, "monitoring.duckdb"), input = file.path(d, "in"),
            watch = file.path(d, "watch"), report = file.path(d, "report"),
            log = file.path(d, "log", "autoimport.log"), off = file.path(d, "off"),
            code = file.path(d, "code"), bin = file.path(d, "bin"),
            environ = file.path(d, "environ"), once = file.path(d, "once"),
            runs = file.path(d, "runs.txt"), events = file.path(d, "events.txt"),
            notes = file.path(d, "notify.txt"), desk = file.path(d, "desktop.txt"),
            flushed = file.path(d, "flush.txt"), renv = file.path(d, "renv.txt"),
            copy = file.path(d, "health-copy.json"),
            rscript = file.path(d, "stub-rscript.sh"), notify = file.path(d, "stub-notify.sh"),
            flush = file.path(d, "stub-flush.sh"), desktop = file.path(d, "stub-desktop.sh"))
  for (p in c(s$home, s$lad, s$input, s$watch, s$report, s$bin, file.path(s$code, "dev"))) dir.create(p, recursive = TRUE)
  writeLines("x", s$db); file.create(s$environ)
  writeLines("x", file.path(s$input, "README.txt"))
  writeLines("# code", file.path(s$code, "dev", "auto-import.R"))
  ev <- function(n) sprintf('echo %s >> "%s"', n, s$events)
  writeLines(c("#!/bin/bash", ev("rscript"),
               sprintf('echo "run|$$|${SAMPLETIDY_AUTOIMPORT_PREV_FAILURE:-}|$1|$(head -1 "$1" 2>/dev/null)" >> "%s"', s$runs),
               sprintf('echo "${R_ENVIRON_USER:-}" >> "%s"', s$renv),
               sprintf('[ -n "${STUB_HEALTH_COPY:-}" ] && cp "%s/.imports.health" "$STUB_HEALTH_COPY"', s$report),
               sprintf('if [ ! -e "%s" ]; then touch "%s"', s$once, s$once),
               '  if [ -n "${STUB_ARRIVE_FILE:-}" ]; then sleep 1.2; echo y > "$STUB_ARRIVE_FILE"; fi',
               "fi",
               'sleep "${STUB_SLEEP:-0}"',
               'exit "${STUB_RC:-0}"'), s$rscript)
  writeLines(c("#!/bin/bash", ev("notify"), sprintf('echo "$#|$1|$2" >> "%s"', s$notes),
               'exit "${STUB_NOTIFY_RC:-0}"'), s$notify)
  writeLines(c("#!/bin/bash", ev("desktop"), sprintf('echo "$#|$1|$2" >> "%s"', s$desk)), s$desktop)
  writeLines(c("#!/bin/bash", ev("flush"),
               sprintf('if [ -d "%s/.imports.lock" ]; then echo "$#|lock" >> "%s"; else echo "$#|nolock" >> "%s"; fi',
                       s$report, s$flushed, s$flushed),
               # a flush that leaves a failed-run record behind: proves it ran before the health read
               sprintf('[ -n "${STUB_FLUSH_HEALTH:-}" ] && echo \'{"state":"done","pid":1,"started_at":"2026-01-02T03:04:05Z","ended_at":"2026-01-02T03:05:05Z","rc":2,"last_success_at":null}\' > "%s/.imports.health"', s$report),
               'echo "flush-stdout-marker"; echo "flush-stderr-marker" >&2',
               'exit "${STUB_FLUSH_RC:-0}"'), s$flush)
  osa <- file.path(s$bin, "osascript")
  writeLines(c("#!/bin/bash", ev("osascript")), osa)
  Sys.chmod(c(s$rscript, s$notify, s$flush, s$desktop, osa), "755")
  s
}

#' The child environment for a run of the `.sh` or `.ps1`. `...` adds or overrides
#' (NA = unset).
ap_env <- function(s, ..., via = "ps1") {
  v <- c(SAMPLETIDY_AUTOIMPORT_DB = s$db, SAMPLETIDY_AUTOIMPORT_INPUT = s$input,
         SAMPLETIDY_AUTOIMPORT_REPORT = s$report, SAMPLETIDY_AUTOIMPORT_RSCRIPT = s$rscript,
         SAMPLETIDY_AUTOIMPORT_LOG = s$log, SAMPLETIDY_AUTOIMPORT_CODE = s$code,
         SAMPLETIDY_AUTOIMPORT_OFF = s$off, SAMPLETIDY_AUTOIMPORT_NOTIFY = s$notify,
         R_ENVIRON_USER = s$environ, LOCALAPPDATA = s$lad)
  over <- c(...)
  if (length(over)) v <- c(v[setdiff(names(v), names(over))], over)
  unset <- names(v)[is.na(v)]   # NA unsets, base variables included
  v <- v[!is.na(v)]
  pw <- dirname(Sys.which("pwsh"))
  base <- c(HOME = s$home, PATH = paste(c(s$bin, "/usr/bin", "/bin", pw), collapse = ":"),
            POWERSHELL_TELEMETRY_OPTOUT = "1", DOTNET_CLI_TELEMETRY_OPTOUT = "1")
  c(base[setdiff(names(base), c(names(v), unset))], v)
}

ap_cmd <- function(s, args, via) {
  if (via == "sh") list(cmd = "bash", args = c(ap_script(s, "sh"), args))
  else list(cmd = as.character(Sys.which("pwsh")), args = c("-NoProfile", "-File", ap_script(s, "ps1"), args))
}

#' Run the trigger to completion.
ap_run <- function(s, ..., args = character(), via = "ps1") {
  a <- ap_cmd(s, args, via)
  expect_true(file.exists(ap_script(s, via)))
  processx::run(a$cmd, a$args, env = ap_env(s, ..., via = via), error_on_status = FALSE, timeout = 90)
}

ap_info <- function(r) paste(r$stdout, r$stderr)
ap_ok <- function(r) expect_identical(r$status, 0L, info = ap_info(r))

ap_runs <- function(s) ap_lines(s$runs)
ap_notes <- function(s) ap_lines(s$notes)
ap_events <- function(s) ap_lines(s$events)
ap_log <- function(s) paste(ap_lines(s$log), collapse = "\n")
ap_health_path <- function(s) file.path(s$report, ".imports.health")
ap_notified <- function(s) ap_lines(file.path(s$report, ".imports.notified"))
ap_gate <- function(s) file.path(s$report, ".imports.gate")
ap_lock <- function(s) file.path(s$report, ".imports.lock")
ap_health <- function(s) {
  expect_true(file.exists(ap_health_path(s)), info = "the trigger writes .imports.health")
  if (!file.exists(ap_health_path(s))) return(list())
  jsonlite::fromJSON(ap_health_path(s), simplifyVector = FALSE)
}
ap_utc <- function(t) format(t, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
ap_write_health <- function(s, ...) {
  dir.create(s$report, showWarnings = FALSE, recursive = TRUE)
  jsonlite::write_json(list(...), ap_health_path(s), auto_unbox = TRUE, null = "null")
}
ap_reset <- function(s) unlink(c(s$runs, s$events, s$notes, s$desk, s$flushed, s$renv))

#' One good run, so a gate exists and the next tick sees nothing changed.
ap_prime <- function(s, ..., via = "ps1") {
  r <- ap_run(s, ..., via = via)
  ap_ok(r)
  expect_length(ap_runs(s), 1L)
  writeLines('{"pending": false}', file.path(s$report, ".imports.state"))
  ap_reset(s)
  invisible(r)
}

ap_skip_if_root <- function() skip_if(identical(Sys.info()[["user"]], "root"), "root can list a mode-000 directory")

#' A subfolder of the input that cannot be listed.
ap_lock_input <- function(s, env = parent.frame()) {
  p <- file.path(s$input, "locked"); dir.create(p)
  withr::defer(Sys.chmod(p, "755"), envir = env)
  Sys.chmod(p, "000")
  p
}

ap_kv <- function(r) {
  out <- strsplit(r$stdout, "\r?\n")[[1]]
  out <- out[nzchar(out)]
  list(lines = out, keys = sub("=.*$", "", out), vals = sub("^[^=]*=", "", out))
}
ap_print <- function(s, ..., args = "-PrintConfig") {
  r <- ap_run(s, ..., args = args)
  ap_ok(r)
  ap_kv(r)
}

# ---- 1. health record -----------------------------------------------------------------------

test_that("health: `running` is on disk before the R child starts, `done` with rc and ended_at after", {
  s <- ap_sandbox()
  r <- ap_run(s, STUB_HEALTH_COPY = s$copy)
  ap_ok(r)
  expect_true(file.exists(s$copy), info = "the health file existed while the child ran")
  during <- jsonlite::fromJSON(s$copy, simplifyVector = FALSE)
  expect_identical(during$state, "running")
  expect_true(is.numeric(during$pid) && during$pid > 0)
  expect_match(during$started_at, "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z$")
  expect_null(during$ended_at); expect_null(during$rc); expect_null(during$last_success_at)
  done <- ap_health(s)
  expect_identical(done$state, "done")
  expect_identical(as.integer(done$rc), 0L)
  expect_identical(done$started_at, during$started_at)
  expect_match(done$ended_at, "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z$")
  expect_identical(done$last_success_at, done$ended_at)
})

test_that("health: the keys are exactly the .sh's, in the .sh's order", {
  s <- ap_sandbox()
  ap_ok(ap_run(s))
  expect_identical(names(ap_health(s)), c("state", "pid", "started_at", "ended_at", "rc", "last_success_at"))
})

test_that("health: last_success_at moves only on rc 0", {
  s <- ap_sandbox()
  old <- ap_utc(Sys.time() - 3600)
  ap_write_health(s, state = "done", pid = 1L, started_at = old, ended_at = old, rc = 0L, last_success_at = old)
  r <- ap_run(s, STUB_RC = "2")                  # retry runs, fails
  expect_identical(r$status, 2L, info = ap_info(r))
  h <- ap_health(s)
  expect_identical(as.integer(h$rc), 2L)
  expect_identical(h$last_success_at, old)       # unchanged by a failure
  r <- ap_run(s)                                  # retry succeeds
  ap_ok(r)
  h <- ap_health(s)
  expect_identical(as.integer(h$rc), 0L)
  expect_identical(h$last_success_at, h$ended_at)
  expect_false(identical(h$last_success_at, old))
})

test_that("health: with no earlier success, last_success_at is JSON null after a failure", {
  s <- ap_sandbox()
  r <- ap_run(s, STUB_RC = "3")
  expect_identical(r$status, 3L, info = ap_info(r))
  h <- ap_health(s)
  expect_true("last_success_at" %in% names(h))
  expect_null(h$last_success_at)
  expect_match(paste(ap_lines(ap_health_path(s)), collapse = ""), '"last_success_at":\\s*null')
})

test_that("health: written by temp file and rename, as UTF-8 with LF line endings and no BOM", {
  s <- ap_sandbox()
  ap_ok(ap_run(s))
  expect_identical(list.files(s$report, pattern = "health.*tmp|tmp.*health", all.files = TRUE), character())
  b <- readBin(ap_health_path(s), "raw", 4000)
  expect_false(identical(b[1:3], as.raw(c(0xef, 0xbb, 0xbf))))
  expect_identical(b[1], charToRaw("{"))
  expect_false(as.raw(13) %in% b)
  expect_identical(b[length(b)], as.raw(10))
})

# ---- 2. retry after a failed or crashed run ----------------------------------------------------

test_that("retry: a record still `running` bypasses the gate, tells R, and notifies once per started_at", {
  s <- ap_sandbox()
  ap_prime(s)
  t0 <- "2026-01-02T03:04:05Z"
  rec <- function() ap_write_health(s, state = "running", pid = 1L, started_at = t0, ended_at = NULL, rc = NULL, last_success_at = NULL)
  rec()
  ap_ok(ap_run(s))
  runs <- strsplit(ap_runs(s), "|", fixed = TRUE)
  expect_length(runs, 1L)
  expect_identical(runs[[1]][3], paste0("The import started ", t0, " did not finish"))
  expect_identical(ap_notes(s), paste0("2|sampleTidy import failed|The import started ", t0, " did not finish; retrying"))
  expect_true(paste0("fail:", t0) %in% ap_notified(s))
  # the same failed run again (e.g. the retry crashed too): retried again, not re-notified
  writeLines('{"pending": false}', file.path(s$report, ".imports.state"))
  rec()
  ap_ok(ap_run(s))
  expect_length(ap_runs(s), 2L)
  expect_length(ap_notes(s), 1L)
})

test_that("retry: a `done` record with rc not 0 retries past the gate with the failed-rc wording", {
  s <- ap_sandbox()
  ap_prime(s)
  t0 <- "2026-01-02T03:04:05Z"
  ap_write_health(s, state = "done", pid = 1L, started_at = t0, ended_at = t0, rc = 2L, last_success_at = NULL)
  ap_ok(ap_run(s))
  runs <- strsplit(ap_runs(s), "|", fixed = TRUE)
  expect_length(runs, 1L)
  expect_identical(runs[[1]][3], paste0("The import started ", t0, " failed (rc 2)"))
  expect_identical(ap_notes(s), paste0("2|sampleTidy import failed|The import started ", t0, " failed (rc 2); retrying"))
})

test_that("retry: a `done` record with rc 0 and an unchanged gate is skipped, with no notice and no failure text", {
  s <- ap_sandbox()
  ap_prime(s)
  ap_ok(ap_run(s))
  expect_length(ap_runs(s), 0L)
  expect_length(ap_notes(s), 0L)
  ap_write_health(s, state = "done", pid = 1L, started_at = ap_utc(Sys.time()), ended_at = ap_utc(Sys.time()),
                  rc = 0L, last_success_at = ap_utc(Sys.time()))
  ap_ok(ap_run(s))
  expect_length(ap_runs(s), 0L)
})

# ---- 3. staleness -------------------------------------------------------------------------------

test_that("stale: no success for 24 h notifies once per local day, also on a tick that skips", {
  s <- ap_sandbox()
  tz <- "Pacific/Kiritimati"
  ap_prime(s, SAMPLETIDY_TIMEZONE = tz)          # the gate hashes the local date: prime in the same zone
  succ <- ap_utc(Sys.time() - 48 * 3600)
  rec <- function() ap_write_health(s, state = "done", pid = 1L, started_at = succ, ended_at = succ, rc = 0L, last_success_at = succ)
  rec()
  ap_ok(ap_run(s, SAMPLETIDY_TIMEZONE = tz))
  expect_length(ap_runs(s), 0L)                  # the gate still skips
  expect_identical(ap_notes(s), paste0("2|sampleTidy import stale|No successful import since ", succ, " (over 24 hours)"))
  expect_true(paste0("stale:", format(Sys.time(), "%Y-%m-%d", tz = tz)) %in% ap_notified(s))
  rec()
  ap_ok(ap_run(s, SAMPLETIDY_TIMEZONE = tz))
  expect_length(ap_notes(s), 1L)                 # same local day: not again
})

test_that("stale: SAMPLETIDY_AUTOIMPORT_STALE_HOURS sets the threshold", {
  s <- ap_sandbox()
  ap_prime(s)
  succ <- ap_utc(Sys.time() - 2 * 3600)
  ap_write_health(s, state = "done", pid = 1L, started_at = succ, ended_at = succ, rc = 0L, last_success_at = succ)
  ap_ok(ap_run(s))
  expect_length(ap_notes(s), 0L)                 # 2 h is under the 24 h default
  ap_ok(ap_run(s, SAMPLETIDY_AUTOIMPORT_STALE_HOURS = "1"))
  expect_match(ap_notes(s), "No successful import since .* \\(over 1 hours\\)$")
})

test_that("stale: never when there has been no success, nor when there is no health record", {
  s <- ap_sandbox()
  ap_ok(ap_run(s, STUB_RC = "0"))                # no record at all: runs, no notice
  expect_length(ap_notes(s), 0L)
  s <- ap_sandbox()
  t0 <- ap_utc(Sys.time() - 72 * 3600)
  ap_write_health(s, state = "done", pid = 1L, started_at = t0, ended_at = t0, rc = 0L, last_success_at = NULL)
  ap_ok(ap_run(s))
  expect_length(ap_notes(s), 0L)
})

# ---- 4-6. listing failure, empty listing, re-check -----------------------------------------------

test_that("listfail: an unreadable subfolder is logged, notified once per day, exits 3, runs nothing, writes no gate", {
  ap_skip_if_root()
  s <- ap_sandbox()
  ap_lock_input(s)
  r <- ap_run(s)
  expect_identical(r$status, 3L, info = ap_info(r))
  expect_length(ap_runs(s), 0L)
  expect_match(ap_log(s), "cannot list", fixed = TRUE)
  expect_length(ap_notes(s), 1L)
  expect_match(ap_notes(s), "^2\\|sampleTidy import cannot read its input\\|")
  expect_true(paste0("listfail:", format(Sys.time(), "%Y-%m-%d", tz = "UTC")) %in% ap_notified(s))
  expect_false(file.exists(ap_gate(s)))
  expect_false(dir.exists(ap_lock(s)))
  r <- ap_run(s)                                  # a second tick: still exit 3, no second notice
  expect_identical(r$status, 3L, info = ap_info(r))
  expect_length(ap_notes(s), 1L)
})

test_that("listfail: a primed gate does not let a partial listing skip the run", {
  ap_skip_if_root()
  s <- ap_sandbox()
  ap_prime(s)
  ap_lock_input(s)
  r <- ap_run(s)
  expect_identical(r$status, 3L, info = ap_info(r))
  expect_length(ap_runs(s), 0L)
})

test_that("empty listing: R runs, even with a gate and state that would otherwise skip", {
  s <- ap_sandbox()
  file.remove(file.path(s$input, "README.txt"))
  ap_ok(ap_run(s))
  expect_length(ap_runs(s), 1L)
  writeLines('{"pending": false}', file.path(s$report, ".imports.state"))
  ap_ok(ap_run(s))
  expect_length(ap_runs(s), 2L)
  expect_match(ap_log(s), "input listing is empty", fixed = TRUE)
})

test_that("re-check: a file arriving during the run leaves the gate unwritten, and the next tick runs R", {
  s <- ap_sandbox()
  ap_ok(ap_run(s, STUB_ARRIVE_FILE = file.path(s$input, "late.txt")))
  expect_length(ap_runs(s), 1L)
  expect_false(file.exists(ap_gate(s)))
  expect_match(ap_log(s), "input changed during the run", fixed = TRUE)
  writeLines('{"pending": false}', file.path(s$report, ".imports.state"))
  ap_ok(ap_run(s))
  expect_length(ap_runs(s), 2L)                   # the late file is picked up
  expect_true(file.exists(ap_gate(s)))            # now nothing changed during the run
})

test_that("re-check: a change in the watch folder during the run does the same", {
  s <- ap_sandbox()
  w <- c(SAMPLETIDY_GATE_WATCH = s$watch)
  ap_ok(ap_run(s, w, STUB_ARRIVE_FILE = file.path(s$watch, "claim.json")))
  expect_false(file.exists(ap_gate(s)))
  expect_match(ap_log(s), "input changed during the run", fixed = TRUE)
  writeLines('{"pending": false}', file.path(s$report, ".imports.state"))
  ap_ok(ap_run(s, w))
  expect_length(ap_runs(s), 2L)
  expect_true(file.exists(ap_gate(s)))
})

# ---- 7. the notify command --------------------------------------------------------------------

# A failed previous run makes every tick notify once.
ap_fail_record <- function(s, t0 = "2026-01-02T03:04:05Z") {
  ap_write_health(s, state = "done", pid = 1L, started_at = t0, ended_at = t0, rc = 2L, last_success_at = NULL)
}

# A .ps1 notify command that records what it received: argc, each argument as base64 of
# its UTF-8 bytes, the process path and the command line of the pwsh that runs it.
ap_ps1_notifier <- function(s) {
  p <- file.path(s$dir, "notify.ps1")
  writeLines(c('$o = $env:STUB_PS1_OUT',
               '$l = @("argc=$($args.Count)")',
               'foreach ($a in $args) { $l += [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$a)) }',
               '$l += "proc=" + [Environment]::ProcessPath',
               '$l += "cmdline=" + ([Environment]::GetCommandLineArgs() -join " ")',
               '[IO.File]::WriteAllLines($o, $l)',
               'if ($env:STUB_NOTIFY_RC) { exit [int]$env:STUB_NOTIFY_RC }'), p)
  p
}

test_that("notify: the command gets exactly two arguments, title then message", {
  s <- ap_sandbox()
  ap_fail_record(s)
  ap_ok(ap_run(s))
  expect_identical(ap_notes(s), "2|sampleTidy import failed|The import started 2026-01-02T03:04:05Z failed (rc 2); retrying")
})

test_that("notify: a command ending .ps1 runs under the same pwsh with -NoProfile -NonInteractive -File", {
  s <- ap_sandbox()
  n <- ap_ps1_notifier(s)
  out <- file.path(s$dir, "ps1-out.txt")
  ap_fail_record(s)
  ap_ok(ap_run(s, SAMPLETIDY_AUTOIMPORT_NOTIFY = n, STUB_PS1_OUT = out))
  expect_true(file.exists(out), info = "the .ps1 notifier ran")
  o <- ap_lines(out)
  expect_identical(o[1], "argc=2")
  expect_identical(rawToChar(jsonlite::base64_dec(o[2])), "sampleTidy import failed")
  expect_match(rawToChar(jsonlite::base64_dec(o[3])), "^The import started 2026-01-02T03:04:05Z failed \\(rc 2\\); retrying$")
  proc <- sub("^proc=", "", grep("^proc=", o, value = TRUE))
  expect_identical(normalizePath(proc), normalizePath(Sys.which("pwsh")))
  cl <- sub("^cmdline=", "", grep("^cmdline=", o, value = TRUE))
  expect_match(cl, "-NoProfile", fixed = TRUE)
  expect_match(cl, "-NonInteractive", fixed = TRUE)
  expect_match(cl, "-File", fixed = TRUE)
})

test_that("notify: awkward characters in a message (quotes, %, ^, &, ', a newline) arrive byte-exact", {
  ap_skip_if_root()
  s <- ap_sandbox()
  nasty <- file.path(s$dir, "in \"q\" %x% ^&' 100\nz")      # the message names the input folder
  dir.create(nasty); writeLines("x", file.path(nasty, "README.txt"))
  p <- file.path(nasty, "locked"); dir.create(p); withr::defer(Sys.chmod(p, "755")); Sys.chmod(p, "000")
  n <- ap_ps1_notifier(s)
  out <- file.path(s$dir, "ps1-out.txt")
  r <- ap_run(s, SAMPLETIDY_AUTOIMPORT_NOTIFY = n, STUB_PS1_OUT = out, SAMPLETIDY_AUTOIMPORT_INPUT = nasty)
  expect_identical(r$status, 3L, info = ap_info(r))
  o <- ap_lines(out)
  expect_identical(o[1], "argc=2")                         # a newline did not split the message
  msg <- rawToChar(jsonlite::base64_dec(o[3]))
  expect_true(grepl(nasty, msg, fixed = TRUE), info = msg)
})

test_that("notify: a non-zero exit from the command is logged only", {
  s <- ap_sandbox()
  ap_fail_record(s)
  ap_ok(ap_run(s, STUB_NOTIFY_RC = "5"))
  expect_match(ap_log(s), "notify command exited 5", fixed = TRUE)
  expect_length(ap_lines(s$desk), 0L)              # no fallback to the desktop on a command's failure
})

test_that("notify: a command that is set but missing is logged and the desktop program is used", {
  s <- ap_sandbox()
  ap_fail_record(s)
  gone <- file.path(s$dir, "no-such-notifier.sh")
  ap_ok(ap_run(s, SAMPLETIDY_AUTOIMPORT_NOTIFY = gone, SAMPLETIDY_NOTIFY_DESKTOP = s$desktop))
  expect_match(ap_log(s), "notify command not (found|executable)")
  expect_match(ap_log(s), gone, fixed = TRUE)
  expect_identical(ap_lines(s$desk), "2|sampleTidy import failed|The import started 2026-01-02T03:04:05Z failed (rc 2); retrying")
})

test_that("notify: with no command the desktop program is used; never osascript", {
  s <- ap_sandbox()
  ap_fail_record(s)
  ap_ok(ap_run(s, SAMPLETIDY_AUTOIMPORT_NOTIFY = NA, SAMPLETIDY_NOTIFY_DESKTOP = s$desktop))
  expect_length(ap_lines(s$desk), 1L)
  expect_false("osascript" %in% ap_events(s))
})

test_that("notify: with no command and no desktop program, off Windows the notice is a log line, never osascript", {
  s <- ap_sandbox()
  ap_fail_record(s)
  ap_ok(ap_run(s, SAMPLETIDY_AUTOIMPORT_NOTIFY = NA))
  expect_match(ap_log(s), "sampleTidy import failed", fixed = TRUE)
  expect_false("osascript" %in% ap_events(s))
})

test_that("notify: the command is read from SAMPLETIDY_NOTIFY_COMMAND, then from the environ file", {
  s <- ap_sandbox()
  ap_fail_record(s)
  ap_ok(ap_run(s, SAMPLETIDY_AUTOIMPORT_NOTIFY = NA, SAMPLETIDY_NOTIFY_COMMAND = s$notify))
  expect_length(ap_notes(s), 1L)
  s <- ap_sandbox()
  ap_fail_record(s)
  writeLines(sprintf("SAMPLETIDY_NOTIFY_COMMAND=%s", s$notify), s$environ)
  ap_ok(ap_run(s, SAMPLETIDY_AUTOIMPORT_NOTIFY = NA))
  expect_length(ap_notes(s), 1L)
})

# ---- 8. the flush command -----------------------------------------------------------------------

test_that("flush: run once per tick, after the lock is taken, with no arguments, output to the log, rc ignored", {
  s <- ap_sandbox()
  r <- ap_run(s, SAMPLETIDY_NOTIFY_FLUSH = s$flush, STUB_FLUSH_RC = "7")
  ap_ok(r)                                          # the flush's rc 7 does not become the trigger's
  expect_identical(ap_lines(s$flushed), "0|lock")
  expect_match(ap_log(s), "flush-stdout-marker", fixed = TRUE)
  expect_match(ap_log(s), "flush-stderr-marker", fixed = TRUE)
  expect_identical(ap_events(s)[1:2], c("flush", "rscript"))
})

test_that("flush: runs before the health record is read (what it leaves behind is what the tick sees)", {
  s <- ap_sandbox()
  ap_prime(s)
  ap_ok(ap_run(s, SAMPLETIDY_NOTIFY_FLUSH = s$flush, STUB_FLUSH_HEALTH = "1"))
  expect_length(ap_runs(s), 1L)                    # the failed record bypassed the gate
  expect_match(ap_notes(s), "failed \\(rc 2\\); retrying")
  expect_identical(ap_events(s)[1:3], c("flush", "notify", "rscript"))
})

test_that("flush: runs on a tick the gate skips, once", {
  s <- ap_sandbox()
  ap_prime(s)
  ap_ok(ap_run(s, SAMPLETIDY_NOTIFY_FLUSH = s$flush))
  expect_length(ap_runs(s), 0L)
  expect_identical(ap_lines(s$flushed), "0|lock")
})

test_that("flush: not run on a paused tick, a no-DB tick or a tick that finds the lock held", {
  s <- ap_sandbox()
  f <- c(SAMPLETIDY_NOTIFY_FLUSH = s$flush)
  writeLines("holder", s$off)
  ap_ok(ap_run(s, f))
  unlink(s$off)
  file.remove(s$db)
  ap_ok(ap_run(s, f))
  writeLines("x", s$db)
  dir.create(ap_lock(s)); writeLines(as.character(Sys.getpid()), file.path(ap_lock(s), "pid"))
  ap_ok(ap_run(s, f))
  expect_false(file.exists(s$flushed))
  expect_false("flush" %in% ap_events(s))
})

test_that("flush: a set but missing command is logged and ignored", {
  s <- ap_sandbox()
  gone <- file.path(s$dir, "no-such-flush.sh")
  ap_ok(ap_run(s, SAMPLETIDY_NOTIFY_FLUSH = gone))
  expect_match(ap_log(s), "flush command not (found|executable)")
  expect_length(ap_runs(s), 1L)
})

# ---- 9. --print-config ---------------------------------------------------------------------------

test_that("--print-config: eight lines, the .sh's keys in the .sh's order, NOTIFY and NOTIFY_FLUSH resolved", {
  s <- ap_sandbox()
  k <- ap_print(s, SAMPLETIDY_AUTOIMPORT_NOTIFY = NA, SAMPLETIDY_NOTIFY_COMMAND = "/some/notify",
                SAMPLETIDY_NOTIFY_FLUSH = "/some/flush", SAMPLETIDY_GATE_WATCH = "/some/watch")
  expect_identical(k$keys, c("DB", "INPUT", "REPORT", "TIMEZONE", "LOG", "NOTIFY", "NOTIFY_FLUSH", "WATCH"))
  expect_identical(k$vals[6:8], c("/some/notify", "/some/flush", "/some/watch"))
  k2 <- ap_print(s, SAMPLETIDY_NOTIFY_COMMAND = "/some/notify", args = "--print-config")   # the AUTOIMPORT_NOTIFY override wins
  expect_identical(k2$vals[6], s$notify)
})

test_that("--print-config: the same values as the .sh on the same fixture", {
  s <- ap_sandbox()
  v <- c(SAMPLETIDY_NOTIFY_COMMAND = "/some/notify", SAMPLETIDY_NOTIFY_FLUSH = "/some/flush",
         SAMPLETIDY_GATE_WATCH = "/some/watch", SAMPLETIDY_TIMEZONE = "Pacific/Kiritimati",
         SAMPLETIDY_AUTOIMPORT_NOTIFY = NA)
  sh <- ap_run(s, v, args = "--print-config", via = "sh")
  ps <- ap_run(s, v, args = "--print-config", via = "ps1")
  ap_ok(sh); ap_ok(ps)
  expect_identical(ap_kv(ps)$lines, ap_kv(sh)$lines)
})

test_that("--print-config has no side effects (no log, report or lock folder, no pause-file or DB needed)", {
  s <- ap_sandbox()
  unlink(s$report, recursive = TRUE)
  file.remove(s$db)
  writeLines("holder", s$off)
  ap_print(s, SAMPLETIDY_NOTIFY_FLUSH = s$flush)
  expect_false(dir.exists(s$report))
  expect_false(dir.exists(dirname(s$log)))
  expect_false(file.exists(s$flushed))
  expect_false(file.exists(s$runs))
})

# ---- 10-12. pause file, junk pid, exit codes -------------------------------------------------------

test_that("pause: a regular file pauses; a FOLDER of that name does not (the .sh's -f)", {
  s <- ap_sandbox()
  dir.create(s$off)
  ap_ok(ap_run(s))
  expect_length(ap_runs(s), 1L)
  unlink(s$off, recursive = TRUE)
  writeLines("holder", s$off)
  ap_reset(s)
  ap_ok(ap_run(s))
  expect_length(ap_runs(s), 0L)
})

test_that("lock: a pid file holding a non-numeric line is `no pid`: respected while fresh, never read as pid 0", {
  s <- ap_sandbox()
  # junk that a naive digit-substitution turns into a plausible, dead pid (99999x9 -> 9999909)
  dir.create(ap_lock(s)); writeLines("99999x9", file.path(ap_lock(s), "pid"))
  ap_ok(ap_run(s))
  expect_length(ap_runs(s), 0L)
  expect_match(ap_log(s), "already in progress", fixed = TRUE)
  expect_true(dir.exists(ap_lock(s)))
  expect_false(grepl("took over", ap_log(s), fixed = TRUE))
})

test_that("lock: a pid file with a non-numeric line is taken over once the lock is older than 120 minutes", {
  s <- ap_sandbox()
  dir.create(ap_lock(s)); writeLines("not-a-pid", file.path(ap_lock(s), "pid"))
  Sys.setFileTime(ap_lock(s), Sys.time() - 3 * 3600)
  ap_ok(ap_run(s))
  expect_length(ap_runs(s), 1L)
  expect_match(ap_log(s), "took over a stale lock", fixed = TRUE)
})

test_that("exit codes: R's rc passes through (0, 2, 7); 3 is a listing failure", {
  for (rc in c(0L, 2L, 7L)) {
    s <- ap_sandbox()
    r <- ap_run(s, STUB_RC = as.character(rc))
    expect_identical(r$status, rc, info = ap_info(r))
  }
})

# ---- cross-script parity -----------------------------------------------------------------------------

# Run one scenario against the .sh or the .ps1 and return what they leave behind.
ap_observe <- function(scenario, via) {
  s <- ap_sandbox()
  status <- scenario(s, via)
  h <- if (file.exists(ap_health_path(s))) ap_health(s) else list()
  norm <- function(k, v) {
    if (is.null(v)) return("null")
    if (k %in% c("pid", "started_at", "ended_at")) return("<set>")
    if (k == "last_success_at" && identical(v, h$ended_at)) return("<ended>")
    as.character(v)
  }
  # Each run has its own sandbox, so its paths are masked before comparing.
  mask <- function(x) gsub(s$dir, "<sandbox>", x, fixed = TRUE)
  list(status = status,
       notes = mask(ap_notes(s)), notified = sort(mask(ap_notified(s))),
       runs = vapply(strsplit(ap_runs(s), "|", fixed = TRUE), function(x) x[3], ""),
       keys = names(h), health = mask(unlist(Map(norm, names(h), h))))
}
ap_same <- function(scenario, label) {
  sh <- ap_observe(scenario, "sh")
  ps <- ap_observe(scenario, "ps1")
  expect_identical(ps, sh, info = label)
}

test_that("parity: a failed previous run (notice, PREV_FAILURE text, retry, new health)", {
  ap_same(function(s, via) {
    ap_prime(s, via = via)
    ap_write_health(s, state = "done", pid = 1L, started_at = "2026-01-02T03:04:05Z",
                    ended_at = "2026-01-02T03:05:05Z", rc = 2L, last_success_at = "2026-01-01T00:00:00Z")
    ap_run(s, SAMPLETIDY_AUTOIMPORT_STALE_HOURS = "100000", via = via)$status
  }, "failed previous run")
})

test_that("parity: a crashed previous run", {
  ap_same(function(s, via) {
    ap_prime(s, via = via)
    ap_write_health(s, state = "running", pid = 1L, started_at = "2026-01-02T03:04:05Z",
                    ended_at = NULL, rc = NULL, last_success_at = NULL)
    ap_run(s, via = via)$status
  }, "crashed previous run")
})

test_that("parity: a stale success", {
  ap_same(function(s, via) {
    ap_prime(s, via = via)
    old <- "2026-01-02T03:04:05Z"
    ap_write_health(s, state = "done", pid = 1L, started_at = old, ended_at = old, rc = 0L, last_success_at = old)
    ap_run(s, via = via)$status
  }, "stale success")
})

test_that("parity: a failing first run leaves the same health", {
  ap_same(function(s, via) ap_run(s, STUB_RC = "2", via = via)$status, "failing first run")
})

test_that("parity: a listing failure", {
  ap_skip_if_root()
  ap_same(function(s, via) { ap_lock_input(s); ap_run(s, via = via)$status }, "listing failure")
})

# ---- 13. R's user environ file ------------------------------------------------------------------------

ap_unset_overrides <- c(SAMPLETIDY_AUTOIMPORT_INPUT = NA, SAMPLETIDY_AUTOIMPORT_REPORT = NA,
                        SAMPLETIDY_AUTOIMPORT_NOTIFY = NA)

ap_print_env <- function(s, ..., args = "-PrintConfig") {
  ap_print(s, c(ap_unset_overrides), ..., args = args)
}

test_that("environ: the six keys are read from the file", {
  s <- ap_sandbox()
  batches <- file.path(s$dir, "batches")
  writeLines(c(sprintf("SAMPLETIDY_INPUT_DIR=%s", file.path(batches, "input")),
               "SAMPLETIDY_REPORT_DIR=/from/file/reports",
               "SAMPLETIDY_TIMEZONE=Pacific/Kiritimati",
               "SAMPLETIDY_NOTIFY_COMMAND=/from/file/notify",
               "SAMPLETIDY_NOTIFY_FLUSH=/from/file/flush",
               "SAMPLETIDY_GATE_WATCH=/from/file/watch"), s$environ)
  k <- ap_print_env(s)
  expect_identical(k$vals[2:4], c(batches, "/from/file/reports", "Pacific/Kiritimati"))
  expect_identical(k$vals[6:8], c("/from/file/notify", "/from/file/flush", "/from/file/watch"))
})

test_that("environ: the process environment beats the file", {
  s <- ap_sandbox()
  writeLines(c("SAMPLETIDY_TIMEZONE=From/File", "SAMPLETIDY_GATE_WATCH=/from/file"), s$environ)
  k <- ap_print_env(s, SAMPLETIDY_TIMEZONE = "From/Env", SAMPLETIDY_GATE_WATCH = "/from/env")
  expect_identical(k$vals[4], "From/Env")
  expect_identical(k$vals[8], "/from/env")
})

test_that("environ: the last KEY= line wins; one pair of quotes is stripped; a bare $VAR and ~ are not expanded", {
  s <- ap_sandbox()
  writeLines(c("SAMPLETIDY_TIMEZONE=First/Zone",
               "SAMPLETIDY_TIMEZONE='Second/Zone'",
               'SAMPLETIDY_GATE_WATCH="/with spaces/watch"',
               "SAMPLETIDY_NOTIFY_FLUSH=\"'nested'\"",
               "SAMPLETIDY_NOTIFY_COMMAND=$HOME/bin/notify",
               "SAMPLETIDY_REPORT_DIR=~/reports/$X"), s$environ)   # (a ${X} IS expanded, as R does: see 13b)
  k <- ap_print_env(s)
  expect_identical(k$vals[4], "Second/Zone")
  expect_identical(k$vals[8], "/with spaces/watch")
  expect_identical(k$vals[7], "'nested'")
  expect_identical(k$vals[6], "$HOME/bin/notify")
  expect_identical(k$vals[3], "~/reports/$X")
})

test_that("environ: comment lines and blank lines are ignored; a CRLF file is read cleanly", {
  s <- ap_sandbox()
  writeLines(c("# SAMPLETIDY_TIMEZONE=Commented/Out", "#SAMPLETIDY_GATE_WATCH=/commented", "",
               "SAMPLETIDY_TIMEZONE=Real/Zone"), s$environ)
  k <- ap_print_env(s)
  expect_identical(k$vals[4], "Real/Zone")
  expect_identical(k$vals[8], "")
  writeLines(c("SAMPLETIDY_TIMEZONE=Crlf/Zone", "SAMPLETIDY_GATE_WATCH=/crlf/watch"), s$environ, sep = "\r\n")
  k <- ap_print_env(s)
  expect_identical(k$vals[4], "Crlf/Zone")
  expect_identical(k$vals[8], "/crlf/watch")
})

test_that("environ: file location is R_ENVIRON_USER, else HOME/.Renviron, else R_USER/.Renviron", {
  s <- ap_sandbox()
  writeLines("SAMPLETIDY_TIMEZONE=Home/Zone", file.path(s$home, ".Renviron"))
  ruser <- file.path(s$dir, "ruser"); dir.create(ruser)
  writeLines("SAMPLETIDY_TIMEZONE=RUser/Zone", file.path(ruser, ".Renviron"))
  explicit <- file.path(s$dir, "explicit.env")
  writeLines("SAMPLETIDY_TIMEZONE=Explicit/Zone", explicit)
  expect_identical(ap_print_env(s, R_ENVIRON_USER = explicit, R_USER = ruser)$vals[4], "Explicit/Zone")
  expect_identical(ap_print_env(s, R_ENVIRON_USER = NA, R_USER = ruser)$vals[4], "Home/Zone")
  expect_identical(ap_print_env(s, R_ENVIRON_USER = NA, R_USER = ruser, HOME = NA)$vals[4], "RUser/Zone")
})

test_that("environ: an unreadable file means no keys, is logged, and the tick still runs", {
  ap_skip_if_root()
  s <- ap_sandbox()
  writeLines("SAMPLETIDY_TIMEZONE=Hidden/Zone", s$environ)
  Sys.chmod(s$environ, "000"); withr::defer(Sys.chmod(s$environ, "644"))
  r <- ap_run(s, SAMPLETIDY_AUTOIMPORT_INPUT = NA, SAMPLETIDY_AUTOIMPORT_REPORT = NA,
              SAMPLETIDY_INPUT_DIR = s$input, SAMPLETIDY_REPORT_DIR = s$report)
  ap_ok(r)
  expect_length(ap_runs(s), 1L)
  expect_match(ap_log(s), "environ", ignore.case = TRUE)
})

test_that("environ: -RenvironFile names the file read, and the R child gets it as R_ENVIRON_USER", {
  s <- ap_sandbox()
  other <- file.path(s$dir, "other.Renviron")
  writeLines("SAMPLETIDY_TIMEZONE=Other/Zone", other)
  writeLines("SAMPLETIDY_TIMEZONE=Default/Zone", s$environ)
  k <- ap_print_env(s, args = c("-PrintConfig", "-RenvironFile", other))
  expect_identical(k$vals[4], "Other/Zone")
  ap_ok(ap_run(s, args = c("-RenvironFile", other)))
  expect_identical(ap_lines(s$renv), other)
})

# ---- 14-16. running main from a detached worktree ------------------------------------------------------

ap_git <- function(repo, ...) {
  out <- suppressWarnings(system2("git", c("-C", shQuote(repo), "-c", "user.name=t", "-c", "user.email=t@example.invalid",
                                           "-c", "commit.gpgsign=false", ...), stdout = TRUE, stderr = TRUE))
  out
}

#' A fixture repo holding a copy of the trigger and a stub dev/auto-import.R, committed to
#' `main`, plus an uncommitted edit to the stub. The scripts under test run from the copy.
ap_fixture_repo <- function(s, branch = "main") {
  repo <- file.path(s$dir, "repo")
  dir.create(file.path(repo, "dev"), recursive = TRUE)
  file.copy(c(ap_dev("auto-import.ps1"), ap_dev("auto-import-gate.ps1")), file.path(repo, "dev"))
  writeLines("# v1", file.path(repo, "dev", "auto-import.R"))
  system2("git", c("-C", shQuote(repo), "init", "-q", "-b", branch))
  ap_git(repo, "add", "dev")
  ap_git(repo, "commit", "-q", "-m", "v1")
  writeLines("# dirty", file.path(repo, "dev", "auto-import.R"))
  s$script <- file.path(repo, "dev", "auto-import.ps1")
  s$repo <- repo
  s$run <- file.path(s$dir, "run tree")        # a path with a space, as the checkout may have
  s$gitlog <- file.path(s$dir, "git.log")
  s$git <- file.path(s$dir, "git-shim.sh")
  writeLines(c("#!/bin/bash", sprintf('echo "$*" >> "%s"', s$gitlog),
               sprintf('exec "%s" "$@"', Sys.which("git"))), s$git)
  Sys.chmod(s$git, "755")
  s
}
ap_wt_vars <- function(s, ...) ap_run(s, SAMPLETIDY_AUTOIMPORT_CODE = NA, SAMPLETIDY_AUTOIMPORT_RUN = s$run,
                                      SAMPLETIDY_AUTOIMPORT_GIT = s$git, ...)

test_that("worktree: main is checked out detached into RUN and the child runs RUN's dev/auto-import.R at main's sha", {
  s <- ap_fixture_repo(ap_sandbox())
  r <- ap_wt_vars(s)
  ap_ok(r)
  runs <- strsplit(ap_runs(s), "|", fixed = TRUE)
  expect_length(runs, 1L)
  expect_identical(normalizePath(runs[[1]][4]), normalizePath(file.path(s$run, "dev", "auto-import.R")))
  expect_identical(runs[[1]][5], "# v1")                       # the uncommitted edit is not seen
  sha <- ap_git(s$repo, "rev-parse", "main")
  expect_identical(ap_git(s$run, "rev-parse", "HEAD"), sha)
  expect_length(suppressWarnings(system2("git", c("-C", shQuote(s$run), "symbolic-ref", "-q", "HEAD"), stdout = TRUE, stderr = TRUE)), 0L)   # detached
  expect_match(ap_log(s), substr(sha, 1, 7), fixed = TRUE)    # the log names the short sha
})

test_that("worktree: a commit to main between ticks is picked up next tick, with no fetch or pull ever", {
  s <- ap_fixture_repo(ap_sandbox())
  ap_ok(ap_wt_vars(s))
  writeLines("# v2", file.path(s$repo, "dev", "auto-import.R"))
  ap_git(s$repo, "commit", "-q", "-am", "v2")
  writeLines("a new batch", file.path(s$input, "new.csv"))      # so the gate does not skip
  ap_ok(ap_wt_vars(s))
  runs <- strsplit(ap_runs(s), "|", fixed = TRUE)
  expect_length(runs, 2L)
  expect_identical(runs[[2]][5], "# v2")
  expect_identical(ap_git(s$run, "rev-parse", "HEAD"), ap_git(s$repo, "rev-parse", "main"))
  g <- ap_lines(s$gitlog)
  expect_gt(length(g), 0L)                                       # SAMPLETIDY_AUTOIMPORT_GIT was used
  expect_false(any(grepl("\\b(fetch|pull)\\b", g)), info = paste(g, collapse = "\n"))
})

test_that("worktree: with RUN unset it is LOCALAPPDATA/sampleTidy-run", {
  s <- ap_fixture_repo(ap_sandbox())
  ap_ok(ap_run(s, SAMPLETIDY_AUTOIMPORT_CODE = NA))
  expect_true(file.exists(file.path(s$lad, "sampleTidy-run", ".git")))
  expect_true(file.exists(file.path(s$lad, "sampleTidy-run", "dev", "auto-import.R")))
})

test_that("worktree: no `main` branch is logged, exits 1, writes no `running` health and does not start R", {
  s <- ap_fixture_repo(ap_sandbox(), branch = "trunk")
  r <- ap_wt_vars(s)
  expect_identical(r$status, 1L, info = ap_info(r))
  expect_length(ap_runs(s), 0L)
  expect_false(file.exists(ap_health_path(s)))
  expect_match(ap_log(s), "could not prepare", fixed = TRUE)
  expect_false(dir.exists(ap_lock(s)))
})

test_that("worktree: git missing is the same failure", {
  s <- ap_fixture_repo(ap_sandbox())
  r <- ap_run(s, SAMPLETIDY_AUTOIMPORT_CODE = NA, SAMPLETIDY_AUTOIMPORT_RUN = s$run,
              SAMPLETIDY_AUTOIMPORT_GIT = file.path(s$dir, "no-such-git"))
  expect_identical(r$status, 1L, info = ap_info(r))
  expect_length(ap_runs(s), 0L)
  expect_false(file.exists(ap_health_path(s)))
})

test_that("CODE set: the child runs CODE/dev/auto-import.R and git is never called", {
  s <- ap_fixture_repo(ap_sandbox())
  r <- ap_run(s, SAMPLETIDY_AUTOIMPORT_RUN = s$run, SAMPLETIDY_AUTOIMPORT_GIT = s$git)   # CODE stays at the sandbox's
  ap_ok(r)
  runs <- strsplit(ap_runs(s), "|", fixed = TRUE)
  expect_identical(normalizePath(runs[[1]][4]), normalizePath(file.path(s$code, "dev", "auto-import.R")))
  expect_false(file.exists(s$gitlog))
  expect_false(dir.exists(s$run))
})

# ---- 13b. R's ${VAR} forms in the environ file (helper-renviron-forms.R) -------------------------
# R expands ${VAR}, ${VAR-default} and ${VAR:-default}; both triggers must give the value R gives,
# and the same value as each other (found live: `KEY=${KEY-'path'}` was read as that literal text).

test_that("environ: ${VAR}, ${VAR-default} and ${VAR:-default} give the value R gives (NOTIFY), in the .ps1", {
  s <- ap_sandbox()
  for (f in rf_forms) {
    writeLines(paste0(rf_key, "=", f[[1]]), s$environ)
    k <- do.call(ap_print_env, c(list(s), as.list(rf_env(f[[2]]))))
    expect_identical(k$vals[6], f[[3]], info = sprintf("%s with VAR=%s", f[[1]], format(f[[2]])))
  }
})

test_that("environ: R's own `KEY=${KEY-'value'}` form works for every key the .ps1 reads from the file", {
  s <- ap_sandbox()
  mk <- function(k, v) sprintf("%s=${%s-'%s'}", k, k, v)
  writeLines(c(mk("SAMPLETIDY_INPUT_DIR", "/b c/input"), mk("SAMPLETIDY_REPORT_DIR", "/r d/rep"),
               mk("SAMPLETIDY_TIMEZONE", "Pacific/Auckland"), mk("SAMPLETIDY_NOTIFY_COMMAND", "/n o/notify"),
               mk("SAMPLETIDY_NOTIFY_FLUSH", "/n o/flush"), mk("SAMPLETIDY_GATE_WATCH", "/w x/watch")), s$environ)
  k <- ap_print_env(s)
  expect_identical(k$vals[2:4], c("/b c", "/r d/rep", "Pacific/Auckland"))
  expect_identical(k$vals[6:8], c("/n o/notify", "/n o/flush", "/w x/watch"))
})

test_that("environ: `KEY=${KEY-'value'}` with KEY already set in the process environment is that value", {
  s <- ap_sandbox()
  writeLines("SAMPLETIDY_NOTIFY_COMMAND=${SAMPLETIDY_NOTIFY_COMMAND-'/from/file'}", s$environ)
  expect_identical(ap_print_env(s, SAMPLETIDY_NOTIFY_COMMAND = "/from/env")$vals[6], "/from/env")
})

test_that("environ: a ${VAR} may name a key set on an earlier line of the same file, as in R", {
  s <- ap_sandbox()
  writeLines(c("SAMPLETIDY_REPORT_DIR=/r/rep", "SAMPLETIDY_NOTIFY_COMMAND=${SAMPLETIDY_REPORT_DIR}/notify"), s$environ)
  expect_identical(ap_print_env(s)$vals[6], "/r/rep/notify")
})

test_that("environ: the .sh and the .ps1 read every ${VAR} form to the same value, and it is R's", {
  s <- ap_sandbox()
  for (f in rf_forms) {
    writeLines(paste0(rf_key, "=", f[[1]]), s$environ)
    ev <- as.list(rf_env(f[[2]]))
    ps <- do.call(ap_print_env, c(list(s), ev))
    sh <- do.call(ap_print_env, c(list(s), ev, list(args = "--print-config", via = "sh")))
    expect_identical(sh$vals[6], ps$vals[6], info = sprintf("sh vs ps1: %s with VAR=%s", f[[1]], format(f[[2]])))
    expect_identical(sh$vals[6], f[[3]], info = sprintf("%s with VAR=%s", f[[1]], format(f[[2]])))
  }
})

# ---- 17. PLAN-21 d5: R's own data-dir rule, and scratch paths through the environ file ---------------------
# R's rule (tools::R_user_dir): R_USER_DATA_DIR, then XDG_DATA_HOME, then the platform default (Windows
# %APPDATA%\R\data, macOS ~/Library/Application Support/org.R-project.R, else ~/.local/share), then
# R/<package>. Both triggers compute it, so the DB and report defaults are where R itself keeps them.
# SAMPLETIDY_AUTOIMPORT_PLATFORM (Windows, Darwin, other) is the test seam for the platform.
# R reads the environ file before it looks at any of this, so a value in the file counts.

#' A full reset between ticks of one test: run records, and the report folder's gate, health and lock.
ap_clean <- function(s) {
  ap_reset(s)
  unlink(list.files(s$report, all.files = TRUE, full.names = TRUE, no.. = TRUE), recursive = TRUE)
  unlink(s$log)
}

ap_data_unset <- c(SAMPLETIDY_AUTOIMPORT_DB = NA, SAMPLETIDY_AUTOIMPORT_REPORT = NA)
ap_pc_args <- function(via) if (via == "sh") "--print-config" else "-PrintConfig"
ap_norm <- function(x) gsub("\\\\", "/", x)

#' The --print-config key/values of one trigger, with DB and REPORT left to their defaults.
ap_cfg <- function(s, via, ...) {
  r <- ap_run(s, c(ap_data_unset), ..., args = ap_pc_args(via), via = via)
  ap_ok(r)
  ap_kv(r)
}

#' What R itself gives as the data dir of sampleTidy: a child Rscript with the same HOME, environ
#' file and extra environment (the oracle).
ap_r_data_dir <- function(s, env = character()) {
  r <- processx::run(as.character(Sys.which("Rscript")),
                     c("-e", 'cat(tools::R_user_dir("sampleTidy", "data"))'),
                     env = c(HOME = s$home, PATH = "/usr/bin:/bin", R_ENVIRON_USER = s$environ,
                             R_PROFILE_USER = file.path(s$home, "none"), env),
                     error_on_status = FALSE, timeout = 60)
  expect_identical(r$status, 0L, info = r$stderr)
  r$stdout
}

test_that("data dir: on macOS both triggers default to where R_user_dir puts it, in every precedence case", {
  skip_if_not(Sys.info()[["sysname"]] == "Darwin", "the oracle's default is the macOS one")
  skip_if(Sys.which("Rscript") == "", "no Rscript")
  s <- ap_sandbox()
  rud <- file.path(s$dir, "rud"); xdg <- file.path(s$dir, "xdg")
  cases <- list(
    none = list(env = character(), file = NULL),
    r_user = list(env = c(R_USER_DATA_DIR = rud), file = NULL),
    xdg = list(env = c(XDG_DATA_HOME = xdg), file = NULL),
    both = list(env = c(R_USER_DATA_DIR = rud, XDG_DATA_HOME = xdg), file = NULL),
    file_only = list(env = character(), file = sprintf("R_USER_DATA_DIR=%s", rud)))
  for (nm in names(cases)) {
    cs <- cases[[nm]]
    writeLines(if (is.null(cs$file)) character() else cs$file, s$environ)
    want <- ap_r_data_dir(s, cs$env)
    for (via in c("sh", "ps1")) {
      k <- do.call(ap_cfg, c(list(s, via, SAMPLETIDY_AUTOIMPORT_PLATFORM = "Darwin"), as.list(cs$env)))
      expect_identical(ap_norm(k$vals[1]), file.path(want, "monitoring.duckdb"), info = paste(nm, via, "DB"))
      expect_identical(ap_norm(k$vals[3]), file.path(want, "reports"), info = paste(nm, via, "REPORT"))
    }
  }
})

test_that("data dir: the Darwin and 'other' defaults, and R_USER_DATA_DIR beating XDG_DATA_HOME, in both triggers", {
  s <- ap_sandbox()
  for (via in c("sh", "ps1")) {
    k <- ap_cfg(s, via, SAMPLETIDY_AUTOIMPORT_PLATFORM = "Darwin")
    expect_identical(ap_norm(k$vals[1]), file.path(s$home, "Library", "Application Support", "org.R-project.R", "R", "sampleTidy", "monitoring.duckdb"), info = via)
    k <- ap_cfg(s, via, SAMPLETIDY_AUTOIMPORT_PLATFORM = "Linux")
    expect_identical(ap_norm(k$vals[1]), file.path(s$home, ".local", "share", "R", "sampleTidy", "monitoring.duckdb"), info = via)
    expect_identical(ap_norm(k$vals[3]), file.path(s$home, ".local", "share", "R", "sampleTidy", "reports"), info = via)
    k <- ap_cfg(s, via, SAMPLETIDY_AUTOIMPORT_PLATFORM = "Linux", XDG_DATA_HOME = file.path(s$dir, "xdg"))
    expect_identical(ap_norm(k$vals[1]), file.path(s$dir, "xdg", "R", "sampleTidy", "monitoring.duckdb"), info = via)
    k <- ap_cfg(s, via, SAMPLETIDY_AUTOIMPORT_PLATFORM = "Linux", XDG_DATA_HOME = file.path(s$dir, "xdg"),
                R_USER_DATA_DIR = file.path(s$dir, "rud"))
    expect_identical(ap_norm(k$vals[1]), file.path(s$dir, "rud", "R", "sampleTidy", "monitoring.duckdb"), info = via)
  }
})

test_that("data dir, Windows branch (.ps1): APPDATA\\R\\data\\R\\sampleTidy, not LOCALAPPDATA; R_USER_DATA_DIR beats it", {
  s <- ap_sandbox()
  A <- file.path(s$dir, "roaming")
  k <- ap_cfg(s, "ps1", SAMPLETIDY_AUTOIMPORT_PLATFORM = "Windows", APPDATA = A)
  expect_identical(ap_norm(k$vals[1]), file.path(A, "R", "data", "R", "sampleTidy", "monitoring.duckdb"))
  expect_identical(ap_norm(k$vals[3]), file.path(A, "R", "data", "R", "sampleTidy", "reports"))
  k <- ap_cfg(s, "ps1", SAMPLETIDY_AUTOIMPORT_PLATFORM = "Windows", APPDATA = A, R_USER_DATA_DIR = file.path(s$dir, "rud"))
  expect_identical(ap_norm(k$vals[1]), file.path(s$dir, "rud", "R", "sampleTidy", "monitoring.duckdb"))
  k <- ap_cfg(s, "ps1", SAMPLETIDY_AUTOIMPORT_PLATFORM = "Windows", APPDATA = A, XDG_DATA_HOME = file.path(s$dir, "xdg"))
  expect_identical(ap_norm(k$vals[1]), file.path(s$dir, "xdg", "R", "sampleTidy", "monitoring.duckdb"))
})

test_that("data dir, Windows with APPDATA unset: DB is empty, and a tick exits 0 with no log and R not run", {
  s <- ap_sandbox()
  # a DB at the old LOCALAPPDATA default would make the tick run, were it still looked at
  old <- file.path(s$lad, "R", "data", "R", "sampleTidy")
  dir.create(old, recursive = TRUE); writeLines("x", file.path(old, "monitoring.duckdb"))
  k <- ap_cfg(s, "ps1", SAMPLETIDY_AUTOIMPORT_PLATFORM = "Windows", APPDATA = NA)
  expect_identical(k$lines[1], "DB=")
  r <- ap_run(s, c(ap_data_unset), SAMPLETIDY_AUTOIMPORT_PLATFORM = "Windows", APPDATA = NA)
  ap_ok(r)
  expect_length(ap_runs(s), 0L)
  expect_false(file.exists(s$log))
})

test_that("DB: SAMPLETIDY_LIVE_DB (env, then the environ file) names it; AUTOIMPORT_DB in the env beats both; in the file it is ignored", {
  s <- ap_sandbox()
  fdb <- file.path(s$dir, "from-file", "live.duckdb"); edb <- file.path(s$dir, "from-env", "live.duckdb")
  adb <- file.path(s$dir, "override", "x.duckdb")
  dflt <- file.path(s$home, "Library", "Application Support", "org.R-project.R", "R", "sampleTidy", "monitoring.duckdb")
  for (via in c("sh", "ps1")) {
    writeLines(sprintf("SAMPLETIDY_LIVE_DB=%s", fdb), s$environ)
    k <- ap_cfg(s, via, SAMPLETIDY_AUTOIMPORT_PLATFORM = "Darwin")
    expect_identical(ap_norm(k$vals[1]), fdb, info = paste(via, "file"))
    k <- ap_cfg(s, via, SAMPLETIDY_AUTOIMPORT_PLATFORM = "Darwin", SAMPLETIDY_LIVE_DB = edb)
    expect_identical(ap_norm(k$vals[1]), edb, info = paste(via, "env beats file"))
    k <- ap_cfg(s, via, SAMPLETIDY_AUTOIMPORT_PLATFORM = "Darwin", SAMPLETIDY_AUTOIMPORT_DB = adb, SAMPLETIDY_LIVE_DB = edb)
    expect_identical(ap_norm(k$vals[1]), adb, info = paste(via, "AUTOIMPORT_DB beats LIVE_DB"))
    writeLines(sprintf("SAMPLETIDY_AUTOIMPORT_DB=%s", adb), s$environ)
    k <- ap_cfg(s, via, SAMPLETIDY_AUTOIMPORT_PLATFORM = "Darwin")
    expect_identical(ap_norm(k$vals[1]), dflt, info = paste(via, "AUTOIMPORT_DB in the file is ignored"))
  }
})

test_that("DB: SAMPLETIDY_LIVE_DB in the environ file decides whether the tick is the writer", {
  s <- ap_sandbox()
  for (via in c("sh", "ps1")) {
    ap_clean(s)
    writeLines(sprintf("SAMPLETIDY_LIVE_DB=%s", s$db), s$environ)
    ap_ok(ap_run(s, c(ap_data_unset), SAMPLETIDY_AUTOIMPORT_PLATFORM = "Darwin", via = via))
    expect_length(ap_runs(s), 1L)
    ap_clean(s)
    writeLines(sprintf("SAMPLETIDY_LIVE_DB=%s", file.path(s$dir, "no-such.duckdb")), s$environ)
    ap_ok(ap_run(s, c(ap_data_unset), SAMPLETIDY_AUTOIMPORT_PLATFORM = "Darwin", via = via))
    expect_length(ap_runs(s), 0L)
  }
})

test_that("LOG in the environ file is printed and written to; the process env beats it", {
  s <- ap_sandbox()
  flog <- file.path(s$dir, "flog", "file.log"); elog <- file.path(s$dir, "elog", "env.log")
  for (via in c("sh", "ps1")) {
    ap_clean(s); unlink(dirname(flog), recursive = TRUE); unlink(dirname(elog), recursive = TRUE)
    writeLines(sprintf("SAMPLETIDY_AUTOIMPORT_LOG=%s", flog), s$environ)
    k <- ap_cfg(s, via, SAMPLETIDY_AUTOIMPORT_LOG = NA)
    expect_identical(ap_norm(k$vals[5]), flog, info = via)
    ap_ok(ap_run(s, SAMPLETIDY_AUTOIMPORT_LOG = NA, via = via))
    expect_true(file.exists(flog), info = paste(via, "the log is written where the file says"))
    expect_gt(length(ap_lines(flog)), 0L)
    k <- ap_cfg(s, via, SAMPLETIDY_AUTOIMPORT_LOG = elog)
    expect_identical(ap_norm(k$vals[5]), elog, info = paste(via, "env beats file"))
  }
})

test_that("OFF in the environ file pauses; the process env beats it", {
  s <- ap_sandbox()
  foff <- file.path(s$dir, "file-off")
  for (via in c("sh", "ps1")) {
    writeLines(sprintf("SAMPLETIDY_AUTOIMPORT_OFF=%s", foff), s$environ)
    ap_clean(s); unlink(foff)
    ap_ok(ap_run(s, SAMPLETIDY_AUTOIMPORT_OFF = NA, via = via))
    expect_length(ap_runs(s), 1L)                                       # the file's pause file is absent: it runs
    writeLines("holder", foff)
    ap_clean(s)
    ap_ok(ap_run(s, SAMPLETIDY_AUTOIMPORT_OFF = NA, via = via))
    expect_length(ap_runs(s), 0L)                                       # present: paused
    ap_clean(s)
    ap_ok(ap_run(s, SAMPLETIDY_AUTOIMPORT_OFF = file.path(s$dir, "other-off"), via = via))
    expect_length(ap_runs(s), 1L)                                       # the env names another file: it wins
  }
})

#' The fixture repo of section 14 with the .sh copied in beside the .ps1, so the worktree is made from
#' the fixture and never from the real checkout. Returns a function running either trigger from it.
ap_fixture_both <- function(s) {
  s <- ap_fixture_repo(s)
  file.copy(ap_dev("auto-import.sh"), file.path(s$repo, "dev", "auto-import.sh"))
  s
}
ap_run_fixture <- function(s, via, ...) {
  v <- ap_env(s, c(SAMPLETIDY_AUTOIMPORT_CODE = NA, SAMPLETIDY_AUTOIMPORT_RUN = NA), ..., via = via)
  if (via == "sh") processx::run("bash", file.path(s$repo, "dev", "auto-import.sh"), env = v, error_on_status = FALSE, timeout = 90)
  else processx::run(as.character(Sys.which("pwsh")), c("-NoProfile", "-File", s$script), env = v, error_on_status = FALSE, timeout = 90)
}

test_that("RUN in the environ file is where main's worktree is made (CODE unset); the process env beats it", {
  s <- ap_fixture_both(ap_sandbox())
  for (via in c("sh", "ps1")) {
    ap_clean(s)
    frun <- file.path(s$dir, paste0("file-run-", via)); erun <- file.path(s$dir, paste0("env-run-", via))
    unlink(c(frun, erun), recursive = TRUE)
    writeLines(sprintf("SAMPLETIDY_AUTOIMPORT_RUN=%s", frun), s$environ)
    r <- ap_run_fixture(s, via)
    ap_ok(r)
    expect_true(file.exists(file.path(frun, ".git")), info = paste(via, ap_info(r)))
    expect_true(file.exists(file.path(frun, "dev", "auto-import.R")), info = via)
    expect_true(any(grepl(file.path(frun, "dev", "auto-import.R"), ap_runs(s), fixed = TRUE)), info = via)
    # the env beats the file
    ap_clean(s)
    writeLines("a new batch", file.path(s$input, paste0("new-", via, ".csv")))
    ap_ok(ap_run_fixture(s, via, SAMPLETIDY_AUTOIMPORT_RUN = erun))
    expect_true(file.exists(file.path(erun, ".git")), info = paste(via, "env"))
  }
  expect_false(dir.exists(file.path(s$home, ".local", "share", "sampleTidy-run")))   # the .sh's old fixed place
})
