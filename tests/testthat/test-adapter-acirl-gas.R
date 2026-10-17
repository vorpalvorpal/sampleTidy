# tests/testthat/test-adapter-acirl-gas.R
#
# TDD "red" tests for the ACIRL monthly-gas adapter `acirl_gas_xlsx`
# (dev/plans/PLAN-17-adapter-acirl-gas.md, "Tests first" 1-10 and 15, plus the
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
  b2025   = build_gas_blaxland_2025(gas_dir),
  b2026   = build_gas_blaxland_2025(gas_dir, report_no = "2400-9904-03-01",
                                    filename = "2400-9904-03-01 Mar 2026 Gas Monitoring Blaxland WMF.xlsx",
                                    shift = 1L),
  weekly  = build_gas_blaxland_2025(gas_dir, report_no = "2400-9905-05-01",
                                    filename = "2400-9905-05-01 Weekly Gas Monitoring Blaxland WMF.xlsx",
                                    weekly = TRUE),
  b2024   = build_gas_blaxland_2024(gas_dir),
  b2021   = build_gas_blaxland_2021(gas_dir),
  kat     = build_gas_katoomba(gas_dir)
)

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
  gx_front_blaxland(wb, "2400-9901-07-01", "2025-07-22")
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
  p <- file.path(dir, "2400-9901-07-01 Monthly Gas Monitoring Blaxland WMF.csv")
  writeLines("Location,CH4 Reading % v/v", p)
  expect_identical(gas_adapter()$match(sampleTidy:::file_meta(p)), "no")
})

# ==============================================================================
# IR contract + constants
# ==============================================================================

