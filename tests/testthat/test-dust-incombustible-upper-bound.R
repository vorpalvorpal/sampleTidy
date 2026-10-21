# tests/testthat/test-dust-incombustible-upper-bound.R
#
# Migration 013's rule, applied by the ACIRL dust adapter at import time
# (2026-10-21 review, FIXES.md item D; value-conflict slice G09).
#
# Robin, 2026-10-16 (dev/migrations/013-dust-incombustible-upper-bound.R,
# dev/MIGRATIONS.md row 1013): ACIRL reports INSOLUBLE SOLIDS (dust-total),
# *COMBUSTIBLE MATTER and INCOMBUSTIBLE MATTER per gauge. Where combustible is a
# non-detect (`<0.1`) the lab computed incombustible = total - combustible with
# the combustible taken as its limit or as zero, so the printed figure is
# arithmetic on a non-detect, not a measurement. The most incombustible can be
# is the whole of the total. The rule, per gauge and month-block:
#
#   IF *COMBUSTIBLE MATTER is a non-detect (`<x`)
#   THEN INCOMBUSTIBLE MATTER := `< INSOLUBLE SOLIDS`
#        i.e. value = total, quantified FALSE, rl_low = total, rl_high NULL
#        (CONTRACT A57's shape for a `<x` row)
#   and nothing else moves: the total and the combustible are stored as
#   reported, and a gauge-block whose combustible is quantified is untouched.
#
# The live DB already holds the 4 samples in 013's shape; before this fix every
# re-import of their workbooks offered the printed figure back as a
# value_conflict (G09: 8 items, 2 workbook copies each). The workbook values
# below are the real G09 pairs: B.D07 Oct-Nov 2023 total 0.14 / combustible
# `<0.1` / incombustible printed 0.1; B.D08 Aug 2023 total 0.36 / printed 0.4
# (rounded ABOVE the total); B.D08 Feb 2025 total 0.2 / printed 0.2. The
# quantified control gauge is the real B.D07 July 2024 row.
#
# Workbooks are built at test time in a tempdir, in the real dust geometry
# (test-dust-dating.R: header row 10 on Dust Results, row 11 on Dust
# Observations, INCOMBUSTIBLE values one column right of their header).

iu_adapter <- function() {
  sampleTidy:::register_builtin_adapters()
  sampleTidy:::adapter_registry()[["acirl_field_xlsx"]]
}

iu_serial <- function(d) as.numeric(as.Date(d) - as.Date("1899-12-30"))

iu_set <- function(wb, sheet, row, col, value) {
  if (is.null(value) || length(value) == 0 || (length(value) == 1 && is.na(value))) {
    return(invisible(NULL))
  }
  openxlsx::writeData(wb, sheet, x = value, startRow = row, startCol = col,
                      colNames = FALSE, rowNames = FALSE)
}

