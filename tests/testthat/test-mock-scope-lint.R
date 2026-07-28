# Test-suite hygiene lint: a REPLACING on.exit() must never share a frame with
# something that registered its own cleanup on that same frame.
#
# WHY THIS EXISTS. `on.exit()` defaults to `add = FALSE`, which REPLACES every
# handler already registered on the current frame. Two different things register
# handlers there and are silently discarded by it:
#
#   1. `testthat::local_mocked_bindings()`, whose restore handler undoes the
#      mock. Discard it and the mock survives into every subsequent test in the
#      file, in the package NAMESPACE where the code under test resolves it.
#   2. `withr::local_*(..., .local_envir = parent.frame())`, the way a shared
#      setup helper binds ITS cleanups to the calling test's frame. Discard
#      those and the test leaks global options and temp directories.
#
# Found the expensive way on 2026-07-28, both classes, one after the other.
# Class 1: `test-ingest.R` had two instances (a mocked `archive_file()` and a
# mocked `ingest_file_set_state()`), leaking silently for as long as they had
# existed. Nothing failed, because no later test happened to exercise the mocked
# path - until R-15.36a archived a file named `ES2617126_0_COA.pdf` and
# inherited an injected failure from a test hundreds of lines earlier. The
# symptom (a test failing in the full file but passing in isolation, with a
# correct-looking implementation) points nowhere near the cause.
#
# Class 2 was found by AUDITING this lint rather than by running it: eleven
# `test_that()` blocks called `ingest_test_setup()` - which registers its
# `withr` cleanups on `parent.frame()`, i.e. the test's own frame - and then
# wiped them with a bare `on.exit(DBI::dbDisconnect(...))`. Measured before the
# fix: 3 `sampletidy.*` options left set GLOBALLY and 47 temp directories
# surviving one run of the file. The class-1 rule could never have seen it,
# because no mock is involved.
#
# The first version of this lint ALSO shipped two holes of its own, both worth
# recording because they are the generic ways a source lint rots:
#
#   * it decided bareness with `!grepl("\\badd\\b", <call text>)`, so
#     `on.exit(..., add = FALSE)` - semantically IDENTICAL to a bare call -
#     read as safe, and `on.exit(rm(add))` read as safe too. The `add` argument
#     is now resolved through `match.call()` against `on.exit`'s real formals,
#     so only a literal `TRUE` (named or positional) counts as composing.
#   * its "calibration control" re-exercised only `.st_find_calls()` and
#     `.st_span_contains()` and never ran the bareness check at all - which is
#     precisely how the hole above survived being written. The calibration below
#     drives the real detector functions over a battery of inputs.
#
# This is a textual/AST guard on the TEST SUITE, not on the code under test. It
# is worth the maintenance precisely because both failure modes are silent,
# order-dependent, and read as a bug in whatever unlucky test comes later.

# TRUE when this `on.exit()` call REPLACES the frame's existing handlers, i.e.
# it does not pass a literal `add = TRUE`. Resolved semantically against
# `on.exit`'s real formals rather than by pattern-matching the text, so the
# positional form `on.exit(expr, TRUE)` is recognised as safe and
# `on.exit(rm(add))` is not mistaken for it.
#
# Deliberately conservative: an `add` whose value is a variable rather than a
# literal cannot be proven safe by reading the source, so it is reported.
# Unparseable text is reported for the same reason - silence would be the one
# outcome this file exists to prevent.
.st_on_exit_replaces <- function(call_text) {
  expr <- tryCatch(str2lang(call_text), error = function(e) NULL)
  if (is.null(expr) || !is.call(expr)) {
    return(TRUE)
  }
  matched <- tryCatch(match.call(args(on.exit), expr), error = function(e) NULL)
  if (is.null(matched)) {
    return(TRUE)
  }
  add <- as.list(matched)[["add"]]
  if (is.null(add)) {
    return(TRUE)
  }
  !isTRUE(add)
}

