# PLAN-21 phase (a), section 4: the trigger's watch folder,
# SAMPLETIDY_GATE_WATCH, in dev/auto-import.sh and dev/auto-import.ps1.
#
#   * a deployment setting (not an SAMPLETIDY_AUTOIMPORT_* key): the process
#     environment first, then (.sh only) R's user environ file via renviron_get;
#   * when set, the change hash also covers a sorted metadata listing of that
#     folder (mindepth 1, maxdepth 2: name, ctime, mtime), so a change there
#     alone starts R (whose writer check then decides);
#   * a listing failure of the watch folder does NOT exit 3 and does not
#     notify: a fixed line `WATCH|unlistable` is hashed instead;
#   * unset: the hash is exactly as today;
#   * --print-config prints WATCH=<value> (empty when unset).
#
# ISOLATION: as in test-autoimport-config.R / test-autoimport-windows.R, every
# child gets a clean environment with HOME, DB, input, report dir, log, pause
# file and R environ file inside a temp dir. RSCRIPT and NOTIFY are stubs: no R
# child is started.

gw_dev <- function(...) normalizePath(testthat::test_path("..", "..", "dev", ...), mustWork = TRUE)

gw_lines <- function(path) if (file.exists(path)) readLines(path, warn = FALSE) else character()

gw_skip_if_root <- function() {
  skip_if(identical(Sys.info()[["user"]], "root"), "root can list a mode-000 directory")
}

# ==== dev/auto-import.sh ======================================================================

#' A sandbox: HOME, a fake DB, an input dir with one file, a watch folder with
#' a file and a subfolder holding a file, an empty environ file, a stub RSCRIPT
#' (one line per run in runs.txt) and a stub NOTIFY (one line per call).
gw_sh_sandbox <- function(env = parent.frame()) {
  skip_on_os("windows")
  skip_if(Sys.which("bash") == "", "no bash")
  d <- normalizePath(withr::local_tempdir(.local_envir = env))
  s <- list(dir = d, home = file.path(d, "home"), db = file.path(d, "monitoring.duckdb"),
            input = file.path(d, "assets"), watch = file.path(d, "watch"),
            report = file.path(d, "report"), code = file.path(d, "code"),
            log = file.path(d, "logs", "ai.log"), off = file.path(d, "off"),
            runs = file.path(d, "runs.txt"), notes = file.path(d, "notes.txt"),
            environ = file.path(d, "environ"),
            rscript = file.path(d, "stub-rscript.sh"), notify = file.path(d, "stub-notify.sh"))
  for (p in c(s$home, s$input, s$code, file.path(s$watch, "sub"))) dir.create(p, recursive = TRUE)
  writeLines("x", s$db)
  writeLines("x", file.path(s$input, "README.txt"))
  writeLines("lease", file.path(s$watch, "lease.json"))
  writeLines("held", file.path(s$watch, "sub", "held.txt"))
  file.create(s$environ)
  writeLines(c("#!/bin/bash", sprintf('echo "run" >> "%s"', s$runs), "exit 0"), s$rscript)
  writeLines(c("#!/bin/bash", sprintf('echo "$1|$2" >> "%s"', s$notes)), s$notify)
  Sys.chmod(c(s$rscript, s$notify), "755")
  s
}

#' The child environment; `...` adds or overrides (e.g. SAMPLETIDY_GATE_WATCH).
gw_sh_env <- function(s, ...) {
  v <- c(HOME = s$home, PATH = "/usr/bin:/bin:/usr/sbin:/sbin",
         SAMPLETIDY_AUTOIMPORT_DB = s$db, SAMPLETIDY_AUTOIMPORT_INPUT = s$input,
         SAMPLETIDY_AUTOIMPORT_REPORT = s$report, SAMPLETIDY_AUTOIMPORT_RSCRIPT = s$rscript,
         SAMPLETIDY_AUTOIMPORT_CODE = s$code, SAMPLETIDY_AUTOIMPORT_LOG = s$log,
         SAMPLETIDY_AUTOIMPORT_OFF = s$off, SAMPLETIDY_AUTOIMPORT_NOTIFY = s$notify,
         R_ENVIRON_USER = s$environ)
  over <- c(...)
  if (length(over)) v <- c(v[setdiff(names(v), names(over))], over)
  v
}

