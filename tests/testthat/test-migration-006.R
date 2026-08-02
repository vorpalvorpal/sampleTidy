# dev/migrations/006-acirl-transcription-methods.R - A79 step 6a: mint one
# resolving ACIRL `lab_method` per transcription label, so the transcription
# import can tell an ACIRL copy of an ALS number from a field reading.
#
#   mig006_run(db, snapshot_dir, mapping, dry_run = FALSE, .now = NULL,
#              .uuid_fn = uuid::UUIDgenerate)
#     -> invisible list(status = "migrated" | "already_migrated" | "dry_run",
#        backup_path, restore_command, n_methods, counts_before, counts_after,
#        recorded_at)
#
# Every test sources the target file inside its own `test_that()` (never at file
# top level), so a missing/broken target surfaces as ordinary per-test failures
# rather than a whole-file collection error that would silently zero out every
# other test's coverage - test-migration-004.R's Phase-5 audit finding B5, kept.
#
# THE FIXTURE'S ONE LOAD-BEARING PROPERTY: `seed_db()` already contains an ALS
# `lab_method` for some of the labels under test. That is not decoration - it is
# what makes these tests non-vacuous. Analyte resolution is PER ORGANISATION, so
# an ALS `Calcium` method must NOT make an ACIRL `Calcium` row resolve. If it
# did, this whole migration would be unnecessary, and a test that passed without
# the ALS row present could not tell the difference.

.mig006_load <- function() {
  env <- new.env(parent = globalenv())
  path <- testthat::test_path("..", "..", "dev", "migrations",
                              "006-acirl-transcription-methods.R")
  if (!file.exists(path)) {
    stop(sprintf("migration file not found: %s", path))
  }
  sys.source(path, envir = env)
  env
}

