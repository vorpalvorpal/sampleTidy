# Lab-method resolution by method CODE (2026-10-21 review, methods finding).
#
# Two defects, one symptom: total and dissolved methods for the same analyte
# share `uuid_analyte`, so when `.rc_lab_method_candidates()` fails to narrow
# by method the lowest uuid wins and a TOTAL reading is filed under the
# DISSOLVED method (or vice versa).
#
# 1. Newer ALS ESdat exports prefix `Method_Name` with the method code:
#    "ED093T - ED093T: Total Major Cations" where the registry holds
#    "ED093T: Total Major Cations". The canonical text is the part from the
#    LAST " - " before the FIRST colon. A row with no colon at all
#    ("EN67 - Client Supplied Data") is left as-is. The adapter must strip
#    the prefix, AND the resolver must tolerate it (held review payloads
#    already carry prefixed text).
# 2. Narrowing ran only with >= 2 candidates, and kept ALL candidates when
#    nothing survived. Required: whenever `method_raw` is non-NA and has a
#    colon, narrow by the folded full key; if none survive, by the folded
#    method code (text before the first colon - this absorbs "NEPM 2013
#    Fraction" vs "Fractions"); if still none, NO candidates (a miss). NA or
#    colon-less `method_raw`: exactly today's behaviour.
#
# Registry strings below are the live ALS ones. Within each fixture the
# WRONG method is given the lexically LOWER uuid, so the buggy "keep all,
# lowest uuid wins" fallback picks it and the test fails for that reason.
#
# Sodium Adsorption Ratio under "ED093F: SAR and Hardness Calculations"
# follows Robin's 2026-10-22 ruling (its own lab_method; see the end).

mk_row <- function(...) {
  defaults <- list(
    source_hash = "hash-1", source_ref = "row1", work_order = "XX1234567",
    revision = 0L, org = "ALS", adapter = "esdat/1",
    lab_sample_id = "XX1234567001", sample_type = "Normal",
    feature_raw = "T.S01", analyte_raw = "Fluoride",
    cas_number = "16984-48-8", method_raw = "EK040P: Fluoride by PC Titrator",
    total_or_filtered = "T", units_raw = "mg/L", value_raw = "<0.1",
    value_num = 0.1, value_chr = NA_character_, below_detection = TRUE,
    rl = 0.1, lab_qualifier = NA_character_, analysed_date = as.Date("2025-05-26"),
    comments = NA_character_, confidence = 1,
    sample_datetime_raw = "24 May 2025 11:45", sampler = NA_character_,
    matrix_raw = "WATER", parent_sample = NA_character_
  )
  tibble::as_tibble(utils::modifyList(defaults, list(...)))
}

mk_event <- function(results, work_order = "XX1234567", orphan = FALSE) {
  list(
    work_order = work_order, orphan = orphan, results = results,
    samples = tibble::tibble(),
    files = tibble::tibble(hash = character(), filename = character(),
                           adapter = character(), rank = integer(), kept = logical()),
    report = list(n_results = nrow(results), n_by_sample_type = list(),
                  n_ncp_foreign = 0L,
                  skipped = tibble::tibble(hash = character(), source_ref = character(),
                                          reason = character()),
                  warnings = character())
  )
}

