# sampling_rounds(ledger): reads the contractor work ledger written by the t1
# tool (invoice-automation/docs/contractor-work-ledger.md) into the
# checks$invoices shape. Contract: PLAN-18 section 4.6. Fixtures are small
# hand-written ledgers in fixtures/contractor_work/.

sr_cols <- c("site", "stream", "sampled_on", "ref", "section", "note")

sr_fixture <- function(name) test_path("fixtures", "contractor_work", name)

sr_rows <- function(site, stream, sampled_on, ref, section, note = NA_character_) {
  n <- length(stream)
  data.frame(
    site = rep(site, length.out = n),
    stream = stream,
    sampled_on = as.Date(rep(sampled_on, length.out = n)),
    ref = rep(ref, length.out = n),
    section = rep(section, length.out = n),
    note = rep(as.character(note), length.out = n),
    stringsAsFactors = FALSE
  )
}

sr_norm <- function(x) {
  x <- as.data.frame(x, stringsAsFactors = FALSE)
  rownames(x) <- NULL
  x
}

sr_expect_shape <- function(x) {
  expect_s3_class(x, "data.frame")
  expect_identical(names(x), sr_cols)
  expect_s3_class(x$sampled_on, "Date")
  for (cl in setdiff(sr_cols, "sampled_on")) expect_type(x[[cl]], "character")
}

test_that("sampling_rounds(ledger) is exported with a single argument", {
  expect_true("sampling_rounds" %in% getNamespaceExports("sampleTidy"))
  expect_identical(names(formals(sampleTidy::sampling_rounds)), "ledger")
  expect_false("acirl_invoices" %in% getNamespaceExports("sampleTidy"))
})

test_that("real-invoice ledger (AC101708/AC101860/AC102053/AC102221) gives the pinned rows", {
  got <- sampling_rounds(sr_fixture("real.json"))
  sr_expect_shape(got)
  want <- rbind(
    sr_rows("K", c("acirl_water", "als_lab"), "2026-08-17", "AC101708", "Monthly"),
    sr_rows(
      "B", c("acirl_water", "acirl_gas", "acirl_dust", "als_lab"), "2026-08-19", "AC101860",
      c("Monthly", "Gas Monitoring", "Monthly Dust", "Monthly")
    ),
    sr_rows("B", c("acirl_water", "als_lab"), "2026-09-19", "AC102053", "Annual",
      note = "date disagrees with period August 2026"
    ),
    sr_rows("K", c("acirl_water", "acirl_gas", "als_lab"), "2026-09-14", "AC102221", "Quarterly")
  )
  expect_identical(sr_norm(got), want)
})

test_that("a ledger date that disagrees with its period is kept as printed, with the note", {
  got <- sr_norm(sampling_rounds(sr_fixture("real.json")))
  b <- got[got$ref == "AC102053", ]
  expect_identical(b$sampled_on, as.Date(c("2026-09-19", "2026-09-19")))
  expect_identical(b$note, rep("date disagrees with period August 2026", 2))
  expect_true(all(is.na(got$note[got$ref != "AC102053"])))
})

test_that("unknown kinds, unknown sites and unknown streams are dropped silently", {
  expect_silent(got <- sampling_rounds(sr_fixture("mixed.json")))
  sr_expect_shape(got)
  expect_identical(
    sr_norm(got),
    rbind(
      sr_rows("B", "acirl_water", "2026-10-01", "AC200001", "Monthly"),
      sr_rows("K", "acirl_dust", "2026-10-03", "AC200001", "Monthly Dust")
    )
  )
})

test_that("another supplier's entry with a future kind and empty items contribute nothing", {
  got <- sampling_rounds(sr_fixture("mixed.json"))
  expect_false(any(got$ref %in% c("AC200002", "INV-7875")))
})

test_that("a ledger with no invoices gives a zero-row frame with the pinned columns and types", {
  got <- sampling_rounds(sr_fixture("empty.json"))
  sr_expect_shape(got)
  expect_equal(nrow(got), 0)
})

test_that("a missing ledger file gives a zero-row frame, no error, no output", {
  missing <- file.path(withr::local_tempdir(), "contractor-work.json")
  expect_silent(got <- sampling_rounds(missing))
  sr_expect_shape(got)
  expect_equal(nrow(got), 0)
})

test_that("a corrupt ledger is a sampletidy_parse_error naming the path", {
  path <- sr_fixture("corrupt.json")
  err <- expect_error(sampling_rounds(path), class = "sampletidy_parse_error")
  expect_match(conditionMessage(err), "corrupt.json", fixed = TRUE)
})

test_that("a ledger with version other than 1 is an error", {
  expect_error(sampling_rounds(sr_fixture("version2.json")))
})

test_that("sampling_rounds() is read-only", {
  dir <- withr::local_tempdir()
  f <- file.path(dir, "contractor-work.json")
  file.copy(sr_fixture("real.json"), f)
  before <- tools::md5sum(f)
  sampling_rounds(f)
  expect_identical(tools::md5sum(f), before)
  expect_identical(list.files(dir), "contractor-work.json")
})

test_that("the result is accepted as checks$invoices columns (site, stream, sampled_on, ref)", {
  got <- sampling_rounds(sr_fixture("real.json"))
  expect_true(all(c("site", "stream", "sampled_on", "ref") %in% names(got)))
  expect_true(all(got$site %in% c("B", "K")))
  expect_true(all(got$stream %in% c("acirl_water", "acirl_gas", "acirl_dust", "als_lab")))
})
