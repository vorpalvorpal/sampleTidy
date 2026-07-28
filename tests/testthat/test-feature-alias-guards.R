# Phase 7b coverage remediation - R/feature-alias.R guards with ZERO test
# coverage (mutation-verified for guard 2 and guard 5; see the task brief).
# This file pins five guards that are ALREADY IMPLEMENTED AND BELIEVED
# CORRECT - it adds no production code and edits no other test file.
#
# Every test's break/restore non-vacuity evidence (disable the guard, confirm
# the test fails; restore, confirm it passes) is logged in
# dev/tdd-run/p7b-guards-report.md, run against a private scratch copy of the
# package - never against R/feature-alias.R in this repo, which another
# worker is editing concurrently.
#
# HARD SAFETY: every test here opens only a fresh withr-scoped temp DuckDB
# file (or, for the two pure argument-validation guards, never opens a DB
# connection at all - the abort in question fires before with_db_write() is
# reached). st_config("live_db") is never allowed to resolve without an
# explicit `db =` override pointing at a temp file.

# ---- local fixtures (inline; this file owns nothing else) -----------------

#' Seed the standard CONTRACT fixture DB and point st_config("live_db") at
#' it, cleanup bound to the CALLING TEST's frame (the withr wrong-frame trap,
#' language-footguns.md). Mirrors test-feature-alias.R's fa_setup(),
#' redefined locally: this file may not source or edit that file.
fag_setup <- function() {
  env <- parent.frame()
  path <- seed_db(dir = withr::local_tempdir(.local_envir = env))
  withr::local_options(list("sampletidy.live_db" = path), .local_envir = env)
  con <- seed_con(path)
  list(path = path, con = con)
}

#' Seed a change_log row shaped exactly like an UNPAIRED FK detach left by a
#' torn `.fa_guarded_update()` run. `.fa_torn_guard()` groups change_log by
#' (tbl, field) and compares detach-suffix count to reattach-suffix count, so
#' one detach-suffixed row with no matching reattach row is sufficient to
#' trip it - regardless of whether `tbl`/`field` correspond to any table that
#' actually declares an FK in this DB.
fag_seed_unpaired_detach <- function(con, tbl, field) {
  .st_write_change_log(
    con, at = Sys.time(), actor = "prior_run", action = "update",
    tbl = tbl, uuid_row = "torn-row-uuid", field = field,
    old = "old-value", new = NA_character_,
    reason = paste("interrupted FK-dance run (fixture)", .fa_detach_reason),
    source_hash = NA_character_
  )
  invisible(NULL)
}