gw_sh_run <- function(s, args = character(), ...) {
  processx::run("/bin/bash", c(gw_dev("auto-import.sh"), args), env = gw_sh_env(s, ...),
                error_on_status = FALSE, timeout = 60)
}

gw_runs <- function(s) length(gw_lines(s$runs))
gw_notes <- function(s) gw_lines(s$notes)
gw_gate <- function(s) gw_lines(file.path(s$report, ".imports.gate"))
gw_state_ok <- function(s) writeLines("{}", file.path(s$report, ".imports.state"))

#' One good tick (so a gate exists), then the state R would leave; runs and
#' notes are reset. `...` is the tick's environment.
gw_sh_prime <- function(s, ...) {
  r <- gw_sh_run(s, ...)
  expect_identical(r$status, 0L, info = r$stderr)
  expect_identical(gw_runs(s), 1L)
  gw_state_ok(s)
  unlink(c(s$runs, s$notes))
  invisible(r)
}

#' Today's change hash, computed independently: the input listing, the DB stat
#' and the UTC day, exactly as dev/auto-import.sh hashed them before the watch.
gw_sh_today_hash <- function(s) {
  cmd <- sprintf(paste0(
    "{ find %s -mindepth 1 -maxdepth 2 ! -name .DS_Store -exec stat -f '%%N|%%z|%%m' {} + | LC_ALL=C sort; ",
    "stat -f 'DB|%%z|%%m' %s; TZ=UTC date +%%F; } | shasum -a 256 | cut -d' ' -f1"),
    shQuote(s$input), shQuote(s$db))
  trimws(processx::run("/bin/bash", c("-c", cmd), env = c(PATH = "/usr/bin:/bin"))$stdout)
}

gw_sh_print <- function(s, ...) {
  r <- gw_sh_run(s, "--print-config", ...)
  expect_identical(r$status, 0L, info = r$stderr)
  kv <- strsplit(strsplit(sub("\n$", "", r$stdout), "\n", fixed = TRUE)[[1]], "=", fixed = TRUE)
  out <- lapply(kv, function(x) paste(x[-1], collapse = "="))
  names(out) <- vapply(kv, `[`, "", 1L)
  out
}

# ---- .sh: --print-config ---------------------------------------------------------------------

test_that(".sh --print-config prints WATCH last: the env value, else the environ file's, else empty", {
  s <- gw_sh_sandbox()
  p <- gw_sh_print(s)
  expect_identical(names(p), c("DB", "INPUT", "REPORT", "TIMEZONE", "LOG", "NOTIFY", "NOTIFY_FLUSH", "WATCH"))
  expect_identical(p$WATCH, "")

  expect_identical(gw_sh_print(s, SAMPLETIDY_GATE_WATCH = s$watch)$WATCH, s$watch)

  writeLines(c("SAMPLETIDY_GATE_WATCH=/from/file/old", "SAMPLETIDY_GATE_WATCH='/from/file'"), s$environ)
  expect_identical(gw_sh_print(s)$WATCH, "/from/file")
  expect_identical(gw_sh_print(s, SAMPLETIDY_GATE_WATCH = "/from/env")$WATCH, "/from/env")
})

test_that(".sh --print-config with a watch folder creates nothing", {
  s <- gw_sh_sandbox()
  gw_sh_print(s, SAMPLETIDY_GATE_WATCH = s$watch)
  expect_false(dir.exists(s$report))
  expect_false(file.exists(s$log))
  expect_length(list.files(s$home, all.files = TRUE, no.. = TRUE), 0)
})

# ---- .sh: unset is today ---------------------------------------------------------------------

test_that(".sh with SAMPLETIDY_GATE_WATCH unset: the gate is exactly today's hash", {
  s <- gw_sh_sandbox()
  r <- gw_sh_run(s)
  expect_identical(r$status, 0L, info = r$stderr)
  expect_identical(gw_runs(s), 1L)
  expect_identical(gw_gate(s), gw_sh_today_hash(s))
})

test_that(".sh with SAMPLETIDY_GATE_WATCH empty in the environment and the file: still today's hash", {
  s <- gw_sh_sandbox()
  writeLines("SAMPLETIDY_GATE_WATCH=", s$environ)
  r <- gw_sh_run(s, SAMPLETIDY_GATE_WATCH = "")
  expect_identical(r$status, 0L, info = r$stderr)
  expect_identical(gw_gate(s), gw_sh_today_hash(s))
})

