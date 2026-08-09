# dev/migrations/010-aroclor-mixture-names.R - four Aroclor MIXTURES get their
# own names and CAS back off the congener records PubChem merged them into.
#
#   mig010_run(db, snapshot_dir, dry_run = FALSE, .now = NULL)
#     -> invisible list(status = "migrated" | "already_migrated" | "dry_run", ...)
#
# Every test sources the target inside its own `test_that()` (test-migration-004's
# Phase-5 audit finding B5).
#
# THE FIXTURE SEEDS THE REAL uuids, NAMES AND CAS. The ruling names four
# specific live rows, and the fixture reproduces those exact strings rather than
# letting the test invent a convenient spec of its own. A test that supplied its
# own renames would prove the MACHINERY works while leaving the actual shipped
# table - the part a human reviews and the part that can be wrong - completely
# unexercised. Same reasoning as test-migration-007.R's header.

.mig010_load <- function() {
  env <- new.env(parent = globalenv())
  path <- testthat::test_path("..", "..", "dev", "migrations", "010-aroclor-mixture-names.R")
  if (!file.exists(path)) {
    stop(sprintf("migration file not found: %s", path))
  }
  sys.source(path, envir = env)
  env
}

# The four target analytes, verbatim from the live registry (measured read-only,
# `scratchpad/a90_aroclor_cas.md` s2). Repeated here rather than read out of the
# migration so a typo in the migration's table cannot be reproduced by the test
# that is supposed to catch it.
.MIG010_TARGETS <- list(
  list(uuid = "938f0eae-2f1f-4bf0-bcfb-b0063c3bef46",
       old = "3,3',5-Trichlorobiphenyl",          new = "Aroclor 1016",
       old_cas = "38444-87-0", new_cas = "12674-11-2",
       old_long = "3,3',5-trichlorobiphenyl"),
  list(uuid = "0eee4bc2-4508-42fa-b7f8-da1f1991bbd1",
       old = "3,3',5,5'-Tetrachlorobiphenyl",     new = "Aroclor 1248",
       old_cas = "33284-52-5", new_cas = "12672-29-6",
       old_long = "3,3',5,5'-tetrachlorobiphenyl"),
  list(uuid = "e8b555a3-c28a-480d-9b13-006bc46cf63f",
       old = "2,2',3,3',4-Pentachlorobiphenyl",   new = "Aroclor 1254",
       old_cas = "52663-62-4", new_cas = "11097-69-1",
       old_long = "2,2',3,3',4-pentachlorobiphenyl"),
  list(uuid = "34443be4-215a-443e-af4c-a2bb15031495",
       old = "2,2',3,3',4,4'-Hexachlorobiphenyl", new = "Aroclor 1260",
       old_cas = "38380-07-3", new_cas = "11096-82-5",
       old_long = "2,2',3,3',4,4'-hexachlorobiphenyl")
)

# The two MASK-ONLY fixes (Robin, 2026-08-09), also verbatim from the live
# registry and also repeated rather than read out of the migration. `analyte`
# is CORRECT on both and must not move; only the `long` display name is wrong,
# and what it names - `Aroclor 1222`, `Aroclor 1233` - is not a real Aroclor.
.MIG010_MASK_FIXES <- list(
  list(uuid = "fda36258-7c29-4d1d-953a-597f14667c42",
       name = "Aroclor 1221", cas = "11104-28-2",
       old_long = "Aroclor 1222", new_long = "Aroclor 1221"),
  list(uuid = "bb4f58ec-7d96-4c72-b0ca-8f617c6267d9",
       name = "Aroclor 1232", cas = "11141-16-5",
       old_long = "Aroclor 1233", new_long = "Aroclor 1232")
)

.MIG010_ALS_METHOD <- "EP131B: Polychlorinated Biphenyls (as Aroclors)"

