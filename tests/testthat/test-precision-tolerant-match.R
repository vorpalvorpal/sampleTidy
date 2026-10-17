# tests/testthat/test-precision-tolerant-match.R
#
# A92 (Robin, 2026-10-17; amends A14): a stored value MORE precise than the
# source report prints it is already present.
#
# Legacy values are sometimes stored with more digits than a report prints:
# field pH 6.59 where the ACIRL report prints 6.6, field EC 94.74 where it
# prints 95. Re-importing such a report raised a false value_conflict under
# A14's exact equality. A92 adds one more way to be equal. It applies when
# both the incoming and the existing value are numeric and quantified, and
# they differ under A14. Let d be the number of decimal places PRINTED in
# the incoming `value_raw`, e.g. "6.6" -> 1, "95" -> 0, "6.60" -> 2. The
# pair is equal when the existing value, rounded HALF AWAY FROM ZERO to d
# places, equals the incoming value within A14's tolerance. The stored value
# is never changed.
#
#   * Only a plain decimal numeral `^-?[0-9]+([.][0-9]+)?$` (after trimws)
#     yields d. Scientific notation, float-noise strings, "<"/">" and
#     anything else fall back to plain A14.
#   * d comes from `value_raw`, NEVER from `value_num`: readxl's text of a
#     numeric cell can be float noise ("94.73999999999999"), and that
#     yields a large d, so the rule does not fire. Accepted.
#   * Less precise stored against more precise incoming is still a
#     conflict, because rounding a 1-dp value to 2 dp leaves it unchanged.
#   * [ASSUMED, main agent to confirm] Unit conversion and
#     `conversion_constant`. d counts digits in the SOURCE unit, so it is
#     shifted by the scale between `value_raw` and the canonical incoming
#     value: d_eff = d - log10(k), with k = incoming / as.numeric(value_raw).
#     It is used only when k is a power of ten (% -> L/L, uS/cm -> mS/cm,
#     mg/L -> ug/L). Any other k (a conversion_constant of 2, an affine
#     temperature conversion), or a raw value of 0, falls back to A14.
#   * Several candidates (`.rc_find_existing()` rule 1): a rounding-equal
#     candidate counts as equal. An exactly equal candidate beats one that is
#     equal only by rounding, even when rules 2/3 (work order, lowest uuid)
#     would prefer the rounding one. Rules 2/3 still order candidates within
#     the best tier.
#
# Every test except the last drives the real, read-only `reconcile_event()`
# on a seed_db() copy. The last one is a full `ingest_dir()` re-ingest. The
# fixture shapes are those of test-existing-row-preference.R: date-only ACIRL
# field rows at T.MW01 (fa-0003) on 2025-09-04, away from seed sample
# s-0001's instant.

# ---- fixture (adapted from test-existing-row-preference.R) -----------------------

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

ptm_day <- "2025-09-04"

ptm_utc <- function(date, hm) {
  format(as.POSIXct(paste(date, hm), tz = "Australia/Sydney"), tz = "UTC",
         "%Y-%m-%d %H:%M:%S")
}

