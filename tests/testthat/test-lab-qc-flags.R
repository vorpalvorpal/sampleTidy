# PLAN-19 phase 1b: the lab_qc_outlier (R-19.29) and holding_time (R-19.30)
# flag checks, and "(QC qualified)" (R-19.32), with the R-19.22 `action`
# column. lab_qc_outlier rows are inserted directly (qci_put_report(),
# helper-qci.R), so these tests do not depend on the parser.
#
# Dates: samples are 2026-09-14, i.e. recent (now = 2026-10-19), after the
# qc_requirements `from` date (2026-09-01), and past every relevant ALS holding
# time (EC 28 days, BOD 2 days, pH 6 hours), so a lab re-run is no longer
# possible -> action `qualify` whichever way the due date is worked out.
#
# Choices the plan leaves open, taken as the simplest reading:
#   [invented: analyte match] an LCS row applies to a result whose lab method
#     code (the text before ":" in lab_method.method) equals the row's `method`
#     and whose analyte name equals `analyte_raw`. Here lab_method.name and
#     analyte.name are both that string, so either name may be used.
#   [invented: reasons] the "QC qualified:" reason for a holding_time row
#     mentions "holding time"; for an LCS row it mentions "LCS".
#   The `reanalyse` action (due date not yet passed) is NOT tested: no
#     lab_qc_outlier row carries a due date for MS/LCS rows, so the plan does
#     not say where that date comes from (reported as an ambiguity).

lf_date <- "2026-09-14"
.ec <- "Electrical Conductivity @ 25°C"
.ec_method <- "EA010P: Conductivity by PC Titrator"
.bod_method <- "EP030: Biochemical Oxygen Demand (BOD)"
.ph_method <- "EA005P: pH by PC Titrator"
.nd_comment <- "MS recovery not determined, background level greater than or equal to 4x spike level."

#' WO ES2690001: EC at B.S01 and B.S03 under EA010P, pH only at B.S05, Copper
#' at B.S01 under EG020F. Returns list(db, s01, s03, s05).
lf_lcs_db <- function(env = parent.frame(), ingested = fl_now() - 10 * 86400) {
  db <- qc_db(env = env)
  out <- list(db = db)
  fl_with(db, function(con) {
    out$s01 <<- fl_sample(con, "B.S01", "ES2690001", lf_date, ingested = ingested, results = list(
      qci_lab(.ec, 900, .ec_method, units = "µS/cm"),
      qci_lab("Copper", 0.05, "EG020F: Dissolved Metals by ICP-MS"),
      qci_lab("Zinc", 0.2, "EG020F: Dissolved Metals by ICP-MS")))
    out$s03 <<- fl_sample(con, "B.S03", "ES2690001", lf_date, ingested = ingested, results = list(
      qci_lab(.ec, 800, .ec_method, units = "µS/cm")))
    out$s05 <<- fl_sample(con, "B.S05", "ES2690001", lf_date, ingested = ingested, results = list(
      qci_lab("pH", 7.1, .ph_method, units = "pH units")))
  })
  out
}

lf_lcs_row <- list(kind = "lcs", method = "EA010P", method_name = "Conductivity by PC Titrator",
                   analyte_raw = .ec, qc_lot = "QC-MRG2-3190228002", value_pct = 90.1,
                   limit_low = 95, limit_high = 113, data_raw = "90.1 %",
                   comment = "Recovery less than lower control limit")

#' WO ES2690002: BOD + lab pH at B.L01 (which also has a field pH) and B.L02,
#' BOD at B.L03; optional licence point 20 = B.L01 with BOD required there.
lf_ht_db <- function(env = parent.frame(), licence = FALSE) {
  db <- qc_db(env = env)
  out <- list(db = db)
  fl_with(db, function(con) {
    if (licence) {
      fl_analyte(con, "BOD", epa = "Biochemical oxygen demand")
      fl_feature(con, "B.L01", epa = "20")
    }
    out$l01 <<- fl_sample(con, "B.L01", "ES2690002", lf_date, results = list(
      qci_lab("BOD", 30, .bod_method, rl = 5),
      qci_lab("pH", 7.2, .ph_method, units = "pH units"),
      qci_field("pH", 7.0)))
    out$l02 <<- fl_sample(con, "B.L02", "ES2690002", lf_date, results = list(
      qci_lab("BOD", 10, .bod_method, rl = 2),
      qci_lab("pH", 7.5, .ph_method, units = "pH units")))
    out$l03 <<- fl_sample(con, "B.L03", "ES2690002", lf_date, results = list(
      qci_lab("BOD", 25, .bod_method, rl = 2)))
  })
  out
}

