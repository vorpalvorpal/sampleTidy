# Plan 08 - R/reconcile.R: the reconciler.
#
# `reconcile_event(event, con)` -> `list(clean, review, skipped, counts)`.
# Read-only against the DB - no writes here (commit is plan 09).
#
# Per the pipeline-tests brief, events are built directly with the plan-07
# pinned shape (R-7.5) rather than by routing real files through adapters -
# this keeps these tests independent of plans 04-07's implementation status.
# The DB is the throwaway `seed_db()` (tests/testthat/helper-db.R), seeded
# with exactly the rows pinned in dev/plans/FIXTURES.md.

# ---- local helpers ------------------------------------------------------

#' Build one already-assembled `event$results` row (IR columns + the
#' plan-07 R-7.3 joined sample columns). Defaults to the FIXTURES.md
#' "Fluoride <0.1 mg/L" row (T.S01, work order XX1234567) so most tests only
#' override what they care about.
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
  args <- utils::modifyList(defaults, list(...))
  tibble::as_tibble(args)
}

mk_rows <- function(...) dplyr::bind_rows(...)

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

count_core_rows <- function(con) {
  tables <- c("feature", "feature_mask", "analyte", "lab_method", "project", "sample", "analysis")
  vapply(tables, function(t) {
    DBI::dbGetQuery(con, sprintf('SELECT count(*) AS n FROM "%s"', t))$n
  }, numeric(1))
}

# ---- R-8.1: QC filter ----------------------------------------------------

test_that("R-8.1: LCS/MB rows are skipped with reasons qc_LCS/qc_MB and counts match", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  event <- mk_event(mk_rows(
    mk_row(source_ref = "r1", sample_type = "LCS"),
    mk_row(source_ref = "r2", sample_type = "MB")
  ))
  out <- reconcile_event(event, con)
  expect_equal(nrow(out$skipped[out$skipped$reason == "qc_LCS", ]), 1)
  expect_equal(nrow(out$skipped[out$skipped$reason == "qc_MB", ]), 1)
  expect_equal(unname(out$counts[["qc_LCS"]]), 1)
  expect_equal(unname(out$counts[["qc_MB"]]), 1)
})

test_that("R-8.1: unknown sample_type rows are not skipped", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  event <- mk_event(mk_row(source_ref = "r1", sample_type = "unknown", value_raw = "2.3",
                           value_num = 2.3, below_detection = FALSE, rl = 0.1))
  out <- reconcile_event(event, con)
  expect_false("r1" %in% out$skipped$source_ref[grepl("^qc_", out$skipped$reason)])
})

test_that("R-8.1: an NCP row, if somehow present, is still skipped as QC-like (defensive)", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  event <- mk_event(mk_row(source_ref = "r1", sample_type = "NCP"))
  out <- reconcile_event(event, con)
  expect_identical(out$skipped$reason[out$skipped$source_ref == "r1"], "qc_NCP")
})

# ---- R-8.2: feature resolution -------------------------------------------

test_that("R-8.2: direct feature name resolves", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # Fresh date (no seeded analysis at f-0001/20 May) so the row lands in `clean`
  # to expose its resolved uuid_feature; the default 24-May row is the seeded
  # already_present row (FIXTURES.md), which R-8.7 covers separately.
  event <- mk_event(mk_row(source_ref = "r1", feature_raw = "T.S01",
                           sample_datetime_raw = "20 May 2025 09:00"))
  out <- reconcile_event(event, con)
  expect_identical(out$clean$uuid_feature[out$clean$source_ref == "r1"], "f-0001")
})

test_that("R-8.2: mask alias resolves to the masked feature's uuid", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # Fresh date (no seeded analysis at f-0001/20 May) so the mask-resolved row
  # lands in `clean`; the default 24-May row is seeded already_present.
  event <- mk_event(mk_row(source_ref = "r1", feature_raw = "Test Surface 01",
                           sample_datetime_raw = "20 May 2025 09:00"))
  out <- reconcile_event(event, con)
  expect_identical(out$clean$uuid_feature[out$clean$source_ref == "r1"], "f-0001")
})

