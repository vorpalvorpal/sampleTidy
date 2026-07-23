# PLAN-15 E - dev/migrations/003-alias-date-bounds.R (R-15.10, R-15.19).
#
# TARGET FILE CONTRACT (the target file is TDD-red/unwritten; this is the
# interface Phase 6 must implement so these tests pass - not part of the
# package NAMESPACE, so tests `sys.source()` it directly via `.mig003_load()`
# below, mirroring test-migration-001.R:42):
#
#   mig003_run(db, snapshot_dir, dry_run = FALSE, .now = NULL)
#     -> invisible(list(status = "migrated" | "already_migrated" | "dry_run",
#        ...)). Against a POST-001/PRE-003 `feature_alias` (no
#        `date_start`/`date_end` columns - see helper-migration-003-db.R):
#          1. `ALTER TABLE feature_alias ADD COLUMN date_start DATE`,
#             `ADD COLUMN date_end DATE` (S-15.9: plain ADD COLUMN only,
#             never a table rebuild - `DROP TABLE feature_alias` is refused,
#             FK parent of `sample`).
#          2. R1's universal self flip, TABLE-WIDE and unconditional:
#             `auto_assign = TRUE` on every `kind = 'self'` row, regardless
#             of whether that feature is one of E.5's curated keys.
#          3. Applies the curated E.5 bounds via the internal
#             `.mig003_apply_bounds()` below, called with the REAL E.5
#             literals (`b.s01`, `k.e02`, ... - meaningless against any test
#             fixture, since those strings do not exist in one).
#        "already_migrated" if `date_start`/`date_end` already exist on
#        `feature_alias` (idempotent no-op) - not exercised by this file.
#
#   .mig003_apply_bounds(con, bounds)
#     -> integer(1), rows updated. `bounds` is a
#        `data.frame(alias_key, target_name, date_start, date_end)` (Date or
#        NA). For each row: match the ONE `feature_alias` row where
#        `alias_key` equals `bounds$alias_key[i]`, `kind != 'self'`, and its
#        `uuid_feature` resolves to a `feature` named `bounds$target_name[i]`
#        (E.5's "row identity for the UPDATEs": the pair, kind-qualified so
#        the transcription_error duplicate never collides with it) - THROW
#        if that is not EXACTLY one row (catchable by `expect_error()`).
#        Sets `date_start`, `date_end` AND `auto_assign = TRUE` on the
#        matched row (E.5's restated UPDATE set: the non-self arm's flip
#        travels with its bound, not with R1's self-only rule). Exposed as a
#        SEPARATE, injectable-`bounds` internal function (rather than folded
#        unconditionally into `mig003_run()`) specifically so this test file
#        can exercise the real matching/write mechanism against a
#        FIXTURE-keyed bounds table - see the plan-change note in this
#        unit's report for why: E.5's literal bounds cannot touch any
#        fixture, named or otherwise, by construction.
#
# Every test sources the target file inside its own `test_that()` (never at
# file top level, matching test-migration-001.R), so a missing/broken target
# file surfaces as an ordinary per-test FAILURE - not a whole-file collection
# error that would silently zero out every other test's coverage.

.mig003_load <- function() {
  env <- new.env(parent = globalenv())
  path <- testthat::test_path("..", "..", "dev", "migrations", "003-alias-date-bounds.R")
  if (!file.exists(path)) {
    # A clean, single, named ERROR (not a skip, and not `testthat::fail()` -
    # that records a failure but does NOT halt execution, so the very next
    # line's `sys.source()` would throw a SECOND, redundant condition for
    # the same missing-file cause). The migration is not yet written, so
    # this is the correct TDD-red state, and it must show up as exactly one
    # red result per test, not silently vanish as a skip.
    stop(sprintf("migration file not found (expected TDD-red): %s", path))
  }
  sys.source(path, envir = env)
  env
}

