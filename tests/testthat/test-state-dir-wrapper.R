# SAMPLETIDY_STATE_DIR, the launcher half (dev/auto-import.sh; see test-state-dir.R for the
# R half and the full design). The wrapper writes four of the eight machine-state files
# (.imports.lock, .imports.gate, .imports.health, .imports.notified) and hands the folder
# to the R job. Pinned here, with a stub RSCRIPT and temp dirs (no R, no DB work):
#   * STATE_DIR resolves like REPORT does: $SAMPLETIDY_STATE_DIR, else the line in R's user
#     environ file; unset, it is the report dir (nothing changes until the setting is made).
#     `--print-config` prints it as the last line, `STATE=`.
#   * the four wrapper files live in STATE_DIR and not in REPORT when it is set; in REPORT
#     when it is unset.
#   * the resolved folder is exported to the R job as SAMPLETIDY_STATE_DIR when set.
#   * the lock a held run leaves is exactly st_imports_lock_path(report_dir), so a live
#     holder there makes the wrapper skip, under both configurations.
#   * dev/auto-import.sh and dev/auto-import.ps1 never build a .imports.* path from REPORT.
# The Windows launcher's behaviour is not run here (no PowerShell in this suite); it is
# pinned by the source guard at the end and by the existing windows parity tests.

sdw_sandbox <- function(env = parent.frame()) {
  skip_on_os("windows")
  skip_if(Sys.which("bash") == "")
  d <- normalizePath(withr::local_tempdir(.local_envir = env))
  s <- list(dir = d, home = file.path(d, "home"), db = file.path(d, "monitoring.duckdb"),
            input = file.path(d, "assets"), code = file.path(d, "code"),
            report = file.path(d, "report"), state = file.path(d, "state"),
            log = file.path(d, "logs", "ai.log"), off = file.path(d, "off"),
            runs = file.path(d, "runs.txt"), notes = file.path(d, "notes.txt"),
            rscript = file.path(d, "stub-rscript.sh"), notify = file.path(d, "stub-notify.sh"),
            environ = file.path(d, "environ"))
  for (p in c(s$home, s$input, s$code)) dir.create(p, recursive = TRUE)
  file.create(s$environ)
  writeLines("x", s$db)
  writeLines("x", file.path(s$input, "README.txt"))
  # The stub records, while "running": the state dir it was told, and which of the two folders
  # holds the lock directory.
  writeLines(c("#!/bin/bash",
               sprintf('echo "run|state=${SAMPLETIDY_STATE_DIR:-}|lock_in_state=$([ -d "%s/.imports.lock" ] && echo 1 || echo 0)|lock_in_report=$([ -d "%s/.imports.lock" ] && echo 1 || echo 0)" >> "%s"',
                       s$state, s$report, s$runs),
               'exit "${STUB_RC:-0}"'), s$rscript)
  writeLines(c("#!/bin/bash", sprintf('echo "$1|$2" >> "%s"', s$notes)), s$notify)
  Sys.chmod(c(s$rscript, s$notify), "755")
  s
}

sdw_env <- function(s, ...) {
  c(SAMPLETIDY_AUTOIMPORT_DB = s$db, SAMPLETIDY_AUTOIMPORT_INPUT = s$input,
    SAMPLETIDY_AUTOIMPORT_REPORT = s$report, SAMPLETIDY_AUTOIMPORT_RSCRIPT = s$rscript,
    SAMPLETIDY_AUTOIMPORT_CODE = s$code, SAMPLETIDY_AUTOIMPORT_LOG = s$log,
    SAMPLETIDY_AUTOIMPORT_OFF = s$off, SAMPLETIDY_AUTOIMPORT_NOTIFY = s$notify,
    R_ENVIRON_USER = s$environ, ...)
}

sdw_run <- function(s, args = character(), env = character()) {
  base <- c(HOME = s$home, PATH = "/usr/bin:/bin:/usr/sbin:/sbin")
  base <- base[setdiff(names(base), names(env))]
  processx::run("/bin/bash",
                c(normalizePath(testthat::test_path("..", "..", "dev", "auto-import.sh"), mustWork = TRUE), args),
                env = c(base, env), error_on_status = FALSE, timeout = 60)
}

sdw_ls <- function(d) {
  if (!dir.exists(d)) return(character())
  sort(list.files(d, all.files = TRUE, no.. = TRUE))
}

WRAPPER_FILES <- c(".imports.lock", ".imports.gate", ".imports.health", ".imports.notified")

# ---- --print-config ---------------------------------------------------------------------

test_that("--print-config: STATE is the report dir when unset, the env var or the environ-file line when set", {
  s <- sdw_sandbox()
  kv <- function(r) {
    expect_identical(r$status, 0L, info = r$stderr)
    x <- strsplit(strsplit(sub("\n$", "", r$stdout), "\n", fixed = TRUE)[[1]], "=", fixed = TRUE)
    stats::setNames(lapply(x, function(y) paste(y[-1], collapse = "=")), vapply(x, `[`, "", 1L))
  }
  p <- kv(sdw_run(s, "--print-config", sdw_env(s)))
  expect_identical(p$STATE, s$report)
  expect_identical(names(p)[length(p)], "STATE")
  p <- kv(sdw_run(s, "--print-config", sdw_env(s, SAMPLETIDY_STATE_DIR = s$state)))
  expect_identical(p$STATE, s$state)
  writeLines(sprintf("SAMPLETIDY_STATE_DIR='%s'", s$state), s$environ)
  p <- kv(sdw_run(s, "--print-config", sdw_env(s)))
  expect_identical(p$STATE, s$state)
  # no side effects
  expect_false(dir.exists(s$state))
})

