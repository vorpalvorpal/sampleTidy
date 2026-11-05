# Generator for `2400-9999-16_SerialZeroDate_WMF.xlsx` - a SYNTHETIC ACIRL
# quarterly workbook carrying a serial-0 `Date of Sample` cell (2026-10-19
# corpus finding; PLAN-06 "R-6.3c").
#
# The property under test: on the `Groundwater Sites` sheet the `Date of
# Sample` row holds the visit's date serial in every sample column EXCEPT the
# last (`PZ # 4`, cell K11), which holds the number 0 - Excel shows a formula
# over an empty cell as 0, and `excel_date(0)` is 1899-12-30. Real quarterly
# workbooks of this layout carry exactly that cell.
#
# The two sheets the adapter needs (`Front Page`, `Groundwater Sites`) are
# laid out in the measured real geometry (labels in column B, units in C,
# sample columns D:K, the date row directly above `Site Name`, ALS lab rows
# interleaved under heading rows, two columns with no readings). Every name,
# id, date and value is invented. Cell types follow the real files: numbers
# are numeric, below-LOR results are text (`<1`), dates are date-formatted
# serials.
#
# Re-run with:
#   Rscript tests/testthat/fixtures/corpus-2026-10-19/generate-serial-zero.R

this_file_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
here <- if (length(this_file_arg) == 1) {
  dirname(normalizePath(sub("^--file=", "", this_file_arg)))
} else {
  "tests/testthat/fixtures/corpus-2026-10-19"
}
library(openxlsx)
set.seed(20261105)

serial <- function(d) as.numeric(as.Date(d) - as.Date("1899-12-30"))
VISIT   <- serial("2025-09-17")   # 45917
MONTH   <- serial("2025-09-01")   # front-page report month
REPORT  <- "2400-9999-16"
ALS_WO  <- "ES2263318"
date_style <- createStyle(numFmt = "dd/mm/yyyy")

put <- function(wb, sh, row, col, x, date = FALSE) {
  writeData(wb, sh, x = x, startRow = row, startCol = col, colNames = FALSE, rowNames = FALSE)
  if (date) addStyle(wb, sh, date_style, rows = row, cols = col)
}

wb <- createWorkbook()

# ---- Front Page (35 x 6) ----------------------------------------------------
fp <- "Front Page"
addWorksheet(wb, fp)
put(wb, fp, 1, 1, "ALS WATER")
put(wb, fp, 2, 1, "ANALYSIS AND TESTING REPORT")
put(wb, fp, 5, 4, "REPORT TO:");  put(wb, fp, 5, 6, "A. Recipient")
put(wb, fp, 8, 4, "REPORT ON:");  put(wb, fp, 8, 6, "EXORG")
put(wb, fp, 9, 6, "SiteB WMF")
put(wb, fp, 10, 6, "Quarterly Monitoring Results")
put(wb, fp, 11, 6, MONTH, date = TRUE)
put(wb, fp, 13, 4, "REPORT NO:"); put(wb, fp, 13, 6, REPORT)
put(wb, fp, 16, 4, "SAMPLED BY:"); put(wb, fp, 16, 6, "A. Sampler & B. Sampler")
put(wb, fp, 25, 6, "A. Signatory")
# no space before the en dash, as in the real signature block
put(wb, fp, 26, 5, "Environmental Project/Quality Officer– RegionA")
put(wb, fp, 34, 1, "Accredited for compliance with ISO/IEC 17025.")
put(wb, fp, 35, 1, "This document will not be reproduced except in full.")

# ---- Groundwater Sites (36 x 11) --------------------------------------------
gw <- "Groundwater Sites"
addWorksheet(wb, gw)
put(wb, gw, 1, 1, "ALS")
put(wb, gw, 2, 1, "WATER ANALYSIS AND TESTING REPORT")
put(wb, gw, 5, 1, "EXORG")
put(wb, gw, 6, 1, "SITEB WMF")
put(wb, gw, 8, 3, "Units")
put(wb, gw, 9, 2, "REPORT NO:");            put(wb, gw, 9, 4, REPORT)
put(wb, gw, 10, 2, "ALS Sydney Report No."); put(wb, gw, 10, 4, ALS_WO)

