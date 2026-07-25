# Plan 01 - R-1.5 ensure_schema() (ops tables & migrations, A2/A7) and
# R-1.6 state transitions (ingest_file_upsert() / ingest_file_set_state()).

# --- R-1.5 ---------------------------------------------------------------

test_that("R-1.5: ensure_schema() creates all five ops objects on a fresh DB", {
  dir <- withr::local_tempdir()
  db <- file.path(dir, "fresh.duckdb")
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = FALSE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  ensure_schema(con)

  tables <- DBI::dbListTables(con)
  expect_true(all(
    c("ingest_file", "ingest_sighting", "review_queue", "change_log", "schema_version") %in% tables
  ))
})

test_that("R-1.5: schema_version holds every migration version applied", {
  dir <- withr::local_tempdir()
  db <- file.path(dir, "fresh2.duckdb")
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = FALSE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  ensure_schema(con)

  versions <- DBI::dbGetQuery(con, "SELECT version FROM schema_version ORDER BY version")$version
  expect_true(length(versions) >= 1)
  expect_false(anyNA(versions))
  expect_equal(versions, sort(unique(versions)))
})

test_that("R-1.5: calling ensure_schema() twice is a no-op (row counts and versions unchanged, no error)", {
  dir <- withr::local_tempdir()
  db <- file.path(dir, "idempotent.duckdb")
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = FALSE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  ops_tables <- c("ingest_file", "ingest_sighting", "review_queue", "change_log", "schema_version")
  row_counts <- function() {
    vapply(ops_tables, function(t) {
      DBI::dbGetQuery(con, sprintf("SELECT COUNT(*) AS n FROM %s", t))$n
    }, numeric(1))
  }

  ensure_schema(con)
  versions_1 <- DBI::dbGetQuery(con, "SELECT version FROM schema_version ORDER BY version")$version
  counts_1 <- row_counts()

  expect_no_error(ensure_schema(con))

  versions_2 <- DBI::dbGetQuery(con, "SELECT version FROM schema_version ORDER BY version")$version
  counts_2 <- row_counts()

  expect_equal(versions_2, versions_1)
  expect_equal(counts_2, counts_1)
})

test_that("R-1.5: ensure_schema() never drops or narrows existing core-table columns", {
  dir <- withr::local_tempdir()
  db <- seed_db(dir)
  con <- seed_con(db)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  core_tables <- c("feature", "feature_mask", "analyte", "lab_method", "project", "sample", "analysis", "asset")
  fields_before <- lapply(core_tables, function(t) DBI::dbListFields(con, t))
  names(fields_before) <- core_tables

  expect_no_error(ensure_schema(con))

  fields_after <- lapply(core_tables, function(t) DBI::dbListFields(con, t))
  names(fields_after) <- core_tables

  expect_equal(fields_after, fields_before)
})

# --- R-1.6 state transitions ----------------------------------------------
# NOTE: ingest_file_upsert()'s exact argument names beyond `con, hash` are not
# pinned in PLAN-01 (only sketched as `ingest_file_upsert(con, hash, ...)`).
# We take the reading that the current path being observed is passed as
# `path`, stored into `path_first_seen` only on the row's first insert (the
# column name says "first seen" - subsequent upserts with a different path
# must not overwrite it, only add an ingest_sighting row). See
# dev/plans/PLAN-CHANGE-REQUESTS.md.

test_that("R-1.6: a legal state path walks end to end", {
  dir <- withr::local_tempdir()
  db <- seed_db(dir)
  con <- seed_con(db)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  hash <- "walk-hash-01"
  ingest_file_upsert(con, hash, path = "/in/walk.csv", filename = "walk.csv", size = 10)

  path_seq <- c("claimed", "parsed", "assembled", "reconciled", "committed", "archived")
  for (state in path_seq) {
    expect_no_error(ingest_file_set_state(con, hash, state))
  }

  final <- DBI::dbGetQuery(con, "SELECT state FROM ingest_file WHERE hash = ?", params = list(hash))
  expect_equal(final$state, "archived")
})

test_that("R-1.6: an illegal jump (seen -> committed) aborts naming both states", {
  dir <- withr::local_tempdir()
  db <- seed_db(dir)
  con <- seed_con(db)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  hash <- "illegal-hash-01"
  ingest_file_upsert(con, hash, path = "/in/illegal.csv", filename = "illegal.csv", size = 10)
  # a freshly-upserted hash starts life in "seen"

  err <- tryCatch(ingest_file_set_state(con, hash, "committed"), error = function(e) e)
  expect_s3_class(err, "sampletidy_error")
  expect_match(conditionMessage(err), "seen", ignore.case = TRUE)
  expect_match(conditionMessage(err), "committed", ignore.case = TRUE)
})

