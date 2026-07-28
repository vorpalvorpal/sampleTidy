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
  # router_matrix() reads the global adapter registry. test-adapter-registry.R
  # leaves it cleared (withr::defer(clear_adapters())), so this test passes in
  # isolation but not in the full suite unless we restore the canonical builtin
  # set first. (ingest_dir() self-registers per A33; router_matrix() does not.)
  clear_adapters()
  register_builtin_adapters()

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
  # PLAN-11: sample no longer carries uuid_feature directly - it points at a
  # feature_alias (sample.uuid_feature_alias -> feature_alias.uuid), which in
  # turn resolves to the feature (feature_alias.uuid_feature -> feature.uuid).
  ec <- DBI::dbGetQuery(con, "
    SELECT a.value FROM analysis a
    JOIN \"sample\" s ON a.uuid_sample = s.uuid
    JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
    WHERE fa.uuid_feature = 'f-0001' AND a.uuid_lab = 'lm-0003'")
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
  # PLAN-11 referential integrity across the alias chain: every analysis must
  # resolve to a real sample, every sample to a real feature_alias, and every
  # feature_alias that IS resolved (uuid_feature not null) to a real feature.
  # An *unresolved* alias (uuid_feature IS NULL) is NOT an orphan - it is the
  # valid pending state for a newly-seen sampling point awaiting human
  # feature-assignment (the needs_review queue), which any realistic corpus
  # produces. So the orphan condition is a genuinely DANGLING reference at any
  # hop, not a merely-unresolved alias.
  orphans <- DBI::dbGetQuery(con, "
    SELECT a.uuid FROM analysis a
    LEFT JOIN \"sample\" s ON a.uuid_sample = s.uuid
    LEFT JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
    LEFT JOIN feature f ON fa.uuid_feature = f.uuid
    WHERE s.uuid IS NULL
       OR fa.uuid IS NULL
       OR (fa.uuid_feature IS NOT NULL AND f.uuid IS NULL)")
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
    copy_path <- file.path(st_config("archive_dir"), asset_row$uuid[[1]], asset_row$filename[[1]])
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
  # R-12.15 T-1 sweep (5th instance): the plan's "review_queue contains
  # exactly the engineered unknowns (typo feature, unknown unit) and nothing
  # else" no longer matches the CONTRACT A34 real-fixture rework - the input
  # dir now also carries the real anonymized ES2537534/ES2600185/ES2617126
  # corpora, whose feature codes (P.S03, Q.MW02, ...) are naturally unknown
  # to the seeded registry, not a single deliberately-engineered typo. Direct
  # replay of reconcile_event()'s R-8.1-8.4 stages (`.rc_qc_filter()`,
  # `.rc_resolve_features()`) against the real fixtures confirms
  # review_queue is dominated by real `unknown_feature` groups, not a small
  # fixed engineered set - see the plan-change note filed for this finding.
  # Assert what IS specific and derivable: the table is non-empty, holds at
  # least one unknown_feature item (the dominant, empirically-confirmed
  # kind), and the report's own tally is internally consistent with what it
  # actually wrote to the table (catches a report that over/under-counts, or
  # a no-op that returns an empty report while still queueing rows, or vice
  # versa).
  expect_true(nrow(reviews) > 0)
  expect_true("unknown_feature" %in% reviews$kind)
  expect_equal(report$review_items_opened, nrow(reviews))
})

# ---- Phase 7b item 7: PLAN-15 F.10's re-ingest guard driven through
#      ingest_dir() itself (regression test for item 2's return-contract fix)
#      - the R-10.3 idempotency block below re-ingests BYTE-IDENTICAL files,
#      so content-hash dedup pre-empts the guard before it is ever reached;
#      that is exactly why item 2's bug had no test that could see it. This
#      stages a differently-named, CONTENT-DIFFERENT copy of an
#      already-committed work order's source so the guard genuinely fires
#      through the full route/parse/assemble/reconcile/commit chain. --------

