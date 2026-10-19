# PLAN-19 R-19.27 `qc_missing`, R-19.28 `qc_unresolved` and R-19.31
# `lab_qc_missing` (+ ruling R19-10 (7): qc_missing waits until the round's
# expected deliveries have all arrived).
#
# Codes and parents are invented (site Q; helper-qc.R). Requirements are
# qc_requirements_df(): duplicate, field, rinsate and filter blank in months
# 3;6;9;12 (and a transport blank in month 3), from 2026-09-01.

wo <- "ES2600501"
d_round <- "2026-09-28"
tot <- "EG020T: Total Metals by ICP-MS"
filt <- "EG020F: Dissolved Metals by ICP-MS"
toc <- function() qc_lab("Total Organic Carbon", 1, rl = 1, quantified = FALSE,
                         method = "EP005: Total Organic Carbon (TOC)")

# A Sep 2026 round at Q: the point Q.X01, a duplicate and a field blank of it.
sep_round <- function(con) {
  qc_add(con, "Q.JD42", "duplicate", parent = "Q.X01")
  qc_add(con, "Q.JF42", "field_blank", parent = "Q.X01")
  fl_sample(con, "Q.X01", wo, d_round, results = list(qc_lab("Zinc", 0.02, rl = 0.005)))
  fl_sample(con, "Q.JD42", wo, d_round, results = list(qc_lab("Zinc", 0.02, rl = 0.005)))
  fl_sample(con, "Q.JF42", wo, d_round, results = list(qc_nd("Zinc", 0.005)))
}

# ---- qc_missing ------------------------------------------------------------------

test_that("qc_missing: one flag per (site, month) listing the short QC types; action chase", {
  db <- qc_db()
  fl_with(db, sep_round)
  f <- fl_run(db, qc_checks())
  expect_length(attr(f, "errors"), 0)
  qm <- fl_of(f, "qc_missing")
  expect_equal(nrow(qm), 1)
  expect_identical(qm$key, "qc_missing|Q|2026-09")
  expect_identical(qm$site, "Q")
  expect_identical(substr(qm$date, 1, 7), "2026-09")
  expect_identical(qm$action, "chase")
  expect_match(qm$detail, "no rinsate blank", fixed = TRUE)
  expect_match(qm$detail, "no filter blank", fixed = TRUE)
  expect_false(grepl("no duplicate", qm$detail, fixed = TRUE))
  expect_false(grepl("no field blank", qm$detail, fixed = TRUE))
  expect_match(qm$detail, "Sep 2026 (quarterly|annual)")
  expect_match(qm$detail, "→ chase", fixed = TRUE)
})

test_that("qc_missing: QC samples count in any project of the month; nothing short -> no flag", {
  db <- qc_db()
  fl_with(db, function(con) {
    sep_round(con)
    qc_add(con, "Q.JR42", "rinsate_blank", parent = "Q.X01")
    qc_add(con, "Q.JL00", "filter_blank")
    # in a second work order of the same month
    fl_sample(con, "Q.JR42", "ES2600502", "2026-09-29",
              results = list(qc_nd("Zinc", 0.005, method = tot), toc()))
    fl_sample(con, "Q.JL00", "ES2600502", "2026-09-29",
              results = list(qc_nd("Zinc", 0.005, method = filt)))
  })
  f <- fl_run(db, qc_checks())
  expect_length(attr(f, "errors"), 0)
  expect_equal(nrow(fl_of(f, "qc_missing")), 0)
})

test_that("qc_missing: a rinsate blank with a field-filtered result is not a decontamination test", {
  db <- qc_db()
  fl_with(db, function(con) {
    sep_round(con)
    qc_add(con, "Q.JR42", "rinsate_blank", parent = "Q.X01")
    qc_add(con, "Q.JL00", "filter_blank")
    fl_sample(con, "Q.JR42", wo, d_round, results = list(
      qc_nd("Zinc", 0.005, method = tot), toc(), qc_nd("Copper", 0.001, method = filt)))
    fl_sample(con, "Q.JL00", wo, d_round, results = list(qc_nd("Zinc", 0.005, method = filt)))
  })
  qm <- fl_of(fl_run(db, qc_checks()), "qc_missing")
  expect_equal(nrow(qm), 1)
  expect_match(qm$detail, "rinsate blank Q.JR42 filtered or wrong suite: not a decontamination test",
               fixed = TRUE)
  expect_false(grepl("no filter blank", qm$detail, fixed = TRUE))
})

test_that("qc_missing: months the requirements do not list, and months before `from`, are not assessed", {
  db <- qc_db()
  fl_with(db, function(con) {
    qc_add(con, "Q.JD42", "duplicate", parent = "Q.X01", date_start = "2026-01-01")
    # August: not a required month (3;6;9;12)
    fl_sample(con, "Q.X01", "ES2600510", "2026-08-12", results = list(qc_lab("Zinc", 0.02, rl = 0.005)))
    # September: required, but `from` is moved past it below
    fl_sample(con, "Q.X01", wo, d_round, results = list(qc_lab("Zinc", 0.02, rl = 0.005)))
  })
  f <- fl_run(db, qc_checks(requirements = qc_requirements_df(from = "2026-01-01")))
  expect_identical(fl_of(f, "qc_missing")$key, "qc_missing|Q|2026-09")
  f2 <- fl_run(db, qc_checks(requirements = qc_requirements_df(from = "2026-10-01")))
  expect_length(attr(f2, "errors"), 0)
  expect_equal(nrow(fl_of(f2, "qc_missing")), 0)
})

