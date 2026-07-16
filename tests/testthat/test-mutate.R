# Plan 09 - R/mutate.R: the mutation layer, the only write door.
#
# `db_append(con, table, df, actor, reason, source_hash = NA)`,
# `db_update(con, table, uuid, changes, actor, reason, source_hash = NA)`,
# `db_delete(con, table, uuid, actor, reason)` all write `change_log` rows in
# the same transaction as the mutation they record.
#
# CONTRACT shows `correct_value(uuid_analysis, new_value, reason, actor)`
# with NO `con` argument (unlike `db_append(con, ...)`), so the domain
# helpers (`correct_value()`, `add_feature()`, `add_analyte()`,
# `add_project()`) are assumed to resolve their own connection from
# `st_config("live_db")`, consistent with DESIGN §9.3 ("one set of write
# functions used by pipeline and humans alike" - humans calling these
# interactively won't have an open `con` lying around). Tests point
# `st_config("live_db")` at the throwaway seeded DB via
# `withr::local_options()`. See dev/plans/PLAN-CHANGE-REQUESTS.md.

count_change_log <- function(con) {
  DBI::dbGetQuery(con, "SELECT count(*) AS n FROM change_log")$n
}

# ---- db_append / db_update: change_log recording ---------------------------

test_that("R-9.1: db_append() of 2 rows writes 2 change_log rows with one shared `at` and the actor recorded", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  before <- count_change_log(con)
  new_features <- tibble::tibble(
    uuid = c("f-1001", "f-1002"), name = c("T.NEW1", "T.NEW2"),
    site = c("TestSite", "TestSite"), flow = c("surface", "surface"),
    matrix = c("water", "water")
  )
  db_append(con, "feature", new_features, actor = "tester", reason = "bulk add")

  after <- count_change_log(con)
  expect_equal(after - before, 2)

  log_rows <- DBI::dbGetQuery(con, "SELECT * FROM change_log WHERE tbl = 'feature' ORDER BY uuid_row")
  expect_equal(nrow(log_rows), 2)
  expect_equal(length(unique(log_rows$at)), 1)
  expect_true(all(log_rows$actor == "tester"))
  expect_true(all(log_rows$action == "insert"))
  expect_setequal(log_rows$uuid_row, c("f-1001", "f-1002"))

  # Counts the appended rows specifically rather than the seed total: plan 11
  # grew the seed's feature count (3 -> 7) and a pinned absolute broke. The
  # WHERE-filtered form matches this file's own idiom (cf. the add_feature test
  # below) and asserts the stronger thing -- that these two rows landed.
  n_features <- DBI::dbGetQuery(
    con, "SELECT count(*) AS n FROM feature WHERE uuid IN ('f-1001', 'f-1002')"
  )$n
  expect_equal(n_features, 2)
})

test_that("R-9.1: db_update() changing 2 fields writes 2 change_log rows with correct old/new", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  before <- count_change_log(con)
  db_update(con, "sample", "s-0001",
            changes = list(organisation = "ACIRL", person = "J. Tester"),
            actor = "tester", reason = "correction")

  after <- count_change_log(con)
  expect_equal(after - before, 2)

  log_rows <- DBI::dbGetQuery(con, "SELECT * FROM change_log WHERE tbl = 'sample' AND uuid_row = 's-0001' ORDER BY field")
  expect_equal(nrow(log_rows), 2)
  org_row <- log_rows[log_rows$field == "organisation", ]
  person_row <- log_rows[log_rows$field == "person", ]
  expect_equal(org_row$old, "ALS")
  expect_equal(org_row$new, "ACIRL")
  expect_equal(person_row$new, "J. Tester")
  expect_true(all(log_rows$action == "update"))

  updated <- DBI::dbGetQuery(con, "SELECT organisation, person FROM \"sample\" WHERE uuid = 's-0001'")
  expect_equal(updated$organisation, "ACIRL")
  expect_equal(updated$person, "J. Tester")
})

test_that("R-9.1: a failing update (bad column) rolls back the change_log too (atomicity)", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  before <- count_change_log(con)
  err <- tryCatch(
    db_update(con, "sample", "s-0001",
              changes = list(not_a_real_column = "x"),
              actor = "tester", reason = "should fail"),
    error = function(e) e
  )
  expect_s3_class(err, "condition")
  after <- count_change_log(con)
  expect_equal(after, before)
})

test_that("R-9.1: db_delete() removes the row and writes a change_log delete entry", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  DBI::dbExecute(con, "INSERT INTO feature (uuid, name, site, flow, matrix) VALUES
    ('f-9999', 'T.THROWAWAY', 'TestSite', 'surface', 'water')")
  before <- count_change_log(con)

  db_delete(con, "feature", uuid = "f-9999", actor = "tester", reason = "cleanup")

  n_left <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM feature WHERE uuid = 'f-9999'")$n
  expect_equal(n_left, 0)
  after <- count_change_log(con)
  expect_equal(after - before, 1)
  log_row <- DBI::dbGetQuery(con, "SELECT * FROM change_log WHERE uuid_row = 'f-9999' ORDER BY \"at\" DESC LIMIT 1")
  expect_equal(log_row$action, "delete")
})

