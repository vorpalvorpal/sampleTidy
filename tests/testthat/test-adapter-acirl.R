# tests/testthat/test-adapter-acirl.R
#
# TDD "red" tests for R/adapter-acirl-field.R (plan 06: `acirl_field_xlsx`).
# R/adapter-acirl-field.R does not exist yet, so every test below is expected
# to fail (missing function/object) until plan 06 lands. See
# dev/plans/PLAN-06-adapter-acirl-field.md and dev/plans/FIXTURES.md for the
# pinned contract, and tests/testthat/fixtures/acirl/README.md for the
# fixture layout decisions (transposed block, column positions, edge cases).
#
# Adapter accessor: as in the other adapter test files, we use the registry
# route pending adjudication (dev/plans/PLAN-CHANGE-REQUESTS.md).

acirl_adapter <- function() sampleTidy:::adapter_registry()[["acirl_field_xlsx"]]

main_path       <- test_path("fixtures", "acirl", "2400-9999-01_Test_WMF.xlsx")
edge_path       <- test_path("fixtures", "acirl", "EDGECASES.xlsx")
no_report_path  <- test_path("fixtures", "acirl", "NO_REPORT_NO.xlsx")
random_xlsx_path <- test_path("fixtures", "acirl", "random.xlsx")
# Real-geometry fixtures (R-6.3a) - see fixtures/acirl/README-real-geometry.md
real_path       <- test_path("fixtures", "acirl", "2400-9999-11_Real_WMF.xlsx")
dustonly_path   <- test_path("fixtures", "acirl", "2400-9999-12_DustOnly_WMF.xlsx")
alsrefs_path    <- test_path("fixtures", "acirl", "2400-9999-13_AlsRefs_WMF.xlsx")
dustconflict_path <- test_path("fixtures", "acirl", "2400-9999-14_DustDateConflict_WMF.xlsx")
xtab_xlsx_path  <- test_path("fixtures", "crosstab", "XX1234567_0_XTAB.xlsx")

fake_als_labels <- c("Fluoride", "Sulphate", "Total Dissolved Solids", "Alkalinity")

# ---- R-6.1 match() ------------------------------------------------------------

test_that("R-6.1: main ACIRL workbook matches format", {
  meta <- sampleTidy:::file_meta(main_path)
  expect_identical(acirl_adapter()$match(meta), "format")
})

test_that("R-6.1: a random xlsx matches no", {
  meta <- sampleTidy:::file_meta(random_xlsx_path)
  expect_identical(acirl_adapter()$match(meta), "no")
})

test_that("R-6.1: the plan-05 XTAB xlsx crosstab fixture matches no", {
  meta <- sampleTidy:::file_meta(xtab_xlsx_path)
  expect_identical(acirl_adapter()$match(meta), "no")
})

# ---- R-6.2 front page ----------------------------------------------------------

test_that("R-6.2: front page yields REPORT NO / SAMPLED BY (stripped) / SAMPLE DATE", {
  meta <- sampleTidy:::file_meta(main_path)
  out <- acirl_adapter()$parse(main_path, meta)
  h <- out$report$header
  expect_identical(h$report_no, "2400-9999-01")
  expect_identical(h$sampled_by, "J. Tester")   # "& offsider" stripped, squished
  expect_identical(h$sample_date, "24/05/2025")
})

test_that("R-6.2: missing REPORT NO: continues parsing with a warning, work_order NA", {
  meta <- sampleTidy:::file_meta(no_report_path)
  out <- acirl_adapter()$parse(no_report_path, meta)
  expect_true(is.na(out$report$header$report_no))
  expect_true(length(out$report$warnings) >= 1)
  expect_true(any(grepl("REPORT NO", out$report$warnings, ignore.case = TRUE)))
  expect_true(nrow(out$results) >= 1)
  expect_true(all(is.na(out$results$work_order)))
})

test_that("R-6.2: get_key() single/zero/duplicate-match front-page grids", {
  make_grid <- function(v1, v2) {
    as.data.frame(list(V1 = v1, V2 = v2), stringsAsFactors = FALSE)
  }

  # exactly one match: normal value extraction.
  single_grid <- make_grid(
    c("REPORT NO:", "SAMPLED BY:", "SAMPLE DATE:"),
    c("2400-9999-01", "J. Tester", "24/05/2025")
  )
  out_single <- sampleTidy:::.st_acirl_parse_front_page(single_grid)
  expect_identical(out_single$header$report_no, "2400-9999-01")
  expect_length(out_single$warnings, 0)

  # zero matches: NA + "not found" warning, no throw.
  missing_grid <- make_grid(
    c("SAMPLED BY:", "SAMPLE DATE:"),
    c("J. Tester", "24/05/2025")
  )
  out_missing <- sampleTidy:::.st_acirl_parse_front_page(missing_grid)
  expect_true(is.na(out_missing$header$report_no))
  expect_true(any(grepl("REPORT NO.*not found", out_missing$warnings, ignore.case = TRUE)))

  # duplicate matches (two "REPORT NO:" cells): must NOT throw; NA + an
  # "ambiguous" warning, same tolerance treatment as the missing-key case.
  dup_grid <- make_grid(
    c("REPORT NO:", "REPORT NO:", "SAMPLE DATE:"),
    c("2400-9999-01", "2400-8888-02", "24/05/2025")
  )
  expect_no_error(out_dup <- sampleTidy:::.st_acirl_parse_front_page(dup_grid))
  expect_true(is.na(out_dup$header$report_no))
  expect_true(any(grepl("REPORT NO.*multiple.*ambiguous", out_dup$warnings, ignore.case = TRUE)))
})

# ---- R-6.3 water sheets -> ir_results + ir_samples ------------------------------

test_that("R-6.3: every fake ALS row is dropped - zero fake lab values appear in results", {
  meta <- sampleTidy:::file_meta(main_path)
  out <- acirl_adapter()$parse(main_path, meta)
  expect_false(any(out$results$analyte_raw %in% fake_als_labels))
  dropped <- out$report$skipped[out$report$skipped$reason == "lab_data_dropped", ]
  expect_equal(nrow(dropped), 32)  # 4 fake rows x 4 sample cols x 2 water sheets
})

