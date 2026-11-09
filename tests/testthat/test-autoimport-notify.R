# dev/auto-import.sh: a configurable notify command and a flush command.
#
# Deployment config (not test overrides), each read from the process environment
# and then from R's user environ file ($R_ENVIRON_USER, else ~/.Renviron):
#   SAMPLETIDY_NOTIFY_COMMAND  a single path, invoked `"$CMD" "<title>" "<message>"`.
#   SAMPLETIDY_NOTIFY_FLUSH    a single path, run with NO arguments once per run.
# Notify resolution: SAMPLETIDY_AUTOIMPORT_NOTIFY (test override) > process env >
# environ file > the desktop notification (osascript).
#   - a command that is not executable: log "notify command not executable: <cmd>"
#     and show the desktop notification instead;
#   - a command that exits non-zero: log "notify command exited <rc>", no desktop
#     notification; neither changes the trigger's exit status.
# Flush: run right after the lock is taken, before the health record is read and
# before the gate; output appended to the log; exit status ignored; a missing or
# non-executable command is logged and ignored. Not run when the off switch, a
# missing DB, a missing input folder or a held lock exit earlier.
# `--print-config` also prints NOTIFY= and NOTIFY_FLUSH= (empty = desktop / none).
# Dedupe (.imports.notified) is unchanged.
#
# ISOLATION: every run gets R_ENVIRON_USER = a sandbox file and both new
# variables set explicitly. A stub `osascript` sits first on PATH.

# ---- helpers -------------------------------------------------------------------------------

an_wrapper <- function() normalizePath(testthat::test_path("..", "..", "dev", "auto-import.sh"), mustWork = TRUE)

#' A sandbox: fake DB, input, report dir, log; a stub RSCRIPT, a stub notify
#' command, a stub flush command and a stub osascript. Every stub appends to
#' events.txt ("rscript", "notify", "flush", "osascript") so order is visible;
#' notify.txt holds "<argc>|<title>|<message>", flush.txt "<argc>[|lock]" and
#' osa.txt one line per desktop notification. STUB_NOTIFY_RC and STUB_FLUSH_RC
#' set the stubs' exit codes.
an_setup <- function(env = parent.frame()) {
  skip_on_os("windows")
  skip_if(Sys.which("bash") == "")
  d <- normalizePath(withr::local_tempdir(.local_envir = env))
  s <- list(dir = d, db = file.path(d, "monitoring.duckdb"), input = file.path(d, "in"),
            report = file.path(d, "report"), log = file.path(d, "log", "autoimport.log"),
            off = file.path(d, "off"), code = file.path(d, "code"), bin = file.path(d, "bin"),
            environ = file.path(d, "environ"), events = file.path(d, "events.txt"),
            notify_out = file.path(d, "notify.txt"), flush_out = file.path(d, "flush.txt"),
            osa = file.path(d, "osa.txt"),
            rscript = file.path(d, "stub-rscript.sh"), notify = file.path(d, "stub-notify.sh"),
            flush = file.path(d, "stub-flush.sh"))
  for (p in c(s$input, s$report, s$code, s$bin)) dir.create(p)
  writeLines("x", s$db); file.create(s$environ)
  writeLines("x", file.path(s$input, "README.txt"))
  writeLines(c("#!/bin/bash", sprintf('echo rscript >> "%s"', s$events), "exit 0"), s$rscript)
  writeLines(c("#!/bin/bash",
               sprintf('echo notify >> "%s"; echo "$#|$1|$2" >> "%s"', s$events, s$notify_out),
               'exit "${STUB_NOTIFY_RC:-0}"'), s$notify)
  writeLines(c("#!/bin/bash",
               sprintf('echo flush >> "%s"', s$events),
               sprintf('if [ -d "%s/.imports.lock" ]; then echo "$#|lock" >> "%s"; else echo "$#" >> "%s"; fi',
                       s$report, s$flush_out, s$flush_out),
               'echo "flush-stdout-marker"; echo "flush-stderr-marker" >&2',
               'exit "${STUB_FLUSH_RC:-0}"'), s$flush)
  osa <- file.path(s$bin, "osascript")
  writeLines(c("#!/bin/bash", sprintf('echo osascript >> "%s"; echo "$*" >> "%s"', s$events, s$osa)), osa)
  Sys.chmod(c(s$rscript, s$notify, s$flush, osa), "755")
  withr::local_envvar(c(
    SAMPLETIDY_AUTOIMPORT_DB = s$db, SAMPLETIDY_AUTOIMPORT_INPUT = s$input,
    SAMPLETIDY_AUTOIMPORT_REPORT = s$report, SAMPLETIDY_AUTOIMPORT_RSCRIPT = s$rscript,
    SAMPLETIDY_AUTOIMPORT_LOG = s$log, SAMPLETIDY_AUTOIMPORT_CODE = s$code,
    SAMPLETIDY_AUTOIMPORT_OFF = s$off, SAMPLETIDY_AUTOIMPORT_NOTIFY = "",
    SAMPLETIDY_AUTOIMPORT_STALE_HOURS = NA, SAMPLETIDY_AUTOIMPORT_PREV_FAILURE = NA,
    R_ENVIRON_USER = s$environ, SAMPLETIDY_NOTIFY_COMMAND = "", SAMPLETIDY_NOTIFY_FLUSH = "",
    STUB_NOTIFY_RC = NA, STUB_FLUSH_RC = NA,
    PATH = paste(s$bin, Sys.getenv("PATH"), sep = ":")), .local_envir = env)
  s
}

