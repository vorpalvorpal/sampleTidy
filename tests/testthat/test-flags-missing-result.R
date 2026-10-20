# Flag check `missing_result` (dev/plans/SPEC-flag-missing-result.md): a unit-bearing
# analyte (a number is expected) with analysis.value NULL, on a recent-delivery sample.

mr_txt <- function(con) {
  # text analytes: NULL units (create first; fl_analyte is find-or-create by name)
  fl_analyte(con, "Appearance", units = NA_character_)
  fl_analyte(con, "Stage", units = NA_character_)
  fl_analyte(con, "Standing water level", units = "m")
}

mr_run <- function(db) fl_of(fl_run(db, fl_checks()), "missing_result")

mr_one <- function(results, org = "ACIRL", feature = "B.L02", project = "ES2528155",
                   at = "2026-09-09", setup = NULL, ...) {
  db <- fl_db(env = parent.frame())
  fl_with(db, function(con) {
    mr_txt(con)
    if (!is.null(setup)) setup(con)
    fl_sample(con, feature, project, at, org = org, results = results, ...)
  })
  mr_run(db)
}

swl <- function(vc, ...) list(analyte = "Standing water level", value = NULL, value_chr = vc, ...)

test_that("missing_result: recent ACIRL field sample, numeric analyte with '_' -> one fully-formed row", {
  mr <- mr_one(list(swl("_")))
  expect_equal(nrow(mr), 1)
  expect_identical(mr$action, "ask_acirl")
  expect_identical(mr$analyte, "Standing water level")
  expect_identical(mr$feature, "B.L02")
  expect_identical(mr$site, "B")
  expect_identical(as.character(mr$date), "2026-09-09")
  expect_identical(mr$threshold, "1 blank result")
  expect_match(mr$detail, 'Standing water level "_"', fixed = TRUE)
  expect_match(mr$detail, "ES2528155", fixed = TRUE)
  expect_match(mr$detail, "ask ACIRL", fixed = TRUE)
  expect_identical(mr$key, "missing_result|ES2528155|B.L02|2026-09-09|ACIRL")
  expect_true(is.na(mr$value))
  expect_true(is.na(mr$unit))
})

test_that("missing_result: any value_chr counts for a unit-bearing analyte; blank shows (blank)", {
  for (vc in list("-", "n/a", "see comments")) {
    mr <- mr_one(list(swl(vc)))
    expect_equal(nrow(mr), 1)
    expect_match(mr$detail, sprintf('Standing water level "%s"', vc), fixed = TRUE)
  }
  for (vc in list("", NULL)) {
    mr <- mr_one(list(swl(vc)))
    expect_equal(nrow(mr), 1)
    expect_match(mr$detail, "Standing water level (blank)", fixed = TRUE)
  }
})

test_that("missing_result: text analytes with no units are never flagged", {
  for (vc in list("_", NULL)) {
    mr <- mr_one(list(list(analyte = "Appearance", value = NULL, value_chr = vc),
                      list(analyte = "Stage", value = NULL, value_chr = vc)))
    expect_equal(nrow(mr), 0)
  }
  mr <- mr_one(list(list(analyte = "Appearance", value = NULL, value_chr = "Clear"),
                    list(analyte = "Stage", value = NULL, value_chr = "Low flow")))
  expect_equal(nrow(mr), 0)
})

test_that("missing_result: results with a value are not flagged (incl. below detection)", {
  mr <- mr_one(list(list(analyte = "Standing water level", value = 1.2),
                    list(analyte = "Zn", value = 0.005, quantified = FALSE, rl = 0.005)))
  expect_equal(nrow(mr), 0)
})

test_that("missing_result: several missing analytes on one sample -> one row", {
  mr <- mr_one(list(swl("_"),
                    list(analyte = "Zn", value = NULL, value_chr = "-"),
                    list(analyte = "Ammonia", value = NULL, value_chr = "")))
  expect_equal(nrow(mr), 1)
  expect_identical(mr$analyte, "Ammonia, Standing water level, Zn")
  expect_identical(mr$threshold, "3 blank results")
  expect_equal(lengths(regmatches(mr$detail, gregexpr(";", mr$detail))), 3)  # 2 joins + project
  expect_match(mr$detail, 'Zn "-"', fixed = TRUE)
  expect_match(mr$detail, "Ammonia (blank)", fixed = TRUE)
})

test_that("missing_result: a non-ACIRL organisation -> ask_lab", {
  mr <- mr_one(list(list(analyte = "Zn", value = NULL, value_chr = "-")), org = "ALS",
               project = "ES2600500", feature = "B.MW05")
  expect_equal(nrow(mr), 1)
  expect_identical(mr$action, "ask_lab")
  expect_match(mr$detail, "ask the lab", fixed = TRUE)
  expect_false(grepl("ask ACIRL", mr$detail, fixed = TRUE))
  expect_identical(mr$key, "missing_result|ES2600500|B.MW05|2026-09-09|ALS")
})

