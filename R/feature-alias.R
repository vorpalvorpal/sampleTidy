# Plan 11 - R/feature-alias.R: the resolve API (B-11-the-api-is-the).
#
# confirm_feature_aliases() (R-11.10) and confirm_analyte_methods() (R-11.11)
# are the ONLY functions that write a resolution: `feature_alias.uuid_feature`
# / `lab_method.uuid_analyte`. They are vectorised for bulk confirmation, run
# entirely through the plan-09 mutation layer (db_update()/db_append()/
# db_delete(), reused - never a raw dbExecute()/dbGetQuery() write; reads via
# dbGetQuery() are fine), and record `confirmed_by` as the `actor` on every
# change_log row they write (A32/A40). `confirmed_by` is mandatory and MUST
# NOT carry a default value anywhere in either signature (A55) - a UI may
# propose, but only a human confirms.
#
# Both open exactly one mutation-layer transaction per call
# (with_db_write() -> db_transaction()) so a multi-item bulk call is one
# atomic unit: an error on item N rolls back items 1..N-1 too, not just N.

# ======================================================================
# R-11.10 confirm_feature_aliases()
# ======================================================================

#' Confirm a feature alias's resolution (R-11.10)
#'
#' Sets `feature_alias.uuid_feature` for one or more aliases, vectorised.
#' Runs inside one `with_db_write()` transaction, entirely through the
#' mutation layer. See PLAN-11 R-11.10 for the full contract (collision
#' check, D5 override semantics, C15 kind rule, C14 merge pins).
#'
#' @param uuid_alias character vector of `feature_alias.uuid`.
#' @param uuid_feature character vector of `feature.uuid`, same length as
#'   `uuid_alias`. `NA` is rejected (a feature must exist).
#' @param confirmed_by who is confirming - mandatory, no default (A55).
#' @param override if `TRUE`, a collision (linking would put two `sample`
#'   rows on the same (feature, date)) is merged rather than aborted (D5).
#' @param db path to the DuckDB file; defaults to `st_config("live_db")`.
#' @return `invisible(tibble(uuid_alias, uuid_feature, n_samples, action))`.
#' @export
confirm_feature_aliases <- function(uuid_alias, uuid_feature, confirmed_by,
                                     override = FALSE, db = st_config("live_db")) {
  checkmate::assert_character(uuid_alias)
  checkmate::assert_character(uuid_feature)
  checkmate::assert_string(confirmed_by)
  checkmate::assert_flag(override)
  checkmate::assert_string(db)

  if (length(uuid_alias) != length(uuid_feature)) {
    cli::cli_abort(
      "uuid_alias and uuid_feature must be the same length ({length(uuid_alias)} vs {length(uuid_feature)}).",
      class = "sampletidy_error"
    )
  }

  if (length(uuid_alias) == 0) {
    return(invisible(tibble::tibble(
      uuid_alias = character(0), uuid_feature = character(0),
      n_samples = integer(0), action = character(0)
    )))
  }

  result <- with_db_write(
    function(con) {
      db_transaction(con, function(con) {
        rows <- purrr::map2(uuid_alias, uuid_feature, function(ua, uf) {
          .fa_confirm_one_alias(con, ua, uf, confirmed_by = confirmed_by, override = override)
        })
        dplyr::bind_rows(rows)
      })
    },
    db = db
  )

  invisible(result)
}

