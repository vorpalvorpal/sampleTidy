# Plan 13 - dev/migrations/001-alias-indirection.R (R-13.1, R-13.2).
#
# TARGET FILE CONTRACT (the target file is TDD-red/unwritten; this is the
# interface Phase 6 must implement so these tests pass - not part of the
# package NAMESPACE, so tests `sys.source()` it directly via `.mig001_load()`
# below rather than relying on `devtools::load_all()`):
#
#   mig001_counts_checksum(con)
#     -> named list(feature=int, sample=int, analysis=int, lab_method=int,
#        checksum=<opaque comparable value>) - row counts + a value checksum
#        (steps 2 and 11 share this).
#
#   mig001_verify(before, after)
#     -> invisible(TRUE) if every field of `before`/`after` matches; throws
#        (catchable by `expect_error()`) on ANY mismatch (step 11, hard gate).
#
#   mig001_backup(db, snapshot_dir, .now = NULL)
#     -> character(1) absolute path to a verified, timestamped copy of `db`
#        (step 1): `<snapshot_dir>/monitoring_pre-001-alias-indirection_
#        <UTC %Y%m%dT%H%M%OS3Z>.duckdb`. `.now` injects a POSIXct instead of
#        `Sys.time()`, for deterministic same-day-collision testing. Throws,
#        writing nothing to `db`, if the copy or its row-count verification
#        fails.
#
#   mig001_run(db, snapshot_dir, dry_run = FALSE, .now = NULL)
#     -> invisible list(status = "migrated" | "already_migrated" | "dry_run",
#        backup_path = chr or NA, restore_command = chr or NA,
#        counts_before/counts_after = mig001_counts_checksum() shape or NA,
#        ambiguous_count = int or NA, recorded_at = POSIXct/chr or NA).
#        Runs steps 0-11 (PLAN-13 B-13.1) plus R-13.2's column-add, inside
#        one transaction. Prints log lines to stdout; every non-blank line
#        quotes the absolute `db` path. Throws on backup failure (nothing
#        written) or step-11 verify mismatch.
#
# Every test sources the target file inside its own `test_that()` (never at
# file top level), so a missing/broken target file surfaces as an ordinary
# per-test failure - not a whole-file collection error that would silently
# zero out every other test's coverage.

.mig001_load <- function() {
  env <- new.env(parent = globalenv())
  path <- testthat::test_path("..", "..", "dev", "migrations", "001-alias-indirection.R")
  skip_if_not(file.exists(path), "dev/migrations not in built package (run via devtools::test)")
  sys.source(path, envir = env)
  env
}

# ---- R-13.1 step 1 / backup gate -------------------------------------------

test_that("R-13.1: the script writes nothing until a verified backup exists", {
  mig <- .mig001_load()
  path <- seed_pre_migration_db()
  con <- pre_migration_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  fields_before <- DBI::dbListFields(con, "sample")

  # A REGULAR FILE where the snapshot dir should be: any attempt to write a
  # backup file "inside" it must fail for real, no mocking required.
  bad_snapshot_dir <- withr::local_tempfile()
  writeLines("not a directory", bad_snapshot_dir)

  expect_error(
    mig$mig001_run(db = path, snapshot_dir = bad_snapshot_dir, dry_run = FALSE)
  )

  # Zero writes: `sample` still has the pre-migration column, and step 3
  # never ran (no `feature_alias` table).
  expect_true("uuid_feature" %in% DBI::dbListFields(con, "sample"))
  expect_identical(DBI::dbListFields(con, "sample"), fields_before)
  expect_false(DBI::dbExistsTable(con, "feature_alias"))
})

