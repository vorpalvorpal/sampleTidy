# PLAN-19 phase 1b: lab-QC storage (R-19.8, R-19.9), the ingest parse step
# (R-19.16), the operator backfill (R-19.17) and outlier linking (R-19.21).
#
# lab_qc_ingest(con, uuid_asset, path) reads the PDF with pdftools::pdf_text().
# Real QCIs cannot be committed, so a stub file stands in for the PDF and
# pdf_text() is mocked to return the anonymised fixture's pages
# (qci_mock_pdf_text(), helper-qci.R). The 0-byte QCI and the corrupt QC.pdf
# go through the REAL pdf_text().
#
# Choices the plan leaves open, taken as the simplest reading:
#   [invented: mismatch] a header Work Order that disagrees with the filename's
#     is recorded in lab_qc_report.message (naming the filename's work order);
#     the status stays 'parsed' and the header's work order is stored.
#   [invented: QC.pdf] the PDF is read BEFORE dispatch (R-19.16's order), so an
#     unreadable QC.pdf is 'unreadable'; a readable one is 'partial'.
#   [invented: version] any stored parser_version other than the current one
#     counts as stale and is re-parsed; the current one is left alone.
#   [invented: pre-048] on a DB without lab_qc_report, retention proceeds and
#     the parse step is skipped silently.
#   [invented: backfill] an asset whose archived copy is missing is skipped.

lq_setup <- function(env = parent.frame()) {
  db <- qc_db(env = env)
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = FALSE)
  withr::defer(if (DBI::dbIsValid(con)) DBI::dbDisconnect(con, shutdown = TRUE), envir = env)
  dir <- withr::local_tempdir(.local_envir = env)
  qci_mock_pdf_text(env = env)
  list(db = db, con = con, dir = dir)
}

lq_ingest <- function(s, filename, fixture, work_order = substr(filename, 1, 9)) {
  path <- if (is.null(fixture)) file.path(s$dir, filename) else qci_stub(s$dir, filename, fixture)
  ua <- qci_asset(s$con, filename, work_order)
  suppressWarnings(lab_qc_ingest(s$con, ua, path))
  rep <- DBI::dbGetQuery(s$con, "SELECT * FROM lab_qc_report WHERE uuid_asset = ?", params = list(ua))
  list(asset = ua, report = rep,
       outliers = if (nrow(rep) == 1) qci_outliers(s$con, rep$uuid) else qci_outliers(s$con)[0, ])
}

# ---- R-19.8 / R-19.9 / R-19.16 storage -----------------------------------------------

test_that("R-19.16/R-19.8: lab_qc_ingest stores one parsed lab_qc_report row for a QCI", {
  s <- lq_setup()
  r <- lq_ingest(s, "ES2609470_0_QCI.pdf", "ES2609470_0_QCI.txt")
  rep <- r$report
  expect_equal(nrow(rep), 1)
  expect_identical(rep$kind, "QCI")
  expect_identical(rep$status, "parsed")
  expect_identical(rep$work_order, "ES2609470")
  expect_equal(as.Date(rep$issue_date), as.Date("2026-03-30"))
  expect_equal(as.integer(rep$n_received), 1L)
  expect_equal(as.integer(rep$n_analysed), 1L)
  expect_true(!is.na(rep$parser_version) && nzchar(rep$parser_version))
  expect_false(is.na(rep$parsed_at))
  expect_false(is.na(rep$uuid))
  sm <- jsonlite::fromJSON(rep$summary)
  expect_setequal(names(sm), .qci_summary_keys)
  expect_identical(unlist(sm[.qci_summary_keys]),
                   c(mb = FALSE, dup = FALSE, lcs = FALSE, ms = TRUE, surrogate = FALSE,
                     holding_time = TRUE, frequency = TRUE))
})

