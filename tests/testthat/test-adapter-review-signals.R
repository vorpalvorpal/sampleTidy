# tests/testthat/test-adapter-review-signals.R
#
# Adapter -> review_queue: a path for "we don't trust this row" signals that
# an ADAPTER raises (Robin's ruling for A77, 2026-10-16: withhold + review).
#
# THE SEAM THESE TESTS TARGET (existing, half-wired):
#   CONTRACT A22/A56. `event$results` carries inline columns
#   `needs_review` (lgl), `review_kind` (chr), `review_payload` (list).
#   `reconcile_event()` STAGE-0 (R/reconcile.R ~l.2830) partitions
#   `needs_review == TRUE` rows out of `active` into `review` BEFORE QC, so
#   they never reach `clean` and never commit; `commit_event()` writes them
#   to `review_queue` (kind / subkind / JSON payload via `.rq_row()`).
#   The gap: assembly (R/assemble.R ~l.477) OVERWRITES those three columns
#   with its own foreign_work_order flags, and the IR has no slot for an
#   adapter to set them. The adapter's only outlets today are
#   `report$skipped` / `report$warnings`, which nothing downstream reads.
#
# CONTRACT THESE TESTS PIN (for the implementer):
#   C1 An adapter's `results` may carry `needs_review` / `review_kind` /
#      `review_payload` (A22's names). Assembly MERGES its own flags into
#      them (first-flag-wins, as `.st_flag_conflict()` already does) instead
#      of overwriting them.
#   C2 STAGE-0 folds flagged rows sharing (source_hash, review_kind,
#      review_payload) into ONE review item (n_rows = k). An adapter groups
#      rows into one item by giving them the identical payload - e.g. every
#      row of one A77 gauge-block, or every row of a gas file whose filename
#      and REPORT NO disagree.
#   C3 A77: kind = "date_conflict", subkind = "a77", one item per flagged
#      GAUGE-BLOCK; every row of that gauge-block (the three dust analytes AND
#      its ANALYSIS OBSERVATIONS row) is withheld.
#   C4 Idempotent: a re-run never opens a second OPEN item for the same
#      (kind, source_hash, gauge-block) - same dedupe shape as adapter_tie
#      (R/router.R ~l.305) and work_order_reingest (R/commit.R ~l.2082).
#   C5 NEW API (no existing function can do this - `resolve_review()` only
#      flips status): `release_review(uuid, overrides, resolved_by, db)`
#      commits the withheld rows with `overrides` applied (here
#      `date_start`/`date`), then resolves the item. See test R5.
#
# Workbook builder: a LOCAL copy of test-dust-dating.R's (each testthat file
# runs in its own environment, so its helpers are not visible here).

serial <- function(d) as.numeric(as.Date(d) - as.Date("1899-12-30"))

dd_set <- function(wb, sheet, row, col, value) {
  if (is.null(value) || length(value) == 0 || (length(value) == 1 && is.na(value))) {
    return(invisible(NULL))
  }
  openxlsx::writeData(wb, sheet, x = value, startRow = row, startCol = col,
                      colNames = FALSE, rowNames = FALSE)
}

