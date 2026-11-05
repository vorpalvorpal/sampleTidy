# Stage 1 of the layer move: the ACIRL gas adapter no longer knows which sites
# exist. `st_config("site_keywords")` is NULL or a named list mapping a site
# code to keywords found in the workbook's own text (spec A7).
#
#   NULL / empty   no inference: report$site is NA, features carry no "<site>."
#                  prefix, nothing aborts.
#   non-empty      per code, count the text cells that match any keyword (fixed,
#                  case-insensitive, a cell counts once per code); one maximum
#                  above 0 wins. A tie, or no hit, aborts sampletidy_parse_error
#                  naming the codes. Features get the prefix "<code>.".
#   anything else  (unnamed list, non-character keywords) aborts sampletidy_error.
#
# Workbooks are synthetic: the site is "Northvale" (or "Southvale"), built with
# the Millbrook-shaped helper (buildings, biofilter grids, bores) and a small
# landfill-only helper.

# The site texts the helpers write, so a test can place them in chosen cells.
gs_front <- "Northvale Recycling Facility Gas Sampling"

gs_millbrook_shaped <- function(dir, name = "2400-9950-01-01 January 2026 Gas Monitoring Northvale.xlsx",
                               front_title = gs_front,
                               sheet_titles = c("ALS Coal Division", gs_front),
                               front_address = "1 Test Rd, Testville NSW 2000") {
  build_gas_millbrook(dir, report_no = "2400-9950-01-01", sample_date = "2026-01-15",
                     filename = name, front_title = front_title, front_address = front_address,
                     sheet_titles = sheet_titles)
}

# One landfill sheet: G101, G102 and the bare point `3` (a weekly point).
gs_mini <- function(dir, front_title = gs_front, sheet_title = "Test landfill",
                    front_address = "1 Test Rd, Testville NSW 2000",
                    name = "2400-9951-01-01 January 2026 Gas Monitoring.xlsx") {
  wb <- openxlsx::createWorkbook()
  gx_front_millbrook(wb, "2400-9951-01-01", "2026-01-15", title = front_title,
                    address = front_address)
  gx_landfill_sheet(wb, "Gas Landfil #1", list(list(G101 = 0.01, G102 = 0, `3` = 0.1)),
                    report_no = "2400-9951-01-01", titles = sheet_title, title_rows = 1L)
  gx_map_sheet(wb)
  gx_save(wb, dir, name)
}

gs_keywords <- function(kw, env = parent.frame()) {
  withr::local_options(list(sampletidy.site_keywords = kw), .local_envir = env)
}

gs_millbrook_names <- function() {
  sub("^M\\.", "", gas_expected_millbrook())
}

# ---- 30. no keywords --------------------------------------------------------------------------

test_that("site keywords NULL: features carry no prefix, report$site is NA, nothing aborts", {
  dir <- withr::local_tempdir()
  p <- gs_millbrook_shaped(dir)
  gs_keywords(NULL)
  out <- expect_no_error(gas_parse(p))
  expect_true(is.na(out$report$site))
  feats <- out$results$feature_raw
  # the same points as a Millbrook-shaped workbook, minus the site prefix; the
  # template-slot skip compares site-qualified names, so G365/G366 now come through
  expect_setequal(feats, c(gs_millbrook_names(), "G365", "G366"))
  expect_false(any(grepl("^[A-Z]\\.", feats)))
  expect_setequal(out$samples$feature_raw, feats)
  expect_true(all(c("G186", "MP_1", "MP_4", "Biofilter North Corner R1C2",
                    "Meal Room - Air conditioner") %in% feats))
  expect_false("template_slot" %in% out$report$skipped$reason)
})

test_that("site keywords NULL / empty: a bare numbered point is 'Weekly <n>'", {
  dir <- withr::local_tempdir()
  p <- gs_mini(dir)
  for (kw in list(NULL, list())) {
    gs_keywords(kw)
    out <- gas_parse(p)
    expect_true(is.na(out$report$site))
    expect_setequal(out$results$feature_raw, c("G101", "G102", "Weekly 3"))
  }
})

# ---- 31. keywords ---------------------------------------------------------------------------------

