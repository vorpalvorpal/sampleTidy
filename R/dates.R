# Named format presets (CONTRACT / PLAN-02 R-2.4, pinned). Each preset is a
# vector of `strptime()` format strings, tried in order - the first one that
# parses an element wins. `esdat`/`iso` list the datetime form before the
# date-only form so a clock time is not silently dropped when present.
.lab_datetime_formats <- list(
  esdat    = c("%d %b %Y %H:%M", "%d %b %Y"),
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
#' different month/year).
#'
#' @param x character vector of raw datetime strings.
#' @param formats either one of the pinned preset names `"esdat"`,
#'   `"crosstab"`, `"iso"`, or a character vector of `strptime()` format
#'   strings to try directly, in order.
#' @param tz timezone to interpret naive lab datetimes in. Defaults to
#'   `"Australia/Sydney"` (CONTRACT A9).
#' @return a `POSIXct` vector, same length as `x`, in `tz`.
#' @export
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
    ok <- !is.na(parsed)
    if (any(ok)) {
      result[idx[ok]] <- as.POSIXct(parsed[ok])
      remaining[idx[ok]] <- FALSE
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
#' @export
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
#' @export
excel_date <- function(n) {
  checkmate::assert_numeric(n, min.len = 0)
  as.Date(n, origin = "1899-12-30")
}
