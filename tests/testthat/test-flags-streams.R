# Stage 1 of the layer move: `checks$streams` replaces the stream constants
# that were hard-coded in R/flags.R and R/qc.R (acirl_water / acirl_gas /
# acirl_dust / als_lab, the ACIRL/ALS organisation tests, dust and gas
# inference). Spec: the stage-1 spec, section A3.
#
# Synthetic throughout: site N, features N.W01 / N.P01 / N.X01, organisations
# FIELDCO (field sheets) and LABCO (a laboratory), project types "Gas round"
# and "Deposition round". helper-streams.R has the builders. Probe schedules
# list one expected feature (N.ZZ9) that is never sampled, so a stream shows up
# as a `missing_point|N|<yyyy-mm>|<stream>` flag exactly when a recent sample
# counted for it in that month.

sx_ing <- function() fl_now() - 10 * 86400    # a recent delivery (the helper's default)

# ---- 9. no streams ------------------------------------------------------------------

test_that("streams absent: schedule checks error 'unknown stream', other checks still run", {
  db <- fl_db()
  fl_with(db, function(con) {
    fl_sample(con, "N.W01", "WO-1", "2026-09-10", org = "FIELDCO",
              results = list(`NH3-N` = 5))
  })
  checks <- list(
    schedule = fl_schedule(list(site = "N", stream = "s1", months = "all")),
    limits = fl_limits_plain(list(site = "N", feature_pattern = "^N\\.W01$",
                                  analyte = "NH3-N", max = "0.9")))
  f <- sx_raw_flags(db, checks)
  err <- attr(f, "errors")
  expect_true("overdue" %in% names(err))
  expect_match(err[["overdue"]], "unknown stream", ignore.case = TRUE)
  expect_equal(nrow(fl_of(f, "licence_limit")), 1)
  # also when `streams` is named but NULL
  f2 <- sx_raw_flags(db, c(checks, list(streams = NULL)))
  expect_match(attr(f2, "errors")[["overdue"]], "unknown stream", ignore.case = TRUE)
})

test_that("streams: a schedule stream missing from the table is 'unknown stream' too", {
  db <- fl_db()
  f <- fl_run(db, sx_checks(schedule = fl_schedule(list(site = "N", stream = "nope"))))
  expect_match(attr(f, "errors")[["overdue"]], "unknown stream.*nope")
})

# ---- 10-11. evidence rows ---------------------------------------------------------------

test_that("streams: a FIELDCO result counts for the field stream, a LABCO result for the lab stream, a sample with both for both", {
  db <- fl_db()
  fl_with(db, function(con) {
    fl_sample(con, "N.W01", "WO-A", "2026-07-14", org = "FIELDCO", results = list(pH = 7))
    # a lower-case organisation still matches (both sides are upper-cased)
    fl_sample(con, "N.P01", "WO-B", "2026-08-14", org = "labco", results = list(pH = 7))
    fl_sample(con, "N.X01", "WO-C", "2026-09-14", org = "FIELDCO", results = list(
      list(analyte = "pH", value = 7, lab_org = "FIELDCO"),
      list(analyte = "Zn", value = 0.1, lab_org = "LABCO")))
  })
  f <- fl_run(db, sx_checks(schedule = sx_probe_schedule(c("field", "lab"))))
  expect_length(attr(f, "errors"), 0)
  expect_identical(sx_mp_streams(f, "2026-07"), "field")
  expect_identical(sx_mp_streams(f, "2026-08"), "lab")
  expect_identical(sx_mp_streams(f, "2026-09"), c("field", "lab"))
  # the same through overdue: a month with only a field sample is overdue for the lab stream
  od <- fl_of(sx_raw_flags(db, sx_checks(schedule = fl_schedule(
    list(site = "N", stream = "field", months = "7;8;9"),
    list(site = "N", stream = "lab", months = "7;8;9")))), "overdue")
  expect_setequal(od$key, c("overdue|N|lab|2026-07", "overdue|N|field|2026-08"))
})

