# PLAN-19 R-19.24 `qc_dup_rpd` (with rulings R19-10 (3), R19-11 and R19-12):
# Council's blind field duplicate against its parent point's sample, lab
# results only, matched on uuid_analyte + method code; a non-detect is taken
# at its RL; RPD when both values are >= k x L, else |A-B| <= m x L; the
# mislabel guard when more than half of the compared analytes fail.
# Criteria (k = 5, 30% inorganic / 50% organic, m = 2) come from
# qc_criteria_df() (helper-qc.R), i.e. the plan's first criteria rows.
#
# Codes and parents are invented (site Q; helper-qc.R).

wo <- "ES2600501"
d_round <- "2026-09-28"
amm <- "EK055G: Ammonia as N by Discrete Analyser"

dup_key <- function(code = "Q.JD42", date = d_round) sprintf("qc_dup_rpd|%s|%s", code, date)

set_organic <- function(con, analyte) {
  fl_analyte(con, analyte)
  DBI::dbExecute(con, "UPDATE analyte SET type = 'organic' WHERE name = ?", params = list(analyte))
}

test_that("qc_dup_rpd: one flag per duplicate naming parent, code, failing analytes and round; passing and field results left out", {
  db <- qc_db()
  fl_with(db, function(con) {
    set_organic(con, "Phenol")
    qc_add(con, "Q.JD42", "duplicate", parent = "Q.X01")
    fl_sample(con, "Q.X01", wo, d_round, results = list(
      qc_lab("Zinc", 0.10, rl = 0.005),                # RPD 66.7% > 30%      -> fail
      qc_lab("Copper", 0.10, rl = 0.001),              # RPD 9.5%              -> pass
      qc_lab("Ammonia as N", 0.03, rl = 0.01, method = amm),  # < 5xLOR: |diff| 0.05 > 0.02 -> fail
      qc_lab("Nitrate as N", 0.02, rl = 0.01, method = amm),  # < 5xLOR: |diff| 0.015      -> pass
      qc_lab("Phenol", 10, rl = 1, method = "EP075: Phenols"), # organic RPD 40% <= 50%   -> pass
      qc_nd("Lead", 0.001),                            # both non-detect       -> pass
      list(analyte = "pH", value = 7.0, lab_org = "ACIRL")))   # field: never compared
    fl_sample(con, "Q.JD42", wo, d_round, results = list(
      qc_lab("Zinc", 0.05, rl = 0.005),
      qc_lab("Copper", 0.11, rl = 0.001),
      qc_lab("Ammonia as N", 0.08, rl = 0.01, method = amm),
      qc_lab("Nitrate as N", 0.035, rl = 0.01, method = amm),
      qc_lab("Phenol", 15, rl = 1, method = "EP075: Phenols"),
      qc_nd("Lead", 0.001),
      list(analyte = "pH", value = 9.5, lab_org = "ACIRL")))
  })
  f <- fl_run(db, qc_checks())
  expect_length(attr(f, "errors"), 0)
  dr <- fl_of(f, "qc_dup_rpd")
  expect_equal(nrow(dr), 1)
  expect_identical(dr$key, dup_key())
  expect_identical(dr$site, "Q")
  expect_identical(dr$feature, "Q.X01")          # the parent point (plan example)
  expect_identical(dr$date, d_round)
  expect_identical(dr$action, "qualify")
  expect_match(dr$detail, "Q.JD42", fixed = TRUE)
  expect_match(dr$detail, "Zinc RPD", fixed = TRUE)
  expect_match(dr$detail, "30%", fixed = TRUE)
  expect_match(dr$detail, "Ammonia as N |diff| 0.05", fixed = TRUE)
  for (ok in c("Copper", "Nitrate", "Phenol", "Lead", "pH")) {
    expect_false(grepl(ok, dr$detail, fixed = TRUE), label = paste(ok, "not listed"))
  }
  # round: "<Mon YYYY> quarterly|annual" [invented: which of the two words is
  # not pinned - the plan gives no rule for telling them apart]
  expect_match(dr$detail, "Sep 2026 (quarterly|annual)")
  expect_match(dr$detail, "→ qualify")
  expect_match(dr$detail, "Q.X01.*→|→.*Q.X01")
})

