# PLAN-19 phase 1: how the QC flag checks plug into import_flags()
# (R-19.22 `action` column, R-19.23 `checks$qc`, section 6's check order and
# "a DB older than 048 still refreshes"). Synthetic DBs from helper-flags.R +
# helper-qc.R; every code and parent is invented (site Q, see helper-qc.R).

wo <- "ES2600501"
d_round <- "2026-09-28"

# A duplicate that fails (Zinc RPD 67%) next to two passing analytes: one
# qc_dup_rpd flag. Also gives lab_qc_missing (ALS results, no QCI).
wiring_db <- function(env = parent.frame()) {
  db <- qc_db(env = env)
  fl_with(db, function(con) {
    qc_add(con, "Q.JD42", "duplicate", parent = "Q.X01")
    fl_sample(con, "Q.X01", wo, d_round, results = list(
      qc_lab("Zinc", 0.10, rl = 0.005), qc_lab("Copper", 0.10, rl = 0.001),
      qc_lab("Nickel", 0.010, rl = 0.001)))
    fl_sample(con, "Q.JD42", wo, d_round, results = list(
      qc_lab("Zinc", 0.05, rl = 0.005), qc_lab("Copper", 0.11, rl = 0.001),
      qc_lab("Nickel", 0.011, rl = 0.001)))
  })
  db
}

test_that("R-19.22: `action` is a character column right after `source`; NA for every pre-existing check", {
  db <- qc_db()
  fl_with(db, function(con) {
    fl_sample(con, "B.E01", "ES2600500", "2026-09-11", results = list(`NH3-N` = 2))
  })
  f <- fl_run(db, fl_checks(schedule = fl_schedule(list(site = "K", months = "8")),
                            limits = fl_limits(list(max = "0.9"))))
  expect_identical(names(f), fl_flag_cols)
  expect_identical(names(f)[[match("source", names(f)) + 1L]], "action")
  expect_type(f$action, "character")
  old <- f[f$check %in% c("overdue", "licence_limit"), , drop = FALSE]
  expect_gte(nrow(old), 2)
  expect_true(all(is.na(old$action)))
  # an empty result carries the column too
  f0 <- fl_run(qc_db(), fl_checks())
  expect_identical(names(f0), fl_flag_cols)
})

test_that("section 6: the QC checks follow unit_change in the pinned order, with a meaning and a function each", {
  ck <- sampleTidy:::.flags_checks
  expect_true(all(.qc_phase1_checks %in% ck))
  # phase-1 checks keep the plan's relative order (later-phase checks may sit between)
  pos <- match(intersect(.qc_all_checks, ck), ck)
  expect_false(is.unsorted(pos))
  expect_true(all(pos > match("unit_change", ck)))
  # the pre-existing checks keep their place at the front
  expect_identical(ck[1:9], c("overdue", "invoiced_not_received", "missing_point",
                              "missing_analytes", "licence_limit", "gas_criterion",
                              "site_history", "rl_change", "unit_change"))
  expect_true(all(.qc_phase1_checks %in% names(sampleTidy:::.flags_meanings)))
  expect_true(all(.qc_phase1_checks %in% names(sampleTidy:::.flags_fns)))
  expect_true(all(nzchar(sampleTidy:::.flags_meanings[.qc_phase1_checks])))
})

test_that("R-19.23: checks$qc is accepted; NULL disables every qc_* check but not lab_qc_missing", {
  db <- wiring_db()
  f <- fl_run(db, qc_checks())
  expect_length(attr(f, "errors"), 0)
  expect_equal(nrow(fl_of(f, "qc_dup_rpd")), 1)
  expect_equal(nrow(fl_of(f, "lab_qc_missing")), 1)

  f0 <- fl_run(db, qc_checks(qc = NULL))
  expect_length(attr(f0, "errors"), 0)
  expect_false(any(grepl("^qc_", f0$check)))
  # lab_qc_* needs only the DB
  expect_equal(nrow(fl_of(f0, "lab_qc_missing")), 1)
})

test_that("R-19.23: criteria and requirements given as CSV paths give the same flags as data.frames", {
  db <- wiring_db()
  d <- withr::local_tempdir()
  cp <- file.path(d, "qc_criteria.csv")
  rp <- file.path(d, "qc_requirements.csv")
  utils::write.csv(qc_criteria_df(), cp, row.names = FALSE, na = "")
  utils::write.csv(qc_requirements_df(), rp, row.names = FALSE, na = "")
  f_df <- fl_run(db, qc_checks())
  f_csv <- fl_run(db, qc_checks(qc = list(criteria = cp, requirements = rp)))
  expect_length(attr(f_csv, "errors"), 0)
  expect_gt(nrow(fl_of(f_csv, "qc_dup_rpd")), 0)
  expect_identical(f_csv$key, f_df$key)
  expect_identical(f_csv$detail, f_df$detail)
  expect_identical(f_csv$action, f_df$action)
})

