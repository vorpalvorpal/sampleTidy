# tests/testthat/test-adapter-crosstab.R
#
# TDD "red" tests for R/adapter-crosstab.R (plan 05: shared parser +
# `als_xtab` + `als_enmrg`). R/adapter-crosstab.R does not exist yet, so every
# test below is expected to fail (missing function/object) until plan 05
# lands. See dev/plans/PLAN-05-adapters-crosstab.md and
# dev/plans/FIXTURES.md for the pinned contract, and
# tests/testthat/fixtures/crosstab/README.md for the fixture layout decisions
# (column positions, two-section structure, mojibake bytes).
#
# Adapter accessor: as in test-adapter-esdat.R, we use the registry route
# pending adjudication (dev/plans/PLAN-CHANGE-REQUESTS.md).

xtab_adapter  <- function() sampleTidy:::adapter_registry()[["als_xtab"]]
enmrg_adapter <- function() sampleTidy:::adapter_registry()[["als_enmrg"]]

xtab_csv_path    <- test_path("fixtures", "crosstab", "XX1234567_0_XTAB.csv")
xtab_xlsx_path   <- test_path("fixtures", "crosstab", "XX1234567_0_XTAB.xlsx")
enmrg_csv_path   <- test_path("fixtures", "crosstab", "XX1234567_0_ENMRG.CSV")
mismatch_path    <- test_path("fixtures", "crosstab", "ZZ9999999_0_XTAB.csv")
esdat_chem_path  <- test_path("fixtures", "esdat", "PROJ_A.ESDAT_XX1234567_0.Chemistry2e.CSV")
random_csv_path  <- test_path("fixtures", "esdat", "random.csv")

# columns considered "provenance" and expected to legitimately differ between
# two files carrying the same logical content (R-5.2's ".xls parses equal to
# its .csv twin, same IR, ignoring source_ref" criterion).
strip_provenance <- function(df) {
  df[, setdiff(names(df), c("source_ref", "source_hash")), drop = FALSE]
}
row_order <- function(df, cols) do.call(order, as.list(df[cols]))

# ---- R-5.2 match() -----------------------------------------------------------

test_that("R-5.2: XTAB fixture claimed only by als_xtab (format tier)", {
  meta <- sampleTidy:::file_meta(xtab_csv_path)
  expect_identical(xtab_adapter()$match(meta), "format")
  expect_identical(enmrg_adapter()$match(meta), "no")
})

test_that("R-5.2: ENMRG fixture claimed only by als_enmrg (format tier)", {
  meta <- sampleTidy:::file_meta(enmrg_csv_path)
  expect_identical(enmrg_adapter()$match(meta), "format")
  expect_identical(xtab_adapter()$match(meta), "no")
})

test_that("R-5.2: ESdat Chemistry2e fixture matches no from both crosstab adapters", {
  meta <- sampleTidy:::file_meta(esdat_chem_path)
  expect_identical(xtab_adapter()$match(meta), "no")
  expect_identical(enmrg_adapter()$match(meta), "no")
})

test_that("R-5.2: random CSV matches no from both crosstab adapters", {
  meta <- sampleTidy:::file_meta(random_csv_path)
  expect_identical(xtab_adapter()$match(meta), "no")
  expect_identical(enmrg_adapter()$match(meta), "no")
})

test_that("R-5.2: .xlsx XTAB fixture (binary) matches format and parses equal to its .csv twin", {
  meta <- sampleTidy:::file_meta(xtab_xlsx_path)
  expect_identical(xtab_adapter()$match(meta), "format")

  meta_csv  <- sampleTidy:::file_meta(xtab_csv_path)
  out_csv   <- xtab_adapter()$parse(xtab_csv_path, meta_csv)
  out_xlsx  <- xtab_adapter()$parse(xtab_xlsx_path, meta)

  res_csv  <- strip_provenance(out_csv$results)
  res_xlsx <- strip_provenance(out_xlsx$results)
  res_csv  <- res_csv[row_order(res_csv, c("lab_sample_id", "analyte_raw")), ]
  res_xlsx <- res_xlsx[row_order(res_xlsx, c("lab_sample_id", "analyte_raw")), ]
  rownames(res_csv) <- NULL
  rownames(res_xlsx) <- NULL
  expect_equal(res_csv, res_xlsx)

  samp_csv  <- strip_provenance(out_csv$samples)
  samp_xlsx <- strip_provenance(out_xlsx$samples)
  samp_csv  <- samp_csv[row_order(samp_csv, "lab_sample_id"), ]
  samp_xlsx <- samp_xlsx[row_order(samp_xlsx, "lab_sample_id"), ]
  rownames(samp_csv) <- NULL
  rownames(samp_xlsx) <- NULL
  expect_equal(samp_csv, samp_xlsx)
})

