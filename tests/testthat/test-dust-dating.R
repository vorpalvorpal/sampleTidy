# tests/testthat/test-dust-dating.R
#
# Dust-gauge sample dating (Robin's ruling, 2026-10-16):
#
#   EXPOSURE date   (gauge put out)   -> `sample.date_start`
#   COLLECTION date (gauge brought in) -> `sample.date`
#
# The defect these tests pin: the ACIRL dust adapter dated each sample by its
# EXPOSURE date (`samp_date <- if (!is.na(exp_d)) exp_d else month_d`), parsed
# and then DISCARDED the collection date, and nothing ever wrote
# `sample.date_start`. Live consequence: the July-2024 gauge sample (exposure
# 2024-07-01, collection 2024-08-01) was dated 2024-07-01, which is the day
# `CAST(date AS DATE)` reads back from the LEGACY June sample (stored
# `2024-07-01 14:00:00` UTC = midnight 2 July Australia/Sydney) - so July's
# values were compared against June's and raised 6 false value_conflicts.
#
#   S1  adapter: sample_datetime_raw = COLLECTION, sample_date_start_raw = EXPOSURE
#   S2  commit:  sample.date_start written from the start-date field, NULL if absent
#   S3  A77 cross-check also works for a TEXT `Month` ("July", "Jul", "July 2024")
#   S4  identity matching compares the Australia/Sydney calendar date (A44)
#
# Values are the real B.D07/B.D08 June and July 2024 readings. The August
# block's VALUES are synthetic (its dates mirror the real legacy row); only
# its dates matter to the tests that use it.
#
# Every workbook is built at test time in a tempdir, reproducing the real
# dust geometry of fixtures/acirl/generate-real-geometry.R (header row 10 on
# Dust Results, row 11 on Dust Observations, INCOMBUSTIBLE values one column
# right of their header).

acirl_adapter <- function() sampleTidy:::adapter_registry()[["acirl_field_xlsx"]]

serial <- function(d) as.numeric(as.Date(d) - as.Date("1899-12-30"))

# ---- workbook builder --------------------------------------------------------

dd_set <- function(wb, sheet, row, col, value) {
  if (is.null(value) || length(value) == 0 || (length(value) == 1 && is.na(value))) {
    return(invisible(NULL))
  }
  openxlsx::writeData(wb, sheet, x = value, startRow = row, startCol = col,
                      colNames = FALSE, rowNames = FALSE)
}

# `blocks`: list of list(month = <serial or text>, exposure = "YYYY-MM-DD"|NA,
#   collection = "YYYY-MM-DD"|NA, days = <num>|NA, gauges = list(list(gauge,
#   insoluble, combustible, incombustible, observation, obs = TRUE)))
# `obs = FALSE` on a gauge leaves it OUT of the Observations sheet.
# `observations = FALSE` omits the Observations sheet entirely.
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
        if (!is.na(b$exposure))   dd_set(wb, s, r, 4, serial(b$exposure))
        if (!is.na(b$collection)) dd_set(wb, s, r, 5, serial(b$collection))
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

# Real July-2024 readings (the block that raised the 6 false conflicts).
july_gauges <- function() list(
  list(gauge = "B.D07", insoluble = 0.97, combustible = 0.37, incombustible = 0.6,
       observation = "Clear, insects, organic matter."),
  list(gauge = "B.D08", insoluble = 1.09, combustible = 0.39, incombustible = 0.7,
       observation = "Clear, organic matter.")
)
# Synthetic August values (dates are the real legacy row's).
aug_gauges <- function() list(
  list(gauge = "B.D07", insoluble = 0.85, combustible = 0.31, incombustible = 0.54,
       observation = "Clear, organic matter."),
  list(gauge = "B.D08", insoluble = 0.62, combustible = 0.22, incombustible = 0.40,
       observation = "Clear, insects.")
)

