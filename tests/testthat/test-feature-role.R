# Monitoring-point roles: feature_role / feature_dubious tables, vocabularies,
# the mutation-layer allowlist and the two standing db_checks.

pr_con <- function(env = parent.frame()) {
  con <- seed_con(seed_db())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE), envir = env)
  con
}

pr_cols <- function(con, tbl) {
  DBI::dbGetQuery(con, sprintf("SELECT column_name FROM information_schema.columns
                                WHERE table_name = '%s' ORDER BY ordinal_position", tbl))$column_name
}

test_that("point roles: the vocabularies have the exact contents and order", {
  expect_identical(.st_water_types, c("groundwater", "surface", "leachate"))
  expect_identical(.st_point_roles, c("leachate", "containment", "receptor", "reference"))
  expect_identical(.st_source_cells, c("A", "B", "A+B", "single cell", "street sweepings", "other"))
  expect_identical(.st_treatments, c("raw", "treated", "partly treated"))
})

test_that("point roles: .feature_role_ddl names both tables with no declared foreign keys", {
  expect_type(.feature_role_ddl, "list")
  expect_identical(names(.feature_role_ddl), c("feature_role", "feature_dubious"))
  for (d in .feature_role_ddl) {
    expect_match(d, "CREATE TABLE", fixed = TRUE)
    expect_false(grepl("REFERENCES|FOREIGN KEY|CHECK\\s*\\(", d, ignore.case = TRUE))
  }
})

test_that("point roles: ready() is FALSE before create_schema and TRUE after", {
  con <- pr_con()
  expect_false(.feature_role_ready(con))
  .feature_role_create_schema(con)
  expect_true(.feature_role_ready(con))
})

test_that("point roles: ready() is FALSE when only one table exists", {
  con <- pr_con()
  DBI::dbExecute(con, .feature_role_ddl$feature_role)
  expect_false(.feature_role_ready(con))
})

test_that("point roles: create_schema makes both tables with exactly the listed columns", {
  con <- pr_con()
  expect_invisible(out <- .feature_role_create_schema(con))
  expect_identical(out, con)
  expect_identical(pr_cols(con, "feature_role"),
    c("uuid_feature", "water_type", "role", "source_cell", "treatment",
      "lmf_end_member", "end_member_note", "comments"))
  expect_identical(pr_cols(con, "feature_dubious"), c("uuid_feature", "reason", "date_flagged"))
})

test_that("point roles: create_schema is idempotent and keeps existing rows", {
  con <- pr_con()
  .feature_role_create_schema(con)
  DBI::dbExecute(con, "INSERT INTO feature_role (uuid_feature, water_type, role) VALUES ('f-0001', 'surface', 'reference')")
  DBI::dbExecute(con, "INSERT INTO feature_dubious VALUES ('f-0002', 'dry', DATE '2025-01-01')")
  expect_no_error(.feature_role_create_schema(con))
  expect_equal(DBI::dbGetQuery(con, "SELECT count(*) AS n FROM feature_role")$n, 1)
  expect_equal(DBI::dbGetQuery(con, "SELECT count(*) AS n FROM feature_dubious")$n, 1)
})

test_that("point roles: create_schema creates only the missing table and leaves the other alone", {
  con <- pr_con()
  DBI::dbExecute(con, .feature_role_ddl$feature_role)
  DBI::dbExecute(con, "INSERT INTO feature_role (uuid_feature, water_type, role) VALUES ('f-0001', 'surface', 'reference')")
  .feature_role_create_schema(con)
  expect_true(.feature_role_ready(con))
  expect_equal(DBI::dbGetQuery(con, "SELECT count(*) AS n FROM feature_role")$n, 1)
})

test_that("point roles: lmf_end_member defaults to FALSE and the primary key rejects a duplicate feature", {
  con <- pr_con()
  .feature_role_create_schema(con)
  DBI::dbExecute(con, "INSERT INTO feature_role (uuid_feature, water_type, role) VALUES ('f-0001', 'surface', 'reference')")
  expect_false(DBI::dbGetQuery(con, "SELECT lmf_end_member FROM feature_role")$lmf_end_member)
  expect_error(DBI::dbExecute(con, "INSERT INTO feature_role (uuid_feature, water_type, role)
                                    VALUES ('f-0001', 'leachate', 'leachate')"))
  DBI::dbExecute(con, "INSERT INTO feature_dubious VALUES ('f-0001', 'dry', DATE '2025-01-01')")
  expect_error(DBI::dbExecute(con, "INSERT INTO feature_dubious VALUES ('f-0001', 'wet', DATE '2025-01-02')"))
})

test_that("point roles: water_type and role are NOT NULL, source_cell and treatment may be NULL", {
  con <- pr_con()
  .feature_role_create_schema(con)
  expect_error(DBI::dbExecute(con, "INSERT INTO feature_role (uuid_feature, role) VALUES ('f-0001', 'reference')"))
  expect_error(DBI::dbExecute(con, "INSERT INTO feature_role (uuid_feature, water_type) VALUES ('f-0001', 'surface')"))
  expect_no_error(DBI::dbExecute(con, "INSERT INTO feature_role (uuid_feature, water_type, role, source_cell, treatment)
                                       VALUES ('f-0001', 'surface', 'reference', NULL, NULL)"))
})

test_that("point roles: the mutation allowlist includes both tables", {
  expect_true(all(c("feature_role", "feature_dubious") %in% .st_mutate_allowlist))
})

test_that("point roles: db_append writes both tables and logs to change_log", {
  con <- pr_con()
  .feature_role_create_schema(con)
  before <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM change_log")$n
  db_append(con, "feature_role",
            data.frame(uuid_feature = "f-0003", water_type = "leachate", role = "leachate",
                       source_cell = "A", treatment = "raw", stringsAsFactors = FALSE),
            actor = "tester", reason = "assign role")
  db_append(con, "feature_dubious",
            data.frame(uuid_feature = "f-0001", reason = "dry", date_flagged = as.Date("2025-01-01")),
            actor = "tester", reason = "flag")
  expect_equal(DBI::dbGetQuery(con, "SELECT count(*) AS n FROM feature_role")$n, 1)
  expect_equal(DBI::dbGetQuery(con, "SELECT count(*) AS n FROM feature_dubious")$n, 1)
  log <- DBI::dbGetQuery(con, "SELECT tbl, actor, action FROM change_log
                               WHERE tbl IN ('feature_role', 'feature_dubious') ORDER BY tbl")
  expect_equal(DBI::dbGetQuery(con, "SELECT count(*) AS n FROM change_log")$n - before, 2)
  expect_identical(log$tbl, c("feature_dubious", "feature_role"))
  expect_true(all(log$actor == "tester" & log$action == "insert"))
})

# ---- db_checks --------------------------------------------------------------------------

test_that("point roles: both checks are hourly error checks in db_checks_core()", {
  core <- db_checks_core()
  for (nm in c("orphan_feature_role_refs", "vocab_feature_role")) {
    r <- core[core$name == nm, , drop = FALSE]
    expect_equal(nrow(r), 1, info = nm)
    expect_identical(r$tier, "hourly", info = nm)
    expect_identical(r$severity, "error", info = nm)
  }
})

test_that("point roles: both checks pass on a DB without the tables", {
  db <- dbc_db()
  res <- dbc_with(db, function(con) {
    DBI::dbExecute(con, "DROP TABLE feature_role")
    DBI::dbExecute(con, "DROP TABLE feature_dubious")
    expect_false(.feature_role_ready(con))
    db_checks(con, tier = "hourly")
  })
  for (nm in c("orphan_feature_role_refs", "vocab_feature_role")) {
    expect_identical(dbc_row(res, nm)$status, "pass", info = dbc_bad(res))
  }
})

pr_checks <- function(seed) {
  db <- dbc_db()
  dbc_with(db, function(con) {
    seed(con)
    db_checks(con, tier = "hourly")
  })
}

test_that("point roles: the clean fixture's valid rows are not flagged", {
  res <- pr_checks(function(con) NULL)
  expect_identical(dbc_row(res, "orphan_feature_role_refs")$status, "pass", info = dbc_bad(res))
  expect_identical(dbc_row(res, "vocab_feature_role")$status, "pass", info = dbc_bad(res))
})

test_that("point roles: orphan check flags an orphan in each table, keyed by uuid_feature", {
  res <- pr_checks(function(con) {
    DBI::dbExecute(con, "INSERT INTO feature_role (uuid_feature, water_type, role) VALUES ('f-gone1', 'surface', 'reference')")
    DBI::dbExecute(con, "INSERT INTO feature_dubious VALUES ('f-gone2', 'dry', DATE '2025-01-01')")
  })
  r <- dbc_row(res, "orphan_feature_role_refs")
  expect_identical(r$status, "fail")
  expect_identical(r$n, 2L)
  expect_setequal(as.character(r$sample[[1]]$key), c("f-gone1", "f-gone2"))
})

test_that("point roles: vocab check passes valid rows, including NULL source_cell and treatment", {
  res <- pr_checks(function(con) {
    DBI::dbExecute(con, "INSERT INTO feature_role (uuid_feature, water_type, role, source_cell, treatment)
                         VALUES ('f-0002', 'surface', 'reference', NULL, NULL),
                                ('f-0004', 'groundwater', 'receptor', NULL, NULL),
                                ('f-0005', 'leachate', 'containment', 'street sweepings', 'raw')")
    DBI::dbExecute(con, "INSERT INTO feature_dubious VALUES ('f-0002', ' dry in summer ', DATE '2025-01-01')")
  })
  expect_identical(dbc_row(res, "vocab_feature_role")$status, "pass", info = dbc_bad(res))
  expect_identical(dbc_row(res, "orphan_feature_role_refs")$status, "pass", info = dbc_bad(res))
})

test_that("point roles: vocab check flags NULL water_type or role when the column allows it", {
  # water_type / role are NOT NULL in the DDL, so a NULL can only arise if the
  # table was built differently; the check must still treat NULL as invalid.
  db <- dbc_db()
  res <- dbc_with(db, function(con) {
    DBI::dbExecute(con, "DROP TABLE feature_role")
    DBI::dbExecute(con, "CREATE TABLE feature_role (uuid_feature VARCHAR PRIMARY KEY, water_type VARCHAR,
                         role VARCHAR, source_cell VARCHAR, treatment VARCHAR,
                         lmf_end_member BOOLEAN DEFAULT FALSE, end_member_note VARCHAR, comments VARCHAR)")
    DBI::dbExecute(con, "INSERT INTO feature_role (uuid_feature, water_type, role) VALUES
                         ('f-0002', NULL, 'reference'), ('f-0004', 'surface', NULL)")
    db_checks(con, tier = "hourly")
  })
  r <- dbc_row(res, "vocab_feature_role")
  expect_identical(r$status, "fail")
  expect_identical(r$n, 2L)
  expect_setequal(as.character(r$sample[[1]]$key), c("f-0002", "f-0004"))
})

# One bad field per case; the clean fixture's valid rows must stay unflagged.
pr_vocab_cases <- list(
  list(label = "water_type", key = "f-0002",
       sql = "INSERT INTO feature_role (uuid_feature, water_type, role) VALUES ('f-0002', 'rainwater', 'reference')"),
  list(label = "role", key = "f-0002",
       sql = "INSERT INTO feature_role (uuid_feature, water_type, role) VALUES ('f-0002', 'surface', 'upstream')"),
  list(label = "source_cell", key = "f-0002",
       sql = "INSERT INTO feature_role (uuid_feature, water_type, role, source_cell) VALUES ('f-0002', 'leachate', 'leachate', 'C')"),
  list(label = "treatment", key = "f-0002",
       sql = "INSERT INTO feature_role (uuid_feature, water_type, role, treatment) VALUES ('f-0002', 'leachate', 'leachate', 'boiled')"),
  list(label = "blank dubious reason", key = "f-0002",
       sql = "INSERT INTO feature_dubious VALUES ('f-0002', '  ', DATE '2025-01-01')"),
  list(label = "empty dubious reason", key = "f-0002",
       sql = "INSERT INTO feature_dubious VALUES ('f-0002', '', DATE '2025-01-01')")
)

for (cs in pr_vocab_cases) local({
  cs <- cs
  test_that(sprintf("point roles: vocab check flags a bad %s, and only that row", cs$label), {
    res <- pr_checks(function(con) DBI::dbExecute(con, cs$sql))
    dbc_expect_only(res, "vocab_feature_role", cs$key)
  })
})