# The 9 curated keys of the helper-migration-003-db.R seed, in the SAME
# rule-shape as E.5 (helper file header has the full mapping). Mirrors the
# structure of the real production bounds table (which uses the live
# `b.s01`/`k.e02`/... literals instead) so `.mig003_apply_bounds()` can be
# exercised for real against this seed.
.mig003_fixture_bounds <- function() {
  data.frame(
    alias_key = c(
      "t.src01", "t.src02", "t.src03",   # EXACT rule-1 (point bound)
      "t.src04", "t.src05",              # PROXY rule-1 (date_end only)
      "t.src06", "t.src07",              # rule-2 (stays NULL/NULL)
      "t.src08", "t.src09"                # rule-3 (non-overlap / overlap)
    ),
    target_name = c(
      "T.TGT01", "T.TGT02", "TH.TGT03",
      "T.TGT04", "T.TGT05",
      "T.TGT06", "TH.TGT07",
      "T.TGT08", "T.TGT09"
    ),
    date_start = as.Date(c(
      "2024-03-10", "2021-06-15", "2023-09-01",
      NA, NA,
      NA, NA,
      NA, NA
    )),
    date_end = as.Date(c(
      "2024-03-10", "2021-06-15", "2023-09-01",
      "2024-11-20", "2021-06-15",
      NA, NA,
      "2021-06-15", "2023-09-01"
    )),
    stringsAsFactors = FALSE
  )
}

# ---- R-15.10 ----------------------------------------------------------

test_that("R-15.10: universal self-alias flip resolves own name after 003, even for a feature outside E.5's curated keys", {
  mig <- .mig003_load()
  path <- seed_migration_003_db()

  # Positive control: T.PLAIN01 is deliberately NOT one of the seed's
  # curated keys (helper header), and its self arm starts auto_assign
  # FALSE - so pre-migration it does not resolve at all. Without this half
  # the post-migration assertion below would be unfalsifiable (E.6 box
  # (iii): a self-alias-abort-style criterion that can't fail on any
  # existing seed is exactly the defect class this pairs against).
  con <- migration_003_con(path)
  registry_before <- .rc_load_registry(con)
  DBI::dbDisconnect(con, shutdown = TRUE)
  cand_before <- .rc_feature_candidates("T.PLAIN01", as.Date("2025-06-01"), registry_before)
  expect_equal(nrow(cand_before), 0L)

  snap_dir <- withr::local_tempdir()
  mig$mig003_run(db = path, snapshot_dir = snap_dir)

  con2 <- migration_003_con(path)
  withr::defer(DBI::dbDisconnect(con2, shutdown = TRUE))
  registry_after <- .rc_load_registry(con2)

  # (a) T.PLAIN01 now resolves by its own canonical name - a real seam test
  # through the actual resolver, not a raw flag check.
  cand_after <- .rc_feature_candidates("T.PLAIN01", as.Date("2025-06-01"), registry_after)
  expect_equal(nrow(cand_after), 1L)
  expect_equal(cand_after$uuid_feature, "mf-plain01")

  # (b) the table-wide post-condition, asserted SEPARATELY: zero
  # `feature_alias` rows with kind = 'self' and auto_assign not TRUE. The
  # (a) assertion alone is satisfied by a migration that flips only E.5's 8
  # keys' arms (T.PLAIN01 would then still fail); this assertion alone is
  # satisfied by a seed that never had a FALSE self arm to begin with. Only
  # together do they catch a migration that flips only the curated keys.
  fa_after <- registry_after$feature_alias
  n_bad_self <- sum(fa_after$kind == "self" & !.rc_is_true_vec(fa_after$auto_assign))
  expect_equal(n_bad_self, 0L)
})

# ---- R-15.19 ------------------------------------------------------------

