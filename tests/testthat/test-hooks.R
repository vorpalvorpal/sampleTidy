# PLAN-20 phase 1, P20.2: hooks (register_hook / clear_hooks / hooks) and their
# firing inside inbox_run(). Spec: dev/plans/PLAN-20-phase1-spec.md.
#
# Hooks are SESSION state, so every test that touches them clears them on entry
# and on exit (hk_clean()).
#
# inbox_run() is driven with ingest_dir() mocked (the namespace binding is
# mockable, see test-inbox.R). The real fixtures cannot be used for the
# "became complete" cases: every real fixture import opens review items that
# reference its own work order, so it never completes. The mock inserts a
# distinctively-named project (and sample) straight into the DB instead, which
# is exactly "a project that became complete during this run".

# ---- helpers ---------------------------------------------------------------------------

hk_clean <- function(env = parent.frame()) {
  clear_hooks()
  withr::defer(clear_hooks(), envir = env)
  invisible(NULL)
}

# What completed_work() returns, column by column (P20.4).
hk_cw_cols <- c("uuid", "name", "type", "site", "date_start", "date_end",
                "uuid_root", "root_name", "assets")

# The status list's names, in order, when no `checks` is given (P20.2).
hk_status_names <- c("updated", "host", "dry_run", "review_items_open",
                     "folders_waiting", "needs_review", "non_blocking_notes",
                     "waiting", "problems", "recent_imports", "db_checks")

