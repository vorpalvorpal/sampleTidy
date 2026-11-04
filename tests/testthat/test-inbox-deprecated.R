# Stage 2 of the layer move: import_status() and import_report() are deprecated
# wrappers for one release. They write the JSON (import_status) and run only the
# hooks tagged renderer = TRUE; with none registered they warn
# (sampletidy_deprecated) and write no markdown.

dp_clean <- function(env = parent.frame()) {
  clear_hooks()
  withr::defer(clear_hooks(), envir = env)
  invisible(NULL)
}

dp_status <- function(s, now = sydney_midday(), ...) {
  import_status(db = s$db, input_dir = s$input_dir, report_dir = s$report_dir, now = now, ...)
}

dp_report <- function(s, now = sydney_midday()) {
  import_report(db = s$db, report_dir = s$report_dir, now = now)
}

# ---- import_status() ---------------------------------------------------------------------------

test_that("import_status() with no renderer warns sampletidy_deprecated, writes both json files and no markdown, and invisibly returns <report_dir>/Import status.md", {
  dp_clean()
  s <- bt_setup()
  expect_warning(r <- withVisible(suppressMessages(dp_status(s))), class = "sampletidy_deprecated")
  expect_false(r$visible)
  expect_identical(r$value, file.path(s$report_dir, "Import status.md"))
  expect_true(file.exists(file.path(s$report_dir, "status.json")))
  expect_true(file.exists(file.path(s$report_dir, ".import-status.json")))
  expect_length(report_md_files(s$report_dir), 0)
  # the warning names the function and says what happened
  w <- tryCatch(suppressMessages(dp_status(s)), warning = function(w) conditionMessage(w))
  expect_match(w, "import_status()", fixed = TRUE)
  expect_match(w, "renderer", fixed = TRUE)
  expect_match(w, "status.json", fixed = TRUE)
})

test_that("import_status() with a non-renderer and a renderer after_status hook runs only the renderer, with (status, context) and source import_status; no warning; a failing renderer's problem is in status.json", {
  dp_clean()
  s <- bt_setup()
  plain <- record_hook("after_status")
  rend <- record_hook("after_status", renderer = TRUE)
  expect_no_warning(suppressMessages(dp_status(s)))
  expect_length(plain$calls, 0)
  expect_length(rend$calls, 1)
  ctx <- rend$calls[[1]]$context
  expect_identical(ctx$source, "import_status")
  expect_identical(ctx$report_dir, s$report_dir)
  expect_identical(ctx$input_dir, s$input_dir)
  expect_identical(ctx$db, s$db)
  expect_null(ctx$day)
  expect_identical(rend$calls[[1]]$arg$timezone, ctx$timezone)
  expect_true("updated" %in% names(rend$calls[[1]]$arg))

  dp_clean()
  register_hook("after_status", function(x, context) NULL)
  register_hook("after_status", function(x, context) stop("kaboom"), renderer = TRUE)
  expect_no_warning(suppressMessages(dp_status(s)))
  p <- as.character(unlist(read_status_json(s$report_dir)$problems))
  expect_true("hook after_status[2] failed: kaboom" %in% p)
  # the rewritten json files agree
  a <- file.path(s$report_dir, "status.json")
  b <- file.path(s$report_dir, ".import-status.json")
  expect_identical(readBin(a, "raw", file.size(a)), readBin(b, "raw", file.size(b)))
})

test_that("import_status(dry_run = 'x') is a dry run: dry_run TRUE and dry_run_plan null", {
  dp_clean()
  s <- bt_setup()
  quiet_run(dp_status(s, dry_run = "x"))
  js <- read_status_json(s$report_dir)
  expect_true(js$dry_run)
  expect_true("dry_run_plan" %in% names(js))
  expect_null(js$dry_run_plan)
})

test_that("a newline in a check's error message is kept raw in flag_errors; rendering is not the core's job", {
  dp_clean()
  s <- fl_status_setup()
  f <- function() stop("tables\nare unreadable")
  fl_status(s, checks = f)
  js <- fl_status_json(s)
  expect_identical(vapply(js$flag_errors, function(e) e$check, ""), "checks")
  expect_match(js$flag_errors[[1]]$message, "tables\nare unreadable", fixed = TRUE)
  txt <- paste(readLines(file.path(s$report_dir, "status.json"), warn = FALSE), collapse = "\n")
  expect_match(txt, "tables\\nare unreadable", fixed = TRUE)    # escaped in the file, never a bullet
})

# ---- import_report() ---------------------------------------------------------------------------

test_that("import_report() with no renderer warns, writes nothing, and returns <report_dir>/<local date>-imports.md", {
  dp_clean()
  s <- bt_setup()
  now <- sydney_midday()
  before <- list.files(s$report_dir, all.files = TRUE, no.. = TRUE)
  expect_warning(r <- withVisible(suppressMessages(dp_report(s, now))), class = "sampletidy_deprecated")
  expect_false(r$visible)
  expect_identical(r$value, file.path(s$report_dir, paste0(sydney_date(now), "-imports.md")))
  expect_identical(list.files(s$report_dir, all.files = TRUE, no.. = TRUE), before)
  expect_false(file.exists(r$value))
  # a hook that is not a renderer does not count
  register_hook("after_run", function(x, context) NULL)
  expect_warning(suppressMessages(dp_report(s, now)), class = "sampletidy_deprecated")
})

test_that("import_report() with a renderer: it gets run NULL and a non-NULL day, even with no news; a non-renderer after_run hook is not called", {
  dp_clean()
  s <- bt_setup()
  now <- sydney_midday()
  plain <- record_hook("after_run")
  rend <- record_hook("after_run", renderer = TRUE)
  expect_no_warning(suppressMessages(dp_report(s, now)))
  expect_length(plain$calls, 0)
  expect_length(rend$calls, 1)
  expect_null(rend$calls[[1]]$arg)
  ctx <- rend$calls[[1]]$context
  expect_identical(ctx$source, "import_report")
  expect_identical(ctx$report_dir, s$report_dir)
  expect_true(is.na(ctx$input_dir))
  expect_identical(ctx$db, s$db)
  expect_false(is.null(ctx$day))
  expect_identical(ctx$day$date, sydney_date(now))
  expect_length(ctx$day$runs, 0)
})

test_that("import_report(): a failing renderer is a sampletidy_hook_failed warning with the standard problem string", {
  dp_clean()
  s <- bt_setup()
  register_hook("after_run", function(x, context) NULL)
  register_hook("after_run", function(x, context) stop("kaboom"), renderer = TRUE)
  expect_warning(suppressMessages(dp_report(s)), class = "sampletidy_hook_failed")
  w <- tryCatch(suppressMessages(dp_report(s)), warning = function(w) conditionMessage(w))
  expect_match(w, "hook after_run[2] failed: kaboom", fixed = TRUE)
})
