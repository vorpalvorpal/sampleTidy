# PLAN-19 phase 1b: the ALS QCI parser `.qci_parse(lines)` (R-19.18-R-19.20).
#
# Pure function of a character vector of lines -> list(header, summary,
# outliers, warnings). Fixtures are anonymised `pdftotext -layout` extracts of
# real QCIs (fixtures/qci/, REAL-FIXTURES.md); each was chosen for a layout in
# PLAN-19 Appendix A.8. Every expected value below was read off the fixture
# text by hand, not produced by any parser.
#
# Choices the plan leaves open, taken as the simplest reading:
#   [invented: header] `res$header` has fields work_order, issue_date (Date),
#     n_received, n_analysed (integer), named as lab_qc_report's columns.
#   [invented: outliers] `res$outliers` is a data.frame whose columns are
#     lab_qc_outlier's (kind, method, method_name, analyte_raw, cas, lab_id,
#     qc_lot, client_id, data_raw, value_pct, limit_low, limit_high, comment,
#     days_overdue, date_* / due_* as Date, source_page).
#   [invented: "----"] a `----` cell (CAS, limits, lab ID, dates) is NA.
#   [invented: method] `method` is the code before the colon ("EK055G"),
#     `method_name` the text after it, both trimmed.
#   [invented: unrecognised bullet] its summary key is NA (never guessed).
#   [invented: frequency] a frequency row stores the analytical-method name in
#     method_name, the method code (NA where the layout has none) in method,
#     the actual rate in value_pct and the expected rate in limit_low.

na_chr <- NA_character_

# ---- R-19.19 header and Summary of Outliers -------------------------------------

test_that("R-19.19: header fields come from page 1's two-column key : value grid", {
  res <- qci_parse("ES2609470")
  expect_identical(qci_header(res, "work_order"), "ES2609470")
  expect_equal(as.Date(qci_header(res, "issue_date")), as.Date("2026-03-30"))
  expect_equal(as.integer(qci_header(res, "n_received")), 1L)
  expect_equal(as.integer(qci_header(res, "n_analysed")), 1L)

  res <- qci_parse("ES2519223")
  expect_identical(qci_header(res, "work_order"), "ES2519223")
  expect_equal(as.Date(qci_header(res, "issue_date")), as.Date("2025-07-02"))
  expect_equal(as.integer(qci_header(res, "n_received")), 3L)
  expect_equal(as.integer(qci_header(res, "n_analysed")), 3L)
})

test_that("R-19.19: the seven Summary-of-Outliers bullets parse to TRUE ('exist') / FALSE ('NO ...')", {
  expect_identical(qci_summary(qci_parse("ES2609470")),
                   c(mb = FALSE, dup = FALSE, lcs = FALSE, ms = TRUE, surrogate = FALSE,
                     holding_time = TRUE, frequency = TRUE))
  # Short surrogate phrasing ("For all regular sample matrices, NO surrogate ...").
  expect_identical(qci_summary(qci_parse("ES2027611")),
                   c(mb = FALSE, dup = FALSE, lcs = TRUE, ms = FALSE, surrogate = FALSE,
                     holding_time = TRUE, frequency = FALSE))
  expect_identical(qci_summary(qci_parse("ES2011067")),
                   c(mb = FALSE, dup = FALSE, lcs = TRUE, ms = TRUE, surrogate = FALSE,
                     holding_time = FALSE, frequency = TRUE))
  expect_identical(qci_summary(qci_parse("ES2314145")),
                   c(mb = FALSE, dup = FALSE, lcs = FALSE, ms = FALSE, surrogate = FALSE,
                     holding_time = FALSE, frequency = TRUE))
  expect_identical(qci_summary(qci_parse("ES2014537")),
                   c(mb = FALSE, dup = FALSE, lcs = FALSE, ms = FALSE, surrogate = FALSE,
                     holding_time = FALSE, frequency = FALSE))
})

test_that("R-19.19: a fully clean QCI (ES2014537) has no outlier rows and no warnings", {
  res <- qci_parse("ES2014537")
  expect_equal(nrow(as.data.frame(res$outliers)), 0)
  expect_length(res$warnings, 0)
})

