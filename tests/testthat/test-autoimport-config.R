# Stage 3 of the layer move: dev/auto-import.sh, auto-import.R, the Windows gate
# and the launchd files name no deployment. Every value the hourly job needs
# (DB, input, report dir, zone) is resolved in one place:
#
#   DB      $SAMPLETIDY_AUTOIMPORT_DB, else <HOME>/Library/Application Support/
#           org.R-project.R/R/sampleTidy/monitoring.duckdb
#   INPUT   $SAMPLETIDY_AUTOIMPORT_INPUT (verbatim), else $SAMPLETIDY_INPUT_DIR,
#           else the last SAMPLETIDY_INPUT_DIR line of R's user environ file;
#           for those two, a folder named `input` is replaced by its parent
#   REPORT  $SAMPLETIDY_AUTOIMPORT_REPORT, else $SAMPLETIDY_REPORT_DIR, else the
#           environ file, else <HOME>/Library/Application Support/org.R-project.R/
#           R/sampleTidy/reports (PKM_VAULT is no longer read)
#   ZONE    $SAMPLETIDY_TIMEZONE, else the environ file, else UTC
#   `auto-import.sh --print-config` prints DB/INPUT/REPORT/TIMEZONE/LOG/WATCH and
#   exits 0 with no side effects.
#
# ISOLATION (E1, E2). R_ENVIRON_USER (or ~/.Renviron) beats exported variables
# in R, and the live deployment's keys point at the live DB and the vault. Every
# child here is started with a CLEAN environment (like `env -i`): HOME is a
# temp dir, PATH is /usr/bin:/bin plus the stubs, and the only SAMPLETIDY_*
# variables are the ones a test names. No test starts an R child except the
# e2e one, which sets R_ENVIRON_USER to an empty file.

# ---- helpers -------------------------------------------------------------------------------

ac_dev <- function(...) normalizePath(testthat::test_path("..", "..", "dev", ...), mustWork = TRUE)

ac_skip <- function() {
  skip_on_os("windows")
  skip_if(Sys.which("bash") == "", "no bash")
}

#' A sandbox: HOME, a stub RSCRIPT (appends its environment's report dir to
#' runs.txt), stub NOTIFY, a fake DB, an input dir holding one file.
ac_sandbox <- function(env = parent.frame()) {
  ac_skip()
  d <- normalizePath(withr::local_tempdir(.local_envir = env))
  s <- list(dir = d, home = file.path(d, "home"), db = file.path(d, "monitoring.duckdb"),
            input = file.path(d, "assets"), code = file.path(d, "code"),
            log = file.path(d, "logs", "ai.log"), off = file.path(d, "off"),
            runs = file.path(d, "runs.txt"), notes = file.path(d, "notes.txt"),
            rscript = file.path(d, "stub-rscript.sh"), notify = file.path(d, "stub-notify.sh"))
  for (p in c(s$home, s$input, s$code)) dir.create(p, recursive = TRUE)
  writeLines("x", s$db)
  writeLines("x", file.path(s$input, "README.txt"))
  writeLines(c("#!/bin/bash",
               sprintf('echo "run|$SAMPLETIDY_AUTOIMPORT_REPORT" >> "%s"', s$runs),
               "exit 0"), s$rscript)
  writeLines(c("#!/bin/bash", sprintf('echo "$1|$2" >> "%s"', s$notes)), s$notify)
  Sys.chmod(c(s$rscript, s$notify), "755")
  s
}

#' Run dev/auto-import.sh in a clean environment. `env` is a named character
#' vector of the variables to set; HOME and PATH are always set.
ac_run <- function(s, args = character(), env = character()) {
  base <- c(HOME = s$home, PATH = "/usr/bin:/bin:/usr/sbin:/sbin")
  base <- base[setdiff(names(base), names(env))]
  processx::run("/bin/bash", c(ac_dev("auto-import.sh"), args),
                env = c(base, env), error_on_status = FALSE, timeout = 60)
}

