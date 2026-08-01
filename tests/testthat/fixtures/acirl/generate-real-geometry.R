# Deterministic generator for the REAL-GEOMETRY ACIRL fixtures (PLAN-06 R-6.3a).
#
# Re-run with:
#   Rscript tests/testthat/fixtures/acirl/generate-real-geometry.R
#
# WHY THIS FILE EXISTS. The original fixtures (generate.R) were built from
# PLAN-06's prose description of the water-sheet layout, never measured from a
# real workbook. The result: the adapter passed 100% of its tests while
# extracting ZERO rows from all 147 real ACIRL workbooks. Every structural
# property below was measured from the real corpus (213 workbooks / 986 water
# sheets / 50 dust-results sheets) and each carries its provenance. See
# README-real-geometry.md.
#
# MEASURED GEOMETRY (counts are out of the 640 real water sheets that have a
# "Site Name" row; all four rules held on every one of them):
#
#   units_col        == site_col + 1                      640/640
#   first_feature_col== units_col + 1  (= site_col + 2)    640/640
#   date-label col   == site_col                          640/640
#   date_row         == site_row - 1   (ABOVE the site row) 640/640
#   units_row        == site_row - 4 (593) or -3 (47)   <- marker floats
#   ALS-ref row      == site_row - 3 (442) or -2 (198), label in site_col
#
# The old fixtures put the `Units` marker ON the `Site Name` row and the field
# labels in column 1; neither shape occurs anywhere in the real corpus.

this_file_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
here <- if (length(this_file_arg) == 1) {
  dirname(normalizePath(sub("^--file=", "", this_file_arg)))
} else {
  "tests/testthat/fixtures/acirl"
}

if (!requireNamespace("openxlsx", quietly = TRUE)) {
  stop("openxlsx is required to generate the ACIRL xlsx fixtures")
}
library(openxlsx)

# ---- pinned serial facts ([MEASURE TWICE], PLAN-02 R-2.4) -------------------
serial <- function(d) as.numeric(as.Date(d) - as.Date("1899-12-30"))
stopifnot(serial("2025-05-25") == 45802)
stopifnot(serial("2024-03-01") == 45352)   # the "Mar-24" exposure month of
                                           # 2400-7399-04, verified against its
                                           # sibling PDF

SITE_COL   <- 2L   # dominant real value (510 of 640); 1 and 3 also occur
UNITS_COL  <- SITE_COL + 1L
FEAT_COL   <- UNITS_COL + 1L
SITE_ROW   <- 10L
DATE_ROW   <- SITE_ROW - 1L
ALS_ROW    <- SITE_ROW - 3L
REPORT_ROW <- SITE_ROW - 2L
UNITS_ROW  <- SITE_ROW - 4L

set_cell <- function(wb, sheet, row, col, value) {
  if (length(value) == 0 || (length(value) == 1 && is.na(value))) return(invisible(NULL))
  writeData(wb, sheet, x = value, startRow = row, startCol = col,
            colNames = FALSE, rowNames = FALSE)
}
write_row <- function(wb, sheet, row, start_col, values) {
  for (i in seq_along(values)) set_cell(wb, sheet, row, start_col + i - 1L, values[[i]])
}