test_that("missing_result: organisation 'acirl' in any case -> ask_acirl", {
  mr <- mr_one(list(swl("_")), org = "acirl")
  expect_identical(mr$action, "ask_acirl")
})

test_that("missing_result: window - legacy samples and old samples are not flagged", {
  expect_equal(nrow(mr_one(list(swl("_")), ingested = NULL)), 0)
  expect_equal(nrow(mr_one(list(swl("_")), actor = "012-detection-limits")), 0)
  expect_equal(nrow(mr_one(list(swl("_")), source_hash = NA_character_)), 0)
  # recent work order, but the sample is > 180 days before today (2026-10-19)
  expect_equal(nrow(mr_one(list(swl("_")), at = "2026-03-01")), 0)
  # control: same setup, recent date, is flagged
  expect_equal(nrow(mr_one(list(swl("_")), at = "2026-09-01")), 1)
})

test_that("missing_result: units '1' and 'pH' count as numeric", {
  mr <- mr_one(list(list(analyte = "SAR", value = NULL, value_chr = "-", units = "1"),
                    list(analyte = "pH", value = NULL, value_chr = "_", units = "pH")))
  expect_equal(nrow(mr), 1)
  expect_identical(mr$analyte, "pH, SAR")
  expect_identical(mr$threshold, "2 blank results")
})

test_that("missing_result: empty lab_method.units falls back to analyte.units; both NULL -> text", {
  mr <- mr_one(list(list(analyte = "Zn", value = NULL, value_chr = "-", units = "")))
  expect_equal(nrow(mr), 1)                      # analyte Zn has mg/L
  mr <- mr_one(list(list(analyte = "Colour", value = NULL, value_chr = "-", units = NA_character_)),
               setup = function(con) fl_analyte(con, "Colour", units = NA_character_))
  expect_equal(nrow(mr), 0)
  # whitespace-only units on the method and none on the analyte: no unit
  mr <- mr_one(list(list(analyte = "Odour", value = NULL, value_chr = "-", units = "  ")),
               setup = function(con) fl_analyte(con, "Odour", units = NA_character_))
  expect_equal(nrow(mr), 0)
})

test_that("missing_result: QC samples are not excluded", {
  expect_false("missing_result" %in% sampleTidy:::.flags_qc_blind)
})

test_that("missing_result: keys are stable across runs", {
  db <- fl_db()
  fl_with(db, function(con) {
    mr_txt(con)
    fl_sample(con, "B.L02", "ES2528155", "2026-09-09", org = "ACIRL", results = list(swl("_")))
  })
  a <- mr_run(db)
  b <- mr_run(db)
  expect_equal(nrow(a), 1)
  expect_identical(a$key, b$key)
})

test_that("missing_result: registered after unit_change with the exact meaning text", {
  ck <- sampleTidy:::.flags_checks
  expect_true("missing_result" %in% ck)
  expect_identical(match("missing_result", ck), match("unit_change", ck) + 1L)
  expect_identical(
    unname(sampleTidy:::.flags_meanings[["missing_result"]]),
    "a result is blank on the report (\"_\" or similar) — ask the supplier for the value or why it wasn't measured")
})

test_that("missing_result: status note Flags section and .import-status.json, first_seen kept", {
  s <- fl_status_setup()
  fl_with(s$db, function(con) {
    mr_txt(con)
    fl_sample(con, "B.L02", "ES2528155", "2026-09-09", org = "ACIRL", results = list(swl("_")))
  })
  t1 <- fl_now()
  fl_status(s, checks = fl_checks(), now = t1)
  sec <- md_section(read_status_note(s$report_dir), "Flags")
  expect_true(any(grepl("**missing_result** — a result is blank on the report",
                        sec, fixed = TRUE)))
  js1 <- fl_status_json(s)
  f1 <- Filter(function(x) identical(x$check, "missing_result"), js1$flags)
  expect_length(f1, 1)
  expect_identical(f1[[1]]$first_seen, "2026-10-19T02:00:00Z")
  expect_identical(f1[[1]]$key, "missing_result|ES2528155|B.L02|2026-09-09|ACIRL")

  fl_status(s, checks = fl_checks(), now = t1 + 2 * 3600)
  f2 <- Filter(function(x) identical(x$check, "missing_result"), fl_status_json(s)$flags)
  expect_length(f2, 1)
  expect_identical(f2[[1]]$first_seen, "2026-10-19T02:00:00Z")
})