# The names of every function in `lines` that registers cleanups on its
# CALLER's frame - the `withr::local_*(..., .local_envir = <caller env>)`
# idiom. Found structurally rather than from a hand-maintained list of helper
# names, so a new setup helper is covered the day it is written.
.st_frame_borrowing_helpers <- function(pd, lines) {
  defs <- .st_find_function_defs(pd)
  if (nrow(defs) == 0) {
    return(character(0))
  }
  assigns <- .st_find_assignments(pd)
  out <- character(0)
  for (i in seq_len(nrow(defs))) {
    # Both halves are required: `.local_envir` is what redirects the handler,
    # and `parent.frame()` is what makes the target the CALLER's frame.
    #
    # Matched STRUCTURALLY - a real `.local_envir` argument token and a real
    # call to `parent.frame` - rather than by grepping the definition's text.
    # Text matching made this function report ITSELF, because the names appear
    # in its own string literals; that is SIG-04, the comment/string-blind
    # scanner, for the sixth time in this codebase, and in the very helper
    # written to catch a hygiene defect.
    in_def <- function(spans) {
      .st_span_contains(
        defs$line1[[i]], defs$col1[[i]], defs$line2[[i]], defs$col2[[i]],
        spans$line1, spans$col1, spans$line2, spans$col2
      )
    }
    envir_args <- pd[pd$token == "SYMBOL_SUB" & pd$text == ".local_envir", , drop = FALSE]
    if (nrow(envir_args) == 0 || !any(in_def(envir_args))) {
      next
    }
    pf_calls <- .st_find_calls(pd, "parent.frame")
    if (nrow(pf_calls) == 0 || !any(in_def(pf_calls))) {
      next
    }
    # Which name is this definition assigned to? The one whose RHS span
    # CONTAINS the function-definition span - the assignment is the outer term
    # and the definition the inner one, not the other way round. Getting that
    # backwards matched `env <- parent.frame()` (an assignment INSIDE the
    # helper) instead of the helper itself; the calibration below is what
    # caught it.
    if (nrow(assigns) == 0) {
      next
    }
    contains <- vapply(seq_len(nrow(assigns)), function(a) {
      .st_span_contains(
        assigns$rhs_line1[[a]], assigns$rhs_col1[[a]],
        assigns$rhs_line2[[a]], assigns$rhs_col2[[a]],
        defs$line1[[i]], defs$col1[[i]], defs$line2[[i]], defs$col2[[i]]
      )
    }, logical(1))
    owner <- which(contains)
    if (length(owner) == 0) {
      next
    }
    # A function defined inside another assigned function is contained by both;
    # the SMALLEST containing RHS is its own.
    extent <- (assigns$rhs_line2[owner] - assigns$rhs_line1[owner]) * 1e6 +
      (assigns$rhs_col2[owner] - assigns$rhs_col1[owner])
    out <- c(out, assigns$lhs[[owner[[which.min(extent)]]]])
  }
  unique(out)
}

# Both rules scan test files AND helper files: a helper file has no enclosing
# `test_that()` block, which is exactly why the first version of this lint -
# scoped to test files and to block containment - could not see into one.
.st_lint_source_files <- function() {
  sort(c(
    list.files(testthat::test_path(), pattern = "^test-.*\\.R$", full.names = TRUE),
    list.files(testthat::test_path(), pattern = "^helper-.*\\.R$", full.names = TRUE)
  ))
}

# Every replacing-on.exit in one file, tagged with the innermost frame it
# registers against. Shared by both rules and by the calibration, so the
# calibration exercises the SAME code path the suite scan uses.
.st_scan_exit_frames <- function(lines, file_label) {
  pd <- .st_parse_tree(lines, file_label = file_label)
  exits <- .st_find_calls(pd, "on.exit")
  # A frame is created by a function body, by `local()`, and by the `code`
  # argument of `test_that()`. Attributing a handler to the INNERMOST of these
  # is what distinguishes a helper function's own `on.exit()` from one written
  # directly in the block around it.
  scopes <- rbind(
    .st_find_calls(pd, c("test_that", "local")),
    .st_find_function_defs(pd)
  )
  list(pd = pd, exits = exits, scopes = scopes,
       exit_scope = .st_innermost_scope(scopes, exits),
       replaces = vapply(seq_len(nrow(exits)), function(i) {
         .st_on_exit_replaces(.st_span_text(
           lines, exits$line1[[i]], exits$col1[[i]], exits$line2[[i]], exits$col2[[i]]
         ))
       }, logical(1)))
}

