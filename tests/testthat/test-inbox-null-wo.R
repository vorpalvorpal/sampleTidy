# Live DB holds projects with a NULL name; the work-order diff must not crash on them.
test_that(".inbox_work_orders tolerates work orders with no name", {
  pre <- list(
    samples = data.frame(uuid = "s1", wo = NA_character_, dt = as.POSIXct(NA), site = NA_character_),
    an = data.frame(wo = c(NA_character_, "ES1"), n = c(3, 2)))
  post <- list(
    samples = data.frame(uuid = c("s1", "s2"), wo = c(NA_character_, "ES1"),
                         dt = as.POSIXct(c(NA, "2026-07-01"), tz = "UTC"), site = c(NA, "B")),
    an = data.frame(wo = c(NA_character_, "ES1"), n = c(3, 5)))
  out <- sampleTidy:::.inbox_work_orders(pre, post, "ALS lab")
  expect_length(out, 1)
  expect_identical(out[[1]]$name, "ES1")
  expect_identical(out[[1]]$analyses, 3L)
})
