# R-22.S (Robin 2026-10-25, "include all the temp, etc data as their own
# columns"): the ALS sample receipt notification (SRN) parser and the receipt
# schema. An SRN is parsed from `pdftotext -layout` text (the same lines
# .lab_qc_read() gives the QCI parser) into one lab_qc_report row of kind 'SRN'
# whose receipt facts are columns, plus three child tables hung off
# lab_qc_report.uuid (no declared FK - migration 048's reasoning):
# lab_receipt_temperature, lab_receipt_holding_breach, lab_receipt_comment.
# Like the QCI parser, nothing here judges a value; the lab_receipt_warm
# db_check does.

# ---- the schema (single source; the operator migration calls this) --------------------

# lab_qc_report gains these columns. NULL on QC/QCI rows except `received_at`,
# which a QCI front page also prints. received_at is a UTC instant (the lab's
# Australia/Sydney local time converted), like every stored timestamp.
.lab_receipt_report_cols <- c(
  received_at = "TIMESTAMP", client_due_date = "DATE", scheduled_report_date = "DATE",
  delivery_mode = "VARCHAR", security_seal = "VARCHAR", n_coolers = "INTEGER",
  temp_min_c = "DOUBLE", temp_max_c = "DOUBLE", cooling_medium = "VARCHAR",
  cooling_present = "BOOLEAN", n_container_noncompliances = "INTEGER",
  n_holding_breaches = "INTEGER"
)

.lab_receipt_ddl <- list(
  lab_receipt_temperature = "
    CREATE TABLE lab_receipt_temperature (
      uuid VARCHAR PRIMARY KEY, uuid_report VARCHAR, position INTEGER, temp_c DOUBLE)",
  lab_receipt_holding_breach = "
    CREATE TABLE lab_receipt_holding_breach (
      uuid VARCHAR PRIMARY KEY, uuid_report VARCHAR, lab_sample_id VARCHAR,
      client_sample_id VARCHAR, method VARCHAR, due_date DATE, days_overdue INTEGER)",
  lab_receipt_comment = "
    CREATE TABLE lab_receipt_comment (
      uuid VARCHAR PRIMARY KEY, uuid_report VARCHAR, position INTEGER, text VARCHAR)"
)

