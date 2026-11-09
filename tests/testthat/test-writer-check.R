# PLAN-21 phase (a), section 2: the writer check.
#
# st_config("writer_check"): NULL (default) or a function, code-only (never an
# env var). inbox_run() calls it FIRST, right after argument validation, as
# fn(db). Exactly isTRUE() allows the run, which then proceeds as today.
# Anything else refuses, with the reason:
#   the value itself if it is one non-empty string; else attr(value, "reason")
#   if that is one non-empty string; else "writer check refused".
#   An error inside fn refuses with "writer check failed: <conditionMessage>".
# A refused run never opens/creates/locks/backs up/snapshots the DB, writes no
# .imports.state, takes no inbox lock, fires no hooks, leaves the input alone,
# and returns (invisibly) the usual list with action "writer_check",
# ran FALSE and writer_check = <reason>. It records itself only in:
#   1. one line appended to events.jsonl (report_dir created if needed):
#      action "writer_check", started_at, writer_check = reason; never
#      .imports.log, and never in later statuses or day digests;
#   2. an EXISTING status.json (and the identical .import-status.json):
#      top-level writer_check = reason, problem
#      "Import refused by the writer check: <reason>" first in problems (not
#      duplicated), every other field (flags and first_seen included) as was.
# The next allowed run rebuilds the status as today: no writer_check field and
# no such problem. Synthetic fixtures only.

# ---- helpers -------------------------------------------------------------------------------

wc_problem <- function(reason) paste0("Import refused by the writer check: ", reason)