test_that("R-8.2: a typo feature queues one grouped review item covering all its rows", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  event <- mk_event(mk_rows(
    mk_row(source_ref = "r1", feature_raw = "T.S0l", lab_sample_id = "XX1234567004"),
    mk_row(source_ref = "r2", feature_raw = "T.S0l", lab_sample_id = "XX1234567004", analyte_raw = "pH Value")
  ))
  out <- reconcile_event(event, con)
  unknown_feature <- out$review[out$review$kind == "unknown_feature", ]
  expect_equal(nrow(unknown_feature), 1)
  expect_true(all(c("r1", "r2") %in% strsplit(unknown_feature$payload[[1]], ",")[[1]]) ||
                grepl("r1", unknown_feature$payload[[1]]) && grepl("r2", unknown_feature$payload[[1]]))
})

test_that("R-8.2: an ambiguous feature name queues review listing both candidate uuids", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  event <- mk_event(mk_row(source_ref = "r1", feature_raw = "AMBIG"))
  out <- reconcile_event(event, con)
  ambiguous <- out$review[out$review$kind == "unknown_feature" & out$review$source_ref == "r1", ]
  expect_equal(nrow(ambiguous), 1)
  expect_true(grepl("f-0002", ambiguous$payload[[1]]) && grepl("f-0003", ambiguous$payload[[1]]))
})

test_that("R-8.2: no fuzzy matching - a Levenshtein-1 miss stays unknown_feature", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # "T.S011" is one insertion away from "T.S01" - must NOT auto-resolve
  event <- mk_event(mk_row(source_ref = "r1", feature_raw = "T.S011"))
  out <- reconcile_event(event, con)
  expect_equal(nrow(out$review[out$review$kind == "unknown_feature" & out$review$source_ref == "r1", ]), 1)
  expect_false("r1" %in% out$clean$source_ref)
})

test_that("R-8.2: a NA feature_raw is unknown (never a phantom hit into clean) - A44", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # Regression: a missing feature_raw once produced a phantom single NA
  # candidate (x[NA] -> NA -> unique() collapses to length 1), which was
  # mis-read as a "hit" and kept in clean with uuid_feature = NA - an orphan
  # sample/analysis at commit. It must go to review, and never to clean, and
  # never be silently dropped (R-8.8 completeness).
  event <- mk_event(mk_row(source_ref = "r1", feature_raw = NA_character_))
  out <- reconcile_event(event, con)
  expect_false("r1" %in% out$clean$source_ref)
  expect_true("r1" %in% out$review$source_ref)
  in_review <- "r1" %in% out$review$source_ref
  in_skipped <- "r1" %in% out$skipped$source_ref
  in_clean <- "r1" %in% out$clean$source_ref
  expect_equal(sum(in_review, in_skipped, in_clean), 1) # exactly one disposition
})

# ---- R-8.3: analyte / method resolution ----------------------------------

test_that("R-8.3: org-scoped analyte name hit resolves", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # Fresh sample (T.S02, no seeded analysis) so the resolved uuid_lab/uuid_analyte
  # are inspectable in `clean` (FIXTURES.md: XX1234567002 = T.S02).
  event <- mk_event(mk_row(source_ref = "r1", analyte_raw = "Fluoride", org = "ALS",
                           feature_raw = "T.S02", lab_sample_id = "XX1234567002",
                           method_raw = "EK040P: Fluoride by PC Titrator"))
  out <- reconcile_event(event, con)
  expect_identical(out$clean$uuid_lab[out$clean$source_ref == "r1"], "lm-0002")
  expect_identical(out$clean$uuid_analyte[out$clean$source_ref == "r1"], "a-0002")
})

test_that("R-8.3: the same name under a different org does not cross-resolve", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # lm-0005 is "pH" under ACIRL; asking for "pH" under ALS must not match it
  event <- mk_event(mk_row(source_ref = "r1", analyte_raw = "pH", org = "ALS",
                           cas_number = NA_character_, units_raw = "pH"))
  out <- reconcile_event(event, con)
  expect_false("r1" %in% out$clean$source_ref)
  expect_true(any(out$review$source_ref == "r1" & out$review$kind == "unknown_analyte"))
})

test_that("R-8.3: CAS fallback finds the analyte but still queues (known_analyte_no_method)", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # No lab_method row for (Fluoride, Internal); CAS 16984-48-8 -> a-0002 exists
  event <- mk_event(mk_row(source_ref = "r1", analyte_raw = "Fluoride", org = "Internal",
                           cas_number = "16984-48-8", method_raw = NA_character_))
  out <- reconcile_event(event, con)
  hit <- out$review[out$review$source_ref == "r1", ]
  expect_equal(nrow(hit), 1)
  expect_identical(hit$kind, "unknown_analyte")
  expect_true(grepl("known_analyte_no_method", hit$payload[[1]]) || grepl("known_analyte_no_method", paste(hit, collapse = " ")))
})

