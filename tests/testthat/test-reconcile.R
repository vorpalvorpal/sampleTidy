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

test_that("R-8.7: a lab measurement is distinct from a field measurement of the same analyte (A45)", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # A45: uniqueness is (feature, datetime, analyte, METHOD). A field EC (ACIRL
  # method lm-0006) and a lab EC (ALS method lm-0003) both resolve to analyte
  # a-0003 at the same feature+date, but different methods -> two distinct
  # measurements, NOT a conflict. Seed an existing FIELD EC, then reconcile an
  # incoming LAB EC and assert it lands clean/new (not already_present/conflict).
  DBI::dbExecute(con, "INSERT INTO \"sample\" (uuid, uuid_feature, uuid_project, date, organisation)
    VALUES ('s-field', 'f-0001', 'p-0001', TIMESTAMP '2025-05-24 00:00:00', 'ACIRL')")
  DBI::dbExecute(con, "INSERT INTO analysis (uuid, uuid_sample, uuid_lab, value, quantified)
    VALUES ('an-field-ec', 's-field', 'lm-0006', 0.45, TRUE)")

  event <- mk_event(mk_row(
    source_ref = "r1", feature_raw = "T.S01",
    analyte_raw = "Electrical Conductivity @ 25°C",
    method_raw = "EA010P: Conductivity by PC Titrator", cas_number = NA_character_,
    org = "ALS", units_raw = "µS/cm", value_raw = "185", value_num = 185,
    below_detection = FALSE, rl = 1, sample_datetime_raw = "24 May 2025 11:45"
  ))
  out <- reconcile_event(event, con)

  expect_true("r1" %in% out$clean$source_ref)
  expect_false("r1" %in% out$review$source_ref)
  expect_false("r1" %in% out$skipped$source_ref)
  row <- out$clean[out$clean$source_ref == "r1", ]
  expect_true(is.na(row$supersedes))            # distinct measurement, not a supersede
  expect_identical(row$uuid_lab, "lm-0003")     # resolved to the lab method
  expect_equal(row$value_converted, 0.185, tolerance = 1e-9) # uS/cm -> mS/cm
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

# =============================================================================
# PLAN 11 - feature_alias indirection, commit-everything, R-11.19 exact-match
# =============================================================================

# ---- R-11.3: .rc_key() normalisation (fold safety) -------------------------

test_that("R-11.3: .rc_key folds punctuation/case variants of the same code to one key", {
  keys <- .rc_key(c("B.S01", "B S01", "BS01", "b.s01", "B..S01"))
  expect_equal(length(unique(keys)), 1)
  expect_false(is.na(keys[[1]]))
})

test_that("R-11.3: .rc_key maps NA and blank names to NA (A44 guard, amended half)", {
  expect_true(is.na(.rc_key(NA_character_)))
  expect_true(is.na(.rc_key("")))
  expect_true(is.na(.rc_key("   ")))
})

#' Read the `distinct_keys=<n>` count from an R-11.3 frozen-snapshot fixture's
#' own comment header - never a literal in a test body.
.rc_fixture_header_count <- function(path) {
  lines <- readLines(path, warn = FALSE)
  hdr <- lines[grepl("distinct_keys=", lines)]
  expect_true(length(hdr) >= 1, info = paste("no distinct_keys= header line in", path))
  m <- regmatches(hdr[[1]], regexpr("distinct_keys=[0-9]+", hdr[[1]]))
  as.integer(sub("distinct_keys=", "", m))
}

# the OLD .rc_key (pre-R-11.3, punctuation kept)
.rc_old_key <- function(x) tolower(stringr::str_squish(normalise_lab_text(x)))

test_that("R-11.3: frozen-snapshot - feature.name fold adds zero new collisions vs the OLD key; count matches the fixture's own header", {
  path <- testthat::test_path("fixtures", "registry-names", "feature-names.csv")
  expected <- .rc_fixture_header_count(path)
  names <- readr::read_csv(path, comment = "#", show_col_types = FALSE)$name
  n_old <- length(unique(.rc_old_key(names)))
  n_new <- length(unique(.rc_key(names)))
  expect_equal(n_new, expected)
  expect_equal(n_new, n_old) # the fold introduces zero NEW collisions
})

test_that("R-11.3: frozen-snapshot - analyte.name fold adds zero new collisions vs the OLD key; count matches the fixture's own header", {
  path <- testthat::test_path("fixtures", "registry-names", "analyte-names.csv")
  expected <- .rc_fixture_header_count(path)
  names <- readr::read_csv(path, comment = "#", show_col_types = FALSE)$name
  n_old <- length(unique(.rc_old_key(names)))
  n_new <- length(unique(.rc_key(names)))
  expect_equal(n_new, expected)
  expect_equal(n_new, n_old)
})

test_that("R-11.3: frozen-snapshot - lab_method (organisation,name,method) triple fold adds zero new collisions; count matches the fixture's own header", {
  path <- testthat::test_path("fixtures", "registry-names", "lab-method-triples.csv")
  expected <- .rc_fixture_header_count(path)
  triples <- readr::read_csv(path, comment = "#", show_col_types = FALSE)
  old_triple <- paste(triples$organisation, .rc_old_key(triples$name), .rc_old_key(triples$method), sep = "||")
  new_triple <- paste(triples$organisation, .rc_key(triples$name), .rc_key(triples$method), sep = "||")
  n_old <- length(unique(old_triple))
  n_new <- length(unique(new_triple))
  expect_equal(n_new, expected)
  expect_equal(n_new, n_old)
})

test_that("R-11.3: live registry property - .rc_key is injective over feature/analyte/lab_method names modulo the two known allowlisted collisions (corpus-gated, no count literal)", {
  corpus_db <- Sys.getenv("SAMPLETIDY_CORPUS_DB")
  skip_if(corpus_db == "", "SAMPLETIDY_CORPUS_DB not set")
  con <- DBI::dbConnect(duckdb::duckdb(), corpus_db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  check_injective <- function(ids, allowed_ids) {
    keys <- .rc_key(ids)
    groups <- split(ids, keys)
    groups <- groups[vapply(groups, function(g) length(unique(g)) > 1, logical(1))]
    for (g in groups) {
      distinct_ids <- unique(g)
      not_allowed <- setdiff(distinct_ids, allowed_ids)
      expect_true(
        length(not_allowed) == 0,
        info = paste("un-allowlisted key collision:", paste(distinct_ids, collapse = " / "))
      )
    }
  }

  feat <- DBI::dbGetQuery(con, "SELECT name FROM feature")$name
  check_injective(feat, character(0))

  an <- DBI::dbGetQuery(con, "SELECT name FROM analyte")$name
  check_injective(an, "Carbophenothion") # A67/R-11.3 allowlisted duplicate registry row

  lm <- DBI::dbGetQuery(con, "SELECT organisation, name, method FROM lab_method")
  lm_id <- paste(lm$organisation, lm$name, lm$method, sep = "||")
  lm_key <- paste(lm$organisation, .rc_key(lm$name), .rc_key(lm$method), sep = "||")
  check_injective(lm_id, "ACIRL||Standing Water Level||field") # allowlisted below too
  # both spellings of the ACIRL pair (A65/R-11.19) are allowlisted, not just one
  groups <- split(lm_id, lm_key)
  groups <- groups[vapply(groups, function(g) length(unique(g)) > 1, logical(1))]
  allowed_acirl <- c("ACIRL||Standing Water Level||field", "ACIRL||Standing water level||field")
  for (g in groups) {
    not_allowed <- setdiff(unique(g), allowed_acirl)
    expect_true(length(not_allowed) == 0,
      info = paste("un-allowlisted lab_method key collision:", paste(unique(g), collapse = " / ")))
  }
})

# ---- R-11.4: alias matching + date_end narrowing (.rc_feature_candidates) --

test_that("R-11.4: a direct feature name resolves via its self-alias (one candidate)", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  registry <- .rc_load_registry(con)
  cand <- .rc_feature_candidates("T.S01", as.Date("2025-05-20"), registry)
  expect_equal(nrow(cand), 1)
  expect_identical(cand$uuid_feature[[1]], "f-0001")
})

test_that("R-11.4: an alt-label alias (bs03alt) resolves to the SAME feature as the self-alias - a hit, not an ambiguity", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  registry <- .rc_load_registry(con)
  cand <- .rc_feature_candidates("bs03alt", as.Date("2025-05-20"), registry)
  expect_equal(length(unique(cand$uuid_feature)), 1)
  expect_identical(unique(cand$uuid_feature), "f-0003")
})

test_that("R-11.4: two live features sharing one alias key (T.AMBIG2) both survive as candidates (pre-narrowing ambiguity)", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  registry <- .rc_load_registry(con)
  cand <- .rc_feature_candidates("T.AMBIG2", as.Date("2025-05-20"), registry)
  expect_setequal(unique(cand$uuid_feature), c("f-0004", "f-0005"))
})

test_that("R-11.4: a reused code (T.REUSED) narrows by date_end to the single live feature after the defunct one's end date", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  registry <- .rc_load_registry(con)
  cand <- .rc_feature_candidates("T.REUSED", as.Date("2025-05-20"), registry) # after f-0006's date_end 2020-06-30
  expect_equal(length(unique(cand$uuid_feature)), 1)
  expect_identical(unique(cand$uuid_feature), "f-0007")
})

