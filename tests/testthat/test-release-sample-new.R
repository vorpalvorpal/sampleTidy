# tests/testthat/test-release-sample-new.R
#
# Companion to test-release-sample-override.R (2026-10-21): a release with
# `overrides = list(sample = "new")` puts its rows on a fresh sample, which
# holds nothing yet, so the existing-analysis lookup must not compare them with
# analyses on the point-day's other samples. Reuses that file's file-local
# rs_* helpers: only its top-level assignments are evaluated here, so its
# test_that() blocks do not run twice.

for (rs_expr in parse(test_path("test-release-sample-override.R"), keep.source = FALSE)) {
  if (is.call(rs_expr) && identical(rs_expr[[1]], as.name("<-"))) eval(rs_expr, environment())
}
rm(rs_expr)

test_that("a release onto a new sample is not skipped against another sample's equal reading", {
  db <- rs_two_items(0.9, 1.2)
  con <- seed_con(db$path)
  DBI::dbExecute(con, "INSERT INTO analysis (uuid, uuid_sample, uuid_lab, value, quantified, rl_low)
                       VALUES ('an-s-a-lm-fec', 's-a', 'lm-fec', 0.9, TRUE, NULL)")
  DBI::dbDisconnect(con, shutdown = TRUE)

  sampleTidy::release_review(db$item_1, overrides = list(sample = "new"),
                             resolved_by = "tester", db = db$path)

  con <- seed_con(db$path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  ec <- DBI::dbGetQuery(con, "SELECT uuid_sample, value FROM analysis
                               WHERE uuid_lab = 'lm-fec' ORDER BY uuid_sample")
  expect_equal(nrow(ec), 2)
  expect_false(any(ec$uuid_sample[ec$uuid_sample != "s-a"] %in% c("s-a", "s-b")))
  expect_equal(ec$value, c(0.9, 0.9))
  expect_length(rs_values(con, "s-b"), 0)
  expect_equal(nrow(rs_reviews(con, "value_conflict")), 0)
})
