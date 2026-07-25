# Plan 09 - R/commit.R: `commit_event()` (R-9.2), the atomic transactional
# commit step of the ingest pipeline.
#
# The whole body runs inside exactly one db_transaction(con, fn) call
# (R/mutate.R): the con handed to fn is a tagged copy of the caller's own
# con, so every nested db_append()/db_update()/archive_file()/
# ingest_file_set_state() call below participates in that single
# transaction instead of opening a second one (CONTRACT A40). No raw
# table-write calls appear in this file (A32) - every write goes through
# the mutation layer (db_append()/db_update()/.st_write_change_log()) or
# db-schema.R's ingest_file_set_state(); all SELECTs are plain
# DBI::dbGetQuery() reads.

.ct_actor <- "pipeline"

# ---- small shared helpers ---------------------------------------------------

#' NA-safe vectorised "is this row kept" test
#' @keywords internal
#' @noRd
.ct_kept_rows <- function(files) {
  kept <- files$kept
  !is.na(kept) & kept
}

# ---- step 0: idempotency guard ----------------------------------------------

#' Abort if any `kept` file of the event is already `committed`/`archived`
#' (a second call on the same event should be a clean no-op abort, not a
#' duplicate commit). Deliberately does not treat `ignored` as terminal for
#' this purpose - superseded renderings are legitimately `ignored`.
#' @keywords internal
#' @noRd
.ct_check_not_already_committed <- function(con, files) {
  kept <- files[.ct_kept_rows(files), , drop = FALSE]
  if (nrow(kept) == 0) {
    return(invisible(NULL))
  }
  for (h in kept$hash) {
    row <- DBI::dbGetQuery(con, "SELECT state FROM ingest_file WHERE hash = ?", params = list(h))
    if (nrow(row) > 0 && row$state[[1]] %in% c("committed", "archived")) {
      cli::cli_abort(
        "commit_event(): file with hash {.val {h}} is already in state {.val {row$state[[1]]}}; refusing to re-commit.",
        class = "sampletidy_error"
      )
    }
  }
  invisible(NULL)
}

# ---- step 1: project ---------------------------------------------------------

#' Look up the project row for `work_order`, creating one if absent (step 1)
#'
#' `add_project()` (R/mutate.R) opens its own connection via
#' `with_db_write()`, which would escape this function's transaction, so the
#' insert is done directly with `db_append()` on the caller's `con` instead.
#' @keywords internal
#' @noRd
.ct_ensure_project <- function(con, work_order, reason) {
  existing <- DBI::dbGetQuery(con, "SELECT uuid FROM project WHERE name = ?", params = list(work_order))
  if (nrow(existing) > 0) {
    return(existing$uuid[[1]])
  }

  new_uuid <- uuid::UUIDgenerate()
  row <- tibble::tibble(
    uuid = new_uuid, uuid_parent = NA_character_, uuid_root = NA_character_,
    uuid_project = NA_character_, name = work_order, type = "Work order",
    purpose = NA_character_, date_start = as.POSIXct(NA), date_end = as.POSIXct(NA),
    regulated_by = NA_character_, cypher = NA_character_, site = NA_character_,
    value = NA_character_
  )
  db_append(con, "project", row, actor = .ct_actor, reason = reason)
  new_uuid
}

# ---- step 1b: materialise pending aliases + dangling methods (R-11.8) --------

#' NA-safe vectorised `isTRUE()` for a possibly-absent logical column.
#' @keywords internal
#' @noRd
.ct_pending_flag <- function(clean, col) {
  if (!(col %in% names(clean))) {
    return(rep(FALSE, nrow(clean)))
  }
  .rc_is_true_vec(clean[[col]])
}

