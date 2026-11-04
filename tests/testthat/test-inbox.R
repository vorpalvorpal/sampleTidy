# Auto-import: inbox_signature(), inbox_check(), inbox_run(), import_report(),
# import_status() - scratchpad/2026-10-18-autoimport/SPEC.md sections 0, 1, 2,
# 2a. Every test runs on temp dirs and a seed_db(); nothing touches the live DB,
# OneDrive or the vault.
#
# Seams the implementation must provide (beyond the spec's signatures):
#   * inbox_check(input_dir, report_dir, now = Sys.time(), db = st_config("live_db"))
#     -> "none" | "status" | "run". `db` is needed to stat the DB file.
#   * import_report(db, report_dir, now = Sys.time()) -> path (invisibly).
#     Reads today's Problems from <report_dir>/.imports.log.
#   * import_status(db, input_dir, report_dir, now = Sys.time(), settle_minutes = 10)
#   * .inbox_backup_copy(from, to): the internal function inbox_run() uses to
#     copy the DB to the backup path; verification (SHA-256) happens AFTER it,
#     so a mocked copy that writes different bytes must make verification fail.
#   * inbox_run() calls ingest_dir() through the namespace binding (mockable).
#   * file formats pinned in helper-inbox.R (lock, state, log, note paths).
#
# Return value of inbox_run() (and keys of each .imports.log line):
#   action ("none"/"status"/"run"), ran (TRUE only for "run"), locked,
#   started_at, ended_at, dry_run, folders_seen, folders_settled,
#   folders_processed (processing order), folders_arriving, folders (named by
#   folder basename: events_committed, rows_new, rows_already_present,
#   rows_superseded, review_items_opened, failed, error, files_left),
#   backup_path (NA when none), errors (character), stale_lock (logical).

# ---- section 0: inbox_signature() ------------------------------------------

test_that("inbox_signature() is a stable string over an unchanged tree", {
  d <- withr::local_tempdir()
  make_inbox_folder(d, "batch-2026-10-18 0900 a", inbox_proj_a_files())
  s1 <- inbox_signature(d)
  s2 <- inbox_signature(d)
  expect_type(s1, "character")
  expect_length(s1, 1)
  expect_identical(s1, s2)
})

test_that("inbox_signature() is built from metadata only, never file contents", {
  d <- withr::local_tempdir()
  f <- st_test_write_file(d, "batch-2026-10-18 0900 a/report.csv", raw = charToRaw("AAAAAAAAAA"))
  t0 <- as.POSIXct("2026-10-01 00:00:00", tz = "UTC")
  Sys.setFileTime(f, t0)
  s1 <- inbox_signature(d)
  # same size, different bytes, mtime restored: a stat-only signature cannot see it
  writeBin(charToRaw("BBBBBBBBBB"), f)
  Sys.setFileTime(f, t0)
  expect_identical(inbox_signature(d), s1)
})

test_that("inbox_signature() changes with mtime, size, add, remove, rename, new folder", {
  d <- withr::local_tempdir()
  f <- st_test_write_file(d, "batch-2026-10-18 0900 a/report.csv", raw = charToRaw("AAAAAAAAAA"))
  t0 <- as.POSIXct("2026-10-01 00:00:00", tz = "UTC")
  Sys.setFileTime(f, t0)
  base <- inbox_signature(d)

  Sys.setFileTime(f, t0 + 60)
  expect_false(identical(inbox_signature(d), base), info = "mtime")
  writeBin(charToRaw("AAAAAAAAAAA"), f)
  Sys.setFileTime(f, t0)
  expect_false(identical(inbox_signature(d), base), info = "size")
  writeBin(charToRaw("AAAAAAAAAA"), f)
  Sys.setFileTime(f, t0)
  base <- inbox_signature(d)

  g <- st_test_write_file(d, "batch-2026-10-18 0900 a/coa.pdf", "x")
  s_add <- inbox_signature(d)
  expect_false(identical(s_add, base), info = "file added inside a folder")
  file.rename(g, file.path(dirname(g), "coa2.pdf"))
  expect_false(identical(inbox_signature(d), s_add), info = "file renamed")
  s_ren <- inbox_signature(d)
  file.remove(file.path(dirname(g), "coa2.pdf"))
  expect_false(identical(inbox_signature(d), s_ren), info = "file removed")

  s_before_dir <- inbox_signature(d)
  dir.create(file.path(d, "batch-2026-10-18 1000 b"))
  expect_false(identical(inbox_signature(d), s_before_dir), info = "folder added")
  s_before_loose <- inbox_signature(d)
  st_test_write_file(d, "loose.csv", "x")
  expect_false(identical(inbox_signature(d), s_before_loose), info = "loose file added")
})

# ---- section 0: inbox_check() ------------------------------------------------

test_that("inbox_check(): no state file -> 'run', and the check writes nothing", {
  s <- inbox_setup()
  make_inbox_folder(s$input_dir, "batch-2026-10-18 0900 a", inbox_proj_a_files())
  before_r <- tree_snapshot(s$report_dir)
  before_i <- tree_snapshot(s$input_dir)
  expect_identical(inbox_check(s$input_dir, s$report_dir, now = Sys.time(), db = s$db), "run")
  expect_identical(tree_snapshot(s$report_dir), before_r)
  expect_identical(tree_snapshot(s$input_dir), before_i)
})

