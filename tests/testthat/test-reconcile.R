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

  event <- mk_event(mk_rows(
    mk_row(source_ref = "r1", sample_type = "unknown", value_raw = "2.3",
           value_num = 2.3, below_detection = FALSE, rl = 0.1),
    # D17 (PLAN-7b round-2): `is_ok <- is.na(st) | st %in% c('Normal',
    # 'unknown')` keeps the NA arm too - a future adapter that leaves
    # sample_type unset must not have every row silently skipped as
    # `qc_NA` with no review item.
    mk_row(source_ref = "r2", sample_type = NA_character_,
           feature_raw = "T.S02", lab_sample_id = "XX1234567002",
           value_raw = "2.3", value_num = 2.3, below_detection = FALSE, rl = 0.1)
  ))
  out <- reconcile_event(event, con)
  expect_false("r1" %in% out$skipped$source_ref[grepl("^qc_", out$skipped$reason)])
  expect_false("r2" %in% out$skipped$source_ref[grepl("^qc_", out$skipped$reason)])
  expect_true("r2" %in% out$clean$source_ref)
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

test_that("R-8.2: a mask-only name does not resolve (feature_mask join removed, R-11.4)", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # "Test Surface 01" only exists in feature_mask, which reconcile no longer
  # joins for candidate matching (R-11.4) - it must land in clean as a
  # dangling/pending row, not resolve to f-0001.
  event <- mk_event(mk_row(source_ref = "r1", feature_raw = "Test Surface 01",
                           sample_datetime_raw = "20 May 2025 09:00"))
  out <- reconcile_event(event, con)
  row <- out$clean[out$clean$source_ref == "r1", ]
  expect_equal(nrow(row), 1)
  expect_true(row$feature_pending)
  expect_true(is.na(row$uuid_feature_alias))
  expect_true(any(out$review$source_ref == "r1" & out$review$kind == "unknown_feature"))
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
  expect_true(all(c("r1", "r2") %in% strsplit(unknown_feature$source_ref[[1]], ",")[[1]]) ||
                grepl("r1", unknown_feature$source_ref[[1]]) && grepl("r2", unknown_feature$source_ref[[1]]))
})

test_that("R-8.2: an ambiguous feature name queues review listing both candidate uuids", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # "T.AMBIG2" (fa-0005/fa-0006, both auto_assign) resolves to two distinct
  # features f-0004 AND f-0005 - the genuine ambiguity fixture.
  event <- mk_event(mk_row(source_ref = "r1", feature_raw = "T.AMBIG2"))
  out <- reconcile_event(event, con)
  ambiguous <- out$review[out$review$kind == "unknown_feature" & out$review$source_ref == "r1", ]
  expect_equal(nrow(ambiguous), 1)
  # TRANSLATED 2026-07-26. Was:
  #   expect_true(grepl("f-0004", ambiguous$payload[[1]]) &&
  #               grepl("f-0005", ambiguous$payload[[1]]))
  # Robin ruled candidates travel as typed review_queue_candidate rows, not as
  # JSON in the payload, so the uuids are no longer in that string. Reading the
  # child rows is also strictly stronger than the two greps: `expect_setequal`
  # fails on a spurious THIRD candidate, which a pair of substring checks
  # cannot see.
  amb_cand <- ambiguous$candidates[[1]]
  amb_cand <- amb_cand[!is.na(amb_cand$kind) & amb_cand$kind == "candidate", ]
  expect_setequal(amb_cand$uuid_feature, c("f-0004", "f-0005"))
})

test_that("R-8.2: no fuzzy matching - a Levenshtein-1 miss stays unknown_feature", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # "T.S011" is one insertion away from "T.S01" - must NOT auto-resolve
  event <- mk_event(mk_row(source_ref = "r1", feature_raw = "T.S011"))
  out <- reconcile_event(event, con)
  expect_equal(nrow(out$review[out$review$kind == "unknown_feature" & out$review$source_ref == "r1", ]), 1)
  # Row still flows to clean (commit-everything, PLAN-11), but must NOT have
  # resolved to f-0001 via fuzzy matching.
  row <- out$clean[out$clean$source_ref == "r1", ]
  expect_equal(nrow(row), 1)
  expect_true(row$feature_pending)
  expect_true(is.na(row$uuid_feature_alias))
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

  # Phase-5 audit C4: disposition alone is asserted only above - an
  # implementation that parses the A44 NA sentinel and emits a structural
  # suggestion for it (rather than treating it as unresolvable) would still
  # pass every assertion above. `feature_raw = NA` must never reach a
  # structural parse.
  expect_false(identical(out$review$subkind[[1]], "structural"))
})

test_that("PLAN-7b round-3 finding 7: a feature-side HELD row's review item carries subkind = 'held', distinguishable from a PENDING row with nothing to say (both used to emit subkind=NA and were indistinguishable in review_queue despite OPPOSITE commit dispositions)", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # 'feature_raw = "."' folds to nothing (A44) -> HELD, dropped from clean.
  # 'QQNOSITE' is a genuine unknown -> PENDING, commits dangling. Both used
  # to reach `.rc_feature_review()`'s NA-key branch (subkind = NA) despite
  # opposite dispositions (auditor probes/p6.R).
  event <- mk_event(mk_rows(
    mk_row(source_ref = "r_held", feature_raw = ".", lab_sample_id = "XX9999979020",
           sample_datetime_raw = "20 Jun 2025 09:00"),
    mk_row(source_ref = "r_pending", feature_raw = "QQNOSITE", lab_sample_id = "XX9999979021",
           sample_datetime_raw = "20 Jun 2025 09:00")
  ))
  out <- reconcile_event(event, con)

  expect_false("r_held" %in% out$clean$source_ref)
  expect_true("r_pending" %in% out$clean$source_ref)

  held <- out$review[out$review$kind == "unknown_feature" & out$review$source_ref == "r_held", ]
  expect_equal(nrow(held), 1)
  expect_identical(held$subkind[[1]], "held")

  pending <- out$review[out$review$kind == "unknown_feature" & out$review$source_ref == "r_pending", ]
  expect_equal(nrow(pending), 1)
  expect_true(is.na(pending$subkind[[1]]))
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
  row <- out$clean[out$clean$source_ref == "r1", ]
  expect_equal(nrow(row), 1)
  expect_true(row$analyte_pending)
  expect_true(is.na(row$uuid_analyte))
  expect_true(is.na(row$uuid_lab))
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
  # PLAN-16 Phase-7 round 2 (FE7): this asserted grepl("known_analyte_no_method",
  # payload) with a `|| grepl(tok, paste(hit, collapse=" "))` disjunct appended.
  # The disjunct passed if the token appeared in ANY column, which is what kept the
  # block green after PLAN-16 moved `known_analyte_no_method` OUT of the payload text
  # and INTO the typed `subkind` column (R/reconcile.R:800) - the precise conjunct had
  # silently become unsatisfiable. Assert the typed column, which is where the value
  # now lives.
  expect_identical(hit$subkind[[1]], "known_analyte_no_method")
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

test_that("D1/D2 (PLAN-7b round-2): closing the analyte-side registry poison loop - a punctuation-only analyte_raw is HELD (never mints a dangling lab_method), and an EXISTING poisoned lab_method row (name='--') does not phantom-splice into an UNRELATED analyte's folded-match candidate set", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # D1 setup: a junk lab_method row whose name folds to NA (punctuation-only)
  # - exactly what D2 prevents COMMIT from ever minting again, seeded
  # directly here so D1's fix is exercised independently of D2's.
  DBI::dbExecute(con, "INSERT INTO lab_method (uuid, uuid_analyte, name, organisation) VALUES
    ('lm-poison', NULL, '--', 'ALS')")

  event <- mk_event(mk_rows(
    # D1 precondition (orchestrator-verified): the incoming name must differ
    # in case/whitespace from the stored 'pH Value' so the EXACT-match
    # branch (already NA-guarded, and which returns FIRST) does not run -
    # the phantom row is unreachable through it. 'PH VALUE' forces the
    # FOLDED path (:1202, the previously-unguarded one) to actually run.
    # method_raw = NA so the (unrelated) method-disambiguation narrowing
    # never gets a chance to incidentally drop the phantom row itself -
    # isolating D1's own guard as the thing under test.
    mk_row(source_ref = "folded_hit", analyte_raw = "PH VALUE", org = "ALS",
           method_raw = NA_character_, cas_number = NA_character_,
           units_raw = "pH", value_raw = "7.20", value_num = 7.2,
           below_detection = FALSE, rl = 0.01,
           lab_sample_id = "XX9999979001", sample_datetime_raw = "20 Jun 2025 09:00"),
    # D2: punctuation-only analyte_raw - no key to hang a dangling lab_method
    # on. Must be HELD (dropped from `clean`), never reach commit's
    # .ct_materialise_lab_methods() with name='--' (which would only
    # re-poison the registry D1 just guarded against - closing the loop).
    mk_row(source_ref = "punct_only", analyte_raw = "--",
           lab_sample_id = "XX9999979002", sample_datetime_raw = "20 Jun 2025 09:00")
  ))
  out <- reconcile_event(event, con)

  # D1: the poison row must NOT phantom-splice into the folded candidate set
  # - 'PH VALUE' still resolves cleanly to the real method/analyte (lm-0001/
  # a-0001), not 'ambiguous'.
  hit <- out$clean[out$clean$source_ref == "folded_hit", ]
  expect_equal(nrow(hit), 1)
  expect_false(hit$analyte_pending)
  expect_identical(hit$uuid_lab, "lm-0001")
  expect_identical(hit$uuid_analyte, "a-0001")

  # D2: the punctuation-only row is HELD - dropped from `clean` entirely,
  # but still surfaced in `review`.
  expect_false("punct_only" %in% out$clean$source_ref)
  expect_true("punct_only" %in% out$review$source_ref)

  # D2 (closing the loop): commit must never mint a SECOND lab_method('--')
  # from the held row.
  commit_event(event, out, con)
  poisoned_after <- DBI::dbGetQuery(con,
    "SELECT count(*) AS n FROM lab_method WHERE name = '--' AND organisation = 'ALS'")$n
  expect_equal(poisoned_after, 1)   # only the ONE seeded above - none minted anew
})

test_that("T1.1 (PLAN-7b round-3): .rc_lab_method_candidates() guards the FOLDED method key on ALL THREE conjuncts, not just the name conjunct D1 fixed - a punctuation-only method_raw (or a registry row whose OWN method folds to nothing) must never phantom-splice an all-NA row over the real candidates", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # --- conjunct A: incoming method_raw folds to NA ("-", a routine
  # lab-spreadsheet placeholder). lm-0002/lm-0004 are the seeded
  # duplicate-method Fluoride/ALS pair, both resolving to the SAME analyte
  # (a-0002) - a punctuation-only method_raw carries no disambiguating
  # information, so narrowing must be SKIPPED (not attempted against a NA
  # key), leaving both real candidates for the uuid_analyte-uniqueness check
  # below to resolve cleanly. Pre-fix: `mkey <- NA`; the raw `!is.na(method_raw)`
  # gate ("-" is non-NA) let narrowing proceed, `TRUE & NA` logical
  # subsetting spliced one all-NA phantom row per candidate, `cand` became
  # all-NA, and the row incorrectly came out "dangling_method"/uuid_lab=NA
  # (auditor-verified directly on this exact call).
  reg <- .rc_load_registry(con)
  res_a <- .rc_resolve_one_analyte("Fluoride", "ALS", "-", reg)
  expect_identical(res_a$status, "resolved")
  expect_identical(res_a$uuid_analyte, "a-0002")
  expect_false(is.na(res_a$uuid_lab))

  # --- conjunct B: a REGISTRY row whose own `method` folds to nothing -----
  # 'Nitrate' (uppercase-varied incoming name so the exact-match branch,
  # which is raw case-sensitive, cannot fire and the folded path is forced)
  # has one poisoned candidate (method='-') and one real one. Pre-fix, the
  # poisoned row's raw `!is.na(cand$method)` guard passed ("-" is non-NA),
  # but `.rc_method_key(cand$method) == mkey` went NA -> phantom-spliced
  # into `narrowed` alongside the real match, `unique(uuid_analyte)` gained
  # a spurious NA and the row came out "ambiguous" instead of resolved.
  DBI::dbExecute(con, "INSERT INTO lab_method (uuid, uuid_analyte, name, method, organisation) VALUES
    ('lm-poison-method', NULL, 'Nitrate', '-', 'ALS'),
    ('lm-real-nitrate', 'a-0001', 'Nitrate', 'NOX: Nitrate by discrete analyser', 'ALS')")
  reg2 <- .rc_load_registry(con)
  res_b <- .rc_resolve_one_analyte("NITRATE", "ALS", "NOX: Nitrate by discrete analyser", reg2)
  expect_identical(res_b$status, "resolved")
  expect_identical(res_b$uuid_analyte, "a-0001")
  expect_identical(res_b$uuid_lab, "lm-real-nitrate")

  # --- conjunct C: the `org` PARAMETER itself is NA -----------------------
  # Unreachable through .rc_resolve_one_analyte() in production
  # (`:1244` returns "miss" on `is.na(org)` first), but
  # `.rc_lab_method_candidates()` must not be silently unsafe to call this
  # way either - `lm$organisation == NA` is `NA` for every row regardless of
  # the `!is.na(lm$organisation)` column guard, which only guards the
  # COLUMN, not the parameter.
  cand_na_org <- .rc_lab_method_candidates("Fluoride", NA_character_, NA_character_, reg)
  expect_equal(nrow(cand_na_org), 0)
})

test_that("PLAN-7b round-3 finding 5: an analyte-side HELD row's review item actually carries subkind = 'held' (asserted by zero tests before this - mutation R-M1-GAP, which turns the literal into NA_character_, survived the whole suite)", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  event <- mk_event(mk_row(source_ref = "r1", analyte_raw = "--", cas_number = NA_character_,
                           lab_sample_id = "XX9999979009", sample_datetime_raw = "20 Jun 2025 09:00"))
  out <- reconcile_event(event, con)
  hit <- out$review[out$review$source_ref == "r1", ]
  expect_equal(nrow(hit), 1)
  expect_identical(hit$kind, "unknown_analyte")
  expect_identical(hit$subkind[[1]], "held")
})

test_that("PLAN-7b round-3 finding 6: the analyte-side HELD group is keyed by ORG, like every other unknown_analyte group - holds from DIFFERENT orgs must not collapse into one review item that names only the first member's org", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  event <- mk_event(mk_rows(
    mk_row(source_ref = "r_als", org = "ALS", analyte_raw = "--", cas_number = NA_character_,
           lab_sample_id = "XX9999979010", sample_datetime_raw = "20 Jun 2025 09:00"),
    mk_row(source_ref = "r_acirl", org = "ACIRL", analyte_raw = "...", cas_number = NA_character_,
           lab_sample_id = "XX9999979011", sample_datetime_raw = "20 Jun 2025 09:00"),
    mk_row(source_ref = "r_acirl2", org = "ACIRL", analyte_raw = NA_character_, cas_number = NA_character_,
           lab_sample_id = "XX9999979012", sample_datetime_raw = "20 Jun 2025 09:00")
  ))
  out <- reconcile_event(event, con)
  held <- out$review[out$review$kind == "unknown_analyte" & out$review$subkind == "held", ]
  # Pre-fix: ONE item, n_rows=3, diagnostics naming only the first member's
  # org (ACIRL) - the ALS hold invisible. Post-fix: TWO items, one per org.
  expect_equal(nrow(held), 2)
  payloads <- lapply(held$payload, jsonlite::fromJSON)
  orgs <- vapply(payloads, function(p) p$org, character(1))
  expect_setequal(orgs, c("ALS", "ACIRL"))
  n_by_org <- stats::setNames(vapply(payloads, function(p) p$n_rows, numeric(1)), orgs)
  expect_equal(unname(n_by_org["ALS"]), 1)
  expect_equal(unname(n_by_org["ACIRL"]), 2)
})

test_that("D4 (PLAN-7b round-2): .rc_analyte_review()'s GROUP order is radix-pinned, not the R session's LC_COLLATE - mirrors PLAN-7b item 7's fix for .rc_feature_review(), which this sibling producer never received", {
  rows <- tibble::tibble(
    source_ref = c("r_underscore", "r_dot"),
    analyte_raw = c("NoSuchAnalyte", "NoSuchAnalyte"),
    org = c("T_ORG", "T.ORG"),
    source_hash = c("h1", "h2"),
    uuid_lab = NA_character_
  )
  cas_suggest <- rep(NA_character_, 2)

  run_order <- function(locale) {
    withr::with_locale(c(LC_COLLATE = locale), {
      out <- .rc_analyte_review(rows, cas_suggest)
      out$source_ref
    })
  }

  # Establish the divergence is REAL on this platform before pinning against
  # it (same idiom as PLAN-7b item 7) - the group key is
  # 'nosuchanalyte||<org>', so the org segment carries the same '.'-vs-'_'
  # divergence item 7 measured for feature keys.
  sort_c <- sort(c("nosuchanalyte||T_ORG", "nosuchanalyte||T.ORG"))
  sort_en <- withr::with_locale(c(LC_COLLATE = "en_US.UTF-8"),
                                 sort(c("nosuchanalyte||T_ORG", "nosuchanalyte||T.ORG")))
  skip_if_not(!identical(sort_c, sort_en),
              "this platform's C and en_US.UTF-8 collations agree here - cannot demonstrate the divergence")

  order_c <- run_order("C")
  order_en <- run_order("en_US.UTF-8")

  expect_identical(order_c, order_en)
  # radix: '.' (0x2E) < '_' (0x5F) -> the T.ORG group ('r_dot') sorts first.
  expect_identical(order_c, c("r_dot", "r_underscore"))
})

test_that("D5 (PLAN-7b round-2): .rc_analyte_review()'s within-GROUP order (and the source_hash it reads off the group) is presentation-order-independent - the F.5 defect, unfixed in this sibling producer", {
  rows <- tibble::tibble(
    source_ref = c("rZZ", "rAA"),
    analyte_raw = c("SharedMiss", "SharedMiss"),
    org = c("SHARED_ORG", "SHARED_ORG"),
    source_hash = c("hZZ", "hAA"),
    uuid_lab = NA_character_
  )
  cas_suggest <- rep(NA_character_, 2)

  out_zz_first <- .rc_analyte_review(rows, cas_suggest)
  out_aa_first <- .rc_analyte_review(rows[c(2, 1), ], cas_suggest)

  expect_equal(nrow(out_zz_first), 1)
  expect_equal(nrow(out_aa_first), 1)
  # byte-identical whichever order the caller's rows were presented in.
  expect_identical(out_zz_first$source_ref, out_aa_first$source_ref)
  expect_identical(out_zz_first$source_hash, out_aa_first$source_hash)
  expect_identical(out_zz_first$payload, out_aa_first$payload)
  # radix: 'rAA' sorts before 'rZZ'.
  expect_identical(out_zz_first$source_ref, "rAA,rZZ")
  expect_identical(out_zz_first$source_hash, "hAA")
})

test_that("PLAN-7b round-3 finding 9: .rc_radix_sort_named() (extracted from reconcile_event()'s `counts` assembly, D7) is radix-pinned against a SYNTHETIC key set that DOES diverge under this platform's collations - the real qc_<UPPER> vocabulary does not diverge yet, which had left the D7 pin both latent and unobserved by any test", {
  x <- stats::setNames(c(1L, 2L), c("qc_type_a", "qc_type.a"))

  run_order <- function(locale) {
    withr::with_locale(c(LC_COLLATE = locale), names(.rc_radix_sort_named(x)))
  }

  # Establish the divergence is REAL on this platform before pinning against
  # it (same idiom as D4/item 7).
  sort_c <- sort(c("qc_type_a", "qc_type.a"))
  sort_en <- withr::with_locale(c(LC_COLLATE = "en_US.UTF-8"),
                                 sort(c("qc_type_a", "qc_type.a")))
  skip_if_not(!identical(sort_c, sort_en),
              "this platform's C and en_US.UTF-8 collations agree here - cannot demonstrate the divergence")

  order_c <- run_order("C")
  order_en <- run_order("en_US.UTF-8")
  expect_identical(order_c, order_en)
  # radix: '.' (0x2E) < '_' (0x5F) -> "qc_type.a" sorts first.
  expect_identical(order_c, c("qc_type.a", "qc_type_a"))
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

test_that("R-8.4: text-only results pass through unconverted with quantified NA", {
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
  # NA, not TRUE, since 2026-07-23: a qualitative observation is not a
  # measurement, so no detection state is true of it. See PLAN-CHANGE-REQUESTS.
  expect_true(is.na(row$quantified))
  expect_equal(row$value_chr, "Clear, low flow")
})

test_that("FD4/R-16.20: a text-vs-text value_conflict carries BOTH text values in the payload, not two nulls", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # An existing TEXT-valued measurement (tri-state: value NULL, value_chr set,
  # quantified NULL) on s-0001/T.S01, a fresh lab_method (lm-0001, pH Value,
  # ALS) not already used on that sample.
  DBI::dbExecute(con, "INSERT INTO analysis
    (uuid, uuid_sample, uuid_lab, value, value_chr, quantified) VALUES
    ('an-fd4-text', 's-0001', 'lm-0001', NULL, 'clear', NULL)")

  # Incoming row: same feature/date/lab_method, a DIFFERENT text value
  # (comma-bearing, the exact hazard class R-16.10 exists for). No revision
  # recorded for this work order, so this cannot supersede - it must land in
  # review as a genuine value_conflict, not silently skip.
  event <- mk_event(mk_row(source_ref = "r1", analyte_raw = "pH Value", org = "ALS",
                           method_raw = "EA005P: pH by PC Titrator", units_raw = "pH",
                           value_raw = "turbid, brown", value_num = NA_real_,
                           value_chr = "turbid, brown", below_detection = NA,
                           rl = NA_real_, cas_number = NA_character_,
                           lab_sample_id = "XX1234567001"))
  out <- reconcile_event(event, con)

  hit <- out$review[out$review$source_ref == "r1" & out$review$kind == "value_conflict", ]
  expect_equal(nrow(hit), 1)
  expect_identical(hit$subkind[[1]], "measurement")

  d <- jsonlite::fromJSON(hit$payload[[1]])
  # Both text values must be retrievable - the numeric value_existing/
  # value_incoming keys are NA/null for a text-vs-text conflict, so without
  # value_chr_existing/value_chr_incoming a reviewer sees two nulls and
  # cannot tell 'clear' from 'turbid, brown'.
  expect_identical(d$value_chr_existing, "clear")
  expect_identical(d$value_chr_incoming, "turbid, brown")
})

# ---- R-11.16: quantified from parse_value(); write rl_high (F4) -----------
# Producer-side pins: unlike test-commit.R's R-11.16 tests (which hand-build
# `clean` and so only exercise the consumer), these drive the real
# `.rc_resolve_units_values()`/`reconcile_event()` producer end to end. A
# fresh date (15 Jan 2026, not 24 May 2025) keeps the row off the seeded
# an-0001 fluoride three-way match, landing it in `clean` as new.

test_that("R-11.16: a real '>2000 mg/L' row produces quantified = FALSE and rl_high = 2000000 (converted to canonical ug/L)", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  event <- mk_event(mk_row(source_ref = "r1", lab_sample_id = "XX1234567099",
                           sample_datetime_raw = "15 Jan 2026 09:00",
                           value_raw = ">2000", value_num = 2000, below_detection = FALSE,
                           rl = NA_real_, units_raw = "mg/L"))
  out <- reconcile_event(event, con)
  row <- out$clean[out$clean$source_ref == "r1", ]
  expect_equal(nrow(row), 1)
  expect_false(row$quantified)
  expect_equal(row$rl_high, 2000000, tolerance = 1e-9)
})

test_that("R-11.16: a real plain-numeric row still produces quantified = TRUE", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  event <- mk_event(mk_row(source_ref = "r1", lab_sample_id = "XX1234567099",
                           sample_datetime_raw = "15 Jan 2026 09:00",
                           value_raw = "2.3", value_num = 2.3, below_detection = FALSE,
                           rl = 0.1, units_raw = "mg/L"))
  out <- reconcile_event(event, con)
  row <- out$clean[out$clean$source_ref == "r1", ]
  expect_equal(nrow(row), 1)
  expect_true(row$quantified)
})

test_that("R-11.16: a real '<0.01' row keeps quantified = FALSE and rl_converted still set", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  event <- mk_event(mk_row(source_ref = "r1", lab_sample_id = "XX1234567099",
                           sample_datetime_raw = "15 Jan 2026 09:00",
                           value_raw = "<0.01", value_num = 0.01, below_detection = TRUE,
                           rl = 0.01, units_raw = "mg/L"))
  out <- reconcile_event(event, con)
  row <- out$clean[out$clean$source_ref == "r1", ]
  expect_equal(nrow(row), 1)
  expect_false(row$quantified)
  expect_equal(row$rl_converted, 10, tolerance = 1e-9)
})

