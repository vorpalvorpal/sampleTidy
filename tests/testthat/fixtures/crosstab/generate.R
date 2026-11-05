# Deterministic generator for every crosstab-shaped fixture in
# tests/testthat/fixtures/crosstab/ (plus the Secondary-ID ENMRG copy in
# ../qc/secondary/ and the latin-1 / UTF-8 pair in ../corpus-2026-10-19/).
# Re-run with: Rscript tests/testthat/fixtures/crosstab/generate.R
# All content is synthetic. (Re-running also rewrites XX1234567_0_XTAB.xlsx,
# whose zip metadata carries a timestamp; its cells do not change.)
#
# CONTRACT A34 (2026-07-15): the ALS crosstab layout differs from an earlier
# synthetic-fixture guess. The fixtures below encode the CORRECT layout (see
# README.md's column table). Two kinds:
#   - minimal fixtures, one criterion each: (a) a two-section fixture
#     (matrix/date carried per-section), (b) a Workgroup-cell-vs-filename
#     mismatch, (c) an ENMRG file with QC sample columns, and the R-12.8
#     match()-hardening files;
#   - full-shape lab exports (the section at the end of this file): every
#     analyte row of a routine water suite, with invented work orders,
#     purchase orders, dates and results.
#
# Layout column facts encoded below (0-based column indices): section-scalar
# labels (`Matrix:`/`Client - Matrix:`, `Workgroup:`, `Project name/number:`)
# at column 0,
# value at column 1. Per-sample labels at column 3 (XTAB) / column 4
# (ENMRG); XTAB's per-sample values start two columns after the label
# (column 5, i.e. one empty gap column), ENMRG's start immediately the next
# column (no gap) - both are handled by the adapter's "first non-empty cell
# to the right of the label" rule, so the generator just reproduces each
# dialect's observed spacing. The analyte header is always the single
# combined `Analyte grouping/Analyte` column, with `CAS Number` +
# `Unit`/`Units` + `Limit of reporting`/`LOR` alongside it.

this_file_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
here <- if (length(this_file_arg) == 1) {
  dirname(normalizePath(sub("^--file=", "", this_file_arg)))
} else {
  "tests/testthat/fixtures/crosstab"
}

csv_escape_field <- function(x) {
  x <- ifelse(is.na(x), "", x)
  ifelse(grepl('[,"\n]', x, useBytes = TRUE),
         paste0('"', gsub('"', '""', x, fixed = TRUE), '"'),
         x)
}
csv_row <- function(fields) paste(csv_escape_field(fields), collapse = ",")

pad <- function(fields, n) {
  if (length(fields) >= n) return(fields[seq_len(n)])
  c(fields, rep("", n - length(fields)))
}

write_ascii_csv <- function(rows, path) {
  max_cols <- max(vapply(rows, length, integer(1)))
  lines <- vapply(rows, function(r) csv_row(pad(r, max_cols)), character(1))
  text <- paste0(paste(lines, collapse = "\r\n"), "\r\n")
  con <- file(path, open = "wb")
  writeBin(charToRaw(text), con) # pure ASCII content - encoding-neutral bytes
  close(con)
}

# =============================================================================
# XX1234567_0_XTAB.csv -- (a) two-section fixture: WATER then SOIL, proving
# R-5.1's "rows carry their own section's matrix and date" (each section
# resets on its own "Matrix:" row, per CONTRACT A34's per-row multi-label
# handling: this row also carries that section's "Sample Type:").
# XTAB column layout: per-sample label at column 3 (0-based), one empty gap
# column, values from column 5.
# =============================================================================
water_rows <- list(
  c("Matrix:", "WATER", "", "Sample Type:", "", "REG", "REG"),
  c("Workgroup:", "XX1234567", "", "ALS Sample Number:", "", "XX1234567001", "XX1234567002"),
  c("Project name/number:", "Test Project A / XX1234567", "", "Sample Date:", "", "24/05/2025", "24/05/2025"),
  c("", "", "", "Client sample ID (1st):", "", "T.S01", "T.S02"),
  c("", "", "", "Site:", "", "Site A", "Site A"),
  c("", "", "", "", "", "", ""),
  c("Analyte grouping/Analyte", "CAS Number", "Unit", "Limit of reporting", "", "", ""),
  c("", "", "", "", "", "", ""),
  c("EA005P: pH by PC Titrator", "", "", "", "", "", ""),
  c("pH Value", "", "pH Unit", "0.01", "", "6.40", "6.90")
)

soil_rows <- list(
  c("Matrix:", "SOIL", "", "Sample Type:", "", "REG"),
  c("Workgroup:", "XX1234567", "", "ALS Sample Number:", "", "XX1234567003"),
  c("Project name/number:", "Test Project A / XX1234567", "", "Sample Date:", "", "25/05/2025"),
  c("", "", "", "Client sample ID (1st):", "", "T.S03"),
  c("", "", "", "", "", ""),
  c("Analyte grouping/Analyte", "CAS Number", "Unit", "Limit of reporting", "", ""),
  c("", "", "", "", "", ""),
  c("EA005P: pH by PC Titrator", "", "", "", "", ""),
  c("pH Value", "", "pH Unit", "0.01", "", "6.80")
)

xtab_csv_path <- file.path(here, "XX1234567_0_XTAB.csv")
write_ascii_csv(c(water_rows, soil_rows), xtab_csv_path)

# =============================================================================
# XX1234567_0_XTAB.xlsx -- binary/xlsx twin, kept only so that OTHER plans'
# fixtures (test-adapter-acirl.R's "a foreign xlsx matches no" check) have a
# `.xlsx` crosstab-shaped file to point at. R-5.2's real "xls twin parses
# equal to its csv twin" criterion is deferred (CONTRACT A37: the real
# `.XLS` is unreadable SpreadsheetML, not BIFF) - this file is NOT asserted
# equal to the csv above.
# =============================================================================
if (!requireNamespace("openxlsx", quietly = TRUE)) {
  stop("openxlsx is required to generate the XTAB .xlsx fixture twin")
}
library(openxlsx)