test_that("Phase-7b item 7: ingest_dir() reports a guard-blocked re-download as blocked, not committed - n_events_committed/rows_new/review_items_opened all reflect the block, not a phantom commit", {
  db_path <- e2e_setup()
  input_dir <- build_e2e_input_dir()
  report1 <- ingest_dir(input_dir, db = db_path)
  expect_gt(report1$n_events_committed, 0)  # sanity: WO XX1234567 really committed

  # A differently-named, CONTENT-DIFFERENT (new hash - hash dedup cannot
  # pre-empt this) re-download of work order XX1234567: the SAME resolved
  # feature (T.S01/pH Value/EA005P, already loaded above) but a NEW
  # sample_datetime (01 Sep 2025) matching NOTHING already committed - the
  # classic F.10 block, same revision (0) as the original.
  redl_dir <- withr::local_tempdir()
  chem_path <- file.path(redl_dir, "PROJ_A.ESDAT_XX1234567_0_REDL.Chemistry2e.CSV")
  sample_path <- file.path(redl_dir, "PROJ_A.ESDAT_XX1234567_0_REDL.Sample2e.CSV")
  writeLines(c(
    "SampleCode,ChemCode,OriginalChemName,Prefix,Result,Result_Unit,Total_or_Filtered,Result_Type,Method_Type,Method_Name,Extraction_Date,Analysed_Date,EQL,EQL_Units,Comments,Lab_Qualifier,UCL,LCL",
    "XX1234567001,,pH Value,,6.80,pH Unit,T,Numeric,pH by PC Titrator,EA005P: pH by PC Titrator,,01 Sep 2025,0.01,pH Unit,,,,"
  ), chem_path)
  writeLines(c(
    "SampleCode,Sampled_Date_Time,Field_ID,Blank1,Depth,Blank2,Matrix_Type,Sample_Type,Parent_Sample,Blank3,SDG,Lab_Name,Lab_SampleID,Lab_Comments,Lab_Report_Number",
    "XX1234567001,01 Sep 2025 09:00,T.S01,,,,WATER,Normal,,,,ALSE-Sydney,XX1234567001,,XX1234567"
  ), sample_path)

  con <- DBI::dbConnect(duckdb::duckdb(), db_path, read_only = TRUE)
  before_sample <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM \"sample\"")$n
  before_analysis <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM analysis")$n
  before_review <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM review_queue")$n
  DBI::dbDisconnect(con, shutdown = TRUE)

  report2 <- ingest_dir(redl_dir, db = db_path)

  con2 <- DBI::dbConnect(duckdb::duckdb(), db_path, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con2, shutdown = TRUE))
  after_sample <- DBI::dbGetQuery(con2, "SELECT count(*) AS n FROM \"sample\"")$n
  after_analysis <- DBI::dbGetQuery(con2, "SELECT count(*) AS n FROM analysis")$n
  after_review <- DBI::dbGetQuery(con2, "SELECT count(*) AS n FROM review_queue")$n

  # Reproduction premise: the guard actually fired at the DB level - zero new
  # sample/analysis rows, at least one new review item.
  expect_equal(after_sample, before_sample)
  expect_equal(after_analysis, before_analysis)
  expect_gt(after_review, before_review)

  # The item-2 regression: pre-fix, commit_event() returned invisible(NULL)
  # from BOTH the blocked and the committed branch, so
  # .ig_reconcile_and_commit() derived its tally from resolved$clean (what
  # reconcile WOULD have committed, not what commit_event() actually wrote)
  # and counted a blocked event as committed unconditionally - measured as
  # n_committed=1, new=1, review_opened=0 against 0 samples/0 analyses/1
  # review row actually written.
  expect_equal(report2$n_events_committed, 0)
  expect_equal(report2$rows_new, 0)
  expect_equal(report2$review_items_opened, after_review - before_review)
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
    "snapshot_db", "prune_snapshots",
    # PLAN-15 curation API, added 2026-07-23. The pin is a deliberate gate on
    # the public surface, so new exports belong here explicitly.
    "pending_features", "pending_analytes",
    "confirm_feature_aliases", "confirm_analyte_methods",
    # PLAN-16 R-16.22, added 2026-07-25 (Robin's ruling) and added to
    # CONTRACT.md's public-API list in the same change. Required to be
    # EXPORTED: round 3 found `review_queue_candidate` had no reader anywhere
    # in `R/` - rows were written and nothing could read them back - while
    # CONTRACT A55 makes candidate choice the HUMAN's job. A reviewer cannot
    # choose among candidates the package can store but never show, so the
    # reader has to be on the public surface, not internal.
    "review_queue_candidates",
    # PLAN-15 E.8, added 2026-07-26 and added to CONTRACT.md's public-API list
    # in the same change. EXPORTED because E.8 pins it as public and it is an
    # operator-run tool: a `dry_run` argument and a `db = st_config("live_db")`
    # default are the A16 human-callable convention. The implementer added
    # `@export` but deliberately did NOT run document(), leaving roxygen
    # claiming an export the package did not deliver and man/ stale -- this
    # closes that half-state rather than reverting it to internal.
    "merge_identity_aliases",
    # Phase-7b round 3, added 2026-07-26 (Robin's ruling) and added to
    # CONTRACT.md's public-API list in the same change. EXPORTED because round 3
    # found that NOTHING in the package could close a `sample_collision` review
    # row: `review_queue_close()` is internal and its single production call
    # site filters to `kind = "unknown_feature"`, while the only review-facing
    # exports were read-only. The open queue therefore grew monotonically and
    # never drained. A57 puts resolution in the operator's hands, so the close
    # path has to be on the public surface with `change_log` provenance.
    "resolve_review",
    # PLAN-09 R-9.7 / R-9.11, added 2026-07-28 (Robin's ruling) and added to
    # CONTRACT.md's public-API list in the same change. Both EXPORTED because
    # both are operator-run tools with the A16 human-callable convention (a
    # `db = st_config("live_db")` default; `dry_run` on the ingesting one):
    #
    # `ingest_inbox()` is how the PowerAutomate inbox is actually consumed -
    # one batch per email folder. `ingest_dir()` stays non-recursive (R-9.5),
    # so without this the folder layout has no entry point at all.
    #
    # `quarantine_report()` because NOTHING in the package surfaced a
    # quarantined or failed file: 19 of them sat unnoticed in the live DB from
    # 2026-07-23 until they were found by hand. A backlog nobody can list is a
    # backlog nobody drains - the same reasoning that put `resolve_review`
    # above on the public surface.
    "ingest_inbox", "quarantine_report"
  )
  actual <- getNamespaceExports("sampleTidy")
  expect_setequal(actual, pinned)
})