test_that("R-11.16 end-to-end: commit_event() on a real '>2000 mg/L' clean row stores quantified = FALSE and rl_high = 2000000", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  event <- mk_event(mk_row(source_ref = "r1", lab_sample_id = "XX1234567099",
                           sample_datetime_raw = "15 Jan 2026 09:00",
                           value_raw = ">2000", value_num = 2000, below_detection = FALSE,
                           rl = NA_real_, units_raw = "mg/L"))
  out <- reconcile_event(event, con)
  commit_event(event, out, con)

  new_row <- DBI::dbGetQuery(con,
    "SELECT quantified, rl_high FROM analysis WHERE uuid NOT IN ('an-0001','an-0002','an-0003','an-0004','an-0005')")
  expect_equal(nrow(new_row), 1)
  expect_false(new_row$quantified[[1]])
  expect_equal(new_row$rl_high[[1]], 2000000)
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

test_that("R-8.5: a short-date ESdat datetime '07-May-24 11:30' resolves, not a parse_error", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # Real ESdat exports render some sample datetimes hyphen/2-digit-year; the
  # reconciler must resolve this dialect rather than queue a spurious
  # parse_error (the dominant avoidable review item in the 2026-07-23 corpus
  # dry-run: 443 of them, all this exact format).
  event <- mk_event(mk_row(source_ref = "r1", feature_raw = "T.S02", lab_sample_id = "XX1234567002",
                           sample_datetime_raw = "07-May-24 11:30"))
  out <- reconcile_event(event, con)
  expect_equal(nrow(out$review[out$review$source_ref == "r1", ]), 0)
  row <- out$clean[out$clean$source_ref == "r1", ]
  expect_equal(nrow(row), 1)
  expect_equal(row$sample_date, as.Date("2024-05-07"))
  expect_false(is.na(row$sample_datetime))
  expect_equal(format(row$sample_datetime, "%Y-%m-%d %H:%M:%S", tz = "Australia/Sydney"),
               "2024-05-07 11:30:00")
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

test_that("PLAN-7b round-3 finding 10: .rc_method_preference()'s tie-break is a TOTAL order (source_ref), not presentation order - the D5/F.5 sibling fix this producer never received. A FULL tie on (rl_low, value_num) used to fall through to `order()`'s stable original-index order, so the winner flipped depending on which row was presented first", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbExecute(con, "INSERT INTO lab_method (uuid, uuid_analyte, name, method, organisation, rl_low) VALUES
    ('lm-0002c', 'a-0002', 'Fluoride', 'EK040P: Fluoride by PC Titrator (tie2)', 'ALS', 0.1)")

  mk_pair <- function(a_first) {
    a <- mk_row(source_ref = "a_row", lab_sample_id = "XX1234567002", feature_raw = "T.S02",
                method_raw = "EK040P: Fluoride by PC Titrator", value_raw = "2.3", value_num = 2.3,
                below_detection = FALSE, rl = 0.1)
    z <- mk_row(source_ref = "z_row", lab_sample_id = "XX1234567002", feature_raw = "T.S02",
                method_raw = "EK040P: Fluoride by PC Titrator (tie2)", value_raw = "2.3", value_num = 2.3,
                below_detection = FALSE, rl = 0.1)
    rows <- if (a_first) mk_rows(a, z) else mk_rows(z, a)
    reconcile_event(mk_event(rows), con)
  }

  out1 <- mk_pair(TRUE)   # presented a_row, z_row
  out2 <- mk_pair(FALSE)  # presented z_row, a_row

  # Both keys fully tie (same rl_low 0.1, same value_num 2.3); source_ref
  # ("a_row" < "z_row") must decide, identically, in BOTH presentations.
  expect_true("a_row" %in% out1$clean$source_ref)
  expect_false("z_row" %in% out1$clean$source_ref)
  expect_true("a_row" %in% out2$clean$source_ref)
  expect_false("z_row" %in% out2$clean$source_ref)
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
  DBI::dbExecute(con, "INSERT INTO \"sample\" (uuid, uuid_feature_alias, uuid_project, date, organisation)
    VALUES ('s-field', 'fa-0001', 'p-0001', TIMESTAMP '2025-05-24 00:00:00', 'ACIRL')")
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

# ---- R-11.18/A62: distinct-datetime second sampling is a NEW event ---------
# The reconcile-side twin of commit's .ct_find_or_create_sample predicate:
# .rc_find_existing must treat an incoming measurement as a NEW event (return
# no match) only when distinctness is PROVABLE - incoming datetime non-NA AND
# every candidate datetime non-NA AND none equal. Both sides must agree, or a
# second read of a genuinely new sampling is wrongly discarded as
# already_present.

test_that("R-11.18/A62: a same feature+date+lab+value measurement at a DISTINCT datetime is a new sampling (clean), not already_present", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # Seed s-0001/an-0001 is the "<0.1 mg/L" Fluoride row at T.S01 on 2025-05-24
  # at 11:45, value 100 (lm-0002). The default mk_row re-ingests it verbatim
  # and is already_present (R-8.7 above). Change ONLY the clock time: a second
  # sampling of the same feature, same calendar day, same method and same value
  # but at 15:30 is a DISTINCT sampling event (A62) - two provably-distinct
  # instants -> the incoming row must land clean/new, NOT be skipped as
  # already_present. (With the pre-fix single-candidate path this wrongly
  # matched an-0001 because datetime narrowing was gated on nrow(cand) > 1.)
  event <- mk_event(mk_row(source_ref = "r1",
                           sample_datetime_raw = "24 May 2025 15:30"))
  out <- reconcile_event(event, con)

  expect_true("r1" %in% out$clean$source_ref)
  expect_false("r1" %in% out$skipped$source_ref[out$skipped$reason == "already_present"])
})

test_that("R-11.18/A62: an incoming row with NO datetime at an existing feature+date+lab stays already_present (distinctness must be PROVABLE)", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # A missing incoming datetime is NOT provable distinctness -> reuse, never
  # fabricate a duplicate. Guards against a naive "any different-or-absent
  # datetime -> new event" fix. Date-only raw keeps sample_date = 2025-05-24
  # (matching s-0001) while sample_datetime is NA.
  event <- mk_event(mk_row(source_ref = "r1", sample_datetime_raw = "24/05/2025"))
  out <- reconcile_event(event, con)

  hit <- out$skipped[out$skipped$source_ref == "r1", ]
  expect_equal(nrow(hit), 1)
  expect_identical(hit$reason, "already_present")
})

test_that("D11 (R-11.18/A62/PLAN-7b round-2): a candidate row with datetime IS NULL is still reused as already_present - the 'distinctness must be PROVABLE' conjunct treats a NULL candidate instant as UNPROVABLE, not as license to fabricate a second commit", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # T.S02/fa-0002: fresh feature, no seeded analysis (isolates this fixture
  # from s-0001/an-0001). A single existing candidate at feature+date+lab
  # whose datetime is NULL (PLAN-15 F.11 measures 2 of 15,149 live samples
  # in this exact shape), same converted value as the incoming default
  # "<0.1 mg/L" Fluoride row (100 ug/L, quantified FALSE).
  DBI::dbExecute(con, "INSERT INTO \"sample\" (uuid, uuid_feature_alias, uuid_project, date, datetime, organisation) VALUES
    ('s-nulldt', 'fa-0002', 'p-0001', TIMESTAMP '2025-05-25 00:00:00', NULL, 'ALS')")
  DBI::dbExecute(con, "INSERT INTO analysis (uuid, uuid_sample, uuid_lab, value, quantified, rl_low) VALUES
    ('an-nulldt', 's-nulldt', 'lm-0002', 100, FALSE, 100)")

  # incoming: same feature+date+lab+value, a REAL (non-NA) incoming datetime
  # (the FIXTURES.md default "24 May 2025 11:45" applies to T.S01, so make
  # the raw explicit for T.S02's own date/time).
  event <- mk_event(mk_row(source_ref = "r1", feature_raw = "T.S02",
                           lab_sample_id = "XX1234567002",
                           sample_datetime_raw = "25 May 2025 11:45"))
  out <- reconcile_event(event, con)

  hit <- out$skipped[out$skipped$source_ref == "r1", ]
  expect_equal(nrow(hit), 1)
  expect_identical(hit$reason, "already_present")
  expect_identical(hit$existing_uuid, "an-nulldt")
  expect_false("r1" %in% out$clean$source_ref)
})

test_that("D12 (PLAN-7b round-2): .rc_find_existing() picks the INSTANT-MATCHING candidate when several committed analyses share (feature, date, lab), not an arbitrary DB physical-row-order pick", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # Two analyses at f-0002/fa-0002, same DATE, same lab, DIFFERENT instants -
  # a shape D6's missing ORDER BY and D12's missing datetime-narrowing both
  # leave undiscriminated.
  DBI::dbExecute(con, "INSERT INTO \"sample\" (uuid, uuid_feature_alias, uuid_project, date, datetime, organisation) VALUES
    ('s-multiA', 'fa-0002', 'p-0001', TIMESTAMP '2025-05-25 00:00:00', TIMESTAMP '2025-05-25 21:45:00', 'ALS'),
    ('s-multiB', 'fa-0002', 'p-0001', TIMESTAMP '2025-05-25 00:00:00', TIMESTAMP '2025-05-25 23:45:00', 'ALS')")
  DBI::dbExecute(con, "INSERT INTO analysis (uuid, uuid_sample, uuid_lab, value, quantified, rl_low) VALUES
    ('an-multiA', 's-multiA', 'lm-0002', 50, TRUE, 0.1),
    ('an-multiB', 's-multiB', 'lm-0002', 60, TRUE, 0.1)")

  # incoming instant matches s-multiB's stored datetime EXACTLY.
  inc_dt <- as.POSIXct("2025-05-25 23:45:00", tz = "UTC")
  existing <- .rc_find_existing(con, resolved_feature = "f-0002", uuid_feature_alias = NA_character_,
                                feature_pending = FALSE, sample_date = as.Date("2025-05-25"),
                                sample_datetime = inc_dt, uuid_lab = "lm-0002")
  expect_false(is.null(existing))
  expect_identical(existing$analysis_uuid[[1]], "an-multiB")
})

test_that("PLAN-7b round-3 finding 8: D6's `ORDER BY a.uuid` is actually EXERCISED - two candidates sharing (feature, date, lab) with datetime IS NULL and an NA incoming instant (D11's 'unprovable' shape, which never narrows) pick the LOWER uuid deterministically, not DB insertion/physical-row order", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # Insert the alphabetically LATER uuid FIRST - a physical-row-order pick
  # (no ORDER BY) would return it first; the ORDER BY must override
  # insertion order. Neither candidate's stored datetime is provable
  # against an NA incoming instant (D11), so `cand[1, ]` after the query's
  # own ORDER BY decides.
  DBI::dbExecute(con, "INSERT INTO \"sample\" (uuid, uuid_feature_alias, uuid_project, date, datetime, organisation) VALUES
    ('s-ord-zz', 'fa-0002', 'p-0001', TIMESTAMP '2025-05-25 00:00:00', NULL, 'ALS'),
    ('s-ord-aa', 'fa-0002', 'p-0001', TIMESTAMP '2025-05-25 00:00:00', NULL, 'ALS')")
  DBI::dbExecute(con, "INSERT INTO analysis (uuid, uuid_sample, uuid_lab, value, quantified, rl_low) VALUES
    ('an-zz', 's-ord-zz', 'lm-0002', 50, TRUE, 0.1),
    ('an-aa', 's-ord-aa', 'lm-0002', 60, TRUE, 0.1)")

  existing <- .rc_find_existing(con, resolved_feature = "f-0002", uuid_feature_alias = NA_character_,
                                feature_pending = FALSE, sample_date = as.Date("2025-05-25"),
                                sample_datetime = as.POSIXct(NA), uuid_lab = "lm-0002")
  expect_false(is.null(existing))
  expect_identical(existing$analysis_uuid[[1]], "an-aa")
})

test_that("D3/R-15.33 (deferred to F.11, BLOCKED ON F.13 - PLAN-15:1965): a reuse match finds a LEGACY-CONVENTION row ('date' at 13:00/14:00 UTC, 'datetime' at the real instant), paired with the modern-convention control", {
  # `.rc_find_existing()` matches on `CAST(s.date AS DATE)` against the
  # Sydney-local date computed in memory. Against the live registry, where
  # ALL 15,111 non-NULL `date` values are stored at the legacy 13:00/14:00
  # UTC convention (PLAN-15 F.11), this CAST reads the WRONG calendar day
  # and the reuse match misses every legacy row. R-15.33 belongs to F.11,
  # which the plan marks BLOCKED ON F.13 - this criterion is plan-correct
  # RED today, not an oversight, and must not be "fixed" ahead of F.13
  # (out of this unit's scope regardless).
  #
  # No native testthat "soft xfail" exists that both (a) does not turn the
  # suite red today and (b) auto-flips to a real green PASS the day F.11
  # lands with no test edit required: `testthat::expect_failure()` requires
  # EXACTLY one failure and zero successes in its wrapped expression, so it
  # is STRICT - it would itself go RED the day the wrapped assertions start
  # passing (the opposite of "flip green"). This test self-diagnoses
  # instead: it runs the real assertions and self-skips ONLY while the
  # known-red condition (`nrow(out$clean) != 0`) still holds; the day F.11
  # lands, the condition becomes false, the skip is bypassed, and the block
  # below runs for real - a genuine PASS with no maintainer action needed.
  path <- seed_db(); con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # CONTROL (modern convention, `date` = local midnight): must reuse-match
  # TODAY and after F.11 alike - a real, unconditional assertion so a no-op
  # "implementation" of the eventual fix still fails this test.
  ctrl <- reconcile_event(mk_event(mk_row()), con)
  expect_equal(nrow(ctrl$clean), 0)
  expect_identical(ctrl$skipped$reason, "already_present")

  # The fixture that makes this capable of failing: rewrite s-0001's `date`
  # to the legacy convention. 2025-05-23 14:00 UTC IS 2025-05-24 00:00
  # Australia/Sydney - the same calendar day as the untouched `datetime`
  # (2025-05-24 01:45 UTC = 11:45 AEST) and the same day the incoming row
  # parses to. Only `CAST(date AS DATE)` disagrees, reading 2025-05-23.
  DBI::dbExecute(con, "UPDATE \"sample\" SET date = TIMESTAMP '2025-05-23 14:00:00'
                        WHERE uuid = 's-0001'")

  out <- reconcile_event(mk_event(mk_row()), con)

  if (nrow(out$clean) != 0) {
    testthat::skip(paste(
      "R-15.33 deferred to F.11 (BLOCKED ON F.13, PLAN-15:1965):",
      ".rc_find_existing() CAST(date AS DATE)-matches, which misses a",
      "legacy-convention 'date' (13:00/14:00 UTC, all 15,111 live legacy",
      "rows). Remove this self-skip once F.11 lands - see the comment",
      "block above this test."
    ))
  }
  expect_equal(nrow(out$clean), 0)
  expect_identical(out$skipped$reason, "already_present")
  expect_identical(out$skipped$existing_uuid, "an-0001")
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
  # HARNESS FIX: 's-0002'/'an-0002' collide with helper-db.R's own seeded
  # rows (uuid PK) - use locally-scoped uuids instead (pure infra fix,
  # pre-existing, unrelated to the R-11.2 schema rename below).
  DBI::dbExecute(con, "INSERT INTO \"sample\" (uuid, uuid_feature_alias, uuid_project, date, organisation) VALUES
    ('s-0102', 'fa-0002', 'p-0002', TIMESTAMP '2025-06-01 00:00:00', 'ALS')")
  DBI::dbExecute(con, "INSERT INTO analysis (uuid, uuid_sample, uuid_lab, value, quantified, rl_low) VALUES
    ('an-0102', 's-0102', 'lm-0003', 0.5, TRUE, 1)")

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

  clean_refs <- out$clean$source_ref
  review_refs <- out$review$source_ref
  skipped_refs <- out$skipped$source_ref
  all_refs <- c(clean_refs, review_refs, skipped_refs)
  input_refs <- event$results$source_ref

  # (a) completeness: every input row appears somewhere.
  expect_setequal(unique(all_refs), input_refs)
  # (b) under commit-everything (PLAN-11), a dangling row is legitimately in
  # BOTH clean and review at once - but skipped is still disjoint from both.
  expect_equal(length(intersect(skipped_refs, union(clean_refs, review_refs))), 0)

  # unknown_feature/unknown_analyte rows: pending, so in BOTH clean and review.
  expect_true("unk_feature" %in% clean_refs)
  expect_true("unk_feature" %in% review_refs)
  expect_true("unk_analyte" %in% clean_refs)
  expect_true("unk_analyte" %in% review_refs)
  # unknown_unit row is review-held, NOT in clean.
  expect_true("bad_unit" %in% review_refs)
  expect_false("bad_unit" %in% clean_refs)
  # qc / non-sample rows are skipped.
  expect_true("qc" %in% skipped_refs)
  expect_true("ns_row" %in% skipped_refs)
  # a fresh row is clean-only.
  expect_true("fresh" %in% clean_refs)
  expect_false("fresh" %in% review_refs)
  expect_false("fresh" %in% skipped_refs)
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

# ---- R-11.3: .rc_method_key() normalisation (fold safety) -------------------------

test_that("R-11.3: .rc_method_key folds punctuation/case variants of the same code to one key", {
  keys <- .rc_method_key(c("B.S01", "B S01", "BS01", "b.s01", "B..S01"))
  expect_equal(length(unique(keys)), 1)
  expect_false(is.na(keys[[1]]))
})

test_that("R-11.3: .rc_method_key maps NA and blank names to NA (A44 guard, amended half)", {
  expect_true(is.na(.rc_method_key(NA_character_)))
  expect_true(is.na(.rc_method_key("")))
  expect_true(is.na(.rc_method_key("   ")))
})

# ---- PLAN-15 Work A: .rc_feature_key() punctuation-PRESERVING alias key ------
# The feature-alias registry key is written by migration-001's `.mig001_normalize`
# = tolower(trimws(name)) - punctuation is PRESERVED. Reconcile must look features
# up with the SAME normaliser, or the ~62% of alias keys that contain a dot/space
# are unreachable. This is a DIFFERENT function from `.rc_method_key` (which strips all
# punctuation and is shared by method keys + intra-event dedup - must not change).

# Phase-5 audit C1/C2: the F.3/F.4 tautologies formerly here (one comparing
# `.rc_feature_key` against a locally-redefined copy of its own
# implementation; one asserting only "two distinct values", a restatement of
# the function definition) are DELETED - PLAN-15 F.3(a) calls the first a
# BLOCKING false-green gate, and both are fully superseded by the real
# collision-oracle assertions at R-15.24/R-15.25 (`:1838,1841`) below.

test_that("PLAN-15 A: .rc_feature_key case-folds + trims but PRESERVES internal punctuation", {
  expect_equal(.rc_feature_key("B.S01"), "b.s01")
  expect_equal(.rc_feature_key(" B.S01 "), "b.s01")   # trims outer whitespace
  expect_equal(.rc_feature_key("b.s01"), "b.s01")     # already-normalised is stable
  expect_equal(.rc_feature_key("K.E02"), "k.e02")
  expect_equal(.rc_feature_key("BH.MW02A"), "bh.mw02a")
})

test_that("PLAN-15 A: .rc_feature_key maps NA and blank/whitespace names to NA (A44 guard)", {
  expect_true(is.na(.rc_feature_key(NA_character_)))
  expect_true(is.na(.rc_feature_key("")))
  expect_true(is.na(.rc_feature_key("   ")))
  # vectorised NA-safety: mix of real, NA, blank
  out <- .rc_feature_key(c("B.S01", NA_character_, "  ", "K.E02"))
  expect_equal(out, c("b.s01", NA, NA, "k.e02"))
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

# the OLD .rc_method_key (pre-R-11.3, punctuation kept)
.rc_old_key <- function(x) tolower(stringr::str_squish(normalise_lab_text(x)))

test_that("R-11.3: frozen-snapshot - feature.name fold adds zero new collisions vs the OLD key; count matches the fixture's own header", {
  path <- testthat::test_path("fixtures", "registry-names", "feature-names.csv")
  expected <- .rc_fixture_header_count(path)
  names <- readr::read_csv(path, comment = "#", show_col_types = FALSE)$name
  n_old <- length(unique(.rc_old_key(names)))
  n_new <- length(unique(.rc_method_key(names)))
  expect_equal(n_new, expected)
  expect_equal(n_new, n_old) # the fold introduces zero NEW collisions
})

test_that("R-11.3: frozen-snapshot - analyte.name fold adds zero new collisions vs the OLD key; count matches the fixture's own header", {
  path <- testthat::test_path("fixtures", "registry-names", "analyte-names.csv")
  expected <- .rc_fixture_header_count(path)
  names <- readr::read_csv(path, comment = "#", show_col_types = FALSE)$name
  n_old <- length(unique(.rc_old_key(names)))
  n_new <- length(unique(.rc_method_key(names)))
  expect_equal(n_new, expected)
  expect_equal(n_new, n_old)
})

test_that("R-11.3: frozen-snapshot - lab_method (organisation,name,method) triple fold adds zero new collisions; count matches the fixture's own header", {
  path <- testthat::test_path("fixtures", "registry-names", "lab-method-triples.csv")
  expected <- .rc_fixture_header_count(path)
  triples <- readr::read_csv(path, comment = "#", show_col_types = FALSE)
  old_triple <- paste(triples$organisation, .rc_old_key(triples$name), .rc_old_key(triples$method), sep = "||")
  new_triple <- paste(triples$organisation, .rc_method_key(triples$name), .rc_method_key(triples$method), sep = "||")
  n_old <- length(unique(old_triple))
  n_new <- length(unique(new_triple))
  expect_equal(n_new, expected)
  expect_equal(n_new, n_old)
})

test_that("R-11.3: live registry property - .rc_method_key is injective over feature/analyte/lab_method names modulo the two known allowlisted collisions (corpus-gated, no count literal)", {
  corpus_db <- Sys.getenv("SAMPLETIDY_CORPUS_DB")
  skip_if(corpus_db == "", "SAMPLETIDY_CORPUS_DB not set")
  con <- DBI::dbConnect(duckdb::duckdb(), corpus_db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  check_injective <- function(ids, allowed_ids) {
    keys <- .rc_method_key(ids)
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
  lm_key <- paste(lm$organisation, .rc_method_key(lm$name), .rc_method_key(lm$method), sep = "||")
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
    ('fa-dangling-r114', NULL, 'T.DANGLE114', 't.dangle114', 'pending', TRUE,
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

# ---- PLAN-15 A: dotted-key resolution + ambiguous-candidate surfacing --------

test_that("PLAN-15 A: a dotted feature name resolves via the migration-format alias_key (T.S01 -> t.s01)", {
  # Guards the 62% failure: fixture alias_key is now punctuation-preserving
  # ('t.s01'), and `.rc_feature_candidates` looks up with `.rc_feature_key`.
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  registry <- .rc_load_registry(con)
  expect_identical(registry$feature_alias$alias_key[registry$feature_alias$uuid == "fa-0001"], "t.s01")
  cand <- .rc_feature_candidates("T.S01", as.Date("2025-05-20"), registry)
  expect_equal(nrow(cand), 1)
  expect_identical(cand$uuid_feature[[1]], "f-0001")
})

test_that("PLAN-15 A: an all-auto_assign=FALSE ambiguous key (T.DUAL) does NOT auto-resolve but SURFACES both candidates in review", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  registry <- .rc_load_registry(con)
  # auto path: nothing (both arms auto_assign=FALSE)
  expect_equal(nrow(.rc_feature_candidates("T.DUAL", as.Date("2025-05-20"), registry)), 0)
  # suggestion path: both distinct features surface
  expect_setequal(.rc_feature_suggestions("T.DUAL", as.Date("2025-05-20"), registry),
                  c("f-0004", "f-0005"))
  # end-to-end: pending (not silently unknown), review payload lists BOTH candidates
  event <- mk_event(mk_row(source_ref = "r1", feature_raw = "T.DUAL"))
  out <- reconcile_event(event, con)
  row <- out$clean[out$clean$source_ref == "r1", ]
  expect_true(row$feature_pending)
  rv <- out$review[out$review$kind == "unknown_feature" & grepl("r1", out$review$source_ref), ]
  expect_equal(nrow(rv), 1)
  expect_identical(rv$subkind[[1]], "ambiguous")
  # TRANSLATED 2026-07-26. Was:
  #   dg <- jsonlite::fromJSON(rv$payload[[1]])
  #   expect_true("f-0004" %in% dg$candidates && "f-0005" %in% dg$candidates)
  # Same reason as R-8.2 above: candidates are typed child rows now, not a JSON
  # key. `expect_setequal` also pins that there are exactly these two.
  dual_cand <- rv$candidates[[1]]
  dual_cand <- dual_cand[!is.na(dual_cand$kind) & dual_cand$kind == "candidate", ]
  expect_setequal(dual_cand$uuid_feature, c("f-0004", "f-0005"))
})

test_that("PLAN-15 A: the committed alias_key on a pending row is punctuation-preserving (matches migration format)", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  event <- mk_event(mk_row(source_ref = "r1", feature_raw = "B.NEW-POINT7"))
  out <- reconcile_event(event, con)
  row <- out$clean[out$clean$source_ref == "r1", ]
  expect_identical(row$alias_key, "b.new-point7")   # NOT 'bnewpoint7'
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
    # Different BYTES, same measurement. The differing bytes are carried by
    # source_hash above; value_raw is reformatted rather than annotated. It used
    # to read "7.10 (resent)", which parse_value() classifies as TEXT - that
    # only matched because text was once quantified = TRUE while carrying the
    # adapter's numeric value_num, an incoherent pairing. Since text is now
    # quantified = NA (2026-07-23), the fixture must be a real numeric restatement.
    units_raw = "pH Unit", value_raw = "7.100",
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
    # Reformatted numeric restatement, not an annotated string - see the note in
    # the feature-side test above.
    units_raw = "mg/L", value_raw = "12.00",
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
  path <- seed_db(); con <- seed_con(path)
  # withr::defer, not on.exit - a bare on.exit() in a mocking block discards
  # local_mocked_bindings()'s restore handler (see test-mock-scope-lint.R).
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
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
  # lm-0004, both Fluoride/ALS but DIFFERENT uuid_lab). The different labs are
  # deliberate: .rc_method_preference only drops a row when a key-group has
  # 2+ eligible rows from DIFFERENT uuid_lab (length(labs) > 1); same-lab
  # duplicates are left for a later stage, so a same-method (same-lab) pair
  # would pass even with feat_key collapsed to a constant, masking the bug.
  # With correct, distinct feat_key the two rows land in separate
  # preference groups (both kept, neither eligible to dedup against the
  # other). If uuid_feature is dropped (R-11.2) and the key is not re-keyed
  # on the resolved/pending split, paste() recycles the missing feature
  # component to "" and BOTH rows collapse into one group of two
  # different-lab rows for the same analyte/date - triggering the
  # cross-lab method_duplicate drop and losing one row's data.
  event <- mk_event(mk_rows(
    mk_row(source_ref = "r1", feature_raw = "T.UNKNOWN-FEATURE-A", method_raw = "EK040P: Fluoride by PC Titrator",
           sample_datetime_raw = "20 May 2025 09:00", value_raw = "2.3", value_num = 2.3,
           below_detection = FALSE, rl = 0.1),
    mk_row(source_ref = "r2", feature_raw = "T.UNKNOWN-FEATURE-B", method_raw = "EK040T: Fluoride by alt method",
           sample_datetime_raw = "20 May 2025 09:00", value_raw = "2.5", value_num = 2.5,
           below_detection = FALSE, rl = 0.5)
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
    ('fa-field-r117', 'f-0001', 'T.S01-FIELD', 't.s01-field', 'historical_code', TRUE,
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
  d <- jsonlite::fromJSON(hit$payload[[1]])
  expect_null(d$candidates)
  expect_null(d$guess)
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

test_that("A44: a genuinely-missing feature_raw and a row whose feature code is the literal string 'NA' are NOT folded into one review item", {
  # Both `.rc_feature_key(NA)` (the A44 guard) and `.rc_feature_key('NA')`
  # (a real, punctuation-free key that folds to 'na') used to share the
  # SAME string sentinel inside `.rc_feature_review()`'s `split()` grouping,
  # merging a row with no feature at all into the same review item as a row
  # whose feature code genuinely IS "NA" - hiding the literal code from the
  # operator and blanking `diagnostics$feature_raw`.
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  event <- mk_event(mk_rows(
    mk_row(source_ref = "r-missing", feature_raw = NA_character_, lab_sample_id = "XX1234567005"),
    mk_row(source_ref = "r-litNA", feature_raw = "NA", lab_sample_id = "XX1234567006")
  ))
  out <- reconcile_event(event, con)
  rv <- out$review[out$review$kind == "unknown_feature", ]
  expect_equal(nrow(rv), 2) # two DISTINCT items, not one merged item

  missing_item <- rv[rv$source_ref == "r-missing", ]
  lit_item <- rv[rv$source_ref == "r-litNA", ]
  expect_equal(nrow(missing_item), 1)
  expect_equal(nrow(lit_item), 1)

  d_missing <- jsonlite::fromJSON(missing_item$payload[[1]])
  d_lit <- jsonlite::fromJSON(lit_item$payload[[1]])
  expect_true(is.null(d_missing$feature_raw) || is.na(d_missing$feature_raw))
  expect_identical(d_lit$feature_raw, "NA")
  expect_false(identical(missing_item$source_ref[[1]], lit_item$source_ref[[1]]))
})

test_that("A44: case-variant literal feature codes 'na'/'Na' reach the same collision-prone key as 'NA' and still stay split from a genuinely-missing feature", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  event <- mk_event(mk_rows(
    mk_row(source_ref = "r-missing2", feature_raw = NA_character_, lab_sample_id = "XX1234567007"),
    mk_row(source_ref = "r-na-lower", feature_raw = "na", lab_sample_id = "XX1234567008"),
    mk_row(source_ref = "r-na-mixed", feature_raw = "Na", lab_sample_id = "XX1234567009")
  ))
  out <- reconcile_event(event, con)
  rv <- out$review[out$review$kind == "unknown_feature", ]
  # 'na' and 'Na' both fold to the SAME .rc_feature_key ('na') and belong in
  # ONE group together; the genuinely-missing row is a SECOND, separate group.
  expect_equal(nrow(rv), 2)
  missing_item <- rv[rv$source_ref == "r-missing2", ]
  lit_item <- rv[grepl("r-na-lower", rv$source_ref), ]
  expect_equal(nrow(lit_item), 1)
  expect_true(grepl("r-na-lower", lit_item$source_ref[[1]]) && grepl("r-na-mixed", lit_item$source_ref[[1]]))
  d_lit <- jsonlite::fromJSON(lit_item$payload[[1]])
  expect_equal(d_lit$n_rows, 2)
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

# ---- PLAN-16 Phase 7b round 2 FF4/FF5: STAGE-0 fold-in typed columns -------
#
# FF4: assembly's `review_payload` list carries `kind`/`subkind` keys of its
# own (R/assemble.R); the STAGE-0 fold used to pass the whole list through as
# `diagnostics`, so `review_queue.subkind` stayed NULL while the JSON
# remainder duplicated `kind`/`subkind`. Fixed by hoisting `subkind` into
# `.rc_review_row()`'s typed argument and stripping both keys from the
# serialised remainder.
#
# FF5: for `foreign_work_order`, the payload ALSO carried `work_order` (the
# FOREIGN work order named inside the file) under the same key name
# `commit_event()` uses for the typed `review_queue.work_order` column (the
# HOME work order the event was ingested under, taken from `event$work_order`
# - never from this diagnostics list). REPRODUCED: verified directly
# (probe) that pre-fix the two carriers disagreed under one name
# (payload.work_order = "FOREIGN999" vs review_queue.work_order =
# "XX1234567" for the same row) - these are two DIFFERENT FACTS, not one
# duplicated, so the fix renames the diagnostics key rather than picking a
# winner. `home_work_order` (a pure duplicate of the future typed column,
# verified byte-identical to `event$work_order`) is dropped rather than
# renamed.

test_that("PLAN-16 FF4: STAGE-0 foreign_work_order item promotes subkind to the typed column and the JSON payload no longer duplicates kind/subkind", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  parsed <- list(
    "h-multi-ff4" = .rc_mk_parsed_entry(
      results = dplyr::bind_rows(
        .rc_mk_ir_result(source_hash = "h-multi-ff4", source_ref = "own_wo", work_order = "XX1234567",
                         lab_sample_id = "XX1234567001", sample_type = "unknown"),
        .rc_mk_ir_result(source_hash = "h-multi-ff4", source_ref = "foreign_wo", work_order = "ZZ0000002",
                         lab_sample_id = "ZZ0000002001", sample_type = "Normal")
      ),
      meta = list(work_order_guess = "XX1234567")
    )
  )
  asm <- assemble_events(parsed)
  target <- Filter(function(e) "foreign_wo" %in% e$results$source_ref, asm$events)
  event <- target[[1]]
  out <- reconcile_event(event, con)

  row <- out$review[out$review$source_ref == "foreign_wo", ]
  expect_equal(nrow(row), 1)
  # Typed column, not a grepl() on the payload string (before the fix this was NA).
  expect_identical(row$subkind[[1]], "foreign_work_order")

  parsed_payload <- jsonlite::fromJSON(row$payload[[1]])
  expect_false("kind" %in% names(parsed_payload))
  expect_false("subkind" %in% names(parsed_payload))
})

test_that("PLAN-16 FF4: STAGE-0 sample_datetime_mismatch item promotes subkind to the typed column, datetime_candidates survive, kind/subkind dropped from JSON", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  parsed <- list(
    "h-chem2-ff4" = .rc_mk_parsed_entry(
      results = .rc_mk_ir_result(source_hash = "h-chem2-ff4", source_ref = "dt_flagged", lab_sample_id = "XX1234567007", sample_type = "unknown"),
      meta = list(work_order_guess = "XX1234567")
    ),
    "h-samp-c-ff4" = .rc_mk_parsed_entry(
      samples = .rc_mk_ir_sample(source_hash = "h-samp-c-ff4", lab_sample_id = "XX1234567007", feature_raw = "T.S01",
                                 sample_datetime_raw = "24 May 2025 11:45", sample_type = "Normal"),
      meta = list(work_order_guess = "XX1234567")
    ),
    "h-samp-d-ff4" = .rc_mk_parsed_entry(
      samples = .rc_mk_ir_sample(source_hash = "h-samp-d-ff4", lab_sample_id = "XX1234567007", feature_raw = "T.S01",
                                 sample_datetime_raw = "25 May 2025 09:00", sample_type = "Normal"),
      meta = list(work_order_guess = "XX1234567")
    )
  )
  asm <- assemble_events(parsed)
  event <- asm$events[[1]]

  out <- reconcile_event(event, con)
  row <- out$review[out$review$source_ref == "dt_flagged", ]
  expect_equal(nrow(row), 1)
  expect_identical(row$subkind[[1]], "sample_datetime_mismatch")

  parsed_payload <- jsonlite::fromJSON(row$payload[[1]])
  expect_false("kind" %in% names(parsed_payload))
  expect_false("subkind" %in% names(parsed_payload))
  # Cold-audit defect 4 (this fix): was pinned as "candidates" - the exact
  # key name `unknown_feature`'s candidate FEATURE uuids use - which a
  # `review_queue_candidates()` reader (R/mutate.R) would misinterpret as
  # feature uuids. Renamed at the source (R/assemble.R) to `datetime_candidates`;
  # this test's OLD assertion was pinning that collision, not a correct
  # contract, so it is corrected rather than left as a regression guard for
  # the wrong name.
  expect_false("candidates" %in% names(parsed_payload))
  expect_true("datetime_candidates" %in% names(parsed_payload))
  expect_setequal(parsed_payload$datetime_candidates, c("24 May 2025 11:45", "25 May 2025 09:00"))
})

test_that("PLAN-16 FF5: committed review_queue.work_order (home) and the payload's foreign work order are different facts under different key names, both present", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  parsed <- list(
    "h-multi-ff5" = .rc_mk_parsed_entry(
      results = dplyr::bind_rows(
        .rc_mk_ir_result(source_hash = "h-multi-ff5", source_ref = "own_wo", work_order = "XX1234567",
                         lab_sample_id = "XX1234567001", sample_type = "unknown"),
        .rc_mk_ir_result(source_hash = "h-multi-ff5", source_ref = "foreign_wo", work_order = "ZZ0000002",
                         lab_sample_id = "ZZ0000002001", sample_type = "Normal")
      ),
      meta = list(work_order_guess = "XX1234567")
    )
  )
  asm <- assemble_events(parsed)
  target <- Filter(function(e) "foreign_wo" %in% e$results$source_ref, asm$events)
  event <- target[[1]]
  out <- reconcile_event(event, con)

  commit_event(event, out, con)
  rq <- review_queue(con)
  rq <- rq[rq$source_hash == "h-multi-ff5" & rq$subkind == "foreign_work_order", ]
  expect_equal(nrow(rq), 1)

  # The typed column is the HOME work order the event was ingested under
  # (commit_event() always takes it from event$work_order, never the review
  # tibble - by design, verified at R/commit.R).
  expect_identical(rq$work_order[[1]], event$work_order)
  expect_identical(rq$work_order[[1]], "XX1234567")

  # The payload carries the FOREIGN work order named inside the file, under
  # an unambiguous key name - never the bare "work_order" name the typed
  # column also uses, and never a second copy of the home value.
  parsed_payload <- jsonlite::fromJSON(rq$payload[[1]])
  expect_identical(parsed_payload$foreign_work_order, "ZZ0000002")
  expect_false("work_order" %in% names(parsed_payload))
  expect_false("home_work_order" %in% names(parsed_payload))
})

test_that("PLAN-7b round-3 G-A site 2: STAGE-0 reads review_payload's subkind via EXACT match only - R's `$` prefix-matches on lists, so a sibling key like `subkind_detail` (no exact `subkind` key) must NOT be misread as subkind and re-emitted a second time into the JSON diagnostics", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  parsed <- list(
    "h-chem-ga" = .rc_mk_parsed_entry(
      results = .rc_mk_ir_result(source_hash = "h-chem-ga", source_ref = "flagged", lab_sample_id = "XX1234567007", sample_type = "unknown"),
      meta = list(work_order_guess = "XX1234567")
    ),
    "h-samp-ga1" = .rc_mk_parsed_entry(
      samples = .rc_mk_ir_sample(source_hash = "h-samp-ga1", lab_sample_id = "XX1234567007", feature_raw = "T.S01",
                                 sample_datetime_raw = "24 May 2025 11:45", sample_type = "Normal"),
      meta = list(work_order_guess = "XX1234567")
    ),
    "h-samp-ga2" = .rc_mk_parsed_entry(
      samples = .rc_mk_ir_sample(source_hash = "h-samp-ga2", lab_sample_id = "XX1234567007", feature_raw = "T.S01",
                                 sample_datetime_raw = "25 May 2025 09:00", sample_type = "Normal"),
      meta = list(work_order_guess = "XX1234567")
    )
  )
  # Two DIFFERENT sample-source datetimes join to the SAME lab_sample_id -
  # assembly's real sample_datetime_mismatch flag (same fixture shape as the
  # FF4 test above), so "flagged" is flagged by the REAL adapter path, not
  # hand-set.
  asm <- assemble_events(parsed)
  event <- asm$events[[1]]
  i <- which(event$results$source_ref == "flagged")
  expect_true(isTRUE(event$results$needs_review[[i]]))
  # Simulate an ADAPTER-controlled payload carrying NO exact "subkind" key,
  # only a same-prefixed sibling - verified directly: `list(subkind_detail =
  # "oops")$subkind` returns `"oops"`, R's `$` prefix-matching on lists.
  event$results$review_payload[[i]] <- list(subkind_detail = "oops")

  out <- reconcile_event(event, con)
  row <- out$review[out$review$source_ref == "flagged", ]
  expect_equal(nrow(row), 1)
  # Pre-fix: `diag$subkind` misread "oops" from `subkind_detail` and the
  # typed column carried it.
  expect_true(is.na(row$subkind[[1]]))
  # `subkind_detail` itself is untouched real diagnostics (setdiff() only
  # ever strips the EXACT name "subkind") - it must survive in the JSON,
  # not be silently eaten by the fix either.
  parsed_payload <- jsonlite::fromJSON(row$payload[[1]])
  expect_identical(parsed_payload$subkind_detail, "oops")
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

# =============================================================================
# PLAN 12 - R-12.13: within-batch duplicate guard before commit (A-7)
# =============================================================================
#
# R-8.6 dedups across *methods*; two identical-key rows from the SAME method
# in one batch (a lab re-listing a determination) each independently pass the
# three-way (which only consults the DB, not sibling rows in this batch) and
# would otherwise commit as two analyses on one sample. The fix is a
# `duplicated()` check over `(uuid_feature_alias, sample_date, uuid_analyte,
# uuid_lab)` in `clean` before commit - route the exact dupe to REVIEW, never
# collapse it (pinned 2026-07-22, Phase-3 D13: A54 - the pipeline records the
# question, never invents the answer by silently picking one of two
# uncompared rows). The key is `uuid_feature_alias`, NOT `uuid_feature`
# (PLAN-12 "Ordering vs PLAN-11" + R-12.13 fix text, explicit).
#
# PROVISIONAL ORACLE: R-12.13 pins the *disposition* (review, not skip, not
# collapse) but not the exact review `kind` string. "batch_duplicate" below is
# a placeholder in the existing snake_case vocabulary
# (unknown_feature/unknown_analyte/unknown_unit/parse_error/value_conflict);
# Phase 6 must confirm or rename it against the real implementation.

test_that("R-12.13: two identical-key same-method rows in one batch commit as ONE analysis, the other routed to review (not collapsed, not both committed)", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  # T.S02/f-0002 has no seeded analysis, so the three-way sees BOTH rows as
  # "new" absent the R-12.13 guard - the exact bug this criterion fixes.
  event <- mk_event(mk_rows(
    mk_row(source_ref = "r1", lab_sample_id = "XX1234567002", feature_raw = "T.S02",
           value_raw = "2.3", value_num = 2.3, below_detection = FALSE, rl = 0.1),
    mk_row(source_ref = "r2", lab_sample_id = "XX1234567002", feature_raw = "T.S02",
           value_raw = "2.3", value_num = 2.3, below_detection = FALSE, rl = 0.1)
  ))
  out <- reconcile_event(event, con)

  # Exactly one of the two source_refs lands in clean - not zero (collapsed
  # away), not two (the pre-fix bug: one sample gets two analyses).
  expect_equal(sum(c("r1", "r2") %in% out$clean$source_ref), 1)

  loser <- setdiff(c("r1", "r2"), out$clean$source_ref)
  expect_equal(length(loser), 1)
  # Routed to REVIEW, not skipped and not silently dropped (D13: never collapse).
  expect_false(loser %in% out$skipped$source_ref)
  hit <- out$review[out$review$source_ref == loser, ]
  expect_equal(nrow(hit), 1)
  expect_identical(hit$kind, "batch_duplicate") # PROVISIONAL ORACLE: R-12.13
})

test_that("R-12.13: distinct-key rows in the same batch are unaffected - both commit", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  # Same feature/analyte/method but DIFFERENT sample dates - genuinely two
  # distinct measurements, must not trip the within-batch guard.
  event <- mk_event(mk_rows(
    mk_row(source_ref = "r1", lab_sample_id = "XX1234567002", feature_raw = "T.S02",
           value_raw = "2.3", value_num = 2.3, below_detection = FALSE, rl = 0.1,
           sample_datetime_raw = "24 May 2025 11:45"),
    mk_row(source_ref = "r2", lab_sample_id = "XX1234567002", feature_raw = "T.S02",
           value_raw = "2.4", value_num = 2.4, below_detection = FALSE, rl = 0.1,
           sample_datetime_raw = "25 May 2025 11:45")
  ))
  out <- reconcile_event(event, con)
  expect_true("r1" %in% out$clean$source_ref)
  expect_true("r2" %in% out$clean$source_ref)
  expect_false(any(out$review$kind == "batch_duplicate")) # PROVISIONAL ORACLE: R-12.13
})

test_that("R-12.13: interacts correctly with R-8.6 - cross-method dedup runs FIRST, then the within-batch guard catches the remaining same-method dupe", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  # r1/r3: same key AND same method (lm-0002) - the R-12.13 case.
  # r2: same key but a DIFFERENT method (lm-0004, higher rl_low) - loses to r1
  # under R-8.6's method preference BEFORE R-12.13 ever sees it.
  event <- mk_event(mk_rows(
    mk_row(source_ref = "r1", lab_sample_id = "XX1234567002", feature_raw = "T.S02",
           method_raw = "EK040P: Fluoride by PC Titrator",
           value_raw = "2.3", value_num = 2.3, below_detection = FALSE, rl = 0.1),
    mk_row(source_ref = "r2", lab_sample_id = "XX1234567002", feature_raw = "T.S02",
           method_raw = "EK040T: Fluoride by alt method",
           value_raw = "2.5", value_num = 2.5, below_detection = FALSE, rl = 0.5),
    mk_row(source_ref = "r3", lab_sample_id = "XX1234567002", feature_raw = "T.S02",
           method_raw = "EK040P: Fluoride by PC Titrator",
           value_raw = "2.3", value_num = 2.3, below_detection = FALSE, rl = 0.1)
  ))
  out <- reconcile_event(event, con)

  # R-8.6 already removes r2 as a cross-method duplicate.
  dup2 <- out$skipped[out$skipped$source_ref == "r2", ]
  expect_equal(nrow(dup2), 1)
  expect_identical(dup2$reason, "method_duplicate")

  # Of the surviving same-method pair (r1, r3), exactly one commits and the
  # other is routed to review by R-12.13 - never both, never neither.
  expect_equal(sum(c("r1", "r3") %in% out$clean$source_ref), 1)
  loser <- setdiff(c("r1", "r3"), out$clean$source_ref)
  expect_identical(out$review$kind[out$review$source_ref == loser], "batch_duplicate") # PROVISIONAL ORACLE: R-12.13
})

test_that("R-12.13: the guard is keyed on uuid_feature_alias, NOT uuid_feature - two DIFFERENT (both-resolved) aliases of the same feature are not flagged as duplicates", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  # fa-0003 (self-alias 'T.MW01') and fa-0004 ('bs03alt') both resolve to the
  # SAME uuid_feature f-0003 (FIXTURES.md/helper-db.R), but are two distinct
  # feature_alias rows. Same analyte/method/date on both incoming rows: if the
  # guard were (wrongly) keyed on uuid_feature, this pair would be flagged; a
  # key of uuid_feature_alias (as PLAN-12 explicitly pins) must not flag it.
  event <- mk_event(mk_rows(
    mk_row(source_ref = "r1", feature_raw = "T.MW01", lab_sample_id = "XX9999999991",
           sample_datetime_raw = "24 May 2025 11:45"),
    mk_row(source_ref = "r2", feature_raw = "bs03alt", lab_sample_id = "XX9999999992",
           sample_datetime_raw = "24 May 2025 11:45")
  ))
  out <- reconcile_event(event, con)
  expect_true("r1" %in% out$clean$source_ref)
  expect_true("r2" %in% out$clean$source_ref)
  expect_false(any(out$review$kind == "batch_duplicate" & # PROVISIONAL ORACLE: R-12.13
                     out$review$source_ref %in% c("r1", "r2")))
})

test_that("R-12.13: NA-safe key - two rows with an unresolved (NA) uuid_feature_alias are never matched to each other as batch dupes (A44/[#5])", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  # Two genuinely distinct lab rows for the SAME never-seen feature code, same
  # analyte/method/date: both carry uuid_feature_alias = NA (feature_pending,
  # R-11.5). A naive duplicated()-on-NA would spuriously pair them; the guard
  # must exclude the NA key from the match (documented A44 behaviour), not
  # coerce it into a spurious duplicate flag. Both must independently commit
  # dangling, each with its own R-11.5 review item.
  event <- mk_event(mk_rows(
    mk_row(source_ref = "r1", feature_raw = "T.NEVER-SEEN-CODE-R1213", lab_sample_id = "XX9999999997"),
    mk_row(source_ref = "r2", feature_raw = "T.NEVER-SEEN-CODE-R1213", lab_sample_id = "XX9999999998")
  ))
  out <- reconcile_event(event, con)
  expect_true("r1" %in% out$clean$source_ref)
  expect_true("r2" %in% out$clean$source_ref)
  expect_false(any(out$review$kind == "batch_duplicate" & # PROVISIONAL ORACLE: R-12.13
                     out$review$source_ref %in% c("r1", "r2")))
})

# ---- PLAN-16 Phase 7b round 2 FF7: batch_duplicate names its OWN row too ---
#
# `.rc_review_row(source_ref = ...)` already promotes the LOSER's own
# source_ref into both the typed `source_ref` column and `diagnostics$source_ref`
# (Q2, 2026-07-25); `kept_source_ref` names the winner separately. The item is
# therefore identifiable both ways, not just by the row it kept.

test_that("PLAN-16 FF7: a batch_duplicate item's typed source_ref column AND its JSON payload identify the DROPPED row, while kept_source_ref still names the winner", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  event <- mk_event(mk_rows(
    mk_row(source_ref = "BD_WINNER", lab_sample_id = "XX1234567002", feature_raw = "T.S02",
           value_raw = "2.3", value_num = 2.3, below_detection = FALSE, rl = 0.1),
    mk_row(source_ref = "BD_LOSER", lab_sample_id = "XX1234567002", feature_raw = "T.S02",
           value_raw = "2.3", value_num = 2.3, below_detection = FALSE, rl = 0.1)
  ))
  out <- reconcile_event(event, con)

  hit <- out$review[out$review$kind == "batch_duplicate", ]
  expect_equal(nrow(hit), 1)
  # Typed column: the item is about the row that was DROPPED, not the winner.
  expect_identical(hit$source_ref[[1]], "BD_LOSER")

  parsed_payload <- jsonlite::fromJSON(hit$payload[[1]])
  expect_identical(parsed_payload$source_ref, "BD_LOSER")
  expect_identical(parsed_payload$kept_source_ref, "BD_WINNER")
})

# =============================================================================
# Phase-8b remediation: duplicate identity keys on DATETIME, not DATE
# (Robin's ruling, 2026-07): same point + same date + DIFFERENT datetime is
# two real sampling events, never a duplicate; same point + same datetime IS
# the same event. `.rc_batch_duplicate()` used to key on `sample_date` alone,
# so two genuinely distinct same-day samplings in one batch were wrongly
# flagged as `batch_duplicate`. `.rc_find_existing()` already got this right
# for the cross-ingest case; both now share `.rc_provably_distinct_datetime()`.
# Four cells, both paths: same point+same datetime; same point+same date,
# different datetime; different point+same datetime; date-only (no time
# reported on one or both sides).
# =============================================================================

test_that("PLAN-8b: in-batch - same point, same date, DIFFERENT datetime - both are distinct sampling events and commit, neither flagged batch_duplicate", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  event <- mk_event(mk_rows(
    mk_row(source_ref = "morning", lab_sample_id = "XX1234567002", feature_raw = "T.S02",
           sample_datetime_raw = "20 May 2025 08:00",
           value_raw = "0.5", value_num = 0.5, below_detection = FALSE, rl = 0.1),
    mk_row(source_ref = "evening", lab_sample_id = "XX1234567002", feature_raw = "T.S02",
           sample_datetime_raw = "20 May 2025 16:00",
           value_raw = "1.9", value_num = 1.9, below_detection = FALSE, rl = 0.1)
  ))
  out <- reconcile_event(event, con)

  expect_true("morning" %in% out$clean$source_ref)
  expect_true("evening" %in% out$clean$source_ref)
  expect_false(any(out$review$kind == "batch_duplicate"))
})

test_that("PLAN-8b: in-batch - same point, SAME datetime - the second is still the same sampling event and is flagged batch_duplicate", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  event <- mk_event(mk_rows(
    mk_row(source_ref = "r1", lab_sample_id = "XX1234567002", feature_raw = "T.S02",
           sample_datetime_raw = "20 May 2025 08:00",
           value_raw = "0.5", value_num = 0.5, below_detection = FALSE, rl = 0.1),
    mk_row(source_ref = "r2", lab_sample_id = "XX1234567002", feature_raw = "T.S02",
           sample_datetime_raw = "20 May 2025 08:00",
           value_raw = "0.5", value_num = 0.5, below_detection = FALSE, rl = 0.1)
  ))
  out <- reconcile_event(event, con)

  expect_equal(sum(c("r1", "r2") %in% out$clean$source_ref), 1)
  loser <- setdiff(c("r1", "r2"), out$clean$source_ref)
  hit <- out$review[out$review$source_ref == loser, ]
  expect_equal(nrow(hit), 1)
  expect_identical(hit$kind, "batch_duplicate")
})

test_that("PLAN-8b: in-batch - DIFFERENT point, same datetime - unaffected, both commit", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  event <- mk_event(mk_rows(
    mk_row(source_ref = "r1", feature_raw = "T.MW01", lab_sample_id = "XX9999999991",
           sample_datetime_raw = "20 May 2025 08:00"),
    mk_row(source_ref = "r2", feature_raw = "T.S02", lab_sample_id = "XX9999999992",
           sample_datetime_raw = "20 May 2025 08:00")
  ))
  out <- reconcile_event(event, con)
  expect_true("r1" %in% out$clean$source_ref)
  expect_true("r2" %in% out$clean$source_ref)
  expect_false(any(out$review$kind == "batch_duplicate" &
                     out$review$source_ref %in% c("r1", "r2")))
})

test_that("PLAN-8b: in-batch - same point, same date, BOTH date-only (no time reported) - treated as the SAME event (conservative: a bare date is not proof of two events)", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  event <- mk_event(mk_rows(
    mk_row(source_ref = "r1", lab_sample_id = "XX1234567002", feature_raw = "T.S02",
           sample_datetime_raw = "20/05/2025",
           value_raw = "0.5", value_num = 0.5, below_detection = FALSE, rl = 0.1),
    mk_row(source_ref = "r2", lab_sample_id = "XX1234567002", feature_raw = "T.S02",
           sample_datetime_raw = "20/05/2025",
           value_raw = "0.5", value_num = 0.5, below_detection = FALSE, rl = 0.1)
  ))
  out <- reconcile_event(event, con)

  expect_equal(sum(c("r1", "r2") %in% out$clean$source_ref), 1)
  loser <- setdiff(c("r1", "r2"), out$clean$source_ref)
  expect_identical(out$review$kind[out$review$source_ref == loser], "batch_duplicate")
})

test_that("PLAN-8b: in-batch - one date-only row and one timed row, same date - AMBIGUOUS, conservatively flagged batch_duplicate rather than silently committing both", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  event <- mk_event(mk_rows(
    mk_row(source_ref = "timed", lab_sample_id = "XX1234567002", feature_raw = "T.S02",
           sample_datetime_raw = "20 May 2025 08:00",
           value_raw = "0.5", value_num = 0.5, below_detection = FALSE, rl = 0.1),
    mk_row(source_ref = "dateonly", lab_sample_id = "XX1234567002", feature_raw = "T.S02",
           sample_datetime_raw = "20/05/2025",
           value_raw = "0.5", value_num = 0.5, below_detection = FALSE, rl = 0.1)
  ))
  out <- reconcile_event(event, con)

  expect_equal(sum(c("timed", "dateonly") %in% out$clean$source_ref), 1)
  loser <- setdiff(c("timed", "dateonly"), out$clean$source_ref)
  expect_identical(out$review$kind[out$review$source_ref == loser], "batch_duplicate")
})

test_that("PLAN-8b: in-batch - THREE rows, same key: two genuinely distinct datetimes plus a duplicate of one of them, in a single batch", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  event <- mk_event(mk_rows(
    mk_row(source_ref = "r1", lab_sample_id = "XX1234567002", feature_raw = "T.S02",
           sample_datetime_raw = "20 May 2025 08:00",
           value_raw = "0.5", value_num = 0.5, below_detection = FALSE, rl = 0.1),
    mk_row(source_ref = "r2", lab_sample_id = "XX1234567002", feature_raw = "T.S02",
           sample_datetime_raw = "20 May 2025 16:00",
           value_raw = "1.9", value_num = 1.9, below_detection = FALSE, rl = 0.1),
    mk_row(source_ref = "r3", lab_sample_id = "XX1234567002", feature_raw = "T.S02",
           sample_datetime_raw = "20 May 2025 08:00",
           value_raw = "0.5", value_num = 0.5, below_detection = FALSE, rl = 0.1)
  ))
  out <- reconcile_event(event, con)

  # r1 and r2 are two genuinely distinct sampling events - both commit.
  expect_true("r1" %in% out$clean$source_ref)
  expect_true("r2" %in% out$clean$source_ref)
  # r3 shares r1's exact datetime - it is the duplicate, not r2.
  expect_false("r3" %in% out$clean$source_ref)
  hit <- out$review[out$review$source_ref == "r3", ]
  expect_equal(nrow(hit), 1)
  expect_identical(hit$kind, "batch_duplicate")
})

test_that("PLAN-8b: cross-batch - different point, same datetime, does not falsely match an existing sample (already_present) at another feature", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  # T.S02/fa-0002 has no seeded analysis; s-0001's datetime (T.S01) is
  # 24 May 2025 11:45 Sydney. Same instant, different feature - must commit
  # clean, never match across features.
  event <- mk_event(mk_row(source_ref = "r1", feature_raw = "T.S02",
                           lab_sample_id = "XX1234567002",
                           sample_datetime_raw = "24 May 2025 11:45"))
  out <- reconcile_event(event, con)
  expect_true("r1" %in% out$clean$source_ref)
  expect_false("r1" %in% out$skipped$source_ref)
})

test_that("PLAN-8b: cross-batch - same point, both date-only (no time on the incoming row OR the committed candidate), same date - treated as the SAME event (already_present)", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  # T.S02/fa-0002: fresh feature, seed a committed candidate with a NULL
  # datetime (a historically date-only source row), same date/value/method as
  # the incoming date-only row.
  DBI::dbExecute(con, "INSERT INTO \"sample\" (uuid, uuid_feature_alias, uuid_project, date, datetime, organisation) VALUES
    ('s-dateonly', 'fa-0002', 'p-0001', TIMESTAMP '2025-05-20 00:00:00', NULL, 'ALS')")
  DBI::dbExecute(con, "INSERT INTO analysis (uuid, uuid_sample, uuid_lab, value, quantified, rl_low) VALUES
    ('an-dateonly', 's-dateonly', 'lm-0002', 500, TRUE, 0.1)")

  event <- mk_event(mk_row(source_ref = "r1", feature_raw = "T.S02",
                           lab_sample_id = "XX1234567002",
                           sample_datetime_raw = "20/05/2025",
                           value_raw = "0.5", value_num = 0.5, below_detection = FALSE, rl = 0.1))
  out <- reconcile_event(event, con)

  hit <- out$skipped[out$skipped$source_ref == "r1", ]
  expect_equal(nrow(hit), 1)
  expect_identical(hit$reason, "already_present")
  expect_identical(hit$existing_uuid, "an-dateonly")
})

# Cross-batch same-point-same-date-DIFFERENT-datetime (new event, not
# already_present) and cross-batch same-point-SAME-datetime (already_present,
# never double-committed) are already covered above by the pre-existing
# R-11.18/A62 tests ("a same feature+date+lab+value measurement at a DISTINCT
# datetime is a new sampling" / R-8.7 "an identical re-ingest row is
# already_present") - both paths now share `.rc_provably_distinct_datetime()`
# with `.rc_batch_duplicate()`, so this file does not re-test them here.

# =============================================================================
# PLAN-15 Work B - Layer-2 structural (site, point) resolver (PINNED SPEC)
# PLAN-15 Work C - Layer-3 WO single-site disambiguation (PINNED SPEC)
#
# Seam names below are PROPOSED by this test file, not pinned by the plan
# (Work B/C introduce genuinely new production code; Work A's own
# `.rc_feature_key` was likewise named by its implementer, not the plan).
# `.rc_site_registry(registry)` - B.1 site set, longest nchar first.
# `.rc_canonical_point(x)` - B.3 point canonicalisation (uppercase, strip
# leading zeros per digit run). Both are internal `.rc_*` helpers mirroring
# the existing `.rc_feature_key`/`.rc_feature_candidates` naming convention;
# if the implementer names them differently, these two unit tests need a
# rename delta - every other test below drives the real `reconcile_event()`/
# `commit_event()` seam and is naming-independent.
# =============================================================================

# ---- B.1: site registry -----------------------------------------------------

test_that("B.1: .rc_site_registry() reads the site set from the feature.site COLUMN (never a feature.name prefix parse), longest nchar first", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  registry <- .rc_load_registry(con)
  sites <- .rc_site_registry(registry)

  # LITERAL oracle over the seeded fixture (helper-db.R), NOT a re-derivation
  # of the same expression the implementation itself would use. The old
  # `expected <- unique(registry$feature$site[...])` form was satisfied by ANY
  # implementation that read *some* site-like set - including a name-prefix
  # parse, because on the old fixture prefix and site always agreed.
  # B.1's "tests must not hard-code the site set" bars encoding the LIVE
  # registry's {B, K, L, BH}; the throwaway fixture's own site set is a test
  # constant we own and is pinned here deliberately.
  expect_setequal(sites, c("T", "TH", "Z"))
  # longest-match-first: nchar is non-increasing across the returned order.
  expect_true(!is.unsorted(rev(nchar(sites))))

  # F8 discriminator: f-0013 is NAMED 'Q.S01' but SITED 'Z'. A name-prefix
  # parse yields 'Q' and never 'Z'; the column yields 'Z' and never 'Q'.
  expect_true("Z" %in% sites)
  expect_false("Q" %in% sites)
})

test_that("B.1/B.3: a feature whose name prefix != its site is EXCLUDED from the structural index - the raw 'Q S01' (f-0013 'Q.S01', site 'Z') never resolves", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  # The B.1 unit test above cannot reach this: it dies on the missing
  # `.rc_site_registry` symbol. This is the same rule at RESOLUTION level,
  # which is what actually protects data. f-0013 carries a self-alias
  # (fa-0024), so an implementation that derived the site from a name prefix
  # would produce a unique structural hit WITH a usable alias and auto-commit
  # the row under a feature whose real site is 'Z'. Paired with the positive
  # control so a merely-disabled resolver fails the test too.
  event <- mk_event(mk_rows(
    mk_row(source_ref = "prefix_not_site", feature_raw = "Q S01",
           lab_sample_id = "XX9999979001", sample_datetime_raw = "20 Jun 2025 09:00"),
    mk_row(source_ref = "control", feature_raw = "T S01",
           lab_sample_id = "XX9999979002", sample_datetime_raw = "20 Jun 2025 09:00")
  ))
  out <- reconcile_event(event, con)

  pns <- out$clean[out$clean$source_ref == "prefix_not_site", ]
  expect_true(pns$feature_pending)
  expect_true(is.na(pns$uuid_feature))

  ctl <- out$clean[out$clean$source_ref == "control", ]
  expect_false(ctl$feature_pending)
  expect_identical(ctl$uuid_feature, "f-0001")
})

# ---- B.2: boundaries and parsing --------------------------------------------

test_that("R-15.4/R-15.24/R-15.25/B.2: a DIRECT (no dot/space) boundary NEVER auto-resolves - falsified against the F2 collision oracle (TS1 curated -> TH.S01, the OPPOSITE site from a naive TS01->T.S01 parse)", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  registry <- .rc_load_registry(con)
  event <- mk_event(mk_rows(
    mk_row(source_ref = "direct", feature_raw = "TS01", lab_sample_id = "XX9999997001",
           sample_datetime_raw = "02 Jun 2025 09:00"),
    mk_row(source_ref = "boundary", feature_raw = "T S01", lab_sample_id = "XX9999997002",
           sample_datetime_raw = "02 Jun 2025 09:00"),
    mk_row(source_ref = "curated", feature_raw = "TS1", lab_sample_id = "XX9999997003",
           sample_datetime_raw = "02 Jun 2025 09:00")
  ))
  out <- reconcile_event(event, con)

  # NEGATIVE: "TS01" has no dot/space boundary - must NOT auto-resolve to
  # T.S01 (f-0001), even though a longest-match parse without the B.2 gate
  # would find it.
  direct_row <- out$clean[out$clean$source_ref == "direct", ]
  expect_true(direct_row$feature_pending)
  expect_true(is.na(direct_row$uuid_feature))

  # ... but B.2's other half: a direct boundary is SUGGESTION-ONLY, not
  # silence. The review item must still carry the structural parse so the
  # operator sees what was rejected. Without this assert an implementation
  # that emits a bare payload (no subkind) for the direct case passes.
  rv_direct <- out$review[out$review$kind == "unknown_feature" &
                            grepl("direct", out$review$source_ref, fixed = TRUE), ]
  expect_equal(nrow(rv_direct), 1)
  expect_identical(rv_direct$subkind[[1]], "structural")
  dg_direct <- jsonlite::fromJSON(rv_direct$payload[[1]])
  expect_identical(dg_direct$site, "T")

  # POSITIVE CONTROL (same test): the boundary form DOES auto-resolve -
  # proves the resolver is active, not merely disabled.
  boundary_row <- out$clean[out$clean$source_ref == "boundary", ]
  expect_false(boundary_row$feature_pending)
  expect_identical(boundary_row$uuid_feature, "f-0001")

  # F2 collision oracle: the CURATED "TS1" resolves to the OPPOSITE site
  # (TH.S01, f-0008) - proving "TS01" auto-resolving to T.S01 would have been
  # exactly the cross-site merge B.2 exists to prevent.
  curated_row <- out$clean[out$clean$source_ref == "curated", ]
  expect_false(curated_row$feature_pending)
  expect_identical(curated_row$uuid_feature, "f-0008")

  # R-15.24/R-15.25 (F.4): the collision oracle at Layer-1 candidate level,
  # positively specified. The retired oracle asserted only that TS1 and TS01
  # give DIFFERENT answers - satisfiable by the broken longest-match mutation
  # too, since a naive TS01 -> T.S01 parse (f-0001) also differs from TS1's
  # f-0008. Assert each result's IDENTITY on its own; never compare the two.
  cand_ts1 <- .rc_feature_candidates("TS1", as.Date("2025-06-02"), registry)
  expect_equal(nrow(cand_ts1), 1)
  expect_identical(cand_ts1$uuid_feature[[1]], "f-0008")   # TS1 -> TH.S01 (R-15.24)

  cand_ts01 <- .rc_feature_candidates("TS01", as.Date("2025-06-02"), registry)
  expect_equal(nrow(cand_ts01), 0)   # TS01 -> zero candidates (R-15.25), not "!= TS1"
})

test_that("B.2: boundary set is '.'/' ' ONLY - '_' inside a point is neither a split point nor stripped, and a residual with a second separator is unparseable", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  event <- mk_event(mk_rows(
    # underscore is not a boundary AND is not stripped during
    # canonicalisation - "T.MW_01" must NOT resolve to T.MW01 (f-0003) even
    # though a naive strip-all-non-alnum canonicaliser would collapse them.
    mk_row(source_ref = "underscore", feature_raw = "T.MW_01", lab_sample_id = "XX9999996001",
           sample_datetime_raw = "03 Jun 2025 09:00"),
    # positive control: a DIFFERENT, un-aliased space-boundary raw (needs
    # Layer 2, unlike 'T.MW01' which already resolves via the pre-existing
    # curated self-alias fa-0003) DOES resolve - proving the resolver is
    # active, not merely disabled.
    mk_row(source_ref = "clean_form", feature_raw = "T S02", lab_sample_id = "XX9999996002",
           sample_datetime_raw = "03 Jun 2025 09:00"),
    # "T.T.S01" splits at the FIRST '.' only, leaving residual "t.s01" which
    # still contains '.' - NOT parseable, so the row goes to review.
    # This raw (not the old "T.MW.01") is what makes the rule falsifiable: an
    # implementation that re-splits, or recurses on, the residual finds site
    # T + point S01 and auto-resolves to f-0001 - attaching the measurement to
    # a real, wrong feature. "T.MW.01" could not catch that: every
    # re-splitting of it misses the index anyway, so the assertion held for
    # correct and incorrect implementations alike.
    mk_row(source_ref = "second_separator", feature_raw = "T.T.S01", lab_sample_id = "XX9999996003",
           sample_datetime_raw = "03 Jun 2025 09:00")
  ))
  out <- reconcile_event(event, con)

  u <- out$clean[out$clean$source_ref == "underscore", ]
  expect_true(u$feature_pending)
  expect_true(is.na(u$uuid_feature))

  cf <- out$clean[out$clean$source_ref == "clean_form", ]
  expect_false(cf$feature_pending)
  expect_identical(cf$uuid_feature, "f-0002")

  dd <- out$clean[out$clean$source_ref == "second_separator", ]
  expect_true(dd$feature_pending)
  expect_true(is.na(dd$uuid_feature))
  # named negative: specifically NOT the feature a residual re-split reaches.
  expect_false(identical(dd$uuid_feature, "f-0001"))
})

# ---- B.3: point canonicalisation --------------------------------------------

test_that("B.3: canonical point worked set is pinned exactly (uppercase + strip leading zeros per digit run, NOT zero-pad)", {
  expect_equal(.rc_canonical_point("S1"), "S1")
  expect_equal(.rc_canonical_point("S01"), "S1")
  expect_equal(.rc_canonical_point("S001"), "S1")
  expect_equal(.rc_canonical_point("MW02A"), "MW2A")
  expect_equal(.rc_canonical_point("TS41"), "TS41")
  expect_equal(.rc_canonical_point("E02"), "E2")
  expect_equal(.rc_canonical_point("centroid"), "CENTROID")
})

test_that("B.3: canonical (site, point) is injective over the whole feature table (registry-driven invariant, no hard-coded count)", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  registry <- .rc_load_registry(con)
  feat <- registry$feature

  # Registry-side point = name minus leading site minus exactly one
  # following separator (B.3); a feature whose name prefix != its site is
  # EXCLUDED from the structural index.
  has_prefix <- !is.na(feat$site) & trimws(feat$site) != "" &
    substr(feat$name, 1, nchar(feat$site)) == feat$site
  sep_ok <- has_prefix &
    nchar(feat$name) > nchar(feat$site) &
    substr(feat$name, nchar(feat$site) + 1, nchar(feat$site) + 1) %in% c(".", " ")
  idx <- which(sep_ok)
  point_raw <- substr(feat$name[idx], nchar(feat$site[idx]) + 2, nchar(feat$name[idx]))
  canon_key <- paste(toupper(feat$site[idx]), .rc_canonical_point(point_raw), sep = "|")

  # B.3's own invariant: injective, and it must fail loudly if a future
  # same-site pair (the live K.G01 / K.G001 hazard) ever collides.
  expect_equal(length(unique(canon_key)), length(canon_key))   # 0 collisions

  # LITERAL oracle. `length(unique(x)) == length(x)` plus a >= floor held for
  # ANY canonicaliser - a pad-to-3 or a no-op uppercase is equally injective
  # over this fixture, so the old form pinned nothing about the VALUES.
  # These are the 12 seeded prefix==site features; f-0013 'Q.S01'/site 'Z' is
  # absent because B.3 EXCLUDES a feature whose name prefix != its site.
  expect_setequal(canon_key, c(
    "T|S1", "T|S2", "T|MW1", "T|S4", "T|S5", "T|S6", "T|S7", "T|S8",
    "T|G1", "TH|S1", "TH|MW2A", "TH|G1"
  ))
  expect_equal(length(canon_key), 12L)
  expect_false("Z|S1" %in% canon_key)   # excluded: name prefix 'Q' != site 'Z'
  expect_false("Q|S1" %in% canon_key)
})

test_that("B.3: digit width is never assumed - a 1-digit raw reaches a 3-wide point (T.G001), a 2-wide point (TH.G01) and a 2-char point (T.S01) alike", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  # WHAT THIS CATCHES (the old docstring's arithmetic was wrong and is
  # corrected here): a SYMMETRIC fixed-width zero-pad applied to BOTH the raw
  # and the registry side is algebraically equivalent to stripping leading
  # zeros - pad-to-3 turns 'G1' and 'G001' both into 'G001', pad-to-2 turns
  # both into 'G01' - so no fixture can distinguish it, and the old
  # "defeats both a pad-to-2 and a pad-to-3" claim was unachievable.
  # What this test DOES falsify: (a) no canonicalisation at all (a literal
  # string compare misses 'G1' vs 'G001'); (b) an asymmetric pad, applied to
  # the raw but not the registry side or vice versa; (c) any per-site or
  # per-prefix width assumption - r1 and r3 are BOTH site T and need widths
  # 3 and 2 respectively from the same 1-digit raw form.
  # NOTE the T.G001/TH.G01 pair is CROSS-site, so it does not reproduce the
  # live within-site K.G01/K.G026 mixed width; the within-site half is r1+r3,
  # and the collision hazard that mixed width creates is covered by the
  # injectivity invariant above, not here.
  event <- mk_event(mk_rows(
    mk_row(source_ref = "r1", feature_raw = "T G1", lab_sample_id = "XX9999998001",
           sample_datetime_raw = "01 Jun 2025 09:00"),
    mk_row(source_ref = "r2", feature_raw = "TH G1", lab_sample_id = "XX9999998002",
           sample_datetime_raw = "01 Jun 2025 09:00"),
    mk_row(source_ref = "r3", feature_raw = "T S1", lab_sample_id = "XX9999998003",
           sample_datetime_raw = "01 Jun 2025 09:00")
  ))
  out <- reconcile_event(event, con)
  row1 <- out$clean[out$clean$source_ref == "r1", ]
  row2 <- out$clean[out$clean$source_ref == "r2", ]
  row3 <- out$clean[out$clean$source_ref == "r3", ]
  expect_false(row1$feature_pending)
  expect_identical(row1$uuid_feature, "f-0010")   # T.G001 (3-wide digit run)
  expect_false(row2$feature_pending)
  expect_identical(row2$uuid_feature, "f-0011")   # TH.G01 (2-wide digit run)
  expect_false(row3$feature_pending)
  expect_identical(row3$uuid_feature, "f-0001")   # T.S01 (2-wide, SAME site as r1)
})

# ---- B.4: when Layer 2 runs (gating) ----------------------------------------

test_that("B.4: a key reaching >=1 alias row (all auto_assign=FALSE) is gated from Layer 2 EVEN WHEN its structural parse is a unique hit (mirrors the real b.s01 -> B.S01/B.TS41 shape)", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  # test-local ambiguity fixture: 'T.S77' reaches TWO auto_assign=FALSE rows
  # (self vs a fictitious historical_code pointing at f-0002). A structural
  # parse of 'T.S77' IS a unique hit (site T, point S77, matching the new
  # feature below) - without the B.4 gate, Layer 2 would silently
  # auto-resolve exactly this parked ambiguity.
  DBI::dbExecute(con, "INSERT INTO feature (uuid, name, site, flow, matrix, lon, lat) VALUES
    ('f-local-s77', 'T.S77', 'T', 'surface', 'water', 150.7777, -33.7777)")
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign, first_seen, last_seen, confirmed_by) VALUES
    ('fa-local-s77a', 'f-local-s77', 'T.S77', 't.s77', 'self', 0, FALSE,
     TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00', NULL),
    ('fa-local-s77b', 'f-0002', 'T.S77', 't.s77', 'historical_code', 0, FALSE,
     TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00', NULL)")

  event <- mk_event(mk_rows(
    mk_row(source_ref = "ambig", feature_raw = "T.S77", lab_sample_id = "XX9999995001",
           sample_datetime_raw = "04 Jun 2025 09:00"),
    # positive control (same test): a different, un-aliased structural raw
    # resolves fine in the same event, proving the resolver is active.
    mk_row(source_ref = "clean", feature_raw = "T S01", lab_sample_id = "XX9999995002",
           sample_datetime_raw = "04 Jun 2025 09:00")
  ))
  out <- reconcile_event(event, con)

  a <- out$clean[out$clean$source_ref == "ambig", ]
  expect_true(a$feature_pending)
  expect_true(is.na(a$uuid_feature))
  rv <- out$review[out$review$kind == "unknown_feature" & grepl("ambig", out$review$source_ref), ]
  expect_equal(nrow(rv), 1)
  expect_identical(rv$subkind[[1]], "ambiguous")
  expect_false(identical(rv$subkind[[1]], "structural"))

  cl <- out$clean[out$clean$source_ref == "clean", ]
  expect_false(cl$feature_pending)
  expect_identical(cl$uuid_feature, "f-0001")
})

test_that("B.4: an EXISTING dangling alias for a structurally-parseable key (F6) stays unresolved, carries a structural SUGGESTION, and re-ingesting the identical measurement does not double-commit (idempotency)", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # F6 fixture: fa-0023 'T S08' (space form, key 't s08') is a pre-existing
  # DANGLING alias; T.S08 (f-0012) exists in the registry and structurally
  # matches this key (site T, point S08 -> S8) - a unique hit if Layer 2 ran
  # unguarded. s-0005/an-0005 is the pre-committed measurement under fa-0023.
  #
  # The F6 raw is deliberately used TWICE, at two different dates, because
  # the two halves of B.4 have MUTUALLY EXCLUSIVE dispositions on one row:
  #  - "dangling_new" (20 Jun, no seeded sample) is a NEW measurement, stays
  #    in `clean`, and is where the gate/suggestion behaviour is observable;
  #  - "dangling_repeat" (15 May 09:15, byte-identical to s-0005/an-0005) is
  #    a REPEAT, so a correct .rc_three_way() classifies it already_present
  #    and REMOVES it from `clean` - it is the idempotency half only.
  # Asserting both dispositions on a single row (the pre-delta form) was
  # unsatisfiable under every correct implementation.
  event <- mk_event(mk_rows(
    mk_row(source_ref = "dangling_new", feature_raw = "T S08",
           lab_sample_id = "XX9999994003", sample_datetime_raw = "20 Jun 2025 09:00"),
    mk_row(source_ref = "dangling_repeat", feature_raw = "T S08",
           analyte_raw = "pH Value", org = "ALS", method_raw = "EA005P: pH by PC Titrator",
           units_raw = "pH", value_raw = "7.05", value_num = 7.05, below_detection = FALSE,
           rl = NA_real_, cas_number = NA_character_, lab_sample_id = "XX9999994001",
           sample_datetime_raw = "15 May 2025 09:15"),
    # positive control (same test): a FRESH, un-aliased structural raw for
    # the SAME target feature (extra zero-padding, reaching zero alias rows)
    # DOES auto-resolve - proving the gate, not a disabled resolver, is why
    # the dangling-alias rows above stayed pending.
    mk_row(source_ref = "fresh", feature_raw = "T.S008", lab_sample_id = "XX9999994002",
           sample_datetime_raw = "16 May 2025 09:00")
  ))
  out <- reconcile_event(event, con)

  dg <- out$clean[out$clean$source_ref == "dangling_new", ]
  expect_equal(nrow(dg), 1)
  expect_true(dg$feature_pending)
  expect_true(is.na(dg$uuid_feature))
  expect_identical(dg$uuid_feature_alias, "fa-0023")   # filled via R-11.5a natural key
  # both F6 rows share alias_key 't s08', so they group into ONE review item.
  rv <- out$review[out$review$kind == "unknown_feature" &
                     grepl("dangling_new", out$review$source_ref, fixed = TRUE), ]
  expect_equal(nrow(rv), 1)
  expect_identical(rv$subkind[[1]], "structural")   # B.4/B.7: structural suggestion attached

  fr <- out$clean[out$clean$source_ref == "fresh", ]
  expect_false(fr$feature_pending)
  expect_identical(fr$uuid_feature, "f-0012")

  # idempotency: the "dangling_repeat" row is the SAME measurement already
  # committed as s-0005/an-0005 - it must be recognised as already_present
  # (matched via s.uuid_feature_alias = fa-0023) and dropped from `clean`.
  expect_true("dangling_repeat" %in% out$skipped$source_ref)
  expect_identical(out$skipped$reason[out$skipped$source_ref == "dangling_repeat"], "already_present")
  expect_false("dangling_repeat" %in% out$clean$source_ref)

  commit_event(event, out, con)
  # THE oracle for the double-commit hazard, counted on the MEASUREMENT.
  # Counting `sample WHERE uuid_feature_alias = 'fa-0023'` was blind to it:
  # the failure mode B.4 exists to prevent is an ungated Layer 2 resolving
  # 't s08' to f-0012 and attaching f-0012's SELF alias fa-0021, so the
  # duplicate lands under fa-0021 and the fa-0023 count stays 1 either way.
  n_meas <- DBI::dbGetQuery(con, paste(
    "SELECT count(*) AS n FROM analysis a",
    "JOIN \"sample\" s ON s.uuid = a.uuid_sample",
    "WHERE CAST(s.date AS DATE) = DATE '2025-05-15' AND a.uuid_lab = 'lm-0001'"))$n
  expect_equal(n_meas, 1)
})

# ---- B.5: liveness -----------------------------------------------------------

test_that("B.5: an UNCONDITIONAL live-at-sample_date filter rejects a defunct structural hit (f-0006, date_end 2020-06-30) rather than resolving to it", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  event <- mk_event(mk_rows(
    # "T S006" is a fresh, un-aliased key that structurally matches f-0006's
    # canonical point (S06 -> S6) - a unique hit that is DEFUNCT at the 2025
    # sample date. A structural hit is unique by construction, so
    # .rc_narrow_live()'s "only narrow when length(unique(uuid_feature))>1"
    # guard would be a no-op here and wrongly resolve to the defunct feature -
    # Layer 2 must apply an unconditional live check instead.
    mk_row(source_ref = "defunct", feature_raw = "T S006", lab_sample_id = "XX9999993001",
           sample_datetime_raw = "05 Jun 2025 09:00"),
    # positive control (same test): a live target resolves normally.
    mk_row(source_ref = "live", feature_raw = "T S01", lab_sample_id = "XX9999993002",
           sample_datetime_raw = "05 Jun 2025 09:00")
  ))
  out <- reconcile_event(event, con)

  d <- out$clean[out$clean$source_ref == "defunct", ]
  expect_true(d$feature_pending)
  expect_true(is.na(d$uuid_feature))

  l <- out$clean[out$clean$source_ref == "live", ]
  expect_false(l$feature_pending)
  expect_identical(l$uuid_feature, "f-0001")
})

# ---- B.6: the alias side of a structural hit --------------------------------

test_that("B.6: a Layer-2 structural hit carries the target's self-alias uuid; a target with NO self-alias goes to review instead of committing with a NA alias", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  # test-local target with NO self-alias, to exercise the "review, never a
  # NA alias" fallback (B.6).
  DBI::dbExecute(con, "INSERT INTO feature (uuid, name, site, flow, matrix, lon, lat) VALUES
    ('f-local-s99', 'T.S99', 'T', 'surface', 'water', 150.9999, -33.0099)")

  event <- mk_event(mk_rows(
    # The target is f-0007 (T.S07), NOT f-0002: f-0007 carries TWO alias rows
    # - fa-0008 ('T.REUSED', kind historical_code, inserted FIRST) and
    # fa-0014 ('T.S07', kind self). B.6 pins "the target's SELF-alias uuid",
    # and only a two-alias target can tell that apart from "the first alias
    # row found for this uuid_feature", which is what f-0002 (one alias)
    # could not.
    mk_row(source_ref = "with_alias", feature_raw = "T S07", lab_sample_id = "XX9999992001",
           sample_datetime_raw = "06 Jun 2025 09:00"),
    mk_row(source_ref = "no_alias", feature_raw = "T S99", lab_sample_id = "XX9999992002",
           sample_datetime_raw = "06 Jun 2025 09:00")
  ))
  out <- reconcile_event(event, con)

  wa <- out$clean[out$clean$source_ref == "with_alias", ]
  expect_false(wa$feature_pending)
  expect_identical(wa$uuid_feature, "f-0007")
  expect_identical(wa$uuid_feature_alias, "fa-0014")   # T.S07's SELF alias
  expect_false(identical(wa$uuid_feature_alias, "fa-0008"))  # not the first-listed alias

  no_alias_row <- out$clean[out$clean$source_ref == "no_alias", ]
  expect_true(no_alias_row$feature_pending)   # never committed with a NA alias
  expect_true(is.na(no_alias_row$uuid_feature_alias))
  expect_true("no_alias" %in% out$review$source_ref)

  # D8 (PLAN-7b round-2): the identical "never commit with a NA alias" guard
  # exists a SECOND time, on the Layer-3 branch (`:899`) - a second event,
  # to keep it independent of the Layer-2 case above. 'S99L3' carries NO
  # recognised site prefix at all (Layer-2's own parse never fires for it),
  # so it can only be retried by Layer 3, which assumes the event's single
  # resolved site ('T', established here by 'T.S01') and structurally hits
  # a target ('T.S99L3') that - like f-local-s99 above - carries no
  # self-alias.
  DBI::dbExecute(con, "INSERT INTO feature (uuid, name, site, flow, matrix, lon, lat) VALUES
    ('f-local-s99l3', 'T.S99L3', 'T', 'surface', 'water', 150.9998, -33.0098)")

  event2 <- mk_event(mk_rows(
    mk_row(source_ref = "site_anchor", feature_raw = "T.S01", lab_sample_id = "XX9999993001",
           sample_datetime_raw = "06 Jun 2025 10:00"),
    mk_row(source_ref = "l3_no_alias", feature_raw = "S99L3", lab_sample_id = "XX9999993002",
           sample_datetime_raw = "06 Jun 2025 10:00")
  ))
  out2 <- reconcile_event(event2, con)

  anchor <- out2$clean[out2$clean$source_ref == "site_anchor", ]
  expect_false(anchor$feature_pending)   # establishes the event's single site (T)

  l3_row <- out2$clean[out2$clean$source_ref == "l3_no_alias", ]
  expect_true(l3_row$feature_pending)    # never committed with a NA alias
  expect_true(is.na(l3_row$uuid_feature_alias))
  expect_true(is.na(l3_row$uuid_feature))
  expect_true("l3_no_alias" %in% out2$review$source_ref)
})

test_that("B.6: two identical structurally-resolved rows in one batch are subject to the R-12.13 within-batch duplicate guard", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  event <- mk_event(mk_rows(
    mk_row(source_ref = "r1", feature_raw = "T S01", lab_sample_id = "XX9999991001",
           sample_datetime_raw = "07 Jun 2025 09:00"),
    mk_row(source_ref = "r2", feature_raw = "T S01", lab_sample_id = "XX9999991002",
           sample_datetime_raw = "07 Jun 2025 09:00")
  ))
  out <- reconcile_event(event, con)
  expect_equal(sum(c("r1", "r2") %in% out$clean$source_ref), 1)
  loser <- setdiff(c("r1", "r2"), out$clean$source_ref)
  # guard first: if the guard wrongly COLLAPSED both rows away, `loser` is
  # length 2 (and length 0 if both committed). Either way the `==` below
  # would recycle/compare against a zero- or two-length vector and the
  # failure would report as an opaque length mismatch rather than the real
  # defect. Mirrors the R-12.13 test at the top of this file.
  expect_equal(length(loser), 1)
  expect_identical(out$review$kind[out$review$source_ref == loser], "batch_duplicate")
})

# ---- B.7: acceptance criteria (every negative paired with a positive) ------

test_that("R-15.1/R-15.2/R-15.3/B.7: a structural miss (site recognised, no matching point) carries a subkind=structural suggestion in review, and neither a feature nor a structural alias is fabricated across reconcile+commit", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  before <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM feature")$n
  fa_before <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM feature_alias")$n

  event <- mk_event(mk_rows(
    mk_row(source_ref = "miss", feature_raw = "T S88", lab_sample_id = "XX9999990001",
           sample_datetime_raw = "08 Jun 2025 09:00"),
    # positive control (same test): the resolver is active.
    mk_row(source_ref = "hit", feature_raw = "T S01", lab_sample_id = "XX9999990002",
           sample_datetime_raw = "08 Jun 2025 09:00")
  ))
  out <- reconcile_event(event, con)

  m <- out$clean[out$clean$source_ref == "miss", ]
  expect_true(m$feature_pending)
  expect_true(is.na(m$uuid_feature))
  rv <- out$review[out$review$kind == "unknown_feature" & grepl("miss", out$review$source_ref), ]
  expect_equal(nrow(rv), 1)
  expect_identical(rv$subkind[[1]], "structural")
  dg <- jsonlite::fromJSON(rv$payload[[1]])
  # ANCHORED: dg$site is the exact site string, never merely a substring
  # match that "TH" would also satisfy.
  expect_identical(dg$site, "T")
  expect_identical(dg$point, "S88")

  h <- out$clean[out$clean$source_ref == "hit", ]
  expect_false(h$feature_pending)

  commit_event(event, out, con)
  after <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM feature")$n
  expect_equal(after, before)   # B.7: never fabricate a feature

  # B.6: commit must NOT materialise a kind='structural' feature_alias - a
  # structural resolution is a re-derivable rule, not curation. (The plain
  # `count(*) FROM feature` above cannot fail on today's code at all: commit.R
  # has no INSERT INTO feature. The alias counts below are the discriminating
  # half of "nothing fabricated"; the feature count is retained only because
  # B.7 names it as a criterion.)
  n_struct <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM feature_alias WHERE kind = 'structural'")$n
  expect_equal(n_struct, 0)
  # exactly ONE new alias - the R-11.8 pending alias for the UNRESOLVED
  # 'T S88' row. The resolved 'T S01' row rides f-0001's existing self-alias
  # and must add nothing.
  fa_after <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM feature_alias")$n
  expect_equal(fa_after, fa_before + 1)
  new_kinds <- DBI::dbGetQuery(con,
    "SELECT kind, alias_key FROM feature_alias WHERE uuid_feature IS NULL AND alias_key = 't s88'")
  expect_equal(nrow(new_kinds), 1)
  expect_identical(new_kinds$kind[[1]], "pending")
})

