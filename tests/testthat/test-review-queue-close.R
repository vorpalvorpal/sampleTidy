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

  # Force a genuinely pre-version-5 database - otherwise seed_db()'s own
  # ensure_schema() applies the migration during setup and this test can never
  # observe the transition it exists to check.
  #
  # THE CHILD TABLE MUST GO FIRST, AND THAT IS NOT OPTIONAL (orchestrator,
  # 2026-07-26). DuckDB 1.4.1 refuses to ALTER a table any FK references at
  # all - reproduced in isolation on a two-table toy schema: dropping an
  # UNRELATED column from the parent raises "Dependency Error: Cannot alter
  # entry ... because there are entries that depend on it", and neither
  # IF EXISTS nor CASCADE suppresses it. PLAN-16's version-6 migration gives
  # review_queue exactly such a dependant (review_queue_candidate.uuid_review
  # REFERENCES review_queue(uuid)). The DROP below was silently a no-op while
  # `uuid_target` did not exist (IF EXISTS short-circuits before the dependency
  # check); the moment D1 landed it began to ERROR. Both version markers are
  # cleared so ensure_schema() re-applies 5 AND 6, restoring the child table
  # rather than leaving the fixture DB half-migrated.
  DBI::dbExecute(con, "DROP TABLE IF EXISTS review_queue_candidate")
  DBI::dbExecute(con, "ALTER TABLE review_queue DROP COLUMN IF EXISTS uuid_target")
  DBI::dbExecute(con, "DELETE FROM schema_version WHERE version IN (5, 6)")

  # DO NOT DELETE THE THREE STATEMENTS ABOVE - without them this test silently
  # stops testing R-15.38.
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

  # Phase 7b Tier-3: R-15.38's own "the ALTER is not re-attempted" clause had
  # no oracle - the v5_count == 1 assertion above is guaranteed by the
  # marker-skip regardless of whether the v5 DDL is itself idempotent, so it
  # cannot tell "the DDL is safe to re-run" from "the DDL never gets
  # re-run". Delete ONLY the version-5 marker row (columns/data untouched -
  # unlike the fixture-forcing block at the top of this test, which also
  # drops the column) and re-apply: `ALTER TABLE ... ADD COLUMN IF NOT
  # EXISTS uuid_target` (the real production DDL) must not raw-error just
  # because the column is already present, and review_queue must still carry
  # EXACTLY ONE uuid_target column afterwards (not silently duplicated).
  DBI::dbExecute(con, "DELETE FROM schema_version WHERE version = 5")
  expect_no_error(ensure_schema(con))

  uuid_target_cols <- DBI::dbGetQuery(
    con,
    "SELECT column_name FROM information_schema.columns
     WHERE table_name = 'review_queue' AND column_name = 'uuid_target'"
  )
  expect_equal(nrow(uuid_target_cols), 1)
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