COLS  <- 4:11                                   # D:K
SITES <- c("WELL 3", "WELL5A", "WELL6B", "WELL 9", "PZ # 1", "PZ # 2", "PZ # 3", "PZ # 4")
NOTES <- c("Cloudy", "Clear", "Cloudy", "Not located", "Cloudy", "Dry", "Clear", "Cloudy")
put(wb, gw, 11, 2, "Date of Sample")
for (k in seq_along(COLS)) {
  # K11 (the last column) is the serial-0 cell under test.
  put(wb, gw, 11, COLS[k], if (k == length(COLS)) 0 else VISIT, date = TRUE)
  put(wb, gw, 12, COLS[k], SITES[k])
  put(wb, gw, 13, COLS[k], NOTES[k])
}
put(wb, gw, 12, 2, "Site Name")
put(wb, gw, 13, 2, "General Comments/ Observations")

# Analyte rows. `pattern` gives each column D:K: n = numeric reading,
# < = below-LOR text, . = blank (columns G and I have no readings).
# `k` pins column K's value (the serial-0 column the test reads back).
rows <- list(
  list(14, "Temperature", "˚C",   "nnn.n.nn", 1, 8, 14,    k = 10.4),
  list(15, "pH", "pH Units",           "nnn.n.nn", 1, 5.5, 7.5, k = 7.1),
  list(16, "Electrical Conductivity", "µS/cm", "nnn.n.nn", 0, 60, 1700, k = 432),
  list(17, "Total Dissolved Solids", "mg/L", "nnn.n.nn", 0, 40, 1100, k = 281),
  list(18, "Water Height", "m",        "nnn...nn", 2, 0.4, 5,   k = 1.87),
  list(19, "Alkalinity by PC Titrator"),
  list(20, "Hydroxide Alkalinity as CaCO3", "mg/L", "<<<.<.<<", lor = "<1"),
  list(21, "Carbonate Alkalinity as CaCO3", "mg/L", "<<<.<.<<", lor = "<1"),
  list(22, "Bicarbonate Alkalinity as CaCO3", "mg/L", "nnn.n.nn", 0, 2, 900),
  list(23, "Total Alkalinity as CaCO3", "mg/L", "nnn.n.nn", same = 22),
  list(24, "Sulfate (Turbidimetric) as SO4 2"),
  list(25, "Sulfate as SO4 - Turbidimetric", "mg/L", "nnn.<.nn", 0, 2, 60, lor = "<1"),
  list(26, "Chloride by Discrete Analyser"),
  list(27, "Chloride", "mg/L", "nnn.n.nn", 0, 2, 60),
  list(28, "Dissolved Major Cations"),
  list(29, "Calcium", "mg/L",   "nn<.n.nn", 0, 2, 140, lor = "<1"),
  list(30, "Magnesium", "mg/L", "<n<.n.nn", 0, 2, 30, lor = "<1"),
  list(31, "Sodium", "mg/L",    "nnn.n.nn", 0, 2, 70),
  list(32, "Potassium", "mg/L", "nnn.n.nn", 0, 2, 60),
  list(33, "Ammonia as N by Discrete Analyser"),
  list(34, "Ammonia as N", "mg/L", "n<n.n.<n", 2, 0.02, 90, lor = "<0.01"),
  list(35, "Total Organic Carbon (TOC)"),
  list(36, "Total Organic Carbon", "mg/L", "nnn.n.nn", 0, 4, 70)
)
vals <- list()
for (r in rows) {
  row <- r[[1]]
  put(wb, gw, row, 2, r[[2]])
  if (length(r) < 4) next                       # heading row, no values
  put(wb, gw, row, 3, r[[3]])
  pat <- strsplit(r[[4]], "")[[1]]
  v <- if (!is.null(r$same)) vals[[as.character(r$same)]] else if (is.numeric(r[[5]]))
    round(exp(stats::runif(length(COLS), log(r[[6]]), log(r[[7]]))), r[[5]]) else
    rep(NA_real_, length(COLS))
  if (!is.null(r$k)) v[length(v)] <- r$k
  vals[[as.character(row)]] <- v
  for (k in seq_along(COLS)) {
    if (pat[k] == "n") put(wb, gw, row, COLS[k], v[k])
    if (pat[k] == "<") put(wb, gw, row, COLS[k], r$lor)
  }
}

out <- file.path(here, "2400-9999-16_SerialZeroDate_WMF.xlsx")
saveWorkbook(wb, out, overwrite = TRUE)

# Guard: the property under test survived the round-trip.
chk <- suppressMessages(readxl::read_excel(out, sheet = gw, col_names = FALSE, col_types = "text"))
stopifnot(identical(dim(chk), c(36L, 11L)),
          identical(chk[[11]][[11]], "0"), identical(chk[[10]][[11]], as.character(VISIT)),
          identical(chk[[11]][[12]], "PZ # 4"))
message("wrote ", out)
