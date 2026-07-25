# PLAN-15 E - dev/migrations/003-alias-date-bounds.R (R-15.10, R-15.19).
#
# TARGET FILE CONTRACT (the target file is TDD-red/unwritten; this is the
# interface Phase 6 must implement so these tests pass - not part of the
# package NAMESPACE, so tests `sys.source()` it directly via `.mig003_load()`
# below, mirroring test-migration-001.R:42):
#
#   mig003_run(db, snapshot_dir, dry_run = FALSE, .now = NULL,
#              bounds = .mig003_e5_bounds())
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
#          3. Applies `bounds` via the internal `.mig003_apply_bounds()`
#             below. `bounds` DEFAULTS to `.mig003_e5_bounds()` (the real
#             curated E.5 table as a function), so the production default is
#             unchanged and no production caller passes it - but it is
#             INJECTABLE at the `mig003_run()` level too (PLAN-15 B-15.E5,
#             AMENDED 2026-07-24, Phase-5 audit round 2 B2/PCR-1), because
#             the real E.5 literals (`b.s01`, `k.e02`, ...) do not exist on
#             any `T.*`/`TH.*` test fixture and every one would match zero
#             rows, which E.5 pins as an ABORT - making `mig003_run()`
#             impossible to call on a fixture at all without this. Every
#             test below passes `bounds = .mig003_fixture_bounds()`, so
#             R-15.19's per-row assertions cover the REAL entry point, not
#             only the internal `.mig003_apply_bounds()`.
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

  # bounds = .mig003_fixture_bounds() (Phase-5 audit round 2 B2): the real
  # E.5 literals default would match zero rows on this fixture and ABORT.
  snap_dir <- withr::local_tempdir()
  mig$mig003_run(db = path, snapshot_dir = snap_dir, bounds = .mig003_fixture_bounds())

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
  # B3: baseline change_log count captured BEFORE mig003_run() does
  # anything - Phase-5 audit round 2 B2(b): bounds application now happens
  # INSIDE the real entry point (see below), not via a separate direct
  # `.mig003_apply_bounds()` call afterwards, so the "before" snapshot for
  # the provenance-count assertion must precede the entry-point call itself.
  # Phase-5 audit round 3 C1: restricted to the nine itemised
  # `ma-src%02d-cur` uuids (see log_after, below) so the count discriminates
  # bounds-application provenance from R1's unrelated table-wide self flip.
  # Phase-5 audit round 4 A2: also restricted to field IN
  # ('date_start', 'date_end') - `.mig003_apply_bounds()`'s pinned contract
  # sets `auto_assign = TRUE` on every one of these nine rows too, and
  # db_update() logs one change_log row per changed field, so without this
  # filter the auto_assign flip alone clears the threshold with ZERO bounds
  # provenance. This filter makes the count one of bounds-field provenance
  # only.
  cur_uuids_for_log <- sprintf("ma-src%02d-cur", 1:9)
  log_before <- DBI::dbGetQuery(con0, sprintf(
    "SELECT count(*) AS n FROM change_log WHERE tbl = 'feature_alias' AND uuid_row IN (%s) AND field IN ('date_start', 'date_end')",
    paste(sprintf("'%s'", cur_uuids_for_log), collapse = ", ")))$n
  DBI::dbDisconnect(con0, shutdown = TRUE)

  # ---- Full production entry point: ALTER TABLE + R1's universal flip +
  # the itemised bounds application - ALL via the REAL mig003_run() entry
  # point, injecting THIS seed's own fixture-scoped bounds table (mirrors
  # E.5's shape/counts exactly). Phase-5 audit round 2 B2(b): this covers
  # mig003_run() itself, not only the internal .mig003_apply_bounds() - a
  # migration that does the ALTER and the R1 flip and applies ZERO curated
  # bounds can no longer pass this test. ----
  snap_dir <- withr::local_tempdir()
  mig$mig003_run(db = path, snapshot_dir = snap_dir, bounds = .mig003_fixture_bounds())

  con <- migration_003_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  fields <- DBI::dbListFields(con, "feature_alias")
  expect_true(all(c("date_start", "date_end") %in% fields))

  fa_after <- DBI::dbGetQuery(con, "SELECT * FROM feature_alias ORDER BY uuid")

  # Phase-5 audit round 3 C1: counting ALL change_log rows for
  # tbl='feature_alias' does not discriminate - R1's table-wide self flip
  # alone touches 22 `self` arms on this seed, so a 003 that ALTERs and
  # flips but applies ZERO curated bounds still cleared this count. Restrict
  # to rows whose `uuid_row` is one of the nine itemised `ma-src%02d-cur`
  # uuids (log_before, captured above from con0 pre-mig003_run(), is
  # filtered identically), so only bounds-application provenance is counted.
  # Phase-5 audit round 4 A2: also restricted to field IN
  # ('date_start', 'date_end'), matching log_before - the auto_assign flip
  # that a correct applier also performs on every one of these nine rows can
  # no longer satisfy this count. The oracle is now a count of *field*
  # changes, not of rows: 3 non-NULL date_start + 7 non-NULL date_end = 10.
  log_after <- DBI::dbGetQuery(con, sprintf(
    "SELECT count(*) AS n FROM change_log WHERE tbl = 'feature_alias' AND uuid_row IN (%s) AND field IN ('date_start', 'date_end')",
    paste(sprintf("'%s'", cur_uuids_for_log), collapse = ", ")))$n
  bounds_for_log <- .mig003_fixture_bounds()
  n_bound_fields <- sum(!is.na(bounds_for_log$date_start)) +
                    sum(!is.na(bounds_for_log$date_end))   # 3 + 7 = 10
  expect_gte(log_after - log_before, n_bound_fields)

  # Row counts unchanged: only ALTER/UPDATE, never INSERT/DELETE.
  expect_equal(nrow(fa_after), n_rows_before)

  # B4 (S-15.9): the SET of feature_alias.uuid is IDENTICAL before and after
  # mig003_run()'s ALTER TABLE step - a rebuild (the forbidden `DROP TABLE
  # feature_alias` + TEMP-copy path, refused live because `feature_alias` is
  # the FK parent of `sample` - seeded onto this fixture specifically so that
  # refusal is real here too) regenerates or reorders uuids; plain
  # `ALTER TABLE ... ADD COLUMN` never does.
  expect_equal(length(fa_after$uuid), length(fa_before$uuid))
  expect_true(setequal(fa_after$uuid, fa_before$uuid))

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
  # COMPLEMENT (never a hard-coded total; PLAN-15 E.6 box (ii)). The
  # complement is of "rows that got at least one bound" (7 non-NULL
  # date_end + the 2 rule-2 rows that get neither = 9 itemised rows, but
  # rows 6/7 (t.src06/t.src07, rule-2 "stays open") are NA on BOTH bounds by
  # construction - so a CORRECT migration leaves nrow - 7 rows null-on-both,
  # never nrow - 9 (Phase-5 audit B1: a hard-coded `- 9L` here can never
  # pass). Derived from the fixture itself, not a second hard-coded literal.
  bounds_fx <- .mig003_fixture_bounds()
  n_bounded <- sum(!is.na(bounds_fx$date_start) | !is.na(bounds_fx$date_end))
  n_null_both <- sum(is.na(fa_after$date_start) & is.na(fa_after$date_end))
  expect_equal(n_null_both, nrow(fa_after) - n_bounded)

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

