# Operator-run migration: apply Robin's 2026-08-08 ruling 9 - "there should
# never be two samples at the same feature at the same datetime; fix the
# existing data".
#
# Investigating that ruling (scratchpad/dup_*.R, scratchpad/r008_*.R) found the
# 13 offending (feature, datetime) groups are TWO UNRELATED ERRORS, and that one
# fix applied to both would destroy real data. So this migration does two
# different things, and REFUSES to guess which case a group belongs to.
#
# ---- (1) DELETE five duplicate field-reading samples ----
#
# Site L, 2024-11-28, features L.L01 / L.L02 / L.MW06 / L.MW07 / L.MW08. Each
# holds exactly two samples: a big one keyed by its ALS sample number
# (ES2439045001..005, 67-143 analyses, person `S. Carter`) and a small one keyed
# by a random uuid (2-3 analyses, person `L. Pyne`). The small one carries only
# field readings - Standing water level, Temperature, pH - and every one of its
# 13 analyses is ALREADY on the big sample with the same lab_method, analyte and
# value. It is a second load of the same field data, not a second sample.
#
# The precondition below re-proves that twin-by-twin at run time rather than
# trusting this note, and refuses the whole migration if even one analysis on a
# sample marked for deletion is not already present on its partner. That is what
# makes it safe to name these rows at all.
#
# WHAT IS LOST: the `person = 'L. Pyne'` attribution on those five rows (the
# survivors say `S. Carter`). That is recorded here, in the deletion `reason`
# and therefore in `change_log`, because it is the one fact the delete destroys
# that is not duplicated elsewhere.
#
# ---- (2) REASSIGN 27 Lawson STP samples from B.L01 to B.L05 ----
#
# The other eight groups are at B.L01, Feb-Mar 2026, and are NOT duplicates.
# They are different physical samples - pH 7.95-8.20, BOD 192-583, EC 3070-3920
# across the 13 samples on 2026-03-04 - each submitted as its own ALS work
# order. Merging them would discard 686 distinct measurements at a licensed
# discharge point, 149 of them outright value conflicts.
#
# The real error is the FEATURE. Of the 103 samples filed on a B.L01 alias, the
# lab's own `Client sample ID` splits them 27 `Discharge Point - Lawson STP` /
# 27 `Trade Waste Dam` / 1 `T/W Pump` / 48 with no XTAB in the archive. BOTH of
# the first two are confirmed feature aliases in the database, confirmed_by
# R. Shannon - and `Discharge Point - Lawson STP` points at B.L05, which
# currently holds ZERO samples. So the reassignment is documentary rather than
# interpretive, and it un-breaks a feature that reads as unmonitored today.
#
# ROBIN'S RULING SAID "the family b ones", i.e. the 24 samples that COLLIDE.
# This migration moves 27: the same error also affects three 2025-05-24 samples
# and one 2026-02-27 sample that happen not to collide with a sibling. Leaving a
# misfiled sample in place because it did not happen to clash would give B.L05 a
# partial history and leave B.L01 holding another feature's data. The extra
# three are listed in the CSV like every other row and can simply be deleted
# from it if that reading is wrong.
#
# ---- WHAT THIS MIGRATION DOES NOT DO, AND WHY IT CANNOT ----
#
# IT DOES NOT MAKE (feature, datetime) UNIQUE, and no migration can. Simulated
# against the live database (scratchpad/r008_postfix.R): after BOTH steps above,
# 14 groups holding 44 samples still share a (feature, datetime) key - 7 at
# B.L01 and 7 at B.L05. In every one of those 14 groups, every sample comes from
# a DISTINCT ALS work order (44 samples, 44 work orders, no exceptions). They
# are genuinely different field samples taken at one discharge point on one day
# during a discharge event, all stamped 00:00 because the XTAB format has no
# time field. Their real times do not exist anywhere: `datetime_start` is
# identical, `change_log` has no rows for them, and only 1 of the 47 work orders
# has a chain-of-custody scan with a time filled in.
#
# So Robin's invariant is right about intent and unenforceable as literally
# stated. Enforcing UNIQUE (feature, datetime) would require inventing 44 clock
# times. See dev/plans/CONTRACT.md A84 and the import-side guard in
# `.ct_existing_sample_uuid()`, which is where the "quarantine incoming data"
# half of the ruling lives.
#
# ---- THE FK PRE-PASS (BOTH rulings) ----
# duckdb will not let a `sample` row be touched while any `analysis` references
# it. Measured here, not assumed - both halves were found by running this
# migration against a copy of the live database:
#
#   * DELETE: removing all of a sample's analyses and then the sample INSIDE ONE
#     `db_transaction()` still raises "Violates foreign key constraint because
#     key uuid_sample: 2e97029a... is still referenced by a foreign key in a
#     different table". The FK index does not see the uncommitted deletes.
#   * UPDATE: a plain `UPDATE sample SET uuid_feature_alias = ? WHERE uuid = ?`
#     raises the same error - on a column that is not part of any key. duckdb
#     treats an update of a referenced row as delete+insert.
#
# Same F.14 limitation 007 hit on `lab_method.uuid_analyte`, and the same
# remedy: statements that COMMIT SEPARATELY, run before the main transaction.
# Ruling (1) deletes the analyses first and then the sample; ruling (2) detaches
# the analyses (`uuid_sample` NULL - the column is nullable, only `analysis.uuid`
# is NOT NULL), moves the sample, and reattaches them.
#
# There is no "did they all come back" count inside that loop, deliberately -
# it would be unreachable, and the note at `.mig008_reassign_sample()` explains
# why. The property is checked one level up, by `mig008_verify()`, through
# `v_measurement`: a row left detached drops out of that view's INNER JOIN.
#
# THE COST: the backup is taken first, so the failure window is recoverable by
# restore, but it IS a window. If the main transaction fails, the deletes and
# moves have happened and the marker has not; the operator restores from the
# printed backup path rather than trying to unpick it. `counts_before` is
# captured BEFORE the pre-pass, so the safety gate still measures everything the
# pre-pass did and cannot be fooled by it.
#
# ---- ORDERING ----
# INDEPENDENT of 005, 006 and 007. Those three write `analyte` / `lab_method`
# and rebuild views; this one writes `sample` and `analysis` and creates no
# registry rows. It can run before or after any of them.
#
# NEVER invoked by package code (A50). Run it from a session where the package
# was loaded with `devtools::load_all(".")`.
#
#   devtools::load_all(".")
#   env <- new.env()
#   sys.source("dev/migrations/008-duplicate-samples.R", envir = env)
#   env$mig008_run(db = st_config("live_db"),
#                  snapshot_dir = st_config("snapshot_dir"),
#                  reassign = "dev/migrations/008-duplicate-samples-REASSIGN.csv",
#                  dry_run = TRUE)

