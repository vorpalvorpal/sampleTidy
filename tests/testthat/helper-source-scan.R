# Shared test-only infrastructure for source-level lints (Phase-7b round-3
# G-B/SIG-04: "comment/string-blind source scanner" has now recurred THREE
# times independently in this codebase - test-mutate.R's A32 "only write
# door" lint (round-2 item 9, fixed for comments only; round-3 A7 found it
# still string-blind) and test-payload-lint.R (round-3, comment-blind and
# vacuous-pass). One shared, correct implementation, used by every scanner,
# so the class of defect cannot recur a fourth time one file at a time.
#
# Auto-sourced by testthat for the WHOLE suite (the `helper-*.R` convention,
# same as helper-testutils.R) - defines functions only, no top-level calls,
# so it is safe to source before any production R/ code exists.
#
# Coordination note (Phase-7b round-3, U4/alias): built here rather than
# inside test-mutate.R so U2's test-payload-lint.R (a different file, a
# different unit, same wave) can call it too without either file editing the
# other. Reported to the orchestrator per the wave-2 brief's [GENERALIZE]
# routing instruction - do not duplicate this logic in test-payload-lint.R.

#' Strip comments AND string literals from R source, via the real parser
#' (`getParseData()`) rather than a regex - the actual SIG-04 fix, not a
#' half-measure. Every blanked span is replaced with spaces of the SAME
#' WIDTH (never deleted), so any positional information a caller derives
#' afterwards (line numbers, `grepl()` offsets) stays valid.
#'
#' Aborts LOUDLY when `lines` does not parse, rather than silently reverting
#' to returning the raw, unstripped text (Phase-7b round-3 A8: the old
#' per-scanner copy of this idea did exactly that - a file the parser
#' rejected was scanned with comments/strings intact, silently, the precise
#' pre-fix behaviour, with nothing in the test output to say so). A
#' genuinely unparseable `R/` file is a bug in the file (or in this lint's
#' file list) either way, and both deserve a loud failure, not a quiet
#' downgrade.
#'
#' @param lines character vector, one element per source line (as read by
#'   `readLines()`).
#' @param file_label used only in the abort message, to name the file that
#'   failed to parse when a caller is looping over many.
#' @param tokens which parse tokens count as "noise". Defaults to BOTH, which
#'   is what a forbidden-IDENTIFIER scan wants (SIG-04's canonical fix) and
#'   what every existing caller relies on - do not change the default.
#'   Pass `"COMMENT"` alone when the lint's own pattern MATCHES ON a string
#'   literal, because stripping strings would blank the very thing it looks
#'   for. Found the first time this helper was reused: the round-3 radix guard
#'   greps for `method = "radix"`, and the default blanked `"radix"` to spaces,
#'   so the guard reported every correctly-pinned call as a violation.
#' @return character vector, same length as `lines`: the requested tokens
#'   blanked (spaces), everything else byte-identical.
#' @keywords internal
.st_strip_source_noise <- function(lines, file_label = "<source>",
                                   tokens = c("COMMENT", "STR_CONST")) {
  tokens <- match.arg(tokens, c("COMMENT", "STR_CONST"), several.ok = TRUE)
  text <- paste(lines, collapse = "\n")
  pd <- tryCatch(
    utils::getParseData(parse(text = text, keep.source = TRUE)),
    error = function(e) NULL
  )
  if (is.null(pd)) {
    stop(
      ".st_strip_source_noise(): '", file_label, "' could not be parsed by ",
      "parse() - refusing to silently scan it with comments/strings left ",
      "intact (that is exactly the pre-fix SIG-04 behaviour this helper ",
      "exists to prevent). Fix the file's syntax, or exclude it from the ",
      "scan explicitly and say so.",
      call. = FALSE
    )
  }
  if (nrow(pd) == 0) {
    return(lines)
  }
  noise <- pd[pd$token %in% tokens, , drop = FALSE]
  if (nrow(noise) == 0) {
    return(lines)
  }

  out <- lines
  for (i in seq_len(nrow(noise))) {
    r1 <- noise$line1[[i]]
    c1 <- noise$col1[[i]]
    r2 <- noise$line2[[i]]
    c2 <- noise$col2[[i]]
    if (r1 == r2) {
      s <- out[[r1]]
      substr(s, c1, c2) <- strrep(" ", c2 - c1 + 1L)
      out[[r1]] <- s
    } else {
      s1 <- out[[r1]]
      substr(s1, c1, nchar(s1)) <- strrep(" ", nchar(s1) - c1 + 1L)
      out[[r1]] <- s1
      if (r2 > r1 + 1L) {
        for (mid in (r1 + 1L):(r2 - 1L)) {
          out[[mid]] <- strrep(" ", nchar(out[[mid]]))
        }
      }
      s2 <- out[[r2]]
      substr(s2, 1, c2) <- strrep(" ", c2)
      out[[r2]] <- s2
    }
  }
  out
}
