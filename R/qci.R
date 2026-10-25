# PLAN-19 phase 1b: the ALS QA/QC Compliance Assessment (QCI) parser (R-19.18 -
# R-19.20). A pure function of the PDF's text lines:
#
#   lines <- strsplit(paste(pdftools::pdf_text(path), collapse = "\f"), "\n")[[1]]
#
# which is line-for-line `pdftotext -layout`. A line that begins with "\f" is
# the first line of a new page. The report is ALS's own fact sheet: nothing
# here judges a value (R19-2, R19-11); the flag checks do that.
#
# Layout (PLAN-19 Appendix A): page 1 carries the key : value header grid and
# the seven Summary-of-Outliers bullets. The detail tables follow on later
# pages, each led by an `Outliers : <table>` title:
#   * Quality Control Samples - one record per outlier, columns located by x
#     position (they move between files and pages);
#   * Analysis Holding Time Compliance - method / container / client-ID lines;
#   * Frequency of Quality Control Samples - one row per QC type x method.
# The full holding-time and frequency listings that follow those tables are
# not parsed (phase 3, R-19.36).

# "2" (R-22.S): a QCI report now also stores received_at, so reports stored at
# "1" are stale and the backfill re-parses them.
.qci_parser_version <- "2"

.qci_summary_keys <- c("mb", "dup", "lcs", "ms", "surrogate", "holding_time", "frequency")

.qci_outlier_cols <- c("kind", "method", "method_name", "analyte_raw", "cas", "lab_id",
                       "qc_lot", "client_id", "data_raw", "value_pct", "limit_low",
                       "limit_high", "comment", "days_overdue", "date_analysed",
                       "due_analysis", "date_extracted", "due_extraction", "source_page")

.qci_method_re <- "E[A-Z][0-9]{3}[A-Za-z0-9/-]*"
.qci_lab_id_re <- "E[A-Z][0-9]{7}-{1,2}[0-9]{3}"
.qci_lot_re <- "QC-[A-Z0-9]+(?:-[A-Z0-9]+)*"
.qci_date_re <- "[0-9]{2}-[A-Z][a-z]{2}-[0-9]{4}"
.qci_limits_re <- "^(----|[0-9.]+ ?- ?[0-9.]+ ?%)$"
.qci_data_re <- "^(Not|Not Determined|[<>]?-?[0-9.]+ ?%?)$"

# ---- small pieces ----------------------------------------------------------------

# dd-Mon-yyyy -> Date, locale-free; anything else ("----", blank) -> NA.
.qci_date <- function(x) {
  x <- trimws(as.character(x))
  ok <- !is.na(x) & grepl(paste0("^", .qci_date_re, "$"), x)
  out <- rep(as.Date(NA), length(x))
  if (any(ok)) {
    mon <- match(substr(x[ok], 4, 6), month.abb)
    out[ok] <- as.Date(sprintf("%s-%02d-%s", substr(x[ok], 8, 11), mon, substr(x[ok], 1, 2)))
  }
  out
}

.qci_na_dash <- function(x) {
  x <- trimws(as.character(x))
  x[!is.na(x) & (x == "" | grepl("^-+$", x))] <- NA_character_
  x
}

.qci_num <- function(x) suppressWarnings(as.numeric(x))

# Cells of a line: runs of text separated by two or more spaces, with their
# character start/end positions (1-based, inclusive).
.qci_tokens <- function(line) {
  m <- gregexpr("\\S+(?: \\S+)*", line, perl = TRUE)[[1]]
  if (length(m) == 1 && m[[1]] == -1) {
    return(data.frame(text = character(), start = integer(), end = integer(),
                      stringsAsFactors = FALSE))
  }
  len <- attr(m, "match.length")
  data.frame(text = regmatches(line, list(m))[[1]], start = as.integer(m),
             end = as.integer(m + len - 1L), stringsAsFactors = FALSE)
}

# Replace characters `from`..`to` of `line` with spaces (positions kept).
.qci_blank <- function(line, from, to) {
  if (is.na(from) || to < from) return(line)
  paste0(substr(line, 1, from - 1L), strrep(" ", to - from + 1L),
         substr(line, to + 1L, nchar(line)))
}

.qci_empty_outliers <- function() {
  d <- data.frame(kind = character(), method = character(), method_name = character(),
                  analyte_raw = character(), cas = character(), lab_id = character(),
                  qc_lot = character(), client_id = character(), data_raw = character(),
                  value_pct = numeric(), limit_low = numeric(), limit_high = numeric(),
                  comment = character(), days_overdue = integer(),
                  stringsAsFactors = FALSE)
  d$date_analysed <- as.Date(character())
  d$due_analysis <- as.Date(character())
  d$date_extracted <- as.Date(character())
  d$due_extraction <- as.Date(character())
  d$source_page <- integer()
  d[, .qci_outlier_cols]
}

# One outlier row from a named list (missing fields NA).
.qci_row <- function(...) {
  x <- list(...)
  d <- .qci_empty_outliers()[NA_integer_, , drop = FALSE]
  rownames(d) <- NULL
  for (k in names(x)) d[[k]] <- if (is.null(x[[k]]) || length(x[[k]]) == 0) d[[k]] else x[[k]]
  d
}

# ---- page structure ----------------------------------------------------------------