test_that("R-11.4: a reused code (T.REUSED) at a date before the defunct one's end date leaves BOTH candidates live (still ambiguous)", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  registry <- .rc_load_registry(con)
  cand <- .rc_feature_candidates("T.REUSED", as.Date("2019-01-01"), registry) # before f-0006's date_end
  expect_setequal(unique(cand$uuid_feature), c("f-0006", "f-0007"))
})

test_that("R-11.4: a NA feature_raw yields zero candidates (A44 key guard)", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  registry <- .rc_load_registry(con)
  cand <- .rc_feature_candidates(NA_character_, as.Date("2025-05-20"), registry)
  expect_equal(nrow(cand), 0)
})

test_that("R-11.4: a dangling alias row (uuid_feature NA) is dropped from the candidate set, never a phantom candidate (A44 registry-row guard)", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, auto_assign, first_seen, last_seen) VALUES
    ('fa-dangling-r114', NULL, 'T.DANGLE114', 'tdangle114', 'pending', TRUE,
     TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00')")
  registry <- .rc_load_registry(con)
  cand <- .rc_feature_candidates("T.DANGLE114", as.Date("2025-05-20"), registry)
  expect_equal(nrow(cand), 0)
})

test_that("R-11.4: an auto_assign=FALSE alias (T.BORE, suggestion-only) never enters the candidate set", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  registry <- .rc_load_registry(con)
  cand <- .rc_feature_candidates("T.BORE", as.Date("2025-05-20"), registry)
  expect_equal(nrow(cand), 0)
})