test_that("streams: a 'Client Supplied' method under a lab organisation counts as field, not lab", {
  db <- fl_db()
  fl_with(db, function(con) {
    fl_sample(con, "N.W01", "WO-D", "2026-09-14", org = "LABCO", results = list(
      list(analyte = "pH", value = 7, lab_org = "LABCO", method_name = "pH",
           method = "EN67 - Client Supplied Data")))
  })
  f <- fl_run(db, sx_checks(schedule = sx_probe_schedule(c("field", "lab"))))
  expect_identical(sx_mp_streams(f, "2026-09"), "field")
})

# ---- 12. claim rows -----------------------------------------------------------------------

test_that("streams: claim precedence, ANDed criteria within a row, ORed across rows; a claimed sample adds no evidence stream", {
  db <- fl_db()
  fl_with(db, function(con) {
    add <- function(feature, project, at, type) {
      fl_sample(con, feature, project, at, org = "FIELDCO", type = type, results = list(pH = 7))
    }
    add("N.Q01", "WO-1", "2026-05-12", "Work order")        # no claim: evidence (field)
    add("N.W02", "WO-2", "2026-06-10", "Work order")        # claimed by the pattern stream
    add("N.W01", "WO-3", "2026-07-14", "Gas round")         # two claims match; the first listed wins
    add("N.P01", "WO-4", "2026-08-14", "Gas round")         # both criteria of the AND row match
    add("N.X01", "WO-5", "2026-09-14", "Work order")        # second row of the OR stream
    add("N.Y01", "WO-6", "2026-10-05", "Deposition round")  # first row of the OR stream
  })
  streams <- sx_streams(
    list(stream = "s_and", project_type = "Gas round", feature_pattern = "^N\\.P"),
    list(stream = "s_first", project_type = "Gas round"),
    list(stream = "s_second", feature_pattern = "^N\\.W"),
    list(stream = "s_or", project_type = "Deposition round"),
    list(stream = "s_or", feature_pattern = "^N\\.X"),
    list(stream = "field", organisation = "FIELDCO", kind = "field", water = TRUE))
  f <- fl_run(db, sx_checks(streams = streams, schedule = sx_probe_schedule(
    c("s_and", "s_first", "s_second", "s_or", "field"))))
  expect_length(attr(f, "errors"), 0)
  expect_identical(sx_mp_streams(f, "2026-05"), "field")
  expect_identical(sx_mp_streams(f, "2026-06"), "s_second")
  expect_identical(sx_mp_streams(f, "2026-07"), "s_first")     # not s_second, not field
  expect_identical(sx_mp_streams(f, "2026-08"), "s_and")       # not s_first
  expect_identical(sx_mp_streams(f, "2026-09"), "s_or")
  expect_identical(sx_mp_streams(f, "2026-10"), "s_or")
})

test_that("streams: the matrix criterion is an exact match on feature.matrix", {
  db <- fl_db()
  fl_with(db, function(con) {
    fl_sample(con, "N.W01", "WO-1", "2026-09-14", org = "FIELDCO", matrix = "air",
              results = list(pH = 7))
    fl_sample(con, "N.P01", "WO-2", "2026-10-05", org = "FIELDCO", matrix = "freshwater",
              results = list(pH = 7))
  })
  streams <- sx_streams(list(stream = "aerial", matrix = "air"),
                        list(stream = "field", organisation = "FIELDCO", kind = "field"))
  f <- fl_run(db, sx_checks(streams = streams, schedule = sx_probe_schedule(c("aerial", "field"))))
  expect_identical(sx_mp_streams(f, "2026-09"), "aerial")
  expect_identical(sx_mp_streams(f, "2026-10"), "field")
})

# ---- 13. window_months -----------------------------------------------------------------------

