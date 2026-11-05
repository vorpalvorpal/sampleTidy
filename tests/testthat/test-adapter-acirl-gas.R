# tests/testthat/test-adapter-acirl-gas.R
#
# TDD "red" tests for the ACIRL monthly-gas adapter `acirl_gas_xlsx`
# (PLAN-17-adapter-acirl-gas.md, "Tests first" 1-10 and 15, plus the
# naming/semantics rulings settled 2026-10-16). End-to-end tests (9, 11-14 and
# the review half of 6/7) live in test-acirl-gas-e2e.R.
#
# Workbooks are built at test time by helper-acirl-gas.R, whose header records
# the real geometry each family copies. Expected counts below are hard-coded
# against that helper's DEFAULT content (summarised again where used) - they
# are NOT derived from the builder, so a builder change cannot silently move
# the goalposts.
#
# R/adapter-acirl-gas.R does not exist yet: every test except the reachability
# guards fails on `gas_adapter()`'s "acirl_gas_xlsx adapter is not registered".

# ---- shared fixtures (built once per file, read-only afterwards) -------------

gas_dir <- withr::local_tempdir()
fx <- list(
  b2025   = build_gas_northvale_2025(gas_dir),
  b2026   = build_gas_northvale_2025(gas_dir, report_no = "2400-9904-03-01",
                                    filename = "2400-9904-03-01 Mar 2026 Gas Monitoring Northvale WMF.xlsx",
                                    shift = 1L),
  weekly  = build_gas_northvale_2025(gas_dir, report_no = "2400-9905-05-01",
                                    filename = "2400-9905-05-01 Weekly Gas Monitoring Northvale WMF.xlsx",
                                    weekly = TRUE),
  b2024   = build_gas_northvale_2024(gas_dir),
  b2021   = build_gas_northvale_2021(gas_dir),
  kat     = build_gas_millbrook(gas_dir)
)

# gas_parse() of a shared fixture, memoised per fixture for this file (PLAN-22
# B3: ~50 tests re-parsed the same six workbooks). The fixtures above are
# never written after they are built, so one parse per fixture is the same
# parse every test used to repeat. The memo hands back an ordinary list of
# tibbles, which R copies on modify, so a test that alters its `out` alters
# only its own copy. Tests that build their OWN workbook, that compare two
# parses (the determinism test), or that assert on the parse call itself
# (errors) still call gas_parse() directly.
.gas_fx_parsed <- new.env(parent = emptyenv())
gas_parse_fx <- function(nm) {
  if (is.null(.gas_fx_parsed[[nm]])) .gas_fx_parsed[[nm]] <- gas_parse(fx[[nm]])
  .gas_fx_parsed[[nm]]
}

gas_reasons <- function(out) {
  sk <- out$report$skipped
  if (is.null(sk) || nrow(sk) == 0) return(character(0))
  sk$reason
}

# ==============================================================================
# 0 - the adapter exists (read this failure first)
# ==============================================================================

test_that("0: `acirl_gas_xlsx` is registered by register_builtin_adapters() with id/version/match/parse", {
  register_builtin_adapters()
  reg <- sampleTidy:::adapter_registry()
  expect_true("acirl_gas_xlsx" %in% names(reg))
  ad <- reg[["acirl_gas_xlsx"]]
  expect_identical(ad$id, "acirl_gas_xlsx")
  expect_true(is.character(ad$version) && length(ad$version) == 1 && nzchar(ad$version))
  expect_true(is.function(ad$match))
  expect_true(is.function(ad$parse))
})

test_that("0 (guard): every builder produces a readable workbook with the real sheet names", {
  # Passes today. Pins that no fixture/syntax error can masquerade as an
  # adapter failure below - and that the trailing spaces survived.
  expect_identical(readxl::excel_sheets(fx$b2025),
                   c("Front Page", "Gas Landfil #1", "Gas Landfil #2", "Gas Landfil #3", "MAP"))
  expect_identical(readxl::excel_sheets(fx$b2024),
                   c("Front Page", "Gas Landfil #1", "Gas Landfil #2", "Gas Buildings ", "MAP"))
  expect_identical(readxl::excel_sheets(fx$b2021),
                   c("Front Page", "Gas Landfil #1", "Gas Landfil #2", "Gas Buildings ", "MAP"))
  expect_identical(readxl::excel_sheets(fx$kat),
                   c("Front Page", "Gas Landfil #1", "Gas Landfil #2 ", "Gas Building 1",
                     "Gas Building 2", "Gas Building 3", "Biofliter and Bores", "MAP"))
})

# ==============================================================================
# 1 - match()
# ==============================================================================

test_that("1: match() is `format` on every family fixture", {
  for (nm in names(fx)) {
    expect_identical(gas_adapter()$match(sampleTidy:::file_meta(fx[[nm]])), "format", info = nm)
  }
})

test_that("1: on every gas fixture the gas adapter is the ONLY claimant (every other adapter says `no`)", {
  ad <- gas_adapter()
  reg <- sampleTidy:::adapter_registry()
  for (nm in names(fx)) {
    fm <- sampleTidy:::file_meta(fx[[nm]])
    tiers <- vapply(reg, function(a) a$match(fm), character(1))
    expect_identical(tiers[["acirl_gas_xlsx"]], "format", info = nm)
    others <- tiers[names(tiers) != "acirl_gas_xlsx"]
    expect_true(length(others) >= 4, info = nm)
    expect_true(all(others == "no"), info = paste(nm, paste(names(others), others, collapse = ", ")))
  }
})