#' Seed exactly the rows the ruling names, plus `analyte_mask` (which
#' `seed_db()` does not create - the live database has it and `v_analyte_long`
#' COALESCEs its `name` over `analyte.name`).
.seed_010_fixture <- function(con) {
  DBI::dbExecute(con, "CREATE TABLE analyte_mask (
                         uuid_analyte VARCHAR,
                         variant VARCHAR,
                         name VARCHAR,
                         units VARCHAR,
                         conversion_constant DOUBLE)")

  for (i in seq_along(.MIG010_TARGETS)) {
    t <- .MIG010_TARGETS[[i]]
    DBI::dbExecute(con,
      "INSERT INTO analyte (uuid, name, units, type, CAS) VALUES (?, ?, 'mg/L', 'organic', ?)",
      params = list(t$uuid, t$old, t$old_cas))
    # BOTH mask variants, as the live database has them: `EPA` carries a NULL
    # name (it exists only to set conversion_constant = 1) and so falls through
    # to `analyte.name`; only `long` holds a display name. A fixture with just
    # the `long` row could not catch a migration that rewrote the wrong variant.
    DBI::dbExecute(con,
      "INSERT INTO analyte_mask (uuid_analyte, variant, name, units, conversion_constant)
         VALUES (?, 'long', ?, NULL, NULL), (?, 'EPA', NULL, NULL, 1)",
      params = list(t$uuid, t$old_long, t$uuid))

    # The ALS method that carries the committed analyses, and the ACIRL
    # transcription method migration 006 minted (method NULL, no analyses).
    DBI::dbExecute(con,
      "INSERT INTO lab_method (uuid, uuid_analyte, name, method, organisation) VALUES
         (?, ?, ?, ?, 'ALS'), (?, ?, ?, NULL, 'ACIRL')",
      params = list(sprintf("lm-als-%d", i), t$uuid, t$new, .MIG010_ALS_METHOD,
                    sprintf("lm-acirl-%d", i), t$uuid, t$new))
    # Two committed non-detects each, exactly as live: <0.10 ug/L -> 1e-04 mg/L,
    # quantified FALSE, rl_low == value. The migration must not move them.
    DBI::dbExecute(con,
      "INSERT INTO analysis (uuid, uuid_sample, uuid_lab, value, quantified, rl_low) VALUES
         (?, 's-0001', ?, 1e-04, FALSE, 1e-04), (?, 's-0002', ?, 1e-04, FALSE, 1e-04)",
      params = list(sprintf("an-%d-a", i), sprintf("lm-als-%d", i),
                    sprintf("an-%d-b", i), sprintf("lm-als-%d", i)))
  }

  # The two MASK-ONLY fixes, seeded exactly as live: a CORRECT analyte carrying
  # a `long` mask that names an Aroclor which does not exist. The `EPA` variant
  # is seeded too, with a NULL name, so a migration that rewrote the wrong
  # variant is caught here as well as on the four renames.
  for (i in seq_along(.MIG010_MASK_FIXES)) {
    f <- .MIG010_MASK_FIXES[[i]]
    DBI::dbExecute(con,
      "INSERT INTO analyte (uuid, name, units, type, CAS)
         VALUES (?, ?, 'mg/L', 'organic', ?)",
      params = list(f$uuid, f$name, f$cas))
    DBI::dbExecute(con,
      "INSERT INTO analyte_mask (uuid_analyte, variant, name, units, conversion_constant)
         VALUES (?, 'long', ?, NULL, NULL), (?, 'EPA', NULL, NULL, 1)",
      params = list(f$uuid, f$old_long, f$uuid))
    DBI::dbExecute(con,
      "INSERT INTO lab_method (uuid, uuid_analyte, name, method, organisation)
         VALUES (?, ?, ?, ?, 'ALS')",
      params = list(sprintf("lm-als-fix-%d", i), f$uuid, f$name, .MIG010_ALS_METHOD))
    DBI::dbExecute(con,
      "INSERT INTO analysis (uuid, uuid_sample, uuid_lab, value, quantified, rl_low)
         VALUES (?, 's-0001', ?, 1e-04, FALSE, 1e-04)",
      params = list(sprintf("an-fix-%d", i), sprintf("lm-als-fix-%d", i)))
  }

  # A CONTROL: `Aroclor 1242` is recorded under its archaic OSHA trade name
  # `Chlorodiphenyl` with the CORRECT Aroclor 1242 CAS, and is explicitly out of
  # scope - right substance, old name. It shares the reporting block, the method
  # and the mask shape with the six rows above, so if the migration ever widened
  # to "everything under EP131B" this is the row that says so.
  DBI::dbExecute(con,
    "INSERT INTO analyte (uuid, name, units, type, CAS)
       VALUES ('a-1242', 'Chlorodiphenyl', 'mg/L', 'organic', '53469-21-9')")
  DBI::dbExecute(con,
    "INSERT INTO analyte_mask (uuid_analyte, variant, name, units, conversion_constant)
       VALUES ('a-1242', 'long', 'chlorodiphenyl', NULL, NULL)")
  DBI::dbExecute(con,
    "INSERT INTO lab_method (uuid, uuid_analyte, name, method, organisation)
       VALUES ('lm-als-1242', 'a-1242', 'Aroclor 1242', ?, 'ALS')",
    params = list(.MIG010_ALS_METHOD))
  DBI::dbExecute(con,
    "INSERT INTO analysis (uuid, uuid_sample, uuid_lab, value, quantified, rl_low)
       VALUES ('an-1242', 's-0001', 'lm-als-1242', 1e-04, FALSE, 1e-04)")

  invisible(NULL)
}

.mig010_env <- function() {
  dir <- withr::local_tempdir(.local_envir = parent.frame())
  db <- seed_db(dir = dir)
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = FALSE)
  .seed_010_fixture(con)
  DBI::dbDisconnect(con, shutdown = TRUE)
  snap <- withr::local_tempdir(.local_envir = parent.frame())
  list(db = db, snapshot_dir = snap)
}

.mig010_state <- function(db) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  list(
    marker = DBI::dbGetQuery(
      con, "SELECT version FROM schema_version WHERE version = 1010")$version,
    n_analyte = as.integer(DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM analyte")$n),
    n_lab = as.integer(DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM lab_method")$n),
    n_analysis = as.integer(DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM analysis")$n),
    analyte = DBI::dbGetQuery(con, "SELECT uuid, name, units, type, CAS FROM analyte ORDER BY uuid"),
    mask = DBI::dbGetQuery(con,
      "SELECT uuid_analyte, variant, name FROM analyte_mask ORDER BY uuid_analyte, variant"),
    lab = DBI::dbGetQuery(con,
      "SELECT uuid, uuid_analyte, name, method, organisation FROM lab_method ORDER BY uuid"),
    analysis = DBI::dbGetQuery(con,
      "SELECT uuid, uuid_sample, uuid_lab, value, quantified, rl_low FROM analysis ORDER BY uuid")
  )
}

#' Read one analyte's (name, CAS) out of a database.
.mig010_row <- function(db, uuid) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbGetQuery(con, "SELECT name, CAS FROM analyte WHERE uuid = ?", params = list(uuid))
}

#' Run a statement against the fixture database.
.mig010_exec <- function(db, sql, params = NULL) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = FALSE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbExecute(con, sql, params = params)
}

#' Every pre-backup refusal has the same three obligations: it errors as a
#' `sampletidy_error`, it leaves the database exactly as it found it, and it
#' leaves NO backup behind. `expect_error()` alone would pass for a migration
#' that half-applied and then blew up.
.expect_010_refused <- function(mig, e, regexp = NULL) {
  before <- .mig010_state(e$db)
  expect_error(mig$mig010_run(db = e$db, snapshot_dir = e$snapshot_dir),
               regexp = regexp, class = "sampletidy_error")
  expect_identical(.mig010_state(e$db), before)
  expect_length(list.files(e$snapshot_dir), 0L)
}

# ======================================================================
# the happy path
# ======================================================================

test_that("mig010_run() renames all four analytes and corrects all four CAS", {
  mig <- .mig010_load()
  e <- .mig010_env()
  before <- .mig010_state(e$db)

  res <- mig$mig010_run(db = e$db, snapshot_dir = e$snapshot_dir)
  expect_identical(res$status, "migrated")

  after <- .mig010_state(e$db)
  expect_identical(after$marker, 1010L)
  # A RENAME CREATES AND DELETES NOTHING.
  expect_identical(after$n_analyte, before$n_analyte)
  expect_identical(after$n_lab, before$n_lab)
  expect_identical(after$n_analysis, before$n_analysis)

  for (t in .MIG010_TARGETS) {
    got <- .mig010_row(e$db, t$uuid)
    expect_identical(got$name[[1]], t$new)
    expect_identical(got$CAS[[1]], t$new_cas)
  }
})

test_that("the long-form display name follows, so v_analyte_long stops printing the congener", {
  # `v_analyte_long` reads COALESCE(analyte_mask.name, analyte.name). Renaming
  # only `analyte` would leave the reporting view still naming PCB 36/80/82/128 -
  # the exact publication risk the ruling exists to remove.
  mig <- .mig010_load(); e <- .mig010_env()
  mig$mig010_run(db = e$db, snapshot_dir = e$snapshot_dir)

  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  for (t in .MIG010_TARGETS) {
    got <- DBI::dbGetQuery(con,
      "SELECT variant, name FROM analyte_mask WHERE uuid_analyte = ? ORDER BY variant",
      params = list(t$uuid))
    expect_identical(got$name[got$variant == "long"], t$new)
    # the EPA variant's NULL name is untouched - it falls through on purpose
    expect_true(is.na(got$name[got$variant == "EPA"]))
  }
})

test_that("NOT ONE NUMBER MOVES - every analysis row is byte-identical", {
  # The whole ruling rests on this: all eight committed rows are non-detects at
  # ALS's LOR, so the labels are wrong and the numbers are not.
  mig <- .mig010_load(); e <- .mig010_env()
  before <- .mig010_state(e$db)
  mig$mig010_run(db = e$db, snapshot_dir = e$snapshot_dir)
  after <- .mig010_state(e$db)

  expect_identical(after$analysis, before$analysis)
  expect_identical(after$lab, before$lab)          # lab_method.name is ALS's, already right
})

test_that("the out-of-scope Chlorodiphenyl (Aroclor 1242) is left completely alone", {
  mig <- .mig010_load(); e <- .mig010_env()
  before <- .mig010_state(e$db)
  mig$mig010_run(db = e$db, snapshot_dir = e$snapshot_dir)
  after <- .mig010_state(e$db)

  expect_identical(after$analyte[after$analyte$uuid == "a-1242", ],
                   before$analyte[before$analyte$uuid == "a-1242", ])
  expect_identical(after$mask[after$mask$uuid_analyte == "a-1242", ],
                   before$mask[before$mask$uuid_analyte == "a-1242", ])
})

test_that("no label's resolution moves - asked through the production resolver", {
  # The analyte name is not a resolution key, so this SHOULD be a no-op. That is
  # exactly why it is worth asserting: `.rc_resolve_one_analyte()` does reach
  # `analyte` on the CAS-suggestion path (A66) and this migration rewrites CAS.
  mig <- .mig010_load(); e <- .mig010_env()

  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = TRUE)
  before <- mig$.mig010_label_resolutions(con)
  DBI::dbDisconnect(con, shutdown = TRUE)
  expect_gt(length(before), 0L)          # non-vacuous

  mig$mig010_run(db = e$db, snapshot_dir = e$snapshot_dir)

  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  expect_identical(mig$.mig010_label_resolutions(con), before)
})

test_that("the rename is recorded in change_log, twice per analyte", {
  # Three of the four `analyte.comments` are chemically false as written and are
  # deliberately left in place; the change_log rows are the other half of the
  # record that these were once filed as congeners.
  mig <- .mig010_load(); e <- .mig010_env()
  mig$mig010_run(db = e$db, snapshot_dir = e$snapshot_dir)

  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  got <- DBI::dbGetQuery(con,
    "SELECT tbl, field, old, new, uuid_row FROM change_log
      WHERE actor = '010-aroclor-mixture-names' ORDER BY tbl, field, old")
  expect_identical(sum(got$tbl == "analyte" & got$field == "name"), 4L)
  expect_identical(sum(got$tbl == "analyte" & got$field == "CAS"), 4L)
  # SIX mask rows, not four: the four renames plus the two display-name-only
  # fixes. And still only four `analyte` rows either side, which is the half
  # that says the two fixes did not touch their analyte.
  expect_identical(sum(got$tbl == "analyte_mask" & got$field == "name"), 6L)
  expect_true(all(.MIG010_TARGETS[[1]]$old_cas %in% got$old))
  expect_true(all(c("Aroclor 1222", "Aroclor 1233") %in% got$old))
  expect_false(any(got$tbl == "analyte" &
                     got$uuid_row %in% vapply(.MIG010_MASK_FIXES, `[[`, character(1), "uuid")))
})

# ======================================================================
# the two MASK-ONLY fixes (Robin, 2026-08-09)
# ======================================================================

test_that("both long masks naming a non-existent Aroclor are corrected", {
  mig <- .mig010_load(); e <- .mig010_env()

  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = TRUE)
  before <- DBI::dbGetQuery(con,
    "SELECT uuid_analyte, name FROM analyte_mask WHERE variant = 'long' ORDER BY uuid_analyte")
  DBI::dbDisconnect(con, shutdown = TRUE)
  # NON-VACUOUS: the wrong names really are there to start with
  expect_true(all(c("Aroclor 1222", "Aroclor 1233") %in% before$name))

  mig$mig010_run(db = e$db, snapshot_dir = e$snapshot_dir)

  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  for (f in .MIG010_MASK_FIXES) {
    got <- DBI::dbGetQuery(con,
      "SELECT name FROM analyte_mask WHERE uuid_analyte = ? AND variant = 'long'",
      params = list(f$uuid))
    expect_identical(got$name[[1]], f$new_long)
  }
  after <- DBI::dbGetQuery(con, "SELECT name FROM analyte_mask WHERE variant = 'long'")
  expect_false(any(c("Aroclor 1222", "Aroclor 1233") %in% after$name))
})

test_that("a MASK-ONLY fix does not touch the analyte underneath it", {
  # The half that matters. A fix that "corrected" the display name by renaming
  # the analyte would satisfy the assertion above perfectly.
  mig <- .mig010_load(); e <- .mig010_env()

  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = TRUE)
  uuids <- vapply(.MIG010_MASK_FIXES, `[[`, character(1), "uuid")
  q <- "SELECT uuid, name, CAS, units, type FROM analyte WHERE uuid IN (?, ?) ORDER BY uuid"
  before <- DBI::dbGetQuery(con, q, params = as.list(uuids))
  DBI::dbDisconnect(con, shutdown = TRUE)
  expect_identical(nrow(before), 2L)                    # non-vacuous

  mig$mig010_run(db = e$db, snapshot_dir = e$snapshot_dir)

  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  expect_identical(DBI::dbGetQuery(con, q, params = as.list(uuids)), before)
})