test_that("qc_missing: a round counts only once a RECENT delivery has a water sample at the site that month", {
  db <- qc_db()
  fl_with(db, function(con) {
    fl_sample(con, "Q.X01", wo, "2026-06-15", results = list(qc_lab("Zinc", 0.02, rl = 0.005)),
              ingested = fl_now() - 100 * 86400)
  })
  f <- fl_run(db, qc_checks(requirements = qc_requirements_df(from = "2026-01-01")))
  expect_length(attr(f, "errors"), 0)
  expect_equal(nrow(fl_of(f, "qc_missing")), 0)
})

test_that("qc_missing (R19-10 (7)): waits until every expected delivery of the round has arrived", {
  # [invented: "every expected work order of the round" is read as every water
  #  stream (acirl_water, als_lab) that checks$schedule expects at that site in
  #  that month. With no schedule there is nothing to wait for (other tests).]
  sched <- fl_schedule(list(site = "Q", stream = "acirl_water", months = "9", due_days = 60),
                       list(site = "Q", stream = "als_lab", months = "9", due_days = 60))
  db <- qc_db()
  fl_with(db, sep_round)            # ALS lab results only
  f1 <- fl_run(db, qc_checks(schedule = sched))
  expect_length(attr(f1, "errors"), 0)
  expect_equal(nrow(fl_of(f1, "qc_missing")), 0)

  fl_with(db, function(con) {       # the ACIRL field work order lands
    fl_sample(con, "Q.X01", "2400-9001-09", d_round, org = "ACIRL",
              results = list(list(analyte = "pH", value = 7, lab_org = "ACIRL")))
  })
  f2 <- fl_run(db, qc_checks(schedule = sched))
  expect_identical(fl_of(f2, "qc_missing")$key, "qc_missing|Q|2026-09")
})

# ---- qc_unresolved -------------------------------------------------------------------

test_that("qc_unresolved: a QC code with no qc_feature row live at the sample date; action ask_acirl", {
  db <- qc_db()
  fl_with(db, function(con) {
    qc_add(con, "Q.JD43", "duplicate", parent = "Q.X01", date_start = "2026-01-01",
           date_end = "2026-06-30")
    fl_sample(con, "Q.X01", wo, d_round, results = list(qc_lab("Zinc", 0.02, rl = 0.005)))
    fl_sample(con, "Q.JD43", wo, d_round, results = list(qc_lab("Zinc", 0.02, rl = 0.005)))
  })
  f <- fl_run(db, qc_checks())
  expect_length(attr(f, "errors"), 0)
  un <- fl_of(f, "qc_unresolved")
  expect_equal(nrow(un), 1)
  expect_identical(un$key, sprintf("qc_unresolved|Q.JD43|%s", d_round))
  expect_identical(un$site, "Q")
  expect_identical(un$date, d_round)
  expect_identical(un$action, "ask_acirl")
  expect_match(un$detail, "→ ask", ignore.case = TRUE)
})

test_that("qc_unresolved: a duplicate, field blank or rinsate blank whose parent has no sample in the round; the detail says which", {
  db <- qc_db()
  fl_with(db, function(con) {
    qc_add(con, "Q.JD42", "duplicate", parent = "Q.X01")
    qc_add(con, "Q.JF42", "field_blank", parent = "Q.X02")
    qc_add(con, "Q.JR42", "rinsate_blank", parent = "Q.X03")
    fl_sample(con, "Q.X09", wo, d_round, results = list(qc_lab("Zinc", 0.02, rl = 0.005)))
    for (code in c("Q.JD42", "Q.JF42", "Q.JR42")) {
      fl_sample(con, code, wo, d_round, results = list(qc_nd("Zinc", 0.005)))
    }
  })
  un <- fl_of(fl_run(db, qc_checks()), "qc_unresolved")
  expect_setequal(un$key, sprintf("qc_unresolved|%s|%s", c("Q.JD42", "Q.JF42", "Q.JR42"), d_round))
  expect_true(all(un$action == "ask_acirl"))
  d_jd <- un$detail[un$key == sprintf("qc_unresolved|Q.JD42|%s", d_round)]
  expect_match(d_jd, "Q.X01", fixed = TRUE)
  expect_match(d_jd, "parent", fixed = TRUE)
})

test_that("qc_unresolved: codes tied to no point (transport, source, type-only field blank) need no parent", {
  # [invented: a field blank with uuid_parent NULL (R19-6's type-only B.JF00
  #  analogue) is not unresolved - only a code WITH a parent needs its sample.]
  db <- qc_db()
  fl_with(db, function(con) {
    qc_add(con, "Q.JT00", "transport_blank")
    qc_add(con, "Q.JA00", "source_blank")
    qc_add(con, "Q.JF00", "field_blank")
    for (code in c("Q.JT00", "Q.JA00", "Q.JF00")) {
      fl_sample(con, code, wo, d_round, results = list(qc_nd("Zinc", 0.005)))
    }
  })
  f <- fl_run(db, qc_checks())
  expect_length(attr(f, "errors"), 0)
  expect_equal(nrow(fl_of(f, "qc_unresolved")), 0)
})