grid_rows <- c(water_rows, soil_rows)
max_cols <- max(vapply(grid_rows, length, integer(1)))
grid <- t(vapply(grid_rows, function(r) pad(r, max_cols), character(max_cols)))
grid_df <- as.data.frame(grid, stringsAsFactors = FALSE)
names(grid_df) <- paste0("V", seq_len(max_cols))

wb <- createWorkbook()
addWorksheet(wb, "XTAB")
writeData(wb, "XTAB", grid_df, colNames = FALSE, na.string = "")
saveWorkbook(wb, file.path(here, "XX1234567_0_XTAB.xlsx"), overwrite = TRUE)

# =============================================================================
# XX1234567_0_ENMRG.CSV -- (c) ENMRG with QC sample columns (`Sample Type:`
# = `LCS`, `MB`), proving R-5.1's "QC sample columns emitted (not dropped),
# counted in report$n_by_sample_type". The full-shape ENMRG fixture's only usable
# section is all-REG (its QC data lives in an unsupported trailing
# "QC - Matrix:" block the adapter deliberately does not parse - see
# README.md), so this criterion needs a synthetic fixture.
# ENMRG column layout: per-sample label at column 4 (0-based), values
# immediately the next column (no gap).
# =============================================================================
enmrg_rows <- list(
  c("Client - Matrix:", "WATER", "", "", "Sample Type:", "REG", "LCS", "MB"),
  c("Workgroup:", "XX1234567", "", "", "ALS Sample number:", "XX1234567001", "QC-000001", "QC-000002"),
  c("Project name/number:", "Test Project A / XX1234567", "", "", "Sample date:", "24/05/2025", "", ""),
  c("", "", "", "", "Client sample ID (Primary):", "T.S01", "", ""),
  c("", "", "", "", "Sample Site:", "Site A", "", ""),
  c("", "", "", "", "", "", "", ""),
  c("Analyte grouping/Analyte", "CAS Number", "Units", "LOR", "", "", "", ""),
  c("", "", "", "", "", "", "", ""),
  c("EA005P: pH by PC Titrator", "", "", "", "", "", "", ""),
  c("pH Value", "", "pH Unit", "0.01", "", "6.40", "7.00", "----"),
  c("EK040P: Fluoride by PC Titrator", "", "", "", "", "", "", ""),
  c("Fluoride", "16984-48-8", "mg/L", "0.1", "", "<0.1", "0.5", ""),
  c("EA010P: Conductivity by PC Titrator", "", "", "", "", "", "", ""),
  c("Electrical Conductivity @ 25°C", "", "µS/cm", "1", "", "185", "", "600")
)
enmrg_path <- file.path(here, "XX1234567_0_ENMRG.CSV")
{
  max_cols_enmrg <- max(vapply(enmrg_rows, length, integer(1)))
  enmrg_lines <- vapply(enmrg_rows, function(r) csv_row(pad(r, max_cols_enmrg)), character(1))
  enmrg_text <- paste0(paste(enmrg_lines, collapse = "\r\n"), "\r\n")
  con <- file(enmrg_path, open = "wb")
  writeBin(charToRaw(enc2utf8(enmrg_text)), con) # genuinely UTF-8, like real ENMRG
  close(con)
}

# =============================================================================
# ZZ9999999_0_XTAB.csv -- (b) filename/Workgroup mismatch precedence
# fixture. Filename says ZZ9999999; Workgroup: cell says XX1234567. Work
# order resolution must prefer the Workgroup cell + record a warning
# (R-5.3). Also doubles as the d/m/y disambiguation fixture (R-5.1): Sample
# Date "05/01/2026" is unambiguous only under d/m/y (-> 5 January).
# =============================================================================
mismatch_rows <- list(
  c("Matrix:", "WATER", "", "Sample Type:", "", "REG"),
  c("Workgroup:", "XX1234567", "", "ALS Sample Number:", "", "ZZ9999999001"),
  c("Project name/number:", "Test Project A", "", "Sample Date:", "", "05/01/2026"),
  c("", "", "", "Client sample ID (1st):", "", "T.S01"),
  c("", "", "", "", "", ""),
  c("Analyte grouping/Analyte", "CAS Number", "Unit", "Limit of reporting", "", ""),
  c("", "", "", "", "", ""),
  c("EA005P: pH by PC Titrator", "", "", "", "", ""),
  c("pH Value", "", "pH Unit", "0.01", "", "6.90")
)
write_ascii_csv(mismatch_rows, file.path(here, "ZZ9999999_0_XTAB.csv"))

# =============================================================================
# R-12.8 hardening fixtures (PLAN-12, F14): match()'s dialect-marker peek
# currently reads only file_meta()'s fixed first-2048-byte window
# (`.st_crosstab_peek_lines()` -> `fm$peek`). Two ways real (very wide)
# crosstabs can defeat that: (1) the `Workgroup:` cell sits past byte 2048,
# so the byte-limited peek never sees it; (2) a UTF-8 BOM on line 1 decodes
# under the pinned latin-1 peek locale as 3 extra leading characters, which
# defeats `^Matrix:`. Both fixtures are match()-only (never parsed in the
# test suite) - minimal single-section XTAB shape, otherwise identical to
# `ZZ9999999_0_XTAB.csv` above.
# =============================================================================