test_that("1: the gas adapter says `no` to the ACIRL water/dust, crosstab, ESdat and random fixtures", {
  ad <- gas_adapter()
  paths <- c(
    test_path("fixtures", "acirl", c(
      "2400-9999-01_Test_WMF.xlsx", "2400-9999-11_Real_WMF.xlsx",
      "2400-9999-12_DustOnly_WMF.xlsx", "2400-9999-13_AlsRefs_WMF.xlsx",
      "2400-9999-14_DustDateConflict_WMF.xlsx", "2400-9999-15_Uncited_WMF.xlsx",
      "EDGECASES.xlsx", "NO_REPORT_NO.xlsx", "random.xlsx")),
    test_path("fixtures", "crosstab", "XX1234567_0_XTAB.xlsx"),
    test_path("fixtures", "esdat", "PROJ_A.ESDAT_XX1234567_0.Sample2e.CSV")
  )
  for (p in paths) {
    expect_true(file.exists(p), info = p)
    expect_identical(ad$match(sampleTidy:::file_meta(p)), "no", info = basename(p))
  }
})

test_that("1: a front page + `Gas Landfil` sheet WITHOUT a `CH4 Reading` header is `no`", {
  dir <- withr::local_tempdir()
  wb <- openxlsx::createWorkbook()
  gx_front_northvale(wb, "2400-9901-07-01", "2025-07-22")
  openxlsx::addWorksheet(wb, "Gas Landfil #1")
  gx_set(wb, "Gas Landfil #1", 7, 1, "Location")
  gx_set(wb, "Gas Landfil #1", 7, 2, "H2S Reading ppm")
  gx_set(wb, "Gas Landfil #1", 8, 1, "G182"); gx_set(wb, "Gas Landfil #1", 8, 2, 0)
  p <- gx_save(wb, dir, "2400-9901-07-01 not gas.xlsx")
  expect_identical(gas_adapter()$match(sampleTidy:::file_meta(p)), "no")
})

test_that("1: a `Gas Landfil` sheet with a CH4 header but NO front-page sheet is `no`", {
  dir <- withr::local_tempdir()
  wb <- openxlsx::createWorkbook()
  gx_landfill_sheet(wb, "Gas Landfil #1", list(list(G182 = 0)), report_no = "2400-9901-07-01")
  p <- gx_save(wb, dir, "2400-9901-07-01 no front.xlsx")
  expect_identical(gas_adapter()$match(sampleTidy:::file_meta(p)), "no")
})

test_that("1: a non-spreadsheet extension is `no` without opening the file", {
  dir <- withr::local_tempdir()
  p <- file.path(dir, "2400-9901-07-01 Monthly Gas Monitoring Northvale WMF.csv")
  writeLines("Location,CH4 Reading % v/v", p)
  expect_identical(gas_adapter()$match(sampleTidy:::file_meta(p)), "no")
})

# ==============================================================================
# IR contract + constants
# ==============================================================================

test_that("IR: output validates; analyte_raw `CH4 Reading % v/v`, units_raw `%`, org ACIRL, adapter tag", {
  for (nm in names(fx)) {
    out <- gas_parse_fx(nm)
    expect_no_error(sampleTidy:::ir_validate(out$results, "results"))
    expect_no_error(sampleTidy:::ir_validate(out$samples, "samples"))
    r <- out$results
    expect_gt(nrow(r), 0)
    expect_true(all(r$analyte_raw == "CH4 Reading % v/v"), info = nm)
    expect_true(all(r$units_raw == "%"), info = nm)
    expect_true(all(r$org == "ACIRL"), info = nm)
    expect_true(all(grepl("^acirl_gas_xlsx/", r$adapter)), info = nm)
    expect_true(all(r$sample_type == "Normal"), info = nm)
  }
})

test_that("IR: one sample per reading - every result joins to exactly one sample with the same feature", {
  for (nm in names(fx)) {
    out <- gas_parse_fx(nm)
    r <- out$results; s <- out$samples
    expect_false(anyNA(r$lab_sample_id), info = nm)
    expect_false(anyDuplicated(s$lab_sample_id) > 0, info = nm)
    expect_equal(nrow(s), nrow(r), info = nm)
    m <- match(r$lab_sample_id, s$lab_sample_id)
    expect_false(anyNA(m), info = nm)
    expect_identical(s$feature_raw[m], r$feature_raw, info = nm)
  }
})

test_that("IR: the parse is deterministic - a re-parse yields identical results and samples", {
  # Two DIRECT parses, deliberately not gas_parse_fx(): a memoised result
  # compared with itself would pass vacuously.
  a <- gas_parse(fx$kat)
  b <- gas_parse(fx$kat)
  expect_identical(a$results, b$results)
  expect_identical(a$samples, b$samples)
})

test_that("IR: report$campaign is `Monthly gas monitoring` (A80 filing)", {
  for (nm in names(fx)) {
    expect_identical(gas_parse_fx(nm)$report$campaign, "Monthly gas monitoring", info = nm)
  }
})

# ==============================================================================
# 2 - header-text block location
# ==============================================================================

test_that("2: Northvale 2025 (header row 7, column offset 0) yields exactly the expected 45 probes", {
  out <- gas_parse_fx("b2025")
  expect_setequal(out$results$feature_raw, gas_expected_b2025_monthly())
  expect_equal(nrow(out$results), 45)
})

