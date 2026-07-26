# Plan 11 - R/feature-alias.R: confirm_feature_aliases() (R-11.10) and
# confirm_analyte_methods() (R-11.11) - the resolve API (B-11-the-api-is-the).
#
# NEW FILE, NEW target module. Both functions are unwritten; every test below
# is expected to fail on a missing production symbol ("could not find
# function") - that is the correct TDD-red state, not a defect. Do not stub
# R/feature-alias.R to make these pass.
#
# Both functions are vectorised over uuid_alias/uuid_feature (resp.
# uuid_lab/uuid_analyte) for bulk confirmation, run inside one
# with_db_write() transaction per item, all via the plan-09 mutation layer
# (db_update()/db_append(), reused - do not re-derive), and record
# `confirmed_by` provenance via `change_log` (A32/A40/A55). `confirmed_by` is
# mandatory and must never default (the authority rule, B-11-the-api-is-the).
#
# Fixture/idiom convention (matches test-commit.R/test-mutate.R): seed a
# throwaway DB, point `st_config("live_db")` at it via
# `withr::local_options(.local_envir = parent.frame())` (never the bare/
# default-arg form - the withr wrong-frame trap), and call the functions
# under test with no explicit `db` arg so they resolve it themselves exactly
# as a human caller would (A16-style, consistent with add_feature() etc. in
# test-mutate.R).

# ---- local helpers ----------------------------------------------------

#' Seed a DB, point st_config("live_db") at it, return {path, con}.
#' Cleanup (tempdir, option) is bound to the CALLING TEST's frame, not this
#' helper's own frame - the withr wrong-frame trap (language-footguns.md).
fa_setup <- function() {
  env <- parent.frame()
  path <- seed_db(dir = withr::local_tempdir(.local_envir = env))
  withr::local_options(list("sampletidy.live_db" = path), .local_envir = env)
  con <- seed_con(path)
  list(path = path, con = con)
}

count_rows <- function(con, table) DBI::dbGetQuery(con, sprintf('SELECT count(*) AS n FROM "%s"', table))$n

all_counts <- function(con) {
  list(
    feature = count_rows(con, "feature"), feature_alias = count_rows(con, "feature_alias"),
    analyte = count_rows(con, "analyte"), lab_method = count_rows(con, "lab_method"),
    sample = count_rows(con, "sample"), analysis = count_rows(con, "analysis"),
    review_queue = count_rows(con, "review_queue"), change_log = count_rows(con, "change_log")
  )
}

#' The v_measurement-equivalent join for a resolved FEATURE side (A24: the
#' test schema has no views, so this is the real join the plan pins - not a
#' hand-rolled stand-in for the seam).
feature_joined_analyses <- function(con) {
  DBI::dbGetQuery(con, '
    SELECT a.uuid AS analysis_uuid, a.value
    FROM analysis a
    JOIN "sample" s ON s.uuid = a.uuid_sample
    JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
    JOIN feature f ON f.uuid = fa.uuid_feature
  ')
}

#' The v_measurement-equivalent join for a resolved ANALYTE side.
analyte_joined_analyses <- function(con) {
  DBI::dbGetQuery(con, "
    SELECT a.uuid AS analysis_uuid, a.value
    FROM analysis a
    JOIN lab_method lm ON lm.uuid = a.uuid_lab
    JOIN analyte an ON an.uuid = lm.uuid_analyte
  ")
}

feature_alias_row <- function(con, uuid) {
  DBI::dbGetQuery(con, "SELECT * FROM feature_alias WHERE uuid = ?", params = list(uuid))
}

lab_method_row <- function(con, uuid) {
  DBI::dbGetQuery(con, "SELECT * FROM lab_method WHERE uuid = ?", params = list(uuid))
}

#' Insert the (fa-9001/s-9001/an-w1/an-w2) + (fa-9002/s-9002/an-l1/an-l2)
#' collision fixture: two DANGLING aliases, each with a sample dated
#' 2025-08-01, each sample carrying two analyses. an-w1/an-l1 share
#' (feature, date, analyte, method) once merged under f-0002 and have EQUAL
#' values (7.0) - the already_present-semantics duplicate. an-w2/an-l2 also
#' share that key post-merge but have DIFFERENT values (50 vs 99) - the
#' value_conflict duplicate. s-9001/s-9002 carry deliberately different
#' organisation/person so the discard-and-log pin is checkable.
#'
#' alias_key literals ('tnewcode1' etc) are hand-written in the fixture's own
#' stripped-lowercase style (matching fa-0005's 'tambig2' etc in
#' helper-db.R), NOT computed via `.rc_method_key()` - today's pre-R-11.3 `.rc_method_key()`
#' still keeps punctuation (`.rc_method_key("T.NEWCODE1")` == "t.newcode1", not
#' "tnewcode1"), so calling it here would silently create an alias whose key
#' never matches this file's own literal lookups.
mk_collision_fixture <- function(con) {
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign,
     first_seen, last_seen, confirmed_by) VALUES
    (?, NULL, ?, ?, 'pending', 0, FALSE, TIMESTAMP '2025-08-01 08:00:00',
     TIMESTAMP '2025-08-01 08:00:00', NULL)",
    params = list("fa-9001", "T.NEWCODE1", "tnewcode1"))
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign,
     first_seen, last_seen, confirmed_by) VALUES
    (?, NULL, ?, ?, 'pending', 0, FALSE, TIMESTAMP '2025-08-01 08:00:00',
     TIMESTAMP '2025-08-01 08:00:00', NULL)",
    params = list("fa-9002", "T.NEWCODE2", "tnewcode2"))
  DBI::dbExecute(con, "INSERT INTO \"sample\"
    (uuid, uuid_feature_alias, uuid_project, date, datetime, organisation, person) VALUES
    ('s-9001', 'fa-9001', 'p-0001', TIMESTAMP '2025-08-01 00:00:00', TIMESTAMP '2025-08-01 09:00:00', 'ALS', NULL),
    ('s-9002', 'fa-9002', 'p-0001', TIMESTAMP '2025-08-01 00:00:00', TIMESTAMP '2025-08-01 14:00:00', 'ACIRL', 'J. Smith')")
  DBI::dbExecute(con, "INSERT INTO analysis
    (uuid, uuid_sample, uuid_lab, value, quantified, rl_low) VALUES
    ('an-w1', 's-9001', 'lm-0001', 7.0, TRUE, 0.01),
    ('an-w2', 's-9001', 'lm-0002', 50, TRUE, 0.1),
    ('an-l1', 's-9002', 'lm-0001', 7.0, TRUE, 0.01),
    ('an-l2', 's-9002', 'lm-0002', 99, TRUE, 0.1)")
  invisible(NULL)
}

# ======================================================================
# R-11.10 confirm_feature_aliases()
# ======================================================================

# ---- resurfacing, idempotency, kind/auto_assign rules ------------------

test_that("R-11.10: an unconfirmed dangling sample is invisible to the feature-joined join, resurfaces after confirmation, kind pending->transcription_error, auto_assign flips TRUE (before/after pin)", {
  setup <- fa_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # Before: fa-0010 dangling, its sample/analysis (s-0003/an-0003) invisible.
  before_alias <- feature_alias_row(con, "fa-0010")
  expect_true(is.na(before_alias$confirmed_by[[1]])) # a guess is never pre-written as confirmed
  before_visible <- feature_joined_analyses(con)
  expect_false("an-0003" %in% before_visible$analysis_uuid)

  confirm_feature_aliases("fa-0010", "f-0002", confirmed_by = "alice")

  after_alias <- feature_alias_row(con, "fa-0010")
  expect_identical(after_alias$uuid_feature[[1]], "f-0002")
  expect_identical(after_alias$kind[[1]], "transcription_error") # was 'pending'
  expect_true(after_alias$auto_assign[[1]])
  expect_identical(after_alias$confirmed_by[[1]], "alice")

  after_visible <- feature_joined_analyses(con)
  expect_true("an-0003" %in% after_visible$analysis_uuid)
})

test_that("R-11.10: confirming the same alias to the same feature twice is idempotent (no duplicate alias row, no row-count change on the second call)", {
  setup <- fa_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  confirm_feature_aliases("fa-0010", "f-0002", confirmed_by = "alice")
  before <- all_counts(con)

  expect_no_error(confirm_feature_aliases("fa-0010", "f-0002", confirmed_by = "alice"))

  after <- all_counts(con)
  expect_equal(after, before)
  expect_equal(nrow(feature_alias_row(con, "fa-0010")), 1)
})

test_that("R-11.10 (C15): a non-'pending' kind (descriptive) is left untouched by confirmation; auto_assign still flips TRUE and confirmed_by is still recorded", {
  setup <- fa_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # fa-0009: kind = 'descriptive', already resolved to f-0003, auto_assign FALSE.
  before <- feature_alias_row(con, "fa-0009")
  expect_identical(before$kind[[1]], "descriptive")
  expect_false(before$auto_assign[[1]])

  confirm_feature_aliases("fa-0009", "f-0003", confirmed_by = "alice")

  after <- feature_alias_row(con, "fa-0009")
  expect_identical(after$kind[[1]], "descriptive") # NOT relabelled transcription_error
  expect_true(after$auto_assign[[1]])
  expect_identical(after$confirmed_by[[1]], "alice")
})

test_that("R-11.10 (C15): a non-'pending' kind (historical_code) is likewise left untouched by confirmation", {
  setup <- fa_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  confirm_feature_aliases("fa-0008", "f-0007", confirmed_by = "alice")

  after <- feature_alias_row(con, "fa-0008")
  expect_identical(after$kind[[1]], "historical_code")
})

test_that("R-11.10: confirming to a DIFFERENT feature than an existing confirmed_by row is an error, not a silent second row", {
  setup <- fa_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  confirm_feature_aliases("fa-0010", "f-0002", confirmed_by = "alice")
  before <- feature_alias_row(con, "fa-0010")

  expect_error(
    confirm_feature_aliases("fa-0010", "f-0003", confirmed_by = "bob"),
    class = "sampletidy_error"
  )

  after <- feature_alias_row(con, "fa-0010")
  expect_identical(after$uuid_feature[[1]], before$uuid_feature[[1]]) # still f-0002
  expect_equal(nrow(feature_alias_row(con, "fa-0010")), 1) # no second row
})

test_that("R-11.10: the ambiguity nuance - confirming one alias of a genuinely ambiguous key does not stop future ambiguity", {
  setup <- fa_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # fa-0005/fa-0006 both carry alias_key 't.ambig2' (the fixture's own literal
  # - see helper-db.R; this is `.rc_feature_key("T.AMBIG2")` = the migration's
  # punctuation-preserving `tolower(trimws())`, PLAN-15 A), resolving to DIFFERENT
  # features (f-0004, f-0005) - the plan's ambiguous-key fixture.
  key <- "t.ambig2"
  before_distinct <- DBI::dbGetQuery(con,
    "SELECT COUNT(DISTINCT uuid_feature) AS n FROM feature_alias WHERE alias_key = ? AND uuid_feature IS NOT NULL",
    params = list(key))$n
  expect_equal(before_distinct, 2)

  # "Confirming" fa-0005 here is idempotent (same feature it already
  # resolves to) - it only records provenance, per the plan's "confirmation
  # resolves those samples, not the string."
  confirm_feature_aliases("fa-0005", "f-0004", confirmed_by = "alice")

  after_distinct <- DBI::dbGetQuery(con,
    "SELECT COUNT(DISTINCT uuid_feature) AS n FROM feature_alias WHERE alias_key = ? AND uuid_feature IS NOT NULL",
    params = list(key))$n
  expect_equal(after_distinct, 2) # still ambiguous - fa-0006 untouched
  untouched <- feature_alias_row(con, "fa-0006")
  expect_identical(untouched$uuid_feature[[1]], "f-0005")
  expect_true(is.na(untouched$confirmed_by[[1]]))
})

# ---- collision: override = FALSE aborts, writes NOTHING ----------------

test_that("R-11.10 (D5): a collision with override = FALSE aborts, class sampletidy_error, naming the colliding (feature, date) and sample uuids, and writes NOTHING (throw-after-partial-write pin: every table's row count unchanged)", {
  setup <- fa_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  mk_collision_fixture(con)

  # fa-9001 -> f-0002 resolves cleanly first (no prior sample at f-0002 on
  # 2025-08-01), establishing the pre-existing sample the second call collides
  # against.
  confirm_feature_aliases("fa-9001", "f-0002", confirmed_by = "alice")

  before <- all_counts(con)
  err <- tryCatch(
    confirm_feature_aliases("fa-9002", "f-0002", confirmed_by = "alice", override = FALSE),
    error = function(e) e
  )
  expect_s3_class(err, "sampletidy_error")
  msg <- conditionMessage(err)
  expect_true(grepl("f-0002", msg, fixed = TRUE))
  expect_true(grepl("2025-08-01", msg, fixed = TRUE))
  expect_true(grepl("s-9001", msg, fixed = TRUE) && grepl("s-9002", msg, fixed = TRUE))

  after <- all_counts(con)
  expect_equal(after, before) # nothing written by the aborted call
  still_dangling <- feature_alias_row(con, "fa-9002")
  expect_true(is.na(still_dangling$uuid_feature[[1]]))
})

# ---- collision: override = TRUE merges -----------------------------------

test_that("R-11.10 (D5, cold review C14): override = TRUE merges a collision - winner is the pre-existing sample (not reached via the confirmed alias); loser's differing organisation/person are discarded AND logged as a provenance change_log row; equal-value duplicate analysis is dropped (already_present semantics); different-value duplicate is RE-POINTED onto the winner (never orphaned) and opens value_conflict WITHOUT overwriting the winner's existing value; the emptied loser sample is deleted only after its analyses moved", {
  setup <- fa_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  mk_collision_fixture(con)

  confirm_feature_aliases("fa-9001", "f-0002", confirmed_by = "alice")
  confirm_feature_aliases("fa-9002", "f-0002", confirmed_by = "alice", override = TRUE)

  # winner = s-9001 (pre-existing, not reached via the just-confirmed fa-9002
  # alias); loser = s-9002 is deleted.
  winner <- DBI::dbGetQuery(con, "SELECT * FROM \"sample\" WHERE uuid = 's-9001'")
  loser <- DBI::dbGetQuery(con, "SELECT * FROM \"sample\" WHERE uuid = 's-9002'")
  expect_equal(nrow(winner), 1)
  expect_equal(nrow(loser), 0) # emptied sample deleted

  # discarded organisation/person are logged, not silently dropped.
  prov <- DBI::dbGetQuery(con,
    "SELECT * FROM change_log WHERE action = 'provenance' AND uuid_row = 's-9002'")
  expect_gt(nrow(prov), 0)
  logged_text <- paste(c(prov$old, prov$new, prov$field, prov$reason), collapse = " | ")
  expect_true(grepl("ACIRL", logged_text, fixed = TRUE))
  expect_true(grepl("J. Smith", logged_text, fixed = TRUE))

  # an-l1 (value 7.0, same key as an-w1's 7.0) is a duplicate -> dropped, with
  # its own already_present-style provenance row - never orphaned on a
  # deleted sample because it never exists post-merge.
  an_l1 <- DBI::dbGetQuery(con, "SELECT * FROM analysis WHERE uuid = 'an-l1'")
  expect_equal(nrow(an_l1), 0)
  an_w1 <- DBI::dbGetQuery(con, "SELECT value FROM analysis WHERE uuid = 'an-w1'")
  expect_equal(an_w1$value[[1]], 7.0) # existing value untouched

  # an-l2 (value 99, differs from an-w2's 50) is RE-POINTED onto the winner
  # sample, never orphaned, and an-w2's existing value is untouched.
  an_l2 <- DBI::dbGetQuery(con, "SELECT uuid_sample, value FROM analysis WHERE uuid = 'an-l2'")
  expect_equal(nrow(an_l2), 1)
  expect_identical(an_l2$uuid_sample[[1]], "s-9001") # moved onto the winner
  expect_equal(an_l2$value[[1]], 99) # its own value is untouched too
  an_w2 <- DBI::dbGetQuery(con, "SELECT value FROM analysis WHERE uuid = 'an-w2'")
  expect_equal(an_w2$value[[1]], 50) # winner's existing value NOT overwritten

  conflict <- DBI::dbGetQuery(con, "SELECT * FROM review_queue WHERE kind = 'value_conflict'")
  expect_equal(nrow(conflict), 1)
  # ROBIN'S RULING 2 (Phase-7b round-2 item 5, 2026-07-26): PLAN-11 R-11.10
  # pins that the merge's value_conflict item names BOTH analysis uuids, and
  # the plan wins - via the TYPED `uuid_incoming` column (schema ladder
  # version 7), never the JSON payload; PLAN-16's whole direction is moving
  # uuids OUT of payload INTO typed columns, and a cross-producer key-parity
  # invariant elsewhere (test-review-queue-payload.R, another unit) compares
  # parsed payload key SETS between producers - putting it in `diagnostics`
  # would break that invariant. The original comment's justification for
  # omitting it ("an-l2 has no uuid to name") was itself wrong, not merely
  # stale: an-l2 is RE-POINTED onto the winner sample, never deleted, and
  # this very test queries it by that uuid a few lines above (`an_l2 <-
  # ...WHERE uuid = 'an-l2'`). The payload-absence assertion below is
  # therefore KEPT as-is (payloads legitimately carry no uuids on this
  # producer) and a new positive assertion is added for the typed column.
  expect_identical(conflict$uuid_existing[[1]], "an-w2")
  expect_false(grepl("an-l2", conflict$payload[[1]], fixed = TRUE))
  expect_identical(conflict$uuid_incoming[[1]], "an-l2")

  # both analyses now live on the surviving sample - two, not four (an-l1
  # dropped, an-w1/an-w2/an-l2 remain).
  on_winner <- DBI::dbGetQuery(con, "SELECT uuid FROM analysis WHERE uuid_sample = 's-9001'")
  expect_setequal(on_winner$uuid, c("an-w1", "an-w2", "an-l2"))
})

# ---- Phase-7b item 3 (D5, RULED BY ROBIN): same-alias collision -----------

#' Two samples reached through the SAME dangling alias, same date - the
#' shape `.fa_find_collisions()` cannot see because the OTHER sample's alias
#' (here, the SAME alias) has `uuid_feature IS NULL` until this confirmation
#' resolves it.
mk_self_collision_fixture <- function(con) {
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign,
     first_seen, last_seen, confirmed_by) VALUES
    (?, NULL, ?, ?, 'pending', 0, FALSE, TIMESTAMP '2025-08-05 08:00:00',
     TIMESTAMP '2025-08-05 08:00:00', NULL)",
    params = list("fa-9701", "T.SELFCOLL", "tselfcoll"))
  DBI::dbExecute(con, "INSERT INTO \"sample\"
    (uuid, uuid_feature_alias, uuid_project, date, datetime, organisation, person) VALUES
    ('s-9701', 'fa-9701', 'p-0001', TIMESTAMP '2025-08-05 00:00:00', TIMESTAMP '2025-08-05 09:00:00', 'ALS', NULL),
    ('s-9702', 'fa-9701', 'p-0001', TIMESTAMP '2025-08-05 00:00:00', TIMESTAMP '2025-08-05 14:00:00', 'ACIRL', 'J. Smith')")
  invisible(NULL)
}