test_that("R-13.1: same-day repeat backups use millisecond-precision names and never overwrite each other", {
  mig <- .mig001_load()
  path <- seed_pre_migration_db()
  snap_dir <- withr::local_tempdir()

  # Same UTC calendar day, distinct instants a few milliseconds apart -
  # the exact scenario second-precision naming would collide on
  # (Phase-3 D19 / the snapshot_db() trap).
  t1 <- as.POSIXct("2026-07-22 10:00:00.100", tz = "UTC")
  t2 <- as.POSIXct("2026-07-22 10:00:00.400", tz = "UTC")

  p1 <- mig$mig001_backup(db = path, snapshot_dir = snap_dir, .now = t1)
  p2 <- mig$mig001_backup(db = path, snapshot_dir = snap_dir, .now = t2)

  expect_true(fs::file_exists(p1))
  expect_true(fs::file_exists(p2))
  expect_false(identical(p1, p2))
  expect_false(basename(p1) == basename(p2))

  # Never the snapshot_db() date-only naming scheme.
  expect_false(grepl("^monitoring_\\d{4}-\\d{2}-\\d{2}\\.duckdb$", basename(p1)))
  expect_true(grepl(
    "^monitoring_pre-001-alias-indirection_\\d{8}T\\d{6}\\.\\d{3}Z\\.duckdb$",
    basename(p1)
  ))

  # Both are genuine, independently-verified copies of the same pre-migration
  # state (round-trip through the real driver, not just the in-memory path).
  src_con <- pre_migration_con(path)
  withr::defer(DBI::dbDisconnect(src_con, shutdown = TRUE))
  src_n <- DBI::dbGetQuery(src_con, "SELECT COUNT(*) n FROM feature")$n

  for (p in c(p1, p2)) {
    bcon <- DBI::dbConnect(duckdb::duckdb(), p, read_only = TRUE)
    expect_identical(DBI::dbGetQuery(bcon, "SELECT COUNT(*) n FROM feature")$n, src_n)
    DBI::dbDisconnect(bcon, shutdown = TRUE)
  }
})

# ---- R-13.1 idempotency (step 0 marker) ------------------------------------

test_that("R-13.1: a second run is idempotent via the schema_version marker and writes nothing", {
  mig <- .mig001_load()
  path <- seed_pre_migration_db()
  snap_dir <- withr::local_tempdir()

  r1 <- mig$mig001_run(db = path, snapshot_dir = snap_dir, dry_run = FALSE)
  expect_identical(r1$status, "migrated")

  con <- pre_migration_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  n_alias_after_1 <- DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM feature_alias")$n

  # Simulate PLAN-14 having since written a value the migration must not
  # clear on a re-run (R-13.2's idempotency half).
  DBI::dbExecute(con, "UPDATE lab_method SET units = 'mg/L-since-plan14' WHERE uuid = 'lm-901'")

  r2 <- mig$mig001_run(db = path, snapshot_dir = snap_dir, dry_run = FALSE)
  expect_identical(r2$status, "already_migrated")
  # Not merely "no error": row-count and checksum comparison.
  expect_identical(r2$counts_before, r2$counts_after)
  expect_identical(mig$mig001_counts_checksum(con), r1$counts_after)

  n_alias_after_2 <- DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM feature_alias")$n
  expect_identical(n_alias_after_2, n_alias_after_1)

  # The value PLAN-14 wrote survives the idempotent re-run untouched.
  expect_identical(
    DBI::dbGetQuery(con, "SELECT units FROM lab_method WHERE uuid = 'lm-901'")$units,
    "mg/L-since-plan14"
  )
})

# ---- R-13.1 logging ---------------------------------------------------------

test_that("R-13.1: every log line quotes the absolute DB path", {
  mig <- .mig001_load()
  path <- seed_pre_migration_db()
  snap_dir <- withr::local_tempdir()

  out <- capture.output(
    mig$mig001_run(db = path, snapshot_dir = snap_dir, dry_run = FALSE)
  )
  nonblank <- out[nzchar(trimws(out))]
  expect_true(length(nonblank) > 0)
  expect_true(all(grepl(path, nonblank, fixed = TRUE)))

  # Step 1 must also print the backup path and the restore command before
  # proceeding.
  expect_true(any(grepl("restore", nonblank, ignore.case = TRUE)))
})

# ---- R-13.1 views (steps 6/10, D20) -----------------------------------------