test_that("R-19.19: an unrecognised Summary bullet is a warning and NA, never a guess", {
  lines <- qci_lines("ES2014537")
  i <- grep("NO Duplicate outliers occur.", lines, fixed = TRUE)
  expect_length(i, 1)
  lines[[i]] <- sub("NO Duplicate outliers occur.", "Duplicate outliers are under review.",
                    lines[[i]], fixed = TRUE)
  res <- .qci_parse(lines)
  expect_true(length(res$warnings) >= 1)
  s <- qci_summary(res)
  expect_true(is.na(s[["dup"]]))
  expect_false(s[["mb"]])
  expect_false(s[["ms"]])
})

# ---- R-19.20 QC table: MS ---------------------------------------------------------

test_that("R-19.20: MS 'not determined' rows on Anonymous samples, double-dash lab IDs normalised (ES2609470)", {
  ms <- qci_of(qci_parse("ES2609470"), "ms")
  expect_equal(nrow(ms), 2)
  ms <- ms[order(ms$method), , drop = FALSE]
  expect_identical(ms$method, c("EK055G", "EK061G"))
  expect_identical(ms$method_name, c("Ammonia as N by Discrete Analyser",
                                     "Total Kjeldahl Nitrogen By Discrete Analyser"))
  expect_identical(ms$lab_id, c("ES2609442-001", "ES2609438-001"))
  expect_identical(ms$client_id, c("Anonymous", "Anonymous"))
  # Analyte wraps onto the next line and is joined with one space.
  expect_identical(ms$analyte_raw, c("Ammonia as N", "Total Kjeldahl Nitrogen as N"))
  expect_identical(ms$cas, c("7664-41-7", na_chr))
  expect_identical(ms$data_raw, c("Not Determined", "Not Determined"))
  expect_true(all(is.na(ms$value_pct)))
  expect_true(all(is.na(ms$limit_low)) && all(is.na(ms$limit_high)))
  expect_identical(unique(ms$comment),
                   "MS recovery not determined, background level greater than or equal to 4x spike level.")
  expect_true(all(is.na(ms$qc_lot)))
  expect_equal(as.integer(ms$source_page), c(2L, 2L))
})

test_that("R-19.20: own-sample MS rows, lab ID alone on its own line because the method name wrapped (ES2028716)", {
  ms <- qci_of(qci_parse("ES2028716"), "ms")
  expect_equal(nrow(ms), 3)
  ms <- ms[order(ms$method), , drop = FALSE]
  expect_identical(ms$method, c("EK055G", "EK059G", "EK061G"))
  expect_identical(ms$method_name[[2]], "Nitrite plus Nitrate as N (NOx) by Discrete Analyser")
  expect_identical(ms$lab_id, rep("ES2028716-002", 3))
  expect_identical(ms$client_id, rep("Ridgely Road Seep", 3))
  expect_identical(ms$analyte_raw, c("Ammonia as N", "Nitrite + Nitrate as N",
                                     "Total Kjeldahl Nitrogen as N"))
  expect_identical(ms$data_raw, rep("Not Determined", 3))
})

test_that("R-19.20: five numeric MS failures, lab IDs on their own line and one glued to the method name (ES2519223)", {
  ms <- qci_of(qci_parse("ES2519223"), "ms")
  expect_equal(nrow(ms), 9)
  num <- ms[!is.na(ms$value_pct), , drop = FALSE]
  num <- num[order(num$analyte_raw), , drop = FALSE]
  expect_identical(num$analyte_raw, c("Beryllium", "Copper", "Lead", "Nitrite + Nitrate as N",
                                      "Vanadium"))
  expect_equal(num$value_pct, c(69.7, 39.6, 67.5, 10.1, 56.4))
  expect_equal(num$limit_low, rep(70, 5))
  expect_equal(num$limit_high, rep(130, 5))
  expect_identical(unique(num$comment), "Recovery less than lower data quality objective")
  expect_identical(num$lab_id, c("ES2519215-010", "ES2519215-010", "ES2519215-010",
                                 "ES2519046-011", "ES2519215-010"))
  expect_identical(num$method, c("EG020F", "EG020F", "EG020F", "EK059G", "EG020F"))
  expect_identical(num$data_raw[[1]], "69.7 %")

  # Not-determined rows: Cl (ED lab), Mn, the second NOx (EN lab), Reactive P.
  nd <- ms[is.na(ms$value_pct), , drop = FALSE]
  expect_setequal(paste(nd$method, nd$lab_id, nd$analyte_raw),
                  c("ED045G ED2500936-001 Chloride",
                    "EG020F ES2519215-010 Manganese",
                    "EK059G EN2510842-001 Nitrite + Nitrate as N",
                    "EK071G ED2500936-001 Reactive Phosphorus as P"))
  # "...by discrete analyserED2500936--001": x-positions, not whitespace, split cells.
  rp <- ms[ms$method %in% "EK071G", , drop = FALSE]
  expect_identical(rp$method_name, "Reactive Phosphorus as P by discrete analyser")
  expect_identical(rp$cas, "14265-44-2")
  expect_true(all(ms$client_id == "Anonymous"))
})

