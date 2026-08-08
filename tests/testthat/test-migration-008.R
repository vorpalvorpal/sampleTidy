# dev/migrations/008-duplicate-samples.R - Robin's 2026-08-08 ruling 9.
#
#   mig008_run(db, snapshot_dir, reassign, dry_run = FALSE, .now = NULL)
#     -> invisible list(status = "migrated" | "already_migrated" | "dry_run", ...)
#
# Every test sources the target inside its own `test_that()` (test-migration-004's
# Phase-5 audit finding B5).
#
# THE FIXTURE SEEDS THE REAL NATURAL KEYS, for the same reason 007's does. The
# rulings name live rows by feature name, date, `person` and alias name -
# 'L.MW06' / '2024-11-28' / 'L. Pyne' / 'Discharge Point - Lawson STP' - so the
# fixture reproduces those exact strings. A fixture that supplied its own names
# would prove the machinery works while leaving the actual shipped spec - the
# part a human reviews, and the part that can be wrong - unexercised.
#
# IT ALSO BUILDS `v_measurement`. `seed_db()` has no views, and without one the
# derived-property assertion in `mig008_verify()` - that the view lost exactly
# the analyses ruling (1) deleted, which is what catches an analysis the FK
# pre-pass failed to reattach - would pass vacuously on every test. The
# assertion is guarded by a `%in% names(views)` check precisely so a view-less
# database is not a failure, which is also exactly how it would go unnoticed.

.mig008_load <- function() {
  env <- new.env(parent = globalenv())
  path <- testthat::test_path("..", "..", "dev", "migrations", "008-duplicate-samples.R")
  if (!file.exists(path)) {
    stop(sprintf("migration file not found: %s", path))
  }
  sys.source(path, envir = env)
  env
}

# The five (feature, loser, winner) triples ruling (1) names, and how many
# analyses each carries. Mirrors the live shape: 2 or 3 field readings on the
# loser, more on the winner.
.MIG008_PAIRS <- list(
  list(f = "L.L01",  n_lo = 2L, n_wi = 4L),
  list(f = "L.L02",  n_lo = 2L, n_wi = 4L),
  list(f = "L.MW06", n_lo = 3L, n_wi = 5L),
  list(f = "L.MW07", n_lo = 3L, n_wi = 5L),
  list(f = "L.MW08", n_lo = 3L, n_wi = 5L)
)

.MIG008_MOVE <- c("ES2515447001", "ES2606532001", "ES2606550001")