#' Confirm exactly one (uuid_alias, uuid_feature) pair.
#' @keywords internal
#' @noRd
.fa_confirm_one_alias <- function(con, uuid_alias, uuid_feature, confirmed_by, override) {
  alias <- DBI::dbGetQuery(con, "SELECT * FROM feature_alias WHERE uuid = ?", params = list(uuid_alias))
  if (nrow(alias) == 0) {
    cli::cli_abort("No feature_alias with uuid '{uuid_alias}'.", class = "sampletidy_error")
  }
  if (is.na(uuid_feature)) {
    cli::cli_abort(
      "uuid_feature must not be NA (confirming alias '{uuid_alias}').",
      class = "sampletidy_error"
    )
  }
  feature <- DBI::dbGetQuery(con, "SELECT * FROM feature WHERE uuid = ?", params = list(uuid_feature))
  if (nrow(feature) == 0) {
    cli::cli_abort("No feature with uuid '{uuid_feature}'.", class = "sampletidy_error")
  }

  current_feature <- alias$uuid_feature[[1]]
  already_confirmed <- !is.na(alias$confirmed_by[[1]])
  if (already_confirmed && !is.na(current_feature) && !identical(current_feature, uuid_feature)) {
    cli::cli_abort(
      paste0(
        "Alias '", uuid_alias, "' is already confirmed to feature '", current_feature,
        "'; refusing to silently re-point it to a different feature '", uuid_feature,
        "'. Confirming to a different feature than an existing confirmed_by row is an error."
      ),
      class = "sampletidy_error"
    )
  }

  n_samples <- DBI::dbGetQuery(
    con, 'SELECT count(*) AS n FROM "sample" WHERE uuid_feature_alias = ?',
    params = list(uuid_alias)
  )$n[[1]]

  collisions <- .fa_find_collisions(con, uuid_alias, uuid_feature)

  if (nrow(collisions) > 0 && !isTRUE(override)) {
    detail <- paste(
      sprintf(
        "feature %s, date %s: existing sample %s vs new sample %s",
        uuid_feature, as.character(collisions$collision_date),
        collisions$uuid_existing, collisions$uuid_new
      ),
      collapse = "; "
    )
    cli::cli_abort(
      paste0(
        "Confirming alias '", uuid_alias, "' to feature '", uuid_feature,
        "' would collide with existing sample(s) on the same (feature, date): ",
        detail,
        ". Pass override = TRUE to merge, or pick a different feature - a collision ",
        "usually means the wrong feature was picked."
      ),
      class = "sampletidy_error"
    )
  }

  changes <- list(uuid_feature = uuid_feature, confirmed_by = confirmed_by, auto_assign = TRUE)
  if (identical(alias$kind[[1]], "pending")) {
    changes$kind <- "transcription_error"
  }
  db_update(
    con, "feature_alias", uuid_alias, changes = changes,
    actor = confirmed_by, reason = "confirm_feature_aliases()"
  )

  action <- "confirmed"
  if (nrow(collisions) > 0 && isTRUE(override)) {
    losers <- unique(collisions$uuid_new)
    for (loser_uuid in losers) {
      winner_uuid <- collisions$uuid_existing[collisions$uuid_new == loser_uuid][[1]]
      .fa_merge_samples(con, uuid_loser = loser_uuid, uuid_winner = winner_uuid, confirmed_by = confirmed_by)
    }
    action <- "merged"
  }

  tibble::tibble(
    uuid_alias = uuid_alias, uuid_feature = uuid_feature,
    n_samples = n_samples, action = action
  )
}

#' Find (feature, date) collisions a link from `uuid_alias` to `uuid_feature`
#' would create: for every sample currently reached through `uuid_alias`,
#' any OTHER sample (reached through any alias) resolving to the same
#' `uuid_feature` on the same date. `uuid_new` is always the sample reached
#' through the alias being confirmed (the arrival); `uuid_existing` is the
#' pre-existing sample (D5/C14 - winner = NOT reached via the confirmed alias).
#' @keywords internal
#' @noRd
.fa_find_collisions <- function(con, uuid_alias, uuid_feature) {
  DBI::dbGetQuery(
    con,
    '
    SELECT DISTINCT s1.uuid AS uuid_new, s2.uuid AS uuid_existing,
           CAST(s1.date AS DATE) AS collision_date
    FROM "sample" s1
    JOIN "sample" s2
      ON CAST(s2.date AS DATE) = CAST(s1.date AS DATE) AND s2.uuid != s1.uuid
    JOIN feature_alias fa2 ON fa2.uuid = s2.uuid_feature_alias
    WHERE s1.uuid_feature_alias = ?
      AND fa2.uuid_feature = ?
    ',
    params = list(uuid_alias, uuid_feature)
  )
}

