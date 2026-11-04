# Stage 1 of the layer move: the status note's site names come from
# `checks$site_names` (a named character vector, code -> name), not from the
# hard-coded .inbox_site_label(). The status.json flags keep the raw code.
# Synthetic: sites N (mapped), M (unmapped) and B (which the old hard-coded
# label used to turn into a name).

sn_chk <- function(site_names) {
  sx_checks(site_names = site_names,
            schedule = fl_schedule(list(site = "N", stream = "field", months = "8"),
                                   list(site = "M", stream = "field", months = "8"),
                                   list(site = "B", stream = "field", months = "8")))
}

# The "· <site> ·" cell of the note's overdue lines, by site code's date line.
sn_lines <- function(s) {
  sec <- md_section(read_status_note(s$report_dir), "Flags")
  sec[grepl("^- 2026-08-01", sec)]
}

test_that("site names: the note shows the mapped name; an unmapped site shows the code (never the old hard-coded label)", {
  s <- fl_status_setup()
  fl_status(s, checks = sn_chk(c(N = "Northvale")))
  ln <- sn_lines(s)
  expect_length(ln, 3)
  expect_true(any(grepl("2026-08-01 · Northvale ·", ln, fixed = TRUE)))
  expect_true(any(grepl("2026-08-01 · M ·", ln, fixed = TRUE)))
  expect_true(any(grepl("2026-08-01 · B ·", ln, fixed = TRUE)))
  expect_false(any(grepl("Northvale", ln, fixed = TRUE)))
  expect_false(any(grepl("· N ·", ln, fixed = TRUE)))
})

test_that("site names: a NULL map shows every raw code", {
  s <- fl_status_setup()
  fl_status(s, checks = sn_chk(NULL))
  ln <- sn_lines(s)
  expect_length(ln, 3)
  for (code in c("N", "M", "B")) {
    expect_true(any(grepl(sprintf("2026-08-01 · %s ·", code), ln, fixed = TRUE)), info = code)
  }
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