test_that("Phase-7b item 3 (D5, RULED BY ROBIN): two samples on the SAME dangling alias landing on one (feature, date) do NOT abort - the confirmation proceeds and a review item is opened, with no winner picked", {
  setup <- fa_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  mk_self_collision_fixture(con)

  before_review <- count_rows(con, "review_queue")

  expect_no_error(
    confirm_feature_aliases("fa-9701", "f-0002", confirmed_by = "alice")
  )

  # the confirmation proceeded - not blocked, no override needed.
  after_alias <- feature_alias_row(con, "fa-9701")
  expect_identical(after_alias$uuid_feature[[1]], "f-0002")

  # both samples still exist, untouched - no winner picked, neither deleted
  # or re-pointed.
  both <- DBI::dbGetQuery(con, "SELECT uuid FROM \"sample\" WHERE uuid IN ('s-9701', 's-9702')")
  expect_equal(nrow(both), 2)

  after_review <- count_rows(con, "review_queue")
  expect_equal(after_review, before_review + 1)

  review <- DBI::dbGetQuery(con, "SELECT * FROM review_queue WHERE kind = 'sample_collision'")
  expect_equal(nrow(review), 1)
  expect_identical(review$uuid_alias[[1]], "fa-9701")
  txt <- paste(review$payload, review$uuid_alias, review$uuid_target, collapse = " ")
  expect_true(grepl("s-9701", txt, fixed = TRUE))
  expect_true(grepl("s-9702", txt, fixed = TRUE))
  expect_true(grepl("2025-08-05", txt, fixed = TRUE))

  # Phase-7b round-2 item 1 (RANK 1): the item this SAME call opened must NOT
  # be closed by that call's own review_queue_close(uuid_target = uuid_alias)
  # at the end of .fa_confirm_one_alias() - the two rows share `uuid_target`
  # (`uuid_alias` is polymorphic), and the close used to have no `kind`
  # filter, so it swept this row too, in the same transaction, before an
  # operator could ever see it. Assert BOTH the raw status and that the
  # public review_queue() reader actually surfaces it as open.
  expect_identical(review$status[[1]], "open")
  still_open <- review_queue(con, status = "open")
  expect_true("fa-9701" %in% still_open$uuid_alias[still_open$kind == "sample_collision"])
})

test_that("Phase-7b round-2 item 2: confirming the SAME alias to the SAME feature a second (and third, override = TRUE) time is idempotent even when that alias carries two same-date samples - a self-collision must never re-surface as a cross-alias collision against itself", {
  setup <- fa_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  mk_self_collision_fixture(con)

  n_sample_collisions <- function() {
    nrow(DBI::dbGetQuery(
      con, "SELECT uuid FROM review_queue WHERE kind = 'sample_collision' AND status = 'open'"
    ))
  }

  confirm_feature_aliases("fa-9701", "f-0002", confirmed_by = "alice")
  # Phase-7b round-3 A3 (CONFIRMED-BY-ORCH, probe2_sample_collision.R: 1 -> 2
  # -> 3 rows across 3 confirms before the fix): R-11.10 pins re-confirmation
  # idempotent, but the FIRST confirm above legitimately opens exactly one
  # `sample_collision` row for this alias's own same-date pair.
  expect_equal(n_sample_collisions(), 1L)

  # Once fa-9701 itself carries uuid_feature = f-0002, `.fa_find_collisions()`
  # used to see s-9701's OWN sibling s-9702 (reached through the SAME alias)
  # as a colliding "existing" sample on the SAME feature/date and abort -
  # R-11.10's pinned "confirming the same alias->feature twice is idempotent"
  # is false for any alias carrying >=2 same-date samples without this fix.
  expect_no_error(
    confirm_feature_aliases("fa-9701", "f-0002", confirmed_by = "alice")
  )
  after_alias <- feature_alias_row(con, "fa-9701")
  expect_identical(after_alias$uuid_feature[[1]], "f-0002")
  both <- DBI::dbGetQuery(con, "SELECT uuid FROM \"sample\" WHERE uuid IN ('s-9701', 's-9702')")
  expect_equal(nrow(both), 2) # neither sample merged/deleted by the idempotent re-confirm
  # A3: the SECOND (idempotent) confirm must NOT open a duplicate row for the
  # identical pair.
  expect_equal(n_sample_collisions(), 1L)

  # override = TRUE on the idempotent re-confirm must not abort or
  # destructively merge the alias's own two samples against each other
  # either - the reciprocal self-collision pair used to make
  # .fa_merge_samples() run twice, the second call hitting an
  # already-deleted sample.
  expect_no_error(
    confirm_feature_aliases("fa-9701", "f-0002", confirmed_by = "alice", override = TRUE)
  )
  both_after_override <- DBI::dbGetQuery(con, "SELECT uuid FROM \"sample\" WHERE uuid IN ('s-9701', 's-9702')")
  expect_equal(nrow(both_after_override), 2)
  # A3: a THIRD confirm (override = TRUE included) still must not open a
  # second row for the same pair.
  expect_equal(n_sample_collisions(), 1L)
})

# ---- authority rule + input contract ------------------------------------

test_that("R-11.10 (A55): confirmed_by is mandatory and must not default", {
  setup <- fa_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  expect_error(confirm_feature_aliases("fa-0010", "f-0002"))
})

test_that("R-11.10: a NULL/NA uuid_feature is rejected (feature must exist), not coerced into a spurious link (nullable-key safety)", {
  setup <- fa_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  expect_error(
    confirm_feature_aliases("fa-0010", NA_character_, confirmed_by = "alice"),
    class = "sampletidy_error"
  )
  still_dangling <- feature_alias_row(con, "fa-0010")
  expect_true(is.na(still_dangling$uuid_feature[[1]]))
})

test_that("R-11.10: a nonexistent uuid_alias errors before writing anything", {
  setup <- fa_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  before <- all_counts(con)
  expect_error(
    confirm_feature_aliases("fa-nonexistent-xyz", "f-0002", confirmed_by = "alice"),
    class = "sampletidy_error"
  )
  expect_equal(all_counts(con), before)
})