july_block <- function(month = serial("2024-07-01"), exposure = "2024-07-01",
                       collection = "2024-08-01", days = 31, gauges = july_gauges()) {
  list(month = month, exposure = exposure, collection = collection, days = days,
       gauges = gauges)
}

parse_dust <- function(path) {
  register_builtin_adapters()
  acirl_adapter()$parse(path, sampleTidy:::file_meta(path))
}

dust_samples_of <- function(out) out$samples[out$samples$matrix_raw %in% "Dust", ]

conflict_fired <- function(out) {
  any(out$report$skipped$reason %in% "dust_exposure_date_conflict")
}

# ==============================================================================
# S1 - adapter output: date = COLLECTION, date_start = EXPOSURE
# ==============================================================================

test_that("S1: a dust sample is dated by its COLLECTION date, and carries its EXPOSURE date as the start", {
  dir <- withr::local_tempdir()
  out <- parse_dust(build_dust_workbook(dir, "2400-7401-07", list(july_block())))
  ds <- dust_samples_of(out)
  expect_equal(nrow(ds), 2)
  expect_true("sample_date_start_raw" %in% names(ds))
  # Same dd/mm/yyyy convention the adapter already uses for sample_datetime_raw.
  expect_identical(unique(ds$sample_datetime_raw), "01/08/2024")
  expect_identical(unique(ds$sample_date_start_raw), "01/07/2024")
})

test_that("S1: the dated samples still pass the IR samples contract (the new column is declared)", {
  dir <- withr::local_tempdir()
  out <- parse_dust(build_dust_workbook(dir, "2400-7401-07", list(july_block())))
  expect_true("sample_date_start_raw" %in% names(sampleTidy:::ir_samples()))
  expect_no_error(sampleTidy:::ir_validate(out$samples, "samples"))
})

test_that("S1: a quarterly sheet dates EACH month-block by its own collection/exposure pair", {
  dir <- withr::local_tempdir()
  blocks <- list(
    july_block(),
    list(month = serial("2024-08-01"), exposure = "2024-08-01",
         collection = "2024-09-01", days = 31, gauges = aug_gauges())
  )
  out <- parse_dust(build_dust_workbook(dir, "2400-7401-08", blocks))
  ds <- dust_samples_of(out)
  expect_equal(nrow(ds), 4)
  b1 <- ds[grepl("!b1$", ds$lab_sample_id), ]
  b2 <- ds[grepl("!b2$", ds$lab_sample_id), ]
  expect_identical(unique(b1$sample_datetime_raw), "01/08/2024")
  expect_identical(unique(b1$sample_date_start_raw), "01/07/2024")
  expect_identical(unique(b2$sample_datetime_raw), "01/09/2024")
  expect_identical(unique(b2$sample_date_start_raw), "01/08/2024")
})

test_that("S1 fallback: with NO Observations sheet, date_start = 1st of Month and date = 1st of the following month", {
  dir <- withr::local_tempdir()
  out <- parse_dust(build_dust_workbook(dir, "2400-7401-07", list(july_block()),
                                        observations = FALSE))
  ds <- dust_samples_of(out)
  expect_equal(nrow(ds), 2)
  expect_identical(unique(ds$sample_date_start_raw), "01/07/2024")
  expect_identical(unique(ds$sample_datetime_raw), "01/08/2024")
})

test_that("S1 fallback: a gauge MISSING from an otherwise-present Observations sheet falls back to Month too", {
  dir <- withr::local_tempdir()
  g <- july_gauges()
  g[[2]]$obs <- FALSE                     # B.D08 has no Observations row
  out <- parse_dust(build_dust_workbook(dir, "2400-7401-07", list(july_block(gauges = g))))
  ds <- dust_samples_of(out)
  d08 <- ds[ds$feature_raw == "B.D08", ]
  d07 <- ds[ds$feature_raw == "B.D07", ]
  expect_equal(nrow(d08), 1)
  expect_identical(d08$sample_date_start_raw, "01/07/2024")
  expect_identical(d08$sample_datetime_raw, "01/08/2024")
  # Reachability: the gauge WITH observations is still dated from them.
  expect_identical(d07$sample_date_start_raw, "01/07/2024")
  expect_identical(d07$sample_datetime_raw, "01/08/2024")
})

