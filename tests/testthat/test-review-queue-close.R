# PLAN-15 F.15 "THE PINNED DESIGN" (ruling (a), 2026-07-24, D1-D6) -
# tests/testthat/test-review-queue-close.R.
#
# NEW FILE. Criteria R-15.38 .. R-15.43 span R/db-schema.R (D1 migration
# version 5 + D3 review_queue_add(uuid_target=)/D4 review_queue_close()),
# R/commit.R (D2 .ct_rewrite_review_payloads()/.ct_commit_review() carrying
# uuid_target) and R/feature-alias.R (D5 .fa_confirm_one_alias() call site) -
# whose own test files are owned by sibling P15 units. None of
# `review_queue_close()`, the `uuid_target` column, or migration version 5
# exist yet. Every test below is expected to fail on a missing production
# symbol/column ("could not find function", "unused argument", a DuckDB
# binder error on a column that does not exist) or on a plain failed
# assertion where the pre-migration-5 no-op is observable (R-15.38's first
# half) - that is the correct TDD-red state. Do NOT stub R/db-schema.R,
# R/commit.R or R/feature-alias.R to make any of this pass.
#
# STATUS TERMINOLOGY IS PINNED (D4): 'open' -> 'resolved'. Never 'closed'.
#
# All fixture/helper functions below are LOCAL, self-contained copies in the
# style already used across this suite (test-commit.R's own header note: "no
# cross-file name collision since each testthat test file runs in its own
# environment") - reusing seed_db()/seed_con() (shared helper-db.R) but never
# reaching into another test file's private helpers.

# ---- local helpers ----------------------------------------------------

#' Seed a DB, point `st_config("live_db")` at it (needed by
#' `confirm_feature_aliases()`, R-15.42/R-15.43), add the `asset` table, write
#' one real source file to disk, hash it, and register it in `ingest_file` at
#' state `reconciled` - mirrors test-commit.R's `commit_test_setup()` +
#' test-feature-alias.R's `fa_setup()`, combined because R-15.42/R-15.43 need
#' both a live `commit_event()`-held `con` AND `confirm_feature_aliases()`'s
#' own `st_config("live_db")`-resolved connection against the SAME file.
rq_commit_setup <- function(filename = "PROJ_A.ESDAT_XX1234567_0.Chemistry2e.CSV",
                             work_order = "XX1234567", revision = 0L) {
  # Cleanups bound to the CALLING TEST's frame, not this helper's own frame -
  # the withr wrong-frame trap (language-footguns.md ## R).
  env <- parent.frame()
  db_path <- seed_db(dir = withr::local_tempdir(.local_envir = env))
  withr::local_options(list("sampletidy.live_db" = db_path), .local_envir = env)
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

  list(con = con, path = db_path, hash = hash, src_path = src_path, work_order = work_order)
}

rq_event <- function(files, work_order = "XX1234567") {
  list(
    work_order = work_order, orphan = FALSE,
    results = tibble::tibble(), samples = tibble::tibble(),
    files = files,
    report = list(n_results = 0L, n_by_sample_type = list(), n_ncp_foreign = 0L,
                  skipped = tibble::tibble(hash = character(), source_ref = character(), reason = character()),
                  warnings = character())
  )
}