#' Materialise a pending feature_alias per distinct `alias_key` (R-11.8, D8)
#'
#' D8 keeps reconcile read-only: the dangling alias is CREATED here, at commit.
#' find-or-create is keyed `uuid_feature IS NULL AND alias_key = ?` (CONTRACT
#' PIN (a): never `uuid_feature = NULL`, which matches nothing in SQL and would
#' spawn a fresh alias for every file). `name` is the group's FIRST row's raw
#' `feature_raw` (PIN (b): provenance, first-wins). `n_seen` is incremented by
#' the number of distinct sample tuples that newly point at the alias in this
#' event (PIN (c)); `first_seen`/`last_seen` are `Sys.time()` at materialisation.
#' Returns `clean` with `uuid_feature_alias` filled for every pending row.
#' @keywords internal
#' @noRd
.ct_materialise_feature_aliases <- function(con, clean, event, actor, reason) {
  if (!("uuid_feature_alias" %in% names(clean))) {
    clean$uuid_feature_alias <- NA_character_
  }
  pending <- .ct_pending_flag(clean, "feature_pending")
  if (!any(pending)) {
    return(clean)
  }

  now <- Sys.time()
  keys <- clean$alias_key
  pend_idx <- which(pending)

  for (uk in unique(keys[pend_idx])) {
    rows_k <- pend_idx[keys[pend_idx] == uk]
    first_i <- rows_k[[1]]
    name_raw <- clean$feature_raw[[first_i]]
    incr <- length(unique(paste(
      as.character(clean$sample_date[rows_k]),
      ifelse(is.na(clean$sample_datetime[rows_k]), "NA",
             format(clean$sample_datetime[rows_k], "%Y-%m-%d %H:%M:%S")),
      sep = "||"
    )))

    existing <- DBI::dbGetQuery(
      con,
      "SELECT uuid, n_seen FROM feature_alias WHERE alias_key = ? AND uuid_feature IS NULL",
      params = list(uk)
    )
    if (nrow(existing) > 0) {
      alias_uuid <- existing$uuid[[1]]
      prev_n <- existing$n_seen[[1]]
      if (is.na(prev_n)) prev_n <- 0L
      db_update(
        con, "feature_alias", uuid = alias_uuid,
        changes = list(n_seen = as.integer(prev_n + incr), last_seen = now),
        actor = actor, reason = reason
      )
    } else {
      alias_uuid <- uuid::UUIDgenerate()
      row <- tibble::tibble(
        uuid = alias_uuid, uuid_feature = NA_character_, name = name_raw,
        alias_key = uk, kind = "pending", n_seen = as.integer(incr),
        auto_assign = FALSE, first_seen = now, last_seen = now,
        confirmed_by = NA_character_,
        comments = NA_character_
      )
      db_append(con, "feature_alias", row, actor = actor, reason = reason,
                source_hash = clean$source_hash[[first_i]])
    }
    clean$uuid_feature_alias[rows_k] <- alias_uuid
  }
  clean
}

#' Materialise a dangling lab_method per distinct pending analyte (R-11.8)
#'
#' find-or-create from (`name` = analyte_raw, `organisation` = org, `method` =
#' method_raw, rl_low, rl_high, `units` = units_raw), `uuid_analyte = NULL`.
#' Dedup key is `(organisation, .rc_method_key(name), .rc_method_key(method))` AND
#' `uuid_analyte IS NULL` (PIN (e): the lookup MUST use the identical
#' `.rc_method_key()` expression `.rc_lab_method_candidates()` uses, or nothing ever
#' dedups). `conversion_constant` stays NA. Returns `clean` with `uuid_lab`
#' filled for every pending-analyte row.
#' @keywords internal
#' @noRd
.ct_materialise_lab_methods <- function(con, clean, event, actor, reason) {
  if (!("uuid_lab" %in% names(clean))) {
    clean$uuid_lab <- NA_character_
  }
  pending <- .ct_pending_flag(clean, "analyte_pending")
  if (!any(pending)) {
    return(clean)
  }

  pend_idx <- which(pending)
  dk <- paste(clean$org, .rc_method_key(clean$analyte_raw), .rc_method_key(clean$method_raw), sep = "||")

  for (uk in unique(dk[pend_idx])) {
    rows_k <- pend_idx[dk[pend_idx] == uk]
    first_i <- rows_k[[1]]
    org <- clean$org[[first_i]]
    name_raw <- clean$analyte_raw[[first_i]]
    method_raw <- clean$method_raw[[first_i]]

    cand <- DBI::dbGetQuery(
      con,
      "SELECT uuid, name, method, units FROM lab_method WHERE organisation = ? AND uuid_analyte IS NULL",
      params = list(org)
    )
    lab_uuid <- NA_character_
    recorded_units <- NA_character_
    if (nrow(cand) > 0) {
      name_match <- !is.na(cand$name) & .rc_method_key(cand$name) == .rc_method_key(name_raw)
      method_match <- (is.na(cand$method) & is.na(method_raw)) |
        (!is.na(cand$method) & !is.na(method_raw) & .rc_method_key(cand$method) == .rc_method_key(method_raw))
      hit <- cand[name_match & method_match, , drop = FALSE]
      if (nrow(hit) > 0) {
        lab_uuid <- hit$uuid[[1]]
        recorded_units <- hit$units[[1]]
      }
    }

    if (!is.na(lab_uuid)) {
      row_units_raw <- if ("units_raw" %in% names(clean)) clean$units_raw[[first_i]] else NA_character_
      if (!is.na(row_units_raw) && !identical(row_units_raw, recorded_units)) {
        .st_write_change_log(
          con, at = Sys.time(), actor = actor, action = "provenance", tbl = "lab_method",
          uuid_row = lab_uuid, field = "units", old = recorded_units, new = row_units_raw,
          reason = sprintf("units-drift sighting (%s -> %s)", recorded_units, row_units_raw),
          source_hash = clean$source_hash[[first_i]]
        )
      }
    }

    if (is.na(lab_uuid)) {
      lab_uuid <- uuid::UUIDgenerate()
      rl_low <- if ("rl_low" %in% names(clean)) clean$rl_low[[first_i]] else NA_real_
      rl_high <- if ("rl_high" %in% names(clean)) clean$rl_high[[first_i]] else NA_real_
      units_raw <- if ("units_raw" %in% names(clean)) clean$units_raw[[first_i]] else NA_character_
      row <- tibble::tibble(
        uuid = lab_uuid, uuid_analyte = NA_character_, name = name_raw,
        method = method_raw, organisation = org, rl_low = rl_low, rl_high = rl_high,
        units = units_raw, conversion_constant = NA_real_
      )
      db_append(con, "lab_method", row, actor = actor, reason = reason,
                source_hash = clean$source_hash[[first_i]])
    }
    clean$uuid_lab[rows_k] <- lab_uuid
  }
  clean
}

