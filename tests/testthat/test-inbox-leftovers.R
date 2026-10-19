# Auto-import: filing an email folder's leftovers (PLAN-18 section 1 "After
# import", rule added 2026-10-19).
#
# A Power Automate folder also holds files no adapter will ever import: the
# email itself (`_email.eml`), signature images (`image001.png`, ...), and PDFs
# that were not retained as work-order siblings. The rule:
#
#   After a folder is processed, if every DATA file in it is done - no file
#   remains in state needs_review / failed / quarantined whose kind is
#   tabular or claimable (an adapter claims it, or it is csv/xls/xlsx/xml) -
#   MOVE every remaining file into <archive_dir>/_emails/<folder basename>/
#   and remove the now-empty input folder. Never delete a leftover; never
#   overwrite: an existing destination gets " (2)", " (3)", ... If any data
#   file is unfinished, move NOTHING. A folder with no data files at all is
#   all-done. dry_run moves nothing but says what would be filed.
#
# Seams pinned here (beyond test-inbox.R's):
#   * archive root = st_config("archive_dir") (inbox_setup() sets it via the
#     `sampletidy.archive_dir` option); destination
#     file.path(archive_dir, "_emails", <folder basename>[ " (n)"]).
#   * res$folders[[name]]$files_filed (and the same key in the .imports.log
#     line) is a list(to = <absolute destination folder>, files = <character
#     basenames moved>). When nothing was filed, `files` is empty.
#   * Waiting, for a kept folder: lists the unfinished data files (with
#     state) and NOT the leftovers by name; one line says
#     "<n> other file(s) ... filed ..." for the leftovers.
#   * DATA kinds (coordinator ruling 2026-10-19): anything an adapter claims,
#     plus extensions csv, tsv, txt, json, xml, xls, xlsx, xlsm, xlsb, zip. An
#     unclaimed one keeps the folder (unfiled, listed under Waiting).
#   * the dated <date>-imports.md has a "Filed" section: one entry per filed
#     folder naming the folder, each file, and a file:/// link to the
#     destination; a day whose only activity is filing still writes it.
#   * dry run: the status note carries a line "would file ..." naming the
#     folder.

# ---- local helpers (definitions only) ---------------------------------------

#' Write the usual non-data email debris into a fresh temp dir; returns paths.
make_leftovers <- function(env = parent.frame(),
                           names = c("_email.eml", "image001.png", "image002.jpg",
                                     "Cover letter.pdf")) {
  d <- withr::local_tempdir(.local_envir = env)
  for (nm in names) {
    p <- file.path(d, nm)
    ext <- tolower(tools::file_ext(nm))
    if (ext == "eml") {
      writeLines(c("From: lab@example.com", "To: robin@example.com",
                   paste0("Subject: results ", nm), "", "Please find attached."), p)
    } else if (ext == "png") {
      writeBin(c(as.raw(c(0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a)),
                 charToRaw(paste0("png-body-", nm))), p)
    } else if (ext %in% c("jpg", "jpeg")) {
      writeBin(c(as.raw(c(0xff, 0xd8, 0xff, 0xe0)), charToRaw(paste0("jpg-body-", nm))), p)
    } else if (ext == "zip") {
      writeBin(c(as.raw(c(0x50, 0x4b, 0x03, 0x04)), charToRaw(paste0("zip-body-", nm))), p)
    } else if (ext == "pdf") {
      writeBin(c(charToRaw("%PDF-1.4\n"), charToRaw(paste0("pdf-body-", nm))), p)
    } else {
      writeLines(paste0("leftover ", nm), p)
    }
  }
  file.path(d, names)
}

emails_root <- function(s) file.path(s$archive_dir, "_emails")

#' md5 + mtime of every file in a folder, keyed by basename.
file_facts <- function(dir) {
  f <- list.files(dir, full.names = TRUE)
  list(md5 = stats::setNames(unname(tools::md5sum(f)), basename(f)),
       mtime = stats::setNames(as.numeric(file.info(f)$mtime), basename(f)))
}

filed_files <- function(entry) as.character(unlist(entry$files_filed$files))

filed_to <- function(entry) {
  x <- entry$files_filed$to
  if (is.null(x) || length(x) != 1 || is.na(x)) return(NA_character_)
  normalizePath(as.character(x), mustWork = FALSE)
}
np <- function(p) normalizePath(p, mustWork = FALSE)

