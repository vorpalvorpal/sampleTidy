# Deterministic generator for tests/testthat/fixtures/spreadsheetml/*.
# Re-run with: Rscript tests/testthat/fixtures/spreadsheetml/make-spreadsheetml.R
#
# Why these fixtures live in their OWN directory (not fixtures/crosstab/):
# `build_e2e_input_dir()` (helper-corpus.R) and the R-10.1 router-matrix test
# copy/enumerate EVERY file in fixtures/{esdat,crosstab,acirl}. Putting these
# here keeps the new synthetic twins, the deliberately-malformed files and this
# generator out of the e2e pipeline corpus.
#
# What is modelled. Real ALS XTAB "`.XLS`" is SpreadsheetML 2003 XML (CONTRACT
# A37), e.g. fixtures/crosstab/ES2600185_0_XTAB.XLS and the real staged
# ES2623357_0_XTAB.XLS. Structure copied from those files (verified
# 2026-10-18):
#   - `<?xml version="1.0" encoding="ISO-8859-1"?>` then
#     `<ss:Workbook xmlns:ss="urn:schemas-microsoft-com:office:spreadsheet"
#     xmlns:fo=...>`, an `<ss:Styles>` block, then TWO worksheets:
#     "Client WATER - 1" (the data the `.csv` twin carries) and
#     "QC WATER - 1" (QC lots AND other clients' primary samples, e.g.
#     ES2600144001 - it is NOT in the `.csv` twin and must never be ingested).
#   - every cell is `ss:Type="String"`; `<` is written `&lt;`;
#   - the per-sample labels (`Sample Type:`, `ALS Sample Number:`, ...) are
#     `ss:MergeAcross="1"` cells spanning 0-based columns 3-4, so the first
#     sample value sits at column 5 - exactly where the `.csv` has it after
#     its empty gap column;
#   - blank cells appear as `<ss:Cell/>` or as
#     `<ss:Cell><ss:Data ss:Type="String"/></ss:Cell>`; blank rows as
#     `<ss:Row/>`; the table ends with one extra trailing `<ss:Row/>` that
#     the `.csv` does not have;
#   - some labels carry trailing "\n\t\t\t\t\t" whitespace inside ss:Data
#     (the `.csv` has trailing spaces instead; the parser trims both);
#   - degree and micro signs are raw ISO-8859-1 bytes 0xB0 / 0xB5. In the
#     `.csv` twin the same two characters are already destroyed on disk to
#     U+FFFD (bytes EF BF BD) - CONTRACT A34 / adapter-crosstab.R header -
#     and `normalise_lab_text()` repairs them to U+00B0 / U+00B5.
#   - `WorksheetOptions` in the default (excel) namespace after the table.
# Additionally (not seen in the two real files, but legal SpreadsheetML that
# a reader must honour): `ss:Index` on a Cell (1-based absolute column; the
# skipped columns are blank) and `ss:Index` on a Row (1-based absolute row;
# skipped rows are blank).
#
# Files written:
#   SX7654321_0_XTAB.csv  - the CSV twin (UTF-8, U+FFFD for degree/micro, as
#                           real XTAB.csv)
#   SX7654321_0_XTAB.XLS  - SpreadsheetML encoding the SAME grid in its first
#                           worksheet, using ss:Index cell + row gaps, plus a
#                           QC worksheet that must be ignored
#   SX0000001_0_XTAB.XLS  - malformed: SpreadsheetML truncated mid-row
#   SX0000002_0_XTAB.XLS  - well-formed XML that is NOT SpreadsheetML (carries
#                           "Matrix:"/"Workgroup:" text so a naive sniff would
#                           claim it)
#   SX0000003_0_XTAB.XLS  - well-formed SpreadsheetML whose first row is
#                           ENMRG-style "Client - Matrix:" (als_xtab must not
#                           claim it)
#   SX0000004_0_XTAB.XLS  - binary garbage (neither XML nor BIFF)
# All identifiers are synthetic (SX*, T.S0n, "Test Project S").

this_file_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
here <- if (length(this_file_arg) == 1) {
  dirname(normalizePath(sub("^--file=", "", this_file_arg)))
} else {
  "tests/testthat/fixtures/spreadsheetml"
}

DEG <- "°"
MU <- "µ"
NCOL <- 8L