#' Rewrite the `review_queue` row's typed `uuid_alias` column for every
#' review item whose pending feature materialised to an alias uuid in this
#' commit (R-11.9 commit-side, seam S-8; PLAN-16 S-16.4). The commit is the
#' only point where a review item, its clean row (matched by `source_ref`),
#' and the freshly created alias uuid all coexist.
#'
#' `review$uuid` is the `review_queue` row's own primary key - by the time
#' this runs, `.ct_commit_review()` has already inserted the row and carried
#' its generated `uuid` back onto `review`. The write is a keyed `UPDATE` of
#' `uuid_alias` (via the mutation layer's `db_update()`, A32) - idempotent
#' (R-16.15) because it SETs rather than appends, and `uuid_alias` is the
#' ONLY representation of the alias uuid (R-16.21, RULING D): the JSON
#' `payload` text itself is never touched by this rewrite. Non-pending /
#' unmatched review rows pass through untouched.
#'
#' `clean$source_ref` is one ref per row, but `.rc_feature_review()` /
#' `.rc_analyte_review()` (R/reconcile.R) build a GROUPED review item's
#' `source_ref` as `paste(refs, collapse = ",")` - a comma-joined list over
#' the whole group (FF3, round-2 audit). An exact-string join against `amap`
#' therefore only ever matched a one-row item; every grouped item's
#' `uuid_alias` stayed NULL although the alias row existed. The match below
#' splits the review row's `source_ref` on `,` and looks up each individual
#' ref instead - every ref in a group's `clean` rows was assigned the SAME
#' alias uuid by `.ct_materialise_feature_aliases()` (one alias per
#' `alias_key`), so any one hit is sufficient and the result cannot depend on
#' group size or row order.
#'
#' `amap`'s key additionally folds in `source_hash` when both tibbles carry
#' it (always true for a real `reconcile_event()` review/clean pair; some
#' hand-built test fixtures omit it, so this degrades to `source_ref`-only
#' rather than erroring). `source_ref` alone (e.g. `"row1"`, `"r1c11"`) is
#' only unique WITHIN one source file; a commit event spanning more than one
#' file could otherwise let two DIFFERENT items' refs collide and rewrite
#' the wrong review row's `uuid_alias` - a mis-link, which is worse than the
#' missing link this fix repairs, since `uuid_alias` is what a human uses to
#' accept the alias (PLAN-15 `review_queue_close()`, R-16.21).
#' @keywords internal
#' @noRd
.ct_rewrite_review_payloads <- function(con, review, clean) {
  if (nrow(review) == 0 ||
      !all(c("source_ref", "uuid") %in% names(review)) ||
      !all(c("source_ref", "feature_pending", "uuid_feature_alias") %in% names(clean))) {
    return(review)
  }
  pend <- .ct_pending_flag(clean, "feature_pending")
  if (!any(pend)) {
    return(review)
  }
  use_hash <- "source_hash" %in% names(clean) && "source_hash" %in% names(review)
  amap_keys <- if (use_hash) {
    paste(clean$source_hash[pend], clean$source_ref[pend], sep = "\x01")
  } else {
    clean$source_ref[pend]
  }
  amap <- stats::setNames(clean$uuid_feature_alias[pend], amap_keys)

  for (i in seq_len(nrow(review))) {
    sr <- review$source_ref[[i]]
    if (is.na(sr)) next
    refs <- strsplit(sr, ",", fixed = TRUE)[[1]]
    keys <- if (use_hash) {
      sh <- review$source_hash[[i]]
      if (is.na(sh)) character(0) else paste(sh, refs, sep = "\x01")
    } else {
      refs
    }
    hit <- keys[keys %in% names(amap)]
    if (length(hit) == 0) next
    au <- amap[[hit[[1]]]]
    if (is.na(au)) next
    row_uuid <- review$uuid[[i]]
    if (is.na(row_uuid)) next
    db_update(
      con, "review_queue", uuid = row_uuid,
      changes = list(uuid_alias = au),
      actor = .ct_actor, reason = "commit_event: review alias rewrite"
    )
  }
  review
}

