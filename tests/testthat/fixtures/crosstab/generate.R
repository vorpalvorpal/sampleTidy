# Deterministic generator for tests/testthat/fixtures/crosstab/*
#
# Reproduces the ALS crosstab (XTAB / ENMRG) fixtures pinned in
# dev/plans/FIXTURES.md and dev/plans/PLAN-05-adapters-crosstab.md. Re-run
# with: Rscript tests/testthat/fixtures/crosstab/generate.R
#
# Column layout chosen for these fixtures (documented in README.md):
#   XTAB   section columns: 0 label/Analyte, 1 CAS Number, 2 Unit,
#          3 Limit of reporting, 4.. sample columns.
#          "ALS Sample Number:" label sits at column index 3 (per plan-05's
#          observed real-file layout fact) with sample numbers starting at
#          column 4.
#   ENMRG  columns: 0 Analyte grouping, 1 Analyte, 2 CAS Number, 3 Unit,
#          4 Limit of reporting, 5.. sample columns (3 regular + 2 QC).
#          "ALS Sample number:" label sits at column index 4, sample numbers
#          from column 5 (one more label column than XTAB, per plan-05).
#
# The XTAB .csv is written latin-1 with two REAL raw bytes standing in for
# legacy MacRoman/Latin-1 mojibake: 0xA1 (decodes under latin-1 to '¡' -
# the documented "25¡C" degree-sign mojibake, plan-02 R-2.1) and 0xB5
# (correct latin-1 byte for micro sign 'µ', used for "µS/cm"). Both are
# spliced in as raw bytes so the file is byte-exact, never routed through
# R's own (UTF-8) string encoding machinery.

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

# Placeholder -> raw byte splicing --------------------------------------
splice_all <- function(raw_vec, placeholder, replacement_raw) {
  ph <- charToRaw(placeholder)
  repeat {
    n <- length(raw_vec); m <- length(ph)
    pos <- NA_integer_
    if (n >= m) {
      for (i in seq_len(n - m + 1)) {
        if (identical(raw_vec[i:(i + m - 1)], ph)) { pos <- i; break }
      }
    }
    if (is.na(pos)) break
    raw_vec <- c(raw_vec[seq_len(pos - 1)], replacement_raw,
                 raw_vec[(pos + m):n])
  }
  raw_vec
}

DEG_TOKEN   <- "@@DEG@@"    # -> raw 0xA1 (latin-1/MacRoman mojibake byte)
MICRO_TOKEN <- "@@MICRO@@"  # -> raw 0xB5 (correct latin-1 byte for micro sign)

# =============================================================================
# XX1234567_0_XTAB.csv  (latin-1, two stacked sections: WATER then SOIL)
# =============================================================================
water_rows <- list(
  c("Matrix:", "WATER"),
  c("Workgroup:", "XX1234567"),
  c("Project name/number:", "Test Project A / XX1234567"),
  c("Sample Type:", "", "", "", "REG", "REG", "REG"),
  c("Sample Date:", "", "", "", "24/05/2025", "24/05/2025", "24/05/2025"),
  c("Client sample ID (1st):", "", "", "", "T.S01", "T.S02", "T.MW01"),
  c("Depth (m):", "", "", "", "", "", ""),
  c("", "", "", "ALS Sample Number:", "XX1234567001", "XX1234567002", "XX1234567003"),
  c("Analyte", "CAS Number", "Unit", "Limit of reporting", "", "", ""),
  c("EA005P: pH by PC Titrator", "", "", "", "", "", ""),
  c("pH", "", "pH Unit", "0.01", "6.40", "----", ""),
  c("EK040P: Fluoride by PC Titrator", "", "", "", "", "", ""),
  c("Fluoride", "16984-48-8", "mg/L", "0.1", "<0.1", "2.3", ">2000"),
  c("EA010P: Conductivity by PC Titrator", "", "", "", "", "", ""),
  c(paste0("Electrical Conductivity @ 25", DEG_TOKEN, "C"), "",
    paste0(MICRO_TOKEN, "S/cm"), "1", "185", "965", "")
)