#' Merge a collision (D5/C14, override = TRUE): re-point the loser's
#' analyses onto the winner (dropping an A14-equal duplicate, re-pointing and
#' flagging a genuinely different one as value_conflict - never orphaning
#' it), log the loser's discarded organisation/person/datetime as
#' `provenance` rows, then delete the emptied loser sample.
#' @keywords internal
#' @noRd
.fa_merge_samples <- function(con, uuid_loser, uuid_winner, confirmed_by) {
  loser <- DBI::dbGetQuery(con, 'SELECT * FROM "sample" WHERE uuid = ?', params = list(uuid_loser))
  winner <- DBI::dbGetQuery(con, 'SELECT * FROM "sample" WHERE uuid = ?', params = list(uuid_winner))

  discard_fields <- c("organisation", "person", "datetime")
  for (f in discard_fields) {
    lv <- loser[[f]][[1]]
    wv <- winner[[f]][[1]]
    if (!identical(as.character(lv), as.character(wv))) {
      .st_write_change_log(
        con, at = Sys.time(), actor = confirmed_by, action = "provenance",
        tbl = "sample", uuid_row = uuid_loser, field = f,
        old = as.character(lv), new = as.character(wv),
        reason = paste0(
          "merge: loser sample's ", f, " discarded in favour of winner sample '", uuid_winner, "'"
        ),
        source_hash = NA_character_
      )
    }
  }

  loser_analyses <- DBI::dbGetQuery(con, "SELECT * FROM analysis WHERE uuid_sample = ?", params = list(uuid_loser))

  for (i in seq_len(nrow(loser_analyses))) {
    la <- loser_analyses[i, ]
    existing <- DBI::dbGetQuery(
      con,
      "SELECT * FROM analysis WHERE uuid_sample = ? AND uuid_lab = ? AND uuid != ?",
      params = list(uuid_winner, la$uuid_lab, la$uuid)
    )

    if (nrow(existing) > 0) {
      ex <- existing[1, ]
      eq <- .rc_values_equal(la$value, la$value_chr, la$quantified, ex$value, ex$value_chr, ex$quantified)

      if (isTRUE(eq)) {
        .st_write_change_log(
          con, at = Sys.time(), actor = confirmed_by, action = "provenance",
          tbl = "analysis", uuid_row = la$uuid, field = "value",
          old = as.character(la$value), new = NA_character_,
          reason = paste0(
            "merge: duplicate of '", ex$uuid, "' dropped (already_present semantics, A14-equal)"
          ),
          source_hash = NA_character_
        )
        db_delete(con, "analysis", la$uuid, actor = confirmed_by, reason = "merge: duplicate analysis dropped")
      } else {
        db_update(
          con, "analysis", la$uuid, changes = list(uuid_sample = uuid_winner),
          actor = confirmed_by, reason = "merge: re-pointed duplicate analysis onto winner sample"
        )
        # PLAN-16 R-16.19/R-16.20: subkind='alias_merge' (discriminated by
        # subkind, not a second grammar); uuid_existing is a real column
        # (the winner's analysis uuid), never a diagnostics key. Vocabulary
        # is <thing>_<role> (role in {existing,incoming}), shared with the
        # reconcile `.rc` measurement producer's subkind='measurement' on
        # value_existing/value_incoming. Unlike that producer, the incoming
        # side here IS a real analysis row (`la`) - but its uuid is
        # deliberately NOT surfaced as a diagnostics key (no uuid_new/
        # uuid_incoming), to keep the shared vocabulary identical; it
        # remains discoverable via change_log's "re-pointed" row above.
        review_row <- .rq_row(
          kind = "value_conflict", subkind = "alias_merge",
          uuid_existing = ex$uuid,
          diagnostics = list(value_existing = ex$value, value_incoming = la$value)
        )$review
        db_append(
          con, "review_queue", review_row, actor = confirmed_by,
          reason = "merge: value conflict between duplicate analyses, existing value left untouched"
        )
      }
    } else {
      db_update(
        con, "analysis", la$uuid, changes = list(uuid_sample = uuid_winner),
        actor = confirmed_by, reason = "merge: re-pointed analysis onto winner sample"
      )
    }
  }

  db_delete(con, "sample", uuid_loser, actor = confirmed_by, reason = "merge: emptied sample deleted after merge")
  invisible(NULL)
}