#' Seed the analytes and the cross-organisation ALS methods the 006 fixture
#' needs, on top of `seed_db()`.
#'
#' `lm-9001` (ALS, name `Calcium`, resolving to `a-9001`) is the non-vacuity
#' anchor described in this file's header: it proves the ACIRL row does not
#' resolve through some OTHER organisation's method.
#'
#' @param con an open read-write DBI connection to a `seed_db()` database.
#' @return invisible(NULL).
.seed_006_fixture <- function(con) {
  DBI::dbExecute(con, "INSERT INTO analyte (uuid, name, units, type, CAS) VALUES
    ('a-9001', 'Calcium', 'mg/L', 'cation', '7440-70-2'),
    ('a-9002', 'Arsenic', 'mg/L', 'metal',  '7440-38-2'),
    ('a-9003', 'TSS',     'mg/L', 'physical', NULL)")

  DBI::dbExecute(con, "INSERT INTO lab_method
    (uuid, uuid_analyte, name, method, organisation, rl_low, units, conversion_constant) VALUES
    ('lm-9001', 'a-9001', 'Calcium', 'ED093F: Dissolved Major Cations', 'ALS', 0.1, NULL, NULL),
    ('lm-9002', 'a-9003', 'Suspended Solids (SS)', 'EA025: Total Suspended Solids', 'ALS', 5, NULL, NULL)")

  invisible(NULL)
}

#' The mapping every happy-path test uses.
#'
#' Three labels, none of which folds onto any `seed_db()` ACIRL method
#' (`pH`, `EC`, `Temperature`, `Standing Water Level`, `Standing water level`).
.mig006_map <- function() {
  data.frame(
    label = c("Calcium", "Arsenic", "Total Suspended Solids"),
    analyte = c("Calcium", "Arsenic", "TSS"),
    uuid_analyte = c("a-9001", "a-9002", "a-9003"),
    stringsAsFactors = FALSE
  )
}

#' Build a seeded DB + snapshot dir, both bound to the CALLER's frame.
#'
#' `withr::local_tempdir(.local_envir = parent.frame())` is threaded through
#' deliberately: bound to this helper's own frame the directory would be deleted
#' the instant the helper returned, handing the test a dead path (`seed_db()`'s
#' own note).
.mig006_env <- function() {
  dir <- withr::local_tempdir(.local_envir = parent.frame())
  db <- seed_db(dir = dir)
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = FALSE)
  .seed_006_fixture(con)
  DBI::dbDisconnect(con, shutdown = TRUE)
  snap <- withr::local_tempdir(.local_envir = parent.frame())
  list(db = db, snapshot_dir = snap)
}

#' Read helper: everything a test wants to know about the post-run state.
.mig006_state <- function(db) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  list(
    marker = DBI::dbGetQuery(
      con, "SELECT version FROM schema_version WHERE version = 1006")$version,
    acirl = DBI::dbGetQuery(
      con,
      "SELECT uuid, name, method, units, organisation, uuid_analyte
       FROM lab_method WHERE organisation = 'ACIRL' ORDER BY name"),
    n_lab = as.integer(DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM lab_method")$n),
    n_analysis = as.integer(DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM analysis")$n),
    change_log = DBI::dbGetQuery(
      con,
      "SELECT uuid_row, reason FROM change_log
       WHERE tbl = 'lab_method' AND action = 'insert'")
  )
}

# ======================================================================
# Happy path
# ======================================================================

test_that("mig006_run() mints one resolving ACIRL method per mapping row", {
  mig <- .mig006_load()
  e <- .mig006_env()

  before <- .mig006_state(e$db)
  res <- mig$mig006_run(db = e$db, snapshot_dir = e$snapshot_dir,
                        mapping = .mig006_map())

  expect_identical(res$status, "migrated")
  expect_identical(res$n_methods, 3L)

  after <- .mig006_state(e$db)
  expect_identical(after$n_lab, before$n_lab + 3L)
  expect_identical(after$marker, 1006L)
})

test_that("the minted methods carry NULL method and NULL units under ACIRL", {
  mig <- .mig006_load()
  e <- .mig006_env()

  mig$mig006_run(db = e$db, snapshot_dir = e$snapshot_dir, mapping = .mig006_map())

  st <- .mig006_state(e$db)
  new <- st$acirl[st$acirl$name %in% .mig006_map()$label, , drop = FALSE]
  expect_identical(nrow(new), 3L)
  expect_true(all(is.na(new$method)))
  expect_true(all(is.na(new$units)))
  expect_true(all(new$organisation == "ACIRL"))
  expect_identical(
    new$uuid_analyte[order(new$name)],
    .mig006_map()$uuid_analyte[order(.mig006_map()$label)]
  )
})

test_that("every mapped label resolves through the PRODUCTION resolver", {
  # The property that actually matters, asked the way the import will ask it.
  mig <- .mig006_load()
  e <- .mig006_env()
  map <- .mig006_map()

  mig$mig006_run(db = e$db, snapshot_dir = e$snapshot_dir, mapping = map)

  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  registry <- .rc_load_registry(con)

  for (i in seq_len(nrow(map))) {
    got <- .rc_resolve_one_analyte(map$label[[i]], "ACIRL", NA_character_, registry)
    expect_identical(got$status, "resolved")
    expect_identical(got$uuid_analyte, map$uuid_analyte[[i]])
    expect_identical(.rc_lab_kind(got$uuid_lab, registry), "acirl_transcription")
  }
})

test_that("before the migration those same labels do NOT resolve - the ALS method is not enough", {
  # NON-VACUITY for the test above. `seed_db()` + the fixture already hold an
  # ALS `Calcium` method resolving to a-9001. If cross-organisation resolution
  # worked, the migration would be pointless and the previous test would pass
  # for the wrong reason.
  e <- .mig006_env()

  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  registry <- .rc_load_registry(con)

  als <- .rc_resolve_one_analyte("Calcium", "ALS", NA_character_, registry)
  expect_identical(als$status, "resolved")
  expect_identical(als$uuid_analyte, "a-9001")

  acirl <- .rc_resolve_one_analyte("Calcium", "ACIRL", NA_character_, registry)
  expect_identical(acirl$status, "miss")
  expect_true(is.na(acirl$uuid_analyte))
})

test_that("a row carrying a method code still resolves against the NULL-method method", {
  # Measured behaviour, pinned because it is load-bearing and non-obvious: the
  # exact branch misses (method NA vs a code), but the folded branch narrows on
  # method ONLY when there is more than one candidate, so a single NULL-method
  # ACIRL method is a catch-all for that label. If this ever changes, an ACIRL
  # sheet that started carrying method codes would silently stop resolving.
  mig <- .mig006_load()
  e <- .mig006_env()

  mig$mig006_run(db = e$db, snapshot_dir = e$snapshot_dir, mapping = .mig006_map())

  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  registry <- .rc_load_registry(con)

  got <- .rc_resolve_one_analyte("Calcium", "ACIRL", "SOME-CODE", registry)
  expect_identical(got$status, "resolved")
  expect_identical(got$uuid_analyte, "a-9001")
})

test_that("`analysis` is untouched and every insert is in change_log", {
  mig <- .mig006_load()
  e <- .mig006_env()

  before <- .mig006_state(e$db)
  mig$mig006_run(db = e$db, snapshot_dir = e$snapshot_dir, mapping = .mig006_map())
  after <- .mig006_state(e$db)

  expect_identical(after$n_analysis, before$n_analysis)
  expect_identical(nrow(after$change_log), nrow(before$change_log) + 3L)
  expect_true(all(grepl("A79 step 6a", tail(after$change_log$reason, 3))))
})

test_that("the backup is taken, verified and named in the result", {
  mig <- .mig006_load()
  e <- .mig006_env()

  res <- mig$mig006_run(db = e$db, snapshot_dir = e$snapshot_dir,
                        mapping = .mig006_map())

  expect_true(file.exists(res$backup_path))
  expect_match(res$backup_path, "pre-006-acirl-transcription-methods")
  expect_match(res$restore_command, "^cp ")
})

test_that("re-running is a clean no-op", {
  mig <- .mig006_load()
  e <- .mig006_env()

  mig$mig006_run(db = e$db, snapshot_dir = e$snapshot_dir, mapping = .mig006_map())
  once <- .mig006_state(e$db)

  again <- mig$mig006_run(db = e$db, snapshot_dir = e$snapshot_dir,
                          mapping = .mig006_map())
  twice <- .mig006_state(e$db)

  expect_identical(again$status, "already_migrated")
  expect_identical(twice$n_lab, once$n_lab)
  expect_identical(nrow(twice$change_log), nrow(once$change_log))
})

test_that("a GROWN mapping is refused, not reported as `already_migrated`", {
  # ADVERSARIAL-AUDIT FINDING. `-EXCLUDED.csv` tells the operator to create an
  # analyte and "then add to this mapping", and 4 of its 7 rows await a ruling -
  # so a LARGER mapping on a second run is the designed workflow. Trusting the
  # marker alone reported "nothing to do", the new label was never linked, and
  # it then dangles at import with no analyte for A79's twin test: the exact
  # failure this migration exists to prevent, reintroduced by its own no-op path.
  mig <- .mig006_load()
  e <- .mig006_env()

  mig$mig006_run(db = e$db, snapshot_dir = e$snapshot_dir, mapping = .mig006_map())
  once <- .mig006_state(e$db)

  grown <- .mig006_map()
  grown[nrow(grown) + 1, ] <- list("Magnesium", "Calcium", "a-9001")

  expect_error(
    mig$mig006_run(db = e$db, snapshot_dir = e$snapshot_dir, mapping = grown),
    class = "sampletidy_error"
  )
  # ...and it refuses without touching anything.
  expect_identical(.mig006_state(e$db)$n_lab, once$n_lab)
})

test_that("a TORN state - marker present, minted rows gone - is refused", {
  mig <- .mig006_load()
  e <- .mig006_env()
  mig$mig006_run(db = e$db, snapshot_dir = e$snapshot_dir, mapping = .mig006_map())

  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = FALSE)
  DBI::dbExecute(con, "DELETE FROM lab_method
    WHERE organisation = 'ACIRL' AND method IS NULL AND name IN ('Calcium','Arsenic','Total Suspended Solids')")
  DBI::dbDisconnect(con, shutdown = TRUE)

  expect_error(
    mig$mig006_run(db = e$db, snapshot_dir = e$snapshot_dir, mapping = .mig006_map()),
    class = "sampletidy_error"
  )
})

test_that("an unchanged mapping on an applied DB is still a clean no-op", {
  # Non-vacuity for the two tests above: the new check must not turn the
  # ordinary, correct re-run into an error.
  mig <- .mig006_load()
  e <- .mig006_env()
  mig$mig006_run(db = e$db, snapshot_dir = e$snapshot_dir, mapping = .mig006_map())
  again <- mig$mig006_run(db = e$db, snapshot_dir = e$snapshot_dir, mapping = .mig006_map())
  expect_identical(again$status, "already_migrated")
})

test_that("the SAFETY half catches a change to ANY column of ANY table", {
  # ADVERSARIAL-AUDIT FINDING: the first checksum named 6 of 18 tables, checked
  # 5 of them by row count only, and hashed 4 of `analysis`'s 10 columns - so
  # flipping every non-detect to a detect, or rewriting `rl_low`/`comments`/
  # `purpose`, or deleting every `project` row, all passed. Each mutation below
  # is one the audit demonstrated slipping through.
  mig <- .mig006_load()

  mutations <- list(
    "analysis.quantified" = "UPDATE analysis SET quantified = NOT quantified",
    "analysis.rl_low"     = "UPDATE analysis SET rl_low = COALESCE(rl_low, 0) + 1",
    "analysis.comments"   = "UPDATE analysis SET comments = 'mutated'",
    "analysis.purpose"    = "UPDATE analysis SET purpose = 'mutated'",
    "analyte.name"        = "UPDATE analyte SET name = name || 'x'",
    "feature.name"        = "UPDATE feature SET name = name || 'x'",
    "project (delete all)" = "DELETE FROM project"
  )

  for (nm in names(mutations)) {
    e <- .mig006_env()
    before <- .mig006_state(e$db)
    m <- .mig006_load()
    append_ok <- m$.mig006_append_methods
    m$.mig006_append_methods <- function(con, map, uuid_fn = uuid::UUIDgenerate) {
      out <- append_ok(con, map, uuid_fn = uuid_fn)
      DBI::dbExecute(con, mutations[[nm]])
      out
    }
    expect_error(
      m$mig006_run(db = e$db, snapshot_dir = e$snapshot_dir, mapping = .mig006_map()),
      class = "sampletidy_error",
      info = nm
    )
    expect_identical(.mig006_state(e$db)$n_lab, before$n_lab, info = nm)
  }
})

test_that("labels are trimmed Unicode-aware, not just ASCII", {
  # ADVERSARIAL-AUDIT FINDING: `trimws()` is ASCII-only, so a leading NBSP,
  # thin space, ZWSP or BOM slipped past the whitespace gate. PLAN-15 F.2
  # records a real duplicate-alias defect from exactly that.
  mig <- .mig006_load()
  for (ws in c(" ", " ", "​", "﻿")) {
    e <- .mig006_env()
    map <- .mig006_map(); map$label[[1]] <- paste0(ws, "Calcium")
    expect_error(
      mig$mig006_run(db = e$db, snapshot_dir = e$snapshot_dir, mapping = map),
      class = "sampletidy_error",
      info = sprintf("U+%04X", utf8ToInt(ws))
    )
  }
})

test_that("a mapping that is neither a data frame nor a path raises sampletidy_error", {
  mig <- .mig006_load()
  e <- .mig006_env()
  for (bad in list(42L, list(1, 2), NULL, c("a", "b"), NA_character_)) {
    expect_error(
      mig$mig006_run(db = e$db, snapshot_dir = e$snapshot_dir, mapping = bad),
      class = "sampletidy_error"
    )
  }
})

test_that("a label that is literally \"NA\" survives the CSV path", {
  # `read.csv`'s default na.strings would turn it into a missing value, so the
  # CSV path refused a row the data-frame path accepts. Nothing in the real
  # mapping is called "NA"; the point is that the two paths must agree.
  mig <- .mig006_load()
  e <- .mig006_env()
  dir <- withr::local_tempdir()
  path <- file.path(dir, "map.csv")
  map <- .mig006_map(); map$label[[3]] <- "NA"
  utils::write.csv(map, path, row.names = FALSE)

  res <- mig$mig006_run(db = e$db, snapshot_dir = e$snapshot_dir, mapping = path)
  expect_identical(res$status, "migrated")

  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  registry <- .rc_load_registry(con)
  got <- .rc_resolve_one_analyte("NA", "ACIRL", NA_character_, registry)
  expect_identical(got$status, "resolved")
})

test_that("dry_run writes nothing at all - no rows, no marker, no backup", {
  mig <- .mig006_load()
  e <- .mig006_env()

  before <- .mig006_state(e$db)
  res <- mig$mig006_run(db = e$db, snapshot_dir = e$snapshot_dir,
                        mapping = .mig006_map(), dry_run = TRUE)
  after <- .mig006_state(e$db)

  expect_identical(res$status, "dry_run")
  expect_identical(res$n_methods, 3L)
  expect_identical(after$n_lab, before$n_lab)
  expect_length(after$marker, 0L)
  expect_length(list.files(e$snapshot_dir), 0L)
})

# ======================================================================
# Mapping validation - each refuses, and nothing is written
# ======================================================================

#' Assert a run aborts with `sampletidy_error` AND leaves the database exactly
#' as it was. A gate that refuses but half-writes is worse than no gate.
.expect_006_refused <- function(mig, e, mapping) {
  before <- .mig006_state(e$db)
  expect_error(
    mig$mig006_run(db = e$db, snapshot_dir = e$snapshot_dir, mapping = mapping),
    class = "sampletidy_error"
  )
  after <- .mig006_state(e$db)
  expect_identical(after$n_lab, before$n_lab)
  expect_length(after$marker, 0L)
  # A run that could never have succeeded must not leave a stray backup copy
  # behind (005's rule). Every gate reached here is checkable read-only, so
  # every one of them runs before the backup is taken.
  expect_length(list.files(e$snapshot_dir), 0L)
  invisible(TRUE)
}

test_that("an empty mapping is refused rather than reported as success", {
  mig <- .mig006_load()
  e <- .mig006_env()
  .expect_006_refused(mig, e, .mig006_map()[0, , drop = FALSE])
})

test_that("a missing required column is refused", {
  mig <- .mig006_load()
  e <- .mig006_env()
  .expect_006_refused(mig, e, .mig006_map()[, c("label", "analyte")])
})

test_that("a blank cell is refused, and refused BY THE BLANK GATE", {
  # MUTATION-DRIVEN. Asserting only "this is refused" made the blank gate look
  # protective when it is not: with it removed, a blank `uuid_analyte` is caught
  # by the unknown-analyte gate, a blank `label` by the folds-to-nothing gate,
  # and a blank `analyte` by the name-drift gate. The blank check is a
  # DIAGNOSTIC-QUALITY gate, not a detection one - it names the offending column
  # and row before any database is opened. So the test pins the message, which
  # is the only thing it actually contributes.
  mig <- .mig006_load()
  e <- .mig006_env()
  map <- .mig006_map(); map$uuid_analyte[[2]] <- ""
  expect_error(
    mig$mig006_run(db = e$db, snapshot_dir = e$snapshot_dir, mapping = map),
    regexp = "`uuid_analyte` is blank on row\\(s\\) 2",
    class = "sampletidy_error"
  )
  .expect_006_refused(mig, e, map)
})

test_that("a label with surrounding whitespace is refused, not silently trimmed", {
  mig <- .mig006_load()
  e <- .mig006_env()
  map <- .mig006_map(); map$label[[1]] <- " Calcium"
  .expect_006_refused(mig, e, map)
})

test_that("a duplicate label is refused", {
  mig <- .mig006_load()
  e <- .mig006_env()
  map <- .mig006_map(); map$label[[2]] <- "Calcium"; map$analyte[[2]] <- "Calcium"
  map$uuid_analyte[[2]] <- "a-9001"
  .expect_006_refused(mig, e, map)
})

test_that("two labels folding to one key with DIFFERENT analytes are refused", {
  # `.rc_method_key()` strips non-alphanumerics and case-folds, so `Calcium`
  # and `calcium!` are one key. With two different analytes behind that key,
  # `.rc_resolve_one_analyte()` returns `ambiguous` and BOTH labels stop
  # resolving - strictly worse than not running at all.
  mig <- .mig006_load()
  e <- .mig006_env()
  map <- .mig006_map(); map$label[[2]] <- "calcium!"   # row 2's analyte is a-9002
  .expect_006_refused(mig, e, map)
})

test_that("two labels folding to one key with the SAME analyte are ALLOWED", {
  # The live corpus has exactly this: `Azinphos Methyl` and `Azinphos-methyl`,
  # one analyte between them. A stricter gate would refuse it, and the label
  # would be dropped for a danger that does not exist - the folded branch
  # resolves whenever the survivors agree on the analyte. Both must resolve.
  mig <- .mig006_load()
  e <- .mig006_env()
  map <- .mig006_map()
  map[nrow(map) + 1, ] <- list("calcium!", "Calcium", "a-9001")

  res <- mig$mig006_run(db = e$db, snapshot_dir = e$snapshot_dir, mapping = map)
  expect_identical(res$status, "migrated")

  con <- DBI::dbConnect(duckdb::duckdb(), e$db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  registry <- .rc_load_registry(con)
  for (lb in c("Calcium", "calcium!")) {
    got <- .rc_resolve_one_analyte(lb, "ACIRL", NA_character_, registry)
    expect_identical(got$status, "resolved")
    expect_identical(got$uuid_analyte, "a-9001")
  }
})

test_that("a label that folds to nothing is refused", {
  mig <- .mig006_load()
  e <- .mig006_env()
  map <- .mig006_map(); map$label[[2]] <- "--"
  .expect_006_refused(mig, e, map)
})

test_that("an analyte uuid that does not exist is refused, BY THE UUID GATE", {
  # MUTATION-DRIVEN, same shape as the blank-cell gate. Once the name-drift
  # check became NA-safe it also catches an unknown uuid (the name lookup
  # returns NA), so "is this refused?" no longer distinguishes the two. The
  # unknown-uuid gate earns its place by naming the real problem - a uuid that
  # is not in `analyte` - and telling the operator to use add_analyte() first,
  # so that message is what the test pins.
  mig <- .mig006_load()
  e <- .mig006_env()
  map <- .mig006_map(); map$uuid_analyte[[3]] <- "a-does-not-exist"
  expect_error(
    mig$mig006_run(db = e$db, snapshot_dir = e$snapshot_dir, mapping = map),
    regexp = "do not exist in `analyte`",
    class = "sampletidy_error"
  )
  .expect_006_refused(mig, e, map)
})

test_that("an analyte NAME that disagrees with its uuid is refused", {
  # The redundant `analyte` column exists so a human can review the mapping.
  # If a hand edit moves the name without the uuid, the reviewed thing and the
  # linked thing are different - the one error the uuid alone cannot show.
  mig <- .mig006_load()
  e <- .mig006_env()
  map <- .mig006_map(); map$analyte[[1]] <- "Magnesium"
  .expect_006_refused(mig, e, map)
})

test_that("a label already claimed by an ACIRL method is refused", {
  # `seed_db()` holds ACIRL `pH`. Minting a second `pH` method would make the
  # label ambiguous instead of resolving it.
  mig <- .mig006_load()
  e <- .mig006_env()
  map <- .mig006_map()
  map[nrow(map) + 1, ] <- list("pH", "Calcium", "a-9001")
  .expect_006_refused(mig, e, map)
})

test_that("the collision gate folds, so a case/punctuation variant is caught too", {
  mig <- .mig006_load()
  e <- .mig006_env()
  map <- .mig006_map()
  map[nrow(map) + 1, ] <- list("p.H", "Calcium", "a-9001")
  .expect_006_refused(mig, e, map)
})

# ======================================================================
# The verify gate - mutate the loaded environment and prove it catches it
# ======================================================================

test_that("verify catches a write under the wrong organisation, and rolls back", {
  mig <- .mig006_load()
  e <- .mig006_env()
  before <- .mig006_state(e$db)

  mig$.mig006_rows <- function(map, uuids) {
    data.frame(uuid = uuids, uuid_analyte = map$uuid_analyte, name = map$label,
               method = NA_character_, organisation = "ALS", rl_low = NA_real_,
               rl_high = NA_real_, units = NA_character_,
               conversion_constant = NA_real_, stringsAsFactors = FALSE)
  }

  expect_error(
    mig$mig006_run(db = e$db, snapshot_dir = e$snapshot_dir, mapping = .mig006_map()),
    class = "sampletidy_error"
  )
  after <- .mig006_state(e$db)
  expect_identical(after$n_lab, before$n_lab)
  expect_length(after$marker, 0L)
})

test_that("verify catches a NON-NULL method, which would exempt the row from A79 forever", {
  # This is the mutation that matters most. A method code makes `.rc_lab_kind()`
  # return `acirl_own_lab` - the row still RESOLVES, so a gate that only checked
  # resolution would pass it, and every transcription would become permanently
  # un-supersedable. Caught only because the gate checks the KIND as well.
  mig <- .mig006_load()
  e <- .mig006_env()
  before <- .mig006_state(e$db)

  mig$.mig006_rows <- function(map, uuids) {
    data.frame(uuid = uuids, uuid_analyte = map$uuid_analyte, name = map$label,
               method = "field", organisation = "ACIRL", rl_low = NA_real_,
               rl_high = NA_real_, units = NA_character_,
               conversion_constant = NA_real_, stringsAsFactors = FALSE)
  }

  expect_error(
    mig$mig006_run(db = e$db, snapshot_dir = e$snapshot_dir, mapping = .mig006_map()),
    class = "sampletidy_error"
  )
  after <- .mig006_state(e$db)
  expect_identical(after$n_lab, before$n_lab)
  expect_length(after$marker, 0L)
})

test_that("verify catches a row linked to the WRONG analyte", {
  mig <- .mig006_load()
  e <- .mig006_env()
  before <- .mig006_state(e$db)

  mig$.mig006_rows <- function(map, uuids) {
    data.frame(uuid = uuids, uuid_analyte = rep("a-9002", nrow(map)),
               name = map$label, method = NA_character_, organisation = "ACIRL",
               rl_low = NA_real_, rl_high = NA_real_, units = NA_character_,
               conversion_constant = NA_real_, stringsAsFactors = FALSE)
  }

  expect_error(
    mig$mig006_run(db = e$db, snapshot_dir = e$snapshot_dir, mapping = .mig006_map()),
    class = "sampletidy_error"
  )
  after <- .mig006_state(e$db)
  expect_identical(after$n_lab, before$n_lab)
  expect_length(after$marker, 0L)
})

test_that("verify catches an append that writes MORE rows than the mapping", {
  # MUTATION-DRIVEN: the `lab_method` growth count was unreached by every other
  # test, because a WRONG row is caught by the resolver oracle and a MISSING row
  # is too. The one thing only the count catches is an EXTRA row - a duplicate
  # append leaves every label resolving correctly while quietly doubling the
  # registry.
  mig <- .mig006_load()
  e <- .mig006_env()
  before <- .mig006_state(e$db)

  append_ok <- mig$.mig006_append_methods
  mig$.mig006_append_methods <- function(con, map, uuid_fn = uuid::UUIDgenerate) {
    append_ok(con, map, uuid_fn = uuid_fn)          # once...
    append_ok(con, map, uuid_fn = uuid_fn)          # ...and again
  }

  expect_error(
    mig$mig006_run(db = e$db, snapshot_dir = e$snapshot_dir, mapping = .mig006_map()),
    class = "sampletidy_error"
  )
  after <- .mig006_state(e$db)
  expect_identical(after$n_lab, before$n_lab)
  expect_length(after$marker, 0L)
})

test_that("the preconditions are re-checked INSIDE the transaction, not only before it", {
  # MUTATION-DRIVEN, and the only test that can see the TOCTOU guard: the
  # preconditions run once on a read-only connection (so a doomed run leaves no
  # stray backup) and again inside the write transaction (because the database
  # can move in between). Removing the second check survived every other test.
  #
  # The collision is planted with the SAME analyte deliberately. A different
  # analyte would leave the resolver oracle to catch it, and the test would pass
  # for the wrong reason; with the analyte agreeing, resolution still succeeds
  # and ONLY the re-check can refuse it.
  mig <- .mig006_load()
  e <- .mig006_env()
  before <- .mig006_state(e$db)

  backup_ok <- mig$mig006_backup
  mig$mig006_backup <- function(db, snapshot_dir, .now = NULL) {
    path <- backup_ok(db = db, snapshot_dir = snapshot_dir, .now = .now)
    con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = FALSE)
    on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
    DBI::dbExecute(con, "INSERT INTO lab_method
      (uuid, uuid_analyte, name, method, organisation) VALUES
      ('lm-race', 'a-9001', 'Calcium', NULL, 'ACIRL')")
    path
  }

  expect_error(
    mig$mig006_run(db = e$db, snapshot_dir = e$snapshot_dir, mapping = .mig006_map()),
    class = "sampletidy_error"
  )
  after <- .mig006_state(e$db)
  # The racing row is still there - it is not this migration's to remove - but
  # nothing of the migration's own was committed.
  expect_identical(after$n_lab, before$n_lab + 1L)
  expect_length(after$marker, 0L)
})

test_that("the SAFETY half catches a stray write to `analysis`", {
  mig <- .mig006_load()
  e <- .mig006_env()
  before <- .mig006_state(e$db)

  append_ok <- mig$.mig006_append_methods
  mig$.mig006_append_methods <- function(con, map, uuid_fn = uuid::UUIDgenerate) {
    out <- append_ok(con, map, uuid_fn = uuid_fn)
    DBI::dbExecute(con, "DELETE FROM analysis WHERE uuid IN (SELECT uuid FROM analysis LIMIT 1)")
    out
  }

  expect_error(
    mig$mig006_run(db = e$db, snapshot_dir = e$snapshot_dir, mapping = .mig006_map()),
    class = "sampletidy_error"
  )
  after <- .mig006_state(e$db)
  expect_identical(after$n_analysis, before$n_analysis)
  expect_identical(after$n_lab, before$n_lab)
  expect_length(after$marker, 0L)
})

test_that("a mapping supplied as a CSV path behaves identically to a data frame", {
  mig <- .mig006_load()
  e <- .mig006_env()
  dir <- withr::local_tempdir()
  path <- file.path(dir, "map.csv")
  utils::write.csv(.mig006_map(), path, row.names = FALSE)

  res <- mig$mig006_run(db = e$db, snapshot_dir = e$snapshot_dir, mapping = path)

  expect_identical(res$status, "migrated")
  expect_identical(.mig006_state(e$db)$marker, 1006L)
})

test_that("a mapping path that does not exist is refused", {
  mig <- .mig006_load()
  e <- .mig006_env()
  .expect_006_refused(mig, e, file.path(tempdir(), "no-such-mapping.csv"))
})
