# Deterministic generator for tests/testthat/fixtures/esdat/*
#
# Reproduces the ESdat (EScIS) delivery fixtures pinned in
# dev/plans/FIXTURES.md ("ESdat (plan 04, fixtures/esdat/)") and
# dev/plans/PLAN-04-adapter-esdat.md. Re-run with:
#   Rscript tests/testthat/fixtures/esdat/generate.R
# from the package root (or any working directory - paths are relative to
# this script's own location).

this_file_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
here <- if (length(this_file_arg) == 1) {
  dirname(normalizePath(sub("^--file=", "", this_file_arg)))
} else {
  # Fallback: assume Rscript was launched from the package root.
  "tests/testthat/fixtures/esdat"
}

# ---- Chemistry2e.CSV (UTF-8 with BOM) --------------------------------------
# Columns pinned in FIXTURES.md (Chemistry2e), including `Method_Type` between
# Result_Type and Method_Name. ADJUDICATED (A15): the real ALS ESdat header
# carries Method_Type (verified against the live corpus), and match() is a
# header-byte fingerprint, so it MUST be present or the adapter rejects real
# files. Method_Type holds a human method name (e.g. "pH by PC Titrator")
# while Method_Name holds the coded method ("EA005P: pH by PC Titrator").
chem_header <- c(
  "SampleCode", "ChemCode", "OriginalChemName", "Prefix", "Result",
  "Result_Unit", "Total_or_Filtered", "Result_Type", "Method_Type",
  "Method_Name", "Extraction_Date", "Analysed_Date", "EQL", "EQL_Units",
  "Comments", "Lab_Qualifier", "UCL", "LCL"
)

# The row literals below are written in the pre-Method_Type 17-field shape
# (Method_Name at index 9); splice a derived Method_Type in at index 9 so the
# rows become the 18-field header shape. Method_Type = Method_Name with the
# leading "CODE: " stripped; empty when Method_Name is empty.
splice_method_type <- function(row) {
  mname <- row[[9]]
  mtype <- if (nzchar(mname)) sub("^[A-Za-z0-9]+:\\s*", "", mname) else ""
  append(row, mtype, after = 8)
}

chem_rows <- list(
  c("XX1234567001", "", "pH Value", "", "6.40", "pH Unit", "T", "Numeric",
    "EA005P: pH by PC Titrator", "", "26 May 2025", "0.01", "pH Unit",
    "", "", "", ""),
  c("XX1234567001", "16984-48-8", "Fluoride", "<", "0.1", "mg/L", "T",
    "Numeric", "EK040P: Fluoride by PC Titrator", "26 May 2025",
    "26 May 2025", "0.1", "mg/L", "", "", "", ""),
  c("XX1234567001", "", "Electrical Conductivity @ 25°C", "", "185",
    "µS/cm", "T", "Numeric", "EA010P: Conductivity by PC Titrator",
    "26 May 2025", "26 May 2025", "1", "µS/cm", "", "", "", ""),
  c("XX1234567002", "16984-48-8", "Fluoride", "", "2.3", "mg/L", "T",
    "Numeric", "EK040P: Fluoride by PC Titrator", "26 May 2025",
    "26 May 2025", "0.1", "mg/L", "", "", "", ""),
  c("XX1234567002", "", "Electrical Conductivity @ 25°C", "", "965",
    "µS/cm", "T", "Numeric", "EA010P: Conductivity by PC Titrator",
    "26 May 2025", "26 May 2025", "1", "µS/cm", "", "J", "", ""),
  c("XX1234567003", "", "Fluoride", ">", "2000", "mg/L", "T", "Numeric",
    "EK040P: Fluoride by PC Titrator", "26 May 2025", "26 May 2025", "0.1",
    "mg/L", "", "", "", ""),
  c("XX1234567003", "", "Observation", "", "Clear, low flow", "", "T",
    "Text", "", "26 May 2025", "26 May 2025", "", "", "Field observation",
    "", "", ""),
  c("QC-000001", "16984-48-8", "Fluoride", "", "0.5", "mg/L", "T", "Numeric",
    "EK040P: Fluoride by PC Titrator", "26 May 2025", "26 May 2025", "0.1",
    "mg/L", "Duplicate check", "", "", ""),
  c("QC-000002", "", "pH Value", "", "7.00", "pH Unit", "T", "Numeric",
    "EA005P: pH by PC Titrator", "26 May 2025", "26 May 2025", "0.01",
    "pH Unit", "", "", "", ""),
  c("YY0000001", "16984-48-8", "Fluoride", "", "1.0", "mg/L", "T", "Numeric",
    "EK040P: Fluoride by PC Titrator", "26 May 2025", "26 May 2025", "0.1",
    "mg/L", "", "", "", "")
)
chem_rows <- lapply(chem_rows, splice_method_type)
stopifnot(all(vapply(chem_rows, length, integer(1)) == length(chem_header)))

csv_escape_field <- function(x) {
  if (grepl('[,"\n]', x, useBytes = TRUE)) {
    paste0('"', gsub('"', '""', x, fixed = TRUE), '"')
  } else {
    x
  }
}
csv_line <- function(fields) paste(vapply(fields, csv_escape_field, character(1)), collapse = ",")

