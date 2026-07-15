# Plan 09 - R/commit.R: `commit_event(event, resolved, con)`.
#
# Per the pipeline-tests brief (mirroring the plan-08 "construct directly"
# instruction), both `event` (plan-07 R-7.5 shape) and `resolved` (plan-08
# R-8.8 shape: list(clean, review, skipped, counts)) are built directly here
# rather than by running real assemble_events()/reconcile_event(), keeping
# this file independent of plans 07/08's implementation status. See
# dev/plans/PLAN-CHANGE-REQUESTS.md for the `asset`-table gap this file
# works around (`ensure_test_asset_table()`, from helper-corpus.R) and the
# `existing_uuid` skipped-column-name assumption used below.

# ---- local helpers -----------------------------------------------------

#' Seed a DB, add the `asset` table, write one real source file to disk,
#' hash it, and register it in `ingest_file` at state `reconciled` (the
#' state commit_event() should find files in, per R-1.6).
commit_test_setup <- function(filename = "PROJ_A.ESDAT_XX1234567_0.Chemistry2e.CSV",
                                work_order = "XX1234567", revision = 0L) {
  # Bind withr cleanups to the calling test's frame, not this helper's - see
  # CONTRACT A41 (the A38 bug, one frame removed).
  env <- parent.frame()
  db_path <- seed_db(dir = withr::local_tempdir(.local_envir = env))
  con <- seed_con(db_path)
  ensure_test_asset_table(con)

  archive_dir <- withr::local_tempdir(.local_envir = env)
  withr::local_options(list("sampletidy.archive_dir" = archive_dir), .local_envir = env)

  src_dir <- withr::local_tempdir(.local_envir = env)
  src_path <- file.path(src_dir, filename)
  writeLines(paste("SampleCode,ChemCode", filename), src_path)
  hash <- hash_file(src_path)

  DBI::dbExecute(con, sprintf(
    "INSERT INTO ingest_file (hash, filename, path_first_seen, state, work_order, revision)
     VALUES ('%s', '%s', '%s', 'reconciled', '%s', %d)",
    hash, basename(src_path), src_path, work_order, revision
  ))

  list(con = con, hash = hash, path = src_path, archive_dir = archive_dir, work_order = work_order)
}

mk_commit_event <- function(files, work_order = "XX1234567") {
  list(
    work_order = work_order, orphan = FALSE,
    results = tibble::tibble(), samples = tibble::tibble(),
    files = files,
    report = list(n_results = 0L, n_by_sample_type = list(), n_ncp_foreign = 0L,
                  skipped = tibble::tibble(hash = character(), source_ref = character(), reason = character()),
                  warnings = character())
  )
}

mk_clean_row <- function(...) {
  defaults <- list(
    source_hash = "hash-x", source_ref = "row1", work_order = "XX1234567", revision = 0L,
    org = "ALS", adapter = "esdat/1", lab_sample_id = "XX1234567099", sample_type = "Normal",
    feature_raw = "T.S01", analyte_raw = "pH Value", cas_number = NA_character_,
    method_raw = "EA005P: pH by PC Titrator", total_or_filtered = "T", units_raw = "pH Unit",
    value_raw = "6.50", value_num = 6.50, value_chr = NA_character_, below_detection = FALSE,
    rl = NA_real_, lab_qualifier = NA_character_, analysed_date = as.Date("2025-06-10"),
    comments = NA_character_, confidence = 1, sample_datetime_raw = "10 Jun 2025 09:00",
    sampler = NA_character_, matrix_raw = "WATER", parent_sample = NA_character_,
    uuid_feature = "f-0001", uuid_lab = "lm-0001", uuid_analyte = "a-0001",
    value_converted = 6.50, rl_converted = NA_real_,
    sample_date = as.Date("2025-06-10"),
    sample_datetime = as.POSIXct("2025-06-10 09:00:00", tz = "Australia/Sydney"),
    supersedes = NA_character_
  )
  args <- utils::modifyList(defaults, list(...))
  tibble::as_tibble(args)
}

mk_resolved <- function(clean = mk_clean_row(), review = tibble::tibble(),
                          skipped = tibble::tibble(), counts = c(new = nrow(clean))) {
  list(clean = clean, review = review, skipped = skipped, counts = counts)
}

count_rows <- function(con, table) DBI::dbGetQuery(con, sprintf('SELECT count(*) AS n FROM "%s"', table))$n

# ---- R-9.2 criteria -------------------------------------------------------