test_that("2: the Mar-2026 shape (#1/#2 one column right) parses identically to the unshifted one", {
  a <- gas_parse_fx("b2025")$results
  b <- gas_parse_fx("b2026")$results
  expect_setequal(b$feature_raw, gas_expected_b2025_monthly())
  a <- a[order(a$feature_raw), ]; b <- b[order(b$feature_raw), ]
  expect_identical(b$feature_raw, a$feature_raw)
  expect_identical(b$value_num, a$value_num)
})

test_that("2: Millbrook (header row 6, one column in, `CH4 Reading     % v/v`) yields all 50 readings (52 cells less 2 template slots)", {
  out <- gas_parse_fx("kat")
  expect_setequal(out$results$feature_raw, gas_expected_millbrook())
  expect_equal(nrow(out$results), 50)
})

test_that("2: Northvale 2021 (header row 11) yields its 40 readings", {
  out <- gas_parse_fx("b2021")
  expected <- c(paste0("N.G", c(1:3, 26:28, 51:53, 76:78)),
                paste0("N.G", c(101:106, 126:131, 151:156, 176:181)),
                "N.Toilets - Right Side", "N.Toilets - Left Side",
                "N.Lunch Room - Centre", "N.Main Office - Centre")
  expect_setequal(out$results$feature_raw, expected)
  expect_equal(nrow(out$results), 40)
})

test_that("2: Northvale 2024 landfill (row 7) + `Gas Buildings ` (row 8) yield 31 readings", {
  out <- gas_parse_fx("b2024")
  expect_equal(nrow(out$results), 31)
  expect_equal(sum(grepl("^N\\.G[0-9]+$", out$results$feature_raw)), 23)
  expect_equal(sum(grepl(" - ", out$results$feature_raw)), 8)
})

test_that("2: a `#3` sheet of only 3 rows yields exactly N.G382-N.G384", {
  dir <- withr::local_tempdir()
  p <- build_gas_northvale_2025(dir, l1 = list(list(G182 = 0)), l2 = list(list(G282 = 0)),
                               l2_rows = 8L)
  r <- gas_parse(p)$results
  expect_setequal(r$feature_raw, c("N.G182", "N.G282", "N.G382", "N.G383", "N.G384"))
  expect_equal(gas_value_of(list(results = r), "N.G383"), 0.01)
})

test_that("2: a wholly blank row INSIDE the grid does not end the block (Mar-2026 #2 row 27)", {
  r <- gas_parse_fx("b2025")$results
  # rows 14-15 of `Gas Landfil #2`, below the blank row 13, in every pair
  for (f in paste0("N.G", c(288, 289, 313, 314, 338, 339, 374, 375))) {
    expect_true(f %in% r$feature_raw, info = f)
  }
  expect_equal(gas_value_of(list(results = r), "N.G288"), 0.02)
})

test_that("2: each Location column pairs with ITS OWN CH4 column (values land on the right probe)", {
  out <- gas_parse_fx("b2025")
  expect_equal(gas_value_of(out, "N.G197"), 0.01)   # pair 1
  expect_equal(gas_value_of(out, "N.G223"), 0.02)   # pair 2
  expect_equal(gas_value_of(out, "N.G250"), 0.17)   # pair 3
  expect_equal(gas_value_of(out, "N.G276"), 0.04)   # pair 4
  expect_equal(gas_value_of(out, "N.G283"), 0.01)
  expect_equal(gas_value_of(out, "N.G372"), 0.01)
  k <- gas_parse_fx("kat")
  expect_equal(gas_value_of(k, "M.G187"), 0.01)
})

# ==============================================================================
# 3 - note rows and the 2021 coordinates table yield nothing
# ==============================================================================

test_that("3: `NS: ...` / `NR: ...` note rows yield no result, sample or skip", {
  out <- gas_parse_fx("weekly")
  expect_false(any(grepl("^(NS|NR):", out$results$value_raw)))
  expect_false(any(grepl("NS:|NR:|Unable|requested", out$results$feature_raw)))
  expect_false(any(grepl("NS:|NR:|Unable|requested", out$samples$feature_raw)))
  # exactly the 9 text-coded CELLS are skipped - the 2 note rows are not among them
  expect_equal(length(gas_reasons(out)), 9)
})

test_that("3: the 2021 `Note` row and its `G103 | Working Face` remark yield nothing", {
  out <- gas_parse_fx("b2021")
  expect_equal(sum(out$results$feature_raw == "N.G103"), 1)
  expect_identical(gas_value_of(out, "N.G103"), 0)
  expect_false(any(grepl("Working Face|^Note$", c(out$results$value_raw, out$results$feature_raw))))
  expect_equal(length(gas_reasons(out)), 0)
})

test_that("3: the 2021 `Additional Gas Point Coordinates` table yields nothing", {
  out <- gas_parse_fx("b2021")
  r <- out$results
  # one reading per G179-G181 (the data rows), none from the coordinates rows
  for (f in c("N.G179", "N.G180", "N.G181")) expect_equal(sum(r$feature_raw == f), 1, info = f)
  expect_true(all(r$value_num <= 1))   # no latitude/longitude/UTM value leaked in
  expect_false(any(grepl("Latitude|Longitude|UTM|Coordinates|56H",
                         c(r$feature_raw, r$value_raw, out$samples$feature_raw))))
  expect_equal(nrow(r), 40)
})

