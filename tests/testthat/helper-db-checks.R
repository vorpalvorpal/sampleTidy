# Helpers for the PLAN-22 Part A tests (test-db-checks*.R): standing DB checks.
# Only DEFINES functions - no top-level calls (beyond constants).
#
# dbc_db() is a CLEAN fixture: seed_db() (helper-db.R, unchanged) plus
#   * the declared constraints a migrated live DB carries (FKs on
#     analysis/sample/lab_method/feature_mask/analyte_mask; seed_db() declares
#     none) - so `expected_constraints_present` can pass and FK-enforced
#     orphans genuinely cannot be seeded;
#   * the tables the checks read that seed_db() lacks: analyte_mask and the
#     PLAN-19 QC tables (helper-qc.R's qc_create_tables());
#   * one representative row in each of asset / ingest_sighting / lab_qc_report
#     / lab_qc_outlier / sample_lab_id / qc_feature / change_log /
#     review_queue_candidate, a resolved review item and a migration marker
#     (1072), so every check reads at least one row it must NOT flag;
#   * two views: a representative `v_measurement` (the columns the view checks
#     read: uuid_analysis, uuid_feature, date, analyte_name, preference_rank)
#     and `v_feature_dates`;
#   * the data fix-ups that make seed_db()'s rows satisfy every invariant (each
#     says which check it serves). The checks are NOT weakened to fit the
#     fixture; the fixture is made richer to fit the checks.
#
# The template is built once per R session and copied per test (a closed
# DuckDB file copies cheaply), so the table-driven tests stay fast.

# ---- the pinned check catalogue (PLAN-22 A2; names/severities as checks-draft.R) ----

dbc_hourly_names <- c(
  "view_nonempty", "schema_version_core_current",
  "orphan_alias_feature", "orphan_sample_project", "orphan_project_refs",
  "orphan_asset_refs", "orphan_ingest_sighting", "orphan_qc_refs",
  "orphan_registry_refs", "orphan_review_open_refs",
  "dup_analysis_sample_method", "dup_sample_identity_null_datetime",
  "dup_asset_hash", "dup_lab_method_key",
  "alias_self_arm", "alias_pending_consistent", "alias_key_normalised",
  "vocab_lab_method_fraction", "vocab_feature_alias_kind", "vocab_ingest_state",
  "vocab_review_status", "vocab_mask_variant", "vocab_feature_flow",
  "analysis_value_shape", "hash_format",
  "sample_date_plausible", "sample_date_datetime_agree", "date_windows_ordered",
  "feature_coords"
)
dbc_migration_only_names <- c(
  "measurement_view_coverage", "measurement_view_no_fanout",
  "measurement_rank1_unique", "expected_constraints_present",
  "schema_version_no_duplicates", "schema_version_core_contiguous",
  "fraction_matches_code"
)
dbc_on_demand_names <- c(
  "review_resolved_dangling", "change_log_dangling_source_hash",
  "change_log_shape", "alias_window_ambiguous", "sample_in_feature_window",
  "feature_geom_matches_lonlat"
)
dbc_all_names <- c(dbc_hourly_names, dbc_migration_only_names, dbc_on_demand_names)

dbc_warn_names <- c(
  "review_resolved_dangling", "change_log_dangling_source_hash",
  "dup_sample_identity_null_datetime", "alias_key_normalised",
  "alias_window_ambiguous", "fraction_matches_code", "vocab_mask_variant",
  "vocab_feature_flow", "change_log_shape", "sample_date_datetime_agree",
  "sample_in_feature_window", "feature_coords", "feature_geom_matches_lonlat"
)

dbc_result_cols <- c("name", "tier", "severity", "status", "n", "ms", "sample", "message")

# ---- small utilities ---------------------------------------------------------------

#' A deterministic 32-lower-hex (xxHash128-shaped) string from an integer.
dbc_hex <- function(i) sprintf("%032x", as.integer(i))

dbc_exec <- function(con, sql, ...) {
  DBI::dbExecute(con, sql, params = if (length(list(...))) list(...) else NULL)
}

#' Run fn(con) against a DB file on a read-write connection, then disconnect.
dbc_with <- function(db, fn) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = FALSE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  fn(con)
}

#' db_checks() on a DB file (tier "all" by default, so every check runs).
dbc_run <- function(db, tier = "all", ...) {
  dbc_with(db, function(con) db_checks(con, tier = tier, ...))
}

dbc_row <- function(res, name) res[res$name == name, , drop = FALSE]

#' A summary of every non-passing check, for failure messages.
dbc_bad <- function(res) {
  bad <- res[res$status != "pass", , drop = FALSE]
  if (nrow(bad) == 0) return("(none)")
  paste0(bad$name, "=", bad$status, "(n=", bad$n, ")",
         ifelse(is.na(bad$message) | bad$message == "", "", paste0(": ", bad$message)),
         collapse = "; ")
}

