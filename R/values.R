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
#' A `<`/`>` marker whose remaining text does not parse to a plain finite
#' number (an embedded unit like `<0.01 mg/L`, a bare `<`/`>` with nothing
#' after it) is NOT guessed at: the row's whole numeric content is refused
#' and `parse_error` is set, rather than committing a below/above-detection
#' row with a fabricated or missing reporting limit. Likewise, a comma whose
#' reading is genuinely ambiguous between the thousands-grouping convention
#' (`"1,234"`) and a European decimal comma (`"1,5"`) is refused rather than
#' guessed - see `parse_error` below for exactly which shapes count as
#' ambiguous. Both are governed by the same principle as CONTRACT A4's
#' skips: anything the parser cannot confidently resolve is surfaced, not
#' silently committed as its best guess.
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
#'     skipped or unparseable/ambiguous row.
#'   - `rl_low` (dbl): the reporting limit for `<`-notation rows.
#'   - `rl_high` (dbl): the reporting limit for `>`-notation rows.
#'   - `skip_reason` (chr): `NA` unless the row was skipped
#'     (`"empty"`, `"no_sample"`, `"not_computable"`).
#'   - `parse_error` (chr): `NA` unless the row's numeric content could not
#'     be confidently resolved (`"unparseable_limit_value"` for a `<`/`>`
#'     marker whose remaining text is not a plain finite number;
#'     `"ambiguous_number_format"` for a comma that could be either a
#'     thousands separator or a decimal point). These rows carry `NA` in
#'     every other column - the caller is expected to route them to
#'     `review_queue`, the same way it already does for unit-conversion and
#'     datetime parse failures, rather than commit or silently drop them.
#' @keywords internal
#' @noRd
parse_value <- function(value_raw) {
  checkmate::assert_character(value_raw, min.len = 0)
  n <- length(value_raw)

  # Two typographic look-alikes real sources emit that have exactly ONE sane
  # reading - unlike the comma case below, these are not ambiguous, so
  # normalising them is not a guess. NBSP (U+00A0) is whitespace wherever it
  # appears (PDF-to-CSV / copy-paste tooling emits it around numbers, and
  # base `trimws()` does not strip it). U+2212 MINUS SIGN is what word
  # processors substitute for a plain hyphen in front of a negative number.
  normalised <- gsub(" ", " ", value_raw, fixed = TRUE)
  normalised <- gsub("−", "-", normalised, fixed = TRUE)

  trimmed <- trimws(normalised)

  is_empty <- is.na(value_raw) | trimmed == ""
  is_ns <- !is_empty & trimmed == "NS"
  is_dash <- !is_empty & !is_ns & grepl("^-+$", trimmed)
  is_below <- !is_empty & !is_ns & !is_dash & grepl("^<", trimmed)
  is_above <- !is_empty & !is_ns & !is_dash & !is_below & grepl("^>", trimmed)
  is_bdl_word <- !is_empty & !is_ns & !is_dash & !is_below & !is_above &
    grepl("^BDL$", trimmed)

  # The string actually handed to the numeric parser: the marker-stripped
  # body for below/above rows, the trimmed string itself for everything
  # else. Whitespace left behind by stripping "<"/">" (e.g. "<  0.01") is
  # trimmed again here so it parses the same as "<0.01".
  numeric_input <- trimmed
  is_marker <- is_below | is_above
  numeric_input[is_marker] <- trimws(sub("^[<>]", "", trimmed[is_marker]))

  # A comma-and-digits string is unambiguous ONLY when every group after the
  # first is exactly 3 digits - the one grouping convention that cannot also
  # be a decimal separator ("1,234", "1,234,567"). "1,5"/"0,5" (too few
  # digits to be a group), "2,5,7" and "1,23,456" (non-3-digit groups) are
  # refused rather than guessed at: they could be a European decimal comma,
  # could be a different grouping convention entirely, and guessing wrong is
  # a silent order-of-magnitude error either way. Restricted to strings that
  # are otherwise nothing but digits/sign/commas/decimal-point, so a
  # legitimate comma-bearing free-text note (e.g. "Clear, low flow") is
  # never mistaken for an ambiguous number.
  comma_numeric_like <- grepl("^[+-]?[0-9]{1,3}(,[0-9]{1,3})+(\\.[0-9]+)?$", numeric_input)
  comma_unambiguous <- grepl("^[+-]?[0-9]{1,3}(,[0-9]{3})+(\\.[0-9]+)?$", numeric_input)

  # Only rows that could plausibly be numeric at all are eligible for either
  # the ambiguous-comma refusal or the numeric fast path; "NS"/dash/"BDL"
  # rows are already fully classified above and never reach here.
  maybe_numeric <- !is_empty & !is_ns & !is_dash & !is_bdl_word

  comma_ambiguous <- maybe_numeric & comma_numeric_like & !comma_unambiguous

  # `as.numeric()` silently parses hex literals ("0x10" -> 16); no lab
  # reading is ever written in hex, so this is blocked from the numeric fast
  # path rather than trusted like a normal decimal string. It is NOT treated
  # as a `parse_error` (that state is reserved for cases the caller must
  # route to a human): a bare "0x10" with no `<`/`>` marker falls through to
  # the ordinary free-text bucket, exactly like any other non-numeric
  # string, rather than being committed as the number 16.
  is_hex_like <- maybe_numeric & grepl("^[+-]?0[xX][0-9a-fA-F]+$", numeric_input)

  numeric_clean <- numeric_input
  numeric_clean[comma_ambiguous | is_hex_like] <- NA_character_
  strip_idx <- maybe_numeric & !comma_ambiguous & !is_hex_like
  numeric_clean[strip_idx] <- gsub(",", "", numeric_clean[strip_idx], fixed = TRUE)

  numeric_val <- suppressWarnings(as.numeric(numeric_clean))
  # `as.numeric("Inf")`/`as.numeric("-Inf")` succeed; no lab reading is ever
  # infinite, so - like hex above - this is blocked from the fast path and
  # (for a plain value) falls through to free text rather than being
  # committed as Inf. `as.numeric("NaN")` already returns a value `is.na()`
  # treats as TRUE, so it needs no special handling here.
  numeric_val[is.infinite(numeric_val)] <- NA_real_

  # A `<`/`>` marker whose body did not yield a finite, unambiguous number
  # (embedded unit, hex, infinite, bare marker with nothing after it) is
  # refused, never committed as a below/above-detection row with a
  # fabricated or missing reporting limit.
  marker_unparseable <- is_marker & is.na(numeric_val) & !comma_ambiguous
  is_below_valid <- is_below & !is.na(numeric_val)
  is_above_valid <- is_above & !is.na(numeric_val)

  is_plain_numeric <- maybe_numeric & !is_below & !is_above & !is.na(numeric_val)

  parse_error <- rep(NA_character_, n)
  parse_error[comma_ambiguous] <- "ambiguous_number_format"
  parse_error[marker_unparseable] <- "unparseable_limit_value"

  is_text <- maybe_numeric & !is_below & !is_above & !is_plain_numeric & is.na(parse_error)

  value_num <- rep(NA_real_, n)
  value_num[is_below_valid] <- numeric_val[is_below_valid]
  value_num[is_above_valid] <- numeric_val[is_above_valid]
  value_num[is_plain_numeric] <- numeric_val[is_plain_numeric]

  quantified <- rep(NA, n)
  quantified[is_below_valid | is_above_valid | is_bdl_word] <- FALSE
  # Text results stay NA. `quantified` is a statement about a MEASUREMENT -
  # whether the analyte was detected above the reporting limit - and a
  # qualitative observation ("Cloudy", "Dry", "Could not find due to long
  # grass") is not a measurement at all, so neither TRUE nor FALSE is true of
  # it. TRUE would be the worse error: 23 of the 315 such rows in the live
  # registry record that NO SAMPLE WAS TAKEN, and marking those quantified
  # asserts an observation that never happened. Ruled by Robin 2026-07-23.
  # The invariant this establishes: quantified IS NULL <=> value_chr IS NOT NULL.
  quantified[is_plain_numeric] <- TRUE
  # parse_error rows also stay NA: an unparseable/ambiguous input is not a
  # resolved measurement of any kind until a human looks at it.

  rl_low <- rep(NA_real_, n)
  rl_low[is_below_valid] <- numeric_val[is_below_valid]

  rl_high <- rep(NA_real_, n)
  rl_high[is_above_valid] <- numeric_val[is_above_valid]

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
    skip_reason = skip_reason,
    parse_error = parse_error
  )
}