# Per line: its page number, the line without its leading form feed, and
# whether it is page furniture (the repeated page header block, the footer).
.qci_pages <- function(lines) {
  n <- length(lines)
  page <- integer(n)
  skip <- logical(n)
  text <- lines
  cur <- 1L
  hdr_left <- 0L
  for (i in seq_len(n)) {
    x <- text[[i]]
    if (startsWith(x, "\f")) {
      cur <- cur + 1L
      x <- sub("^\f+", "", x)
      text[[i]] <- x
    }
    m <- regmatches(x, regexec("^Page\\s*:\\s*([0-9]+)\\s+of\\s+[0-9]+\\s*$", x))[[1]]
    if (length(m) == 2) {
      cur <- as.integer(m[[2]])
      skip[[i]] <- TRUE
      hdr_left <- 3L
    } else if (hdr_left > 0L && grepl("^(Work Order|Client|Project)\\s*:", x)) {
      skip[[i]] <- TRUE
      hdr_left <- hdr_left - 1L
    } else {
      hdr_left <- 0L
    }
    if (grepl("^\\s*right solutions[.|[:space:]]*right partner\\.?\\s*$", x, ignore.case = TRUE)) {
      skip[[i]] <- TRUE
    }
    page[[i]] <- cur
  }
  list(text = text, page = page, skip = skip)
}

# ---- header (R-19.19) ------------------------------------------------------------------

.qci_header <- function(text, page) {
  p1 <- text[page == 1L]
  grab <- function(re) {
    for (x in p1) {
      m <- regmatches(x, regexec(re, x, perl = TRUE))[[1]]
      if (length(m) == 2) return(m[[2]])
    }
    NA_character_
  }
  list(work_order = grab("Work Order\\s*:\\s*(E[A-Z][0-9]{7})"),
       issue_date = .qci_date(grab(paste0("Issue Date\\s*:\\s*(", .qci_date_re, ")"))),
       n_received = as.integer(grab("No\\. of samples received\\s*:\\s*([0-9]+)")),
       n_analysed = as.integer(grab("No\\. of samples analysed\\s*:\\s*([0-9]+)")))
}

# ---- Summary of Outliers (R-19.19) ------------------------------------------------------

.qci_bullet_key <- function(x) {
  if (grepl("surrogate", x, ignore.case = TRUE)) return("surrogate")
  if (grepl("Method Blank", x, fixed = TRUE)) return("mb")
  if (grepl("Laboratory Control", x, fixed = TRUE)) return("lcs")
  if (grepl("Matrix Spike", x, fixed = TRUE)) return("ms")
  if (grepl("Holding Time", x, ignore.case = TRUE)) return("holding_time")
  if (grepl("Frequency", x, ignore.case = TRUE)) return("frequency")
  if (grepl("Duplicate", x, fixed = TRUE)) return("dup")
  NA_character_
}

.qci_bullet_value <- function(x) {
  x <- gsub("\\s+", " ", trimws(x))
  if (grepl("^NO .* (outliers )?(occur|exist)\\.$", x)) return(FALSE)
  if (grepl(paste0("^For all regular sample matrices, (where applicable to the methodology, )?",
                   "NO surrogate recovery outliers occur\\.$"), x)) return(FALSE)
  if (grepl(" (exist|occur) - please see following pages for full details\\.$", x)) return(TRUE)
  NA
}

.qci_summary <- function(text, page, skip) {
  warn <- character(0)
  out <- stats::setNames(as.list(rep(NA, length(.qci_summary_keys))), .qci_summary_keys)
  start <- grep("^Summary of Outliers\\s*$", text)
  if (length(start) == 0) {
    return(list(summary = out, warnings = "Summary of Outliers not found", end = 0L))
  }
  start <- start[[1]]
  pg <- page[[start]]
  idx <- which(seq_along(text) > start & page == pg & !skip)
  end <- if (length(idx)) max(idx) else start
  bullets <- character(0)
  open <- FALSE
  for (i in idx) {
    x <- text[[i]]
    if (grepl("^\\s*l\\s+\\S", x)) {
      bullets <- c(bullets, sub("^\\s*l\\s+", "", x))
      open <- TRUE
    } else if (open && grepl("^\\s+\\S", x)) {
      # A bullet wrapped onto the next line.
      bullets[[length(bullets)]] <- paste(bullets[[length(bullets)]], trimws(x))
    } else {
      open <- FALSE
    }
  }
  seen <- character(0)
  for (b in bullets) {
    k <- .qci_bullet_key(b)
    v <- .qci_bullet_value(b)
    if (is.na(k)) {
      warn <- c(warn, sprintf("unrecognised Summary bullet: %s", trimws(b)))
      next
    }
    if (k %in% seen) {
      warn <- c(warn, sprintf("Summary bullet for %s appears twice", k))
      out[[k]] <- NA
      next
    }
    seen <- c(seen, k)
    if (is.na(v)) warn <- c(warn, sprintf("unrecognised Summary bullet (%s): %s", k, trimws(b)))
    out[[k]] <- v
  }
  for (k in setdiff(.qci_summary_keys, seen)) {
    warn <- c(warn, sprintf("no Summary bullet for %s", k))
  }
  list(summary = out, warnings = warn, end = end)
}

# ---- sections ------------------------------------------------------------------------------

# The detail sections after the Summary: list of (type, line indices).
.qci_sections <- function(text, skip, from) {
  n <- length(text)
  type <- rep(NA_character_, n)
  cur <- NA_character_
  for (i in seq_len(n)) {
    if (i <= from) next
    x <- text[[i]]
    if (grepl("^\\s*Outliers\\s*:.*-\\s*Continued\\s*$", x)) {
      # A continued page: same table, the title is page furniture.
      skip[[i]] <- TRUE
    } else if (grepl("^\\s*Outliers\\s*:\\s*Quality Control Samples\\s*$", x)) {
      cur <- "qc"
      skip[[i]] <- TRUE
    } else if (grepl("^\\s*Outliers\\s*:\\s*Analysis Holding Time Compliance\\s*$", x)) {
      cur <- "ht"
      skip[[i]] <- TRUE
    } else if (grepl("^\\s*Outliers\\s*:\\s*Frequency of Quality Control Samples\\s*$", x)) {
      cur <- "freq"
      skip[[i]] <- TRUE
    } else if (grepl("^\\s*Outliers\\s*:", x) ||
               grepl("^(Analysis Holding Time Compliance|Quality Control Parameter Frequency Compliance|Brief Method Summaries)", x)) {
      cur <- NA_character_
    }
    type[[i]] <- cur
  }
  list(type = type, skip = skip)
}