# ---------------------------------------------------------------------------
# The shared grid (one character vector per row, 8 columns, "" = blank).
# Columns (0-based): 0 analyte/section label, 1 CAS/section value, 2 unit,
# 3 LOR / per-sample label, 4 gap, 5-7 samples 001-003.
# ---------------------------------------------------------------------------
client_grid <- list(
  c("Matrix:", "WATER", "", "Sample Type:", "", "REG", "REG", "REG"),
  c("Workgroup:", "SX7654321", "", "ALS Sample Number:", "", "SX7654321001", "SX7654321002", "SX7654321003"),
  c("Project name/number:", "Test Project S", "", "Sample Date:", "", "03/02/2026", "03/02/2026", "04/02/2026"),
  c("", "", "", "Client sample ID (1st):", "", "T.S01", "T.S02", "T.S03"),
  c("", "", "", "Client sample ID (2nd):", "", "", "", ""),
  c("", "", "", "Site:", "", "Site S", "Site S", "Site S"),
  c("", "", "", "", "", "", "", ""),
  c("Analyte grouping/Analyte", "CAS Number", "Unit", "Limit of reporting", "", "", "", ""),
  c("", "", "", "", "", "", "", ""),
  c("EA005P: pH by PC Titrator", "", "", "", "", "", "", ""),
  c("pH Value", "", "pH Unit", "0.01", "", "6.40", "----", "7.10"),
  c("", "", "", "", "", "", "", ""),
  c("EA010P: Conductivity by PC Titrator", "", "", "", "", "", "", ""),
  c(paste0("Electrical Conductivity @ 25", DEG, "C"), "", paste0(MU, "S/cm"), "1", "", "185", "", "600"),
  c("", "", "", "", "", "", "", ""),
  c("EK040P: Fluoride by PC Titrator", "", "", "", "", "", "", ""),
  c("Fluoride", "16984-48-8", "mg/L", "0.1", "", "<0.1", "0.5", "<0.1"),
  c("", "", "", "", "", "", "", ""),
  c("EK059G: Nitrite & Nitrate as N (NOx) by Discrete Analyser", "", "", "", "", "", "", ""),
  c("Nitrite + Nitrate as N", "", "mg/L", "0.01", "", "0.14", "<0.01", "0.38")
)
stopifnot(all(lengths(client_grid) == NCOL))

# ---------------------------------------------------------------------------
# CSV twin: bytes exactly as real XTAB.csv - CRLF, no trailing newline on the
# last line, degree/micro destroyed to U+FFFD (EF BF BD).
# ---------------------------------------------------------------------------
csv_field <- function(x) {
  ifelse(grepl('[,"\n]', x), paste0('"', gsub('"', '""', x, fixed = TRUE), '"'), x)
}
csv_lines <- vapply(client_grid, function(r) {
  r <- gsub(DEG, "�", r, fixed = TRUE)
  r <- gsub(MU, "�", r, fixed = TRUE)
  paste(csv_field(r), collapse = ",")
}, character(1))
csv_text <- enc2utf8(paste(csv_lines, collapse = "\r\n"))
con <- file(file.path(here, "SX7654321_0_XTAB.csv"), open = "wb")
writeBin(charToRaw(csv_text), con)
close(con)

# ---------------------------------------------------------------------------
# SpreadsheetML helpers.
# ---------------------------------------------------------------------------
xml_esc <- function(x) {
  x <- gsub("&", "&amp;", x, fixed = TRUE)
  x <- gsub("<", "&lt;", x, fixed = TRUE)
  gsub(">", "&gt;", x, fixed = TRUE)
}
# One cell. `value` NA -> `<ss:Cell/>`; "" -> empty String Data element.
cell <- function(value, index = NA, merge = NA, style = NA) {
  attrs <- character(0)
  if (!is.na(index)) attrs <- c(attrs, sprintf('ss:Index="%d"', index))
  if (!is.na(merge)) attrs <- c(attrs, sprintf('ss:MergeAcross="%d"', merge))
  if (!is.na(style)) attrs <- c(attrs, sprintf('ss:StyleID="%s"', style))
  open <- paste(c("<ss:Cell", attrs), collapse = " ")
  if (is.na(value)) {
    return(paste0(open, "/>"))
  }
  data <- if (identical(value, "")) {
    '<ss:Data ss:Type="String"/>'
  } else {
    sprintf('<ss:Data ss:Type="String">%s</ss:Data>', xml_esc(value))
  }
  paste0(open, ">", data, "</ss:Cell>")
}
row <- function(cells, index = NA) {
  if (length(cells) == 0) {
    return(if (is.na(index)) "<ss:Row/>" else sprintf('<ss:Row ss:Index="%d"/>', index))
  }
  open <- if (is.na(index)) "<ss:Row>" else sprintf('<ss:Row ss:Index="%d">', index)
  paste0(open, paste(cells, collapse = ""), "</ss:Row>")
}
# A row written the way the real files write it: every column present, the
# per-sample label merged across columns 3-4 (so column 4 is not emitted).
real_style_row <- function(g, label_merge = TRUE, blank_as = NA) {
  out <- character(0)
  c <- 1L
  while (c <= length(g)) {
    v <- g[[c]]
    v <- if (nzchar(v)) v else blank_as
    if (label_merge && c == 4L && nzchar(g[[4]])) {
      out <- c(out, cell(v, merge = 1, style = "3"))
      c <- c + 2L
      next
    }
    out <- c(out, cell(v))
    c <- c + 1L
  }
  # trim trailing blank cells, as the real exporter does for method rows
  row(out)
}