# ==============================================================================
# 4 - Location fill-down; duplicate references get `#2`
# ==============================================================================

test_that("4: building Location fills down over blank cells", {
  f <- gas_parse_fx("b2024")$results$feature_raw
  expect_true("N.Toilets - Right Side" %in% f)
  expect_true("N.Toilets - Left Side" %in% f)          # Location blank on this row
  expect_true("N.Weigh Bridge Building - Toilet" %in% f)
  expect_true("N.Storage Shed re used - Back Wall" %in% f)
  expect_true("N.Out side - Reused shed" %in% f)
  expect_false(any(grepl("^N\\. - |^N\\.NA - ", f)))
})

test_that("4: a reference repeated within ONE building gets `#2`", {
  f <- gas_parse_fx("b2024")$results$feature_raw
  expect_equal(sum(f == "N.Storage Shed re used - Right Wall"), 1)
  expect_equal(sum(f == "N.Storage Shed re used - Right Wall #2"), 1)
  k <- gas_parse_fx("kat")
  expect_equal(sum(k$results$feature_raw == "M.Re-use Center - Power point back wall #2"), 1)
  expect_equal(sum(k$results$feature_raw == "M.Meeting Room - Window wall 2 #2"), 1)
})

# A small Northvale-2024-shaped workbook whose `Gas Buildings ` sheet holds
# `entries` (gx_entries(): loc, ref, val). Used to pin the `#n` suffix rule:
# the suffix follows the row's POSITION among same-reference rows in a
# building, whether or not the earlier rows carry a reading.
gas_suffix_parse <- function(entries) {
  d <- withr::local_tempdir(.local_envir = parent.frame())
  rn <- "2400-9902-08-01"
  wb <- openxlsx::createWorkbook()
  gx_front_northvale(wb, rn, "2024-08-07", report_on = "August 2024 Gas Monitoring")
  gx_landfill_sheet(wb, "Gas Landfil #1", list(list(G182 = 0.01, G183 = 0, G184 = 0)),
                    report_no = rn)
  gx_building_sheet(wb, "Gas Buildings ", entries, header_row = 8L, report_no = rn,
                    titles = c("ALS COAL DIVISION", "EXORG NORTHVALE WASTE MANAGEMENT FACILITY",
                               "MONTHLY GAS  REPORT"))
  gx_map_sheet(wb)
  path <- gx_save(wb, d, paste0(rn, " August 2024 Monthly Gas Monitoring Northvale WMF.xlsx"))
  gas_parse(path)
}
gas_suffix_bldg <- function(out) {
  f <- out$results$feature_raw
  f[grepl("^N\\.Shed - ", f)]
}

test_that("4: suffix is positional - a BLANK first occurrence still leaves the second as `#2`", {
  out <- gas_suffix_parse(gx_entries(
    list("Shed", "Wall", NA_real_),
    list(NA, "Wall", 0.01),
    list(NA, "Door", 0)
  ))
  f <- gas_suffix_bldg(out)
  expect_setequal(f, c("N.Shed - Wall #2", "N.Shed - Door"))
  expect_equal(gas_value_of(out, "N.Shed - Wall #2"), 0.01)
})

test_that("4: suffix is positional - an `NS` first occurrence still leaves the second as `#2`", {
  out <- gas_suffix_parse(gx_entries(
    list("Shed", "Wall", "NS"),
    list(NA, "Wall", 0.01)
  ))
  expect_setequal(gas_suffix_bldg(out), "N.Shed - Wall #2")
  expect_equal(gas_value_of(out, "N.Shed - Wall #2"), 0.01)
})

test_that("4: suffix is positional - NR and other skipped text in an earlier occurrence count too", {
  out <- gas_suffix_parse(gx_entries(
    list("Shed", "Wall", "NR"),
    list(NA, "Wall", "No Access"),
    list(NA, "Wall", 0.02)
  ))
  expect_setequal(gas_suffix_bldg(out), "N.Shed - Wall #3")
})

test_that("4: three occurrences with the MIDDLE one blank give no suffix, then `#3`", {
  out <- gas_suffix_parse(gx_entries(
    list("Shed", "Wall", 0.01),
    list(NA, "Wall", NA_real_),
    list(NA, "Wall", 0.03)
  ))
  expect_setequal(gas_suffix_bldg(out), c("N.Shed - Wall", "N.Shed - Wall #3"))
  expect_equal(gas_value_of(out, "N.Shed - Wall"), 0.01)
  expect_equal(gas_value_of(out, "N.Shed - Wall #3"), 0.03)
})

test_that("4: regression - fully populated repeats are still unsuffixed / `#2` / `#3`", {
  out <- gas_suffix_parse(gx_entries(
    list("Shed", "Wall", 0.01),
    list(NA, "Wall", 0.02),
    list(NA, "Wall", 0.03),
    list("Other", "Wall", 0.04)
  ))
  expect_setequal(c(gas_suffix_bldg(out), grep("^N\\.Other", out$results$feature_raw, value = TRUE)),
                  c("N.Shed - Wall", "N.Shed - Wall #2", "N.Shed - Wall #3", "N.Other - Wall"))
  expect_equal(gas_value_of(out, "N.Shed - Wall #2"), 0.02)
  expect_equal(gas_value_of(out, "N.Shed - Wall #3"), 0.03)
})