test_that("no on.exit() discards a local_mocked_bindings() restore handler registered on the same frame", {
  files <- .st_lint_source_files()
  expect_true(length(files) > 20,
              info = "the scan must actually find the suite, else it passes vacuously")

  offenders <- character(0)
  for (f in files) {
    lines <- readLines(f, warn = FALSE)
    s <- .st_scan_exit_frames(lines, basename(f))
    if (nrow(s$exits) == 0) next
    mocks <- .st_find_calls(s$pd, c("local_mocked_bindings", "local_mocked_s3_method"))
    if (nrow(mocks) == 0) next
    mock_scope <- .st_innermost_scope(s$scopes, mocks)

    for (i in seq_len(nrow(s$exits))) {
      if (!s$replaces[[i]]) next
      si <- s$exit_scope[[i]]
      if (is.na(si) || !(si %in% mock_scope[!is.na(mock_scope)])) next
      offenders <- c(offenders, sprintf(
        "%s:%d - on.exit() without add = TRUE shares a frame with a mocked binding; use withr::defer()",
        basename(f), s$exits$line1[[i]]
      ))
    }
  }

  expect_equal(
    offenders, character(0),
    info = paste0(
      "An on.exit() without add = TRUE wipes local_mocked_bindings()'s restore ",
      "handler, leaking the mock into every later test in the file:\n  ",
      paste(offenders, collapse = "\n  ")
    )
  )
})

# The rule-2 ratchet. EMPTY, and that is the finished state: every file must
# have zero offenders. Any entry added here is a regression being tolerated, so
# add one only with a reason and a plan to remove it.
#
# History, because an empty list looks like a rule that never found anything.
# When this rule was written on 2026-07-28 it found **411 sites across 15
# files**: the eleven in `test-ingest.R` that motivated it, plus a backlog of
# 400 across 14 more. The backlog was recorded here rather than swept
# immediately, because converting it changes real behaviour - the leaked
# options and temp dirs start actually being cleaned up, and any test that had
# silently come to depend on the leak would begin failing. Swept in tiers on
# 2026-07-29, smallest file first, running each tier before starting the next.
# No fallout materialised in any of the 15 files.
#
# Measured on `test-ingest.R` before its fix: 3 `sampletidy.*` options left set
# GLOBALLY and 47 temp directories surviving one run of that one file. After:
# 0 and 0.
.ST_RULE2_BASELINE <- integer(0)

test_that("no on.exit() discards the withr cleanups a setup helper bound to the calling test's frame", {
  files <- .st_lint_source_files()

  # The helpers are discovered across the WHOLE suite, because the helper is
  # normally defined in a different file from the tests that call it.
  helpers <- character(0)
  parsed <- list()
  for (f in files) {
    lines <- readLines(f, warn = FALSE)
    pd <- .st_parse_tree(lines, file_label = basename(f))
    parsed[[f]] <- lines
    helpers <- c(helpers, .st_frame_borrowing_helpers(pd, lines))
  }
  helpers <- unique(helpers)
  expect_true(length(helpers) > 0,
              info = paste0(
                "no frame-borrowing setup helper found - either the idiom was ",
                "renamed or the detector broke, and this rule is now vacuous"
              ))

  counts <- integer(0)
  detail <- character(0)
  for (f in files) {
    lines <- parsed[[f]]
    s <- .st_scan_exit_frames(lines, basename(f))
    if (nrow(s$exits) == 0) next
    calls <- .st_find_calls(s$pd, helpers)
    if (nrow(calls) == 0) next
    call_scope <- .st_innermost_scope(s$scopes, calls)

    n <- 0L
    for (i in seq_len(nrow(s$exits))) {
      if (!s$replaces[[i]]) next
      si <- s$exit_scope[[i]]
      if (is.na(si) || !(si %in% call_scope[!is.na(call_scope)])) next
      n <- n + 1L
      detail <- c(detail, sprintf("%s:%d", basename(f), s$exits$line1[[i]]))
    }
    if (n > 0L) counts[[basename(f)]] <- n
  }

  # Compare against the ratchet on the union of both key sets, so a brand-new
  # offending file and a fully-cleaned baseline file are both caught.
  # as.character() because `names()` of an EMPTY named vector is NULL, and
  # `union(NULL, NULL)` is NULL rather than character(0) - so in the fully-clean
  # state (the one this rule is trying to reach) both verdicts below came back
  # NULL and failed against character(0). The success case was the last one to
  # be exercised, which is exactly when that shows up.
  all_files <- as.character(union(names(counts), names(.ST_RULE2_BASELINE)))
  # `[[` on a named ATOMIC vector throws "subscript out of bounds" for a name
  # it does not hold - it does not return NULL the way a list does. Looking a
  # count up that way would therefore ERROR on exactly the two cases this
  # ratchet exists to report: a brand-new offending file (absent from the
  # baseline) and a fully-cleaned one (absent from the counts). Index by
  # position with an explicit default instead.
  lookup <- function(v, k) {
    i <- match(k, names(v))
    if (is.na(i)) 0L else as.integer(v[[i]])
  }
  now <- vapply(all_files, function(k) lookup(counts, k), integer(1))
  was <- vapply(all_files, function(k) lookup(.ST_RULE2_BASELINE, k), integer(1))

  grew <- all_files[now > was]
  # Filter the site list by FILE, not by `startsWith(detail, "a|b")` - that
  # builds a regex alternation and hands it to a literal-prefix test, which
  # matches nothing, so the report would name no sites at all.
  grew_detail <- detail[sub(":.*$", "", detail) %in% grew]
  expect_equal(
    grew, character(0),
    info = paste0(
      "NEW instances of the leak. A setup helper registers its withr cleanups ",
      "on the CALLING test's frame via .local_envir; an on.exit() without ",
      "add = TRUE on that same frame discards them, leaking global options and ",
      "temp directories. Use withr::defer(). Sites:\n  ",
      paste(grew_detail, collapse = "\n  ")
    )
  )

  shrank <- all_files[now < was]
  expect_equal(
    shrank, character(0),
    info = paste0(
      "Good news, but the ratchet must be tightened: these files now have ",
      "FEWER offenders than .ST_RULE2_BASELINE records. Lower the baseline (or ",
      "delete the entry at zero) so the improvement cannot silently regress: ",
      paste(sprintf("%s %d -> %d", shrank, was[now < was], now[now < was]), collapse = ", ")
    )
  )
})

