# PLAN-23 3.5, 17/18 Nov revision: the register checks for ended features,
# class/flow, dated masks and common names, and the link tables.
#   R-23.24  feature_sample_after_end (through a non-self arm), feature_self_arm_end,
#            feature_class_flow (a bore with flow 'still'; a class with no rule passes)
#   R-23.30  each new check is in the core with its tier and severity, the clean
#            fixture passes it (the one-violation-each table is dbc_violation_cases
#            in helper-db-checks.R, run by test-db-checks.R); the extra columns and
#            boundaries are here
#   R-23.20  expected_constraints_present: the mask's and link tables' primary keys,
#            only when they exist
#   R-23.7   every new check passes with zero rows on a pre-117 database
# Fixture: dbc_db() (helper-db-checks.R).

new_hourly <- setdiff(dbc_register_1117_names, "register_comments_present")
new_warn <- c("feature_class_flow", "feature_self_arm_end", "feature_common_alias",
              "feature_predecessor_dates", "feature_flow_dates", "register_comments_present")

run_one <- function(db, name, params = db_checks_params(), seed = NULL, tier = "all") {
  dbc_with(db, function(con) {
    if (!is.null(seed)) seed(con)
    dbc_row(db_checks(con, tier = tier, params = params), name)
  })
}

# every offending key (`keys`), not the first `sample_n` rows of `sample`
sample_keys <- function(r) as.character(r$keys[[1]])

# ---- the catalogue (R-23.30) -----------------------------------------------------------------

test_that("R-23.30: the 17/18 Nov register checks are in the core with 3.5's tiers and severities", {
  core <- db_checks_core()
  expect_true(all(dbc_register_1117_names %in% core$name),
              info = paste(setdiff(dbc_register_1117_names, core$name), collapse = ", "))
  tier_of <- stats::setNames(core$tier, core$name)
  sev_of <- stats::setNames(core$severity, core$name)
  expect_true(all(tier_of[new_hourly] == "hourly"), info = paste(new_hourly, tier_of[new_hourly], collapse = ", "))
  expect_identical(unname(tier_of["register_comments_present"]), "migration")
  expect_true(all(sev_of[new_warn] == "warn"))
  expect_true(all(sev_of[setdiff(dbc_register_1117_names, new_warn)] == "error"))
})

