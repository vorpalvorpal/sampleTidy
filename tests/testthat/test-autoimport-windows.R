# The Windows hourly trigger, dev/auto-import.ps1 (PowerShell 7), at parity with
# the Mac's dev/auto-import.sh. All logic lives in the .ps1 so it is testable
# under pwsh on any machine; dev/auto-import.cmd is a thin Task Scheduler shim
# that forwards to it (those tests run on Windows only).
#
# What is covered: -PrintConfig / --print-config; the resolution table; the
# writer-machine, pause-file, input-folder and log-folder rules (bug 1: a missing
# custom log folder); the atomic lock (R-22.H); the gate; the child environment;
# the exit code (rc 3 passes through); the gate write; and bug 2 (an RSCRIPT that
# is a .cmd file must hand control back).
#
# ISOLATION. These tests also run on a work laptop. Every path the script can
# touch (DB, input, report dir, log, pause file, LOCALAPPDATA, HOME) is inside a
# temp dir, and SAMPLETIDY_AUTOIMPORT_OFF is always set to a sandbox path except
# in the one default-path test (skipped on Windows, where pwsh's $HOME cannot be
# redirected). Off Windows the child gets a CLEAN environment; on Windows a clean
# environment breaks pwsh and cmd, so the current one is used with every
# SAMPLETIDY_* variable and R_ENVIRON_USER blanked (empty counts as unset).
# No test starts a real R child: RSCRIPT is always a stub.

# ---- helpers -------------------------------------------------------------------------------

aw_is_win <- function() .Platform$OS.type == "windows"

# The dev folder exists even when the script does not, so a missing script FAILS
# (aw_run asserts it) rather than skipping.
aw_dev <- function(...) file.path(normalizePath(testthat::test_path("..", "..", "dev"), mustWork = TRUE), ...)

aw_skip <- function() skip_if(Sys.which("pwsh") == "", "no pwsh")

# Compare paths regardless of slash direction.
aw_norm <- function(x) gsub("\\\\", "/", x)

# Variables blanked on Windows unless a test sets them.
aw_blank_vars <- c("SAMPLETIDY_AUTOIMPORT_DB", "SAMPLETIDY_AUTOIMPORT_INPUT",
                   "SAMPLETIDY_AUTOIMPORT_REPORT", "SAMPLETIDY_AUTOIMPORT_RSCRIPT",
                   "SAMPLETIDY_AUTOIMPORT_LOG", "SAMPLETIDY_AUTOIMPORT_OFF",
                   "SAMPLETIDY_AUTOIMPORT_CODE", "SAMPLETIDY_AUTOIMPORT_NOTIFY",
                   "SAMPLETIDY_AUTOIMPORT_STALE_HOURS", "SAMPLETIDY_INPUT_DIR",
                   "SAMPLETIDY_REPORT_DIR", "SAMPLETIDY_TIMEZONE", "SAMPLETIDY_GATE_WATCH",
                   "R_ENVIRON_USER")

#' A stub RSCRIPT (the script argument is auto-import.R). It records
#' `run|REPORT|INPUT|DB|lock-held|arg1` in runs, prints to stdout and stderr,
#' optionally sleeps, and exits `rc`.
aw_stub <- function(s, rc = 0L, sleep = 0L) {
  if (aw_is_win()) {
    lines <- c("@echo off",
               "set LOCKED=no",
               'if exist "%SAMPLETIDY_AUTOIMPORT_REPORT%\\.imports.lock\\pid" set LOCKED=yes',
               sprintf('>>"%s" echo run^|%%SAMPLETIDY_AUTOIMPORT_REPORT%%^|%%SAMPLETIDY_AUTOIMPORT_INPUT%%^|%%SAMPLETIDY_AUTOIMPORT_DB%%^|%%LOCKED%%^|%%~1', s$runs),
               "echo stub stdout line",
               "echo stub stderr line 1>&2",
               if (sleep > 0) sprintf("ping -n %d 127.0.0.1 >nul", sleep + 1L),
               sprintf("exit /b %d", rc))
    writeLines(lines, s$rscript, sep = "\r\n")
  } else {
    lines <- c("#!/bin/bash",
               'locked=no; [ -f "$SAMPLETIDY_AUTOIMPORT_REPORT/.imports.lock/pid" ] && locked=yes',
               sprintf('echo "run|$SAMPLETIDY_AUTOIMPORT_REPORT|$SAMPLETIDY_AUTOIMPORT_INPUT|$SAMPLETIDY_AUTOIMPORT_DB|$locked|$1" >> "%s"', s$runs),
               "echo stub stdout line",
               "echo stub stderr line >&2",
               if (sleep > 0) sprintf("sleep %d", sleep),
               sprintf("exit %d", rc))
    writeLines(lines, s$rscript)
    Sys.chmod(s$rscript, "755")
  }
  invisible(s)
}