test_that("4: the same reference in two DIFFERENT buildings is not suffixed", {
  f <- gas_parse_fx("kat")$results$feature_raw
  expect_true("M.Office - Air conditioner" %in% f)
  expect_true("M.Meal Room - Air conditioner" %in% f)
  expect_false(any(grepl("Air conditioner #", f)))
})

test_that("4: feature_raw is unique within every file (A84 refuses repeats)", {
  for (nm in names(fx)) {
    f <- gas_parse_fx(nm)$results$feature_raw
    expect_false(anyDuplicated(f) > 0, info = paste(nm, paste(f[duplicated(f)], collapse = ", ")))
  }
})

test_that("4: runs of whitespace inside a building Location are squished", {
  f <- gas_parse_fx("kat")$results$feature_raw
  expect_true("M.Main Recycle area (Drop Off) - Power point near hose reel" %in% f)
  expect_false(any(grepl("  ", f)))
})

# ==============================================================================
# 5 - site from content, never the filename; naming rulings
# ==============================================================================

test_that("5: probes are site-qualified from content - N.G182 at Northvale, M.G186 at Millbrook", {
  expect_true("N.G182" %in% gas_parse_fx("b2024")$results$feature_raw)
  expect_true("M.G186" %in% gas_parse_fx("kat")$results$feature_raw)
})

test_that("5: B and K never cross - every feature in a file carries that file's site", {
  for (nm in c("b2025", "b2026", "weekly", "b2024", "b2021")) {
    out <- gas_parse_fx(nm)
    expect_true(all(startsWith(c(out$results$feature_raw, out$samples$feature_raw), "N.")), info = nm)
  }
  out <- gas_parse_fx("kat")
  expect_true(all(startsWith(c(out$results$feature_raw, out$samples$feature_raw), "M.")))
})

test_that("5: Millbrook content in a file NAMED Northvale is Millbrook (and the reverse)", {
  dir <- withr::local_tempdir()
  k <- gas_parse(build_gas_millbrook(dir, filename = "2400-9903-12-01 December 2025 Gas Monitoring Northvale WMF.xlsx"))
  expect_true(all(startsWith(k$results$feature_raw, "M.")))
  expect_true("M.G186" %in% k$results$feature_raw)
  b <- gas_parse(build_gas_northvale_2025(dir, filename = "2400-9901-07-01 July 2025 Gas Monitoring Millbrook WMF.xlsx"))
  expect_true(all(startsWith(b$results$feature_raw, "N.")))
  # and a filename naming no site at all changes nothing
  n <- gas_parse(build_gas_millbrook(dir, filename = "gas.xlsx"))
  expect_setequal(n$results$feature_raw, gas_expected_millbrook())
})

test_that("5: a workbook whose content names neither site is refused, never guessed", {
  dir <- withr::local_tempdir()
  p <- build_gas_millbrook(dir, filename = "2400-9903-12-01 Millbrook WMF.xlsx",
                          front_title = "EXORG Gas Sampling", front_address = "1 Test Rd",
                          sheet_titles = c("ALS Coal Division", "EXORG Gas Sampling"))
  expect_error(gas_parse(p), class = "sampletidy_parse_error")
})

test_that("5: probe numbers are emitted verbatim - `N.G1`, not `N.G001` (the resolver pads)", {
  f <- gas_parse_fx("b2021")$results$feature_raw
  expect_true("N.G1" %in% f)
  expect_false("N.G001" %in% f)
})

test_that("5: G368-G384 on a landfill sheet emit `N.G368`..., never a building-style name", {
  out <- gas_parse_fx("b2025")
  f <- out$results$feature_raw
  for (g in c("N.G368", "N.G370", "N.G372", "N.G374", "N.G375", "N.G382", "N.G383", "N.G384")) {
    expect_true(g %in% f, info = g)
  }
  expect_false(any(grepl(" - ", f)))              # no `{Location} - {Reference}` on a landfill-only file
  expect_false(any(grepl("Gatehouse|Demountables|Reuse shed", f, ignore.case = TRUE)))
})

test_that("5: G179-G181 emit N.G179-N.G181 (the registry aliases them to N.TG179-181, not the adapter)", {
  f <- gas_parse_fx("b2021")$results$feature_raw
  expect_true(all(c("N.G179", "N.G180", "N.G181") %in% f))
  expect_false(any(grepl("TG", f)))
})

test_that("5: Millbrook bores emit M.MP_1..K.MP_4 (the registry's MP_n alias form), not a building name", {
  out <- gas_parse_fx("kat")
  f <- out$results$feature_raw
  expect_true(all(paste0("M.MP_", 1:4) %in% f))
  expect_false(any(grepl("Gas Bore", f)))
  expect_equal(gas_value_of(out, "M.MP_3"), 0.01)
})

test_that("5: Northvale weekly points 1-21 emit `N.Weekly 1` ... `N.Weekly 21`", {
  out <- gas_parse_fx("weekly")
  f <- out$results$feature_raw
  expect_true(all(paste("N.Weekly", 1:21) %in% f))
  expect_false(any(f %in% paste0("N.", 1:21)))
  expect_false(any(f %in% paste0("N.G", 1:21)))
  expect_equal(gas_value_of(out, "N.Weekly 1"), 0.07)
  expect_equal(gas_value_of(out, "N.Weekly 11"), 0.18)
  expect_equal(gas_value_of(out, "N.Weekly 15"), 0.22)
  expect_equal(nrow(out$results), 63)
})

