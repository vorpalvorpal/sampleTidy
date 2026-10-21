# tests/testthat/test-esdat-placeholders.R
#
# 2026-10-21 review-queue triage, fix A (scratchpad/2026-10-21-review/FIXES.md):
# ESdat Chemistry2e rows whose Result is a PLACEHOLDER and whose real meaning is
# in Comments, plus the "11 Feb 2025 15:00" Sampled_Date_Time form.
#
# Real evidence (2020-era ALS "BLAXLAND INCIDENT" deliveries; rows are
# re-created here synthetically under the fixture work order XX1234567 - no
# real sample, QC or work-order codes):
#   * ES2008702-003/-014 HPC 36C: Result 1, EQL 1, Comments "NR" (not reported).
#     Committed as the value 1 CFU/mL today (units slice, pattern D).
#   * ES2013803-007, ES2017584-008..011 Coliforms: Result 1, EQL 1,
#     Comments "~<2" / "~<10". Migration 066 (decision 23) stored these as
#     non-detects: value = N in the stored unit, quantified FALSE, rl_low = the
#     EQL, comments kept verbatim - "as ES2013803-008's '<10' is stored", whose
#     source row is Prefix "<", Result 10, EQL 1.
#
# Representation pinned here:
#   * "NR": the row is DROPPED from `results` and recorded in
#     `report$skipped` (source_ref + a reason naming "NR"). `report$n_rows`
#     still counts every data row in the file, so the drop is never silent.
#   * "~<N": emitted exactly as if the lab had written Prefix "<", Result N -
#     value_raw "<N", value_num N, below_detection TRUE, rl = the EQL column
#     (unchanged), units_raw the source Result_Unit, comments verbatim.

esdat_adapter <- function() {
  sampleTidy:::adapter_registry()[["esdat"]]
}

ph_chem_header <- c(
  "SampleCode", "ChemCode", "OriginalChemName", "Prefix", "Result",
  "Result_Unit", "Total_or_Filtered", "Result_Type", "Method_Type",
  "Method_Name", "Extraction_Date", "Analysed_Date", "EQL", "EQL_Units",
  "Comments", "Lab_Qualifier", "UCL", "LCL"
)
ph_sample_header <- c(
  "SampleCode", "Sampled_Date_Time", "Field_ID", "Blank1", "Depth", "Blank2",
  "Matrix_Type", "Sample_Type", "Parent_Sample", "Blank3", "SDG", "Lab_Name",
  "Lab_SampleID", "Lab_Comments", "Lab_Report_Number"
)

ph_write <- function(dir, kind, header, rows) {
  p <- file.path(dir, paste0("PROJ_P.ESDAT_XX1234567_0.", kind, ".CSV"))
  writeLines(c(paste(header, collapse = ","), rows), p, useBytes = TRUE)
  p
}

ph_parse_chem <- function(rows, envir = parent.frame()) {
  d <- withr::local_tempdir(.local_envir = envir)
  p <- ph_write(d, "Chemistry2e", ph_chem_header, rows)
  esdat_adapter()$parse(p, sampleTidy:::file_meta(p))
}

# Synthetic rows modelled byte-for-byte on the real ones' shape (18 fields).
row_hpc_nr <- paste0(
  "XX1234567003,PLATE_COUNT_36oC,Heterotrophic Plate Count (36C),,1,CFU/mL,T,REG,",
  "Heterotrophic (Total) Plate Count @ 22C and 36C,MW002: Heterotrophic Plate Count,",
  ",13-Mar-20,1,CFU/mL,NR,,,"
)
row_hpc_22 <- paste0(
  "XX1234567003,PLATE_COUNT_22oC,Heterotrophic Plate Count (22C),,78000,CFU/mL,T,REG,",
  "Heterotrophic (Total) Plate Count @ 22C and 36C,MW002: Heterotrophic Plate Count,",
  ",13-Mar-20,1,CFU/mL,Result value is an approximate. ,,,"
)
row_coli <- function(code, comment) {
  paste0(
    code, ",Coliform,Coliforms,,1,CFU/100mL,T,REG,Coliforms by Membrane Filtration,",
    "MW007: Coliforms by MF,,22-May-20,1,CFU/100mL,", comment, ",,,"
  )
}
row_coli_lt10 <- paste0(
  "XX1234567008,Coliform,Coliforms,<,10,CFU/100mL,T,REG,Coliforms by Membrane Filtration,",
  "MW007: Coliforms by MF,,24-Apr-20,1,CFU/100mL,,,,"
)
row_coli_count <- paste0(
  "XX1234567009,Coliform,Coliforms,,340,CFU/100mL,T,REG,Coliforms by Membrane Filtration,",
  "MW007: Coliforms by MF,,24-Apr-20,1,CFU/100mL,,,,"
)
row_fluoride <- paste0(
  "XX1234567001,16984-48-8,Fluoride,,2.3,mg/L,T,REG,Fluoride by PC Titrator,",
  "EK040P: Fluoride by PC Titrator,,26-May-25,0.1,mg/L,,,,"
)