an_status <- function(args = character()) {
  out <- suppressWarnings(system2("bash", c(shQuote(an_wrapper()), args), stdout = TRUE, stderr = TRUE))
  as.integer(attr(out, "status") %||% 0L)
}
an_lines <- function(path) if (file.exists(path)) readLines(path, warn = FALSE) else character()
an_log <- function(s) paste(an_lines(s$log), collapse = "\n")
an_events <- function(s) an_lines(s$events)

#' The previous run failed (rc 1): the next tick notifies "fail:<started_at>".
an_fail_prev <- function(s, started = "2026-01-01T00:00:00Z") {
  writeLines(sprintf('{"state":"done","pid":1,"started_at":"%s","ended_at":"2026-01-01T00:01:00Z","rc":1,"last_success_at":null}',
                     started), file.path(s$report, ".imports.health"))
}
an_environ <- function(s, ...) writeLines(c(...), s$environ)

#' One good run, so a gate exists and the next tick is skipped by it.
an_prime_gate <- function(s) {
  expect_identical(an_status(), 0L)
  writeLines("{}", file.path(s$report, ".imports.state"))
  for (f in c(s$events, s$flush_out)) if (file.exists(f)) file.remove(f)
}

# ---- A1. resolution order -------------------------------------------------------------------

test_that("A1: the test override beats the process env and the environ file", {
  s <- an_setup()
  other <- file.path(s$dir, "other-notify.sh")
  writeLines(c("#!/bin/bash", sprintf('echo "$1" >> "%s"', file.path(s$dir, "other.txt"))), other)
  Sys.chmod(other, "755")
  an_environ(s, paste0("SAMPLETIDY_NOTIFY_COMMAND=", other))
  withr::local_envvar(SAMPLETIDY_AUTOIMPORT_NOTIFY = s$notify, SAMPLETIDY_NOTIFY_COMMAND = other)
  an_fail_prev(s)
  expect_identical(an_status(), 0L)
  expect_length(an_lines(s$notify_out), 1L)
  expect_false(file.exists(file.path(s$dir, "other.txt")))
  expect_false(file.exists(s$osa))
})

test_that("A1: SAMPLETIDY_NOTIFY_COMMAND in the process env beats the environ file", {
  s <- an_setup()
  other <- file.path(s$dir, "other-notify.sh")
  writeLines(c("#!/bin/bash", sprintf('echo "$1" >> "%s"', file.path(s$dir, "other.txt"))), other)
  Sys.chmod(other, "755")
  an_environ(s, paste0("SAMPLETIDY_NOTIFY_COMMAND=", other))
  withr::local_envvar(SAMPLETIDY_NOTIFY_COMMAND = s$notify)
  an_fail_prev(s)
  expect_identical(an_status(), 0L)
  expect_length(an_lines(s$notify_out), 1L)
  expect_false(file.exists(file.path(s$dir, "other.txt")))
  expect_false(file.exists(s$osa))
})

test_that("A1: SAMPLETIDY_NOTIFY_COMMAND is read from the environ file when the env has none", {
  s <- an_setup()
  an_environ(s, paste0("SAMPLETIDY_NOTIFY_COMMAND=", s$notify))
  an_fail_prev(s)
  expect_identical(an_status(), 0L)
  expect_length(an_lines(s$notify_out), 1L)
  expect_false(file.exists(s$osa))
})

test_that("A1: the command is called with exactly a title and a message", {
  s <- an_setup()
  withr::local_envvar(SAMPLETIDY_NOTIFY_COMMAND = s$notify)
  an_fail_prev(s)
  an_status()
  n <- strsplit(an_lines(s$notify_out), "|", fixed = TRUE)[[1]]
  expect_identical(n[1], "2")
  expect_match(n[2], "sampleTidy import")
  expect_match(n[3], "failed")
})

