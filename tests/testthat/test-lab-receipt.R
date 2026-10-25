# R-22.S (Robin 2026-10-25): ALS sample receipt notifications (SRN) are parsed
# into lab_qc_report (kind 'SRN') with the receipt facts as their own columns -
# "include all the temp, etc data as their own columns" - plus three child
# tables: lab_receipt_temperature (one row per reported temperature),
# lab_receipt_holding_breach (one row per Proactive Holding Time Report breach)
# and lab_receipt_comment (one row per General Comments bullet). The QCI front
# page's "Date Samples Received" fills received_at too. A db_check
# (lab_receipt_warm) warns about SRNs received warm.
#
# FIXTURES (tests/testthat/fixtures/srn/): SYNTHETIC `pdftotext -layout`
# text. The column layout is measured from two real ALS SRNs (one amended,
# one with a breach table); every name, address, contact, order/quote number, sample ID and
# value is invented. Read the same way as the QCI fixtures: a stub "PDF" and
# the mocked pdf_text() (helper-qci.R).
#   ES2690001: 3 temperatures, space-separated, "- Ice" wrapping to
#              "Bricks present"; 4 coolers; 3 comment bullets (one with
#              sub-items, one wrapped); no breaches; received in AEST.
#   ES2690002: "7.9'C, 8.4'C - Ice present"; 2 coolers; 2 holding breaches,
#              the second after a page break under a second method; received
#              in AEDT.
#   ES2690003: "Temperature : Not recorded", no cooling stated; 1 cooler;
#              received 09:00 AEST (the UTC instant is the previous day).
#   not_an_srn: readable text with no SRN title.
#
# Measured on the real SRNs, contrary to the spec's sketch: the Proactive
# Holding Time Report section is ALWAYS present - with no breaches it reads
# "Sample(s) have been received within the recommended holding times for the
# requested analysis." Its breach table carries no lab sample ID and no
# days-overdue column: rows are (client sample ID, container, due for
# extraction, due for analysis, samples-received date + evaluation mark,
# instructions-received date + mark) under a method line.
#
# Choices the spec leaves open, pinned here:
#   [invented: breach lab_sample_id] taken from the SRN's own Summary of
#     Sample(s) table, matching the breach's client sample ID.
#   [invented: breach due_date / days_overdue] due_date is the EARLIER of the
#     row's due-for-extraction and due-for-analysis dates ("----" ignored);
#     days_overdue = samples-received date - due_date, in days.
#   [invented: breach method] begins with the method code ("EA005-P...");
#     whether the method name follows is left open.
#   [invented: date-only received_at] a QCI prints "Date Samples Received" as a
#     date only; stored as 00:00 Australia/Sydney converted to UTC, the same
#     convention as sample.date.
#   [invented: cooling] "- Ice Bricks present" -> cooling_medium "Ice Bricks",
#     "- Ice present" -> "Ice", cooling_present TRUE; no cooling statement ->
#     both NULL. security_seal / delivery_mode are stored as printed.
#   [invented: unreadable] text with no "SAMPLE RECEIPT NOTIFICATION" title is
#     status 'unreadable' with a message, never an error.
#   [invented: pre-receipt-migration DB] lab_qc_report without the receipt
#     columns -> an SRN is skipped silently; a QCI is stored as before.
#   [invented: lab_qc_reparse] lab_qc_reparse(con, uuid_asset, path = NULL,
#     actor) forces a re-parse whatever the stored parser_version; path NULL
#     reads `<archive_dir>/<asset uuid>/<filename>`. Whether the report keeps
#     its uuid is left open; that it is not duplicated is not.

srn_fixture <- function(...) normalizePath(testthat::test_path("fixtures", "srn", ...), mustWork = TRUE)

lr_setup <- function(env = parent.frame(), receipt = TRUE) {
  db <- qc_db(env = env, receipt = receipt)
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = FALSE)
  withr::defer(if (DBI::dbIsValid(con)) DBI::dbDisconnect(con, shutdown = TRUE), envir = env)
  dir <- withr::local_tempdir(.local_envir = env)
  qci_mock_pdf_text(env = env)
  list(db = db, con = con, dir = dir)
}

