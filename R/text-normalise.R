# Substitution tables for normalise_lab_text() ------------------------------
#
# Two layers, both shipped (CONTRACT A25):
#
#  1. `.lab_text_mojibake_fixes` - ported **verbatim** from
#     `WEM.data/R/new/data/normalise_lab_text.R`. Keys are the literal
#     `<XX>` hex-escape strings that show up when a UTF-8 byte sequence gets
#     printed byte-by-byte (e.g. a tool renders the raw bytes of a degree
#     sign as the four characters `<c2><b0>` instead of decoding them).
#
#  2. `.lab_text_real_char_fixes` - new entries pinned by PLAN-02 for the
#     *real* (already-decoded) mis-mapped characters real files carry: the
#     MacRoman/latin-1 degree byte (0xA1, which decodes as U+00A1, an
#     inverted exclamation mark, when misread as latin-1) and the classic
#     cp1252 pairs from the old `unify_value()` unit_dictionary, where a lost
#     multibyte sequence collapses to a single U+FFFD replacement character.
#
# Substitutions are applied with `fixed = TRUE` (literal string matching, no
# regex metacharacters).
#
# Every non-ASCII character here is written as a `\uxxxx` escape, not as a
# literal: R CMD check requires ASCII-only source ("checking code files for
# non-ASCII characters"), and a table whose whole job is repairing encoding
# damage is the last place that should itself depend on how a file's bytes
# are decoded. The escapes are identical in value to the literals -
# test-text-normalise.R pins the behaviour.

.lab_text_mojibake_fixes <- c(
  "<c2><b0>"     = "\u00b0", # degree sign       U+00B0
  "<c2><b1>"     = "\u00b1", # plus-minus        U+00B1
  "<c2><b2>"     = "\u00b2", # superscript two   U+00B2
  "<c2><b5>"     = "\u00b5", # micro sign        U+00B5
  "<c2><a1>"     = "\u00b0", # alt mojibake of degree (source byte 0xB0 lost via cp1252 -> utf8 misroute)
  "<e2><80><94>" = "\u2014", # em dash           U+2014
  "<e2><81><bb>" = "\u207b"  # superscript minus U+207B
)

.lab_text_real_char_fixes <- c(
  # U+00A1 = MacRoman degree byte (0xA1) read as latin-1 -> degree sign
  "\u00a1"       = "\u00b0",
  # U+FFFD = a micro/degree sign lost in a cp1252 misroute
  "\ufffdS/cm"   = "\u00b5S/cm",
  "\ufffdg/L"    = "\u00b5g/L",
  "\ufffdC"      = "\u00b0C"
)

#' Normalise mojibaked text from lab data files
#'
#' Lab CSV/XLSX files frequently arrive with non-UTF8 encodings (cp1252,
#' latin-1, or worse) that produce visible mojibake: either literal
#' ASCII-escape strings like `<c2><b0>C` (where a degree-C was intended), or
#' already-decoded-but-wrong characters (e.g. a MacRoman degree byte misread
#' as latin-1, or a lost multibyte sequence collapsed to the Unicode
#' replacement character U+FFFD).
#'
#' Run incoming lab text through this function before matching against
#' analyte/method names or unit strings. The substitution tables
#' (`.lab_text_mojibake_fixes`, `.lab_text_real_char_fixes`) are the
#' authoritative list of seen-in-the-wild patterns and their intended
#' characters.
#'
#' Any U+FFFD left over after substitution indicates irrecoverable byte
#' loss - the source byte cannot be deduced, so no blind substitution is
#' attempted. Instead a warning (class `sampletidy_warning`) is raised so the
#' operator can review the source file, and the text is returned unchanged.
#'
#' @param x character vector - text from a lab data file.
#' @return same shape as `x`, with known mojibake substituted to proper
#'   UTF-8. `NULL` and zero-length input are returned as-is. `NA` elements
#'   stay `NA`.
#' @keywords internal
#' @noRd
normalise_lab_text <- function(x) {
  if (is.null(x) || length(x) == 0) {
    return(x)
  }

  out <- x
  fixes <- c(.lab_text_mojibake_fixes, .lab_text_real_char_fixes)
  for (pattern in names(fixes)) {
    out <- gsub(pattern, fixes[[pattern]], out, fixed = TRUE)
  }

  # Flag irrecoverable bytes - these need a human eye, not a blind
  # substitution. Leftover U+FFFD (or its 3-byte UTF-8 mojibake spelling)
  # means the original byte cannot be reconstructed from the table above.
  fffd_hit <- grepl("<ef><bf><bd>", out, fixed = TRUE) |
    grepl("\ufffd", out, fixed = TRUE)
  if (any(fffd_hit, na.rm = TRUE)) {
    affected <- unique(out[which(fffd_hit)])
    cli::cli_warn(
      c(
        "{.fn normalise_lab_text}: input contains the Unicode replacement character (U+FFFD); the original byte is irrecoverable.",
        "i" = "Review the source file. Affected entries: {paste(affected, collapse = ' | ')}"
      ),
      class = "sampletidy_warning"
    )
  }

  out
}