# WK7654321_0_XTAB.csv: `Matrix:` on line 1 (required - it's the section AND
# match() marker), then one huge filler row (>2048 bytes on its own) BEFORE
# the `Workgroup:` row, pushing the latter's first byte past offset 2048.
past_2kb_rows <- list(
  c("Matrix:", "WATER", "", "Sample Type:", "", "REG"),
  c("Filler:", strrep("x", 2200)),
  c("Workgroup:", "WK7654321", "", "ALS Sample Number:", "", "WK7654321001"),
  c("Project name/number:", "Test Project A", "", "Sample Date:", "", "24/05/2025"),
  c("", "", "", "Client sample ID (1st):", "", "T.S01"),
  c("", "", "", "", "", ""),
  c("Analyte grouping/Analyte", "CAS Number", "Unit", "Limit of reporting", "", ""),
  c("", "", "", "", "", ""),
  c("EA005P: pH by PC Titrator", "", "", "", "", ""),
  c("pH Value", "", "pH Unit", "0.01", "", "6.40")
)
write_ascii_csv(past_2kb_rows, file.path(here, "WK7654321_0_XTAB.csv"))

# BM1122334_0_XTAB.csv: same minimal single-section shape, with a raw UTF-8
# BOM (EF BB BF) prepended before any text - ESdat's own reader strips BOMs;
# the crosstab path currently does not (R-12.8/F14).
bom_rows <- list(
  c("Matrix:", "WATER", "", "Sample Type:", "", "REG"),
  c("Workgroup:", "BM1122334", "", "ALS Sample Number:", "", "BM1122334001"),
  c("Project name/number:", "Test Project A", "", "Sample Date:", "", "24/05/2025"),
  c("", "", "", "Client sample ID (1st):", "", "T.S01"),
  c("", "", "", "", "", ""),
  c("Analyte grouping/Analyte", "CAS Number", "Unit", "Limit of reporting", "", ""),
  c("", "", "", "", "", ""),
  c("EA005P: pH by PC Titrator", "", "", "", "", ""),
  c("pH Value", "", "pH Unit", "0.01", "", "6.40")
)
bom_path <- file.path(here, "BM1122334_0_XTAB.csv")
{
  max_cols_bom <- max(vapply(bom_rows, length, integer(1)))
  bom_lines <- vapply(bom_rows, function(r) csv_row(pad(r, max_cols_bom)), character(1))
  bom_text <- paste0(paste(bom_lines, collapse = "\r\n"), "\r\n")
  con <- file(bom_path, open = "wb")
  writeBin(as.raw(c(0xEF, 0xBB, 0xBF)), con) # UTF-8 BOM
  writeBin(charToRaw(bom_text), con)
  close(con)
}

# =============================================================================
# Lab-export-shaped fixtures. These carry the full shape of ALS exports (all
# analyte rows of a routine water suite, "----" cells, "<LOR" values, the
# ENMRG trailing "QC - Matrix:" block, the XTAB .XLS's QC worksheet, and each
# file's own encoding quirks) with INVENTED work orders, purchase orders,
# dates and results:
#   ES2670610_0_XTAB.csv             XTAB, degree/micro already destroyed to
#                                    U+FFFD (bytes EF BF BD), CRLF, no final
#                                    newline
#   ES2670610_0_XTAB.XLS             SpreadsheetML 2003 twin (ISO-8859-1, raw
#                                    0xB0/0xB5), plus a "QC WATER - 1" sheet
#   ES2570540_0_ENMRG.CSV            ENMRG, genuine UTF-8, quoted values, CRLF
#   ../qc/secondary/ES2570540_0_ENMRG.CSV   the same report with edited
#                                    Primary/Secondary client-ID rows
#                                    (test-qc-ingest.R)
#   ../corpus-2026-10-19/latin1/ES2470410_0_XTAB.csv     genuinely latin-1
#                                    (raw 0xB0/0xB5/0xB1), final CRLF
#   ../corpus-2026-10-19/utf8-twin/ES2470410_0_XTAB.csv  the same report in
#                                    UTF-8, no final newline
# Point codes (P.*/Q.*), project names and "Site C" are the fixtures' own
# synthetic labels.
# =============================================================================
deg <- "°"
micro <- "µ"
plusminus <- "±"

# A body is a list of method-group titles (strings) and analyte rows
# c(name, CAS, unit, LOR, one value per sample).
xtab_body <- list(
  "EA005P: pH by PC Titrator",
  c("pH Value", "", "pH Unit", "0.01", "----", "3.32", "6.86"),
  "EA006: Sodium Adsorption Ratio (SAR)",
  c("Sodium Adsorption Ratio", "", "", "0.01", "----", "1.09", "0.32"),
  "EA010P: Conductivity by PC Titrator",
  c(paste0("Electrical Conductivity @ 25", deg, "C"), "", paste0(micro, "S/cm"), "1", "----", "156", "173"),
  "EA016: Calculated TDS (from Electrical Conductivity)",
  c("Total Dissolved Solids (Calc.)", "", "mg/L", "1", "----", "101", "112"),
  "EA065: Total Hardness as CaCO3",
  c("Total Hardness as CaCO3", "", "mg/L", "1", "----", "<1", "71"),
  "ED037P: Alkalinity by PC Titrator",
  c("Hydroxide Alkalinity as CaCO3", "", "mg/L", "1", "----", "<1", "<1"),
  c("Carbonate Alkalinity as CaCO3", "3812-32-6", "mg/L", "1", "----", "<1", "<1"),
  c("Bicarbonate Alkalinity as CaCO3", "71-52-3", "mg/L", "1", "----", "<1", "54"),
  c("Total Alkalinity as CaCO3", "", "mg/L", "1", "----", "<1", "54"),
  "ED041G: Sulfate (Turbidimetric) as SO4 2- by DA",
  c("Sulfate as SO4 - Turbidimetric", "14808-79-8", "mg/L", "1", "----", "<1", "13"),
  "ED045G: Chloride by Discrete Analyser",
  c("Chloride", "16887-00-6", "mg/L", "1", "----", "5", "6"),
  "ED093F: Dissolved Major Cations",
  c("Calcium", "7440-70-2", "mg/L", "1", "----", "<1", "25"),
  c("Magnesium", "7439-95-4", "mg/L", "1", "----", "<1", "2"),
  c("Sodium", "7440-23-5", "mg/L", "1", "----", "5", "6"),
  c("Potassium", "7440-09-7", "mg/L", "1", "----", "<1", "2"),
  "EK040P: Fluoride by PC Titrator",
  c("Fluoride", "16984-48-8", "mg/L", "0.1", "----", "<0.1", "<0.1"),
  "EK055G: Ammonia as N by Discrete Analyser",
  c("Ammonia as N", "7664-41-7", "mg/L", "0.01", "0.10", "0.10", "0.02"),
  "EK057G:  Nitrite as N by Discrete Analyser",
  c("Nitrite as N", "14797-65-0", "mg/L", "0.01", "----", "<0.01", "<0.01"),
  "EK058G:  Nitrate as N by Discrete Analyser",
  c("Nitrate as N", "14797-55-8", "mg/L", "0.01", "----", "0.14", "0.44"),
  "EK059G:  Nitrite plus Nitrate as N (NOx)  by Discrete Analyser",
  c("Nitrite + Nitrate as N", "", "mg/L", "0.01", "0.16", "0.14", "0.44"),
  "EK061G: Total Kjeldahl Nitrogen By Discrete Analyser",
  c("Total Kjeldahl Nitrogen as N", "", "mg/L", "0.1", "----", "<0.1", "<0.1"),
  "EK062G: Total Nitrogen as N (TKN + NOx) by Discrete Analyser",
  c("Total Nitrogen as N", "", "mg/L", "0.1", "----", "0.1", "0.4"),
  "EK067G: Total Phosphorus as P by Discrete Analyser",
  c("Total Phosphorus as P", "", "mg/L", "0.01", "----", "0.03", "0.02"),
  "EK071G: Reactive Phosphorus as P by discrete analyser",
  c("Reactive Phosphorus as P", "14265-44-2", "mg/L", "0.01", "----", "<0.01", "<0.01"),
  "EN055: Ionic Balance",
  c("Total Anions", "", "meq/L", "0.01", "----", "0.17", "1.91"),
  c("Total Cations", "", "meq/L", "0.01", "----", "0.13", "1.63")
)