# ---- R-19.20 QC table: LCS ---------------------------------------------------------

test_that("R-19.20: an LCS row has a QC lot, no lab ID, a wrapped analyte and parsed limits (ES2027611)", {
  lcs <- qci_of(qci_parse("ES2027611"), "lcs")
  expect_equal(nrow(lcs), 1)
  expect_identical(lcs$method, "EA010P")
  expect_identical(lcs$method_name, "Conductivity by PC Titrator")
  expect_identical(lcs$qc_lot, "QC-MRG2-3190228002")
  expect_true(is.na(lcs$lab_id))
  expect_identical(lcs$analyte_raw, "Electrical Conductivity @ 25°C")
  expect_equal(lcs$value_pct, 90.1)
  expect_equal(lcs$limit_low, 95)
  expect_equal(lcs$limit_high, 113)
  expect_identical(lcs$comment, "Recovery less than lower control limit")
})

test_that("R-19.20: two LCS rows (EC low, TKN high) - the second's data on the line after its method/lot line; then an MS row (ES2011067)", {
  res <- qci_parse("ES2011067")
  lcs <- qci_of(res, "lcs")
  expect_equal(nrow(lcs), 2)
  lcs <- lcs[order(lcs$method), , drop = FALSE]
  expect_identical(lcs$method, c("EA010P", "EK061G"))
  expect_identical(lcs$qc_lot, c("QC-2947377-002", "QC-MRG2-2949300002"))
  expect_true(all(is.na(lcs$lab_id)))
  expect_identical(lcs$analyte_raw, c("Electrical Conductivity @ 25°C",
                                      "Total Kjeldahl Nitrogen as N"))
  expect_equal(lcs$value_pct, c(89.8, 102))
  expect_equal(lcs$limit_low, c(95, 69))
  expect_equal(lcs$limit_high, c(113, 101))
  # The comment wraps ("... upper control" / "limit") and is joined with one space.
  expect_identical(lcs$comment, c("Recovery less than lower control limit",
                                  "Recovery greater than upper control limit"))

  ms <- qci_of(res, "ms")
  expect_equal(nrow(ms), 1)
  expect_identical(ms$method, "ED041G")
  expect_identical(ms$lab_id, "ES2010965-001")
  expect_identical(ms$analyte_raw, "Sulfate as SO4 - Turbidimetric")
  expect_identical(ms$cas, "14808-79-8")
  expect_identical(ms$client_id, "Anonymous")
  expect_equal(nrow(qci_of(res, "holding_time")), 0)
})

test_that("R-19.20: subsections other than MS/LCS map to mb/dup/surrogate by keyword", {
  base <- qci_lines("ES2609470")
  i <- grep("^Matrix Spike \\(MS\\) Recoveries\\s*$", base)
  expect_length(i, 1)
  for (case in list(c("Surrogate Recoveries", "surrogate"),
                    c("Method Blank (MB) Results", "mb"),
                    c("Laboratory Duplicate (DUP) Results", "dup"))) {
    lines <- base
    lines[[i]] <- case[[1]]
    res <- .qci_parse(lines)
    o <- as.data.frame(res$outliers)
    expect_equal(sum(o$kind == case[[2]]), 2, info = case[[1]])
    expect_equal(sum(o$kind == "ms"), 0, info = case[[1]])
  }
})

test_that("R-19.20: an unknown QC subsection is a warning (status partial at ingest), not a guess", {
  lines <- qci_lines("ES2609470")
  i <- grep("^Matrix Spike \\(MS\\) Recoveries\\s*$", lines)
  lines[[i]] <- "Unexpected Results"   # [invented: no MS/LCS/blank/duplicate/surrogate keyword]
  res <- .qci_parse(lines)
  expect_true(length(res$warnings) >= 1)
  expect_equal(sum(as.data.frame(res$outliers)$kind %in% "ms"), 0)
})

# ---- R-19.20 holding-time table -----------------------------------------------------