# ---- vectorised bulk contract + degenerate shapes -----------------------

test_that("R-11.10: vectorised over uuid_alias/uuid_feature - one call confirms two independent pairs and returns invisible(tibble(uuid_alias, uuid_feature, n_samples, action))", {
  setup <- fa_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # a second, independent dangling alias with its own referencing sample.
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign,
     first_seen, last_seen, confirmed_by) VALUES
    (?, NULL, ?, ?, 'pending', 0, FALSE, TIMESTAMP '2025-08-02 08:00:00',
     TIMESTAMP '2025-08-02 08:00:00', NULL)",
    params = list("fa-9102", "T.NEWCODE-BULK", "tnewcodebulk"))
  DBI::dbExecute(con, "INSERT INTO \"sample\"
    (uuid, uuid_feature_alias, uuid_project, date, datetime, organisation) VALUES
    ('s-9102', 'fa-9102', 'p-0001', TIMESTAMP '2025-08-02 00:00:00', TIMESTAMP '2025-08-02 09:00:00', 'ALS')")
  DBI::dbExecute(con, "INSERT INTO analysis (uuid, uuid_sample, uuid_lab, value, quantified, rl_low) VALUES
    ('an-9102', 's-9102', 'lm-0001', 7.2, TRUE, 0.01)")

  vis <- withVisible(confirm_feature_aliases(
    c("fa-0010", "fa-9102"), c("f-0002", "f-0007"), confirmed_by = "alice"
  ))
  expect_false(vis$visible)
  result <- vis$value
  expect_true(is.data.frame(result))
  expect_setequal(names(result), c("uuid_alias", "uuid_feature", "n_samples", "action"))
  expect_equal(nrow(result), 2)
  expect_setequal(result$uuid_alias, c("fa-0010", "fa-9102"))
  by_alias <- rlang::set_names(result$n_samples, result$uuid_alias)
  expect_equal(unname(by_alias["fa-0010"]), 1) # s-0003
  expect_equal(unname(by_alias["fa-9102"]), 1) # s-9102
  expect_true(all(!is.na(result$action)))
})

test_that("R-11.10: an empty uuid_alias/uuid_feature vector is a no-op that writes nothing and returns a zero-row tibble (degenerate empty shape)", {
  setup <- fa_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  before <- all_counts(con)
  result <- confirm_feature_aliases(character(0), character(0), confirmed_by = "alice")
  expect_equal(nrow(result), 0)
  expect_equal(all_counts(con), before)
})

test_that("R-11.10: mismatched uuid_alias/uuid_feature vector lengths error (malformed bulk input, not silently recycled)", {
  setup <- fa_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  expect_error(
    confirm_feature_aliases(c("fa-0010", "fa-0009"), "f-0002", confirmed_by = "alice"),
    class = "sampletidy_error"
  )
})

# ======================================================================
# R-11.11 confirm_analyte_methods()
# ======================================================================

test_that("R-11.11: a dangling analyte is invisible to the analyte-joined join, resurfaces after confirmation, and its value is converted from lab_method.units (pinned mu S/cm -> mS/cm, 965 -> 0.965, A44 EC conversion) - is idempotent on a second call", {
  setup <- fa_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  before_visible <- analyte_joined_analyses(con)
  expect_false("an-0002" %in% before_visible$analysis_uuid)
  before_lm <- lab_method_row(con, "lm-0008")
  expect_true(is.na(before_lm$uuid_analyte[[1]]))

  confirm_analyte_methods("lm-0008", "a-0003", confirmed_by = "alice")

  after_lm <- lab_method_row(con, "lm-0008")
  expect_identical(after_lm$uuid_analyte[[1]], "a-0003")
  after_visible <- analyte_joined_analyses(con)
  hit <- after_visible[after_visible$analysis_uuid == "an-0002", ]
  expect_equal(nrow(hit), 1)
  expect_equal(hit$value[[1]], 0.965) # FIXTURES.md-pinned mu S/cm -> mS/cm conversion

  # idempotent: no double-conversion on a second call.
  before2 <- DBI::dbGetQuery(con, "SELECT value FROM analysis WHERE uuid = 'an-0002'")$value
  expect_no_error(confirm_analyte_methods("lm-0008", "a-0003", confirmed_by = "alice"))
  after2 <- DBI::dbGetQuery(con, "SELECT value FROM analysis WHERE uuid = 'an-0002'")$value
  expect_equal(after2, before2)
  expect_equal(after2, 0.965)
})