#' A minimal PRIVATE schema that - unlike the shared CONTRACT test DDL
#' (helper-db.R), which declares NO foreign keys on purpose (see
#' R/feature-alias.R's own comment at `.fa_fk_columns()`, "that is exactly
#' why those fixtures never reproduce this defect") - DOES declare a real
#' `lab_method.uuid_analyte -> analyte(uuid)` FK and a real
#' `analysis.uuid_lab -> lab_method(uuid)` FK, so `.fa_needs_fk_dance()` can
#' actually return TRUE and drive `.fa_guarded_update()` into its FK-dance
#' branch. That branch is the ONLY way to reach the in-transaction assertion
#' guard 5 pins. Table names are real allowlisted mutation-layer tables
#' (analyte, lab_method, analysis) so db_update() accepts them; only the
#' DDL's own FK declarations differ from the shared fixture.
fag_fk_setup <- function() {
  env <- parent.frame()
  dir <- withr::local_tempdir(.local_envir = env)
  path <- file.path(dir, "fk-guard.duckdb")
  con <- DBI::dbConnect(duckdb::duckdb(), path, read_only = FALSE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE), envir = env)

  ensure_schema(con)

  DBI::dbExecute(con, "CREATE TABLE analyte (
    uuid VARCHAR PRIMARY KEY, name VARCHAR, units VARCHAR,
    conversion_constant DOUBLE, type VARCHAR, \"CAS\" VARCHAR)")
  DBI::dbExecute(con, "CREATE TABLE lab_method (
    uuid VARCHAR PRIMARY KEY,
    uuid_analyte VARCHAR REFERENCES analyte(uuid),
    name VARCHAR, method VARCHAR, organisation VARCHAR,
    rl_low DOUBLE, rl_high DOUBLE, reported_as VARCHAR, api VARCHAR,
    uuid_project VARCHAR, uuid_feature VARCHAR, comments VARCHAR,
    units VARCHAR, conversion_constant DOUBLE)")
  DBI::dbExecute(con, "CREATE TABLE analysis (
    uuid VARCHAR PRIMARY KEY, uuid_sample VARCHAR,
    uuid_lab VARCHAR REFERENCES lab_method(uuid),
    value DOUBLE, value_chr VARCHAR, quantified BOOLEAN,
    rl_low DOUBLE, rl_high DOUBLE, purpose VARCHAR, comments VARCHAR)")

  DBI::dbExecute(con, "INSERT INTO analyte (uuid, name, units) VALUES
    ('fk-an-1', 'Analyte One', 'mg/L'), ('fk-an-2', 'Analyte Two', 'mg/L')")
  DBI::dbExecute(con, "INSERT INTO lab_method
    (uuid, uuid_analyte, name, organisation, units) VALUES
    ('fk-lm-1', 'fk-an-1', 'Method One', 'ALS', 'mg/L')")
  DBI::dbExecute(con, "INSERT INTO analysis
    (uuid, uuid_sample, uuid_lab, value, quantified) VALUES
    ('fk-row-1', 'fk-s-1', 'fk-lm-1', 1.0, TRUE)")

  list(path = path, con = con)
}

# ======================================================================
# Guard 1 - .fa_check_bound() rejects POSIXt bounds (PLAN-15 E.1)
# ======================================================================
# No DB is ever opened: the bound check runs before with_db_write() in
# confirm_feature_aliases(), so a never-created tempfile path is safe and
# sufficient.

test_that("Phase-7 pin (guard 1a): confirm_feature_aliases() rejects a POSIXct date_start (kills a disabled POSIXt check in .fa_check_bound())", {
  db_path <- withr::local_tempfile()
  expect_error(
    confirm_feature_aliases(
      "fa-0010", "f-0002", confirmed_by = "alice",
      date_start = as.POSIXct("2025-09-01 00:00:00", tz = "Australia/Sydney"),
      db = db_path
    ),
    class = "sampletidy_error"
  )
})

test_that("Phase-7 pin (guard 1b): confirm_feature_aliases() rejects a POSIXct date_end (kills a disabled POSIXt check in .fa_check_bound())", {
  db_path <- withr::local_tempfile()
  expect_error(
    confirm_feature_aliases(
      "fa-0010", "f-0002", confirmed_by = "alice",
      date_end = as.POSIXct("2025-09-01 00:00:00", tz = "Australia/Sydney"),
      db = db_path
    ),
    class = "sampletidy_error"
  )
})

test_that("Phase-8b pin (guard 1c): confirm_feature_aliases() rejects a TRANSPOSED date_start/date_end pair (kills a disabled .fa_check_bound_order()) - no DB is ever opened, mirroring guard 1a/1b", {
  db_path <- withr::local_tempfile()
  expect_error(
    confirm_feature_aliases(
      "fa-0010", "f-0002", confirmed_by = "alice",
      date_start = as.Date("2030-01-01"), date_end = as.Date("2020-01-01"),
      db = db_path
    ),
    class = "sampletidy_error"
  )
  # No DB file was ever created - the argument-level check runs before
  # with_db_write() is reached, exactly like guard 1a/1b.
  expect_false(file.exists(db_path))
})

# ======================================================================
# Guard 2 - .fa_torn_guard() (PLAN-15 F.14, the atomicity buy-back) - all
# three entry points that call it.
# ======================================================================

test_that("Phase-7 pin (guard 2a): confirm_analyte_methods() aborts on an interrupted-run torn change_log (kills a disabled .fa_torn_guard())", {
  setup <- fag_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  fag_seed_unpaired_detach(con, tbl = "lab_method", field = "uuid_analyte")

  expect_error(
    confirm_analyte_methods("lm-0008", "a-0003", confirmed_by = "alice"),
    class = "sampletidy_error"
  )
})

test_that("Phase-7 pin (guard 2b): confirm_feature_aliases() - the call shape the F.19 identity post-pass runs under - aborts on an interrupted-run torn change_log (kills a disabled .fa_torn_guard())", {
  setup <- fag_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  fag_seed_unpaired_detach(con, tbl = "sample", field = "uuid_feature_alias")

  # fa-0002 -> f-0002 is an identity mapping (alias_key == lower(feature.name)):
  # the shape the F.19 post-pass repoints under. The guard itself fires
  # unconditionally at entry, before any identity branch is reached, so this
  # assertion holds for confirm_feature_aliases() generally too - documented
  # honestly rather than claiming a narrower reach than the code has.
  expect_error(
    confirm_feature_aliases("fa-0002", "f-0002", confirmed_by = "alice"),
    class = "sampletidy_error"
  )
})

test_that("Phase-7 pin (guard 2c): merge_identity_aliases() aborts on an interrupted-run torn change_log (kills a disabled .fa_torn_guard())", {
  setup <- fag_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  fag_seed_unpaired_detach(con, tbl = "sample", field = "uuid_feature_alias")

  expect_error(
    merge_identity_aliases(db = setup$path, actor = "alice"),
    class = "sampletidy_error"
  )
})

# ======================================================================
# Guard 2d - Phase-7b round-2 item 6: the SECOND non-atomic window
# .fa_torn_guard() now also detects - a redundant identity arm left behind
# by an INTERRUPTED repoint-then-delete run (F.19's post-pass /
# merge_identity_aliases(), both of which run .fa_repoint_samples() then a
# separate db_delete() as two separately committed calls, per the guarded
# exception at the head of R/feature-alias.R). Unlike guard 2a-c, there is
# no missing "reattach" here - the DELETE itself is the missing step - so
# this is a genuinely different detection shape, not a copy of the
# detach/reattach check.
# ======================================================================

test_that("Phase-7 pin (guard 2d): confirm_feature_aliases() aborts when a redundant identity arm's samples were already re-pointed off it but the arm itself was never deleted (an interrupted repoint-then-delete run)", {
  setup <- fag_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # A dangling (uuid_feature IS NULL) non-self arm, plus a change_log row
  # recording a COMPLETED repoint of a sample OFF it - exactly the state a
  # crash between .fa_repoint_samples() committing and the following
  # db_delete() leaves.
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign,
     first_seen, last_seen, confirmed_by) VALUES
    ('fa-torn-del-01', NULL, 'Z.TORNDEL01', 'z.torndel01', 'transcription_error', 0, TRUE,
     TIMESTAMP '2025-09-01 08:00:00', TIMESTAMP '2025-09-01 08:00:00', NULL)")
  .st_write_change_log(
    con, at = Sys.time(), actor = "prior_run", action = "update",
    tbl = "sample", uuid_row = "s-torn-del-01", field = "uuid_feature_alias",
    old = "fa-torn-del-01", new = "fa-0002",
    reason = paste0(
      "identity alias: sample re-pointed from the redundant arm 'fa-torn-del-01' ",
      "onto the surviving self arm 'fa-0002'"
    ),
    source_hash = NA_character_
  )

  expect_error(
    confirm_feature_aliases("fa-0010", "f-0002", confirmed_by = "alice", db = setup$path),
    class = "sampletidy_error"
  )
})

test_that("Phase-7 pin (guard 2d control): an ordinary UNCONFIRMED pending alias (uuid_feature IS NULL, no repoint trail at all) does NOT trip the new torn-delete check - the guard fires on the change_log trail, not merely on a dangling arm", {
  setup <- fag_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  expect_no_error(
    confirm_feature_aliases("fa-0010", "f-0002", confirmed_by = "alice", db = setup$path)
  )
})

test_that("Phase-7b round-3 A5 regression guard: an E.8-shaped torn trail (a merge_identity_aliases() repoint reason on a loser arm whose uuid_feature is NOT NULL, as every real E.8 loser's is by construction) must NOT abort - the guard predicate is scoped to uuid_feature IS NULL and must stay that way", {
  # A5 (CONFIRMED-BY-ORCH, probe3_torn_guard.R): a prior `OR cl.reason LIKE
  # 'merge_identity_aliases(): ...'` clause here was UNREACHABLE dead SQL,
  # because .fa_torn_guard()'s own WHERE requires `fa.uuid_feature IS NULL`
  # and .fa_identity_duplicates() only ever selects E.8 losers with a
  # non-NULL uuid_feature - deleted, per Robin's explicit instruction NOT to
  # widen the predicate (that would block E.8's own documented
  # recovery-by-re-run, R/feature-alias.R:1118-1121). This is a REGRESSION
  # GUARD, not a red/green pin for the deletion itself - removing dead code
  # cannot be exhibited as a behaviour change by definition. It exists to
  # catch a FUTURE "widen the predicate to also catch E.8" mistake.
  setup <- fag_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  DBI::dbExecute(con, "INSERT INTO feature (uuid, name, site, flow, matrix, lon, lat) VALUES
    ('f-torn-e8', 'Z.TORNE8A5', 'Z', 'surface', 'water', 150.9860, -33.9860)")
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign,
     first_seen, last_seen, confirmed_by) VALUES
    ('fa-torn-e8-self', 'f-torn-e8', 'Z.TORNE8A5', 'z.torne8a5', 'self', 0, TRUE,
     TIMESTAMP '2020-01-01 00:00:00', TIMESTAMP '2020-01-01 00:00:00', 'R. Shannon'),
    ('fa-torn-e8-loser', 'f-torn-e8', 'Z.TORNE8A5', 'z.torne8a5', 'transcription_error', 0, TRUE,
     TIMESTAMP '2026-01-01 00:00:00', TIMESTAMP '2026-01-01 00:00:00', 'R. Shannon')")
  .st_write_change_log(
    con, at = Sys.time(), actor = "prior_run", action = "update",
    tbl = "sample", uuid_row = "s-torn-e8-1", field = "uuid_feature_alias",
    old = "fa-torn-e8-loser", new = "fa-torn-e8-self",
    reason = paste0(
      "merge_identity_aliases(): sample re-pointed from redundant identity ",
      "arm 'fa-torn-e8-loser' onto surviving self arm 'fa-torn-e8-self' (E.8)"
    ),
    source_hash = NA_character_
  )

  expect_no_error(.fa_torn_guard(con))
})

# ======================================================================
# Guard 3 - .fa_check_kind() vocabulary validation (PLAN-15 F.19)
# ======================================================================
# No DB is ever opened: the kind check runs before with_db_write().

test_that("Phase-7 pin (guard 3): confirm_feature_aliases() rejects an out-of-vocabulary kind with class = sampletidy_error, and the message names the valid vocabulary (kills a disabled vocabulary check in .fa_check_kind(), and the cli leading-dot defect)", {
  # This pin was written BEFORE the behaviour it asserts existed, and that is
  # how the defect was found. `.fa_check_kind()`'s abort interpolated the
  # DOTTED name `.fa_kind_vocabulary` directly inside `{.val {...}}`; under
  # cli >= 3.4.0 a `{}` expression starting with a dot is a STYLE token, so
  # cli threw its own "Invalid cli literal" error (class rlib_error_3_0)
  # before ever constructing the documented `sampletidy_error`. An invalid
  # kind DID abort - so a bare expect_error() would have passed and hidden it
  # - but not with the class F.19 promises, so nothing catching
  # `sampletidy_error` would have seen it. Fixed in Phase 7b by parenthesising
  # to `{.val {(.fa_kind_vocabulary)}}`.
  #
  # The message assertion is not decoration: parenthesising could restore the
  # CLASS while still producing a message that never names the valid kinds,
  # which is the whole point of the error. Both halves or neither.
  err <- tryCatch(
    sampleTidy:::.fa_check_kind("histrical_code"),
    condition = function(e) e
  )
  expect_s3_class(err, "sampletidy_error")
  expect_match(conditionMessage(err), "transcription_error", fixed = TRUE)
  expect_false(inherits(err, "rlib_error_3_0"))
})

# ======================================================================
# Guard 4 - the two pinned kind-misuse errors (PLAN-15 F.19 / E.4)
# ======================================================================

test_that("Phase-7 pin (guard 4a): confirm_feature_aliases() rejects kind on a bounds-only call (uuid_feature omitted) (kills a disabled kind-on-bounds-only check)", {
  setup <- fag_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  expect_error(
    confirm_feature_aliases(
      "fa-0010", confirmed_by = "alice", kind = "descriptive",
      date_start = as.Date("2025-01-01"), db = setup$path
    ),
    class = "sampletidy_error"
  )
})

test_that("Phase-7 pin (guard 4b): confirm_feature_aliases() rejects kind alongside an identity confirmation - an error, not a silent override (kills a disabled kind-on-identity check)", {
  setup <- fag_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # fa-0002's alias_key 't.s02' == lower(feature 'T.S02'.name): an identity
  # mapping onto its own feature - 'self' by construction (F.19).
  expect_error(
    confirm_feature_aliases(
      "fa-0002", "f-0002", confirmed_by = "alice", kind = "historical_code",
      db = setup$path
    ),
    class = "sampletidy_error"
  )
})

# ======================================================================
# Guard 5 - .fa_guarded_update()'s in-transaction assertion (mutation-
# verified: `if (.st_in_txn(con))` -> `if (FALSE)` survived the full suite)
# ======================================================================

test_that("Phase-7 pin (guard 5): .fa_guarded_update() aborts when the FK-dance path is reached inside an already-open db_transaction() (kills .st_in_txn(con) -> FALSE)", {
  setup <- fag_fk_setup()
  con <- setup$con

  # Sanity: on THIS private FK-declaring schema the dance really is needed
  # for this (table, uuid, columns) - i.e. the assertion under test is
  # actually reachable, not vacuously skipped by the early-return branch.
  expect_true(.fa_needs_fk_dance(con, "lab_method", "fk-lm-1", "uuid_analyte"))

  db_transaction(con, function(con) {
    expect_error(
      .fa_guarded_update(
        con, "lab_method", "fk-lm-1",
        changes = list(uuid_analyte = "fk-an-2"),
        actor = "alice", reason = "phase7 guard 5 pin"
      ),
      class = "sampletidy_error"
    )
  })
})

test_that("Phase-7 pin (guard 5, control): .fa_guarded_update() runs the FK dance normally OUTSIDE an open transaction on the same fixture (proves guard 5's abort above is about the open transaction, not the FK-dance path itself)", {
  setup <- fag_fk_setup()
  con <- setup$con

  expect_true(.fa_needs_fk_dance(con, "lab_method", "fk-lm-1", "uuid_analyte"))
  expect_no_error(
    .fa_guarded_update(
      con, "lab_method", "fk-lm-1",
      changes = list(uuid_analyte = "fk-an-2"),
      actor = "alice", reason = "phase7 guard 5 control"
    )
  )
  moved <- DBI::dbGetQuery(con, "SELECT uuid_analyte FROM lab_method WHERE uuid = 'fk-lm-1'")$uuid_analyte[[1]]
  expect_identical(moved, "fk-an-2")
})
