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
  make_inbox_folder(d, "input2026-10-18 0900 a", inbox_proj_a_files())
  s1 <- inbox_signature(d)
  s2 <- inbox_signature(d)
  expect_type(s1, "character")
  expect_length(s1, 1)
  expect_identical(s1, s2)
})

test_that("inbox_signature() is built from metadata only, never file contents", {
  d <- withr::local_tempdir()
  f <- st_test_write_file(d, "input2026-10-18 0900 a/report.csv", raw = charToRaw("AAAAAAAAAA"))
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
  f <- st_test_write_file(d, "input2026-10-18 0900 a/report.csv", raw = charToRaw("AAAAAAAAAA"))
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

  g <- st_test_write_file(d, "input2026-10-18 0900 a/coa.pdf", "x")
  s_add <- inbox_signature(d)
  expect_false(identical(s_add, base), info = "file added inside a folder")
  file.rename(g, file.path(dirname(g), "coa2.pdf"))
  expect_false(identical(inbox_signature(d), s_add), info = "file renamed")
  s_ren <- inbox_signature(d)
  file.remove(file.path(dirname(g), "coa2.pdf"))
  expect_false(identical(inbox_signature(d), s_ren), info = "file removed")

  s_before_dir <- inbox_signature(d)
  dir.create(file.path(d, "input2026-10-18 1000 b"))
  expect_false(identical(inbox_signature(d), s_before_dir), info = "folder added")
  s_before_loose <- inbox_signature(d)
  st_test_write_file(d, "loose.csv", "x")
  expect_false(identical(inbox_signature(d), s_before_loose), info = "loose file added")
})

# ---- section 0: inbox_check() ------------------------------------------------

