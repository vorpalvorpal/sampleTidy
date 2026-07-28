# Traceability lint: every test name COVERAGE-MAP.md quotes must exist.
#
# WHY THIS EXISTS. `dev/plans/COVERAGE-MAP.md` maps each plan criterion to the
# `test_that()` description that pins it, by quoting that description verbatim.
# The whole document is only useful if those quotes RESOLVE - a criterion whose
# quoted name no longer exists reads as covered while being covered by nothing,
# and a name-anchored criterion sweep silently skips it.
#
# Found the expensive way on 2026-07-28, by a reviewer reading the map rather
# than by anything running. Three entries were stale, and two of them recorded
# behaviour the codebase had since REVERSED:
#
#   * "R-1.1: remove_ingested default is FALSE (A13)" - the default became TRUE
#     on 2026-07-23 and the test was renamed to say so. The map still asserted
#     the superseded default.
#   * "R-8.2: mask alias resolves to the masked feature's uuid" - R-11.4 removed
#     the `feature_mask` join, and the real test now pins the OPPOSITE ("a
#     mask-only name does not resolve").
#   * an AUDIT-1 entry quoting a description that was never the test's name.
#
# A stale quote is worse than a missing entry: it is a false claim of coverage.

# Quoted strings in COVERAGE-MAP that are DATA, not test names - units, example
# filenames, state reasons, env var names. Everything else quoted on a mapping
# line must resolve to a real `test_that()` description.
#
# Kept as an explicit list rather than guessed at with a "looks like a test
# name" heuristic, because the failure direction matters: a heuristic that
# quietly classifies a typo'd test name as "probably a literal" reinstates
# exactly the hole this lint closes. Adding a genuinely new literal here is a
# one-line, deliberate act - which is the point.
.ST_COVMAP_LITERALS <- c(
  "SAMPLETIDY_CORPUS", "busy", "mg/L", "µg/L", "°C", "g/m3",
  "1,320", "05/01/2026", "right", "down", "ES2600194_0_XTAB.csv",
  "empty_file", "unclaimed", "unknown", "date part", "banana/L",
  "Chemical analysis"
)

# Every `test_that()` description in the suite. Read textually on purpose: the
# map quotes the literal source text, so that is what must match.
.st_suite_test_names <- function() {
  files <- list.files(testthat::test_path(), pattern = "^test-.*\\.R$", full.names = TRUE)
  src <- unlist(lapply(files, readLines, warn = FALSE))
  hits <- regmatches(src, regexpr('test_that\\("[^"]*"', src))
  unique(sub('"$', "", sub('^test_that\\("', "", hits)))
}

# Every quoted string on a mapping line (one containing the `→` that separates
# a criterion from the test pinning it).
.st_covmap_quoted <- function(lines) {
  arrow <- lines[grepl("→", lines)]
  q <- unlist(regmatches(arrow, gregexpr('"[^"]*"', arrow)))
  unique(sub('"$', "", sub('^"', "", q)))
}

test_that("every test name quoted in COVERAGE-MAP.md resolves to a real test_that() description", {
  map_path <- testthat::test_path("..", "..", "dev", "plans", "COVERAGE-MAP.md")
  skip_if_not(file.exists(map_path), "COVERAGE-MAP.md not present in this checkout")

  quoted <- .st_covmap_quoted(readLines(map_path, warn = FALSE))
  expect_true(length(quoted) > 100,
              info = "the map must actually be parsed, else this passes vacuously")

  have <- .st_suite_test_names()
  expect_true(length(have) > 500,
              info = "the suite scan must actually find tests, else this passes vacuously")

  unresolved <- setdiff(setdiff(quoted, have), .ST_COVMAP_LITERALS)
  expect_equal(
    unresolved, character(0),
    info = paste0(
      "COVERAGE-MAP.md quotes test names that do not exist. Either the test was ",
      "renamed (update the map) or the criterion is no longer covered (say so). ",
      "If the string is a data literal rather than a test name, add it to ",
      ".ST_COVMAP_LITERALS deliberately:\n  ",
      paste(unresolved, collapse = "\n  ")
    )
  )

  # The allowlist must not rot either: an entry that has become a real test
  # name, or that no longer appears in the map at all, is dead weight that
  # would mask a future typo.
  stale_allow <- setdiff(.ST_COVMAP_LITERALS, quoted)
  expect_equal(
    stale_allow, character(0),
    info = paste0(
      "these .ST_COVMAP_LITERALS entries are no longer quoted in the map; ",
      "remove them so the allowlist cannot mask a future mismatch: ",
      paste(stale_allow, collapse = ", ")
    )
  )
})

test_that("calibration: the traceability check reports a quoted name that does not exist", {
  # Prove the detector can produce a POSITIVE before trusting its negative.
  # The real scan above passes; without this, a broken extractor (a changed
  # arrow glyph, a regex that stops matching) would report a clean map forever.
  fake_map <- c(
    "### R-99.1 something",
    "- a criterion → \"R-99.1: a test that really exists\"",
    "- another criterion → \"R-99.1: a test that does NOT exist\"",
    "- a literal → \"mg/L\""
  )
  quoted <- .st_covmap_quoted(fake_map)
  expect_setequal(
    quoted,
    c("R-99.1: a test that really exists", "R-99.1: a test that does NOT exist", "mg/L")
  )

  have <- c("R-99.1: a test that really exists")
  unresolved <- setdiff(setdiff(quoted, have), .ST_COVMAP_LITERALS)
  expect_identical(unresolved, "R-99.1: a test that does NOT exist")

  # A line with no arrow contributes nothing, so prose merely mentioning a
  # quoted phrase cannot trip the lint.
  expect_length(.st_covmap_quoted('some prose about "a quoted phrase" with no arrow'), 0)
})