# ---- QC table (R-19.20) --------------------------------------------------------------------

.qci_subsection_kind <- function(x) {
  if (grepl("Matrix Spike|\\(MS\\)", x)) return("ms")
  if (grepl("Laboratory Control|\\(LCS\\)", x)) return("lcs")
  if (grepl("Surrogate", x, ignore.case = TRUE)) return("surrogate")
  if (grepl("Method Blank|\\(MB\\)", x)) return("mb")
  if (grepl("Duplicate|\\(DUP\\)", x)) return("dup")
  NA_character_
}

.qci_parse_qc <- function(text, page, idx) {
  warn <- character(0)
  rows <- list()
  kind <- NULL          # NULL: no subsection yet; NA: an unknown one
  method <- NA_character_
  method_name <- NA_character_
  pend <- list()        # lab_id / lot / method seen on lines before the data line
  rec <- NULL           # the open record: cells plus the data line's token spans

  close_rec <- function() {
    if (is.null(rec)) return(invisible())
    if (!is.null(rec$kind) && !is.na(rec$kind)) {
      cell <- function(k) {
        v <- rec$cells[[k]]
        if (is.null(v) || length(v) == 0) NA_character_ else paste(v, collapse = " ")
      }
      data_raw <- cell("data")
      limits <- cell("limits")
      lim <- regmatches(limits, regexec("^([0-9.]+) ?- ?([0-9.]+) ?%$", limits))[[1]]
      val <- regmatches(data_raw, regexec("^([<>]?-?[0-9.]+) ?%$", data_raw))[[1]]
      rows[[length(rows) + 1L]] <<- .qci_row(
        kind = rec$kind, method = rec$method, method_name = rec$method_name,
        analyte_raw = .qci_na_dash(cell("analyte")), cas = .qci_na_dash(cell("cas")),
        lab_id = .qc_norm_lab_id(rec$lab_id), qc_lot = rec$lot,
        client_id = .qci_na_dash(cell("client")), data_raw = data_raw,
        value_pct = if (length(val) == 2) .qci_num(sub("^[<>]", "", val[[2]])) else NA_real_,
        limit_low = if (length(lim) == 3) .qci_num(lim[[2]]) else NA_real_,
        limit_high = if (length(lim) == 3) .qci_num(lim[[3]]) else NA_real_,
        comment = cell("comment"), source_page = rec$page)
    }
    rec <<- NULL
  }

  for (i in idx) {
    x <- text[[i]]
    if (!nzchar(trimws(x))) next
    if (grepl("Compound Group Name", x, fixed = TRUE)) next
    if (grepl("^\\s*Matrix\\s*:", x) || grepl("^\\s*Duplicates, Method Blanks", x)) next
    mline <- regmatches(x, regexec(paste0("^\\s*(", .qci_method_re, "):\\s*"), x))[[1]]
    if (grepl("^\\S", x) && length(mline) == 0) {
      close_rec()
      pend <- list()
      kind <- .qci_subsection_kind(x)
      if (is.na(kind)) warn <- c(warn, sprintf("unknown QC subsection: %s", trimws(x)))
      method <- NA_character_
      method_name <- NA_character_
      next
    }
    line <- x
    # Lab ID / QC lot anywhere on the line (x-position free: a long method
    # name can push it right, or glue it to the method text).
    lab <- regexpr(.qci_lab_id_re, line)
    lot <- regexpr(.qci_lot_re, line, perl = TRUE)
    lab_id <- if (lab > 0) regmatches(line, lab) else NA_character_
    lot_id <- if (lot > 0) regmatches(line, lot) else NA_character_
    m_code <- NA_character_
    m_name <- NA_character_
    if (length(mline) == 2) {
      m_code <- mline[[2]]
      ms <- nchar(mline[[1]]) + 1L
      cut <- c(if (lab > 0 && lab >= ms) lab, if (lot > 0 && lot >= ms) lot)
      rest <- substr(line, ms, nchar(line))
      gap <- regexpr("\\s{2,}", rest)
      end_gap <- if (gap > 0) ms + gap - 2L else nchar(line)
      m_end <- min(c(cut - 1L, end_gap))
      m_name <- trimws(substr(line, ms, m_end))
      line <- .qci_blank(line, 1L, m_end)
    }
    if (lab > 0) line <- .qci_blank(line, lab, lab + attr(lab, "match.length") - 1L)
    if (lot > 0) line <- .qci_blank(line, lot, lot + attr(lot, "match.length") - 1L)
    tk <- .qci_tokens(line)
    n <- nrow(tk)
    is_data <- FALSE
    if (n >= 3) {
      li <- if (grepl(.qci_limits_re, tk$text[[n]])) n else if (grepl(.qci_limits_re, tk$text[[n - 1L]])) n - 1L else 0L
      is_data <- li >= 3 && grepl(.qci_data_re, tk$text[[li - 1L]])
    }
    if (is_data) {
      close_rec()
      if (!is.na(m_code)) pend$method <- c(m_code, m_name)
      if (!is.na(lab_id)) pend$lab_id <- lab_id
      if (!is.na(lot_id)) pend$lot <- lot_id
      if (!is.null(pend$method)) {
        method <- pend$method[[1]]
        method_name <- pend$method[[2]]
      }
      roles <- character(n)
      roles[li] <- "limits"
      roles[li - 1L] <- "data"
      if (li < n) roles[(li + 1L):n] <- "comment"
      if (li - 2L >= 1) roles[li - 2L] <- "cas"
      if (li - 3L >= 1) roles[li - 3L] <- "analyte"
      if (li - 4L >= 1) roles[seq_len(li - 4L)] <- "client"
      cells <- lapply(c(client = "client", analyte = "analyte", cas = "cas", data = "data",
                        limits = "limits", comment = "comment"),
                      function(r) tk$text[roles == r])
      if (is.null(kind)) warn <- c(warn, sprintf("QC record before any subsection (page %d)", page[[i]]))
      rec <- list(kind = if (is.null(kind)) NA_character_ else kind, method = method,
                  method_name = method_name, lab_id = if (is.null(pend$lab_id)) NA_character_ else pend$lab_id,
                  lot = if (is.null(pend$lot)) NA_character_ else pend$lot,
                  page = page[[i]], cells = cells, spans = tk, roles = roles)
      if (is.na(method)) warn <- c(warn, sprintf("QC record with no method (page %d)", page[[i]]))
      pend <- list()
      next
    }
    if (!is.na(m_code) || !is.na(lab_id) || !is.na(lot_id)) {
      # A line before its record's data line: a lone lab ID, or the method
      # (and lot) whose data wrapped to the next line.
      close_rec()
      if (!is.na(m_code)) pend$method <- c(m_code, m_name)
      if (!is.na(lab_id)) pend$lab_id <- lab_id
      if (!is.na(lot_id)) pend$lot <- lot_id
      next
    }
    if (n == 0) next
    if (is.null(rec)) {
      warn <- c(warn, sprintf("unplaced QC table line (page %d): %s", page[[i]], trimws(x)))
      next
    }
    # A wrapped continuation: each piece joins the data-line cell it lies under.
    sp <- rec$spans
    for (j in seq_len(n)) {
      ov <- pmin(sp$end, tk$end[[j]]) - pmax(sp$start, tk$start[[j]]) + 1L
      k <- if (any(ov > 0)) which.max(ov) else which.min(abs((sp$start + sp$end) / 2 - (tk$start[[j]] + tk$end[[j]]) / 2))
      role <- rec$roles[[k]]
      rec$cells[[role]] <- c(rec$cells[[role]], tk$text[[j]])
    }
  }
  close_rec()
  if (length(pend)) warn <- c(warn, "QC table ends with a record that has no data line")
  list(rows = if (length(rows)) do.call(rbind, rows) else .qci_empty_outliers(), warnings = warn)
}