#' A sandbox: DB, input folder with one file, report dir (NOT created), log,
#' pause file path (NOT created), LOCALAPPDATA, HOME and a stub RSCRIPT.
aw_sandbox <- function(env = parent.frame(), rc = 0L, sleep = 0L) {
  aw_skip()
  d <- normalizePath(withr::local_tempdir(.local_envir = env))
  s <- list(dir = d, home = file.path(d, "home"), lad = file.path(d, "localappdata"),
            db = file.path(d, "monitoring.duckdb"), input = file.path(d, "assets"),
            report = file.path(d, "reports"), log = file.path(d, "logs", "ai.log"),
            off = file.path(d, "off"), runs = file.path(d, "runs.txt"),
            rscript = file.path(d, if (aw_is_win()) "stub-rscript.cmd" else "stub-rscript.sh"))
  for (p in c(s$home, s$lad, s$input)) dir.create(p, recursive = TRUE)
  writeLines("x", s$db)
  writeLines("x", file.path(s$input, "README.txt"))
  aw_stub(s, rc, sleep)
  s
}

#' The usual variables of a sandboxed run; `...` overrides (NA = leave unset).
aw_std <- function(s, ...) {
  v <- c(SAMPLETIDY_AUTOIMPORT_DB = s$db, SAMPLETIDY_AUTOIMPORT_INPUT = s$input,
         SAMPLETIDY_AUTOIMPORT_REPORT = s$report, SAMPLETIDY_AUTOIMPORT_RSCRIPT = s$rscript,
         SAMPLETIDY_AUTOIMPORT_LOG = s$log)
  over <- c(...)
  if (length(over)) v <- c(v[setdiff(names(v), names(over))], over)
  v
}

#' The full child environment. `vars` is the named vector a test sets (NA =
#' unset). OFF and LOCALAPPDATA default to sandbox paths.
aw_full_env <- function(s, vars) {
  defaults <- c(SAMPLETIDY_AUTOIMPORT_OFF = s$off, LOCALAPPDATA = s$lad)
  vars <- c(vars, defaults[setdiff(names(defaults), names(vars))])
  if (aw_is_win()) {
    vars[is.na(vars)] <- ""
    blank <- setNames(rep("", length(aw_blank_vars)), aw_blank_vars)
    blank <- blank[setdiff(names(blank), names(vars))]
    c("current", blank, vars)
  } else {
    vars <- vars[!is.na(vars)]
    pw <- dirname(Sys.which("pwsh"))
    base <- c(HOME = s$home, PATH = paste(c("/usr/bin", "/bin", pw), collapse = ":"),
              POWERSHELL_TELEMETRY_OPTOUT = "1", DOTNET_CLI_TELEMETRY_OPTOUT = "1",
              LOCALAPPDATA = s$lad)
    c(base[setdiff(names(base), names(vars))], vars)
  }
}

aw_args <- function(args, via) {
  if (via == "cmd") {
    list(cmd = "cmd.exe", args = c("/c", aw_dev("auto-import.cmd"), args))
  } else {
    list(cmd = as.character(Sys.which("pwsh")),
         args = c("-NoProfile", "-File", aw_dev("auto-import.ps1"), args))
  }
}