test_that("R-1.6: any state can transition to failed", {
  dir <- withr::local_tempdir()
  db <- seed_db(dir)
  con <- seed_con(db)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  hash <- "failed-hash-01"
  ingest_file_upsert(con, hash, path = "/in/f.csv", filename = "f.csv", size = 10)
  ingest_file_set_state(con, hash, "claimed")
  ingest_file_set_state(con, hash, "parsed")

  expect_no_error(ingest_file_set_state(con, hash, "failed", reason = "kaboom"))
  row <- DBI::dbGetQuery(con, "SELECT state, state_reason FROM ingest_file WHERE hash = ?", params = list(hash))
  expect_equal(row$state, "failed")
  expect_equal(row$state_reason, "kaboom")
})

test_that("R-1.6: terminal states (e.g. archived) cannot transition further without reset = TRUE", {
  dir <- withr::local_tempdir()
  db <- seed_db(dir)
  con <- seed_con(db)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  hash <- "terminal-hash-01"
  ingest_file_upsert(con, hash, path = "/in/t.csv", filename = "t.csv", size = 10)
  ingest_file_set_state(con, hash, "claimed")
  ingest_file_set_state(con, hash, "ignored")

  err <- tryCatch(ingest_file_set_state(con, hash, "claimed"), error = function(e) e)
  expect_s3_class(err, "sampletidy_error")
})

test_that("R-1.6: upsert on an existing hash updates updated_at, preserves path_first_seen, and appends a sighting only when the path differs", {
  dir <- withr::local_tempdir()
  db <- seed_db(dir)
  con <- seed_con(db)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  hash <- "sighting-hash-01"
  ingest_file_upsert(con, hash, path = "/in/s.csv", filename = "s.csv", size = 10)
  first <- DBI::dbGetQuery(con, "SELECT updated_at, path_first_seen FROM ingest_file WHERE hash = ?", params = list(hash))
  expect_equal(first$path_first_seen, "/in/s.csv")

  Sys.sleep(1.1)
  ingest_file_upsert(con, hash, path = "/in/s.csv", filename = "s.csv", size = 10)
  second <- DBI::dbGetQuery(con, "SELECT updated_at, path_first_seen FROM ingest_file WHERE hash = ?", params = list(hash))
  expect_gt(as.numeric(second$updated_at), as.numeric(first$updated_at))
  expect_equal(second$path_first_seen, "/in/s.csv")

  sightings_same_path <- DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM ingest_sighting WHERE hash = ?", params = list(hash))$n
  expect_equal(sightings_same_path, 0)

  Sys.sleep(1.1)
  ingest_file_upsert(con, hash, path = "/in/other/s.csv", filename = "s.csv", size = 10)
  third <- DBI::dbGetQuery(con, "SELECT path_first_seen FROM ingest_file WHERE hash = ?", params = list(hash))
  expect_equal(third$path_first_seen, "/in/s.csv") # unchanged - it's the FIRST-seen path

  sightings_diff_path <- DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM ingest_sighting WHERE hash = ?", params = list(hash))$n
  expect_equal(sightings_diff_path, 1)
})

# --- R-12.9: ingest_file_upsert() must not clobber on re-sight (F15) -----
# db-schema.R:184-188 unconditionally overwrote filename/size on re-sight,
# so a later caller taking the NA defaults would null a real filename.
# Fix must COALESCE-guard: keep the existing non-NULL value when the new
# one is NA, but still apply a real (non-NA) incoming value.

test_that("R-12.9: re-upsert with filename = NA leaves the stored filename intact (no clobber)", {
  dir <- withr::local_tempdir()
  db <- seed_db(dir)
  con <- seed_con(db)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  hash <- "nofilename-hash-01"
  ingest_file_upsert(con, hash, path = "/in/keep.csv", filename = "keep.csv", size = 10)

  # Re-sight the SAME path, but this caller takes the filename/size defaults
  # (NA) rather than passing them explicitly.
  ingest_file_upsert(con, hash, path = "/in/keep.csv")

  row <- DBI::dbGetQuery(con, "SELECT filename FROM ingest_file WHERE hash = ?", params = list(hash))
  expect_equal(row$filename, "keep.csv")
})

test_that("R-12.9: re-upsert with a real filename updates the stored filename", {
  dir <- withr::local_tempdir()
  db <- seed_db(dir)
  con <- seed_con(db)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  hash <- "renamedfile-hash-01"
  ingest_file_upsert(con, hash, path = "/in/old.csv", filename = "old.csv", size = 10)
  ingest_file_upsert(con, hash, path = "/in/old.csv", filename = "renamed.csv", size = 20)

  row <- DBI::dbGetQuery(con, "SELECT filename, size FROM ingest_file WHERE hash = ?", params = list(hash))
  expect_equal(row$filename, "renamed.csv")
  expect_equal(row$size, 20)
})

