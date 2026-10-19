# Generator for `2400-9999-16_SerialZeroDate_WMF.xlsx` - an ANONYMIZED REAL
# fixture (2026-10-19 corpus finding; PLAN-06 "R-6.3c").
#
# Source: `2400-7223-09-1 September 2022 Quarterly Katoomba WMF.xls` (binary
# BIFF, Robin's ACIRL corpus; a copy sits in
# scratchpad/2026-10-19-corpus/src/unprocessed/). Its `Groundwater Sites`
# sheet has a `Date of Sample` row reading 44823 (2022-09-18) in every sample
# column EXCEPT the last (`MP # 4`, cell K11), which holds the number 0 - Excel
# shows a formula over an empty cell as 0, and `excel_date(0)` is 1899-12-30.
# The adapter emitted that as `sample_datetime_raw = "30/12/1899"`, and the
# November-2020 quarterly (`24006990-11`, same cell, same 0) collided with it on
# (MP # 4, 1899-12-30): five readings committed against the wrong date and three
# false value_conflicts.
#
# Binary BIFF cannot be byte-anonymized (REAL-FIXTURES.md), so - as for the
# other ACIRL real fixtures - the two sheets the adapter needs (`Front Page`,
# `Groundwater Sites`) are read cell-by-cell with readxl (each cell keeps its
# own type: numeric stays numeric, text stays text) and re-written as .xlsx.
# Geometry and every analytical value (dates, values, units, `<1`, the 0) are
# the original; only place/person names and the sampling-point labels are
# changed (ASCII, see `anon` below). Work-order IDs are kept.
#
# Re-run with (needs the corpus source file):
#   Rscript tests/testthat/fixtures/corpus-2026-10-19/generate-serial-zero.R <source.xls>

args <- commandArgs(trailingOnly = TRUE)
src <- if (length(args)) args[[1]] else file.path(
  "scratchpad", "2026-10-19-corpus", "src", "unprocessed",
  "2400-7223-09-1 September 2022 Quarterly Katoomba WMF.xls"
)
stopifnot(file.exists(src))
this_file_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
here <- if (length(this_file_arg) == 1) {
  dirname(normalizePath(sub("^--file=", "", this_file_arg)))
} else {
  "tests/testthat/fixtures/corpus-2026-10-19"
}
library(openxlsx)

# Ordered literal substitutions, applied to TEXT cells only.
anon <- c(
  "KATOOMBA" = "SITEB", "Katoomba" = "SiteB", "Lithgow" = "RegionA",
  "Jane Manners" = "A. Recipient", "Adriana Hernandez" = "A. Signatory",
  "S. Carter & J. Sharp" = "A. Sampler & B. Sampler",
  "BORE" = "WELL", "MP #" = "PZ #"
)
anonymize <- function(s) {
  for (k in names(anon)) s <- gsub(k, anon[[k]], s, fixed = TRUE)
  s
}

wb <- createWorkbook()
for (sh in c("Front Page", "Groundwater Sites")) {
  g <- suppressMessages(readxl::read_excel(src, sheet = sh, col_names = FALSE, col_types = "list"))
  # The same grid as text: for a date-formatted cell this is the raw serial
  # ("44823", "0"), which is what the adapter itself reads.
  gt <- suppressMessages(readxl::read_excel(src, sheet = sh, col_names = FALSE, col_types = "text"))
  addWorksheet(wb, sh)
  for (j in seq_along(g)) for (i in seq_len(nrow(g))) {
    v <- g[[j]][[i]]
    if (is.null(v) || length(v) == 0 || (length(v) == 1 && is.na(v))) next
    if (inherits(v, "POSIXt")) {
      # Date-formatted cell: write the original serial as a number, keep a
      # date number format (so Excel still shows it as a date).
      writeData(wb, sh, x = as.numeric(gt[[j]][[i]]), startRow = i, startCol = j,
                colNames = FALSE, rowNames = FALSE)
      addStyle(wb, sh, createStyle(numFmt = "dd/mm/yyyy"), rows = i, cols = j)
      next
    }
    if (is.character(v)) v <- anonymize(v)
    writeData(wb, sh, x = v, startRow = i, startCol = j, colNames = FALSE, rowNames = FALSE)
  }
}
out <- file.path(here, "2400-9999-16_SerialZeroDate_WMF.xlsx")
saveWorkbook(wb, out, overwrite = TRUE)

# Guard: the property under test survived the round-trip.
chk <- suppressMessages(readxl::read_excel(out, sheet = "Groundwater Sites", col_names = FALSE, col_types = "text"))
stopifnot(identical(chk[[11]][[11]], "0"), identical(chk[[10]][[11]], "44823"))
message("wrote ", out)