# `gauges`: list(list(gauge, insoluble, combustible, incombustible)); a value
# may be numeric or text (`"<0.1"`). One month-block, with Observations.
iu_build <- function(dir, gauges, report_no = "2400-9921-11-02",
                     exposure = "2023-10-09", collection = "2023-11-07", days = 29,
                     filename = paste0(report_no, " November Monthly dust report Blaxland WMF.xlsx")) {
  wb <- openxlsx::createWorkbook()
  openxlsx::addWorksheet(wb, "Front Page")
  iu_set(wb, "Front Page", 1, 1, "ALS COAL DIVISION")
  iu_set(wb, "Front Page", 2, 1, "BMCC BLAXLAND WASTE MANAGEMENT FACILITY")
  iu_set(wb, "Front Page", 6, 2, "REPORT NO:");   iu_set(wb, "Front Page", 6, 3, report_no)
  iu_set(wb, "Front Page", 7, 2, "SAMPLED BY:");  iu_set(wb, "Front Page", 7, 3, "J. Tester")
  iu_set(wb, "Front Page", 8, 2, "SAMPLE DATE:"); iu_set(wb, "Front Page", 8, 3, "07/11/2023")

  s <- "Dust Results"
  openxlsx::addWorksheet(wb, s)
  iu_set(wb, s, 1, 1, "ALS COAL DIVISION")
  iu_set(wb, s, 3, 1, "MONTHLY ANALYSIS AND TESTING REPORT")
  iu_set(wb, s, 5, 6, "Report No."); iu_set(wb, s, 5, 7, report_no)
  iu_set(wb, s, 7, 4, "DUST DEPOSITION RESULTS")
  iu_set(wb, s, 8, 1, "(g/m²/month)")
  iu_set(wb, s, 10, 1, "GAUGE NO.")
  iu_set(wb, s, 10, 3, "Other Sample Id")
  iu_set(wb, s, 10, 4, "Month")
  iu_set(wb, s, 10, 6, "INSOLUBLE SOLIDS")
  iu_set(wb, s, 10, 9, "*COMBUSTIBLE MATTER")
  iu_set(wb, s, 10, 12, "INCOMBUSTIBLE MATTER")
  r <- 11L
  for (g in gauges) {
    iu_set(wb, s, r, 1, g$gauge)
    iu_set(wb, s, r, 4, iu_serial(exposure))
    iu_set(wb, s, r, 6, g$insoluble)
    iu_set(wb, s, r, 9, g$combustible)
    iu_set(wb, s, r, 13, g$incombustible)   # col 13, NOT 12 (real geometry)
    r <- r + 1L
  }
  iu_set(wb, s, r, 4, "Exposure Days")
  iu_set(wb, s, r, 6, days)
  iu_set(wb, s, r + 2L, 1, "Analysed in accordance with AS3580.10.1")

  s <- "Dust Observations"
  openxlsx::addWorksheet(wb, s)
  iu_set(wb, s, 1, 1, "ALS COAL DIVISION")
  iu_set(wb, s, 5, 5, "Report No."); iu_set(wb, s, 5, 7, report_no)
  iu_set(wb, s, 9, 1, "DEPOSITIONAL DUST GAUGE OBSERVATIONS")
  iu_set(wb, s, 11, 3, "GAUGE")
  iu_set(wb, s, 11, 4, "EXPOSURE DATE")
  iu_set(wb, s, 11, 5, "COLLECTION DATE")
  iu_set(wb, s, 11, 6, "DAYS EXPOSED")
  iu_set(wb, s, 11, 7, "ANALYSIS OBSERVATIONS")
  r <- 12L
  for (g in gauges) {
    iu_set(wb, s, r, 3, g$gauge)
    iu_set(wb, s, r, 4, iu_serial(exposure))
    iu_set(wb, s, r, 5, iu_serial(collection))
    iu_set(wb, s, r, 6, days)
    iu_set(wb, s, r, 7, "Clear, organic matter.")
    r <- r + 1L
  }
  openxlsx::addWorksheet(wb, "Dust Methodology ")
  iu_set(wb, "Dust Methodology ", 1, 1, "DUST METHODOLOGY")

  path <- file.path(dir, filename)
  openxlsx::saveWorkbook(wb, path, overwrite = TRUE)
  path
}

# B.D07: combustible non-detect (real G09 Nov-2023). B.D08: quantified control.
iu_gauges <- function() list(
  list(gauge = "B.D07", insoluble = 0.14, combustible = "<0.1", incombustible = 0.1),
  list(gauge = "B.D08", insoluble = 0.97, combustible = 0.37, incombustible = 0.6)
)

iu_parse <- function(path) iu_adapter()$parse(path, sampleTidy:::file_meta(path))

iu_row <- function(out, gauge, analyte) {
  r <- out$results
  r[r$feature_raw == gauge & r$analyte_raw == analyte, , drop = FALSE]
}

# ==============================================================================
# adapter
# ==============================================================================

test_that("013 rule: combustible `<0.1` -> incombustible is emitted as `< INSOLUBLE SOLIDS` (<0.14), not the printed 0.1", {
  out <- iu_parse(iu_build(withr::local_tempdir(), iu_gauges()))
  inc <- iu_row(out, "B.D07", "INCOMBUSTIBLE MATTER")
  expect_equal(nrow(inc), 1)
  expect_true(grepl("^<", inc$value_raw))
  expect_equal(inc$value_num, 0.14)
  expect_true(inc$below_detection)
  # value_raw re-parses (reconcile re-parses it) to the same `<0.14`
  pv <- sampleTidy:::parse_value(inc$value_raw)
  expect_equal(pv$value_num, 0.14)
  expect_no_error(sampleTidy:::ir_validate(out$results, "results"))
})

