# tests/testthat/test-existing-row-preference.R
#
# Which existing analysis an incoming row is compared against when MORE THAN
# ONE committed analysis matches `.rc_find_existing()`'s key (feature + Sydney
# day + uuid_lab, then the A62 datetime predicate).
#
# The defect (scratchpad/2026-10-17-fieldconflict/PROPOSAL.md section 3): a
# legacy visit split across two ALS work orders has two samples, each holding
# the field readings of ITS OWN ACIRL report, and the two reports can print
# different values (2023-06-14 B.S01 pH 7.3 vs 6.6; 2022-09-07 B.S03 EC 95 vs
# 94.7). The lookup took `cand[1]` - the lowest analysis uuid across both
# samples - so re-importing one report was compared against the OTHER order's
# copy and raised a false value_conflict although its own copy matched.
#
# Required behaviour (decided by the main agent, 2026-10-17). When several
# existing analyses match:
#   1. a candidate whose value EQUALS the incoming value (the A14
#      `.rc_values_equal()` already used for already_present) wins - a row
#      equal to ANY candidate is already_present;
#   2. failing that, the candidate on a sample whose project is the incoming
#      event's work order;
#   3. otherwise today's deterministic `cand[1]` (lowest analysis uuid).
# A value_conflict names the candidate rules 2/3 chose. Single-candidate
# behaviour is unchanged.
#
# "The incoming event's work order" - ASSUMPTION, read from the code:
#   * an ALS/ESdat event: `event$work_order` (the project the commit files it
#     under, `.ct_ensure_project(con, event$work_order)`, type 'Work order');
#   * an ACIRL event: an orphan (`event$work_order` NA, each row's
#     `work_order` is the REPORT number), so its ALS orders are the ones its
#     report cites, `event$report$sources[[h]]$als_work_orders` - exactly what
#     `.ct_event_als_work_orders()` collects for A80's filing in
#     `.ct_ensure_report_project()`. A candidate matches when its sample's
#     `project.name` is one of those orders.
#
# Every test drives the real, read-only `reconcile_event()` on a seed_db()
# copy; nothing is committed. ACIRL rows are date-only (as the field adapter
# emits them), so the A62 predicate never narrows the candidate set, and they
# sit on T.MW01 on 2025-09-04 - away from seed sample s-0001's instant, which
# A91 step 5 would otherwise withhold.

# ---- fixture -------------------------------------------------------------------

# mk_row()/mk_rows()/mk_event(): verbatim copies of test-reconcile.R's local
# helpers (testthat files do not share locals).
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


erp_day <- "2025-09-04"

erp_utc <- function(date, hm) {
  format(as.POSIXct(paste(date, hm), tz = "Australia/Sydney"), tz = "UTC",
         "%Y-%m-%d %H:%M:%S")
}

