# PLAN-23, 17/18 Nov revision: the constants and DDL of 3.1 that the 16 Nov
# tests (test-feature-register-ddl.R) do not cover.
#   R-23.25  .st_core_ddl_feature_mask (dated), .st_core_ddl_feature_predecessor,
#            .st_core_ddl_feature_flow and their CHECKs; .st_core_comments
#   R-23.2   .st_mutate_allowlist gains feature_predecessor and feature_flow;
#            db_append() logs them
#   3.1      .st_core_mask_variants, .st_flow_drives, .st_feature_class_flow,
#            .st_feature_label_sql; st_config("mask_variants_extra")
#   3.5      db_checks_params() gains class_flow; mask_variants follows the core
# Throwaway databases only: in-memory, or seed_db() in a temp dir.

register_tables <- c("feature", "feature_mask", "feature_geometry", "feature_predecessor", "feature_flow")

# An in-memory database holding the five register tables built from the
# package constants (the single source, 3.1). Closed with the caller.
st_reg_mem <- function(env = parent.frame()) {
  con <- DBI::dbConnect(duckdb::duckdb(), config = list(memory_limit = "1GB"))
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE), envir = env)
  DBI::dbExecute(con, .st_core_ddl_feature)
  DBI::dbExecute(con, .st_core_ddl_feature_mask)
  DBI::dbExecute(con, .st_core_ddl_feature_geometry)
  DBI::dbExecute(con, .st_core_ddl_feature_predecessor)
  DBI::dbExecute(con, .st_core_ddl_feature_flow)
  con
}

