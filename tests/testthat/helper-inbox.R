# Helpers for test-inbox.R (auto-import: inbox_signature(), inbox_check(),
# inbox_run(), import_report() - scratchpad/2026-10-18-autoimport/SPEC.md).
# Only DEFINES functions - no top-level calls.
#
# Pinned file-format seams the implementation must honour (they are what the
# tests write by hand to simulate prior state):
#   * lock file:  paste0(db, ".inbox.lock"), JSON {"pid": <int>, "started_at":
#                 "<ISO-8601 UTC, e.g. 2026-10-18T01:00:00Z>"}
#   * state file: <report_dir>/.imports.state, JSON with at least
#                 "signature" (string), "pending" (bool), "checked_at", plus the
#                 DB stat fields (names not pinned) (SPEC section 0).
#                 "checked_at" is ISO-8601 UTC of the `now` of the run (or
#                 status refresh) that wrote the state; inbox_check() compares
#                 its Sydney day with now's (ruling 2026-10-19 R14).
#   * status:     <report_dir>/status.json and the identical .import-status.json
#                 (the core writes no markdown: renderers are deployment hooks)
#   * run log:    <report_dir>/.imports.log, one JSON object per line

inbox_fixture <- function(...) testthat::test_path("fixtures", ...)

# The esdat triple for work order XX1234567 (commits cleanly against seed_db).
inbox_proj_a_files <- function() {
  list.files(inbox_fixture("esdat"), pattern = "XX1234567", full.names = TRUE)
}
# The ES2664217 esdat triple (its sampling points are unknown to seed_db, so it
# commits under dangling aliases -> no site -> "other").
inbox_rain_files <- function() {
  list.files(inbox_fixture("esdat"), pattern = "ES2664217", full.names = TRUE)
}
inbox_corrupt_file <- function() {
  inbox_fixture("esdat", "CORRUPT.ESDAT_XX0000000_0.Chemistry2e.CSV")
}

#' The inbox recogniser the older suites were written against: folders named
#' `batch-<something>`, 10 minutes to settle, leftovers filed under `filed-mail`.
#' The setup file no longer pins it globally: inbox_setup() sets it for the
#' calling test, and a test of the generic defaults clears it again (bt_setup()).
test_batches <- function() {
  inbox_batches("^batch-.+", settle_minutes = 10, leftovers = "filed-mail")
}

#' Set the option to test_batches() for the rest of the calling test.
local_test_batches <- function(env = parent.frame()) {
  withr::local_options(list(sampletidy.inbox_batches = test_batches()), .local_envir = env)
  invisible(NULL)
}

#' A seeded DB, archive/snapshot dirs, an empty inbox, backup and report dirs.
#' Seeded features with site 'T' are re-sited to 'B' (Northvale) so that the
#' XX1234567 fixture's samples land on Northvale features.
inbox_setup <- function(env = parent.frame()) {
  db_dir <- withr::local_tempdir(.local_envir = env)
  db_path <- seed_db(dir = db_dir)
  con <- seed_con(db_path)
  ensure_test_asset_table(con)
  DBI::dbExecute(con, "UPDATE feature SET site = 'B' WHERE site = 'T'")
  DBI::dbExecute(con, "UPDATE feature SET site = 'K' WHERE site = 'TH'")
  DBI::dbDisconnect(con, shutdown = TRUE)

  archive_dir <- withr::local_tempdir(.local_envir = env)
  snapshot_dir <- withr::local_tempdir(.local_envir = env)
  input_dir <- withr::local_tempdir(.local_envir = env)
  backup_dir <- withr::local_tempdir(.local_envir = env)
  report_dir <- withr::local_tempdir(.local_envir = env)
  withr::local_options(list(
    "sampletidy.archive_dir" = archive_dir,
    "sampletidy.snapshot_dir" = snapshot_dir,
    "sampletidy.remove_ingested" = TRUE,
    "sampletidy.live_db" = db_path,
    "sampletidy.input_dir" = input_dir
  ), .local_envir = env)
  local_test_batches(env)
  list(db = db_path, archive_dir = archive_dir, snapshot_dir = snapshot_dir,
       input_dir = input_dir, backup_dir = backup_dir, report_dir = report_dir)
}