test_that("streams: window_months lets a neighbouring month's sample meet missing_point; 0 does not", {
  db <- fl_db()
  fl_with(db, function(con) {
    # legacy samples (no change_log): they count as sampled but start no round
    fl_sample(con, "N.P01", "WO-0", "2026-08-28", org = "FIELDCO", ingested = NULL,
              results = list(pH = 7))
    fl_sample(con, "N.P02", "WO-00", "2026-10-03", org = "FIELDCO", ingested = NULL,
              results = list(pH = 7))
    fl_sample(con, "N.W01", "WO-1", "2026-09-10", org = "FIELDCO", type = "Gas round",
              results = list(pH = 7))
    fl_sample(con, "N.Q01", "WO-2", "2026-09-10", org = "FIELDCO", type = "Deposition round",
              results = list(pH = 7))
  })
  streams <- sx_streams(
    list(stream = "win", project_type = "Gas round", window_months = 1L),
    list(stream = "nowin", project_type = "Deposition round", window_months = 0L))
  f <- fl_run(db, sx_checks(streams = streams, schedule = sx_probe_schedule(
    c("win", "nowin"), features = "N.P01;N.P02")))
  expect_length(attr(f, "errors"), 0)
  expect_identical(sx_mp_streams(f, "2026-09"), "nowin")
  mp <- fl_of(f, "missing_point")
  expect_match(mp$detail, "2 of 2 expected points not sampled: N.P01, N.P02", fixed = TRUE)
})

# ---- 14. water -----------------------------------------------------------------------------------

test_that("streams: a point sampled only under a non-water stream is still missing for a water round", {
  db <- fl_db()
  fl_with(db, function(con) {
    fl_sample(con, "N.W01", "WO-1", "2026-09-10", org = "FIELDCO", results = list(pH = 7))
    fl_sample(con, "N.P01", "WO-2", "2026-09-10", org = "FIELDCO", type = "Gas round",
              results = list(pH = 7))
  })
  sched <- sx_probe_schedule("wat", features = "N.W01;N.P01")
  streams <- sx_streams(
    list(stream = "wat", organisation = "FIELDCO", kind = "field", water = TRUE),
    list(stream = "other", project_type = "Gas round", water = FALSE))
  f <- fl_run(db, sx_checks(streams = streams, schedule = sched))
  mp <- fl_of(f, "missing_point")
  expect_equal(nrow(mp), 1)
  expect_identical(sx_mp_streams(f, "2026-09"), "wat")
  expect_match(mp$detail, "1 of 2 expected points not sampled: N.P01", fixed = TRUE)
  # the same data with the claiming stream flagged `water`: the point is met
  streams$water[streams$stream == "other"] <- TRUE
  f2 <- fl_run(db, sx_checks(streams = streams, schedule = sched))
  expect_equal(nrow(fl_of(f2, "missing_point")), 0)
})

# ---- 15. gas -------------------------------------------------------------------------------------------

test_that("streams: a non-air sample claimed by a gas stream gets a gas_criterion flag; without `gas` it does not", {
  db <- fl_db()
  fl_with(db, function(con) {
    fl_analyte(con, "CH4", units = "L/L")
    fl_guideline(con, "CH4", "LEL", 3, "10% of lower explosive limit", 0.005)
    fl_sample(con, "N.W01", "WO-G1", "2026-09-28", org = "FIELDCO", type = "Gas round",
              matrix = "freshwater", results = list(CH4 = 0.006))
  })
  gas <- sx_streams(list(stream = "g", project_type = "Gas round", gas = TRUE))
  gc <- fl_of(fl_run(db, sx_checks(streams = gas)), "gas_criterion")
  expect_equal(nrow(gc), 1)
  expect_identical(gc$feature, "N.W01")
  nogas <- sx_streams(list(stream = "g", project_type = "Gas round", gas = FALSE))
  expect_equal(nrow(fl_of(fl_run(db, sx_checks(streams = nogas)), "gas_criterion")), 0)
})

# ---- 16. expects_qci ---------------------------------------------------------------------------------------

test_that("streams: lab_qc_missing applies only to streams with expects_qci", {
  db <- qc_db()
  fl_with(db, function(con) {
    fl_sample(con, "N.X01", "WO-L1", "2026-09-14", org = "LABCO", results = list(
      list(analyte = "Zn", value = 0.1, lab_org = "LABCO")))
    fl_sample(con, "N.X02", "WO-D1", "2026-09-14", org = "LABCO", type = "Deposition round",
              results = list(list(analyte = "Zn", value = 0.1, lab_org = "LABCO")))
  })
  streams <- sx_streams(
    list(stream = "lab", organisation = "LABCO", kind = "lab", water = TRUE, expects_qci = TRUE),
    list(stream = "dep", project_type = "Deposition round", expects_qci = FALSE))
  keys <- function(s) fl_of(fl_run(db, sx_checks(streams = s)), "lab_qc_missing")$key
  expect_identical(keys(streams), "lab_qc_missing|WO-L1")
  streams$expects_qci[streams$stream == "dep"] <- TRUE
  expect_setequal(keys(streams), c("lab_qc_missing|WO-L1", "lab_qc_missing|WO-D1"))
  streams$expects_qci <- FALSE
  expect_length(keys(streams), 0)
})