lr_q <- function(con, sql, ...) DBI::dbGetQuery(con, sql, params = if (length(list(...))) list(...) else NULL)

# Ingest one asset (stub PDF reading `fixture`, or the real bytes at `path`).
lr_ingest <- function(s, filename, fixture = NULL, type = "QA", work_order = substr(filename, 1, 9)) {
  path <- if (is.null(fixture)) file.path(s$dir, filename) else qci_stub(s$dir, filename, fixture)
  ua <- qci_asset(s$con, filename, work_order, type = type)
  suppressWarnings(lab_qc_ingest(s$con, ua, path))
  rep <- lr_q(s$con, "SELECT * FROM lab_qc_report WHERE uuid_asset = ?", ua)
  kids <- function(tbl, order) {
    if (nrow(rep) != 1 || !DBI::dbExistsTable(s$con, tbl)) return(NULL)
    lr_q(s$con, sprintf("SELECT * FROM %s WHERE uuid_report = ? ORDER BY %s", tbl, order), rep$uuid)
  }
  list(asset = ua, path = path, report = rep,
       temps = kids("lab_receipt_temperature", "position"),
       comments = kids("lab_receipt_comment", "position"),
       breaches = kids("lab_receipt_holding_breach", "client_sample_id"))
}

lr_srn <- function(s, wo, filename = sprintf("%s_0_SRN_260929155925.pdf", wo)) {
  lr_ingest(s, filename, srn_fixture(sprintf("%s_0_SRN.txt", wo)))
}

utc <- function(x) as.POSIXct(x, tz = "UTC")

lr_child_counts <- function(con) {
  vapply(c("lab_receipt_temperature", "lab_receipt_comment", "lab_receipt_holding_breach"),
         function(t) as.integer(lr_q(con, sprintf("SELECT count(*) AS n FROM %s", t))$n), integer(1))
}

# ---- the SRN report row ------------------------------------------------------------------

test_that("R-22.S: an SRN asset is stored as one lab_qc_report row of kind SRN with its header fields", {
  s <- lr_setup()
  r <- lr_srn(s, "ES2690001")
  rep <- r$report
  expect_equal(nrow(rep), 1)
  if (nrow(rep) != 1) return()
  expect_identical(rep$kind, "SRN")
  expect_identical(rep$status, "parsed", info = rep$message)
  expect_identical(rep$work_order, "ES2690001")
  expect_equal(as.Date(rep$issue_date), as.Date("2026-09-29"))
  expect_equal(as.integer(rep$n_received), 18L)
  expect_equal(as.integer(rep$n_analysed), 17L)
  expect_equal(as.Date(rep$client_due_date), as.Date("2026-10-07"))
  expect_equal(as.Date(rep$scheduled_report_date), as.Date("2026-10-08"))
  expect_identical(rep$delivery_mode, "Carrier")
  expect_identical(rep$security_seal, "Intact.")
  expect_equal(as.integer(rep$n_coolers), 4L)
  expect_equal(as.integer(rep$n_container_noncompliances), 0L)
  expect_equal(as.integer(rep$n_holding_breaches), 0L)
  expect_true(!is.na(rep$parser_version) && nzchar(rep$parser_version))
  expect_false(is.na(rep$parsed_at))
})

test_that("R-22.S: received_at is the lab's Sydney local receipt time stored as UTC (AEST and AEDT)", {
  s <- lr_setup()
  a <- lr_srn(s, "ES2690001")$report   # 29-Sep-2026 10:30 AEST (+10)
  b <- lr_srn(s, "ES2690002")$report   # 15-Jan-2026 14:05 AEDT (+11)
  c <- lr_srn(s, "ES2690003")$report   # 02-Jun-2026 09:00 AEST -> previous UTC day
  expect_equal(nrow(a) + nrow(b) + nrow(c), 3)
  if (nrow(a) + nrow(b) + nrow(c) != 3) return()
  expect_equal(a$received_at, utc("2026-09-29 00:30:00"))
  expect_equal(b$received_at, utc("2026-01-15 03:05:00"))
  expect_equal(c$received_at, utc("2026-06-01 23:00:00"))
})

# ---- temperatures and cooling ------------------------------------------------------------