# ======================================================================
# R-11.11 confirm_analyte_methods()
# ======================================================================

#' Confirm a lab method's analyte resolution (R-11.11)
#'
#' Sets `lab_method.uuid_analyte` for one or more methods, vectorised. No
#' propagation UPDATE is needed - analyses already point at the method. Each
#' affected analysis's `value`/`rl_low`/`rl_high` is converted from the
#' method's recorded `units` to the analyte's units via `unify_value()`
#' (D7 reversed - the source units come from `lab_method.units`, never from a
#' per-analysis column). An analysis whose method units cannot be converted
#' is left alone and opens an `unknown_unit` review item. Before converting,
#' checks `change_log` for `units`-drift on this method (>1 distinct unit
#' ever seen); if found, does NOT bulk-convert or link, and opens a
#' `units_drift` review item instead (see PLAN-11 R-11.11 and the RULED PIN
#' on the drift-detection mechanism).
#'
#' @param uuid_lab character vector of `lab_method.uuid`.
#' @param uuid_analyte character vector of `analyte.uuid`, same length as
#'   `uuid_lab`. `NA` is rejected (an analyte must exist).
#' @param confirmed_by who is confirming - mandatory, no default (A55).
#' @param db path to the DuckDB file; defaults to `st_config("live_db")`.
#' @return `invisible(tibble(uuid_lab, uuid_analyte, n_analyses, n_converted, action))`.
#' @export
confirm_analyte_methods <- function(uuid_lab, uuid_analyte, confirmed_by,
                                     db = st_config("live_db")) {
  checkmate::assert_character(uuid_lab)
  checkmate::assert_character(uuid_analyte)
  checkmate::assert_string(confirmed_by)
  checkmate::assert_string(db)

  if (length(uuid_lab) != length(uuid_analyte)) {
    cli::cli_abort(
      "uuid_lab and uuid_analyte must be the same length ({length(uuid_lab)} vs {length(uuid_analyte)}).",
      class = "sampletidy_error"
    )
  }

  if (length(uuid_lab) == 0) {
    return(invisible(tibble::tibble(
      uuid_lab = character(0), uuid_analyte = character(0),
      n_analyses = integer(0), n_converted = integer(0), action = character(0)
    )))
  }

  result <- with_db_write(
    function(con) {
      db_transaction(con, function(con) {
        rows <- purrr::map2(uuid_lab, uuid_analyte, function(ul, ua) {
          .am_confirm_one_method(con, ul, ua, confirmed_by = confirmed_by)
        })
        dplyr::bind_rows(rows)
      })
    },
    db = db
  )

  invisible(result)
}