test_that("R-6.3: results = features x visits x 3 field analytes minus the one empty cell", {
  meta <- sampleTidy:::file_meta(main_path)
  out <- acirl_adapter()$parse(main_path, meta)
  # 2 features x 2 visits x 3 analytes x 2 sheets = 24, minus 1 genuinely
  # empty Temperature cell (Field Data 1, T.S02 @ 25 May) = 23, plus the one
  # qualitative Appearance row A76 now splits out of this fixture's single
  # parseable Comments cell ("Clear") = 24.
  expect_equal(nrow(out$results), 24)
  expect_true(all(out$results$analyte_raw %in% c("pH", "EC", "Temperature", "Comments")))
  expect_equal(sum(out$results$analyte_raw == "Comments"), 1)
  empty_skips <- out$report$skipped[out$report$skipped$reason == "empty", ]
  expect_equal(nrow(empty_skips), 1)
})

test_that("R-6.3: EC mojibake unit variant and Temperature 'oC' both normalise correctly", {
  meta <- sampleTidy:::file_meta(main_path)
  out <- acirl_adapter()$parse(main_path, meta)
  ec_rows <- out$results[out$results$analyte_raw == "EC", ]
  expect_true(nrow(ec_rows) > 0)
  expect_true(all(ec_rows$units_raw == "µS/cm"))  # both clean and mojibake sheets normalise the same

  temp_rows <- out$results[out$results$analyte_raw == "Temperature", ]
  expect_true(nrow(temp_rows) > 0)
  expect_true(all(temp_rows$units_raw == "°C"))   # 'oC' repaired to the real degree sign
})

# NOTE (orchestrator fix): date fill-down is a `samples`-level property -
# `sample_datetime_raw` is a samples-only IR column (R/ir.R), not on `results`.
# The original test read `out$results$sample_datetime_raw` (always NULL), a
# copy-paste slip from the results-based tests; test 10 below already asserts
# the same per-visit fill-down correctly via `out$samples`. Retargeted to
# `out$samples` per [NO SILENT DEVIATION] (trivial test bug, fixed with a note).
test_that("R-6.3: date fill-down - second-visit rows carry the second date (25/05/2025)", {
  meta <- sampleTidy:::file_meta(main_path)
  out <- acirl_adapter()$parse(main_path, meta)
  visit1 <- out$samples[out$samples$sample_datetime_raw == "24/05/2025", ]
  visit2 <- out$samples[out$samples$sample_datetime_raw == "25/05/2025", ]
  expect_true(nrow(visit1) > 0)
  expect_true(nrow(visit2) > 0)
  expect_equal(nrow(visit1) + nrow(visit2), nrow(out$samples))
})

# CHANGED 2026-08-01 (A76, Robin): an observation is a qualitative RESULT as
# well as a note. The raw text still reaches the sample - it is the only home
# for the observations that describe no water at all - but a recognised
# appearance/stage term now ALSO produces an analysis row. The original
# `expect_false(any(analyte_raw == "Comments"))` pinned exactly the behaviour
# the ruling reverses, so it is inverted here rather than deleted.
test_that("R-6.3/A76: Comments cell text lands on the sample AND as a qualitative result", {
  meta <- sampleTidy:::file_meta(main_path)
  out <- acirl_adapter()$parse(main_path, meta)
  appearance <- out$results[out$results$analyte_raw == "Comments", ]
  expect_equal(nrow(appearance), 1)
  expect_identical(appearance$value_chr, "Clear")
  expect_identical(appearance$feature_raw, "T.S01")
  # "Slight turbidity", "Odour noted" and "Duplicate sample" carry no term in
  # the measured vocabulary, so they stay comments-only - no invented result.
  expect_equal(nrow(out$results), 24)

  clear_row <- out$samples[!is.na(out$samples$comments) & out$samples$comments == "Clear", ]
  expect_equal(nrow(clear_row), 1)
  expect_identical(clear_row$feature_raw, "T.S01")
  expect_identical(clear_row$sample_datetime_raw, "24/05/2025")

  turbid_row <- out$samples[!is.na(out$samples$comments) &
                               out$samples$comments == "Slight turbidity", ]
  expect_equal(nrow(turbid_row), 1)
  expect_identical(turbid_row$feature_raw, "T.S01")
  expect_identical(turbid_row$sample_datetime_raw, "25/05/2025")
})

test_that("R-6.3: sampler is recorded from the front page on water-sheet samples", {
  meta <- sampleTidy:::file_meta(main_path)
  out <- acirl_adapter()$parse(main_path, meta)
  expect_true(all(out$samples$sampler == "J. Tester"))
})

test_that("R-6.3: ir_validate() passes on the main workbook's output", {
  meta <- sampleTidy:::file_meta(main_path)
  out <- acirl_adapter()$parse(main_path, meta)
  expect_silent(sampleTidy:::ir_validate(out$results, kind = "results"))
  expect_silent(sampleTidy:::ir_validate(out$samples, kind = "samples"))
})

# RETIRED 2026-08-01 (R-6.3a): "a >20-row field block emits a warning".
# The warning measured the size of the terminator-bounded block, and there is
# no terminator any more - rows are classified individually (A75). Real water
# sheets routinely carry ~50 labelled rows (the reference workbook has 50), so
# the old warning would now fire on essentially every real sheet. Replaced by
# the positive property that actually matters: a large sheet parses in full.
test_that("R-6.3a: a large field block parses in full, with no spurious size warning", {
  meta <- sampleTidy:::file_meta(edge_path)
  out <- acirl_adapter()$parse(edge_path, meta)
  # Field Data Big's own pH values (7.00, 7.10, 7.05, 7.15) must appear
  expect_true(any(out$results$value_raw %in% c("7", "7.1", "7.05", "7.15") |
                    out$results$value_num %in% c(7, 7.1, 7.05, 7.15)))
  expect_false(any(grepl("more than 20", out$report$warnings, fixed = TRUE)))
})

