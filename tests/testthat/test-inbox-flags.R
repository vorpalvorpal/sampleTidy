# Phase 2 of auto-import: import_flags() and the Flags section of the standing
# status note (dev/plans/PLAN-18-auto-import.md section 4, contract in 4.5).
# Every test builds a small synthetic DB with helper-flags.R; nothing touches
# the live DB, dev/ or the vault. "now" is fixed at 2026-10-19 13:00 Sydney
# (fl_now()), so "today" is 2026-10-19 and the overdue window is Oct 2025 -
# Sep 2026.

months_seq <- function(from, n) {
  format(seq(as.Date(paste0(from, "-01")), by = "month", length.out = n), "%Y-%m")
}

# ---- shape -----------------------------------------------------------------

test_that("import_flags(): pinned columns and types; NULL inputs on an empty DB give no rows, no errors", {
  db <- fl_db()
  f <- fl_run(db, fl_checks())
  expect_s3_class(f, "data.frame")
  expect_identical(names(f), fl_flag_cols)
  expect_equal(nrow(f), 0)
  expect_type(f$value, "double")
  for (cl in setdiff(fl_flag_cols, "value")) expect_type(f[[cl]], "character")
  errs <- attr(f, "errors")
  expect_true(is.character(errs))
  expect_length(errs, 0)
})

test_that("import_flags(): read-only - the DB file is byte-identical afterwards", {
  db <- fl_db()
  fl_with(db, function(con) {
    fl_sample(con, "B.E01", "ES2600001", "2026-09-11", results = list(`NH3-N` = 2))
  })
  before <- file_md5(db)
  f <- fl_run(db, fl_checks(schedule = fl_schedule(list(months = "8")),
                            limits = fl_limits(list(max = "0.9"))))
  expect_gt(nrow(f), 0)
  expect_identical(file_md5(db), before)
})

# ---- 4.1 overdue -------------------------------------------------------------

test_that("overdue: a month with no delivery is flagged once its due date has passed; not before; not beyond 12 months", {
  db <- fl_db()
  fl_with(db, function(con) {
    # ACIRL water at Blaxland every month Oct 2025 - Jul 2026; none Aug, Sep.
    for (m in months_seq("2025-10", 10)) {
      fl_sample(con, "B.S01", "ES2600001", paste0(m, "-15"), org = "ACIRL",
                results = list(pH = 7))
    }
  })
  f <- fl_run(db, fl_checks(schedule = fl_schedule(list(site = "B", stream = "acirl_water",
                                                        months = "all", due_days = 30))))
  od <- fl_of(f, "overdue")
  # Aug 2026: due 2026-09-30, passed. Sep 2026: due 2026-10-30, not yet.
  # Sep 2025 (13 months back) is outside the window although it had no sample.
  expect_identical(od$date, "2026-08-01")
  expect_identical(od$site, "B")
  expect_match(od$detail, "acirl_water", fixed = TRUE)
  expect_match(od$threshold, "Aug 2026", fixed = TRUE)
  expect_match(od$threshold, "2026-09-30", fixed = TRUE)
  expect_true(is.na(od$value))
})

test_that("overdue: a due date of today is not yet overdue; yesterday is", {
  db <- fl_db()
  # end of Aug + 49 days = 2026-10-19 (today); + 48 = 2026-10-18.
  f <- fl_run(db, fl_checks(schedule = fl_schedule(
    list(site = "B", months = "8", due_days = 49),
    list(site = "K", months = "8", due_days = 48))))
  od <- fl_of(f, "overdue")
  expect_identical(od$site, "K")
  expect_identical(od$date, "2026-08-01")
})

test_that("overdue: months parse as 'all' or a ;-list with whitespace; another stream's samples do not count", {
  db <- fl_db()
  fl_with(db, function(con) {
    # ALS lab samples every month: they are als_lab, not acirl_water.
    for (m in months_seq("2025-10", 12)) {
      fl_sample(con, "B.S01", "ES2600002", paste0(m, "-10"), org = "ALS",
                results = list(pH = 7))
    }
  })
  f <- fl_run(db, fl_checks(schedule = fl_schedule(
    list(site = "B", stream = "acirl_water", months = " 1; 4 ;7;10"))))
  expect_identical(fl_of(f, "overdue")$date,
                   c("2026-07-01", "2026-04-01", "2026-01-01", "2025-10-01"))

  f2 <- fl_run(db, fl_checks(schedule = fl_schedule(
    list(site = "B", stream = "acirl_water", months = "all"))))
  # Oct 2025 .. Aug 2026 (Sep 2026 not yet due), newest first.
  expect_identical(fl_of(f2, "overdue")$date,
                   rev(paste0(months_seq("2025-10", 11), "-01")))
})

test_that("overdue: a schedule row counts only in months it overlaps (from/to); empty `to` is open-ended", {
  db <- fl_db()
  f <- fl_run(db, fl_checks(schedule = fl_schedule(
    list(site = "B", months = "all", from = "2026-03-15", to = "2026-06-10"),
    list(site = "K", months = "all", from = "2026-08-01", to = ""))))
  od <- fl_of(f, "overdue")
  expect_identical(od$date[od$site == "B"],
                   c("2026-06-01", "2026-05-01", "2026-04-01", "2026-03-01"))
  expect_identical(od$date[od$site == "K"], "2026-08-01")
})

test_that("overdue: a malformed schedule (unknown stream, month 13) is an error of the schedule checks, not a crash", {
  db <- fl_db()
  for (bad in list(list(stream = "acirl_water_monthly"), list(months = "13"))) {
    f <- fl_run(db, fl_checks(schedule = fl_schedule(bad)))
    expect_identical(names(f), fl_flag_cols)
    expect_equal(nrow(fl_of(f, "overdue")), 0)
    expect_true("overdue" %in% names(attr(f, "errors")))
  }
})