test_that("R-12.9: re-upsert with size = NA leaves the stored size intact (no clobber)", {
  dir <- withr::local_tempdir()
  db <- seed_db(dir)
  con <- seed_con(db)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  hash <- "nosize-hash-01"
  ingest_file_upsert(con, hash, path = "/in/sized.csv", filename = "sized.csv", size = 42)

  # Re-sight taking the size default (NA), same path.
  ingest_file_upsert(con, hash, path = "/in/sized.csv", filename = "sized.csv")

  row <- DBI::dbGetQuery(con, "SELECT size FROM ingest_file WHERE hash = ?", params = list(hash))
  expect_equal(row$size, 42)
})

test_that("R-12.9: path_first_seen is still set exactly once across a no-clobber re-upsert sequence (A21 regression)", {
  dir <- withr::local_tempdir()
  db <- seed_db(dir)
  con <- seed_con(db)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  hash <- "firstseen-noclobber-hash-01"
  ingest_file_upsert(con, hash, path = "/in/first.csv", filename = "first.csv", size = 5)
  first <- DBI::dbGetQuery(con, "SELECT path_first_seen FROM ingest_file WHERE hash = ?", params = list(hash))
  expect_equal(first$path_first_seen, "/in/first.csv")

  # Re-sight with filename/size taking their NA defaults, and via a
  # different path (must not touch path_first_seen either way).
  ingest_file_upsert(con, hash, path = "/in/second.csv")

  second <- DBI::dbGetQuery(con, "SELECT path_first_seen FROM ingest_file WHERE hash = ?", params = list(hash))
  expect_equal(second$path_first_seen, "/in/first.csv")

  # A third, explicit-values re-sight must still leave path_first_seen alone.
  ingest_file_upsert(con, hash, path = "/in/third.csv", filename = "third.csv", size = 99)
  third <- DBI::dbGetQuery(con, "SELECT path_first_seen FROM ingest_file WHERE hash = ?", params = list(hash))
  expect_equal(third$path_first_seen, "/in/first.csv")
})

# ---------------------------------------------------------------------------
# PLAN-16 - review_queue structured payload (schema version 6): R-16.1,
# R-16.2, R-16.3, R-16.4, R-16.5, R-16.9.
#
# All six criteria are RED by design against today's code: `review_queue`
# does not yet carry `subkind`/`uuid_existing`/`uuid_alias`, the
# `review_queue_candidate` child table does not exist, and there is no
# version-6 migration in `.st_schema_migrations`. Nothing here stubs
# production code to make any of this pass.
#
# PLAN-16 does not pin review_queue_add()'s exact future argument names for
# the new columns/candidates - only that it and the raw db_append() tibble
# path must produce identical results (R-16.9). This suite fixes the most
# natural extension of the EXISTING signature
# (review_queue_add(con, kind, work_order, source_hash, payload, uuid,
# created_at)): new args `subkind`, `uuid_existing`, `uuid_alias` (mirroring
# the new column names 1:1, matching every other argument's own naming
# convention) and a `candidates` argument taking a character vector of
# feature uuids in the desired rank order. This is a designed-interface
# choice for the Phase-6 implementer to match, flagged in the P16-T-schema
# report - not a plan ambiguity blocking this suite.
# ---------------------------------------------------------------------------

# --- R-16.1: version 6 applies regardless of whether version 5 exists yet --

test_that("R-16.1 arm (a): ensure_schema() applies version 6 to a DB at version 4 with no version 5 defined", {
  ns <- asNamespace("sampleTidy")
  migrations <- get(".st_schema_migrations", envir = ns)
  base_versions <- vapply(migrations, function(m) m$version, integer(1))
  # Sanity check on this arm's premise: no version 5 is defined in the
  # shipped migration list yet (RULING E - PLAN-15 P6 is suspended until
  # PLAN-16 lands). If this ever fails, the fixture assumption below needs
  # revisiting, not a silent pass.
  expect_false(5L %in% base_versions)

  dir <- withr::local_tempdir()
  db <- file.path(dir, "p16-v6.duckdb")
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = FALSE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  ensure_schema(con)

  versions <- DBI::dbGetQuery(con, "SELECT version FROM schema_version ORDER BY version")$version
  expect_true(6L %in% versions)
  expect_false(5L %in% versions)
})

