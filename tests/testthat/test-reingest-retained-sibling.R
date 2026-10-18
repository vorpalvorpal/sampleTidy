# F.10 / R-15.32 re-ingest guard vs F.17 retained siblings.
#
# Robin's ruling 2026-10-18: `.ct_reingest_guard()` (R/commit.R) must NOT
# count, as prior-ingestion evidence, an `asset` whose `ingest_file` row is
# `archived` with `state_reason = 'retained_sibling'` - a kept COA / PDF /
# XTAB / other non-tabular deliverable that F.17 (`.ig_retain_siblings()`,
# R/ingest.R) archived WITHOUT ever parsing it. Assets from files that were
# actually parsed and committed (`state_reason` 'commit_event: <wo>') still
# count exactly as before, and so do legacy assets with no `ingest_file` row
# at all (the ruling excludes retained siblings only, nothing else).
#
# Real case: work order ES2623357 had only ACIRL field samples plus a
# retained ALS COA PDF; its ALS XTAB (once parseable) was blocked as
# work_order_reingest/blocked although all 171 of its rows were new.
#
# Synthetic DB states throughout, built with the same direct-construction
# style as test-commit.R (whose local helpers are not visible from this file,
# so the few needed are copied here).

# ---- local helpers ---------------------------------------------------------

rs_setup <- function(filename = "PROJ_A.ESDAT_XX1234567_0.Chemistry2e.CSV",
                     work_order = "XX1234567", revision = 0L) {
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
  DBI::dbExecute(con, "INSERT INTO ingest_file
    (hash, filename, path_first_seen, state, work_order, revision)
    VALUES (?, ?, ?, 'reconciled', ?, ?)",
    params = list(hash, basename(src_path), src_path, work_order, as.integer(revision)))

  list(con = con, hash = hash, path = src_path, archive_dir = archive_dir,
       work_order = work_order)
}

#' A further `reconciled` (i.e. about-to-commit) lab file on the same DB.
rs_add_reconciled <- function(setup, filename, work_order = setup$work_order, revision = 0L) {
  path <- file.path(dirname(setup$path), filename)
  writeLines(paste("SampleCode,ChemCode", filename), path)
  hash <- hash_file(path)
  DBI::dbExecute(setup$con, "INSERT INTO ingest_file
    (hash, filename, path_first_seen, state, work_order, revision)
    VALUES (?, ?, ?, 'reconciled', ?, ?)",
    params = list(hash, basename(path), path, work_order, as.integer(revision)))
  list(hash = hash, path = path)
}

#' Put a retained sibling on the DB exactly as `.ig_retain_siblings()`
#' (R/ingest.R, F.17) leaves one: an unclaimed file routed `quarantined`, then
#' `archive_file()` (asset row under the work order's project) and the
#' terminal `archived` / 'retained_sibling' transition. Never parsed.
rs_add_retained_sibling <- function(setup, filename, work_order = setup$work_order) {
  path <- file.path(dirname(setup$path), filename)
  writeLines(paste("%PDF-1.4 not really a pdf", filename), path)
  hash <- hash_file(path)
  con <- setup$con
  DBI::dbExecute(con, "INSERT INTO ingest_file
    (hash, filename, path_first_seen, state, state_reason, work_order, revision)
    VALUES (?, ?, ?, 'quarantined', 'unclaimed', NULL, NULL)",
    params = list(hash, basename(path), path))
  db_transaction(con, function(con) {
    archive_file(con, path, hash, event = list(work_order = work_order),
                 type = .ig_retained_asset_type(basename(path)))
    ingest_file_set_state(con, hash, "archived", reason = "retained_sibling", reset = TRUE)
  })
  list(hash = hash, path = path)
}

rs_files <- function(f) {
  tibble::tibble(hash = f$hash, filename = basename(f$path),
                 adapter = "esdat/1", rank = 3L, kept = TRUE)
}

rs_commit_event <- function(files, work_order = "XX1234567") {
  list(
    work_order = work_order, orphan = FALSE,
    results = tibble::tibble(), samples = tibble::tibble(),
    files = files,
    report = list(n_results = 0L, n_by_sample_type = list(), n_ncp_foreign = 0L,
                  skipped = tibble::tibble(hash = character(), source_ref = character(), reason = character()),
                  warnings = character())
  )
}

rs_row <- function(...) {
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
  tibble::as_tibble(utils::modifyList(defaults, list(...)))
}