#' Run the trigger (via the .ps1 under pwsh, or the .cmd shim on Windows).
aw_run <- function(s, args = character(), vars = aw_std(s), via = c("ps1", "cmd")) {
  via <- match.arg(via)
  expect_true(file.exists(aw_dev("auto-import.ps1")), info = "dev/auto-import.ps1 exists")
  a <- aw_args(args, via)
  processx::run(a$cmd, a$args, env = aw_full_env(s, vars), error_on_status = FALSE, timeout = 60)
}

#' Start the trigger without waiting (concurrency test).
aw_start <- function(s, vars = aw_std(s), env = parent.frame()) {
  a <- aw_args(character(), "ps1")
  p <- processx::process$new(a$cmd, a$args, env = aw_full_env(s, vars), stdout = "|", stderr = "|")
  withr::defer(if (p$is_alive()) p$kill(), envir = env)
  p
}

aw_lines <- function(path) if (file.exists(path)) readLines(path, warn = FALSE) else character()
aw_runs <- function(s) strsplit(aw_lines(s$runs), "|", fixed = TRUE)
aw_log <- function(s) paste(aw_lines(s$log), collapse = "\n")
aw_lock <- function(s) file.path(s$report, ".imports.lock")
aw_gate <- function(s) file.path(s$report, ".imports.gate")
aw_state <- function(s) file.path(s$report, ".imports.state")

#' `--print-config` / `-PrintConfig` output as a named list.
aw_kv <- function(r) {
  out <- strsplit(r$stdout, "\r?\n")[[1]]
  out <- out[nzchar(out)]
  list(lines = out, keys = sub("=.*$", "", out), vals = sub("^[^=]*=", "", out))
}

aw_print <- function(s, vars, args = "-PrintConfig") {
  r <- aw_run(s, args, vars)
  expect_identical(r$status, 0L, info = paste(r$stdout, r$stderr))
  aw_kv(r)
}

#' A held lock in the report dir with `pid` (NULL: no pid file); `age_h` hours old.
aw_make_lock <- function(s, pid, age_h = 0) {
  dir.create(s$report, recursive = TRUE, showWarnings = FALSE)
  dir.create(aw_lock(s))
  if (!is.null(pid)) writeLines(as.character(pid), file.path(aw_lock(s), "pid"))
  if (age_h > 0) Sys.setFileTime(aw_lock(s), Sys.time() - age_h * 3600)   # AFTER writing pid
}

#' One good run, so a gate exists; then the state says nothing is pending and the runs file is reset.
aw_prime <- function(s) {
  r <- aw_run(s)
  expect_identical(r$status, 0L, info = paste(r$stdout, r$stderr))
  expect_length(aw_runs(s), 1L)
  writeLines('{"pending": false}', aw_state(s))
  file.remove(s$runs)
}

# ---- 1. print config ------------------------------------------------------------------------

# PLAN-21 phase (a): WATCH (SAMPLETIDY_GATE_WATCH, empty when unset) is printed last.
test_that("-PrintConfig prints exactly DB, INPUT, REPORT, TIMEZONE, LOG, WATCH in order and exits 0", {
  s <- aw_sandbox()
  k <- aw_print(s, aw_std(s, SAMPLETIDY_TIMEZONE = "Pacific/Kiritimati"))
  expect_identical(k$keys, c("DB", "INPUT", "REPORT", "TIMEZONE", "LOG", "WATCH"))
  expect_identical(aw_norm(k$vals), aw_norm(c(s$db, s$input, s$report, "Pacific/Kiritimati", s$log, "")))
})

test_that("--print-config (the Mac spelling) prints the same six lines", {
  s <- aw_sandbox()
  v <- aw_std(s, SAMPLETIDY_TIMEZONE = "Pacific/Kiritimati")
  a <- aw_print(s, v, "-PrintConfig")
  b <- aw_print(s, v, "--print-config")
  expect_length(b$lines, 6L)
  expect_identical(b$lines, a$lines)
})