chem_lines <- c(csv_line(chem_header), vapply(chem_rows, csv_line, character(1)))
chem_text <- paste(chem_lines, collapse = "\r\n")
chem_text <- paste0(chem_text, "\r\n")

# A35 rework (2026-07-15): real Chemistry2e/Sample2e CSVs are latin-1, not
# UTF-8 - `°`/`µ` (typed here as ordinary UTF-8 characters, since this
# script's own source is UTF-8) must be written to the fixture as their raw
# single-byte latin-1 codepoints (0xB0/0xB5), NOT the two-byte UTF-8
# sequences (0xC2 0xB0/0xC2 0xB5) a plain `enc2utf8()`+`charToRaw()` write
# would produce. `iconv(..., to = "latin1")` performs the actual byte
# transcoding (verified: the degree sign becomes the single byte 0xB0).
# The leading UTF-8 BOM is kept regardless - real-world files sometimes
# staple a UTF-8 BOM onto an otherwise latin-1 body (PLAN-04 "Encoding -
# CORRECTED (A35)"), and R-4.1's "(with BOM)" test exercises exactly that.
chem_text_latin1 <- iconv(chem_text, from = "UTF-8", to = "latin1")
stopifnot(identical(Encoding(chem_text_latin1), "latin1"))

chem_path <- file.path(here, "PROJ_A.ESDAT_XX1234567_0.Chemistry2e.CSV")
con <- file(chem_path, open = "wb")
writeBin(as.raw(c(0xEF, 0xBB, 0xBF)), con)                 # UTF-8 BOM
writeBin(charToRaw(chem_text_latin1), con)
close(con)

# ---- Sample2e.CSV (UTF-8, no BOM) ------------------------------------------
sample_header <- c(
  "SampleCode", "Sampled_Date_Time", "Field_ID", "Blank1", "Depth", "Blank2",
  "Matrix_Type", "Sample_Type", "Parent_Sample", "Blank3", "SDG", "Lab_Name",
  "Lab_SampleID", "Lab_Comments", "Lab_Report_Number"
)
sample_rows <- list(
  c("XX1234567001", "24 May 2025 11:45", "T.S01", "", "", "", "WATER",
    "Normal", "", "", "", "ALSE-Sydney", "XX1234567001", "", "XX1234567"),
  c("XX1234567002", "24 May 2025 11:10", "T.S02", "", "", "", "WATER",
    "Normal", "", "", "", "ALSE-Sydney", "XX1234567002", "", "XX1234567"),
  c("XX1234567003", "24 May 2025 11:00", "T.MW01", "", "", "", "WATER",
    "Normal", "", "", "", "ALSE-Sydney", "XX1234567003", "", "XX1234567"),
  c("QC-000001", "", "", "", "", "", "WATER", "LCS", "", "", "",
    "ALSE-Sydney", "QC-000001", "", "XX1234567"),
  c("QC-000002", "", "", "", "", "", "WATER", "MB", "", "", "",
    "ALSE-Sydney", "QC-000002", "", "XX1234567"),
  c("YY0000001", "20 May 2025 09:00", "T.OFFSITE", "", "", "", "WATER",
    "NCP", "", "", "", "ALSE-Sydney", "YY0000001", "", "YY0000001")
)
stopifnot(all(vapply(sample_rows, length, integer(1)) == length(sample_header)))
sample_lines <- c(csv_line(sample_header), vapply(sample_rows, csv_line, character(1)))
writeLines(sample_lines, file.path(here, "PROJ_A.ESDAT_XX1234567_0.Sample2e.CSV"),
           sep = "\r\n", useBytes = FALSE)

# ---- lone PROJ_B Sample2e.CSV -----------------------------------------------
projb_rows <- list(
  c("XX7654321001", "26 May 2025 10:30", "T.S01", "", "", "", "WATER",
    "Normal", "", "", "", "ALSE-Sydney", "XX7654321001", "", "XX7654321")
)
projb_lines <- c(csv_line(sample_header), vapply(projb_rows, csv_line, character(1)))
writeLines(projb_lines, file.path(here, "PROJ_B.ESDAT_XX7654321_0.Sample2e.CSV"),
           sep = "\r\n", useBytes = FALSE)

# ---- Header.XML (EScIS namespace) ------------------------------------------
header_xml <- paste0(
  '<?xml version="1.0" encoding="UTF-8"?>\n',
  '<ESdat xmlns="http://www.escis.com.au/2013/XML" fileType="eLabResultsHeader">\n',
  '  <LabReport Lab_Report_Number="XX1234567" Date_Reported="2025-05-28" ',
  'Project_ID="PROJ_A" Lab_Name="ALSE-Sydney" Lab_Signatory="J. Signatory">\n',
  '    <eCoCs>\n',
  '      <eCoC COC_Number="COC-0001"/>\n',
  '    </eCoCs>\n',
  '  </LabReport>\n',
  '</ESdat>\n'
)
writeLines(header_xml, file.path(here, "PROJ_A.ESDAT_XX1234567_0.Header.XML"), sep = "")