test_that("R-8.3: a full analyte miss queues grouped by (analyte_raw, org)", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  event <- mk_event(mk_rows(
    mk_row(source_ref = "r1", analyte_raw = "Nonexistentite", org = "ALS", cas_number = NA_character_),
    mk_row(source_ref = "r2", analyte_raw = "Nonexistentite", org = "ALS", cas_number = NA_character_)
  ))
  out <- reconcile_event(event, con)
  grouped <- out$review[out$review$kind == "unknown_analyte" &
                           grepl("Nonexistentite", out$review$payload), ]
  expect_equal(nrow(grouped), 1)
})

# ---- R-8.4: units & value -------------------------------------------------

test_that("R-8.4: mg/L to ug/L multiplies value and rl by 1000", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # T.S02 = a fresh sample (no seeded analysis) so the row lands in `clean`,
  # isolating the unit conversion from R-8.7 (FIXTURES.md: XX1234567002 = T.S02).
  event <- mk_event(mk_row(source_ref = "r1", lab_sample_id = "XX1234567002",
                           feature_raw = "T.S02",
                           value_raw = "2.3", value_num = 2.3, below_detection = FALSE,
                           rl = 0.1, units_raw = "mg/L"))
  out <- reconcile_event(event, con)
  row <- out$clean[out$clean$source_ref == "r1", ]
  expect_equal(nrow(row), 1)
  expect_equal(row$value_converted, 2300, tolerance = 1e-9)
  expect_equal(row$rl_converted, 100, tolerance = 1e-9)
})

test_that("R-8.4: pH (dimensionless) passes unit resolution", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  event <- mk_event(mk_row(source_ref = "r1", analyte_raw = "pH Value", org = "ALS",
                           method_raw = "EA005P: pH by PC Titrator", units_raw = "pH Unit",
                           value_raw = "6.40", value_num = 6.40, below_detection = FALSE,
                           rl = NA_real_, cas_number = NA_character_,
                           lab_sample_id = "XX1234567001"))
  out <- reconcile_event(event, con)
  row <- out$clean[out$clean$source_ref == "r1", ]
  expect_equal(nrow(row), 1)
  expect_equal(row$value_converted, 6.40, tolerance = 1e-9)
})

test_that("R-8.4: an invalid unit string queues unknown_unit", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  event <- mk_event(mk_row(source_ref = "r1", units_raw = "banana/L"))
  out <- reconcile_event(event, con)
  hit <- out$review[out$review$source_ref == "r1", ]
  expect_equal(nrow(hit), 1)
  expect_identical(hit$kind, "unknown_unit")
})

test_that("R-8.4: an NS row lands in skipped, not review", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  event <- mk_event(mk_row(source_ref = "r1", value_raw = "NS", value_num = NA_real_,
                           value_chr = NA_character_, below_detection = NA, rl = NA_real_))
  out <- reconcile_event(event, con)
  expect_false("r1" %in% out$review$source_ref)
  expect_identical(out$skipped$reason[out$skipped$source_ref == "r1"], "no_sample")
})

test_that("R-8.4: a BDL row keeps quantified FALSE with a converted rl", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # <0.2 mg/L Fluoride at T.S02 - a fresh sample (no seeded an-0001 collision),
  # so it's inspectable directly in `clean` (isolated from R-8.7 logic).
  # FIXTURES.md: XX1234567002 = T.S02.
  event <- mk_event(mk_row(source_ref = "r1", lab_sample_id = "XX1234567002",
                           feature_raw = "T.S02",
                           value_raw = "<0.2", value_num = 0.2, below_detection = TRUE,
                           rl = 0.2, units_raw = "mg/L"))
  out <- reconcile_event(event, con)
  row <- out$clean[out$clean$source_ref == "r1", ]
  expect_equal(nrow(row), 1)
  expect_false(row$quantified)
  expect_equal(row$rl_converted, 200, tolerance = 1e-9)
})