test_that("R-22.S: three temperatures on a wrapped line give three lab_receipt_temperature rows in order, min/max, and Ice Bricks present", {
  s <- lr_setup()
  r <- lr_srn(s, "ES2690001")
  expect_equal(nrow(r$report), 1)
  if (nrow(r$report) != 1) return()
  expect_equal(r$temps$temp_c, c(15.8, 16.7, 16.8))
  expect_equal(as.integer(r$temps$position), 1:3)
  expect_false(anyNA(r$temps$uuid))
  expect_equal(r$report$temp_min_c, 15.8)
  expect_equal(r$report$temp_max_c, 16.8)
  expect_identical(r$report$cooling_medium, "Ice Bricks")
  expect_true(isTRUE(r$report$cooling_present))
  # Three temperatures for four coolers: the counts are independent facts.
  expect_equal(as.integer(r$report$n_coolers), 4L)
})

test_that("R-22.S: comma-separated temperatures and 'Ice present' parse the same way", {
  s <- lr_setup()
  r <- lr_srn(s, "ES2690002")
  expect_equal(nrow(r$report), 1)
  if (nrow(r$report) != 1) return()
  expect_equal(r$temps$temp_c, c(7.9, 8.4))
  expect_equal(r$report$temp_min_c, 7.9)
  expect_equal(r$report$temp_max_c, 8.4)
  expect_identical(r$report$cooling_medium, "Ice")
  expect_true(isTRUE(r$report$cooling_present))
  expect_equal(as.integer(r$report$n_coolers), 2L)
  expect_identical(r$report$delivery_mode, "Client Drop Off")
})

test_that("R-22.S: an SRN with no temperature recorded stores NULL temperatures and no temperature rows", {
  s <- lr_setup()
  r <- lr_srn(s, "ES2690003")
  expect_equal(nrow(r$report), 1)
  if (nrow(r$report) != 1) return()
  expect_identical(r$report$status, "parsed", info = r$report$message)
  expect_true(is.na(r$report$temp_min_c))
  expect_true(is.na(r$report$temp_max_c))
  expect_equal(nrow(r$temps), 0)
  expect_true(is.na(r$report$cooling_medium))
  expect_true(is.na(r$report$cooling_present))
  expect_equal(as.integer(r$report$n_coolers), 1L)
  expect_identical(r$report$security_seal, "Not Available")
  expect_equal(as.integer(r$report$n_received), 2L)
})

# ---- comments and holding-time breaches --------------------------------------------------

test_that("R-22.S: General Comments bullets are stored one row each, in order, wrapped lines joined", {
  s <- lr_setup()
  r <- lr_srn(s, "ES2690001")
  expect_equal(nrow(r$report), 1)
  if (nrow(r$report) != 1) return()
  cm <- r$comments
  expect_equal(nrow(cm), 3)
  if (nrow(cm) != 3) return()
  expect_equal(as.integer(cm$position), 1:3)
  expect_match(cm$text[[1]], "^This report contains the following information:")
  expect_match(cm$text[[1]], "Summary of Sample(s) and Requested Analysis", fixed = TRUE)
  expect_identical(cm$text[[2]], "Sample #3 received without a label.")
  expect_identical(cm$text[[3]], paste(
    "Please be aware that samples should be chilled to less than or equal to 6°C for chemical",
    "analysis. Where samples are received above this temperature, it should be considered."))
  # Neither the bullet glyph nor the page footer leaks into a comment.
  expect_false(any(grepl("^l\\s", cm$text)))
  expect_false(any(grepl("right solutions", cm$text, fixed = TRUE)))
})

test_that("R-22.S: holding-time breaches are stored one row per sample and method, across a page break", {
  s <- lr_setup()
  r <- lr_srn(s, "ES2690002")
  expect_equal(nrow(r$report), 1)
  if (nrow(r$report) != 1) return()
  expect_identical(r$report$status, "parsed", info = r$report$message)
  expect_equal(as.integer(r$report$n_holding_breaches), 2L)
  b <- r$breaches
  expect_equal(nrow(b), 2)
  if (nrow(b) != 2) return()
  expect_identical(b$client_sample_id, c("Q.MW01", "Q.S02"))
  expect_identical(b$lab_sample_id, c("ES2690002-001", "ES2690002-003"))
  expect_match(b$method[[1]], "^EA005-P")
  expect_match(b$method[[2]], "^EP080")
  # Q.MW01: analysis due 14-Jan (no extraction), received 15-Jan.
  # Q.S02: extraction due 12-Jan (before analysis due 21-Feb), received 15-Jan.
  expect_equal(as.Date(b$due_date), as.Date(c("2026-01-14", "2026-01-12")))
  expect_equal(as.integer(b$days_overdue), c(1L, 3L))
  expect_true(all(b$uuid_report == r$report$uuid))
  expect_equal(nrow(r$comments), 1)
})

