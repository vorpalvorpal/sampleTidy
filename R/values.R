#' Parse raw lab-report value strings into numeric/quantified/RL columns
#'
#' Vectorised successor to the old `cleanBDLvalues()`. Handles below/above
#' reporting-limit notation (`<0.01`, `>2000`), the `BDL` marker, thousands
#' separators, and two distinct "not a real reading" cases that must be
#' recorded as skips with a reason rather than silently dropped (CONTRACT
#' A4): `"NS"` ("no sample") and strings of dashes only (e.g. `"----"`,
#' meaning "not computable"). Anything else that isn't numeric is kept
#' verbatim as free text in `value_chr` (e.g. field notes like
#' `"Clear, low flow"`) and marked `quantified = TRUE` (a valid, recorded
#' observation - just not a numeric one).
#'
#' @param value_raw character vector of raw value strings as they appear in
#'   the source file.
#' @return a [tibble::tibble()] with one row per element of `value_raw` and
#'   columns:
#'   - `value_num` (dbl): the parsed numeric value (equal to `rl_low`/
#'     `rl_high` for below/above-detection rows).
#'   - `value_chr` (chr): non-numeric free text, `NA` otherwise.
#'   - `quantified` (lgl): `TRUE` for a genuine numeric or free-text reading,
#'     `FALSE` for a below/above-detection or `BDL` reading, `NA` for a
#'     skipped row.
#'   - `rl_low` (dbl): the reporting limit for `<`-notation rows.
#'   - `rl_high` (dbl): the reporting limit for `>`-notation rows.
#'   - `skip_reason` (chr): `NA` unless the row was skipped
#'     (`"empty"`, `"no_sample"`, `"not_computable"`).
#' @keywords internal
#' @noRd
parse_value <- function(value_raw) {
  checkmate::assert_character(value_raw, min.len = 0)
  n <- length(value_raw)

  trimmed <- trimws(value_raw)

  is_empty <- is.na(value_raw) | trimmed == ""
  is_ns <- !is_empty & trimmed == "NS"
  is_dash <- !is_empty & !is_ns & grepl("^-+$", trimmed)
  is_below <- !is_empty & !is_ns & !is_dash & grepl("^<", trimmed)
  is_above <- !is_empty & !is_ns & !is_dash & !is_below & grepl("^>", trimmed)
  is_bdl_word <- !is_empty & !is_ns & !is_dash & !is_below & !is_above &
    grepl("^BDL$", trimmed)

  strip_marker <- function(s) {
    s <- sub("^[<>]", "", s)
    s <- gsub(",", "", s)
    trimws(s)
  }
  marker_val <- suppressWarnings(as.numeric(strip_marker(trimmed)))

  numeric_candidate <- suppressWarnings(as.numeric(gsub(",", "", trimmed)))
  is_plain_numeric <- !is_empty & !is_ns & !is_dash & !is_below & !is_above &
    !is_bdl_word & !is.na(numeric_candidate)
  is_text <- !is_empty & !is_ns & !is_dash & !is_below & !is_above &
    !is_bdl_word & !is_plain_numeric

  value_num <- rep(NA_real_, n)
  value_num[is_below] <- marker_val[is_below]
  value_num[is_above] <- marker_val[is_above]
  value_num[is_plain_numeric] <- numeric_candidate[is_plain_numeric]

  quantified <- rep(NA, n)
  quantified[is_below | is_above | is_bdl_word] <- FALSE
  quantified[is_plain_numeric | is_text] <- TRUE

  rl_low <- rep(NA_real_, n)
  rl_low[is_below] <- marker_val[is_below]

  rl_high <- rep(NA_real_, n)
  rl_high[is_above] <- marker_val[is_above]

  value_chr <- rep(NA_character_, n)
  value_chr[is_text] <- trimmed[is_text]

  skip_reason <- rep(NA_character_, n)
  skip_reason[is_empty] <- "empty"
  skip_reason[is_ns] <- "no_sample"
  skip_reason[is_dash] <- "not_computable"

  tibble::tibble(
    value_num = value_num,
    value_chr = value_chr,
    quantified = quantified,
    rl_low = rl_low,
    rl_high = rl_high,
    skip_reason = skip_reason
  )
}