test_that("stream of a sample: gas by project type, dust by gauge name, ALS/ACIRL by organisation, Sydney day", {
  db <- fl_db()
  fl_with(db, function(con) {
    # gas reading at a WELL (not an air feature), date-only, under a gas project
    fl_sample(con, "B.MW01", "2400-7538-08-01", "2026-08-10", org = "ACIRL",
              type = "Monthly gas monitoring", ts_col = "date",
              results = list(CH4 = 0.001))
    # dust gauge: an air feature inside an ALS work order, ACIRL organisation
    fl_sample(con, "B.D01", "ES2600003", "2026-08-01", org = "ACIRL", matrix = "air",
              results = list(`dust-total` = 1))
    # ALS: 2026-07-31 15:00 UTC is 2026-08-01 01:00 in Sydney -> August
    fl_sample(con, "B.S01", "ES2600003", "2026-07-31 15:00:00", org = "ALS",
              results = list(pH = 7))
    # ACIRL water at Blaxland only on 2026-07-31 23:00 Sydney (13:00 UTC) -> July
    fl_sample(con, "B.S02", "ES2600003", "2026-07-31 13:00:00", org = "ACIRL",
              results = list(pH = 7))
    # ...in August only at Katoomba, and from an 'Internal' sampler at Blaxland
    fl_sample(con, "K.S01", "ES2600004", "2026-08-12", org = "ACIRL", results = list(pH = 7))
    fl_sample(con, "B.S03", "ES2600003", "2026-08-12", org = "Internal", results = list(pH = 7))
  })
  sched <- fl_schedule(list(stream = "acirl_water", months = "8"),
                       list(stream = "acirl_gas", months = "8"),
                       list(stream = "acirl_dust", months = "8"),
                       list(stream = "als_lab", months = "8"))
  od <- fl_of(fl_run(db, fl_checks(schedule = sched)), "overdue")
  expect_equal(nrow(od), 1)
  expect_identical(od$site, "B")
  expect_match(od$detail, "acirl_water", fixed = TRUE)
})

test_that("stream of a sample: with no sample organisation, the analyses' lab_method organisation decides", {
  db <- fl_db()
  fl_with(db, function(con) {
    fl_sample(con, "B.S01", "ES2600005", "2026-08-12", org = NA_character_,
              results = list(list(analyte = "pH", value = 7, lab_org = "ACIRL")))
  })
  od <- fl_of(fl_run(db, fl_checks(schedule = fl_schedule(list(months = "8")))), "overdue")
  expect_equal(nrow(od), 0)
})

# ---- 4.1 invoiced, not received ---------------------------------------------------

test_that("invoiced_not_received: due_days from the schedule (default 30); a sample within +-3 days clears it", {
  db <- fl_db()
  fl_with(db, function(con) {
    fl_sample(con, "B.S01", "ES2600010", "2026-08-23", org = "ACIRL", results = list(pH = 7))
    fl_sample(con, "B.S02", "ES2600010", "2026-08-22", org = "ALS", results = list(pH = 7))
  })
  inv <- data.frame(
    site = c("B", "B", "B", "K", "K"),
    stream = c("acirl_water", "als_lab", "acirl_water", "acirl_gas", "acirl_gas"),
    sampled_on = as.Date(c("2026-08-19", "2026-08-19", "2026-09-25", "2026-09-10", "2026-09-20")),
    ref = c("AC101418", "INV-2", "AC101500", "AC101600", "AC101700"),
    stringsAsFactors = FALSE)
  sched <- fl_schedule(list(site = "B", stream = "acirl_water", months = "8;9", due_days = 30))
  inr <- fl_of(fl_run(db, fl_checks(schedule = sched, invoices = inv)), "invoiced_not_received")
  # B acirl_water 08-19: the nearest ACIRL sample is 4 days later -> flagged.
  # B als_lab 08-19: ALS sample 3 days later -> cleared.
  # B acirl_water 09-25: due 10-25 -> not yet.
  # K acirl_gas 09-10: no schedule row, default 30 -> due 10-10 -> flagged.
  # K acirl_gas 09-20: due 10-20 -> not yet.
  expect_identical(inr$date, c("2026-09-10", "2026-08-19"))
  expect_identical(inr$site, c("K", "B"))
  expect_match(inr$detail[[2]], "AC101418", fixed = TRUE)
  expect_match(inr$detail[[1]], "AC101600", fixed = TRUE)
})

test_that("invoiced_not_received: invoices = NULL gives no such flags", {
  db <- fl_db()
  f <- fl_run(db, fl_checks(schedule = fl_schedule(list(months = "8"))))
  expect_equal(nrow(fl_of(f, "invoiced_not_received")), 0)
})

# ---- 4.2 incomplete deliveries ------------------------------------------------------

test_that("missing_point: ONE flag per (site, month, stream) counting the unsampled expected points (R3); old/legacy deliveries ignored", {
  db <- fl_db()
  fl_with(db, function(con) {
    # recent (ingested 10 days ago): B.S01 and B.E01 in Sep 2026
    fl_sample(con, "B.S01", "ES2600020", "2026-09-14", results = list(pH = 7))
    fl_sample(con, "B.E01", "ES2600020", "2026-09-14", results = list(pH = 7))
    # ingested 100 days ago: only B.S01
    fl_sample(con, "B.S01", "ES2600021", "2026-06-10", results = list(pH = 7),
              ingested = fl_now() - 100 * 86400)
    # legacy, no change_log: only B.S01
    fl_sample(con, "B.S01", "ES2600022", "2026-07-10", results = list(pH = 7),
              ingested = NULL)
    # Katoomba round in September, but its schedule row is quarterly Jan/Apr/Jul/Oct
    fl_sample(con, "K.S01", "ES2600023", "2026-09-15", results = list(pH = 7))
  })
  sched <- fl_schedule(
    list(site = "B", stream = "als_lab", features = "B.S01;B.S02; B.E01"),
    list(site = "B", stream = "acirl_gas", features = "B.G01"),
    list(site = "K", stream = "als_lab", months = "1;4;7;10", features = "K.S01;K.S02"))
  mp <- fl_of(fl_run(db, fl_checks(schedule = sched)), "missing_point")
  expect_equal(nrow(mp), 1)
  expect_true(is.na(mp$feature))
  expect_identical(mp$site, "B")
  expect_identical(mp$date, "2026-09-14")
  expect_match(mp$detail, "1 of 3 expected points not sampled: B.S02", fixed = TRUE)
  expect_match(mp$detail, "als_lab", fixed = TRUE)
})

test_that("missing_point: a feature sampled that month in another work order, or only in the field, is not missing", {
  db <- fl_db()
  fl_with(db, function(con) {
    fl_sample(con, "B.S01", "ES2600030", "2026-09-14", results = list(pH = 7))
    fl_sample(con, "B.S02", "ES2600031", "2026-09-20", results = list(pH = 7), ingested = NULL)
    fl_sample(con, "B.E01", "ES2600030", "2026-09-14", org = "ACIRL", results = list(pH = 7))
  })
  sched <- fl_schedule(list(site = "B", stream = "als_lab", features = "B.S01;B.S02;B.E01"))
  expect_equal(nrow(fl_of(fl_run(db, fl_checks(schedule = sched)), "missing_point")), 0)
})