test_that("R-19.9: the report's outlier rows are stored with uuid_report, work_order and normalised lab IDs", {
  s <- lq_setup()
  r <- lq_ingest(s, "ES2609470_0_QCI.pdf", "ES2609470_0_QCI.txt")
  o <- r$outliers
  expect_equal(nrow(o), 5)
  expect_equal(as.vector(table(factor(o$kind, c("ms", "holding_time", "frequency")))), c(2, 2, 1))
  expect_true(all(o$uuid_report == r$report$uuid))
  expect_true(all(o$work_order == "ES2609470"))
  expect_false(anyNA(o$uuid))
  expect_equal(length(unique(o$uuid)), 5)
  expect_setequal(stats::na.omit(o$lab_id), c("ES2609442-001", "ES2609438-001"))
  ht <- o[o$kind == "holding_time", , drop = FALSE]
  expect_setequal(as.integer(ht$days_overdue), c(5L, 3L))
  expect_true(all(is.na(o$uuid_sample)))      # nothing in this DB to link to
})

test_that("R-19.16: a 0-byte QCI (the real ES2607384 archived copy) is stored 'unreadable', never an error", {
  s <- lq_setup()
  file.copy(qci_fixture("ES2607384_0_QCI.pdf"), file.path(s$dir, "ES2607384_0_QCI.pdf"))
  ua <- qci_asset(s$con, "ES2607384_0_QCI.pdf", "ES2607384")
  expect_no_error(suppressWarnings(
    lab_qc_ingest(s$con, ua, file.path(s$dir, "ES2607384_0_QCI.pdf"))))
  rep <- DBI::dbGetQuery(s$con, "SELECT * FROM lab_qc_report WHERE uuid_asset = ?", params = list(ua))
  expect_equal(nrow(rep), 1)
  expect_identical(rep$status, "unreadable")
  expect_true(!is.na(rep$message) && nzchar(rep$message))
  expect_equal(nrow(qci_outliers(s$con)), 0)
})

test_that("R-19.16: a corrupt PDF (stand-in for ES2602084_0_QC.pdf) is stored 'unreadable' with the error message", {
  s <- lq_setup()
  file.copy(qci_fixture("ES2602084_0_QC.pdf"), file.path(s$dir, "ES2602084_0_QC.pdf"))
  r <- lq_ingest(s, "ES2602084_0_QC.pdf", NULL)
  expect_equal(nrow(r$report), 1)
  expect_identical(r$report$status, "unreadable")
  expect_identical(r$report$kind, "QC")
  expect_true(!is.na(r$report$message) && nzchar(r$report$message))
})

test_that("R-19.16: a readable _QC.pdf (phase 3 parser not built) is stored 'partial', 'QC.pdf not parsed yet'", {
  s <- lq_setup()
  r <- lq_ingest(s, "ES2609470_0_QC.pdf", "ES2609470_0_QCI.txt")
  expect_equal(nrow(r$report), 1)
  expect_identical(r$report$kind, "QC")
  expect_identical(r$report$status, "partial")
  expect_match(r$report$message, "QC.pdf not parsed yet", fixed = TRUE)
  expect_equal(nrow(qci_outliers(s$con)), 0)
})

test_that("R-19.19: a header Work Order that disagrees with the filename is a warning; the header wins", {
  s <- lq_setup()
  r <- lq_ingest(s, "ES2600001_0_QCI.pdf", "ES2609470_0_QCI.txt")
  expect_identical(r$report$work_order, "ES2609470")
  expect_identical(r$report$status, "parsed")
  expect_match(r$report$message, "ES2600001", fixed = TRUE)
  expect_true(all(r$outliers$work_order == "ES2609470"))
})

test_that("R-19.19: an unrecognised Summary bullet makes the report 'partial' with a message", {
  s <- lq_setup()
  lines <- qci_lines("ES2014537")
  i <- grep("NO Duplicate outliers occur.", lines, fixed = TRUE)
  lines[[i]] <- sub("NO Duplicate outliers occur.", "Duplicate outliers are under review.",
                    lines[[i]], fixed = TRUE)
  r <- lq_ingest(s, "ES2014537_0_QCI.pdf", qci_write_lines(lines))
  expect_identical(r$report$status, "partial")
  expect_true(!is.na(r$report$message) && nzchar(r$report$message))
})

