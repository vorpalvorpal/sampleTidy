# Stage 3 of the layer move (D4): the gas template slots are deployment config,
# st_config("gas_template_slots"), not a constant in the adapter.
#
#   NULL (the default)  no slot is skipped.
#   character vector    each site-qualified feature name is skipped as
#                       `template_slot` when read as a number.
#   anything else       (NA, "", a list, a number) aborts the parse with
#                       sampletidy_error, naming the key.
#
# The workbooks are synthetic, built with the Millbrook-shaped helper; the setup
# file pins the slot option for the older gas suites.

gts_reasons <- function(out) {
  sk <- out$report$skipped
  if (is.null(sk) || nrow(sk) == 0) return(character(0))
  sk$reason
}

gts_parse <- function(slots, keywords = list(M = "millbrook"), env = parent.frame()) {
  dir <- withr::local_tempdir(.local_envir = env)
  p <- build_gas_millbrook(dir)
  withr::local_options(list(sampletidy.site_keywords = keywords,
                            sampletidy.gas_template_slots = slots), .local_envir = env)
  gas_parse(p)
}

test_that("gas_template_slots NULL: M.G365 and M.G366 are emitted and nothing is a template_slot", {
  out <- gts_parse(NULL)
  expect_true(all(c("M.G365", "M.G366") %in% out$results$feature_raw))
  expect_false("template_slot" %in% gts_reasons(out))
})

test_that("gas_template_slots set: the named features are skipped with reason template_slot", {
  out <- gts_parse(c("M.G365", "M.G366"))
  expect_false(any(c("M.G365", "M.G366") %in% out$results$feature_raw))
  expect_false(any(c("M.G365", "M.G366") %in% out$samples$feature_raw))
  expect_equal(sum(gts_reasons(out) == "template_slot"), 2)
  expect_true("M.G362" %in% out$results$feature_raw)
})

test_that("gas_template_slots is site-qualified: a slot at another site's prefix is not skipped", {
  out <- gts_parse(c("N.G365", "N.G366"))
  expect_true(all(c("M.G365", "M.G366") %in% out$results$feature_raw))
  expect_false("template_slot" %in% gts_reasons(out))
})

test_that("gas_template_slots: an invalid value aborts the parse with sampletidy_error naming the key", {
  for (bad in list(NA_character_, "", c("M.G365", ""), c("M.G365", NA), list("a"), 1)) {
    expect_error(gts_parse(bad), class = "sampletidy_error", regexp = "gas_template_slots",
                 info = paste(deparse(bad), collapse = ""))
  }
})

test_that("gas_template_slots is list-valued: SAMPLETIDY_GAS_TEMPLATE_SLOTS aborts, and the default is NULL", {
  withr::local_options(list(sampletidy.gas_template_slots = NULL))
  withr::local_envvar(c(SAMPLETIDY_GAS_TEMPLATE_SLOTS = NA))
  expect_null(st_config("gas_template_slots"))
  withr::local_envvar(c(SAMPLETIDY_GAS_TEMPLATE_SLOTS = "x"))
  expect_error(st_config("gas_template_slots"), class = "sampletidy_error")
})

test_that("gas_template_slots: a valid vector round-trips through st_config()", {
  withr::local_options(list(sampletidy.gas_template_slots = NULL))
  st_config("gas_template_slots", c("M.G365", "M.G366"))
  expect_identical(st_config("gas_template_slots"), c("M.G365", "M.G366"))
})