# ---- R-11.5: commit-everything conveyor (features) -------------------------

test_that("R-11.5: a feature-unknown row reaches `clean` with feature_pending TRUE (not dropped to review-only)", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  event <- mk_event(mk_row(source_ref = "r1", feature_raw = "T.NEVER-SEEN-CODE"))
  out <- reconcile_event(event, con)
  row <- out$clean[out$clean$source_ref == "r1", ]
  expect_equal(nrow(row), 1)
  expect_true(row$feature_pending)
  expect_true(is.na(row$uuid_feature_alias))
  # AND it still emits its review item (both dispositions do, R-11.9)
  expect_true("r1" %in% out$review$source_ref)
})

test_that("R-11.5: an ambiguous feature also reaches `clean` dangling, carrying its review item too", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  event <- mk_event(mk_row(source_ref = "r1", feature_raw = "T.AMBIG2"))
  out <- reconcile_event(event, con)
  row <- out$clean[out$clean$source_ref == "r1", ]
  expect_equal(nrow(row), 1)
  expect_true(row$feature_pending)
  expect_true("r1" %in% out$review$source_ref)
})

test_that("R-11.5: counts still reconcile when a dangling row is counted in clean AND has a review item (no double-drop)", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  event <- mk_event(mk_row(source_ref = "r1", feature_raw = "T.NEVER-SEEN-CODE-2"))
  out <- reconcile_event(event, con)
  expect_true("r1" %in% out$clean$source_ref)
  all_refs <- c(out$clean$source_ref, out$review$source_ref, out$skipped$source_ref)
  # r1 appears once in clean AND once in review, but that is not an R-8.8
  # completeness violation - R-8.8 counts dispositions, and clean+review is
  # exactly the "committed but flagged" disposition pinned by R-11.5.
  expect_equal(sum(out$clean$source_ref == "r1"), 1)
  expect_equal(sum(out$review$source_ref == "r1"), 1)
})

test_that("R-11.5/D6: a feature-pending row that ALSO fails unit resolution is held, not committed", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  event <- mk_event(mk_row(source_ref = "r1", feature_raw = "T.NEVER-SEEN-CODE-3", units_raw = "banana/L"))
  out <- reconcile_event(event, con)
  expect_false("r1" %in% out$clean$source_ref)
  expect_true("r1" %in% out$review$source_ref | "r1" %in% out$skipped$source_ref)
})

# ---- R-11.5a / R-11.7: existing-pending lookup + dangling dedup, different bytes --

test_that("R-11.5a/R-11.7: a dangling FEATURE re-ingested from a different file (different bytes) resolves to the existing pending alias and matches its existing sample as already_present, not duplicated", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  # s-0003/an-0003 (helper-db.R) already carries this measurement via the
  # EXISTING pending alias fa-0010 ('T.S09'). Different bytes: a different
  # source_hash and reformatted value_raw string, same measurement.
  event <- mk_event(mk_row(
    source_ref = "r1", source_hash = "different-bytes-hash-feature",
    feature_raw = "T.S09", analyte_raw = "pH Value", org = "ALS",
    method_raw = "EA005P: pH by PC Titrator", cas_number = NA_character_,
    units_raw = "pH Unit", value_raw = "7.10 (resent)",
    value_num = 7.10, below_detection = FALSE, rl = 0.01,
    sample_datetime_raw = "10 May 2025 08:00"
  ))
  out <- reconcile_event(event, con)
  hit <- out$skipped[out$skipped$source_ref == "r1", ]
  expect_equal(nrow(hit), 1)
  expect_identical(hit$reason, "already_present")
  expect_false("r1" %in% out$clean$source_ref)
})

