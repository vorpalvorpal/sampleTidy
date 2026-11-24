# Sampling-point resolution, rule R1b GENERALISED (approved 2026-11-24).
#
# Until now R1b (R/reconcile.R `.rc_self_precedence()`) let a dated arm win on
# its dates only when the competing candidate was the feature's `self` arm.
# The rule now reads: when several arms match a label on a date, an arm whose
# EXPLICIT date window (date_start and/or date_end set) covers that date beats
# an open-ended or undated arm, WHATEVER the undated arm's kind (`self`,
# `historical_code`, `descriptive`, `mask_long`, ...). Two dated covering arms
# onto different features, or two undated arms, are still ambiguous.
#
# Why: migration 118 turns old codes into undated `historical_code` arms, so a
# dated mislabel arm ("on 2021-03-26 to 2021-04-14, label X meant feature Y")
# would otherwise stop winning and its rows would go to review.
#
# Fixtures: the throwaway `seed_db()` (helper-db.R) plus locally inserted
# features and arms on fresh synthetic T. names, so nothing in the shared seed
# is relied on beyond the schema.

# ---- local helpers (the shape of test-alias-date-precedence.R's) ----------------

dp_row <- function(...) {
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

dp_event <- function(results, work_order = "XX1234567") {
  list(
    work_order = work_order, orphan = FALSE, results = results,
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

dp_lit <- function(d) if (is.na(d)) "NULL" else sprintf("DATE '%s'", d)

dp_feature <- function(con, uuid, name) {
  DBI::dbExecute(con, sprintf(
    "INSERT INTO feature (uuid, name, site, flow, matrix) VALUES ('%s', '%s', 'T', 'surface', 'water')",
    uuid, name))
}

dp_alias <- function(con, uuid, uuid_feature, name, kind, date_start = NA, date_end = NA) {
  DBI::dbExecute(con, sprintf(
    "INSERT INTO feature_alias
       (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign,
        first_seen, last_seen, confirmed_by, date_start, date_end)
     VALUES ('%s', '%s', '%s', '%s', '%s', 0, TRUE,
             TIMESTAMP '2020-01-01 00:00:00', TIMESTAMP '2020-01-01 00:00:00',
             NULL, %s, %s)",
    uuid, uuid_feature, name, .rc_feature_key(name), kind, dp_lit(date_start), dp_lit(date_end)))
}

# Three features T.H01..T.H03, each with its own self arm. The label under
# test is the OLD code T.OLD7, which is nobody's own name.
dp_setup <- function(env = parent.frame()) {
  path <- seed_db(dir = withr::local_tempdir(.local_envir = env))
  con <- seed_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE), envir = env)
  for (k in 1:3) {
    dp_feature(con, sprintf("f-h%d", k), sprintf("T.H0%d", k))
    dp_alias(con, sprintf("fa-h%d-self", k), sprintf("f-h%d", k), sprintf("T.H0%d", k), "self")
  }
  con
}

# Reconcile one row per date (named by source_ref) carrying label `raw`.
dp_run <- function(con, raw, dates) {
  rows <- do.call(dplyr::bind_rows, lapply(seq_along(dates), function(i) {
    dp_row(source_ref = names(dates)[[i]], feature_raw = raw,
           lab_sample_id = sprintf("XX99999700%02d", i),
           sample_datetime_raw = format(as.Date(dates[[i]]), "%d %b %Y 09:00"))
  }))
  reconcile_event(dp_event(rows), con)
}

dp_clean <- function(out, ref) out$clean[out$clean$source_ref == ref, , drop = FALSE]

dp_notes <- function(out, ref) {
  rv <- out$review
  if (nrow(rv) == 0) return(rv)
  hit <- vapply(strsplit(rv$source_ref, ",", fixed = TRUE), function(s) ref %in% s, logical(1))
  rv[hit & !is.na(rv$subkind) & rv$subkind == "self_precedence_note", , drop = FALSE]
}

dp_expect_resolved <- function(out, ref, feature, alias) {
  r <- dp_clean(out, ref)
  expect_equal(nrow(r), 1L, label = ref)
  expect_false(r$feature_pending, label = ref)
  expect_identical(r$uuid_feature, feature, label = ref)
  expect_identical(r$uuid_feature_alias, alias, label = ref)
  expect_equal(nrow(dp_notes(out, ref)), 0, label = ref)
}

dp_expect_ambiguous <- function(out, ref) {
  r <- dp_clean(out, ref)
  expect_equal(nrow(r), 1L, label = ref)
  expect_true(r$feature_pending, label = ref)
  expect_true(is.na(r$uuid_feature), label = ref)
}

# The mislabel window used throughout: 2021-03-26 to 2021-04-14.
dp_on <- c(first_day = "2021-03-26", mid = "2021-04-01", last_day = "2021-04-14")
dp_off <- c(day_before = "2021-03-25", day_after = "2021-04-15", later = "2023-06-01")

# ---- a dated arm beats an open arm of any kind ----------------------------------

test_that("R1b general: a dated arm beats an open historical_code arm on its dates (ends inclusive), with no note", {
  con <- dp_setup()
  dp_alias(con, "fa-old7-open", "f-h1", "T.OLD7", "historical_code")
  dp_alias(con, "fa-old7-dated", "f-h2", "T.OLD7", "transcription_error",
           date_start = "2021-03-26", date_end = "2021-04-14")
  out <- dp_run(con, "T.OLD7", dp_on)
  for (ref in names(dp_on)) dp_expect_resolved(out, ref, "f-h2", "fa-old7-dated")
})

test_that("R1b general: outside the dated arm's window the open historical_code arm wins", {
  con <- dp_setup()
  dp_alias(con, "fa-old7-open", "f-h1", "T.OLD7", "historical_code")
  dp_alias(con, "fa-old7-dated", "f-h2", "T.OLD7", "transcription_error",
           date_start = "2021-03-26", date_end = "2021-04-14")
  out <- dp_run(con, "T.OLD7", dp_off)
  for (ref in names(dp_off)) dp_expect_resolved(out, ref, "f-h1", "fa-old7-open")
})

for (open_kind in c("descriptive", "mask_long")) local({
  open_kind <- open_kind
  test_that(sprintf("R1b general: a dated historical_code arm beats an open %s arm on its dates", open_kind), {
    con <- dp_setup()
    dp_alias(con, "fa-old7-open", "f-h1", "T.OLD7", open_kind)
    dp_alias(con, "fa-old7-dated", "f-h2", "T.OLD7", "historical_code", date_end = "2021-04-14")
    out <- dp_run(con, "T.OLD7", c(inside = "2021-04-01", outside = "2021-04-15"))
    dp_expect_resolved(out, "inside", "f-h2", "fa-old7-dated")
    dp_expect_resolved(out, "outside", "f-h1", "fa-old7-open")
  })
})

test_that("R1b general: a start-only window counts as dated (covers from its start, open after)", {
  con <- dp_setup()
  dp_alias(con, "fa-old7-open", "f-h1", "T.OLD7", "historical_code")
  dp_alias(con, "fa-old7-from", "f-h2", "T.OLD7", "historical_code", date_start = "2022-01-01")
  out <- dp_run(con, "T.OLD7", c(before = "2021-12-31", on = "2022-01-01", after = "2024-05-05"))
  dp_expect_resolved(out, "before", "f-h1", "fa-old7-open")
  dp_expect_resolved(out, "on", "f-h2", "fa-old7-from")
  dp_expect_resolved(out, "after", "f-h2", "fa-old7-from")
})

test_that("R1b general: a dated arm beats SEVERAL open arms onto different features (the open arms' own tie is moot on its dates)", {
  con <- dp_setup()
  dp_alias(con, "fa-old7-open1", "f-h1", "T.OLD7", "historical_code")
  dp_alias(con, "fa-old7-open3", "f-h3", "T.OLD7", "descriptive")
  dp_alias(con, "fa-old7-dated", "f-h2", "T.OLD7", "transcription_error",
           date_start = "2021-03-26", date_end = "2021-04-14")
  out <- dp_run(con, "T.OLD7", c(inside = "2021-04-01", outside = "2021-04-15"))
  dp_expect_resolved(out, "inside", "f-h2", "fa-old7-dated")
  dp_expect_ambiguous(out, "outside")
})

# ---- the self-arm case is unchanged ---------------------------------------------

test_that("R1b general: the self-arm case is unchanged - a dated arm beats self on its dates, self wins outside them, no note either way", {
  con <- dp_setup()
  dp_alias(con, "fa-h1-dated", "f-h2", "T.H01", "transcription_error",
           date_start = "2021-03-26", date_end = "2021-04-14")
  out <- dp_run(con, "T.H01", c(inside = "2021-04-01", outside = "2021-04-15"))
  dp_expect_resolved(out, "inside", "f-h2", "fa-h1-dated")
  dp_expect_resolved(out, "outside", "f-h1", "fa-h1-self")
})

test_that("R1b general: an open non-self arm still loses to self, with the non-blocking self_precedence_note (R2 unchanged)", {
  con <- dp_setup()
  dp_alias(con, "fa-h1-old", "f-h3", "T.H01", "historical_code")
  out <- dp_run(con, "T.H01", c(any = "2021-04-01"))
  r <- dp_clean(out, "any")
  expect_false(r$feature_pending)
  expect_identical(r$uuid_feature, "f-h1")
  expect_identical(r$uuid_feature_alias, "fa-h1-self")
  expect_equal(nrow(dp_notes(out, "any")), 1)
})

# ---- ties stay ambiguous --------------------------------------------------------

test_that("R1b general: two dated arms covering the date onto different features are ambiguous, with or without an open arm beside them", {
  con <- dp_setup()
  dp_alias(con, "fa-old7-d2", "f-h2", "T.OLD7", "transcription_error",
           date_start = "2021-03-26", date_end = "2021-04-14")
  dp_alias(con, "fa-old7-d3", "f-h3", "T.OLD7", "historical_code", date_end = "2021-12-31")
  out <- dp_run(con, "T.OLD7", c(both = "2021-04-01"))
  dp_expect_ambiguous(out, "both")

  dp_alias(con, "fa-old7-open", "f-h1", "T.OLD7", "historical_code")
  out2 <- dp_run(con, "T.OLD7", c(both_plus_open = "2021-04-01", only_d3 = "2021-06-01"))
  dp_expect_ambiguous(out2, "both_plus_open")
  # on a date only ONE dated arm covers, that arm beats the open one
  dp_expect_resolved(out2, "only_d3", "f-h3", "fa-old7-d3")
})

test_that("R1b general: two dated covering arms onto the SAME feature are not a tie: the row resolves to that feature", {
  con <- dp_setup()
  dp_alias(con, "fa-old7-open", "f-h1", "T.OLD7", "historical_code")
  dp_alias(con, "fa-old7-da", "f-h2", "T.OLD7", "transcription_error",
           date_start = "2021-03-26", date_end = "2021-04-14")
  dp_alias(con, "fa-old7-db", "f-h2", "T.OLD7", "historical_code", date_end = "2021-12-31")
  out <- dp_run(con, "T.OLD7", c(inside = "2021-04-01"))
  r <- dp_clean(out, "inside")
  expect_false(r$feature_pending)
  expect_identical(r$uuid_feature, "f-h2")
  expect_true(r$uuid_feature_alias %in% c("fa-old7-da", "fa-old7-db"))
})

test_that("R1b general: two open arms onto different features are ambiguous (unchanged)", {
  con <- dp_setup()
  dp_alias(con, "fa-old7-o1", "f-h1", "T.OLD7", "historical_code")
  dp_alias(con, "fa-old7-o2", "f-h2", "T.OLD7", "historical_code")
  out <- dp_run(con, "T.OLD7", c(any = "2021-04-01"))
  dp_expect_ambiguous(out, "any")
})

# ---- alias_window_ambiguous does not start reporting dated-vs-open pairs --------

test_that("alias_window_ambiguous: a dated arm beside an open arm of the same key is not reported; two overlapping dated arms still are", {
  con <- dp_setup()
  dp_alias(con, "fa-old7-open", "f-h1", "T.OLD7", "historical_code")
  dp_alias(con, "fa-old7-dated", "f-h2", "T.OLD7", "transcription_error",
           date_start = "2021-03-26", date_end = "2021-04-14")
  dp_alias(con, "fa-old8-d1", "f-h1", "T.OLD8", "historical_code",
           date_start = "2021-01-01", date_end = "2021-06-30")
  dp_alias(con, "fa-old8-d2", "f-h2", "T.OLD8", "transcription_error",
           date_start = "2021-03-26", date_end = "2021-04-14")
  res <- db_checks(con, tier = "all")
  r <- res[res$name == "alias_window_ambiguous", , drop = FALSE]
  expect_identical(nrow(r), 1L)
  keys <- as.character(r$keys[[1]])
  expect_false(any(grepl("fa-old7-", keys, fixed = TRUE)), info = paste(keys, collapse = " | "))
  expect_true("fa-old8-d1 fa-old8-d2" %in% keys, info = paste(keys, collapse = " | "))
})
