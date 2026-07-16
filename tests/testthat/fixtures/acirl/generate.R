# Deterministic generator for tests/testthat/fixtures/acirl/*
#
# Reproduces the ACIRL monthly-workbook fixtures pinned in
# dev/plans/FIXTURES.md and dev/plans/PLAN-06-adapter-acirl-field.md, plus
# auxiliary fixtures needed to cover every R-6.x criterion (documented in
# README.md and dev/plans/PLAN-CHANGE-REQUESTS.md). Re-run with:
#   Rscript tests/testthat/fixtures/acirl/generate.R
#
# Water-sheet layout (transposed field block; rows = parameters, columns =
# samples, matching the old reader's raw shape before pivoting):
#   row "Site Name": colA="Site Name", colB="Units" (the match() marker
#     cell), colC.. = feature names, one column per (feature, visit).
#   row "Date":      colA="Date", colB=NA, colC.. = Excel serial dates,
#     filled across repeated columns per visit ("date fill-down").
#   row "pH"/"EC"/"Temperature": colA=label, colB=units, colC.. = values.
#   row "Comments":  colA="Comments", colB=NA, colC.. = free text
#     (attaches to ir_samples$comments, not a result row).
#   block terminator = the "Comments" row (last row matching the plan's
#     terminator regex); below it sit 4 fake ALS analyte rows per sheet
#     that must be dropped (`lab_data_dropped`) by the adapter.

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

EXCEL_SERIAL_24MAY2025 <- as.numeric(as.Date("2025-05-24") - as.Date("1899-12-30"))
EXCEL_SERIAL_25MAY2025 <- as.numeric(as.Date("2025-05-25") - as.Date("1899-12-30"))
stopifnot(EXCEL_SERIAL_25MAY2025 == 45802)  # pinned fact, PLAN-02 R-2.4 [MEASURE TWICE]

set_cell <- function(wb, sheet, row, col, value) {
  if (length(value) == 0 || is.na(value)) return(invisible(NULL))
  writeData(wb, sheet, x = value, startRow = row, startCol = col,
            colNames = FALSE, rowNames = FALSE)
}

write_row <- function(wb, sheet, row, start_col, values) {
  for (i in seq_along(values)) {
    set_cell(wb, sheet, row, start_col + i - 1, values[[i]])
  }
}

# One water-sheet builder, reused for the pinned fixture and edge cases.
build_water_sheet <- function(wb, sheet, feature_cols, dates, units_marker = "Units",
                               ph_units = "pH Units", ec_units = "µS/cm",
                               temp_units = "oC", ph_vals, ec_vals, temp_vals,
                               comment_vals, filler_rows = 0,
                               fake_als_rows = list(
                                 list(label = "Fluoride", vals = c(0.4, 0.6, 0.5, 0.7)),
                                 list(label = "Sulphate", vals = c(24, 31, 26, 33)),
                                 list(label = "Total Dissolved Solids", vals = c(310, 405, 320, 415)),
                                 list(label = "Alkalinity", vals = c(140, 165, 145, 170))
                               )) {
  addWorksheet(wb, sheet)
  n <- length(feature_cols)
  stopifnot(length(dates) == n, length(ph_vals) == n, length(ec_vals) == n,
            length(temp_vals) == n, length(comment_vals) == n)

  row <- 1L
  set_cell(wb, sheet, row, 1, "Site Name")
  if (!is.na(units_marker)) set_cell(wb, sheet, row, 2, units_marker)
  write_row(wb, sheet, row, 3, feature_cols)
  row <- row + 1L

  set_cell(wb, sheet, row, 1, "Date")
  write_row(wb, sheet, row, 3, dates)
  row <- row + 1L

  if (filler_rows > 0) {
    for (i in seq_len(filler_rows)) {
      set_cell(wb, sheet, row, 1, paste0("Note ", i))
      row <- row + 1L
    }
  }

  set_cell(wb, sheet, row, 1, "pH")
  set_cell(wb, sheet, row, 2, ph_units)
  write_row(wb, sheet, row, 3, ph_vals)
  row <- row + 1L

  set_cell(wb, sheet, row, 1, "EC")
  set_cell(wb, sheet, row, 2, ec_units)
  write_row(wb, sheet, row, 3, ec_vals)
  row <- row + 1L

  set_cell(wb, sheet, row, 1, "Temperature")
  set_cell(wb, sheet, row, 2, temp_units)
  write_row(wb, sheet, row, 3, temp_vals)
  row <- row + 1L

  set_cell(wb, sheet, row, 1, "Comments")
  write_row(wb, sheet, row, 3, comment_vals)
  row <- row + 1L  # <- this is the block terminator row

  for (fake in fake_als_rows) {
    set_cell(wb, sheet, row, 1, fake$label)
    set_cell(wb, sheet, row, 2, "mg/L")
    write_row(wb, sheet, row, 3, fake$vals)
    row <- row + 1L
  }
  invisible(row)
}

build_front_sheet <- function(wb, sheet, report_no = "2400-9999-01",
                               sampled_by = "J. Tester & offsider",
                               sample_date = "24/05/2025") {
  addWorksheet(wb, sheet)
  set_cell(wb, sheet, 1, 1, "ACIRL Monthly Water Field Report")
  if (!is.na(report_no)) {
    set_cell(wb, sheet, 3, 1, "REPORT NO:")
    set_cell(wb, sheet, 3, 2, report_no)
  }
  set_cell(wb, sheet, 4, 1, "SAMPLED BY:")
  set_cell(wb, sheet, 4, 2, sampled_by)
  set_cell(wb, sheet, 5, 1, "SAMPLE DATE:")
  set_cell(wb, sheet, 5, 2, sample_date)
  invisible(NULL)
}