#' Assert exactly `name` is non-passing in `res`: status "fail", n == `n`,
#' and `key` (a substring) appears in the sample's `key` column.
dbc_expect_only <- function(res, name, key, n = 1L) {
  bad <- res$name[res$status != "pass"]
  testthat::expect_identical(bad, name, info = dbc_bad(res))
  r <- dbc_row(res, name)
  testthat::expect_equal(nrow(r), 1L)
  if (nrow(r) != 1L) return(invisible(NULL))
  testthat::expect_identical(r$status, "fail", info = dbc_bad(res))
  testthat::expect_identical(r$n, as.integer(n), info = dbc_bad(res))
  s <- r$sample[[1]]
  testthat::expect_s3_class(s, "data.frame")
  testthat::expect_true("key" %in% names(s), info = paste(names(s), collapse = ","))
  if ("key" %in% names(s)) {
    testthat::expect_true(any(grepl(key, as.character(s$key), fixed = TRUE)),
                          info = paste0("want key containing '", key, "', got: ",
                                        paste(s$key, collapse = " | ")))
  }
  invisible(r)
}

#' expect_error() that cannot be satisfied by the function under test not
#' existing yet ("could not find function"); optionally matches `pattern`.
dbc_expect_error <- function(expr, pattern = NULL) {
  e <- testthat::expect_error(expr)
  if (!is.null(e)) {
    msg <- conditionMessage(e)
    testthat::expect_false(grepl("could not find function", msg, fixed = TRUE), info = msg)
    if (!is.null(pattern)) testthat::expect_match(msg, pattern, fixed = TRUE)
  }
  invisible(e)
}

# ---- views ----------------------------------------------------------------------------