enmrg_body <- list(
  "EA005P: pH by PC Titrator",
  c("pH Value", "", "pH Unit", "0.01", "6.15", "6.51", "6.44", "5.15", "4.84", "6.94", "8.13"),
  "EA010P: Conductivity by PC Titrator",
  c(paste0("Electrical Conductivity @ 25", deg, "C"), "", paste0(micro, "S/cm"), "1",
    "1040", "642", "237", "187", "127", "168", "306"),
  "EA016: Calculated TDS (from Electrical Conductivity)",
  c("Total Dissolved Solids (Calc.)", "", "mg/L", "1", "676", "417", "154", "122", "83", "109", "199"),
  paste0("EA025: Total Suspended Solids dried at 104 ", plusminus, " 2", deg, "C"),
  c("Suspended Solids (SS)", "", "mg/L", "5", "----", "----", "----", "<5", "<5", "<5", "<5"),
  "EA065: Total Hardness as CaCO3",
  c("Total Hardness as CaCO3", "", "mg/L", "1", "89", "61", "37", "19", "11", "44", "38"),
  "ED037P: Alkalinity by PC Titrator",
  c("Hydroxide Alkalinity as CaCO3", "DMO-210-001", "mg/L", "1", "<1", "<1", "<1", "<1", "<1", "<1", "<1"),
  c("Carbonate Alkalinity as CaCO3", "3812-32-6", "mg/L", "1", "<1", "<1", "<1", "<1", "<1", "<1", "<1"),
  c("Bicarbonate Alkalinity as CaCO3", "71-52-3", "mg/L", "1", "218", "109", "34", "<1", "<1", "30", "72"),
  c("Total Alkalinity as CaCO3", "", "mg/L", "1", "218", "109", "34", "<1", "<1", "30", "72"),
  "ED041G: Sulfate (Turbidimetric) as SO4 2- by DA",
  c("Sulfate as SO4 - Turbidimetric", "14808-79-8", "mg/L", "1", "82", "32", "16", "9", "3", "19", "24"),
  "ED045G: Chloride by Discrete Analyser",
  c("Chloride", "16887-00-6", "mg/L", "1", "270", "79", "33", "37", "30", "47", "67"),
  "ED093F: Dissolved Major Cations",
  c("Calcium", "7440-70-2", "mg/L", "1", "16", "8", "5", "1", "1", "11", "7"),
  c("Magnesium", "7439-95-4", "mg/L", "1", "12", "10", "6", "4", "2", "4", "5"),
  c("Sodium", "7440-23-5", "mg/L", "1", "77", "67", "20", "29", "20", "29", "49"),
  c("Potassium", "7440-09-7", "mg/L", "1", "25", "33", "9", "1", "1", "5", "16"),
  "EG020F: Dissolved Metals by ICP-MS",
  c("Iron", "7439-89-6", "mg/L", "0.05", "0.37", "1.60", "0.07", "----", "----", "----", "----"),
  "EG051G: Ferrous Iron by Discrete Analyser",
  c("Ferrous Iron", "", "mg/L", "0.05", "38.8", "2.93", "1.39", "----", "----", "----", "----"),
  "EG053FG-MS: Dissolved Ferric Iron by ICPMS and DA",
  c("Ferric Iron", "", "mg/L", "0.05", "<0.50", "<0.50", "<0.50", "----", "----", "----", "----"),
  "EK040P: Fluoride by PC Titrator",
  c("Fluoride", "16984-48-8", "mg/L", "0.1", "<0.1", "<0.1", "<0.1", "<0.1", "<0.1", "<0.1", "<0.1"),
  "EK055G: Ammonia as N by Discrete Analyser",
  c("Ammonia as N", "7664-41-7", "mg/L", "0.01", "78.3", "9.52", "2.51", "0.02", "<0.01", "0.04", "0.13"),
  "EK057G:  Nitrite as N by Discrete Analyser",
  c("Nitrite as N", "14797-65-0", "mg/L", "0.01", "0.06", "0.03", "0.01", "<0.01", "<0.01", "<0.01", "0.04"),
  "EK058G:  Nitrate as N by Discrete Analyser",
  c("Nitrate as N", "14797-55-8", "mg/L", "0.01", "0.06", "0.04", "0.01", "0.01", "<0.01", "0.15", "1.28"),
  "EK059G:  Nitrite plus Nitrate as N (NOx)  by Discrete Analyser",
  c("Nitrite + Nitrate as N", "", "mg/L", "0.01", "0.12", "0.07", "0.02", "0.01", "<0.01", "0.15", "1.32"),
  "EK071G: Reactive Phosphorus as P by discrete analyser",
  c("Reactive Phosphorus as P", "14265-44-2", "mg/L", "0.01", "<0.01", "<0.01", "<0.01", "<0.01", "<0.01", "<0.01", "<0.01"),
  "EN055: Ionic Balance",
  c("Total Anions", "", "meq/L", "0.01", "15.1", "6.04", "2.04", "1.06", "0.96", "1.91", "3.97"),
  c("Total Cations", "", "meq/L", "0.01", "13.6", "4.92", "2.22", "1.62", "1.15", "1.62", "3.16"),
  c("Ionic Balance", "", "%", "0.01", "5.23", "10.22", "----", "----", "----", "----", "11.36")
)