# ---- R-5.1 shared parser ------------------------------------------------------

test_that("R-5.1: XTAB results count = sum of valid analyte x sample cells across both sections", {
  meta <- sampleTidy:::file_meta(xtab_csv_path)
  out <- xtab_adapter()$parse(xtab_csv_path, meta)
  # WATER section: pH 1 valid (of 3), Fluoride 3 valid, EC 2 valid = 6
  # SOIL section: pH/Fluoride/EC each 1 valid (1 sample col) = 3
  expect_equal(nrow(out$results), 9)
})

test_that("R-5.1: '----' and empty XTAB cells land in report$skipped with correct reasons and source_ref", {
  meta <- sampleTidy:::file_meta(xtab_csv_path)
  out <- xtab_adapter()$parse(xtab_csv_path, meta)
  skipped <- out$report$skipped
  expect_equal(nrow(skipped), 3)
  expect_equal(sum(skipped$reason == "not_computable"), 1)
  expect_equal(sum(skipped$reason == "empty"), 2)
  expect_true(all(grepl("^r[0-9]+c[0-9]+$", skipped$source_ref)))
})

test_that("R-5.1: method-group rows produce zero result rows and set method_raw for following rows", {
  meta <- sampleTidy:::file_meta(xtab_csv_path)
  out <- xtab_adapter()$parse(xtab_csv_path, meta)
  # the method-group label text itself never appears as an analyte
  expect_false(any(grepl("^EA0|^EK0", out$results$analyte_raw)))
  ph_rows <- out$results[out$results$analyte_raw == "pH", ]
  fl_rows <- out$results[out$results$analyte_raw == "Fluoride", ]
  expect_true(all(ph_rows$method_raw == "EA005P: pH by PC Titrator"))
  expect_true(all(fl_rows$method_raw == "EK040P: Fluoride by PC Titrator"))
})

test_that("R-5.1: a second method-group row resets method_raw (EC gets its own method)", {
  meta <- sampleTidy:::file_meta(xtab_csv_path)
  out <- xtab_adapter()$parse(xtab_csv_path, meta)
  ec_rows <- out$results[grepl("Electrical Conductivity", out$results$analyte_raw) &
                           out$results$lab_sample_id %in% c("XX1234567001", "XX1234567002"), ]
  expect_true(all(ec_rows$method_raw == "EA010P: Conductivity by PC Titrator"))
})

test_that("R-5.1: two-section fixture - rows carry their own section's matrix and date", {
  meta <- sampleTidy:::file_meta(xtab_csv_path)
  out <- xtab_adapter()$parse(xtab_csv_path, meta)
  water_samples <- out$samples[out$samples$lab_sample_id %in%
                                  c("XX1234567001", "XX1234567002", "XX1234567003"), ]
  expect_true(all(water_samples$matrix_raw == "WATER"))
  expect_true(all(water_samples$sample_datetime_raw == "24/05/2025"))

  soil_samples <- out$samples[out$samples$lab_sample_id == "XX1234567004", ]
  expect_equal(nrow(soil_samples), 1)
  expect_identical(soil_samples$matrix_raw, "SOIL")
  expect_identical(soil_samples$sample_datetime_raw, "25/05/2025")
})

test_that("R-5.1: mojibake analyte normalised - '25<0xA1>C' becomes '25°C' in analyte_raw", {
  meta <- sampleTidy:::file_meta(xtab_csv_path)
  out <- xtab_adapter()$parse(xtab_csv_path, meta)
  ec_rows <- out$results[out$results$lab_sample_id %in% c("XX1234567001", "XX1234567002") &
                           grepl("Electrical Conductivity", out$results$analyte_raw), ]
  expect_equal(nrow(ec_rows), 2)
  expect_true(all(ec_rows$analyte_raw == "Electrical Conductivity @ 25°C"))
  expect_false(any(grepl("¡", ec_rows$analyte_raw)))
})