# ---- 17. licence "field wins" ----------------------------------------------------------------------------------

test_that("streams: licence_limit 'field wins' follows the table's field organisations", {
  db <- fl_db()
  fl_with(db, function(con) {
    # day 1: a FIELDCO pH of 7.4 and a LABCO pH of 6.4 for one feature and day
    fl_sample(con, "N.W01", "WO-1", "2026-09-01 01:00:00", org = "FIELDCO", results = list(pH = 7.4))
    fl_sample(con, "N.W01", "WO-1", "2026-09-01 02:00:00", org = "LABCO", results = list(pH = 6.4))
    # day 2: a LABCO batch carrying a Client Supplied pH (7.4) and its own lab pH (6.4)
    fl_sample(con, "N.W01", "WO-1", "2026-09-02 02:00:00", org = "LABCO", results = list(
      list(analyte = "pH", value = 7.4, lab_org = "LABCO", method_name = "pH",
           method = "EN67 - Client Supplied Data"),
      list(analyte = "pH", value = 6.4, lab_org = "LABCO", method_name = "pH Value",
           method = "EA005P: pH by PC Titrator")))
  })
  lim <- fl_limits_plain(list(site = "N", feature_pattern = "^N\\.W01$", analyte = "pH",
                        min = "6.5", max = "8.5", unit = "pH", condition = "T1.1"))
  # FIELDCO is the field organisation: the field value (and the Client Supplied one) wins
  ll <- fl_of(fl_run(db, sx_checks(streams = sx_evidence(), limits = lim)), "licence_limit")
  expect_equal(nrow(ll), 0)
  # swap the roles: LABCO is now the field organisation, FIELDCO the lab
  swapped <- sx_streams(
    list(stream = "field", organisation = "LABCO", kind = "field", water = TRUE),
    list(stream = "lab", organisation = "FIELDCO", kind = "lab", water = TRUE))
  ll2 <- fl_of(fl_run(db, sx_checks(streams = swapped, limits = lim)), "licence_limit")
  expect_identical(ll2$date, c("2026-09-02", "2026-09-01"))
  expect_equal(ll2$value, c(6.4, 6.4))
  expect_true(all(grepl("\\|field$", ll2$key)))
})

# ---- 18. malformed tables ------------------------------------------------------------------------------------------

test_that("streams: a malformed table gives an errors entry containing 'streams:'", {
  db <- fl_db()
  ev <- function(...) list(stream = "e", organisation = "FIELDCO", kind = "field", ...)
  bad <- list(
    mixed_claim_and_evidence = sx_streams(list(stream = "s", project_type = "Gas round",
                                               organisation = "FIELDCO", kind = "field")),
    neither = sx_streams(list(stream = "s")),
    kind_x = sx_streams(list(stream = "s", organisation = "FIELDCO", kind = "x")),
    evidence_without_kind = sx_streams(list(stream = "s", organisation = "FIELDCO")),
    water_differs = sx_streams(list(stream = "s", project_type = "Gas round", water = TRUE),
                               list(stream = "s", feature_pattern = "^N", water = FALSE)),
    gas_differs = sx_streams(list(stream = "s", project_type = "Gas round", gas = TRUE),
                             list(stream = "s", feature_pattern = "^N", gas = FALSE)),
    window_differs = sx_streams(list(stream = "s", project_type = "Gas round", window_months = 1L),
                                list(stream = "s", feature_pattern = "^N", window_months = 0L)),
    qci_differs = sx_streams(list(stream = "s", project_type = "Gas round", expects_qci = TRUE),
                             list(stream = "s", feature_pattern = "^N", expects_qci = FALSE)),
    negative_window = sx_streams(list(stream = "s", project_type = "Gas round", window_months = -1L)),
    fractional_window = sx_streams(list(stream = "s", project_type = "Gas round", window_months = 1.5)),
    claim_and_evidence_rows = sx_streams(list(stream = "s", project_type = "Gas round"),
                                         list(stream = "s", organisation = "FIELDCO", kind = "field")),
    stream_is_na = sx_streams(list(stream = NA_character_, project_type = "Gas round"))
  )
  for (nm in names(bad)) {
    f <- fl_run(db, sx_checks(streams = bad[[nm]], schedule = fl_schedule(list(site = "N", stream = "s"))))
    err <- attr(f, "errors")
    expect_true(length(err) > 0 && any(grepl("streams:", err, fixed = TRUE)), info = nm)
  }
})