test_that("R-16.1 arm (b): a migration arriving out of version order (5 added after 6 already shipped) applies 5 alone, and 6 is not re-applied", {
  ns <- asNamespace("sampleTidy")
  base_migrations <- get(".st_schema_migrations", envir = ns)
  # Restore the real migration list unconditionally when this test ends,
  # regardless of pass/fail, so no later test in this (or any other, per
  # Phase-5 order-independence) file sees the injected fake version 5.
  withr::defer(assignInNamespace(".st_schema_migrations", base_migrations, ns = "sampleTidy"))

  base_versions <- vapply(base_migrations, function(m) m$version, integer(1))
  expect_true(6L %in% base_versions)
  expect_false(5L %in% base_versions)

  dir <- withr::local_tempdir()
  db <- file.path(dir, "p16-outoforder.duckdb")
  con1 <- DBI::dbConnect(duckdb::duckdb(), db, read_only = FALSE)
  ensure_schema(con1) # applies 1,2,3,4,6 - no version 5 exists yet
  versions_step1 <- DBI::dbGetQuery(con1, "SELECT version FROM schema_version ORDER BY version")$version
  DBI::dbDisconnect(con1, shutdown = TRUE)

  expect_true(6L %in% versions_step1)
  expect_false(5L %in% versions_step1)

  # Simulate version 5 (PLAN-15 P6's uuid_target) arriving LATER, after 6 has
  # already shipped and already been applied to this DB - the out-of-order
  # sequence the criterion is actually about. assignInNamespace() is used
  # (not a plain `.st_schema_migrations <<-`) because devtools::load_all()'s
  # attached search-path copy is a DIFFERENT binding from the one
  # ensure_schema()'s closure actually reads - only assigning into the real
  # package namespace is visible to the function under test.
  v5 <- list(version = 5L, ddl = "CREATE TABLE IF NOT EXISTS p16_v5_probe (uuid VARCHAR)")
  assignInNamespace(".st_schema_migrations", c(base_migrations, list(v5)), ns = "sampleTidy")

  con2 <- DBI::dbConnect(duckdb::duckdb(), db, read_only = FALSE) # re-open
  withr::defer(DBI::dbDisconnect(con2, shutdown = TRUE))
  ensure_schema(con2)
  versions_step2 <- DBI::dbGetQuery(con2, "SELECT version FROM schema_version ORDER BY version")$version

  # 5 applies alone...
  expect_setequal(setdiff(versions_step2, versions_step1), 5L)
  # ...and 6 (already recorded before the injection) is NOT re-applied - no
  # duplicate row for either version.
  expect_equal(sum(versions_step2 == 5L), 1L)
  expect_equal(sum(versions_step2 == 6L), 1L)
})

test_that("R-16.1 arm (c): re-opening an already-migrated DB applies nothing and changes no row", {
  dir <- withr::local_tempdir()
  db <- file.path(dir, "p16-reopen.duckdb")

  con1 <- DBI::dbConnect(duckdb::duckdb(), db, read_only = FALSE)
  ensure_schema(con1)
  before <- DBI::dbGetQuery(con1, "SELECT version, applied_at FROM schema_version ORDER BY version")
  DBI::dbDisconnect(con1, shutdown = TRUE)

  con2 <- DBI::dbConnect(duckdb::duckdb(), db, read_only = FALSE)
  withr::defer(DBI::dbDisconnect(con2, shutdown = TRUE))
  ensure_schema(con2)
  after <- DBI::dbGetQuery(con2, "SELECT version, applied_at FROM schema_version ORDER BY version")

  expect_equal(after$version, before$version)
  expect_equal(after$applied_at, before$applied_at) # no row re-inserted/rewritten
})

# --- R-16.2: subkind/uuid_existing/uuid_alias are real, nullable columns ---

