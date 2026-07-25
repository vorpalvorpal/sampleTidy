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
#
# ---------------------------------------------------------------------------
# GUARDED EXCEPTION to the one-transaction contract above
# (PLAN-15 F.14, ADJUDICATED 2026-07-24; the same limitation forces it on
#  E.8's `merge_identity_aliases()` and on F.19's identity-arm repoint.)
# ---------------------------------------------------------------------------
# duckdb 1.4.1 refuses to UPDATE a row's own outgoing-FK column (or DELETE
# the row) while ANY row in another table still references it - "Constraint
# Error: ... still referenced by a foreign key in a different table" - EVEN
# INSIDE ONE TRANSACTION, and even when the referencing rows were re-pointed
# by an earlier statement of that same transaction (verified empirically on
# purpose-built FK-constrained DuckDBs, twice in Phase 4 and again here for
# the `sample`/`feature_alias` shape). Migration 002 hit this first and
# documents it at `.mig002_detach_reason`; `.mig002_torn_guard()`
# (dev/migrations/002-registry-remediation.R:119) exists precisely BECAUSE
# the workaround cannot be atomic.
#
# So three paths here run their FK-sensitive statements as SEPARATELY
# COMMITTED mutation-layer calls, outside the surrounding transaction:
#   * `confirm_analyte_methods()` on a method that HAS dependent analyses
#     (F.14) - detach -> repoint `lab_method.uuid_analyte` -> reattach, in a
#     pre-pass before the one transaction opens.
#   * `confirm_feature_aliases()`'s identity branch (F.19) - re-pointing the
#     redundant arm's samples onto the surviving `self` arm, in a post-pass
#     after the one transaction commits.
#   * `merge_identity_aliases()` (E.8) - repoint-then-DELETE cannot be one
#     transaction for the same reason.
# Every step still goes through the mutation layer (db_update()/db_delete()),
# so every step is still in `change_log`. What is given up is atomicity ACROSS
# the steps; what buys that back is `.fa_torn_guard()`, which every entry
# point calls before writing and which ABORTS LOUDLY on re-entry if a prior
# run left an unpaired detach (modelled on `.mig002_torn_guard()`, and keyed
# off the byte-identical reason suffixes so the two guards see each other's
# torn runs).

# ======================================================================
# The duckdb chained-FK workaround (PLAN-15 F.14 / E.8) - see the guarded
# exception documented at the head of this file.
# ======================================================================

# The two `change_log.reason` suffixes the detach/reattach workaround
# appends. These are BYTE-IDENTICAL to `.mig002_detach_reason` /
# `.mig002_reattach_reason` (dev/migrations/002-registry-remediation.R:94-95)
# ON PURPOSE, and must stay so: dev/migrations/ is not part of the package,
# so the constants cannot be shared by reference, but a single shared audit
# vocabulary means `.mig002_torn_guard()` still detects a run torn by THIS
# code and `.fa_torn_guard()` still detects one torn by 002. Changing either
# copy without the other silently blinds both guards.
.fa_detach_reason <- "(temporary FK detach, duckdb 1.4.1 chained-FK limitation)"
.fa_reattach_reason <- "(FK reattach, duckdb 1.4.1 chained-FK limitation)"

#' Pre-flight guard: abort loudly if a prior FK detach/reattach run was torn
#'
#' Modelled on `.mig002_torn_guard()` and generalised over (tbl, field): a
#' crash between a committed detach (child FK column -> NULL) and its
#' matching reattach leaves that child row PERMANENTLY orphaned, and a fresh
#' re-run cannot see it (the dependent lookup that would find it reads the
#' very column that is now NULL), so the re-run would no-op and report
#' success while the orphan stays orphaned. Keyed off this code's OWN
#' `change_log` trail rather than "FK column IS NULL", which is a legitimate
#' state, so it cannot false-positive: only an UNPAIRED detach is torn.
#'
#' @param con an open DBI connection (read-only is fine).
#' @return invisible(NULL); aborts (`class = "sampletidy_error"`) if torn.
#' @keywords internal
#' @noRd
.fa_torn_guard <- function(con) {
  like_detach <- paste0("%", .fa_detach_reason)
  like_reattach <- paste0("%", .fa_reattach_reason)

  counts <- DBI::dbGetQuery(
    con,
    "SELECT tbl, field,
            SUM(CASE WHEN reason LIKE ? THEN 1 ELSE 0 END) AS n_detach,
            SUM(CASE WHEN reason LIKE ? THEN 1 ELSE 0 END) AS n_reattach
       FROM change_log
      WHERE reason LIKE ? OR reason LIKE ?
      GROUP BY tbl, field",
    params = list(like_detach, like_reattach, like_detach, like_reattach)
  )

  torn <- counts[counts$n_detach > counts$n_reattach, , drop = FALSE]
  if (nrow(torn) > 0) {
    detail <- paste(
      sprintf(
        "%s.%s: %d detach row(s) but only %d reattach row(s)",
        torn$tbl, torn$field, as.integer(torn$n_detach), as.integer(torn$n_reattach)
      ),
      collapse = "; "
    )
    cli::cli_abort(c(
      "This database is from an INTERRUPTED foreign-key detach/reattach run.",
      "x" = "{detail} - an unpaired detach, left by a run that crashed mid-workaround.",
      "i" = "Re-running cannot recover it: the detached row(s) are invisible to a fresh dependent lookup and would stay detached forever.",
      "i" = "Restore from the pre-run backup/snapshot, then re-run.",
      "i" = "See the guarded-exception note at the head of R/feature-alias.R and `.mig002_torn_guard()`."
    ), class = "sampletidy_error")
  }

  invisible(NULL)
}

