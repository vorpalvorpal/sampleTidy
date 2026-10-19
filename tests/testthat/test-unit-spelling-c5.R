# C5 end-to-end: ESdat unit spellings through adapter -> reconcile_event().

c5_row_from_parse <- function(lines, analyte, ...) {
  d <- withr::local_tempdir(.local_envir = parent.frame())
  p <- file.path(d, "PROJ_A.ESDAT_XX1234567_0.Chemistry2e.CSV")
  hdr <- c("SampleCode", "ChemCode", "OriginalChemName", "Prefix", "Result",
           "Result_Unit", "Total_or_Filtered", "Result_Type", "Method_Type",
           "Method_Name", "Extraction_Date", "Analysed_Date", "EQL", "EQL_Units",
           "Comments", "Lab_Qualifier", "UCL", "LCL")
  writeLines(c(paste(hdr, collapse = ","), lines), p, useBytes = TRUE)
  parsed <- sampleTidy:::adapter_registry()[["esdat"]]$parse(p, sampleTidy:::file_meta(p))$results
  r <- parsed[parsed$analyte_raw == analyte, ]
  stopifnot(nrow(r) == 1L)
  # sample XX1234567002 / T.S02 has no seeded analysis, so rows land in `clean`
  tibble::as_tibble(utils::modifyList(
    list(
      source_hash = "hash-1", source_ref = "r1", work_order = "XX1234567",
      revision = 0L, org = "ALS", adapter = "esdat/1",
      lab_sample_id = "XX1234567002", sample_type = "Normal", feature_raw = "T.S02",
      analyte_raw = r$analyte_raw, cas_number = r$cas_number,
      method_raw = r$method_raw, total_or_filtered = "T", units_raw = r$units_raw,
      value_raw = r$value_raw, value_num = r$value_num, value_chr = r$value_chr,
      below_detection = r$below_detection, rl = r$rl, lab_qualifier = NA_character_,
      analysed_date = as.Date("2025-05-26"), comments = NA_character_, confidence = 1,
      sample_datetime_raw = "24 May 2025 11:45", sampler = NA_character_,
      matrix_raw = "WATER", parent_sample = NA_character_
    ), list(...)
  ))
}

c5_event <- function(row) {
  list(
    work_order = "XX1234567", orphan = FALSE, results = row, samples = tibble::tibble(),
    files = tibble::tibble(hash = character(), filename = character(),
                           adapter = character(), rank = integer(), kept = logical()),
    report = list(n_results = nrow(row), n_by_sample_type = list(), n_ncp_foreign = 0L,
                  skipped = tibble::tibble(hash = character(), source_ref = character(),
                                          reason = character()),
                  warnings = character())
  )
}

c5_seed <- function() {
  path <- seed_db()
  con <- seed_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE), envir = parent.frame())
  DBI::dbExecute(con, "INSERT INTO analyte (uuid, name, units, type, CAS) VALUES
    ('a-c501', 'Escherichia coli', 'CFU/mL', 'micro', NULL),
    ('a-c502', 'Sodium Adsorption Ratio', '1', 'calc', NULL)")
  DBI::dbExecute(con, "INSERT INTO lab_method
    (uuid, uuid_analyte, name, method, organisation, rl_low, units, conversion_constant) VALUES
    ('lm-c501', 'a-c501', 'Escherichia coli', 'MB: E coli', 'ALS', NULL, 'CFU/mL', NULL),
    ('lm-c502', 'a-c502', 'Sodium Adsorption Ratio', 'ED: SAR', 'ALS', NULL, '1', NULL)")
  con
}

ecoli_line <- function(prefix, val) {
  sprintf("XX1234567002,,Escherichia coli,%s,%s,CFU/100mL,T,Numeric,MB,MB: E coli,26 May 2025,26 May 2025,1,CFU/100mL,,,,", prefix, val)
}

test_that("C5 e2e: ESdat 'Escherichia coli 6500 CFU/100mL' reconciles to value 65 in CFU/mL, no unknown_unit", {
  con <- c5_seed()
  row <- c5_row_from_parse(ecoli_line("", "6500"), "Escherichia coli")
  out <- reconcile_event(c5_event(row), con)
  expect_false("unknown_unit" %in% out$review$kind)
  got <- out$clean[out$clean$source_ref == "r1", ]
  expect_equal(nrow(got), 1)
  expect_equal(got$value_converted, 65, tolerance = 1e-9)
})

test_that("C5 e2e: '<1 CFU/100mL' reconciles to rl/value 0.01 with quantified FALSE, no unknown_unit", {
  con <- c5_seed()
  row <- c5_row_from_parse(ecoli_line("<", "1"), "Escherichia coli")
  out <- reconcile_event(c5_event(row), con)
  expect_false("unknown_unit" %in% out$review$kind)
  got <- out$clean[out$clean$source_ref == "r1", ]
  expect_equal(nrow(got), 1)
  expect_false(got$quantified)
  expect_equal(got$rl_converted, 0.01, tolerance = 1e-9)
})

test_that("C5 e2e: ESdat SAR row with Result_Unit '-' reconciles with no review item", {
  con <- c5_seed()
  row <- c5_row_from_parse(
    "XX1234567002,,Sodium Adsorption Ratio,,0.5,-,T,Numeric,SAR,ED: SAR,26 May 2025,26 May 2025,,,,,,",
    "Sodium Adsorption Ratio"
  )
  out <- reconcile_event(c5_event(row), con)
  expect_equal(nrow(out$review[out$review$source_ref == "r1", ]), 0)
  got <- out$clean[out$clean$source_ref == "r1", ]
  expect_equal(nrow(got), 1)
  expect_equal(got$value_converted, 0.5, tolerance = 1e-9)
})

test_that("C5 e2e: '-' on a mg/L analyte still raises unknown_unit (control)", {
  con <- c5_seed()
  row <- c5_row_from_parse(
    "XX1234567002,16984-48-8,Fluoride,,2.3,-,T,Numeric,Fluoride by PC Titrator,EK040P: Fluoride by PC Titrator,26 May 2025,26 May 2025,0.1,mg/L,,,,",
    "Fluoride"
  )
  out <- reconcile_event(c5_event(row), con)
  hit <- out$review[out$review$source_ref == "r1", ]
  expect_equal(nrow(hit), 1)
  expect_identical(hit$kind, "unknown_unit")
})

test_that("C5 e2e: an unlisted CFU spelling still raises unknown_unit (control)", {
  con <- c5_seed()
  row <- c5_row_from_parse(ecoli_line("", "6500"), "Escherichia coli")
  row$units_raw <- "MPN/100mL"
  out <- reconcile_event(c5_event(row), con)
  hit <- out$review[out$review$source_ref == "r1", ]
  expect_equal(hit$kind, "unknown_unit")
})