test_that("inbox_check(): unchanged inbox and DB -> 'none', writing nothing (not even checked_at)", {
  s <- inbox_setup()
  run_inbox(s)                     # baseline: writes the state file
  expect_true(file.exists(file.path(s$report_dir, ".imports.state")))
  # Instead of sleeping: backdate what is already there, so any rewrite would
  # show a new mtime, and tell the check the clock has moved on, so a
  # rewritten checked_at would show in the content too.
  backdate_tree(s$report_dir)
  before <- tree_snapshot(s$report_dir)
  expect_identical(inbox_check(s$input_dir, s$report_dir, now = Sys.time() + 2, db = s$db), "none")
  expect_identical(tree_snapshot(s$report_dir), before)
})

test_that("inbox_check(): a changed signature -> 'run'; pending = TRUE -> 'run'", {
  s <- inbox_setup()
  run_inbox(s)
  expect_identical(inbox_check(s$input_dir, s$report_dir, db = s$db), "none")

  mutate_inbox_state(s$report_dir, signature = "not-the-current-signature")
  expect_identical(inbox_check(s$input_dir, s$report_dir, db = s$db), "run")

  mutate_inbox_state(s$report_dir, signature = inbox_signature(s$input_dir), pending = TRUE)
  expect_identical(inbox_check(s$input_dir, s$report_dir, db = s$db), "run")

  mutate_inbox_state(s$report_dir, pending = FALSE)
  expect_identical(inbox_check(s$input_dir, s$report_dir, db = s$db), "none")
})

test_that("inbox_check(): only the DB file's stat changed -> 'status'", {
  s <- inbox_setup()
  run_inbox(s)
  expect_identical(inbox_check(s$input_dir, s$report_dir, db = s$db), "none")
  before <- tree_snapshot(s$report_dir)
  Sys.setFileTime(s$db, Sys.time() + 120)   # stat changes, contents do not
  expect_identical(inbox_check(s$input_dir, s$report_dir, db = s$db), "status")
  expect_identical(tree_snapshot(s$report_dir), before)
})

# ---- ruling 2026-10-19 R14: a new Sydney day is a "status" reason ----------------

# A state written by a real run at `t0`, then checked at `t`.
r14_check <- function(s, t) inbox_check(s$input_dir, s$report_dir, now = t, db = s$db)

test_that("inbox_check() (R14): same Sydney day -> 'none'; the next Sydney day -> 'status'; writes nothing", {
  s <- inbox_setup()
  t0 <- as.POSIXct("2026-10-19 01:00:00", tz = "UTC")        # 12:00 AEDT, 19 Oct
  run_inbox(s, now = t0)
  expect_identical(read_inbox_state(s$report_dir)$checked_at, "2026-10-19T01:00:00Z")
  before <- tree_snapshot(s$report_dir)
  # AEDT = UTC+11: Sydney midnight 19->20 Oct is 2026-10-19 13:00 UTC
  expect_identical(r14_check(s, as.POSIXct("2026-10-19 12:30:00", tz = "UTC")), "none")    # 23:30 on the 19th
  expect_identical(r14_check(s, as.POSIXct("2026-10-19 13:30:00", tz = "UTC")), "status")  # 00:30 on the 20th
  expect_identical(tree_snapshot(s$report_dir), before)
})

test_that("inbox_check() (R14): the day boundary is Sydney's, not UTC's", {
  s <- inbox_setup()
  run_inbox(s, now = as.POSIXct("2026-10-19 13:30:00", tz = "UTC"))  # 00:30 AEDT, 20 Oct
  # 2026-10-20 01:00 UTC: a different UTC day, the same Sydney day (12:00, 20 Oct)
  expect_identical(r14_check(s, as.POSIXct("2026-10-20 01:00:00", tz = "UTC")), "none")
  # 2026-10-20 12:59 UTC is still the 20th in Sydney; 13:00 UTC is the 21st
  expect_identical(r14_check(s, as.POSIXct("2026-10-20 12:59:00", tz = "UTC")), "none")
  expect_identical(r14_check(s, as.POSIXct("2026-10-20 13:00:00", tz = "UTC")), "status")
})

test_that("inbox_check() (R14): a state without a usable checked_at -> 'status'; 'run' reasons still win", {
  s <- inbox_setup()
  t0 <- as.POSIXct("2026-10-19 01:00:00", tz = "UTC")
  run_inbox(s, now = t0)
  mutate_inbox_state(s$report_dir, checked_at = "not a time")
  expect_identical(r14_check(s, t0 + 60), "status")
  mutate_inbox_state(s$report_dir, checked_at = NULL)
  expect_identical(r14_check(s, t0 + 60), "status")
  # a new day AND a changed signature (or pending) -> "run"
  mutate_inbox_state(s$report_dir, checked_at = "2026-10-19T01:00:00Z",
                     signature = "not-the-current-signature")
  expect_identical(r14_check(s, t0 + 86400), "run")
  mutate_inbox_state(s$report_dir, signature = inbox_signature(s$input_dir), pending = TRUE)
  expect_identical(r14_check(s, t0 + 86400), "run")
})

test_that("inbox_run() (R14): a new-day 'status' rewrites status.json read-only and records the new day", {
  s <- inbox_setup()
  t0 <- as.POSIXct("2026-10-19 01:00:00", tz = "UTC")
  run_inbox(s, now = t0)
  backups <- list.files(s$backup_dir)
  db_md5 <- file_md5(s$db)
  unlink(file.path(s$report_dir, c("status.json", ".import-status.json")))
  t1 <- as.POSIXct("2026-10-20 01:00:00", tz = "UTC")
  r <- run_inbox(s, now = t1)
  expect_identical(r$action, "status")
  expect_false(r$ran)
  expect_identical(read_status_json(s$report_dir)$updated, "2026-10-20 12:00")
  expect_identical(read_status_json(s$report_dir)$timezone, "Australia/Sydney")
  expect_length(report_md_files(s$report_dir), 0)
  expect_identical(file_md5(s$db), db_md5)
  expect_identical(list.files(s$backup_dir), backups)
  expect_identical(read_inbox_state(s$report_dir)$checked_at, "2026-10-20T01:00:00Z")
  expect_identical(r14_check(s, t1 + 3600), "none")
})

