# SAMPLETIDY_STATE_DIR: machine state leaves the report folder (Robin, 2026-11-16/18).
#
# Today SAMPLETIDY_REPORT_DIR (st_config("report_dir")) holds two kinds of file:
#   machine state  .imports.lock  .imports.state  .imports.gate  .imports.health
#                  .imports.log   .imports.notified  events.jsonl  status.json
#   notes for people  Import status.md, <date>-imports.md and .import-status.json
#                  (Obsidian's daily note reads .import-status.json by vault path)
#
# Design these tests pin:
#   1. st_config("state_dir") reads option sampletidy.state_dir, then env var
#      SAMPLETIDY_STATE_DIR, like every other key. Unset, it is NULL (no abort).
#   2. st_state_dir(report_dir = st_config("report_dir")) is the folder of the eight
#      files: the state_dir setting when set (and not ""), else report_dir itself, so
#      nothing changes until the setting is made. Exported.
#   3. st_imports_lock_path(report_dir = st_config("report_dir")) is
#      file.path(st_state_dir(report_dir), ".imports.lock"). Exported, for callers
#      (bmcc-monitoring's migration scripts) that must find the lock the wrapper
#      (dev/auto-import.sh / .ps1) takes. Not the same thing as the R-side
#      `<db>.inbox.lock`, which stays beside the database (pinned below).
#   4. inbox_run(), inbox_check() and the status refresh write/read .imports.state,
#      .imports.log, events.jsonl and status.json under st_state_dir(report_dir), and
#      .import-status.json plus renderer notes under report_dir.
#   5. Nothing moves files: a file already in report_dir is not read as state once
#      state_dir is set.
#   6. The recommended value at the cut-over is tools::R_user_dir("sampleTidy", "data");
#      it is documented (see the man page / config docs), not the unset default.
# The wrapper scripts are covered by test-state-dir-wrapper.R.

R_STATE_FILES <- c(".imports.state", ".imports.log", "events.jsonl", "status.json")
ALL_STATE_FILES <- c(".imports.lock", ".imports.state", ".imports.gate", ".imports.health",
                     ".imports.log", ".imports.notified", "events.jsonl", "status.json")

sd_dirs <- function(env = parent.frame()) {
  list(report = withr::local_tempdir(pattern = "report", .local_envir = env),
       state = withr::local_tempdir(pattern = "state", .local_envir = env))
}

sd_ls <- function(d) sort(list.files(d, all.files = TRUE, no.. = TRUE, recursive = TRUE))

# Renderer hooks standing in for a deployment's note writers (the core writes no markdown).
sd_note_renderers <- function(env = parent.frame()) {
  register_hook("after_status", function(arg, context)
    writeLines("status note", file.path(context$report_dir, "Import status.md")), renderer = TRUE)
  register_hook("after_run", function(arg, context) {
    if (!is.null(context$day))
      writeLines("day note", file.path(context$report_dir, paste0(context$day$date, "-imports.md")))
  }, renderer = TRUE)
  withr::defer(clear_hooks(), envir = env)
}

# One real inbox_run() over the shared fixtures, with the ingest stubbed.
sd_run <- function(s, now = bt_now()) {
  sd_note_renderers(parent.frame())
  bt_folder(s, "batch-1", now)
  testthat::local_mocked_bindings(ingest_dir = bt_ingest(), .env = parent.frame())
  res <- run_inbox(s, now = now, batch = inbox_batches())
  expect_true(isTRUE(res$ran))
  invisible(res)
}

# ---- 1. the setting -------------------------------------------------------------

test_that("st_config('state_dir') is NULL when unset, reads the env var, and the option wins", {
  withr::local_options(sampletidy.state_dir = NULL)
  withr::local_envvar(SAMPLETIDY_STATE_DIR = NA)
  expect_null(st_config("state_dir"))
  withr::local_envvar(SAMPLETIDY_STATE_DIR = "/from/env")
  expect_identical(st_config("state_dir"), "/from/env")
  withr::local_options(sampletidy.state_dir = "/from/option")
  expect_identical(st_config("state_dir"), "/from/option")
})

# ---- 2/3. the accessors ----------------------------------------------------------

test_that("unset, st_state_dir() is the report dir and the lock path is under it", {
  d <- sd_dirs()
  withr::local_options(sampletidy.state_dir = NULL)
  withr::local_envvar(SAMPLETIDY_STATE_DIR = NA)
  expect_identical(st_state_dir(d$report), d$report)
  expect_identical(st_imports_lock_path(d$report), file.path(d$report, ".imports.lock"))
})

test_that("an empty SAMPLETIDY_STATE_DIR counts as unset", {
  d <- sd_dirs()
  withr::local_options(sampletidy.state_dir = NULL)
  withr::local_envvar(SAMPLETIDY_STATE_DIR = "")
  expect_identical(st_state_dir(d$report), d$report)
})