test_that("print config has no side effects and works with no DB, a pause file and a held lock", {
  s <- aw_sandbox()
  file.remove(s$db)
  writeLines(c("agent-a", "agent-b"), s$off)
  aw_make_lock(s, 999999)
  before <- readBin(file.path(aw_lock(s), "pid"), "raw", 100)
  for (a in c("-PrintConfig", "--print-config")) {
    k <- aw_print(s, aw_std(s), a)
    expect_length(k$lines, 6L)
  }
  expect_false(dir.exists(dirname(s$log)))
  expect_false(file.exists(s$log))
  expect_false(file.exists(s$runs))
  expect_false(file.exists(aw_gate(s)))
  expect_true(dir.exists(aw_lock(s)))
  expect_identical(readBin(file.path(aw_lock(s), "pid"), "raw", 100), before)
})

test_that("print config creates no log folder or report folder", {
  s <- aw_sandbox()
  aw_print(s, aw_std(s))
  expect_false(dir.exists(s$report))
  expect_false(dir.exists(dirname(s$log)))
})

# ---- 2. resolution ---------------------------------------------------------------------------

test_that("AUTOIMPORT_REPORT beats SAMPLETIDY_REPORT_DIR, which beats the LOCALAPPDATA default", {
  s <- aw_sandbox()
  other <- file.path(s$dir, "other-reports")
  k <- aw_print(s, aw_std(s, SAMPLETIDY_REPORT_DIR = other))
  expect_identical(aw_norm(k$vals[3]), aw_norm(s$report))
  k <- aw_print(s, aw_std(s, SAMPLETIDY_AUTOIMPORT_REPORT = NA, SAMPLETIDY_REPORT_DIR = other))
  expect_identical(aw_norm(k$vals[3]), aw_norm(other))
  k <- aw_print(s, aw_std(s, SAMPLETIDY_AUTOIMPORT_REPORT = NA))
  expect_identical(aw_norm(k$vals[3]), aw_norm(file.path(s$lad, "R", "data", "R", "sampleTidy", "reports")))
})

test_that("INPUT_DIR named `input` resolves to its parent; any other name is used verbatim", {
  s <- aw_sandbox()
  batches <- file.path(s$dir, "batches")
  k <- aw_print(s, aw_std(s, SAMPLETIDY_AUTOIMPORT_INPUT = NA, SAMPLETIDY_INPUT_DIR = file.path(batches, "input")))
  expect_identical(aw_norm(k$vals[2]), aw_norm(batches))
  k <- aw_print(s, aw_std(s, SAMPLETIDY_AUTOIMPORT_INPUT = NA, SAMPLETIDY_INPUT_DIR = file.path(batches, "inputs")))
  expect_identical(aw_norm(k$vals[2]), aw_norm(file.path(batches, "inputs")))
  k <- aw_print(s, aw_std(s, SAMPLETIDY_AUTOIMPORT_INPUT = NA, SAMPLETIDY_INPUT_DIR = file.path(batches, "my-input")))
  expect_identical(aw_norm(k$vals[2]), aw_norm(file.path(batches, "my-input")))
})

test_that("AUTOIMPORT_INPUT is used verbatim, even when named `input`, and beats INPUT_DIR", {
  s <- aw_sandbox()
  verb <- file.path(s$dir, "batches", "input")
  k <- aw_print(s, aw_std(s, SAMPLETIDY_AUTOIMPORT_INPUT = verb,
                          SAMPLETIDY_INPUT_DIR = file.path(s$dir, "elsewhere", "input")))
  expect_identical(aw_norm(k$vals[2]), aw_norm(verb))
})

test_that("INPUT is empty when neither variable is set", {
  s <- aw_sandbox()
  k <- aw_print(s, aw_std(s, SAMPLETIDY_AUTOIMPORT_INPUT = NA))
  expect_identical(k$lines[2], "INPUT=")
})

test_that("TIMEZONE defaults to UTC, and the DB and LOG default under LOCALAPPDATA", {
  s <- aw_sandbox()
  k <- aw_print(s, aw_std(s, SAMPLETIDY_AUTOIMPORT_DB = NA, SAMPLETIDY_AUTOIMPORT_LOG = NA))
  expect_identical(k$vals[4], "UTC")
  expect_identical(aw_norm(k$vals[1]), aw_norm(file.path(s$lad, "R", "data", "R", "sampleTidy", "monitoring.duckdb")))
  expect_identical(aw_norm(k$vals[5]), aw_norm(file.path(s$lad, "sampleTidy", "autoimport.log")))
})

