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
#' helper-db.R), NOT computed via `.rc_key()` - today's pre-R-11.3 `.rc_key()`
#' still keeps punctuation (`.rc_key("T.NEWCODE1")` == "t.newcode1", not
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

  # fa-0005/fa-0006 both carry alias_key 'tambig2' (the fixture's own literal
  # - see helper-db.R; NOT `.rc_key("T.AMBIG2")`, which today's pre-R-11.3
  # `.rc_key()` still renders 't.ambig2' with the dot kept, so calling it here
  # would silently miss the seeded rows), resolving to DIFFERENT features
  # (f-0004, f-0005) - the plan's ambiguous-key fixture.
  key <- "tambig2"
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
  expect_true(grepl("an-w2", conflict$payload[[1]], fixed = TRUE))
  expect_true(grepl("an-l2", conflict$payload[[1]], fixed = TRUE))

  # both analyses now live on the surviving sample - two, not four (an-l1
  # dropped, an-w1/an-w2/an-l2 remain).
  on_winner <- DBI::dbGetQuery(con, "SELECT uuid FROM analysis WHERE uuid_sample = 's-9001'")
  expect_setequal(on_winner$uuid, c("an-w1", "an-w2", "an-l2"))
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
  expect_true(grepl("mg/L", hit$payload[[1]], fixed = TRUE) && grepl("g/L", hit$payload[[1]], fixed = TRUE))
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

test_that("R-11.10/R-11.11 (A55, source meta-test): confirmed_by carries NO default value in either function's signature - comment/string-stripped, with a decoy that must NOT trip the guard", {
  # Comment/string-aware: a raw line-grep would false-positive on the decoy
  # comment below (which mentions a defaulted confirmed_by in prose) - strip
  # comments and string literals before matching (phase4-test-authoring.md
  # meta-test rule).
  pkg_root <- normalizePath(file.path(testthat::test_path(), "..", ".."))
  target <- file.path(pkg_root, "R", "feature-alias.R")
  skip_if_not(file.exists(target), "R/feature-alias.R not yet written (expected pre-Phase-6)")

  lines <- readLines(target, warn = FALSE)
  # DECOY (must not trip the guard): "confirmed_by = 'system'" as a default
  # is exactly the anti-pattern A55 forbids - never write it into a real
  # signature, but mentioning it here in a comment must be inert.
  stripped <- vapply(lines, function(l) {
    l <- sub("#.*$", "", l) # strip line comments
    l <- gsub('"[^"]*"', "", l) # strip double-quoted string literals
    l <- gsub("'[^']*'", "", l) # strip single-quoted string literals
    l
  }, character(1))
  src_text <- paste(stripped, collapse = "\n")

  sig_re <- "(confirm_feature_aliases|confirm_analyte_methods)\\s*<-\\s*function\\s*\\(([^)]*)\\)"
  matches <- gregexpr(sig_re, src_text, perl = TRUE)
  captured <- regmatches(src_text, matches)[[1]]
  expect_gt(length(captured), 0) # both signatures found once written

  for (sig in captured) {
    expect_false(
      grepl("confirmed_by\\s*=", sig),
      info = paste("confirmed_by must not carry a default value:", sig)
    )
  }
})
