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
# FLAGGED NEW LOCAL HELPER (not in helper-db.R): `.p16_write_review_row()`,
# a thin wrapper around the REAL `db_append()` mutation-layer writer that
# mirrors `.ct_commit_review()`'s own per-row insert (R/commit.R:638-653)
# exactly - i.e. the real downstream write path for a `reconcile_event()`
# review row, not a hand-rolled `INSERT`. Defined locally per the brief
# (do not edit helper-db.R).

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

#' FLAGGED NEW LOCAL HELPER. Write ONE `reconcile_event()`-produced review row
#' through the REAL `db_append()` mutation-layer writer, reproducing
#' `.ct_commit_review()`'s own per-row insert shape (R/commit.R:638-653)
#' exactly - the real downstream write path for a review item, not a
#' hand-rolled `INSERT INTO review_queue`. Returns the written uuid.
#' @keywords internal
.p16_write_review_row <- function(con, review_row_1, work_order = "XX1234567") {
  row <- tibble::tibble(
    uuid = uuid::UUIDgenerate(), created_at = Sys.time(), kind = review_row_1$kind[[1]],
    work_order = work_order, source_hash = review_row_1$source_hash[[1]],
    payload = review_row_1$payload[[1]], status = "open"
  )
  db_append(con, "review_queue", row, actor = "test", reason = "P16-T-payload seam test")
  row$uuid
}

# ==============================================================================
# R-16.10 (THE HEADLINE): a value containing a comma, a pipe or an equals
# sign round-trips byte-identical
# ==============================================================================

test_that("R-16.10: an analyte name with commas/apostrophes plus a synthetic |/= value round-trips byte-identical through JSON diagnostics (the criterion the plan exists for - RED against today's k=v payload)", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  hazard_analyte <- "2,2',3,3',4,4'-Hexachlorobiphenyl"   # real analyte name, live registry
  hazard_value <- "a|b=c,d"                                 # synthetic: pipe + equals + comma

  row <- mk_row(source_ref = "r1")
  row$needs_review <- TRUE
  row$review_kind <- "value_conflict"
  row$review_payload <- list(list(subkind = "manual_note", analyte = hazard_analyte, value = hazard_value))
  event <- mk_event(row)

  # REAL producer: reconcile_event()'s STAGE-0 fold-in (R-11.14) serialises
  # this diagnostics list via the REAL .rc_serialise_payload()
  # (R/reconcile.R:108-117) - the unescaped paste0() k=v joiner this whole
  # plan exists to retire.
  out <- reconcile_event(event, con)
  hit <- out$review[out$review$kind == "value_conflict", , drop = FALSE]
  expect_equal(nrow(hit), 1)

  # REAL downstream writer: the exact row shape .ct_commit_review() inserts.
  uuid_written <- .p16_write_review_row(con, hit)

  stored <- DBI::dbGetQuery(con, "SELECT payload FROM review_queue WHERE uuid = ?",
                             params = list(uuid_written))
  expect_equal(nrow(stored), 1)

  diagnostics <- tryCatch(jsonlite::fromJSON(stored$payload[[1]]), error = function(e) list())
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
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

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
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

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
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

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
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

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
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

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
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

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
    expect_error(ctor(kind = "value_conflict", diagnostics = "existing_uuid=an-0001,value=1"))
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
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

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

  fa_diag <- tryCatch(jsonlite::fromJSON(fa_hit$payload[[1]]), error = function(e) list())
  expect_false(any(c("existing_value", "incoming_value", "value_new", "uuid_new") %in% names(fa_diag)))

  # R-16.20: compare the two producers' diagnostics KEY SETS TO EACH OTHER,
  # not to a hardcoded list. The shared subset must match EXACTLY
  # (value_existing/value_incoming); reconcile-only extras
  # (quantified_*/revision_*) are the ONLY permitted difference.
  rc_keys <- sort(names(rc_diag))
  fa_keys <- sort(names(fa_diag))
  extras_permitted <- c("quantified_existing", "quantified_incoming",
                        "revision_existing", "revision_incoming")
  rc_shared <- setdiff(rc_keys, extras_permitted)
  expect_true(setequal(rc_shared, fa_keys))
  expect_true(all(c("value_existing", "value_incoming") %in% rc_shared))
  expect_true(all(c("value_existing", "value_incoming") %in% fa_keys))
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
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

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
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

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
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  uuid_written <- review_queue_add(con, kind = "unknown_feature", subkind = "structural")

  stored <- DBI::dbGetQuery(con, "SELECT payload FROM review_queue WHERE uuid = ?",
                             params = list(uuid_written))
  # fromJSON() cannot distinguish "{}" from "[]" (both -> list()), so this
  # MUST be asserted on the raw stored TEXT.
  expect_identical(stored$payload[[1]], "{}")
})

test_that("FA7: .rq_row()/.rq_skip() reject an UNNAMED diagnostics list (a hand-built k=v blob wrapped in list())", {
  expect_error(.rq_row(kind = "x", diagnostics = list("existing_uuid=an-0001,value=1")))
  expect_error(.rq_row(kind = "x", diagnostics = list("a=1", site = "T")))
  expect_error(.rq_skip(diagnostics = list("existing_uuid=an-0001,value=1")))
})

test_that("FB4: review_queue_add() with a failing child row leaves NO review row and NO candidate rows (parent+children are one transaction)", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  before_review <- DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM review_queue")$n
  before_cand <- DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM review_queue_candidate")$n

  expect_error(
    review_queue_add(con, kind = "unknown_feature", candidates = c("ok1", NA_character_))
  )

  after_review <- DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM review_queue")$n
  after_cand <- DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM review_queue_candidate")$n
  expect_identical(after_review, before_review)
  expect_identical(after_cand, before_cand)
})