test_that("R-8.4: text-only results pass through unconverted with quantified TRUE", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  event <- mk_event(mk_row(source_ref = "r1", analyte_raw = "pH Value", org = "ALS",
                           method_raw = "EA005P: pH by PC Titrator", units_raw = NA_character_,
                           value_raw = "Clear, low flow", value_num = NA_real_,
                           value_chr = "Clear, low flow", below_detection = NA,
                           rl = NA_real_, cas_number = NA_character_,
                           lab_sample_id = "XX1234567003"))
  out <- reconcile_event(event, con)
  row <- out$clean[out$clean$source_ref == "r1", ]
  expect_equal(nrow(row), 1)
  expect_true(row$quantified)
})

# ---- R-8.5: sample datetime -----------------------------------------------

test_that("R-8.5: an ESdat-format datetime yields both sample_date and sample_datetime", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # T.S02 = a fresh sample so the row lands in `clean` (FIXTURES.md:
  # XX1234567002 = T.S02); keeps the ESdat datetime under test.
  event <- mk_event(mk_row(source_ref = "r1", feature_raw = "T.S02", lab_sample_id = "XX1234567002",
                           sample_datetime_raw = "24 May 2025 11:45"))
  out <- reconcile_event(event, con)
  row <- out$clean[out$clean$source_ref == "r1", ]
  expect_equal(nrow(row), 1)
  expect_equal(row$sample_date, as.Date("2025-05-24"))
  expect_false(is.na(row$sample_datetime))
})

test_that("R-8.5: a crosstab-format (date-only) datetime yields date only", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # T.S02 = a fresh sample so the row lands in `clean` (FIXTURES.md:
  # XX1234567002 = T.S02); keeps the crosstab date-only value under test.
  event <- mk_event(mk_row(source_ref = "r1", lab_sample_id = "XX1234567002",
                           feature_raw = "T.S02",
                           value_raw = "2.3", value_num = 2.3, below_detection = FALSE,
                           sample_datetime_raw = "24/05/2025"))
  out <- reconcile_event(event, con)
  row <- out$clean[out$clean$source_ref == "r1", ]
  expect_equal(nrow(row), 1)
  expect_equal(row$sample_date, as.Date("2025-05-24"))
  expect_true(is.na(row$sample_datetime))
})

test_that("R-8.5: a garbage datetime queues a parse_error", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  event <- mk_event(mk_row(source_ref = "r1", sample_datetime_raw = "not a date"))
  out <- reconcile_event(event, con)
  hit <- out$review[out$review$source_ref == "r1", ]
  expect_equal(nrow(hit), 1)
  expect_identical(hit$kind, "parse_error")
})

# ---- R-8.6: method preference ---------------------------------------------

test_that("R-8.6: the duplicate-method pair keeps the lower-RL row", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # Both rows at T.S02 = a fresh sample, so the method-preference winner lands
  # in `clean` (FIXTURES.md: XX1234567002 = T.S02), isolating R-8.6 from R-8.7.
  event <- mk_event(mk_rows(
    mk_row(source_ref = "r1", lab_sample_id = "XX1234567002", feature_raw = "T.S02", method_raw = "EK040P: Fluoride by PC Titrator",
           value_raw = "2.3", value_num = 2.3, below_detection = FALSE, rl = 0.1),
    mk_row(source_ref = "r2", lab_sample_id = "XX1234567002", feature_raw = "T.S02", method_raw = "EK040T: Fluoride by alt method",
           value_raw = "2.5", value_num = 2.5, below_detection = FALSE, rl = 0.5)
  ))
  out <- reconcile_event(event, con)
  expect_true("r1" %in% out$clean$source_ref)
  expect_false("r2" %in% out$clean$source_ref)
  dup <- out$skipped[out$skipped$source_ref == "r2", ]
  expect_identical(dup$reason, "method_duplicate")
  expect_true(grepl("lm-0002", dup$reason) || grepl("lm-0002", paste(dup, collapse = " ")))
})