# test-dust-dating.R's build_dust_workbook(), plus a per-gauge date override.
build_dust_workbook <- function(dir, report_no, blocks, observations = TRUE,
                                filename = paste0(report_no, "_Dust_WMF.xlsx")) {
  wb <- openxlsx::createWorkbook()

  openxlsx::addWorksheet(wb, "Front Page")
  dd_set(wb, "Front Page", 1, 1, "ALS COAL DIVISION")
  dd_set(wb, "Front Page", 2, 1, "BMCC TEST WASTE MANAGEMENT FACILITY")
  dd_set(wb, "Front Page", 6, 2, "REPORT NO:");   dd_set(wb, "Front Page", 6, 3, report_no)
  dd_set(wb, "Front Page", 7, 2, "SAMPLED BY:");  dd_set(wb, "Front Page", 7, 3, "J. Tester")
  dd_set(wb, "Front Page", 8, 2, "SAMPLE DATE:"); dd_set(wb, "Front Page", 8, 3, "01/08/2024")

  s <- "Dust Results"
  openxlsx::addWorksheet(wb, s)
  dd_set(wb, s, 1, 1, "ALS COAL DIVISION")
  dd_set(wb, s, 3, 1, "MONTHLY ANALYSIS AND TESTING REPORT")
  dd_set(wb, s, 5, 6, "Report No."); dd_set(wb, s, 5, 7, report_no)
  dd_set(wb, s, 7, 4, "DUST DEPOSITION RESULTS")
  dd_set(wb, s, 8, 1, "(g/m²/month)")
  dd_set(wb, s, 10, 1, "GAUGE NO.")
  dd_set(wb, s, 10, 3, "Other Sample Id")
  dd_set(wb, s, 10, 4, "Month")
  dd_set(wb, s, 10, 6, "INSOLUBLE SOLIDS")
  dd_set(wb, s, 10, 9, "*COMBUSTIBLE MATTER")
  dd_set(wb, s, 10, 12, "INCOMBUSTIBLE MATTER")
  r <- 11L
  for (b in blocks) {
    for (g in b$gauges) {
      dd_set(wb, s, r, 1, g$gauge)
      dd_set(wb, s, r, 4, b$month)
      dd_set(wb, s, r, 6, g$insoluble)
      dd_set(wb, s, r, 9, g$combustible)
      dd_set(wb, s, r, 13, g$incombustible)   # col 13, NOT 12 (real geometry)
      r <- r + 1L
    }
    dd_set(wb, s, r, 4, "Exposure Days")
    dd_set(wb, s, r, 6, b$days)
    r <- r + 1L
  }
  dd_set(wb, s, r + 1L, 1, "Analysed in accordance with AS3580.10.1")

  if (isTRUE(observations)) {
    s <- "Dust Observations"
    openxlsx::addWorksheet(wb, s)
    dd_set(wb, s, 1, 1, "ALS COAL DIVISION")
    dd_set(wb, s, 5, 5, "Report No."); dd_set(wb, s, 5, 7, report_no)
    dd_set(wb, s, 9, 1, "DEPOSITIONAL DUST GAUGE OBSERVATIONS")
    dd_set(wb, s, 11, 3, "GAUGE")
    dd_set(wb, s, 11, 4, "EXPOSURE DATE")
    dd_set(wb, s, 11, 5, "COLLECTION DATE")
    dd_set(wb, s, 11, 6, "DAYS EXPOSED")
    dd_set(wb, s, 11, 7, "ANALYSIS OBSERVATIONS")
    r <- 12L
    for (b in blocks) {
      for (g in b$gauges) {
        if (identical(g$obs, FALSE)) next
        dd_set(wb, s, r, 3, g$gauge)
        # Per-gauge override (this file's only change to the copied builder):
        # one gauge's Observations row can carry its own dates.
        expo <- if (is.null(g$exposure)) b$exposure else g$exposure
        coll <- if (is.null(g$collection)) b$collection else g$collection
        if (!is.na(expo)) dd_set(wb, s, r, 4, serial(expo))
        if (!is.na(coll)) dd_set(wb, s, r, 5, serial(coll))
        dd_set(wb, s, r, 6, b$days)
        dd_set(wb, s, r, 7, g$observation)
        r <- r + 1L
      }
    }
  }

  openxlsx::addWorksheet(wb, "Dust Methodology ")
  dd_set(wb, "Dust Methodology ", 1, 1, "DUST METHODOLOGY")

  path <- file.path(dir, filename)
  openxlsx::saveWorkbook(wb, path, overwrite = TRUE)
  path
}

# ---- scenario ---------------------------------------------------------------
#
# ONE month-block (August 2024), two gauges. Every gauge must appear in every
# block: the Observations parser numbers blocks by the nth sighting of a gauge,
# so a gauge missing from a block shifts its later blocks (verified - a
# one-gauge-per-block fixture silently fell back to Month dating and never
# reached the A77 check).
#
#   B.D08 - CLEAN gauge-block: Month 1 Aug 2024 == EXPOSURE 1 Aug 2024.
#   B.D07 - A77 gauge-block: its Observations row is a year stale (exposure
#           1 Aug 2023, collection 1 Sep 2023) - the 2400-7538-02 shape.