test_that("set (by env var or by option), st_state_dir() and the lock path are under the state dir", {
  d <- sd_dirs()
  withr::local_options(sampletidy.state_dir = NULL)
  withr::local_envvar(SAMPLETIDY_STATE_DIR = d$state)
  expect_identical(st_state_dir(d$report), d$state)
  expect_identical(st_imports_lock_path(d$report), file.path(d$state, ".imports.lock"))
  other <- withr::local_tempdir(pattern = "opt")
  withr::local_options(sampletidy.state_dir = other)
  expect_identical(st_state_dir(d$report), other)
  expect_identical(st_imports_lock_path(d$report), file.path(other, ".imports.lock"))
})

test_that("the accessors default report_dir to st_config('report_dir')", {
  d <- sd_dirs()
  withr::local_options(sampletidy.state_dir = NULL, sampletidy.report_dir = d$report)
  withr::local_envvar(SAMPLETIDY_STATE_DIR = NA)
  expect_identical(st_state_dir(), d$report)
  expect_identical(st_imports_lock_path(), file.path(d$report, ".imports.lock"))
  withr::local_envvar(SAMPLETIDY_STATE_DIR = d$state)
  expect_identical(st_state_dir(), d$state)
  expect_identical(st_imports_lock_path(), file.path(d$state, ".imports.lock"))
})

test_that("the accessors are exported", {
  exports <- getNamespaceExports("sampleTidy")
  expect_true(all(c("st_state_dir", "st_imports_lock_path") %in% exports))
})

test_that("the R-side database lock stays beside the database under either setting", {
  withr::local_envvar(SAMPLETIDY_STATE_DIR = withr::local_tempdir())
  expect_identical(sampleTidy:::.inbox_lock_path("/x/monitoring.duckdb"),
                   "/x/monitoring.duckdb.inbox.lock")
})

# ---- 4. an import run, state dir set ---------------------------------------------

test_that("state dir set: the four R-written state files land only there; notes and .import-status.json only in the report dir", {
  s <- bt_setup()
  d <- sd_dirs()
  s$report_dir <- d$report
  withr::local_options(sampletidy.state_dir = NULL)
  withr::local_envvar(SAMPLETIDY_STATE_DIR = d$state)
  sd_run(s)
  expect_setequal(sd_ls(d$state), R_STATE_FILES)
  rep <- sd_ls(d$report)
  expect_setequal(rep, c(".import-status.json", "Import status.md",
                         grep("-imports\\.md$", rep, value = TRUE)))
  expect_true(".import-status.json" %in% rep)
  expect_true("Import status.md" %in% rep)
  expect_length(grep("-imports\\.md$", rep), 1L)
  expect_false(any(rep %in% ALL_STATE_FILES))
})

test_that("state dir set: status.json and .import-status.json are still identical, in their two folders", {
  s <- bt_setup()
  d <- sd_dirs()
  s$report_dir <- d$report
  withr::local_options(sampletidy.state_dir = NULL)
  withr::local_envvar(SAMPLETIDY_STATE_DIR = d$state)
  sd_run(s)
  expect_identical(readLines(file.path(d$state, "status.json")),
                   readLines(file.path(d$report, ".import-status.json")))
})

test_that("state dir set: a status refresh alone (import_status) writes status.json to the state dir", {
  s <- bt_setup()
  d <- sd_dirs()
  withr::local_options(sampletidy.state_dir = NULL)
  withr::local_envvar(SAMPLETIDY_STATE_DIR = d$state)
  sd_note_renderers()
  quiet_run(import_status(db = s$db, input_dir = s$input_dir, report_dir = d$report,
                          now = bt_now()))
  expect_true(file.exists(file.path(d$state, "status.json")))
  expect_false(file.exists(file.path(d$report, "status.json")))
  expect_true(file.exists(file.path(d$report, ".import-status.json")))
})

test_that("state dir set: inbox_check() reads .imports.state from the state dir", {
  s <- bt_setup()
  d <- sd_dirs()
  s$report_dir <- d$report
  withr::local_options(sampletidy.state_dir = NULL)
  withr::local_envvar(SAMPLETIDY_STATE_DIR = d$state)
  now <- bt_now()
  sd_run(s, now)
  expect_identical(inbox_check(s$input_dir, d$report, now = now + 60, db = s$db), "none")
  unlink(file.path(d$state, ".imports.state"))
  expect_identical(inbox_check(s$input_dir, d$report, now = now + 60, db = s$db), "run")
})

test_that("state dir set: nothing is read from stale state left in the report dir (no automatic move)", {
  s <- bt_setup()
  d <- sd_dirs()
  s$report_dir <- d$report
  withr::local_options(sampletidy.state_dir = NULL)
  # a run with the setting unset leaves state in the report dir ...
  withr::local_envvar(SAMPLETIDY_STATE_DIR = NA)
  now <- bt_now()
  sd_run(s, now)
  expect_true(file.exists(file.path(d$report, ".imports.state")))
  before <- tools::md5sum(file.path(d$report, R_STATE_FILES))
  # ... and once the setting is made, inbox_check() ignores it and nothing is moved or touched
  withr::local_envvar(SAMPLETIDY_STATE_DIR = d$state)
  expect_identical(inbox_check(s$input_dir, d$report, now = now + 60, db = s$db), "run")
  expect_identical(tools::md5sum(file.path(d$report, R_STATE_FILES)), before)
  expect_length(sd_ls(d$state), 0L)
})

