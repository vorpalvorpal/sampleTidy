# tests/testthat/test-adapter-acirl-gas-o2co2.R
#
# TDD "red" tests: the ACIRL gas adapter reads O2 and CO2 columns to the right
# of each CH4 column. Workbooks come from helper-acirl-gas-o2co2.R; expected
# values are hard-coded against its DEFAULT content, not derived from it.
# Tests tagged (pin) pass today and must keep passing.

o2_refs <- function(out, feature) out$results$source_ref[out$results$feature_raw == feature]
o2_val <- function(out, feature, analyte) {
  out$results$value_num[out$results$feature_raw == feature & out$results$analyte_raw == analyte]
}
# review columns exist only when something is flagged
o2_col <- function(df, col) if (col %in% names(df)) df[[col]] else rep(NA, nrow(df))

O2 <- "O2 Reading % v/v"
CO2 <- "CO2 Reading % v/v"
CH4 <- "CH4 Reading % v/v"

test_that("landfill blocks with O2 + CO2: three readings per row, in CH4, O2, CO2 order", {
  out <- gas_parse(build_gas_o2co2(withr::local_tempdir()))
  expect_equal(nrow(out$results), 12)
  expect_equal(nrow(out$samples), 12)
  expect_identical(out$results$source_ref, c(
    paste0("Gas Landfil #1!", c("B", "C", "D"), 8), paste0("Gas Landfil #1!", c("B", "C", "D"), 9),
    paste0("Gas Landfil #1!", c("B", "C", "D"), 10), paste0("Gas Landfil #1!", c("F", "G", "H"), 8)))
  expect_identical(out$results$analyte_raw, rep(c(CH4, O2, CO2), 4))
  expect_true(all(out$results$units_raw == "%"))
  expect_identical(out$results$feature_raw, rep(c("N.G197", "N.G198", "N.G199", "N.G222"), each = 3))
})

test_that("landfill O2 / CO2 values are read as printed; zero is below_detection", {
  out <- gas_parse(build_gas_o2co2(withr::local_tempdir()))
  expect_equal(o2_val(out, "N.G197", O2), 20.9)
  expect_equal(o2_val(out, "N.G197", CO2), 0.5)
  expect_equal(o2_val(out, "N.G199", CO2), 1.25)
  expect_equal(o2_val(out, "N.G222", O2), 21)
  r <- out$results[out$results$feature_raw == "N.G198", ]
  expect_true(all(r$value_num == 0))
  expect_true(all(r$below_detection))
  expect_false(any(out$results$below_detection[out$results$feature_raw == "N.G197"]))
})

test_that("each gas cell has one sample row with the same source_ref and feature", {
  out <- gas_parse(build_gas_o2co2(withr::local_tempdir()))
  expect_identical(out$samples$source_ref, out$results$source_ref)
  expect_identical(out$samples$feature_raw, out$results$feature_raw)
  expect_true(all(out$samples$matrix_raw == "Gas"))
  expect_equal(length(unique(out$samples$sample_datetime_raw)), 1)
})

test_that("building block with Reference + O2 + CO2: feature shared; repeated name gets #2 once", {
  bld <- list(
    gxo_row("Toilets", "Right Side", 0, 20.5, 0.1),
    gxo_row(NA, "Left Side", 0.01, 20.9, 0.2),
    gxo_row("Storage Shed", "Right Wall", 0, 19, 1),
    gxo_row(NA, "Back Wall", 0, 20, 0.5),
    gxo_row(NA, "Right Wall", 0.02, 18.5, 2.5)
  )
  out <- gas_parse(build_gas_o2co2(withr::local_tempdir(), bld = bld))
  b <- out$results[grepl("Gas Buildings", out$results$source_ref), ]
  expect_equal(nrow(b), 15)
  tab <- table(b$feature_raw)
  expect_setequal(names(tab), c("B.Toilets - Right Side", "B.Toilets - Left Side",
                                "B.Storage Shed - Right Wall", "B.Storage Shed - Back Wall",
                                "B.Storage Shed - Right Wall #2"))
  expect_true(all(tab == 3))
  expect_identical(b$analyte_raw, rep(c(CH4, O2, CO2), 5))
  expect_identical(b$source_ref[b$feature_raw == "B.Storage Shed - Right Wall #2"],
                   paste0("Gas Buildings!", c("C", "D", "E"), 13))
  expect_equal(o2_val(out, "B.Storage Shed - Right Wall #2", O2), 18.5)
})