test_that("R-11.11: an unconvertible unit does not corrupt the value and opens an unknown_unit review item", {
  setup <- fa_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  DBI::dbExecute(con, "INSERT INTO lab_method
    (uuid, uuid_analyte, name, method, organisation, rl_low, units, conversion_constant) VALUES
    ('lm-9201', NULL, 'Weird Analyte Method', 'M1', 'ALS', 1, 'banana-unit', NULL)")
  DBI::dbExecute(con, "INSERT INTO \"sample\"
    (uuid, uuid_feature_alias, uuid_project, date, datetime, organisation) VALUES
    ('s-9201', 'fa-0001', 'p-0001', TIMESTAMP '2025-08-03 00:00:00', TIMESTAMP '2025-08-03 09:00:00', 'ALS')")
  DBI::dbExecute(con, "INSERT INTO analysis (uuid, uuid_sample, uuid_lab, value, quantified, rl_low) VALUES
    ('an-9201', 's-9201', 'lm-9201', 42, TRUE, 1)")

  confirm_analyte_methods("lm-9201", "a-0002", confirmed_by = "alice") # a-0002 units: mu g/L

  unchanged <- DBI::dbGetQuery(con, "SELECT value FROM analysis WHERE uuid = 'an-9201'")
  expect_equal(unchanged$value[[1]], 42) # value left alone, not corrupted

  review <- DBI::dbGetQuery(con, "SELECT * FROM review_queue WHERE kind = 'unknown_unit'")
  expect_gt(nrow(review), 0)
  hit <- review[grepl("an-9201", review$payload, fixed = TRUE) | grepl("lm-9201", review$payload, fixed = TRUE), , drop = FALSE]
  expect_gt(nrow(hit), 0)
})

test_that("R-11.11 (D7/A63): a method seen with two different units surfaces the drift at confirmation and does NOT silently bulk-convert every analysis on it", {
  # PROVISIONAL ORACLE: the plan (R-11.8(f)) says a units mismatch is
  # "recorded for confirmation-time review" but does not pin the storage
  # mechanism precisely. This test's best reading - modelled on this same
  # plan's other provenance-logging idiom (change_log rows, action =
  # 'provenance', one row per distinct units_raw sighting on the method) -
  # and the review kind literal 'units_drift' are placeholders. See the
  # accompanying plan-change-request; Phase 6 must re-check both against the
  # real implementation before trusting them.
  setup <- fa_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # lm-0009 is dangling, currently recorded units 'mg/L' (paired with
  # an-0004, value 12). Simulate a second commit having seen 'g/L' for the
  # same method (R-11.8(f)'s drift-recording, not yet landed in R/commit.R -
  # stood in here as the precondition state confirm_analyte_methods() reacts to).
  DBI::dbExecute(con, "INSERT INTO change_log
      (uuid, \"at\", actor, action, tbl, uuid_row, field, old, new, reason, source_hash) VALUES
    (?, CURRENT_TIMESTAMP, 'pipeline', 'provenance', 'lab_method', 'lm-0009', 'units', NULL, 'mg/L', 'first sighting', 'h1'),
    (?, CURRENT_TIMESTAMP, 'pipeline', 'provenance', 'lab_method', 'lm-0009', 'units', 'mg/L', 'g/L', 'drift sighting', 'h2')",
    params = list(uuid::UUIDgenerate(), uuid::UUIDgenerate()))

  before_value <- DBI::dbGetQuery(con, "SELECT value FROM analysis WHERE uuid = 'an-0004'")$value[[1]]
  expect_equal(before_value, 12)

  confirm_analyte_methods("lm-0009", "a-0002", confirmed_by = "alice")

  # does not silently bulk-convert: an-0004's value is unchanged (neither
  # blindly converted as mg/L nor as g/L).
  after_value <- DBI::dbGetQuery(con, "SELECT value FROM analysis WHERE uuid = 'an-0004'")$value[[1]]
  expect_equal(after_value, before_value)

  drift_review <- DBI::dbGetQuery(con, "SELECT * FROM review_queue WHERE kind = 'units_drift'")
  expect_gt(nrow(drift_review), 0)
  hit <- drift_review[grepl("lm-0009", drift_review$payload, fixed = TRUE), , drop = FALSE]
  expect_gt(nrow(hit), 0)
  # FE8 (PLAN-16 Phase-7b round-2 audit): the original assertion
  # `grepl("mg/L", ...) && grepl("g/L", ...)` was tautological - "g/L" is a
  # substring of "mg/L", so the second conjunct is implied by the first and
  # the whole thing reduces to grepl("mg/L", ...). Repointed at what the
  # block name actually claims: BOTH distinct units must survive into the
  # JSON payload's `units` array, not just one of them.
  d <- jsonlite::fromJSON(hit$payload[[1]])
  expect_setequal(d$units, c("mg/L", "g/L"))
})

test_that("R-11.11 (A63): a resolved (non-drifting) row is still converted exactly as today - all existing conversion behaviour stays green (conversion_constant, R-8.4-equivalent)", {
  setup <- fa_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # lm-0012 is ALREADY resolved (uuid_analyte = a-0002) with
  # conversion_constant 2.0 - not a confirm-API fixture on its own, but this
  # pins that confirm_analyte_methods() is not the ONLY path applying
  # conversion_constant; re-confirming an already-resolved method (idempotent,
  # same analyte) must not re-apply it a second time.
  before <- DBI::dbGetQuery(con, "SELECT uuid_analyte FROM lab_method WHERE uuid = 'lm-0012'")
  expect_identical(before$uuid_analyte[[1]], "a-0002")

  expect_no_error(confirm_analyte_methods("lm-0012", "a-0002", confirmed_by = "alice"))
  after <- DBI::dbGetQuery(con, "SELECT uuid_analyte FROM lab_method WHERE uuid = 'lm-0012'")
  expect_identical(after$uuid_analyte[[1]], "a-0002")
})

test_that("R-11.11: after confirmation, the same incoming analyte auto-resolves (uuid_analyte set, no longer dangling) - no fresh review item is opened by the confirming call itself", {
  setup <- fa_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  before_open <- count_rows(con, "review_queue")
  confirm_analyte_methods("lm-0008", "a-0003", confirmed_by = "alice")
  after_open <- count_rows(con, "review_queue")
  expect_equal(after_open, before_open) # clean confirm opens nothing

  resolved <- lab_method_row(con, "lm-0008")
  expect_identical(resolved$uuid_analyte[[1]], "a-0003") # future analyses on lm-0008 auto-resolve
})

test_that("R-11.11 (A55): confirmed_by is mandatory and must not default", {
  setup <- fa_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  expect_error(confirm_analyte_methods("lm-0008", "a-0003"))
})

test_that("R-11.11: a NULL/NA uuid_analyte is rejected, not coerced into a spurious link (nullable-key safety)", {
  setup <- fa_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  expect_error(
    confirm_analyte_methods("lm-0008", NA_character_, confirmed_by = "alice"),
    class = "sampletidy_error"
  )
  still_dangling <- lab_method_row(con, "lm-0008")
  expect_true(is.na(still_dangling$uuid_analyte[[1]]))
})

test_that("R-11.11: a nonexistent uuid_lab errors before writing anything", {
  setup <- fa_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  before <- all_counts(con)
  expect_error(
    confirm_analyte_methods("lm-nonexistent-xyz", "a-0003", confirmed_by = "alice"),
    class = "sampletidy_error"
  )
  expect_equal(all_counts(con), before)
})

test_that("R-11.11: an empty uuid_lab/uuid_analyte vector is a no-op that writes nothing and returns a zero-row tibble (degenerate empty shape)", {
  setup <- fa_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  before <- all_counts(con)
  result <- confirm_analyte_methods(character(0), character(0), confirmed_by = "alice")
  expect_equal(nrow(result), 0)
  expect_equal(all_counts(con), before)
})

test_that("R-11.11: vectorised over uuid_lab/uuid_analyte - one call confirms two independent methods and returns invisible(tibble(uuid_lab, uuid_analyte, n_analyses, n_converted, action))", {
  setup <- fa_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  vis <- withVisible(confirm_analyte_methods(
    c("lm-0008", "lm-0009"), c("a-0003", "a-0002"), confirmed_by = "alice"
  ))
  expect_false(vis$visible)
  result <- vis$value
  expect_true(is.data.frame(result))
  expect_setequal(names(result), c("uuid_lab", "uuid_analyte", "n_analyses", "n_converted", "action"))
  expect_equal(nrow(result), 2)
  expect_setequal(result$uuid_lab, c("lm-0008", "lm-0009"))
})

# ======================================================================
# Meta: source-level authority-rule guard (B-11-the-api-is-the)
# ======================================================================

# ======================================================================
# Phase-7b item 7: .fa_check_kind()'s abort message used a leading-dot
# `{.fa_kind_vocabulary}` cli literal, which cli >= 3.4.0 treats as a STYLE
# token rather than interpolation - so the abort itself throws cli's own
# "Invalid cli literal" error (class rlib_error_3_0) before this function's
# documented sampletidy_error ever fires. A caller catching sampletidy_error
# (the contract F.19 pins - "fails loudly ... not a silent override") misses
# it entirely.
# ======================================================================

test_that("Phase-7b item 7: .fa_check_kind() on a typo'd kind aborts with class sampletidy_error (not a cli-internals rlib_error) AND the message names the valid vocabulary", {
  err <- tryCatch(.fa_check_kind("histrical_code"), error = function(e) e)
  expect_s3_class(err, "sampletidy_error")
  msg <- conditionMessage(err)
  # the message half matters independently of the class half: parenthesising
  # the cli literal could silence the cli error while still producing a
  # useless/empty message, and only asserting the class would not catch that.
  for (valid_kind in .fa_kind_vocabulary) {
    expect_true(grepl(valid_kind, msg, fixed = TRUE), info = valid_kind)
  }
  expect_true(grepl("histrical_code", msg, fixed = TRUE))
})

test_that("Phase-7b item 7: the same typo'd kind, reached through the public confirm_feature_aliases() entry point, also aborts sampletidy_error - not just the internal helper in isolation", {
  setup <- fa_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  expect_error(
    confirm_feature_aliases("fa-0010", "f-0002", confirmed_by = "alice", kind = "histrical_code"),
    class = "sampletidy_error"
  )
})

# ======================================================================
# PLAN-15 F.19 / R-15.37 - confirm_feature_aliases() no longer mislabels
# every confirmation as a transcription error (RULINGS-2026-07-23 R4).
# ======================================================================

test_that("R-15.37: confirming an identity-mapped pending alias (alias_key == lower(feature.name)) flips the EXISTING self arm rather than minting a duplicate row, and the self arm carries confirmed_by; a genuine non-identity alias is NOT defaulted to transcription_error", {
  setup <- fa_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # fa-9601 is the feature's own pre-existing 'self' arm (alias_key ==
  # lower(f-9601.name)); fa-9602 is a SEPARATE pending row that arrived
  # later carrying the identical key - the exact shape the b.s01/k.e02
  # duplicates came from (RULINGS R3/R4).
  DBI::dbExecute(con, "INSERT INTO feature (uuid, name, site, flow, matrix, lon, lat) VALUES
    ('f-9601', 'Z.IDENT01', 'Z', 'surface', 'water', 150.9601, -33.9601)")
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign,
     first_seen, last_seen, confirmed_by) VALUES
    ('fa-9601', 'f-9601', 'Z.IDENT01', 'z.ident01', 'self', 0, TRUE,
     TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00', NULL)")
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign,
     first_seen, last_seen, confirmed_by) VALUES
    ('fa-9602', NULL, 'Z.IDENT01', 'z.ident01', 'pending', 0, FALSE,
     TIMESTAMP '2025-09-01 08:00:00', TIMESTAMP '2025-09-01 08:00:00', NULL)")
  # Phase-7b round-2 item 8: a sample hanging off the REDUNDANT arm
  # (fa-9602) specifically - R-15.37's identity branch was previously only
  # ever exercised with a ZERO-sample redundant arm, so the repoint half of
  # Robin's Phase-7b item-2 ruling ("any sample still hanging off the
  # redundant arm is re-pointed, so a confirmation is never silently
  # ineffective") had no test at all; nothing would go red if it stopped
  # working.
  DBI::dbExecute(con, "INSERT INTO \"sample\"
    (uuid, uuid_feature_alias, uuid_project, date, datetime, organisation) VALUES
    ('s-9602', 'fa-9602', 'p-0001', TIMESTAMP '2025-09-01 00:00:00', TIMESTAMP '2025-09-01 09:00:00', 'ALS')")

  before_count <- count_rows(con, "feature_alias")
  before_self <- feature_alias_row(con, "fa-9601")
  expect_true(is.na(before_self$confirmed_by[[1]]))

  confirm_feature_aliases("fa-9602", "f-9601", confirmed_by = "alice")

  # (a) no new feature_alias row is minted for the identity confirmation, and
  # (Phase-7b item 2, RULED BY ROBIN) the now-provably-zero-sample redundant
  # arm (fa-9602) is deleted in the post-pass, so the row count drops by
  # exactly one - assert the table row count, not the resolution outcome.
  after_count <- count_rows(con, "feature_alias")
  expect_equal(after_count, before_count - 1)

  # (b) the EXISTING self arm (fa-9601), not the just-confirmed pending row,
  # carries the confirmed_by - proof the flip landed on the self arm.
  after_self <- feature_alias_row(con, "fa-9601")
  expect_identical(after_self$confirmed_by[[1]], "alice")

  # (b2) Phase-7b item 2: the redundant arm itself is gone, and
  # pending_features() (the only reader that could ever have surfaced it,
  # since it can never leave 'pending' via .fa_identity_duplicates()) no
  # longer lists it.
  expect_equal(nrow(feature_alias_row(con, "fa-9602")), 0)
  expect_false("fa-9602" %in% pending_features(con)$uuid_alias)

  # (b3) Phase-7b round-2 item 8: s-9602 - the sample that was hanging off
  # the now-deleted redundant arm - landed on the surviving self arm, not
  # orphaned by the deletion.
  s9602 <- DBI::dbGetQuery(con, "SELECT uuid_feature_alias FROM \"sample\" WHERE uuid = 's-9602'")
  expect_identical(s9602$uuid_feature_alias[[1]], "fa-9601")

  # (c) a genuine NON-identity alias (key != lower(feature.name)) accepts an
  # explicit `kind`, which round-trips onto the row rather than being
  # overridden or silently invented. Phase-5 audit C5: a bare negative
  # (`expect_false(kind == "transcription_error")`) is satisfied by ANY
  # OTHER silently-invented kind, so the positive form is asserted.
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign,
     first_seen, last_seen, confirmed_by) VALUES
    ('fa-9603', NULL, 'ZIDENTMISPELL', 'zidentmispell', 'pending', 0, FALSE,
     TIMESTAMP '2025-09-01 08:00:00', TIMESTAMP '2025-09-01 08:00:00', NULL)")
  confirm_feature_aliases("fa-9603", "f-9601", confirmed_by = "alice", kind = "historical_code")
  non_identity <- feature_alias_row(con, "fa-9603")
  expect_identical(non_identity$kind[[1]], "historical_code") # round-tripped, not invented

  # (d) OMITTING `kind` on the non-identity branch DEFAULTS to
  # `transcription_error`; it is NOT an error.
  #
  # RULED BY ROBIN 2026-07-26, overriding PCR-5's non-identity half. PCR-5
  # (F.19, 2026-07-24) said omission here must abort with no default, and this
  # block asserted that. It contradicted R-11.10 (test-feature-alias.R:126),
  # green since PLAN-11, which pins the same shape SUCCEEDING with exactly this
  # default - fa-0010 ('t.s09' -> f-0002 'T.S02') is non-identity too, so no
  # discriminator separates the two fixtures. PCR-5 was aimed at F.19's
  # IDENTITY branch and the non-identity half came along uncosted.
  #
  # Resolved in favour of the shipped behaviour because a transcription variant
  # IS the honest majority case for a pending non-identity alias, and because
  # `kind` is provenance only: the sole production branch on it anywhere is
  # `kind == "self"` (reconcile.R:632,653). Nothing reads historical_code vs
  # transcription_error - not reconcile, not commit, not migration 002, not
  # merge_identity_aliases(). Making omission an error would have broken a
  # shipped public API to protect a field with no reader.
  #
  # Residual, accepted: a `descriptive` or `mask_long` name (a sheet writing
  # "Downstream Cripple Creek" for B.S01) confirmed without `kind` is labelled
  # a typo when nobody mistyped. An operator who cares passes `kind`.
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign,
     first_seen, last_seen, confirmed_by) VALUES
    ('fa-9604', NULL, 'ZIDENTMISPELL2', 'zidentmispell2', 'pending', 0, FALSE,
     TIMESTAMP '2025-09-01 08:00:00', TIMESTAMP '2025-09-01 08:00:00', NULL)")
  confirm_feature_aliases("fa-9604", "f-9601", confirmed_by = "alice")
  defaulted <- feature_alias_row(con, "fa-9604")
  expect_identical(defaulted$kind[[1]], "transcription_error")
  expect_identical(defaulted$uuid_feature[[1]], "f-9601")
})

# ---- Phase-7b round-2 item 4: normalisation divergence at the identity ----
#      boundary (a trailing NBSP survives plain tolower()/SQL lower() but not
#      .rc_feature_key(), the function alias_key was actually built with).

test_that("Phase-7b round-2 item 4: an identity confirmation is recognised even when the feature's own name carries a non-breaking space .rc_feature_key() trims but plain tolower() does not - flips the existing self arm rather than minting a mislabelled duplicate", {
  setup <- fa_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  nbsp_name <- "Z.NBSPTEST01 " # trailing NBSP - .rc_feature_key() trims it, tolower() does not
  key <- .rc_feature_key(nbsp_name)
  expect_false(identical(key, tolower(nbsp_name))) # the two folds genuinely diverge on this input

  DBI::dbExecute(con, "INSERT INTO feature (uuid, name, site, flow, matrix, lon, lat) VALUES
    ('f-9901', ?, 'Z', 'surface', 'water', 150.9901, -33.9901)", params = list(nbsp_name))
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign,
     first_seen, last_seen, confirmed_by) VALUES
    ('fa-9901', 'f-9901', ?, ?, 'self', 0, TRUE,
     TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00', NULL)",
    params = list(nbsp_name, key))
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign,
     first_seen, last_seen, confirmed_by) VALUES
    ('fa-9902', NULL, ?, ?, 'pending', 0, FALSE,
     TIMESTAMP '2025-09-01 08:00:00', TIMESTAMP '2025-09-01 08:00:00', NULL)",
    params = list(nbsp_name, key))

  before_count <- count_rows(con, "feature_alias")

  confirm_feature_aliases("fa-9902", "f-9901", confirmed_by = "alice")

  # the identity flip happened (existing self arm fa-9901 carries
  # confirmed_by; no duplicate second arm minted, so the row count drops by
  # exactly one, same shape as the fa-9601/fa-9602 test above) - NOT the
  # buggy "mints a mislabelled transcription_error duplicate" behaviour.
  after_count <- count_rows(con, "feature_alias")
  expect_equal(after_count, before_count - 1)
  after_self <- feature_alias_row(con, "fa-9901")
  expect_identical(after_self$confirmed_by[[1]], "alice")
  expect_equal(nrow(feature_alias_row(con, "fa-9902")), 0) # redundant arm deleted, not left as a duplicate
})

test_that("Phase-7b round-2 item 4: .fa_identity_duplicates()/merge_identity_aliases() find and merge a pre-existing identity duplicate even when the feature's own name carries a non-breaking space (SQL lower() would miss it; the R-side .rc_feature_key() match does not)", {
  setup <- fa_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  nbsp_name <- "Z.NBSPTEST02 "
  key <- .rc_feature_key(nbsp_name)

  DBI::dbExecute(con, "INSERT INTO feature (uuid, name, site, flow, matrix, lon, lat) VALUES
    ('f-9903', ?, 'Z', 'surface', 'water', 150.9903, -33.9903)", params = list(nbsp_name))
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign,
     first_seen, last_seen, confirmed_by) VALUES
    ('fa-9903', 'f-9903', ?, ?, 'self', 0, FALSE,
     TIMESTAMP '2020-01-01 00:00:00', TIMESTAMP '2020-01-01 00:00:00', NULL)",
    params = list(nbsp_name, key))
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign,
     first_seen, last_seen, confirmed_by) VALUES
    ('fa-9904', 'f-9903', ?, ?, 'transcription_error', 0, TRUE,
     TIMESTAMP '2026-01-01 00:00:00', TIMESTAMP '2026-01-01 00:00:00', 'R. Shannon')",
    params = list(nbsp_name, key))

  cand <- .fa_identity_duplicates(con)
  expect_true("fa-9904" %in% cand$uuid_loser)

  result <- merge_identity_aliases(actor = "phase7b-item4-nbsp-test")
  expect_true("fa-9904" %in% result$uuid_loser)
  expect_equal(nrow(feature_alias_row(con, "fa-9904")), 0)
  survivor <- feature_alias_row(con, "fa-9903")
  expect_identical(survivor$confirmed_by[[1]], "R. Shannon")
  expect_true(survivor$auto_assign[[1]])
})

