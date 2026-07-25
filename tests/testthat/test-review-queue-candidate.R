# PLAN-16 Phase-7b round-3, Robin's RULING 2 (2026-07-25, "Scope added
# 2026-07-25" in dev/plans/PLAN-16-review-queue-structured-payload.md):
# `review_queue_candidate` had neither a producer nor a reader in production
# (Slice G proved it by mutation - zeroing `.rq_row()`'s child rows killed 6
# constructor-level unit tests and left every end-to-end file green). This
# file covers the three new criteria that close the gap:
#
#  - R-16.22: an exported read path, `review_queue_candidates()`
#    (R/mutate.R), returns a review item's candidates in rank order,
#    asserted against a row a REAL producer wrote - never a fixture this
#    file inserts directly.
#  - R-16.23 (FG-3): `.rc_review_row()` (R/reconcile.R) no longer silently
#    drops `rq$candidates`/`rq$expired`; at least one production path
#    (`.rc_feature_candidates()` resolving real feature uuids ->
#    `review_queue_add()`'s own `candidates=` argument, both unedited) is
#    driven end to end: producer -> review_queue_candidate -> reader -> the
#    same uuids.
#  - R-16.24: the two candidate carriers (review_queue_candidate child rows,
#    and the JSON `candidates` diagnostics key RULING-F pins for
#    reconcile-side producers) are told apart by PRESENCE, never guessed;
#    a row using both at once is a producer defect and the reader aborts
#    rather than silently pick a side.
#
# Also covers two more round-3 findings landed alongside this scope
# (R/reconcile.R, same file this worker owns):
#  - H11: the two `as.Date()` calls with no `tz=` (`.rc_narrow_live()`,
#    `.rc_structural_hit()`) are pinned against the exact day-shift class
#    already fixed once at the `.rq_row()` `expired=` driver boundary.
#  - F7: R-16.11's "no stored diagnostics value is an embedded k=v
#    fragment" check, previously pinned on ONE structural row only, is
#    widened here to every review-producing kind this file can drive.
#
# Fixtures: `tests/testthat/helper-db.R`'s `seed_db()`/`seed_con()` only.
# `mk_row()`/`mk_rows()`/`mk_event()` below are LOCAL, verbatim copies of
# test-reconcile.R's own builders (same no-cross-file-collision convention
# every other testthat file in this suite already uses).

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

#' Own-frame seed+reconcile so `on.exit()` disconnects THIS scenario's
#' connection when the helper returns, rather than deferring several
#' iterations' worth of `on.exit(..., add = TRUE)` calls to one shared
#' test_that frame (which would all close over the SAME reassigned `con`
#' variable and only ever disconnect the last one).
run_scenario <- function(event) {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  reconcile_event(event, con)
}

# ==============================================================================
# FG-3/R-16.23: .rc_review_row() no longer silently drops rq$candidates/expired
# ==============================================================================

test_that("FG-3: .rc_review_row() carries rq$candidates through as a `candidates` list-column instead of silently dropping them", {
  row <- .rc_review_row(
    source_ref = "r1", kind = "unknown_feature", n_rows = 1L, source_hash = "hash-1",
    subkind = "ambiguous", candidates = c("f-0004", "f-0005")
  )
  expect_true("candidates" %in% names(row))
  cand <- row$candidates[[1]]
  expect_equal(nrow(cand), 2)
  expect_identical(cand$uuid_feature, c("f-0004", "f-0005"))
  expect_identical(cand$rank, c(1L, 2L))
  expect_identical(cand$kind, c("candidate", "candidate"))
})

test_that("FG-3: .rc_review_row() also carries the `expired` arm through, ranked after the candidate arm (mirrors .rq_row()'s own contract)", {
  expired <- tibble::tibble(
    uuid_feature = "f-0004", date_start = as.Date("2020-01-01"), date_end = as.Date("2020-12-31")
  )
  row <- .rc_review_row(
    source_ref = "r1", kind = "unknown_feature", n_rows = 1L, source_hash = "hash-1",
    candidates = "f-0005", expired = expired
  )
  cand <- row$candidates[[1]]
  expect_equal(nrow(cand), 2)
  expect_identical(cand$kind, c("candidate", "expired"))
  expect_identical(cand$rank, c(1L, 2L))
  expect_identical(cand$date_start[[2]], as.Date("2020-01-01"))
})

test_that("FG-3: a call with NEITHER candidates= nor expired= - every one of the 11 real call sites today - still returns a `candidates` list-column, but empty; the fix changes nothing for current callers (latent, not a behaviour change)", {
  row <- .rc_review_row(source_ref = "r1", kind = "unknown_feature", n_rows = 1L, source_hash = "hash-1")
  expect_true("candidates" %in% names(row))
  expect_equal(nrow(row$candidates[[1]]), 0)
})

