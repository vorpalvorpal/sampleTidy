# tests/testthat/test-unknown-feature-dedupe.R
#
# Review-queue dedupe for `unknown_feature` on a ROW-LEVEL re-ingest.
#
# THE DEFECT (scratchpad/2026-10-17-gasdry2/RESULTS.md section 4): delete a
# file's `ingest_file` row (or let the same content arrive under a new hash or
# path) and re-ingest it. Every row is already_present and the pending
# feature_alias is not duplicated - but a SECOND open `unknown_feature` item is
# opened for every unresolved feature, the second one without a `uuid_alias`
# (the alias already existed), and the file ends `needs_review` instead of
# `archived`.
#
# HOW THE OTHER KINDS BEHAVE (read from the code, not assumed):
#   * `.ct_commit_review()` (R/commit.R) refuses a second OPEN item with the
#     same (kind, source_hash, payload) - and only checks status = 'open', so a
#     RESOLVED earlier item never blocks a new one. That dedupe is scoped to
#     adapter-raised items and is WITHIN one file (source_hash); it is not
#     cross-file.
#   * `duplicate_report_number` / `report_no_mismatch` are not re-opened for
#     other reasons (their trigger condition is false on a re-ingest).
#
# CONTRACT THESE TESTS PIN: an `unknown_feature` item is identified by the
# unresolved feature - its payload `feature_raw` (+ `site`/`point`) - within the
# SAME source_hash, while status = 'open'. The tests do not care how the
# implementation keys it, only the outcome. Re-ingesting the same file must
# leave exactly one open item per unresolved feature, and the file `archived`
# as on first ingest.
#
# Cross-file: the existing dedupe is per source_hash, so a DIFFERENT file citing
# the same unknown feature is deliberately NOT asserted to fold into the first
# file's item (its item names that file's cells). A characterisation test
# records today's behaviour; delete it if the design is changed to cross-file.
#
# Fixtures: synthetic gas workbooks (helper-acirl-gas.R). B.G190 and B.G191
# are deliberately absent from the registry.

ufd_features <- c(`f-g182` = "B.G182", `f-g368` = "B.G368", `f-g382` = "B.G382")