test_that("qc_unresolved: an OPEN qc_label_conflict review item on the QC sample's work order flags it", {
  db <- qc_db()
  fl_with(db, function(con) {
    qc_add(con, "Q.JD42", "duplicate", parent = "Q.X01")
    fl_sample(con, "Q.X01", wo, d_round, results = list(qc_lab("Zinc", 0.02, rl = 0.005)))
    fl_sample(con, "Q.JD42", wo, d_round, results = list(qc_lab("Zinc", 0.02, rl = 0.005)))
  })
  f0 <- fl_run(db, qc_checks())
  expect_equal(nrow(fl_of(f0, "qc_unresolved")), 0)          # control: paired fine

  insert_review_items(db, data.frame(
    uuid = c("rq-qc-1", "rq-qc-2"), created_at = rep(fl_now() - 3600, 2),
    kind = "qc_label_conflict", subkind = NA_character_,
    work_order = c("ES2600599", wo), status = c("open", "resolved"), stringsAsFactors = FALSE))
  f1 <- fl_run(db, qc_checks())
  expect_equal(nrow(fl_of(f1, "qc_unresolved")), 0)          # other WO open, ours resolved

  insert_review_items(db, data.frame(
    uuid = "rq-qc-3", created_at = fl_now() - 3600, kind = "qc_label_conflict",
    subkind = NA_character_, work_order = wo, status = "open", stringsAsFactors = FALSE))
  un <- fl_of(fl_run(db, qc_checks()), "qc_unresolved")
  expect_identical(un$key, sprintf("qc_unresolved|Q.JD42|%s", d_round))
  expect_identical(un$action, "ask_acirl")
})

# ---- lab_qc_missing ---------------------------------------------------------------------

lqm_detail_none <- paste0("no ALS QC Interpretive report (QCI) received: ask ACIRL/ALS for the ",
                          "QC report and QA/QC compliance assessment")

test_that("lab_qc_missing: a recent work order with ALS lab results and no QCI -> one flag (channel A), action chase", {
  db <- qc_db()
  fl_with(db, function(con) {
    fl_sample(con, "Q.X01", wo, d_round, results = list(qc_lab("Zinc", 0.02, rl = 0.005)))
    fl_sample(con, "Q.X02", wo, d_round, results = list(qc_lab("Zinc", 0.03, rl = 0.005)))
  })
  f <- fl_run(db, fl_checks())                # needs only the DB
  expect_length(attr(f, "errors"), 0)
  lm <- fl_of(f, "lab_qc_missing")
  expect_equal(nrow(lm), 1)
  expect_identical(lm$key, sprintf("lab_qc_missing|%s", wo))
  expect_identical(lm$site, "Q")
  expect_identical(lm$action, "chase")
  expect_match(lm$detail, lqm_detail_none, fixed = TRUE)
})

test_that("lab_qc_missing: a parsed QCI clears it; an unreadable one says so; a QC.pdf alone is not a QCI", {
  db <- qc_db()
  fl_with(db, function(con) {
    for (w in c("ES2600511", "ES2600512", "ES2600513")) {
      fl_sample(con, "Q.X01", w, d_round, results = list(qc_lab("Zinc", 0.02, rl = 0.005)))
    }
    qc_report(con, "ES2600511", kind = "QCI", status = "parsed")
    qc_report(con, "ES2600512", kind = "QCI", status = "unreadable",
              message = "archived copy is 0 bytes")
    qc_report(con, "ES2600513", kind = "QC", status = "parsed")
  })
  lm <- fl_of(fl_run(db, fl_checks()), "lab_qc_missing")
  expect_setequal(lm$key, c("lab_qc_missing|ES2600512", "lab_qc_missing|ES2600513"))
  expect_match(lm$detail[lm$key == "lab_qc_missing|ES2600512"],
               "QCI received but unreadable: archived copy is 0 bytes", fixed = TRUE)
  expect_match(lm$detail[lm$key == "lab_qc_missing|ES2600513"], lqm_detail_none, fixed = TRUE)
})

test_that("lab_qc_missing: field-only (ACIRL) work orders and old deliveries are not flagged", {
  db <- qc_db()
  fl_with(db, function(con) {
    fl_sample(con, "Q.X01", "2400-9001-09", d_round, org = "ACIRL",
              results = list(list(analyte = "pH", value = 7, lab_org = "ACIRL")))
    fl_sample(con, "Q.X01", "ES2600520", "2026-06-15", results = list(qc_lab("Zinc", 0.02, rl = 0.005)),
              ingested = fl_now() - 100 * 86400)
  })
  f <- fl_run(db, fl_checks())
  expect_length(attr(f, "errors"), 0)
  expect_equal(nrow(fl_of(f, "lab_qc_missing")), 0)
})