.mig008_marker_version <- 1008L
.mig008_actor <- "008-duplicate-samples"

.mig008_default <- function(x, default) if (is.null(x)) default else x

# ---- ruling (1), declaratively ----------------------------------------------
# Named by NATURAL KEY - feature name, calendar date, and the `person` that
# tells the two rows apart - never by uuid. A uuid here would be unreviewable,
# and worse, would let the migration delete the wrong row silently if the
# database moved. Everything else about the pair is PROVED at run time.

.mig008_dup_date <- "2024-11-28"
.mig008_dup_loser_person <- "L. Pyne"
.mig008_dup_winner_person <- "S. Carter"
.mig008_dup_features <- c("L.L01", "L.L02", "L.MW06", "L.MW07", "L.MW08")

# A sample marked for deletion may carry no more than this many analyses. Not
# decoration: it bounds the blast radius of a mis-identified pair to something a
# human would notice, and the twin proof below is what actually authorises the
# delete.
.mig008_dup_max_analyses <- 3L

# ---- ruling (2), declaratively ----------------------------------------------
.mig008_from_feature <- "B.L01"
.mig008_to_feature <- "B.L05"
.mig008_to_alias <- "Discharge Point - Lawson STP"
.mig008_reassign_cols <- c("uuid_sample", "client_sample_id")