test_that("R-8.6: a tied rl_low keeps the higher value", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  # Supplement the seed with a second ALS Fluoride method tied on rl_low
  # (FIXTURES.md only pins one duplicate-method pair, which isn't tied - see
  # dev/plans/PLAN-CHANGE-REQUESTS.md for context on why this is added here
  # rather than in helper-db.R).
  DBI::dbExecute(con, "INSERT INTO lab_method (uuid, uuid_analyte, name, method, organisation, rl_low) VALUES
    ('lm-0002b', 'a-0002', 'Fluoride', 'EK040P: Fluoride by PC Titrator (tie)', 'ALS', 0.1)")

  # Both rows at T.S02 = a fresh sample (FIXTURES.md: XX1234567002 = T.S02),
  # so the tie-break winner lands in `clean`, isolating R-8.6 from R-8.7.
  event <- mk_event(mk_rows(
    mk_row(source_ref = "r1", lab_sample_id = "XX1234567002", feature_raw = "T.S02", method_raw = "EK040P: Fluoride by PC Titrator",
           value_raw = "2.3", value_num = 2.3, below_detection = FALSE, rl = 0.1),
    mk_row(source_ref = "r2", lab_sample_id = "XX1234567002", feature_raw = "T.S02", method_raw = "EK040P: Fluoride by PC Titrator (tie)",
           value_raw = "2.9", value_num = 2.9, below_detection = FALSE, rl = 0.1)
  ))
  out <- reconcile_event(event, con)
  expect_true("r2" %in% out$clean$source_ref)
  expect_false("r1" %in% out$clean$source_ref)
})

# ---- R-8.7: three-way outcome vs DB ----------------------------------------

test_that("R-8.7: a fresh row is new/clean", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # T.S02 = a fresh sample with no seeded analysis (FIXTURES.md:
  # XX1234567002 = T.S02) -> genuinely new, supersedes NA.
  event <- mk_event(mk_row(source_ref = "r1", lab_sample_id = "XX1234567002",
                           feature_raw = "T.S02",
                           value_raw = "2.3", value_num = 2.3, below_detection = FALSE, rl = 0.1))
  out <- reconcile_event(event, con)
  row <- out$clean[out$clean$source_ref == "r1", ]
  expect_equal(nrow(row), 1)
  expect_true(is.na(row$supersedes))
})

test_that("R-8.7: an identical re-ingest row is already_present", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # exactly the FIXTURES.md pinned "<0.1 mg/L" row - converts to 100 ug/L,
  # matching seeded an-0001 (value 100, quantified FALSE)
  event <- mk_event(mk_row(source_ref = "r1"))
  out <- reconcile_event(event, con)
  hit <- out$skipped[out$skipped$source_ref == "r1", ]
  expect_equal(nrow(hit), 1)
  expect_identical(hit$reason, "already_present")
})

test_that("R-8.7: a value differing at 1e-12 relative is already_present (tolerance)", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # 0.1 + 1e-13 mg/L -> ~100 + 1e-10 ug/L, well within A14 tolerance vs 100
  event <- mk_event(mk_row(source_ref = "r1", value_raw = "<0.1000000000001",
                           value_num = 0.1 + 1e-13, rl = 0.1 + 1e-13))
  out <- reconcile_event(event, con)
  hit <- out$skipped[out$skipped$source_ref == "r1", ]
  expect_equal(nrow(hit), 1)
  expect_identical(hit$reason, "already_present")
})

test_that("R-8.7: a value differing at 1e-3 relative is a conflict", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # 0.1001 mg/L -> 100.1 ug/L vs existing 100: 1e-3 relative, exceeds A14
  event <- mk_event(mk_row(source_ref = "r1", value_raw = "<0.1001",
                           value_num = 0.1001, rl = 0.1001))
  out <- reconcile_event(event, con)
  expect_false("r1" %in% out$clean$source_ref[is.na(out$clean$supersedes[out$clean$source_ref == "r1"])])
  hit <- out$review[out$review$source_ref == "r1", ]
  expect_equal(nrow(hit), 1)
  expect_identical(hit$kind, "value_conflict")
})

test_that("R-8.7: conflict with recorded revision 0 and incoming revision 1 becomes a supersede row", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # T.S01 Fluoride changed to 0.3 mg/L, incoming revision 1 > recorded 0
  # (seeded ingest_file legacy-hash-XX, work_order XX1234567, revision 0)
  event <- mk_event(mk_row(source_ref = "r1", revision = 1L, value_raw = "0.3",
                           value_num = 0.3, below_detection = FALSE, rl = 0.1))
  out <- reconcile_event(event, con)
  row <- out$clean[out$clean$source_ref == "r1", ]
  expect_equal(nrow(row), 1)
  expect_identical(row$supersedes, "an-0001")
})