test_that("site keywords: the site is inferred case-insensitively and prefixes every feature", {
  dir <- withr::local_tempdir()
  p <- gs_millbrook_shaped(dir)
  gs_keywords(list(N = "northvale", S = c("southvale", "sv site")))
  out <- gas_parse(p)
  expect_identical(out$report$site, "N")
  feats <- out$results$feature_raw
  expect_setequal(feats, c(sub("^", "N.", gs_millbrook_names()), "N.G365", "N.G366"))
  expect_true(all(startsWith(feats, "N.")))
  expect_true(all(c("N.G186", "N.MP_3", "N.Biofilter North Corner R1C2") %in% feats))
  # upper-case workbook text, lower-case keyword
  p2 <- gs_mini(dir, front_title = "NORTHVALE RECYCLING", name = "upper.xlsx")
  expect_setequal(gas_parse(p2)$results$feature_raw, c("N.G101", "N.G102", "N.Weekly 3"))
  # the second keyword of the second code
  p3 <- gs_mini(dir, front_title = "Recycling at the SV Site", name = "second.xlsx")
  out3 <- gas_parse(p3)
  expect_identical(out3$report$site, "S")
  expect_true(all(startsWith(out3$results$feature_raw, "S.")))
})

test_that("site keywords: matching is fixed (not a regex) and a cell counts once per code", {
  dir <- withr::local_tempdir()
  # fixed: "n.rthvale" would match "Northvale" as a regex, but is not a substring of it
  gs_keywords(list(N = "n.rthvale", S = "southvale"))
  expect_error(gas_parse(gs_mini(dir, name = "fixed.xlsx")), class = "sampletidy_parse_error")
  # once per cell: one front-page cell holds both of N's keywords (count 1);
  # S's keyword is in two other cells (count 2), so S wins
  gs_keywords(list(N = c("northvale", "recycling facility"), S = "southvale"))
  p <- gs_mini(dir, front_title = gs_front, sheet_title = "Southvale landfill",
               front_address = "1 Test Rd, Southvale NSW", name = "once.xlsx")
  expect_identical(gas_parse(p)$report$site, "S")
})

# ---- 32. ties and misses -------------------------------------------------------------------------------

test_that("site keywords: a tie at the maximum aborts sampletidy_parse_error naming the codes", {
  dir <- withr::local_tempdir()
  p <- gs_mini(dir, front_title = "Northvale Recycling", sheet_title = "Southvale landfill",
               name = "tie.xlsx")
  gs_keywords(list(N = "northvale", S = "southvale"))
  e <- expect_error(gas_parse(p), class = "sampletidy_parse_error")
  msg <- conditionMessage(e)
  expect_match(msg, "cannot tell the site", fixed = TRUE)
  expect_match(msg, "\\bN\\b")
  expect_match(msg, "\\bS\\b")
  expect_match(msg, "from the workbook's own text", fixed = TRUE)
})

test_that("site keywords: no hit at all aborts sampletidy_parse_error naming the codes", {
  dir <- withr::local_tempdir()
  p <- gs_mini(dir, front_title = "Elsewhere Recycling", name = "nohit.xlsx")
  gs_keywords(list(N = "northvale", S = "southvale"))
  e <- expect_error(gas_parse(p), class = "sampletidy_parse_error")
  msg <- conditionMessage(e)
  expect_match(msg, "cannot tell the site", fixed = TRUE)
  expect_match(msg, "\\bN\\b")
  expect_match(msg, "\\bS\\b")
})

# ---- 33. invalid configuration ----------------------------------------------------------------------------------

test_that("site keywords: an unnamed list, or non-character keywords, abort sampletidy_error", {
  dir <- withr::local_tempdir()
  p <- gs_mini(dir, name = "cfg.xlsx")
  for (kw in list(list("northvale"),
                  list(N = "northvale", "southvale"),
                  list(N = 1),
                  list(N = list("northvale")),
                  "northvale")) {
    gs_keywords(kw)
    expect_error(gas_parse(p), class = "sampletidy_error", info = deparse(kw))
  }
})

test_that("site keywords: an env var cannot supply them (st_config aborts, so no silent single entry)", {
  withr::local_options(list(sampletidy.site_keywords = NULL))
  withr::local_envvar(c(SAMPLETIDY_SITE_KEYWORDS = "northvale"))
  expect_error(st_config("site_keywords"), class = "sampletidy_error")
  dir <- withr::local_tempdir()
  expect_error(gas_parse(gs_mini(dir, name = "env.xlsx")), class = "sampletidy_error")
})
