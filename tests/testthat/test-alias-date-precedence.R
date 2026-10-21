# Sampling-point resolution: feature date_start narrowing, and dated non-self
# arms against self-precedence (R/reconcile.R `.rc_narrow_live_feature()`,
# `.rc_self_precedence()`, `.rc_self_precedence_notes()`).
#
# Found reviewing the 2026-10-21 self_precedence_note queue
# (scratchpad/2026-10-21-review/uf-self-precedence/REPORT.md):
#  (a) `.rc_narrow_live_feature()` narrowed on `feature.date_end` only, so a
#      feature that did not exist yet on the row date could win (B.TS40
#      starts 2024-04-08 but won May 2023 rows);
#  (b) self-precedence (R2) beat a curated non-self arm whose explicit date
#      window covered the row date (e.g. a one-day arm for that exact visit).
# Required: narrow on BOTH feature date_start and date_end; a non-self arm
# with a date window (date_start and/or date_end set) that covers the row
# date beats the self arm; an UNDATED non-self arm still loses to self, with
# the non-blocking self_precedence_note, exactly as before.
#
# Fixtures: the throwaway `seed_db()` (helper-db.R) plus locally inserted
# features/aliases on fresh keys, so nothing in the shared seed is relied on
# beyond the schema. Dates are DATE literals only (never TIMESTAMP bounds).

# ---- local helpers (same shape as test-reconcile.R's) ----------------------

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

# Insert one feature with explicit DATE bounds (NULL when NA).
adp_feature <- function(con, uuid, name, date_start = NA, date_end = NA) {
  lit <- function(d) if (is.na(d)) "NULL" else sprintf("DATE '%s'", d)
  DBI::dbExecute(con, sprintf(
    "INSERT INTO feature (uuid, name, site, flow, matrix, date_start, date_end, lon, lat)
     VALUES ('%s', '%s', 'T', 'surface', 'water', %s, %s, 150.5, -33.5)",
    uuid, name, lit(date_start), lit(date_end)))
}

# Insert one alias arm with explicit DATE bounds (NULL when NA).
adp_alias <- function(con, uuid, uuid_feature, name, kind,
                      date_start = NA, date_end = NA, auto_assign = TRUE) {
  lit <- function(d) if (is.na(d)) "NULL" else sprintf("DATE '%s'", d)
  DBI::dbExecute(con, sprintf(
    "INSERT INTO feature_alias
       (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign,
        first_seen, last_seen, confirmed_by, date_start, date_end)
     VALUES ('%s', '%s', '%s', '%s', '%s', 0, %s,
             TIMESTAMP '2020-01-01 00:00:00', TIMESTAMP '2020-01-01 00:00:00',
             NULL, %s, %s)",
    uuid, uuid_feature, name, sampleTidy:::.rc_feature_key(name), kind,
    if (auto_assign) "TRUE" else "FALSE", lit(date_start), lit(date_end)))
}

# Does a review row's source_ref (a grouped row's refs, comma-joined) name `ref`?
adp_names_ref <- function(source_ref, ref) {
  vapply(strsplit(source_ref, ",", fixed = TRUE), function(s) ref %in% s, logical(1))
}

# The self_precedence_note rows whose source_ref names `ref`.
adp_notes_for <- function(out, ref) {
  rv <- out$review
  if (nrow(rv) == 0) return(rv)
  hit <- adp_names_ref(rv$source_ref, ref)
  rv[hit & !is.na(rv$subkind) & rv$subkind == "self_precedence_note", , drop = FALSE]
}

adp_clean <- function(out, ref) out$clean[out$clean$source_ref == ref, , drop = FALSE]

# ---- (1) feature date_start narrows candidates -----------------------------

test_that("(1a) a feature whose date_start is AFTER the row date is not a candidate: the unit narrower drops it, and an otherwise-identical row dated on/after date_start keeps it (date_start inclusive)", {
  path <- seed_db(); con <- seed_con(path); withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  # B.TS40-shaped: the point's own name, but the feature only starts 2024-04-08.
  adp_feature(con, "f-new", "T.N40", date_start = "2024-04-08")
  adp_alias(con, "fa-new-self", "f-new", "T.N40", "self")
  registry <- .rc_load_registry(con)

  before <- .rc_feature_candidates("T.N40", as.Date("2023-05-10"), registry)
  expect_equal(nrow(before), 0)

  # Paired positive controls: ON the start date (inclusive) and after.
  on_start <- .rc_feature_candidates("T.N40", as.Date("2024-04-08"), registry)
  expect_identical(on_start$uuid_feature, "f-new")
  after <- .rc_feature_candidates("T.N40", as.Date("2025-01-01"), registry)
  expect_identical(after$uuid_feature, "f-new")

  # A NA sample date still narrows nothing (E.6/R-15.21 unchanged).
  na_date <- .rc_feature_candidates("T.N40", as.Date(NA), registry)
  expect_identical(na_date$uuid_feature, "f-new")
})