test_that("5: Millbrook biofilter grids emit labelled R<r>C<c> names, row-major as laid out", {
  out <- gas_parse_fx("kat")
  g <- out$results[grepl("^M\\.(Biofilter North Corner|Front of Buildings) R[12]C[123]$",
                         out$results$feature_raw), ]
  expect_equal(nrow(g), 12)
  expect_equal(gas_value_of(out, "M.Biofilter North Corner R1C2"), 0.01)
  expect_equal(gas_value_of(out, "M.Biofilter North Corner R2C3"), 0.02)
  expect_equal(gas_value_of(out, "M.Front of Buildings R2C1"), 0.03)
  zeros <- setdiff(g$feature_raw, c("M.Biofilter North Corner R1C2", "M.Biofilter North Corner R2C3",
                                    "M.Front of Buildings R2C1"))
  expect_true(all(g$value_num[g$feature_raw %in% zeros] == 0))
})

test_that("5: UNLABELLED grids default to North Corner first, Front of Buildings second", {
  dir <- withr::local_tempdir()
  out <- gas_parse(build_gas_millbrook(dir, grid_labels = FALSE))
  expect_setequal(out$results$feature_raw, gas_expected_millbrook())
  expect_equal(gas_value_of(out, "M.Biofilter North Corner R1C2"), 0.01)
  expect_equal(gas_value_of(out, "M.Front of Buildings R2C1"), 0.03)
})

# ==============================================================================
# 6 - REPORT NO from the cell; filename mismatch recorded
# ==============================================================================

test_that("6: work_order is the front-page REPORT NO cell, not the filename token", {
  dir <- withr::local_tempdir()
  p <- build_gas_northvale_2025(dir, report_no = "2400-9901-07-01",
                               filename = "2400-9901-07 July 2025 Monthly Gas Monitoring Northvale WMF.xlsx")
  out <- gas_parse(p)
  expect_identical(out$report$header$report_no, "2400-9901-07-01")
  expect_true(all(out$results$work_order == "2400-9901-07-01"))
  expect_true(all(out$samples$work_order == "2400-9901-07-01"))
})

test_that("6: the filename token is kept on the report, and a mismatch with the cell is recorded", {
  dir <- withr::local_tempdir()
  p <- build_gas_northvale_2025(dir, report_no = "2400-9901-07-01",
                               filename = "2400-9901-07 July 2025 Monthly Gas Monitoring Northvale WMF.xlsx")
  out <- gas_parse(p)
  expect_identical(out$report$filename_report_no, "2400-9901-07")
  w <- out$report$warnings
  expect_true(any(grepl("2400-9901-07-01", w, fixed = TRUE) & grepl("2400-9901-07 ", paste0(w, " "), fixed = TRUE)))
})

test_that("6: a filename that AGREES with the cell records no mismatch", {
  out <- gas_parse_fx("b2025")                  # "2400-9901-07-01 July 2025 ..." / cell 2400-9901-07-01
  expect_identical(out$report$filename_report_no, "2400-9901-07-01")
  expect_false(any(grepl("mismatch|disagree|differ", out$report$warnings, ignore.case = TRUE)))
})

test_that("6: `24009902 - 05 Amended` files as `24009902-05`, with `Amended` kept in comments", {
  out <- gas_parse_fx("b2021")
  expect_identical(out$report$header$report_no, "24009902-05")
  expect_true(all(out$results$work_order == "24009902-05"))
  s <- out$samples; r <- out$results
  m <- match(r$lab_sample_id, s$lab_sample_id)
  amended <- grepl("Amended", s$comments[m]) | grepl("Amended", r$comments)
  expect_true(all(amended))
})

test_that("6: whitespace inside the REPORT NO cell is normalised", {
  dir <- withr::local_tempdir()
  p <- build_gas_northvale_2025(dir, report_no = "2400-9901-07-01",
                               front_report_no = "  2400-9901-07-01  ")
  expect_identical(gas_parse(p)$report$header$report_no, "2400-9901-07-01")
})

test_that("6: sampler comes from SAMPLED BY (first name, `& ...` stripped), like the field adapter", {
  out <- gas_parse_fx("b2025")
  expect_true(all(out$samples$sampler == "J. Tester"))
})

# ==============================================================================
# 7 - rounding to 2 dp; more precision -> review
# ==============================================================================

test_that("7: binary-noise readings round to 2 dp - `0.0299999999999999` -> 0.03", {
  out <- gas_parse_fx("b2025")
  r <- out$results[out$results$feature_raw == "N.G199", ]
  expect_equal(nrow(r), 1)
  expect_identical(r$value_num, 0.03)
  expect_identical(r$value_raw, "0.03")
  b <- gas_parse_fx("b2024")
  expect_identical(gas_value_of(b, "N.Out side - Reused shed"), 0.03)
})

test_that("7: every emitted value_raw carries at most 2 decimals and parses to value_num", {
  for (nm in names(fx)) {
    r <- gas_parse_fx(nm)$results
    expect_true(all(grepl("^[0-9]+(\\.[0-9]{1,2})?$", r$value_raw)),
                info = paste(nm, paste(head(r$value_raw[!grepl("^[0-9]+(\\.[0-9]{1,2})?$", r$value_raw)]), collapse = ", ")))
    expect_identical(as.numeric(r$value_raw), r$value_num, info = nm)
  }
})

