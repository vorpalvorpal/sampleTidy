# PLAN-23 3.2 (R-23.6): add_feature() refuses a name that reduces to the same
# canonical key as an existing feature's name. The refusal is a
# sampletidy_error whose message names the new name, the shared canonical key
# and the existing feature, so the operator can act on it. A cli markup
# mistake in the message (a leading-dot `{.fn(...)}` read as an inline class)
# must not replace that text with a cli formatting error.
# Fixture: t23_setup() (helper-feature-register.R).

clash_condition <- function(expr) {
  e <- tryCatch({ force(expr); NULL }, error = function(e) e)
  expect_false(is.null(e), info = "add_feature() did not refuse")
  e
}

test_that("R-23.6: the canonical-clash refusal names the name, the canonical key and the existing feature", {
  s <- t23_setup()
  before <- t23_fingerprint(s$con)
  e <- clash_condition(add_feature(name = "T.S1", site = "T", actor = "tester", reason = "x"))
  skip_if(is.null(e))
  expect_s3_class(e, "sampletidy_error")
  msg <- cli::ansi_strip(conditionMessage(e))
  expect_match(msg, "canonical key", fixed = TRUE)
  expect_match(msg, "T.S1", fixed = TRUE)
  expect_match(msg, .st_feature_name_key("T.S1"), fixed = TRUE)
  expect_match(msg, "T.S01", fixed = TRUE)
  expect_match(msg, "existing feature", fixed = TRUE)
  expect_identical(t23_fingerprint(s$con), before)
})

test_that("R-23.6: the canonical-clash refusal is not a cli formatting error", {
  s <- t23_setup()
  e <- clash_condition(add_feature(name = "T.S6", site = "T", actor = "tester", reason = "x"))
  skip_if(is.null(e))
  msg <- cli::ansi_strip(conditionMessage(e))
  expect_false(grepl("cli|glue|Invalid|Could not|unknown|inline", msg, ignore.case = FALSE), info = msg)
  # db_transaction() wraps a refusal (parent = the refusal); the innermost
  # condition must be add_feature()'s own sampletidy_error, not cli's.
  root <- e
  while (inherits(root$parent, "condition")) root <- root$parent
  expect_s3_class(root, "sampletidy_error")
  expect_match(cli::ansi_strip(conditionMessage(root)), "canonical key", fixed = TRUE)
  expect_match(msg, "T.S06", fixed = TRUE)
})
