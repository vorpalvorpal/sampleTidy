# PLAN-16 (dev/plans/PLAN-16-review-queue-structured-payload.md) -
# dev/migrations/006-review-queue-payload.R (R-16.12, R-16.13 ONLY).
#
# TARGET FILE CONTRACT (the target file is TDD-red/unwritten; naming follows
# the house convention test-migration-NNN.R <-> dev/migrations/NNN-*.R
# established by 001/002/003/004. PLAN-16's own DDL is "schema version 6"
# per plan block B-16.ddl, so the script is numbered 006 by the same
# convention - this exact FILE NAME is this unit's own inference (the plan
# text never states it literally); flagged in the dispatch report rather
# than assumed silently):
#
#   mig006_run(db, snapshot_dir, dry_run = FALSE, .now = NULL)
#     -> invisible(list(status = "migrated" | "already_migrated" | "dry_run",
#        ...))
#     The DATA half of PLAN-16's migration (block B-16.migration): converts
#     every legacy-shaped review_queue.payload row into the version-6 shape -
#       - format (b) `asset_content_unverified` rows: `state` -> the
#         constant `subkind = 'hash_mismatch'`; `uuid_asset` -> the real
#         `uuid_existing` column; `filename` KEPT as the sole remaining JSON
#         remainder key (RULING-D exception: an audit snapshot, not a
#         duplicated live pointer).
#       - format (a) k=v rows: the `subkind=`/`work_order=` keys promote to
#         the real `subkind`/`work_order` columns; the unkeyed positional
#         prefix becomes a JSON `source_ref` array; a `candidates=` pipe-list
#         becomes one `review_queue_candidate` row per candidate, FK'd at
#         `feature`.
#     Snapshot-first, one-way, per the standing DB-changing-session rule
#     (out of THIS unit's scope to test - covered by whichever unit owns the
#     backup/verify contract, mirroring mig001_backup()/mig001_verify()).
#
# SCOPE: this file covers ONLY R-16.12 and R-16.13, the two data-migration
# criteria. R-16.1-11 and R-16.14-21 (schema DDL, the write API, the read
# side, dedicated round-trip/format criteria) belong to other Phase-4 units
# and are NOT exercised here.
#
# FIXTURE, NEVER THE LIVE DB (standing constraint): a fresh/temp DuckDB,
# built locally in this file only - the shared helper-migration-db.R /
# helper-migration-003-db.R files are NOT edited (brief instruction), since
# neither hosts a `review_queue`/`asset` shape at all.
#
# The fixture pre-applies the version-6 DDL EXACTLY as pinned by block
# B-16.ddl (new review_queue columns + the review_queue_candidate table) and
# records schema_version 6 as already-applied (`ensure_schema()`'s own
# `.st_schema_migrations` ladder in R/db-schema.R has no version-6 entry yet
# as of Phase 4 - that DDL landing is a DIFFERENT unit's job, R-16.1's own).
# So `mig006_run()`'s job under test here is purely the DATA conversion,
# never the DDL - and if it also calls `ensure_schema(con)` defensively, the
# schema_version row already present makes that call a correct no-op against
# this fixture rather than a duplicate-column error.
#
# Every test sources the target file inside its own `test_that()` (never at
# file top level, mirroring test-migration-003.R/004.R), so a missing/broken
# target file surfaces as an ordinary per-test failure, not a whole-file
# collection error that would silently zero out every other test's coverage.

.mig006_load <- function() {
  env <- new.env(parent = globalenv())
  path <- testthat::test_path("..", "..", "dev", "migrations", "006-review-queue-payload.R")
  if (!file.exists(path)) {
    # A clean, single, named ERROR (never `testthat::fail()`, which records a
    # failure but does not halt execution, so the very next line's
    # `sys.source()` would throw a SECOND, redundant condition for the same
    # missing-file cause) - the correct TDD-red state, mirroring
    # `.mig003_load()` / `.mig004_load()` exactly.
    stop(sprintf("migration file not found (expected TDD-red until Phase 6): %s", path))
  }
  sys.source(path, envir = env)
  env
}

# ---- local, throwaway fixture schema (NOT shared - see header) -----------

.rq006_feature_ddl <- "
  CREATE TABLE feature (
    uuid VARCHAR PRIMARY KEY,
    name VARCHAR,
    lon DOUBLE NOT NULL,
    lat DOUBLE NOT NULL
  )"

# Minimal, empty corpus tables (Phase-7b audit, FC10) - `.mig006_backup_counts()`
# now COUNTs `analysis`/`sample` too (not just `review_queue`/
# `review_queue_candidate`), so this throwaway fixture needs them to exist,
# even empty, for `mig006_backup()`'s verify step to run at all. No column
# beyond `uuid` is needed - nothing in this unit reads their content.
.rq006_analysis_ddl <- "CREATE TABLE analysis (uuid VARCHAR PRIMARY KEY)"
.rq006_sample_ddl <- "CREATE TABLE \"sample\" (uuid VARCHAR PRIMARY KEY)"