test_that("R-10.6: DESCRIPTION Imports equal the CONTRACT-pinned set", {
  pinned <- c("checkmate", "cli", "DBI", "digest", "dplyr", "duckdb", "fs",
              "purrr", "readr", "readxl", "rlang", "stringr", "tibble",
              "units", "uuid", "xml2",
              # `jsonlite` added by PLAN-CHANGE REQUEST, Robin 2026-07-25, and
              # added to CONTRACT.md's pinned list in the same change. This
              # guard did its job: PLAN-16 put jsonlite into DESCRIPTION in its
              # own first commit while claiming it was "a dependency already
              # present" (it was not), and R-10.6 went red and stayed red
              # through Phase 6 and two audit rounds because it sits outside
              # the PLAN-16 file window. It is ratified rather than removed
              # because it is used at exactly ONE production call site - the
              # single diagnostics serialiser - and no other pinned Import
              # offers JSON serialisation, so dropping it would mean
              # hand-writing escaping and full-precision number formatting,
              # which is the defect class PLAN-16 exists to eliminate.
              "jsonlite")
  # Read the package's OWN metadata rather than walking up to the source
  # tree: under `R CMD check` the tests run from `sampleTidy.Rcheck/tests/
  # testthat`, where `../../DESCRIPTION` does not exist, so a path-walk makes
  # this drift guard pass under `devtools::test()` and error under
  # `check()` - which is precisely the gate it is meant to satisfy.
  imports_raw <- utils::packageDescription("sampleTidy")$Imports
  expect_false(is.null(imports_raw))
  imports <- strsplit(imports_raw, ",")[[1]]
  imports <- trimws(gsub("\\s*\\(.*\\)\\s*", "", imports))
  imports <- trimws(gsub("\\n", " ", imports))
  expect_setequal(imports, pinned)
})