# ---- section 1: inbox_run() ----------------------------------------------------

test_that("inbox_run(): a 'none' check does nothing at all (ran = FALSE)", {
  s <- inbox_setup()
  make_inbox_folder(s$input_dir, "batch-2026-10-18 0900 a", inbox_proj_a_files())
  first <- run_inbox(s)
  expect_true(first$ran)
  backups <- list.files(s$backup_dir)
  # Instead of sleeping: backdate the notes, so any rewrite would show a new
  # mtime, and run the second sweep with the clock moved on. (The input files
  # and the DB cannot be backdated: their stat IS the signature under test.)
  backdate_tree(s$report_dir)
  rep_before <- tree_snapshot(s$report_dir)
  in_before <- tree_snapshot(s$input_dir)
  db_md5 <- file_md5(s$db)
  db_mtime <- file.mtime(s$db)

  # the run's own removals/writes must not trigger the next check
  second <- run_inbox(s, now = Sys.time() + 2)
  expect_false(second$ran)
  expect_identical(second$action, "none")
  expect_identical(list.files(s$backup_dir), backups)
  expect_identical(tree_snapshot(s$report_dir), rep_before)
  expect_identical(tree_snapshot(s$input_dir), in_before)
  expect_identical(file_md5(s$db), db_md5)
  expect_identical(file.mtime(s$db), db_mtime)
  expect_false(file.exists(inbox_lock_path(s$db)))
})

test_that("inbox_run(): only batch-* subdirectories are candidates; bare 'batch-', other dirs and loose files are left alone (loose files are listed in status.json)", {
  s <- inbox_setup()
  now <- Sys.time()
  make_inbox_folder(s$input_dir, "batch-2026-10-18 0900 PROJ_A", inbox_proj_a_files(), now = now)
  make_inbox_folder(s$input_dir, "batch-", inbox_fixture("crosstab", "ES2670610_0_XTAB.csv"), now = now)
  make_inbox_folder(s$input_dir, "my notes", inbox_fixture("crosstab", "ES2570540_0_ENMRG.CSV"), now = now)
  loose <- file.path(s$input_dir, "loose_ES2670610.csv")
  file.copy(inbox_fixture("crosstab", "ES2670610_0_XTAB.csv"), loose)
  Sys.setFileTime(loose, now - 3600)

  res <- run_inbox(s, now = now)
  expect_true(res$ran)
  expect_identical(res$folders_processed, "batch-2026-10-18 0900 PROJ_A")
  expect_false("batch-" %in% res$folders_seen)
  expect_false("my notes" %in% res$folders_seen)

  # untouched, and never routed
  expect_true(file.exists(file.path(s$input_dir, "batch-", "ES2670610_0_XTAB.csv")))
  expect_true(file.exists(file.path(s$input_dir, "my notes", "ES2570540_0_ENMRG.CSV")))
  expect_true(file.exists(loose))
  fn <- ingest_file_rows(s$db)$filename
  expect_false(any(fn %in% c("ES2670610_0_XTAB.csv", "ES2570540_0_ENMRG.CSV", "loose_ES2670610.csv"),
                   na.rm = TRUE))
  expect_true("PROJ_A.ESDAT_XX1234567_0.Chemistry2e.CSV" %in% fn)

  # the loose file is listed in status.json, with its path
  js <- read_status_json(s$report_dir)
  expect_length(js$loose, 1)
  expect_identical(js$loose[[1]]$file, "loose_ES2670610.csv")
  expect_identical(js$loose[[1]]$path, file.path(s$input_dir, "loose_ES2670610.csv"))
  # sibling directories (archive, bare batch-, the user's own folders) are not listed
  listed <- vapply(js$waiting, function(w) w$folder, character(1))
  expect_false(any(c("batch-", "my notes") %in% listed))
  expect_false(any(vapply(js$loose, function(l) l$file, character(1)) %in% c("batch-", "my notes")))
})