# Same columns as helper-corpus.R's own `asset` DDL (uuid PK + filename) -
# the only two fields R-16.12's `uuid_existing`/JSON-remainder pairing needs
# to exist and be resolvable against.
.rq006_asset_ddl <- "
  CREATE TABLE asset (
    uuid VARCHAR PRIMARY KEY,
    name VARCHAR,
    date TIMESTAMP,
    file_format VARCHAR,
    type VARCHAR,
    purpose VARCHAR,
    organisation VARCHAR,
    person VARCHAR,
    uuid_project VARCHAR,
    uuid_feature VARCHAR,
    filename VARCHAR,
    hash VARCHAR,
    comments VARCHAR
  )"

# Block B-16.ddl, copied EXACTLY (schema version 6) - applied directly to
# this fixture rather than through `ensure_schema()`, whose
# `.st_schema_migrations` ladder does not carry a version-6 entry in
# R/db-schema.R as of Phase 4 (that landing is R-16.1's own unit, out of
# scope here). Split into individual statements - DuckDB's DBI driver
# executes one statement per `dbExecute()` call.
.rq006_v6_ddl <- c(
  "ALTER TABLE review_queue ADD COLUMN subkind VARCHAR",
  "ALTER TABLE review_queue ADD COLUMN uuid_existing VARCHAR",
  "ALTER TABLE review_queue ADD COLUMN uuid_alias VARCHAR",
  "CREATE TABLE IF NOT EXISTS review_queue_candidate (
    uuid          VARCHAR NOT NULL PRIMARY KEY,
    uuid_review   VARCHAR NOT NULL REFERENCES review_queue(uuid),
    uuid_feature  VARCHAR NOT NULL REFERENCES feature(uuid),
    kind          VARCHAR NOT NULL,
    date_start    DATE,
    date_end      DATE,
    rank          INTEGER NOT NULL
  )"
)

# ---- R-16.12 fixture: 5 distinguishable asset_content_unverified rows ----
# Deliberately SCRAMBLED: the review-row uuid order (b1..b5) does not track
# alphabetical filename order (AAA=b2, CCC=b4, MMM=b1, QQQ=b5, ZZZ=b3), and
# it does not track asset-uuid order either. A migration that pairs rows
# POSITIONALLY, or by re-sorting on filename/asset-uuid, rather than reading
# each row's OWN `uuid_asset` value out of ITS OWN payload, produces a
# provably wrong (uuid_existing, filename) pairing on this fixture -
# Phase-5 audit protocol's fixture-reachability requirement, made concrete.
.rq006_asset_fixture <- data.frame(
  uuid_review = sprintf("rq-b%d", 1:5),
  uuid_asset  = sprintf("asset-b%d", 1:5),
  filename = c(
    "MMM_middle_COC.pdf",
    "AAA_alpha_LabReport.pdf",
    "ZZZ_omega_Chain.pdf",
    "CCC_charlie_Field.pdf",
    "QQQ_quebec_QAQC.pdf"
  ),
  stringsAsFactors = FALSE
)

# ---- R-16.13 fixture: the real legacy k=v grammar (evidence file §3) -----
# rq-a1: unknown_analyte, no subkind, no candidates (the "1/4" fractions -
#   analyte_raw, org - land here). rq-a2/a3/a4: unknown_feature, each with
#   `subkind=ambiguous` and a `candidates=` pipe-list - 2+1+1 = 4 distinct
#   candidate uuids total, max fan-out 2, matching the live evidence exactly
#   (evidence file §3-4). Every `source_ref` is length >= 2, so no vector
#   ever collapses to a length-1 ambiguity under an auto-unboxing JSON
#   writer. `work_order` is intentionally DUPLICATED between the
#   `review_queue_add()` argument and the payload's own `work_order=` key -
#   the live shape (evidence file §3: "work_order is duplicated here").
.rq006_kv_rows <- list(
  list(
    uuid = "rq-a1", kind = "unknown_analyte", work_order = "ES1000001",
    subkind = NULL, candidates = NULL,
    source_ref = c("r1c1", "r2c1"),
    payload = "r1c1,r2c1,analyte_raw=Sodium Adsorption Ratio,work_order=ES1000001,n_rows=2,org=ALS",
    # MC3 (Phase-7b audit): the exact key SET the migrated remainder must
    # have - not merely "still has source_ref" - so a mutation that leaves
    # the duplicated `work_order=` text in the remainder (instead of
    # excluding it) is caught.
    remainder_keys = c("source_ref", "analyte_raw", "n_rows", "org")
  ),
  list(
    uuid = "rq-a2", kind = "unknown_feature", work_order = "ES2616703",
    subkind = "ambiguous", candidates = c("feat-1", "feat-2"),
    source_ref = c("r10c11", "r12c11", "r55c11"),
    payload = "r10c11,r12c11,r55c11,feature_raw=K.E02,work_order=ES2616703,n_rows=27,subkind=ambiguous,candidates=feat-1|feat-2",
    remainder_keys = c("source_ref", "feature_raw", "n_rows")
  ),
  list(
    uuid = "rq-a3", kind = "unknown_feature", work_order = "ES2700001",
    subkind = "ambiguous", candidates = c("feat-3"),
    source_ref = c("r20c5", "r21c5"),
    payload = "r20c5,r21c5,feature_raw=B.S09,work_order=ES2700001,n_rows=1,subkind=ambiguous,candidates=feat-3",
    remainder_keys = c("source_ref", "feature_raw", "n_rows")
  ),
  list(
    uuid = "rq-a4", kind = "unknown_feature", work_order = "ES2800002",
    subkind = "ambiguous", candidates = c("feat-4"),
    source_ref = c("r30c2", "r31c2"),
    payload = "r30c2,r31c2,feature_raw=T.OLD1,work_order=ES2800002,n_rows=3,subkind=ambiguous,candidates=feat-4",
    remainder_keys = c("source_ref", "feature_raw", "n_rows")
  )
)