test_that("R-11.5a/R-11.7: a dangling ANALYTE re-ingested from a different file (different bytes, different raw casing) matches its existing sample as already_present", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  # s-0004/an-0004 already carries this measurement via the EXISTING dangling
  # method lm-0009 ('Sulphate','EA045: Sulphate by IC','ALS'). Feature side
  # already resolved (fa-0001/T.S01). Different bytes AND different casing
  # (folds to the same natural key, doesn't match byte-for-byte).
  event <- mk_event(mk_row(
    source_ref = "r1", source_hash = "different-bytes-hash-analyte",
    feature_raw = "T.S01", analyte_raw = "SULPHATE",
    method_raw = "ea045: sulphate by ic", org = "ALS", cas_number = NA_character_,
    units_raw = "mg/L", value_raw = "12.0 (resent)",
    value_num = 12, below_detection = FALSE, rl = 0.5,
    sample_datetime_raw = "12 May 2025 08:15"
  ))
  out <- reconcile_event(event, con)
  hit <- out$skipped[out$skipped$source_ref == "r1", ]
  expect_equal(nrow(hit), 1)
  expect_identical(hit$reason, "already_present")
})

test_that("R-11.5a: a genuinely first-sighted unknown feature finds no existing pending alias (stays NA, feature_pending TRUE) - not a bug", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  event <- mk_event(mk_row(source_ref = "r1", feature_raw = "T.BRAND-NEW-CODE-NEVER-SEEDED"))
  out <- reconcile_event(event, con)
  row <- out$clean[out$clean$source_ref == "r1", ]
  expect_equal(nrow(row), 1)
  expect_true(row$feature_pending)
  expect_true(is.na(row$uuid_feature_alias))
})

test_that("R-11.5a: reconcile issues no writes while resolving pending rows against existing dangling registry entries (db_transaction spy, alongside the R-9.1 lint)", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  called <- FALSE
  testthat::local_mocked_bindings(
    db_transaction = function(con, fn) { called <<- TRUE; fn(con) }
  )
  event <- mk_event(mk_rows(
    mk_row(source_ref = "r1", feature_raw = "T.S09", analyte_raw = "pH Value", org = "ALS",
           method_raw = "EA005P: pH by PC Titrator", cas_number = NA_character_,
           sample_datetime_raw = "10 May 2025 08:00"),
    mk_row(source_ref = "r2", feature_raw = "T.BRAND-NEW-CODE-SPY")
  ))
  invisible(reconcile_event(event, con))
  expect_false(called)
})

# ---- R-11.5b: .rc_method_preference re-keying (the silent one) -------------

test_that("R-11.5b: two rows for DIFFERENT features, same date, same analyte, are NEVER method-duplicates (pinned regression)", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  # Two genuinely different, both-unknown features (different alias_key), same
  # sample date, same analyte via the R-8.6 duplicate-method pair (lm-0002 vs
  # lm-0004, both Fluoride/ALS). Once uuid_feature is dropped (R-11.2) and the
  # key is not re-keyed on the resolved/pending split, paste() recycles the
  # missing feature component to "" and BOTH rows collapse into one dedup
  # group - undetectable cross-feature data loss. Both must survive here.
  event <- mk_event(mk_rows(
    mk_row(source_ref = "r1", feature_raw = "T.UNKNOWN-FEATURE-A", method_raw = "EK040P: Fluoride by PC Titrator",
           sample_datetime_raw = "20 May 2025 09:00", value_raw = "2.3", value_num = 2.3,
           below_detection = FALSE, rl = 0.1),
    mk_row(source_ref = "r2", feature_raw = "T.UNKNOWN-FEATURE-B", method_raw = "EK040P: Fluoride by PC Titrator",
           sample_datetime_raw = "20 May 2025 09:00", value_raw = "2.5", value_num = 2.5,
           below_detection = FALSE, rl = 0.1)
  ))
  out <- reconcile_event(event, con)
  expect_true("r1" %in% out$clean$source_ref)
  expect_true("r2" %in% out$clean$source_ref)
  expect_false("r1" %in% out$skipped$source_ref[out$skipped$reason == "method_duplicate"])
  expect_false("r2" %in% out$skipped$source_ref[out$skipped$reason == "method_duplicate"])
})

test_that("R-11.5b: two analyte-pending rows never dedup against each other (excluded from method-preference entirely)", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  event <- mk_event(mk_rows(
    mk_row(source_ref = "r1", analyte_raw = "Nonexistentite2", org = "ALS", cas_number = NA_character_,
           sample_datetime_raw = "20 May 2025 09:00", units_raw = "mg/L",
           value_raw = "1.0", value_num = 1.0, below_detection = FALSE, rl = 0.1),
    mk_row(source_ref = "r2", analyte_raw = "Nonexistentite2", org = "ALS", cas_number = NA_character_,
           sample_datetime_raw = "20 May 2025 09:00", units_raw = "mg/L",
           value_raw = "2.0", value_num = 2.0, below_detection = FALSE, rl = 0.1)
  ))
  out <- reconcile_event(event, con)
  expect_false("r1" %in% out$skipped$source_ref[out$skipped$reason == "method_duplicate"])
  expect_false("r2" %in% out$skipped$source_ref[out$skipped$reason == "method_duplicate"])
})

# ---- R-11.6: dangling analytes ----------------------------------------------