test_that("R-19.9: re-ingesting at the same parser_version changes nothing; a stale version is replaced", {
  s <- lq_setup()
  r1 <- lq_ingest(s, "ES2028911_0_QCI.pdf", "ES2028911_0_QCI.txt")
  ua <- r1$asset
  path <- file.path(s$dir, "ES2028911_0_QCI.pdf")
  n1 <- nrow(r1$outliers)
  expect_equal(n1, 31)   # 1 LCS + 24 holding-time + 6 frequency

  suppressWarnings(lab_qc_ingest(s$con, ua, path))
  expect_equal(nrow(qci_reports(s$con)), 1)
  o2 <- qci_outliers(s$con)
  expect_setequal(o2$uuid, r1$outliers$uuid)

  DBI::dbExecute(s$con, "UPDATE lab_qc_report SET parser_version = '0'")
  suppressWarnings(lab_qc_ingest(s$con, ua, path))
  rep <- qci_reports(s$con)
  expect_equal(nrow(rep), 1)
  expect_identical(rep$parser_version, r1$report$parser_version)
  o3 <- qci_outliers(s$con)
  expect_equal(nrow(o3), n1)
  expect_length(intersect(o3$uuid, r1$outliers$uuid), 0)
  expect_true(all(o3$uuid_report == rep$uuid))
})

# ---- R-19.21 linking ------------------------------------------------------------------

lq_link_setup <- function(env = parent.frame()) {
  s <- lq_setup(env = env)
  con <- s$con
  # Q.S39 is known to the registry as "Ridgely Road Seep" (an anonymised
  # own-sample client ID); Q.S40 is another point of the same work order.
  u <- fl_feature(con, "Q.S39")
  DBI::dbExecute(con, "INSERT INTO feature_alias (uuid, uuid_feature, name, alias_key, kind, auto_assign)
                       VALUES (?, ?, 'Ridgely Road Seep', ?, 'descriptive', TRUE)",
                 params = list(fl_uuid(), u, .rc_feature_key("Ridgely Road Seep")))
  s$s39 <- fl_sample(con, "Q.S39", "ES2028716", "2020-08-14",
                     results = list(qci_lab("Nitrite as N", 0.1, "EK057G: Nitrite as N by Discrete Analyser")))
  s$s40 <- fl_sample(con, "Q.S40", "ES2028716", "2020-08-14",
                     results = list(qci_lab("Ammonia as N", 0.3, "EK055G: Ammonia as N by Discrete Analyser")))
  s
}

test_that("R-19.21 route 1: a lab ID in the same work order links through sample_lab_id (first match wins)", {
  s <- lq_link_setup()
  DBI::dbExecute(s$con, "INSERT INTO sample_lab_id (uuid_sample, work_order, lab_id, client_id, source_hash)
                         VALUES (?, 'ES2028716', 'ES2028716-002', 'Q.S40', 'abc')",
                 params = list(s$s40))
  r <- lq_ingest(s, "ES2028716_0_QCI.pdf", "ES2028716_0_QCI.txt")
  ms <- r$outliers[r$outliers$kind == "ms", , drop = FALSE]
  expect_equal(nrow(ms), 3)
  # Route 1 beats route 2: the client ID "Ridgely Road Seep" would give Q.S39.
  expect_true(all(ms$uuid_sample %in% s$s40))
})

test_that("R-19.21 route 2: (work order, client ID) links when the alias resolves to exactly one sample", {
  s <- lq_link_setup()
  r <- lq_ingest(s, "ES2028716_0_QCI.pdf", "ES2028716_0_QCI.txt")
  ht <- r$outliers[r$outliers$kind == "holding_time", , drop = FALSE]
  expect_equal(nrow(ht), 4)
  seep <- ht[ht$client_id == "Ridgely Road Seep", , drop = FALSE]
  expect_equal(nrow(seep), 2)
  expect_true(all(seep$uuid_sample %in% s$s39))
  # "End Ridgely Road" resolves to no feature -> NULL.
  expect_true(all(is.na(ht$uuid_sample[ht$client_id == "End Ridgely Road"])))
  # No sample_lab_id rows: the MS rows link by route 2 as well.
  ms <- r$outliers[r$outliers$kind == "ms", , drop = FALSE]
  expect_true(all(ms$uuid_sample %in% s$s39))
})