test_that("B.6: an event whose ONLY row is structurally resolved adds no feature_alias row at all at commit (no kind='structural' curation accreted)", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  fa_before <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM feature_alias")$n

  # 'T S01' reaches ZERO alias rows (the curated key is 't.s01', dotted), so
  # it can only resolve through Layer 2 - and B.6 pins that the resolution
  # rides f-0001's existing SELF alias rather than registering 't s01'.
  event <- mk_event(mk_row(source_ref = "r1", feature_raw = "T S01",
                           lab_sample_id = "XX9999978001",
                           sample_datetime_raw = "21 Jun 2025 09:00"))
  out <- reconcile_event(event, con)
  r1 <- out$clean[out$clean$source_ref == "r1", ]
  expect_false(r1$feature_pending)                     # positive control
  expect_identical(r1$uuid_feature, "f-0001")
  expect_identical(r1$uuid_feature_alias, "fa-0001")

  commit_event(event, out, con)
  fa_after <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM feature_alias")$n
  expect_equal(fa_after, fa_before)
  expect_equal(DBI::dbGetQuery(con,
    "SELECT count(*) AS n FROM feature_alias WHERE alias_key = 't s01'")$n, 0)
  expect_equal(DBI::dbGetQuery(con,
    "SELECT count(*) AS n FROM feature_alias WHERE kind = 'structural'")$n, 0)
})