test_that(".sh with the watch unset, a change in that (unconfigured) folder does not start R", {
  s <- gw_sh_sandbox()
  gw_sh_prime(s)
  writeLines("new", file.path(s$watch, "new.json"))
  r <- gw_sh_run(s)
  expect_identical(r$status, 0L, info = r$stderr)
  expect_identical(gw_runs(s), 0L)
})

# ---- .sh: the watch is part of the gate ----------------------------------------------------------

test_that(".sh with a watch folder and nothing changed: the second tick is skipped", {
  s <- gw_sh_sandbox()
  gw_sh_prime(s, SAMPLETIDY_GATE_WATCH = s$watch)
  r <- gw_sh_run(s, SAMPLETIDY_GATE_WATCH = s$watch)
  expect_identical(r$status, 0L, info = r$stderr)
  expect_identical(gw_runs(s), 0L)
})

test_that(".sh: a new file in the watch folder alone starts R", {
  s <- gw_sh_sandbox()
  gw_sh_prime(s, SAMPLETIDY_GATE_WATCH = s$watch)
  writeLines("other machine", file.path(s$watch, "claim.json"))
  r <- gw_sh_run(s, SAMPLETIDY_GATE_WATCH = s$watch)
  expect_identical(r$status, 0L, info = r$stderr)
  expect_identical(gw_runs(s), 1L)
})

test_that(".sh: a new mtime on a file one folder down in the watch folder alone starts R", {
  s <- gw_sh_sandbox()
  gw_sh_prime(s, SAMPLETIDY_GATE_WATCH = s$watch)
  Sys.setFileTime(file.path(s$watch, "sub", "held.txt"), Sys.time() - 86400)
  r <- gw_sh_run(s, SAMPLETIDY_GATE_WATCH = s$watch)
  expect_identical(r$status, 0L, info = r$stderr)
  expect_identical(gw_runs(s), 1L)
})

test_that(".sh: a watch folder named only in the environ file is watched too", {
  s <- gw_sh_sandbox()
  writeLines(sprintf('SAMPLETIDY_GATE_WATCH="%s"', s$watch), s$environ)
  gw_sh_prime(s)
  r <- gw_sh_run(s)
  expect_identical(gw_runs(s), 0L)
  writeLines("other machine", file.path(s$watch, "claim.json"))
  r <- gw_sh_run(s)
  expect_identical(r$status, 0L, info = r$stderr)
  expect_identical(gw_runs(s), 1L)
})

test_that(".sh: the input's own changes still start R with a watch folder set", {
  s <- gw_sh_sandbox()
  gw_sh_prime(s, SAMPLETIDY_GATE_WATCH = s$watch)
  writeLines("a batch", file.path(s$input, "new.csv"))
  r <- gw_sh_run(s, SAMPLETIDY_GATE_WATCH = s$watch)
  expect_identical(gw_runs(s), 1L)
})

# ---- .sh: an unlistable watch folder ---------------------------------------------------------------

test_that(".sh: a missing watch folder does not exit 3 or notify; R runs, a gate is written, and a repeat tick is skipped", {
  s <- gw_sh_sandbox()
  gone <- file.path(s$dir, "no-such-watch")
  r <- gw_sh_run(s, SAMPLETIDY_GATE_WATCH = gone)
  expect_identical(r$status, 0L, info = r$stderr)
  expect_identical(gw_runs(s), 1L)
  expect_length(gw_notes(s), 0L)
  expect_match(gw_gate(s), "^[0-9a-f]{64}$")
  gw_state_ok(s)
  r2 <- gw_sh_run(s, SAMPLETIDY_GATE_WATCH = gone)
  expect_identical(r2$status, 0L, info = r2$stderr)
  expect_identical(gw_runs(s), 1L)
  expect_length(gw_notes(s), 0L)
})