test_that("digit-zero headers `02 Reading` / `C02 Reading` are read as O2 / CO2", {
  ex <- c(o2 = "02 Reading % v/v", co2 = "C02 Reading % v/v")
  out <- gas_parse(build_gas_o2co2(withr::local_tempdir(), extra = ex))
  expect_equal(nrow(out$results), 12)
  expect_equal(sum(out$results$analyte_raw == O2), 4)
  expect_equal(sum(out$results$analyte_raw == CO2), 4)
  expect_equal(o2_val(out, "N.G197", O2), 20.9)
})

test_that("headers with and without units, any case, and space runs are matched", {
  variants <- list(
    c(o2 = "O2 Reading", co2 = "CO2 Reading"),
    c(o2 = "O2 Reading %v/v", co2 = "CO2 Reading %v/v"),
    c(o2 = "o2 reading % v/v", co2 = "co2 reading"),
    c(o2 = "O2 Reading               % v/v", co2 = "CO2 Reading % v/v")
  )
  for (i in seq_along(variants)) {
    out <- gas_parse(build_gas_o2co2(withr::local_tempdir(), extra = variants[[i]]))
    expect_equal(nrow(out$results), 12, info = as.character(i))
    expect_setequal(out$results$analyte_raw, c(CH4, O2, CO2))
  }
})

test_that("only an O2 column (no CO2): two readings per row", {
  ex <- c(o2 = "O2 Reading % v/v")
  l1 <- list(list(gxo_pt("G197", 0.01, 20.9), gxo_pt("G198", 0, 21)))
  out <- gas_parse(build_gas_o2co2(withr::local_tempdir(), l1 = l1, extra = ex))
  expect_equal(nrow(out$results), 4)
  expect_identical(out$results$analyte_raw, rep(c(CH4, O2), 2))
  expect_false(CO2 %in% out$results$analyte_raw)
  expect_identical(out$results$source_ref[2], "Gas Landfil #1!C8")
})

test_that("only a CO2 column (no O2): CH4 and CO2 are read", {
  ex <- c(co2 = "CO2 Reading % v/v")
  l1 <- list(list(gxo_pt("G197", 0.01, co2 = 0.5)))
  out <- gas_parse(build_gas_o2co2(withr::local_tempdir(), l1 = l1, extra = ex))
  expect_identical(out$results$analyte_raw, c(CH4, CO2))
  expect_identical(out$results$source_ref, c("Gas Landfil #1!B8", "Gas Landfil #1!C8"))
})

test_that("a row with a blank CH4 but an O2 value yields only the O2 reading", {
  l1 <- list(list(gxo_pt("G197", NA, 20.9, NA), gxo_pt("G198", 0.01, 21, 0.1)))
  out <- gas_parse(build_gas_o2co2(withr::local_tempdir(), l1 = l1))
  r <- out$results[out$results$feature_raw == "N.G197", ]
  expect_identical(r$analyte_raw, O2)
  expect_identical(r$source_ref, "Gas Landfil #1!C8")
  expect_equal(r$value_num, 20.9)
  expect_equal(nrow(out$results), 4)
  expect_identical(out$samples$source_ref, out$results$source_ref)
})

test_that("a fully blank gas row still takes its place in the #n sequence", {
  bld <- list(
    gxo_row("Storage Shed", "Right Wall"),
    gxo_row("Storage Shed", "Right Wall", 0.01, 20.9, 0.2)
  )
  out <- gas_parse(build_gas_o2co2(withr::local_tempdir(), bld = bld))
  b <- out$results[grepl("Gas Buildings", out$results$source_ref), ]
  expect_equal(nrow(b), 3)
  expect_true(all(b$feature_raw == "B.Storage Shed - Right Wall #2"))
})