latin1_body <- list(
  "EA005P: pH by PC Titrator",
  c("pH Value", "", "pH Unit", "0.01", "7.33"),
  "EA010P: Conductivity by PC Titrator",
  c(paste0("Electrical Conductivity @ 25", deg, "C"), "", paste0(micro, "S/cm"), "1", "358"),
  "EA016: Calculated TDS (from Electrical Conductivity)",
  c("Total Dissolved Solids (Calc.)", "", "mg/L", "1", "233"),
  paste0("EA025: Total Suspended Solids dried at 104 ", plusminus, " 2", deg, "C"),
  c("Suspended Solids (SS)", "", "mg/L", "5", "95"),
  "EA065: Total Hardness as CaCO3",
  c("Total Hardness as CaCO3", "", "mg/L", "1", "75"),
  "ED037P: Alkalinity by PC Titrator",
  c("Hydroxide Alkalinity as CaCO3", "DMO-210-001", "mg/L", "1", "<1"),
  c("Carbonate Alkalinity as CaCO3", "3812-32-6", "mg/L", "1", "<1"),
  c("Bicarbonate Alkalinity as CaCO3", "71-52-3", "mg/L", "1", "65"),
  c("Total Alkalinity as CaCO3", "", "mg/L", "1", "65"),
  "ED041G: Sulfate (Turbidimetric) as SO4 2- by DA",
  c("Sulfate as SO4 - Turbidimetric", "14808-79-8", "mg/L", "1", "21"),
  "ED045G: Chloride by Discrete Analyser",
  c("Chloride", "16887-00-6", "mg/L", "1", "41"),
  "ED093F: Dissolved Major Cations",
  c("Calcium", "7440-70-2", "mg/L", "1", "25"),
  c("Magnesium", "7439-95-4", "mg/L", "1", "3"),
  c("Sodium", "7440-23-5", "mg/L", "1", "21"),
  c("Potassium", "7440-09-7", "mg/L", "1", "12"),
  "EK040P: Fluoride by PC Titrator",
  c("Fluoride", "16984-48-8", "mg/L", "0.1", "<0.1"),
  "EK055G: Ammonia as N by Discrete Analyser",
  c("Ammonia as N", "7664-41-7", "mg/L", "0.01", "0.02"),
  "EK057G:  Nitrite as N by Discrete Analyser",
  c("Nitrite as N", "14797-65-0", "mg/L", "0.01", "0.02"),
  "EK058G:  Nitrate as N by Discrete Analyser",
  c("Nitrate as N", "14797-55-8", "mg/L", "0.01", "2.67"),
  "EK059G:  Nitrite plus Nitrate as N (NOx)  by Discrete Analyser",
  c("Nitrite + Nitrate as N", "", "mg/L", "0.01", "2.69"),
  "EK071G: Reactive Phosphorus as P by discrete analyser",
  c("Reactive Phosphorus as P", "14265-44-2", "mg/L", "0.01", "<0.01"),
  "EN055: Ionic Balance",
  c("Total Anions", "", "meq/L", "0.01", "2.73"),
  c("Total Cations", "", "meq/L", "0.01", "3.65"),
  "EP005: Total Organic Carbon (TOC)",
  c("Total Organic Carbon", "", "mg/L", "1", "8")
)

write_bytes <- function(bytes, path) {
  con <- file(path, open = "wb")
  writeBin(bytes, con)
  close(con)
}
to_latin1 <- function(text) {
  b <- iconv(text, from = "UTF-8", to = "latin1", toRaw = TRUE)[[1]]
  stopifnot(!is.null(b))
  b
}

# ---- XTAB grid: label col 0, CAS 1, unit 2, LOR / per-sample label 3, gap 4,
# samples from 5. Every row padded to the full width, no quoting.
xtab_grid <- function(wo, project, date, ids, site, po, body) {
  n <- length(ids)
  w <- 5L + n
  blank <- rep("", w)
  lab <- function(label, vals) c("", "", "", label, "", vals)
  rows <- list(
    c("Matrix:", "WATER", "", "Sample Type:", "", rep("REG", n)),
    c("Workgroup:", wo, "", "ALS Sample Number:", "", sprintf("%s%03d", wo, seq_len(n))),
    c("Project name/number:", project, "", "Sample Date:", "", rep(date, n)),
    lab("Client sample ID (1st):", ids),
    lab("Client sample ID (2nd):", rep("", n)),
    lab("Depth Type:", rep("", n)),
    lab("Depth (m):      ", rep("", n)),
    lab("Site:      ", rep(site, n)),
    lab("Purchase Order:      ", rep(po, n)),
    blank,
    c("Analyte grouping/Analyte", "CAS Number", "Unit", "Limit of reporting", rep("", n + 1L)),
    blank
  )
  for (k in seq_along(body)) {
    b <- body[[k]]
    if (length(b) == 1) {
      if (k > 1) rows[[length(rows) + 1]] <- blank
      rows[[length(rows) + 1]] <- c(b, rep("", w - 1L))
    } else {
      rows[[length(rows) + 1]] <- c(b[1:4], "", b[-(1:4)])
    }
  }
  rows
}
xtab_text <- function(rows, eol_at_end) {
  text <- paste(vapply(rows, paste, character(1), collapse = ","), collapse = "\r\n")
  if (eol_at_end) paste0(text, "\r\n") else text
}