lf_ht_rows <- function(d) {
  ht <- function(method, method_name, client, uuid, days) {
    list(kind = "holding_time", method = method, method_name = method_name, client_id = client,
         uuid_sample = uuid, days_overdue = days, date_analysed = "2026-09-19",
         due_analysis = as.character(as.Date("2026-09-19") - days))
  }
  list(ht("EP030", "Biochemical Oxygen Demand (BOD)", "B.L01", d$l01, 3L),
       ht("EP030", "Biochemical Oxygen Demand (BOD)", "B.L02", d$l02, 3L),
       ht("EP030", "Biochemical Oxygen Demand (BOD)", "End Ridgely Road", NA_character_, 3L),
       ht("EA005P", "pH by PC Titrator", "B.L01", d$l01, 5L),
       ht("EA005P", "pH by PC Titrator", "B.L02", d$l02, 5L),
       list(kind = "frequency", method = "EP030", method_name = "Biochemical Oxygen Demand (BOD)",
            value_pct = 0, limit_low = 5))
}

# ---- wiring -------------------------------------------------------------------------

test_that("R-19.29/R-19.30: lab_qc_outlier and holding_time are registered after unit_change, before lab_qc_missing", {
  ck <- .flags_checks
  expect_true(all(c("unit_change", "lab_qc_outlier", "holding_time", "lab_qc_missing") %in% ck))
  expect_true(match("unit_change", ck) < match("lab_qc_outlier", ck))
  expect_true(match("lab_qc_outlier", ck) < match("holding_time", ck))
  expect_true(match("holding_time", ck) < match("lab_qc_missing", ck))
  expect_true(all(c("lab_qc_outlier", "holding_time") %in% names(.flags_meanings)))
  expect_true(all(c("lab_qc_outlier", "holding_time") %in% names(.flags_fns)))
})

test_that("R-19.29/R-19.30: a DB without the lab_qc tables (older than 048) gives no rows and no error", {
  db <- qc_db(tables = FALSE)
  fl_with(db, function(con) {
    fl_sample(con, "B.S01", "ES2690001", lf_date, results = list(qci_lab(.ec, 900, .ec_method)))
  })
  f <- fl_run(db, fl_checks())
  expect_false(any(c("lab_qc_outlier", "holding_time") %in% names(attr(f, "errors"))))
  expect_equal(nrow(fl_of(f, "lab_qc_outlier")) + nrow(fl_of(f, "holding_time")), 0)
})

# ---- R-19.29 lab_qc_outlier ------------------------------------------------------------

test_that("R-19.29: a batch-level LCS failure flags once and names every point with that method and analyte", {
  d <- lf_lcs_db()
  fl_with(d$db, function(con) qci_put_report(con, "ES2690001", list(lf_lcs_row)))
  f <- qci_flags(d$db, check = "lab_qc_outlier")
  expect_equal(nrow(f), 1)
  expect_identical(f$key, sprintf("lab_qc_outlier|ES2690001|lcs|EA010P|%s|QC-MRG2-3190228002", .ec))
  expect_identical(f$site, "B")
  expect_match(f$detail, "ALS QCI ES2690001", fixed = TRUE)
  expect_match(f$detail, "EA010P", fixed = TRUE)
  expect_match(f$detail, "LCS 90.1%", fixed = TRUE)
  expect_match(f$detail, "95(\\.0)?[–-]113%")
  expect_match(f$detail, "recovery less than lower control limit", ignore.case = TRUE)
  expect_match(f$detail, "affects B.S01, B.S03", fixed = TRUE)
  expect_false(grepl("B.S05", f$detail, fixed = TRUE))   # no EC result under EA010P
  expect_identical(f$action, "qualify")
})