test_that("calibration: the ratchet's comparison handles a file missing from EITHER side, and names the sites it reports", {
  # The ratchet's arithmetic only ever runs its interesting branches when the
  # lint FIRES, so a green suite exercises none of it. Both bugs found by
  # reading it rather than running it, and both fatal to the report:
  #   * `[[` on a named atomic vector ERRORS on an absent name instead of
  #     returning NULL - so a brand-new offending file, the exact thing this
  #     ratchet is for, would have crashed the test instead of reporting it.
  #   * the site list was filtered with startsWith(detail, "a|b"), a regex
  #     alternation handed to a literal-prefix test, which matches nothing.
  lookup <- function(v, k) {
    i <- match(k, names(v))
    if (is.na(i)) 0L else as.integer(v[[i]])
  }
  counts <- c("new-offender.R" = 3L, "still-dirty.R" = 5L)
  baseline <- c("still-dirty.R" = 5L, "now-clean.R" = 2L)
  all_files <- union(names(counts), names(baseline))

  now <- vapply(all_files, function(k) lookup(counts, k), integer(1))
  was <- vapply(all_files, function(k) lookup(baseline, k), integer(1))

  expect_identical(all_files[now > was], "new-offender.R")
  expect_identical(all_files[now < was], "now-clean.R")
  expect_identical(all_files[now == was], "still-dirty.R")

  detail <- c("new-offender.R:12", "new-offender.R:40", "still-dirty.R:7")
  grew <- all_files[now > was]
  expect_identical(
    detail[sub(":.*$", "", detail) %in% grew],
    c("new-offender.R:12", "new-offender.R:40")
  )
})

test_that("calibration: the bareness detector reads on.exit()'s add argument semantically, not textually", {
  # Before trusting either negative above, prove the REAL detector separates
  # replacing from composing calls. The first version of this lint passed a
  # calibration that never called this function, and shipped a hole that
  # `add = FALSE` walked straight through.
  replacing <- c(
    "on.exit(rm(con))",
    "on.exit(DBI::dbDisconnect(con, shutdown = TRUE))",
    "on.exit(rm(con), add = FALSE)",        # identical in effect to a bare call
    "on.exit(rm(con), FALSE)",              # ... and positionally
    "on.exit(rm(add))",                     # the word `add`, but not the argument
    "on.exit(f(add = TRUE))",               # `add = TRUE` on an INNER call
    "on.exit(rm(con), add = compose)",      # not provably TRUE -> report it
    "on.exit(rm(con), after = FALSE)"
  )
  for (txt in replacing) {
    expect_true(.st_on_exit_replaces(txt),
                info = paste("must be treated as replacing:", txt))
  }

  composing <- c(
    "on.exit(rm(con), add = TRUE)",
    "on.exit(rm(con), TRUE)",                       # positional `add`
    "on.exit(rm(con), add = TRUE, after = FALSE)",
    "on.exit(add = TRUE, expr = rm(con))",          # order does not matter
    "on.exit(DBI::dbDisconnect(con),\n  add = TRUE)"  # line-wrapped
  )
  for (txt in composing) {
    expect_false(.st_on_exit_replaces(txt),
                 info = paste("must be treated as composing:", txt))
  }
})