test_that("R-22.S: an SRN with no breaches stores n_holding_breaches 0 and no breach rows", {
  s <- lr_setup()
  r <- lr_srn(s, "ES2690003")
  expect_equal(nrow(r$report), 1)
  if (nrow(r$report) != 1) return()
  expect_equal(as.integer(r$report$n_holding_breaches), 0L)
  expect_equal(nrow(r$breaches), 0)
  expect_equal(as.integer(r$report$n_container_noncompliances), 0L)
})

# ---- failure, idempotency, pre-migration -------------------------------------------------

test_that("R-22.S: an SRN that is not readable as one is stored 'unreadable' with a message, kind SRN, and no child rows", {
  s <- lr_setup()
  r <- lr_ingest(s, "ES2690004_0_SRN_261001090000.pdf", srn_fixture("not_an_srn.txt"))
  expect_equal(nrow(r$report), 1)
  if (nrow(r$report) != 1) return()
  expect_identical(r$report$kind, "SRN")
  expect_identical(r$report$status, "unreadable")
  expect_true(!is.na(r$report$message) && nzchar(r$report$message))
  expect_identical(r$report$work_order, "ES2690004")
  expect_equal(unname(lr_child_counts(s$con)), c(0L, 0L, 0L))

  # A 0-byte SRN goes through the REAL pdf_text(): unreadable, never an error.
  file.copy(qci_fixture("ES2607384_0_QCI.pdf"), file.path(s$dir, "ES2690005_0_SRN_261001090000.pdf"))
  ua <- qci_asset(s$con, "ES2690005_0_SRN_261001090000.pdf", "ES2690005", type = "QA")
  expect_no_error(suppressWarnings(
    lab_qc_ingest(s$con, ua, file.path(s$dir, "ES2690005_0_SRN_261001090000.pdf"))))
  rep <- lr_q(s$con, "SELECT kind, status, message FROM lab_qc_report WHERE uuid_asset = ?", ua)
  expect_equal(nrow(rep), 1)
  expect_identical(rep$kind, "SRN")
  expect_identical(rep$status, "unreadable")
})

test_that("R-22.S: re-ingesting an SRN at the same parser version changes nothing; a stale version is replaced with its child rows", {
  s <- lr_setup()
  r1 <- lr_srn(s, "ES2690002")
  expect_equal(nrow(r1$report), 1)
  if (nrow(r1$report) != 1) return()
  n1 <- lr_child_counts(s$con)
  expect_equal(unname(n1), c(2L, 1L, 2L))
  t1 <- lr_q(s$con, "SELECT uuid FROM lab_receipt_temperature")$uuid

  suppressWarnings(lab_qc_ingest(s$con, r1$asset, r1$path))
  expect_equal(nrow(qci_reports(s$con)), 1)
  expect_identical(lr_child_counts(s$con), n1)
  expect_setequal(lr_q(s$con, "SELECT uuid FROM lab_receipt_temperature")$uuid, t1)

  DBI::dbExecute(s$con, "UPDATE lab_qc_report SET parser_version = '0'")
  suppressWarnings(lab_qc_ingest(s$con, r1$asset, r1$path))
  rep <- qci_reports(s$con)
  expect_equal(nrow(rep), 1)
  expect_false(identical(rep$parser_version, "0"))
  expect_identical(lr_child_counts(s$con), n1)
  t3 <- lr_q(s$con, "SELECT uuid, uuid_report FROM lab_receipt_temperature")
  expect_length(intersect(t3$uuid, t1), 0)
  for (t in c("lab_receipt_temperature", "lab_receipt_comment", "lab_receipt_holding_breach")) {
    expect_true(all(lr_q(s$con, sprintf("SELECT uuid_report FROM %s", t))$uuid_report == rep$uuid), info = t)
  }
})

