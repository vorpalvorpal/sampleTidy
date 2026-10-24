# R-22.E - the delivering email's identity (Robin 2026-10-25).
#
# A delivery folder holds the attachments plus `_email.eml`, the whole message
# (often 10-25 MB, attachments inlined). The email is not attached as an asset;
# its identity goes in `ingest_email` and each `ingest_file` row routed from the
# folder names it through `ingest_file.message_id`.

# Longest header block we will read. Real blocks are a few KB; this bounds the
# read on a file with no blank line at all.
.ie_max_header_bytes <- 1024L * 1024L

#' Read the header block of an .eml (bytes up to the first blank line)
#' @return a character vector of unfolded "Name: value" lines, UTF-8, or NULL.
#' @keywords internal
#' @noRd
.ie_read_header_lines <- function(path) {
  con <- tryCatch(file(path, "rb"), error = function(e) NULL, warning = function(w) NULL)
  if (is.null(con)) {
    return(NULL)
  }
  on.exit(close(con), add = TRUE)

  buf <- raw(0)
  repeat {
    chunk <- readBin(con, "raw", 65536L)
    if (length(chunk) == 0) break
    buf <- c(buf, chunk)
    # first blank line: LF LF, or LF CR LF (CRLF files)
    nl <- which(buf == as.raw(0x0a))
    if (length(nl) >= 2) {
      nxt <- nl[-length(nl)] + 1L
      blank <- buf[nxt] == as.raw(0x0a) |
        (buf[nxt] == as.raw(0x0d) & buf[pmin(nxt + 1L, length(buf))] == as.raw(0x0a) & nxt + 1L <= length(buf))
      if (any(blank)) break
    }
    if (length(buf) >= .ie_max_header_bytes) break
  }
  if (length(buf) == 0) {
    return(NULL)
  }

  buf <- buf[buf != as.raw(0)]
  txt <- iconv(rawToChar(buf), from = "UTF-8", to = "UTF-8", sub = "?")
  if (is.na(txt)) {
    txt <- iconv(rawToChar(buf), from = "latin1", to = "UTF-8", sub = "?")
  }
  if (is.na(txt)) {
    return(NULL)
  }
  lines <- strsplit(gsub("\r", "", txt, fixed = TRUE), "\n", fixed = TRUE)[[1]]
  if (length(lines) == 0 || !nzchar(lines[[1]])) {
    return(NULL)
  }
  blank <- which(!nzchar(lines))
  if (length(blank) > 0) {
    lines <- lines[seq_len(blank[[1]] - 1L)]
  }

  # Unfold: a line starting with whitespace continues the previous header.
  out <- character(0)
  for (ln in lines) {
    if (grepl("^[ \t]", ln) && length(out) > 0) {
      out[[length(out)]] <- paste0(out[[length(out)]], ln)
    } else {
      out <- c(out, ln)
    }
  }
  out
}

# RFC 2047 encoded-words (B and Q), any charset iconv knows; whitespace between
# two adjacent encoded-words is dropped (s6.2).
.ie_decode_2047 <- function(x) {
  if (is.na(x) || !grepl("=?", x, fixed = TRUE)) {
    return(x)
  }
  pat <- "=\\?([^?\\s]+)\\?([bBqQ])\\?([^?\\s]*)\\?="
  x <- gsub(paste0("(", pat, ")\\s+(?==\\?)"), "\\1", x, perl = TRUE)
  m <- gregexpr(pat, x, perl = TRUE)
  words <- regmatches(x, m)[[1]]
  if (length(words) == 0) {
    return(x)
  }
  dec <- vapply(words, function(w) {
    p <- regmatches(w, regexec(pat, w, perl = TRUE))[[1]]
    charset <- sub("\\*.*$", "", p[[2]])
    bytes <- tryCatch(
      if (toupper(p[[3]]) == "B") {
        jsonlite::base64_dec(p[[4]])
      } else {
        q <- gsub("_", " ", p[[4]], fixed = TRUE)
        r <- charToRaw(q)
        i <- which(r == charToRaw("="))
        i <- i[i + 2L <= length(r)]
        hexok <- vapply(i, function(k) grepl("^[0-9A-Fa-f]{2}$", rawToChar(r[k + 1:2])), logical(1))
        i <- i[hexok]
        if (length(i)) {
          r[i] <- as.raw(vapply(i, function(k) strtoi(rawToChar(r[k + 1:2]), 16L), integer(1)))
          r <- r[-c(i + 1L, i + 2L)]
        }
        r
      },
      error = function(e) NULL
    )
    if (is.null(bytes)) {
      return(w)
    }
    bytes <- bytes[bytes != as.raw(0)]
    r <- tryCatch(
      iconv(list(bytes), from = charset, to = "UTF-8", sub = "?")[[1]],
      error = function(e) NA_character_
    )
    if (is.na(r)) w else r
  }, character(1), USE.NAMES = FALSE)
  regmatches(x, m) <- list(dec)
  x
}

.ie_months <- c(jan = 1L, feb = 2L, mar = 3L, apr = 4L, may = 5L, jun = 6L,
                jul = 7L, aug = 8L, sep = 9L, oct = 10L, nov = 11L, dec = 12L)

