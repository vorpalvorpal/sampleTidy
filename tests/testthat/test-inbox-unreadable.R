# Auto-import must not file a folder whose files could not be read (cloud-only
# OneDrive files read as 0 bytes and hash as empty input; 2026-10-26). Also: a
# live run must refuse an archive_dir inside the temp area (2026-10-20).

st_empty_hash_inbox <- "99aa06d3014798d86001c324468d497f"

unreadable_setup <- function(env = parent.frame()) {
  s <- inbox_setup(env)
  con <- seed_con(s$db)
  DBI::dbExecute(con,
    "INSERT INTO ingest_file (hash, filename, state, state_reason) VALUES (?, ?, 'ignored', 'empty_file')",
    params = list(st_empty_hash_inbox, "zero.csv"))
  DBI::dbDisconnect(con, shutdown = TRUE)
  now <- Sys.time()
  src <- withr::local_tempdir(.local_envir = env)
  csv <- file.path(src, "WO-TEST-001 results.csv"); writeLines(c("a,b", "1,2"), csv)
  pdf <- file.path(src, "WO-TEST-001 report.pdf")
  writeBin(c(charToRaw("%PDF-1.4\n"), charToRaw("synthetic")), pdf)
  s$folder <- make_inbox_folder(s$input_dir, "batch-2026-10-26 0900 WO-TEST-001",
                                c(csv, pdf), now = now)
  s$now <- now
  s
}

mock_unreadable_hash <- function(env = parent.frame()) {
  real <- rlang::hash_file
  testthat::local_mocked_bindings(
    hash_file = function(path, ...) {
      if (file.size(path) > 0) "99aa06d3014798d86001c324468d497f" else real(path, ...)
    },
    .package = "rlang", .env = env
  )
}

test_that("unreadable (empty-hashing) non-empty files: find_work sees work and the folder is not fileable", {
  s <- unreadable_setup()
  mock_unreadable_hash()
  cd <- list(name = basename(s$folder), path = s$folder,
             files = list.files(s$folder),
             file_paths = list.files(s$folder, full.names = TRUE))
  fw <- .inbox_find_work(stats::setNames(list(cd), cd$name), s$db)
  expect_true(unname(fw$work[[basename(s$folder)]]))
  v <- .inbox_folder_verdict(s$folder, s$db)
  expect_false(v$fileable)
})

test_that("inbox_run() does not file a folder whose files hash as empty", {
  s <- unreadable_setup()
  mock_unreadable_hash()
  res <- run_inbox(s, now = s$now)
  expect_true(dir.exists(s$folder))
  expect_false(dir.exists(file.path(s$archive_dir, "filed-mail", basename(s$folder))))
  f <- res$folders[[basename(s$folder)]]
  expect_length(as.character(unlist(f$files_filed$files)), 0L)
})

# ---- archive_dir guard -------------------------------------------------------
# Tests run with db AND archive_dir under tempdir(), so the guard must stay
# silent for them. To make the db look "outside" the temp area while the archive
# is "inside", base::tempdir is mocked to a separate directory that contains the
# archive dir but not the db.

test_that("inbox_run() refuses a temp-area archive_dir when the db is outside the temp area", {
  s <- inbox_setup()
  fake_tmp_parent <- withr::local_tempdir()
  fake_tmp <- file.path(fake_tmp_parent, "RtmpFAKE"); dir.create(fake_tmp)
  arch <- file.path(fake_tmp, "archive"); dir.create(arch)
  withr::local_options("sampletidy.archive_dir" = arch)
  testthat::local_mocked_bindings(tempdir = function(...) fake_tmp, .package = "base")
  d <- make_inbox_folder(s$input_dir, "batch-2026-10-26 0900 WO-TEST-002",
                         inbox_proj_a_files(), now = Sys.time())
  before <- ingest_file_rows(s$db)
  res <- run_inbox(s)
  expect_true(any(grepl("archive_dir", res$errors) & grepl("temp", res$errors, ignore.case = TRUE)))
  expect_true(dir.exists(d))
  expect_identical(nrow(ingest_file_rows(s$db)), nrow(before))
  expect_identical(length(list.files(arch, recursive = TRUE)), 0L)
  expect_identical(length(list.files(s$backup_dir)), 0L)
  expect_true(is.na(res$backup_path))
})