test_that("missing_point: first 10 names then '+m more'; one flag per stream with distinct keys (R3)", {
  db <- fl_db()
  fl_with(db, function(con) {
    fl_sample(con, "B.S00", "ES2600032", "2026-09-14", results = list(pH = 7))
    fl_sample(con, "B.E01", "ES2600032", "2026-09-14", org = "ACIRL",
              results = list(list(analyte = "pH", value = 7, lab_org = "ACIRL")))
  })
  many <- sprintf("B.S%02d", 0:12)   # B.S00 sampled; B.S01..B.S12 not
  sched <- fl_schedule(list(site = "B", stream = "als_lab", features = paste(many, collapse = ";")),
                       list(site = "B", stream = "acirl_water", features = "B.E01;B.E02"))
  mp <- fl_of(fl_run(db, fl_checks(schedule = sched)), "missing_point")
  expect_equal(nrow(mp), 2)
  expect_false(anyDuplicated(mp$key) > 0)
  als <- mp$detail[grepl("als_lab", mp$detail, fixed = TRUE)]
  expect_length(als, 1)
  expect_match(als, paste0("12 of 13 expected points not sampled: ",
                           paste(sprintf("B.S%02d", 1:10), collapse = ", "), ", +2 more"),
               fixed = TRUE)
  acw <- mp$detail[grepl("acirl_water", mp$detail, fixed = TRUE)]
  expect_match(acw, "1 of 2 expected points not sampled: B.E02", fixed = TRUE)
})

test_that("missing_point: gas rounds count a point sampled in the month either side (R3); other streams do not", {
  db <- fl_db()
  fl_with(db, function(con) {
    gas <- function(feature, at, project, ingested = NULL) {
      fl_sample(con, feature, project, at, org = "ACIRL", matrix = "air",
                type = "Monthly gas monitoring", ts_col = "date", ingested = ingested,
                results = list(CH4 = 0.0001))
    }
    gas("B.G01", "2026-09-28", "2400-7538-09-01", ingested = fl_now() - 10 * 86400)
    gas("B.G02", "2026-08-30", "2400-7538-08-01")   # previous month
    gas("B.G03", "2026-10-02", "2400-7538-10-01")   # next month
    gas("B.G04", "2026-07-15", "2400-7538-07-01")   # two months off
    fl_sample(con, "B.S01", "ES2600033", "2026-09-14", results = list(pH = 7))
    fl_sample(con, "B.S02", "ES2500033", "2026-08-30", results = list(pH = 7), ingested = NULL)
  })
  sched <- fl_schedule(list(site = "B", stream = "acirl_gas", features = "B.G01;B.G02;B.G03;B.G04"),
                       list(site = "B", stream = "als_lab", features = "B.S01;B.S02"))
  mp <- fl_of(fl_run(db, fl_checks(schedule = sched)), "missing_point")
  expect_equal(nrow(mp), 2)
  expect_match(mp$detail[grepl("acirl_gas", mp$detail, fixed = TRUE)],
               "1 of 4 expected points not sampled: B.G04", fixed = TRUE)
  expect_match(mp$detail[grepl("als_lab", mp$detail, fixed = TRUE)],
               "1 of 2 expected points not sampled: B.S02", fixed = TRUE)
})

# Licence points and pollutant masks shared by the missing_analytes tests.
ma_inputs <- function() {
  list(
    requirements = fl_requirements(
      list(epa_point = "18", pollutant = "pH", frequency = "Monthly"),
      list(epa_point = "18", pollutant = "Ammonia (as N)", frequency = "Monthly"),
      list(epa_point = "18", pollutant = "Total suspended solids", frequency = "Quarterly", required = "4"),
      list(epa_point = "18", pollutant = "Lead", frequency = "Yearly", required = "1"),
      list(epa_point = "18", pollutant = "Conductivity", frequency = "Special Frequency 1", required = ""),
      list(epa_point = "20", pollutant = "pH", frequency = "Monthly"),
      list(epa_point = "20", pollutant = "Ammonia (as N)", frequency = "Monthly"),
      list(epa_point = "27", pollutant = "pH", frequency = "Monthly")),
    points = fl_points(list("B", "18", "surface_water"), list("B", "20", "surface_water"),
                       list("B", "27", "weather")))
}

ma_seed <- function(con) {
  fl_feature(con, "B.S01", epa = "18")
  fl_feature(con, "B.S02", epa = "20")
  fl_feature(con, "B.WS01", epa = "27")
  fl_analyte(con, "pH", units = "pH", epa = "pH")
  fl_analyte(con, "NH3-N", epa = "Ammonia (as N)")
  fl_analyte(con, "TSS", epa = "Total suspended solids")
  fl_analyte(con, "Pb", epa = "Lead")
  fl_analyte(con, "EC", units = "µS/cm", epa = "Conductivity")
}

ma_run <- function(db, inp = ma_inputs()) {
  fl_of(fl_run(db, fl_checks(requirements = inp$requirements, points = inp$points)),
        "missing_analytes")
}

test_that("missing_analytes: ONE flag per (site, month) listing each missing pollutant with its features (R4); field-only marked", {
  db <- fl_db()
  fl_with(db, function(con) {
    ma_seed(con)
    # B.S01: field + lab, pH present, ammonia absent
    fl_sample(con, "B.S01", "ES2600040", "2026-09-14", org = "ALS", results = list(pH = 7))
    fl_sample(con, "B.S01", "ES2600040", "2026-09-14", org = "ACIRL", results = list(pH = 7.1))
    # TSS 105 days before (quarterly window 120), Pb 378 days before (yearly 395)
    fl_sample(con, "B.S01", "ES2600041", "2026-06-01", results = list(TSS = 10), ingested = NULL)
    fl_sample(con, "B.S01", "ES2500041", "2025-09-01", results = list(Pb = 0.001), ingested = NULL)
    # B.S02: field only, no ammonia
    fl_sample(con, "B.S02", "ES2600040", "2026-09-14", org = "ACIRL", results = list(pH = 7.2))
    # weather point: never required
    fl_sample(con, "B.WS01", "ES2600040", "2026-09-14", org = "ACIRL", results = list(EC = 1))
  })
  ma <- ma_run(db)
  expect_equal(nrow(ma), 1)
  expect_identical(ma$site, "B")
  expect_true(is.na(ma$feature))
  expect_identical(substr(ma$date, 1, 7), "2026-09")
  expect_match(ma$detail, "Ammonia (as N): B.S01, B.S02 (field only)", fixed = TRUE)
  for (p in c("Lead", "Total suspended solids", "Conductivity", "B.WS01")) {
    expect_false(grepl(p, ma$detail, fixed = TRUE), info = p)
  }
})