# ---- 1. Sampled_Date_Time "11 Feb 2025 15:00" -------------------------------

test_that("A1: '11 Feb 2025 15:00' and '08-May-20 10:17' both parse to Sydney local times", {
  x <- c("11 Feb 2025 15:00", "08-May-20 10:17")
  want <- as.POSIXct(c("2025-02-11 15:00", "2020-05-08 10:17"), tz = "Australia/Sydney")
  for (fmts in list("esdat", sampleTidy:::.rc_datetime_formats,
                    sampleTidy:::.st_join_datetime_formats)) {
    got <- sampleTidy:::parse_lab_datetime(x, fmts)
    expect_equal(as.numeric(got), as.numeric(want))
    expect_identical(attr(got, "tzone"), "Australia/Sydney")
  }
})

test_that("A1: reconcile's datetime step keeps the clock time for both ESdat forms", {
  rows <- tibble::tibble(
    source_ref = c("row1", "row2"), source_hash = "h",
    sample_datetime_raw = c("11 Feb 2025 15:00", "08-May-20 10:17")
  )
  out <- sampleTidy:::.rc_resolve_datetime(rows)
  expect_equal(nrow(out$review), 0)
  expect_equal(out$kept$sample_date, as.Date(c("2025-02-11", "2020-05-08")))
  expect_equal(
    as.numeric(out$kept$sample_datetime),
    as.numeric(as.POSIXct(c("2025-02-11 15:00", "2020-05-08 10:17"), tz = "Australia/Sydney"))
  )
})

test_that("A1: a Sample2e '11 Feb 2025 15:00' reaches the assembled results row", {
  d <- withr::local_tempdir()
  chem <- ph_write(d, "Chemistry2e", ph_chem_header, row_fluoride)
  smp <- ph_write(d, "Sample2e", ph_sample_header, paste0(
    "XX1234567001,11 Feb 2025 15:00,T.S01,,,,WATER,Normal,,13 Feb 2025,",
    "ALSE-Sydney 12 Feb 2025,ALSE-Sydney,XX1234567001,,XX1234567"
  ))
  parsed <- list()
  for (f in c(chem, smp)) {
    m <- sampleTidy:::file_meta(f)
    o <- esdat_adapter()$parse(f, m)
    parsed[[m$hash]] <- list(ir = list(results = o$results, samples = o$samples),
                             report = o$report, meta = m)
  }
  ev <- sampleTidy:::assemble_events(parsed)$events
  expect_length(ev, 1)
  r <- ev[[1]]$results
  expect_identical(r$sample_datetime_raw, "11 Feb 2025 15:00")
  got <- sampleTidy:::.rc_resolve_datetime(r)$kept$sample_datetime
  expect_equal(as.numeric(got),
               as.numeric(as.POSIXct("2025-02-11 15:00", tz = "Australia/Sydney")))
})

# ---- 2. Comments "NR" -> not a committable value ----------------------------

test_that("A2: a Chemistry2e row with Comments 'NR' is not emitted as a result", {
  out <- ph_parse_chem(c(row_hpc_22, row_hpc_nr))
  res <- out$results
  expect_false(any(res$analyte_raw == "Heterotrophic Plate Count (36C)"))
  expect_false(any(!is.na(res$comments) & trimws(res$comments) == "NR"))
  # the sibling analyte on the same sample is untouched
  expect_equal(sum(res$analyte_raw == "Heterotrophic Plate Count (22C)"), 1)
})