test_that("7: a reading with GENUINE >2 dp precision is never silently rounded", {
  dir <- withr::local_tempdir()
  l1 <- gas_b2025_l1(); l1[[1]]$G198 <- 0.125
  out <- gas_parse(build_gas_northvale_2025(dir, l1 = l1))
  r <- out$results[out$results$feature_raw == "N.G198", ]
  # Either it is not emitted as an ordinary result at all, or it is emitted
  # carrying its full precision for reconcile to route to review (see the e2e
  # test). What it must NEVER be is 0.12 or 0.13.
  expect_false(any(r$value_num %in% c(0.12, 0.13)))
  expect_false(any(r$value_raw %in% c("0.12", "0.13")))
  # Reachability: the rest of the sheet is untouched.
  expect_identical(gas_value_of(out, "N.G199"), 0.03)
})

# ==============================================================================
# 8 - text codes skipped with reasons; no sample
# ==============================================================================

test_that("8: each text code is skipped with its reason", {
  out <- gas_parse_fx("b2025")
  expect_true(all(c("source_ref", "reason") %in% names(out$report$skipped)))
  tab <- table(gas_reasons(out))
  expect_equal(as.integer(tab[["no_sample"]]), 2)      # G200, G308
  expect_equal(as.integer(tab[["point_absent"]]), 1)   # G201 `does not exist`
  expect_equal(as.integer(tab[["no_access"]]), 1)      # G224
  expect_equal(as.integer(tab[["not_requested"]]), 1)  # G369
  expect_equal(as.integer(tab[["not_on_map"]]), 1)     # G371
  expect_equal(sum(tab), 6)
  expect_false(anyNA(out$report$skipped$source_ref))
})

test_that("8: a text-coded point creates no result and no sample", {
  out <- gas_parse_fx("b2025")
  coded <- paste0("N.G", c(200, 201, 224, 308, 369, 371))
  expect_false(any(coded %in% out$results$feature_raw))
  expect_false(any(coded %in% out$samples$feature_raw))
  expect_false(any(grepl("NS|NR|Access|exist|map", out$results$value_raw)))
})

test_that("8: text codes match case- and whitespace-blind (`Does not exist`, `NS `)", {
  dir <- withr::local_tempdir()
  l1 <- gas_b2025_l1(); l1[[1]]$G201 <- "Does not exist"; l1[[1]]$G200 <- "NS "
  l1[[2]]$G224 <- "no access"
  out <- gas_parse(build_gas_northvale_2025(dir, l1 = l1))
  tab <- table(gas_reasons(out))
  expect_equal(as.integer(tab[["point_absent"]]), 1)
  expect_equal(as.integer(tab[["no_sample"]]), 2)
  expect_equal(as.integer(tab[["no_access"]]), 1)
  k <- gas_parse_fx("kat")                        # G263 = "NS " on the Millbrook #1 sheet
  # (plus the two numeric template slots G365/G366 - section 16)
  expect_identical(sort(gas_reasons(k)), c("no_sample", "template_slot", "template_slot"))
  expect_false("M.G263" %in% k$results$feature_raw)
})

test_that("8: the weekly sheet's NR-coded G382-G384 are skipped as not_requested", {
  out <- gas_parse_fx("weekly")
  tab <- table(gas_reasons(out))
  expect_equal(as.integer(tab[["not_requested"]]), 4)  # G369 + G382-G384
  expect_false(any(c("N.G382", "N.G383", "N.G384") %in% out$results$feature_raw))
})

# ==============================================================================
# 9 - zero is a non-detect (adapter half; the commit half is in the e2e file)
# ==============================================================================

test_that("9: a zero reading is emitted as value 0, flagged below detection", {
  out <- gas_parse_fx("b2025")
  z <- out$results[out$results$feature_raw == "N.G198", ]
  expect_equal(nrow(z), 1)
  expect_identical(z$value_raw, "0")
  expect_identical(z$value_num, 0)
  expect_true(z$below_detection)
  nz <- out$results[out$results$feature_raw == "N.G197", ]
  expect_false(nz$below_detection)
})

# ==============================================================================
# 10 - date from the serial; biofilter/bores note override; datetime NA
# ==============================================================================

test_that("10: every sample is dated by the front-page SAMPLE DATE serial, date only", {
  out <- gas_parse_fx("b2025")                    # SAMPLE DATE serial for 2025-07-22
  expect_true(all(out$samples$sample_datetime_raw == "22/07/2025"))
  expect_false(any(sampleTidy:::has_clock_time(out$samples$sample_datetime_raw)))
  expect_true(all(is.na(out$samples$sample_date_start_raw)))
  o21 <- gas_parse_fx("b2021")
  expect_true(all(o21$samples$sample_datetime_raw == "06/05/2021"))
})

test_that("10: the Millbrook `Biofilter and Bores sampled 5/1/26` note re-dates ONLY those rows", {
  dir <- withr::local_tempdir()
  out <- gas_parse(build_gas_millbrook(dir, sample_date = "2025-12-10",
                                      note = "Biofilter and Bores sampled 5/1/26"))
  s <- out$samples
  bio <- grepl("^M\\.(Biofilter North Corner|Front of Buildings) R|^M\\.MP_", s$feature_raw)
  expect_equal(sum(bio), 16)
  expect_true(all(s$sample_datetime_raw[bio] == "05/01/2026"))
  expect_true(all(s$sample_datetime_raw[!bio] == "10/12/2025"))
})