test_that("missing_analytes: quarterly/yearly outside their windows are missing; lab-only marked; the key is per (site, month)", {
  db <- fl_db()
  fl_with(db, function(con) {
    ma_seed(con)
    fl_sample(con, "B.S01", "ES2600042", "2026-09-14", org = "ALS",
              results = list(pH = 7, `NH3-N` = 0.1))
    fl_sample(con, "B.S01", "ES2600042", "2026-09-14", org = "ACIRL", results = list(pH = 7))
    # TSS 136 days before (> 120); Pb 409 days before (> 395)
    fl_sample(con, "B.S01", "ES2600043", "2026-05-01", results = list(TSS = 10), ingested = NULL)
    fl_sample(con, "B.S01", "ES2500043", "2025-08-01", results = list(Pb = 0.001), ingested = NULL)
    # B.S02: lab only, ammonia absent
    fl_sample(con, "B.S02", "ES2600042", "2026-09-14", org = "ALS", results = list(pH = 7))
  })
  ma1 <- ma_run(db)
  expect_equal(nrow(ma1), 1)
  expect_match(ma1$detail, "Lead: B.S01", fixed = TRUE)
  expect_match(ma1$detail, "Total suspended solids: B.S01", fixed = TRUE)
  expect_match(ma1$detail, "Ammonia (as N): B.S02 (lab only)", fixed = TRUE)
  # the missing list changes; the flag (and its key) is the same
  fl_with(db, function(con) {
    fl_sample(con, "B.S01", "ES2600044", "2026-09-20", results = list(TSS = 5))
  })
  ma2 <- ma_run(db)
  expect_identical(ma2$key, ma1$key)
  expect_false(grepl("Total suspended solids", ma2$detail, fixed = TRUE))
})

test_that("missing_analytes: at most 15 pollutants in the detail, then '+m more' (R4)", {
  db <- fl_db()
  pols <- sprintf("Pollutant %02d", 1:17)
  fl_with(db, function(con) {
    fl_feature(con, "B.S01", epa = "18")
    for (i in seq_along(pols)) fl_analyte(con, sprintf("A%02d", i), epa = pols[[i]])
    fl_analyte(con, "pH", units = "pH")
    fl_sample(con, "B.S01", "ES2600045", "2026-09-14", results = list(pH = 7))
  })
  req <- do.call(fl_requirements, lapply(pols, function(p) list(epa_point = "18", pollutant = p)))
  ma <- ma_run(db, list(requirements = req, points = fl_points(list("B", "18", "surface_water"))))
  expect_equal(nrow(ma), 1)
  shown <- vapply(pols, function(p) grepl(paste0(p, ": B.S01"), ma$detail, fixed = TRUE), logical(1))
  expect_equal(sum(shown), 15)
  expect_match(ma$detail, "+2 more", fixed = TRUE)
})

test_that("missing_analytes: group line items map by their expanded `pollutant`, as dev/epa-monitoring-report.R does (R4)", {
  db <- fl_db()
  fl_with(db, function(con) {
    fl_feature(con, "B.MW01", epa = "12")
    fl_analyte(con, "Aldrin", epa = "Aldrin")
    fl_analyte(con, "Dieldrin", epa = "Dieldrin")
    fl_sample(con, "B.MW01", "ES2600046", "2026-09-14", results = list(Aldrin = 0.0001))
  })
  ocp <- function(p) list(epa_point = "12", pollutant = p,
                          licence_pollutant = "Organochlorine pesticides",
                          frequency = "Yearly", required = "1", group_item = "OCP")
  req <- fl_requirements(ocp("Aldrin"), ocp("Dieldrin"),
                         # the same (point, pollutant) under a second condition
                         c(ocp("Dieldrin"), list(condition = "M2.2")))
  ma <- ma_run(db, list(requirements = req, points = fl_points(list("B", "12", "groundwater"))))
  expect_equal(nrow(ma), 1)
  expect_match(ma$detail, "Dieldrin: B.MW01", fixed = TRUE)
  expect_false(grepl("Aldrin", ma$detail, fixed = TRUE))
  expect_false(grepl("Organochlorine", ma$detail, fixed = TRUE))
  expect_equal(lengths(regmatches(ma$detail, gregexpr("Dieldrin", ma$detail, fixed = TRUE))), 1)
})

# ---- R1: what counts as a recent delivery ----------------------------------------------

test_that("recent delivery (R1): a pipeline import in the last 90 days of samples dated in the last 180 days; migrations, backfills and unsourced rows are not", {
  db <- fl_db()
  fl_with(db, function(con) {
    nh3 <- list(`NH3-N` = 5)
    # pipeline import, sample 2026-09-01 -> recent
    fl_sample(con, "B.E01", "ES2600200", "2026-09-01", results = nh3)
    # pipeline import logged on the ANALYSIS rows only -> recent
    fl_sample(con, "B.E01", "ES2600201", "2026-09-02", results = nh3, log = "analysis")
    # sample 2026-05-01 (171 days back) -> recent
    fl_sample(con, "B.E01", "ES2600202", "2026-05-01", results = nh3)
    # backfill: imported 10 days ago by the pipeline, but sampled in 2024 / 2026-04-01
    fl_sample(con, "B.E01", "ES2400203", "2024-03-01", results = nh3)
    fl_sample(con, "B.E01", "ES2600204", "2026-04-01", results = nh3)
    # migrations, 10 days ago, with and without a source hash
    fl_sample(con, "B.E01", "ES2600205", "2026-09-05", results = nh3, actor = "012-detection-limits")
    fl_sample(con, "B.E01", "ES2600206", "2026-09-06", results = nh3, actor = "migration-040",
              source_hash = NA_character_)
    # no source_hash: not a pipeline import
    fl_sample(con, "B.E01", "ES2600207", "2026-09-07", results = nh3, source_hash = NA_character_)
  })
  ll <- fl_of(fl_run(db, fl_checks(limits = fl_limits(list(max = "0.9")))), "licence_limit")
  expect_identical(ll$date, c("2026-09-02", "2026-09-01", "2026-05-01"))
})

