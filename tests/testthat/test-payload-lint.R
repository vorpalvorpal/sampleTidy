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

test_that("no R/ file builds a `payload` value with paste0()/paste()/sprintf()/glue()", {
  files <- list.files(testthat::test_path("..", "..", "R"), pattern = "[.]R$", full.names = TRUE)
  offenders <- character(0)
  for (f in files) {
    lines <- readLines(f, warn = FALSE)
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