# ---- water sheet, real geometry --------------------------------------------
# `rows` is an ordered list of list(label=, units=, vals=) written from the row
# after Site Name downwards. A NULL/NA `vals` writes a heading row: label only,
# no values in any sample column (real examples: "Dissolved Major Cations").
build_water_sheet <- function(wb, sheet, features, dates, rows,
                              als_ref = "ES9999001", report_no = "2400-9999-01",
                              units_marker = "Units", shadow_ref = NA) {
  addWorksheet(wb, sheet)
  n <- length(features)

  set_cell(wb, sheet, 1, 1, "ALS COAL DIVISION")
  set_cell(wb, sheet, 2, 1, "BMCC TEST WASTE MANAGEMENT FACILITY")
  set_cell(wb, sheet, 3, 1, "MONTHLY ANALYSIS AND TESTING REPORT")

  # The `Units` marker sits on its OWN row, above the block - this is the
  # match() fingerprint (R-6.1) and is NOT the header row.
  if (!is.na(units_marker)) set_cell(wb, sheet, UNITS_ROW, UNITS_COL, units_marker)

  # A SECOND `ALS ... Report No` row, immediately above the Sydney one and
  # holding a value that is NOT an `ES#######`. Measured from `2400-7223-12-01
  # 2022 December Quarterly Katoomba WMF.xls`, whose water sheets carry
  # `ALS Lithogw Report No | 2400-7223-12-01` directly above
  # `ALS Sydney Report No. | ES2246297`. An extractor that stops at the first
  # matching label reads the Lithgow row, finds no work order, and reports the
  # file as citing nothing - which under the A74 gate quarantines 57 real rows.
  if (!is.na(shadow_ref)) {
    set_cell(wb, sheet, ALS_ROW - 1L, SITE_COL, "ALS Lithogw Report No")
    set_cell(wb, sheet, ALS_ROW - 1L, FEAT_COL, shadow_ref)
  }
  set_cell(wb, sheet, ALS_ROW, SITE_COL, "ALS Sydney Report No.")
  if (!is.na(als_ref)) set_cell(wb, sheet, ALS_ROW, FEAT_COL, als_ref)
  set_cell(wb, sheet, REPORT_ROW, SITE_COL, "REPORT NO:")
  set_cell(wb, sheet, REPORT_ROW, FEAT_COL, report_no)

  # Date row sits ABOVE the Site Name row.
  set_cell(wb, sheet, DATE_ROW, SITE_COL, "Date of Sample")
  write_row(wb, sheet, DATE_ROW, FEAT_COL, dates)

  set_cell(wb, sheet, SITE_ROW, SITE_COL, "Site Name")
  write_row(wb, sheet, SITE_ROW, FEAT_COL, features)

  r <- SITE_ROW + 1L
  for (spec in rows) {
    set_cell(wb, sheet, r, SITE_COL, spec$label)
    if (!is.null(spec$units) && !is.na(spec$units)) {
      set_cell(wb, sheet, r, UNITS_COL, spec$units)
    }
    if (!is.null(spec$vals)) {
      stopifnot(length(spec$vals) == n)
      write_row(wb, sheet, r, FEAT_COL, spec$vals)
    }
    r <- r + 1L
  }
  invisible(r)
}

# ---- dust sheets, real geometry --------------------------------------------
# Measured from all 50 real dust-results sheets. Two quirks are deliberate:
#  * INCOMBUSTIBLE MATTER's header is in col 12 but its VALUES land in col 13
#    (merged-cell artifact; the legacy reader used coalesce(last, last-1));
#  * quarterly sheets repeat the month-block: 2 gauge rows + one "Exposure
#    Days" row per month.
build_dust_results <- function(wb, sheet, report_no, blocks) {
  addWorksheet(wb, sheet)
  set_cell(wb, sheet, 1, 1, "ALS COAL DIVISION")
  set_cell(wb, sheet, 2, 1, "BMCC TEST WASTE MANAGEMENT FACILITY")
  set_cell(wb, sheet, 3, 1, "QUARTERLY ANALYSIS AND TESTING REPORT")
  set_cell(wb, sheet, 5, 6, "Report No.")
  set_cell(wb, sheet, 5, 7, report_no)
  set_cell(wb, sheet, 7, 4, "DUST DEPOSITION RESULTS")
  set_cell(wb, sheet, 8, 1, "(g/m²/month)")

  set_cell(wb, sheet, 10, 1,  "GAUGE NO.")
  set_cell(wb, sheet, 10, 3,  "Other Sample Id")
  set_cell(wb, sheet, 10, 4,  "Month")
  set_cell(wb, sheet, 10, 6,  "INSOLUBLE SOLIDS")
  set_cell(wb, sheet, 10, 9,  "*COMBUSTIBLE MATTER")
  set_cell(wb, sheet, 10, 12, "INCOMBUSTIBLE MATTER")

  r <- 11L
  for (b in blocks) {
    for (g in b$gauges) {
      set_cell(wb, sheet, r, 1, g$gauge)
      set_cell(wb, sheet, r, 3, g$other_id)
      set_cell(wb, sheet, r, 4, b$month_serial)
      set_cell(wb, sheet, r, 6, g$insoluble)
      set_cell(wb, sheet, r, 9, g$combustible)
      set_cell(wb, sheet, r, 13, g$incombustible)  # col 13, NOT 12 - see above
      r <- r + 1L
    }
    set_cell(wb, sheet, r, 4, "Exposure Days")
    set_cell(wb, sheet, r, 6, b$exposure_days)
    r <- r + 1L
  }
  r <- r + 1L
  set_cell(wb, sheet, r, 1, "* Result Calculated");                r <- r + 1L
  set_cell(wb, sheet, r, 1, "NS - No Sample");                     r <- r + 1L
  set_cell(wb, sheet, r, 1, "Analysed in accordance with AS3580.10.1")
  invisible(NULL)
}