test_that("R-19.21 route 2: several matching samples in the work order leave the row unlinked", {
  s <- lq_link_setup()
  fl_sample(s$con, "Q.S39", "ES2028716", "2020-08-14 05:00:00",
            results = list(qci_lab("Nitrite as N", 0.2, "EK057G: Nitrite as N by Discrete Analyser")))
  r <- lq_ingest(s, "ES2028716_0_QCI.pdf", "ES2028716_0_QCI.txt")
  ht <- r$outliers[r$outliers$kind == "holding_time", , drop = FALSE]
  expect_true(all(is.na(ht$uuid_sample)))
})

test_that("R-19.21: an Anonymous row is never linked, even when its lab ID is in sample_lab_id", {
  s <- lq_setup()
  other <- fl_sample(s$con, "Q.S41", "ES2609442", "2026-03-19",
                     results = list(qci_lab("Ammonia as N", 0.3, "EK055G: Ammonia as N by Discrete Analyser")))
  DBI::dbExecute(s$con, "INSERT INTO sample_lab_id (uuid_sample, work_order, lab_id, client_id, source_hash)
                         VALUES (?, 'ES2609442', 'ES2609442-001', 'Q.S41', 'abc')",
                 params = list(other))
  r <- lq_ingest(s, "ES2609470_0_QCI.pdf", "ES2609470_0_QCI.txt")
  ms <- r$outliers[r$outliers$kind == "ms", , drop = FALSE]
  expect_equal(nrow(ms), 2)
  expect_true(all(is.na(ms$uuid_sample)))
})

# ---- R-19.16 retention integration ------------------------------------------------------

lq_ingest_dir_setup <- function(env = parent.frame(), tables = TRUE) {
  db <- seed_db(dir = withr::local_tempdir(.local_envir = env))
  con <- seed_con(db)
  ensure_test_asset_table(con)
  if (tables) qc_create_tables(con)
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

lq_db_get <- function(db, sql, ...) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbGetQuery(con, sql, params = list(...))
}