test_that("R-15.40: review_queue_close() closes exactly the matching open row(s) (status -> 'resolved', resolution/resolved_by/resolved_at populated); a SECOND open row with the SAME uuid_target is ALSO closed (n == 2, pinning the docstring's PLURAL claim, item G); a THIRD open row with a DIFFERENT uuid_target is untouched; a second identical call closes zero rows", {
  db_path <- seed_db()
  con <- seed_con(db_path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  target_uuid <- "fa-target-0001"
  other_uuid <- "fa-other-0002"

  uuid_a <- review_queue_add(con, kind = "unknown_feature", work_order = "XX1234567",
                              source_hash = "h-a", payload = "a", uuid_target = target_uuid)
  # Phase 7b round-2 item G: a SECOND row sharing the SAME uuid_target - the
  # docstring and this criterion are both PLURAL ("closes every open row"),
  # but before this fix every fixture had exactly one matching row, so
  # n == 1 passed equally for a correct plural close and for a close that
  # (bugged) LIMITs to one row. This row pins the plural claim for real.
  uuid_a2 <- review_queue_add(con, kind = "unknown_feature", work_order = "XX1234567",
                               source_hash = "h-a2", payload = "a2", uuid_target = target_uuid)
  uuid_b <- review_queue_add(con, kind = "unknown_feature", work_order = "XX1234567",
                              source_hash = "h-b", payload = "b", uuid_target = other_uuid)

  n_closed <- review_queue_close(con, uuid_target = target_uuid,
                                  resolution = "confirmed", resolved_by = "robin",
                                  kind = NULL)
  expect_equal(n_closed, 2)
  # Phase 7b: the SQL path returns a `numeric` (double) count natively - must
  # match the NA/zero-length guard's own invisible(0L) (R-15.41, below), or
  # the two zero-row cases D6 unifies would silently disagree on type.
  expect_type(n_closed, "integer")

  row_a <- DBI::dbGetQuery(
    con, "SELECT status, resolution, resolved_by, resolved_at FROM review_queue WHERE uuid = ?",
    params = list(uuid_a)
  )
  expect_identical(row_a$status[[1]], "resolved")
  expect_identical(row_a$resolution[[1]], "confirmed")
  expect_identical(row_a$resolved_by[[1]], "robin")
  expect_false(is.na(row_a$resolved_at[[1]]))

  row_a2 <- DBI::dbGetQuery(
    con, "SELECT status, resolution, resolved_by, resolved_at FROM review_queue WHERE uuid = ?",
    params = list(uuid_a2)
  )
  expect_identical(row_a2$status[[1]], "resolved")
  expect_identical(row_a2$resolution[[1]], "confirmed")
  expect_identical(row_a2$resolved_by[[1]], "robin")
  expect_false(is.na(row_a2$resolved_at[[1]]))

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
                                        resolution = "confirmed", resolved_by = "robin",
                                        kind = NULL)
  expect_equal(n_closed_again, 0)
})

# ======================================================================
# Phase 7b round-2 item A: review_queue_close(kind =) - uuid_target is a
# POLYMORPHIC key (version-5 ladder comment, R/db-schema.R), so closing on it
# alone closes every open row on that target regardless of kind. `kind` is
# OPTIONAL (default NULL = close across all kinds, preserving the pre-fix
# behaviour) - R/feature-alias.R's call site is NOT touched by this unit and
# still calls review_queue_close() without `kind` (a later wave's job).
# ======================================================================