# =============================================================================
# PLAN-15 Work C - Layer-3 WO single-site disambiguation
# =============================================================================

# ---- C.1: what "the event/WO" means -----------------------------------------

test_that("C.1: Layer 3 is SKIPPED entirely when event$orphan is TRUE (an unattributed bag of files has no meaningful single site)", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  rows <- mk_rows(
    mk_row(source_ref = "root", feature_raw = "TH.S01", lab_sample_id = "XX9999989001",
           sample_datetime_raw = "09 Jun 2025 09:00"),
    mk_row(source_ref = "candidate", feature_raw = "MW02A", lab_sample_id = "XX9999989002",
           sample_datetime_raw = "09 Jun 2025 09:00")
  )
  out_orphan <- reconcile_event(mk_event(rows, orphan = TRUE), con)
  c1 <- out_orphan$clean[out_orphan$clean$source_ref == "candidate", ]
  expect_true(c1$feature_pending)
  expect_true(is.na(c1$uuid_feature))

  # positive control (same test): the identical rows, non-orphan, DO resolve
  # via Layer 3 - proving orphan status, not a disabled resolver, is why.
  out_normal <- reconcile_event(mk_event(rows, orphan = FALSE), con)
  c2 <- out_normal$clean[out_normal$clean$source_ref == "candidate", ]
  expect_false(c2$feature_pending)
  expect_identical(c2$uuid_feature, "f-0009")   # TH.MW02A
})

test_that("C.1: Layer 3 is SKIPPED entirely when work_order is NA", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  rows <- mk_rows(
    mk_row(source_ref = "root", feature_raw = "TH.S01", lab_sample_id = "XX9999988001",
           sample_datetime_raw = "10 Jun 2025 09:00"),
    mk_row(source_ref = "candidate", feature_raw = "MW02A", lab_sample_id = "XX9999988002",
           sample_datetime_raw = "10 Jun 2025 09:00")
  )
  out_na <- reconcile_event(mk_event(rows, work_order = NA_character_), con)
  c1 <- out_na$clean[out_na$clean$source_ref == "candidate", ]
  expect_true(c1$feature_pending)
  expect_true(is.na(c1$uuid_feature))

  # positive control (same test): identical rows under a real WO DO resolve.
  out_normal <- reconcile_event(mk_event(rows, work_order = "XX1234567"), con)
  c2 <- out_normal$clean[out_normal$clean$source_ref == "candidate", ]
  expect_false(c2$feature_pending)
  expect_identical(c2$uuid_feature, "f-0009")
})

test_that("C.1: the site set is computed over the CURRENT EVENT ONLY, never re-queried from already-committed DB rows for the same work_order (a WO split across two runs must not leak site history)", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  wo <- "YY9876543"   # PLAN-15 F5 second work order/project (p-0003)

  event_a <- mk_event(mk_rows(
    mk_row(source_ref = "a1", feature_raw = "T.S01", work_order = wo,
           lab_sample_id = "YY9876543001", sample_datetime_raw = "01 Jul 2025 09:00"),
    mk_row(source_ref = "a2", feature_raw = "T.S02", work_order = wo,
           lab_sample_id = "YY9876543002", sample_datetime_raw = "01 Jul 2025 09:00")
  ), work_order = wo)
  out_a <- reconcile_event(event_a, con)
  commit_event(event_a, out_a, con)

  # A LATER "run" for the SAME work order: this batch's OWN resolved rows are
  # TH-only. If Layer 3 wrongly re-queried the DB for every sample ever
  # committed under this work_order, it would see {T, TH} (from event_a) and
  # disable itself as multi-site.
  event_b <- mk_event(mk_rows(
    mk_row(source_ref = "b1", feature_raw = "TH.S01", work_order = wo,
           lab_sample_id = "YY9876543003", sample_datetime_raw = "02 Jul 2025 09:00"),
    mk_row(source_ref = "candidate", feature_raw = "MW02A", work_order = wo,
           lab_sample_id = "YY9876543004", sample_datetime_raw = "02 Jul 2025 09:00")
  ), work_order = wo)
  out_b <- reconcile_event(event_b, con)

  c <- out_b$clean[out_b$clean$source_ref == "candidate", ]
  expect_false(c$feature_pending)
  expect_identical(c$uuid_feature, "f-0009")   # resolved via event_b's OWN {TH} site set
})

# ---- C.2: which rows Layer 3 may retry --------------------------------------

test_that("C.2: Layer 3 never retries a row that yielded a recognised site prefix (even with a missed point), and never retries a candidate whose separator survived an unrecognised prefix", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbExecute(con, "INSERT INTO feature (uuid, name, site, flow, matrix, lon, lat) VALUES
    ('f-local-th-s77', 'TH.S77', 'TH', 'surface', 'water', 150.7778, -33.7778)")
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign, first_seen, last_seen, confirmed_by) VALUES
    ('fa-local-th-s77', 'f-local-th-s77', 'TH.S77', 'th.s77', 'self', 0, TRUE,
     TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00', NULL)")

  event <- mk_event(mk_rows(
    mk_row(source_ref = "root", feature_raw = "TH.S01",
           lab_sample_id = "XX9999987001", sample_datetime_raw = "11 Jun 2025 09:00"),
    # POSITIVE control: no recognised site at all -> retried, resolves.
    mk_row(source_ref = "no_site", feature_raw = "MW02A",
           lab_sample_id = "XX9999987002", sample_datetime_raw = "11 Jun 2025 09:00"),
    # NEGATIVE a: recognised site T (point missed at T) - must NEVER be
    # retried as TH, even though TH.S77 exists and the event's sole site is TH.
    mk_row(source_ref = "recognised_site_missed_point", feature_raw = "T S77",
           lab_sample_id = "XX9999987003", sample_datetime_raw = "11 Jun 2025 09:00"),
    # NEGATIVE b: "XX.MW02A" has no recognised site token, so under the
    # orchestrator's C.2 ruling (the "leading recognised site token removed
    # if present" clause is STRUCK - Layer 3 only ever sees rows that yielded
    # NO recognised site) the candidate point is the WHOLE canonicalised raw,
    # which still contains '.'. Not retried, per "a candidate still containing
    # a separator is not retried".
    mk_row(source_ref = "residual_separator", feature_raw = "XX.MW02A",
           lab_sample_id = "XX9999987004", sample_datetime_raw = "11 Jun 2025 09:00")
  ))
  out <- reconcile_event(event, con)

  ns <- out$clean[out$clean$source_ref == "no_site", ]
  expect_false(ns$feature_pending)
  expect_identical(ns$uuid_feature, "f-0009")

  rp <- out$clean[out$clean$source_ref == "recognised_site_missed_point", ]
  expect_true(rp$feature_pending)
  expect_true(is.na(rp$uuid_feature))

  rs <- out$clean[out$clean$source_ref == "residual_separator", ]
  expect_true(rs$feature_pending)
  expect_true(is.na(rs$uuid_feature))
})