#' Local copy of test-commit.R's `mk_p11_row()` (verbatim shape) - the plan-09
#' `clean` row shape `commit_event()` expects.
rq_row <- function(...) {
  defaults <- list(
    source_hash = "rq-hash-x", source_ref = "row1", work_order = "XX1234567", revision = 0L,
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

rq_resolved <- function(clean, review = tibble::tibble(), skipped = tibble::tibble(),
                         counts = c(new = nrow(clean))) {
  list(clean = clean, review = review, skipped = skipped, counts = counts)
}

#' The dangling `feature_alias` row a pending-feature commit materialised,
#' looked up by its (unique per test) `alias_key`.
rq_dangling_alias <- function(con, alias_key) {
  DBI::dbGetQuery(con, "SELECT * FROM feature_alias WHERE alias_key = ? AND uuid_feature IS NULL",
                   params = list(alias_key))
}

# ======================================================================
# R-15.38: ensure_schema() migration version 5 (D1)
# ======================================================================

test_that("R-15.38: ensure_schema() on a pre-version-5 database adds uuid_target to review_queue; a pre-existing row reads NA on it; a second ensure_schema() call is a no-op (version 5 recorded exactly once)", {
  db_path <- seed_db()
  con <- seed_con(db_path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # Force a genuinely pre-version-5 database. Written to be a no-op TODAY (the
  # column and the marker do not exist yet) and to actually undo migration 5 once
  # D1 lands - otherwise seed_db()'s own ensure_schema() applies the migration
  # during setup and this test can never observe the transition it exists to check.
  DBI::dbExecute(con, "ALTER TABLE review_queue DROP COLUMN IF EXISTS uuid_target")
  DBI::dbExecute(con, "DELETE FROM schema_version WHERE version = 5")

  # DO NOT DELETE THE TWO STATEMENTS ABOVE. They look redundant today because
  # migration 5 does not exist yet - that is exactly why they are there. Without
  # them this test silently stops testing R-15.38 the moment D1 lands.
  #
  # review_queue_add() is the sanctioned pre-migration-5 writer (it never sets
  # uuid_target), so this row stands in for a row written before the migration ran.
  pre_uuid <- review_queue_add(con, kind = "unknown_feature", work_order = "XX1234567",
                                source_hash = "pre-mig-hash", payload = "pre-existing")

  ensure_schema(con)

  cols <- DBI::dbGetQuery(
    con,
    "SELECT column_name FROM information_schema.columns WHERE table_name = 'review_queue'"
  )$column_name
  expect_true("uuid_target" %in% cols)

  pre_row <- DBI::dbGetQuery(con, "SELECT uuid_target FROM review_queue WHERE uuid = ?",
                              params = list(pre_uuid))
  expect_equal(nrow(pre_row), 1)
  expect_true(is.na(pre_row$uuid_target[[1]]))

  # A second (and third) ensure_schema() call must not re-attempt the ALTER
  # or re-insert the schema_version marker.
  ensure_schema(con)
  ensure_schema(con)

  v5_count <- DBI::dbGetQuery(
    con, "SELECT count(*) AS n FROM schema_version WHERE version = 5"
  )$n[[1]]
  expect_equal(v5_count, 1)
})

# ======================================================================
# R-15.39: commit writes uuid_target = the SAME commit's feature_alias.uuid (D2)
# ======================================================================

test_that("R-15.39: committing an event with a pending feature writes a review_queue row whose uuid_target equals the feature_alias.uuid created by that SAME commit - not merely non-NA; a review row that is not a pending-feature row has uuid_target NA", {
  setup <- rq_commit_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  key <- .rc_feature_key("T.RQ-PENDING")

  files <- tibble::tibble(hash = setup$hash, filename = basename(setup$src_path),
                          adapter = "esdat/1", rank = 3L, kept = TRUE)

  pending_row <- rq_row(source_ref = "r1", source_hash = setup$hash,
                        feature_raw = "T.RQ-PENDING", alias_key = key,
                        feature_pending = TRUE, uuid_feature_alias = NA_character_,
                        sample_date = as.Date("2025-07-15"),
                        sample_datetime = as.POSIXct("2025-07-15 09:00:00", tz = "UTC"))
  other_row <- rq_row(source_ref = "r2", source_hash = setup$hash,
                       feature_raw = "T.S02", alias_key = .rc_feature_key("T.S02"),
                       feature_pending = FALSE, uuid_feature_alias = "fa-0002",
                       sample_date = as.Date("2025-07-15"),
                       sample_datetime = as.POSIXct("2025-07-15 09:05:00", tz = "UTC"))
  clean <- dplyr::bind_rows(pending_row, other_row)

  # r1 is the pending-feature row (D1's `unknown_feature`); r2 stands in for
  # a review row of a kind D1 pins to NULL under this plan (e.g.
  # value_conflict), source_ref NA so `.ct_rewrite_review_payloads()` never
  # matches it - the "not a pending-feature row" half of the criterion.
  review <- tibble::tibble(
    source_ref = c("r1", NA_character_),
    kind = c("unknown_feature", "value_conflict"),
    source_hash = c(setup$hash, setup$hash),
    payload = c("r1,feature_raw=T.RQ-PENDING,work_order=XX1234567,n_rows=1",
                "unrelated conflict, no source_ref")
  )
  resolved <- rq_resolved(clean = clean, review = review)

  commit_event(rq_event(files), resolved, con)

  alias <- rq_dangling_alias(con, key)
  expect_equal(nrow(alias), 1)
  alias_uuid <- alias$uuid[[1]]

  rows <- DBI::dbGetQuery(
    con, "SELECT kind, uuid_target FROM review_queue WHERE source_hash = ? ORDER BY kind",
    params = list(setup$hash)
  )
  expect_equal(nrow(rows), 2)

  pending_hit <- rows[rows$kind == "unknown_feature", ]
  other_hit <- rows[rows$kind == "value_conflict", ]
  expect_equal(nrow(pending_hit), 1)
  expect_equal(nrow(other_hit), 1)

  # THE trap this criterion exists to catch: compare against the REAL alias
  # uuid this commit created, not merely assert non-NA.
  expect_identical(pending_hit$uuid_target[[1]], alias_uuid)
  expect_true(is.na(other_hit$uuid_target[[1]]))
})

# ======================================================================
# R-15.40: review_queue_close() closes exactly the matching open row(s) (D4)
# ======================================================================

test_that("R-15.40: review_queue_close() closes exactly the matching open row (status -> 'resolved', resolution/resolved_by/resolved_at populated); a SECOND open row with a DIFFERENT uuid_target is untouched; a second identical call closes zero rows", {
  db_path <- seed_db()
  con <- seed_con(db_path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  target_uuid <- "fa-target-0001"
  other_uuid <- "fa-other-0002"

  uuid_a <- review_queue_add(con, kind = "unknown_feature", work_order = "XX1234567",
                              source_hash = "h-a", payload = "a", uuid_target = target_uuid)
  uuid_b <- review_queue_add(con, kind = "unknown_feature", work_order = "XX1234567",
                              source_hash = "h-b", payload = "b", uuid_target = other_uuid)

  n_closed <- review_queue_close(con, uuid_target = target_uuid,
                                  resolution = "confirmed", resolved_by = "robin")
  expect_equal(n_closed, 1)

  row_a <- DBI::dbGetQuery(
    con, "SELECT status, resolution, resolved_by, resolved_at FROM review_queue WHERE uuid = ?",
    params = list(uuid_a)
  )
  expect_identical(row_a$status[[1]], "resolved")
  expect_identical(row_a$resolution[[1]], "confirmed")
  expect_identical(row_a$resolved_by[[1]], "robin")
  expect_false(is.na(row_a$resolved_at[[1]]))

  # The unrelated open row (a DIFFERENT uuid_target) must be untouched - a
  # test that omits this cannot fail if the UPDATE forgets its WHERE clause.
  row_b <- DBI::dbGetQuery(con, "SELECT status, resolution, resolved_by, resolved_at FROM review_queue WHERE uuid = ?",
                            params = list(uuid_b))
  expect_identical(row_b$status[[1]], "open")
  expect_true(is.na(row_b$resolution[[1]]))
  expect_true(is.na(row_b$resolved_by[[1]]))
  expect_true(is.na(row_b$resolved_at[[1]]))

  # Idempotent: nothing left open under target_uuid, so a second call closes
  # zero rows.
  n_closed_again <- review_queue_close(con, uuid_target = target_uuid,
                                        resolution = "confirmed", resolved_by = "robin")
  expect_equal(n_closed_again, 0)
})

# ======================================================================
# R-15.41: the D6 NULL trap
# ======================================================================

test_that("R-15.41: review_queue_close() with a NA/missing target, or a target matching no row, closes zero rows and does not error; a row with uuid_target IS NULL is never closed by any call", {
  db_path <- seed_db()
  con <- seed_con(db_path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # A row with NO uuid_target - review_queue_add()'s default (D1's meaning
  # for a non-pending-feature kind, or a pre-migration row).
  null_uuid <- review_queue_add(con, kind = "value_conflict", work_order = "XX1234567",
                                 source_hash = "h-null", payload = "null-target")

  before_target <- DBI::dbGetQuery(con, "SELECT uuid_target FROM review_queue WHERE uuid = ?",
                                    params = list(null_uuid))$uuid_target[[1]]
  expect_true(is.na(before_target))

  # (D6) An NA target must not be interpolated as the SQL/R literal string
  # "NA" and match nothing only by accident - review_queue_close() must
  # return early on a missing/NA target.
  n_na <- expect_no_error(
    review_queue_close(con, uuid_target = NA_character_, resolution = "confirmed", resolved_by = "robin")
  )
  expect_equal(n_na, 0)

  # A target matching no row - the second, weaker half.
  n_missing <- expect_no_error(
    review_queue_close(con, uuid_target = "no-such-uuid-anywhere", resolution = "confirmed", resolved_by = "robin")
  )
  expect_equal(n_missing, 0)

  still_open <- DBI::dbGetQuery(con, "SELECT status FROM review_queue WHERE uuid = ?",
                                 params = list(null_uuid))
  expect_equal(nrow(still_open), 1)
  expect_identical(still_open$status[[1]], "open")
})

# ======================================================================
# R-15.42: end-to-end, the original F.15 acceptance
# ======================================================================

test_that("R-15.42: end-to-end (F.15 acceptance) - open a review item via commit, confirm its alias via confirm_feature_aliases(), the item is no longer 'open', and an unrelated open item is untouched", {
  setup <- rq_commit_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  key <- .rc_feature_key("T.RQ-E2E")

  files <- tibble::tibble(hash = setup$hash, filename = basename(setup$src_path),
                          adapter = "esdat/1", rank = 3L, kept = TRUE)
  pending_row <- rq_row(source_ref = "r1", source_hash = setup$hash,
                        feature_raw = "T.RQ-E2E", alias_key = key,
                        feature_pending = TRUE, uuid_feature_alias = NA_character_,
                        sample_date = as.Date("2025-07-16"),
                        sample_datetime = as.POSIXct("2025-07-16 09:00:00", tz = "UTC"))
  review <- tibble::tibble(
    source_ref = "r1", kind = "unknown_feature", source_hash = setup$hash,
    payload = "r1,feature_raw=T.RQ-E2E,work_order=XX1234567,n_rows=1"
  )
  commit_event(rq_event(files), rq_resolved(clean = pending_row, review = review), con)

  alias <- rq_dangling_alias(con, key)
  expect_equal(nrow(alias), 1)
  alias_uuid <- alias$uuid[[1]]

  # An unrelated, already-open item (a distinct uuid_target) seeded before the
  # confirmation - must survive it untouched (mirrors R-15.40's fixture
  # shape at the end-to-end level).
  unrelated_uuid <- review_queue_add(con, kind = "unknown_feature", work_order = "XX1234567",
                                      source_hash = "unrelated-hash", payload = "unrelated",
                                      uuid_target = "fa-9999-unrelated-target")

  confirm_feature_aliases(alias_uuid, "f-0002", confirmed_by = "robin")

  closed <- DBI::dbGetQuery(con, "SELECT status FROM review_queue WHERE uuid_target = ?",
                             params = list(alias_uuid))
  expect_equal(nrow(closed), 1)
  expect_identical(closed$status[[1]], "resolved")

  still_open <- DBI::dbGetQuery(con, "SELECT status FROM review_queue WHERE uuid = ?",
                                 params = list(unrelated_uuid))
  expect_identical(still_open$status[[1]], "open")
})

# ======================================================================
# R-15.43: an ABORTED confirmation leaves the review item open
# ======================================================================

test_that("R-15.43 (PROVISIONAL ORACLE: R-15.43 - see note below): a confirm_feature_aliases() call that ABORTS leaves the review item 'open'", {
  # PROVISIONAL ORACLE (brief note / phase4-test-authoring.md #8): this
  # proves an ABORTED confirm_feature_aliases() does not close the review
  # item - it does NOT prove the close lives inside confirm's own
  # transaction (that would require observing a partial-write rollback mid-
  # transaction, which this black-box assertion cannot see). Phase 6 must
  # re-check the transactional claim once D5 is implemented, e.g. by
  # instrumenting or by a fault-injection test that aborts AFTER the
  # feature_alias UPDATE but BEFORE the review_queue_close() UPDATE would
  # otherwise commit.
  setup <- rq_commit_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  key <- .rc_feature_key("T.RQ-ABORT")

  files <- tibble::tibble(hash = setup$hash, filename = basename(setup$src_path),
                          adapter = "esdat/1", rank = 3L, kept = TRUE)
  pending_row <- rq_row(source_ref = "r1", source_hash = setup$hash,
                        feature_raw = "T.RQ-ABORT", alias_key = key,
                        feature_pending = TRUE, uuid_feature_alias = NA_character_,
                        sample_date = as.Date("2025-07-17"),
                        sample_datetime = as.POSIXct("2025-07-17 09:00:00", tz = "UTC"))
  review <- tibble::tibble(
    source_ref = "r1", kind = "unknown_feature", source_hash = setup$hash,
    payload = "r1,feature_raw=T.RQ-ABORT,work_order=XX1234567,n_rows=1"
  )
  commit_event(rq_event(files), rq_resolved(clean = pending_row, review = review), con)

  alias <- rq_dangling_alias(con, key)
  expect_equal(nrow(alias), 1)
  alias_uuid <- alias$uuid[[1]]

  # Force the abort: uuid_feature = NA is rejected at feature-alias.R:82-87,
  # before any write (feature_alias update OR review_queue close) happens.
  expect_error(
    confirm_feature_aliases(alias_uuid, NA_character_, confirmed_by = "robin"),
    class = "sampletidy_error"
  )

  still_open <- DBI::dbGetQuery(con, "SELECT status FROM review_queue WHERE uuid_target = ?",
                                 params = list(alias_uuid))
  expect_equal(nrow(still_open), 1)
  expect_identical(still_open$status[[1]], "open")
})