test_that("R-19.20: holding-time rows, one per (method, client ID), dates from the first client line (ES2609470)", {
  ht <- qci_of(qci_parse("ES2609470"), "holding_time")
  # Only the outlier table: the full listing that follows (with its û on EP030)
  # is phase 3 (R-19.36) and adds nothing.
  expect_equal(nrow(ht), 2)
  ht <- ht[order(ht$method), , drop = FALSE]
  expect_identical(ht$method, c("EA005P", "EP030"))
  expect_identical(ht$method_name, c("pH by PC Titrator", "Biochemical Oxygen Demand (BOD)"))
  expect_identical(ht$client_id, rep("Discharge Point - Hamlet STP", 2))
  expect_equal(as.Date(ht$date_analysed), as.Date(c("2026-03-25", "2026-03-25")))
  expect_equal(as.Date(ht$due_analysis), as.Date(c("2026-03-20", "2026-03-22")))
  expect_equal(as.integer(ht$days_overdue), c(5L, 3L))
  expect_true(all(is.na(ht$date_extracted)) && all(is.na(ht$due_extraction)))
  expect_true(all(is.na(ht$lab_id)))
  expect_equal(as.integer(ht$source_page), c(2L, 2L))
})

test_that("R-19.20: comma-continued client-ID lists, two per line over 4 lines, each get a row with the block's dates (ES2028911)", {
  ht <- qci_of(qci_parse("ES2028911"), "holding_time")
  expect_equal(nrow(ht), 24)
  ids <- c("LS1", "LS2", "W1", "W2", "L6", "L7", "L8", "L9")
  for (m in c("EA005P", "EK057G", "EP030")) {
    x <- ht[ht$method == m, , drop = FALSE]
    expect_setequal(x$client_id, ids)
    expect_equal(nrow(x), 8, info = m)
  }
  expect_true(all(as.Date(ht$date_analysed) == as.Date("2020-08-19")))
  expect_true(all(as.integer(ht$days_overdue[ht$method == "EA005P"]) == 6L))
  expect_true(all(as.Date(ht$due_analysis[ht$method == "EA005P"]) == as.Date("2020-08-13")))
  expect_true(all(as.integer(ht$days_overdue[ht$method != "EA005P"]) == 4L))
  # No trailing comma survives in a client ID.
  expect_false(any(grepl(",", ht$client_id)))
})

test_that("R-19.20: two client IDs on one line, the second without a trailing comma, end the list (ES2028716, ES2519223)", {
  ht <- qci_of(qci_parse("ES2028716"), "holding_time")
  expect_equal(nrow(ht), 4)
  expect_setequal(paste(ht$method, ht$client_id),
                  c("EK057G End Ridgely Road", "EK057G Ridgely Road Seep",
                    "EP030 End Ridgely Road", "EP030 Ridgely Road Seep"))
  expect_true(all(as.integer(ht$days_overdue) == 2L))

  ht <- qci_of(qci_parse("ES2519223"), "holding_time")
  expect_equal(nrow(ht), 5)
  expect_setequal(paste(ht$method, ht$client_id, ht$days_overdue),
                  c("EA005P QH.S03 1", "EA005P QH.S02 1", "EA005P QH.S01 1",
                    "EP005 QH.S03 4", "EP005 QH.S02 4"))
})

test_that("R-19.20: a page break inside the holding-time table (page header + '- Continued') does not end it", {
  lines <- qci_lines("ES2028911")
  hdr <- grep("^\fPage\\s+: 3 of 11", lines)
  expect_length(hdr, 1)
  page_hdr <- lines[hdr:(hdr + 3)]
  col_hdr <- lines[grep("^ Container / Client Sample ID\\(s\\)", lines)[[1]] + (-1:1)]
  at <- grep("^EP030: Biochemical Oxygen Demand \\(BOD\\)", lines)[[1]]
  # [invented: the shape of a continued page - page header, blank line, the
  # section title with "- Continued", the matrix line, the column header.]
  spliced <- c(lines[seq_len(at - 1)], page_hdr, "",
               "Outliers : Analysis Holding Time Compliance - Continued", "Matrix: WATER",
               col_hdr, lines[at:length(lines)])
  ht <- qci_of(.qci_parse(spliced), "holding_time")
  expect_equal(nrow(ht), 24)
  expect_equal(sum(ht$method == "EP030"), 8)
  expect_true(all(as.integer(ht$source_page[ht$method == "EP030"]) == 3L))
  expect_true(all(as.integer(ht$source_page[ht$method != "EP030"]) == 2L))
  expect_false(any(grepl("Page|Work Order|Client|Project", ht$client_id)))
})