test_that("R-19.29: MS flags only a linked row outside its limits; not-determined, Anonymous, in-limit and frequency rows never flag", {
  d <- lf_lcs_db()
  ms <- function(...) utils::modifyList(list(kind = "ms", method = "EG020F",
                                             method_name = "Dissolved Metals by ICP-MS",
                                             limit_low = 70, limit_high = 130), list(...))
  fl_with(d$db, function(con) qci_put_report(con, "ES2690001", list(
    ms(analyte_raw = "Copper", lab_id = "ES2690001-002", client_id = "B.S01", uuid_sample = d$s01,
       value_pct = 39.6, data_raw = "39.6 %", comment = "Recovery less than lower data quality objective"),
    ms(analyte_raw = "Zinc", lab_id = "ES2690001-002", client_id = "B.S01", uuid_sample = d$s01,
       value_pct = NA_real_, limit_low = NA_real_, limit_high = NA_real_,
       data_raw = "Not Determined", comment = .nd_comment),
    ms(analyte_raw = "Vanadium", lab_id = "ES2690999-010", client_id = "Anonymous",
       value_pct = 56.4, comment = "Recovery less than lower data quality objective"),
    ms(analyte_raw = "Lead", lab_id = "ES2690001-002", client_id = "B.S01", uuid_sample = d$s01,
       value_pct = 95),
    list(kind = "frequency", method = "EG020A-T", method_name = "Total Metals by ICP-MS - Suite A",
         value_pct = 0, limit_low = 5))))
  f <- qci_flags(d$db, check = "lab_qc_outlier")
  expect_equal(nrow(f), 1)
  expect_identical(f$key, "lab_qc_outlier|ES2690001|ms|EG020F|Copper|ES2690001-002")
  expect_identical(f$feature, "B.S01")
  expect_match(f$detail, "ALS QCI ES2690001", fixed = TRUE)
  expect_match(f$detail, "Copper", fixed = TRUE)
  expect_match(f$detail, "39.6%", fixed = TRUE)
  expect_identical(f$action, "qualify")
})

test_that("R-19.29: rows of a work order that is not a recent delivery are not flagged", {
  d <- lf_lcs_db(ingested = fl_now() - 200 * 86400)
  fl_with(d$db, function(con) qci_put_report(con, "ES2690001", list(lf_lcs_row)))
  expect_equal(nrow(qci_flags(d$db, check = "lab_qc_outlier")), 0)
})

# ---- R-19.30 holding_time ----------------------------------------------------------------

test_that("R-19.30: one flag per (work order, method), listing linked points, days overdue and unlinked IDs in quotes", {
  d <- lf_ht_db()
  fl_with(d$db, function(con) qci_put_report(con, "ES2690002", lf_ht_rows(d)))
  f <- qci_flags(d$db, check = "holding_time")
  expect_setequal(f$key, c("holding_time|ES2690002|EP030", "holding_time|ES2690002|EA005P"))
  bod <- f[f$key == "holding_time|ES2690002|EP030", , drop = FALSE]
  expect_identical(bod$site, "B")
  expect_match(bod$detail, "ES2690002", fixed = TRUE)
  expect_match(bod$detail, "EP030", fixed = TRUE)
  expect_match(bod$detail, "B.L01", fixed = TRUE)
  expect_match(bod$detail, "B.L02", fixed = TRUE)
  expect_match(bod$detail, "\"End Ridgely Road\"", fixed = TRUE)
  expect_match(bod$detail, "3 days?", perl = TRUE)
  expect_false(grepl("B.L03", bod$detail, fixed = TRUE))
  # No licence requirements given -> nothing licence-required -> qualify.
  expect_identical(bod$action, "qualify")
})

test_that("R-19.30: lab pH (EA005*) is suppressed at a sample that has a field pH, kept where there is none", {
  d <- lf_ht_db()
  fl_with(d$db, function(con) qci_put_report(con, "ES2690002", lf_ht_rows(d)))
  f <- qci_flags(d$db, check = "holding_time")
  ph <- f[f$key == "holding_time|ES2690002|EA005P", , drop = FALSE]
  expect_equal(nrow(ph), 1)
  expect_match(ph$detail, "B.L02", fixed = TRUE)
  expect_false(grepl("B.L01", ph$detail, fixed = TRUE))

  # With only the B.L01 row, the pH flag disappears entirely.
  d2 <- lf_ht_db()
  fl_with(d2$db, function(con) qci_put_report(con, "ES2690002", lf_ht_rows(d2)[4]))
  expect_equal(nrow(qci_flags(d2$db, check = "holding_time")), 0)
})

test_that("R-19.30: action is resample when a licence-required pollutant at a linked licence point breached its holding time", {
  d <- lf_ht_db(licence = TRUE)
  fl_with(d$db, function(con) qci_put_report(con, "ES2690002", lf_ht_rows(d)))
  checks <- fl_checks(
    requirements = fl_requirements(list(site = "B", epa_point = "20",
                                        pollutant = "Biochemical oxygen demand",
                                        licence_pollutant = "BOD", frequency = "Yearly")),
    points = fl_points(list("B", "20", "discharge")))
  f <- qci_flags(d$db, checks, check = "holding_time")
  bod <- f[f$key == "holding_time|ES2690002|EP030", , drop = FALSE]
  expect_identical(bod$action, "resample")
  expect_match(bod$detail, "resample B.L01", fixed = TRUE)
  ph <- f[f$key == "holding_time|ES2690002|EA005P", , drop = FALSE]
  expect_identical(ph$action, "qualify")   # pH is not required at point 20 here
})