test_that("FG-3: reconcile_event()'s own `review` tibble carries the candidates list-column through too (not dropped a second time at the review_cols selection step); the real .rc_feature_review() producer still chooses the JSON carrier (RULING-F, unchanged), so its element is empty here - the OTHER carrier is exercised via review_queue_add() directly, below", {
  out <- run_scenario(mk_event(mk_row(source_ref = "r1", feature_raw = "T.AMBIG2")))
  expect_true("candidates" %in% names(out$review))
  amb <- out$review[out$review$source_ref == "r1", ]
  expect_equal(nrow(amb), 1)
  expect_equal(nrow(amb$candidates[[1]]), 0)
})

# ==============================================================================
# R-16.22/R-16.23: the reader, driven end to end against a REAL producer
# ==============================================================================

test_that("R-16.22/R-16.23: review_queue_candidates() reads back, in rank order, the SAME feature uuids a real production write persisted - .rc_feature_candidates() (real reconcile resolution against the real seeded registry) -> review_queue_add()'s own candidates= argument (the real, already-shipped write path, unedited) -> review_queue_candidate -> review_queue_candidates() (this criterion's new reader)", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  registry <- .rc_load_registry(con)
  cand <- .rc_feature_candidates("T.AMBIG2", as.Date(NA), registry)
  expect_equal(sort(cand$uuid_feature), c("f-0004", "f-0005"))

  uuid_review <- review_queue_add(
    con, kind = "unknown_feature", subkind = "ambiguous",
    work_order = "XX1234567", candidates = cand$uuid_feature
  )

  got <- review_queue_candidates(con, uuid_review)
  expect_equal(nrow(got), 2)
  expect_identical(got$rank, c(1L, 2L))
  expect_identical(got$uuid_feature, cand$uuid_feature)
  expect_identical(got$kind, c("candidate", "candidate"))

  # Confirms the reader used the CHILD-TABLE carrier, not a lucky JSON parse:
  # this row's payload has no `candidates` key at all (review_queue_add() was
  # called with no `diagnostics=`).
  raw <- DBI::dbGetQuery(con, "SELECT payload FROM review_queue WHERE uuid = ?", params = list(uuid_review))
  expect_false(grepl("candidates", raw$payload[[1]], fixed = TRUE))
})

test_that("review_queue_candidates(): an unknown uuid_review returns zero rows, not an error", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  got <- review_queue_candidates(con, "nonexistent-uuid")
  expect_equal(nrow(got), 0)
  expect_named(got, c("rank", "uuid_feature", "kind", "date_start", "date_end"))
})

# ==============================================================================
# R-16.24: one carrier per item, discriminated by presence, never guessed
# ==============================================================================

test_that("R-16.24: a review item with neither carrier returns zero rows (not an error, not a guess)", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  uuid_review <- review_queue_add(con, kind = "adapter_tie", work_order = "XX1234567")
  got <- review_queue_candidates(con, uuid_review)
  expect_equal(nrow(got), 0)
})

test_that("R-16.24: the JSON-carrier row a REAL reconcile_event() run produces is read back correctly via the fallback path, and the discriminator proves it actually fell back (zero review_queue_candidate rows exist for it)", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # A real, unedited production run: RULING-F means this row's candidates
  # travel as diagnostics$candidates JSON, not as review_queue_candidate rows
  # (reconcile.R is read-only against the DB and never persists anything
  # itself - see reconcile_event()'s own header comment).
  out <- reconcile_event(mk_event(mk_row(source_ref = "r1", feature_raw = "T.AMBIG2")), con)
  amb <- out$review[out$review$source_ref == "r1" & out$review$kind == "unknown_feature", ]
  expect_equal(nrow(amb), 1)
  expect_identical(amb$subkind[[1]], "ambiguous")

  # Persist the REAL producer's own payload verbatim, via review_queue_add()'s
  # sanctioned test-only override (R-16.18's own comment in
  # test-review-queue-hygiene.R: "the argument is retained for tests but no
  # production path supplies one"). This is reconcile_event()'s actual
  # output, not a value this test authored.
  uuid_review <- review_queue_add(
    con, kind = amb$kind[[1]], subkind = amb$subkind[[1]],
    work_order = "XX1234567", payload = amb$payload[[1]]
  )

  got <- review_queue_candidates(con, uuid_review)
  expect_equal(sort(got$uuid_feature), c("f-0004", "f-0005"))
  expect_identical(got$kind, rep("candidate", 2))
  expect_true(all(is.na(got$date_start)) && all(is.na(got$date_end)))

  n_child <- DBI::dbGetQuery(
    con, "SELECT count(*) AS n FROM review_queue_candidate WHERE uuid_review = ?",
    params = list(uuid_review)
  )$n
  expect_equal(n_child, 0)
})

test_that("R-16.24: a review item carrying candidates in BOTH the child table AND the JSON payload aborts rather than silently pick one carrier", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  uuid_review <- review_queue_add(
    con, kind = "unknown_feature", subkind = "ambiguous", work_order = "XX1234567",
    candidates = c("f-0004", "f-0005"),
    diagnostics = list(candidates = c("f-0004", "f-0005"))
  )
  expect_error(review_queue_candidates(con, uuid_review), class = "sampletidy_error")
})

