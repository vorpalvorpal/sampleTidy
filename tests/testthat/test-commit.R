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
# .rc_key(feature_raw)), `uuid_feature_alias` (chr, NA when pending),
# `analyte_pending` (lgl), `org` (chr, reporting organisation), `method_raw`,
# `units_raw`, `quantified` (lgl, from parse_value(), never re-derived from
# `below_detection`), `rl_high` (dbl, from parse_value(), for `>`-rows).
# Built directly here per this file's own top-of-file convention -
# independent of plan-08's implementation status.

mk_p11_row <- function(...) {
  defaults <- list(
    source_hash = "p11-hash-x", source_ref = "row1", work_order = "XX1234567", revision = 0L,
    org = "ALS",
    feature_raw = "T.S01", alias_key = .rc_key("T.S01"),
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
               feature_raw = "T.NEVER-SEEN-C20", alias_key = .rc_key("T.NEVER-SEEN-C20"),
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

  alias <- dangling_alias_row(con, .rc_key("T.NEVER-SEEN-C20"))
  expect_equal(nrow(alias), 1)
  expect_true(is.na(alias$uuid_feature[[1]]))
  expect_identical(alias$kind[[1]], "pending")
  expect_false(alias$auto_assign[[1]])
})

test_that("R-11.8(a,c): two commits of the same still-unknown feature reuse ONE dangling feature_alias, and n_seen counts one per referencing sample (idempotent find-or-create)", {
  setup <- commit_test_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  key <- .rc_key("T.DEDUPE-FEAT")

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
  key <- .rc_key("T.SHARED-KEY-M4")

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

test_that("R-11.8(e)/M5: two rows in the SAME commit event, same analyte, differing ONLY in method raw casing, reuse ONE dangling lab_method (intra-event dedup uses .rc_key, not the raw string)", {
  setup <- commit_test_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # Both rows land in the SAME commit_event() call (a single event), so this
  # exercises the intra-event dedup key at commit.R:178
  # (`paste(clean$org, .rc_key(analyte_raw), .rc_key(method_raw))`), never
  # the cross-file DB-lookup path the R-11.8(e) two-commit test above covers.
  # Distinct features/sample times keep both rows alive through sample
  # creation and analysis commit, so both reach lab_method materialisation.
  files <- tibble::tibble(hash = setup$hash, filename = basename(setup$path),
                          adapter = "esdat/1", rank = 3L, kept = TRUE)
  clean <- dplyr::bind_rows(
    mk_p11_row(source_ref = "r1", source_hash = setup$hash,
               feature_raw = "T.S01", alias_key = .rc_key("T.S01"),
               feature_pending = FALSE, uuid_feature_alias = "fa-0001",
               analyte_raw = "T.DEDUPE-ANALYTE-M5", method_raw = "T.DEDUPE-METHOD-M5",
               analyte_pending = TRUE, uuid_lab = NA_character_, uuid_analyte = NA_character_,
               units_raw = "mg/L",
               sample_date = as.Date("2025-07-09"),
               sample_datetime = as.POSIXct("2025-07-09 09:00:00", tz = "UTC")),
    mk_p11_row(source_ref = "r2", source_hash = setup$hash,
               feature_raw = "T.S02", alias_key = .rc_key("T.S02"),
               feature_pending = FALSE, uuid_feature_alias = "fa-0002",
               analyte_raw = "t.dedupe-analyte-m5", method_raw = "t.dedupe-method-m5",
               analyte_pending = TRUE, uuid_lab = NA_character_, uuid_analyte = NA_character_,
               units_raw = "mg/L",
               sample_date = as.Date("2025-07-09"),
               sample_datetime = as.POSIXct("2025-07-09 10:00:00", tz = "UTC"))
  )
  commit_event(mk_commit_event(files), mk_resolved(clean = clean), con)

  dangling <- dangling_lab_method_rows(con, "ALS")
  matching <- dangling[!is.na(dangling$name) & .rc_key(dangling$name) == .rc_key("T.DEDUPE-ANALYTE-M5") &
                          !is.na(dangling$method) & .rc_key(dangling$method) == .rc_key("T.DEDUPE-METHOD-M5"), , drop = FALSE]
  expect_equal(nrow(matching), 1)
})

test_that("R-11.8(e): two commits of the same unknown analyte, differing ONLY in raw casing, reuse ONE dangling lab_method (dedup uses .rc_key, not raw string)", {
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
  matching <- dangling[!is.na(dangling$name) & .rc_key(dangling$name) == .rc_key("T.DEDUPE-ANALYTE") &
                          !is.na(dangling$method) & .rc_key(dangling$method) == .rc_key("T.DEDUPE-METHOD"), , drop = FALSE]
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
  hit <- dangling[!is.na(dangling$name) & .rc_key(dangling$name) == .rc_key("EC New Units Method"), , drop = FALSE]
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
  matching <- dangling[!is.na(dangling$name) & .rc_key(dangling$name) == .rc_key("T.DRIFT-ANALYTE") &
                          !is.na(dangling$method) & .rc_key(dangling$method) == .rc_key("T.DRIFT-METHOD"), , drop = FALSE]
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
  matching_after <- dangling_after[!is.na(dangling_after$name) & .rc_key(dangling_after$name) == .rc_key("T.DRIFT-ANALYTE") &
                          !is.na(dangling_after$method) & .rc_key(dangling_after$method) == .rc_key("T.DRIFT-METHOD"), , drop = FALSE]
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
  key <- .rc_key("T.NEEDS-REVIEW-ALIAS")

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
    "SELECT payload FROM review_queue WHERE kind = 'unknown_feature' AND source_hash = ?",
    params = list(setup$hash))
  expect_equal(nrow(stored), 1)
  m <- regmatches(stored$payload[[1]], regexpr("alias_uuid=[^,}]+", stored$payload[[1]]))
  expect_true(length(m) == 1 && nzchar(m))
  extracted_uuid <- sub("^alias_uuid=", "", m)
  expect_identical(extracted_uuid, alias$uuid[[1]])
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