test_that("stream per result (R2): an ACIRL-sampled sample with ALS lab results is als_lab, not acirl_water; mixed results count for both", {
  db <- fl_db()
  fl_with(db, function(con) {
    # B: sample.organisation ACIRL, results analysed by ALS -> als_lab only
    fl_sample(con, "B.S01", "ES2604522", "2026-08-12", org = "ACIRL",
              results = list(list(analyte = "NH3-N", value = 0.1, lab_org = "ALS")))
    # K: one sample carrying an ALS lab result AND an ACIRL field reading -> both
    fl_sample(con, "K.S01", "ES2604523", "2026-08-12", org = "ALS",
              results = list(list(analyte = "NH3-N", value = 0.1, lab_org = "ALS"),
                             list(analyte = "pH", value = 7, lab_org = "ACIRL")))
  })
  sched <- fl_schedule(list(site = "B", stream = "acirl_water", months = "8"),
                       list(site = "B", stream = "als_lab", months = "8"),
                       list(site = "K", stream = "acirl_water", months = "8"),
                       list(site = "K", stream = "als_lab", months = "8"))
  od <- fl_of(fl_run(db, fl_checks(schedule = sched)), "overdue")
  expect_equal(nrow(od), 1)
  expect_identical(od$site, "B")
  expect_match(od$detail, "acirl_water", fixed = TRUE)
})

test_that("field-pH-wins (R2) classifies per result from the lab method, not sample.organisation", {
  db <- fl_db()
  fl_with(db, function(con) {
    wo <- "ES2600061"
    # 09-01: one ALS sample with an ACIRL-method (field) pH and an ALS lab pH
    fl_sample(con, "B.E01", wo, "2026-09-01", org = "ALS", results = list(
      list(analyte = "pH", value = 7.4, lab_org = "ACIRL"),
      list(analyte = "pH", value = 6.4, lab_org = "ALS", method_name = "pH Value")))
    # 09-02: an ACIRL-organisation sample whose pH is an ALS LAB method (6.3),
    # and an ALS sample carrying the ACIRL field pH (7.0): the field one wins
    fl_sample(con, "B.E01", wo, "2026-09-02", org = "ACIRL", results = list(
      list(analyte = "pH", value = 6.3, lab_org = "ALS", method_name = "pH Value")))
    fl_sample(con, "B.E01", wo, "2026-09-02", org = "ALS", results = list(
      list(analyte = "pH", value = 7.0, lab_org = "ACIRL")))
    # 09-03: only a lab pH (in an ACIRL-organisation sample) -> assessed
    fl_sample(con, "B.E01", wo, "2026-09-03", org = "ACIRL", results = list(
      list(analyte = "pH", value = 6.2, lab_org = "ALS", method_name = "pH Value")))
  })
  lim <- fl_limits(list(analyte = "pH", min = "6.5", max = "8.5", unit = "pH"))
  ll <- fl_of(fl_run(db, fl_checks(limits = lim)), "licence_limit")
  expect_identical(ll$date, "2026-09-03")
  expect_equal(ll$value, 6.2)
})

# ---- 4.3 licence limits ---------------------------------------------------------------

test_that("licence_limit: value x factor beyond max is flagged; exactly at the limit, non-detects, other features/sites and old deliveries are not", {
  db <- fl_db()
  fl_with(db, function(con) {
    fl_analyte(con, "CH4", units = "L/L")
    fl_sample(con, "B.E01", "ES2600050", "2026-09-10", results = list(`NH3-N` = 0.9))
    fl_sample(con, "B.E01", "ES2600050", "2026-09-11", results = list(`NH3-N` = 0.91))
    fl_sample(con, "B.E01", "ES2600050", "2026-09-12",
              results = list(list(analyte = "NH3-N", value = 1.0, quantified = FALSE, rl = 1.0)))
    fl_sample(con, "B.S01", "ES2600050", "2026-09-10", results = list(`NH3-N` = 5))
    fl_sample(con, "K.E01", "ES2600051", "2026-09-10", results = list(`NH3-N` = 5))
    fl_sample(con, "B.E01", "ES2600052", "2026-06-10", results = list(`NH3-N` = 5),
              ingested = fl_now() - 100 * 86400)
    fl_sample(con, "B.G01", "2400-7538-09-01", "2026-09-28", org = "ACIRL", matrix = "air",
              type = "Monthly gas monitoring", ts_col = "date", results = list(CH4 = 0.0126))
    fl_sample(con, "B.G02", "2400-7538-09-01", "2026-09-28", org = "ACIRL", matrix = "air",
              type = "Monthly gas monitoring", ts_col = "date", results = list(CH4 = 0.0125))
  })
  lim <- fl_limits(
    list(site = "B", feature_pattern = "^B\\.E01$", analyte = "NH3-N", max = "0.9",
         unit = "mg/L", factor = "1", condition = "L2.4"),
    list(site = "B", feature_pattern = "^B\\.G", analyte = "CH4", max = "1.25",
         unit = "%v/v", factor = "100", condition = "R2.3"))
  ll <- fl_of(fl_run(db, fl_checks(limits = lim)), "licence_limit")
  expect_identical(ll$feature, c("B.G01", "B.E01"))      # newest first
  expect_identical(ll$date, c("2026-09-28", "2026-09-11"))
  expect_equal(ll$value, c(1.26, 0.91), tolerance = 1e-9)
  expect_identical(ll$unit, c("%v/v", "mg/L"))
  expect_match(ll$threshold[[2]], "> 0.9 mg/L", fixed = TRUE)
  expect_match(ll$detail[[2]], "L2.5", fixed = TRUE)
  expect_identical(ll$analyte, c("CH4", "NH3-N"))
})

test_that("licence_limit: where field and lab pH exist for one feature and day the field pH is assessed, not the lab", {
  db <- fl_db()
  fl_with(db, function(con) {
    fl_analyte(con, "pH", units = "pH")
    wo <- "ES2600060"
    fl_sample(con, "B.E01", wo, "2026-09-01", org = "ACIRL", results = list(pH = 7.4))
    fl_sample(con, "B.E01", wo, "2026-09-01", org = "ALS", results = list(pH = 6.4))
    fl_sample(con, "B.E01", wo, "2026-09-02", org = "ACIRL", results = list(pH = 6.3))
    fl_sample(con, "B.E01", wo, "2026-09-02", org = "ALS", results = list(pH = 7.0))
    fl_sample(con, "B.E01", wo, "2026-09-03", org = "ALS", results = list(pH = 6.4))
    # ALS batch carrying the field probe as EN67 Client Supplied Data
    fl_sample(con, "B.E01", wo, "2026-09-04", org = "ALS", results = list(
      list(analyte = "pH", value = 7.4, method_name = "pH", method = "EN67 - Client Supplied Data"),
      list(analyte = "pH", value = 6.4, method_name = "pH Value", method = "EA005P: pH by PC Titrator")))
    fl_sample(con, "B.E01", wo, "2026-09-05", org = "ACIRL", results = list(pH = 8.6))
  })
  lim <- fl_limits(list(analyte = "pH", min = "6.5", max = "8.5", unit = "pH"))
  ll <- fl_of(fl_run(db, fl_checks(limits = lim)), "licence_limit")
  expect_identical(ll$date, c("2026-09-05", "2026-09-03", "2026-09-02"))
  expect_equal(ll$value, c(8.6, 6.4, 6.3))
  expect_match(ll$threshold[[1]], "outside 6.5-8.5", fixed = TRUE)
})