# CHANGED 2026-08-01 (R-6.3a): the `Units` marker is now ONLY the match()
# fingerprint (R-6.1); it no longer locates the block, because in every real
# workbook it sits 3-4 rows above the header on its own row. A sheet that has
# a `Site Name` row but no `Units` marker is therefore parsed (units_raw NA)
# rather than skipped. What IS skipped is a sheet with no `Site Name` row at
# all - 70 such sheets exist in the real corpus.
test_that("R-6.3a: a sheet with no Units marker still parses; the anchor is Site Name", {
  meta <- sampleTidy:::file_meta(edge_path)
  out <- acirl_adapter()$parse(edge_path, meta)
  # Field Data NoUnits has a Site Name row, so its values are now recovered
  expect_true(any(out$results$value_num %in% c(7.20, 7.35)))
  # and it must not be reported as skipped for want of a Units marker
  expect_false(any(out$report$skipped$reason == "no_units_marker"))
  # sibling sheets still parse
  expect_true(nrow(out$results) > 0)
})

test_that("R-6.3a: a sheet with no Site Name row is skipped as no_site_row", {
  # "Water Methodology" is a real-shaped sheet with no Site Name row. Fed to
  # the water-sheet parser directly it must skip loudly, not return silently
  # empty - 70 real corpus sheets take this path.
  ws <- sampleTidy:::.st_acirl_parse_water_sheet(
    real_path, "Water Methodology", st_config("field_analytes")
  )
  expect_length(ws$results, 0)
  reasons <- vapply(ws$skipped, function(s) s$reason[[1]], character(1))
  expect_true("no_site_row" %in% reasons)
  expect_true(any(grepl("Site Name", ws$warnings, fixed = TRUE)))
})

# ---- R-6.4 dust sheets (A10) -----------------------------------------------------

# ---- R-6.4 dust sheets are PARSED (A73 reversed A10) ----------------------
#
# The old test here asserted `dust_sheet_ignored` - the A10 behaviour A73
# REVERSED on 2026-08-01. It is replaced, not patched: asserting the old
# contract would now be asserting the opposite of the ruling.
#
# Geometry re-measured over all 50 real dust-results and 50 dust-observations
# sheets (PLAN-06 R-6.4a); the fixture reproduces it, including the one-column
# INCOMBUSTIBLE shift and a `<0.1` below-detection value.

dust_rows_of <- function(out) {
  out$results[out$results$analyte_raw %in%
                c("INSOLUBLE SOLIDS", "*COMBUSTIBLE MATTER",
                  "INCOMBUSTIBLE MATTER"), ]
}

test_that("R-6.4: a 3-block quarterly dust sheet yields 3 x 2 gauges x 3 analytes", {
  out <- acirl_adapter()$parse(real_path, sampleTidy:::file_meta(real_path))
  d <- dust_rows_of(out)
  expect_equal(nrow(d), 18)
  expect_setequal(unique(d$feature_raw), c("T.D01", "T.D02"))
  # `Exposure Days` closes a month-block and is never a result
  expect_false(any(grepl("Exposure", d$analyte_raw, ignore.case = TRUE)))
  expect_true(all(d$units_raw == "g/m2/month"))
})

test_that("R-6.4: the column-SHIFTED incombustible value is read from the right cell", {
  # Measured: 49 of 50 real sheets put INCOMBUSTIBLE's values one column right
  # of its header, 1 puts them beneath it - so the reader COALESCEs. The
  # fixture writes col 13 against a col-12 header; a constant +1 offset would
  # pass here but break the other sheet, and reading only the header column
  # would yield nothing at all.
  out <- acirl_adapter()$parse(real_path, sampleTidy:::file_meta(real_path))
  inc <- out$results[out$results$analyte_raw == "INCOMBUSTIBLE MATTER", ]
  expect_equal(nrow(inc), 6)
  expect_setequal(inc$value_num, c(1.8, 0.2, 0.3, 0.2, 0.4, 3.1))
})

test_that("R-6.4: a `<0.1` dust value sets below_detection", {
  out <- acirl_adapter()$parse(real_path, sampleTidy:::file_meta(real_path))
  bd <- out$results[out$results$analyte_raw == "*COMBUSTIBLE MATTER" &
                      out$results$below_detection, ]
  # both gauges in block 2, plus T.D01 in block 3
  expect_equal(nrow(bd), 3)
  expect_true(all(bd$value_raw == "<0.1"))
  expect_true(all(bd$value_num == 0.1))
})

test_that("R-6.4: the observation text becomes an ANALYSIS OBSERVATIONS result AND a sample comment", {
  out <- acirl_adapter()$parse(real_path, sampleTidy:::file_meta(real_path))
  obs <- out$results[out$results$analyte_raw == "ANALYSIS OBSERVATIONS", ]
  expect_equal(nrow(obs), 6)
  expect_true(all(!is.na(obs$value_chr)))
  # `ANALYSIS OBSERVATIONS` is a registered ACIRL lab_method against the
  # `Appearance` analyte, so the RAW header text must survive as analyte_raw
  # for reconcile to resolve it.
  expect_true(any(grepl("bird droppings", obs$value_chr)))
  dust_samp <- out$samples[out$samples$matrix_raw == "Dust", ]
  expect_equal(nrow(dust_samp), 6)
  expect_true(any(grepl("bird droppings", dust_samp$comments)))
})

test_that("R-6.4/A77: Month contradicting EXPOSURE DATE is routed to review, never silently resolved", {
  out <- acirl_adapter()$parse(dustconflict_path, sampleTidy:::file_meta(dustconflict_path))
  expect_true(any(out$report$skipped$reason == "dust_exposure_date_conflict"))
  # neither sheet is authoritative (A77), so the disagreement is SURFACED and
  # the row is still emitted - it is a review item, not a silent drop
  expect_gt(nrow(dust_rows_of(out)), 0)
})

test_that("R-6.4: the main fixture's Month and EXPOSURE DATE AGREE, so no conflict fires", {
  # Reachability guard: without this the A77 test above could pass merely
  # because the detector fires on everything.
  out <- acirl_adapter()$parse(real_path, sampleTidy:::file_meta(real_path))
  expect_false(any(out$report$skipped$reason == "dust_exposure_date_conflict"))
})

