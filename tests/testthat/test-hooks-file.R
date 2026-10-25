# Site hooks file (PLAN-20 follow-on, 2026-10-25): a generic way for a
# deployment to register hooks without the package knowing anything about it.
#
# Spec (this file is the spec):
#
#   load_hooks_file(path = Sys.getenv("SAMPLETIDY_HOOKS_FILE"))   # EXPORTED
#
#   * `path` "" (the env var unset or empty) -> a no-op: nothing is sourced,
#     nothing is registered, nothing is recorded; returns character(0)
#     invisibly.
#   * Otherwise the file is sourced into a NEW environment whose parent is
#     globalenv() (so the attached package's exports, e.g. register_hook(),
#     are visible unqualified). Its top-level assignments do not land in
#     globalenv(); closures it registers keep that environment, so a hook can
#     call helpers the file defines when the hook fires later. The file is
#     expected to call register_hook(); the usual registry semantics apply.
#   * It NEVER errors (a warning is allowed). On a missing file it records and
#     returns (invisibly) exactly
#         "hooks file <path> not found"
#     and when sourcing errors, exactly
#         "hooks file <path> failed: <conditionMessage>"
#     with <path> as given. On success it returns character(0) invisibly.
#   * A recorded problem is session state, like the hooks: it appears in the
#     Problems of every status inbox_run() writes afterwards in the session
#     (status.json, .import-status.json and the "Import status.md" note), on a
#     full run and on action "status", AFTER the log-derived problems and
#     BEFORE this run's own hook failures. It is not a run error (not in
#     inbox_run()'s `errors`) and is never written to events.jsonl or
#     .imports.log.
#   * Each load_hooks_file() call REPLACES the recorded problems (a successful
#     or no-op call clears them); clear_hooks() with no argument clears them
#     too. clear_hooks(event) does not.
#
#   dev/auto-import.R calls load_hooks_file() after the package is loaded and
#   before inbox_run(), so a site sets SAMPLETIDY_HOOKS_FILE in the launchd
#   job's environment to attach its hooks to the live import.

# ---- helpers ---------------------------------------------------------------------------

hf_clean <- function(env = parent.frame()) {
  clear_hooks()
  withr::defer(clear_hooks(), envir = env)
  invisible(NULL)
}

# Write `lines` to a fresh .R file in a temp dir; returns its path.
hf_file <- function(lines, env = parent.frame()) {
  d <- withr::local_tempdir(.local_envir = env)
  p <- file.path(d, "site-hooks.R")
  writeLines(lines, p)
  p
}

# A hooks file whose after_run hook writes `res$action` (or a helper's value)
# to the file named by HF_MARKER.
hf_marker_lines <- c(
  'hf_leak_probe <- 42',
  'hf_helper <- function(res) paste0("fired:", res$action)',
  'register_hook("after_run", function(res) writeLines(hf_helper(res), Sys.getenv("HF_MARKER")))'
)

hf_load <- function(...) suppressWarnings(suppressMessages(withVisible(load_hooks_file(...))))

hf_json_problems <- function(report_dir, file = "status.json") {
  p <- file.path(report_dir, file)
  if (!file.exists(p)) return(character(0))
  as.character(unlist(jsonlite::fromJSON(p, simplifyVector = FALSE)$problems))
}

hf_dev_file <- function(...) testthat::test_path("..", "..", "dev", ...)

# ---- the loader ------------------------------------------------------------------------

test_that("hooks file: load_hooks_file is exported", {
  expect_true("load_hooks_file" %in% getNamespaceExports("sampleTidy"))
  expect_identical(formals(load_hooks_file)$path, quote(Sys.getenv("SAMPLETIDY_HOOKS_FILE")))
})

test_that("hooks file: unset or empty SAMPLETIDY_HOOKS_FILE is a no-op returning character(0) invisibly", {
  hf_clean()
  for (v in list(NA, "")) {
    withr::local_envvar(SAMPLETIDY_HOOKS_FILE = v)
    got <- expect_no_error(hf_load())
    expect_false(got$visible)
    expect_identical(got$value, character(0))
    for (ev in names(hooks())) expect_length(hooks(ev), 0)
  }
  got <- expect_no_error(hf_load(""))
  expect_identical(got$value, character(0))
})

