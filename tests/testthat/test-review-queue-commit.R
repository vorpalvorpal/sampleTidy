# PLAN-16 - R/commit.R: the commit-time alias rewrite (`.ct_rewrite_review_payloads()`).
#
# NEW FILE. Scope: TWO criteria only - R-16.15 (idempotence) and R-16.21
# (uuid_alias is the ONLY representation, no duplicate alias_uuid= survives in
# the payload). Every other PLAN-16 criterion (payload content/shape, DDL,
# migration, the k=v-forbidden meta-test, dual-insert-path parity, ...)
# belongs to a different unit; do not add tests for them here.
#
# RED BY DESIGN (RULING D, S-16.4): `review_queue` has no `uuid_alias` column
# yet, and `.ct_rewrite_review_payloads()` (R/commit.R:243) still regex-
# APPENDS `,alias_uuid=<uuid>` into the payload string (replacing an existing
# token on a second call, never deleting it, and never writing a typed
# column). Both tests below are written against the FUTURE shape the plan
# pins - an `UPDATE review_queue SET uuid_alias = ? WHERE uuid = ?`, called
# from a signature `.ct_rewrite_review_payloads(con, review, clean)` (con
# first, matching every other `.ct_*` DB-writing helper in R/commit.R, e.g.
# `.ct_commit_review(con, review, event, actor, reason)`,
# `.ct_materialise_feature_aliases(con, clean, event, actor, reason)`). The
# exact new signature is NOT pinned verbatim anywhere in the plan text; this
# is our best-faith reading from the file's own established convention, not
# an invented one - see the report for the flag on this point.
#
# Fixtures: `tests/testthat/helper-db.R`'s `seed_db()`/`seed_con()` only - no
# edits there. `commit_test_setup()`, `mk_commit_event()`, `mk_p11_row()`,
# `mk_resolved()`, `dangling_alias_row()` below are LOCAL, verbatim copies of
# test-commit.R's own builders (same convention that file documents for
# itself: each testthat file runs in its own environment, so there is no
# cross-file name collision).

# ---- local helpers (verbatim copies of test-commit.R's; see file header) ---

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

#' Plan-11 shaped clean row (feature_pending / uuid_feature_alias etc.) -
#' verbatim copy of test-commit.R's `mk_p11_row()`.
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

mk_resolved <- function(clean = mk_p11_row(), review = tibble::tibble(),
                          skipped = tibble::tibble(), counts = c(new = nrow(clean))) {
  list(clean = clean, review = review, skipped = skipped, counts = counts)
}

dangling_alias_row <- function(con, alias_key) {
  DBI::dbGetQuery(con, "SELECT * FROM feature_alias WHERE alias_key = ? AND uuid_feature IS NULL",
                   params = list(alias_key))
}

# ==============================================================================
# R-16.15: the commit-time alias rewrite is idempotent
# ==============================================================================

test_that("R-16.15: two applications of .ct_rewrite_review_payloads() leave review_queue.uuid_alias identical to what one application produces (an UPDATE is idempotent; the old string-append was not)", {
  setup <- commit_test_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # This test pins the REWRITE STEP's own idempotence, not materialisation
  # (that is R-11.8's job, covered elsewhere) - clean claims an alias already
  # resolved to seed_db()'s fa-0001 (-> f-0001).
  clean <- mk_p11_row(source_ref = "r1", source_hash = setup$hash,
                       feature_pending = TRUE, uuid_feature_alias = "fa-0001")

  # Seed the "before rewrite" review_queue row through the REAL, reuse-listed
  # `review_queue_add()` constructor (R/db-schema.R:292) - exactly the write
  # path `.ct_commit_review()` uses - so this test drives a real review_queue
  # row/uuid rather than a hand-built stand-in for one.
  payload_in <- '{"feature_raw":"T.S01","n_rows":1}'
  rq_uuid <- review_queue_add(con, kind = "unknown_feature",
                               work_order = setup$work_order, source_hash = setup$hash,
                               payload = payload_in)

  review <- tibble::tibble(uuid = rq_uuid, source_ref = "r1", kind = "unknown_feature",
                            source_hash = setup$hash, payload = payload_in)

  .ct_rewrite_review_payloads(con, review, clean)
  after_one <- DBI::dbGetQuery(con, "SELECT uuid_alias FROM review_queue WHERE uuid = ?",
                                params = list(rq_uuid))$uuid_alias[[1]]
  expect_identical(after_one, "fa-0001")

  # Apply again, feeding the rewrite its own output (the SAME review/clean
  # inputs it already ran against) rather than assuming stability (R-16.15).
  # The OLD regex-append path appended a SECOND `,alias_uuid=` clause on a
  # repeat call; an UPDATE re-sets the identical value.
  .ct_rewrite_review_payloads(con, review, clean)
  after_two <- DBI::dbGetQuery(con, "SELECT uuid_alias FROM review_queue WHERE uuid = ?",
                                params = list(rq_uuid))$uuid_alias[[1]]
  expect_identical(after_two, after_one)
})