#' Write a `change_log` provenance row for every NON-CURATED feature
#' resolution (PLAN-15 C.4).
#'
#' Reconcile is read-only (A32) and cannot write `change_log`, so the reason
#' rides on the clean row's `feature_resolution` field and the row is written
#' here, mirroring `.fa_merge_samples`: `action = 'provenance'`, `tbl =
#' 'sample'`, `field = 'uuid_feature_alias'`, `new` = the alias the row landed
#' on, `reason` = `structural_parse: ...` / `wo_site_inferred: ...`. A Layer-1
#' curated alias hit carries no reason and logs nothing - only a rule-derived
#' resolution needs to be auditable and reversible.
#'
#' `change_log` has NO `confidence` column: confidence rides on the clean row's
#' own `confidence` field and is deliberately NOT smuggled into `reason`.
#' One row per distinct (sample, alias, reason) - several analyses of one
#' sample share a single resolution event.
#' @keywords internal
#' @noRd
.ct_record_resolution_provenance <- function(con, clean, actor) {
  if (nrow(clean) == 0 || !("feature_resolution" %in% names(clean))) {
    return(invisible(NULL))
  }
  idx <- which(!is.na(clean$feature_resolution))
  if (length(idx) == 0) {
    return(invisible(NULL))
  }
  has_sample <- "uuid_sample" %in% names(clean)
  seen <- character(0)
  for (i in idx) {
    uuid_sample <- if (has_sample) clean$uuid_sample[[i]] else NA_character_
    alias <- clean$uuid_feature_alias[[i]]
    key <- paste(uuid_sample, alias, clean$feature_resolution[[i]], sep = "||")
    if (key %in% seen) next
    seen <- c(seen, key)
    .st_write_change_log(
      con, at = Sys.time(), actor = actor, action = "provenance", tbl = "sample",
      uuid_row = uuid_sample, field = "uuid_feature_alias",
      old = NA_character_, new = alias,
      reason = clean$feature_resolution[[i]], source_hash = clean$source_hash[[i]]
    )
  }
  invisible(NULL)
}

# ---- step 2: samples ----------------------------------------------------------

#' Per-row feature keys for sample resolution (R-11.2 re-key)
#'
#' `sample.uuid_feature` was dropped (A48); a sample points at the alias it
#' arrived under. This computes, per clean row: `pending` (is the feature
#' unresolved), `alias_uuid` (the alias a NEW sample stores), and
#' `match_feature` (the resolved feature to REUSE existing samples by, NA for a
#' pending row). Handles both the plan-11 shape (carries `uuid_feature_alias` /
#' `feature_pending`) and the plan-09 shape (carries `uuid_feature` only, whose
#' self-alias supplies `alias_uuid`).
#' @keywords internal
#' @noRd
.ct_row_feature_keys <- function(con, clean) {
  n <- nrow(clean)
  pending <- .ct_pending_flag(clean, "feature_pending")
  ufa <- if ("uuid_feature_alias" %in% names(clean)) clean$uuid_feature_alias else rep(NA_character_, n)
  uf <- if ("uuid_feature" %in% names(clean)) clean$uuid_feature else rep(NA_character_, n)

  alias_uuid <- rep(NA_character_, n)
  match_feature <- rep(NA_character_, n)

  for (i in seq_len(n)) {
    if (pending[[i]]) {
      alias_uuid[[i]] <- ufa[[i]]              # match + create by alias uuid
    } else if (!is.na(ufa[[i]])) {
      alias_uuid[[i]] <- ufa[[i]]
      fr <- DBI::dbGetQuery(con, "SELECT uuid_feature FROM feature_alias WHERE uuid = ?",
                            params = list(ufa[[i]]))
      match_feature[[i]] <- if (nrow(fr) > 0) fr$uuid_feature[[1]] else NA_character_
    } else if (!is.na(uf[[i]])) {
      match_feature[[i]] <- uf[[i]]
      sa <- DBI::dbGetQuery(con,
        "SELECT uuid FROM feature_alias WHERE uuid_feature = ? AND kind = 'self'",
        params = list(uf[[i]]))
      alias_uuid[[i]] <- if (nrow(sa) > 0) sa$uuid[[1]] else NA_character_
    }
  }
  list(pending = pending, alias_uuid = alias_uuid, match_feature = match_feature)
}