test_that("Phase-7b item 6: bounding a 'self' arm aborts - own-name reachability (R1) is unconditional and a bound cannot be silently attached to it", {
  setup <- fa_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  DBI::dbExecute(con, "INSERT INTO feature (uuid, name, site, flow, matrix, lon, lat) VALUES
    ('f-9801', 'Z.SELFBOUND01', 'Z', 'surface', 'water', 150.9801, -33.9801)")

  # (a) a DIRECT re-confirm of a row that already carries kind = 'self',
  # with a bound - must abort before writing anything.
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign,
     first_seen, last_seen, confirmed_by) VALUES
    ('fa-9801', 'f-9801', 'Z.SELFBOUND01', 'z.selfbound01', 'self', 0, TRUE,
     TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00', NULL)")
  before_direct <- feature_alias_row(con, "fa-9801")
  err_direct <- tryCatch(
    confirm_feature_aliases(
      "fa-9801", "f-9801", confirmed_by = "alice", date_start = as.Date("2025-01-01")
    ),
    error = function(e) e
  )
  expect_s3_class(err_direct, "sampletidy_error")
  after_direct <- feature_alias_row(con, "fa-9801")
  expect_true(is.na(after_direct$date_start[[1]])) # nothing written
  expect_identical(after_direct, before_direct)

  # (b) an IDENTITY mapping FLIPPING an existing self arm, with a bound -
  # must also abort, even though the bound is nominally attached to the
  # confirming call for the REDUNDANT arm, not the self arm directly.
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign,
     first_seen, last_seen, confirmed_by) VALUES
    ('fa-9802', NULL, 'Z.SELFBOUND01', 'z.selfbound01', 'pending', 0, FALSE,
     TIMESTAMP '2025-09-01 08:00:00', TIMESTAMP '2025-09-01 08:00:00', NULL)")
  before_flip_self <- feature_alias_row(con, "fa-9801")
  err_flip <- tryCatch(
    confirm_feature_aliases(
      "fa-9802", "f-9801", confirmed_by = "alice", date_end = as.Date("2025-12-31")
    ),
    error = function(e) e
  )
  expect_s3_class(err_flip, "sampletidy_error")
  after_flip_self <- feature_alias_row(con, "fa-9801") # the self arm itself, untouched
  expect_identical(after_flip_self, before_flip_self)
  after_flip_redundant <- feature_alias_row(con, "fa-9802")
  expect_true(is.na(after_flip_redundant$uuid_feature[[1]])) # still dangling, no write happened
  expect_true(is.na(after_flip_redundant$date_end[[1]]))

  # (c) a NON-self bound (e.g. on fa-0009, kind = 'descriptive') is
  # unaffected - the regression guard proving this fix did not become a
  # blanket "bounds are always rejected" bug.
  expect_no_error(
    confirm_feature_aliases(
      "fa-0009", "f-0003", confirmed_by = "alice", date_start = as.Date("2020-01-01")
    )
  )
  non_self <- feature_alias_row(con, "fa-0009")
  expect_equal(non_self$date_start[[1]], as.Date("2020-01-01"))

  # (d) Phase-7b round-2 item 3: the BOUNDS-ONLY route (`uuid_feature`
  # omitted) - a DIRECT re-confirm of a row that already carries
  # kind = 'self', with a bound. The R1 guard above lived entirely inside
  # the non-bounds-only branch (past that branch's own early `return()`),
  # so this exact shape - `confirm_feature_aliases(<self arm>,
  # confirmed_by=, date_end=)` with no `uuid_feature` - used to succeed and
  # store the bound on a `kind='self'` row with `auto_assign` left TRUE.
  before_bounds_only <- feature_alias_row(con, "fa-9801")
  err_bounds_only <- tryCatch(
    confirm_feature_aliases(
      "fa-9801", confirmed_by = "alice", date_end = as.Date("2020-01-01")
    ),
    error = function(e) e
  )
  expect_s3_class(err_bounds_only, "sampletidy_error")
  after_bounds_only <- feature_alias_row(con, "fa-9801")
  expect_identical(after_bounds_only, before_bounds_only) # nothing written
})

# ---- coverage-gap tests for two mutations the round-2 audit measured as ---
#      SURVIVING the full suite (M1, M4) --------------------------------

test_that("Phase-7b round-2 M1 coverage gap: an identity mapping BECOMING a feature's self arm for the FIRST TIME (no pre-existing self arm at all) with a bound aborts - R1's guard must fire on `is_identity` alone, not only via an already-resolved `self_arm`", {
  setup <- fa_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # f-9820 has NO self arm yet at all - fa-9820 is a still-pending identity
  # mapping (alias_key == .rc_feature_key(feature name)) that would become
  # the feature's self arm for the first time on confirmation. Under the M1
  # mutant (`target_is_self` dropping `|| is_identity`), `self_arm` stays NA
  # (no pre-existing self arm to find) AND `alias$kind[[1]]` is 'pending', so
  # `target_is_self` would be FALSE and the bound would be silently written.
  DBI::dbExecute(con, "INSERT INTO feature (uuid, name, site, flow, matrix, lon, lat) VALUES
    ('f-9820', 'Z.NEWSELF01', 'Z', 'surface', 'water', 150.9820, -33.9820)")
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign,
     first_seen, last_seen, confirmed_by) VALUES
    ('fa-9820', NULL, 'Z.NEWSELF01', 'z.newself01', 'pending', 0, FALSE,
     TIMESTAMP '2025-09-01 08:00:00', TIMESTAMP '2025-09-01 08:00:00', NULL)")

  err <- tryCatch(
    confirm_feature_aliases(
      "fa-9820", "f-9820", confirmed_by = "alice", date_start = as.Date("2025-01-01")
    ),
    error = function(e) e
  )
  expect_s3_class(err, "sampletidy_error")

  after <- feature_alias_row(con, "fa-9820")
  expect_true(is.na(after$date_start[[1]])) # nothing written
  expect_true(is.na(after$uuid_feature[[1]])) # the whole call aborted, not just the bound
})

test_that("Phase-7b round-3 A2: the BOUNDS-ONLY R1 guard must also fire on a mislabelled arm that IS the feature's own name (identity), not only on kind == 'self' - own-name reachability must not go 1 -> 0", {
  setup <- fa_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # The ONLY arm carrying the feature's own name, mislabelled
  # 'transcription_error' (the pre-F.19 registry shape merge_identity_
  # aliases() exists to clean up) - already confirmed (uuid_feature set), so
  # its OWN uuid_feature is in hand without picking anything. The bounds-only
  # copy of the R1 guard used to check only `kind == 'self'` and let a bound
  # land here, making the feature unreachable by its own name.
  DBI::dbExecute(con, "INSERT INTO feature (uuid, name, site, flow, matrix, lon, lat) VALUES
    ('f-9840', 'Z.MISLABEL9840', 'Z', 'surface', 'water', 150.9840, -33.9840)")
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign,
     first_seen, last_seen, confirmed_by) VALUES
    ('fa-9840', 'f-9840', 'Z.MISLABEL9840', 'z.mislabel9840', 'transcription_error', 1, TRUE,
     TIMESTAMP '2020-01-01 00:00:00', TIMESTAMP '2020-01-01 00:00:00', 'R. Shannon')")

  registry_before <- .rc_load_registry(con)
  before_n <- nrow(.rc_feature_candidates("Z.MISLABEL9840", as.Date("2026-01-01"), registry_before))
  expect_equal(before_n, 1L)

  before_row <- feature_alias_row(con, "fa-9840")
  err <- tryCatch(
    confirm_feature_aliases(
      "fa-9840", confirmed_by = "alice", date_end = as.Date("2021-01-01")
    ),
    error = function(e) e
  )
  expect_s3_class(err, "sampletidy_error")
  after_row <- feature_alias_row(con, "fa-9840")
  expect_identical(after_row, before_row) # nothing written

  registry_after <- .rc_load_registry(con)
  after_n <- nrow(.rc_feature_candidates("Z.MISLABEL9840", as.Date("2026-01-01"), registry_after))
  expect_equal(after_n, 1L) # still reachable by its own name
})

