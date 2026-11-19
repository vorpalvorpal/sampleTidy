# PLAN-23 R-23.7 and 3.5: the pre-117 guard and the register checks look at
# the MAIN database only. A connection can have a second database ATTACHed (the
# migration 117 rehearsal attaches the pre-117 copy beside the migrated one),
# and DuckDB's catalogue views (information_schema, duckdb_tables(),
# duckdb_columns(), duckdb_constraints()) list the tables of every attached
# database. A probe that does not filter on current_database() then answers for
# the wrong database: a pre-117 database attached beside a post-117 main turns
# every register check off without a word.
# Fixtures: seed_db() (post-117) and local_pre117_db(), one opened as main and
# the other ATTACHed read-only beside it.

# A connection whose main database is the one at `main_path` (opened
# read-write), with the database at `attach_path` attached read-only as
# `other`. (An in-memory copy through COPY FROM DATABASE is not possible: it
# trips feature_geometry's self-referencing foreign key on DuckDB 1.4.)
att_con <- function(main_path, attach_path, env = parent.frame()) {
  con <- DBI::dbConnect(duckdb::duckdb(config = list(memory_limit = "1GB")), main_path, read_only = FALSE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE), envir = env)
  DBI::dbExecute(con, sprintf("ATTACH '%s' AS other (READ_ONLY)", attach_path))
  con
}

post_main_pre_other <- function(env = parent.frame()) {
  post <- seed_db(dir = withr::local_tempdir(.local_envir = env))
  pre <- local_pre117_db(env = env)
  att_con(post, pre, env = env)
}

pre_main_post_other <- function(env = parent.frame()) {
  pre <- local_pre117_db(env = env)
  post <- seed_db(dir = withr::local_tempdir(.local_envir = env))
  att_con(pre, post, env = env)
}

test_that("fixture: main is the post-117 database and the pre-117 one is attached", {
  con <- post_main_pre_other()
  expect_false(identical(DBI::dbGetQuery(con, "SELECT current_database() AS d")$d, "other"))
  expect_true("other" %in% DBI::dbGetQuery(con, "SELECT database_name FROM duckdb_databases()")$database_name)
  expect_true(DBI::dbExistsTable(con, "feature_geometry"))
  expect_false("lon" %in% DBI::dbListFields(con, "feature"))
})

# ---- the guard -----------------------------------------------------------------------------

test_that("R-23.7: .st_has_feature_register() is TRUE for a post-117 main with a pre-117 database attached", {
  con <- post_main_pre_other()
  expect_true(.st_has_feature_register(con))
})

test_that("R-23.7: .st_has_feature_register() is FALSE for a pre-117 main with a post-117 database attached", {
  con <- pre_main_post_other()
  expect_false(.st_has_feature_register(con))
})

# ---- the register checks run against main --------------------------------------------------

test_that("R-23.30: with a pre-117 database attached, a register check still runs on main and reports main's violation", {
  con <- post_main_pre_other()
  # f-0006 ended 2020-06-30; open its self arm in MAIN (feature_self_arm_end, hourly).
  DBI::dbExecute(con, "UPDATE feature_alias SET date_end = NULL WHERE uuid = 'fa-0013'")
  expect_true("feature_self_arm_end" %in% db_checks_core()$name)
  res <- db_checks(con, tier = "hourly")
  r <- res[res$name == "feature_self_arm_end", , drop = FALSE]
  expect_identical(nrow(r), 1L)
  expect_identical(r$status, "fail")     # not a silent pass from the guard
  expect_true("f-0006" %in% as.character(r$sample[[1]]$key))
})

test_that("R-23.30: with a pre-117 database attached, feature_sample_after_end still reports main's late sample", {
  con <- post_main_pre_other()
  DBI::dbExecute(con, "UPDATE feature_alias SET date_end = DATE '2020-06-30' WHERE uuid = 'fa-0013'")
  t23_sample(con, "s-att-late", "fa-0013", "2021-03-01")
  res <- db_checks(con, tier = "hourly")
  r <- res[res$name == "feature_sample_after_end", , drop = FALSE]
  expect_identical(nrow(r), 1L)
  expect_identical(r$status, "fail")
  expect_true("s-att-late" %in% as.character(r$sample[[1]]$key))
})

# ---- the mask readers' window columns (R/feature-register.R) -------------------------------

test_that("3.6: .st_mask_window_cols() reads main's mask: undated on a pre-117 main even with a dated mask attached", {
  con <- pre_main_post_other()
  cols <- .st_mask_window_cols(con)
  expect_match(cols, "CAST(NULL AS DATE) AS date_start", fixed = TRUE)
  # and the reader's query runs on main
  expect_no_error(DBI::dbGetQuery(con, paste("SELECT fm.uuid_feature,", cols, "FROM feature_mask fm")))
})

test_that("3.6: .st_mask_window_cols() gives the row's window on a post-117 main with an undated mask attached", {
  con <- post_main_pre_other()
  cols <- .st_mask_window_cols(con)
  expect_match(cols, "fm.date_start AS date_start", fixed = TRUE)
  expect_no_error(DBI::dbGetQuery(con, paste("SELECT fm.uuid_feature,", cols, "FROM feature_mask fm")))
})

# ---- expected_constraints_present reads main's constraints ---------------------------------

test_that("R-23.20: main's feature_predecessor without its primary key is reported even when an attached database's table has one", {
  post <- seed_db(dir = withr::local_tempdir())
  other <- seed_db(dir = withr::local_tempdir())
  con <- att_con(post, other)
  DBI::dbExecute(con, "CREATE TEMP TABLE keep_fp AS SELECT * FROM feature_predecessor")
  DBI::dbExecute(con, "DROP TABLE feature_predecessor")
  DBI::dbExecute(con, "CREATE TABLE feature_predecessor (uuid VARCHAR, uuid_feature VARCHAR NOT NULL,
                       uuid_predecessor VARCHAR NOT NULL, date_break DATE, source VARCHAR NOT NULL, comments VARCHAR)")
  DBI::dbExecute(con, "INSERT INTO feature_predecessor SELECT * FROM keep_fp")
  res <- db_checks(con, tier = "migration")
  r <- res[res$name == "expected_constraints_present", , drop = FALSE]
  expect_identical(r$status, "fail")
  expect_true("feature_predecessor.uuid PRIMARY KEY" %in% as.character(r$sample[[1]]$key))
})