test_that("S1 fallback: Month mid-month still falls back to the FIRST of that month and the first of the next", {
  dir <- withr::local_tempdir()
  out <- parse_dust(build_dust_workbook(
    dir, "2400-7401-07", list(july_block(month = serial("2024-07-15"))),
    observations = FALSE))
  ds <- dust_samples_of(out)
  expect_identical(unique(ds$sample_date_start_raw), "01/07/2024")
  expect_identical(unique(ds$sample_datetime_raw), "01/08/2024")
})

test_that("S1: exposure present, collection MISSING, DAYS present -> date = exposure + days", {
  dir <- withr::local_tempdir()
  # 2024-07-03 + 30 days = 2024-08-02: distinct from every Month-derived
  # fallback, so only the exposure+days arm can produce it.
  blk <- july_block(exposure = "2024-07-03", collection = NA, days = 30,
                    month = serial("2024-07-01"))
  out <- parse_dust(build_dust_workbook(dir, "2400-7401-07", list(blk)))
  ds <- dust_samples_of(out)
  expect_identical(unique(ds$sample_date_start_raw), "03/07/2024")
  expect_identical(unique(ds$sample_datetime_raw), "02/08/2024")
})

test_that("S1: ACIRL WATER samples carry the start-date column, all NA", {
  path <- test_path("fixtures", "acirl", "2400-9999-11_Real_WMF.xlsx")
  out <- parse_dust(path)
  water <- out$samples[out$samples$matrix_raw %in% "Water", ]
  expect_gt(nrow(water), 0)
  expect_true("sample_date_start_raw" %in% names(water))
  expect_true(all(is.na(water$sample_date_start_raw)))
  # and their own dates are untouched (R-6.3a pin)
  expect_setequal(unique(water$sample_datetime_raw), c("24/05/2025", "25/05/2025"))
})

test_that("S1: ESdat and crosstab samples carry the start-date column, all NA", {
  register_builtin_adapters()
  reg <- sampleTidy:::adapter_registry()
  cases <- list(
    list(ad = "esdat", path = test_path("fixtures", "esdat", "PROJ_A.ESDAT_XX1234567_0.Sample2e.CSV")),
    list(ad = "als_xtab", path = test_path("fixtures", "crosstab", "ES2600185_0_XTAB.csv"))
  )
  for (cs in cases) {
    expect_true(cs$ad %in% names(reg), info = cs$ad)
    out <- reg[[cs$ad]]$parse(cs$path, sampleTidy:::file_meta(cs$path))
    expect_gt(nrow(out$samples), 0)
    expect_true("sample_date_start_raw" %in% names(out$samples), info = cs$ad)
    expect_true(all(is.na(out$samples$sample_date_start_raw)), info = cs$ad)
  }
})

# ==============================================================================
# S3 - A77 cross-check with a TEXT `Month`
# ==============================================================================
#
# Today `serial_date()` returns NA for "July", so `!is.na(month_d)` is FALSE
# and the A77 check silently never runs. Agreement = same calendar month (and
# same year when the text carries one; the exposure date supplies the year
# when it does not).

test_that("S3: a TEXT Month that DISAGREES with the exposure date routes to review, exactly as the numeric case does", {
  dir <- withr::local_tempdir()
  out <- parse_dust(build_dust_workbook(dir, "2400-7401-07",
                                        list(july_block(month = "June"))))
  expect_true(conflict_fired(out))
  expect_true(any(grepl("A77", out$report$warnings)))
  # surfaced, never silently dropped (A77): the rows are still emitted
  expect_equal(nrow(dust_samples_of(out)), 2)
})