test_that("R-6.7 extends to dust: `Other Sample Id` on a dust sheet is an alias, not an analyte", {
  out <- acirl_adapter()$parse(real_path, sampleTidy:::file_meta(real_path))
  expect_false("Other Sample Id" %in% out$results$analyte_raw)
  al <- out$report$feature_aliases
  expect_true(all(c("T.D01", "T.D02") %in% al$feature_raw))
  expect_true(all(c("DG #1", "DG #2") %in% al$alias))
})

test_that("R-6.4: a DUST-ONLY workbook yields dust rows and needs no water sheet", {
  out <- acirl_adapter()$parse(dustonly_path, sampleTidy:::file_meta(dustonly_path))
  expect_equal(nrow(dust_rows_of(out)), 6)          # 1 block x 2 gauges x 3
  expect_equal(nrow(out$samples), 2)
  expect_identical(out$report$n_water_sheets, 0L)   # and stays A74-exempt
})

# ---- R-11.15 ACIRL synthetic per-column lab_sample_id ---------------------
#
# PLAN-11 R-11.15: the ACIRL adapter emits a synthetic per-column
# `lab_sample_id` (`"<sheet>!c<col>"`) on BOTH the results rows and the
# samples rows derived from that column, so the join in assemble.R can use
# the exact-match branch instead of a feature-name-only fallback. See
# dev/plans/PLAN-11-feature-alias.md block B-11.15.

test_that("R-11.15: results and samples lab_sample_id is non-NA and matches the '<sheet>!c<col>' format", {
  meta <- sampleTidy:::file_meta(main_path)
  out <- acirl_adapter()$parse(main_path, meta)
  expect_true(all(!is.na(out$results$lab_sample_id)))
  expect_true(all(!is.na(out$samples$lab_sample_id)))
  id_pattern <- "^(Field Data 1|Field Data 2)!c[0-9]+$"
  expect_true(all(grepl(id_pattern, out$results$lab_sample_id)))
  expect_true(all(grepl(id_pattern, out$samples$lab_sample_id)))
})

test_that("R-11.15: lab_sample_id is distinct per sample column within a sheet", {
  meta <- sampleTidy:::file_meta(main_path)
  out <- acirl_adapter()$parse(main_path, meta)
  fd1_samples <- out$samples[startsWith(out$samples$lab_sample_id, "Field Data 1!"), ]
  # Field Data 1 has 2 features x 2 visits = 4 sample columns (FIXTURES.md/README)
  expect_equal(nrow(fd1_samples), 4)
  expect_equal(length(unique(fd1_samples$lab_sample_id)), 4)
})

test_that("R-11.15: a result row's lab_sample_id ties it to its own visit's sample column, not a sibling visit", {
  meta <- sampleTidy:::file_meta(main_path)
  out <- acirl_adapter()$parse(main_path, meta)

  s_v1 <- out$samples[out$samples$feature_raw == "T.S01" &
                         out$samples$sample_datetime_raw == "24/05/2025", ]
  s_v2 <- out$samples[out$samples$feature_raw == "T.S01" &
                         out$samples$sample_datetime_raw == "25/05/2025", ]
  # one T.S01/24-May column and one T.S01/25-May column per water sheet (x2 sheets)
  expect_equal(nrow(s_v1), 2)
  expect_equal(nrow(s_v2), 2)
  # distinct per-column ids - no overlap between the two visits
  expect_equal(length(intersect(s_v1$lab_sample_id, s_v2$lab_sample_id)), 0)

  # every result row carrying a visit-1 lab_sample_id is a T.S01 row with its
  # own 3 field analytes (pH/EC/Temperature) - not merged with visit 2's
  for (lsid in s_v1$lab_sample_id) {
    res_rows <- out$results[!is.na(out$results$lab_sample_id) &
                               out$results$lab_sample_id == lsid, ]
    expect_true(all(res_rows$feature_raw == "T.S01"))
    # The property under test is that visit 1's rows are NOT merged with visit
    # 2's: each of the three field analytes appears exactly once per visit
    # column. A76 may add one qualitative Appearance row on a column whose
    # Comments cell carries a recognised term, so the total is 3 or 4 - the
    # per-analyte count is what pins the id partitioning.
    expect_equal(sum(res_rows$analyte_raw %in% c("pH", "EC", "Temperature")), 3)
    expect_setequal(
      intersect(res_rows$analyte_raw, c("pH", "EC", "Temperature")),
      c("pH", "EC", "Temperature")
    )
    expect_true(all(res_rows$analyte_raw %in%
                      c("pH", "EC", "Temperature", "Comments", "Flow observation")))
  }
})

test_that("R-11.15: lab_sample_id is stable across a re-parse of the same file (idempotency)", {
  meta <- sampleTidy:::file_meta(main_path)
  out1 <- acirl_adapter()$parse(main_path, meta)
  out2 <- acirl_adapter()$parse(main_path, meta)
  expect_identical(out1$samples$lab_sample_id, out2$samples$lab_sample_id)
  expect_identical(out1$results$lab_sample_id, out2$results$lab_sample_id)
})

# ---- R-6.3a / R-6.3b / R-6.5: real-workbook geometry -----------------------
# These run against the real-geometry fixtures. Against the PREVIOUS adapter
# every one of them fails (the fixture yielded 0 rows, 2x no_field_block) -
# which is exactly the result the old adapter gave on all 147 real ACIRL
# workbooks. See fixtures/acirl/README-real-geometry.md for the measurement.

test_that("R-6.3a: real geometry parses - Units marker off the header row, labels in the Site Name column", {
  meta <- sampleTidy:::file_meta(real_path)
  out <- acirl_adapter()$parse(real_path, meta)

  expect_gt(nrow(out$results), 0)
  # the old failure mode must be gone entirely
  expect_false(any(out$report$skipped$reason == "no_field_block"))
  # features come from the Site Name row, not the Units row (which is blank).
  # Scoped to WATER rows: dust gauges (T.D*) now parse too (R-6.4/A73), and
  # this test is about water-sheet geometry.
  water <- out$results[!grepl("^T[.]D[0-9]", out$results$feature_raw), ]
  expect_setequal(unique(water$feature_raw), c("T.S01", "T.S02"))
  # both field analytes on the current allowlist are recovered
  expect_true(all(c("pH", "Temperature") %in% out$results$analyte_raw))
})