test_that("R-9.2: committing new clean rows creates exactly matching sample/analysis counts", {
  setup <- commit_test_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  files <- tibble::tibble(hash = setup$hash, filename = basename(setup$path),
                          adapter = "esdat/1", rank = 3L, kept = TRUE)
  event <- mk_commit_event(files)
  clean <- dplyr::bind_rows(
    mk_clean_row(source_ref = "r1", source_hash = setup$hash, uuid_feature = "f-0001",
                 uuid_lab = "lm-0001", uuid_analyte = "a-0001",
                 sample_date = as.Date("2025-06-10")),
    mk_clean_row(source_ref = "r2", source_hash = setup$hash, uuid_feature = "f-0002",
                 uuid_lab = "lm-0003", uuid_analyte = "a-0003", analyte_raw = "Electrical Conductivity @ 25°C",
                 units_raw = "mS/cm", value_raw = "0.5", value_num = 0.5, value_converted = 0.5,
                 sample_date = as.Date("2025-06-11"),
                 sample_datetime = as.POSIXct("2025-06-11 09:00:00", tz = "Australia/Sydney"))
  )
  resolved <- mk_resolved(clean = clean)

  before_sample <- count_rows(con, "sample")
  before_analysis <- count_rows(con, "analysis")
  commit_event(event, resolved, con)
  expect_equal(count_rows(con, "sample") - before_sample, 2)
  expect_equal(count_rows(con, "analysis") - before_analysis, 2)
})

test_that("R-9.2: a second commit_event() call on already-terminal files aborts", {
  setup <- commit_test_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  files <- tibble::tibble(hash = setup$hash, filename = basename(setup$path),
                          adapter = "esdat/1", rank = 3L, kept = TRUE)
  event <- mk_commit_event(files)
  resolved <- mk_resolved(clean = mk_clean_row(source_ref = "r1", source_hash = setup$hash))

  commit_event(event, resolved, con)
  expect_error(commit_event(event, resolved, con))
})