test_that("R-5.1: cross-format equivalence - XTAB WATER-section values equal ESdat for XX1234567001-003", {
  meta_xtab <- sampleTidy:::file_meta(xtab_csv_path)
  out_xtab  <- xtab_adapter()$parse(xtab_csv_path, meta_xtab)

  fl_001 <- out_xtab$results[out_xtab$results$lab_sample_id == "XX1234567001" &
                               out_xtab$results$analyte_raw == "Fluoride", ]
  expect_identical(fl_001$value_raw, "<0.1")
  fl_002 <- out_xtab$results[out_xtab$results$lab_sample_id == "XX1234567002" &
                               out_xtab$results$analyte_raw == "Fluoride", ]
  expect_identical(fl_002$value_raw, "2.3")
  fl_003 <- out_xtab$results[out_xtab$results$lab_sample_id == "XX1234567003" &
                               out_xtab$results$analyte_raw == "Fluoride", ]
  expect_identical(fl_003$value_raw, ">2000")
  ec_001 <- out_xtab$results[out_xtab$results$lab_sample_id == "XX1234567001" &
                               grepl("Electrical Conductivity", out_xtab$results$analyte_raw), ]
  expect_identical(ec_001$value_raw, "185")
  ec_002 <- out_xtab$results[out_xtab$results$lab_sample_id == "XX1234567002" &
                               grepl("Electrical Conductivity", out_xtab$results$analyte_raw), ]
  expect_identical(ec_002$value_raw, "965")
})

test_that("R-5.1: d/m/y - '05/01/2026' Sample Date is kept verbatim and parses as 5 January", {
  meta <- sampleTidy:::file_meta(mismatch_path)
  out <- xtab_adapter()$parse(mismatch_path, meta)
  expect_true(all(out$samples$sample_datetime_raw == "05/01/2026"))
  parsed <- sampleTidy:::parse_lab_datetime("05/01/2026", formats = "crosstab")
  expect_equal(as.integer(format(parsed, "%m")), 1L)
  expect_equal(as.integer(format(parsed, "%d")), 5L)
  expect_equal(as.integer(format(parsed, "%Y")), 2026L)
})

test_that("R-5.1: ENMRG fixture - 2 QC sample columns emitted (not dropped), counted by sample_type", {
  meta <- sampleTidy:::file_meta(enmrg_csv_path)
  out <- enmrg_adapter()$parse(enmrg_csv_path, meta)
  expect_equal(nrow(out$results), 9)
  lcs_rows <- out$results[out$results$sample_type == "LCS", ]
  mb_rows  <- out$results[out$results$sample_type == "MB", ]
  expect_equal(nrow(lcs_rows), 2)   # pH 7.00, Fluoride 0.5 - both valid
  expect_equal(nrow(mb_rows), 1)    # EC 600 - the only valid MB cell
  expect_true(all(c("LCS", "MB") %in% names(out$report$n_by_sample_type)))
  expect_equal(unname(out$report$n_by_sample_type[["LCS"]]), 2)
  expect_equal(unname(out$report$n_by_sample_type[["MB"]]), 1)
})

test_that("R-5.1: ir_validate() passes on both XTAB and ENMRG outputs", {
  out_xtab  <- xtab_adapter()$parse(xtab_csv_path, sampleTidy:::file_meta(xtab_csv_path))
  out_enmrg <- enmrg_adapter()$parse(enmrg_csv_path, sampleTidy:::file_meta(enmrg_csv_path))
  expect_silent(sampleTidy:::ir_validate(out_xtab$results, kind = "results"))
  expect_silent(sampleTidy:::ir_validate(out_xtab$samples, kind = "samples"))
  expect_silent(sampleTidy:::ir_validate(out_enmrg$results, kind = "results"))
  expect_silent(sampleTidy:::ir_validate(out_enmrg$samples, kind = "samples"))
})

# ---- R-5.3 filename robustness -----------------------------------------------

test_that("R-5.3: Workgroup cell wins over filename guess on mismatch, with a warning", {
  meta <- sampleTidy:::file_meta(mismatch_path)  # filename says ZZ9999999
  out <- xtab_adapter()$parse(mismatch_path, meta)
  expect_true(all(out$results$work_order == "XX1234567"))
  expect_true(length(out$report$warnings) >= 1)
  expect_true(any(grepl("ZZ9999999", out$report$warnings) & grepl("XX1234567", out$report$warnings)))
})