test_that("A1: a command path containing a space is not word-split", {
  s <- an_setup()
  dir.create(file.path(s$dir, "my tools"))
  spaced <- file.path(s$dir, "my tools", "notify.sh")
  file.copy(s$notify, spaced); Sys.chmod(spaced, "755")
  withr::local_envvar(SAMPLETIDY_NOTIFY_COMMAND = spaced)
  an_fail_prev(s)
  an_status()
  expect_length(an_lines(s$notify_out), 1L)
  expect_false(file.exists(s$osa))
})

test_that("A1: with no command anywhere the desktop notification (osascript) is used", {
  s <- an_setup()
  an_fail_prev(s)
  expect_identical(an_status(), 0L)
  expect_length(an_lines(s$osa), 1L)
  expect_match(an_lines(s$osa), "sampleTidy import")
  expect_false(file.exists(s$notify_out))
})

# ---- A2. failures of the command -------------------------------------------------------------

test_that("A2: a configured command that is not executable is logged and the desktop notification shown", {
  s <- an_setup()
  plain <- file.path(s$dir, "plain.sh"); writeLines("#!/bin/bash", plain); Sys.chmod(plain, "644")
  withr::local_envvar(SAMPLETIDY_NOTIFY_COMMAND = plain)
  an_fail_prev(s)
  expect_identical(an_status(), 0L)
  expect_match(an_log(s), paste0("notify command not executable: ", plain), fixed = TRUE)
  expect_length(an_lines(s$osa), 1L)
})

test_that("A2: a configured command that does not exist is logged and the desktop notification shown", {
  s <- an_setup()
  gone <- file.path(s$dir, "no-such-notify")
  an_environ(s, paste0("SAMPLETIDY_NOTIFY_COMMAND=", gone))
  an_fail_prev(s)
  expect_identical(an_status(), 0L)
  expect_match(an_log(s), paste0("notify command not executable: ", gone), fixed = TRUE)
  expect_length(an_lines(s$osa), 1L)
})

test_that("A2: a command that exits non-zero is logged, with no desktop notification and the same exit status", {
  s <- an_setup()
  withr::local_envvar(SAMPLETIDY_NOTIFY_COMMAND = s$notify, STUB_NOTIFY_RC = "7")
  an_fail_prev(s)
  expect_identical(an_status(), 0L)
  expect_length(an_lines(s$notify_out), 1L)
  expect_match(an_log(s), "notify command exited 7", fixed = TRUE)
  expect_false(file.exists(s$osa))
})

test_that("A2: the desktop notification is not shown when the command succeeds", {
  s <- an_setup()
  withr::local_envvar(SAMPLETIDY_NOTIFY_COMMAND = s$notify)
  an_fail_prev(s)
  an_status()
  expect_false(file.exists(s$osa))
  expect_false(grepl("notify command", an_log(s), fixed = TRUE))
})

# ---- A3. flush ---------------------------------------------------------------------------------

test_that("A3: the flush command runs once, with no arguments, while the lock is held", {
  s <- an_setup()
  withr::local_envvar(SAMPLETIDY_NOTIFY_FLUSH = s$flush)
  expect_identical(an_status(), 0L)
  expect_identical(an_lines(s$flush_out), "0|lock")
  expect_identical(sum(an_events(s) == "flush"), 1L)
})

test_that("A3: the flush runs before the health record is acted on and before the run", {
  s <- an_setup()
  withr::local_envvar(SAMPLETIDY_NOTIFY_FLUSH = s$flush, SAMPLETIDY_NOTIFY_COMMAND = s$notify)
  an_fail_prev(s)
  an_status()
  expect_identical(an_events(s), c("flush", "notify", "rscript"))
})

test_that("A3: a tick the gate skips still flushes", {
  s <- an_setup()
  withr::local_envvar(SAMPLETIDY_NOTIFY_FLUSH = s$flush)
  an_prime_gate(s)
  expect_identical(an_status(), 0L)
  expect_identical(an_events(s), "flush")    # flushed, and RSCRIPT did not run
})

test_that("A3: the off switch means no flush", {
  s <- an_setup()
  writeLines("", s$off)
  withr::local_envvar(SAMPLETIDY_NOTIFY_FLUSH = s$flush)
  expect_identical(an_status(), 0L)
  expect_length(an_events(s), 0L)
})

test_that("A3: a missing DB or input folder means no flush", {
  s <- an_setup()
  withr::local_envvar(SAMPLETIDY_NOTIFY_FLUSH = s$flush)
  file.remove(s$db)
  an_status()
  writeLines("x", s$db)
  unlink(s$input, recursive = TRUE)
  an_status()
  expect_length(an_events(s), 0L)
})

