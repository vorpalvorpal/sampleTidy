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

# PLAN-7b round-3 finding 16 (SIG-04): the comment/string stripping here
# routes through the SHARED `.st_strip_source_noise()` helper
# (`tests/testthat/helper-source-scan.R`, built by the alias unit this same
# wave) rather than a second local copy - SIG-04 ("comment/string-blind
# source scanner") had already recurred three times in this codebase, each
# time as a scanner growing its own half-measure. One shared, correct
# implementation, used by every scanner in the suite.

test_that("no R/ file builds a `payload` value with paste0()/paste()/sprintf()/glue() (comment/string-aware; non-vacuous scan)", {
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
    lines <- .st_strip_source_noise(readLines(f, warn = FALSE), file_label = basename(f))
    hit <- grepl("payload\\s*(<-|=)", lines) &
      grepl("paste0\\(|paste\\(|sprintf\\(|glue\\(", lines)
    if (any(hit)) {
      offenders <- c(offenders, sprintf("%s:%d", basename(f), which(hit)))
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

  lines <- .st_strip_source_noise(readLines(tmp, warn = FALSE), file_label = basename(tmp))
  hit <- grepl("payload\\s*(<-|=)", lines) &
    grepl("paste0\\(|paste\\(|sprintf\\(|glue\\(", lines)
  expect_false(any(hit))
})