test_that("R-22.S: on a DB without the receipt schema an SRN is skipped silently and a QCI is still stored", {
  s <- lr_setup(receipt = FALSE)
  ua <- qci_asset(s$con, "ES2690001_0_SRN_260929155925.pdf", "ES2690001", type = "QA")
  p <- qci_stub(s$dir, "ES2690001_0_SRN_260929155925.pdf", srn_fixture("ES2690001_0_SRN.txt"))
  expect_no_error(lab_qc_ingest(s$con, ua, p))
  expect_equal(nrow(lr_q(s$con, "SELECT * FROM lab_qc_report WHERE uuid_asset = ?", ua)), 0)
  q <- lr_ingest(s, "ES2609470_0_QCI.pdf", "ES2609470_0_QCI.txt", type = "QC")
  expect_equal(nrow(q$report), 1)
  expect_identical(q$report$status, "parsed")
})

test_that("R-22.S: the mutation layer accepts the three receipt tables", {
  for (t in c("lab_receipt_temperature", "lab_receipt_holding_breach", "lab_receipt_comment")) {
    expect_no_error(.st_validate_table(t))
  }
})

# ---- QCI received_at, re-parse and backfill ----------------------------------------------

test_that("R-22.S: a QCI's Date Samples Received fills received_at (Sydney midnight as UTC); its receipt columns stay NULL", {
  s <- lr_setup()
  a <- lr_ingest(s, "ES2609470_0_QCI.pdf", "ES2609470_0_QCI.txt", type = "QC")$report  # 24-Mar-2026, AEDT
  b <- lr_ingest(s, "ES2028911_0_QCI.pdf", "ES2028911_0_QCI.txt", type = "QC")$report  # 18-Aug-2020, AEST
  expect_equal(a$received_at, utc("2026-03-23 13:00:00"))
  expect_equal(b$received_at, utc("2020-08-17 14:00:00"))
  expect_identical(a$status, "parsed")
  expect_true(is.na(a$temp_max_c))
  expect_true(is.na(a$n_coolers))
  expect_equal(unname(lr_child_counts(s$con)), c(0L, 0L, 0L))
})

test_that("R-22.S: lab_qc_reparse() re-parses a current QCI report in place - received_at filled, one report, outliers not duplicated", {
  s <- lr_setup()
  r <- lr_ingest(s, "ES2609470_0_QCI.pdf", "ES2609470_0_QCI.txt", type = "QC")
  # As a report stored before R-22.S: current parser_version, no received_at.
  DBI::dbExecute(s$con, "UPDATE lab_qc_report SET received_at = NULL")
  expect_no_error(suppressWarnings(lab_qc_reparse(s$con, r$asset, r$path, actor = "test")))
  rep <- qci_reports(s$con)
  expect_equal(nrow(rep), 1)
  expect_equal(rep$received_at, utc("2026-03-23 13:00:00"))
  o <- qci_outliers(s$con)
  expect_equal(nrow(o), 5)
  expect_true(all(o$uuid_report == rep$uuid))
})

test_that("R-22.S: lab_qc_reparse() with no path reads the archived copy, and refills an SRN's child rows without duplicating them", {
  s <- lr_setup()
  arch <- withr::local_tempdir()
  withr::local_options(list("sampletidy.archive_dir" = arch))
  f <- "ES2690001_0_SRN_260929155925.pdf"
  ua <- qci_asset(s$con, f, "ES2690001", type = "QA")
  dir.create(file.path(arch, ua))
  qci_stub(file.path(arch, ua), f, srn_fixture("ES2690001_0_SRN.txt"))
  expect_no_error(suppressWarnings(lab_qc_reparse(s$con, ua, actor = "test")))
  rep <- qci_reports(s$con)
  expect_equal(nrow(rep), 1)
  expect_identical(rep$kind, "SRN")
  expect_equal(rep$received_at, utc("2026-09-29 00:30:00"))
  n1 <- lr_child_counts(s$con)
  expect_equal(unname(n1), c(3L, 3L, 0L))
  suppressWarnings(lab_qc_reparse(s$con, ua, actor = "test"))
  expect_equal(nrow(qci_reports(s$con)), 1)
  expect_identical(lr_child_counts(s$con), n1)
})