soil_rows <- list(
  c("Matrix:", "SOIL"),
  c("Workgroup:", "XX1234567"),
  c("Sample Type:", "", "", "", "REG"),
  c("Sample Date:", "", "", "", "25/05/2025"),
  c("Client sample ID (1st):", "", "", "", "T.S03"),
  c("", "", "", "ALS Sample Number:", "XX1234567004"),
  c("Analyte", "CAS Number", "Unit", "Limit of reporting", ""),
  c("EA005P: pH by PC Titrator", "", "", "", ""),
  c("pH", "", "pH Unit", "0.01", "6.80"),
  c("EK040P: Fluoride by PC Titrator", "", "", "", ""),
  c("Fluoride", "16984-48-8", "mg/L", "0.1", "0.2"),
  c("EA010P: Conductivity by PC Titrator", "", "", "", ""),
  c("Electrical Conductivity (25C)", "", "uS/cm", "1", "210")
)

max_cols_xtab <- max(vapply(c(water_rows, soil_rows), length, integer(1)))
xtab_lines <- vapply(c(water_rows, soil_rows), function(r) csv_row(pad(r, max_cols_xtab)), character(1))
xtab_text <- paste(xtab_lines, collapse = "\r\n")
xtab_text <- paste0(xtab_text, "\r\n")

xtab_raw <- charToRaw(xtab_text)                    # safe: whole text is ASCII + placeholders
xtab_raw <- splice_all(xtab_raw, DEG_TOKEN, as.raw(0xA1))
xtab_raw <- splice_all(xtab_raw, MICRO_TOKEN, as.raw(0xB5))
stopifnot(!any(grepl("@@", rawToChar(xtab_raw), fixed = TRUE)))

xtab_csv_path <- file.path(here, "XX1234567_0_XTAB.csv")
con <- file(xtab_csv_path, open = "wb")
writeBin(xtab_raw, con)
close(con)

# =============================================================================
# XX1234567_0_XTAB.xlsx  -- xlsx substitutes for legacy .xls (README notes
# this). Identical LOGICAL content to the .csv twin: same values, but with
# the *correct* Unicode degree sign / micro sign (xlsx is natively Unicode,
# so it never suffers the CSV's legacy-encoding mojibake artifact - the
# mojibake is a property of the byte encoding, not the data). Adapter output
# (IR) from both files must be identical after normalise_lab_text() fixes
# the CSV's mojibake, ignoring source_ref (R-5.2 criterion).
# =============================================================================
if (!requireNamespace("openxlsx", quietly = TRUE)) {
  stop("openxlsx is required to generate the XTAB .xlsx fixture twin")
}
library(openxlsx)

clean_water_rows <- water_rows
# Row 15 (index) is the EC analyte row: replace placeholders with real chars.
ec_idx <- which(vapply(clean_water_rows, function(r) grepl("Electrical Conductivity", r[1]), logical(1)))
clean_water_rows[[ec_idx]][1] <- "Electrical Conductivity @ 25°C"
clean_water_rows[[ec_idx]][3] <- "µS/cm"

grid_rows <- c(clean_water_rows, soil_rows)
max_cols <- max(vapply(grid_rows, length, integer(1)))
grid <- t(vapply(grid_rows, function(r) pad(r, max_cols), character(max_cols)))
grid_df <- as.data.frame(grid, stringsAsFactors = FALSE)
names(grid_df) <- paste0("V", seq_len(max_cols))

wb <- createWorkbook()
addWorksheet(wb, "XTAB")
writeData(wb, "XTAB", grid_df, colNames = FALSE, na.string = "")
saveWorkbook(wb, file.path(here, "XX1234567_0_XTAB.xlsx"), overwrite = TRUE)

# =============================================================================
# XX1234567_0_ENMRG.CSV (UTF-8, +2 QC sample columns: LCS, MB)
# =============================================================================
enmrg_rows <- list(
  c("Client - Matrix:", "WATER"),
  c("Workgroup:", "XX1234567"),
  c("Project name/number:", "Test Project A / XX1234567"),
  c("Sample Type:", "", "", "", "", "REG", "REG", "REG", "LCS", "MB"),
  c("Sample Date:", "", "", "", "", "24/05/2025", "24/05/2025", "24/05/2025", "", ""),
  c("Client sample ID (1st):", "", "", "", "", "T.S01", "T.S02", "T.MW01", "", ""),
  c("Depth (m):", "", "", "", "", "", "", "", "", ""),
  c("", "", "", "", "ALS Sample number:", "XX1234567001", "XX1234567002",
    "XX1234567003", "QC-000001", "QC-000002"),
  c("Analyte grouping", "Analyte", "CAS Number", "Unit", "Limit of reporting",
    "", "", "", "", ""),
  c("EA005P: pH by PC Titrator", "", "", "", "", "", "", "", "", ""),
  c("Physical", "pH", "", "pH Unit", "0.01", "6.40", "----", "", "7.00", ""),
  c("EK040P: Fluoride by PC Titrator", "", "", "", "", "", "", "", "", ""),
  c("Anions", "Fluoride", "16984-48-8", "mg/L", "0.1", "<0.1", "2.3", ">2000", "0.5", ""),
  c("EA010P: Conductivity by PC Titrator", "", "", "", "", "", "", "", "", ""),
  c("Physical", "Electrical Conductivity @ 25°C", "", "µS/cm", "1",
    "185", "965", "", "", "600")
)
max_cols_enmrg <- max(vapply(enmrg_rows, length, integer(1)))
enmrg_lines <- vapply(enmrg_rows, function(r) csv_row(pad(r, max_cols_enmrg)), character(1))
enmrg_text <- paste(enmrg_lines, collapse = "\r\n")
enmrg_text <- paste0(enmrg_text, "\r\n")
con <- file(file.path(here, "XX1234567_0_ENMRG.CSV"), open = "wb")
writeBin(charToRaw(enc2utf8(enmrg_text)), con)
close(con)