# ---- E.5 / B7: .mig003_apply_bounds()'s row-identity abort ----------------
# PLAN-15 E.5 pins that `.mig003_apply_bounds()` THROWS when its own
# `(alias_key, kind != 'self', target name)` key does not resolve to
# EXACTLY one row - the only thing between a mis-keyed UPDATE and the live
# registry. Phase-5 audit B7: nothing exercised this abort at all.

bounds_row <- function(alias_key, target_name, date_start = NA, date_end = NA) {
  data.frame(
    alias_key = alias_key, target_name = target_name,
    date_start = as.Date(date_start), date_end = as.Date(date_end),
    stringsAsFactors = FALSE
  )
}

#' Snapshot of every bounds-relevant field, keyed by uuid - so "the DB is
#' UNCHANGED" is checked over the FULL state (an abort that already wrote
#' some rows before throwing is the failure mode worth catching), not merely
#' a row count.
.mig003_bounds_snapshot <- function(con) {
  DBI::dbGetQuery(con, "SELECT uuid, date_start, date_end, auto_assign FROM feature_alias ORDER BY uuid")
}

test_that("E.5: .mig003_apply_bounds() aborts (catchable error) and writes NOTHING when a bounds row's target name matches NO feature", {
  mig <- .mig003_load()
  path <- seed_migration_003_db()
  con <- migration_003_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  # .mig003_apply_bounds() operates on a post-ALTER schema (mirrors R-15.19's
  # own call order). bounds = .mig003_fixture_bounds() (Phase-5 audit round 2
  # B2): the real E.5 literals default would match zero rows on this fixture
  # and ABORT before the ALTER/R1 flip could even land.
  snap_dir <- withr::local_tempdir()
  mig$mig003_run(db = path, snapshot_dir = snap_dir, bounds = .mig003_fixture_bounds())

  before <- .mig003_bounds_snapshot(con)

  # 'T.NONEXISTENT99' names no feature at all in this seed - zero matching
  # rows, not exactly one.
  bad_bounds <- bounds_row("t.src01", "T.NONEXISTENT99", date_end = "2024-01-01")
  # C1 (Phase-5 audit round 2): class-checked, not a bare expect_error() -
  # this is the ONLY test of E.5's row-identity abort, and a bare
  # expect_error() is satisfied by ANY incidental error, including a
  # mig003_run() abort a few lines above.
  expect_error(mig$.mig003_apply_bounds(con, bad_bounds), class = "sampletidy_error")

  after <- .mig003_bounds_snapshot(con)
  expect_equal(after, before)
})

