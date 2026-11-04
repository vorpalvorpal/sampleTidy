# Stage 2 of the layer move: the generic inbox. inbox_batches() says which
# top-level folders of the input directory are batches, how long a batch must
# be quiet before it is settled, and what happens to the files an import leaves
# behind (left in place, or filed under a subfolder of the archive).
#
# Synthetic: folders batch-1, batch-2, misc and .hidden; leftover subfolder
# filed-mail. These tests clear the legacy recogniser that the setup file pins
# for the older suites (bt_setup()), so they run on the package defaults unless
# they pass `batch`.

# Forget that the inbox was handled, so that the next call runs again.
bt_forget <- function(s) unlink(file.path(s$report_dir, ".imports.state"))

np <- function(p) normalizePath(p, mustWork = FALSE)

# Folders for the "which folders are seen" tests: three batches and the things
# that are never batches.
bt_tree <- function(s, now, age_sec = 3600) {
  for (nm in c("batch-1", "batch-2", "misc", ".hidden")) {
    bt_folder(s, nm, now, age_sec = age_sec, files = inbox_rain_files())
  }
  writeLines("loose", file.path(s$input_dir, "loose.csv"))
}

# ---- the constructor ---------------------------------------------------------------------

test_that("inbox_batches() has the class and the defaults pattern NULL, settle_minutes 0, leftovers NULL", {
  b <- inbox_batches()
  expect_s3_class(b, "sampletidy_inbox_batches")
  expect_identical(names(b), c("pattern", "settle_minutes", "leftovers"))
  expect_null(b$pattern)
  expect_identical(b$settle_minutes, 0)
  expect_null(b$leftovers)

  b2 <- inbox_batches("^batch-.+", settle_minutes = 5, leftovers = "filed-mail")
  expect_identical(b2$pattern, "^batch-.+")
  expect_identical(b2$settle_minutes, 5)
  expect_identical(b2$leftovers, "filed-mail")
})

test_that("inbox_batches() aborts with sampletidy_error on every invalid argument", {
  bad_pattern <- list(NA, NA_character_, "", c("a", "b"), "(", 1, character(0))
  for (x in bad_pattern) {
    expect_error(inbox_batches(pattern = x), class = "sampletidy_error",
                 info = paste("pattern:", deparse(x)))
  }
  bad_settle <- list(-1, NA, NA_real_, Inf, "10", c(1, 2), NULL)
  for (x in bad_settle) {
    expect_error(inbox_batches(settle_minutes = x), class = "sampletidy_error",
                 info = paste("settle_minutes:", deparse(x)))
  }
  bad_leftovers <- list("", "a/b", "a\\b", ".", "..", NA, NA_character_, c("a", "b"), 1)
  for (x in bad_leftovers) {
    expect_error(inbox_batches(leftovers = x), class = "sampletidy_error",
                 info = paste("leftovers:", deparse(x)))
  }
})

# ---- which folders are batches --------------------------------------------------------------

test_that("with the option unset, every non-hidden subfolder is seen; hidden folders and loose files are not; settled means every file is no newer than now", {
  s <- bt_setup()
  now <- bt_now()
  bt_folder(s, "batch-1", now, age_sec = 1, files = inbox_rain_files())      # now - 1s: settled
  bt_folder(s, "batch-2", now, age_sec = -60, files = inbox_rain_files())    # now + 60s: arriving
  bt_folder(s, "misc", now, age_sec = 3600, files = inbox_rain_files())
  bt_folder(s, ".hidden", now, age_sec = 3600, files = inbox_rain_files())
  writeLines("loose", file.path(s$input_dir, "loose.csv"))
  testthat::local_mocked_bindings(ingest_dir = bt_ingest())

  res <- run_inbox(s, now = now)
  expect_identical(res$folders_seen, c("batch-1", "batch-2", "misc"))
  expect_identical(res$folders_settled, c("batch-1", "misc"))
  expect_identical(res$folders_arriving, "batch-2")
  expect_false(".hidden" %in% res$folders_seen)
})

test_that("inbox_batches(\"^batch-.+\"): misc, a bare 'batch-' and the hidden folder are not seen", {
  s <- bt_setup()
  now <- bt_now()
  bt_tree(s, now)
  bt_folder(s, "batch-", now, files = inbox_rain_files())
  testthat::local_mocked_bindings(ingest_dir = bt_ingest())

  res <- run_inbox(s, now = now, batch = inbox_batches("^batch-.+"))
  expect_identical(res$folders_seen, c("batch-1", "batch-2"))
})

# ---- where the recogniser comes from ----------------------------------------------------------

