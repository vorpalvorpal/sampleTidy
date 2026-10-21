# R-8.6 method-CODE refinement (Robin's ruling 2026-10-22, broadened): R-8.6
# collapses rows only when their lab_methods share the same method CODE (text
# before the colon, after stripping any "CODE - " prefix, folded with
# .rc_method_key; a colon-less/NA text is its own code). Different codes are
# different measurements: all kept. Preference between them is a view concern.
#
# Fixtures: seed_db()/seed_con() plus per-test analytes and lab_methods.
# mk_row()/mk_rows()/mk_event() are local verbatim copies (suite convention).

# ---- local helpers ---------------------------------------------------------

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

# Insert lab_methods (ALS, mg/L) for an existing analyte. `methods` is a data
# frame of (uuid, name, method, rl_low).
add_lab_methods <- function(con, uuid_analyte, methods, units = "mg/L") {
  for (i in seq_len(nrow(methods))) {
    DBI::dbExecute(con,
      "INSERT INTO lab_method (uuid, uuid_analyte, name, method, organisation, rl_low, units, conversion_constant)
       VALUES (?, ?, ?, ?, 'ALS', ?, ?, NULL)",
      params = list(methods$uuid[[i]], uuid_analyte, methods$name[[i]],
                    methods$method[[i]], methods$rl_low[[i]], units))
  }
}

# Two rows, one sample (T.S02 = fresh sample), one analyte, two methods.
# r1 has the lower RL (0.1) and so wins any real collapse.
pair_rows <- function(name, m1, m2, v1 = 1.1, v2 = 2.2, units = "mg/L") {
  mk_rows(
    mk_row(source_ref = "r1", lab_sample_id = "XX1234567002", feature_raw = "T.S02",
           analyte_raw = name, method_raw = m1, value_raw = as.character(v1),
           value_num = v1, below_detection = FALSE, rl = 0.1, units_raw = units),
    mk_row(source_ref = "r2", lab_sample_id = "XX1234567002", feature_raw = "T.S02",
           analyte_raw = name, method_raw = m2, value_raw = as.character(v2),
           value_num = v2, below_detection = FALSE, rl = 0.5, units_raw = units)
  )
}

# Seed DB + a new analyte `a-0101` with two methods m1 (rl 0.1), m2 (rl 0.5).
setup_pair <- function(analyte_name, m1, m2, env = parent.frame()) {
  path <- seed_db()
  con <- seed_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE), envir = env)
  DBI::dbExecute(con, sprintf(
    "INSERT INTO analyte (uuid, name, units, type, CAS) VALUES ('a-0101', '%s', 'mg/L', 'metal', NULL)",
    analyte_name))
  add_lab_methods(con, "a-0101", data.frame(
    uuid = c("lm-1001", "lm-1002"), name = analyte_name,
    method = c(m1, m2), rl_low = c(0.1, 0.5)))
  con
}

dup_refs <- function(out) out$skipped$source_ref[out$skipped$reason == "method_duplicate"]

expect_both_kept <- function(out) {
  expect_true(all(c("r1", "r2") %in% out$clean$source_ref))
  expect_length(dup_refs(out), 0)
}

# ---- tests -----------------------------------------------------------------

test_that("code: EG020F dissolved + EG020T total for one sample/analyte are both kept", {
  m1 <- "EG020F: Dissolved Metals by ICP-MS"; m2 <- "EG020T: Total Metals by ICP-MS"
  con <- setup_pair("Zinc", m1, m2)
  out <- reconcile_event(mk_event(pair_rows("Zinc", m1, m2)), con)
  expect_both_kept(out)
})

test_that("code: ED093F + ED093T cations are both kept", {
  m1 <- "ED093F: Dissolved Major Cations"; m2 <- "ED093T: Total Major Cations"
  con <- setup_pair("Calcium", m1, m2)
  out <- reconcile_event(mk_event(pair_rows("Calcium", m1, m2)), con)
  expect_both_kept(out)
})

test_that("code: EG035F + EG035T mercury are both kept", {
  m1 <- "EG035F: Dissolved Mercury by FIMS"; m2 <- "EG035T: Total Mercury by FIMS"
  con <- setup_pair("Mercury", m1, m2)
  out <- reconcile_event(mk_event(pair_rows("Mercury", m1, m2)), con)
  expect_both_kept(out)
})

test_that("code: EG005(ED093)F + EG020F (different codes) are both kept", {
  m1 <- "EG005(ED093)F: Dissolved Metals by ICP-AES"; m2 <- "EG020F: Dissolved Metals by ICP-MS"
  con <- setup_pair("Zinc", m1, m2)
  out <- reconcile_event(mk_event(pair_rows("Zinc", m1, m2)), con)
  expect_both_kept(out)
})

test_that("code: EA015 (measured TDS) + EA016 (calculated TDS) are both kept", {
  m1 <- "EA015: Total Dissolved Solids dried at 180 C"; m2 <- "EA016: Conductivity (Calculated) Total Dissolved Solids"
  con <- setup_pair("Total Dissolved Solids", m1, m2)
  out <- reconcile_event(mk_event(pair_rows("Total Dissolved Solids", m1, m2)), con)
  expect_both_kept(out)
})

test_that("code: EP075(SIM)B + EP080 naphthalene are both kept", {
  m1 <- "EP075(SIM)B: Polynuclear Aromatic Hydrocarbons"; m2 <- "EP080: BTEXN"
  con <- setup_pair("Naphthalene", m1, m2)
  out <- reconcile_event(mk_event(pair_rows("Naphthalene", m1, m2)), con)
  expect_both_kept(out)
})

