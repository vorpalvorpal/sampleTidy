# Stage 3 of the layer move (D4): the QC flags name the sampler from the stream
# table's field organisation instead of a hard-coded "ACIRL".
#
#   exactly one field organisation (matched case-insensitively, spelled as in
#   the table)  ->  its spelling in the text, and action ask_<lower-case spelling>
#   none, or two or more                        ->  "the sampler", ask_sampler
#   lab_qc_missing                              ->  "ask <org>/ALS for the QC
#                                                    report", else "ask ALS ..."
#
# The ALS wording ("ALS QC Interpretive report (QCI)") is lab-format and stays.
# test-qc-dup-rpd, test-qc-missing and test-flags-missing-result pin the
# unchanged output under fl_test_streams() (ACIRL field).
#
# Synthetic: site Q, organisations FIELDCO (field) and LABCO (lab).

sw_wo <- "ES2600501"
sw_d <- "2026-09-28"

sw_checks <- function(streams) {
  ch <- qc_checks()
  ch["streams"] <- list(streams)
  ch
}

sw_field_only <- function(org) {
  sx_streams(list(stream = "field", organisation = org, kind = "field", water = TRUE),
             list(stream = "lab", organisation = "LABCO", kind = "lab", water = TRUE,
                  expects_qci = TRUE))
}

sw_two_fields <- function() {
  sx_streams(list(stream = "field", organisation = "FIELDCO", kind = "field", water = TRUE),
             list(stream = "field2", organisation = "OTHERCO", kind = "field", water = TRUE),
             list(stream = "lab", organisation = "LABCO", kind = "lab", water = TRUE,
                  expects_qci = TRUE))
}

sw_no_field <- function() {
  sx_streams(list(stream = "lab", organisation = "LABCO", kind = "lab", water = TRUE,
                  expects_qci = TRUE))
}

# One run holding all four flags: a mislabelled duplicate (3 of 4 analytes fail
# the RPD), a QC code with no qc_feature row (unresolved), a September round
# short of its rinsate and filter blanks (qc_missing) and a lab work order with
# no QCI (lab_qc_missing).
# The lab results of LABCO's samples (helper-qc.R's qc_lab() says lab_org "ALS").
sw_lab <- function(analyte, value, rl = NA_real_, quantified = TRUE,
                   method = "EG020T: Total Metals by ICP-MS") {
  x <- qc_lab(analyte, value, rl = rl, quantified = quantified, method = method)
  x$lab_org <- "LABCO"
  x
}
sw_nd <- function(analyte, rl) sw_lab(analyte, rl, rl = rl, quantified = FALSE)

sw_flags <- function(streams) {
  db <- qc_db()
  fl_with(db, function(con) {
    qc_add(con, "Q.JD42", "duplicate", parent = "Q.X01")
    qc_add(con, "Q.JF42", "field_blank", parent = "Q.X01")
    qc_add(con, "Q.JD43", "duplicate", parent = "Q.X01", date_start = "2026-01-01",
           date_end = "2026-06-30")
    par <- lapply(c("Fail01", "Fail02", "Fail03", "Pass01"), function(a) sw_lab(a, 0.10, rl = 0.001))
    dup <- c(lapply(c("Fail01", "Fail02", "Fail03"), function(a) sw_lab(a, 0.30, rl = 0.001)),
             list(sw_lab("Pass01", 0.10, rl = 0.001)))
    fl_sample(con, "Q.X01", sw_wo, sw_d, org = "LABCO", results = par)
    fl_sample(con, "Q.JD42", sw_wo, sw_d, org = "LABCO", results = dup)
    fl_sample(con, "Q.JF42", sw_wo, sw_d, org = "LABCO", results = list(sw_nd("Zinc", 0.005)))
    fl_sample(con, "Q.JD43", sw_wo, sw_d, org = "LABCO", results = list(sw_lab("Zinc", 0.02, rl = 0.005)))
  })
  f <- fl_run(db, sw_checks(streams))
  expect_length(attr(f, "errors"), 0)
  f
}

sw_row <- function(f, check) {
  r <- fl_of(f, check)
  expect_gte(nrow(r), 1)
  r[1, , drop = FALSE]
}

# ---- one field organisation: FIELDCO ---------------------------------------------------

