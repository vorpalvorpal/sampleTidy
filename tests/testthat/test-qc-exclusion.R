# PLAN-19 R-19.5: QC never leaks. `.flags_load()` marks a sample whose
# feature is in `qc_feature` as `qc = TRUE`; missing_point, missing_analytes,
# licence_limit, gas_criterion, site_history, rl_change and unit_change never
# see it; it still evidences a delivery for overdue / invoiced_not_received.
# Each test pairs the QC sample with a non-QC control that IS flagged, so a
# check that silently stopped working cannot pass.
#
# Codes and parents are invented (site Q; helper-qc.R).

wo <- "ES2600501"

test_that(".flags_load(): samples carry `qc`, TRUE exactly for samples on a qc_feature", {
  db <- qc_db()
  fl_with(db, function(con) {
    qc_add(con, "Q.JD42", "duplicate", parent = "Q.X01")
    fl_sample(con, "Q.X01", wo, "2026-09-28", results = list(qc_lab("Zinc", 0.1, rl = 0.005)))
    fl_sample(con, "Q.JD42", wo, "2026-09-28", results = list(qc_lab("Zinc", 0.1, rl = 0.005)))
  })
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  img <- sampleTidy:::.flags_load(con, fl_now())
  expect_true("qc" %in% names(img$samples))
  expect_type(img$samples$qc, "logical")
  expect_identical(img$samples$qc[img$samples$feature == "Q.JD42"], TRUE)
  expect_identical(img$samples$qc[img$samples$feature == "Q.X01"], FALSE)
})

test_that(".flags_load(): a DB with no qc_feature table marks nothing as qc", {
  db <- qc_db(tables = FALSE)
  fl_with(db, function(con) {
    fl_sample(con, "Q.X01", wo, "2026-09-28", results = list(qc_lab("Zinc", 0.1, rl = 0.005)))
  })
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  img <- sampleTidy:::.flags_load(con, fl_now())
  expect_identical(img$samples$qc, FALSE)
})

test_that("licence_limit: a QC duplicate whose value breaches the limit gives no flag", {
  db <- qc_db()
  fl_with(db, function(con) {
    qc_add(con, "Q.JD42", "duplicate", parent = "Q.X01")
    fl_sample(con, "Q.JD42", wo, "2026-09-10", results = list(`NH3-N` = 5))
    fl_sample(con, "Q.X01", wo, "2026-09-10", results = list(`NH3-N` = 2))
  })
  lim <- fl_limits(list(site = "Q", feature_pattern = "^Q\\.", analyte = "NH3-N", max = "0.9"))
  ll <- fl_of(fl_run(db, fl_checks(limits = lim)), "licence_limit")
  expect_identical(ll$feature, "Q.X01")
})

test_that("rl_change: a blank with a raised RL gives no flag", {
  db <- qc_db()
  fl_with(db, function(con) {
    qc_add(con, "Q.JF42", "field_blank", parent = "Q.X01", date_start = "2020-01-01")
    nd <- function(rl) list(list(analyte = "Pb", value = rl, quantified = FALSE, rl = rl))
    for (feat in c("Q.JF42", "Q.X01")) {
      fl_sample(con, feat, "HIST", "2026-06-01", results = nd(0.001), ingested = NULL)
      fl_sample(con, feat, "ES2600590", "2026-09-14", results = nd(0.005))
    }
  })
  rc <- fl_of(fl_run(db, fl_checks()), "rl_change")
  expect_identical(rc$feature, "Q.X01")
})

test_that("unit_change: a QC sample's unit change gives no flag", {
  db <- qc_db()
  fl_with(db, function(con) {
    qc_add(con, "Q.JF42", "field_blank", parent = "Q.X01", date_start = "2020-01-01")
    fl_analyte(con, "Zn", units = "mg/L")
    zn <- function(units) list(list(analyte = "Zn", value = 0.01, units = units))
    for (feat in c("Q.JF42", "Q.X01")) {
      fl_sample(con, feat, "HIST", "2026-06-01", results = zn("mg/L"), ingested = NULL)
      fl_sample(con, feat, "ES2600591", "2026-09-14", results = zn("µg/L"))
    }
  })
  uc <- fl_of(fl_run(db, fl_checks()), "unit_change")
  expect_identical(uc$feature, "Q.X01")
})

test_that("site_history: a QC sample far outside its code's history gives no flag", {
  db <- qc_db()
  fl_with(db, function(con) {
    qc_add(con, "Q.JD42", "duplicate", parent = "Q.X01", date_start = "2020-01-01")
    fl_analyte(con, "EC", units = "µS/cm")
    dates <- c("2022-01-15", "2022-07-15", "2023-01-15", "2023-07-15",
               "2024-01-15", "2024-07-15", "2025-01-15", "2026-06-15")
    for (feat in c("Q.JD42", "Q.X01")) {
      for (i in seq_along(dates)) {
        fl_sample(con, feat, "HIST", dates[[i]], ingested = NULL,
                  results = list(list(analyte = "EC", value = 99 + i)))
      }
      fl_sample(con, feat, "ES2600592", "2026-09-14", results = list(list(analyte = "EC", value = 300)))
    }
  })
  sh <- fl_of(fl_run(db, fl_checks()), "site_history")
  expect_identical(sh$feature, "Q.X01")
})

test_that("missing_point never sees a QC sample; overdue still counts it as a delivery", {
  db <- qc_db()
  fl_with(db, function(con) {
    qc_add(con, "Q.JD42", "duplicate", parent = "Q.X01", date_start = "2026-01-01")
    # Aug 2026: only a QC sample was delivered at Q
    fl_sample(con, "Q.JD42", "ES2600593", "2026-08-12", results = list(qc_lab("Zinc", 0.1, rl = 0.005)))
    # Sep 2026: a delivery holding only a QC sample
    fl_sample(con, "Q.JD42", wo, "2026-09-12", results = list(qc_lab("Zinc", 0.1, rl = 0.005)))
    # Sep 2026 at P (control): a real point, one of two expected
    fl_sample(con, "P.X01", "ES2600594", "2026-09-12", results = list(qc_lab("Zinc", 0.1, rl = 0.005)))
  })
  sched <- fl_schedule(list(site = "Q", stream = "als_lab", months = "8;9", due_days = 10,
                            features = "Q.X01;Q.X02"),
                       list(site = "P", stream = "als_lab", months = "9", due_days = 10,
                            features = "P.X01;P.X02"))
  f <- fl_run(db, fl_checks(schedule = sched))
  mp <- fl_of(f, "missing_point")
  expect_identical(mp$site, "P")                          # Q's QC-only round is no round
  expect_false(any(fl_of(f, "overdue")$site == "Q" & fl_of(f, "overdue")$date == "2026-08-01"))
})