#' Find an existing sample at A11 granularity, or create one (step 2)
#'
#' Reuse candidates are found by `uuid_feature_alias` (pending row) or by the
#' resolved feature (join `feature_alias`), then the R-11.18/A62 predicate
#' decides: create a NEW sample only when distinctness is provable - incoming
#' `sample_datetime` is non-NA AND every candidate datetime is non-NA AND none
#' equals the incoming one (two clock times at one feature+date are two
#' samplings). Otherwise REUSE (incoming NA, any candidate NA, or an equal
#' datetime -> uncertain identity, never fabricate a duplicate), preferring a
#' datetime-equal candidate.
#' @keywords internal
#' @noRd
.ct_find_or_create_sample <- function(con, pending, match_feature, alias_uuid,
                                       sample_date, sample_datetime,
                                       uuid_project, organisation, person, reason) {
  if (isTRUE(pending)) {
    cand <- DBI::dbGetQuery(
      con,
      'SELECT uuid, datetime FROM "sample" WHERE uuid_feature_alias = ? AND CAST(date AS DATE) = ?',
      params = list(alias_uuid, as.character(sample_date))
    )
  } else {
    cand <- DBI::dbGetQuery(
      con,
      'SELECT s.uuid, s.datetime FROM "sample" s
         JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
        WHERE fa.uuid_feature = ? AND CAST(s.date AS DATE) = ?',
      params = list(match_feature, as.character(sample_date))
    )
  }

  if (nrow(cand) > 0) {
    # Compare instants as epoch seconds so a tz-tagged incoming POSIXct and the
    # driver's UTC-returned candidate never raise a spurious "inconsistent
    # tzone" warning; equality of instants is tz-independent.
    inc_dt <- as.numeric(sample_datetime)
    cand_dt <- as.numeric(cand$datetime)
    create_new <- !is.na(inc_dt) &&
      all(!is.na(cand_dt)) &&
      !any(cand_dt == inc_dt)
    if (!create_new) {
      if (!is.na(inc_dt)) {
        match_dt <- !is.na(cand_dt) & (cand_dt == inc_dt)
        if (any(match_dt)) cand <- cand[match_dt, , drop = FALSE]
      }
      return(cand$uuid[[1]])
    }
  }

  new_uuid <- uuid::UUIDgenerate()
  # Store the calendar date as a naive midnight (tz = "UTC"), NOT AEST: the
  # duckdb driver converts a POSIXct to UTC on write, so midnight AEST would be
  # stored as the *previous* day's 14:00 and CAST(date AS DATE) would read back
  # one day early - misaligning with the naive-literal seed dates and breaking
  # cross-run sample reuse (a re-ingest can't find the day-early sample and
  # duplicates it). tz = "UTC" preserves the intended calendar day (A44).
  midnight <- as.POSIXct(paste(as.character(sample_date), "00:00:00"), tz = "UTC")
  row <- tibble::tibble(
    uuid = new_uuid, uuid_feature_alias = alias_uuid, uuid_project = uuid_project,
    date = midnight, date_start = as.POSIXct(NA), datetime = sample_datetime,
    datetime_start = as.POSIXct(NA), organisation = organisation, person = person,
    purpose = NA_character_, comments = NA_character_
  )
  db_append(con, "sample", row, actor = .ct_actor, reason = reason)
  new_uuid
}

#' Resolve every `clean` row's sample uuid (step 2)
#'
#' Iterates the distinct `(feature-or-alias, sample_date, sample_datetime)`
#' tuples of `clean` in row order, reusing the sample uuid already resolved
#' for an earlier row sharing the same tuple (writes made earlier in this
#' same transaction are visible to the `SELECT`s inside
#' `.ct_find_or_create_sample()`, so cross-tuple reuse via the DB round-trip
#' falls out for free too).
#'
#' @return character vector, one sample uuid per row of `clean`.
#' @keywords internal
#' @noRd
.ct_resolve_samples <- function(con, clean, uuid_project, reason) {
  n <- nrow(clean)
  sample_uuid <- rep(NA_character_, n)
  if (n == 0) {
    return(sample_uuid)
  }

  keys <- .ct_row_feature_keys(con, clean)
  mk <- ifelse(keys$pending, keys$alias_uuid, keys$match_feature)
  key <- paste(
    mk, as.character(clean$sample_date),
    ifelse(is.na(clean$sample_datetime), "NA", format(clean$sample_datetime, "%Y-%m-%d %H:%M:%S")),
    sep = "||"
  )
  resolved <- new.env(parent = emptyenv())

  for (i in seq_len(n)) {
    k <- key[[i]]
    uuid_i <- if (exists(k, envir = resolved, inherits = FALSE)) get(k, envir = resolved) else NULL
    if (is.null(uuid_i)) {
      uuid_i <- .ct_find_or_create_sample(
        con,
        pending = keys$pending[[i]],
        match_feature = keys$match_feature[[i]],
        alias_uuid = keys$alias_uuid[[i]],
        sample_date = clean$sample_date[[i]],
        sample_datetime = clean$sample_datetime[[i]],
        uuid_project = uuid_project,
        organisation = clean$org[[i]],
        person = clean$sampler[[i]],
        reason = reason
      )
      assign(k, uuid_i, envir = resolved)
    }
    sample_uuid[[i]] <- uuid_i
  }
  sample_uuid
}

# ---- step 3: analyses ---------------------------------------------------------

#' The matched method's `conversion_constant` (NA when none / no method).
#' @keywords internal
#' @noRd
.ct_method_conversion <- function(con, uuid_lab) {
  if (is.na(uuid_lab)) {
    return(NA_real_)
  }
  r <- DBI::dbGetQuery(con, "SELECT conversion_constant FROM lab_method WHERE uuid = ?",
                       params = list(uuid_lab))
  if (nrow(r) == 0) NA_real_ else r$conversion_constant[[1]]
}

