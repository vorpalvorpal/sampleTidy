# PLAN-16 residual guard for R-16.6/R-16.7/R-16.8/R-16.18 (RETIRED 2026-07-25, Robin's Ruling 1
# - see PLAN-16.md). This replaces `test-review-queue-hygiene.R` (1,237 lines of AST-scanning
# meta-tests, 8 blocks), deleted in the same ruling for being both evadable (proved by a cold
# audit: a `sprintf`-built SQL string, one variable of indirection, and ~7 of 9 producing idioms
# all walked straight past it) and false-positive-prone (`AND kind LIKE '%feature%'` on the
# `kind` column tripped R-16.6 RED). The escaping PROPERTY those scanners guarded is now covered
# behaviourally by R-16.10's 14 producer-indexed hostile-byte round-trip blocks against real
# writers - this file is the one cheap textual guard left standing on top of that.
#
# What this deliberately does NOT catch, and why that is accepted: indirection through a
# variable (`s <- paste0(...); payload <- s`), non-literal SQL built elsewhere and passed in,
# or a payload string built with positional (unnamed) `paste0()`/`sprintf()` arguments assigned
# to something other than a variable literally named `payload`. Catching those requires an
# AST walk - exactly the 1,237-line scanner that was deleted for being evadable in the ways
# that matter (per-site routing, cross-file `paste0()` concatenation) while still throwing false
# positives on unrelated code. A plain textual grep for `payload <- ...paste0(...)` etc. cannot
# be evaded by mistake (nobody writes `payload <- paste0(...)` accidentally) and needs no
# maintenance when refactors change unrelated call sites.

# PLAN-7b round-3 finding 16 (SIG-04) / Phase-8b F7: the scan below matches
# on the PARSE TREE (`.st_find_assignments()` / `.st_find_calls()` /
# `.st_span_contains()`, `tests/testthat/helper-source-scan.R`), not a regex
# over rendered text. SIG-04 ("comment/string-blind source scanner") had
# already recurred three times in this codebase as a text scanner growing
# its own half-measure comment/string strip; round-4 found a FOURTH
# recurrence one level up - even the shared, correct strip
# (`.st_strip_source_noise()`) still fed a `payload\\s*(<-|=)` /
# `paste0\\(|...` regex pair applied per LINE, so the exact violation this
# lint exists to catch (`payload <-` and its `paste0(` call on different
# lines - e.g. a styler-wrapped long assignment) walked straight past it.
# Matching the parse tree's own "this is an assignment to X" / "this is a
# call to F" structure is immune to that by construction: wrapping,
# comments, and case are all just source-text details the parser already
# resolved before this scan ever sees it.

#' TRUE if `lines` assigns a `payload`-named variable (any case - the
#' concept this guards is "a payload value", not one specific spelling of
#' the variable name) a value built by `paste0()`/`paste()`/`sprintf()`/
#' `glue()`, anywhere in that assignment's right-hand side.
#' @keywords internal
.pl_scan_payload_violation <- function(lines, file_label = "<source>") {
  pd <- .st_parse_tree(lines, file_label = file_label)
  assigns <- .st_find_assignments(pd)
  payload_assigns <- assigns[toupper(assigns$lhs) == "PAYLOAD", , drop = FALSE]
  if (nrow(payload_assigns) == 0) {
    return(integer(0))
  }
  calls <- .st_find_calls(pd, c("paste0", "paste", "sprintf", "glue"))
  if (nrow(calls) == 0) {
    return(integer(0))
  }
  hit_lines <- integer(0)
  for (i in seq_len(nrow(payload_assigns))) {
    a <- payload_assigns[i, ]
    hit <- .st_span_contains(
      a$rhs_line1, a$rhs_col1, a$rhs_line2, a$rhs_col2,
      calls$line1, calls$col1, calls$line2, calls$col2
    )
    if (any(hit)) {
      hit_lines <- c(hit_lines, a$rhs_line1)
    }
  }
  hit_lines
}

test_that("no R/ file builds a `payload` value with paste0()/paste()/sprintf()/glue() (parse-tree scan; non-vacuous)", {
  files <- list.files(testthat::test_path("..", "..", "R"), pattern = "[.]R$", full.names = TRUE)
  # PLAN-7b round-3 finding 15: `list.files()` on a missing/relocated
  # directory silently returns `character(0)`, and the loop below then
  # passes having read nothing - e.g. under `R CMD check`, where the tests
  # run from `<pkg>.Rcheck/tests/testthat` and `../../R` resolves to
  # `<pkg>.Rcheck/R`, not the installed package's own `R/`. Assert the scan
  # actually found real source files before trusting a clean result.
  expect_gt(length(files), 0)

  offenders <- character(0)
  for (f in files) {
    hits <- .pl_scan_payload_violation(readLines(f, warn = FALSE), file_label = basename(f))
    if (length(hits) > 0) {
      offenders <- c(offenders, sprintf("%s:%d", basename(f), hits))
    }
  }
  expect_identical(
    offenders, character(0),
    info = paste0(
      "payload built by string concatenation at: ", paste(offenders, collapse = ", ")
    )
  )
})

test_that("PLAN-7b round-3 finding 16 (SIG-04 decoy): a COMMENT or a string literal naming both `payload <-` and `paste0(` does NOT trip the scan", {
  tmp <- withr::local_tempfile(fileext = ".R")
  writeLines(c(
    "# decoy: payload <- paste0('this comment must not trip the lint')",
    "x <- 1  # another decoy: payload <- sprintf('nope')",
    "msg <- \"decoy in a string: payload <- paste0(nested)\"",
    "real_var <- 2"
  ), tmp)

  expect_length(.pl_scan_payload_violation(readLines(tmp, warn = FALSE), file_label = basename(tmp)), 0)
})

# ---- Phase-8b F7 self-tests: caught in every awkward form -------------------

test_that("Phase-8b F7: a one-line `payload <- paste0(...)` violation is caught", {
  decoy <- c(
    "f <- function(x) {",
    "  payload <- paste0(\"{\\\"k\\\":\\\"\", x, \"\\\"}\")",
    "  payload",
    "}"
  )
  expect_length(.pl_scan_payload_violation(decoy), 1)
})

test_that("Phase-8b F7: the same violation, line-wrapped across `<-` and `paste0(`, is caught (the exact evasion that walked past the old per-line regex)", {
  decoy <- c(
    "f <- function(x) {",
    "  payload <-",
    "    paste0(\"{\\\"k\\\":\\\"\", x, \"\\\"}\")",
    "  payload",
    "}"
  )
  expect_length(.pl_scan_payload_violation(decoy), 1)
})

test_that("Phase-8b F7: the same violation with the assigned name in the opposite case (`Payload`/`PAYLOAD`) is caught", {
  decoy <- c(
    "f <- function(x) {",
    "  PAYLOAD <- paste0(\"{\\\"k\\\":\\\"\", x, \"\\\"}\")",
    "  PAYLOAD",
    "}"
  )
  expect_length(.pl_scan_payload_violation(decoy), 1)
})

test_that("Phase-8b F7: the same violation with a comment interleaved between the assignment operator and the call is caught", {
  decoy <- c(
    "f <- function(x) {",
    "  payload <-  # build the response body",
    "    paste0(\"{\\\"k\\\":\\\"\", x, \"\\\"}\")",
    "  payload",
    "}"
  )
  expect_length(.pl_scan_payload_violation(decoy), 1)
})
