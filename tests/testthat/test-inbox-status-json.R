# Stage 2 of the layer move: status.json carries everything a renderer needs,
# because the core writes no markdown. The additions (spec A5): timezone,
# waiting[].path / last_written / unfinished, loose, dry_run_plan, flag_checks,
# site_names; recent_imports[].site is the log's value verbatim.
#
# Synthetic: folders batch-1, batch-2, misc; site N. The legacy recogniser the
# setup file pins is cleared (bt_setup()), so every subfolder is a batch.

sj_raw <- function(s, f = "status.json") {
  paste(readLines(file.path(s$report_dir, f), warn = FALSE), collapse = "\n")
}

sj_utc <- function(x) format(x, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")

test_that("timezone is the configured zone, on a run and on a status refresh", {
  s <- bt_setup()
  withr::local_options(sampletidy.timezone = "Pacific/Auckland")
  now <- bt_now()
  run_inbox(s, now = now)
  expect_identical(read_status_json(s$report_dir)$timezone, "Pacific/Auckland")
  unlink(file.path(s$report_dir, "status.json"))
  quiet_run(import_status(db = s$db, input_dir = s$input_dir, report_dir = s$report_dir, now = now))
  expect_identical(read_status_json(s$report_dir)$timezone, "Pacific/Auckland")
})

test_that("an arriving entry has path and last_written (UTC ISO of the newest file); an empty folder has last_written null", {
  s <- bt_setup()
  now <- bt_now()
  batch <- inbox_batches(settle_minutes = 10)
  d <- bt_folder(s, "batch-1", now, age_sec = 600, files = inbox_rain_files())
  fs <- list.files(d, full.names = TRUE)
  newest <- now - 120
  Sys.setFileTime(fs[[1]], newest)
  Sys.setFileTime(fs[-1], now - 300)
  dir.create(file.path(s$input_dir, "batch-2"))
  testthat::local_mocked_bindings(ingest_dir = bt_ingest())

  run_inbox(s, now = now, batch = batch)
  e <- status_waiting(s$report_dir, "batch-1")
  expect_identical(e$status, "arriving")
  expect_identical(e$path, file.path(s$input_dir, "batch-1"))
  expect_identical(e$last_written, sj_utc(newest))
  empty <- status_waiting(s$report_dir, "batch-2")
  expect_identical(empty$status, "arriving")
  expect_identical(empty$path, file.path(s$input_dir, "batch-2"))
  expect_true("last_written" %in% names(empty))
  expect_null(empty$last_written)
  expect_match(sj_raw(s), "\"last_written\": null", fixed = TRUE)
})

test_that("a left entry with unfinished data has unfinished TRUE and other_files; an all-done entry under a filing policy has unfinished FALSE, status left, and is counted", {
  s <- bt_setup()
  now <- bt_now()
  # an unfinished data file (corrupt csv) plus a non-data file
  bt_folder(s, "batch-1", now, files = c(inbox_rain_files(), inbox_corrupt_file()),
            extra = "photo.png")
  res <- run_inbox(s, now = now, batch = inbox_batches())
  expect_identical(res$folders_processed, "batch-1")
  e <- status_waiting(s$report_dir, "batch-1")
  expect_identical(e$status, "left")
  expect_true(e$unfinished)
  expect_identical(e$other_files, 1L)
  expect_identical(vapply(e$files, function(f) f$file, ""), basename(inbox_corrupt_file()))

  # a folder holding only a non-data file, with a filing policy: not "done"
  s2 <- bt_setup()
  bt_folder(s2, "batch-2", now, files = character(0), extra = "photo.jpg")
  quiet_run(import_status(db = s2$db, input_dir = s2$input_dir, report_dir = s2$report_dir,
                          now = now, batch = inbox_batches(leftovers = "filed-mail")))
  e2 <- status_waiting(s2$report_dir, "batch-2")
  expect_identical(e2$status, "left")
  expect_false(e2$unfinished)
  expect_identical(as.integer(read_status_json(s2$report_dir)$folders_waiting), 1L)
})

test_that("loose is [{file, path}], sorted, without hidden files; [] when none; a single entry is still an array", {
  s <- bt_setup()
  now <- bt_now()
  for (f in c("b.csv", "a.csv", ".hidden.csv")) writeLines("x", file.path(s$input_dir, f))
  dir.create(file.path(s$input_dir, "batch-1"))
  run_inbox(s, now = now, batch = inbox_batches())
  loose <- read_status_json(s$report_dir)$loose
  expect_identical(vapply(loose, function(l) l$file, ""), c("a.csv", "b.csv"))
  expect_identical(vapply(loose, function(l) l$path, ""), file.path(s$input_dir, c("a.csv", "b.csv")))

  s2 <- bt_setup()
  run_inbox(s2, now = now, batch = inbox_batches())
  expect_length(read_status_json(s2$report_dir)$loose, 0)
  expect_match(sj_raw(s2), "\"loose\": []", fixed = TRUE)

  s3 <- bt_setup()
  writeLines("x", file.path(s3$input_dir, "only.csv"))
  run_inbox(s3, now = now, batch = inbox_batches())
  expect_match(sj_raw(s3), "\"loose\":\\s*\\[\\s*\\{")
  expect_length(read_status_json(s3$report_dir)$loose, 1)
})

test_that("flag_checks is absent with checks = NULL; otherwise it follows .flags_checks, starts with overdue, and carries .flags_meanings", {
  s <- fl_status_setup()
  fl_status(s, checks = NULL)
  expect_false("flag_checks" %in% names(fl_status_json(s)))

  s2 <- fl_status_setup()
  fl_status(s2, checks = fl_checks())
  fc <- fl_status_json(s2)$flag_checks
  got <- vapply(fc, function(x) x$check, "")
  expect_identical(got, as.character(sampleTidy:::.flags_checks))
  expect_identical(got[[1]], "overdue")
  for (x in fc) {
    want <- unname(sampleTidy:::.flags_meanings[x$check])
    if (is.na(want)) expect_null(x$meaning, info = x$check)
    else expect_identical(x$meaning, want, info = x$check)
  }
})

test_that("site_names is the checks' map as an object, or {} when it has none; absent without checks", {
  s <- fl_status_setup()
  fl_status(s, checks = sx_checks(site_names = c(N = "Northvale", M = "Midvale")))
  expect_identical(fl_status_json(s)$site_names, list(N = "Northvale", M = "Midvale"))

  s2 <- fl_status_setup()
  fl_status(s2, checks = sx_checks(site_names = NULL))
  expect_match(sj_raw(s2), "\"site_names\": {}", fixed = TRUE)

  s3 <- fl_status_setup()
  fl_status(s3, checks = NULL)
  expect_false("site_names" %in% names(fl_status_json(s3)))
})

test_that("dry_run_plan is null in a run and in a status refresh; in a dry run would_import is the folders processed, still an array at length 1", {
  s <- bt_setup()
  now <- bt_now()
  bt_folder(s, "batch-1", now, files = inbox_rain_files())
  testthat::local_mocked_bindings(ingest_dir = bt_ingest())
  run_inbox(s, now = now, batch = inbox_batches())
  js <- read_status_json(s$report_dir)
  expect_true("dry_run_plan" %in% names(js))
  expect_null(js$dry_run_plan)
  expect_match(sj_raw(s), "\"dry_run_plan\": null", fixed = TRUE)

  quiet_run(import_status(db = s$db, input_dir = s$input_dir, report_dir = s$report_dir, now = now))
  expect_null(read_status_json(s$report_dir)$dry_run_plan)

  s2 <- bt_setup()
  bt_folder(s2, "batch-1", now, files = inbox_rain_files())
  res <- run_inbox(s2, now = now, batch = inbox_batches(), dry_run = TRUE)
  plan <- read_status_json(s2$report_dir)$dry_run_plan
  expect_identical(unlist(plan$would_import), res$folders_processed)
  expect_identical(unlist(plan$would_import), "batch-1")
  expect_length(plan$would_file, 0)
  expect_match(sj_raw(s2), "\"would_import\":\\s*\\[")
})

test_that("recent_imports site is the log's value: the code N, not a label", {
  now <- bt_now()
  s <- bt_setup()
  bt_folder(s, "batch-1", now, files = inbox_rain_files())
  testthat::local_mocked_bindings(ingest_dir = bt_ingest(wo = "ES9990001", site = "N"))
  run_inbox(s, now = now, batch = inbox_batches())
  recent <- read_status_json(s$report_dir)$recent_imports
  expect_length(recent, 1)
  expect_identical(recent[[1]]$work_order, "ES9990001")
  expect_identical(recent[[1]]$site, "N")
})

test_that("recent_imports site is a JSON null when the work order has no site (dangling feature aliases)", {
  s <- bt_setup()
  now <- bt_now()
  bt_folder(s, "batch-1", now, files = inbox_rain_files())
  run_inbox(s, now = now, batch = inbox_batches())
  expect_match(sj_raw(s), "\"site\": null", fixed = TRUE)
  recent <- read_status_json(s$report_dir)$recent_imports
  expect_identical(recent[[1]]$work_order, "ES2664217")
  expect_true("site" %in% names(recent[[1]]))
  expect_null(recent[[1]]$site)
})

test_that("events.jsonl and the run's return value hold the site code N, not a label", {
  s <- bt_setup()
  now <- bt_now()
  bt_folder(s, "batch-1", now, files = inbox_rain_files())
  testthat::local_mocked_bindings(ingest_dir = bt_ingest(wo = "ES9990001", site = "N"))
  res <- run_inbox(s, now = now, batch = inbox_batches())
  expect_identical(res$folders[[1]]$work_orders[[1]]$site, "N")
  line <- read_inbox_log(s$report_dir)[[1]]
  expect_identical(line$folders[[1]]$work_orders[[1]]$site, "N")
  ev <- jsonlite::fromJSON(utils::tail(readLines(file.path(s$report_dir, "events.jsonl")), 1),
                           simplifyVector = FALSE)
  expect_identical(ev$folders[[1]]$work_orders[[1]]$site, "N")
})

test_that("the core writes no markdown: after a run, a status refresh and a dry run with no hooks, the report dir holds no *.md", {
  s <- bt_setup()
  now <- bt_now()
  clear_hooks()
  withr::defer(clear_hooks())
  bt_folder(s, "batch-1", now, files = inbox_rain_files())
  testthat::local_mocked_bindings(ingest_dir = bt_ingest())
  run_inbox(s, now = now, batch = inbox_batches())
  expect_length(report_md_files(s$report_dir), 0)

  Sys.setFileTime(s$db, Sys.time() + 120)
  r <- run_inbox(s, now = now + 3600, batch = inbox_batches())
  expect_identical(r$action, "status")
  expect_length(report_md_files(s$report_dir), 0)

  s2 <- bt_setup()
  bt_folder(s2, "batch-1", now, files = inbox_rain_files())
  run_inbox(s2, now = now, batch = inbox_batches(), dry_run = TRUE)
  expect_length(report_md_files(s2$report_dir), 0)
})

test_that("status.json and .import-status.json are identical", {
  s <- bt_setup()
  now <- bt_now()
  bt_folder(s, "batch-1", now, files = inbox_rain_files())
  writeLines("x", file.path(s$input_dir, "loose.csv"))
  testthat::local_mocked_bindings(ingest_dir = bt_ingest())
  run_inbox(s, now = now, batch = inbox_batches())
  a <- file.path(s$report_dir, "status.json")
  b <- file.path(s$report_dir, ".import-status.json")
  expect_identical(readBin(a, "raw", file.size(a)), readBin(b, "raw", file.size(b)))
})