# tree_snapshot() md5s directories too, which only warns; keep the output clean.
snap <- function(dir) suppressWarnings(tree_snapshot(dir))

# ---- 1. all data done -> leftovers filed, input folder gone ----------------

test_that("inbox_run(): a folder whose data all archived has its leftovers MOVED to <archive>/_emails/<folder>/ and the input folder removed", {
  s <- inbox_setup()
  now <- Sys.time()
  name <- "input2026-10-18 0900 ALS results XX1234567"
  lo <- make_leftovers()
  d <- make_inbox_folder(s$input_dir, name, c(inbox_proj_a_files(), lo), now = now)
  before <- file_facts(d)
  lo_names <- basename(lo)

  res <- run_inbox(s, now = now)

  # the data really was imported (the precondition of the rule)
  st <- ingest_file_rows(s$db)
  for (fn in basename(inbox_proj_a_files())) {
    expect_identical(st$state[match(fn, st$filename)], "archived", info = fn)
  }

  expect_false(dir.exists(d))
  dest <- file.path(emails_root(s), name)
  expect_true(dir.exists(dest))
  expect_setequal(list.files(dest), lo_names)
  after <- file_facts(dest)
  for (fn in lo_names) {
    expect_identical(unname(after$md5[fn]), unname(before$md5[fn]), info = fn)
    # mtimes preserved (a rename on one filesystem keeps them)
    expect_true(isTRUE(abs(after$mtime[fn] - before$mtime[fn]) < 2), info = fn)
  }
  # the data files went to the asset archive as before, not to _emails
  expect_false(any(basename(inbox_proj_a_files()) %in% list.files(dest)))

  f <- res$folders[[name]]
  expect_setequal(filed_files(f), lo_names)
  expect_identical(filed_to(f), np(dest))
  expect_length(f$files_left, 0)
})

test_that("inbox_run(): the run log line records files_filed (names + destination)", {
  s <- inbox_setup()
  now <- Sys.time()
  name <- "input2026-10-18 0900 a"
  lo <- make_leftovers()
  make_inbox_folder(s$input_dir, name, c(inbox_proj_a_files(), lo), now = now)
  run_inbox(s, now = now)

  log <- read_inbox_log(s$report_dir)
  expect_length(log, 1)
  f <- log[[1]]$folders[[name]]
  expect_true("files_filed" %in% names(f))
  expect_setequal(as.character(unlist(f$files_filed$files)), basename(lo))
  expect_identical(filed_to(f), np(file.path(emails_root(s), name)))
})

test_that("inbox_run(): a filed folder is no longer listed under Waiting", {
  s <- inbox_setup()
  now <- Sys.time()
  name <- "input2026-10-18 0900 a"
  make_inbox_folder(s$input_dir, name, c(inbox_proj_a_files(), make_leftovers()), now = now)
  run_inbox(s, now = now)

  note <- read_status_note(s$report_dir)
  waiting <- md_section(note, "Waiting")
  expect_false(any(grepl("0900 a", waiting, fixed = TRUE)))
  expect_false(any(grepl("_email.eml", waiting, fixed = TRUE)))
  expect_true(grepl("\\b0 folder\\(s\\) waiting", note[[1]]))
  js <- jsonlite::fromJSON(file.path(s$report_dir, ".import-status.json"),
                           simplifyVector = FALSE)
  expect_equal(as.integer(js$folders_waiting), 0L)
})

# ---- 2. an unfinished data file -> nothing moves -----------------------------

expect_nothing_filed <- function(s, d, name, before, res, unfinished, leftovers) {
  expect_true(dir.exists(d))
  now_facts <- file_facts(d)
  for (fn in leftovers) {
    expect_true(fn %in% names(now_facts$md5), info = fn)
    expect_identical(unname(now_facts$md5[[fn]]), unname(before$md5[[fn]]), info = fn)
  }
  for (fn in unfinished) expect_true(file.exists(file.path(d, fn)), info = fn)
  expect_false(dir.exists(file.path(emails_root(s), name)))
  expect_length(filed_files(res$folders[[name]]), 0)

  waiting <- md_section(read_status_note(s$report_dir), "Waiting")
  expect_true(any(grepl(name, waiting, fixed = TRUE)))
  for (fn in unfinished) {
    expect_true(any(grepl(fn, waiting, fixed = TRUE)), info = fn)
  }
  # leftovers are counted, not itemised
  for (fn in leftovers) {
    expect_false(any(grepl(fn, waiting, fixed = TRUE)), info = fn)
  }
  count_line <- waiting[grepl(sprintf("\\b%d other file\\(s\\)", length(leftovers)), waiting)]
  expect_length(count_line, 1)
  expect_true(grepl("filed", count_line, fixed = TRUE))
}

