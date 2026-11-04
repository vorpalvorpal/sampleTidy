# Stage 1 of the layer move: the site names come from `checks$site_names` (a
# named character vector, code -> name), not from a hard-coded label. Stage 2:
# the core renders nothing, so the map travels in status.json as `site_names`
# and the flags keep the raw code. Synthetic: sites N (mapped), M (unmapped)
# and B (which the old hard-coded label used to turn into a name).

sn_chk <- function(site_names) {
  sx_checks(site_names = site_names,
            schedule = fl_schedule(list(site = "N", stream = "field", months = "8"),
                                   list(site = "M", stream = "field", months = "8"),
                                   list(site = "B", stream = "field", months = "8")))
}

test_that("site names: status.json carries the map as `site_names`; the flags keep the raw codes (never a label)", {
  s <- fl_status_setup()
  fl_status(s, checks = sn_chk(c(N = "Northvale")))
  js <- fl_status_json(s)
  expect_identical(js$site_names, list(N = "Northvale"))
  expect_setequal(vapply(js$flags, function(x) x$site, ""), c("N", "M", "B"))
  expect_false(grepl("Northvale", paste(readLines(file.path(s$report_dir, "status.json")), collapse = "\n"),
                     fixed = TRUE))
})

test_that("site names: a NULL map is an empty object, never null or an array", {
  s <- fl_status_setup()
  fl_status(s, checks = sn_chk(NULL))
  txt <- paste(readLines(file.path(s$report_dir, "status.json"), warn = FALSE), collapse = "\n")
  expect_match(txt, "\"site_names\": {}", fixed = TRUE)
  expect_length(fl_status_json(s)$site_names, 0)
})

test_that("site names: status.json keeps the raw code whatever the map says", {
  s <- fl_status_setup()
  fl_status(s, checks = sn_chk(c(N = "Northvale")))
  js <- fl_status_json(s)
  sites <- vapply(js$flags, function(x) x$site, "")
  expect_setequal(sites, c("N", "M", "B"))
})

test_that("site names: the map is carried into the status build (fs$site_names)", {
  s <- fl_status_setup()
  fs <- sampleTidy:::.flags_for_status(s$db, fl_now(), sn_chk(c(N = "Northvale")), s$report_dir)
  expect_identical(fs$site_names, c(N = "Northvale"))
  fs0 <- sampleTidy:::.flags_for_status(s$db, fl_now(), sn_chk(NULL), s$report_dir)
  expect_null(fs0$site_names)
})

test_that("site names: anything but NULL or a named character vector with unique, non-empty names stops import_flags", {
  db <- fl_db()
  bad <- list(
    unnamed = c("Northvale"),
    partly_named = c(N = "Northvale", "Elsewhere"),
    empty_name = structure("Northvale", names = ""),
    duplicate_codes = c(N = "Northvale", N = "Other"),
    not_character = c(N = 1),
    a_list = list(N = "Northvale"))
  for (nm in names(bad)) {
    expect_error(sx_raw_flags(db, list(site_names = bad[[nm]])), "site_names must be", info = nm)
  }
  expect_no_error(sx_raw_flags(db, list(site_names = NULL)))
  expect_no_error(sx_raw_flags(db, list(site_names = c(N = "Northvale", M = "Midvale"))))
})