#' This table's own outgoing foreign-key columns, per the duckdb catalog.
#' Returns `character(0)` when the catalog cannot be read or the table
#' declares no FKs (e.g. the shared test DDL, which declares none at all -
#' that is exactly why those fixtures never reproduce this defect).
#' @keywords internal
#' @noRd
.fa_fk_columns <- function(con, table) {
  rows <- tryCatch(
    DBI::dbGetQuery(
      con,
      "SELECT constraint_column_names FROM duckdb_constraints()
        WHERE constraint_type = 'FOREIGN KEY' AND table_name = ?",
      params = list(table)
    ),
    error = function(e) NULL
  )
  if (is.null(rows) || nrow(rows) == 0) {
    return(character(0))
  }
  unique(unlist(rows$constraint_column_names, use.names = FALSE))
}

#' Rows in other tables whose FK currently references `uuid` in `table`.
#' One list element per (child table, child column) that actually has rows.
#' A child table without a `uuid` column is skipped - it cannot be keyed
#' through the mutation layer, so the detach dance is not available for it
#' and the caller's UPDATE will simply fail loudly, which is the honest
#' outcome.
#' @keywords internal
#' @noRd
.fa_fk_dependents <- function(con, table, uuid) {
  children <- tryCatch(
    DBI::dbGetQuery(
      con,
      "SELECT table_name, constraint_column_names FROM duckdb_constraints()
        WHERE constraint_type = 'FOREIGN KEY' AND referenced_table = ?",
      params = list(table)
    ),
    error = function(e) NULL
  )
  if (is.null(children) || nrow(children) == 0) {
    return(list())
  }

  out <- list()
  for (i in seq_len(nrow(children))) {
    child_table <- children$table_name[[i]]
    if (!DBI::dbExistsTable(con, child_table)) next
    fields <- DBI::dbListFields(con, child_table)
    if (!"uuid" %in% fields) next
    for (child_col in unlist(children$constraint_column_names[[i]], use.names = FALSE)) {
      if (!child_col %in% fields) next
      rows <- DBI::dbGetQuery(
        con,
        sprintf(
          "SELECT uuid FROM %s WHERE %s = ?",
          DBI::dbQuoteIdentifier(con, child_table),
          DBI::dbQuoteIdentifier(con, child_col)
        ),
        params = list(uuid)
      )
      if (nrow(rows) > 0) {
        out[[length(out) + 1L]] <- list(table = child_table, column = child_col, uuids = rows$uuid)
      }
    }
  }
  out
}

#' A one-entry named list - `changes` for a single-column db_update().
#' (Hand-built rather than `stats::setNames()`: `stats` is not in the
#' CONTRACT-pinned DESCRIPTION Imports and R-10.6 gates that list.)
#' @keywords internal
#' @noRd
.fa_named <- function(name, value) {
  out <- list(value)
  names(out) <- name
  out
}

#' Does updating `columns` on this row need the detach/reattach dance?
#' Only when the change touches one of the row's OWN outgoing-FK columns AND
#' something still references the row. Both halves matter: without the first
#' every ordinary UPDATE would pay for the workaround; without the second the
#' workaround runs (and writes change_log noise) where a plain UPDATE works.
#' @keywords internal
#' @noRd
.fa_needs_fk_dance <- function(con, table, uuid, columns) {
  if (!any(columns %in% .fa_fk_columns(con, table))) {
    return(FALSE)
  }
  length(.fa_fk_dependents(con, table, uuid)) > 0
}