test_that("IR: output validates; analyte_raw `CH4 Reading % v/v`, units_raw `%`, org ACIRL, adapter tag", {
  for (nm in names(fx)) {
    out <- gas_parse(fx[[nm]])
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
    out <- gas_parse(fx[[nm]])
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
  a <- gas_parse(fx$kat)
  b <- gas_parse(fx$kat)
  expect_identical(a$results, b$results)
  expect_identical(a$samples, b$samples)
})

test_that("IR: report$campaign is `Monthly gas monitoring` (A80 filing)", {
  for (nm in names(fx)) {
    expect_identical(gas_parse(fx[[nm]])$report$campaign, "Monthly gas monitoring", info = nm)
  }
})

# ==============================================================================
# 2 - header-text block location
# ==============================================================================

test_that("2: Blaxland 2025 (header row 7, column offset 0) yields exactly the expected 45 probes", {
  out <- gas_parse(fx$b2025)
  expect_setequal(out$results$feature_raw, gas_expected_b2025_monthly())
  expect_equal(nrow(out$results), 45)
})

test_that("2: the Mar-2026 shape (#1/#2 one column right) parses identically to the unshifted one", {
  a <- gas_parse(fx$b2025)$results
  b <- gas_parse(fx$b2026)$results
  expect_setequal(b$feature_raw, gas_expected_b2025_monthly())
  a <- a[order(a$feature_raw), ]; b <- b[order(b$feature_raw), ]
  expect_identical(b$feature_raw, a$feature_raw)
  expect_identical(b$value_num, a$value_num)
})

test_that("2: Katoomba (header row 6, one column in, `CH4 Reading     % v/v`) yields all 52 readings", {
  out <- gas_parse(fx$kat)
  expect_setequal(out$results$feature_raw, gas_expected_katoomba())
  expect_equal(nrow(out$results), 52)
})

test_that("2: Blaxland 2021 (header row 11) yields its 40 readings", {
  out <- gas_parse(fx$b2021)
  expected <- c(paste0("B.G", c(1:3, 26:28, 51:53, 76:78)),
                paste0("B.G", c(101:106, 126:131, 151:156, 176:181)),
                "B.Toilets - Right Side", "B.Toilets - Left Side",
                "B.Lunch Room - Centre", "B.Main Office - Centre")
  expect_setequal(out$results$feature_raw, expected)
  expect_equal(nrow(out$results), 40)
})

test_that("2: Blaxland 2024 landfill (row 7) + `Gas Buildings ` (row 8) yield 31 readings", {
  out <- gas_parse(fx$b2024)
  expect_equal(nrow(out$results), 31)
  expect_equal(sum(grepl("^B\\.G[0-9]+$", out$results$feature_raw)), 23)
  expect_equal(sum(grepl(" - ", out$results$feature_raw)), 8)
})

test_that("2: a `#3` sheet of only 3 rows yields exactly B.G382-B.G384", {
  dir <- withr::local_tempdir()
  p <- build_gas_blaxland_2025(dir, l1 = list(list(G182 = 0)), l2 = list(list(G282 = 0)),
                               l2_rows = 8L)
  r <- gas_parse(p)$results
  expect_setequal(r$feature_raw, c("B.G182", "B.G282", "B.G382", "B.G383", "B.G384"))
  expect_equal(gas_value_of(list(results = r), "B.G383"), 0.01)
})

test_that("2: a wholly blank row INSIDE the grid does not end the block (Mar-2026 #2 row 27)", {
  r <- gas_parse(fx$b2025)$results
  # rows 14-15 of `Gas Landfil #2`, below the blank row 13, in every pair
  for (f in paste0("B.G", c(288, 289, 313, 314, 338, 339, 374, 375))) {
    expect_true(f %in% r$feature_raw, info = f)
  }
  expect_equal(gas_value_of(list(results = r), "B.G288"), 0.02)
})

test_that("2: each Location column pairs with ITS OWN CH4 column (values land on the right probe)", {
  out <- gas_parse(fx$b2025)
  expect_equal(gas_value_of(out, "B.G197"), 0.01)   # pair 1
  expect_equal(gas_value_of(out, "B.G223"), 0.02)   # pair 2
  expect_equal(gas_value_of(out, "B.G250"), 0.17)   # pair 3
  expect_equal(gas_value_of(out, "B.G276"), 0.04)   # pair 4
  expect_equal(gas_value_of(out, "B.G283"), 0.01)
  expect_equal(gas_value_of(out, "B.G372"), 0.01)
  k <- gas_parse(fx$kat)
  expect_equal(gas_value_of(k, "K.G187"), 0.01)
})

# ==============================================================================
# 3 - note rows and the 2021 coordinates table yield nothing
# ==============================================================================

test_that("3: `NS: ...` / `NR: ...` note rows yield no result, sample or skip", {
  out <- gas_parse(fx$weekly)
  expect_false(any(grepl("^(NS|NR):", out$results$value_raw)))
  expect_false(any(grepl("NS:|NR:|Unable|requested", out$results$feature_raw)))
  expect_false(any(grepl("NS:|NR:|Unable|requested", out$samples$feature_raw)))
  # exactly the 9 text-coded CELLS are skipped - the 2 note rows are not among them
  expect_equal(length(gas_reasons(out)), 9)
})

test_that("3: the 2021 `Note` row and its `G103 | Working Face` remark yield nothing", {
  out <- gas_parse(fx$b2021)
  expect_equal(sum(out$results$feature_raw == "B.G103"), 1)
  expect_identical(gas_value_of(out, "B.G103"), 0)
  expect_false(any(grepl("Working Face|^Note$", c(out$results$value_raw, out$results$feature_raw))))
  expect_equal(length(gas_reasons(out)), 0)
})

test_that("3: the 2021 `Additional Gas Point Coordinates` table yields nothing", {
  out <- gas_parse(fx$b2021)
  r <- out$results
  # one reading per G179-G181 (the data rows), none from the coordinates rows
  for (f in c("B.G179", "B.G180", "B.G181")) expect_equal(sum(r$feature_raw == f), 1, info = f)
  expect_true(all(r$value_num <= 1))   # no latitude/longitude/UTM value leaked in
  expect_false(any(grepl("Latitude|Longitude|UTM|Coordinates|56H",
                         c(r$feature_raw, r$value_raw, out$samples$feature_raw))))
  expect_equal(nrow(r), 40)
})

# ==============================================================================
# 4 - Location fill-down; duplicate references get `#2`
# ==============================================================================

test_that("4: building Location fills down over blank cells", {
  f <- gas_parse(fx$b2024)$results$feature_raw
  expect_true("B.Toilets - Right Side" %in% f)
  expect_true("B.Toilets - Left Side" %in% f)          # Location blank on this row
  expect_true("B.Weigh Bridge Building - Toilet" %in% f)
  expect_true("B.Storage Shed re used - Back Wall" %in% f)
  expect_true("B.Out side - Reused shed" %in% f)
  expect_false(any(grepl("^B\\. - |^B\\.NA - ", f)))
})

test_that("4: a reference repeated within ONE building gets `#2`", {
  f <- gas_parse(fx$b2024)$results$feature_raw
  expect_equal(sum(f == "B.Storage Shed re used - Right Wall"), 1)
  expect_equal(sum(f == "B.Storage Shed re used - Right Wall #2"), 1)
  k <- gas_parse(fx$kat)
  expect_equal(sum(k$results$feature_raw == "K.Re-use Center - Power point back wall #2"), 1)
  expect_equal(sum(k$results$feature_raw == "K.Meeting Room - Window wall 2 #2"), 1)
})

# A small Blaxland-2024-shaped workbook whose `Gas Buildings ` sheet holds
# `entries` (gx_entries(): loc, ref, val). Used to pin the `#n` suffix rule:
# the suffix follows the row's POSITION among same-reference rows in a
# building, whether or not the earlier rows carry a reading.
gas_suffix_parse <- function(entries) {
  d <- withr::local_tempdir(.local_envir = parent.frame())
  rn <- "2400-9902-08-01"
  wb <- openxlsx::createWorkbook()
  gx_front_blaxland(wb, rn, "2024-08-07", report_on = "August 2024 Gas Monitoring")
  gx_landfill_sheet(wb, "Gas Landfil #1", list(list(G182 = 0.01, G183 = 0, G184 = 0)),
                    report_no = rn)
  gx_building_sheet(wb, "Gas Buildings ", entries, header_row = 8L, report_no = rn,
                    titles = c("ALS COAL DIVISION", "BMCC BLAXLAND WASTE MANAGEMENT FACILITY",
                               "MONTHLY GAS  REPORT"))
  gx_map_sheet(wb)
  path <- gx_save(wb, d, paste0(rn, " August 2024 Monthly Gas Monitoring Blaxland WMF.xlsx"))
  gas_parse(path)
}
gas_suffix_bldg <- function(out) {
  f <- out$results$feature_raw
  f[grepl("^B\\.Shed - ", f)]
}

test_that("4: suffix is positional - a BLANK first occurrence still leaves the second as `#2`", {
  out <- gas_suffix_parse(gx_entries(
    list("Shed", "Wall", NA_real_),
    list(NA, "Wall", 0.01),
    list(NA, "Door", 0)
  ))
  f <- gas_suffix_bldg(out)
  expect_setequal(f, c("B.Shed - Wall #2", "B.Shed - Door"))
  expect_equal(gas_value_of(out, "B.Shed - Wall #2"), 0.01)
})

test_that("4: suffix is positional - an `NS` first occurrence still leaves the second as `#2`", {
  out <- gas_suffix_parse(gx_entries(
    list("Shed", "Wall", "NS"),
    list(NA, "Wall", 0.01)
  ))
  expect_setequal(gas_suffix_bldg(out), "B.Shed - Wall #2")
  expect_equal(gas_value_of(out, "B.Shed - Wall #2"), 0.01)
})

test_that("4: suffix is positional - NR and other skipped text in an earlier occurrence count too", {
  out <- gas_suffix_parse(gx_entries(
    list("Shed", "Wall", "NR"),
    list(NA, "Wall", "No Access"),
    list(NA, "Wall", 0.02)
  ))
  expect_setequal(gas_suffix_bldg(out), "B.Shed - Wall #3")
})

test_that("4: three occurrences with the MIDDLE one blank give no suffix, then `#3`", {
  out <- gas_suffix_parse(gx_entries(
    list("Shed", "Wall", 0.01),
    list(NA, "Wall", NA_real_),
    list(NA, "Wall", 0.03)
  ))
  expect_setequal(gas_suffix_bldg(out), c("B.Shed - Wall", "B.Shed - Wall #3"))
  expect_equal(gas_value_of(out, "B.Shed - Wall"), 0.01)
  expect_equal(gas_value_of(out, "B.Shed - Wall #3"), 0.03)
})

test_that("4: regression - fully populated repeats are still unsuffixed / `#2` / `#3`", {
  out <- gas_suffix_parse(gx_entries(
    list("Shed", "Wall", 0.01),
    list(NA, "Wall", 0.02),
    list(NA, "Wall", 0.03),
    list("Other", "Wall", 0.04)
  ))
  expect_setequal(c(gas_suffix_bldg(out), grep("^B\\.Other", out$results$feature_raw, value = TRUE)),
                  c("B.Shed - Wall", "B.Shed - Wall #2", "B.Shed - Wall #3", "B.Other - Wall"))
  expect_equal(gas_value_of(out, "B.Shed - Wall #2"), 0.02)
  expect_equal(gas_value_of(out, "B.Shed - Wall #3"), 0.03)
})

test_that("4: the same reference in two DIFFERENT buildings is not suffixed", {
  f <- gas_parse(fx$kat)$results$feature_raw
  expect_true("K.Office - Air conditioner" %in% f)
  expect_true("K.Meal Room - Air conditioner" %in% f)
  expect_false(any(grepl("Air conditioner #", f)))
})

test_that("4: feature_raw is unique within every file (A84 refuses repeats)", {
  for (nm in names(fx)) {
    f <- gas_parse(fx[[nm]])$results$feature_raw
    expect_false(anyDuplicated(f) > 0, info = paste(nm, paste(f[duplicated(f)], collapse = ", ")))
  }
})

test_that("4: runs of whitespace inside a building Location are squished", {
  f <- gas_parse(fx$kat)$results$feature_raw
  expect_true("K.Main Recycle area (Drop Off) - Power point near hose reel" %in% f)
  expect_false(any(grepl("  ", f)))
})

# ==============================================================================
# 5 - site from content, never the filename; naming rulings
# ==============================================================================

test_that("5: probes are site-qualified from content - B.G182 at Blaxland, K.G186 at Katoomba", {
  expect_true("B.G182" %in% gas_parse(fx$b2024)$results$feature_raw)
  expect_true("K.G186" %in% gas_parse(fx$kat)$results$feature_raw)
})

test_that("5: B and K never cross - every feature in a file carries that file's site", {
  for (nm in c("b2025", "b2026", "weekly", "b2024", "b2021")) {
    out <- gas_parse(fx[[nm]])
    expect_true(all(startsWith(c(out$results$feature_raw, out$samples$feature_raw), "B.")), info = nm)
  }
  out <- gas_parse(fx$kat)
  expect_true(all(startsWith(c(out$results$feature_raw, out$samples$feature_raw), "K.")))
})

test_that("5: Katoomba content in a file NAMED Blaxland is Katoomba (and the reverse)", {
  dir <- withr::local_tempdir()
  k <- gas_parse(build_gas_katoomba(dir, filename = "2400-9903-12-01 December 2025 Gas Monitoring Blaxland WMF.xlsx"))
  expect_true(all(startsWith(k$results$feature_raw, "K.")))
  expect_true("K.G186" %in% k$results$feature_raw)
  b <- gas_parse(build_gas_blaxland_2025(dir, filename = "2400-9901-07-01 July 2025 Gas Monitoring Katoomba WMF.xlsx"))
  expect_true(all(startsWith(b$results$feature_raw, "B.")))
  # and a filename naming no site at all changes nothing
  n <- gas_parse(build_gas_katoomba(dir, filename = "gas.xlsx"))
  expect_setequal(n$results$feature_raw, gas_expected_katoomba())
})

test_that("5: a workbook whose content names neither site is refused, never guessed", {
  dir <- withr::local_tempdir()
  p <- build_gas_katoomba(dir, filename = "2400-9903-12-01 Katoomba WMF.xlsx",
                          front_title = "BMCC Gas Sampling", front_address = "1 Test Rd",
                          sheet_titles = c("ALS Coal Division", "BMCC Gas Sampling"))
  expect_error(gas_parse(p), class = "sampletidy_parse_error")
})

test_that("5: probe numbers are emitted verbatim - `B.G1`, not `B.G001` (the resolver pads)", {
  f <- gas_parse(fx$b2021)$results$feature_raw
  expect_true("B.G1" %in% f)
  expect_false("B.G001" %in% f)
})

test_that("5: G368-G384 on a landfill sheet emit `B.G368`..., never a building-style name", {
  out <- gas_parse(fx$b2025)
  f <- out$results$feature_raw
  for (g in c("B.G368", "B.G370", "B.G372", "B.G374", "B.G375", "B.G382", "B.G383", "B.G384")) {
    expect_true(g %in% f, info = g)
  }
  expect_false(any(grepl(" - ", f)))              # no `{Location} - {Reference}` on a landfill-only file
  expect_false(any(grepl("Gatehouse|Demountables|Reuse shed", f, ignore.case = TRUE)))
})

test_that("5: G179-G181 emit B.G179-B.G181 (the registry aliases them to B.TG179-181, not the adapter)", {
  f <- gas_parse(fx$b2021)$results$feature_raw
  expect_true(all(c("B.G179", "B.G180", "B.G181") %in% f))
  expect_false(any(grepl("TG", f)))
})

test_that("5: Katoomba bores emit K.MP_1..K.MP_4 (the registry's MP_n alias form), not a building name", {
  out <- gas_parse(fx$kat)
  f <- out$results$feature_raw
  expect_true(all(paste0("K.MP_", 1:4) %in% f))
  expect_false(any(grepl("Gas Bore", f)))
  expect_equal(gas_value_of(out, "K.MP_3"), 0.01)
})

test_that("5: Blaxland weekly points 1-21 emit `B.Weekly 1` ... `B.Weekly 21`", {
  out <- gas_parse(fx$weekly)
  f <- out$results$feature_raw
  expect_true(all(paste("B.Weekly", 1:21) %in% f))
  expect_false(any(f %in% paste0("B.", 1:21)))
  expect_false(any(f %in% paste0("B.G", 1:21)))
  expect_equal(gas_value_of(out, "B.Weekly 1"), 0.07)
  expect_equal(gas_value_of(out, "B.Weekly 11"), 0.18)
  expect_equal(gas_value_of(out, "B.Weekly 15"), 0.22)
  expect_equal(nrow(out$results), 63)
})

test_that("5: Katoomba biofilter grids emit labelled R<r>C<c> names, row-major as laid out", {
  out <- gas_parse(fx$kat)
  g <- out$results[grepl("^K\\.(Biofilter North Corner|Front of Buildings) R[12]C[123]$",
                         out$results$feature_raw), ]
  expect_equal(nrow(g), 12)
  expect_equal(gas_value_of(out, "K.Biofilter North Corner R1C2"), 0.01)
  expect_equal(gas_value_of(out, "K.Biofilter North Corner R2C3"), 0.02)
  expect_equal(gas_value_of(out, "K.Front of Buildings R2C1"), 0.03)
  zeros <- setdiff(g$feature_raw, c("K.Biofilter North Corner R1C2", "K.Biofilter North Corner R2C3",
                                    "K.Front of Buildings R2C1"))
  expect_true(all(g$value_num[g$feature_raw %in% zeros] == 0))
})

test_that("5: UNLABELLED grids default to North Corner first, Front of Buildings second", {
  dir <- withr::local_tempdir()
  out <- gas_parse(build_gas_katoomba(dir, grid_labels = FALSE))
  expect_setequal(out$results$feature_raw, gas_expected_katoomba())
  expect_equal(gas_value_of(out, "K.Biofilter North Corner R1C2"), 0.01)
  expect_equal(gas_value_of(out, "K.Front of Buildings R2C1"), 0.03)
})

# ==============================================================================
# 6 - REPORT NO from the cell; filename mismatch recorded
# ==============================================================================

test_that("6: work_order is the front-page REPORT NO cell, not the filename token", {
  dir <- withr::local_tempdir()
  p <- build_gas_blaxland_2025(dir, report_no = "2400-9901-07-01",
                               filename = "2400-9901-07 July 2025 Monthly Gas Monitoring Blaxland WMF.xlsx")
  out <- gas_parse(p)
  expect_identical(out$report$header$report_no, "2400-9901-07-01")
  expect_true(all(out$results$work_order == "2400-9901-07-01"))
  expect_true(all(out$samples$work_order == "2400-9901-07-01"))
})

test_that("6: the filename token is kept on the report, and a mismatch with the cell is recorded", {
  dir <- withr::local_tempdir()
  p <- build_gas_blaxland_2025(dir, report_no = "2400-9901-07-01",
                               filename = "2400-9901-07 July 2025 Monthly Gas Monitoring Blaxland WMF.xlsx")
  out <- gas_parse(p)
  expect_identical(out$report$filename_report_no, "2400-9901-07")
  w <- out$report$warnings
  expect_true(any(grepl("2400-9901-07-01", w, fixed = TRUE) & grepl("2400-9901-07 ", paste0(w, " "), fixed = TRUE)))
})

test_that("6: a filename that AGREES with the cell records no mismatch", {
  out <- gas_parse(fx$b2025)                  # "2400-9901-07-01 July 2025 ..." / cell 2400-9901-07-01
  expect_identical(out$report$filename_report_no, "2400-9901-07-01")
  expect_false(any(grepl("mismatch|disagree|differ", out$report$warnings, ignore.case = TRUE)))
})

test_that("6: `24009902 - 05 Amended` files as `24009902-05`, with `Amended` kept in comments", {
  out <- gas_parse(fx$b2021)
  expect_identical(out$report$header$report_no, "24009902-05")
  expect_true(all(out$results$work_order == "24009902-05"))
  s <- out$samples; r <- out$results
  m <- match(r$lab_sample_id, s$lab_sample_id)
  amended <- grepl("Amended", s$comments[m]) | grepl("Amended", r$comments)
  expect_true(all(amended))
})

test_that("6: whitespace inside the REPORT NO cell is normalised", {
  dir <- withr::local_tempdir()
  p <- build_gas_blaxland_2025(dir, report_no = "2400-9901-07-01",
                               front_report_no = "  2400-9901-07-01  ")
  expect_identical(gas_parse(p)$report$header$report_no, "2400-9901-07-01")
})

test_that("6: sampler comes from SAMPLED BY (first name, `& ...` stripped), like the field adapter", {
  out <- gas_parse(fx$b2025)
  expect_true(all(out$samples$sampler == "J. Tester"))
})

# ==============================================================================
# 7 - rounding to 2 dp; more precision -> review
# ==============================================================================

test_that("7: binary-noise readings round to 2 dp - `0.0299999999999999` -> 0.03", {
  out <- gas_parse(fx$b2025)
  r <- out$results[out$results$feature_raw == "B.G199", ]
  expect_equal(nrow(r), 1)
  expect_identical(r$value_num, 0.03)
  expect_identical(r$value_raw, "0.03")
  b <- gas_parse(fx$b2024)
  expect_identical(gas_value_of(b, "B.Out side - Reused shed"), 0.03)
})

test_that("7: every emitted value_raw carries at most 2 decimals and parses to value_num", {
  for (nm in names(fx)) {
    r <- gas_parse(fx[[nm]])$results
    expect_true(all(grepl("^[0-9]+(\\.[0-9]{1,2})?$", r$value_raw)),
                info = paste(nm, paste(head(r$value_raw[!grepl("^[0-9]+(\\.[0-9]{1,2})?$", r$value_raw)]), collapse = ", ")))
    expect_identical(as.numeric(r$value_raw), r$value_num, info = nm)
  }
})

test_that("7: a reading with GENUINE >2 dp precision is never silently rounded", {
  dir <- withr::local_tempdir()
  l1 <- gas_b2025_l1(); l1[[1]]$G198 <- 0.125
  out <- gas_parse(build_gas_blaxland_2025(dir, l1 = l1))
  r <- out$results[out$results$feature_raw == "B.G198", ]
  # Either it is not emitted as an ordinary result at all, or it is emitted
  # carrying its full precision for reconcile to route to review (see the e2e
  # test). What it must NEVER be is 0.12 or 0.13.
  expect_false(any(r$value_num %in% c(0.12, 0.13)))
  expect_false(any(r$value_raw %in% c("0.12", "0.13")))
  # Reachability: the rest of the sheet is untouched.
  expect_identical(gas_value_of(out, "B.G199"), 0.03)
})

# ==============================================================================
# 8 - text codes skipped with reasons; no sample
# ==============================================================================

test_that("8: each text code is skipped with its reason", {
  out <- gas_parse(fx$b2025)
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
  out <- gas_parse(fx$b2025)
  coded <- paste0("B.G", c(200, 201, 224, 308, 369, 371))
  expect_false(any(coded %in% out$results$feature_raw))
  expect_false(any(coded %in% out$samples$feature_raw))
  expect_false(any(grepl("NS|NR|Access|exist|map", out$results$value_raw)))
})

test_that("8: text codes match case- and whitespace-blind (`Does not exist`, `NS `)", {
  dir <- withr::local_tempdir()
  l1 <- gas_b2025_l1(); l1[[1]]$G201 <- "Does not exist"; l1[[1]]$G200 <- "NS "
  l1[[2]]$G224 <- "no access"
  out <- gas_parse(build_gas_blaxland_2025(dir, l1 = l1))
  tab <- table(gas_reasons(out))
  expect_equal(as.integer(tab[["point_absent"]]), 1)
  expect_equal(as.integer(tab[["no_sample"]]), 2)
  expect_equal(as.integer(tab[["no_access"]]), 1)
  k <- gas_parse(fx$kat)                        # G263 = "NS " on the Katoomba #1 sheet
  expect_identical(gas_reasons(k), "no_sample")
  expect_false("K.G263" %in% k$results$feature_raw)
})

test_that("8: the weekly sheet's NR-coded G382-G384 are skipped as not_requested", {
  out <- gas_parse(fx$weekly)
  tab <- table(gas_reasons(out))
  expect_equal(as.integer(tab[["not_requested"]]), 4)  # G369 + G382-G384
  expect_false(any(c("B.G382", "B.G383", "B.G384") %in% out$results$feature_raw))
})

# ==============================================================================
# 9 - zero is a non-detect (adapter half; the commit half is in the e2e file)
# ==============================================================================

test_that("9: a zero reading is emitted as value 0, flagged below detection", {
  out <- gas_parse(fx$b2025)
  z <- out$results[out$results$feature_raw == "B.G198", ]
  expect_equal(nrow(z), 1)
  expect_identical(z$value_raw, "0")
  expect_identical(z$value_num, 0)
  expect_true(z$below_detection)
  nz <- out$results[out$results$feature_raw == "B.G197", ]
  expect_false(nz$below_detection)
})

# ==============================================================================
# 10 - date from the serial; biofilter/bores note override; datetime NA
# ==============================================================================

test_that("10: every sample is dated by the front-page SAMPLE DATE serial, date only", {
  out <- gas_parse(fx$b2025)                    # SAMPLE DATE serial for 2025-07-22
  expect_true(all(out$samples$sample_datetime_raw == "22/07/2025"))
  expect_false(any(sampleTidy:::has_clock_time(out$samples$sample_datetime_raw)))
  expect_true(all(is.na(out$samples$sample_date_start_raw)))
  o21 <- gas_parse(fx$b2021)
  expect_true(all(o21$samples$sample_datetime_raw == "06/05/2021"))
})

test_that("10: the Katoomba `Biofilter and Bores sampled 5/1/26` note re-dates ONLY those rows", {
  dir <- withr::local_tempdir()
  out <- gas_parse(build_gas_katoomba(dir, sample_date = "2025-12-10",
                                      note = "Biofilter and Bores sampled 5/1/26"))
  s <- out$samples
  bio <- grepl("^K\\.(Biofilter North Corner|Front of Buildings) R|^K\\.MP_", s$feature_raw)
  expect_equal(sum(bio), 16)
  expect_true(all(s$sample_datetime_raw[bio] == "05/01/2026"))
  expect_true(all(s$sample_datetime_raw[!bio] == "10/12/2025"))
})

test_that("10: with no note, the biofilter and bores carry the front-page date", {
  out <- gas_parse(fx$kat)                      # sample_date 2025-12-10, no note
  expect_true(all(out$samples$sample_datetime_raw == "10/12/2025"))
})

# ==============================================================================
# 15 - gated real-corpus census (A3: real data is never committed)
# ==============================================================================
#
# Opt-in: SAMPLETIDY_GAS_CORPUS = a directory holding the 16 real
# "... Gas Monitoring ... .xls" workbooks (searched recursively), e.g.
# `.../waste_data - Environmental monitoring/assets/unprocessed`. A separate
# variable from SAMPLETIDY_CORPUS because the gas workbooks sit in the
# Sharepoint `unprocessed` tree, not the input corpus.
#
# Expected counts measured 2026-10-16 (read-only census, scratchpad
# gastw/census3.R): numeric CH4 readings per file, and text-coded cells per
# file. Totals 3,293 readings; 329 text cells = NS 262, NR 31, No Access 24,
# `does/Does not exist` 10, `Not on the map` 2.

gas_corpus_census <- tibble::tribble(
  ~file,                                                                    ~n_results, ~n_skipped,
  "2400-7127-05 May 2021 Monthly Gas Monitoring Blaxland WMF.XLS",               196,  0,
  "2400-7399-08-01 August 2024 Monthly Gas Monitoring Blaxland WMF.xls",         202,  1,
  "2400-7453-03-01 Mar 2026 Gas Monitoring Blaxland WMF.xls",                    120, 83,
  "2400-7453-05-01 May 2025 Monthly Gas Monitoring Blaxland WMF.xls",            202,  1,
  "2400-7453-07-01 July 2025 Monthly Gas Monitoring Blaxland WMF.xls",           202,  1,
  "2400-7453-10-01 October 2025 Monthly Gas Monitoring Blaxland WMF.xls",        202,  1,
  "2400-7453-11 November 2025 Monthly Gas Monitoring Blaxland WMF.xls",          202,  1,
  "2400-7454-06-01 June 2025 Gas Monitoring Katoomba WMF.xls",                   291,  0,
  "2400-7454-09-01 September 2025 Gas Monitoring Katoomba WMF.xls",              291,  0,
  "2400-7454-12-01 December 2025 Gas Monitoring Katoomba WMF.xls",               291,  0,
  "2400-7538-02-01 Monthly Gas Monitoring Blaxland WMF.xls",                     164, 26,
  "2400-7538-04-01 Monthly Gas Monitoring Blaxland WMF.xls",                      84, 119,
  "2400-7538-05 Monthly Gas Monitoring Blaxland WMF.xls",                        141, 62,
  "2400-7538-05-01 Weekly Gas Monitoring Blaxland WMF.xls",                      205, 19,
  "2400-7538-05-03 Weekly Gas Monitoring Blaxland WMF.xls",                      209, 15,
  "2400-7593-03-01 March 2026 Gas Monitoring Katoomba WMF.xls",                  291,  0
)

skip_if_no_gas_corpus <- function() {
  path <- Sys.getenv("SAMPLETIDY_GAS_CORPUS", unset = "")
  if (identical(path, "") || !dir.exists(path)) {
    testthat::skip("SAMPLETIDY_GAS_CORPUS not set to an existing directory (A3) - real gas-corpus test skipped")
  }
  path
}

gas_corpus_files <- function(root) {
  fs <- list.files(root, pattern = "(?i)gas monitoring.*\\.xls$", recursive = TRUE, full.names = TRUE)
  fs[basename(fs) %in% gas_corpus_census$file]
}

test_that("15 (gated): every real gas workbook is claimed by the gas adapter alone, at `format`", {
  root <- skip_if_no_gas_corpus()
  use_builtin_adapters()
  paths <- gas_corpus_files(root)
  expect_setequal(basename(paths), gas_corpus_census$file)
  gas_adapter()
  reg <- sampleTidy:::adapter_registry()
  for (p in paths) {
    fm <- sampleTidy:::file_meta(p)
    tiers <- vapply(reg, function(a) a$match(fm), character(1))
    expect_identical(tiers[["acirl_gas_xlsx"]], "format", info = basename(p))
    expect_true(all(tiers[names(tiers) != "acirl_gas_xlsx"] == "no"), info = basename(p))
  }
})

test_that("15 (gated): per-file result and skip counts match the measured census", {
  root <- skip_if_no_gas_corpus()
  paths <- gas_corpus_files(root)
  expect_equal(length(paths), nrow(gas_corpus_census))
  all_reasons <- character(0)
  for (p in paths) {
    want <- gas_corpus_census[gas_corpus_census$file == basename(p), ]
    out <- gas_parse(p)
    expect_no_error(sampleTidy:::ir_validate(out$results, "results"))
    expect_equal(nrow(out$results), want$n_results, info = basename(p))
    expect_equal(nrow(out$samples), want$n_results, info = basename(p))
    expect_equal(length(gas_reasons(out)), want$n_skipped, info = basename(p))
    f <- out$results$feature_raw
    expect_false(anyDuplicated(f) > 0, info = basename(p))
    site <- if (grepl("Katoomba", basename(p))) "K." else "B."
    expect_true(all(startsWith(f, site)), info = basename(p))
    expect_true(all(grepl("^[0-9]+(\\.[0-9]{1,2})?$", out$results$value_raw)), info = basename(p))
    all_reasons <- c(all_reasons, gas_reasons(out))
  }
  tab <- table(all_reasons)
  expect_equal(as.integer(tab[["no_sample"]]), 262)
  expect_equal(as.integer(tab[["not_requested"]]), 31)
  expect_equal(as.integer(tab[["no_access"]]), 24)
  expect_equal(as.integer(tab[["point_absent"]]), 10)
  expect_equal(as.integer(tab[["not_on_map"]]), 2)
})

test_that("15 (gated): REPORT NO is read from the cell for every real workbook", {
  root <- skip_if_no_gas_corpus()
  paths <- gas_corpus_files(root)
  rn <- vapply(paths, function(p) gas_parse(p)$report$header$report_no, character(1))
  names(rn) <- basename(paths)
  expect_identical(rn[["2400-7127-05 May 2021 Monthly Gas Monitoring Blaxland WMF.XLS"]], "24007127-05")
  # the filename says 2400-7538-05, the cell says -01
  expect_identical(rn[["2400-7538-05 Monthly Gas Monitoring Blaxland WMF.xls"]], "2400-7538-05-01")
  expect_identical(rn[["2400-7453-11 November 2025 Monthly Gas Monitoring Blaxland WMF.xls"]], "2400-7453-11")
})
