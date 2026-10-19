# PLAN-19 section 7 (R-19.33, R-19.34) and phase-1 wiring: dev/qc_criteria.csv,
# dev/qc_requirements.csv and their use in dev/auto-import.R. These read the
# source tree's dev/ (not part of the installed package), so they skip there.

dev_file <- function(...) test_path("..", "..", "dev", ...)

read_chr <- function(p) utils::read.csv(p, colClasses = "character", na.strings = character(0),
                                        check.names = FALSE, encoding = "UTF-8")

skip_if_no_dev <- function() skip_if_not(dir.exists(dev_file()), "no dev/ (installed package)")

.qc_types <- c("duplicate", "field_blank", "rinsate_blank", "transport_blank", "filter_blank",
               "source_blank")

test_that("R-19.33 dev/qc_criteria.csv: columns, vocabularies, and the plan's first rows", {
  skip_if_no_dev()
  p <- dev_file("qc_criteria.csv")
  expect_true(file.exists(p))
  d <- read_chr(p)
  expect_identical(names(d), c("rule", "qc_type", "analyte_class", "param", "value", "unit",
                               "action", "source", "status"))
  expect_true(all(d$rule %in% c("dup_rpd", "dup_absdiff", "dup_lor_multiple", "blank_detect",
                                "blank_factor", "carryover", "filtered_method_regex",
                                "completeness")))
  types <- unlist(strsplit(d$qc_type, ";", fixed = TRUE))
  expect_true(all(trimws(types) %in% c(.qc_types, "any")))
  expect_true(all(d$analyte_class %in% c("inorganic", "organic", "lab_contaminant", "any")))
  expect_true(all(d$status %in% c("proposed", "adopted")))
  key <- function(x) paste(x$rule, x$qc_type, x$analyte_class, x$param, sep = "|")
  want <- qc_criteria_df()
  want <- want[want$rule != "filtered_method_regex", , drop = FALSE]   # value re-measured, below
  got_v <- stats::setNames(d$value, key(d))
  expect_true(all(key(want) %in% key(d)))
  expect_identical(unname(got_v[key(want)]), want$value)
  expect_equal(sum(d$rule == "filtered_method_regex"), 1)
})

test_that("R-19.33 filtered_method_regex: matches the measured field-filtered ALS methods only", {
  skip_if_no_dev()
  d <- read_chr(dev_file("qc_criteria.csv"))
  re <- d$value[d$rule == "filtered_method_regex"]
  expect_length(re, 1)
  yes <- c("EG020F: Dissolved Metals by ICP-MS", "EG035F: Dissolved Mercury by FIMS",
           "EG050F: Dissolved Hexavalent Chromium", "ED093F: Dissolved Major Cations",
           "EG053FG: Dissolved Selenium", "EP002: Dissolved Organic Carbon (DOC)")
  no <- c("EG020T: Total Metals by ICP-MS", "EG035T: Total Recoverable Mercury by FIMS",
          "EA005P: pH by PC Titrator", "EK055G: Ammonia as N by Discrete Analyser",
          "EP005: Total Organic Carbon (TOC)", "EN67 - Client Supplied Data")
  expect_true(all(grepl(re, yes, perl = TRUE)))
  expect_false(any(grepl(re, no, perl = TRUE)))
})

test_that("R-19.34 dev/qc_requirements.csv: Blaxland types and counts only, from 2026-09-01; no Katoomba; no codes", {
  skip_if_no_dev()
  p <- dev_file("qc_requirements.csv")
  expect_true(file.exists(p))
  d <- read_chr(p)
  expect_identical(names(d), c("site", "months", "qc_type", "n_min", "from", "to", "source"))
  expect_false(any(d$site == "K"))
  key <- paste(d$site, gsub(" ", "", d$months), d$qc_type, d$n_min, d$from)
  want <- c(paste("B", "3;6;9;12", c("duplicate", "field_blank", "rinsate_blank", "filter_blank"),
                  "1", "2026-09-01"),
            paste("B", "3", "transport_blank", "1", "2026-09-01"))
  expect_setequal(key, want)
  expect_true(all(d$qc_type %in% .qc_types))
  # types and counts only, never a code
  cells <- unlist(d, use.names = FALSE)
  expect_false(any(grepl("\\.J[A-Z]", cells)))
})

test_that("phase 1: dev/auto-import.R passes checks$qc with the two dev/ tables", {
  skip_if_no_dev()
  src <- paste(readLines(dev_file("auto-import.R"), warn = FALSE), collapse = "\n")
  expect_match(src, "qc\\s*=\\s*list\\(")
  expect_match(src, "qc_criteria.csv", fixed = TRUE)
  expect_match(src, "qc_requirements.csv", fixed = TRUE)
})

test_that("phase 1: the dev/ tables drive import_flags() without error - a Blaxland Sep 2026 round with no QC is qc_missing", {
  skip_if_no_dev()
  db <- qc_db()
  fl_with(db, function(con) {
    fl_sample(con, "B.E01", "ES2600530", "2026-09-28", results = list(qc_lab("Zinc", 0.02, rl = 0.005)))
  })
  f <- fl_run(db, qc_checks(qc = list(criteria = dev_file("qc_criteria.csv"),
                                      requirements = dev_file("qc_requirements.csv"))))
  expect_length(attr(f, "errors"), 0)
  qm <- fl_of(f, "qc_missing")
  expect_identical(qm$key, "qc_missing|B|2026-09")
  for (t in c("duplicate", "field blank", "rinsate blank", "filter blank")) {
    expect_match(qm$detail, paste("no", t), fixed = TRUE)
  }
  expect_false(grepl("transport", qm$detail, fixed = TRUE))   # month 3 only
})