test_that("R-6.3a: the date row ABOVE the header row is used", {
  meta <- sampleTidy:::file_meta(real_path)
  out <- acirl_adapter()$parse(real_path, meta)
  # fixture dates are 24/05/2025 (visit 1) and 25/05/2025 (visit 2). Scoped to
  # the WATER samples - dust samples carry their own exposure dates (R-6.4).
  water <- out$samples[out$samples$matrix_raw == "Water", ]
  expect_setequal(unique(water$sample_datetime_raw),
                  c("24/05/2025", "25/05/2025"))
})

test_that("R-6.3b: a valueless heading row is dropped, and never becomes a result", {
  meta <- sampleTidy:::file_meta(real_path)
  out <- acirl_adapter()$parse(real_path, meta)
  # "Dissolved Major Cations" is a section heading with no values in any
  # sample column - it must not appear as a result NOR as an ALS candidate
  expect_false("Dissolved Major Cations" %in% out$results$analyte_raw)
  expect_false("Dissolved Major Cations" %in% out$report$als_candidates$analyte_raw)
  expect_true(any(out$report$skipped$reason == "heading"))
})

test_that("R-6.3b: '----' is recorded as not_analysed, never parsed as a value", {
  meta <- sampleTidy:::file_meta(real_path)
  out <- acirl_adapter()$parse(real_path, meta)
  expect_true(any(out$report$skipped$reason == "not_analysed"))
  expect_false(any(grepl("^-{2,}$", out$results$value_raw)))
  expect_false(any(grepl("^-{2,}$", out$report$als_candidates$value_raw)))
})

test_that("R-6.3b: ALS-looking rows are KEPT with their values, not discarded at parse", {
  meta <- sampleTidy:::file_meta(real_path)
  out <- acirl_adapter()$parse(real_path, meta)
  cand <- out$report$als_candidates
  expect_gt(nrow(cand), 0)
  # the ALS twins of the field probes must survive parse WITH their values,
  # because A75's comparison happens later in assemble/reconcile and cannot
  # run on values the adapter threw away
  expect_true("pH Value" %in% cand$analyte_raw)
  ph_copy <- cand$value_raw[cand$analyte_raw == "pH Value"]
  expect_true(all(c("6.42", "6.61") %in% ph_copy))
  # and the field reading is a result, distinct from its ALS twin
  expect_true("pH" %in% out$results$analyte_raw)
  expect_false("pH Value" %in% out$results$analyte_raw)
})

# ---- R-6.6 (A76): the widened field set, the diff-required pair, and the
# ---- qualitative Stage/Appearance split ------------------------------------
#
# The vocabulary these tests assert against is MEASURED, not invented: 262
# distinct observation values over the real corpus, cross-checked against the
# `Stage`/`Appearance` values already in the live database. See
# `scratchpad/a76_split_result.csv` for the full calibration table.

test_that("R-6.6: the widened allowlist imports Electrical Conductivity and Standing Water Level", {
  meta <- sampleTidy:::file_meta(real_path)
  out <- acirl_adapter()$parse(real_path, meta)
  # Both were silently dropped by the old four-entry allowlist, which matched
  # labels exactly and knew only "Conductivity"/"EC".
  expect_true("Electrical Conductivity" %in% out$results$analyte_raw)
  expect_true("Standing Water Level" %in% out$results$analyte_raw)
  # ...while the @-25 variant, which is the ALS value transcribed into the
  # sheet, stays an ALS candidate and never becomes a result.
  expect_false("Electrical Conductivity @ 25°C" %in% out$results$analyte_raw)
  expect_true("Electrical Conductivity @ 25°C" %in% out$report$als_candidates$analyte_raw)
})

test_that("R-6.6: a transcription label is never imported on its name alone", {
  meta <- sampleTidy:::file_meta(real_path)
  out <- acirl_adapter()$parse(real_path, meta)
  # `Total Suspended Solids` is the ALS analyte's own name, and measurement
  # settled what the ACIRL rows are: transcriptions, not field estimates. The
  # adapter still cannot decide anything (one file, no DB) - it routes them to
  # als_candidates WITH THEIR VALUES, and R-8.9 supersedes them once the label
  # has an analyte.
  expect_false("Total Suspended Solids" %in% out$results$analyte_raw)
  cand <- out$report$als_candidates
  tss <- cand[cand$analyte_raw == "Total Suspended Solids", ]
  expect_gt(nrow(tss), 0)
  expect_true(all(tss$transcription_label))
  # The values survive parse. `<5` is the evidence itself: it is ALS's own
  # reporting limit for EA025, which is why these rows are known to be copies.
  expect_true(all(c("6", "<5") %in% tss$value_raw))
  # every OTHER candidate is a plain ALS copy, not a name-collision label
  expect_false(any(cand$transcription_label[cand$analyte_raw != "Total Suspended Solids"]))
  expect_true(any(out$report$skipped$reason == "transcription_label"))
})

test_that("R-6.6: observations split into one Stage and one Appearance qualitative row", {
  meta <- sampleTidy:::file_meta(real_path)
  out <- acirl_adapter()$parse(real_path, meta)
  qual <- out$results[out$results$analyte_raw %in% c("Flow observation", "Comments"), ]
  expect_gt(nrow(qual), 0)
  # qualitative: value_chr carries the canonical term, value_num is empty
  expect_true(all(is.na(qual$value_num)))
  expect_true(all(!is.na(qual$value_chr)))
  expect_true(all(is.na(qual$units_raw)))
  # value_raw keeps the WHOLE original observation, so the split is auditable
  # from the row itself
  stage <- qual[qual$analyte_raw == "Flow observation", ]
  expect_true("Low flow" %in% stage$value_chr)
  expect_true("Low flow Clear" %in% stage$value_raw)
  expect_true("Pooled" %in% stage$value_chr)
  expect_true("Mod level" %in% stage$value_chr)
})

