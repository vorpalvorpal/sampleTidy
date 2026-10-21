# tests/testthat/test-esdat-placeholders-guard.R
#
# 2026-10-22 ruling on fix A (ESdat placeholder Results): a "~<N" Comments
# value only rewrites the row when its Result is a PLACEHOLDER - Result equal
# to the EQL (or Result 1 when EQL is missing). A real value with a
# contradictory "~<N" comment is left exactly as the lab reported it.

guard_header <- c(
  "SampleCode", "ChemCode", "OriginalChemName", "Prefix", "Result",
  "Result_Unit", "Total_or_Filtered", "Result_Type", "Method_Type",
  "Method_Name", "Extraction_Date", "Analysed_Date", "EQL", "EQL_Units",
  "Comments", "Lab_Qualifier", "UCL", "LCL"
)

guard_parse <- function(rows, envir = parent.frame()) {
  d <- withr::local_tempdir(.local_envir = envir)
  p <- file.path(d, "PROJ_P.ESDAT_XX1234567_0.Chemistry2e.CSV")
  writeLines(c(paste(guard_header, collapse = ","), rows), p, useBytes = TRUE)
  sampleTidy:::adapter_registry()[["esdat"]]$parse(p, sampleTidy:::file_meta(p))
}

guard_row <- function(code, result, eql, comment) {
  paste0(
    code, ",Coliform,Coliforms,,", result, ",CFU/100mL,T,REG,",
    "Coliforms by Membrane Filtration,MW007: Coliforms by MF,,22-May-20,",
    eql, ",CFU/100mL,", comment, ",,,"
  )
}

test_that("a real Result with a contradictory '~<10' comment is not rewritten", {
  out <- guard_parse(guard_row("XX1234567012", "340", "1", "~<10"))
  res <- out$results
  expect_equal(nrow(res), 1)
  expect_identical(res$value_raw, "340")
  expect_equal(res$value_num, 340)
  expect_false(res$below_detection)
  expect_identical(sampleTidy:::parse_value(res$value_raw)$quantified, TRUE)
  expect_identical(res$comments, "~<10")
  expect_equal(res$rl, 1)
})

test_that("Result equal to a non-1 EQL is a placeholder and is rewritten", {
  out <- guard_parse(guard_row("XX1234567013", "2", "2", "~<10"))
  expect_identical(out$results$value_raw, "<10")
  expect_true(out$results$below_detection)
  expect_equal(out$results$rl, 2)
})

test_that("Result 1 with a missing EQL is a placeholder and is rewritten", {
  out <- guard_parse(guard_row("XX1234567014", "1", "", "~<2"))
  expect_identical(out$results$value_raw, "<2")
  expect_true(out$results$below_detection)
  expect_true(is.na(out$results$rl))
})

test_that("Result differing from the EQL (EQL missing, Result not 1) is not rewritten", {
  out <- guard_parse(guard_row("XX1234567015", "5", "", "~<2"))
  expect_identical(out$results$value_raw, "5")
  expect_false(out$results$below_detection)
})
