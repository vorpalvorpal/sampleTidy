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
#
# Round-4 recurrence (the SAME class, a fifth time): `.st_strip_source_noise()`
# fixed the INPUT side (comments/strings blanked via the real parser) but
# every lint still matched the blanked TEXT with a hand-rolled regex - so
# each one stayed independently vulnerable to line-wrapping (a `payload <-`
# split from its `paste0(` by a line break) and case (a lowercase `delete`
# inside a SQL string literal, where the old scanner only recognised
# `DELETE`). Half a fix, paid for a fourth and fifth time. The actual
# structure a lint needs - "is this identifier a call target", "what is this
# assignment's right-hand side" - is exactly what `getParseData()` already
# computed and `.st_strip_source_noise()` threw away. `.st_find_calls()` and
# `.st_find_assignments()` below expose that structure directly, so a lint
# says what it means (find calls to F; find the RHS of an assignment to X)
# instead of reverse-engineering it from rendered text - immune by
# construction to wrapping, case, and comments interleaved anywhere the
# parser itself tolerates them.

#' Parse `lines` and return `getParseData()`'s flat token frame, aborting
#' LOUDLY on a parse failure rather than silently falling back to something
#' that would scan unstripped, comment/string-intact text (Phase-7b round-3
#' A8's fix, now the ONE place that decides it - both `.st_strip_source_noise()`
#' and the parse-tree matchers below call this rather than each parsing
#' `lines` their own way).
#' @param lines character vector, one element per source line.
#' @param file_label used only in the abort message.
#' @return the `getParseData()` data.frame (zero rows for e.g. an empty file).
#' @keywords internal
.st_parse_tree <- function(lines, file_label = "<source>") {
  text <- paste(lines, collapse = "\n")
  pd <- tryCatch(
    utils::getParseData(parse(text = text, keep.source = TRUE)),
    error = function(e) NULL
  )
  if (is.null(pd)) {
    stop(
      ".st_parse_tree(): '", file_label, "' could not be parsed by ",
      "parse() - refusing to silently scan it with comments/strings left ",
      "intact (that is exactly the pre-fix SIG-04 behaviour this helper ",
      "exists to prevent). Fix the file's syntax, or exclude it from the ",
      "scan explicitly and say so.",
      call. = FALSE
    )
  }
  pd
}

#' Every span in `inner` (vectors, one element each) that is fully CONTAINED
#' inside the single `outer` span - the primitive both matchers below use to
#' ask "is this call/identifier inside that assignment's right-hand side /
#' inside that other call's arguments". Position order is `(line, col)`
#' pairs compared lexicographically, matching `getParseData()`'s own
#' convention (1-indexed, `col2` inclusive of the span's last character).
#' @keywords internal
.st_span_contains <- function(outer_line1, outer_col1, outer_line2, outer_col2,
                              line1, col1, line2, col2) {
  after_start <- (line1 > outer_line1) | (line1 == outer_line1 & col1 >= outer_col1)
  before_end <- (line2 < outer_line2) | (line2 == outer_line2 & col2 <= outer_col2)
  after_start & before_end
}

.st_empty_calls <- data.frame(
  text = character(0), line1 = integer(0), col1 = integer(0),
  line2 = integer(0), col2 = integer(0), stringsAsFactors = FALSE
)

