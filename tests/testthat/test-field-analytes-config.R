# field_analytes is deployment config (spec FA, part A)
#
# API (spec):
# - st_config("field_analytes") defaults to character(0): the generic core ships
#   no lab's labels. An unconfigured deployment imports no field reading from an
#   ACIRL water sheet; every labelled row with a value goes to als_candidates
#   (skipped with reason lab_data_dropped).
# - It is list-valued (no env var; SAMPLETIDY_FIELD_ANALYTES still aborts).
# - The ACIRL field adapter validates it when it reads it: a character vector
#   with no NA (length 0 allowed), else a sampletidy_error naming field_analytes.
# - st_capabilities() ends with "field_analytes".

fa_sheet <- "Groundwater Sites 2"

# A one-sample water sheet: pH and CH4 are labelled field readings.
fa_workbook <- function(path) {
  wb <- openxlsx::createWorkbook()
  openxlsx::addWorksheet(wb, fa_sheet)
  put <- function(r, c, v) {
    openxlsx::writeData(wb, fa_sheet, x = v, startRow = r, startCol = c,
                        colNames = FALSE, rowNames = FALSE)
  }
  put(6L, 3L, "Units")
  put(9L, 2L, "Date of Sample"); put(9L, 4L, 45802)
  put(10L, 2L, "Site Name");     put(10L, 4L, "P.MW06")
  put(11L, 2L, "pH");                 put(11L, 3L, "pH units"); put(11L, 4L, 6.8)
  put(12L, 2L, "CH4 Reading % v/v");  put(12L, 3L, "% v/v");    put(12L, 4L, 1.5)
  openxlsx::saveWorkbook(wb, path, overwrite = TRUE)
  path
}

fa_labels <- function(x) vapply(x, function(r) r$analyte_raw, character(1))

fa_parse <- function(path, field_analytes) {
  sampleTidy:::.st_acirl_parse_water_sheet(
    path, fa_sheet, field_analytes = field_analytes,
    transcription_labels = character(0)
  )
}

fa_unset <- function(env = parent.frame()) {
  withr::local_options(list("sampletidy.field_analytes" = NULL), .local_envir = env)
  withr::local_envvar(c(SAMPLETIDY_FIELD_ANALYTES = NA), .local_envir = env)
}

test_that("field_analytes defaults to character(0)", {
  fa_unset()
  expect_identical(st_config("field_analytes"), character(0))
})

test_that("st_capabilities() lists field_analytes last, keeping the existing names in order", {
  caps <- st_capabilities()
  expect_identical(caps[length(caps)], "field_analytes")
  expect_identical(
    caps[-length(caps)],
    c("timezone", "checks_option", "checks_streams", "site_names",
      "site_keywords", "date_overrides_env", "inbox_batches", "renderer_hooks",
      "report_dir", "gas_template_slots", "acirl_job_prefix")
  )
})

test_that("an empty allowlist sends every labelled field row to als_candidates, none to results", {
  skip_if_not_installed("openxlsx")
  path <- fa_workbook(withr::local_tempfile(fileext = ".xlsx"))
  ws <- fa_parse(path, character(0))
  expect_length(ws$results, 0)
  expect_setequal(fa_labels(ws$als_candidates), c("pH", "CH4 Reading % v/v"))
  reasons <- vapply(ws$skipped, function(s) s$reason[[1]], character(1))
  expect_true("lab_data_dropped" %in% reasons)
})

test_that("a configured allowlist lands those rows in results", {
  skip_if_not_installed("openxlsx")
  path <- fa_workbook(withr::local_tempfile(fileext = ".xlsx"))
  ws <- fa_parse(path, c("pH", "CH4 Reading % v/v"))
  expect_setequal(fa_labels(ws$results), c("pH", "CH4 Reading % v/v"))
  expect_length(ws$als_candidates, 0)
})

test_that("the full adapter reads the allowlist at run time: unconfigured imports nothing, configured imports the rows", {
  skip_if_not_installed("openxlsx")
  path <- fa_workbook(withr::local_tempfile(fileext = ".xlsx"))
  meta <- sampleTidy:::file_meta(path)
  adapter <- sampleTidy:::adapter_registry()[["acirl_field_xlsx"]]

  fa_unset()
  out0 <- adapter$parse(path, meta)
  expect_equal(nrow(out0$results), 0)

  st_config("field_analytes", c("pH", "CH4 Reading % v/v"))
  out1 <- adapter$parse(path, meta)
  expect_equal(nrow(out1$results), 2)
})

test_that("invalid field_analytes values abort the adapter with a sampletidy_error naming the key", {
  skip_if_not_installed("openxlsx")
  path <- fa_workbook(withr::local_tempfile(fileext = ".xlsx"))
  meta <- sampleTidy:::file_meta(path)
  adapter <- sampleTidy:::adapter_registry()[["acirl_field_xlsx"]]

  for (bad in list(1:3, 7.5, c("pH", NA), NA_character_, list("pH", "EC"), TRUE)) {
    withr::local_options(list("sampletidy.field_analytes" = bad))
    err <- tryCatch(adapter$parse(path, meta), error = function(e) e)
    expect_s3_class(err, "sampletidy_error")
    expect_match(conditionMessage(err), "field_analytes", fixed = TRUE)
  }
})

test_that("a valid empty or character allowlist does not abort the adapter", {
  skip_if_not_installed("openxlsx")
  path <- fa_workbook(withr::local_tempfile(fileext = ".xlsx"))
  meta <- sampleTidy:::file_meta(path)
  adapter <- sampleTidy:::adapter_registry()[["acirl_field_xlsx"]]
  withr::local_options(list("sampletidy.field_analytes" = character(0)))
  expect_no_error(adapter$parse(path, meta))
})

test_that("SAMPLETIDY_FIELD_ANALYTES in the environment still aborts", {
  withr::local_options(list("sampletidy.field_analytes" = NULL))
  withr::local_envvar(c(SAMPLETIDY_FIELD_ANALYTES = "pH"))
  err <- tryCatch(st_config("field_analytes"), error = function(e) e)
  expect_s3_class(err, "sampletidy_error")
  expect_match(conditionMessage(err), "field_analytes", fixed = TRUE)
})