test_that("the EPA mask variant of a mask-fix analyte is untouched", {
  mig <- .mig010_load(); e <- .mig010_env()
  mig$mig010_run(db = e$db, snapshot_dir = e$snapshot_dir)

  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  for (f in .MIG010_MASK_FIXES) {
    got <- DBI::dbGetQuery(con,
      "SELECT name FROM analyte_mask WHERE uuid_analyte = ? AND variant = 'EPA'",
      params = list(f$uuid))
    expect_identical(nrow(got), 1L)
    expect_true(is.na(got$name[[1]]))
  }
})

test_that("it is refused if a mask-fix analyte has been renamed", {
  mig <- .mig010_load(); e <- .mig010_env()
  .mig010_exec(e$db, "UPDATE analyte SET name = 'Aroclor 1221 (edited)' WHERE uuid = ?",
               params = list(.MIG010_MASK_FIXES[[1]]$uuid))
  .expect_010_refused(mig, e, regexp = "must not have moved it|not .*Aroclor 1221")
})

test_that("it is refused if a mask-fix analyte's CAS has moved", {
  mig <- .mig010_load(); e <- .mig010_env()
  .mig010_exec(e$db, "UPDATE analyte SET CAS = '00000-00-0' WHERE uuid = ?",
               params = list(.MIG010_MASK_FIXES[[2]]$uuid))
  .expect_010_refused(mig, e, regexp = "carries CAS")
})