# ==============================================================================
# R-16.21: the alias uuid is stored once
# ==============================================================================

test_that("R-16.21: after the commit-time alias rewrite, uuid_alias holds the uuid AND the JSON payload remainder carries no alias_uuid key (real seam: commit_event() drives .ct_rewrite_review_payloads() for real)", {
  setup <- commit_test_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  key <- .rc_feature_key("T.NEEDS-REVIEW-ALIAS-16")

  files <- tibble::tibble(hash = setup$hash, filename = basename(setup$path),
                          adapter = "esdat/1", rank = 3L, kept = TRUE)
  clean <- mk_p11_row(source_ref = "r1", source_hash = setup$hash,
                       feature_raw = "T.NEEDS-REVIEW-ALIAS-16", alias_key = key,
                       feature_pending = TRUE, uuid_feature_alias = NA_character_,
                       sample_date = as.Date("2025-07-10"),
                       sample_datetime = as.POSIXct("2025-07-10 09:00:00", tz = "UTC"))

  # A future-shaped diagnostics-only JSON payload (B-16.design: free-form
  # diagnostics -> JSON in `payload`, never parsed by SQL) - deliberately
  # carries NO alias_uuid key from the start, so any key appearing after the
  # rewrite would prove the defect this criterion forbids.
  payload_in <- as.character(jsonlite::toJSON(
    list(feature_raw = "T.NEEDS-REVIEW-ALIAS-16", work_order = "XX1234567", n_rows = 1L),
    auto_unbox = TRUE
  ))
  review <- tibble::tibble(
    source_ref = "r1", kind = "unknown_feature", source_hash = setup$hash,
    payload = payload_in
  )
  resolved <- mk_resolved(clean = clean, review = review)

  commit_event(mk_commit_event(files), resolved, con)

  alias <- dangling_alias_row(con, key)
  expect_equal(nrow(alias), 1)

  stored <- DBI::dbGetQuery(con,
    "SELECT uuid_alias, payload FROM review_queue WHERE kind = 'unknown_feature' AND source_hash = ?",
    params = list(setup$hash))
  expect_equal(nrow(stored), 1)

  # uuid_alias holds the uuid ...
  expect_identical(stored$uuid_alias[[1]], alias$uuid[[1]])

  # ... AND is the ONLY representation (RULING D): no alias_uuid key survives
  # in the parsed JSON remainder, and the payload TEXT ITSELF is untouched by
  # the rewrite - the alias_uuid= clause is not re-emitted into it for human
  # convenience (that becomes a reader-function presentation concern, not a
  # storage concern). A test asserting only that uuid_alias is correct does
  # NOT satisfy R-16.21 - the point is the ABSENCE of the duplicate.
  parsed <- jsonlite::fromJSON(stored$payload[[1]])
  expect_false("alias_uuid" %in% names(parsed))
  expect_identical(stored$payload[[1]], payload_in)
})
