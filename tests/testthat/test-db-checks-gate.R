# PLAN-22 A3: mig_db_checks_gate(), the migration gate.
#
#   baseline <- db_checks(con, tier = "migration")   # before the change
#   ... the migration's writes, inside its transaction ...
#   mig_db_checks_gate(con, baseline, allow = character())   # before COMMIT
#
# The gate re-runs the migration-tier checks on `con` and returns invisibly
# unless there is a NEW failure, when it aborts (class "sampletidy_error")
# naming the new failing checks. New = a check that passed (or was absent) in
# the baseline and now fails or errors, OR a check that was already failing
# whose set of offending `key`s gained a key not in the baseline. Keys are
# compared over ALL offenders, not just the `sample_n` shown. Failures already
# present are printed (a message naming the check) but do not block. `allow`
# names checks exempt from the gate (a migration that changes an invariant on
# purpose). The gate never opens or closes a transaction itself: the caller's
# transaction wrapper rolls back on the abort.

dbc_bad_hash <- function(con, i) {
  dbc_exec(con, "INSERT INTO ingest_file (hash, state) VALUES (?, 'archived')", sprintf("BAD-HASH-%02d", i))
}

dbc_expect_gate_abort <- function(expr, names) {
  e <- testthat::expect_error(expr, class = "sampletidy_error")
  if (!is.null(e)) for (nm in names) testthat::expect_match(conditionMessage(e), nm, fixed = TRUE)
  invisible(e)
}

test_that("gate: nothing changed on a clean DB -> returns invisibly", {
  db <- dbc_db()
  dbc_with(db, function(con) {
    baseline <- db_checks(con, tier = "migration")
    expect_invisible(mig_db_checks_gate(con, baseline))
  })
})

test_that("gate: a failure already in the baseline is tolerated (and printed)", {
  db <- dbc_db()
  dbc_with(db, function(con) {
    dbc_bad_hash(con, 1)
    baseline <- db_checks(con, tier = "migration")
    expect_identical(dbc_row(baseline, "hash_format")$status, "fail")
    DBI::dbExecute(con, "UPDATE feature SET comments = 'touched' WHERE uuid = 'f-0001'")
    expect_message(out <- withVisible(mig_db_checks_gate(con, baseline)), "hash_format")
    expect_false(out$visible)
  })
})

