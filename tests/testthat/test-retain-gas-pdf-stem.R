# R-22.G1: a non-tabular ACIRL gas PDF is attached to the project of the asset
# (the .xls/.xlsx report) that shares its filename stem.
#
# `.ig_retain_siblings()` (R/ingest.R) finds a retained sibling's work order
# from (1) an ES####### filename token, then (2) folder inference. A gas PDF,
# e.g. "2400-7538-09-01 September Monthly Gas Monitoring Blaxland WMF.pdf",
# has neither: no ES token, and its folder holds no ALS work order. Parsing
# the 2400-* number out of a filename is FORBIDDEN (the ACIRL work-order trap,
# R/commit.R), so the new step 3 matches on the file's STEM against existing
# `asset.filename` stems instead - the report workbook was archived under the
# right project when it was parsed.
#
# Step 3 runs only AFTER steps 1 and 2 fail, so anything that already
# resolves keeps resolving exactly as before (regression tests below).
#
# The SAME-RUN case (workbook and PDF in one ingest) needs the gas workbook
# builders and lives at the end of test-acirl-gas-e2e.R.

# ---- local helpers ---------------------------------------------------------

g1_stem <- "2400-7538-09-01 September Monthly Gas Monitoring Blaxland WMF"

g1_setup <- function() {
  env <- parent.frame()
  db_path <- seed_db(dir = withr::local_tempdir(.local_envir = env))
  con <- seed_con(db_path)
  ensure_test_asset_table(con)
  DBI::dbDisconnect(con, shutdown = TRUE)
  withr::local_options(list(
    "sampletidy.archive_dir" = withr::local_tempdir(.local_envir = env),
    "sampletidy.snapshot_dir" = withr::local_tempdir(.local_envir = env),
    "sampletidy.remove_ingested" = FALSE
  ), .local_envir = env)
  db_path
}

