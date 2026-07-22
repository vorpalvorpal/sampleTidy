# Defensive encoding fallback for lab data-file CSV reads.
#
# Root cause (2026-07-22): the `als_xtab` crosstab dialect declared
# `encoding = "latin1"`, but every real XTAB.csv is valid UTF-8 whose degree/
# micro signs were ALREADY destroyed to a single U+FFFD replacement char
# (bytes `ef bf bd`) on disk. Reading that UTF-8 file under a latin-1 locale
# SHATTERS the one U+FFFD into three latin-1 characters (the "shattered
# triple", rendered "i-umlaut + inverted-question + one-half"), which defeats
# both the repair table in `normalise_lab_text()` (it maps a *single* U+FFFD,
# not the triple) and the operator warning - so `Electrical Conductivity @
# 25C` (degree) silently became `unknown_analyte`.
#
# Two-part fix: (1) the crosstab dialect now declares UTF-8 (adapter-crosstab.R);
# (2) this shared helper wires a symmetric latin1<->UTF-8 fallback into every
# data-file CSV read, so a future file whose *default* encoding is wrong is
# rescued automatically rather than corrupted silently.

# Every non-ASCII marker below is written as a \u escape: R CMD check requires
# ASCII-only source, and a helper whose whole job is spotting encoding damage
# is the last place that should depend on how its own bytes are decoded.
.ST_FFFD_SINGLE <- "\ufffd" # U+FFFD replacement character
.ST_FFFD_TRIPLE <- "\u00ef\u00bf\u00bd" # UTF-8 U+FFFD mis-decoded under latin-1
.ST_FFFD_ESCAPE <- "<ef><bf><bd>" # byte-by-byte escape spelling (already ASCII)

# QUALITY PROBE: number of text cells that STILL contain a mojibake marker
# AFTER `normalise_lab_text()` has run (its warnings are suppressed during the
# probe - this is a measurement, not a user-facing repair). A "marker" is any
# of the three spellings above.
#
# Why probe AFTER normalise: `normalise_lab_text()` repairs a lone U+FFFD
# (degree-C, micro-S/cm) but CANNOT repair the shattered triple. So the CORRECT
# read of a pre-destroyed file scores 0 while the WRONG (encoding-mangled) read
# scores > 0 - this asymmetry is exactly what lets the fallback pick the right
# encoding.
.st_mojibake_probe <- function(text) {
  if (is.null(text) || length(text) == 0) {
    return(0L)
  }
  text <- text[!is.na(text)]
  if (length(text) == 0) {
    return(0L)
  }
  normalised <- suppressWarnings(normalise_lab_text(text))
  markers <- grepl(.ST_FFFD_SINGLE, normalised, fixed = TRUE) |
    grepl(.ST_FFFD_TRIPLE, normalised, fixed = TRUE) |
    grepl(.ST_FFFD_ESCAPE, normalised, fixed = TRUE)
  sum(markers, na.rm = TRUE)
}

#' Read a data grid with a defensive encoding fallback
#'
#' Reads with `primary_encoding` first. If a post-`normalise_lab_text()`
#' quality probe finds no residual mojibake markers, the primary read is
#' returned immediately - the alternate encoding is only ever tried when the
#' default read looks damaged. When the probe is positive, the file is re-read
#' with `alternate_encoding`, and the alternate is adopted ONLY when it has the
#' same row count as the primary AND a strictly lower probe score; otherwise
#' the primary read is kept. Swapping in the alternate emits a
#' `cli::cli_inform` note naming the file and both encodings.
#'
#' A clean file scores 0 and is never re-read, so wiring this into an
#' already-correct read path is a strict no-op (zero behaviour change).
#'
#' @param read_fn a closure `function(encoding)` returning the read object
#'   (matrix or data frame) for that encoding. Must accept an encoding string.
#' @param primary_encoding the encoding to try first (the path's declared one).
#' @param alternate_encoding the encoding to fall back to on a positive probe.
#' @param text_extractor `function(obj)` returning a character vector of the
#'   object's text cells (used to compute the mojibake probe and nothing else).
#' @param source_label a short label (e.g. the filename) for the inform note.
#' @return the primary read object, or the alternate when it is strictly
#'   cleaner at the same row count.
#' @keywords internal
#' @noRd
.st_read_grid_with_encoding_fallback <- function(read_fn,
                                                 primary_encoding,
                                                 alternate_encoding,
                                                 text_extractor,
                                                 source_label) {
  primary <- read_fn(primary_encoding)
  probe_primary <- .st_mojibake_probe(text_extractor(primary))

  # Only try the other encoding if the default read looks damaged.
  if (probe_primary == 0L) {
    return(primary)
  }

  alt <- tryCatch(read_fn(alternate_encoding), error = function(e) NULL)
  if (is.null(alt)) {
    return(primary)
  }

  # Same shape, strictly cleaner => it was an encoding issue; use the clean one.
  if (identical(nrow(alt), nrow(primary))) {
    probe_alt <- .st_mojibake_probe(text_extractor(alt))
    if (probe_alt < probe_primary) {
      cli::cli_inform(c(
        "i" = "{.file {source_label}}: re-read as {.val {alternate_encoding}} (was {.val {primary_encoding}}) - resolves {probe_primary - probe_alt} mojibake cell{?s} the default encoding left damaged."
      ))
      return(alt)
    }
  }

  primary
}