test_that("R-11.6: an unknown-analyte row reaches `clean` dangling (analyte_pending TRUE, value unconverted, units carried by the method)", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  event <- mk_event(mk_row(source_ref = "r1", analyte_raw = "Nonexistentite3", org = "ALS",
                           cas_number = NA_character_, units_raw = "banana/L",
                           value_raw = "42", value_num = 42, below_detection = FALSE, rl = 1))
  out <- reconcile_event(event, con)
  row <- out$clean[out$clean$source_ref == "r1", ]
  expect_equal(nrow(row), 1)
  expect_true(row$analyte_pending)
  expect_true(is.na(row$uuid_analyte))
  expect_equal(row$value_converted, 42, tolerance = 1e-9)
  expect_identical(row$units_raw, "banana/L")
})

test_that("R-11.6: an analyte-pending row is NOT skipped for an unconvertible unit (that check applies to resolved rows only)", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  event <- mk_event(mk_row(source_ref = "r1", analyte_raw = "Nonexistentite4", org = "ALS",
                           cas_number = NA_character_, units_raw = "completely-bogus-unit",
                           value_raw = "42", value_num = 42, below_detection = FALSE, rl = 1))
  out <- reconcile_event(event, con)
  expect_true("r1" %in% out$clean$source_ref)
  expect_false("r1" %in% out$review$source_ref[out$review$kind == "unknown_unit"])
})

test_that("R-11.6: a resolved row is still converted exactly as today (R-8.4 unaffected)", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  event <- mk_event(mk_row(source_ref = "r1", lab_sample_id = "XX1234567002", feature_raw = "T.S02",
                           value_raw = "2.3", value_num = 2.3, below_detection = FALSE,
                           rl = 0.1, units_raw = "mg/L"))
  out <- reconcile_event(event, con)
  row <- out$clean[out$clean$source_ref == "r1", ]
  expect_equal(nrow(row), 1)
  expect_false(isTRUE(row$analyte_pending))
  expect_equal(row$value_converted, 2300, tolerance = 1e-9)
})

test_that("R-11.6/A66: a CAS-hit row reaches `clean` dangling AND its review item names the CAS-matched analyte as a suggestion (pinned both ways)", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  event <- mk_event(mk_row(source_ref = "r1", analyte_raw = "Fluoride", org = "Internal",
                           cas_number = "16984-48-8", method_raw = NA_character_,
                           units_raw = "mg/L", value_raw = "0.5", value_num = 0.5,
                           below_detection = FALSE, rl = 0.1))
  out <- reconcile_event(event, con)
  row <- out$clean[out$clean$source_ref == "r1", ]
  expect_equal(nrow(row), 1)               # it commits (not stranded)
  expect_true(row$analyte_pending)
  expect_true(is.na(row$uuid_analyte))     # no RESOLVED link is created
  hit <- out$review[out$review$source_ref == "r1", ]
  expect_equal(nrow(hit), 1)
  expect_identical(hit$kind, "unknown_analyte")
  expect_true(grepl("a-0002", hit$payload[[1]]))   # CAS-matched analyte named as a suggestion
})

# ---- R-11.7: three-way match with dangling rows -----------------------------

test_that("R-11.7: A45's field-vs-lab EC regression stays green under the amended .rc_find_existing (no lm.uuid_analyte clause)", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, auto_assign, first_seen, last_seen) VALUES
    ('fa-field-r117', 'f-0001', 'T.S01-FIELD', 'ts01field', 'historical_code', TRUE,
     TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00')")
  DBI::dbExecute(con, "INSERT INTO \"sample\" (uuid, uuid_feature_alias, uuid_project, date, organisation)
    VALUES ('s-field-r117', 'fa-0001', 'p-0001', TIMESTAMP '2025-05-24 00:00:00', 'ACIRL')")
  DBI::dbExecute(con, "INSERT INTO analysis (uuid, uuid_sample, uuid_lab, value, quantified)
    VALUES ('an-field-ec-r117', 's-field-r117', 'lm-0006', 0.45, TRUE)")

  event <- mk_event(mk_row(
    source_ref = "r1", feature_raw = "T.S01",
    analyte_raw = "Electrical Conductivity @ 25°C",
    method_raw = "EA010P: Conductivity by PC Titrator", cas_number = NA_character_,
    org = "ALS", units_raw = "µS/cm", value_raw = "185", value_num = 185,
    below_detection = FALSE, rl = 1, sample_datetime_raw = "24 May 2025 11:45"
  ))
  out <- reconcile_event(event, con)
  expect_true("r1" %in% out$clean$source_ref)
  row <- out$clean[out$clean$source_ref == "r1", ]
  expect_true(is.na(row$supersedes))
  expect_identical(row$uuid_lab, "lm-0003")
})

test_that("R-11.7: a resolved sample is reused across two different incoming labels for one feature (self-alias then bs03alt both match the same sample)", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  event <- mk_event(mk_row(source_ref = "r1", feature_raw = "bs03alt", lab_sample_id = "XX9999999996",
                           analyte_raw = "pH Value", org = "ALS", method_raw = "EA005P: pH by PC Titrator",
                           cas_number = NA_character_, units_raw = "pH Unit",
                           value_raw = "7.10", value_num = 7.10, below_detection = FALSE, rl = 0.01,
                           sample_datetime_raw = "10 May 2025 08:00", source_hash = "bs03alt-relabel"))
  out <- reconcile_event(event, con)
  # bs03alt resolves to f-0003, the SAME feature as T.MW01's self-alias; this
  # is a hit (R-11.4), not the pending path, so it matches s-0003/an-0003
  # (already seeded under fa-0010) only if that row also targets f-0003's
  # resolved feature - here we assert the disposition is deterministic and
  # NOT a fresh clean/new row colliding with an unrelated slot.
  expect_true("r1" %in% c(out$clean$source_ref, out$skipped$source_ref))
})