test_that("R-13.1: all six views exist and return without error after migration, and v_measurement's row count is unchanged", {
  mig <- .mig001_load()
  path <- seed_pre_migration_db()
  con0 <- pre_migration_con(path)
  n_before <- DBI::dbGetQuery(con0, "SELECT COUNT(*) n FROM v_measurement")$n
  DBI::dbDisconnect(con0, shutdown = TRUE)

  mig$mig001_run(db = path, snapshot_dir = withr::local_tempdir(), dry_run = FALSE)

  con <- pre_migration_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  six <- c(
    "v_feature_dates", "v_measurement", "v_measurement_epa",
    "v_measurement_gas_report", "v_measurement_long", "v_measurement_old"
  )
  for (v in six) {
    expect_true(DBI::dbExistsTable(con, v), info = v)
    expect_no_error(DBI::dbGetQuery(con, sprintf("SELECT * FROM %s", v)))
  }

  n_after <- DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM v_measurement")$n
  expect_identical(n_after, n_before)
  expect_equal(n_after, 3L)
})

# ---- R-13.1 feature.cypher left untouched ----------------------------------

test_that("R-13.1: feature.cypher is left untouched by the migration", {
  mig <- .mig001_load()
  path <- seed_pre_migration_db()
  mig$mig001_run(db = path, snapshot_dir = withr::local_tempdir(), dry_run = FALSE)

  con <- pre_migration_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  cyphers <- DBI::dbGetQuery(con, "SELECT uuid, cypher FROM feature ORDER BY uuid")
  expect_identical(cyphers$cypher[cyphers$uuid == "f-101"], "PM01")
  expect_identical(cyphers$cypher[cyphers$uuid == "f-102"], "B.S02a, B.S02a")
  expect_identical(cyphers$cypher[cyphers$uuid == "f-103"], "old landfill bore")
})

# ---- R-13.1 dry run ----------------------------------------------------------

test_that("R-13.1: dry-run prints the counts it would insert and writes nothing", {
  mig <- .mig001_load()
  path <- seed_pre_migration_db()
  snap_dir <- withr::local_tempdir()

  out <- capture.output(
    result <- mig$mig001_run(db = path, snapshot_dir = snap_dir, dry_run = TRUE)
  )
  expect_identical(result$status, "dry_run")

  # 5 features in the fixture -> 5 self-aliases it WOULD insert.
  expect_true(any(grepl("5", out)))

  con <- pre_migration_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  expect_false(DBI::dbExistsTable(con, "feature_alias"))
  expect_true("uuid_feature" %in% DBI::dbListFields(con, "sample"))
  expect_false("units" %in% DBI::dbListFields(con, "lab_method"))
  expect_length(list.files(snap_dir), 0)
})

# ---- R-13.1 step 3/4: self-aliases, historical_code/descriptive, n_seen ----

test_that("R-13.1: step 3 seeds one self-alias per feature, folded (not duplicated) by a self-name cypher entry", {
  mig <- .mig001_load()
  path <- seed_pre_migration_db()
  con0 <- pre_migration_con(path)
  n_features <- DBI::dbGetQuery(con0, "SELECT COUNT(*) n FROM feature")$n
  DBI::dbDisconnect(con0, shutdown = TRUE)

  mig$mig001_run(db = path, snapshot_dir = withr::local_tempdir(), dry_run = FALSE)

  con <- pre_migration_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  self_rows <- DBI::dbGetQuery(con, "SELECT * FROM feature_alias WHERE kind = 'self'")
  expect_equal(nrow(self_rows), n_features)

  pm01 <- DBI::dbGetQuery(con, "SELECT * FROM feature_alias WHERE alias_key = 'pm01'")
  # Exactly one row - the self-name cypher entry folds into the self-alias,
  # it does not create a second row.
  expect_identical(nrow(pm01), 1L)
  expect_identical(pm01$kind, "self")
  expect_identical(pm01$uuid_feature, "f-101")
  expect_identical(pm01$n_seen, 1L)
})