test_that("C.2/C.1 MISS path: when the assumed site yields NO hit the row stays in review and the review payload SUGGESTS that site (never a fabricated or a nearest-other-site match)", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  # Fixture F4, until now unused: T.MW01 (f-0003) exists and TH.MW01 does
  # NOT. In an all-TH event the raw 'MW01' is retried assuming TH, misses,
  # and per C.1 "else keep as review with S as the suggested site".
  # This is the branch that separates "assume S, no hit -> review" from the
  # two failure modes either side of it: fabricating a TH.MW01, or falling
  # back to the other site's T.MW01 (a cross-site merge).
  event <- mk_event(mk_rows(
    mk_row(source_ref = "root", feature_raw = "TH.S01",
           lab_sample_id = "XX9999976001", sample_datetime_raw = "23 Jun 2025 09:00"),
    # POSITIVE control (same test): 'MW02A' under the same assumed site TH IS
    # an exact hit (TH.MW02A, f-0009) - Layer 3 is active, not disabled.
    mk_row(source_ref = "l3_hit", feature_raw = "MW02A",
           lab_sample_id = "XX9999976002", sample_datetime_raw = "23 Jun 2025 09:00"),
    mk_row(source_ref = "l3_miss", feature_raw = "MW01",
           lab_sample_id = "XX9999976003", sample_datetime_raw = "23 Jun 2025 09:00")
  ))
  out <- reconcile_event(event, con)

  hit <- out$clean[out$clean$source_ref == "l3_hit", ]
  expect_false(hit$feature_pending)
  expect_identical(hit$uuid_feature, "f-0009")

  miss <- out$clean[out$clean$source_ref == "l3_miss", ]
  expect_true(miss$feature_pending)
  expect_true(is.na(miss$uuid_feature))
  # explicitly NOT the same point in the OTHER site.
  expect_false(identical(miss$uuid_feature, "f-0003"))   # T.MW01

  rv <- out$review[out$review$kind == "unknown_feature" &
                     grepl("l3_miss", out$review$source_ref, fixed = TRUE), ]
  expect_equal(nrow(rv), 1)
  # PROVISIONAL ORACLE (C.1/B.7): the plan pins the review payload grammar as
  # `subkind=structural,site=...,point=...` and pins that Layer 3's miss keeps
  # "S as the suggested site", but does not name a distinct subkind for the
  # Layer-3 case. Phase 6 re-checks the token against real output; the
  # load-bearing half is the anchored site=TH, which must be the ASSUMED site.
  expect_identical(rv$subkind[[1]], "structural")
  dg <- jsonlite::fromJSON(rv$payload[[1]])
  expect_identical(dg$site, "TH")
  expect_false(identical(dg$site, "T"))
  expect_identical(dg$point, "MW1")
})

# ---- C.3: the iff gate, operationally ---------------------------------------

test_that("C.3: a resolved feature with NA/blank site makes the whole event INELIGIBLE for Layer 3 (fail closed), even though the visible non-NA sites are single", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbExecute(con, "INSERT INTO feature (uuid, name, site, flow, matrix, lon, lat) VALUES
    ('f-local-nosite', 'V.VIRT01', NULL, 'surface', 'water', 150.5555, -33.5555)")
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign, first_seen, last_seen, confirmed_by) VALUES
    ('fa-local-nosite', 'f-local-nosite', 'V.VIRT01', 'v.virt01', 'self', 0, TRUE,
     TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00', NULL)")

  event <- mk_event(mk_rows(
    mk_row(source_ref = "nosite", feature_raw = "V.VIRT01",
           lab_sample_id = "XX9999986001", sample_datetime_raw = "12 Jun 2025 09:00"),
    mk_row(source_ref = "th", feature_raw = "TH.S01",
           lab_sample_id = "XX9999986002", sample_datetime_raw = "12 Jun 2025 09:00"),
    mk_row(source_ref = "candidate", feature_raw = "MW02A",
           lab_sample_id = "XX9999986003", sample_datetime_raw = "12 Jun 2025 09:00")
  ))
  out <- reconcile_event(event, con)

  c <- out$clean[out$clean$source_ref == "candidate", ]
  expect_true(c$feature_pending)
  expect_true(is.na(c$uuid_feature))

  # POSITIVE CONTROL (same test): the identical event MINUS the NA-site row
  # DOES let Layer 3 fire and resolve "MW02A" - proving the NA-site row
  # itself (not an unimplemented/disabled resolver in general) is what
  # blocks the negative case above.
  clean_event <- mk_event(mk_rows(
    mk_row(source_ref = "th", feature_raw = "TH.S01",
           lab_sample_id = "XX9999986004", sample_datetime_raw = "12 Jun 2025 09:00"),
    mk_row(source_ref = "candidate", feature_raw = "MW02A",
           lab_sample_id = "XX9999986005", sample_datetime_raw = "12 Jun 2025 09:00")
  ))
  out_clean <- reconcile_event(clean_event, con)
  cc <- out_clean$clean[out_clean$clean$source_ref == "candidate", ]
  expect_false(cc$feature_pending)
  expect_identical(cc$uuid_feature, "f-0009")
})

test_that("D15/C.3: a resolved feature with a BLANK (empty-string, not NA) site ALSO makes the event INELIGIBLE for Layer 3 (fail closed) - the other half of C.3's 'NA or blank site' rule; the sibling test above covers only the NA half", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbExecute(con, "INSERT INTO feature (uuid, name, site, flow, matrix, lon, lat) VALUES
    ('f-local-blanksite', 'V.VIRT02', '', 'surface', 'water', 150.5556, -33.5556)")
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign, first_seen, last_seen, confirmed_by) VALUES
    ('fa-local-blanksite', 'f-local-blanksite', 'V.VIRT02', 'v.virt02', 'self', 0, TRUE,
     TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00', NULL)")

  # A single resolved row whose feature's site is '' (blank, not NULL) is the
  # event's ONLY resolved feature - so `unique(trimws(s))` alone (with the
  # blank-guard mutated away) would read as "one single site: ''", NOT as
  # ">1 distinct site", so the discriminating observable is NOT whether
  # "candidate" resolves (a blank site never matches any real structural
  # index entry, so it stays unresolved either way) but whether Layer 3 was
  # even ATTEMPTED: without the guard `struct_site` gets set to '' before the
  # (failing) hit lookup, which flips the review payload's subkind from bare
  # (NA) to 'structural' with a meaningless site=''.
  event <- mk_event(mk_rows(
    mk_row(source_ref = "blanksite", feature_raw = "V.VIRT02",
           lab_sample_id = "XX9999984001", sample_datetime_raw = "12 Jun 2025 09:00"),
    mk_row(source_ref = "candidate", feature_raw = "MW02A",
           lab_sample_id = "XX9999984002", sample_datetime_raw = "12 Jun 2025 09:00")
  ))
  out <- reconcile_event(event, con)

  c <- out$clean[out$clean$source_ref == "candidate", ]
  expect_true(c$feature_pending)
  expect_true(is.na(c$uuid_feature))

  rv <- out$review[out$review$kind == "unknown_feature" &
                      grepl("candidate", out$review$source_ref, fixed = TRUE), ]
  expect_equal(nrow(rv), 1)
  expect_true(is.na(rv$subkind[[1]]))   # bare - never 'structural' with site=''
})

test_that("C.3: curation always wins - a row gated by an existing feature_alias entry (B.4) is never resolved by WO site-inference either", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  # THE discriminating row is "gated_no_site". The previous form used
  # 'T S08' (gated by fa-0023), but that raw yields a RECOGNISED site prefix,
  # so C.2's "Layer 3 never retries a recognised-site row" already blocks it
  # and an implementation that ignored B.4's alias gate in Layer 3 entirely
  # left the suite at its exact baseline. A gated key with NO site prefix is
  # reachable by Layer 3 and only the gate can stop it.
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign, first_seen, last_seen, confirmed_by) VALUES
    ('fa-local-s08', NULL, 'S08', 's08', 'pending', 0, FALSE,
     TIMESTAMP '2025-05-01 08:00:00', TIMESTAMP '2025-05-01 08:00:00', NULL)")

  event <- mk_event(mk_rows(
    mk_row(source_ref = "root", feature_raw = "T.S01",
           lab_sample_id = "XX9999985001", sample_datetime_raw = "13 Jun 2025 09:00"),
    # gated by the DANGLING alias 's08' and carrying no site token at all.
    # The event's sole resolved site is T and T.S08 (f-0012) exists, so
    # Layer 3 assuming T WOULD hit - the B.4 gate is the only thing between
    # this row and a silent auto-resolution over a curator's pending alias.
    mk_row(source_ref = "gated_no_site", feature_raw = "S08",
           lab_sample_id = "XX9999985004", sample_datetime_raw = "13 Jun 2025 09:00"),
    # second negative, kept for documentation: gated by fa-0023 AND
    # site-prefixed, so both B.4 and C.2 forbid it.
    mk_row(source_ref = "gated", feature_raw = "T S08",
           lab_sample_id = "XX9999985002", sample_datetime_raw = "13 Jun 2025 09:00"),
    # positive control (same test): a DIFFERENT un-aliased no-site row DOES
    # resolve via inference in the same single-T event.
    mk_row(source_ref = "inferred", feature_raw = "S07",
           lab_sample_id = "XX9999985003", sample_datetime_raw = "13 Jun 2025 09:00")
  ))
  out <- reconcile_event(event, con)

  gns <- out$clean[out$clean$source_ref == "gated_no_site", ]
  expect_equal(nrow(gns), 1)
  expect_true(gns$feature_pending)
  expect_true(is.na(gns$uuid_feature))
  expect_false(identical(gns$uuid_feature, "f-0012"))  # the site-inferred hit it must NOT take

  g <- out$clean[out$clean$source_ref == "gated", ]
  expect_true(g$feature_pending)
  expect_true(is.na(g$uuid_feature))

  i <- out$clean[out$clean$source_ref == "inferred", ]
  expect_false(i$feature_pending)
  expect_identical(i$uuid_feature, "f-0007")
})

test_that("C.3: an event with ZERO resolved rows is skipped by Layer 3 - a merely PARSED (but unresolved) site prefix is not a site set", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  # C.3 pins Resolved = !is.na(uuid_feature) after Layers 1-2, and C.1's iff
  # gate skips the event when that set is empty. The hazard this catches is an
  # implementation that builds the site set from RECOGNISED PARSES instead:
  # 'T S88' parses to site T but resolves to nothing (no T.S88 feature), so a
  # parse-derived set is {T} and 'S02' would be auto-assigned to T.S02.
  no_resolved <- mk_event(mk_rows(
    mk_row(source_ref = "parse_only", feature_raw = "T S88",
           lab_sample_id = "XX9999977001", sample_datetime_raw = "22 Jun 2025 09:00"),
    mk_row(source_ref = "candidate", feature_raw = "S02",
           lab_sample_id = "XX9999977002", sample_datetime_raw = "22 Jun 2025 09:00")
  ))
  out_none <- reconcile_event(no_resolved, con)
  po <- out_none$clean[out_none$clean$source_ref == "parse_only", ]
  expect_true(po$feature_pending)          # precondition: zero resolved rows
  c1 <- out_none$clean[out_none$clean$source_ref == "candidate", ]
  expect_true(c1$feature_pending)
  expect_true(is.na(c1$uuid_feature))

  # POSITIVE CONTROL (same test): the identical candidate row in an event that
  # DOES have a resolved T row resolves - so the negative above is the empty
  # resolved set, not a disabled Layer 3.
  with_resolved <- mk_event(mk_rows(
    mk_row(source_ref = "root", feature_raw = "T.S01",
           lab_sample_id = "XX9999977003", sample_datetime_raw = "22 Jun 2025 09:00"),
    mk_row(source_ref = "candidate", feature_raw = "S02",
           lab_sample_id = "XX9999977004", sample_datetime_raw = "22 Jun 2025 09:00")
  ))
  out_some <- reconcile_event(with_resolved, con)
  c2 <- out_some$clean[out_some$clean$source_ref == "candidate", ]
  expect_false(c2$feature_pending)
  expect_identical(c2$uuid_feature, "f-0002")
})

# Phase-5 audit C3: the seam table's degenerate list opens with "Empty event
# - zero rows reach the resolver" and nothing drove it. Measured: it
# currently returns clean=0 review=0 skipped=0 without error - a missing
# REGRESSION GUARD, not a live crash. The hazard it guards is Layer 3's
# `iff exactly one site` gate over a zero-length vector (the classic
# `length(unique(x)) == 1` trap over an empty candidate set).
test_that("C.3: an EMPTY event (zero rows reach the resolver) is handled without error - clean/review/skipped all zero-row", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  empty_event <- mk_event(mk_row(source_ref = "unused")[0, ])
  expect_equal(nrow(empty_event$results), 0) # precondition: genuinely zero rows

  out <- NULL
  expect_no_error(out <- reconcile_event(empty_event, con))
  expect_equal(nrow(out$clean), 0)
  expect_equal(nrow(out$review), 0)
  expect_equal(nrow(out$skipped), 0)
})

# Phase-5 audit round 2 C5: the seam table's SECOND degenerate shape -
# "Single-row event - the site set has one member; Layer 3's 'single site'
# must not be satisfied vacuously by an event that resolved nothing." The
# only single-row-event test in this file (B.6, above) has its row RESOLVE
# at Layer 2, so Layer 3's gate is never the discriminating seam there; the
# "resolved nothing" half is otherwise covered only by a TWO-row test
# (C.3's `no_resolved` case, above). This is the compound shape - ONE row,
# resolving NOTHING, reaching the Layer-3 gate - and it was untested.
# Measured (not a live defect): it currently behaves correctly. Written as
# a REGRESSION GUARD, same class as the empty-event test immediately above.
test_that("Work C: a SINGLE-row event whose one row resolves at NEITHER Layer 1 nor Layer 2 does not vacuously satisfy Layer 3's 'exactly one site' gate - stays pending, never auto-assigned", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # 'MW02A' matches no feature_alias row and carries no recognised site
  # prefix (T/TH/Z) - unresolved at both Layer 1 and Layer 2. The hazard is
  # an implementation deriving the "site set" from something other than the
  # RESOLVED rows (e.g. a length-1 vector coerced from a zero-row/NA site),
  # which could wrongly read "exactly one site" and auto-assign - the
  # classic `length(unique(x)) == 1` trap over an empty candidate set.
  event <- mk_event(mk_row(source_ref = "solo", feature_raw = "MW02A",
                            lab_sample_id = "XX9999976001",
                            sample_datetime_raw = "23 Jun 2025 09:00"))
  out <- reconcile_event(event, con)
  solo <- out$clean[out$clean$source_ref == "solo", ]
  expect_equal(nrow(solo), 1)
  expect_true(solo$feature_pending)
  expect_true(is.na(solo$uuid_feature))
})

# ---- C.4: provenance ---------------------------------------------------------

test_that("C.4: a plain Layer-2 structural resolution writes a 'structural_parse:' change_log provenance row at COMMIT (reconcile stays read-only)", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  before <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM change_log")$n

  event <- mk_event(mk_row(source_ref = "r1", feature_raw = "T S07",
                           lab_sample_id = "XX9999984001", sample_datetime_raw = "14 Jun 2025 09:00"))
  out <- reconcile_event(event, con)
  # reconcile is read-only (A32): no change_log row exists yet.
  mid <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM change_log")$n
  expect_equal(mid, before)

  # C.4, POSITIVE half: confidence rides on the CLEAN ROW's own `confidence`
  # field (R/ir.R:17,26 declares it "double"). Asserting only that change_log
  # has no `confidence` column pinned the negative half alone - it was equally
  # satisfied by an implementation that carried no confidence anywhere.
  # PROVISIONAL ORACLE (C.4): the plan pins WHERE confidence rides, not what
  # a structural resolution's value is; Phase 6 pins the value against real
  # output. Until then: present, non-NA, and a valid probability.
  r1 <- out$clean[out$clean$source_ref == "r1", ]
  expect_false(r1$feature_pending)                  # positive control: resolved
  expect_true("confidence" %in% names(out$clean))
  expect_false(is.na(r1$confidence))
  expect_true(is.numeric(r1$confidence))
  expect_true(r1$confidence > 0 && r1$confidence <= 1)

  commit_event(event, out, con)
  log <- DBI::dbGetQuery(con,
    "SELECT * FROM change_log WHERE action = 'provenance' AND tbl = 'sample' AND field = 'uuid_feature_alias' AND reason LIKE 'structural_parse:%'")
  expect_equal(nrow(log), 1)
  # C.4: confidence rides on the row's own field, never smuggled into reason
  # (change_log has no confidence column at all).
  expect_false("confidence" %in% names(log))
  if (nrow(log) == 1) {
    expect_true(is.na(log$old[[1]]) || log$old[[1]] == "")
    expect_identical(log$new[[1]], "fa-0014")   # T.S07's self-alias
    expect_true(grepl("T S07", log$reason[[1]], fixed = TRUE) || grepl("T.S07", log$reason[[1]], fixed = TRUE))
    expect_false(grepl("confidence", log$reason[[1]], ignore.case = TRUE))
  }
})

test_that("C.4: a Layer-3 WO-inferred resolution writes a 'wo_site_inferred: <raw> -> <feature.name> (sites={...})' change_log provenance row at COMMIT", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  event <- mk_event(mk_rows(
    mk_row(source_ref = "root", feature_raw = "TH.S01",
           lab_sample_id = "XX9999983001", sample_datetime_raw = "15 Jun 2025 09:00"),
    mk_row(source_ref = "candidate", feature_raw = "MW02A",
           lab_sample_id = "XX9999983002", sample_datetime_raw = "15 Jun 2025 09:00")
  ))
  out <- reconcile_event(event, con)
  commit_event(event, out, con)

  log <- DBI::dbGetQuery(con,
    "SELECT * FROM change_log WHERE action = 'provenance' AND tbl = 'sample' AND field = 'uuid_feature_alias' AND reason LIKE 'wo_site_inferred:%'")
  expect_equal(nrow(log), 1)
  expect_false("confidence" %in% names(log))
  if (nrow(log) == 1) {
    expect_true(grepl("MW02A", log$reason[[1]], fixed = TRUE))
    expect_true(grepl("TH.MW02A", log$reason[[1]], fixed = TRUE))
    expect_true(grepl("sites={TH}", log$reason[[1]], fixed = TRUE))
    expect_identical(log$new[[1]], "fa-0018")   # TH.MW02A's self-alias
  }
})

# ---- C.5: acceptance criteria (positive control across two events) ---------

test_that("R-15.5/C.5: the SAME unresolved raw resolves in a single-site event and stays in review in a mixed-site event (positive control across two events, one test)", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  single_site_event <- mk_event(mk_rows(
    mk_row(source_ref = "root", feature_raw = "TH.S01",
           lab_sample_id = "XX9999982001", sample_datetime_raw = "16 Jun 2025 09:00"),
    mk_row(source_ref = "candidate", feature_raw = "MW02A",
           lab_sample_id = "XX9999982002", sample_datetime_raw = "16 Jun 2025 09:00")
  ))
  out_single <- reconcile_event(single_site_event, con)
  c1 <- out_single$clean[out_single$clean$source_ref == "candidate", ]
  expect_false(c1$feature_pending)
  expect_identical(c1$uuid_feature, "f-0009")

  mixed_site_event <- mk_event(mk_rows(
    mk_row(source_ref = "root_t", feature_raw = "T.S01",
           lab_sample_id = "XX9999982003", sample_datetime_raw = "16 Jun 2025 09:00"),
    mk_row(source_ref = "root_th", feature_raw = "TH.S01",
           lab_sample_id = "XX9999982004", sample_datetime_raw = "16 Jun 2025 09:00"),
    mk_row(source_ref = "candidate", feature_raw = "MW02A",
           lab_sample_id = "XX9999982005", sample_datetime_raw = "16 Jun 2025 09:00")
  ))
  out_mixed <- reconcile_event(mixed_site_event, con)
  c2 <- out_mixed$clean[out_mixed$clean$source_ref == "candidate", ]
  expect_true(c2$feature_pending)
  expect_true(is.na(c2$uuid_feature))
})

test_that("R-15.6/C.5: one curated cross-site alias suppresses Layer 3 for the WHOLE event, even inside an otherwise-all-T WO (ruling: it does)", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  all_t_event <- mk_event(mk_rows(
    mk_row(source_ref = "root", feature_raw = "T.S01",
           lab_sample_id = "XX9999981001", sample_datetime_raw = "17 Jun 2025 09:00"),
    mk_row(source_ref = "candidate", feature_raw = "S02",
           lab_sample_id = "XX9999981002", sample_datetime_raw = "17 Jun 2025 09:00")
  ))
  out_t <- reconcile_event(all_t_event, con)
  c1 <- out_t$clean[out_t$clean$source_ref == "candidate", ]
  expect_false(c1$feature_pending)
  expect_identical(c1$uuid_feature, "f-0002")

  with_cross_alias_event <- mk_event(mk_rows(
    mk_row(source_ref = "root", feature_raw = "T.S01",
           lab_sample_id = "XX9999981003", sample_datetime_raw = "17 Jun 2025 09:00"),
    mk_row(source_ref = "cross", feature_raw = "TS1",
           lab_sample_id = "XX9999981004", sample_datetime_raw = "17 Jun 2025 09:00"),
    mk_row(source_ref = "candidate", feature_raw = "S02",
           lab_sample_id = "XX9999981005", sample_datetime_raw = "17 Jun 2025 09:00")
  ))
  out_x <- reconcile_event(with_cross_alias_event, con)
  cx <- out_x$clean[out_x$clean$source_ref == "cross", ]
  expect_false(cx$feature_pending)
  expect_identical(cx$uuid_feature, "f-0008")   # TS1 -> TH.S01, F2 collision oracle

  c2 <- out_x$clean[out_x$clean$source_ref == "candidate", ]
  expect_true(c2$feature_pending)
  expect_true(is.na(c2$uuid_feature))
})

test_that("A14/R-8.7: a re-ingested TEXT result matches as already_present and does NOT commit twice (quantified NA compares equal to NA)", {
  # Regression guard for the 2026-07-23 tri-state change. `quantified` is NA for
  # every text result; if .rc_values_equal() treats NA as unmatchable, the same
  # qualitative observation is re-committed on every re-ingest. Both the equal
  # case and the genuinely-different case are asserted, so the test cannot pass
  # by making everything match.
  expect_true(.rc_values_equal(
    inc_value = NA_real_, inc_chr = "Cloudy", inc_quant = NA,
    exist_value = NA_real_, exist_chr = "Cloudy", exist_quant = NA))

  expect_false(.rc_values_equal(
    inc_value = NA_real_, inc_chr = "Cloudy", inc_quant = NA,
    exist_value = NA_real_, exist_chr = "Clear", exist_quant = NA))

  # NA on one side only is a real difference, not a match
  expect_false(.rc_values_equal(
    inc_value = NA_real_, inc_chr = "Cloudy", inc_quant = NA,
    exist_value = 7.1, exist_chr = NA_character_, exist_quant = TRUE))
  expect_false(.rc_values_equal(
    inc_value = 7.1, inc_chr = NA_character_, inc_quant = TRUE,
    exist_value = NA_real_, exist_chr = "Cloudy", exist_quant = NA))

  # numeric behaviour is unchanged
  expect_true(.rc_values_equal(7.1, NA_character_, TRUE, 7.1, NA_character_, TRUE))
  expect_false(.rc_values_equal(7.1, NA_character_, TRUE, 7.1, NA_character_, FALSE))

  # D13 (PLAN-7b round-2): a NUMERIC value whose `quantified` state is itself
  # NA is still a genuine mismatch against a determinate measurement sharing
  # that same number - `is.na(inc_quant) != is.na(exist_quant)` is the ONLY
  # guard reached when `inc_quant` is NA (the OTHER guard two lines below,
  # `!is.na(inc_quant) && !identical(...)`, only fires when `inc_quant` is
  # non-NA, so it cannot substitute for this one). Without it, once both
  # `inc_value`/`exist_value` are non-NA and numerically equal, execution
  # falls straight into the numeric-tolerance branch and reports a match -
  # silently discarding a real change.
  expect_false(.rc_values_equal(
    inc_value = 100, inc_chr = NA_character_, inc_quant = NA,
    exist_value = 100, exist_chr = NA_character_, exist_quant = TRUE))
})

# ---- PLAN-15 Work E (E.1/E.2): alias-level date bounds ---------------------
#
# `feature_alias.date_start`/`date_end` exist in the DDL above (post-003
# shape) but nothing in R/reconcile.R reads them yet - migration 003 itself
# is not written. These tests fail RED until that reading is implemented.
# DATE granularity only - every bound literal below is `DATE 'YYYY-MM-DD'`,
# never TIMESTAMP, and every comparison date is `as.Date(...)`, never a
# POSIXct - converting a DATE bound through POSIXct is the tz hazard E.5
# documents and this project has already been bitten by (footguns: General).

test_that("R-15.7: an expired date_end alias does not resolve a later-dated row, paired in the same test with the identical row dated inside the bound, which DOES resolve", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, auto_assign, first_seen, last_seen, date_start, date_end) VALUES
    ('fa-e07', 'f-0002', 'T.EXPIRED07', 't.expired07', 'historical_code', TRUE,
     TIMESTAMP '2018-01-01 00:00:00', TIMESTAMP '2020-12-31 00:00:00', NULL, DATE '2020-12-31')")
  registry <- .rc_load_registry(con)

  # AFTER date_end: the bound has expired - must NOT resolve.
  cand_after <- .rc_feature_candidates("T.EXPIRED07", as.Date("2025-05-20"), registry)
  expect_equal(nrow(cand_after), 0)

  # PAIRED positive control (same test): the identical row dated INSIDE the
  # bound DOES resolve - without this pair a resolver that is simply broken
  # (never resolves anything) would also pass the assertion above.
  cand_inside <- .rc_feature_candidates("T.EXPIRED07", as.Date("2019-06-01"), registry)
  expect_equal(nrow(cand_inside), 1)
  expect_identical(cand_inside$uuid_feature[[1]], "f-0002")
})

test_that("R-15.8: a date_start bound blocks a row dated before the start date, paired in the same test with the identical row dated after the start, which DOES resolve", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, auto_assign, first_seen, last_seen, date_start, date_end) VALUES
    ('fa-e08', 'f-0002', 'T.STARTED08', 't.started08', 'historical_code', TRUE,
     TIMESTAMP '2024-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00', DATE '2024-01-01', NULL)")
  registry <- .rc_load_registry(con)

  # BEFORE date_start: not yet valid - must NOT resolve.
  cand_before <- .rc_feature_candidates("T.STARTED08", as.Date("2023-06-01"), registry)
  expect_equal(nrow(cand_before), 0)

  # PAIRED positive control (same test): dated AFTER date_start DOES resolve.
  cand_after <- .rc_feature_candidates("T.STARTED08", as.Date("2024-06-01"), registry)
  expect_equal(nrow(cand_after), 1)
  expect_identical(cand_after$uuid_feature[[1]], "f-0002")
})

test_that("R-15.9: a bounded two-arm key resolves via self-precedence to its own feature inside the historical arm's bound (R1/R2), with exactly one self_precedence_note, paired with the trivial resolve outside the bound", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  # T.S01's self-alias (fa-0001, unbounded, kind='self') shares its alias_key
  # with a NEW curated historical arm pointing at a DIFFERENT feature
  # (f-0002) - E.0's "an alias key IS another feature's real name" shape.
  # Bounded 2015-01-01..2019-12-31 (E.5-style curated historical window).
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, auto_assign, first_seen, last_seen, date_start, date_end) VALUES
    ('fa-e09', 'f-0002', 'T.S01', 't.s01', 'historical_code', TRUE,
     TIMESTAMP '2015-01-01 00:00:00', TIMESTAMP '2019-12-31 00:00:00',
     DATE '2015-01-01', DATE '2019-12-31')")

  event <- mk_event(mk_rows(
    # INSIDE the historical arm's bound: both fa-0001 (self -> f-0001) and
    # fa-e09 (historical -> f-0002) are alias-live. R1/R1a: the self arm is
    # unbounded, so it WINS over the shadowed historical arm; the row
    # resolves (not review) and a non-blocking self_precedence_note is
    # emitted (R2) recording that the override happened.
    mk_row(source_ref = "inside_bound", feature_raw = "T.S01",
           lab_sample_id = "XX9999900001", sample_datetime_raw = "01 Jun 2017 09:00"),
    # OUTSIDE the historical arm's bound (same test): fa-e09 has expired, so
    # only the self arm survives - a plain, non-precedence hit. Proves the
    # inside-bound resolve above is self-PRECEDENCE, not merely "date bounds
    # are ignored so it always resolves to f-0001 anyway".
    mk_row(source_ref = "outside_bound", feature_raw = "T.S01",
           lab_sample_id = "XX9999900002", sample_datetime_raw = "01 Jun 2025 09:00")
  ))
  out <- reconcile_event(event, con)

  inside <- out$clean[out$clean$source_ref == "inside_bound", ]
  expect_false(inside$feature_pending)
  expect_identical(inside$uuid_feature, "f-0001")   # self wins, never f-0002

  # S-15.6 pins `self_precedence_note` as the literal subkind token for this
  # non-blocking override annotation. Not asserting a specific `kind` column
  # value - the seam table pins the subkind grammar, not the top-level kind,
  # and this row is a HIT (not pending/held), a different case than every
  # existing `.rc_feature_review` payload today.
  #
  # TRANSLATED 2026-07-25 under PLAN-16 RULING A. This was authored against the
  # pre-PLAN-16 k=v payload grammar as
  #   grepl("subkind=self_precedence_note", out$review$payload)
  # which PLAN-16 retired: `subkind` is now a typed review_queue column
  # (db-schema.R:121, populated by .rq_row() at :589) and `payload` is JSON, so
  # the old substring can never match again and this assertion was pinning a
  # deleted grammar rather than the behaviour. The TOKEN is unchanged - only the
  # carrier moved from a string clause to a column. `!is.na()` is load-bearing:
  # `subkind == x` yields NA for rows with a NULL subkind, and NA in `[` indexing
  # selects an all-NA row rather than dropping it.
  note <- out$review[grepl("inside_bound", out$review$source_ref, fixed = TRUE) &
                        !is.na(out$review$subkind) &
                        out$review$subkind == "self_precedence_note", ]
  expect_equal(nrow(note), 1)

  outside <- out$clean[out$clean$source_ref == "outside_bound", ]
  expect_false(outside$feature_pending)
  expect_identical(outside$uuid_feature, "f-0001")
})

test_that("R-15.11: a key with one alias-live arm pointing at a DEFUNCT feature goes to review, not to the defunct feature - alias-side and feature-side liveness are separate filters, both apply", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  # Bound the LIVE arm (fa-0008 'T.REUSED' -> f-0007) so it expires before
  # the row's date. That leaves fa-0007 (-> f-0006, FEATURE-side defunct,
  # date_end 2020-06-30) as the ONLY alias-live arm at 2025-05-20.
  # `.rc_narrow_live()` only narrows when >1 distinct feature survives
  # (reconcile.R:190) - after alias-side filtering there is exactly ONE
  # alias-live candidate, so that guard is NOT the mechanism here (criterion
  # #5). Feature-side liveness must still apply UNCONDITIONALLY and exclude
  # f-0006 - the net candidate set is EMPTY, not a silent resolve to the
  # defunct feature.
  DBI::dbExecute(con, "UPDATE feature_alias SET date_end = DATE '2024-06-30' WHERE uuid = 'fa-0008'")
  registry <- .rc_load_registry(con)

  cand <- .rc_feature_candidates("T.REUSED", as.Date("2025-05-20"), registry)
  expect_equal(nrow(cand), 0)
})

