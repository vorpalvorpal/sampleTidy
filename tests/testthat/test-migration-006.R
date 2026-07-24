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
    payload = "r1c1,r2c1,analyte_raw=Sodium Adsorption Ratio,work_order=ES1000001,n_rows=2,org=ALS"
  ),
  list(
    uuid = "rq-a2", kind = "unknown_feature", work_order = "ES2616703",
    subkind = "ambiguous", candidates = c("feat-1", "feat-2"),
    source_ref = c("r10c11", "r12c11", "r55c11"),
    payload = "r10c11,r12c11,r55c11,feature_raw=K.E02,work_order=ES2616703,n_rows=27,subkind=ambiguous,candidates=feat-1|feat-2"
  ),
  list(
    uuid = "rq-a3", kind = "unknown_feature", work_order = "ES2700001",
    subkind = "ambiguous", candidates = c("feat-3"),
    source_ref = c("r20c5", "r21c5"),
    payload = "r20c5,r21c5,feature_raw=B.S09,work_order=ES2700001,n_rows=1,subkind=ambiguous,candidates=feat-3"
  ),
  list(
    uuid = "rq-a4", kind = "unknown_feature", work_order = "ES2800002",
    subkind = "ambiguous", candidates = c("feat-4"),
    source_ref = c("r30c2", "r31c2"),
    payload = "r30c2,r31c2,feature_raw=T.OLD1,work_order=ES2800002,n_rows=3,subkind=ambiguous,candidates=feat-4"
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

  # feature/asset created BEFORE ensure_schema: once R-16.1's v6 lands in
  # .st_schema_migrations, ensure_schema() applies v6 HERE too, and v6's
  # review_queue_candidate.uuid_feature FK REFERENCES feature(uuid) - so
  # feature must already exist when that DDL runs. ensure_schema does not
  # create feature itself (it is a corpus table, not part of the ops schema).
  DBI::dbExecute(con, .rq006_feature_ddl)
  DBI::dbExecute(con, .rq006_asset_ddl)

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
  mig$mig006_run(db = path, snapshot_dir = snap_dir, dry_run = FALSE)

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
  mig$mig006_run(db = path, snapshot_dir = snap_dir, dry_run = FALSE)

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
  }
})

test_that("R-16.13: the 3 candidates= rows yield exactly 4 distinct review_queue_candidate rows, each uuid_feature resolving to a live feature", {
  mig <- .mig006_load()
  path <- seed_migration_006_db()

  snap_dir <- withr::local_tempdir()
  mig$mig006_run(db = path, snapshot_dir = snap_dir, dry_run = FALSE)

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