#' Update a row that other rows may reference, working around duckdb's
#' chained-FK limitation: detach the referencing rows, update, reattach -
#' migration 002's loop, verbatim, tagged with its reason suffixes.
#'
#' MUST NOT be called inside an open mutation-layer transaction when the
#' dance is required: each step has to commit on its own (that is the whole
#' point), so an outer transaction would defeat it silently. Asserted, not
#' assumed. When no dance is needed this is a plain `db_update()` and
#' participates in whatever transaction the caller has open.
#' @keywords internal
#' @noRd
.fa_guarded_update <- function(con, table, uuid, changes, actor, reason) {
  if (!.fa_needs_fk_dance(con, table, uuid, names(changes))) {
    db_update(con, table, uuid, changes = changes, actor = actor, reason = reason)
    return(invisible(0L))
  }

  if (.st_in_txn(con)) {
    cli::cli_abort(
      paste0(
        "Internal error: the duckdb FK detach/reattach workaround for '", table,
        "' was reached inside an open mutation transaction, where its steps ",
        "cannot commit separately. See the guarded-exception note at the head ",
        "of R/feature-alias.R."
      ),
      class = "sampletidy_error"
    )
  }

  deps <- .fa_fk_dependents(con, table, uuid)
  n <- 0L
  for (d in deps) {
    for (u in d$uuids) {
      db_update(
        con, d$table, u, changes = .fa_named(d$column, NA_character_),
        actor = actor, reason = paste(reason, .fa_detach_reason)
      )
      n <- n + 1L
    }
  }
  db_update(con, table, uuid, changes = changes, actor = actor, reason = reason)
  for (d in deps) {
    for (u in d$uuids) {
      db_update(
        con, d$table, u, changes = .fa_named(d$column, uuid),
        actor = actor, reason = paste(reason, .fa_reattach_reason)
      )
    }
  }
  invisible(n)
}

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
#' PLAN-15 E.4 adds `date_start` / `date_end` validity bounds and a
#' bounds-only call (`uuid_feature` omitted); PLAN-15 F.19 adds `kind` and
#' stops an identity mapping (`alias_key == lower(feature.name)`) from
#' minting a second arm alongside the feature's own `self` arm.
#'
#' THE E.4 SENTINEL SCHEME (pinned in PLAN-15 B-15.E4, ratified 2026-07-24):
#' `NULL` - the default, and what every pre-E.4 caller gets for free - leaves
#' the stored bound ALONE; `as.Date(NA)` CLEARS it; a real `Date` SETS it.
#' Bare `NA` is deliberately not a sentinel here: on `uuid_feature` it is
#' already spoken for as "reject". Bounds are DATE, never POSIXct - a
#' POSIXct bound is rejected rather than silently truncated at the driver
#' boundary.
#'
#' @param uuid_alias character vector of `feature_alias.uuid`.
#' @param uuid_feature character vector of `feature.uuid`, same length as
#'   `uuid_alias`. `NA` is rejected (a feature must exist). OMIT it entirely
#'   (the `NULL` default) for a bounds-only call: the stored `uuid_feature`
#'   is then left untouched and no feature is re-picked (E.4).
#' @param confirmed_by who is confirming - mandatory, no default (A55).
#' @param override if `TRUE`, a collision (linking would put two `sample`
#'   rows on the same (feature, date)) is merged rather than aborted (D5).
#' @param db path to the DuckDB file; defaults to `st_config("live_db")`.
#' @param kind the relationship being confirmed, one of `self`,
#'   `historical_code`, `mask_long`, `descriptive`, `transcription_error`
#'   (F.19). Never supply it for an identity mapping - that arm is `self` by
#'   construction and passing a `kind` alongside it is an error, not a silent
#'   override.
#' @param date_start,date_end validity bounds (E.4). `NULL` leaves the stored
#'   bound alone, `as.Date(NA)` clears it, a real `Date` sets it.
#' @return `invisible(tibble(uuid_alias, uuid_feature, n_samples, action))`.
#' @export
confirm_feature_aliases <- function(uuid_alias, uuid_feature = NULL, confirmed_by,
                                     override = FALSE, db = st_config("live_db"),
                                     kind = NULL, date_start = NULL, date_end = NULL) {
  checkmate::assert_character(uuid_alias)
  checkmate::assert_string(confirmed_by)
  checkmate::assert_flag(override)
  checkmate::assert_string(db)

  bounds_only <- is.null(uuid_feature)
  if (!bounds_only) {
    checkmate::assert_character(uuid_feature)
    if (length(uuid_alias) != length(uuid_feature)) {
      cli::cli_abort(
        "uuid_alias and uuid_feature must be the same length ({length(uuid_alias)} vs {length(uuid_feature)}).",
        class = "sampletidy_error"
      )
    }
  }

  kind <- .fa_check_kind(kind)
  date_start <- .fa_check_bound(date_start, "date_start")
  date_end <- .fa_check_bound(date_end, "date_end")

  if (length(uuid_alias) == 0) {
    return(invisible(tibble::tibble(
      uuid_alias = character(0), uuid_feature = character(0),
      n_samples = integer(0), action = character(0)
    )))
  }

  result <- with_db_write(
    function(con) {
      .fa_torn_guard(con)

      out <- db_transaction(con, function(con) {
        rows <- purrr::map(seq_along(uuid_alias), function(i) {
          .fa_confirm_one_alias(
            con, uuid_alias[[i]],
            if (bounds_only) NULL else uuid_feature[[i]],
            confirmed_by = confirmed_by, override = override,
            kind = kind, date_start = date_start, date_end = date_end
          )
        })
        dplyr::bind_rows(rows)
      })

      # F.19 identity branch, GUARDED EXCEPTION (see the head of this file):
      # any sample still hanging off the redundant arm is re-pointed onto the
      # surviving `self` arm, so a confirmation is never silently ineffective.
      # It runs AFTER the transaction commits because on a real FK-constrained
      # database each repoint may need duckdb's detach/reattach dance, whose
      # steps must commit separately. Deliberately after, not before, so the
      # D5 collision analysis inside the transaction still sees the samples
      # exactly where they were.
      for (i in seq_len(nrow(out))) {
        if (!is.na(out$uuid_self_arm[[i]])) {
          .fa_repoint_samples(
            con, from = out$uuid_alias[[i]], to = out$uuid_self_arm[[i]],
            actor = confirmed_by
          )
        }
      }

      out[, c("uuid_alias", "uuid_feature", "n_samples", "action")]
    },
    db = db
  )

  invisible(result)
}

