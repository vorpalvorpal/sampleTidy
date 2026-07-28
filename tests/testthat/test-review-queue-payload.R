# PLAN-16 - R/reconcile.R + R/feature-alias.R + R/commit.R: the structured
# review payload (`.rq_row()`/`.rq_skip()`, typed `subkind`/`uuid_existing`/
# `uuid_alias` columns, the `review_queue_candidate` child table).
#
# NEW FILE. Scope: seven payload CONTENT/SHAPE criteria only - R-16.10,
# R-16.11, R-16.14, R-16.17, R-16.18, R-16.19, R-16.20. Every other R-16.*
# criterion (DDL, migration, R-16.6's k=v-forbidden meta-test, R-16.9's
# dual-insert-path parity, ...) belongs to a different unit; do not add tests
# for them here.
#
# RED BY DESIGN: `.rq_row()`/`.rq_skip()` do not exist yet, `review_queue`
# has no `subkind`/`uuid_existing`/`uuid_alias` columns yet, and every
# producer still hand-assembles a `k=v` string via `paste0()` or the
# unescaped `.rc_serialise_payload()` (R/reconcile.R:108-117). Every test
# below is written against the FUTURE structured shape the plan pins, not
# against today's behaviour - do not weaken an assertion to match the
# current mangled/absent output.
#
# Fixtures: `tests/testthat/helper-db.R`'s `seed_db()`/`seed_con()` only -
# no edits there. `mk_row()`/`mk_rows()`/`mk_event()` below are LOCAL,
# verbatim copies of test-reconcile.R's own builders (same convention
# test-commit.R already uses for the identical reason: each testthat file
# runs in its own environment, so there is no cross-file name collision).
# `mk_collision_fixture()` is likewise a local, verbatim copy of
# test-feature-alias.R's fixture builder, needed to drive the REAL
# `.fa_merge_samples()` value_conflict producer for R-16.19/R-16.20.
#
# `mk_commit_event()`/`mk_resolved()` are local, verbatim-shape copies of
# test-commit.R's own builders of the same name (same no-cross-file-collision
# convention as every other local helper in this file). Round-2 remediation
# (FF12, worker W-G 2026-07-25): R-16.10 previously drove a test-local
# `.p16_write_review_row()` that mirrored `.ct_commit_review()`'s insert by
# hand and had already drifted (it wrote 6 columns, omitting
# subkind/uuid_existing/uuid_alias) - so the plan's headline criterion never
# exercised the real write path. `.p16_write_review_row()` is DELETED, not
# kept alongside; R-16.10 now drives a genuine `commit_event()` call instead.

# ---- local helpers (verbatim copies; see file header) ----------------------

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