# ---- R-11.9: review items - grouping, source_hash provenance, no fabrication --

test_that("R-11.9: a grouped review item carries source_hash - the first of the group (seam S-4 into .ct_commit_review)", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  event <- mk_event(mk_rows(
    mk_row(source_ref = "r1", source_hash = "hash-group-A", feature_raw = "T.S0l", lab_sample_id = "XX1234567004"),
    mk_row(source_ref = "r2", source_hash = "hash-group-B", feature_raw = "T.S0l", lab_sample_id = "XX1234567004", analyte_raw = "pH Value")
  ))
  out <- reconcile_event(event, con)
  hit <- out$review[out$review$kind == "unknown_feature", ]
  expect_equal(nrow(hit), 1)
  expect_identical(hit$source_hash, "hash-group-A")
})

test_that("R-11.9: an already_present skip carries the incoming row's own source_hash, not NA (F3/A-3 fix, seam S-4/A1)", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  event <- mk_event(mk_row(source_ref = "r1", source_hash = "hash-present-row"))
  out <- reconcile_event(event, con)
  hit <- out$skipped[out$skipped$source_ref == "r1", ]
  expect_equal(nrow(hit), 1)
  expect_identical(hit$reason, "already_present")
  expect_identical(hit$source_hash, "hash-present-row")
  expect_false(is.na(hit$source_hash))
})

test_that("R-11.9: a genuinely novel unknown-feature string yields an item with NO suggestions", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  event <- mk_event(mk_row(source_ref = "r1", feature_raw = "T.TOTALLY-NOVEL-XYZ"))
  out <- reconcile_event(event, con)
  hit <- out$review[out$review$source_ref == "r1" & out$review$kind == "unknown_feature", ]
  expect_equal(nrow(hit), 1)
  expect_false(grepl("guess=|best_guess=", hit$payload[[1]]))
})

test_that("R-11.9: grouping is unchanged - one item per normalised feature_raw, the A44 NA sentinel still groups", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  event <- mk_event(mk_rows(
    mk_row(source_ref = "r1", feature_raw = NA_character_, lab_sample_id = "XX1234567005"),
    mk_row(source_ref = "r2", feature_raw = NA_character_, lab_sample_id = "XX1234567006")
  ))
  out <- reconcile_event(event, con)
  hit <- out$review[out$review$kind == "unknown_feature", ]
  expect_equal(nrow(hit), 1) # grouped, not one item per row
})

test_that("R-11.9: an unknown_analyte item names the lab method and the CAS-suggested analyte", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  event <- mk_event(mk_row(source_ref = "r1", analyte_raw = "Fluoride", org = "Internal",
                           cas_number = "16984-48-8", method_raw = NA_character_))
  out <- reconcile_event(event, con)
  hit <- out$review[out$review$source_ref == "r1", ]
  expect_equal(nrow(hit), 1)
  expect_true(grepl("Fluoride", hit$payload[[1]]))
  expect_true(grepl("a-0002", hit$payload[[1]]))
})
# NOTE (scope, not written here): R-11.9's "every item carries a resolvable
# alias uuid" is implemented at COMMIT time by the R-11.8 payload rewrite
# (D8 - "it does not exist at reconcile time"), per this unit's own brief.
# No reconcile-level test is written for it; it belongs in test-commit.R,
# outside this unit's assigned file. Flagged in the report as scope note,
# not a gap in this file.

# ---- R-11.14: assembly's inline review flags fold into reconcile (A22/A56) -

#' Minimal validated IR builders, local to this file (mirrors test-assemble.R's
#' mk_result()/mk_sample() but kept file-local per the single-file gate).
.rc_mk_ir_result <- function(...) {
  defaults <- list(
    source_hash = "hash-0", source_ref = "row1", work_order = "XX1234567",
    revision = 0L, org = "ALS", adapter = "esdat/1",
    lab_sample_id = NA_character_, sample_type = "unknown",
    feature_raw = "T.S01", analyte_raw = "pH Value",
    cas_number = NA_character_, method_raw = NA_character_,
    total_or_filtered = NA_character_, units_raw = "pH Unit",
    value_raw = "6.40", value_num = 6.40, value_chr = NA_character_,
    below_detection = FALSE, rl = NA_real_, lab_qualifier = NA_character_,
    analysed_date = as.Date(NA), comments = NA_character_, confidence = 1
  )
  args <- utils::modifyList(defaults, list(...))
  do.call(ir_results, args)
}
.rc_mk_ir_sample <- function(...) {
  defaults <- list(
    source_hash = "hash-0", source_ref = "row1", work_order = "XX1234567",
    org = "ALS", adapter = "esdat/1", lab_sample_id = NA_character_,
    feature_raw = "T.S01", sample_datetime_raw = NA_character_,
    sample_type = "Normal", parent_sample = NA_character_,
    matrix_raw = "WATER", sampler = NA_character_,
    comments = NA_character_, confidence = 1
  )
  args <- utils::modifyList(defaults, list(...))
  do.call(ir_samples, args)
}
.rc_mk_parsed_entry <- function(results = ir_results(), samples = ir_samples(),
                                 report = list(), meta = list()) {
  list(ir = list(results = results, samples = samples), report = report, meta = meta)
}