# ---- holding-time table (R-19.20) ---------------------------------------------------------

.qci_parse_ht <- function(text, page, idx) {
  warn <- character(0)
  rows <- list()
  method <- NA_character_
  method_name <- NA_character_
  in_list <- FALSE
  dates <- NULL
  tail_re <- sprintf(paste0("\\s+(----|%1$s)\\s+(----|%1$s)\\s+(----|[0-9]+)\\s+",
                            "(----|%1$s)\\s+(----|%1$s)\\s+(----|[0-9]+)\\s*$"), .qci_date_re)
  for (i in idx) {
    x <- text[[i]]
    if (!nzchar(trimws(x))) next
    if (grepl("^\\s*Matrix\\s*:", x) || grepl("^Method\\s{2,}", x) ||
        grepl("^\\s*Container / Client Sample ID", x) || grepl("^\\s*overdue(\\s+overdue)?\\s*$", x)) next
    mline <- regmatches(x, regexec(paste0("^\\s?(", .qci_method_re, "):\\s*(.*?)\\s*$"), x))[[1]]
    if (length(mline) == 3) {
      method <- mline[[2]]
      # A block continued on a new page repeats its method line with the
      # table title glued on (ES2413933): page furniture, not the name.
      method_name <- sub("\\s+-\\s+Analysis Holding Time Compliance$", "", mline[[3]])
      in_list <- FALSE
      next
    }
    tm <- regexpr(tail_re, x, perl = TRUE)
    if (tm > 0) {
      parts <- regmatches(x, regexec(tail_re, x, perl = TRUE))[[1]]
      dates <- list(date_extracted = .qci_date(parts[[2]]), due_extraction = .qci_date(parts[[3]]),
                    d_ext = .qci_num(parts[[4]]), date_analysed = .qci_date(parts[[5]]),
                    due_analysis = .qci_date(parts[[6]]), d_an = .qci_num(parts[[7]]))
      portion <- substr(x, 1, tm - 1L)
    } else if (in_list) {
      portion <- x
    } else {
      # A container line ("Clear Plastic Bottle - Natural"): it carries no
      # dates and does not continue a comma list. Its indent is not reliable
      # (one or two spaces, even within one file), so it is not used.
      next
    }
    if (is.na(method)) {
      warn <- c(warn, sprintf("holding-time client line with no method (page %d)", page[[i]]))
      next
    }
    in_list <- grepl(",\\s*$", portion)
    ids <- unlist(lapply(strsplit(portion, ",", fixed = TRUE)[[1]], function(p) strsplit(trimws(p), "\\s{2,}")[[1]]))
    ids <- trimws(ids)
    ids <- ids[nzchar(ids)]
    days <- dates$d_an
    if (is.na(days)) days <- dates$d_ext
    for (cid in ids) {
      rows[[length(rows) + 1L]] <- .qci_row(
        kind = "holding_time", method = method, method_name = method_name, client_id = cid,
        days_overdue = as.integer(days), date_analysed = dates$date_analysed,
        due_analysis = dates$due_analysis, date_extracted = dates$date_extracted,
        due_extraction = dates$due_extraction, source_page = page[[i]])
    }
  }
  out <- if (length(rows)) do.call(rbind, rows) else .qci_empty_outliers()
  # One row per (method block, client ID). Two blocks may share a method code
  # (EP080/071 TPH and TRH, ES2608954); they are distinct analyses.
  out <- out[!duplicated(paste(out$method, out$method_name, out$client_id, sep = "\r")), , drop = FALSE]
  list(rows = out, warnings = warn)
}