test_that("(1b) a not-yet-existing feature never wins self-precedence: its self arm vs an UNDATED non-self arm onto the predecessor resolves a pre-start row to the predecessor as a plain hit (no note), while a post-start row still resolves to the new feature with the note", {
  path <- seed_db(); con <- seed_con(path); withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  # The non-self arm is deliberately UNDATED, so the only thing that can stop
  # the self arm winning the 2023 row is the FEATURE's own date_start (fix a),
  # not the dated-arm rule (fix b).
  adp_feature(con, "f-old", "T.N39")
  adp_feature(con, "f-new", "T.N40", date_start = "2024-04-08")
  adp_alias(con, "fa-old-self", "f-old", "T.N39", "self")
  adp_alias(con, "fa-new-self", "f-new", "T.N40", "self")
  adp_alias(con, "fa-n40-old", "f-old", "T.N40", "historical_code")

  out <- reconcile_event(mk_event(mk_rows(
    mk_row(source_ref = "pre_start", feature_raw = "T.N40",
           lab_sample_id = "XX9999960001", sample_datetime_raw = "10 May 2023 09:00"),
    mk_row(source_ref = "post_start", feature_raw = "T.N40",
           lab_sample_id = "XX9999960002", sample_datetime_raw = "10 May 2025 09:00")
  )), con)

  pre <- adp_clean(out, "pre_start")
  expect_false(pre$feature_pending)
  expect_identical(pre$uuid_feature, "f-old")
  expect_identical(pre$uuid_feature_alias, "fa-n40-old")
  expect_equal(nrow(adp_notes_for(out, "pre_start")), 0)

  # Control: after the start date both features are live and the undated
  # non-self arm loses to self as before (R2 unchanged).
  post <- adp_clean(out, "post_start")
  expect_false(post$feature_pending)
  expect_identical(post$uuid_feature, "f-new")
  expect_equal(nrow(adp_notes_for(out, "post_start")), 1)
})

test_that("(1c) when date_start removes the ONLY candidate the row goes pending (the existing empty-candidate behaviour, as R-15.11 does for an expired feature), never onto the not-yet-existing feature", {
  path <- seed_db(); con <- seed_con(path); withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  adp_feature(con, "f-new", "T.N41", date_start = "2026-01-21")
  adp_alias(con, "fa-new-self", "f-new", "T.N41", "self")

  out <- reconcile_event(mk_event(
    mk_row(source_ref = "too_early", feature_raw = "T.N41",
           lab_sample_id = "XX9999960003", sample_datetime_raw = "08 Apr 2024 09:00")
  ), con)

  row <- adp_clean(out, "too_early")
  expect_equal(nrow(row), 1)
  expect_true(row$feature_pending)
  expect_true(is.na(row$uuid_feature))
  # It surfaces for review rather than resolving silently.
  expect_true(any(adp_names_ref(out$review$source_ref, "too_early") &
                    out$review$kind == "unknown_feature"))
})

# ---- (2) a dated non-self arm covering the row date beats self -------------

test_that("(2) name X is F1's self alias AND a non-self arm onto F2 whose explicit window covers the row date: resolves to F2 through that arm, with NO self_precedence_note - for a one-day window, a date_end-only window and a date_start-only window", {
  path <- seed_db(); con <- seed_con(path); withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  # (i) one-day arm curated for that exact visit.
  adp_feature(con, "f-a1", "T.A01"); adp_feature(con, "f-a2", "T.A02")
  adp_alias(con, "fa-a1-self", "f-a1", "T.A01", "self")
  adp_alias(con, "fa-a2-self", "f-a2", "T.A02", "self")
  adp_alias(con, "fa-a01-day", "f-a2", "T.A01", "transcription_error",
            date_start = "2021-03-26", date_end = "2021-03-26")
  # (ii) date_end only (c0b269d2 B.TS40 -> B.TS39 shape).
  adp_feature(con, "f-b1", "T.B01"); adp_feature(con, "f-b2", "T.B02")
  adp_alias(con, "fa-b1-self", "f-b1", "T.B01", "self")
  adp_alias(con, "fa-b2-self", "f-b2", "T.B02", "self")
  adp_alias(con, "fa-b01-end", "f-b2", "T.B01", "historical_code",
            date_end = "2024-04-07")
  # (iii) date_start only.
  adp_feature(con, "f-c1", "T.C01"); adp_feature(con, "f-c2", "T.C02")
  adp_alias(con, "fa-c1-self", "f-c1", "T.C01", "self")
  adp_alias(con, "fa-c2-self", "f-c2", "T.C02", "self")
  adp_alias(con, "fa-c01-start", "f-c2", "T.C01", "historical_code",
            date_start = "2025-01-01")

  out <- reconcile_event(mk_event(mk_rows(
    mk_row(source_ref = "one_day", feature_raw = "T.A01",
           lab_sample_id = "XX9999961001", sample_datetime_raw = "26 Mar 2021 09:00"),
    mk_row(source_ref = "end_only", feature_raw = "T.B01",
           lab_sample_id = "XX9999961002", sample_datetime_raw = "10 May 2023 09:00"),
    mk_row(source_ref = "start_only", feature_raw = "T.C01",
           lab_sample_id = "XX9999961003", sample_datetime_raw = "10 May 2025 09:00")
  )), con)

  cases <- list(one_day = c("f-a2", "fa-a01-day"),
                end_only = c("f-b2", "fa-b01-end"),
                start_only = c("f-c2", "fa-c01-start"))
  for (ref in names(cases)) {
    r <- adp_clean(out, ref)
    expect_false(r$feature_pending, label = ref)
    expect_identical(r$uuid_feature, cases[[ref]][[1]], label = ref)
    expect_identical(r$uuid_feature_alias, cases[[ref]][[2]], label = ref)
    expect_equal(nrow(adp_notes_for(out, ref)), 0, label = ref)
  }
})