test_that("R-13.1: a whitespace-free digit-bearing entry imports historical_code, a multi-word entry imports descriptive, and duplicates count into n_seen", {
  mig <- .mig001_load()
  path <- seed_pre_migration_db()
  mig$mig001_run(db = path, snapshot_dir = withr::local_tempdir(), dry_run = FALSE)

  con <- pre_migration_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  code_row <- DBI::dbGetQuery(con, "
    SELECT * FROM feature_alias WHERE alias_key = 'b.s02a' AND uuid_feature = 'f-102'")
  expect_identical(nrow(code_row), 1L)
  expect_identical(code_row$kind, "historical_code")
  # 2 duplicate cypher occurrences + 1 mask-'long' overlap (R-13.1 step 5) =
  # 3, never merely "no error".
  expect_identical(code_row$n_seen, 3L)
  expect_true(code_row$auto_assign)

  desc_row <- DBI::dbGetQuery(con, "
    SELECT * FROM feature_alias WHERE alias_key = 'old landfill bore'")
  expect_identical(nrow(desc_row), 1L)
  expect_identical(desc_row$kind, "descriptive")
  expect_identical(desc_row$n_seen, 1L)
  expect_true(desc_row$auto_assign)
})

test_that("R-13.1: an alias_key reaching two features is ambiguous on both rows, a single-feature key stays auto_assign = TRUE, and the ambiguous count is printed", {
  mig <- .mig001_load()
  path <- seed_pre_migration_db()
  snap_dir <- withr::local_tempdir()

  out <- capture.output(
    result <- mig$mig001_run(db = path, snapshot_dir = snap_dir, dry_run = FALSE)
  )
  expect_identical(result$ambiguous_count, 2L)
  expect_true(any(grepl("ambig", out, ignore.case = TRUE) & grepl("2", out)))

  con <- pre_migration_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  ambig_rows <- DBI::dbGetQuery(con, "SELECT * FROM feature_alias WHERE alias_key = 'ambig.key1'")
  expect_identical(nrow(ambig_rows), 2L)
  expect_setequal(ambig_rows$uuid_feature, c("f-104", "f-105"))
  expect_true(all(!ambig_rows$auto_assign))

  # A single-feature key stays TRUE (contrast case, same run).
  single_row <- DBI::dbGetQuery(con, "SELECT auto_assign FROM feature_alias WHERE alias_key = 'old landfill bore'")
  expect_true(single_row$auto_assign)
})

# ---- R-13.1 step 5: mask import -------------------------------------------

test_that("R-13.1: feature_mask 'long' names import as mask_long and collapse into an existing alias, while old/gas_report/epa are never imported", {
  mig <- .mig001_load()
  path <- seed_pre_migration_db()
  mig$mig001_run(db = path, snapshot_dir = withr::local_tempdir(), dry_run = FALSE)

  con <- pre_migration_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  # 'long' on f-102 collapsed into the existing cypher-derived 'b.s02a' row
  # rather than erroring or creating a second row (asserted precisely above:
  # n_seen == 3, exactly one row). Here: no NEW alias row of kind
  # 'mask_long' was needed to represent it.
  n_b_s02a_rows <- DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM feature_alias WHERE alias_key = 'b.s02a'")$n
  expect_equal(n_b_s02a_rows, 1L)

  not_imported <- DBI::dbGetQuery(con, "
    SELECT alias_key FROM feature_alias
    WHERE alias_key IN ('old pm three name', 'gr-pm01', 'epa-pm04')")
  expect_identical(nrow(not_imported), 0L)
})

# ---- feature_alias DDL must match the runtime schema (R-11.1) -------------

test_that("R-13.1: feature_alias is created with all 11 runtime columns (incl. `name`) and the migrated DB is usable by pending_features()", {
  mig <- .mig001_load()
  path <- seed_pre_migration_db()
  mig$mig001_run(db = path, snapshot_dir = withr::local_tempdir(), dry_run = FALSE)

  con <- pre_migration_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  expect_setequal(
    DBI::dbListFields(con, "feature_alias"),
    c("uuid", "uuid_feature", "name", "alias_key", "kind", "n_seen",
      "auto_assign", "first_seen", "last_seen", "confirmed_by", "comments")
  )

  # `name` must actually be populated (NOT NULL, non-vacuous) for every row -
  # the defect this test guards against left it entirely unwritten.
  n_missing_name <- DBI::dbGetQuery(
    con, "SELECT COUNT(*) n FROM feature_alias WHERE name IS NULL"
  )$n
  expect_equal(n_missing_name, 0L)

  # Prove the migrated DB is actually usable by a runtime writer/reader, not
  # just structurally correct: pending_features() must run without error.
  expect_no_error(result <- pending_features(con))
  expect_s3_class(result, "data.frame")
})

test_that("R-13.1: the migrated `sample` rebuild keeps uuid_feature_alias NOT NULL (matches CONTRACT / helper-db.R)", {
  mig <- .mig001_load()
  path <- seed_pre_migration_db()
  mig$mig001_run(db = path, snapshot_dir = withr::local_tempdir(), dry_run = FALSE)

  con <- pre_migration_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  is_nullable <- DBI::dbGetQuery(con, "
    SELECT is_nullable FROM information_schema.columns
    WHERE table_name='sample' AND column_name='uuid_feature_alias'
  ")$is_nullable
  expect_identical(is_nullable, "NO")

  expect_error(DBI::dbExecute(con, "
    INSERT INTO \"sample\" (uuid, uuid_feature_alias, date)
    VALUES ('s-null-test', NULL, TIMESTAMP '2024-01-01 00:00:00')
  "))
})

# ---- R-13.1 step 11: verify is a hard gate ---------------------------------

test_that("R-13.1: the step-11 verify is a hard gate that aborts on any count/checksum mismatch", {
  mig <- .mig001_load()
  path <- seed_pre_migration_db()
  con <- pre_migration_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  before <- mig$mig001_counts_checksum(con)
  identical_after <- before
  expect_true(isTRUE(mig$mig001_verify(before, identical_after)))

  for (field in c("feature", "sample", "analysis", "lab_method", "checksum")) {
    mismatched <- before
    mismatched[[field]] <- if (is.numeric(mismatched[[field]])) {
      mismatched[[field]] + 1
    } else {
      paste0(mismatched[[field]], "-mismatch")
    }
    expect_error(mig$mig001_verify(before, mismatched), info = field)
  }
})

# ---- R-13.1: a mid-transaction failure leaves the DB unchanged ------------

test_that("R-13.1: a failure inside the steps 3-10 transaction leaves the DB completely unchanged", {
  mig <- .mig001_load()
  path <- seed_pre_migration_db()

  # Force step 3's `CREATE TABLE feature_alias` to fail for real by
  # pre-creating an incompatible table under that name - a legitimate SQL
  # error, not a mock.
  setup_con <- pre_migration_con(path)
  DBI::dbExecute(setup_con, "CREATE TABLE feature_alias (dummy INTEGER)")
  fields_before <- DBI::dbListFields(setup_con, "sample")
  counts_before <- mig$mig001_counts_checksum(setup_con)
  DBI::dbDisconnect(setup_con, shutdown = TRUE)

  expect_error(
    mig$mig001_run(db = path, snapshot_dir = withr::local_tempdir(), dry_run = FALSE)
  )

  con <- pre_migration_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  # The rollback leaves the pre-existing (dummy) `feature_alias` exactly as
  # it was - proof the whole transaction reverted, not just step 3.
  expect_identical(DBI::dbListFields(con, "feature_alias"), "dummy")
  expect_identical(DBI::dbListFields(con, "sample"), fields_before)
  expect_identical(mig$mig001_counts_checksum(con), counts_before)
})

# ---- Phase-8b: step-11 verify must GATE the commit, not run after it -------

test_that("R-13.1/Phase-8b: a step-11 verify failure rolls back the whole transaction (verify gates the commit)", {
  mig <- .mig001_load()
  path <- seed_pre_migration_db()
  snap_dir <- withr::local_tempdir()

  setup_con <- pre_migration_con(path)
  fields_before <- DBI::dbListFields(setup_con, "sample")
  counts_before <- mig$mig001_counts_checksum(setup_con)
  DBI::dbDisconnect(setup_con, shutdown = TRUE)

  # Inject a verify that always fails, simulating a real integrity mismatch
  # discovered at step 11.
  mig$mig001_verify <- function(before, after) stop("injected integrity failure")

  expect_error(
    mig$mig001_run(db = path, snapshot_dir = snap_dir, dry_run = FALSE),
    "injected integrity failure"
  )

  # The marker must be ABSENT - the injected failure must have rolled back
  # the whole transaction, not landed after an already-committed marker.
  con <- pre_migration_con(path)
  marker <- DBI::dbGetQuery(
    con, "SELECT applied_at FROM schema_version WHERE version = ?",
    params = list(mig$.mig001_marker_version)
  )
  expect_identical(nrow(marker), 0L)

  # The db is still in its exact pre-migration shape: `sample` still lacks
  # `uuid_feature_alias` (the post-migration column) and still has its
  # pre-migration NOT NULL `uuid_feature` column; row counts/checksum are
  # unchanged.
  expect_identical(DBI::dbListFields(con, "sample"), fields_before)
  expect_false("uuid_feature_alias" %in% DBI::dbListFields(con, "sample"))
  expect_identical(mig$mig001_counts_checksum(con), counts_before)
  DBI::dbDisconnect(con, shutdown = TRUE)

  # Restore a healthy verify and retry: the migration must actually run
  # (status "migrated"), NOT report "already_migrated" - proving the earlier
  # failure was not laundered by a marker that got committed anyway.
  mig$mig001_verify <- function(before, after) invisible(TRUE)
  r2 <- mig$mig001_run(db = path, snapshot_dir = snap_dir, dry_run = FALSE)
  expect_identical(r2$status, "migrated")

  con2 <- pre_migration_con(path)
  withr::defer(DBI::dbDisconnect(con2, shutdown = TRUE))
  expect_true("uuid_feature_alias" %in% DBI::dbListFields(con2, "sample"))
})

# ---- R-13.2: restore lab_method.units / conversion_constant ---------------

test_that("R-13.2: lab_method gains nullable units and conversion_constant columns", {
  mig <- .mig001_load()
  path <- seed_pre_migration_db()
  mig$mig001_run(db = path, snapshot_dir = withr::local_tempdir(), dry_run = FALSE)

  con <- pre_migration_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  fields <- DBI::dbListFields(con, "lab_method")
  expect_true("units" %in% fields)
  expect_true("conversion_constant" %in% fields)

  cols <- DBI::dbGetQuery(con, "
    SELECT column_name, is_nullable FROM duckdb_columns()
    WHERE table_name = 'lab_method' AND column_name IN ('units', 'conversion_constant')")
  expect_true(all(cols$is_nullable))
  expect_identical(nrow(cols), 2L)
})

test_that("R-13.2: the units column comment records the fallback-not-identity binding rule and is readable back via duckdb_columns()", {
  mig <- .mig001_load()
  path <- seed_pre_migration_db()
  mig$mig001_run(db = path, snapshot_dir = withr::local_tempdir(), dry_run = FALSE)

  con <- pre_migration_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  comment <- DBI::dbGetQuery(con, "
    SELECT comment FROM duckdb_columns()
    WHERE table_name = 'lab_method' AND column_name = 'units'")$comment
  expect_true(!is.na(comment) && nzchar(comment))
  expect_true(grepl("fallback", comment, ignore.case = TRUE))
  expect_true(grepl("identity", comment, ignore.case = TRUE))
})

test_that("R-13.2: every existing lab_method row is otherwise byte-identical after the column-add", {
  mig <- .mig001_load()
  path <- seed_pre_migration_db()
  con0 <- pre_migration_con(path)
  before <- DBI::dbGetQuery(con0, "
    SELECT uuid, uuid_analyte, name, method, organisation, rl_low FROM lab_method ORDER BY uuid")
  DBI::dbDisconnect(con0, shutdown = TRUE)

  mig$mig001_run(db = path, snapshot_dir = withr::local_tempdir(), dry_run = FALSE)

  con <- pre_migration_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  after <- DBI::dbGetQuery(con, "
    SELECT uuid, uuid_analyte, name, method, organisation, rl_low FROM lab_method ORDER BY uuid")

  expect_identical(after, before)
})