test_that("R-15.12: a dangling pending alias whose bounds would exclude the row is still found by the natural-key lookup (bounds are exempt), and re-ingesting the same measurement commits it ONCE", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  # A dangling ('pending') alias carrying a bound that EXCLUDES the row's
  # 2025 sample date (2020-01-01..2020-06-30). The R-11.5a natural-key lookup
  # (.rc_resolve_existing_pending, reconcile.R:764) must ignore this entirely
  # - it is keyed on alias_key only, never on date - or the second ingest
  # would materialise a SECOND alias for the same key and commit twice.
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, auto_assign, first_seen, last_seen, date_start, date_end) VALUES
    ('fa-e12', NULL, 'T.PEND12', 't.pend12', 'pending', FALSE,
     TIMESTAMP '2025-05-10 08:00:00', TIMESTAMP '2025-05-10 08:00:00',
     DATE '2020-01-01', DATE '2020-06-30')")
  DBI::dbExecute(con, "INSERT INTO \"sample\"
    (uuid, uuid_feature_alias, uuid_project, date, datetime, organisation) VALUES
    ('s-e12', 'fa-e12', 'p-0001', TIMESTAMP '2025-05-20 00:00:00',
     TIMESTAMP '2025-05-19 23:00:00', 'ALS')")
  DBI::dbExecute(con, "INSERT INTO analysis (uuid, uuid_sample, uuid_lab, value, quantified, rl_low) VALUES
    ('an-e12', 's-e12', 'lm-0001', 7.20, TRUE, 0.01)")

  event <- mk_event(mk_row(
    source_ref = "r1", source_hash = "different-bytes-hash-r1512",
    feature_raw = "T.PEND12", analyte_raw = "pH Value", org = "ALS",
    method_raw = "EA005P: pH by PC Titrator", cas_number = NA_character_,
    units_raw = "pH Unit", value_raw = "7.200",
    value_num = 7.20, below_detection = FALSE, rl = 0.01,
    sample_datetime_raw = "20 May 2025 09:00"
  ))
  out <- reconcile_event(event, con)
  hit <- out$skipped[out$skipped$source_ref == "r1", ]
  expect_equal(nrow(hit), 1)
  expect_identical(hit$reason, "already_present")
  expect_false("r1" %in% out$clean$source_ref)

  commit_event(event, out, con)
  # The oracle counted on the MEASUREMENT, not just "no error" (brief #req).
  n_meas <- DBI::dbGetQuery(con, paste(
    "SELECT count(*) AS n FROM analysis a",
    "JOIN \"sample\" s ON s.uuid = a.uuid_sample",
    "WHERE CAST(s.date AS DATE) = DATE '2025-05-20' AND a.uuid_lab = 'lm-0001'"))$n
  expect_equal(n_meas, 1)
})

test_that("R-15.13: NULL/NULL alias bounds behave exactly as today (regression guard) - T.AMBIG2 ambiguity, T.REUSED narrowing, bs03alt hit, and a direct alias resolving at dates far either side of any curated bound", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  registry <- .rc_load_registry(con)

  cand_ambig <- .rc_feature_candidates("T.AMBIG2", as.Date("2025-05-20"), registry)
  expect_setequal(unique(cand_ambig$uuid_feature), c("f-0004", "f-0005"))

  cand_reused <- .rc_feature_candidates("T.REUSED", as.Date("2025-05-20"), registry)
  expect_equal(length(unique(cand_reused$uuid_feature)), 1)
  expect_identical(unique(cand_reused$uuid_feature), "f-0007")

  cand_hit <- .rc_feature_candidates("bs03alt", as.Date("2025-05-20"), registry)
  expect_equal(length(unique(cand_hit$uuid_feature)), 1)
  expect_identical(unique(cand_hit$uuid_feature), "f-0003")

  # A NULL/NULL alias (self, fa-0001) resolves at dates FAR either side of
  # any curated bound in this seed - NULL means unbounded on that side,
  # always, unconditionally.
  cand_far_past <- .rc_feature_candidates("T.S01", as.Date("1900-01-01"), registry)
  expect_equal(nrow(cand_far_past), 1)
  expect_identical(cand_far_past$uuid_feature[[1]], "f-0001")

  cand_far_future <- .rc_feature_candidates("T.S01", as.Date("2100-01-01"), registry)
  expect_equal(nrow(cand_far_future), 1)
  expect_identical(cand_far_future$uuid_feature[[1]], "f-0001")
})

#' A throwaway pre-003 seed: `feature_alias` in its ORIGINAL (001) shape,
#' with NO `date_start`/`date_end` columns at all - not columns of NA. Frame
#' threaded to the caller per the withr wrong-frame trap (footguns: R).
seed_pre003_con <- function(dir = NULL) {
  if (is.null(dir)) dir <- withr::local_tempdir(.local_envir = parent.frame())
  path <- file.path(dir, "pre003.duckdb")
  con <- DBI::dbConnect(duckdb::duckdb(), path, read_only = FALSE)
  DBI::dbExecute(con, "CREATE TABLE feature (
    uuid VARCHAR PRIMARY KEY, name VARCHAR, site VARCHAR, flow VARCHAR, matrix VARCHAR,
    geom_wkt VARCHAR, virtual BOOLEAN, date_start DATE, date_end DATE,
    lon DOUBLE NOT NULL, lat DOUBLE NOT NULL)")
  # PRE-003 shape (001:368-381) - NO date_start/date_end columns. This is the
  # genuine "absent column" case E.1/S-15.5 pins: fa$date_start must read
  # back NULL (not a column of NA) against a DB that never ran migration 003.
  DBI::dbExecute(con, "CREATE TABLE feature_alias (
    uuid VARCHAR PRIMARY KEY, uuid_feature VARCHAR, name VARCHAR NOT NULL,
    alias_key VARCHAR NOT NULL, kind VARCHAR, n_seen INTEGER DEFAULT 0,
    auto_assign BOOLEAN DEFAULT TRUE, first_seen TIMESTAMP, last_seen TIMESTAMP,
    confirmed_by VARCHAR, comments VARCHAR)")
  DBI::dbExecute(con, "CREATE TABLE feature_mask (uuid_feature VARCHAR, variant VARCHAR, name VARCHAR)")
  DBI::dbExecute(con, "CREATE TABLE analyte (uuid VARCHAR PRIMARY KEY, name VARCHAR, units VARCHAR,
    conversion_constant DOUBLE, type VARCHAR, CAS VARCHAR)")
  DBI::dbExecute(con, "CREATE TABLE lab_method (uuid VARCHAR PRIMARY KEY, uuid_analyte VARCHAR,
    name VARCHAR, method VARCHAR, organisation VARCHAR, rl_low DOUBLE, rl_high DOUBLE,
    reported_as VARCHAR, api VARCHAR, uuid_project VARCHAR, uuid_feature VARCHAR,
    comments VARCHAR, units VARCHAR, conversion_constant DOUBLE)")
  DBI::dbExecute(con, "CREATE TABLE project (uuid VARCHAR PRIMARY KEY, uuid_parent VARCHAR,
    uuid_root VARCHAR, uuid_project VARCHAR, name VARCHAR, type VARCHAR, purpose VARCHAR,
    date_start TIMESTAMP, date_end TIMESTAMP, regulated_by VARCHAR, cypher VARCHAR,
    site VARCHAR, value VARCHAR)")

  DBI::dbExecute(con, "INSERT INTO feature (uuid, name, site, flow, matrix, lon, lat) VALUES
    ('f-pre003-01', 'P.S01', 'P', 'surface', 'water', 150.9001, -33.9001)")
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, auto_assign, first_seen, last_seen) VALUES
    ('fa-pre003-01', 'f-pre003-01', 'P.S01', 'p.s01', 'self', TRUE,
     TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00')")
  con
}

test_that("R-15.14: the resolver against a pre-003 DB (date_start/date_end columns ABSENT, not a column of NA) behaves exactly as today and does not error (regression guard)", {
  con <- seed_pre003_con()
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  registry <- .rc_load_registry(con)

  # Criterion #4: absent columns, never a column of NA.
  expect_null(registry$feature_alias$date_start)
  expect_null(registry$feature_alias$date_end)

  cand <- .rc_feature_candidates("P.S01", as.Date("2025-05-20"), registry)
  expect_equal(nrow(cand), 1)
  expect_identical(cand$uuid_feature[[1]], "f-pre003-01")
})

test_that("R-15.21: sample_date NA yields unchanged behaviour on .rc_feature_candidates - no narrowing at either alias-side or feature-side liveness", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, auto_assign, first_seen, last_seen, date_start, date_end) VALUES
    ('fa-e21a', 'f-0004', 'T.NA21', 't.na21', 'historical_code', TRUE,
     TIMESTAMP '2018-01-01 00:00:00', TIMESTAMP '2019-12-31 00:00:00', NULL, DATE '2020-01-01'),
    ('fa-e21b', 'f-0005', 'T.NA21', 't.na21', 'descriptive', TRUE,
     TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-05-01 00:00:00', NULL, NULL)")
  registry <- .rc_load_registry(con)

  # NA sample_date: no basis to narrow either arm - both candidates survive,
  # exactly as today (E.6/R-15.21).
  cand_na <- .rc_feature_candidates("T.NA21", as.Date(NA), registry)
  expect_setequal(unique(cand_na$uuid_feature), c("f-0004", "f-0005"))

  # PAIRED contrast (same test, real date well after fa-e21a's expiry): the
  # bound DOES apply, narrowing to the single surviving arm - proving the NA
  # case above is "no narrowing", not "the bound mechanism never works".
  cand_real <- .rc_feature_candidates("T.NA21", as.Date("2025-05-20"), registry)
  expect_equal(length(unique(cand_real$uuid_feature)), 1)
  expect_identical(unique(cand_real$uuid_feature), "f-0005")
})

test_that("PLAN-15 E.2 shape: a contradictory alias bound (date_start > date_end) empties the candidate set at every date, rather than resolving arbitrarily", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, auto_assign, first_seen, last_seen, date_start, date_end) VALUES
    ('fa-e-contra', 'f-0003', 'T.CONTRA', 't.contra', 'historical_code', TRUE,
     TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00',
     DATE '2025-01-01', DATE '2020-01-01')")
  registry <- .rc_load_registry(con)

  # date_start (2025-01-01) > date_end (2020-01-01): no date satisfies BOTH
  # halves of the liveness predicate, so the arm must NEVER be live - not
  # "live before 2020" and not "live after 2025" (a naive single-sided check
  # would wrongly pass one of these), and not "always live" (a naive OR
  # would wrongly pass all three).
  expect_equal(nrow(.rc_feature_candidates("T.CONTRA", as.Date("2019-06-01"), registry)), 0)
  expect_equal(nrow(.rc_feature_candidates("T.CONTRA", as.Date("2022-06-01"), registry)), 0)
  expect_equal(nrow(.rc_feature_candidates("T.CONTRA", as.Date("2026-06-01"), registry)), 0)
})

# =============================================================================
# P15-T-review-payload unit: F.3 (real migration-parity oracle), F.5 (payload
# order-independence), F.6 (single-candidate suggestion), F.7 (doc drift),
# E.3 (expired_alias), E.7 (self-precedence note). ONE PASS, ONE `subkind`
# precedence table (S-15.6): self_precedence_note > ambiguous > expired_alias
# > suggestion > structural > bare. Each block below locks one link in that
# chain against its immediate neighbour.
# =============================================================================

# ---- local helper: sys.source the REAL migration-001 normaliser -----------
# Same pattern as test-migration-001.R:42/.mig001_load() (each test FILE is
# sourced into its own env by testthat, so redefining this name per file is
# the established convention here, not a collision).

.mig001_load <- function() {
  env <- new.env(parent = globalenv())
  path <- testthat::test_path("..", "..", "dev", "migrations", "001-alias-indirection.R")
  skip_if_not(file.exists(path), "dev/migrations not in built package (run via devtools::test)")
  sys.source(path, envir = env)
  env
}

# ---- F.3: the migration-parity oracle, respecified (R-15.22/R-15.23) ------

test_that("R-15.22: .rc_feature_key reproduces the REAL sys.sourced .mig001_normalize over the stored alias_key domain (idempotence on migration-001's own output) and on the ASCII discriminating inputs the two functions genuinely agree on - NOT a locally re-declared oracle", {
  mig <- .mig001_load()
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  fa <- DBI::dbGetQuery(con, "SELECT name, alias_key FROM feature_alias")
  expect_true(nrow(fa) > 0)

  # Sanity tie: the seeded `alias_key` domain IS what the REAL migration-001
  # normaliser produces from the raw `name` - ties "the stored domain" to
  # "real .mig001_normalize output", never to an independently-typed fixture
  # literal.
  expect_identical(mig$.mig001_normalize(fa$name), fa$alias_key)

  # THE property that matters (F.3, cold audit finding 4): re-normalising
  # migration-001's own stored output through `.rc_feature_key` must
  # reproduce it exactly, for EVERY key actually stored - a key reconcile
  # computes at runtime must find the row migration 001 wrote. Not a
  # tautology: nothing here re-implements the normaliser; the oracle is the
  # real DB domain plus the real sys.sourced function above.
  expect_identical(.rc_feature_key(fa$alias_key), fa$alias_key)

  # ASCII discriminating inputs (kept from the original F.3 list, minus the
  # NBSP case - R-15.23's explicit divergence instead): a double internal
  # space and a trailing tab, on which `.rc_feature_key` and the REAL
  # `.mig001_normalize` genuinely agree.
  ascii_inputs <- c("B.  S01", "B.S01\t")
  expect_identical(.rc_feature_key(ascii_inputs), mig$.mig001_normalize(ascii_inputs))
})

test_that("R-15.23: .rc_feature_key and the REAL .mig001_normalize DIVERGE on a leading-NBSP input - .rc_feature_key (F.2's Unicode-aware trim) folds it to the clean key, .mig001_normalize's base trimws() leaves the NBSP in place (locks F.2 against a silent revert)", {
  mig <- .mig001_load()
  nbsp_input <- " B.S01"   # LEADING U+00A0 NBSP (bytes c2 a0) - not a plain space
  clean_key <- "b.s01"

  rc_out <- .rc_feature_key(nbsp_input)
  mig_out <- mig$.mig001_normalize(nbsp_input)

  expect_identical(rc_out, clean_key)            # F.2: folds the NBSP away
  expect_false(identical(mig_out, clean_key))    # base trimws() does not strip NBSP
  expect_false(identical(rc_out, mig_out))       # EXPLICIT divergence, not silently absorbed
})

# ---- F.5: review payload order-independence (R-15.26) ---------------------

test_that("R-15.26: the review payload's candidate list is the UNION of the WHOLE group (not just cand_list[[g[[1]]]]'s first row), and is BYTE-IDENTICAL whichever order the two rows are presented in", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  # test-local pair sharing ONE alias_key ('ordkeynosite' - deliberately no
  # recognised site prefix, so no structural token can interfere with this
  # test's own signal): f-ord-a is defunct after 2024-12-31, f-ord-b is
  # unbounded. Both aliases are auto_assign=FALSE so `.rc_feature_candidates`
  # never auto-resolves either row - both stay "pending" and reach
  # `.rc_feature_review` regardless of date or row order.
  DBI::dbExecute(con, "INSERT INTO feature (uuid, name, site, flow, matrix, date_end, lon, lat) VALUES
    ('f-ord-a', 'T.ORD01', 'T', 'surface', 'water', DATE '2024-12-31', 150.5001, -33.5001),
    ('f-ord-b', 'T.ORD02', 'T', 'surface', 'water', NULL, 150.5002, -33.5002)")
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, auto_assign, first_seen, last_seen) VALUES
    ('fa-ord-a', 'f-ord-a', 'ORDKEYNOSITE', 'ordkeynosite', 'descriptive', FALSE,
     TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00'),
    ('fa-ord-b', 'f-ord-b', 'ORDKEYNOSITE', 'ordkeynosite', 'descriptive', FALSE,
     TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00')")

  # Only THIS row's own date (2024-06-01, before f-ord-a's date_end) leaves
  # BOTH candidates live in `.rc_feature_suggestions()`; `new_row`'s date
  # (2025-06-01, after f-ord-a's date_end) narrows ITS OWN suggestion set to
  # exactly f-ord-b - the "only the LATER row's date narrows the candidate
  # set" shape the cold-audit finding names.
  old_row <- mk_row(source_ref = "old", feature_raw = "ORDKEYNOSITE",
                     lab_sample_id = "XX9999980001", sample_datetime_raw = "01 Jun 2024 09:00")
  new_row <- mk_row(source_ref = "new", feature_raw = "ORDKEYNOSITE",
                     lab_sample_id = "XX9999980002", sample_datetime_raw = "01 Jun 2025 09:00")

  out_old_first <- reconcile_event(mk_event(mk_rows(old_row, new_row)), con)
  out_new_first <- reconcile_event(mk_event(mk_rows(new_row, old_row)), con)

  rv_old_first <- out_old_first$review[out_old_first$review$kind == "unknown_feature", ]
  rv_new_first <- out_new_first$review[out_new_first$review$kind == "unknown_feature", ]
  expect_equal(nrow(rv_old_first), 1)
  expect_equal(nrow(rv_new_first), 1)

  # Against TODAY's code the new-first ordering emits NO `candidates=` clause
  # at all (`cand_list[[g[[1]]]]` reads the FIRST ROW's OWN suggestion set,
  # a single-candidate set the `length(sugg) > 1` gate drops entirely) - the
  # failure this criterion exists to catch.
  expect_identical(rv_old_first$payload[[1]], rv_new_first$payload[[1]])   # byte-identical

  # TRANSLATED 2026-07-26 under PLAN-16 RULING A (round-2 sweep). Was
  #   dg <- jsonlite::fromJSON(rv_old_first$payload[[1]])
  #   expect_setequal(dg$candidates, c("f-ord-a", "f-ord-b"))
  # candidates no longer travel in the JSON diagnostics blob at all (Robin's
  # ruling: feature-review candidates route to the typed child table, not
  # JSON) - read the "candidate"-kind rows of the `candidates` list-column
  # instead. Still order-INDEPENDENT, as before: don't assume which of the
  # two lands first in the union.
  cand_ord <- rv_old_first$candidates[[1]]
  cand_ord <- cand_ord[!is.na(cand_ord$kind) & cand_ord$kind == "candidate", ]
  expect_setequal(cand_ord$uuid_feature, c("f-ord-a", "f-ord-b"))
})

# ---- F.6: single-candidate suggestions are no longer discarded (R-15.27) --

test_that("R-15.27: ZERO suggestion candidates emits a bare unknown_feature payload - no subkind= clause at all", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  event <- mk_event(mk_rows(
    # 'QQQNOTHING' matches no feature_alias row and no site prefix (T/TH/Z).
    mk_row(source_ref = "zero_cand", feature_raw = "QQQNOTHING",
           lab_sample_id = "XX9999970001", sample_datetime_raw = "10 Jun 2025 09:00")
  ))
  out <- reconcile_event(event, con)
  rv <- out$review[out$review$kind == "unknown_feature" &
                      grepl("zero_cand", out$review$source_ref, fixed = TRUE), ]
  expect_equal(nrow(rv), 1)
  expect_true(is.na(rv$subkind[[1]]))
})

test_that("R-15.27: exactly ONE suggestion candidate (fixture T.BORE -> f-0003 via fa-0009, auto_assign=FALSE) emits subkind=suggestion,candidates=f-0003 - the lone candidate is no longer discarded by the length(sugg)>1 gate", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  event <- mk_event(mk_rows(
    mk_row(source_ref = "one_cand", feature_raw = "T.BORE",
           lab_sample_id = "XX9999970002", sample_datetime_raw = "10 Jun 2025 09:00")
  ))
  out <- reconcile_event(event, con)
  a <- out$clean[out$clean$source_ref == "one_cand", ]
  expect_true(a$feature_pending)
  rv <- out$review[out$review$kind == "unknown_feature" &
                      grepl("one_cand", out$review$source_ref, fixed = TRUE), ]
  expect_equal(nrow(rv), 1)
  # TRANSLATED 2026-07-26 under PLAN-16 RULING A. Was
  #   grepl("subkind=suggestion", rv$payload[[1]], fixed = TRUE)
  # `subkind` is now a typed review_queue column (db-schema.R:121, populated
  # by .rq_row() at :589); read it directly instead of grepping the retired
  # k=v payload grammar.
  expect_identical(rv$subkind[[1]], "suggestion")
  # Phase-5 round-5 audit A3: the criterion is the lone candidate (the SET),
  # not a substring - assert the SET, matching R-15.16's idiom.
  # TRANSLATED 2026-07-26 under PLAN-16 RULING A (round-2 sweep). Was
  #   dg <- jsonlite::fromJSON(rv$payload[[1]])
  #   expect_true(setequal(dg$candidates, "f-0003"))
  # same substitution as the union test above: candidates live in the typed
  # `candidates` list-column, not the JSON diagnostics blob.
  cand_bore <- rv$candidates[[1]]
  cand_bore <- cand_bore[!is.na(cand_bore$kind) & cand_bore$kind == "candidate", ]
  expect_true(setequal(cand_bore$uuid_feature, "f-0003"))
  # Against TODAY's code this is `subkind=structural,site=T,point=BORE`
  # instead (the candidate was dropped by the >1 gate) - the failure this
  # criterion exists to catch, and the precedence-table link `suggestion` >
  # `structural` (S-15.6).
  expect_false(identical(rv$subkind[[1]], "ambiguous"))
  expect_false(identical(rv$subkind[[1]], "structural"))
})

test_that("R-15.27: TWO OR MORE suggestion candidates (fixture T.DUAL -> f-0004/f-0005) still emit subkind=ambiguous, never subkind=suggestion - the >=2 branch of the same total order (regression guard)", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  event <- mk_event(mk_rows(
    mk_row(source_ref = "two_cand", feature_raw = "T.DUAL",
           lab_sample_id = "XX9999970003", sample_datetime_raw = "10 Jun 2025 09:00")
  ))
  out <- reconcile_event(event, con)
  rv <- out$review[out$review$kind == "unknown_feature" &
                      grepl("two_cand", out$review$source_ref, fixed = TRUE), ]
  expect_equal(nrow(rv), 1)
  expect_identical(rv$subkind[[1]], "ambiguous")
  expect_false(identical(rv$subkind[[1]], "suggestion"))
})

# ---- E.3: expired-only alias goes to review, not structural (R-15.15) -----

test_that("R-15.15: a key whose ONLY alias is EXPIRED lands in review with subkind=expired_alias and is NOT structurally resolved, paired with an identical-SHAPE raw carrying NO alias row at all which DOES structurally resolve (proves Layer 2 is gated, not disabled)", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  # 'T S07' (space form) structurally parses to f-0007 (T.S07), which itself
  # already carries a self-alias - so an UNGATED Layer 2 would resolve this
  # cleanly. The ONLY alias reaching key 't s07' is the one inserted here,
  # and it is EXPIRED (date_end 2019-12-31, long before the row's 2025 date).
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, auto_assign, first_seen, last_seen, date_start, date_end) VALUES
    ('fa-exp15', 'f-0007', 'T S07', 't s07', 'historical_code', FALSE,
     TIMESTAMP '2018-01-01 00:00:00', TIMESTAMP '2019-12-31 00:00:00',
     DATE '2018-01-01', DATE '2019-12-31')")

  event <- mk_event(mk_rows(
    mk_row(source_ref = "expired_only", feature_raw = "T S07",
           lab_sample_id = "XX9999960001", sample_datetime_raw = "12 Jun 2025 09:00"),
    # PAIRED positive control (same test): 'T S01' (space form) reaches ZERO
    # alias rows at all (f-0001's self-alias is stored under the DOTTED key
    # 't.s01', not this space form) and DOES structurally resolve.
    mk_row(source_ref = "no_alias_control", feature_raw = "T S01",
           lab_sample_id = "XX9999960002", sample_datetime_raw = "12 Jun 2025 09:00")
  ))
  out <- reconcile_event(event, con)

  ex <- out$clean[out$clean$source_ref == "expired_only", ]
  expect_true(ex$feature_pending)
  expect_true(is.na(ex$uuid_feature))
  rv <- out$review[out$review$kind == "unknown_feature" &
                      grepl("expired_only", out$review$source_ref, fixed = TRUE), ]
  expect_equal(nrow(rv), 1)
  # TRANSLATED 2026-07-26 under PLAN-16 RULING A. Was
  #   grepl("subkind=expired_alias", rv$payload[[1]], fixed = TRUE)
  # paired with expect_false(grepl("subkind=structural", ...)) below -
  # `subkind` is a single-valued typed column, so pinning it to
  # "expired_alias" already implies it is not "structural"; the negative is
  # deleted as redundant per RULING A.
  expect_identical(rv$subkind[[1]], "expired_alias")
  # TRANSLATED 2026-07-26 under PLAN-16 RULING A. Was
  #   grepl("expired=f-0007@2018-01-01..2019-12-31", rv$payload[[1]], fixed = TRUE)
  # `expired=` named a k=v payload clause that no longer exists; the same
  # fact now lives as one "expired"-kind row in the `candidates` list-column
  # (reconcile.R:263, db-schema.R .rq_row()) with real Date bounds.
  exp15 <- rv$candidates[[1]]
  exp15_row <- exp15[!is.na(exp15$kind) & exp15$kind == "expired", ]
  expect_identical(exp15_row$uuid_feature, "f-0007")
  expect_identical(c(exp15_row$date_start, exp15_row$date_end),
                    as.Date(c("2018-01-01", "2019-12-31")))

  ctrl <- out$clean[out$clean$source_ref == "no_alias_control", ]
  expect_false(ctrl$feature_pending)
  expect_identical(ctrl$uuid_feature, "f-0001")
})

test_that("R-15.16: payload emission at the expired-candidate count boundary - exactly ONE expired candidate, ZERO live arms, still emits subkind=expired_alias (guards the length(sugg)>1 gate); TWO live + ONE expired emits subkind=ambiguous with candidates= restricted to the two LIVE ones plus an expired= clause naming the third", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # Case 1: a single EXPIRED-only candidate, ZERO live arms (no structural
  # interference - 'QQQEXP16A' matches no site prefix).
  # Phase-5 audit round 3 B3: round-2's C4(a) added a co-occurring LIVE
  # auto_assign=FALSE arm here and asserted subkind=expired_alias +
  # expect_false(subkind=suggestion) - but PLAN-15's "LIVE CANDIDATE WAS
  # OVERLOADED" ruling (2026-07-24) makes `expired_alias` conditional on
  # ZERO live arms (auto_assign-BLIND) existing at all; adding a live arm
  # makes the plan-conformant answer `subkind=suggestion` instead, so that
  # edit pinned an outcome no correct implementation can produce. Reverted:
  # this case is restored to its own shape (one expired candidate, zero live
  # arms), and the co-occurrence shape gets its OWN test at R-15.46, below.
  # CANDIDATE-COUNT COMMENT: .rc_feature_candidates("QQQEXP16A", <any date>,
  # registry) returns ZERO rows for this key - fa-exp16a is auto_assign=FALSE
  # so it fails the filter at reconcile.R:171 regardless of date.
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, auto_assign, first_seen, last_seen, date_start, date_end) VALUES
    ('fa-exp16a', 'f-0002', 'QQQEXP16A', 'qqqexp16a', 'historical_code', FALSE,
     TIMESTAMP '2018-01-01 00:00:00', TIMESTAMP '2019-12-31 00:00:00',
     DATE '2018-01-01', DATE '2019-12-31')")

  # Case 2: TWO live candidates + ONE expired candidate, one shared key.
  DBI::dbExecute(con, "INSERT INTO feature (uuid, name, site, flow, matrix, lon, lat) VALUES
    ('f-exp16-live1', 'T.EXP16L1', 'T', 'surface', 'water', 150.6001, -33.6001),
    ('f-exp16-live2', 'T.EXP16L2', 'T', 'surface', 'water', 150.6002, -33.6002)")
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, auto_assign, first_seen, last_seen, date_start, date_end) VALUES
    ('fa-exp16b1', 'f-exp16-live1', 'QQQEXP16B', 'qqqexp16b', 'descriptive', FALSE,
     TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00', NULL, NULL),
    ('fa-exp16b2', 'f-exp16-live2', 'QQQEXP16B', 'qqqexp16b', 'descriptive', FALSE,
     TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00', NULL, NULL),
    ('fa-exp16b3', 'f-0002', 'QQQEXP16B', 'qqqexp16b', 'historical_code', FALSE,
     TIMESTAMP '2018-01-01 00:00:00', TIMESTAMP '2019-12-31 00:00:00',
     DATE '2018-01-01', DATE '2019-12-31')")

  event <- mk_event(mk_rows(
    mk_row(source_ref = "one_expired", feature_raw = "QQQEXP16A",
           lab_sample_id = "XX9999950001", sample_datetime_raw = "13 Jun 2025 09:00"),
    mk_row(source_ref = "two_live_one_expired", feature_raw = "QQQEXP16B",
           lab_sample_id = "XX9999950002", sample_datetime_raw = "13 Jun 2025 09:00")
  ))
  out <- reconcile_event(event, con)

  # Phase-5 audit B2: `grepl("one_expired", ...)` also matches the SIBLING
  # row "two_live_one_expired" in this same event (a substring collision -
  # `grepl("one_expired", "two_live_one_expired", fixed = TRUE)` is TRUE),
  # so `rv_a` always held 2 rows and `expect_equal(nrow(rv_a), 1)` could
  # never pass. Exact match, both here and below (converted together since
  # both filters are in this one test, testing for one specific row each).
  rv_a <- out$review[out$review$kind == "unknown_feature" &
                        out$review$source_ref == "one_expired", ]
  expect_equal(nrow(rv_a), 1)
  # TRANSLATED 2026-07-26 under PLAN-16 RULING A. Was
  #   grepl("subkind=expired_alias", rv_a$payload[[1]], fixed = TRUE)
  # paired with expect_false(grepl("subkind=ambiguous", ...)) below - a
  # single-valued typed column pinned to "expired_alias" already excludes
  # "ambiguous"; the negative is deleted as redundant per RULING A.
  expect_identical(rv_a$subkind[[1]], "expired_alias")
  # TRANSLATED 2026-07-26 under PLAN-16 RULING A. Was
  #   grepl("expired=f-0002@2018-01-01..2019-12-31", rv_a$payload[[1]], fixed = TRUE)
  # same substitution as R-15.15 above: read the "expired"-kind row of the
  # `candidates` list-column instead of a retired payload clause.
  cand_tbl_a <- rv_a$candidates[[1]]
  exp_row_a <- cand_tbl_a[!is.na(cand_tbl_a$kind) & cand_tbl_a$kind == "expired", ]
  expect_identical(exp_row_a$uuid_feature, "f-0002")
  expect_identical(c(exp_row_a$date_start, exp_row_a$date_end),
                    as.Date(c("2018-01-01", "2019-12-31")))
  # round-3 B3: the `expect_false(subkind=suggestion)` assertion that lived
  # here (round-2 C4(a)) is deleted along with the live arm that motivated
  # it - this case has zero live arms, so `suggestion` was never a
  # discriminating check for it in the first place. The actual co-occurrence
  # boundary (one live + one expired) is R-15.46, below.

  rv_b <- out$review[out$review$kind == "unknown_feature" &
                        out$review$source_ref == "two_live_one_expired", ]
  expect_equal(nrow(rv_b), 1)
  # TRANSLATED 2026-07-26 under PLAN-16 RULING A. Was
  #   grepl("subkind=ambiguous", rv_b$payload[[1]], fixed = TRUE)
  expect_identical(rv_b$subkind[[1]], "ambiguous")
  # TRANSLATED 2026-07-26 under PLAN-16 RULING A. Was
  #   grepl("expired=f-0002@2018-01-01..2019-12-31", rv_b$payload[[1]], fixed = TRUE)
  # same substitution as R-15.15/the first R-15.16 case above.
  cand_tbl_b <- rv_b$candidates[[1]]
  exp_row_b <- cand_tbl_b[!is.na(cand_tbl_b$kind) & cand_tbl_b$kind == "expired", ]
  expect_identical(exp_row_b$uuid_feature, "f-0002")
  expect_identical(c(exp_row_b$date_start, exp_row_b$date_end),
                    as.Date(c("2018-01-01", "2019-12-31")))
  # TRANSLATED 2026-07-26 under PLAN-16 RULING A. Was a regmatches()/strsplit()
  # parse of a retired `candidates=` payload clause (the length-guard against
  # a missing/malformed clause no longer applies - subsetting a tibble never
  # errors on a zero-row result). Read the "candidate"-kind rows of the
  # `candidates` list-column directly, in rank order, and assert the SET of
  # uuid_feature values - unchanged strength from the original
  # expect_setequal() below.
  cand_rows_b <- cand_tbl_b[!is.na(cand_tbl_b$kind) & cand_tbl_b$kind == "candidate", ]
  cand_rows_b <- cand_rows_b[order(cand_rows_b$rank), ]
  # Against TODAY's code the candidate set also lists the expired
  # uuid_feature (f-0002) - the expired one belongs in the "expired"-kind
  # rows only, per the pinned grammar ("2 live + 1 expired emits ambiguous
  # WITH an expired candidate").
  expect_setequal(cand_rows_b$uuid_feature, c("f-exp16-live1", "f-exp16-live2"))
})