#' Create `input_dir/<name>/` holding copies of `files`, every file's mtime set
#' to `now - age_min` minutes. The folder's own mtime is left at "just now".
make_inbox_folder <- function(input_dir, name, files, age_min = 60,
                              now = Sys.time()) {
  d <- file.path(input_dir, name)
  dir.create(d, recursive = TRUE, showWarnings = FALSE)
  for (f in files) {
    dest <- file.path(d, basename(f))
    stopifnot(file.copy(f, dest, overwrite = TRUE))
    Sys.setFileTime(dest, now - age_min * 60)
  }
  d
}

file_md5 <- function(path) unname(tools::md5sum(path))

inbox_lock_path <- function(db) paste0(db, ".inbox.lock")

write_inbox_lock <- function(db, pid, started_at) {
  jsonlite::write_json(
    list(pid = as.integer(pid),
         started_at = format(started_at, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")),
    inbox_lock_path(db), auto_unbox = TRUE
  )
  inbox_lock_path(db)
}

#' The PID of a live child process (killed when the calling test ends).
live_child_pid <- function(env = parent.frame()) {
  p <- processx::process$new("sleep", "120")
  withr::defer(p$kill(), envir = env)
  p$get_pid()
}

# Above macOS/Linux pid_max: no such process can exist.
dead_pid <- function() 99999999L

#' Today's 12:00 in Sydney as a POSIXct: a `now` far from the Sydney day boundary,
#' for tests that compare two checks a little apart (ruling 2026-10-19 R14 makes a
#' new Sydney day a "status" reason, so a Sys.time() base could straddle midnight).
sydney_midday <- function() {
  as.POSIXct(paste(format(Sys.time(), "%Y-%m-%d", tz = "Australia/Sydney"), "12:00:00"),
             tz = "Australia/Sydney")
}

sydney_date <- function(now) format(now, "%Y-%m-%d", tz = "Australia/Sydney")
sydney_hhmm <- function(now) format(now, "%H:%M", tz = "Australia/Sydney")

read_inbox_log <- function(report_dir) {
  p <- file.path(report_dir, ".imports.log")
  if (!file.exists(p)) return(list())
  l <- readLines(p, warn = FALSE)
  l <- l[nzchar(trimws(l))]
  lapply(l, jsonlite::fromJSON, simplifyVector = FALSE)
}

read_inbox_state <- function(report_dir) {
  jsonlite::fromJSON(file.path(report_dir, ".imports.state"), simplifyVector = TRUE)
}

#' Rewrite fields of an existing state file (written by a real run), keeping
#' every field the tests do not name - so the DB-stat fields, whose names the
#' spec does not pin, survive.
mutate_inbox_state <- function(report_dir, ...) {
  p <- file.path(report_dir, ".imports.state")
  st <- jsonlite::fromJSON(p, simplifyVector = FALSE)
  changes <- list(...)
  for (k in names(changes)) st[[k]] <- changes[[k]]
  jsonlite::write_json(st, p, auto_unbox = TRUE, digits = NA)
  invisible(st)
}

#' The parsed status.json written by the last run or status refresh (nested
#' lists, so arrays stay lists and JSON null reads as NULL).
read_status_json <- function(report_dir) {
  jsonlite::read_json(file.path(report_dir, "status.json"), simplifyVector = FALSE)
}

#' The `waiting` entry for folder `name` in status.json, or NULL.
status_waiting <- function(report_dir, name) {
  w <- read_status_json(report_dir)$waiting
  for (e in w) if (identical(e$folder, name)) return(e)
  NULL
}

#' Markdown files in a report dir (the core writes none).
report_md_files <- function(report_dir) {
  list.files(report_dir, pattern = "\\.md$", all.files = TRUE)
}

#' Register a recording hook for `event`; returns an environment whose `calls`
#' lists `list(arg, context, nargs)` per call. `renderer = TRUE` tags it. The
#' hook is two-argument, so it receives the context. Cleared when the calling
#' test ends.
record_hook <- function(event, renderer = FALSE, env = parent.frame()) {
  rec <- new.env()
  rec$calls <- list()
  fn <- function(arg, context) {
    rec$calls[[length(rec$calls) + 1L]] <- list(arg = arg, context = context)
    invisible(NULL)
  }
  if (renderer) register_hook(event, fn, renderer = TRUE) else register_hook(event, fn)
  withr::defer(clear_hooks(), envir = env)
  rec
}

# ---- stage 2 helpers: the generic inbox (test-inbox-batches.R and friends) ---------
# inbox_setup() sets test_batches() (batch-*, 10 minutes, filed-mail) for the
# older suites. The stage 2 tests clear it, so they run on the package defaults
# (every non-hidden subfolder, settled at once, leftovers left in place) unless
# they pass `batch` themselves. Synthetic folders: batch-1, batch-2, misc.

#' inbox_setup() with the batch option cleared (for the rest of the calling test).
bt_setup <- function(env = parent.frame()) {
  s <- inbox_setup(env)
  withr::local_options(list(sampletidy.inbox_batches = NULL), .local_envir = env)
  s
}

#' A folder of the XX1234567 esdat triple (plus `extra` bytes-files by name),
#' every file's mtime `age_sec` seconds before `now`.
bt_folder <- function(s, name, now, age_sec = 3600, files = inbox_proj_a_files(),
                      extra = character(0)) {
  d <- file.path(s$input_dir, name)
  dir.create(d, recursive = TRUE, showWarnings = FALSE)
  for (f in files) stopifnot(file.copy(f, file.path(d, basename(f)), overwrite = TRUE))
  for (nm in extra) {
    writeBin(c(as.raw(c(0xff, 0xd8, 0xff, 0xe0)), charToRaw(paste0("body-", nm))), file.path(d, nm))
  }
  fs <- list.files(d, full.names = TRUE)
  if (length(fs)) Sys.setFileTime(fs, now - age_sec)
  d
}

#' A whole-second `now` (no sub-second mtime comparisons).
bt_now <- function() as.POSIXct(floor(as.numeric(Sys.time())), origin = "1970-01-01", tz = "UTC")

#' Stand-in for ingest_dir(): commits one work order at site `site` (or, for
#' NULL, leaves the seeded site alone), with one sample dated 2026-10-10.
bt_ingest <- function(wo = "ES9990001", site = "N") {
  force(wo)
  force(site)
  function(path, ..., db) {
    con <- seed_con(db)
    on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
    if (!is.null(site)) {
      DBI::dbExecute(con, sprintf(
        "UPDATE feature SET site = '%s'
          WHERE uuid IN (SELECT uuid_feature FROM feature_alias WHERE uuid = 'fa-0001')", site))
    }
    DBI::dbExecute(con, "INSERT INTO project (uuid, name, type) VALUES (?, ?, 'Work order')",
                   params = list(paste0("p-", wo), wo))
    DBI::dbExecute(con, "INSERT INTO \"sample\" (uuid, uuid_feature_alias, uuid_project, datetime, organisation)
                         VALUES (?, 'fa-0001', ?, TIMESTAMP '2026-10-10 01:00:00', 'ACIRL')",
                   params = list(paste0("s-", wo), paste0("p-", wo)))
    DBI::dbExecute(con, "INSERT INTO analysis (uuid, uuid_sample, uuid_lab, value, quantified)
                         VALUES (?, ?, 'lm-0001', 7, TRUE)",
                   params = list(paste0("a-", wo), paste0("s-", wo)))
    list(n_events_committed = 1L, rows_new = 1L, rows_already_present = 0L,
         rows_superseded = 0L, review_items_opened = 0L)
  }
}

#' One synthetic run-log line (the JSON `inbox_run()` appends to events.jsonl),
#' started at `when`, importing one work order at `site`.
inbox_log_line <- function(when, wo = "ES9990001", site = "N", dry_run = FALSE,
                           folder = "batch-0", filed = NULL, errors = character(0)) {
  w <- list(name = wo, kind = "unknown", site = site, date_start = "2026-10-10",
            date_end = "2026-10-10", samples = 1L, analyses = 3L)
  entry <- list(
    events_committed = 1L, rows_new = 3L, rows_already_present = 0L, rows_superseded = 0L,
    review_items_opened = 0L, failed = FALSE, error = NA_character_, files_left = I(character(0)),
    folder_path = file.path("/fixture/inbox", folder), work_orders = if (is.null(wo)) list() else list(w),
    files_filed = if (is.null(filed)) list(to = NA_character_, files = I(character(0))) else
      list(to = filed$to, files = I(filed$files)))
  folders <- list()
  folders[[folder]] <- entry
  lg <- list(action = "run", ran = TRUE, locked = FALSE, dry_run = dry_run,
             started_at = format(when, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
             ended_at = format(when + 5, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
             folders_seen = I(folder), folders_settled = I(folder),
             folders_processed = I(folder), folders_arriving = I(character(0)),
             folders = folders, backup_path = NA_character_, errors = I(errors),
             stale_lock = FALSE)
  as.character(jsonlite::toJSON(lg, auto_unbox = TRUE, null = "null", na = "null", digits = NA))
}

#' Write `lines` as the report dir's events.jsonl (created if needed).
write_events <- function(report_dir, lines) {
  dir.create(report_dir, showWarnings = FALSE, recursive = TRUE)
  writeLines(lines, file.path(report_dir, "events.jsonl"))
  invisible(file.path(report_dir, "events.jsonl"))
}

#' inbox_run() against a setup from inbox_setup(), messages/warnings muffled.
run_inbox <- function(s, now = Sys.time(), ...) {
  quiet_run(inbox_run(input_dir = s$input_dir, db = s$db,
                      backup_dir = s$backup_dir, report_dir = s$report_dir,
                      now = now, ...))
}

#' Snapshot of a directory tree: relative path -> "size|mtime|md5", used to
#' prove a call wrote nothing.
tree_snapshot <- function(dir) {
  f <- list.files(dir, recursive = TRUE, all.files = TRUE, full.names = TRUE,
                  include.dirs = TRUE, no.. = TRUE)
  info <- file.info(f)
  md5 <- ifelse(info$isdir, "", tools::md5sum(f))
  stats::setNames(
    paste(info$size, format(as.numeric(info$mtime), nsmall = 3), md5, sep = "|"),
    sub(paste0("^", normalizePath(dir), "/?"), "", normalizePath(f))
  )
}

#' Move every file under `dir` `secs` into the past, so that a later rewrite
#' shows in `tree_snapshot()`'s mtime even on a whole-second filesystem. Used
#' in place of `Sys.sleep()` (PLAN-22 B6). Only for directories whose mtimes
#' the code under test does not read (the report dir, not the input dir or DB).
backdate_tree <- function(dir, secs = 60) {
  f <- list.files(dir, recursive = TRUE, all.files = TRUE, full.names = TRUE, no.. = TRUE)
  if (length(f) > 0) Sys.setFileTime(f, Sys.time() - secs)
  invisible(f)
}

quiet_run <- function(expr) suppressWarnings(suppressMessages(expr))

ingest_file_rows <- function(db) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbGetQuery(con, "SELECT hash, filename, state FROM ingest_file")
}

insert_review_items <- function(db, rows) {
  con <- seed_con(db)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  for (i in seq_len(nrow(rows))) {
    DBI::dbExecute(con,
      "INSERT INTO review_queue (uuid, created_at, kind, subkind, work_order, status)
       VALUES (?, ?, ?, ?, ?, ?)",
      params = list(rows$uuid[[i]], rows$created_at[[i]], rows$kind[[i]],
                    rows$subkind[[i]], rows$work_order[[i]], rows$status[[i]]))
  }
  invisible(NULL)
}

# PLAN-22 A3: import_status() runs the hourly db_checks(); seed_db() violates
# some of their invariants and lacks some of their tables. Tests that assert
# on import Problems (not DB invariants) mock db_checks() to an all-pass result.
local_db_checks_pass <- function(env = parent.frame()) {
  testthat::local_mocked_bindings(
    db_checks = function(con, tier = "hourly", ...) {
      core <- db_checks_core()
      core <- core[core$tier == "hourly", , drop = FALSE]
      out <- data.frame(name = core$name, tier = core$tier, severity = core$severity,
                        status = "pass", n = 0L, ms = 0, stringsAsFactors = FALSE)
      out$sample <- rep(list(data.frame(key = character())), nrow(out))
      out$message <- NA_character_
      out$keys <- rep(list(character()), nrow(out))
      out
    },
    .package = "sampleTidy", .env = env
  )
}