# ---- 5. state dir unset: as today ------------------------------------------------

test_that("state dir unset: every file of the run lands in the report dir, as today", {
  s <- bt_setup()
  d <- sd_dirs()
  s$report_dir <- d$report
  withr::local_options(sampletidy.state_dir = NULL)
  withr::local_envvar(SAMPLETIDY_STATE_DIR = NA)
  sd_run(s)
  rep <- sd_ls(d$report)
  expect_true(all(c(R_STATE_FILES, ".import-status.json", "Import status.md") %in% rep))
  expect_length(grep("-imports\\.md$", rep), 1L)
  expect_length(sd_ls(d$state), 0L)
})

# ---- 6. the state-writing code and the lock wrapper agree on the lock path -------

test_that("the lock path the accessor gives is the one inside the folder that holds the other state files", {
  s <- bt_setup()
  d <- sd_dirs()
  s$report_dir <- d$report
  withr::local_options(sampletidy.state_dir = NULL)
  for (state in list(NA, d$state)) {
    withr::local_envvar(SAMPLETIDY_STATE_DIR = state)
    unlink(list.files(d$report, full.names = TRUE, all.files = TRUE, no.. = TRUE), recursive = TRUE)
    unlink(list.files(d$state, full.names = TRUE, all.files = TRUE, no.. = TRUE), recursive = TRUE)
    sd_run(s)
    expect_identical(dirname(st_imports_lock_path(d$report)), st_state_dir(d$report))
    expect_true(file.exists(file.path(dirname(st_imports_lock_path(d$report)), ".imports.state")))
  }
})

# ---- 7. source guard -------------------------------------------------------------

# Every string literal in R/ that names one of the eight state files must sit inside a
# file.path()/paste0()/paste() call that also calls st_state_dir() or
# st_imports_lock_path(); that is, no R/ code builds a state-file path from the report
# dir. (A literal in a bare c() or a `for` loop fails too: build each path by the accessor.)
# Comments and roxygen are not string tokens, so they are ignored by construction.

sd_state_file_names <- "^(\\.imports\\.(lock|state|gate|health|log|notified)|events\\.jsonl|status\\.json)$"

sd_literal_offenders <- function(files) {
  out <- list()
  n_seen <- 0L
  for (f in files) {
    ex <- parse(f, keep.source = TRUE)
    pd <- utils::getParseData(ex, includeText = TRUE)
    if (is.null(pd)) next
    strs <- pd[pd$token == "STR_CONST" &
                 grepl(sd_state_file_names, gsub("^[\"']|[\"']$", "", pd$text)), ]
    for (i in seq_len(nrow(strs))) {
      n_seen <- n_seen + 1L
      id <- strs$id[[i]]
      ok <- FALSE
      repeat {
        par <- pd$parent[pd$id == id]
        if (length(par) == 0L || par == 0L) break
        id <- par
        kids <- pd[pd$parent == id, ]
        fn <- kids$text[kids$token == "SYMBOL_FUNCTION_CALL"]
        if (length(fn) == 0L) {
          # `pkg::f(...)` and plain calls hold the name one level down
          for (k in kids$id[kids$token == "expr"]) {
            gk <- pd[pd$parent == k, ]
            fn <- c(fn, gk$text[gk$token == "SYMBOL_FUNCTION_CALL"])
          }
        }
        if (any(fn %in% c("file.path", "paste0", "paste"))) {
          txt <- pd$text[pd$id == id]
          calls <- pd$text[pd$token == "SYMBOL_FUNCTION_CALL" &
                             pd$line1 >= pd$line1[pd$id == id] & pd$line1 <= pd$line2[pd$id == id]]
          ok <- any(c("st_state_dir", "st_imports_lock_path") %in% calls)
          break
        }
      }
      if (!ok) out[[length(out) + 1L]] <- sprintf("%s:%d %s", basename(f), strs$line1[[i]], strs$text[[i]])
    }
  }
  list(offenders = unlist(out), n_seen = n_seen)
}

test_that("no code in R/ builds a path to a machine-state file except through the accessor", {
  r_dir <- testthat::test_path("..", "..", "R")
  skip_if_not(dir.exists(r_dir), "R/ sources not available (installed-package test run)")
  res <- sd_literal_offenders(list.files(r_dir, pattern = "\\.[Rr]$", full.names = TRUE))
  # not vacuous: the scanner does see the state files' names today and after the change
  expect_gte(res$n_seen, 4L)
  expect_identical(res$offenders, NULL, info = paste(res$offenders, collapse = "\n"))
})

test_that("the source guard catches a hand-built path (self-test)", {
  bad <- withr::local_tempfile(fileext = ".R")
  writeLines(c('f <- function(report_dir) file.path(report_dir, ".imports.state")',
               'g <- function(report_dir) file.path(st_state_dir(report_dir), "events.jsonl")'), bad)
  res <- sd_literal_offenders(bad)
  expect_length(res$offenders, 1L)
  expect_match(res$offenders, ".imports.state", fixed = TRUE)
})