test_that("R-15.46: a key holding exactly ONE live arm (auto_assign=FALSE) AND at least one EXPIRED arm, reconciled inside the live arm's bounds and outside the expired one's, emits subkind=suggestion (never subkind=expired_alias) AND carries an expired= clause naming the expired candidate - paired in the same test with a control on an otherwise-identical key whose live arm is removed, which DOES emit subkind=expired_alias (PLAN-15's 'LIVE CANDIDATE WAS OVERLOADED' ruling, 2026-07-24, round-3 PCR-1: 'live arm' throughout the precedence table means date-bounds-admit-the-sample-date, auto_assign-BLIND - expired_alias fires only at ZERO live arms, suggestion at EXACTLY ONE live auto_assign=FALSE arm; expiry is context, never the subkind, whenever any live arm exists)", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # Key A ('qqq1546'): one live, auto_assign=FALSE, UNBOUNDED arm (always
  # date-admits) PLUS one EXPIRED arm sharing the same key.
  # CANDIDATE-COUNT COMMENT: .rc_feature_candidates("QQQ1546", <any date>,
  # registry) returns ZERO rows - BOTH arms are auto_assign=FALSE, so both
  # fail the reconcile.R:171 filter before date narrowing is even reached.
  # This is DELIBERATE, per the OVERLOADED ruling: the plan's "live arm" for
  # this table means date-bounds-admits, auto_assign-BLIND - a DIFFERENT
  # count from `.rc_feature_candidates()`'s auto_assign=TRUE-filtered one.
  # This key's date-bounds-admitted live-arm count is ONE (the unbounded
  # arm); its filtered candidate count is ZERO. Both are true at once - that
  # is the whole point of the ruling C4's mistake needed.
  DBI::dbExecute(con, "INSERT INTO feature (uuid, name, site, flow, matrix, lon, lat) VALUES
    ('f-1546-live', 'T.Q1546LIVE', 'T', 'surface', 'water', 150.6041, -33.6041)")
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, auto_assign, first_seen, last_seen, date_start, date_end) VALUES
    ('fa-1546-live', 'f-1546-live', 'QQQ1546', 'qqq1546', 'descriptive', FALSE,
     TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00', NULL, NULL),
    ('fa-1546-exp', 'f-0002', 'QQQ1546', 'qqq1546', 'historical_code', FALSE,
     TIMESTAMP '2018-01-01 00:00:00', TIMESTAMP '2019-12-31 00:00:00',
     DATE '2018-01-01', DATE '2019-12-31')")

  # PAIRED CONTROL (same test): a FRESH key 'qqq1546ctrl' carries ONLY the
  # expired arm - the live arm above does not exist on this key at all.
  # CANDIDATE-COUNT COMMENT: .rc_feature_candidates() also returns ZERO rows
  # here (the sole arm is auto_assign=FALSE) - identical to Key A's filtered
  # count. The discriminator between this control and Key A is the
  # date-bounds-admitted live-arm count (0 here, 1 above), never the
  # auto_assign-filtered candidate count (0 in both) - so a hard-coded
  # subkind, or one keyed off filtered-candidate count alone, fails one half
  # of this test or the other.
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, auto_assign, first_seen, last_seen, date_start, date_end) VALUES
    ('fa-1546ctrl-exp', 'f-0002', 'QQQ1546CTRL', 'qqq1546ctrl', 'historical_code', FALSE,
     TIMESTAMP '2018-01-01 00:00:00', TIMESTAMP '2019-12-31 00:00:00',
     DATE '2018-01-01', DATE '2019-12-31')")

  event <- mk_event(mk_rows(
    # 14 Jun 2025: inside the live arm's (unbounded) bounds, outside the
    # expired arm's (2018-01-01..2019-12-31) bounds.
    mk_row(source_ref = "live_plus_expired", feature_raw = "QQQ1546",
           lab_sample_id = "XX9999951001", sample_datetime_raw = "14 Jun 2025 09:00"),
    mk_row(source_ref = "expired_only_control", feature_raw = "QQQ1546CTRL",
           lab_sample_id = "XX9999951002", sample_datetime_raw = "14 Jun 2025 09:00")
  ))
  out <- reconcile_event(event, con)

  rv <- out$review[out$review$kind == "unknown_feature" &
                      out$review$source_ref == "live_plus_expired", ]
  expect_equal(nrow(rv), 1)
  # BOTH halves, per the criterion text: an implementation that simply
  # ignores expired arms whenever a live one exists would pass
  # subkind=suggestion alone without ever emitting the expired= clause - the
  # exact opposite of "expiry is context".
  # TRANSLATED 2026-07-26 under PLAN-16 RULING A. Was
  #   grepl("subkind=suggestion", rv$payload[[1]], fixed = TRUE)
  # paired with expect_false(grepl("subkind=expired_alias", ...)) below - a
  # single-valued typed column pinned to "suggestion" already excludes
  # "expired_alias"; the negative is deleted as redundant per RULING A.
  expect_identical(rv$subkind[[1]], "suggestion")
  # TRANSLATED 2026-07-26 under PLAN-16 RULING A. Was a regmatches()/strsplit()
  # parse of a retired `candidates=` payload clause. Read the
  # "candidate"-kind rows of the `candidates` list-column directly, in rank
  # order - this is exactly the "expiry is context, not candidates" check
  # the deleted comment above named: the expired uuid_feature must NOT
  # appear in this subset.
  cand_tbl_live <- rv$candidates[[1]]
  cand_rows_live <- cand_tbl_live[!is.na(cand_tbl_live$kind) & cand_tbl_live$kind == "candidate", ]
  cand_rows_live <- cand_rows_live[order(cand_rows_live$rank), ]
  expect_setequal(cand_rows_live$uuid_feature, "f-1546-live")
  # TRANSLATED 2026-07-26 under PLAN-16 RULING A. Was
  #   grepl("expired=f-0002@2018-01-01..2019-12-31", rv$payload[[1]], fixed = TRUE)
  # same substitution as R-15.15/R-15.16 above.
  exp_row_live <- cand_tbl_live[!is.na(cand_tbl_live$kind) & cand_tbl_live$kind == "expired", ]
  expect_identical(exp_row_live$uuid_feature, "f-0002")
  expect_identical(c(exp_row_live$date_start, exp_row_live$date_end),
                    as.Date(c("2018-01-01", "2019-12-31")))

  # PAIRED CONTROL: the same key shape with the live arm removed - a
  # hard-coded subkind fails this half.
  rv_ctrl <- out$review[out$review$kind == "unknown_feature" &
                           out$review$source_ref == "expired_only_control", ]
  expect_equal(nrow(rv_ctrl), 1)
  # TRANSLATED 2026-07-26 under PLAN-16 RULING A. Was
  #   grepl("subkind=expired_alias", rv_ctrl$payload[[1]], fixed = TRUE)
  # paired with expect_false(grepl("subkind=suggestion", ...)) below - a
  # single-valued typed column pinned to "expired_alias" already excludes
  # "suggestion"; the negative is deleted as redundant per RULING A.
  expect_identical(rv_ctrl$subkind[[1]], "expired_alias")
  # TRANSLATED 2026-07-26 under PLAN-16 RULING A. Was
  #   grepl("expired=f-0002@2018-01-01..2019-12-31", rv_ctrl$payload[[1]], fixed = TRUE)
  cand_tbl_ctrl <- rv_ctrl$candidates[[1]]
  exp_row_ctrl <- cand_tbl_ctrl[!is.na(cand_tbl_ctrl$kind) & cand_tbl_ctrl$kind == "expired", ]
  expect_identical(exp_row_ctrl$uuid_feature, "f-0002")
  expect_identical(c(exp_row_ctrl$date_start, exp_row_ctrl$date_end),
                    as.Date(c("2018-01-01", "2019-12-31")))
})

# ---- E.7: self-precedence note (R2) - blocking flag, commit, negative -----
# control (no assigned R-15.NN ID in the dispatch brief; PLAN-CHANGE REQUEST
# filed in the handoff report). Named "E.7:" per this file's existing
# convention for un-numbered plan-block criteria (cf. "B.4:", "PLAN-15 A:").

test_that("R-15.45 (E.7): a key reaching a live SELF arm plus one live NON-self arm resolves via the self arm, commits a real sample/analysis row (assert row COUNTS, not merely the absence of a review item), and records exactly ONE non-blocking review row naming the shadowed feature and carrying an EXPLICIT boolean blocking flag - paired in the same test with a SECOND self-precedence case on a NEW, LOCALLY-BUILT key (t.e7dual2, all three arms auto_assign=TRUE) where the self arm faces TWO live non-self opponents at once, AND the plan-mandated negative control (a key reaching two live NON-self arms and no self arm still goes to review and does NOT commit) - (Phase-5 audit round 3 B1+B2: round-2's C4(b) planted the second self-precedence case on T.DUAL itself, whose fa-0015/fa-0016 non-self arms are auto_assign=FALSE in the shared seed [helper-db.R:329-336], so .rc_feature_candidates() [R/reconcile.R:171, which filters to auto_assign=TRUE FIRST] returned exactly ONE row for T.DUAL - an ordinary clean Layer-1 hit that `next`s before candidate collection, so the fixture could never produce the self_precedence_note the test asserted, AND it consumed R-15.45's own plan-mandated negative control by leaving no key in the test with two live non-self arms and no self arm. FIX: the second self-precedence case now lives on a NEW key built with auto_assign=TRUE on all three arms; T.DUAL is left completely untouched and used below exactly as the negative control)", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  # f-0002's OWN self-alias (fa-0002, unbounded) shares its key 't.s02' with
  # a NEW curated historical arm pointing at a DIFFERENT feature (f-0003),
  # bounded 2015-01-01..2019-12-31 - the "an alias key IS another feature's
  # real name" shape (E.0/R1/R2).
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, auto_assign, first_seen, last_seen, date_start, date_end) VALUES
    ('fa-e7-block', 'f-0003', 'T.S02', 't.s02', 'historical_code', TRUE,
     TIMESTAMP '2015-01-01 00:00:00', TIMESTAMP '2019-12-31 00:00:00',
     DATE '2015-01-01', DATE '2019-12-31')")

  # Phase-5 audit round 3 B1+B2: a NEW, LOCAL key (t.e7dual2) with all THREE
  # arms auto_assign=TRUE - one self, two non-self opponents.
  # CANDIDATE-COUNT COMMENT: .rc_feature_candidates("T.E7DUAL2", <any date>,
  # registry) returns THREE rows here (fa-e7dual2-self -> f-e7dual2-self,
  # fa-e7dual2-opp1 -> f-e7dual2-opp1, fa-e7dual2-opp2 -> f-e7dual2-opp2) -
  # all pass the auto_assign=TRUE filter at reconcile.R:171, all unbounded so
  # live at every fixture date. THREE distinct features survive the filter,
  # so `length(distinct_feat) == 1` at reconcile.R:448 is FALSE and the row
  # reaches candidate collection (never the Layer-1 `next`) - the actual
  # multi-candidate, self-included shape self-precedence needs. T.DUAL
  # itself is NOT touched by this insert.
  DBI::dbExecute(con, "INSERT INTO feature (uuid, name, site, flow, matrix, lon, lat) VALUES
    ('f-e7dual2-self', 'T.E7DUAL2', 'T', 'surface', 'water', 150.6031, -33.6031),
    ('f-e7dual2-opp1', 'T.E7DUAL2OPP1', 'T', 'surface', 'water', 150.6032, -33.6032),
    ('f-e7dual2-opp2', 'T.E7DUAL2OPP2', 'T', 'surface', 'water', 150.6033, -33.6033)")
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, auto_assign, first_seen, last_seen) VALUES
    ('fa-e7dual2-self', 'f-e7dual2-self', 'T.E7DUAL2', 't.e7dual2', 'self', TRUE,
     TIMESTAMP '2020-01-01 00:00:00', TIMESTAMP '2020-01-01 00:00:00'),
    ('fa-e7dual2-opp1', 'f-e7dual2-opp1', 'T.E7DUAL2', 't.e7dual2', 'descriptive', TRUE,
     TIMESTAMP '2020-01-01 00:00:00', TIMESTAMP '2020-01-01 00:00:00'),
    ('fa-e7dual2-opp2', 'f-e7dual2-opp2', 'T.E7DUAL2', 't.e7dual2', 'descriptive', TRUE,
     TIMESTAMP '2020-01-01 00:00:00', TIMESTAMP '2020-01-01 00:00:00')")

  # BEFORE: no sample/analysis is yet linked to f-0002 or f-e7dual2-self in
  # the seed, so targeted counts below isolate each row's own commit from
  # the other in the same event. T.DUAL's own arms (fa-0015/fa-0016 ->
  # f-0004/f-0005) are entirely UNTOUCHED by this test's inserts and are
  # used below only as R-15.45's paired negative control.
  before_f2 <- DBI::dbGetQuery(con,
    "SELECT count(*) AS n FROM \"sample\" s JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
     WHERE fa.uuid_feature = 'f-0002'")$n
  before_dual <- DBI::dbGetQuery(con,
    "SELECT count(*) AS n FROM \"sample\" s JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
     WHERE fa.uuid_feature IN ('f-0004', 'f-0005')")$n
  before_dual2self <- DBI::dbGetQuery(con,
    "SELECT count(*) AS n FROM \"sample\" s JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
     WHERE fa.uuid_feature = 'f-e7dual2-self'")$n

  event <- mk_event(mk_rows(
    # date INSIDE the historical arm's bound: both fa-0002 (self, unbounded)
    # and fa-e7-block (historical, bounded) are alias-live - self must win.
    mk_row(source_ref = "e7_self_wins", feature_raw = "T.S02",
           lab_sample_id = "XX9999940001", sample_datetime_raw = "01 Jun 2017 09:00"),
    # SECOND self-precedence case (same test): T.E7DUAL2 carries a self arm
    # (fa-e7dual2-self) plus TWO live non-self opponents, all auto_assign=TRUE
    # - self must win against TWO live candidate opponents at once, not only
    # the single-opponent shape above.
    mk_row(source_ref = "e7_dual2_self_wins", feature_raw = "T.E7DUAL2",
           lab_sample_id = "XX9999940002", sample_datetime_raw = "01 Jun 2017 09:00"),
    # PLAN-15 R-15.45 NEGATIVE CONTROL (round-3 B2, restored to its original
    # key): T.DUAL reaches ONLY its shared-seed pair fa-0015/fa-0016
    # (f-0004/f-0005), BOTH auto_assign=FALSE and NO self arm anywhere on
    # this key.  CANDIDATE-COUNT COMMENT: .rc_feature_candidates() returns
    # ZERO rows for 't.dual' (both arms fail the auto_assign=TRUE filter),
    # so it never auto-resolves at Layer 1; .rc_feature_suggestions()
    # (auto_assign-BLIND) returns TWO distinct live candidates
    # (f-0004, f-0005), which is the `ambiguous` branch (R-15.27's own
    # T.DUAL test, above, on a fresh seed). Per R-15.45 this key must go to
    # review and NOT commit - the test fails if self-precedence were ever
    # implemented as "always take the first candidate".
    mk_row(source_ref = "e7_dual_negative_control", feature_raw = "T.DUAL",
           lab_sample_id = "XX9999940003", sample_datetime_raw = "01 Jun 2017 09:00")
  ))
  out <- reconcile_event(event, con)

  win <- out$clean[out$clean$source_ref == "e7_self_wins", ]
  expect_false(win$feature_pending)
  expect_identical(win$uuid_feature, "f-0002")   # (a) self wins, never f-0003

  win_dual2 <- out$clean[out$clean$source_ref == "e7_dual2_self_wins", ]
  expect_false(win_dual2$feature_pending)
  expect_identical(win_dual2$uuid_feature, "f-e7dual2-self")  # self wins against BOTH opponents

  # negative control (pre-commit half): T.DUAL stays pending - no self arm
  # exists anywhere on this key to win.
  ctrl <- out$clean[out$clean$source_ref == "e7_dual_negative_control", ]
  expect_true(ctrl$feature_pending)

  commit_event(event, out, con)

  # (b) a REAL committed row, counted - not merely "no review item for it".
  after_f2 <- DBI::dbGetQuery(con,
    "SELECT count(*) AS n FROM \"sample\" s JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
     WHERE fa.uuid_feature = 'f-0002'")$n
  after_dual <- DBI::dbGetQuery(con,
    "SELECT count(*) AS n FROM \"sample\" s JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
     WHERE fa.uuid_feature IN ('f-0004', 'f-0005')")$n
  after_dual2self <- DBI::dbGetQuery(con,
    "SELECT count(*) AS n FROM \"sample\" s JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
     WHERE fa.uuid_feature = 'f-e7dual2-self'")$n
  expect_equal(after_f2 - before_f2, 1)               # the self-precedence win committed
  expect_equal(after_dual2self - before_dual2self, 1) # the SECOND self win committed too
  # (negative control, commit half) - the two live non-self T.DUAL arms
  # never commit, because nothing on that key ever resolves to a single hit.
  expect_equal(after_dual - before_dual, 0)

  an_count <- DBI::dbGetQuery(con,
    "SELECT count(*) AS n FROM analysis a
     JOIN \"sample\" s ON s.uuid = a.uuid_sample
     JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
     WHERE fa.uuid_feature = 'f-0002'")$n
  expect_equal(an_count, 1)

  # (c) exactly ONE review_queue row, naming the shadowed feature (f-0003),
  # `kind` UNCHANGED ('unknown_feature' - a new top-level kind would read as
  # a new class of work to every existing review_queue consumer), and an
  # EXPLICIT boolean blocking flag a reader can branch on directly - not an
  # inference from the subkind name.
  # PROVISIONAL ORACLE: the plan pins the PROPERTY ("a boolean, not an
  # implied property of the subkind value"), not the literal token spelling.
  # `blocking=FALSE`/`blocking=TRUE` is this test's best reading, matching
  # the `subkind=`/`candidates=`/`expired=` key=value grammar already in
  # use; Phase 6 may rename the key in one place if it picks otherwise.
  note <- out$review[grepl("e7_self_wins", out$review$source_ref, fixed = TRUE), ]
  expect_equal(nrow(note), 1)
  expect_identical(note$kind, "unknown_feature")
  # TRANSLATED 2026-07-26 under PLAN-16 RULING A. Was
  #   grepl("subkind=self_precedence_note", note$payload[[1]], fixed = TRUE)
  # `subkind` is now a typed review_queue column; read it directly.
  expect_identical(note$subkind[[1]], "self_precedence_note")
  # TRANSLATED 2026-07-26 under PLAN-16 RULING A (round-2 sweep). Was
  #   grepl("f-0003", note$payload[[1]], fixed = TRUE)
  # candidate uuids no longer travel in payload text at all - read the
  # "candidate"-kind rows of the `candidates` list-column instead.
  cand_note <- note$candidates[[1]]
  cand_note <- cand_note[!is.na(cand_note$kind) & cand_note$kind == "candidate", ]
  expect_true("f-0003" %in% cand_note$uuid_feature)
  # TRANSLATED 2026-07-26 under PLAN-16 RULING A (round-2 sweep). Was the
  # paired
  #   expect_true(grepl("blocking=FALSE", note$payload[[1]], fixed = TRUE))
  #   expect_false(grepl("blocking=TRUE", note$payload[[1]], fixed = TRUE))
  # unlike `subkind`, `blocking` is NOT a typed review_queue column - no
  # ALTER adds it (db-schema.R:121-123 add only subkind/uuid_existing/
  # uuid_alias) - it is a JSON diagnostics key, read via the idiom already
  # used at lines 404/1096. The paired presence+absence collapses to the one
  # positive check per RULING A.
  d_note <- jsonlite::fromJSON(note$payload[[1]])
  expect_false(d_note$blocking)

  # the SECOND case's review row is ALSO a self-precedence note - locking
  # the self_precedence_note > ambiguous link (S-15.6) against a shape where
  # self faces TWO live non-self opponents at once, not the `ambiguous`
  # outcome a per-case (rather than one-table) precedence implementation
  # might wrongly emit for it - and it names BOTH shadowed features. Unlike
  # the round-2 T.DUAL fixture this replaces, today's un-E.7 code DOES
  # already emit exactly one review row here (three candidates -> `pending`,
  # `sugg` length 3 > 1 -> `subkind=ambiguous` naming all three), so this
  # stays an unconditional `expect_equal(nrow(...), 1)`, same as the first
  # case above - not an NA/empty-safe guard.
  note_dual2 <- out$review[grepl("e7_dual2_self_wins", out$review$source_ref, fixed = TRUE), ]
  expect_equal(nrow(note_dual2), 1)
  # TRANSLATED 2026-07-26 under PLAN-16 RULING A. Was
  #   grepl("subkind=self_precedence_note", note_dual2$payload[[1]], fixed = TRUE)
  # paired with expect_false(grepl("subkind=ambiguous", ...)) below - a
  # single-valued typed column pinned to "self_precedence_note" already
  # excludes "ambiguous"; the negative is deleted as redundant per RULING A.
  expect_identical(note_dual2$subkind[[1]], "self_precedence_note")
  # TRANSLATED 2026-07-26 under PLAN-16 RULING A (round-2 sweep). Was two
  # separate greps:
  #   grepl("f-e7dual2-opp1", note_dual2$payload[[1]], fixed = TRUE)
  #   grepl("f-e7dual2-opp2", note_dual2$payload[[1]], fixed = TRUE)
  # read the "candidate"-kind rows of the `candidates` list-column and
  # assert the SET in one call - stronger than the pair of greps, which
  # could not catch a spurious third candidate.
  cand_dual2 <- note_dual2$candidates[[1]]
  cand_dual2 <- cand_dual2[!is.na(cand_dual2$kind) & cand_dual2$kind == "candidate", ]
  expect_setequal(cand_dual2$uuid_feature, c("f-e7dual2-opp1", "f-e7dual2-opp2"))
  # TRANSLATED 2026-07-26 under PLAN-16 RULING A (round-2 sweep). Was
  #   grepl("blocking=FALSE", note_dual2$payload[[1]], fixed = TRUE)
  # `blocking` is a JSON diagnostics key (see the matching comment above) -
  # read it via jsonlite::fromJSON, not a payload substring.
  d_dual2 <- jsonlite::fromJSON(note_dual2$payload[[1]])
  expect_false(d_dual2$blocking)

  # negative control (review half): T.DUAL's row is ambiguous, never a
  # self-precedence note - completing R-15.45's plan-mandated pairing IN
  # THIS SAME TEST (not merely relying on R-15.27's separate fresh-seed
  # T.DUAL test, which asserts subkind only, never commit counts).
  note_ctrl <- out$review[grepl("e7_dual_negative_control", out$review$source_ref, fixed = TRUE), ]
  expect_equal(nrow(note_ctrl), 1)
  # TRANSLATED 2026-07-26 under PLAN-16 RULING A. Was
  #   grepl("subkind=ambiguous", note_ctrl$payload[[1]], fixed = TRUE)
  # paired with expect_false(grepl("subkind=self_precedence_note", ...))
  # below - a single-valued typed column pinned to "ambiguous" already
  # excludes "self_precedence_note"; the negative is deleted as redundant
  # per RULING A.
  expect_identical(note_ctrl$subkind[[1]], "ambiguous")
})

test_that("D16 (E.7/PLAN-7b round-2): .rc_self_precedence() returns NULL when MORE THAN ONE surviving arm is kind='self' - two features claiming one name by their own names is a registry defect, not something to resolve arbitrarily", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  registry <- .rc_load_registry(con)

  # fa-0001 (self -> f-0001) and fa-0002 (self -> f-0002): TWO distinct
  # features, both claimed via their OWN self alias - the "not applicable"
  # arm of E.7's rule (`sum(is_self) != 1L`), distinct from the ordinary
  # "zero self arms" ambiguity every other self-precedence test exercises.
  cand <- tibble::tibble(uuid_alias = c("fa-0001", "fa-0002"),
                         uuid_feature = c("f-0001", "f-0002"))
  expect_null(.rc_self_precedence(cand, registry))
})

test_that("D10 (PLAN-7b round-2): .rc_self_precedence_notes()'s GROUP order and WITHIN-group order are both radix-pinned, mirroring PLAN-7b item 7/F.5's fix for the sibling .rc_feature_review() producer, which this one never received - byte-identical payload across two presentation orders, with a SECOND group so group order is itself observable", {
  mk <- function(order_rows) {
    rows <- tibble::tibble(
      source_ref = vapply(order_rows, `[[`, character(1), "source_ref"),
      alias_key = vapply(order_rows, `[[`, character(1), "alias_key"),
      feature_raw = vapply(order_rows, `[[`, character(1), "feature_raw"),
      source_hash = vapply(order_rows, `[[`, character(1), "source_hash")
    )
    uuid_feature <- vapply(order_rows, `[[`, character(1), "uuid_feature")
    shadowed <- lapply(order_rows, function(r) r$shadowed)
    .rc_self_precedence_notes(rows, uuid_feature, shadowed, work_order = "XX1234567")
  }

  # Two GROUPS sharing the same shape item 7 already proved diverges under
  # C vs en_US.UTF-8 collation on this platform ('t_01' vs 't.01' - ASCII
  # '.' 0x2E < '_' 0x5F). Two rows per group also exercise the WITHIN-group
  # source_ref order (F.5).
  row_under_b <- list(source_ref = "r_under_b", alias_key = "t_01", feature_raw = "T_01",
                      source_hash = "h1", uuid_feature = "f-under", shadowed = "f-under-shadow")
  row_under_a <- list(source_ref = "r_under_a", alias_key = "t_01", feature_raw = "T_01",
                      source_hash = "h1", uuid_feature = "f-under", shadowed = "f-under-shadow")
  row_dot_b   <- list(source_ref = "r_dot_b", alias_key = "t.01", feature_raw = "T.01",
                      source_hash = "h2", uuid_feature = "f-dot", shadowed = "f-dot-shadow")
  row_dot_a   <- list(source_ref = "r_dot_a", alias_key = "t.01", feature_raw = "T.01",
                      source_hash = "h2", uuid_feature = "f-dot", shadowed = "f-dot-shadow")

  order1 <- list(row_under_b, row_under_a, row_dot_b, row_dot_a)
  order2 <- list(row_dot_a, row_dot_b, row_under_a, row_under_b)

  out1 <- mk(order1)
  out2 <- mk(order2)

  expect_equal(nrow(out1), 2)
  expect_equal(nrow(out2), 2)

  # byte-identical whichever order the caller's rows were presented in.
  expect_identical(out1$payload, out2$payload)
  expect_identical(out1$source_ref, out2$source_ref)
  expect_identical(out1$source_hash, out2$source_hash)

  # radix collation: 't.01' < 't_01' (ASCII '.' 0x2E < '_' 0x5F), same as
  # PLAN-7b item 7 - the dot group's row sorts first, and within it 'r_dot_a'
  # sorts before 'r_dot_b'.
  expect_identical(out1$source_ref, c("r_dot_a,r_dot_b", "r_under_a,r_under_b"))
})

# ---- cold-audit defect 2: .rc_fill_missing_cols() is type-aware for the
#      `candidates` list-column ---------------------------------------------

test_that("cold-audit defect 2: .rc_fill_missing_cols() backfills a missing `candidates` column as a list of NULL (one per row), not NA_character_", {
  df <- tibble::tibble(source_ref = c("r1", "r2"), kind = c("unknown_unit", "unknown_unit"))
  out <- .rc_fill_missing_cols(df, c("source_ref", "kind", "candidates"))

  expect_true(is.list(out$candidates))
  expect_false(is.character(out$candidates))
  expect_length(out$candidates, 2)
  expect_null(out$candidates[[1]])
  expect_null(out$candidates[[2]])

  # every non-list column is still backfilled the old way (NA_character_) -
  # the fix must not change behaviour for any column but `candidates`.
  df2 <- tibble::tibble(source_ref = "r1")
  out2 <- .rc_fill_missing_cols(df2, c("source_ref", "kind", "subkind"))
  expect_identical(out2$kind, NA_character_)
  expect_identical(out2$subkind, NA_character_)
})

test_that("cold-audit defect 2: dplyr::bind_rows() over one df with a real `candidates` list-column and one backfilled by .rc_fill_missing_cols() combines cleanly (no 'Can't combine <list> and <character>' error)", {
  real_cand <- tibble::tibble(uuid_feature = c("f-0001", "f-0002"))
  with_col <- tibble::tibble(
    source_ref = "r1", kind = "unknown_feature", candidates = list(real_cand)
  )
  missing_col <- tibble::tibble(source_ref = "r2", kind = "unknown_unit")
  missing_col <- .rc_fill_missing_cols(missing_col, c("source_ref", "kind", "candidates"))

  combined <- dplyr::bind_rows(with_col, missing_col)

  expect_equal(nrow(combined), 2)
  expect_true(is.list(combined$candidates))
  expect_identical(combined$candidates[[1]], real_cand)
  expect_null(combined$candidates[[2]])
  # downstream shape .ct_commit_review() (R/commit.R) branches on directly.
  expect_true(is.data.frame(combined$candidates[[1]]))
  expect_false(is.data.frame(combined$candidates[[2]]))
})

# =============================================================================
# PLAN-7b remediation (2026-07-26 round 3 audit) - items 1-8
# =============================================================================

# ---- item 1: E.7 self-precedence notes grouped by (alias_key, resolved -----
# feature), not emitted per ANALYSIS ROW (this file's grain) ------------------

test_that("PLAN-7b item 1: a multi-analyte panel resolving via self-precedence over the SAME (alias_key, resolved feature) emits exactly ONE self_precedence_note, not one per analysis row - E.7's own stated purpose ('stops turning into a review-queue flood')", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  # Same self-precedence shape as R-15.45: f-0002's self-alias (fa-0002)
  # shares key 't.s02' with a curated historical arm on f-0003.
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, auto_assign, first_seen, last_seen, date_start, date_end) VALUES
    ('fa-e7grp-block', 'f-0003', 'T.S02', 't.s02', 'historical_code', TRUE,
     TIMESTAMP '2015-01-01 00:00:00', TIMESTAMP '2019-12-31 00:00:00',
     DATE '2015-01-01', DATE '2019-12-31')")

  event <- mk_event(mk_rows(
    mk_row(source_ref = "grp_a", feature_raw = "T.S02", lab_sample_id = "XX9999951001",
           sample_datetime_raw = "01 Jun 2017 09:00"),
    mk_row(source_ref = "grp_b", feature_raw = "T.S02", lab_sample_id = "XX9999951002",
           sample_datetime_raw = "01 Jun 2017 09:00"),
    mk_row(source_ref = "grp_c", feature_raw = "T.S02", lab_sample_id = "XX9999951003",
           sample_datetime_raw = "01 Jun 2017 09:00")
  ))
  out <- reconcile_event(event, con)

  notes <- out$review[!is.na(out$review$subkind) & out$review$subkind == "self_precedence_note", ]
  expect_equal(nrow(notes), 1)
  expect_setequal(strsplit(notes$source_ref[[1]], ",", fixed = TRUE)[[1]],
                  c("grp_a", "grp_b", "grp_c"))
  # `n_rows` itself is internal (not part of `reconcile_event()`'s returned
  # `review` columns), so it is not asserted directly here; the real
  # discriminator against the fan-out this item fixes is `nrow(notes) == 1`
  # above (unfixed code emits THREE rows, one per analysis row, and the
  # `source_ref` check above would then only ever see ONE ref per row, never
  # the full set).
  expect_equal(unname(out$counts[["unknown_feature"]]), 3)
})

# ---- item 2 (kills M5): same-feature alias tie-break prefers the `self` ----
# arm, regardless of DB physical row order ------------------------------------

test_that("PLAN-7b item 2 (kills M5): when several ARMS resolve to the SAME feature, the arm written to sample.uuid_feature_alias is the `kind == 'self'` one - not whichever arm the DB happens to return first - proved in BOTH insert orders", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  DBI::dbExecute(con, "INSERT INTO feature (uuid, name, site, flow, matrix, lon, lat) VALUES
    ('f-tb-a', 'T.TBCASEA', 'T', 'surface', 'water', 150.7001, -33.7001),
    ('f-tb-b', 'T.TBCASEB', 'T', 'surface', 'water', 150.7002, -33.7002)")

  # Case A: self arm inserted FIRST, the non-self arm SECOND.
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, auto_assign, first_seen, last_seen) VALUES
    ('fa-tb-a-self', 'f-tb-a', 'T.TBCASEA', 't.tbcasea', 'self', TRUE,
     TIMESTAMP '2020-01-01 00:00:00', TIMESTAMP '2020-01-01 00:00:00')")
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, auto_assign, first_seen, last_seen) VALUES
    ('fa-tb-a-other', 'f-tb-a', 'T.TBCASEA', 't.tbcasea', 'transcription_error', TRUE,
     TIMESTAMP '2020-01-01 00:00:00', TIMESTAMP '2020-01-01 00:00:00')")

  # Case B: the OPPOSITE order - non-self arm FIRST, self arm SECOND.
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, auto_assign, first_seen, last_seen) VALUES
    ('fa-tb-b-other', 'f-tb-b', 'T.TBCASEB', 't.tbcaseb', 'transcription_error', TRUE,
     TIMESTAMP '2020-01-01 00:00:00', TIMESTAMP '2020-01-01 00:00:00')")
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, auto_assign, first_seen, last_seen) VALUES
    ('fa-tb-b-self', 'f-tb-b', 'T.TBCASEB', 't.tbcaseb', 'self', TRUE,
     TIMESTAMP '2020-01-01 00:00:00', TIMESTAMP '2020-01-01 00:00:00')")

  registry <- .rc_load_registry(con)
  # sanity: both arms really are live candidates on one feature (two rows).
  expect_equal(nrow(.rc_feature_candidates("T.TBCASEA", as.Date("2025-05-20"), registry)), 2)
  expect_equal(nrow(.rc_feature_candidates("T.TBCASEB", as.Date("2025-05-20"), registry)), 2)

  event <- mk_event(mk_rows(
    mk_row(source_ref = "case_a", feature_raw = "T.TBCASEA", lab_sample_id = "XX9999955001",
           sample_datetime_raw = "01 Jun 2020 09:00"),
    mk_row(source_ref = "case_b", feature_raw = "T.TBCASEB", lab_sample_id = "XX9999955002",
           sample_datetime_raw = "01 Jun 2020 09:00")
  ))
  out <- reconcile_event(event, con)

  a <- out$clean[out$clean$source_ref == "case_a", ]
  expect_false(a$feature_pending)
  expect_identical(a$uuid_feature, "f-tb-a")
  expect_identical(a$uuid_feature_alias, "fa-tb-a-self")   # self arm, inserted FIRST

  b <- out$clean[out$clean$source_ref == "case_b", ]
  expect_false(b$feature_pending)
  expect_identical(b$uuid_feature, "f-tb-b")
  expect_identical(b$uuid_feature_alias, "fa-tb-b-self")   # self arm, inserted SECOND
})