.rq006_kv_uuids <- vapply(.rq006_kv_rows, function(r) r$uuid, character(1))

#' Create a throwaway, POST-v6-DDL/PRE-data-migration DuckDB seeded with
#' this unit's two legacy-payload fixtures.
#'
#' @param dir directory to hold the DB file (defaults to a fresh withr temp
#'   dir scoped to the CALLING TEST - language-footguns.md's R section: the
#'   caller's frame is threaded through explicitly so cleanup does not fire
#'   before the calling test's own assertions run).
#' @return path to the seeded, closed DuckDB file.
seed_migration_006_db <- function(dir = NULL) {
  if (is.null(dir)) dir <- withr::local_tempdir(.local_envir = parent.frame())
  path <- file.path(dir, "migration-006-seed.duckdb")
  con <- DBI::dbConnect(duckdb::duckdb(), path, read_only = FALSE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  # feature/asset created BEFORE ensure_schema. Historical note, corrected by
  # the Phase-7b audit (FA8): earlier revisions of this comment claimed v6's
  # `review_queue_candidate.uuid_feature` REFERENCES feature(uuid) as an FK -
  # that FK was REMOVED by the R-16.3 Option-A ruling (there is no database
  # FK on `uuid_feature`, which is exactly why `mig006_convert_kv_rows()`
  # must VERIFY each `candidates=` uuid against `feature` itself, D1). The
  # real reason `feature` must exist before this fixture's rows are written
  # is R-16.13's OWN resolution check: the 4 candidate uuids referenced by
  # `.rq006_kv_rows` below must resolve to LIVE `feature` rows for the
  # migration to accept them, so those rows are inserted first. `asset` is
  # here for the same reason (R-16.12's `uuid_asset` resolution check).
  # ensure_schema does not create feature/asset itself (corpus tables, not
  # part of the ops schema).
  DBI::dbExecute(con, .rq006_feature_ddl)
  DBI::dbExecute(con, .rq006_asset_ddl)
  DBI::dbExecute(con, .rq006_analysis_ddl)
  DBI::dbExecute(con, .rq006_sample_ddl)

  # review_queue + ops schema, from the REAL production function. Applies
  # schema_version 1-4 today; 1-6 once R-16.1's v6 DDL lands in Phase 6.
  ensure_schema(con)

  # Apply the v6 DDL + its schema_version marker ONLY if ensure_schema has not
  # already applied version 6 - idempotent across the Phase-4 -> Phase-6
  # transition. Pre-v6: ensure_schema stops at 4, so we hand-apply the exact
  # B-16.ddl statements (the fixture's whole point: a post-DDL/pre-data DB).
  # Post-v6: this is a no-op, avoiding the non-idempotent ADD COLUMN error and
  # a duplicate schema_version row.
  applied <- DBI::dbGetQuery(con, "SELECT version FROM schema_version")$version
  if (!(6L %in% applied)) {
    for (stmt in .rq006_v6_ddl) DBI::dbExecute(con, stmt)
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (6, CURRENT_TIMESTAMP)")
  }

  # 4 distinct features - resolving the 4 distinct candidate uuids referenced
  # by the k=v fixture below (evidence file §4: "all 4 resolve to live
  # feature rows").
  DBI::dbExecute(con, "INSERT INTO feature (uuid, name, lon, lat) VALUES
    ('feat-1', 'T.F01', 150.9001, -33.9001),
    ('feat-2', 'T.F02', 150.9002, -33.9002),
    ('feat-3', 'T.F03', 150.9003, -33.9003),
    ('feat-4', 'T.F04', 150.9004, -33.9004)")

  # ---- R-16.12 fixture rows -------------------------------------------
  for (i in seq_len(nrow(.rq006_asset_fixture))) {
    r <- .rq006_asset_fixture[i, ]
    DBI::dbExecute(
      con, "INSERT INTO asset (uuid, name, filename) VALUES (?, ?, ?)",
      params = list(r$uuid_asset, r$uuid_asset, r$filename)
    )
    # Hand-rolled JSON via sprintf, unescaped - the EXACT live shape
    # (evidence file §1/scratchpad/f18_apply.R:86), including the one
    # constant `state` string every one of the 92 live rows carries.
    payload <- sprintf(
      '{"uuid_asset":"%s","filename":"%s","state":"file present but bytes do not match the stored xxHash128"}',
      r$uuid_asset, r$filename
    )
    review_queue_add(con, kind = "asset_content_unverified", payload = payload, uuid = r$uuid_review)
  }

  # ---- R-16.13 fixture rows -------------------------------------------
  # Real production write path (review_queue_add(), R/db-schema.R) - a real
  # seam, not a hand-built row, even though the migration itself is what is
  # under test.
  for (row in .rq006_kv_rows) {
    review_queue_add(
      con, kind = row$kind, work_order = row$work_order,
      payload = row$payload, uuid = row$uuid
    )
  }

  path
}

# ---- Phase-7b audit (slice C) remediation test helpers --------------------
# Small, direct-SQL mutators for planting exactly one grammar violation on an
# already-seeded fixture DB, and read-only assertions for "did the whole
# transaction actually roll back". None of these go through the mutation
# layer - they exist to corrupt a row the way a hand-rolled legacy write
# could have, not to exercise db_update()/db_append() themselves.

.mig006_update_payload <- function(path, uuid, payload) {
  con <- DBI::dbConnect(duckdb::duckdb(), path, read_only = FALSE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbExecute(con, "UPDATE review_queue SET payload = ? WHERE uuid = ?", params = list(payload, uuid))
}

.mig006_update_work_order <- function(path, uuid, work_order) {
  con <- DBI::dbConnect(duckdb::duckdb(), path, read_only = FALSE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbExecute(con, "UPDATE review_queue SET work_order = ? WHERE uuid = ?", params = list(work_order, uuid))
}

.mig006_marker_present <- function(path) {
  con <- DBI::dbConnect(duckdb::duckdb(), path, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  nrow(DBI::dbGetQuery(con, "SELECT 1 AS x FROM schema_version WHERE version = 1006")) > 0
}

.mig006_all_unmigrated <- function(path) {
  con <- DBI::dbConnect(duckdb::duckdb(), path, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  all(is.na(DBI::dbGetQuery(con, "SELECT subkind FROM review_queue")$subkind))
}

# =============================================================================
# R-16.12: the asset_content_unverified rows convert with no information loss
# =============================================================================

test_that("R-16.12: asset_content_unverified rows convert row-by-row with no uuid<->filename mis-join and no un-promoted payload key", {
  mig <- .mig006_load()
  path <- seed_migration_006_db()

  con0 <- DBI::dbConnect(duckdb::duckdb(), path, read_only = FALSE)
  before <- DBI::dbGetQuery(
    con0,
    "SELECT uuid, payload, subkind, uuid_existing FROM review_queue
      WHERE kind = 'asset_content_unverified' ORDER BY uuid"
  )
  DBI::dbDisconnect(con0, shutdown = TRUE)

  # Positive control (Phase-5 audit protocol §2, fixture reachability): the
  # fixture genuinely starts un-migrated - none of the new columns are
  # populated and every payload is still hand-rolled JSON - so the
  # post-migration assertions below are falsifiable, not vacuously true.
  expect_equal(nrow(before), nrow(.rq006_asset_fixture))
  expect_true(all(is.na(before$subkind)))
  expect_true(all(is.na(before$uuid_existing)))

  snap_dir <- withr::local_tempdir()
  mig$mig006_run(db = path, snapshot_dir = snap_dir, dry_run = FALSE, expect_asset = 5, expect_kv = 4)

  con <- DBI::dbConnect(duckdb::duckdb(), path, read_only = FALSE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  after <- DBI::dbGetQuery(
    con,
    "SELECT uuid, subkind, uuid_existing, payload FROM review_queue
      WHERE kind = 'asset_content_unverified' ORDER BY uuid"
  )

  # Row count preserved EXACTLY - derived from the fixture's own row count,
  # never a bare literal disconnected from what was actually seeded.
  expect_equal(nrow(after), nrow(.rq006_asset_fixture))

  # ROW BY ROW, keyed by the row's OWN uuid (never by position or by a
  # re-sort) - the failure mode this criterion exists to catch is a mis-JOIN
  # that preserves every value and every count while destroying the
  # association between them.
  for (i in seq_len(nrow(.rq006_asset_fixture))) {
    expected <- .rq006_asset_fixture[i, ]
    got <- after[after$uuid == expected$uuid_review, ]
    expect_equal(nrow(got), 1L)
    expect_identical(got$subkind, "hash_mismatch")
    expect_identical(got$uuid_existing, expected$uuid_asset)

    remainder <- jsonlite::fromJSON(got$payload)
    # No un-promoted payload key survives: `state` and `uuid_asset` are both
    # promoted to real columns, leaving `filename` as the ONLY remainder key.
    expect_identical(names(remainder), "filename")
    expect_identical(unname(remainder[["filename"]]), expected$filename)
  }

  # uuid_existing resolves to a LIVE asset row, for every migrated row -
  # asserted as an independent join, not merely "the column is non-NA".
  resolved_n <- DBI::dbGetQuery(con, "
    SELECT COUNT(*) AS n FROM review_queue rq
    JOIN asset a ON a.uuid = rq.uuid_existing
    WHERE rq.kind = 'asset_content_unverified'")$n
  expect_equal(resolved_n, nrow(.rq006_asset_fixture))
})

# =============================================================================
# R-16.13: the 4 legacy k=v rows migrate to columns and child rows
# =============================================================================

test_that("R-16.13: the 4 legacy k=v rows keep subkind, work_order and the source_ref list, and no migrated payload keeps a bare '=' outside JSON", {
  mig <- .mig006_load()
  path <- seed_migration_006_db()

  in_clause <- paste(sprintf("'%s'", .rq006_kv_uuids), collapse = ", ")

  con0 <- DBI::dbConnect(duckdb::duckdb(), path, read_only = FALSE)
  before <- DBI::dbGetQuery(con0, sprintf(
    "SELECT uuid, payload, work_order, subkind FROM review_queue WHERE uuid IN (%s) ORDER BY uuid",
    in_clause
  ))
  DBI::dbDisconnect(con0, shutdown = TRUE)

  # Positive control: pre-migration every one of the 4 rows still carries a
  # literal '=' in its raw payload (the legacy grammar this criterion exists
  # to eliminate), and none has the new `subkind` column populated yet.
  expect_equal(nrow(before), length(.rq006_kv_rows))
  expect_true(all(grepl("=", before$payload, fixed = TRUE)))
  expect_true(all(is.na(before$subkind)))

  snap_dir <- withr::local_tempdir()
  mig$mig006_run(db = path, snapshot_dir = snap_dir, dry_run = FALSE, expect_asset = 5, expect_kv = 4)

  con <- DBI::dbConnect(duckdb::duckdb(), path, read_only = FALSE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  after <- DBI::dbGetQuery(con, sprintf(
    "SELECT uuid, payload, work_order, subkind FROM review_queue WHERE uuid IN (%s) ORDER BY uuid",
    in_clause
  ))

  expect_equal(nrow(after), length(.rq006_kv_rows))

  # No legacy payload still contains '=' outside JSON. This fixture plants no
  # legitimate '=' inside any JSON string VALUE, so a plain substring check
  # on the migrated text is exact here, not an approximation.
  expect_false(any(grepl("=", after$payload, fixed = TRUE)))
  # And every remainder is actually valid, parseable JSON - never merely
  # "'='-free text" that happens to fool the grepl check above.
  parsed_ok <- vapply(after$payload, function(p) {
    !inherits(try(jsonlite::fromJSON(p), silent = TRUE), "try-error")
  }, logical(1))
  expect_true(all(parsed_ok))

  for (row in .rq006_kv_rows) {
    got <- after[after$uuid == row$uuid, ]
    expect_equal(nrow(got), 1L)

    # subkind: RULING A's translation rules. rq-a1 never carried a subkind
    # clause at all (rule 3: is.na()); the other three carry the one value
    # they had (rule 1's "identical" form, since there is no paired
    # "asserts absence of the other" half here to collapse against).
    if (is.null(row$subkind)) {
      expect_true(is.na(got$subkind))
    } else {
      expect_identical(got$subkind, row$subkind)
    }

    # work_order SURVIVES - it was ALREADY a real review_queue column
    # pre-migration (and duplicated in the payload text too, the live
    # shape); the migration must not clobber or blank it.
    expect_identical(got$work_order, row$work_order)

    remainder <- jsonlite::fromJSON(got$payload)
    expect_identical(remainder$source_ref, row$source_ref)

    # MC3 (Phase-7b audit mutation spec): the migrated remainder's key SET
    # must be EXACTLY the expected one - not merely "still contains
    # source_ref" - so a mutation that leaves the duplicated `work_order=`
    # text in the remainder (instead of excluding it, per the excluded-key
    # set at `.mig006_parse_kv_payload()`) is caught here rather than
    # surviving with 0 failures.
    expect_setequal(names(remainder), row$remainder_keys)
  }
})

test_that("R-16.13: the 3 candidates= rows yield exactly 4 distinct review_queue_candidate rows, each uuid_feature resolving to a live feature", {
  mig <- .mig006_load()
  path <- seed_migration_006_db()

  snap_dir <- withr::local_tempdir()
  mig$mig006_run(db = path, snapshot_dir = snap_dir, dry_run = FALSE, expect_asset = 5, expect_kv = 4)

  con <- DBI::dbConnect(duckdb::duckdb(), path, read_only = FALSE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  cand <- DBI::dbGetQuery(con, "SELECT * FROM review_queue_candidate ORDER BY uuid_review, rank")

  # Total: 4 DISTINCT candidate uuids across the 3 candidates= rows (max
  # fan-out 2, per the live evidence) - checked in aggregate here, and then
  # per-row below so a migration that gets the total right by accident
  # (e.g. attaching all 4 candidates to the wrong source row) is still caught.
  expect_equal(nrow(cand), 4L)
  expect_equal(length(unique(cand$uuid_feature)), 4L)

  candidate_rows <- Filter(function(r) !is.null(r$candidates), .rq006_kv_rows)
  expect_equal(length(candidate_rows), 3L) # positive control: fixture shape

  for (row in candidate_rows) {
    got <- cand[cand$uuid_review == row$uuid, ]
    expect_equal(nrow(got), length(row$candidates))
    expect_true(setequal(got$uuid_feature, row$candidates))
  }

  # Every uuid_feature resolves to a LIVE feature row - an independent join,
  # not merely "the column is populated".
  resolved_n <- DBI::dbGetQuery(con, "
    SELECT COUNT(*) AS n FROM review_queue_candidate c
    JOIN feature f ON f.uuid = c.uuid_feature")$n
  expect_equal(resolved_n, 4L)
})

# =============================================================================
# Phase-7b audit (slice C) remediation - FC11: every non-happy branch, plus
# one block per refusal gate (D1/FC1, FC2, FC3, FC4, FC6, FC8, FC9, FC10,
# FC12), each asserting the abort message NAMES the offending row.
# =============================================================================

test_that("FC11: dry_run leaves the DB byte-identical and writes no snapshot", {
  mig <- .mig006_load()
  path <- seed_migration_006_db()
  before_hash <- unname(tools::md5sum(path))

  snap_dir <- withr::local_tempdir()
  result <- mig$mig006_run(db = path, snapshot_dir = snap_dir, dry_run = TRUE)

  expect_equal(result$status, "dry_run")
  expect_equal(result$n_asset, nrow(.rq006_asset_fixture))
  expect_equal(result$n_kv, length(.rq006_kv_rows))
  expect_equal(unname(tools::md5sum(path)), before_hash)
  expect_equal(length(list.files(snap_dir)), 0L)
  expect_false(.mig006_marker_present(path))
})

test_that("FC11: a second run returns already_migrated and converts nothing", {
  mig <- .mig006_load()
  path <- seed_migration_006_db()
  snap_dir <- withr::local_tempdir()

  first <- mig$mig006_run(db = path, snapshot_dir = snap_dir, dry_run = FALSE, expect_asset = 5, expect_kv = 4)
  expect_equal(first$status, "migrated")

  before_hash <- unname(tools::md5sum(path))
  second <- mig$mig006_run(db = path, snapshot_dir = snap_dir, dry_run = FALSE, expect_asset = 5, expect_kv = 4)

  expect_equal(second$status, "already_migrated")
  expect_true(is.na(second$n_asset))
  expect_true(is.na(second$n_kv))
  expect_equal(unname(tools::md5sum(path)), before_hash)
})

test_that("FC11/MC4: a dangling candidates= uuid rolls back everything and writes no marker", {
  mig <- .mig006_load()
  path <- seed_migration_006_db()
  .mig006_update_payload(
    path, "rq-a3",
    "r20c5,r21c5,feature_raw=B.S09,work_order=ES2700001,n_rows=1,subkind=ambiguous,candidates=feat-does-not-exist"
  )

  snap_dir <- withr::local_tempdir()
  expect_error(
    mig$mig006_run(db = path, snapshot_dir = snap_dir, dry_run = FALSE, expect_asset = 5, expect_kv = 4),
    regexp = "feat-does-not-exist"
  )
  expect_true(.mig006_all_unmigrated(path))
  expect_false(.mig006_marker_present(path))

  con <- DBI::dbConnect(duckdb::duckdb(), path, read_only = TRUE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  expect_equal(nrow(DBI::dbGetQuery(con, "SELECT * FROM review_queue_candidate")), 0L)
})

test_that("FC11: a missing snapshot_dir aborts before any write", {
  mig <- .mig006_load()
  path <- seed_migration_006_db()
  missing_dir <- file.path(withr::local_tempdir(), "does-not-exist")
  before_hash <- unname(tools::md5sum(path))

  expect_error(
    mig$mig006_run(db = path, snapshot_dir = missing_dir, dry_run = FALSE, expect_asset = 5, expect_kv = 4)
  )
  expect_equal(unname(tools::md5sum(path)), before_hash)
  expect_false(.mig006_marker_present(path))
})

test_that("D1/FC1: an unescaped comma inside a k=v value aborts naming the row, never guesses", {
  mig <- .mig006_load()
  path <- seed_migration_006_db()
  # The FC1 reproduction: a comma-bearing analyte_raw value forges an unkeyed
  # token AFTER the first k=v token - the live grammar always emits the
  # unkeyed source_ref prefix first, so this shape catches every corruption
  # case the audit could construct.
  .mig006_update_payload(
    path, "rq-a1",
    "r1c1,r2c1,analyte_raw=1,2-Dichloroethane,work_order=ES1000001,n_rows=2,org=ALS"
  )

  snap_dir <- withr::local_tempdir()
  expect_error(
    mig$mig006_run(db = path, snapshot_dir = snap_dir, dry_run = FALSE, expect_asset = 5, expect_kv = 4),
    regexp = "rq-a1"
  )
  # Whole transaction rolled back, not just the offending row - the asset
  # rows (converted BEFORE the kv rows, inside the same db_transaction())
  # are unmigrated too, and no marker was written.
  expect_true(.mig006_all_unmigrated(path))
  expect_false(.mig006_marker_present(path))
})

test_that("D1/FC4: a repeated key aborts naming the row", {
  mig <- .mig006_load()
  path <- seed_migration_006_db()
  .mig006_update_payload(
    path, "rq-a2",
    "r10c11,feature_raw=first,feature_raw=second,work_order=ES2616703,subkind=ambiguous,candidates=feat-1"
  )

  snap_dir <- withr::local_tempdir()
  expect_error(
    mig$mig006_run(db = path, snapshot_dir = snap_dir, dry_run = FALSE, expect_asset = 5, expect_kv = 4),
    regexp = "rq-a2"
  )
  expect_false(.mig006_marker_present(path))
})

test_that("D1/FC8: a key outside the known vocabulary aborts naming the row", {
  mig <- .mig006_load()
  path <- seed_migration_006_db()
  .mig006_update_payload(path, "rq-a1", "r1c1,r2c1,totally_new_key=zzz,work_order=ES1000001")

  snap_dir <- withr::local_tempdir()
  expect_error(
    mig$mig006_run(db = path, snapshot_dir = snap_dir, dry_run = FALSE, expect_asset = 5, expect_kv = 4),
    regexp = "rq-a1"
  )
  expect_false(.mig006_marker_present(path))
})

test_that("D1/FC12: an empty candidates= value aborts naming the row, never vanishes silently", {
  mig <- .mig006_load()
  path <- seed_migration_006_db()
  .mig006_update_payload(path, "rq-a2", "r10c11,subkind=ambiguous,candidates=,work_order=ES2616703")

  snap_dir <- withr::local_tempdir()
  expect_error(
    mig$mig006_run(db = path, snapshot_dir = snap_dir, dry_run = FALSE, expect_asset = 5, expect_kv = 4),
    regexp = "rq-a2"
  )
  expect_false(.mig006_marker_present(path))
})

test_that("FC2: a zero-row run against an already-migrated DB refuses to write the marker", {
  mig <- .mig006_load()
  path <- seed_migration_006_db()
  snap_dir <- withr::local_tempdir()

  first <- mig$mig006_run(db = path, snapshot_dir = snap_dir, dry_run = FALSE, expect_asset = 5, expect_kv = 4)
  expect_equal(first$status, "migrated")

  # Wipe the marker by hand (e.g. the marker row was deleted, or the run is
  # pointed at the wrong DB) - the DB itself is now fully converted, so a
  # re-run would convert 0 rows and, pre-fix, would report "migrated" anyway.
  con <- DBI::dbConnect(duckdb::duckdb(), path, read_only = FALSE)
  DBI::dbExecute(con, "DELETE FROM schema_version WHERE version = 1006")
  DBI::dbDisconnect(con, shutdown = TRUE)

  expect_error(
    mig$mig006_run(db = path, snapshot_dir = snap_dir, dry_run = FALSE, expect_asset = 5, expect_kv = 4),
    regexp = "expected 5"
  )
  expect_false(.mig006_marker_present(path))
})

test_that("FC3: a work_order column that disagrees with the payload's work_order= aborts naming the row", {
  mig <- .mig006_load()
  path <- seed_migration_006_db()
  .mig006_update_work_order(path, "rq-a1", "ES_WRONG_COLUMN")

  snap_dir <- withr::local_tempdir()
  expect_error(
    mig$mig006_run(db = path, snapshot_dir = snap_dir, dry_run = FALSE, expect_asset = 5, expect_kv = 4),
    regexp = "rq-a1"
  )
  expect_false(.mig006_marker_present(path))
})

test_that("FC5/FC7: an asset payload without exactly the three expected keys aborts naming the row", {
  mig <- .mig006_load()

  # missing filename
  path1 <- seed_migration_006_db()
  .mig006_update_payload(path1, "rq-b1", '{"uuid_asset":"asset-b1","state":"s"}')
  expect_error(
    mig$mig006_run(db = path1, snapshot_dir = withr::local_tempdir(), dry_run = FALSE, expect_asset = 5, expect_kv = 4),
    regexp = "rq-b1"
  )
  expect_false(.mig006_marker_present(path1))

  # a 4th key
  path2 <- seed_migration_006_db()
  .mig006_update_payload(
    path2, "rq-b2",
    '{"uuid_asset":"asset-b2","filename":"AAA_alpha_LabReport.pdf","state":"s","detected_hash":"h"}'
  )
  expect_error(
    mig$mig006_run(db = path2, snapshot_dir = withr::local_tempdir(), dry_run = FALSE, expect_asset = 5, expect_kv = 4),
    regexp = "rq-b2"
  )
  expect_false(.mig006_marker_present(path2))
})

test_that("FC6: a NULL payload aborts naming the row, in both dry_run and the real run", {
  mig <- .mig006_load()
  path <- seed_migration_006_db()
  .mig006_update_payload(path, "rq-a1", NA_character_)

  snap_dir <- withr::local_tempdir()
  expect_error(
    mig$mig006_run(db = path, snapshot_dir = snap_dir, dry_run = TRUE),
    regexp = "rq-a1"
  )
  expect_equal(length(list.files(snap_dir)), 0L)

  expect_error(
    mig$mig006_run(db = path, snapshot_dir = snap_dir, dry_run = FALSE, expect_asset = 5, expect_kv = 4),
    regexp = "rq-a1"
  )
  expect_false(.mig006_marker_present(path))
})

test_that("FC9: source_ref is always a JSON array, never a bare string or {}", {
  mig <- .mig006_load()
  path <- seed_migration_006_db()

  con <- DBI::dbConnect(duckdb::duckdb(), path, read_only = FALSE)
  # cardinality 0: no unkeyed tokens at all.
  review_queue_add(con, kind = "unknown_feature", payload = "subkind=ambiguous,candidates=feat-1", uuid = "rq-fc9-0")
  # cardinality 1: exactly one unkeyed token - the singleton auto_unbox() was
  # collapsing to a bare JSON string.
  review_queue_add(con, kind = "unknown_feature", payload = "r1c1,subkind=ambiguous,candidates=feat-1", uuid = "rq-fc9-1")
  DBI::dbDisconnect(con, shutdown = TRUE)

  snap_dir <- withr::local_tempdir()
  mig$mig006_run(db = path, snapshot_dir = snap_dir, dry_run = FALSE, expect_asset = 5, expect_kv = 6)

  con2 <- DBI::dbConnect(duckdb::duckdb(), path, read_only = TRUE)
  withr::defer(DBI::dbDisconnect(con2, shutdown = TRUE))
  got0 <- DBI::dbGetQuery(con2, "SELECT payload FROM review_queue WHERE uuid = 'rq-fc9-0'")$payload
  got1 <- DBI::dbGetQuery(con2, "SELECT payload FROM review_queue WHERE uuid = 'rq-fc9-1'")$payload

  # simplifyVector = FALSE is load-bearing here: a JSON ARRAY parses to an R
  # list; a bare JSON STRING parses to a length-1 character vector. Default
  # simplification would hide the exact type distinction FC9 exists to fix.
  parsed0 <- jsonlite::fromJSON(got0, simplifyVector = FALSE)
  parsed1 <- jsonlite::fromJSON(got1, simplifyVector = FALSE)
  expect_true(is.list(parsed0$source_ref))
  expect_equal(length(parsed0$source_ref), 0L)
  expect_true(is.list(parsed1$source_ref))
  expect_equal(length(parsed1$source_ref), 1L)
  expect_identical(parsed1$source_ref[[1]], "r1c1")
})

test_that("FC10: .mig006_backup_counts() detects a lost asset table, not just review_queue counts", {
  mig <- .mig006_load()
  path <- seed_migration_006_db()

  con <- DBI::dbConnect(duckdb::duckdb(), path, read_only = FALSE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  before <- mig$.mig006_backup_counts(con)
  expect_true(all(
    c("asset", "feature", "analysis", "sample", "change_log", "review_queue_digest") %in% names(before)
  ))
  expect_equal(before$asset, nrow(.rq006_asset_fixture))

  DBI::dbExecute(con, "DELETE FROM asset")
  after <- mig$.mig006_backup_counts(con)

  # A backup that lost every asset row must NOT verify identical to the live
  # counts - the pre-fix version compared ONLY review_queue/
  # review_queue_candidate counts, so this exact loss was invisible.
  expect_false(identical(before, after))
  expect_equal(after$asset, 0L)
  expect_identical(before$review_queue, after$review_queue)
})

test_that("MC4: an unresolvable uuid_asset aborts and rolls back everything, naming the row", {
  mig <- .mig006_load()
  path <- seed_migration_006_db()
  .mig006_update_payload(
    path, "rq-b3",
    '{"uuid_asset":"asset-does-not-exist","filename":"ZZZ_omega_Chain.pdf","state":"s"}'
  )

  snap_dir <- withr::local_tempdir()
  expect_error(
    mig$mig006_run(db = path, snapshot_dir = snap_dir, dry_run = FALSE, expect_asset = 5, expect_kv = 4),
    regexp = "asset-does-not-exist"
  )
  expect_true(.mig006_all_unmigrated(path))
  expect_false(.mig006_marker_present(path))
})