test_that(".sh: a watch folder with an unreadable subfolder does not exit 3 or notify; a repeat tick is skipped", {
  s <- gw_sh_sandbox()
  gw_skip_if_root()
  locked <- file.path(s$watch, "locked")
  dir.create(locked)
  Sys.chmod(locked, "000")
  withr::defer(Sys.chmod(locked, "755"))
  r <- gw_sh_run(s, SAMPLETIDY_GATE_WATCH = s$watch)
  expect_identical(r$status, 0L, info = r$stderr)
  expect_identical(gw_runs(s), 1L)
  expect_length(gw_notes(s), 0L)
  expect_match(gw_gate(s), "^[0-9a-f]{64}$")
  gw_state_ok(s)
  r2 <- gw_sh_run(s, SAMPLETIDY_GATE_WATCH = s$watch)
  expect_identical(r2$status, 0L, info = r2$stderr)
  expect_identical(gw_runs(s), 1L)
  expect_length(gw_notes(s), 0L)
})

test_that(".sh: while the watch folder is unlistable, a change in the input still starts R", {
  s <- gw_sh_sandbox()
  gone <- file.path(s$dir, "no-such-watch")
  gw_sh_prime(s, SAMPLETIDY_GATE_WATCH = gone)
  writeLines("a batch", file.path(s$input, "new.csv"))
  r <- gw_sh_run(s, SAMPLETIDY_GATE_WATCH = gone)
  expect_identical(r$status, 0L, info = r$stderr)
  expect_identical(gw_runs(s), 1L)
})

test_that(".sh: the input's own listing failure still exits non-zero with a watch folder set", {
  s <- gw_sh_sandbox()
  gw_skip_if_root()
  locked <- file.path(s$input, "locked")
  dir.create(locked)
  Sys.chmod(locked, "000")
  withr::defer(Sys.chmod(locked, "755"))
  r <- gw_sh_run(s, SAMPLETIDY_GATE_WATCH = s$watch)
  expect_false(identical(r$status, 0L))
  expect_identical(gw_runs(s), 0L)
})

# ==== dev/auto-import.ps1 =====================================================================
# PLAN-21 b2: the .ps1 also reads R's environ file; these tests point it at a file that
# does not exist, so the watch folder comes from the process environment only.

gw_is_win <- function() .Platform$OS.type == "windows"

gw_ps_blank <- c("SAMPLETIDY_AUTOIMPORT_DB", "SAMPLETIDY_AUTOIMPORT_INPUT",
                 "SAMPLETIDY_AUTOIMPORT_REPORT", "SAMPLETIDY_AUTOIMPORT_RSCRIPT",
                 "SAMPLETIDY_AUTOIMPORT_LOG", "SAMPLETIDY_AUTOIMPORT_OFF",
                 "SAMPLETIDY_AUTOIMPORT_CODE", "SAMPLETIDY_AUTOIMPORT_NOTIFY",
                 "SAMPLETIDY_AUTOIMPORT_STALE_HOURS", "SAMPLETIDY_INPUT_DIR",
                 "SAMPLETIDY_REPORT_DIR", "SAMPLETIDY_TIMEZONE", "SAMPLETIDY_GATE_WATCH",
                 "R_ENVIRON_USER")

gw_ps_sandbox <- function(env = parent.frame()) {
  skip_if(Sys.which("pwsh") == "", "no pwsh")
  d <- normalizePath(withr::local_tempdir(.local_envir = env))
  s <- list(dir = d, home = file.path(d, "home"), lad = file.path(d, "localappdata"),
            db = file.path(d, "monitoring.duckdb"), input = file.path(d, "assets"),
            watch = file.path(d, "watch"), report = file.path(d, "reports"),
            log = file.path(d, "logs", "ai.log"), off = file.path(d, "off"),
            runs = file.path(d, "runs.txt"),
            rscript = file.path(d, if (gw_is_win()) "stub-rscript.cmd" else "stub-rscript.sh"))
  for (p in c(s$home, s$lad, s$input, file.path(s$watch, "sub"))) dir.create(p, recursive = TRUE)
  writeLines("x", s$db)
  writeLines("x", file.path(s$input, "README.txt"))
  writeLines("lease", file.path(s$watch, "lease.json"))
  writeLines("held", file.path(s$watch, "sub", "held.txt"))
  if (gw_is_win()) {
    writeLines(c("@echo off", sprintf('>>"%s" echo run', s$runs), "exit /b 0"), s$rscript, sep = "\r\n")
  } else {
    writeLines(c("#!/bin/bash", sprintf('echo "run" >> "%s"', s$runs), "exit 0"), s$rscript)
    Sys.chmod(s$rscript, "755")
  }
  s
}