build_dust_observations <- function(wb, sheet, report_no, blocks) {
  addWorksheet(wb, sheet)
  set_cell(wb, sheet, 1, 1, "ALS COAL DIVISION")
  set_cell(wb, sheet, 2, 1, "BMCC TEST WASTE MANAGEMENT FACILITY")
  set_cell(wb, sheet, 3, 1, "QUARTERLY ANALYSIS AND TESTING REPORT")
  set_cell(wb, sheet, 5, 5, "Report No.")
  set_cell(wb, sheet, 5, 7, report_no)
  set_cell(wb, sheet, 9, 1, "DEPOSITIONAL DUST GAUGE OBSERVATIONS")
  set_cell(wb, sheet, 11, 3, "GAUGE")
  set_cell(wb, sheet, 11, 4, "EXPOSURE DATE")
  set_cell(wb, sheet, 11, 5, "COLLECTION DATE")
  set_cell(wb, sheet, 11, 6, "DAYS EXPOSED")
  set_cell(wb, sheet, 11, 7, "ANALYSIS OBSERVATIONS")
  r <- 12L
  for (b in blocks) {
    for (g in b$gauges) {
      set_cell(wb, sheet, r, 3, g$gauge)
      set_cell(wb, sheet, r, 4, b$exposure_serial)
      set_cell(wb, sheet, r, 5, b$collection_serial)
      set_cell(wb, sheet, r, 6, b$exposure_days)
      set_cell(wb, sheet, r, 7, g$observation)
      r <- r + 1L
    }
  }
  set_cell(wb, sheet, r + 1L, 2, "Analysed in accordance with AS3580.10.1")
  invisible(NULL)
}

add_stub_sheet <- function(wb, sheet, title) {
  addWorksheet(wb, sheet)
  set_cell(wb, sheet, 1, 1, title)
  set_cell(wb, sheet, 3, 1, "Method")
  set_cell(wb, sheet, 3, 2, "Reference")
  set_cell(wb, sheet, 4, 1, "AS3580.10.1")
  set_cell(wb, sheet, 4, 2, "Depositional dust")
}

add_front_page <- function(wb, report_no, sampled_by = "J. Tester",
                           sample_date = "24/05/2025") {
  addWorksheet(wb, "Front Page")
  set_cell(wb, "Front Page", 1, 1, "ALS COAL DIVISION")
  set_cell(wb, "Front Page", 2, 1, "BMCC TEST WASTE MANAGEMENT FACILITY")
  # values sit one cell to the RIGHT of their key (vector_from_key "right")
  set_cell(wb, "Front Page", 6, 2, "REPORT NO:");   set_cell(wb, "Front Page", 6, 3, report_no)
  set_cell(wb, "Front Page", 7, 2, "SAMPLED BY:");  set_cell(wb, "Front Page", 7, 3, sampled_by)
  set_cell(wb, "Front Page", 8, 2, "SAMPLE DATE:"); set_cell(wb, "Front Page", 8, 3, sample_date)
}

# ===========================================================================
# 1. Main workbook - real geometry, water + quarterly dust
# ===========================================================================
D1 <- serial("2025-05-24"); D2 <- serial("2025-05-25")
FEATURES <- c("T.S01", "T.S02", "T.S01", "T.S02")
DATES    <- c(D1, D1, D2, D2)   # real files repeat the date in every column

# ALS-copy rows carry values that a companion ALS fixture must reproduce
# EXACTLY, so PLAN-07/08 can exercise A75's value test. Field rows deliberately
# differ from their ALS twin, reproducing the real field-vs-lab pH split.
ALS_PH   <- c(6.42, 6.61, 6.75, 5.94)
ALS_EC25 <- c(1360, 805, 698, 117)
FIELD_PH <- c(5.90, 6.10, 6.60, 6.40)
FIELD_EC <- c(1265, 398, 400, 195)