# ---- frequency table (R-19.20) -------------------------------------------------------------

.qci_parse_freq <- function(text, page, idx) {
  warn <- character(0)
  rows <- list()
  qc_type <- NA_character_
  row_re <- paste0("^(\\S.*?)\\s{2,}(?:(", .qci_method_re, ")\\s+)?([0-9]+)\\s+([0-9]+)\\s+",
                   "([0-9]+(?:\\.[0-9]+)?)\\s+([0-9]+(?:\\.[0-9]+)?)\\s*(.*?)\\s*$")
  for (i in idx) {
    x <- text[[i]]
    if (!nzchar(trimws(x))) next
    if (grepl("^\\s*Matrix\\s*:", x) || grepl("^Quality Control Sample Type", x) ||
        grepl("^\\s*(Analytical Methods\\s+)?Method\\s+QC\\s+Regular", x)) next
    m <- regmatches(x, regexec(row_re, x, perl = TRUE))[[1]]
    if (length(m) == 8) {
      spec <- if (nzchar(m[[8]])) m[[8]] else NA_character_
      rows[[length(rows) + 1L]] <- .qci_row(
        kind = "frequency", method = if (nzchar(m[[3]])) m[[3]] else NA_character_,
        method_name = trimws(m[[2]]), data_raw = sprintf("QC %s, regular %s", m[[4]], m[[5]]),
        value_pct = .qci_num(m[[6]]), limit_low = .qci_num(m[[7]]),
        comment = paste(stats::na.omit(c(qc_type, spec)), collapse = "; "),
        source_page = page[[i]])
      next
    }
    if (grepl("^\\S", x) && !grepl("[0-9]+\\s+[0-9]+", x)) {
      qc_type <- trimws(x)
      next
    }
    if (grepl("^\\s+[0-9]+\\s*$", x)) next   # a stray count digit of the PDF layer
    warn <- c(warn, sprintf("unplaced frequency line (page %d): %s", page[[i]], trimws(x)))
  }
  list(rows = if (length(rows)) do.call(rbind, rows) else .qci_empty_outliers(), warnings = warn)
}

# ---- the parser ------------------------------------------------------------------------------

#' Parse the text of an ALS QCI (R-19.18 - R-19.20)
#'
#' @param lines character vector, the PDF text split on "\n" with pages joined
#'   by "\f".
#' @return `list(header, summary, outliers, warnings)`: `header` has
#'   `work_order`, `issue_date` (Date), `n_received`, `n_analysed`; `summary`
#'   is one logical per Summary-of-Outliers bullet (NA when unrecognised);
#'   `outliers` a data.frame of lab_qc_outlier columns; `warnings` a character
#'   vector (any warning makes the stored report `partial`).
#' @keywords internal
#' @noRd
.qci_parse <- function(lines) {
  lines <- as.character(lines)
  lines[is.na(lines)] <- ""
  lines <- enc2utf8(lines)
  pg <- .qci_pages(lines)
  text <- pg$text
  header <- .qci_header(text, pg$page)
  warn <- character(0)
  for (k in names(header)) {
    if (is.na(header[[k]])) warn <- c(warn, sprintf("header field %s not found", k))
  }
  sm <- .qci_summary(text, pg$page, pg$skip)
  warn <- c(warn, sm$warnings)
  sec <- .qci_sections(text, pg$skip, sm$end)
  use <- !sec$skip
  pick <- function(t) which(sec$type %in% t & use)
  qc <- .qci_parse_qc(text, pg$page, pick("qc"))
  ht <- .qci_parse_ht(text, pg$page, pick("ht"))
  fr <- .qci_parse_freq(text, pg$page, pick("freq"))
  warn <- c(warn, qc$warnings, ht$warnings, fr$warnings)
  out <- rbind(qc$rows, ht$rows, fr$rows)
  rownames(out) <- NULL
  # The Summary and the tables must agree (an outlier table the bullets deny,
  # or a bullet whose table is empty, is a layout the parser did not follow).
  have <- c(mb = "mb", dup = "dup", lcs = "lcs", ms = "ms", surrogate = "surrogate",
            holding_time = "holding_time", frequency = "frequency")
  for (k in names(have)) {
    s <- sm$summary[[k]]
    nk <- sum(out$kind == have[[k]])
    if (isTRUE(s) && nk == 0) warn <- c(warn, sprintf("Summary reports %s outliers but none were parsed", k))
    if (isFALSE(s) && nk > 0) warn <- c(warn, sprintf("Summary reports no %s outliers but %d were parsed", k, nk))
  }
  list(header = header, summary = sm$summary, outliers = out, warnings = unique(warn))
}

# ---- storage: lab_qc_report / lab_qc_outlier (R-19.8, R-19.9, R-19.16) ----------------------

# The asset's report kind from its filename token: `_QCI` -> QCI, `_QC` -> QC.
.lab_qc_kind <- function(filename) {
  # R-22.S: a sample receipt notification (`ES#######_0_SRN_<digits>.pdf`).
  if (grepl("(?i)_SRN_[0-9]+(\\[[0-9]+\\])?\\.[a-z0-9]+$", filename, perl = TRUE)) return("SRN")
  if (grepl("(?i)_QCI(\\[[0-9]+\\])?\\.[a-z0-9]+$", filename, perl = TRUE)) return("QCI")
  if (grepl("(?i)_QC(\\[[0-9]+\\])?\\.[a-z0-9]+$", filename, perl = TRUE)) return("QC")
  NA_character_
}