test_that("text codes in O2 / CO2 cells are skipped with reasons; CH4 in the row is kept", {
  l1 <- list(list(gxo_pt("G197", 0.01, "NS", "NR"), gxo_pt("G198", 0, "No Access", "does not exist"),
                  gxo_pt("G199", 0, 21, "Not on the map")))
  out <- gas_parse(build_gas_o2co2(withr::local_tempdir(), l1 = l1))
  sk <- out$report$skipped
  expect_identical(sk$source_ref, c("Gas Landfil #1!C8", "Gas Landfil #1!D8", "Gas Landfil #1!C9",
                                    "Gas Landfil #1!D9", "Gas Landfil #1!D10"))
  expect_identical(sk$reason, c("no_sample", "not_requested", "no_access", "point_absent", "not_on_map"))
  expect_equal(nrow(out$results), 4)
  expect_identical(out$results$analyte_raw, c(CH4, CH4, CH4, O2))
  expect_equal(nrow(out$samples), 4)
})

test_that("unrecognised text in an O2 / CO2 cell warns naming the gas and the cell; CH4's wording is unchanged", {
  l1 <- list(list(gxo_pt("G197", "weird", "bogus", "odd")))
  out <- gas_parse(build_gas_o2co2(withr::local_tempdir(), l1 = l1))
  w <- out$report$warnings
  expect_equal(sum(grepl("unrecognised O2 cell text .bogus. at Gas Landfil #1!C8; skipped\\.", w)), 1)
  expect_equal(sum(grepl("unrecognised CO2 cell text .odd. at Gas Landfil #1!D8; skipped\\.", w)), 1)
  expect_equal(sum(grepl("unrecognised CH4 cell text .weird. at Gas Landfil #1!B8; skipped\\.", w)), 1)
  expect_equal(nrow(out$results), 0)
  expect_equal(sum(out$report$skipped$reason == "unrecognised_text"), 3)
})

test_that("template_slot applies to O2 / CO2 cells: N.G201 yields no results, one skip per gas cell", {
  l1 <- list(list(gxo_pt("G200", 0, 20.9, 0.1), gxo_pt("G201", 0, 5, 1), gxo_pt("G202", 0, 21, 0)))
  out <- gas_parse(build_gas_o2co2(withr::local_tempdir(), l1 = l1))
  expect_false("N.G201" %in% out$results$feature_raw)
  expect_false("N.G201" %in% out$samples$feature_raw)
  sk <- out$report$skipped
  expect_identical(sk$source_ref[sk$reason == "template_slot"],
                   paste0("Gas Landfil #1!", c("B", "C", "D"), 9))
  expect_equal(nrow(out$results), 6)
})

test_that("an O2 reading with more than 2 dp is withheld as precision_exceeded, never rounded", {
  l1 <- list(list(gxo_pt("G197", 0.01, 20.125, 0.5)))
  out <- gas_parse(build_gas_o2co2(withr::local_tempdir(), l1 = l1))
  r <- out$results[out$results$analyte_raw == O2, ]
  expect_equal(nrow(r), 1)
  expect_false(r$value_raw %in% c("20.12", "20.13"))
  expect_false(r$value_num %in% c(20.12, 20.13))
  expect_identical(o2_col(r, "review_kind"), "precision_exceeded")
  expect_true(isTRUE(o2_col(r, "review_withhold")))
  expect_identical(r$source_ref, "Gas Landfil #1!C8")
  # its neighbours are ordinary
  nb <- out$results[out$results$analyte_raw != O2, ]
  expect_true(all(is.na(o2_col(nb, "review_kind"))))
})

test_that("a CO2 reading with more than 2 dp is withheld; 2 dp values are kept as printed", {
  l1 <- list(list(gxo_pt("G197", 0.01, 20.95, 0.333)))
  out <- gas_parse(build_gas_o2co2(withr::local_tempdir(), l1 = l1))
  rk <- o2_col(out$results, "review_kind")
  expect_identical(rk[out$results$analyte_raw == CO2], "precision_exceeded")
  expect_true(is.na(rk[out$results$analyte_raw == O2]))
  expect_equal(o2_val(out, "N.G197", O2), 20.95)
})