main_rows <- list(
  list(label = "Other Sample Id", vals = c("BORE 1", "BORE 2", "BORE 1", "BORE 2")),
  list(label = "Observations / Comments",
       vals = c("Cloudy", "Clear", "Slightly cloudy", "Clear")),
  list(label = "Temperature", units = "oC", vals = c(21, 19.9, 18.9, 17.1)),
  list(label = "pH", units = "pH Units", vals = FIELD_PH),
  list(label = "pH Value", units = "pH Units", vals = ALS_PH),
  list(label = "Electrical Conductivity", units = "µS/cm", vals = FIELD_EC),
  list(label = "Electrical Conductivity @ 25°C", units = "µS/cm", vals = ALS_EC25),
  # field-estimated TSS (A76); "----" = not analysed, must not parse as a value
  list(label = "Total Suspended Solids", units = "mg/L", vals = c("----", "----", 6, "<5")),
  list(label = "Standing Water Level", units = "m", vals = c(5.41, 3.11, NA, 2.92)),
  list(label = "Flow Observation / Appearance",
       vals = c("Low flow Clear", "Pooled Cloudy", "Mod level Clear", "Low flow Clear")),
  # heading: label only, NO values in any sample column -> dropped silently
  list(label = "Dissolved Major Cations", vals = NULL),
  list(label = "Fluoride", units = "mg/L", vals = c(0.4, 0.6, 0.5, 0.7)),
  list(label = "Sulphate", units = "mg/L", vals = c(24, 31, 26, 33)),
  list(label = "Total Dissolved Solids", units = "mg/L", vals = c(310, 405, 320, 415)),
  list(label = "Alkalinity", units = "mg/L", vals = c(140, 165, 145, 170))
)

DUST_BLOCKS <- list(
  list(month_serial = serial("2025-03-01"), exposure_serial = serial("2025-03-01"),
       collection_serial = serial("2025-04-01"), exposure_days = 31,
       gauges = list(
         list(gauge = "T.D01", other_id = "DG #1", insoluble = 2.6,
              combustible = 0.8, incombustible = 1.8,
              observation = "Slightly cloudy, insects, organic matter."),
         list(gauge = "T.D02", other_id = "DG #2", insoluble = 0.6,
              combustible = 0.4, incombustible = 0.2,
              observation = "Clear, insects, organic matter."))),
  list(month_serial = serial("2025-04-01"), exposure_serial = serial("2025-04-01"),
       collection_serial = serial("2025-05-01"), exposure_days = 30,
       gauges = list(
         list(gauge = "T.D01", other_id = "DG #1", insoluble = 0.33,
              combustible = "<0.1", incombustible = 0.3,   # below-detection
              observation = "Clear, organic matter."),
         list(gauge = "T.D02", other_id = "DG #2", insoluble = 0.16,
              combustible = "<0.1", incombustible = 0.2,
              observation = "Clear, bird droppings."))),
  list(month_serial = serial("2025-05-01"), exposure_serial = serial("2025-05-01"),
       collection_serial = serial("2025-06-01"), exposure_days = 31,
       gauges = list(
         list(gauge = "T.D01", other_id = "DG #1", insoluble = 0.41,
              combustible = "<0.1", incombustible = 0.4,
              observation = "Cloudy, fine brown dust."),
         list(gauge = "T.D02", other_id = "DG #2", insoluble = 3.48,
              combustible = 0.38, incombustible = 3.1,
              observation = "Clear, coarse black dust.")))
)

wb <- createWorkbook()
add_front_page(wb, "2400-9999-01")
build_water_sheet(wb, "Sampling Sites 1", FEATURES, DATES, main_rows)
# second water sheet: same shape, mojibake EC units variant, one empty cell
rows2 <- main_rows
rows2[[6]]$units <- "�S/cm"                      # cp1252-style mojibake
rows2[[3]]$vals  <- c(20.5, NA, 18.0, 16.6)           # genuinely empty cell
build_water_sheet(wb, "Sampling Sites 2", FEATURES, DATES, rows2)
build_dust_results(wb, "Dust Results", "2400-9999-01", DUST_BLOCKS)
build_dust_observations(wb, "Dust Observations", "2400-9999-01", DUST_BLOCKS)
add_stub_sheet(wb, "Dust Methodology ", "DUST METHODOLOGY")
add_stub_sheet(wb, "Water Methodology", "WATER METHODOLOGY")
saveWorkbook(wb, file.path(here, "2400-9999-11_Real_WMF.xlsx"), overwrite = TRUE)