test_that("R-9.1: direct-write bypass is lint-guarded - no forbidden raw SQL writes in R/", {
  pkg_root <- normalizePath(file.path(testthat::test_path(), "..", ".."))
  r_dir <- file.path(pkg_root, "R")
  r_files <- if (dir.exists(r_dir)) list.files(r_dir, pattern = "\\.R$", full.names = TRUE) else character(0)
  r_files <- r_files[!basename(r_files) %in% c("mutate.R", "db-schema.R")]

  pattern <- "dbAppendTable|dbExecute\\([^)]*(INSERT|UPDATE|DELETE)"
  hits <- character(0)
  for (f in r_files) {
    lines <- readLines(f, warn = FALSE)
    bad <- grepl(pattern, lines)
    if (any(bad)) hits <- c(hits, paste0(basename(f), ":", paste(which(bad), collapse = ",")))
  }
  # Trivially passes while R/ has no adapter/commit/etc. sources yet; becomes
  # meaningful once plans 01-09 land their production files (R-9.1 note).
  expect_true(length(hits) == 0, info = paste("forbidden direct writes found in:", paste(hits, collapse = "; ")))
})

# ---- domain helpers ---------------------------------------------------------

test_that("R-9.1: add_feature() inserts a row and a change_log entry", {
  path <- seed_db()
  withr::local_options(list("sampletidy.live_db" = path))
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  before <- count_change_log(con)

  add_feature(name = "T.NEW1", site = "TestSite", flow = "surface", matrix = "water",
              actor = "tester", reason = "new monitoring point")

  n_features <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM feature WHERE name = 'T.NEW1'")$n
  expect_equal(n_features, 1)
  after <- count_change_log(con)
  expect_gt(after, before)
})

test_that("R-9.1: add_analyte() inserts a row and a change_log entry", {
  path <- seed_db()
  withr::local_options(list("sampletidy.live_db" = path))
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  before <- count_change_log(con)

  add_analyte(name = "Sulfate", units = "mg/L", type = "anion", CAS = "14808-79-8",
              actor = "tester", reason = "new analyte")

  n_analytes <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM analyte WHERE name = 'Sulfate'")$n
  expect_equal(n_analytes, 1)
  after <- count_change_log(con)
  expect_gt(after, before)
})

test_that("R-9.1: add_project() inserts a row and a change_log entry", {
  path <- seed_db()
  withr::local_options(list("sampletidy.live_db" = path))
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  before <- count_change_log(con)

  add_project(name = "ZZ0000099", type = "Work order", actor = "tester", reason = "new work order")

  n_projects <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM project WHERE name = 'ZZ0000099'")$n
  expect_equal(n_projects, 1)
  after <- count_change_log(con)
  expect_gt(after, before)
})

test_that("R-9.1: correct_value() updates the analysis and logs the old value", {
  path <- seed_db()
  withr::local_options(list("sampletidy.live_db" = path))
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  before <- count_change_log(con)

  correct_value(uuid_analysis = "an-0001", new_value = 150, reason = "lab reissue", actor = "tester")

  updated <- DBI::dbGetQuery(con, "SELECT value FROM analysis WHERE uuid = 'an-0001'")
  expect_equal(updated$value, 150)
  after <- count_change_log(con)
  expect_gt(after, before)
  log_row <- DBI::dbGetQuery(con, "SELECT * FROM change_log WHERE uuid_row = 'an-0001' ORDER BY \"at\" DESC LIMIT 1")
  expect_equal(log_row$old, "100")
})

# ---- review_queue reader -----------------------------------------------------

test_that("R-9.1: review_queue() filters by status", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  DBI::dbExecute(con, "INSERT INTO review_queue (uuid, created_at, kind, work_order, status) VALUES
    ('rq-0001', CURRENT_TIMESTAMP, 'unknown_feature', 'XX1234567', 'open'),
    ('rq-0002', CURRENT_TIMESTAMP, 'unknown_analyte', 'XX1234567', 'resolved')")

  open_items <- review_queue(con, status = "open")
  expect_equal(nrow(open_items), 1)
  expect_identical(open_items$uuid, "rq-0001")

  resolved_items <- review_queue(con, status = "resolved")
  expect_equal(nrow(resolved_items), 1)
  expect_identical(resolved_items$uuid, "rq-0002")
})

test_that("R-9.1: review_queue() has stable columns on a zero-row result", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  empty <- review_queue(con, status = "open")
  expect_equal(nrow(empty), 0)
  expect_true(all(c("uuid", "created_at", "kind", "work_order", "source_hash", "payload",
                     "status", "resolution", "resolved_by", "resolved_at") %in% names(empty)))
})