test_that("R-8.7: conflict with no recorded revision queues for review", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # A brand-new work order/project with no ingest_file or asset history at
  # all -> recorded revision is NA -> A12 "no recorded revision -> review",
  # regardless of the incoming revision value.
  DBI::dbExecute(con, "INSERT INTO project (uuid, name, type) VALUES ('p-0002', 'CD2222222', 'Work order')")
  DBI::dbExecute(con, "INSERT INTO \"sample\" (uuid, uuid_feature, uuid_project, date, organisation) VALUES
    ('s-0002', 'f-0002', 'p-0002', TIMESTAMP '2025-06-01 00:00:00', 'ALS')")
  DBI::dbExecute(con, "INSERT INTO analysis (uuid, uuid_sample, uuid_lab, value, quantified, rl_low) VALUES
    ('an-0002', 's-0002', 'lm-0003', 0.5, TRUE, 1)")

  event <- mk_event(mk_row(source_ref = "r1", work_order = "CD2222222", revision = 5L,
                           feature_raw = "T.S02", analyte_raw = "Electrical Conductivity @ 25°C",
                           cas_number = NA_character_, method_raw = "EA010P: Conductivity by PC Titrator",
                           units_raw = "µS/cm", value_raw = "600", value_num = 600,
                           below_detection = FALSE, rl = 1, sample_datetime_raw = "01/06/2025"))
  out <- reconcile_event(event, con)
  hit <- out$review[out$review$source_ref == "r1", ]
  expect_equal(nrow(hit), 1)
  expect_identical(hit$kind, "value_conflict")
})

test_that("R-8.7: equal values but different quantified is a conflict", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # existing an-0001: value 100, quantified FALSE. Incoming: a genuine
  # detected 0.1 mg/L (quantified TRUE) that converts to the same 100 ug/L.
  event <- mk_event(mk_row(source_ref = "r1", value_raw = "0.1", value_num = 0.1,
                           below_detection = FALSE, rl = NA_real_))
  out <- reconcile_event(event, con)
  expect_false("r1" %in% out$skipped$source_ref[out$skipped$reason == "already_present"])
  hit <- out$review[out$review$source_ref == "r1", ]
  expect_equal(nrow(hit), 1)
  expect_identical(hit$kind, "value_conflict")
})

# ---- R-8.8: output contract -------------------------------------------------

test_that("R-8.8: clean/review/skipped are disjoint and complete over a mixed event", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  event <- mk_event(mk_rows(
    mk_row(source_ref = "qc", sample_type = "LCS"),                                    # skipped: qc
    mk_row(source_ref = "unk_feature", feature_raw = "T.S0l"),                          # review: unknown_feature
    mk_row(source_ref = "unk_analyte", analyte_raw = "Nonexistentite", cas_number = NA_character_), # review
    mk_row(source_ref = "bad_unit", units_raw = "banana/L"),                            # review: unknown_unit
    mk_row(source_ref = "ns_row", value_raw = "NS", value_num = NA_real_,
           value_chr = NA_character_, below_detection = NA, rl = NA_real_),             # skipped: no_sample
    mk_row(source_ref = "fresh", lab_sample_id = "XX1234567002", feature_raw = "T.S02", value_raw = "2.3",
           value_num = 2.3, below_detection = FALSE, rl = 0.1),                          # clean: new (T.S02, no seed)
    mk_row(source_ref = "present")                                                       # skipped: already_present
  ))
  out <- reconcile_event(event, con)

  all_refs <- c(out$clean$source_ref, out$review$source_ref, out$skipped$source_ref)
  input_refs <- event$results$source_ref
  expect_setequal(all_refs, input_refs)
  expect_equal(length(all_refs), length(input_refs))
  expect_equal(sum(duplicated(all_refs)), 0)
})

test_that("R-8.7/R-8.8: reconcile_event() is pure - DB row counts are unchanged after a run", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  before <- count_core_rows(con)
  event <- mk_event(mk_rows(
    mk_row(source_ref = "r1", lab_sample_id = "XX1234567002", value_raw = "2.3",
           value_num = 2.3, below_detection = FALSE, rl = 0.1),
    mk_row(source_ref = "r2", feature_raw = "AMBIG"),
    mk_row(source_ref = "r3", sample_type = "MB")
  ))
  invisible(reconcile_event(event, con))
  after <- count_core_rows(con)
  expect_equal(before, after)
})