test_that("R-22.S: lab_qc_backfill also parses archived QA assets carrying the _SRN_ token, and no other QA asset", {
  s <- lr_setup()
  arch <- withr::local_tempdir()
  withr::local_options(list("sampletidy.archive_dir" = arch))
  put <- function(filename, fixture, type) {
    ua <- qci_asset(s$con, filename, substr(filename, 1, 9), type = type)
    dir.create(file.path(arch, ua))
    qci_stub(file.path(arch, ua), filename, fixture)
    ua
  }
  a_srn <- put("ES2690002_0_SRN_260116090000.pdf", srn_fixture("ES2690002_0_SRN.txt"), "QA")
  a_coc <- put("ES2690002_0_COC.pdf", srn_fixture("ES2690002_0_SRN.txt"), "QA")
  DBI::dbDisconnect(s$con, shutdown = TRUE)

  suppressWarnings(suppressMessages(lab_qc_backfill(s$db, actor = "test-backfill")))

  con <- DBI::dbConnect(duckdb::duckdb(), s$db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  rep <- DBI::dbGetQuery(con, "SELECT * FROM lab_qc_report")
  expect_identical(rep$uuid_asset, a_srn)
  expect_identical(rep$kind, "SRN")
  expect_equal(as.integer(rep$n_holding_breaches), 2L)
  expect_equal(nrow(DBI::dbGetQuery(con, "SELECT * FROM lab_receipt_holding_breach")), 2)
})

# ---- retention integration ---------------------------------------------------------------

lr_ingest_dir_setup <- function(env = parent.frame()) {
  db <- seed_db(dir = withr::local_tempdir(.local_envir = env))
  con <- seed_con(db)
  ensure_test_asset_table(con)
  qc_create_tables(con)
  DBI::dbDisconnect(con, shutdown = TRUE)
  withr::local_options(list(
    "sampletidy.archive_dir" = withr::local_tempdir(.local_envir = env),
    "sampletidy.snapshot_dir" = withr::local_tempdir(.local_envir = env),
    "sampletidy.remove_ingested" = FALSE
  ), .local_envir = env)
  input <- withr::local_tempdir(.local_envir = env)
  for (f in list.files(testthat::test_path("fixtures", "esdat"), pattern = "ES2617126",
                       full.names = TRUE)) {
    file.copy(f, file.path(input, basename(f)))
  }
  qci_mock_pdf_text(env = env)
  list(db = db, input = input)
}

test_that("R-22.S: retaining an SRN sibling parses it in the same run; an unreadable SRN is still retained", {
  s <- lr_ingest_dir_setup()
  # The synthetic SRN re-pointed at the fixture's committed work order.
  lines <- gsub("ES2690001", "ES2617126", readLines(srn_fixture("ES2690001_0_SRN.txt"), encoding = "UTF-8"),
                fixed = TRUE)
  qci_stub(s$input, "ES2617126_0_SRN_260929155925.pdf", qci_write_lines(lines))
  file.copy(qci_fixture("ES2602084_0_QC.pdf"), file.path(s$input, "ES2617126_1_SRN_261001090000.pdf"))
  suppressWarnings(suppressMessages(ingest_dir(s$input, db = s$db)))

  con <- DBI::dbConnect(duckdb::duckdb(), s$db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  st <- DBI::dbGetQuery(con, "SELECT filename, state FROM ingest_file WHERE filename LIKE '%_SRN_%'")
  expect_equal(nrow(st), 2)
  expect_true(all(st$state == "archived"))
  rep <- DBI::dbGetQuery(con, "SELECT r.*, a.filename, a.type FROM lab_qc_report r
                               JOIN asset a ON a.uuid = r.uuid_asset")
  expect_equal(nrow(rep), 2)
  if (nrow(rep) != 2) return()
  expect_true(all(rep$kind == "SRN"))
  expect_true(all(rep$type == "QA"))
  good <- rep[rep$filename == "ES2617126_0_SRN_260929155925.pdf", , drop = FALSE]
  expect_identical(good$status, "parsed")
  expect_identical(good$work_order, "ES2617126")
  expect_equal(good$temp_max_c, 16.8)
  expect_equal(nrow(DBI::dbGetQuery(con, "SELECT * FROM lab_receipt_temperature WHERE uuid_report = ?",
                                    params = list(good$uuid))), 3)
  bad <- rep[rep$filename == "ES2617126_1_SRN_261001090000.pdf", , drop = FALSE]
  expect_identical(bad$status, "unreadable")
})

# ---- db_checks: lab_receipt_warm, vocab_lab_qc_kind ----------------------------------------

test_that("R-22.S: lab_receipt_warm is an hourly warn check; vocab_lab_qc_kind an hourly error check", {
  core <- db_checks_core()
  w <- core[core$name == "lab_receipt_warm", , drop = FALSE]
  expect_equal(nrow(w), 1)
  expect_identical(w$tier, "hourly")
  expect_identical(w$severity, "warn")
  k <- core[core$name == "vocab_lab_qc_kind", , drop = FALSE]
  expect_equal(nrow(k), 1)
  expect_identical(k$tier, "hourly")
  expect_identical(k$severity, "error")
})

test_that("R-22.S: db_checks_params() carries receipt_max_temp_c (6) and receipt_lookback_days (90), overridable", {
  p <- db_checks_params()
  expect_equal(p$receipt_max_temp_c, 6)
  expect_equal(p$receipt_lookback_days, 90)
  p2 <- db_checks_params(receipt_max_temp_c = 10, receipt_lookback_days = 30)
  expect_equal(p2$receipt_max_temp_c, 10)
  expect_equal(p2$receipt_lookback_days, 30)
  expect_error(db_checks_params(receipt_max_temp_c = "warm"))
  expect_error(db_checks_params(receipt_lookback_days = -1))
})

lr_warm_res <- function(params = db_checks_params()) {
  db <- dbc_db(env = parent.frame())
  dbc_with(db, function(con) {
    dbc_exec(con, "INSERT INTO asset (uuid, name, uuid_project, hash)
                   VALUES ('as-warm', 'XX7654321_0_SRN_260101000000.pdf', 'p-0001', ?)", dbc_hex(912))
    dbc_srn_report(con, "lqr-warm", "as-warm", "XX7654321", temp_max = 16.8, days_ago = 10)
    db_checks(con, tier = "hourly", params = params)
  })
}

test_that("R-22.S: lab_receipt_warm honours receipt_max_temp_c and receipt_lookback_days", {
  # The clean fixture also holds a warm SRN 200 days old (XX2000001) and one at
  # exactly 6 degrees (XX2000002); neither is flagged by default.
  r0 <- dbc_row(lr_warm_res(), "lab_receipt_warm")
  expect_identical(r0$status, "fail")
  expect_identical(r0$n, 1L)
  expect_identical(as.character(r0$sample[[1]]$key), "XX7654321")
  expect_identical(dbc_row(lr_warm_res(db_checks_params(receipt_max_temp_c = 20)), "lab_receipt_warm")$status,
                   "pass")
  expect_identical(dbc_row(lr_warm_res(db_checks_params(receipt_lookback_days = 5)), "lab_receipt_warm")$status,
                   "pass")
  r3 <- dbc_row(lr_warm_res(db_checks_params(receipt_lookback_days = 365)), "lab_receipt_warm")
  expect_identical(r3$n, 2L)
  expect_setequal(as.character(r3$sample[[1]]$key), c("XX7654321", "XX2000001"))
})

test_that("R-22.S: lab_receipt_warm ignores QCI rows and SRNs with no temperature", {
  db <- dbc_db()
  res <- dbc_with(db, function(con) {
    dbc_exec(con, "UPDATE lab_qc_report SET temp_max_c = 30, received_at = CAST(? AS TIMESTAMP)
                   WHERE uuid = 'lqr-0001'", dbc_ago(1))   # the clean QCI row
    dbc_exec(con, "UPDATE lab_qc_report SET temp_max_c = NULL, temp_min_c = NULL WHERE uuid = 'lqr-0002'")
    db_checks(con, tier = "hourly")
  })
  expect_identical(dbc_row(res, "lab_receipt_warm")$status, "pass", info = dbc_bad(res))
})