test_that("the option is used when `batch` is missing, an explicit `batch` beats it, and anything that is not a recogniser aborts", {
  s <- bt_setup()
  now <- bt_now()
  bt_tree(s, now)
  testthat::local_mocked_bindings(ingest_dir = bt_ingest())

  withr::local_options(sampletidy.inbox_batches = inbox_batches("^misc$"))
  expect_identical(run_inbox(s, now = now)$folders_seen, "misc")

  # an explicit argument beats the option
  bt_forget(s)
  expect_identical(run_inbox(s, now = now + 120, batch = inbox_batches("^batch-1$"))$folders_seen,
                   "batch-1")

  # a bad option value, a bad argument, and import_status() too
  withr::local_options(sampletidy.inbox_batches = list(pattern = "^misc$"))
  expect_error(run_inbox(s, now = now + 240), class = "sampletidy_error")
  withr::local_options(sampletidy.inbox_batches = NULL)
  expect_error(run_inbox(s, now = now + 240, batch = "^misc$"), class = "sampletidy_error")
  expect_error(run_inbox(s, now = now + 240, batch = list(pattern = "^misc$")),
               class = "sampletidy_error")
  expect_error(quiet_run(import_status(db = s$db, input_dir = s$input_dir,
                                       report_dir = s$report_dir, now = now, batch = "^misc$")),
               class = "sampletidy_error")
})

test_that("SAMPLETIDY_INBOX_BATCHES makes st_config() abort: the key is list-valued", {
  withr::local_options(sampletidy.inbox_batches = NULL)
  withr::local_envvar(SAMPLETIDY_INBOX_BATCHES = "^batch-.+")
  expect_error(st_config("inbox_batches"), class = "sampletidy_error")
})

test_that("st_config(\"inbox_batches\") defaults to NULL and round-trips a recogniser", {
  withr::local_options(sampletidy.inbox_batches = NULL)
  withr::local_envvar(SAMPLETIDY_INBOX_BATCHES = NA)
  expect_null(st_config("inbox_batches"))
  b <- inbox_batches("^batch-.+", 2, "filed-mail")
  st_config("inbox_batches", b)
  expect_identical(st_config("inbox_batches"), b)
})

test_that("the test recogniser: unset at the top of a test, set by inbox_setup(), equal to inbox_batches(\"^batch-.+\", 10, \"filed-mail\")", {
  # (the older suites run on this)
  expect_null(getOption("sampletidy.inbox_batches"))
  expect_identical(test_batches(),
                   inbox_batches("^batch-.+", settle_minutes = 10, leftovers = "filed-mail"))
  inbox_setup()
  expect_identical(getOption("sampletidy.inbox_batches"), test_batches())
})

test_that("the older suites use the generic folder names: no legacy dated-input folders or underscore-mail subdirectory", {
  dir <- testthat::test_path()
  skip_if_not(dir.exists(dir) && length(list.files(dir, pattern = "^test-.*[.]R$")) > 50,
              "test sources not present")
  files <- list.files(dir, pattern = "[.]R$", full.names = TRUE)
  files <- files[basename(files) != "test-processed-dedupe.R"]
  # the patterns are assembled so that this file does not match itself
  legacy <- c(paste0("\"", "inp", "ut20"), paste0("'", "inp", "ut20"), paste0("_", "emails"))
  for (f in files) {
    txt <- readLines(f, warn = FALSE)
    for (pat in legacy) {
      expect_false(any(grepl(pat, txt, fixed = TRUE)), info = paste(basename(f), pat))
    }
  }
})

# ---- settling ---------------------------------------------------------------------------------

test_that("a batch settle of 10 with files 5 minutes old is arriving; settle_minutes = 1 settles it, in inbox_run and in import_status", {
  now <- bt_now()
  batch <- inbox_batches("^batch-.+", settle_minutes = 10)

  s <- bt_setup()
  bt_folder(s, "batch-1", now, age_sec = 300, files = inbox_rain_files())
  testthat::local_mocked_bindings(ingest_dir = bt_ingest())
  r1 <- run_inbox(s, now = now, batch = batch)
  expect_identical(r1$folders_arriving, "batch-1")
  expect_length(r1$folders_settled, 0)

  s2 <- bt_setup()
  bt_folder(s2, "batch-1", now, age_sec = 300, files = inbox_rain_files())
  r2 <- run_inbox(s2, now = now, batch = batch, settle_minutes = 1)
  expect_identical(r2$folders_settled, "batch-1")
  expect_length(r2$folders_arriving, 0)

  # the status refresh sees the same
  s3 <- bt_setup()
  bt_folder(s3, "batch-1", now, age_sec = 300, files = inbox_rain_files())
  quiet_run(import_status(db = s3$db, input_dir = s3$input_dir, report_dir = s3$report_dir,
                          now = now, batch = batch))
  expect_identical(status_waiting(s3$report_dir, "batch-1")$status, "arriving")
  quiet_run(import_status(db = s3$db, input_dir = s3$input_dir, report_dir = s3$report_dir,
                          now = now, batch = batch, settle_minutes = 1))
  expect_identical(status_waiting(s3$report_dir, "batch-1")$status, "left")
})

