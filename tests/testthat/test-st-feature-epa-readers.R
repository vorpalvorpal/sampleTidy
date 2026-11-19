# PLAN-23 3.6 (D17-64): every reader of a mask matches on the date.
#   R-23.31  The EPA readers in R/flags.R (missing_analytes) and R/qc.R (the
#            licence-required pollutants behind holding_time's `resample`) match a
#            sample to an `EPA` mask row only when the sample's date is in the row's
#            window: a sample before a moved EPA number's move date keeps the old
#            feature's number, and a sample after it does not.
# Fixtures: fl_db() / qc_db() (helper-flags.R, helper-qc.R), synthetic site N.
# EPA point 18 (flags) and 20 (qc) MOVE between two features on a fixed date.

# A dated EPA mask row on `feature` (created with its self alias when missing).
epa_row <- function(con, feature, epa, from = NA, to = NA) {
  u <- fl_feature(con, feature)
  DBI::dbExecute(con, "INSERT INTO feature_mask (uuid, uuid_feature, variant, name, date_start, date_end)
                       VALUES (?, ?, 'EPA', ?, CAST(? AS DATE), CAST(? AS DATE))",
                 params = list(fl_uuid(), u, as.character(epa), as.character(from), as.character(to)))
}

# ---- R/flags.R: missing_analytes ---------------------------------------------------------------

epa_ma_checks <- function() {
  fl_checks(
    requirements = fl_requirements(
      list(epa_point = "18", pollutant = "pH", frequency = "Monthly"),
      list(epa_point = "18", pollutant = "Ammonia (as N)", frequency = "Monthly")),
    points = fl_points(list("N", "18", "surface_water")))
}

epa_ma_db <- function(env = parent.frame()) {
  db <- fl_db(env = env)
  fl_with(db, function(con) {
    # EPA point 18 is N.S01's until 2026-08-31 and N.S03's from 2026-09-01.
    epa_row(con, "N.S01", "18", to = "2026-08-31")
    epa_row(con, "N.S03", "18", from = "2026-09-01")
    fl_analyte(con, "pH", units = "pH", epa = "pH")
    fl_analyte(con, "NH3-N", epa = "Ammonia (as N)")
    # every sample has pH and no ammonia
    fl_sample(con, "N.S01", "ES2600501", "2026-08-14", results = list(pH = 7))   # before the move
    fl_sample(con, "N.S01", "ES2600502", "2026-09-14", results = list(pH = 7))   # after it
    fl_sample(con, "N.S03", "ES2600502", "2026-09-14", results = list(pH = 7.1)) # after it
  })
  db
}

test_that("R-23.31: missing_analytes - after the move, the point's requirement falls on the NEW holder only", {
  db <- epa_ma_db()
  ma <- fl_of(fl_run(db, epa_ma_checks()), "missing_analytes")
  sep <- ma[substr(ma$date, 1, 7) == "2026-09", , drop = FALSE]
  expect_equal(nrow(sep), 1L)
  expect_match(sep$detail, "Ammonia (as N): N.S03", fixed = TRUE)
  expect_false(grepl("N.S01", sep$detail, fixed = TRUE), info = sep$detail)
})

test_that("R-23.31: missing_analytes - a sample before the move keeps the old feature's number", {
  db <- epa_ma_db()
  ma <- fl_of(fl_run(db, epa_ma_checks()), "missing_analytes")
  aug <- ma[substr(ma$date, 1, 7) == "2026-08", , drop = FALSE]
  expect_equal(nrow(aug), 1L)
  expect_match(aug$detail, "Ammonia (as N): N.S01", fixed = TRUE)
  expect_false(grepl("N.S03", aug$detail, fixed = TRUE), info = aug$detail)
})

test_that("R-23.31: missing_analytes - an undated EPA row still applies on every date (open ends)", {
  db <- fl_db()
  fl_with(db, function(con) {
    epa_row(con, "N.S01", "18")
    fl_analyte(con, "pH", units = "pH", epa = "pH")
    fl_analyte(con, "NH3-N", epa = "Ammonia (as N)")
    fl_sample(con, "N.S01", "ES2600503", "2026-09-14", results = list(pH = 7))
  })
  ma <- fl_of(fl_run(db, epa_ma_checks()), "missing_analytes")
  expect_equal(nrow(ma), 1L)
  expect_match(ma$detail, "Ammonia (as N): N.S01", fixed = TRUE)
})

# ---- R/qc.R: the licence-required pollutants behind holding_time ------------------------------

.epa_bod_method <- "EP030: Biochemical Oxygen Demand (BOD)"

# WO ES2690101: BOD at N.L01 on 2026-09-14, analysed 3 days past its holding
# time. BOD is the EPA pollutant 'Biochemical oxygen demand'; point 20 requires
# it. `l01_from`/`l01_to` date N.L01's hold on point 20; N.L09 holds it on the
# other side of the move.
epa_ht_db <- function(l01_from = NA, l01_to = NA, l09_from = NA, l09_to = NA, env = parent.frame()) {
  db <- qc_db(env = env)
  fl_with(db, function(con) {
    fl_analyte(con, "BOD", epa = "Biochemical oxygen demand")
    epa_row(con, "N.L01", "20", from = l01_from, to = l01_to)
    epa_row(con, "N.L09", "20", from = l09_from, to = l09_to)
    s <- fl_sample(con, "N.L01", "ES2690101", "2026-09-14", results = list(
      qci_lab("BOD", 30, .epa_bod_method, rl = 5)))
    qci_put_report(con, "ES2690101", list(
      list(kind = "holding_time", method = "EP030", method_name = "Biochemical Oxygen Demand (BOD)",
           client_id = "N.L01", uuid_sample = s, days_overdue = 3L, date_analysed = "2026-09-19",
           due_analysis = "2026-09-16")))
  })
  db
}

epa_ht_checks <- function() {
  fl_checks(
    requirements = fl_requirements(list(site = "N", epa_point = "20", pollutant = "Biochemical oxygen demand",
                                        licence_pollutant = "BOD", frequency = "Yearly")),
    points = fl_points(list("N", "20", "discharge")))
}

test_that("R-23.31: holding_time - a sample BEFORE point 20 moved to N.L01 is not at a licence point: qualify, not resample", {
  # point 20 was N.L09's until 2026-09-30 and is N.L01's from 2026-10-01; the sample is 2026-09-14
  db <- epa_ht_db(l01_from = "2026-10-01", l09_to = "2026-09-30")
  f <- qci_flags(db, epa_ht_checks(), check = "holding_time")
  bod <- f[f$key == "holding_time|ES2690101|EP030", , drop = FALSE]
  expect_equal(nrow(bod), 1L)
  expect_identical(bod$action, "qualify")
  expect_false(grepl("resample", bod$detail, fixed = TRUE), info = bod$detail)
})

test_that("R-23.31: holding_time - a sample before point 20 moved AWAY from N.L01 keeps the old number: resample N.L01", {
  # point 20 was N.L01's until 2026-09-30 and is N.L09's from 2026-10-01; the sample is 2026-09-14
  db <- epa_ht_db(l01_to = "2026-09-30", l09_from = "2026-10-01")
  f <- qci_flags(db, epa_ht_checks(), check = "holding_time")
  bod <- f[f$key == "holding_time|ES2690101|EP030", , drop = FALSE]
  expect_equal(nrow(bod), 1L)
  expect_identical(bod$action, "resample")
  expect_match(bod$detail, "resample N.L01", fixed = TRUE)
})