workbook <- function(sheets) {
  styles <- paste0(
    '<ss:Styles><ss:Style ss:ID="1"><ss:Font ss:Bold="1"/></ss:Style>',
    '<ss:Style ss:ID="3"><ss:Alignment ss:Horizontal="Right" ss:Vertical="Bottom" ss:Indent="1"/>',
    '<ss:Borders/><ss:Font ss:Bold="1"/><ss:Interior/><ss:NumberFormat/><ss:Protection/></ss:Style>',
    '<ss:Style ss:ID="4"><ss:Alignment ss:Horizontal="Center" ss:Vertical="Bottom"/><ss:Font ss:Bold="1"/></ss:Style>',
    '<ss:Style ss:ID="6"><ss:Font ss:Bold="1"/></ss:Style></ss:Styles>'
  )
  ws_opts <- paste0(
    '<WorksheetOptions xmlns="urn:schemas-microsoft-com:office:excel"><FreezePanes/>',
    "<FrozenNoSplit/><SplitHorizontal>11</SplitHorizontal><ActivePane>0</ActivePane>",
    "<ProtectObjects>False</ProtectObjects></WorksheetOptions>"
  )
  cols <- paste(rep('<ss:Column ss:Width="80"/>', NCOL), collapse = "")
  body <- vapply(names(sheets), function(nm) {
    paste0(
      sprintf('<ss:Worksheet ss:Name="%s"><ss:Table>', nm), cols,
      paste(sheets[[nm]], collapse = "\n"),
      "</ss:Table>", ws_opts, "</ss:Worksheet>"
    )
  }, character(1))
  paste0(
    '<?xml version="1.0" encoding="ISO-8859-1"?>',
    '<ss:Workbook xmlns:ss="urn:schemas-microsoft-com:office:spreadsheet" ',
    'xmlns:fo="http://www.w3.org/1999/XSL/Format">',
    styles, paste(body, collapse = "\n"), "\n</ss:Workbook>"
  )
}
write_latin1 <- function(text, path) {
  bytes <- iconv(text, from = "UTF-8", to = "latin1", toRaw = TRUE)[[1]]
  stopifnot(!is.null(bytes))
  con <- file(path, open = "wb")
  writeBin(bytes, con)
  close(con)
}

g <- client_grid
client_rows <- c(
  # r1: real style (blank col 2 as <ss:Cell/>, merged label)
  real_style_row(g[[1]]),
  # r2: cell ss:Index gap - col 2 (0-based) not emitted; label jumps to Index 4
  row(c(cell(g[[2]][1], style = "3"), cell(g[[2]][2]),
        cell(g[[2]][4], index = 4, merge = 1, style = "3"),
        cell(g[[2]][6]), cell(g[[2]][7]), cell(g[[2]][8]))),
  # r3: real style, but the first sample cell carries a (redundant, consistent)
  #     absolute ss:Index="6" right after the merged label
  row(c(cell(g[[3]][1], style = "3"), cell(g[[3]][2]), cell(NA),
        cell(g[[3]][4], merge = 1, style = "3"),
        cell(g[[3]][6], index = 6), cell(g[[3]][7]), cell(g[[3]][8]))),
  # r4: leading blank columns 0-2 skipped entirely via ss:Index="4"
  row(c(cell(g[[4]][4], index = 4, merge = 1, style = "3"),
        cell(g[[4]][6]), cell(g[[4]][7]), cell(g[[4]][8]))),
  # r5: blank sample cells as empty String Data elements
  real_style_row(g[[5]], blank_as = ""),
  # r6: label with trailing newline+tabs inside ss:Data (as real "Site:")
  row(c(cell(NA), cell(NA), cell(NA),
        cell("Site:\n\t\t\t\t\t", merge = 1, style = "3"),
        cell(g[[6]][6]), cell(g[[6]][7]), cell(g[[6]][8]))),
  # r7: blank row
  row(character(0)),
  # r8: analyte header
  real_style_row(g[[8]], label_merge = FALSE),
  # r9: NOT EMITTED - r10 carries ss:Index="10" on the Row (row gap)
  # r10: method-group row, row-level ss:Index
  row(c(cell(g[[10]][1], style = "1")), index = 10),
  # r11: pH, with "----"
  row(c(cell(g[[11]][1]), cell(""), cell(g[[11]][3]), cell(g[[11]][4]), cell(""),
        cell(g[[11]][6], style = "6"), cell(g[[11]][7], style = "6"), cell(g[[11]][8], style = "6"))),
  row(character(0)),
  row(c(cell(g[[13]][1], style = "1"))),
  # r14: EC - degree/micro as latin-1 bytes; CAS column skipped via Index=3,
  #      gap column skipped via Index=6, sample 002 (col 6, 0-based) skipped
  #      via Index=8 on sample 003
  row(c(cell(g[[14]][1]), cell(g[[14]][3], index = 3), cell(g[[14]][4]),
        cell(g[[14]][6], index = 6), cell(g[[14]][8], index = 8))),
  row(character(0)),
  row(c(cell(g[[16]][1], style = "1"))),
  # r17: Fluoride with "<" values (&lt; in XML)
  real_style_row(g[[17]], label_merge = FALSE),
  row(character(0)),
  # r19: method-group text containing "&" (&amp; in XML)
  row(c(cell(g[[19]][1], style = "1"))),
  real_style_row(g[[20]], label_merge = FALSE),
  # trailing blank row, as in the real export (the .csv has no such line)
  "         <ss:Row/>"
)

