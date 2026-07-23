# Plan 03 - R-3.2 file_meta(path): path, filename, ext, size, hash,
# sheet_names, peek, work_order_guess, revision_guess.

# Regex for a lab work-order token: exactly two uppercase letters followed
# by exactly seven digits (e.g. "ES2600194").
.st_work_order_re <- "[A-Z]{2}\\d{7}"

# Regex for a revision marker immediately following the work-order token:
# an underscore, one or more digits, then an underscore or dot (A12: the
# anchor must be immediate, so "..._COC_1.pdf" does not count).
.st_revision_re <- "^_(\\d+)[_.]"

#' Inspect a file and extract routing metadata
#'
#' Builds the metadata bundle the router and adapters use to decide how (or
#' whether) to handle a file, without parsing its content. Never errors on
#' binary content (R-3.2).
#'
#' @param path path to an existing, readable file.
#' @return a list with elements `path`, `filename`, `ext` (lower-cased, no
#'   leading dot), `size` (bytes), `hash` (xxHash128, via [hash_file()]),
#'   `sheet_names` (via `readxl::excel_sheets()` for xls/xlsx, else `NULL`),
#'   `peek` (first ~2048 bytes, latin-1 decoded, always a character
#'   scalar), `work_order_guess` (first `[A-Z]{2}\d{7}` match in the
#'   filename, else `NA`), `revision_guess` (integer parsed from
#'   `_(\d+)[_.]` immediately after the work order, else `NA`).
#' @keywords internal
#' @noRd
file_meta <- function(path) {
  checkmate::assert_string(path)

  # hash_file() validates existence and aborts (class sampletidy_error) if
  # the file is missing - reused rather than duplicating the check here.
  hash <- hash_file(path)

  filename <- basename(path)
  size <- file.size(path)
  ext <- tolower(tools::file_ext(path))

  sheet_names <- NULL
  if (ext %in% c("xls", "xlsx")) {
    sheet_names <- tryCatch(readxl::excel_sheets(path), error = function(e) NULL)
  }

  peek <- .st_peek_latin1(path)

  wo <- .st_guess_work_order_revision(filename)

  list(
    path = path,
    filename = filename,
    ext = ext,
    size = size,
    hash = hash,
    sheet_names = sheet_names,
    peek = peek,
    work_order_guess = wo$work_order_guess,
    revision_guess = wo$revision_guess
  )
}

# First ~2048 bytes of `path`, decoded latin-1, as a single character
# scalar. Never errors, even on arbitrary binary content: nul bytes (which
# base R character strings cannot embed) are stripped before decoding.
.st_peek_latin1 <- function(path) {
  raw_bytes <- tryCatch(readBin(path, what = "raw", n = 2048L), error = function(e) raw(0))
  raw_bytes <- raw_bytes[raw_bytes != as.raw(0)]
  tryCatch(
    {
      txt <- rawToChar(raw_bytes)
      Encoding(txt) <- "latin1"
      enc2utf8(txt)
    },
    error = function(e) ""
  )
}

# Extract the work-order guess and, anchored immediately after it, the
# revision guess (A12) from a filename.
.st_guess_work_order_revision <- function(filename) {
  wo_match <- regexpr(.st_work_order_re, filename)
  if (identical(as.integer(wo_match), -1L)) {
    return(list(work_order_guess = NA_character_, revision_guess = NA_integer_))
  }

  work_order_guess <- regmatches(filename, wo_match)
  end_pos <- as.integer(wo_match) + attr(wo_match, "match.length")
  rest <- substring(filename, end_pos)

  rev_groups <- regmatches(rest, regexec(.st_revision_re, rest))[[1]]
  revision_guess <- if (length(rev_groups) >= 2) as.integer(rev_groups[[2]]) else NA_integer_

  list(work_order_guess = work_order_guess, revision_guess = revision_guess)
}