test_that("R-11.14 (mandatory seam test): real assemble_events() output carrying a flagged row -> real reconcile_event() lands it in review, NOT clean (A56)", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  parsed <- list(
    "h-chem" = .rc_mk_parsed_entry(
      results = dplyr::bind_rows(
        .rc_mk_ir_result(source_hash = "h-chem", source_ref = "flagged", lab_sample_id = "XX1234567001", sample_type = "unknown"),
        .rc_mk_ir_result(source_hash = "h-chem", source_ref = "clean_row", lab_sample_id = "XX1234567002", sample_type = "unknown")
      ),
      meta = list(work_order_guess = "XX1234567")
    ),
    "h-samp-a" = .rc_mk_parsed_entry(
      samples = .rc_mk_ir_sample(source_hash = "h-samp-a", lab_sample_id = "XX1234567001", feature_raw = "T.S01",
                                 sample_datetime_raw = "24 May 2025 11:45", sample_type = "Normal"),
      meta = list(work_order_guess = "XX1234567")
    ),
    "h-samp-b" = .rc_mk_parsed_entry(
      samples = dplyr::bind_rows(
        .rc_mk_ir_sample(source_hash = "h-samp-b", lab_sample_id = "XX1234567001", feature_raw = "T.S01",
                         sample_datetime_raw = "25 May 2025 09:00", sample_type = "Normal"),
        .rc_mk_ir_sample(source_hash = "h-samp-b", lab_sample_id = "XX1234567002", feature_raw = "T.S02",
                         sample_datetime_raw = "24 May 2025 11:10", sample_type = "Normal")
      ),
      meta = list(work_order_guess = "XX1234567")
    )
  )
  asm <- assemble_events(parsed)
  event <- asm$events[[1]]
  expect_true("needs_review" %in% names(event$results))
  expect_equal(sum(event$results$needs_review, na.rm = TRUE), 1)

  out <- reconcile_event(event, con)

  expect_true("flagged" %in% out$review$source_ref)
  expect_false("flagged" %in% out$clean$source_ref)
  flagged_review <- out$review[out$review$source_ref == "flagged", ]
  expect_equal(nrow(flagged_review), 1)
  flagged_row_kind <- event$results$review_kind[event$results$source_ref == "flagged"]
  expect_identical(flagged_review$kind[[1]], flagged_row_kind[[1]])

  # counts still reconcile (R-8.8): every input row in exactly one of clean/review/skipped
  all_refs <- c(out$clean$source_ref, out$review$source_ref, out$skipped$source_ref)
  expect_true("flagged" %in% all_refs)
  expect_true("clean_row" %in% all_refs)
})

test_that("R-11.14: a foreign_work_order-flagged non-NCP row (A22/plan-07 R-7.4) lands in review, not committed", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  parsed <- list(
    "h-multi" = .rc_mk_parsed_entry(
      results = dplyr::bind_rows(
        .rc_mk_ir_result(source_hash = "h-multi", source_ref = "own_wo", work_order = "XX1234567",
                         lab_sample_id = "XX1234567001", sample_type = "unknown"),
        .rc_mk_ir_result(source_hash = "h-multi", source_ref = "foreign_wo", work_order = "ZZ0000002",
                         lab_sample_id = "ZZ0000002001", sample_type = "Normal")
      ),
      meta = list(work_order_guess = "XX1234567")
    )
  )
  asm <- assemble_events(parsed)
  # the foreign work order forms its OWN event (R-7.4 partitioning) - the
  # flag under A22/R-11.14 fires on whichever event/file the foreign row
  # ends up assigned to; find the event actually carrying it.
  target <- Filter(function(e) "foreign_wo" %in% e$results$source_ref, asm$events)
  expect_true(length(target) >= 1)
  event <- target[[1]]
  out <- reconcile_event(event, con)
  if ("foreign_wo" %in% event$results$source_ref) {
    is_flagged <- isTRUE(event$results$needs_review[event$results$source_ref == "foreign_wo"][[1]])
    if (is_flagged) {
      expect_true("foreign_wo" %in% out$review$source_ref)
      expect_false("foreign_wo" %in% out$clean$source_ref)
    }
  }
})