test_that("S3: a TEXT Month with a year that disagrees with the exposure YEAR routes to review (the stale-Observations case)", {
  # 2400-7538-02: the Observations sheet was two years stale while Month was right.
  dir <- withr::local_tempdir()
  out <- parse_dust(build_dust_workbook(dir, "2400-7401-07",
                                        list(july_block(month = "July 2022"))))
  expect_true(conflict_fired(out))
})

test_that("S3: abbreviated text Month that disagrees ('Jun') routes to review too", {
  dir <- withr::local_tempdir()
  out <- parse_dust(build_dust_workbook(dir, "2400-7401-07",
                                        list(july_block(month = "Jun"))))
  expect_true(conflict_fired(out))
})

test_that("S3: TEXT Months that AGREE with the exposure date raise nothing", {
  # Reachability guard for the three tests above: without it they could pass
  # merely because a text Month always conflicts.
  for (m in c("July", "Jul", "July 2024", "JULY")) {
    dir <- withr::local_tempdir()
    out <- parse_dust(build_dust_workbook(dir, "2400-7401-07",
                                          list(july_block(month = m))))
    expect_false(conflict_fired(out), info = m)
  }
})

test_that("S3: the NUMERIC cross-check is unchanged - agreement silent, disagreement routed", {
  dir <- withr::local_tempdir()
  agree <- parse_dust(build_dust_workbook(dir, "2400-7401-07", list(july_block())))
  expect_false(conflict_fired(agree))
  dir2 <- withr::local_tempdir()
  # Month holds the COLLECTION date - the 2400-7453-06 error
  disagree <- parse_dust(build_dust_workbook(
    dir2, "2400-7401-07", list(july_block(month = serial("2024-08-01")))))
  expect_true(conflict_fired(disagree))
})

test_that("S3 + S1: a text Month WITH a year, and no Observations sheet, still dates the sample from Month", {
  dir <- withr::local_tempdir()
  out <- parse_dust(build_dust_workbook(dir, "2400-7401-07",
                                        list(july_block(month = "July 2024")),
                                        observations = FALSE))
  ds <- dust_samples_of(out)
  expect_identical(unique(ds$sample_date_start_raw), "01/07/2024")
  expect_identical(unique(ds$sample_datetime_raw), "01/08/2024")
})

# ==============================================================================
# DB fixtures for S2 / S4: the B.D07/B.D08 dust registry + legacy samples
# ==============================================================================
#
# The live `sample.date`/`date_start` columns are TIMESTAMP holding the UTC
# instant (legacy rows: Australia/Sydney midnight = 14:00 UTC the previous day;
# pipeline rows: naive midnight, A44.3). The seed schema has the same types.