# ---- 4.3 gas criteria --------------------------------------------------------------------

test_that("gas_criterion: LEL and EPA guideline rows, highest level per family, at air/gas points; others ignored", {
  db <- fl_db()
  fl_with(db, function(con) {
    fl_analyte(con, "CH4", units = "L/L")
    fl_analyte(con, "NH3-N", units = "mg/L")
    fl_guideline(con, "CH4", "LEL", 3, "10% of lower explosive limit", 0.005)
    fl_guideline(con, "CH4", "LEL", 4, "50% of lower explosive limit", 0.025)
    fl_guideline(con, "CH4", "EPA", 2, "solid waste guidelines trigger value", 0.0005)
    fl_guideline(con, "NH3-N", "dgv", 2, "ANZECC 95% species protection guideline value", 0.9)
    gas <- function(feature, v, q = TRUE, project = "2400-7538-09-01", ingested = fl_now() - 10 * 86400) {
      fl_sample(con, feature, project, "2026-09-28", org = "ACIRL", matrix = "air",
                type = "Monthly gas monitoring", ts_col = "date", ingested = ingested,
                results = list(list(analyte = "CH4", value = v, quantified = q)))
    }
    gas("B.G01", 0.006)            # > 10% LEL, > EPA
    gas("B.G02", 0.03)             # > 50% LEL, > EPA
    gas("B.G03", 0.005)            # exactly 10% LEL: EPA only
    gas("B.G04", 0.0004)           # nothing
    gas("B.G05", 0.01, q = FALSE)  # non-detect
    gas("B.G06", 0.5, project = "2400-7538-05-01", ingested = fl_now() - 100 * 86400)
    fl_sample(con, "B.S01", "ES2600070", "2026-09-14", results = list(`NH3-N` = 5))
  })
  gc <- fl_of(fl_run(db, fl_checks()), "gas_criterion")
  expect_equal(nrow(gc), 5)
  lel <- grepl("lower explosive", gc$threshold)
  expect_setequal(gc$feature[lel], c("B.G01", "B.G02"))
  expect_setequal(gc$feature[!lel], c("B.G01", "B.G02", "B.G03"))
  expect_match(gc$threshold[lel & gc$feature == "B.G01"], "10% of lower explosive limit", fixed = TRUE)
  expect_match(gc$threshold[lel & gc$feature == "B.G02"], "50% of lower explosive limit", fixed = TRUE)
  expect_true(all(gc$analyte == "CH4"))
  expect_true(all(gc$date == "2026-09-28"))
})

# ---- 4.3 site history ------------------------------------------------------------------

sh_prior_dates <- c("2022-01-15", "2022-07-15", "2023-01-15", "2023-07-15",
                    "2024-01-15", "2024-07-15", "2025-01-15", "2026-06-15")

sh_seed <- function(con, feature, priors, new, new_q = TRUE, prior_q = rep(TRUE, length(priors)),
                    dates = sh_prior_dates[seq_along(priors)]) {
  fl_analyte(con, "EC", units = "µS/cm")
  for (i in seq_along(priors)) {
    fl_sample(con, feature, "HIST", dates[[i]], ingested = NULL,
              results = list(list(analyte = "EC", value = priors[[i]], quantified = prior_q[[i]])))
  }
  fl_sample(con, feature, "ES2600080", "2026-09-14",
            results = list(list(analyte = "EC", value = new, quantified = new_q)))
}

test_that("site_history: >= 8 prior quantified results, outside the range and |robust z| > 4 -> flagged (high and low)", {
  db <- fl_db()
  fl_with(db, function(con) {
    sh_seed(con, "B.MW01", 100:107, 300)          # z ~ +66
    sh_seed(con, "B.MW05", 100:107, 50)           # z ~ -18 (quantified low)
    sh_seed(con, "B.MW03", seq(100, 170, 10), 175)  # outside range, z ~ 1.35
  })
  sh <- fl_of(fl_run(db, fl_checks()), "site_history")
  expect_setequal(sh$feature, c("B.MW01", "B.MW05"))
  expect_identical(unique(sh$analyte), "EC")
  expect_identical(unique(sh$date), "2026-09-14")
  expect_equal(sh$value[sh$feature == "B.MW01"], 300)
  expect_match(sh$threshold[sh$feature == "B.MW01"], "n=8", fixed = TRUE)
})

test_that("site_history: 7 priors, a prior older than 5 years, prior non-detects and a below-detection new result are not flagged", {
  db <- fl_db()
  fl_with(db, function(con) {
    sh_seed(con, "B.MW02", 100:106, 300)                                   # only 7 priors
    sh_seed(con, "B.MW06", 100:107, 300,
            dates = c("2020-01-15", sh_prior_dates[-1]))                    # 1 prior > 5 y old
    sh_seed(con, "B.MW07", 100:107, 300, prior_q = c(FALSE, rep(TRUE, 7)))  # 7 quantified
    sh_seed(con, "B.MW04", 100:107, 1, new_q = FALSE)                       # below detection, low
  })
  expect_equal(nrow(fl_of(fl_run(db, fl_checks()), "site_history")), 0)
})

test_that("site_history: MAD 0 - flagged when outside the (single-valued) prior range, not when equal", {
  db <- fl_db()
  fl_with(db, function(con) {
    sh_seed(con, "B.MW08", rep(5, 8), 5.5)
    sh_seed(con, "B.MW09", rep(5, 8), 5)
  })
  sh <- fl_of(fl_run(db, fl_checks()), "site_history")
  expect_identical(sh$feature, "B.MW08")
})

# ---- 4.3 reporting limit and unit changes ---------------------------------------------------