test_that("code: two methods with the SAME code (different text) still collapse; lowest RL wins", {
  m1 <- "EG020F: Dissolved Metals by ICP-MS"; m2 <- "EG020F: Dissolved Metals by ICP-MS (alt)"
  con <- setup_pair("Zinc", m1, m2)
  out <- reconcile_event(mk_event(pair_rows("Zinc", m1, m2)), con)
  expect_true("r1" %in% out$clean$source_ref)
  expect_false("r2" %in% out$clean$source_ref)
  expect_identical(dup_refs(out), "r2")
})

test_that("code: EN67 field pH and EA005P lab pH are both kept", {
  path <- seed_db(); con <- seed_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  # lm-0001 (a-0001 'pH Value', EA005P: pH by PC Titrator) is seeded.
  add_lab_methods(con, "a-0001", data.frame(
    uuid = "lm-1003", name = "pH Value", method = "EN67: Field pH", rl_low = 0.5),
    units = "pH")
  out <- reconcile_event(mk_event(pair_rows("pH Value",
    "EA005P: pH by PC Titrator", "EN67: Field pH", 7.1, 7.4, units = "pH")), con)
  expect_both_kept(out)
})

test_that("code: nitrite as N and nitrite as NO2 under the same code EK057G still collapse", {
  path <- seed_db(); con <- seed_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbExecute(con, "INSERT INTO analyte (uuid, name, units, type, CAS) VALUES
    ('a-0102', 'Nitrite', 'mg/L', 'anion', NULL)")
  add_lab_methods(con, "a-0102", data.frame(
    uuid = c("lm-1004", "lm-1005"), name = c("Nitrite as N", "Nitrite as NO2"),
    method = "EK057G: Nitrite as N by DA", rl_low = c(0.01, 0.05)))
  rows <- mk_rows(
    mk_row(source_ref = "r1", lab_sample_id = "XX1234567002", feature_raw = "T.S02",
           analyte_raw = "Nitrite as N", method_raw = "EK057G: Nitrite as N by DA",
           value_raw = "0.3", value_num = 0.3, below_detection = FALSE, rl = 0.01, units_raw = "mg/L"),
    mk_row(source_ref = "r2", lab_sample_id = "XX1234567002", feature_raw = "T.S02",
           analyte_raw = "Nitrite as NO2", method_raw = "EK057G: Nitrite as N by DA",
           value_raw = "1.0", value_num = 1.0, below_detection = FALSE, rl = 0.05, units_raw = "mg/L"))
  out <- reconcile_event(mk_event(rows), con)
  expect_true("r1" %in% out$clean$source_ref)
  expect_false("r2" %in% out$clean$source_ref)
  expect_identical(dup_refs(out), "r2")
})

test_that("code: the seeded EK040P vs EK040T pair (different codes) is now KEPT BOTH", {
  path <- seed_db(); con <- seed_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  out <- reconcile_event(mk_event(mk_rows(
    mk_row(source_ref = "r1", lab_sample_id = "XX1234567002", feature_raw = "T.S02",
           method_raw = "EK040P: Fluoride by PC Titrator", value_raw = "2.3", value_num = 2.3,
           below_detection = FALSE, rl = 0.1),
    mk_row(source_ref = "r2", lab_sample_id = "XX1234567002", feature_raw = "T.S02",
           method_raw = "EK040T: Fluoride by alt method", value_raw = "2.5", value_num = 2.5,
           below_detection = FALSE, rl = 0.5))), con)
  expect_both_kept(out)
})

test_that("code: a 'CODE - ' prefixed text 'EG020T - EG020T: ...' has code EG020T, distinct from EG020F, so both are kept", {
  m1 <- "EG020F: Dissolved Metals by ICP-MS"; m2 <- "EG020T - EG020T: Total Metals by ICP-MS"
  con <- setup_pair("Zinc", m1, m2)
  out <- reconcile_event(mk_event(pair_rows("Zinc", m1, m2)), con)
  expect_both_kept(out)
})

test_that("code: end to end - dissolved + total both reach clean AND are committed as two analysis rows", {
  m1 <- "EG020F: Dissolved Metals by ICP-MS"; m2 <- "EG020T: Total Metals by ICP-MS"
  con <- setup_pair("Zinc", m1, m2)
  event <- mk_event(pair_rows("Zinc", m1, m2, 1.1, 2.2))
  before <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM analysis")$n
  out <- reconcile_event(event, con)
  expect_both_kept(out)
  commit_event(event, out, con)
  after <- DBI::dbGetQuery(con, "SELECT value FROM analysis")
  expect_equal(nrow(after) - before, 2)
  expect_true(all(c(1.1, 2.2) %in% after$value))
})

test_that("code: end to end - field pH + lab pH both committed", {
  path <- seed_db(); con <- seed_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  add_lab_methods(con, "a-0001", data.frame(
    uuid = "lm-1003", name = "pH Value", method = "EN67: Field pH", rl_low = 0.5),
    units = "pH")
  event <- mk_event(pair_rows("pH Value", "EA005P: pH by PC Titrator", "EN67: Field pH", 7.1, 7.4, units = "pH"))
  before <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM analysis")$n
  out <- reconcile_event(event, con)
  expect_both_kept(out)
  commit_event(event, out, con)
  after <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM analysis")$n
  expect_equal(after - before, 2)
})