test_that("R-19.33: an unknown criteria rule, or a missing required rule, is an error of the qc_* checks - not a crash", {
  db <- wiring_db()
  fl_with(db, function(con) {
    fl_sample(con, "B.E01", "ES2600500", "2026-09-11", results = list(`NH3-N` = 2))
  })
  lim <- fl_limits(list(max = "0.9"))
  bad_rule <- qc_criteria_df()
  bad_rule$rule[[1]] <- "dup_lor_multipel"
  no_rpd <- qc_criteria_df()
  no_rpd <- no_rpd[no_rpd$rule != "dup_rpd", , drop = FALSE]
  for (crit in list(bad_rule, no_rpd)) {
    f <- fl_run(db, qc_checks(criteria = crit, limits = lim))
    expect_identical(names(f), fl_flag_cols)
    expect_true("qc_dup_rpd" %in% names(attr(f, "errors")))
    expect_equal(nrow(fl_of(f, "qc_dup_rpd")), 0)
    # other checks still run
    expect_equal(nrow(fl_of(f, "licence_limit")), 1)
    expect_false("licence_limit" %in% names(attr(f, "errors")))
  }
})

test_that("section 6: a DB older than 048 (no QC tables) still refreshes - no QC rows, no errors", {
  db <- qc_db(tables = FALSE)
  fl_with(db, function(con) {
    fl_sample(con, "Q.X01", wo, d_round, results = list(qc_lab("Zinc", 0.1, rl = 0.005)))
    fl_sample(con, "B.E01", "ES2600500", "2026-09-11", results = list(`NH3-N` = 2))
  })
  f <- fl_run(db, qc_checks(limits = fl_limits(list(max = "0.9"))))
  expect_length(attr(f, "errors"), 0)
  expect_false(any(f$check %in% .qc_all_checks))
  # [invented: with no lab_qc_report table there is nothing to compare against,
  #  so lab_qc_missing gives no rows - otherwise every pre-048 refresh, and
  #  every pre-PLAN-19 flags test with an ALS sample, would grow flags.]
  expect_equal(nrow(fl_of(f, "licence_limit")), 1)
})

test_that("section 6: a qc_feature table with no rows gives no qc_* rows and no errors", {
  db <- qc_db()
  fl_with(db, function(con) {
    fl_sample(con, "Q.X01", wo, d_round, results = list(qc_lab("Zinc", 0.1, rl = 0.005)))
  })
  f <- fl_run(db, qc_checks())
  expect_length(attr(f, "errors"), 0)
  expect_false(any(f$check %in% c("qc_dup_rpd", "qc_blank_detect", "qc_unresolved")))
})

test_that("R-19.22: the status note's QC line ends with the action text; the JSON carries `action`", {
  s <- fl_status_setup()
  fl_with(s$db, qc_create_tables)
  fl_with(s$db, function(con) {
    qc_add(con, "Q.JD42", "duplicate", parent = "Q.X01")
    fl_sample(con, "Q.X01", wo, d_round, results = list(
      qc_lab("Zinc", 0.10, rl = 0.005), qc_lab("Copper", 0.10, rl = 0.001),
      qc_lab("Nickel", 0.010, rl = 0.001)))
    fl_sample(con, "Q.JD42", wo, d_round, results = list(
      qc_lab("Zinc", 0.05, rl = 0.005), qc_lab("Copper", 0.11, rl = 0.001),
      qc_lab("Nickel", 0.011, rl = 0.001)))
  })
  fl_status(s, checks = qc_checks())
  sec <- md_section(read_status_note(s$report_dir), "Flags")
  expect_length(grep("^\\*\\*qc_dup_rpd\\*\\*", sec), 1)
  line <- sec[grepl("^- ", sec) & grepl("Q.JD42", sec, fixed = TRUE)]
  expect_length(line, 1)
  expect_match(line, "→ qualify[^→]*$")
  js <- fl_status_json(s)
  dup <- Filter(function(x) identical(x$check, "qc_dup_rpd"), js$flags)
  expect_length(dup, 1)
  expect_identical(dup[[1]]$action, "qualify")
})