ufd_db_setup <- function(env = parent.frame()) {
  db_path <- seed_db(dir = withr::local_tempdir(.local_envir = env))
  con <- seed_con(db_path)
  ensure_test_asset_table(con)
  withr::local_options(list(
    "sampletidy.archive_dir" = withr::local_tempdir(.local_envir = env),
    "sampletidy.snapshot_dir" = withr::local_tempdir(.local_envir = env),
    "sampletidy.remove_ingested" = FALSE
  ), .local_envir = env)
  i <- 0
  for (u in names(ufd_features)) {
    i <- i + 1
    nm <- ufd_features[[u]]
    DBI::dbExecute(con, "INSERT INTO feature (uuid, name, site, flow, matrix, date_end, lon, lat)
                         VALUES (?, ?, 'B', NULL, 'air', NULL, ?, ?)",
                   params = list(u, nm, 150.6 + i / 1000, -33.7 - i / 1000))
    DBI::dbExecute(con, "INSERT INTO feature_alias
      (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign, first_seen, last_seen, confirmed_by)
      VALUES (?, ?, ?, ?, 'self', 0, TRUE, TIMESTAMP '2020-01-01 00:00:00', TIMESTAMP '2020-01-01 00:00:00', NULL)",
      params = list(paste0("fa-", sub("^f-", "", u)), u, nm, tolower(nm)))
  }
  DBI::dbExecute(con, "INSERT INTO analyte (uuid, name, units, conversion_constant, type, CAS)
                       VALUES ('a-ch4', 'CH4', 'L/L', 1, 'gas', NULL)")
  DBI::dbExecute(con, "INSERT INTO lab_method
    (uuid, uuid_analyte, name, method, organisation, rl_low, units, conversion_constant)
    VALUES ('lm-ch4', 'a-ch4', 'CH4 Reading % v/v', 'field', 'ACIRL', 1e-4, NULL, NULL)")
  DBI::dbExecute(con, "INSERT INTO project (uuid, uuid_parent, uuid_root, name, type)
                       VALUES ('p-gascamp', NULL, 'p-gascamp', 'Monthly gas monitoring', NULL)")
  DBI::dbDisconnect(con, shutdown = TRUE)
  db_path
}

# One workbook: B.G182 known; `unknown` are unregistered L1 points (B.G190 ...).
ufd_workbook <- function(dir, report_no = "2400-9901-07-01", sample_date = "2025-07-22",
                         unknown = list(G190 = 0.1, G191 = 0.2)) {
  build_gas_blaxland_2025(
    dir, report_no = report_no, sample_date = sample_date,
    filename = paste0(report_no, " July 2025 Monthly Gas Monitoring Blaxland WMF.xlsx"),
    l1 = list(c(list(G182 = 0), unknown)),
    l2 = list(list(G368 = 0)), l2_rows = 8,
    l3 = list(list(G382 = 0))
  )
}

ufd_ingest <- function(db_path, input) {
  suppressMessages(suppressWarnings(ingest_dir(input, db = db_path)))
}

ufd_query <- function(db_path, sql, params = NULL) {
  con <- DBI::dbConnect(duckdb::duckdb(), db_path, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbGetQuery(con, sql, params = params)
}

# Review items for one unresolved feature (payload names it as feature_raw).
ufd_items <- function(db_path, feature_raw = NULL, status = NULL) {
  sql <- "SELECT uuid, status, source_hash, uuid_alias, payload FROM review_queue
           WHERE kind = 'unknown_feature'"
  if (!is.null(feature_raw)) {
    sql <- paste0(sql, " AND payload LIKE '%\"feature_raw\":\"", feature_raw, "\"%'")
  }
  if (!is.null(status)) sql <- paste0(sql, " AND status = '", status, "'")
  ufd_query(db_path, sql)
}

# Forget the file at the ingest level only, so the next ingest_dir() re-runs it
# through reconcile and commit at ROW level (every row already_present).
ufd_forget_file <- function(db_path) {
  con <- seed_con(db_path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbExecute(con, "DELETE FROM ingest_file")
}

ufd_file_states <- function(db_path) {
  ufd_query(db_path, "SELECT hash, state FROM ingest_file")
}

# ==============================================================================

test_that("UD0 (control): first ingest opens one open unknown_feature item per unknown point and archives the file", {
  db_path <- ufd_db_setup()
  input <- withr::local_tempdir()
  ufd_workbook(input)
  ufd_ingest(db_path, input)

  expect_equal(nrow(ufd_items(db_path, "B.G190", "open")), 1)
  expect_equal(nrow(ufd_items(db_path, "B.G191", "open")), 1)
  expect_equal(nrow(ufd_items(db_path)), 2)
  expect_false(any(is.na(ufd_items(db_path)$uuid_alias)))      # pending alias linked
  expect_true(all(ufd_file_states(db_path)$state == "archived"))
})

test_that("UD1: a row-level re-ingest of the same file opens no second unknown_feature item per feature", {
  db_path <- ufd_db_setup()
  input <- withr::local_tempdir()
  ufd_workbook(input)
  ufd_ingest(db_path, input)
  expect_equal(nrow(ufd_items(db_path)), 2)

  ufd_forget_file(db_path)
  ufd_ingest(db_path, input)

  expect_equal(nrow(ufd_items(db_path, "B.G190", "open")), 1)
  expect_equal(nrow(ufd_items(db_path, "B.G191", "open")), 1)
  expect_equal(nrow(ufd_items(db_path)), 2)
})

test_that("UD1: the surviving item is the ORIGINAL one - still linked to its pending alias", {
  db_path <- ufd_db_setup()
  input <- withr::local_tempdir()
  ufd_workbook(input)
  ufd_ingest(db_path, input)
  before <- ufd_items(db_path)
  n_alias <- ufd_query(db_path, "SELECT count(*) AS n FROM feature_alias")$n

  ufd_forget_file(db_path)
  ufd_ingest(db_path, input)
  after <- ufd_items(db_path)

  expect_setequal(after$uuid, before$uuid)
  expect_false(any(is.na(after$uuid_alias)))
  # (the pending alias itself was never duplicated - only the review item)
  expect_equal(ufd_query(db_path, "SELECT count(*) AS n FROM feature_alias")$n, n_alias)
})

test_that("UD2: the file re-ingested at row level ends archived, as on first ingest, not needs_review", {
  db_path <- ufd_db_setup()
  input <- withr::local_tempdir()
  ufd_workbook(input)
  ufd_ingest(db_path, input)

  ufd_forget_file(db_path)
  ufd_ingest(db_path, input)

  st <- ufd_file_states(db_path)
  expect_equal(nrow(st), 1)
  expect_identical(st$state[[1]], "archived")
})

test_that("UD2: repeated row-level re-ingests stay at one item per feature", {
  db_path <- ufd_db_setup()
  input <- withr::local_tempdir()
  ufd_workbook(input)
  ufd_ingest(db_path, input)
  for (k in 1:3) {
    ufd_forget_file(db_path)
    ufd_ingest(db_path, input)
  }
  expect_equal(nrow(ufd_items(db_path)), 2)
  expect_equal(nrow(ufd_items(db_path, status = "open")), 2)
})

test_that("UD3: after the item is RESOLVED, a new occurrence opens a fresh open item (resolved items do not block)", {
  db_path <- ufd_db_setup()
  input <- withr::local_tempdir()
  ufd_workbook(input)
  ufd_ingest(db_path, input)
  first <- ufd_items(db_path, "B.G190", "open")
  expect_equal(nrow(first), 1)
  resolve_review(first$uuid[[1]], resolution = "test: dismissed", resolved_by = "tester",
                 db = db_path)
  expect_equal(nrow(ufd_items(db_path, "B.G190", "resolved")), 1)

  ufd_forget_file(db_path)
  ufd_ingest(db_path, input)

  expect_equal(nrow(ufd_items(db_path, "B.G190", "resolved")), 1)   # history kept
  expect_equal(nrow(ufd_items(db_path, "B.G190", "open")), 1)       # and a new one
  expect_equal(nrow(ufd_items(db_path, "B.G190")), 2)
  expect_equal(nrow(ufd_items(db_path, "B.G191", "open")), 1)       # untouched sibling: still one
  expect_equal(nrow(ufd_items(db_path, "B.G191")), 1)
})

test_that("UD4 (regression): two DIFFERENT unknown features still get two items", {
  db_path <- ufd_db_setup()
  input <- withr::local_tempdir()
  ufd_workbook(input)
  ufd_ingest(db_path, input)
  expect_equal(nrow(ufd_items(db_path, status = "open")), 2)
  expect_false(identical(ufd_items(db_path, "B.G190")$uuid, ufd_items(db_path, "B.G191")$uuid))

  ufd_forget_file(db_path)
  ufd_ingest(db_path, input)
  expect_equal(nrow(ufd_items(db_path, "B.G190", "open")), 1)
  expect_equal(nrow(ufd_items(db_path, "B.G191", "open")), 1)
})

test_that("UD4 (regression): a re-ingest whose file has a NEW unknown feature opens exactly one item for it", {
  db_path <- ufd_db_setup()
  input <- withr::local_tempdir()
  ufd_workbook(input)
  ufd_ingest(db_path, input)

  # Same report, re-saved with an extra unregistered point: different content
  # hash, same rows for G190/G191. The dedupe is per source_hash (as UD6), so
  # the re-save is another file: one item each per file for G190/G191.
  input2 <- withr::local_tempdir()
  ufd_workbook(input2, unknown = list(G190 = 0.1, G191 = 0.2, G192 = 0.3))
  ufd_ingest(db_path, input2)

  expect_equal(nrow(ufd_items(db_path, "B.G190", "open")), 2)
  expect_equal(nrow(ufd_items(db_path, "B.G191", "open")), 2)
  expect_equal(nrow(ufd_items(db_path, "B.G192", "open")), 1)
})

test_that("UD5 (control, passes today): identical bytes under a new path short-circuit on the file hash and open nothing", {
  db_path <- ufd_db_setup()
  input <- withr::local_tempdir()
  ufd_workbook(input)
  ufd_ingest(db_path, input)

  input2 <- withr::local_tempdir()
  src <- list.files(input, full.names = TRUE)
  file.copy(src, file.path(input2, paste0("copy-", basename(src))))
  ufd_ingest(db_path, input2)

  expect_equal(nrow(ufd_items(db_path, "B.G190", "open")), 1)
  expect_equal(nrow(ufd_items(db_path, "B.G191", "open")), 1)
})

test_that("UD6 (characterisation, delete if dedupe becomes cross-file): a DIFFERENT file citing the same unknown feature keeps its own item", {
  # The existing dedupe (.ct_commit_review) is per source_hash, so this pins
  # today's behaviour: two files, two items for B.G190, each naming its own cells.
  db_path <- ufd_db_setup()
  input <- withr::local_tempdir()
  ufd_workbook(input)
  ufd_ingest(db_path, input)

  input2 <- withr::local_tempdir()
  ufd_workbook(input2, report_no = "2400-9902-08-01", sample_date = "2025-08-19")
  ufd_ingest(db_path, input2)

  items <- ufd_items(db_path, "B.G190", "open")
  expect_equal(nrow(items), 2)
  expect_equal(length(unique(items$source_hash)), 2)
})
