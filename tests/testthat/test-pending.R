# Plan 11 - R/pending.R: pending_features() / pending_analytes() (R-11.12).
#
# NEW FILE, NEW target module. Both readers are unwritten; every test below is
# expected to fail on a missing production symbol ("could not find function")
# - that is the correct TDD-red state, not a defect. Do not stub R/pending.R
# to make these pass.
#
# A dangling row (feature_alias.uuid_feature IS NULL / lab_method.uuid_analyte
# IS NULL) is invisible to every view BY DESIGN (INNER JOIN through feature /
# analyte) - so without this reader pair it is silent work. ensure_schema()
# creates no views (A24), so this is a reader pair in the existing
# review_queue() style (R/mutate.R), NOT a view. Per the plan (B-11.12):
#
#   pending_features(con)  # -> tibble(uuid_alias, name, alias_key, n_seen,
#                           #    n_samples, first_seen, last_seen)
#   pending_analytes(con)  # -> tibble(uuid_lab, name, organisation, method,
#                           #    units_raw, n_analyses)
#
# `units_raw` is the tibble's OWN column name (matching the IR field name that
# flows into it, R/ir.R:14), not a literal `lab_method` column - the DB column
# is `lab_method.units` (D7 reversed, A63). Taken as written from the plan's
# code block; if this reading is wrong, that is a plan-change matter, not
# something to invent around here.
#
# Fixture convention (matches test-feature-alias.R/test-commit.R): seed_db()
# already carries one dangling feature_alias (fa-0010, referenced by exactly
# one sample, s-0003) and two dangling lab_method rows (lm-0008, lm-0009,
# each referenced by exactly one analysis). Do not edit helper-db.R (plan 11
# owns it, but this unit's brief forbids touching any other test/helper
# file) - a test-local zero-referenced dangling row is inserted directly by
# SQL where needed, which is a hand-built fixture for this module's own unit
# tests (permitted; it is not standing in for another module's output).

# ---- R-11.12: zero-row results have stable columns --------------------

test_that("R-11.12: pending_features()/pending_analytes() have stable columns on a zero-row result", {
  dir <- withr::local_tempdir()
  path <- file.path(dir, "empty.duckdb")
  con <- DBI::dbConnect(duckdb::duckdb(), path, read_only = FALSE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  ensure_schema(con)
  for (ddl in .st_test_core_ddl) DBI::dbExecute(con, ddl)
  # No feature_alias / lab_method / sample / analysis rows at all - the
  # emptiest possible degenerate shape, not merely "no dangling rows".

  pf <- pending_features(con)
  pa <- pending_analytes(con)

  expect_equal(nrow(pf), 0)
  expect_named(
    pf,
    c("uuid_alias", "name", "alias_key", "n_seen", "n_samples",
      "first_seen", "last_seen")
  )
  expect_equal(nrow(pa), 0)
  expect_named(
    pa,
    c("uuid_lab", "name", "organisation", "method", "units_raw", "n_analyses")
  )
})

# ---- R-11.12: counts match the dangling rows exactly -------------------

test_that("R-11.12: pending backlog counts match the dangling rows exactly, including a zero-referenced row", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # A dangling alias/lab_method with NO referencing sample/analysis - proves
  # the reader does not silently drop a zero-count dangling row (e.g. via an
  # INNER JOIN to its referencing table instead of a LEFT JOIN + COUNT).
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign,
     first_seen, last_seen, source_hash, confirmed_by) VALUES
    ('fa-0099', NULL, 'T.ZERO', 'tzero', 'pending', 0, FALSE,
     TIMESTAMP '2025-06-01 00:00:00', TIMESTAMP '2025-06-01 00:00:00',
     'seed-hash-zero-feature', NULL)")
  DBI::dbExecute(con, "INSERT INTO lab_method
    (uuid, uuid_analyte, name, method, organisation, rl_low, units, conversion_constant) VALUES
    ('lm-0099', NULL, 'Zero Method', 'EA000: Zero method', 'ALS', 0.1, 'mg/L', NULL)")

  n_dangling_alias <- DBI::dbGetQuery(
    con, "SELECT COUNT(*) n FROM feature_alias WHERE uuid_feature IS NULL"
  )$n
  n_dangling_method <- DBI::dbGetQuery(
    con, "SELECT COUNT(*) n FROM lab_method WHERE uuid_analyte IS NULL"
  )$n

  pf <- pending_features(con)
  pa <- pending_analytes(con)

  # Exact row counts - not "at least" or "runs without error".
  expect_equal(nrow(pf), n_dangling_alias)
  expect_equal(nrow(pa), n_dangling_method)

  fa10 <- dplyr::filter(pf, .data$uuid_alias == "fa-0010")
  expect_equal(nrow(fa10), 1)
  expect_equal(fa10$name, "T.S09")
  expect_equal(fa10$alias_key, "ts09")
  expect_equal(fa10$n_seen, 0)
  expect_equal(fa10$n_samples, 1) # only s-0003 points at fa-0010

  fa99 <- dplyr::filter(pf, .data$uuid_alias == "fa-0099")
  expect_equal(nrow(fa99), 1)
  expect_equal(fa99$n_samples, 0) # zero-referenced - must not be dropped

  lm8 <- dplyr::filter(pa, .data$uuid_lab == "lm-0008")
  expect_equal(nrow(lm8), 1)
  expect_equal(lm8$name, "EC New Method")
  expect_equal(lm8$organisation, "ALS")
  expect_equal(lm8$method, "EA010Z: Conductivity by new method")
  expect_equal(lm8$units_raw, "µS/cm")
  expect_equal(lm8$n_analyses, 1) # an-0002

  lm9 <- dplyr::filter(pa, .data$uuid_lab == "lm-0009")
  expect_equal(nrow(lm9), 1)
  expect_equal(lm9$n_analyses, 1) # an-0004

  lm99 <- dplyr::filter(pa, .data$uuid_lab == "lm-0099")
  expect_equal(nrow(lm99), 1)
  expect_equal(lm99$n_analyses, 0) # zero-referenced - must not be dropped
})

# ---- R-11.12: reconciles with review_queue() ---------------------------

test_that("R-11.12: pending backlog counts reconcile with review_queue() open-item counts", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # Real writer (db-schema.R) + real reader (mutate.R) - a genuine seam, not a
  # hand-rolled stand-in for another module's output. One review item per
  # dangling row already in the seed fixture.
  review_queue_add(con, kind = "unknown_feature", payload = "alias=fa-0010")
  review_queue_add(con, kind = "unknown_analyte", payload = "lab_method=lm-0008")
  review_queue_add(con, kind = "unknown_analyte", payload = "lab_method=lm-0009")
  # A different-kind open item must not be swept into either count - proves
  # the assertion below isn't vacuously true from "review_queue() is non-empty".
  review_queue_add(con, kind = "value_conflict", payload = "sample=s-0001")

  rq <- review_queue(con, status = "open")

  expect_equal(nrow(pending_features(con)), sum(rq$kind == "unknown_feature"))
  expect_equal(nrow(pending_analytes(con)), sum(rq$kind == "unknown_analyte"))
})
