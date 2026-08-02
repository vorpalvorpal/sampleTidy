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

#' Phase-7b item 5: the ONE `work_order_reingest`/`blocked` guard row a test
#' fixture is expected to have written - fetched with its typed `kind`/
#' `subkind` columns AND its JSON `payload` (parsed for `n_rows_blocked`), so
#' a blocking assertion can check more than "some review row of some kind
#' exists" (the pre-existing `expect_gt(count_rows(...), before_review)`
#' checks nothing about WHICH item landed).
guard_review_row <- function(con) {
  row <- DBI::dbGetQuery(con,
    # Round-2 item 2: `work_order` added to the SELECT so a test can assert
    # the typed column, not just the JSON payload's own `work_order` field -
    # the two used to be able to disagree (payload built from the guard's
    # `wo`, column overwritten with `event$work_order`).
    "SELECT kind, subkind, work_order, payload FROM review_queue WHERE kind = 'work_order_reingest'")
  row
}

#' Local copies of test-reconcile.R's `mk_row`/`mk_event` builders (verbatim,
#' lines ~18-50 there) - no cross-file name collision since each testthat
#' test file runs in its own environment. Needed here to drive a REAL
#' reconcile_event() re-ingest against the analysis this file's commit_event()
#' just stored (R-8.7/A63 conversion_constant idempotency, below).
mk_row <- function(...) {
  defaults <- list(
    source_hash = "hash-1", source_ref = "row1", work_order = "XX1234567",
    revision = 0L, org = "ALS", adapter = "esdat/1",
    lab_sample_id = "XX1234567001", sample_type = "Normal",
    feature_raw = "T.S01", analyte_raw = "Fluoride",
    cas_number = "16984-48-8", method_raw = "EK040P: Fluoride by PC Titrator",
    total_or_filtered = "T", units_raw = "mg/L", value_raw = "<0.1",
    value_num = 0.1, value_chr = NA_character_, below_detection = TRUE,
    rl = 0.1, lab_qualifier = NA_character_, analysed_date = as.Date("2025-05-26"),
    comments = NA_character_, confidence = 1,
    sample_datetime_raw = "24 May 2025 11:45", sampler = NA_character_,
    matrix_raw = "WATER", parent_sample = NA_character_
  )
  args <- utils::modifyList(defaults, list(...))
  tibble::as_tibble(args)
}

mk_event <- function(results, work_order = "XX1234567", orphan = FALSE) {
  list(
    work_order = work_order, orphan = orphan, results = results,
    samples = tibble::tibble(),
    files = tibble::tibble(hash = character(), filename = character(),
                           adapter = character(), rank = integer(), kept = logical()),
    report = list(n_results = nrow(results), n_by_sample_type = list(),
                  n_ncp_foreign = 0L,
                  skipped = tibble::tibble(hash = character(), source_ref = character(),
                                          reason = character()),
                  warnings = character())
  )
}

# ---- R-9.2 criteria -------------------------------------------------------

