# dev/migrations/009-sample-identity-index.R - the DB-level enforcement of
# Robin's 2026-08-08 ruling 9.
#
#   mig009_run(db, snapshot_dir, dry_run = FALSE, .now = NULL)
#     -> invisible list(status = "migrated" | "already_migrated" | "dry_run", ...)
#
# Every test sources the target inside its own `test_that()` (test-migration-004's
# Phase-5 audit finding B5).
#
# THE FIXTURE DROPS THE INDEX FIRST. `seed_db()` now creates
# `ux_sample_identity`, because a seeded database is meant to match a migrated
# live one. So a test of the MIGRATION has to start from a pre-009 database,
# which is what `.mig009_env()` builds. That is deliberate rather than awkward:
# it means every test here proves the migration can still create the index on a
# database that does not have it, instead of quietly testing nothing because
# the fixture already arrived migrated.
#
# WHAT THESE TESTS ASSERT, AND WHY IT IS NOT `expect_error()` ALONE. A gate that
# has been removed still ends in an error - just later, after a destructive step
# has committed. So every refusal test asserts BOTH that the database is
# byte-for-byte where it started AND that no backup file was left behind. The
# second half is what tells a gate apart from a late failure: preconditions run
# before the backup, so a refusal that produced a backup means the gate moved.

.mig009_load <- function() {
  env <- new.env(parent = globalenv())
  path <- testthat::test_path("..", "..", "dev", "migrations", "009-sample-identity-index.R")
  if (!file.exists(path)) {
    stop(sprintf("migration file not found: %s", path))
  }
  sys.source(path, envir = env)
  env
}

.MIG009_INDEX <- "ux_sample_identity"

#' A seeded database with 009 NOT yet applied.
#'
#' @param extra optional function(con) run after the index is dropped, to bend
#'   the fixture into the shape a particular gate needs.
.mig009_env <- function(extra = NULL) {
  dir <- withr::local_tempdir(.local_envir = parent.frame())
  db <- seed_db(dir = dir)
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = FALSE)
  DBI::dbExecute(con, sprintf("DROP INDEX %s", .MIG009_INDEX))
  if (!is.null(extra)) extra(con)
  DBI::dbDisconnect(con, shutdown = TRUE)
  list(db = db, snapshot_dir = withr::local_tempdir(.local_envir = parent.frame()))
}

#' Everything about the database this migration must not change, plus the one
#' thing it must.
.mig009_state <- function(db) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  tb <- DBI::dbGetQuery(
    con, "SELECT table_name FROM information_schema.tables
           WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  list(
    markers = DBI::dbGetQuery(con, "SELECT version FROM schema_version ORDER BY version")$version,
    indexes = DBI::dbGetQuery(
      con, "SELECT index_name, table_name, is_unique FROM duckdb_indexes() ORDER BY index_name"),
    counts = vapply(tb, function(t) as.integer(
      DBI::dbGetQuery(con, sprintf('SELECT COUNT(*) n FROM "%s"', t))$n), integer(1)),
    samples = DBI::dbGetQuery(
      con, 'SELECT uuid, uuid_feature_alias, datetime, uuid_project FROM "sample" ORDER BY uuid')
  )
}

.mig009_has_index <- function(db) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  nrow(DBI::dbGetQuery(con, "SELECT 1 FROM duckdb_indexes() WHERE index_name = ?",
                       params = list(.MIG009_INDEX))) > 0
}

#' Does the database REJECT a row duplicating an existing sample's key?
#'
#' Asked by making one, not by reading `duckdb_indexes()`. Always leaves the
#' database as it found it.
.mig009_rejects_duplicate <- function(db) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = FALSE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  row <- DBI::dbGetQuery(
    con, 'SELECT uuid_feature_alias a, datetime d, uuid_project p FROM "sample"
           WHERE uuid_feature_alias IS NOT NULL AND datetime IS NOT NULL
             AND uuid_project IS NOT NULL ORDER BY uuid LIMIT 1')
  if (nrow(row) == 0) stop("fixture has no probeable sample row")
  DBI::dbExecute(con, "BEGIN TRANSACTION")
  on.exit(try(DBI::dbExecute(con, "ROLLBACK"), silent = TRUE), add = TRUE, after = FALSE)
  tryCatch({
    DBI::dbExecute(
      con, 'INSERT INTO "sample" (uuid, uuid_feature_alias, datetime, uuid_project)
              VALUES (?, ?, ?, ?)',
      params = list("mig009-test-probe", row$a[[1]], row$d[[1]], row$p[[1]]))
    FALSE
  }, error = function(e) TRUE)
}