test_that("hooks file: the env var names the file by default; its register_hook() calls take effect", {
  hf_clean()
  p <- hf_file(c(
    'register_hook("after_run", function(res) NULL)',
    'register_hook("work_complete", function(cw) NULL)'
  ))
  withr::local_envvar(SAMPLETIDY_HOOKS_FILE = p)
  got <- hf_load()
  expect_false(got$visible)
  expect_identical(got$value, character(0))
  expect_length(hooks("after_run"), 1)
  expect_length(hooks("work_complete"), 1)
  expect_length(hooks("after_status"), 0)
})

test_that("hooks file: an explicit path wins over the env var", {
  hf_clean()
  a <- hf_file('register_hook("after_run", function(res) "a")')
  b <- hf_file(c('register_hook("after_status", function(st) "b")'))
  withr::local_envvar(SAMPLETIDY_HOOKS_FILE = a)
  hf_load(b)
  expect_length(hooks("after_run"), 0)
  expect_length(hooks("after_status"), 1)
})

test_that("hooks file: it is sourced into its own environment - top-level assignments do not reach globalenv()", {
  hf_clean()
  withr::defer(if (exists("hf_leak_probe", envir = globalenv(), inherits = FALSE))
    rm("hf_leak_probe", envir = globalenv()))
  p <- hf_file(hf_marker_lines)
  hf_load(p)
  expect_false(exists("hf_leak_probe", envir = globalenv(), inherits = FALSE))
  expect_false(exists("hf_helper", envir = globalenv(), inherits = FALSE))
  fn <- hooks("after_run")[[1]]
  e <- environment(fn)
  expect_false(identical(e, globalenv()))
  expect_identical(get("hf_leak_probe", envir = e, inherits = FALSE), 42)
  expect_identical(parent.env(e), globalenv())
})

test_that("hooks file: a missing file never errors; returns and records 'hooks file <path> not found'; registers nothing", {
  hf_clean()
  p <- file.path(withr::local_tempdir(), "no-such-hooks.R")
  got <- expect_no_error(hf_load(p))
  expect_false(got$visible)
  expect_identical(got$value, sprintf("hooks file %s not found", p))
  for (ev in names(hooks())) expect_length(hooks(ev), 0)
})

test_that("hooks file: a file whose sourcing errors never errors; returns 'hooks file <path> failed: <msg>'", {
  hf_clean()
  p <- hf_file(c('x <- 1', 'stop("deliberate hooks-file failure")'))
  got <- expect_no_error(hf_load(p))
  expect_false(got$visible)
  expect_identical(got$value, sprintf("hooks file %s failed: deliberate hooks-file failure", p))
})

test_that("hooks file: a parse error is a failure too, not an abort", {
  hf_clean()
  p <- hf_file('register_hook("after_run", function(res) {')
  got <- expect_no_error(hf_load(p))
  expect_length(got$value, 1)
  expect_true(startsWith(got$value, sprintf("hooks file %s failed: ", p)))
})

# ---- inside inbox_run() ----------------------------------------------------------------

test_that("hooks file: hooks it registers fire on the next inbox_run(), with helpers from the file in scope", {
  hf_clean()
  s <- inbox_setup()
  marker <- file.path(withr::local_tempdir(), "marker.txt")
  withr::local_envvar(HF_MARKER = marker)
  hf_load(hf_file(hf_marker_lines))
  res <- run_inbox(s, now = sydney_midday())
  expect_identical(res$action, "run")
  expect_true(file.exists(marker))
  expect_identical(readLines(marker), "fired:run")
})

test_that("hooks file: a missing file's problem is in status.json, .import-status.json and the status note's Problems; the run still runs", {
  hf_clean()
  s <- inbox_setup()
  local_db_checks_pass()
  p <- file.path(withr::local_tempdir(), "no-such-hooks.R")
  hf_load(p)
  res <- expect_no_error(run_inbox(s, now = sydney_midday()))
  expect_true(res$ran)
  want <- sprintf("hooks file %s not found", p)
  expect_true(want %in% hf_json_problems(s$report_dir))
  expect_true(want %in% hf_json_problems(s$report_dir, ".import-status.json"))
  prob <- md_section(read_status_note(s$report_dir), "Problems")
  expect_true(any(grepl(want, prob, fixed = TRUE)))
  expect_identical(res$errors, character(0))
})