#' The environment of a sandboxed run: the stubs, temp DB/input/report.
ac_env <- function(s, report, ...) {
  c(SAMPLETIDY_AUTOIMPORT_DB = s$db, SAMPLETIDY_AUTOIMPORT_INPUT = s$input,
    SAMPLETIDY_AUTOIMPORT_REPORT = report, SAMPLETIDY_AUTOIMPORT_RSCRIPT = s$rscript,
    SAMPLETIDY_AUTOIMPORT_CODE = s$code, SAMPLETIDY_AUTOIMPORT_LOG = s$log,
    SAMPLETIDY_AUTOIMPORT_OFF = s$off, SAMPLETIDY_AUTOIMPORT_NOTIFY = s$notify, ...)
}

#' Write an R user environ file; returns its path.
ac_environ <- function(s, lines, name = "environ") {
  p <- file.path(s$dir, name)
  writeLines(lines, p)
  p
}

#' `--print-config` parsed into a named list (KEY=value lines).
ac_print <- function(s, env = character(), environ_lines = character()) {
  env <- c(R_ENVIRON_USER = ac_environ(s, environ_lines), env)
  r <- ac_run(s, "--print-config", env)
  expect_identical(r$status, 0L, info = r$stderr)
  kv <- strsplit(strsplit(sub("\n$", "", r$stdout), "\n", fixed = TRUE)[[1]], "=", fixed = TRUE)
  out <- lapply(kv, function(x) paste(x[-1], collapse = "="))
  names(out) <- vapply(kv, `[`, "", 1L)
  out
}

ac_tree <- function(dir) {
  list.files(dir, recursive = TRUE, all.files = TRUE, include.dirs = TRUE, no.. = TRUE)
}

# ---- 1. --print-config -----------------------------------------------------------------------

test_that("--print-config prints the resolved values from the environ file, exits 0 and creates nothing", {
  s <- ac_sandbox()
  rep <- file.path(s$dir, "r d", "rep")
  p <- ac_print(s, environ_lines = c(
    "SAMPLETIDY_INPUT_DIR=/x/assets/input",
    sprintf("SAMPLETIDY_REPORT_DIR='%s'", rep),
    'SAMPLETIDY_TIMEZONE="Pacific/Auckland"'))
  expect_identical(p$INPUT, "/x/assets")
  expect_identical(p$REPORT, rep)
  expect_identical(p$TIMEZONE, "Pacific/Auckland")
  # PLAN-21 phase (a): WATCH (SAMPLETIDY_GATE_WATCH, empty when unset) is printed last.
  expect_identical(names(p), c("DB", "INPUT", "REPORT", "TIMEZONE", "LOG", "NOTIFY", "NOTIFY_FLUSH",
                               "WATCH"))
  expect_identical(p$WATCH, "")
  expect_identical(p$DB, file.path(s$home, "Library", "Application Support", "org.R-project.R",
                                   "R", "sampleTidy", "monitoring.duckdb"))
  expect_match(p$LOG, "sampletidy-autoimport.log$")
  # no side effects: HOME is still empty, and neither the report dir nor its parent exist
  expect_length(ac_tree(s$home), 0)
  expect_false(dir.exists(file.path(s$dir, "r d")))
  expect_false(dir.exists(file.path(s$dir, "logs")))
})

test_that("--print-config does no DB check, honours no off switch and takes no lock or log", {
  s <- ac_sandbox()
  file.create(s$off)
  rep <- file.path(s$dir, "rep")
  unlink(s$db)
  env <- ac_env(s, rep)
  r <- ac_run(s, "--print-config", c(R_ENVIRON_USER = ac_environ(s, character()), env))
  expect_identical(r$status, 0L)
  expect_match(r$stdout, paste0("REPORT=", rep), fixed = TRUE)
  expect_false(dir.exists(rep))
  expect_false(file.exists(s$log))
  expect_length(ac_tree(s$home), 0)
})

# ---- 2. precedence ----------------------------------------------------------------------------

test_that("REPORT: SAMPLETIDY_AUTOIMPORT_REPORT beats the env SAMPLETIDY_REPORT_DIR, which beats the file", {
  s <- ac_sandbox()
  f <- c("SAMPLETIDY_REPORT_DIR=/from/file")
  expect_identical(ac_print(s, environ_lines = f)$REPORT, "/from/file")
  expect_identical(ac_print(s, c(SAMPLETIDY_REPORT_DIR = "/from/env"), f)$REPORT, "/from/env")
  expect_identical(ac_print(s, c(SAMPLETIDY_REPORT_DIR = "/from/env",
                                 SAMPLETIDY_AUTOIMPORT_REPORT = "/from/override"), f)$REPORT,
                   "/from/override")
})