# ES2670610: XTAB.csv (U+FFFD for degree/micro, as ALS's own export) ...
xtab_wo <- "ES2670610"
xtab_rows <- xtab_grid(xtab_wo, "SiteB Monthly", "07/01/2026", c("P.S03", "P.S07", "P.S09"),
                       "Site C", "49002", xtab_body)
csv_text <- gsub(paste0("[", deg, micro, "]"), "�", xtab_text(xtab_rows, FALSE))
write_bytes(charToRaw(enc2utf8(csv_text)), file.path(here, paste0(xtab_wo, "_0_XTAB.csv")))

# ... and its SpreadsheetML ".XLS" twin, written the way ALS writes it: every
# cell a String, per-sample labels merged across columns 3-4, labels with a
# trailing newline + tabs, blank cells as <ss:Cell/> or an empty Data element,
# raw ISO-8859-1 degree/micro bytes, a trailing blank row, and a second
# worksheet of QC lots and other clients' samples that must never be ingested.
xml_esc <- function(x) {
  x <- gsub("&", "&amp;", x, fixed = TRUE)
  x <- gsub("<", "&lt;", x, fixed = TRUE)
  gsub(">", "&gt;", x, fixed = TRUE)
}
ss_cell <- function(v, style = NA, merge = FALSE) {
  attrs <- paste0(if (merge) ' ss:MergeAcross="1"' else "",
                  if (!is.na(style)) sprintf(' ss:StyleID="%s"', style) else "")
  if (is.na(v)) return(sprintf("<ss:Cell%s/>", attrs))
  data <- if (identical(v, "")) '<ss:Data ss:Type="String"/>' else
    sprintf('<ss:Data ss:Type="String">%s</ss:Data>', xml_esc(v))
  sprintf("<ss:Cell%s>%s</ss:Cell>", attrs, data)
}
ss_row <- function(cells) if (length(cells)) paste0("<ss:Row>", paste(cells, collapse = ""), "</ss:Row>") else "<ss:Row/>"
value_style <- function(v, j = NA) if (grepl("^<", v) || !nzchar(v)) NA else "6"
ss_label <- function(label) sub("\\s+$", "\n\t\t\t\t\t", label)

ss_sheet <- function(type, type_style, wo, project, ids, dates, extra, body, vstyle = value_style) {
  first3 <- if (is.null(project)) rep(ss_cell(NA), 3) else
    c(ss_cell("Project name/number:", "3"), ss_cell(project), ss_cell(NA))
  head <- c(
    ss_row(c(ss_cell("Matrix:", "3"), ss_cell("WATER"), ss_cell(NA), ss_cell("Sample Type:", "3", TRUE),
             vapply(type, ss_cell, "", style = type_style))),
    ss_row(c(ss_cell("Workgroup:", "3"), ss_cell(wo), ss_cell(NA),
             ss_cell("ALS Sample Number:", "3", TRUE), vapply(ids, ss_cell, ""))),
    ss_row(c(first3, ss_cell("Sample Date:", "3", TRUE), vapply(dates, ss_cell, "")))
  )
  for (x in extra) {
    head <- c(head, ss_row(c(rep(ss_cell(NA), 3), ss_cell(ss_label(x[[1]]), "3", TRUE),
                             vapply(x[[2]], ss_cell, ""))))
  }
  seps <- rep("\n", length(head))
  seps[intersect(c(1L, 4L), seq_along(head))] <- "        \n"
  out <- paste0(paste0(head, seps, collapse = ""), "<ss:Row/>",
                ss_row(vapply(c("Analyte grouping/Analyte", "CAS Number", "Unit", "Limit of reporting"),
                              ss_cell, "", style = "1")), "\n")
  for (b in body) {
    if (length(b) == 1) {
      out <- paste0(out, "<ss:Row/>", ss_row(ss_cell(b, "2")))
    } else {
      vals <- b[-(1:4)]
      cells <- c(vapply(b[1:4], ss_cell, ""), ss_cell(""),
                 vapply(seq_along(vals), function(j) ss_cell(vals[j], vstyle(vals[j], j)), ""))
      out <- paste0(out, ss_row(cells), "        \n         ")
    }
  }
  paste0(out, "<ss:Row/>")
}