test_that("A3: a held lock means no flush", {
  s <- an_setup()
  withr::local_envvar(SAMPLETIDY_NOTIFY_FLUSH = s$flush)
  pid <- as.integer(system2("bash", c("-c", shQuote("sleep 300 >/dev/null 2>&1 & echo $!")), stdout = TRUE))
  withr::defer(tools::pskill(pid))
  dir.create(file.path(s$report, ".imports.lock"))
  writeLines(as.character(pid), file.path(s$report, ".imports.lock", "pid"))
  expect_identical(an_status(), 0L)
  expect_length(an_events(s), 0L)
})

test_that("A3: the flush command's output is appended to the log", {
  s <- an_setup()
  withr::local_envvar(SAMPLETIDY_NOTIFY_FLUSH = s$flush)
  an_status()
  expect_match(an_log(s), "flush-stdout-marker", fixed = TRUE)
  expect_match(an_log(s), "flush-stderr-marker", fixed = TRUE)
})

test_that("A3: a flush command that fails does not change the exit status or stop the run", {
  s <- an_setup()
  withr::local_envvar(SAMPLETIDY_NOTIFY_FLUSH = s$flush, STUB_FLUSH_RC = "5")
  expect_identical(an_status(), 0L)
  expect_identical(an_events(s), c("flush", "rscript"))
})

test_that("A3: a missing or non-executable flush command is logged and ignored", {
  s <- an_setup()
  gone <- file.path(s$dir, "no-such-flush")
  withr::local_envvar(SAMPLETIDY_NOTIFY_FLUSH = gone)
  expect_identical(an_status(), 0L)
  expect_match(an_log(s), gone, fixed = TRUE)
  expect_identical(an_events(s), "rscript")
  plain <- file.path(s$dir, "plain-flush.sh"); writeLines("#!/bin/bash", plain); Sys.chmod(plain, "644")
  withr::local_envvar(SAMPLETIDY_NOTIFY_FLUSH = plain)
  expect_identical(an_status(), 0L)
  expect_match(an_log(s), plain, fixed = TRUE)
})

test_that("A3: SAMPLETIDY_NOTIFY_FLUSH comes from the environ file, and the process env beats it", {
  s <- an_setup()
  an_environ(s, paste0("SAMPLETIDY_NOTIFY_FLUSH=", s$flush))
  an_status()
  expect_identical(sum(an_events(s) == "flush"), 1L)
  file.remove(s$events)
  other <- file.path(s$dir, "other-flush.sh")
  writeLines(c("#!/bin/bash", sprintf('echo other-flush >> "%s"', s$events)), other)
  Sys.chmod(other, "755")
  withr::local_envvar(SAMPLETIDY_NOTIFY_FLUSH = other)
  an_status()
  expect_true("other-flush" %in% an_events(s))
  expect_false("flush" %in% an_events(s))
})

# ---- A4. --print-config ------------------------------------------------------------------------

test_that("A4: --print-config prints NOTIFY and NOTIFY_FLUSH, empty when unset", {
  s <- an_setup()
  out <- system2("bash", c(shQuote(an_wrapper()), "--print-config"), stdout = TRUE)
  expect_true("NOTIFY=" %in% out)
  expect_true("NOTIFY_FLUSH=" %in% out)
})

test_that("A4: --print-config prints the resolved values (env, then environ file)", {
  s <- an_setup()
  an_environ(s, "SAMPLETIDY_NOTIFY_COMMAND=/from/file-notify", "SAMPLETIDY_NOTIFY_FLUSH=/from/file-flush")
  out <- system2("bash", c(shQuote(an_wrapper()), "--print-config"), stdout = TRUE)
  expect_true("NOTIFY=/from/file-notify" %in% out)
  expect_true("NOTIFY_FLUSH=/from/file-flush" %in% out)
  withr::local_envvar(SAMPLETIDY_NOTIFY_COMMAND = "/from/env-notify", SAMPLETIDY_NOTIFY_FLUSH = "/from/env-flush")
  out <- system2("bash", c(shQuote(an_wrapper()), "--print-config"), stdout = TRUE)
  expect_true("NOTIFY=/from/env-notify" %in% out)
  expect_true("NOTIFY_FLUSH=/from/env-flush" %in% out)
})

# ---- A5. dedupe unchanged ----------------------------------------------------------------------

test_that("A5: one failed run is notified once across two ticks through the new command route", {
  s <- an_setup()
  withr::local_envvar(SAMPLETIDY_NOTIFY_COMMAND = s$notify)
  an_fail_prev(s, started = "2026-01-01T00:00:00Z")
  an_status()
  expect_length(an_lines(s$notify_out), 1L)
  an_fail_prev(s, started = "2026-01-01T00:00:00Z")   # the same failed run, seen again
  an_status()
  expect_length(an_lines(s$notify_out), 1L)
  expect_true("fail:2026-01-01T00:00:00Z" %in% an_lines(file.path(s$report, ".imports.notified")))
})