# ==============================================================================
# H11: as.Date() with no tz= at .rc_narrow_live()/.rc_structural_hit() -
# same silent-corruption class already fixed once at .rq_row()'s expired=
# driver boundary (FD9); a no-op today (the columns are DATE), pinned against
# regression.
# ==============================================================================

test_that("H11: .rc_narrow_live() pins tz= explicitly - a POSIXct sample_date does not silently shift a day relative to the Sydney wall-clock date it names", {
  registry <- list(feature = tibble::tibble(
    uuid = c("f-a", "f-b"),
    date_end = as.Date(c("2022-03-03", NA))
  ))
  cand <- tibble::tibble(uuid_alias = c("al-a", "al-b"), uuid_feature = c("f-a", "f-b"))
  # 2022-03-04 09:00 Australia/Sydney (AEDT, UTC+11) is 2022-03-03 22:00 UTC -
  # the exact FD9 day-shift case (.rq_row()'s own comment). Under the correct
  # Sydney wall-clock date (2022-03-04), f-a's date_end (2022-03-03) has
  # already lapsed and must be narrowed OUT; under the (wrong) UTC date
  # (2022-03-03) it would look still-live and stay in.
  sample_date <- as.POSIXct("2022-03-04 09:00:00", tz = "Australia/Sydney")
  out <- .rc_narrow_live(cand, sample_date, registry)
  expect_identical(out$uuid_feature, "f-b")
})

test_that("H11: .rc_structural_hit() pins tz= explicitly - the same POSIXct day-shift case correctly excludes a feature whose date_end has lapsed under the Sydney wall-clock date", {
  registry <- list(feature = tibble::tibble(uuid = "f-a", date_end = as.Date("2022-03-03")))
  index <- tibble::tibble(key = "T|S01", uuid_feature = "f-a")
  sample_date <- as.POSIXct("2022-03-04 09:00:00", tz = "Australia/Sydney")
  expect_true(is.na(.rc_structural_hit("T", "S01", index, sample_date, registry)))
})

# ==============================================================================
# F7: R-16.11's leaf-value check ("no stored diagnostics value is an embedded
# k=v fragment") widened from ONE structural row to every review-producing
# kind reachable here. Slice I re-glued analyte_raw=...,org=... into
# unknown_analyte's diagnostics and the suite stayed green because the only
# pinned check (test-review-queue-payload.R's R-16.11 block) looks at a
# structural row alone.
# ==============================================================================

test_that("F7: no diagnostics leaf value contains an embedded k=v fragment, across every review-producing kind driven in this file (unknown_feature x2 subkinds, unknown_analyte x2 subkinds, unknown_unit, parse_error, value_conflict)", {
  scenarios <- list(
    unknown_feature_ambiguous = mk_event(mk_row(source_ref = "r1", feature_raw = "T.AMBIG2")),
    unknown_feature_structural = mk_event(mk_rows(
      mk_row(source_ref = "miss", feature_raw = "T S88", lab_sample_id = "XX9999990001",
             sample_datetime_raw = "08 Jun 2025 09:00"),
      mk_row(source_ref = "hit", feature_raw = "T S01", lab_sample_id = "XX9999990002",
             sample_datetime_raw = "08 Jun 2025 09:00")
    )),
    unknown_analyte_cas_suggest = mk_event(mk_row(
      source_ref = "r1", analyte_raw = "Fluoride", org = "Internal",
      cas_number = "16984-48-8", method_raw = NA_character_
    )),
    unknown_analyte_miss = mk_event(mk_rows(
      mk_row(source_ref = "r1", analyte_raw = "Nonexistentite", org = "ALS", cas_number = NA_character_),
      mk_row(source_ref = "r2", analyte_raw = "Nonexistentite", org = "ALS", cas_number = NA_character_)
    )),
    unknown_unit = mk_event(mk_row(source_ref = "r1", units_raw = "banana/L")),
    parse_error = mk_event(mk_row(source_ref = "r1", sample_datetime_raw = "not a date")),
    value_conflict = mk_event(mk_row(
      source_ref = "r1", value_raw = "0.1", value_num = 0.1,
      below_detection = FALSE, rl = NA_real_
    ))
  )

  for (nm in names(scenarios)) {
    review <- run_scenario(scenarios[[nm]])$review
    expect_true(nrow(review) > 0, info = sprintf("scenario %s produced no review rows", nm))
    for (i in seq_len(nrow(review))) {
      diag <- tryCatch(jsonlite::fromJSON(review$payload[[i]]), error = function(e) list())
      leaf_values <- as.character(unlist(diag, use.names = FALSE))
      offending <- leaf_values[grepl("=", leaf_values, fixed = TRUE)]
      expect_true(
        length(offending) == 0,
        info = sprintf("scenario %s row %d leaf value(s) %s", nm, i, paste(offending, collapse = "; "))
      )
    }
  }
})