ss_workbook <- function(sheets, n_cols) {
  styles <- paste0(
    '<ss:Styles><ss:Style ss:ID="1"><ss:Font ss:Bold="1"/></ss:Style><ss:Style ss:ID="2">',
    '<ss:Font ss:Bold="1" ss:Italic="1"/><ss:Interior ss:Color="#99CCFF" ss:Pattern="Solid"/>',
    '<ss:Borders><ss:Border ss:Position="Bottom" ss:LineStyle="Continuous" ss:Weight="1"/>',
    '<ss:Border ss:Position="Left" ss:LineStyle="Continuous" ss:Weight="1"/>',
    '<ss:Border ss:Position="Right" ss:LineStyle="Continuous" ss:Weight="1"/>',
    '<ss:Border ss:Position="Top" ss:LineStyle="Continuous" ss:Weight="1"/></ss:Borders>',
    '<ss:NumberFormat/><ss:Protection/></ss:Style><ss:Style ss:ID="3"><ss:Alignment ',
    'ss:Horizontal="Right" ss:Vertical="Bottom" ss:Indent="1"/><ss:Borders/><ss:Font ss:Bold="1"/>',
    '<ss:Interior/><ss:NumberFormat/><ss:Protection/></ss:Style><ss:Style ss:ID="4"><ss:Alignment ',
    'ss:Horizontal="Center" ss:Vertical="Bottom"/><ss:Borders><ss:Border ss:Position="Bottom" ',
    'ss:LineStyle="Continuous" ss:Weight="2" ss:Color="#3366FF"/></ss:Borders><ss:Font ss:Bold="1"/>',
    '</ss:Style><ss:Style ss:ID="5"><ss:Alignment ss:Horizontal="Center" ss:Vertical="Bottom"/>',
    '<ss:Borders><ss:Border ss:Position="Bottom" ss:LineStyle="Continuous" ss:Weight="2" ',
    'ss:Color="#339966"/></ss:Borders><ss:Font ss:Bold="1"/><ss:Interior/><ss:NumberFormat/>',
    '<ss:Protection/></ss:Style><ss:Style ss:ID="6"><ss:Font ss:Bold="1"/></ss:Style></ss:Styles>'
  )
  ws_opts <- function(split) paste0(
    '<WorksheetOptions xmlns="urn:schemas-microsoft-com:office:excel"><FreezePanes/><FrozenNoSplit/>',
    sprintf("<SplitHorizontal>%d</SplitHorizontal><TopRowBottomPane>%d</TopRowBottomPane>", split, split),
    "<SplitVertical>5</SplitVertical><LeftColumnRightPane>5</LeftColumnRightPane><ActivePane>0</ActivePane>",
    "<Panes><Pane><Number>3</Number></Pane><Pane><Number>1</Number></Pane><Pane><Number>2</Number></Pane>",
    "<Pane><Number>0</Number></Pane></Panes><ProtectObjects>False</ProtectObjects>",
    "<ProtectScenarios>False</ProtectScenarios></WorksheetOptions>"
  )
  body <- vapply(seq_along(sheets), function(i) {
    s <- sheets[[i]]
    cols <- paste0('<ss:Column ss:Width="210"/><ss:Column ss:Width="80"/><ss:Column ss:Width="60"/>',
                   '<ss:Column ss:AutoFitWidth="0" ss:Width="55"/><ss:Column ss:AutoFitWidth="0" ss:Width="65"/>',
                   strrep('<ss:Column ss:Width="80"/>', n_cols[[i]]))
    paste0(sprintf('<ss:Worksheet ss:Name="%s"><ss:Table>', names(sheets)[i]), cols,
           s$rows, "</ss:Table>", ws_opts(s$split), "</ss:Worksheet>\n")
  }, character(1))
  paste0('<?xml version="1.0" encoding="ISO-8859-1"?><ss:Workbook ',
         'xmlns:ss="urn:schemas-microsoft-com:office:spreadsheet" ',
         'xmlns:fo="http://www.w3.org/1999/XSL/Format">', styles, paste(body, collapse = ""),
         "</ss:Workbook>")
}

# Drop the analyte rows named in `drop`, then any method title left with no rows.
drop_rows <- function(body, drop) {
  body <- Filter(function(b) length(b) == 1 || !b[1] %in% drop, body)
  keep <- vapply(seq_along(body), function(k) {
    length(body[[k]]) > 1 || (k < length(body) && length(body[[k + 1]]) > 1)
  }, logical(1))
  body[keep]
}

# A synthetic QC block: invented QC lots, other clients' samples (work orders
# ESyy707nn / EWyy707nn / ENyy707nn) and results. Same seed, same block.
qc_block <- function(seed, n_qc, n_reg, yy, date, body) {
  set.seed(seed)
  types <- c(sample(c("LCS", "DUP", "MB", "MS"), n_qc, replace = TRUE, prob = c(4, 4, 2, 1)),
             rep("REG", n_reg))
  lot <- 9100000L + sort(sample(1:900, n_qc))
  lot_ids <- ifelse(runif(n_qc) < 0.4,
                    sprintf("QC-MRG%d-%07d%03d", sample(2:5, n_qc, replace = TRUE), lot, sample(1:60, n_qc, replace = TRUE)),
                    sprintf("QC-%07d-%03d", lot, sample(1:60, n_qc, replace = TRUE)))
  reg_ids <- sprintf("%s%s707%02d%03d", sample(c("ES", "ES", "ES", "EN", "EW"), n_reg, replace = TRUE), yy,
                     seq_len(n_reg), sample(1:12, n_reg, replace = TRUE))
  d0 <- as.Date(date, "%d/%m/%Y")
  dates <- format(d0 + c(sample(1:6, n_qc, replace = TRUE), sample(-7:0, n_reg, replace = TRUE)), "%d/%m/%Y")
  rows <- lapply(body, function(b) {
    if (length(b) == 1) return(b)
    lor <- as.numeric(b[4])
    vals <- vapply(seq_along(types), function(j) {
      t <- types[j]
      if (runif(1) < 0.55) return(if (t == "REG") "----" else "")
      if (t %in% c("LCS", "MS")) return(as.character(signif(runif(1, 82, 116), 3)))
      if (b[1] == "pH Value") return(if (t == "MB") "----" else sprintf("%.2f", runif(1, 4, 9)))
      if (t == "MB") return(paste0("<", b[4]))
      as.character(signif(lor * 10^runif(1, 0.3, 3), 3))
    }, "")
    c(b[1:4], vals)
  })
  list(types = types, ids = c(lot_ids, reg_ids), dates = dates, rows = rows)
}

xls_qc <- qc_block(20261105L, 22L, 8L, "26", "07/01/2026",
                   drop_rows(xtab_body, c("Total Dissolved Solids (Calc.)", "Total Hardness as CaCO3",
                                          "Total Nitrogen as N", "Total Anions", "Total Cations")))
