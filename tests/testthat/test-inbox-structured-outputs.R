# PLAN-20 phase 1, P20.1: status.json and events.jsonl, written beside the legacy
# .import-status.json and .imports.log (kept for one release). Spec:
# dev/plans/PLAN-20-phase1-spec.md.
#
# ingest_dir() is mocked to a no-op (the namespace binding is mockable, see
# test-inbox.R): these tests are about the files inbox_run() writes, not about
# what an import does.

so_ingest <- function(path, db, ...) list(n_events_committed = 1L, rows_new = 1L)

so_path <- function(s, f) file.path(s$report_dir, f)

# Byte-for-byte equality of two files.
so_same_bytes <- function(a, b) {
  identical(readBin(a, "raw", file.size(a)), readBin(b, "raw", file.size(b)))
}

so_lines <- function(p) {
  l <- readLines(p, warn = FALSE)
  l[nzchar(trimws(l))]
}

# A setup with one settled folder in the inbox.
so_setup <- function(env = parent.frame()) {
  s <- inbox_setup(env)
  s$now <- sydney_midday()
  make_inbox_folder(s$input_dir, "input2026-10-18 0900 a", inbox_proj_a_files(), now = s$now)
  s
}

# A hand-written run-log line for an import of `wo`, started at `when` (POSIXct).
so_log_line <- function(wo, when, errors = character(0), folder = "input2026-10-17 0900 legacy") {
  w <- list(name = wo, kind = "ALS lab", site = "Blaxland", date_start = "2026-10-10",
            date_end = "2026-10-10", samples = 2L, analyses = 7L)
  folders <- list()
  folders[[folder]] <- list(
    events_committed = 1L, rows_new = 7L, rows_already_present = 0L, rows_superseded = 0L,
    review_items_opened = 0L, failed = FALSE, error = NA_character_, files_left = I(character(0)),
    folder_path = file.path(tempdir(), folder), work_orders = list(w),
    files_filed = list(to = NA_character_, files = I(character(0))))
  lg <- list(action = "run", ran = TRUE, locked = FALSE, dry_run = FALSE,
             started_at = format(when, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
             ended_at = format(when + 5, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
             folders_seen = I(folder), folders_settled = I(folder),
             folders_processed = I(folder), folders_arriving = I(character(0)),
             folders = folders, backup_path = NA_character_, errors = I(errors),
             stale_lock = FALSE)
  as.character(jsonlite::toJSON(lg, auto_unbox = TRUE, null = "null", na = "null", digits = NA))
}

# ---- status.json ------------------------------------------------------------------------

test_that("P20.1: a full run writes status.json byte-identical to .import-status.json", {
  s <- so_setup()
  testthat::local_mocked_bindings(ingest_dir = so_ingest)
  res <- run_inbox(s, now = s$now)
  expect_true(res$ran)
  expect_true(file.exists(so_path(s, "status.json")))
  expect_true(file.exists(so_path(s, ".import-status.json")))
  expect_true(so_same_bytes(so_path(s, "status.json"), so_path(s, ".import-status.json")))
  js <- jsonlite::fromJSON(so_path(s, "status.json"), simplifyVector = FALSE)
  expect_true(all(c("updated", "host", "dry_run", "review_items_open", "folders_waiting",
                    "problems", "recent_imports") %in% names(js)))
})

test_that("P20.1: the status-only refresh (action 'status') writes status.json identical to .import-status.json", {
  s <- so_setup()
  testthat::local_mocked_bindings(ingest_dir = so_ingest)
  run_inbox(s, now = s$now)
  unlink(c(so_path(s, "status.json"), so_path(s, ".import-status.json")))
  Sys.setFileTime(s$db, Sys.time() + 120)
  res <- run_inbox(s, now = s$now)
  expect_identical(res$action, "status")
  expect_true(file.exists(so_path(s, "status.json")))
  expect_true(so_same_bytes(so_path(s, "status.json"), so_path(s, ".import-status.json")))
})

test_that("P20.1: a dry run writes status.json identical to .import-status.json, with dry_run true", {
  s <- so_setup()
  testthat::local_mocked_bindings(ingest_dir = so_ingest)
  res <- run_inbox(s, now = s$now, dry_run = TRUE)
  expect_true(res$ran)
  expect_true(file.exists(so_path(s, "status.json")))
  expect_true(so_same_bytes(so_path(s, "status.json"), so_path(s, ".import-status.json")))
  expect_true(jsonlite::fromJSON(so_path(s, "status.json"))$dry_run)
})

test_that("P20.1: import_status() called directly also writes status.json (identical to .import-status.json) and still writes Import status.md", {
  s <- inbox_setup()
  suppressWarnings(suppressMessages(
    import_status(db = s$db, input_dir = s$input_dir, report_dir = s$report_dir,
                  now = sydney_midday())))
  expect_true(file.exists(so_path(s, "Import status.md")))
  expect_true(file.exists(so_path(s, ".import-status.json")))
  expect_true(file.exists(so_path(s, "status.json")))
  expect_true(so_same_bytes(so_path(s, "status.json"), so_path(s, ".import-status.json")))
})

test_that("P20.1: import_status() with `checks` also keeps the two json files byte-identical", {
  s <- fl_status_setup()
  chk <- fl_checks(schedule = fl_schedule(list(site = "K", months = "7;8")))
  fl_status(s, checks = chk)
  expect_true(file.exists(file.path(s$report_dir, "status.json")))
  expect_true(so_same_bytes(file.path(s$report_dir, "status.json"),
                            file.path(s$report_dir, ".import-status.json")))
  expect_gt(length(jsonlite::fromJSON(file.path(s$report_dir, "status.json"),
                                      simplifyVector = FALSE)$flags), 0)
})

test_that("P20.1: import_status() and import_report() called directly run no hooks", {
  s <- inbox_setup()
  now <- sydney_midday()
  clear_hooks()
  withr::defer(clear_hooks())
  fired <- character(0)
  register_hook("after_status", function(x) fired <<- c(fired, "after_status"))
  register_hook("after_run", function(x) fired <<- c(fired, "after_run"))
  register_hook("work_complete", function(x) fired <<- c(fired, "work_complete"))
  suppressWarnings(suppressMessages({
    import_status(db = s$db, input_dir = s$input_dir, report_dir = s$report_dir, now = now)
    import_report(db = s$db, report_dir = s$report_dir, now = now)
  }))
  expect_length(fired, 0)
  # and with hooks registered the direct call still writes the note (it is the renderer)
  expect_true(file.exists(so_path(s, "Import status.md")))
  expect_true(file.exists(inbox_report_path(s$report_dir, now)))
})

test_that("P20.1: import_report() called directly writes the dated note only (not status.json)", {
  s <- inbox_setup()
  now <- sydney_midday()
  suppressWarnings(suppressMessages(import_report(db = s$db, report_dir = s$report_dir, now = now)))
  expect_true(file.exists(inbox_report_path(s$report_dir, now)))
  expect_false(file.exists(so_path(s, "status.json")))
})

# ---- events.jsonl ----------------------------------------------------------------------

test_that("P20.1: a full run appends the same line to events.jsonl and .imports.log; the files are byte-identical", {
  s <- so_setup()
  testthat::local_mocked_bindings(ingest_dir = so_ingest)
  run_inbox(s, now = s$now)
  expect_true(file.exists(so_path(s, "events.jsonl")))
  expect_true(file.exists(so_path(s, ".imports.log")))
  expect_length(so_lines(so_path(s, "events.jsonl")), 1)
  expect_true(so_same_bytes(so_path(s, "events.jsonl"), so_path(s, ".imports.log")))

  # a second full run appends a second line to both
  make_inbox_folder(s$input_dir, "input2026-10-18 1000 b", inbox_proj_a_files(), now = s$now)
  run_inbox(s, now = s$now)
  expect_length(so_lines(so_path(s, "events.jsonl")), 2)
  expect_length(so_lines(so_path(s, ".imports.log")), 2)
  expect_true(so_same_bytes(so_path(s, "events.jsonl"), so_path(s, ".imports.log")))
  # each line is the run's JSON
  last <- jsonlite::fromJSON(utils::tail(so_lines(so_path(s, "events.jsonl")), 1), simplifyVector = FALSE)
  expect_true(last$ran)
  expect_identical(last$action, "run")
})

test_that("P20.1: with a pre-existing .imports.log and no events.jsonl, the run seeds events.jsonl from it, then appends to both", {
  s <- so_setup()
  testthat::local_mocked_bindings(ingest_dir = so_ingest)
  legacy <- so_log_line("ES9000001", s$now - 3 * 86400)
  dir.create(s$report_dir, showWarnings = FALSE, recursive = TRUE)
  writeLines(legacy, so_path(s, ".imports.log"))
  expect_false(file.exists(so_path(s, "events.jsonl")))

  run_inbox(s, now = s$now)
  ev <- so_lines(so_path(s, "events.jsonl"))
  expect_length(ev, 2)
  expect_identical(ev[[1]], legacy)                # the seed, verbatim
  expect_true(so_same_bytes(so_path(s, "events.jsonl"), so_path(s, ".imports.log")))
  expect_length(so_lines(so_path(s, ".imports.log")), 2)
})

test_that("P20.1: an existing events.jsonl is appended to and not re-seeded from .imports.log", {
  s <- so_setup()
  testthat::local_mocked_bindings(ingest_dir = so_ingest)
  dir.create(s$report_dir, showWarnings = FALSE, recursive = TRUE)
  line_a <- so_log_line("ES9000001", s$now - 3 * 86400)
  writeLines(line_a, so_path(s, "events.jsonl"))
  writeLines(so_log_line("ES9000002", s$now - 2 * 86400), so_path(s, ".imports.log"))
  run_inbox(s, now = s$now)
  ev <- so_lines(so_path(s, "events.jsonl"))
  expect_length(ev, 2)
  expect_identical(ev[[1]], line_a)
})

test_that("P20.1: a dry run appends nothing to either log, and creates neither", {
  s <- so_setup()
  testthat::local_mocked_bindings(ingest_dir = so_ingest)
  run_inbox(s, now = s$now, dry_run = TRUE)
  expect_false(file.exists(so_path(s, "events.jsonl")))
  expect_false(file.exists(so_path(s, ".imports.log")))

  # with both logs present, a dry run leaves them byte-for-byte alone
  s2 <- so_setup()
  dir.create(s2$report_dir, showWarnings = FALSE, recursive = TRUE)
  line <- so_log_line("ES9000001", s2$now - 86400)
  writeLines(line, so_path(s2, "events.jsonl"))
  writeLines(line, so_path(s2, ".imports.log"))
  before <- file_md5(c(so_path(s2, "events.jsonl"), so_path(s2, ".imports.log")))
  run_inbox(s2, now = s2$now, dry_run = TRUE)
  expect_identical(file_md5(c(so_path(s2, "events.jsonl"), so_path(s2, ".imports.log"))), before)
})

test_that("P20.1: a status-only refresh appends nothing to either log", {
  s <- so_setup()
  testthat::local_mocked_bindings(ingest_dir = so_ingest)
  run_inbox(s, now = s$now)
  before <- file_md5(c(so_path(s, "events.jsonl"), so_path(s, ".imports.log")))
  Sys.setFileTime(s$db, Sys.time() + 120)
  res <- run_inbox(s, now = s$now)
  expect_identical(res$action, "status")
  expect_identical(file_md5(c(so_path(s, "events.jsonl"), so_path(s, ".imports.log"))), before)
})

# ---- readers ---------------------------------------------------------------------------

test_that("P20.1 readers: the status note reads recent imports from events.jsonl alone (no .imports.log)", {
  s <- inbox_setup()
  now <- sydney_midday()
  dir.create(s$report_dir, showWarnings = FALSE, recursive = TRUE)
  writeLines(so_log_line("ES9000777", now - 3600), so_path(s, "events.jsonl"))
  suppressWarnings(suppressMessages(
    import_status(db = s$db, input_dir = s$input_dir, report_dir = s$report_dir, now = now)))
  recent <- md_section(read_status_note(s$report_dir), "Recent imports")
  expect_true(any(grepl("ES9000777", recent, fixed = TRUE)))
  js <- jsonlite::fromJSON(so_path(s, "status.json"), simplifyVector = FALSE)
  expect_identical(vapply(js$recent_imports, function(r) r$work_order, ""), "ES9000777")
})

test_that("P20.1 readers: when both logs exist the status note reads events.jsonl, not .imports.log", {
  s <- inbox_setup()
  now <- sydney_midday()
  dir.create(s$report_dir, showWarnings = FALSE, recursive = TRUE)
  writeLines(so_log_line("ES9000111", now - 7200), so_path(s, ".imports.log"))
  writeLines(so_log_line("ES9000222", now - 3600), so_path(s, "events.jsonl"))
  suppressWarnings(suppressMessages(
    import_status(db = s$db, input_dir = s$input_dir, report_dir = s$report_dir, now = now)))
  recent <- md_section(read_status_note(s$report_dir), "Recent imports")
  expect_true(any(grepl("ES9000222", recent, fixed = TRUE)))
  expect_false(any(grepl("ES9000111", recent, fixed = TRUE)))
})

test_that("P20.1 readers: the status note's Problems come from events.jsonl's last line when it exists", {
  s <- inbox_setup()
  now <- sydney_midday()
  dir.create(s$report_dir, showWarnings = FALSE, recursive = TRUE)
  writeLines(so_log_line("ES9000111", now - 7200, errors = "problem from the legacy log"),
             so_path(s, ".imports.log"))
  writeLines(so_log_line("ES9000222", now - 3600, errors = "problem from the events log"),
             so_path(s, "events.jsonl"))
  suppressWarnings(suppressMessages(
    import_status(db = s$db, input_dir = s$input_dir, report_dir = s$report_dir, now = now)))
  prob <- md_section(read_status_note(s$report_dir), "Problems")
  expect_true(any(grepl("problem from the events log", prob, fixed = TRUE)))
  expect_false(any(grepl("problem from the legacy log", prob, fixed = TRUE)))
})

test_that("P20.1 readers: the daily report reads events.jsonl when it exists", {
  s <- inbox_setup()
  now <- sydney_midday()
  dir.create(s$report_dir, showWarnings = FALSE, recursive = TRUE)
  writeLines(so_log_line("ES9000111", now - 7200), so_path(s, ".imports.log"))
  writeLines(so_log_line("ES9000222", now - 3600), so_path(s, "events.jsonl"))
  suppressWarnings(suppressMessages(import_report(db = s$db, report_dir = s$report_dir, now = now)))
  day <- md_section(read_report(s$report_dir, now), "Imported today")
  expect_true(any(grepl("ES9000222", day, fixed = TRUE)))
  expect_false(any(grepl("ES9000111", day, fixed = TRUE)))
})

test_that("P20.1 readers: with only the legacy .imports.log, both notes still read it", {
  s <- inbox_setup()
  now <- sydney_midday()
  dir.create(s$report_dir, showWarnings = FALSE, recursive = TRUE)
  writeLines(so_log_line("ES9000333", now - 3600), so_path(s, ".imports.log"))
  suppressWarnings(suppressMessages({
    import_status(db = s$db, input_dir = s$input_dir, report_dir = s$report_dir, now = now)
    import_report(db = s$db, report_dir = s$report_dir, now = now)
  }))
  expect_true(any(grepl("ES9000333", md_section(read_status_note(s$report_dir), "Recent imports"), fixed = TRUE)))
  expect_true(any(grepl("ES9000333", md_section(read_report(s$report_dir, now), "Imported today"), fixed = TRUE)))
})

test_that("P20.1 readers: after a full run the status note and the daily report agree with events.jsonl", {
  s <- so_setup()
  testthat::local_mocked_bindings(ingest_dir = function(path, db, ...) stop("simulated folder failure"))
  res <- run_inbox(s, now = s$now)
  expect_true(res$ran)
  expect_true(file.exists(so_path(s, "events.jsonl")))
  expect_true(any(grepl("simulated folder failure",
                        md_section(read_status_note(s$report_dir), "Problems"), fixed = TRUE)))
  expect_true(any(grepl("simulated folder failure",
                        md_section(read_report(s$report_dir, s$now), "Problems"), fixed = TRUE)))
})

# ---- flags first_seen carry-over --------------------------------------------------------

so_edit_first_seen <- function(path, value) {
  js <- jsonlite::fromJSON(path, simplifyVector = FALSE)
  for (i in seq_along(js$flags)) js$flags[[i]]$first_seen <- value
  jsonlite::write_json(js, path, auto_unbox = TRUE, pretty = TRUE, na = "null", digits = NA)
  invisible(length(js$flags))
}

test_that("P20.1 readers: the flags first_seen carry-over reads status.json when it exists", {
  s <- fl_status_setup()
  chk <- fl_checks(schedule = fl_schedule(list(site = "K", months = "7;8")))
  t1 <- fl_now()
  fl_status(s, checks = chk, now = t1)
  n <- so_edit_first_seen(file.path(s$report_dir, "status.json"), "2020-01-01T00:00:00Z")
  expect_gt(n, 0)
  # .import-status.json still holds the t1 first_seen values: only status.json is read
  fl_status(s, checks = chk, now = t1 + 2 * 3600)
  js <- jsonlite::fromJSON(file.path(s$report_dir, "status.json"), simplifyVector = FALSE)
  expect_identical(length(js$flags), n)
  for (fl in js$flags) expect_identical(fl$first_seen, "2020-01-01T00:00:00Z")
  expect_true(so_same_bytes(file.path(s$report_dir, "status.json"),
                            file.path(s$report_dir, ".import-status.json")))
})

test_that("P20.1 readers: with no status.json the flags first_seen carry-over falls back to .import-status.json", {
  s <- fl_status_setup()
  chk <- fl_checks(schedule = fl_schedule(list(site = "K", months = "7;8")))
  t1 <- fl_now()
  fl_status(s, checks = chk, now = t1)
  n <- so_edit_first_seen(file.path(s$report_dir, ".import-status.json"), "2019-06-01T00:00:00Z")
  expect_gt(n, 0)
  unlink(file.path(s$report_dir, "status.json"))
  fl_status(s, checks = chk, now = t1 + 2 * 3600)
  js <- jsonlite::fromJSON(file.path(s$report_dir, "status.json"), simplifyVector = FALSE)
  expect_identical(length(js$flags), n)
  for (fl in js$flags) expect_identical(fl$first_seen, "2019-06-01T00:00:00Z")
})