# ---- a run with the state dir set ---------------------------------------------------------

test_that("state dir set: a good run puts the gate and health record in the state dir, nothing of the eight in the report dir", {
  s <- sdw_sandbox()
  r <- sdw_run(s, env = sdw_env(s, SAMPLETIDY_STATE_DIR = s$state))
  expect_identical(r$status, 0L, info = r$stderr)
  expect_true(all(c(".imports.gate", ".imports.health") %in% sdw_ls(s$state)))
  expect_false(dir.exists(file.path(s$state, ".imports.lock")))   # released at the end
  expect_length(intersect(sdw_ls(s$report), c(WRAPPER_FILES, ".imports.state", ".imports.log",
                                              "events.jsonl", "status.json")), 0L)
})

test_that("state dir set: the lock is taken in the state dir (not the report dir) and the R job is told the state dir", {
  s <- sdw_sandbox()
  sdw_run(s, env = sdw_env(s, SAMPLETIDY_STATE_DIR = s$state))
  line <- readLines(s$runs)
  expect_length(line, 1L)
  expect_match(line, paste0("state=", s$state), fixed = TRUE)
  expect_match(line, "lock_in_state=1", fixed = TRUE)
  expect_match(line, "lock_in_report=0", fixed = TRUE)
})

test_that("state dir set: a failed run then a retry notifies once, recorded in the state dir's .imports.notified", {
  s <- sdw_sandbox()
  env <- sdw_env(s, SAMPLETIDY_STATE_DIR = s$state, STUB_RC = "1")
  sdw_run(s, env = env)
  sdw_run(s, env = env)
  expect_true(".imports.notified" %in% sdw_ls(s$state))
  expect_false(".imports.notified" %in% sdw_ls(s$report))
  expect_length(readLines(s$notes), 1L)
})

test_that("state dir set: a live holder of st_imports_lock_path() makes the wrapper skip", {
  s <- sdw_sandbox()
  withr::local_options(sampletidy.state_dir = NULL)
  withr::local_envvar(SAMPLETIDY_STATE_DIR = s$state)
  lock <- st_imports_lock_path(s$report)
  expect_identical(lock, file.path(s$state, ".imports.lock"))
  dir.create(lock, recursive = TRUE)
  writeLines(as.character(Sys.getpid()), file.path(lock, "pid"))
  r <- sdw_run(s, env = sdw_env(s, SAMPLETIDY_STATE_DIR = s$state))
  expect_identical(r$status, 0L)
  expect_false(file.exists(s$runs))                 # the job never ran
  expect_match(paste(readLines(s$log), collapse = "\n"), "already in progress")
})

# ---- a run with the state dir unset: as today --------------------------------------------

test_that("state dir unset: the wrapper's files are all in the report dir, as today", {
  s <- sdw_sandbox()
  env <- sdw_env(s, STUB_RC = "1")
  sdw_run(s, env = env)
  sdw_run(s, env = env)
  expect_true(all(c(".imports.health", ".imports.notified") %in% sdw_ls(s$report)))
  sdw_run(s, env = sdw_env(s))   # a good run writes the gate
  expect_true(".imports.gate" %in% sdw_ls(s$report))
  expect_false(dir.exists(s$state))
  line <- readLines(s$runs)
  expect_true(all(grepl("lock_in_report=1", line, fixed = TRUE)))
  expect_true(all(grepl("lock_in_state=0", line, fixed = TRUE)))
})

test_that("state dir unset: a live holder of st_imports_lock_path() (in the report dir) makes the wrapper skip", {
  s <- sdw_sandbox()
  withr::local_options(sampletidy.state_dir = NULL)
  withr::local_envvar(SAMPLETIDY_STATE_DIR = NA)
  lock <- st_imports_lock_path(s$report)
  expect_identical(lock, file.path(s$report, ".imports.lock"))
  dir.create(lock, recursive = TRUE)
  writeLines(as.character(Sys.getpid()), file.path(lock, "pid"))
  r <- sdw_run(s, env = sdw_env(s))
  expect_identical(r$status, 0L)
  expect_false(file.exists(s$runs))
  expect_match(paste(readLines(s$log), collapse = "\n"), "already in progress")
})

# ---- source guard: the launchers --------------------------------------------------------

test_that("neither launcher builds an .imports.* path from the report dir", {
  for (f in c("auto-import.sh", "auto-import.ps1")) {
    p <- testthat::test_path("..", "..", "dev", f)
    skip_if_not(file.exists(p))
    code <- grep("^\\s*#", readLines(p, warn = FALSE), value = TRUE, invert = TRUE)
    hits <- grep("\\.imports\\.", code, value = TRUE)
    expect_gt(length(hits), 0L, label = paste(f, "names the state files"))
    bad <- grep("REPORT", hits, value = TRUE)
    expect_length(bad, 0L)
  }
})
