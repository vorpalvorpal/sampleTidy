# PLAN-22 A3: the hourly db_checks() inside import_status().
#
# import_status() runs db_checks(con, tier = "hourly") on the DB it reads:
#   * every failing check of severity "error" is a line in `## Problems` (and
#     in the status json's `problems`) that names the check;
#   * failing "warn" checks are counted in a `## DB checks` section and are
#     NOT problems;
#   * the full result goes to `.import-status.json` under `db_checks`, one
#     record per check (name, status, ...);
#   * a check whose SQL errors, or db_checks() itself failing, never breaks
#     import_status() - the note and json are still written.
# Failures never block an import (PLAN-22 A3); nothing here runs inbox_run().

dbc_status <- function(db, env = parent.frame()) {
  input_dir <- withr::local_tempdir(.local_envir = env)
  report_dir <- withr::local_tempdir(.local_envir = env)
  now <- as.POSIXct("2026-10-22 03:00:00", tz = "UTC")
  quiet_run(import_status(db = db, input_dir = input_dir, report_dir = report_dir, now = now))
  list(
    note = read_status_note(report_dir),
    json = jsonlite::read_json(file.path(report_dir, ".import-status.json"), simplifyVector = FALSE)
  )
}

dbc_json_checks <- function(js) {
  dc <- js$db_checks
  data.frame(
    name = vapply(dc, function(r) as.character(r$name), ""),
    status = vapply(dc, function(r) as.character(r$status), ""),
    stringsAsFactors = FALSE
  )
}

test_that("import_status(): a clean DB -> every hourly check recorded as pass in the json, no Problems", {
  db <- dbc_db()
  st <- dbc_status(db)
  jc <- dbc_json_checks(st$json)
  expect_setequal(jc$name, dbc_hourly_names)
  expect_true(all(jc$status == "pass"), info = paste(jc$name[jc$status != "pass"], collapse = ","))
  expect_false(any(grepl("^#+\\s*Problems", st$note)))
  expect_length(st$json$problems, 0)
})

test_that("import_status(): error-severity failures are Problems; warn failures are a count under DB checks", {
  db <- dbc_db()
  dbc_with(db, function(con) {
    # error: dup_asset_hash
    dbc_exec(con, "INSERT INTO asset (uuid, name, uuid_project, hash) VALUES
                   ('as-x1', 'a.pdf', 'p-0001', ?), ('as-x2', 'b.pdf', 'p-0001', ?)", dbc_hex(904), dbc_hex(904))
    # warn x2: vocab_feature_flow, feature_coords
    DBI::dbExecute(con, "UPDATE feature SET flow = 'river' WHERE uuid = 'f-0002'")
    DBI::dbExecute(con, "UPDATE feature SET lon = 'NaN'::DOUBLE, lat = 'NaN'::DOUBLE, geom_wkt = 'POINT EMPTY'
                         WHERE uuid = 'f-0003'")
  })
  st <- dbc_status(db)

  probs <- md_section(st$note, "Problems")
  expect_true(any(grepl("dup_asset_hash", probs, fixed = TRUE)), info = paste(probs, collapse = "\n"))
  expect_false(any(grepl("vocab_feature_flow", probs, fixed = TRUE)))
  expect_false(any(grepl("feature_coords", probs, fixed = TRUE)))
  jp <- vapply(st$json$problems, as.character, "")
  expect_true(any(grepl("dup_asset_hash", jp, fixed = TRUE)))
  expect_false(any(grepl("vocab_feature_flow|feature_coords", jp)))

  sec <- md_section(st$note, "DB checks")
  expect_gt(length(sec), 0)
  expect_true(any(grepl("\\b2\\b[^0-9]*warn", sec, ignore.case = TRUE)), info = paste(sec, collapse = "\n"))

  jc <- dbc_json_checks(st$json)
  expect_setequal(jc$name, dbc_hourly_names)
  expect_identical(jc$status[jc$name == "dup_asset_hash"], "fail")
  expect_identical(jc$status[jc$name == "vocab_feature_flow"], "fail")
  expect_identical(jc$status[jc$name == "feature_coords"], "fail")
  rec <- st$json$db_checks[[which(jc$name == "dup_asset_hash")]]
  expect_equal(as.integer(rec$n), 1L)
  expect_identical(as.character(rec$severity), "error")
})

test_that("import_status(): a check whose SQL errors is recorded as 'error' and the note is still written", {
  db <- dbc_db()
  dbc_with(db, function(con) DBI::dbExecute(con, "DROP TABLE lab_qc_outlier"))
  st <- dbc_status(db)
  expect_true(any(grepl("^#+\\s*Needs review", st$note)))
  jc <- dbc_json_checks(st$json)
  expect_identical(jc$status[jc$name == "orphan_qc_refs"], "error")
})

test_that("import_status(): db_checks() itself failing does not break the status note", {
  db <- dbc_db()
  local_mocked_bindings(db_checks = function(...) stop("db_checks exploded"))
  input_dir <- withr::local_tempdir()
  report_dir <- withr::local_tempdir()
  expect_no_error(quiet_run(import_status(db = db, input_dir = input_dir, report_dir = report_dir,
                                          now = as.POSIXct("2026-10-22 03:00:00", tz = "UTC"))))
  note <- read_status_note(report_dir)
  expect_true(any(grepl("^#+\\s*Needs review", note)))
  expect_true(file.exists(file.path(report_dir, ".import-status.json")))
})