qc_rows <- c(
  row(c(cell("Matrix:", style = "3"), cell("WATER"), cell(NA),
        cell("Sample Type:", merge = 1, style = "3"),
        cell("LCS"), cell("MB"), cell("REG"))),
  row(c(cell("Workgroup:", style = "3"), cell("SX7654321"), cell(NA),
        cell("ALS Sample Number:", merge = 1, style = "3"),
        cell("QC-1111111-001"), cell("QC-1111111-002"), cell("ZZ1111111001"))),
  row(c(cell(NA), cell(NA), cell(NA), cell("Sample Date:", merge = 1, style = "3"),
        cell("05/02/2026"), cell("05/02/2026"), cell("01/02/2026"))),
  row(character(0)),
  real_style_row(c("Analyte grouping/Analyte", "CAS Number", "Unit", "Limit of reporting", "", "", "", ""),
                 label_merge = FALSE),
  row(character(0)),
  row(c(cell("EA005P: pH by PC Titrator", style = "1"))),
  real_style_row(c("pH Value", "", "pH Unit", "0.01", "", "7.00", "----", "6.55"), label_merge = FALSE)
)

xls_text <- workbook(list("Client WATER - 1" = client_rows, "QC WATER - 1" = qc_rows))
write_latin1(xls_text, file.path(here, "SX7654321_0_XTAB.XLS"))

# ---------------------------------------------------------------------------
# Malformed / non-claimable .XLS files.
# ---------------------------------------------------------------------------
# SX0000001: truncated SpreadsheetML - the first rows (Matrix:, Workgroup:)
# are intact, then the file stops mid-element.
trunc_text <- workbook(list("Client WATER - 1" = client_rows))
trunc_text <- gsub("SX7654321", "SX0000001", trunc_text, fixed = TRUE)
cut_at <- regexpr("Analyte grouping", trunc_text, fixed = TRUE)[[1]]
write_latin1(substr(trunc_text, 1, cut_at + 5), file.path(here, "SX0000001_0_XTAB.XLS"))

# SX0000002: well-formed XML, wrong vocabulary (not the SpreadsheetML
# namespace), but containing the marker text a naive sniff would accept.
write_latin1(paste0(
  '<?xml version="1.0" encoding="ISO-8859-1"?>',
  "<Report><Row><Cell>Matrix:</Cell><Cell>WATER</Cell></Row>",
  "<Row><Cell>Workgroup:</Cell><Cell>SX0000002</Cell></Row></Report>"
), file.path(here, "SX0000002_0_XTAB.XLS"))

# SX0000003: well-formed SpreadsheetML, ENMRG-style first row.
enmrg_rows <- c(
  row(c(cell("Client - Matrix:", style = "3"), cell("WATER"), cell(NA), cell(NA),
        cell("Sample Type:", style = "3"), cell("REG"))),
  row(c(cell("Workgroup:", style = "3"), cell("SX0000003"), cell(NA), cell(NA),
        cell("ALS Sample number:", style = "3"), cell("SX0000003001"))),
  row(c(cell("Analyte grouping/Analyte"), cell("CAS Number"), cell("Units"), cell("LOR"))),
  row(c(cell("EA005P: pH by PC Titrator"))),
  row(c(cell("pH Value"), cell(NA), cell("pH Unit"), cell("0.01"), cell(NA), cell("6.40")))
)
write_latin1(workbook(list("Client WATER - 1" = enmrg_rows)), file.path(here, "SX0000003_0_XTAB.XLS"))

# SX0000004: binary garbage - neither XML nor an OLE2/BIFF workbook.
set.seed(20261018)
con <- file(file.path(here, "SX0000004_0_XTAB.XLS"), open = "wb")
writeBin(as.raw(c(0x00, 0xff, 0x13, sample(0:255, 509, replace = TRUE))), con)
close(con)

invisible(TRUE)
