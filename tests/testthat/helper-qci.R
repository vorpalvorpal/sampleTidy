# Helpers for the PLAN-19 phase-1b tests (test-qci-*.R, test-lab-qc-*.R): the
# ALS QCI parser, lab-QC storage and the lab_qc_outlier / holding_time flags.
# Only DEFINES functions - no top-level calls.
#
# The schema (qc_db(), qc_create_tables()) and the QC-feature builders come from
# helper-qc.R (the phase-1 helpers), so both phases test against ONE shape of
# migration 048's tables.
#
# FIXTURES (tests/testthat/fixtures/qci/, see REAL-FIXTURES.md): the `.txt`
# files are `pdftotext -layout` extracts of real ALS QCI PDFs, anonymised
# length-preserving (column x-positions are part of what is under test).
#
# THE PARSER INPUT (R-19.18) is a character vector of lines, exactly
#   strsplit(paste(pdftools::pdf_text(path), collapse = "\f"), "\n")[[1]]
# which is line-for-line `readLines()` of the `pdftotext -layout` output
# (measured on ES2609470, ES2011067 and ES2028911: identical except pdftotext's
# final trailing "\f"). So a line that begins with "\f" is the first line of a
# new page. [invented: "\f" as the page marker inside `lines`.]

qci_fixture <- function(...) testthat::test_path("fixtures", "qci", ...)

#' The parser input for one fixture, e.g. qci_lines("ES2609470").
qci_lines <- function(wo, file = sprintf("%s_0_QCI.txt", wo)) {
  readLines(qci_fixture(file), encoding = "UTF-8", warn = FALSE)
}

#' `.qci_parse()` on a fixture (or on a character vector of lines).
qci_parse <- function(x) {
  lines <- if (length(x) == 1 && !grepl("\n|\\s", x) && grepl("^E[A-Z][0-9]{7}$", x)) qci_lines(x) else x
  .qci_parse(lines)
}

qci_of <- function(res, kind) {
  o <- as.data.frame(res$outliers, stringsAsFactors = FALSE)
  o[o$kind %in% kind, , drop = FALSE]
}

.qci_summary_keys <- c("mb", "dup", "lcs", "ms", "surrogate", "holding_time", "frequency")

#' The seven Summary-of-Outliers booleans as a named logical vector.
qci_summary <- function(res) {
  s <- res$summary
  vapply(.qci_summary_keys, function(k) {
    v <- s[[k]]
    if (is.null(v) || length(v) != 1) NA else as.logical(v)
  }, logical(1))
}

#' A header field from `res$header` (a list or a one-row data.frame).
qci_header <- function(res, field) res$header[[field]][[1]]

# ---- PDF text, mocked ------------------------------------------------------------
#
# lab_qc_ingest() reads a PDF with pdftools::pdf_text() (R-19.16). Real QCI
# PDFs cannot be committed (they are not anonymisable byte-for-byte), so the
# ingest tests write a STUB file whose content is `QCI-FIXTURE:<fixture>` and
# mock pdf_text() to return that fixture's pages. Any other file (the real
# 0-byte QCI, the corrupt QC.pdf) goes through the REAL pdf_text().

.qci_real_pdf_text <- function() get("pdf_text", envir = asNamespace("pdftools"))

#' The pages of a pdftotext -layout file, as pdf_text() would return them.
qci_pages <- function(txt_path) {
  txt <- readChar(txt_path, file.size(txt_path), useBytes = TRUE)
  Encoding(txt) <- "UTF-8"
  pages <- strsplit(txt, "\f", fixed = TRUE)[[1]]
  pages[nzchar(pages) | seq_along(pages) < length(pages)]
}

qci_mock_pdf_text <- function(env = parent.frame()) {
  real <- .qci_real_pdf_text()
  testthat::local_mocked_bindings(
    pdf_text = function(pdf, ...) {
      head <- tryCatch(readChar(pdf, 200L, useBytes = TRUE), error = function(e) "")
      if (length(head) == 1 && startsWith(head, "QCI-FIXTURE:")) {
        ref <- trimws(sub("^QCI-FIXTURE:", "", head))
        path <- if (file.exists(ref)) ref else qci_fixture(ref)
        return(qci_pages(path))
      }
      real(pdf, ...)
    },
    .package = "pdftools", .env = env
  )
}