test_that("R-6.6: at most one Stage and one Appearance row per sample column", {
  meta <- sampleTidy:::file_meta(real_path)
  out <- acirl_adapter()$parse(real_path, meta)
  qual <- out$results[out$results$analyte_raw %in% c("Flow observation", "Comments"), ]
  # This fixture carries BOTH "Observations / Comments" and "Flow Observation /
  # Appearance" on the same sheet and they disagree on appearance (Cloudy vs
  # Clear). That combination occurs ZERO times in the real corpus - the three
  # observation labels never co-occur on one sheet - so the fixture is
  # deliberately stricter than reality, and exists solely to pin the dedupe
  # rule Robin asked for (2026-08-01: "make sure we don't end up with duplicate
  # rows for the field rows"). First non-NA wins, top-to-bottom.
  per_col <- table(qual$lab_sample_id, qual$analyte_raw)
  expect_true(all(per_col <= 1))
  first_col <- qual[qual$lab_sample_id == qual$lab_sample_id[[1]], ]
  expect_setequal(first_col$analyte_raw, c("Flow observation", "Comments"))
  # "Observations / Comments" sits ABOVE "Flow Observation / Appearance" in the
  # sheet, so its "Cloudy" wins over the later row's "Clear".
  expect_identical(first_col$value_chr[first_col$analyte_raw == "Comments"], "Cloudy")
})

test_that("R-6.6: the raw observation text still reaches the sample, unsplit", {
  meta <- sampleTidy:::file_meta(real_path)
  out <- acirl_adapter()$parse(real_path, meta)
  # Both observation rows are concatenated, in sheet order, and nothing is lost
  # to the split - this is the only home for observations that describe no
  # water at all ("could not locate", "no access").
  expect_true("Cloudy; Low flow Clear" %in% out$samples$comments)
})

test_that("R-6.6: the observation splitter reproduces the measured corpus vocabulary", {
  split <- sampleTidy:::.st_acirl_split_observation
  expect_identical(split("Low flow Clear"), list(stage = "Low flow", appearance = "Clear"))
  expect_identical(split("Mod level/ Cloudy"), list(stage = "Mod level", appearance = "Cloudy"))
  expect_identical(split("Low dis/Clear"), list(stage = "Low discharge", appearance = "Clear"))
  expect_identical(split("Very low flow Clear"),
                   list(stage = "Very low flow", appearance = "Clear"))
  # run-together and split spellings, both measured
  expect_identical(split("Lowflow/ Clear"), list(stage = "Low flow", appearance = "Clear"))
  expect_identical(split("Mod flowClear"), list(stage = "Mod flow", appearance = "Clear"))
  expect_identical(split("Mod flow C lear"), list(stage = "Mod flow", appearance = "Clear"))
  # measured misspellings, matched by explicit alternation - never fuzzily
  expect_identical(split("Low flow, celar"), list(stage = "Low flow", appearance = "Clear"))
  expect_identical(split("High evel Slightly cloudy"),
                   list(stage = "High level", appearance = "Slightly cloudy"))
  expect_identical(split("Mod level, slighhtly cloudy"),
                   list(stage = "Mod level", appearance = "Slightly cloudy"))
  # "slightly cloudy" must never be read as "cloudy"
  expect_identical(split("Slightly cloudy")$appearance, "Slightly cloudy")
  # standalone stage terms, no magnitude
  expect_identical(split("Non Discharge"), list(stage = "No discharge", appearance = NA_character_))
  expect_identical(split("Dry"), list(stage = "Dry", appearance = NA_character_))
  expect_identical(split("Clear, polled"), list(stage = "Pooled", appearance = "Clear"))
  # the "low" inside "flow" must not manufacture a magnitude - this is the
  # false positive the leading word boundary was added to kill
  expect_identical(split("Clear, flow flow"), list(stage = NA_character_, appearance = "Clear"))
  # observations that describe no water at all yield neither analyte; the raw
  # text is preserved on the sample instead
  for (v in c("Could not locate, grass too long", "No access, snakes on site and track",
              "Decomissioned", "Too dangerous to sample", "Insufficient sample",
              "Unable to locate", "No longer exists", "Blocked")) {
    expect_identical(split(v), list(stage = NA_character_, appearance = NA_character_),
                     info = v)
  }
  expect_identical(split(NA_character_), list(stage = NA_character_, appearance = NA_character_))
  expect_identical(split(""), list(stage = NA_character_, appearance = NA_character_))
})

test_that("R-6.5: als_work_orders is exposed, including a two-order citation", {
  meta <- sampleTidy:::file_meta(real_path)
  expect_identical(acirl_adapter()$parse(real_path, meta)$report$als_work_orders,
                   "ES9999001")

  # 2400-9999-13 cites ES9999001/ES9999002 on one sheet, and carries a bare
  # "ES", an ACIRL number and a blank on the others - none of which yield a
  # work order. A74 requires ALL cited orders, so both must surface.
  meta2 <- sampleTidy:::file_meta(alsrefs_path)
  wo <- acirl_adapter()$parse(alsrefs_path, meta2)$report$als_work_orders
  expect_setequal(wo, c("ES9999001", "ES9999002"))
})

test_that("R-6.1: a dust-only workbook matches (it has no Units marker at all)", {
  # All 6 real dust-only workbooks measured match() == "no" before the second
  # match arm was added; reversing A10 alone would have recovered no dust.
  meta <- sampleTidy:::file_meta(dustonly_path)
  expect_identical(acirl_adapter()$match(meta), "format")
  expect_false(any(grepl("Units", readxl::excel_sheets(dustonly_path))))
})

# ---- R-6.7: site-metadata labels are not analytes -------------------------
#
# Measured over all 154 claimed workbooks: exactly three labels carry the
# sampling point's alternative name as an ordinary label row, and their values
# are 100% non-numeric - "BORE 2", "Cripple Creek", "EFFLUENT".
#
#     Other Sample Id   2604 rows across 97 files
#     Other Site Name     26 rows
#     Other Site ID        5 rows
#
# They used to take the `als_candidate` path, where A75 rule (iv) would open
# ~2,635 review items of pure noise - 21% of the whole no-twin population.

test_that("R-6.7: a site-metadata label yields no result and no ALS candidate", {
  meta <- sampleTidy:::file_meta(real_path)
  out <- acirl_adapter()$parse(real_path, meta)

  for (lab in c("Other Sample Id", "Other Site Name", "Other Site ID")) {
    expect_false(lab %in% out$results$analyte_raw, info = lab)
    expect_false(lab %in% out$report$als_candidates$analyte_raw, info = lab)
  }
  expect_true(any(out$report$skipped$reason == "site_metadata_label"))
})