test_that("Phase 7b item A: review_queue_close(kind =) closes only the matching kind, leaving a DIFFERENT-kind open row on the SAME uuid_target untouched; the plural close still works WITHIN a kind", {
  db_path <- seed_db()
  con <- seed_con(db_path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  target_uuid <- "fa-kindtest-0001"

  uuid_x1 <- review_queue_add(con, kind = "unknown_feature", work_order = "XX1234567",
                               source_hash = "h-x1", payload = "x1", uuid_target = target_uuid)
  uuid_x2 <- review_queue_add(con, kind = "unknown_feature", work_order = "XX1234567",
                               source_hash = "h-x2", payload = "x2", uuid_target = target_uuid)
  uuid_y <- review_queue_add(con, kind = "value_conflict", work_order = "XX1234567",
                              source_hash = "h-y", payload = "y", uuid_target = target_uuid)

  n_closed <- review_queue_close(con, uuid_target = target_uuid, resolution = "confirmed",
                                  resolved_by = "robin", kind = "unknown_feature")
  expect_equal(n_closed, 2) # the plural close, WITHIN a kind (item G's fixture, narrowed by kind)
  expect_type(n_closed, "integer")

  row_x1 <- DBI::dbGetQuery(con, "SELECT status FROM review_queue WHERE uuid = ?", params = list(uuid_x1))
  row_x2 <- DBI::dbGetQuery(con, "SELECT status FROM review_queue WHERE uuid = ?", params = list(uuid_x2))
  row_y <- DBI::dbGetQuery(con, "SELECT status FROM review_queue WHERE uuid = ?", params = list(uuid_y))

  expect_identical(row_x1$status[[1]], "resolved")
  expect_identical(row_x2$status[[1]], "resolved")
  # SAME uuid_target, DIFFERENT kind - the exact reproduction from the audit
  # (confirm_feature_aliases() closing a sample_collision row that was never
  # the one it meant to resolve): must stay open.
  expect_identical(row_y$status[[1]], "open")
})

test_that("Phase 7b item A control: review_queue_close() with an EXPLICIT kind = NULL still closes across all kinds - the escape hatch stays available, but only to a caller that asks for it in so many words", {
  db_path <- seed_db()
  con <- seed_con(db_path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  target_uuid <- "fa-allkinds-0001"
  uuid_x <- review_queue_add(con, kind = "unknown_feature", work_order = "XX1234567",
                              source_hash = "h-ax", payload = "x", uuid_target = target_uuid)
  uuid_y <- review_queue_add(con, kind = "value_conflict", work_order = "XX1234567",
                              source_hash = "h-ay", payload = "y", uuid_target = target_uuid)

  n_closed <- review_queue_close(con, uuid_target = target_uuid, resolution = "confirmed", resolved_by = "robin", kind = NULL)
  expect_equal(n_closed, 2)

  row_x <- DBI::dbGetQuery(con, "SELECT status FROM review_queue WHERE uuid = ?", params = list(uuid_x))
  row_y <- DBI::dbGetQuery(con, "SELECT status FROM review_queue WHERE uuid = ?", params = list(uuid_y))
  expect_identical(row_x$status[[1]], "resolved")
  expect_identical(row_y$status[[1]], "resolved")
})

test_that("Phase 7b item A: OMITTING kind is a classed caller error, so the round-2 rank-1 defect cannot recur by forgetting the argument", {
  db_path <- seed_db()
  con <- seed_con(db_path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  review_queue_add(con, kind = "unknown_feature", source_hash = "h-req",
                   payload = "p", uuid_target = "fa-req-target")

  # The point of the abort: documentation did NOT stop this. `kind` was
  # documented as narrowing the close and the one live caller still omitted
  # it, silently resolving a `sample_collision` row it had opened itself.
  expect_error(
    review_queue_close(con, uuid_target = "fa-req-target",
                       resolution = "confirmed", resolved_by = "robin"),
    class = "sampletidy_error"
  )

  # Non-vacuity control: the row is untouched by the refused call, so the
  # abort happens BEFORE any UPDATE rather than after a partial one.
  still_open <- DBI::dbGetQuery(
    con, "SELECT status FROM review_queue WHERE uuid_target = 'fa-req-target'")
  expect_identical(still_open$status[[1]], "open")
})

# ======================================================================
# Phase 7b round-2 item C: review_queue_close() must write change_log rows
# through the same mutation-layer audit path review_queue_add() already
# uses, not a raw DBI::dbExecute() UPDATE producing zero.
# ======================================================================

test_that("Phase 7b item C: review_queue_close() writes change_log rows via the mutation layer, mirroring review_queue_add()'s own audit trail", {
  dir <- withr::local_tempdir()
  db <- seed_db(dir)
  con <- seed_con(db)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  uuid_a <- review_queue_add(con, kind = "unknown_feature", work_order = "XX1234567",
                              source_hash = "h-cl-a", payload = "a", uuid_target = "fa-cl-target")
  uuid_b <- review_queue_add(con, kind = "unknown_feature", work_order = "XX1234567",
                              source_hash = "h-cl-b", payload = "b", uuid_target = "fa-cl-other")

  before <- DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM change_log")$n

  n_closed <- review_queue_close(con, uuid_target = "fa-cl-target", resolution = "confirmed", resolved_by = "robin", kind = NULL)
  expect_equal(n_closed, 1)

  after <- DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM change_log")$n
  expect_gt(after, before) # zero before this fix (audit asymmetry, item 12/C)

  close_log <- DBI::dbGetQuery(
    con,
    "SELECT COUNT(*) AS n FROM change_log WHERE tbl = 'review_queue' AND uuid_row = ? AND action = 'update'",
    params = list(uuid_a)
  )$n
  expect_gt(close_log, 0)

  # the row NOT closed by this call must not have gained a change_log row.
  other_log <- DBI::dbGetQuery(
    con,
    "SELECT COUNT(*) AS n FROM change_log WHERE tbl = 'review_queue' AND uuid_row = ? AND action = 'update'",
    params = list(uuid_b)
  )$n
  expect_equal(other_log, 0)
})

# ======================================================================
# Phase 7b round 3, S6: review_queue_close() used to write
# change_log.actor = "pipeline", discarding `resolved_by` - asymmetric with
# its own sibling db_update() in the SAME transaction
# (.fa_confirm_one_alias(), R/feature-alias.R, actor = confirmed_by). Fixed:
# actor = resolved_by.
# ======================================================================

test_that("Phase 7b (S6): review_queue_close() writes change_log.actor = resolved_by, not a generic 'pipeline' placeholder", {
  dir <- withr::local_tempdir()
  db <- seed_db(dir)
  con <- seed_con(db)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  uuid_a <- review_queue_add(con, kind = "unknown_feature", work_order = "XX1234567",
                              source_hash = "h-actor-a", payload = "a", uuid_target = "fa-actor-target")

  review_queue_close(con, uuid_target = "fa-actor-target", resolution = "confirmed",
                      resolved_by = "robin", kind = NULL)

  actor_rows <- DBI::dbGetQuery(
    con,
    "SELECT DISTINCT actor FROM change_log WHERE tbl = 'review_queue' AND uuid_row = ? AND action = 'update'",
    params = list(uuid_a)
  )$actor
  expect_true(length(actor_rows) > 0)
  expect_true(all(actor_rows == "robin"))
  expect_false(any(actor_rows == "pipeline"))
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

  # Phase 7b round-2 item F: D6's stated danger is an NA_character_
  # interpolated as the LITERAL STRING "NA" matching a row the moment
  # anything ever wrote that literal string into uuid_target. Without a real
  # `uuid_target = 'NA'` row in the fixture, "an NA target closes zero rows"
  # (below) passes equally for the correct R-side guard and for a bugged
  # implementation that interpolates and merely happens to match nothing.
  # Seed that row for real so the assertion actually discriminates.
  na_literal_uuid <- review_queue_add(con, kind = "value_conflict", work_order = "XX1234567",
                                       source_hash = "h-na-literal", payload = "na-literal-target",
                                       uuid_target = "NA")
  before_na_literal <- DBI::dbGetQuery(con, "SELECT uuid_target, status FROM review_queue WHERE uuid = ?",
                                        params = list(na_literal_uuid))
  expect_identical(before_na_literal$uuid_target[[1]], "NA")
  expect_identical(before_na_literal$status[[1]], "open")

  # (D6) An NA target must not be interpolated as the SQL/R literal string
  # "NA" and match nothing only by accident - review_queue_close() must
  # return early on a missing/NA target.
  n_na <- expect_no_error(
    review_queue_close(con, uuid_target = NA_character_, resolution = "confirmed", resolved_by = "robin", kind = NULL)
  )
  expect_equal(n_na, 0)
  expect_type(n_na, "integer")

  # A target matching no row - the second, weaker half.
  n_missing <- expect_no_error(
    review_queue_close(con, uuid_target = "no-such-uuid-anywhere", resolution = "confirmed", resolved_by = "robin", kind = NULL)
  )
  expect_equal(n_missing, 0)
  expect_type(n_missing, "integer")

  still_open <- DBI::dbGetQuery(con, "SELECT status FROM review_queue WHERE uuid = ?",
                                 params = list(null_uuid))
  expect_equal(nrow(still_open), 1)
  expect_identical(still_open$status[[1]], "open")

  # Item F, the real discriminator: the row whose uuid_target is the LITERAL
  # STRING "NA" must still be open after the NA-target call above - a bugged
  # implementation that interpolates NA_character_ as "NA" would have closed
  # exactly this row.
  still_open_na_literal <- DBI::dbGetQuery(con, "SELECT status FROM review_queue WHERE uuid = ?",
                                            params = list(na_literal_uuid))
  expect_equal(nrow(still_open_na_literal), 1)
  expect_identical(still_open_na_literal$status[[1]], "open")
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

test_that("R-15.43 (transactional arm): when a MULTI-alias confirmation aborts on a later alias, an EARLIER alias's review item that was already closed inside the same transaction is rolled back to 'open', and that alias stays unconfirmed", {
  # ORCHESTRATOR ADJUDICATION of the provisional oracle above (2026-07-26).
  # The block above aborts on `uuid_feature = NA`, which `.fa_confirm_one_alias()`
  # rejects BEFORE any write happens - so it passes identically whether the
  # close lives inside confirm's transaction or outside it, and cannot pin D5's
  # atomicity claim. This arm makes the abort land AFTER a real, successful
  # close: two pending aliases in ONE commit, then one confirm call whose FIRST
  # alias succeeds (updating feature_alias AND closing its review item) and
  # whose SECOND aborts. `db_transaction()` (R/mutate.R:97) rolls the whole
  # thing back, so the first item must return to 'open'.
  #
  # WHAT THIS ARM DOES AND DOES NOT PIN - both measured by mutation, 2026-07-26,
  # not argued. Stated because the first version of this note overclaimed.
  #   KILLS: closing on a SEPARATE connection (`DBI::dbConnect()` /
  #     its own `with_db_write()`), which autocommits outside the enclosing
  #     transaction and so survives the rollback. Mutant applied, this block
  #     and ONLY this block went red.
  #   DOES NOT KILL: hoisting the close to run immediately AFTER the
  #     transaction commits. Mutant applied, whole file stayed green - on an
  #     abort that implementation never reaches the close either, so no
  #     black-box assertion can separate it from the correct one. Telling
  #     those two apart needs a fault injected BETWEEN the commit and the
  #     close, which is out of reach from here.
  # So: in-transaction placement is still partly a code-review property. That
  # is a real limit of this arm, recorded rather than papered over.
  setup <- rq_commit_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  key_a <- .rc_feature_key("T.RQ-TXN-A")
  key_b <- .rc_feature_key("T.RQ-TXN-B")

  files <- tibble::tibble(hash = setup$hash, filename = basename(setup$src_path),
                          adapter = "esdat/1", rank = 3L, kept = TRUE)
  clean <- dplyr::bind_rows(
    rq_row(source_ref = "r1", source_hash = setup$hash,
           feature_raw = "T.RQ-TXN-A", alias_key = key_a,
           feature_pending = TRUE, uuid_feature_alias = NA_character_,
           sample_date = as.Date("2025-07-18"),
           sample_datetime = as.POSIXct("2025-07-18 09:00:00", tz = "UTC")),
    rq_row(source_ref = "r2", source_hash = setup$hash,
           feature_raw = "T.RQ-TXN-B", alias_key = key_b,
           feature_pending = TRUE, uuid_feature_alias = NA_character_,
           sample_date = as.Date("2025-07-19"),
           sample_datetime = as.POSIXct("2025-07-19 09:00:00", tz = "UTC"))
  )
  review <- tibble::tibble(
    source_ref = c("r1", "r2"),
    kind = "unknown_feature",
    source_hash = setup$hash,
    payload = c("r1,feature_raw=T.RQ-TXN-A,work_order=XX1234567,n_rows=1",
                "r2,feature_raw=T.RQ-TXN-B,work_order=XX1234567,n_rows=1")
  )
  commit_event(rq_event(files), rq_resolved(clean = clean, review = review), con)

  alias_a <- rq_dangling_alias(con, key_a)
  alias_b <- rq_dangling_alias(con, key_b)
  expect_equal(nrow(alias_a), 1)
  expect_equal(nrow(alias_b), 1)

  # Alias A is confirmable; alias B carries NA and aborts. A is FIRST, so its
  # close really does execute before the abort.
  expect_error(
    confirm_feature_aliases(c(alias_a$uuid[[1]], alias_b$uuid[[1]]),
                             c("f-0002", NA_character_), confirmed_by = "robin"),
    class = "sampletidy_error"
  )

  rolled_back <- DBI::dbGetQuery(con, "SELECT status FROM review_queue WHERE uuid_target = ?",
                                  params = list(alias_a$uuid[[1]]))
  expect_equal(nrow(rolled_back), 1)
  expect_identical(rolled_back$status[[1]], "open")

  # ...and the alias itself is still unconfirmed, so the two halves cannot
  # disagree in either direction.
  alias_a_after <- DBI::dbGetQuery(con, "SELECT uuid_feature, confirmed_by FROM feature_alias WHERE uuid = ?",
                                    params = list(alias_a$uuid[[1]]))
  expect_true(is.na(alias_a_after$uuid_feature[[1]]))
  expect_true(is.na(alias_a_after$confirmed_by[[1]]))
})

# ======================================================================
# Robin's ruling 2 (Phase 7b round 3, 2026-07-26): export
# resolve_review(uuid, resolution, resolved_by) - the operator API for
# closing ANY review kind. Before this function existed, NOTHING could close
# a `sample_collision` review row: review_queue_close() is unexported and
# its one production call site hard-filters to kind = "unknown_feature", and
# review_queue()/review_queue_candidates() are read-only (Tier-3 finding A4).
# ======================================================================

test_that("Ruling 2: resolve_review() closes a sample_collision review row - a kind review_queue_close()'s one production call site never reaches", {
  dir <- withr::local_tempdir()
  db_path <- seed_db(dir)
  con <- seed_con(db_path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  # A real sample_collision row, shaped exactly like
  # .fa_find_self_collisions()'s own producer (R/feature-alias.R:672-681) -
  # the kind review_queue_close()'s one caller never passes.
  uuid_collision <- review_queue_add(
    con, kind = "sample_collision", subkind = "same_alias",
    work_order = "XX1234567", source_hash = "h-collision",
    uuid_alias = "fa-collision-0001", uuid_target = "fa-collision-0001",
    diagnostics = list(
      uuid_feature = "f-0001", collision_date = "2025-01-01",
      uuid_sample_a = "s-a", uuid_sample_b = "s-b"
    )
  )

  before_log <- DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM change_log")$n

  result <- resolve_review(
    uuid_collision, resolution = "reviewed - accepted field duplicate",
    resolved_by = "robin", db = db_path
  )
  expect_true(isTRUE(result))

  row <- DBI::dbGetQuery(
    con, "SELECT status, resolution, resolved_by, resolved_at FROM review_queue WHERE uuid = ?",
    params = list(uuid_collision)
  )
  expect_identical(row$status[[1]], "resolved")
  expect_identical(row$resolution[[1]], "reviewed - accepted field duplicate")
  expect_identical(row$resolved_by[[1]], "robin")
  expect_false(is.na(row$resolved_at[[1]]))

  # change_log provenance, with actor = resolved_by (not "pipeline").
  after_log <- DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM change_log")$n
  expect_gt(after_log, before_log)
  actor_rows <- DBI::dbGetQuery(
    con,
    "SELECT DISTINCT actor FROM change_log WHERE tbl = 'review_queue' AND uuid_row = ? AND action = 'update'",
    params = list(uuid_collision)
  )$actor
  expect_true(length(actor_rows) > 0)
  expect_true(all(actor_rows == "robin"))
})

test_that("resolve_review(): idempotent - resolving an already-resolved (or nonexistent) uuid closes nothing, returns FALSE, and does not error", {
  dir <- withr::local_tempdir()
  db_path <- seed_db(dir)
  con <- seed_con(db_path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  uuid_x <- review_queue_add(con, kind = "value_conflict", work_order = "XX1234567",
                              source_hash = "h-idem", payload = "x")

  first <- resolve_review(uuid_x, resolution = "confirmed", resolved_by = "robin", db = db_path)
  expect_true(isTRUE(first))

  second <- expect_no_error(
    resolve_review(uuid_x, resolution = "confirmed", resolved_by = "robin", db = db_path)
  )
  expect_false(isTRUE(second))

  # A nonexistent uuid behaves identically - no error, FALSE.
  third <- expect_no_error(
    resolve_review("no-such-uuid-anywhere", resolution = "confirmed", resolved_by = "robin", db = db_path)
  )
  expect_false(isTRUE(third))
})
