# PLAN-19 R-19.25 `qc_blank_detect` (+ R-19.7 analyte.lab_contaminant, R19-10
# (2)/(4)): a detection is any quantified lab result in a blank; it qualifies
# every associated non-QC result of the round (same work order project, same
# site, same analyte and method) that is quantified and < f x the blank value
# (f = 10 for a lab contaminant, else 5). A blank is never subtracted.
#
# Codes and parents are invented (site Q; helper-qc.R).

wo <- "ES2600501"
d_round <- "2026-09-28"
amm <- "EK055G: Ammonia as N by Discrete Analyser"
nh3 <- function(v, rl = 0.01, q = TRUE) qc_lab("NH3-N", v, rl = rl, quantified = q, method = amm)

blank_key <- function(code) sprintf("qc_blank_detect|%s|%s", code, d_round)

# A field blank with an NH3-N detection (0.05) and a Zinc non-detect, and the
# round's points: Q.X01 0.2 (< 5 x 0.05 -> qualified), Q.X02 0.3 (not),
# Q.X03 a non-detect (not), Q.X04 0.1 in ANOTHER work order (not associated).
field_blank_round <- function(con, code = "Q.JF42", qc_type = "field_blank", parent = "Q.X01") {
  qc_add(con, code, qc_type, parent = parent)
  fl_sample(con, code, wo, d_round, results = list(nh3(0.05), qc_nd("Zinc", 0.005)))
  fl_sample(con, "Q.X01", wo, d_round, results = list(nh3(0.2), qc_lab("Zinc", 0.02, rl = 0.005)))
  fl_sample(con, "Q.X02", wo, d_round, results = list(nh3(0.3)))
  fl_sample(con, "Q.X03", wo, d_round, results = list(nh3(0.01, q = FALSE)))
  fl_sample(con, "Q.X04", "ES2600502", d_round, results = list(nh3(0.1)))
}

test_that("qc_blank_detect: one flag per blank listing detections and the results they qualify, at the parent point", {
  db <- qc_db()
  fl_with(db, function(con) field_blank_round(con))
  f <- fl_run(db, qc_checks())
  expect_length(attr(f, "errors"), 0)
  bd <- fl_of(f, "qc_blank_detect")
  expect_equal(nrow(bd), 1)
  expect_identical(bd$key, blank_key("Q.JF42"))
  expect_identical(bd$site, "Q")
  expect_identical(bd$feature, "Q.X01")
  expect_identical(bd$date, d_round)
  expect_identical(bd$action, "qualify")
  expect_match(bd$detail, "Q.JF42", fixed = TRUE)
  expect_match(bd$detail, "NH3-N", fixed = TRUE)
  expect_match(bd$detail, "0.05", fixed = TRUE)
  expect_match(bd$detail, "qualifies 1 results? at 1 points?")
  expect_false(grepl("Zinc", bd$detail, fixed = TRUE))      # not detected in the blank
  expect_false(grepl("Q.X02", bd$detail, fixed = TRUE))     # 0.3 >= 5 x 0.05
  expect_false(grepl("Q.X03", bd$detail, fixed = TRUE))     # non-detect
  expect_false(grepl("Q.X04", bd$detail, fixed = TRUE))     # another work order
  expect_match(bd$detail, "Sep 2026 (quarterly|annual)")
  expect_match(bd$detail, "→ qualify")
})

test_that("qc_blank_detect: a blank with only non-detects gives no flag", {
  db <- qc_db()
  fl_with(db, function(con) {
    qc_add(con, "Q.JF42", "field_blank", parent = "Q.X01")
    fl_sample(con, "Q.JF42", wo, d_round, results = list(nh3(0.01, q = FALSE), qc_nd("Zinc", 0.005)))
    fl_sample(con, "Q.X01", wo, d_round, results = list(nh3(0.2)))
  })
  f <- fl_run(db, qc_checks())
  expect_length(attr(f, "errors"), 0)
  expect_equal(nrow(fl_of(f, "qc_blank_detect")), 0)
})

test_that("qc_blank_detect (R-19.7): a lab contaminant qualifies below 10 x the blank, any other analyte below 5 x", {
  build <- function(contaminant) {
    db <- qc_db()
    fl_with(db, function(con) {
      tol <- function(v) qc_lab("Toluene", v, rl = 0.001, method = "EP080: BTEXN")
      qc_add(con, "Q.JF42", "field_blank", parent = "Q.X01")
      fl_sample(con, "Q.JF42", wo, d_round, results = list(tol(0.002)))
      fl_sample(con, "Q.X01", wo, d_round, results = list(tol(0.030)))   # >= 10x: never
      fl_sample(con, "Q.X02", wo, d_round, results = list(tol(0.015)))   # 5x..10x
      if (contaminant) qc_set_contaminant(con, "Toluene")
    })
    fl_of(fl_run(db, qc_checks()), "qc_blank_detect")
  }
  lc <- build(TRUE)
  expect_equal(nrow(lc), 1)
  expect_match(lc$detail, "qualifies 1 results? at 1 points?")
  expect_match(lc$detail, "Q.X02", fixed = TRUE)
  plain <- build(FALSE)
  expect_equal(nrow(plain), 1)                      # still a detection
  expect_false(grepl("Q.X02", plain$detail, fixed = TRUE))
  expect_match(plain$detail, "qualifies 0 results? at 0 points?")
})