#' Insert (or supersede-update) an analysis row for every `clean` row
#' (step 3). Rows with `supersedes` NA are inserted fresh; rows with a
#' non-NA `supersedes` update the existing analysis in place instead - with
#' `value` first in `changes` so it is the row DuckDB returns for
#' `ORDER BY "at" DESC LIMIT 1` ties within the one `db_update()` call.
#'
#' `quantified` is read straight off `clean$quantified` (R-11.16: from
#' `parse_value()`, NEVER re-derived from `below_detection`); the plan-09 shape
#' with no `quantified` column falls back to `below_detection`. `rl_high`
#' (R-11.16/F4) is written when present. The matched method's
#' `conversion_constant`, when non-NA, multiplies `value`/`rl_low`/`rl_high`
#' before the write (D7/A63); a pending-analyte row's dangling method has a NA
#' constant, so its value passes through unconverted.
#' @keywords internal
#' @noRd
.ct_commit_analyses <- function(con, clean, actor, reason) {
  n <- nrow(clean)
  if (n == 0) {
    return(invisible(NULL))
  }

  has_q <- "quantified" %in% names(clean)
  has_rh <- "rl_high" %in% names(clean)

  for (i in seq_len(n)) {
    # NA must SURVIVE. `isTRUE()` maps NA to FALSE, which silently recorded an
    # unknown/non-measurement detection state as "below detection" - see the
    # note in .st_parse_values(). The tri-state is real in the data.
    quantified <- if (has_q) {
      q <- clean$quantified[[i]]
      if (length(q) != 1L || is.na(q)) NA else isTRUE(q)
    } else {
      !isTRUE(clean$below_detection[[i]])
    }
    source_hash <- clean$source_hash[[i]]

    value <- clean$value_converted[[i]]
    rl_low <- clean$rl_converted[[i]]
    rl_high <- if (has_rh) clean$rl_high[[i]] else NA_real_

    cc <- .ct_method_conversion(con, clean$uuid_lab[[i]])
    if (!is.na(cc)) {
      if (!is.na(value)) value <- value * cc
      if (!is.na(rl_low)) rl_low <- rl_low * cc
      if (!is.na(rl_high)) rl_high <- rl_high * cc
    }

    if (is.na(clean$supersedes[[i]])) {
      new_uuid <- uuid::UUIDgenerate()
      new_row <- tibble::tibble(
        uuid = new_uuid, uuid_sample = clean$uuid_sample[[i]], uuid_lab = clean$uuid_lab[[i]],
        value = value, value_chr = clean$value_chr[[i]], quantified = quantified,
        rl_low = rl_low, rl_high = rl_high, comments = clean$comments[[i]]
      )
      db_append(con, "analysis", new_row, actor = actor, reason = reason, source_hash = source_hash)
    } else {
      changes <- list(
        value = value, value_chr = clean$value_chr[[i]],
        quantified = quantified, rl_low = rl_low
      )
      if (has_rh) changes$rl_high <- rl_high
      db_update(
        con, "analysis", uuid = clean$supersedes[[i]], changes = changes,
        actor = actor, reason = reason, source_hash = source_hash
      )
    }
  }
  invisible(NULL)
}

# ---- step 4: archive every file + already_present provenance -----------------

#' Archive every file listed on the event (kept AND superseded renderings
#' alike, per A13) via `archive_file()` (R-9.3). Looks up each file's
#' original path from `ingest_file.path_first_seen`.
#' @keywords internal
#' @noRd
.ct_archive_files <- function(con, event) {
  files <- event$files
  if (nrow(files) == 0) {
    return(invisible(NULL))
  }
  for (i in seq_len(nrow(files))) {
    hash <- files$hash[[i]]
    path_row <- DBI::dbGetQuery(con, "SELECT path_first_seen FROM ingest_file WHERE hash = ?", params = list(hash))
    if (nrow(path_row) == 0 || is.na(path_row$path_first_seen[[1]])) {
      next
    }
    archive_file(con, path_row$path_first_seen[[1]], hash, event)
  }
  invisible(NULL)
}

#' Resolve one `resolved$skipped` row's existing analysis uuid
#'
#' Reads the typed `existing_uuid` column (R-16.14): `already_present`
#' populates it directly (`.rq_skip()`, R/reconcile.R), so the regex that
#' used to parse a bare-uuid `payload` as a pass-through fallback is retired
#' - the equivalence (same uuid the regex used to recover, for the same
#' input) is asserted by the "R-16.14: .ct_skip_existing_uuid() returns the
#' analysis uuid a REAL reconcile_event() already_present skip carries"
#' block in test-commit.R (PLAN-16 Phase-7b/FA5), not assumed. A skip tibble
#' missing the column entirely (e.g. `.rc_qc_filter()`'s own output) is
#' covered by the sibling block in the same file: this function returns
#' `NA_character_`, not the old fallback's pass-through.
#' @keywords internal
#' @noRd
.ct_skip_existing_uuid <- function(skipped, i) {
  if ("existing_uuid" %in% names(skipped)) {
    val <- skipped$existing_uuid[[i]]
    if (!is.na(val)) {
      return(val)
    }
  }
  NA_character_
}

#' Write a provenance `change_log` row for every `already_present` skip
#' (step 4b): no new analysis, but a row linking the existing analysis to
#' this source_hash.
#' @keywords internal
#' @noRd
.ct_record_already_present <- function(con, skipped, actor, reason) {
  if (nrow(skipped) == 0 || !("reason" %in% names(skipped))) {
    return(invisible(NULL))
  }
  idx <- which(skipped$reason == "already_present")
  for (i in idx) {
    existing_uuid <- .ct_skip_existing_uuid(skipped, i)
    if (is.na(existing_uuid) || identical(existing_uuid, "")) {
      next
    }
    source_hash <- if ("source_hash" %in% names(skipped)) skipped$source_hash[[i]] else NA_character_
    .st_write_change_log(
      con, at = Sys.time(), actor = actor, action = "provenance", tbl = "analysis",
      uuid_row = existing_uuid, field = NA_character_, old = NA_character_, new = NA_character_,
      reason = reason, source_hash = source_hash
    )
  }
  invisible(NULL)
}

