# Deterministic generator for tests/testthat/fixtures/crosstab/*'s SYNTHETIC
# fixtures. Re-run with: Rscript tests/testthat/fixtures/crosstab/generate.R
#
# CONTRACT A34 (2026-07-15): the real ALS crosstab layout, verified against
# the real (anonymized, committed) XTAB/ENMRG fixtures in this same
# directory (`ES2600185_0_XTAB.csv`, `ES2537534_0_ENMRG.CSV`), differs from
# an earlier synthetic-fixture guess. These synthetic fixtures now encode the
# CORRECT real layout (see README.md's column table) and cover only the
# criteria the two real files do not: (a) a two-section fixture (matrix/date
# carried per-section), (b) a Workgroup-cell-vs-filename mismatch, (c) an
# ENMRG file with QC sample columns (the real ENMRG fixture's only usable
# section is all-REG - see README.md). They are intentionally tiny.
#
# Real-layout column facts encoded below (0-based column indices, confirmed
# against the real fixtures): section-scalar labels (`Matrix:`/
# `Client - Matrix:`, `Workgroup:`, `Project name/number:`) at column 0,
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
# counted in report$n_by_sample_type". The real ENMRG fixture's only usable
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

message("crosstab fixtures written to ", normalizePath(here))