test_that("R-6.7: the point-code -> name mapping is kept, not discarded", {
  meta <- sampleTidy:::file_meta(real_path)
  al <- acirl_adapter()$parse(real_path, meta)$report$feature_aliases

  # Recognising these rows as metadata must not throw the evidence away: the
  # mapping is exactly what the feature-alias subsystem needs.
  expect_true(nrow(al) > 0)
  expect_named(al, c("source_ref", "feature_raw", "label", "alias"),
               ignore.order = TRUE)
  expect_true(all(!is.na(al$feature_raw)))
  expect_true(all(nzchar(al$alias)))
  # deduped - the same (feature, label, alias) on two sheets is one row
  expect_equal(nrow(al), nrow(dplyr::distinct(al)))
})

test_that("R-6.7: an ordinary analyte label is untouched by the metadata rule", {
  # Reachability guard: the metadata set must be an exact-label match, not a
  # prefix or substring one. "Other Sample Id" must not take "Total Suspended
  # Solids" (or anything else) down with it.
  meta <- sampleTidy:::file_meta(real_path)
  out <- acirl_adapter()$parse(real_path, meta)
  expect_true(nrow(out$results) > 0)
  expect_true(nrow(out$report$als_candidates) > 0)
  expect_true("pH" %in% out$results$analyte_raw)
})

# ---- RULING 2026-08-08: the stale-template Fe labels ----------------------
#
# Two Fe labels in the Lawson Landfill workbooks are an UNCLEARED TEMPLATE ROW,
# not a reading. Measured over the unprocessed corpus
# (`scratchpad/m6a_corpus_candidates.rds`, 34,137 candidate rows):
#
#     Ferrous Iron by Discrete Analyser        20 rows, 4 files
#     Dissolved Ferric Iron by ICPMS and DA    20 rows, 4 files
#
# What makes them stale rather than merely oddly named:
#
#   * The stale row sits ONE ROW ABOVE the real row it shadows - r30 `Ferrous
#     Iron by Discrete Analyser` / r31 `Ferrous Iron`, r32 `Dissolved Ferric
#     Iron by ICPMS and DA` / r33 `Ferric Iron`.
#   * Its values are BYTE-IDENTICAL across all four workbooks, which span
#     May-2024, Nov-2024 and May-2025. Ferrous is 0.14 / 0.14 / 7.18 / <0.05 /
#     <0.05 per sampling point in every one of them; Ferric is `<0.05` on all
#     20 rows. Three sampling rounds a year apart do not repeat five numbers.
#   * 13 of the 20 Ferrous rows share a (file, sampling point) with the real
#     `Ferrous Iron` row, and 7 of those 13 DISAGREE with it - only the
#     May-2024 workbook the template was frozen from agrees, which is what
#     dates the freeze. Ferric collides on 13 of 20 the same way.
#   * All 40 rows carry no units; the real Fe rows carry `mg/L`.
#
# So the identity is not in doubt (they ARE Fe(II) and Fe(III)) - the VALUES
# are known-wrong, and linking the labels would commit them.
#
# WHY THE ADAPTER AND NOT A MAPPING. Leaving a label out of migration 006's
# label -> analyte mapping only stops it RESOLVING, never IMPORTING.
# `.rc_resolve_analytes()` drops a row from `kept` for exactly one status,
# `held`; an unmapped label gets `miss`, which keeps the row with
# `analyte_pending = TRUE` and mints a dangling `lab_method` at commit.
# Measured over all 7 labels excluded from 006: 7 rows in, 7 kept, 6 review
# items (`scratchpad/m6a_excluded_fate.R`). A label that must not be imported
# needs an adapter-level exclusion, so these ride the same exact-label path
# R-6.7 built for the site-metadata labels.

# Builds a water-sheet-only workbook in the MEASURED real geometry (R-6.3a:
# units_col = site_col + 1, first feature col = site_col + 2, date row ABOVE
# the site row) carrying the Lawson Fe block in its real vertical order, with
# the stale row immediately above the real one it shadows.
acirl_fe_workbook <- function(env = parent.frame()) {
  skip_if_not_installed("openxlsx")
  path <- withr::local_tempfile(fileext = ".xlsx", .local_envir = env)
  site_col <- 2L; units_col <- 3L; feat_col <- 4L
  site_row <- 10L; date_row <- 9L
  features <- c("L.MW06", "L.MW07", "L.MW08")

  wb <- openxlsx::createWorkbook()
  openxlsx::addWorksheet(wb, "Groundwater Sites 2")
  put <- function(r, c, v) {
    openxlsx::writeData(wb, "Groundwater Sites 2", x = v, startRow = r,
                        startCol = c, colNames = FALSE, rowNames = FALSE)
  }
  put(site_row - 4L, units_col, "Units")            # R-6.1 fingerprint
  put(date_row, site_col, "Date of Sample")
  for (i in seq_along(features)) put(date_row, feat_col + i - 1L, 45802)
  put(site_row, site_col, "Site Name")
  for (i in seq_along(features)) put(site_row, feat_col + i - 1L, features[[i]])

  # The real vertical order, from `2400-7430-01 May 2024 Lawson Landfill.xls`.
  # `Iron` is on the field allowlist below and so must emit RESULTS; the four
  # Fe(II)/Fe(III) labels are not, so the two survivors must emit ALS
  # CANDIDATES. Both survival routes are therefore exercised.
  rows <- list(
    list("Iron",                                  "mg/L", c("<0.05", "0.07", "6.33")),
    list("Ferrous Iron by Discrete Analyser",     NA,     c("0.14", "0.14", "7.18")),
    list("Ferrous Iron",                          "mg/L", c("0.14", "0.40", "0.05")),
    list("Dissolved Ferric Iron by ICPMS and DA", NA,     c("<0.05", "<0.05", "<0.05")),
    list("Ferric Iron",                           "mg/L", c("<0.05", "0.12", "<0.05"))
  )
  for (k in seq_along(rows)) {
    r <- site_row + k
    put(r, site_col, rows[[k]][[1]])
    if (!is.na(rows[[k]][[2]])) put(r, units_col, rows[[k]][[2]])
    for (i in seq_along(features)) put(r, feat_col + i - 1L, rows[[k]][[3]][[i]])
  }
  openxlsx::saveWorkbook(wb, path, overwrite = TRUE)
  path
}