#' Validate the F.19 `kind` argument against the registry vocabulary.
#' `NULL` (not supplied) passes through; a typo fails loudly rather than
#' entering the registry.
#' @keywords internal
#' @noRd
.fa_check_kind <- function(kind) {
  if (is.null(kind)) {
    return(NULL)
  }
  checkmate::assert_string(kind)
  if (!kind %in% .fa_kind_vocabulary) {
    cli::cli_abort(
      "kind must be one of {.val {.fa_kind_vocabulary}}, not {.val {kind}}.",
      class = "sampletidy_error"
    )
  }
  kind
}

.fa_kind_vocabulary <- c(
  "self", "historical_code", "mask_long", "descriptive", "transcription_error"
)

#' Validate one E.4 bound argument. Returns `NULL` for leave-alone, else a
#' length-1 `Date` (possibly `NA`, the clear sentinel).
#' @keywords internal
#' @noRd
.fa_check_bound <- function(x, name) {
  if (is.null(x)) {
    return(NULL)
  }
  if (inherits(x, "POSIXt")) {
    cli::cli_abort(
      paste0(
        "`", name, "` must be a Date, not a POSIXct/POSIXlt - `feature_alias.",
        name, "` is a DATE column and a datetime round-trips through the ",
        "driver as a truncated date."
      ),
      class = "sampletidy_error"
    )
  }
  if (!inherits(x, "Date")) {
    cli::cli_abort(
      paste0(
        "`", name, "` must be a Date: NULL leaves the stored bound alone, ",
        "as.Date(NA) clears it, a real Date sets it."
      ),
      class = "sampletidy_error"
    )
  }
  if (length(x) != 1) {
    cli::cli_abort(
      "`{name}` must be length 1, not {length(x)}.",
      class = "sampletidy_error"
    )
  }
  x
}

#' The bound half of a `changes` list: only the bounds the caller actually
#' spoke about (E.4 - `NULL` means leave alone, so it contributes nothing).
#' @keywords internal
#' @noRd
.fa_bound_changes <- function(date_start, date_end) {
  changes <- list()
  if (!is.null(date_start)) changes$date_start <- date_start
  if (!is.null(date_end)) changes$date_end <- date_end
  changes
}