test_that("hooks file: a failing file's problem reaches the status; it is not a run error and is not logged", {
  hf_clean()
  s <- inbox_setup()
  local_db_checks_pass()
  p <- hf_file('stop("deliberate hooks-file failure")')
  hf_load(p)
  res <- expect_no_error(run_inbox(s, now = sydney_midday()))
  want <- sprintf("hooks file %s failed: deliberate hooks-file failure", p)
  expect_true(want %in% hf_json_problems(s$report_dir))
  expect_identical(res$errors, character(0))
  for (f in c(".imports.log", "events.jsonl")) {
    p_log <- file.path(s$report_dir, f)
    if (file.exists(p_log)) {
      expect_false(any(grepl("hooks file", readLines(p_log, warn = FALSE), fixed = TRUE)), info = f)
    }
  }
})

test_that("hooks file: the problem comes before this run's own hook failures", {
  hf_clean()
  s <- inbox_setup()
  local_db_checks_pass()
  p <- hf_file(c(
    'register_hook("after_run", function(res) stop("boom-after-run"))',
    'stop("deliberate hooks-file failure")'
  ))
  hf_load(p)
  run_inbox(s, now = sydney_midday())
  pr <- hf_json_problems(s$report_dir)
  i_file <- which(pr == sprintf("hooks file %s failed: deliberate hooks-file failure", p))
  i_hook <- which(pr == "hook after_run[1] failed: boom-after-run")
  expect_length(i_file, 1)
  expect_length(i_hook, 1)
  expect_lt(i_file, i_hook)
})

test_that("hooks file: the recorded problem persists for the session (action 'status' too) until clear_hooks()", {
  hf_clean()
  s <- inbox_setup()
  local_db_checks_pass()
  now <- sydney_midday()
  p <- file.path(withr::local_tempdir(), "no-such-hooks.R")
  want <- sprintf("hooks file %s not found", p)
  hf_load(p)
  run_inbox(s, now = now)
  expect_true(want %in% hf_json_problems(s$report_dir))

  Sys.setFileTime(s$db, Sys.time() + 120)          # only the DB stat changed -> "status"
  res <- run_inbox(s, now = now)
  expect_identical(res$action, "status")
  expect_true(want %in% hf_json_problems(s$report_dir))

  clear_hooks("after_run")                         # one event: the problem stays
  Sys.setFileTime(s$db, Sys.time() + 240)
  run_inbox(s, now = now)
  expect_true(want %in% hf_json_problems(s$report_dir))

  clear_hooks()                                    # all: the problem goes
  Sys.setFileTime(s$db, Sys.time() + 360)
  res <- run_inbox(s, now = now)
  expect_identical(res$action, "status")
  expect_false(any(startsWith(hf_json_problems(s$report_dir), "hooks file ")))
})

test_that("hooks file: a later successful (or no-op) load replaces the recorded problem", {
  hf_clean()
  s <- inbox_setup()
  local_db_checks_pass()
  hf_load(file.path(withr::local_tempdir(), "no-such-hooks.R"))
  got <- hf_load(hf_file('register_hook("after_run", function(res) NULL)'))
  expect_identical(got$value, character(0))
  run_inbox(s, now = sydney_midday())
  expect_false(any(startsWith(hf_json_problems(s$report_dir), "hooks file ")))

  hf_clean()
  hf_load(file.path(withr::local_tempdir(), "no-such-hooks.R"))
  hf_load("")
  Sys.setFileTime(s$db, Sys.time() + 120)
  run_inbox(s, now = sydney_midday())
  expect_false(any(startsWith(hf_json_problems(s$report_dir), "hooks file ")))
})

test_that("hooks file: with no hooks file loaded the status carries no 'hooks file' problem", {
  hf_clean()
  s <- inbox_setup()
  local_db_checks_pass()
  run_inbox(s, now = sydney_midday())
  expect_false(any(startsWith(hf_json_problems(s$report_dir), "hooks file ")))
})