test_that("qc_dup_rpd: 30% for inorganic, 50% for organic (analyte.type); a non-detect counts at its RL", {
  db <- qc_db()
  fl_with(db, function(con) {
    set_organic(con, "Phenol")
    qc_add(con, "Q.JD42", "duplicate", parent = "Q.X01")
    fl_sample(con, "Q.X01", wo, d_round, results = list(
      qc_lab("Phenol", 10, rl = 1, method = "EP075: Phenols"),  # 40%, organic   -> pass
      qc_lab("Sulfate", 10, rl = 1, method = "ED041G: Sulfate"), # 40%, inorganic -> fail
      qc_lab("Iron", 0.05, rl = 0.01),                 # dup ND at 0.01: |diff| 0.04 > 0.02 -> fail
      qc_lab("Copper", 0.10, rl = 0.001),
      qc_lab("Nickel", 0.010, rl = 0.001),
      qc_nd("Lead", 0.001)))
    fl_sample(con, "Q.JD42", wo, d_round, results = list(
      qc_lab("Phenol", 15, rl = 1, method = "EP075: Phenols"),
      qc_lab("Sulfate", 15, rl = 1, method = "ED041G: Sulfate"),
      qc_nd("Iron", 0.01),
      qc_lab("Copper", 0.10, rl = 0.001),
      qc_lab("Nickel", 0.011, rl = 0.001),
      qc_nd("Lead", 0.001)))
  })
  dr <- fl_of(fl_run(db, qc_checks()), "qc_dup_rpd")
  expect_equal(nrow(dr), 1)
  expect_identical(dr$action, "qualify")
  expect_match(dr$detail, "Sulfate", fixed = TRUE)
  expect_match(dr$detail, "Iron", fixed = TRUE)
  expect_false(grepl("Phenol", dr$detail, fixed = TRUE))
})

test_that("qc_dup_rpd: every compared analyte passing (incl. both non-detect) gives no flag", {
  db <- qc_db()
  fl_with(db, function(con) {
    qc_add(con, "Q.JD42", "duplicate", parent = "Q.X01")
    fl_sample(con, "Q.X01", wo, d_round, results = list(
      qc_lab("Copper", 0.10, rl = 0.001), qc_nd("Lead", 0.001),
      qc_lab("Ammonia as N", 0.02, rl = 0.01, method = amm)))
    fl_sample(con, "Q.JD42", wo, d_round, results = list(
      qc_lab("Copper", 0.11, rl = 0.001), qc_nd("Lead", 0.001),
      qc_lab("Ammonia as N", 0.03, rl = 0.01, method = amm)))
  })
  f <- fl_run(db, qc_checks())
  expect_length(attr(f, "errors"), 0)
  expect_equal(nrow(fl_of(f, "qc_dup_rpd")), 0)
})

test_that("qc_dup_rpd: a different method code, or a field result, is never compared", {
  db <- qc_db()
  fl_with(db, function(con) {
    qc_add(con, "Q.JD42", "duplicate", parent = "Q.X01")
    fl_sample(con, "Q.X01", wo, d_round, results = list(
      qc_lab("Zinc", 0.10, rl = 0.005, method = "EG020T: Total Metals by ICP-MS"),
      list(analyte = "EC", value = 100, lab_org = "ACIRL")))
    fl_sample(con, "Q.JD42", wo, d_round, results = list(
      qc_lab("Zinc", 0.05, rl = 0.005, method = "EG020F: Dissolved Metals by ICP-MS"),
      list(analyte = "EC", value = 900, lab_org = "ACIRL")))
  })
  f <- fl_run(db, qc_checks())
  expect_length(attr(f, "errors"), 0)
  expect_equal(nrow(fl_of(f, "qc_dup_rpd")), 0)
})

test_that("qc_dup_rpd mislabel guard: more than half failing -> 'does not resemble its parent', ask_acirl; exactly half -> qualify", {
  build <- function(n_fail, n_pass) {
    db <- qc_db()
    fl_with(db, function(con) {
      qc_add(con, "Q.JD42", "duplicate", parent = "Q.X01")
      par <- c(lapply(seq_len(n_fail), function(i) qc_lab(sprintf("Fail%02d", i), 0.10, rl = 0.001)),
               lapply(seq_len(n_pass), function(i) qc_lab(sprintf("Pass%02d", i), 0.10, rl = 0.001)))
      dup <- c(lapply(seq_len(n_fail), function(i) qc_lab(sprintf("Fail%02d", i), 0.30, rl = 0.001)),
               lapply(seq_len(n_pass), function(i) qc_lab(sprintf("Pass%02d", i), 0.10, rl = 0.001)))
      fl_sample(con, "Q.X01", wo, d_round, results = par)
      fl_sample(con, "Q.JD42", wo, d_round, results = dup)
    })
    fl_of(fl_run(db, qc_checks()), "qc_dup_rpd")
  }
  m <- build(3, 1)
  expect_equal(nrow(m), 1)
  expect_identical(m$action, "ask_acirl")
  expect_match(m$detail, "duplicate does not resemble its parent", fixed = TRUE)
  expect_match(m$detail, "check the label with ACIRL", fixed = TRUE)
  expect_identical(m$key, dup_key())

  h <- build(2, 2)
  expect_equal(nrow(h), 1)
  expect_identical(h$action, "qualify")
  expect_false(grepl("does not resemble", h$detail, fixed = TRUE))
})