test_that("it is refused if a mask-fix long mask does not hold the name the ruling assumes", {
  mig <- .mig010_load(); e <- .mig010_env()
  .mig010_exec(e$db,
    "UPDATE analyte_mask SET name = 'something else'
      WHERE uuid_analyte = ? AND variant = 'long'",
    params = list(.MIG010_MASK_FIXES[[1]]$uuid))
  .expect_010_refused(mig, e, regexp = "not .*Aroclor 1222")
})

test_that("it is refused if a mask-fix analyte has no long mask row at all", {
  mig <- .mig010_load(); e <- .mig010_env()
  .mig010_exec(e$db,
    "DELETE FROM analyte_mask WHERE uuid_analyte = ? AND variant = 'long'",
    params = list(.MIG010_MASK_FIXES[[2]]$uuid))
  .expect_010_refused(mig, e, regexp = "analyte_mask rows, not exactly 1")
})

test_that("the checksum excuses the mask-fix long names and NOTHING else about them", {
  mig <- .mig010_load(); e <- .mig010_env()
  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = FALSE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  a <- mig$mig010_counts_checksum(con)
  f <- .MIG010_MASK_FIXES[[1]]

  # the `long` name IS excused - that is the cell this fix writes
  DBI::dbExecute(con, "UPDATE analyte_mask SET name = 'x'
                        WHERE uuid_analyte = ? AND variant = 'long'", params = list(f$uuid))
  expect_identical(mig$mig010_counts_checksum(con)$analyte_mask, a$analyte_mask)

  # its ANALYTE is not excused, unlike the four renames
  b <- mig$mig010_counts_checksum(con)
  DBI::dbExecute(con, "UPDATE analyte SET name = 'x' WHERE uuid = ?", params = list(f$uuid))
  expect_false(identical(mig$mig010_counts_checksum(con)$analyte, b$analyte))

  c0 <- mig$mig010_counts_checksum(con)
  DBI::dbExecute(con, "UPDATE analyte SET CAS = 'x' WHERE uuid = ?", params = list(f$uuid))
  expect_false(identical(mig$mig010_counts_checksum(con)$analyte, c0$analyte))
})

test_that(".mig010_verify_renames() catches a mask fix that did not land", {
  mig <- .mig010_load(); e <- .mig010_env()
  mig$mig010_run(db = e$db, snapshot_dir = e$snapshot_dir)

  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = FALSE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  expect_true(mig$.mig010_verify_renames(con))          # non-vacuous: passes first

  DBI::dbExecute(con, "UPDATE analyte_mask SET name = 'Aroclor 1222'
                        WHERE uuid_analyte = ? AND variant = 'long'",
                 params = list(.MIG010_MASK_FIXES[[1]]$uuid))
  expect_error(mig$.mig010_verify_renames(con), class = "sampletidy_error")
})

test_that(".mig010_verify_renames() catches a mask fix that moved its analyte", {
  # The gate has to notice the WRONG way of making the display name agree.
  mig <- .mig010_load(); e <- .mig010_env()
  mig$mig010_run(db = e$db, snapshot_dir = e$snapshot_dir)

  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = FALSE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  expect_true(mig$.mig010_verify_renames(con))          # non-vacuous

  DBI::dbExecute(con, "UPDATE analyte SET name = 'Aroclor 1222' WHERE uuid = ?",
                 params = list(.MIG010_MASK_FIXES[[1]]$uuid))
  expect_error(mig$.mig010_verify_renames(con), class = "sampletidy_error")
})

# ======================================================================
# preconditions - each one refuses BEFORE the backup
# ======================================================================

test_that("it is refused if an analyte no longer carries the name the ruling assumes", {
  mig <- .mig010_load(); e <- .mig010_env()
  .mig010_exec(e$db, "UPDATE analyte SET name = 'PCB 36' WHERE uuid = ?",
               params = list(.MIG010_TARGETS[[1]]$uuid))
  .expect_010_refused(mig, e, regexp = "not .*Trichlorobiphenyl")
})

test_that("it is refused if an analyte no longer carries the CAS the ruling assumes", {
  # The CONGENER CAS being wrong is the entire premise. A different value means
  # something else has already edited this row, and overwriting blindly would
  # clobber it.
  mig <- .mig010_load(); e <- .mig010_env()
  .mig010_exec(e$db, "UPDATE analyte SET CAS = '11097-69-1' WHERE uuid = ?",
               params = list(.MIG010_TARGETS[[2]]$uuid))
  .expect_010_refused(mig, e, regexp = "carries CAS")
})

test_that("it is refused if the long-form display name has moved", {
  mig <- .mig010_load(); e <- .mig010_env()
  .mig010_exec(e$db,
    "UPDATE analyte_mask SET name = 'PCB 82' WHERE uuid_analyte = ? AND variant = 'long'",
    params = list(.MIG010_TARGETS[[3]]$uuid))
  .expect_010_refused(mig, e, regexp = "long-form display name")
})

test_that("it is refused if another analyte already holds the target NAME", {
  # `analyte.name` carries no uniqueness constraint, so nothing but this gate
  # stops the migration minting a second `Aroclor 1254`.
  mig <- .mig010_load(); e <- .mig010_env()
  .mig010_exec(e$db, "INSERT INTO analyte (uuid, name, units, type, CAS)
                        VALUES ('a-clash', 'Aroclor 1254', 'mg/L', 'organic', NULL)")
  .expect_010_refused(mig, e, regexp = "already named")
})

test_that("it is refused if another analyte already holds the target CAS", {
  # Two analytes on one CAS make reconcile's CAS-suggestion path (A66) pick
  # arbitrarily between them.
  mig <- .mig010_load(); e <- .mig010_env()
  .mig010_exec(e$db, "INSERT INTO analyte (uuid, name, units, type, CAS)
                        VALUES ('a-clash', 'Something Else', 'mg/L', 'organic', '11096-82-5')")
  .expect_010_refused(mig, e, regexp = "already carries CAS")
})

test_that("it is refused if a target analyte has vanished", {
  mig <- .mig010_load(); e <- .mig010_env()
  # delete the dependents first - the analyte is FK'd from lab_method
  .mig010_exec(e$db, "DELETE FROM analysis WHERE uuid_lab IN ('lm-als-4')")
  .mig010_exec(e$db, "DELETE FROM lab_method WHERE uuid_analyte = ?",
               params = list(.MIG010_TARGETS[[4]]$uuid))
  .mig010_exec(e$db, "DELETE FROM analyte_mask WHERE uuid_analyte = ?",
               params = list(.MIG010_TARGETS[[4]]$uuid))
  .mig010_exec(e$db, "DELETE FROM analyte WHERE uuid = ?",
               params = list(.MIG010_TARGETS[[4]]$uuid))
  .expect_010_refused(mig, e, regexp = "matches 0 rows")
})

test_that("it is refused if a target has no long-variant mask row", {
  mig <- .mig010_load(); e <- .mig010_env()
  .mig010_exec(e$db,
    "DELETE FROM analyte_mask WHERE uuid_analyte = ? AND variant = 'long'",
    params = list(.MIG010_TARGETS[[1]]$uuid))
  .expect_010_refused(mig, e, regexp = "analyte_mask rows, not exactly 1")
})

test_that("it is refused if a target has TWO long-variant mask rows", {
  # `analyte_mask` has no primary key, so a duplicate is possible and
  # `v_analyte_long` would then emit the analyte twice. Which of the two the
  # migration rewrote would be arbitrary.
  mig <- .mig010_load(); e <- .mig010_env()
  .mig010_exec(e$db,
    "INSERT INTO analyte_mask (uuid_analyte, variant, name) VALUES (?, 'long', 'dupe')",
    params = list(.MIG010_TARGETS[[2]]$uuid))
  .expect_010_refused(mig, e, regexp = "analyte_mask rows, not exactly 1")
})

test_that("it is refused, with an explanation, on a database with no analyte_mask", {
  mig <- .mig010_load(); e <- .mig010_env()
  .mig010_exec(e$db, "DROP TABLE analyte_mask")
  before_files <- list.files(e$snapshot_dir)
  expect_error(mig$mig010_run(db = e$db, snapshot_dir = e$snapshot_dir),
               regexp = "analyte_mask", class = "sampletidy_error")
  expect_identical(list.files(e$snapshot_dir), before_files)
})

test_that("the pre-backup refusal really is pre-backup, not merely unlogged", {
  # The three obligations of `.expect_010_refused()` are worth stating once
  # explicitly: nothing written, no backup, and the marker never set.
  mig <- .mig010_load(); e <- .mig010_env()
  .mig010_exec(e$db, "UPDATE analyte SET name = 'PCB 128' WHERE uuid = ?",
               params = list(.MIG010_TARGETS[[4]]$uuid))
  expect_error(mig$mig010_run(db = e$db, snapshot_dir = e$snapshot_dir),
               class = "sampletidy_error")
  expect_length(.mig010_state(e$db)$marker, 0L)
  expect_length(list.files(e$snapshot_dir), 0L)
})

# ======================================================================
# dry run / idempotency
# ======================================================================

test_that("dry_run checks every precondition and writes nothing", {
  mig <- .mig010_load(); e <- .mig010_env()
  before <- .mig010_state(e$db)
  res <- mig$mig010_run(db = e$db, snapshot_dir = e$snapshot_dir, dry_run = TRUE)

  expect_identical(res$status, "dry_run")
  expect_identical(.mig010_state(e$db), before)
  expect_length(list.files(e$snapshot_dir), 0L)
})

test_that("dry_run still REFUSES a database in the wrong starting state", {
  # A dry run that reported success on a database the real run would refuse
  # would be worse than no dry run at all.
  mig <- .mig010_load(); e <- .mig010_env()
  .mig010_exec(e$db, "UPDATE analyte SET CAS = 'nonsense' WHERE uuid = ?",
               params = list(.MIG010_TARGETS[[1]]$uuid))
  expect_error(mig$mig010_run(db = e$db, snapshot_dir = e$snapshot_dir, dry_run = TRUE),
               class = "sampletidy_error")
})

test_that("re-running is a clean no-op", {
  mig <- .mig010_load(); e <- .mig010_env()
  mig$mig010_run(db = e$db, snapshot_dir = e$snapshot_dir)
  once <- .mig010_state(e$db)
  n_backups <- length(list.files(e$snapshot_dir))

  again <- mig$mig010_run(db = e$db, snapshot_dir = e$snapshot_dir)
  expect_identical(again$status, "already_migrated")
  expect_identical(.mig010_state(e$db), once)
  expect_identical(length(list.files(e$snapshot_dir)), n_backups)  # no second backup
})

test_that("a TORN state - marker present, renames gone - is refused, not reported as done", {
  # 006's header records why: a marker plus a torn state reported as "nothing to
  # do" is worse than a loud failure, because the next thing that reads these
  # names is a published report.
  mig <- .mig010_load(); e <- .mig010_env()
  mig$mig010_run(db = e$db, snapshot_dir = e$snapshot_dir)
  t <- .MIG010_TARGETS[[1]]
  .mig010_exec(e$db, "UPDATE analyte SET name = ? WHERE uuid = ?",
               params = list(t$old, t$uuid))

  expect_error(mig$mig010_run(db = e$db, snapshot_dir = e$snapshot_dir),
               class = "sampletidy_error")
})

test_that("a torn LONG MASK is refused on re-run too", {
  mig <- .mig010_load(); e <- .mig010_env()
  mig$mig010_run(db = e$db, snapshot_dir = e$snapshot_dir)
  t <- .MIG010_TARGETS[[2]]
  .mig010_exec(e$db,
    "UPDATE analyte_mask SET name = ? WHERE uuid_analyte = ? AND variant = 'long'",
    params = list(t$old_long, t$uuid))

  expect_error(mig$mig010_run(db = e$db, snapshot_dir = e$snapshot_dir),
               regexp = "long-form display name", class = "sampletidy_error")
})

# ======================================================================
# the backup
# ======================================================================

test_that("a verified backup is taken, and it holds the PRE-migration names", {
  mig <- .mig010_load(); e <- .mig010_env()
  res <- mig$mig010_run(db = e$db, snapshot_dir = e$snapshot_dir)

  expect_true(file.exists(res$backup_path))
  expect_match(res$restore_command, "^cp ")
  for (t in .MIG010_TARGETS) {
    got <- .mig010_row(res$backup_path, t$uuid)
    expect_identical(got$name[[1]], t$old)
    expect_identical(got$CAS[[1]], t$old_cas)
  }
})

# ======================================================================
# mig010_verify() - THE SAFETY HALF, tested directly
# ======================================================================
#
# A verify gate is protection for the OPERATOR at runtime. An end-to-end test
# that reads a value straight out of the database is already failed by any
# mutation to the WRITE, so it can never be the thing that proves the gate
# works. Every test below asserts the NON-VACUOUS pass first.

test_that("mig010_verify() passes on identical checksums and names what moved", {
  mig <- .mig010_load()
  before <- list(n_analysis = 9L, analysis = "aaa", analyte = "bbb")
  expect_true(mig$mig010_verify(before, before))       # non-vacuous

  for (k in names(before)) {
    after <- before
    after[[k]] <- "MOVED"
    expect_error(mig$mig010_verify(before, after), regexp = k,
                 class = "sampletidy_error")
  }
})

test_that("mig010_verify() catches a key that appears or disappears entirely", {
  # A checksum function that silently stopped emitting `analysis` would make
  # every comparison over the remaining keys pass.
  mig <- .mig010_load()
  before <- list(n_analysis = 9L, analysis = "aaa")
  expect_error(mig$mig010_verify(before, before["n_analysis"]),
               regexp = "analysis", class = "sampletidy_error")
  expect_error(mig$mig010_verify(before["n_analysis"], before),
               regexp = "analysis", class = "sampletidy_error")
})

test_that("mig010_counts_checksum() MOVES when analysis moves, and not otherwise", {
  # Non-vacuity for the checksum itself: if it were constant, `mig010_verify()`
  # would be a gate over nothing.
  mig <- .mig010_load(); e <- .mig010_env()
  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = FALSE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  a <- mig$mig010_counts_checksum(con)
  expect_identical(mig$mig010_counts_checksum(con), a)   # stable

  DBI::dbExecute(con, "UPDATE analysis SET value = value + 1 WHERE uuid = 'an-1-a'")
  expect_false(identical(mig$mig010_counts_checksum(con)$analysis, a$analysis))
})

test_that("the checksum FREEZES every analyte column except name and CAS on the four", {
  # This is what makes "only names and CAS moved" a proof rather than a claim.
  mig <- .mig010_load(); e <- .mig010_env()
  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = FALSE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  a <- mig$mig010_counts_checksum(con)
  t <- .MIG010_TARGETS[[1]]

  # name / CAS on a TARGET row are blanked out - the migration may move them
  DBI::dbExecute(con, "UPDATE analyte SET name = 'x', CAS = 'y' WHERE uuid = ?",
                 params = list(t$uuid))
  expect_identical(mig$mig010_counts_checksum(con)$analyte, a$analyte)

  # ...but units on the same row are NOT
  DBI::dbExecute(con, "UPDATE analyte SET units = 'ug/L' WHERE uuid = ?",
                 params = list(t$uuid))
  expect_false(identical(mig$mig010_counts_checksum(con)$analyte, a$analyte))
})

test_that("the checksum does NOT excuse a name change on a non-target analyte", {
  mig <- .mig010_load(); e <- .mig010_env()
  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = FALSE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  a <- mig$mig010_counts_checksum(con)

  DBI::dbExecute(con, "UPDATE analyte SET name = 'Chlorodiphenyl (renamed)' WHERE uuid = 'a-1242'")
  expect_false(identical(mig$mig010_counts_checksum(con)$analyte, a$analyte))
})

test_that("the checksum freezes the EPA mask variant and every non-target mask row", {
  # Only the four `long` rows are excused. A migration that rewrote the EPA
  # variant, or another analyte's long name, has to be caught.
  mig <- .mig010_load(); e <- .mig010_env()
  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = FALSE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  a <- mig$mig010_counts_checksum(con)
  t <- .MIG010_TARGETS[[1]]

  DBI::dbExecute(con, "UPDATE analyte_mask SET name = 'x'
                        WHERE uuid_analyte = ? AND variant = 'long'", params = list(t$uuid))
  expect_identical(mig$mig010_counts_checksum(con)$analyte_mask, a$analyte_mask)

  DBI::dbExecute(con, "UPDATE analyte_mask SET name = 'x'
                        WHERE uuid_analyte = ? AND variant = 'EPA'", params = list(t$uuid))
  expect_false(identical(mig$mig010_counts_checksum(con)$analyte_mask, a$analyte_mask))

  b <- mig$mig010_counts_checksum(con)
  DBI::dbExecute(con, "UPDATE analyte_mask SET name = 'x' WHERE uuid_analyte = 'a-1242'")
  expect_false(identical(mig$mig010_counts_checksum(con)$analyte_mask, b$analyte_mask))
})

test_that("the SAFETY half catches a stray change to `analysis` made mid-transaction", {
  # `db_update` is looked up in the migration's own environment, so overriding
  # it there injects a write BETWEEN the before- and after-checksums - which is
  # the only place a stray write could hide.
  mig <- .mig010_load(); e <- .mig010_env()
  before <- .mig010_state(e$db)

  real <- db_update
  mig$db_update <- function(con, table, ...) {
    out <- real(con, table, ...)
    if (identical(table, "analyte")) {
      DBI::dbExecute(con, "UPDATE analysis SET value = 99 WHERE uuid = 'an-1-a'")
    }
    out
  }

  expect_error(mig$mig010_run(db = e$db, snapshot_dir = e$snapshot_dir),
               regexp = "analysis", class = "sampletidy_error")
  expect_identical(.mig010_state(e$db), before)   # rolled back whole
})

test_that("the SAFETY half catches a stray change to a NON-target analyte", {
  mig <- .mig010_load(); e <- .mig010_env()
  before <- .mig010_state(e$db)

  real <- db_update
  mig$db_update <- function(con, table, ...) {
    out <- real(con, table, ...)
    if (identical(table, "analyte")) {
      DBI::dbExecute(con, "UPDATE analyte SET CAS = 'clobbered' WHERE uuid = 'a-1242'")
    }
    out
  }

  expect_error(mig$mig010_run(db = e$db, snapshot_dir = e$snapshot_dir),
               class = "sampletidy_error")
  expect_identical(.mig010_state(e$db), before)
})

# ======================================================================
# .mig010_verify_renames() - THE SUCCESS HALF, tested directly
# ======================================================================

test_that(".mig010_verify_renames() catches a name that did not land", {
  mig <- .mig010_load(); e <- .mig010_env()
  mig$mig010_run(db = e$db, snapshot_dir = e$snapshot_dir)

  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = FALSE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  expect_true(mig$.mig010_verify_renames(con))          # non-vacuous: passes first

  DBI::dbExecute(con, "UPDATE analyte SET name = ? WHERE uuid = ?",
                 params = list(.MIG010_TARGETS[[3]]$old, .MIG010_TARGETS[[3]]$uuid))
  expect_error(mig$.mig010_verify_renames(con), class = "sampletidy_error")
})

test_that(".mig010_verify_renames() catches a CAS that did not land", {
  # THE CASE THE END-TO-END TESTS CANNOT KILL. Neutering the CAS branch of the
  # verify leaves every other test green, because they all read `analyte.CAS`
  # straight out of the database and so are already failed by any mutation to
  # the WRITE. A rename that fixed the label and left the congener CAS in place
  # would keep the row lying to every CAS-keyed consumer.
  mig <- .mig010_load(); e <- .mig010_env()
  mig$mig010_run(db = e$db, snapshot_dir = e$snapshot_dir)

  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = FALSE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  expect_true(mig$.mig010_verify_renames(con))          # non-vacuous

  DBI::dbExecute(con, "UPDATE analyte SET CAS = ? WHERE uuid = ?",
                 params = list(.MIG010_TARGETS[[1]]$old_cas, .MIG010_TARGETS[[1]]$uuid))
  expect_error(mig$.mig010_verify_renames(con), regexp = "CAS",
               class = "sampletidy_error")
})

test_that(".mig010_verify_renames() catches a long mask name that did not land", {
  mig <- .mig010_load(); e <- .mig010_env()
  mig$mig010_run(db = e$db, snapshot_dir = e$snapshot_dir)

  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = FALSE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  expect_true(mig$.mig010_verify_renames(con))          # non-vacuous

  DBI::dbExecute(con, "UPDATE analyte_mask SET name = ?
                        WHERE uuid_analyte = ? AND variant = 'long'",
                 params = list(.MIG010_TARGETS[[4]]$old_long, .MIG010_TARGETS[[4]]$uuid))
  expect_error(mig$.mig010_verify_renames(con), regexp = "long-form",
               class = "sampletidy_error")
})

test_that("a WRITE that silently did nothing is caught by the in-run success gate", {
  # MUTATION-DRIVEN. Removing the `.mig010_verify_renames()` call from inside
  # `mig010_run()`'s transaction killed no test: every end-to-end test reads the
  # database afterwards, and the SAFETY checksum deliberately EXEMPTS `name` and
  # `CAS` on these four rows - so a `db_update` that quietly wrote nothing would
  # sail through the checksum and get the marker recorded. The in-run gate is
  # the only thing standing between that and a "migrated successfully" line.
  mig <- .mig010_load(); e <- .mig010_env()
  before <- .mig010_state(e$db)

  real <- db_update
  mig$db_update <- function(con, table, ...) {
    if (identical(table, "analyte")) return(invisible(NULL))   # silently no-op
    real(con, table, ...)
  }

  expect_error(mig$mig010_run(db = e$db, snapshot_dir = e$snapshot_dir),
               class = "sampletidy_error")
  expect_length(.mig010_state(e$db)$marker, 0L)
  expect_identical(.mig010_state(e$db), before)     # rolled back whole
})

test_that("a MASK write that silently did nothing is caught the same way", {
  mig <- .mig010_load(); e <- .mig010_env()
  before <- .mig010_state(e$db)

  real <- db_update
  mig$db_update <- function(con, table, ...) {
    if (identical(table, "analyte_mask")) return(invisible(NULL))
    real(con, table, ...)
  }

  expect_error(mig$mig010_run(db = e$db, snapshot_dir = e$snapshot_dir),
               regexp = "long-form", class = "sampletidy_error")
  expect_identical(.mig010_state(e$db), before)
})

test_that(".mig010_verify_renames() catches a target analyte that has vanished", {
  mig <- .mig010_load(); e <- .mig010_env()
  mig$mig010_run(db = e$db, snapshot_dir = e$snapshot_dir)

  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = FALSE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  expect_true(mig$.mig010_verify_renames(con))

  DBI::dbExecute(con, "UPDATE analyte SET uuid = 'moved' WHERE uuid = ?",
                 params = list(.MIG010_TARGETS[[2]]$uuid))
  expect_error(mig$.mig010_verify_renames(con), class = "sampletidy_error")
})

test_that(".mig010_label_resolutions() refuses to pass vacuously over an empty set", {
  # A stability check over zero labels proves nothing, and would go quiet
  # exactly when the lab_methods it is guarding had been destroyed.
  mig <- .mig010_load(); e <- .mig010_env()
  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = FALSE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  expect_gt(length(mig$.mig010_label_resolutions(con)), 0L)   # non-vacuous

  DBI::dbExecute(con, "DELETE FROM analysis")
  DBI::dbExecute(con, "UPDATE lab_method SET uuid_analyte = NULL")
  expect_error(mig$.mig010_label_resolutions(con), class = "sampletidy_error")
})

# ======================================================================
# the shipped table, and its cross-file pin to 006
# ======================================================================

test_that("the shipped rename table is internally coherent", {
  # Guards the copy-and-paste failure mode a review reads straight past: a
  # duplicated CAS, or a `to_CAS` accidentally left equal to the congener's.
  mig <- .mig010_load()
  expect_identical(length(mig$.mig010_renames), 4L)

  from_cas <- vapply(mig$.mig010_renames, function(s) s$from_CAS, character(1))
  to_cas   <- vapply(mig$.mig010_renames, function(s) s$to_CAS, character(1))
  to_name  <- vapply(mig$.mig010_renames, function(s) s$to_name, character(1))

  expect_length(unique(c(from_cas, to_cas)), 8L)   # eight distinct CAS numbers
  expect_length(unique(to_name), 4L)
  expect_true(all(nzchar(to_cas)))
  # the long-form display name IS the new name - the whole point of moving it
  expect_identical(vapply(mig$.mig010_renames, function(s) s$to_long, character(1)),
                   to_name)
})

test_that("the shipped table matches the ruling, uuid by uuid", {
  # Pins the actual reviewed file against the four rows measured read-only out
  # of the live registry. If a literal in the migration ever drifts, this is
  # what says so - the fixture alone could drift with it.
  mig <- .mig010_load()
  by_uuid <- stats::setNames(mig$.mig010_renames,
                             vapply(mig$.mig010_renames, function(s) s$uuid, character(1)))
  for (t in .MIG010_TARGETS) {
    spec <- by_uuid[[t$uuid]]
    expect_false(is.null(spec))
    expect_identical(spec$from_name, t$old)
    expect_identical(spec$to_name,   t$new)
    expect_identical(spec$from_CAS,  t$old_cas)
    expect_identical(spec$to_CAS,    t$new_cas)
    expect_identical(spec$from_long, t$old_long)
  }
})

test_that("006's mapping names the NEW analyte names against the SAME uuids", {
  # THE CROSS-FILE PIN, the mirror of test-migration-007's. 006 is already
  # applied to the live database; its `already_migrated` branch re-verifies by
  # resolving each label and comparing `uuid_analyte`, and never reads the CSV's
  # `analyte` NAME column - so this edit cannot break a 006 re-run. The name
  # column IS read by `.mig006_check_preconditions()`, on an UNMIGRATED
  # database, which is why the two files have to agree.
  mig <- .mig010_load()
  path <- testthat::test_path("..", "..", "dev", "migrations",
                              "006-acirl-transcription-methods.csv")
  skip_if_not(file.exists(path))
  map <- utils::read.csv(path, stringsAsFactors = FALSE, colClasses = "character",
                         na.strings = character(0), encoding = "UTF-8")

  for (spec in mig$.mig010_renames) {
    rows <- map[map$uuid_analyte == spec$uuid, , drop = FALSE]
    expect_identical(nrow(rows), 1L)
    expect_identical(rows$analyte[[1]], spec$to_name)
    # ...and the OLD congener name is gone from the mapping entirely
    expect_identical(sum(map$analyte == spec$from_name), 0L)
  }
})

test_that("006's mapping still resolves the four Aroclor labels by their own uuids", {
  # The uuids are what 006's already-applied re-verification compares. If this
  # edit had moved any of them, a 006 re-run would abort on the live database.
  mig <- .mig010_load()
  path <- testthat::test_path("..", "..", "dev", "migrations",
                              "006-acirl-transcription-methods.csv")
  skip_if_not(file.exists(path))
  map <- utils::read.csv(path, stringsAsFactors = FALSE, colClasses = "character",
                         na.strings = character(0), encoding = "UTF-8")
  for (spec in mig$.mig010_renames) {
    row <- map[map$label == spec$to_name, , drop = FALSE]
    expect_identical(nrow(row), 1L)
    expect_identical(row$uuid_analyte[[1]], spec$uuid)
  }
})

test_that("the three already-correct Aroclors are NOT in the rename table", {
  # Explicitly out of scope: 1221 and 1232 are right, and `Chlorodiphenyl` is
  # Aroclor 1242 under its archaic OSHA name with the correct CAS 53469-21-9.
  mig <- .mig010_load()
  touched <- c(vapply(mig$.mig010_renames, function(s) s$uuid, character(1)))
  expect_false(any(c("fda36258-7c29-4d1d-953a-597f14667c42",
                     "bb4f58ec-7d96-4c72-b0ca-8f617c6267d9",
                     "4cce075a-7ac4-449e-a6c5-1d791818bc42") %in% touched))
  cas <- vapply(mig$.mig010_renames, function(s) s$to_CAS, character(1))
  expect_false("53469-21-9" %in% cas)
})

test_that("mig010_run() refuses when the package is not loaded", {
  # The success gate calls the internal `.rc_load_registry()` /
  # `.rc_resolve_one_analyte()`. Sourced into an environment whose parent is
  # `baseenv()` they are unreachable, which is exactly the operator's mistake of
  # running the file without `devtools::load_all(".")`. Without this guard the
  # run would get as far as the writes and then fail inside the transaction with
  # an "object not found" naming nothing useful.
  e <- .mig010_env()
  env <- new.env(parent = baseenv())
  path <- testthat::test_path("..", "..", "dev", "migrations", "010-aroclor-mixture-names.R")
  sys.source(path, envir = env)

  expect_error(env$mig010_run(db = e$db, snapshot_dir = e$snapshot_dir),
               regexp = "load_all", class = "sampletidy_error")
  expect_length(.mig010_state(e$db)$marker, 0L)
  expect_length(list.files(e$snapshot_dir), 0L)
})