erp_db <- function(env = parent.frame()) {
  path <- seed_db(dir = withr::local_tempdir(.local_envir = env))
  con <- seed_con(path)
  DBI::dbExecute(con, "INSERT INTO lab_method
    (uuid, uuid_analyte, name, method, organisation, rl_low, units, conversion_constant) VALUES
    ('lm-fph', 'a-0001', 'Field pH', 'field', 'ACIRL', NULL, 'pH', NULL)")
  # The two ALS orders one legacy visit was split across, and a third order
  # neither candidate is filed under.
  DBI::dbExecute(con, "INSERT INTO project (uuid, uuid_parent, uuid_root, name, type) VALUES
    ('p-wa', NULL, NULL, 'ES2232312', 'Work order'),
    ('p-wb', NULL, NULL, 'ES2232317', 'Work order'),
    ('p-wc', NULL, NULL, 'ES2299999', 'Work order')")
  con
}

# One existing sample at T.MW01 (fa-0003) on erp_day holding ONE analysis
# `an_uuid` on `lab` with `value`. The date is stored the legacy way (Sydney
# midnight as its UTC instant).
erp_sample <- function(con, uuid, project, an_uuid, value, lab = "lm-fph",
                       hm = "09:25", org = "ACIRL") {
  DBI::dbExecute(con, "INSERT INTO \"sample\"
    (uuid, uuid_feature_alias, uuid_project, date, datetime, organisation)
    VALUES (?, 'fa-0003', ?, CAST(? AS TIMESTAMP), CAST(? AS TIMESTAMP), ?)",
    params = list(uuid, project, erp_utc(erp_day, "00:00"), erp_utc(erp_day, hm), org))
  DBI::dbExecute(con, "INSERT INTO analysis (uuid, uuid_sample, uuid_lab, value, quantified, rl_low)
                       VALUES (?, ?, ?, ?, TRUE, NULL)",
                 params = list(an_uuid, uuid, lab, value))
  invisible(uuid)
}

# The split-visit shape: an-a (lower uuid, so today's cand[1]) on ES2232312
# holds 7.3; an-b on ES2232317 holds 6.6. Inserted in REVERSE uuid order so
# storage order and the ORDER BY disagree.
erp_split_visit <- function(con, value_a = 7.3, value_b = 6.6) {
  erp_sample(con, "s-b", "p-wb", "an-b", value_b, hm = "09:25")
  erp_sample(con, "s-a", "p-wa", "an-a", value_a, hm = "09:20")
}

# An ACIRL field-sheet pH row: date-only, method_raw NA, report number in
# work_order - mk_row() (test-reconcile.R's shape) with the field adapter's
# values.
erp_field_row <- function(value, report_no = "2400-7286-06-01", ref = "fld-pH") {
  tibble::as_tibble(list(
    source_hash = "hash-erp", source_ref = ref, work_order = report_no,
    revision = 0L, org = "ACIRL", adapter = "acirl_field_xlsx/1",
    lab_sample_id = "T.MW01", sample_type = "Normal",
    feature_raw = "T.MW01", analyte_raw = "Field pH", cas_number = NA_character_,
    method_raw = NA_character_, total_or_filtered = NA_character_, units_raw = "pH",
    value_raw = format(value), value_num = value, value_chr = NA_character_,
    below_detection = FALSE, rl = NA_real_, lab_qualifier = NA_character_,
    analysed_date = as.Date(NA), comments = NA_character_, confidence = 1,
    sample_datetime_raw = "04/09/2025", sampler = NA_character_,
    matrix_raw = "Water", parent_sample = NA_character_
  ))
}

# An ACIRL event as assembly builds it: an orphan carrying PLAN-07's per-hash
# `sources`, whose `als_work_orders` are the orders the report cites (A80).
erp_acirl_event <- function(rows, cited, report_no = "2400-7286-06-01") {
  h <- "hash-erp"
  list(
    work_order = NA_character_, orphan = TRUE, results = rows,
    samples = tibble::tibble(sample_datetime_raw = unique(rows$sample_datetime_raw)),
    files = tibble::tibble(hash = h, filename = paste(report_no, "WMF.xlsx"),
                           adapter = "acirl_field_xlsx/1", rank = 1L, kept = TRUE),
    report = list(
      n_results = nrow(rows), n_by_sample_type = list(), n_ncp_foreign = 0L,
      skipped = tibble::tibble(hash = character(), source_ref = character(),
                               reason = character()),
      warnings = character(),
      sources = stats::setNames(list(list(
        hash = h, filename = paste(report_no, "WMF.xlsx"), report_no = report_no,
        als_work_orders = cited, feature_aliases = list(), als_candidates = list()
      )), h)
    )
  )
}

erp_conflicts <- function(out) {
  out$review[out$review$kind == "value_conflict", , drop = FALSE]
}

# ---- rule 1: equal to ANY candidate -> already_present ---------------------------

test_that("existing-row preference: a row equal to the SECOND-lowest-uuid candidate is already_present, not a value_conflict against cand[1]", {
  con <- erp_db()
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  erp_split_visit(con)                      # an-a 7.3 (ES2232312), an-b 6.6 (ES2232317)

  # Cites an-a's order, so rule 2 alone would pick the WRONG copy: the value
  # match must outrank the work-order match.
  out <- reconcile_event(erp_acirl_event(erp_field_row(6.6), cited = "ES2232312"), con)

  expect_equal(nrow(erp_conflicts(out)), 0)
  hit <- out$skipped[out$skipped$source_ref == "fld-pH", , drop = FALSE]
  expect_equal(nrow(hit), 1)
  expect_identical(hit$reason, "already_present")
  expect_identical(hit$existing_uuid, "an-b")
  expect_false("fld-pH" %in% out$clean$source_ref)
})

test_that("existing-row preference: rule 1 uses the A14 equality - a value within 1e-9 relative of the second candidate is already_present", {
  con <- erp_db()
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  erp_split_visit(con, value_a = 95, value_b = 94.7)    # 2022-09-07 B.S03 EC shape

  out <- reconcile_event(erp_acirl_event(erp_field_row(94.7 + 1e-12), cited = character(0)), con)

  expect_equal(nrow(erp_conflicts(out)), 0)
  expect_identical(out$skipped$reason, "already_present")
  expect_identical(out$skipped$existing_uuid, "an-b")
})

# ---- rule 2: equal to neither -> the candidate on the event's work order ---------

test_that("existing-row preference: equal to neither candidate, an ACIRL report citing an-b's order -> the value_conflict names an-b", {
  con <- erp_db()
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  erp_split_visit(con)

  out <- reconcile_event(erp_acirl_event(erp_field_row(5.0), cited = "ES2232317"), con)

  vc <- erp_conflicts(out)
  expect_equal(nrow(vc), 1)
  expect_identical(vc$uuid_existing, "an-b")
  expect_false("fld-pH" %in% out$clean$source_ref)
  expect_false("already_present" %in% out$skipped$reason)
})

test_that("existing-row preference: a report citing two orders, only one of them a candidate's, picks that candidate", {
  con <- erp_db()
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  erp_split_visit(con)

  out <- reconcile_event(
    erp_acirl_event(erp_field_row(5.0), cited = c("ES2232317", "ES2299999")), con)

  vc <- erp_conflicts(out)
  expect_equal(nrow(vc), 1)
  expect_identical(vc$uuid_existing, "an-b")
})

test_that("existing-row preference: an ALS event prefers the candidate filed under its own event$work_order", {
  con <- erp_db()
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  # Two ALS samples at the SAME instant on two orders (the ruling-9 shape):
  # A62 cannot narrow them, both are candidates.
  erp_sample(con, "s-lb", "p-wb", "an-lb", 7.9, lab = "lm-0001", hm = "09:25", org = "ALS")
  erp_sample(con, "s-la", "p-wa", "an-la", 7.1, lab = "lm-0001", hm = "09:25", org = "ALS")

  row <- mk_row(
    source_ref = "als-pH", work_order = "ES2232317", lab_sample_id = "ES2232317001",
    feature_raw = "T.MW01", analyte_raw = "pH Value", cas_number = NA_character_,
    method_raw = "EA005P: pH by PC Titrator", units_raw = "pH Unit",
    value_raw = "5.00", value_num = 5.0, below_detection = FALSE, rl = NA_real_,
    sample_datetime_raw = "04 Sep 2025 09:25"
  )
  out <- reconcile_event(mk_event(row, work_order = "ES2232317"), con)

  vc <- erp_conflicts(out)
  expect_equal(nrow(vc), 1)
  expect_identical(vc$uuid_existing, "an-lb")
})

# ---- rule 3: equal to neither, no work-order match -> cand[1] as today -----------

test_that("existing-row preference: equal to neither and no work-order match -> the value_conflict names cand[1] (lowest uuid), as today", {
  con <- erp_db()
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  erp_split_visit(con)

  out_other <- reconcile_event(erp_acirl_event(erp_field_row(5.0), cited = "ES2299999"), con)
  vc <- erp_conflicts(out_other)
  expect_equal(nrow(vc), 1)
  expect_identical(vc$uuid_existing, "an-a")

  # A report that cites no order at all (a dust-only or gas workbook shape).
  out_none <- reconcile_event(erp_acirl_event(erp_field_row(5.0), cited = character(0)), con)
  vc2 <- erp_conflicts(out_none)
  expect_equal(nrow(vc2), 1)
  expect_identical(vc2$uuid_existing, "an-a")
})

# ---- single candidate: unchanged ----------------------------------------------------

test_that("existing-row preference: a SINGLE candidate behaves exactly as before - equal -> already_present, unequal -> conflict on it whatever the cited order", {
  con <- erp_db()
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  erp_sample(con, "s-a", "p-wa", "an-a", 7.3)

  eq <- reconcile_event(erp_acirl_event(erp_field_row(7.3), cited = "ES2232317"), con)
  expect_identical(eq$skipped$reason, "already_present")
  expect_identical(eq$skipped$existing_uuid, "an-a")
  expect_equal(nrow(erp_conflicts(eq)), 0)

  # Cites an order the lone candidate is NOT on: it is still the one compared.
  ne <- reconcile_event(erp_acirl_event(erp_field_row(5.0), cited = "ES2232317"), con)
  vc <- erp_conflicts(ne)
  expect_equal(nrow(vc), 1)
  expect_identical(vc$uuid_existing, "an-a")
  expect_false("fld-pH" %in% ne$clean$source_ref)
})

# ---- both candidates equal ---------------------------------------------------------

test_that("existing-row preference: both candidates equal the incoming value -> already_present (the identical-copy days, 2022-09-07 B.S03 / 2023-05-10 B.S01)", {
  con <- erp_db()
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  erp_split_visit(con, value_a = 7.1, value_b = 7.1)

  out <- reconcile_event(erp_acirl_event(erp_field_row(7.1), cited = character(0)), con)

  expect_equal(nrow(erp_conflicts(out)), 0)
  expect_identical(out$skipped$reason, "already_present")
  expect_true(out$skipped$existing_uuid %in% c("an-a", "an-b"))
  # no work-order match: the deterministic cand[1] among the equal ones
  expect_identical(out$skipped$existing_uuid, "an-a")
})

test_that("existing-row preference [ASSUMED tie-break]: both equal, report cites an-b's order -> already_present names an-b (rules 2/3 order the equal candidates)", {
  con <- erp_db()
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  erp_split_visit(con, value_a = 7.1, value_b = 7.1)

  out <- reconcile_event(erp_acirl_event(erp_field_row(7.1), cited = "ES2232317"), con)

  expect_identical(out$skipped$reason, "already_present")
  expect_identical(out$skipped$existing_uuid, "an-b")
})