# ---- step 5: review queue ------------------------------------------------------

#' Append every `resolved$review` row to `review_queue` (step 5).
#' `work_order` always comes from the event, not the review tibble - the
#' real `reconcile_event()` review shape has no `work_order` column of its
#' own.
#'
#' Returns `review` with its own generated `uuid` column filled in (or added,
#' if absent), one per row, in the same order as inserted - the primary key
#' `.ct_rewrite_review_payloads()` keys its `UPDATE review_queue SET
#' uuid_alias = ?` on (PLAN-16 S-16.4). Must therefore run BEFORE that
#' rewrite so the row it updates already exists.
#' @keywords internal
#' @noRd
.ct_commit_review <- function(con, review, event, actor, reason) {
  n <- nrow(review)
  if (n == 0) {
    return(review)
  }
  if (!("uuid" %in% names(review))) {
    review$uuid <- NA_character_
  }
  # PLAN-16 Phase-7b (FB8): route through .rq_row() (B-16.api: "Both insert
  # paths route through it") instead of hand-building the row inline, so this
  # writer's column set/`status` default cannot drift from
  # review_queue_add()'s. `.rq_row()` also carries the typed columns
  # reconcile now populates (subkind / uuid_existing / uuid_alias) through to
  # review_queue -- reconcile moved this data OUT of the payload string and
  # INTO real columns, so a naive writer that only copied `payload` would
  # silently drop it. Defensive `%in%`: unconverted producers (still
  # legacy-migration pending) may omit a column, in which case it stores NA
  # rather than erroring.
  # Deliberately NOT overwriting: this function keeps generating its own
  # per-row `uuid` (not the review tibble's) and takes `work_order` from the
  # event, not the review row -- both passed straight into `.rq_row()`,
  # mirroring how `review_queue_add()` passes `work_order` through rather
  # than overwriting it after construction.
  #
  # PLAN-16 round-3 R-16.23 (this fix): a reconcile-side `candidates`
  # list-column (`.rc_review_row()`, R/reconcile.R) IS now written, when
  # present and non-empty, as `review_queue_candidate` child rows -- most
  # reconcile producers still deliberately route candidates through
  # `diagnostics$candidates` JSON instead (RULING-F: e.g. an ambiguous
  # `unknown_feature` item, whose feature uuids exist before any review row
  # does), but a producer that DOES call `.rc_review_row(candidates = ...)`/
  # `expired = ...)` must not have that data silently dropped a second time
  # here, the way it used to be dropped inside `.rc_review_row()` itself
  # before FG-3.
  #
  # The uuid mismatch this must handle: `.rq_row()` (inside `.rc_review_row()`)
  # mints its OWN `uuid_row` and stamps every child row's `uuid_review` with
  # it, at reconcile time -- long before this function mints the FRESH
  # `review_queue.uuid` (`row_uuid` below) the parent row is actually
  # inserted under. A child row carrying the constructor's uuid would be an
  # orphan referencing a `review_queue.uuid` that was never inserted, and
  # `review_queue_candidate.uuid_review` has a real FK to `review_queue(uuid)`
  # -- so the insert would fail outright. Every child row's `uuid_review` is
  # therefore overwritten with `row_uuid` immediately before it is persisted,
  # exactly the `cand$uuid_review <- uuid` rewrite `review_queue_add()`
  # (R/db-schema.R) already does for its own `candidates=` argument, and the
  # same "rewrite-to-the-actually-inserted-parent-uuid-before-persisting"
  # shape `.ct_rewrite_review_payloads()` below uses for `uuid_alias`.
  # `db_append()` (the sanctioned mutation-layer write path, A32/B-16.api;
  # NOT a raw DBI table-append call) keeps the write inside this same
  # `db_transaction()` call, so parent and children commit or roll back as
  # one unit.
  col_or_na <- function(nm, i) if (nm %in% names(review)) review[[nm]][[i]] else NA_character_
  has_candidates_col <- "candidates" %in% names(review)
  for (i in seq_len(n)) {
    source_hash <- if ("source_hash" %in% names(review)) review$source_hash[[i]] else NA_character_
    row_uuid <- uuid::UUIDgenerate()
    rq <- .rq_row(
      kind = review$kind[[i]], subkind = col_or_na("subkind", i),
      work_order = event$work_order, source_hash = source_hash,
      uuid_existing = col_or_na("uuid_existing", i),
      uuid_alias = col_or_na("uuid_alias", i)
    )
    row <- rq$review
    row$uuid <- row_uuid
    row$created_at <- Sys.time()
    row$payload <- review$payload[[i]]
    db_append(con, "review_queue", row, actor = actor, reason = reason, source_hash = source_hash)
    review$uuid[[i]] <- row_uuid

    if (has_candidates_col) {
      cand_i <- review$candidates[[i]]
      if (is.data.frame(cand_i) && nrow(cand_i) > 0) {
        cand_i$uuid_review <- row_uuid
        db_append(
          con, "review_queue_candidate", cand_i, actor = actor,
          reason = paste0(reason, ": review candidates"), source_hash = source_hash
        )
      }
    }
  }
  review
}