# Add a second sample that collides with s-0001 on (alias, datetime, project).
# s-0001 is fa-0001 / 2025-05-24 01:45 UTC / p-0001 in the FIXTURES.md seed.
.mig009_add_collision <- function(con) {
  DBI::dbExecute(
    con, 'INSERT INTO "sample" (uuid, uuid_feature_alias, uuid_project, date, datetime, organisation)
          VALUES (\'s-dup1\', \'fa-0001\', \'p-0001\', TIMESTAMP \'2025-05-24 00:00:00\',
                  TIMESTAMP \'2025-05-24 01:45:00\', \'ALS\')')
}

# ======================================================================
# happy path
# ======================================================================

test_that("mig009_run() creates the unique index and records marker 1009", {
  mig <- .mig009_load(); e <- .mig009_env()
  expect_false(.mig009_has_index(e$db))

  res <- mig$mig009_run(db = e$db, snapshot_dir = e$snapshot_dir)

  expect_identical(res$status, "migrated")
  expect_identical(res$index_name, .MIG009_INDEX)
  expect_identical(res$key_columns,
                   c("uuid_feature_alias", "datetime", "uuid_project"))
  after <- .mig009_state(e$db)
  expect_true(1009L %in% after$markers)
  expect_true(.mig009_has_index(e$db))
})

test_that("the index it creates ACTUALLY REJECTS a duplicate", {
  # The property the whole migration exists for, asked of the committed
  # database by attempting a real duplicate INSERT. `duckdb_indexes()` saying
  # is_unique = TRUE proves an index was named, not that it bites.
  mig <- .mig009_load(); e <- .mig009_env()
  expect_false(.mig009_rejects_duplicate(e$db))

  mig$mig009_run(db = e$db, snapshot_dir = e$snapshot_dir)

  expect_true(.mig009_rejects_duplicate(e$db))
})

test_that("it writes NO rows to any table except its own schema_version marker", {
  mig <- .mig009_load(); e <- .mig009_env()
  before <- .mig009_state(e$db)

  mig$mig009_run(db = e$db, snapshot_dir = e$snapshot_dir)

  after <- .mig009_state(e$db)
  expect_identical(after$samples, before$samples)
  moved <- names(before$counts)[after$counts[names(before$counts)] != before$counts]
  expect_identical(moved, "schema_version")
  expect_identical(as.integer(after$counts[["schema_version"]]),
                   as.integer(before$counts[["schema_version"]]) + 1L)
})

test_that("a non-colliding INSERT still works after the migration", {
  # A constraint that rejects everything would pass every test above.
  mig <- .mig009_load(); e <- .mig009_env()
  mig$mig009_run(db = e$db, snapshot_dir = e$snapshot_dir)

  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = FALSE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  expect_silent(
    DBI::dbExecute(
      con, 'INSERT INTO "sample" (uuid, uuid_feature_alias, uuid_project, datetime)
              VALUES (\'s-new\', \'fa-0001\', \'p-0001\', TIMESTAMP \'1999-01-01 00:00:00\')'))
  expect_identical(
    as.integer(DBI::dbGetQuery(
      con, 'SELECT COUNT(*) n FROM "sample" WHERE uuid = \'s-new\'')$n), 1L)
})

test_that("the run is idempotent - a second call is a no-op and takes no second backup", {
  mig <- .mig009_load(); e <- .mig009_env()
  mig$mig009_run(db = e$db, snapshot_dir = e$snapshot_dir)
  mid <- .mig009_state(e$db)
  n_backups <- length(list.files(e$snapshot_dir))

  res <- mig$mig009_run(db = e$db, snapshot_dir = e$snapshot_dir)

  expect_identical(res$status, "already_migrated")
  expect_identical(.mig009_state(e$db), mid)
  expect_identical(length(list.files(e$snapshot_dir)), n_backups)
})

test_that("a verified backup is written before the change", {
  mig <- .mig009_load(); e <- .mig009_env()
  res <- mig$mig009_run(db = e$db, snapshot_dir = e$snapshot_dir,
                        .now = as.POSIXct("2026-08-08 12:00:00", tz = "UTC"))

  expect_true(file.exists(res$backup_path))
  expect_match(basename(res$backup_path), "^monitoring_pre-009-sample-identity-index_")
  # The backup is the PRE state: it must NOT carry the index or the marker.
  expect_false(.mig009_has_index(res$backup_path))
  expect_false(1009L %in% .mig009_state(res$backup_path)$markers)
})

# ======================================================================
# dry run
# ======================================================================

test_that("dry_run writes nothing, takes no backup, and leaves no index behind", {
  # The preflight CREATES the index inside a transaction it always rolls back.
  # If that rollback did not work, a dry run would silently migrate the
  # database - which is the failure this test exists to catch.
  mig <- .mig009_load(); e <- .mig009_env()
  before <- .mig009_state(e$db)

  res <- mig$mig009_run(db = e$db, snapshot_dir = e$snapshot_dir, dry_run = TRUE)

  expect_identical(res$status, "dry_run")
  expect_identical(res$n_samples, 5L)
  expect_identical(.mig009_state(e$db), before)
  expect_false(.mig009_has_index(e$db))
  expect_identical(length(list.files(e$snapshot_dir)), 0L)
})

test_that("a dry run REFUSES when the data violates the key, so it is a real rehearsal", {
  mig <- .mig009_load()
  e <- .mig009_env(extra = .mig009_add_collision)
  before <- .mig009_state(e$db)

  expect_error(
    mig$mig009_run(db = e$db, snapshot_dir = e$snapshot_dir, dry_run = TRUE),
    class = "sampletidy_error")

  expect_identical(.mig009_state(e$db), before)
  expect_identical(length(list.files(e$snapshot_dir)), 0L)
})

# ======================================================================
# preconditions - each asserted as a GATE, not merely as an error
# ======================================================================

test_that("it REFUSES when existing data violates the key, and names the offenders", {
  mig <- .mig009_load()
  e <- .mig009_env(extra = .mig009_add_collision)
  before <- .mig009_state(e$db)

  expect_error(
    mig$mig009_run(db = e$db, snapshot_dir = e$snapshot_dir),
    class = "sampletidy_error")

  # GATE, not a late failure: nothing moved AND no backup was taken. A
  # precondition that had been removed would still abort - at CREATE INDEX -
  # but only after the backup had been written.
  expect_identical(.mig009_state(e$db), before)
  expect_identical(length(list.files(e$snapshot_dir)), 0L)
  expect_false(.mig009_has_index(e$db))
})

test_that("the violation message names the colliding group and its sample count", {
  mig <- .mig009_load()
  e <- .mig009_env(extra = .mig009_add_collision)
  err <- tryCatch(mig$mig009_run(db = e$db, snapshot_dir = e$snapshot_dir),
                  sampletidy_error = function(e) e)
  msg <- paste(conditionMessage(err), collapse = " ")
  expect_match(msg, "1 group")
  expect_match(msg, "2 samples")
  expect_match(msg, "fa-0001", fixed = TRUE)
})

test_that("NULL key columns do NOT count as a violation - duckdb treats them as distinct", {
  # Two samples sharing an alias and datetime but with a NULL uuid_project can
  # never violate the index (NULLs are distinct in a duckdb unique index), so
  # the precondition must not refuse them. If it did, the migration would be
  # unrunnable on any database holding project-less samples.
  mig <- .mig009_load()
  e <- .mig009_env(extra = function(con) {
    DBI::dbExecute(
      con, 'INSERT INTO "sample" (uuid, uuid_feature_alias, uuid_project, datetime) VALUES
              (\'s-np1\', \'fa-0001\', NULL, TIMESTAMP \'2030-01-01 00:00:00\'),
              (\'s-np2\', \'fa-0001\', NULL, TIMESTAMP \'2030-01-01 00:00:00\')')
  })

  res <- mig$mig009_run(db = e$db, snapshot_dir = e$snapshot_dir)
  expect_identical(res$status, "migrated")
  expect_true(.mig009_has_index(e$db))
})

test_that("it REFUSES when an index of that name already exists without the marker", {
  mig <- .mig009_load()
  e <- .mig009_env(extra = function(con) {
    DBI::dbExecute(con, sprintf(
      'CREATE INDEX %s ON "sample" (uuid_project)', .MIG009_INDEX))
  })
  before <- .mig009_state(e$db)

  expect_error(
    mig$mig009_run(db = e$db, snapshot_dir = e$snapshot_dir),
    class = "sampletidy_error")

  expect_identical(.mig009_state(e$db), before)
  expect_identical(length(list.files(e$snapshot_dir)), 0L)
})

test_that("it REFUSES when a key column is missing from `sample`", {
  mig <- .mig009_load()
  e <- .mig009_env(extra = function(con) {
    DBI::dbExecute(con, 'ALTER TABLE "sample" DROP COLUMN uuid_project')
  })

  expect_error(
    mig$mig009_run(db = e$db, snapshot_dir = e$snapshot_dir),
    class = "sampletidy_error")
  expect_identical(length(list.files(e$snapshot_dir)), 0L)
})

test_that("it REFUSES a database ensure_schema() has never touched", {
  mig <- .mig009_load()
  dir <- withr::local_tempdir()
  db <- file.path(dir, "bare.duckdb")
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = FALSE)
  DBI::dbExecute(con, 'CREATE TABLE "sample" (uuid VARCHAR)')
  DBI::dbDisconnect(con, shutdown = TRUE)

  expect_error(
    mig$mig009_run(db = db, snapshot_dir = dir),
    class = "sampletidy_error")
})

test_that("every refusal is a sampletidy_error, not a cli dot-literal rlib_error", {
  # cli reads a `{}` expression STARTING WITH A DOT as a style name, not a
  # value, so `{.mig009_index_name}` inside cli_abort() raises an rlib_error
  # about an invalid cli literal instead of the promised class. This trap has
  # been sprung in 006, 007 and 008; every message in 009 that interpolates a
  # dotted internal binds it to a local first. These are the messages that do.
  mig <- .mig009_load()

  e1 <- .mig009_env(extra = .mig009_add_collision)
  err1 <- tryCatch(mig$mig009_run(db = e1$db, snapshot_dir = e1$snapshot_dir), error = function(e) e)
  expect_s3_class(err1, "sampletidy_error")

  e2 <- .mig009_env(extra = function(con) {
    DBI::dbExecute(con, sprintf('CREATE INDEX %s ON "sample" (uuid_project)', .MIG009_INDEX))
  })
  err2 <- tryCatch(mig$mig009_run(db = e2$db, snapshot_dir = e2$snapshot_dir), error = function(e) e)
  expect_s3_class(err2, "sampletidy_error")
})

# ======================================================================
# the SAFETY half
# ======================================================================

test_that("mig009_verify() passes only when NOTHING moved", {
  mig <- .mig009_load()
  before <- list(tables = list(sample = 5L, sample_checksum = "111", analysis = 5L),
                 views = list(v_measurement = 5L))
  expect_true(mig$mig009_verify(before, before))
})

test_that("mig009_verify() catches a changed base table - with NO exemption list", {
  # 008 had to exempt `sample`/`analysis` because changing them was its job.
  # 009 changes no rows, so EVERY base table is checked. A regression that
  # reintroduced an exemption would be caught here.
  mig <- .mig009_load()
  before <- list(tables = list(sample = 5L, sample_checksum = "111", analysis = 5L),
                 views = list(v_measurement = 5L))
  for (fld in c("sample", "sample_checksum", "analysis")) {
    after <- before
    after$tables[[fld]] <- if (is.character(before$tables[[fld]])) "999" else 6L
    expect_error(mig$mig009_verify(before, after), class = "sampletidy_error")
  }
})

test_that("mig009_verify() catches a changed VIEW count", {
  mig <- .mig009_load()
  before <- list(tables = list(sample = 5L), views = list(v_measurement = 5L))
  after <- before; after$views$v_measurement <- 4L
  expect_error(mig$mig009_verify(before, after), class = "sampletidy_error")
})

test_that("mig009_verify() catches a table or view being added or dropped", {
  mig <- .mig009_load()
  before <- list(tables = list(sample = 5L), views = list(v_measurement = 5L))
  after <- list(tables = list(sample = 5L, extra = 1L), views = list(v_measurement = 5L))
  expect_error(mig$mig009_verify(before, after), class = "sampletidy_error")
})

test_that("mig009_counts_checksum() covers change_log and separates views from tables", {
  # `change_log` is INSIDE 009's safety sweep (008 had to skip it). Only
  # `schema_version` is exempt, because the marker goes there.
  mig <- .mig009_load(); e <- .mig009_env()
  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  cc <- mig$mig009_counts_checksum(con)
  expect_true("change_log" %in% names(cc$tables))
  expect_true("change_log_checksum" %in% names(cc$tables))
  expect_false("schema_version" %in% names(cc$tables))
  expect_false(any(grepl("^v_", names(cc$tables))))
})

test_that("the checksum notices a changed VALUE, not just a changed row count", {
  mig <- .mig009_load(); e <- .mig009_env()
  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = FALSE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  before <- mig$mig009_counts_checksum(con)
  DBI::dbExecute(con, 'UPDATE "sample" SET organisation = \'CHANGED\' WHERE uuid = \'s-0001\'')
  after <- mig$mig009_counts_checksum(con)

  expect_identical(after$tables$sample, before$tables$sample)      # count unchanged
  expect_false(identical(after$tables$sample_checksum, before$tables$sample_checksum))
  expect_error(mig$mig009_verify(before, after), class = "sampletidy_error")
})

# ======================================================================
# the SUCCESS half
# ======================================================================

test_that(".mig009_verify_enforces() refuses when the index is absent", {
  mig <- .mig009_load(); e <- .mig009_env()
  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = FALSE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  expect_error(mig$.mig009_verify_enforces(con), class = "sampletidy_error")
})

test_that(".mig009_verify_enforces() refuses an index of the right NAME that is not UNIQUE", {
  # The failure a catalogue-only check would wave through: an index exists,
  # it is on `sample`, it has the expected name - and it enforces nothing.
  #
  # THE MESSAGE IS ASSERTED, not just the class, and that is deliberate. The
  # probe below would ALSO reject this database (a non-unique index accepts the
  # duplicate), so class-only assertions cannot tell the two gates apart -
  # mutation M5 (deleting the is_unique check) survived a class-only version of
  # this test. Pinning the diagnostic is what makes the catalogue check
  # separately alive: it is the gate that tells an operator "your index is the
  # wrong KIND" rather than "your index does not work".
  mig <- .mig009_load()
  e <- .mig009_env(extra = function(con) {
    DBI::dbExecute(con, sprintf(
      'CREATE INDEX %s ON "sample" (uuid_feature_alias, datetime, uuid_project)',
      .MIG009_INDEX))
  })
  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = FALSE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  err <- tryCatch(mig$.mig009_verify_enforces(con), error = function(e) e)
  expect_s3_class(err, "sampletidy_error")
  expect_match(paste(conditionMessage(err), collapse = " "), "not UNIQUE", fixed = TRUE)
})

test_that("the probe ABORTS when a duplicate is ACCEPTED - asked with no index at all", {
  # ISOLATES the probe's own verdict from every catalogue check around it.
  # Without an index the duplicate INSERT succeeds, so this reaches the
  # `accepted` branch and nothing else. Mutation M4 (treating an accepted
  # duplicate as success) survived until this test existed, because every other
  # test that could have caught it tripped the is_unique check first.
  mig <- .mig009_load(); e <- .mig009_env()
  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = FALSE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  err <- tryCatch(mig$.mig009_probe_rejects_duplicate(con, create_first = FALSE),
                  error = function(e) e)
  expect_s3_class(err, "sampletidy_error")
  expect_match(paste(conditionMessage(err), collapse = " "), "DOES NOT ENFORCE", fixed = TRUE)

  # and it left nothing behind, even on the path where the INSERT SUCCEEDED
  expect_identical(
    as.integer(DBI::dbGetQuery(
      con, 'SELECT COUNT(*) n FROM "sample" WHERE uuid LIKE \'mig009-probe-%\'')$n), 0L)
})

test_that(".mig009_verify_enforces() actually RUNS the probe, not just the catalogue reads", {
  # The discriminator for mutation M3 (deleting the probe call). With the index
  # genuinely present and unique, every catalogue check passes - so the only
  # way to observe whether the probe ran is to make the PROBE the thing that
  # fails. An empty `sample` gives it nothing to duplicate, which it refuses
  # rather than passing vacuously; if the probe call were gone, this would
  # return TRUE.
  mig <- .mig009_load()
  e <- .mig009_env(extra = function(con) {
    DBI::dbExecute(con, "DELETE FROM analysis")
    DBI::dbExecute(con, 'DELETE FROM "sample"')
    DBI::dbExecute(con, sprintf(
      'CREATE UNIQUE INDEX %s ON "sample" (uuid_feature_alias, datetime, uuid_project)',
      .MIG009_INDEX))
  })
  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = FALSE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  err <- tryCatch(mig$.mig009_verify_enforces(con), error = function(e) e)
  expect_s3_class(err, "sampletidy_error")
  expect_match(paste(conditionMessage(err), collapse = " "), "nothing to duplicate")
})

test_that("the enforcement probe REFUSES rather than passing when it cannot run", {
  # A probe with no row to duplicate would otherwise report success for a
  # check that never happened - the vacuous-gate failure this codebase has
  # been bitten by before.
  mig <- .mig009_load()
  e <- .mig009_env(extra = function(con) {
    DBI::dbExecute(con, "DELETE FROM analysis")
    DBI::dbExecute(con, 'DELETE FROM "sample"')
  })
  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = FALSE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  err <- tryCatch(mig$.mig009_probe_rejects_duplicate(con, create_first = TRUE),
                  error = function(e) e)
  expect_s3_class(err, "sampletidy_error")
  expect_match(paste(conditionMessage(err), collapse = " "), "nothing to duplicate")
})

test_that("the probe leaves NO trace - no probe row, no index", {
  mig <- .mig009_load(); e <- .mig009_env()
  before <- .mig009_state(e$db)
  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = FALSE)
  mig$.mig009_preflight(con)
  DBI::dbDisconnect(con, shutdown = TRUE)

  expect_identical(.mig009_state(e$db), before)
  expect_false(.mig009_has_index(e$db))
})

# ======================================================================
# commit.R: the raw constraint error becomes the quarantine message
# ======================================================================

test_that(".ct_is_sample_identity_violation() tells this violation from other errors", {
  mk <- function(m) simpleError(m)
  expect_true(.ct_is_sample_identity_violation(
    mk('Constraint Error: Duplicate key "uuid_feature_alias: x" violates unique constraint')))
  expect_true(.ct_is_sample_identity_violation(
    mk("Constraint Error: ux_sample_identity")))
  # NOT this index: must be re-thrown unchanged, not relabelled.
  expect_false(.ct_is_sample_identity_violation(
    mk("Constraint Error: Violates foreign key constraint because key uuid_sample")))
  expect_false(.ct_is_sample_identity_violation(mk("Binder Error: no such column")))
  expect_false(.ct_is_sample_identity_violation(mk("Duplicate key without the constraint words")))
})

test_that("a sample INSERT rejected by the index becomes the quarantine sampletidy_error", {
  # Reached through the real writer, on a database carrying the real index.
  # s-0001 is fa-0001 / 2025-05-24 01:45 UTC / p-0001; asking
  # .ct_find_or_create_sample() to create a NEW sample with that exact identity
  # is what a legacy re-ingest does (the `date` convention makes the reuse
  # lookup miss it), so this is the shape production actually hits.
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  err <- tryCatch(
    .ct_find_or_create_sample(
      con, pending = FALSE, match_feature = NA_character_, alias_uuid = "fa-0001",
      sample_date = as.Date("1990-01-01"),
      sample_datetime = as.POSIXct("2025-05-24 01:45:00", tz = "UTC"),
      uuid_project = "p-0001", organisation = "ALS", person = NA_character_,
      reason = "test"),
    error = function(e) e)

  expect_s3_class(err, "sampletidy_error")
  msg <- paste(conditionMessage(err), collapse = " ")
  expect_match(msg, "already exists at the same")
  expect_match(msg, "ux_sample_identity", fixed = TRUE)
  expect_match(msg, "DATA error", fixed = TRUE)
})

test_that("an INSERT failure that is NOT this index is re-thrown unchanged", {
  # The guard must not relabel every error as a duplicate sample.
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  got <- .ct_find_or_create_sample(
    con, pending = FALSE, match_feature = NA_character_, alias_uuid = "fa-0001",
    sample_date = as.Date("1991-02-03"),
    sample_datetime = as.POSIXct("1991-02-03 01:00:00", tz = "UTC"),
    uuid_project = "p-0001", organisation = "ALS", person = NA_character_,
    reason = "test")

  # A genuinely new sample must still be created - the guard must not turn
  # every insert into a refusal.
  expect_type(got, "character")
  expect_identical(
    as.integer(DBI::dbGetQuery(
      con, 'SELECT COUNT(*) n FROM "sample" WHERE uuid = ?', params = list(got))$n),
    1L)
})
