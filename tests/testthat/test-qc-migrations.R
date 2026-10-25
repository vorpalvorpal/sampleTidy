# PLAN-19 section 8, migrations 048 (schema, R-19.1/R-19.6/R-19.7/R-19.8/R-19.9)
# and 049 (QC features from $SAMPLETIDY_QC_CODES, R-19.2/R-19.10/R-19.11).
#
#   mig048_run(db, snapshot_dir, dry_run = FALSE, .now = NULL)
#   mig049_run(db, snapshot_dir, dry_run = FALSE, .now = NULL)
#     -> invisible list(status = "migrated" | "already_migrated" | "dry_run", ...)
#
# [invented: the file names (dev/migrations/048-*.R, 049-*.R, found by glob)
#  and the run signature follow the house shape of 041-047.]
#
# 049 is fed tests/testthat/fixtures/qc/qc-codes-FAKE.csv: 92 INVENTED codes
# at the invented site Q (Q.JDnn/Q.JFnn/Q.JRnn for 30 invented points
# Q.X01-Q.X30, plus Q.JT00 transport and Q.JL00 filter blank tied to no point).
# The migration refuses a codes file inside the repo, so every run copies the
# fixture to a temp dir first. Each test sources the migration inside its own
# test_that() (house rule, test-migration-004 B5).

mig_load <- function(no) {
  dir <- test_path("..", "..", "dev", "migrations")
  hits <- list.files(dir, pattern = sprintf("^%s-.*\\.R$", no), full.names = TRUE)
  hits <- hits[!grepl("^apply-", basename(hits))]
  if (length(hits) != 1) stop(sprintf("migration %s not found (or not unique) in %s", no, dir))
  env <- new.env(parent = globalenv())
  sys.source(hits[[1]], envir = env)
  env
}

mig_query <- function(db, sql, params = NULL) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbGetQuery(con, sql, params = params)
}

mig_cols <- function(db, tbl) {
  mig_query(db, "SELECT column_name FROM information_schema.columns WHERE table_name = ?
                  ORDER BY ordinal_position", params = list(tbl))$column_name
}

mig_marker <- function(db) {
  v <- mig_query(db, "SELECT version FROM schema_version")$version
  v[v >= 1000]
}

# A seeded DB at marker 1047 (the live `feature.permanent` column 049 sets
# is in seed_db()'s DDL).
mig_db_1047 <- function(env = parent.frame()) {
  db <- seed_db(dir = withr::local_tempdir(.local_envir = env))
  con <- seed_con(db)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  ensure_test_asset_table(con)
  # feature.permanent is in seed_db()'s DDL since 2026-10-25.
  DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at)
                       VALUES (1047, TIMESTAMP '2026-10-19 00:00:00')")
  db
}

# ---- 048 ------------------------------------------------------------------------------

test_that("048: creates qc_feature, sample_lab_id, lab_qc_report, lab_qc_outlier and analyte.lab_contaminant; no data; marker 1048", {
  env048 <- mig_load("048")
  db <- mig_db_1047()
  snap <- withr::local_tempdir()
  n_analyte <- mig_query(db, "SELECT count(*) AS n FROM analyte")$n
  r <- suppressMessages(env048$mig048_run(db = db, snapshot_dir = snap))
  expect_identical(r$status, "migrated")
  expect_true(1048 %in% mig_marker(db))

  expect_identical(mig_cols(db, "qc_feature"),
                   c("uuid_feature", "qc_type", "uuid_parent", "date_start", "date_end", "comments"))
  expect_identical(mig_cols(db, "sample_lab_id"),
                   c("uuid_sample", "work_order", "lab_id", "client_id", "source_hash"))
  expect_true(all(c("uuid", "uuid_asset", "work_order", "kind", "issue_date", "n_received",
                    "n_analysed", "summary", "status", "message", "parser_version", "parsed_at")
                  %in% mig_cols(db, "lab_qc_report")))
  expect_true(all(c("uuid", "uuid_report", "work_order", "kind", "method", "method_name",
                    "analyte_raw", "cas", "lab_id", "qc_lot", "client_id", "uuid_sample",
                    "data_raw", "value_pct", "limit_low", "limit_high", "comment", "days_overdue",
                    "date_analysed", "due_analysis", "date_extracted", "due_extraction",
                    "source_page") %in% mig_cols(db, "lab_qc_outlier")))
  for (t in c("qc_feature", "sample_lab_id", "lab_qc_report", "lab_qc_outlier")) {
    expect_equal(mig_query(db, sprintf("SELECT count(*) AS n FROM %s", t))$n, 0, label = t)
  }
  # lab_contaminant: every existing analyte FALSE (R19-10 (2)), none NULL
  lc <- mig_query(db, "SELECT lab_contaminant FROM analyte")$lab_contaminant
  expect_length(lc, n_analyte)
  expect_true(all(lc %in% FALSE))
})