test_that("E.5: .mig003_apply_bounds() aborts (catchable error) and writes NOTHING when a bounds row's (alias_key, kind != 'self', target name) key matches TWO rows", {
  mig <- .mig003_load()
  path <- seed_migration_003_db()
  con <- migration_003_con(path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  # bounds = .mig003_fixture_bounds() (Phase-5 audit round 2 B2): see the
  # sibling abort test above.
  snap_dir <- withr::local_tempdir()
  mig$mig003_run(db = path, snapshot_dir = snap_dir, bounds = .mig003_fixture_bounds())

  # Manufacture a genuine 2-row collision: a SECOND non-self arm sharing
  # 't.src02' AND pointing at the same target feature (mf-tgt02 / T.TGT02)
  # as the seed's own curated 'ma-src02-cur' row - so the (alias_key,
  # kind != 'self', target name) key now resolves to TWO rows, not one.
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign, first_seen, last_seen) VALUES
    ('ma-src02-collision', 'mf-tgt02', 'T.SRC02', 't.src02', 'descriptive', 1, FALSE,
     TIMESTAMP '2020-06-01 00:00:00', TIMESTAMP '2020-06-01 00:00:00')")

  before <- .mig003_bounds_snapshot(con)

  bad_bounds <- bounds_row("t.src02", "T.TGT02", date_end = "2021-06-15")
  # C1 (Phase-5 audit round 2): class-checked, not a bare expect_error().
  expect_error(mig$.mig003_apply_bounds(con, bad_bounds), class = "sampletidy_error")

  after <- .mig003_bounds_snapshot(con)
  expect_equal(after, before)
})

# ======================================================================
# E.5 — the curated bounds table AS DATA (no database)
# ======================================================================