test_that("empty environment values count as unset", {
  s <- aw_sandbox()
  k <- aw_print(s, aw_std(s, SAMPLETIDY_AUTOIMPORT_REPORT = "", SAMPLETIDY_TIMEZONE = "",
                          SAMPLETIDY_AUTOIMPORT_LOG = ""))
  expect_identical(k$vals[4], "UTC")
  expect_identical(aw_norm(k$vals[3]), aw_norm(file.path(s$lad, "R", "data", "R", "sampleTidy", "reports")))
  expect_identical(aw_norm(k$vals[5]), aw_norm(file.path(s$lad, "sampleTidy", "autoimport.log")))
})

# ---- 3. not the writer machine, pause file, log folder, input -------------------------------

test_that("with no DB the script exits 0 silently: nothing created, stub not run", {
  s <- aw_sandbox()
  file.remove(s$db)
  r <- aw_run(s)
  expect_identical(r$status, 0L, info = paste(r$stdout, r$stderr))
  expect_length(aw_runs(s), 0L)
  expect_false(dir.exists(s$report))
  expect_false(dir.exists(dirname(s$log)))
})

test_that("a non-empty pause file (a line per holder) pauses: no run, no lock, no log, file untouched", {
  s <- aw_sandbox()
  writeLines(c("task-one", "task-two"), s$off)
  before <- readBin(s$off, "raw", 1000)
  r <- aw_run(s)
  expect_identical(r$status, 0L, info = paste(r$stdout, r$stderr))
  expect_length(aw_runs(s), 0L)
  expect_false(dir.exists(aw_lock(s)))
  expect_false(file.exists(s$log))
  expect_false(file.exists(aw_gate(s)))
  expect_true(file.exists(s$off))
  expect_identical(readBin(s$off, "raw", 1000), before)
})

test_that("an EMPTY pause file also pauses (existence is what counts)", {
  s <- aw_sandbox()
  file.create(s$off)
  r <- aw_run(s)
  expect_identical(r$status, 0L, info = paste(r$stdout, r$stderr))
  expect_length(aw_runs(s), 0L)
  expect_false(file.exists(s$log))
  expect_true(file.exists(s$off))
})

test_that("with no pause file the script runs", {
  s <- aw_sandbox()
  r <- aw_run(s)
  expect_identical(r$status, 0L, info = paste(r$stdout, r$stderr))
  expect_length(aw_runs(s), 1L)
})

test_that("the default pause file is $HOME/.sampletidy-autoimport-off", {
  skip_on_os("windows")   # pwsh's $HOME there cannot be redirected: never touch the real home
  s <- aw_sandbox()
  v <- aw_std(s, SAMPLETIDY_AUTOIMPORT_OFF = NA)
  r <- aw_run(s, vars = v)
  expect_length(aw_runs(s), 1L)          # control: no file, it runs
  file.remove(s$runs)
  writeLines("holder", file.path(s$home, ".sampletidy-autoimport-off"))
  r <- aw_run(s, vars = v)
  expect_identical(r$status, 0L, info = paste(r$stdout, r$stderr))
  expect_length(aw_runs(s), 0L)
})

test_that("bug 1: a custom LOG several levels deep in missing folders is created", {
  s <- aw_sandbox()
  deep <- file.path(s$dir, "l1", "l2", "l3", "l4", "deep.log")
  r <- aw_run(s, vars = aw_std(s, SAMPLETIDY_AUTOIMPORT_LOG = deep))
  expect_identical(r$status, 0L, info = paste(r$stdout, r$stderr))
  expect_true(file.exists(deep))
  expect_match(paste(aw_lines(deep), collapse = "\n"), "auto-import start", fixed = TRUE)
})

test_that("log lines have the Mac form `=== yyyy-MM-dd HH:mm:ss message`", {
  s <- aw_sandbox()
  aw_run(s)
  expect_match(aw_lines(s$log), "^=== \\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2} auto-import start", all = FALSE)
})