test_that("R-9.2: committing new clean rows creates exactly matching sample/analysis counts", {
  setup <- commit_test_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  files <- tibble::tibble(hash = setup$hash, filename = basename(setup$path),
                          adapter = "esdat/1", rank = 3L, kept = TRUE)
  event <- mk_commit_event(files)
  clean <- dplyr::bind_rows(
    mk_clean_row(source_ref = "r1", source_hash = setup$hash, uuid_feature = "f-0001",
                 uuid_lab = "lm-0001", uuid_analyte = "a-0001",
                 sample_date = as.Date("2025-06-10")),
    mk_clean_row(source_ref = "r2", source_hash = setup$hash, uuid_feature = "f-0002",
                 uuid_lab = "lm-0003", uuid_analyte = "a-0003", analyte_raw = "Electrical Conductivity @ 25\u00b0C",
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

  # A44: the stored sample date must read back as the intended calendar day.
  # Building midnight in AEST would shift it to the previous day on write (the
  # duckdb driver stores POSIXct as UTC), which desynced cross-run sample reuse.
  # sample.uuid_feature was DROPPED (R-11.2/A48); reach the feature through the
  # alias the sample points at.
  new_dates <- DBI::dbGetQuery(con,
    "SELECT CAST(s.date AS DATE) AS d FROM \"sample\" s
       JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
      WHERE fa.uuid_feature IN ('f-0001','f-0002')
        AND s.uuid NOT IN ('s-0001','s-0002','s-0003','s-0004')")
  expect_setequal(as.character(new_dates$d), c("2025-06-10", "2025-06-11"))
})

test_that("R-9.2: a second commit_event() call on already-terminal files aborts", {
  setup <- commit_test_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

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
  # withr::defer, not on.exit: this block mocks bindings, and on.exit()
  # defaults to add = FALSE, which would discard local_mocked_bindings()'s own
  # restore handler and leak the mock into every later test in this file.
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

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
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

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
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  files <- tibble::tibble(hash = setup$hash, filename = basename(setup$path),
                          adapter = "esdat/1", rank = 3L, kept = TRUE)
  event <- mk_commit_event(files)
  clean <- mk_clean_row(source_ref = "r1", source_hash = setup$hash)
  resolved <- mk_resolved(clean = clean)

  commit_event(event, resolved, con)

  new_analysis <- DBI::dbGetQuery(con,
    "SELECT uuid FROM analysis WHERE uuid NOT IN ('an-0001','an-0002','an-0003','an-0004','an-0005')")
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
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

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
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

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

# ---- Plan 11 (R-11.8 commit-time materialisation, R-11.9 commit-side
#      alias_uuid payload rewrite, R-11.16 quantified/rl_high, R-11.18
#      distinct-datetime samplings) ------------------------------------------
#
# `resolved$clean` reaching commit_event() after the plan-11 reconcile
# rewrite (a different unit's file - R-11.5/R-11.6/R-11.7) carries columns
# beyond the plan-09 shape above: `feature_pending` (lgl), `alias_key` (chr,
# .rc_feature_key(feature_raw)), `uuid_feature_alias` (chr, NA when pending),
# `analyte_pending` (lgl), `org` (chr, reporting organisation), `method_raw`,
# `units_raw`, `quantified` (lgl, from parse_value(), never re-derived from
# `below_detection`), `rl_high` (dbl, from parse_value(), for `>`-rows).
# Built directly here per this file's own top-of-file convention -
# independent of plan-08's implementation status.

mk_p11_row <- function(...) {
  defaults <- list(
    source_hash = "p11-hash-x", source_ref = "row1", work_order = "XX1234567", revision = 0L,
    org = "ALS",
    feature_raw = "T.S01", alias_key = .rc_feature_key("T.S01"),
    feature_pending = FALSE, uuid_feature_alias = "fa-0001",
    analyte_raw = "pH Value", method_raw = "EA005P: pH by PC Titrator", units_raw = "pH Unit",
    analyte_pending = FALSE, uuid_lab = "lm-0001", uuid_analyte = "a-0001",
    value_raw = "6.50", value_num = 6.50, value_chr = NA_character_,
    value_converted = 6.50, below_detection = FALSE, quantified = TRUE,
    rl_low = NA_real_, rl_high = NA_real_, rl_converted = NA_real_,
    sample_date = as.Date("2025-06-10"),
    sample_datetime = as.POSIXct("2025-06-10 09:00:00", tz = "UTC"),
    sampler = NA_character_, comments = NA_character_, supersedes = NA_character_
  )
  args <- utils::modifyList(defaults, list(...))
  tibble::as_tibble(args)
}

#' Insert a second `reconciled` ingest_file row (a distinct hash) into the
#' SAME `commit_test_setup()` connection - for two-commit idempotency tests.
add_second_reconciled_file <- function(setup, filename) {
  path2 <- file.path(dirname(setup$path), filename)
  writeLines(paste("SampleCode,ChemCode", filename), path2)
  hash2 <- hash_file(path2)
  DBI::dbExecute(setup$con, sprintf(
    "INSERT INTO ingest_file (hash, filename, path_first_seen, state, work_order, revision)
     VALUES ('%s', '%s', '%s', 'reconciled', '%s', %d)",
    hash2, basename(path2), path2, setup$work_order, 0L
  ))
  list(hash = hash2, path = path2)
}

#' Register a NEW `reconciled` ingest_file row (its own hash/filename) against
#' the SAME `commit_test_setup()` connection, with a caller-chosen work_order
#' and revision - PLAN-15 F.10's re-ingest-guard tests need several distinctly
#' -named files against one (or more) work orders, some sharing revisions,
#' some not. Parameterised (not sprintf'd) so a work_order containing a SPACE
#' (the ACIRL false-split fixture below) round-trips safely.
add_reconciled_file <- function(setup, filename, work_order = setup$work_order, revision = 0L) {
  path <- file.path(dirname(setup$path), filename)
  writeLines(paste("SampleCode,ChemCode", filename), path)
  hash <- hash_file(path)
  DBI::dbExecute(setup$con, "INSERT INTO ingest_file
    (hash, filename, path_first_seen, state, work_order, revision)
    VALUES (?, ?, ?, 'reconciled', ?, ?)",
    params = list(hash, basename(path), path, work_order, as.integer(revision)))
  list(hash = hash, path = path)
}

dangling_alias_row <- function(con, alias_key) {
  DBI::dbGetQuery(con, "SELECT * FROM feature_alias WHERE alias_key = ? AND uuid_feature IS NULL",
                   params = list(alias_key))
}

dangling_lab_method_rows <- function(con, organisation) {
  DBI::dbGetQuery(con, "SELECT * FROM lab_method WHERE organisation = ? AND uuid_analyte IS NULL",
                   params = list(organisation))
}

# ---- R-11.8: materialise pending aliases and dangling methods --------------

test_that("R-11.8: a file with a resolved row and an unknown-feature row commits BOTH; the dangling row is invisible to a feature-joined view; ingest_file archives legitimately (C20 corollary)", {
  setup <- commit_test_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  files <- tibble::tibble(hash = setup$hash, filename = basename(setup$path),
                          adapter = "esdat/1", rank = 3L, kept = TRUE)
  event <- mk_commit_event(files)
  clean <- dplyr::bind_rows(
    mk_p11_row(source_ref = "r1", source_hash = setup$hash,
               sample_date = as.Date("2025-07-01"),
               sample_datetime = as.POSIXct("2025-07-01 09:00:00", tz = "UTC")),
    mk_p11_row(source_ref = "r2", source_hash = setup$hash,
               feature_raw = "T.NEVER-SEEN-C20", alias_key = .rc_feature_key("T.NEVER-SEEN-C20"),
               feature_pending = TRUE, uuid_feature_alias = NA_character_,
               sample_date = as.Date("2025-07-01"),
               sample_datetime = as.POSIXct("2025-07-01 09:00:00", tz = "UTC"))
  )
  resolved <- mk_resolved(clean = clean)

  before_analysis <- count_rows(con, "analysis")
  commit_event(event, resolved, con)
  expect_equal(count_rows(con, "analysis") - before_analysis, 2)

  new_analyses <- DBI::dbGetQuery(con,
    "SELECT uuid FROM analysis WHERE uuid NOT IN ('an-0001','an-0002','an-0003','an-0004','an-0005')")
  expect_equal(nrow(new_analyses), 2)

  # the dangling row's analysis is invisible to a feature-joined view; the
  # resolved row's is visible - exactly one of the two survives the join.
  visible <- DBI::dbGetQuery(con, '
    SELECT a.uuid AS analysis_uuid
    FROM analysis a
    JOIN "sample" s ON s.uuid = a.uuid_sample
    JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
    JOIN feature f ON f.uuid = fa.uuid_feature
    WHERE a.uuid NOT IN (\'an-0001\',\'an-0002\',\'an-0003\',\'an-0004\',\'an-0005\')
  ')
  expect_equal(nrow(visible), 1)

  state_row <- DBI::dbGetQuery(con, "SELECT state FROM ingest_file WHERE hash = ?", params = list(setup$hash))
  expect_identical(state_row$state[[1]], "archived")

  alias <- dangling_alias_row(con, .rc_feature_key("T.NEVER-SEEN-C20"))
  expect_equal(nrow(alias), 1)
  expect_true(is.na(alias$uuid_feature[[1]]))
  expect_identical(alias$kind[[1]], "pending")
  expect_false(alias$auto_assign[[1]])
})

test_that("R-11.8(a,c): two commits of the same still-unknown feature reuse ONE dangling feature_alias, and n_seen counts one per referencing sample (idempotent find-or-create)", {
  setup <- commit_test_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  key <- .rc_feature_key("T.DEDUPE-FEAT")

  files1 <- tibble::tibble(hash = setup$hash, filename = basename(setup$path),
                           adapter = "esdat/1", rank = 3L, kept = TRUE)
  clean1 <- mk_p11_row(source_ref = "r1", source_hash = setup$hash,
                        feature_raw = "T.DEDUPE-FEAT", alias_key = key,
                        feature_pending = TRUE, uuid_feature_alias = NA_character_,
                        sample_date = as.Date("2025-07-05"),
                        sample_datetime = as.POSIXct("2025-07-05 09:00:00", tz = "UTC"))
  commit_event(mk_commit_event(files1), mk_resolved(clean = clean1), con)

  # The SECOND commit goes to its own work order, NOT the seeded XX1234567.
  # Not incidental tidying - do not move it back: PLAN-15 F.10's re-ingest
  # guard blocks a second, differently-named file arriving against a work
  # order that already holds samples, which is exactly the shape of a
  # two-commit fixture sharing one work order. Nothing here is about work
  # orders; alias reuse ACROSS work orders is the stronger property anyway,
  # and every assertion below is unchanged.
  second <- add_reconciled_file(setup, "second_file.CSV", work_order = "XX7654321")
  files2 <- tibble::tibble(hash = second$hash, filename = basename(second$path),
                           adapter = "esdat/1", rank = 3L, kept = TRUE)
  clean2 <- mk_p11_row(source_ref = "r1", source_hash = second$hash,
                        work_order = "XX7654321",
                        feature_raw = "T.DEDUPE-FEAT", alias_key = key,
                        feature_pending = TRUE, uuid_feature_alias = NA_character_,
                        sample_date = as.Date("2025-07-06"),
                        sample_datetime = as.POSIXct("2025-07-06 09:00:00", tz = "UTC"))
  commit_event(mk_commit_event(files2, work_order = "XX7654321"),
               mk_resolved(clean = clean2), con)

  aliases <- dangling_alias_row(con, key)
  expect_equal(nrow(aliases), 1)
  expect_equal(aliases$n_seen[[1]], 2)
})

test_that("R-11.8(a,c)/M4: a RESOLVED feature_alias sharing the alias_key is left untouched; committing a pending row creates a NEW distinct pending alias (find-or-create excludes resolved aliases)", {
  setup <- commit_test_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  key <- .rc_feature_key("T.SHARED-KEY-M4")

  # Pre-seed a RESOLVED alias (uuid_feature NOT NULL) sharing alias_key = key.
  # The find-or-create in .ct_materialise_feature_aliases keys its lookup on
  # `WHERE alias_key = ? AND uuid_feature IS NULL` - dropping the
  # `uuid_feature IS NULL` guard would let this resolved row match instead of
  # creating a new pending one.
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign, first_seen, last_seen, confirmed_by, comments)
    VALUES ('fa-m4-resolved', 'f-0001', 'T.SHARED-KEY-M4-OLD', ?, 'historical_code', 5, TRUE,
            TIMESTAMP '2020-01-01 00:00:00', TIMESTAMP '2020-01-01 00:00:00', NULL, NULL)",
    params = list(key))

  files <- tibble::tibble(hash = setup$hash, filename = basename(setup$path),
                          adapter = "esdat/1", rank = 3L, kept = TRUE)
  clean <- mk_p11_row(source_ref = "r1", source_hash = setup$hash,
                       feature_raw = "T.SHARED-KEY-M4", alias_key = key,
                       feature_pending = TRUE, uuid_feature_alias = NA_character_,
                       sample_date = as.Date("2025-07-10"),
                       sample_datetime = as.POSIXct("2025-07-10 09:00:00", tz = "UTC"))
  commit_event(mk_commit_event(files), mk_resolved(clean = clean), con)

  resolved_after <- DBI::dbGetQuery(con, "SELECT * FROM feature_alias WHERE uuid = 'fa-m4-resolved'")
  expect_equal(nrow(resolved_after), 1)
  expect_equal(resolved_after$n_seen[[1]], 5)
  expect_false(is.na(resolved_after$uuid_feature[[1]]))

  pending <- dangling_alias_row(con, key)
  expect_equal(nrow(pending), 1)
  expect_false(identical(pending$uuid[[1]], "fa-m4-resolved"))
  expect_identical(pending$kind[[1]], "pending")
})

test_that("R-11.8(e)/M5: two rows in the SAME commit event, same analyte, differing ONLY in method raw casing, reuse ONE dangling lab_method (intra-event dedup uses .rc_method_key, not the raw string)", {
  setup <- commit_test_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  # Both rows land in the SAME commit_event() call (a single event), so this
  # exercises the intra-event dedup key at commit.R:178
  # (`paste(clean$org, .rc_method_key(analyte_raw), .rc_method_key(method_raw))`), never
  # the cross-file DB-lookup path the R-11.8(e) two-commit test above covers.
  # Distinct features/sample times keep both rows alive through sample
  # creation and analysis commit, so both reach lab_method materialisation.
  files <- tibble::tibble(hash = setup$hash, filename = basename(setup$path),
                          adapter = "esdat/1", rank = 3L, kept = TRUE)
  clean <- dplyr::bind_rows(
    mk_p11_row(source_ref = "r1", source_hash = setup$hash,
               feature_raw = "T.S01", alias_key = .rc_feature_key("T.S01"),
               feature_pending = FALSE, uuid_feature_alias = "fa-0001",
               analyte_raw = "T.DEDUPE-ANALYTE-M5", method_raw = "T.DEDUPE-METHOD-M5",
               analyte_pending = TRUE, uuid_lab = NA_character_, uuid_analyte = NA_character_,
               units_raw = "mg/L",
               sample_date = as.Date("2025-07-09"),
               sample_datetime = as.POSIXct("2025-07-09 09:00:00", tz = "UTC")),
    mk_p11_row(source_ref = "r2", source_hash = setup$hash,
               feature_raw = "T.S02", alias_key = .rc_feature_key("T.S02"),
               feature_pending = FALSE, uuid_feature_alias = "fa-0002",
               analyte_raw = "t.dedupe-analyte-m5", method_raw = "t.dedupe-method-m5",
               analyte_pending = TRUE, uuid_lab = NA_character_, uuid_analyte = NA_character_,
               units_raw = "mg/L",
               sample_date = as.Date("2025-07-09"),
               sample_datetime = as.POSIXct("2025-07-09 10:00:00", tz = "UTC"))
  )
  commit_event(mk_commit_event(files), mk_resolved(clean = clean), con)

  dangling <- dangling_lab_method_rows(con, "ALS")
  matching <- dangling[!is.na(dangling$name) & .rc_method_key(dangling$name) == .rc_method_key("T.DEDUPE-ANALYTE-M5") &
                          !is.na(dangling$method) & .rc_method_key(dangling$method) == .rc_method_key("T.DEDUPE-METHOD-M5"), , drop = FALSE]
  expect_equal(nrow(matching), 1)
})

test_that("R-11.8(e): two commits of the same unknown analyte, differing ONLY in raw casing, reuse ONE dangling lab_method (dedup uses .rc_method_key, not raw string)", {
  setup <- commit_test_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  files1 <- tibble::tibble(hash = setup$hash, filename = basename(setup$path),
                           adapter = "esdat/1", rank = 3L, kept = TRUE)
  clean1 <- mk_p11_row(source_ref = "r1", source_hash = setup$hash,
                        analyte_raw = "T.DEDUPE-ANALYTE", method_raw = "T.DEDUPE-METHOD",
                        analyte_pending = TRUE, uuid_lab = NA_character_, uuid_analyte = NA_character_,
                        units_raw = "mg/L",
                        sample_date = as.Date("2025-07-07"),
                        sample_datetime = as.POSIXct("2025-07-07 09:00:00", tz = "UTC"))
  commit_event(mk_commit_event(files1), mk_resolved(clean = clean1), con)

  second <- add_second_reconciled_file(setup, "second_analyte_file.CSV")
  files2 <- tibble::tibble(hash = second$hash, filename = basename(second$path),
                           adapter = "esdat/1", rank = 3L, kept = TRUE)
  clean2 <- mk_p11_row(source_ref = "r1", source_hash = second$hash,
                        analyte_raw = "T.Dedupe-Analyte", method_raw = "t.dedupe-method",
                        analyte_pending = TRUE, uuid_lab = NA_character_, uuid_analyte = NA_character_,
                        units_raw = "mg/L",
                        sample_date = as.Date("2025-07-08"),
                        sample_datetime = as.POSIXct("2025-07-08 09:00:00", tz = "UTC"))
  commit_event(mk_commit_event(files2), mk_resolved(clean = clean2), con)

  dangling <- dangling_lab_method_rows(con, "ALS")
  matching <- dangling[!is.na(dangling$name) & .rc_method_key(dangling$name) == .rc_method_key("T.DEDUPE-ANALYTE") &
                          !is.na(dangling$method) & .rc_method_key(dangling$method) == .rc_method_key("T.DEDUPE-METHOD"), , drop = FALSE]
  expect_equal(nrow(matching), 1)
  expect_true(is.na(matching$conversion_constant[[1]]))
})

test_that("R-11.8/A63 (D7 reversed): a pending-analyte row's reported units land on lab_method.units, nowhere on analysis; conversion_constant stays NA", {
  setup <- commit_test_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  files <- tibble::tibble(hash = setup$hash, filename = basename(setup$path),
                          adapter = "esdat/1", rank = 3L, kept = TRUE)
  clean <- mk_p11_row(source_ref = "r1", source_hash = setup$hash,
                       analyte_raw = "EC New Units Method", method_raw = "EA010Z-units-test",
                       analyte_pending = TRUE, uuid_lab = NA_character_, uuid_analyte = NA_character_,
                       units_raw = "\u00b5S/cm", value_num = 965, value_converted = 965,
                       sample_date = as.Date("2025-07-09"),
                       sample_datetime = as.POSIXct("2025-07-09 09:00:00", tz = "UTC"))
  commit_event(mk_commit_event(files), mk_resolved(clean = clean), con)

  dangling <- dangling_lab_method_rows(con, "ALS")
  hit <- dangling[!is.na(dangling$name) & .rc_method_key(dangling$name) == .rc_method_key("EC New Units Method"), , drop = FALSE]
  expect_equal(nrow(hit), 1)
  expect_identical(hit$units[[1]], "\u00b5S/cm")
  expect_true(is.na(hit$conversion_constant[[1]]))

  expect_false("units" %in% DBI::dbListFields(con, "analysis"))
  expect_false("units_raw" %in% DBI::dbListFields(con, "analysis"))
})

test_that("R-11.8(f): a committing row's units_raw drift from an existing dangling lab_method's recorded units is RECORDED as a change_log provenance row, reuses the SAME uuid_lab, and leaves lab_method.units unchanged", {
  setup <- commit_test_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  files1 <- tibble::tibble(hash = setup$hash, filename = basename(setup$path),
                           adapter = "esdat/1", rank = 3L, kept = TRUE)
  clean1 <- mk_p11_row(source_ref = "r1", source_hash = setup$hash,
                        analyte_raw = "T.DRIFT-ANALYTE", method_raw = "T.DRIFT-METHOD",
                        analyte_pending = TRUE, uuid_lab = NA_character_, uuid_analyte = NA_character_,
                        units_raw = "mg/L",
                        sample_date = as.Date("2025-07-11"),
                        sample_datetime = as.POSIXct("2025-07-11 09:00:00", tz = "UTC"))
  commit_event(mk_commit_event(files1), mk_resolved(clean = clean1), con)

  dangling <- dangling_lab_method_rows(con, "ALS")
  matching <- dangling[!is.na(dangling$name) & .rc_method_key(dangling$name) == .rc_method_key("T.DRIFT-ANALYTE") &
                          !is.na(dangling$method) & .rc_method_key(dangling$method) == .rc_method_key("T.DRIFT-METHOD"), , drop = FALSE]
  expect_equal(nrow(matching), 1)
  lab_uuid <- matching$uuid[[1]]
  expect_identical(matching$units[[1]], "mg/L")

  # Second commit on its own work order, NOT the seeded XX1234567 - same
  # reason as R-11.8(a,c) above: PLAN-15 F.10's re-ingest guard blocks a
  # second differently-named file against a work order that already holds
  # samples. This block is about `lab_method` units drift and asserts nothing
  # about work orders; no assertion changed when it moved.
  second <- add_reconciled_file(setup, "drift_file.CSV", work_order = "XX7654321")
  files2 <- tibble::tibble(hash = second$hash, filename = basename(second$path),
                           adapter = "esdat/1", rank = 3L, kept = TRUE)
  clean2 <- mk_p11_row(source_ref = "r1", source_hash = second$hash,
                        work_order = "XX7654321",
                        analyte_raw = "T.DRIFT-ANALYTE", method_raw = "T.DRIFT-METHOD",
                        analyte_pending = TRUE, uuid_lab = NA_character_, uuid_analyte = NA_character_,
                        units_raw = "g/L",
                        sample_date = as.Date("2025-07-12"),
                        sample_datetime = as.POSIXct("2025-07-12 09:00:00", tz = "UTC"))
  commit_event(mk_commit_event(files2, work_order = "XX7654321"),
               mk_resolved(clean = clean2), con)

  dangling_after <- dangling_lab_method_rows(con, "ALS")
  matching_after <- dangling_after[!is.na(dangling_after$name) & .rc_method_key(dangling_after$name) == .rc_method_key("T.DRIFT-ANALYTE") &
                          !is.na(dangling_after$method) & .rc_method_key(dangling_after$method) == .rc_method_key("T.DRIFT-METHOD"), , drop = FALSE]
  expect_equal(nrow(matching_after), 1)
  expect_identical(matching_after$units[[1]], "mg/L")

  prov <- DBI::dbGetQuery(con, sprintf(
    "SELECT * FROM change_log WHERE action = 'provenance' AND tbl = 'lab_method' AND field = 'units' AND uuid_row = '%s'",
    lab_uuid))
  expect_equal(nrow(prov), 1)
  expect_identical(prov$old[[1]], "mg/L")
  expect_identical(prov$new[[1]], "g/L")
  expect_identical(prov$source_hash[[1]], second$hash)
  expect_true(grepl("sighting", prov$reason[[1]]))
})

test_that("R-11.9 (commit-side, D8): review payload carries a resolvable alias_uuid after commit (rewritten by the R-11.8 materialise step, seam S-8)", {
  setup <- commit_test_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  key <- .rc_feature_key("T.NEEDS-REVIEW-ALIAS")

  files <- tibble::tibble(hash = setup$hash, filename = basename(setup$path),
                          adapter = "esdat/1", rank = 3L, kept = TRUE)
  clean <- mk_p11_row(source_ref = "r1", source_hash = setup$hash,
                       feature_raw = "T.NEEDS-REVIEW-ALIAS", alias_key = key,
                       feature_pending = TRUE, uuid_feature_alias = NA_character_,
                       sample_date = as.Date("2025-07-10"),
                       sample_datetime = as.POSIXct("2025-07-10 09:00:00", tz = "UTC"))
  review <- tibble::tibble(
    source_ref = "r1", kind = "unknown_feature", source_hash = setup$hash,
    payload = "r1,feature_raw=T.NEEDS-REVIEW-ALIAS,work_order=XX1234567,n_rows=1"
  )
  resolved <- mk_resolved(clean = clean, review = review)

  commit_event(mk_commit_event(files), resolved, con)

  alias <- dangling_alias_row(con, key)
  expect_equal(nrow(alias), 1)

  stored <- DBI::dbGetQuery(con,
    "SELECT payload, uuid_alias FROM review_queue WHERE kind = 'unknown_feature' AND source_hash = ?",
    params = list(setup$hash))
  expect_equal(nrow(stored), 1)
  # PLAN-16 R-16.21: uuid_alias is the ONLY representation of the alias uuid -
  # a typed column, not an `alias_uuid=` fragment folded into the payload text.
  expect_identical(stored$uuid_alias[[1]], alias$uuid[[1]])
  expect_false(grepl("alias_uuid", stored$payload[[1]], fixed = TRUE))
})

test_that("round-2 audit FF3: .ct_rewrite_review_payloads() links uuid_alias for a GROUPED review item (comma-joined source_ref, >=2 rows) as well as a single-row item, real reconcile_event() -> commit_event() end to end", {
  setup <- commit_test_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  key_grouped <- .rc_feature_key("T.GROUPED-FF3")
  key_single <- .rc_feature_key("T.SINGLE-FF3")

  # Two rows share the SAME unresolved feature_raw (-> one GROUPED
  # unknown_feature review item, source_ref = "g1,g2" per .rc_feature_review(),
  # R/reconcile.R:669), plus one row with a DIFFERENT unresolved feature_raw
  # (-> a single-row item) - all in the SAME real reconcile_event() so both
  # arms are asserted from one .ct_rewrite_review_payloads() pass, per the
  # FF3 finding's "assert both arms" instruction.
  results <- dplyr::bind_rows(
    mk_row(source_ref = "g1", source_hash = setup$hash, feature_raw = "T.GROUPED-FF3",
           sample_datetime_raw = "10 Jul 2025 09:00"),
    mk_row(source_ref = "g2", source_hash = setup$hash, feature_raw = "T.GROUPED-FF3",
           sample_datetime_raw = "10 Jul 2025 10:00"),
    mk_row(source_ref = "s1", source_hash = setup$hash, feature_raw = "T.SINGLE-FF3",
           sample_datetime_raw = "10 Jul 2025 11:00")
  )
  event <- mk_event(results, work_order = setup$work_order)
  out <- reconcile_event(event, con)

  # Reproduction premise (task step 1): the grouped item's source_ref really
  # is comma-joined, and this event produced exactly two unknown_feature
  # review items (one grouped, one single).
  expect_equal(nrow(out$review), 2)
  grouped_review <- out$review[grepl(",", out$review$source_ref, fixed = TRUE), , drop = FALSE]
  single_review <- out$review[!grepl(",", out$review$source_ref, fixed = TRUE), , drop = FALSE]
  expect_equal(nrow(grouped_review), 1)
  expect_equal(nrow(single_review), 1)
  expect_identical(grouped_review$source_ref[[1]], "g1,g2")
  expect_identical(single_review$source_ref[[1]], "s1")

  files <- tibble::tibble(hash = setup$hash, filename = basename(setup$path),
                          adapter = "esdat/1", rank = 3L, kept = TRUE)
  resolved <- mk_resolved(clean = out$clean, review = out$review, skipped = out$skipped,
                          counts = c(new = nrow(out$clean)))
  commit_event(mk_commit_event(files, work_order = setup$work_order), resolved, con)

  alias_grouped <- dangling_alias_row(con, key_grouped)
  alias_single <- dangling_alias_row(con, key_single)
  expect_equal(nrow(alias_grouped), 1)
  expect_equal(nrow(alias_single), 1)

  # `review_queue` has no `source_ref` column (FF1, separate finding) - tell
  # the two committed rows apart by their `payload` diagnostics instead.
  stored <- DBI::dbGetQuery(con,
    "SELECT payload, uuid_alias FROM review_queue WHERE kind = 'unknown_feature' AND source_hash = ?",
    params = list(setup$hash))
  stored_grouped <- stored[grepl("T.GROUPED-FF3", stored$payload, fixed = TRUE), , drop = FALSE]
  stored_single <- stored[grepl("T.SINGLE-FF3", stored$payload, fixed = TRUE), , drop = FALSE]
  expect_equal(nrow(stored_grouped), 1)
  expect_equal(nrow(stored_single), 1)

  # The bug (pre-fix): the grouped item's uuid_alias stays NULL because the
  # exact-string join never matches "g1,g2" against per-row keys "g1"/"g2".
  # Each item must link to its OWN alias, never the other's (no mis-link).
  expect_false(is.na(stored_grouped$uuid_alias[[1]]))
  expect_identical(stored_grouped$uuid_alias[[1]], alias_grouped$uuid[[1]])
  expect_false(is.na(stored_single$uuid_alias[[1]]))
  expect_identical(stored_single$uuid_alias[[1]], alias_single$uuid[[1]])
  expect_false(identical(stored_grouped$uuid_alias[[1]], stored_single$uuid_alias[[1]]))
})

test_that("W-8b-f2: a two-file grouped unknown_feature review item still links uuid_alias when its FIRST member's row is dropped (seam S-4: .rc_feature_review() records only the first group member's source_hash, so the hash-keyed lookup misses for every ref and must fall back to the unique-or-nothing ref-only match)", {
  setup <- commit_test_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  second <- add_second_reconciled_file(setup, "PROJ_A.ESDAT_XX1234567_0.Chemistry2b.CSV")

  key <- .rc_feature_key("ZZ.X9-W8BF2")

  # Two rows share ONE unresolved feature_raw (-> one grouped unknown_feature
  # review item, source_ref = "r1,r2"), but come from TWO different source
  # files. The first group member (setup$hash / r1) carries an unparseable
  # datetime and is dropped before it reaches `clean`; the second (second$hash
  # / r2) survives and is what actually materialises the alias at commit.
  results <- dplyr::bind_rows(
    mk_row(source_ref = "r1", source_hash = setup$hash, feature_raw = "ZZ.X9-W8BF2",
           sample_datetime_raw = "not a date"),
    mk_row(source_ref = "r2", source_hash = second$hash, feature_raw = "ZZ.X9-W8BF2",
           sample_datetime_raw = "10 Jul 2025 09:00")
  )
  event <- mk_event(results, work_order = setup$work_order)
  out <- reconcile_event(event, con)

  uf <- out$review[out$review$kind == "unknown_feature", , drop = FALSE]
  expect_equal(nrow(uf), 1)
  expect_identical(uf$source_ref[[1]], "r1,r2")
  # Reproduction premise: seam S-4 records only the FIRST group member's hash.
  expect_identical(uf$source_hash[[1]], setup$hash)
  expect_equal(nrow(out$clean), 1)
  expect_identical(out$clean$source_hash[[1]], second$hash)

  files <- tibble::tibble(hash = c(setup$hash, second$hash),
                          filename = c(basename(setup$path), basename(second$path)),
                          adapter = "esdat/1", rank = 3L, kept = TRUE)
  resolved <- mk_resolved(clean = out$clean, review = out$review, skipped = out$skipped,
                          counts = c(new = nrow(out$clean)))
  commit_event(mk_commit_event(files, work_order = setup$work_order), resolved, con)

  alias <- dangling_alias_row(con, key)
  expect_equal(nrow(alias), 1)

  stored <- DBI::dbGetQuery(con,
    "SELECT uuid_alias FROM review_queue WHERE kind = 'unknown_feature' AND source_hash = ?",
    params = list(setup$hash))
  expect_equal(nrow(stored), 1)
  # Pre-fix: this was NA - the hash-keyed lookup only ever tried
  # setup$hash\x01r1 / setup$hash\x01r2, both misses, because the alias was
  # materialised from second$hash's row.
  expect_false(is.na(stored$uuid_alias[[1]]))
  expect_identical(stored$uuid_alias[[1]], alias$uuid[[1]])
})

test_that("W-8b-f2 (guard, holds before AND after the fix - do not repin): the ref-only fallback is unique-or-nothing - two DIFFERENT source files sharing one source_ref value that resolve to DIFFERENT aliases leaves uuid_alias NULL rather than picking either candidate", {
  # This guards the anti-mis-link property the source_hash key exists for. A
  # mis-link (attaching the wrong alias to a review item) is worse than the
  # missing link W-8b-f2 fixes above, because uuid_alias is what a human uses
  # to accept the alias (review_queue_close(), R-16.21). Do NOT edit this
  # test to expect a non-NULL uuid_alias if it starts "failing" - that would
  # be re-introducing the hazard, not fixing a bug.
  setup <- commit_test_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  key_a <- .rc_feature_key("AA.GUARD-W8BF2")
  key_b <- .rc_feature_key("BB.GUARD-W8BF2")

  files <- tibble::tibble(hash = setup$hash, filename = basename(setup$path),
                          adapter = "esdat/1", rank = 3L, kept = TRUE)
  # Two UNRELATED pending rows from two different files happen to share the
  # same source_ref ("rX") - only plausible because source_ref is only
  # unique WITHIN one source file. They resolve to two DIFFERENT aliases.
  clean <- dplyr::bind_rows(
    mk_p11_row(source_ref = "rX", source_hash = setup$hash,
               feature_raw = "AA.GUARD-W8BF2", alias_key = key_a,
               feature_pending = TRUE, uuid_feature_alias = NA_character_,
               sample_date = as.Date("2025-07-11"),
               sample_datetime = as.POSIXct("2025-07-11 09:00:00", tz = "UTC")),
    mk_p11_row(source_ref = "rX", source_hash = "w8bf2-other-file-hash",
               feature_raw = "BB.GUARD-W8BF2", alias_key = key_b,
               feature_pending = TRUE, uuid_feature_alias = NA_character_,
               sample_date = as.Date("2025-07-11"),
               sample_datetime = as.POSIXct("2025-07-11 10:00:00", tz = "UTC"))
  )
  # The review row's OWN source_hash matches NEITHER clean row above, so the
  # hash-keyed lookup misses for every ref and falls through to the
  # hash-agnostic ref-only fallback - the only code path that could trigger
  # the hazard this test guards against.
  review <- tibble::tibble(
    source_ref = "rX", kind = "unknown_feature", source_hash = "w8bf2-third-unrelated-hash",
    payload = "rX,work_order=XX1234567,n_rows=1"
  )
  resolved <- mk_resolved(clean = clean, review = review)

  commit_event(mk_commit_event(files, work_order = setup$work_order), resolved, con)

  alias_a <- dangling_alias_row(con, key_a)
  alias_b <- dangling_alias_row(con, key_b)
  expect_equal(nrow(alias_a), 1)
  expect_equal(nrow(alias_b), 1)
  expect_false(identical(alias_a$uuid[[1]], alias_b$uuid[[1]]))

  stored <- DBI::dbGetQuery(con,
    "SELECT uuid_alias FROM review_queue WHERE kind = 'unknown_feature' AND source_hash = ?",
    params = list("w8bf2-third-unrelated-hash"))
  expect_equal(nrow(stored), 1)
  expect_true(is.na(stored$uuid_alias[[1]]))
})

# ---- Phase 7b item 6: a positive test for the source_hash half of the key -

test_that("Phase-7b item 6: two review items sharing ONE source_ref, each carrying the source_hash of its OWN file, link to THEIR OWN (distinct) alias - the hash-keyed match, not the ref-only fallback", {
  # W-8b-f2's guard test above proves the ref-only fallback correctly REFUSES
  # to link an ambiguous ref. This proves the positive half: when each review
  # row's OWN source_hash correctly identifies which file it belongs to, the
  # hash-keyed lookup links it to that file's alias directly - the property
  # the roxygen on .ct_rewrite_review_payloads() spends 15 lines justifying,
  # and which had no test exercising the hash key actually doing its job.
  setup <- commit_test_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  key_a <- .rc_feature_key("AA.ITEM6-HASH")
  key_b <- .rc_feature_key("BB.ITEM6-HASH")

  files <- tibble::tibble(hash = setup$hash, filename = basename(setup$path),
                          adapter = "esdat/1", rank = 3L, kept = TRUE)
  # Two pending rows, SAME source_ref ("r1"), from TWO DIFFERENT files
  # (different source_hash), resolving to TWO DIFFERENT aliases - the exact
  # ambiguous-ref shape the ref-only fallback must refuse, but which the
  # hash-keyed lookup resolves correctly because each review item below
  # carries the CORRECT file's own source_hash.
  clean <- dplyr::bind_rows(
    mk_p11_row(source_ref = "r1", source_hash = setup$hash,
               feature_raw = "AA.ITEM6-HASH", alias_key = key_a,
               feature_pending = TRUE, uuid_feature_alias = NA_character_,
               sample_date = as.Date("2025-07-20"),
               sample_datetime = as.POSIXct("2025-07-20 09:00:00", tz = "UTC")),
    mk_p11_row(source_ref = "r1", source_hash = "item6-other-file-hash",
               feature_raw = "BB.ITEM6-HASH", alias_key = key_b,
               feature_pending = TRUE, uuid_feature_alias = NA_character_,
               sample_date = as.Date("2025-07-20"),
               sample_datetime = as.POSIXct("2025-07-20 10:00:00", tz = "UTC"))
  )
  review <- tibble::tibble(
    source_ref = c("r1", "r1"), kind = c("unknown_feature", "unknown_feature"),
    source_hash = c(setup$hash, "item6-other-file-hash"),
    payload = c("r1,work_order=XX1234567,n_rows=1", "r1,work_order=XX1234567,n_rows=1")
  )
  resolved <- mk_resolved(clean = clean, review = review)

  commit_event(mk_commit_event(files, work_order = setup$work_order), resolved, con)

  alias_a <- dangling_alias_row(con, key_a)
  alias_b <- dangling_alias_row(con, key_b)
  expect_equal(nrow(alias_a), 1)
  expect_equal(nrow(alias_b), 1)
  expect_false(identical(alias_a$uuid[[1]], alias_b$uuid[[1]]))

  stored_a <- DBI::dbGetQuery(con,
    "SELECT uuid_alias FROM review_queue WHERE kind = 'unknown_feature' AND source_hash = ?",
    params = list(setup$hash))
  stored_b <- DBI::dbGetQuery(con,
    "SELECT uuid_alias FROM review_queue WHERE kind = 'unknown_feature' AND source_hash = ?",
    params = list("item6-other-file-hash"))
  expect_equal(nrow(stored_a), 1)
  expect_equal(nrow(stored_b), 1)
  # Pre-fix (mutation `hit <- character(0)`): the hash-keyed lookup never
  # matches ANYTHING, so both items fall through to the ref-only fallback,
  # which sees ONE ref ("r1") mapping to TWO distinct aliases and correctly
  # (per W-8b-f2's guard) refuses to link EITHER - both would be NA here,
  # not just one.
  expect_identical(stored_a$uuid_alias[[1]], alias_a$uuid[[1]])
  expect_identical(stored_b$uuid_alias[[1]], alias_b$uuid[[1]])
})

# ---- PLAN-16 Q2 (Robin 2026-07-25): source_ref/n_rows survive the commit
#      boundary INSIDE diagnostics, because review_queue has no column for
#      either one ---------------------------------------------------------

test_that("PLAN-16 Q2: a real reconcile_event() -> commit_event() stores source_ref and n_rows in the committed payload's diagnostics - as a JSON ARRAY plus n_rows=2 for a GROUPED item and a scalar plus n_rows=1 for a single-row item", {
  setup <- commit_test_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  # Same shape as the FF3 fixture above: two rows sharing one unresolved
  # feature_raw (-> ONE grouped review item over two source rows) plus one row
  # with a different unresolved feature_raw (-> a single-row item). The grouped
  # arm is the load-bearing one: it is the only case where source_ref is
  # plural, so it is the only case that can tell a real vector apart from a
  # comma-joined string that merely looks like one.
  results <- dplyr::bind_rows(
    mk_row(source_ref = "g1", source_hash = setup$hash, feature_raw = "T.GROUPED-Q2",
           sample_datetime_raw = "10 Jul 2025 09:00"),
    mk_row(source_ref = "g2", source_hash = setup$hash, feature_raw = "T.GROUPED-Q2",
           sample_datetime_raw = "10 Jul 2025 10:00"),
    mk_row(source_ref = "s1", source_hash = setup$hash, feature_raw = "T.SINGLE-Q2",
           sample_datetime_raw = "10 Jul 2025 11:00")
  )
  event <- mk_event(results, work_order = setup$work_order)
  out <- reconcile_event(event, con)
  expect_equal(nrow(out$review), 2)

  files <- tibble::tibble(hash = setup$hash, filename = basename(setup$path),
                          adapter = "esdat/1", rank = 3L, kept = TRUE)
  resolved <- mk_resolved(clean = out$clean, review = out$review, skipped = out$skipped,
                          counts = c(new = nrow(out$clean)))
  commit_event(mk_commit_event(files, work_order = setup$work_order), resolved, con)

  stored <- DBI::dbGetQuery(con,
    "SELECT payload FROM review_queue WHERE kind = 'unknown_feature' AND source_hash = ?",
    params = list(setup$hash))
  expect_equal(nrow(stored), 2)

  # Parse with simplifyVector = FALSE so a length-1 array and a scalar stay
  # DISTINGUISHABLE: jsonlite's default simplification would collapse both to a
  # length-1 character vector and the array-vs-scalar assertion would be
  # vacuous. Read the raw TEXT too, so a driver-side or parser-side
  # normalisation cannot fake either shape.
  diags <- lapply(stored$payload, jsonlite::fromJSON, simplifyVector = FALSE)
  names(diags) <- vapply(stored$payload, function(p) {
    if (grepl("T.GROUPED-Q2", p, fixed = TRUE)) "grouped" else "single"
  }, character(1))
  expect_setequal(names(diags), c("grouped", "single"))

  # GROUPED: source_ref is a two-element array, in source order, and n_rows
  # reports 2 - the count of folded source rows, not 1 (the review item count).
  expect_identical(diags$grouped$source_ref, list("g1", "g2"))
  expect_identical(diags$grouped$n_rows, 2L)
  grouped_text <- stored$payload[grepl("T.GROUPED-Q2", stored$payload, fixed = TRUE)][[1]]
  expect_match(grouped_text, '"source_ref":\\["g1","g2"\\]')
  expect_match(grouped_text, '"n_rows":2')

  # SINGLE: source_ref is a ONE-ELEMENT ARRAY, not a bare JSON string.
  #
  # This assertion was the exact opposite when first written, and the reversal
  # is a POLICY CHANGE, not an assertion tuned to match output. `source_ref` is
  # a semantically PLURAL key, and it is now registered in
  # `.RQ_PLURAL_DIAGNOSTIC_KEYS` (R/db-schema.R), so it serialises as an array
  # at every length including 1 and 0. The original version pinned
  # auto_unbox's default behaviour, which made the field change SHAPE with its
  # length - array at 2, bare string at 1 - forcing every consumer to branch,
  # and to get it wrong on the length-1 case, which is the common case. The
  # same defect was reported independently against `candidates` (round-2
  # finding FF8), which is what prompted deciding it once for all plural keys
  # rather than per key. `n_rows` is genuinely scalar and still unboxes.
  expect_identical(diags$single$source_ref, list("s1"))
  expect_identical(diags$single$n_rows, 1L)
  single_text <- stored$payload[grepl("T.SINGLE-Q2", stored$payload, fixed = TRUE)][[1]]
  expect_match(single_text, '"source_ref":\\["s1"\\]')
  expect_match(single_text, '"n_rows":1')

  # n_rows is a JSON NUMBER, never a quoted string: the retired migration 006
  # could only recover the string it had parsed out of k=v text, and a quoted
  # value here would mean the count has gone back to travelling as text.
  expect_no_match(grouped_text, '"n_rows":"')
  expect_no_match(single_text, '"n_rows":"')
})

# ---- R-11.16: quantified from parse_value(); write rl_high (F4) ------------

test_that("R-11.16: a '>2000' row commits quantified = FALSE (from parse_value, never re-derived from below_detection) and a non-NA rl_high = 2000 (F4)", {
  setup <- commit_test_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  files <- tibble::tibble(hash = setup$hash, filename = basename(setup$path),
                          adapter = "esdat/1", rank = 3L, kept = TRUE)
  # below_detection deliberately FALSE (contradicting quantified) to prove
  # .ct_commit_analyses() reads clean$quantified and never re-derives it.
  clean <- mk_p11_row(source_ref = "r1", source_hash = setup$hash,
                       value_raw = ">2000", value_num = 2000, value_converted = 2000,
                       below_detection = FALSE, quantified = FALSE, rl_high = 2000,
                       sample_date = as.Date("2025-07-11"),
                       sample_datetime = as.POSIXct("2025-07-11 09:00:00", tz = "UTC"))
  commit_event(mk_commit_event(files), mk_resolved(clean = clean), con)

  new_row <- DBI::dbGetQuery(con,
    "SELECT quantified, rl_high FROM analysis WHERE uuid NOT IN ('an-0001','an-0002','an-0003','an-0004','an-0005')")
  expect_equal(nrow(new_row), 1)
  expect_false(new_row$quantified[[1]])
  expect_equal(new_row$rl_high[[1]], 2000)
})

test_that("R-11.16: a literal 'BDL' row commits quantified = FALSE independent of below_detection", {
  setup <- commit_test_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  files <- tibble::tibble(hash = setup$hash, filename = basename(setup$path),
                          adapter = "esdat/1", rank = 3L, kept = TRUE)
  clean <- mk_p11_row(source_ref = "r1", source_hash = setup$hash,
                       value_raw = "BDL", value_num = NA_real_, value_converted = NA_real_,
                       below_detection = FALSE, quantified = FALSE,
                       sample_date = as.Date("2025-07-12"),
                       sample_datetime = as.POSIXct("2025-07-12 09:00:00", tz = "UTC"))
  commit_event(mk_commit_event(files), mk_resolved(clean = clean), con)

  new_row <- DBI::dbGetQuery(con,
    "SELECT quantified FROM analysis WHERE uuid NOT IN ('an-0001','an-0002','an-0003','an-0004','an-0005')")
  expect_equal(nrow(new_row), 1)
  expect_false(new_row$quantified[[1]])
})

test_that("R-11.16: a '<0.01' row keeps rl_low = 0.01 (existing pin) and commits quantified = FALSE", {
  setup <- commit_test_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  files <- tibble::tibble(hash = setup$hash, filename = basename(setup$path),
                          adapter = "esdat/1", rank = 3L, kept = TRUE)
  clean <- mk_p11_row(source_ref = "r1", source_hash = setup$hash,
                       value_raw = "<0.01", value_num = 0.01, value_converted = NA_real_,
                       below_detection = TRUE, quantified = FALSE, rl_converted = 0.01,
                       sample_date = as.Date("2025-07-13"),
                       sample_datetime = as.POSIXct("2025-07-13 09:00:00", tz = "UTC"))
  commit_event(mk_commit_event(files), mk_resolved(clean = clean), con)

  new_row <- DBI::dbGetQuery(con,
    "SELECT quantified, rl_low FROM analysis WHERE uuid NOT IN ('an-0001','an-0002','an-0003','an-0004','an-0005')")
  expect_equal(nrow(new_row), 1)
  expect_false(new_row$quantified[[1]])
  expect_equal(new_row$rl_low[[1]], 0.01)
})

test_that("R-11.16: a plain-numeric row commits quantified = TRUE regardless of below_detection", {
  setup <- commit_test_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  files <- tibble::tibble(hash = setup$hash, filename = basename(setup$path),
                          adapter = "esdat/1", rank = 3L, kept = TRUE)
  # below_detection deliberately TRUE (contradicting quantified) - proves
  # commit reads clean$quantified only, never below_detection, for this field.
  clean <- mk_p11_row(source_ref = "r1", source_hash = setup$hash,
                       value_raw = "6.50", value_num = 6.50, value_converted = 6.50,
                       below_detection = TRUE, quantified = TRUE,
                       sample_date = as.Date("2025-07-14"),
                       sample_datetime = as.POSIXct("2025-07-14 09:00:00", tz = "UTC"))
  commit_event(mk_commit_event(files), mk_resolved(clean = clean), con)

  new_row <- DBI::dbGetQuery(con,
    "SELECT quantified FROM analysis WHERE uuid NOT IN ('an-0001','an-0002','an-0003','an-0004','an-0005')")
  expect_equal(nrow(new_row), 1)
  expect_true(new_row$quantified[[1]])
})

# ---- R-11.18/A62: distinct non-NA datetimes are distinct samplings ---------

test_that("R-11.18/A62: two non-NA differing datetimes at one feature+date create TWO sample rows and two analyses (distinct samplings)", {
  setup <- commit_test_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  files <- tibble::tibble(hash = setup$hash, filename = basename(setup$path),
                          adapter = "esdat/1", rank = 3L, kept = TRUE)
  clean <- dplyr::bind_rows(
    mk_p11_row(source_ref = "r1", source_hash = setup$hash,
               sample_date = as.Date("2025-07-15"),
               sample_datetime = as.POSIXct("2025-07-15 09:00:00", tz = "UTC")),
    mk_p11_row(source_ref = "r2", source_hash = setup$hash,
               sample_date = as.Date("2025-07-15"),
               sample_datetime = as.POSIXct("2025-07-15 15:00:00", tz = "UTC"))
  )
  before_sample <- count_rows(con, "sample")
  before_analysis <- count_rows(con, "analysis")
  commit_event(mk_commit_event(files), mk_resolved(clean = clean), con)
  expect_equal(count_rows(con, "sample") - before_sample, 2)
  expect_equal(count_rows(con, "analysis") - before_analysis, 2)

  # A44.3 round-trip: both distinct instants survive through the real driver.
  new_samples <- DBI::dbGetQuery(con,
    "SELECT datetime FROM \"sample\" WHERE uuid_feature_alias = 'fa-0001' AND CAST(date AS DATE) = '2025-07-15'")
  expect_equal(nrow(new_samples), 2)
  got <- sort(format(new_samples$datetime, tz = "UTC", "%H:%M"))
  expect_identical(got, c("09:00", "15:00"))
})

test_that("R-11.18/A62: an incoming NA datetime reuses an existing date-only sample (no new sample)", {
  setup <- commit_test_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbExecute(con, "INSERT INTO \"sample\" (uuid, uuid_feature_alias, uuid_project, date, datetime, organisation)
    VALUES ('s-r1118-a', 'fa-0001', 'p-0001', TIMESTAMP '2025-07-16 00:00:00', NULL, 'ALS')")

  files <- tibble::tibble(hash = setup$hash, filename = basename(setup$path),
                          adapter = "esdat/1", rank = 3L, kept = TRUE)
  clean <- mk_p11_row(source_ref = "r1", source_hash = setup$hash,
                       sample_date = as.Date("2025-07-16"), sample_datetime = as.POSIXct(NA))
  before_sample <- count_rows(con, "sample")
  commit_event(mk_commit_event(files), mk_resolved(clean = clean), con)
  expect_equal(count_rows(con, "sample"), before_sample)

  linked <- DBI::dbGetQuery(con,
    "SELECT uuid_sample FROM analysis WHERE uuid NOT IN ('an-0001','an-0002','an-0003','an-0004','an-0005')")
  expect_equal(nrow(linked), 1)
  expect_identical(linked$uuid_sample[[1]], "s-r1118-a")
})

test_that("R-11.18/A62: a non-NA incoming datetime still reuses an existing NA-datetime candidate (uncertain identity - no fabricated duplicate)", {
  setup <- commit_test_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbExecute(con, "INSERT INTO \"sample\" (uuid, uuid_feature_alias, uuid_project, date, datetime, organisation)
    VALUES ('s-r1118-b', 'fa-0001', 'p-0001', TIMESTAMP '2025-07-17 00:00:00', NULL, 'ALS')")

  files <- tibble::tibble(hash = setup$hash, filename = basename(setup$path),
                          adapter = "esdat/1", rank = 3L, kept = TRUE)
  clean <- mk_p11_row(source_ref = "r1", source_hash = setup$hash,
                       sample_date = as.Date("2025-07-17"),
                       sample_datetime = as.POSIXct("2025-07-17 15:00:00", tz = "UTC"))
  before_sample <- count_rows(con, "sample")
  commit_event(mk_commit_event(files), mk_resolved(clean = clean), con)
  expect_equal(count_rows(con, "sample"), before_sample)

  linked <- DBI::dbGetQuery(con,
    "SELECT uuid_sample FROM analysis WHERE uuid NOT IN ('an-0001','an-0002','an-0003','an-0004','an-0005')")
  expect_equal(nrow(linked), 1)
  expect_identical(linked$uuid_sample[[1]], "s-r1118-b")
})

test_that("R-11.18/A62: an incoming datetime equal to an existing sample's datetime reuses that sample", {
  setup <- commit_test_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbExecute(con, "INSERT INTO \"sample\" (uuid, uuid_feature_alias, uuid_project, date, datetime, organisation)
    VALUES ('s-r1118-c', 'fa-0001', 'p-0001', TIMESTAMP '2025-07-18 00:00:00', TIMESTAMP '2025-07-18 09:00:00', 'ALS')")

  files <- tibble::tibble(hash = setup$hash, filename = basename(setup$path),
                          adapter = "esdat/1", rank = 3L, kept = TRUE)
  clean <- mk_p11_row(source_ref = "r1", source_hash = setup$hash,
                       sample_date = as.Date("2025-07-18"),
                       sample_datetime = as.POSIXct("2025-07-18 09:00:00", tz = "UTC"))
  before_sample <- count_rows(con, "sample")
  commit_event(mk_commit_event(files), mk_resolved(clean = clean), con)
  expect_equal(count_rows(con, "sample"), before_sample)

  linked <- DBI::dbGetQuery(con,
    "SELECT uuid_sample FROM analysis WHERE uuid NOT IN ('an-0001','an-0002','an-0003','an-0004','an-0005')")
  expect_equal(nrow(linked), 1)
  expect_identical(linked$uuid_sample[[1]], "s-r1118-c")
})

# ---- R-8.7/A63: conversion_constant idempotency (end-to-end commit + reconcile) ----

test_that("R-8.7/A63: a re-ingested reading under a conversion_constant method is already_present, not a false value_conflict", {
  setup <- commit_test_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  # Step 1: store a Fluoride-as-F reading of 3 mg/L via REAL commit under
  # lm-0012 (conversion_constant = 2.0). `value_converted` must be the
  # CANONICAL post-unit-conversion figure commit actually receives from a real
  # reconcile - a-0002's registered canonical unit is ug/L (FIXTURES.md: "canonical
  # units deliberately differ from reported units to force conversion"), so 3
  # mg/L canonicalises to 3000 (NOT 3 - passing 3 straight through would
  # silently skip that real unit conversion and desync from what Step 2's
  # real reconcile_event() independently computes for the identical raw
  # reading, see escalation note in the session report).
  files <- tibble::tibble(hash = setup$hash, filename = basename(setup$path),
                          adapter = "esdat/1", rank = 3L, kept = TRUE)
  clean <- mk_clean_row(
    source_ref = "c1", source_hash = setup$hash,
    uuid_feature = "f-0001", uuid_lab = "lm-0012", uuid_analyte = "a-0002",
    analyte_raw = "Fluoride as F", method_raw = "EK040P: Fluoride by PC Titrator",
    units_raw = "mg/L", value_raw = "3", value_num = 3, value_converted = 3000,
    below_detection = FALSE,
    sample_date = as.Date("2025-05-24"),
    sample_datetime = as.POSIXct("2025-05-24 11:45:00", tz = "Australia/Sydney")
  )
  commit_event(mk_commit_event(files), mk_resolved(clean = clean), con)

  stored <- DBI::dbGetQuery(con, "SELECT value FROM analysis WHERE uuid_lab = 'lm-0012'")
  expect_equal(stored$value, 6000)  # 3000 * conversion_constant (2.0) - pins commit's cc-multiply

  # Step 2: re-ingest the IDENTICAL measurement via REAL reconcile_event().
  event <- mk_event(mk_row(
    source_ref = "r1", analyte_raw = "Fluoride as F",
    cas_number = "16984-48-8", method_raw = "EK040P: Fluoride by PC Titrator",
    org = "ALS", units_raw = "mg/L", value_raw = "3", value_num = 3,
    below_detection = FALSE, rl = 0.1,
    sample_datetime_raw = "24 May 2025 11:45"
  ))
  out <- reconcile_event(event, con)

  expect_true("r1" %in% out$skipped$source_ref)
  expect_identical(out$skipped$reason[out$skipped$source_ref == "r1"], "already_present")
  expect_false("r1" %in% out$review$source_ref)
})

# ---- PLAN-16 R-16.14 (FA5): .ct_skip_existing_uuid()'s load-bearing half ---
#
# The R-16.14 block in test-review-queue-payload.R only asserts half 1 (the
# tibble column reconcile populates). Half 2 - "the replacement must return
# the same uuid the regex returned FOR THE SAME INPUT" - had NO test calling
# `.ct_skip_existing_uuid()` at all; the coverage credited to it actually
# lived in the R-9.2 "already_present" block above, driven by a fixture
# (`existing_uuid = "an-0001"`) rather than by production. These two blocks
# close that gap by driving `.ct_skip_existing_uuid()` on the skip tibble a
# REAL `reconcile_event()`/`.rc_qc_filter()` produces.

test_that("R-16.14: .ct_skip_existing_uuid() returns the analysis uuid a REAL reconcile_event() already_present skip carries, and drives a real commit_event() provenance row from it", {
  setup <- commit_test_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  # Step 1: store a Fluoride-as-F reading via a REAL commit_event() (same
  # fixture as the R-8.7/A63 block above) so a KNOWN analysis.uuid exists.
  files <- tibble::tibble(hash = setup$hash, filename = basename(setup$path),
                          adapter = "esdat/1", rank = 3L, kept = TRUE)
  clean <- mk_clean_row(
    source_ref = "c1", source_hash = setup$hash,
    uuid_feature = "f-0001", uuid_lab = "lm-0012", uuid_analyte = "a-0002",
    analyte_raw = "Fluoride as F", method_raw = "EK040P: Fluoride by PC Titrator",
    units_raw = "mg/L", value_raw = "3", value_num = 3, value_converted = 3000,
    below_detection = FALSE,
    sample_date = as.Date("2025-05-24"),
    sample_datetime = as.POSIXct("2025-05-24 11:45:00", tz = "Australia/Sydney")
  )
  commit_event(mk_commit_event(files), mk_resolved(clean = clean), con)
  existing_uuid <- DBI::dbGetQuery(con, "SELECT uuid FROM analysis WHERE uuid_lab = 'lm-0012'")$uuid[[1]]

  # Step 2: re-ingest the IDENTICAL reading via a REAL reconcile_event() -
  # production's already_present skip producer (R/reconcile.R ~1260) is what
  # populates `existing_uuid`, not this test.
  second <- add_second_reconciled_file(setup, "PROJ_A.ESDAT_XX1234567_0.Chemistry2f.CSV")
  event <- mk_event(mk_row(
    source_ref = "r1", source_hash = second$hash, analyte_raw = "Fluoride as F",
    cas_number = "16984-48-8", method_raw = "EK040P: Fluoride by PC Titrator",
    org = "ALS", units_raw = "mg/L", value_raw = "3", value_num = 3,
    below_detection = FALSE, rl = 0.1,
    sample_datetime_raw = "24 May 2025 11:45"
  ))
  out <- reconcile_event(event, con)
  expect_true("r1" %in% out$skipped$source_ref)
  expect_identical(out$skipped$reason[out$skipped$source_ref == "r1"], "already_present")

  i <- which(out$skipped$source_ref == "r1")
  expect_identical(.ct_skip_existing_uuid(out$skipped, i), existing_uuid)

  # Drive a REAL commit_event() on this REAL skip tibble (not a hand-built
  # fixture) and assert the provenance change_log row lands on the uuid
  # .ct_skip_existing_uuid() returned.
  second_files <- tibble::tibble(hash = second$hash, filename = basename(second$path),
                                 adapter = "esdat/1", rank = 3L, kept = TRUE)
  resolved <- mk_resolved(clean = tibble::tibble(), skipped = out$skipped,
                          counts = c(already_present = 1))
  commit_event(mk_commit_event(second_files, work_order = setup$work_order), resolved, con)

  prov <- DBI::dbGetQuery(con, sprintf(
    "SELECT * FROM change_log WHERE uuid_row = '%s' AND action = 'provenance' AND source_hash = '%s'",
    existing_uuid, second$hash))
  expect_equal(nrow(prov), 1)
})

test_that("R-16.14: a skip tibble missing the existing_uuid column (e.g. .rc_qc_filter()'s own output, R/reconcile.R:194-200) makes .ct_skip_existing_uuid() return NA, and commit_event() skips the provenance row entirely rather than erroring", {
  # .rc_qc_filter() is a real production function (reconcile_event() itself
  # backfills the column for its OWN return value via .rc_fill_missing_cols(),
  # so this shape only surfaces one function earlier - exactly where FA5
  # says it is constructible today).
  qc <- .rc_qc_filter(tibble::tibble(
    source_ref = "qc1", sample_type = "LCS", source_hash = "qc-hash"
  ))
  expect_false("existing_uuid" %in% names(qc$skipped))
  expect_identical(.ct_skip_existing_uuid(qc$skipped, 1), NA_character_)

  setup <- commit_test_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  files <- tibble::tibble(hash = setup$hash, filename = basename(setup$path),
                          adapter = "esdat/1", rank = 3L, kept = TRUE)
  # A skip tibble shaped like .rc_qc_filter()'s (no existing_uuid column) but
  # forced to reason = "already_present" so it reaches
  # .ct_record_already_present()'s loop - it must skip the row silently, not
  # error, matching the retired regex fallback's replacement.
  skipped <- tibble::tibble(source_ref = "qc1", source_hash = setup$hash,
                            reason = "already_present")
  resolved <- mk_resolved(clean = tibble::tibble(), skipped = skipped, counts = c(already_present = 1))
  # Scoped to tbl='analysis'/action='provenance' - the exact write
  # .ct_record_already_present() makes - so commit_event()'s OWN incidental
  # change_log traffic (e.g. .ct_ensure_project() inserting a new project row
  # on this work order's first commit) does not confound the assertion.
  before <- nrow(DBI::dbGetQuery(con, "SELECT * FROM change_log WHERE tbl = 'analysis' AND action = 'provenance'"))
  commit_event(mk_commit_event(files), resolved, con)
  after <- nrow(DBI::dbGetQuery(con, "SELECT * FROM change_log WHERE tbl = 'analysis' AND action = 'provenance'"))
  expect_equal(after, before)
})

# ---- PLAN-16 FB8: .ct_commit_review()'s typed columns survive the commit
#      boundary (routes through .rq_row(), B-16.api: "Both insert paths
#      route through it") ------------------------------------------------

test_that("PLAN-16 FB8: subkind, uuid_existing and uuid_alias all survive a real commit_event() -> .ct_commit_review() write, not just uuid_alias", {
  setup <- commit_test_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  files <- tibble::tibble(hash = setup$hash, filename = basename(setup$path),
                          adapter = "esdat/1", rank = 3L, kept = TRUE)
  review <- tibble::tibble(
    source_ref = "r1", kind = "value_conflict", subkind = "measurement",
    source_hash = setup$hash, payload = '{"value_existing":1,"value_incoming":2}',
    uuid_existing = "an-0001", uuid_alias = "fa-0009"
  )
  resolved <- mk_resolved(clean = tibble::tibble(), review = review)

  commit_event(mk_commit_event(files), resolved, con)

  stored <- DBI::dbGetQuery(con,
    "SELECT subkind, uuid_existing, uuid_alias, status FROM review_queue WHERE kind = 'value_conflict' AND source_hash = ?",
    params = list(setup$hash))
  expect_equal(nrow(stored), 1)
  expect_identical(stored$subkind[[1]], "measurement")
  expect_identical(stored$uuid_existing[[1]], "an-0001")
  expect_identical(stored$uuid_alias[[1]], "fa-0009")
  expect_identical(stored$status[[1]], "open")
})

test_that("cold-audit defect 1: a review tibble with no `payload` column at all commits with the valid JSON empty-object default, not NULL/an error (.ct_commit_review() unguarded `row$payload <- review$payload[[i]]` bypassed the col_or_na() guard every sibling column uses)", {
  setup <- commit_test_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  files <- tibble::tibble(hash = setup$hash, filename = basename(setup$path),
                          adapter = "esdat/1", rank = 3L, kept = TRUE)
  # Deliberately NO `payload` column - the exact shape `review$payload` is
  # NULL for, so `review$payload[[i]]` (pre-fix) throws "subscript out of
  # bounds" rather than silently writing NA.
  review <- tibble::tibble(
    source_ref = "r1", kind = "unknown_unit", subkind = NA_character_,
    source_hash = setup$hash
  )
  resolved <- mk_resolved(clean = tibble::tibble(), review = review)

  commit_event(mk_commit_event(files), resolved, con)

  stored <- DBI::dbGetQuery(con,
    "SELECT payload FROM review_queue WHERE kind = 'unknown_unit' AND source_hash = ?",
    params = list(setup$hash))
  expect_equal(nrow(stored), 1)
  # .rq_row()'s own default for "no diagnostics" - `.rq_serialise_diagnostics(list())`
  # - is the JSON empty object, not NA/NULL.
  expect_identical(stored$payload[[1]], "{}")
})

test_that("PLAN-16 round-3 R-16.23: .ct_commit_review() persists a real .rc_review_row() producer's `candidates` as review_queue_candidate rows - not discarded a second time - with uuid_review rewritten to the PARENT ROW'S ACTUAL INSERTED uuid (not the constructor's own uuid_row), read back in rank order via the exported review_queue_candidates() reader", {
  setup <- commit_test_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  # Real resolution against the real seeded registry - T.AMBIG2 -> f-0004/
  # f-0005, the same fixture the sibling worker drove in
  # test-review-queue-candidate.R's R-16.22/R-16.23 block.
  registry <- .rc_load_registry(con)
  cand <- .rc_feature_candidates("T.AMBIG2", as.Date(NA), registry)
  expect_equal(sort(cand$uuid_feature), c("f-0004", "f-0005"))

  # The real producer: .rc_review_row() (R/reconcile.R), unedited - the
  # function FG-3 fixed to stop discarding `rq$candidates`. Its OWN
  # `uuid_row` (minted inside .rq_row()) is deliberately NOT the
  # review_queue.uuid this test reads back under below - closing that exact
  # mismatch is this file's job.
  review_row <- .rc_review_row(
    source_ref = "r1", kind = "unknown_feature", n_rows = 1L,
    source_hash = setup$hash, subkind = "ambiguous", candidates = cand$uuid_feature
  )
  constructor_uuid_review <- review_row$candidates[[1]]$uuid_review[[1]]

  files <- tibble::tibble(hash = setup$hash, filename = basename(setup$path),
                          adapter = "esdat/1", rank = 3L, kept = TRUE)
  resolved <- mk_resolved(clean = tibble::tibble(), review = review_row)

  commit_event(mk_commit_event(files), resolved, con)

  stored_review <- DBI::dbGetQuery(
    con, "SELECT uuid FROM review_queue WHERE kind = 'unknown_feature' AND source_hash = ?",
    params = list(setup$hash)
  )
  expect_equal(nrow(stored_review), 1)
  actual_uuid <- stored_review$uuid[[1]]

  # The crux: commit_event() mints a FRESH review_queue.uuid at insert time,
  # different from .rq_row()'s own constructor-time uuid_row.
  expect_false(identical(actual_uuid, constructor_uuid_review))

  got <- review_queue_candidates(con, actual_uuid)
  expect_equal(nrow(got), 2)
  expect_identical(got$rank, c(1L, 2L))
  expect_identical(got$uuid_feature, cand$uuid_feature)
  expect_identical(got$kind, c("candidate", "candidate"))

  # Pins the rewrite itself: every persisted child row's uuid_review equals
  # the parent row's ACTUAL uuid, not the constructor's discarded one.
  child_uuid_review <- DBI::dbGetQuery(
    con, "SELECT DISTINCT uuid_review FROM review_queue_candidate WHERE uuid_review = ?",
    params = list(actual_uuid)
  )$uuid_review
  expect_equal(child_uuid_review, actual_uuid)

  # No orphaned child rows under the discarded constructor uuid (would be an
  # FK violation had they been inserted verbatim; also proves the rewrite
  # actually ran rather than merely not crashing).
  orphans <- DBI::dbGetQuery(
    con, "SELECT count(*) AS n FROM review_queue_candidate WHERE uuid_review = ?",
    params = list(constructor_uuid_review)
  )$n
  expect_equal(orphans, 0)
})

test_that("PLAN-16 round-3 R-16.23: a review tibble with no `candidates` column at all (every pre-existing hand-built test fixture / not-yet-routed producer) still commits cleanly and writes zero review_queue_candidate rows - the fix must not require every caller to carry the column", {
  setup <- commit_test_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  files <- tibble::tibble(hash = setup$hash, filename = basename(setup$path),
                          adapter = "esdat/1", rank = 3L, kept = TRUE)
  review <- tibble::tibble(
    source_ref = "r1", kind = "unknown_unit", subkind = NA_character_,
    source_hash = setup$hash, payload = '{"units_raw":"banana/L"}'
  )
  resolved <- mk_resolved(clean = tibble::tibble(), review = review)

  commit_event(mk_commit_event(files), resolved, con)

  n_child <- count_rows(con, "review_queue_candidate")
  expect_equal(n_child, 0)
})

test_that("R-11.16: a qualitative text row commits quantified = NA, not FALSE (the tri-state survives the write)", {
  # Ruled by Robin 2026-07-23. `isTRUE()` maps NA to FALSE, which silently
  # recorded "this is not a measurement" as "below detection". In the live
  # registry 315 rows are text-valued and 23 of those record that no sample was
  # taken - committing them as quantified = FALSE asserts a non-detection that
  # was never performed.
  setup <- commit_test_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  files <- tibble::tibble(hash = setup$hash, filename = basename(setup$path),
                          adapter = "esdat/1", rank = 3L, kept = TRUE)
  # below_detection deliberately FALSE so that a fallback to it could not
  # accidentally produce the NA we are asserting.
  clean <- mk_p11_row(source_ref = "r1", source_hash = setup$hash,
                       value_raw = "Could not find due to long grass",
                       value_num = NA_real_, value_converted = NA_real_,
                       value_chr = "Could not find due to long grass",
                       below_detection = FALSE, quantified = NA,
                       sample_date = as.Date("2025-07-13"),
                       sample_datetime = as.POSIXct("2025-07-13 09:00:00", tz = "UTC"))
  commit_event(mk_commit_event(files), mk_resolved(clean = clean), con)

  new_row <- DBI::dbGetQuery(con,
    "SELECT quantified, value_chr FROM analysis WHERE uuid NOT IN ('an-0001','an-0002','an-0003','an-0004','an-0005')")
  expect_equal(nrow(new_row), 1)
  expect_true(is.na(new_row$quantified[[1]]))
  # and it must be NA specifically - FALSE is the bug this guards
  expect_false(isFALSE(new_row$quantified[[1]]))
  expect_equal(new_row$value_chr[[1]], "Could not find due to long grass")
})

# ---- PLAN-15 E.4/R-15.17: new-alias date_start = min(sample_date) over the
#      WHOLE alias_key group, order-independent; existing-dangling branch
#      must not touch either bound -----------------------------------------

test_that("R-15.17: a new pending alias's date_start is min(sample_date) over the WHOLE group, identical regardless of row/file order; date_end stays NULL", {
  setup <- commit_test_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  key <- .rc_feature_key("T.ORDER-INDEP")
  event <- mk_commit_event(tibble::tibble(hash = setup$hash, filename = basename(setup$path),
                                           adapter = "esdat/1", rank = 3L, kept = TRUE))

  # Three rows sharing one alias_key, NOT in date order - the earliest
  # (2025-05-01) is neither first nor last in this ordering, so a
  # first-in-file-order bug (rows_k[[1]]) would pick 2025-06-01, not the
  # group minimum.
  clean_fwd <- dplyr::bind_rows(
    mk_p11_row(source_ref = "r1", source_hash = setup$hash,
               feature_raw = "T.ORDER-INDEP", alias_key = key,
               feature_pending = TRUE, uuid_feature_alias = NA_character_,
               sample_date = as.Date("2025-06-01"),
               sample_datetime = as.POSIXct("2025-06-01 09:00:00", tz = "UTC")),
    mk_p11_row(source_ref = "r2", source_hash = setup$hash,
               feature_raw = "T.ORDER-INDEP", alias_key = key,
               feature_pending = TRUE, uuid_feature_alias = NA_character_,
               sample_date = as.Date("2025-06-15"),
               sample_datetime = as.POSIXct("2025-06-15 09:00:00", tz = "UTC")),
    mk_p11_row(source_ref = "r3", source_hash = setup$hash,
               feature_raw = "T.ORDER-INDEP", alias_key = key,
               feature_pending = TRUE, uuid_feature_alias = NA_character_,
               sample_date = as.Date("2025-05-01"),
               sample_datetime = as.POSIXct("2025-05-01 09:00:00", tz = "UTC"))
  )
  .ct_materialise_feature_aliases(con, clean_fwd, event, "test-actor", "R-15.17 forward order")

  alias_fwd <- dangling_alias_row(con, key)
  expect_equal(nrow(alias_fwd), 1)
  expect_equal(alias_fwd$date_start[[1]], as.Date("2025-05-01"))
  expect_true(is.na(alias_fwd$date_end[[1]]))

  # Rebuild with the SAME group in REVERSED row order (simulating the two
  # files of one event arriving in a different order) - must yield the
  # IDENTICAL date_start, not a different, permanent one.
  DBI::dbExecute(con, "DELETE FROM feature_alias WHERE alias_key = ?", params = list(key))
  clean_rev <- clean_fwd[rev(seq_len(nrow(clean_fwd))), ]
  clean_rev$uuid_feature_alias <- NA_character_
  .ct_materialise_feature_aliases(con, clean_rev, event, "test-actor", "R-15.17 reversed order")

  alias_rev <- dangling_alias_row(con, key)
  expect_equal(nrow(alias_rev), 1)
  expect_equal(alias_rev$date_start[[1]], as.Date("2025-05-01"))
  expect_true(is.na(alias_rev$date_end[[1]]))
})

test_that("R-15.17: re-ingesting into an EXISTING dangling alias updates n_seen/last_seen only - date_start/date_end are left untouched even by an earlier-dated incoming row", {
  setup <- commit_test_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  key <- .rc_feature_key("T.EXISTING-DANGLING-BOUNDS")

  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign, first_seen, last_seen,
     confirmed_by, comments, date_start, date_end)
    VALUES ('fa-existing-dangling', NULL, 'T.EXISTING-DANGLING-BOUNDS', ?, 'pending', 1, FALSE,
            TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00', NULL, NULL,
            DATE '2025-03-15', NULL)",
    params = list(key))

  files <- tibble::tibble(hash = setup$hash, filename = basename(setup$path),
                          adapter = "esdat/1", rank = 3L, kept = TRUE)
  event <- mk_commit_event(files)
  # sample_date deliberately EARLIER than the recorded date_start - proves the
  # existing-dangling branch does not widen (or otherwise touch) the bound.
  clean <- mk_p11_row(source_ref = "r1", source_hash = setup$hash,
                       feature_raw = "T.EXISTING-DANGLING-BOUNDS", alias_key = key,
                       feature_pending = TRUE, uuid_feature_alias = NA_character_,
                       sample_date = as.Date("2025-01-01"),
                       sample_datetime = as.POSIXct("2025-01-01 09:00:00", tz = "UTC"))
  .ct_materialise_feature_aliases(con, clean, event, "test-actor", "R-15.17 existing-dangling")

  after <- dangling_alias_row(con, key)
  expect_equal(nrow(after), 1)
  expect_equal(after$date_start[[1]], as.Date("2025-03-15"))
  expect_true(is.na(after$date_end[[1]]))
  expect_equal(after$n_seen[[1]], 2)
})

# ---- PLAN-15 F.10/R-15.31/R-15.32: work-order-level re-ingest guard --------
#
# F.10's guard is a positive DB check ("does this work order already have
# `sample` rows?"), not a filename/`ingest_file` check, with two PINNED
# exemptions: a higher-revision re-ingest of a loaded WO (A12 supersede,
# `.rc_recorded_revision`) and an `already_present` match
# (`.rc_find_existing`) must both stay exempt. The already_present exemption
# for an already-loaded WO is independently covered by the pre-existing
# "R-8.7/A63" test above (WO XX1234567, already loaded via
# commit_test_setup()); it is not re-derived here. Driven through the REAL
# reconcile_event() -> commit_event() pipeline throughout (not hand-built
# `resolved`), per this file's plan-11 convention below.

test_that("R-15.31/R-15.32: the work-order re-ingest guard blocks a differently-named, non-matching, same-revision re-download of a loaded WO (routed to review, zero new rows), while a HIGHER-revision file for that same WO stays exempt and commits via the normal A12 supersede path", {
  setup <- commit_test_setup(filename = "PROJ_A.ESDAT_XX9990001_0.Chemistry2e.CSV",
                              work_order = "XX9990001", revision = 0L)
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  # ---- seed: WO XX9990001 already has sample/analysis rows.
  files0 <- tibble::tibble(hash = setup$hash, filename = basename(setup$path),
                           adapter = "esdat/1", rank = 3L, kept = TRUE)
  event0 <- mk_event(mk_row(source_ref = "r1", source_hash = setup$hash,
                             work_order = "XX9990001", revision = 0L,
                             sample_datetime_raw = "01 Aug 2025 09:00"),
                      work_order = "XX9990001")
  resolved0 <- reconcile_event(event0, con)
  expect_equal(nrow(resolved0$clean), 1)  # sanity: the seed genuinely commits
  commit_event(mk_commit_event(files0, work_order = "XX9990001"), resolved0, con)

  seeded_analysis <- DBI::dbGetQuery(con,
    "SELECT uuid FROM analysis WHERE uuid NOT IN ('an-0001','an-0002','an-0003','an-0004','an-0005')")
  expect_equal(nrow(seeded_analysis), 1)
  seeded_uuid <- seeded_analysis$uuid[[1]]

  before_sample <- count_rows(con, "sample")
  before_analysis <- count_rows(con, "analysis")
  before_review <- count_rows(con, "review_queue")

  # ---- EXEMPTION (R-15.31): a HIGHER-revision file for the SAME work order,
  # under a NEW filename, carrying a DIFFERENT value - must commit via the
  # normal A12 supersede path (update in place), not be caught by the guard.
  hi <- add_reconciled_file(setup, "PROJ_A.ESDAT_XX9990001_1_REISSUE.Chemistry2e.CSV",
                             work_order = "XX9990001", revision = 1L)
  files_hi <- tibble::tibble(hash = hi$hash, filename = basename(hi$path),
                             adapter = "esdat/1", rank = 3L, kept = TRUE)
  event_hi <- mk_event(mk_row(source_ref = "r1", source_hash = hi$hash,
                               work_order = "XX9990001", revision = 1L,
                               sample_datetime_raw = "01 Aug 2025 09:00",
                               value_raw = "0.2", value_num = 0.2, below_detection = FALSE),
                        work_order = "XX9990001")
  resolved_hi <- reconcile_event(event_hi, con)
  expect_equal(nrow(resolved_hi$clean), 1)
  expect_identical(resolved_hi$clean$supersedes[[1]], seeded_uuid)
  commit_event(mk_commit_event(files_hi, work_order = "XX9990001"), resolved_hi, con)

  expect_equal(count_rows(con, "analysis"), before_analysis)  # updated in place, no new row
  updated <- DBI::dbGetQuery(con, sprintf("SELECT value FROM analysis WHERE uuid = '%s'", seeded_uuid))
  expect_equal(updated$value[[1]], 200)  # 0.2 mg/L -> 200 ug/L canonical (lm-0002 has no conversion_constant)

  # ---- BLOCKING (R-15.32): a SAME-revision file, under yet another new
  # filename, carrying a row for a DIFFERENT sample_date matching NOTHING
  # already in the DB - must be blocked from commit and routed to review,
  # not silently committed as a brand-new legitimate sample.
  lo <- add_reconciled_file(setup, "PROJ_A.ESDAT_XX9990001_0_REDOWNLOAD.Chemistry2e.CSV",
                             work_order = "XX9990001", revision = 0L)
  files_lo <- tibble::tibble(hash = lo$hash, filename = basename(lo$path),
                             adapter = "esdat/1", rank = 3L, kept = TRUE)
  event_lo <- mk_event(mk_row(source_ref = "r1", source_hash = lo$hash,
                               work_order = "XX9990001", revision = 0L,
                               sample_datetime_raw = "03 Aug 2025 09:00"),
                        work_order = "XX9990001")
  resolved_lo <- reconcile_event(event_lo, con)
  commit_event(mk_commit_event(files_lo, work_order = "XX9990001"), resolved_lo, con)

  expect_equal(count_rows(con, "sample"), before_sample)
  expect_equal(count_rows(con, "analysis"), before_analysis)
  expect_gt(count_rows(con, "review_queue"), before_review)

  # Phase-7b item 5: WHICH item landed, not just "some review row exists" -
  # kind/subkind and the n_rows_blocked value parsed out of the guard's own
  # JSON payload (exactly 1: the lo event's single, non-matching clean row).
  guard_row <- guard_review_row(con)
  expect_equal(nrow(guard_row), 1)
  expect_identical(guard_row$kind[[1]], "work_order_reingest")
  expect_identical(guard_row$subkind[[1]], "blocked")
  guard_diag <- jsonlite::fromJSON(guard_row$payload[[1]])
  expect_equal(guard_diag$n_rows_blocked, 1)

  # Phase-7b item 4 (F.17 obligations of the blocked path): the blocked
  # deliverable is still archived (asset row + byte copy on disk), so it is
  # never lost, and its ingest_file row lands on needs_review, NOT the
  # committed/archived terminal state a real commit would use. A mutation
  # sending `.ct_set_file_states()` down the committed->archived path for a
  # blocked event (n_clean wrongly passed as nrow(resolved$clean) instead of
  # 0L) survived the whole suite with no assertion here to catch it.
  lo_asset <- DBI::dbGetQuery(con, "SELECT * FROM asset WHERE hash = ?", params = list(lo$hash))
  expect_equal(nrow(lo_asset), 1)
  expect_true(file.exists(file.path(setup$archive_dir, lo_asset$uuid[[1]])))

  lo_state <- DBI::dbGetQuery(con, "SELECT state FROM ingest_file WHERE hash = ?",
                              params = list(lo$hash))
  expect_identical(lo_state$state[[1]], "needs_review")
})

test_that("R-15.32 (ACIRL false-merge guard): a first-time work order whose filename embeds a SHORTER, already-loaded ACIRL work order as a literal prefix still commits cleanly - the guard must key on the recorded work_order, never a filename-parsed one", {
  setup <- commit_test_setup(filename = "2400-7538-02_ALS_Chemistry.CSV",
                              work_order = "2400-7538-02", revision = 0L)
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  # WO A = "2400-7538-02" is already loaded (has sample rows).
  files_a <- tibble::tibble(hash = setup$hash, filename = basename(setup$path),
                            adapter = "esdat/1", rank = 3L, kept = TRUE)
  event_a <- mk_event(mk_row(source_ref = "r1", source_hash = setup$hash,
                              work_order = "2400-7538-02", revision = 0L,
                              sample_datetime_raw = "01 Aug 2025 09:00"),
                       work_order = "2400-7538-02")
  commit_event(mk_commit_event(files_a, work_order = "2400-7538-02"),
               reconcile_event(event_a, con), con)

  # WO B = "2400-7538-02-01" is a DIFFERENT, never-before-loaded work order -
  # but its filename embeds "2400-7538-02" (WO A) as a literal PREFIX, the
  # exact false-merge bait measured on the real corpus 2026-07-23 (a filename
  # regex matches WO A inside WO B's filename).
  b <- add_reconciled_file(setup, "2400-7538-02-01_ALS_Chemistry.CSV",
                            work_order = "2400-7538-02-01", revision = 0L)
  files_b <- tibble::tibble(hash = b$hash, filename = basename(b$path),
                            adapter = "esdat/1", rank = 3L, kept = TRUE)
  event_b <- mk_event(mk_row(source_ref = "r1", source_hash = b$hash,
                              work_order = "2400-7538-02-01", revision = 0L,
                              sample_datetime_raw = "02 Aug 2025 09:00"),
                       work_order = "2400-7538-02-01")

  before_sample <- count_rows(con, "sample")
  before_analysis <- count_rows(con, "analysis")
  resolved_b <- reconcile_event(event_b, con)
  expect_equal(nrow(resolved_b$clean), 1)
  commit_event(mk_commit_event(files_b, work_order = "2400-7538-02-01"), resolved_b, con)

  # WO B had NO prior sample rows - a first-time load must commit cleanly,
  # not be caught by a guard that mistook it (via filename) for a
  # re-download of WO A.
  expect_equal(count_rows(con, "sample") - before_sample, 1)
  expect_equal(count_rows(con, "analysis") - before_analysis, 1)
})

test_that("R-15.32 (ACIRL false-split guard): a re-download of a loaded work order whose true name contains a SPACE ('2400-7538 01-01') is still blocked and routed to review - the guard must not derive a shorter, never-loaded work order by regex-splitting the filename at the space", {
  setup <- commit_test_setup(filename = "2400-7538 01-01_ALS_Chemistry.CSV",
                              work_order = "2400-7538 01-01", revision = 0L)
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  files0 <- tibble::tibble(hash = setup$hash, filename = basename(setup$path),
                           adapter = "esdat/1", rank = 3L, kept = TRUE)
  event0 <- mk_event(mk_row(source_ref = "r1", source_hash = setup$hash,
                             work_order = "2400-7538 01-01", revision = 0L,
                             sample_datetime_raw = "01 Aug 2025 09:00"),
                      work_order = "2400-7538 01-01")
  commit_event(mk_commit_event(files0, work_order = "2400-7538 01-01"),
               reconcile_event(event0, con), con)

  before_sample <- count_rows(con, "sample")
  before_analysis <- count_rows(con, "analysis")
  before_review <- count_rows(con, "review_queue")

  # A differently-named re-download of the SAME work order (the correct
  # field value is passed directly here, exactly as `ingest_file.work_order`
  # would carry it - never re-derived from the filename), same revision, a
  # row matching nothing already in the DB: the classic F.10 re-download
  # case, on a WO string a hyphen-only regex would truncate at the space (a
  # false split down to "2400-7538", which was never loaded and so would
  # slip an implementation that keys on a filename-parsed work order).
  redl <- add_reconciled_file(setup, "2400-7538 01-01_ALS_Chemistry_v2.CSV",
                               work_order = "2400-7538 01-01", revision = 0L)
  files_redl <- tibble::tibble(hash = redl$hash, filename = basename(redl$path),
                               adapter = "esdat/1", rank = 3L, kept = TRUE)
  event_redl <- mk_event(mk_row(source_ref = "r1", source_hash = redl$hash,
                                 work_order = "2400-7538 01-01", revision = 0L,
                                 sample_datetime_raw = "05 Aug 2025 09:00"),
                          work_order = "2400-7538 01-01")
  commit_event(mk_commit_event(files_redl, work_order = "2400-7538 01-01"),
               reconcile_event(event_redl, con), con)

  expect_equal(count_rows(con, "sample"), before_sample)
  expect_equal(count_rows(con, "analysis"), before_analysis)
  expect_gt(count_rows(con, "review_queue"), before_review)

  # Phase-7b item 5 (see note at the R-15.31/R-15.32 block above).
  guard_row <- guard_review_row(con)
  expect_equal(nrow(guard_row), 1)
  expect_identical(guard_row$kind[[1]], "work_order_reingest")
  expect_identical(guard_row$subkind[[1]], "blocked")
  guard_diag <- jsonlite::fromJSON(guard_row$payload[[1]])
  expect_equal(guard_diag$n_rows_blocked, 1)
})

test_that("R-15.32 (legacy work order): a re-download of a work order whose project row PREDATES this pipeline - samples present, no `change_log` project insert - is still blocked and routed to review", {
  # This is the population the guard's first cut silently exempted, and it is
  # the majority of the live DB: measured read-only 2026-07-26, only 8 of the
  # 423 loaded work orders carried a pipeline `change_log` project insert (the
  # post-2026-07-23-cutover ones), so requiring that insert left 415 work
  # orders unguarded. Robin ruled the condition out on that measurement.
  #
  # WO XX1234567 is exactly the legacy shape: `seed_db()` writes project
  # p-0001 with raw SQL, so it has samples but NO `change_log` insert, and
  # `.ct_ensure_project()` finds it already there and never stamps one. The
  # assertion below is what fails if the registration condition is ever
  # restored - it is the only block in this file that pins the widening.
  setup <- commit_test_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  legacy_registered <- DBI::dbGetQuery(con,
    "SELECT count(*) AS n FROM change_log
      WHERE tbl = 'project' AND action = 'insert' AND uuid_row = 'p-0001'")
  expect_equal(legacy_registered$n[[1]], 0)   # the legacy shape, not an artefact

  # A first ingest against the legacy work order: leaves an `asset` row (the
  # prior-ingest evidence the guard still requires) under the pre-existing
  # project.
  files1 <- tibble::tibble(hash = setup$hash, filename = basename(setup$path),
                           adapter = "esdat/1", rank = 3L, kept = TRUE)
  event1 <- mk_event(mk_row(source_ref = "r1", source_hash = setup$hash,
                             sample_datetime_raw = "01 Aug 2025 09:00"))
  resolved1 <- reconcile_event(event1, con)
  expect_equal(nrow(resolved1$clean), 1)      # sanity: the seed genuinely commits
  commit_event(mk_commit_event(files1), resolved1, con)

  still_unregistered <- DBI::dbGetQuery(con,
    "SELECT count(*) AS n FROM change_log
      WHERE tbl = 'project' AND action = 'insert' AND uuid_row = 'p-0001'")
  expect_equal(still_unregistered$n[[1]], 0)  # committing did not register it

  before_sample <- count_rows(con, "sample")
  before_analysis <- count_rows(con, "analysis")
  before_review <- count_rows(con, "review_queue")

  # The re-download: same work order, same revision, a new filename, a row
  # matching nothing already loaded.
  redl <- add_reconciled_file(setup, "PROJ_A.ESDAT_XX1234567_0.Chemistry2e_v2.CSV",
                               work_order = "XX1234567", revision = 0L)
  files2 <- tibble::tibble(hash = redl$hash, filename = basename(redl$path),
                           adapter = "esdat/1", rank = 3L, kept = TRUE)
  event2 <- mk_event(mk_row(source_ref = "r1", source_hash = redl$hash,
                             sample_datetime_raw = "03 Aug 2025 09:00"))
  commit_event(mk_commit_event(files2), reconcile_event(event2, con), con)

  expect_equal(count_rows(con, "sample"), before_sample)
  expect_equal(count_rows(con, "analysis"), before_analysis)
  expect_gt(count_rows(con, "review_queue"), before_review)

  # Phase-7b item 5 (see note at the R-15.31/R-15.32 block above).
  guard_row <- guard_review_row(con)
  expect_equal(nrow(guard_row), 1)
  expect_identical(guard_row$kind[[1]], "work_order_reingest")
  expect_identical(guard_row$subkind[[1]], "blocked")
  guard_diag <- jsonlite::fromJSON(guard_row$payload[[1]])
  expect_equal(guard_diag$n_rows_blocked, 1)
})

# ---- Phase 7b item 1: .ct_rewrite_review_payloads() must key on `kind` too -

test_that("Phase-7b item 1: a row that is BOTH feature- and analyte-pending stamps ONLY the unknown_feature item's uuid_target with the alias uuid; the unknown_analyte item sharing the SAME source_ref is left NA", {
  setup <- commit_test_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  files <- tibble::tibble(hash = setup$hash, filename = basename(setup$path),
                          adapter = "esdat/1", rank = 3L, kept = TRUE)
  results <- mk_row(source_ref = "r1", source_hash = setup$hash,
                     feature_raw = "T.NEW-P1-FEAT", analyte_raw = "NEW-P1-ANALYTE",
                     method_raw = "NEW-P1-METHOD", cas_number = NA_character_,
                     sample_datetime_raw = "10 Jul 2025 09:00")
  event <- mk_event(results, work_order = setup$work_order)
  out <- reconcile_event(event, con)

  # Reproduction premise: one clean row produces TWO review items, both keyed
  # on the SAME source_ref ("r1") - exactly the collision .ct_rewrite_review_
  # payloads() must disambiguate by `kind`, not by (source_hash, source_ref).
  expect_equal(nrow(out$review), 2)
  expect_setequal(out$review$kind, c("unknown_feature", "unknown_analyte"))
  expect_true(all(out$review$source_ref == "r1"))
  expect_equal(nrow(out$clean), 1)

  resolved <- mk_resolved(clean = out$clean, review = out$review, skipped = out$skipped,
                          counts = c(new = nrow(out$clean)))
  commit_event(mk_commit_event(files, work_order = setup$work_order), resolved, con)

  stored <- DBI::dbGetQuery(con,
    "SELECT kind, uuid_target FROM review_queue WHERE kind IN ('unknown_feature','unknown_analyte') AND source_hash = ?",
    params = list(setup$hash))
  expect_equal(nrow(stored), 2)
  feat_row <- stored[stored$kind == "unknown_feature", , drop = FALSE]
  an_row <- stored[stored$kind == "unknown_analyte", , drop = FALSE]

  alias <- dangling_alias_row(con, .rc_feature_key("T.NEW-P1-FEAT"))
  expect_equal(nrow(alias), 1)

  # Pre-fix bug: the per-row loop had no `kind` filter, so the (source_hash,
  # source_ref) key matched BOTH review rows and stamped uuid_target on
  # whichever one the loop reached, including the unknown_analyte item -
  # which confirm_feature_aliases() would then wrongly close as resolved
  # while its lab_method stayed dangling.
  expect_identical(feat_row$uuid_target[[1]], alias$uuid[[1]])
  expect_true(is.na(an_row$uuid_target[[1]]))
})

# ---- Phase 7b item 2: commit_event()'s return value must distinguish a
#      guard-blocked call from a real commit ---------------------------------

test_that("Phase-7b item 2: commit_event() returns a guard verdict - blocked = FALSE for a real commit, blocked = TRUE with n_review = 1 for a guard-blocked re-download", {
  setup <- commit_test_setup(filename = "PROJ_A.ESDAT_XX9990002_0.Chemistry2e.CSV",
                              work_order = "XX9990002", revision = 0L)
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  files0 <- tibble::tibble(hash = setup$hash, filename = basename(setup$path),
                           adapter = "esdat/1", rank = 3L, kept = TRUE)
  event0 <- mk_event(mk_row(source_ref = "r1", source_hash = setup$hash,
                             work_order = "XX9990002", revision = 0L,
                             sample_datetime_raw = "01 Aug 2025 09:00"),
                      work_order = "XX9990002")
  resolved0 <- reconcile_event(event0, con)
  expect_equal(nrow(resolved0$clean), 1)  # sanity: a real, unblocked commit
  out0 <- commit_event(mk_commit_event(files0, work_order = "XX9990002"), resolved0, con)
  expect_false(isTRUE(out0$blocked))

  # a differently-named, same-revision re-download matching NOTHING already
  # loaded - the classic F.10 block.
  lo <- add_reconciled_file(setup, "PROJ_A.ESDAT_XX9990002_0_REDOWNLOAD.Chemistry2e.CSV",
                             work_order = "XX9990002", revision = 0L)
  files_lo <- tibble::tibble(hash = lo$hash, filename = basename(lo$path),
                             adapter = "esdat/1", rank = 3L, kept = TRUE)
  event_lo <- mk_event(mk_row(source_ref = "r1", source_hash = lo$hash,
                               work_order = "XX9990002", revision = 0L,
                               sample_datetime_raw = "03 Aug 2025 09:00"),
                        work_order = "XX9990002")
  resolved_lo <- reconcile_event(event_lo, con)
  before_sample <- count_rows(con, "sample")
  before_analysis <- count_rows(con, "analysis")
  out_lo <- commit_event(mk_commit_event(files_lo, work_order = "XX9990002"), resolved_lo, con)

  # Pre-fix: commit_event() returned invisible(NULL) from BOTH branches, so a
  # caller (.ig_reconcile_and_commit(), R/ingest.R) could not tell a blocked
  # event from a committed one and counted it as committed anyway.
  expect_true(isTRUE(out_lo$blocked))
  expect_equal(out_lo$n_review, 1)
  expect_equal(count_rows(con, "sample"), before_sample)      # nothing written
  expect_equal(count_rows(con, "analysis"), before_analysis)
})

# ---- Phase 7b item 3: retrying a blocked event must be a clean no-op abort -

test_that("Phase-7b item 3: a SECOND commit_event() on an already-blocked (needs_review) event is a clean no-op abort, not an illegal needs_review -> needs_review transition error", {
  setup <- commit_test_setup(filename = "PROJ_A.ESDAT_XX9990003_0.Chemistry2e.CSV",
                              work_order = "XX9990003", revision = 0L)
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  files0 <- tibble::tibble(hash = setup$hash, filename = basename(setup$path),
                           adapter = "esdat/1", rank = 3L, kept = TRUE)
  event0 <- mk_event(mk_row(source_ref = "r1", source_hash = setup$hash,
                             work_order = "XX9990003", revision = 0L,
                             sample_datetime_raw = "01 Aug 2025 09:00"),
                      work_order = "XX9990003")
  commit_event(mk_commit_event(files0, work_order = "XX9990003"),
               reconcile_event(event0, con), con)

  # a differently-named re-download that trips the F.10 guard
  lo <- add_reconciled_file(setup, "PROJ_A.ESDAT_XX9990003_0_REDOWNLOAD.Chemistry2e.CSV",
                             work_order = "XX9990003", revision = 0L)
  files_lo <- tibble::tibble(hash = lo$hash, filename = basename(lo$path),
                             adapter = "esdat/1", rank = 3L, kept = TRUE)
  event_lo <- mk_event(mk_row(source_ref = "r1", source_hash = lo$hash,
                               work_order = "XX9990003", revision = 0L,
                               sample_datetime_raw = "03 Aug 2025 09:00"),
                        work_order = "XX9990003")
  resolved_lo <- reconcile_event(event_lo, con)

  out1 <- commit_event(mk_commit_event(files_lo, work_order = "XX9990003"), resolved_lo, con)
  expect_true(isTRUE(out1$blocked))

  state_after_1 <- DBI::dbGetQuery(con, "SELECT state FROM ingest_file WHERE hash = ?",
                                   params = list(lo$hash))$state[[1]]
  expect_identical(state_after_1, "needs_review")

  before_sample <- count_rows(con, "sample")
  before_analysis <- count_rows(con, "analysis")
  before_review <- count_rows(con, "review_queue")

  # Pre-fix: `.ct_set_file_states()`'s needs_review_only branch re-issued the
  # same state on the SECOND call - needs_review -> needs_review - which is
  # not in `.st_ingest_transitions[["needs_review"]]`, so it aborted (and
  # rolled back the whole transaction) instead of being the no-op the
  # blocking contract promises.
  out2 <- commit_event(mk_commit_event(files_lo, work_order = "XX9990003"), resolved_lo, con)
  expect_true(isTRUE(out2$blocked))

  state_after_2 <- DBI::dbGetQuery(con, "SELECT state FROM ingest_file WHERE hash = ?",
                                   params = list(lo$hash))$state[[1]]
  expect_identical(state_after_2, "needs_review")
  expect_equal(count_rows(con, "sample"), before_sample)
  expect_equal(count_rows(con, "analysis"), before_analysis)
  # Round-2 item 3: the missing assertion - `before_review` was captured but
  # never checked, so a SECOND identical work_order_reingest row landing on
  # every retry went uncaught. Find-or-create (keyed on kind = 'work_order_
  # reingest' AND work_order = ? AND status = 'open') means the second call
  # reuses the first call's open row rather than minting another.
  expect_equal(count_rows(con, "review_queue"), before_review)
  expect_equal(out2$n_review, 0)   # nothing NEW was opened on the retry

  # A THIRD call - the audit's own reproduction was "3 successive
  # commit_event() calls -> 3 identical work_order_reingest review rows".
  out3 <- commit_event(mk_commit_event(files_lo, work_order = "XX9990003"), resolved_lo, con)
  expect_true(isTRUE(out3$blocked))
  expect_equal(out3$n_review, 0)
  expect_equal(count_rows(con, "review_queue"), before_review)

  guard_row <- guard_review_row(con)
  expect_equal(nrow(guard_row), 1)
})

# ---- commit-1 (round-3): a retry must not re-insert a co-resident ---------
#      ordinary reconcile review item on every call ------------------------

test_that("commit-1: a blocked event that ALSO carries an ordinary reconcile review item (e.g. unknown_feature) does not re-insert that item on every retry - only the guard's own find-or-create was deduped, not co-resident review rows", {
  setup <- commit_test_setup(filename = "C1_A0.CSV", work_order = "XY9990070", revision = 0L)
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  files0 <- tibble::tibble(hash = setup$hash, filename = basename(setup$path),
                           adapter = "esdat/1", rank = 3L, kept = TRUE)
  commit_event(mk_commit_event(files0, work_order = "XY9990070"),
               mk_resolved(mk_clean_row(source_hash = setup$hash, work_order = "XY9990070")), con)

  a1 <- add_reconciled_file(setup, "C1_A1_REDL.CSV", work_order = "XY9990070", revision = 0L)
  files1 <- tibble::tibble(hash = a1$hash, filename = basename(a1$path),
                           adapter = "esdat/1", rank = 3L, kept = TRUE)
  clean <- mk_clean_row(source_hash = a1$hash, work_order = "XY9990070",
                        sample_date = as.Date("2025-09-01"),
                        sample_datetime = as.POSIXct("2025-09-01 09:00:00", tz = "Australia/Sydney"))
  review <- tibble::tibble(
    source_ref = "row1", kind = "unknown_feature", subkind = NA_character_,
    payload = "{}", n_rows = 1L, source_hash = a1$hash,
    uuid_existing = NA_character_, uuid_alias = NA_character_
  )
  ev <- mk_commit_event(files1, work_order = "XY9990070")
  res <- mk_resolved(clean, review)

  before_review <- count_rows(con, "review_queue")
  out1 <- commit_event(ev, res, con)
  out2 <- commit_event(ev, res, con)
  out3 <- commit_event(ev, res, con)

  expect_true(isTRUE(out1$blocked) && isTRUE(out2$blocked) && isTRUE(out3$blocked))
  # Pre-fix: n_review was 2/1/1 and review_queue kinds ended
  # work_order_reingest = 1, unknown_feature = 3 (one new duplicate per
  # retry). One guard row PLUS one unknown_feature row on the FIRST call,
  # then a true no-op on every retry.
  expect_equal(out1$n_review, 2)
  expect_equal(out2$n_review, 0)
  expect_equal(out3$n_review, 0)
  kinds <- DBI::dbGetQuery(con, "SELECT kind, count(*) AS n FROM review_queue GROUP BY kind")
  expect_equal(kinds$n[kinds$kind == "work_order_reingest"], 1)
  expect_equal(kinds$n[kinds$kind == "unknown_feature"], 1)
  expect_equal(count_rows(con, "review_queue"), before_review + 2)
})

# ---- commit-8 (round-3): a work_order_reingest guard row must be closable -

test_that("commit-8: a work_order_reingest guard row's uuid_target is stamped with the blocked work order's project uuid, so review_queue_close() can actually close it - pre-fix, no code path could ever set status = 'resolved' on it", {
  setup <- commit_test_setup(filename = "C8_A0.CSV", work_order = "XY9990080", revision = 0L)
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  files0 <- tibble::tibble(hash = setup$hash, filename = basename(setup$path),
                           adapter = "esdat/1", rank = 3L, kept = TRUE)
  commit_event(mk_commit_event(files0, work_order = "XY9990080"),
               mk_resolved(mk_clean_row(source_hash = setup$hash, work_order = "XY9990080")), con)

  a1 <- add_reconciled_file(setup, "C8_A1_REDL.CSV", work_order = "XY9990080", revision = 0L)
  files1 <- tibble::tibble(hash = a1$hash, filename = basename(a1$path),
                           adapter = "esdat/1", rank = 3L, kept = TRUE)
  clean <- mk_clean_row(source_hash = a1$hash, work_order = "XY9990080",
                        sample_date = as.Date("2025-09-01"),
                        sample_datetime = as.POSIXct("2025-09-01 09:00:00", tz = "Australia/Sydney"))
  out <- commit_event(mk_commit_event(files1, work_order = "XY9990080"), mk_resolved(clean), con)
  expect_true(isTRUE(out$blocked))

  guard_row <- guard_review_row(con)
  expect_equal(nrow(guard_row), 1)
  proj_uuid <- DBI::dbGetQuery(con, "SELECT uuid FROM project WHERE name = ?",
                               params = list("XY9990080"))$uuid[[1]]
  target_row <- DBI::dbGetQuery(
    con, "SELECT uuid_target FROM review_queue WHERE kind = 'work_order_reingest'"
  )
  expect_identical(target_row$uuid_target[[1]], proj_uuid)

  n_closed <- review_queue_close(con, uuid_target = proj_uuid, resolution = "handled manually",
                                 resolved_by = "robin", kind = "work_order_reingest")
  expect_equal(n_closed, 1L)
  status_after <- DBI::dbGetQuery(con, "SELECT status FROM review_queue WHERE kind = 'work_order_reingest'")$status[[1]]
  expect_identical(status_after, "resolved")
})

# ---- Phase 7b item 8: n_rows_blocked must be counted PER WORK ORDER --------

test_that("Phase-7b item 8: a multi-work-order event's guard row counts n_rows_blocked against ONLY the work order it fired for, not every unmatched row across the whole event", {
  setup <- commit_test_setup(filename = "P8_A0.CSV", work_order = "XX9990020", revision = 0L)
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  # Seed TWO work orders, each with one existing sample.
  files_a0 <- tibble::tibble(hash = setup$hash, filename = basename(setup$path),
                             adapter = "esdat/1", rank = 3L, kept = TRUE)
  event_a0 <- mk_event(mk_row(source_ref = "r1", source_hash = setup$hash,
                               work_order = "XX9990020", revision = 0L,
                               sample_datetime_raw = "01 Aug 2025 09:00"),
                        work_order = "XX9990020")
  commit_event(mk_commit_event(files_a0, work_order = "XX9990020"),
               reconcile_event(event_a0, con), con)

  b0 <- add_reconciled_file(setup, "P8_B0.CSV", work_order = "XX9990021", revision = 0L)
  files_b0 <- tibble::tibble(hash = b0$hash, filename = basename(b0$path),
                             adapter = "esdat/1", rank = 3L, kept = TRUE)
  event_b0 <- mk_event(mk_row(source_ref = "r1", source_hash = b0$hash,
                               work_order = "XX9990021", revision = 0L,
                               sample_datetime_raw = "01 Aug 2025 09:00"),
                        work_order = "XX9990021")
  commit_event(mk_commit_event(files_b0, work_order = "XX9990021"),
               reconcile_event(event_b0, con), con)

  # ONE event spanning BOTH now-loaded work orders, each carrying ONE clean
  # row that matches nothing already loaded for ITS OWN work order (the
  # block condition, evaluated separately per WO by .ct_reingest_guard()'s
  # `for (wo in wos)` loop).
  a1 <- add_reconciled_file(setup, "P8_A1_REDL.CSV", work_order = "XX9990020", revision = 0L)
  b1 <- add_reconciled_file(setup, "P8_B1_REDL.CSV", work_order = "XX9990021", revision = 0L)
  files <- tibble::tibble(
    hash = c(a1$hash, b1$hash), filename = c(basename(a1$path), basename(b1$path)),
    adapter = "esdat/1", rank = 3L, kept = TRUE
  )
  clean <- dplyr::bind_rows(
    mk_clean_row(source_ref = "r1", source_hash = a1$hash, work_order = "XX9990020",
                 uuid_feature = "f-0001", sample_date = as.Date("2025-09-01"),
                 sample_datetime = as.POSIXct("2025-09-01 09:00:00", tz = "Australia/Sydney")),
    mk_clean_row(source_ref = "r2", source_hash = b1$hash, work_order = "XX9990021",
                 uuid_feature = "f-0002", sample_date = as.Date("2025-09-02"),
                 sample_datetime = as.POSIXct("2025-09-02 09:00:00", tz = "Australia/Sydney"))
  )
  resolved <- mk_resolved(clean = clean)

  before_review <- count_rows(con, "review_queue")
  out <- commit_event(mk_commit_event(files, work_order = "XX9990020"), resolved, con)
  expect_true(isTRUE(out$blocked))
  expect_gt(count_rows(con, "review_queue"), before_review)

  guard_row <- guard_review_row(con)
  expect_equal(nrow(guard_row), 1)
  # Round-2 item 2: the typed review_queue.work_order column must name the
  # SAME work order the payload names (they used to be able to disagree).
  expect_identical(guard_row$work_order[[1]], "XX9990020")
  diag <- jsonlite::fromJSON(guard_row$payload[[1]])
  expect_identical(diag$work_order, "XX9990020")
  # Pre-fix: `.ct_unmatched_clean_rows(con, clean)` ran over the WHOLE
  # event's clean tibble (both WOs' rows), so the guard row that fired for
  # WO XX9990020 wrongly reported 2 - counting WO XX9990021's unmatched row
  # too - instead of the 1 row actually recorded against XX9990020.
  expect_equal(diag$n_rows_blocked, 1)
  # Round-2 item 4: n_rows_clean must be the SAME per-work-order granularity
  # as n_rows_blocked, not nrow(clean) (2, the whole event across both WOs).
  # Pre-fix this read 2 for a WO whose truth was 1 - "1 of 2 blocked" when
  # the real answer is "1 of 1".
  expect_equal(diag$n_rows_clean, 1)
})

# ---- T1.4 (round-3 regression): an NA-`work_order` clean row must not ------
#      escape the per-work-order F.10 filter -------------------------------

test_that("T1.4: a re-download of an already-loaded work order still blocks under F.10 when the clean row's OWN work_order is NA (a real crosstab/assemble shape, mirroring R/assemble.R:325's 'own, not foreign' NA classification)", {
  setup <- commit_test_setup(filename = "T14_A0.CSV", work_order = "XX9990060", revision = 0L)
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  files_a0 <- tibble::tibble(hash = setup$hash, filename = basename(setup$path),
                             adapter = "esdat/1", rank = 3L, kept = TRUE)
  commit_event(mk_commit_event(files_a0, work_order = "XX9990060"),
               mk_resolved(mk_clean_row(source_hash = setup$hash, work_order = "XX9990060")), con)

  a1 <- add_reconciled_file(setup, "T14_A1_REDL.CSV", work_order = "XX9990060", revision = 0L)
  files <- tibble::tibble(hash = a1$hash, filename = basename(a1$path),
                          adapter = "esdat/1", rank = 3L, kept = TRUE)
  # Pre-fix: `wo_clean <- clean[!is.na(clean$work_order) & clean$work_order ==
  # wo, ]` dropped this row from EVERY work order's subset, so
  # `.ct_unmatched_clean_rows(con, wo_clean)` saw zero rows, hit "EXEMPTION 3:
  # everything already matches", and committed a genuine duplicate.
  clean <- mk_clean_row(source_hash = a1$hash, work_order = NA_character_,
                        sample_date = as.Date("2025-09-01"),
                        sample_datetime = as.POSIXct("2025-09-01 09:00:00", tz = "Australia/Sydney"))
  before_sample <- count_rows(con, "sample")
  before_analysis <- count_rows(con, "analysis")

  out <- commit_event(mk_commit_event(files, work_order = "XX9990060"), mk_resolved(clean), con)

  expect_true(isTRUE(out$blocked))
  expect_equal(count_rows(con, "sample"), before_sample)
  expect_equal(count_rows(con, "analysis"), before_analysis)

  diag <- jsonlite::fromJSON(guard_review_row(con)$payload[[1]])
  expect_equal(diag$n_rows_blocked, 1)
})

test_that("T1.4: in a genuinely multi-WO event, an NA-work_order clean row is absorbed only by the event's own (home) work order, never by a different work order it was not recorded against", {
  setup <- commit_test_setup(filename = "T14B_A0.CSV", work_order = "XX9990063", revision = 0L)
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  # Seed TWO work orders, each already carrying one sample - mirrors the
  # Phase-7b item 8 multi-WO test above.
  files_a0 <- tibble::tibble(hash = setup$hash, filename = basename(setup$path),
                             adapter = "esdat/1", rank = 3L, kept = TRUE)
  commit_event(mk_commit_event(files_a0, work_order = "XX9990063"),
               mk_resolved(mk_clean_row(source_hash = setup$hash, work_order = "XX9990063")), con)

  b0 <- add_reconciled_file(setup, "T14B_B0.CSV", work_order = "XX9990064", revision = 0L)
  commit_event(mk_commit_event(
    tibble::tibble(hash = b0$hash, filename = basename(b0$path), adapter = "esdat/1", rank = 3L, kept = TRUE),
    work_order = "XX9990064"),
    mk_resolved(mk_clean_row(source_hash = b0$hash, work_order = "XX9990064", uuid_feature = "f-0002")), con)

  # ONE event whose home work_order is XX9990063 (WO A), that ALSO touches
  # WO B via its own `ingest_file.work_order` link (`.ct_event_work_orders()`
  # then reports BOTH WOs, exactly the multi-WO shape the per-WO filter
  # exists for), carrying an NA-work_order clean row for WO A's own
  # re-download AND a second file recorded against WO B that carries NO
  # clean row of its own at all (a fixture stand-in for "WO B's own upload
  # this run matched everything already loaded" - genuinely exempt on its
  # own evidence). If the fix mis-scoped the NA-absorb to EVERY `wo` in the
  # loop (rather than only `event$work_order`), the NA row would ALSO count
  # as WO B's unmatched evidence and WO B would spuriously block too, even
  # though WO B has no clean row of its own in this event at all.
  a1 <- add_reconciled_file(setup, "T14B_A1_REDL.CSV", work_order = "XX9990063", revision = 0L)
  b_dummy <- add_reconciled_file(setup, "T14B_B_TOUCH.CSV", work_order = "XX9990064", revision = 0L)
  files <- tibble::tibble(
    hash = c(a1$hash, b_dummy$hash), filename = c(basename(a1$path), basename(b_dummy$path)),
    adapter = "esdat/1", rank = 3L, kept = TRUE
  )
  clean <- mk_clean_row(source_ref = "r1", source_hash = a1$hash, work_order = NA_character_,
                        sample_date = as.Date("2025-09-01"),
                        sample_datetime = as.POSIXct("2025-09-01 09:00:00", tz = "Australia/Sydney"))

  out <- commit_event(mk_commit_event(files, work_order = "XX9990063"), mk_resolved(clean), con)

  expect_true(isTRUE(out$blocked))
  guard_rows <- DBI::dbGetQuery(
    con, "SELECT work_order, payload FROM review_queue WHERE kind = 'work_order_reingest'"
  )
  # ONLY WO A (the NA row's home) blocks. Pre-fix (whole-loop NA-absorb),
  # WO B's `wo_clean` would also pick up the NA row (which has no genuine
  # match for WO B either) and mint a second, spurious guard row for a work
  # order the event carries zero real clean rows for.
  expect_equal(nrow(guard_rows), 1)
  expect_identical(guard_rows$work_order[[1]], "XX9990063")
  diag <- jsonlite::fromJSON(guard_rows$payload[[1]])
  expect_equal(diag$n_rows_blocked, 1)
})

# ---- Phase-7b round-2, item 1 (RANK 1): the incoming-revision comparison
#      must be scoped PER work order, not leak across a multi-WO event ------

test_that("Phase-7b round-2 item 1: a same-revision re-download of WO A bundled with a genuinely higher-revision re-issue of WO B still blocks WO A - WO B's higher revision must not leak across and exempt WO A too", {
  setup <- commit_test_setup(filename = "PROJ_A.ESDAT_XX9990040_0.Chemistry2e.CSV",
                              work_order = "XX9990040", revision = 0L)
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  # ---- seed WO A (XX9990040) at revision 0.
  files_a0 <- tibble::tibble(hash = setup$hash, filename = basename(setup$path),
                             adapter = "esdat/1", rank = 3L, kept = TRUE)
  event_a0 <- mk_event(mk_row(source_ref = "r1", source_hash = setup$hash,
                               work_order = "XX9990040", revision = 0L,
                               sample_datetime_raw = "01 Aug 2025 09:00"),
                        work_order = "XX9990040")
  commit_event(mk_commit_event(files_a0, work_order = "XX9990040"),
               reconcile_event(event_a0, con), con)

  # ---- seed WO B (XX9990041) at revision 0, a DIFFERENT feature so its
  # sample is not silently reused from WO A's project (round-2 item 14).
  b0 <- add_reconciled_file(setup, "PROJ_B.ESDAT_XX9990041_0.Chemistry2e.CSV",
                             work_order = "XX9990041", revision = 0L)
  files_b0 <- tibble::tibble(hash = b0$hash, filename = basename(b0$path),
                             adapter = "esdat/1", rank = 3L, kept = TRUE)
  event_b0 <- mk_event(mk_row(source_ref = "r1", source_hash = b0$hash,
                               work_order = "XX9990041", revision = 0L,
                               feature_raw = "T.S02",
                               sample_datetime_raw = "01 Aug 2025 09:00"),
                        work_order = "XX9990041")
  commit_event(mk_commit_event(files_b0, work_order = "XX9990041"),
               reconcile_event(event_b0, con), con)

  before_sample <- count_rows(con, "sample")
  before_analysis <- count_rows(con, "analysis")

  # ONE event bundling: (1) a SAME-revision, differently-named re-download of
  # WO A carrying a row matching NOTHING already loaded (the classic F.10
  # block on its own); (2) a HIGHER-revision file for WO B, legitimately
  # exempt (A12 supersede path).
  a1 <- add_reconciled_file(setup, "PROJ_A.ESDAT_XX9990040_0_REDOWNLOAD.Chemistry2e.CSV",
                             work_order = "XX9990040", revision = 0L)
  b1 <- add_reconciled_file(setup, "PROJ_B.ESDAT_XX9990041_1_REISSUE.Chemistry2e.CSV",
                             work_order = "XX9990041", revision = 1L)
  files <- tibble::tibble(
    hash = c(a1$hash, b1$hash), filename = c(basename(a1$path), basename(b1$path)),
    adapter = "esdat/1", rank = 3L, kept = TRUE
  )
  clean <- dplyr::bind_rows(
    mk_clean_row(source_ref = "r1", source_hash = a1$hash, work_order = "XX9990040",
                 revision = 0L, uuid_feature = "f-0001",
                 sample_date = as.Date("2025-09-05"),
                 sample_datetime = as.POSIXct("2025-09-05 09:00:00", tz = "Australia/Sydney")),
    mk_clean_row(source_ref = "r2", source_hash = b1$hash, work_order = "XX9990041",
                 revision = 1L, uuid_feature = "f-0002", uuid_lab = "lm-0001", uuid_analyte = "a-0001",
                 sample_date = as.Date("2025-09-06"),
                 sample_datetime = as.POSIXct("2025-09-06 09:00:00", tz = "Australia/Sydney"))
  )
  resolved <- mk_resolved(clean = clean)

  out <- commit_event(mk_commit_event(files, work_order = "XX9990040"), resolved, con)

  # Pre-fix (RANK 1): .ct_incoming_revision() took max() over BOTH files on
  # the event regardless of work order, so WO B's revision 1 wrongly exempted
  # WO A's same-revision re-download too - blocked = FALSE, 2 NEW sample/
  # analysis rows (a genuine duplicate commit of WO A's already-loaded data).
  # Reproduced and verified against the pre-fix code before writing this fix.
  expect_true(isTRUE(out$blocked))
  expect_equal(count_rows(con, "sample"), before_sample)
  expect_equal(count_rows(con, "analysis"), before_analysis)

  guard_rows <- guard_review_row(con)
  expect_equal(nrow(guard_rows), 1)
  expect_identical(guard_rows$work_order[[1]], "XX9990040")
  diag <- jsonlite::fromJSON(guard_rows$payload[[1]])
  expect_identical(diag$work_order, "XX9990040")
  expect_equal(diag$revision_incoming, 0)   # NOT 1 (WO B's file's revision)
})

test_that("Phase-7b round-2 (max/min gap): TWO files of one event carrying DIFFERENT revisions for the SAME already-loaded work order are exempted by the HIGHEST recorded revision, not the lowest", {
  setup <- commit_test_setup(filename = "PROJ_A.ESDAT_XX9990030_1.Chemistry2e.CSV",
                              work_order = "XX9990030", revision = 1L)
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  # seed: WO XX9990030 already loaded at revision 1.
  files0 <- tibble::tibble(hash = setup$hash, filename = basename(setup$path),
                           adapter = "esdat/1", rank = 3L, kept = TRUE)
  event0 <- mk_event(mk_row(source_ref = "r1", source_hash = setup$hash,
                             work_order = "XX9990030", revision = 1L,
                             sample_datetime_raw = "01 Aug 2025 09:00"),
                      work_order = "XX9990030")
  commit_event(mk_commit_event(files0, work_order = "XX9990030"),
               reconcile_event(event0, con), con)

  # ONE event bundling TWO NEW files against the SAME WO - one at a LOWER
  # revision (0) than recorded, one at a HIGHER revision (2). If the incoming
  # revision were computed by min() instead of max(), the lower file would
  # make the guard wrongly fire even though a genuinely higher-revision
  # re-issue (2) is present too - the exact exemption 1 case.
  lo <- add_reconciled_file(setup, "PROJ_A.ESDAT_XX9990030_0_OLD.Chemistry2e.CSV",
                             work_order = "XX9990030", revision = 0L)
  hi <- add_reconciled_file(setup, "PROJ_A.ESDAT_XX9990030_2_NEW.Chemistry2e.CSV",
                             work_order = "XX9990030", revision = 2L)
  files <- tibble::tibble(
    hash = c(lo$hash, hi$hash), filename = c(basename(lo$path), basename(hi$path)),
    adapter = "esdat/1", rank = 3L, kept = TRUE
  )
  clean <- dplyr::bind_rows(
    mk_clean_row(source_ref = "r1", source_hash = lo$hash, work_order = "XX9990030",
                 revision = 0L, uuid_feature = "f-0001",
                 sample_date = as.Date("2025-09-10"),
                 sample_datetime = as.POSIXct("2025-09-10 09:00:00", tz = "Australia/Sydney")),
    mk_clean_row(source_ref = "r2", source_hash = hi$hash, work_order = "XX9990030",
                 revision = 2L, uuid_feature = "f-0001",
                 sample_date = as.Date("2025-09-10"),
                 sample_datetime = as.POSIXct("2025-09-10 09:00:00", tz = "Australia/Sydney"))
  )
  resolved <- mk_resolved(clean = clean)

  before_sample <- count_rows(con, "sample")
  out <- commit_event(mk_commit_event(files, work_order = "XX9990030"), resolved, con)

  # Kill-verified: with `min(revs)` substituted for `max(revs)` in
  # .ct_incoming_revision(), incoming_rev reads 0 (not > recorded_rev 1), so
  # the guard wrongly fires here (blocked = TRUE, 0 new samples) instead of
  # correctly exempting a genuinely higher-revision re-issue.
  expect_false(isTRUE(out$blocked))
  expect_gt(count_rows(con, "sample"), before_sample)
})

# ---- Phase-7b round-2, item 10: accumulate EVERY blocking work order's row -

test_that("Phase-7b round-2 item 10: a multi-WO event where BOTH work orders block gets a review row for EACH, not just the first - and each row's typed work_order column names its OWN work order (round-2 item 2)", {
  setup <- commit_test_setup(filename = "P10_A0.CSV", work_order = "XX9990050", revision = 0L)
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  # Seed TWO work orders, each with its OWN sample under its OWN project
  # (distinct features so round-2 item 14's cross-WO sample reuse cannot
  # collapse one WO's n_samples to zero and mask its block).
  files_a0 <- tibble::tibble(hash = setup$hash, filename = basename(setup$path),
                             adapter = "esdat/1", rank = 3L, kept = TRUE)
  event_a0 <- mk_event(mk_row(source_ref = "r1", source_hash = setup$hash,
                               work_order = "XX9990050", revision = 0L,
                               sample_datetime_raw = "01 Aug 2025 09:00"),
                        work_order = "XX9990050")
  commit_event(mk_commit_event(files_a0, work_order = "XX9990050"),
               reconcile_event(event_a0, con), con)

  b0 <- add_reconciled_file(setup, "P10_B0.CSV", work_order = "XX9990051", revision = 0L)
  files_b0 <- tibble::tibble(hash = b0$hash, filename = basename(b0$path),
                             adapter = "esdat/1", rank = 3L, kept = TRUE)
  event_b0 <- mk_event(mk_row(source_ref = "r1", source_hash = b0$hash,
                               work_order = "XX9990051", revision = 0L,
                               feature_raw = "T.S02",
                               sample_datetime_raw = "01 Aug 2025 09:00"),
                        work_order = "XX9990051")
  commit_event(mk_commit_event(files_b0, work_order = "XX9990051"),
               reconcile_event(event_b0, con), con)

  # ONE event bundling BOTH now-loaded work orders, each carrying ONE clean
  # row that matches nothing already loaded for ITS OWN work order.
  a1 <- add_reconciled_file(setup, "P10_A1_REDL.CSV", work_order = "XX9990050", revision = 0L)
  b1 <- add_reconciled_file(setup, "P10_B1_REDL.CSV", work_order = "XX9990051", revision = 0L)
  files <- tibble::tibble(
    hash = c(a1$hash, b1$hash), filename = c(basename(a1$path), basename(b1$path)),
    adapter = "esdat/1", rank = 3L, kept = TRUE
  )
  clean <- dplyr::bind_rows(
    mk_clean_row(source_ref = "r1", source_hash = a1$hash, work_order = "XX9990050",
                 uuid_feature = "f-0001", sample_date = as.Date("2025-09-01"),
                 sample_datetime = as.POSIXct("2025-09-01 09:00:00", tz = "Australia/Sydney")),
    mk_clean_row(source_ref = "r2", source_hash = b1$hash, work_order = "XX9990051",
                 uuid_feature = "f-0002", uuid_lab = "lm-0001", uuid_analyte = "a-0001",
                 sample_date = as.Date("2025-09-02"),
                 sample_datetime = as.POSIXct("2025-09-02 09:00:00", tz = "Australia/Sydney"))
  )
  resolved <- mk_resolved(clean = clean)

  out <- commit_event(mk_commit_event(files, work_order = "XX9990050"), resolved, con)
  expect_true(isTRUE(out$blocked))
  expect_equal(out$n_review, 2)

  # Pre-fix: .ct_reingest_guard() `return(row)`-ed inside the `for (wo in
  # wos)` loop, so only the FIRST blocking work order (XX9990050, since
  # event$work_order is first in `wos`) ever got a review row - WO XX9990051
  # was silently dropped even though it blocked too.
  guard_rows <- guard_review_row(con)
  expect_equal(nrow(guard_rows), 2)
  expect_setequal(guard_rows$work_order, c("XX9990050", "XX9990051"))

  diags <- lapply(guard_rows$payload, jsonlite::fromJSON)
  wos_in_payload <- vapply(diags, function(d) d$work_order, character(1))
  expect_setequal(wos_in_payload, c("XX9990050", "XX9990051"))
  for (d in diags) {
    expect_equal(d$n_rows_blocked, 1)
    expect_equal(d$n_rows_clean, 1)
  }
  # Round-2 item 2: each row's typed work_order column matches its OWN
  # payload's work_order, not both stamped with event$work_order
  # ("XX9990050") regardless of which WO the row is actually about.
  for (i in seq_len(nrow(guard_rows))) {
    expect_identical(guard_rows$work_order[[i]], diags[[i]]$work_order)
  }
})

# ---- Phase-7b round-2, item 11: the sample_date type guard must also apply
#      at .ct_find_or_create_sample() (not only .ct_group_date_start()) ------

test_that("Phase-7b round-2 item 11: .ct_find_or_create_sample() refuses a non-Date sample_date rather than silently storing a non-midnight datetime", {
  setup <- commit_test_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  before_sample <- count_rows(con, "sample")

  err <- tryCatch(
    .ct_find_or_create_sample(
      con, pending = TRUE, match_feature = NA_character_,
      alias_uuid = "fa-does-not-exist",
      sample_date = as.POSIXct("2025-06-10 09:00:00", tz = "Australia/Sydney"),
      sample_datetime = as.POSIXct("2025-06-10 09:00:00", tz = "Australia/Sydney"),
      uuid_project = "p-0001", organisation = "ALS", person = NA_character_,
      reason = "test"
    ),
    error = function(e) e
  )
  expect_s3_class(err, "sampletidy_error")
  expect_equal(count_rows(con, "sample"), before_sample)  # nothing written
})

# ---- Phase-7b round-2, item 13: a retry's block reason must not be lost ----

test_that("Phase-7b round-2 item 13: a second .ct_set_file_states() call with a DIFFERENT reason updates ingest_file.state_reason instead of leaving it stuck on the first block's reason", {
  setup <- commit_test_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  files <- tibble::tibble(hash = setup$hash, filename = basename(setup$path),
                          adapter = "esdat/1", rank = 3L, kept = TRUE)

  .ct_set_file_states(con, files, 0L, 1L, "first block reason")
  first <- DBI::dbGetQuery(con, "SELECT state, state_reason FROM ingest_file WHERE hash = ?",
                           params = list(setup$hash))
  expect_identical(first$state[[1]], "needs_review")
  expect_identical(first$state_reason[[1]], "first block reason")

  # Pre-fix: the needs_review no-op skip `next`-ed BEFORE
  # ingest_file_set_state() ran at all, so a retry's reason never reached
  # ingest_file.state_reason - the row stayed stuck on the FIRST reason.
  .ct_set_file_states(con, files, 0L, 1L, "second block reason")
  second <- DBI::dbGetQuery(con, "SELECT state, state_reason FROM ingest_file WHERE hash = ?",
                            params = list(setup$hash))
  expect_identical(second$state[[1]], "needs_review")
  expect_identical(second$state_reason[[1]], "second block reason")
})

# ---- orphan (NA work_order) project find-or-create -------------------------
#
# `name = ?` bound to `NA` compiles to `name = NULL`, which SQL's three-valued
# logic never satisfies for any row - the find half of .ct_ensure_project()'s
# find-or-create silently never matched for an orphan (no work order) event,
# so every orphan commit minted its own indistinguishable `name IS NULL`
# project row with nothing to ever collapse them.

test_that(".ct_ensure_project(): two calls with a NA (orphan) work_order return the SAME project uuid, not two NULL-name rows", {
  dir <- withr::local_tempdir()
  db_path <- seed_db(dir = dir)
  con <- seed_con(db_path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  null_name_count <- function() {
    DBI::dbGetQuery(con, "SELECT count(*) AS n FROM project WHERE name IS NULL")$n
  }
  expect_equal(null_name_count(), 0)

  uuid1 <- .ct_ensure_project(con, NA_character_, "test orphan 1")
  uuid2 <- .ct_ensure_project(con, NA_character_, "test orphan 2")

  expect_identical(uuid1, uuid2)
  expect_equal(null_name_count(), 1)

  # A real (non-NA) work order is unaffected: still find-or-create by name.
  uuid3 <- .ct_ensure_project(con, "XX1234567", "test named")
  uuid4 <- .ct_ensure_project(con, "XX1234567", "test named again")
  expect_identical(uuid3, uuid4)
  expect_equal(null_name_count(), 1)
})

test_that("commit_event(): two DIFFERENT orphan work orders (no work order recorded) share ONE anonymous project row, not one each", {
  dir <- withr::local_tempdir()
  db_path <- seed_db(dir = dir)
  con <- seed_con(db_path)
  ensure_test_asset_table(con)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  archive_dir <- withr::local_tempdir()
  withr::local_options(list("sampletidy.archive_dir" = archive_dir))

  src_dir <- withr::local_tempdir()
  mk_orphan_event <- function(i) {
    path <- file.path(src_dir, sprintf("2400-753%d-01_ACIRL_Field.CSV", i))
    writeLines(sprintf("field sheet %d", i), path)
    hash <- hash_file(path)
    DBI::dbExecute(con,
      "INSERT INTO ingest_file (hash, filename, path_first_seen, state, work_order, revision)
       VALUES (?, ?, ?, 'reconciled', NULL, 0)",
      params = list(hash, basename(path), path))
    files <- tibble::tibble(hash = hash, kept = TRUE)
    list(
      hash = hash,
      event = list(
        work_order = NA_character_, orphan = TRUE, results = tibble::tibble(),
        samples = tibble::tibble(), files = files, report = list()
      )
    )
  }
  mk_orphan_clean <- function(hash, feat, dt) mk_clean_row(
    source_hash = hash, source_ref = "r1", work_order = NA_character_,
    feature_raw = feat, sample_date = as.Date(dt),
    sample_datetime = as.POSIXct(NA)
  )

  null_name_count <- function() {
    DBI::dbGetQuery(con, "SELECT count(*) AS n FROM project WHERE name IS NULL")$n
  }
  expect_equal(null_name_count(), 0)

  wo1 <- mk_orphan_event(1)
  wo2 <- mk_orphan_event(2)
  r1 <- commit_event(wo1$event,
    mk_resolved(clean = mk_orphan_clean(wo1$hash, "T.S01", "2025-06-10")), con)
  r2 <- commit_event(wo2$event,
    mk_resolved(clean = mk_orphan_clean(wo2$hash, "T.S02", "2025-06-11")), con)

  expect_false(isTRUE(r1$blocked))
  expect_false(isTRUE(r2$blocked))
  # Pre-fix: this was 2 - a fresh NULL-name "Work order" project row per
  # orphan commit, growing without bound and never collapsing.
  expect_equal(null_name_count(), 1)

  # Both orphan events' samples hang off the SAME shared anonymous project.
  proj_uuids <- DBI::dbGetQuery(con,
    'SELECT DISTINCT p.uuid FROM "sample" s JOIN project p ON p.uuid = s.uuid_project
      WHERE p.name IS NULL')
  expect_equal(nrow(proj_uuids), 1)
})

# ---- R-9.14 / A80: the ACIRL project hierarchy ------------------------------
#
# campaign -> ACIRL report -> ALS work order, with samples on the CHILD wherever
# an ALS order is cited and on the parent when none is.
#
# Every number these tests encode was MEASURED off the real corpus and the live
# registry before a line of this was written (`scratchpad/a80_cardinality_probe.R`,
# `a80_tree_probe.R`), because A80 taken literally would have overwritten the
# campaign on 116 of the 129 cited work orders.

a80_seed_project <- function(con, name, type = "Work order",
                             parent = NA_character_, root = NA_character_) {
  u <- uuid::UUIDgenerate()
  DBI::dbExecute(
    con,
    "INSERT INTO project (uuid, uuid_parent, uuid_root, name, type) VALUES (?, ?, ?, ?, ?)",
    params = list(u, parent, root, name, type)
  )
  u
}

a80_project <- function(con, name) {
  DBI::dbGetQuery(
    con, "SELECT uuid, uuid_parent, uuid_root, name, type FROM project WHERE name = ?",
    params = list(name)
  )
}

# An ACIRL event as assembly really builds one: no home work order (the header
# carries a report number, never a work order, and `2400-*` is never parsed
# from a filename), with PLAN-07 R-7.5b's per-hash `sources`.
a80_event <- function(con, src_dir, report_no, cited = character(0), tag = "a") {
  path <- file.path(src_dir, sprintf("%s_%s_WMF.xls", report_no, tag))
  writeLines(sprintf("acirl workbook %s %s", report_no, tag), path)
  hash <- hash_file(path)
  DBI::dbExecute(
    con,
    "INSERT INTO ingest_file (hash, filename, path_first_seen, state, work_order, revision)
     VALUES (?, ?, ?, 'reconciled', NULL, 0)",
    params = list(hash, basename(path), path)
  )
  list(
    hash = hash,
    path = path,
    event = list(
      work_order = NA_character_, orphan = TRUE,
      results = tibble::tibble(), samples = tibble::tibble(),
      files = tibble::tibble(hash = hash, kept = TRUE),
      report = list(sources = stats::setNames(list(list(
        hash = hash, filename = basename(path), report_no = report_no,
        als_work_orders = cited, feature_aliases = list(), als_candidates = list()
      )), hash))
    )
  )
}

a80_clean <- function(hash, report_no, feature = "T.S01", date = "2025-06-10") {
  mk_clean_row(
    source_hash = hash, source_ref = "r1", work_order = report_no, org = "ACIRL",
    adapter = "acirl_field_xlsx/1", feature_raw = feature,
    sample_date = as.Date(date), sample_datetime = as.POSIXct(NA)
  )
}

# `seed_db()` already seeds a `sample` row of its own, so a bare
# `SELECT DISTINCT uuid_project FROM sample` conflates it with the rows the
# commit under test wrote. Only the NEW samples say where A80 filed anything.
a80_sample_uuids <- function(con) {
  DBI::dbGetQuery(con, 'SELECT uuid FROM "sample"')$uuid
}
a80_new_sample_projects <- function(con, before) {
  rows <- DBI::dbGetQuery(con, 'SELECT uuid, uuid_project FROM "sample"')
  unique(rows$uuid_project[!(rows$uuid %in% before)])
}

a80_setup <- function() {
  dir <- withr::local_tempdir(.local_envir = parent.frame())
  db_path <- seed_db(dir = dir)
  con <- seed_con(db_path)
  ensure_test_asset_table(con)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE), envir = parent.frame())
  withr::local_options(
    list("sampletidy.archive_dir" = withr::local_tempdir(.local_envir = parent.frame())),
    .local_envir = parent.frame()
  )
  list(con = con, src = withr::local_tempdir(.local_envir = parent.frame()))
}

test_that("A80: an ACIRL event with a cited ALS order builds campaign -> report -> work order, and its samples attach to the CHILD", {
  s <- a80_setup()
  con <- s$con
  # The measured starting state: the ALS work order already exists and already
  # sits under a campaign (116 of 129 real ones do).
  campaign <- a80_seed_project(con, "EPL quarterly", type = NA_character_)
  DBI::dbExecute(con, "UPDATE project SET uuid_root = uuid WHERE uuid = ?", params = list(campaign))
  wo <- a80_seed_project(con, "ES2420251", parent = campaign, root = campaign)

  ev <- a80_event(con, s$src, "2400-7400-06-01", cited = "ES2420251")
  before <- a80_sample_uuids(con)
  res <- commit_event(ev$event, mk_resolved(clean = a80_clean(ev$hash, "2400-7400-06-01")), con)
  expect_false(isTRUE(res$blocked))

  report <- a80_project(con, "2400-7400-06-01")
  expect_equal(nrow(report), 1)
  expect_identical(report$type[[1]], "ACIRL report")
  # The report is INSERTED between them; the campaign is displaced, not lost.
  expect_identical(report$uuid_parent[[1]], campaign)
  expect_identical(report$uuid_root[[1]], campaign)

  wo_after <- a80_project(con, "ES2420251")
  expect_identical(wo_after$uuid[[1]], wo)          # same row, re-pointed
  expect_identical(wo_after$uuid_parent[[1]], report$uuid[[1]])
  expect_identical(wo_after$uuid_root[[1]], campaign)

  # A80: samples attach to the CHILD wherever an ALS order is cited.
  expect_identical(a80_new_sample_projects(con, before), wo)
})

test_that("A80: the displaced campaign survives in change_log, so the move is recoverable", {
  s <- a80_setup()
  con <- s$con
  campaign <- a80_seed_project(con, "Monthly monitoring", type = NA_character_)
  a80_seed_project(con, "ES2420251", parent = campaign, root = campaign)

  ev <- a80_event(con, s$src, "2400-7400-06-01", cited = "ES2420251")
  commit_event(ev$event, mk_resolved(clean = a80_clean(ev$hash, "2400-7400-06-01")), con)

  moved <- DBI::dbGetQuery(
    con,
    "SELECT old, new FROM change_log
      WHERE tbl = 'project' AND field = 'uuid_parent' AND action = 'update'"
  )
  expect_true(any(moved$old == campaign))
})

test_that("A80: a dust-only workbook (no ALS citation) files under the report project itself, as its own root", {
  s <- a80_setup()
  con <- s$con
  ev <- a80_event(con, s$src, "2400-7538-02", cited = character(0))
  before <- a80_sample_uuids(con)
  commit_event(ev$event, mk_resolved(clean = a80_clean(ev$hash, "2400-7538-02")), con)

  report <- a80_project(con, "2400-7538-02")
  expect_equal(nrow(report), 1)
  expect_true(is.na(report$uuid_parent[[1]]))
  # The registry's own convention for a root row: it points at itself.
  expect_identical(report$uuid_root[[1]], report$uuid[[1]])

  expect_identical(a80_new_sample_projects(con, before), report$uuid[[1]])
  # No anonymous orphan row was minted for it - that is the wart A80 removes.
  expect_equal(DBI::dbGetQuery(con, "SELECT count(*) n FROM project WHERE name IS NULL")$n, 0)
})

test_that("A80: a cited ALS order we have never seen is created as a child of the report", {
  s <- a80_setup()
  con <- s$con
  ev <- a80_event(con, s$src, "2400-7400-09-01", cited = "ES2434371")
  commit_event(ev$event, mk_resolved(clean = a80_clean(ev$hash, "2400-7400-09-01")), con)

  report <- a80_project(con, "2400-7400-09-01")
  wo <- a80_project(con, "ES2434371")
  expect_equal(nrow(wo), 1)
  expect_identical(wo$uuid_parent[[1]], report$uuid[[1]])
  # No campaign anywhere, so the report is the root of the pair (13 of 129).
  expect_identical(report$uuid_root[[1]], report$uuid[[1]])
  expect_identical(wo$uuid_root[[1]], report$uuid[[1]])
})

test_that("A80: a report number colliding with an existing project MERGES into it and never touches its parent", {
  s <- a80_setup()
  con <- s$con
  # The measured shape of the six real collisions: a `Monthly gas monitoring`
  # project already carrying samples, already a child of a campaign.
  gas_campaign <- a80_seed_project(con, "Monthly gas monitoring", type = NA_character_)
  gas <- a80_seed_project(con, "2400-7222-01", type = "Monthly gas monitoring",
                          parent = gas_campaign, root = gas_campaign)
  # A child of its own, of a kind that is NOT a lab work order. The duplicate
  # check restricts `kids` to `type = 'Work order'` precisely so a merged
  # project's unrelated children cannot be misread as ALS orders already filed.
  a80_seed_project(con, "Gauge block A", type = "Dust monitoring",
                   parent = gas, root = gas_campaign)
  als_campaign <- a80_seed_project(con, "EPL quarterly", type = NA_character_)
  a80_seed_project(con, "ES2420251", parent = als_campaign, root = als_campaign)

  ev <- a80_event(con, s$src, "2400-7222-01", cited = "ES2420251")
  commit_event(ev$event, mk_resolved(clean = a80_clean(ev$hash, "2400-7222-01")), con)

  rows <- a80_project(con, "2400-7222-01")
  expect_equal(nrow(rows), 1)                       # merged, not duplicated
  expect_identical(rows$uuid[[1]], gas)
  expect_identical(rows$type[[1]], "Monthly gas monitoring")
  expect_identical(rows$uuid_parent[[1]], gas_campaign)   # NOT re-pointed
  # A pre-existing gas project is not a new sampling event under a reused
  # number, so the merge must not raise the duplicate flag (contract A80).
  expect_equal(
    DBI::dbGetQuery(con, "SELECT count(*) n FROM review_queue WHERE kind = 'duplicate_report_number'")$n,
    0
  )
})

test_that("A80: a report number reused for a DIFFERENT sampling event raises duplicate_report_number - and still imports", {
  s <- a80_setup()
  con <- s$con
  ev1 <- a80_event(con, s$src, "2400-7430-01", cited = "ES2417748", tag = "a")
  commit_event(ev1$event, mk_resolved(clean = a80_clean(ev1$hash, "2400-7430-01", date = "2024-05-29")), con)

  # The worst of the three real collisions: the May 2025 report carrying the
  # 2024 filename AND the 2024 report number; only its date and ALS order are
  # right.
  ev2 <- a80_event(con, s$src, "2400-7430-01", cited = "ES2515829", tag = "b")
  res <- commit_event(
    ev2$event,
    mk_resolved(clean = a80_clean(ev2$hash, "2400-7430-01", feature = "T.S02", date = "2025-05-27")),
    con
  )

  expect_false(isTRUE(res$blocked))                 # "the data still imports"
  flag <- DBI::dbGetQuery(
    con, "SELECT kind, work_order, payload FROM review_queue WHERE kind = 'duplicate_report_number'"
  )
  expect_equal(nrow(flag), 1)
  expect_identical(flag$work_order[[1]], "2400-7430-01")
  diag <- jsonlite::fromJSON(flag$payload[[1]])
  expect_identical(unlist(diag$als_work_orders_incoming), "ES2515829")
  expect_identical(unlist(diag$als_work_orders_already_filed), "ES2417748")

  # One parent, two children - which is what makes the reuse survivable.
  report <- a80_project(con, "2400-7430-01")
  kids <- DBI::dbGetQuery(con, "SELECT name FROM project WHERE uuid_parent = ? ORDER BY name",
                          params = list(report$uuid[[1]]))
  expect_identical(kids$name, c("ES2417748", "ES2515829"))
})

test_that("A80: a re-saved report (same number, same cited order) does NOT raise duplicate_report_number", {
  s <- a80_setup()
  con <- s$con
  # 13 of the 16 real repeats are this: one report re-saved or revised. Byte
  # difference alone is not a discriminator, so flagging them would bury the
  # three that matter.
  ev1 <- a80_event(con, s$src, "2400-7399-04", cited = "ES2417748", tag = "a")
  commit_event(ev1$event, mk_resolved(clean = a80_clean(ev1$hash, "2400-7399-04")), con)
  ev2 <- a80_event(con, s$src, "2400-7399-04", cited = "ES2417748", tag = "b")
  commit_event(ev2$event, mk_resolved(clean = a80_clean(ev2$hash, "2400-7399-04", feature = "T.S02")), con)

  expect_equal(
    DBI::dbGetQuery(con, "SELECT count(*) n FROM review_queue WHERE kind = 'duplicate_report_number'")$n,
    0
  )
  # And the second commit re-points nothing: the order is already adopted, so
  # there is no second UPDATE and no change_log churn per retry.
  updates <- DBI::dbGetQuery(
    con,
    "SELECT count(*) n FROM change_log
      WHERE tbl = 'project' AND field = 'uuid_parent' AND action = 'update'"
  )$n
  expect_equal(updates, 1)
})

test_that("A80: an ALS order already claimed by ANOTHER ACIRL report keeps its parent and raises project_parent_conflict", {
  s <- a80_setup()
  con <- s$con
  # Measured: 4 of the 129 cited orders are cited by two different report
  # numbers (e.g. ES2245792 by 2400-7222-12-01 and -12-04). A row has one
  # parent, so the second report cannot also adopt it.
  ev1 <- a80_event(con, s$src, "2400-7222-12-01", cited = "ES2245792", tag = "a")
  commit_event(ev1$event, mk_resolved(clean = a80_clean(ev1$hash, "2400-7222-12-01")), con)
  first_report <- a80_project(con, "2400-7222-12-01")

  ev2 <- a80_event(con, s$src, "2400-7222-12-04", cited = "ES2245792", tag = "b")
  res <- commit_event(
    ev2$event,
    mk_resolved(clean = a80_clean(ev2$hash, "2400-7222-12-04", feature = "T.S02")), con
  )
  expect_false(isTRUE(res$blocked))

  wo <- a80_project(con, "ES2245792")
  expect_identical(wo$uuid_parent[[1]], first_report$uuid[[1]])   # NOT stolen

  flag <- DBI::dbGetQuery(
    con, "SELECT work_order, payload FROM review_queue WHERE kind = 'project_parent_conflict'"
  )
  expect_equal(nrow(flag), 1)
  expect_identical(flag$work_order[[1]], "ES2245792")
  diag <- jsonlite::fromJSON(flag$payload[[1]])
  expect_identical(diag$existing_parent_name, "2400-7222-12-01")

  # The samples still attach to the cited work order - the flag is about the
  # tree, not about where the data belongs.
  attached <- DBI::dbGetQuery(
    con, 'SELECT DISTINCT uuid_project FROM "sample" WHERE uuid_project = ?',
    params = list(wo$uuid[[1]])
  )
  expect_equal(nrow(attached), 1)
})

test_that("A80: a workbook citing TWO orders makes both children, attaches its samples to the PARENT, and raises no duplicate flag", {
  s <- a80_setup()
  con <- s$con
  campaign <- a80_seed_project(con, "EPL annual", type = NA_character_)
  a80_seed_project(con, "ES2507242", parent = campaign, root = campaign)
  a80_seed_project(con, "ES2407054", parent = campaign, root = campaign)

  ev <- a80_event(con, s$src, "2400-7454-03", cited = c("ES2507242", "ES2407054"))
  before <- a80_sample_uuids(con)
  commit_event(ev$event, mk_resolved(clean = a80_clean(ev$hash, "2400-7454-03")), con)

  report <- a80_project(con, "2400-7454-03")
  expect_identical(report$uuid_parent[[1]], campaign)
  kids <- DBI::dbGetQuery(con, "SELECT name FROM project WHERE uuid_parent = ? ORDER BY name",
                          params = list(report$uuid[[1]]))
  expect_identical(kids$name, c("ES2407054", "ES2507242"))

  # One event resolves to ONE project and the per-row ALS citation is not
  # carried past the sheet, so these samples cannot be split between the two
  # children. They sit on the report - honest about what we know.
  expect_identical(a80_new_sample_projects(con, before), report$uuid[[1]])

  # Both children were established in ONE call, so this is not a reused number.
  expect_equal(
    DBI::dbGetQuery(con, "SELECT count(*) n FROM review_queue WHERE kind = 'duplicate_report_number'")$n,
    0
  )
})

test_that("A80: two cited orders under DIFFERENT campaigns leave both campaigns intact and flag both", {
  s <- a80_setup()
  con <- s$con
  # The one real workbook with this shape: 2400-7286-03 cites ES2308842 (under
  # `EPL annual`) and ES2308767 (under `2022 March pollution incidents`).
  # There is no single campaign to promote, so nothing is displaced.
  c1 <- a80_seed_project(con, "EPL annual", type = NA_character_)
  c2 <- a80_seed_project(con, "2022 March pollution incidents", type = NA_character_)
  a80_seed_project(con, "ES2308842", parent = c1, root = c1)
  a80_seed_project(con, "ES2308767", parent = c2, root = c2)

  ev <- a80_event(con, s$src, "2400-7286-03", cited = c("ES2308842", "ES2308767"))
  commit_event(ev$event, mk_resolved(clean = a80_clean(ev$hash, "2400-7286-03")), con)

  expect_true(is.na(a80_project(con, "2400-7286-03")$uuid_parent[[1]]))
  expect_identical(a80_project(con, "ES2308842")$uuid_parent[[1]], c1)
  expect_identical(a80_project(con, "ES2308767")$uuid_parent[[1]], c2)
  expect_equal(
    DBI::dbGetQuery(con, "SELECT count(*) n FROM review_queue WHERE kind = 'project_parent_conflict'")$n,
    2
  )
})

test_that("A80: an event with no ACIRL report number is untouched - same project, no review rows", {
  s <- a80_setup()
  con <- s$con
  before <- count_rows(con, "project")

  ev <- list(
    work_order = "XX1234567", results = tibble::tibble(), samples = tibble::tibble(),
    files = tibble::tibble(hash = "hash-x", kept = TRUE), report = list()
  )
  tree <- .ct_ensure_project_tree(con, ev, "test")

  expect_identical(tree$uuid_project, .ct_ensure_project(con, "XX1234567", "test"))
  expect_null(tree$review)
  expect_equal(count_rows(con, "project"), before)
})

test_that("A80: the archived ACIRL workbook lands on its report project, not the anonymous orphan row", {
  s <- a80_setup()
  con <- s$con
  ev <- a80_event(con, s$src, "2400-7538-02", cited = character(0))
  commit_event(ev$event, mk_resolved(clean = a80_clean(ev$hash, "2400-7538-02")), con)

  report <- a80_project(con, "2400-7538-02")
  asset <- DBI::dbGetQuery(con, "SELECT uuid_project FROM asset WHERE hash = ?",
                           params = list(ev$hash))
  expect_equal(nrow(asset), 1)
  expect_identical(asset$uuid_project[[1]], report$uuid[[1]])
})