test_that("E.5: .mig003_e5_bounds() is exactly the nine curated rows, with rule-1 point bounds and no contradictory bound", {
  mig <- .mig003_load()
  b <- mig$.mig003_e5_bounds()

  # WHY THIS TEST EXISTS. PLAN-15 E.5 pins it explicitly: splitting 003 into
  # an entry point plus an injectable applier made the MECHANISM testable
  # (every other block here drives `.mig003_fixture_bounds()`), but left the
  # nine real curated rows exercised by nothing. The plan's own words: without
  # this, the split "converts an untestable migration into a tested mechanism
  # carrying untested data, which is a quieter failure than the one it
  # replaces". These literals are hand-transcribed and are written to the LIVE
  # alias registry, where a slipped date silently mis-annotates which arms get
  # a self-precedence note.
  #
  # The rows are DATA, not derivable - E.5 says an implementer "must use
  # exactly these literals and must not recompute them", so this test
  # transcribes them independently from the plan's table rather than reading
  # them back from the constant it is checking.

  expect_identical(nrow(b), 9L)
  expect_setequal(names(b), c("alias_key", "target_name", "date_start", "date_end"))

  # A mixed-case key silently matches zero alias rows, and E.5's own abort
  # would then fire on a correct migration. Cheap to assert, invisible if wrong.
  expect_identical(b$alias_key, tolower(b$alias_key))

  # Bounds must be DATE. `.rc_as_date_bound()` and `.rq_row()` both REJECT a
  # POSIXct rather than coercing, because as.Date() on a POSIXct is itself
  # timezone-dependent; a POSIXct leaking in here would be truncated in UTC.
  expect_s3_class(b$date_start, "Date")
  expect_s3_class(b$date_end, "Date")

  expected <- data.frame(
    alias_key   = c("b.s01", "b.ts02", "b.ts41", "b.s22", "b.s04",
                    "b.s22", "k.e02", "b.ts18", "b.ts40"),
    target_name = c("B.TS41", "B.TS27", "B.TMW15", "B.S06", "B.S01",
                    "B.TS18", "K.S06", "B.S30", "B.TS39"),
    date_start  = as.Date(c("2026-01-21", "2021-11-12", "2024-04-08", NA, NA,
                            NA, NA, NA, NA)),
    date_end    = as.Date(c("2026-01-21", "2021-11-12", "2024-04-08", NA,
                            "2026-05-04", "2021-11-12", NA, "2021-11-12",
                            "2024-04-08")),
    stringsAsFactors = FALSE
  )
  expect_equal(b[order(b$alias_key, b$target_name), ],
               expected[order(expected$alias_key, expected$target_name), ],
               ignore_attr = "row.names")

  # R5: a rule-1 arm gets a POINT bound, never an open-ended-back one. E.2's
  # liveness rule makes a `date_end`-only arm live back to the beginning of
  # time, so `b.s01`->B.TS41's SINGLE sample would shadow 24 years of B.S01 -
  # measured in the plan at 178 of 186 samples vs 1 under a point bound. The
  # constant carries no `rule` column, so the checkable form is: any row that
  # sets `date_start` at all must close at the same day.
  bounded <- !is.na(b$date_start)
  expect_identical(b$date_start[bounded], b$date_end[bounded])

  # A contradictory bound (start > end) can never be live - E.2 ANDs both
  # halves - so such a row would silently apply nothing.
  both <- !is.na(b$date_start) & !is.na(b$date_end)
  expect_true(all(b$date_start[both] <= b$date_end[both]))

  # E.6's restated count: SEVEN non-NULL `date_end` over the nine rows, not
  # eight. `b.s22`->B.S06 (rule 2) and `k.e02`->K.S06 both stay open.
  expect_identical(sum(!is.na(b$date_end)), 7L)

  # The corrected proxy, and the one that is NOT a proxy any more.
  #
  # READ THE TABLE, NOT THE PROSE. E.5's guidance box still says "the two
  # corrected proxy dates are 2026-05-25 (k.e02->K.S06) and 2026-05-04
  # (b.s04->B.S01)". That box is STALE: the authoritative table below it
  # strikes 2026-05-25 through twice, because R5 RECLASSIFIED k.e02->K.S06
  # from rule 1 to rule 2. K.E02 and K.S06 coexist for their whole lifespans
  # and both end 2026-05-25, so ANY bound on the K.S06 arm also falls inside
  # K.E02's range and the key would go to review at every date and never
  # resolve. It stays open. Asserting 2026-05-25 here would be transcribing
  # the stale prose and would make a CORRECT migration fail.
  expect_identical(b$date_end[b$alias_key == "b.s04" & b$target_name == "B.S01"],
                   as.Date("2026-05-04"))
  ke02 <- b$alias_key == "k.e02" & b$target_name == "K.S06"
  expect_true(is.na(b$date_start[ke02]) && is.na(b$date_end[ke02]))
})