test_that("a missing input folder logs `input folder not found`, exits 0 and does not run the stub", {
  s <- aw_sandbox()
  r <- aw_run(s, vars = aw_std(s, SAMPLETIDY_AUTOIMPORT_INPUT = file.path(s$dir, "no-such-folder")))
  expect_identical(r$status, 0L, info = paste(r$stdout, r$stderr))
  expect_match(aw_log(s), "input folder not found", fixed = TRUE)
  expect_length(aw_runs(s), 0L)
})

test_that("an empty INPUT (nothing configured) is also `input folder not found`", {
  s <- aw_sandbox()
  r <- aw_run(s, vars = aw_std(s, SAMPLETIDY_AUTOIMPORT_INPUT = NA))
  expect_identical(r$status, 0L, info = paste(r$stdout, r$stderr))
  expect_match(aw_log(s), "input folder not found", fixed = TRUE)
  expect_length(aw_runs(s), 0L)
})

test_that("the report folder is created when missing", {
  s <- aw_sandbox()
  aw_run(s)
  expect_true(dir.exists(s$report))
})

# ---- 4. lock (R-22.H) -----------------------------------------------------------------------

test_that("R-22.H: the lock is held while RSCRIPT runs and gone after success", {
  s <- aw_sandbox()
  r <- aw_run(s)
  expect_identical(r$status, 0L, info = paste(r$stdout, r$stderr))
  run <- aw_runs(s)[[1]]
  expect_identical(run[5], "yes")
  expect_false(dir.exists(aw_lock(s)))
})

test_that("R-22.H: the lock is released after rc 1 and after rc 3", {
  for (rc in c(1L, 3L)) {
    s <- aw_sandbox(rc = rc)
    r <- aw_run(s)
    expect_identical(r$status, rc, info = paste(r$stdout, r$stderr))
    expect_false(dir.exists(aw_lock(s)), info = paste("rc", rc))
  }
})

test_that("R-22.H: the lock is released when the gate skips the run", {
  s <- aw_sandbox()
  aw_prime(s)
  r <- aw_run(s)
  expect_identical(r$status, 0L, info = paste(r$stdout, r$stderr))
  expect_length(aw_runs(s), 0L)
  expect_false(dir.exists(aw_lock(s)))
})

test_that("R-22.H: a lock whose PID is dead is taken over, logged, and the run proceeds", {
  s <- aw_sandbox()
  aw_make_lock(s, 999999)
  r <- aw_run(s)
  expect_identical(r$status, 0L, info = paste(r$stdout, r$stderr))
  expect_length(aw_runs(s), 1L)
  expect_match(aw_log(s), "took over a stale lock", fixed = TRUE)
  expect_false(dir.exists(aw_lock(s)))
})

test_that("R-22.H: a lock older than 120 minutes is taken over even though its PID is alive", {
  s <- aw_sandbox()
  aw_make_lock(s, Sys.getpid(), age_h = 3)
  r <- aw_run(s)
  expect_identical(r$status, 0L, info = paste(r$stdout, r$stderr))
  expect_length(aw_runs(s), 1L)
  expect_match(aw_log(s), "took over a stale lock", fixed = TRUE)
})

test_that("R-22.H: a fresh lock held by a live PID is respected and left untouched", {
  s <- aw_sandbox()
  aw_make_lock(s, Sys.getpid())
  pidfile <- file.path(aw_lock(s), "pid")
  before <- readBin(pidfile, "raw", 100)
  r <- aw_run(s)
  expect_identical(r$status, 0L, info = paste(r$stdout, r$stderr))
  expect_length(aw_runs(s), 0L)
  expect_match(aw_log(s), "already in progress", fixed = TRUE)
  expect_true(dir.exists(aw_lock(s)))
  expect_true(file.exists(pidfile))
  expect_identical(readBin(pidfile, "raw", 100), before)
})