test_that("R-16.2: review_queue carries subkind, uuid_existing, uuid_alias as real, nullable VARCHAR columns", {
  dir <- withr::local_tempdir()
  db <- seed_db(dir)
  con <- seed_con(db)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  cols <- DBI::dbGetQuery(con, "
    SELECT column_name, data_type, is_nullable, column_default
    FROM duckdb_columns()
    WHERE table_name = 'review_queue'
      AND column_name IN ('subkind', 'uuid_existing', 'uuid_alias')
    ORDER BY column_name")

  expect_equal(nrow(cols), 3L)
  expect_true(all(cols$data_type == "VARCHAR"))
  expect_true(all(cols$is_nullable))
  # Not a computed/generated column: a real column has no generation
  # expression standing in as its default.
  expect_true(all(is.na(cols$column_default)))

  # And genuinely nullable in practice, not merely declared so.
  uuid_row <- uuid::UUIDgenerate()
  DBI::dbExecute(con, "
    INSERT INTO review_queue (uuid, created_at, kind, subkind, uuid_existing, uuid_alias)
    VALUES (?, ?, 'value_conflict', NULL, NULL, NULL)",
    params = list(uuid_row, Sys.time()))
  row <- DBI::dbGetQuery(con, "
    SELECT subkind, uuid_existing, uuid_alias FROM review_queue WHERE uuid = ?",
    params = list(uuid_row))
  expect_true(is.na(row$subkind))
  expect_true(is.na(row$uuid_existing))
  expect_true(is.na(row$uuid_alias))
})

# --- R-16.3: review_queue_candidate FKs are enforced, not merely declared --

test_that("R-16.3 review_queue_candidate FK on uuid_review is enforced: a dangling parent uuid errors", {
  dir <- withr::local_tempdir()
  db <- seed_db(dir)
  con <- seed_con(db)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  expect_error(
    DBI::dbExecute(
      con,
      "INSERT INTO review_queue_candidate (uuid, uuid_review, uuid_feature, kind, rank)
       VALUES (?, ?, 'f-0001', 'candidate', 1)",
      params = list(uuid::UUIDgenerate(), uuid::UUIDgenerate()) # uuid_review has no parent row
    ),
    regexp = "Constraint Error|foreign key"
  )
})

test_that("R-16.3 review_queue_candidate.uuid_feature is NOT NULL but carries NO foreign key (Option A, Robin 2026-07-25): a NULL raises, and a dangling-but-present uuid is deliberately ACCEPTED because resolution is a migration guarantee, not a DB constraint", {
  dir <- withr::local_tempdir()
  db <- seed_db(dir)
  con <- seed_con(db)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  parent_uuid <- review_queue_add(con, kind = "value_conflict") # a REAL, live parent

  # Half 1: NOT NULL is enforced.
  expect_error(
    DBI::dbExecute(
      con,
      "INSERT INTO review_queue_candidate (uuid, uuid_review, uuid_feature, kind, rank)
       VALUES (?, ?, NULL, 'candidate', 1)",
      params = list(uuid::UUIDgenerate(), parent_uuid)
    ),
    regexp = "NOT NULL"
  )

  # Half 2: the FK is absent by design. A syntactically valid but non-existent
  # uuid_feature must SUCCEED and the row must actually land -- resolution is
  # verified by the migration (R-16.12/R-16.13), not by the database.
  candidate_uuid <- uuid::UUIDgenerate()
  dangling_feature_uuid <- uuid::UUIDgenerate()
  n <- DBI::dbExecute(
    con,
    "INSERT INTO review_queue_candidate (uuid, uuid_review, uuid_feature, kind, rank)
     VALUES (?, ?, ?, 'candidate', 1)",
    params = list(candidate_uuid, parent_uuid, dangling_feature_uuid)
  )
  expect_equal(n, 1L)

  row <- DBI::dbGetQuery(
    con,
    "SELECT uuid_feature FROM review_queue_candidate WHERE uuid = ?",
    params = list(candidate_uuid)
  )
  expect_equal(row$uuid_feature, dangling_feature_uuid)
})

# --- R-16.4: candidate order is preserved through a write/read round-trip -
# ORDER, not SET: expect_setequal alone would pass a scrambled read-back and
# FAILS this criterion by construction, so it is deliberately absent below.

test_that("R-16.4 review_queue_candidate order is preserved through a write/read round-trip via rank", {
  dir <- withr::local_tempdir()
  db <- seed_db(dir)
  con <- seed_con(db)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  read_order <- function(parent) {
    DBI::dbGetQuery(
      con,
      "SELECT uuid_feature FROM review_queue_candidate WHERE uuid_review = ? ORDER BY rank",
      params = list(parent)
    )$uuid_feature
  }

  # Driven through the REAL writer (review_queue_add() -> .rq_row()), not
  # test-supplied rank values -- a self-fulfilling fixture that writes its own
  # `rank` and reads it back via ORDER BY rank tests DuckDB's ORDER BY, not
  # whether the writer assigns rank in input order. Both vectors below are
  # deliberately UNSORTED (sort(x) != x) so a rank-scrambling bug (e.g.
  # `uuid_feature = sort(candidates)` in .rq_row()) cannot hide the way it did
  # behind R-16.9's already-sorted c("f-0001", "f-0002") fixture.
  candidates_1 <- c("f-0002", "f-0001")
  stopifnot(!identical(sort(candidates_1), candidates_1))
  parent_1 <- review_queue_add(con, kind = "unknown_feature", candidates = candidates_1)
  expect_equal(read_order(parent_1), candidates_1)

  candidates_2 <- c("f-0003", "f-0005", "f-0004")
  stopifnot(!identical(sort(candidates_2), candidates_2))
  parent_2 <- review_queue_add(con, kind = "unknown_feature", candidates = candidates_2)
  expect_equal(read_order(parent_2), candidates_2)
})

# --- R-16.5: the expired kind carries its date range; candidate does not --

test_that("R-16.5 kind='expired' round-trips date_start/date_end as DATE; kind='candidate' carries NA for both", {
  dir <- withr::local_tempdir()
  db <- seed_db(dir)
  con <- seed_con(db)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  parent <- review_queue_add(con, kind = "value_conflict")

  # Build the child rows through the real constructor, .rq_row(), so the
  # expired branch (kind='expired', the date columns, and the
  # rank = n_candidates + seq_len(n_expired) offset) is actually exercised --
  # a block that only hand-INSERTs both kinds pins the DDL, not the writer.
  rq <- sampleTidy:::.rq_row(
    kind = "value_conflict",
    candidates = "f-0002",
    expired = tibble::tibble(
      uuid_feature = "f-0001",
      date_start = as.Date("2020-01-01"),
      date_end = as.Date("2020-06-30")
    )
  )
  cand <- rq$candidates
  expect_equal(nrow(cand), 2L)

  cand_built <- cand[cand$kind == "candidate", ]
  expired_built <- cand[cand$kind == "expired", ]

  expect_equal(cand_built$uuid_feature, "f-0002")
  expect_true(is.na(cand_built$date_start))
  expect_true(is.na(cand_built$date_end))
  expect_equal(cand_built$rank, 1L)

  expect_equal(expired_built$uuid_feature, "f-0001")
  expect_equal(expired_built$date_start, as.Date("2020-01-01"))
  expect_equal(expired_built$date_end, as.Date("2020-06-30"))
  # the rank offset that keeps expired rows ordered AFTER candidates.
  expect_equal(expired_built$rank, 2L)

  # Write the constructor's own child rows (tied to the real parent uuid) and
  # keep the existing DDL round-trip assertions on the read-back.
  cand$uuid_review <- parent
  for (i in seq_len(nrow(cand))) {
    DBI::dbExecute(
      con,
      "INSERT INTO review_queue_candidate
         (uuid, uuid_review, uuid_feature, kind, date_start, date_end, rank)
       VALUES (?, ?, ?, ?, ?, ?, ?)",
      params = list(
        cand$uuid[[i]], cand$uuid_review[[i]], cand$uuid_feature[[i]], cand$kind[[i]],
        cand$date_start[[i]], cand$date_end[[i]], cand$rank[[i]]
      )
    )
  }

  expired_row <- DBI::dbGetQuery(
    con,
    "SELECT date_start, date_end FROM review_queue_candidate WHERE uuid_review = ? AND kind = 'expired'",
    params = list(parent)
  )
  candidate_row <- DBI::dbGetQuery(
    con,
    "SELECT date_start, date_end FROM review_queue_candidate WHERE uuid_review = ? AND kind = 'candidate'",
    params = list(parent)
  )

  expect_equal(nrow(expired_row), 1L)
  expect_equal(expired_row$date_start, as.Date("2020-01-01"))
  expect_equal(expired_row$date_end, as.Date("2020-06-30"))
  expect_true(inherits(expired_row$date_start, "Date"))

  expect_equal(nrow(candidate_row), 1L)
  expect_true(is.na(candidate_row$date_start))
  expect_true(is.na(candidate_row$date_end))
})

# --- R-16.9: both insert paths write the same shape ------------------------

test_that("R-16.9 review_queue_add() and the raw db_append() tibble path write identical review_queue columns and identical review_queue_candidate child rows for identical input", {
  dir <- withr::local_tempdir()
  db <- seed_db(dir)
  con <- seed_con(db)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  # Identical logical input fed to both paths.
  kind <- "unknown_feature"
  subkind <- "descriptive"
  work_order <- "XX1234567"
  source_hash <- "src-hash-p16-9"
  payload <- "note: R-16.9 fixture" # a plain diagnostics string is enough here - this test is about column/child-row shape, not payload format (R-16.6/R-16.10 own that).
  uuid_existing <- NA_character_
  uuid_alias <- NA_character_
  candidate_features <- c("f-0001", "f-0002") # order matters (R-16.4)

  # --- path A: review_queue_add() -------------------------------------------
  uuid_a <- review_queue_add(
    con, kind = kind, subkind = subkind, work_order = work_order,
    source_hash = source_hash, payload = payload,
    uuid_existing = uuid_existing, uuid_alias = uuid_alias,
    candidates = candidate_features
  )

  # --- path B: the raw db_append() tibble path, mirroring
  # .ct_commit_review()'s row shape (R/commit.R:645-650) plus the new
  # PLAN-16 columns, with a second db_append() for the child rows - there is
  # no single generic call that writes a parent row and its children at
  # once via this path. ------------------------------------------------
  uuid_b <- uuid::UUIDgenerate()
  row_b <- tibble::tibble(
    uuid = uuid_b, created_at = Sys.time(), kind = kind, subkind = subkind,
    work_order = work_order, source_hash = source_hash, payload = payload,
    status = "open", uuid_existing = uuid_existing, uuid_alias = uuid_alias
  )
  db_append(con, "review_queue", row_b, actor = "test", reason = "R-16.9 fixture")

  cand_rows_b <- tibble::tibble(
    uuid = vapply(candidate_features, function(x) uuid::UUIDgenerate(), character(1)),
    uuid_review = uuid_b, uuid_feature = candidate_features,
    kind = "candidate", date_start = as.Date(NA), date_end = as.Date(NA),
    rank = seq_along(candidate_features)
  )
  db_append(con, "review_queue_candidate", cand_rows_b, actor = "test", reason = "R-16.9 fixture")

  # --- compare: identical review_queue column population (uuid/created_at
  # excluded - each row's own identity/timestamp, not shared shape). -------
  fields <- c("kind", "subkind", "work_order", "source_hash", "payload", "status", "uuid_existing", "uuid_alias")
  select_sql <- sprintf("SELECT %s FROM review_queue WHERE uuid = ?", paste(fields, collapse = ", "))
  row_a <- DBI::dbGetQuery(con, select_sql, params = list(uuid_a))
  row_b_read <- DBI::dbGetQuery(con, select_sql, params = list(uuid_b))
  expect_equal(row_a, row_b_read)

  # --- compare: identical child-row population, order (rank) included. ----
  cand_sql <- "SELECT uuid_feature, kind, rank FROM review_queue_candidate WHERE uuid_review = ? ORDER BY rank"
  cand_a <- DBI::dbGetQuery(con, cand_sql, params = list(uuid_a))
  cand_b <- DBI::dbGetQuery(con, cand_sql, params = list(uuid_b))
  expect_equal(cand_a, cand_b)
  expect_equal(cand_a$uuid_feature, candidate_features)
})

# ---------------------------------------------------------------------------
# PLAN-16 Phase-7b round-2 remediation: FD6/FF9, FD9, FD10, FD12, FF8.
# ---------------------------------------------------------------------------

# --- FD12: .rq_row() validates every scalar typed argument, not just kind --

test_that("FD12: .rq_row() rejects a length>1 value for any scalar typed argument (not just kind)", {
  expect_error(
    sampleTidy:::.rq_row(kind = "unknown_feature", uuid_existing = c("a", "b")),
    regexp = "length 1"
  )
  expect_error(
    sampleTidy:::.rq_row(kind = "unknown_feature", subkind = c("a", "b")),
    regexp = "length 1"
  )
  expect_error(
    sampleTidy:::.rq_row(kind = "unknown_feature", work_order = c("a", "b")),
    regexp = "length 1"
  )
  expect_error(
    sampleTidy:::.rq_row(kind = "unknown_feature", source_hash = c("a", "b")),
    regexp = "length 1"
  )
  expect_error(
    sampleTidy:::.rq_row(kind = "unknown_feature", uuid_alias = c("a", "b")),
    regexp = "length 1"
  )
  # a length>1 argument must never reach a 2-row review tibble sharing one uuid.
  expect_no_error(sampleTidy:::.rq_row(kind = "unknown_feature", uuid_existing = NA_character_))
})

# --- FD9: expired= is validated - a non-Date bound is rejected, not coerced -

test_that("FD9: .rq_row(expired=) rejects a POSIXct date_start/date_end instead of silently truncating it", {
  bad <- tibble::tibble(
    uuid_feature = "f-0001",
    date_start = as.POSIXct("2022-03-04 09:00:00", tz = "Australia/Sydney"),
    date_end = as.POSIXct(NA)
  )
  expect_error(
    sampleTidy:::.rq_row(kind = "expired", expired = bad),
    regexp = "date_start.*Date"
  )
})

test_that("FD9: .rq_row(expired=) rejects a data frame missing the columns it actually reads", {
  bad <- tibble::tibble(uuid_feature = "f-0001") # no date_start/date_end
  expect_error(
    sampleTidy:::.rq_row(kind = "expired", expired = bad),
    regexp = "date_start|date_end"
  )
})

test_that("FD9: .rq_row(expired=) accepts a genuine Date bound (control - the guard is not over-broad)", {
  ok <- tibble::tibble(
    uuid_feature = "f-0001", date_start = as.Date("2020-01-01"), date_end = as.Date(NA)
  )
  expect_no_error(sampleTidy:::.rq_row(kind = "expired", expired = ok))
})

# --- FD10(a): candidate dedup, first-seen order, dense rank sequence -------

test_that("FD10(a): review_queue_add() dedups repeated candidate feature uuids, preserving first-seen order with a dense rank sequence", {
  dir <- withr::local_tempdir()
  db <- seed_db(dir)
  con <- seed_con(db)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  parent <- review_queue_add(con, kind = "unknown_feature", candidates = c("f-1", "f-1", "f-2", "f-1"))

  rows <- DBI::dbGetQuery(
    con,
    "SELECT uuid_feature, rank FROM review_queue_candidate WHERE uuid_review = ? ORDER BY rank",
    params = list(parent)
  )
  expect_equal(nrow(rows), 2L) # deduped, not 4
  expect_equal(rows$uuid_feature, c("f-1", "f-2")) # first-seen order
  expect_equal(rows$rank, c(1L, 2L)) # dense 1..n after dedup

  # the expired offset must be recomputed off the DEDUPED count, not the raw input length.
  rq <- sampleTidy:::.rq_row(
    kind = "unknown_feature",
    candidates = c("f-1", "f-1", "f-2"),
    expired = tibble::tibble(
      uuid_feature = "f-3", date_start = as.Date("2020-01-01"), date_end = as.Date("2020-06-30")
    )
  )
  expect_equal(nrow(rq$candidates), 3L) # 2 deduped candidates + 1 expired
  expired_row <- rq$candidates[rq$candidates$kind == "expired", ]
  expect_equal(expired_row$rank, 3L) # 2 (deduped candidates), not 4 (raw input length)
})

# --- FD10(b): UNIQUE(uuid_review, rank) is enforced at the DB level --------

test_that("FD10(b): review_queue_candidate has UNIQUE(uuid_review, rank), enforced by a real duplicate insert", {
  dir <- withr::local_tempdir()
  db <- seed_db(dir)
  con <- seed_con(db)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  parent <- review_queue_add(con, kind = "value_conflict")
  DBI::dbExecute(
    con,
    "INSERT INTO review_queue_candidate (uuid, uuid_review, uuid_feature, kind, rank)
     VALUES (?, ?, 'f-1', 'candidate', 1)",
    params = list(uuid::UUIDgenerate(), parent)
  )

  expect_error(
    DBI::dbExecute(
      con,
      "INSERT INTO review_queue_candidate (uuid, uuid_review, uuid_feature, kind, rank)
       VALUES (?, ?, 'f-2', 'candidate', 1)", # same (uuid_review, rank) pair
      params = list(uuid::UUIDgenerate(), parent)
    ),
    regexp = "Constraint Error|unique constraint"
  )
})

# --- FD6/FF9: review_queue_add() writes go through the mutation layer -----

test_that("FD6/FF9: review_queue_add() writes one change_log row per record (parent + every candidate), via db_append() not raw dbExecute()", {
  dir <- withr::local_tempdir()
  db <- seed_db(dir)
  con <- seed_con(db)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  before <- DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM change_log")$n

  parent <- review_queue_add(con, kind = "unknown_feature", candidates = c("f-1", "f-2"))

  after <- DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM change_log")$n
  expect_equal(after - before, 3L) # 1 parent row + 2 candidate rows

  parent_log <- DBI::dbGetQuery(
    con, "SELECT COUNT(*) AS n FROM change_log WHERE uuid_row = ? AND tbl = 'review_queue'",
    params = list(parent)
  )$n
  expect_equal(parent_log, 1L)

  cand_uuids <- DBI::dbGetQuery(
    con, "SELECT uuid FROM review_queue_candidate WHERE uuid_review = ?", params = list(parent)
  )$uuid
  cand_log <- DBI::dbGetQuery(
    con,
    "SELECT COUNT(*) AS n FROM change_log WHERE tbl = 'review_queue_candidate' AND uuid_row IN (?, ?)",
    params = list(cand_uuids[[1]], cand_uuids[[2]])
  )$n
  expect_equal(cand_log, 2L)
})

# --- FF8: registered plural diagnostics keys always serialise as a JSON
# array, at length 1 AND length 0/2 - asserted on the raw JSON TEXT (not
# jsonlite::fromJSON(), whose own simplification would hide a scalar/array
# difference). Non-registered keys keep auto_unbox's scalar-at-length-1
# behaviour (a control, so the fix is not shown to have gone global).

test_that("FF8: registered plural diagnostics keys (candidates, source_ref) always serialise as a JSON array, at length 1 and length 2", {
  expect_identical(
    sampleTidy:::.rq_serialise_diagnostics(list(candidates = "f-0001")),
    '{"candidates":["f-0001"]}'
  )
  expect_identical(
    sampleTidy:::.rq_serialise_diagnostics(list(candidates = c("f-0001", "f-0002"))),
    '{"candidates":["f-0001","f-0002"]}'
  )
  expect_identical(
    sampleTidy:::.rq_serialise_diagnostics(list(source_ref = "row1")),
    '{"source_ref":["row1"]}'
  )
  expect_identical(
    sampleTidy:::.rq_serialise_diagnostics(list(source_ref = c("row1", "row2"))),
    '{"source_ref":["row1","row2"]}'
  )
})

test_that("FF8: a NON-registered diagnostics key keeps auto_unbox's scalar-at-length-1 shape (control: the fix is scoped, not global)", {
  expect_identical(
    sampleTidy:::.rq_serialise_diagnostics(list(units_raw = "mg/L")),
    '{"units_raw":"mg/L"}'
  )
})

test_that("FF8: a caller that has already wrapped a plural key in I() is honoured, not double-wrapped", {
  expect_identical(
    sampleTidy:::.rq_serialise_diagnostics(list(candidates = I("f-0001"))),
    '{"candidates":["f-0001"]}'
  )
})
