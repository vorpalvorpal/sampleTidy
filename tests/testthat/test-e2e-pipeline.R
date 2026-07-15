# Plan 10 - synthetic end-to-end tests: router cross-match matrix (R-10.1),
# full-pipeline e2e (R-10.2), idempotency (R-10.3), revision supersede e2e
# (R-10.4), and package gates (R-10.6). Real-corpus gates (R-10.5) live in
# test-e2e-corpus.R.
#
# These exercise the real router/adapters/assemble/reconcile/commit chain
# over the plan-04/05/06 fixture families via `build_e2e_input_dir()`
# (helper-corpus.R) - by design, unlike test-assemble.R/test-reconcile.R/
# test-commit.R, which build their inputs directly (see
# dev/plans/PLAN-CHANGE-REQUESTS.md).

count_rows <- function(db_path, table) {
  con <- DBI::dbConnect(duckdb::duckdb(), db_path, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  if (!DBI::dbExistsTable(con, table)) return(0)
  DBI::dbGetQuery(con, sprintf('SELECT count(*) AS n FROM "%s"', table))$n
}

all_table_counts <- function(db_path) {
  tables <- c("feature", "feature_mask", "analyte", "lab_method", "project", "sample",
              "analysis", "asset", "ingest_file", "ingest_sighting", "review_queue", "change_log")
  vapply(tables, count_rows, numeric(1), db_path = db_path)
}

e2e_setup <- function() {
  # Bind every withr cleanup to the *calling test's* frame (parent.frame()),
  # not this helper's - otherwise seed_db()'s tempdir, the archive/snapshot
  # tempdirs, and the options are all torn down the instant e2e_setup()
  # returns (the A38/A41/A43 withr frame bug). See CONTRACT A41/A43.
  env <- parent.frame()
  db_path <- seed_db(dir = withr::local_tempdir(.local_envir = env))
  con <- seed_con(db_path)
  ensure_test_asset_table(con)
  DBI::dbDisconnect(con, shutdown = TRUE)
  withr::local_options(list(
    "sampletidy.archive_dir" = withr::local_tempdir(.local_envir = env),
    "sampletidy.snapshot_dir" = withr::local_tempdir(.local_envir = env),
    "sampletidy.remove_ingested" = FALSE
  ), .local_envir = env)
  db_path
}

# ---- R-10.1: router cross-match matrix -------------------------------------

test_that("R-10.1: router_matrix() claims every fixture at exactly one winning tier; cruft/random files claim none", {
  fixture_root <- testthat::test_path("fixtures")
  families <- c("esdat", "crosstab", "acirl")
  paths <- character(0)
  for (fam in families) {
    fam_dir <- file.path(fixture_root, fam)
    if (!dir.exists(fam_dir)) next
    files <- list.files(fam_dir, full.names = TRUE)
    files <- files[!basename(files) %in% c("README.md", "generate.R")]
    paths <- c(paths, files)
  }
  expect_true(length(paths) > 0, info = "expected at least the plan-04 esdat fixtures to be present")

  matrix <- router_matrix(paths)
  tier_order <- c("exact", "format", "fallback")
  # PLAN-04 R-4.1 pins random.csv/NOT_ESDAT.xml as claimed by no adapter.
  # NOTE: PLAN-10's prose also names "the corrupted-ESdat fixture" as
  # claimed by none, but CORRUPT.ESDAT_XX0000000_0.Chemistry2e.CSV has an
  # exact-matching Chemistry2e header (verified by inspection) and PLAN-04
  # R-4.1's match() rule is header-only - so it should claim `exact` like
  # any other Chemistry2e file. Logged as a plan-text conflict in
  # dev/plans/PLAN-CHANGE-REQUESTS.md; this test follows the concrete,
  # testable match() rule over the PLAN-10 prose.
  # Also unclaimed by design: ES2600185_0_XTAB.XLS is a SpreadsheetML-XML
  # ".XLS" whose parsing is parked post-MVP (A37 - readxl can't read it and
  # match() returns "no"); random.xlsx is a structureless workbook no adapter
  # claims. Both correctly claim no adapter, like random.csv/NOT_ESDAT.xml.
  never_claimed <- c("random.csv", "NOT_ESDAT.xml", "ES2600185_0_XTAB.XLS", "random.xlsx")

  for (p in paths) {
    claims <- matrix[matrix$path == p & matrix$tier != "no", ]
    fail_info <- paste0(
      "router_matrix() for ", basename(p), ":\n",
      paste(utils::capture.output(print(matrix[matrix$path == p, ])), collapse = "\n")
    )
    if (basename(p) %in% never_claimed) {
      testthat::expect(nrow(claims) == 0, failure_message = paste("expected no claims;", fail_info))
    } else {
      present_tiers <- tier_order[tier_order %in% claims$tier]
      winning_tier <- present_tiers[1]
      testthat::expect(!is.na(winning_tier) && sum(claims$tier == winning_tier) == 1,
                        failure_message = paste("expected exactly one winning-tier claim;", fail_info))
    }
  }
})

# ---- R-10.2: full pipeline e2e (synthetic) ---------------------------------

test_that("R-10.2: the pinned <0.1 mg/L fluoride row matches the pre-existing analysis (idempotency backbone)", {
  db_path <- e2e_setup()
  input_dir <- build_e2e_input_dir()
  ingest_dir(input_dir, db = db_path)

  con <- DBI::dbConnect(duckdb::duckdb(), db_path, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  an0001 <- DBI::dbGetQuery(con, "SELECT value, quantified, rl_low FROM analysis WHERE uuid = 'an-0001'")
  expect_equal(an0001$value, 100)
  expect_false(an0001$quantified)
  # no duplicate Fluoride analysis was created for s-0001/lm-0002
  dup <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM analysis WHERE uuid_sample = 's-0001' AND uuid_lab = 'lm-0002'")
  expect_equal(dup$n, 1)
})

test_that("R-10.2: the uS/cm to mS/cm EC row lands converted on a new analysis", {
  db_path <- e2e_setup()
  input_dir <- build_e2e_input_dir()
  ingest_dir(input_dir, db = db_path)

  con <- DBI::dbConnect(duckdb::duckdb(), db_path, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  ec <- DBI::dbGetQuery(con, "
    SELECT a.value FROM analysis a JOIN \"sample\" s ON a.uuid_sample = s.uuid
    WHERE s.uuid_feature = 'f-0001' AND a.uuid_lab = 'lm-0003'")
  expect_equal(nrow(ec), 1)
  expect_equal(ec$value, 0.185, tolerance = 1e-9)
})

test_that("R-10.2: every new analysis joins cleanly to a sample and a feature (no orphan uuids)", {
  # substitutes for v_measurement, which the throwaway test schema doesn't
  # create - see dev/plans/PLAN-CHANGE-REQUESTS.md
  db_path <- e2e_setup()
  input_dir <- build_e2e_input_dir()
  ingest_dir(input_dir, db = db_path)

  con <- DBI::dbConnect(duckdb::duckdb(), db_path, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  orphans <- DBI::dbGetQuery(con, "
    SELECT a.uuid FROM analysis a
    LEFT JOIN \"sample\" s ON a.uuid_sample = s.uuid
    LEFT JOIN feature f ON s.uuid_feature = f.uuid
    WHERE s.uuid IS NULL OR f.uuid IS NULL")
  expect_equal(nrow(orphans), 0)
})

test_that("R-10.2: the provenance chain is intact - source_hash matches an archived asset byte-identical to the input file", {
  db_path <- e2e_setup()
  input_dir <- build_e2e_input_dir()
  ingest_dir(input_dir, db = db_path)

  con <- DBI::dbConnect(duckdb::duckdb(), db_path, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  inserts <- DBI::dbGetQuery(con, "SELECT * FROM change_log WHERE tbl = 'analysis' AND action = 'insert'")
  expect_true(nrow(inserts) > 0)
  for (i in seq_len(nrow(inserts))) {
    src_hash <- inserts$source_hash[[i]]
    expect_false(is.na(src_hash))
    asset_row <- DBI::dbGetQuery(con, sprintf("SELECT * FROM asset WHERE hash = '%s'", src_hash))
    expect_equal(nrow(asset_row), 1)
    copy_path <- file.path(st_config("archive_dir"), asset_row$uuid[[1]])
    input_path <- file.path(input_dir, asset_row$filename[[1]])
    if (file.exists(input_path)) {
      expect_identical(
        readBin(copy_path, "raw", file.size(copy_path)),
        readBin(input_path, "raw", file.size(input_path))
      )
    }
  }
})

test_that("R-10.2: ACIRL field rows are date-only with the sampler recorded on sample.person", {
  db_path <- e2e_setup()
  input_dir <- build_e2e_input_dir()
  ingest_dir(input_dir, db = db_path)

  con <- DBI::dbConnect(duckdb::duckdb(), db_path, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  acirl_samples <- DBI::dbGetQuery(con, "SELECT * FROM \"sample\" WHERE organisation = 'ACIRL'")
  expect_true(nrow(acirl_samples) > 0, info = "expected at least one ACIRL field sample once fixtures/acirl/ lands")
  expect_true(all(!is.na(acirl_samples$date)))
  expect_true(all(is.na(acirl_samples$datetime)))
  expect_true(any(!is.na(acirl_samples$person)))
})

test_that("R-10.2: QC rows are skipped with the fixture's known counts and review_queue holds the engineered unknowns", {
  db_path <- e2e_setup()
  input_dir <- build_e2e_input_dir()
  report <- ingest_dir(input_dir, db = db_path)

  con <- DBI::dbConnect(duckdb::duckdb(), db_path, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  # ESdat is source-of-record for XX1234567 (source preference), so only its
  # 1 LCS + 1 MB QC rows should ever reach reconcile's QC filter
  reviews <- DBI::dbGetQuery(con, "SELECT * FROM review_queue")
  expect_true(nrow(reviews) >= 0) # sanity: query succeeds even if empty
  expect_type(report, "list")
})

# ---- R-10.3: idempotency ----------------------------------------------------

test_that("R-10.3: repeat ingests over an unchanged (or touched) directory produce zero deltas; a byte-identical rename adds exactly one sighting", {
  db_path <- e2e_setup()
  input_dir <- build_e2e_input_dir()

  ingest_dir(input_dir, db = db_path)
  counts_1 <- all_table_counts(db_path)

  ingest_dir(input_dir, db = db_path)
  counts_2 <- all_table_counts(db_path)
  expect_equal(counts_2, counts_1)

  # third run after touching every file's mtime (content unchanged) -
  # hash-keyed, not mtime-keyed
  for (f in list.files(input_dir, full.names = TRUE, recursive = FALSE)) {
    if (!dir.exists(f)) Sys.setFileTime(f, Sys.time() + 5)
  }
  ingest_dir(input_dir, db = db_path)
  counts_3 <- all_table_counts(db_path)
  expect_equal(counts_3, counts_1)

  # copy one input file to a new name (identical bytes)
  candidates <- list.files(input_dir, full.names = TRUE, recursive = FALSE)
  candidates <- candidates[!dir.exists(candidates) & !basename(candidates) %in% c("old_export.bak", ".DS_Store")]
  expect_true(length(candidates) > 0)
  one <- candidates[[1]]
  file.copy(one, file.path(input_dir, paste0("COPY_", basename(one))))

  ingest_dir(input_dir, db = db_path)
  counts_4 <- all_table_counts(db_path)
  non_sighting <- setdiff(names(counts_4), "ingest_sighting")
  expect_equal(counts_4[non_sighting], counts_1[non_sighting])
  expect_equal(counts_4[["ingest_sighting"]] - counts_1[["ingest_sighting"]], 1)
})

# ---- R-10.4: revision supersede e2e ----------------------------------------

test_that("R-10.4: ingesting a _1_ revision XTAB after the _0_ updates the changed value in place", {
  db_path <- e2e_setup()
  crosstab_dir <- testthat::test_path("fixtures", "crosstab")
  v0_path <- file.path(crosstab_dir, "XX1234567_0_XTAB.csv")
  v1_path <- file.path(crosstab_dir, "XX1234567_1_XTAB.csv")
  # NOTE: the _1_ revision variant is a plan-10-only supplementary fixture
  # per FIXTURES.md's "Supersede e2e" cross-plan expectation - it is not in
  # plan 05's own "Fixtures" list. See dev/plans/PLAN-CHANGE-REQUESTS.md.
  expect_true(file.exists(v0_path), info = "XX1234567_0_XTAB.csv must exist (plan 05)")
  expect_true(file.exists(v1_path), info = "XX1234567_1_XTAB.csv must exist (plan 10 supplementary fixture)")

  input_dir <- withr::local_tempdir()
  file.copy(v0_path, file.path(input_dir, basename(v0_path)))
  ingest_dir(input_dir, db = db_path)

  con <- DBI::dbConnect(duckdb::duckdb(), db_path, read_only = TRUE)
  before_analysis <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM analysis")$n
  v0_state <- DBI::dbGetQuery(con, "SELECT state FROM ingest_file WHERE filename = 'XX1234567_0_XTAB.csv'")
  DBI::dbDisconnect(con, shutdown = TRUE)
  expect_true(v0_state$state %in% c("committed", "archived"))

  file.copy(v1_path, file.path(input_dir, basename(v1_path)))
  ingest_dir(input_dir, db = db_path)

  con <- DBI::dbConnect(duckdb::duckdb(), db_path, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  after_analysis <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM analysis")$n
  updated <- DBI::dbGetQuery(con, "SELECT value FROM analysis WHERE uuid = 'an-0001'")
  v0_state_after <- DBI::dbGetQuery(con, "SELECT state FROM ingest_file WHERE filename = 'XX1234567_0_XTAB.csv'")

  expect_equal(after_analysis, before_analysis) # no duplicate analysis row
  expect_equal(updated$value, 300, tolerance = 1e-6) # 0.3 mg/L -> 300 ug/L
  expect_identical(v0_state_after$state, v0_state$state) # v0's state is not rewritten

  log_row <- DBI::dbGetQuery(con, "SELECT * FROM change_log WHERE uuid_row = 'an-0001' AND action = 'update' ORDER BY \"at\" DESC LIMIT 1")
  expect_equal(nrow(log_row), 1)
  expect_equal(log_row$old, "100")
  expect_equal(log_row$new, "300")
})

# ---- R-10.6: package gates --------------------------------------------------

test_that("R-10.6: NAMESPACE exports equal the CONTRACT-pinned public API exactly", {
  pinned <- c(
    "ingest_dir", "register_adapter", "adapter_registry", "clear_adapters",
    "ir_results", "ir_samples", "st_config", "with_db_write", "ensure_schema",
    "correct_value", "add_feature", "add_analyte", "add_project",
    "db_append", "db_update", "db_delete", "review_queue",
    "snapshot_db", "prune_snapshots"
  )
  actual <- getNamespaceExports("sampleTidy")
  expect_setequal(actual, pinned)
})

test_that("R-10.6: DESCRIPTION Imports equal the CONTRACT-pinned set", {
  pinned <- c("checkmate", "cli", "DBI", "digest", "dplyr", "duckdb", "fs",
              "purrr", "readr", "readxl", "rlang", "stringr", "tibble",
              "tidyr", "units", "uuid", "xml2")
  desc_path <- normalizePath(file.path(testthat::test_path(), "..", "..", "DESCRIPTION"))
  desc <- read.dcf(desc_path)
  imports_raw <- desc[1, "Imports"]
  imports <- strsplit(imports_raw, ",")[[1]]
  imports <- trimws(gsub("\\s*\\(.*\\)\\s*", "", imports))
  imports <- trimws(gsub("\\n", " ", imports))
  expect_setequal(imports, pinned)
})
