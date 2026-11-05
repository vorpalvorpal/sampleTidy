# Deterministic generator for tests/testthat/fixtures/qci/*_QCI.txt.
# Re-run with: Rscript tests/testthat/fixtures/qci/generate.R
#
# The eight `*_QCI.txt` fixtures are SYNTHETIC. Each stands in for the
# `pdftotext -layout` text of an ALS "QA/QC Compliance Assessment" (QCI) PDF
# and reproduces one layout the parser has to handle (helper-qci.R,
# test-qci-parse.R): page breaks as form feeds, the two-column page-1 key :
# value grid, the Summary-of-Outliers bullets, QC tables whose cells are split
# by x-position (wrapped method names and analytes, lab IDs on their own line
# or glued to the method name, "--" lab-ID separators), holding-time tables
# with comma-continued client-ID lists, older and newer frequency-table
# layouts, and the û / ü evaluation glyphs.
#
# Every client, project, client sample ID, other work order's lab ID, QC lot,
# recovery, control limit and QC-frequency count in templates/ is invented.
# The ALS boilerplate (method names and summaries, column headings, notes) is
# the lab's generic report text. A template leaves two things to this script:
#   {{WO}}    the fixture's work order (also the prefix of its own lab IDs)
#   {{D+n}}   the fixture's Date Samples Received plus n days, as dd-Mon-yyyy
# Column x-positions are part of what is under test, so a placeholder is
# filled WITHOUT moving anything to its right: the first run of two or more
# spaces after the filled value gives up the extra characters.

this_file_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
here <- if (length(this_file_arg) == 1) {
  dirname(normalizePath(sub("^--file=", "", this_file_arg)))
} else {
  "tests/testthat/fixtures/qci"
}

fixtures <- list(
  list(wo = "ES2070220", received = "2020-04-13"),  # LCS x2 (wrapped comment) + MS
  list(wo = "ES2070230", received = "2020-04-18"),  # fully clean QCI
  list(wo = "ES2070240", received = "2020-08-25"),  # short surrogate bullet, one LCS
  list(wo = "ES2070250", received = "2020-08-26"),  # own-sample MS rows, lab ID alone
  list(wo = "ES2070260", received = "2020-08-06"),  # 11 pages, comma-continued IDs
  list(wo = "ES2370310", received = "2023-05-23"),  # frequency outliers only
  list(wo = "ES2570530", received = "2025-06-10"),  # numeric MS failures, glued lab ID
  list(wo = "ES2670640", received = "2026-03-08")   # MS not determined, holding time
)

fmt_date <- function(d) {
  d <- as.POSIXlt(d)
  sprintf("%02d-%s-%d", d$mday, month.abb[d$mon + 1L], d$year + 1900L)
}

placeholder_re <- "\\{\\{(WO|D[+-][0-9]+)\\}\\}"

fill_line <- function(line, wo, received) {
  repeat {
    m <- regexpr(placeholder_re, line, perl = TRUE)
    if (m < 0) return(line)
    ph <- regmatches(line, m)
    key <- substr(ph, 3L, nchar(ph) - 2L)
    val <- if (key == "WO") wo else fmt_date(received + as.integer(sub("^D", "", key)))
    start <- as.integer(m)
    line <- paste0(substr(line, 1L, start - 1L), val,
                   substr(line, start + nchar(ph), nchar(line)))
    delta <- nchar(val) - nchar(ph)
    stopifnot(delta > 0)
    after <- start + nchar(val)
    rest <- substr(line, after, nchar(line))
    r <- regexpr(" {2,}", rest)
    if (r > 0) {
      len <- attr(r, "match.length")
      stopifnot(len - delta >= 2)
      p <- after + as.integer(r) - 1L
      line <- paste0(substr(line, 1L, p - 1L), strrep(" ", len - delta),
                     substr(line, p + len, nchar(line)))
    }
  }
}

for (fx in fixtures) {
  tmpl <- file.path(here, "templates", sprintf("%s_0_QCI.txt.in", fx$wo))
  txt <- readChar(tmpl, file.size(tmpl), useBytes = TRUE)
  Encoding(txt) <- "UTF-8"
  lines <- strsplit(paste0(txt, "\nEND"), "\n", fixed = TRUE)[[1]]
  lines <- lines[-length(lines)]
  out <- vapply(lines, fill_line, character(1), wo = fx$wo,
                received = as.Date(fx$received), USE.NAMES = FALSE)
  out <- paste(out, collapse = "\n")
  stopifnot(!grepl("{{", out, fixed = TRUE))
  con <- file(file.path(here, sprintf("%s_0_QCI.txt", fx$wo)), open = "wb")
  writeBin(charToRaw(enc2utf8(out)), con)
  close(con)
}

invisible(TRUE)
