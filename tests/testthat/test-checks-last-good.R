# When the checks hook fails, the status carries the previous run's flags
# forward unchanged (so first_seen survives), marks them as carried, and says
# when the check that produced them last succeeded.

lg_checks <- function() {
  sx_checks(site_names = c(N = "Northvale"),
            schedule = fl_schedule(list(site = "N", stream = "field", months = "7;8")))
}

lg_files <- function(s) file.path(s$report_dir, c("status.json", ".import-status.json"))

# One inbox_run(); `bump` is a per-call counter so the DB stat changes every time.
lg_bump <- new.env()
lg_run <- function(s, checks, now) {
  lg_bump$n <- (if (is.null(lg_bump$n)) 0 else lg_bump$n) + 1
  Sys.setFileTime(s$db, Sys.time() + 120 * lg_bump$n)
  quiet_run(inbox_run(input_dir = s$input_dir, db = s$db, backup_dir = s$backup_dir,
                      report_dir = s$report_dir, now = now, checks = checks))
}

lg_js <- function(s) read_status_json(s$report_dir)
lg_msg <- function(js) {
  m <- Filter(function(e) identical(e$check, "checks"), js$flag_errors)
  if (length(m)) m[[1]]$message else NULL
}
lg_checks_errs <- function(js) vapply(js$flag_errors, function(e) e$check, "")

# A good run at t1 (>= 2 flags), then a failing run at t2; returns the state.
lg_good_then_fail <- function(fail = function() stop("ledger unreadable")) {
  s <- fl_status_setup(env = parent.frame())
  ok <- TRUE
  f <- function() if (ok) lg_checks() else fail()
  t1 <- fl_now()
  lg_run(s, f, t1)
  js1 <- lg_js(s)
  ok <- FALSE
  r2 <- lg_run(s, f, t1 + 3 * 3600)
  list(s = s, f = f, js1 = js1, js2 = lg_js(s), r2 = r2, t1 = t1,
       set_ok = function(v) ok <<- v)
}

test_that("fixture: the good run has at least two flags, checked_at = updated, not carried", {
  s <- fl_status_setup()
  lg_run(s, lg_checks, fl_now())
  js <- lg_js(s)
  expect_gte(length(js$flags), 2)
  expect_false(js$flags_carried_forward)
  expect_identical(js$flags_checked_at, js$updated)
  expect_false("checks" %in% lg_checks_errs(js))
})

test_that("failure after a good run: flags carried forward unchanged, first_seen included", {
  x <- lg_good_then_fail()
  expect_true(x$r2$action %in% c("run", "status"))
  expect_gte(length(x$js1$flags), 2)
  expect_identical(x$js2$flags, x$js1$flags)
})

test_that("failure after a good run: the checks error stays visible with the hook's own message", {
  x <- lg_good_then_fail()
  expect_true("checks" %in% lg_checks_errs(x$js2))
  expect_match(lg_msg(x$js2), "ledger unreadable", fixed = TRUE)
})

test_that("failure after a good run: carried flag is TRUE and checked_at is the earlier updated", {
  x <- lg_good_then_fail()
  expect_true(x$js2$flags_carried_forward)
  expect_identical(x$js2$flags_checked_at, x$js1$updated)
  expect_false(identical(x$js2$flags_checked_at, x$js2$updated))
})

test_that("failure message says the flags are from the last successful check, with the time", {
  x <- lg_good_then_fail()
  m <- lg_msg(x$js2)
  expect_match(m, "from the last successful check", fixed = TRUE)
  expect_true(is.character(x$js2$flags_checked_at) && grepl(x$js2$flags_checked_at, m, fixed = TRUE))
  expect_match(m, "ledger unreadable", fixed = TRUE)
})

test_that("a non-list result from the hook is carried forward the same way", {
  x <- lg_good_then_fail(fail = function() "not a list")
  expect_identical(x$js2$flags, x$js1$flags)
  expect_true(x$js2$flags_carried_forward)
  expect_identical(x$js2$flags_checked_at, x$js1$updated)
  expect_true("checks" %in% lg_checks_errs(x$js2))
})

test_that("site_names is carried forward with the flags", {
  x <- lg_good_then_fail()
  expect_identical(x$js1$site_names$N, "Northvale")
  expect_identical(x$js2$site_names, x$js1$site_names)
})