#' The child environment; `...` adds or overrides (NA = leave unset).
gw_ps_env <- function(s, ...) {
  v <- c(SAMPLETIDY_AUTOIMPORT_DB = s$db, SAMPLETIDY_AUTOIMPORT_INPUT = s$input,
         SAMPLETIDY_AUTOIMPORT_REPORT = s$report, SAMPLETIDY_AUTOIMPORT_RSCRIPT = s$rscript,
         SAMPLETIDY_AUTOIMPORT_LOG = s$log, SAMPLETIDY_AUTOIMPORT_OFF = s$off,
         LOCALAPPDATA = s$lad,
         # hermetic: run this checkout's dev/ (no worktree, no git) and read no developer .Renviron
         SAMPLETIDY_AUTOIMPORT_CODE = dirname(gw_dev()),
         R_ENVIRON_USER = file.path(s$dir, "no-such.Renviron"))
  over <- c(...)
  if (length(over)) v <- c(v[setdiff(names(v), names(over))], over)
  if (gw_is_win()) {
    v[is.na(v)] <- ""
    blank <- stats::setNames(rep("", length(gw_ps_blank)), gw_ps_blank)
    c("current", blank[setdiff(names(blank), names(v))], v)
  } else {
    v <- v[!is.na(v)]
    pw <- dirname(Sys.which("pwsh"))
    base <- c(HOME = s$home, PATH = paste(c("/usr/bin", "/bin", pw), collapse = ":"),
              POWERSHELL_TELEMETRY_OPTOUT = "1", DOTNET_CLI_TELEMETRY_OPTOUT = "1")
    c(base[setdiff(names(base), names(v))], v)
  }
}

gw_ps_run <- function(s, args = character(), ...) {
  processx::run(as.character(Sys.which("pwsh")),
                c("-NoProfile", "-File", gw_dev("auto-import.ps1"), args),
                env = gw_ps_env(s, ...), error_on_status = FALSE, timeout = 60)
}

gw_ps_prime <- function(s, ...) {
  r <- gw_ps_run(s, ...)
  expect_identical(r$status, 0L, info = paste(r$stdout, r$stderr))
  expect_identical(gw_runs(s), 1L)
  writeLines('{"pending": false}', file.path(s$report, ".imports.state"))
  unlink(s$runs)
  invisible(r)
}

gw_ps_print <- function(s, args = "-PrintConfig", ...) {
  r <- gw_ps_run(s, args, ...)
  expect_identical(r$status, 0L, info = paste(r$stdout, r$stderr))
  out <- strsplit(r$stdout, "\r?\n")[[1]]
  out <- out[nzchar(out)]
  list(lines = out, keys = sub("=.*$", "", out), vals = sub("^[^=]*=", "", out))
}

# ---- .ps1: print config ---------------------------------------------------------------------------

test_that(".ps1 print config prints the eight keys with WATCH last, for both spellings: the env value, else empty", {
  s <- gw_ps_sandbox()
  for (a in c("-PrintConfig", "--print-config")) {
    k <- gw_ps_print(s, a)
    expect_identical(k$keys, c("DB", "INPUT", "REPORT", "TIMEZONE", "LOG", "NOTIFY", "NOTIFY_FLUSH", "WATCH"), info = a)
    expect_identical(k$vals[8], "", info = a)
    k <- gw_ps_print(s, a, SAMPLETIDY_GATE_WATCH = s$watch)
    expect_identical(gsub("\\\\", "/", k$vals[8]), gsub("\\\\", "/", s$watch), info = a)
  }
})

# ---- .ps1: the gate ------------------------------------------------------------------------------

test_that(".ps1 with the watch unset: the gate is the gate script's hash as today, and a change in that folder does not start R", {
  s <- gw_ps_sandbox()
  gw_ps_prime(s)
  h <- processx::run(as.character(Sys.which("pwsh")),
                     c("-NoProfile", "-File", gw_dev("auto-import-gate.ps1"),
                       "-Input", s$input, "-Db", s$db, "-TimeZone", "UTC"),
                     env = gw_ps_env(s), error_on_status = FALSE, timeout = 60)
  expect_identical(gw_lines(file.path(s$report, ".imports.gate"))[1], trimws(h$stdout))
  writeLines("new", file.path(s$watch, "new.json"))
  r <- gw_ps_run(s)
  expect_identical(r$status, 0L, info = paste(r$stdout, r$stderr))
  expect_identical(gw_runs(s), 0L)
})

