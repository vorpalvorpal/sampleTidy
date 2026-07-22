# Plan 07 - R/assemble.R: event assembly & source preference.
#
# `assemble_events(parsed)` takes `parsed = list(<hash> = list(ir = list(
# results, samples), report, meta))` (one entry per file in state `parsed`)
# and returns `list(events = list(...), states = tibble(hash, state, reason))`
# (R-7.5).
#
# Per the pipeline-tests brief (mirroring the explicit plan-08 instruction),
# `parsed` inputs here are built directly from the pinned FIXTURES.md values
# via `ir_results()`/`ir_samples()`, not by routing the real esdat/crosstab/
# acirl fixture files through the router/adapters. That keeps this file
# independent of plans 04-06's landing order and implementation status; see
# dev/plans/PLAN-CHANGE-REQUESTS.md ("assembly `parsed` inputs built directly").

# ---- local helpers ----------------------------------------------------

mk_result <- function(...) {
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

mk_sample <- function(...) {
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

mk_parsed_entry <- function(results = ir_results(), samples = ir_samples(),
                             report = list(), meta = list()) {
  list(ir = list(results = results, samples = samples), report = report, meta = meta)
}

#' Validate the R-7.5 pinned event shape. Used by every constructive test
#' below (R-7.5 criterion: "shape validated by a helper expect_valid_event()
#' used by every test above").
expect_valid_event <- function(event) {
  testthat::expect_type(event, "list")
  required <- c("work_order", "orphan", "results", "samples", "files", "report")
  testthat::expect_true(
    all(required %in% names(event)),
    info = paste("event missing fields:", paste(setdiff(required, names(event)), collapse = ", "))
  )
  testthat::expect_length(event$work_order, 1)
  testthat::expect_type(event$orphan, "logical")
  testthat::expect_s3_class(event$results, "data.frame")
  testthat::expect_s3_class(event$samples, "data.frame")
  testthat::expect_s3_class(event$files, "data.frame")
  testthat::expect_true(all(c("hash", "filename", "adapter", "rank", "kept") %in% names(event$files)))
  testthat::expect_type(event$files$kept, "logical")
  testthat::expect_type(event$report, "list")
  report_required <- c("n_results", "n_by_sample_type", "n_ncp_foreign", "skipped", "warnings")
  testthat::expect_true(
    all(report_required %in% names(event$report)),
    info = paste("event$report missing:", paste(setdiff(report_required, names(event$report)), collapse = ", "))
  )
  testthat::expect_s3_class(event$report$skipped, "data.frame")
  testthat::expect_true(all(c("hash", "source_ref", "reason") %in% names(event$report$skipped)))
  testthat::expect_type(event$report$warnings, "character")
  invisible(event)
}

# ---- R-7.1: grouping ----------------------------------------------------

test_that("R-7.1: three files sharing a work order form one event", {
  parsed <- list(
    "h-chem" = mk_parsed_entry(
      results = dplyr::bind_rows(
        mk_result(source_hash = "h-chem", lab_sample_id = "XX1234567001", analyte_raw = "pH Value"),
        mk_result(source_hash = "h-chem", lab_sample_id = "XX1234567002", analyte_raw = "pH Value"),
        mk_result(source_hash = "h-chem", lab_sample_id = "XX1234567003", analyte_raw = "pH Value")
      ),
      meta = list(work_order_guess = "XX1234567")
    ),
    "h-samp" = mk_parsed_entry(
      samples = dplyr::bind_rows(
        mk_sample(source_hash = "h-samp", lab_sample_id = "XX1234567001", feature_raw = "T.S01"),
        mk_sample(source_hash = "h-samp", lab_sample_id = "XX1234567002", feature_raw = "T.S02"),
        mk_sample(source_hash = "h-samp", lab_sample_id = "XX1234567003", feature_raw = "T.MW01")
      ),
      meta = list(work_order_guess = "XX1234567")
    ),
    # Header.XML: zero-row IR, metadata-only (PLAN-04 R-4.4). Signal both
    # possible grouping keys (see PLAN-CHANGE-REQUESTS.md).
    "h-hdr" = mk_parsed_entry(
      report = list(header = list(work_order = "XX1234567", date_reported = "2025-05-28")),
      meta = list(work_order_guess = "XX1234567", filename = "PROJ_A.ESDAT_XX1234567_0.Header.XML")
    )
  )

  out <- assemble_events(parsed)
  expect_length(out$events, 1)
  event <- out$events[[1]]
  expect_valid_event(event)
  expect_identical(event$work_order, "XX1234567")
  expect_false(event$orphan)
  expect_equal(nrow(event$results), 3)

  # states tibble covers all three input hashes exactly once
  expect_setequal(out$states$hash, names(parsed))
})

test_that("R-7.1: a lone Sample2e forms its own event", {
  parsed <- list(
    "h-lone-samp" = mk_parsed_entry(
      samples = mk_sample(source_hash = "h-lone-samp", work_order = "XX7654321", feature_raw = "T.S01"),
      meta = list(work_order_guess = "XX7654321")
    )
  )
  out <- assemble_events(parsed)
  expect_length(out$events, 1)
  event <- out$events[[1]]
  expect_valid_event(event)
  expect_identical(event$work_order, "XX7654321")
  expect_equal(nrow(event$results), 0)
  expect_equal(nrow(event$samples), 1)
})

test_that("R-7.1: an NA-work-order file forms an orphan event without error", {
  parsed <- list(
    "h-orphan" = mk_parsed_entry(
      results = mk_result(source_hash = "h-orphan", work_order = NA_character_, adapter = "acirl_field_xlsx/1"),
      meta = list(work_order_guess = NA_character_)
    )
  )
  expect_no_error(out <- assemble_events(parsed))
  expect_length(out$events, 1)
  event <- out$events[[1]]
  expect_valid_event(event)
  expect_true(is.na(event$work_order))
  expect_true(event$orphan)
})

# ---- R-7.2: source preference ------------------------------------------

test_that("R-7.2: ESdat + XTAB in one event keeps ESdat, drops XTAB as superseded_by_better_source", {
  parsed <- list(
    "h-esdat" = mk_parsed_entry(
      results = mk_result(source_hash = "h-esdat", adapter = "esdat/1", lab_sample_id = "XX1234567001"),
      meta = list(work_order_guess = "XX1234567")
    ),
    "h-xtab" = mk_parsed_entry(
      results = mk_result(source_hash = "h-xtab", adapter = "als_xtab/1", lab_sample_id = "XX1234567001"),
      meta = list(work_order_guess = "XX1234567")
    )
  )
  out <- assemble_events(parsed)
  event <- out$events[[1]]
  expect_valid_event(event)
  expect_equal(nrow(event$results), 1)
  expect_true(all(event$results$adapter == "esdat/1"))

  files <- event$files
  expect_true(files$kept[files$hash == "h-esdat"])
  expect_false(files$kept[files$hash == "h-xtab"])

  xtab_state <- out$states[out$states$hash == "h-xtab", ]
  expect_identical(xtab_state$state, "ignored")
  expect_identical(xtab_state$reason, "superseded_by_better_source")
})

test_that("R-7.2: event with only XTAB keeps XTAB results", {
  parsed <- list(
    "h-xtab-only" = mk_parsed_entry(
      results = mk_result(source_hash = "h-xtab-only", adapter = "als_xtab/1", lab_sample_id = "XX1234567001"),
      meta = list(work_order_guess = "XX1234567")
    )
  )
  out <- assemble_events(parsed)
  event <- out$events[[1]]
  expect_valid_event(event)
  expect_equal(nrow(event$results), 1)
  expect_true(event$files$kept[event$files$hash == "h-xtab-only"])
})

test_that("R-7.2: ACIRL field results survive alongside ESdat lab results", {
  parsed <- list(
    "h-esdat" = mk_parsed_entry(
      results = mk_result(source_hash = "h-esdat", adapter = "esdat/1", analyte_raw = "Fluoride"),
      meta = list(work_order_guess = "XX1234567")
    ),
    "h-acirl" = mk_parsed_entry(
      results = mk_result(source_hash = "h-acirl", adapter = "acirl_field_xlsx/1", org = "ACIRL",
                           analyte_raw = "pH", sample_type = "Normal"),
      meta = list(work_order_guess = "XX1234567")
    )
  )
  out <- assemble_events(parsed)
  event <- out$events[[1]]
  expect_valid_event(event)
  expect_equal(nrow(event$results), 2)
  expect_true(all(event$files$kept))
})

test_that("R-7.2: equal-rank duplicate renderings keep the higher revision", {
  parsed <- list(
    "h-xtab-r0" = mk_parsed_entry(
      results = mk_result(source_hash = "h-xtab-r0", adapter = "als_xtab/1", revision = 0L, value_raw = "0.1"),
      meta = list(work_order_guess = "XX1234567")
    ),
    "h-xtab-r1" = mk_parsed_entry(
      results = mk_result(source_hash = "h-xtab-r1", adapter = "als_xtab/1", revision = 1L, value_raw = "0.3"),
      meta = list(work_order_guess = "XX1234567")
    )
  )
  out <- assemble_events(parsed)
  event <- out$events[[1]]
  expect_valid_event(event)
  expect_true(event$files$kept[event$files$hash == "h-xtab-r1"])
  expect_false(event$files$kept[event$files$hash == "h-xtab-r0"])
  dropped_state <- out$states[out$states$hash == "h-xtab-r0", ]
  expect_identical(dropped_state$state, "ignored")
  expect_identical(dropped_state$reason, "superseded_by_better_source")
})

test_that("R-7.2: equal-rank same-revision duplicates keep either and warn with both hashes", {
  # content-identical by construction (same revision, same values)
  parsed <- list(
    "h-xtab-a" = mk_parsed_entry(
      results = mk_result(source_hash = "h-xtab-a", adapter = "als_xtab/1", revision = 0L, value_raw = "0.1"),
      meta = list(work_order_guess = "XX1234567")
    ),
    "h-xtab-b" = mk_parsed_entry(
      results = mk_result(source_hash = "h-xtab-b", adapter = "als_xtab/1", revision = 0L, value_raw = "0.1"),
      meta = list(work_order_guess = "XX1234567")
    )
  )
  out <- assemble_events(parsed)
  event <- out$events[[1]]
  expect_valid_event(event)
  n_kept <- sum(event$files$kept[event$files$hash %in% c("h-xtab-a", "h-xtab-b")])
  expect_equal(n_kept, 1)
  expect_true(any(grepl("h-xtab-a", event$report$warnings, fixed = TRUE)))
  expect_true(any(grepl("h-xtab-b", event$report$warnings, fixed = TRUE)))
})

# ---- R-7.3: sample-metadata join ----------------------------------------

test_that("R-7.3: ESdat event gains Sample2e datetime and sample_type, unknowns gone", {
  parsed <- list(
    "h-chem" = mk_parsed_entry(
      results = dplyr::bind_rows(
        mk_result(source_hash = "h-chem", lab_sample_id = "XX1234567001", sample_type = "unknown"),
        mk_result(source_hash = "h-chem", lab_sample_id = "XX1234567002", sample_type = "unknown")
      ),
      meta = list(work_order_guess = "XX1234567")
    ),
    "h-samp" = mk_parsed_entry(
      samples = dplyr::bind_rows(
        mk_sample(source_hash = "h-samp", lab_sample_id = "XX1234567001", feature_raw = "T.S01",
                  sample_datetime_raw = "24 May 2025 11:45", sample_type = "Normal"),
        mk_sample(source_hash = "h-samp", lab_sample_id = "XX1234567002", feature_raw = "T.S02",
                  sample_datetime_raw = "24 May 2025 11:10", sample_type = "Normal")
      ),
      meta = list(work_order_guess = "XX1234567")
    )
  )
  out <- assemble_events(parsed)
  event <- out$events[[1]]
  expect_valid_event(event)
  expect_true("sample_datetime_raw" %in% names(event$results))
  expect_false(any(event$results$sample_type == "unknown"))
  expect_true(all(!is.na(event$results$sample_datetime_raw)))
  row1 <- event$results[event$results$lab_sample_id == "XX1234567001", ]
  expect_identical(row1$sample_datetime_raw[[1]], "24 May 2025 11:45")
})

test_that("R-7.3: ESdat results (feature_raw NA) gain feature_raw from the Sample2e join - A44", {
  # Real ESdat Chemistry2e carries no feature - it lives only on Sample2e, so
  # results start with feature_raw = NA and MUST be filled from the joined
  # sample. Without this, every ESdat row is an unknown feature and (before the
  # reconcile NA-guard) became an orphan sample/analysis at commit.
  parsed <- list(
    "h-chem" = mk_parsed_entry(
      results = dplyr::bind_rows(
        mk_result(source_hash = "h-chem", lab_sample_id = "XX1234567001", feature_raw = NA_character_),
        mk_result(source_hash = "h-chem", lab_sample_id = "XX1234567002", feature_raw = NA_character_)
      ),
      meta = list(work_order_guess = "XX1234567")
    ),
    "h-samp" = mk_parsed_entry(
      samples = dplyr::bind_rows(
        mk_sample(source_hash = "h-samp", lab_sample_id = "XX1234567001", feature_raw = "T.S01",
                  sample_datetime_raw = "24 May 2025 11:45"),
        mk_sample(source_hash = "h-samp", lab_sample_id = "XX1234567002", feature_raw = "T.S02",
                  sample_datetime_raw = "24 May 2025 11:10")
      ),
      meta = list(work_order_guess = "XX1234567")
    )
  )
  out <- assemble_events(parsed)
  event <- out$events[[1]]
  expect_false(any(is.na(event$results$feature_raw)))
  expect_identical(event$results$feature_raw[event$results$lab_sample_id == "XX1234567001"][[1]], "T.S01")
  expect_identical(event$results$feature_raw[event$results$lab_sample_id == "XX1234567002"][[1]], "T.S02")
})

test_that("R-12.15 M1: a crosstab row's INLINE feature_raw wins over a joinable sample's differing feature (A44.2 is.na() guard)", {
  # T-2 M1 mutation-kill: every other fixture in this file has the joined
  # sample's feature equal to the row's own inline feature, so removing the
  # A44.2 `is.na(feature_raw)` guard is invisible to them (the unconditional
  # fill would write back the SAME value it already has). Here the crosstab
  # row carries a non-NA inline feature_raw ("T.S01") and is joined by
  # lab_sample_id (not the feature-key fallback, which would trivially force
  # equality) to a sample row whose feature_raw genuinely differs
  # ("T.MW01") - e.g. a mislabelled Sample2e row for the same lab code. The
  # guarded code must leave the crosstab row's own inline value alone.
  parsed <- list(
    "h-xtab" = mk_parsed_entry(
      results = mk_result(source_hash = "h-xtab", adapter = "als_xtab/1",
                           lab_sample_id = "XX1234567001", feature_raw = "T.S01"),
      meta = list(work_order_guess = "XX1234567")
    ),
    "h-samp" = mk_parsed_entry(
      samples = mk_sample(source_hash = "h-samp", lab_sample_id = "XX1234567001",
                           feature_raw = "T.MW01"),
      meta = list(work_order_guess = "XX1234567")
    )
  )
  out <- assemble_events(parsed)
  event <- out$events[[1]]
  expect_valid_event(event)
  expect_equal(nrow(event$results), 1)
  expect_identical(event$results$feature_raw[[1]], "T.S01")
})

test_that("R-7.3: fallback join matches on feature_raw when lab_sample_id is absent", {
  # Single visit per feature - avoids the unresolved "date part" mechanism
  # for results (see PLAN-CHANGE-REQUESTS.md).
  parsed <- list(
    "h-xtab" = mk_parsed_entry(
      results = mk_result(source_hash = "h-xtab", adapter = "als_xtab/1", lab_sample_id = NA_character_,
                           feature_raw = "  t.s01  ", sample_type = "unknown"),
      meta = list(work_order_guess = "XX1234567")
    ),
    "h-acirl-samp" = mk_parsed_entry(
      samples = mk_sample(source_hash = "h-acirl-samp", adapter = "acirl_field_xlsx/1", org = "ACIRL",
                           lab_sample_id = NA_character_, feature_raw = "T.S01",
                           sample_datetime_raw = "24/05/2025", sample_type = "Normal"),
      meta = list(work_order_guess = "XX1234567")
    )
  )
  out <- assemble_events(parsed)
  event <- out$events[[1]]
  expect_valid_event(event)
  expect_equal(nrow(event$results), 1)
  expect_identical(event$results$sample_type[[1]], "Normal")
  expect_identical(event$results$sample_datetime_raw[[1]], "24/05/2025")
})

test_that("R-7.3: an engineered sample_datetime_raw mismatch flags exactly one row for review without blocking the rest", {
  # NOTE: assembly's review-marking interface isn't pinned by PLAN-07;
  # assumed here to be a `needs_review` lgl column on the joined results
  # tibble. See PLAN-CHANGE-REQUESTS.md ("assembly-stage review-marking
  # interface not pinned").
  parsed <- list(
    "h-chem" = mk_parsed_entry(
      results = dplyr::bind_rows(
        mk_result(source_hash = "h-chem", lab_sample_id = "XX1234567001", sample_type = "unknown"),
        mk_result(source_hash = "h-chem", lab_sample_id = "XX1234567002", sample_type = "unknown")
      ),
      meta = list(work_order_guess = "XX1234567")
    ),
    "h-samp-a" = mk_parsed_entry(
      samples = mk_sample(source_hash = "h-samp-a", lab_sample_id = "XX1234567001", feature_raw = "T.S01",
                          sample_datetime_raw = "24 May 2025 11:45", sample_type = "Normal"),
      meta = list(work_order_guess = "XX1234567")
    ),
    # conflicting datetime for the SAME lab_sample_id from a second source -
    # date part disagrees (24th vs 25th)
    "h-samp-b" = mk_parsed_entry(
      samples = dplyr::bind_rows(
        mk_sample(source_hash = "h-samp-b", lab_sample_id = "XX1234567001", feature_raw = "T.S01",
                  sample_datetime_raw = "25 May 2025 09:00", sample_type = "Normal"),
        mk_sample(source_hash = "h-samp-b", lab_sample_id = "XX1234567002", feature_raw = "T.S02",
                  sample_datetime_raw = "24 May 2025 11:10", sample_type = "Normal")
      ),
      meta = list(work_order_guess = "XX1234567")
    )
  )
  expect_no_error(out <- assemble_events(parsed))
  event <- out$events[[1]]
  expect_valid_event(event)
  # the whole event still assembles - both result rows are present
  expect_equal(nrow(event$results), 2)
  expect_true(
    "needs_review" %in% names(event$results),
    info = "assembly must expose some review marker on the joined results tibble (interface not pinned by PLAN-07 - see PLAN-CHANGE-REQUESTS.md)"
  )
  flagged <- event$results$needs_review
  expect_equal(sum(flagged, na.rm = TRUE), 1)
  # the unrelated row (XX1234567002) is not blocked/flagged
  clean_row <- event$results[event$results$lab_sample_id == "XX1234567002", ]
  expect_false(isTRUE(clean_row$needs_review[[1]]))
})

# ---- R-7.4: multi-work-order ESdat partitioning -------------------------

test_that("R-7.4: multi-work-order ESdat file contributes only its own work order's rows to the event", {
  parsed <- list(
    "h-multi" = mk_parsed_entry(
      results = dplyr::bind_rows(
        mk_result(source_hash = "h-multi", work_order = "XX1234567", lab_sample_id = "XX1234567001", sample_type = "unknown"),
        mk_result(source_hash = "h-multi", work_order = "YY0000001", lab_sample_id = "YY0000001", sample_type = "NCP"),
        mk_result(source_hash = "h-multi", work_order = "ZZ0000002", lab_sample_id = "ZZ0000002001", sample_type = "Normal")
      ),
      meta = list(work_order_guess = "XX1234567")
    )
  )
  out <- assemble_events(parsed)
  expect_length(out$events, 1)
  event <- out$events[[1]]
  expect_valid_event(event)
  expect_identical(event$work_order, "XX1234567")
  expect_true(all(event$results$work_order == "XX1234567" | event$results$needs_review %in% TRUE))
  expect_false(any(event$results$work_order == "YY0000001"))
})

test_that("R-7.4: NCP rows are counted in n_ncp_foreign, absent from results, and not flagged for review", {
  parsed <- list(
    "h-multi" = mk_parsed_entry(
      results = dplyr::bind_rows(
        mk_result(source_hash = "h-multi", work_order = "XX1234567", lab_sample_id = "XX1234567001", sample_type = "unknown"),
        mk_result(source_hash = "h-multi", work_order = "YY0000001", lab_sample_id = "YY0000001", sample_type = "NCP")
      ),
      meta = list(work_order_guess = "XX1234567")
    )
  )
  out <- assemble_events(parsed)
  event <- out$events[[1]]
  expect_valid_event(event)
  expect_identical(event$report$n_ncp_foreign, 1L)
  expect_false(any(event$results$sample_type == "NCP"))
  expect_false(any(event$results$work_order == "YY0000001"))
})

test_that("R-7.4: a non-NCP foreign-work-order row is flagged for review", {
  parsed <- list(
    "h-multi" = mk_parsed_entry(
      results = dplyr::bind_rows(
        mk_result(source_hash = "h-multi", work_order = "XX1234567", lab_sample_id = "XX1234567001", sample_type = "unknown"),
        mk_result(source_hash = "h-multi", work_order = "ZZ0000002", lab_sample_id = "ZZ0000002001", sample_type = "Normal")
      ),
      meta = list(work_order_guess = "XX1234567")
    )
  )
  out <- assemble_events(parsed)
  event <- out$events[[1]]
  expect_valid_event(event)
  expect_true("needs_review" %in% names(event$results))
  foreign_row <- event$results[event$results$work_order == "ZZ0000002", ]
  expect_equal(nrow(foreign_row), 1)
  expect_true(isTRUE(foreign_row$needs_review[[1]]))
  expect_true(length(event$report$warnings) >= 1)
})

test_that("R-7.4 (seam: real ESdat parser -> assemble_events): a compound-SampleCode NCP row is counted in n_ncp_foreign, dropped from results, and NOT flagged, while a plain foreign row IS flagged", {
  # SEAM test (like R-11.15 below): the other R-7.4 tests hand-build results
  # with an explicit sample_type = "NCP", which bypasses the exact bug this
  # fix closes - the ESdat Chemistry2e parser hard-codes sample_type =
  # "unknown", and the multi-work-order partition (R-7.4) runs on that raw
  # output BEFORE the sample-metadata join could fill it. So the NCP marker
  # must come from the parser's compound-SampleCode detection (R-4.6), or NCP
  # cross-references leak into results as foreign_work_order review items.
  # This test drives the REAL adapter, so a regression in either half fails it.
  register_builtin_adapters()
  esdat <- sampleTidy:::adapter_registry()[["esdat"]]
  chem_path <- test_path("fixtures", "esdat", "PROJ_A.ESDAT_XX1234567_0.Chemistry2e.CSV")
  meta <- sampleTidy:::file_meta(chem_path)
  parsed_chem <- esdat$parse(chem_path, meta)

  parsed <- list(
    "h-chem" = mk_parsed_entry(
      results = parsed_chem$results,
      report = parsed_chem$report,
      meta = list(work_order_guess = "XX1234567")
    )
  )
  out <- assemble_events(parsed)
  expect_length(out$events, 1)
  event <- out$events[[1]]
  expect_valid_event(event)
  expect_identical(event$work_order, "XX1234567")

  # the compound NCP cross-reference (ZZ9999999001_XX1234567) is counted and
  # dropped, never committed, never flagged
  expect_identical(event$report$n_ncp_foreign, 1L)
  expect_false(any(event$results$work_order == "ZZ9999999", na.rm = TRUE))
  expect_false(any(event$results$sample_type == "NCP", na.rm = TRUE))
  expect_false(any(grepl("ZZ9999999", vapply(event$results$review_payload,
    function(p) paste(unlist(p), collapse = " "), character(1)))))

  # the plain foreign row (YY0000001, NO compound suffix) is a genuine foreign
  # result and IS kept + flagged foreign_work_order for review
  yy <- event$results[!is.na(event$results$work_order) &
    event$results$work_order == "YY0000001", ]
  expect_equal(nrow(yy), 1)
  expect_true(isTRUE(yy$needs_review[[1]]))
  expect_identical(yy$review_payload[[1]]$subkind, "foreign_work_order")
  expect_true(any(grepl("foreign_work_order", event$report$warnings, fixed = TRUE)))
})

# ---- R-7.5: event object shape / states completeness --------------------

# ---- R-11.15: ACIRL synthetic lab_sample_id seam (adapter -> assemble) --
#
# NOTE: unlike the rest of this file (whose `parsed` inputs are hand-built
# via ir_results()/ir_samples() so it stays independent of plans 04-06's
# landing order - see the file header), R-11.15's own criteria are pinned
# against the REAL two-visit ACIRL fixture routed through the REAL adapter
# (dev/plans/PLAN-11-feature-alias.md block B-11.15: "after assemble_events()
# on the two-visit ACIRL fixture ..."). This is a genuine producer(adapter)
# -> consumer(assemble) seam per phase4-test-authoring.md's seam-test
# mandate, so this one test intentionally breaks the file's usual
# synthetic-input pattern rather than hand-rolling a stand-in for the
# adapter's output.

test_that("R-11.15 (mandatory seam test): real ACIRL adapter output -> real assemble_events() keeps the 25-May visit dated 25/05/2025 with no spurious value_conflict flag", {
  # This seam test is the only test in the file that reads the REAL adapter
  # registry (the other tests use synthetic mk_*() fixtures). A predecessor in
  # the full-suite alphabetical order (test-adapter-registry.R) defers
  # clear_adapters(), leaving the registry empty - so this test must establish
  # its own precondition rather than depend on global state left by others
  # (same self-registration convention as test-e2e-pipeline.R). register is
  # idempotent (A33).
  register_builtin_adapters()
  acirl <- sampleTidy:::adapter_registry()[["acirl_field_xlsx"]]
  main_path <- test_path("fixtures", "acirl", "2400-9999-01_Test_WMF.xlsx")
  meta <- sampleTidy:::file_meta(main_path)
  parsed_acirl <- acirl$parse(main_path, meta)

  parsed <- list(
    "h-acirl" = mk_parsed_entry(
      results = parsed_acirl$results,
      samples = parsed_acirl$samples,
      report = parsed_acirl$report,
      meta = list(work_order_guess = parsed_acirl$report$header$report_no)
    )
  )
  out <- assemble_events(parsed)
  expect_length(out$events, 1)
  event <- out$events[[1]]
  expect_valid_event(event)

  t_s01 <- event$results[event$results$feature_raw == "T.S01", ]
  # both visit dates survive distinctly on the joined results - the 25-May
  # rows are NOT re-dated to 24-May (the F2 bug this criterion closes)
  expect_setequal(unique(t_s01$sample_datetime_raw), c("24/05/2025", "25/05/2025"))
  visit2 <- t_s01[t_s01$sample_datetime_raw == "25/05/2025", ]
  expect_true(nrow(visit2) > 0)

  # no ACIRL result is flagged value_conflict/sample_datetime_mismatch for a
  # spurious multi-date (feature-only) match - NA-safe on review_kind
  spurious <- event$results$needs_review %in% TRUE &
    !is.na(event$results$review_kind) &
    event$results$review_kind == "value_conflict"
  expect_equal(sum(spurious), 0)

  # both sampling dates exist as distinct samples on the assembled event
  # (the committed-DB half of this criterion is pinned by the e2e suite,
  # PLAN-11 file-ownership table - test-e2e-pipeline.R)
  t_s01_samples <- event$samples[event$samples$feature_raw == "T.S01", ]
  expect_setequal(unique(t_s01_samples$sample_datetime_raw), c("24/05/2025", "25/05/2025"))
})

test_that("R-7.5: assemble_events() states tibble covers every input hash exactly once", {
  parsed <- list(
    "h-esdat" = mk_parsed_entry(
      results = mk_result(source_hash = "h-esdat", adapter = "esdat/1"),
      meta = list(work_order_guess = "XX1234567")
    ),
    "h-xtab" = mk_parsed_entry(
      results = mk_result(source_hash = "h-xtab", adapter = "als_xtab/1"),
      meta = list(work_order_guess = "XX1234567")
    ),
    "h-orphan" = mk_parsed_entry(
      results = mk_result(source_hash = "h-orphan", work_order = NA_character_, adapter = "acirl_field_xlsx/1"),
      meta = list(work_order_guess = NA_character_)
    )
  )
  out <- assemble_events(parsed)
  expect_true(all(c("hash", "state", "reason") %in% names(out$states)))
  expect_setequal(out$states$hash, names(parsed))
  expect_equal(nrow(out$states), length(parsed))
  # each hash appears exactly once
  expect_equal(sum(duplicated(out$states$hash)), 0)
})