#' Write a stub "PDF" named `filename` in `dir` that the mock reads as `fixture`
#' (a fixture file name, or an absolute path to a lines file).
qci_stub <- function(dir, filename, fixture) {
  p <- file.path(dir, filename)
  writeLines(paste0("QCI-FIXTURE:", fixture), p, useBytes = TRUE)
  p
}

#' Write modified fixture lines to a temp file; returns its path (for qci_stub()).
qci_write_lines <- function(lines, env = parent.frame()) {
  p <- withr::local_tempfile(fileext = ".txt", .local_envir = env)
  writeLines(lines, p, useBytes = TRUE)
  p
}

# ---- DB rows -----------------------------------------------------------------------

#' An `asset` row of type `type` under the work order's project. Returns its uuid.
qci_asset <- function(con, filename, work_order, type = "QC") {
  up <- fl_project(con, work_order)
  u <- fl_uuid()
  DBI::dbExecute(con, "INSERT INTO asset (uuid, file_format, type, uuid_project, filename, hash)
                       VALUES (?, 'pdf', ?, ?, ?, ?)",
                 params = list(u, type, up, filename, substr(gsub("-", "", fl_uuid()), 1, 16)))
  u
}

qci_reports <- function(con) DBI::dbGetQuery(con, "SELECT * FROM lab_qc_report")
qci_outliers <- function(con, uuid_report = NULL) {
  if (is.null(uuid_report)) return(DBI::dbGetQuery(con, "SELECT * FROM lab_qc_outlier"))
  DBI::dbGetQuery(con, "SELECT * FROM lab_qc_outlier WHERE uuid_report = ?",
                  params = list(uuid_report))
}

#' A parsed QCI report with outlier rows, inserted directly (flag tests do not
#' go through the parser). `outliers` is a list of named lists of
#' lab_qc_outlier columns. Returns the report uuid.
qci_put_report <- function(con, work_order, outliers = list(), status = "parsed") {
  ur <- fl_uuid()
  DBI::dbExecute(con, "INSERT INTO lab_qc_report (uuid, uuid_asset, work_order, kind, issue_date,
                         n_received, n_analysed, summary, status, message, parser_version, parsed_at)
                       VALUES (?, ?, ?, 'QCI', CAST('2026-09-20' AS DATE), 1, 1, '{}', ?, NULL, '1',
                               CAST(? AS TIMESTAMP))",
                 params = list(ur, fl_uuid(), work_order, status, fl_ts(fl_now() - 86400)))
  cols <- c("method", "method_name", "analyte_raw", "cas", "lab_id", "qc_lot", "client_id",
            "uuid_sample", "data_raw", "comment")
  num <- c("value_pct", "limit_low", "limit_high")
  dts <- c("date_analysed", "due_analysis", "date_extracted", "due_extraction")
  for (o in outliers) {
    v <- function(k, na) if (is.null(o[[k]])) na else o[[k]]
    DBI::dbExecute(con, sprintf(
      "INSERT INTO lab_qc_outlier (uuid, uuid_report, work_order, kind, %s, %s, days_overdue, %s, source_page)
       VALUES (?, ?, ?, ?, %s, %s, ?, %s, 2)",
      paste(cols, collapse = ", "), paste(num, collapse = ", "), paste(dts, collapse = ", "),
      paste(rep("?", length(cols)), collapse = ", "), paste(rep("?", length(num)), collapse = ", "),
      paste(rep("CAST(? AS DATE)", length(dts)), collapse = ", ")),
      params = c(list(fl_uuid(), ur, work_order, o$kind),
                 lapply(cols, v, na = NA_character_), lapply(num, v, na = NA_real_),
                 list(as.integer(v("days_overdue", NA_integer_))),
                 lapply(dts, v, na = NA_character_)))
  }
  invisible(ur)
}

#' An ALS lab result under a method (method = "<CODE>: <name>").
qci_lab <- function(analyte, value, method, units = "mg/L", rl = NA_real_, quantified = TRUE) {
  list(analyte = analyte, value = value, method = method, units = units, rl = rl,
       quantified = quantified, lab_org = "ALS")
}

#' A field result (ACIRL / client-supplied: field by the lab method's organisation).
qci_field <- function(analyte, value, units = "pH units") {
  list(analyte = analyte, value = value, method = "Field measurement", units = units,
       lab_org = "ACIRL")
}

#' Flags of one check, from a run.
qci_flags <- function(db, checks = fl_checks(), check) fl_of(fl_run(db, checks), check)
