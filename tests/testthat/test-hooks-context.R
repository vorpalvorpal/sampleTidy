# Stage 2 of the layer move: hooks get a context, the core has no default
# renderers, and register_hook() can tag a hook as a renderer.
#
#   * a hook of two or more formals (or with `...`) is called fn(arg, context);
#     any other is called fn(arg);
#   * context = list(source, report_dir, input_dir, db, now, timezone, day);
#   * `day` is NULL except for after_run, where it is the day digest when the
#     day has news;
#   * register_hook(renderer = TRUE) is for after_status / after_run only;
#   * a hook's problem string is "hook <event>[<i>] failed: <msg>", i being its
#     1-based registration index; there is no "default" any more.
#
# Synthetic: folders batch-1, site N, the legacy recogniser cleared.

hc_names <- c("source", "report_dir", "input_dir", "db", "now", "timezone", "day")

hc_clean <- function(env = parent.frame()) {
  clear_hooks()
  withr::defer(clear_hooks(), envir = env)
  invisible(NULL)
}

# A project with one sample and analysis that is complete (no open review item).
hc_add_project <- function(db, uuid, name) {
  con <- seed_con(db)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbExecute(con, sprintf(
    "INSERT INTO project (uuid, name, type, date_start, date_end)
     VALUES ('%s', '%s', 'Work order', TIMESTAMP '2026-10-10 00:00:00',
             TIMESTAMP '2026-10-11 00:00:00')", uuid, name))
  DBI::dbExecute(con, sprintf(
    "INSERT INTO \"sample\" (uuid, uuid_feature_alias, uuid_project, date, datetime)
     VALUES ('%s-s1', 'fa-0001', '%s', TIMESTAMP '2026-10-10 00:00:00',
             TIMESTAMP '2026-10-10 01:00:00')", uuid, uuid))
  DBI::dbExecute(con, sprintf(
    "INSERT INTO analysis (uuid, uuid_sample, uuid_lab, value, quantified)
     VALUES ('%s-a1', '%s-s1', 'lm-0001', 7.0, TRUE)", uuid, uuid))
  invisible(NULL)
}

hc_problems <- function(s) as.character(unlist(read_status_json(s$report_dir)$problems))

# ---- the context -------------------------------------------------------------------------------

test_that("a two-argument after_status hook gets the context, names in order, from inbox_run", {
  hc_clean()
  s <- bt_setup()
  withr::local_options(sampletidy.timezone = "Pacific/Auckland")
  now <- bt_now()
  rec <- record_hook("after_status")
  run_inbox(s, now = now, batch = inbox_batches())
  expect_length(rec$calls, 1)
  ctx <- rec$calls[[1]]$context
  expect_identical(names(ctx), hc_names)
  expect_identical(ctx$source, "inbox_run")
  expect_identical(ctx$report_dir, s$report_dir)
  expect_identical(ctx$input_dir, s$input_dir)
  expect_identical(ctx$db, s$db)
  expect_s3_class(ctx$now, "POSIXct")
  expect_equal(as.numeric(ctx$now), as.numeric(now))
  expect_identical(ctx$timezone, "Pacific/Auckland")
  expect_null(ctx$day)
  # the first argument is still the status list
  expect_identical(rec$calls[[1]]$arg$timezone, "Pacific/Auckland")
})

test_that("a one-argument hook is called with one argument; a function(...) hook receives two", {
  hc_clean()
  s <- bt_setup()
  n_one <- NA
  n_dots <- NA
  register_hook("after_status", function(x) n_one <<- nargs())
  register_hook("after_status", function(...) n_dots <<- length(list(...)))
  run_inbox(s, now = bt_now(), batch = inbox_batches())
  expect_identical(n_one, 1L)
  expect_identical(n_dots, 2L)
})

test_that("after_run: context$day is NULL when the run had no news", {
  hc_clean()
  s <- bt_setup()
  rec <- record_hook("after_run")
  res <- run_inbox(s, now = bt_now(), batch = inbox_batches())      # an empty inbox
  expect_true(res$ran)
  expect_length(rec$calls, 1)
  expect_identical(rec$calls[[1]]$context$source, "inbox_run")
  expect_null(rec$calls[[1]]$context$day)
})

test_that("after_run: when the run imports, day has date, time, review_items_open and runs; runs holds today's earlier line but not yesterday's or a dry run's", {
  hc_clean()
  s <- bt_setup()
  now <- sydney_midday()
  bt_folder(s, "batch-1", now, files = inbox_rain_files())
  testthat::local_mocked_bindings(ingest_dir = bt_ingest(wo = "ES9990001", site = "N"))
  insert_review_items(s$db, data.frame(
    uuid = c("rq-1", "rq-2", "rq-3"),
    created_at = as.POSIXct(rep("2026-10-10 00:00:00", 3), tz = "UTC"),
    kind = "unknown_analyte", subkind = NA_character_,
    work_order = c("ES1", "ES2", "ES3"),
    status = c("open", "open", "resolved"), stringsAsFactors = FALSE))
  earlier <- inbox_log_line(now - 2 * 3600, wo = "ES9990002", folder = "batch-0")
  write_events(s$report_dir, c(
    inbox_log_line(now - 26 * 3600, wo = "ES9990003", folder = "batch-y"),   # yesterday
    earlier,
    inbox_log_line(now - 3600, wo = "ES9990004", dry_run = TRUE, folder = "batch-d")))
  rec <- record_hook("after_run")

  run_inbox(s, now = now, batch = inbox_batches())
  expect_length(rec$calls, 1)
  day <- rec$calls[[1]]$context$day
  expect_false(is.null(day))
  expect_true(all(c("date", "time", "review_items_open", "runs") %in% names(day)))
  expect_identical(day$date, sydney_date(now))
  expect_identical(day$time, sydney_hhmm(now))
  n_open <- nrow(sampleTidy:::.inbox_open_reviews(s$db))
  expect_gte(n_open, 2)
  expect_equal(day$review_items_open, n_open)

  # the earlier same-day line and this run; not yesterday's, not the dry run's
  expect_length(day$runs, 2)
  started <- vapply(day$runs, function(r) r$started_at, "")
  expect_identical(started[[1]], jsonlite::fromJSON(earlier)$started_at)
  imported <- lapply(day$runs, function(r) vapply(r$imports, function(w) w$name, ""))
  expect_identical(imported[[1]], "ES9990002")
  expect_identical(imported[[2]], "ES9990001")
  expect_false(any(c("ES9990003", "ES9990004") %in% unlist(imported)))
  for (r in day$runs) expect_true(all(c("started_at", "time", "imports", "filed", "problems") %in% names(r)))

  imp <- day$runs[[2]]$imports[[1]]
  expect_true(all(c("name", "kind", "site", "date_start", "date_end", "samples", "analyses",
                    "folder", "folder_path") %in% names(imp)))
  expect_identical(imp$site, "N")
  expect_identical(imp$folder, "batch-1")
  expect_identical(imp$date_start, "2026-10-10")
  expect_identical(imp$date_end, "2026-10-10")
})

test_that("the day digest's times are local: under Pacific/Auckland a line started 2026-03-01T23:30:00Z has time 12:30 on 2026-03-02", {
  hc_clean()
  s <- bt_setup()
  withr::local_options(sampletidy.timezone = "Pacific/Auckland")
  now <- as.POSIXct("2026-03-02 02:00:00", tz = "UTC")              # 15:00 on 2 March in Auckland
  write_events(s$report_dir, inbox_log_line(as.POSIXct("2026-03-01 23:30:00", tz = "UTC")))
  rec <- record_hook("after_run", renderer = TRUE)
  expect_warning(suppressMessages(import_report(db = s$db, report_dir = s$report_dir, now = now)),
                 NA)                                              # a renderer is registered
  expect_length(rec$calls, 1)
  day <- rec$calls[[1]]$context$day
  expect_identical(day$date, "2026-03-02")
  expect_identical(day$time, "15:00")
  expect_length(day$runs, 1)
  expect_identical(day$runs[[1]]$time, "12:30")
})

test_that("work_complete two-argument hooks receive the context", {
  hc_clean()
  s <- bt_setup()
  now <- sydney_midday()
  bt_folder(s, "batch-1", now, files = inbox_rain_files())
  testthat::local_mocked_bindings(ingest_dir = function(path, ..., db) {
    hc_add_project(db, "hc-new-1", "HC-NEW-1")
    list(n_events_committed = 1L, rows_new = 1L)
  })
  rec <- record_hook("work_complete")
  run_inbox(s, now = now, batch = inbox_batches())
  expect_length(rec$calls, 1)
  expect_identical(rec$calls[[1]]$arg$name, "HC-NEW-1")
  ctx <- rec$calls[[1]]$context
  expect_identical(names(ctx), hc_names)
  expect_identical(ctx$source, "inbox_run")
  expect_identical(ctx$report_dir, s$report_dir)
  expect_null(ctx$day)
})

# ---- register_hook(renderer =) -------------------------------------------------------------------

test_that("renderer = TRUE is for after_status and after_run only; NA (or anything but one TRUE/FALSE) is an error; nothing is registered by a refused call", {
  hc_clean()
  f <- function(x, context) NULL
  expect_error(register_hook("work_complete", f, renderer = TRUE), class = "sampletidy_error")
  for (bad in list(NA, NULL, "TRUE", 1, c(TRUE, FALSE), logical(0))) {
    expect_error(register_hook("after_run", f, renderer = bad), class = "sampletidy_error")
    expect_error(register_hook("after_status", f, renderer = bad), class = "sampletidy_error")
  }
  for (ev in c("after_run", "after_status", "work_complete")) expect_length(hooks(ev), 0)

  expect_no_error(register_hook("after_status", f, renderer = TRUE))
  expect_no_error(register_hook("after_run", f, renderer = TRUE))
  expect_no_error(register_hook("work_complete", f, renderer = FALSE))
  expect_length(hooks("after_status"), 1)
})

test_that("clear_hooks() resets the renderer flags with the hooks", {
  hc_clean()
  f <- function(x, context) NULL
  register_hook("after_status", f, renderer = TRUE)
  register_hook("after_status", f)
  register_hook("after_run", f, renderer = TRUE)
  expect_identical(sampleTidy:::.hook_env$renderer[["after_status"]], c(TRUE, FALSE))
  clear_hooks("after_status")
  expect_length(sampleTidy:::.hook_env$renderer[["after_status"]], 0)
  expect_identical(sampleTidy:::.hook_env$renderer[["after_run"]], TRUE)
  clear_hooks()
  for (ev in c("after_status", "after_run")) {
    expect_length(sampleTidy:::.hook_env$renderer[[ev]], 0)
  }
  # observable: with the flags gone, a plain hook is not a renderer
  register_hook("after_status", f)
  s <- bt_setup()
  expect_warning(suppressMessages(
    import_status(db = s$db, input_dir = s$input_dir, report_dir = s$report_dir)),
    class = "sampletidy_deprecated")
})

# ---- problem strings --------------------------------------------------------------------------------

test_that("a failing second-registered hook is 'hook after_run[2] failed: boom' in status.json; no problem ever says [default]", {
  hc_clean()
  s <- bt_setup()
  register_hook("after_run", function(x) NULL)
  register_hook("after_run", function(x, context) stop("boom"))
  register_hook("after_status", function(x) stop("sboom"))
  res <- run_inbox(s, now = bt_now(), batch = inbox_batches())
  expect_true(res$ran)
  p <- hc_problems(s)
  expect_true("hook after_run[2] failed: boom" %in% p)
  expect_true("hook after_status[1] failed: sboom" %in% p)
  expect_false("hook after_run[1] failed: boom" %in% p)
  expect_false(any(grepl("[default]", p, fixed = TRUE)))
})

test_that("the index is the registration index also when only renderers run (the deprecated wrapper)", {
  hc_clean()
  s <- bt_setup()
  register_hook("after_status", function(x, context) NULL)                         # [1], not a renderer
  register_hook("after_status", function(x, context) stop("rboom"), renderer = TRUE) # [2]
  quiet_run(import_status(db = s$db, input_dir = s$input_dir, report_dir = s$report_dir,
                          now = bt_now()))
  expect_true("hook after_status[2] failed: rboom" %in% hc_problems(s))
})

# ---- replace_default ---------------------------------------------------------------------------------

test_that("replace_default TRUE or FALSE makes no difference, and no markdown is written either way", {
  for (rd in c(TRUE, FALSE)) {
    hc_clean()
    s <- bt_setup()
    now <- bt_now()
    bt_folder(s, "batch-1", now, files = inbox_rain_files())
    testthat::local_mocked_bindings(ingest_dir = bt_ingest())
    fired <- character(0)
    register_hook("after_run", function(x) fired <<- c(fired, "after_run"), replace_default = rd)
    register_hook("after_status", function(x) fired <<- c(fired, "after_status"), replace_default = rd)
    run_inbox(s, now = now, batch = inbox_batches())
    expect_identical(fired, c("after_run", "after_status"), info = paste("replace_default", rd))
    expect_length(report_md_files(s$report_dir), 0)
    expect_false(any(grepl("[default]", hc_problems(s), fixed = TRUE)))
  }
})