test_that("10: with no note, the biofilter and bores carry the front-page date", {
  out <- gas_parse_fx("kat")                      # sample_date 2025-12-10, no note
  expect_true(all(out$samples$sample_datetime_raw == "10/12/2025"))
})

# ==============================================================================
# 16 - ACIRL template slots N.G201 / M.G365 / M.G366 are never emitted
# ==============================================================================
#
# Robin, migrations 032 and 034 (MIGRATIONS.md rows 1032/1034): "Are they
# existing features in the database with known locations? If not, we don't
# want them." No probe at the REPORTING site carries those numbers - they are
# rows the ACIRL template prints (CH4 0) at a site that has no such probe. The
# same NUMBERS are real at the OTHER site (M.G201 at Millbrook, N.G365/N.G366 on
# the 2023 Northvale grid), so the skip is on the SITE-QUALIFIED name.
# Before this fix every import re-minted 3 pending aliases and their samples
# (2026-10-21 review, uf-other group 2: 22 samples + 22 CH4 0.0 readings).
#
# A NUMERIC slot reading is skipped with reason `template_slot` (one row in
# report$skipped, so the census still accounts for every cell). A slot cell
# that is already TEXT-coded keeps its text reason (Northvale G201 has read
# `does not exist` since May 2025 -> point_absent, section 8).

gas_template_slots <- c("N.G201", "M.G365", "M.G366")

test_that("16: a numeric N.G201 reading (Aug 2024 shape, CH4 0) yields no result and no sample", {
  dir <- withr::local_tempdir()
  l1 <- gas_b2025_l1(); l1[[1]]$G201 <- 0
  out <- gas_parse(build_gas_northvale_2025(dir, l1 = l1))
  expect_false("N.G201" %in% out$results$feature_raw)
  expect_false("N.G201" %in% out$samples$feature_raw)
  # its neighbours in the same column are untouched
  expect_setequal(out$results$feature_raw, gas_expected_b2025_monthly())
  expect_equal(nrow(out$results), 45)
  expect_equal(gas_value_of(out, "N.G197"), 0.01)
  expect_equal(gas_value_of(out, "N.G198"), 0)
})

test_that("16: the skipped N.G201 is recorded as `template_slot` with its cell reference", {
  dir <- withr::local_tempdir()
  l1 <- gas_b2025_l1(); l1[[1]]$G201 <- 0
  out <- gas_parse(build_gas_northvale_2025(dir, l1 = l1))
  sk <- out$report$skipped
  expect_equal(sum(sk$reason == "template_slot"), 1)
  # G201 is the 5th entry of pair 1: header row 7 + 5 = row 12, CH4 column B
  expect_identical(sk$source_ref[sk$reason == "template_slot"], "Gas Landfil #1!B12")
  # the other text codes keep their reasons and counts (section 8)
  tab <- table(gas_reasons(out))
  expect_equal(as.integer(tab[["no_sample"]]), 2)
  expect_false("point_absent" %in% names(tab))   # G201 is a number here, not `does not exist`
})

test_that("16: Millbrook M.G365 / M.G366 (CH4 0) yield no result and no sample; M.G362 beside them is kept", {
  out <- gas_parse_fx("kat")
  for (s in c("M.G365", "M.G366")) {
    expect_false(s %in% out$results$feature_raw, info = s)
    expect_false(s %in% out$samples$feature_raw, info = s)
  }
  expect_true("M.G362" %in% out$results$feature_raw)
  expect_equal(gas_value_of(out, "M.G362"), 0)
  expect_equal(nrow(out$samples), nrow(out$results))
  expect_equal(sum(gas_reasons(out) == "template_slot"), 2)
})

test_that("16: a NON-zero reading at a slot is still skipped (the rule is the slot, not the value)", {
  dir <- withr::local_tempdir()
  l2 <- gas_k_l2(); l2[[4]]$G365 <- 0.05
  out <- gas_parse(build_gas_millbrook(dir, l2 = l2))
  expect_false("M.G365" %in% out$results$feature_raw)
  expect_equal(sum(gas_reasons(out) == "template_slot"), 2)
})

test_that("16: the skip is site-qualified - M.G201 at Millbrook and N.G365/N.G366 at Northvale are real probes and are kept", {
  dir <- withr::local_tempdir()
  l1 <- gas_k_l1(); l1[[1]]$G201 <- 0.02
  k <- gas_parse(build_gas_millbrook(dir, l1 = l1))
  expect_true("M.G201" %in% k$results$feature_raw)
  expect_equal(gas_value_of(k, "M.G201"), 0.02)
  expect_true("M.G201" %in% k$samples$feature_raw)

  b <- gas_parse(build_gas_northvale_2025(dir, l2 = list(list(G365 = 0, G366 = 0.01)), l2_rows = 8:9))
  expect_true(all(c("N.G365", "N.G366") %in% b$results$feature_raw))
  expect_equal(gas_value_of(b, "N.G366"), 0.01)
  expect_false("template_slot" %in% gas_reasons(b))
})

test_that("16: no fixture family ever emits a template slot", {
  for (nm in names(fx)) {
    out <- gas_parse_fx(nm)
    expect_false(any(gas_template_slots %in% c(out$results$feature_raw, out$samples$feature_raw)),
                 info = nm)
  }
})
