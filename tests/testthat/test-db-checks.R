# PLAN-22 Part A: db_check(), db_checks_core(), db_checks_params(), db_checks().
# Fixture: dbc_db() (helper-db-checks.R) - seed_db() plus FKs, the QC tables,
# one row per linked table and two views; it satisfies every invariant. Nothing
# here touches the live DB.
#
# Spec choices pinned by these tests (PLAN-22 A1-A3 plus the test writer's
# rulings, reported to the orchestrator):
#   * db_check() returns a ONE-ROW data.frame with columns name, sql,
#     description, tier, severity; a check set (db_checks_core(), `extra`) is
#     a data.frame of such rows (rbind()).
#   * Every check's offending rows carry a `key` column (VARCHAR) naming the
#     offender; `sample` holds the first `sample_n` offending rows with it.
#   * db_checks_params(...) takes named overrides; defaults: bbox NULL (finite
#     coordinates pass), tz "Australia/Sydney" (no st_config() timezone key
#     exists, and the package's day convention is Sydney - CONTRACT A9),
#     mask_variants c("long", "old", "gas_report").
#   * view_nonempty is HOURLY (PLAN-22 A2 table: "28 + view_nonempty").
#   * measurement_view_coverage ignores analyses whose lab_method has no
#     analyte (they are invisible to every view by design - helper-db.R).
#   * fraction_matches_code only judges fractions in the vocabulary; a value
#     outside it is vocab_lab_method_fraction's finding alone.

# ---- db_check() ----------------------------------------------------------------------------

test_that("db_check(): one row with the five fields; tier and severity default to hourly / error", {
  ck <- db_check("my_check", "SELECT 'x' AS key WHERE FALSE", "A test check.")
  expect_s3_class(ck, "data.frame")
  expect_equal(nrow(ck), 1L)
  expect_true(all(c("name", "sql", "description", "tier", "severity") %in% names(ck)))
  expect_identical(ck$name, "my_check")
  expect_identical(ck$description, "A test check.")
  expect_identical(ck$tier, "hourly")
  expect_identical(ck$severity, "error")

  ck2 <- db_check("other", "SELECT 1 AS key WHERE FALSE", "d", tier = "on_demand", severity = "warn")
  expect_identical(ck2$tier, "on_demand")
  expect_identical(ck2$severity, "warn")
  both <- rbind(ck, ck2)
  expect_identical(both$name, c("my_check", "other"))
})

test_that("db_check(): rejects a bad tier, a bad severity, an empty name and a non-character sql", {
  dbc_expect_error(db_check("x", "SELECT 1 AS key", "d", tier = "weekly"))
  dbc_expect_error(db_check("x", "SELECT 1 AS key", "d", severity = "fatal"))
  dbc_expect_error(db_check("", "SELECT 1 AS key", "d"))
  dbc_expect_error(db_check(NA_character_, "SELECT 1 AS key", "d"))
  dbc_expect_error(db_check(c("a", "b"), "SELECT 1 AS key", "d"))
  dbc_expect_error(db_check("x", 42, "d"))
})

# ---- db_checks_core() / db_checks_params() ---------------------------------------------------

test_that("db_checks_core(): the 46 generic checks, uniquely named, with their pinned tiers and severities", {
  core <- db_checks_core()
  expect_s3_class(core, "data.frame")
  expect_true(all(c("name", "sql", "description", "tier", "severity") %in% names(core)))
  expect_false(anyDuplicated(core$name) > 0)
  expect_setequal(core$name, dbc_all_names)
  tier_of <- stats::setNames(core$tier, core$name)
  expect_true(all(tier_of[dbc_hourly_names] == "hourly"),
              info = paste(names(which(tier_of[dbc_hourly_names] != "hourly")), collapse = ","))
  expect_true(all(tier_of[dbc_migration_only_names] == "migration"),
              info = paste(names(which(tier_of[dbc_migration_only_names] != "migration")), collapse = ","))
  expect_true(all(tier_of[dbc_on_demand_names] == "on_demand"),
              info = paste(names(which(tier_of[dbc_on_demand_names] != "on_demand")), collapse = ","))
  sev_of <- stats::setNames(core$severity, core$name)
  expect_setequal(names(sev_of)[sev_of == "warn"], dbc_warn_names)
  expect_setequal(names(sev_of)[sev_of == "error"], setdiff(dbc_all_names, dbc_warn_names))
  expect_true(all(nzchar(core$description)))
})