test_that("R-19.20: a page break inside the QC table (repeated page and column headers) does not end it", {
  lines <- qci_lines("ES2519223")
  hdr <- grep("^\fPage\\s+: 3 of 9", lines)
  page_hdr <- lines[hdr:(hdr + 3)]
  col_hdr <- lines[grep("^\\s+Compound Group Name", lines)[[1]]]
  at <- grep("Manganese", lines)[[1]]
  spliced <- c(lines[seq_len(at - 1)], page_hdr, "", col_hdr, lines[at:length(lines)])
  ms <- qci_of(.qci_parse(spliced), "ms")
  expect_equal(nrow(ms), 9)
  expect_equal(sum(!is.na(ms$value_pct)), 5)
  expect_identical(ms$method[ms$analyte_raw %in% "Manganese"], "EG020F")
})

# ---- R-19.20 frequency table ---------------------------------------------------------

test_that("R-19.20: frequency outliers are one row per QC type x method, stored with their rates", {
  f <- qci_of(qci_parse("ES2609470"), "frequency")
  expect_equal(nrow(f), 1)
  expect_identical(f$method, "EG020A-T")
  expect_identical(f$method_name, "Total Metals by ICP-MS - Suite A")
  expect_equal(f$value_pct, 0)
  expect_equal(f$limit_low, 5)

  f <- qci_of(qci_parse("ES2011067"), "frequency")
  expect_equal(nrow(f), 1)
  expect_identical(f$method_name, "Total Kjeldahl Nitrogen as N By Discrete Analyser")
  expect_equal(f$value_pct, 10.53)
  expect_equal(f$limit_low, 15)

  # ES2028911: DUP x3 and MS x3; this older layout has no method-code column.
  f <- qci_of(qci_parse("ES2028911"), "frequency")
  expect_equal(nrow(f), 6)
  expect_equal(sort(f$limit_low), c(5, 5, 5, 10, 10, 10))
  expect_equal(sum(f$method_name == "Pesticides by GCMS"), 2)
})

test_that("R-19.20: a QCI with frequency outliers only (ES2314145) has exactly those rows", {
  res <- qci_parse("ES2314145")
  o <- as.data.frame(res$outliers)
  expect_equal(nrow(o), 2)
  expect_true(all(o$kind == "frequency"))
  expect_true(all(o$method_name == "Ammonia as N by Discrete analyser"))
  expect_equal(sort(o$value_pct), c(0, 6.25))
})

test_that("R-19.20: per-fixture outlier counts by kind (calibration of the whole parse)", {
  counts <- function(wo) {
    o <- as.data.frame(qci_parse(wo)$outliers)
    k <- c("ms", "lcs", "holding_time", "frequency")
    stats::setNames(vapply(k, function(x) sum(o$kind == x), integer(1)), k)
  }
  expect_identical(counts("ES2609470"), c(ms = 2L, lcs = 0L, holding_time = 2L, frequency = 1L))
  expect_identical(counts("ES2027611"), c(ms = 0L, lcs = 1L, holding_time = 1L, frequency = 0L))
  expect_identical(counts("ES2011067"), c(ms = 1L, lcs = 2L, holding_time = 0L, frequency = 1L))
  expect_identical(counts("ES2028911"), c(ms = 0L, lcs = 1L, holding_time = 24L, frequency = 6L))
  expect_identical(counts("ES2028716"), c(ms = 3L, lcs = 0L, holding_time = 4L, frequency = 0L))
  expect_identical(counts("ES2519223"), c(ms = 9L, lcs = 0L, holding_time = 5L, frequency = 0L))
  expect_identical(counts("ES2314145"), c(ms = 0L, lcs = 0L, holding_time = 0L, frequency = 2L))
  expect_identical(counts("ES2014537"), c(ms = 0L, lcs = 0L, holding_time = 0L, frequency = 0L))
})

test_that("R-19.20: the ES2027611 holding-time row and the one-LCS ES2028911 row", {
  ht <- qci_of(qci_parse("ES2027611"), "holding_time")
  expect_identical(ht$method, "EA005P")
  expect_identical(ht$client_id, "Discharge to Hamlet STP")
  expect_equal(as.integer(ht$days_overdue), 2L)
  expect_equal(as.Date(ht$due_analysis), as.Date("2020-08-08"))

  lcs <- qci_of(qci_parse("ES2028911"), "lcs")
  expect_identical(lcs$qc_lot, "QC-3208392-002")
  expect_equal(lcs$value_pct, 92.8)
})