#' A representative v_measurement: one row per analysis on a resolved alias
#' with a resolved analyte (INNER JOINs, as the live views), Sydney-day `date`,
#' preference_rank = row_number over (feature, day, analyte). `where` filters
#' the analyses (used to seed a coverage violation); `extra` is UNION ALL'd on.
dbc_v_measurement_sql <- function(where = "TRUE", extra = NULL) {
  base <- paste0("
    SELECT a.uuid AS uuid_analysis, s.uuid AS uuid_sample, f.uuid AS uuid_feature,
           f.name AS feature,
           CAST(timezone('Australia/Sydney', timezone('UTC', coalesce(s.datetime, s.date))) AS DATE) AS date,
           an.name AS analyte_name, a.value, an.units,
           row_number() OVER (
             PARTITION BY f.uuid,
               CAST(timezone('Australia/Sydney', timezone('UTC', coalesce(s.datetime, s.date))) AS DATE),
               an.uuid
             ORDER BY a.rl_low NULLS LAST, s.uuid, a.uuid) AS preference_rank
    FROM analysis a
    JOIN \"sample\" s ON s.uuid = a.uuid_sample
    JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
    JOIN feature f ON f.uuid = fa.uuid_feature
    JOIN lab_method lm ON lm.uuid = a.uuid_lab
    JOIN analyte an ON an.uuid = lm.uuid_analyte
    WHERE ", where)
  if (is.null(extra)) return(base)
  paste0("SELECT * FROM (", base, ") UNION ALL ", extra)
}

dbc_set_v_measurement <- function(con, ...) {
  DBI::dbExecute(con, paste0("CREATE OR REPLACE VIEW v_measurement AS ", dbc_v_measurement_sql(...)))
}

# ---- the clean fixture ----------------------------------------------------------------

.dbc_sub1 <- function(ddl, from, to) {
  out <- sub(from, to, ddl, fixed = TRUE)
  if (identical(out, ddl)) stop("dbc fixture: DDL anchor not found: ", from)
  out
}

#' Re-create seed_db()'s tables with the FKs a live DB declares (DuckDB cannot
#' ALTER TABLE ADD FOREIGN KEY). Column lists come from helper-db.R's DDL.
.dbc_add_fks <- function(con) {
  ddl <- .st_test_core_ddl
  tabs <- c("analysis", "sample", "lab_method", "feature_mask")
  for (t in tabs) {
    DBI::dbExecute(con, sprintf("CREATE TEMP TABLE dbc_keep_%s AS SELECT * FROM \"%s\"", t, t))
  }
  for (t in tabs) DBI::dbExecute(con, sprintf("DROP TABLE \"%s\"", t))
  fm <- .dbc_sub1(ddl$feature_mask, "uuid_feature VARCHAR,", "uuid_feature VARCHAR REFERENCES feature(uuid),")
  lm <- .dbc_sub1(ddl$lab_method, "uuid_analyte VARCHAR,", "uuid_analyte VARCHAR REFERENCES analyte(uuid),")
  sm <- .dbc_sub1(ddl$sample, "uuid_feature_alias VARCHAR NOT NULL,",
                  "uuid_feature_alias VARCHAR NOT NULL REFERENCES feature_alias(uuid),")
  an <- .dbc_sub1(ddl$analysis, "uuid_sample VARCHAR,", "uuid_sample VARCHAR REFERENCES \"sample\"(uuid),")
  an <- .dbc_sub1(an, "uuid_lab VARCHAR,", "uuid_lab VARCHAR REFERENCES lab_method(uuid),")
  for (d in c(fm, lm, sm, an)) DBI::dbExecute(con, d)
  for (d in .st_test_core_indexes) DBI::dbExecute(con, d)
  for (t in rev(tabs)) {
    DBI::dbExecute(con, sprintf("INSERT INTO \"%s\" SELECT * FROM dbc_keep_%s", t, t))
    DBI::dbExecute(con, sprintf("DROP TABLE dbc_keep_%s", t))
  }
  DBI::dbExecute(con, "
    CREATE TABLE analyte_mask (
      uuid_analyte VARCHAR REFERENCES analyte(uuid),
      variant VARCHAR,
      name VARCHAR)")
  invisible(con)
}

.dbc_build <- function(path) {
  dir <- dirname(path)
  src <- seed_db(dir = dir)  # writes <dir>/seed.duckdb
  if (!identical(basename(src), basename(path))) stopifnot(file.rename(src, path))
  con <- DBI::dbConnect(duckdb::duckdb(), path, read_only = FALSE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  qc_create_tables(con)   # qc_feature, sample_lab_id, lab_qc_report, lab_qc_outlier
  # The live `feature` carries a soft project link (orphan_registry_refs reads
  # it); seed_db()'s DDL omits it. Added before any FK makes `feature` a parent.
  DBI::dbExecute(con, "ALTER TABLE feature ADD COLUMN uuid_project VARCHAR")
  .dbc_add_fks(con)

  # hash_format: seed_db's 'legacy-hash-XX' is not xxHash128-shaped.
  dbc_exec(con, "UPDATE ingest_file SET hash = ? WHERE hash = 'legacy-hash-XX'", dbc_hex(1))
  # alias_window_ambiguous: seed_db's ambiguity fixtures as live curates them -
  # an ambiguous key is suggest-only (auto_assign FALSE, as migration 001 marks
  # it) and a reused key's two arms have disjoint date windows.
  dbc_exec(con, "UPDATE feature_alias SET auto_assign = FALSE WHERE uuid IN ('fa-0005', 'fa-0006')")
  dbc_exec(con, "UPDATE feature_alias SET date_end = DATE '2020-06-30' WHERE uuid = 'fa-0007'")
  dbc_exec(con, "UPDATE feature_alias SET date_start = DATE '2020-07-01' WHERE uuid = 'fa-0008'")
  # vocab_feature_flow: 'surface' is not a flow (groundwater/still/seep/flowing).
  dbc_exec(con, "UPDATE feature SET flow = 'flowing' WHERE flow = 'surface'")
  # vocab_mask_variant: 'epa' is a deployment variant, not a core one.
  dbc_exec(con, "UPDATE feature_mask SET variant = 'old' WHERE variant = 'epa'")
  # feature_geom_matches_lonlat: geometry agrees with lon/lat.
  dbc_exec(con, "UPDATE feature SET geom_wkt = 'POINT (' || CAST(lon AS VARCHAR) || ' ' || CAST(lat AS VARCHAR) || ')'")

  # alias_pending_consistent: each pending alias has an open review item.
  # orphan_review_open_refs: it points at rows that exist.
  dbc_exec(con, "INSERT INTO review_queue (uuid, created_at, kind, work_order, source_hash, status, uuid_alias)
                 VALUES ('rq-0001', TIMESTAMP '2025-05-10 08:00:00', 'unknown_feature', 'XX1234567', ?, 'open', 'fa-0010'),
                        ('rq-0002', TIMESTAMP '2025-05-10 08:00:00', 'unknown_feature', 'XX1234567', ?, 'open', 'fa-0023')",
           dbc_hex(1), dbc_hex(1))
  dbc_exec(con, "INSERT INTO review_queue_candidate (uuid, uuid_review, uuid_feature, kind, rank)
                 VALUES ('rqc-0001', 'rq-0002', 'f-0012', 'structural', 1)")
  # vocab_review_status / review_resolved_dangling: a resolved item, fully
  # resolved, whose alias still exists.
  dbc_exec(con, "INSERT INTO review_queue (uuid, created_at, kind, status, resolution, resolved_by, resolved_at, uuid_alias)
                 VALUES ('rq-0003', TIMESTAMP '2025-04-01 00:00:00', 'unknown_feature', 'resolved', 'accepted', 'test',
                         TIMESTAMP '2025-04-02 00:00:00', 'fa-0004')")

  # One row in each linked table, every link resolving.
  dbc_exec(con, "INSERT INTO asset (uuid, name, uuid_project, hash) VALUES
                 ('as-0001', 'XX1234567.csv', 'p-0001', ?), ('as-0002', 'XX1234567_QCI.pdf', 'p-0001', ?)",
           dbc_hex(2), dbc_hex(3))
  dbc_exec(con, "UPDATE ingest_file SET uuid_asset = 'as-0001' WHERE hash = ?", dbc_hex(1))
  dbc_exec(con, "INSERT INTO ingest_sighting (hash, path, seen_at) VALUES (?, '/inbox/XX1234567.csv', TIMESTAMP '2025-05-26 00:00:00')",
           dbc_hex(1))
  dbc_exec(con, "INSERT INTO lab_qc_report (uuid, uuid_asset, work_order, kind, status)
                 VALUES ('lqr-0001', 'as-0002', 'XX1234567', 'QCI', 'parsed')")
  dbc_exec(con, "INSERT INTO lab_qc_outlier (uuid, uuid_report, work_order, uuid_sample)
                 VALUES ('lqo-0001', 'lqr-0001', 'XX1234567', 's-0001')")
  dbc_exec(con, "INSERT INTO sample_lab_id (uuid_sample, work_order, lab_id, client_id, source_hash)
                 VALUES ('s-0001', 'XX1234567', 'XX1234567-001', 'T.S01', ?)", dbc_hex(1))
  dbc_exec(con, "INSERT INTO qc_feature (uuid_feature, qc_type, uuid_parent, date_start)
                 VALUES ('f-0013', 'field_blank', 'f-0001', DATE '2025-01-01')")
  dbc_exec(con, "INSERT INTO change_log (uuid, \"at\", actor, action, tbl, uuid_row, reason, source_hash)
                 VALUES ('cl-0001', TIMESTAMP '2025-05-26 00:00:00', 'test', 'insert', 'analysis', 'an-0001', 'seed', ?)",
           dbc_hex(1))
  dbc_exec(con, "INSERT INTO analyte_mask (uuid_analyte, variant, name) VALUES ('a-0002', 'long', 'Fluoride (F)')")
  # fraction_matches_code: one method that carries a fraction, correctly.
  dbc_exec(con, "INSERT INTO lab_method (uuid, uuid_analyte, name, method, organisation, rl_low, units, fraction)
                 VALUES ('lm-0013', 'a-0002', 'Fluoride (filtered)', 'EG020F: Dissolved Metals by ICP-MS', 'ALS', 0.1, 'mg/L', 'dissolved')")
  # A second analysis visible in v_measurement (pH on s-0004 at f-0001), so a
  # view that drops one analysis is still non-empty.
  dbc_exec(con, "INSERT INTO analysis (uuid, uuid_sample, uuid_lab, value, quantified, rl_low)
                 VALUES ('an-0006', 's-0004', 'lm-0001', 7.2, TRUE, 0.01)")
  # A migration marker (>= 1000): ignored by the core-version checks.
  dbc_exec(con, "INSERT INTO schema_version (version, applied_at) VALUES (1072, TIMESTAMP '2026-10-22 00:00:00')")

  dbc_set_v_measurement(con)
  DBI::dbExecute(con, "
    CREATE VIEW v_feature_dates AS
    SELECT f.uuid AS uuid_feature, f.name, min(s.date) AS first_date, max(s.date) AS last_date
    FROM feature f
    JOIN feature_alias fa ON fa.uuid_feature = f.uuid
    JOIN \"sample\" s ON s.uuid_feature_alias = fa.uuid
    GROUP BY f.uuid, f.name")
  invisible(path)
}

.dbc_template_env <- new.env(parent = emptyenv())

#' A fresh copy of the clean db-checks fixture, cleaned up with the caller.
dbc_db <- function(env = parent.frame()) {
  tpl <- .dbc_template_env$path
  if (is.null(tpl) || !file.exists(tpl)) {
    tdir <- file.path(tempdir(), paste0("dbc-template-", Sys.getpid()))
    unlink(tdir, recursive = TRUE)
    dir.create(tdir, recursive = TRUE)
    tpl <- file.path(tdir, "dbc.duckdb")
    .dbc_build(tpl)
    .dbc_template_env$path <- tpl
  }
  dir <- withr::local_tempdir(.local_envir = env)
  path <- file.path(dir, "dbc.duckdb")
  stopifnot(file.copy(tpl, path))
  path
}

# ---- one seeded violation per check ------------------------------------------------------
#
# Each case seeds EXACTLY ONE offender for `check` into a clean dbc_db() and
# names a substring of that offender's `key` (the identifying column every
# check's result carries). `params` (optional) are passed to
# db_checks_params(). Checks guarded by an FK the fixture declares cannot be
# seeded and have no case: analysis.uuid_sample / uuid_lab, sample ->
# feature_alias, lab_method -> analyte, feature_mask -> feature, analyte_mask ->
# analyte and review_queue_candidate -> review_queue are FK-enforced (DuckDB
# rejects the INSERT), which is why the catalogue excludes them (PLAN-22 A2).
#
# Key conventions pinned here (a key is a VARCHAR; composite keys contain the
# identifying uuid(s)): a row's uuid for row-level checks; the view name for
# view_nonempty; the hash for hash/ingest checks; the missing/duplicated/found
# version number for schema_version_*; the feature uuid for alias_self_arm and
# measurement_rank1_unique; the sample uuid (with the method) for
# dup_analysis_sample_method; the alias uuid for
# dup_sample_identity_null_datetime; a member's natural key (method name) for
# dup_lab_method_key; the variant for vocab_mask_variant; the index/constraint
# name for expected_constraints_present.

dbc_new_sample <- function(con, uuid, alias = "fa-0002", date = "2025-06-01",
                           datetime = "2025-05-31 23:00:00", project = "p-0001") {
  dbc_exec(con, "INSERT INTO \"sample\" (uuid, uuid_feature_alias, uuid_project, date, datetime, organisation)
                 VALUES (?, ?, ?, CAST(? AS TIMESTAMP), CAST(? AS TIMESTAMP), 'ALS')",
           uuid, alias, project, date, datetime)
}

dbc_alias <- function(con, uuid, feature, name, key, kind, auto = FALSE) {
  dbc_exec(con, "INSERT INTO feature_alias (uuid, uuid_feature, name, alias_key, kind, auto_assign)
                 VALUES (?, ?, ?, ?, ?, ?)", uuid, feature, name, key, kind, auto)
}

# v_measurement rebuilt over a materialised copy of its clean rows plus `extra`
# (a view cannot read its own previous definition).
dbc_v_measurement_plus <- function(con, extra) {
  DBI::dbExecute(con, "CREATE TABLE dbc_vm AS SELECT * FROM v_measurement")
  dbc_set_v_measurement(con, extra = extra)
}

dbc_violation_cases <- list(
  list(check = "view_nonempty", key = "v_empty", label = "an empty view",
       seed = function(con) DBI::dbExecute(con, "CREATE VIEW v_empty AS SELECT uuid FROM feature WHERE FALSE")),
  list(check = "view_nonempty", key = "v_broken", label = "a view that errors when queried",
       seed = function(con) {
         DBI::dbExecute(con, "CREATE TABLE dbc_gone (a INTEGER)")
         DBI::dbExecute(con, "INSERT INTO dbc_gone VALUES (1)")
         DBI::dbExecute(con, "CREATE VIEW v_broken AS SELECT a FROM dbc_gone")
         DBI::dbExecute(con, "DROP TABLE dbc_gone")
       }),
  list(check = "measurement_view_coverage", key = "an-0006", label = "v_measurement drops an analysis",
       seed = function(con) dbc_set_v_measurement(con, where = "a.uuid <> 'an-0006'")),
  list(check = "measurement_view_no_fanout", key = "an-0001", label = "v_measurement fans one analysis out",
       seed = function(con) dbc_v_measurement_plus(con, "
         SELECT uuid_analysis, uuid_sample, uuid_feature, feature, date, analyte_name, value, units,
                2 AS preference_rank FROM dbc_vm WHERE uuid_analysis = 'an-0001'")),
  list(check = "measurement_rank1_unique", key = "f-0001", label = "two rank-1 rows for one feature/day/analyte",
       seed = function(con) dbc_v_measurement_plus(con, "
         SELECT 'an-ghost', uuid_sample, uuid_feature, feature, date, analyte_name, value, units,
                preference_rank FROM dbc_vm WHERE uuid_analysis = 'an-0001'")),
  list(check = "expected_constraints_present", key = "ux_sample_identity", label = "ux_sample_identity dropped",
       seed = function(con) DBI::dbExecute(con, "DROP INDEX ux_sample_identity")),
  list(check = "schema_version_no_duplicates", key = "8", label = "a schema_version marker recorded twice",
       seed = function(con) DBI::dbExecute(con, "INSERT INTO schema_version VALUES (8, TIMESTAMP '2026-01-01 00:00:00')")),
  list(check = "schema_version_core_current", key = "9", label = "core ladder ahead of this build",
       seed = function(con) DBI::dbExecute(con, "INSERT INTO schema_version VALUES (9, TIMESTAMP '2026-01-01 00:00:00')")),
  list(check = "schema_version_core_contiguous", key = "5", label = "a core version missing from 1..N",
       seed = function(con) DBI::dbExecute(con, "DELETE FROM schema_version WHERE version = 5")),
  list(check = "orphan_alias_feature", key = "fa-orphan", label = "alias pointing at a missing feature",
       seed = function(con) dbc_alias(con, "fa-orphan", "f-gone", "T.GONE", "t.gone", "historical_code")),
  list(check = "orphan_sample_project", key = "s-orphan", label = "sample pointing at a missing project",
       seed = function(con) dbc_new_sample(con, "s-orphan", project = "p-gone")),
  list(check = "orphan_project_refs", key = "p-x", label = "project whose uuid_root is missing",
       seed = function(con) DBI::dbExecute(con, "INSERT INTO project (uuid, uuid_root, name, type)
                                                 VALUES ('p-x', 'p-gone', 'ZZ0000001', 'Work order')")),
  list(check = "orphan_asset_refs", key = "as-x", label = "asset pointing at a missing project",
       seed = function(con) dbc_exec(con, "INSERT INTO asset (uuid, name, uuid_project, hash)
                                           VALUES ('as-x', 'x.pdf', 'p-gone', ?)", dbc_hex(901))),
  list(check = "orphan_ingest_sighting", key = dbc_hex(902), label = "sighting of an unknown hash",
       seed = function(con) dbc_exec(con, "INSERT INTO ingest_sighting VALUES (?, '/x', TIMESTAMP '2025-01-01 00:00:00')",
                                     dbc_hex(902))),
  list(check = "orphan_qc_refs", key = "s-gone", label = "sample_lab_id pointing at a missing sample",
       seed = function(con) DBI::dbExecute(con, "INSERT INTO sample_lab_id
                                                 VALUES ('s-gone', 'XX1234567', 'XX1234567-099', 'T.S01', NULL)")),
  list(check = "orphan_registry_refs", key = "lm-x", label = "lab_method pointing at a missing project",
       seed = function(con) DBI::dbExecute(con, "INSERT INTO lab_method (uuid, uuid_analyte, name, method, organisation, uuid_project)
                                                 VALUES ('lm-x', 'a-0003', 'EC (site)', 'EA999: EC', 'ALS', 'p-gone')")),
  list(check = "orphan_review_open_refs", key = "rq-x", label = "open review item pointing at a deleted analysis",
       seed = function(con) {
         DBI::dbExecute(con, "INSERT INTO analysis (uuid, uuid_sample, uuid_lab, value, quantified, rl_low)
                              VALUES ('an-del', 's-0004', 'lm-0003', 1.5, TRUE, 1)")
         DBI::dbExecute(con, "INSERT INTO review_queue (uuid, created_at, kind, status, uuid_existing)
                              VALUES ('rq-x', TIMESTAMP '2025-06-01 00:00:00', 'value_conflict', 'open', 'an-del')")
         DBI::dbExecute(con, "DELETE FROM analysis WHERE uuid = 'an-del'")
       }),
  list(check = "orphan_review_open_refs", key = "rqc-x", label = "open review candidate naming a missing feature",
       seed = function(con) DBI::dbExecute(con, "INSERT INTO review_queue_candidate (uuid, uuid_review, uuid_feature, kind, rank)
                                                 VALUES ('rqc-x', 'rq-0002', 'f-gone', 'structural', 2)")),
  list(check = "review_resolved_dangling", key = "rq-x", label = "resolved review item whose alias was deleted",
       seed = function(con) DBI::dbExecute(con, "INSERT INTO review_queue
                                                   (uuid, created_at, kind, status, resolution, resolved_by, resolved_at, uuid_alias)
                                                 VALUES ('rq-x', TIMESTAMP '2025-04-01 00:00:00', 'unknown_feature', 'resolved',
                                                         'merged', 'test', TIMESTAMP '2025-04-02 00:00:00', 'fa-gone')")),
  list(check = "change_log_dangling_source_hash", key = dbc_hex(903), label = "change_log provenance hash with no file",
       seed = function(con) dbc_exec(con, "INSERT INTO change_log (uuid, \"at\", actor, action, tbl, uuid_row, reason, source_hash)
                                           VALUES ('cl-x', TIMESTAMP '2025-06-01 00:00:00', 'test', 'insert', 'analysis',
                                                   'an-0001', 'x', ?)", dbc_hex(903))),
  list(check = "dup_analysis_sample_method", key = "s-0001", label = "two analyses on one sample + lab_method",
       seed = function(con) DBI::dbExecute(con, "INSERT INTO analysis (uuid, uuid_sample, uuid_lab, value, quantified, rl_low)
                                                 VALUES ('an-dup', 's-0001', 'lm-0002', 100, FALSE, 100)")),
  list(check = "dup_sample_identity_null_datetime", key = "fa-0002", label = "NULL-datetime sample identity pair",
       seed = function(con) {
         dbc_new_sample(con, "s-n1", datetime = NA)
         dbc_new_sample(con, "s-n2", datetime = NA)
       }),
  list(check = "dup_asset_hash", key = dbc_hex(904), label = "two assets sharing a hash",
       seed = function(con) dbc_exec(con, "INSERT INTO asset (uuid, name, uuid_project, hash) VALUES
                                           ('as-x1', 'a.pdf', 'p-0001', ?), ('as-x2', 'b.pdf', 'p-0001', ?)",
                                     dbc_hex(904), dbc_hex(904))),
  list(check = "dup_lab_method_key", key = "pH Value", label = "two lab_methods with one natural key",
       seed = function(con) DBI::dbExecute(con, "INSERT INTO lab_method (uuid, uuid_analyte, name, method, organisation, rl_low, units)
                                                 VALUES ('lm-dup', 'a-0001', 'pH Value', 'EA005P: pH by PC Titrator', 'ALS', 0.01, 'pH')")),
  list(check = "alias_self_arm", key = "f-0002", label = "a feature with two self aliases",
       seed = function(con) dbc_alias(con, "fa-self2", "f-0002", "T.S02", "t.s02", "self", auto = TRUE)),
  list(check = "alias_self_arm", key = "f-new", label = "a feature with no self alias",
       seed = function(con) DBI::dbExecute(con, "INSERT INTO feature (uuid, name, site, flow, matrix, geom_wkt, lon, lat)
                                                 VALUES ('f-new', 'T.S10', 'T', 'flowing', 'water', 'POINT (150.2 -33.2)', 150.2, -33.2)")),
  list(check = "alias_pending_consistent", key = "fa-pf", label = "a pending alias that has a feature",
       seed = function(con) {
         dbc_alias(con, "fa-pf", "f-0001", "T S01x", "t s01x", "pending")
         DBI::dbExecute(con, "INSERT INTO review_queue (uuid, created_at, kind, status, uuid_alias)
                              VALUES ('rq-pf', TIMESTAMP '2025-06-01 00:00:00', 'unknown_feature', 'open', 'fa-pf')")
       }),
  list(check = "alias_pending_consistent", key = "fa-pn", label = "a pending alias with no open review item",
       seed = function(con) dbc_alias(con, "fa-pn", NA, "T.S99", "t.s99", "pending")),
  list(check = "alias_key_normalised", key = "fa-key", label = "alias_key not the normalised name",
       seed = function(con) dbc_alias(con, "fa-key", "f-0001", "T.Site One", "wrong", "descriptive")),
  list(check = "alias_window_ambiguous", key = "fa-amb", label = "two auto arms of one key, overlapping, different features",
       seed = function(con) {
         dbc_alias(con, "fa-amb1", "f-0001", "T.X", "t.x", "historical_code", auto = TRUE)
         dbc_alias(con, "fa-amb2", "f-0002", "T.X", "t.x", "historical_code", auto = TRUE)
       }),
  list(check = "vocab_lab_method_fraction", key = "lm-fr", label = "lab_method.fraction outside the vocabulary",
       seed = function(con) DBI::dbExecute(con, "INSERT INTO lab_method (uuid, uuid_analyte, name, method, organisation, fraction)
                                                 VALUES ('lm-fr', 'a-0002', 'Fluoride (odd)', 'EG020F: Dissolved Metals', 'ALS', 'Dissolved')")),
  list(check = "fraction_matches_code", key = "lm-fc", label = "fraction contradicting the method code",
       seed = function(con) DBI::dbExecute(con, "INSERT INTO lab_method (uuid, uuid_analyte, name, method, organisation, fraction)
                                                 VALUES ('lm-fc', 'a-0002', 'Fluoride (total)', 'EG020T: Total Metals by ICP-MS', 'ALS', 'dissolved')")),
  list(check = "vocab_feature_alias_kind", key = "fa-kind", label = "bad alias kind",
       seed = function(con) dbc_alias(con, "fa-kind", "f-0001", "T.K", "t.k", "nickname")),
  list(check = "vocab_ingest_state", key = dbc_hex(905), label = "ingest_file state outside the state machine",
       seed = function(con) dbc_exec(con, "INSERT INTO ingest_file (hash, state) VALUES (?, 'done')", dbc_hex(905))),
  list(check = "vocab_review_status", key = "rq-st", label = "review status outside the vocabulary",
       seed = function(con) DBI::dbExecute(con, "INSERT INTO review_queue (uuid, created_at, kind, status)
                                                 VALUES ('rq-st', TIMESTAMP '2025-06-01 00:00:00', 'parse_error', 'closed')")),
  list(check = "vocab_review_status", key = "rq-rs", label = "resolved review item with no resolved_at",
       seed = function(con) DBI::dbExecute(con, "INSERT INTO review_queue (uuid, created_at, kind, status, resolution)
                                                 VALUES ('rq-rs', TIMESTAMP '2025-06-01 00:00:00', 'parse_error', 'resolved', 'ignored')")),
  list(check = "vocab_mask_variant", key = "nickname", label = "unregistered mask variant",
       seed = function(con) DBI::dbExecute(con, "INSERT INTO feature_mask VALUES ('f-0002', 'nickname', 'Second creek')")),
  list(check = "vocab_feature_flow", key = "f-0002", label = "feature.flow outside the vocabulary",
       seed = function(con) DBI::dbExecute(con, "UPDATE feature SET flow = 'river' WHERE uuid = 'f-0002'")),
  list(check = "analysis_value_shape", key = "an-shape", label = "analysis with neither value nor value_chr",
       seed = function(con) DBI::dbExecute(con, "INSERT INTO analysis (uuid, uuid_sample, uuid_lab, value, value_chr, quantified)
                                                 VALUES ('an-shape', 's-0004', 'lm-0003', NULL, NULL, TRUE)")),
  list(check = "analysis_value_shape", key = "an-nan", label = "analysis with a NaN value",
       seed = function(con) DBI::dbExecute(con, "INSERT INTO analysis (uuid, uuid_sample, uuid_lab, value, quantified)
                                                 VALUES ('an-nan', 's-0004', 'lm-0003', 'NaN'::DOUBLE, TRUE)")),
  list(check = "hash_format", key = "e3b0c442", label = "a SHA-256 hash in ingest_file",
       seed = function(con) DBI::dbExecute(con, "INSERT INTO ingest_file (hash, state) VALUES
                                                 ('e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855', 'quarantined')")),
  list(check = "change_log_shape", key = "cl-x", label = "change_log row with no actor",
       seed = function(con) DBI::dbExecute(con, "INSERT INTO change_log (uuid, \"at\", actor, action, tbl, uuid_row, reason)
                                                 VALUES ('cl-x', TIMESTAMP '2025-06-01 00:00:00', NULL, 'update', 'analysis', 'an-0001', 'x')")),
  list(check = "sample_date_plausible", key = "s-future", label = "a sample dated in the future",
       seed = function(con) dbc_new_sample(con, "s-future", date = format(Sys.Date() + 30), datetime = NA)),
  list(check = "sample_date_datetime_agree", key = "s-skew", label = "sample date and datetime on different days",
       seed = function(con) dbc_new_sample(con, "s-skew", date = "2025-06-01", datetime = "2025-06-05 02:00:00")),
  list(check = "sample_in_feature_window", key = "s-late", label = "a sample after its feature's date_end",
       seed = function(con) dbc_new_sample(con, "s-late", alias = "fa-0013", date = "2025-01-01",
                                           datetime = "2024-12-31 23:00:00")),
  list(check = "date_windows_ordered", key = "p-0003", label = "a transposed project window",
       seed = function(con) DBI::dbExecute(con, "UPDATE project SET date_start = TIMESTAMP '2025-02-01 00:00:00',
                                                 date_end = TIMESTAMP '2025-01-01 00:00:00' WHERE uuid = 'p-0003'")),
  list(check = "feature_coords", key = "f-0002", label = "NaN coordinates",
       seed = function(con) DBI::dbExecute(con, "UPDATE feature SET lon = 'NaN'::DOUBLE, lat = 'NaN'::DOUBLE,
                                                 geom_wkt = 'POINT EMPTY' WHERE uuid = 'f-0002'")),
  list(check = "feature_coords", key = "f-0002", label = "coordinates outside the configured bbox",
       params = list(bbox = c(xmin = 150, ymin = -33.2, xmax = 150.2, ymax = -33)),
       seed = function(con) DBI::dbExecute(con, "UPDATE feature SET lon = 151.5, lat = -33.5,
                                                 geom_wkt = 'POINT (151.5 -33.5)' WHERE uuid = 'f-0002'")),
  list(check = "feature_geom_matches_lonlat", key = "f-0002", label = "geometry disagreeing with lon/lat",
       seed = function(con) DBI::dbExecute(con, "UPDATE feature SET geom_wkt = 'POINT (151 -34)' WHERE uuid = 'f-0002'"))
)