test_that("048: keys - qc_feature PK, sample_lab_id PK (work_order, lab_id), lab_qc_report.uuid_asset UNIQUE; qc_type NOT NULL", {
  env048 <- mig_load("048")
  db <- mig_db_1047()
  suppressMessages(env048$mig048_run(db = db, snapshot_dir = withr::local_tempdir()))
  con <- seed_con(db)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbExecute(con, "INSERT INTO qc_feature (uuid_feature, qc_type) VALUES ('f-q1', 'duplicate')")
  expect_error(DBI::dbExecute(con, "INSERT INTO qc_feature (uuid_feature, qc_type) VALUES ('f-q1', 'field_blank')"))
  expect_error(DBI::dbExecute(con, "INSERT INTO qc_feature (uuid_feature, qc_type) VALUES ('f-q2', NULL)"))
  DBI::dbExecute(con, "INSERT INTO sample_lab_id (uuid_sample, work_order, lab_id) VALUES (NULL, 'ES2600001', 'ES2600001-001')")
  expect_error(DBI::dbExecute(con, "INSERT INTO sample_lab_id (uuid_sample, work_order, lab_id) VALUES (NULL, 'ES2600001', 'ES2600001-001')"))
  DBI::dbExecute(con, "INSERT INTO lab_qc_report (uuid, uuid_asset, work_order) VALUES ('r1', 'as1', 'ES2600001')")
  expect_error(DBI::dbExecute(con, "INSERT INTO lab_qc_report (uuid, uuid_asset, work_order) VALUES ('r2', 'as1', 'ES2600001')"))
})

test_that("048: dry run writes nothing; a re-run is already_migrated", {
  env048 <- mig_load("048")
  db <- mig_db_1047()
  snap <- withr::local_tempdir()
  r0 <- suppressMessages(env048$mig048_run(db = db, snapshot_dir = snap, dry_run = TRUE))
  expect_identical(r0$status, "dry_run")
  expect_false("qc_feature" %in% mig_query(db, "SELECT table_name FROM information_schema.tables")$table_name)
  expect_false(1048 %in% mig_marker(db))
  suppressMessages(env048$mig048_run(db = db, snapshot_dir = snap))
  r2 <- suppressMessages(env048$mig048_run(db = db, snapshot_dir = snap))
  expect_identical(r2$status, "already_migrated")
})

# ---- 049 ------------------------------------------------------------------------------

fake_codes <- function() {
  utils::read.csv(test_path("fixtures", "qc", "qc-codes-FAKE.csv"), colClasses = "character",
                  na.strings = character(0))
}

write_codes <- function(d, env = parent.frame()) {
  p <- file.path(withr::local_tempdir(.local_envir = env), "qc-codes.csv")
  utils::write.csv(d, p, row.names = FALSE, na = "")
  p
}

# 1048 DB with the 30 invented parent points Q.X01-Q.X30 (live, water).
mig_db_1048 <- function(env = parent.frame(), dead = character(0)) {
  env048 <- mig_load("048")
  db <- mig_db_1047(env = env)
  suppressMessages(env048$mig048_run(db = db, snapshot_dir = withr::local_tempdir(.local_envir = env)))
  con <- seed_con(db)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  for (nm in sprintf("Q.X%02d", 1:30)) {
    u <- fl_feature(con, nm, matrix = "freshwater")
    if (nm %in% dead) DBI::dbExecute(con, "UPDATE feature SET date_end = DATE '2020-01-01' WHERE uuid = ?",
                                     params = list(u))
  }
  db
}