# ---- Non-ESdat XML (for the R-4.4 hard-fail negative test) -----------------
not_esdat_xml <- paste0(
  '<?xml version="1.0" encoding="UTF-8"?>\n',
  '<catalog xmlns="http://example.com/2020/XML">\n',
  '  <book id="1"><title>Not an ESdat file</title></book>\n',
  '</catalog>\n'
)
writeLines(not_esdat_xml, file.path(here, "NOT_ESDAT.xml"), sep = "")

# ---- Random CSV (for R-4.1 negative match tests) ---------------------------
random_csv <- c(
  "id,name,value",
  "1,widget,42",
  "2,gadget,7"
)
writeLines(random_csv, file.path(here, "random.csv"), sep = "\r\n")

# ---- Chemistry2e with an unparseable Analysed_Date (R-4.5) -----------------
# FIXTURES.md's pinned 10-row Chemistry2e table always uses the clean
# "26 May 2025" date, so R-4.5's "an unparseable date lands in warnings ...
# the row still emitted with analysed_date NA" criterion has no data to hit
# in the pinned fixture. This is a documented addition (see
# dev/plans/PLAN-CHANGE-REQUESTS.md) - a minimal extra delivery, same header,
# one row with a garbled Analysed_Date.
baddate_rows <- list(
  c("XX5555555001", "", "pH Value", "", "6.90", "pH Unit", "T", "Numeric",
    "EA005P: pH by PC Titrator", "", "31 Undecember 2025", "0.01", "pH Unit",
    "", "", "", "")
)
baddate_rows <- lapply(baddate_rows, splice_method_type)
baddate_lines <- c(csv_line(chem_header), vapply(baddate_rows, csv_line, character(1)))
writeLines(baddate_lines, file.path(here, "BADDATE.ESDAT_XX5555555_0.Chemistry2e.CSV"),
           sep = "\r\n", useBytes = FALSE)

# ---- Deliberately corrupted ESdat Chemistry2e CSV (plan-09/10) -------------
# REWORKED (A35, 2026-07-15): the original version of this fixture relied on
# a bare, invalid-on-its-own UTF-8 continuation byte (0x80) to trip base R's
# nchar()/toupper(). That premise is now dead - under the latin-1 locale the
# adapter must use for real Chemistry2e/Sample2e files (A35), EVERY byte
# 0x00-0xFF is a valid latin-1 codepoint, so 0x80 just decodes quietly (as
# U+0080) and no read/normalise step errors on it. A27 was refined
# accordingly: a file is `failed` only on genuine structural failure
# (unreadable, or invalid even under latin-1), not merely for a non-UTF-8
# byte.
#
# The new corruption is a genuinely unterminated quoted field: the
# OriginalChemName cell opens with `"` but the field, and the row, are never
# closed - the character never reappears anywhere else in the file. This is
# realistic corruption (a truncated CSV export / a stray unescaped `"` in a
# text field) and is invalid CSV structure under ANY encoding, latin-1
# included: RFC 4180 requires every quoted field's opening quote to be
# matched by a closing quote (and an escaped `""` still contributes an even
# number to the total), so a well-formed CSV always has an EVEN total count
# of `"` bytes. This file's total count is ONE (odd) - deliberately.
# Empirically, `readr::read_csv()` itself does *not* raise an R error for
# this on a plain file path - it silently swallows the rest of the file into
# one runaway field and returns a suspicious near-empty/zero-row result with
# no warning. That silent failure is precisely the "genuine structural
# corruption" A27/A35 need surfaced loudly, so `R/adapter-esdat.R` checks
# quote-parity explicitly (`.st_esdat_check_quote_parity()`) before every
# ESdat CSV body read and aborts with class `sampletidy_parse_error` on an
# odd count - this is what the plan-09/10 "adapter crash -> file `failed`"
# scenario now exercises. See "R-4.2: corrupted CSV data" in
# test-adapter-esdat.R.
#
# The header line is written verbatim and unmodified (so match() still
# fingerprints this file as an exact ESdat Chemistry2e file and the router
# *claims* it for the esdat adapter - a genuinely unclaimed/no-match file
# would never reach "claimed -> failed").
corrupt_path <- file.path(here, "CORRUPT.ESDAT_XX0000000_0.Chemistry2e.CSV")
con <- file(corrupt_path, open = "wb")
writeBin(charToRaw(paste(chem_header, collapse = ",")), con)
writeBin(as.raw(c(0x0d, 0x0a)), con)
writeBin(charToRaw(paste0(
  'XX0000000001,,"pH Value,,6.40,pH Unit,T,Numeric,pH by PC Titrator,',
  "EA005P: pH by PC Titrator,,26 May 2025,0.01,pH Unit,,,,\r\n"
)), con)
close(con)
corrupt_bytes <- readBin(corrupt_path, "raw", n = file.info(corrupt_path)$size)
stopifnot(sum(corrupt_bytes == as.raw(0x22)) %% 2 == 1) # odd quote count, deliberately

message("esdat fixtures written to ", normalizePath(here))