test_that("inbox_run(): a folder still holding a needs_review data file moves nothing; Waiting lists only that file plus a leftover count", {
  s <- inbox_setup()
  now <- Sys.time()
  name <- "input2026-10-18 0900 review"
  lo <- make_leftovers(names = c("_email.eml", "image001.png", "image002.jpg"))
  # random.csv is a data file (csv); it is held as needs_review below
  d <- make_inbox_folder(s$input_dir, name,
                         c(inbox_proj_a_files(), inbox_fixture("esdat", "random.csv"), lo),
                         now = now)
  held <- file.path(d, "random.csv")
  held_hash <- hash_file(held)
  real_ingest_dir <- ingest_dir
  testthat::local_mocked_bindings(ingest_dir = function(path, ..., db) {
    out <- real_ingest_dir(path, ..., db = db)
    con <- seed_con(db)
    on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
    ingest_file_set_state(con, held_hash, "needs_review", reset = TRUE)
    out
  })
  before <- file_facts(d)

  res <- run_inbox(s, now = now)

  st <- ingest_file_rows(s$db)
  expect_identical(st$state[match("random.csv", st$filename)], "needs_review")
  expect_nothing_filed(s, d, name, before, res,
                       unfinished = "random.csv", leftovers = basename(lo))
})

test_that("inbox_run(): a failed or quarantined data file (corrupt CSV, unclaimed csv) also holds the leftovers back", {
  s <- inbox_setup()
  now <- Sys.time()
  name <- "input2026-10-18 0930 mixed"
  lo <- make_leftovers()
  d <- make_inbox_folder(s$input_dir, name,
                         c(inbox_rain_files(), inbox_corrupt_file(),
                           inbox_fixture("esdat", "random.csv"), lo),
                         now = now)
  before <- file_facts(d)

  res <- run_inbox(s, now = now)

  st <- ingest_file_rows(s$db)
  expect_identical(st$state[match(basename(inbox_corrupt_file()), st$filename)], "failed")
  expect_identical(st$state[match("random.csv", st$filename)], "quarantined")
  expect_nothing_filed(s, d, name, before, res,
                       unfinished = c(basename(inbox_corrupt_file()), "random.csv"),
                       leftovers = basename(lo))
})

# ---- 3. never overwrite: name collisions ------------------------------------------

test_that("inbox_run(): an existing _emails/<folder>/ is never overwritten; the leftovers go to '<folder> (2)', then '(3)'", {
  s <- inbox_setup()
  now <- Sys.time()
  name <- "input2026-10-18 0900 re-delivered"
  prior <- file.path(emails_root(s), name)
  dir.create(prior, recursive = TRUE)
  writeLines("an EARLIER email with the same subject line", file.path(prior, "_email.eml"))
  prior_md5 <- file_md5(file.path(prior, "_email.eml"))

  lo <- make_leftovers()
  d <- make_inbox_folder(s$input_dir, name, c(inbox_proj_a_files(), lo), now = now)
  before <- file_facts(d)
  res <- run_inbox(s, now = now)

  expect_identical(list.files(prior), "_email.eml")
  expect_identical(file_md5(file.path(prior, "_email.eml")), prior_md5)
  dest2 <- file.path(emails_root(s), paste0(name, " (2)"))
  expect_true(dir.exists(dest2))
  expect_setequal(list.files(dest2), basename(lo))
  expect_identical(unname(file_facts(dest2)$md5[basename(lo)]),
                   unname(before$md5[basename(lo)]))
  expect_identical(filed_to(res$folders[[name]]), np(dest2))
  expect_false(dir.exists(d))

  # a third delivery under the same name -> " (3)"
  lo3 <- make_leftovers(names = c("_email.eml", "image001.png"))
  d3 <- make_inbox_folder(s$input_dir, name, c(inbox_rain_files(), lo3), now = now)
  run_inbox(s, now = now + 120)
  dest3 <- file.path(emails_root(s), paste0(name, " (3)"))
  expect_true(dir.exists(dest3))
  expect_setequal(list.files(dest3), basename(lo3))
  expect_setequal(list.files(dest2), basename(lo))
  expect_identical(file_md5(file.path(prior, "_email.eml")), prior_md5)
  expect_false(dir.exists(d3))
})