test_that("R-23.30: the existing feature.flow check keeps its name and meaning; the flow-link vocabulary is a separate check", {
  core <- db_checks_core()
  expect_true(all(c("vocab_feature_flow", "vocab_feature_flow_link") %in% core$name))
  db <- dbc_db()
  r <- run_one(db, "vocab_feature_flow",
               seed = function(con) DBI::dbExecute(con, "INSERT INTO feature_flow (uuid, uuid_from, uuid_to, drive, source)
                                                         VALUES ('ff-x', 'f-0001', 'f-0002', 'siphon', 'doc')"))
  expect_identical(r$status, "pass")    # a bad drive is not a feature.flow problem
})

test_that("R-23.30: the clean fixture passes every new check with n == 0", {
  db <- dbc_db()
  res <- dbc_run(db, tier = "all")
  r <- res[res$name %in% dbc_register_1117_names, ]
  expect_setequal(r$name, dbc_register_1117_names)
  expect_true(all(r$status == "pass"), info = dbc_bad(res))
  expect_true(all(r$n == 0L))
})

test_that("R-23.30: vocab_mask_variant now registers common and no longer old (a stray 'old' row after 117 is reported)", {
  db <- dbc_db()
  r <- run_one(db, "vocab_mask_variant", seed = function(con) {
    DBI::dbExecute(con, "INSERT INTO feature_mask (uuid, uuid_feature, variant, name) VALUES ('fm-old', 'f-0004', 'old', 'T.S00')")
  })
  expect_identical(r$status, "fail")
  expect_true(any(grepl("old", sample_keys(r), fixed = TRUE)))
  # the fixture's own common rows are not reported
  expect_false(any(grepl("common", sample_keys(r), fixed = TRUE)))
})

# ---- R-23.24 ------------------------------------------------------------------------------------

test_that("R-23.24: feature_sample_after_end reports a sample dated after its feature's end, reached through a NON-self arm; extra columns date_end, alias_name", {
  db <- dbc_db()
  r <- run_one(db, "feature_sample_after_end", tier = "hourly", seed = function(con) {
    dbc_new_sample(con, "s-late", alias = "fa-0007", date = "2025-01-01", datetime = "2024-12-31 23:00:00")
  })
  expect_identical(r$status, "fail")
  expect_identical(r$n, 1L)
  smp <- r$sample[[1]]
  expect_identical(as.character(smp$key), "s-late")
  expect_true(all(c("date_end", "alias_name") %in% names(smp)))
  expect_equal(as.Date(smp$date_end), as.Date("2020-06-30"))
  expect_identical(smp$alias_name, "T.REUSED")
})

test_that("R-23.24: feature_sample_after_end reports through the self arm too, and not a sample ON the end date (ends are inclusive)", {
  db <- dbc_db()
  r <- run_one(db, "feature_sample_after_end", tier = "hourly", seed = function(con) {
    # f-0006 ended 2020-06-30 (Sydney day); s-on is midday that day, s-after the next day.
    dbc_new_sample(con, "s-on", alias = "fa-0013", date = "2020-06-30", datetime = "2020-06-30 02:00:00")
    dbc_new_sample(con, "s-after", alias = "fa-0013", date = "2020-07-01", datetime = "2020-07-01 02:00:00")
  })
  expect_identical(r$n, 1L)
  expect_identical(sample_keys(r), "s-after")
})

test_that("R-23.24: feature_sample_after_end ignores samples of features that have not ended", {
  db <- dbc_db()
  r <- run_one(db, "feature_sample_after_end", tier = "hourly", seed = function(con) {
    dbc_new_sample(con, "s-live", alias = "fa-0002", date = "2026-01-01", datetime = "2026-01-01 02:00:00")
  })
  expect_identical(r$status, "pass")
})

test_that("R-23.24: feature_self_arm_end reports an ended feature with an open self arm (key = feature uuid)", {
  db <- dbc_db()
  r <- run_one(db, "feature_self_arm_end",
               seed = function(con) DBI::dbExecute(con, "UPDATE feature_alias SET date_end = NULL WHERE uuid = 'fa-0013'"))
  expect_identical(r$status, "fail")
  expect_identical(sample_keys(r), "f-0006")
})

test_that("R-23.24: feature_self_arm_end reports an ended feature whose self arm ends on a DIFFERENT date, and a live feature whose self arm is bounded", {
  db <- dbc_db()
  r <- run_one(db, "feature_self_arm_end", seed = function(con) {
    DBI::dbExecute(con, "UPDATE feature_alias SET date_end = DATE '2021-01-01' WHERE uuid = 'fa-0013'")
    DBI::dbExecute(con, "UPDATE feature_alias SET date_end = DATE '2025-12-31' WHERE uuid = 'fa-0002'")
  })
  expect_identical(r$n, 2L)
  expect_setequal(sample_keys(r), c("f-0006", "f-0002"))
})

test_that("R-23.24: feature_class_flow reports a bore with flow 'still', with columns class and flow", {
  db <- dbc_db()
  r <- run_one(db, "feature_class_flow",
               seed = function(con) DBI::dbExecute(con, "UPDATE feature SET flow = 'still' WHERE uuid = 'f-0003'"))
  expect_identical(r$status, "fail")
  smp <- r$sample[[1]]
  expect_identical(as.character(smp$key), "f-0003")
  expect_identical(smp$class, "bore")
  expect_identical(smp$flow, "still")
})

test_that("R-23.24: feature_class_flow passes a class it has no rule for, a NULL flow, an allowed flow, and reads params$class_flow", {
  db <- dbc_db()
  seed <- function(con) {
    DBI::dbExecute(con, "UPDATE feature SET class = 'pipe', flow = 'seep' WHERE uuid = 'f-0001'")       # no rule
    DBI::dbExecute(con, "UPDATE feature SET class = 'gas_well', flow = NULL WHERE uuid = 'f-0002'")      # NULL always passes
    DBI::dbExecute(con, "UPDATE feature SET class = 'dam', flow = 'flowing' WHERE uuid = 'f-0004'")      # allowed
    DBI::dbExecute(con, "UPDATE feature SET class = 'sampling_point', flow = 'groundwater' WHERE uuid = 'f-0005'")  # any
  }
  expect_identical(run_one(db, "feature_class_flow", seed = seed)$status, "pass")
  db2 <- dbc_db()
  r <- run_one(db2, "feature_class_flow", seed = seed,
               params = db_checks_params(class_flow = list(pipe = "flowing")))
  expect_identical(r$status, "fail")
  expect_identical(sample_keys(r), "f-0001")
})

test_that("R-23.24: feature_class_flow: a gas well may have no flow at all (an empty rule refuses every non-NULL flow)", {
  db <- dbc_db()
  r <- run_one(db, "feature_class_flow",
               seed = function(con) DBI::dbExecute(con, "UPDATE feature SET class = 'gas_well', flow = 'flowing' WHERE uuid = 'f-0002'"))
  expect_identical(r$status, "fail")
  expect_identical(sample_keys(r), "f-0002")
})

# ---- masks and common names --------------------------------------------------------------------

test_that("R-23.30: feature_mask_overlap: rows of different variants, and rows of one variant with disjoint windows, are not reported; one shared day is", {
  db <- dbc_db()
  ok <- run_one(db, "feature_mask_overlap", seed = function(con) {
    DBI::dbExecute(con, "INSERT INTO feature_mask (uuid, uuid_feature, variant, name, date_start, date_end) VALUES
                         ('fm-a1', 'f-0004', 'long', 'Fourth creek', NULL, DATE '2024-12-31'),
                         ('fm-a2', 'f-0004', 'long', 'Fourth creek east', DATE '2025-01-01', NULL),
                         ('fm-a3', 'f-0004', 'gas_report', 'G4', NULL, NULL)")
  })
  expect_identical(ok$status, "pass")
  db2 <- dbc_db()
  r <- run_one(db2, "feature_mask_overlap", seed = function(con) {
    DBI::dbExecute(con, "INSERT INTO feature_mask (uuid, uuid_feature, variant, name, date_start, date_end) VALUES
                         ('fm-a1', 'f-0004', 'long', 'Fourth creek', NULL, DATE '2025-01-01'),
                         ('fm-a2', 'f-0004', 'long', 'Fourth creek east', DATE '2025-01-01', NULL)")
  })
  expect_identical(r$status, "fail")
  expect_identical(r$n, 1L)
  smp <- r$sample[[1]]
  expect_true(all(c("variant", "other") %in% names(smp)))
  expect_setequal(c(as.character(smp$key), smp$other), c("fm-a1", "fm-a2"))
  expect_identical(smp$variant, "long")
})

test_that("R-23.30: feature_common_unique: two features holding one common name on overlapping windows are reported, with name and other_feature", {
  db <- dbc_db()
  r <- run_one(db, "feature_common_unique", seed = function(con) {
    DBI::dbExecute(con, "UPDATE feature_mask SET date_end = DATE '2025-01-01' WHERE uuid = 'fm-0004'")
  })
  expect_identical(r$status, "fail")
  smp <- r$sample[[1]]
  expect_true(all(c("name", "other_feature") %in% names(smp)))
  expect_true(any(c("fm-0004", "fm-0005") %in% as.character(smp$key)))
  expect_true(all(smp$name == "T.SN01"))
})

test_that("R-23.30: feature_common_unique compares by the canonical key: T.SN1 on another feature clashes with T.SN01", {
  db <- dbc_db()
  r <- run_one(db, "feature_common_unique", seed = function(con) {
    DBI::dbExecute(con, "INSERT INTO feature_mask (uuid, uuid_feature, variant, name) VALUES ('fm-c1', 'f-0004', 'common', 'T.SN1')")
  })
  expect_identical(r$status, "fail")
  expect_true("fm-c1" %in% sample_keys(r))
})

test_that("R-23.30: feature_common_unique: a feature's common name equal to its OWN systematic name is not a clash", {
  db <- dbc_db()
  r <- run_one(db, "feature_common_unique", seed = function(con) {
    DBI::dbExecute(con, "INSERT INTO feature_mask (uuid, uuid_feature, variant, name) VALUES ('fm-own', 'f-0004', 'common', 'T.S04')")
  })
  expect_identical(r$status, "pass")
})

test_that("R-23.30: feature_common_alias: an arm whose window does not COVER the mask row's is reported; one that does is not", {
  db <- dbc_db()
  r <- run_one(db, "feature_common_alias", seed = function(con) {
    # T.SN01 on f-0007 from 2025-01-01: move its arm's start a year later
    DBI::dbExecute(con, "UPDATE feature_alias SET date_start = DATE '2026-01-01' WHERE uuid = 'fa-0026'")
  })
  expect_identical(r$status, "fail")
  expect_identical(sample_keys(r), "fm-0005")
  db2 <- dbc_db()
  ok <- run_one(db2, "feature_common_alias", seed = function(con) {
    # a WIDER arm covers it too
    DBI::dbExecute(con, "UPDATE feature_alias SET date_start = DATE '2024-01-01' WHERE uuid = 'fa-0026'")
  })
  expect_identical(ok$status, "pass")
})

test_that("R-23.30: feature_common_alias: an arm of the same key on ANOTHER feature does not count", {
  db <- dbc_db()
  r <- run_one(db, "feature_common_alias", seed = function(con) {
    DBI::dbExecute(con, "UPDATE feature_alias SET uuid_feature = 'f-0005' WHERE uuid = 'fa-0026'")
  })
  expect_identical(r$status, "fail")
  expect_identical(sample_keys(r), "fm-0005")
})

# ---- the link tables ---------------------------------------------------------------------------

test_that("R-23.30: orphan_feature_link names the table of each orphan (column tbl), for both link tables", {
  db <- dbc_db()
  r <- run_one(db, "orphan_feature_link", seed = function(con) {
    DBI::dbExecute(con, "INSERT INTO feature_predecessor (uuid, uuid_feature, uuid_predecessor, source)
                         VALUES ('fp-o', 'f-gone', 'f-0001', 'doc')")
    DBI::dbExecute(con, "INSERT INTO feature_flow (uuid, uuid_from, uuid_to, drive, source)
                         VALUES ('ff-o', 'f-0001', 'f-gone', 'gravity', 'doc')")
  })
  expect_identical(r$n, 2L)
  smp <- r$sample[[1]]
  expect_true("tbl" %in% names(smp))
  expect_identical(smp$tbl[as.character(smp$key) == "fp-o"], "feature_predecessor")
  expect_identical(smp$tbl[as.character(smp$key) == "ff-o"], "feature_flow")
})

test_that("R-23.30: feature_predecessor_cycle reports every row on a three-row loop and none on a line", {
  db <- dbc_db()
  r <- run_one(db, "feature_predecessor_cycle", seed = function(con) {
    DBI::dbExecute(con, "INSERT INTO feature_predecessor (uuid, uuid_feature, uuid_predecessor, source) VALUES
                         ('fp-c2', 'f-0004', 'f-0007', 'doc'), ('fp-c3', 'f-0006', 'f-0004', 'doc'),
                         ('fp-line', 'f-0005', 'f-0004', 'doc')")
  })
  expect_identical(r$n, 3L)
  expect_setequal(sample_keys(r), c("fp-0001", "fp-c2", "fp-c3"))
})

test_that("R-23.30: feature_predecessor_dates: a date_break before the predecessor's date_start is reported; extra columns date_break, last_predecessor_sample", {
  db <- dbc_db()
  r <- run_one(db, "feature_predecessor_dates", seed = function(con) {
    DBI::dbExecute(con, "UPDATE feature SET date_start = DATE '2021-01-01' WHERE uuid = 'f-0006'")
    DBI::dbExecute(con, "UPDATE feature SET date_end = DATE '2022-06-30' WHERE uuid = 'f-0006'")
    DBI::dbExecute(con, "UPDATE feature_alias SET date_end = DATE '2022-06-30' WHERE uuid = 'fa-0013'")
  })
  expect_identical(r$status, "fail")
  smp <- r$sample[[1]]
  expect_identical(as.character(smp$key), "fp-0001")
  expect_true(all(c("date_break", "last_predecessor_sample") %in% names(smp)))
})

test_that("R-23.30: feature_predecessor_dates: the predecessor's last sample the day BEFORE date_break passes; on date_break it is reported", {
  db <- dbc_db()
  # f-0001's last sample is 2025-05-24 (Sydney day).
  ok <- run_one(db, "feature_predecessor_dates", seed = function(con) {
    DBI::dbExecute(con, "INSERT INTO feature_predecessor (uuid, uuid_feature, uuid_predecessor, date_break, source)
                         VALUES ('fp-d1', 'f-0004', 'f-0001', DATE '2025-05-25', 'doc')")
  })
  expect_identical(ok$status, "pass")
  db2 <- dbc_db()
  r <- run_one(db2, "feature_predecessor_dates", seed = function(con) {
    DBI::dbExecute(con, "INSERT INTO feature_predecessor (uuid, uuid_feature, uuid_predecessor, date_break, source)
                         VALUES ('fp-d2', 'f-0004', 'f-0001', DATE '2025-05-24', 'doc')")
  })
  expect_identical(r$status, "fail")
  expect_identical(sample_keys(r), "fp-d2")
  expect_equal(as.Date(r$sample[[1]]$last_predecessor_sample), as.Date("2025-05-24"))
})

test_that("R-23.30: feature_flow_overlap: the reverse direction is a different link; a link that ends the day before the next starts is fine", {
  db <- dbc_db()
  ok <- run_one(db, "feature_flow_overlap", seed = function(con) {
    DBI::dbExecute(con, "UPDATE feature_flow SET date_end = DATE '2025-12-31' WHERE uuid = 'ff-0001'")
    DBI::dbExecute(con, "INSERT INTO feature_flow (uuid, uuid_from, uuid_to, drive, date_start, source) VALUES
                         ('ff-next', 'f-0005', 'f-0007', 'pumped', DATE '2026-01-01', 'doc'),
                         ('ff-back', 'f-0007', 'f-0005', 'pumped', DATE '2024-06-01', 'doc')")
  })
  expect_identical(ok$status, "pass")
})

test_that("R-23.30: feature_flow_dates: a link starting before an end's date_start is reported; a link inside both windows is not", {
  db <- dbc_db()
  r <- run_one(db, "feature_flow_dates", seed = function(con) {
    DBI::dbExecute(con, "UPDATE feature SET date_start = DATE '2025-01-01' WHERE uuid = 'f-0007'")
  })
  expect_identical(r$status, "fail")
  expect_identical(sample_keys(r), "ff-0001")
  db2 <- dbc_db()
  ok <- run_one(db2, "feature_flow_dates", seed = function(con) {
    DBI::dbExecute(con, "UPDATE feature SET date_start = DATE '2023-01-01' WHERE uuid = 'f-0007'")
    DBI::dbExecute(con, "INSERT INTO feature_flow (uuid, uuid_from, uuid_to, drive, date_start, date_end, source)
                         VALUES ('ff-in', 'f-0001', 'f-0006', 'gravity', DATE '2019-01-01', DATE '2020-06-30', 'doc')")
  })
  expect_identical(ok$status, "pass")
})

test_that("R-23.30: register_comments_present reports each register table that lost its comment, keyed by table name", {
  db <- dbc_db()
  r <- run_one(db, "register_comments_present", seed = function(con) {
    DBI::dbExecute(con, "COMMENT ON TABLE feature_mask IS NULL")
    DBI::dbExecute(con, "COMMENT ON TABLE feature_predecessor IS NULL")
  })
  expect_identical(r$n, 2L)
  expect_setequal(sample_keys(r), c("feature_mask", "feature_predecessor"))
})

# ---- R-23.20 -----------------------------------------------------------------------------------

test_that("R-23.20: expected_constraints_present reports a feature_predecessor without its primary key", {
  db <- dbc_db()
  r <- run_one(db, "expected_constraints_present", seed = function(con) {
    DBI::dbExecute(con, "CREATE TEMP TABLE keep_fp AS SELECT * FROM feature_predecessor")
    DBI::dbExecute(con, "DROP TABLE feature_predecessor")
    DBI::dbExecute(con, "CREATE TABLE feature_predecessor (uuid VARCHAR, uuid_feature VARCHAR NOT NULL,
                         uuid_predecessor VARCHAR NOT NULL, date_break DATE, source VARCHAR NOT NULL, comments VARCHAR)")
    DBI::dbExecute(con, "INSERT INTO feature_predecessor SELECT * FROM keep_fp")
  })
  expect_identical(r$status, "fail")
  expect_true("feature_predecessor.uuid PRIMARY KEY" %in% sample_keys(r))
})

test_that("R-23.20: on a pre-117 database (undated mask, no link tables) the new keys are not required", {
  old <- local_pre117_db()
  con <- DBI::dbConnect(duckdb::duckdb(), old, read_only = FALSE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  r <- dbc_row(db_checks(con, tier = "all"), "expected_constraints_present")
  keys <- if (nrow(r) == 1L && identical(r$status, "fail")) sample_keys(r) else character(0)
  expect_false(any(c("feature_mask.uuid PRIMARY KEY", "feature_predecessor.uuid PRIMARY KEY",
                     "feature_flow.uuid PRIMARY KEY") %in% keys))
  expect_identical(nrow(r), 1L)
  expect_false(identical(r$status, "error"), info = r$message)
})

# ---- R-23.7 ------------------------------------------------------------------------------------

test_that("R-23.7: on a pre-117 database every new register check passes with zero rows", {
  old <- local_pre117_db()
  con <- DBI::dbConnect(duckdb::duckdb(), old, read_only = FALSE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  # A pre-117 database can still hold an ended feature with an open self arm and
  # a sample after the end; the guard means none of it is reported yet.
  DBI::dbExecute(con, "INSERT INTO \"sample\" (uuid, uuid_feature_alias, uuid_project, date, datetime, organisation)
                       VALUES ('s-pre', 'fa-0013', 'p-0001', TIMESTAMP '2025-01-01 00:00:00',
                               TIMESTAMP '2025-01-01 02:00:00', 'ALS')")
  res <- db_checks(con, tier = "all")
  r <- res[res$name %in% dbc_register_1117_names, ]
  expect_setequal(r$name, dbc_register_1117_names)
  expect_true(all(r$status == "pass"), info = paste(r$name, r$status, r$message, collapse = "; "))
  expect_true(all(r$n == 0L))
})