# RFC 5322 Date -> POSIXct UTC (offset applied); NA when unparseable.
.ie_parse_date <- function(x) {
  na <- as.POSIXct(NA_real_, origin = "1970-01-01", tz = "UTC")
  if (is.na(x)) {
    return(na)
  }
  x <- gsub("\\([^)]*\\)", "", x)
  m <- regmatches(x, regexec(
    "^\\s*(?:[A-Za-z]{3},\\s*)?(\\d{1,2})\\s+([A-Za-z]{3})[a-z]*\\s+(\\d{2,4})\\s+(\\d{1,2}):(\\d{2})(?::(\\d{2}))?\\s*([+-]\\d{4})?",
    x, perl = TRUE
  ))[[1]]
  if (length(m) == 0) {
    return(na)
  }
  mon <- .ie_months[tolower(m[[3]])]
  if (is.na(mon)) {
    return(na)
  }
  sec <- if (nzchar(m[[7]])) as.integer(m[[7]]) else 0L
  base <- as.POSIXct(
    sprintf("%04d-%02d-%02d %02d:%02d:%02d", as.integer(m[[4]]), mon, as.integer(m[[2]]),
            as.integer(m[[5]]), as.integer(m[[6]]), sec),
    tz = "UTC"
  )
  off <- 0
  if (nzchar(m[[8]])) {
    sgn <- if (substr(m[[8]], 1, 1) == "-") -1 else 1
    off <- sgn * (as.integer(substr(m[[8]], 2, 3)) * 3600 + as.integer(substr(m[[8]], 4, 5)) * 60)
  }
  base - off
}

#' Identity of an email, from its header block only (R-22.E)
#'
#' Reads up to the first blank line - never the body, which can be tens of MB.
#' Header names are case-insensitive; LF and CRLF are alike; binary junk is
#' tolerated.
#'
#' @param path path to an `.eml` file.
#' @return `NULL` when there is no header block or no Message-ID; else a list
#'   `(message_id, sent_at, sender, sender_name, subject, in_reply_to)`.
#' @keywords internal
#' @noRd
email_headers <- function(path) {
  lines <- tryCatch(.ie_read_header_lines(path), error = function(e) NULL)
  if (is.null(lines)) {
    return(NULL)
  }
  hit <- regexpr("^[!-9;-~]+:", lines)
  lines <- lines[hit > 0]
  if (length(lines) == 0) {
    return(NULL)
  }
  nm <- tolower(sub(":.*$", "", lines))
  val <- trimws(sub("^[^:]*:", "", lines))
  get <- function(name) {
    i <- which(nm == name)
    if (length(i) == 0 || !nzchar(val[[i[[1]]]])) NA_character_ else val[[i[[1]]]]
  }
  angle <- function(v) {
    if (is.na(v)) {
      return(NA_character_)
    }
    a <- regmatches(v, regexec("<([^>]*)>", v))[[1]]
    r <- trimws(if (length(a)) a[[2]] else v)
    if (nzchar(r)) r else NA_character_
  }

  mid <- angle(get("message-id"))
  if (is.na(mid)) {
    return(NULL)
  }

  from <- get("from")
  sender <- NA_character_
  sender_name <- NA_character_
  if (!is.na(from)) {
    a <- regmatches(from, regexec("<([^>]*)>", from))[[1]]
    if (length(a)) {
      sender <- tolower(trimws(a[[2]]))
      nmpart <- trimws(sub("<[^>]*>.*$", "", from))
      nmpart <- trimws(gsub("^\"|\"$", "", nmpart))
      if (nzchar(nmpart)) sender_name <- .ie_decode_2047(nmpart)
    } else {
      sender <- tolower(trimws(from))
    }
  }

  list(
    message_id = mid,
    sent_at = .ie_parse_date(get("date")),
    sender = sender,
    sender_name = sender_name,
    subject = .ie_decode_2047(get("subject")),
    in_reply_to = angle(get("in-reply-to"))
  )
}

#' Record the delivering email of a folder, and stamp its files (R-22.E)
#'
#' Called by [ingest_dir()] on a real run after routing. Writes one
#' `ingest_email` row (first sighting wins) through the mutation layer, then
#' sets `message_id` on the folder's routed rows where it is still NULL.
#' A malformed `_email.eml` (no header block / no Message-ID) gets one warning
#' and changes nothing else.
#' @keywords internal
#' @noRd
.ig_record_delivery_email <- function(con, path, paths, routed) {
  eml <- paths[basename(paths) == "_email.eml"]
  if (length(eml) == 0) {
    return(invisible(NULL))
  }
  h <- email_headers(eml[[1]])
  if (is.null(h)) {
    cli::cli_warn(
      "ingest_dir(): {.file _email.eml} in {.path {path}} has no readable
       Message-ID header; its files are not linked to an email."
    )
    return(invisible(NULL))
  }
  have <- DBI::dbGetQuery(
    con, "SELECT 1 FROM ingest_email WHERE message_id = ?", params = list(h$message_id)
  )
  if (nrow(have) == 0) {
    db_append(
      con, "ingest_email",
      data.frame(
        message_id = h$message_id, sent_at = h$sent_at, sender = h$sender,
        sender_name = h$sender_name, subject = h$subject,
        in_reply_to = h$in_reply_to, folder = basename(sub("/+$", "", path)),
        first_seen_at = Sys.time(), stringsAsFactors = FALSE
      ),
      actor = "ingest_dir",
      # change_log has no key column for a table without uuid; name the email.
      reason = paste0("R-22.E: delivering email ", h$message_id)
    )
  }
  ingest_file_set_message_id(con, routed$hash, h$message_id)
  invisible(NULL)
}