test_that("qc_blank_detect: a type-only blank (no parent) is reported at its own code", {
  db <- qc_db()
  fl_with(db, function(con) field_blank_round(con, code = "Q.JA00", qc_type = "source_blank",
                                              parent = NULL))
  bd <- fl_of(fl_run(db, qc_checks()), "qc_blank_detect")
  expect_equal(nrow(bd), 1)
  expect_identical(bd$feature, "Q.JA00")
  expect_identical(bd$key, blank_key("Q.JA00"))
  expect_match(bd$detail, "qualifies 1 results? at 1 points?")
})

test_that("qc_blank_detect: a rinsate blank detection says decontamination failed after its parent", {
  db <- qc_db()
  fl_with(db, function(con) field_blank_round(con, code = "Q.JR42", qc_type = "rinsate_blank"))
  bd <- fl_of(fl_run(db, qc_checks()), "qc_blank_detect")
  expect_equal(nrow(bd), 1)
  expect_identical(bd$feature, "Q.X01")
  expect_match(bd$detail, "decontamination failed for the apparatus used after Q.X01", fixed = TRUE)
})

test_that("qc_blank_detect: a filter blank qualifies only results under field-filtered methods (filtered_method_regex)", {
  db <- qc_db()
  fl_with(db, function(con) {
    filt <- "EG020F: Dissolved Metals by ICP-MS"
    tot <- "EG020T: Total Metals by ICP-MS"
    qc_add(con, "Q.JL00", "filter_blank")
    fl_sample(con, "Q.JL00", wo, d_round, results = list(
      qc_lab("Zinc", 0.01, rl = 0.005, method = filt), qc_lab("Copper", 0.002, rl = 0.001, method = tot)))
    fl_sample(con, "Q.X02", wo, d_round, results = list(
      qc_lab("Zinc", 0.02, rl = 0.005, method = filt),     # filtered, < 5x -> qualified
      qc_lab("Copper", 0.005, rl = 0.001, method = tot)))  # < 5x but total: not associated
  })
  bd <- fl_of(fl_run(db, qc_checks()), "qc_blank_detect")
  expect_equal(nrow(bd), 1)
  expect_identical(bd$feature, "Q.JL00")
  expect_match(bd$detail, "qualifies 1 results? at 1 points?")
  expect_match(bd$detail, "Q.X02 Zinc", fixed = TRUE)
  expect_false(grepl("Q.X02 Copper", bd$detail, fixed = TRUE))
})

test_that("qc_blank_detect: action resample when a qualified result also has a licence_limit flag this run", {
  db <- qc_db()
  fl_with(db, function(con) field_blank_round(con))
  lim <- fl_limits(list(site = "Q", feature_pattern = "^Q\\.X01$", analyte = "NH3-N", max = "0.1",
                        unit = "mg/L"))
  f <- fl_run(db, qc_checks(limits = lim))
  expect_identical(fl_of(f, "licence_limit")$feature, "Q.X01")
  bd <- fl_of(f, "qc_blank_detect")
  expect_equal(nrow(bd), 1)
  expect_identical(bd$action, "resample")
  expect_match(bd$detail, "→ resample", fixed = TRUE)
  tail_clause <- sub("^.*→", "", bd$detail)
  expect_match(tail_clause, "Q.X01", fixed = TRUE)
  expect_match(tail_clause, "NH3-N", fixed = TRUE)
})

test_that("qc_blank_detect: an old delivery (not recent, R1) is not assessed", {
  db <- qc_db()
  fl_with(db, function(con) {
    qc_add(con, "Q.JF42", "field_blank", parent = "Q.X01")
    old <- fl_now() - 100 * 86400
    fl_sample(con, "Q.JF42", wo, d_round, results = list(nh3(0.05)), ingested = old)
    fl_sample(con, "Q.X01", wo, d_round, results = list(nh3(0.2)), ingested = old)
  })
  f <- fl_run(db, qc_checks())
  expect_length(attr(f, "errors"), 0)
  expect_equal(nrow(fl_of(f, "qc_blank_detect")), 0)
})