test_that("rl_change (R5): only an RL RAISED above the pair's maximum RL of the prior 2 years is flagged", {
  db <- fl_db()
  fl_with(db, function(con) {
    fl_analyte(con, "Pb")
    nd <- function(rl) list(list(analyte = "Pb", value = rl, quantified = FALSE, rl = rl))
    nd_na <- list(list(analyte = "Pb", value = 0.001, quantified = FALSE))
    hist <- function(feature, at, rl) {
      fl_sample(con, feature, "HIST", at, results = if (is.na(rl)) nd_na else nd(rl), ingested = NULL)
    }
    new <- function(feature, rl) fl_sample(con, feature, "ES2600090", "2026-09-14", results = nd(rl))
    hist("B.MW01", "2026-06-01", 0.001); new("B.MW01", 0.005)     # raised -> flag
    hist("B.MW02", "2026-06-01", 0.001); new("B.MW02", 0.001)     # same
    hist("B.MW03", "2026-06-01", NA);    new("B.MW03", 0.005)     # no prior RL
    hist("B.MW04", "2026-01-01", 0.005); hist("B.MW04", "2026-06-01", 0.001)
    new("B.MW04", 0.005)                                          # not above the 2-y max
    hist("B.MW10", "2026-06-01", 0.005); new("B.MW10", 0.001)     # lowered
    hist("B.MW11", "2024-06-01", 0.01);  hist("B.MW11", "2026-06-01", 0.001)
    new("B.MW11", 0.005)                                          # 0.01 is > 2 y old -> flag
  })
  rc <- fl_of(fl_run(db, fl_checks()), "rl_change")
  expect_setequal(rc$feature, c("B.MW01", "B.MW11"))
  d1 <- rc$detail[rc$feature == "B.MW01"]
  expect_match(d1, "0.001", fixed = TRUE)
  expect_match(d1, "0.005", fixed = TRUE)
  expect_identical(unique(rc$date), "2026-09-14")
})

test_that("unit_change: the reporting unit (lab_method.units, else analyte.units) changed since the last result", {
  db <- fl_db()
  fl_with(db, function(con) {
    fl_analyte(con, "Zn", units = "mg/L")
    zn <- function(v, units = NULL) list(list(analyte = "Zn", value = v, units = units))
    fl_sample(con, "B.MW05", "HIST", "2026-06-01", results = zn(0.01, "mg/L"), ingested = NULL)
    fl_sample(con, "B.MW05", "ES2600091", "2026-09-14", results = zn(0.01, "µg/L"))
    fl_sample(con, "B.MW06", "HIST", "2026-06-01", results = zn(0.01), ingested = NULL)
    fl_sample(con, "B.MW06", "ES2600091", "2026-09-14", results = zn(0.01))
  })
  uc <- fl_of(fl_run(db, fl_checks()), "unit_change")
  expect_identical(uc$feature, "B.MW05")
  expect_match(uc$detail, "mg/L", fixed = TRUE)
  expect_match(uc$detail, "µg/L", fixed = TRUE)
})

# ---- keys, ordering, inputs as files ------------------------------------------------------

keyed_db <- function(env = parent.frame()) {
  db <- fl_db(env = env)
  fl_with(db, function(con) {
    fl_sample(con, "B.E01", "ES2600100", "2026-09-11", results = list(`NH3-N` = 2))
    fl_sample(con, "B.E01", "ES2600100", "2026-09-12", results = list(`NH3-N` = 3))
  })
  db
}
keyed_checks <- function() {
  fl_checks(schedule = fl_schedule(list(site = "K", months = "7;8")),
            limits = fl_limits(list(max = "0.9")))
}

test_that("keys are unique, non-missing and do not depend on `now`; rows ordered by check then date desc", {
  db <- keyed_db()
  f1 <- fl_run(db, keyed_checks(), now = fl_now())
  f2 <- fl_run(db, keyed_checks(), now = fl_now() + 3 * 3600)
  expect_gt(nrow(f1), 3)
  expect_false(anyNA(f1$key))
  expect_false(anyDuplicated(f1$key) > 0)
  expect_identical(f1$key, f2$key)
  expect_identical(f1$check, c("overdue", "overdue", "licence_limit", "licence_limit"))
  expect_identical(f1$date, c("2026-08-01", "2026-07-01", "2026-09-12", "2026-09-11"))
})

test_that("checks given as CSV paths give the same flags as data.frames; a missing file fails only its own checks", {
  db <- keyed_db()
  d <- withr::local_tempdir()
  chk <- keyed_checks()
  sp <- file.path(d, "expected_schedule.csv")
  lp <- file.path(d, "epa_licence_limits.csv")
  utils::write.csv(chk$schedule, sp, row.names = FALSE, na = "")
  utils::write.csv(chk$limits, lp, row.names = FALSE, na = "")
  f_df <- fl_run(db, chk)
  f_csv <- fl_run(db, fl_checks(schedule = sp, limits = lp))
  expect_identical(f_csv$key, f_df$key)
  expect_identical(f_csv$threshold, f_df$threshold)

  f_bad <- fl_run(db, fl_checks(schedule = sp, limits = file.path(d, "nope.csv")))
  expect_identical(names(attr(f_bad, "errors")), "licence_limit")
  expect_equal(nrow(fl_of(f_bad, "licence_limit")), 0)
  expect_equal(nrow(fl_of(f_bad, "overdue")), 2)
})

# ---- the status note and JSON ------------------------------------------------------------------

test_that("import_status(checks = NULL): no Flags section and no `flags` in the JSON (phase-1 output)", {
  s <- fl_status_setup()
  fl_status(s, checks = NULL)
  lines <- read_status_note(s$report_dir)
  expect_false(any(grepl("^## Flags", lines)))
  js <- fl_status_json(s)
  expect_false("flags" %in% names(js))
  expect_false("flag_errors" %in% names(js))
})

test_that("import_status(checks): '## Flags' sits between Needs review and Waiting; 'No flags.' when none", {
  s <- fl_status_setup()
  fl_status(s, checks = fl_checks())
  lines <- read_status_note(s$report_dir)
  i_nr <- which(lines == "## Needs review")
  i_fl <- which(lines == "## Flags")
  i_wa <- which(lines == "## Waiting")
  expect_length(i_fl, 1)
  expect_true(i_nr < i_fl && i_fl < i_wa)
  expect_true("No flags." %in% md_section(lines, "Flags"))
  js <- fl_status_json(s)
  expect_length(js$flags, 0)
})