test_that("qc_dup_rpd: at most 15 failing analytes are listed, then '+m more'", {
  db <- qc_db()
  fl_with(db, function(con) {
    qc_add(con, "Q.JD42", "duplicate", parent = "Q.X01")
    nm_f <- sprintf("Fail%02d", 1:17)
    nm_p <- sprintf("Pass%02d", 1:17)    # 17 of 34 fail: exactly half, so not a mislabel
    fl_sample(con, "Q.X01", wo, d_round, results = c(
      lapply(nm_f, qc_lab, value = 0.10, rl = 0.001), lapply(nm_p, qc_lab, value = 0.10, rl = 0.001)))
    fl_sample(con, "Q.JD42", wo, d_round, results = c(
      lapply(nm_f, qc_lab, value = 0.30, rl = 0.001), lapply(nm_p, qc_lab, value = 0.10, rl = 0.001)))
  })
  dr <- fl_of(fl_run(db, qc_checks()), "qc_dup_rpd")
  expect_equal(nrow(dr), 1)
  expect_identical(dr$action, "qualify")
  expect_length(regmatches(dr$detail, gregexpr("Fail[0-9]{2}", dr$detail))[[1]], 15)
  expect_match(dr$detail, "+2 more", fixed = TRUE)
})

test_that("qc_dup_rpd pairing (R19-12): same work order first, else the parent's sample on the same Sydney date in any work order", {
  db <- qc_db()
  fl_with(db, function(con) {
    qc_add(con, "Q.JD42", "duplicate", parent = "Q.X01")
    qc_add(con, "Q.JD43", "duplicate", parent = "Q.X02")
    # Q.JD42: the same-WO parent agrees; another WO's same-day sample would not.
    fl_sample(con, "Q.X01", wo, d_round, results = list(qc_lab("Zinc", 0.10, rl = 0.005)))
    fl_sample(con, "Q.X01", "ES2600502", "2026-09-28 03:00:00",
              results = list(qc_lab("Zinc", 0.50, rl = 0.005)))
    fl_sample(con, "Q.JD42", wo, d_round, results = list(qc_lab("Zinc", 0.10, rl = 0.005)))
    # Q.JD43: parent only in another work order, same Sydney date
    # (2026-09-27 14:30 UTC = 2026-09-28 00:30 Sydney, AEST) -> paired, and fails.
    fl_sample(con, "Q.X02", "ES2600502", "2026-09-27 14:30:00",
              results = list(qc_lab("Zinc", 0.50, rl = 0.005)))
    fl_sample(con, "Q.JD43", wo, d_round, results = list(qc_lab("Zinc", 0.10, rl = 0.005)))
  })
  dr <- fl_of(fl_run(db, qc_checks()), "qc_dup_rpd")
  expect_identical(dr$key, dup_key("Q.JD43"))
  expect_identical(dr$feature, "Q.X02")
})

test_that("qc_dup_rpd pairing (R19-12): no +-3-day fallback - a parent sampled the next day leaves the pair unresolved", {
  db <- qc_db()
  fl_with(db, function(con) {
    qc_add(con, "Q.JD42", "duplicate", parent = "Q.X01")
    fl_sample(con, "Q.X01", "ES2600502", "2026-09-29", results = list(qc_lab("Zinc", 0.50, rl = 0.005)))
    fl_sample(con, "Q.JD42", wo, d_round, results = list(qc_lab("Zinc", 0.10, rl = 0.005)))
  })
  f <- fl_run(db, qc_checks())
  expect_equal(nrow(fl_of(f, "qc_dup_rpd")), 0)
  un <- fl_of(f, "qc_unresolved")
  expect_identical(un$key, sprintf("qc_unresolved|Q.JD42|%s", d_round))
})

test_that("qc_dup_rpd: only recent deliveries (R1), and only events on or after the requirements' `from` date", {
  db <- qc_db()
  fl_with(db, function(con) {
    qc_add(con, "Q.JD42", "duplicate", parent = "Q.X01", date_start = "2026-01-01")
    fail <- function(feature, project, at, v, ingested = fl_now() - 10 * 86400) {
      fl_sample(con, feature, project, at, ingested = ingested,
                results = list(qc_lab("Zinc", v, rl = 0.005)))
    }
    # before `from` (2026-09-01), recent delivery
    fail("Q.X01", "ES2600503", "2026-08-20", 0.10); fail("Q.JD42", "ES2600503", "2026-08-20", 0.05)
    # after `from`, but delivered 100 days ago (not recent)
    fail("Q.X01", "ES2600504", "2026-09-02", 0.10, fl_now() - 100 * 86400)
    fail("Q.JD42", "ES2600504", "2026-09-02", 0.05, fl_now() - 100 * 86400)
  })
  f <- fl_run(db, qc_checks())
  expect_length(attr(f, "errors"), 0)
  expect_equal(nrow(fl_of(f, "qc_dup_rpd")), 0)
  # control: with `from` moved back, the August pair is assessed
  f2 <- fl_run(db, qc_checks(requirements = qc_requirements_df(from = "2026-01-01")))
  expect_identical(fl_of(f2, "qc_dup_rpd")$key, dup_key(date = "2026-08-20"))
})