dust_db_setup <- function(legacy = TRUE) {
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

  if (isTRUE(legacy)) {
    # LEGACY June 2024: exposure 1 Jun -> collection 2 Jul (Sydney); stored as
    # Sydney midnight in UTC. `CAST(date AS DATE)` reads 2024-07-01 - the day
    # the buggy adapter gave the JULY sample.
    # LEGACY August 2024: 1 Aug -> 1 Sep Sydney.
    DBI::dbExecute(con, "INSERT INTO \"sample\"
      (uuid, uuid_feature_alias, uuid_project, date, date_start, datetime, organisation) VALUES
      ('s-jun-d07', 'fa-d07', 'p-dust', TIMESTAMP '2024-07-01 14:00:00', TIMESTAMP '2024-05-31 14:00:00', NULL, 'ACIRL'),
      ('s-jun-d08', 'fa-d08', 'p-dust', TIMESTAMP '2024-07-01 14:00:00', TIMESTAMP '2024-05-31 14:00:00', NULL, 'ACIRL'),
      ('s-aug-d07', 'fa-d07', 'p-dust', TIMESTAMP '2024-08-31 14:00:00', TIMESTAMP '2024-07-31 14:00:00', NULL, 'ACIRL'),
      ('s-aug-d08', 'fa-d08', 'p-dust', TIMESTAMP '2024-08-31 14:00:00', TIMESTAMP '2024-07-31 14:00:00', NULL, 'ACIRL')")
    DBI::dbExecute(con, "INSERT INTO analysis
      (uuid, uuid_sample, uuid_lab, value, quantified, rl_low) VALUES
      ('an-jun-d07-ins', 's-jun-d07', 'lm-dins', 1.53, TRUE, NULL),
      ('an-jun-d07-com', 's-jun-d07', 'lm-dcom', 0.33, TRUE, NULL),
      ('an-jun-d07-inc', 's-jun-d07', 'lm-dinc', 1.2,  TRUE, NULL),
      ('an-jun-d08-ins', 's-jun-d08', 'lm-dins', 0.57, TRUE, NULL),
      ('an-jun-d08-com', 's-jun-d08', 'lm-dcom', 0.27, TRUE, NULL),
      ('an-jun-d08-inc', 's-jun-d08', 'lm-dinc', 0.30, TRUE, NULL),
      ('an-aug-d07-ins', 's-aug-d07', 'lm-dins', 0.85, TRUE, NULL),
      ('an-aug-d07-com', 's-aug-d07', 'lm-dcom', 0.31, TRUE, NULL),
      ('an-aug-d07-inc', 's-aug-d07', 'lm-dinc', 0.54, TRUE, NULL),
      ('an-aug-d08-ins', 's-aug-d08', 'lm-dins', 0.62, TRUE, NULL),
      ('an-aug-d08-com', 's-aug-d08', 'lm-dcom', 0.22, TRUE, NULL),
      ('an-aug-d08-inc', 's-aug-d08', 'lm-dinc', 0.40, TRUE, NULL)")
  }
  DBI::dbDisconnect(con, shutdown = TRUE)
  db_path
}

# Sydney calendar day of a stored instant (the driver returns TIMESTAMP as UTC).
sydney_day <- function(x) as.character(as.Date(format(x, tz = "Australia/Sydney")))

ro_con <- function(db_path, env = parent.frame()) {
  con <- DBI::dbConnect(duckdb::duckdb(), db_path, read_only = TRUE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE), envir = env)
  con
}

gauge_samples <- function(con, alias) {
  DBI::dbGetQuery(con, "SELECT uuid, date, date_start FROM \"sample\"
                          WHERE uuid_feature_alias = ? ORDER BY uuid", params = list(alias))
}

dust_value_conflicts <- function(con) {
  DBI::dbGetQuery(con, "SELECT * FROM review_queue WHERE kind = 'value_conflict'")
}

ingest_workbook <- function(db_path, report_no, blocks, ...) {
  input <- withr::local_tempdir(.local_envir = parent.frame())
  build_dust_workbook(input, report_no, blocks, ...)
  ingest_dir(input, db = db_path)
}

# ==============================================================================
# S2 - commit writes sample.date_start
# ==============================================================================

test_that("S2: a dust workbook ingested end to end stores date = COLLECTION and date_start = EXPOSURE", {
  db_path <- dust_db_setup(legacy = FALSE)
  ingest_workbook(db_path, "2400-7401-07", list(july_block()))

  con <- ro_con(db_path)
  for (alias in c("fa-d07", "fa-d08")) {
    s <- gauge_samples(con, alias)
    expect_equal(nrow(s), 1, info = alias)
    expect_identical(sydney_day(s$date), "2024-08-01", info = alias)
    expect_false(is.na(s$date_start), info = alias)
    expect_identical(sydney_day(s$date_start), "2024-07-01", info = alias)
  }
})

# The pipeline-level `clean` row shape, as test-commit.R builds it.
s2_commit_setup <- function() {
  env <- parent.frame()
  db_path <- seed_db(dir = withr::local_tempdir(.local_envir = env))
  con <- seed_con(db_path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE), envir = env)
  ensure_test_asset_table(con)
  withr::local_options(list("sampletidy.archive_dir" = withr::local_tempdir(.local_envir = env)),
                       .local_envir = env)
  src <- file.path(withr::local_tempdir(.local_envir = env),
                   "PROJ_A.ESDAT_XX1234567_0.Chemistry2e.CSV")
  writeLines("SampleCode,ChemCode", src)
  hash <- hash_file(src)
  DBI::dbExecute(con, sprintf(
    "INSERT INTO ingest_file (hash, filename, path_first_seen, state, work_order, revision)
     VALUES ('%s', '%s', '%s', 'reconciled', 'XX1234567', 0)", hash, basename(src), src))
  files <- tibble::tibble(hash = hash, filename = basename(src), adapter = "esdat/1",
                          rank = 3L, kept = TRUE)
  event <- list(
    work_order = "XX1234567", orphan = FALSE, results = tibble::tibble(),
    samples = tibble::tibble(), files = files,
    report = list(n_results = 0L, n_by_sample_type = list(), n_ncp_foreign = 0L,
                  skipped = tibble::tibble(hash = character(), source_ref = character(),
                                           reason = character()),
                  warnings = character()))
  list(con = con, hash = hash, event = event)
}

s2_clean_row <- function(hash, ...) {
  defaults <- list(
    source_hash = hash, source_ref = "row1", work_order = "XX1234567", revision = 0L,
    org = "ALS", adapter = "esdat/1", lab_sample_id = "XX1234567099", sample_type = "Normal",
    feature_raw = "T.S01", analyte_raw = "pH Value", cas_number = NA_character_,
    method_raw = "EA005P: pH by PC Titrator", total_or_filtered = "T", units_raw = "pH Unit",
    value_raw = "6.50", value_num = 6.50, value_chr = NA_character_, below_detection = FALSE,
    rl = NA_real_, lab_qualifier = NA_character_, analysed_date = as.Date("2025-06-10"),
    comments = NA_character_, confidence = 1, sample_datetime_raw = "10 Jun 2025",
    sampler = NA_character_, matrix_raw = "WATER", parent_sample = NA_character_,
    uuid_feature = "f-0001", uuid_lab = "lm-0001", uuid_analyte = "a-0001",
    value_converted = 6.50, rl_converted = NA_real_,
    sample_date = as.Date("2025-06-10"), sample_datetime = as.POSIXct(NA),
    supersedes = NA_character_
  )
  tibble::as_tibble(utils::modifyList(defaults, list(...)))
}

s2_new_sample <- function(con) {
  DBI::dbGetQuery(con, "SELECT date, date_start FROM \"sample\"
    WHERE uuid NOT IN ('s-0001','s-0002','s-0003','s-0004','s-0005')")
}

test_that("S2: commit writes sample.date_start from the clean row's `sample_date_start`", {
  st <- s2_commit_setup()
  clean <- s2_clean_row(st$hash, sample_date = as.Date("2025-06-10"),
                        sample_date_start = as.Date("2025-05-10"))
  commit_event(st$event, list(clean = clean, review = tibble::tibble(),
                              skipped = tibble::tibble(), counts = c(new = 1L)), st$con)
  s <- s2_new_sample(st$con)
  expect_equal(nrow(s), 1)
  expect_identical(sydney_day(s$date), "2025-06-10")
  expect_false(is.na(s$date_start))
  expect_identical(sydney_day(s$date_start), "2025-05-10")
})

test_that("S2: a clean row with sample_date_start = NA writes date_start NULL", {
  st <- s2_commit_setup()
  clean <- s2_clean_row(st$hash, sample_date_start = as.Date(NA))
  commit_event(st$event, list(clean = clean, review = tibble::tibble(),
                              skipped = tibble::tibble(), counts = c(new = 1L)), st$con)
  s <- s2_new_sample(st$con)
  expect_equal(nrow(s), 1)
  expect_true(is.na(s$date_start))
})

test_that("S2 (unchanged): a clean row with NO sample_date_start column still commits, date_start NULL", {
  # Guard, passes before and after: every existing producer/fixture lacks the column.
  st <- s2_commit_setup()
  clean <- s2_clean_row(st$hash)
  expect_false("sample_date_start" %in% names(clean))
  commit_event(st$event, list(clean = clean, review = tibble::tibble(),
                              skipped = tibble::tibble(), counts = c(new = 1L)), st$con)
  s <- s2_new_sample(st$con)
  expect_equal(nrow(s), 1)
  expect_identical(sydney_day(s$date), "2025-06-10")
  expect_true(is.na(s$date_start))
})

# ==============================================================================
# S4 - identity matching on the Australia/Sydney calendar date (A44)
# ==============================================================================
#
# A44 (CONTRACT.md): "the canonical timezone is Australia/Sydney" and the
# stored `sample.date` must read back as the intended CALENDAR DAY. The
# pipeline writes naive midnight (A44.3); legacy rows hold Sydney midnight as
# its UTC instant (14:00 / 13:00 the previous day). Comparing
# `CAST(date AS DATE)` reads the UTC day, which is right for the first and one
# day early for the second. The Sydney calendar day of the stored instant is
# right for BOTH, so that is the comparison these tests demand.

test_that("S4: the July block does NOT match the legacy June sample - no false value_conflicts", {
  db_path <- dust_db_setup()
  ingest_workbook(db_path, "2400-7401-07", list(july_block()))

  con <- ro_con(db_path)
  expect_equal(nrow(dust_value_conflicts(con)), 0)
  # Legacy June values untouched.
  jun <- DBI::dbGetQuery(con, "SELECT uuid, value FROM analysis WHERE uuid LIKE 'an-jun-%' ORDER BY uuid")
  expect_equal(jun$value, c(0.33, 1.2, 1.53, 0.27, 0.30, 0.57))
})

test_that("S4: the July block lands on NEW samples - neither June's nor August's - carrying July's real values", {
  db_path <- dust_db_setup()
  ingest_workbook(db_path, "2400-7401-07", list(july_block()))

  con <- ro_con(db_path)
  expected <- list(`fa-d07` = c(0.97, 0.37, 0.6), `fa-d08` = c(1.09, 0.39, 0.7))
  for (alias in names(expected)) {
    s <- gauge_samples(con, alias)
    new <- s[!grepl("^s-(jun|aug)-", s$uuid), ]
    expect_equal(nrow(s), 3, info = alias)          # June + August + new July
    expect_equal(nrow(new), 1, info = alias)
    expect_identical(sydney_day(new$date), "2024-08-01", info = alias)
    v <- DBI::dbGetQuery(con, "SELECT uuid_lab, value FROM analysis WHERE uuid_sample = ?
                                AND uuid_lab IN ('lm-dins','lm-dcom','lm-dinc') ORDER BY uuid_lab",
                         params = list(new$uuid))
    # ORDER BY uuid_lab: lm-dcom, lm-dinc, lm-dins
    expect_equal(v$value, expected[[alias]][c(2, 3, 1)], info = alias)
  }
  # nothing was attached to the legacy August samples
  aug <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM analysis
                               WHERE uuid_sample IN ('s-aug-d07','s-aug-d08')")
  expect_equal(aug$n, 6)
})

test_that("S4: re-ingesting the August block MATCHES the legacy August sample (Sydney 1 Sep = stored 31 Aug 14:00 UTC)", {
  db_path <- dust_db_setup()
  aug <- list(list(month = serial("2024-08-01"), exposure = "2024-08-01",
                   collection = "2024-09-01", days = 31, gauges = aug_gauges()))
  ingest_workbook(db_path, "2400-7401-08", aug)

  con <- ro_con(db_path)
  for (alias in c("fa-d07", "fa-d08")) {
    s <- gauge_samples(con, alias)
    expect_setequal(s$uuid, paste0(c("s-jun-", "s-aug-"), sub("fa-", "", alias)))
  }
  # identical values: already_present, no new dust analyses, no conflicts
  n_dust <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM analysis
                                  WHERE uuid_lab IN ('lm-dins','lm-dcom','lm-dinc')")
  expect_equal(n_dust$n, 12)
  expect_equal(nrow(dust_value_conflicts(con)), 0)
})

# ---- the general (non-dust) path, at the matcher level -----------------------

s4_matcher_db <- function(stored_date) {
  env <- parent.frame()
  db_path <- seed_db(dir = withr::local_tempdir(.local_envir = env))
  con <- seed_con(db_path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE), envir = env)
  DBI::dbExecute(con, sprintf("INSERT INTO \"sample\"
    (uuid, uuid_feature_alias, uuid_project, date, datetime, organisation) VALUES
    ('s-gen', 'fa-0002', 'p-0001', TIMESTAMP '%s', NULL, 'ALS')", stored_date))
  DBI::dbExecute(con, "INSERT INTO analysis (uuid, uuid_sample, uuid_lab, value, quantified, rl_low)
    VALUES ('an-gen', 's-gen', 'lm-0001', 7.2, TRUE, 0.01)")
  con
}

matches_on <- function(con, day) {
  c(
    commit = sampleTidy:::.ct_existing_sample_uuid(
      con, pending = FALSE, match_feature = "f-0002", alias_uuid = "fa-0002",
      sample_date = as.Date(day), sample_datetime = as.POSIXct(NA)),
    reconcile = {
      hit <- sampleTidy:::.rc_find_existing(
        con, resolved_feature = "f-0002", uuid_feature_alias = "fa-0002",
        feature_pending = FALSE, sample_date = as.Date(day),
        sample_datetime = as.POSIXct(NA), uuid_lab = "lm-0001")
      if (is.null(hit)) NA_character_ else hit$analysis_uuid[[1]]
    }
  )
}

test_that("S4 general path: a legacy sample stored as Sydney midnight (14:00 UTC prior day) matches its own Sydney day", {
  con <- s4_matcher_db("2025-06-09 14:00:00")     # = 2025-06-10 00:00 AEST
  got <- matches_on(con, "2025-06-10")
  expect_identical(unname(got[["commit"]]), "s-gen")
  expect_identical(unname(got[["reconcile"]]), "an-gen")
})

test_that("S4 general path: ...and does NOT match the UTC day it used to read back as", {
  con <- s4_matcher_db("2025-06-09 14:00:00")
  got <- matches_on(con, "2025-06-09")
  expect_true(is.na(got[["commit"]]))
  expect_true(is.na(got[["reconcile"]]))
})

test_that("S4 general path (guard): a pipeline-written naive-midnight sample still matches its own day", {
  # A44.3 convention - every sample this pipeline has written. Passes today;
  # must keep passing once the comparison moves to the Sydney day.
  con <- s4_matcher_db("2025-06-10 00:00:00")
  got <- matches_on(con, "2025-06-10")
  expect_identical(unname(got[["commit"]]), "s-gen")
  expect_identical(unname(got[["reconcile"]]), "an-gen")
  nope <- matches_on(con, "2025-06-09")
  expect_true(is.na(nope[["commit"]]))
  expect_true(is.na(nope[["reconcile"]]))
})

test_that("S4 general path: the Sydney-day comparison does not depend on the DuckDB session TimeZone", {
  # DuckDB's TimeZone setting defaults to the HOST zone; a server/CI host in
  # UTC must give the same answer as a Sydney laptop.
  for (tz in c("UTC", "Australia/Sydney", "America/New_York")) {
    con <- s4_matcher_db("2025-06-09 14:00:00")
    DBI::dbExecute(con, sprintf("SET TimeZone = '%s'", tz))
    got <- matches_on(con, "2025-06-10")
    expect_identical(unname(got[["commit"]]), "s-gen", info = tz)
    expect_identical(unname(got[["reconcile"]]), "an-gen", info = tz)
  }
})