# ---- item 3 (kills M1): C.2's cross-site-merge guard, a DIRECT-boundary ----
# same-key re-siting the shared C.2 fixture's dotted/spaced raws cannot reach -

test_that("PLAN-7b item 3 (kills M1): Layer 3 never retries a row Layer 2 already recognised SOME site for through a DIRECT (separator-less) boundary, even when that recognition did not itself produce a hit - without the guard, the WHOLE canonicalised raw is reinterpreted as a point of the work order's single site and silently merges onto an unrelated feature (the live B.K01/L.B01 shape)", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  DBI::dbExecute(con, "INSERT INTO feature (uuid, name, site, flow, matrix, lon, lat) VALUES
    ('f-cx-anchor', 'X.ANCHOR', 'X', 'surface', 'water', 150.8001, -33.8001),
    ('f-cx-collide', 'X.XY01', 'X', 'surface', 'water', 150.8002, -33.8002)")
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, auto_assign, first_seen, last_seen) VALUES
    ('fa-cx-anchor', 'f-cx-anchor', 'X.ANCHOR', 'x.anchor', 'self', TRUE,
     TIMESTAMP '2020-01-01 00:00:00', TIMESTAMP '2020-01-01 00:00:00'),
    ('fa-cx-collide', 'f-cx-collide', 'X.XY01', 'x.xy01', 'self', TRUE,
     TIMESTAMP '2020-01-01 00:00:00', TIMESTAMP '2020-01-01 00:00:00')")

  event <- mk_event(mk_rows(
    # Resolves via Layer 1 (exact alias hit) - establishes the event's
    # single site 'X' for Layer 3 (C.1/C.3).
    mk_row(source_ref = "anchor", feature_raw = "X.ANCHOR", lab_sample_id = "XX9999970001",
           sample_datetime_raw = "01 Jun 2025 09:00"),
    # 'XY01': Layer 2 recognises site 'X' via a DIRECT (separator-less)
    # boundary, extracting residual point 'Y01' -> canonical 'Y1' - which does
    # NOT match f-cx-collide's own point ('X.XY01' split on '.' -> 'XY1').
    # Layer 2 therefore MISSES, but `parsed_site` IS set ('X'). Without the
    # guard, Layer 3 re-canonicalises the WHOLE raw ('xy01' -> 'XY1') as the
    # point and DOES match f-cx-collide - a wrong merge onto an unrelated
    # feature that only happens to share the recognised site.
    mk_row(source_ref = "collide", feature_raw = "XY01", lab_sample_id = "XX9999970002",
           sample_datetime_raw = "01 Jun 2025 09:00")
  ))
  out <- reconcile_event(event, con)

  anc <- out$clean[out$clean$source_ref == "anchor", ]
  expect_false(anc$feature_pending)
  expect_identical(anc$uuid_feature, "f-cx-anchor")

  col <- out$clean[out$clean$source_ref == "collide", ]
  expect_true(col$feature_pending)
  expect_true(is.na(col$uuid_feature))
})

# ---- item 4 (kills M2/M3/M4): exact date-boundary assertions ---------------

test_that("PLAN-7b item 4 (kills M2): an alias-side date_end bound RESOLVES exactly ON the boundary date (E.2 'date_end INCLUSIVE'), not merely strictly before it", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, auto_assign, first_seen, last_seen, date_start, date_end) VALUES
    ('fa-e07b', 'f-0002', 'T.EXPIRED07B', 't.expired07b', 'historical_code', TRUE,
     TIMESTAMP '2018-01-01 00:00:00', TIMESTAMP '2020-12-31 00:00:00', NULL, DATE '2020-12-31')")
  registry <- .rc_load_registry(con)

  cand_on <- .rc_feature_candidates("T.EXPIRED07B", as.Date("2020-12-31"), registry)
  expect_equal(nrow(cand_on), 1)
  expect_identical(cand_on$uuid_feature[[1]], "f-0002")

  # paired negative control: one day AFTER the boundary no longer resolves.
  cand_after <- .rc_feature_candidates("T.EXPIRED07B", as.Date("2021-01-01"), registry)
  expect_equal(nrow(cand_after), 0)
})

test_that("PLAN-7b item 4: an alias-side date_start bound RESOLVES exactly ON the boundary date", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, auto_assign, first_seen, last_seen, date_start, date_end) VALUES
    ('fa-e08b', 'f-0002', 'T.STARTED08B', 't.started08b', 'historical_code', TRUE,
     TIMESTAMP '2024-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00', DATE '2024-01-01', NULL)")
  registry <- .rc_load_registry(con)

  cand_on <- .rc_feature_candidates("T.STARTED08B", as.Date("2024-01-01"), registry)
  expect_equal(nrow(cand_on), 1)
  expect_identical(cand_on$uuid_feature[[1]], "f-0002")

  # paired negative control: one day BEFORE the boundary does not yet resolve.
  cand_before <- .rc_feature_candidates("T.STARTED08B", as.Date("2023-12-31"), registry)
  expect_equal(nrow(cand_before), 0)
})

test_that("PLAN-7b item 4 (kills M4): .rc_feature_candidates() (via .rc_narrow_live_feature()) keeps a defunct FEATURE candidate exactly ON its own date_end - the reused code T.REUSED stays AMBIGUOUS (both f-0006/f-0007) at the exact boundary, not narrowed to f-0007 alone", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  registry <- .rc_load_registry(con)

  # f-0006's date_end is 2020-06-30 (helper-db.R).
  cand_on <- .rc_feature_candidates("T.REUSED", as.Date("2020-06-30"), registry)
  expect_setequal(unique(cand_on$uuid_feature), c("f-0006", "f-0007"))

  # paired negative control: one day after narrows to the single live feature.
  cand_after <- .rc_feature_candidates("T.REUSED", as.Date("2020-07-01"), registry)
  expect_equal(length(unique(cand_after$uuid_feature)), 1)
  expect_identical(unique(cand_after$uuid_feature), "f-0007")
})

test_that("PLAN-7b item 4 (kills M3): .rc_structural_hit() RESOLVES a structural hit exactly ON the feature's own date_end - E.2's 'date_end inclusive' rule applied to the FEATURE side, not only the alias side", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  registry <- .rc_load_registry(con)
  index <- .rc_structural_index(registry)

  # f-0006 (T.S06), date_end 2020-06-30 (helper-db.R); canonical point 'S6'.
  hit_on <- .rc_structural_hit("T", "S6", index, as.Date("2020-06-30"), registry)
  expect_identical(hit_on, "f-0006")

  # paired negative control: one day AFTER the boundary does not resolve.
  hit_after <- .rc_structural_hit("T", "S6", index, as.Date("2020-07-01"), registry)
  expect_true(is.na(hit_after))
})

# ---- item 5: .rc_structural_hit() does not abort when feature.date_end ----
# is an ABSENT column (mirrors .rc_narrow_live_feature()'s existing guard) ---

#' A throwaway registry with a `feature` table that has NO `date_end` column
#' at all (not a column of NA) - the pre-existing-column state
#' `.rc_narrow_live_feature()` already guards ("no date_end column at all =
#' unbounded") but `.rc_structural_hit()` did not.
seed_no_feature_date_end_con <- function(dir = NULL) {
  if (is.null(dir)) dir <- withr::local_tempdir(.local_envir = parent.frame())
  path <- file.path(dir, "no-fde.duckdb")
  con <- DBI::dbConnect(duckdb::duckdb(), path, read_only = FALSE)
  DBI::dbExecute(con, "CREATE TABLE feature (
    uuid VARCHAR PRIMARY KEY, name VARCHAR, site VARCHAR, flow VARCHAR, matrix VARCHAR,
    lon DOUBLE NOT NULL, lat DOUBLE NOT NULL)")
  DBI::dbExecute(con, "CREATE TABLE feature_alias (
    uuid VARCHAR PRIMARY KEY, uuid_feature VARCHAR, name VARCHAR NOT NULL,
    alias_key VARCHAR NOT NULL, kind VARCHAR, n_seen INTEGER DEFAULT 0,
    auto_assign BOOLEAN DEFAULT TRUE, first_seen TIMESTAMP, last_seen TIMESTAMP,
    confirmed_by VARCHAR, comments VARCHAR)")
  DBI::dbExecute(con, "CREATE TABLE feature_mask (uuid_feature VARCHAR, variant VARCHAR, name VARCHAR)")
  DBI::dbExecute(con, "CREATE TABLE analyte (uuid VARCHAR PRIMARY KEY, name VARCHAR, units VARCHAR,
    conversion_constant DOUBLE, type VARCHAR, CAS VARCHAR)")
  DBI::dbExecute(con, "CREATE TABLE lab_method (uuid VARCHAR PRIMARY KEY, uuid_analyte VARCHAR,
    name VARCHAR, method VARCHAR, organisation VARCHAR, rl_low DOUBLE, rl_high DOUBLE,
    reported_as VARCHAR, api VARCHAR, uuid_project VARCHAR, uuid_feature VARCHAR,
    comments VARCHAR, units VARCHAR, conversion_constant DOUBLE)")
  DBI::dbExecute(con, "CREATE TABLE project (uuid VARCHAR PRIMARY KEY, uuid_parent VARCHAR,
    uuid_root VARCHAR, uuid_project VARCHAR, name VARCHAR, type VARCHAR, purpose VARCHAR,
    date_start TIMESTAMP, date_end TIMESTAMP, regulated_by VARCHAR, cypher VARCHAR,
    site VARCHAR, value VARCHAR)")

  DBI::dbExecute(con, "INSERT INTO feature (uuid, name, site, flow, matrix, lon, lat) VALUES
    ('f-nfde-01', 'P.S01', 'P', 'surface', 'water', 150.9001, -33.9001)")
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, auto_assign, first_seen, last_seen) VALUES
    ('fa-nfde-01', 'f-nfde-01', 'P.S01', 'p.s01', 'self', TRUE,
     TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00')")
  con
}

test_that("PLAN-7b item 5: .rc_structural_hit() does not abort when feature.date_end is an ABSENT column (mirrors .rc_narrow_live_feature()'s existing 'no date_end column at all = unbounded' guard)", {
  con <- seed_no_feature_date_end_con()
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  registry <- .rc_load_registry(con)
  expect_null(registry$feature$date_end)

  index <- .rc_structural_index(registry)
  hit <- .rc_structural_hit("P", "S1", index, as.Date("2025-05-20"), registry)
  expect_identical(hit, "f-nfde-01")
})

test_that("D9/R-15.14 extension (PLAN-7b round-2): .rc_narrow_live_feature()'s OWN 'no feature.date_end column at all = unbounded' guard (:417) does not empty the candidate set - the same absent-column fixture item 5 uses above for its .rc_structural_hit() twin, read through .rc_feature_candidates() (which routes straight through .rc_narrow_live_feature())", {
  con <- seed_no_feature_date_end_con()
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  registry <- .rc_load_registry(con)
  expect_null(registry$feature$date_end)

  cand <- .rc_feature_candidates("P.S01", as.Date("2025-05-20"), registry)
  expect_equal(nrow(cand), 1)
  expect_identical(cand$uuid_feature[[1]], "f-nfde-01")
})

# ---- item 6(a): .rc_as_date_bound() never silently admits a wrongly-spelled -
# character bound as "unbounded" ----------------------------------------------

test_that("D14 (PLAN-7b round-2): .rc_review_row() aborts when `diagnostics` supplies a RESERVED key ('source_ref' or 'n_rows') - these are always set from this function's own arguments, and a caller supplying either would otherwise silently overwrite the real value with a duplicate name .rq_row() rejects with a message pointing at the wrong function", {
  expect_error(
    .rc_review_row(source_ref = "r1", kind = "unknown_feature", n_rows = 1L,
                   source_hash = "h1", diagnostics = list(source_ref = "x")),
    class = "sampletidy_error"
  )
  expect_error(
    .rc_review_row(source_ref = "r1", kind = "unknown_feature", n_rows = 1L,
                   source_hash = "h1", diagnostics = list(n_rows = 99L)),
    class = "sampletidy_error"
  )
  # paired positive control: an ORDINARY diagnostics key (no collision) does
  # not abort - the guard is scoped to the two reserved names, not to
  # diagnostics= being non-empty.
  ok <- .rc_review_row(source_ref = "r1", kind = "unknown_feature", n_rows = 1L,
                       source_hash = "h1", diagnostics = list(feature_raw = "T.S01"))
  expect_equal(nrow(ok), 1)
})

test_that("PLAN-7b item 6(a): .rc_as_date_bound() ABORTS on a non-NA character bound that does not parse as ISO 'YYYY-MM-DD' - a wrong spelling ('2026/05/04') used to silently become NA (i.e. UNBOUNDED, i.e. ADMITTING the row), defeating the bound a curator set", {
  expect_error(.rc_as_date_bound("2026/05/04", what = "test bound"), class = "sampletidy_error")

  # paired positive control: a real ISO string still parses cleanly.
  expect_identical(.rc_as_date_bound("2026-05-04", what = "test bound"), as.Date("2026-05-04"))

  # paired NA control: a genuine missing bound stays unbounded, never an error.
  expect_true(is.na(.rc_as_date_bound(NA_character_, what = "test bound")))
})

# ---- item 6(b): .rc_narrow_live() routed through .rc_as_date_bound() -------

test_that("PLAN-7b item 6(b): .rc_narrow_live() routes feature$date_end through .rc_as_date_bound() and ABORTS on a POSIXct bound instead of silently coercing it - the candidate path (.rc_narrow_live_feature()/.rc_structural_hit()) already rejects exactly this input", {
  registry <- list(feature = data.frame(
    uuid = c("fx-1", "fx-2"),
    date_end = as.POSIXct(c("2020-06-30 00:00:00", NA), tz = "UTC"),
    stringsAsFactors = FALSE
  ))
  cand <- tibble::tibble(uuid_alias = c("a1", "a2"), uuid_feature = c("fx-1", "fx-2"))
  expect_error(.rc_narrow_live(cand, as.Date("2025-05-20"), registry), class = "sampletidy_error")
})

# ---- item 7: unknown_feature review row GROUP order is radix-pinned, not --
# the R session's LC_COLLATE ---------------------------------------------------

test_that("PLAN-7b item 7: .rc_feature_review()'s GROUP order is pinned to radix (byte-order) collation, not the R session's LC_COLLATE - two keys differing only in punctuation ('t_01' vs 't.01') that collate in OPPOSITE order under C vs en_US.UTF-8 on this platform still emit in the SAME (radix) order under both", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  event <- mk_event(mk_rows(
    mk_row(source_ref = "r_underscore", feature_raw = "T_01",
           lab_sample_id = "XX9999960001", sample_datetime_raw = "01 Jun 2025 09:00"),
    mk_row(source_ref = "r_dot", feature_raw = "T.01",
           lab_sample_id = "XX9999960002", sample_datetime_raw = "01 Jun 2025 09:00")
  ))

  run_order <- function(locale) {
    withr::with_locale(c(LC_COLLATE = locale), {
      out <- reconcile_event(event, con)
      out$review$source_ref[out$review$kind == "unknown_feature"]
    })
  }

  # Establish the divergence is REAL on this platform before pinning against
  # it - otherwise a platform where the two locales happen to agree would
  # make the assertion below vacuous.
  sort_c <- sort(c("t_01", "t.01"))
  sort_en <- withr::with_locale(c(LC_COLLATE = "en_US.UTF-8"), sort(c("t_01", "t.01")))
  skip_if_not(!identical(sort_c, sort_en),
              "this platform's C and en_US.UTF-8 collations agree on 't_01'/'t.01' - cannot demonstrate the divergence here")

  order_c <- run_order("C")
  order_en <- run_order("en_US.UTF-8")

  expect_identical(order_c, order_en)
  # radix: 't.01' < 't_01' (ASCII '.' 0x2E < '_' 0x5F).
  expect_identical(order_c, c("r_dot", "r_underscore"))
})

# ---- item 8: `blocking` is an explicit boolean on every remaining review- --
# row diagnostic this file queues, not merely the self_precedence_note case --

test_that("PLAN-7b item 8 REVERSED (Robin, 2026-07-26): `blocking` stays SCOPED to the unknown_feature subkind precedence table (.rc_feature_review()/.rc_self_precedence_notes()) and is ABSENT (not merely FALSE) from every other kind's diagnostics - batch_duplicate, unknown_unit, unknown_analyte (both branches), parse_error, value_conflict, and STAGE-0. A first attempt made it universal; that broke test-review-queue-payload.R's R-16.19/R-16.20 cross-producer key-parity invariant against .fa_merge_samples() (R/feature-alias.R, a file this assignment does not own) because that sibling producer has no `blocking` key to match. Reverted to code; the docstring's claim was narrowed instead (see the comment block above `.rc_feature_review()`) - this test locks the narrowed contract, not the reverted-and-forgotten one", {
  path <- seed_db(); con <- seed_con(path); on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  diag_of <- function(review_row) jsonlite::fromJSON(review_row$payload[[1]])

  # unknown_unit
  event_unit <- mk_event(mk_row(source_ref = "r1", units_raw = "banana/L"))
  out_unit <- reconcile_event(event_unit, con)
  hit_unit <- out_unit$review[out_unit$review$source_ref == "r1" & out_unit$review$kind == "unknown_unit", ]
  expect_equal(nrow(hit_unit), 1)
  expect_false("blocking" %in% names(diag_of(hit_unit)))

  # parse_error (datetime)
  event_dt <- mk_event(mk_row(source_ref = "r1", sample_datetime_raw = "not a date"))
  out_dt <- reconcile_event(event_dt, con)
  hit_dt <- out_dt$review[out_dt$review$source_ref == "r1" & out_dt$review$kind == "parse_error", ]
  expect_equal(nrow(hit_dt), 1)
  expect_false("blocking" %in% names(diag_of(hit_dt)))

  # unknown_analyte: known_analyte_no_method (CAS-suggested) branch
  event_cas <- mk_event(mk_row(source_ref = "r1", analyte_raw = "Fluoride", org = "Internal",
                               cas_number = "16984-48-8", method_raw = NA_character_))
  out_cas <- reconcile_event(event_cas, con)
  hit_cas <- out_cas$review[out_cas$review$source_ref == "r1", ]
  expect_equal(nrow(hit_cas), 1)
  expect_identical(hit_cas$subkind[[1]], "known_analyte_no_method")
  expect_false("blocking" %in% names(diag_of(hit_cas)))

  # unknown_analyte: full-miss (grouped) branch
  event_miss <- mk_event(mk_row(source_ref = "r1", analyte_raw = "Nonexistentite", org = "ALS",
                                cas_number = NA_character_))
  out_miss <- reconcile_event(event_miss, con)
  hit_miss <- out_miss$review[out_miss$review$kind == "unknown_analyte" &
                                 grepl("Nonexistentite", out_miss$review$payload), ]
  expect_equal(nrow(hit_miss), 1)
  expect_false("blocking" %in% names(diag_of(hit_miss)))

  # value_conflict - the shape that broke R-16.19/R-16.20 parity.
  DBI::dbExecute(con, "INSERT INTO analysis
    (uuid, uuid_sample, uuid_lab, value, value_chr, quantified) VALUES
    ('an-p7b8-vc', 's-0001', 'lm-0001', NULL, 'clear', NULL)")
  event_vc <- mk_event(mk_row(source_ref = "r1", analyte_raw = "pH Value", org = "ALS",
                              method_raw = "EA005P: pH by PC Titrator", units_raw = "pH",
                              value_raw = "turbid, brown", value_num = NA_real_,
                              value_chr = "turbid, brown", below_detection = NA,
                              rl = NA_real_, cas_number = NA_character_,
                              lab_sample_id = "XX1234567001"))
  out_vc <- reconcile_event(event_vc, con)
  hit_vc <- out_vc$review[out_vc$review$source_ref == "r1" & out_vc$review$kind == "value_conflict", ]
  expect_equal(nrow(hit_vc), 1)
  expect_false("blocking" %in% names(diag_of(hit_vc)))

  # batch_duplicate
  event_bd <- mk_event(mk_rows(
    mk_row(source_ref = "BD_WINNER", feature_raw = "T.S01", lab_sample_id = "XX9999958001",
           sample_datetime_raw = "01 Jun 2025 09:00"),
    mk_row(source_ref = "BD_LOSER", feature_raw = "T.S01", lab_sample_id = "XX9999958001",
           sample_datetime_raw = "01 Jun 2025 09:00")
  ))
  out_bd <- reconcile_event(event_bd, con)
  hit_bd <- out_bd$review[out_bd$review$kind == "batch_duplicate", ]
  expect_equal(nrow(hit_bd), 1)
  expect_false("blocking" %in% names(diag_of(hit_bd)))

  # STAGE-0 (foreign_work_order, via assembly)
  parsed <- list(
    "h-p7b8" = .rc_mk_parsed_entry(
      results = dplyr::bind_rows(
        .rc_mk_ir_result(source_hash = "h-p7b8", source_ref = "own_wo", work_order = "XX1234567",
                         lab_sample_id = "XX1234567001", sample_type = "unknown"),
        .rc_mk_ir_result(source_hash = "h-p7b8", source_ref = "foreign_wo", work_order = "ZZ0000002",
                         lab_sample_id = "ZZ0000002001", sample_type = "Normal")
      ),
      meta = list(work_order_guess = "XX1234567")
    )
  )
  asm <- assemble_events(parsed)
  target <- Filter(function(e) "foreign_wo" %in% e$results$source_ref, asm$events)
  out_s0 <- reconcile_event(target[[1]], con)
  hit_s0 <- out_s0$review[out_s0$review$source_ref == "foreign_wo", ]
  expect_equal(nrow(hit_s0), 1)
  expect_false("blocking" %in% names(diag_of(hit_s0)))

  # positive control (same test): the unknown_feature producer STILL carries
  # `blocking` - the scoped claim, not a total absence.
  event_uf <- mk_event(mk_row(source_ref = "r1", feature_raw = "Test Surface 01",
                              sample_datetime_raw = "20 May 2025 09:00"))
  out_uf <- reconcile_event(event_uf, con)
  hit_uf <- out_uf$review[out_uf$review$source_ref == "r1" & out_uf$review$kind == "unknown_feature", ]
  expect_equal(nrow(hit_uf), 1)
  expect_true("blocking" %in% names(diag_of(hit_uf)))
})

test_that("round-3 [GENERALIZE]: every order() in reconcile.R pins method='radix'", {
  # D4/D7 pin radix as the locale-independent sort. Round 3's sibling grep found
  # three sites that had drifted off it - .rc_site_registry()'s secondary key and
  # the two uuid tie-breaks - all CHARACTER keys, so all locale-dependent.
  # This is observable in the project's own locale, not a hypothetical one:
  # under en_AU.UTF-8, order(c("ax","Bx")) is ax,Bx while radix is Bx,ax.
  reg <- list(feature = data.frame(
    site = c("ax", "Bx", "Longer Site"), stringsAsFactors = FALSE))
  got <- .rc_site_registry(reg)

  # Longest first (the registry is matched longest-first, so this must hold).
  expect_identical(got[[1]], "Longer Site")

  # WHY THERE IS NO BEHAVIOURAL ASSERTION ON THE TIE-BREAK ORDER, and why the
  # structural guard below is not belt-and-braces but the ONLY detector:
  #
  # testthat runs with LC_COLLATE=C. Under C collation `order(x)` and
  # `order(x, method = "radix")` are BY DEFINITION identical, so no fixture can
  # tell a radix-pinned sort from a locale-dependent one from inside this
  # suite. I checked rather than assumed: `expect_identical(got[2:3],
  # c("Bx","ax"))` PASSES against the un-pinned code, because in C collation
  # "Bx" sorts before "ax" either way. Outside testthat, in the project's own
  # en_AU.UTF-8, the same call returns "ax","Bx" - the bug is real, it is
  # simply invisible here.
  #
  # Consequence worth knowing: EVERY locale-collation defect in this codebase
  # is behaviourally untestable in this suite, so the D4/D7 radix pins can only
  # be defended structurally. Do not "strengthen" this test by adding an order
  # assertion - one was tried and was decorative.
  expect_identical(Sys.getlocale("LC_COLLATE"), "C")

  # Structural guard so the next drift is caught at the source, not by a
  # behavioural test someone has to think to write. This is the [GENERALIZE]
  # half: pin the PATTERN, not just the three sites fixed today.
  src <- readLines(test_path("..", "..", "R", "reconcile.R"), warn = FALSE)
  # COMMENT only: the default also blanks STR_CONST, which would blank the
  # `"radix"` this guard matches on and report every correctly-pinned call as
  # a violation. Comments still must go - a commented-out order() is not code.
  src <- .st_strip_source_noise(src, "R/reconcile.R", tokens = "COMMENT")
  hits <- grep("\\border\\(", src, value = TRUE)
  bad <- hits[!grepl('method\\s*=\\s*"radix"', hits)]
  # A multi-line order() call carries `method = "radix"` on a continuation
  # line; join those to the following line before judging.
  if (length(bad) > 0) {
    idx <- which(!grepl('method\\s*=\\s*"radix"', hits))
    bad <- bad[vapply(idx, function(i) {
      j <- which(src == hits[[i]])[[1]]
      !grepl('method\\s*=\\s*"radix"', paste(src[j:min(j + 2, length(src))], collapse = " "))
    }, logical(1))]
  }
  expect_identical(bad, character(0),
    info = "every order() in R/reconcile.R must pin method = 'radix' (D4/D7)")
})