.seed_008_fixture <- function(con) {
  # ---- features, aliases, masks ----
  feats <- c(vapply(.MIG008_PAIRS, function(p) p$f, character(1)), "B.L01", "B.L05")
  for (i in seq_along(feats)) {
    DBI::dbExecute(
      con, "INSERT INTO feature (uuid, name, site, flow, matrix, lon, lat)
            VALUES (?, ?, ?, NULL, 'water', 150.5, -33.5)",
      params = list(paste0("f8-", i), feats[[i]], substr(feats[[i]], 1, 1))
    )
    DBI::dbExecute(
      con, "INSERT INTO feature_alias (uuid, uuid_feature, name, alias_key, kind,
                                       n_seen, auto_assign, confirmed_by)
            VALUES (?, ?, ?, ?, 'self', 0, TRUE, NULL)",
      params = list(paste0("fa8-", i), paste0("f8-", i), feats[[i]], tolower(feats[[i]]))
    )
  }
  # The destination alias: a SECOND alias on B.L05, confirmed by hand, exactly
  # as the live database has it.
  DBI::dbExecute(
    con, "INSERT INTO feature_alias (uuid, uuid_feature, name, alias_key, kind,
                                     n_seen, auto_assign, confirmed_by)
          VALUES ('fa8-lawson', 'f8-7', 'Discharge Point - Lawson STP',
                  'discharge point - lawson stp', 'descriptive', 0, TRUE, 'R. Shannon')")
  # Masks on the SOURCE only. The destination starts with NONE, exactly as the
  # live database has it - ruling (3) creates the `long` one and the `EPA`
  # variant is a declared exemption. A fixture that pre-seeded the destination
  # would have made ruling (3) untestable and the exemption invisible.
  DBI::dbExecute(con, "INSERT INTO feature_mask (uuid_feature, variant, name) VALUES
    ('f8-6', 'EPA', '21'), ('f8-6', 'long', 'Main dam')")

  # ---- ruling (1): five loser/winner pairs ----
  for (i in seq_along(.MIG008_PAIRS)) {
    p <- .MIG008_PAIRS[[i]]
    lo <- paste0("s8-lo-", i)
    wi <- paste0("s8-wi-", i)
    for (spec in list(list(u = lo, who = "L. Pyne"), list(u = wi, who = "S. Carter"))) {
      DBI::dbExecute(
        con, "INSERT INTO sample (uuid, uuid_feature_alias, date, datetime,
                                  organisation, person)
              VALUES (?, ?, DATE '2024-11-28', TIMESTAMP '2024-11-28 00:00:00', 'ACIRL', ?)",
        params = list(spec$u, paste0("fa8-", i), spec$who)
      )
    }
    # Every loser analysis is an exact twin on the winner; the winner also
    # carries rows the loser does not.
    for (j in seq_len(p$n_lo)) {
      DBI::dbExecute(
        con, "INSERT INTO analysis (uuid, uuid_sample, uuid_lab, value, quantified)
              VALUES (?, ?, 'lm8-field', ?, TRUE)",
        params = list(sprintf("an8-lo-%d-%d", i, j), lo, j * 1.5)
      )
      DBI::dbExecute(
        con, "INSERT INTO analysis (uuid, uuid_sample, uuid_lab, value, quantified)
              VALUES (?, ?, 'lm8-field', ?, TRUE)",
        params = list(sprintf("an8-wi-%d-%d", i, j), wi, j * 1.5)
      )
    }
    for (j in seq_len(p$n_wi - p$n_lo)) {
      DBI::dbExecute(
        con, "INSERT INTO analysis (uuid, uuid_sample, uuid_lab, value, quantified)
              VALUES (?, ?, 'lm8-lab', ?, TRUE)",
        params = list(sprintf("an8-wx-%d-%d", i, j), wi, 100 + j)
      )
    }
  }

  # ---- ruling (2): three B.L01 samples to move, each with analyses so the FK
  # detach/reattach is actually exercised ----
  for (i in seq_along(.MIG008_MOVE)) {
    DBI::dbExecute(
      con, "INSERT INTO sample (uuid, uuid_feature_alias, date, datetime,
                                organisation, person)
            VALUES (?, 'fa8-6', DATE '2026-03-04', TIMESTAMP '2026-03-04 00:00:00', 'ALS', 'S. Carter')",
      params = list(.MIG008_MOVE[[i]])
    )
    for (j in 1:2) {
      DBI::dbExecute(
        con, "INSERT INTO analysis (uuid, uuid_sample, uuid_lab, value, quantified)
              VALUES (?, ?, 'lm8-lab', ?, TRUE)",
        params = list(sprintf("an8-mv-%d-%d", i, j), .MIG008_MOVE[[i]], 7 + j)
      )
    }
  }
  # A B.L01 sample that STAYS - proves the move is scoped to the list.
  DBI::dbExecute(
    con, "INSERT INTO sample (uuid, uuid_feature_alias, date, datetime, organisation, person)
          VALUES ('ES2607204001', 'fa8-6', DATE '2026-03-04',
                  TIMESTAMP '2026-03-04 00:00:00', 'ALS', 'S. Carter')")

  DBI::dbExecute(con, "CREATE VIEW v_measurement AS
    SELECT a.uuid AS uuid_analysis, s.uuid AS uuid_sample, f.name AS feature_name, a.value
      FROM analysis a
      JOIN sample s        ON s.uuid = a.uuid_sample
      JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
      JOIN feature f       ON f.uuid = fa.uuid_feature")
  invisible(NULL)
}

.mig008_env <- function() {
  dir <- withr::local_tempdir(.local_envir = parent.frame())
  db <- seed_db(dir = dir)
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = FALSE)
  DBI::dbExecute(con, "INSERT INTO analyte (uuid, name, units, type, CAS)
                       VALUES ('a8-1', 'Temperature', 'C', 'field', NULL)")
  DBI::dbExecute(con, "INSERT INTO lab_method (uuid, uuid_analyte, name, method, organisation)
                       VALUES ('lm8-field', 'a8-1', 'Temperature', 'field', 'ACIRL'),
                              ('lm8-lab',   'a8-1', 'Temperature lab', 'X01', 'ALS')")
  .seed_008_fixture(con)
  DBI::dbDisconnect(con, shutdown = TRUE)
  list(db = db, snapshot_dir = withr::local_tempdir(.local_envir = parent.frame()))
}

.mig008_reassign_df <- function(which = .MIG008_MOVE) {
  data.frame(
    uuid_sample = which,
    client_sample_id = rep("Discharge Point - Lawson STP", length(which)),
    stringsAsFactors = FALSE
  )
}

.mig008_state <- function(db) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  list(
    marker = DBI::dbGetQuery(
      con, "SELECT version FROM schema_version WHERE version = 1008")$version,
    n_sample = as.integer(DBI::dbGetQuery(con, 'SELECT COUNT(*) n FROM "sample"')$n),
    n_analysis = as.integer(DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM analysis")$n),
    n_view = as.integer(DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM v_measurement")$n),
    by_feature = DBI::dbGetQuery(
      con, 'SELECT f.name AS feature, COUNT(*) AS n
              FROM "sample" s
              JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
              JOIN feature f        ON f.uuid = fa.uuid_feature
             GROUP BY 1 ORDER BY 1'),
    persons = DBI::dbGetQuery(
      con, 'SELECT person, COUNT(*) n FROM "sample" GROUP BY 1 ORDER BY 1'),
    masks = DBI::dbGetQuery(
      con, "SELECT uuid_feature, variant, name FROM feature_mask
             ORDER BY uuid_feature, variant")
  )
}

.mig008_n_feature <- function(db, feature) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  as.integer(DBI::dbGetQuery(
    con, 'SELECT COUNT(*) n FROM "sample" s
            JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
            JOIN feature f        ON f.uuid = fa.uuid_feature
           WHERE f.name = ?', params = list(feature))$n)
}

# ======================================================================
# happy path
# ======================================================================

test_that("mig008_run() applies both rulings", {
  mig <- .mig008_load(); e <- .mig008_env()
  before <- .mig008_state(e$db)

  res <- mig$mig008_run(db = e$db, snapshot_dir = e$snapshot_dir,
                        reassign = .mig008_reassign_df())
  expect_identical(res$status, "migrated")
  expect_identical(res$n_deleted_samples, 5L)
  expect_identical(res$n_deleted_analyses, 13L)
  expect_identical(res$n_reassigned, 3L)

  after <- .mig008_state(e$db)
  expect_identical(after$marker, 1008L)
  expect_identical(after$n_sample, before$n_sample - 5L)
  expect_identical(after$n_analysis, before$n_analysis - 13L)
})

test_that("(1) every 'L. Pyne' duplicate sample is gone and every winner is untouched", {
  mig <- .mig008_load(); e <- .mig008_env()
  mig$mig008_run(db = e$db, snapshot_dir = e$snapshot_dir, reassign = .mig008_reassign_df())

  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  for (p in .MIG008_PAIRS) {
    rows <- DBI::dbGetQuery(
      con, 'SELECT s.uuid, s.person,
                   (SELECT COUNT(*) FROM analysis a WHERE a.uuid_sample = s.uuid) n_an
              FROM "sample" s
              JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
              JOIN feature f        ON f.uuid = fa.uuid_feature
             WHERE f.name = ? AND CAST(s.datetime AS DATE) = CAST(? AS DATE)',
      params = list(p$f, "2024-11-28"))
    expect_identical(nrow(rows), 1L)
    expect_identical(rows$person[[1]], "S. Carter")
    expect_identical(as.integer(rows$n_an[[1]]), p$n_wi)
  }
})

test_that("(2) every listed sample resolves to B.L05 and the unlisted one stays on B.L01", {
  mig <- .mig008_load(); e <- .mig008_env()
  expect_identical(.mig008_n_feature(e$db, "B.L01"), 4L)
  expect_identical(.mig008_n_feature(e$db, "B.L05"), 0L)

  mig$mig008_run(db = e$db, snapshot_dir = e$snapshot_dir, reassign = .mig008_reassign_df())

  expect_identical(.mig008_n_feature(e$db, "B.L01"), 1L)
  expect_identical(.mig008_n_feature(e$db, "B.L05"), 3L)
})

test_that("(2) the FK detach/reattach leaves every analysis attached to its sample", {
  # The pre-pass NULLs `analysis.uuid_sample` and puts it back. If it did not
  # put it back the row would still be in `analysis` - so a row count proves
  # nothing - but would fall out of `v_measurement`'s INNER JOIN.
  mig <- .mig008_load(); e <- .mig008_env()
  mig$mig008_run(db = e$db, snapshot_dir = e$snapshot_dir, reassign = .mig008_reassign_df())

  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  expect_identical(
    as.integer(DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM analysis WHERE uuid_sample IS NULL")$n),
    0L)
  for (u in .MIG008_MOVE) {
    expect_identical(
      as.integer(DBI::dbGetQuery(
        con, "SELECT COUNT(*) n FROM analysis WHERE uuid_sample = ?", params = list(u))$n),
      2L)
  }
  # and they moved WITH the sample
  expect_identical(
    as.integer(DBI::dbGetQuery(
      con, "SELECT COUNT(*) n FROM v_measurement WHERE feature_name = 'B.L05'")$n),
    6L)
})

test_that("the run is idempotent - a second call is a no-op", {
  mig <- .mig008_load(); e <- .mig008_env()
  mig$mig008_run(db = e$db, snapshot_dir = e$snapshot_dir, reassign = .mig008_reassign_df())
  mid <- .mig008_state(e$db)

  res <- mig$mig008_run(db = e$db, snapshot_dir = e$snapshot_dir,
                        reassign = .mig008_reassign_df())
  expect_identical(res$status, "already_migrated")
  expect_identical(res$n_deleted_samples, 0L)
  expect_identical(res$n_reassigned, 0L)
  expect_identical(.mig008_state(e$db)[c("n_sample", "n_analysis")],
                   mid[c("n_sample", "n_analysis")])
})

test_that("dry_run writes nothing, takes no backup, and still runs every gate", {
  mig <- .mig008_load(); e <- .mig008_env()
  before <- .mig008_state(e$db)

  res <- mig$mig008_run(db = e$db, snapshot_dir = e$snapshot_dir,
                        reassign = .mig008_reassign_df(), dry_run = TRUE)
  expect_identical(res$status, "dry_run")
  expect_identical(res$n_deleted_analyses, 13L)
  expect_identical(res$n_reassigned, 3L)
  expect_identical(.mig008_state(e$db), before)
  expect_identical(length(list.files(e$snapshot_dir)), 0L)
})

test_that("a dry run REFUSES when a gate fails, so it is a real rehearsal", {
  mig <- .mig008_load(); e <- .mig008_env()
  expect_error(
    mig$mig008_run(db = e$db, snapshot_dir = e$snapshot_dir,
                   reassign = .mig008_reassign_df("ES9999999001"), dry_run = TRUE),
    class = "sampletidy_error"
  )
})

# ======================================================================
# ruling (1) gates
# ======================================================================

test_that("(1) is REFUSED when an analysis on the doomed sample is NOT a twin", {
  # This is the check that authorises the delete at all. If even one reading is
  # unique to the sample being deleted, deleting it loses a real measurement.
  mig <- .mig008_load(); e <- .mig008_env()
  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = FALSE)
  DBI::dbExecute(con, "UPDATE analysis SET value = 99.9 WHERE uuid = 'an8-lo-1-1'")
  DBI::dbDisconnect(con, shutdown = TRUE)

  before <- .mig008_state(e$db)
  expect_error(
    mig$mig008_run(db = e$db, snapshot_dir = e$snapshot_dir, reassign = .mig008_reassign_df()),
    class = "sampletidy_error")
  expect_identical(.mig008_state(e$db), before)
})

test_that("(1) is REFUSED when the group no longer holds exactly two samples", {
  # THE ASSERTION THAT MATTERS IS "NOTHING CHANGED", not "it errored". Mutation
  # testing showed that removing this gate still ends in an error - but from the
  # SUCCESS verify, long after the FK pre-pass has COMMITTED five deletions.
  # An expect_error() alone therefore passes with the gate ripped out, which is
  # a test that cannot tell the safe outcome from the destructive one.
  mig <- .mig008_load(); e <- .mig008_env()
  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = FALSE)
  DBI::dbExecute(con, "INSERT INTO sample (uuid, uuid_feature_alias, date, datetime,
                                           organisation, person)
                       VALUES ('s8-extra', 'fa8-1', DATE '2024-11-28',
                               TIMESTAMP '2024-11-28 00:00:00', 'ACIRL', 'Someone Else')")
  DBI::dbDisconnect(con, shutdown = TRUE)

  before <- .mig008_state(e$db)
  expect_error(
    mig$mig008_run(db = e$db, snapshot_dir = e$snapshot_dir, reassign = .mig008_reassign_df()),
    class = "sampletidy_error")
  expect_identical(.mig008_state(e$db), before)
  expect_identical(length(list.files(e$snapshot_dir)), 0L)
})

test_that("(1) is REFUSED when `person` no longer tells the pair apart", {
  mig <- .mig008_load(); e <- .mig008_env()
  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = FALSE)
  DBI::dbExecute(con, "UPDATE sample SET person = 'S. Carter' WHERE uuid = 's8-lo-1'")
  DBI::dbDisconnect(con, shutdown = TRUE)

  expect_error(
    mig$mig008_run(db = e$db, snapshot_dir = e$snapshot_dir, reassign = .mig008_reassign_df()),
    class = "sampletidy_error")
})

test_that("(1) is REFUSED when the doomed sample has grown past the analysis bound", {
  mig <- .mig008_load(); e <- .mig008_env()
  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = FALSE)
  # Two more twins - still all twins, so only the BOUND can catch this.
  DBI::dbExecute(con, "INSERT INTO analysis (uuid, uuid_sample, uuid_lab, value, quantified)
                       VALUES ('an8-lo-1-9', 's8-lo-1', 'lm8-field', 1.5, TRUE),
                              ('an8-lo-1-8', 's8-lo-1', 'lm8-field', 3.0, TRUE)")
  DBI::dbDisconnect(con, shutdown = TRUE)

  expect_error(
    mig$mig008_run(db = e$db, snapshot_dir = e$snapshot_dir, reassign = .mig008_reassign_df()),
    class = "sampletidy_error")
})

test_that("(1) is REFUSED when the doomed sample carries no analyses at all", {
  mig <- .mig008_load(); e <- .mig008_env()
  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = FALSE)
  DBI::dbExecute(con, "DELETE FROM analysis WHERE uuid_sample = 's8-lo-1'")
  DBI::dbDisconnect(con, shutdown = TRUE)

  expect_error(
    mig$mig008_run(db = e$db, snapshot_dir = e$snapshot_dir, reassign = .mig008_reassign_df()),
    class = "sampletidy_error")
})

# ======================================================================
# ruling (2) gates
# ======================================================================

test_that("(3) the destination gets its `long` mask, and deliberately NO EPA mask", {
  # Found by rehearsal against a copy of the live DB: `v_measurement_epa` and
  # `v_measurement_long` INNER JOIN feature_mask, so a destination missing a
  # variant does not merely look different in that report - the rows VANISH.
  # Unguarded, the move deleted 522 measurements from BOTH views.
  #
  # Robin ruled the Lawson STP tanker discharge is a Sydney Water trade-waste
  # point, not an EPA licensed discharge: so it gets a `long` mask (it must
  # stay in ordinary reporting) and NO EPA mask (leaving the EPA return is the
  # correction). Both halves are asserted - the presence AND the absence.
  mig <- .mig008_load(); e <- .mig008_env()
  mig$mig008_run(db = e$db, snapshot_dir = e$snapshot_dir, reassign = .mig008_reassign_df())

  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  m <- DBI::dbGetQuery(con, "SELECT variant, name FROM feature_mask
                              WHERE uuid_feature = 'f8-7' ORDER BY variant")
  expect_identical(m$variant, "long")
  expect_identical(m$name, "Discharge Point - Lawson STP")
})

test_that("(3) is idempotent - a destination that already has the mask gains no duplicate", {
  # `feature_mask` is keyed by (uuid_feature, variant) with no uuid column, so a
  # second append would be a duplicate key, not a harmless no-op. This is the
  # re-run-after-a-partial-failure path.
  mig <- .mig008_load(); e <- .mig008_env()
  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = FALSE)
  DBI::dbExecute(con, "INSERT INTO feature_mask (uuid_feature, variant, name)
                       VALUES ('f8-7', 'long', 'Discharge Point - Lawson STP')")
  DBI::dbDisconnect(con, shutdown = TRUE)

  res <- mig$mig008_run(db = e$db, snapshot_dir = e$snapshot_dir,
                        reassign = .mig008_reassign_df())
  expect_identical(res$status, "migrated")

  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  expect_identical(
    as.integer(DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM feature_mask
                                      WHERE uuid_feature = 'f8-7'")$n), 1L)
})

test_that("a source variant that is neither created NOR exempt is REFUSED", {
  # The gate is an exemption list, not a weaker check: a variant the source has
  # that ruling (3) does not create and no ruling excuses must still stop the
  # migration, or the next reporting view added silently loses its rows.
  mig <- .mig008_load(); e <- .mig008_env()
  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = FALSE)
  DBI::dbExecute(con, "INSERT INTO feature_mask (uuid_feature, variant, name)
                       VALUES ('f8-6', 'gas_report', 'Main dam gas')")
  DBI::dbDisconnect(con, shutdown = TRUE)

  before <- .mig008_state(e$db)
  expect_error(
    mig$mig008_run(db = e$db, snapshot_dir = e$snapshot_dir, reassign = .mig008_reassign_df()),
    class = "sampletidy_error")
  expect_identical(.mig008_state(e$db), before)
  expect_identical(length(list.files(e$snapshot_dir)), 0L)
})

test_that("(2) is REFUSED when the destination alias is not human-confirmed", {
  mig <- .mig008_load(); e <- .mig008_env()
  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = FALSE)
  DBI::dbExecute(con, "UPDATE feature_alias SET confirmed_by = NULL WHERE uuid = 'fa8-lawson'")
  DBI::dbDisconnect(con, shutdown = TRUE)

  expect_error(
    mig$mig008_run(db = e$db, snapshot_dir = e$snapshot_dir, reassign = .mig008_reassign_df()),
    class = "sampletidy_error")
})

test_that("(2) is REFUSED when the destination alias points at the wrong feature", {
  # Same lesson as the exactly-two-samples test: without the gate the run still
  # errors, but only after the pre-pass has deleted five samples and moved three
  # onto the WRONG feature. "Nothing changed" is the assertion with teeth.
  mig <- .mig008_load(); e <- .mig008_env()
  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = FALSE)
  DBI::dbExecute(con, "UPDATE feature_alias SET uuid_feature = 'f8-6' WHERE uuid = 'fa8-lawson'")
  DBI::dbDisconnect(con, shutdown = TRUE)

  before <- .mig008_state(e$db)
  expect_error(
    mig$mig008_run(db = e$db, snapshot_dir = e$snapshot_dir, reassign = .mig008_reassign_df()),
    class = "sampletidy_error")
  expect_identical(.mig008_state(e$db), before)
})

test_that("(2) is REFUSED when a listed sample is not on the source feature", {
  mig <- .mig008_load(); e <- .mig008_env()
  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = FALSE)
  DBI::dbExecute(con, "UPDATE sample SET uuid_feature_alias = 'fa8-1' WHERE uuid = ?",
                 params = list(.MIG008_MOVE[[1]]))
  DBI::dbDisconnect(con, shutdown = TRUE)

  expect_error(
    mig$mig008_run(db = e$db, snapshot_dir = e$snapshot_dir, reassign = .mig008_reassign_df()),
    class = "sampletidy_error")
})

test_that("(2) is REFUSED when a listed sample does not exist", {
  mig <- .mig008_load(); e <- .mig008_env()
  expect_error(
    mig$mig008_run(db = e$db, snapshot_dir = e$snapshot_dir,
                   reassign = .mig008_reassign_df(c(.MIG008_MOVE, "ES0000000001"))),
    class = "sampletidy_error")
})

# ======================================================================
# the reassignment list itself
# ======================================================================

test_that("an EMPTY reassignment list is refused, not reported as success", {
  mig <- .mig008_load(); e <- .mig008_env()
  expect_error(
    mig$mig008_run(db = e$db, snapshot_dir = e$snapshot_dir,
                   reassign = .mig008_reassign_df(character(0))),
    class = "sampletidy_error")
})

test_that("a missing required column is refused", {
  mig <- .mig008_load(); e <- .mig008_env()
  df <- .mig008_reassign_df()
  df$client_sample_id <- NULL
  expect_error(
    mig$mig008_run(db = e$db, snapshot_dir = e$snapshot_dir, reassign = df),
    class = "sampletidy_error")
})

test_that("a duplicate sample in the list is refused BEFORE anything is written", {
  # The list gate is structural and runs before the database is even opened, so
  # a duplicate must cost nothing. Without it the run still fails - the SUCCESS
  # verify notices 4 listed rows against 3 distinct samples - but by then the
  # pre-pass has committed, which is exactly the outcome this gate prevents.
  mig <- .mig008_load(); e <- .mig008_env()
  before <- .mig008_state(e$db)
  expect_error(
    mig$mig008_run(db = e$db, snapshot_dir = e$snapshot_dir,
                   reassign = .mig008_reassign_df(c(.MIG008_MOVE, .MIG008_MOVE[[1]]))),
    class = "sampletidy_error")
  expect_identical(.mig008_state(e$db), before)
  expect_identical(length(list.files(e$snapshot_dir)), 0L)
})

test_that("a blank cell is refused", {
  mig <- .mig008_load(); e <- .mig008_env()
  df <- .mig008_reassign_df()
  df$client_sample_id[[2]] <- "  "
  expect_error(
    mig$mig008_run(db = e$db, snapshot_dir = e$snapshot_dir, reassign = df),
    class = "sampletidy_error")
})

test_that("a client_sample_id naming somewhere ELSE is refused - the evidence column is checked", {
  mig <- .mig008_load(); e <- .mig008_env()
  df <- .mig008_reassign_df()
  df$client_sample_id[[2]] <- "Trade Waste Dam"
  expect_error(
    mig$mig008_run(db = e$db, snapshot_dir = e$snapshot_dir, reassign = df),
    class = "sampletidy_error")
})

test_that("the real workbook's spelling variant IS accepted", {
  # One of the 27 live XTABs says 'Discharge point- lawson STP'. That is a lab
  # typo for the same place, not a different destination, and the fold must let
  # it through or the shipped CSV cannot be applied at all.
  mig <- .mig008_load(); e <- .mig008_env()
  df <- .mig008_reassign_df()
  df$client_sample_id[[3]] <- "Discharge point- lawson STP"
  res <- mig$mig008_run(db = e$db, snapshot_dir = e$snapshot_dir, reassign = df)
  expect_identical(res$status, "migrated")
  expect_identical(.mig008_n_feature(e$db, "B.L05"), 3L)
})

test_that("the shipped CSV round-trips through the reader", {
  mig <- .mig008_load()
  path <- testthat::test_path("..", "..", "dev", "migrations",
                              "008-duplicate-samples-REASSIGN.csv")
  skip_if_not(file.exists(path))
  df <- mig$.mig008_read_reassign(path)
  expect_gt(nrow(df), 0L)
  expect_true(all(mig$.mig008_reassign_cols %in% names(df)))
  expect_false(any(duplicated(df$uuid_sample)))
})

# ======================================================================
# the verify gates themselves
# ======================================================================

test_that("mig008_verify() fires when a table it must not touch has moved", {
  mig <- .mig008_load()
  before <- list(tables = list(feature = 3L, feature_checksum = "aa",
                               sample = 10L, sample_checksum = "s1",
                               analysis = 20L, analysis_checksum = "x1"),
                 views = list())
  after <- before
  after$tables$feature_checksum <- "bb"
  after$tables$sample <- 5L
  after$tables$analysis <- 7L
  expect_error(mig$mig008_verify(before, after, 5L, 13L, 0L), class = "sampletidy_error")
})

test_that("mig008_verify() fires on the wrong sample/analysis delta", {
  mig <- .mig008_load()
  before <- list(tables = list(sample = 10L, sample_checksum = "s1",
                               analysis = 20L, analysis_checksum = "x1"),
                 views = list())
  after <- before
  after$tables$sample <- 6L         # lost 4, not 5
  after$tables$analysis <- 7L
  expect_error(mig$mig008_verify(before, after, 5L, 13L, 0L), class = "sampletidy_error")
})

test_that("mig008_verify() fires when v_measurement and analysis disagree - the orphan check", {
  mig <- .mig008_load()
  before <- list(tables = list(sample = 10L, sample_checksum = "s1",
                               analysis = 20L, analysis_checksum = "x1"),
                 views = list(v_measurement = 20L))
  after <- list(tables = list(sample = 5L, sample_checksum = "s2",
                              analysis = 7L, analysis_checksum = "x2"),
                views = list(v_measurement = 6L))   # one row orphaned
  expect_error(mig$mig008_verify(before, after, 5L, 13L, 0L), class = "sampletidy_error")
})

test_that("mig008_verify() passes on the shape the migration actually produces", {
  mig <- .mig008_load()
  before <- list(tables = list(feature = 3L, feature_checksum = "aa",
                               sample = 10L, sample_checksum = "s1",
                               analysis = 20L, analysis_checksum = "x1"),
                 views = list(v_measurement = 20L))
  after <- list(tables = list(feature = 3L, feature_checksum = "aa",
                              sample = 5L, sample_checksum = "s2",
                              analysis = 7L, analysis_checksum = "x2"),
                views = list(v_measurement = 7L))
  expect_true(mig$mig008_verify(before, after, 5L, 13L, 0L))
})

test_that("mig008_counts_checksum() separates base tables from views", {
  mig <- .mig008_load(); e <- .mig008_env()
  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  cc <- mig$mig008_counts_checksum(con)
  expect_true("sample" %in% names(cc$tables))
  expect_true("v_measurement" %in% names(cc$views))
  expect_false("v_measurement" %in% names(cc$tables))
  # the ops tables this migration is allowed to append to are excluded
  expect_false("change_log" %in% names(cc$tables))
  expect_false("schema_version" %in% names(cc$tables))
})

test_that("mig008_counts_checksum() notices a VALUE change with no row-count change", {
  mig <- .mig008_load(); e <- .mig008_env()
  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = FALSE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  a <- mig$mig008_counts_checksum(con)
  DBI::dbExecute(con, "UPDATE analysis SET value = value + 1 WHERE uuid = 'an8-wx-1-1'")
  b <- mig$mig008_counts_checksum(con)
  expect_identical(a$tables$analysis, b$tables$analysis)
  expect_false(identical(a$tables$analysis_checksum, b$tables$analysis_checksum))
})

# ======================================================================
# backup
# ======================================================================

test_that("a backup is written and verified before any write", {
  mig <- .mig008_load(); e <- .mig008_env()
  res <- mig$mig008_run(db = e$db, snapshot_dir = e$snapshot_dir,
                        reassign = .mig008_reassign_df(),
                        .now = as.POSIXct("2026-08-08 12:00:00", tz = "UTC"))
  expect_true(file.exists(res$backup_path))
  expect_match(basename(res$backup_path), "^monitoring_pre-008-duplicate-samples_.*\\.duckdb$")

  # the backup is the PRE state
  con <- DBI::dbConnect(duckdb::duckdb(), res$backup_path, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  expect_identical(
    as.integer(DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM schema_version WHERE version = 1008")$n),
    0L)
  expect_identical(
    as.integer(DBI::dbGetQuery(con, 'SELECT COUNT(*) n FROM "sample" WHERE person = ?',
                               params = list("L. Pyne"))$n),
    5L)
})

test_that("a run that could never have succeeded leaves NO backup behind", {
  mig <- .mig008_load(); e <- .mig008_env()
  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = FALSE)
  DBI::dbExecute(con, "UPDATE analysis SET value = 99.9 WHERE uuid = 'an8-lo-1-1'")
  DBI::dbDisconnect(con, shutdown = TRUE)

  expect_error(
    mig$mig008_run(db = e$db, snapshot_dir = e$snapshot_dir, reassign = .mig008_reassign_df()),
    class = "sampletidy_error")
  expect_identical(length(list.files(e$snapshot_dir)), 0L)
})

# ======================================================================
# structural
# ======================================================================

test_that("the marker version is 1008 and the actor names the migration", {
  mig <- .mig008_load()
  expect_identical(mig$.mig008_marker_version, 1008L)
  expect_identical(mig$.mig008_actor, "008-duplicate-samples")
})

test_that("every write lands in change_log through the mutation layer", {
  mig <- .mig008_load(); e <- .mig008_env()
  mig$mig008_run(db = e$db, snapshot_dir = e$snapshot_dir, reassign = .mig008_reassign_df())

  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  cl <- DBI::dbGetQuery(con, "SELECT action, tbl, reason FROM change_log WHERE actor = ?",
                        params = list("008-duplicate-samples"))
  expect_identical(sum(cl$action == "delete" & cl$tbl == "sample"), 5L)
  expect_identical(sum(cl$action == "delete" & cl$tbl == "analysis"), 13L)
  # 3 samples moved + 6 analyses detached + 6 reattached
  expect_identical(sum(cl$action == "update" & cl$tbl == "sample"), 3L)
  expect_identical(sum(cl$action == "update" & cl$tbl == "analysis"), 12L)
  # the deletion reason records the attribution the delete destroys
  expect_true(any(grepl("L. Pyne", cl$reason[cl$tbl == "sample" & cl$action == "delete"],
                        fixed = TRUE)))
})

test_that("the migration refuses a database with no schema_version table", {
  mig <- .mig008_load()
  dir <- withr::local_tempdir()
  db <- file.path(dir, "bare.duckdb")
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = FALSE)
  DBI::dbExecute(con, "CREATE TABLE t (x INTEGER)")
  DBI::dbDisconnect(con, shutdown = TRUE)
  expect_error(
    mig$mig008_run(db = db, snapshot_dir = dir, reassign = .mig008_reassign_df()),
    class = "sampletidy_error")
})