#' Seed a project row (the find-only target).
g1_project <- function(db_path, uuid, name) {
  con <- seed_con(db_path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbExecute(con, "INSERT INTO project (uuid, uuid_parent, uuid_root, name, type)
                       VALUES (?, NULL, ?, ?, 'Work order')",
                 params = list(uuid, uuid, name))
  invisible(uuid)
}

#' Seed an `asset` row as if a report workbook had been archived earlier.
g1_asset <- function(db_path, filename, uuid_project, uuid = paste0("a-", filename)) {
  con <- seed_con(db_path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbExecute(con, "INSERT INTO asset (uuid, name, type, uuid_project, filename, hash)
                       VALUES (?, ?, 'Chemical analysis', ?, ?, ?)",
                 params = list(uuid, filename, uuid_project, filename,
                               paste0("seedhash-", uuid)))
  invisible(uuid)
}

g1_pdf <- function(dir, filename) {
  path <- file.path(dir, filename)
  writeBin(charToRaw(paste("fake ACIRL gas report", filename, paste(1:30, collapse = " "))), path)
  list(path = path, hash = hash_file(path))
}

g1_ro <- function(db_path, env = parent.frame()) {
  con <- DBI::dbConnect(duckdb::duckdb(), db_path, read_only = TRUE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE), envir = env)
  con
}

g1_asset_for <- function(con, hash) {
  DBI::dbGetQuery(con,
    "SELECT a.type, a.uuid_project, p.name AS project
       FROM asset a LEFT JOIN project p ON p.uuid = a.uuid_project
      WHERE a.hash = ?", params = list(hash))
}

g1_state <- function(db_path, hash) {
  con <- DBI::dbConnect(duckdb::duckdb(), db_path, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbGetQuery(con, "SELECT hash, state, state_reason FROM ingest_file WHERE hash = ?",
                  params = list(hash))
}

g1_copy_es_fixture <- function(input_dir) {
  for (f in list.files(testthat::test_path("fixtures", "esdat"),
                       pattern = "ES2617126", full.names = TRUE)) {
    file.copy(f, file.path(input_dir, basename(f)))
  }
}

# ---- 1. positive: earlier-run workbook ------------------------------------

test_that("R-22.G1: a gas PDF whose stem matches an .xls archived in an EARLIER run is attached to that asset's project, typed Chemical analysis, and archived/retained_sibling", {
  db_path <- g1_setup()
  g1_project(db_path, "p-gas-0901", "2400-7538-09-01")
  g1_asset(db_path, paste0(g1_stem, ".xls"), "p-gas-0901")

  input_dir <- withr::local_tempdir()
  pdf <- g1_pdf(input_dir, paste0(g1_stem, ".pdf"))
  expect_true(is.na(file_meta(pdf$path)$work_order_guess),
              info = "precondition: no ES token, and the 2400 number is never parsed")

  con0 <- seed_con(db_path)
  n_projects <- DBI::dbGetQuery(con0, "SELECT count(*) AS n FROM project")$n
  DBI::dbDisconnect(con0, shutdown = TRUE)

  expect_no_warning(ingest_dir(input_dir, db = db_path))

  con <- g1_ro(db_path)
  a <- g1_asset_for(con, pdf$hash)
  expect_equal(nrow(a), 1, info = "R-22.G1: the PDF must get an asset row")
  if (nrow(a) == 1) {
    expect_identical(a$project[[1]], "2400-7538-09-01")
    expect_identical(a$type[[1]], "Chemical analysis")
  }
  st <- g1_state(db_path, pdf$hash)
  expect_identical(st$state[[1]], "archived")
  expect_identical(st$state_reason[[1]], "retained_sibling")
  expect_equal(DBI::dbGetQuery(con, "SELECT count(*) AS n FROM project")$n, n_projects,
               info = "find-only: no project minted")
})

# ---- 2. matching rules -----------------------------------------------------

test_that("R-22.G1: the stem match is case-insensitive and whitespace-trimmed, and a PDF matches an .xlsx as well as an .xls", {
  db_path <- g1_setup()
  g1_project(db_path, "p-gas-0901", "2400-7538-09-01")
  g1_asset(db_path, paste0(toupper(g1_stem), " .XLSX"), "p-gas-0901")

  input_dir <- withr::local_tempdir()
  pdf <- g1_pdf(input_dir, paste0(g1_stem, ".pdf"))
  ingest_dir(input_dir, db = db_path)

  con <- g1_ro(db_path)
  a <- g1_asset_for(con, pdf$hash)
  expect_equal(nrow(a), 1)
  if (nrow(a) == 1) expect_identical(a$project[[1]], "2400-7538-09-01")
})

test_that("R-22.G1: several matching assets on the SAME single project still resolve to it", {
  db_path <- g1_setup()
  g1_project(db_path, "p-gas-0901", "2400-7538-09-01")
  g1_asset(db_path, paste0(g1_stem, ".xls"), "p-gas-0901")
  g1_asset(db_path, paste0(g1_stem, ".xlsx"), "p-gas-0901")

  input_dir <- withr::local_tempdir()
  pdf <- g1_pdf(input_dir, paste0(g1_stem, ".pdf"))
  ingest_dir(input_dir, db = db_path)

  con <- g1_ro(db_path)
  a <- g1_asset_for(con, pdf$hash)
  expect_equal(nrow(a), 1)
  if (nrow(a) == 1) expect_identical(a$project[[1]], "2400-7538-09-01")
})

test_that("R-22.G1: a matching asset with a NULL uuid_project is ignored - the other matching asset's project still decides", {
  db_path <- g1_setup()
  g1_project(db_path, "p-gas-0901", "2400-7538-09-01")
  g1_asset(db_path, paste0(g1_stem, ".xls"), "p-gas-0901")
  g1_asset(db_path, paste0(g1_stem, ".xlsx"), NA_character_)

  input_dir <- withr::local_tempdir()
  pdf <- g1_pdf(input_dir, paste0(g1_stem, ".pdf"))
  ingest_dir(input_dir, db = db_path)

  con <- g1_ro(db_path)
  a <- g1_asset_for(con, pdf$hash)
  expect_equal(nrow(a), 1)
  if (nrow(a) == 1) expect_identical(a$project[[1]], "2400-7538-09-01")
})

# ---- 3. negatives ----------------------------------------------------------

test_that("R-22.G1: a gas PDF whose stem matches NO asset stays quarantined with the existing 'work order could not be recovered' warning", {
  db_path <- g1_setup()
  g1_project(db_path, "p-gas-0901", "2400-7538-09-01")
  g1_asset(db_path, paste0(g1_stem, ".xls"), "p-gas-0901")

  input_dir <- withr::local_tempdir()
  pdf <- g1_pdf(input_dir, "2400-7538-10-01 October Monthly Gas Monitoring Blaxland WMF.pdf")

  expect_warning(ingest_dir(input_dir, db = db_path),
                 regexp = "work order could not be recovered", fixed = TRUE)

  con <- g1_ro(db_path)
  expect_equal(nrow(g1_asset_for(con, pdf$hash)), 0)
  expect_identical(g1_state(db_path, pdf$hash)$state[[1]], "quarantined")
})

test_that("R-22.G1: a prefix variant ('Prelim <stem>.pdf') does NOT match - exact stem only", {
  db_path <- g1_setup()
  g1_project(db_path, "p-gas-0901", "2400-7538-09-01")
  g1_asset(db_path, paste0(g1_stem, ".xls"), "p-gas-0901")

  input_dir <- withr::local_tempdir()
  pdf <- g1_pdf(input_dir, paste0("Prelim ", g1_stem, ".pdf"))

  expect_warning(ingest_dir(input_dir, db = db_path),
                 regexp = "work order could not be recovered", fixed = TRUE)

  con <- g1_ro(db_path)
  expect_equal(nrow(g1_asset_for(con, pdf$hash)), 0)
  expect_identical(g1_state(db_path, pdf$hash)$state[[1]], "quarantined")
})

test_that("R-22.G1: a stem matching assets on TWO distinct projects is ambiguous - the PDF stays quarantined and the warning names the file", {
  db_path <- g1_setup()
  g1_project(db_path, "p-gas-0901", "2400-7538-09-01")
  g1_project(db_path, "p-gas-0902", "2400-7538-09-02")
  g1_asset(db_path, paste0(g1_stem, ".xls"), "p-gas-0901")
  g1_asset(db_path, paste0(g1_stem, ".xlsx"), "p-gas-0902")

  input_dir <- withr::local_tempdir()
  pdf <- g1_pdf(input_dir, paste0(g1_stem, ".pdf"))

  w <- testthat::capture_warnings(ingest_dir(input_dir, db = db_path))
  expect_true(any(grepl(basename(pdf$path), w, fixed = TRUE)),
              info = "R-22.G1: a warning must mention the file path")

  con <- g1_ro(db_path)
  expect_equal(nrow(g1_asset_for(con, pdf$hash)), 0,
               info = "never file against a guess when the stem is ambiguous")
  expect_identical(g1_state(db_path, pdf$hash)$state[[1]], "quarantined")
})

# ---- 4. regression: earlier steps win --------------------------------------

test_that("R-22.G1: a file that folder inference already resolves keeps its ALS work order even when an .xls with the same stem sits on a different project", {
  db_path <- g1_setup()
  g1_asset(db_path, "2400-7454-05 May 2025 Monthly Katoomba WMF.xls", "p-0001")  # XX1234567

  input_dir <- withr::local_tempdir()
  g1_copy_es_fixture(input_dir)
  pdf <- g1_pdf(input_dir, "2400-7454-05 May 2025 Monthly Katoomba WMF.pdf")

  suppressWarnings(ingest_dir(input_dir, db = db_path))

  con <- g1_ro(db_path)
  a <- g1_asset_for(con, pdf$hash)
  expect_equal(nrow(a), 1)
  if (nrow(a) == 1) {
    expect_identical(a$project[[1]], "ES2617126",
                     label = "folder inference (step 2) must beat the stem match (step 3)")
  }
})

test_that("R-22.G1: a file with an ES####### token keeps its filename work order even when a same-stem asset sits on another project", {
  db_path <- g1_setup()
  g1_asset(db_path, "ES2617126_0_COA.xls", "p-0003")  # YY9876543

  input_dir <- withr::local_tempdir()
  g1_copy_es_fixture(input_dir)
  pdf <- g1_pdf(input_dir, "ES2617126_0_COA.pdf")

  suppressWarnings(ingest_dir(input_dir, db = db_path))

  con <- g1_ro(db_path)
  a <- g1_asset_for(con, pdf$hash)
  expect_equal(nrow(a), 1)
  if (nrow(a) == 1) expect_identical(a$project[[1]], "ES2617126")
})