#' Re-point every sample on `from` onto `to` (F.19 / E.8). Separately
#' committed per sample via `.fa_guarded_update()` - see the guarded
#' exception at the head of this file.
#' @keywords internal
#' @noRd
.fa_repoint_samples <- function(con, from, to, actor, reason = NULL) {
  if (is.null(reason)) {
    reason <- paste0(
      "identity alias: sample re-pointed from the redundant arm '", from,
      "' onto the surviving self arm '", to, "'"
    )
  }
  samples <- DBI::dbGetQuery(
    con, 'SELECT uuid FROM "sample" WHERE uuid_feature_alias = ?', params = list(from)
  )$uuid
  for (u in samples) {
    .fa_guarded_update(
      con, "sample", u, changes = list(uuid_feature_alias = to),
      actor = actor, reason = reason
    )
  }
  invisible(length(samples))
}

#' Confirm exactly one (uuid_alias, uuid_feature) pair. `uuid_feature = NULL`
#' is the E.4 bounds-only call.
#' @keywords internal
#' @noRd
.fa_confirm_one_alias <- function(con, uuid_alias, uuid_feature, confirmed_by, override,
                                   kind = NULL, date_start = NULL, date_end = NULL) {
  alias <- DBI::dbGetQuery(con, "SELECT * FROM feature_alias WHERE uuid = ?", params = list(uuid_alias))
  if (nrow(alias) == 0) {
    cli::cli_abort("No feature_alias with uuid '{uuid_alias}'.", class = "sampletidy_error")
  }
  bounds <- .fa_bound_changes(date_start, date_end)

  # ---- E.4: the bounds-only call (uuid_feature omitted) ----
  # Widen/clear a bound without re-picking a feature. No feature lookup, no
  # collision analysis, no kind: nothing about the resolution changes.
  if (is.null(uuid_feature)) {
    if (!is.null(kind)) {
      cli::cli_abort(
        paste0(
          "`kind` cannot be supplied on a bounds-only call (alias '", uuid_alias,
          "'): no relationship is being confirmed, only a validity bound changed."
        ),
        class = "sampletidy_error"
      )
    }
    if (length(bounds) == 0) {
      cli::cli_abort(
        paste0(
          "Nothing to do for alias '", uuid_alias, "': `uuid_feature` was omitted ",
          "and neither `date_start` nor `date_end` was supplied."
        ),
        class = "sampletidy_error"
      )
    }
    n_samples <- DBI::dbGetQuery(
      con, 'SELECT count(*) AS n FROM "sample" WHERE uuid_feature_alias = ?',
      params = list(uuid_alias)
    )$n[[1]]
    db_update(
      con, "feature_alias", uuid_alias,
      changes = c(list(confirmed_by = confirmed_by, auto_assign = TRUE), bounds),
      actor = confirmed_by, reason = "confirm_feature_aliases(): validity bounds"
    )
    return(tibble::tibble(
      uuid_alias = uuid_alias,
      uuid_feature = as.character(alias$uuid_feature[[1]]),
      n_samples = n_samples, action = "bounds_updated",
      uuid_self_arm = NA_character_
    ))
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

  # ---- F.19: is this an IDENTITY mapping? ----
  # `alias_key == lower(feature.name)` - the string is the feature's own name,
  # spelled correctly. Definitionally not a transcription error, and the arm
  # that already carries it is the feature's `self` arm (R1).
  is_identity <- !is.na(feature$name[[1]]) &&
    identical(alias$alias_key[[1]], tolower(feature$name[[1]]))

  self_arm <- NA_character_
  if (is_identity) {
    if (!is.null(kind)) {
      cli::cli_abort(
        paste0(
          "Alias '", uuid_alias, "' is an identity mapping onto feature '", uuid_feature,
          "' (alias_key == lower(feature.name)), which is 'self' by construction; ",
          "passing kind = '", kind, "' alongside it is an error, not an override."
        ),
        class = "sampletidy_error"
      )
    }
    arms <- DBI::dbGetQuery(
      con,
      "SELECT * FROM feature_alias
        WHERE uuid_feature = ? AND alias_key = ? AND kind = 'self'
        ORDER BY uuid",
      params = list(uuid_feature, alias$alias_key[[1]])
    )
    if (nrow(arms) > 0 && !identical(arms$uuid[[1]], uuid_alias)) {
      self_arm <- arms$uuid[[1]]
    }
  }

  if (!is.na(self_arm)) {
    # F.19 requirement 1: flip the EXISTING self arm rather than minting a
    # duplicate. Under R1 that arm is already auto_assign = TRUE, so in the
    # common case this is a no-op plus a confirmed_by. The redundant arm is
    # deliberately NOT written to (writing uuid_feature onto it is exactly how
    # the b.s01/k.e02 duplicates E.8 cleans up came to exist) and deliberately
    # NOT deleted here - collapsing an existing duplicate is
    # `merge_identity_aliases()`'s job, itemised and auditable. Its samples are
    # re-pointed onto the survivor by the post-pass in the caller.
    db_update(
      con, "feature_alias", self_arm,
      changes = c(list(confirmed_by = confirmed_by, auto_assign = TRUE), bounds),
      actor = confirmed_by,
      reason = paste0(
        "confirm_feature_aliases(): identity mapping confirmed on the feature's ",
        "existing self arm (redundant arm '", uuid_alias, "' left unresolved, F.19)"
      )
    )
    action <- "self_arm"
  } else {
    changes <- c(
      list(uuid_feature = uuid_feature, confirmed_by = confirmed_by, auto_assign = TRUE),
      bounds
    )
    if (is_identity) {
      # An identity mapping with no other self arm for the key: this row IS
      # the feature's self arm. Label it honestly rather than inventing a
      # relationship (F.19 requirement 2).
      if (!identical(alias$kind[[1]], "self")) {
        changes$kind <- "self"
      }
    } else if (!is.null(kind)) {
      changes$kind <- kind
    } else if (identical(alias$kind[[1]], "pending")) {
      # A non-identity confirmation with no explicit `kind` defaults to
      # `transcription_error`. RULED BY ROBIN 2026-07-26, overriding the
      # non-identity half of PCR-5 (F.19, 2026-07-24), which had said this
      # must abort with no default.
      #
      # PCR-5 contradicted R-11.10, green since PLAN-11, which pins this exact
      # shape SUCCEEDING with this default: fa-0010 ('t.s09' -> f-0002 named
      # 'T.S02') is non-identity too, so no discriminator separates the two
      # fixtures. PCR-5 was written for F.19's IDENTITY branch and its
      # non-identity half was uncosted collateral.
      #
      # Resolved toward the shipped behaviour on two grounds. A transcription
      # variant is the honest majority case for a pending non-identity alias.
      # And `kind` is provenance only - the sole production branch on it
      # anywhere is `kind == "self"` (reconcile.R:632, :653); nothing reads
      # historical_code vs transcription_error, not reconcile, not commit, not
      # migration 002, not merge_identity_aliases(). Erroring here would have
      # broken a shipped public API to protect a field with no reader.
      #
      # Accepted residual: a `descriptive` or `mask_long` name confirmed
      # without `kind` is recorded as a typo when nobody mistyped. Callers who
      # care pass `kind`; it round-trips verbatim (the branch above).
      changes$kind <- "transcription_error"
    }
    db_update(
      con, "feature_alias", uuid_alias, changes = changes,
      actor = confirmed_by, reason = "confirm_feature_aliases()"
    )
    action <- "confirmed"
  }

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
    n_samples = n_samples, action = action, uuid_self_arm = self_arm
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
        # value_existing/value_incoming/value_chr_existing/value_chr_incoming
        # (round-2 FD4: the text side of a tri-state measurement is carried
        # too, or a text-vs-text conflict is unadjudicable - two nulls).
        # Unlike that producer, the incoming side here IS a real analysis
        # row (`la`) - but its uuid is deliberately NOT surfaced as a
        # diagnostics key (no uuid_new/uuid_incoming), to keep the shared
        # vocabulary identical; it remains discoverable via change_log's
        # "re-pointed" row above.
        review_row <- .rq_row(
          kind = "value_conflict", subkind = "alias_merge",
          uuid_existing = ex$uuid,
          diagnostics = list(
            value_existing = ex$value, value_incoming = la$value,
            value_chr_existing = ex$value_chr, value_chr_incoming = la$value_chr
          )
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
# PLAN-15 E.8 merge_identity_aliases()
# ======================================================================

#' The identity duplicates E.8 collapses: for one `alias_key`, a `kind =
#' 'self'` arm and a distinct NON-self arm, BOTH pointing at the SAME
#' feature, where the key IS that feature's own lower-cased name.
#'
#' The same-feature restriction is load-bearing, not incidental: an alias key
#' that is one feature's real name while a second arm carrying it points at a
#' DIFFERENT feature is the ordinary historical/descriptive shape E.5/E.7/003
#' exist to preserve, and merging it would delete curated registry knowledge.
#' @keywords internal
#' @noRd
.fa_identity_duplicates <- function(con) {
  DBI::dbGetQuery(
    con,
    "SELECT s.alias_key       AS alias_key,
            s.uuid            AS uuid_winner,
            d.uuid            AS uuid_loser,
            s.confirmed_by    AS winner_confirmed_by,
            d.confirmed_by    AS loser_confirmed_by
       FROM feature_alias s
       JOIN feature f
         ON f.uuid = s.uuid_feature
       JOIN feature_alias d
         ON d.alias_key = s.alias_key
        AND d.uuid_feature = s.uuid_feature
        AND d.uuid <> s.uuid
      WHERE s.kind = 'self'
        AND (d.kind IS NULL OR d.kind <> 'self')
        AND s.alias_key = lower(f.name)
      ORDER BY s.alias_key, d.uuid"
  )
}

#' Collapse a redundant identity alias into the feature's `self` arm (E.8)
#'
#' For every `alias_key` holding both a `kind = 'self'` arm and a distinct
#' non-self arm pointing at the SAME feature, where the key is that feature's
#' own lower-cased name: carry the `confirmed_by` and `auto_assign = TRUE`
#' onto the surviving self arm, re-point every `sample.uuid_feature_alias`
#' reference off the redundant arm, then delete it. The two rows this exists
#' to remove (`b.s01` -> B.S01 and `k.e02` -> K.E02) are identity mappings
#' mislabelled `transcription_error` at the 2026-07-23 cutover, before F.19
#' fixed the labelling; with F.19 in place this is a one-time backfill rather
#' than a recurring chore.
#'
#' TRANSACTIONALITY: this is one of the guarded exceptions documented at the
#' head of this file. duckdb 1.4.1 will not DELETE a `feature_alias` row while
#' a `sample` still references it EVEN IF that sample was re-pointed by an
#' earlier statement of the same transaction (verified), so repoint and delete
#' must commit separately. Every interruption point is recoverable by simply
#' re-running: an interruption after the repoint leaves a duplicate arm with
#' no samples, which the next run merges and deletes; an interruption inside
#' the FK detach/reattach dance is caught by `.fa_torn_guard()` on re-entry.
#'
#' @param db path to the DuckDB file; defaults to `st_config("live_db")`.
#' @param actor who is running the merge - mandatory, no default: this DELETEs
#'   registry rows and re-points `sample`, and every `change_log` row it
#'   writes needs an honest actor.
#' @param dry_run if `TRUE`, write nothing and return the same itemised
#'   tibble a real run would.
#' @return `tibble(alias_key, uuid_winner, uuid_loser, n_repointed)`, one row
#'   per merged duplicate.
#' @export
merge_identity_aliases <- function(db = st_config("live_db"), actor, dry_run = FALSE) {
  checkmate::assert_string(db)
  checkmate::assert_string(actor)
  checkmate::assert_flag(dry_run)

  with_db_write(
    function(con) {
      .fa_torn_guard(con)

      cand <- .fa_identity_duplicates(con)
      if (nrow(cand) == 0) {
        return(tibble::tibble(
          alias_key = character(0), uuid_winner = character(0),
          uuid_loser = character(0), n_repointed = integer(0)
        ))
      }

      rows <- vector("list", nrow(cand))
      for (i in seq_len(nrow(cand))) {
        winner <- cand$uuid_winner[[i]]
        loser <- cand$uuid_loser[[i]]

        n_repointed <- DBI::dbGetQuery(
          con, 'SELECT count(*) AS n FROM "sample" WHERE uuid_feature_alias = ?',
          params = list(loser)
        )$n[[1]]

        if (!dry_run) {
          .fa_repoint_samples(
            con, from = loser, to = winner, actor = actor,
            reason = paste0(
              "merge_identity_aliases(): sample re-pointed from redundant identity arm '",
              loser, "' onto surviving self arm '", winner, "' (E.8)"
            )
          )

          changes <- list(auto_assign = TRUE)
          if (is.na(cand$winner_confirmed_by[[i]]) && !is.na(cand$loser_confirmed_by[[i]])) {
            changes$confirmed_by <- cand$loser_confirmed_by[[i]]
          }
          db_update(
            con, "feature_alias", winner, changes = changes, actor = actor,
            reason = paste0(
              "merge_identity_aliases(): confirmed_by/auto_assign carried onto the ",
              "surviving self arm from '", loser, "' (E.8)"
            )
          )

          db_delete(
            con, "feature_alias", loser, actor = actor,
            reason = paste0(
              "merge_identity_aliases(): redundant identity arm merged into self arm '",
              winner, "' and deleted (E.8)"
            )
          )
        }

        rows[[i]] <- tibble::tibble(
          alias_key = cand$alias_key[[i]], uuid_winner = winner,
          uuid_loser = loser, n_repointed = as.integer(n_repointed)
        )
      }

      dplyr::bind_rows(rows)
    },
    db = db
  )
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
      .fa_torn_guard(con)

      # F.14, GUARDED EXCEPTION (see the head of this file): on a real
      # FK-constrained database duckdb refuses to move
      # `lab_method.uuid_analyte` while any `analysis` still references the
      # method - which is every method that arrived with data, i.e. the
      # normal case. The detach -> repoint -> reattach loop that works around
      # it needs separately committed statements, so it runs here, BEFORE the
      # one transaction opens, and only for the items that actually need it.
      repointed <- vapply(
        seq_along(uuid_lab),
        function(i) .am_fk_prerepoint(con, uuid_lab[[i]], uuid_analyte[[i]], confirmed_by),
        logical(1)
      )

      db_transaction(con, function(con) {
        rows <- purrr::map(seq_along(uuid_lab), function(i) {
          .am_confirm_one_method(
            con, uuid_lab[[i]], uuid_analyte[[i]], confirmed_by = confirmed_by,
            repointed = repointed[[i]]
          )
        })
        dplyr::bind_rows(rows)
      })
    },
    db = db
  )

  invisible(result)
}

#' Every distinct `units` value ever recorded for this method in
#' `change_log` (RULED PIN drift-detection mechanism). >1 means drift.
#' @keywords internal
#' @noRd
.am_units_drift <- function(con, uuid_lab) {
  DBI::dbGetQuery(
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
}

#' F.14 pre-pass: move `lab_method.uuid_analyte` with duckdb's FK
#' detach/reattach dance, in separately committed statements, for the one
#' case that needs it - a method with dependent analyses on a database that
#' really declares the analyte <- lab_method <- analysis chain.
#'
#' Returns TRUE only if it actually moved the column; the caller then tells
#' `.am_confirm_one_method()` to skip its own `lab_method` UPDATE (and not to
#' mistake the already-moved column for an idempotent re-confirm, which would
#' skip the unit conversion). Every reason NOT to act here - a missing
#' method/analyte, an NA analyte, an already-set `uuid_analyte`, units drift,
#' no dependents, or no declared FK - returns FALSE and leaves the ordinary
#' in-transaction path to do exactly what it does today, INCLUDING raising
#' each of those errors with an empty database behind it.
#' @keywords internal
#' @noRd
.am_fk_prerepoint <- function(con, uuid_lab, uuid_analyte, confirmed_by) {
  if (is.na(uuid_analyte)) {
    return(FALSE)
  }
  method <- DBI::dbGetQuery(con, "SELECT * FROM lab_method WHERE uuid = ?", params = list(uuid_lab))
  if (nrow(method) == 0 || !is.na(method$uuid_analyte[[1]])) {
    return(FALSE)
  }
  analyte <- DBI::dbGetQuery(con, "SELECT uuid FROM analyte WHERE uuid = ?", params = list(uuid_analyte))
  if (nrow(analyte) == 0) {
    return(FALSE)
  }
  if (length(.am_units_drift(con, uuid_lab)) > 1) {
    return(FALSE)
  }
  if (!.fa_needs_fk_dance(con, "lab_method", uuid_lab, "uuid_analyte")) {
    return(FALSE)
  }

  .fa_guarded_update(
    con, "lab_method", uuid_lab, changes = list(uuid_analyte = uuid_analyte),
    actor = confirmed_by, reason = "confirm_analyte_methods()"
  )
  TRUE
}

#' Confirm exactly one (uuid_lab, uuid_analyte) pair. `repointed = TRUE` when
#' the F.14 pre-pass has already moved `lab_method.uuid_analyte` outside this
#' transaction (see `.am_fk_prerepoint()`).
#' @keywords internal
#' @noRd
.am_confirm_one_method <- function(con, uuid_lab, uuid_analyte, confirmed_by,
                                    repointed = FALSE) {
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
  if (!repointed && !is.na(current_analyte) && identical(current_analyte, uuid_analyte)) {
    return(tibble::tibble(
      uuid_lab = uuid_lab, uuid_analyte = uuid_analyte,
      n_analyses = n_analyses, n_converted = 0L, action = "already_confirmed"
    ))
  }

  if (!repointed && !is.na(current_analyte) && !identical(current_analyte, uuid_analyte)) {
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
  drift_units <- .am_units_drift(con, uuid_lab)

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

  if (!repointed) {
    db_update(
      con, "lab_method", uuid_lab, changes = list(uuid_analyte = uuid_analyte),
      actor = confirmed_by, reason = "confirm_analyte_methods()"
    )
  }

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