# ---- 4. dry run ----------------------------------------------------------------------

test_that("inbox_run(dry_run = TRUE): nothing is filed or removed, and the note says what would be filed", {
  s <- inbox_setup()
  now <- Sys.time()
  name <- "input2026-10-18 0900 a"
  make_inbox_folder(s$input_dir, name, c(inbox_proj_a_files(), make_leftovers()), now = now)
  in_before <- snap(s$input_dir)
  arch_before <- snap(s$archive_dir)

  res <- run_inbox(s, now = now, dry_run = TRUE)
  expect_true(res$ran)
  expect_identical(snap(s$input_dir), in_before)
  expect_identical(snap(s$archive_dir), arch_before)
  expect_false(dir.exists(emails_root(s)))

  notes <- c(if (file.exists(inbox_report_path(s$report_dir, now))) read_report(s$report_dir, now),
             if (file.exists(status_note_path(s$report_dir))) read_status_note(s$report_dir))
  would <- notes[grepl("(?i)would file", notes, perl = TRUE)]
  expect_gt(length(would), 0)
  expect_true(any(grepl(name, would, fixed = TRUE)))

  # and the real run afterwards still files them
  run_inbox(s, now = now)
  expect_setequal(list.files(file.path(emails_root(s), name)),
                  c("_email.eml", "image001.png", "image002.jpg", "Cover letter.pdf"))
})

# ---- 5. a folder with no data files at all ---------------------------------------------

test_that("inbox_run(): a folder holding only leftovers (an email with just a PDF and a logo) is all-done and filed", {
  s <- inbox_setup()
  now <- Sys.time()
  name <- "input2026-10-18 0900 ACIRL report"
  # an ACIRL 2400-* report PDF with no work order in the DB: never retained
  lo <- make_leftovers(names = c("_email.eml", "image001.png",
                                 "2400-9999-01 Sep 2026 Monthly Katoomba WMF.pdf"))
  d <- make_inbox_folder(s$input_dir, name, lo, now = now)
  before <- file_facts(d)

  res <- run_inbox(s, now = now)

  expect_false(dir.exists(d))
  dest <- file.path(emails_root(s), name)
  expect_setequal(list.files(dest), basename(lo))
  expect_identical(unname(file_facts(dest)$md5[basename(lo)]),
                   unname(before$md5[basename(lo)]))
  expect_setequal(filed_files(res$folders[[name]]), basename(lo))
  waiting <- md_section(read_status_note(s$report_dir), "Waiting")
  expect_false(any(grepl(name, waiting, fixed = TRUE)))
})

test_that("inbox_run(): a backlog folder left by an earlier import (only leftovers remain, already known to the DB) is filed", {
  # The motivating case: folders imported before this rule existed hold only
  # _email.eml + images, each already in ingest_file as quarantined. Nothing
  # in them is new to the DB, yet they must stop waiting forever.
  s <- inbox_setup()
  now <- Sys.time()
  name <- "input2026-10-17 0900 old"
  lo <- make_leftovers(names = c("_email.eml", "image001.png"))
  d <- make_inbox_folder(s$input_dir, name, c(inbox_proj_a_files(), lo), now = now)
  quiet_run(ingest_dir(d, db = s$db))
  expect_setequal(list.files(d), basename(lo))
  before <- file_facts(d)

  run_inbox(s, now = now)

  expect_false(dir.exists(d))
  dest <- file.path(emails_root(s), name)
  expect_setequal(list.files(dest), basename(lo))
  expect_identical(unname(file_facts(dest)$md5[basename(lo)]),
                   unname(before$md5[basename(lo)]))
})

# ---- 6. idempotency ------------------------------------------------------------------------