rs_event <- function(results, work_order = "XX1234567") {
  list(
    work_order = work_order, orphan = FALSE, results = results,
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

rs_count <- function(con, table) {
  DBI::dbGetQuery(con, sprintf('SELECT count(*) AS n FROM "%s"', table))$n
}

rs_guard_rows <- function(con) {
  DBI::dbGetQuery(con,
    "SELECT kind, subkind, work_order, payload FROM review_queue
      WHERE kind = 'work_order_reingest'")
}

#' Reconcile + commit one lab file's single row for `wo` on `datetime_raw`.
rs_ingest_lab_file <- function(setup, f, datetime_raw, wo = setup$work_order,
                               source_ref = "r1") {
  ev <- rs_event(rs_row(source_ref = source_ref, source_hash = f$hash,
                        work_order = wo, revision = 0L,
                        sample_datetime_raw = datetime_raw),
                 work_order = wo)
  resolved <- reconcile_event(ev, setup$con)
  commit_event(rs_commit_event(rs_files(f), work_order = wo), resolved, setup$con)
  invisible(resolved)
}

# The seeded work order XX1234567 (project p-0001) already has five `sample`
# rows (s-0001..s-0005, May 2025) but NO `asset` rows - so before anything in
# these tests runs, it has samples from earlier loads but no prior-ingest
# evidence at all. Incoming rows below are dated August 2025, matching no
# existing sample, i.e. genuinely new (the guard's "unmatched" condition).

# ---- 1. retained siblings alone are not prior-ingest evidence --------------

test_that("F.10 vs F.17 (ruling 2026-10-18): a work order whose ONLY prior assets are retained siblings (a COA PDF archived as retained_sibling) is not a re-ingest - an incoming lab file for it commits and no work_order_reingest item is opened", {
  setup <- rs_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  coa <- rs_add_retained_sibling(setup, "XX1234567_COA.pdf")

  # Sanity: the fixture is the real shape - the WO has samples, and its one
  # asset is the retained COA, archived/retained_sibling.
  expect_gt(DBI::dbGetQuery(con,
    "SELECT count(*) AS n FROM sample WHERE uuid_project = 'p-0001'")$n[[1]], 0)
  coa_asset <- DBI::dbGetQuery(con, "SELECT a.hash FROM asset a
      JOIN project p ON p.uuid = a.uuid_project WHERE p.name = 'XX1234567'")
  expect_identical(coa_asset$hash, coa$hash)
  coa_state <- DBI::dbGetQuery(con, "SELECT state, state_reason FROM ingest_file WHERE hash = ?",
                               params = list(coa$hash))
  expect_identical(coa_state$state[[1]], "archived")
  expect_identical(coa_state$state_reason[[1]], "retained_sibling")

  before_sample <- rs_count(con, "sample")
  before_analysis <- rs_count(con, "analysis")

  # The guard itself, called directly: nothing to block.
  ev <- rs_event(rs_row(source_ref = "r1", source_hash = setup$hash,
                        sample_datetime_raw = "03 Aug 2025 09:00"))
  resolved <- reconcile_event(ev, con)
  expect_equal(nrow(resolved$clean), 1)
  cev <- rs_commit_event(rs_files(setup))
  expect_null(.ct_reingest_guard(con, cev, resolved))

  commit_event(cev, resolved, con)

  expect_equal(rs_count(con, "sample") - before_sample, 1)
  expect_equal(rs_count(con, "analysis") - before_analysis, 1)
  expect_equal(nrow(rs_guard_rows(con)), 0)

  lab_state <- DBI::dbGetQuery(con, "SELECT state FROM ingest_file WHERE hash = ?",
                               params = list(setup$hash))
  expect_identical(lab_state$state[[1]], "archived")
  # The COA is untouched by the lab file's commit.
  coa_after <- DBI::dbGetQuery(con, "SELECT state, state_reason FROM ingest_file WHERE hash = ?",
                               params = list(coa$hash))
  expect_identical(coa_after$state_reason[[1]], "retained_sibling")
})

test_that("F.10 vs F.17: SEVERAL retained siblings (COA PDF, COC, QC report, XTAB) on one work order are still not prior-ingest evidence", {
  setup <- rs_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  for (fn in c("XX1234567_COA.pdf", "XX1234567_COC.pdf", "XX1234567_QC.pdf",
               "XX1234567_XTAB.XLS")) {
    rs_add_retained_sibling(setup, fn)
  }
  expect_equal(DBI::dbGetQuery(con, "SELECT count(*) AS n FROM asset")$n[[1]], 4)

  before_sample <- rs_count(con, "sample")
  rs_ingest_lab_file(setup, setup, "03 Aug 2025 09:00")

  expect_equal(rs_count(con, "sample") - before_sample, 1)
  expect_equal(nrow(rs_guard_rows(con)), 0)
})

test_that("F.10 vs F.17: the dry-run preview agrees - a work order with only retained siblings previews as not blocked", {
  setup <- rs_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  rs_add_retained_sibling(setup, "XX1234567_COA.pdf")
  ev <- rs_event(rs_row(source_ref = "r1", source_hash = setup$hash,
                        sample_datetime_raw = "03 Aug 2025 09:00"))
  resolved <- reconcile_event(ev, con)
  preview <- .ct_reingest_guard_preview(con, rs_commit_event(rs_files(setup)), resolved)
  expect_false(preview$blocked)
})

# ---- 2. a committed lab file still counts (regression guard) ---------------

test_that("F.10 regression guard: a work order with a prior asset from a COMMITTED lab file (state_reason commit_event) is still blocked exactly as before", {
  setup <- rs_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  rs_ingest_lab_file(setup, setup, "01 Aug 2025 09:00")
  first <- DBI::dbGetQuery(con, "SELECT state, state_reason FROM ingest_file WHERE hash = ?",
                           params = list(setup$hash))
  expect_identical(first$state[[1]], "archived")
  expect_match(first$state_reason[[1]], "^commit_event")

  before_sample <- rs_count(con, "sample")
  before_analysis <- rs_count(con, "analysis")

  redl <- rs_add_reconciled(setup, "PROJ_A.ESDAT_XX1234567_0.Chemistry2e_v2.CSV")
  rs_ingest_lab_file(setup, redl, "03 Aug 2025 09:00")

  expect_equal(rs_count(con, "sample"), before_sample)
  expect_equal(rs_count(con, "analysis"), before_analysis)
  g <- rs_guard_rows(con)
  expect_equal(nrow(g), 1)
  expect_identical(g$subkind[[1]], "blocked")
  expect_identical(g$work_order[[1]], "XX1234567")
  diag <- jsonlite::fromJSON(g$payload[[1]])
  expect_equal(diag$n_prior_ingested_files, 1)
  expect_equal(diag$n_rows_blocked, 1)
  expect_identical(
    DBI::dbGetQuery(con, "SELECT state FROM ingest_file WHERE hash = ?",
                    params = list(redl$hash))$state[[1]],
    "needs_review")
})

test_that("F.10 regression guard: a legacy asset with NO ingest_file row at all still counts as prior-ingest evidence (only retained_sibling is excluded)", {
  setup <- rs_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  DBI::dbExecute(con, "INSERT INTO asset (uuid, type, uuid_project, filename, hash)
    VALUES ('as-legacy', 'Chemical analysis', 'p-0001', 'old_load.csv', 'legacy-asset-hash')")
  expect_equal(DBI::dbGetQuery(con,
    "SELECT count(*) AS n FROM ingest_file WHERE hash = 'legacy-asset-hash'")$n[[1]], 0)

  before_sample <- rs_count(con, "sample")
  rs_ingest_lab_file(setup, setup, "03 Aug 2025 09:00")

  expect_equal(rs_count(con, "sample"), before_sample)
  g <- rs_guard_rows(con)
  expect_equal(nrow(g), 1)
  expect_equal(jsonlite::fromJSON(g$payload[[1]])$n_prior_ingested_files, 1)
})

# ---- 3. mixed: retained COA + committed ENMRG ------------------------------

test_that("F.10 vs F.17: a work order with BOTH a retained COA and a committed ENMRG is still blocked", {
  setup <- rs_setup(filename = "XX1234567_ENMRG.CSV")
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  rs_add_retained_sibling(setup, "XX1234567_COA.pdf")
  rs_ingest_lab_file(setup, setup, "01 Aug 2025 09:00")   # the ENMRG commits
  expect_equal(nrow(rs_guard_rows(con)), 0)              # COA alone: ENMRG not blocked

  before_sample <- rs_count(con, "sample")
  before_analysis <- rs_count(con, "analysis")

  xtab <- rs_add_reconciled(setup, "XX1234567_XTAB_parsed.CSV")
  rs_ingest_lab_file(setup, xtab, "03 Aug 2025 09:00")

  expect_equal(rs_count(con, "sample"), before_sample)
  expect_equal(rs_count(con, "analysis"), before_analysis)
  g <- rs_guard_rows(con)
  expect_equal(nrow(g), 1)
  expect_identical(g$kind[[1]], "work_order_reingest")
  expect_identical(g$subkind[[1]], "blocked")
})

# ---- 4. payload counts exclude retained siblings ---------------------------

test_that("F.10 vs F.17: the guard payload's n_prior_ingested_files counts ONLY parsed/committed files, never retained siblings", {
  setup <- rs_setup(filename = "XX1234567_ENMRG.CSV")
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  rs_add_retained_sibling(setup, "XX1234567_COA.pdf")
  rs_add_retained_sibling(setup, "XX1234567_COC.pdf")
  rs_ingest_lab_file(setup, setup, "01 Aug 2025 09:00")   # 1 committed file

  xtab <- rs_add_reconciled(setup, "XX1234567_XTAB_parsed.CSV")
  rs_ingest_lab_file(setup, xtab, "03 Aug 2025 09:00")

  g <- rs_guard_rows(con)
  expect_equal(nrow(g), 1)
  diag <- jsonlite::fromJSON(g$payload[[1]])
  # 3 assets on the WO (2 retained + 1 committed); only the committed counts.
  expect_equal(diag$n_prior_ingested_files, 1)

  # The helper the payload is built from, directly (namespace-qualified so a
  # load_all() export copy cannot shadow it).
  prior <- sampleTidy:::.ct_wo_prior_asset_hashes(con, "XX1234567", own_hashes = xtab$hash)
  expect_identical(sort(prior), setup$hash)
})

# ---- 5. idempotency once the lab file has committed ------------------------

test_that("F.10 vs F.17: after a retained-sibling-only work order's lab file commits, re-running the same rows is a no-op (already present) with no review item, and a later NON-matching re-download IS blocked (the committed file now counts)", {
  setup <- rs_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  rs_add_retained_sibling(setup, "XX1234567_COA.pdf")
  rs_ingest_lab_file(setup, setup, "03 Aug 2025 09:00")
  expect_equal(nrow(rs_guard_rows(con)), 0)

  after_sample <- rs_count(con, "sample")
  after_analysis <- rs_count(con, "analysis")
  after_review <- rs_count(con, "review_queue")

  # (a) The same rows again, in a differently-named re-download of the same
  # bytes' content: every row is already present, nothing commits, no item.
  same <- rs_add_reconciled(setup, "PROJ_A.ESDAT_XX1234567_0.Chemistry2e_copy.CSV")
  resolved <- rs_ingest_lab_file(setup, same, "03 Aug 2025 09:00")
  expect_equal(nrow(resolved$clean), 0)
  expect_true(all(resolved$skipped$reason == "already_present"))
  expect_equal(rs_count(con, "sample"), after_sample)
  expect_equal(rs_count(con, "analysis"), after_analysis)
  expect_equal(rs_count(con, "review_queue"), after_review)
  expect_equal(nrow(rs_guard_rows(con)), 0)

  # (b) A re-download carrying a row that matches nothing: the lab file that
  # committed in step 1 is now real prior-ingest evidence, so F.10 blocks.
  redl <- rs_add_reconciled(setup, "PROJ_A.ESDAT_XX1234567_0.Chemistry2e_v2.CSV")
  rs_ingest_lab_file(setup, redl, "05 Aug 2025 09:00")
  expect_equal(rs_count(con, "sample"), after_sample)
  g <- rs_guard_rows(con)
  expect_equal(nrow(g), 1)
  # Two PARSED lab files are now prior evidence (the step-1 commit and the
  # step-(a) already-present re-download, both archived via commit_event);
  # the retained COA still is not.
  parsed <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM ingest_file
     WHERE hash IN (?, ?) AND state = 'archived' AND state_reason LIKE 'commit_event%'",
    params = list(setup$hash, same$hash))$n[[1]]
  expect_equal(parsed, 2)
  expect_equal(jsonlite::fromJSON(g$payload[[1]])$n_prior_ingested_files, 2)
})