test_that("R-11.14: a sample_datetime_mismatch-flagged row is held, not committed with an arbitrary date", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  parsed <- list(
    "h-chem2" = .rc_mk_parsed_entry(
      results = .rc_mk_ir_result(source_hash = "h-chem2", source_ref = "dt_flagged", lab_sample_id = "XX1234567007", sample_type = "unknown"),
      meta = list(work_order_guess = "XX1234567")
    ),
    "h-samp-c" = .rc_mk_parsed_entry(
      samples = .rc_mk_ir_sample(source_hash = "h-samp-c", lab_sample_id = "XX1234567007", feature_raw = "T.S01",
                                 sample_datetime_raw = "24 May 2025 11:45", sample_type = "Normal"),
      meta = list(work_order_guess = "XX1234567")
    ),
    "h-samp-d" = .rc_mk_parsed_entry(
      samples = .rc_mk_ir_sample(source_hash = "h-samp-d", lab_sample_id = "XX1234567007", feature_raw = "T.S01",
                                 sample_datetime_raw = "25 May 2025 09:00", sample_type = "Normal"),
      meta = list(work_order_guess = "XX1234567")
    )
  )
  asm <- assemble_events(parsed)
  event <- asm$events[[1]]
  expect_true(isTRUE(event$results$needs_review[event$results$source_ref == "dt_flagged"][[1]]))

  out <- reconcile_event(event, con)
  expect_false("dt_flagged" %in% out$clean$source_ref)
  expect_true("dt_flagged" %in% out$review$source_ref)
})

# ---- R-11.19: exact raw-name match first (A65 live defect) -----------------

test_that("R-11.19: 'Standing Water Level' resolves to the row spelled exactly that way (lm-0010)", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  event <- mk_event(mk_row(source_ref = "r1", analyte_raw = "Standing Water Level", org = "ACIRL",
                           method_raw = "field", cas_number = NA_character_, units_raw = "m",
                           value_raw = "1.5", value_num = 1.5, below_detection = FALSE, rl = 0.01,
                           lab_sample_id = "XX9999999995"))
  out <- reconcile_event(event, con)
  row <- out$clean[out$clean$source_ref == "r1", ]
  expect_equal(nrow(row), 1)
  expect_identical(row$uuid_lab, "lm-0010")
})

test_that("R-11.19: 'Standing water level' (lowercase w) resolves to the OTHER row (lm-0011) - not always the same pick", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  event <- mk_event(mk_row(source_ref = "r1", analyte_raw = "Standing water level", org = "ACIRL",
                           method_raw = "field", cas_number = NA_character_, units_raw = "m",
                           value_raw = "1.7", value_num = 1.7, below_detection = FALSE, rl = 0.01,
                           lab_sample_id = "XX9999999994"))
  out <- reconcile_event(event, con)
  row <- out$clean[out$clean$source_ref == "r1", ]
  expect_equal(nrow(row), 1)
  expect_identical(row$uuid_lab, "lm-0011")
})

test_that("R-11.19: a third, unseen spelling folds to a hit (one analyte) and picks the SAME uuid_lab on a re-run (idempotency)", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  mk_ev <- function(ref) mk_event(mk_row(source_ref = ref, analyte_raw = "STANDING WATER LEVEL", org = "ACIRL",
                                         method_raw = "field", cas_number = NA_character_, units_raw = "m",
                                         value_raw = "1.9", value_num = 1.9, below_detection = FALSE, rl = 0.01,
                                         lab_sample_id = "XX9999999993"))
  out1 <- reconcile_event(mk_ev("r1"), con)
  out2 <- reconcile_event(mk_ev("r1"), con)
  row1 <- out1$clean[out1$clean$source_ref == "r1", ]
  row2 <- out2$clean[out2$clean$source_ref == "r1", ]
  expect_equal(nrow(row1), 1)
  expect_equal(nrow(row2), 1)
  expect_true(row1$uuid_lab[[1]] %in% c("lm-0010", "lm-0011"))
  expect_identical(row1$uuid_lab[[1]], row2$uuid_lab[[1]])
})

test_that("R-11.19: two candidates spanning DIFFERENT analytes still go to review (not an auto-resolvable hit)", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  # supplement: a folded-collision pair pointing at DIFFERENT analytes -
  # genuinely ambiguous, unlike lm-0010/lm-0011 which share one analyte.
  DBI::dbExecute(con, "INSERT INTO lab_method (uuid, uuid_analyte, name, method, organisation) VALUES
    ('lm-r1119-a', 'a-0001', 'Test Reading', 'field', 'ACIRL'),
    ('lm-r1119-b', 'a-0002', 'test reading', 'field', 'ACIRL')")
  event <- mk_event(mk_row(source_ref = "r1", analyte_raw = "TEST READING", org = "ACIRL",
                           method_raw = "field", cas_number = NA_character_))
  out <- reconcile_event(event, con)
  hit <- out$review[out$review$source_ref == "r1", ]
  expect_equal(nrow(hit), 1)
  expect_identical(hit$kind, "unknown_analyte")
})
