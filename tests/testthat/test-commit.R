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
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

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
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

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
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  key <- .rc_feature_key("T.DEDUPE-FEAT")

  files1 <- tibble::tibble(hash = setup$hash, filename = basename(setup$path),
                           adapter = "esdat/1", rank = 3L, kept = TRUE)
  clean1 <- mk_p11_row(source_ref = "r1", source_hash = setup$hash,
                        feature_raw = "T.DEDUPE-FEAT", alias_key = key,
                        feature_pending = TRUE, uuid_feature_alias = NA_character_,
                        sample_date = as.Date("2025-07-05"),
                        sample_datetime = as.POSIXct("2025-07-05 09:00:00", tz = "UTC"))
  commit_event(mk_commit_event(files1), mk_resolved(clean = clean1), con)

  second <- add_second_reconciled_file(setup, "second_file.CSV")
  files2 <- tibble::tibble(hash = second$hash, filename = basename(second$path),
                           adapter = "esdat/1", rank = 3L, kept = TRUE)
  clean2 <- mk_p11_row(source_ref = "r1", source_hash = second$hash,
                        feature_raw = "T.DEDUPE-FEAT", alias_key = key,
                        feature_pending = TRUE, uuid_feature_alias = NA_character_,
                        sample_date = as.Date("2025-07-06"),
                        sample_datetime = as.POSIXct("2025-07-06 09:00:00", tz = "UTC"))
  commit_event(mk_commit_event(files2), mk_resolved(clean = clean2), con)

  aliases <- dangling_alias_row(con, key)
  expect_equal(nrow(aliases), 1)
  expect_equal(aliases$n_seen[[1]], 2)
})

test_that("R-11.8(a,c)/M4: a RESOLVED feature_alias sharing the alias_key is left untouched; committing a pending row creates a NEW distinct pending alias (find-or-create excludes resolved aliases)", {
  setup <- commit_test_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
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
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

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
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

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
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

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
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

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

  second <- add_second_reconciled_file(setup, "drift_file.CSV")
  files2 <- tibble::tibble(hash = second$hash, filename = basename(second$path),
                           adapter = "esdat/1", rank = 3L, kept = TRUE)
  clean2 <- mk_p11_row(source_ref = "r1", source_hash = second$hash,
                        analyte_raw = "T.DRIFT-ANALYTE", method_raw = "T.DRIFT-METHOD",
                        analyte_pending = TRUE, uuid_lab = NA_character_, uuid_analyte = NA_character_,
                        units_raw = "g/L",
                        sample_date = as.Date("2025-07-12"),
                        sample_datetime = as.POSIXct("2025-07-12 09:00:00", tz = "UTC"))
  commit_event(mk_commit_event(files2), mk_resolved(clean = clean2), con)

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
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
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

# ---- R-11.16: quantified from parse_value(); write rl_high (F4) ------------

test_that("R-11.16: a '>2000' row commits quantified = FALSE (from parse_value, never re-derived from below_detection) and a non-NA rl_high = 2000 (F4)", {
  setup <- commit_test_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

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
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

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
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

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
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

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
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

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
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
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
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
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
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
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
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

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
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

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
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
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
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

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

test_that("R-11.16: a qualitative text row commits quantified = NA, not FALSE (the tri-state survives the write)", {
  # Ruled by Robin 2026-07-23. `isTRUE()` maps NA to FALSE, which silently
  # recorded "this is not a measurement" as "below detection". In the live
  # registry 315 rows are text-valued and 23 of those record that no sample was
  # taken - committing them as quantified = FALSE asserts a non-detection that
  # was never performed.
  setup <- commit_test_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

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
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
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
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
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
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

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
})

test_that("R-15.32 (ACIRL false-merge guard): a first-time work order whose filename embeds a SHORTER, already-loaded ACIRL work order as a literal prefix still commits cleanly - the guard must key on the recorded work_order, never a filename-parsed one", {
  setup <- commit_test_setup(filename = "2400-7538-02_ALS_Chemistry.CSV",
                              work_order = "2400-7538-02", revision = 0L)
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

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
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

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
})