#' Find every call to one of `fn_names`, by the parse tree's own IDENTITY of
#' "this token is a call's function name" (`SYMBOL_FUNCTION_CALL`) - not a
#' regex over rendered text. Immune by construction to line-wrapping (the
#' call's span is read off the parse tree, not reconstructed from character
#' offsets) and to a comment or string elsewhere in the file merely NAMING
#' the function (a `SYMBOL_FUNCTION_CALL` token is only ever a real call
#' target). Matches the call's bare name only, so `fn(...)` and `pkg::fn(...)`
#' are both found - deliberate: a lint forbidding `dbWriteTable()` should
#' also forbid `DBI::dbWriteTable()`.
#' @param pd a `getParseData()` frame (see `.st_parse_tree()`).
#' @param fn_names character vector of bare function names to find. Matched
#'   case-SENSITIVELY: these are real R identifiers (case matters to R
#'   itself, unlike the SQL keywords a lint's own content check may still
#'   need to compare case-insensitively).
#' @return data.frame, one row per matching call: `text` (the matched name)
#'   and the call's FULLY ENCLOSING span (`line1`/`col1`/`line2`/`col2`, the
#'   function name through the closing `)`, including all arguments) -
#'   suitable as the `outer_*` or `inner` args to `.st_span_contains()`.
#' @keywords internal
.st_find_calls <- function(pd, fn_names) {
  if (nrow(pd) == 0) {
    return(.st_empty_calls)
  }
  fn_tokens <- pd[pd$token == "SYMBOL_FUNCTION_CALL" & pd$text %in% fn_names, , drop = FALSE]
  if (nrow(fn_tokens) == 0) {
    return(.st_empty_calls)
  }
  rows <- lapply(seq_len(nrow(fn_tokens)), function(i) {
    fn <- fn_tokens[i, ]
    # Two levels up: `fn`'s immediate parent is the `expr` wrapping just the
    # call's own name (bare, or `pkg::fn`); THAT node's parent is the `expr`
    # for the whole call, spanning through the matching closing `)` (verified
    # against getParseData() output directly - the grammar is `expr -> expr
    # '(' sublist ')'`, so the call-name expr and the whole-call expr are
    # always exactly one level apart, regardless of nesting or line count).
    ref_expr <- pd[pd$id == fn$parent, , drop = FALSE]
    call_expr <- pd[pd$id == ref_expr$parent[[1]], , drop = FALSE]
    data.frame(
      text = fn$text, line1 = call_expr$line1[[1]], col1 = call_expr$col1[[1]],
      line2 = call_expr$line2[[1]], col2 = call_expr$col2[[1]], stringsAsFactors = FALSE
    )
  })
  do.call(rbind, rows)
}

.st_empty_assignments <- data.frame(
  lhs = character(0), rhs_line1 = integer(0), rhs_col1 = integer(0),
  rhs_line2 = integer(0), rhs_col2 = integer(0), stringsAsFactors = FALSE
)

#' Find every simple assignment statement (`name <- ...` / `name = ...`) in
#' a parsed source tree, and the exact span of its right-hand side - so a
#' lint can ask "does the RHS of the assignment to X contain a call to F"
#' directly off the parse tree, rather than a `name\\s*(<-|=)` text regex
#' that a line-wrapped statement (the name and the operator, or the operator
#' and its value, on different lines) walks straight past.
#'
#' Deliberately does NOT match a call's own named argument (`f(payload =
#' 1)`) - that parses to a different token pair (`SYMBOL_SUB`/`EQ_SUB`), so
#' it is never returned here; only a statement-level `SYMBOL` immediately
#' followed by `LEFT_ASSIGN`/`EQ_ASSIGN` counts.
#' @param pd a `getParseData()` frame (see `.st_parse_tree()`).
#' @return data.frame, one row per assignment: `lhs` (the assigned name's
#'   literal text - callers wanting case-insensitive matching on this, e.g.
#'   because the guarded concept matters more than local naming style,
#'   should compare with `toupper()`/`tolower()` themselves) and the RHS
#'   span (`rhs_line1`/`rhs_col1`/`rhs_line2`/`rhs_col2`).
#' @keywords internal
.st_find_assignments <- function(pd) {
  if (nrow(pd) == 0) {
    return(.st_empty_assignments)
  }
  ops <- pd[pd$token %in% c("LEFT_ASSIGN", "EQ_ASSIGN"), , drop = FALSE]
  if (nrow(ops) == 0) {
    return(.st_empty_assignments)
  }
  term <- pd[pd$terminal, , drop = FALSE]
  term <- term[order(term$line1, term$col1), , drop = FALSE]

  rows <- lapply(seq_len(nrow(ops)), function(i) {
    op <- ops[i, ]
    pos <- which(term$id == op$id)
    if (length(pos) != 1 || pos <= 1) {
      return(NULL)
    }
    prev <- term[pos - 1L, ]
    if (prev$token != "SYMBOL") {
      return(NULL)
    }
    stmt <- pd[pd$id == op$parent, , drop = FALSE]
    if (nrow(stmt) != 1) {
      return(NULL)
    }
    data.frame(
      lhs = prev$text, rhs_line1 = op$line2, rhs_col1 = op$col2,
      rhs_line2 = stmt$line2[[1]], rhs_col2 = stmt$col2[[1]], stringsAsFactors = FALSE
    )
  })
  rows <- rows[!vapply(rows, is.null, logical(1))]
  if (length(rows) == 0) {
    return(.st_empty_assignments)
  }
  do.call(rbind, rows)
}

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
  pd <- .st_parse_tree(lines, file_label = file_label)
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