# Seed DB + the cation / hydrocarbon / surrogate methods. Returns the con.
lmc_seed <- function(env = parent.frame()) {
  path <- seed_db()
  con <- seed_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE), envir = env)
  DBI::dbExecute(con, "INSERT INTO analyte (uuid, name, units, type, CAS) VALUES
    ('a-mg', 'Magnesium', 'mg/L', 'cation', NULL),
    ('a-ca', 'Calcium', 'mg/L', 'cation', NULL),
    ('a-c6', 'C6 - C10 Fraction', 'µg/L', 'hydrocarbon', NULL),
    ('a-ddE', 'Dibromo-DDE', '%', 'surrogate', NULL)")
  DBI::dbExecute(con, "INSERT INTO lab_method
    (uuid, uuid_analyte, name, method, organisation, units) VALUES
    -- Magnesium: the DISSOLVED method sorts first (the buggy pick for a TOTAL row)
    ('lm-mg-1-F', 'a-mg', 'Magnesium', 'ED093F: Dissolved Major Cations', 'ALS', 'mg/L'),
    ('lm-mg-2-T', 'a-mg', 'Magnesium', 'ED093T: Total Major Cations', 'ALS', 'mg/L'),
    -- Calcium: the TOTAL method sorts first (the buggy pick for a DISSOLVED row)
    ('lm-ca-1-T', 'a-ca', 'Calcium', 'ED093T: Total Major Cations', 'ALS', 'mg/L'),
    ('lm-ca-2-F', 'a-ca', 'Calcium', 'ED093F: Dissolved Major Cations', 'ALS', 'mg/L'),
    -- C6-C10: the EP080-UT method sorts first
    ('lm-c6-1-UT', 'a-c6', 'C6 - C10 Fraction', 'EP080-UT / EP071-SD: Total Recoverable Hydrocarbons', 'ALS', 'µg/L'),
    ('lm-c6-2-NEPM', 'a-c6', 'C6 - C10 Fraction', 'EP080/071: Total Recoverable Hydrocarbons - NEPM 2013 Fractions', 'ALS', 'µg/L'),
    -- Dibromo-DDE: ONE candidate, under a different method code
    ('lm-dde-068', 'a-ddE', 'Dibromo-DDE', 'EP068S: Organochlorine Pesticide Surrogate', 'ALS', '%')")
  con
}

resolve <- function(con, analyte, method) {
  sampleTidy:::.rc_resolve_one_analyte(analyte, "ALS", method, sampleTidy:::.rc_load_registry(con))
}

# ---- (a) adapter strips the ESdat code prefix --------------------------------

lmc_chem_header <- c(
  "SampleCode", "ChemCode", "OriginalChemName", "Prefix", "Result",
  "Result_Unit", "Total_or_Filtered", "Result_Type", "Method_Type",
  "Method_Name", "Extraction_Date", "Analysed_Date", "EQL", "EQL_Units",
  "Comments", "Lab_Qualifier", "UCL", "LCL"
)

lmc_parse_methods <- function(methods) {
  d <- withr::local_tempdir(.local_envir = parent.frame())
  p <- file.path(d, "PROJ_A.ESDAT_XX1234567_0.Chemistry2e.CSV")
  rows <- sprintf(
    "XX1234567001,,Analyte%02d,,1.0,mg/L,T,Numeric,x,%s,26 May 2025,26 May 2025,0.1,mg/L,,,,",
    seq_along(methods), methods
  )
  writeLines(c(paste(lmc_chem_header, collapse = ","), rows), p, useBytes = TRUE)
  out <- sampleTidy:::adapter_registry()[["esdat"]]$parse(p, sampleTidy:::file_meta(p))
  res <- out$results
  res$method_raw[match(sprintf("Analyte%02d", seq_along(methods)), res$analyte_raw)]
}

test_that("the ESdat adapter strips the method-code prefix from Method_Name (keep from the LAST ' - ' before the FIRST colon)", {
  got <- lmc_parse_methods(c(
    "ED093T - ED093T: Total Major Cations",
    "ED093F - ED093F: Dissolved Major Cations",
    "EP080 - EP080/071: Total Recoverable Hydrocarbons - NEPM 2013 Fraction",
    "EN055 - PG - EN055: Ionic Balance",
    "EA025H - EA025: Total Suspended Solids",
    "ED093F - EA065: Total Hardness as CaCO3"
  ))
  expect_identical(got, c(
    "ED093T: Total Major Cations",
    "ED093F: Dissolved Major Cations",
    # a ' - ' AFTER the first colon is part of the description, not a prefix
    "EP080/071: Total Recoverable Hydrocarbons - NEPM 2013 Fraction",
    # two prefixes: keep from the LAST ' - ' before the colon
    "EN055: Ionic Balance",
    # the prefix code need not equal the body code
    "EA025: Total Suspended Solids",
    "EA065: Total Hardness as CaCO3"
  ))
})

test_that("the ESdat adapter leaves un-prefixed and colon-less Method_Name verbatim", {
  methods <- c(
    "EN67 - Client Supplied Data",                              # no colon: as-is
    "ED093T: Total Major Cations",                              # already canonical
    "EP080-UT / EP071-SD: Total Recoverable Hydrocarbons",      # hyphens without spaces
    "EP071: Total Recoverable Hydrocarbons - NEPM 2013 Fractions" # ' - ' only after colon
  )
  expect_identical(lmc_parse_methods(methods), methods)
})

# ---- (a)+(b) resolver: prefixed text, full key, then code --------------------

test_that("Magnesium under prefixed 'ED093T - ED093T: Total Major Cations' resolves to the TOTAL method, not the lower-uuid DISSOLVED one", {
  con <- lmc_seed()
  res <- resolve(con, "Magnesium", "ED093T - ED093T: Total Major Cations")
  expect_identical(res$status, "resolved")
  expect_identical(res$uuid_analyte, "a-mg")
  expect_identical(res$uuid_lab, "lm-mg-2-T")
})

test_that("Calcium under 'ED093F: Dissolved Major Cations' (prefixed or not) resolves to the DISSOLVED method, not the lower-uuid TOTAL one", {
  con <- lmc_seed()
  # Case-varied analyte name so the exact-match branch cannot fire and the
  # folded path is the one under test.
  for (m in c("ED093F - ED093F: Dissolved Major Cations", "ED093F: Dissolved Major Cations")) {
    res <- resolve(con, "CALCIUM", m)
    expect_identical(res$status, "resolved", label = m)
    expect_identical(res$uuid_lab, "lm-ca-2-F", label = m)
  }
})

test_that("C6-C10 under 'EP080 - EP080/071: ... NEPM 2013 Fraction' resolves to the EP080/071 method by CODE ('Fraction' vs registry 'Fractions'), not the lower-uuid EP080-UT one", {
  con <- lmc_seed()
  for (m in c("EP080 - EP080/071: Total Recoverable Hydrocarbons - NEPM 2013 Fraction",
              "EP080/071: Total Recoverable Hydrocarbons - NEPM 2013 Fraction",
              "EP080 - EP080/071: Total Petroleum Hydrocarbons")) {
    res <- resolve(con, "C6 - C10 Fraction", m)
    expect_identical(res$status, "resolved", label = m)
    expect_identical(res$uuid_analyte, "a-c6", label = m)
    expect_identical(res$uuid_lab, "lm-c6-2-NEPM", label = m)
  }
})

test_that(".rc_lab_method_candidates() narrows to the code-matching candidate(s) only", {
  con <- lmc_seed()
  reg <- sampleTidy:::.rc_load_registry(con)
  cand <- sampleTidy:::.rc_lab_method_candidates(
    "Magnesium", "ALS", "ED093T - ED093T: Total Major Cations", reg)
  expect_identical(cand$uuid, "lm-mg-2-T")
  cand <- sampleTidy:::.rc_lab_method_candidates(
    "C6 - C10 Fraction", "ALS", "EP080/071: Total Recoverable Hydrocarbons - NEPM 2013 Fraction", reg)
  expect_identical(cand$uuid, "lm-c6-2-NEPM")
})

# ---- (b) no candidate survives -> NO candidates (a miss) ---------------------

test_that("a SINGLE candidate under a different method code is not a hit: the row is a miss", {
  con <- lmc_seed()
  reg <- sampleTidy:::.rc_load_registry(con)
  # Today: one candidate -> narrowing skipped -> resolved to EP068S.
  expect_equal(nrow(sampleTidy:::.rc_lab_method_candidates(
    "Dibromo-DDE", "ALS", "EP131S: OC Pesticide Surrogate", reg)), 0)
  res <- resolve(con, "Dibromo-DDE", "EP131S: OC Pesticide Surrogate")
  expect_identical(res$status, "miss")
  expect_true(is.na(res$uuid_lab))
  expect_true(is.na(res$uuid_analyte))
})

test_that("several candidates, none matching the method code: NO candidates, not all of them", {
  con <- lmc_seed()
  reg <- sampleTidy:::.rc_load_registry(con)
  expect_equal(nrow(sampleTidy:::.rc_lab_method_candidates(
    "Magnesium", "ALS", "EG020T: Total Metals by ICP-MS", reg)), 0)
  expect_identical(resolve(con, "Magnesium", "EG020A-T - EG020T: Total Metals by ICP-MS")$status, "miss")
})

test_that("end to end: a code-mismatched row with a known CAS rides the known_analyte_no_method path, pending, with no uuid_lab", {
  con <- lmc_seed()
  # Fluoride has two seeded ALS methods (EK040P / EK040T), both a-0002, and
  # the seeded CAS. Today the unmatched method keeps both and resolves to
  # lm-0002. XX1234567002 = T.S02, a fresh sample (FIXTURES.md), so the row
  # reaches `clean` rather than meeting committed history.
  out <- reconcile_event(mk_event(mk_row(
    source_ref = "r1", lab_sample_id = "XX1234567002", feature_raw = "T.S02",
    analyte_raw = "FLUORIDE", value_raw = "2.3", value_num = 2.3, below_detection = FALSE,
    method_raw = "ZZ999 - ZZ999: Fluoride by wishing"
  )), con)
  hit <- out$clean[out$clean$source_ref == "r1", ]
  expect_equal(nrow(hit), 1)
  expect_true(hit$analyte_pending)
  expect_true(is.na(hit$uuid_lab))
  rv <- out$review[out$review$kind == "unknown_analyte" & out$review$source_ref == "r1", ]
  expect_equal(nrow(rv), 1)
  expect_identical(rv$subkind, "known_analyte_no_method")
})

# ---- (c) NA / colon-less method_raw: today's behaviour -----------------------

test_that("NA method_raw: unchanged - candidates are not narrowed; same-analyte pair resolves to the lowest uuid; a single candidate resolves", {
  con <- lmc_seed()
  res <- resolve(con, "Magnesium", NA_character_)
  expect_identical(res$status, "resolved")
  expect_identical(res$uuid_lab, "lm-mg-1-F")
  res <- resolve(con, "Dibromo-DDE", NA_character_)
  expect_identical(res$status, "resolved")
  expect_identical(res$uuid_lab, "lm-dde-068")
})

test_that("colon-less method_raw: unchanged - no code narrowing, no miss", {
  con <- lmc_seed()
  # Single candidate, colon-less non-matching method: still a hit.
  res <- resolve(con, "Dibromo-DDE", "EN67 - Client Supplied Data")
  expect_identical(res$status, "resolved")
  expect_identical(res$uuid_lab, "lm-dde-068")
  # Two candidates, nothing matches the full key: all kept, lowest uuid.
  res <- resolve(con, "Magnesium", "EN67 - Client Supplied Data")
  expect_identical(res$status, "resolved")
  expect_identical(res$uuid_lab, "lm-mg-1-F")
  # Two candidates, the colon-less text matches one by folded full key:
  # narrowed to it, and the ' - ' is NOT treated as a code prefix.
  DBI::dbExecute(con, "INSERT INTO lab_method (uuid, uuid_analyte, name, method, organisation) VALUES
    ('lm-mg-3-EN67', 'a-mg', 'Magnesium', 'EN67 - Client Supplied Data', 'ALS')")
  res <- resolve(con, "MAGNESIUM", "en67 - client supplied data")
  expect_identical(res$status, "resolved")
  expect_identical(res$uuid_lab, "lm-mg-3-EN67")
})

# ---- SAR (Robin's ruling, 2026-10-22) ----------------------------------------
# ALS's SAR under "ED093F: SAR and Hardness Calculations" gets its OWN SAR
# lab_method with that method text (migration 069). Normal narrowing then
# picks it; until it exists the row is a miss - never a fallback onto the
# EA006 SAR method.

lmc_seed_sar <- function(con, with_ed093f) {
  DBI::dbExecute(con, "INSERT INTO analyte (uuid, name, units, type, CAS) VALUES
    ('a-sar', 'Sodium Adsorption Ratio', '1', 'calculated', NULL)")
  DBI::dbExecute(con, "INSERT INTO lab_method (uuid, uuid_analyte, name, method, organisation, units) VALUES
    ('lm-sar-1-EA006', 'a-sar', 'Sodium Adsorption Ratio', 'EA006: Sodium Adsorption Ratio (SAR)', 'ALS', '1')")
  if (with_ed093f) {
    DBI::dbExecute(con, "INSERT INTO lab_method (uuid, uuid_analyte, name, method, organisation, units) VALUES
      ('lm-sar-2-ED093F', 'a-sar', 'Sodium Adsorption Ratio', 'ED093F: SAR and Hardness Calculations', 'ALS', '1')")
  }
}

test_that("SAR under 'ED093F: SAR and Hardness Calculations' resolves to the ED093F SAR lab_method when the registry has one, not the lower-uuid EA006 one", {
  con <- lmc_seed()
  lmc_seed_sar(con, with_ed093f = TRUE)
  # Case-varied name forces the folded path (the exact branch would hit the
  # unprefixed text on its own).
  for (m in c("ED093F: SAR and Hardness Calculations",
              "ED093F - ED093F: SAR and Hardness Calculations")) {
    res <- resolve(con, "SODIUM ADSORPTION RATIO", m)
    expect_identical(res$status, "resolved", label = m)
    expect_identical(res$uuid_analyte, "a-sar", label = m)
    expect_identical(res$uuid_lab, "lm-sar-2-ED093F", label = m)
  }
})

test_that("SAR under 'ED093F: SAR and Hardness Calculations' is a MISS when the registry has only the EA006 SAR method - no fallback onto EA006", {
  con <- lmc_seed()
  lmc_seed_sar(con, with_ed093f = FALSE)
  res <- resolve(con, "Sodium Adsorption Ratio", "ED093F: SAR and Hardness Calculations")
  expect_identical(res$status, "miss")
  expect_true(is.na(res$uuid_lab))
  # control: the EA006 text still resolves to the EA006 method
  res <- resolve(con, "Sodium Adsorption Ratio", "EA006: Sodium Adsorption Ratio (SAR)")
  expect_identical(res$uuid_lab, "lm-sar-1-EA006")
})
