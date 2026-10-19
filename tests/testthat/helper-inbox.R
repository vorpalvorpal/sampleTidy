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
#                 DB stat fields (names not pinned) (SPEC section 0)
#   * status:     <report_dir>/Import status.md and .import-status.json (2a)
#   * run log:    <report_dir>/.imports.log, one JSON object per line
#   * report:     <report_dir>/<YYYY-MM-DD>-imports.md (Sydney date of `now`)

inbox_fixture <- function(...) testthat::test_path("fixtures", ...)

# The esdat triple for work order XX1234567 (commits cleanly against seed_db).
inbox_proj_a_files <- function() {
  list.files(inbox_fixture("esdat"), pattern = "XX1234567", full.names = TRUE)
}
# The ES2617126 esdat triple (its sampling points are unknown to seed_db, so it
# commits under dangling aliases -> no site -> "other").
inbox_rain_files <- function() {
  list.files(inbox_fixture("esdat"), pattern = "ES2617126", full.names = TRUE)
}
inbox_corrupt_file <- function() {
  inbox_fixture("esdat", "CORRUPT.ESDAT_XX0000000_0.Chemistry2e.CSV")
}

#' A seeded DB, archive/snapshot dirs, an empty inbox, backup and report dirs.
#' Seeded features with site 'T' are re-sited to 'B' (Blaxland) so that the
#' XX1234567 fixture's samples land on Blaxland features.
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

sydney_date <- function(now) format(now, "%Y-%m-%d", tz = "Australia/Sydney")
sydney_hhmm <- function(now) format(now, "%H:%M", tz = "Australia/Sydney")

inbox_report_path <- function(report_dir, now) {
  file.path(report_dir, paste0(sydney_date(now), "-imports.md"))
}

#' Ruling R8 (2026-10-19): both notes start with a YAML frontmatter block
#' (`---` / `summary:` / `  - '...'` / `---`). Returns the frontmatter lines
#' (without the fences), or NULL when the note has none.
note_frontmatter <- function(lines) {
  if (length(lines) < 2 || !identical(lines[[1]], "---")) return(NULL)
  end <- which(lines == "---")
  end <- end[end > 1]
  if (length(end) == 0) return(NULL)
  if (end[[1]] == 2) character(0) else lines[2:(end[[1]] - 1)]
}

#' The note body after its frontmatter (unchanged when there is none), so the
#' header-line assertions keep reading the header.
strip_frontmatter <- function(lines) {
  fm <- note_frontmatter(lines)
  if (is.null(fm)) return(lines)
  n <- length(fm) + 2L
  if (n >= length(lines)) character(0) else lines[(n + 1L):length(lines)]
}

read_report <- function(report_dir, now) {
  strip_frontmatter(readLines(inbox_report_path(report_dir, now), warn = FALSE,
                              encoding = "UTF-8"))
}

#' Lines of the markdown section whose heading matches `title` (a `#` heading),
#' up to the next heading of the same or a higher level. character(0) if the
#' section is absent.
md_section <- function(lines, title) {
  is_h <- grepl("^#+\\s", lines)
  start <- which(is_h & grepl(paste0("^#+\\s*", title), lines, ignore.case = TRUE))
  if (length(start) == 0) return(character(0))
  start <- start[[1]]
  level <- nchar(sub("^(#+).*", "\\1", lines[[start]]))
  later <- which(is_h & seq_along(lines) > start)
  later <- later[nchar(sub("^(#+).*", "\\1", lines[later])) <= level]
  end <- if (length(later)) later[[1]] - 1L else length(lines)
  if (end <= start) return(character(0))
  lines[(start + 1L):end]
}

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

#' inbox_run() against a setup from inbox_setup(), messages/warnings muffled.
run_inbox <- function(s, now = Sys.time(), ...) {
  quiet_run(inbox_run(input_dir = s$input_dir, db = s$db,
                      backup_dir = s$backup_dir, report_dir = s$report_dir,
                      now = now, ...))
}

status_note_path <- function(report_dir) file.path(report_dir, "Import status.md")
read_status_note <- function(report_dir) {
  strip_frontmatter(readLines(status_note_path(report_dir), warn = FALSE, encoding = "UTF-8"))
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
