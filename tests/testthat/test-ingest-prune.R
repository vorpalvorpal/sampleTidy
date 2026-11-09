# Snapshot pruning wired into ingest_dir(): prune_snapshots() runs after a
# successful snapshot, never otherwise, and its failure never fails the ingest.

prune_test_setup <- function() {
  env <- parent.frame()
  db_path <- seed_db(dir = withr::local_tempdir(.local_envir = env))
  con <- seed_con(db_path)
  ensure_test_asset_table(con)
  DBI::dbDisconnect(con, shutdown = TRUE)
  archive_dir <- withr::local_tempdir(.local_envir = env)
  snapshot_dir <- withr::local_tempdir(.local_envir = env)
  withr::local_options(list(
    "sampletidy.archive_dir" = archive_dir,
    "sampletidy.snapshot_dir" = snapshot_dir,
    "sampletidy.remove_ingested" = FALSE
  ), .local_envir = env)
  list(db_path = db_path, archive_dir = archive_dir, snapshot_dir = snapshot_dir)
}

prune_stage_esdat <- function(env = parent.frame()) {
  input_dir <- withr::local_tempdir(.local_envir = env)
  for (f in list.files(testthat::test_path("fixtures", "esdat"), full.names = TRUE)) {
    if (!grepl("^PROJ_A\\.", basename(f))) next # one clean event; no unrelated warnings
    file.copy(f, file.path(input_dir, basename(f)))
  }
  input_dir
}

prune_touch <- function(dir, names) {
  for (n in names) writeLines("", file.path(dir, n))
}

snap_name <- function(d) sprintf("monitoring_%s.duckdb", format(d, "%Y-%m-%d"))

test_that("prune: ingest_dir() prunes old non-month-final snapshots after snapshotting", {
  setup <- prune_test_setup()
  input_dir <- prune_stage_esdat()

  today <- Sys.Date()
  base <- today - 200
  month_start <- as.Date(format(base, "%Y-%m-01"))
  old_days <- month_start + c(2, 9, 19) # same old month; the 20th-of-month is final
  young <- today - c(5, 30)
  prune_touch(setup$snapshot_dir, snap_name(c(old_days, young)))
  # a second, older month with a single snapshot: it is its month's final one
  lone <- month_start - 40
  prune_touch(setup$snapshot_dir, snap_name(lone))
  others <- c("monitoring_pre-001-x_2026-01-01.duckdb", "notes.txt")
  prune_touch(setup$snapshot_dir, others)

  ingest_dir(input_dir, db = setup$db_path)

  remaining <- list.files(setup$snapshot_dir)
  expect_false(snap_name(old_days[1]) %in% remaining)
  expect_false(snap_name(old_days[2]) %in% remaining)
  expect_true(snap_name(old_days[3]) %in% remaining)
  expect_true(snap_name(lone) %in% remaining)
  expect_true(all(snap_name(young) %in% remaining))
  expect_true(snap_name(today) %in% remaining)
  expect_true(all(others %in% remaining))
})

test_that("prune: prune_snapshots() is called after the snapshot exists, with the snapshot dir", {
  setup <- prune_test_setup()
  input_dir <- prune_stage_esdat()
  calls <- list()
  testthat::local_mocked_bindings(
    prune_snapshots = function(...) {
      args <- list(...)
      calls[[length(calls) + 1]] <<- list(
        args = args,
        snapshot_existed = file.exists(file.path(setup$snapshot_dir, snap_name(Sys.Date())))
      )
      invisible(NULL)
    }
  )

  ingest_dir(input_dir, db = setup$db_path)

  expect_length(calls, 1)
  expect_true(calls[[1]]$snapshot_existed)
  dest <- if (!is.null(calls[[1]]$args$dest_dir)) calls[[1]]$args$dest_dir else calls[[1]]$args[[1]]
  expect_equal(normalizePath(dest), normalizePath(setup$snapshot_dir))
  expect_null(calls[[1]]$args$keep_days)
})

test_that("prune: no prune on a dry run", {
  setup <- prune_test_setup()
  input_dir <- prune_stage_esdat()
  n <- 0
  testthat::local_mocked_bindings(prune_snapshots = function(...) { n <<- n + 1; invisible(NULL) })

  ingest_dir(input_dir, db = setup$db_path, dry_run = TRUE)

  expect_equal(n, 0)
})

test_that("prune: no prune when there is nothing to do (empty dir, or a repeat ingest)", {
  setup <- prune_test_setup()
  input_dir <- prune_stage_esdat()
  ingest_dir(input_dir, db = setup$db_path) # real first pass; snapshot taken
  n <- 0
  testthat::local_mocked_bindings(prune_snapshots = function(...) { n <<- n + 1; invisible(NULL) })

  ingest_dir(input_dir, db = setup$db_path) # same files again
  suppressWarnings(ingest_dir(withr::local_tempdir(), db = setup$db_path)) # empty dir

  expect_equal(n, 0)
})

test_that("prune: a prune failure warns but does not fail the ingest or block removal", {
  setup <- prune_test_setup()
  input_dir <- prune_stage_esdat()
  files_before <- list.files(input_dir)
  withr::local_options(list("sampletidy.remove_ingested" = TRUE))
  testthat::local_mocked_bindings(prune_snapshots = function(...) stop("simulated prune failure"))

  report <- NULL
  expect_warning(
    report <- ingest_dir(input_dir, db = setup$db_path),
    "prun"
  )

  expect_false(is.null(report))
  expect_false(is.na(report$snapshot_path))
  expect_true(file.exists(report$snapshot_path))
  expect_lt(length(list.files(input_dir)), length(files_before))
  expect_gt(length(report$removed_files), 0)
})

test_that("prune: a snapshot failure still propagates and prune is not called", {
  setup <- prune_test_setup()
  input_dir <- prune_stage_esdat()
  n <- 0
  testthat::local_mocked_bindings(
    snapshot_db = function(...) stop("simulated snapshot failure"),
    prune_snapshots = function(...) { n <<- n + 1; invisible(NULL) }
  )

  expect_error(ingest_dir(input_dir, db = setup$db_path), "simulated snapshot failure")
  expect_equal(n, 0)
})