test_that("db_checks_params(): defaults, and named overrides", {
  p <- db_checks_params()
  expect_type(p, "list")
  expect_true(all(c("min_date", "bbox", "tz", "mask_variants") %in% names(p)))
  expect_null(p$bbox)
  expect_identical(p$tz, "Australia/Sydney")
  expect_setequal(p$mask_variants, c("long", "old", "gas_report"))
  expect_length(p$min_date, 1L)

  b <- c(xmin = 150, ymin = -34, xmax = 151, ymax = -33)
  p2 <- db_checks_params(bbox = b, min_date = "2000-01-01")
  expect_equal(p2$bbox, b)
  expect_equal(as.character(p2$min_date), "2000-01-01")
  expect_identical(p2$tz, p$tz)
  dbc_expect_error(db_checks_params(no_such_param = 1))
})

# ---- the clean fixture -------------------------------------------------------------------------

test_that("db_checks(): the clean fixture passes every core check at tier 'all' (no false positives)", {
  db <- dbc_db()
  res <- dbc_run(db, tier = "all")
  expect_s3_class(res, "data.frame")
  expect_true(all(dbc_result_cols %in% names(res)), info = paste(names(res), collapse = ","))
  expect_setequal(res$name, dbc_all_names)
  expect_false(anyDuplicated(res$name) > 0)
  expect_true(all(res$status == "pass"), info = dbc_bad(res))
  expect_type(res$n, "integer")
  expect_true(all(res$n == 0L))
  expect_type(res$ms, "double")
  expect_true(all(!is.na(res$ms) & res$ms >= 0))
  expect_type(res$sample, "list")
  expect_true(all(res$status %in% c("pass", "fail", "error")))
  # tier/severity carried from the catalogue
  core <- db_checks_core()
  m <- match(res$name, core$name)
  expect_identical(res$tier, core$tier[m])
  expect_identical(res$severity, core$severity[m])
})

test_that("db_checks(): runs on a read-only connection and leaves the DB file byte-identical", {
  db <- dbc_db()
  before <- unname(tools::md5sum(db))
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  res <- db_checks(con, tier = "all")
  DBI::dbDisconnect(con, shutdown = TRUE)
  expect_true(all(res$status == "pass"), info = dbc_bad(res))
  expect_identical(unname(tools::md5sum(db)), before)
})

# ---- one seeded violation per check -----------------------------------------------------------

test_that("every core check has at least one seeded-violation case", {
  expect_setequal(unique(vapply(dbc_violation_cases, `[[`, "", "check")), dbc_all_names)
})

for (cs in dbc_violation_cases) local({
  cs <- cs
  test_that(sprintf("%s: %s -> only this check fails, n == 1, offender in the sample", cs$check, cs$label), {
    db <- dbc_db()
    params <- do.call(db_checks_params, if (is.null(cs$params)) list() else cs$params)
    res <- dbc_with(db, function(con) {
      cs$seed(con)
      db_checks(con, tier = "all", params = params)
    })
    dbc_expect_only(res, cs$check, cs$key)
  })
})

test_that("the bbox case passes when no bbox is configured (finite coordinates suffice)", {
  cs <- Filter(function(x) !is.null(x$params$bbox), dbc_violation_cases)[[1]]
  db <- dbc_db()
  res <- dbc_with(db, function(con) {
    cs$seed(con)
    db_checks(con, tier = "all")
  })
  expect_true(all(res$status == "pass"), info = dbc_bad(res))
})