#' Guard: this migration is run from a `devtools::load_all(".")` session
#' @keywords internal
#' @noRd
.mig008_require_internals <- function() {
  needed <- c("st_connect", "with_db_write", "db_transaction", "db_delete", "db_update")
  missing <- needed[!vapply(needed, exists, logical(1), mode = "function")]
  if (length(missing) > 0) {
    cli::cli_abort(
      "008-duplicate-samples: {paste(missing, collapse = ', ')} {?is/are} not
       visible. Run this from a session where the package was loaded with
       {.code devtools::load_all(\".\")} - see the file header.",
      class = "sampletidy_error"
    )
  }
  invisible(TRUE)
}

# ---- the reassignment list --------------------------------------------------

#' Read and structurally validate the reassignment list
#'
#' Accepts a path to a CSV or an already-built data frame. Structure only -
#' anything needing the database is `.mig008_check_preconditions()`'s job.
#' @keywords internal
#' @noRd
.mig008_read_reassign <- function(reassign) {
  df <- if (is.data.frame(reassign)) {
    reassign
  } else {
    if (!(is.character(reassign) && length(reassign) == 1L && !is.na(reassign))) {
      cli::cli_abort(
        "008-duplicate-samples: `reassign` must be a data frame or a path to a
         CSV, not {.cls {class(reassign)}} of length {length(reassign)}.",
        class = "sampletidy_error"
      )
    }
    if (!file.exists(reassign)) {
      cli::cli_abort("008-duplicate-samples: reassignment file not found: {reassign}.",
                     class = "sampletidy_error")
    }
    utils::read.csv(reassign, stringsAsFactors = FALSE, encoding = "UTF-8",
                    colClasses = "character", na.strings = character(0))
  }

  missing_cols <- setdiff(.mig008_reassign_cols, names(df))
  if (length(missing_cols) > 0) {
    cli::cli_abort(
      "008-duplicate-samples: reassignment list is missing required column(s)
       {paste(missing_cols, collapse = ', ')}.",
      class = "sampletidy_error"
    )
  }

  # NON-VACUITY. An empty list would sail through every check below, move
  # nothing, and report success - indistinguishable from a list that failed to
  # load. Same gate, same reason, as 006's.
  if (nrow(df) == 0) {
    cli::cli_abort(
      "008-duplicate-samples: the reassignment list is EMPTY. Refusing rather
       than reporting success for doing nothing.",
      class = "sampletidy_error"
    )
  }

  for (col in .mig008_reassign_cols) {
    v <- df[[col]]
    if (any(is.na(v) | !nzchar(trimws(v)))) {
      cli::cli_abort(
        "008-duplicate-samples: reassignment column `{col}` is blank on row(s)
         {paste(utils::head(which(is.na(v) | !nzchar(trimws(v))), 5), collapse = ', ')}.",
        class = "sampletidy_error"
      )
    }
  }

  dup <- duplicated(df$uuid_sample)
  if (any(dup)) {
    cli::cli_abort(
      "008-duplicate-samples: duplicate sample(s) in the reassignment list:
       {paste(unique(df$uuid_sample[dup]), collapse = ', ')}.",
      class = "sampletidy_error"
    )
  }

  # The `client_sample_id` column is the EVIDENCE, and checking it is what stops
  # this list quietly becoming a hand-written set of uuids. Every row must name
  # the destination in the lab's own words. The match is deliberately loose on
  # case and internal spacing, because one of the 27 XTABs really does say
  # "Discharge point- lawson STP" - a lab typo, not a different place - while
  # still refusing anything that is not this destination.
  fold <- function(x) gsub("[^a-z0-9]+", "", tolower(x))
  wrong <- fold(df$client_sample_id) != fold(.mig008_to_alias)
  if (any(wrong)) {
    i <- which(wrong)[[1]]
    cli::cli_abort(
      "008-duplicate-samples: {sum(wrong)} reassignment row(s) carry a
       `client_sample_id` that is not {sQuote(.mig008_to_alias)} - e.g.
       {sQuote(df$uuid_sample[i])} says {sQuote(df$client_sample_id[i])}. That
       column is the evidence for the move; a row that does not carry it is a
       bare uuid nobody reviewed.",
      class = "sampletidy_error"
    )
  }

  df
}

# ---- preconditions ----------------------------------------------------------

#' The two samples at one (feature, `.mig008_dup_date`) group
#'
#' Returns a list(loser, winner) of uuids, or throws. Split out so the delete
#' and the verify ask the same question the same way.
#' @keywords internal
#' @noRd
.mig008_dup_pair <- function(con, feature) {
  rows <- DBI::dbGetQuery(
    con,
    'SELECT s.uuid, s.person,
            (SELECT COUNT(*) FROM analysis a WHERE a.uuid_sample = s.uuid) AS n_an
       FROM "sample" s
       JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
       JOIN feature f        ON f.uuid = fa.uuid_feature
      WHERE f.name = ? AND CAST(s.datetime AS DATE) = CAST(? AS DATE)
      ORDER BY s.uuid',
    params = list(feature, .mig008_dup_date)
  )
  # `on` rather than `{.mig008_dup_date}`: see the cli dot-literal note below.
  on <- .mig008_dup_date
  if (nrow(rows) != 2L) {
    cli::cli_abort(
      "008-duplicate-samples ruling (1): feature {sQuote(feature)} holds
       {nrow(rows)} sample(s) at {on}, not the 2 this ruling
       assumes. Refusing - the data moved since the ruling was made.",
      class = "sampletidy_error"
    )
  }
  lo <- rows[!is.na(rows$person) & rows$person == .mig008_dup_loser_person, , drop = FALSE]
  wi <- rows[!is.na(rows$person) & rows$person == .mig008_dup_winner_person, , drop = FALSE]
  if (nrow(lo) != 1L || nrow(wi) != 1L) {
    cli::cli_abort(
      "008-duplicate-samples ruling (1): feature {sQuote(feature)} at
       {on} does not hold exactly one {sQuote(.mig008_dup_loser_person)}
       sample and one {sQuote(.mig008_dup_winner_person)} sample (got
       {nrow(lo)} and {nrow(wi)}). `person` is the key that tells the pair
       apart, so this migration cannot proceed without it.",
      class = "sampletidy_error"
    )
  }
  # Bound to a local because cli reads a `{}` expression STARTING WITH A DOT as
  # a style name, not a value (cli >= 3.4.0), so `{.mig008_dup_max_analyses}`
  # aborts with an rlib_error about an invalid cli literal instead of this
  # gate's promised `sampletidy_error`. Third time this trap has been sprung
  # across 006/007/008; the tests have caught it every time.
  bound <- .mig008_dup_max_analyses
  if (lo$n_an[[1]] > bound) {
    cli::cli_abort(
      "008-duplicate-samples ruling (1): the {sQuote(.mig008_dup_loser_person)}
       sample at {sQuote(feature)} carries {lo$n_an[[1]]} analyses, more than the
       {bound} this ruling bounds a duplicate field-reading load at. Refusing.",
      class = "sampletidy_error"
    )
  }
  list(loser = lo$uuid[[1]], winner = wi$uuid[[1]], n_loser = as.integer(lo$n_an[[1]]),
       n_winner = as.integer(wi$n_an[[1]]))
}

#' Every analysis on `loser` must already exist on `winner`, same method, same
#' analyte, same value.
#'
#' THIS is the check that authorises the delete. It is asked against the rows
#' themselves, not against a count, because two samples can have equal analysis
#' counts and completely different content.
#' @keywords internal
#' @noRd
.mig008_twin_check <- function(con, feature, loser, winner) {
  det <- function(u) DBI::dbGetQuery(
    con,
    'SELECT lm.uuid AS uuid_lab, lm.name AS lab_name, a.value, a.value_chr,
            a.quantified, a.rl_low, a.rl_high
       FROM analysis a JOIN lab_method lm ON lm.uuid = a.uuid_lab
      WHERE a.uuid_sample = ? ORDER BY lm.uuid',
    params = list(u)
  )
  L <- det(loser)
  W <- det(winner)
  if (nrow(L) == 0L) {
    cli::cli_abort(
      "008-duplicate-samples ruling (1): the sample marked for deletion at
       {sQuote(feature)} carries NO analyses. That is not the shape this ruling
       was made about, so it is refused rather than deleted as a freebie.",
      class = "sampletidy_error"
    )
  }
  key <- function(d) paste(d$uuid_lab, d$value, d$value_chr, d$quantified,
                           d$rl_low, d$rl_high, sep = "\r")
  orphan <- !(key(L) %in% key(W))
  if (any(orphan)) {
    cli::cli_abort(
      "008-duplicate-samples ruling (1): {sum(orphan)} of {nrow(L)} analyses on
       the {sQuote(feature)} sample marked for deletion are NOT already present
       on its partner - e.g. {sQuote(L$lab_name[which(orphan)[[1]]])} =
       {L$value[which(orphan)[[1]]]}. Deleting would lose a real measurement.
       Refusing.",
      class = "sampletidy_error"
    )
  }
  invisible(nrow(L))
}

#' Ruling (1) as a pre-pass: delete one duplicate sample and its analyses
#'
#' MUST be called with `con` OUTSIDE any open transaction, so each `db_delete()`
#' commits on its own - see the FK note in the file header. Re-proves the pair
#' and the twin property immediately before deleting, so the proof and the
#' delete cannot drift apart.
#'
#' @return the number of `analysis` rows deleted.
#' @keywords internal
#' @noRd
.mig008_delete_duplicate <- function(con, feature) {
  p <- .mig008_dup_pair(con, feature)
  .mig008_twin_check(con, feature, p$loser, p$winner)

  kids <- DBI::dbGetQuery(
    con, "SELECT uuid FROM analysis WHERE uuid_sample = ? ORDER BY uuid",
    params = list(p$loser))$uuid
  for (k in kids) {
    db_delete(con, "analysis", uuid = k, actor = .mig008_actor,
              reason = sprintf(
                "008 ruling (1): duplicate field reading at %s %s - twin already on sample %s",
                feature, .mig008_dup_date, p$winner))
  }
  db_delete(con, "sample", uuid = p$loser, actor = .mig008_actor,
            reason = sprintf(
              "008 ruling (1): second load of the %s %s field readings (person '%s'); every analysis was an exact twin on sample %s (person '%s'), which survives",
              feature, .mig008_dup_date, .mig008_dup_loser_person, p$winner,
              .mig008_dup_winner_person))
  list(n_analyses = length(kids), pair = p)
}

#' Ruling (2) as a pre-pass: move one sample onto another alias
#'
#' MUST be called with `con` OUTSIDE any open transaction - see the FK note in
#' the file header. Detach -> move -> reattach.
#'
#' @return the number of `analysis` rows detached and restored.
#' @keywords internal
#' @noRd
.mig008_reassign_sample <- function(con, uuid_sample, dest_alias, reason) {
  kids <- DBI::dbGetQuery(
    con, "SELECT uuid FROM analysis WHERE uuid_sample = ? ORDER BY uuid",
    params = list(uuid_sample))$uuid

  for (k in kids) {
    db_update(con, "analysis", uuid = k, changes = list(uuid_sample = NA_character_),
              actor = .mig008_actor, reason = paste(reason, "(FK detach)"))
  }
  db_update(con, "sample", uuid = uuid_sample,
            changes = list(uuid_feature_alias = dest_alias),
            actor = .mig008_actor, reason = reason)
  for (k in kids) {
    db_update(con, "analysis", uuid = k, changes = list(uuid_sample = uuid_sample),
              actor = .mig008_actor, reason = paste(reason, "(FK reattach)"))
  }

  # THERE IS DELIBERATELY NO "did they all come back" COUNT HERE, and the reason
  # is worth recording because writing one is the obvious next move - the first
  # draft did. It would be UNREACHABLE. `db_update()` aborts with
  # `sampletidy_error` when its key matches no row (A72), and it writes whenever
  # the value differs - which on a reattach it always does, NA -> a uuid. So
  # every iteration above either wrote or threw, and a count taken here can only
  # ever agree. Mutation testing confirmed it: neutering the check killed no
  # test, because no fixture can reach its failing branch.
  #
  # The property it was reaching for IS checked, one level up and by a mechanism
  # that shares nothing with this loop: `mig008_verify()` asserts that
  # `v_measurement` - which INNER JOINs analysis to sample - lost exactly the
  # rows ruling (1) deleted. An analysis left detached would drop out of that
  # view and the count would be wrong. (Same shape as 006's deleted
  # "label already resolves" gate: a gate whose failing case cannot be reached
  # passes vacuously and reads as protection that is not there.)
  length(kids)
}

#' Resolve a feature name to exactly one uuid
#' @keywords internal
#' @noRd
.mig008_one_feature <- function(con, name) {
  hit <- DBI::dbGetQuery(con, "SELECT uuid FROM feature WHERE name = ?", params = list(name))
  if (nrow(hit) != 1L) {
    cli::cli_abort(
      "008-duplicate-samples: feature {sQuote(name)} matches {nrow(hit)} rows, not exactly 1.",
      class = "sampletidy_error"
    )
  }
  hit$uuid[[1]]
}

#' Resolve the destination alias, and prove it points where the ruling says
#' @keywords internal
#' @noRd
.mig008_dest_alias <- function(con) {
  hit <- DBI::dbGetQuery(
    con,
    "SELECT fa.uuid, fa.confirmed_by, f.name AS feature
       FROM feature_alias fa JOIN feature f ON f.uuid = fa.uuid_feature
      WHERE fa.name = ?",
    params = list(.mig008_to_alias)
  )
  if (nrow(hit) != 1L) {
    cli::cli_abort(
      "008-duplicate-samples ruling (2): alias {sQuote(.mig008_to_alias)} matches
       {nrow(hit)} feature_alias rows, not exactly 1.",
      class = "sampletidy_error"
    )
  }
  if (!identical(hit$feature[[1]], .mig008_to_feature)) {
    cli::cli_abort(
      "008-duplicate-samples ruling (2): alias {sQuote(.mig008_to_alias)} points at
       feature {sQuote(hit$feature[[1]])}, not {sQuote(.mig008_to_feature)}.
       The whole ruling rests on that link; refusing.",
      class = "sampletidy_error"
    )
  }
  # The ruling's evidence is that Robin confirmed this alias BY HAND. An
  # unconfirmed alias is a guess the importer made, and moving 27 samples onto
  # a guess is exactly what this migration is fixing.
  if (is.na(hit$confirmed_by[[1]]) || !nzchar(hit$confirmed_by[[1]])) {
    cli::cli_abort(
      "008-duplicate-samples ruling (2): alias {sQuote(.mig008_to_alias)} is not
       confirmed (`confirmed_by` is empty). This move rests on it being a
       human-confirmed alias, not an inferred one.",
      class = "sampletidy_error"
    )
  }
  hit$uuid[[1]]
}

#' Ruling (1)'s preconditions
#'
#' Split from ruling (2)'s because the FK pre-pass makes them true at DIFFERENT
#' moments: once ruling (1) has run, these checks are supposed to fail (the pair
#' is gone), so the in-transaction re-check must ask ruling (2)'s alone.
#' @keywords internal
#' @noRd
.mig008_check_preconditions_dup <- function(con) {
  for (ft in .mig008_dup_features) {
    p <- .mig008_dup_pair(con, ft)
    .mig008_twin_check(con, ft, p$loser, p$winner)
  }
  invisible(TRUE)
}

#' The destination feature must be as VISIBLE as the source in every reporting
#' view, or the move silently hides data
#'
#' FOUND BY REHEARSAL, not by reading. Run against a copy of the live database
#' the reassignment dropped 522 measurements out of BOTH `v_measurement_epa` and
#' `v_measurement_long`. Both views INNER JOIN `feature_mask` on a variant;
#' B.L01 carries an EPA mask named "21" and a `long` mask named "Main dam", and
#' B.L05 carries NO mask rows at all. So moving the samples would have taken 522
#' measurements at a discharge point out of the EPA reporting view without one
#' word of warning, in the middle of the licence-13089 return window.
#'
#' Whether that is WRONG is Robin's call and not this migration's: if the Lawson
#' STP tanker discharge is a Sydney Water trade-waste point rather than an EPA
#' licensed discharge point, then dropping out of the EPA view is CORRECT and
#' B.L01 has been inflating EPA point 21 with it. Either way the migration must
#' not decide silently, so it refuses until B.L05 carries a deliberate answer.
#' @keywords internal
#' @noRd
.mig008_check_dest_masks <- function(con) {
  m <- DBI::dbGetQuery(
    con,
    "SELECT f.name AS feature, fm.variant, fm.name
       FROM feature_mask fm JOIN feature f ON f.uuid = fm.uuid_feature
      WHERE f.name IN (?, ?)",
    params = list(.mig008_from_feature, .mig008_to_feature)
  )
  src <- sort(unique(m$variant[m$feature == .mig008_from_feature]))
  dst <- sort(unique(m$variant[m$feature == .mig008_to_feature]))
  missing <- setdiff(src, dst)
  if (length(missing) > 0) {
    have <- m[m$feature == .mig008_from_feature & m$variant %in% missing, , drop = FALSE]
    cli::cli_abort(
      "008-duplicate-samples ruling (2): {sQuote(.mig008_to_feature)} has no
       feature_mask row for variant(s) {paste(sQuote(missing), collapse = ', ')},
       which {sQuote(.mig008_from_feature)} does have
       ({paste(sprintf('%s = %s', have$variant, sQuote(have$name)), collapse = '; ')}).
       Those views INNER JOIN feature_mask, so moving the samples would delete
       them from the report rather than move them. Add the destination's mask
       rows first - and decide deliberately whether the Lawson STP tanker
       discharge belongs in the EPA return at all.",
      class = "sampletidy_error"
    )
  }
  invisible(TRUE)
}

#' Ruling (2)'s preconditions - re-checkable at any point before the UPDATE
#' @keywords internal
#' @noRd
.mig008_check_preconditions_reassign <- function(con, reassign) {
  dest <- .mig008_dest_alias(con)
  .mig008_check_dest_masks(con)
  from_uuid <- .mig008_one_feature(con, .mig008_from_feature)

  got <- DBI::dbGetQuery(
    con,
    sprintf(
      'SELECT s.uuid, f.name AS feature, f.uuid AS uuid_feature
         FROM "sample" s
         JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
         JOIN feature f        ON f.uuid = fa.uuid_feature
        WHERE s.uuid IN (%s)',
      paste(rep("?", nrow(reassign)), collapse = ", ")
    ),
    params = as.list(reassign$uuid_sample)
  )
  gone <- setdiff(reassign$uuid_sample, got$uuid)
  if (length(gone) > 0) {
    cli::cli_abort(
      "008-duplicate-samples ruling (2): {length(gone)} listed sample(s) do not
       exist - e.g. {paste(sQuote(utils::head(gone, 3)), collapse = ', ')}.",
      class = "sampletidy_error"
    )
  }
  wrong <- got[got$uuid_feature != from_uuid, , drop = FALSE]
  if (nrow(wrong) > 0) {
    cli::cli_abort(
      "008-duplicate-samples ruling (2): {nrow(wrong)} listed sample(s) are not
       on feature {sQuote(.mig008_from_feature)} - e.g. {sQuote(wrong$uuid[[1]])}
       is on {sQuote(wrong$feature[[1]])}. Either they have already been moved or
       the list is wrong; refusing either way.",
      class = "sampletidy_error"
    )
  }
  invisible(TRUE)
}

#' Both rulings' preconditions, for the dry run and the pre-backup gate
#' @keywords internal
#' @noRd
.mig008_check_preconditions <- function(con, reassign) {
  .mig008_check_preconditions_dup(con)
  .mig008_check_preconditions_reassign(con, reassign)
}

# ---- verify: the SAFETY half ------------------------------------------------

#' Row counts + a content checksum over every table, discovered from the
#' database rather than listed.
#'
#' `sample` and `analysis` are the two this migration is allowed to change, so
#' they are checked by explicit DELTA in `mig008_verify()` instead of by
#' equality. A hand-written table list silently stops covering whatever is added
#' next, which is the defect an audit found in 006's first version.
#' @keywords internal
mig008_counts_checksum <- function(con) {
  # BASE TABLES AND VIEWS ARE SEPARATED, and finding out why cost a rehearsal
  # run. `dbListTables()` returns both, so the first version of this gate
  # checksummed the five reporting views too - and then failed the migration
  # because they had changed. Of course they had: they are DERIVED from
  # `sample` and `analysis`, so changing those two is the whole point. A gate
  # that fires on the intended effect is not a safety gate, it is a blocker.
  # Views are counted and reported instead, and `mig008_verify()` asserts the
  # one derived property that must hold.
  skip <- c("change_log", "schema_version")
  meta <- DBI::dbGetQuery(
    con,
    "SELECT table_name, table_type FROM information_schema.tables
      WHERE table_schema = 'main' ORDER BY table_name")
  meta <- meta[!(meta$table_name %in% skip) & !grepl("^_st_", meta$table_name), , drop = FALSE]

  tables <- list()
  for (t in meta$table_name[meta$table_type == "BASE TABLE"]) {
    n <- as.integer(DBI::dbGetQuery(con, sprintf('SELECT COUNT(*) n FROM "%s"', t))$n)
    cols <- DBI::dbListFields(con, t)
    # Cast the sum to VARCHAR IN SQL: returned as a double it arrives as
    # "8.9e+23", roughly 1e8 of resolution on a 24-digit sum - a checksum with
    # a hole in it.
    expr <- paste(sprintf('COALESCE(CAST("%s" AS VARCHAR), \'\\x00\')', cols),
                  collapse = " || '|' || ")
    h <- DBI::dbGetQuery(
      con, sprintf('SELECT CAST(COALESCE(SUM(HASH(%s)), 0) AS VARCHAR) h FROM "%s"', expr, t)
    )$h
    tables[[t]] <- n
    tables[[paste0(t, "_checksum")]] <- as.character(h)
  }

  views <- list()
  for (v in meta$table_name[meta$table_type == "VIEW"]) {
    views[[v]] <- as.integer(DBI::dbGetQuery(con, sprintf('SELECT COUNT(*) n FROM "%s"', v))$n)
  }
  list(tables = tables, views = views)
}

#' The SAFETY half: nothing outside `sample` / `analysis` moved, and those two
#' moved by exactly the expected amount.
#'
#' @param before,after `mig008_counts_checksum()`-shaped lists.
#' @param n_deleted_samples,n_deleted_analyses expected deltas (both negative
#'   in effect - passed as positive counts).
#' @return invisible(TRUE); throws otherwise.
mig008_verify <- function(before, after, n_deleted_samples, n_deleted_analyses) {
  if (!identical(names(before$tables), names(after$tables)) ||
      !identical(names(before$views), names(after$views))) {
    cli::cli_abort(
      "008-duplicate-samples verify failed: the before/after count structures differ.",
      class = "sampletidy_error"
    )
  }
  # `sample` changes content (the reassignment) as well as count, and
  # `analysis` loses rows, so both are excluded from the equality sweep and
  # checked by delta immediately below. Every other BASE TABLE must be
  # byte-identical.
  moved <- c("sample", "sample_checksum", "analysis", "analysis_checksum")
  names_to_check <- setdiff(names(before$tables), moved)
  bad <- names_to_check[!vapply(
    names_to_check, function(n) identical(before$tables[[n]], after$tables[[n]]), logical(1))]
  if (length(bad) > 0) {
    cli::cli_abort(
      "008-duplicate-samples verify failed: this migration writes `sample` and
       `analysis` and nothing else, but {paste(bad, collapse = ', ')} changed.",
      class = "sampletidy_error"
    )
  }
  for (spec in list(list(t = "sample", n = n_deleted_samples),
                    list(t = "analysis", n = n_deleted_analyses))) {
    want <- before$tables[[spec$t]] - spec$n
    if (!identical(as.integer(after$tables[[spec$t]]), as.integer(want))) {
      cli::cli_abort(
        "008-duplicate-samples verify failed: `{spec$t}` went
         {before$tables[[spec$t]]} -> {after$tables[[spec$t]]}, expected {want}
         (a loss of exactly {spec$n}).",
        class = "sampletidy_error"
      )
    }
  }

  # THE DERIVED PROPERTY. `v_measurement` is one row per `analysis` - it is the
  # unfiltered base of the reporting stack - so it must lose exactly what
  # `analysis` lost and nothing more. This is what catches a reassignment that
  # quietly orphaned a row: an analysis left with a NULL `uuid_sample` would
  # still be in `analysis` (count unchanged, so the delta check above passes)
  # but would fall out of `v_measurement`'s INNER JOIN.
  if ("v_measurement" %in% names(after$views)) {
    # DELTA, not `v_measurement == analysis`. The equality was the first draft
    # and it is NOT an invariant: the view INNER JOINs through
    # feature_alias -> feature, so an analysis on a sample whose alias is still
    # pending (uuid_feature NULL) is legitimately absent. The test fixture has
    # two such rows and caught it. The delta is the property that actually
    # matters, and it still catches an orphan: a row the FK pre-pass failed to
    # reattach drops out of the view, making the loss 14 instead of 13.
    want <- before$views$v_measurement - n_deleted_analyses
    if (!identical(as.integer(after$views$v_measurement), as.integer(want))) {
      cli::cli_abort(
        "008-duplicate-samples verify failed: `v_measurement` went
         {before$views$v_measurement} -> {after$views$v_measurement}, expected
         {want}.",
        class = "sampletidy_error"
      )
    }
  }
  invisible(TRUE)
}

#' Human-readable view deltas, for the operator's log
#' @keywords internal
#' @noRd
.mig008_view_deltas <- function(before, after) {
  nm <- names(after$views)
  d <- vapply(nm, function(v) as.integer(after$views[[v]]) - as.integer(before$views[[v]]),
              integer(1))
  d[d != 0L]
}

# ---- verify: the SUCCESS half -----------------------------------------------

#' Both rulings, asked as the questions that actually matter
#' @keywords internal
#' @noRd
.mig008_verify_rulings <- function(con, reassign, winners) {
  fail <- function(msg) cli::cli_abort(paste("008-duplicate-samples verify failed:", msg),
                                       class = "sampletidy_error")

  # (1) each feature now holds exactly ONE sample at that date, it is the
  # winner, and the winner kept every analysis it had.
  for (ft in names(winners)) {
    rows <- DBI::dbGetQuery(
      con,
      'SELECT s.uuid, s.person,
              (SELECT COUNT(*) FROM analysis a WHERE a.uuid_sample = s.uuid) AS n_an
         FROM "sample" s
         JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
         JOIN feature f        ON f.uuid = fa.uuid_feature
        WHERE f.name = ? AND CAST(s.datetime AS DATE) = CAST(? AS DATE)',
      params = list(ft, .mig008_dup_date)
    )
    if (nrow(rows) != 1L) fail(sprintf("(1) %s still holds %d samples at %s, expected 1.",
                                       ft, nrow(rows), .mig008_dup_date))
    if (!identical(rows$uuid[[1]], winners[[ft]]$winner)) {
      fail(sprintf("(1) %s kept %s, expected the %s sample %s.", ft, rows$uuid[[1]],
                   .mig008_dup_winner_person, winners[[ft]]$winner))
    }
    if (!identical(as.integer(rows$n_an[[1]]), winners[[ft]]$n_winner)) {
      fail(sprintf("(1) the surviving %s sample now carries %d analyses, not the %d it had.",
                   ft, as.integer(rows$n_an[[1]]), winners[[ft]]$n_winner))
    }
  }

  # (2) every listed sample resolves to the destination FEATURE. Asked through
  # the alias join the reporting views use, not by re-reading the UPDATE.
  got <- DBI::dbGetQuery(
    con,
    sprintf(
      'SELECT s.uuid, f.name AS feature
         FROM "sample" s
         JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
         JOIN feature f        ON f.uuid = fa.uuid_feature
        WHERE s.uuid IN (%s)',
      paste(rep("?", nrow(reassign)), collapse = ", ")
    ),
    params = as.list(reassign$uuid_sample)
  )
  if (nrow(got) != nrow(reassign)) {
    fail(sprintf("(2) %d of %d listed samples came back from the alias join.",
                 nrow(got), nrow(reassign)))
  }
  off <- got[got$feature != .mig008_to_feature, , drop = FALSE]
  if (nrow(off) > 0) {
    fail(sprintf("(2) %d listed sample(s) still resolve to %s, not %s - e.g. %s.",
                 nrow(off), off$feature[[1]], .mig008_to_feature, off$uuid[[1]]))
  }
  invisible(TRUE)
}

# ---- backup -----------------------------------------------------------------

.mig008_backup_counts <- function(con) {
  list(
    sample = as.integer(DBI::dbGetQuery(con, 'SELECT COUNT(*) n FROM "sample"')$n),
    analysis = as.integer(DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM analysis")$n),
    feature_alias = as.integer(DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM feature_alias")$n)
  )
}

mig008_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- .mig008_default(.now, Sys.time())
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-008-duplicate-samples_%sZ.duckdb", ts))

  live_counts <- with_db_write(
    function(con) {
      DBI::dbExecute(con, "CHECKPOINT")
      counts <- .mig008_backup_counts(con)
      ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)),
                     error = function(e) FALSE)
      if (!isTRUE(ok)) {
        cli::cli_abort("{db}: failed to write backup copy to {dest}.",
                       class = "sampletidy_error")
      }
      counts
    },
    db = db
  )

  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE),
                         error = function(e) NULL)
  if (is.null(verify_con)) {
    cli::cli_abort("{db}: backup verification failed - cannot open {dest} read-only.",
                   class = "sampletidy_error")
  }
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig008_backup_counts(verify_con))) {
    cli::cli_abort("{db}: backup verification failed - row counts differ between live DB and {dest}.",
                   class = "sampletidy_error")
  }
  dest
}