#' Confirm exactly one (uuid_lab, uuid_analyte) pair.
#' @keywords internal
#' @noRd
.am_confirm_one_method <- function(con, uuid_lab, uuid_analyte, confirmed_by) {
  method <- DBI::dbGetQuery(con, "SELECT * FROM lab_method WHERE uuid = ?", params = list(uuid_lab))
  if (nrow(method) == 0) {
    cli::cli_abort("No lab_method with uuid '{uuid_lab}'.", class = "sampletidy_error")
  }
  if (is.na(uuid_analyte)) {
    cli::cli_abort(
      "uuid_analyte must not be NA (confirming lab_method '{uuid_lab}').",
      class = "sampletidy_error"
    )
  }
  analyte <- DBI::dbGetQuery(con, "SELECT * FROM analyte WHERE uuid = ?", params = list(uuid_analyte))
  if (nrow(analyte) == 0) {
    cli::cli_abort("No analyte with uuid '{uuid_analyte}'.", class = "sampletidy_error")
  }

  current_analyte <- method$uuid_analyte[[1]]
  analyses <- DBI::dbGetQuery(con, "SELECT * FROM analysis WHERE uuid_lab = ?", params = list(uuid_lab))
  n_analyses <- nrow(analyses)

  # Idempotent no-op: already confirmed to this exact analyte (lm-0012-style
  # re-confirm). Values were converted (or not) the first time; do not
  # re-attempt conversion, which would double-convert an already-canonical
  # value.
  if (!is.na(current_analyte) && identical(current_analyte, uuid_analyte)) {
    return(tibble::tibble(
      uuid_lab = uuid_lab, uuid_analyte = uuid_analyte,
      n_analyses = n_analyses, n_converted = 0L, action = "already_confirmed"
    ))
  }

  if (!is.na(current_analyte) && !identical(current_analyte, uuid_analyte)) {
    cli::cli_abort(
      paste0(
        "lab_method '", uuid_lab, "' is already confirmed to analyte '", current_analyte,
        "'; refusing to silently re-point it to a different analyte '", uuid_analyte, "'."
      ),
      class = "sampletidy_error"
    )
  }

  # Units-drift check (RULED PIN): scan change_log for every distinct
  # non-NULL `units` value ever recorded (old or new) for this method. >1
  # distinct value -> do not bulk-convert or link; surface it instead.
  drift_units <- DBI::dbGetQuery(
    con,
    "
    SELECT DISTINCT val FROM (
      SELECT old AS val FROM change_log
        WHERE tbl = 'lab_method' AND uuid_row = ? AND field = 'units' AND old IS NOT NULL
      UNION
      SELECT new AS val FROM change_log
        WHERE tbl = 'lab_method' AND uuid_row = ? AND field = 'units' AND new IS NOT NULL
    ) t
    ",
    params = list(uuid_lab, uuid_lab)
  )$val

  if (length(drift_units) > 1) {
    # PLAN-16 R-16.8: routed through .rq_row() - diagnostics -> JSON, no
    # hand-built k=v string. `units_drift` has no `uuid_existing` referent
    # in B-16.ddl's polymorphic map, so uuid_lab travels in diagnostics.
    review_row <- .rq_row(
      kind = "units_drift",
      diagnostics = list(uuid_lab = uuid_lab, units = drift_units)
    )$review
    db_append(
      con, "review_queue", review_row, actor = confirmed_by,
      reason = "confirm_analyte_methods(): units drift detected, not bulk-converting"
    )
    return(tibble::tibble(
      uuid_lab = uuid_lab, uuid_analyte = uuid_analyte,
      n_analyses = n_analyses, n_converted = 0L, action = "units_drift"
    ))
  }

  db_update(
    con, "lab_method", uuid_lab, changes = list(uuid_analyte = uuid_analyte),
    actor = confirmed_by, reason = "confirm_analyte_methods()"
  )

  units_from <- normalise_lab_text(method$units[[1]])
  units_to <- normalise_lab_text(analyte$units[[1]])

  n_converted <- 0L
  for (i in seq_len(nrow(analyses))) {
    a <- analyses[i, ]
    conv <- tryCatch(
      unify_value(
        c(a$value, a$rl_low, a$rl_high),
        c(units_from, units_from, units_from),
        c(units_to, units_to, units_to)
      ),
      sampletidy_units_error = function(e) e
    )

    if (inherits(conv, "condition")) {
      # PLAN-16 R-16.8: routed through .rq_row() - diagnostics -> JSON, no
      # hand-built k=v string. This `unknown_unit` has no `uuid_existing`
      # referent in B-16.ddl's polymorphic map, so the entity references
      # travel in diagnostics.
      review_row <- .rq_row(
        kind = "unknown_unit",
        diagnostics = list(
          uuid_analysis = a$uuid, uuid_lab = uuid_lab,
          units_from = method$units[[1]], units_to = analyte$units[[1]]
        )
      )$review
      db_append(
        con, "review_queue", review_row, actor = confirmed_by,
        reason = "confirm_analyte_methods(): method units could not be converted to the analyte's units"
      )
      next
    }

    db_update(
      con, "analysis", a$uuid,
      changes = list(value = conv[[1]], rl_low = conv[[2]], rl_high = conv[[3]]),
      actor = confirmed_by, reason = "confirm_analyte_methods(): unit conversion"
    )
    n_converted <- n_converted + 1L
  }

  tibble::tibble(
    uuid_lab = uuid_lab, uuid_analyte = uuid_analyte,
    n_analyses = n_analyses, n_converted = n_converted, action = "confirmed"
  )
}