test_that("FIELDCO as the one field organisation: the mislabel flag asks FIELDCO, action ask_fieldco", {
  m <- sw_row(sw_flags(sw_field_only("FIELDCO")), "qc_dup_rpd")
  expect_identical(m$action, "ask_fieldco")
  expect_match(m$detail, "check the label with FIELDCO", fixed = TRUE)
  expect_match(m$detail, "ask FIELDCO whether", fixed = TRUE)
  expect_false(grepl("ACIRL", m$detail, fixed = TRUE))
})

test_that("FIELDCO: qc_unresolved asks FIELDCO which point and QC type it is, action ask_fieldco", {
  un <- fl_of(sw_flags(sw_field_only("FIELDCO")), "qc_unresolved")
  un <- un[un$key == sprintf("qc_unresolved|Q.JD43|%s", sw_d), , drop = FALSE]
  expect_equal(nrow(un), 1)
  expect_match(un$detail, "ask FIELDCO which point", fixed = TRUE)
  expect_identical(un$action, "ask_fieldco")
  expect_false(grepl("ACIRL", un$detail, fixed = TRUE))
})

test_that("FIELDCO: qc_missing chases FIELDCO for the missing QC samples", {
  qm <- sw_row(sw_flags(sw_field_only("FIELDCO")), "qc_missing")
  expect_match(qm$detail, "chase FIELDCO for the missing QC samples", fixed = TRUE)
  expect_false(grepl("ACIRL", qm$detail, fixed = TRUE))
})

test_that("FIELDCO: lab_qc_missing with no QCI asks FIELDCO/ALS for the QC report", {
  lm <- sw_row(sw_flags(sw_field_only("FIELDCO")), "lab_qc_missing")
  expect_match(lm$detail, "ask FIELDCO/ALS for the QC report", fixed = TRUE)
  expect_match(lm$detail, "no ALS QC Interpretive report (QCI) received", fixed = TRUE)
  expect_false(grepl("ACIRL", lm$detail, fixed = TRUE))
})

# ---- no field organisation, or two ------------------------------------------------------

test_that("with no field evidence row the wording says 'the sampler', action ask_sampler, and lab_qc_missing asks ALS", {
  f <- sw_flags(sw_no_field())
  m <- sw_row(f, "qc_dup_rpd")
  expect_identical(m$action, "ask_sampler")
  expect_match(m$detail, "check the label with the sampler", fixed = TRUE)
  expect_match(m$detail, "ask the sampler whether", fixed = TRUE)
  un <- fl_of(f, "qc_unresolved")
  expect_true(all(un$action == "ask_sampler"))
  expect_true(any(grepl("ask the sampler which point", un$detail, fixed = TRUE)))
  expect_match(sw_row(f, "qc_missing")$detail, "chase the sampler for the missing QC samples", fixed = TRUE)
  lm <- sw_row(f, "lab_qc_missing")
  expect_match(lm$detail, "ask ALS for the QC report", fixed = TRUE)
  expect_false(grepl("/ALS", lm$detail, fixed = TRUE))
})

test_that("with two different field organisations the wording is the same generic one", {
  f <- sw_flags(sw_two_fields())
  m <- sw_row(f, "qc_dup_rpd")
  expect_identical(m$action, "ask_sampler")
  expect_match(m$detail, "check the label with the sampler", fixed = TRUE)
  expect_match(sw_row(f, "qc_missing")$detail, "chase the sampler for the missing QC samples", fixed = TRUE)
  lm <- sw_row(f, "lab_qc_missing")
  expect_match(lm$detail, "ask ALS for the QC report", fixed = TRUE)
  expect_false(grepl("FIELDCO|OTHERCO", paste(lm$detail, m$detail)))
})

# ---- spelling ---------------------------------------------------------------------------

test_that("the organisation is written as spelled in the stream table: 'Fieldco' gives 'Fieldco' and ask_fieldco", {
  f <- sw_flags(sw_field_only("Fieldco"))
  m <- sw_row(f, "qc_dup_rpd")
  expect_match(m$detail, "check the label with Fieldco", fixed = TRUE)
  expect_identical(m$action, "ask_fieldco")
  expect_match(sw_row(f, "lab_qc_missing")$detail, "ask Fieldco/ALS for the QC report", fixed = TRUE)
})
