# Plan 14 - dev/migrations/002-registry-remediation.R (R-14.1, R-14.2).
# R-14.3 is CLOSED (no write, no test, no code - PLAN-14-registry-remediation.md):
# the 12 `Ammonia as NH3` analyses are already correct, and this file's job is
# to PROVE they stay that way (the row-count-and-checksum invariant below),
# never to touch them.
#
# TARGET FILE CONTRACT (the target file is TDD-red/unwritten; this is the
# interface Phase 6 must implement so these tests pass - not part of the
# package NAMESPACE, so tests `sys.source()` it directly, mirroring
# test-migration-001.R's idiom exactly):
#
#   mig002_run(db, snapshot_dir, actor = "migration-002", dry_run = FALSE, .now = NULL)
#     -> invisible list(
#          status = "migrated" | "already_migrated" | "dry_run",
#          backup_path = chr or NA, restore_command = chr or NA,
#          carbophenothion = list(
#            merged   = logical(1),        # TRUE iff a merge happened THIS run
#            survivor = chr(1),            # uuid kept
#            deleted  = chr(1) or NA_character_  # uuid removed; NA if already gone
#          ),
#          reported_as = list(
#            matched_count  = int(1),      # lab_method rows whose name matched
#            unmatched      = data.frame(uuid, name),      # non-matching names
#            outside_seven  = data.frame(uuid, name, reported_as)  # matched,
#              # NOT one of the seven enumerated names - reported_as IS set,
#              # conversion_constant is NOT
#          )
#        )
#     Runs the R-14.1 merge (with its existence pre-check, CONTRACT A72) and
#     the R-14.2 backfill inside one call, same backup/verify/transaction
#     discipline as 001 (brief "Which database" block). Every write goes
#     through db_update()/db_delete() (R/mutate.R) - never raw SQL.
#
# Every test sources the target file inside its own `test_that()` (never at
# file top level), so a missing/broken target file surfaces as an ordinary
# per-test failure - not a whole-file collection error that would silently
# zero out every other test's coverage. Same for `.mig001_load()`: P14
# explicitly depends on P13 (R-14.2 writes lab_method.units/conversion_constant,
# which do not exist pre-migration), and the brief's Fixtures block requires
# running against PLAN-13's *actual migrated output*, never a hand-built
# post-migration DDL - so every test here is also gated on 001 existing.

.mig002_load <- function() {
  env <- new.env(parent = globalenv())
  path <- testthat::test_path("..", "..", "dev", "migrations", "002-registry-remediation.R")
  sys.source(path, envir = env)
  env
}

.mig001_load <- function() {
  env <- new.env(parent = globalenv())
  path <- testthat::test_path("..", "..", "dev", "migrations", "001-alias-indirection.R")
  sys.source(path, envir = env)
  env
}

#' Seed a DB carrying both this plan's fixtures, already migrated by 001
#'
#' Fixtures block (brief): "Run this plan against the migrated output of
#' PLAN-13's script, not against a hand-built post-migration DDL - the
#' dependency is real and testing around it would hide a step-9 FK mistake."
#'
#' Threads the CALLING TEST's frame through explicitly (language-footguns.md
#' R section: the wrong-frame trap) - a bare/default-arg `withr::local_tempdir()`
#' here would bind cleanup to this helper's own frame and tear the dir down
#' the instant it returns, before the test body runs.
#'
#' @param dir directory to hold the DB file (defaults to a fresh withr temp
#'   dir scoped to the calling test).
#' @return path to the seeded, migrated (via 001), closed DuckDB file.
.seed_002_db <- function(dir = NULL) {
  if (is.null(dir)) dir <- withr::local_tempdir(.local_envir = parent.frame())
  path <- seed_pre_migration_db(dir = dir)

  con <- pre_migration_con(path)
  seed_carbophenothion_duplicate(con)
  seed_reported_as_fixture(con)
  DBI::dbDisconnect(con, shutdown = TRUE)

  mig1 <- .mig001_load()
  mig1$mig001_run(
    db = path,
    snapshot_dir = withr::local_tempdir(.local_envir = parent.frame()),
    dry_run = FALSE
  )

  path
}