mig049_counts <- function(db) {
  mig_query(db, "SELECT (SELECT count(*) FROM feature) AS feature,
                        (SELECT count(*) FROM feature_alias) AS alias,
                        (SELECT count(*) FROM qc_feature) AS qc")
}

test_that("049: 92 virtual, permanent QC features with self aliases, qc_feature rows and parents; no masks; marker 1049", {
  env049 <- mig_load("049")
  db <- mig_db_1048()
  snap <- withr::local_tempdir()
  withr::local_envvar(SAMPLETIDY_QC_CODES = write_codes(fake_codes()))
  before <- mig049_counts(db)
  r <- suppressMessages(env049$mig049_run(db = db, snapshot_dir = snap))
  expect_identical(r$status, "migrated")
  expect_true(1049 %in% mig_marker(db))
  after <- mig049_counts(db)
  expect_equal(after$feature - before$feature, 92)
  expect_equal(after$alias - before$alias, 92)
  expect_equal(after$qc, 92)

  codes <- fake_codes()
  got <- mig_query(db, "SELECT f.name, f.site, f.matrix, f.virtual, f.permanent, q.qc_type,
                               q.date_start, p.name AS parent, p.matrix AS parent_matrix
                          FROM qc_feature q JOIN feature f ON f.uuid = q.uuid_feature
                          LEFT JOIN feature p ON p.uuid = q.uuid_parent")
  expect_setequal(got$name, codes$code)
  got <- got[match(codes$code, got$name), , drop = FALSE]
  expect_identical(got$qc_type, codes$qc_type)
  expect_identical(ifelse(is.na(got$parent), "", got$parent), codes$parent)
  expect_true(all(got$site == "Q"))
  expect_true(all(got$virtual %in% TRUE))
  expect_true(all(got$permanent %in% TRUE))
  has_p <- codes$parent != ""
  expect_identical(got$matrix[has_p], got$parent_matrix[has_p])
  expect_identical(as.character(got$date_start), codes$date_start)

  al <- mig_query(db, "SELECT fa.name, fa.kind, fa.auto_assign, f.name AS feature
                         FROM feature_alias fa JOIN feature f ON f.uuid = fa.uuid_feature
                        WHERE f.uuid IN (SELECT uuid_feature FROM qc_feature)")
  expect_equal(nrow(al), 92)
  expect_true(all(al$kind == "self" & al$auto_assign %in% TRUE & al$name == al$feature))
  expect_equal(mig_query(db, "SELECT count(*) AS n FROM feature_mask
                               WHERE uuid_feature IN (SELECT uuid_feature FROM qc_feature)")$n, 0)
  expect_gt(mig_query(db, "SELECT count(*) AS n FROM change_log WHERE actor LIKE '049-%'")$n, 0)
})

test_that("049 (R-19.11): row backups go to snapshot_dir, never dev/migrations/", {
  env049 <- mig_load("049")
  db <- mig_db_1048()
  snap <- withr::local_tempdir()
  withr::local_envvar(SAMPLETIDY_QC_CODES = write_codes(fake_codes()))
  mdir <- test_path("..", "..", "dev", "migrations")
  pre <- list.files(mdir)
  suppressMessages(env049$mig049_run(db = db, snapshot_dir = snap))
  expect_identical(setdiff(list.files(mdir), pre), character(0))
  expect_length(list.files(mdir, pattern = "^049-.*BACKUP"), 0)
  expect_gt(length(list.files(snap, recursive = TRUE)), 0)
})

test_that("049: idempotent - a second run is already_migrated and adds nothing", {
  env049 <- mig_load("049")
  db <- mig_db_1048()
  snap <- withr::local_tempdir()
  withr::local_envvar(SAMPLETIDY_QC_CODES = write_codes(fake_codes()))
  suppressMessages(env049$mig049_run(db = db, snapshot_dir = snap))
  mid <- mig049_counts(db)
  r <- suppressMessages(env049$mig049_run(db = db, snapshot_dir = snap))
  expect_identical(r$status, "already_migrated")
  expect_identical(mig049_counts(db), mid)
})

test_that("049 (R-19.11): aborts with no SAMPLETIDY_QC_CODES, or a codes file inside the repo; nothing written", {
  env049 <- mig_load("049")
  db <- mig_db_1048()
  snap <- withr::local_tempdir()
  before <- mig049_counts(db)
  withr::local_envvar(SAMPLETIDY_QC_CODES = NA)
  expect_error(suppressMessages(env049$mig049_run(db = db, snapshot_dir = snap)),
               class = "sampletidy_error")
  withr::local_envvar(SAMPLETIDY_QC_CODES = normalizePath(test_path("fixtures", "qc", "qc-codes-FAKE.csv")))
  expect_error(suppressMessages(env049$mig049_run(db = db, snapshot_dir = snap)),
               class = "sampletidy_error")
  expect_identical(mig049_counts(db), before)
  expect_false(1049 %in% mig_marker(db))
})

test_that("049: aborts, writing nothing, on an unknown or dead parent, a duplicate code, a registered code, or a count other than 92", {
  env049 <- mig_load("049")
  codes <- fake_codes()
  bad <- list(
    unknown_parent = within(codes, parent[1] <- "Q.X99"),
    duplicate_code = within(codes, code[2] <- code[1]),
    count_91 = codes[-92, ],
    dead_parent = codes,
    registered = codes)
  for (case in names(bad)) {
    db <- mig_db_1048(dead = if (case == "dead_parent") codes$parent[[1]] else character(0))
    if (case == "registered") {
      con <- seed_con(db)
      fl_feature(con, codes$code[[92]])
      DBI::dbDisconnect(con, shutdown = TRUE)
    }
    before <- mig049_counts(db)
    withr::local_envvar(SAMPLETIDY_QC_CODES = write_codes(bad[[case]]))
    expect_error(suppressMessages(env049$mig049_run(db = db, snapshot_dir = withr::local_tempdir())),
                 class = "sampletidy_error", label = case)
    expect_identical(mig049_counts(db), before, label = case)
    expect_false(1049 %in% mig_marker(db), label = case)
  }
})
