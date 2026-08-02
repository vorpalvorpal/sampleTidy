# dev/migrations/005-preference-rank.R - the A75/A79 read-time preference
# (field beats lab; among lab, ALS beats ACIRL), exposed as a `preference_rank`
# column on the 5 reporting views.
#
#   mig005_run(db, snapshot_dir, dry_run = FALSE, .now = NULL)
#     -> invisible list(status = "migrated" | "already_migrated" | "dry_run",
#        backup_path = chr or NA, restore_command = chr or NA, ...)
#
# Every test sources the target file inside its own `test_that()` (never at
# file top level), so a missing/broken target surfaces as ordinary per-test
# failures rather than a whole-file collection error that would silently zero
# out every other test's coverage - test-migration-004.R's Phase-5 audit
# finding B5, kept.
#
# Every test runs 001 -> 004 -> 005 against a real seeded DB rather than a
# hand-built post-004 DDL: 005 rebuilds 004's OWN views and must carry every
# column 004 restored, so testing against a hand-written approximation of 004's
# output is exactly the shape that would hide a regression in that projection.

.mig005_load <- function() {
  env <- new.env(parent = globalenv())
  path <- testthat::test_path("..", "..", "dev", "migrations", "005-preference-rank.R")
  if (!file.exists(path)) {
    stop(sprintf("migration file not found: %s", path))
  }
  sys.source(path, envir = env)
  env
}

.mig005_load_001 <- function() {
  env <- new.env(parent = globalenv())
  path <- testthat::test_path("..", "..", "dev", "migrations", "001-alias-indirection.R")
  skip_if_not(file.exists(path), "dev/migrations not in built package (run via devtools::test)")
  sys.source(path, envir = env)
  env
}

.mig005_load_004 <- function() {
  env <- new.env(parent = globalenv())
  path <- testthat::test_path("..", "..", "dev", "migrations", "004-view-repair.R")
  skip_if_not(file.exists(path), "dev/migrations not in built package (run via devtools::test)")
  sys.source(path, envir = env)
  env
}

