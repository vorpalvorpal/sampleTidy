# C4 - archive copies made inside a db_transaction() that rolls back must be
# removed; see dev/specs C4-archive-rollback-cleanup. Reuses
# archive_test_setup() from test-archive.R (testthat loads files alphabetically
# but helpers are not shared across test files, so it is redefined here).

rb_setup <- function() {
  env <- parent.frame()
  db_path <- seed_db(dir = withr::local_tempdir(.local_envir = env))
  con <- seed_con(db_path)
  ensure_test_asset_table(con)
  archive_dir <- withr::local_tempdir(.local_envir = env)
  withr::local_options(list("sampletidy.archive_dir" = archive_dir), .local_envir = env)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE), envir = env)
  list(con = con, archive_dir = archive_dir)
}

rb_src <- function(name, body, env = parent.frame()) {
  p <- file.path(withr::local_tempdir(.local_envir = env), name)
  writeLines(body, p)
  p
}

rb_dirs <- function(d) sort(list.dirs(d, recursive = FALSE))
rb_n_assets <- function(con, hash) {
  DBI::dbGetQuery(con, "SELECT count(*) AS n FROM asset WHERE hash = ?",
                  params = list(hash))$n[[1]]
}
rb_event <- list(work_order = "XX1234567")

test_that("C4-1: a rolled-back transaction removes the archive directory it created", {
  s <- rb_setup()
  src <- rb_src("a.csv", "alpha")
  hash <- hash_file(src)
  before <- rb_dirs(s$archive_dir)

  expect_error(
    db_transaction(s$con, function(con) {
      archive_file(con, src, hash, rb_event)
      stop("boom")
    }),
    "boom"
  )

  expect_identical(rb_dirs(s$archive_dir), before)
  expect_equal(rb_n_assets(s$con, hash), 0)
})

test_that("C4-2: a committed transaction keeps the archive directory and file", {
  s <- rb_setup()
  src <- rb_src("a.csv", "alpha")
  hash <- hash_file(src)

  uuid <- db_transaction(s$con, function(con) archive_file(con, src, hash, rb_event))

  expect_true(file.exists(file.path(s$archive_dir, uuid, "a.csv")))
  expect_length(rb_dirs(s$archive_dir), 1)
  expect_equal(rb_n_assets(s$con, hash), 1)
})

test_that("C4-3: a rollback never deletes a pre-existing (dedupe-reused) directory", {
  s <- rb_setup()
  src <- rb_src("a.csv", "alpha")
  hash <- hash_file(src)
  uuid <- archive_file(s$con, src, hash, rb_event)
  before <- rb_dirs(s$archive_dir)

  expect_error(
    db_transaction(s$con, function(con) {
      expect_identical(archive_file(con, src, hash, rb_event), uuid)
      stop("boom")
    }),
    "boom"
  )

  expect_identical(rb_dirs(s$archive_dir), before)
  expect_true(file.exists(file.path(s$archive_dir, uuid, "a.csv")))
  expect_equal(rb_n_assets(s$con, hash), 1)
})

test_that("C4-4: a failed file copy removes the directory just created and aborts", {
  s <- rb_setup()
  src <- rb_src("a.csv", "alpha")
  hash <- hash_file(src)
  before <- rb_dirs(s$archive_dir)

  # Seam: archive_file() must copy via an internal .ar_copy_file(from, to).
  testthat::local_mocked_bindings(.ar_copy_file = function(...) FALSE)

  expect_error(archive_file(s$con, src, hash, rb_event), class = "sampletidy_error")
  expect_identical(rb_dirs(s$archive_dir), before)
  expect_equal(rb_n_assets(s$con, hash), 0)
})

test_that("C4-5: several archives in one rolled-back transaction are all removed; retry leaves one each", {
  s <- rb_setup()
  src1 <- rb_src("a.csv", "alpha")
  src2 <- rb_src("b.csv", "bravo")
  h1 <- hash_file(src1)
  h2 <- hash_file(src2)
  before <- rb_dirs(s$archive_dir)

  expect_error(
    db_transaction(s$con, function(con) {
      archive_file(con, src1, h1, rb_event)
      archive_file(con, src2, h2, rb_event)
      stop("boom")
    }),
    "boom"
  )
  expect_identical(rb_dirs(s$archive_dir), before)

  db_transaction(s$con, function(con) {
    archive_file(con, src1, h1, rb_event)
    archive_file(con, src2, h2, rb_event)
  })
  expect_length(rb_dirs(s$archive_dir), length(before) + 2)
  expect_equal(rb_n_assets(s$con, h1), 1)
  expect_equal(rb_n_assets(s$con, h2), 1)
})

test_that("C4-6: cleanup failure (directory already gone) does not mask the original error", {
  s <- rb_setup()
  src <- rb_src("a.csv", "alpha")
  hash <- hash_file(src)

  expect_error(
    db_transaction(s$con, function(con) {
      uuid <- archive_file(con, src, hash, rb_event)
      unlink(file.path(s$archive_dir, uuid), recursive = TRUE)
      stop("boom")
    }),
    "boom"
  )
})

test_that("C4-7: archive_file() outside any transaction keeps its directory", {
  s <- rb_setup()
  src <- rb_src("a.csv", "alpha")
  hash <- hash_file(src)

  uuid <- archive_file(s$con, src, hash, rb_event)

  expect_true(file.exists(file.path(s$archive_dir, uuid, "a.csv")))
  expect_length(rb_dirs(s$archive_dir), 1)
})