test_that("import_status(checks): flags grouped by check in the fixed order, newest first within a group", {
  s <- fl_status_setup()
  fl_with(s$db, function(con) {
    fl_sample(con, "B.E01", "ES2600110", "2026-09-11", results = list(`NH3-N` = 2))
  })
  fl_status(s, checks = fl_checks(schedule = fl_schedule(list(site = "K", months = "7;8")),
                                  limits = fl_limits(list(max = "0.9"))))
  sec <- md_section(read_status_note(s$report_dir), "Flags")
  h_od <- grep("^\\*\\*overdue\\*\\*", sec)
  h_ll <- grep("^\\*\\*licence_limit\\*\\*", sec)
  expect_length(h_od, 1)
  expect_length(h_ll, 1)
  expect_true(h_od < h_ll)
  i_aug <- grep("^- .*2026-08-01", sec)
  i_jul <- grep("^- .*2026-07-01", sec)
  i_nh3 <- grep("^- .*2026-09-11", sec)
  expect_length(i_aug, 1)
  expect_length(i_jul, 1)
  expect_length(i_nh3, 1)
  expect_true(h_od < i_aug && i_aug < i_jul && i_jul < h_ll && h_ll < i_nh3)
  expect_match(sec[[i_nh3]], "B.E01", fixed = TRUE)
  expect_false("No flags." %in% sec)
})

test_that(".import-status.json: flags carry first_seen, kept by key across runs; new flags get now; gone flags drop", {
  s <- fl_status_setup()
  chk <- fl_checks(schedule = fl_schedule(list(site = "K", months = "7;8")),
                   limits = fl_limits(list(max = "0.9")))
  fl_with(s$db, function(con) {
    fl_sample(con, "B.E01", "ES2600120", "2026-09-11", results = list(`NH3-N` = 2))
  })
  t1 <- fl_now()
  fl_status(s, checks = chk, now = t1)
  js1 <- fl_status_json(s)
  expect_length(js1$flags, 3)
  for (fl in js1$flags) {
    expect_true(all(c(fl_flag_cols, "first_seen") %in% names(fl)))
    expect_identical(fl$first_seen, "2026-10-19T02:00:00Z")
  }

  # Between runs: July's Katoomba delivery turns up; a new NH3 exceedance lands.
  fl_with(s$db, function(con) {
    fl_sample(con, "K.S01", "ES2600121", "2026-07-20", org = "ACIRL", results = list(pH = 7))
    fl_sample(con, "B.E01", "ES2600122", "2026-09-25", results = list(`NH3-N` = 4))
  })
  t2 <- t1 + 2 * 3600
  fl_status(s, checks = chk, now = t2)
  js2 <- fl_status_json(s)
  by_key <- function(js) stats::setNames(vapply(js$flags, function(x) x$first_seen, ""),
                                          vapply(js$flags, function(x) x$key, ""))
  k1 <- by_key(js1)
  k2 <- by_key(js2)
  expect_length(k2, 3)
  kept <- intersect(names(k1), names(k2))
  expect_length(kept, 2)                                  # Aug overdue + 09-11 NH3
  expect_identical(unname(k2[kept]), rep("2026-10-19T02:00:00Z", 2))
  new <- setdiff(names(k2), names(k1))
  expect_identical(unname(k2[new]), "2026-10-19T04:00:00Z")
  dates2 <- vapply(js2$flags, function(x) x$date, "")
  expect_false("2026-07-01" %in% dates2)                  # cleared overdue dropped
})

test_that("status note (R6): at most 15 lines per check, newest first, then '+N more'; the JSON keeps all", {
  s <- fl_status_setup()
  # no samples: B and K each overdue Oct 2025 .. Aug 2026 = 22 flags
  chk <- fl_checks(schedule = fl_schedule(list(site = "B"), list(site = "K")))
  fl_status(s, checks = chk)
  sec <- md_section(read_status_note(s$report_dir), "Flags")
  h <- grep("^\\*\\*overdue\\*\\*", sec)
  expect_length(h, 1)
  rest <- sec[(h + 1):length(sec)]
  nxt <- grep("^\\*\\*", rest)
  grp <- if (length(nxt)) rest[seq_len(nxt[[1]] - 1)] else rest
  items <- grp[grepl("^- ", grp) & !grepl("more — see", grp, fixed = TRUE)]
  expect_length(items, 15)
  expect_true(any(grepl("+7 more — see .import-status.json", grp, fixed = TRUE)))
  expect_match(items[[1]], "2026-08-01", fixed = TRUE)
  expect_false(any(grepl("2025-10-01", items, fixed = TRUE)))
  expect_length(fl_status_json(s)$flags, 22)
})

test_that("a failing check does not break the note: 'check <name> failed: <msg>' in Flags; other checks still listed", {
  s <- fl_status_setup()
  chk <- fl_checks(schedule = fl_schedule(list(site = "K", months = "8")),
                   limits = file.path(s$report_dir, "no-such-limits.csv"))
  expect_no_error(fl_status(s, checks = chk))
  sec <- md_section(read_status_note(s$report_dir), "Flags")
  expect_true(any(grepl("check licence_limit failed: ", sec, fixed = TRUE)))
  expect_true(any(grepl("^- .*2026-08-01", sec)))
  js <- fl_status_json(s)
  expect_identical(vapply(js$flag_errors, function(e) e$check, ""), "licence_limit")
  expect_true(nzchar(js$flag_errors[[1]]$message))
  expect_length(js$flags, 1)
})

test_that("inbox_run(checks = ...) passes checks to the status note on a run and on a status refresh", {
  s <- fl_status_setup()
  chk <- fl_checks(schedule = fl_schedule(list(site = "K", months = "8")))
  run <- function(now) quiet_run(inbox_run(input_dir = s$input_dir, db = s$db,
                                           backup_dir = s$backup_dir, report_dir = s$report_dir,
                                           now = now, checks = chk))
  r1 <- run(fl_now())
  expect_identical(r1$action, "run")
  sec <- md_section(read_status_note(s$report_dir), "Flags")
  expect_true(any(grepl("^- .*2026-08-01", sec)))

  unlink(status_note_path(s$report_dir))
  Sys.setFileTime(s$db, Sys.time() + 120)          # DB stat changed -> "status"
  r2 <- run(fl_now() + 3600)
  expect_identical(r2$action, "status")
  sec2 <- md_section(read_status_note(s$report_dir), "Flags")
  expect_true(any(grepl("^- .*2026-08-01", sec2)))
})

test_that("inbox_run() without checks writes no Flags section (backward compatible)", {
  s <- fl_status_setup()
  quiet_run(inbox_run(input_dir = s$input_dir, db = s$db, backup_dir = s$backup_dir,
                      report_dir = s$report_dir, now = fl_now()))
  expect_false(any(grepl("^## Flags", read_status_note(s$report_dir))))
})