# ---- dev/auto-import.R -----------------------------------------------------------------

test_that("hooks file: dev/auto-import.R calls load_hooks_file() after loading the package and before inbox_run()", {
  skip_if_not(dir.exists(hf_dev_file()), "no dev/ (installed package)")
  src <- readLines(hf_dev_file("auto-import.R"), warn = FALSE)
  code <- sub("#.*$", "", src)                     # ignore comments
  i_load <- grep("load_all\\(", code)
  i_hooks <- grep("load_hooks_file\\(", code)
  i_run <- grep("inbox_run\\(", code)
  expect_length(i_hooks, 1)
  expect_true(length(i_load) >= 1 && length(i_run) == 1)
  expect_gt(i_hooks, max(i_load))
  expect_lt(i_hooks, i_run)
  # documented where the deployment reads it
  expect_true(any(grepl("SAMPLETIDY_HOOKS_FILE", src, fixed = TRUE)))
})

# End to end: run dev/auto-import.R under Rscript against a scratch DB, inbox and
# report dir, with SAMPLETIDY_HOOKS_FILE set.
hf_run_auto_import <- function(s, hooks_file, extra_env = character(0), env = parent.frame()) {
  scratch <- withr::local_tempdir(.local_envir = env)
  envs <- c(
    SAMPLETIDY_AUTOIMPORT_DB = s$db,
    SAMPLETIDY_AUTOIMPORT_INPUT = s$input_dir,
    SAMPLETIDY_AUTOIMPORT_REPORT = s$report_dir,
    SAMPLETIDY_AUTOIMPORT_LEDGER = file.path(scratch, "no-ledger.json"),
    SAMPLETIDY_AUTOIMPORT_LICENCE_DIR = scratch,
    SAMPLETIDY_AUTOIMPORT_PREV_FAILURE = "",
    SAMPLETIDY_ARCHIVE_DIR = s$archive_dir,
    SAMPLETIDY_SNAPSHOT_DIR = s$snapshot_dir,
    SAMPLETIDY_INPUT_DIR = s$input_dir,
    SAMPLETIDY_HOOKS_FILE = hooks_file,
    extra_env
  )
  withr::local_envvar(envs)
  out <- suppressWarnings(system2(file.path(R.home("bin"), "Rscript"),
                                  shQuote(normalizePath(hf_dev_file("auto-import.R"))),
                                  stdout = TRUE, stderr = TRUE))
  list(status = attr(out, "status") %||% 0L, out = out)
}

test_that("hooks file e2e: dev/auto-import.R sources SAMPLETIDY_HOOKS_FILE and its after_run hook fires on the live-style run", {
  skip_on_cran()
  skip_if_not(dir.exists(hf_dev_file()), "no dev/ (installed package)")
  skip_if_not_installed("devtools")
  s <- inbox_setup()
  marker <- file.path(withr::local_tempdir(), "marker.txt")
  r <- hf_run_auto_import(s, hf_file(hf_marker_lines), c(HF_MARKER = marker))
  expect_identical(r$status, 0L, info = paste(r$out, collapse = "\n"))
  expect_true(file.exists(marker), info = paste(r$out, collapse = "\n"))
  expect_identical(readLines(marker), "fired:run")
})

test_that("hooks file e2e: a failing hooks file does not stop dev/auto-import.R; the failure is in status.json's problems", {
  skip_on_cran()
  skip_if_not(dir.exists(hf_dev_file()), "no dev/ (installed package)")
  skip_if_not_installed("devtools")
  s <- inbox_setup()
  p <- hf_file('stop("deliberate hooks-file failure")')
  r <- hf_run_auto_import(s, p)
  expect_identical(r$status, 0L, info = paste(r$out, collapse = "\n"))
  expect_true(file.exists(file.path(s$report_dir, "status.json")), info = paste(r$out, collapse = "\n"))
  expect_true(sprintf("hooks file %s failed: deliberate hooks-file failure", p) %in%
                hf_json_problems(s$report_dir))
})