test_that("R-22.H: a lock with no pid file is stale only by age", {
  s <- aw_sandbox()
  aw_make_lock(s, NULL)                      # fresh, no pid: respected
  r <- aw_run(s)
  expect_identical(r$status, 0L, info = paste(r$stdout, r$stderr))
  expect_length(aw_runs(s), 0L)
  expect_match(aw_log(s), "already in progress", fixed = TRUE)
  expect_true(dir.exists(aw_lock(s)))
  Sys.setFileTime(aw_lock(s), Sys.time() - 3 * 3600)   # now old: taken over
  r <- aw_run(s)
  expect_identical(r$status, 0L, info = paste(r$stdout, r$stderr))
  expect_length(aw_runs(s), 1L)
  expect_match(aw_log(s), "took over a stale lock", fixed = TRUE)
})

test_that("R-22.H: triggers started at once never run RSCRIPT more than once", {
  s <- aw_sandbox(sleep = 3)
  env <- environment()
  ps <- lapply(1:3, function(i) aw_start(s, env = env))
  for (p in ps) p$wait(60000)
  expect_length(aw_runs(s), 1L)
  expect_false(dir.exists(aw_lock(s)))
})

# ---- 5. gate -----------------------------------------------------------------------------------

test_that("the first run writes .imports.gate: one line of 64 hex digits, the gate script's hash", {
  s <- aw_sandbox()
  r <- aw_run(s)
  expect_identical(r$status, 0L, info = paste(r$stdout, r$stderr))
  expect_true(file.exists(aw_gate(s)))
  g <- aw_lines(aw_gate(s))
  expect_match(g[1], "^[0-9a-f]{64}$")
  h <- processx::run(Sys.which("pwsh"),
                     c("-NoProfile", "-File", aw_dev("auto-import-gate.ps1"),
                       "-Input", s$input, "-Db", s$db, "-TimeZone", "UTC"),
                     env = aw_full_env(s, aw_std(s)), error_on_status = FALSE, timeout = 60)
  expect_identical(g[1], trimws(h$stdout))
})

test_that("unchanged input and a state with pending false: the run is skipped", {
  s <- aw_sandbox()
  aw_prime(s)
  r <- aw_run(s)
  expect_identical(r$status, 0L, info = paste(r$stdout, r$stderr))
  expect_length(aw_runs(s), 0L)
})

test_that("unchanged input but a state with pending true: the stub runs", {
  s <- aw_sandbox()
  aw_prime(s)
  writeLines('{"pending":   true, "other": 1}', aw_state(s))
  r <- aw_run(s)
  expect_identical(r$status, 0L, info = paste(r$stdout, r$stderr))
  expect_length(aw_runs(s), 1L)
})

test_that("changed input: the stub runs", {
  s <- aw_sandbox()
  aw_prime(s)
  writeLines("a new batch file", file.path(s$input, "new.txt"))
  r <- aw_run(s)
  expect_identical(r$status, 0L, info = paste(r$stdout, r$stderr))
  expect_length(aw_runs(s), 1L)
})

test_that("a gate but no state file: the stub runs", {
  s <- aw_sandbox()
  aw_prime(s)
  file.remove(aw_state(s))
  r <- aw_run(s)
  expect_identical(r$status, 0L, info = paste(r$stdout, r$stderr))
  expect_length(aw_runs(s), 1L)
})

# ---- 6. child environment and output ------------------------------------------------------------

test_that("the child sees the resolved INPUT, DB and REPORT and is passed auto-import.R", {
  s <- aw_sandbox()
  r <- aw_run(s)
  expect_identical(r$status, 0L, info = paste(r$stdout, r$stderr))
  run <- aw_runs(s)[[1]]
  expect_identical(aw_norm(run[2:4]), aw_norm(c(s$report, s$input, s$db)))
  expect_match(aw_norm(run[6]), "/auto-import\\.R$")
  expect_identical(aw_norm(dirname(run[6])), aw_norm(dirname(aw_dev("auto-import.ps1"))))
})

