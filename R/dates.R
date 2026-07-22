# Named format presets (CONTRACT / PLAN-02 R-2.4, pinned). Each preset is a
# vector of `strptime()` format strings, tried in order - the first one that
# parses an element wins. `esdat`/`iso` list the datetime form before the
# date-only form so a clock time is not silently dropped when present.
.lab_datetime_formats <- list(
  # ESdat exports vary the sample/analysed date rendering: the long form
  # `"07 May 2024 11:30"` (space, 4-digit year) and the short form
  # `"07-May-24 11:30"` (hyphen, 2-digit year) both occur in the real corpus.
  # Both dialects are accepted; datetime forms precede their date-only
  # counterparts so a clock time is never silently dropped to midnight.
  esdat    = c("%d %b %Y %H:%M", "%d %b %Y", "%d-%b-%y %H:%M", "%d-%b-%y"),
  crosstab = c("%d/%m/%Y"),
  iso      = c("%Y-%m-%d %H:%M", "%Y-%m-%d")
)

#' Resolve a `formats` argument to a vector of `strptime()` format strings
#' @keywords internal
.resolve_lab_datetime_formats <- function(formats) {
  checkmate::assert_character(formats, min.len = 1)
  if (length(formats) == 1 && formats %in% names(.lab_datetime_formats)) {
    return(.lab_datetime_formats[[formats]])
  }
  formats
}

#' Parse lab-report datetime strings into POSIXct
#'
#' Tries each format in the resolved `formats` preset in order against every
#' element of `x`, keeping the first successful parse; elements that match no
#' format become `NA` (never silently reinterpreted - e.g. `"13/13/2025"`
#' under the `"crosstab"` `"%d/%m/%Y"` preset is `NA`, not rolled over into a
#' different month/year). A wall-clock time that does not exist in `tz` (a
#' DST spring-forward gap, e.g. `"05 Oct 2025 02:30"` in
#' `"Australia/Sydney"`) is likewise `NA` rather than silently normalised to
#' a different instant (e.g. that day's midnight) - detected by comparing
#' the literal parsed fields against the tz-normalised result, not by string
#' round-trip. An ambiguous fall-back time (ie one that occurs twice, e.g.
#' the first Sunday of April in `"Australia/Sydney"`) is unaffected and
#' still parses non-`NA`.
#'
#' @param x character vector of raw datetime strings.
#' @param formats either one of the pinned preset names `"esdat"`,
#'   `"crosstab"`, `"iso"`, or a character vector of `strptime()` format
#'   strings to try directly, in order.
#' @param tz timezone to interpret naive lab datetimes in. Defaults to
#'   `"Australia/Sydney"` (CONTRACT A9).
#' @return a `POSIXct` vector, same length as `x`, in `tz`.
#' @keywords internal
#' @noRd
parse_lab_datetime <- function(x, formats, tz = "Australia/Sydney") {
  checkmate::assert_character(x, min.len = 0)
  checkmate::assert_string(tz)
  fmt_vec <- .resolve_lab_datetime_formats(formats)

  n <- length(x)
  trimmed <- trimws(x)
  result <- as.POSIXct(rep(NA_real_, n), origin = "1970-01-01", tz = tz)
  if (n == 0) {
    return(result)
  }

  remaining <- !is.na(trimmed) & trimmed != ""
  for (fmt in fmt_vec) {
    idx <- which(remaining)
    if (length(idx) == 0) {
      break
    }
    parsed <- strptime(trimmed[idx], format = fmt, tz = tz)
    # `matched`: strptime successfully read literal date/time fields out of
    # the string for this format - true regardless of whether the resulting
    # local instant actually exists (mktime's handling of a DST gap is
    # platform-dependent: some libcs return NA outright for a nonexistent
    # wall-clock time, others silently normalise it to a nearby valid
    # instant with shifted fields). A total non-match (format simply didn't
    # fit the string) leaves these fields NA too, so `matched` correctly
    # excludes it.
    matched <- !is.na(parsed$year)
    ok <- !is.na(parsed)
    if (any(ok)) {
      ct <- as.POSIXct(parsed[ok])
      lt_lit  <- parsed[ok]              # POSIXlt: the literal fields strptime read
      lt_norm <- as.POSIXlt(ct, tz = tz) # normalised back to the tz
      nonexistent <- (lt_lit$hour != lt_norm$hour) | (lt_lit$min != lt_norm$min) |
        (lt_lit$mday != lt_norm$mday) | (lt_lit$mon  != lt_norm$mon)  |
        (lt_lit$year != lt_norm$year)
      nonexistent[is.na(nonexistent)] <- FALSE
      ct[nonexistent] <- as.POSIXct(NA_real_, origin = "1970-01-01", tz = tz)
      result[idx[ok]] <- ct
      remaining[idx[ok]] <- FALSE   # CRITICAL: gap elements stay NA and must NOT
                                     # fall through to a later date-only format
                                     # (which would re-drop the clock to
                                     # midnight - the same bug).
    }
    # A DST gap time that mktime rejected outright (`matched` but not `ok`) -
    # the other platform behaviour for the same underlying defect. Must also
    # be excluded from `remaining`, for the identical reason as above.
    gap <- matched & !ok
    if (any(gap)) {
      result[idx[gap]] <- as.POSIXct(NA_real_, origin = "1970-01-01", tz = tz)
      remaining[idx[gap]] <- FALSE
    }
  }

  result
}

#' Does a lab datetime string include a clock-time component?
#'
#' Drives the CONTRACT A11 date-vs-datetime split (`sample.date` is always
#' set; `sample.datetime` only when a clock time was actually present in the
#' source).
#'
#' @param x character vector of raw datetime strings.
#' @return logical vector, same length as `x`.
#' @keywords internal
#' @noRd
has_clock_time <- function(x) {
  checkmate::assert_character(x, min.len = 0)
  stringr::str_detect(x, "\\d{1,2}:\\d{2}")
}

#' Convert an Excel serial date number to a `Date`
#'
#' Uses the Excel-for-Windows epoch `1899-12-30` (which already accounts for
#' Lotus 1-2-3's spurious 1900 leap day, the usual source of Excel
#' off-by-one date bugs).
#'
#' @param n numeric vector of Excel serial date numbers.
#' @return a `Date` vector, same length as `n`.
#' @keywords internal
#' @noRd
excel_date <- function(n) {
  checkmate::assert_numeric(n, min.len = 0)
  as.Date(n, origin = "1899-12-30")
}