test_that("013 rule: the bound is the total even when the printed incombustible is ABOVE it (B.D08 Aug 2023: 0.36 / printed 0.4)", {
  g <- list(list(gauge = "B.D08", insoluble = 0.36, combustible = "<0.1", incombustible = 0.4))
  out <- iu_parse(iu_build(withr::local_tempdir(), g, report_no = "2400-9921-09",
                           exposure = "2023-08-01", collection = "2023-08-31", days = 30))
  inc <- iu_row(out, "B.D08", "INCOMBUSTIBLE MATTER")
  expect_equal(inc$value_num, 0.36)
  expect_true(inc$below_detection)
})

test_that("013 rule: printed incombustible EQUAL to the total (B.D08 Feb 2025: 0.2 / 0.2) still becomes the non-detect `<0.2`", {
  g <- list(list(gauge = "B.D08", insoluble = 0.2, combustible = "<0.1", incombustible = 0.2))
  out <- iu_parse(iu_build(withr::local_tempdir(), g, report_no = "2400-9923-03",
                           exposure = "2025-01-29", collection = "2025-02-28", days = 30))
  inc <- iu_row(out, "B.D08", "INCOMBUSTIBLE MATTER")
  expect_equal(inc$value_num, 0.2)
  expect_true(inc$below_detection)
  expect_true(grepl("^<", inc$value_raw))
})

test_that("013 rule: the total and the `<0.1` combustible themselves are emitted exactly as reported", {
  out <- iu_parse(iu_build(withr::local_tempdir(), iu_gauges()))
  tot <- iu_row(out, "B.D07", "INSOLUBLE SOLIDS")
  expect_identical(tot$value_raw, "0.14")
  expect_false(tot$below_detection)
  com <- iu_row(out, "B.D07", "*COMBUSTIBLE MATTER")
  expect_identical(com$value_raw, "<0.1")
  expect_true(com$below_detection)
  expect_equal(com$value_num, 0.1)
})

test_that("013 rule: a gauge whose combustible is QUANTIFIED keeps its printed incombustible (B.D08 0.97 / 0.37 / 0.6)", {
  out <- iu_parse(iu_build(withr::local_tempdir(), iu_gauges()))
  inc <- iu_row(out, "B.D08", "INCOMBUSTIBLE MATTER")
  expect_identical(inc$value_raw, "0.6")
  expect_equal(inc$value_num, 0.6)
  expect_false(inc$below_detection)
  expect_identical(iu_row(out, "B.D08", "INSOLUBLE SOLIDS")$value_raw, "0.97")
  expect_identical(iu_row(out, "B.D08", "*COMBUSTIBLE MATTER")$value_raw, "0.37")
  # and the row count is unchanged: 3 analytes x 2 gauges + 2 observations
  expect_equal(sum(out$results$analyte_raw != "ANALYSIS OBSERVATIONS"), 6)
})

test_that("013 rule: it is per gauge-block - a quarterly sheet's `<` month does not touch its other months", {
  dir <- withr::local_tempdir()
  # Two month-blocks on one Dust Results sheet; only block 2 has a `<` combustible.
  wb_path <- iu_build(dir, list(
    list(gauge = "B.D07", insoluble = 0.97, combustible = 0.37, incombustible = 0.6)))
  wb <- openxlsx::loadWorkbook(wb_path)
  s <- "Dust Results"
  # block 1 ends with `Exposure Days` at row 12; block 2 at rows 13-14
  iu_set(wb, s, 13, 1, "B.D07")
  iu_set(wb, s, 13, 4, iu_serial("2023-11-07"))
  iu_set(wb, s, 13, 6, 0.14)
  iu_set(wb, s, 13, 9, "<0.1")
  iu_set(wb, s, 13, 13, 0.1)
  iu_set(wb, s, 14, 4, "Exposure Days")
  iu_set(wb, s, 14, 6, 30)
  openxlsx::saveWorkbook(wb, wb_path, overwrite = TRUE)
  out <- iu_parse(wb_path)
  inc <- iu_row(out, "B.D07", "INCOMBUSTIBLE MATTER")
  expect_equal(nrow(inc), 2)
  b1 <- inc[grepl("!b1$", inc$lab_sample_id), ]
  b2 <- inc[grepl("!b2$", inc$lab_sample_id), ]
  expect_identical(b1$value_raw, "0.6")
  expect_false(b1$below_detection)
  expect_equal(b2$value_num, 0.14)
  expect_true(b2$below_detection)
})