# Insert a project with `samples` samples, optionally with one open review item
# that names it by work order (rule (a): blocks completeness).
hk_add_project <- function(db, uuid, name, samples = 1L, open_review = FALSE,
                           resolved_review = FALSE) {
  con <- seed_con(db)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbExecute(con, sprintf(
    "INSERT INTO project (uuid, name, type, date_start, date_end)
     VALUES ('%s', '%s', 'Work order', TIMESTAMP '2026-10-10 00:00:00',
             TIMESTAMP '2026-10-11 00:00:00')", uuid, name))
  for (i in seq_len(samples)) {
    DBI::dbExecute(con, sprintf(
      "INSERT INTO \"sample\" (uuid, uuid_feature_alias, uuid_project, date, datetime)
       VALUES ('%s-s%d', 'fa-0001', '%s', TIMESTAMP '2026-10-10 00:00:00',
               TIMESTAMP '2026-10-10 0%d:00:00')", uuid, i, uuid, i))
    # inbox_run()'s per-folder work-order summary needs an analysis per new sample
    DBI::dbExecute(con, sprintf(
      "INSERT INTO analysis (uuid, uuid_sample, uuid_lab, value, quantified)
       VALUES ('%s-a%d', '%s-s%d', 'lm-0001', 7.0, TRUE)", uuid, i, uuid, i))
  }
  if (open_review) {
    DBI::dbExecute(con, sprintf(
      "INSERT INTO review_queue (uuid, created_at, kind, work_order, status)
       VALUES ('%s-r1', TIMESTAMP '2026-10-10 00:00:00', 'unknown_analyte', '%s', 'open')",
      uuid, name))
  }
  if (resolved_review) {
    DBI::dbExecute(con, sprintf(
      "INSERT INTO review_queue (uuid, created_at, kind, work_order, status)
       VALUES ('%s-r2', TIMESTAMP '2026-10-10 00:00:00', 'unknown_analyte', '%s', 'resolved')",
      uuid, name))
  }
  invisible(NULL)
}

# A stand-in for ingest_dir(): runs `adder(db)` (if any) against the DB it is
# handed, or fails with a fixed message.
hk_ingest <- function(adder = NULL, fail = FALSE) {
  force(adder)
  force(fail)
  function(path, db, ...) {
    if (fail) stop("simulated folder failure")
    if (!is.null(adder)) adder(db)
    list(n_events_committed = 1L, rows_new = 1L)
  }
}

hk_folder <- function(s, now, name = "input2026-10-18 0900 a") {
  make_inbox_folder(s$input_dir, name, inbox_proj_a_files(), now = now)
}

hk_json <- function(report_dir, file = "status.json") {
  p <- file.path(report_dir, file)
  if (!file.exists(p)) return(list())
  jsonlite::fromJSON(p, simplifyVector = FALSE)
}

hk_problems <- function(report_dir, file = "status.json") {
  as.character(unlist(hk_json(report_dir, file)$problems))
}

# A recorder: hk_rec$calls is a list of list(event, arg).
hk_rec <- function() {
  rec <- new.env()
  rec$calls <- list()
  rec
}
hk_hook <- function(rec, event) {
  force(rec)
  force(event)
  function(x) {
    rec$calls[[length(rec$calls) + 1L]] <- list(event = event, arg = x)
    invisible(NULL)
  }
}
hk_events <- function(rec) vapply(rec$calls, function(cl) cl$event, character(1))

# ---- the API ---------------------------------------------------------------------------

test_that("P20.2: hooks() with no argument is a named list of the three events, in order, each empty", {
  hk_clean()
  h <- hooks()
  expect_type(h, "list")
  expect_identical(names(h), c("after_run", "after_status", "work_complete"))
  for (ev in names(h)) {
    expect_type(h[[ev]], "list")
    expect_length(h[[ev]], 0)
  }
})

test_that("P20.2: register_hook() returns fn invisibly and stores it under its event", {
  hk_clean()
  f <- function(x) NULL
  v <- withVisible(register_hook("after_run", f))
  expect_false(v$visible)
  expect_identical(v$value, f)
  expect_length(hooks("after_run"), 1)
  expect_identical(hooks("after_run")[[1]], f)
  expect_length(hooks("after_status"), 0)
  expect_length(hooks("work_complete"), 0)
  expect_identical(hooks()$after_run[[1]], f)
})

test_that("P20.2: hooks(event) returns that event's unnamed list", {
  hk_clean()
  register_hook("after_status", function(x) 1)
  register_hook("after_status", function(x) 2)
  got <- hooks("after_status")
  expect_type(got, "list")
  expect_length(got, 2)
  expect_null(names(got))
  expect_null(names(hooks()$after_status))
})

test_that("P20.2: hooks of one event run in registration order (list order) and the same function may be registered twice", {
  hk_clean()
  f <- function(x) "f"
  g <- function(x) "g"
  register_hook("work_complete", f)
  register_hook("work_complete", g)
  register_hook("work_complete", f)
  got <- hooks("work_complete")
  expect_length(got, 3)
  expect_identical(got[[1]], f)
  expect_identical(got[[2]], g)
  expect_identical(got[[3]], f)
})

test_that("P20.2: register_hook() rejects an unknown event with class sampletidy_error and registers nothing", {
  hk_clean()
  f <- function(x) NULL
  expect_error(register_hook("after_lunch", f), class = "sampletidy_error")
  expect_error(register_hook("AFTER_RUN", f), class = "sampletidy_error")
  expect_error(register_hook(NULL, f), class = "sampletidy_error")
  expect_error(register_hook(NA_character_, f), class = "sampletidy_error")
  expect_error(register_hook(c("after_run", "after_status"), f), class = "sampletidy_error")
  expect_error(register_hook(1, f), class = "sampletidy_error")
  expect_true(all(lengths(hooks()) == 0))
})

test_that("P20.2: register_hook() rejects a non-function with class sampletidy_error and registers nothing", {
  hk_clean()
  expect_error(register_hook("after_run", "not a function"), class = "sampletidy_error")
  expect_error(register_hook("after_run", NULL), class = "sampletidy_error")
  expect_error(register_hook("after_run", 42), class = "sampletidy_error")
  expect_error(register_hook("after_run", list(function(x) 1)), class = "sampletidy_error")
  expect_true(all(lengths(hooks()) == 0))
})

test_that("P20.2: clear_hooks(event) clears that event only; clear_hooks() clears all; both return NULL invisibly", {
  hk_clean()
  for (ev in c("after_run", "after_status", "work_complete")) {
    register_hook(ev, function(x) NULL)
    register_hook(ev, function(x) NULL)
  }
  v <- withVisible(clear_hooks("after_status"))
  expect_false(v$visible)
  expect_null(v$value)
  expect_length(hooks("after_status"), 0)
  expect_length(hooks("after_run"), 2)
  expect_length(hooks("work_complete"), 2)

  v2 <- withVisible(clear_hooks())
  expect_false(v2$visible)
  expect_null(v2$value)
  expect_true(all(lengths(hooks()) == 0))
  expect_identical(names(hooks()), c("after_run", "after_status", "work_complete"))
})

test_that("P20.2: clear_hooks() and hooks() reject an invalid event name with class sampletidy_error", {
  hk_clean()
  register_hook("after_run", function(x) NULL)
  expect_error(clear_hooks("nope"), class = "sampletidy_error")
  expect_error(hooks("nope"), class = "sampletidy_error")
  expect_length(hooks("after_run"), 1)   # a refused clear clears nothing
})

# ---- which events fire -------------------------------------------------------------------

hk_register_all <- function(rec) {
  register_hook("after_run", hk_hook(rec, "after_run"))
  register_hook("after_status", hk_hook(rec, "after_status"))
  register_hook("work_complete", hk_hook(rec, "work_complete"))
}

test_that("P20.2: action 'none' fires nothing", {
  hk_clean()
  s <- inbox_setup()
  now <- sydney_midday()
  testthat::local_mocked_bindings(ingest_dir = hk_ingest())
  run_inbox(s, now = now)                        # baseline: writes the state file
  rec <- hk_rec()
  hk_register_all(rec)
  res <- run_inbox(s, now = now)
  expect_identical(res$action, "none")
  expect_length(rec$calls, 0)
})

test_that("P20.2: a locked run fires nothing", {
  hk_clean()
  s <- inbox_setup()
  now <- sydney_midday()
  hk_folder(s, now)
  write_inbox_lock(s$db, live_child_pid(), now - 5 * 60)
  rec <- hk_rec()
  hk_register_all(rec)
  res <- run_inbox(s, now = now)
  expect_true(isTRUE(res$locked))
  expect_length(rec$calls, 0)
})

test_that("P20.2: action 'status' fires after_status only, with the status list", {
  hk_clean()
  s <- inbox_setup()
  now <- sydney_midday()
  testthat::local_mocked_bindings(ingest_dir = hk_ingest())
  run_inbox(s, now = now)
  Sys.setFileTime(s$db, Sys.time() + 120)          # only the DB stat changed -> "status"
  rec <- hk_rec()
  hk_register_all(rec)
  res <- run_inbox(s, now = now)
  expect_identical(res$action, "status")
  expect_identical(hk_events(rec), "after_status")
  arg <- rec$calls[[1]]$arg
  expect_identical(names(arg), hk_status_names)
  expect_false(arg$dry_run)
  expect_true(file.exists(file.path(s$report_dir, "status.json")))
})

test_that("P20.2: a dry run fires after_status only; its argument has dry_run = TRUE; nothing is appended to the logs", {
  hk_clean()
  s <- inbox_setup()
  now <- sydney_midday()
  hk_folder(s, now)
  testthat::local_mocked_bindings(ingest_dir = hk_ingest())
  rec <- hk_rec()
  hk_register_all(rec)
  res <- run_inbox(s, now = now, dry_run = TRUE)
  expect_true(res$ran)
  expect_identical(hk_events(rec), "after_status")
  expect_true(rec$calls[[1]]$arg$dry_run)
  expect_identical(names(rec$calls[[1]]$arg), hk_status_names)
  expect_false(file.exists(file.path(s$report_dir, "events.jsonl")))
  expect_false(file.exists(file.path(s$report_dir, ".imports.log")))
})

test_that("P20.2: a full run fires after_run, work_complete, after_status once each, in that order", {
  hk_clean()
  s <- inbox_setup()
  now <- sydney_midday()
  hk_folder(s, now)
  testthat::local_mocked_bindings(ingest_dir = hk_ingest(function(db) {
    hk_add_project(db, "hk-new-1", "HK-NEW-1")
  }))
  rec <- hk_rec()
  hk_register_all(rec)
  res <- run_inbox(s, now = now)
  expect_true(res$ran)
  expect_identical(hk_events(rec), c("after_run", "work_complete", "after_status"))
})

test_that("P20.2: after_run receives exactly the list inbox_run() returns", {
  hk_clean()
  s <- inbox_setup()
  now <- sydney_midday()
  hk_folder(s, now)
  testthat::local_mocked_bindings(ingest_dir = hk_ingest())
  rec <- hk_rec()
  register_hook("after_run", hk_hook(rec, "after_run"))
  res <- run_inbox(s, now = now)
  expect_length(rec$calls, 1)
  expect_identical(rec$calls[[1]]$arg, res)
  expect_true(res$ran)
  expect_identical(res$folders_processed, "input2026-10-18 0900 a")
})

test_that("P20.2: after_status receives the status list (names, types), and shows the import this run just logged", {
  hk_clean()
  s <- inbox_setup()
  now <- sydney_midday()
  hk_folder(s, now)
  testthat::local_mocked_bindings(ingest_dir = hk_ingest(function(db) {
    hk_add_project(db, "hk-new-1", "HK-NEW-1")
  }))
  rec <- hk_rec()
  register_hook("after_status", hk_hook(rec, "after_status"))
  run_inbox(s, now = now)
  expect_length(rec$calls, 1)
  arg <- rec$calls[[1]]$arg
  expect_identical(names(arg), hk_status_names)
  expect_type(arg$updated, "character")
  expect_type(arg$host, "character")
  expect_false(arg$dry_run)
  expect_equal(arg$review_items_open, 0)
  expect_type(arg$problems, "list")
  # the log line was appended before the status was built
  wos <- vapply(arg$recent_imports, function(r) r$work_order, character(1))
  expect_true("HK-NEW-1" %in% wos)
  # the same values are in status.json
  js <- hk_json(s$report_dir)
  expect_identical(js$updated, arg$updated)
  expect_identical(js$review_items_open, arg$review_items_open)
  expect_identical(names(js), hk_status_names)
})

test_that("P20.2: work_complete receives a completed_work() tibble of only the newly complete projects", {
  hk_clean()
  s <- inbox_setup()
  now <- sydney_midday()
  hk_folder(s, now)
  testthat::local_mocked_bindings(ingest_dir = hk_ingest(function(db) {
    hk_add_project(db, "hk-new-1", "HK-NEW-1")                    # becomes complete
    hk_add_project(db, "hk-new-2", "HK-NEW-2", open_review = TRUE) # blocked: not complete
    hk_add_project(db, "hk-new-3", "HK-NEW-3", samples = 0L)       # no samples: not complete
  }))
  rec <- hk_rec()
  register_hook("work_complete", hk_hook(rec, "work_complete"))
  run_inbox(s, now = now)
  expect_length(rec$calls, 1)
  arg <- rec$calls[[1]]$arg
  expect_s3_class(arg, "tbl_df")
  expect_identical(names(arg), hk_cw_cols)
  # seed project p-0001 was complete before the run, so it is excluded too
  expect_identical(arg$uuid, "hk-new-1")
  expect_identical(arg$name, "HK-NEW-1")
  cw <- completed_work(s$db)
  expect_equal(arg, cw[cw$uuid == "hk-new-1", ])
})

test_that("P20.2: work_complete does not fire when no project became complete during the run", {
  hk_clean()
  s <- inbox_setup()
  now <- sydney_midday()
  hk_folder(s, now)
  testthat::local_mocked_bindings(ingest_dir = hk_ingest(function(db) {
    hk_add_project(db, "hk-new-2", "HK-NEW-2", open_review = TRUE)
  }))
  rec <- hk_rec()
  hk_register_all(rec)
  run_inbox(s, now = now)
  expect_identical(hk_events(rec), c("after_run", "after_status"))
})

test_that("P20.2: work_complete does not fire when the folder ingest adds nothing, or fails", {
  hk_clean()
  s <- inbox_setup()
  now <- sydney_midday()
  hk_folder(s, now)
  testthat::local_mocked_bindings(ingest_dir = hk_ingest())
  rec <- hk_rec()
  hk_register_all(rec)
  run_inbox(s, now = now)
  expect_identical(hk_events(rec), c("after_run", "after_status"))

  hk_clean()
  s2 <- inbox_setup()
  hk_folder(s2, now)
  testthat::local_mocked_bindings(ingest_dir = hk_ingest(fail = TRUE))
  rec2 <- hk_rec()
  hk_register_all(rec2)
  run_inbox(s2, now = now)
  expect_identical(hk_events(rec2), c("after_run", "after_status"))
})

test_that("P20.2: work_complete does not fire when no folder was handed to ingest_dir() (an empty inbox)", {
  hk_clean()
  s <- inbox_setup()
  rec <- hk_rec()
  hk_register_all(rec)
  res <- run_inbox(s, now = sydney_midday())
  expect_true(res$ran)
  expect_identical(hk_events(rec), c("after_run", "after_status"))
})

test_that("P20.2: a project that became complete BETWEEN runs does not fire work_complete", {
  hk_clean()
  s <- inbox_setup()
  now <- sydney_midday()
  # incomplete before: it has a sample and an open review item
  hk_add_project(s$db, "hk-held", "HK-HELD", open_review = TRUE)
  testthat::local_mocked_bindings(ingest_dir = hk_ingest())
  hk_folder(s, now, "input2026-10-18 0900 a")
  run_inbox(s, now = now)

  # resolved by hand between runs
  con <- seed_con(s$db)
  DBI::dbExecute(con, "UPDATE review_queue SET status = 'resolved' WHERE uuid = 'hk-held-r1'")
  DBI::dbDisconnect(con, shutdown = TRUE)

  rec <- hk_rec()
  register_hook("work_complete", hk_hook(rec, "work_complete"))
  hk_folder(s, now, "input2026-10-18 1000 b")
  res <- run_inbox(s, now = now)
  expect_true(res$ran)
  expect_length(rec$calls, 0)
})

test_that("P20.2: a failed backup (nothing ingested) fires after_run and after_status but not work_complete", {
  hk_clean()
  s <- inbox_setup()
  now <- sydney_midday()
  hk_folder(s, now)
  testthat::local_mocked_bindings(
    .inbox_backup_copy = function(from, to) {
      writeLines("truncated copy", to)
      TRUE
    },
    ingest_dir = hk_ingest(function(db) hk_add_project(db, "hk-new-1", "HK-NEW-1"))
  )
  rec <- hk_rec()
  hk_register_all(rec)
  res <- run_inbox(s, now = now)
  expect_gt(length(res$errors), 0)
  expect_identical(hk_events(rec), c("after_run", "after_status"))
})

test_that("P20.2: the completed_work() snapshots are taken only when a work_complete hook is registered", {
  hk_clean()
  s <- inbox_setup()
  now <- sydney_midday()
  real_cw <- completed_work
  n <- 0L
  testthat::local_mocked_bindings(
    completed_work = function(...) {
      n <<- n + 1L
      real_cw(...)
    },
    ingest_dir = hk_ingest(function(db) hk_add_project(db, "hk-new-1", "HK-NEW-1"))
  )
  hk_folder(s, now)
  register_hook("after_run", function(x) NULL)
  run_inbox(s, now = now)
  expect_identical(n, 0L)

  # now with a work_complete hook: a snapshot before and one after
  s2 <- inbox_setup()
  hk_folder(s2, now)
  register_hook("work_complete", function(x) NULL)
  run_inbox(s2, now = now)
  expect_identical(n, 2L)
})

test_that("P20.2: hooks of one event run in registration order, and a function registered twice runs twice", {
  hk_clean()
  s <- inbox_setup()
  now <- sydney_midday()
  hk_folder(s, now)
  testthat::local_mocked_bindings(ingest_dir = hk_ingest())
  seen <- character(0)
  a <- function(x) seen <<- c(seen, "a")
  b <- function(x) seen <<- c(seen, "b")
  register_hook("after_run", a)
  register_hook("after_run", b)
  register_hook("after_run", a)
  run_inbox(s, now = now)
  expect_identical(seen, c("a", "b", "a"))
})

test_that("P20.2: status.json does not exist yet when after_run fires, and exists (with .import-status.json) when after_status fires", {
  hk_clean()
  s <- inbox_setup()
  now <- sydney_midday()
  hk_folder(s, now)
  testthat::local_mocked_bindings(ingest_dir = hk_ingest())
  at_run <- NA
  at_status <- NA
  log_at_run <- NA
  register_hook("after_run", function(x) {
    at_run <<- file.exists(file.path(s$report_dir, "status.json"))
    log_at_run <<- file.exists(file.path(s$report_dir, "events.jsonl")) &&
      length(readLines(file.path(s$report_dir, "events.jsonl"))) == 1L
  })
  register_hook("after_status", function(x) {
    at_status <<- file.exists(file.path(s$report_dir, "status.json")) &&
      file.exists(file.path(s$report_dir, ".import-status.json"))
  })
  run_inbox(s, now = now)
  expect_false(at_run)
  expect_true(log_at_run)            # the log line is appended before after_run
  expect_true(at_status)
})

# ---- default renderers -------------------------------------------------------------------

# A run that has news (one import and one failed folder), so the daily report is
# written by default and the log holds a problem.
hk_news_run <- function(s, now, ...) {
  hk_folder(s, now, "input2026-10-18 0900 good")
  hk_folder(s, now, "input2026-10-18 1000 boom")
  testthat::local_mocked_bindings(
    ingest_dir = function(path, db, ...) {
      if (grepl("boom", basename(path))) stop("simulated folder failure")
      hk_add_project(db, "hk-new-1", "HK-NEW-1")
      list(n_events_committed = 1L, rows_new = 1L)
    },
    .env = parent.frame()
  )
  run_inbox(s, now = now, ...)
}

test_that("P20.2 default renderers: with no hooks, Import status.md and the daily report equal import_status()/import_report() on the same inputs", {
  hk_clean()
  s <- inbox_setup()
  now <- sydney_midday()
  hk_news_run(s, now)

  note <- status_note_path(s$report_dir)
  day <- inbox_report_path(s$report_dir, now)
  expect_true(file.exists(note))
  expect_true(file.exists(day))

  # Same inputs through the exported functions, in a fresh report_dir that holds a
  # copy of the run log (the legacy name, which every reader falls back to).
  other <- withr::local_tempdir()
  file.copy(file.path(s$report_dir, ".imports.log"), file.path(other, ".imports.log"))
  suppressWarnings(suppressMessages({
    import_status(db = s$db, input_dir = s$input_dir, report_dir = other, now = now)
    import_report(db = s$db, report_dir = other, now = now)
  }))
  expect_identical(readLines(note, warn = FALSE),
                   readLines(status_note_path(other), warn = FALSE))
  expect_identical(readLines(day, warn = FALSE),
                   readLines(inbox_report_path(other, now), warn = FALSE))
  # and the content is the familiar one
  expect_true(any(grepl("HK-NEW-1", md_section(read_report(s$report_dir, now), "Imported today"))))
  expect_true(any(grepl("boom", md_section(read_status_note(s$report_dir), "Problems"))))
})

test_that("P20.2 default renderers: with no hooks status.json and .import-status.json are written too", {
  hk_clean()
  s <- inbox_setup()
  hk_news_run(s, sydney_midday())
  expect_true(file.exists(file.path(s$report_dir, "status.json")))
  expect_true(file.exists(file.path(s$report_dir, ".import-status.json")))
})

test_that("P20.2: a registered after_status hook replaces the Import status.md renderer; status.json and .import-status.json are still written", {
  hk_clean()
  s <- inbox_setup()
  now <- sydney_midday()
  register_hook("after_status", function(x) NULL)
  hk_news_run(s, now)
  expect_false(file.exists(status_note_path(s$report_dir)))
  expect_true(file.exists(file.path(s$report_dir, "status.json")))
  expect_true(file.exists(file.path(s$report_dir, ".import-status.json")))
  # the after_run default is untouched: the daily report is still written
  expect_true(file.exists(inbox_report_path(s$report_dir, now)))
})

test_that("P20.2: a registered after_run hook replaces the daily-report renderer; Import status.md is still written", {
  hk_clean()
  s <- inbox_setup()
  now <- sydney_midday()
  register_hook("after_run", function(x) NULL)
  hk_news_run(s, now)
  expect_false(file.exists(inbox_report_path(s$report_dir, now)))
  expect_true(file.exists(status_note_path(s$report_dir)))
})

test_that("P20.2: with both an after_run and an after_status hook neither markdown note is written", {
  hk_clean()
  s <- inbox_setup()
  now <- sydney_midday()
  register_hook("after_run", function(x) NULL)
  register_hook("after_status", function(x) NULL)
  hk_news_run(s, now)
  expect_false(file.exists(inbox_report_path(s$report_dir, now)))
  expect_false(file.exists(status_note_path(s$report_dir)))
  expect_true(file.exists(file.path(s$report_dir, "status.json")))
})

test_that("P20.2: work_complete has no default and does not replace either renderer", {
  hk_clean()
  s <- inbox_setup()
  now <- sydney_midday()
  register_hook("work_complete", function(x) NULL)
  hk_news_run(s, now)
  expect_true(file.exists(inbox_report_path(s$report_dir, now)))
  expect_true(file.exists(status_note_path(s$report_dir)))
})

test_that("P20.2: a dry run with an after_status hook writes no Import status.md; without one it writes it as before", {
  hk_clean()
  s <- inbox_setup()
  now <- sydney_midday()
  hk_folder(s, now)
  testthat::local_mocked_bindings(ingest_dir = hk_ingest())
  run_inbox(s, now = now, dry_run = TRUE)
  expect_true(any(grepl("DRY RUN", read_status_note(s$report_dir), fixed = TRUE)))

  s2 <- inbox_setup()
  hk_folder(s2, now)
  register_hook("after_status", function(x) NULL)
  run_inbox(s2, now = now, dry_run = TRUE)
  expect_false(file.exists(status_note_path(s2$report_dir)))
  expect_true(file.exists(file.path(s2$report_dir, "status.json")))
})

# ---- failure isolation -------------------------------------------------------------------

test_that("P20.2 failures: a failing after_run hook never fails the run, stops later hooks, or changes the returned list", {
  hk_clean()
  s0 <- inbox_setup()
  now <- sydney_midday()
  hk_folder(s0, now)
  testthat::local_mocked_bindings(ingest_dir = hk_ingest())
  plain <- run_inbox(s0, now = now)

  s <- inbox_setup()
  hk_folder(s, now)
  later <- 0L
  register_hook("after_run", function(x) stop("boom1"))
  register_hook("after_run", function(x) later <<- later + 1L)
  res <- expect_no_error(run_inbox(s, now = now))
  expect_identical(later, 1L)
  expect_identical(names(res), names(plain))
  expect_identical(res$action, "run")
  expect_true(res$ran)
  expect_false(res$locked)
  expect_identical(res$folders_processed, plain$folders_processed)
  expect_identical(res$errors, character(0))     # hook problems are not run errors
})

test_that("P20.2 failures: the exact problem string 'hook after_run[<id>] failed: <msg>' is in status.json, .import-status.json and the status note's Problems; id is the 1-based position", {
  hk_clean()
  s <- inbox_setup()
  now <- sydney_midday()
  hk_folder(s, now)
  testthat::local_mocked_bindings(ingest_dir = hk_ingest())
  register_hook("after_run", function(x) NULL)
  register_hook("after_run", function(x) stop("boom2"))
  run_inbox(s, now = now)
  want <- "hook after_run[2] failed: boom2"
  expect_true(want %in% hk_problems(s$report_dir))
  expect_true(want %in% hk_problems(s$report_dir, ".import-status.json"))
  expect_false("hook after_run[1] failed: boom2" %in% hk_problems(s$report_dir))
  prob <- md_section(read_status_note(s$report_dir), "Problems")
  expect_true(any(grepl(want, prob, fixed = TRUE)))
})

test_that("P20.2 failures: hook problems come after the log-derived problems, and are not written to the run log", {
  hk_clean()
  s <- inbox_setup()
  now <- sydney_midday()
  hk_folder(s, now)
  testthat::local_mocked_bindings(ingest_dir = hk_ingest(fail = TRUE))
  register_hook("after_run", function(x) stop("boom3"))
  run_inbox(s, now = now)
  p <- hk_problems(s$report_dir)
  i_log <- grep("simulated folder failure", p, fixed = TRUE)
  i_hook <- which(p == "hook after_run[1] failed: boom3")
  expect_length(i_log, 1)
  expect_length(i_hook, 1)
  expect_lt(i_log, i_hook)
  for (f in c(".imports.log", "events.jsonl")) {
    p_log <- file.path(s$report_dir, f)
    if (file.exists(p_log)) {
      expect_false(any(grepl("hook after_run", readLines(p_log, warn = FALSE), fixed = TRUE)), info = f)
    }
  }
})

test_that("P20.2 failures: a failing work_complete hook is recorded as 'hook work_complete[<id>] failed: <msg>', later hooks still run", {
  hk_clean()
  s <- inbox_setup()
  now <- sydney_midday()
  hk_folder(s, now)
  testthat::local_mocked_bindings(ingest_dir = hk_ingest(function(db) {
    hk_add_project(db, "hk-new-1", "HK-NEW-1")
  }))
  later <- 0L
  register_hook("work_complete", function(x) stop("wcboom"))
  register_hook("work_complete", function(x) later <<- later + 1L)
  # No after_status hook: the default renderer must write the note read below.
  res <- run_inbox(s, now = now)
  expect_true(res$ran)
  expect_identical(later, 1L)
  expect_true("hook work_complete[1] failed: wcboom" %in% hk_problems(s$report_dir))
  expect_true("hook work_complete[1] failed: wcboom" %in% hk_problems(s$report_dir, ".import-status.json"))
  prob <- md_section(read_status_note(s$report_dir), "Problems")
  expect_true(any(grepl("hook work_complete[1] failed: wcboom", prob, fixed = TRUE)))
})

test_that("P20.2 failures: a failing completed_work() snapshot is recorded as 'hook work_complete[snapshot] failed: <msg>' and the run still completes", {
  hk_clean()
  s <- inbox_setup()
  now <- sydney_midday()
  hk_folder(s, now)
  testthat::local_mocked_bindings(
    completed_work = function(...) stop("snapboom"),
    ingest_dir = hk_ingest()
  )
  register_hook("work_complete", function(x) NULL)
  done <- FALSE
  register_hook("after_status", function(x) done <<- TRUE)
  res <- run_inbox(s, now = now)
  expect_true(res$ran)
  expect_true(done)
  expect_true("hook work_complete[snapshot] failed: snapboom" %in% hk_problems(s$report_dir))
})

test_that("P20.2 failures: a failing after_status hook is isolated; its failure is added to problems and status.json is rewritten; the hook saw the status without its own failure", {
  hk_clean()
  s <- inbox_setup()
  now <- sydney_midday()
  hk_folder(s, now)
  testthat::local_mocked_bindings(ingest_dir = hk_ingest())
  seen_by_failing <- NULL
  later <- 0L
  register_hook("after_status", function(x) {
    seen_by_failing <<- x
    stop("sboom")
  })
  register_hook("after_status", function(x) later <<- later + 1L)
  res <- expect_no_error(run_inbox(s, now = now))
  expect_true(res$ran)
  expect_identical(later, 1L)
  want <- "hook after_status[1] failed: sboom"
  expect_false(want %in% as.character(unlist(seen_by_failing$problems)))
  expect_true(want %in% hk_problems(s$report_dir))
  expect_true(want %in% hk_problems(s$report_dir, ".import-status.json"))
  # the two files are still byte-identical after the rewrite
  expect_identical(file_md5(file.path(s$report_dir, "status.json")),
                   file_md5(file.path(s$report_dir, ".import-status.json")))
})

test_that("P20.2 failures: a failing after_status hook on action 'status' and on a dry run is isolated too", {
  hk_clean()
  s <- inbox_setup()
  now <- sydney_midday()
  hk_folder(s, now)
  testthat::local_mocked_bindings(ingest_dir = hk_ingest())
  register_hook("after_status", function(x) stop("sboom2"))
  res <- expect_no_error(run_inbox(s, now = now, dry_run = TRUE))
  expect_true(res$ran)
  expect_true("hook after_status[1] failed: sboom2" %in% hk_problems(s$report_dir))
})

test_that("P20.2 failures: a failing default after_status renderer is recorded as 'hook after_status[default] failed: ...' and the run completes", {
  hk_clean()
  s <- inbox_setup()
  now <- sydney_midday()
  hk_folder(s, now)
  testthat::local_mocked_bindings(ingest_dir = hk_ingest())
  # a directory where the note must be written makes the default renderer fail
  dir.create(status_note_path(s$report_dir), recursive = TRUE)
  res <- expect_no_error(run_inbox(s, now = now))
  expect_true(res$ran)
  p <- hk_problems(s$report_dir)
  expect_true(any(startsWith(p, "hook after_status[default] failed: ")))
  expect_true(file.exists(file.path(s$report_dir, "status.json")))
})

test_that("P20.2 failures: a failing default after_run renderer is recorded as 'hook after_run[default] failed: ...', in status.json and the status note's Problems", {
  hk_clean()
  s <- inbox_setup()
  now <- sydney_midday()
  hk_folder(s, now, "input2026-10-18 0900 boom")
  testthat::local_mocked_bindings(ingest_dir = hk_ingest(fail = TRUE))   # news: a failed folder
  dir.create(inbox_report_path(s$report_dir, now), recursive = TRUE)
  res <- expect_no_error(run_inbox(s, now = now))
  expect_true(res$ran)
  p <- hk_problems(s$report_dir)
  expect_true(any(startsWith(p, "hook after_run[default] failed: ")))
  prob <- md_section(read_status_note(s$report_dir), "Problems")
  expect_true(any(grepl("hook after_run[default] failed: ", prob, fixed = TRUE)))
})

test_that("P20.2 failures: a failing hook leaves the other files of the run intact (events.jsonl line, status.json)", {
  hk_clean()
  s <- inbox_setup()
  now <- sydney_midday()
  hk_folder(s, now)
  testthat::local_mocked_bindings(ingest_dir = hk_ingest())
  register_hook("after_run", function(x) stop("x"))
  register_hook("work_complete", function(x) stop("y"))
  register_hook("after_status", function(x) stop("z"))
  res <- run_inbox(s, now = now)
  expect_true(res$ran)
  expect_length(readLines(file.path(s$report_dir, "events.jsonl")), 1)
  p <- hk_problems(s$report_dir)
  expect_true("hook after_run[1] failed: x" %in% p)
  expect_true("hook after_status[1] failed: z" %in% p)
})