st_constraints <- function(con, table) {
  DBI::dbGetQuery(con, "SELECT constraint_type, constraint_column_names FROM duckdb_constraints()
                        WHERE table_name = ?", params = list(table))
}

st_indexes <- function(con, table) {
  DBI::dbGetQuery(con, "SELECT index_name FROM duckdb_indexes() WHERE table_name = ?",
                  params = list(table))$index_name
}

# ---- 3.1 vocabulary constants ------------------------------------------------------------

test_that("3.1: .st_core_mask_variants is long, gas_report, common ('old' withdrawn, D17-75; 'common' new, D17-77)", {
  expect_setequal(.st_core_mask_variants, c("long", "gas_report", "common"))
  expect_false("old" %in% .st_core_mask_variants)
  expect_false("EPA" %in% .st_core_mask_variants)   # a deployment variant, not a core one
})

test_that("3.1: .st_flow_drives is gravity and pumped", {
  expect_identical(.st_flow_drives, c("gravity", "pumped"))
})

test_that("3.1 / 2.4: .st_feature_class_flow maps each constrained class to the non-NULL flows it allows", {
  cf <- .st_feature_class_flow
  expect_type(cf, "list")
  expect_false(is.null(names(cf)))
  expect_true(all(names(cf) %in% .st_feature_classes))
  expect_setequal(cf[["bore"]], "groundwater")
  for (cl in c("gas_point", "gas_well", "dust_gauge", "weather_station")) {
    expect_true(cl %in% names(cf), info = cl)
    expect_length(cf[[cl]], 0L)
  }
  for (cl in c("dam", "pond", "drain", "watercourse", "spillway")) {
    expect_setequal(cf[[cl]], c("still", "flowing", "seep"))
  }
  # sampling_point allows any flow: either it is not constrained at all, or it lists every flow
  if ("sampling_point" %in% names(cf)) expect_true(all(.st_feature_flows %in% cf[["sampling_point"]]))
  # a class with no rule is simply absent (unconstrained)
  expect_false("pipe" %in% names(cf))
})

test_that("3.1: .st_feature_label_sql is one SQL string over feature and feature_mask (the label rule's twin, for extracts)", {
  expect_true(checkmate::test_string(.st_feature_label_sql, min.chars = 1))
  expect_match(.st_feature_label_sql, "feature_mask", fixed = TRUE)
  expect_match(.st_feature_label_sql, "common", fixed = TRUE)
})

test_that("3.2: st_config('mask_variants_extra') defaults to no extra variants and does not abort when unset", {
  withr::local_options(list("sampletidy.mask_variants_extra" = NULL))
  expect_no_error(x <- st_config("mask_variants_extra"))
  expect_length(x, 0L)
  withr::local_options(list("sampletidy.mask_variants_extra" = c("EPA", "licence")))
  expect_identical(st_config("mask_variants_extra"), c("EPA", "licence"))
})

# ---- R-23.25: the dated mask ---------------------------------------------------------------

test_that("R-23.25: .st_core_ddl_feature_mask has the 7 columns of 2.1, in order, with uuid PK and uuid_feature/variant NOT NULL", {
  con <- st_reg_mem()
  d <- DBI::dbGetQuery(con, "SELECT column_name, data_type, is_nullable FROM information_schema.columns
                             WHERE table_name = 'feature_mask' ORDER BY ordinal_position")
  expect_identical(d$column_name,
                   c("uuid", "uuid_feature", "variant", "name", "date_start", "date_end", "comments"))
  expect_identical(d$data_type, c("VARCHAR", "VARCHAR", "VARCHAR", "VARCHAR", "DATE", "DATE", "VARCHAR"))
  expect_identical(d$is_nullable[d$column_name %in% c("uuid_feature", "variant")], c("NO", "NO"))
  expect_identical(d$is_nullable[d$column_name %in% c("name", "date_start", "date_end", "comments")],
                   rep("YES", 4))
  k <- st_constraints(con, "feature_mask")
  expect_identical(unlist(k$constraint_column_names[k$constraint_type == "PRIMARY KEY"]), "uuid")
  expect_true(all(c("idx_feature_mask_feature", "idx_feature_mask_variant") %in% st_indexes(con, "feature_mask")))
})

test_that("R-23.25: the dated mask refuses date_end < date_start, accepts date_end == date_start and open ends, keeps its FK", {
  con <- st_reg_mem()
  DBI::dbExecute(con, "INSERT INTO feature (uuid, name, site) VALUES ('f1', 'X.S01', 'X')")
  ins <- function(u, ds, de) DBI::dbExecute(con, sprintf(
    "INSERT INTO feature_mask (uuid, uuid_feature, variant, name, date_start, date_end)
     VALUES ('%s', 'f1', 'common', 'X.C01', %s, %s)", u, ds, de))
  expect_error(ins("m1", "DATE '2025-02-01'", "DATE '2025-01-31'"), "CHECK")
  expect_no_error(ins("m2", "DATE '2025-02-01'", "DATE '2025-02-01'"))
  expect_no_error(ins("m3", "NULL", "DATE '2024-12-31'"))
  expect_no_error(ins("m4", "DATE '2025-03-01'", "NULL"))
  expect_error(DBI::dbExecute(con, "INSERT INTO feature_mask (uuid, uuid_feature, variant, name)
                                    VALUES ('m5', 'f-missing', 'long', 'x')"))
  expect_error(DBI::dbExecute(con, "INSERT INTO feature_mask (uuid, uuid_feature, name) VALUES ('m6', 'f1', 'x')"))
})

# ---- R-23.25: the link tables ---------------------------------------------------------------

test_that("R-23.25: .st_core_ddl_feature_predecessor creates 2.6's 6 columns, PK uuid, NOT NULL source, both indexes, and no FK", {
  con <- st_reg_mem()
  d <- DBI::dbGetQuery(con, "SELECT column_name, data_type, is_nullable FROM information_schema.columns
                             WHERE table_name = 'feature_predecessor' ORDER BY ordinal_position")
  expect_identical(d$column_name,
                   c("uuid", "uuid_feature", "uuid_predecessor", "date_break", "source", "comments"))
  expect_identical(d$data_type, c("VARCHAR", "VARCHAR", "VARCHAR", "DATE", "VARCHAR", "VARCHAR"))
  expect_identical(d$is_nullable, c("NO", "NO", "NO", "YES", "NO", "YES"))
  k <- st_constraints(con, "feature_predecessor")
  expect_identical(unlist(k$constraint_column_names[k$constraint_type == "PRIMARY KEY"]), "uuid")
  expect_false("FOREIGN KEY" %in% k$constraint_type)   # integrity is the check orphan_feature_link
  expect_true(all(c("idx_feature_predecessor_feature", "idx_feature_predecessor_pred") %in%
                    st_indexes(con, "feature_predecessor")))
})

test_that("R-23.25: feature_predecessor refuses a self-link (CHECK) and a missing source; date_break may be NULL", {
  con <- st_reg_mem()
  expect_error(DBI::dbExecute(con, "INSERT INTO feature_predecessor (uuid, uuid_feature, uuid_predecessor, source)
                                    VALUES ('p1', 'fa', 'fa', 'doc')"), "CHECK")
  expect_error(DBI::dbExecute(con, "INSERT INTO feature_predecessor (uuid, uuid_feature, uuid_predecessor)
                                    VALUES ('p2', 'fa', 'fb')"))
  expect_no_error(DBI::dbExecute(con, "INSERT INTO feature_predecessor (uuid, uuid_feature, uuid_predecessor, source)
                                       VALUES ('p3', 'fa', 'fb', 'doc')"))
})

test_that("R-23.25: .st_core_ddl_feature_flow creates 2.6's 9 columns, PK uuid, NOT NULL drive/source, both indexes, and no FK", {
  con <- st_reg_mem()
  d <- DBI::dbGetQuery(con, "SELECT column_name, data_type, is_nullable FROM information_schema.columns
                             WHERE table_name = 'feature_flow' ORDER BY ordinal_position")
  expect_identical(d$column_name, c("uuid", "uuid_from", "uuid_to", "carries", "drive", "date_start",
                                    "date_end", "source", "comments"))
  expect_identical(d$data_type, c("VARCHAR", "VARCHAR", "VARCHAR", "VARCHAR", "VARCHAR", "DATE", "DATE",
                                  "VARCHAR", "VARCHAR"))
  expect_identical(d$is_nullable, c("NO", "NO", "NO", "YES", "NO", "YES", "YES", "NO", "YES"))
  k <- st_constraints(con, "feature_flow")
  expect_identical(unlist(k$constraint_column_names[k$constraint_type == "PRIMARY KEY"]), "uuid")
  expect_false("FOREIGN KEY" %in% k$constraint_type)
  expect_true(all(c("idx_feature_flow_from", "idx_feature_flow_to") %in% st_indexes(con, "feature_flow")))
})

test_that("R-23.25: feature_flow refuses a self-link and date_end < date_start (CHECKs); equal dates and open ends are fine", {
  con <- st_reg_mem()
  ins <- function(u, from, to, ds = "NULL", de = "NULL") DBI::dbExecute(con, sprintf(
    "INSERT INTO feature_flow (uuid, uuid_from, uuid_to, drive, date_start, date_end, source)
     VALUES ('%s', '%s', '%s', 'gravity', %s, %s, 'doc')", u, from, to, ds, de))
  expect_error(ins("w1", "fa", "fa"), "CHECK")
  expect_error(ins("w2", "fa", "fb", "DATE '2025-02-01'", "DATE '2025-01-31'"), "CHECK")
  expect_no_error(ins("w3", "fa", "fb", "DATE '2025-02-01'", "DATE '2025-02-01'"))
  expect_no_error(ins("w4", "fb", "fa"))
  expect_error(DBI::dbExecute(con, "INSERT INTO feature_flow (uuid, uuid_from, uuid_to, source)
                                    VALUES ('w5', 'fa', 'fc', 'doc')"))   # drive NOT NULL
})

# ---- R-23.25: the database's own documentation (2.6, D17-65) ---------------------------------

st_exec_comments <- function(con) {
  for (stmt in .st_core_comments) DBI::dbExecute(con, stmt)
}

test_that("R-23.25: after .st_core_comments every register table has a table comment", {
  con <- st_reg_mem()
  st_exec_comments(con)
  tc <- DBI::dbGetQuery(con, "SELECT table_name, comment FROM duckdb_tables() WHERE table_name IN
                              ('feature', 'feature_mask', 'feature_geometry', 'feature_predecessor', 'feature_flow')")
  expect_setequal(tc$table_name, register_tables)
  expect_true(all(!is.na(tc$comment) & nzchar(trimws(tc$comment))), info = paste(tc$table_name, tc$comment))
})

test_that("R-23.25: every column of the five register tables carries a comment", {
  con <- st_reg_mem()
  st_exec_comments(con)
  cc <- DBI::dbGetQuery(con, "SELECT table_name, column_name, comment FROM duckdb_columns() WHERE table_name IN
                              ('feature', 'feature_mask', 'feature_geometry', 'feature_predecessor', 'feature_flow')")
  missing <- cc[is.na(cc$comment) | !nzchar(trimws(cc$comment)), ]
  expect_equal(nrow(missing), 0L, info = paste(missing$table_name, missing$column_name, sep = ".", collapse = ", "))
})

test_that("R-23.25: the comments say what 2.6 requires (predecessor vs former code; flow joins structures; mask variants and dates; geometry never edited in place)", {
  con <- st_reg_mem()
  st_exec_comments(con)
  tc <- DBI::dbGetQuery(con, "SELECT table_name, comment FROM duckdb_tables()")
  cm <- stats::setNames(tc$comment, tc$table_name)
  expect_match(cm[["feature_predecessor"]], "date_break", fixed = TRUE)
  expect_match(cm[["feature_predecessor"]], "alias arm", ignore.case = TRUE)
  expect_match(cm[["feature_flow"]], "uuid_from", fixed = TRUE)
  expect_match(cm[["feature_flow"]], "uuid_to", fixed = TRUE)
  expect_match(cm[["feature_flow"]], "pipe", ignore.case = TRUE)
  for (v in c("long", "gas_report", "common", "EPA")) expect_match(cm[["feature_mask"]], v, fixed = TRUE)
  expect_match(cm[["feature_mask"]], "date", ignore.case = TRUE)
  expect_match(cm[["feature_geometry"]], "in place", ignore.case = TRUE)
  for (r in .st_geometry_roles) expect_match(cm[["feature_geometry"]], r, fixed = TRUE)
})

test_that("R-23.25: .st_core_comments survives a rebuild: run again after DROP/CREATE, the comments are back", {
  con <- st_reg_mem()
  st_exec_comments(con)
  DBI::dbExecute(con, "DROP TABLE feature_flow")
  DBI::dbExecute(con, .st_core_ddl_feature_flow)
  expect_true(is.na(DBI::dbGetQuery(con, "SELECT comment FROM duckdb_tables() WHERE table_name = 'feature_flow'")$comment) ||
                !nzchar(DBI::dbGetQuery(con, "SELECT comment FROM duckdb_tables() WHERE table_name = 'feature_flow'")$comment))
  expect_no_error(st_exec_comments(con))   # idempotent: COMMENT ON just sets the text again
  expect_true(nzchar(DBI::dbGetQuery(con, "SELECT comment FROM duckdb_tables() WHERE table_name = 'feature_flow'")$comment))
})

# ---- R-23.2: the allowlist ---------------------------------------------------------------------

test_that("R-23.2: feature_predecessor and feature_flow join .st_mutate_allowlist; feature_geometry and feature_mask stay", {
  expect_true(all(c("feature_predecessor", "feature_flow", "feature_geometry", "feature_mask") %in% .st_mutate_allowlist))
  expect_no_error(.st_validate_table("feature_predecessor"))
  expect_no_error(.st_validate_table("feature_flow"))
})

test_that("R-23.2: db_append() on feature_predecessor / feature_flow / feature_mask writes one change_log insert keyed by the row's uuid", {
  s <- t23_setup()
  n0 <- DBI::dbGetQuery(s$con, "SELECT count(*) AS n FROM change_log")$n
  db_append(s$con, "feature_predecessor",
            tibble::tibble(uuid = "fp-new", uuid_feature = "f-0005", uuid_predecessor = "f-0004",
                           date_break = as.Date("2025-01-01"), source = "test doc"),
            actor = "tester", reason = "append predecessor")
  db_append(s$con, "feature_flow",
            tibble::tibble(uuid = "ff-new", uuid_from = "f-0001", uuid_to = "f-0002", drive = "pumped",
                           source = "test doc"),
            actor = "tester", reason = "append flow")
  db_append(s$con, "feature_mask",
            tibble::tibble(uuid = "fm-new", uuid_feature = "f-0004", variant = "long", name = "Fourth creek"),
            actor = "tester", reason = "append mask")
  for (x in list(c("feature_predecessor", "fp-new"), c("feature_flow", "ff-new"), c("feature_mask", "fm-new"))) {
    lg <- t23_log_rows(s$con, x[[1]], x[[2]])
    expect_equal(nrow(lg), 1L, info = x[[1]])
    expect_identical(lg$action, "insert", info = x[[1]])
    expect_identical(lg$actor, "tester", info = x[[1]])
  }
  expect_identical(DBI::dbGetQuery(s$con, "SELECT count(*) AS n FROM change_log")$n, n0 + 3)
})

test_that("R-23.2: db_update(feature_mask, uuid =) is keyed by the mask row's uuid now, with an old/new change_log row", {
  s <- t23_setup()
  db_update(s$con, "feature_mask", uuid = "fm-0001", changes = list(name = "Test surface one"),
            actor = "tester", reason = "rename long")
  expect_identical(DBI::dbGetQuery(s$con, "SELECT name FROM feature_mask WHERE uuid = 'fm-0001'")$name,
                   "Test surface one")
  lg <- t23_log_rows(s$con, "feature_mask", "fm-0001")
  expect_equal(nrow(lg), 1L)
  expect_identical(lg$field, "name")
  expect_identical(lg$old, "Test Surface 01")
})

# ---- 3.5: db_checks_params() ---------------------------------------------------------------------

test_that("3.5: db_checks_params() carries class_flow (default .st_feature_class_flow); mask_variants follows the core", {
  p <- db_checks_params()
  expect_true("class_flow" %in% names(p))
  expect_identical(p$class_flow, .st_feature_class_flow)
  expect_setequal(p$mask_variants, .st_core_mask_variants)
  p2 <- db_checks_params(class_flow = list(bore = "groundwater"))
  expect_identical(p2$class_flow, list(bore = "groundwater"))
})