test_that("TIMEZONE: the env SAMPLETIDY_TIMEZONE beats the file", {
  s <- ac_sandbox()
  f <- "SAMPLETIDY_TIMEZONE=Pacific/Auckland"
  expect_identical(ac_print(s, environ_lines = f)$TIMEZONE, "Pacific/Auckland")
  expect_identical(ac_print(s, c(SAMPLETIDY_TIMEZONE = "Pacific/Pago_Pago"), f)$TIMEZONE,
                   "Pacific/Pago_Pago")
})

test_that("INPUT: the env SAMPLETIDY_INPUT_DIR beats the file; AUTOIMPORT_INPUT is used verbatim", {
  s <- ac_sandbox()
  f <- "SAMPLETIDY_INPUT_DIR=/from/file/input"
  expect_identical(ac_print(s, environ_lines = f)$INPUT, "/from/file")
  expect_identical(ac_print(s, c(SAMPLETIDY_INPUT_DIR = "/from/env/input"), f)$INPUT, "/from/env")
  # no parent rule for the override, and none for a folder not named `input`
  expect_identical(ac_print(s, c(SAMPLETIDY_AUTOIMPORT_INPUT = "/y/input",
                                 SAMPLETIDY_INPUT_DIR = "/from/env/input"), f)$INPUT, "/y/input")
  expect_identical(ac_print(s, c(SAMPLETIDY_INPUT_DIR = "/from/env/batches"), f)$INPUT,
                   "/from/env/batches")
})

test_that("DB: SAMPLETIDY_AUTOIMPORT_DB beats the default under HOME", {
  s <- ac_sandbox()
  expect_identical(ac_print(s, c(SAMPLETIDY_AUTOIMPORT_DB = "/the/db"))$DB, "/the/db")
})

# ---- 3. defaults ------------------------------------------------------------------------------

test_that("defaults with an empty environ file: REPORT under HOME's R data dir, TIMEZONE UTC, PKM_VAULT ignored", {
  s <- ac_sandbox()
  p <- ac_print(s, c(PKM_VAULT = "/vault"))
  expect_identical(p$REPORT, file.path(s$home, "Library", "Application Support",
                                       "org.R-project.R", "R", "sampleTidy", "reports"))
  expect_identical(p$TIMEZONE, "UTC")
  expect_false(grepl("vault", p$REPORT, fixed = TRUE))
})

# ---- 4. quoting -------------------------------------------------------------------------------

test_that("the environ file's quotes are stripped (one pair of ' or \"), and of two lines the last wins", {
  s <- ac_sandbox()
  for (line in c("SAMPLETIDY_REPORT_DIR='a b'", 'SAMPLETIDY_REPORT_DIR="a b"', "SAMPLETIDY_REPORT_DIR=a b")) {
    expect_identical(ac_print(s, environ_lines = line)$REPORT, "a b", info = line)
  }
  expect_identical(ac_print(s, environ_lines = c("SAMPLETIDY_REPORT_DIR=first",
                                                 "SAMPLETIDY_REPORT_DIR='second'"))$REPORT, "second")
  # no ${VAR} or ~ expansion
  expect_identical(ac_print(s, environ_lines = "SAMPLETIDY_REPORT_DIR=~/x")$REPORT, "~/x")
})

# ---- 5. the gate day ---------------------------------------------------------------------------

ac_gate_after <- function(s, zone, report) {
  r <- ac_run(s, env = ac_env(s, report, R_ENVIRON_USER = ac_environ(s, character()),
                              SAMPLETIDY_TIMEZONE = zone))
  expect_identical(r$status, 0L, info = paste(r$stdout, r$stderr))
  g <- file.path(report, ".imports.gate")
  expect_true(file.exists(g), info = zone)
  readLines(g, warn = FALSE)
}