# ===========================================================================
# 2. Dust-only workbook - NO water sheet at all. Must never be ALS-gated
#    (A73/A74). 6 such workbooks exist in the real corpus.
# ===========================================================================
wb <- createWorkbook()
add_front_page(wb, "2400-9999-12")
build_dust_results(wb, "Dust Results", "2400-9999-12", DUST_BLOCKS[1])
build_dust_observations(wb, "Dust Observations", "2400-9999-12", DUST_BLOCKS[1])
add_stub_sheet(wb, "Dust Methodology ", "DUST METHODOLOGY")
saveWorkbook(wb, file.path(here, "2400-9999-12_DustOnly_WMF.xlsx"), overwrite = TRUE)

# ===========================================================================
# 3. ALS-reference edge cases (A74). Real forms, all observed in the corpus.
# ===========================================================================
wb <- createWorkbook()
add_front_page(wb, "2400-9999-13")
# two work orders cited - BOTH must be held for the gate to pass. The sheet
# also carries a SHADOWING `ALS Lithogw Report No` row above the Sydney one, so
# a first-match-wins extractor reports this sheet as citing nothing.
build_water_sheet(wb, "Sampling Sites 1", FEATURES, DATES, main_rows,
                  als_ref = "ES9999001/ES9999002", report_no = "2400-9999-13",
                  shadow_ref = "2400-9999-13")
# bare "ES" - unparseable, must quarantine rather than silently pass
build_water_sheet(wb, "Sampling Sites 2", FEATURES, DATES, main_rows,
                  als_ref = "ES", report_no = "2400-9999-13")
# an ACIRL report number pasted into the ALS field
build_water_sheet(wb, "Sampling Sites 3", FEATURES, DATES, main_rows,
                  als_ref = "2400-9999-13", report_no = "2400-9999-13")
# blank ALS cell (row present, no value)
build_water_sheet(wb, "Sampling Sites 4", FEATURES, DATES, main_rows,
                  als_ref = NA, report_no = "2400-9999-13")
saveWorkbook(wb, file.path(here, "2400-9999-13_AlsRefs_WMF.xlsx"), overwrite = TRUE)

# ===========================================================================
# 3b. Water sheets that cite NOTHING (A74, R-9.13). Modelled on
#     `2400-7483-01 May 2025 Lawson Landfill.xls`, whose eight water sheets
#     each carry `ALS Sydney Report No. | ES` - the number was never filled
#     in. It is the ONE real workbook that separates "gate on no citation"
#     from "exempt on no citation": it has real water data (30 rows) and no
#     traceable ALS source, so it must be quarantined, not waved through as
#     if it were dust-only.
# ===========================================================================
wb <- createWorkbook()
add_front_page(wb, "2400-9999-15")
build_water_sheet(wb, "Sampling Sites 1", FEATURES, DATES, main_rows,
                  als_ref = "ES", report_no = "2400-9999-15")
build_water_sheet(wb, "Sampling Sites 2", FEATURES, DATES, main_rows,
                  als_ref = "ES", report_no = "2400-9999-15")
add_stub_sheet(wb, "Water Methodology", "WATER METHODOLOGY")
saveWorkbook(wb, file.path(here, "2400-9999-15_Uncited_WMF.xlsx"), overwrite = TRUE)

# ===========================================================================
# 4. Dust exposure-date conflict (A77): Results$Month holds the COLLECTION
#    date while Observations$EXPOSURE DATE holds the true exposure start.
#    Reproduces 2400-7453-06; must raise review, not auto-resolve.
# ===========================================================================
conflict <- DUST_BLOCKS[1]
conflict[[1]]$month_serial <- conflict[[1]]$collection_serial  # the error
wb <- createWorkbook()
add_front_page(wb, "2400-9999-14")
build_dust_results(wb, "Dust Results", "2400-9999-14", conflict)
build_dust_observations(wb, "Dust Observations", "2400-9999-14", conflict)
saveWorkbook(wb, file.path(here, "2400-9999-14_DustDateConflict_WMF.xlsx"), overwrite = TRUE)

cat("wrote real-geometry ACIRL fixtures to ", here, "\n", sep = "")