test_that("the child's resolved values come from SAMPLETIDY_INPUT_DIR / REPORT_DIR when the overrides are unset", {
  s <- aw_sandbox()
  batches <- file.path(s$dir, "batches")
  dir.create(file.path(batches, "input"), recursive = TRUE)
  rep2 <- file.path(s$dir, "reports2")
  r <- aw_run(s, vars = aw_std(s, SAMPLETIDY_AUTOIMPORT_INPUT = NA, SAMPLETIDY_AUTOIMPORT_REPORT = NA,
                               SAMPLETIDY_INPUT_DIR = file.path(batches, "input"),
                               SAMPLETIDY_REPORT_DIR = rep2))
  expect_identical(r$status, 0L, info = paste(r$stdout, r$stderr))
  run <- aw_runs(s)[[1]]
  expect_identical(aw_norm(run[2:3]), aw_norm(c(rep2, batches)))
})

test_that("the child's stdout and stderr are appended to the log", {
  s <- aw_sandbox()
  aw_run(s)
  expect_match(aw_log(s), "stub stdout line", fixed = TRUE)
  expect_match(aw_log(s), "stub stderr line", fixed = TRUE)
})

# ---- 7. exit code and gate write -----------------------------------------------------------------

test_that("the exit code is RSCRIPT's: 0, 1 and 3", {
  for (rc in c(0L, 1L, 3L)) {
    s <- aw_sandbox(rc = rc)
    r <- aw_run(s)
    expect_identical(r$status, rc, info = paste(rc, r$stdout, r$stderr))
    expect_length(aw_runs(s), 1L)
  }
})

test_that("rc 3 does not write the gate, and leaves an existing gate unchanged", {
  s <- aw_sandbox(rc = 3L)
  aw_run(s)
  expect_false(file.exists(aw_gate(s)))
  writeLines("0123456789abcdef", aw_gate(s))
  r <- aw_run(s)
  expect_identical(r$status, 3L)
  expect_identical(aw_lines(aw_gate(s)), "0123456789abcdef")
})

test_that("rc 1 does not write the gate", {
  s <- aw_sandbox(rc = 1L)
  r <- aw_run(s)
  expect_identical(r$status, 1L)
  expect_false(file.exists(aw_gate(s)))
})

test_that("rc 0 replaces a stale gate with the current hash", {
  s <- aw_sandbox()
  dir.create(s$report)
  writeLines("stale", aw_gate(s))
  aw_run(s)
  expect_match(aw_lines(aw_gate(s))[1], "^[0-9a-f]{64}$")
})

# ---- 8. Windows only: bug 2 and the .cmd shim ------------------------------------------------------

test_that("bug 2: with RSCRIPT a .cmd stub, control returns and the gate is written", {
  skip_if_not(aw_is_win())
  s <- aw_sandbox()
  expect_match(s$rscript, "\\.cmd$")
  r <- aw_run(s)
  expect_identical(r$status, 0L, info = paste(r$stdout, r$stderr))
  expect_length(aw_runs(s), 1L)
  expect_true(file.exists(aw_gate(s)))
})

test_that("the .cmd shim passes rc 3 through", {
  skip_if_not(aw_is_win())
  s <- aw_sandbox(rc = 3L)
  r <- aw_run(s, via = "cmd")
  expect_identical(r$status, 3L, info = paste(r$stdout, r$stderr))
  expect_length(aw_runs(s), 1L)
  expect_false(file.exists(aw_gate(s)))
})

test_that("the .cmd shim prints the same config as the .ps1, for both spellings", {
  skip_if_not(aw_is_win())
  s <- aw_sandbox()
  v <- aw_std(s, SAMPLETIDY_TIMEZONE = "Pacific/Kiritimati")
  ref <- aw_print(s, v, "-PrintConfig")
  for (a in c("-PrintConfig", "--print-config")) {
    r <- aw_run(s, a, v, via = "cmd")
    expect_identical(r$status, 0L, info = paste(r$stdout, r$stderr))
    expect_identical(aw_kv(r)$lines, ref$lines)
  }
})

test_that("a normal run through the .cmd shim runs the stub and writes the gate", {
  skip_if_not(aw_is_win())
  s <- aw_sandbox()
  r <- aw_run(s, via = "cmd")
  expect_identical(r$status, 0L, info = paste(r$stdout, r$stderr))
  expect_length(aw_runs(s), 1L)
  expect_true(file.exists(aw_gate(s)))
})
