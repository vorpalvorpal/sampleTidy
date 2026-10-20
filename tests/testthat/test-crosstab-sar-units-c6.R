# tests/testthat/test-crosstab-sar-units-c6.R
#
# C6: Sodium Adsorption Ratio is dimensionless. An ALS crosstab result row for
# it whose Units cell is blank gets unit "1" (what live already carries for
# SAR) instead of NA, so reconcile no longer raises `units_missing` for it.
# Any OTHER analyte with a blank Units cell is unchanged (units_raw stays NA).

xtab_adapter_c6 <- function() sampleTidy:::adapter_registry()[["als_xtab"]]

# Write a one-section WATER crosstab with the given (analyte, unit) rows and
# parse it. `units` NA -> blank cell.
c6_parse <- function(analytes, units, dir = withr::local_tempdir(.local_envir = parent.frame())) {
  stopifnot(length(analytes) == length(units))
  path <- file.path(dir, "XX1234567_0_XTAB.csv")
  rows <- c(
    "Matrix:,WATER,,Sample Type:,,REG,REG",
    "Workgroup:,XX1234567,,ALS Sample Number:,,XX1234567001,XX1234567002",
    "Project name/number:,Test Project A / XX1234567,,Sample Date:,,24/05/2025,24/05/2025",
    ",,,Client sample ID (1st):,,T.S01,T.S02",
    ",,,Site:,,Site A,Site A",
    ",,,,,,",
    "Analyte grouping/Analyte,CAS Number,Unit,Limit of reporting,,,",
    ",,,,,,",
    "EA005P: Some method,,,,,,",
    sprintf("%s,,%s,0.01,,1.5,2.5", analytes, ifelse(is.na(units), "", units))
  )
  writeLines(rows, path)
  meta <- sampleTidy:::file_meta(path)
  xtab_adapter_c6()$parse(path, meta)$results
}

test_that("C6: blank Units on Sodium Adsorption Ratio becomes unit '1'", {
  res <- c6_parse("Sodium Adsorption Ratio", NA)
  expect_equal(nrow(res), 2)
  expect_true(all(res$units_raw == "1"))
})

test_that("C6: whitespace-only Units and case/padding variants of the name also give '1'", {
  res <- c6_parse(c("Sodium Adsorption Ratio", "SODIUM ADSORPTION RATIO"), c("   ", ""))
  expect_equal(nrow(res), 4)
  expect_true(all(res$units_raw == "1"))

  res2 <- c6_parse("  sodium adsorption ratio ", NA)
  expect_equal(nrow(res2), 2)
  expect_true(all(res2$units_raw == "1"))
})

test_that("C6: a non-blank Units cell for SAR is left as given", {
  res <- c6_parse("Sodium Adsorption Ratio", "meq/L")
  expect_true(all(res$units_raw == "meq/L"))
})

test_that("C6: a blank Units cell for any other analyte is NOT given '1'", {
  res <- c6_parse(c("pH Value", "Sodium"), c(NA, NA))
  expect_equal(nrow(res), 4)
  expect_true(all(is.na(res$units_raw)))
})

test_that("C6: SAR fix does not disturb other analytes alongside it", {
  res <- c6_parse(c("Sodium Adsorption Ratio", "Fluoride"), c(NA, "mg/L"))
  expect_true(all(res$units_raw[res$analyte_raw == "Sodium Adsorption Ratio"] == "1"))
  expect_true(all(res$units_raw[res$analyte_raw == "Fluoride"] == "mg/L"))
})