#' Snapshot the whole `analysis` table (uuid, value, quantified, rl_low),
#' ordered for a stable diff - the row-count-and-value-checksum invariant
#' both R-14.1 and R-14.2 pin, done directly (no bespoke checksum function
#' needed in the target file - a full before/after table diff IS the
#' checksum).
.analysis_snapshot <- function(con) {
  DBI::dbGetQuery(con, "
    SELECT uuid, uuid_sample, uuid_lab, value, quantified, rl_low
    FROM analysis ORDER BY uuid")
}

# =============================================================================
# R-14.1: merge the duplicate Carbophenothion analyte rows
# =============================================================================

test_that("R-14.1: exactly one Carbophenothion analyte row remains after the merge, and it is the survivor", {
  mig2 <- .mig002_load()
  path <- .seed_002_db()

  mig2$mig002_run(db = path, snapshot_dir = withr::local_tempdir(), dry_run = FALSE)

  con <- pre_migration_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  rows <- DBI::dbGetQuery(con, "SELECT uuid FROM analyte WHERE name = 'Carbophenothion'")
  expect_identical(nrow(rows), 1L)
  expect_identical(rows$uuid, "carb-survivor")
  expect_false("carb-doomed" %in% DBI::dbGetQuery(con, "SELECT uuid FROM analyte")$uuid)
})

test_that("R-14.1: the doomed lab_method row is repointed (not dropped), so all 5 Carbophenothion analyses resolve to the survivor", {
  mig2 <- .mig002_load()
  path <- .seed_002_db()

  con0 <- pre_migration_con(path)
  n_before <- DBI::dbGetQuery(con0, "
    SELECT COUNT(*) n FROM analysis a JOIN lab_method lm ON a.uuid_lab = lm.uuid
    WHERE lm.uuid_analyte = 'carb-survivor'")$n
  DBI::dbDisconnect(con0, shutdown = TRUE)
  expect_equal(n_before, 3L) # only the survivor's own 3, pre-merge

  mig2$mig002_run(db = path, snapshot_dir = withr::local_tempdir(), dry_run = FALSE)

  con <- pre_migration_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  # Both lab_method rows still exist (repoint, not delete) - only the doomed
  # ANALYTE row is gone.
  lm_rows <- DBI::dbGetQuery(con, "SELECT uuid, uuid_analyte FROM lab_method WHERE uuid IN ('lm-carb-survivor', 'lm-carb-doomed') ORDER BY uuid")
  expect_identical(nrow(lm_rows), 2L)
  expect_true(all(lm_rows$uuid_analyte == "carb-survivor"))

  n_after <- DBI::dbGetQuery(con, "
    SELECT COUNT(*) n FROM analysis a JOIN lab_method lm ON a.uuid_lab = lm.uuid
    WHERE lm.uuid_analyte = 'carb-survivor'")$n
  expect_equal(n_after, 5L) # 3 + 2, the merge criterion's arithmetic
})

test_that("R-14.1: the doomed uuid's colliding 'long' mask is deduped (deleted, not repointed) and its non-colliding 'EPA' mask is repointed, none left dangling and no duplicate on the survivor", {
  mig2 <- .mig002_load()
  path <- .seed_002_db()

  mig2$mig002_run(db = path, snapshot_dir = withr::local_tempdir(), dry_run = FALSE)

  con <- pre_migration_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  # No analyte_mask row references the deleted uuid, whether its variant was
  # deduped (deleted) or repointed - R-14.1's "no dangling reference" holds
  # for either branch of the per-variant conditional.
  dangling <- DBI::dbGetQuery(con, "SELECT * FROM analyte_mask WHERE uuid_analyte = 'carb-doomed'")
  expect_identical(nrow(dangling), 0L)

  survivor_rows <- DBI::dbGetQuery(
    con, "SELECT uuid_analyte, variant, name FROM analyte_mask WHERE uuid_analyte = 'carb-survivor' ORDER BY variant"
  )
  expect_identical(nrow(survivor_rows), 2L)
  expect_setequal(survivor_rows$variant, c("EPA", "long"))

  # Mask-collision dedup (Phase-8a): blind repoint - the bug this
  # remediation fixes - would leave the survivor with TWO 'long' rows. This
  # is the non-vacuous duplicate check: no (uuid_analyte, variant) pair
  # appears twice on the survivor.
  expect_identical(
    anyDuplicated(paste(survivor_rows$uuid_analyte, survivor_rows$variant)), 0L
  )

  # The survivor's OWN 'long' row wins - it is not overwritten by the
  # doomed's colliding 'long' row (the doomed's is deleted, not repointed).
  long_row <- survivor_rows[survivor_rows$variant == "long", ]
  expect_identical(long_row$name, "Carbophenothion (survivor long)")

  # 'EPA' has no collision, so it IS repointed from the doomed row. The
  # NULL-name row (the live shape quoted in the plan block) survives the
  # repoint as NULL, not coerced into a spurious value - NA-safe assertion,
  # never `== NULL`.
  epa_row <- survivor_rows[survivor_rows$variant == "EPA", ]
  expect_true(is.na(epa_row$name))
})

test_that("R-14.1: no analysis row is touched by the merge (row-count and value-checksum invariant)", {
  mig2 <- .mig002_load()
  path <- .seed_002_db()

  con0 <- pre_migration_con(path)
  before <- .analysis_snapshot(con0)
  DBI::dbDisconnect(con0, shutdown = TRUE)

  mig2$mig002_run(db = path, snapshot_dir = withr::local_tempdir(), dry_run = FALSE)

  con <- pre_migration_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  after <- .analysis_snapshot(con)

  expect_identical(after, before)
})

test_that("R-14.1: a v_measurement-equivalent join (analysis -> lab_method -> analyte) has the same row count before and after the merge", {
  mig2 <- .mig002_load()
  path <- .seed_002_db()

  join_sql <- "
    SELECT COUNT(*) n FROM analysis a
    JOIN lab_method lm ON a.uuid_lab = lm.uuid
    JOIN analyte an ON lm.uuid_analyte = an.uuid"

  con0 <- pre_migration_con(path)
  n_before <- DBI::dbGetQuery(con0, join_sql)$n
  DBI::dbDisconnect(con0, shutdown = TRUE)

  mig2$mig002_run(db = path, snapshot_dir = withr::local_tempdir(), dry_run = FALSE)

  con <- pre_migration_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  n_after <- DBI::dbGetQuery(con, join_sql)$n

  expect_identical(n_after, n_before) # a merge must not hide or reveal a measurement
})

test_that("R-14.1: change_log records the analyte delete, the lab_method repoint, the 'EPA' mask repoint and the 'long' mask dedup-delete", {
  mig2 <- .mig002_load()
  path <- .seed_002_db()

  mig2$mig002_run(db = path, snapshot_dir = withr::local_tempdir(), dry_run = FALSE)

  con <- pre_migration_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  del <- DBI::dbGetQuery(con, "
    SELECT * FROM change_log WHERE tbl = 'analyte' AND action = 'delete' AND uuid_row = 'carb-doomed'")
  expect_identical(nrow(del), 1L)

  lm_update <- DBI::dbGetQuery(con, "
    SELECT * FROM change_log
    WHERE tbl = 'lab_method' AND action = 'update' AND uuid_row = 'lm-carb-doomed'
      AND field = 'uuid_analyte'")
  expect_identical(nrow(lm_update), 1L)
  expect_identical(lm_update$old, "carb-doomed")
  expect_identical(lm_update$new, "carb-survivor")

  # 'EPA' has no collision with the survivor, so it is repointed (update) -
  # asserted on new = 'carb-survivor' (analyte_mask has no `uuid` column of
  # its own, so identity is on old/new value rather than a single uuid_row).
  mask_update <- DBI::dbGetQuery(con, "
    SELECT * FROM change_log
    WHERE tbl = 'analyte_mask' AND action = 'update' AND new = 'carb-survivor'")
  expect_identical(nrow(mask_update), 1L)

  # 'long' collides with the survivor's own 'long' row, so the doomed's is
  # deduped via a DELETE, not an update-repoint (the mask-collision-dedup
  # fix). `db_delete()` called with a `key=` (no single `uuid`) logs
  # `uuid_row = NA` - do not over-constrain it to a specific uuid value.
  mask_delete <- DBI::dbGetQuery(con, "
    SELECT * FROM change_log WHERE tbl = 'analyte_mask' AND action = 'delete'")
  expect_identical(nrow(mask_delete), 1L)
  expect_true(is.na(mask_delete$uuid_row))
  expect_true(grepl("dedup", mask_delete$reason, ignore.case = TRUE))

  # Exactly one repoint (EPA) and one dedup-delete (long) - never both a
  # repoint and a delete for the same variant, and never two repoints (the
  # blind-loop bug this remediation fixes).
  expect_identical(nrow(mask_update) + nrow(mask_delete), 2L)
})

test_that("R-14.1: a second run is idempotent via the existence pre-check - no abort, and no further writes", {
  mig2 <- .mig002_load()
  path <- .seed_002_db()

  r1 <- mig2$mig002_run(db = path, snapshot_dir = withr::local_tempdir(), dry_run = FALSE)
  expect_true(isTRUE(r1$carbophenothion$merged))

  con <- pre_migration_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  n_log_after_1 <- DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM change_log")$n
  state_after_1 <- DBI::dbGetQuery(con, "SELECT uuid, uuid_analyte FROM lab_method ORDER BY uuid")

  # CONTRACT A72: db_delete() on a nonexistent uuid ABORTS. A naive re-run
  # would therefore throw - the whole point of the pre-check.
  expect_no_error({
    r2 <- mig2$mig002_run(db = path, snapshot_dir = withr::local_tempdir(), dry_run = FALSE)
  })
  expect_false(isTRUE(r2$carbophenothion$merged))
  expect_identical(r2$carbophenothion$deleted, NA_character_)

  n_log_after_2 <- DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM change_log")$n
  expect_identical(n_log_after_2, n_log_after_1)

  state_after_2 <- DBI::dbGetQuery(con, "SELECT uuid, uuid_analyte FROM lab_method ORDER BY uuid")
  expect_identical(state_after_2, state_after_1)
})

test_that("Phase-8b: a torn prior run (unpaired FK detach in change_log) makes mig002_run() abort loudly instead of silently reporting success", {
  mig2 <- .mig002_load()
  path <- .seed_002_db()

  # Simulate a crash mid-merge, THE WAY THE MIGRATION ITSELF WOULD: a real
  # db_update() detach of one of the doomed lab_method's dependent `analysis`
  # rows, using the migration's own detach-reason constant, with no matching
  # reattach - an unpaired detach left in `change_log`, exactly what a
  # process crash between the detach and reattach steps would leave behind.
  with_db_write(function(con) {
    db_update(
      con, "analysis", uuid = "an-carb-d1",
      changes = list(uuid_lab = NA_character_), actor = "test-crash-sim",
      reason = paste(
        "PLAN-14 R-14.1: merge duplicate Carbophenothion analyte",
        mig2$.mig002_detach_reason
      )
    )
  }, db = path)

  con0 <- pre_migration_con(path)
  before_row <- DBI::dbGetQuery(con0, "SELECT uuid_lab FROM analysis WHERE uuid = 'an-carb-d1'")
  DBI::dbDisconnect(con0, shutdown = TRUE)
  expect_true(is.na(before_row$uuid_lab))

  err <- tryCatch(
    mig2$mig002_run(db = path, snapshot_dir = withr::local_tempdir(), dry_run = FALSE),
    error = function(e) e
  )
  expect_true(inherits(err, "sampletidy_error"))
  expect_true(grepl("interrupt", conditionMessage(err), ignore.case = TRUE))
  expect_true(grepl("restore", conditionMessage(err), ignore.case = TRUE))
  expect_true(grepl("backup", conditionMessage(err), ignore.case = TRUE))

  # The aborted run must leave the torn row exactly as it was found - still
  # NA, never further mangled (no partial "recovery" attempt).
  con <- pre_migration_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  after_row <- DBI::dbGetQuery(con, "SELECT uuid_lab FROM analysis WHERE uuid = 'an-carb-d1'")
  expect_true(is.na(after_row$uuid_lab))
})

# =============================================================================
# R-14.2: backfill reported_as / conversion_constant
# =============================================================================

test_that("R-14.2: sets reported_as for each of the seven enumerated lab_method names, with conversion_constant NA except Ammonia as NH3", {
  mig2 <- .mig002_load()
  path <- .seed_002_db()

  mig2$mig002_run(db = path, snapshot_dir = withr::local_tempdir(), dry_run = FALSE)

  con <- pre_migration_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  seven <- DBI::dbGetQuery(con, "
    SELECT uuid, name, reported_as, conversion_constant FROM lab_method
    WHERE uuid IN ('lm-nh-n', 'lm-nh-nh3', 'lm-alk-total', 'lm-alk-bicarb',
                    'lm-alk-carb', 'lm-alk-hydrox', 'lm-hardness')")
  rows <- setNames(split(seven, seq_len(nrow(seven))), seven$uuid)

  expect_identical(rows[["lm-nh-n"]]$reported_as, "N")
  expect_true(is.na(rows[["lm-nh-n"]]$conversion_constant))

  expect_identical(rows[["lm-nh-nh3"]]$reported_as, "NH3")
  expect_equal(rows[["lm-nh-nh3"]]$conversion_constant, 0.8224428, tolerance = 1e-9)

  for (u in c("lm-alk-total", "lm-alk-bicarb", "lm-alk-carb", "lm-alk-hydrox", "lm-hardness")) {
    expect_identical(rows[[u]]$reported_as, "CaCO3", info = u)
    expect_true(is.na(rows[[u]]$conversion_constant), info = u)
  }
})

test_that("R-14.2: a non-matching lab_method name leaves reported_as NULL and appears in the reported unmatched set", {
  mig2 <- .mig002_load()
  path <- .seed_002_db()

  result <- mig2$mig002_run(db = path, snapshot_dir = withr::local_tempdir(), dry_run = FALSE)

  con <- pre_migration_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  lm901 <- DBI::dbGetQuery(con, "SELECT reported_as FROM lab_method WHERE uuid = 'lm-901'")
  expect_true(is.na(lm901$reported_as))

  expect_true("lm-901" %in% result$reported_as$unmatched$uuid)
})

test_that("R-14.2: a matched name outside the enumerated seven gets reported_as set but NO invented conversion_constant, and is reported separately", {
  mig2 <- .mig002_load()
  path <- .seed_002_db()

  result <- mig2$mig002_run(db = path, snapshot_dir = withr::local_tempdir(), dry_run = FALSE)

  con <- pre_migration_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  zn <- DBI::dbGetQuery(con, "SELECT reported_as, conversion_constant FROM lab_method WHERE uuid = 'lm-zn-extra'")
  expect_identical(zn$reported_as, "Zn") # the regex still captures the token
  expect_true(is.na(zn$conversion_constant)) # but no constant is invented

  expect_true("lm-zn-extra" %in% result$reported_as$outside_seven$uuid)
  # It must NOT be reported as merely "unmatched" - its name DID match.
  expect_false("lm-zn-extra" %in% result$reported_as$unmatched$uuid)
})

test_that("R-14.2: no analysis.value is altered by the backfill - row-count and value-checksum invariant over analysis before vs after", {
  mig2 <- .mig002_load()
  path <- .seed_002_db()

  con0 <- pre_migration_con(path)
  before <- .analysis_snapshot(con0)
  DBI::dbDisconnect(con0, shutdown = TRUE)

  mig2$mig002_run(db = path, snapshot_dir = withr::local_tempdir(), dry_run = FALSE)

  con <- pre_migration_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  after <- .analysis_snapshot(con)

  expect_identical(after, before)
})

test_that("R-14.2/R-14.3: the existing Ammonia-as-NH3 analysis keeps its exact stored value (1.76002759) - the backfill records the constant, it does not re-apply it", {
  mig2 <- .mig002_load()
  path <- .seed_002_db()

  con0 <- pre_migration_con(path)
  before_val <- DBI::dbGetQuery(con0, "SELECT value FROM analysis WHERE uuid = 'an-nh3-existing'")$value
  DBI::dbDisconnect(con0, shutdown = TRUE)
  expect_equal(before_val, 1.76002759, tolerance = 1e-9)

  mig2$mig002_run(db = path, snapshot_dir = withr::local_tempdir(), dry_run = FALSE)

  con <- pre_migration_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  after_val <- DBI::dbGetQuery(con, "SELECT value FROM analysis WHERE uuid = 'an-nh3-existing'")$value

  # Exact, not merely close: re-applying 0.8224428 a second time would move
  # this by ~18% (R-14.3's "double-converted" failure mode) - a tolerant
  # comparison would not catch that.
  expect_identical(after_val, before_val)
})

test_that("R-14.2: the backfill is idempotent - a second run changes nothing further", {
  mig2 <- .mig002_load()
  path <- .seed_002_db()

  mig2$mig002_run(db = path, snapshot_dir = withr::local_tempdir(), dry_run = FALSE)

  con <- pre_migration_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  state_after_1 <- DBI::dbGetQuery(con, "SELECT uuid, reported_as, conversion_constant FROM lab_method ORDER BY uuid")
  n_log_after_1 <- DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM change_log")$n

  mig2$mig002_run(db = path, snapshot_dir = withr::local_tempdir(), dry_run = FALSE)

  state_after_2 <- DBI::dbGetQuery(con, "SELECT uuid, reported_as, conversion_constant FROM lab_method ORDER BY uuid")
  n_log_after_2 <- DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM change_log")$n

  expect_identical(state_after_2, state_after_1)
  expect_identical(n_log_after_2, n_log_after_1)
})

test_that("R-14.2: change_log records provenance for every reported_as/conversion_constant write, including the Ammonia-as-NH3 constant", {
  mig2 <- .mig002_load()
  path <- .seed_002_db()

  mig2$mig002_run(db = path, snapshot_dir = withr::local_tempdir(), dry_run = FALSE)

  con <- pre_migration_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  reported_as_writes <- DBI::dbGetQuery(con, "
    SELECT * FROM change_log WHERE tbl = 'lab_method' AND field = 'reported_as'")
  # The 8 matched rows (seven enumerated + the outside-seven Zn row) - every
  # MATCHED name is written, per R-14.2's criterion text.
  expect_identical(nrow(reported_as_writes), 8L)

  const_write <- DBI::dbGetQuery(con, "
    SELECT * FROM change_log
    WHERE tbl = 'lab_method' AND field = 'conversion_constant' AND uuid_row = 'lm-nh-nh3'")
  expect_identical(nrow(const_write), 1L)
  expect_equal(as.numeric(const_write$new), 0.8224428, tolerance = 1e-9)
})

# =============================================================================
# Mutation-layer / no-raw-SQL gate (brief "Which database" block)
# =============================================================================

#' Strip line comments and string literals before matching (phase4-test-
#' authoring.md meta-test rule) - never a raw line-grep.
.strip_r_source <- function(lines) {
  stripped <- vapply(lines, function(l) {
    l <- sub("#.*$", "", l)
    l <- gsub('"[^"]*"', "", l)
    l <- gsub("'[^']*'", "", l)
    l
  }, character(1))
  paste(stripped, collapse = "\n")
}

test_that("meta: the comment/string-stripping guard does not trip on a decoy mentioning the forbidden calls only in prose", {
  decoy <- c(
    "# NEVER call dbExecute(), dbSendStatement(), dbAppendTable() or dbWriteTable() here.",
    "x <- \"dbExecute() is forbidden in this file\"",
    "y <- 'dbAppendTable is also forbidden'",
    "z <- db_update(con, 'lab_method', uuid, changes, actor, reason)"
  )
  src <- .strip_r_source(decoy)
  expect_false(grepl("dbExecute|dbSendStatement|dbAppendTable|dbWriteTable", src))
})

test_that("R-14 gate: dev/migrations/002-registry-remediation.R never calls a raw DB write function", {
  target <- testthat::test_path("..", "..", "dev", "migrations", "002-registry-remediation.R")
  skip_if_not(file.exists(target), "dev/migrations/002-registry-remediation.R not yet written (expected pre-Phase-6)")

  lines <- readLines(target, warn = FALSE)
  src <- .strip_r_source(lines)

  hit <- regmatches(src, regexpr("dbExecute|dbSendStatement|dbAppendTable|dbWriteTable", src))
  expect_identical(
    length(hit) > 0 && nzchar(hit), FALSE,
    label = "raw DB write call found in 002-registry-remediation.R"
  )
})

# =============================================================================
# R-14.2 provisional oracle (Phase-3 D5) - re-check in Phase 6 against real
# output. `ES2415638_0_XTAB.csv` is real corpus data (A3 forbids committing
# it), so this is a skip-guarded gate, never a synthesised fixture carrying
# the same numbers (that would prove the arithmetic against itself, not
# against the live data - the entire point of this gate per the brief).
# =============================================================================

test_that("PROVISIONAL ORACLE R-14.2: re-ingesting ES2415638_0_XTAB.csv after the backfill reproduces 2.14 x 0.8224428 = 1.76002759, reports already_present, and opens no value_conflict", {
  skip_if_no_corpus()
  db_copy_src <- corpus_db_path()
  if (identical(db_copy_src, "") || !file.exists(db_copy_src)) {
    testthat::skip("SAMPLETIDY_CORPUS_DB not set to an existing file - real-DB re-ingest oracle skipped (A3, narrower opt-in)")
  }

  # Location per the plan block (R-14.3): a sibling `assets/processed/<uuid>/`
  # of the DB's own directory - not committed anywhere, so this is a
  # best-effort resolution; skip (never fail) if the environment differs.
  asset_path <- file.path(
    dirname(db_copy_src), "assets", "processed",
    "08f1555c-18be-4167-a051-ba4f9fedea09", "ES2415638_0_XTAB.csv"
  )
  if (!file.exists(asset_path)) {
    testthat::skip(paste(
      "ES2415638_0_XTAB.csv not found at the expected asset path -",
      "PROVISIONAL ORACLE, re-check location in Phase 6:", asset_path
    ))
  }

  dest_dir <- withr::local_tempdir()
  db_copy <- file.path(dest_dir, basename(db_copy_src))
  file.copy(db_copy_src, db_copy)

  mig1 <- .mig001_load()
  mig2 <- .mig002_load()
  snap_dir <- withr::local_tempdir()
  mig1$mig001_run(db = db_copy, snapshot_dir = snap_dir, dry_run = FALSE)
  mig2$mig002_run(db = db_copy, snapshot_dir = snap_dir, dry_run = FALSE)

  input_dir <- withr::local_tempdir()
  file.copy(asset_path, file.path(input_dir, basename(asset_path)))

  review_before <- {
    con <- DBI::dbConnect(duckdb::duckdb(), db_copy, read_only = TRUE)
    n <- DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM review_queue WHERE kind = 'value_conflict'")$n
    DBI::dbDisconnect(con, shutdown = TRUE)
    n
  }

  report <- ingest_dir(input_dir, db = db_copy, dry_run = FALSE)

  expect_identical(report$rows_new, 0L)
  testthat::expect(
    report$rows_already_present > 0,
    failure_message = paste0(
      "re-ingest after the R-14.2 backfill found no already_present rows ",
      "(new=", report$rows_new, ", already_present=", report$rows_already_present, ")"
    )
  )

  con <- DBI::dbConnect(duckdb::duckdb(), db_copy, read_only = TRUE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  review_after <- DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM review_queue WHERE kind = 'value_conflict'")$n
  expect_identical(review_after, review_before) # no NEW value_conflict opened

  stored <- DBI::dbGetQuery(con, "
    SELECT a.value FROM analysis a
    JOIN lab_method lm ON a.uuid_lab = lm.uuid
    WHERE lm.reported_as = 'NH3' AND ABS(a.value - 1.76002759) < 1e-6")
  expect_true(nrow(stored) >= 1)
})