test_that("inbox_run(): settled gate - a folder with a recently-modified file is 'arriving', not imported; pending makes the next call run", {
  s <- inbox_setup()
  now <- Sys.time()
  make_inbox_folder(s$input_dir, "batch-2026-10-18 0900 settled", inbox_proj_a_files(), age_min = 60, now = now)
  # one old file and one written 2 minutes ago: not settled (settle_minutes = 10)
  arr <- make_inbox_folder(s$input_dir, "batch-2026-10-18 0950 arriving", inbox_rain_files(), age_min = 60, now = now)
  t_last <- as.POSIXct(floor(as.numeric(now)) - 120, origin = "1970-01-01", tz = "UTC")
  Sys.setFileTime(file.path(arr, basename(inbox_rain_files()[[1]])), t_last)
  dir.create(file.path(s$input_dir, "batch-2026-10-18 0955 empty"))

  res <- run_inbox(s, now = now, settle_minutes = 10)
  expect_identical(res$folders_settled, "batch-2026-10-18 0900 settled")
  expect_identical(res$folders_processed, "batch-2026-10-18 0900 settled")
  expect_setequal(res$folders_arriving, c("batch-2026-10-18 0950 arriving", "batch-2026-10-18 0955 empty"))

  # the arriving folder is untouched and none of its files were routed
  expect_setequal(list.files(arr), basename(inbox_rain_files()))
  expect_false(any(basename(inbox_rain_files()) %in% ingest_file_rows(s$db)$filename))

  e <- status_waiting(s$report_dir, "batch-2026-10-18 0950 arriving")
  expect_identical(e$status, "arriving")
  expect_identical(e$path, file.path(s$input_dir, "batch-2026-10-18 0950 arriving"))
  expect_identical(e$last_written, format(t_last, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"))
  expect_setequal(unlist(e$files), basename(inbox_rain_files()))
  empty <- status_waiting(s$report_dir, "batch-2026-10-18 0955 empty")
  expect_identical(empty$status, "arriving")
  expect_true("last_written" %in% names(empty))
  expect_null(empty$last_written)

  st <- read_inbox_state(s$report_dir)
  expect_true(isTRUE(st$pending))
  expect_identical(inbox_check(s$input_dir, s$report_dir, now = now, db = s$db), "run")

  # an hour later, nothing else changed: pending forces a run and it imports
  later <- now + 3600
  res2 <- run_inbox(s, now = later)
  expect_true(res2$ran)
  expect_identical(res2$folders_processed, "batch-2026-10-18 0950 arriving")
  expect_true(all(basename(inbox_rain_files()) %in% ingest_file_rows(s$db)$filename))
})

test_that("inbox_run(): a settled folder counts files' mtimes, not the folder's own fresh mtime", {
  s <- inbox_setup()
  now <- Sys.time()
  d <- make_inbox_folder(s$input_dir, "batch-2026-10-18 0900 a", inbox_proj_a_files(), age_min = 30, now = now)
  Sys.setFileTime(d, now)   # the folder itself was just touched
  res <- run_inbox(s, now = now)
  expect_identical(res$folders_processed, "batch-2026-10-18 0900 a")
})

test_that("inbox_run(): signature changed but nothing new to import -> no backup, no DB write; status.json and state written, no markdown", {
  s <- inbox_setup()
  now <- Sys.time()
  d <- make_inbox_folder(s$input_dir, "batch-2026-10-18 0900 corrupt", inbox_corrupt_file(), now = now)
  quiet_run(ingest_dir(d, db = s$db))   # the file is now known: state 'failed'
  expect_true(file.exists(file.path(d, basename(inbox_corrupt_file()))))
  db_md5 <- file_md5(s$db)

  res <- run_inbox(s, now = now)
  expect_true(res$ran)
  expect_identical(length(list.files(s$backup_dir)), 0L)
  expect_true(is.na(res$backup_path))
  expect_identical(file_md5(s$db), db_md5)
  expect_true(file.exists(file.path(s$report_dir, "status.json")))
  expect_true(file.exists(file.path(s$report_dir, ".imports.state")))
  expect_length(report_md_files(s$report_dir), 0)
  # the failed file and its folder stay
  expect_true(file.exists(file.path(d, basename(inbox_corrupt_file()))))
})

test_that("inbox_run(): the backup is taken before any write and is a verified copy of the pre-run DB", {
  s <- inbox_setup()
  now <- Sys.time()
  make_inbox_folder(s$input_dir, "batch-2026-10-18 0900 a", inbox_proj_a_files(), now = now)
  pre_md5 <- file_md5(s$db)

  res <- run_inbox(s, now = now)
  expect_true(res$ran)
  expect_type(res$backup_path, "character")
  expect_true(file.exists(res$backup_path))
  expect_identical(normalizePath(dirname(res$backup_path)), normalizePath(s$backup_dir))
  expect_match(basename(res$backup_path), "^monitoring_pre-auto-import_.+\\.duckdb$")
  expect_identical(file_md5(res$backup_path), pre_md5)
  expect_false(identical(file_md5(s$db), pre_md5))  # the import did write
})

test_that("inbox_run(): rotation keeps the newest keep_backups matching files and never touches other files", {
  s <- inbox_setup()
  now <- Sys.time()
  fakes <- sprintf("monitoring_pre-auto-import_20260101T0000%02dZ.duckdb", 1:12)
  for (i in seq_along(fakes)) {
    p <- file.path(s$backup_dir, fakes[[i]])
    writeLines(paste("fake backup", i), p)
    Sys.setFileTime(p, as.POSIXct("2026-01-01", tz = "UTC") + i * 60)
  }
  others <- c("monitoring_pre-migration-030_20260101.duckdb", "README.txt",
              "monitoring_pre-auto-import_notes.txt")
  for (o in others) writeLines("keep me", file.path(s$backup_dir, o))
  make_inbox_folder(s$input_dir, "batch-2026-10-18 0900 a", inbox_proj_a_files(), now = now)

  res <- run_inbox(s, now = now, keep_backups = 10)
  left <- list.files(s$backup_dir)
  matching <- grep("^monitoring_pre-auto-import_.*\\.duckdb$", left, value = TRUE)
  expect_length(matching, 10)
  expect_true(basename(res$backup_path) %in% matching)
  expect_setequal(setdiff(matching, basename(res$backup_path)), fakes[4:12])
  expect_true(all(others %in% left))
})

test_that("inbox_run(): a backup that fails verification aborts the run - error reported, no DB write, inputs untouched, retried next time", {
  s <- inbox_setup()
  now <- Sys.time()
  d <- make_inbox_folder(s$input_dir, "batch-2026-10-18 0900 a", inbox_proj_a_files(), now = now)
  pre_md5 <- file_md5(s$db)
  in_before <- tree_snapshot(s$input_dir)

  testthat::local_mocked_bindings(.inbox_backup_copy = function(from, to) {
    writeLines("truncated copy", to)
    TRUE
  })
  res <- run_inbox(s, now = now)

  expect_gt(length(res$errors), 0)
  expect_true(any(grepl("backup", res$errors, ignore.case = TRUE)))
  expect_identical(file_md5(s$db), pre_md5)
  expect_identical(tree_snapshot(s$input_dir), in_before)
  expect_length(res$folders_processed, 0)
  expect_false(file.exists(inbox_lock_path(s$db)))

  # reported as a Problem in status.json, and as an error in the run's log line
  expect_true(any(grepl("backup", unlist(read_status_json(s$report_dir)$problems), ignore.case = TRUE)))
  expect_true(any(grepl("backup", unlist(read_inbox_log(s$report_dir)[[1]]$errors), ignore.case = TRUE)))
  # the failed run must not record the inbox as handled
  expect_identical(inbox_check(s$input_dir, s$report_dir, now = now, db = s$db), "run")
})

test_that("inbox_run(): folders are imported oldest name first, one ingest_dir() call each", {
  s <- inbox_setup()
  now <- Sys.time()
  # created newest-name-first, with mtimes in the opposite order to the names
  make_inbox_folder(s$input_dir, "batch-2026-10-18 1000 c", inbox_fixture("crosstab", "ES2670610_0_XTAB.csv"),
                    age_min = 300, now = now)
  make_inbox_folder(s$input_dir, "batch-2026-10-18 0900 b", inbox_rain_files(), age_min = 200, now = now)
  make_inbox_folder(s$input_dir, "batch-2026-10-17 2300 a", inbox_proj_a_files(), age_min = 100, now = now)

  real_ingest_dir <- ingest_dir
  calls <- character(0)
  testthat::local_mocked_bindings(ingest_dir = function(path, ...) {
    calls <<- c(calls, basename(path))
    real_ingest_dir(path, ...)
  })
  res <- run_inbox(s, now = now)
  want <- c("batch-2026-10-17 2300 a", "batch-2026-10-18 0900 b", "batch-2026-10-18 1000 c")
  expect_identical(calls, want)
  expect_identical(res$folders_processed, want)
})

test_that("inbox_run(): one folder failing does not stop the next; the failure is recorded", {
  s <- inbox_setup()
  now <- Sys.time()
  make_inbox_folder(s$input_dir, "batch-2026-10-18 0800 boom", inbox_rain_files(), now = now)
  make_inbox_folder(s$input_dir, "batch-2026-10-18 0830 corrupt", inbox_corrupt_file(), now = now)
  make_inbox_folder(s$input_dir, "batch-2026-10-18 0900 good", inbox_proj_a_files(), now = now)

  real_ingest_dir <- ingest_dir
  testthat::local_mocked_bindings(ingest_dir = function(path, ...) {
    if (grepl("boom", basename(path))) stop("simulated folder failure XYZZY")
    real_ingest_dir(path, ...)
  })
  res <- run_inbox(s, now = now)

  expect_identical(res$folders_processed,
                   c("batch-2026-10-18 0800 boom", "batch-2026-10-18 0830 corrupt", "batch-2026-10-18 0900 good"))
  boom <- res$folders[["batch-2026-10-18 0800 boom"]]
  expect_true(isTRUE(boom$failed))
  expect_match(boom$error, "XYZZY")
  good <- res$folders[["batch-2026-10-18 0900 good"]]
  expect_false(isTRUE(good$failed))
  expect_gte(good$events_committed, 1)
  expect_true("PROJ_A.ESDAT_XX1234567_0.Chemistry2e.CSV" %in% ingest_file_rows(s$db)$filename)
  # the corrupt file failed inside ingest_dir: recorded as a file left behind
  expect_true(basename(inbox_corrupt_file()) %in% res$folders[["batch-2026-10-18 0830 corrupt"]]$files_left)

  logged <- read_inbox_log(s$report_dir)[[1]]$folders[["batch-2026-10-18 0800 boom"]]
  expect_true(isTRUE(logged$failed))
  expect_match(logged$error, "XYZZY")
  expect_true(any(grepl("XYZZY", unlist(read_status_json(s$report_dir)$problems), fixed = TRUE)))
})

test_that("inbox_run(): archived files are removed, emptied folders removed, unfinished folders kept", {
  s <- inbox_setup()
  now <- Sys.time()
  make_inbox_folder(s$input_dir, "batch-2026-10-18 0900 done", inbox_proj_a_files(), now = now)
  mixed <- make_inbox_folder(s$input_dir, "batch-2026-10-18 0930 mixed",
                             c(inbox_rain_files(), inbox_corrupt_file(), inbox_fixture("esdat", "random.csv")),
                             now = now)
  res <- run_inbox(s, now = now)

  expect_false(dir.exists(file.path(s$input_dir, "batch-2026-10-18 0900 done")))
  expect_true(dir.exists(mixed))
  states <- ingest_file_rows(s$db)
  for (fn in basename(inbox_rain_files())) {
    expect_identical(states$state[match(fn, states$filename)], "archived")
    expect_false(file.exists(file.path(mixed, fn)), info = fn)
  }
  expect_true(file.exists(file.path(mixed, basename(inbox_corrupt_file()))))
  expect_true(file.exists(file.path(mixed, "random.csv")))
  expect_setequal(res$folders[["batch-2026-10-18 0930 mixed"]]$files_left,
                  c(basename(inbox_corrupt_file()), "random.csv"))
  expect_length(res$folders[["batch-2026-10-18 0900 done"]]$files_left, 0)

  # the unfinished folder is listed as waiting, naming its files and their state
  e <- status_waiting(s$report_dir, "batch-2026-10-18 0930 mixed")
  expect_identical(e$status, "left")
  expect_true(e$unfinished)
  expect_identical(e$path, file.path(s$input_dir, "batch-2026-10-18 0930 mixed"))
  st_of <- stats::setNames(vapply(e$files, function(f) f$state, character(1)),
                           vapply(e$files, function(f) f$file, character(1)))
  expect_identical(st_of[[basename(inbox_corrupt_file())]], "failed")
  expect_identical(st_of[["random.csv"]], "quarantined")
  expect_null(status_waiting(s$report_dir, "batch-2026-10-18 0900 done"))
})

test_that("inbox_run(): a live lock makes a second run exit immediately, writing nothing", {
  s <- inbox_setup()
  now <- Sys.time()
  make_inbox_folder(s$input_dir, "batch-2026-10-18 0900 a", inbox_proj_a_files(), now = now)
  lock <- write_inbox_lock(s$db, live_child_pid(), now - 5 * 60)
  lock_md5 <- file_md5(lock)
  pre_md5 <- file_md5(s$db)
  in_before <- tree_snapshot(s$input_dir)

  res <- run_inbox(s, now = now)
  expect_true(isTRUE(res$locked))
  expect_false(isTRUE(res$ran))
  expect_identical(file_md5(s$db), pre_md5)
  expect_identical(tree_snapshot(s$input_dir), in_before)
  expect_length(list.files(s$backup_dir), 0)
  expect_length(list.files(s$report_dir, all.files = TRUE, no.. = TRUE), 0)
  expect_identical(file_md5(lock), lock_md5)
})

test_that("inbox_run(): a lock whose PID is dead is stale: taken over and reported", {
  s <- inbox_setup()
  now <- Sys.time()
  make_inbox_folder(s$input_dir, "batch-2026-10-18 0900 a", inbox_proj_a_files(), now = now)
  write_inbox_lock(s$db, dead_pid(), now - 5 * 60)

  res <- run_inbox(s, now = now)
  expect_true(res$ran)
  expect_true(isTRUE(res$stale_lock))
  expect_identical(res$folders_processed, "batch-2026-10-18 0900 a")
  expect_false(file.exists(inbox_lock_path(s$db)))
  expect_true(isTRUE(read_inbox_log(s$report_dir)[[1]]$stale_lock))
  expect_true(any(grepl("stale", unlist(read_status_json(s$report_dir)$problems), ignore.case = TRUE)))
  expect_length(report_md_files(s$report_dir), 0)
})

test_that("inbox_run(): a lock older than 2 hours is stale even if its PID is alive", {
  s <- inbox_setup()
  now <- Sys.time()
  make_inbox_folder(s$input_dir, "batch-2026-10-18 0900 a", inbox_proj_a_files(), now = now)
  write_inbox_lock(s$db, live_child_pid(), now - 3 * 3600)

  res <- run_inbox(s, now = now)
  expect_true(res$ran)
  expect_true(isTRUE(res$stale_lock))
  expect_identical(res$folders_processed, "batch-2026-10-18 0900 a")
})

test_that("inbox_run(): appends one JSON line per run with the documented fields", {
  s <- inbox_setup()
  now <- Sys.time()
  make_inbox_folder(s$input_dir, "batch-2026-10-18 0900 a", inbox_proj_a_files(), now = now)
  res <- run_inbox(s, now = now)
  log <- read_inbox_log(s$report_dir)
  expect_length(log, 1)
  l <- log[[1]]
  for (k in c("started_at", "ended_at", "folders_seen", "folders_settled",
              "folders_processed", "folders", "backup_path", "errors")) {
    expect_true(k %in% names(l), info = k)
  }
  expect_identical(unlist(l$folders_processed), "batch-2026-10-18 0900 a")
  f <- l$folders[["batch-2026-10-18 0900 a"]]
  for (k in c("events_committed", "rows_new", "rows_already_present", "rows_superseded",
              "review_items_opened", "failed", "files_left")) {
    expect_true(k %in% names(f), info = k)
  }
  expect_identical(as.integer(f$rows_new), as.integer(res$folders[["batch-2026-10-18 0900 a"]]$rows_new))
  expect_gt(as.integer(f$rows_new), 0)
  expect_identical(l$backup_path, res$backup_path)

  # a second real run appends rather than rewrites; a 'none' call appends nothing
  make_inbox_folder(s$input_dir, "batch-2026-10-18 1000 b", inbox_rain_files(), now = now)
  run_inbox(s, now = now)
  run_inbox(s, now = now)
  expect_length(read_inbox_log(s$report_dir), 2)
})

test_that("inbox_run(dry_run = TRUE): no backup, no DB write, no removal, no state; status.json has the plan and is flagged dry_run", {
  s <- inbox_setup()
  now <- Sys.time()
  d <- make_inbox_folder(s$input_dir, "batch-2026-10-18 0900 a", inbox_proj_a_files(), now = now)
  pre_md5 <- file_md5(s$db)
  in_before <- tree_snapshot(s$input_dir)

  res <- run_inbox(s, now = now, dry_run = TRUE)
  expect_true(res$ran)
  expect_true(isTRUE(res$dry_run))
  expect_length(list.files(s$backup_dir), 0)
  expect_identical(file_md5(s$db), pre_md5)
  expect_identical(tree_snapshot(s$input_dir), in_before)
  # a dry run must not mark the inbox as handled, or the real run would skip it
  expect_false(file.exists(file.path(s$report_dir, ".imports.state")))
  js <- read_status_json(s$report_dir)
  expect_true(js$dry_run)
  expect_identical(unlist(js$dry_run_plan$would_import), "batch-2026-10-18 0900 a")
  # The folder's files are all new data, so it would be filed after import too
  # (the same verdict main's "Would file" banner line reported).
  expect_length(js$dry_run_plan$would_file, 1)
  expect_identical(js$dry_run_plan$would_file[[1]]$folder, "batch-2026-10-18 0900 a")
  expect_length(report_md_files(s$report_dir), 0)

  real <- run_inbox(s, now = now)
  expect_true(real$ran)
  expect_identical(real$folders_processed, "batch-2026-10-18 0900 a")
})

test_that("inbox_run(): a DB change alone refreshes status.json read-only; a resolved item disappears", {
  s <- inbox_setup()
  now <- sydney_midday()
  make_inbox_folder(s$input_dir, "batch-2026-10-18 0900 a", inbox_rain_files(), now = now)
  run_inbox(s, now = now)
  review_wos <- function() {
    vapply(read_status_json(s$report_dir)$needs_review, function(g) g$work_order, character(1))
  }
  expect_true("ES2664217" %in% review_wos())
  # Instead of sleeping: backdate the log so a rewrite would show.
  backdate_tree(s$report_dir)
  log_before <- tree_snapshot(s$report_dir)[".imports.log"]
  log_n <- length(read_inbox_log(s$report_dir))
  backups <- list.files(s$backup_dir)

  # resolve every ES2664217 item outside an import (as a migration would)
  con <- seed_con(s$db)
  DBI::dbExecute(con, "UPDATE review_queue SET status = 'resolved' WHERE work_order = 'ES2664217'")
  DBI::dbDisconnect(con, shutdown = TRUE)
  # The DB stat is what inbox_check() reads. The sleep that used to sit above
  # made sure the UPDATE's mtime differed from the recorded one even on a
  # filesystem with whole-second mtimes; move it on explicitly instead.
  Sys.setFileTime(s$db, Sys.time() + 5)
  db_md5 <- file_md5(s$db)
  expect_identical(inbox_check(s$input_dir, s$report_dir, now = now, db = s$db), "status")

  res <- run_inbox(s, now = now + 60)
  expect_identical(res$action, "status")
  expect_false(res$ran)
  expect_false("ES2664217" %in% review_wos())
  expect_identical(file_md5(s$db), db_md5)                 # read-only
  expect_identical(list.files(s$backup_dir), backups)       # no backup
  expect_identical(tree_snapshot(s$report_dir)[".imports.log"], log_before)
  expect_length(read_inbox_log(s$report_dir), log_n)        # no import logged
  expect_length(report_md_files(s$report_dir), 0)
  # the refresh records the DB stat, so the next check is quiet again
  expect_identical(inbox_check(s$input_dir, s$report_dir, now = now + 120, db = s$db), "none")
})

test_that("inbox_run(): quiet days get one status-only refresh per Sydney day, never an import (R14)", {
  s <- inbox_setup()
  now <- sydney_midday()
  make_inbox_folder(s$input_dir, "batch-2026-10-18 0900 a", inbox_rain_files(), now = now)
  run_inbox(s, now = now)
  backdate_tree(s$report_dir)
  log_snap <- tree_snapshot(s$report_dir)[".imports.log"]
  log_n <- length(read_inbox_log(s$report_dir))
  backups <- list.files(s$backup_dir)
  db_md5 <- file_md5(s$db)
  for (k in 1:3) {
    unlink(file.path(s$report_dir, c("status.json", ".import-status.json")))
    r <- run_inbox(s, now = now + k * 86400)
    expect_identical(r$action, "status")
    expect_false(r$ran)
    expect_true(file.exists(file.path(s$report_dir, "status.json")))       # rewritten
    expect_identical(read_status_json(s$report_dir)$updated,
                     format(now + k * 86400, "%Y-%m-%d %H:%M", tz = "Australia/Sydney"))
    expect_identical(run_inbox(s, now = now + k * 86400 + 3600)$action, "none")  # once a day
  }
  expect_identical(file_md5(s$db), db_md5)
  expect_identical(list.files(s$backup_dir), backups)
  expect_length(read_inbox_log(s$report_dir), log_n)                 # nothing imported or logged
  expect_identical(tree_snapshot(s$report_dir)[".imports.log"], log_snap)
  expect_length(report_md_files(s$report_dir), 0)
})

test_that("inbox_run(): a work order's site and counts are in the log, the return value and status.json", {
  s <- inbox_setup()
  now <- Sys.time()
  make_inbox_folder(s$input_dir, "batch-2026-10-18 0900 PROJ_A", inbox_proj_a_files(), now = now)
  make_inbox_folder(s$input_dir, "batch-2026-10-18 0930 rain", inbox_rain_files(), now = now)
  res <- run_inbox(s, now = now)

  wo_of <- function(folder, name) {
    for (w in res$folders[[folder]]$work_orders) if (identical(w$name, name)) return(w)
    NULL
  }
  a <- wo_of("batch-2026-10-18 0900 PROJ_A", "XX1234567")
  b <- wo_of("batch-2026-10-18 0930 rain", "ES2664217")
  expect_false(is.null(a))
  expect_false(is.null(b))
  expect_identical(a$site, "B")                      # the code, not a label
  expect_true(is.na(b$site))                         # dangling aliases: no site
  expect_match(a$kind, "ALS")
  expect_gt(a$samples, 0)
  expect_identical(a$analyses, res$folders[["batch-2026-10-18 0900 PROJ_A"]]$rows_new)
  expect_identical(b$analyses, res$folders[["batch-2026-10-18 0930 rain"]]$rows_new)

  # the log and status.json carry the same, a missing site as JSON null
  recent <- read_status_json(s$report_dir)$recent_imports
  by_wo <- stats::setNames(recent, vapply(recent, function(r) r$work_order, character(1)))
  expect_identical(by_wo[["XX1234567"]]$site, "B")
  expect_null(by_wo[["ES2664217"]]$site)
  expect_identical(by_wo[["XX1234567"]]$date, sydney_date(now))
  expect_length(report_md_files(s$report_dir), 0)
})

# ---- section 2a: import_status() (the standing note) --------------------------

review_fixture <- function(now) {
  h <- function(x) now - x * 3600
  data.frame(
    uuid = sprintf("rq-%02d", 1:11),
    created_at = as.POSIXct(c(h(200), h(150), h(2), h(3), h(30), h(1), h(400),
                              h(100), h(90), h(80), h(1)), origin = "1970-01-01", tz = "UTC"),
    # A self-precedence note is stored as kind 'unknown_feature' with SUBKIND
    # 'self_precedence_note' (.rc_self_precedence_notes() in R/reconcile.R; the
    # live queue's rows have that shape), never kind = 'self_precedence_note'.
    kind = c("date_conflict", "date_conflict", "work_order_reingest", "unknown_feature",
             "unknown_feature", "unknown_feature", "unknown_feature",
             "unknown_feature", "unknown_feature", "unknown_feature",
             "unknown_feature"),
    subkind = c("a77", "a77", "blocked", NA, NA, NA, NA,
                "self_precedence_note", "self_precedence_note", "self_precedence_note", NA),
    work_order = c("2400-1111-01", "2400-1111-01", "ES1111111", "ES2222222", "ES2222222",
                   "ES3333333", "ES4444444", "ES5555551", "ES5555552", "ES5555553", "ES9999999"),
    status = c(rep("open", 10), "resolved"),
    stringsAsFactors = FALSE
  )
}

test_that("import_status(): writes .import-status.json with the same content as data", {
  s <- inbox_setup()
  now <- as.POSIXct("2026-10-18 14:30:00", tz = "UTC")
  insert_review_items(s$db, review_fixture(now))
  quiet_run(import_status(db = s$db, input_dir = s$input_dir, report_dir = s$report_dir, now = now))
  p <- file.path(s$report_dir, ".import-status.json")
  expect_true(file.exists(p))
  txt <- paste(readLines(p, warn = FALSE), collapse = "\n")
  expect_no_error(jsonlite::fromJSON(txt))
  for (wo in c("2400-1111-01", "ES1111111", "ES2222222")) expect_match(txt, wo, fixed = TRUE)
  expect_false(grepl("ES9999999", txt, fixed = TRUE))
})

test_that("import_status(): self-precedence notes (kind unknown_feature, subkind self_precedence_note) are counted in non_blocking_notes, not grouped", {
  s <- inbox_setup()
  now <- as.POSIXct("2026-10-18 14:30:00", tz = "UTC")
  insert_review_items(s$db, review_fixture(now))
  quiet_run(import_status(db = s$db, input_dir = s$input_dir, report_dir = s$report_dir, now = now))
  js <- jsonlite::fromJSON(file.path(s$report_dir, ".import-status.json"))

  # The three open notes are counted, and still count as open review items.
  expect_identical(as.integer(js$non_blocking_notes), 3L)
  expect_identical(as.integer(js$review_items_open), 10L)

  # None of them is an import-status group.
  nr <- as.data.frame(js$needs_review)
  expect_gt(nrow(nr), 0)
  expect_false(any(nr$subkind %in% "self_precedence_note"))
  expect_false(any(grepl("^ES555555", nr$work_order)))
  # The ordinary unknown_feature items (no subkind) are still grouped.
  uf <- nr[nr$kind == "unknown_feature", , drop = FALSE]
  expect_setequal(uf$work_order, c("ES2222222", "ES3333333", "ES4444444"))
  expect_true(all(is.na(uf$subkind)))
  expect_identical(as.integer(sum(uf$n)), 4L)
})

test_that(".inbox_review_groups(): drops rows whose subkind is self_precedence_note, keeps other unknown_feature rows", {
  now <- as.POSIXct("2026-10-18 14:30:00", tz = "UTC")
  rv <- data.frame(
    kind = c("unknown_feature", "unknown_feature", "unknown_feature"),
    subkind = c("self_precedence_note", NA, "self_precedence_note"),
    work_order = c("ES5555551", "ES2222222", NA),
    created_at = as.numeric(now) - c(3600, 7200, 10800),
    stringsAsFactors = FALSE
  )
  g <- .inbox_review_groups(rv, now)
  expect_identical(nrow(g), 1L)
  expect_identical(g$work_order, "ES2222222")
  expect_true(is.na(g$subkind))

  # Only notes -> no groups at all.
  expect_identical(NROW(.inbox_review_groups(rv[c(1, 3), , drop = FALSE], now)), 0L)
})

