# tests/testthat/test-adapter-crosstab.R
#
# Tests for R/adapter-crosstab.R (plan 05: shared parser + `als_xtab` +
# `als_enmrg`). CONTRACT A34 (2026-07-15): retargeted to the REAL
# (anonymized, committed) ALS crosstab exports as the primary fixtures for
# every core parsing criterion - `ES2600185_0_XTAB.csv` (XTAB) and
# `ES2537534_0_ENMRG.CSV` (ENMRG). All expected counts/names/values below
# were derived by actually parsing those files with the corrected adapter
# and reading off the results (see PR discussion / dev notes) - never
# hand-guessed. See dev/plans/PLAN-05-adapters-crosstab.md (A34 block),
# dev/plans/CONTRACT.md (A29, A34, A37), tests/testthat/fixtures/
# REAL-FIXTURES.md, and tests/testthat/fixtures/crosstab/README.md.
#
# A small set of synthetic fixtures (generate.R) cover the three criteria
# the two real files do not: a two-section (WATER+SOIL) fixture, a
# Workgroup/filename mismatch fixture, and an ENMRG fixture with QC sample
# columns (the real ENMRG file's only usable section is all-REG - its QC
# data lives in a trailing "QC - Matrix:" block the adapter deliberately
# does not parse; see README.md and the adapter's
# `.ST_CROSSTAB_ANY_MARKER_RE` comment).
#
# Adapter accessor: as in the other adapter test files, we use the registry
# route pending adjudication (dev/plans/PLAN-CHANGE-REQUESTS.md).

xtab_adapter  <- function() sampleTidy:::adapter_registry()[["als_xtab"]]
enmrg_adapter <- function() sampleTidy:::adapter_registry()[["als_enmrg"]]

# Real fixtures (primary).
xtab_real_path  <- test_path("fixtures", "crosstab", "ES2600185_0_XTAB.csv")
xtab_xls_path   <- test_path("fixtures", "crosstab", "ES2600185_0_XTAB.XLS")
enmrg_real_path <- test_path("fixtures", "crosstab", "ES2537534_0_ENMRG.CSV")

# Synthetic fixtures (minimal, cover only what the real files don't).
two_section_path <- test_path("fixtures", "crosstab", "XX1234567_0_XTAB.csv")
enmrg_qc_path     <- test_path("fixtures", "crosstab", "XX1234567_0_ENMRG.CSV")
mismatch_path     <- test_path("fixtures", "crosstab", "ZZ9999999_0_XTAB.csv")

# Cross-adapter non-claim fixtures.
esdat_chem_path  <- test_path("fixtures", "esdat", "PROJ_A.ESDAT_XX1234567_0.Chemistry2e.CSV")
random_csv_path  <- test_path("fixtures", "esdat", "random.csv")

# ---- R-5.2 match() -----------------------------------------------------------

test_that("R-5.2: real XTAB fixture claimed only by als_xtab (format tier)", {
  meta <- sampleTidy:::file_meta(xtab_real_path)
  expect_identical(xtab_adapter()$match(meta), "format")
  expect_identical(enmrg_adapter()$match(meta), "no")
})

test_that("R-5.2: real ENMRG fixture claimed only by als_enmrg (format tier)", {
  meta <- sampleTidy:::file_meta(enmrg_real_path)
  expect_identical(enmrg_adapter()$match(meta), "format")
  expect_identical(xtab_adapter()$match(meta), "no")
})