test_that("Phase-7b round-2 M4 coverage gap: re-confirming a row that IS ALREADY its own feature's self arm (no kind, no bound - a plain idempotent re-confirm) never deletes it", {
  setup <- fa_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # fa-9830 IS f-9830's self arm already. `arms` (the query at
  # `.fa_confirm_one_alias()`'s identity check) finds ITSELF here. Under the
  # M4 mutant (dropping `&& !identical(arms$uuid[[1]], uuid_alias)`),
  # `self_arm` would be set to `uuid_alias` itself, and the F.19 post-pass
  # would then repoint-onto-itself (a no-op) and DELETE the feature's own
  # self arm.
  DBI::dbExecute(con, "INSERT INTO feature (uuid, name, site, flow, matrix, lon, lat) VALUES
    ('f-9830', 'Z.SELFRECONF01', 'Z', 'surface', 'water', 150.9830, -33.9830)")
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign,
     first_seen, last_seen, confirmed_by) VALUES
    ('fa-9830', 'f-9830', 'Z.SELFRECONF01', 'z.selfreconf01', 'self', 0, TRUE,
     TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00', NULL)")

  expect_no_error(
    confirm_feature_aliases("fa-9830", "f-9830", confirmed_by = "alice")
  )

  after <- feature_alias_row(con, "fa-9830")
  expect_equal(nrow(after), 1) # the self arm must survive - never deleted
  expect_identical(after$confirmed_by[[1]], "alice")
  expect_identical(after$kind[[1]], "self")
})

test_that("Phase-7b round-3 A11: an open sample_collision row on a redundant identity arm is re-keyed onto the surviving self arm before the F.19 post-pass deletes it, not left orphaned", {
  setup <- fa_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  DBI::dbExecute(con, "INSERT INTO feature (uuid,name,site,flow,matrix,lon,lat) VALUES
    ('f-9850','Z.ORPH9850','Z','surface','water',150.9850,-33.9850)")
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid,uuid_feature,name,alias_key,kind,n_seen,auto_assign,first_seen,last_seen,confirmed_by) VALUES
    ('fa-9850-self','f-9850','Z.ORPH9850','z.orph9850','self',0,TRUE,
     TIMESTAMP '2020-01-01 00:00:00',TIMESTAMP '2020-01-01 00:00:00',NULL),
    ('fa-9850-red',NULL,'Z.ORPH9850','z.orph9850','pending',0,FALSE,
     TIMESTAMP '2026-01-01 00:00:00',TIMESTAMP '2026-01-01 00:00:00',NULL)")
  DBI::dbExecute(con, "INSERT INTO \"sample\"
    (uuid,uuid_feature_alias,uuid_project,date,datetime,organisation) VALUES
    ('s-9850a','fa-9850-red','p-0001',TIMESTAMP '2026-02-01 00:00:00',TIMESTAMP '2026-02-01 09:00:00','ALS'),
    ('s-9850b','fa-9850-red','p-0001',TIMESTAMP '2026-02-01 00:00:00',TIMESTAMP '2026-02-01 14:00:00','ACIRL')")

  confirm_feature_aliases("fa-9850-red", "f-9850", confirmed_by = "alice")

  # the redundant arm is gone (F.19 post-pass, mirroring probe7).
  expect_equal(
    nrow(DBI::dbGetQuery(con, "SELECT 1 FROM feature_alias WHERE uuid = 'fa-9850-red'")), 0
  )

  open_rq <- review_queue(con, status = "open")
  collision <- open_rq[open_rq$kind == "sample_collision", , drop = FALSE]
  expect_equal(nrow(collision), 1) # the review item still exists...

  # ...and no longer points at the deleted alias - it was re-keyed onto the
  # surviving self arm, so an operator can still look it up.
  expect_false("fa-9850-red" %in% collision$uuid_alias)
  expect_false("fa-9850-red" %in% collision$uuid_target)
  expect_true(all(collision$uuid_alias == "fa-9850-self"))
  expect_true(all(collision$uuid_target == "fa-9850-self"))
})

# ======================================================================
# PLAN-15 E.8 / R-15.44 - merge the two duplicate identity arms (R3).
#
#   merge_identity_aliases(db = st_config("live_db"), actor, dry_run = FALSE)
#     -> tibble(alias_key, uuid_winner, uuid_loser, n_repointed)
#   PINNED by the orchestrator 2026-07-24 in PLAN-15 B-15.E8 - this is no longer
#   a guess. `actor` is MANDATORY (no default): the op DELETEs registry rows and
#   repoints `sample`, and every change_log row it writes needs an honest actor.
#   For every (alias_key, uuid_feature) pair holding BOTH a `kind = 'self'`
#   row and a distinct non-self row sharing `alias_key == lower(feature.name)`
#   (an identity duplicate - E.8's own definition): carries `confirmed_by`
#   and `auto_assign = TRUE` onto the surviving self row, repoints every
#   `sample.uuid_feature_alias` reference from the deleted row onto the
#   survivor, then deletes the duplicate - one `with_db_write()` transaction,
#   `change_log` provenance on both writes.
# ======================================================================

#' A local, FK-constrained fixture reproducing E.8's duplicate-identity shape
#' (mirrors `fa_fk_setup()`'s own idiom, not a reuse of it - that helper's
#' analyte/lab_method/analysis chain has no feature/feature_alias/sample
#' tables at all): one feature carrying BOTH a `self` arm (auto_assign
#' FALSE, unconfirmed - the real pre-003 registry shape) and a
#' `transcription_error` duplicate of the SAME alias_key (auto_assign TRUE,
#' confirmed_by = 'R. Shannon' - E.8's own worked example, `b.s01`/`k.e02`),
#' with a `sample` row hanging off the DUPLICATE arm specifically - the only
#' way (d)'s "sample count unchanged across the merge" assertion below can
#' fail, since a merge that deletes the duplicate WITHOUT repointing first
#' orphans that sample (or, with the FK below, aborts outright).
#' Cleanup (tempdir, option) bound to the CALLING TEST's frame, not this
#' helper's own frame (the withr wrong-frame trap, language-footguns.md).
fa_e8_setup <- function() {
  env <- parent.frame()
  dir <- withr::local_tempdir(.local_envir = env)
  path <- file.path(dir, "e8-seed.duckdb")
  withr::local_options(list("sampletidy.live_db" = path), .local_envir = env)

  {
    con <- DBI::dbConnect(duckdb::duckdb(), path, read_only = FALSE)
    on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

    ensure_schema(con) # review_queue/change_log/schema_version - reused, not re-derived

    DBI::dbExecute(con, "CREATE TABLE feature (
      uuid VARCHAR PRIMARY KEY, name VARCHAR, site VARCHAR,
      lon DOUBLE NOT NULL, lat DOUBLE NOT NULL)")
    DBI::dbExecute(con, "CREATE TABLE feature_alias (
      uuid VARCHAR PRIMARY KEY, uuid_feature VARCHAR REFERENCES feature(uuid),
      name VARCHAR NOT NULL, alias_key VARCHAR NOT NULL, kind VARCHAR,
      n_seen INTEGER DEFAULT 0, auto_assign BOOLEAN DEFAULT TRUE,
      first_seen TIMESTAMP, last_seen TIMESTAMP, confirmed_by VARCHAR,
      date_start DATE, date_end DATE, comments VARCHAR)")
    DBI::dbExecute(con, "CREATE TABLE \"sample\" (
      uuid VARCHAR PRIMARY KEY,
      uuid_feature_alias VARCHAR NOT NULL REFERENCES feature_alias(uuid),
      date TIMESTAMP, datetime TIMESTAMP, organisation VARCHAR)")
    # Phase-7b round-2 item 7: an `analysis` table WITH a real FK on
    # `uuid_sample` - unlike the earlier version of this fixture, which (like
    # `fa_e8_dup_loser_setup()` below) declared no child table referencing
    # `sample` at all, so `.fa_fk_dependents(con, "sample", ...)` returned
    # `list()` and `.fa_repoint_samples()` degenerated to a plain
    # `db_update()`. That is NOT the shape the live registry has - `analysis`
    # really does reference `sample` - so the detach/reattach dance this
    # merge is supposed to exercise had never actually run under this test.
    DBI::dbExecute(con, "CREATE TABLE analysis (
      uuid VARCHAR PRIMARY KEY,
      uuid_sample VARCHAR REFERENCES \"sample\"(uuid),
      value DOUBLE)")

    # Phase-5 audit round 2 B1: `.rc_load_registry()` (R/reconcile.R:25-34)
    # does an unconditional `SELECT * FROM` all SIX of feature/feature_alias/
    # feature_mask/analyte/lab_method/project - the (c) assertion below goes
    # through the REAL resolver, so all six must EXIST (empty is fine; none
    # of this unit's assertions touch these four). Reuses
    # helper-migration-003-db.R's own `.st_mig003_empty_ddl` idiom rather
    # than inventing a new one.
    for (ddl in .st_mig003_empty_ddl) DBI::dbExecute(con, ddl)

    DBI::dbExecute(con, "INSERT INTO feature (uuid, name, site, lon, lat) VALUES
      ('f-e8-01', 'Z.E8DUP01', 'Z', 150.8801, -33.8801)")

    DBI::dbExecute(con, "INSERT INTO feature_alias
      (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign, first_seen, last_seen, confirmed_by) VALUES
      ('fa-e8-self', 'f-e8-01', 'Z.E8DUP01', 'z.e8dup01', 'self', 3, FALSE,
       TIMESTAMP '2020-01-01 00:00:00', TIMESTAMP '2020-01-01 00:00:00', NULL)")
    DBI::dbExecute(con, "INSERT INTO feature_alias
      (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign, first_seen, last_seen, confirmed_by) VALUES
      ('fa-e8-dup', 'f-e8-01', 'Z.E8DUP01', 'z.e8dup01', 'transcription_error', 1, TRUE,
       TIMESTAMP '2026-07-23 00:00:00', TIMESTAMP '2026-07-23 00:00:00', 'R. Shannon')")

    # Phase-5 audit round 3 B4: a SECOND feature + a NON-IDENTITY pair - the
    # negative control the E.8 fixture lacked entirely. 'z.e8diff01' IS an
    # identity key for f-e8-02 (its self arm's alias_key == lower(name)),
    # but the SECOND arm sharing that key points at a DIFFERENT feature
    # (f-e8-03) - the canonical "an alias key IS another feature's real
    # name" shape (mirrors t.s02 in test-reconcile.R's R-15.45: self f-0002
    # + historical f-0003). E.8 restricts the merge to IDENTITY duplicates -
    # `alias_key == lower(feature.name)` with BOTH arms pointing at the SAME
    # feature (PLAN-15:1258-1261). An implementation written as "for every
    # alias_key holding a self row and >=1 non-self row, merge" - with no
    # same-feature restriction - would wrongly merge this pair too, deleting
    # a curated historical/descriptive arm of exactly the kind E.5/E.7/003
    # exist to preserve.
    # MERGE-CANDIDATE-COUNT COMMENT: for alias_key 'z.e8diff01', a
    # plan-conformant merge_identity_aliases() must treat this as ZERO
    # identity-duplicate pairs (fa-e8-self2 -> f-e8-02, fa-e8-otherfeat ->
    # f-e8-03 - two DIFFERENT features), vs alias_key 'z.e8dup01' above,
    # which is exactly ONE identity pair (fa-e8-self/fa-e8-dup, both ->
    # f-e8-01). Both R-15.44 tests below assert `result$alias_key` never
    # contains 'z.e8diff01'.
    DBI::dbExecute(con, "INSERT INTO feature (uuid, name, site, lon, lat) VALUES
      ('f-e8-02', 'Z.E8DIFF01', 'Z', 150.8802, -33.8802),
      ('f-e8-03', 'Z.E8DIFF02', 'Z', 150.8803, -33.8803)")
    DBI::dbExecute(con, "INSERT INTO feature_alias
      (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign, first_seen, last_seen, confirmed_by) VALUES
      ('fa-e8-self2', 'f-e8-02', 'Z.E8DIFF01', 'z.e8diff01', 'self', 2, FALSE,
       TIMESTAMP '2020-01-01 00:00:00', TIMESTAMP '2020-01-01 00:00:00', NULL)")
    DBI::dbExecute(con, "INSERT INTO feature_alias
      (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign, first_seen, last_seen, confirmed_by) VALUES
      ('fa-e8-otherfeat', 'f-e8-03', 'Z.E8DIFF01', 'z.e8diff01', 'historical_code', 1, TRUE,
       TIMESTAMP '2015-01-01 00:00:00', TIMESTAMP '2019-12-31 00:00:00', 'R. Shannon')")

    DBI::dbExecute(con, "INSERT INTO \"sample\"
      (uuid, uuid_feature_alias, date, datetime, organisation) VALUES
      ('s-e8-01', 'fa-e8-dup', TIMESTAMP '2026-06-01 00:00:00', TIMESTAMP '2026-06-01 09:00:00', 'ALS')")
    # Phase-7b round-2 item 7: two analyses hanging off s-e8-01 - the sample
    # that is about to be re-pointed. `.fa_needs_fk_dance()` now sees a real
    # dependent (an FK-declared `analysis` row referencing `sample.uuid`)
    # and drives `.fa_guarded_update()` into its detach -> update -> reattach
    # branch for THIS sample's own repoint, exercising the exact
    # "thousands of separately committed analysis.uuid_sample NULL/restore
    # pairs" path the live registry actually runs.
    DBI::dbExecute(con, "INSERT INTO analysis (uuid, uuid_sample, value) VALUES
      ('an-e8-01', 's-e8-01', 7.0), ('an-e8-02', 's-e8-01', 8.0)")
  }

  list(path = path, con = seed_con(path))
}

test_that("R-15.44 (E.8): merges a duplicate identity arm into its self arm, deletes the duplicate, repoints its sample, and leaves the feature's sample count unchanged across the merge", {
  setup <- fa_e8_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  before_n <- DBI::dbGetQuery(con,
    "SELECT count(*) AS n FROM \"sample\" s JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
     WHERE fa.uuid_feature = 'f-e8-01'")$n
  expect_equal(before_n, 1) # positive control: the sample is reachable before the merge

  result <- merge_identity_aliases(actor = "phase5-e8-test")

  # Phase-5 audit round 2 C2: the return value is PINNED as
  # tibble(alias_key, uuid_winner, uuid_loser, n_repointed) - nothing
  # previously asserted it, so an implementation returning NULL passed.
  expect_named(result, c("alias_key", "uuid_winner", "uuid_loser", "n_repointed"))
  expect_equal(nrow(result), 1)
  expect_identical(result$alias_key[[1]], "z.e8dup01")
  expect_identical(result$uuid_winner[[1]], "fa-e8-self")
  expect_identical(result$uuid_loser[[1]], "fa-e8-dup")
  expect_equal(result$n_repointed[[1]], 1)

  # Phase-5 audit round 3 B4: the non-identity pair (z.e8diff01, self ->
  # f-e8-02 vs historical_code -> f-e8-03) must be ABSENT from the returned
  # tibble - the negative control this fixture previously lacked.
  expect_false("z.e8diff01" %in% result$alias_key)

  # (a) exactly ONE feature_alias row for the key afterwards.
  after_rows <- DBI::dbGetQuery(con, "SELECT * FROM feature_alias WHERE alias_key = 'z.e8dup01'")
  expect_equal(nrow(after_rows), 1)

  # (b) that row is kind = 'self', auto_assign = TRUE, confirmed_by preserved
  # - and it is the SELF row that survives, never the duplicate.
  expect_identical(after_rows$kind[[1]], "self")
  expect_true(after_rows$auto_assign[[1]])
  expect_identical(after_rows$confirmed_by[[1]], "R. Shannon")
  expect_identical(after_rows$uuid[[1]], "fa-e8-self")

  # (c) the raw name still resolves - a real seam test through the actual
  # resolver, not a raw flag check.
  registry <- .rc_load_registry(con)
  cand <- .rc_feature_candidates("Z.E8DUP01", as.Date("2026-07-24"), registry)
  expect_equal(nrow(cand), 1L)
  expect_identical(cand$uuid_feature, "f-e8-01")

  # (d) THE ONE THAT MATTERS: the sample count attached to the feature is
  # UNCHANGED across the merge, asserted before AND after - a merge that
  # deletes a row a `sample` still points at orphans data, and nothing else
  # in this suite would go red on that.
  after_n <- DBI::dbGetQuery(con,
    "SELECT count(*) AS n FROM \"sample\" s JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
     WHERE fa.uuid_feature = 'f-e8-01'")$n
  expect_equal(after_n, before_n)
  repointed <- DBI::dbGetQuery(con, "SELECT uuid_feature_alias FROM \"sample\" WHERE uuid = 's-e8-01'")$uuid_feature_alias
  expect_identical(repointed, "fa-e8-self") # repoint landed on the survivor, not orphaned

  # (d2) Phase-7b round-2 item 7: the FK-dependent `analysis` rows on the
  # re-pointed sample - the shape that actually drove `.fa_guarded_update()`
  # into its detach/reattach dance for THIS repoint - still point at the
  # SAME sample afterwards, neither orphaned nor left detached.
  after_analyses <- DBI::dbGetQuery(con, "SELECT uuid, uuid_sample FROM analysis ORDER BY uuid")
  expect_equal(nrow(after_analyses), 2)
  expect_true(all(after_analyses$uuid_sample == "s-e8-01"))

  # (e) B4: the non-identity pair (different features sharing a key)
  # SURVIVES untouched - never merged, never deleted, both rows intact with
  # their original fields.
  diff_rows <- DBI::dbGetQuery(con,
    "SELECT * FROM feature_alias WHERE alias_key = 'z.e8diff01' ORDER BY uuid")
  expect_equal(nrow(diff_rows), 2)
  expect_setequal(diff_rows$uuid, c("fa-e8-self2", "fa-e8-otherfeat"))
  self2 <- diff_rows[diff_rows$uuid == "fa-e8-self2", ]
  other <- diff_rows[diff_rows$uuid == "fa-e8-otherfeat", ]
  expect_identical(self2$uuid_feature[[1]], "f-e8-02")
  expect_identical(other$uuid_feature[[1]], "f-e8-03")
  expect_identical(other$confirmed_by[[1]], "R. Shannon")
})

test_that("R-15.44 (E.8): dry_run = TRUE leaves both alias rows AND the sample pointer unchanged, while still returning the same itemised tibble", {
  # Phase-5 audit round 2 C2: dry_run was asserted NOWHERE - an
  # implementation that deletes and repoints REGARDLESS of dry_run passed.
  setup <- fa_e8_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  before_rows <- DBI::dbGetQuery(con,
    "SELECT * FROM feature_alias WHERE alias_key = 'z.e8dup01' ORDER BY uuid")
  before_sample <- DBI::dbGetQuery(con,
    "SELECT uuid_feature_alias FROM \"sample\" WHERE uuid = 's-e8-01'")$uuid_feature_alias

  result <- merge_identity_aliases(actor = "phase5-e8-dryrun-test", dry_run = TRUE)

  # dry_run returns the SAME itemised tibble a real run would - an operator
  # previewing the merge sees exactly what would happen.
  expect_named(result, c("alias_key", "uuid_winner", "uuid_loser", "n_repointed"))
  expect_equal(nrow(result), 1)
  expect_identical(result$alias_key[[1]], "z.e8dup01")
  expect_identical(result$uuid_winner[[1]], "fa-e8-self")
  expect_identical(result$uuid_loser[[1]], "fa-e8-dup")
  expect_equal(result$n_repointed[[1]], 1)

  # Phase-5 audit round 3 B4: absent from the itemised tibble under dry_run
  # too - the non-identity pair is never a merge candidate, dry_run or not.
  expect_false("z.e8diff01" %in% result$alias_key)

  after_rows <- DBI::dbGetQuery(con,
    "SELECT * FROM feature_alias WHERE alias_key = 'z.e8dup01' ORDER BY uuid")
  after_sample <- DBI::dbGetQuery(con,
    "SELECT uuid_feature_alias FROM \"sample\" WHERE uuid = 's-e8-01'")$uuid_feature_alias

  expect_equal(nrow(after_rows), 2)         # BOTH rows survive - dry_run must not delete
  expect_equal(after_rows, before_rows)     # nothing on either row was written
  expect_identical(after_sample, before_sample) # sample pointer NOT repointed

  # (B4) the non-identity pair survives untouched under dry_run too.
  diff_rows <- DBI::dbGetQuery(con,
    "SELECT * FROM feature_alias WHERE alias_key = 'z.e8diff01' ORDER BY uuid")
  expect_equal(nrow(diff_rows), 2)
  expect_setequal(diff_rows$uuid, c("fa-e8-self2", "fa-e8-otherfeat"))
})

# ---- Phase-7b item 4: a duplicate loser aborts mid-way with no de-dup -----

#' Two `kind = 'self'` arms sharing one `alias_key`/feature (a bug precondition
#' - two self arms should not normally coexist, but this fixture proves the
#' merge loop survives it rather than assuming it away), plus ONE non-self
#' duplicate arm carrying the same key. `.fa_identity_duplicates()` joins on
#' (alias_key, uuid_feature) with no restriction distinguishing the two self
#' rows, so it emits the SAME `uuid_loser` (the one non-self arm) TWICE, paired
#' with each self arm in turn - the exact duplicate-loser shape item 4 fixes.
fa_e8_dup_loser_setup <- function() {
  env <- parent.frame()
  dir <- withr::local_tempdir(.local_envir = env)
  path <- file.path(dir, "e8-duploser-seed.duckdb")
  withr::local_options(list("sampletidy.live_db" = path), .local_envir = env)

  {
    con <- DBI::dbConnect(duckdb::duckdb(), path, read_only = FALSE)
    on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

    ensure_schema(con)

    DBI::dbExecute(con, "CREATE TABLE feature (
      uuid VARCHAR PRIMARY KEY, name VARCHAR, site VARCHAR,
      lon DOUBLE NOT NULL, lat DOUBLE NOT NULL)")
    DBI::dbExecute(con, "CREATE TABLE feature_alias (
      uuid VARCHAR PRIMARY KEY, uuid_feature VARCHAR REFERENCES feature(uuid),
      name VARCHAR NOT NULL, alias_key VARCHAR NOT NULL, kind VARCHAR,
      n_seen INTEGER DEFAULT 0, auto_assign BOOLEAN DEFAULT TRUE,
      first_seen TIMESTAMP, last_seen TIMESTAMP, confirmed_by VARCHAR,
      date_start DATE, date_end DATE, comments VARCHAR)")
    DBI::dbExecute(con, "CREATE TABLE \"sample\" (
      uuid VARCHAR PRIMARY KEY,
      uuid_feature_alias VARCHAR NOT NULL REFERENCES feature_alias(uuid),
      date TIMESTAMP, datetime TIMESTAMP, organisation VARCHAR)")
    # Phase-7b round-2 item 7: same fix as fa_e8_setup() above - a real FK
    # child table on `sample`, so the merge's repoint of s-dup-01 actually
    # exercises `.fa_guarded_update()`'s detach/reattach dance rather than
    # degenerating to a plain db_update().
    DBI::dbExecute(con, "CREATE TABLE analysis (
      uuid VARCHAR PRIMARY KEY,
      uuid_sample VARCHAR REFERENCES \"sample\"(uuid),
      value DOUBLE)")
    for (ddl in .st_mig003_empty_ddl) DBI::dbExecute(con, ddl)

    DBI::dbExecute(con, "INSERT INTO feature (uuid, name, site, lon, lat) VALUES
      ('f-dup-01', 'Z.DUPLOSER01', 'Z', 150.9101, -33.9101)")

    DBI::dbExecute(con, "INSERT INTO feature_alias
      (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign, first_seen, last_seen, confirmed_by) VALUES
      ('fa-dup-selfA', 'f-dup-01', 'Z.DUPLOSER01', 'z.duploser01', 'self', 1, FALSE,
       TIMESTAMP '2020-01-01 00:00:00', TIMESTAMP '2020-01-01 00:00:00', NULL)")
    DBI::dbExecute(con, "INSERT INTO feature_alias
      (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign, first_seen, last_seen, confirmed_by) VALUES
      ('fa-dup-selfB', 'f-dup-01', 'Z.DUPLOSER01', 'z.duploser01', 'self', 1, FALSE,
       TIMESTAMP '2020-01-01 00:00:00', TIMESTAMP '2020-01-01 00:00:00', NULL)")
    DBI::dbExecute(con, "INSERT INTO feature_alias
      (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign, first_seen, last_seen, confirmed_by) VALUES
      ('fa-dup-loser', 'f-dup-01', 'Z.DUPLOSER01', 'z.duploser01', 'transcription_error', 1, TRUE,
       TIMESTAMP '2026-07-23 00:00:00', TIMESTAMP '2026-07-23 00:00:00', 'R. Shannon')")

    DBI::dbExecute(con, "INSERT INTO \"sample\"
      (uuid, uuid_feature_alias, date, datetime, organisation) VALUES
      ('s-dup-01', 'fa-dup-loser', TIMESTAMP '2026-06-01 00:00:00', TIMESTAMP '2026-06-01 09:00:00', 'ALS')")
    DBI::dbExecute(con, "INSERT INTO analysis (uuid, uuid_sample, value) VALUES
      ('an-dup-01', 's-dup-01', 3.3)")
  }

  list(path = path, con = seed_con(path))
}

test_that("Phase-7b item 4: merge_identity_aliases() de-dups on uuid_loser before the loop, so a loser shared by two self arms does not abort mid-way after the first iteration's writes committed", {
  setup <- fa_e8_dup_loser_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  expect_no_error(
    result <- merge_identity_aliases(actor = "phase7b-item4-test")
  )

  # exactly ONE itemised row - the duplicate uuid_loser is collapsed, not
  # reported (and re-processed) twice.
  expect_equal(nrow(result), 1)
  expect_identical(result$uuid_loser[[1]], "fa-dup-loser")
  expect_true(result$uuid_winner[[1]] %in% c("fa-dup-selfA", "fa-dup-selfB"))

  # the loser is gone, deleted exactly once.
  expect_equal(nrow(DBI::dbGetQuery(con, "SELECT * FROM feature_alias WHERE uuid = 'fa-dup-loser'")), 0)

  # exactly one of the two self arms received the merge (auto_assign TRUE,
  # confirmed_by carried over); the other is untouched.
  selves <- DBI::dbGetQuery(con,
    "SELECT uuid, auto_assign, confirmed_by FROM feature_alias WHERE uuid IN ('fa-dup-selfA', 'fa-dup-selfB')")
  expect_equal(nrow(selves), 2)
  n_merged <- sum(selves$auto_assign & !is.na(selves$confirmed_by))
  expect_equal(n_merged, 1)

  # the sample was re-pointed onto whichever self arm actually won.
  sample_row <- DBI::dbGetQuery(con, "SELECT uuid_feature_alias FROM \"sample\" WHERE uuid = 's-dup-01'")
  expect_identical(sample_row$uuid_feature_alias[[1]], result$uuid_winner[[1]])

  # Phase-7b round-2 item 7: the FK-dependent analysis on s-dup-01 - the
  # shape that drives .fa_guarded_update()'s detach/reattach dance for this
  # repoint - still points at the same sample afterwards.
  analysis_row <- DBI::dbGetQuery(con, "SELECT uuid_sample FROM analysis WHERE uuid = 'an-dup-01'")
  expect_identical(analysis_row$uuid_sample[[1]], "s-dup-01")
})

# ======================================================================
# PLAN-15 E.4 / R-15.18 - confirm_feature_aliases() gains date_start /
# date_end bound arguments: set, clear (explicit sentinel), leave-alone, and
# a bounds-only call with uuid_feature omitted.
#
# PCR-4 (RULED 2026-07-24, Phase-5 audit): the bounds sentinel scheme is now
# PINNED IN THE PLAN exactly as encoded below, no longer provisional -
# `NULL` (default/omitted) means leave-alone; an explicit `as.Date(NA)`
# means clear; a real `Date` means set.
# ======================================================================

test_that("R-15.18 (E.4): confirm_feature_aliases() SETS date_start on an unbounded alias, round-tripped as a real DATE (never POSIXct) via the driver", {
  setup <- fa_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign,
     first_seen, last_seen, confirmed_by) VALUES
    ('fa-9501', NULL, 'Z.SET01', 'z.set01', 'pending', 0, FALSE,
     TIMESTAMP '2025-09-01 08:00:00', TIMESTAMP '2025-09-01 08:00:00', NULL)")

  before <- feature_alias_row(con, "fa-9501")
  expect_true(is.na(before$date_start[[1]]))

  confirm_feature_aliases(
    "fa-9501", "f-0002", confirmed_by = "alice",
    date_start = as.Date("2025-09-01")
  )

  after <- feature_alias_row(con, "fa-9501")
  expect_s3_class(after$date_start[[1]], "Date") # DATE, never POSIXct/TIMESTAMP
  expect_equal(after$date_start[[1]], as.Date("2025-09-01"))
})

test_that("R-15.18 (E.4): confirm_feature_aliases() CLEARS an existing date_end via the explicit clear sentinel (as.Date(NA)), distinct from the leave-alone default", {
  setup <- fa_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign,
     first_seen, last_seen, confirmed_by, date_start, date_end) VALUES
    ('fa-9502', 'f-0002', 'Z.CLEAR01', 'z.clear01', 'historical_code', 0, TRUE,
     TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00', NULL,
     DATE '2025-01-01', DATE '2025-06-30')")

  before <- feature_alias_row(con, "fa-9502")
  expect_equal(before$date_end[[1]], as.Date("2025-06-30"))

  confirm_feature_aliases(
    "fa-9502", "f-0002", confirmed_by = "alice",
    date_end = as.Date(NA)
  )

  after <- feature_alias_row(con, "fa-9502")
  expect_true(is.na(after$date_end[[1]]))
  expect_equal(after$date_start[[1]], as.Date("2025-01-01")) # untouched by clearing date_end
})

test_that("R-15.18 (E.4): confirm_feature_aliases() LEAVES an existing date_start bound untouched when explicitly passed the leave-alone default (NULL) - a re-confirm must not silently wipe a bound", {
  setup <- fa_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign,
     first_seen, last_seen, confirmed_by, date_start) VALUES
    ('fa-9503', 'f-0002', 'Z.LEAVE01', 'z.leave01', 'historical_code', 0, TRUE,
     TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00', NULL,
     DATE '2024-01-01')")

  before <- feature_alias_row(con, "fa-9503")
  expect_equal(before$date_start[[1]], as.Date("2024-01-01"))

  confirm_feature_aliases(
    "fa-9503", "f-0002", confirmed_by = "alice",
    date_start = NULL
  )

  after <- feature_alias_row(con, "fa-9503")
  expect_equal(after$date_start[[1]], as.Date("2024-01-01")) # unchanged
  expect_identical(after$confirmed_by[[1]], "alice") # the rest of confirmation still happened
})

test_that("R-15.18 (E.4): a bounds-only call works with uuid_feature OMITTED - widens an existing alias's date_start without re-picking a feature, leaving uuid_feature untouched", {
  setup <- fa_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign,
     first_seen, last_seen, confirmed_by, date_start) VALUES
    ('fa-9504', 'f-0003', 'Z.BOUNDSONLY01', 'z.boundsonly01', 'historical_code', 0, TRUE,
     TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00', 'prior_op',
     DATE '2025-05-01')")

  before <- feature_alias_row(con, "fa-9504")
  expect_identical(before$uuid_feature[[1]], "f-0003")

  expect_no_error(
    confirm_feature_aliases(
      "fa-9504", confirmed_by = "alice", date_start = as.Date("2024-01-01")
    )
  )

  after <- feature_alias_row(con, "fa-9504")
  expect_identical(after$uuid_feature[[1]], "f-0003") # untouched - no feature re-pick
  expect_equal(after$date_start[[1]], as.Date("2024-01-01")) # bound widened
})

test_that("Phase-7b item 1: a bounds-only call on a row with auto_assign = FALSE (a curator veto on a non-'self' arm) does NOT flip auto_assign to TRUE or write confirmed_by - only the bound itself changes", {
  setup <- fa_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # fa-9506: a curated arm with the row already resolved (uuid_feature set)
  # but auto_assign FALSE and confirmed_by NULL - the per-row veto PLAN-15:574
  # pins on any non-'self' arm. The OLD bounds-only branch's
  # `changes = c(list(confirmed_by = confirmed_by, auto_assign = TRUE), bounds)`
  # is invisible against fa-9504 above (already auto_assign TRUE) but would
  # flip THIS row's veto and mark a still-dangling/vetoed arm as confirmed.
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign,
     first_seen, last_seen, confirmed_by, date_start) VALUES
    ('fa-9506', 'f-0003', 'Z.VETOBOUNDS01', 'z.vetobounds01', 'historical_code', 0, FALSE,
     TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00', NULL,
     DATE '2025-05-01')")

  before <- feature_alias_row(con, "fa-9506")
  expect_false(before$auto_assign[[1]])
  expect_true(is.na(before$confirmed_by[[1]]))

  confirm_feature_aliases(
    "fa-9506", confirmed_by = "alice", date_start = as.Date("2024-01-01")
  )

  after <- feature_alias_row(con, "fa-9506")
  expect_false(after$auto_assign[[1]]) # veto NOT silently un-vetoed
  expect_true(is.na(after$confirmed_by[[1]])) # NOT silently confirmed
  expect_equal(after$date_start[[1]], as.Date("2024-01-01")) # bound still widened
})

test_that("R-15.18 (E.4): confirm_feature_aliases() with BOTH date_start and date_end entirely OMITTED leaves BOTH bounds unchanged - the direct guard of the NULL-means-leave-alone half of the sentinel scheme (PCR-4)", {
  setup <- fa_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign,
     first_seen, last_seen, confirmed_by, date_start, date_end) VALUES
    ('fa-9505', 'f-0002', 'Z.OMITBOTH01', 'z.omitboth01', 'historical_code', 0, TRUE,
     TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00', NULL,
     DATE '2024-03-01', DATE '2024-09-30')")

  before <- feature_alias_row(con, "fa-9505")
  expect_equal(before$date_start[[1]], as.Date("2024-03-01"))
  expect_equal(before$date_end[[1]], as.Date("2024-09-30"))

  # date_start and date_end are ENTIRELY OMITTED from this call - not passed
  # as explicit NULL - the shape a real re-confirm call takes when the
  # caller has no opinion about bounds. This is the DIRECT guard of the
  # NULL-means-leave-alone half of the E.4 sentinel scheme (PCR-4): NULL
  # (default/omitted) = leave alone, as.Date(NA) = clear, a real Date = set.
  # PASSES TODAY because no bounds logic exists at all yet, so bounds
  # trivially survive - this is a legitimate regression guard, not a false
  # green (same shape as the R-15.12/R-15.13 guards the audit already
  # cleared), and becomes load-bearing the moment E.4 lands. Do not "clean
  # this up" - a single side-effect assertion elsewhere (the CLEAR test
  # above) is not enough coverage for an API contract Robin ratified this
  # week.
  confirm_feature_aliases("fa-9505", "f-0002", confirmed_by = "alice")

  after <- feature_alias_row(con, "fa-9505")
  expect_equal(after$date_start[[1]], as.Date("2024-03-01")) # unchanged
  expect_equal(after$date_end[[1]], as.Date("2024-09-30"))   # unchanged
})

# ======================================================================
# PLAN-15 F.14 / R-15.34 - confirm_analyte_methods() must succeed on a
# method that HAS dependent analyses (today it fails on any such method:
# duckdb 1.4.1 refuses an UPDATE of a chained-FK table's own outgoing-FK
# column - lab_method.uuid_analyte - while any analysis row still
# references it; see .mig002_detach_reason's own comment in
# dev/migrations/002-registry-remediation.R for the reference detach ->
# repoint -> reattach pattern the fix is expected to reuse).
#
# NOTE: helper-db.R's shared `seed_db()`/`fa_setup()` DDL declares NO
# foreign keys at all (verified: no REFERENCES/FOREIGN KEY anywhere in
# .st_test_core_ddl), so it CANNOT reproduce this defect - any test built on
# it would pass today regardless of the bug (false green). This test
# instead builds its own minimal, self-contained FK-constrained DB (the
# smallest two-hop chain that reproduces it: analyte <- lab_method <-
# analysis, mirroring the live shape at
# dev/migrations/001-alias-indirection.R:456-499), reusing `ensure_schema()`
# for the ops tables rather than re-deriving them. Empirically verified
# (scratch repro) that duckdb 1.4.1 raises "Constraint Error: ... still
# referenced by a foreign key in a different table" on this exact shape,
# even wrapped in one transaction.
# ======================================================================

#' Build a minimal, self-contained FK-constrained DB reproducing the real
#' analyte <- lab_method <- analysis foreign-key chain (R-15.34 / F.14).
#' Cleanup (tempdir, option) bound to the CALLING TEST's frame, not this
#' helper's own frame (the withr wrong-frame trap, language-footguns.md).
fa_fk_setup <- function() {
  env <- parent.frame()
  dir <- withr::local_tempdir(.local_envir = env)
  path <- file.path(dir, "fk-seed.duckdb")
  withr::local_options(list("sampletidy.live_db" = path), .local_envir = env)

  # ---- seed, then close the seeding connection (mirrors seed_db()'s own
  # on.exit-scoped-to-itself pattern in helper-db.R) ----
  {
    con <- DBI::dbConnect(duckdb::duckdb(), path, read_only = FALSE)
    on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

    ensure_schema(con) # review_queue/change_log/schema_version - reused, not re-derived

    DBI::dbExecute(con, "CREATE TABLE analyte (
      uuid VARCHAR PRIMARY KEY, name VARCHAR, units VARCHAR,
      conversion_constant DOUBLE, type VARCHAR, CAS VARCHAR)")
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

    # a-9401/lm-9401: same units on both sides (identity conversion, keeps
    # this test scoped to the FK/repoint behaviour, not unit conversion
    # math - that is already covered by R-11.11's own tests). lm-9401 is
    # DANGLING (uuid_analyte NULL) with TWO dependent analyses, so both the
    # FK-chain defect and the "every dependent analysis still points at the
    # same lab_method" assertion are exercised.
    DBI::dbExecute(con, "INSERT INTO analyte (uuid, name, units, type, CAS) VALUES
      ('a-9401', 'FK Analyte', 'mg/L', 'anion', NULL)")
    DBI::dbExecute(con, "INSERT INTO lab_method
      (uuid, uuid_analyte, name, method, organisation, rl_low, units) VALUES
      ('lm-9401', NULL, 'FK Method', 'M-FK', 'ALS', 0.1, 'mg/L')")
    DBI::dbExecute(con, "INSERT INTO analysis
      (uuid, uuid_sample, uuid_lab, value, quantified, rl_low) VALUES
      ('an-9401', 's-9401-nofk', 'lm-9401', 5, TRUE, 0.1),
      ('an-9402', 's-9402-nofk', 'lm-9401', 6, TRUE, 0.1)")
  }

  list(path = path, con = seed_con(path))
}

test_that("R-15.34: confirm_analyte_methods() succeeds on a method WITH dependent analyses (real FK chain: analyte <- lab_method <- analysis) - lab_method.uuid_analyte moves AND every dependent analysis still points at the same lab_method", {
  setup <- fa_fk_setup()
  con <- setup$con
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  before_lab <- DBI::dbGetQuery(con, "SELECT uuid_analyte FROM lab_method WHERE uuid = 'lm-9401'")
  expect_true(is.na(before_lab$uuid_analyte[[1]]))
  before_deps <- DBI::dbGetQuery(con, "SELECT uuid FROM analysis WHERE uuid_lab = 'lm-9401'")
  expect_equal(nrow(before_deps), 2) # a method WITH dependent analyses, not the zero-referenced case

  expect_no_error(
    confirm_analyte_methods("lm-9401", "a-9401", confirmed_by = "alice")
  )

  after_lab <- DBI::dbGetQuery(con, "SELECT uuid_analyte FROM lab_method WHERE uuid = 'lm-9401'")
  expect_identical(after_lab$uuid_analyte[[1]], "a-9401") # moved

  after_deps <- DBI::dbGetQuery(con, "SELECT uuid, uuid_lab FROM analysis WHERE uuid IN ('an-9401', 'an-9402') ORDER BY uuid")
  expect_equal(nrow(after_deps), 2) # neither orphaned nor deleted
  expect_true(all(after_deps$uuid_lab == "lm-9401")) # every dependent analysis still points at the SAME lab_method
})

test_that("R-11.10/R-11.11/E.8 (A55): the mandatory actor argument carries NO default value in any producer's real parsed signature", {
  # Assert on the real parsed signature via formals() rather than a source
  # regex: a regex capturing `([^)]*)` cannot cross a `)`, so it truncates at
  # the first close-paren inside the argument list (e.g. a `db = st_config()`
  # or a future `date_start = as.Date(NA)` default) and silently stops
  # checking every argument after that point - an argument-order-dependent
  # guard, which is the defect this replaces (phase5-delta-to-apply-r5.md A1).
  #
  # Phase-7b round-3 A12 (CONFIRMED-BY-ORCH, mutation A-M10-GAP SURVIVED):
  # this loop used to cover only the two `confirm_*` functions, so giving
  # `merge_identity_aliases()`'s own mandatory `actor` (PLAN-15 B-15.E8,
  # docstring `:1124-1126`) a default would survive the whole suite - added
  # here, keyed to its own argument name (`actor`, not `confirmed_by`).
  producers <- list(
    list(fn = confirm_feature_aliases, arg = "confirmed_by"),
    list(fn = confirm_analyte_methods, arg = "confirmed_by"),
    list(fn = merge_identity_aliases, arg = "actor")
  )
  for (p in producers) {
    expect_true(is.function(p$fn))
    expect_true(p$arg %in% names(formals(p$fn)))
    expect_true(identical(formals(p$fn)[[p$arg]], quote(expr = )))
  }
})