test_that("A2: the dropped 'NR' row is recorded in report$skipped, never silently lost", {
  out <- ph_parse_chem(c(row_hpc_22, row_hpc_nr))
  expect_equal(out$report$n_rows, 2)
  sk <- out$report$skipped
  expect_identical(sk$source_ref, "row2")
  expect_match(sk$reason, "NR")
  expect_equal(nrow(out$results) + nrow(sk), out$report$n_rows)
  expect_silent(sampleTidy:::ir_validate(out$results, kind = "results"))
})

test_that("A2: 'NR' is matched as the whole (trimmed) Comments value, not a substring", {
  row_other <- sub(",NR,,,$", ",Sample NRA-labelled,,,", row_hpc_nr)
  out <- ph_parse_chem(c(row_other, sub(",NR,,,$", ", NR ,,,", row_hpc_nr)))
  expect_equal(nrow(out$results), 1)
  expect_identical(out$results$comments, "Sample NRA-labelled")
  expect_identical(out$results$value_raw, "1")
})

# ---- 3. Comments "~<N" -> non-detect <N -------------------------------------

test_that("A3: Comments '~<2' / '~<10' with Result 1 are emitted as non-detects <2 / <10", {
  out <- ph_parse_chem(c(
    row_coli("XX1234567010", "~<2"),
    row_coli("XX1234567011", "~<10")
  ))
  res <- out$results
  expect_equal(nrow(res), 2)
  a <- res[res$lab_sample_id == "XX1234567010", ]
  b <- res[res$lab_sample_id == "XX1234567011", ]
  expect_identical(a$value_raw, "<2")
  expect_identical(b$value_raw, "<10")
  expect_equal(a$value_num, 2)
  expect_equal(b$value_num, 10)
  expect_true(isTRUE(a$below_detection))
  expect_true(isTRUE(b$below_detection))
  expect_identical(res$units_raw, c("CFU/100mL", "CFU/100mL"))
  # quantified FALSE, the way every '<' value_raw is read downstream
  pv <- sampleTidy:::parse_value(res$value_raw)
  expect_identical(pv$quantified, c(FALSE, FALSE))
  expect_equal(pv$rl_low, c(2, 10))
  # comments carried verbatim (066 kept them)
  expect_identical(a$comments, "~<2")
  expect_identical(b$comments, "~<10")
  expect_silent(sampleTidy:::ir_validate(res, kind = "results"))
})

test_that("A3: a '~<N' row has the same shape as a lab-written '<N' row", {
  out <- ph_parse_chem(c(row_coli_lt10, row_coli("XX1234567011", "~<10")))
  res <- out$results
  real <- res[res$lab_sample_id == "XX1234567008", ]
  tilde <- res[res$lab_sample_id == "XX1234567011", ]
  for (col in c("value_raw", "value_num", "value_chr", "below_detection", "rl",
                "units_raw", "analyte_raw", "method_raw")) {
    expect_identical(tilde[[col]], real[[col]], info = col)
  }
  expect_equal(tilde$rl, 1) # the EQL column, as for the lab-written '<10'
})

# ---- 4. Normal rows unaffected ---------------------------------------------

test_that("A4: ordinary rows (plain count, lab '<', approximate-comment, numeric) are unchanged", {
  rows <- c(row_coli_count, row_coli_lt10, row_hpc_22, row_fluoride)
  out <- ph_parse_chem(rows)
  res <- out$results
  expect_equal(nrow(res), 4)
  expect_equal(nrow(out$report$skipped), 0)
  expect_identical(res$value_raw, c("340", "<10", "78000", "2.3"))
  expect_equal(res$value_num, c(340, 10, 78000, 2.3))
  expect_identical(res$below_detection, c(FALSE, TRUE, FALSE, FALSE))
  expect_equal(res$rl, c(1, 1, 1, 0.1))
  expect_identical(res$comments, c(NA, NA, "Result value is an approximate.", NA))
})

test_that("A4: a Result-1 row with no placeholder comment stays a quantified 1", {
  row_one <- sub(",NR,,,$", ",,,,", row_hpc_nr)
  out <- ph_parse_chem(row_one)
  expect_equal(nrow(out$results), 1)
  expect_identical(out$results$value_raw, "1")
  expect_equal(out$results$value_num, 1)
  expect_false(out$results$below_detection)
})