# `Iron` stands in for the field allowlist so the sheet has a real result row;
# the Fe(II)/Fe(III) labels are deliberately absent from both vectors, which is
# the state they are in today.
acirl_fe_parse <- function(path) {
  sampleTidy:::.st_acirl_parse_water_sheet(
    path, "Groundwater Sites 2",
    field_analytes = c("Iron", "pH"),
    transcription_labels = character(0)
  )
}

acirl_fe_labels <- function(ws) {
  c(vapply(ws$results, function(x) x$analyte_raw, character(1)),
    vapply(ws$als_candidates, function(x) x$analyte_raw, character(1)))
}

test_that("RULING 2026-08-08: the stale-template Fe labels emit no row at all", {
  # Not "no result" - NO ROW. The als_candidate path is the one that would have
  # carried these values forward into the transcription population, so it is
  # the path that has to be empty, and the skip has to be recorded rather than
  # silent so the drop is auditable from the report.
  path <- acirl_fe_workbook()
  ws <- acirl_fe_parse(path)

  stale <- c("Ferrous Iron by Discrete Analyser",
             "Dissolved Ferric Iron by ICPMS and DA")
  for (lab in stale) {
    expect_false(lab %in% vapply(ws$results, function(x) x$analyte_raw, character(1)),
                 info = lab)
    expect_false(lab %in% vapply(ws$als_candidates, function(x) x$analyte_raw, character(1)),
                 info = lab)
  }
  # One skip row per stale LABEL row (the metadata rule's granularity), not per
  # cell: two labels, one sheet.
  reasons <- vapply(ws$skipped, function(x) x$reason, character(1))
  expect_equal(sum(reasons == "stale_template_label"), 2L)
})

test_that("RULING 2026-08-08: the stale labels are not carried as feature aliases", {
  # The site-metadata rule keeps its rows as point-code -> name evidence. This
  # rule must NOT: the stale values are `0.14` and `<0.05`, which are numbers,
  # not alternative site names, and would poison the alias domain.
  path <- acirl_fe_workbook()
  ws <- acirl_fe_parse(path)
  expect_length(ws$feature_aliases, 0L)
})

test_that("RULING 2026-08-08: the REAL Ferrous/Ferric Iron labels still survive", {
  # The whole point of the ruling. The stale rows shadow real rows with the
  # same element in the same workbook, so an over-broad match ("anything with
  # Ferrous in it") destroys the data the ruling exists to protect - and it
  # would do so silently, because the real rows are ALS candidates, not
  # results, so no result count would move.
  path <- acirl_fe_workbook()
  ws <- acirl_fe_parse(path)

  cand <- vapply(ws$als_candidates, function(x) x$analyte_raw, character(1))
  expect_true("Ferrous Iron" %in% cand)
  expect_true("Ferric Iron" %in% cand)
  # 2 surviving Fe labels x 3 sampling points, and nothing else.
  expect_equal(length(cand), 6L)
  expect_setequal(unique(cand), c("Ferrous Iron", "Ferric Iron"))

  # Values arrive intact - the survivors are the real row's numbers, not the
  # frozen template's (0.14 / 0.14 / 7.18).
  ferrous <- vapply(ws$als_candidates[cand == "Ferrous Iron"],
                    function(x) x$value_raw, character(1))
  expect_setequal(ferrous, c("0.14", "0.40", "0.05"))
})

test_that("RULING 2026-08-08: the allowlisted `Iron` row is untouched", {
  # `Iron` is 155 rows across 43 files in the corpus - far more than the Fe(II)
  # and Fe(III) rows combined - and shares the substring with neither stale
  # label but DOES share it with the word the exclusion is written around. A
  # match written on "Iron" rather than the full label takes it out.
  path <- acirl_fe_workbook()
  ws <- acirl_fe_parse(path)
  res <- vapply(ws$results, function(x) x$analyte_raw, character(1))
  expect_equal(sum(res == "Iron"), 3L)
})

test_that("RULING 2026-08-08: the stale match is exact, and case/whitespace-blind", {
  # Two directions at once. (a) The labels are matched on the NORMALISED label,
  # so the same row in ALL CAPS or with the double space real spreadsheets pick
  # up is still excluded. (b) The match is exact, so a longer label that merely
  # CONTAINS a stale one is not swept up with it - the corpus has no such
  # label today, which is exactly why an over-broad match would go unnoticed.
  skip_if_not_installed("openxlsx")
  path <- withr::local_tempfile(fileext = ".xlsx")
  wb <- openxlsx::createWorkbook()
  openxlsx::addWorksheet(wb, "Groundwater Sites 2")
  put <- function(r, c, v) {
    openxlsx::writeData(wb, "Groundwater Sites 2", x = v, startRow = r,
                        startCol = c, colNames = FALSE, rowNames = FALSE)
  }
  put(6L, 3L, "Units")
  put(9L, 2L, "Date of Sample"); put(9L, 4L, 45802)
  put(10L, 2L, "Site Name");     put(10L, 4L, "L.MW06")
  variants <- c(
    "FERROUS IRON BY  DISCRETE ANALYSER",      # (a) case + doubled space
    "Total Ferrous Iron by Discrete Analyser", # (b) stale label as a suffix
    "Ferrous Iron by Discrete Analyser (Field)" # (b) stale label as a prefix
  )
  for (k in seq_along(variants)) {
    put(10L + k, 2L, variants[[k]])
    put(10L + k, 4L, "0.14")
  }
  openxlsx::saveWorkbook(wb, path, overwrite = TRUE)

  ws <- acirl_fe_parse(path)
  cand <- vapply(ws$als_candidates, function(x) x$analyte_raw, character(1))
  expect_false("FERROUS IRON BY DISCRETE ANALYSER" %in% cand)
  expect_setequal(cand, variants[2:3])
})