d08 <- function() list(gauge = "B.D08", insoluble = 1.09, combustible = 0.39,
                       incombustible = 0.7, observation = "Clear, organic matter.")
d07 <- function(exposure = "2023-08-01", collection = "2023-09-01") list(
  gauge = "B.D07", insoluble = 0.85, combustible = 0.31, incombustible = 0.54,
  observation = "Clear, insects.", exposure = exposure, collection = collection
)

# `month`: what the Results sheet's Month column says for the block.
a77_block <- function(month = serial("2024-08-01")) list(
  month = month, exposure = "2024-08-01", collection = "2024-09-01",
  days = 31, gauges = list(d07(), d08())
)
# Both gauges consistent (agreement control).
agree_block <- function(month = serial("2024-08-01")) list(
  month = month, exposure = "2024-08-01", collection = "2024-09-01",
  days = 31, gauges = list(d07(exposure = "2024-08-01", collection = "2024-09-01"), d08())
)

dust_analytes <- c("INSOLUBLE SOLIDS", "*COMBUSTIBLE MATTER", "INCOMBUSTIBLE MATTER")

# ---- DB fixture (test-dust-dating.R's dust_db_setup(legacy = FALSE)) --------

dust_db_setup <- function() {
  env <- parent.frame()
  db_path <- seed_db(dir = withr::local_tempdir(.local_envir = env))
  con <- seed_con(db_path)
  ensure_test_asset_table(con)
  withr::local_options(list(
    "sampletidy.archive_dir" = withr::local_tempdir(.local_envir = env),
    "sampletidy.snapshot_dir" = withr::local_tempdir(.local_envir = env),
    "sampletidy.remove_ingested" = FALSE
  ), .local_envir = env)

  DBI::dbExecute(con, "INSERT INTO feature (uuid, name, site, flow, matrix, date_end, lon, lat) VALUES
    ('f-d07', 'B.D07', 'B', NULL, 'dust', NULL, 150.31, -33.71),
    ('f-d08', 'B.D08', 'B', NULL, 'dust', NULL, 150.32, -33.72)")
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign, first_seen, last_seen, confirmed_by) VALUES
    ('fa-d07', 'f-d07', 'B.D07', 'b.d07', 'self', 0, TRUE,
     TIMESTAMP '2020-01-01 00:00:00', TIMESTAMP '2020-01-01 00:00:00', NULL),
    ('fa-d08', 'f-d08', 'B.D08', 'b.d08', 'self', 0, TRUE,
     TIMESTAMP '2020-01-01 00:00:00', TIMESTAMP '2020-01-01 00:00:00', NULL)")
  DBI::dbExecute(con, "INSERT INTO analyte (uuid, name, units, type, CAS) VALUES
    ('a-dins', 'Total Insoluble Solids', 'g/m2/month', 'dust', NULL),
    ('a-dcom', 'Combustible Matter', 'g/m2/month', 'dust', NULL),
    ('a-dinc', 'Incombustible Matter', 'g/m2/month', 'dust', NULL)")
  DBI::dbExecute(con, "INSERT INTO lab_method
    (uuid, uuid_analyte, name, method, organisation, rl_low, units, conversion_constant) VALUES
    ('lm-dins', 'a-dins', 'INSOLUBLE SOLIDS', NULL, 'ACIRL', NULL, 'g/m2/month', NULL),
    ('lm-dcom', 'a-dcom', '*COMBUSTIBLE MATTER', NULL, 'ACIRL', NULL, 'g/m2/month', NULL),
    ('lm-dinc', 'a-dinc', 'INCOMBUSTIBLE MATTER', NULL, 'ACIRL', NULL, 'g/m2/month', NULL)")
  DBI::dbExecute(con, "INSERT INTO project (uuid, name, type) VALUES
    ('p-dust', 'Dust 2024', 'Dust monitoring')")
  DBI::dbDisconnect(con, shutdown = TRUE)
  db_path
}

sydney_day <- function(x) as.character(as.Date(format(x, tz = "Australia/Sydney")))

ro_query <- function(db_path, sql, params = NULL) {
  con <- DBI::dbConnect(duckdb::duckdb(), db_path, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbGetQuery(con, sql, params = params)
}

# Committed analyses of one gauge's alias, with their lab_method name.
gauge_analyses <- function(db_path, alias) {
  ro_query(db_path, "SELECT s.uuid AS uuid_sample, s.date, s.date_start, lm.name AS method,
                            a.value
                       FROM analysis a
                       JOIN \"sample\" s ON s.uuid = a.uuid_sample
                       LEFT JOIN lab_method lm ON lm.uuid = a.uuid_lab
                      WHERE s.uuid_feature_alias = ?", params = list(alias))
}

gauge_samples <- function(db_path, alias) {
  ro_query(db_path, "SELECT uuid, date, date_start FROM \"sample\" WHERE uuid_feature_alias = ?",
           params = list(alias))
}

a77_reviews <- function(db_path, status = NULL) {
  sql <- "SELECT * FROM review_queue WHERE kind = 'date_conflict'"
  if (!is.null(status)) sql <- paste0(sql, " AND status = '", status, "'")
  ro_query(db_path, sql)
}

ingest_blocks <- function(db_path, blocks, report_no = "2400-7401-08", input = NULL, ...) {
  if (is.null(input)) input <- withr::local_tempdir(.local_envir = parent.frame())
  path <- build_dust_workbook(input, report_no, blocks, ...)
  suppressMessages(suppressWarnings(ingest_dir(input, db = db_path)))
  invisible(list(input = input, path = path, hash = hash_file(path)))
}

payload_of <- function(row) jsonlite::fromJSON(row$payload[[1]], simplifyVector = TRUE)

# ==============================================================================
# R1 - A77 end to end: withhold the flagged gauge-block, commit the clean one
# ==============================================================================

test_that("R1 (reachability): the adapter's existing A77 check DOES fire on this fixture, for B.D07 only", {
  # Guards every e2e test below: their failures must be the missing seam, not
  # a fixture that never reaches the cross-check (see the scenario note).
  register_builtin_adapters()
  dir <- withr::local_tempdir()
  path <- build_dust_workbook(dir, "2400-7401-08", list(a77_block()))
  out <- adapter_registry()[["acirl_field_xlsx"]]$parse(path, sampleTidy:::file_meta(path))
  hits <- out$report$skipped$source_ref[out$report$skipped$reason %in% "dust_exposure_date_conflict"]
  expect_length(hits, 3)   # the three B.D07 analyte cells
  expect_true(any(grepl("B.D07", out$report$warnings) & grepl("A77", out$report$warnings)))
  expect_false(any(grepl("B.D08", out$report$warnings) & grepl("A77", out$report$warnings)))
})

test_that("R1: the CLEAN gauge-block of a mixed dust workbook commits all three dust analytes", {
  db_path <- dust_db_setup()
  ingest_blocks(db_path, list(a77_block()))

  got <- gauge_analyses(db_path, "fa-d08")
  expect_setequal(intersect(got$method, dust_analytes), dust_analytes)
  expect_equal(sort(got$value[got$method %in% dust_analytes]), sort(c(1.09, 0.39, 0.7)))
})

test_that("R1: the A77-flagged gauge-block commits NOTHING - no sample, no analysis (incl. its observation row)", {
  db_path <- dust_db_setup()
  ingest_blocks(db_path, list(a77_block()))

  expect_equal(nrow(gauge_analyses(db_path, "fa-d07")), 0)
  expect_equal(nrow(gauge_samples(db_path, "fa-d07")), 0)
})

test_that("R1: exactly ONE open date_conflict/a77 review item is opened for the flagged gauge-block", {
  db_path <- dust_db_setup()
  f <- ingest_blocks(db_path, list(a77_block()))

  rq <- a77_reviews(db_path)
  expect_equal(nrow(rq), 1)
  if (nrow(rq) != 1) return(invisible())
  expect_identical(rq$subkind[[1]], "a77")
  expect_identical(rq$status[[1]], "open")
  expect_identical(rq$source_hash[[1]], f$hash)
  expect_identical(rq$work_order[[1]], "2400-7401-08")
})

test_that("R1: the review payload names the gauge, the file, all three dates, and the withheld analyses", {
  db_path <- dust_db_setup()
  f <- ingest_blocks(db_path, list(a77_block()))

  rq <- a77_reviews(db_path)
  expect_equal(nrow(rq), 1)
  if (nrow(rq) != 1) return(invisible())
  p <- payload_of(rq)

  expect_identical(p$gauge, "B.D07")
  expect_identical(p$file, basename(f$path))
  expect_true(length(p$source_ref) >= 1)
  # Dates as ISO strings: the Month as written resolves to 1 Aug 2024; the
  # Observations sheet's exposure/collection are the stale 2023 pair.
  expect_identical(p$month_date, "2024-08-01")
  expect_identical(p$exposure_date, "2023-08-01")
  expect_identical(p$collection_date, "2023-09-01")
  # The withheld analyses: one entry per withheld row, analyte + value.
  w <- as.data.frame(p$withheld)
  expect_true(all(c("analyte", "value") %in% names(w)))
  expect_setequal(intersect(w$analyte, dust_analytes), dust_analytes)
  vals <- stats::setNames(as.numeric(w$value[w$analyte %in% dust_analytes]),
                          w$analyte[w$analyte %in% dust_analytes])
  expect_equal(unname(vals[dust_analytes]), c(0.85, 0.31, 0.54))
  # n_rows counts every withheld row of the gauge-block: 3 analytes + observation.
  expect_equal(p$n_rows, 4)
})

test_that("R1: the file holding a withheld gauge-block is not reported as simply committed", {
  # Clean rows committed alongside open review items -> the review count on
  # the ingest report must include the A77 item.
  db_path <- dust_db_setup()
  input <- withr::local_tempdir()
  build_dust_workbook(input, "2400-7401-08", list(a77_block()))
  report <- suppressMessages(suppressWarnings(ingest_dir(input, db = db_path)))
  expect_gte(report$review_items_opened, 1)
  expect_equal(nrow(a77_reviews(db_path)), 1)
})

# ==============================================================================
# R2 - trigger coverage: numeric Month, text Month; agreement is silent
# ==============================================================================

test_that("R2: a TEXT Month that disagrees ('August 2024' vs a 2023 exposure) also withholds and queues", {
  db_path <- dust_db_setup()
  ingest_blocks(db_path, list(a77_block(month = "August 2024")))

  expect_equal(nrow(gauge_analyses(db_path, "fa-d07")), 0)
  rq <- a77_reviews(db_path)
  expect_equal(nrow(rq), 1)
  if (nrow(rq) != 1) return(invisible())
  p <- payload_of(rq)
  expect_identical(p$gauge, "B.D07")
  expect_identical(p$month_raw, "August 2024")
  expect_identical(p$exposure_date, "2023-08-01")
})

test_that("R2: a TEXT Month whose calendar month disagrees ('June') withholds and queues", {
  db_path <- dust_db_setup()
  # Both gauges' exposure is August; Month says June -> BOTH gauge-blocks flag.
  ingest_blocks(db_path, list(agree_block(month = "June")))

  expect_equal(nrow(gauge_analyses(db_path, "fa-d07")), 0)
  expect_equal(nrow(gauge_analyses(db_path, "fa-d08")), 0)
  rq <- a77_reviews(db_path)
  expect_equal(nrow(rq), 2)   # one per gauge-block, not one per file
  gauges <- vapply(seq_len(nrow(rq)), function(i) payload_of(rq[i, ])$gauge, "")
  expect_setequal(gauges, c("B.D07", "B.D08"))
})

test_that("R2: AGREEMENT (numeric and text Month) withholds nothing and opens no date_conflict item", {
  for (m in list(serial("2024-08-01"), "August", "Aug 2024")) {
    db_path <- dust_db_setup()
    ingest_blocks(db_path, list(agree_block(month = m)))
    expect_equal(nrow(a77_reviews(db_path)), 0, info = as.character(m))
    got <- gauge_analyses(db_path, "fa-d07")
    expect_setequal(intersect(got$method, dust_analytes), dust_analytes)
  }
})

# ==============================================================================
# R3 - idempotence
# ==============================================================================

test_that("R3: re-running the same directory opens no second date_conflict item", {
  db_path <- dust_db_setup()
  f <- ingest_blocks(db_path, list(a77_block()))
  expect_equal(nrow(a77_reviews(db_path)), 1)

  suppressMessages(suppressWarnings(ingest_dir(f$input, db = db_path)))
  expect_equal(nrow(a77_reviews(db_path)), 1)
  expect_equal(nrow(gauge_analyses(db_path, "fa-d07")), 0)
})

test_that("R3: a workbook whose ONLY gauge-block is flagged lands on needs_review, and a re-run (incl. reconsider) still has one item", {
  db_path <- dust_db_setup()
  # One block, one gauge (B.D07, stale Observations): every row is withheld.
  only_d07 <- list(month = serial("2024-08-01"), exposure = "2024-08-01",
                   collection = "2024-09-01", days = 31, gauges = list(d07()))
  f <- ingest_blocks(db_path, list(only_d07))
  expect_equal(nrow(a77_reviews(db_path)), 1)

  st <- ro_query(db_path, "SELECT state FROM ingest_file WHERE hash = ?", params = list(f$hash))
  expect_identical(st$state[[1]], "needs_review")

  suppressMessages(suppressWarnings(ingest_dir(f$input, db = db_path)))
  suppressMessages(suppressWarnings(ingest_dir(f$input, db = db_path, reconsider = TRUE)))
  expect_equal(nrow(a77_reviews(db_path, status = "open")), 1)
})

# ==============================================================================
# R4/R5 - resolution commits the withheld rows with the chosen date
# ==============================================================================
#
# NEW API, MARKED: `resolve_review()` (R/db-schema.R) only flips the row to
# 'resolved' - it has no way to commit anything. The smallest API that can:
#
#   release_review(uuid, overrides = list(date_start = , date = ),
#                  resolved_by, db = st_config("live_db"))
#
# commits the review item's withheld rows with `overrides` applied to the
# sample fields, then resolves the item (actor = resolved_by), in ONE
# transaction. Being a new export, CONTRACT's pinned public-API block
# (R-10.6) must gain it.

test_that("R5 [NEW API release_review()]: releasing with a chosen date commits the withheld analyses with that date_start", {
  has_api <- exists("release_review", envir = asNamespace("sampleTidy"), inherits = FALSE)
  expect_true(has_api, label = "release_review() exists")
  if (!has_api) return(invisible())
  db_path <- dust_db_setup()
  ingest_blocks(db_path, list(a77_block()))
  rq <- a77_reviews(db_path, status = "open")
  expect_equal(nrow(rq), 1)

  # The human rules the Month right and the Observations sheet stale.
  sampleTidy::release_review(
    rq$uuid[[1]],
    overrides = list(date_start = as.Date("2024-08-01"), date = as.Date("2024-09-01")),
    resolved_by = "robin", db = db_path
  )

  got <- gauge_analyses(db_path, "fa-d07")
  dust <- got[got$method %in% dust_analytes, ]
  expect_setequal(dust$method, dust_analytes)
  expect_equal(unname(stats::setNames(dust$value, dust$method)[dust_analytes]), c(0.85, 0.31, 0.54))
  s <- gauge_samples(db_path, "fa-d07")
  expect_equal(nrow(s), 1)
  expect_identical(sydney_day(s$date_start), "2024-08-01")
  expect_identical(sydney_day(s$date), "2024-09-01")

  after <- a77_reviews(db_path)
  expect_identical(after$status[[1]], "resolved")
  expect_identical(after$resolved_by[[1]], "robin")
})

test_that("R5 [NEW API release_review()]: releasing twice commits the rows once", {
  has_api <- exists("release_review", envir = asNamespace("sampleTidy"), inherits = FALSE)
  expect_true(has_api, label = "release_review() exists")
  if (!has_api) return(invisible())
  db_path <- dust_db_setup()
  ingest_blocks(db_path, list(a77_block()))
  rq <- a77_reviews(db_path, status = "open")
  ov <- list(date_start = as.Date("2024-08-01"), date = as.Date("2024-09-01"))
  sampleTidy::release_review(rq$uuid[[1]], overrides = ov, resolved_by = "robin", db = db_path)
  sampleTidy::release_review(rq$uuid[[1]], overrides = ov, resolved_by = "robin", db = db_path)
  expect_equal(nrow(gauge_samples(db_path, "fa-d07")), 1)
  got <- gauge_analyses(db_path, "fa-d07")
  expect_equal(sum(got$method %in% dust_analytes), 3)
})

test_that("R4: release_review() is an exported function (the resolve path for withheld rows)", {
  # The R5 tests also fail on this, before they can reach the DB.
  expect_true("release_review" %in% getNamespaceExports("sampleTidy"))
})

# ==============================================================================
# R6 - the generic adapter contract (what the ACIRL gas adapter will use)
# ==============================================================================

signal_adapter_id <- "t_review_signal"

# A minimal adapter: one dust-shaped result row per gauge, all on one
# 1-Aug-2024 sample each. `flag` (per row) decides needs_review; `payloads`
# supplies each flagged row's review_payload.
register_signal_adapter <- function(env, flag, kind = "test_signal", payloads = NULL) {
  register_adapter(list(
    id = signal_adapter_id, version = "1.0",
    match = function(fm) if (grepl("REVIEWSIGNAL", fm$filename)) "exact" else "no",
    parse = function(path, file_meta) {
      n <- length(flag)
      gauges <- rep(c("B.D07", "B.D08"), length.out = n)
      res <- ir_results(
        source_hash = rep(file_meta$hash, n), source_ref = sprintf("row%d", seq_len(n)),
        work_order = rep("SIG-0001", n), revision = rep(0L, n), org = rep("ACIRL", n),
        adapter = rep("t_review_signal/1.0", n), lab_sample_id = gauges,
        sample_type = rep("Normal", n), feature_raw = gauges,
        analyte_raw = rep("INSOLUBLE SOLIDS", n), cas_number = rep(NA_character_, n),
        method_raw = rep(NA_character_, n), total_or_filtered = rep(NA_character_, n),
        units_raw = rep("g/m2/month", n), value_raw = sprintf("%.2f", seq_len(n) / 10),
        value_num = seq_len(n) / 10, value_chr = rep(NA_character_, n),
        below_detection = rep(FALSE, n), rl = rep(NA_real_, n),
        lab_qualifier = rep(NA_character_, n), analysed_date = rep(as.Date(NA), n),
        comments = rep(NA_character_, n), confidence = rep(1, n)
      )
      res$needs_review <- flag
      res$review_kind <- ifelse(flag, kind, NA_character_)
      res$review_payload <- if (is.null(payloads)) vector("list", n) else payloads
      ug <- unique(gauges)
      smp <- ir_samples(
        source_hash = rep(file_meta$hash, length(ug)), source_ref = ug,
        work_order = rep("SIG-0001", length(ug)), org = rep("ACIRL", length(ug)),
        adapter = rep("t_review_signal/1.0", length(ug)), lab_sample_id = ug,
        feature_raw = ug, sample_datetime_raw = rep("01/08/2024", length(ug)),
        sample_date_start_raw = rep(NA_character_, length(ug)),
        sample_type = rep("Normal", length(ug)), parent_sample = rep(NA_character_, length(ug)),
        matrix_raw = rep("Dust", length(ug)), sampler = rep(NA_character_, length(ug)),
        comments = rep(NA_character_, length(ug)), confidence = rep(1, length(ug))
      )
      list(results = res, samples = smp,
           report = list(n_rows = n, skipped = tibble::tibble(source_ref = character(),
                                                              reason = character()),
                         warnings = character()))
    }
  ))
  withr::defer({
    if (exists(signal_adapter_id, envir = sampleTidy:::.st_adapter_registry, inherits = FALSE)) {
      rm(list = signal_adapter_id, envir = sampleTidy:::.st_adapter_registry)
    }
  }, envir = env)
}

ingest_signal_file <- function(db_path, env = parent.frame()) {
  input <- withr::local_tempdir(.local_envir = env)
  p <- st_test_write_file(input, "SIG-0001_REVIEWSIGNAL_0.csv", content = "x\n1\n")
  suppressMessages(suppressWarnings(ingest_dir(input, db = db_path)))
  hash_file(p)
}

test_that("R6: an adapter row flagged needs_review is withheld; its unflagged sibling commits", {
  db_path <- dust_db_setup()
  register_signal_adapter(environment(), flag = c(TRUE, FALSE),
                          payloads = list(list(subkind = "probe", reason = "too many dp"), NULL))
  ingest_signal_file(db_path)

  # Reachability guard: the clean row (B.D08) DOES commit, so the adapter,
  # registry and work order all resolve - the flagged row's absence below is
  # the flag's doing, not a fixture failure.
  expect_equal(nrow(gauge_analyses(db_path, "fa-d08")), 1)
  expect_equal(nrow(gauge_analyses(db_path, "fa-d07")), 0)
})

test_that("R6: the flagged row opens one review item carrying the adapter's kind, subkind and payload", {
  db_path <- dust_db_setup()
  register_signal_adapter(environment(), flag = c(TRUE, FALSE),
                          payloads = list(list(subkind = "probe", reason = "too many dp"), NULL))
  h <- ingest_signal_file(db_path)

  rq <- ro_query(db_path, "SELECT * FROM review_queue WHERE kind = 'test_signal'")
  expect_equal(nrow(rq), 1)
  if (nrow(rq) != 1) return(invisible())
  expect_identical(rq$subkind[[1]], "probe")
  expect_identical(rq$source_hash[[1]], h)
  p <- payload_of(rq)
  expect_identical(p$reason, "too many dp")
  expect_false("kind" %in% names(p))     # typed column, not duplicated in JSON
  expect_false("subkind" %in% names(p))
})

test_that("R6: flagged rows sharing an identical (kind, payload) fold into ONE review item with n_rows = k", {
  # The gas adapter's filename/REPORT NO mismatch flags EVERY row of a file;
  # one question for the human, not one per row.
  db_path <- dust_db_setup()
  shared <- list(subkind = "report_no_mismatch", filename_report = "A", sheet_report = "B")
  register_signal_adapter(environment(), flag = c(TRUE, TRUE, TRUE, TRUE),
                          payloads = rep(list(shared), 4))
  ingest_signal_file(db_path)

  rq <- ro_query(db_path, "SELECT * FROM review_queue WHERE kind = 'test_signal'")
  expect_equal(nrow(rq), 1)
  if (nrow(rq) != 1) return(invisible())
  expect_equal(payload_of(rq)$n_rows, 4)
  expect_equal(nrow(gauge_analyses(db_path, "fa-d07")) + nrow(gauge_analyses(db_path, "fa-d08")), 0)
})

test_that("R6: an adapter output whose flags are all FALSE still commits everything (control)", {
  db_path <- dust_db_setup()
  register_signal_adapter(environment(), flag = c(FALSE, FALSE))
  ingest_signal_file(db_path)
  expect_equal(nrow(gauge_analyses(db_path, "fa-d07")), 1)
  expect_equal(nrow(gauge_analyses(db_path, "fa-d08")), 1)
  expect_equal(nrow(ro_query(db_path, "SELECT * FROM review_queue WHERE kind = 'test_signal'")), 0)
})