# ---- step 6: file states --------------------------------------------------------

#' Transition `ingest_file` states for the event's kept files (step 6)
#'
#' Only files currently in a non-terminal state (`reconciled`/
#' `needs_review`) are moved. When the event produced review items and zero
#' clean rows, files land on `needs_review`; otherwise they are committed
#' then immediately archived (this function is called from inside the same
#' transaction that archived their files in step 4). `kept == FALSE` files
#' are left alone - they are already `ignored`.
#' @keywords internal
#' @noRd
.ct_set_file_states <- function(con, files, n_clean, n_review, reason) {
  kept <- files[.ct_kept_rows(files), , drop = FALSE]
  if (nrow(kept) == 0) {
    return(invisible(NULL))
  }

  non_terminal <- c("reconciled", "needs_review")
  needs_review_only <- n_review > 0 && n_clean == 0

  for (h in kept$hash) {
    row <- DBI::dbGetQuery(con, "SELECT state FROM ingest_file WHERE hash = ?", params = list(h))
    if (nrow(row) == 0 || !(row$state[[1]] %in% non_terminal)) {
      next
    }
    if (needs_review_only) {
      ingest_file_set_state(con, h, "needs_review", reason = reason)
    } else {
      ingest_file_set_state(con, h, "committed", reason = reason)
      ingest_file_set_state(con, h, "archived", reason = reason)
    }
  }
  invisible(NULL)
}

# ---- top-level entry point -------------------------------------------------------

#' Atomically commit one reconciled event (R-9.2)
#'
#' Runs the whole commit inside one `db_transaction()` call so every write -
#' project/sample/analysis inserts and supersede-updates, archived-`asset`
#' rows, `already_present` provenance rows, `review_queue` inserts, and
#' `ingest_file` state transitions - either all land or none do. Order,
#' per PLAN-09 R-9.2: (1) project, (2) samples, (3) analyses, (4) archive
#' every file of the event + already_present provenance, (5) review items,
#' (6) file-state transitions.
#'
#' Before doing any work, aborts if a `kept` file of the event is already
#' `committed`/`archived` (a second call on the same event is a no-op
#' abort, not a duplicate commit).
#'
#' @param event a plan-07 event object (`work_order`, `files`, ...).
#' @param resolved plan-08 `reconcile_event()` output:
#'   `list(clean, review, skipped, counts)`.
#' @param con an open read-write DBI connection, already live - this
#'   function does NOT open its own connection via `with_db_write()` (A40);
#'   the caller holds `con` open across the call.
#' @return `NULL`, invisibly.
#' @keywords internal
#' @noRd
commit_event <- function(event, resolved, con) {
  checkmate::assert_list(event)
  checkmate::assert_list(resolved)

  reason <- paste0("commit_event: ", event$work_order)

  .ct_check_not_already_committed(con, event$files)

  db_transaction(con, function(con) {
    uuid_project <- .ct_ensure_project(con, event$work_order, reason)

    clean <- resolved$clean
    review <- resolved$review
    if (nrow(clean) > 0) {
      # Step 1b (R-11.8, D8): all pending-alias / dangling-method WRITES happen
      # here (reconcile stays read-only). Must precede sample resolution so a
      # newly-materialised alias uuid is available to key the sample by, and
      # the review-payload rewrite below (R-11.9/PLAN-16 S-16.4) so review
      # items carry a resolvable alias uuid.
      clean <- .ct_materialise_feature_aliases(con, clean, event, .ct_actor, reason)
      clean <- .ct_materialise_lab_methods(con, clean, event, .ct_actor, reason)

      clean$uuid_sample <- .ct_resolve_samples(con, clean, uuid_project, reason)
      # PLAN-15 C.4: provenance for every structural / WO-site-inferred
      # resolution, written once the sample uuid it attaches to exists.
      .ct_record_resolution_provenance(con, clean, .ct_actor)
    }
    .ct_commit_analyses(con, clean, .ct_actor, reason)

    .ct_archive_files(con, event)
    .ct_record_already_present(con, resolved$skipped, .ct_actor, reason)

    # review_queue rows are written FIRST, so each one's own uuid exists to
    # key the alias rewrite below (PLAN-16 S-16.4 keys UPDATE review_queue
    # SET uuid_alias = ? WHERE uuid = ?).
    review <- .ct_commit_review(con, review, event, .ct_actor, reason)
    if (nrow(clean) > 0) {
      review <- .ct_rewrite_review_payloads(con, review, clean)
    }

    .ct_set_file_states(con, event$files, nrow(clean), nrow(review), reason)

    invisible(NULL)
  })

  invisible(NULL)
}