# seed_db() plus a field pH method (pH analyte a-0001), a field ORP analyte and
# method in mV (for negatives and values pH's history would call implausible),
# and three ALS work orders.
ptm_db <- function(env = parent.frame()) {
  path <- seed_db(dir = withr::local_tempdir(.local_envir = env))
  con <- seed_con(path)
  DBI::dbExecute(con, "INSERT INTO analyte (uuid, name, units, type, CAS) VALUES
    ('a-orp', 'ORP', 'mV', 'field', NULL)")
  DBI::dbExecute(con, "INSERT INTO lab_method
    (uuid, uuid_analyte, name, method, organisation, rl_low, units, conversion_constant) VALUES
    ('lm-fph', 'a-0001', 'Field pH', 'field', 'ACIRL', NULL, 'pH', NULL),
    ('lm-forp', 'a-orp', 'Field ORP', 'field', 'ACIRL', NULL, 'mV', NULL)")
  DBI::dbExecute(con, "INSERT INTO project (uuid, uuid_parent, uuid_root, name, type) VALUES
    ('p-wa', NULL, NULL, 'ES2232312', 'Work order'),
    ('p-wb', NULL, NULL, 'ES2232317', 'Work order'),
    ('p-wc', NULL, NULL, 'ES2299999', 'Work order')")
  con
}

# One existing sample at T.MW01 on ptm_day holding ONE analysis. Numeric by
# default; pass `value_chr` (and value = NA) for a text result, `quantified`
# FALSE for a non-detect.
ptm_sample <- function(con, uuid, project, an_uuid, value, lab = "lm-fph",
                       hm = "09:25", org = "ACIRL", quantified = TRUE,
                       value_chr = NA_character_, day = ptm_day, alias = "fa-0003") {
  DBI::dbExecute(con, "INSERT INTO \"sample\"
    (uuid, uuid_feature_alias, uuid_project, date, datetime, organisation)
    VALUES (?, ?, ?, CAST(? AS TIMESTAMP), CAST(? AS TIMESTAMP), ?)",
    params = list(uuid, alias, project, ptm_utc(day, "00:00"), ptm_utc(day, hm), org))
  DBI::dbExecute(con, "INSERT INTO analysis (uuid, uuid_sample, uuid_lab, value, value_chr, quantified, rl_low)
                       VALUES (?, ?, ?, ?, ?, ?, NULL)",
                 params = list(an_uuid, uuid, lab, value, value_chr, quantified))
  invisible(uuid)
}

# An ACIRL field-sheet row whose `value_raw` is the PRINTED text, given
# separately from the parsed number (which defaults to as.numeric(raw)), so a
# test can make them disagree in the way readxl's float-noise text does.
ptm_field_row <- function(raw, value = suppressWarnings(as.numeric(raw)),
                          analyte = "Field pH", units = "pH", ref = "fld-1",
                          value_chr = NA_character_, report_no = "2400-7286-06-01") {
  tibble::as_tibble(list(
    source_hash = "hash-ptm", source_ref = ref, work_order = report_no,
    revision = 0L, org = "ACIRL", adapter = "acirl_field_xlsx/1",
    lab_sample_id = "T.MW01", sample_type = "Normal",
    feature_raw = "T.MW01", analyte_raw = analyte, cas_number = NA_character_,
    method_raw = NA_character_, total_or_filtered = NA_character_, units_raw = units,
    value_raw = raw, value_num = value, value_chr = value_chr,
    below_detection = FALSE, rl = NA_real_, lab_qualifier = NA_character_,
    analysed_date = as.Date(NA), comments = NA_character_, confidence = 1,
    sample_datetime_raw = "04/09/2025", sampler = NA_character_,
    matrix_raw = "Water", parent_sample = NA_character_
  ))
}

ptm_acirl_event <- function(rows, cited = character(0), report_no = "2400-7286-06-01") {
  h <- "hash-ptm"
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

ptm_conflicts <- function(out) out$review[out$review$kind == "value_conflict", , drop = FALSE]

# One existing analysis `an-x` holding `stored` on `lab`; reconcile one
# incoming field row printed as `raw`. Returns the reconcile output.
ptm_one <- function(stored, raw, lab = "lm-fph", analyte = "Field pH", units = "pH",
                    value = suppressWarnings(as.numeric(raw)), env = parent.frame()) {
  con <- ptm_db(env = env)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE), envir = env)
  ptm_sample(con, "s-x", "p-wa", "an-x", stored, lab = lab)
  reconcile_event(ptm_acirl_event(ptm_field_row(raw, value = value, analyte = analyte,
                                                units = units)), con)
}

expect_already_present <- function(out, existing = "an-x", ref = "fld-1") {
  expect_equal(nrow(ptm_conflicts(out)), 0)
  hit <- out$skipped[out$skipped$source_ref == ref, , drop = FALSE]
  expect_equal(nrow(hit), 1)
  expect_identical(hit$reason, "already_present")
  expect_identical(hit$existing_uuid, existing)
  expect_false(ref %in% out$clean$source_ref)
}

expect_value_conflict <- function(out, existing = "an-x", ref = "fld-1") {
  vc <- ptm_conflicts(out)
  expect_equal(nrow(vc), 1)
  expect_identical(vc$source_ref, ref)
  expect_identical(vc$uuid_existing, existing)
  expect_false("already_present" %in% out$skipped$reason)
  expect_false(ref %in% out$clean$source_ref)
}

# ---- the ruling's two cases ----------------------------------------------------------

test_that("A92: stored field pH 6.59 vs a report printing \"6.6\" -> already_present, not a value_conflict", {
  out <- ptm_one(6.59, "6.6")
  expect_already_present(out)
  # The skip's diagnostics report the two values as they are; nothing rewrites
  # the stored 6.59 to the printed 6.6.
  hit <- out$skipped[out$skipped$source_ref == "fld-1", , drop = FALSE]
  if (nrow(hit) == 1) {
    diag <- jsonlite::fromJSON(hit$payload[[1]])
    expect_equal(diag$value_existing, 6.59)
    expect_equal(diag$value_incoming, 6.6)
  }
})

test_that("A92: stored 94.74 vs a report printing \"95\" (d = 0; the field-EC shape, on an mV method) -> already_present", {
  out <- ptm_one(94.74, "95", lab = "lm-forp", analyte = "Field ORP", units = "mV")
  expect_already_present(out)
})

# ---- the direction and the rounding boundary ------------------------------------

test_that("A92: LESS precise stored 6.6 vs a more precise \"6.59\" -> still a value_conflict", {
  expect_value_conflict(ptm_one(6.6, "6.59"))
})

test_that("A92: stored 6.64 vs \"6.7\" -> value_conflict (6.64 rounds to 6.6)", {
  expect_value_conflict(ptm_one(6.64, "6.7"))
})

test_that("A92: stored 6.65 vs \"6.7\" -> already_present (half away from zero)", {
  expect_already_present(ptm_one(6.65, "6.7"))
})

test_that("A92: rounding is DECIMAL half-away-from-zero, not R's round() (0.15 -> 0.2, 2.5 -> 3, 94.5 -> 95)", {
  # R's round() gives 0.1 (binary 0.1499...), 2 (IEC 60559 half-to-even) and 94.
  # A report rounds the decimal number half away from zero.
  expect_already_present(ptm_one(0.15, "0.2", lab = "lm-forp", analyte = "Field ORP", units = "mV"))
  expect_already_present(ptm_one(2.5, "3", lab = "lm-forp", analyte = "Field ORP", units = "mV"))
  expect_already_present(ptm_one(94.5, "95", lab = "lm-forp", analyte = "Field ORP", units = "mV"))
})

test_that("A92: stored 94.4 vs \"95\" -> value_conflict (94.4 rounds to 94)", {
  expect_value_conflict(ptm_one(94.4, "95", lab = "lm-forp", analyte = "Field ORP", units = "mV"))
})

test_that("A92: printed trailing zeros count - stored 6.59 vs \"6.60\" (d = 2) -> value_conflict", {
  expect_value_conflict(ptm_one(6.59, "6.60"))
})

# ---- negatives ------------------------------------------------------------------------

test_that("A92: negative values - stored -12.46 vs \"-12.5\" -> already_present; -6.65 vs \"-6.7\" -> already_present (away from zero); -6.65 vs \"-6.6\" -> value_conflict", {
  orp <- function(stored, raw) ptm_one(stored, raw, lab = "lm-forp", analyte = "Field ORP",
                                       units = "mV", env = parent.frame())
  expect_already_present(orp(-12.46, "-12.5"))
  expect_already_present(orp(-6.65, "-6.7"))
  expect_already_present(orp(-2.5, "-3"))
  expect_value_conflict(orp(-6.65, "-6.6"))
})

# ---- where the rule does NOT apply ------------------------------------------------------

test_that("A92: a non-detect is untouched - \"<0.1\" against a stored non-detect of 0.12 stays a value_conflict, and against 0.1 stays already_present", {
  # Seed an-0001 is Fluoride <0.1 mg/L stored as 100 ug/L, quantified FALSE,
  # on s-0001 (T.S01, 24 May 2025 11:45). mk_row()'s default IS that row. With
  # the "<" stripped, "0.1" would round-match 0.12 mg/L (= 120 ug/L).
  path <- seed_db(dir = withr::local_tempdir())
  con <- seed_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  same <- reconcile_event(mk_event(mk_row()), con)
  expect_identical(same$skipped$reason, "already_present")

  DBI::dbExecute(con, "UPDATE analysis SET value = 120, rl_low = 120 WHERE uuid = 'an-0001'")
  out <- reconcile_event(mk_event(mk_row()), con)
  vc <- ptm_conflicts(out)
  expect_equal(nrow(vc), 1)
  expect_identical(vc$uuid_existing, "an-0001")
  expect_false("already_present" %in% out$skipped$reason)
})

test_that("A92: a quantified incoming value against a stored NON-DETECT is still a conflict (both sides must be quantified)", {
  con <- ptm_db()
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  ptm_sample(con, "s-x", "p-wa", "an-x", 6.59, quantified = FALSE)
  out <- reconcile_event(ptm_acirl_event(ptm_field_row("6.6")), con)
  expect_value_conflict(out)
})

test_that("A92: d comes from value_raw, never value_num - a float-noise raw value keeps today's behaviour", {
  # readxl's text of a numeric cell (col_types = "text") can be float noise:
  # measured, 94.74 reads back as "94.73999999999999". d is then 14, so the
  # rule does not fire. Deriving d from format(value_num) instead ("94.74",
  # d = 2) would wrongly round-match 94.736.
  expect_value_conflict(ptm_one(94.736, "94.73999999999999", value = 94.74,
                                lab = "lm-forp", analyte = "Field ORP", units = "mV"))
  expect_value_conflict(ptm_one(6.59, "6.6000000000000005", value = 6.6))
  # The spec's example: "0.0299999999999999" is d = 16.
  expect_value_conflict(ptm_one(0.0312, "0.0299999999999999", value = 0.03,
                                lab = "lm-forp", analyte = "Field ORP", units = "mV"))
  # Today's A14 equality still holds for a float-noise raw value equal to the
  # stored one.
  expect_already_present(ptm_one(94.74, "94.73999999999999", value = 94.74,
                                 lab = "lm-forp", analyte = "Field ORP", units = "mV"))
})

test_that("A92: scientific notation is not a plain decimal numeral -> today's behaviour", {
  expect_value_conflict(ptm_one(6.59, "6.6E+00", value = 6.6))
  expect_value_conflict(ptm_one(6.59, "6.6e0", value = 6.6))
})

test_that("A92: text values are untouched - compared by identity as before", {
  txt <- function(stored_chr, inc_chr, raw = inc_chr) {
    con <- ptm_db(env = parent.frame())
    withr::defer(DBI::dbDisconnect(con, shutdown = TRUE), envir = parent.frame())
    ptm_sample(con, "s-x", "p-wa", "an-x", NA_real_, quantified = NA, value_chr = stored_chr)
    reconcile_event(ptm_acirl_event(ptm_field_row(raw, value = NA_real_, value_chr = inc_chr)), con)
  }
  expect_already_present(txt("Turbid", "Turbid"))
  expect_value_conflict(txt("Turbid", "Clear"))
  # A text result that happens to look like a number is still text: "6.59"
  # stored as text against "6.6" as text is a difference.
  expect_value_conflict(txt("6.59", "6.6"))
})

# ---- unit scaling [ASSUMED] ----------------------------------------------------------------

test_that("A92 [ASSUMED]: d counts SOURCE-unit digits under a power-of-ten unit conversion - ALS EC \"95\" uS/cm vs stored 0.09474 mS/cm -> already_present", {
  # seed analyte a-0003 EC is mS/cm; ALS lm-0003 reports uS/cm, so the incoming
  # 95 becomes 0.095. In mS/cm the printed precision is 3 dp, not 0.
  con <- ptm_db()
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  ptm_sample(con, "s-ec", "p-wb", "an-ec", 0.09474, lab = "lm-0003", org = "ALS")
  row <- mk_row(
    source_ref = "als-ec", work_order = "ES2232317", lab_sample_id = "ES2232317001",
    feature_raw = "T.MW01", analyte_raw = "Electrical Conductivity @ 25°C",
    cas_number = NA_character_, method_raw = "EA010P: Conductivity by PC Titrator",
    units_raw = "µS/cm", value_raw = "95", value_num = 95, below_detection = FALSE,
    rl = 1, sample_datetime_raw = "04 Sep 2025 09:25"
  )
  out <- reconcile_event(mk_event(row, work_order = "ES2232317"), con)
  expect_already_present(out, existing = "an-ec", ref = "als-ec")

  # ...and 0.0944 mS/cm (= 94.4 uS/cm, which rounds to 94) is a conflict.
  DBI::dbExecute(con, "UPDATE analysis SET value = 0.0944 WHERE uuid = 'an-ec'")
  out2 <- reconcile_event(mk_event(row, work_order = "ES2232317"), con)
  expect_value_conflict(out2, existing = "an-ec", ref = "als-ec")
})

test_that("A92 [ASSUMED]: a scale that is not a power of ten (conversion_constant 2) falls back to A14", {
  # lm-0012 'Fluoride as F': mg/L -> ug/L (x1000), then conversion_constant 2,
  # so "0.33" compares as 660. Stored 659: 659 / 2000 = 0.3295 would round to
  # 0.33, but k = 2000 is not a power of ten, so A14 decides -> conflict.
  path <- seed_db(dir = withr::local_tempdir())
  con <- seed_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbExecute(con, "INSERT INTO analysis (uuid, uuid_sample, uuid_lab, value, quantified, rl_low)
                       VALUES ('an-cc', 's-0001', 'lm-0012', 659, TRUE, 200)")
  row <- mk_row(source_ref = "cc", analyte_raw = "Fluoride as F", value_raw = "0.33",
                value_num = 0.33, below_detection = FALSE, rl = 0.1)
  out <- reconcile_event(mk_event(row), con)
  vc <- ptm_conflicts(out)
  expect_equal(nrow(vc), 1)
  expect_identical(vc$uuid_existing, "an-cc")
})

# ---- several candidates (.rc_find_existing rule 1) ------------------------------------------

# Two samples on two ALS orders, each holding one field pH reading. an-a has
# the lower uuid, so it is cand[1]. They are inserted in reverse uuid order so
# storage order and the ORDER BY disagree.
ptm_split <- function(con, value_a, value_b) {
  ptm_sample(con, "s-b", "p-wb", "an-b", value_b, hm = "09:25")
  ptm_sample(con, "s-a", "p-wa", "an-a", value_a, hm = "09:20")
}

test_that("A92 multi-candidate: an EXACT candidate beats a rounding-only one, even when the report cites the rounding one's order", {
  con <- ptm_db()
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  ptm_split(con, value_a = 6.59, value_b = 6.6)   # an-a rounds to 6.6; an-b is exact

  out <- reconcile_event(ptm_acirl_event(ptm_field_row("6.6"), cited = "ES2232312"), con)
  expect_already_present(out, existing = "an-b")
})

test_that("A92 multi-candidate: exact beats rounding the other way round too (exact is cand[1], the report cites the rounding one's order)", {
  con <- ptm_db()
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  ptm_split(con, value_a = 6.6, value_b = 6.59)

  out <- reconcile_event(ptm_acirl_event(ptm_field_row("6.6"), cited = "ES2232317"), con)
  expect_already_present(out, existing = "an-a")
})

test_that("A92 multi-candidate: a rounding-equal candidate counts as equal - it beats an unequal cand[1] on the cited order", {
  con <- ptm_db()
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  ptm_split(con, value_a = 7.3, value_b = 6.59)

  out <- reconcile_event(ptm_acirl_event(ptm_field_row("6.6"), cited = "ES2232312"), con)
  expect_already_present(out, existing = "an-b")
})

test_that("A92 multi-candidate: of two candidates on either side of a rounding boundary, the one that rounds to the printed value wins", {
  con <- ptm_db()
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  ptm_split(con, value_a = 6.64, value_b = 6.66)  # 6.6 and 6.7

  out <- reconcile_event(ptm_acirl_event(ptm_field_row("6.7")), con)
  expect_already_present(out, existing = "an-b")
})

test_that("A92 multi-candidate: two rounding-equal candidates -> already_present, ordered by rules 2/3 as before", {
  con <- ptm_db()
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  ptm_split(con, value_a = 6.58, value_b = 6.61)  # both round to 6.6

  none <- reconcile_event(ptm_acirl_event(ptm_field_row("6.6")), con)
  expect_already_present(none, existing = "an-a")         # rule 3: lowest uuid

  cited_b <- reconcile_event(ptm_acirl_event(ptm_field_row("6.6"), cited = "ES2232317"), con)
  expect_already_present(cited_b, existing = "an-b")      # rule 2: the cited order
})

test_that("A92 multi-candidate: neither candidate equal by either test -> the value_conflict names the rule-2 candidate as today", {
  con <- ptm_db()
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  ptm_split(con, value_a = 7.3, value_b = 6.64)

  out <- reconcile_event(ptm_acirl_event(ptm_field_row("6.7"), cited = "ES2232317"), con)
  expect_value_conflict(out, existing = "an-b")
})

# ---- end to end -----------------------------------------------------------------------------

ptm_esdat_pair <- function(dir, stem, wo, ph_raw, analysed = "05 Sep 2025", lab_comment = "") {
  writeLines(c(
    "SampleCode,ChemCode,OriginalChemName,Prefix,Result,Result_Unit,Total_or_Filtered,Result_Type,Method_Type,Method_Name,Extraction_Date,Analysed_Date,EQL,EQL_Units,Comments,Lab_Qualifier,UCL,LCL",
    sprintf("%s001,,pH Value,,%s,pH Unit,T,Numeric,pH by PC Titrator,EA005P: pH by PC Titrator,,%s,0.01,pH Unit,,,,",
            wo, ph_raw, analysed)
  ), file.path(dir, paste0(stem, ".ESDAT_", wo, "_0.Chemistry2e.CSV")))
  writeLines(c(
    "SampleCode,Sampled_Date_Time,Field_ID,Blank1,Depth,Blank2,Matrix_Type,Sample_Type,Parent_Sample,Blank3,SDG,Lab_Name,Lab_SampleID,Lab_Comments,Lab_Report_Number",
    sprintf("%s001,04 Sep 2025 09:00,T.S01,,,,WATER,Normal,,,,ALSE-Sydney,%s001,%s,%s",
            wo, wo, lab_comment, wo)
  ), file.path(dir, paste0(stem, ".ESDAT_", wo, "_0.Sample2e.CSV")))
}

test_that("A92 end to end: re-ingesting a report that prints pH \"6.6\" over a stored 6.59 commits nothing, raises no value_conflict and leaves 6.59 in place", {
  db_path <- seed_db(dir = withr::local_tempdir())
  con <- seed_con(db_path)
  ensure_test_asset_table(con)
  DBI::dbDisconnect(con, shutdown = TRUE)
  withr::local_options(list(
    "sampletidy.archive_dir" = withr::local_tempdir(),
    "sampletidy.snapshot_dir" = withr::local_tempdir(),
    "sampletidy.remove_ingested" = FALSE
  ))

  wo <- "XX2468024"
  first <- withr::local_tempdir()
  ptm_esdat_pair(first, "PROJ_P", wo, "6.6")
  r1 <- ingest_dir(first, db = db_path)
  expect_equal(r1$n_events_committed, 1)

  # The legacy shape: the stored value is MORE precise than the report prints.
  con <- DBI::dbConnect(duckdb::duckdb(), db_path)
  stored <- DBI::dbGetQuery(con,
    "SELECT a.uuid FROM analysis a JOIN \"sample\" s ON s.uuid = a.uuid_sample
       JOIN project p ON p.uuid = s.uuid_project
      WHERE p.name = ? AND a.uuid_lab = 'lm-0001'", params = list(wo))
  expect_equal(nrow(stored), 1)
  DBI::dbExecute(con, "UPDATE analysis SET value = 6.59 WHERE uuid = ?", params = list(stored$uuid))
  n_analysis <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM analysis")$n
  n_review <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM review_queue")$n
  DBI::dbDisconnect(con, shutdown = TRUE)

  # A content-different re-download of the same report, still printing 6.6.
  # BOTH files differ from the first pair: an identical Sample2e would be
  # hash-deduped, leaving the chemistry with no sample metadata.
  second <- withr::local_tempdir()
  ptm_esdat_pair(second, "PROJ_P_REDL", wo, "6.6", analysed = "06 Sep 2025",
                 lab_comment = "re-issued")
  ingest_dir(second, db = db_path)

  con <- DBI::dbConnect(duckdb::duckdb(), db_path, read_only = TRUE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  expect_equal(DBI::dbGetQuery(con, "SELECT count(*) AS n FROM analysis")$n, n_analysis)
  expect_equal(
    DBI::dbGetQuery(con, "SELECT value FROM analysis WHERE uuid = ?", params = list(stored$uuid))$value,
    6.59
  )
  expect_equal(DBI::dbGetQuery(con, "SELECT count(*) AS n FROM review_queue")$n, n_review)
  expect_equal(
    DBI::dbGetQuery(con, "SELECT count(*) AS n FROM review_queue WHERE kind = 'value_conflict'")$n, 0
  )
})