# =============================================================================
# ZZ9999999_0_XTAB.csv -- filename/Workgroup mismatch precedence fixture.
# Filename says ZZ9999999; Workgroup: cell says XX1234567. Work order
# resolution must prefer the Workgroup cell + record a warning (R-5.3). Also
# doubles as the d/m/y disambiguation fixture (PLAN-05 R-5.1): the Sample
# Date "05/01/2026" is only unambiguous under d/m/y (-> 5 January); read as
# m/d/y it would be 1 May - the load-bearing check that the crosstab adapter
# tags this cell with the "crosstab" (d/m/y) parse_lab_datetime() format.
# =============================================================================
mismatch_rows <- list(
  c("Matrix:", "WATER"),
  c("Workgroup:", "XX1234567"),
  c("Sample Type:", "", "", "", "REG"),
  c("Sample Date:", "", "", "", "05/01/2026"),
  c("Client sample ID (1st):", "", "", "", "T.S01"),
  c("", "", "", "ALS Sample Number:", "ZZ9999999001"),
  c("Analyte", "CAS Number", "Unit", "Limit of reporting", ""),
  c("EA005P: pH by PC Titrator", "", "", "", ""),
  c("pH", "", "pH Unit", "0.01", "6.90")
)
max_cols_mismatch <- max(vapply(mismatch_rows, length, integer(1)))
mismatch_lines <- vapply(mismatch_rows, function(r) csv_row(pad(r, max_cols_mismatch)), character(1))
mismatch_text <- paste(mismatch_lines, collapse = "\r\n")
mismatch_text <- paste0(mismatch_text, "\r\n")
con <- file(file.path(here, "ZZ9999999_0_XTAB.csv"), open = "wb")
writeBin(charToRaw(mismatch_text), con)  # pure ASCII, encoding-neutral
close(con)

# =============================================================================
# XX1234567_1_XTAB.csv -- revision-1 supersede fixture (FIXTURES.md "Cross-plan
# expectations" / PLAN-10 R-10.4). Identical to the _0_ WATER section except
# T.S01's Fluoride result changes from "<0.1" to "0.3" mg/L. Re-ingesting this
# at revision 1 (> recorded revision 0) must supersede the committed value in
# place (A12). Single WATER section; same latin-1 mojibake bytes as _0_.
# =============================================================================
rev1_rows <- water_rows
fluoride_idx <- which(vapply(rev1_rows, function(r) identical(r[1], "Fluoride"), logical(1)))
rev1_rows[[fluoride_idx]][5] <- "0.3"   # column 5 = first sample (T.S01)
max_cols_rev1 <- max(vapply(rev1_rows, length, integer(1)))
rev1_lines <- vapply(rev1_rows, function(r) csv_row(pad(r, max_cols_rev1)), character(1))
rev1_text <- paste0(paste(rev1_lines, collapse = "\r\n"), "\r\n")
rev1_raw <- charToRaw(rev1_text)
rev1_raw <- splice_all(rev1_raw, DEG_TOKEN, as.raw(0xA1))
rev1_raw <- splice_all(rev1_raw, MICRO_TOKEN, as.raw(0xB5))
stopifnot(!any(grepl("@@", rawToChar(rev1_raw), fixed = TRUE)))
con <- file(file.path(here, "XX1234567_1_XTAB.csv"), open = "wb")
writeBin(rev1_raw, con)
close(con)

message("crosstab fixtures written to ", normalizePath(here))