client_sheet <- list(
  rows = ss_sheet(rep("REG", 3), "4", xtab_wo, "SiteB Monthly", xtab_rows[[2]][6:8], rep("07/01/2026", 3),
                  list(list("Client sample ID (1st):", c("P.S03", "P.S07", "P.S09")),
                       list("Client sample ID (2nd):", rep("", 3)), list("Depth Type:", rep("", 3)),
                       list("Depth (m):      ", rep("", 3)), list("Site:      ", rep("Site C", 3)),
                       list("Purchase Order:      ", rep("49002", 3))),
                  xtab_body),
  split = 11L)
qc_sheet <- list(
  rows = ss_sheet(xls_qc$types, "5", xtab_wo, NULL, xls_qc$ids, xls_qc$dates, list(), xls_qc$rows,
                  vstyle = function(v, j) if (xls_qc$types[j] == "REG" || v == "----") "6" else NA),
  split = 5L)
xls_text <- ss_workbook(list("Client WATER - 1" = client_sheet, "QC WATER - 1" = qc_sheet),
                        c(3L, length(xls_qc$types)))
write_bytes(to_latin1(xls_text), file.path(here, paste0(xtab_wo, "_0_XTAB.XLS")))

# ES2570540: ENMRG. Per-sample labels at column 4, values from column 5; every
# value cell quoted except "----" and blanks; method titles are a single
# quoted field; the client section is followed by an unsupported
# "QC - Matrix:" block that reuses the same columns.
enmrg_wo <- "ES2570540"
enmrg_q <- function(v) ifelse(nzchar(v) & v != "----", paste0('"', v, '"'), v)
enmrg_lines <- function(primary, secondary) {
  n <- length(primary)
  ids <- sprintf("%s%03d", enmrg_wo, seq_len(n))
  head <- c(
    paste(c("Client - Matrix:", "WATER", "", "", "Sample Type:", rep("REG", n)), collapse = ","),
    paste(c("Workgroup:", enmrg_wo, "", "", "ALS Sample number:", ids), collapse = ","),
    paste(c("Project name/number:", "SITEA MONTHLY", "", "", "Sample date:", rep("18/11/2025", n)), collapse = ","),
    paste(c("", "", "", "", "Client sample ID (Primary):", primary), collapse = ","),
    paste(c("", "", "", "", "Client sample ID (Secondary):", secondary), collapse = ","),
    paste(c("", "", "", "", "Sample Site:", rep("Site C", n)), collapse = ","),
    paste(c("", "", "", "", "Purchase Order:", rep("49001", n)), collapse = ","),
    "", "", "Analyte grouping/Analyte,CAS Number,Units,LOR", ""
  )
  body_lines <- function(body) {
    out <- character(0)
    for (k in seq_along(body)) {
      b <- body[[k]]
      if (length(b) == 1) {
        if (k > 1) out <- c(out, "")
        out <- c(out, paste0('"', b, '"'))
      } else {
        out <- c(out, paste(c(paste0('"', b[1], '"'), b[2:4], "", enmrg_q(b[-(1:4)])), collapse = ","))
      }
    }
    out
  }
  qc <- qc_block(20251118L, 24L, 6L, "25", "18/11/2025",
                 drop_rows(enmrg_body, c("Total Dissolved Solids (Calc.)", "Total Hardness as CaCO3",
                                         "Ferric Iron", "Nitrate as N", "Total Anions",
                                         "Total Cations", "Ionic Balance")))
  qc_head <- c(
    paste(c("QC - Matrix:", "WATER", "", "", "Sample Type:", qc$types), collapse = ","),
    paste(c("Workgroup:", enmrg_wo, "", "", "ALS Sample number:", qc$ids), collapse = ","),
    paste(c("", "", "", "", "Sample date:", qc$dates), collapse = ","),
    "", "", "", "Analyte grouping/Analyte,CAS Number,Units,LOR", ""
  )
  c(head, body_lines(enmrg_body), "", "", qc_head, body_lines(qc$rows), "", "")
}
enmrg_ids <- c("Q.MW02", "Q.MW08", "Q.MW09", "Q.S01", "Q.S03", "Q.S05", "Q.S06")
write_enmrg <- function(lines, path) {
  write_bytes(charToRaw(enc2utf8(paste0(paste(lines, collapse = "\r\n"), "\r\n"))), path)
}
write_enmrg(enmrg_lines(enmrg_ids, rep("", 7)), file.path(here, paste0(enmrg_wo, "_0_ENMRG.CSV")))
# test-qc-ingest.R's Secondary-ID copy: only the two client-ID rows differ
# (an unregistered field label, an invented QC code, Secondary IDs).
write_enmrg(enmrg_lines(c("Q.MW02", "Q.MW08", "Bailer/Scoop", "Q.S01", "Q.JD42", "Q.S05", "Q.S06"),
                        c("12", "", "Field Blank", "", "", "Duplicate", "")),
            file.path(here, "..", "qc", "secondary", paste0(enmrg_wo, "_0_ENMRG.CSV")))

# ES2470410: the latin-1 / UTF-8 pair (PLAN-05 R-5.4a). One report, two
# encodings: the latin-1 copy ends with CRLF, the UTF-8 copy has no final
# newline; otherwise `iconv -f latin1` of the first is byte-identical to the
# second.
l1_wo <- "ES2470410"
l1_rows <- xtab_grid(l1_wo, "SITEA Apirl 2024 - Rain Event", "10/07/2024", "Q.E01", "",
                     "P000009001", latin1_body)
corpus <- file.path(here, "..", "corpus-2026-10-19")
write_bytes(to_latin1(xtab_text(l1_rows, TRUE)), file.path(corpus, "latin1", paste0(l1_wo, "_0_XTAB.csv")))
write_bytes(charToRaw(enc2utf8(xtab_text(l1_rows, FALSE))),
            file.path(corpus, "utf8-twin", paste0(l1_wo, "_0_XTAB.csv")))

message("crosstab fixtures written to ", normalizePath(here))