wc_utc <- function(x) format(x, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")

wc_usual <- c("action", "ran", "locked", "dry_run", "started_at", "ended_at",
              "folders_seen", "folders_settled", "folders_processed",
              "folders_arriving", "folders", "backup_path", "errors", "stale_lock")

#' A writer check that refuses with `value` and records each call's argument.
wc_check <- function(value) {
  rec <- new.env()
  rec$args <- list()
  rec$fn <- function(db) {
    rec$args[[length(rec$args) + 1L]] <- db
    value
  }
  rec
}

#' Set st_config("writer_check") for the rest of the calling test.
wc_use <- function(fn, env = parent.frame()) {
  withr::local_options(list(sampletidy.writer_check = fn), .local_envir = env)
  invisible(fn)
}

#' inbox_setup() plus one settled, importable batch folder and recording hooks
#' on every event. The DB's mtime is moved an hour back so a touch would show.
wc_setup <- function(env = parent.frame()) {
  s <- inbox_setup(env)
  s$now <- Sys.time()
  make_inbox_folder(s$input_dir, "batch-1", inbox_proj_a_files(), now = s$now)
  Sys.setFileTime(s$db, s$now - 3600)
  s$hooks <- list(after_run = record_hook("after_run", env = env),
                  after_status = record_hook("after_status", env = env),
                  work_complete = record_hook("work_complete", env = env))
  s
}

wc_hook_calls <- function(s) vapply(s$hooks, function(h) length(h$calls), integer(1))

wc_events <- function(report_dir) {
  p <- file.path(report_dir, "events.jsonl")
  if (!file.exists(p)) return(list())
  l <- readLines(p, warn = FALSE)
  lapply(l[nzchar(trimws(l))], jsonlite::fromJSON, simplifyVector = FALSE)
}

wc_ls <- function(dir) sort(list.files(dir, all.files = TRUE, recursive = TRUE, no.. = TRUE))

#' inbox_run() on paths only: no seeded DB is needed for a refused run.
wc_bare <- function(env = parent.frame()) {
  d <- withr::local_tempdir(.local_envir = env)
  s <- list(dir = d, db = file.path(d, "db", "monitoring.duckdb"),
            input_dir = file.path(d, "input"), backup_dir = file.path(d, "backup"),
            report_dir = file.path(d, "report"))
  dir.create(s$input_dir)
  s
}

wc_run <- function(s, now = Sys.time(), ...) {
  quiet_run(inbox_run(input_dir = s$input_dir, db = s$db, backup_dir = s$backup_dir,
                      report_dir = s$report_dir, now = now, ...))
}

# ---- the config key -----------------------------------------------------------------------

test_that("writer_check defaults to NULL and is listed in st_capabilities()", {
  withr::local_options(list(sampletidy.writer_check = NULL))
  withr::local_envvar(c(SAMPLETIDY_WRITER_CHECK = NA))
  expect_null(st_config("writer_check"))
  expect_true("writer_check" %in% st_capabilities())
})

test_that("writer_check is code-only: an env var for it aborts sampletidy_error rather than being read", {
  withr::local_options(list(sampletidy.writer_check = NULL))
  withr::local_envvar(c(SAMPLETIDY_WRITER_CHECK = "TRUE"))
  expect_error(st_config("writer_check"), class = "sampletidy_error")
})

test_that("writer_check set in code is a function and round-trips", {
  withr::local_options(list(sampletidy.writer_check = NULL))
  f <- function(db) TRUE
  st_config("writer_check", f)
  expect_identical(st_config("writer_check"), f)
})

# ---- the refusal: what it returns and records ------------------------------------------------

test_that("a refused run returns, invisibly, the usual list with action writer_check, ran FALSE and the reason", {
  s <- wc_bare()
  ck <- wc_check("machine B holds the writer lease")
  wc_use(ck$fn)
  now <- as.POSIXct("2026-11-09 01:02:03", tz = "UTC")
  expect_invisible(inbox_run(input_dir = s$input_dir, db = s$db, backup_dir = s$backup_dir,
                             report_dir = s$report_dir, now = now))
  res <- wc_run(s, now = now)
  expect_true(all(c(wc_usual, "writer_check") %in% names(res)))
  expect_identical(res$action, "writer_check")
  expect_false(res$ran)
  expect_false(res$locked)
  expect_identical(res$writer_check, "machine B holds the writer lease")
  expect_identical(res$started_at, "2026-11-09T01:02:03Z")
  expect_length(res$folders_processed, 0)
})

test_that("the writer check is called once per run with the db path", {
  s <- wc_bare()
  ck <- wc_check(FALSE)
  wc_use(ck$fn)
  wc_run(s)
  expect_length(ck$args, 1L)
  expect_identical(ck$args[[1]], s$db)
})

test_that("a refused run with a missing db path: nothing is created at the path, beside it or in its folder", {
  s <- wc_bare()
  wc_use(wc_check("refused")$fn)
  res <- wc_run(s)
  expect_identical(res$action, "writer_check")
  expect_false(file.exists(s$db))
  expect_false(file.exists(paste0(s$db, ".wal")))
  expect_false(file.exists(paste0(s$db, ".inbox.lock")))
  expect_false(dir.exists(dirname(s$db)))
  expect_false(dir.exists(s$backup_dir))
})

test_that("a refused run creates report_dir if needed and writes exactly one events.jsonl line there, nothing else", {
  s <- wc_bare()
  s$report_dir <- file.path(s$dir, "deep", "report")
  wc_use(wc_check("refused for the test")$fn)
  now <- as.POSIXct("2026-11-09 04:05:06", tz = "UTC")
  wc_run(s, now = now)
  expect_identical(wc_ls(s$report_dir), "events.jsonl")
  ev <- wc_events(s$report_dir)
  expect_length(ev, 1L)
  expect_identical(ev[[1]]$action, "writer_check")
  expect_identical(ev[[1]]$started_at, "2026-11-09T04:05:06Z")
  expect_identical(ev[[1]]$writer_check, "refused for the test")
})

test_that("a refused run appends to an existing events.jsonl and leaves .imports.log alone", {
  s <- wc_bare()
  t0 <- as.POSIXct("2026-11-08 01:00:00", tz = "UTC")
  old <- c(inbox_log_line(t0), inbox_log_line(t0 + 3600))
  write_events(s$report_dir, old)
  writeLines(old, file.path(s$report_dir, ".imports.log"))
  log_md5 <- file_md5(file.path(s$report_dir, ".imports.log"))
  wc_use(wc_check("refused")$fn)
  wc_run(s)
  ev <- readLines(file.path(s$report_dir, "events.jsonl"))
  expect_length(ev, 3L)
  expect_identical(ev[1:2], old)
  expect_identical(jsonlite::fromJSON(ev[[3]])$action, "writer_check")
  expect_identical(file_md5(file.path(s$report_dir, ".imports.log")), log_md5)
})

test_that("a refused run does not create .imports.log", {
  s <- wc_bare()
  wc_use(wc_check("refused")$fn)
  wc_run(s)
  expect_false(file.exists(file.path(s$report_dir, ".imports.log")))
})

# ---- the refusal is fail-safe -------------------------------------------------------------------

test_that("a refused run over a real setup touches nothing: DB bytes and mtime, no WAL, no lock, no backup, no snapshot, no archive, no state, input intact", {
  s <- wc_setup()
  wc_use(wc_check("machine B is the writer")$fn)
  db_info <- file.info(s$db)[, c("size", "mtime")]
  db_md5 <- file_md5(s$db)
  input_before <- tree_snapshot(s$input_dir)

  res <- run_inbox(s, now = s$now)
  expect_identical(res$action, "writer_check")
  expect_false(res$ran)

  expect_identical(file.info(s$db)[, c("size", "mtime")], db_info)
  expect_identical(file_md5(s$db), db_md5)
  expect_false(file.exists(paste0(s$db, ".wal")))
  expect_false(file.exists(inbox_lock_path(s$db)))
  expect_length(wc_ls(s$backup_dir), 0)
  expect_length(wc_ls(s$snapshot_dir), 0)
  expect_length(wc_ls(s$archive_dir), 0)
  expect_identical(tree_snapshot(s$input_dir), input_before)
  expect_true(all(file.exists(file.path(s$input_dir, "batch-1", basename(inbox_proj_a_files())))))
  expect_false(file.exists(file.path(s$report_dir, ".imports.state")))
  expect_false(file.exists(file.path(s$report_dir, ".imports.log")))
  expect_identical(wc_ls(s$report_dir), "events.jsonl")
  expect_length(wc_events(s$report_dir), 1L)
})

test_that("a refused run fires no hooks", {
  s <- wc_setup()
  wc_use(wc_check(FALSE)$fn)
  run_inbox(s, now = s$now)
  expect_identical(unname(wc_hook_calls(s)), c(0L, 0L, 0L))
})

test_that("control: the same setup with no writer check imports, fires hooks and writes the state", {
  s <- wc_setup()
  withr::local_options(list(sampletidy.writer_check = NULL))
  res <- run_inbox(s, now = s$now)
  expect_true(res$ran)
  expect_identical(res$folders_processed, "batch-1")
  expect_gt(wc_hook_calls(s)[["after_run"]], 0L)
  expect_true(file.exists(file.path(s$report_dir, ".imports.state")))
})

test_that("a refused run leaves a held inbox lock exactly as it was", {
  s <- wc_setup()
  wc_use(wc_check("refused")$fn)
  lock <- write_inbox_lock(s$db, live_child_pid(), s$now - 60)
  before <- file_md5(lock)
  res <- run_inbox(s, now = s$now)
  expect_identical(res$action, "writer_check")
  expect_false(res$locked)
  expect_identical(file_md5(lock), before)
})

test_that("a refused run with an unreadable DB file returns normally (it never opens the DB)", {
  skip_on_os("windows")
  skip_if(identical(Sys.info()[["user"]], "root"), "root can read a mode-000 file")
  s <- wc_setup()
  wc_use(wc_check("refused")$fn)
  Sys.chmod(s$db, "000")
  withr::defer(Sys.chmod(s$db, "644"))
  res <- run_inbox(s, now = s$now)
  expect_identical(res$action, "writer_check")
  expect_identical(res$writer_check, "refused")
})

test_that("a refused dry run is refused too: nothing written but the event", {
  s <- wc_setup()
  wc_use(wc_check("refused")$fn)
  res <- run_inbox(s, now = s$now, dry_run = TRUE)
  expect_identical(res$action, "writer_check")
  expect_false(res$ran)
  expect_identical(wc_ls(s$report_dir), "events.jsonl")
})

# ---- order: first, after argument validation -----------------------------------------------------

test_that("the writer check runs before inbox_check(): a refusal never reaches it", {
  s <- wc_bare()
  seen <- character(0)
  testthat::local_mocked_bindings(inbox_check = function(...) {
    seen <<- c(seen, "inbox_check")
    "none"
  })
  wc_use(function(db) {
    seen <<- c(seen, "writer_check")
    "refused"
  })
  wc_run(s)
  expect_identical(seen, "writer_check")
})

test_that("an allowed run calls the writer check, then inbox_check()", {
  s <- wc_bare()
  seen <- character(0)
  testthat::local_mocked_bindings(inbox_check = function(...) {
    seen <<- c(seen, "inbox_check")
    "none"
  })
  wc_use(function(db) {
    seen <<- c(seen, "writer_check")
    TRUE
  })
  res <- wc_run(s)
  expect_identical(seen, c("writer_check", "inbox_check"))
  expect_identical(res$action, "none")
})

test_that("argument validation comes first: a bad argument errors without calling the writer check", {
  s <- wc_bare()
  ck <- wc_check("refused")
  wc_use(ck$fn)
  expect_error(quiet_run(inbox_run(input_dir = 1, db = s$db, backup_dir = s$backup_dir,
                                   report_dir = s$report_dir)))
  expect_error(quiet_run(inbox_run(input_dir = s$input_dir, db = s$db, backup_dir = s$backup_dir,
                                   report_dir = s$report_dir, keep_backups = -1)))
  expect_length(ck$args, 0L)
  expect_false(dir.exists(s$report_dir))
})

# ---- the reason ---------------------------------------------------------------------------------

test_that("the reason: a non-empty string is itself; a string 'TRUE' refuses with reason 'TRUE'", {
  for (v in c("machine B holds the lease", "TRUE", "true")) {
    s <- wc_bare()
    wc_use(wc_check(v)$fn)
    res <- wc_run(s)
    expect_identical(res$action, "writer_check", info = v)
    expect_identical(res$writer_check, v, info = v)
  }
})

test_that("the reason: attr(value, 'reason') when the value is not itself a non-empty string", {
  s <- wc_bare()
  wc_use(wc_check(structure(FALSE, reason = "generation 3 is newer than 2"))$fn)
  expect_identical(wc_run(s)$writer_check, "generation 3 is newer than 2")

  s <- wc_bare()
  wc_use(wc_check(structure(list(ok = FALSE), reason = "lease expired"))$fn)
  expect_identical(wc_run(s)$writer_check, "lease expired")

  s <- wc_bare()
  wc_use(wc_check(structure("", reason = "from the attribute"))$fn)
  expect_identical(wc_run(s)$writer_check, "from the attribute")
})

test_that("the reason: a non-empty string value wins over its reason attribute", {
  s <- wc_bare()
  wc_use(wc_check(structure("the value", reason = "the attribute"))$fn)
  expect_identical(wc_run(s)$writer_check, "the value")
})

test_that("the reason: anything else that is not exactly TRUE refuses with 'writer check refused'", {
  values <- list(FALSE, NA, NULL, 1, 1L, c(TRUE, TRUE), "", c("a", "b"), NA_character_,
                 list(TRUE), structure(FALSE, reason = ""), structure(FALSE, reason = c("a", "b")),
                 structure(FALSE, reason = NA_character_), structure(FALSE, reason = 1))
  for (i in seq_along(values)) {
    s <- wc_bare()
    wc_use(wc_check(values[[i]])$fn)
    res <- wc_run(s)
    expect_identical(res$action, "writer_check", info = i)
    expect_false(res$ran, info = i)
    expect_identical(res$writer_check, "writer check refused", info = i)
  }
})

test_that("an error inside the writer check refuses: 'writer check failed: <message>'", {
  s <- wc_bare()
  wc_use(function(db) stop("cannot read the lease file"))
  res <- wc_run(s)
  expect_identical(res$action, "writer_check")
  expect_false(res$ran)
  expect_identical(res$writer_check, "writer check failed: cannot read the lease file")
  expect_false(file.exists(s$db))
  ev <- wc_events(s$report_dir)
  expect_length(ev, 1L)
  expect_identical(ev[[1]]$writer_check, "writer check failed: cannot read the lease file")
})

test_that("an error inside the writer check over a real setup touches nothing either", {
  s <- wc_setup()
  wc_use(function(db) stop("boom"))
  db_md5 <- file_md5(s$db)
  input_before <- tree_snapshot(s$input_dir)
  res <- run_inbox(s, now = s$now)
  expect_identical(res$writer_check, "writer check failed: boom")
  expect_identical(file_md5(s$db), db_md5)
  expect_identical(tree_snapshot(s$input_dir), input_before)
  expect_length(wc_ls(s$backup_dir), 0)
  expect_false(file.exists(file.path(s$report_dir, ".imports.state")))
  expect_identical(unname(wc_hook_calls(s)), c(0L, 0L, 0L))
})

# ---- allowed -------------------------------------------------------------------------------------

test_that("exactly TRUE allows: the run proceeds as with no writer check", {
  s <- wc_setup()
  ck <- wc_check(TRUE)
  wc_use(ck$fn)
  res <- run_inbox(s, now = s$now)
  expect_length(ck$args, 1L)
  expect_identical(res$action, "run")
  expect_true(res$ran)
  expect_identical(res$folders_processed, "batch-1")
  expect_true(file.exists(file.path(s$report_dir, ".imports.state")))
  expect_true(file.exists(file.path(s$report_dir, "status.json")))
  expect_false("writer_check" %in% names(read_status_json(s$report_dir)))
})

test_that("a TRUE carrying a reason attribute is still exactly TRUE by isTRUE(), and allows", {
  s <- wc_setup()
  wc_use(wc_check(structure(TRUE, reason = "ignored"))$fn)
  res <- run_inbox(s, now = s$now)
  expect_true(res$ran)
})

test_that("writer_check NULL (the default) runs exactly as today", {
  s <- wc_setup()
  withr::local_options(list(sampletidy.writer_check = NULL))
  res <- run_inbox(s, now = s$now)
  expect_identical(res$action, "run")
  expect_true(res$ran)
  ev <- wc_events(s$report_dir)
  expect_length(ev, 1L)
  expect_identical(ev[[1]]$action, "run")
  expect_length(read_inbox_log(s$report_dir), 1L)
  js <- read_status_json(s$report_dir)
  expect_false("writer_check" %in% names(js))
})

# ---- the existing status -------------------------------------------------------------------------

test_that("with no status.json the refusal writes no status file", {
  s <- wc_setup()
  wc_use(wc_check("refused")$fn)
  run_inbox(s, now = s$now)
  expect_false(file.exists(file.path(s$report_dir, "status.json")))
  expect_false(file.exists(file.path(s$report_dir, ".import-status.json")))
})

test_that("an existing status.json gains writer_check and the problem first; every other field, flags and first_seen included, is unchanged", {
  s <- fl_status_setup()
  chk <- fl_checks(schedule = fl_schedule(list(site = "M", months = "8")))
  fl_status(s, checks = chk)
  before <- read_status_json(s$report_dir)
  expect_gte(length(before$flags), 1L)
  expect_identical(before$flags[[1]]$first_seen, "2026-10-19T02:00:00Z")

  wc_use(wc_check("machine B is the writer")$fn)
  res <- quiet_run(inbox_run(input_dir = s$input_dir, db = s$db, backup_dir = s$backup_dir,
                             report_dir = s$report_dir, now = fl_now() + 7200,
                             checks = fl_with_defaults(chk)))
  expect_identical(res$action, "writer_check")

  after <- read_status_json(s$report_dir)
  expect_identical(after$writer_check, "machine B is the writer")
  expect_identical(after$problems[[1]], wc_problem("machine B is the writer"))
  expect_identical(after$problems[-1], before$problems)
  keep <- setdiff(names(before), "problems")
  expect_identical(after[keep], before[keep])
  expect_setequal(names(after), c(names(before), "writer_check"))
  expect_identical(after$flags, before$flags)

  a <- file.path(s$report_dir, "status.json")
  b <- file.path(s$report_dir, ".import-status.json")
  expect_identical(readBin(a, "raw", file.size(a)), readBin(b, "raw", file.size(b)))
})

test_that("a second refusal does not duplicate the problem, and keeps it first", {
  s <- fl_status_setup()
  fl_status(s, checks = NULL)
  before <- read_status_json(s$report_dir)
  wc_use(wc_check("refused twice")$fn)
  wc_run(s)
  wc_run(s, now = Sys.time() + 60)
  after <- read_status_json(s$report_dir)
  probs <- unlist(after$problems)
  expect_identical(sum(probs == wc_problem("refused twice")), 1L)
  expect_identical(after$problems[[1]], wc_problem("refused twice"))
  expect_identical(after$problems[-1], before$problems)
  expect_length(wc_events(s$report_dir), 2L)
})

test_that("a refusal fires no after_status hook even when it rewrites status.json", {
  s <- fl_status_setup()
  fl_status(s, checks = NULL)
  rec <- record_hook("after_status")
  wc_use(wc_check("refused")$fn)
  wc_run(s)
  expect_length(rec$calls, 0L)
  expect_identical(read_status_json(s$report_dir)$writer_check, "refused")
})

# ---- after a refusal ------------------------------------------------------------------------------

test_that("the next allowed run rebuilds the status as today: no writer_check field and no refusal problem", {
  s <- inbox_setup()
  s$now <- Sys.time()
  withr::local_options(list(sampletidy.writer_check = NULL))
  run_inbox(s, now = s$now)                                   # empty inbox: a status exists
  expect_true(file.exists(file.path(s$report_dir, "status.json")))

  wc_use(wc_check("machine B is the writer")$fn)
  run_inbox(s, now = s$now + 60)
  expect_identical(read_status_json(s$report_dir)$writer_check, "machine B is the writer")

  wc_use(wc_check(TRUE)$fn)
  make_inbox_folder(s$input_dir, "batch-1", inbox_proj_a_files(), now = s$now)
  res <- run_inbox(s, now = s$now + 120)
  expect_true(res$ran)
  js <- read_status_json(s$report_dir)
  expect_false("writer_check" %in% names(js))
  expect_false(any(grepl("writer check", unlist(js$problems), ignore.case = TRUE)))
})

test_that("a refusal never surfaces in a later status: the previous run's problems and recent imports survive it", {
  s <- wc_setup()
  withr::local_options(list(sampletidy.writer_check = NULL))
  local_db_checks_pass()
  testthat::local_mocked_bindings(ingest_dir = function(path, ..., db) stop("ingest blew up"))
  res <- run_inbox(s, now = s$now)
  expect_true(res$ran)
  probs_before <- unlist(read_status_json(s$report_dir)$problems)
  expect_true(any(grepl("batch-1 failed: ingest blew up", probs_before, fixed = TRUE)))

  wc_use(wc_check("machine B is the writer")$fn)
  run_inbox(s, now = s$now + 60)

  # Allowed again; only the DB changed, so this is a status refresh.
  wc_use(NULL)
  Sys.setFileTime(s$db, s$now + 600)
  res2 <- run_inbox(s, now = s$now + 120)
  expect_identical(res2$action, "status")
  js <- read_status_json(s$report_dir)
  probs <- unlist(js$problems)
  expect_false("writer_check" %in% names(js))
  expect_false(any(grepl("writer check", probs, ignore.case = TRUE)))
  expect_true(any(grepl("batch-1 failed: ingest blew up", probs, fixed = TRUE)))
})

test_that("a refusal is not a run in the day digest handed to after_run", {
  s <- wc_setup()
  withr::local_options(list(sampletidy.writer_check = NULL))
  testthat::local_mocked_bindings(ingest_dir = bt_ingest(wo = "ES9990001", site = "N"))
  wc_use(wc_check("machine B is the writer")$fn)
  run_inbox(s, now = s$now)
  wc_use(NULL)
  res <- run_inbox(s, now = s$now + 60)
  expect_true(res$ran)
  calls <- s$hooks$after_run$calls
  expect_length(calls, 1L)
  day <- calls[[1]]$context$day
  expect_false(is.null(day))
  starts <- vapply(day$runs, function(r) r$started_at, "")
  expect_identical(starts, wc_utc(s$now + 60))
  expect_false(any(grepl("writer.check", unlist(day), ignore.case = TRUE)))
})