#' Seed the ranking fixture: six partitions, each isolating one way the rank
#' can be got wrong
#'
#' Every partition is deliberately NON-VACUOUS - the expected winner is chosen
#' so that a rank computed WITHOUT the rule under test would name a different
#' row. Where that could not be arranged (P5) the comment says so and the test
#' pins a different observable instead.
#'
#' Analysis uuids are chosen for their SORT ORDER, because `a.uuid` is the
#' migration's final tiebreak: a fixture whose expected winner also happens to
#' sort first proves nothing about the keys above it.
#'
#' | partition | isolates | expected rank 1 |
#' |---|---|---|
#' | P1 (f-301, Sydney 2024-07-01) | partition on the DATE, not the datetime | `an-312` (field) |
#' | P2 (f-301, Sydney 2024-07-02) | the SYDNEY date, not a naive UTC cast | `an-322` (field) |
#' | P3 (f-302, 2024-07-03) | ALS beats ACIRL among lab rows | `an-332` (ALS) |
#' | P4 (f-303, 2024-07-04) | `EN67 - Client Supplied Data` ranks as FIELD | `an-341` (EN67) |
#' | P5 (f-304, 2024-07-05) | a NULL `method` is not a field reading | `an-351` (ALS lab) |
#' | P6 (f-305, 2024-07-06) | two field rows tie -> broken stably by uuid | `an-361` |
#'
#' f-301 also carries an `EPA` mask (uppercase - the case production stores,
#' per 004's B-15.F12(a)), so P1/P2 are visible in `v_measurement_epa` and the
#' mask views' own ranks can be checked. It is additionally what makes 005's
#' verify gate reachable at all: `.mig005_verify_views()` refuses a zero
#' base-table count for every one of the 5 views, and
#' `seed_pre_migration_db()`'s only `epa` mask (f-104) is sample-free.
#'
#' @param con an open read-write DBI connection to a DB seeded by
#'   `seed_pre_migration_db()`, BEFORE 001 runs (rows use the pre-migration
#'   `sample.uuid_feature` column).
#' @return invisible(NULL).
.seed_005_rank_fixture <- function(con) {
  DBI::dbExecute(con, "INSERT INTO feature
    (uuid, name, site, flow, matrix, lon, lat, cypher) VALUES
    ('f-301', 'PM-RANK-1', 'PreMigSite', 'surface', 'water', 150.3001, -33.3001, NULL),
    ('f-302', 'PM-RANK-2', 'PreMigSite', 'surface', 'water', 150.3002, -33.3002, NULL),
    ('f-303', 'PM-RANK-3', 'PreMigSite', 'surface', 'water', 150.3003, -33.3003, NULL),
    ('f-304', 'PM-RANK-4', 'PreMigSite', 'surface', 'water', 150.3004, -33.3004, NULL),
    ('f-305', 'PM-RANK-5', 'PreMigSite', 'surface', 'water', 150.3005, -33.3005, NULL)")

  DBI::dbExecute(con, "INSERT INTO feature_mask (uuid_feature, variant, name) VALUES
    ('f-301', 'EPA', 'EPA-PM-RANK-1')")

  # All on analyte `a-901` (seed_pre_migration_db()'s own), so every row of a
  # partition shares an analyte and the partitions are real.
  DBI::dbExecute(con, "INSERT INTO lab_method
    (uuid, uuid_analyte, name, method, organisation, rl_low) VALUES
    ('lm-fld-acirl',  'a-901', 'Analyte X field',  'field',                       'ACIRL', NULL),
    ('lm-lab-als',    'a-901', 'Analyte X by IC',  'EK-X',                        'ALS',   0.1),
    ('lm-lab-acirl',  'a-901', 'Analyte X ACIRL',  'EK-X-ACIRL',                  'ACIRL', 0.1),
    ('lm-en67-als',   'a-901', 'Analyte X client', 'EN67 - Client Supplied Data', 'ALS',   NULL),
    ('lm-null-acirl', 'a-901', 'Analyte X (na)',   NULL,                          'ACIRL', NULL)")

  # ---- P1: one visit, two clocks. 00:00 and 00:01 UTC are 10:00 and 10:01
  # Sydney on 2024-07-01 - the live shape (measured: 54 of the 931 contested
  # partitions look exactly like this). Keyed on `datetime` these are two
  # partitions of one and BOTH rank 1; keyed on the Sydney date they are one
  # partition and the field row wins.
  # `an-311` (lab) sorts BEFORE `an-312` (field), so a rank that ignored
  # `is_field` would name an-311. ----
  DBI::dbExecute(con, "INSERT INTO \"sample\"
    (uuid, uuid_feature, date, datetime, organisation) VALUES
    ('s-311', 'f-301', TIMESTAMP '2024-07-01 00:00:00', TIMESTAMP '2024-07-01 00:00:00', 'ALS'),
    ('s-312', 'f-301', TIMESTAMP '2024-07-01 00:00:00', TIMESTAMP '2024-07-01 00:01:00', 'ACIRL')")
  DBI::dbExecute(con, "INSERT INTO analysis
    (uuid, uuid_sample, uuid_lab, value, quantified, rl_low) VALUES
    ('an-311', 's-311', 'lm-lab-als',   7.10, TRUE, 0.1),
    ('an-312', 's-312', 'lm-fld-acirl', 7.20, TRUE, NULL)")

  # ---- P2: 2024-07-01 23:00 UTC and 2024-07-02 01:00 UTC are 09:00 and 11:00
  # Sydney on the SAME day, 2024-07-02 (UTC+10 in July, no DST). Their NAIVE
  # calendar dates differ, so a timezone-naive `CAST(datetime AS DATE)`
  # partition splits them and both rank 1. `an-321` (lab) sorts first. ----
  DBI::dbExecute(con, "INSERT INTO \"sample\"
    (uuid, uuid_feature, date, datetime, organisation) VALUES
    ('s-321', 'f-301', TIMESTAMP '2024-07-01 00:00:00', TIMESTAMP '2024-07-01 23:00:00', 'ALS'),
    ('s-322', 'f-301', TIMESTAMP '2024-07-02 00:00:00', TIMESTAMP '2024-07-02 01:00:00', 'ACIRL')")
  DBI::dbExecute(con, "INSERT INTO analysis
    (uuid, uuid_sample, uuid_lab, value, quantified, rl_low) VALUES
    ('an-321', 's-321', 'lm-lab-als',   8.10, TRUE, 0.1),
    ('an-322', 's-322', 'lm-fld-acirl', 8.20, TRUE, NULL)")

  # ---- P3: two LAB rows, neither field. ALS must win. `an-331` (ACIRL) sorts
  # BEFORE `an-332` (ALS), so a rank missing the organisation key names
  # an-331. ----
  DBI::dbExecute(con, "INSERT INTO \"sample\"
    (uuid, uuid_feature, date, datetime, organisation) VALUES
    ('s-331', 'f-302', TIMESTAMP '2024-07-03 00:00:00', TIMESTAMP '2024-07-03 02:00:00', 'ACIRL'),
    ('s-332', 'f-302', TIMESTAMP '2024-07-03 00:00:00', TIMESTAMP '2024-07-03 02:00:00', 'ALS')")
  DBI::dbExecute(con, "INSERT INTO analysis
    (uuid, uuid_sample, uuid_lab, value, quantified, rl_low) VALUES
    ('an-331', 's-331', 'lm-lab-acirl', 9.10, TRUE, 0.1),
    ('an-332', 's-332', 'lm-lab-als',   9.20, TRUE, 0.1)")

  # ---- P4: EN67 vs an ordinary ALS lab method. BOTH are ALS, so the
  # organisation key cannot separate them - only `EN67` counting as FIELD can.
  # `an-340` (the ordinary lab row) sorts BEFORE `an-341` (EN67), so if EN67
  # were treated as an ordinary lab method the tiebreak names an-340. ----
  DBI::dbExecute(con, "INSERT INTO \"sample\"
    (uuid, uuid_feature, date, datetime, organisation) VALUES
    ('s-340', 'f-303', TIMESTAMP '2024-07-04 00:00:00', TIMESTAMP '2024-07-04 02:00:00', 'ALS'),
    ('s-341', 'f-303', TIMESTAMP '2024-07-04 00:00:00', TIMESTAMP '2024-07-04 02:00:00', 'ALS')")
  DBI::dbExecute(con, "INSERT INTO analysis
    (uuid, uuid_sample, uuid_lab, value, quantified, rl_low) VALUES
    ('an-340', 's-340', 'lm-lab-als',  6.10, TRUE, 0.1),
    ('an-341', 's-341', 'lm-en67-als', 6.20, TRUE, NULL)")

  # ---- P5: a NULL-method ACIRL row against an ALS lab row.
  # HONEST NOTE ON NON-VACUITY: this partition CANNOT distinguish the COALESCE
  # from its absence on rank alone - DuckDB's ORDER BY ... DESC defaults to
  # NULLS LAST, so an uncoalesced `lm.method IN (...)` (which is NULL here)
  # sorts last either way, and an-351 wins under both. The COALESCE IS
  # observable in the `is_field` COLUMN, which would be NA rather than FALSE
  # without it, and that is what the paired test asserts. `an-350` (the NULL
  # row) sorts first, so the rank half is still a real detector for a rank that
  # ignored the ordering keys entirely. ----
  DBI::dbExecute(con, "INSERT INTO \"sample\"
    (uuid, uuid_feature, date, datetime, organisation) VALUES
    ('s-350', 'f-304', TIMESTAMP '2024-07-05 00:00:00', TIMESTAMP '2024-07-05 02:00:00', 'ACIRL'),
    ('s-351', 'f-304', TIMESTAMP '2024-07-05 00:00:00', TIMESTAMP '2024-07-05 02:00:00', 'ALS')")
  DBI::dbExecute(con, "INSERT INTO analysis
    (uuid, uuid_sample, uuid_lab, value, quantified, rl_low) VALUES
    ('an-350', 's-350', 'lm-null-acirl', 5.10, TRUE, NULL),
    ('an-351', 's-351', 'lm-lab-als',    5.20, TRUE, 0.1)")

  # ---- P6: two FIELD rows in one partition - the live shape for 74 of the
  # 931 contested partitions. `is_field` and the organisation key are equal, so
  # ONLY the uuid tiebreak separates them.
  #
  # INSERTED IN REVERSE UUID ORDER ON PURPOSE. Written the natural way round
  # (an-361 first) this partition is a vacuous test: a rank with no tiebreak at
  # all falls back to scan order, which would ALSO put an-361 first, and the
  # assertion passes against a migration that has no tiebreak. Verified by
  # mutation - dropping `a.uuid` from the ORDER BY survived the natural
  # ordering and is killed by this one. Physical order and uuid order now
  # disagree, so only a real tiebreak can produce the expected answer. ----
  DBI::dbExecute(con, "INSERT INTO \"sample\"
    (uuid, uuid_feature, date, datetime, organisation) VALUES
    ('s-362', 'f-305', TIMESTAMP '2024-07-06 00:00:00', TIMESTAMP '2024-07-06 02:30:00', 'ACIRL'),
    ('s-361', 'f-305', TIMESTAMP '2024-07-06 00:00:00', TIMESTAMP '2024-07-06 02:00:00', 'ACIRL')")
  DBI::dbExecute(con, "INSERT INTO analysis
    (uuid, uuid_sample, uuid_lab, value, quantified, rl_low) VALUES
    ('an-362', 's-362', 'lm-fld-acirl', 4.20, TRUE, NULL),
    ('an-361', 's-361', 'lm-fld-acirl', 4.10, TRUE, NULL)")

  # ---- P7: ONE feature/date, TWO samples, TWO analytes - the shape that
  # showed `a.uuid` alone is not enough (scratchpad/m6a_frankenstein.R).
  #
  # The final tiebreak used to be the ANALYSIS uuid, which bears no relation to
  # the sample the analysis came from. So each analyte picked its rank-1 row
  # independently, and on a feature/date holding two samples they could pick
  # DIFFERENT ones - 62 live feature/date groups did, including the B.D07 dust
  # triple where combustible came from one gauge and incombustible and total
  # from the other, leaving the "canonical" rows failing to sum.
  #
  # The uuids below are chosen so ANALYSIS order and SAMPLE order DISAGREE,
  # which is the only arrangement that can tell the two orderings apart:
  #
  #   analyte a-901:  an-371 (on s-372)   an-374 (on s-371)   -> a.uuid picks s-372
  #   analyte a-902:  an-372 (on s-371)   an-373 (on s-372)   -> a.uuid picks s-371
  #
  # Ordering on `a.uuid` alone therefore selects a different sample per
  # analyte; ordering on `s.uuid` first makes both select s-371. Both rows of
  # each pair are LAB rows of the same organisation, so `is_field` and `is_als`
  # tie and the tiebreak is genuinely what decides. ----
  DBI::dbExecute(con, "INSERT INTO feature
    (uuid, name, site, flow, matrix, lon, lat, cypher) VALUES
    ('f-306', 'PM-RANK-6', 'PreMigSite', 'surface', 'water', 150.3006, -33.3006, NULL)")
  DBI::dbExecute(con, "INSERT INTO analyte (uuid, name, units, type, CAS) VALUES
    ('a-902', 'Analyte Y', 'mg/L', 'anion', NULL)")
  DBI::dbExecute(con, "INSERT INTO lab_method
    (uuid, uuid_analyte, name, method, organisation, rl_low) VALUES
    ('lm-lab-acirl-y', 'a-902', 'Analyte Y ACIRL', 'EK-Y-ACIRL', 'ACIRL', 0.1)")
  DBI::dbExecute(con, "INSERT INTO \"sample\"
    (uuid, uuid_feature, date, datetime, organisation) VALUES
    ('s-371', 'f-306', TIMESTAMP '2024-07-07 00:00:00', TIMESTAMP '2024-07-07 01:00:00', 'ACIRL'),
    ('s-372', 'f-306', TIMESTAMP '2024-07-07 00:00:00', TIMESTAMP '2024-07-07 03:00:00', 'ACIRL')")
  DBI::dbExecute(con, "INSERT INTO analysis
    (uuid, uuid_sample, uuid_lab, value, quantified, rl_low) VALUES
    ('an-371', 's-372', 'lm-lab-acirl',   1.10, TRUE, 0.1),
    ('an-374', 's-371', 'lm-lab-acirl',   2.20, TRUE, 0.1),
    ('an-372', 's-371', 'lm-lab-acirl-y', 3.30, TRUE, 0.1),
    ('an-373', 's-372', 'lm-lab-acirl-y', 4.40, TRUE, 0.1)")

  invisible(NULL)
}

#' Seed, then run 001 -> 004 -> 005 against the result
#'
#' Threads the CALLING TEST's frame through every `withr::local_tempdir()`
#' (language-footguns.md R section): a bare/default-arg form would tear the
#' tempdir - and the DB inside it - down the instant this helper returns.
#'
#' @param mig1,mig4,mig5 environments from the `.mig005_load*()` loaders.
#' @param run_005 if FALSE, stop after 004 (for tests that need a post-004,
#'   pre-005 database).
#' @return path to the migrated DB file.
.run_001_004_005 <- function(mig1, mig4, mig5, run_005 = TRUE) {
  path <- seed_pre_migration_db(dir = withr::local_tempdir(.local_envir = parent.frame()))

  con0 <- pre_migration_con(path)
  .seed_005_rank_fixture(con0)
  DBI::dbDisconnect(con0, shutdown = TRUE)

  mig1$mig001_run(
    db = path, snapshot_dir = withr::local_tempdir(.local_envir = parent.frame()),
    dry_run = FALSE
  )
  mig4$mig004_run(
    db = path, snapshot_dir = withr::local_tempdir(.local_envir = parent.frame()),
    dry_run = FALSE
  )
  if (run_005) {
    mig5$mig005_run(
      db = path, snapshot_dir = withr::local_tempdir(.local_envir = parent.frame()),
      dry_run = FALSE
    )
  }
  path
}

#' Open the migrated DB, read `v_measurement`, and disconnect
#'
#' @param path DB path.
#' @param view view name (default `v_measurement`).
#' @return data.frame of the view's rows for the fixture analyses only.
.mig005_read_view <- function(path, view = "v_measurement") {
  con <- DBI::dbConnect(duckdb::duckdb(), path, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbExecute(con, "INSTALL icu")
  DBI::dbExecute(con, "LOAD icu")
  DBI::dbGetQuery(con, sprintf("SELECT * FROM %s ORDER BY uuid_analysis", view))
}

.rank_of <- function(v, uuid) v$preference_rank[match(uuid, v$uuid_analysis)]

# =============================================================================
# The ranking rule
# =============================================================================

test_that("005: a field reading outranks a lab reading of the same analyte at the same point on the same Sydney day, even when their datetimes differ", {
  mig1 <- .mig005_load_001(); mig4 <- .mig005_load_004(); mig5 <- .mig005_load()
  path <- .run_001_004_005(mig1, mig4, mig5)
  v <- .mig005_read_view(path)

  # P1. Keyed on `datetime` (00:00 vs 00:01) both would be rank 1 - the
  # measured live shape this partition reproduces.
  expect_equal(.rank_of(v, "an-312"), 1L)  # field
  expect_equal(.rank_of(v, "an-311"), 2L)  # lab, same Sydney day
})

test_that("005: the partition is keyed on the SYDNEY calendar date, so two samples whose naive UTC dates differ but whose Sydney dates match compete with each other", {
  mig1 <- .mig005_load_001(); mig4 <- .mig005_load_004(); mig5 <- .mig005_load()
  path <- .run_001_004_005(mig1, mig4, mig5)
  v <- .mig005_read_view(path)

  # P2: 2024-07-01 23:00Z and 2024-07-02 01:00Z are both 2024-07-02 in Sydney.
  # A timezone-naive cast splits them and ranks both 1.
  expect_equal(.rank_of(v, "an-322"), 1L)  # field
  expect_equal(.rank_of(v, "an-321"), 2L)  # lab
  # And the projected `date` agrees with the partition it was ranked in.
  expect_equal(
    as.character(v$date[match(c("an-321", "an-322"), v$uuid_analysis)]),
    c("2024-07-02", "2024-07-02")
  )
})

test_that("005: among two LAB readings, ALS outranks ACIRL", {
  mig1 <- .mig005_load_001(); mig4 <- .mig005_load_004(); mig5 <- .mig005_load()
  path <- .run_001_004_005(mig1, mig4, mig5)
  v <- .mig005_read_view(path)

  # P3. `an-331` (ACIRL) sorts first by uuid, so this fails if the
  # organisation key is dropped.
  expect_equal(.rank_of(v, "an-332"), 1L)  # ALS
  expect_equal(.rank_of(v, "an-331"), 2L)  # ACIRL
  expect_false(v$is_field[match("an-332", v$uuid_analysis)])
})

test_that("005: `EN67 - Client Supplied Data` ranks as a FIELD reading, outranking an ordinary ALS lab method", {
  mig1 <- .mig005_load_001(); mig4 <- .mig005_load_004(); mig5 <- .mig005_load()
  path <- .run_001_004_005(mig1, mig4, mig5)
  v <- .mig005_read_view(path)

  # P4. Both rows are ALS, and `an-340` (the lab row) sorts first, so only the
  # EN67-is-field rule can put an-341 on top.
  expect_equal(.rank_of(v, "an-341"), 1L)  # EN67
  expect_equal(.rank_of(v, "an-340"), 2L)  # ordinary ALS lab
  expect_true(v$is_field[match("an-341", v$uuid_analysis)])
})

test_that("005: the field-method list is READ from .RC_FIELD_METHODS, not re-derived", {
  mig5 <- .mig005_load()
  # If this ever becomes a private copy, the two can drift silently and an
  # ACIRL row could be protected from R-8.9 supersession as a field reading
  # while the views rank it as lab.
  expect_equal(mig5$.mig005_field_methods(), .RC_FIELD_METHODS)
  expect_true("EN67 - Client Supplied Data" %in% mig5$.mig005_field_methods())
})

test_that("005: a NULL lab_method.method is FALSE for is_field, never NA, and never outranks a real lab reading", {
  mig1 <- .mig005_load_001(); mig4 <- .mig005_load_004(); mig5 <- .mig005_load()
  path <- .run_001_004_005(mig1, mig4, mig5)
  v <- .mig005_read_view(path)

  # P5. `is_field` is the half that discriminates: without the COALESCE,
  # `lm.method IN (...)` is NULL for a NULL method and this column is NA.
  # (The rank half agrees either way under DuckDB's NULLS-LAST default - said
  # plainly in the fixture comment rather than dressed up as a detector.)
  expect_identical(v$is_field[match("an-350", v$uuid_analysis)], FALSE)
  expect_equal(.rank_of(v, "an-351"), 1L)  # ALS lab
  expect_equal(.rank_of(v, "an-350"), 2L)  # NULL-method ACIRL
})

test_that("005: two equally-ranked field readings are separated by the uuid tiebreak, not by scan order, and the answer is stable across reads", {
  mig1 <- .mig005_load_001(); mig4 <- .mig005_load_004(); mig5 <- .mig005_load()
  path <- .run_001_004_005(mig1, mig4, mig5)

  # P6: 74 live partitions hold two field rows, which `is_field`/`is_als`
  # cannot separate. The fixture inserts an-362 BEFORE an-361, so scan order
  # and uuid order disagree - a rank with no tiebreak names an-362.
  seen <- lapply(1:3, function(i) {
    v <- .mig005_read_view(path)
    v$preference_rank[match(c("an-361", "an-362"), v$uuid_analysis)]
  })
  expect_equal(seen[[1]], c(1L, 2L))
  expect_equal(seen[[2]], seen[[1]])
  expect_equal(seen[[3]], seen[[1]])
})

test_that("005: rank 1 selects ONE sample for every analyte at a feature/date", {
  # P7. Found by measuring the ranked output on a copy of the live database,
  # not by reasoning about the SQL: with `a.uuid` as the only tiebreak, each
  # analyte picked its canonical row independently of every other, so a
  # feature/date holding two samples could yield a rank-1 row set assembled
  # from BOTH. 62 live feature/date groups did exactly that, and the B.D07 dust
  # triple is the one that shows why it matters - the canonical combustible,
  # incombustible and total no longer summed, because they were not all from
  # the same gauge.
  mig1 <- .mig005_load_001(); mig4 <- .mig005_load_004(); mig5 <- .mig005_load()
  path <- .run_001_004_005(mig1, mig4, mig5)
  v <- .mig005_read_view(path)

  p7 <- v[v$uuid_analysis %in% c("an-371", "an-372", "an-373", "an-374"), ]
  expect_identical(nrow(p7), 4L)

  winners <- p7[p7$preference_rank == 1L, ]
  expect_identical(nrow(winners), 2L)              # one per analyte
  expect_length(unique(winners$uuid_sample), 1L)   # ...and BOTH from one sample
  expect_identical(unique(winners$uuid_sample), "s-371")

  # Non-vacuity: the analysis uuids were chosen so that ordering on `a.uuid`
  # alone would have split these across s-372 and s-371. an-371 sorts first in
  # its partition but sits on the LOSING sample, so it must rank 2.
  expect_equal(.rank_of(v, "an-371"), 2L)
  expect_equal(.rank_of(v, "an-374"), 1L)
  expect_equal(.rank_of(v, "an-372"), 1L)
  expect_equal(.rank_of(v, "an-373"), 2L)
})

test_that("005: a partition of one always ranks 1", {
  mig1 <- .mig005_load_001(); mig4 <- .mig005_load_004(); mig5 <- .mig005_load()
  path <- .run_001_004_005(mig1, mig4, mig5)
  v <- .mig005_read_view(path)

  # seed_pre_migration_db()'s own three analyses: distinct features, distinct
  # days, one analyte each.
  expect_equal(.rank_of(v, "an-901"), 1L)
  expect_equal(.rank_of(v, "an-902"), 1L)
  expect_equal(.rank_of(v, "an-903"), 1L)
})

# =============================================================================
# What the migration must NOT do
# =============================================================================

test_that("005: no row is dropped - every view's cardinality is identical before and after", {
  mig1 <- .mig005_load_001(); mig4 <- .mig005_load_004(); mig5 <- .mig005_load()
  path <- .run_001_004_005(mig1, mig4, mig5, run_005 = FALSE)

  views <- c("v_measurement", "v_measurement_epa", "v_measurement_gas_report",
             "v_measurement_long", "v_measurement_old")
  count_all <- function(p) {
    con <- DBI::dbConnect(duckdb::duckdb(), p, read_only = TRUE)
    on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
    DBI::dbExecute(con, "INSTALL icu"); DBI::dbExecute(con, "LOAD icu")
    vapply(views, function(v) {
      as.integer(DBI::dbGetQuery(con, sprintf("SELECT COUNT(*) n FROM %s", v))$n)
    }, integer(1))
  }
  before <- count_all(path)
  mig5$mig005_run(db = path, snapshot_dir = withr::local_tempdir(), dry_run = FALSE)
  after <- count_all(path)

  expect_equal(after, before)
  # Non-vacuity: the counts being compared must not all be zero.
  expect_true(all(before > 0))
})

test_that("005: every column 004 restored survives, and exactly two are added", {
  mig1 <- .mig005_load_001(); mig4 <- .mig005_load_004(); mig5 <- .mig005_load()
  path <- .run_001_004_005(mig1, mig4, mig5, run_005 = FALSE)

  cols_all <- function(p) {
    con <- DBI::dbConnect(duckdb::duckdb(), p, read_only = TRUE)
    on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
    lapply(mig5$.mig005_five_views, function(v) DBI::dbListFields(con, v))
  }
  before <- cols_all(path)
  mig5$mig005_run(db = path, snapshot_dir = withr::local_tempdir(), dry_run = FALSE)
  after <- cols_all(path)

  for (i in seq_along(before)) {
    expect_true(all(before[[i]] %in% after[[i]]))
    expect_setequal(setdiff(after[[i]], before[[i]]), c("is_field", "preference_rank"))
  }
})

test_that("005: base tables are untouched - the safety checksum is identical before and after", {
  mig1 <- .mig005_load_001(); mig4 <- .mig005_load_004(); mig5 <- .mig005_load()
  path <- .run_001_004_005(mig1, mig4, mig5, run_005 = FALSE)

  sums <- function(p) {
    con <- DBI::dbConnect(duckdb::duckdb(), p, read_only = TRUE)
    on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
    mig5$mig005_counts_checksum(con)
  }
  before <- sums(path)
  mig5$mig005_run(db = path, snapshot_dir = withr::local_tempdir(), dry_run = FALSE)
  expect_identical(sums(path), before)
})

# =============================================================================
# The mask views
# =============================================================================

test_that("005: a masked view carries the SAME preference_rank as v_measurement for the same analysis", {
  mig1 <- .mig005_load_001(); mig4 <- .mig005_load_004(); mig5 <- .mig005_load()
  path <- .run_001_004_005(mig1, mig4, mig5)

  v <- .mig005_read_view(path)
  epa <- .mig005_read_view(path, "v_measurement_epa")

  # f-301 is EPA-masked, so P1 and P2 appear in both views. The partition is
  # keyed on the feature and the mask filters on the feature, so a partition is
  # wholly in or wholly out - the rank must not be recomputed over the subset.
  shared <- c("an-311", "an-312", "an-321", "an-322")
  expect_true(all(shared %in% epa$uuid_analysis))
  expect_equal(
    epa$preference_rank[match(shared, epa$uuid_analysis)],
    v$preference_rank[match(shared, v$uuid_analysis)]
  )
})

test_that("005: an analysis with no lab_method is kept by the mask views (LEFT JOIN), ranked alone, and absent from v_measurement - and the verify gate accepts that asymmetry", {
  mig1 <- .mig005_load_001(); mig4 <- .mig005_load_004(); mig5 <- .mig005_load()
  path <- .run_001_004_005(mig1, mig4, mig5, run_005 = FALSE)

  # The mask views have never required a lab_method (004 did not join one), and
  # 005 keeps that with a LEFT JOIN so its new need for `method`/`organisation`
  # cannot change their cardinality. `v_measurement` INNER JOINs and so drops
  # the row - the two views legitimately disagree, and the oracle has to model
  # that rather than assume it away.
  #
  # `analysis.uuid_lab` is FK'd at `lab_method`, so a DANGLING uuid is not
  # insertable; NULL is, and reaches the same LEFT-JOIN branch.
  con <- DBI::dbConnect(duckdb::duckdb(), path, read_only = FALSE)
  DBI::dbExecute(con, "INSERT INTO analysis
    (uuid, uuid_sample, uuid_lab, value, quantified) VALUES
    ('an-399', 's-311', NULL, 1.23, TRUE)")
  DBI::dbDisconnect(con, shutdown = TRUE)

  # The gate must PASS with such a row present - .mig004_base_n() would have
  # refused it, counting the mask views short by one.
  res <- mig5$mig005_run(db = path, snapshot_dir = withr::local_tempdir(), dry_run = FALSE)
  expect_equal(res$status, "migrated")

  con <- DBI::dbConnect(duckdb::duckdb(), path, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbExecute(con, "INSTALL icu"); DBI::dbExecute(con, "LOAD icu")

  got <- DBI::dbGetQuery(
    con, "SELECT uuid_analysis, is_field, preference_rank FROM v_measurement_epa
          WHERE uuid_analysis = 'an-399'"
  )
  expect_equal(nrow(got), 1L)
  expect_identical(got$is_field[[1]], FALSE)
  # Its analyte is unknown, so it competes with nothing.
  expect_equal(got$preference_rank[[1]], 1L)

  in_measurement <- DBI::dbGetQuery(
    con, "SELECT COUNT(*) n FROM v_measurement WHERE uuid_analysis = 'an-399'"
  )$n
  expect_equal(as.integer(in_measurement), 0L)
})

# =============================================================================
# The verify gate
# =============================================================================

test_that("005: the verify gate rejects a rebuild that ranks every row 1", {
  mig1 <- .mig005_load_001(); mig4 <- .mig005_load_004(); mig5 <- .mig005_load()
  path <- .run_001_004_005(mig1, mig4, mig5, run_005 = FALSE)

  # Mutate the rebuild to emit a constant rank - the single most likely way to
  # ship this migration with its own reason for being missing, and invisible to
  # any count-based check.
  mig5$.mig005_rank_sql <- function(field_methods) "CAST(1 AS BIGINT)"
  expect_error(
    mig5$mig005_run(db = path, snapshot_dir = withr::local_tempdir(), dry_run = FALSE),
    class = "sampletidy_error"
  )

  # And it rolled back: no 1005 marker, so the DB is still repairable.
  con <- DBI::dbConnect(duckdb::duckdb(), path, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  n <- DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM schema_version WHERE version = 1005")$n
  expect_equal(as.integer(n), 0L)
})

test_that("005: the verify gate rejects a rebuild that partitions on the raw datetime instead of the Sydney date", {
  mig1 <- .mig005_load_001(); mig4 <- .mig005_load_004(); mig5 <- .mig005_load()
  path <- .run_001_004_005(mig1, mig4, mig5, run_005 = FALSE)

  # The design-as-recorded said "per (feature, datetime, analyte)". Measurement
  # showed that misses 15 of 931 live partitions - so the gate must catch it.
  mig5$.mig005_rank_sql <- function(field_methods) {
    sprintf(
      "ROW_NUMBER() OVER (PARTITION BY f.uuid, s.datetime,
         COALESCE(lm.uuid_analyte, 'analysis:' || a.uuid)
         ORDER BY %s DESC, %s DESC, a.uuid)",
      mig5$.mig005_is_field_sql(field_methods), mig5$.mig005_is_als_sql
    )
  }
  expect_error(
    mig5$mig005_run(db = path, snapshot_dir = withr::local_tempdir(), dry_run = FALSE),
    class = "sampletidy_error"
  )
})

test_that("005: the verify gate rejects a rebuild that drops a column 004 restored", {
  mig1 <- .mig005_load_001(); mig4 <- .mig005_load_004(); mig5 <- .mig005_load()
  path <- .run_001_004_005(mig1, mig4, mig5, run_005 = FALSE)

  mig5$.mig005_expected_view_cols <- lapply(
    mig5$.mig005_expected_view_cols, function(x) c(x, "a_column_no_view_has")
  )
  expect_error(
    mig5$mig005_run(db = path, snapshot_dir = withr::local_tempdir(), dry_run = FALSE),
    class = "sampletidy_error"
  )
})

# =============================================================================
# Operator surface: dry run, idempotency, preconditions
# =============================================================================

test_that("005: a dry run writes nothing, takes no backup, and leaves the views without a rank column", {
  mig1 <- .mig005_load_001(); mig4 <- .mig005_load_004(); mig5 <- .mig005_load()
  path <- .run_001_004_005(mig1, mig4, mig5, run_005 = FALSE)
  snap <- withr::local_tempdir()

  res <- mig5$mig005_run(db = path, snapshot_dir = snap, dry_run = TRUE)

  expect_equal(res$status, "dry_run")
  expect_true(is.na(res$backup_path))
  expect_equal(length(list.files(snap)), 0L)

  con <- DBI::dbConnect(duckdb::duckdb(), path, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  expect_false("preference_rank" %in% DBI::dbListFields(con, "v_measurement"))
  n <- DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM schema_version WHERE version = 1005")$n
  expect_equal(as.integer(n), 0L)
})

test_that("005: re-running after a successful migration is a no-op that reports already_migrated", {
  mig1 <- .mig005_load_001(); mig4 <- .mig005_load_004(); mig5 <- .mig005_load()
  path <- .run_001_004_005(mig1, mig4, mig5)
  snap <- withr::local_tempdir()

  res <- mig5$mig005_run(db = path, snapshot_dir = snap, dry_run = FALSE)

  expect_equal(res$status, "already_migrated")
  expect_true(is.na(res$backup_path))
  expect_equal(length(list.files(snap)), 0L)

  # The views still work after the no-op run.
  v <- .mig005_read_view(path)
  expect_equal(.rank_of(v, "an-312"), 1L)
})

test_that("005: refuses to run against a database 004 has not been applied to", {
  mig1 <- .mig005_load_001(); mig5 <- .mig005_load()
  path <- seed_pre_migration_db(dir = withr::local_tempdir())

  con0 <- pre_migration_con(path)
  .seed_005_rank_fixture(con0)
  DBI::dbDisconnect(con0, shutdown = TRUE)
  mig1$mig001_run(db = path, snapshot_dir = withr::local_tempdir(), dry_run = FALSE)

  snap <- withr::local_tempdir()
  expect_error(
    mig5$mig005_run(db = path, snapshot_dir = snap, dry_run = FALSE),
    class = "sampletidy_error"
  )
  # 004 is a precondition checked BEFORE the backup, so no stray copy is left
  # behind by a run that could never have succeeded.
  expect_equal(length(list.files(snap)), 0L)
})

test_that("005: a successful run writes a verified backup that restores the pre-005 views", {
  mig1 <- .mig005_load_001(); mig4 <- .mig005_load_004(); mig5 <- .mig005_load()
  path <- .run_001_004_005(mig1, mig4, mig5, run_005 = FALSE)
  snap <- withr::local_tempdir()

  res <- mig5$mig005_run(db = path, snapshot_dir = snap, dry_run = FALSE)
  expect_equal(res$status, "migrated")
  expect_true(file.exists(res$backup_path))

  con <- DBI::dbConnect(duckdb::duckdb(), res$backup_path, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  expect_false("preference_rank" %in% DBI::dbListFields(con, "v_measurement"))
})