# ---- (3) a dated non-self arm NOT covering the row date: self, as today ----

test_that("(3) the same shape with the non-self arm's window NOT covering the row date resolves to F1 through its self arm, with no note (the dated arm is simply not live)", {
  path <- seed_db(); con <- seed_con(path); withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  adp_feature(con, "f-a1", "T.A01"); adp_feature(con, "f-a2", "T.A02")
  adp_alias(con, "fa-a1-self", "f-a1", "T.A01", "self")
  adp_alias(con, "fa-a2-self", "f-a2", "T.A02", "self")
  adp_alias(con, "fa-a01-day", "f-a2", "T.A01", "transcription_error",
            date_start = "2021-03-26", date_end = "2021-03-26")
  adp_alias(con, "fa-a01-end", "f-a2", "T.A01", "historical_code",
            date_end = "2020-12-31")

  out <- reconcile_event(mk_event(mk_rows(
    mk_row(source_ref = "day_after", feature_raw = "T.A01",
           lab_sample_id = "XX9999962001", sample_datetime_raw = "27 Mar 2021 09:00"),
    mk_row(source_ref = "day_before", feature_raw = "T.A01",
           lab_sample_id = "XX9999962002", sample_datetime_raw = "25 Mar 2021 09:00")
  )), con)

  for (ref in c("day_after", "day_before")) {
    r <- adp_clean(out, ref)
    expect_false(r$feature_pending, label = ref)
    expect_identical(r$uuid_feature, "f-a1", label = ref)
    expect_identical(r$uuid_feature_alias, "fa-a1-self", label = ref)
    expect_equal(nrow(adp_notes_for(out, ref)), 0, label = ref)
  }
})

# ---- (4) an UNDATED non-self arm still loses to self, with the note --------

test_that("(4) an UNDATED non-self arm vs the self arm: self wins and the non-blocking self_precedence_note names the shadowed feature (R2 behaviour preserved)", {
  path <- seed_db(); con <- seed_con(path); withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  # 6ca0abf7 B.S22 -> B.S06 shape: an undated arm on another point's name.
  adp_feature(con, "f-s22", "T.S22"); adp_feature(con, "f-s06", "T.S66")
  adp_alias(con, "fa-s22-self", "f-s22", "T.S22", "self")
  adp_alias(con, "fa-s66-self", "f-s06", "T.S66", "self")
  adp_alias(con, "fa-s22-old", "f-s06", "T.S22", "historical_code")

  out <- reconcile_event(mk_event(
    mk_row(source_ref = "undated", feature_raw = "T.S22",
           lab_sample_id = "XX9999963001", sample_datetime_raw = "26 Mar 2021 09:00")
  ), con)

  r <- adp_clean(out, "undated")
  expect_false(r$feature_pending)
  expect_identical(r$uuid_feature, "f-s22")
  expect_identical(r$uuid_feature_alias, "fa-s22-self")

  note <- adp_notes_for(out, "undated")
  expect_equal(nrow(note), 1)
  expect_identical(note$kind[[1]], "unknown_feature")
  cand <- note$candidates[[1]]
  cand <- cand[!is.na(cand$kind) & cand$kind == "candidate", , drop = FALSE]
  expect_true("f-s06" %in% cand$uuid_feature)
  expect_false(jsonlite::fromJSON(note$payload[[1]])$blocking)
})
