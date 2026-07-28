# Test-suite hygiene lint: a bare on.exit() must never share a test_that()
# block with local_mocked_bindings().
#
# WHY THIS EXISTS. `on.exit()` defaults to `add = FALSE`, which REPLACES every
# handler already registered on the current frame - including the one
# `testthat::local_mocked_bindings()` registered to undo itself. The mock then
# survives into every subsequent test in the file, in the package NAMESPACE
# where the code under test resolves it.
#
# Found the expensive way on 2026-07-28. `test-ingest.R` had two instances
# (a mocked `archive_file()` and a mocked `ingest_file_set_state()`), both of
# which had been leaking silently for as long as they existed. Nothing failed,
# because no later test in the file happened to exercise the mocked path - until
# R-15.36a archived a file named `ES2617126_0_COA.pdf` and inherited the
# injected failure from a test hundreds of lines earlier. The symptom (a
# cross-run retention test failing in the full file but passing in isolation,
# with a correct-looking implementation) points nowhere near the cause.
#
# This is a textual/AST guard on the TEST SUITE, not on the code under test.
# It is worth the maintenance precisely because the failure mode is silent,
# order-dependent, and reads as a bug in whatever unlucky test comes later.

test_that("no test_that() block mixes local_mocked_bindings() with a bare on.exit() - the mock's own cleanup would be discarded", {
  test_files <- sort(list.files(
    testthat::test_path(), pattern = "^test-.*\\.R$", full.names = TRUE
  ))
  expect_true(length(test_files) > 20,
              info = "the scan must actually find the suite, else it passes vacuously")

  offenders <- character(0)

  for (f in test_files) {
    lines <- readLines(f, warn = FALSE)
    pd <- .st_parse_tree(lines, file_label = basename(f))

    blocks <- .st_find_calls(pd, "test_that")
    mocks <- .st_find_calls(pd, c("local_mocked_bindings", "local_mocked_s3_method"))
    exits <- .st_find_calls(pd, "on.exit")
    if (nrow(blocks) == 0 || nrow(mocks) == 0 || nrow(exits) == 0) {
      next
    }

    # Only a BARE on.exit() is a problem: `add = TRUE` composes rather than
    # replaces. Read the argument text off the call's own parse-tree span, so a
    # line-wrapped call is handled and an `add` mentioned in a comment or
    # string elsewhere in the file cannot mask a real offender.
    exit_is_bare <- vapply(seq_len(nrow(exits)), function(i) {
      span <- exits[i, ]
      seg <- lines[span$line1:span$line2]
      if (length(seg) == 1) {
        seg <- substr(seg, span$col1, span$col2)
      } else {
        seg[[1]] <- substr(seg[[1]], span$col1, nchar(seg[[1]]))
        seg[[length(seg)]] <- substr(seg[[length(seg)]], 1, span$col2)
      }
      !grepl("\\badd\\b", paste(seg, collapse = " "))
    }, logical(1))

    for (b in seq_len(nrow(blocks))) {
      blk <- blocks[b, ]
      # Nested test_that() does not occur in this suite, but a block containing
      # another block would double-report rather than miss - the safe direction.
      in_block <- function(spans) {
        .st_span_contains(
          blk$line1, blk$col1, blk$line2, blk$col2,
          spans$line1, spans$col1, spans$line2, spans$col2
        )
      }
      has_mock <- any(in_block(mocks))
      bare_here <- in_block(exits) & exit_is_bare
      if (has_mock && any(bare_here)) {
        offenders <- c(offenders, sprintf(
          "%s:%d (test_that at line %d) - bare on.exit() in a block that mocks bindings; use withr::defer() or on.exit(add = TRUE)",
          basename(f), exits$line1[bare_here][[1]], blk$line1
        ))
      }
    }
  }

  expect_equal(
    offenders, character(0),
    info = paste0(
      "A bare on.exit() wipes local_mocked_bindings()'s restore handler, ",
      "leaking the mock into every later test in the file:\n  ",
      paste(offenders, collapse = "\n  ")
    )
  )
})

test_that("the lint's own detector fires on a known-bad snippet (calibration control)", {
  # Before trusting the negative result above, prove the scan can produce a
  # POSITIVE. Without this, a broken matcher (a renamed helper, a parse-tree
  # shape change) reports a clean suite forever.
  bad <- c(
    'test_that("offender", {',
    '  testthat::local_mocked_bindings(hash_file = function(path) "x")',
    '  con <- 1',
    '  on.exit(rm(con))',
    '  expect_true(TRUE)',
    '})'
  )
  pd <- .st_parse_tree(bad, file_label = "<calibration>")
  blocks <- .st_find_calls(pd, "test_that")
  mocks <- .st_find_calls(pd, "local_mocked_bindings")
  exits <- .st_find_calls(pd, "on.exit")

  expect_equal(nrow(blocks), 1)
  expect_equal(nrow(mocks), 1)
  expect_equal(nrow(exits), 1)
  expect_true(all(.st_span_contains(
    blocks$line1, blocks$col1, blocks$line2, blocks$col2,
    mocks$line1, mocks$col1, mocks$line2, mocks$col2
  )))
  expect_true(all(.st_span_contains(
    blocks$line1, blocks$col1, blocks$line2, blocks$col2,
    exits$line1, exits$col1, exits$line2, exits$col2
  )))

  # And the add = TRUE form must NOT be flagged - the other half of the
  # calibration, since a detector that flags everything is as useless as one
  # that flags nothing.
  good <- sub("on.exit\\(rm\\(con\\)\\)", "on.exit(rm(con), add = TRUE)", bad)
  pd_good <- .st_parse_tree(good, file_label = "<calibration-good>")
  exits_good <- .st_find_calls(pd_good, "on.exit")
  seg <- good[exits_good$line1[[1]]]
  expect_true(grepl("\\badd\\b", seg))
})