test_that("R-15.19: migration 003 adds date bounds, writes exactly the itemised rows, flips auto_assign, and leaves everything else unchanged", {
  mig <- .mig003_load()
  path <- seed_migration_003_db()

  src_keys <- sprintf("t.src%02d", 1:9)
  ctrl_uuids <- c("ma-ctrl01-self", "ma-ctrl02-self", "ma-ctrl03-self")
  fingerprint_cols <- c("uuid", "alias_key", "uuid_feature", "kind", "auto_assign", "n_seen")

  con0 <- migration_003_con(path)
  fa_before <- DBI::dbGetQuery(con0, "SELECT * FROM feature_alias ORDER BY uuid")
  n_rows_before <- nrow(fa_before)
  # Positive control: the fixture genuinely starts un-flipped for the
  # curated-key arms (self + curated + duplicate rows share alias_key), so
  # the post-migration "all TRUE" assertion below is falsifiable.
  expect_true(any(!fa_before$auto_assign[fa_before$alias_key %in% src_keys]))
  ctrl_before <- fa_before[fa_before$uuid %in% ctrl_uuids, fingerprint_cols]
  DBI::dbDisconnect(con0, shutdown = TRUE)

  # ---- Full production entry point: ALTER TABLE + R1's universal flip
  # (harmless no-op against this fixture's real-E.5-literal bounds step,
  # since none of `b.s01`/`k.e02`/... exist here - see this unit's report
  # for why the itemised-bounds mechanism is tested via the injectable
  # `.mig003_apply_bounds()` below instead). ----
  snap_dir <- withr::local_tempdir()
  mig$mig003_run(db = path, snapshot_dir = snap_dir)

  con <- migration_003_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  fields <- DBI::dbListFields(con, "feature_alias")
  expect_true(all(c("date_start", "date_end") %in% fields))

  # ---- The itemised-bounds mechanism itself, exercised with THIS seed's
  # own fixture-scoped bounds table (mirrors E.5's shape/counts exactly). ----
  mig$.mig003_apply_bounds(con, .mig003_fixture_bounds())

  fa_after <- DBI::dbGetQuery(con, "SELECT * FROM feature_alias ORDER BY uuid")

  # Row counts unchanged: only ALTER/UPDATE, never INSERT/DELETE.
  expect_equal(nrow(fa_after), n_rows_before)

  # Exact per-row values for each of the 9 itemised rows - keyed by their
  # own known uuid (independent of whatever WHERE-clause the real
  # implementation used to find them).
  expected <- .mig003_fixture_bounds()
  cur_uuids <- sprintf("ma-src%02d-cur", 1:9)
  got <- fa_after[match(cur_uuids, fa_after$uuid), c("date_start", "date_end", "auto_assign")]
  expect_equal(as.character(got$date_start), as.character(expected$date_start))
  expect_equal(as.character(got$date_end), as.character(expected$date_end))
  expect_true(all(got$auto_assign))

  # SEVEN non-NULL date_end / THREE non-NULL date_start over the 9 itemised
  # rows - asserted as an aggregate, independent of the per-row check above.
  expect_equal(sum(!is.na(got$date_end)), 7L)
  expect_equal(sum(!is.na(got$date_start)), 3L)

  # Every OTHER row in the seed stays NULL/NULL - asserted as a count of the
  # COMPLEMENT (never a hard-coded total; PLAN-15 E.6 box (ii)).
  n_null_both <- sum(is.na(fa_after$date_start) & is.na(fa_after$date_end))
  expect_equal(n_null_both, nrow(fa_after) - 9L)

  # auto_assign TRUE on every arm of the 9 curated keys afterwards (self +
  # curated + the 2 already-true duplicates, all sharing one of the 9
  # alias_key strings) - the END STATE, not a count of rows the migration
  # itself touched.
  arm_rows <- fa_after[fa_after$alias_key %in% src_keys, ]
  expect_true(all(arm_rows$auto_assign))

  # R1's table-wide postcondition also holds over this seed's OTHER self
  # arms (T.TGT*, T.CTRL*, and T.PLAIN01 - the last flipped purely by R1,
  # not by any itemised row).
  n_bad_self <- sum(fa_after$kind == "self" & !.rc_is_true_vec(fa_after$auto_assign))
  expect_equal(n_bad_self, 0L)

  # "Otherwise unchanged": the 3 control rows are untouched by anything the
  # migration or the bounds application did, over the field set the plan
  # pins (uuid, alias_key, uuid_feature, kind, auto_assign, n_seen).
  ctrl_after <- fa_after[fa_after$uuid %in% ctrl_uuids, fingerprint_cols]
  expect_equal(
    digest::digest(ctrl_after[order(ctrl_after$uuid), ], algo = "sha1"),
    digest::digest(ctrl_before[order(ctrl_before$uuid), ], algo = "sha1")
  )
})