test_that("R-19.16: retaining a QCI sibling parses it in the same run; an unreadable QC.pdf still lands", {
  s <- lq_ingest_dir_setup()
  qci_stub(s$input, "ES2617126_0_QCI.pdf", "ES2609470_0_QCI.txt")
  file.copy(qci_fixture("ES2602084_0_QC.pdf"), file.path(s$input, "ES2617126_0_QC.pdf"))
  suppressWarnings(suppressMessages(ingest_dir(s$input, db = s$db)))

  assets <- lq_db_get(s$db, "SELECT uuid, filename, type FROM asset WHERE type = 'QC'")
  expect_setequal(assets$filename, c("ES2617126_0_QCI.pdf", "ES2617126_0_QC.pdf"))
  st <- lq_db_get(s$db, "SELECT filename, state, state_reason FROM ingest_file
                         WHERE filename IN ('ES2617126_0_QCI.pdf', 'ES2617126_0_QC.pdf')")
  expect_true(all(st$state == "archived"))

  rep <- lq_db_get(s$db, "SELECT r.*, a.filename FROM lab_qc_report r JOIN asset a ON a.uuid = r.uuid_asset")
  expect_equal(nrow(rep), 2)
  qci <- rep[rep$filename == "ES2617126_0_QCI.pdf", , drop = FALSE]
  expect_identical(qci$kind, "QCI")
  expect_identical(qci$status, "parsed")
  qc <- rep[rep$filename == "ES2617126_0_QC.pdf", , drop = FALSE]
  expect_identical(qc$kind, "QC")
  expect_identical(qc$status, "unreadable")
  expect_equal(nrow(lq_db_get(s$db, "SELECT * FROM lab_qc_outlier WHERE uuid_report = ?", qci$uuid)), 5)
})

test_that("R-19.16: on a DB without the 048 tables, a QCI sibling is still retained", {
  s <- lq_ingest_dir_setup(tables = FALSE)
  qci_stub(s$input, "ES2617126_0_QCI.pdf", "ES2609470_0_QCI.txt")
  suppressWarnings(suppressMessages(ingest_dir(s$input, db = s$db)))
  st <- lq_db_get(s$db, "SELECT state FROM ingest_file WHERE filename = 'ES2617126_0_QCI.pdf'")
  expect_identical(st$state, "archived")
  expect_equal(nrow(lq_db_get(s$db, "SELECT * FROM asset WHERE filename = 'ES2617126_0_QCI.pdf'")), 1)
})

# ---- R-19.17 backfill --------------------------------------------------------------------

test_that("R-19.17: lab_qc_backfill parses every QC asset with an archived copy and no current report", {
  s <- lq_setup()
  arch <- withr::local_tempdir()
  withr::local_options(list("sampletidy.archive_dir" = arch))
  put <- function(filename, fixture, type = "QC", archived = TRUE) {
    ua <- qci_asset(s$con, filename, substr(filename, 1, 9), type = type)
    if (archived) {
      dir.create(file.path(arch, ua))
      if (is.null(fixture)) {
        file.copy(qci_fixture(filename), file.path(arch, ua, filename))
      } else {
        qci_stub(file.path(arch, ua), filename, fixture)
      }
    }
    ua
  }
  a_qci <- put("ES2609470_0_QCI.pdf", "ES2609470_0_QCI.txt")
  a_empty <- put("ES2607384_0_QCI.pdf", NULL)
  a_missing <- put("ES2027611_0_QCI.pdf", "ES2027611_0_QCI.txt", archived = FALSE)
  a_coa <- put("ES2609470_0_COA.pdf", "ES2609470_0_QCI.txt", type = "Certificate of analysis")
  DBI::dbDisconnect(s$con, shutdown = TRUE)

  suppressWarnings(suppressMessages(lab_qc_backfill(s$db, actor = "052-lab-qc-backfill")))

  rep <- lq_db_get(s$db, "SELECT * FROM lab_qc_report")
  expect_setequal(rep$uuid_asset, c(a_qci, a_empty))
  expect_identical(rep$status[rep$uuid_asset == a_qci], "parsed")
  expect_identical(rep$status[rep$uuid_asset == a_empty], "unreadable")
  o1 <- lq_db_get(s$db, "SELECT uuid FROM lab_qc_outlier")
  expect_equal(nrow(o1), 5)

  # Second run: everything is current -> nothing re-parsed.
  suppressWarnings(suppressMessages(lab_qc_backfill(s$db, actor = "052-lab-qc-backfill")))
  expect_equal(nrow(lq_db_get(s$db, "SELECT * FROM lab_qc_report")), 2)
  expect_setequal(lq_db_get(s$db, "SELECT uuid FROM lab_qc_outlier")$uuid, o1$uuid)

  # A stale parser_version is re-parsed.
  con <- DBI::dbConnect(duckdb::duckdb(), s$db, read_only = FALSE)
  DBI::dbExecute(con, "UPDATE lab_qc_report SET parser_version = '0' WHERE uuid_asset = ?",
                 params = list(a_qci))
  DBI::dbDisconnect(con, shutdown = TRUE)
  suppressWarnings(suppressMessages(lab_qc_backfill(s$db, actor = "052-lab-qc-backfill")))
  o3 <- lq_db_get(s$db, "SELECT uuid FROM lab_qc_outlier")
  expect_equal(nrow(o3), 5)
  expect_length(intersect(o3$uuid, o1$uuid), 0)
  expect_false(any(lq_db_get(s$db, "SELECT parser_version FROM lab_qc_report")$parser_version == "0"))
})