test_that("streams: a table without a `stream` column is an error that names streams", {
  db <- fl_db()
  f <- fl_run(db, sx_checks(streams = data.frame(project_type = "Gas round")))
  err <- attr(f, "errors")
  expect_true(length(err) > 0 && any(grepl("streams", err, fixed = TRUE)))
})

test_that("streams: only `stream` is required; absent columns take their defaults, and a CSV path is accepted", {
  db <- fl_db()
  fl_with(db, function(con) {
    fl_sample(con, "N.W01", "WO-1", "2026-09-14", org = "FIELDCO", type = "Gas round",
              results = list(pH = 7))
  })
  sched <- sx_probe_schedule("g")
  minimal <- data.frame(stream = "g", project_type = "Gas round", stringsAsFactors = FALSE)
  f <- fl_run(db, sx_checks(streams = minimal, schedule = sched))
  expect_length(attr(f, "errors"), 0)
  expect_identical(sx_mp_streams(f, "2026-09"), "g")
  p <- file.path(withr::local_tempdir(), "streams.csv")
  utils::write.csv(minimal, p, row.names = FALSE, na = "")
  f2 <- fl_run(db, sx_checks(streams = p, schedule = sched))
  expect_length(attr(f2, "errors"), 0)
  expect_identical(sx_mp_streams(f2, "2026-09"), "g")
})

# ---- 19. missing_result ----------------------------------------------------------------------------------------------------

test_that("streams: missing_result asks the field organisation by name; any other organisation gets ask_lab", {
  db <- fl_db()
  fl_with(db, function(con) {
    fl_analyte(con, "Water level", units = "m")
    blank <- function(feature, project, org) {
      fl_sample(con, feature, project, "2026-09-09", org = org, results = list(
        list(analyte = "Water level", value = NULL, value_chr = "_")))
    }
    blank("N.W01", "WO-F", "FIELDCO")
    blank("N.W02", "WO-f", "fieldco")
    blank("N.P01", "WO-L", "LABCO")
  })
  mr <- fl_of(fl_run(db, sx_checks()), "missing_result")
  expect_equal(nrow(mr), 3)
  f1 <- mr[mr$feature == "N.W01", ]
  expect_identical(f1$action, "ask_fieldco")
  expect_match(f1$detail, "ask FIELDCO", fixed = TRUE)
  expect_match(f1$detail, "for the value or why it wasn't measured", fixed = TRUE)
  # the sample's organisation is compared upper-cased; the table's spelling is used
  f2 <- mr[mr$feature == "N.W02", ]
  expect_identical(f2$action, "ask_fieldco")
  expect_match(f2$detail, "ask FIELDCO", fixed = TRUE)
  l1 <- mr[mr$feature == "N.P01", ]
  expect_identical(l1$action, "ask_lab")
  expect_match(l1$detail, "ask the lab", fixed = TRUE)
  expect_no_match(l1$detail, "FIELDCO", fixed = TRUE)
})

# ---- 20. accepted element names ----------------------------------------------------------------------------------------------

test_that("import_flags: `streams` and `site_names` are accepted checks elements; any other name is still an error", {
  db <- fl_db()
  ok <- list(streams = sx_evidence(), site_names = c(N = "Northvale"))
  f <- expect_no_error(sx_raw_flags(db, ok))
  expect_length(attr(f, "errors"), 0)
  expect_error(sx_raw_flags(db, c(ok, list(foo = 1))), "Unknown element")
})
