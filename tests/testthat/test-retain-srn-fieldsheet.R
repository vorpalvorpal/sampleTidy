# R-22.G2: ALS sample receipt notifications (SRN) and ACIRL scanned field
# sheets are retained and attached (Robin, 2026-10-25).
#
# 1. "ES2631587_0_SRN_260929155925.pdf": an ALS sample receipt notification.
#    The token is followed by "_<digits>", not the end of the name. Selected
#    by the token gate, attached to the ES work order from the filename, typed
#    "QA". A work order with no project row stays quarantined (find-only).
# 2. Scanned field sheets ("30. Quarterly 28-09.pdf"): no work-order token and
#    no stem twin. An unclaimed .pdf (case-insensitive) that the token gate
#    does not select is still selected IF its folder resolves to a work order;
#    attached there as "QA". If folder inference gives nothing it stays
#    quarantined SILENTLY (the commit-5 cruft-silence rule). Non-PDF cruft
#    stays unselected and silent.
# 3. Folder inference extension: one ALS work order in the folder -> it
#    (unchanged); else, if the files committed from the folder map to exactly
#    ONE project of any kind, that project; zero or several -> nothing. The
#    gas-only-folder case needs the gas workbook builders and lives at the end
#    of test-acirl-gas-e2e.R.

rs_setup <- function() {
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

rs_copy_es_fixture <- function(input_dir) {
  for (f in list.files(testthat::test_path("fixtures", "esdat"),
                       pattern = "ES2617126", full.names = TRUE)) {
    file.copy(f, file.path(input_dir, basename(f)))
  }
}

rs_write <- function(dir, filename) {
  path <- file.path(dir, filename)
  writeBin(charToRaw(paste("fake file", filename, paste(1:30, collapse = " "))), path)
  list(path = path, hash = hash_file(path))
}

# Run ingest, returning the warning messages.
rs_ingest <- function(input_dir, db) {
  w <- character(0)
  withCallingHandlers(
    ingest_dir(input_dir, db = db),
    warning = function(c) { w <<- c(w, conditionMessage(c)); invokeRestart("muffleWarning") }
  )
  w
}

rs_asset <- function(db_path, hash) {
  con <- DBI::dbConnect(duckdb::duckdb(), db_path, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbGetQuery(con,
    "SELECT a.type, p.name AS project
       FROM asset a LEFT JOIN project p ON p.uuid = a.uuid_project
      WHERE a.hash = ?", params = list(hash))
}

rs_state <- function(db_path, hash) {
  con <- DBI::dbConnect(duckdb::duckdb(), db_path, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbGetQuery(con, "SELECT hash, state, state_reason FROM ingest_file WHERE hash = ?",
                  params = list(hash))
}

# ---- 1. SRN -----------------------------------------------------------------

test_that("R-22.G2: an SRN with the ES token and a trailing _<digits> is retained against that work order, typed QA", {
  setup <- list(db_path = rs_setup())
  input_dir <- withr::local_tempdir()
  rs_copy_es_fixture(input_dir)
  srn <- rs_write(input_dir, "ES2617126_0_SRN_260929155925.pdf")
  expect_identical(file_meta(srn$path)$work_order_guess, "ES2617126",
                   info = "precondition: the work order parses from the SRN filename")

  rs_ingest(input_dir, setup$db_path)

  a <- rs_asset(setup$db_path, srn$hash)
  expect_equal(nrow(a), 1, info = "R-22.G2: the SRN must get an asset row")
  if (nrow(a) == 1) {
    expect_identical(a$project[[1]], "ES2617126")
    expect_identical(a$type[[1]], "QA")
  }
  st <- rs_state(setup$db_path, srn$hash)
  expect_identical(st$state[[1]], "archived")
  expect_identical(st$state_reason[[1]], "retained_sibling")
})

test_that("R-22.G2: an SRN attaches by its OWN filename token, not the folder's work order (ES2634040 style)", {
  setup <- list(db_path = rs_setup())
  input_dir <- withr::local_tempdir()
  rs_copy_es_fixture(input_dir)
  # The SRN names a work order that DOES have a project row, different from the
  # folder's: seed it.
  con <- seed_con(setup$db_path)
  DBI::dbExecute(con, "INSERT INTO project (uuid, uuid_parent, uuid_root, name, type)
                       VALUES ('p-es2634040', NULL, 'p-es2634040', 'ES2634040', 'Work order')")
  DBI::dbDisconnect(con, shutdown = TRUE)
  srn <- rs_write(input_dir, "ES2634040_0_SRN_261020142039.pdf")

  rs_ingest(input_dir, setup$db_path)

  a <- rs_asset(setup$db_path, srn$hash)
  expect_equal(nrow(a), 1)
  if (nrow(a) == 1) {
    expect_identical(a$project[[1]], "ES2634040")
    expect_identical(a$type[[1]], "QA")
  }
})

test_that("R-22.G2: an SRN whose work order has no project row stays quarantined and mints no project", {
  setup <- list(db_path = rs_setup())
  input_dir <- withr::local_tempdir()
  srn <- rs_write(input_dir, "ES2634040_0_SRN_261020142039.pdf")

  con0 <- DBI::dbConnect(duckdb::duckdb(), setup$db_path, read_only = TRUE)
  n0 <- DBI::dbGetQuery(con0, "SELECT count(*) AS n FROM project")$n
  DBI::dbDisconnect(con0, shutdown = TRUE)

  suppressWarnings(rs_ingest(input_dir, setup$db_path))

  expect_equal(nrow(rs_asset(setup$db_path, srn$hash)), 0)
  expect_identical(rs_state(setup$db_path, srn$hash)$state[[1]], "quarantined")
  con <- DBI::dbConnect(duckdb::duckdb(), setup$db_path, read_only = TRUE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  expect_equal(DBI::dbGetQuery(con, "SELECT count(*) AS n FROM project")$n, n0)
})

# ---- 2. scanned field sheets -----------------------------------------------

test_that("R-22.G2: scanned field sheets (incl. an upper-case .PDF) in a folder with ONE ALS work order attach to it, typed QA", {
  setup <- list(db_path = rs_setup())
  input_dir <- withr::local_tempdir()
  rs_copy_es_fixture(input_dir)
  names <- c("30. Quarterly 28-09.pdf", "25. Gas 19-08.pdf", "27. Monthly 19-08.pdf",
             "Quarterly 2-12.PDF")
  sheets <- lapply(names, function(n) rs_write(input_dir, n))
  expect_true(is.na(file_meta(sheets[[1]]$path)$work_order_guess),
              info = "precondition: no work-order token in the name")

  rs_ingest(input_dir, setup$db_path)

  for (i in seq_along(sheets)) {
    a <- rs_asset(setup$db_path, sheets[[i]]$hash)
    expect_equal(nrow(a), 1, info = paste("R-22.G2: asset row for", names[[i]]))
    if (nrow(a) == 1) {
      expect_identical(a$project[[1]], "ES2617126", label = names[[i]])
      expect_identical(a$type[[1]], "QA", label = names[[i]])
    }
    st <- rs_state(setup$db_path, sheets[[i]]$hash)
    expect_identical(st$state[[1]], "archived", label = names[[i]])
    expect_identical(st$state_reason[[1]], "retained_sibling", label = names[[i]])
  }
})

test_that("R-22.G2: a scanned field sheet in a folder with nothing committed stays quarantined and draws NO warning", {
  setup <- list(db_path = rs_setup())
  input_dir <- withr::local_tempdir()
  sheet <- rs_write(input_dir, "30. Quarterly 28-09.pdf")

  con0 <- DBI::dbConnect(duckdb::duckdb(), setup$db_path, read_only = TRUE)
  n0 <- DBI::dbGetQuery(con0, "SELECT count(*) AS n FROM project")$n
  DBI::dbDisconnect(con0, shutdown = TRUE)

  w <- rs_ingest(input_dir, setup$db_path)
  expect_length(w, 0)
  expect_equal(nrow(rs_asset(setup$db_path, sheet$hash)), 0)
  expect_identical(rs_state(setup$db_path, sheet$hash)$state[[1]], "quarantined")
  con <- DBI::dbConnect(duckdb::duckdb(), setup$db_path, read_only = TRUE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  expect_equal(DBI::dbGetQuery(con, "SELECT count(*) AS n FROM project")$n, n0)
})

test_that("R-22.G2: non-PDF cruft in a folder that DOES resolve (image001.png, README.md, photo.jpg, notes.docx) is not retained and draws no warning", {
  setup <- list(db_path = rs_setup())
  input_dir <- withr::local_tempdir()
  rs_copy_es_fixture(input_dir)
  cruft <- c("image001.png", "README.md", "photo.jpg", "notes.docx")
  hashes <- vapply(cruft, function(n) rs_write(input_dir, n)$hash, character(1))

  w <- rs_ingest(input_dir, setup$db_path)
  expect_equal(sum(grepl("work order could not be recovered", w, fixed = TRUE)), 0)
  for (i in seq_along(cruft)) {
    expect_equal(nrow(rs_asset(setup$db_path, hashes[[i]])), 0, info = cruft[[i]])
  }
})

test_that("R-22.G2: a 'Prelim 2400-...pdf' in a folder with one ALS work order is attached to it (existing R-9.12 behaviour, pinned)", {
  setup <- list(db_path = rs_setup())
  input_dir <- withr::local_tempdir()
  rs_copy_es_fixture(input_dir)
  prelim <- rs_write(input_dir, "Prelim 2400-7538-08-01 August Monthly Gas Monitoring Blaxland WMF.pdf")

  rs_ingest(input_dir, setup$db_path)

  a <- rs_asset(setup$db_path, prelim$hash)
  expect_equal(nrow(a), 1)
  if (nrow(a) == 1) {
    expect_identical(a$project[[1]], "ES2617126")
    expect_identical(a$type[[1]], "Chemical analysis")
  }
})

test_that("R-22.G2: regression - a COA with an ES token still attaches by token, typed Certificate of analysis", {
  setup <- list(db_path = rs_setup())
  input_dir <- withr::local_tempdir()
  rs_copy_es_fixture(input_dir)
  coa <- rs_write(input_dir, "ES2617126_0_COA.pdf")

  rs_ingest(input_dir, setup$db_path)

  a <- rs_asset(setup$db_path, coa$hash)
  expect_equal(nrow(a), 1)
  if (nrow(a) == 1) {
    expect_identical(a$project[[1]], "ES2617126")
    expect_identical(a$type[[1]], "Certificate of analysis")
  }
})