# ==============================================================================
# end to end: stored in 013's shape, and a re-import onto the live 013 row
# raises no value_conflict (the G09 symptom: today it raises one per copy)
# ==============================================================================

iu_db_setup <- function(env = parent.frame()) {
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
  DBI::dbDisconnect(con, shutdown = TRUE)
  db_path
}

iu_analyses <- function(con, alias) {
  DBI::dbGetQuery(con, "SELECT a.uuid_lab, a.value, a.quantified, a.rl_low, a.rl_high
                          FROM analysis a JOIN \"sample\" s ON s.uuid = a.uuid_sample
                         WHERE s.uuid_feature_alias = ? ORDER BY a.uuid_lab", params = list(alias))
}

iu_ro <- function(db_path, env = parent.frame()) {
  con <- DBI::dbConnect(duckdb::duckdb(), db_path, read_only = TRUE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE), envir = env)
  con
}

test_that("013 rule end to end: incombustible commits as value = rl_low = total, quantified FALSE, rl_high NULL; the rest as reported", {
  db <- iu_db_setup()
  input <- withr::local_tempdir()
  iu_build(input, iu_gauges())
  ingest_dir(input, db = db)
  con <- iu_ro(db)

  a <- iu_analyses(con, "fa-d07")
  inc <- a[a$uuid_lab == "lm-dinc", ]
  expect_equal(nrow(inc), 1)
  expect_equal(inc$value, 0.14)
  expect_false(inc$quantified)
  expect_equal(inc$rl_low, 0.14)
  expect_true(is.na(inc$rl_high))
  tot <- a[a$uuid_lab == "lm-dins", ]
  expect_equal(tot$value, 0.14)
  expect_true(tot$quantified)
  com <- a[a$uuid_lab == "lm-dcom", ]
  expect_false(com$quantified)
  expect_equal(com$value, 0.1)

  # the quantified control gauge is stored as printed
  b <- iu_analyses(con, "fa-d08")
  expect_equal(b$value[b$uuid_lab == "lm-dinc"], 0.6)
  expect_true(b$quantified[b$uuid_lab == "lm-dinc"])
})

test_that("013 rule end to end (G09): re-importing onto a live row ALREADY in 013's shape raises no value_conflict", {
  db <- iu_db_setup()
  con <- seed_con(db)
  DBI::dbExecute(con, "INSERT INTO project (uuid, name, type) VALUES ('p-dust', 'Dust 2023', 'Dust monitoring')")
  # Live, as 013 left it: collection 7 Nov 2023 Sydney (= 6 Nov 13:00 UTC, AEDT),
  # exposure 9 Oct 2023 Sydney.
  DBI::dbExecute(con, "INSERT INTO \"sample\"
    (uuid, uuid_feature_alias, uuid_project, date, date_start, datetime, organisation) VALUES
    ('s-d07', 'fa-d07', 'p-dust', TIMESTAMP '2023-11-06 13:00:00', TIMESTAMP '2023-10-08 13:00:00', NULL, 'ACIRL')")
  DBI::dbExecute(con, "INSERT INTO analysis (uuid, uuid_sample, uuid_lab, value, quantified, rl_low) VALUES
    ('an-d07-ins', 's-d07', 'lm-dins', 0.14, TRUE,  NULL),
    ('an-d07-com', 's-d07', 'lm-dcom', 0.1,  FALSE, 0.1),
    ('an-d07-inc', 's-d07', 'lm-dinc', 0.14, FALSE, 0.14)")
  DBI::dbDisconnect(con, shutdown = TRUE)

  input <- withr::local_tempdir()
  iu_build(input, list(iu_gauges()[[1]]))
  ingest_dir(input, db = db)
  ro <- iu_ro(db)
  vc <- DBI::dbGetQuery(ro, "SELECT * FROM review_queue WHERE kind = 'value_conflict'")
  expect_equal(nrow(vc), 0)
  a <- iu_analyses(ro, "fa-d07")
  # the builder always writes a Dust Observations sheet; that text row is new
  # data (pending analyte), so count only the three dust analytes (2026-10-22)
  expect_equal(sum(a$uuid_lab %in% c("lm-dins", "lm-dcom", "lm-dinc")), 3)
  expect_equal(a$value[a$uuid_lab == "lm-dinc"], 0.14)
  expect_false(a$quantified[a$uuid_lab == "lm-dinc"])
})
