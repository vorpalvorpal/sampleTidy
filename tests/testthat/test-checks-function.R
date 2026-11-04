# Stage 1 of the layer move: `checks` may be a zero-argument function (spec
# A6). inbox_run()/import_status() call it on EVERY status build, inside the
# flags tryCatch, so a deployment can re-read its tables each time and a
# failure there degrades to an empty Flags section with a visible error.
# import_flags() itself stays list-only.

cf_checks <- function() {
  sx_checks(site_names = c(N = "Northvale"),
            schedule = fl_schedule(list(site = "N", stream = "field", months = "8")))
}

cf_run <- function(s, checks, now = fl_now()) {
  quiet_run(inbox_run(input_dir = s$input_dir, db = s$db, backup_dir = s$backup_dir,
                      report_dir = s$report_dir, now = now, checks = checks))
}

test_that("checks function: called once per status build (a run, then a status refresh); same flags as the list it returns", {
  s <- fl_status_setup()
  n <- 0L
  f <- function() { n <<- n + 1L; cf_checks() }
  r1 <- cf_run(s, f)
  expect_identical(r1$action, "run")
  expect_identical(n, 1L)
  unlink(status_note_path(s$report_dir))
  Sys.setFileTime(s$db, Sys.time() + 120)          # DB stat changed -> "status"
  r2 <- cf_run(s, f, now = fl_now() + 3600)
  expect_identical(r2$action, "status")
  expect_identical(n, 2L)

  # the flags equal those from the list the function returns
  s2 <- fl_status_setup()
  cf_run(s2, cf_checks())
  js_fun <- fl_status_json(s)
  js_list <- fl_status_json(s2)
  keyed <- function(js) {
    k <- vapply(js$flags, function(x) x$key, "")
    js$flags[order(k)]
  }
  expect_gt(length(js_list$flags), 0)
  strip <- function(fl) lapply(fl, function(x) x[setdiff(names(x), "first_seen")])
  expect_equal(strip(keyed(js_fun)), strip(keyed(js_list)))
  expect_length(js_fun$flag_errors, 0)
})

test_that("checks function: import_status() accepts one too, and calls it on each build", {
  s <- fl_status_setup()
  n <- 0L
  f <- function() { n <<- n + 1L; cf_checks() }
  fl_status(s, checks = f)
  fl_status(s, checks = f)
  expect_identical(n, 2L)
  expect_gt(length(fl_status_json(s)$flags), 0)
})

test_that("checks function: import_flags() stays list-only", {
  db <- fl_db()
  expect_error(import_flags(db = db, now = fl_now(), checks = function() list()))
})

test_that("checks function: one that errors still writes the Flags section, records the error, and does not fail the run", {
  s <- fl_status_setup()
  f <- function() stop("tables are unreadable")
  expect_no_error(r <- cf_run(s, f))
  expect_identical(r$action, "run")
  sec <- md_section(read_status_note(s$report_dir), "Flags")
  expect_true(any(grepl("check checks failed: tables are unreadable", sec, fixed = TRUE)))
  js <- fl_status_json(s)
  expect_identical(vapply(js$flag_errors, function(e) e$check, ""), "checks")
  expect_match(js$flag_errors[[1]]$message, "tables are unreadable", fixed = TRUE)
  expect_length(js$flags, 0)
})

test_that("checks function: a result that is not a list is handled the same way", {
  for (bad in list("not a list", 1:3)) {
    s <- fl_status_setup()
    f <- function() bad
    expect_no_error(cf_run(s, f))
    sec <- md_section(read_status_note(s$report_dir), "Flags")
    expect_true(any(grepl("check checks failed: ", sec, fixed = TRUE)))
    js <- fl_status_json(s)
    expect_identical(vapply(js$flag_errors, function(e) e$check, ""), "checks")
    expect_length(js$flags, 0)
  }
})

test_that("checks function: the checks that follow a failure recover on the next build (flags return)", {
  s <- fl_status_setup()
  ok <- FALSE
  f <- function() if (ok) cf_checks() else stop("transient")
  cf_run(s, f)
  expect_length(fl_status_json(s)$flags, 0)
  ok <- TRUE
  unlink(status_note_path(s$report_dir))
  Sys.setFileTime(s$db, Sys.time() + 120)
  cf_run(s, f, now = fl_now() + 3600)
  js <- fl_status_json(s)
  expect_length(js$flag_errors, 0)
  expect_gt(length(js$flags), 0)
})
