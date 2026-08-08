# dev/migrations/007-registry-rulings.R - Robin's 2026-08-08 registry rulings.
#
#   mig007_run(db, snapshot_dir, dry_run = FALSE, .now = NULL, .uuid_fn = ...)
#     -> invisible list(status = "migrated" | "already_migrated" | "dry_run", ...)
#
# Every test sources the target inside its own `test_that()` (test-migration-004's
# Phase-5 audit finding B5).
#
# THE FIXTURE SEEDS THE REAL NATURAL KEYS. The rulings name live rows by
# (name, method, organisation) - `Total Dissolved Solids @180°C` /
# `EA015: ...`, and so on - and the fixture reproduces those exact strings
# rather than letting the test inject a convenient spec of its own. A test that
# supplied its own rulings would prove the MACHINERY works while leaving the
# actual shipped spec - the part a human reviews and the part that can be
# wrong - completely unexercised.

.mig007_load <- function() {
  env <- new.env(parent = globalenv())
  path <- testthat::test_path("..", "..", "dev", "migrations", "007-registry-rulings.R")
  if (!file.exists(path)) {
    stop(sprintf("migration file not found: %s", path))
  }
  sys.source(path, envir = env)
  env
}

#' Seed exactly the rows the five rulings name, plus the `preference` column
#' 005 would have added.
.seed_007_fixture <- function(con) {
  DBI::dbExecute(con, "ALTER TABLE lab_method ADD COLUMN preference INTEGER")

  DBI::dbExecute(con, "INSERT INTO analyte (uuid, name, units, type, CAS) VALUES
    ('a-tds',  'TDS',         'mg/L', 'physical', NULL),
    ('a-no2n', 'NO2-N',       'mg/L', 'nitrogen', NULL),
    ('a-c11',  'TRH-C11-C16', 'mg/L', 'organic',  NULL),
    ('a-f2',   'TRH-F2',      'mg/L', 'organic',  NULL)")

  DBI::dbExecute(con, "INSERT INTO lab_method
    (uuid, uuid_analyte, name, method, organisation) VALUES
    ('lm-ea015', 'a-tds',  'Total Dissolved Solids @180°C',
       'EA015: Total Dissolved Solids dried at 180 ± 5 °C', 'ALS'),
    ('lm-ea016', 'a-tds',  'Total Dissolved Solids (Calc.)',
       'EA016: Calculated TDS (from Electrical Conductivity)', 'ALS'),
    ('lm-acirl-tds', 'a-tds', 'Total Dissolved Solids', 'field', 'ACIRL'),
    ('lm-no2n', 'a-no2n', 'Nitrite as N',
       'EK057G:  Nitrite as N by Discrete Analyser', 'ALS'),
    ('lm-no2',  'a-no2n', 'Nitrite as NO2',
       'EK057G:  Nitrite as N by Discrete Analyser', 'ALS'),
    ('lm-trh-ep080', 'a-c11', '>C10 - C16 Fraction',
       'EP080/071: Total Recoverable Hydrocarbons - NEPM 2013 Fractions', 'ALS'),
    ('lm-trh-ep071', 'a-f2',  '>C10 - C16 Fraction',
       'EP071: Total Recoverable Hydrocarbons - NEPM 2013 Fractions', 'ALS')")

  # Three analyses on the method ruling (5) repoints - this is what makes the
  # FK pre-pass reachable. duckdb refuses to move `lab_method.uuid_analyte`
  # while any analysis references the method, so a fixture with no dependent
  # analyses would never exercise the detach/reattach at all.
  DBI::dbExecute(con, "INSERT INTO analysis
    (uuid, uuid_sample, uuid_lab, value, quantified) VALUES
    ('an-trh1', 's-0001', 'lm-trh-ep071', 0.11, TRUE),
    ('an-trh2', 's-0001', 'lm-trh-ep071', 0.22, TRUE),
    ('an-trh3', 's-0002', 'lm-trh-ep071', 0.33, TRUE)")

  DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at)
                       VALUES (1005, TIMESTAMP '2026-08-08 00:00:00')")
  invisible(NULL)
}

.mig007_env <- function() {
  dir <- withr::local_tempdir(.local_envir = parent.frame())
  db <- seed_db(dir = dir)
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = FALSE)
  .seed_007_fixture(con)
  DBI::dbDisconnect(con, shutdown = TRUE)
  snap <- withr::local_tempdir(.local_envir = parent.frame())
  list(db = db, snapshot_dir = snap)
}

.mig007_state <- function(db) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  list(
    marker = DBI::dbGetQuery(
      con, "SELECT version FROM schema_version WHERE version = 1007")$version,
    n_lab = as.integer(DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM lab_method")$n),
    n_analyte = as.integer(DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM analyte")$n),
    n_analysis = as.integer(DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM analysis")$n),
    lab = DBI::dbGetQuery(
      con, "SELECT uuid, name, uuid_analyte, preference, conversion_constant
              FROM lab_method ORDER BY uuid"),
    analysis = DBI::dbGetQuery(
      con, "SELECT uuid, uuid_sample, uuid_lab, value FROM analysis ORDER BY uuid")
  )
}

# ======================================================================

test_that("mig007_run() applies all five rulings", {
  mig <- .mig007_load()
  e <- .mig007_env()
  before <- .mig007_state(e$db)

  res <- mig$mig007_run(db = e$db, snapshot_dir = e$snapshot_dir)
  expect_identical(res$status, "migrated")

  after <- .mig007_state(e$db)
  expect_identical(after$marker, 1007L)
  expect_identical(after$n_lab, before$n_lab - 1L)      # (1) one method deleted
  expect_identical(after$n_analyte, before$n_analyte + 2L)  # (4) two created
  expect_identical(after$n_analysis, before$n_analysis)     # nothing else
})

test_that("(1) the unused ACIRL field TDS method is gone", {
  mig <- .mig007_load(); e <- .mig007_env()
  mig$mig007_run(db = e$db, snapshot_dir = e$snapshot_dir)
  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  expect_identical(
    as.integer(DBI::dbGetQuery(con,
      "SELECT COUNT(*) n FROM lab_method
        WHERE name = 'Total Dissolved Solids' AND organisation = 'ACIRL'")$n),
    0L
  )
})

test_that("(1) is REFUSED if the method has acquired analyses - the premise is checked", {
  # The ruling rests on the method being UNUSED. If that stops being true the
  # deletion would destroy data, so the gate re-checks rather than trusting the
  # measurement that justified the ruling.
  mig <- .mig007_load(); e <- .mig007_env()
  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = FALSE)
  DBI::dbExecute(con, "INSERT INTO analysis (uuid, uuid_sample, uuid_lab, value, quantified)
                       VALUES ('an-tds-x', 's-0001', 'lm-acirl-tds', 1.0, TRUE)")
  DBI::dbDisconnect(con, shutdown = TRUE)

  before <- .mig007_state(e$db)
  expect_error(
    mig$mig007_run(db = e$db, snapshot_dir = e$snapshot_dir),
    class = "sampletidy_error"
  )
  expect_identical(.mig007_state(e$db)$n_lab, before$n_lab)
  expect_length(list.files(e$snapshot_dir), 0L)   # refused before the backup
})

test_that("(2) preference values land, measured over calculated", {
  mig <- .mig007_load(); e <- .mig007_env()
  mig$mig007_run(db = e$db, snapshot_dir = e$snapshot_dir)
  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  got <- DBI::dbGetQuery(con,
    "SELECT uuid, preference FROM lab_method WHERE preference IS NOT NULL ORDER BY uuid")
  expect_setequal(got$uuid, c("lm-ea015", "lm-ea016", "lm-no2", "lm-no2n"))
  pref <- stats::setNames(as.integer(got$preference), got$uuid)
  expect_lt(pref[["lm-ea015"]], pref[["lm-ea016"]])   # measured beats calculated
  expect_lt(pref[["lm-no2n"]], pref[["lm-no2"]])      # as-N beats as-NO2
})

test_that("(3) the nitrite basis constant is the real molar ratio", {
  mig <- .mig007_load(); e <- .mig007_env()
  mig$mig007_run(db = e$db, snapshot_dir = e$snapshot_dir)
  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  got <- DBI::dbGetQuery(con,
    "SELECT conversion_constant c FROM lab_method WHERE uuid = 'lm-no2'")$c
  # 14.007/46.005 - pinned as the RATIO, not a copied decimal, so a typo in the
  # migration cannot be reproduced by a typo in the test.
  expect_equal(got, 14.007 / 46.005, tolerance = 1e-9)
  # ...and it is NOT applied to the as-N method.
  expect_true(is.na(DBI::dbGetQuery(con,
    "SELECT conversion_constant c FROM lab_method WHERE uuid = 'lm-no2n'")$c))
})

test_that("(4) the two analytes are created with the ruled units and type", {
  mig <- .mig007_load(); e <- .mig007_env()
  mig$mig007_run(db = e$db, snapshot_dir = e$snapshot_dir)
  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  got <- DBI::dbGetQuery(con,
    "SELECT name, units, type, CAS FROM analyte
      WHERE name IN ('Decachlorobiphenyl','Volume Purged') ORDER BY name")
  expect_identical(nrow(got), 2L)
  expect_identical(got$units, c("%", "L"))
  expect_identical(got$type[got$name == "Decachlorobiphenyl"], "QC")
  expect_identical(got$CAS[got$name == "Decachlorobiphenyl"], "2051-24-3")
})

test_that("(5) the repoint moves the method AND leaves no analysis detached", {
  # The FK pre-pass NULLs `analysis.uuid_lab` and restores it. If it stopped
  # half way the analyses would be orphaned, so both ends are asserted.
  mig <- .mig007_load(); e <- .mig007_env()
  before <- .mig007_state(e$db)
  mig$mig007_run(db = e$db, snapshot_dir = e$snapshot_dir)

  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  expect_identical(
    DBI::dbGetQuery(con,
      "SELECT uuid_analyte a FROM lab_method WHERE uuid = 'lm-trh-ep071'")$a,
    "a-c11"
  )
  expect_identical(
    as.integer(DBI::dbGetQuery(con,
      "SELECT COUNT(*) n FROM analysis WHERE uuid_lab IS NULL")$n),
    0L
  )
  # every analysis row back exactly where it started
  expect_identical(.mig007_state(e$db)$analysis, before$analysis)
})

test_that("(5) the label then resolves unambiguously - the point of the fix", {
  # Before: two same-named ALS methods spanning two analytes, so
  # `.rc_resolve_one_analyte()` returns `ambiguous`. After: one analyte, so it
  # resolves. This is the property, asked through the production resolver.
  mig <- .mig007_load(); e <- .mig007_env()

  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = TRUE)
  reg <- .rc_load_registry(con)
  DBI::dbDisconnect(con, shutdown = TRUE)
  expect_identical(
    .rc_resolve_one_analyte(">C10 - C16 Fraction", "ALS", NA_character_, reg)$status,
    "ambiguous"
  )

  mig$mig007_run(db = e$db, snapshot_dir = e$snapshot_dir)

  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  got <- .rc_resolve_one_analyte(">C10 - C16 Fraction", "ALS", NA_character_,
                                 .rc_load_registry(con))
  expect_identical(got$status, "resolved")
  expect_identical(got$uuid_analyte, "a-c11")
})

test_that("it refuses without the 1005 marker - ruling (2) needs 005's column", {
  mig <- .mig007_load(); e <- .mig007_env()
  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = FALSE)
  DBI::dbExecute(con, "DELETE FROM schema_version WHERE version = 1005")
  DBI::dbDisconnect(con, shutdown = TRUE)

  expect_error(
    mig$mig007_run(db = e$db, snapshot_dir = e$snapshot_dir),
    class = "sampletidy_error"
  )
  expect_length(.mig007_state(e$db)$marker, 0L)
})

test_that("a natural key matching 0 or 2 rows is refused, not guessed", {
  # The rulings name rows by (name, method, organisation) rather than uuid so a
  # human can review them. That only works if an ambiguous or absent key is a
  # hard stop.
  mig <- .mig007_load(); e <- .mig007_env()
  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = FALSE)
  DBI::dbExecute(con, "INSERT INTO lab_method
    (uuid, uuid_analyte, name, method, organisation) VALUES
    ('lm-dupe', 'a-tds', 'Total Dissolved Solids @180°C',
      'EA015: Total Dissolved Solids dried at 180 ± 5 °C', 'ALS')")
  DBI::dbDisconnect(con, shutdown = TRUE)

  before <- .mig007_state(e$db)
  # MUTATION-DRIVEN: asserting only "this errors" made the natural-key gate look
  # protective when the VERIFY gate would have caught it anyway. What the gate
  # uniquely contributes is refusing BEFORE the backup, on a read-only
  # connection - so the message and the absent backup are what the test pins.
  expect_error(
    mig$mig007_run(db = e$db, snapshot_dir = e$snapshot_dir),
    regexp = "matches 2 lab_method rows",
    class = "sampletidy_error"
  )
  expect_identical(.mig007_state(e$db)$n_lab, before$n_lab)
  expect_length(list.files(e$snapshot_dir), 0L)
})

test_that("(5) is refused if the method no longer points where the ruling assumes", {
  mig <- .mig007_load(); e <- .mig007_env()
  # DELETE the dependent analyses rather than detaching them: leaving rows with
  # a NULL `uuid_lab` would trip the pre-pass's own reattach check, and the test
  # would then pass for a reason that has nothing to do with the precondition
  # it is supposed to be exercising. (That is exactly how a surviving mutation
  # exposed a global-vs-scoped bug in that check.)
  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = FALSE)
  DBI::dbExecute(con, "DELETE FROM analysis WHERE uuid_lab = 'lm-trh-ep071'")
  DBI::dbExecute(con, "UPDATE lab_method SET uuid_analyte = 'a-c11' WHERE uuid = 'lm-trh-ep071'")
  DBI::dbDisconnect(con, shutdown = TRUE)

  expect_error(
    mig$mig007_run(db = e$db, snapshot_dir = e$snapshot_dir),
    class = "sampletidy_error"
  )
  expect_length(.mig007_state(e$db)$marker, 0L)
})

test_that("(4) is refused if an analyte of that name already exists", {
  mig <- .mig007_load(); e <- .mig007_env()
  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = FALSE)
  DBI::dbExecute(con, "INSERT INTO analyte (uuid, name, units, type)
                       VALUES ('a-dup', 'Volume Purged', 'L', 'quality')")
  DBI::dbDisconnect(con, shutdown = TRUE)

  before <- .mig007_state(e$db)
  # MUTATION-DRIVEN, same reasoning as the natural-key gate above.
  expect_error(
    mig$mig007_run(db = e$db, snapshot_dir = e$snapshot_dir),
    regexp = "already exists",
    class = "sampletidy_error"
  )
  expect_identical(.mig007_state(e$db)$n_analyte, before$n_analyte)
  expect_length(list.files(e$snapshot_dir), 0L)
})

test_that("dry_run checks every precondition and writes nothing", {
  mig <- .mig007_load(); e <- .mig007_env()
  before <- .mig007_state(e$db)
  res <- mig$mig007_run(db = e$db, snapshot_dir = e$snapshot_dir, dry_run = TRUE)
  after <- .mig007_state(e$db)

  expect_identical(res$status, "dry_run")
  expect_identical(after$n_lab, before$n_lab)
  expect_identical(after$n_analyte, before$n_analyte)
  expect_length(after$marker, 0L)
  expect_length(list.files(e$snapshot_dir), 0L)
})

test_that("re-running is a clean no-op", {
  mig <- .mig007_load(); e <- .mig007_env()
  mig$mig007_run(db = e$db, snapshot_dir = e$snapshot_dir)
  once <- .mig007_state(e$db)
  again <- mig$mig007_run(db = e$db, snapshot_dir = e$snapshot_dir)
  expect_identical(again$status, "already_migrated")
  expect_identical(.mig007_state(e$db)$lab, once$lab)
})

test_that("the SAFETY half catches a stray change to `analysis`", {
  mig <- .mig007_load(); e <- .mig007_env()
  before <- .mig007_state(e$db)

  repoint_ok <- mig$.mig007_repoint_method
  mig$.mig007_repoint_method <- function(con, uuid_lab, uuid_analyte, reason) {
    n <- repoint_ok(con, uuid_lab, uuid_analyte, reason)
    DBI::dbExecute(con, "UPDATE analysis SET value = value + 1 WHERE uuid = 'an-trh1'")
    n
  }

  expect_error(
    mig$mig007_run(db = e$db, snapshot_dir = e$snapshot_dir),
    class = "sampletidy_error"
  )
  expect_length(.mig007_state(e$db)$marker, 0L)
})