test_that("an unrelated header (Balance) stops the scan: later CO2 and the Balance column are not read", {
  ex <- c(o2 = "O2 Reading % v/v", bal = "Balance", co2 = "CO2 Reading % v/v")
  l1 <- list(list(gxo_pt("G197", 0.01, 20.9, 0.5, bal = 78.6)))
  out <- gas_parse(build_gas_o2co2(withr::local_tempdir(), l1 = l1, extra = ex))
  expect_identical(out$results$analyte_raw, c(CH4, O2))
  expect_false(78.6 %in% out$results$value_num)
  expect_false(0.5 %in% out$results$value_num)
})

test_that("a Comments column straight after CH4 stops the scan: O2 beyond it is not read", {
  ex <- c(note = "Comments", o2 = "O2 Reading % v/v")
  l1 <- list(list(gxo_pt("G197", 0.01, o2 = 20.9, note = "ok")))
  out <- gas_parse(build_gas_o2co2(withr::local_tempdir(), l1 = l1, extra = ex))
  expect_identical(out$results$analyte_raw, CH4)
  expect_equal(nrow(out$results), 1)
  expect_equal(length(out$report$warnings[grepl("unrecognised", out$report$warnings)]), 0)
})

test_that("a repeated gas header stops the scan: each gas at most once per block", {
  ex <- c(o2 = "O2 Reading % v/v", o2b = "O2 Reading % v/v", co2 = "CO2 Reading % v/v")
  # o2b has no row field of its own; fill the cells by hand through a post-edit
  d <- withr::local_tempdir()
  l1 <- list(list(gxo_pt("G197", 0.01, 20.9, 0.5)))
  p <- build_gas_o2co2(d, l1 = l1, extra = ex)
  wb <- openxlsx::loadWorkbook(p)
  gx_set(wb, "Gas Landfil #1", 8, 4, 33)      # under the repeated O2 header
  gx_set(wb, "Gas Landfil #1", 8, 5, 44)      # under CO2, beyond the repeat
  openxlsx::saveWorkbook(wb, p, overwrite = TRUE)
  out <- gas_parse(p)
  expect_identical(out$results$analyte_raw, c(CH4, O2))
  expect_false(any(c(33, 44) %in% out$results$value_num))
})

test_that("(pin) a header with O2 / CO2 but no CH4 header is not detected as a gas workbook", {
  p <- build_gas_o2co2(withr::local_tempdir(), ch4_header = "Methane % v/v")
  expect_identical(gas_adapter()$match(sampleTidy:::file_meta(p)), "no")
})

test_that("(pin) existing landfill pairs (Location | CH4 | Location | CH4) are unchanged", {
  ex <- character(0)
  l1 <- list(list(gxo_pt("G197", 0.01), gxo_pt("G198", 0)), list(gxo_pt("G222", 0.02)))
  out <- gas_parse(build_gas_o2co2(withr::local_tempdir(), l1 = l1, extra = ex))
  expect_equal(nrow(out$results), 3)
  expect_true(all(out$results$analyte_raw == CH4))
  expect_identical(out$results$source_ref,
                   c("Gas Landfil #1!B8", "Gas Landfil #1!B9", "Gas Landfil #1!D8"))
})

test_that("(pin) CH4-only workbooks from the existing builders: fixed counts, all CH4", {
  d <- withr::local_tempdir()
  cases <- list(
    b2025 = list(path = build_gas_northvale_2025(d), n = 45),
    b2024 = list(path = build_gas_northvale_2024(d), n = 31),
    kat   = list(path = build_gas_millbrook(d), n = 50)
  )
  for (nm in names(cases)) {
    out <- gas_parse(cases[[nm]]$path)
    expect_equal(nrow(out$results), cases[[nm]]$n, info = nm)
    expect_equal(nrow(out$samples), cases[[nm]]$n, info = nm)
    expect_true(all(out$results$analyte_raw == CH4), info = nm)
    expect_true(all(out$results$units_raw == "%"), info = nm)
  }
})