#' Verbatim copy of test-feature-alias.R's collision fixture: two DANGLING
#' aliases each with a sample dated 2025-08-01; an-w2/an-l2 (values 50 vs 99)
#' is the value_conflict duplicate `.fa_merge_samples()` opens on merge.
mk_collision_fixture <- function(con) {
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign,
     first_seen, last_seen, confirmed_by) VALUES
    (?, NULL, ?, ?, 'pending', 0, FALSE, TIMESTAMP '2025-08-01 08:00:00',
     TIMESTAMP '2025-08-01 08:00:00', NULL)",
    params = list("fa-9001", "T.NEWCODE1", "tnewcode1"))
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign,
     first_seen, last_seen, confirmed_by) VALUES
    (?, NULL, ?, ?, 'pending', 0, FALSE, TIMESTAMP '2025-08-01 08:00:00',
     TIMESTAMP '2025-08-01 08:00:00', NULL)",
    params = list("fa-9002", "T.NEWCODE2", "tnewcode2"))
  DBI::dbExecute(con, "INSERT INTO \"sample\"
    (uuid, uuid_feature_alias, uuid_project, date, datetime, organisation, person) VALUES
    ('s-9001', 'fa-9001', 'p-0001', TIMESTAMP '2025-08-01 00:00:00', TIMESTAMP '2025-08-01 09:00:00', 'ALS', NULL),
    ('s-9002', 'fa-9002', 'p-0001', TIMESTAMP '2025-08-01 00:00:00', TIMESTAMP '2025-08-01 14:00:00', 'ACIRL', 'J. Smith')")
  DBI::dbExecute(con, "INSERT INTO analysis
    (uuid, uuid_sample, uuid_lab, value, quantified, rl_low) VALUES
    ('an-w1', 's-9001', 'lm-0001', 7.0, TRUE, 0.01),
    ('an-w2', 's-9001', 'lm-0002', 50, TRUE, 0.1),
    ('an-l1', 's-9002', 'lm-0001', 7.0, TRUE, 0.01),
    ('an-l2', 's-9002', 'lm-0002', 99, TRUE, 0.1)")
  invisible(NULL)
}

#' Local, verbatim-shape copy of test-commit.R's `mk_commit_event()`: the
#' plan-07 event shape `commit_event()` expects. Needed here (FF12 fix) to
#' drive R-16.10 through the REAL write path instead of a test-local
#' reimplementation of `.ct_commit_review()`.
mk_commit_event <- function(files, work_order = "XX1234567") {
  list(
    work_order = work_order, orphan = FALSE,
    results = tibble::tibble(), samples = tibble::tibble(),
    files = files,
    report = list(n_results = 0L, n_by_sample_type = list(), n_ncp_foreign = 0L,
                  skipped = tibble::tibble(hash = character(), source_ref = character(), reason = character()),
                  warnings = character())
  )
}

#' Local, verbatim-shape copy of test-commit.R's `mk_resolved()`: the
#' plan-08 `resolved` shape `commit_event()` expects.
mk_resolved <- function(clean = tibble::tibble(), review = tibble::tibble(),
                        skipped = tibble::tibble(), counts = c(new = nrow(clean))) {
  list(clean = clean, review = review, skipped = skipped, counts = counts)
}

#' An empty `files` tibble in the shape `commit_event()`/`mk_commit_event()`
#' expect (matching `mk_event()`'s own `files` column set above) - zero rows
#' is enough to drive the review-item write path: `.ct_check_not_already_
#' committed()`, `.ct_archive_files()` and `.ct_set_file_states()` all
#' early-return on zero kept files, and `.ct_commit_review()` (step 5) does
#' not depend on `files` at all.
.p16_empty_files <- function() {
  tibble::tibble(hash = character(), filename = character(),
                 adapter = character(), rank = integer(), kept = logical())
}

# ==============================================================================
# R-16.10 (THE HEADLINE, round-3 TABLE-DRIVEN REWRITE): a value containing
# hostile bytes round-trips byte-for-byte through EVERY content-producing
# review_queue producer, not just one or two of them. Round 3 found this
# verified on only 2 of the 14 producers inventoried in
# `dev/tdd-run/p16-payload-prod-inventory.md` Section 1b - the coverage gap
# that let slice I's mutant F5 hand-roll an unescaped `sprintf()` payload
# inside `.rc_feature_review()`'s `structural` branch and emit INVALID JSON
# for a quoted `feature_raw` against a fully green suite. Every producer
# below (Robin's ruling: a PROPERTY of every producer, not one verified site)
# is driven through its REAL production entry point -
# `reconcile_event()`/`confirm_feature_aliases()`/`confirm_analyte_methods()`/
# `route_files()` - never a hand-built tibble standing in for one, with the
# SAME shared hostile byte set: comma, apostrophe, pipe, `=`, `"`, `\`, tab,
# newline, non-ASCII. Two producers cannot carry hostile content at all
# (explained explicitly at their own table entries below, not silently
# dropped) - #6 `method_duplicate` (no free-text diagnostics field exists)
# and #10's own coverage is retained from round 2 rather than duplicated;
# see the individual `test_that()` names below for the 1/18..18/18 count.
#
# PLAN-7b round-3 finding 3/item 4: this "14 producers" enumeration was
# itself incomplete - it omitted FOUR real `review_queue` producers:
# `.rc_self_precedence_notes()` (diagnostics `feature_raw`, source-controlled
# free text - added #15 below), `.rc_analyte_review()`'s `held` branch
# (diagnostics `analyte_raw`/`org`, also free text - added #16),
# `.ct_reingest_guard()`'s `work_order_reingest` (diagnostics `work_order`)
# and `.fa_confirm_one_alias()`'s `sample_collision` (uuids only), the latter
# two added as explicitly-vacuous entries (#17/#18) in the style of #6 - they
# genuinely carry no free-text field a hostile byte could travel through.
# Also fixed: #1's own header claimed the round-2 gap it exists to close was
# in `.rc_feature_review()`'s `structural` branch, but its fixture drove the
# bare/unmatched (NA-subkind) branch instead, leaving `structural`'s own
# hostile-byte path (`diagnostics$point`) unexercised - #1b below drives it.

# The shared hazard strings. Neither starts/ends with whitespace - both
# `.rc_feature_key()` and `parse_value()` trim LEADING/TRAILING whitespace
# before classification, so an edge char there would test `trimws()`, not
# JSON escaping.
P16_HAZARD  <- "haz,1'2|3=4\"5\\6\t7\n8µend"
P16_HAZARD2 <- "haz,B'C|D=E\"F\\G\tH\nIµend2"
# The real analyte name from the live registry (R-16.10's own instruction:
# use it for at least one case). Already carries a comma and two apostrophes
# - a genuine specimen of the hazard class, not a synthetic stand-in.
P16_REAL_ANALYTE <- "2,2',3,3',4,4'-Hexachlorobiphenyl"

#' Assert that `raw` (the LITERAL stored payload TEXT) contains the correctly
#' escaped JSON rendering of `expected`, AND that `jsonlite::fromJSON(raw)`
#' reads `key` back byte-identical to `expected`. Two independent checks (the
#' original R-16.10 test's own reasoning, preserved here): a serialiser that
#' silently DROPS a hazard character instead of escaping it can still parse
#' back to something via `fromJSON()` on the surviving characters, so the
#' parsed-value check alone cannot see that mutant - the raw-text containment
#' check can.
#' @keywords internal
.p16_assert_hazard <- function(raw, key, expected) {
  expected_json <- as.character(jsonlite::toJSON(expected, auto_unbox = TRUE))
  testthat::expect_true(grepl(expected_json, raw, fixed = TRUE),
                        info = sprintf("key=%s raw=%s", key, raw))
  parsed <- tryCatch(jsonlite::fromJSON(raw), error = function(e) list())
  testthat::expect_identical(parsed[[key]], expected)
}

test_that("R-16.10 property (1/18 - .rc_feature_review, bare/unmatched subkind): feature_raw carrying every hostile byte round-trips through reconcile_event()", {
  path <- seed_db()
  con <- seed_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  event <- mk_event(mk_row(source_ref = "r1", feature_raw = P16_HAZARD,
                           lab_sample_id = "XX9999991001",
                           sample_datetime_raw = "08 Jun 2025 09:00"))
  out <- reconcile_event(event, con)
  hit <- out$review[out$review$kind == "unknown_feature", , drop = FALSE]
  expect_equal(nrow(hit), 1)
  .p16_assert_hazard(hit$payload[[1]], "feature_raw", P16_HAZARD)
})

test_that("R-16.10 property (1b/18 - .rc_feature_review, STRUCTURAL branch specifically): finding 4 - #1's own header names THIS branch as the round-2 mutant F5 gap, but #1's fixture (bare feature_raw) drives the bare/unmatched branch instead; drive the structural branch itself with a recognised site prefix so diagnostics$point actually carries the hostile bytes", {
  path <- seed_db()
  con <- seed_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  # 'T' is a recognised site (R-16.11's own fixture); the same hazard string,
  # prefixed with a recognised site token, reaches the STRUCTURAL branch
  # instead - mutation R-M7-GAP (stripping `"` out of diagnostics$point)
  # survived precisely because no test drove this branch with hostile bytes.
  event <- mk_event(mk_row(source_ref = "r1", feature_raw = paste0("T.", P16_HAZARD),
                           lab_sample_id = "XX9999991002",
                           sample_datetime_raw = "08 Jun 2025 09:00"))
  out <- reconcile_event(event, con)
  hit <- out$review[out$review$kind == "unknown_feature", , drop = FALSE]
  expect_equal(nrow(hit), 1)
  expect_identical(hit$subkind[[1]], "structural")
  .p16_assert_hazard(hit$payload[[1]], "point", toupper(P16_HAZARD))
})

test_that("R-16.10 property (2/18 - .rc_analyte_review CAS-suggested branch): analyte_raw carrying every hostile byte round-trips, subkind='known_analyte_no_method'", {
  path <- seed_db()
  con <- seed_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  # No lab_method row for (hazard text, Internal); CAS 16984-48-8 -> a-0002
  # exists (verbatim setup from test-reconcile.R's own R-8.3 CAS-fallback
  # fixture, hazard text substituted for the plain analyte_raw).
  event <- mk_event(mk_row(source_ref = "r1", analyte_raw = P16_HAZARD, org = "Internal",
                           cas_number = "16984-48-8", method_raw = NA_character_))
  out <- reconcile_event(event, con)
  hit <- out$review[out$review$kind == "unknown_analyte" &
                       !is.na(out$review$subkind) &
                       out$review$subkind == "known_analyte_no_method", , drop = FALSE]
  expect_equal(nrow(hit), 1)
  .p16_assert_hazard(hit$payload[[1]], "analyte_raw", P16_HAZARD)
})

test_that("R-16.10 property (3/18 - .rc_analyte_review miss/ambiguous branch): the REAL live-registry analyte name \"2,2',3,3',4,4'-Hexachlorobiphenyl\" round-trips", {
  path <- seed_db()
  con <- seed_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  event <- mk_event(mk_row(source_ref = "r1", analyte_raw = P16_REAL_ANALYTE, org = "ALS",
                           cas_number = NA_character_))
  out <- reconcile_event(event, con)
  hit <- out$review[out$review$kind == "unknown_analyte" &
                       is.na(out$review$subkind), , drop = FALSE]
  expect_equal(nrow(hit), 1)
  .p16_assert_hazard(hit$payload[[1]], "analyte_raw", P16_REAL_ANALYTE)
})

test_that("R-16.10 property (4/18 - .rc_resolve_units_values, unknown_unit): units_raw carrying every hostile byte round-trips", {
  path <- seed_db()
  con <- seed_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  event <- mk_event(mk_row(source_ref = "r1", units_raw = P16_HAZARD))
  out <- reconcile_event(event, con)
  hit <- out$review[out$review$kind == "unknown_unit", , drop = FALSE]
  expect_equal(nrow(hit), 1)
  .p16_assert_hazard(hit$payload[[1]], "units_raw", P16_HAZARD)
})

test_that("R-16.10 property (5/18 - .rc_resolve_datetime, parse_error): sample_datetime_raw carrying every hostile byte round-trips", {
  path <- seed_db()
  con <- seed_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  event <- mk_event(mk_row(source_ref = "r1", sample_datetime_raw = P16_HAZARD))
  out <- reconcile_event(event, con)
  hit <- out$review[out$review$kind == "parse_error", , drop = FALSE]
  expect_equal(nrow(hit), 1)
  .p16_assert_hazard(hit$payload[[1]], "sample_datetime_raw", P16_HAZARD)
})

test_that("R-16.10 property (6/18 - .rc_method_preference, method_duplicate): NOT DRIVEN WITH HOSTILE BYTES - this producer genuinely has no free-text diagnostics field", {
  # method_duplicate's SKIP row carries exactly one piece of content:
  # kept_uuid_lab, a real TYPED column (R/reconcile.R ~1107-1110) populated
  # from `lab_method.uuid` - an internally-generated identifier, never free
  # text a source file controls. `.rc_skip_row()` is called with no
  # `diagnostics` argument at all for this producer, so
  # `.rq_serialise_diagnostics(list())` always emits the fixed literal "{}" -
  # there is no field in this producer's shape for a hostile byte to travel
  # through, so the byte-round-trip property is VACUOUSLY true here, not
  # silently skipped. Driven through the real production path anyway (the
  # proven R-8.6 fixture, verbatim from R-16.17's own method_duplicate test)
  # to confirm that "{}" claim rather than asserting it from the sidelines.
  path <- seed_db()
  con <- seed_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  event <- mk_event(mk_rows(
    mk_row(source_ref = "r1", lab_sample_id = "XX1234567002", feature_raw = "T.S02",
           method_raw = "EK040P: Fluoride by PC Titrator",
           value_raw = "2.3", value_num = 2.3, below_detection = FALSE, rl = 0.1),
    mk_row(source_ref = "r2", lab_sample_id = "XX1234567002", feature_raw = "T.S02",
           method_raw = "EK040T: Fluoride by alt method",
           value_raw = "2.5", value_num = 2.5, below_detection = FALSE, rl = 0.5)
  ))
  out <- reconcile_event(event, con)
  hit <- out$skipped[out$skipped$reason == "method_duplicate", , drop = FALSE]
  expect_equal(nrow(hit), 1)
  expect_identical(hit$payload[[1]], "{}")
})

test_that("R-16.10 property (7/18 - .rc_three_way, already_present skip): a text value carrying every hostile byte round-trips as BOTH value_chr_existing and value_chr_incoming", {
  path <- seed_db()
  con <- seed_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  # A fresh sample/analysis (own work order, not any FIXTURES.md-pinned one)
  # with a TEXT-valued (quantified=NULL) existing result carrying P16_HAZARD.
  DBI::dbExecute(con, "INSERT INTO project (uuid, name, type) VALUES ('p-9701', 'GH9701234', 'Work order')")
  DBI::dbExecute(con, "INSERT INTO \"sample\" (uuid, uuid_feature_alias, uuid_project, date, organisation) VALUES
    ('s-9701', 'fa-0002', 'p-9701', TIMESTAMP '2025-06-01 00:00:00', 'ALS')")
  DBI::dbExecute(con, "INSERT INTO analysis (uuid, uuid_sample, uuid_lab, value, value_chr, quantified, rl_low) VALUES
    ('an-9701', 's-9701', 'lm-0002', NULL, ?, NULL, 0.1)", params = list(P16_HAZARD))

  # Incoming row: SAME text value (P16_HAZARD) -> .rc_values_equal() ->
  # already_present. feature_raw 'T.S02' resolves via fa-0002's self alias
  # (helper-db.R:303); method 'EK040P: Fluoride by PC Titrator'/ALS -> lm-0002.
  event <- mk_event(mk_row(source_ref = "r1", work_order = "GH9701234",
                           feature_raw = "T.S02", analyte_raw = "Fluoride",
                           method_raw = "EK040P: Fluoride by PC Titrator",
                           cas_number = NA_character_, units_raw = "mg/L",
                           value_raw = P16_HAZARD, value_num = NA_real_,
                           value_chr = P16_HAZARD, below_detection = FALSE, rl = 0.1,
                           sample_datetime_raw = "01 Jun 2025"))
  out <- reconcile_event(event, con)
  hit <- out$skipped[out$skipped$reason == "already_present", , drop = FALSE]
  expect_equal(nrow(hit), 1)
  raw <- hit$payload[[1]]
  .p16_assert_hazard(raw, "value_chr_existing", P16_HAZARD)
  .p16_assert_hazard(raw, "value_chr_incoming", P16_HAZARD)
})

test_that("R-16.10 property (8/18 - .rc_three_way, value_conflict subkind='measurement'): TWO DISTINCT hostile-byte text values (existing vs incoming) both round-trip", {
  path <- seed_db()
  con <- seed_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  DBI::dbExecute(con, "INSERT INTO project (uuid, name, type) VALUES ('p-9801', 'GH9801234', 'Work order')")
  DBI::dbExecute(con, "INSERT INTO \"sample\" (uuid, uuid_feature_alias, uuid_project, date, organisation) VALUES
    ('s-9801', 'fa-0002', 'p-9801', TIMESTAMP '2025-06-01 00:00:00', 'ALS')")
  DBI::dbExecute(con, "INSERT INTO analysis (uuid, uuid_sample, uuid_lab, value, value_chr, quantified, rl_low) VALUES
    ('an-9801', 's-9801', 'lm-0002', NULL, ?, NULL, 0.1)", params = list(P16_HAZARD))

  # Incoming carries a DIFFERENT hostile text (P16_HAZARD2) -> not A14-equal
  # -> no recorded revision on this fresh work order (A12) -> value_conflict.
  event <- mk_event(mk_row(source_ref = "r1", work_order = "GH9801234",
                           feature_raw = "T.S02", analyte_raw = "Fluoride",
                           method_raw = "EK040P: Fluoride by PC Titrator",
                           cas_number = NA_character_, units_raw = "mg/L",
                           value_raw = P16_HAZARD2, value_num = NA_real_,
                           value_chr = P16_HAZARD2, below_detection = FALSE, rl = 0.1,
                           sample_datetime_raw = "01 Jun 2025"))
  out <- reconcile_event(event, con)
  hit <- out$review[out$review$kind == "value_conflict" &
                       !is.na(out$review$subkind) &
                       out$review$subkind == "measurement", , drop = FALSE]
  expect_equal(nrow(hit), 1)
  raw <- hit$payload[[1]]
  .p16_assert_hazard(raw, "value_chr_existing", P16_HAZARD)
  .p16_assert_hazard(raw, "value_chr_incoming", P16_HAZARD2)
})

test_that("R-16.10 property (9/18 - .rc_batch_duplicate): the winner's source_ref, carrying every hostile byte, round-trips as kept_source_ref", {
  path <- seed_db()
  con <- seed_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  event <- mk_event(mk_rows(
    mk_row(source_ref = P16_HAZARD, lab_sample_id = "XX1234567002", feature_raw = "T.S02",
           value_raw = "2.3", value_num = 2.3, below_detection = FALSE, rl = 0.1),
    mk_row(source_ref = "loser-ref", lab_sample_id = "XX1234567002", feature_raw = "T.S02",
           value_raw = "2.3", value_num = 2.3, below_detection = FALSE, rl = 0.1)
  ))
  out <- reconcile_event(event, con)
  hit <- out$review[out$review$source_ref == "loser-ref" & out$review$kind == "batch_duplicate", , drop = FALSE]
  expect_equal(nrow(hit), 1)
  .p16_assert_hazard(hit$payload[[1]], "kept_source_ref", P16_HAZARD)
})

test_that("R-16.10 property (11/18 - .fa_merge_samples, subkind='alias_merge'): TWO DISTINCT hostile-byte text values (existing vs incoming) round-trip through confirm_feature_aliases()'s real merge path", {
  path <- seed_db()
  con <- seed_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign,
     first_seen, last_seen, confirmed_by) VALUES
    (?, NULL, ?, ?, 'pending', 0, FALSE, TIMESTAMP '2025-08-01 08:00:00',
     TIMESTAMP '2025-08-01 08:00:00', NULL)",
    params = list("fa-9711", "T.HAZ711", "t.haz711"))
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign,
     first_seen, last_seen, confirmed_by) VALUES
    (?, NULL, ?, ?, 'pending', 0, FALSE, TIMESTAMP '2025-08-01 08:00:00',
     TIMESTAMP '2025-08-01 08:00:00', NULL)",
    params = list("fa-9712", "T.HAZ712", "t.haz712"))
  DBI::dbExecute(con, "INSERT INTO \"sample\"
    (uuid, uuid_feature_alias, uuid_project, date, datetime, organisation, person) VALUES
    ('s-9711', 'fa-9711', 'p-0001', TIMESTAMP '2025-08-01 00:00:00', TIMESTAMP '2025-08-01 09:00:00', 'ALS', NULL),
    ('s-9712', 'fa-9712', 'p-0001', TIMESTAMP '2025-08-01 00:00:00', TIMESTAMP '2025-08-01 14:00:00', 'ACIRL', 'J. Smith')")
  DBI::dbExecute(con, "INSERT INTO analysis
    (uuid, uuid_sample, uuid_lab, value, value_chr, quantified, rl_low) VALUES
    ('an-9711', 's-9711', 'lm-0002', NULL, ?, NULL, 0.1),
    ('an-9712', 's-9712', 'lm-0002', NULL, ?, NULL, 0.1)",
    params = list(P16_HAZARD, P16_HAZARD2))

  # fa-9711 confirmed FIRST (no override) -> winner; fa-9712 confirmed SECOND
  # with override=TRUE -> loser (verbatim precedence pattern from
  # mk_collision_fixture's own an-w2/an-l2 case above).
  confirm_feature_aliases("fa-9711", "f-0002", confirmed_by = "alice", db = path)
  confirm_feature_aliases("fa-9712", "f-0002", confirmed_by = "alice", override = TRUE, db = path)

  fa_hit <- DBI::dbGetQuery(con, "SELECT * FROM review_queue WHERE kind = 'value_conflict' AND subkind = 'alias_merge'")
  expect_equal(nrow(fa_hit), 1)
  raw <- fa_hit$payload[[1]]
  .p16_assert_hazard(raw, "value_chr_existing", P16_HAZARD)
  .p16_assert_hazard(raw, "value_chr_incoming", P16_HAZARD2)
})

test_that("R-16.10 property (12/18 - .am_confirm_one_method, units_drift): TWO DISTINCT hostile-byte historical unit strings both round-trip via confirm_analyte_methods()'s real change_log drift scan", {
  path <- seed_db()
  con <- seed_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  # lm-0008 is dangling (uuid_analyte NULL, R-11.11 fixture). Two distinct
  # historical `units` values on its change_log -> drift detected.
  DBI::dbExecute(con, "INSERT INTO change_log (uuid, \"at\", actor, action, tbl, uuid_row, field, old, new, reason, source_hash) VALUES
    (?, ?, 'tester', 'update', 'lab_method', 'lm-0008', 'units', NULL, ?, 'p16 fixture', NULL)",
    params = list(uuid::UUIDgenerate(), Sys.time(), P16_HAZARD))
  DBI::dbExecute(con, "INSERT INTO change_log (uuid, \"at\", actor, action, tbl, uuid_row, field, old, new, reason, source_hash) VALUES
    (?, ?, 'tester', 'update', 'lab_method', 'lm-0008', 'units', NULL, ?, 'p16 fixture', NULL)",
    params = list(uuid::UUIDgenerate(), Sys.time(), P16_HAZARD2))

  confirm_analyte_methods(uuid_lab = "lm-0008", uuid_analyte = "a-0003",
                          confirmed_by = "tester", db = path)

  hit <- DBI::dbGetQuery(con, "SELECT payload FROM review_queue WHERE kind = 'units_drift'")
  expect_equal(nrow(hit), 1)
  raw <- hit$payload[[1]]
  parsed <- tryCatch(jsonlite::fromJSON(raw), error = function(e) list())
  expect_true(setequal(parsed$units, c(P16_HAZARD, P16_HAZARD2)))
  expect_true(grepl(as.character(jsonlite::toJSON(P16_HAZARD, auto_unbox = TRUE)), raw, fixed = TRUE))
  expect_true(grepl(as.character(jsonlite::toJSON(P16_HAZARD2, auto_unbox = TRUE)), raw, fixed = TRUE))
})

test_that("R-16.10 property (13/18 - .am_confirm_one_method, unknown_unit): a hostile-byte units_from string round-trips via confirm_analyte_methods()'s real conversion-failure path", {
  path <- seed_db()
  con <- seed_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  # lm-0009 is dangling (uuid_analyte NULL, R-11.11 fixture); its recorded
  # `units` is overwritten with the hostile string DIRECTLY - fixture setup
  # simulating a hostile unit string arriving from source data, not exercised
  # via the mutation layer (the code under test is confirm_analyte_methods()'s
  # conversion-failure branch, not this setup UPDATE).
  DBI::dbExecute(con, "UPDATE lab_method SET units = ? WHERE uuid = 'lm-0009'", params = list(P16_HAZARD))

  confirm_analyte_methods(uuid_lab = "lm-0009", uuid_analyte = "a-0002",
                          confirmed_by = "tester", db = path)

  hit <- DBI::dbGetQuery(con, "SELECT payload FROM review_queue WHERE kind = 'unknown_unit'")
  expect_equal(nrow(hit), 1)
  .p16_assert_hazard(hit$payload[[1]], "units_from", P16_HAZARD)
})

test_that("R-16.10 property (14/18 - router.R adapter_tie): a hostile-byte adapter id round-trips through route_files()'s real tie-quarantine path", {
  clear_adapters()
  withr::defer({ clear_adapters(); register_builtin_adapters() })
  register_adapter(list(
    id = P16_HAZARD, version = "1.0",
    match = function(fm) if (grepl("HAZTIE", fm$filename)) "exact" else "no",
    parse = function(path, file_meta) list(results = ir_results(), samples = ir_samples(), report = list())
  ))
  register_adapter(list(
    id = "p16_normal_tie", version = "1.0",
    match = function(fm) if (grepl("HAZTIE", fm$filename)) "exact" else "no",
    parse = function(path, file_meta) list(results = ir_results(), samples = ir_samples(), report = list())
  ))

  dir <- withr::local_tempdir()
  db <- seed_db(dir)
  con <- seed_con(db)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  path <- st_test_write_file(dir, "ES1234567_HAZTIE_0_XTAB.csv", content = "a,b\n1,2\n")
  result <- route_files(c(path), con)
  expect_equal(result$state[[1]], "quarantined")
  expect_equal(result$reason[[1]], "adapter_tie")

  hit <- DBI::dbGetQuery(con, "SELECT payload FROM review_queue WHERE kind = 'adapter_tie'")
  expect_equal(nrow(hit), 1)
  raw <- hit$payload[[1]]
  parsed <- tryCatch(jsonlite::fromJSON(raw), error = function(e) list())
  expect_true(P16_HAZARD %in% parsed$adapters)
  expect_true(grepl(as.character(jsonlite::toJSON(P16_HAZARD, auto_unbox = TRUE)), raw, fixed = TRUE))
})

# ---- PLAN-7b round-3 finding 3/item 4: the four producers the "14 producers"
# enumeration omitted. Two carry source-controlled free text (#15, #16 -
# real hostile-byte round-trips, same style as #1-#5); two carry uuids/dates
# only, generated internally, never caller-supplied free text (#17, #18 -
# explicitly-vacuous, same style as #6). ---------------------------------

test_that("R-16.10 property (15/18 - .rc_self_precedence_notes, subkind='self_precedence_note'): feature_raw carrying every hostile byte round-trips - a REAL producer this enumeration omitted entirely (grep: 'self_precedence_note' occurred 0 times in this file before this test)", {
  path <- seed_db()
  con <- seed_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  # A fresh (site, point) self+historical arm pair sharing ONE alias_key
  # that folds from a hostile-byte feature_raw (R1: the self arm wins over
  # the shadowed historical arm and the row RESOLVES, with a non-blocking
  # self_precedence_note naming the raw feature text).
  DBI::dbExecute(con, "INSERT INTO feature (uuid, name, site, flow, matrix, date_end, lon, lat) VALUES
    ('f-p16sp-a', 'P16 Self A', 'T', 'surface', 'water', NULL, 150.9101, -33.9101),
    ('f-p16sp-b', 'P16 Historical B', 'T', 'surface', 'water', NULL, 150.9102, -33.9102)")

  hazard_feature_raw <- paste0("SELFHAZ.", P16_HAZARD)
  key <- .rc_feature_key(hazard_feature_raw)
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign,
     first_seen, last_seen, confirmed_by) VALUES
    ('fa-p16sp-self', 'f-p16sp-a', ?, ?, 'self', 0, TRUE,
     TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00', NULL),
    ('fa-p16sp-hist', 'f-p16sp-b', ?, ?, 'historical_code', 0, TRUE,
     TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00', NULL)",
    params = list(hazard_feature_raw, key, hazard_feature_raw, key))

  event <- mk_event(mk_row(source_ref = "r1", feature_raw = hazard_feature_raw,
                           lab_sample_id = "XX9999991003",
                           sample_datetime_raw = "08 Jun 2025 09:00"))
  out <- reconcile_event(event, con)
  note <- out$review[out$review$kind == "unknown_feature" & !is.na(out$review$subkind) &
                        out$review$subkind == "self_precedence_note", , drop = FALSE]
  expect_equal(nrow(note), 1)
  .p16_assert_hazard(note$payload[[1]], "feature_raw", hazard_feature_raw)
})

test_that("R-16.10 property (16/18 - .rc_analyte_review, subkind='held'): analyte_raw carrying the hostile PUNCTUATION subset round-trips - a REAL producer this enumeration omitted entirely, added THIS round (grep: 'held' as a subkind oracle occurred 0 times in this file before this test)", {
  path <- seed_db()
  con <- seed_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  # HELD requires analyte_raw to fold to NOTHING (.rc_method_key strips every
  # non-alnum character; a held row can therefore never carry the FULL
  # P16_HAZARD, which has alnum content by construction) - so this uses the
  # punctuation-only SUBSET of the same shared hazard set: comma, apostrophe,
  # pipe, `=`, `"`, `\`, tab, newline. µ is a letter (alnum), not punctuation,
  # and is excluded for the same reason.
  hazard_held <- paste0(",", "'", "|", "=", "\"", "\\", "\t", "\n")
  event <- mk_event(mk_row(source_ref = "r1", analyte_raw = hazard_held, org = "ALS",
                           cas_number = NA_character_,
                           lab_sample_id = "XX9999991004", sample_datetime_raw = "08 Jun 2025 09:00"))
  out <- reconcile_event(event, con)
  hit <- out$review[out$review$kind == "unknown_analyte" & !is.na(out$review$subkind) &
                       out$review$subkind == "held", , drop = FALSE]
  expect_equal(nrow(hit), 1)
  .p16_assert_hazard(hit$payload[[1]], "analyte_raw", hazard_held)
})

test_that("R-16.10 property (17/18 - .ct_reingest_guard, kind='work_order_reingest'): NOT DRIVEN WITH HOSTILE-BYTE FREE TEXT IN A DIAGNOSTICS FIELD - `diagnostics$work_order` carries the SAME string as the typed `work_order` column (an identifier, driven through the real production path so the round-trip claim is verified, not merely asserted from the sidelines)", {
  path <- seed_db()
  con <- seed_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  wo_hazard <- P16_HAZARD
  DBI::dbExecute(con, "INSERT INTO project (uuid, name, type) VALUES ('p-p16wo', ?, 'Work order')",
                 params = list(wo_hazard))
  DBI::dbExecute(con, "INSERT INTO \"sample\" (uuid, uuid_feature_alias, uuid_project, date, organisation) VALUES
    ('s-p16wo', 'fa-0001', 'p-p16wo', TIMESTAMP '2025-06-01 00:00:00', 'ALS')")
  DBI::dbExecute(con, "INSERT INTO asset (uuid, uuid_project, hash, filename) VALUES
    ('as-p16wo', 'p-p16wo', 'hash-prior-p16', 'prior.csv')")

  # A second, unmatched clean row for the SAME (hostile-byte) work order -
  # the guard's real trigger shape (R-15.31/R-15.32), driven via the real
  # reconcile_event() -> .ct_reingest_guard() path, never a hand-built row.
  event <- mk_event(mk_row(source_ref = "r1", source_hash = "hash-p16wo-own",
                           work_order = wo_hazard, lab_sample_id = "XX1234567002",
                           feature_raw = "T.S02", sample_datetime_raw = "09 Jun 2025 09:00"),
                     work_order = wo_hazard)
  out <- reconcile_event(event, con)
  guard_rows <- .ct_reingest_guard(con, event, out)
  expect_false(is.null(guard_rows))
  expect_equal(nrow(guard_rows), 1)
  expect_identical(guard_rows$kind[[1]], "work_order_reingest")
  expect_identical(guard_rows$work_order[[1]], wo_hazard)
  .p16_assert_hazard(guard_rows$payload[[1]], "work_order", wo_hazard)
})

test_that("R-16.10 property (18/18 - .fa_confirm_one_alias, kind='sample_collision'): NOT DRIVEN WITH HOSTILE BYTES - vacuous like #6, confirmed empirically: this producer's diagnostics carry only internally-generated uuids and a derived date, never the alias's own (potentially hostile) name/alias_key text", {
  path <- seed_db()
  con <- seed_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  # The alias NAME itself carries hostile bytes, to prove empirically (not
  # merely assert) that they do NOT reach the payload - the same-alias,
  # same-date collision shape from test-feature-alias.R's own D5 fixture.
  hazard_name <- paste0("T.SELFCOLL16.", P16_HAZARD)
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign,
     first_seen, last_seen, confirmed_by) VALUES
    (?, NULL, ?, ?, 'pending', 0, FALSE, TIMESTAMP '2025-08-05 08:00:00',
     TIMESTAMP '2025-08-05 08:00:00', NULL)",
    params = list("fa-p16sc", hazard_name, .rc_feature_key(hazard_name)))
  DBI::dbExecute(con, "INSERT INTO \"sample\"
    (uuid, uuid_feature_alias, uuid_project, date, datetime, organisation, person) VALUES
    ('s-p16sc1', 'fa-p16sc', 'p-0001', TIMESTAMP '2025-08-05 00:00:00', TIMESTAMP '2025-08-05 09:00:00', 'ALS', NULL),
    ('s-p16sc2', 'fa-p16sc', 'p-0001', TIMESTAMP '2025-08-05 00:00:00', TIMESTAMP '2025-08-05 14:00:00', 'ACIRL', 'J. Smith')")

  confirm_feature_aliases("fa-p16sc", "f-0002", confirmed_by = "tester", db = path)

  review <- DBI::dbGetQuery(con, "SELECT payload FROM review_queue WHERE kind = 'sample_collision'")
  expect_equal(nrow(review), 1)
  parsed <- jsonlite::fromJSON(review$payload[[1]])
  expect_setequal(names(parsed), c("uuid_feature", "collision_date", "uuid_sample_a", "uuid_sample_b"))
  expect_false(grepl(hazard_name, review$payload[[1]], fixed = TRUE))
})

# ---- producer 10/18: assembly's STAGE-0 inline review-flag fold-in, plus the
# shared .rq_skip() carrier - RETAINED FROM ROUND 2 (these are the "2 of 14"
# round 3 found already covered; not duplicated above). ------------------------

test_that("R-16.10 (10/18 - reconcile_event()'s STAGE-0 fold-in of assembly's inline review flags): an analyte/value pair carrying comma, apostrophe, pipe, equals, DOUBLE QUOTE, BACKSLASH, tab, newline and a non-ASCII character round-trips byte-identical through JSON diagnostics, with the RAW STORED TEXT (not just the fromJSON()-parsed value) carrying correct JSON escaping (the criterion the plan exists for - RED against today's k=v payload, and RED again against a serialiser that silently strips the two characters JSON must escape)", {
  path <- seed_db()
  con <- seed_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  # Comma/apostrophe (original hazard) PLUS the two characters JSON escaping
  # actually has to do work on (" and \\), plus a non-ASCII char - all kept,
  # none traded away.
  hazard_analyte <- "2,2',3,3',4,4'-Hexachlorobiphenyl \"technical\" C:\\lab\\ref \u00b5g/kg"
  # Pipe/equals/comma (original hazard) PLUS a tab and an embedded newline.
  hazard_value <- "a|b=c,d\ttab\nline"

  row <- mk_row(source_ref = "r1")
  row$needs_review <- TRUE
  row$review_kind <- "value_conflict"
  row$review_payload <- list(list(subkind = "manual_note", analyte = hazard_analyte, value = hazard_value))
  event <- mk_event(row)

  # REAL producer: reconcile_event()'s STAGE-0 fold-in (R-11.14) serialises
  # this diagnostics list via the REAL .rq_row()/.rq_serialise_diagnostics()
  # (R/db-schema.R) - the shared JSON policy point this whole plan exists to
  # install in place of the deleted, unescaped paste0() k=v joiner.
  out <- reconcile_event(event, con)
  hit <- out$review[out$review$kind == "value_conflict", , drop = FALSE]
  expect_equal(nrow(hit), 1)

  # REAL downstream writer (FF12 fix): a genuine commit_event() call, not a
  # test-local reimplementation of .ct_commit_review()'s insert.
  commit_event(mk_commit_event(.p16_empty_files()), mk_resolved(review = hit), con)

  stored <- DBI::dbGetQuery(con, "SELECT payload FROM review_queue WHERE kind = 'value_conflict'")
  expect_equal(nrow(stored), 1)
  raw <- stored$payload[[1]]

  # ---- raw-text assertions: a serialiser that silently DROPS " or \\ from a
  # character value (rather than escaping it) still parses back to something
  # via fromJSON() on the surviving characters, so the parsed-value check
  # alone cannot see that mutant. Compare the raw stored TEXT against
  # jsonlite's own correctly-escaped rendering of each hazard string, so a
  # serialiser that mangles either character breaks this fragment match.
  expected_analyte_json <- as.character(jsonlite::toJSON(hazard_analyte, auto_unbox = TRUE))
  expected_value_json <- as.character(jsonlite::toJSON(hazard_value, auto_unbox = TRUE))
  expect_true(grepl(expected_analyte_json, raw, fixed = TRUE))
  expect_true(grepl(expected_value_json, raw, fixed = TRUE))

  # Minimum bar named in the plan: the raw text must literally CONTAIN the
  # escaped forms \" and \\ (2-character sequences: backslash+quote,
  # backslash+backslash) - not the bare, unescaped " / \\ that a
  # character-stripping serialiser would leave behind instead.
  expect_true(grepl('\\"', raw, fixed = TRUE))
  expect_true(grepl('\\\\', raw, fixed = TRUE))
  expect_true(grepl('\\t', raw, fixed = TRUE))
  expect_true(grepl('\\n', raw, fixed = TRUE))

  diagnostics <- tryCatch(jsonlite::fromJSON(raw), error = function(e) list())
  expect_identical(diagnostics$analyte, hazard_analyte)
  expect_identical(diagnostics$value, hazard_value)
})

test_that("R-16.10 (shared serialiser, not one of the 18 producer sites): .rq_skip() shares .rq_serialise_diagnostics() with .rq_row(), so the same hostile analyte/value round-trips byte-identical there too, with the raw payload text carrying correct JSON escaping", {
  hazard_analyte <- "2,2',3,3',4,4'-Hexachlorobiphenyl \"technical\" C:\\lab\\ref \u00b5g/kg"
  hazard_value <- "a|b=c,d\ttab\nline"

  rq <- .rq_skip(existing_uuid = "an-0001",
                 diagnostics = list(analyte = hazard_analyte, value = hazard_value))
  raw <- rq$payload

  expected_analyte_json <- as.character(jsonlite::toJSON(hazard_analyte, auto_unbox = TRUE))
  expected_value_json <- as.character(jsonlite::toJSON(hazard_value, auto_unbox = TRUE))
  expect_true(grepl(expected_analyte_json, raw, fixed = TRUE))
  expect_true(grepl(expected_value_json, raw, fixed = TRUE))
  expect_true(grepl('\\"', raw, fixed = TRUE))
  expect_true(grepl('\\\\', raw, fixed = TRUE))
  expect_true(grepl('\\t', raw, fixed = TRUE))
  expect_true(grepl('\\n', raw, fixed = TRUE))

  diagnostics <- tryCatch(jsonlite::fromJSON(raw), error = function(e) list())
  expect_identical(diagnostics$analyte, hazard_analyte)
  expect_identical(diagnostics$value, hazard_value)
})

# ==============================================================================
# R-16.11: a structural review exposes site and point as separate retrievable
# values; no stored value contains an embedded k=v fragment
# ==============================================================================

test_that("R-16.11: a structural (subkind='structural') review exposes site and point as separate retrievable diagnostics, never glued as an embedded k=v fragment", {
  path <- seed_db()
  con <- seed_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  # Reuses the proven R-15.1/R-15.2/R-15.3/B.7 fixture verbatim: site 'T'
  # recognised, point 'S88' unmatched -> subkind=structural, site=T, point=S88.
  event <- mk_event(mk_rows(
    mk_row(source_ref = "miss", feature_raw = "T S88", lab_sample_id = "XX9999990001",
           sample_datetime_raw = "08 Jun 2025 09:00"),
    mk_row(source_ref = "hit", feature_raw = "T S01", lab_sample_id = "XX9999990002",
           sample_datetime_raw = "08 Jun 2025 09:00")
  ))
  out <- reconcile_event(event, con)
  rv <- out$review[out$review$kind == "unknown_feature" & grepl("miss", out$review$source_ref), , drop = FALSE]
  expect_equal(nrow(rv), 1)

  subkind <- if ("subkind" %in% names(out$review)) rv$subkind[[1]] else NA_character_
  expect_identical(subkind, "structural")

  diagnostics <- tryCatch(jsonlite::fromJSON(rv$payload[[1]]), error = function(e) list())
  expect_identical(diagnostics$site, "T")
  expect_identical(diagnostics$point, "S88")

  # No stored diagnostic VALUE is itself an embedded k=v fragment (the old
  # glued "site=T,point=S88" shape this criterion retires).
  leaf_values <- as.character(unlist(diagnostics, use.names = FALSE))
  expect_false(any(grepl("=", leaf_values, fixed = TRUE)))
})

# ==============================================================================
# R-16.14: already_present resolves without the regex fallback
# (paired with R-16.17's already_present sub-criterion - same structured
# field, so one test covers both rather than duplicating the assertion)
# ==============================================================================

test_that("R-16.14/R-16.17: already_present's existing_uuid is a real, always-populated column on the SKIP tibble reconcile_event() returns, matching the uuid the retired regex fallback recovers for the same bare-uuid input", {
  path <- seed_db()
  con <- seed_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  # Exactly the FIXTURES.md pinned "<0.1 mg/L" row - converts to 100 ug/L,
  # matching seeded an-0001 (value 100, quantified FALSE): already_present.
  event <- mk_event(mk_row(source_ref = "r1"))
  out <- reconcile_event(event, con)

  hit <- out$skipped[out$skipped$reason == "already_present", , drop = FALSE]
  expect_equal(nrow(hit), 1)

  # ORACLE is the SEEDED existing uuid, pinned directly - never through
  # .ct_skip_existing_uuid() (the retired regex fallback R-16.14 removes): an
  # oracle must not be the function under test. This <0.1 mg/L -> 100 ug/L row
  # resolves to the seeded analysis row an-0001 (helper-db.R:498, value 100 /
  # quantified FALSE) -> reason already_present.
  # existing_uuid is a real column on the RETURNED skip tibble carrying that
  # uuid - RED today (column absent from the real reconcile_event() shape,
  # B-16.skips); GREEN once the structured column lands in Phase 6.
  existing_uuid <- if ("existing_uuid" %in% names(out$skipped)) hit$existing_uuid[[1]] else NA_character_
  expect_identical(existing_uuid, "an-0001")
})

# ==============================================================================
# R-16.17: the five previously-uncovered producers have their structured
# content pinned (unknown_unit/parse_error/batch_duplicate on the review
# tibble; already_present covered above; method_duplicate on the skip
# tibble)
# ==============================================================================

test_that("R-16.17 (unknown_unit): units_raw/analyte/value_raw are separate retrievable diagnostics, not glued k=v text", {
  path <- seed_db()
  con <- seed_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  event <- mk_event(mk_row(source_ref = "r1", units_raw = "banana/L"))
  out <- reconcile_event(event, con)
  hit <- out$review[out$review$kind == "unknown_unit", , drop = FALSE]
  expect_equal(nrow(hit), 1)

  diagnostics <- tryCatch(jsonlite::fromJSON(hit$payload[[1]]), error = function(e) list())
  expect_identical(diagnostics$units_raw, "banana/L")
  expect_identical(diagnostics$analyte, "Fluoride")
  expect_identical(diagnostics$value_raw, "<0.1")
})

test_that("R-16.17 (parse_error): subkind='datetime' is a real column and sample_datetime_raw is a separate retrievable diagnostic", {
  path <- seed_db()
  con <- seed_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  event <- mk_event(mk_row(source_ref = "r1", sample_datetime_raw = "not a date"))
  out <- reconcile_event(event, con)
  hit <- out$review[out$review$kind == "parse_error", , drop = FALSE]
  expect_equal(nrow(hit), 1)

  subkind <- if ("subkind" %in% names(out$review)) hit$subkind[[1]] else NA_character_
  expect_identical(subkind, "datetime")

  diagnostics <- tryCatch(jsonlite::fromJSON(hit$payload[[1]]), error = function(e) list())
  expect_identical(diagnostics$sample_datetime_raw, "not a date")
})

test_that("R-16.17 (batch_duplicate): kept_source_ref is a separate retrievable diagnostic, not glued to the loser's own source_ref", {
  path <- seed_db()
  con <- seed_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  # Reuses the proven R-12.13 within-batch guard fixture verbatim: two
  # identical-key rows, one wins clean, the other -> review batch_duplicate.
  event <- mk_event(mk_rows(
    mk_row(source_ref = "r1", lab_sample_id = "XX1234567002", feature_raw = "T.S02",
           value_raw = "2.3", value_num = 2.3, below_detection = FALSE, rl = 0.1),
    mk_row(source_ref = "r2", lab_sample_id = "XX1234567002", feature_raw = "T.S02",
           value_raw = "2.3", value_num = 2.3, below_detection = FALSE, rl = 0.1)
  ))
  out <- reconcile_event(event, con)

  winner <- intersect(c("r1", "r2"), out$clean$source_ref)
  loser <- setdiff(c("r1", "r2"), out$clean$source_ref)
  expect_equal(length(winner), 1)
  expect_equal(length(loser), 1)

  hit <- out$review[out$review$source_ref == loser, , drop = FALSE]
  expect_equal(nrow(hit), 1)
  expect_identical(hit$kind[[1]], "batch_duplicate")

  diagnostics <- tryCatch(jsonlite::fromJSON(hit$payload[[1]]), error = function(e) list())
  expect_identical(diagnostics$kept_source_ref, winner)
})

test_that("R-16.17 (method_duplicate): kept_uuid_lab is a real column on the SKIP tibble reconcile_event() returns", {
  path <- seed_db()
  con <- seed_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  # Reuses the proven R-8.6 method-preference fixture verbatim: r1 (lm-0002,
  # rl_low 0.1) wins, r2 (lm-0004, rl_low 0.5) loses -> method_duplicate.
  event <- mk_event(mk_rows(
    mk_row(source_ref = "r1", lab_sample_id = "XX1234567002", feature_raw = "T.S02",
           method_raw = "EK040P: Fluoride by PC Titrator",
           value_raw = "2.3", value_num = 2.3, below_detection = FALSE, rl = 0.1),
    mk_row(source_ref = "r2", lab_sample_id = "XX1234567002", feature_raw = "T.S02",
           method_raw = "EK040T: Fluoride by alt method",
           value_raw = "2.5", value_num = 2.5, below_detection = FALSE, rl = 0.5)
  ))
  out <- reconcile_event(event, con)

  hit <- out$skipped[out$skipped$source_ref == "r2", , drop = FALSE]
  expect_equal(nrow(hit), 1)
  expect_identical(hit$reason[[1]], "method_duplicate")

  kept_uuid_lab <- if ("kept_uuid_lab" %in% names(out$skipped)) hit$kept_uuid_lab[[1]] else NA_character_
  expect_identical(kept_uuid_lab, "lm-0002")
})

# ==============================================================================
# R-16.18: the structured constructor accepts no free-text payload argument
# ==============================================================================

test_that("R-16.18: .rq_row() has no free-text payload argument and rejects a pre-serialised k=v string passed where diagnostics belongs", {
  has_ctor <- exists(".rq_row", mode = "function")
  expect_true(has_ctor)

  arg_names <- if (has_ctor) names(formals(get(".rq_row", mode = "function"))) else character(0)

  # B-16.api's pinned signature: kind, subkind, work_order, source_hash,
  # uuid_existing, uuid_alias, candidates, expired, diagnostics - no `payload`
  # argument anywhere.
  expect_false("payload" %in% arg_names)
  expect_true(all(c("kind", "diagnostics") %in% arg_names))

  # The fixture-hazard mitigation is structural, not vigilance (B-16.api /
  # "The fixture hazard"): a hand-built k=v string passed where `diagnostics`
  # (a named list) belongs must be REJECTED, not silently written through.
  if (has_ctor) {
    ctor <- get(".rq_row", mode = "function")
    expect_error(ctor(kind = "value_conflict", diagnostics = "existing_uuid=an-0001,value=1"),
                 regexp = "type 'list'")
  }
})

# ==============================================================================
# R-16.19 + R-16.20: value_conflict is discriminated by subkind (not two
# grammars), and the two producers share one vocabulary - asserted together
# so the pair cannot drift apart again
# ==============================================================================

test_that("R-16.19/R-16.20: both value_conflict producers (.rc subkind='measurement', .fa_merge_samples subkind='alias_merge') populate uuid_existing, and their diagnostics key sets match exactly on the shared subset", {
  path <- seed_db()
  con <- seed_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  # ---- producer 1: .rc (R/reconcile.R .rc_three_way), subkind='measurement' ----
  # Verbatim copy of the proven "R-8.7: conflict with no recorded revision
  # queues for review" fixture: a fresh work order with no ingest_file/asset
  # history -> recorded revision NA -> A12 "no recorded revision -> review".
  DBI::dbExecute(con, "INSERT INTO project (uuid, name, type) VALUES ('p-0002', 'CD2222222', 'Work order')")
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
  rc_hit <- out$review[out$review$source_ref == "r1" & out$review$kind == "value_conflict", , drop = FALSE]
  expect_equal(nrow(rc_hit), 1)

  rc_subkind <- if ("subkind" %in% names(out$review)) rc_hit$subkind[[1]] else NA_character_
  expect_identical(rc_subkind, "measurement")
  rc_uuid_existing <- if ("uuid_existing" %in% names(out$review)) rc_hit$uuid_existing[[1]] else NA_character_
  expect_identical(rc_uuid_existing, "an-0102")

  rc_diag <- tryCatch(jsonlite::fromJSON(rc_hit$payload[[1]]), error = function(e) list())

  # R-16.20: uuid_incoming is ABSENT (not NA) for subkind='measurement' - at
  # conflict time the incoming value is not yet a row and has no uuid.
  expect_false("uuid_incoming" %in% names(rc_diag))
  # ...and it is absent from the TYPED column too, which is a separate claim
  # from the payload one above. Robin's round-2 ruling 2 added
  # `review_queue.uuid_incoming` (schema ladder v7) so an operator can compare
  # both rows of a value conflict; this producer genuinely has no incoming row
  # to name, so NA here is correct and must stay NA. Asserting only the
  # payload would let a future change populate the column for `measurement`
  # with something invented and nothing would notice.
  rc_uuid_incoming <- if ("uuid_incoming" %in% names(rc_hit)) rc_hit$uuid_incoming[[1]] else NA_character_
  expect_true(is.na(rc_uuid_incoming))
  # forbidden legacy/mixed-vocabulary key names must not survive anywhere.
  expect_false(any(c("existing_value", "incoming_value", "value_new", "uuid_new") %in% names(rc_diag)))

  # ---- producer 2: .fa_merge_samples (R/feature-alias.R:215-250), subkind='alias_merge' ----
  mk_collision_fixture(con)
  confirm_feature_aliases("fa-9001", "f-0002", confirmed_by = "alice", db = path)
  confirm_feature_aliases("fa-9002", "f-0002", confirmed_by = "alice", override = TRUE, db = path)

  fa_hit <- DBI::dbGetQuery(con, "SELECT * FROM review_queue WHERE kind = 'value_conflict'")
  expect_equal(nrow(fa_hit), 1)

  fa_subkind <- if ("subkind" %in% names(fa_hit)) fa_hit$subkind[[1]] else NA_character_
  expect_identical(fa_subkind, "alias_merge")
  fa_uuid_existing <- if ("uuid_existing" %in% names(fa_hit)) fa_hit$uuid_existing[[1]] else NA_character_
  expect_identical(fa_uuid_existing, "an-w2")
  # R-16.20 under Robin's round-2 ruling 2: THIS producer must name both
  # sides. `an-l2` is the loser's analysis - re-pointed onto the winner
  # sample by `.fa_merge_samples()`, never deleted - so unlike the
  # `measurement` producer above there IS an incoming uuid to record, and the
  # plan (PLAN-11 R-11.10) requires it. This is the assertion that
  # discriminates the ruling: before it, the column was written but nothing
  # read it, and a producer that silently stopped populating it stayed green.
  fa_uuid_incoming <- if ("uuid_incoming" %in% names(fa_hit)) fa_hit$uuid_incoming[[1]] else NA_character_
  expect_identical(fa_uuid_incoming, "an-l2")

  fa_diag <- tryCatch(jsonlite::fromJSON(fa_hit$payload[[1]]), error = function(e) list())
  expect_false(any(c("existing_value", "incoming_value", "value_new", "uuid_new") %in% names(fa_diag)))

  # R-16.20: compare the two producers' diagnostics KEY SETS TO EACH OTHER,
  # not to a hardcoded list. The shared subset must match EXACTLY
  # (value_existing/value_incoming); reconcile-only extras
  # (quantified_*/revision_*) are the ONLY permitted difference.
  rc_keys <- sort(names(rc_diag))
  fa_keys <- sort(names(fa_diag))
  # `source_ref`/`n_rows` are reconcile-only BOOKKEEPING, added to diagnostics
  # under Q2 (Robin, 2026-07-25). They are exempt from the cross-producer
  # comparison for a verified reason, not to make this block pass: the
  # `review_queue` TABLE has no source_ref or n_rows column (R/db-schema.R
  # v3 DDL), so for a reconcile row these two values exist only on the
  # in-memory tibble and were being DROPPED at the commit boundary - which is
  # what Q2 fixes. `.fa_merge_samples()` has no source-row concept at all: it
  # compares two already-committed analyses, so there is no incoming ref to
  # record and no row count to report. Absent there is correct, not missing.
  extras_permitted <- c("quantified_existing", "quantified_incoming",
                        "revision_existing", "revision_incoming",
                        "source_ref", "n_rows")
  rc_shared <- setdiff(rc_keys, extras_permitted)
  expect_true(setequal(rc_shared, fa_keys))
  expect_true(all(c("value_existing", "value_incoming") %in% rc_shared))
  expect_true(all(c("value_existing", "value_incoming") %in% fa_keys))

  # Q2, pinned POSITIVELY: widening `extras_permitted` above without asserting
  # what was exempted would be a pure weakening. The reconcile producer must
  # actually CARRY both keys, `source_ref` must be the fixture's own ref (so a
  # constant or a dropped value cannot pass), and `n_rows` must arrive as a
  # NUMBER - the retired migration could only ever recover the string it had
  # parsed out of k=v text, so a string here would mean the value is
  # travelling as text again. NOTE: `rc_diag` is parsed from the IN-MEMORY
  # reconcile tibble, not from the DB - the commit-boundary round-trip for
  # these keys is asserted separately in test-commit.R, because review_queue
  # has no source_ref/n_rows column for them to land in.
  expect_true(all(c("source_ref", "n_rows") %in% rc_keys))
  expect_identical(rc_diag$source_ref, "r1")
  expect_true(is.numeric(rc_diag$n_rows))
  expect_identical(as.integer(rc_diag$n_rows), 1L)
  # ...and the feature-alias producer must NOT invent them.
  expect_false(any(c("source_ref", "n_rows") %in% fa_keys))

  # F8 (Phase-7b round-3 remediation): `extras_permitted` above is a PERMIT
  # list - it allows the four reconcile-only vocabulary keys to be present,
  # but nothing before this point REQUIRED them, so slice I could delete all
  # four from the producer and this block stayed green. Positive pinning,
  # mirroring the source_ref/n_rows pattern immediately above: presence AND
  # value, not just permitted absence, so a future deletion fails here again.
  expect_true(all(c("quantified_existing", "quantified_incoming",
                    "revision_existing", "revision_incoming") %in% rc_keys))
  # This fixture's incoming/existing values are both genuine numeric readings
  # (600 / 0.5, both parsed quantified=TRUE) - both keys must carry TRUE.
  expect_identical(rc_diag$quantified_existing, TRUE)
  expect_identical(rc_diag$quantified_incoming, TRUE)
  # revision_existing is genuinely NA in this fixture (A12's "no recorded
  # revision" scenario): NA_integer_ serialises to JSON null (FB2's policy),
  # so the correctly round-tripped reading is a PRESENT key whose value is
  # NULL (not a missing key, not the string "NA" - see FB2 above).
  expect_true("revision_existing" %in% names(rc_diag))
  expect_true(is.null(rc_diag$revision_existing))
  expect_true(is.numeric(rc_diag$revision_incoming))
  expect_identical(as.integer(rc_diag$revision_incoming), 5L)
  # ...and the feature-alias producer must NOT invent any of the four either
  # (it has no revision/quantified concept - both analyses are already
  # committed rows, not incoming-vs-recorded-revision comparisons).
  expect_false(any(c("quantified_existing", "quantified_incoming",
                     "revision_existing", "revision_incoming") %in% fa_keys))
})

# ==============================================================================
# Phase-7b remediation (FB1/FB2/FB3/FB4/FA7): .rq_serialise_diagnostics()'s
# fixed serialisation policy, driven through the REAL DuckDB driver so
# jsonlite::fromJSON()'s own normalisation cannot hide a policy regression -
# at least one assertion below reads the stored payload TEXT directly.
# ==============================================================================

test_that("FB1: a diagnostic near 1e-4 round-trips through the REAL driver byte-identically (jsonlite's default digits = 4 would round it to 0.0001)", {
  path <- seed_db()
  con <- seed_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  uuid_written <- review_queue_add(
    con, kind = "value_conflict",
    diagnostics = list(value_existing = 0.000123456, value_incoming = 0.000987654)
  )

  stored <- DBI::dbGetQuery(con, "SELECT payload FROM review_queue WHERE uuid = ?",
                             params = list(uuid_written))
  diagnostics <- jsonlite::fromJSON(stored$payload[[1]])
  expect_identical(diagnostics$value_existing, 0.000123456)
  expect_identical(diagnostics$value_incoming, 0.000987654)
  # shape check: the raw stored text carries full precision, not "0.0001".
  expect_true(grepl("0.000123456", stored$payload[[1]], fixed = TRUE))
})

test_that("FB2: NA_real_/NA_integer_ diagnostics serialise to JSON null and read back as NA (not the string \"NA\")", {
  path <- seed_db()
  con <- seed_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  uuid_written <- review_queue_add(
    con, kind = "value_conflict",
    diagnostics = list(value_existing = NA_real_, revision_existing = NA_integer_)
  )

  stored <- DBI::dbGetQuery(con, "SELECT payload FROM review_queue WHERE uuid = ?",
                             params = list(uuid_written))
  # shape check on the raw TEXT: null, never the quoted string "NA".
  expect_true(grepl("\"value_existing\":null", stored$payload[[1]], fixed = TRUE))
  expect_true(grepl("\"revision_existing\":null", stored$payload[[1]], fixed = TRUE))
  expect_false(grepl("\"NA\"", stored$payload[[1]], fixed = TRUE))

  # jsonlite::fromJSON() maps a bare top-level JSON `null` to R `NULL` (not
  # `NA`) - that IS the correct, type-preserving reading (the field is simply
  # absent, exactly like a JSON object with the key omitted), and the
  # standard `if (is.null(x)) NA else x` coalesce recovers a true NA cleanly.
  # The old bug is what this guards against: with the string "NA" instead,
  # that same coalesce would silently keep the WRONG value ("NA", a string),
  # not flag it as missing.
  diagnostics <- jsonlite::fromJSON(stored$payload[[1]])
  expect_true(is.null(diagnostics$value_existing))
  expect_false(identical(diagnostics$value_existing, "NA"))
  value_existing <- if (is.null(diagnostics$value_existing)) NA_real_ else diagnostics$value_existing
  expect_true(is.na(value_existing))
  expect_true(is.numeric(value_existing))
})

test_that("FB3: an empty diagnostics list stores the JSON OBJECT \"{}\", never toJSON()'s default JSON ARRAY \"[]\"", {
  path <- seed_db()
  con <- seed_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  uuid_written <- review_queue_add(con, kind = "unknown_feature", subkind = "structural")

  stored <- DBI::dbGetQuery(con, "SELECT payload FROM review_queue WHERE uuid = ?",
                             params = list(uuid_written))
  # fromJSON() cannot distinguish "{}" from "[]" (both -> list()), so this
  # MUST be asserted on the raw stored TEXT.
  expect_identical(stored$payload[[1]], "{}")
})

test_that("FA7: .rq_row()/.rq_skip() reject an UNNAMED diagnostics list (a hand-built k=v blob wrapped in list())", {
  expect_error(.rq_row(kind = "x", diagnostics = list("existing_uuid=an-0001,value=1")),
               regexp = "[Mm]ust have names")
  expect_error(.rq_row(kind = "x", diagnostics = list("a=1", site = "T")),
               regexp = "[Mm]ust have names")
  expect_error(.rq_skip(diagnostics = list("existing_uuid=an-0001,value=1")),
               regexp = "[Mm]ust have names")
})

test_that("FB4a (pre-write rejection, Phase-7b round-3): .rq_row()'s candidates validation (W1's landed change) rejects an NA element and, separately, an empty-string element BEFORE any DB write - review_queue and review_queue_candidate counts are unchanged either way", {
  path <- seed_db()
  con <- seed_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  before_review <- DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM review_queue")$n
  before_cand <- DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM review_queue_candidate")$n

  expect_error(
    review_queue_add(con, kind = "unknown_feature", candidates = c("ok1", NA_character_)),
    regexp = "[Cc]ontains missing values"
  )
  expect_error(
    review_queue_add(con, kind = "unknown_feature", candidates = c("ok1", "")),
    regexp = "at least 1 character"
  )

  after_review <- DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM review_queue")$n
  after_cand <- DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM review_queue_candidate")$n
  expect_identical(after_review, before_review)
  expect_identical(after_cand, before_cand)
})

test_that("FB4b (transactional atomicity - FB4's original subject, mechanism updated for W1's stricter constructor): a failing SECOND review_queue_add() call that reaches the real DB insert leaves NO extra review_queue or review_queue_candidate rows behind", {
  path <- seed_db()
  con <- seed_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  # W1's .rq_row() validation (checkmate::assert_character(any.missing=FALSE,
  # min.chars=1L), landed on BOTH `candidates` and `expired$uuid_feature` -
  # Round-3 audit H9) now rejects every previously-reachable bad-CHILD-
  # content trigger BEFORE either db_append() call runs (see FB4a above) - so
  # the pre-round-3 "NA candidate reaches the DB and fails the CHILD insert
  # while the PARENT has already succeeded" scenario is no longer reachable
  # through review_queue_add()'s public surface at all. Confirmed empirically
  # (not assumed): a scratchpad copy of R/db-schema.R with the outer
  # db_transaction() wrapper removed reproduces IDENTICAL counts for this
  # scenario, because the failure below occurs on review_queue's OWN primary
  # key - the FIRST statement inside the transaction - so the child db_append()
  # is never even attempted, with or without the wrapper. A single failing
  # INSERT is trivially atomic on its own; this scenario does not exercise
  # "child fails after parent already succeeded" cross-statement rollback.
  # See this worker's report for the full non-vacuousness finding, escalated
  # separately - the remaining public-surface mechanism below is real and
  # worth keeping (it guards against an orphaned-children regression on a
  # parent-uuid collision), but it is a NARROWER guarantee than FB4's
  # original name claimed.
  u <- review_queue_add(con, kind = "unknown_feature", candidates = c("f-0001", "f-0002"))
  mid_review <- DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM review_queue")$n
  mid_cand <- DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM review_queue_candidate")$n
  expect_equal(mid_review, 1)
  expect_equal(mid_cand, 2)

  cond <- tryCatch(
    review_queue_add(con, kind = "unknown_feature", uuid = u, candidates = c("f-0003", "f-0004")),
    error = function(e) e
  )
  expect_s3_class(cond, "error")
  # Assert on the DB-LEVEL constraint text surviving intact (not just the
  # outer "Mutation transaction failed" wrapper) - this is R/mutate.R's own
  # error-unmasking fix; a regression there would re-mask the real cause.
  expect_true(grepl("Duplicate key", conditionMessage(cond), fixed = TRUE))
  expect_true(grepl("primary key constraint", conditionMessage(cond), fixed = TRUE))

  after_review <- DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM review_queue")$n
  after_cand <- DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM review_queue_candidate")$n
  expect_identical(after_review, mid_review)
  expect_identical(after_cand, mid_cand)
})

# ==============================================================================
# Round-2 audit FD14/FE4: the public reader's typed columns were pinned by no
# test. VERIFIED FIRST (worker W-G, 2026-07-25): R/mutate.R's review_queue()
# SELECT already lists subkind/uuid_existing/uuid_alias (landed Phase-6,
# commit 2a7ec53 "review_queue() returns typed columns") - so this is a
# MISSING-TEST finding only, not a production defect, and no production code
# changes alongside this test. Asserted through review_queue() ITSELF (not a
# raw dbGetQuery), for a row written by a real production writer
# (review_queue_add()), with both the TYPE and the VALUE of each column.
# ==============================================================================

test_that("FD14/FE4: review_queue()'s public reader returns subkind/uuid_existing/uuid_alias with the correct type and value, for a row written by review_queue_add()", {
  path <- seed_db()
  con <- seed_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  uuid_written <- review_queue_add(
    con, kind = "value_conflict", subkind = "measurement",
    uuid_existing = "an-0001", uuid_alias = "fa-0001"
  )

  rows <- review_queue(con)
  hit <- rows[rows$uuid == uuid_written, , drop = FALSE]
  expect_equal(nrow(hit), 1)

  expect_true(is.character(hit$subkind))
  expect_true(is.character(hit$uuid_existing))
  expect_true(is.character(hit$uuid_alias))
  expect_identical(hit$subkind[[1]], "measurement")
  expect_identical(hit$uuid_existing[[1]], "an-0001")
  expect_identical(hit$uuid_alias[[1]], "fa-0001")
})

# ==============================================================================
# Task 4 (this round): register `adapters`/`units` in
# `.RQ_PLURAL_DIAGNOSTIC_KEYS` (R/db-schema.R) and pin, on the RAW JSON TEXT
# (not a jsonlite::fromJSON() result, whose own simplification would hide
# exactly this scalar-vs-array difference), that every registered key
# serialises as a JSON array even at length 1.
# ==============================================================================

test_that(".RQ_PLURAL_DIAGNOSTIC_KEYS: every registered plural diagnostics key serialises as a JSON ARRAY at length 1, asserted on the raw stored payload TEXT", {
  path <- seed_db()
  con <- seed_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  expect_true(all(c("candidates", "source_ref", "adapters", "units") %in% .RQ_PLURAL_DIAGNOSTIC_KEYS))

  for (key in .RQ_PLURAL_DIAGNOSTIC_KEYS) {
    diagnostics <- stats::setNames(list("only-one"), key)
    uuid_written <- review_queue_add(con, kind = "unknown_feature", diagnostics = diagnostics)

    stored <- DBI::dbGetQuery(con, "SELECT payload FROM review_queue WHERE uuid = ?",
                               params = list(uuid_written))
    raw <- stored$payload[[1]]
    expected_array_fragment <- sprintf('"%s":["only-one"]', key)
    expect_true(grepl(expected_array_fragment, raw, fixed = TRUE),
                info = sprintf("key = %s, raw payload = %s", key, raw))
  }
})