test_that("inbox_check(): no state file -> 'run', and the check writes nothing", {
  s <- inbox_setup()
  make_inbox_folder(s$input_dir, "input2026-10-18 0900 a", inbox_proj_a_files())
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
  before <- tree_snapshot(s$report_dir)
  Sys.sleep(1.1)
  expect_identical(inbox_check(s$input_dir, s$report_dir, now = Sys.time(), db = s$db), "none")
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

# ---- section 1: inbox_run() ----------------------------------------------------

test_that("inbox_run(): a 'none' check does nothing at all (ran = FALSE)", {
  s <- inbox_setup()
  make_inbox_folder(s$input_dir, "input2026-10-18 0900 a", inbox_proj_a_files())
  first <- run_inbox(s)
  expect_true(first$ran)
  backups <- list.files(s$backup_dir)
  rep_before <- tree_snapshot(s$report_dir)
  in_before <- tree_snapshot(s$input_dir)
  db_md5 <- file_md5(s$db)
  db_mtime <- file.mtime(s$db)
  Sys.sleep(1.1)

  # the run's own removals/writes must not trigger the next check
  second <- run_inbox(s)
  expect_false(second$ran)
  expect_identical(second$action, "none")
  expect_identical(list.files(s$backup_dir), backups)
  expect_identical(tree_snapshot(s$report_dir), rep_before)
  expect_identical(tree_snapshot(s$input_dir), in_before)
  expect_identical(file_md5(s$db), db_md5)
  expect_identical(file.mtime(s$db), db_mtime)
  expect_false(file.exists(inbox_lock_path(s$db)))
})

test_that("inbox_run(): only input* subdirectories are candidates; bare 'input', other dirs and loose files are left alone", {
  s <- inbox_setup()
  now <- Sys.time()
  make_inbox_folder(s$input_dir, "input2026-10-18 0900 PROJ_A", inbox_proj_a_files(), now = now)
  make_inbox_folder(s$input_dir, "input", inbox_fixture("crosstab", "ES2600185_0_XTAB.csv"), now = now)
  make_inbox_folder(s$input_dir, "Robin's notes", inbox_fixture("crosstab", "ES2537534_0_ENMRG.CSV"), now = now)
  loose <- file.path(s$input_dir, "loose_ES2600185.csv")
  file.copy(inbox_fixture("crosstab", "ES2600185_0_XTAB.csv"), loose)
  Sys.setFileTime(loose, now - 3600)

  res <- run_inbox(s, now = now)
  expect_true(res$ran)
  expect_identical(res$folders_processed, "input2026-10-18 0900 PROJ_A")
  expect_false("input" %in% res$folders_seen)
  expect_false("Robin's notes" %in% res$folders_seen)

  # untouched, and never routed
  expect_true(file.exists(file.path(s$input_dir, "input", "ES2600185_0_XTAB.csv")))
  expect_true(file.exists(file.path(s$input_dir, "Robin's notes", "ES2537534_0_ENMRG.CSV")))
  expect_true(file.exists(loose))
  fn <- ingest_file_rows(s$db)$filename
  expect_false(any(fn %in% c("ES2600185_0_XTAB.csv", "ES2537534_0_ENMRG.CSV", "loose_ES2600185.csv"),
                   na.rm = TRUE))
  expect_true("PROJ_A.ESDAT_XX1234567_0.Chemistry2e.CSV" %in% fn)

  # the loose file is listed as waiting in the status note
  waiting <- md_section(read_status_note(s$report_dir), "Waiting")
  expect_true(any(grepl("loose_ES2600185.csv", waiting, fixed = TRUE)))
  # sibling directories (archive, bare input, the user's own folders) are not listed
  expect_false(any(grepl("Robin's notes", waiting, fixed = TRUE)))
  expect_false(any(grepl("not an import folder", waiting, fixed = TRUE)))
})

test_that("inbox_run(): settled gate - a folder with a recently-modified file is 'arriving', not imported; pending makes the next call run", {
  s <- inbox_setup()
  now <- Sys.time()
  make_inbox_folder(s$input_dir, "input2026-10-18 0900 settled", inbox_proj_a_files(), age_min = 60, now = now)
  # one old file and one written 2 minutes ago: not settled (settle_minutes = 10)
  arr <- make_inbox_folder(s$input_dir, "input2026-10-18 0950 arriving", inbox_rain_files(), age_min = 60, now = now)
  Sys.setFileTime(file.path(arr, basename(inbox_rain_files()[[1]])), now - 120)
  dir.create(file.path(s$input_dir, "input2026-10-18 0955 empty"))

  res <- run_inbox(s, now = now, settle_minutes = 10)
  expect_identical(res$folders_settled, "input2026-10-18 0900 settled")
  expect_identical(res$folders_processed, "input2026-10-18 0900 settled")
  expect_setequal(res$folders_arriving, c("input2026-10-18 0950 arriving", "input2026-10-18 0955 empty"))

  # the arriving folder is untouched and none of its files were routed
  expect_setequal(list.files(arr), basename(inbox_rain_files()))
  expect_false(any(basename(inbox_rain_files()) %in% ingest_file_rows(s$db)$filename))

  waiting <- md_section(read_status_note(s$report_dir), "Waiting")
  arr_line <- waiting[grepl("0950 arriving", waiting, fixed = TRUE)]
  expect_gt(length(arr_line), 0)
  expect_true(any(grepl("arriving", waiting, ignore.case = TRUE)))
  expect_true(any(grepl("file:///", arr_line, fixed = TRUE)))

  st <- read_inbox_state(s$report_dir)
  expect_true(isTRUE(st$pending))
  expect_identical(inbox_check(s$input_dir, s$report_dir, now = now, db = s$db), "run")

  # an hour later, nothing else changed: pending forces a run and it imports
  later <- now + 3600
  res2 <- run_inbox(s, now = later)
  expect_true(res2$ran)
  expect_identical(res2$folders_processed, "input2026-10-18 0950 arriving")
  expect_true(all(basename(inbox_rain_files()) %in% ingest_file_rows(s$db)$filename))
})

test_that("inbox_run(): a settled folder counts files' mtimes, not the folder's own fresh mtime", {
  s <- inbox_setup()
  now <- Sys.time()
  d <- make_inbox_folder(s$input_dir, "input2026-10-18 0900 a", inbox_proj_a_files(), age_min = 30, now = now)
  Sys.setFileTime(d, now)   # the folder itself was just touched
  res <- run_inbox(s, now = now)
  expect_identical(res$folders_processed, "input2026-10-18 0900 a")
})

test_that("inbox_run(): signature changed but nothing new to import -> no backup, no DB write; status note and state written, no dated note", {
  s <- inbox_setup()
  now <- Sys.time()
  d <- make_inbox_folder(s$input_dir, "input2026-10-18 0900 corrupt", inbox_corrupt_file(), now = now)
  quiet_run(ingest_dir(d, db = s$db))   # the file is now known: state 'failed'
  expect_true(file.exists(file.path(d, basename(inbox_corrupt_file()))))
  db_md5 <- file_md5(s$db)

  res <- run_inbox(s, now = now)
  expect_true(res$ran)
  expect_identical(length(list.files(s$backup_dir)), 0L)
  expect_true(is.na(res$backup_path))
  expect_identical(file_md5(s$db), db_md5)
  expect_true(file.exists(status_note_path(s$report_dir)))
  expect_true(file.exists(file.path(s$report_dir, ".imports.state")))
  expect_false(file.exists(inbox_report_path(s$report_dir, now)))
  # the failed file and its folder stay
  expect_true(file.exists(file.path(d, basename(inbox_corrupt_file()))))
})

test_that("inbox_run(): the backup is taken before any write and is a verified copy of the pre-run DB", {
  s <- inbox_setup()
  now <- Sys.time()
  make_inbox_folder(s$input_dir, "input2026-10-18 0900 a", inbox_proj_a_files(), now = now)
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
  make_inbox_folder(s$input_dir, "input2026-10-18 0900 a", inbox_proj_a_files(), now = now)

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
  d <- make_inbox_folder(s$input_dir, "input2026-10-18 0900 a", inbox_proj_a_files(), now = now)
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

  # reported as a Problem in the day's note and the status note
  day <- read_report(s$report_dir, now)
  expect_true(any(grepl("Nothing imported today.", md_section(day, "Imported today"), fixed = TRUE)))
  expect_true(any(grepl("backup", md_section(day, "Problems"), ignore.case = TRUE)))
  expect_true(any(grepl("backup", md_section(read_status_note(s$report_dir), "Problems"),
                        ignore.case = TRUE)))
  # the failed run must not record the inbox as handled
  expect_identical(inbox_check(s$input_dir, s$report_dir, now = now, db = s$db), "run")
})

test_that("inbox_run(): folders are imported oldest name first, one ingest_dir() call each", {
  s <- inbox_setup()
  now <- Sys.time()
  # created newest-name-first, with mtimes in the opposite order to the names
  make_inbox_folder(s$input_dir, "input2026-10-18 1000 c", inbox_fixture("crosstab", "ES2600185_0_XTAB.csv"),
                    age_min = 300, now = now)
  make_inbox_folder(s$input_dir, "input2026-10-18 0900 b", inbox_rain_files(), age_min = 200, now = now)
  make_inbox_folder(s$input_dir, "input2026-10-17 2300 a", inbox_proj_a_files(), age_min = 100, now = now)

  real_ingest_dir <- ingest_dir
  calls <- character(0)
  testthat::local_mocked_bindings(ingest_dir = function(path, ...) {
    calls <<- c(calls, basename(path))
    real_ingest_dir(path, ...)
  })
  res <- run_inbox(s, now = now)
  want <- c("input2026-10-17 2300 a", "input2026-10-18 0900 b", "input2026-10-18 1000 c")
  expect_identical(calls, want)
  expect_identical(res$folders_processed, want)
})

test_that("inbox_run(): one folder failing does not stop the next; the failure is recorded", {
  s <- inbox_setup()
  now <- Sys.time()
  make_inbox_folder(s$input_dir, "input2026-10-18 0800 boom", inbox_rain_files(), now = now)
  make_inbox_folder(s$input_dir, "input2026-10-18 0830 corrupt", inbox_corrupt_file(), now = now)
  make_inbox_folder(s$input_dir, "input2026-10-18 0900 good", inbox_proj_a_files(), now = now)

  real_ingest_dir <- ingest_dir
  testthat::local_mocked_bindings(ingest_dir = function(path, ...) {
    if (grepl("boom", basename(path))) stop("simulated folder failure XYZZY")
    real_ingest_dir(path, ...)
  })
  res <- run_inbox(s, now = now)

  expect_identical(res$folders_processed,
                   c("input2026-10-18 0800 boom", "input2026-10-18 0830 corrupt", "input2026-10-18 0900 good"))
  boom <- res$folders[["input2026-10-18 0800 boom"]]
  expect_true(isTRUE(boom$failed))
  expect_match(boom$error, "XYZZY")
  good <- res$folders[["input2026-10-18 0900 good"]]
  expect_false(isTRUE(good$failed))
  expect_gte(good$events_committed, 1)
  expect_true("PROJ_A.ESDAT_XX1234567_0.Chemistry2e.CSV" %in% ingest_file_rows(s$db)$filename)
  # the corrupt file failed inside ingest_dir: recorded as a file left behind
  expect_true(basename(inbox_corrupt_file()) %in% res$folders[["input2026-10-18 0830 corrupt"]]$files_left)

  day <- read_report(s$report_dir, now)
  expect_true(any(grepl("XYZZY", md_section(day, "Problems"), fixed = TRUE)))
})

test_that("inbox_run(): archived files are removed, emptied folders removed, unfinished folders kept", {
  s <- inbox_setup()
  now <- Sys.time()
  make_inbox_folder(s$input_dir, "input2026-10-18 0900 done", inbox_proj_a_files(), now = now)
  mixed <- make_inbox_folder(s$input_dir, "input2026-10-18 0930 mixed",
                             c(inbox_rain_files(), inbox_corrupt_file(), inbox_fixture("esdat", "random.csv")),
                             now = now)
  res <- run_inbox(s, now = now)

  expect_false(dir.exists(file.path(s$input_dir, "input2026-10-18 0900 done")))
  expect_true(dir.exists(mixed))
  states <- ingest_file_rows(s$db)
  for (fn in basename(inbox_rain_files())) {
    expect_identical(states$state[match(fn, states$filename)], "archived")
    expect_false(file.exists(file.path(mixed, fn)), info = fn)
  }
  expect_true(file.exists(file.path(mixed, basename(inbox_corrupt_file()))))
  expect_true(file.exists(file.path(mixed, "random.csv")))
  expect_setequal(res$folders[["input2026-10-18 0930 mixed"]]$files_left,
                  c(basename(inbox_corrupt_file()), "random.csv"))
  expect_length(res$folders[["input2026-10-18 0900 done"]]$files_left, 0)

  # the unfinished folder is listed as waiting, naming its files and their state
  waiting <- md_section(read_status_note(s$report_dir), "Waiting")
  expect_true(any(grepl("0930 mixed", waiting, fixed = TRUE)))
  corrupt_line <- waiting[grepl(basename(inbox_corrupt_file()), waiting, fixed = TRUE)]
  expect_gt(length(corrupt_line), 0)
  expect_true(any(grepl("failed", corrupt_line)))
  random_line <- waiting[grepl("random.csv", waiting, fixed = TRUE)]
  expect_true(any(grepl("quarantined", random_line)))
})

test_that("inbox_run(): a live lock makes a second run exit immediately, writing nothing", {
  s <- inbox_setup()
  now <- Sys.time()
  make_inbox_folder(s$input_dir, "input2026-10-18 0900 a", inbox_proj_a_files(), now = now)
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
  make_inbox_folder(s$input_dir, "input2026-10-18 0900 a", inbox_proj_a_files(), now = now)
  write_inbox_lock(s$db, dead_pid(), now - 5 * 60)

  res <- run_inbox(s, now = now)
  expect_true(res$ran)
  expect_true(isTRUE(res$stale_lock))
  expect_identical(res$folders_processed, "input2026-10-18 0900 a")
  expect_false(file.exists(inbox_lock_path(s$db)))
  expect_true(any(grepl("stale", md_section(read_report(s$report_dir, now), "Problems"), ignore.case = TRUE)))
  expect_true(any(grepl("stale", md_section(read_status_note(s$report_dir), "Problems"), ignore.case = TRUE)))
})

test_that("inbox_run(): a lock older than 2 hours is stale even if its PID is alive", {
  s <- inbox_setup()
  now <- Sys.time()
  make_inbox_folder(s$input_dir, "input2026-10-18 0900 a", inbox_proj_a_files(), now = now)
  write_inbox_lock(s$db, live_child_pid(), now - 3 * 3600)

  res <- run_inbox(s, now = now)
  expect_true(res$ran)
  expect_true(isTRUE(res$stale_lock))
  expect_identical(res$folders_processed, "input2026-10-18 0900 a")
})

test_that("inbox_run(): appends one JSON line per run with the documented fields", {
  s <- inbox_setup()
  now <- Sys.time()
  make_inbox_folder(s$input_dir, "input2026-10-18 0900 a", inbox_proj_a_files(), now = now)
  res <- run_inbox(s, now = now)
  log <- read_inbox_log(s$report_dir)
  expect_length(log, 1)
  l <- log[[1]]
  for (k in c("started_at", "ended_at", "folders_seen", "folders_settled",
              "folders_processed", "folders", "backup_path", "errors")) {
    expect_true(k %in% names(l), info = k)
  }
  expect_identical(unlist(l$folders_processed), "input2026-10-18 0900 a")
  f <- l$folders[["input2026-10-18 0900 a"]]
  for (k in c("events_committed", "rows_new", "rows_already_present", "rows_superseded",
              "review_items_opened", "failed", "files_left")) {
    expect_true(k %in% names(f), info = k)
  }
  expect_identical(as.integer(f$rows_new), as.integer(res$folders[["input2026-10-18 0900 a"]]$rows_new))
  expect_gt(as.integer(f$rows_new), 0)
  expect_identical(l$backup_path, res$backup_path)

  # a second real run appends rather than rewrites; a 'none' call appends nothing
  make_inbox_folder(s$input_dir, "input2026-10-18 1000 b", inbox_rain_files(), now = now)
  run_inbox(s, now = now)
  run_inbox(s, now = now)
  expect_length(read_inbox_log(s$report_dir), 2)
})

test_that("inbox_run(dry_run = TRUE): no backup, no DB write, no removal, no state; DRY RUN banner", {
  s <- inbox_setup()
  now <- Sys.time()
  d <- make_inbox_folder(s$input_dir, "input2026-10-18 0900 a", inbox_proj_a_files(), now = now)
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
  notes <- c(if (file.exists(inbox_report_path(s$report_dir, now))) read_report(s$report_dir, now),
             if (file.exists(status_note_path(s$report_dir))) read_status_note(s$report_dir))
  expect_gt(length(notes), 0)
  expect_true(any(grepl("DRY RUN", notes, fixed = TRUE)))

  real <- run_inbox(s, now = now)
  expect_true(real$ran)
  expect_identical(real$folders_processed, "input2026-10-18 0900 a")
})

test_that("inbox_run(): a DB change alone refreshes the status note read-only; a resolved item disappears", {
  s <- inbox_setup()
  now <- Sys.time()
  make_inbox_folder(s$input_dir, "input2026-10-18 0900 a", inbox_rain_files(), now = now)
  run_inbox(s, now = now)
  nr <- md_section(read_status_note(s$report_dir), "Needs review")
  expect_true(any(grepl("ES2617126", nr, fixed = TRUE)))
  day_before <- tree_snapshot(s$report_dir)[paste0(sydney_date(now), "-imports.md")]
  log_n <- length(read_inbox_log(s$report_dir))
  backups <- list.files(s$backup_dir)
  Sys.sleep(1.1)

  # resolve every ES2617126 item outside an import (as a migration would)
  con <- seed_con(s$db)
  DBI::dbExecute(con, "UPDATE review_queue SET status = 'resolved' WHERE work_order = 'ES2617126'")
  DBI::dbDisconnect(con, shutdown = TRUE)
  db_md5 <- file_md5(s$db)
  expect_identical(inbox_check(s$input_dir, s$report_dir, now = now, db = s$db), "status")

  res <- run_inbox(s, now = now + 60)
  expect_identical(res$action, "status")
  expect_false(res$ran)
  nr2 <- md_section(read_status_note(s$report_dir), "Needs review")
  expect_false(any(grepl("ES2617126", nr2, fixed = TRUE)))
  expect_identical(file_md5(s$db), db_md5)                 # read-only
  expect_identical(list.files(s$backup_dir), backups)       # no backup
  expect_identical(tree_snapshot(s$report_dir)[paste0(sydney_date(now), "-imports.md")], day_before)
  expect_length(read_inbox_log(s$report_dir), log_n)        # no import logged
  # the refresh records the DB stat, so the next check is quiet again
  expect_identical(inbox_check(s$input_dir, s$report_dir, now = now + 120, db = s$db), "none")
})

test_that("inbox_run(): the status note persists unchanged across days with no activity", {
  s <- inbox_setup()
  now <- Sys.time()
  make_inbox_folder(s$input_dir, "input2026-10-18 0900 a", inbox_rain_files(), now = now)
  run_inbox(s, now = now)
  before <- tree_snapshot(s$report_dir)
  for (k in 1:3) {
    r <- run_inbox(s, now = now + k * 86400)
    expect_identical(r$action, "none")
  }
  expect_identical(tree_snapshot(s$report_dir), before)
})

# ---- section 2: import_report() (the dated note) ------------------------------

test_that("import_report(): the dated note is named for the Sydney date of now; header and footer use Sydney time", {
  s <- inbox_setup()
  # 14:30 UTC on 18 Oct is 01:30 AEDT on 19 Oct in Sydney
  now <- as.POSIXct("2026-10-18 14:30:00", tz = "UTC")
  # a problem (stale lock) makes this a day that gets a dated note
  write_inbox_lock(s$db, dead_pid(), now - 5 * 60)
  run_inbox(s, now = now)

  path <- file.path(s$report_dir, "2026-10-19-imports.md")
  expect_true(file.exists(path))
  expect_false(file.exists(file.path(s$report_dir, "2026-10-18-imports.md")))
  l <- readLines(path, warn = FALSE, encoding = "UTF-8")
  l <- l[nzchar(trimws(l))]
  expect_identical(l[[1]], "*Imports · 01:30 · 0 folder(s) imported today, 0 review item(s) open*")
  expect_identical(l[[length(l)]], "*Last run 01:30; next within the hour. Log: .imports.log*")
  expect_true(any(grepl("Nothing imported today.", md_section(l, "Imported today"), fixed = TRUE)))
})

test_that("import_report(): Imported today groups work orders by site with counts and source folder links; no Needs review/Waiting", {
  s <- inbox_setup()
  now <- Sys.time()
  make_inbox_folder(s$input_dir, "input2026-10-18 0900 PROJ_A", inbox_proj_a_files(), now = now)
  make_inbox_folder(s$input_dir, "input2026-10-18 0930 rain", inbox_rain_files(), now = now)
  res <- run_inbox(s, now = now)

  l <- read_report(s$report_dir, now)
  nonblank <- l[nzchar(trimws(l))]
  expect_match(nonblank[[1]], "^\\*Imports · \\d{2}:\\d{2} · 2 folder\\(s\\) imported today, \\d+ review item\\(s\\) open\\*$")
  sec <- md_section(l, "Imported today")
  expect_gt(length(sec), 0)
  site_idx <- grep("^(#+\\s*|\\*\\*)?(Blaxland|Katoomba|Other)\\b", sec, ignore.case = TRUE)
  site_of <- function(i) {
    prev <- site_idx[site_idx < i]
    if (!length(prev)) return(NA_character_)
    tolower(regmatches(sec[[max(prev)]], regexpr("(?i)blaxland|katoomba|other", sec[[max(prev)]], perl = TRUE)))
  }
  a <- grep("XX1234567", sec, fixed = TRUE)
  b <- grep("ES2617126", sec, fixed = TRUE)
  expect_length(a, 1)
  expect_length(b, 1)
  expect_identical(site_of(a), "blaxland")
  expect_identical(site_of(b), "other")

  la <- sec[[a]]
  expect_match(la, "ALS")
  expect_match(la, "input2026-10-18 0900 PROJ_A", fixed = TRUE)
  expect_match(la, "file:///", fixed = TRUE)
  rows_a <- res$folders[["input2026-10-18 0900 PROJ_A"]]$rows_new
  expect_match(la, paste0("\\b", rows_a, " analys"))
  expect_match(la, "\\b\\d+ samples?")
  expect_match(sec[[b]], paste0("\\b", res$folders[["input2026-10-18 0930 rain"]]$rows_new, " analys"))

  expect_length(md_section(l, "Needs review"), 0)
  expect_length(md_section(l, "Waiting"), 0)
  expect_false(any(grepl("^#+\\s*Problems", l)))
})

test_that("import_report(): rewriting with nothing changed gives an identical file", {
  s <- inbox_setup()
  now <- Sys.time()
  make_inbox_folder(s$input_dir, "input2026-10-18 0900 PROJ_A", inbox_proj_a_files(), now = now)
  run_inbox(s, now = now)
  p <- quiet_run(import_report(db = s$db, report_dir = s$report_dir, now = now))
  first <- readLines(inbox_report_path(s$report_dir, now))
  quiet_run(import_report(db = s$db, report_dir = s$report_dir, now = now))
  expect_identical(readLines(inbox_report_path(s$report_dir, now)), first)
})

# ---- section 2a: import_status() (the standing note) --------------------------

review_fixture <- function(now) {
  h <- function(x) now - x * 3600
  data.frame(
    uuid = sprintf("rq-%02d", 1:11),
    created_at = as.POSIXct(c(h(200), h(150), h(2), h(3), h(30), h(1), h(400),
                              h(100), h(90), h(80), h(1)), origin = "1970-01-01", tz = "UTC"),
    kind = c("date_conflict", "date_conflict", "work_order_reingest", "unknown_feature",
             "unknown_feature", "unknown_feature", "unknown_feature",
             "self_precedence_note", "self_precedence_note", "self_precedence_note",
             "unknown_feature"),
    subkind = c("a77", "a77", "blocked", NA, NA, NA, NA, NA, NA, NA, NA),
    work_order = c("2400-1111-01", "2400-1111-01", "ES1111111", "ES2222222", "ES2222222",
                   "ES3333333", "ES4444444", "ES5555551", "ES5555552", "ES5555553", "ES9999999"),
    status = c(rep("open", 10), "resolved"),
    stringsAsFactors = FALSE
  )
}

test_that("import_status(): header line counts open items and waiting folders", {
  s <- inbox_setup()
  now <- as.POSIXct("2026-10-18 14:30:00", tz = "UTC")
  insert_review_items(s$db, review_fixture(now))
  make_inbox_folder(s$input_dir, "input2026-10-19 0125 arriving", inbox_proj_a_files(), age_min = 1, now = now)
  quiet_run(import_status(db = s$db, input_dir = s$input_dir, report_dir = s$report_dir, now = now))
  l <- read_status_note(s$report_dir)
  l <- l[nzchar(trimws(l))]
  expect_identical(l[[1]], "*Import status · updated 2026-10-19 01:30 · 10 review item(s) open, 1 folder(s) waiting*")
})

test_that("import_status(): Needs review grouped by kind then work order, counts, oldest date, plain-language line, **new**, notes collapsed last", {
  s <- inbox_setup()
  now <- as.POSIXct("2026-10-18 14:30:00", tz = "UTC")
  insert_review_items(s$db, review_fixture(now))
  quiet_run(import_status(db = s$db, input_dir = s$input_dir, report_dir = s$report_dir, now = now))
  sec <- md_section(read_status_note(s$report_dir), "Needs review")
  sec <- sec[nzchar(trimws(sec))]
  expect_gt(length(sec), 0)

  # date_conflict/a77: one group for the work order, count 2, oldest date, meaning
  dc <- sec[grepl("2400-1111-01", sec, fixed = TRUE)]
  expect_length(dc, 1)
  expect_match(dc, "\\b2\\b")
  oldest <- now - 200 * 3600
  expect_true(grepl(format(oldest, "%Y-%m-%d", tz = "Australia/Sydney"), dc, fixed = TRUE) ||
                grepl(format(oldest, "%d %b", tz = "Australia/Sydney"), dc, fixed = TRUE))
  expect_false(grepl("**new**", dc, fixed = TRUE))
  expect_true(any(grepl("dust block dates disagree; held until released", sec, fixed = TRUE)))
  expect_true(any(grepl("lab file for a work order already in the database; held", sec, fixed = TRUE)))
  expect_true(any(grepl("sampling point not recognised", sec, fixed = TRUE)))

  # opened within the last 24 h -> **new**; 30 h / 400 h old -> not new
  expect_match(sec[grepl("ES1111111", sec, fixed = TRUE)], "**new**", fixed = TRUE)
  expect_match(sec[grepl("ES3333333", sec, fixed = TRUE)], "**new**", fixed = TRUE)
  expect_false(grepl("**new**", sec[grepl("ES4444444", sec, fixed = TRUE)], fixed = TRUE))
  es2 <- sec[grepl("ES2222222", sec, fixed = TRUE)]
  expect_length(es2, 1)
  expect_match(es2, "\\b2\\b")

  # grouped by kind: each kind's work orders sit together
  uf <- which(grepl("ES2222222|ES3333333|ES4444444", sec))
  expect_length(uf, 3)
  between <- sec[min(uf):max(uf)]
  expect_false(any(grepl("2400-1111-01|ES1111111", between)))

  # resolved items are not listed
  expect_false(any(grepl("ES9999999", sec, fixed = TRUE)))

  # self_precedence_note: one count line, last, work orders not itemised
  notes <- grep("precedence", sec, ignore.case = TRUE)
  expect_length(notes, 1)
  expect_identical(notes, length(sec))
  expect_match(sec[[notes]], "\\b3\\b")
  expect_false(any(grepl("ES555555", sec, fixed = TRUE)))
})

test_that("import_status(): Recent imports lists the last 14 days' work orders, newest first, linking the dated note", {
  s <- inbox_setup()
  now <- Sys.time()
  make_inbox_folder(s$input_dir, "input2026-10-18 0900 PROJ_A", inbox_proj_a_files(), now = now)
  run_inbox(s, now = now)
  Sys.sleep(1.1)
  make_inbox_folder(s$input_dir, "input2026-10-18 1000 rain", inbox_rain_files(), now = now)
  run_inbox(s, now = now)

  sec <- md_section(read_status_note(s$report_dir), "Recent imports")
  a <- grep("XX1234567", sec, fixed = TRUE)
  b <- grep("ES2617126", sec, fixed = TRUE)
  expect_length(a, 1)
  expect_length(b, 1)
  link <- paste0("[[", sydney_date(now), "-imports]]")
  expect_match(sec[[a]], link, fixed = TRUE)
  expect_match(sec[[b]], link, fixed = TRUE)
  expect_lt(b, a)   # newest first
})

test_that("import_status(): Problems shows only the most recent run's problems, omitted when none", {
  s <- inbox_setup()
  now <- Sys.time()
  write_inbox_lock(s$db, dead_pid(), now - 5 * 60)
  run_inbox(s, now = now)
  expect_true(any(grepl("stale", md_section(read_status_note(s$report_dir), "Problems"),
                        ignore.case = TRUE)))

  make_inbox_folder(s$input_dir, "input2026-10-18 0900 PROJ_A", inbox_proj_a_files(), now = now)
  run_inbox(s, now = now)
  expect_false(any(grepl("^#+\\s*Problems", read_status_note(s$report_dir))))
})

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

test_that("import_status(): rewriting with nothing changed gives an identical file", {
  s <- inbox_setup()
  now <- as.POSIXct("2026-10-18 14:30:00", tz = "UTC")
  insert_review_items(s$db, review_fixture(now))
  quiet_run(import_status(db = s$db, input_dir = s$input_dir, report_dir = s$report_dir, now = now))
  first <- read_status_note(s$report_dir)
  quiet_run(import_status(db = s$db, input_dir = s$input_dir, report_dir = s$report_dir, now = now))
  expect_identical(read_status_note(s$report_dir), first)
})