# ---- leftovers: leave in place -------------------------------------------------------------------

test_that("under the leave policy an import leaves the folder holding its non-data files; nothing is filed; a later run does not process it again; status.json lists it as done and does not count it", {
  s <- bt_setup()
  now <- bt_now()
  batch <- inbox_batches("^batch-.+")        # leftovers = NULL
  bt_folder(s, "batch-1", now, extra = "photo.jpg")

  res <- run_inbox(s, now = now, batch = batch)
  expect_identical(res$folders_processed, "batch-1")
  expect_identical(list.files(file.path(s$input_dir, "batch-1")), "photo.jpg")
  ff <- res$folders[["batch-1"]]$files_filed
  expect_true(is.na(ff$to))
  expect_length(ff$files, 0)
  # nothing was filed: no filed-mail, no folder named for the batch, under the archive
  arch <- list.files(s$archive_dir, recursive = TRUE, include.dirs = TRUE, all.files = TRUE)
  expect_false(any(grepl("filed-mail|batch-1", arch)))

  # a second run, after a new folder arrives, processes only the new folder
  bt_folder(s, "batch-2", now, files = inbox_rain_files())
  res2 <- run_inbox(s, now = now + 120, batch = batch)
  expect_identical(res2$folders_processed, "batch-2")
  expect_identical(list.files(file.path(s$input_dir, "batch-1")), "photo.jpg")

  js <- read_status_json(s$report_dir)
  e <- status_waiting(s$report_dir, "batch-1")
  expect_identical(e$status, "done")
  expect_false(e$unfinished)
  expect_identical(e$path, file.path(s$input_dir, "batch-1"))
  counted <- sum(vapply(js$waiting, function(w) !identical(w$status, "done"), logical(1)))
  expect_identical(as.integer(js$folders_waiting), as.integer(counted))
  expect_false("batch-1" %in% vapply(
    Filter(function(w) !identical(w$status, "done"), js$waiting), function(w) w$folder, ""))
})

# ---- leftovers: filing ------------------------------------------------------------------------------

test_that("leftovers = \"filed-mail\": the folder moves to <archive>/filed-mail/<name>, a second same-named folder to '<name> (2)', and the log records the destination", {
  s <- bt_setup()
  now <- bt_now()
  batch <- inbox_batches("^batch-.+", leftovers = "filed-mail")
  bt_folder(s, "batch-1", now, extra = "photo.jpg")

  res <- run_inbox(s, now = now, batch = batch)
  dest <- file.path(s$archive_dir, "filed-mail", "batch-1")
  expect_true(dir.exists(dest))
  expect_identical(list.files(dest), "photo.jpg")
  expect_false(dir.exists(file.path(s$input_dir, "batch-1")))
  expect_false(dir.exists(file.path(s$archive_dir, "mail")))   # only the configured name is used
  expect_identical(np(res$folders[["batch-1"]]$files_filed$to), np(dest))
  logged <- read_inbox_log(s$report_dir)[[1]]$folders[["batch-1"]]$files_filed
  expect_identical(np(logged$to), np(dest))
  expect_identical(as.character(unlist(logged$files)), "photo.jpg")

  # the same name again
  bt_folder(s, "batch-1", now, files = inbox_rain_files(), extra = "photo2.jpg")
  res2 <- run_inbox(s, now = now + 120, batch = batch)
  dest2 <- file.path(s$archive_dir, "filed-mail", "batch-1 (2)")
  expect_true(dir.exists(dest2))
  expect_identical(list.files(dest), "photo.jpg")                 # never overwritten
  expect_true("photo2.jpg" %in% list.files(dest2))
  expect_identical(np(res2$folders[["batch-1"]]$files_filed$to), np(dest2))
})

test_that("leftovers = \"filed-mail\": a dry run records the plan in status.json and moves nothing", {
  s <- bt_setup()
  now <- bt_now()
  batch <- inbox_batches("^batch-.+", leftovers = "filed-mail")
  d <- bt_folder(s, "batch-1", now, extra = "photo.jpg")
  n_files <- length(list.files(d))
  in_before <- suppressWarnings(tree_snapshot(s$input_dir))
  arch_before <- suppressWarnings(tree_snapshot(s$archive_dir))

  res <- run_inbox(s, now = now, batch = batch, dry_run = TRUE)
  expect_true(res$ran)
  plan <- read_status_json(s$report_dir)$dry_run_plan
  expect_length(plan$would_file, 1)
  expect_identical(plan$would_file[[1]]$folder, "batch-1")
  expect_identical(plan$would_file[[1]]$to, file.path(s$archive_dir, "filed-mail", "batch-1"))
  expect_identical(plan$would_file[[1]]$files, n_files)
  expect_identical(suppressWarnings(tree_snapshot(s$input_dir)), in_before)
  expect_identical(suppressWarnings(tree_snapshot(s$archive_dir)), arch_before)
})