# ---- mig008_run() -----------------------------------------------------------

#' Run (or dry-run) the 008-duplicate-samples migration
#'
#' Never invoked by package code (A50).
#'
#' @param db path to the live DuckDB file.
#' @param snapshot_dir directory for the pre-migration backup.
#' @param reassign path to the reassignment CSV, or a data frame.
#' @param dry_run if `TRUE`, run every gate, write nothing, take no backup.
#' @param .now inject a POSIXct instead of `Sys.time()`.
#' @return invisible list(status, backup_path, restore_command, n_deleted_samples,
#'   n_deleted_analyses, n_reassigned, counts_before, counts_after, recorded_at).
mig008_run <- function(db, snapshot_dir, reassign, dry_run = FALSE, .now = NULL) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))

  .mig008_require_internals()
  rea <- .mig008_read_reassign(reassign)

  # ---- Step 0: idempotency marker ----
  marker_con <- st_connect(db, read_only = TRUE)
  if (!("schema_version" %in% DBI::dbListTables(marker_con))) {
    DBI::dbDisconnect(marker_con, shutdown = TRUE)
    cli::cli_abort(
      "{db}: no schema_version table found - ensure_schema() has never been applied
       to this database, so 008-duplicate-samples cannot check its own marker.",
      class = "sampletidy_error"
    )
  }
  marker <- tryCatch(
    DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                    params = list(.mig008_marker_version)),
    finally = DBI::dbDisconnect(marker_con, shutdown = TRUE)
  )
  if (nrow(marker) > 0) {
    recorded_at <- marker$applied_at[[1]]
    logf("008-duplicate-samples already applied at %s; nothing to do.", format(recorded_at))
    read_con <- st_connect(db, read_only = TRUE)
    counts <- tryCatch(mig008_counts_checksum(read_con),
                       finally = DBI::dbDisconnect(read_con, shutdown = TRUE))
    return(invisible(list(
      status = "already_migrated", backup_path = NA_character_,
      restore_command = NA_character_, n_deleted_samples = 0L,
      n_deleted_analyses = 0L, n_reassigned = 0L,
      counts_before = counts, counts_after = counts, recorded_at = recorded_at
    )))
  }

  # ---- dry run: every gate, no write, no backup ----
  if (isTRUE(dry_run)) {
    preview_con <- st_connect(db, read_only = TRUE)
    out <- tryCatch({
      .mig008_check_preconditions(preview_con, rea)
      pairs <- lapply(.mig008_dup_features, function(ft) .mig008_dup_pair(preview_con, ft))
      list(counts = mig008_counts_checksum(preview_con),
           n_an = sum(vapply(pairs, function(p) p$n_loser, integer(1))))
    }, finally = DBI::dbDisconnect(preview_con, shutdown = TRUE))
    logf("DRY RUN: ruling (1) would delete %d sample(s) and %d analysis row(s), every one proved a twin.",
         length(.mig008_dup_features), out$n_an)
    logf("DRY RUN: ruling (2) would move %d sample(s) from %s to %s.",
         nrow(rea), .mig008_from_feature, .mig008_to_feature)
    logf("DRY RUN: no backup taken, no writes made to %s.", db)
    return(invisible(list(
      status = "dry_run", backup_path = NA_character_, restore_command = NA_character_,
      n_deleted_samples = length(.mig008_dup_features), n_deleted_analyses = out$n_an,
      n_reassigned = nrow(rea), counts_before = out$counts, counts_after = NA,
      recorded_at = NA
    )))
  }

  # ---- Step 1: preconditions on a READ-ONLY connection, BEFORE the backup, so
  # a run that could never have succeeded leaves no stray copy behind. They are
  # re-checked inside the transaction, because the database can move between
  # these two moments. ----
  pre_con <- st_connect(db, read_only = TRUE)
  tryCatch(.mig008_check_preconditions(pre_con, rea),
           finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))

  # ---- Step 2: back up and verify, before any write ----
  backup_path <- mig008_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)

  recorded_at <- .mig008_default(.now, Sys.time())

  result <- with_db_write(
    function(con) {
      # Captured BEFORE the pre-pass, so the safety gate below measures the
      # pre-pass's effect too.
      counts_before <- mig008_counts_checksum(con)

      # ---- ruling (1): the FK pre-pass, OUTSIDE any transaction ----
      winners <- list()
      n_an_deleted <- 0L
      for (ft in .mig008_dup_features) {
        one <- .mig008_delete_duplicate(con, ft)
        winners[[ft]] <- one$pair
        n_an_deleted <- n_an_deleted + one$n_analyses
        logf("Ruling (1): %s - deleted the '%s' sample and its %d analysis row(s).",
             ft, .mig008_dup_loser_person, one$n_analyses)
      }

      # ---- ruling (2): also a pre-pass, and also OUTSIDE any transaction ----
      # Re-checked here rather than only in the read-only gate above, because
      # the database can move between the two moments. Ruling (1)'s
      # preconditions are deliberately NOT re-asked - the pre-pass has already
      # made them false by design.
      .mig008_check_preconditions_reassign(con, rea)
      dest <- .mig008_dest_alias(con)
      n_moved_an <- 0L
      for (i in seq_len(nrow(rea))) {
        n_moved_an <- n_moved_an + .mig008_reassign_sample(
          con, rea$uuid_sample[[i]], dest,
          reason = sprintf(
            "008 ruling (2): filed under %s but the lab's client sample ID says '%s'; moved to %s via the confirmed alias '%s'",
            .mig008_from_feature, rea$client_sample_id[[i]],
            .mig008_to_feature, .mig008_to_alias))
      }
      logf("Ruling (2): moved %d sample(s) (%d analysis row(s) detached and restored) to %s.",
           nrow(rea), n_moved_an, .mig008_to_feature)

      body <- db_transaction(con, function(con) {
        DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                       params = list(.mig008_marker_version, recorded_at))

        counts_after <- mig008_counts_checksum(con)
        mig008_verify(counts_before, counts_after,
                      n_deleted_samples = length(.mig008_dup_features),
                      n_deleted_analyses = n_an_deleted)
        .mig008_verify_rulings(con, rea, winners)

        list(counts_after = counts_after, n_an_deleted = n_an_deleted)
      })

      logf("Verify passed: %d duplicate sample(s) / %d analysis row(s) deleted, %d sample(s) reassigned.",
           length(.mig008_dup_features), body$n_an_deleted, nrow(rea))
      deltas <- .mig008_view_deltas(counts_before, body$counts_after)
      if (length(deltas) > 0) {
        logf("Reporting views that moved: %s",
             paste(sprintf("%s %+d", names(deltas), deltas), collapse = ", "))
      }
      list(counts_before = counts_before, counts_after = body$counts_after,
           n_an_deleted = body$n_an_deleted)
    },
    db = db
  )

  logf("008-duplicate-samples migrated successfully.")

  invisible(list(
    status = "migrated", backup_path = backup_path, restore_command = restore_command,
    n_deleted_samples = length(.mig008_dup_features),
    n_deleted_analyses = result$n_an_deleted, n_reassigned = nrow(rea),
    counts_before = result$counts_before, counts_after = result$counts_after,
    recorded_at = recorded_at
  ))
}