test_that("FK-enforced orphans cannot be seeded, which is why no check re-tests them", {
  db <- dbc_db()
  dbc_with(db, function(con) {
    expect_error(DBI::dbExecute(con, "INSERT INTO analysis (uuid, uuid_sample, uuid_lab, value, quantified)
                                      VALUES ('an-fk', 's-gone', 'lm-0001', 1, TRUE)"))
    expect_error(DBI::dbExecute(con, "INSERT INTO \"sample\" (uuid, uuid_feature_alias, uuid_project, date)
                                      VALUES ('s-fk', 'fa-gone', 'p-0001', TIMESTAMP '2025-01-01 00:00:00')"))
    expect_error(DBI::dbExecute(con, "INSERT INTO review_queue_candidate (uuid, uuid_review, uuid_feature, kind, rank)
                                      VALUES ('rqc-fk', 'rq-gone', 'f-0001', 'structural', 1)"))
  })
})

# ---- sample_n ---------------------------------------------------------------------------------

test_that("db_checks(): n counts every offender; sample holds at most sample_n of them", {
  db <- dbc_db()
  dbc_with(db, function(con) {
    for (i in 1:7) dbc_exec(con, "INSERT INTO ingest_file (hash, state) VALUES (?, 'archived')",
                            sprintf("BAD-HASH-%02d", i))
    r5 <- dbc_row(db_checks(con, tier = "hourly"), "hash_format")
    expect_identical(r5$status, "fail")
    expect_identical(r5$n, 7L)
    expect_equal(nrow(r5$sample[[1]]), 5L)
    expect_true(all(grepl("^BAD-HASH-", r5$sample[[1]]$key)))
    r2 <- dbc_row(db_checks(con, tier = "hourly", sample_n = 2), "hash_format")
    expect_identical(r2$n, 7L)
    expect_equal(nrow(r2$sample[[1]]), 2L)
  })
})

# ---- SQL errors -----------------------------------------------------------------------------------

test_that("db_checks(): a check whose SQL fails gets status 'error' with the message; the rest still run", {
  db <- dbc_db()
  extra <- rbind(
    db_check("bad_table", "SELECT uuid AS key FROM no_such_table", "binder error"),
    db_check("bad_syntax", "SELEC key FROM", "parser error"),
    db_check("bad_runtime", "SELECT CAST('x' AS INTEGER) AS key", "runtime conversion error")
  )
  res <- dbc_with(db, function(con) db_checks(con, tier = "hourly", extra = extra))
  for (nm in extra$name) {
    r <- dbc_row(res, nm)
    expect_identical(r$status, "error", info = nm)
    expect_true(is.na(r$n), info = nm)
    expect_true(is.character(r$message) && nzchar(r$message), info = nm)
  }
  expect_match(dbc_row(res, "bad_table")$message, "no_such_table", fixed = TRUE)
  core <- res[!res$name %in% extra$name, , drop = FALSE]
  expect_setequal(core$name, dbc_hourly_names)
  expect_true(all(core$status == "pass"), info = dbc_bad(core))
})

test_that("db_checks(): a core check reading a missing table errors without stopping the others", {
  db <- dbc_db()
  res <- dbc_with(db, function(con) {
    DBI::dbExecute(con, "DROP TABLE lab_qc_outlier")
    db_checks(con, tier = "hourly")
  })
  expect_identical(dbc_row(res, "orphan_qc_refs")$status, "error")
  rest <- res[res$name != "orphan_qc_refs", , drop = FALSE]
  expect_true(all(rest$status == "pass"), info = dbc_bad(rest))
})

test_that("db_checks(): inside an open transaction a runtime SQL error is reported, not raised", {
  # DuckDB aborts the whole transaction on an execution-time error, so the
  # later checks may error too; db_checks() must still return a result.
  db <- dbc_db()
  dbc_with(db, function(con) {
    DBI::dbBegin(con)
    on.exit(try(DBI::dbRollback(con), silent = TRUE), add = TRUE)
    res <- db_checks(con, tier = "hourly",
                     extra = db_check("bad_runtime", "SELECT CAST('x' AS INTEGER) AS key", "d"))
    expect_identical(dbc_row(res, "bad_runtime")$status, "error")
    expect_true(all(res$status %in% c("pass", "fail", "error")))
  })
})

# ---- tiers ---------------------------------------------------------------------------------------

test_that("db_checks(): tiers nest hourly < migration < all", {
  db <- dbc_db()
  dbc_with(db, function(con) {
    expect_setequal(db_checks(con)$name, dbc_hourly_names)   # default tier = hourly
    expect_setequal(db_checks(con, tier = "migration")$name,
                    c(dbc_hourly_names, dbc_migration_only_names))
    expect_setequal(db_checks(con, tier = "all")$name, dbc_all_names)
    dbc_expect_error(db_checks(con, tier = "weekly"))
  })
})

test_that("db_checks(): a migration-tier violation is invisible at tier hourly", {
  db <- dbc_db()
  dbc_with(db, function(con) {
    DBI::dbExecute(con, "DROP INDEX ux_sample_identity")
    expect_true(all(db_checks(con, tier = "hourly")$status == "pass"))
    expect_identical(dbc_row(db_checks(con, tier = "migration"), "expected_constraints_present")$status, "fail")
  })
})

# ---- extra ------------------------------------------------------------------------------------------

test_that("db_checks(extra): deployment checks run alongside core, under their own tier and severity", {
  db <- dbc_db()
  extra <- rbind(
    db_check("site_codes_valid", "SELECT uuid AS key FROM feature WHERE site NOT IN ('T', 'TH', 'Z')",
             "Every feature's site is a known site.", tier = "hourly", severity = "error"),
    db_check("epa_point_mapped", "SELECT 'B.E01' AS key", "EPA point has a feature.",
             tier = "migration", severity = "warn"),
    db_check("epa_return_rows", "SELECT 'q1' AS key", "EPA return queries return rows.",
             tier = "on_demand", severity = "error")
  )
  dbc_with(db, function(con) {
    h <- db_checks(con, tier = "hourly", extra = extra)
    expect_setequal(h$name, c(dbc_hourly_names, "site_codes_valid"))
    expect_identical(dbc_row(h, "site_codes_valid")$status, "pass")

    m <- db_checks(con, tier = "migration", extra = extra)
    expect_true("epa_point_mapped" %in% m$name)
    expect_false("epa_return_rows" %in% m$name)
    r <- dbc_row(m, "epa_point_mapped")
    expect_identical(r$status, "fail")
    expect_identical(r$severity, "warn")
    expect_identical(r$tier, "migration")
    expect_identical(r$n, 1L)
    expect_identical(as.character(r$sample[[1]]$key), "B.E01")

    a <- db_checks(con, tier = "all", extra = extra)
    expect_setequal(a$name, c(dbc_all_names, extra$name))
  })
})

test_that("db_checks(extra): a name clashing with a core check, or repeated within extra, is an error", {
  db <- dbc_db()
  dbc_with(db, function(con) {
    dbc_expect_error(db_checks(con, extra = db_check("hash_format", "SELECT 1 AS key WHERE FALSE", "clash")),
                     "hash_format")
    twice <- rbind(db_check("dep_x", "SELECT 1 AS key WHERE FALSE", "a"),
                   db_check("dep_x", "SELECT 1 AS key WHERE FALSE", "b"))
    dbc_expect_error(db_checks(con, extra = twice), "dep_x")
  })
})

# ---- {param} substitution ------------------------------------------------------------------------

test_that("db_checks(params): min_date flags samples before it", {
  db <- dbc_db()
  # s-0003 (2025-05-10) is the only fixture sample before 2025-05-11.
  res <- dbc_with(db, function(con) db_checks(con, params = db_checks_params(min_date = "2025-05-11")))
  dbc_expect_only(res, "sample_date_plausible", "s-0003")
})

test_that("db_checks(params): tz sets the day sample.date and sample.datetime must agree on", {
  db <- dbc_db()
  # The fixture's datetimes are UTC instants of Sydney wall-clock times; four
  # of them fall on the previous UTC day.
  res <- dbc_with(db, function(con) db_checks(con, params = db_checks_params(tz = "UTC")))
  r <- dbc_row(res, "sample_date_datetime_agree")
  expect_identical(r$status, "fail")
  expect_identical(r$n, 4L)
  expect_false(any(grepl("s-0001", r$sample[[1]]$key, fixed = TRUE)))
})

test_that("db_checks(params): mask_variants registers a deployment's own variant", {
  db <- dbc_db()
  dbc_with(db, function(con) {
    DBI::dbExecute(con, "INSERT INTO feature_mask VALUES ('f-0002', 'epa', 'Licence point 1')")
    expect_identical(dbc_row(db_checks(con), "vocab_mask_variant")$status, "fail")
    p <- db_checks_params(mask_variants = c("long", "old", "gas_report", "epa"))
    expect_identical(dbc_row(db_checks(con, params = p), "vocab_mask_variant")$status, "pass")
  })
})

test_that("db_checks(params): {param} tokens are filled in extra checks' SQL too", {
  db <- dbc_db()
  extra <- db_check("dep_window", "SELECT 'early' AS key WHERE DATE '{min_date}' > DATE '2000-01-01'", "d")
  dbc_with(db, function(con) {
    late <- db_checks(con, extra = extra, params = db_checks_params(min_date = "2001-01-01"))
    expect_identical(dbc_row(late, "dep_window")$status, "fail")
    early <- db_checks(con, extra = extra, params = db_checks_params(min_date = "1999-01-01"))
    expect_identical(dbc_row(early, "dep_window")$status, "pass")
  })
})