# =============================================================================
# 2400-9999-01_Test_WMF.xlsx  -- THE pinned fixture (FIXTURES.md).
# Front / Methods / Dust / two water sheets, exactly as pinned.
# =============================================================================
wb <- createWorkbook()

build_front_sheet(wb, "Front Page")

addWorksheet(wb, "Methods")
set_cell(wb, "Methods", 1, 1, "Method Code")
set_cell(wb, "Methods", 1, 2, "Description")
set_cell(wb, "Methods", 2, 1, "EA005P")
set_cell(wb, "Methods", 2, 2, "pH by PC Titrator")

addWorksheet(wb, "Dust Sheet")
set_cell(wb, "Dust Sheet", 1, 1, "Dust Monitoring")
set_cell(wb, "Dust Sheet", 2, 1, "Location")
set_cell(wb, "Dust Sheet", 2, 2, "PM10 (ug/m3)")
set_cell(wb, "Dust Sheet", 3, 1, "Site A")
set_cell(wb, "Dust Sheet", 3, 2, 12.4)

feature_cols <- c("T.S01", "T.S02", "T.S01", "T.S02")
dates <- c(EXCEL_SERIAL_24MAY2025, EXCEL_SERIAL_24MAY2025,
           EXCEL_SERIAL_25MAY2025, EXCEL_SERIAL_25MAY2025)

build_water_sheet(
  wb, "Field Data 1", feature_cols, dates,
  ec_units = "µS/cm",
  ph_vals = c(7.10, 7.25, 7.05, 7.30),
  ec_vals = c(450, 610, 470, 630),
  temp_vals = c(18.5, 19.0, 17.8, NA),          # NA -> the "empty" skip branch
  comment_vals = c("Clear", NA, "Slight turbidity", NA)
)

build_water_sheet(
  wb, "Field Data 2", feature_cols, dates,
  ec_units = "�S/cm",                       # mojibake variant (cp1252-style)
  ph_vals = c(7.40, 7.55, 7.35, 7.60),
  ec_vals = c(500, 650, 520, 670),
  temp_vals = c(20.1, 20.6, 19.9, 21.0),
  comment_vals = c(NA, "Odour noted", NA, "Duplicate sample")
)

saveWorkbook(wb, file.path(here, "2400-9999-01_Test_WMF.xlsx"), overwrite = TRUE)

# =============================================================================
# EDGECASES.xlsx -- auxiliary fixture covering R-6.3 branches not present in
# the pinned workbook: a >20-row field block (sanity-check warning, still
# parses) and a water sheet with no "Units" marker (skipped, per-sheet
# warning, sibling sheets still parse). Noted as an addition in README.md /
# PLAN-CHANGE-REQUESTS.md since FIXTURES.md only pins the two-water-sheet
# core file.
# =============================================================================
wb2 <- createWorkbook()
build_front_sheet(wb2, "Front Page")

build_water_sheet(
  wb2, "Field Data Big", feature_cols, dates,
  ph_vals = c(7.00, 7.10, 7.05, 7.15),
  ec_vals = c(400, 420, 410, 430),
  temp_vals = c(18.0, 18.2, 18.1, 18.3),
  comment_vals = c(NA, NA, NA, NA),
  filler_rows = 18   # Site Name + Date + 18 filler + pH/EC/Temp/Comments = 24 rows > 20
)

build_water_sheet(
  wb2, "Field Data NoUnits", feature_cols[1:2], dates[1:2],
  units_marker = NA,                              # <- no "Units" marker anywhere
  ph_vals = c(7.20, 7.35),
  ec_vals = c(440, 615),
  temp_vals = c(18.6, 19.1),
  comment_vals = c(NA, NA)
)

saveWorkbook(wb2, file.path(here, "EDGECASES.xlsx"), overwrite = TRUE)

# =============================================================================
# NO_REPORT_NO.xlsx -- front page missing "REPORT NO:" (R-6.2 negative case)
# =============================================================================
wb3 <- createWorkbook()
build_front_sheet(wb3, "Front Page", report_no = NA)
# still needs a Units marker somewhere for match() at the workbook level
build_water_sheet(
  wb3, "Field Data 1", feature_cols[1], dates[1],
  ph_vals = 7.00, ec_vals = 400, temp_vals = 18.0, comment_vals = NA
)
saveWorkbook(wb3, file.path(here, "NO_REPORT_NO.xlsx"), overwrite = TRUE)

# =============================================================================
# random.xlsx -- unrelated workbook for the R-6.1 negative match() test
# =============================================================================
wb4 <- createWorkbook()
addWorksheet(wb4, "Sheet1")
set_cell(wb4, "Sheet1", 1, 1, "id")
set_cell(wb4, "Sheet1", 1, 2, "value")
set_cell(wb4, "Sheet1", 2, 1, 1)
set_cell(wb4, "Sheet1", 2, 2, 42)
saveWorkbook(wb4, file.path(here, "random.xlsx"), overwrite = TRUE)

message("acirl fixtures written to ", normalizePath(here))