test_that("two failures in a row keep the ORIGINAL success time and flags", {
  x <- lg_good_then_fail()
  lg_run(x$s, x$f, x$t1 + 6 * 3600)
  js3 <- lg_js(x$s)
  expect_identical(js3$flags, x$js1$flags)
  expect_true(js3$flags_carried_forward)
  expect_identical(js3$flags_checked_at, x$js1$updated)
  expect_false(identical(js3$updated, x$js1$updated))
  expect_match(lg_msg(js3), x$js1$updated, fixed = TRUE)
})

test_that("recovery: flags that still hold keep their original first_seen; markers reset", {
  x <- lg_good_then_fail()
  first <- vapply(x$js1$flags, function(f) f$first_seen, "")
  expect_gte(length(first), 2)
  x$set_ok(TRUE)
  lg_run(x$s, x$f, x$t1 + 6 * 3600)
  js3 <- lg_js(x$s)
  expect_false(js3$flags_carried_forward)
  expect_identical(js3$flags_checked_at, js3$updated)
  expect_false("checks" %in% lg_checks_errs(js3))
  expect_gte(length(js3$flags), 2)
  got <- stats::setNames(vapply(js3$flags, function(f) f$first_seen, ""),
                         vapply(js3$flags, function(f) f$key, ""))
  was <- stats::setNames(first, vapply(x$js1$flags, function(f) f$key, ""))
  expect_identical(unname(got[names(was)]), unname(was))
  expect_true(all(got == "2026-10-19T02:00:00Z"))
})

test_that("status refresh path (action 'status') carries forward too", {
  s <- fl_status_setup()
  ok <- TRUE
  f <- function() if (ok) lg_checks() else stop("ledger unreadable")
  lg_run(s, f, fl_now())
  js1 <- lg_js(s)
  ok <- FALSE
  Sys.setFileTime(s$db, Sys.time() + 5000)
  r <- quiet_run(inbox_run(input_dir = s$input_dir, db = s$db, backup_dir = s$backup_dir,
                           report_dir = s$report_dir, now = fl_now() + 3600, checks = f))
  expect_identical(r$action, "status")
  js2 <- lg_js(s)
  expect_identical(js2$flags, js1$flags)
  expect_true(js2$flags_carried_forward)
  expect_identical(js2$flags_checked_at, js1$updated)
})

test_that("import_status() carries forward too (reading .import-status.json)", {
  s <- fl_status_setup()
  ok <- TRUE
  f <- function() if (ok) lg_checks() else stop("ledger unreadable")
  fl_status(s, checks = f, now = fl_now())
  js1 <- fl_status_json(s)
  expect_gte(length(js1$flags), 2)
  ok <- FALSE
  fl_status(s, checks = f, now = fl_now() + 3 * 3600)
  js2 <- fl_status_json(s)
  expect_identical(js2$flags, js1$flags)
  expect_true(js2$flags_carried_forward)
  expect_identical(js2$flags_checked_at, js1$updated)
  expect_match(js2$flag_errors[[1]]$message, "from the last successful check", fixed = TRUE)
})

test_that("falls back to .import-status.json when status.json does not exist", {
  x <- lg_good_then_fail()
  unlink(file.path(x$s$report_dir, "status.json"))
  expect_true(file.exists(file.path(x$s$report_dir, ".import-status.json")))
  lg_run(x$s, x$f, x$t1 + 6 * 3600)
  js3 <- lg_js(x$s)
  expect_identical(js3$flags, x$js1$flags)
  expect_true(js3$flags_carried_forward)
})

test_that("previous status without flags_checked_at (older code): uses its `updated`", {
  s <- fl_status_setup()
  lg_run(s, lg_checks, fl_now())
  for (p in lg_files(s)) if (file.exists(p)) {
    js <- jsonlite::read_json(p, simplifyVector = FALSE)
    js$flags_checked_at <- NULL
    js$flags_carried_forward <- NULL
    jsonlite::write_json(js, p, auto_unbox = TRUE, null = "null")
  }
  old <- lg_js(s)
  expect_false("flags_checked_at" %in% names(old))
  lg_run(s, function() stop("ledger unreadable"), fl_now() + 3 * 3600)
  js <- lg_js(s)
  expect_identical(js$flags, old$flags)
  expect_true(js$flags_carried_forward)
  expect_identical(js$flags_checked_at, old$updated)
})