test_that("R-9.2: mid-commit failure leaves zero new rows anywhere (atomicity)", {
  setup <- commit_test_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # Force step 5 (review_queue insert) to fail on a PK collision: pre-insert
  # a review_queue row at a fixed uuid, then make every subsequent
  # uuid::UUIDgenerate() call return that same value for the duration of
  # this commit.
  DBI::dbExecute(con, "INSERT INTO review_queue (uuid, created_at, kind, status) VALUES
    ('dup-uuid', CURRENT_TIMESTAMP, 'unknown_feature', 'open')")
  testthat::local_mocked_bindings(UUIDgenerate = function(...) "dup-uuid", .package = "uuid")

  files <- tibble::tibble(hash = setup$hash, filename = basename(setup$path),
                          adapter = "esdat/1", rank = 3L, kept = TRUE)
  event <- mk_commit_event(files)
  clean <- mk_clean_row(source_ref = "r1", source_hash = setup$hash)
  review <- tibble::tibble(source_ref = "r2", kind = "unknown_feature",
                           work_order = "XX1234567", payload = "{}")
  resolved <- mk_resolved(clean = clean, review = review)

  before <- list(sample = count_rows(con, "sample"), analysis = count_rows(con, "analysis"),
                 asset = count_rows(con, "asset"), review_queue = count_rows(con, "review_queue"),
                 change_log = count_rows(con, "change_log"))

  expect_error(commit_event(event, resolved, con))

  after <- list(sample = count_rows(con, "sample"), analysis = count_rows(con, "analysis"),
                asset = count_rows(con, "asset"), review_queue = count_rows(con, "review_queue"),
                change_log = count_rows(con, "change_log"))
  expect_equal(after, before)
})

test_that("R-9.2: supersede updates the analysis in place with no duplicate row", {
  setup <- commit_test_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  files <- tibble::tibble(hash = setup$hash, filename = basename(setup$path),
                          adapter = "esdat/1", rank = 3L, kept = TRUE)
  event <- mk_commit_event(files)
  clean <- mk_clean_row(
    source_ref = "r1", source_hash = setup$hash, revision = 1L,
    uuid_feature = "f-0001", uuid_lab = "lm-0002", uuid_analyte = "a-0002",
    analyte_raw = "Fluoride", cas_number = "16984-48-8", units_raw = "mg/L",
    value_raw = "0.3", value_num = 0.3, below_detection = FALSE,
    value_converted = 300, rl_converted = 100,
    sample_date = as.Date("2025-05-24"),
    sample_datetime = as.POSIXct("2025-05-24 11:45:00", tz = "Australia/Sydney"),
    supersedes = "an-0001"
  )
  resolved <- mk_resolved(clean = clean)

  before_analysis <- count_rows(con, "analysis")
  commit_event(event, resolved, con)
  expect_equal(count_rows(con, "analysis"), before_analysis)

  updated <- DBI::dbGetQuery(con, "SELECT value, quantified FROM analysis WHERE uuid = 'an-0001'")
  expect_equal(updated$value, 300)

  log_row <- DBI::dbGetQuery(con, "SELECT * FROM change_log WHERE uuid_row = 'an-0001' ORDER BY \"at\" DESC LIMIT 1")
  expect_equal(log_row$action, "update")
  expect_equal(log_row$old, "100")
  expect_equal(log_row$new, "300")
})

test_that("R-9.2: provenance chain - every committed analysis has a change_log insert row whose source_hash matches an archived asset", {
  setup <- commit_test_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  files <- tibble::tibble(hash = setup$hash, filename = basename(setup$path),
                          adapter = "esdat/1", rank = 3L, kept = TRUE)
  event <- mk_commit_event(files)
  clean <- mk_clean_row(source_ref = "r1", source_hash = setup$hash)
  resolved <- mk_resolved(clean = clean)

  commit_event(event, resolved, con)

  new_analysis <- DBI::dbGetQuery(con, "SELECT uuid FROM analysis WHERE uuid != 'an-0001'")
  expect_equal(nrow(new_analysis), 1)
  log_row <- DBI::dbGetQuery(con, sprintf(
    "SELECT * FROM change_log WHERE uuid_row = '%s' AND action = 'insert'", new_analysis$uuid[[1]]))
  expect_equal(nrow(log_row), 1)
  expect_equal(log_row$source_hash, setup$hash)

  asset_row <- DBI::dbGetQuery(con, sprintf("SELECT * FROM asset WHERE hash = '%s'", setup$hash))
  expect_equal(nrow(asset_row), 1)
  expect_true(file.exists(file.path(setup$archive_dir, asset_row$uuid[[1]])))
})

test_that("R-9.2: superseded-rendering files (state ignored) also get asset rows and archive copies", {
  setup <- commit_test_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # a second, lesser-rendering file for the same event, superseded at
  # assembly time (R-7.2) - still archived per A13
  xtab_path <- file.path(dirname(setup$path), "XX1234567_0_XTAB.csv")
  writeLines("Workgroup:,XX1234567", xtab_path)
  xtab_hash <- hash_file(xtab_path)
  DBI::dbExecute(con, sprintf(
    "INSERT INTO ingest_file (hash, filename, path_first_seen, state, state_reason, work_order, revision)
     VALUES ('%s', '%s', '%s', 'ignored', 'superseded_by_better_source', 'XX1234567', 0)",
    xtab_hash, basename(xtab_path), xtab_path
  ))

  files <- tibble::tibble(
    hash = c(setup$hash, xtab_hash),
    filename = c(basename(setup$path), basename(xtab_path)),
    adapter = c("esdat/1", "als_xtab/1"), rank = c(3L, 1L), kept = c(TRUE, FALSE)
  )
  event <- mk_commit_event(files)
  clean <- mk_clean_row(source_ref = "r1", source_hash = setup$hash)
  resolved <- mk_resolved(clean = clean)

  commit_event(event, resolved, con)

  asset_rows <- DBI::dbGetQuery(con, sprintf(
    "SELECT * FROM asset WHERE hash IN ('%s', '%s')", setup$hash, xtab_hash))
  expect_equal(nrow(asset_rows), 2)
  for (uuid in asset_rows$uuid) {
    expect_true(file.exists(file.path(setup$archive_dir, uuid)))
  }
})

test_that("R-9.2: already_present rows get no new analysis but a provenance change_log row", {
  # NOTE: assumes the skipped tibble carries the existing analysis uuid in an
  # `existing_uuid` column for reason == 'already_present' rows (R-8.7's
  # payload isn't pinned to an exact column name - see
  # dev/plans/PLAN-CHANGE-REQUESTS.md).
  setup <- commit_test_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  files <- tibble::tibble(hash = setup$hash, filename = basename(setup$path),
                          adapter = "esdat/1", rank = 3L, kept = TRUE)
  event <- mk_commit_event(files)
  skipped <- tibble::tibble(source_ref = "rp", source_hash = setup$hash,
                            reason = "already_present", existing_uuid = "an-0001")
  resolved <- mk_resolved(clean = tibble::tibble(), skipped = skipped, counts = c(already_present = 1))

  before_analysis <- count_rows(con, "analysis")
  commit_event(event, resolved, con)
  expect_equal(count_rows(con, "analysis"), before_analysis)

  prov <- DBI::dbGetQuery(con, sprintf(
    "SELECT * FROM change_log WHERE uuid_row = 'an-0001' AND action = 'provenance' AND source_hash = '%s'",
    setup$hash))
  expect_equal(nrow(prov), 1)
})