test_that("the gate hashes the local day in SAMPLETIDY_TIMEZONE: Kiritimati and Pago_Pago differ, a repeat is equal", {
  s <- ac_sandbox()
  k1 <- ac_gate_after(s, "Pacific/Kiritimati", file.path(s$dir, "rep-k1"))
  k2 <- ac_gate_after(s, "Pacific/Kiritimati", file.path(s$dir, "rep-k2"))
  p1 <- ac_gate_after(s, "Pacific/Pago_Pago", file.path(s$dir, "rep-p1"))
  expect_identical(k1, k2)
  expect_false(identical(k1, p1))
  expect_length(readLines(s$runs), 3)
})

# ---- 6. the staleness key ----------------------------------------------------------------------

test_that("the staleness notification is keyed on the local day in SAMPLETIDY_TIMEZONE", {
  for (zone in c("Pacific/Kiritimati", "Pacific/Pago_Pago")) {
    s <- ac_sandbox()
    rep <- file.path(s$dir, "rep")
    dir.create(rep)
    old <- format(Sys.time() - 30 * 3600, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
    writeLines(sprintf('{"state":"done","pid":1,"started_at":"%s","ended_at":"%s","rc":0,"last_success_at":"%s"}',
                       old, old, old), file.path(rep, ".imports.health"))
    before <- format(Sys.time(), "%F", tz = zone)
    r <- ac_run(s, env = ac_env(s, rep, R_ENVIRON_USER = ac_environ(s, character()),
                                SAMPLETIDY_TIMEZONE = zone))
    after <- format(Sys.time(), "%F", tz = zone)
    expect_identical(r$status, 0L, info = paste(r$stdout, r$stderr))
    keys <- readLines(file.path(rep, ".imports.notified"), warn = FALSE)
    stale <- keys[startsWith(keys, "stale:")]
    expect_length(stale, 1)
    expect_true(stale %in% paste0("stale:", unique(c(before, after))), info = paste(zone, stale))
    expect_length(readLines(s$notes), 1)
  }
})

# ---- 7. launcher conditions ---------------------------------------------------------------------

test_that("under launchd's conditions the script finds its input, report dir and zone in HOME/.Renviron", {
  s <- ac_sandbox()
  rep <- file.path(s$dir, "the report dir")
  writeLines(c(sprintf("SAMPLETIDY_INPUT_DIR=%s", file.path(s$input, "input")),
               sprintf("SAMPLETIDY_REPORT_DIR='%s'", rep),
               "SAMPLETIDY_TIMEZONE='Pacific/Kiritimati'"), file.path(s$home, ".Renviron"))
  # only the stub overrides: no AUTOIMPORT_INPUT/_REPORT, no R_ENVIRON_USER
  env <- c(SAMPLETIDY_AUTOIMPORT_DB = s$db, SAMPLETIDY_AUTOIMPORT_RSCRIPT = s$rscript,
           SAMPLETIDY_AUTOIMPORT_CODE = s$code, SAMPLETIDY_AUTOIMPORT_LOG = s$log,
           SAMPLETIDY_AUTOIMPORT_NOTIFY = s$notify)
  r <- ac_run(s, env = env)
  expect_identical(r$status, 0L, info = paste(r$stdout, r$stderr))
  expect_identical(readLines(s$runs), paste0("run|", rep))
  expect_true(file.exists(file.path(rep, ".imports.health")))
  expect_true(file.exists(file.path(rep, ".imports.gate")))
  expect_false(dir.exists(file.path(s$home, "Library")))
})

# ---- 8. static checks ---------------------------------------------------------------------------

test_that("the auto-import scripts, the launchd files and the launcher name no deployment", {
  files <- c(ac_dev("auto-import.sh"), ac_dev("auto-import.R"), ac_dev("auto-import.cmd"),
             ac_dev("auto-import-gate.ps1"), ac_dev("auto-import.ps1"),
             ac_dev("launchd", "install.sh"),
             ac_dev("launchd", "net.robinshannon.sampletidy-autoimport.plist"),
             ac_dev("launchd", "helper", "launcher.c"))
  deny <- c("australia/sydney", "aus eastern", "pkm_vault", "\\bpkm\\b", "import triage",
            "onedrive", "obsidian", "\\brobin\\b", "sharepoint")
  for (f in files) {
    txt <- readLines(f, warn = FALSE)
    txt <- gsub("net.robinshannon.sampletidy-autoimport", "", txt, fixed = TRUE)
    for (pat in deny) {
      hit <- grep(pat, txt, ignore.case = TRUE, perl = TRUE)
      if (length(hit)) {
        fail(sprintf("%s:%d matches %s: %s", basename(f), hit[[1]], pat, trimws(txt[[hit[[1]]]])))
      } else {
        succeed()
      }
    }
  }
})

# ---- 9. the Windows gate, under pwsh -------------------------------------------------------------

ac_gate_hash <- function(s, ..., tz = NULL) {
  args <- c("-NoProfile", "-File", ac_dev("auto-import-gate.ps1"),
            "-Input", s$input, "-Db", s$db)
  if (!is.null(tz)) args <- c(args, "-TimeZone", tz)
  r <- processx::run(Sys.which("pwsh"), args,
                     env = c(HOME = s$home, PATH = "/usr/bin:/bin", POWERSHELL_TELEMETRY_OPTOUT = "1",
                             DOTNET_CLI_TELEMETRY_OPTOUT = "1"),
                     error_on_status = FALSE, timeout = 120)
  expect_identical(r$status, 0L, info = r$stderr)
  trimws(r$stdout)
}

test_that("auto-import-gate.ps1 -TimeZone: UTC equals the default, zones differ, an unknown zone is the local zone", {
  skip_if(Sys.which("pwsh") == "", "no pwsh")
  s <- ac_sandbox()
  default <- ac_gate_hash(s)
  utc <- ac_gate_hash(s, tz = "UTC")
  expect_match(utc, "^[0-9a-f]{64}$")
  expect_identical(utc, default)
  expect_false(identical(ac_gate_hash(s, tz = "Pacific/Kiritimati"),
                         ac_gate_hash(s, tz = "Pacific/Pago_Pago")))
  loc <- processx::run(Sys.which("pwsh"), c("-NoProfile", "-Command", "[TimeZoneInfo]::Local.Id"),
                       env = c(HOME = s$home, PATH = "/usr/bin:/bin"), error_on_status = FALSE)
  local_id <- trimws(loc$stdout)
  expect_true(nzchar(local_id))
  expect_identical(ac_gate_hash(s, tz = "Not/AZone"), ac_gate_hash(s, tz = local_id))
})

# ---- 14. auto-import.R end to end -----------------------------------------------------------------

test_that("auto-import.R writes status.json into st_config('report_dir') when run by hand", {
  skip_on_cran()
  skip_if_not(dir.exists(ac_dev()), "no dev/ (installed package)")
  skip_if_not_installed("devtools")
  s <- inbox_setup()
  d <- withr::local_tempdir()
  empty <- file.path(d, "empty-environ")
  file.create(empty)
  rep <- file.path(d, "rep")
  hooks <- file.path(d, "hooks.R")
  writeLines("invisible(NULL)", hooks)
  # HOME is a temp dir and PKM_VAULT is unset, so that code which still looked
  # for a vault under HOME could never reach a real report directory.
  home <- file.path(d, "home")
  dir.create(home)
  withr::local_envvar(c(
    HOME = home, PKM_VAULT = NA, R_LIBS = paste(.libPaths(), collapse = ":"), R_ENVIRON_USER = empty, R_PROFILE_USER = empty,
    SAMPLETIDY_AUTOIMPORT_DB = s$db, SAMPLETIDY_AUTOIMPORT_INPUT = s$input_dir,
    SAMPLETIDY_AUTOIMPORT_REPORT = NA, SAMPLETIDY_AUTOIMPORT_PREV_FAILURE = "",
    SAMPLETIDY_AUTOIMPORT_LEDGER = file.path(d, "no-ledger.json"),
    SAMPLETIDY_AUTOIMPORT_LICENCE_DIR = d,
    SAMPLETIDY_REPORT_DIR = rep,
    SAMPLETIDY_ARCHIVE_DIR = s$archive_dir, SAMPLETIDY_SNAPSHOT_DIR = s$snapshot_dir,
    SAMPLETIDY_INPUT_DIR = s$input_dir, SAMPLETIDY_HOOKS_FILE = hooks))
  out <- suppressWarnings(system2(file.path(R.home("bin"), "Rscript"),
                                  shQuote(ac_dev("auto-import.R")), stdout = TRUE, stderr = TRUE))
  expect_identical(attr(out, "status") %||% 0L, 0L, info = paste(out, collapse = "\n"))
  expect_true(file.exists(file.path(rep, "status.json")), info = paste(out, collapse = "\n"))
})

test_that("auto-import.R reads its report dir from st_config('report_dir'), not from PKM_VAULT", {
  skip_if_not(file.exists(ac_dev("auto-import.R")))
  txt <- paste(readLines(ac_dev("auto-import.R"), warn = FALSE), collapse = "\n")
  expect_true(grepl('st_config("report_dir")', txt, fixed = TRUE))
  expect_false(grepl("PKM_VAULT", txt, fixed = TRUE))
})

# ---- 6. R's ${VAR} forms in the environ file (helper-renviron-forms.R) ---------------------------
# A line written the way R itself reads it, `KEY=${KEY-'value'}`, must give the value R gives it,
# not the literal text (found live: a notify command was logged "not executable").

test_that("R itself gives the values the table in helper-renviron-forms.R says (the oracle)", {
  skip_on_os("windows")
  skip_if(Sys.which("Rscript") == "", "no Rscript")
  for (f in rf_forms) {
    expect_identical(rf_r_value(paste0(rf_key, "=", f[[1]]), f[[2]]), f[[3]],
                     info = sprintf("%s with VAR=%s", f[[1]], format(f[[2]])))
  }
})

test_that("the environ file's ${VAR}, ${VAR-default} and ${VAR:-default} give the value R gives (NOTIFY)", {
  s <- ac_sandbox()
  for (f in rf_forms) {
    p <- ac_print(s, env = rf_env(f[[2]]), environ_lines = paste0(rf_key, "=", f[[1]]))
    expect_identical(p$NOTIFY, f[[3]], info = sprintf("%s with VAR=%s", f[[1]], format(f[[2]])))
  }
})

test_that("R's own `KEY=${KEY-'value'}` form works for every key the trigger reads from the file", {
  s <- ac_sandbox()
  mk <- function(k, v) sprintf("%s=${%s-'%s'}", k, k, v)
  p <- ac_print(s, environ_lines = c(
    mk("SAMPLETIDY_INPUT_DIR", "/b c/input"), mk("SAMPLETIDY_REPORT_DIR", "/r d/rep"),
    mk("SAMPLETIDY_TIMEZONE", "Pacific/Auckland"), mk("SAMPLETIDY_NOTIFY_COMMAND", "/n o/notify"),
    mk("SAMPLETIDY_NOTIFY_FLUSH", "/n o/flush"), mk("SAMPLETIDY_GATE_WATCH", "/w x/watch")))
  expect_identical(p$INPUT, "/b c")                  # a folder named `input` is replaced by its parent
  expect_identical(p$REPORT, "/r d/rep")
  expect_identical(p$TIMEZONE, "Pacific/Auckland")
  expect_identical(p$NOTIFY, "/n o/notify")
  expect_identical(p$NOTIFY_FLUSH, "/n o/flush")
  expect_identical(p$WATCH, "/w x/watch")
})

test_that("`KEY=${KEY-'value'}` with KEY already set in the process environment is that value", {
  s <- ac_sandbox()
  p <- ac_print(s, env = c(SAMPLETIDY_NOTIFY_COMMAND = "/from/env"),
                environ_lines = "SAMPLETIDY_NOTIFY_COMMAND=${SAMPLETIDY_NOTIFY_COMMAND-'/from/file'}")
  expect_identical(p$NOTIFY, "/from/env")
})

test_that("a ${VAR} may name a key set on an earlier line of the same file, as in R", {
  s <- ac_sandbox()
  lines <- c("SAMPLETIDY_REPORT_DIR=/r/rep", "SAMPLETIDY_NOTIFY_COMMAND=${SAMPLETIDY_REPORT_DIR}/notify")
  expect_identical(ac_print(s, environ_lines = lines)$NOTIFY, "/r/rep/notify")
  skip_if(Sys.which("Rscript") == "", "no Rscript")
  expect_identical(rf_r_value(lines), "/r/rep/notify")
})