test_that("A37: real XTAB '.XLS' (SpreadsheetML, unreadable by readxl) matches no, no crash", {
  meta <- sampleTidy:::file_meta(xtab_xls_path)
  expect_identical(xtab_adapter()$match(meta), "no")
  expect_identical(enmrg_adapter()$match(meta), "no")
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

test_that("R-5.2: synthetic two-section/mismatch XTAB and QC ENMRG fixtures match format", {
  expect_identical(xtab_adapter()$match(sampleTidy:::file_meta(two_section_path)), "format")
  expect_identical(xtab_adapter()$match(sampleTidy:::file_meta(mismatch_path)), "format")
  expect_identical(enmrg_adapter()$match(sampleTidy:::file_meta(enmrg_qc_path)), "format")
})

# ---- R-5.1 shared parser: real XTAB (ES2600185_0_XTAB.csv) -------------------
#
# One `Matrix: WATER` section, 3 REG samples (ES2600185001-003), 26 distinct
# analytes (some method groups cover several analytes, e.g. "ED037P:
# Alkalinity by PC Titrator" -> 4 analyte rows, "ED093F: Dissolved Major
# Cations" -> 4 analyte rows). 26 analytes x 3 samples = 78 cells; every
# cell is either a value or a literal "----" (no truly blank cells in this
# file's 3 sample columns) - 24 are "----" (not_computable), 54 are values.

test_that("R-5.1 (real XTAB): results count = analytes x samples minus '----' skips", {
  meta <- sampleTidy:::file_meta(xtab_real_path)
  out <- xtab_adapter()$parse(xtab_real_path, meta)
  expect_equal(length(unique(out$results$analyte_raw)), 26)
  expect_equal(nrow(out$results), 54)
})

test_that("R-5.1 (real XTAB): '----' cells land in report$skipped as not_computable with correct source_ref", {
  meta <- sampleTidy:::file_meta(xtab_real_path)
  out <- xtab_adapter()$parse(xtab_real_path, meta)
  skipped <- out$report$skipped
  expect_equal(nrow(skipped), 24)
  expect_true(all(skipped$reason == "not_computable"))
  expect_true(all(grepl("^r[0-9]+c[0-9]+$", skipped$source_ref)))
})

test_that("R-5.1 (real XTAB): method-group rows produce zero result rows and set method_raw", {
  meta <- sampleTidy:::file_meta(xtab_real_path)
  out <- xtab_adapter()$parse(xtab_real_path, meta)
  # the method-group label text itself never appears as an analyte
  expect_false(any(grepl("^EA0|^EK0|^ED0", out$results$analyte_raw)))

  ph_rows <- out$results[out$results$analyte_raw == "pH Value", ]
  expect_true(all(ph_rows$method_raw == "EA005P: pH by PC Titrator"))

  # a method group spanning several analyte rows (Alkalinity): all 4 share
  # the SAME method_raw, and a different, later group (Chloride) has a
  # different method_raw - proving reset-on-new-group.
  alkalinity_analytes <- c(
    "Hydroxide Alkalinity as CaCO3", "Carbonate Alkalinity as CaCO3",
    "Bicarbonate Alkalinity as CaCO3", "Total Alkalinity as CaCO3"
  )
  alk_rows <- out$results[out$results$analyte_raw %in% alkalinity_analytes, ]
  expect_true(all(alk_rows$method_raw == "ED037P: Alkalinity by PC Titrator"))

  chloride_rows <- out$results[out$results$analyte_raw == "Chloride", ]
  expect_true(all(chloride_rows$method_raw == "ED045G: Chloride by Discrete Analyser"))
  expect_false(any(chloride_rows$method_raw == "ED037P: Alkalinity by PC Titrator"))
})

test_that("R-5.1 (real XTAB): samples - one row per sample column, feature/date/matrix/type correct", {
  meta <- sampleTidy:::file_meta(xtab_real_path)
  out <- xtab_adapter()$parse(xtab_real_path, meta)
  expect_equal(nrow(out$samples), 3)
  expect_setequal(out$samples$lab_sample_id, c("ES2600185001", "ES2600185002", "ES2600185003"))
  expect_setequal(out$samples$feature_raw, c("P.S03", "P.S07", "P.S09"))
  expect_true(all(out$samples$matrix_raw == "WATER"))
  expect_true(all(out$samples$sample_datetime_raw == "05/01/2026"))
  expect_true(all(out$samples$sample_type == "Normal")) # all REG
  expect_true(all(out$samples$work_order == "ES2600185"))
})

test_that("R-5.1 (real XTAB): CAS number, units and Fluoride below-detection value are read correctly", {
  meta <- sampleTidy:::file_meta(xtab_real_path)
  out <- xtab_adapter()$parse(xtab_real_path, meta)
  fl <- out$results[out$results$analyte_raw == "Fluoride", ]
  # sample 001's Fluoride cell is "----" (skipped); 002/003 are both "<0.1".
  expect_equal(nrow(fl), 2)
  expect_setequal(fl$lab_sample_id, c("ES2600185002", "ES2600185003"))
  expect_true(all(fl$cas_number == "16984-48-8"))
  expect_true(all(fl$units_raw == "mg/L"))
  expect_true(all(fl$value_raw == "<0.1"))
  expect_true(all(fl$below_detection))
})

test_that("R-5.1 (real XTAB): degree-sign mojibake is a UTF-8-encoded U+FFFD, not a raw latin-1 byte - it survives latin-1 decode unfixed", {
  # A34 finding (reported, not silently patched - normalise_lab_text()'s fix
  # table lives outside this adapter's ownership): the real file's only
  # non-ASCII bytes here are `EF BF BD` (valid UTF-8 for U+FFFD), not a
  # single raw latin-1 high byte. Decoding those 3 bytes under the pinned
  # latin-1 locale (CONTRACT A34/A35) yields three separate Latin-1
  # characters ("ï¿½"), which does not match any
  # `normalise_lab_text()` substitution (those match a literal single
  # U+FFFD or specific 0xA1-derived mojibake) - so it passes through
  # unfixed. This differs from what REAL-FIXTURES.md's general "raw
  # 0xB0/0xB5 bytes are untouched" note implies for this specific cell.
  meta <- sampleTidy:::file_meta(xtab_real_path)
  out <- xtab_adapter()$parse(xtab_real_path, meta)
  ec_rows <- out$results[grepl("Conductivity", out$results$analyte_raw), ]
  expect_equal(nrow(ec_rows), 2) # only samples 002/003 have a value; 001 is "----"
  expect_true(all(ec_rows$analyte_raw == "Electrical Conductivity @ 25ï¿½C"))
  expect_true(all(ec_rows$units_raw == "ï¿½S/cm"))
})

test_that("R-5.1 (real XTAB): ir_validate() passes", {
  meta <- sampleTidy:::file_meta(xtab_real_path)
  out <- xtab_adapter()$parse(xtab_real_path, meta)
  expect_silent(sampleTidy:::ir_validate(out$results, kind = "results"))
  expect_silent(sampleTidy:::ir_validate(out$samples, kind = "samples"))
})

# ---- R-5.1 shared parser: real ENMRG (ES2537534_0_ENMRG.CSV) -----------------
#
# One `Client - Matrix: WATER` section, 7 REG samples (ES2537534001-007), 27
# distinct analytes (27 x 7 = 189 cells; 19 are "----", 170 are values). The
# file also carries a trailing "QC - Matrix:" reconciliation block (its own
# ALS-Sample-number row reuses the SAME 7 columns for unrelated QC/other-
# work-order samples, plus dozens more) that this adapter deliberately does
# not parse (see README.md) - so this fixture is, from the adapter's
# perspective, "no QC column", matching REAL-FIXTURES.md's description.
# Because ENMRG is genuinely UTF-8 (unlike XTAB's legacy bytes), its own
# degree-sign/micro-sign characters are already correct - no mojibake fix
# needed.

test_that("R-5.1 (real ENMRG): results count = analytes x samples minus '----' skips, no QC rows", {
  meta <- sampleTidy:::file_meta(enmrg_real_path)
  out <- enmrg_adapter()$parse(enmrg_real_path, meta)
  expect_equal(length(unique(out$results$analyte_raw)), 27)
  expect_equal(nrow(out$results), 170)
  expect_equal(nrow(out$report$skipped), 19)
  expect_true(all(out$report$skipped$reason == "not_computable"))
  expect_setequal(names(out$report$n_by_sample_type), "Normal")
  expect_equal(unname(out$report$n_by_sample_type[["Normal"]]), 170)
})

test_that("R-5.1 (real ENMRG): samples - 7 rows, correct feature codes, matrix, REG type", {
  meta <- sampleTidy:::file_meta(enmrg_real_path)
  out <- enmrg_adapter()$parse(enmrg_real_path, meta)
  expect_equal(nrow(out$samples), 7)
  expect_setequal(
    out$samples$feature_raw,
    c("Q.MW02", "Q.MW08", "Q.MW09", "Q.S01", "Q.S03", "Q.S05", "Q.S06")
  )
  expect_true(all(out$samples$matrix_raw == "WATER"))
  expect_true(all(out$samples$sample_datetime_raw == "26/11/2025"))
  expect_true(all(out$samples$sample_type == "Normal"))
  expect_true(all(out$samples$work_order == "ES2537534"))
})

test_that("R-5.1 (real ENMRG): 'Units'/'LOR' header spellings read correctly, no mojibake (genuine UTF-8)", {
  meta <- sampleTidy:::file_meta(enmrg_real_path)
  out <- enmrg_adapter()$parse(enmrg_real_path, meta)
  ec_rows <- out$results[grepl("Conductivity", out$results$analyte_raw), ]
  expect_equal(nrow(ec_rows), 7)
  expect_true(all(ec_rows$analyte_raw == "Electrical Conductivity @ 25°C"))
  expect_true(all(ec_rows$units_raw == "µS/cm"))
  expect_true(all(!is.na(ec_rows$rl) & ec_rows$rl == 1))
})

test_that("R-5.1 (real ENMRG): ir_validate() passes", {
  meta <- sampleTidy:::file_meta(enmrg_real_path)
  out <- enmrg_adapter()$parse(enmrg_real_path, meta)
  expect_silent(sampleTidy:::ir_validate(out$results, kind = "results"))
  expect_silent(sampleTidy:::ir_validate(out$samples, kind = "samples"))
})

# ---- R-5.1: synthetic two-section fixture -------------------------------------

test_that("R-5.1 (synthetic): two-section fixture - rows carry their own section's matrix and date", {
  meta <- sampleTidy:::file_meta(two_section_path)
  out <- xtab_adapter()$parse(two_section_path, meta)
  expect_equal(nrow(out$results), 3)
  expect_equal(nrow(out$samples), 3)

  water_samples <- out$samples[out$samples$lab_sample_id %in%
    c("XX1234567001", "XX1234567002"), ]
  expect_true(all(water_samples$matrix_raw == "WATER"))
  expect_true(all(water_samples$sample_datetime_raw == "24/05/2025"))

  soil_samples <- out$samples[out$samples$lab_sample_id == "XX1234567003", ]
  expect_equal(nrow(soil_samples), 1)
  expect_identical(soil_samples$matrix_raw, "SOIL")
  expect_identical(soil_samples$sample_datetime_raw, "25/05/2025")

  expect_true(all(out$samples$work_order == "XX1234567"))
  expect_silent(sampleTidy:::ir_validate(out$results, kind = "results"))
  expect_silent(sampleTidy:::ir_validate(out$samples, kind = "samples"))
})

test_that("R-5.2 (synthetic): .xlsx XTAB twin matches format and parses without error", {
  meta <- sampleTidy:::file_meta(test_path("fixtures", "crosstab", "XX1234567_0_XTAB.xlsx"))
  expect_identical(xtab_adapter()$match(meta), "format")
  out <- xtab_adapter()$parse(test_path("fixtures", "crosstab", "XX1234567_0_XTAB.xlsx"), meta)
  expect_equal(nrow(out$results), 3)
  expect_equal(nrow(out$samples), 3)
})

# ---- R-5.1: synthetic ENMRG QC fixture -----------------------------------------

test_that("R-5.1 (synthetic): ENMRG QC sample columns emitted (not dropped), counted by sample_type", {
  meta <- sampleTidy:::file_meta(enmrg_qc_path)
  out <- enmrg_adapter()$parse(enmrg_qc_path, meta)
  expect_equal(nrow(out$results), 6)

  lcs_rows <- out$results[out$results$sample_type == "LCS", ]
  mb_rows  <- out$results[out$results$sample_type == "MB", ]
  expect_equal(nrow(lcs_rows), 2) # pH 7.00, Fluoride 0.5 - both valid
  expect_equal(nrow(mb_rows), 1) # EC 600 - the only valid MB cell

  expect_true(all(c("LCS", "MB", "Normal") %in% names(out$report$n_by_sample_type)))
  expect_equal(unname(out$report$n_by_sample_type[["LCS"]]), 2)
  expect_equal(unname(out$report$n_by_sample_type[["MB"]]), 1)
  expect_equal(unname(out$report$n_by_sample_type[["Normal"]]), 3)

  # QC samples are still emitted as `samples` rows, just with no
  # feature/site of their own (the file never carries one for them).
  qc_samples <- out$samples[out$samples$sample_type %in% c("LCS", "MB"), ]
  expect_equal(nrow(qc_samples), 2)
  expect_true(all(is.na(qc_samples$feature_raw)))

  skipped <- out$report$skipped
  expect_equal(nrow(skipped), 3)
  expect_equal(sum(skipped$reason == "not_computable"), 1)
  expect_equal(sum(skipped$reason == "empty"), 2)

  expect_silent(sampleTidy:::ir_validate(out$results, kind = "results"))
  expect_silent(sampleTidy:::ir_validate(out$samples, kind = "samples"))
})

# ---- R-5.1: d/m/y date parsing -------------------------------------------------

test_that("R-5.1: d/m/y - '05/01/2026' Sample Date is kept verbatim and parses as 5 January", {
  meta <- sampleTidy:::file_meta(mismatch_path)
  out <- xtab_adapter()$parse(mismatch_path, meta)
  expect_true(all(out$samples$sample_datetime_raw == "05/01/2026"))
  parsed <- sampleTidy:::parse_lab_datetime("05/01/2026", formats = "crosstab")
  expect_equal(as.integer(format(parsed, "%m")), 1L)
  expect_equal(as.integer(format(parsed, "%d")), 5L)
  expect_equal(as.integer(format(parsed, "%Y")), 2026L)
})

# ---- R-5.3 filename robustness -----------------------------------------------

test_that("R-5.3: Workgroup cell wins over filename guess on mismatch, with a warning", {
  meta <- sampleTidy:::file_meta(mismatch_path) # filename says ZZ9999999
  out <- xtab_adapter()$parse(mismatch_path, meta)
  expect_true(all(out$results$work_order == "XX1234567"))
  expect_true(length(out$report$warnings) >= 1)
  expect_true(any(grepl("ZZ9999999", out$report$warnings) & grepl("XX1234567", out$report$warnings)))
  expect_silent(sampleTidy:::ir_validate(out$results, kind = "results"))
  expect_silent(sampleTidy:::ir_validate(out$samples, kind = "samples"))
})

# ---- PLAN-12 R-12.3: crosstab no-silent-drops (F8) ----------------------
#
# Two silent-drop paths get a `report$warnings` entry instead: an
# unsupported (foreign) section marker followed by orphaned rows with no
# fresh recognised marker, and an analyte header reached with zero
# sample_cols because the "ALS Sample Number" label was misspelled. Neither
# changes what IS parsed - the existing two-section (WATER+SOIL) fixture
# must keep parsing identically with zero new warnings (regression, below).
# Per the brief's fixture list, only R-12.8 needs committed fixture files;
# these two build their input in-test.

# Write a minimal XTAB-dialect CSV grid (list of row character-vectors,
# comma-joined, CRLF-terminated, ASCII-safe) to a tempfile whose cleanup is
# bound to the CALLING test's frame (language-footguns.md: never let a
# helper own its own tempfile's cleanup frame - thread `envir` through
# explicitly rather than relying on `withr`'s default `parent.frame()`,
# which would bind to this helper's own (already-returned) frame instead).
write_xtab_grid <- function(rows, envir) {
  max_cols <- max(vapply(rows, length, integer(1)))
  pad_row <- function(r) {
    if (length(r) >= max_cols) r[seq_len(max_cols)] else c(r, rep("", max_cols - length(r)))
  }
  lines <- vapply(rows, function(r) paste(pad_row(r), collapse = ","), character(1))
  text <- paste0(paste(lines, collapse = "\r\n"), "\r\n")
  path <- withr::local_tempfile(fileext = ".csv", .local_envir = envir)
  con <- file(path, open = "wb")
  writeBin(charToRaw(text), con)
  close(con)
  path
}

test_that("R-12.3: foreign section marker + orphaned rows (no fresh marker) get a report$warnings entry naming the row range", {
  rows <- list(
    c("Matrix:", "WATER", "", "Sample Type:", "", "REG"),
    c("Workgroup:", "YY6543210", "", "ALS Sample Number:", "", "YY6543210001"),
    c("Project name/number:", "Test Project A", "", "Sample Date:", "", "24/05/2025"),
    c("", "", "", "Client sample ID (1st):", "", "T.S01"),
    c("", "", "", "", "", ""),
    c("Analyte grouping/Analyte", "CAS Number", "Unit", "Limit of reporting", "", ""),
    c("", "", "", "", "", ""),
    c("EA005P: pH by PC Titrator", "", "", "", "", ""),
    c("pH Value", "", "pH Unit", "0.01", "", "6.40"), # row 9: real WATER-section result
    c("QC - Matrix:", "OTHERWO", "", "", "", ""),      # row 10: foreign marker (not "^Matrix:")
    c("Some Orphan Analyte", "", "", "", "", "9.99"),  # row 11: would-be data, no fresh marker
    c("Another Orphan Analyte", "", "", "", "", "1.23") # row 12: ditto
  )
  path <- write_xtab_grid(rows, environment())
  meta <- sampleTidy:::file_meta(path)
  out <- xtab_adapter()$parse(path, meta)

  # What IS parsed is unaffected: the one real WATER-section result survives.
  expect_equal(nrow(out$results), 1)
  expect_identical(out$results$value_raw, "6.40")

  # PROVISIONAL ORACLE: R-12.3 - the plan pins only "record one
  # report$warnings entry (with the row range)", not exact wording. This
  # asserts the one concrete, plan-derivable fact: the entry names row 10
  # (1-based), where the foreign "QC - Matrix:" marker was hit.
  expect_true(length(out$report$warnings) >= 1)
  expect_true(any(grepl("\\b10\\b", out$report$warnings)))
})

test_that("R-12.3: misspelled 'ALS Sample Number' label warns instead of silently emitting a zero-row section", {
  rows <- list(
    c("Matrix:", "WATER", "", "Sample Type:", "", "REG"),
    c("Workgroup:", "YZ2223334", "", "ALS Smaple Number:", "", "YZ2223334001"), # typo: "Smaple"
    c("Project name/number:", "Test Project A", "", "Sample Date:", "", "24/05/2025"),
    c("", "", "", "Client sample ID (1st):", "", "T.S01"),
    c("", "", "", "", "", ""),
    c("Analyte grouping/Analyte", "CAS Number", "Unit", "Limit of reporting", "", ""),
    c("", "", "", "", "", ""),
    c("EA005P: pH by PC Titrator", "", "", "", "", ""),
    c("pH Value", "", "pH Unit", "0.01", "", "6.40")
  )
  path <- write_xtab_grid(rows, environment())
  meta <- sampleTidy:::file_meta(path)
  out <- xtab_adapter()$parse(path, meta)

  # Unchanged: sample_cols never got populated (the label never matched), so
  # the analyte row is misclassified as a method-group row - zero results,
  # zero samples, zero skips.
  expect_equal(nrow(out$results), 0)
  expect_equal(nrow(out$samples), 0)
  expect_equal(nrow(out$report$skipped), 0)

  # PROVISIONAL ORACLE: R-12.3 - exact wording unpinned by the plan; asserts
  # the one concrete, plan-derivable fact: the warning names the section (its
  # Matrix: value, "WATER" - the only well-defined section identifier this
  # parser tracks in scope at the header row).
  expect_true(length(out$report$warnings) >= 1)
  expect_true(any(grepl("WATER", out$report$warnings, fixed = TRUE)))
})

test_that("R-12.3: existing two-section (WATER+SOIL) fixture still parses identically - no new spurious warning", {
  meta <- sampleTidy:::file_meta(two_section_path)
  out <- xtab_adapter()$parse(two_section_path, meta)
  expect_equal(nrow(out$results), 3)
  expect_equal(nrow(out$samples), 3)
  expect_identical(out$report$warnings, character(0))
})

# ---- PLAN-12 R-12.8: crosstab match() robustness (F14) -------------------
#
# match()'s dialect-marker peek currently reads only file_meta()'s fixed
# first-2048-byte window. Two ways a real (very wide) crosstab defeats that:
# a `Workgroup:` cell past byte 2048, and a UTF-8 BOM on line 1 (which
# decodes, under the peek's latin-1 locale, as 3 extra leading characters
# that defeat `^Matrix:`). Fixtures: `WK7654321_0_XTAB.csv`,
# `BM1122334_0_XTAB.csv` (fixtures/crosstab/README.md).

test_that("R-12.8: dialect marker (Workgroup:) past file_meta()'s 2KiB peek window still match()es", {
  meta <- sampleTidy:::file_meta(test_path("fixtures", "crosstab", "WK7654321_0_XTAB.csv"))
  expect_identical(xtab_adapter()$match(meta), "format")
})

test_that("R-12.8: UTF-8 BOM on line 1 does not defeat match()", {
  meta <- sampleTidy:::file_meta(test_path("fixtures", "crosstab", "BM1122334_0_XTAB.csv"))
  expect_identical(xtab_adapter()$match(meta), "format")
})

test_that("R-12.8: SpreadsheetML .XLS (A37) still returns match() == 'no' after the peek hardening", {
  meta <- sampleTidy:::file_meta(xtab_xls_path)
  expect_identical(xtab_adapter()$match(meta), "no")
  expect_identical(enmrg_adapter()$match(meta), "no")
})