# The PDF's text lines (pages joined by "\f"), or a condition on failure.
.lab_qc_read <- function(path) {
  tryCatch({
    if (!file.exists(path)) stop("file not found: ", path)
    if (isTRUE(file.size(path) == 0)) stop("the file is empty (0 bytes)")
    pages <- suppressWarnings(suppressMessages(pdftools::pdf_text(path)))
    if (length(pages) == 0) stop("the PDF has no pages")
    lines <- strsplit(paste(pages, collapse = "\f"), "\n", fixed = TRUE)[[1]]
    enc2utf8(lines)
  }, error = function(e) e)
}

#' Link outlier rows to our samples (R-19.21), first match wins:
#' 1. lab_id (of this work order) -> sample_lab_id;
#' 2. (work order, client ID) -> the work order's samples whose feature the
#'    client ID resolves to, live at the sample date - exactly one, else NULL.
#' An `Anonymous` row (another client's sample) is never linked.
#' @keywords internal
#' @noRd
.lab_qc_link <- function(con, o, work_order) {
  o$uuid_sample <- rep(NA_character_, nrow(o))
  if (nrow(o) == 0 || is.na(work_order)) return(o)
  anon <- !is.na(o$client_id) & tolower(trimws(o$client_id)) == "anonymous"
  # Route 1.
  r1 <- !anon & !is.na(o$lab_id) & substr(o$lab_id, 1, 9) == work_order
  if (any(r1) && DBI::dbExistsTable(con, "sample_lab_id")) {
    sl <- DBI::dbGetQuery(con, "SELECT lab_id, uuid_sample FROM sample_lab_id WHERE work_order = ?",
                          params = list(work_order))
    hit <- match(o$lab_id[r1], sl$lab_id)
    o$uuid_sample[r1] <- sl$uuid_sample[hit]
  }
  # Route 2.
  r2 <- is.na(o$uuid_sample) & !anon & !is.na(o$client_id) & !grepl("^-+$", o$client_id)
  if (!any(r2)) return(o)
  s <- DBI::dbGetQuery(con, "
    SELECT s.uuid AS sample, fa.uuid_feature AS uuid_feature, COALESCE(s.datetime, s.date) AS ts
      FROM \"sample\" s
      JOIN project p ON p.uuid = s.uuid_project
      LEFT JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
     WHERE p.name = ?", params = list(work_order))
  if (nrow(s) == 0) return(o)
  s$date <- .flags_syd_date(s$ts)
  reg <- list(feature = DBI::dbGetQuery(con, "SELECT * FROM feature"),
              feature_alias = DBI::dbGetQuery(con, "SELECT * FROM feature_alias"))
  ids <- unique(o$client_id[r2])
  link <- vapply(ids, function(cid) {
    ok <- vapply(seq_len(nrow(s)), function(j) {
      if (is.na(s$uuid_feature[[j]])) return(FALSE)
      cand <- .rc_feature_candidates(cid, s$date[[j]], reg)
      s$uuid_feature[[j]] %in% cand$uuid_feature
    }, logical(1))
    if (sum(ok) == 1) s$sample[ok] else NA_character_
  }, character(1))
  o$uuid_sample[r2] <- unname(link[match(o$client_id[r2], ids)])
  o
}

#' Parse one retained ALS QC asset into lab_qc_report / lab_qc_outlier
#'
#' R-19.16: dispatches on the filename token (`_QCI` -> the QCI parser; `_QC`
#' -> a `partial` report until the QC.pdf parser exists). A parse failure is
#' stored as an `unreadable` report, never raised. A report already stored at
#' the current parser version is left alone; one at any other version is
#' replaced, report and outliers, in one transaction (R-19.9). A DB without
#' the migration-048 tables is a no-op.
#'
#' @param con an open read-write connection.
#' @param uuid_asset the `asset` row.
#' @param path the PDF (the source or the archived copy).
#' @param actor change_log actor.
#' @return the report status (invisibly), or NULL when nothing was done.
#' @keywords internal
#' @noRd
lab_qc_ingest <- function(con, uuid_asset, path, actor = "ingest", force = FALSE) {
  if (!DBI::dbExistsTable(con, "lab_qc_report") || !DBI::dbExistsTable(con, "lab_qc_outlier")) {
    return(invisible(NULL))
  }
  a <- DBI::dbGetQuery(con, "SELECT a.filename, a.hash, p.name AS project FROM asset a
                              LEFT JOIN project p ON p.uuid = a.uuid_project WHERE a.uuid = ?",
                       params = list(uuid_asset))
  filename <- if (nrow(a) && !is.na(a$filename[[1]])) a$filename[[1]] else basename(path)
  kind <- .lab_qc_kind(filename)
  if (is.na(kind)) return(invisible(NULL))
  # R-22.S: receipt columns/tables exist only after the operator migration. An
  # SRN has nowhere to go before it (skipped silently); a QCI is stored as
  # before, without received_at.
  receipt <- .lab_receipt_ready(con)
  if (kind == "SRN" && !receipt) return(invisible(NULL))
  prev <- DBI::dbGetQuery(con, "SELECT uuid, parser_version FROM lab_qc_report WHERE uuid_asset = ?",
                          params = list(uuid_asset))
  if (!force && nrow(prev) && identical(prev$parser_version[[1]], .qci_parser_version)) {
    return(invisible(NULL))
  }
  m <- regmatches(filename, regexpr("E[A-Z][0-9]{7}", filename))
  file_wo <- if (length(m)) m else if (nrow(a)) a$project[[1]] else NA_character_
  hash <- if (nrow(a)) a$hash[[1]] else NA_character_

  rep <- list(work_order = file_wo, issue_date = as.Date(NA), n_received = NA_integer_,
              n_analysed = NA_integer_, summary = NA_character_, status = "unreadable",
              message = NA_character_)
  out <- .qci_empty_outliers()
  srn <- NULL
  received_at <- as.POSIXct(NA_real_, origin = "1970-01-01", tz = "UTC")
  lines <- .lab_qc_read(path)
  if (inherits(lines, "condition")) {
    rep$message <- paste("PDF unreadable:", conditionMessage(lines))
  } else if (kind == "SRN") {
    # R-22.S: the sample receipt notification.
    res <- tryCatch(.srn_parse(lines), error = function(e) e)
    if (inherits(res, "error")) {
      rep$message <- paste("SRN parse failed:", conditionMessage(res))
    } else if (is.null(res)) {
      rep$message <- "not a sample receipt notification (no SRN title found)"
    } else {
      srn <- res
      h <- res$header
      msgs <- res$warnings
      rep$status <- if (length(msgs)) "partial" else "parsed"
      if (!is.na(h$work_order) && !is.na(file_wo) && h$work_order != file_wo) {
        msgs <- c(msgs, sprintf("header Work Order %s differs from the filename's %s; the header wins",
                                h$work_order, file_wo))
      }
      if (!is.na(h$work_order)) rep$work_order <- h$work_order
      rep$issue_date <- h$issue_date
      rep$n_received <- h$n_received
      rep$n_analysed <- h$n_analysed
      rep$message <- if (length(msgs)) paste(msgs, collapse = "; ") else NA_character_
    }
  } else if (kind == "QC") {
    rep$status <- "partial"
    rep$message <- "QC.pdf not parsed yet (PLAN-19 phase 3)"
  } else {
    res <- tryCatch(.qci_parse(lines), error = function(e) e)
    if (inherits(res, "error")) {
      rep$message <- paste("QCI parse failed:", conditionMessage(res))
    } else {
      h <- res$header
      msgs <- res$warnings
      rep$status <- if (length(msgs)) "partial" else "parsed"
      if (!is.na(h$work_order) && !is.na(file_wo) && h$work_order != file_wo) {
        # As crosstab Workgroup: the header wins, the disagreement is noted.
        msgs <- c(msgs, sprintf("header Work Order %s differs from the filename's %s; the header wins",
                                h$work_order, file_wo))
      }
      if (!is.na(h$work_order)) rep$work_order <- h$work_order
      rep$issue_date <- h$issue_date
      rep$n_received <- h$n_received
      rep$n_analysed <- h$n_analysed
      rep$summary <- as.character(jsonlite::toJSON(res$summary, auto_unbox = TRUE, na = "null",
                                                   null = "null"))
      rep$message <- if (length(msgs)) paste(msgs, collapse = "; ") else NA_character_
      out <- res$outliers
      received_at <- .qci_received_at(lines)
    }
  }
  out <- .lab_qc_link(con, out, rep$work_order)

  report <- data.frame(uuid = uuid::UUIDgenerate(), uuid_asset = uuid_asset,
                       work_order = rep$work_order, kind = kind, issue_date = rep$issue_date,
                       n_received = as.integer(rep$n_received), n_analysed = as.integer(rep$n_analysed),
                       summary = rep$summary, status = rep$status, message = rep$message,
                       parser_version = .qci_parser_version, parsed_at = Sys.time(),
                       stringsAsFactors = FALSE)
  if (receipt && kind == "QCI") report$received_at <- received_at
  kids <- list()
  if (receipt && kind == "SRN") {
    h <- if (is.null(srn)) list() else srn$header
    pick <- function(k, na) if (is.null(h[[k]])) na else h[[k]]
    report$received_at <- if (is.null(srn)) received_at else h$received_at
    report$client_due_date <- pick("client_due_date", as.Date(NA))
    report$scheduled_report_date <- pick("scheduled_report_date", as.Date(NA))
    report$delivery_mode <- pick("delivery_mode", NA_character_)
    report$security_seal <- pick("security_seal", NA_character_)
    report$n_coolers <- as.integer(pick("n_coolers", NA_integer_))
    report$temp_min_c <- as.numeric(pick("temp_min_c", NA_real_))
    report$temp_max_c <- as.numeric(pick("temp_max_c", NA_real_))
    report$cooling_medium <- pick("cooling_medium", NA_character_)
    report$cooling_present <- as.logical(pick("cooling_present", NA))
    report$n_container_noncompliances <- as.integer(pick("n_container_noncompliances", NA_integer_))
    report$n_holding_breaches <- as.integer(pick("n_holding_breaches", NA_integer_))
    if (!is.null(srn)) {
      mk <- function(n) uuid::UUIDgenerate(n = n)
      if (length(srn$temps)) {
        kids$lab_receipt_temperature <- data.frame(
          uuid = mk(length(srn$temps)), uuid_report = report$uuid,
          position = seq_along(srn$temps), temp_c = srn$temps, stringsAsFactors = FALSE)
      }
      if (length(srn$comments)) {
        kids$lab_receipt_comment <- data.frame(
          uuid = mk(length(srn$comments)), uuid_report = report$uuid,
          position = seq_along(srn$comments), text = srn$comments, stringsAsFactors = FALSE)
      }
      if (nrow(srn$breaches)) {
        kids$lab_receipt_holding_breach <- cbind(
          data.frame(uuid = mk(nrow(srn$breaches)), uuid_report = report$uuid, stringsAsFactors = FALSE),
          srn$breaches)
      }
    }
  }
  if (nrow(out)) {
    out <- cbind(data.frame(uuid = uuid::UUIDgenerate(n = nrow(out)), uuid_report = report$uuid,
                            work_order = rep$work_order, stringsAsFactors = FALSE), out)
    out$days_overdue <- as.integer(out$days_overdue)
    out$source_page <- as.integer(out$source_page)
  }
  reason <- sprintf("ALS lab QC report %s (PLAN-19 R-19.16)", filename)
  db_transaction(con, function(con) {
    if (nrow(prev)) {
      # R-19.9: a stale parser_version is replaced, report and rows together.
      for (u in prev$uuid) {
        ids <- DBI::dbGetQuery(con, "SELECT uuid FROM lab_qc_outlier WHERE uuid_report = ?",
                               params = list(u))$uuid
        for (x in ids) db_delete(con, "lab_qc_outlier", uuid = x, actor = actor, reason = reason)
        if (receipt) {
          for (t in names(.lab_receipt_ddl)) {
            for (x in DBI::dbGetQuery(con, sprintf("SELECT uuid FROM %s WHERE uuid_report = ?", t),
                                      params = list(u))$uuid) {
              db_delete(con, t, uuid = x, actor = actor, reason = reason)
            }
          }
        }
        db_delete(con, "lab_qc_report", uuid = u, actor = actor, reason = reason)
      }
    }
    db_append(con, "lab_qc_report", report, actor = actor, reason = reason, source_hash = hash)
    if (nrow(out)) db_append(con, "lab_qc_outlier", out, actor = actor, reason = reason,
                             source_hash = hash)
    for (t in names(kids)) db_append(con, t, kids[[t]], actor = actor, reason = reason, source_hash = hash)
  })
  invisible(report$status)
}

#' Parse every archived ALS QC report not yet parsed (R-19.17)
#'
#' Applies the lab-QC parse step to every `QC`-typed asset whose archived copy
#' exists and that has no `lab_qc_report` row at the current parser version.
#' Operator-run (migration 052). Each asset is its own transaction, so one bad
#' file never undoes the rest.
#'
#' @param db the database file.
#' @param actor the change_log actor, e.g. `"052-lab-qc-backfill"`.
#' @return a data.frame, one row per asset considered: `uuid_asset`,
#'   `filename`, `result` (`parsed`, `partial`, `unreadable`, `current`,
#'   `no_archive`), invisibly.
#' @export
lab_qc_backfill <- function(db = st_config("live_db"), actor = "lab_qc_backfill") {
  checkmate::assert_string(db)
  checkmate::assert_string(actor)
  with_db_write(function(con) {
    if (!DBI::dbExistsTable(con, "lab_qc_report")) {
      cli::cli_abort("lab_qc_backfill(): {.path {db}} has no lab_qc_report table (migration 048 first).",
                     class = "sampletidy_error")
    }
    out <- .lab_qc_backfill_con(con, actor)
    tb <- table(out$result)
    cli::cli_inform("lab_qc_backfill(): {paste(names(tb), tb, sep = ' ', collapse = ', ')}")
    invisible(out)
  }, db = db)
}

# The backfill on an open connection (migration 052 runs it inside its own
# transaction). The archived copy is `<archive_dir>/<asset uuid>/<filename>`.
.lab_qc_backfill_con <- function(con, actor, archive_dir = st_config("archive_dir")) {
  a <- DBI::dbGetQuery(con, "
    SELECT a.uuid, a.filename, a.type, r.parser_version
      FROM asset a LEFT JOIN lab_qc_report r ON r.uuid_asset = a.uuid
     WHERE a.type IN ('QC', 'QA') ORDER BY a.filename, a.uuid")
  # R-22.S: QC-typed assets, plus the QA-typed sample receipt notifications.
  a <- a[a$type == "QC" | (!is.na(a$filename) & vapply(a$filename, function(f) identical(.lab_qc_kind(f), "SRN"), logical(1))), , drop = FALSE]
  res <- character(nrow(a))
  for (i in seq_len(nrow(a))) {
    if (identical(a$parser_version[[i]], .qci_parser_version)) {
      res[[i]] <- "current"
      next
    }
    path <- file.path(archive_dir, a$uuid[[i]], a$filename[[i]])
    if (is.na(a$filename[[i]]) || !file.exists(path)) {
      res[[i]] <- "no_archive"
      next
    }
    st <- lab_qc_ingest(con, a$uuid[[i]], path, actor = actor)
    res[[i]] <- if (is.null(st)) "skipped" else st
  }
  data.frame(uuid_asset = a$uuid, filename = a$filename, result = res, stringsAsFactors = FALSE)
}

#' Re-parse one ALS QC / QCI / SRN asset whatever its stored parser version
#'
#' R-22.S (Robin 2026-10-25): the same parse and replace as [lab_qc_ingest()]
#' but forced, for a report stored before a column existed (e.g. a QCI's
#' `received_at`). The report and its child rows are replaced in one
#' transaction; the report gets a new uuid and is never duplicated.
#'
#' @param con an open read-write connection.
#' @param uuid_asset the `asset` row.
#' @param path the PDF; `NULL` reads `<archive_dir>/<asset uuid>/<filename>`.
#' @param actor change_log actor.
#' @return the report status (invisibly), or NULL when nothing was done (not a
#'   lab report, or a DB without the receipt schema for an SRN).
#' @keywords internal
#' @noRd
lab_qc_reparse <- function(con, uuid_asset, path = NULL, actor = "lab_qc_reparse") {
  checkmate::assert_string(uuid_asset)
  checkmate::assert_string(actor)
  if (is.null(path)) {
    f <- DBI::dbGetQuery(con, "SELECT filename FROM asset WHERE uuid = ?", params = list(uuid_asset))$filename
    if (!length(f) || is.na(f[[1]])) {
      cli::cli_abort("lab_qc_reparse(): no asset {.val {uuid_asset}} with a filename.", class = "sampletidy_error")
    }
    path <- file.path(st_config("archive_dir"), uuid_asset, f[[1]])
  }
  checkmate::assert_string(path)
  lab_qc_ingest(con, uuid_asset, path, actor = actor, force = TRUE)
}