lg_fallback_expect <- function(s) {
  r <- NULL
  expect_no_error(r <- lg_run(s, function() stop("ledger unreadable"), fl_now() + 3 * 3600))
  expect_true(r$action %in% c("run", "status"))
  js <- lg_js(s)
  expect_length(js$flags, 0)
  expect_true("checks" %in% lg_checks_errs(js))
  expect_false(js$flags_carried_forward)
  expect_true("flags_checked_at" %in% names(js))
  expect_null(js$flags_checked_at)
  expect_false(grepl("from the last successful check", lg_msg(js), fixed = TRUE))
}

lg_seed <- function(s, txt) {
  for (p in lg_files(s)) writeLines(txt, p)
}

test_that("fallback: no previous status file", {
  s <- fl_status_setup()
  lg_fallback_expect(s)
})

test_that("fallback: previous status is not valid JSON", {
  s <- fl_status_setup()
  lg_seed(s, "{ this is not json")
  lg_fallback_expect(s)
})

test_that("fallback: previous status is a JSON value that is not an object", {
  s <- fl_status_setup()
  lg_seed(s, "[1, 2, 3]")
  lg_fallback_expect(s)
})

test_that("fallback: previous status has no flags key", {
  s <- fl_status_setup()
  lg_seed(s, '{"updated": "2026-10-19 12:00"}')
  lg_fallback_expect(s)
})

test_that("fallback: previous status has flags but no usable time", {
  s <- fl_status_setup()
  lg_run(s, lg_checks, fl_now())
  for (p in lg_files(s)) if (file.exists(p)) {
    js <- jsonlite::read_json(p, simplifyVector = FALSE)
    js$updated <- NULL
    js$flags_checked_at <- NULL
    jsonlite::write_json(js, p, auto_unbox = TRUE, null = "null")
  }
  lg_fallback_expect(s)
})

test_that("fallback: a present-but-null flags_checked_at is unusable (even with a good `updated`)", {
  s <- fl_status_setup()
  lg_run(s, lg_checks, fl_now())
  for (p in lg_files(s)) if (file.exists(p)) {
    js <- jsonlite::read_json(p, simplifyVector = FALSE)
    js["flags_checked_at"] <- list(NULL)
    jsonlite::write_json(js, p, auto_unbox = TRUE, null = "null")
  }
  expect_true(is.character(lg_js(s)$updated))
  lg_fallback_expect(s)
})

test_that("a successful hook returning zero flags means zero flags, not carried", {
  s <- fl_status_setup()
  ok <- TRUE
  f <- function() if (ok) lg_checks() else fl_checks()
  lg_run(s, f, fl_now())
  expect_gte(length(lg_js(s)$flags), 2)
  ok <- FALSE
  lg_run(s, f, fl_now() + 3 * 3600)
  js <- lg_js(s)
  expect_length(js$flags, 0)
  expect_false(js$flags_carried_forward)
  expect_identical(js$flags_checked_at, js$updated)
  expect_length(js$flag_errors, 0)
})

test_that("an error inside import_flags() (not the hook) does not carry forward", {
  s <- fl_status_setup()
  lg_run(s, lg_checks, fl_now())
  expect_gte(length(lg_js(s)$flags), 2)
  testthat::local_mocked_bindings(import_flags = function(...) stop("boom"))
  lg_run(s, lg_checks, fl_now() + 3 * 3600)
  js <- lg_js(s)
  expect_length(js$flags, 0)
  expect_true("import_flags" %in% lg_checks_errs(js))
  expect_false("checks" %in% lg_checks_errs(js))
  expect_false(js$flags_carried_forward)
  expect_true("flags_checked_at" %in% names(js))
  expect_null(js$flags_checked_at)
})

test_that("checks = NULL: neither new key appears", {
  s <- fl_status_setup()
  lg_run(s, NULL, fl_now())
  js <- lg_js(s)
  expect_false("flags_carried_forward" %in% names(js))
  expect_false("flags_checked_at" %in% names(js))
  expect_false("flags" %in% names(js))
})