# ---- R-19.32 (QC qualified) -------------------------------------------------------------

test_that("R-19.32: a licence_limit flag on a result with a linked holding-time breach carries '; QC qualified:', key unchanged", {
  d <- lf_ht_db()
  fl_with(d$db, function(con) qci_put_report(con, "ES2690002", lf_ht_rows(d)))
  checks <- fl_checks(limits = fl_limits(list(site = "B", feature_pattern = "^B\\.L0[13]$",
                                              analyte = "BOD", max = "20", unit = "mg/L",
                                              condition = "L2.4")))
  f <- qci_flags(d$db, checks, check = "licence_limit")
  expect_setequal(f$feature, c("B.L01", "B.L03"))
  l01 <- f[f$feature == "B.L01", , drop = FALSE]
  expect_identical(l01$key, sprintf("licence_limit|B.L01|BOD|%s|lab", lf_date))
  expect_match(l01$detail, "; QC qualified: ", fixed = TRUE)
  expect_match(l01$detail, "holding time", ignore.case = TRUE)
  # B.L03 has no QC finding.
  expect_false(grepl("QC qualified", f$detail[f$feature == "B.L03"], fixed = TRUE))
})

test_that("R-19.32: an LCS failure qualifies the licence_limit flag of every result it applies to", {
  d <- lf_lcs_db()
  fl_with(d$db, function(con) qci_put_report(con, "ES2690001", list(lf_lcs_row)))
  checks <- fl_checks(limits = fl_limits(list(site = "B", feature_pattern = "^B\\.S01$",
                                              analyte = .ec, max = "600", unit = "µS/cm")))
  f <- qci_flags(d$db, checks, check = "licence_limit")
  expect_equal(nrow(f), 1)
  expect_identical(f$key, sprintf("licence_limit|B.S01|%s|%s|lab", .ec, lf_date))
  expect_match(f$detail, "; QC qualified: ", fixed = TRUE)
  expect_match(f$detail, "LCS", fixed = TRUE)
})

test_that("R-19.32: an rl_change flag on a qualified result carries '; QC qualified:' too", {
  d <- lf_ht_db()
  fl_with(d$db, function(con) {
    # A prior BOD at B.L01 with RL 2 (an old delivery, not recent).
    fl_sample(con, "B.L01", "ES2680000", "2026-03-14", ingested = fl_now() - 200 * 86400,
              results = list(qci_lab("BOD", 4, .bod_method, rl = 2)))
    qci_put_report(con, "ES2690002", lf_ht_rows(d))
  })
  f <- qci_flags(d$db, check = "rl_change")
  l01 <- f[f$feature == "B.L01" & f$analyte == "BOD", , drop = FALSE]
  expect_equal(nrow(l01), 1)
  expect_identical(l01$key, sprintf("rl_change|B.L01|BOD|%s", lf_date))
  expect_match(l01$detail, "; QC qualified: ", fixed = TRUE)
})

test_that("R-19.32: a licence breach under 5x a field-blank detection carries 'QC qualified: field blank <code> <analyte> <value> <unit>'", {
  # Depends on the phase-1 qc_blank_detect machinery (R-19.25) and checks$qc.
  db <- qc_db()
  am <- "EK055G: Ammonia as N by Discrete Analyser"
  fl_with(db, function(con) {
    qc_add(con, "Q.JF01", "field_blank", parent = "Q.X01")
    fl_sample(con, "Q.X01", "ES2690003", lf_date,
              results = list(qci_lab("Ammonia as N", 0.2, am, rl = 0.01)))
    fl_sample(con, "Q.JF01", "ES2690003", lf_date,
              results = list(qci_lab("Ammonia as N", 0.05, am, rl = 0.01)))
  })
  checks <- qc_checks(limits = fl_limits(list(site = "Q", feature_pattern = "^Q\\.X01$",
                                              analyte = "Ammonia as N", max = "0.1",
                                              unit = "mg/L")))
  f <- qci_flags(db, checks, check = "licence_limit")
  expect_equal(nrow(f), 1)
  expect_identical(f$feature, "Q.X01")
  expect_identical(f$key, sprintf("licence_limit|Q.X01|Ammonia as N|%s|lab", lf_date))
  expect_match(f$detail, "QC qualified: field blank Q.JF01 Ammonia as N 0.05 mg/L", fixed = TRUE)
})