test_that("inbox_run(): a second run after filing is a no-op (check says 'none'; archive and inbox unchanged)", {
  s <- inbox_setup()
  now <- sydney_midday()
  name <- "input2026-10-18 0900 a"
  make_inbox_folder(s$input_dir, name, c(inbox_proj_a_files(), make_leftovers()), now = now)
  run_inbox(s, now = now)
  arch <- snap(s$archive_dir)
  inbox <- snap(s$input_dir)
  n_log <- length(read_inbox_log(s$report_dir))

  # the state was written with the inbox signature AFTER filing
  res2 <- run_inbox(s, now = now + 3600)
  expect_identical(res2$action, "none")
  expect_identical(snap(s$archive_dir), arch)
  expect_identical(snap(s$input_dir), inbox)
  expect_length(read_inbox_log(s$report_dir), n_log)
  expect_false(dir.exists(file.path(emails_root(s), paste0(name, " (2)"))))

  # even a forced re-run (state gone) files nothing twice
  unlink(file.path(s$report_dir, ".imports.state"))
  run_inbox(s, now = now + 7200)
  expect_identical(snap(s$archive_dir), arch)
  expect_identical(list.files(emails_root(s)), name)
})

# ---- 7. widened data kinds (ruling 3) ----------------------------------------------------

for (odd in c("bundle.zip", "notes.txt")) {
  local({
    odd <- odd
    test_that(sprintf("inbox_run(): an unclaimed %s is a DATA file - it keeps the folder unfiled and is listed under Waiting", odd), {
      s <- inbox_setup()
      now <- Sys.time()
      name <- paste0("input2026-10-18 0900 with ", odd)
      lo <- make_leftovers(names = c("_email.eml", "image001.png"))
      oddf <- make_leftovers(names = odd)
      d <- make_inbox_folder(s$input_dir, name, c(inbox_proj_a_files(), lo, oddf), now = now)
      before <- file_facts(d)

      res <- run_inbox(s, now = now)

      st <- ingest_file_rows(s$db)
      expect_identical(st$state[match(odd, st$filename)], "quarantined")
      expect_nothing_filed(s, d, name, before, res,
                           unfinished = odd, leftovers = basename(lo))
    })
  })
}

# ---- 8. filing is visible in the dated note (ruling 4) --------------------------------------

test_that("import_report(): the dated note has a Filed section naming each filed folder, its files and a file:/// link to the destination", {
  s <- inbox_setup()
  now <- Sys.time()
  name <- "input2026-10-18 0900 ALS results"
  lo <- make_leftovers()
  make_inbox_folder(s$input_dir, name, c(inbox_proj_a_files(), lo), now = now)
  run_inbox(s, now = now)

  day <- read_report(s$report_dir, now)
  filed <- md_section(day, "Filed")
  expect_gt(length(filed), 0)
  expect_true(any(grepl(name, filed, fixed = TRUE)))
  for (fn in basename(lo)) expect_true(any(grepl(fn, filed, fixed = TRUE)), info = fn)
  link <- filed[grepl("file://", filed, fixed = TRUE)]
  expect_gt(length(link), 0)
  # the link points at the _emails destination (spaces URL-encoded)
  expect_true(any(grepl(paste0("_emails/", utils::URLencode(name)), link, fixed = TRUE)))
  # imports still appear as before
  expect_gt(length(md_section(day, "Imported today")), 0)
})

test_that("inbox_run(): a day whose only activity is filing still writes the dated note, with a Filed section", {
  s <- inbox_setup()
  now <- Sys.time()
  name <- "input2026-10-17 0900 old"
  lo <- make_leftovers(names = c("_email.eml", "image001.png"))
  d <- make_inbox_folder(s$input_dir, name, c(inbox_proj_a_files(), lo), now = now)
  # imported outside inbox_run(): nothing in today's log is an import
  quiet_run(ingest_dir(d, db = s$db))

  run_inbox(s, now = now)

  expect_true(file.exists(inbox_report_path(s$report_dir, now)))
  if (!file.exists(inbox_report_path(s$report_dir, now))) return(invisible())
  day <- read_report(s$report_dir, now)
  filed <- md_section(day, "Filed")
  expect_true(any(grepl(name, filed, fixed = TRUE)))
  for (fn in basename(lo)) expect_true(any(grepl(fn, filed, fixed = TRUE)), info = fn)
})

test_that("import_report(): no Filed section on a day nothing was filed", {
  s <- inbox_setup()
  now <- Sys.time()
  # imports, but the folder holds an unfinished data file, so nothing is filed
  make_inbox_folder(s$input_dir, "input2026-10-18 0900 mixed",
                    c(inbox_proj_a_files(), inbox_corrupt_file(), make_leftovers()), now = now)
  run_inbox(s, now = now)
  day <- read_report(s$report_dir, now)
  expect_length(md_section(day, "Filed"), 0)
  expect_false(any(grepl("^#+\\s*Filed", day)))
})