test_that("calibration: both rules fire on a known-bad snippet, including inside a helper function with no enclosing test_that()", {
  # Rule 1, and the case block-containment could not see: the mock and the
  # on.exit share a HELPER FUNCTION's frame, in a file with no test_that() at
  # all - the shape a helper-*.R file has.
  bad_mock <- c(
    "run_with_stub <- function(db) {",
    '  testthat::local_mocked_bindings(hash_file = function(path) "x")',
    "  con <- 1",
    "  on.exit(rm(con))",
    "  con",
    "}"
  )
  s <- .st_scan_exit_frames(bad_mock, "<calibration-mock>")
  mocks <- .st_find_calls(s$pd, "local_mocked_bindings")
  mock_scope <- .st_innermost_scope(s$scopes, mocks)
  expect_equal(nrow(s$exits), 1)
  expect_true(s$replaces[[1]])
  expect_false(is.na(s$exit_scope[[1]]))
  expect_true(s$exit_scope[[1]] %in% mock_scope,
              info = "the mock and the on.exit must be attributed to the same frame")

  # The same snippet with add = TRUE must NOT be reported - a detector that
  # flags everything is as useless as one that flags nothing.
  good_mock <- sub("on.exit(rm(con))", "on.exit(rm(con), add = TRUE)", bad_mock, fixed = TRUE)
  s_good <- .st_scan_exit_frames(good_mock, "<calibration-mock-good>")
  expect_false(s_good$replaces[[1]])

  # Rule 2: the frame-borrowing helper is recognised from its own source, and
  # a bare on.exit in a block that calls it is attributed to that same block.
  bad_setup <- c(
    "my_setup <- function() {",
    "  env <- parent.frame()",
    "  withr::local_options(list(a = 1), .local_envir = env)",
    "  TRUE",
    "}",
    'test_that("offender", {',
    "  s <- my_setup()",
    "  con <- 1",
    "  on.exit(rm(con))",
    "  expect_true(TRUE)",
    "})"
  )
  pd <- .st_parse_tree(bad_setup, "<calibration-setup>")
  helpers <- .st_frame_borrowing_helpers(pd, bad_setup)
  expect_identical(helpers, "my_setup")

  s2 <- .st_scan_exit_frames(bad_setup, "<calibration-setup>")
  calls <- .st_find_calls(s2$pd, helpers)
  call_scope <- .st_innermost_scope(s2$scopes, calls)
  expect_equal(nrow(s2$exits), 1)
  expect_true(s2$replaces[[1]])
  expect_true(s2$exit_scope[[1]] %in% call_scope,
              info = "the setup call and the on.exit must share the test_that frame")

  # A `\(x)` lambda is a frame too. Its parse token is neither FUNCTION nor any
  # "LAMBDA" spelling, and getting it wrong fails OPEN - the scan just finds no
  # lambdas and reports clean - so pin that both spellings are seen.
  both_forms <- c("f <- \\(x) x + 1", "g <- function(y) y")
  defs <- .st_find_function_defs(.st_parse_tree(both_forms, "<calibration-lambda>"))
  expect_equal(nrow(defs), 2,
               info = "a backslash lambda must be recognised as a function definition")

  # And the negative control for rule 2: an on.exit inside a NESTED function is
  # a different frame and must not be attributed to the block.
  nested_ok <- c(
    'test_that("not an offender", {',
    "  s <- my_setup()",
    "  f <- function() {",
    "    con <- 1",
    "    on.exit(rm(con))",
    "  }",
    "  expect_true(TRUE)",
    "})"
  )
  s3 <- .st_scan_exit_frames(nested_ok, "<calibration-nested>")
  calls3 <- .st_find_calls(s3$pd, "my_setup")
  call_scope3 <- .st_innermost_scope(s3$scopes, calls3)
  expect_equal(nrow(s3$exits), 1)
  expect_false(s3$exit_scope[[1]] %in% call_scope3,
               info = "a nested function's on.exit belongs to the function, not the block")
})