test_that(".ps1 with a watch folder and nothing changed: the second tick is skipped", {
  s <- gw_ps_sandbox()
  gw_ps_prime(s, SAMPLETIDY_GATE_WATCH = s$watch)
  r <- gw_ps_run(s, SAMPLETIDY_GATE_WATCH = s$watch)
  expect_identical(r$status, 0L, info = paste(r$stdout, r$stderr))
  expect_identical(gw_runs(s), 0L)
})

test_that(".ps1: a new file in the watch folder alone starts R", {
  s <- gw_ps_sandbox()
  gw_ps_prime(s, SAMPLETIDY_GATE_WATCH = s$watch)
  writeLines("other machine", file.path(s$watch, "claim.json"))
  r <- gw_ps_run(s, SAMPLETIDY_GATE_WATCH = s$watch)
  expect_identical(r$status, 0L, info = paste(r$stdout, r$stderr))
  expect_identical(gw_runs(s), 1L)
})

test_that(".ps1: a new mtime on a file one folder down in the watch folder alone starts R", {
  s <- gw_ps_sandbox()
  gw_ps_prime(s, SAMPLETIDY_GATE_WATCH = s$watch)
  Sys.setFileTime(file.path(s$watch, "sub", "held.txt"), Sys.time() - 86400)
  r <- gw_ps_run(s, SAMPLETIDY_GATE_WATCH = s$watch)
  expect_identical(r$status, 0L, info = paste(r$stdout, r$stderr))
  expect_identical(gw_runs(s), 1L)
})

test_that(".ps1: the input's own changes still start R with a watch folder set", {
  s <- gw_ps_sandbox()
  gw_ps_prime(s, SAMPLETIDY_GATE_WATCH = s$watch)
  writeLines("a batch", file.path(s$input, "new.csv"))
  r <- gw_ps_run(s, SAMPLETIDY_GATE_WATCH = s$watch)
  expect_identical(gw_runs(s), 1L)
})

test_that(".ps1: a missing watch folder does not exit 3; R runs, a gate is written, and a repeat tick is skipped", {
  s <- gw_ps_sandbox()
  gone <- file.path(s$dir, "no-such-watch")
  r <- gw_ps_run(s, SAMPLETIDY_GATE_WATCH = gone)
  expect_identical(r$status, 0L, info = paste(r$stdout, r$stderr))
  expect_identical(gw_runs(s), 1L)
  expect_match(gw_lines(file.path(s$report, ".imports.gate"))[1], "^[0-9a-f]{64}$")
  writeLines('{"pending": false}', file.path(s$report, ".imports.state"))
  r2 <- gw_ps_run(s, SAMPLETIDY_GATE_WATCH = gone)
  expect_identical(r2$status, 0L, info = paste(r2$stdout, r2$stderr))
  expect_identical(gw_runs(s), 1L)
})

test_that(".ps1: a watch folder with an unreadable subfolder does not exit 3; a repeat tick is skipped", {
  s <- gw_ps_sandbox()
  skip_on_os("windows")
  gw_skip_if_root()
  locked <- file.path(s$watch, "locked")
  dir.create(locked)
  Sys.chmod(locked, "000")
  withr::defer(Sys.chmod(locked, "755"))
  r <- gw_ps_run(s, SAMPLETIDY_GATE_WATCH = s$watch)
  expect_identical(r$status, 0L, info = paste(r$stdout, r$stderr))
  expect_identical(gw_runs(s), 1L)
  writeLines('{"pending": false}', file.path(s$report, ".imports.state"))
  r2 <- gw_ps_run(s, SAMPLETIDY_GATE_WATCH = s$watch)
  expect_identical(r2$status, 0L, info = paste(r2$stdout, r2$stderr))
  expect_identical(gw_runs(s), 1L)
})

test_that(".ps1: while the watch folder is unlistable, a change in the input still starts R", {
  s <- gw_ps_sandbox()
  gone <- file.path(s$dir, "no-such-watch")
  gw_ps_prime(s, SAMPLETIDY_GATE_WATCH = gone)
  writeLines("a batch", file.path(s$input, "new.csv"))
  r <- gw_ps_run(s, SAMPLETIDY_GATE_WATCH = gone)
  expect_identical(r$status, 0L, info = paste(r$stdout, r$stderr))
  expect_identical(gw_runs(s), 1L)
})