test_that("gate: a check that passed in the baseline and now fails aborts, naming it", {
  db <- dbc_db()
  dbc_with(db, function(con) {
    baseline <- db_checks(con, tier = "migration")
    dbc_exec(con, "INSERT INTO asset (uuid, name, uuid_project, hash) VALUES
                   ('as-x1', 'a.pdf', 'p-0001', ?), ('as-x2', 'b.pdf', 'p-0003', ?)", dbc_hex(904), dbc_hex(904))
    dbc_expect_gate_abort(mig_db_checks_gate(con, baseline), "dup_asset_hash")
  })
})

test_that("gate: a migration-tier invariant broken by the change aborts (dropped ux_sample_identity)", {
  db <- dbc_db()
  dbc_with(db, function(con) {
    baseline <- db_checks(con, tier = "migration")
    DBI::dbExecute(con, "DROP INDEX ux_sample_identity")
    dbc_expect_gate_abort(mig_db_checks_gate(con, baseline), "expected_constraints_present")
  })
})

test_that("gate: a new offending key in an already-failing check aborts, naming the check", {
  db <- dbc_db()
  dbc_with(db, function(con) {
    dbc_bad_hash(con, 1)
    baseline <- db_checks(con, tier = "migration")
    dbc_bad_hash(con, 2)
    dbc_expect_gate_abort(mig_db_checks_gate(con, baseline), "hash_format")
  })
})

test_that("gate: fewer offenders than the baseline is not a new failure", {
  db <- dbc_db()
  dbc_with(db, function(con) {
    dbc_bad_hash(con, 1)
    dbc_bad_hash(con, 2)
    baseline <- db_checks(con, tier = "migration")
    DBI::dbExecute(con, "DELETE FROM ingest_file WHERE hash = 'BAD-HASH-02'")
    expect_invisible(suppressMessages(mig_db_checks_gate(con, baseline)))
  })
})

test_that("gate: keys are compared over every offender, not just the sample_n shown", {
  db <- dbc_db()
  dbc_with(db, function(con) {
    for (i in 1:7) dbc_bad_hash(con, i)
    baseline <- db_checks(con, tier = "migration", sample_n = 2)
    # Same 7 offenders: no new key, whichever 2 the sample happened to show.
    expect_invisible(suppressMessages(mig_db_checks_gate(con, baseline)))
    # Replace one offender with another: same count, one NEW key.
    DBI::dbExecute(con, "DELETE FROM ingest_file WHERE hash = 'BAD-HASH-07'")
    dbc_bad_hash(con, 8)
    dbc_expect_gate_abort(mig_db_checks_gate(con, baseline), "hash_format")
  })
})

test_that("gate: a check absent from the baseline that now fails is new", {
  db <- dbc_db()
  dbc_with(db, function(con) {
    DBI::dbExecute(con, "DROP INDEX ux_sample_identity")
    baseline <- db_checks(con, tier = "hourly")   # expected_constraints_present not run
    expect_false("expected_constraints_present" %in% baseline$name)
    dbc_expect_gate_abort(mig_db_checks_gate(con, baseline), "expected_constraints_present")
  })
})

test_that("gate: a check that newly errors is a new failure", {
  db <- dbc_db()
  dbc_with(db, function(con) {
    baseline <- db_checks(con, tier = "migration")
    DBI::dbExecute(con, "DROP TABLE lab_qc_outlier")
    dbc_expect_gate_abort(mig_db_checks_gate(con, baseline), "orphan_qc_refs")
  })
})

test_that("gate: allow exempts the named checks, and only those", {
  db <- dbc_db()
  dbc_with(db, function(con) {
    baseline <- db_checks(con, tier = "migration")
    DBI::dbExecute(con, "UPDATE feature SET flow = 'river' WHERE uuid = 'f-0002'")
    expect_invisible(suppressMessages(mig_db_checks_gate(con, baseline, allow = "vocab_feature_flow")))
    dbc_bad_hash(con, 1)
    e <- dbc_expect_gate_abort(mig_db_checks_gate(con, baseline, allow = "vocab_feature_flow"), "hash_format")
    expect_invisible(suppressMessages(
      mig_db_checks_gate(con, baseline, allow = c("vocab_feature_flow", "hash_format"))))
  })
})

test_that("gate: runs inside the caller's transaction; the caller's rollback undoes the change", {
  db <- dbc_db()
  dbc_with(db, function(con) {
    baseline <- db_checks(con, tier = "migration")
    DBI::dbBegin(con)
    dbc_bad_hash(con, 1)
    dbc_expect_gate_abort(mig_db_checks_gate(con, baseline), "hash_format")
    DBI::dbRollback(con)
    n <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM ingest_file WHERE hash = 'BAD-HASH-01'")$n
    expect_equal(n, 0)
    expect_true(all(db_checks(con, tier = "migration")$status == "pass"))
  })
})

test_that("gate: a clean change inside a transaction passes and the caller can still commit", {
  db <- dbc_db()
  dbc_with(db, function(con) {
    baseline <- db_checks(con, tier = "migration")
    DBI::dbBegin(con)
    DBI::dbExecute(con, "UPDATE feature SET comments = 'gated' WHERE uuid = 'f-0001'")
    expect_invisible(mig_db_checks_gate(con, baseline))
    DBI::dbCommit(con)
    expect_identical(DBI::dbGetQuery(con, "SELECT comments FROM feature WHERE uuid = 'f-0001'")$comments, "gated")
  })
})