#' Add the R-22.S receipt columns and tables to a DB that has lab_qc_report
#' (migration 048). Columns/tables already present are left alone.
#' @keywords internal
#' @noRd
.lab_receipt_create_schema <- function(con) {
  have <- DBI::dbGetQuery(con, "SELECT column_name FROM information_schema.columns
                                 WHERE table_name = 'lab_qc_report'")$column_name
  for (k in setdiff(names(.lab_receipt_report_cols), have)) {
    DBI::dbExecute(con, sprintf("ALTER TABLE lab_qc_report ADD COLUMN %s %s", k,
                                .lab_receipt_report_cols[[k]]))
  }
  for (t in setdiff(names(.lab_receipt_ddl), DBI::dbListTables(con))) {
    DBI::dbExecute(con, .lab_receipt_ddl[[t]])
  }
  invisible(con)
}

# Does this DB carry the receipt schema? (False before the operator migration.)
.lab_receipt_ready <- function(con) {
  if (!DBI::dbExistsTable(con, "lab_qc_report")) return(FALSE)
  all(names(.lab_receipt_ddl) %in% DBI::dbListTables(con)) &&
    all(names(.lab_receipt_report_cols) %in% DBI::dbListFields(con, "lab_qc_report"))
}

# ---- small pieces ------------------------------------------------------------------------

.srn_tz <- "Australia/Sydney"

# A lab-local "dd-Mon-yyyy" (+ optional "HH:MM") -> UTC POSIXct. A date alone
# is 00:00 Sydney (the same convention as sample.date). NA when unparseable.
.srn_utc <- function(date_str, time_str = NA_character_) {
  d <- .qci_date(date_str)
  if (is.na(d)) return(as.POSIXct(NA_real_, origin = "1970-01-01", tz = "UTC"))
  hm <- if (!is.na(time_str) && grepl("^[0-9]{1,2}:[0-9]{2}$", time_str)) time_str else "00:00"
  x <- as.POSIXct(paste(format(d, "%Y-%m-%d"), hm), format = "%Y-%m-%d %H:%M", tz = .srn_tz)
  attr(x, "tzone") <- "UTC"
  x
}

# "Date Samples Received" off a QCI/QC front page (date only), as UTC.
.qci_received_at <- function(lines) {
  re <- paste0("Date Samples Received\\s*:\\s*(", .qci_date_re, ")")
  for (x in utils::head(lines, 80L)) {
    m <- regmatches(x, regexec(re, x, perl = TRUE))[[1]]
    if (length(m) == 2) return(.srn_utc(m[[2]]))
  }
  as.POSIXct(NA_real_, origin = "1970-01-01", tz = "UTC")
}

.srn_empty <- function() list(
  header = list(), temps = numeric(0), comments = character(0),
  breaches = data.frame(lab_sample_id = character(0), client_sample_id = character(0),
                        method = character(0), due_date = as.Date(character(0)),
                        days_overdue = integer(0), stringsAsFactors = FALSE),
  warnings = character(0))

# ---- the parser --------------------------------------------------------------------------

#' Parse the text of an ALS sample receipt notification (R-22.S)
#'
#' @param lines character vector, the PDF text split on "\n" with pages joined
#'   by "\f".
#' @return `NULL` when the text is not an SRN, else `list(header, temps,
#'   comments, breaches, warnings)`; any warning makes the stored report
#'   `partial`.
#' @keywords internal
#' @noRd
.srn_parse <- function(lines) {
  lines <- as.character(lines)
  lines[is.na(lines)] <- ""
  lines <- enc2utf8(sub("^\f", "", lines))
  if (!any(grepl("SAMPLE RECEIPT NOTIFICATION", lines, fixed = TRUE))) return(NULL)
  out <- .srn_empty()
  warn <- character(0)
  grab <- function(re, from = lines) {
    for (x in from) {
      m <- regmatches(x, regexec(re, x, perl = TRUE))[[1]]
      if (length(m) >= 2) return(m[-1])
    }
    NULL
  }
  d_re <- .qci_date_re
  h <- list()
  wo <- grab("Work Order\\s*:\\s*(E[A-Z][0-9]{7})")
  h$work_order <- if (is.null(wo)) NA_character_ else wo[[1]]
  rc <- grab(paste0("Date Samples Received\\s*:\\s*(", d_re, ")(?:\\s+([0-9]{1,2}:[0-9]{2}))?"))
  h$received_at <- if (is.null(rc)) .srn_utc(NA) else .srn_utc(rc[[1]], if (length(rc) > 1) rc[[2]] else NA_character_)
  h$issue_date <- .qci_date(grab(paste0("Issue Date\\s*:\\s*(", d_re, ")"))[1])
  h$client_due_date <- .qci_date(grab(paste0("Client Requested Due\\s*:\\s*(", d_re, ")"))[1])
  h$scheduled_report_date <- .qci_date(grab(paste0("Scheduled Reporting Date\\s*:\\s*(", d_re, ")"))[1])
  md <- grab("Mode of Delivery\\s*:\\s*(.*?)\\s*(?:\\s{2,}Security Seal\\s*:.*)?$")
  h$delivery_mode <- if (is.null(md) || !nzchar(md[[1]])) NA_character_ else md[[1]]
  ss <- grab("Security Seal\\s*:\\s*(\\S.*?)\\s*$")
  h$security_seal <- if (is.null(ss)) NA_character_ else ss[[1]]
  nc <- grab("No\\. of coolers/boxes\\s*:\\s*([0-9]+)")
  h$n_coolers <- if (is.null(nc)) NA_integer_ else as.integer(nc[[1]])
  sr <- grab("No\\. of samples received / analysed\\s*:\\s*([0-9]+)\\s*/\\s*([0-9]+)")
  h$n_received <- if (is.null(sr)) NA_integer_ else as.integer(sr[[1]])
  h$n_analysed <- if (is.null(sr)) NA_integer_ else as.integer(sr[[2]])
  for (k in c("work_order", "issue_date", "n_received", "n_analysed", "received_at")) {
    if (is.na(h[[k]])) warn <- c(warn, sprintf("header field %s not found", k))
  }

  # Temperature: the cell after "Temperature :" plus its wrapped continuation
  # lines (indented, up to the "Receipt Detail" line).
  ti <- grep("Temperature\\s*:", lines, perl = TRUE)[1]
  temps <- numeric(0)
  h$cooling_medium <- NA_character_
  h$cooling_present <- NA
  if (!is.na(ti)) {
    cell <- sub(".*Temperature\\s*:\\s*", "", lines[[ti]], perl = TRUE)
    j <- ti + 1L
    while (j <= length(lines) && nzchar(trimws(lines[[j]])) && !grepl("^\\s*Receipt Detail", lines[[j]]) &&
           grepl("^\\s{20,}", lines[[j]])) {
      cell <- paste(cell, trimws(lines[[j]]))
      j <- j + 1L
    }
    cell <- trimws(gsub("\\s+", " ", cell))
    tm <- regmatches(cell, gregexpr("-?[0-9]+(?:\\.[0-9]+)?\\s*'?\\s*C\\b", cell, perl = TRUE))[[1]]
    temps <- as.numeric(sub("\\s*'?\\s*C$", "", tm))
    cm <- regmatches(cell, regexec("\\s-\\s+(.+?)\\s+(not present|present)\\b", cell,
                                   perl = TRUE, ignore.case = TRUE))[[1]]
    if (length(cm) == 3) {
      h$cooling_medium <- cm[[2]]
      h$cooling_present <- tolower(cm[[3]]) == "present"
    }
    if (!length(temps) && !grepl("not recorded", cell, ignore.case = TRUE)) {
      warn <- c(warn, sprintf("temperature not understood: %s", cell))
    }
  } else {
    warn <- c(warn, "header field temperature not found")
  }
  h$temp_min_c <- if (length(temps)) min(temps) else NA_real_
  h$temp_max_c <- if (length(temps)) max(temps) else NA_real_

  # Section boundaries are column-0 headings (the comment bullet that lists
  # them is indented).
  at <- function(re) { i <- grep(re, lines, perl = TRUE); if (length(i)) i[[1]] else NA_integer_ }
  i_gc <- at("^General Comments\\s*$")
  i_nc <- at("^Sample Container\\(s\\)/Preservation Non-Compliances\\s*$")
  i_sum <- at("^Summary of Sample\\(s\\) and Requested Analysis\\s*$")
  i_ht <- at("^Proactive Holding Time Report\\s*$")
  i_del <- at("^Requested Deliverables\\s*$")
  span <- function(a, b) if (b > a) lines[(a + 1L):b] else character(0)
  is_furniture <- function(x) grepl("right solutions\\. right partner\\.|^Issue Date\\s+:|^Page\\s+:|^Client\\s+:|^Work Order\\s+:.*Amendment", x)

  # General Comments: one row per bullet ("l" glyph at column 0); wrapped and
  # sub-item lines join the bullet above with single spaces.
  cm_out <- character(0)
  if (!is.na(i_gc)) {
    stops <- c(i_nc, i_sum, i_ht, i_del)
    stops <- stops[!is.na(stops) & stops > i_gc]
    end <- if (length(stops)) min(stops) - 1L else length(lines)
    cur <- NULL
    for (x in span(i_gc, end)) {
      if (!nzchar(trimws(x)) || is_furniture(x)) next
      b <- regmatches(x, regexec("^l\\s+(\\S.*?)\\s*$", x, perl = TRUE))[[1]]
      if (length(b) == 2) {
        if (!is.null(cur)) cm_out <- c(cm_out, cur)
        cur <- b[[2]]
      } else if (!is.null(cur)) {
        cur <- paste(cur, trimws(x))
      }
    }
    if (!is.null(cur)) cm_out <- c(cm_out, cur)
    cm_out <- trimws(gsub("\\s+", " ", cm_out))
  }

  # Container / preservation non-compliances: a count. The measured real
  # layout reads "No sample container / preservation non-compliance exists.";
  # for a non-empty table (not measured) the lab sample IDs named are counted.
  h$n_container_noncompliances <- NA_integer_
  if (!is.na(i_nc)) {
    end <- c(i_sum, i_ht, i_del); end <- end[!is.na(end) & end > i_nc]
    sec <- span(i_nc, if (length(end)) min(end) - 1L else length(lines))
    sec <- sec[!vapply(sec, is_furniture, logical(1))]
    if (any(grepl("No sample container / preservation non-compliance exists", sec, fixed = TRUE))) {
      h$n_container_noncompliances <- 0L
    } else {
      ids <- unique(unlist(regmatches(sec, gregexpr(.qci_lab_id_re, sec, perl = TRUE))))
      if (length(ids)) {
        h$n_container_noncompliances <- length(ids)
      } else {
        warn <- c(warn, "container non-compliance section not understood")
      }
    }
  } else {
    warn <- c(warn, "container non-compliance section not found")
  }

  # Summary of Sample(s): lab sample ID -> client sample ID, for the breaches.
  smap <- character(0)
  if (!is.na(i_sum)) {
    end <- c(i_ht, i_del); end <- end[!is.na(end) & end > i_sum]
    sec <- span(i_sum, if (length(end)) min(end) - 1L else length(lines))
    re <- paste0("^\\s*(", .qci_lab_id_re, ")\\s+", d_re, "(?:\\s+[0-9]{1,2}:[0-9]{2})?\\s+(\\S.*?)(?:\\s{2,}.*)?$")
    for (x in sec) {
      m <- regmatches(x, regexec(re, x, perl = TRUE))[[1]]
      if (length(m) == 3 && !m[[3]] %in% names(smap)) smap[[m[[3]]]] <- m[[2]]
    }
  }

  # Proactive Holding Time Report. Always present; a breach table lists rows
  # (client ID, container, due for extraction, due for analysis, samples
  # received, instructions received + mark) under a method line. The mark may
  # sit on the next line, so every row of the table is a breach. due_date is
  # the earlier of the two due dates; days_overdue = received - due_date.
  br <- out$breaches
  h$n_holding_breaches <- NA_integer_
  if (!is.na(i_ht)) {
    end <- if (!is.na(i_del) && i_del > i_ht) i_del - 1L else length(lines)
    sec <- span(i_ht, end)
    sec <- sec[nzchar(trimws(sec)) & !vapply(sec, is_furniture, logical(1))]
    method <- NA_character_
    tail_re <- sprintf("\\s+(----|%1$s)\\s+(----|%1$s)\\s+(----|%1$s)\\s+(----|%1$s)\\s+(----|%1$s)\\s*$", d_re)
    rows <- list()
    for (x in sec) {
      ml <- regmatches(x, regexec(paste0("^\\s?((?:", .qci_method_re, "):.*?)\\s*$"), x, perl = TRUE))[[1]]
      if (length(ml) == 2) { method <- ml[[2]]; next }
      tm <- regexpr(tail_re, x, perl = TRUE)
      if (tm < 0) next
      p <- regmatches(x, regexec(tail_re, x, perl = TRUE))[[1]]
      front <- regmatches(substr(x, 1, tm - 1L), regexec("^(\\S.*?)(?:\\s{2,}\\S.*)?$", substr(x, 1, tm - 1L), perl = TRUE))[[1]]
      if (length(front) < 2) next
      dues <- c(.qci_date(p[[2]]), .qci_date(p[[3]]))
      due <- if (all(is.na(dues))) as.Date(NA) else min(dues, na.rm = TRUE)
      recv <- .qci_date(p[[4]])
      cids <- trimws(strsplit(front[[2]], ",", fixed = TRUE)[[1]])
      for (cid in cids[nzchar(cids)]) {
        rows[[length(rows) + 1L]] <- data.frame(
          lab_sample_id = if (cid %in% names(smap)) smap[[cid]] else NA_character_,
          client_sample_id = cid, method = method, due_date = due,
          days_overdue = as.integer(recv - due), stringsAsFactors = FALSE)
      }
    }
    if (length(rows)) {
      br <- do.call(rbind, rows)
      h$n_holding_breaches <- nrow(br)
    } else if (any(grepl("received within the recommended holding times", sec, fixed = TRUE))) {
      h$n_holding_breaches <- 0L
    } else {
      warn <- c(warn, "holding-time section not understood")
    }
  } else {
    warn <- c(warn, "holding-time section not found")
  }

  list(header = h, temps = temps, comments = cm_out, breaches = br, warnings = unique(warn))
}
