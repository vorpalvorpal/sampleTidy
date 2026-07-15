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

# ---- step 2: samples ----------------------------------------------------------

#' Find an existing sample at A11 granularity, or create one (step 2)
#'
#' A11: match on `uuid_feature` + `date` first; when the incoming
#' `sample_datetime` is non-NA and more than one date-level candidate exists,
#' narrow to a `datetime`-equal candidate. Creates a new row (organisation =
#' the row's `org`, person = the row's `sampler`) when nothing matches.
#' @keywords internal
#' @noRd
.ct_find_or_create_sample <- function(con, uuid_feature, sample_date, sample_datetime,
                                       uuid_project, organisation, person, reason) {
  cand <- DBI::dbGetQuery(
    con,
    'SELECT uuid, datetime FROM "sample" WHERE uuid_feature = ? AND CAST(date AS DATE) = ?',
    params = list(uuid_feature, as.character(sample_date))
  )
  if (nrow(cand) > 0) {
    if (!is.na(sample_datetime) && nrow(cand) > 1) {
      has_dt <- !is.na(cand$datetime)
      match_dt <- has_dt & (cand$datetime == sample_datetime)
      if (any(match_dt)) {
        cand <- cand[match_dt, , drop = FALSE]
      }
    }
    return(cand$uuid[[1]])
  }

  new_uuid <- uuid::UUIDgenerate()
  midnight <- as.POSIXct(paste(as.character(sample_date), "00:00:00"), tz = "Australia/Sydney")
  row <- tibble::tibble(
    uuid = new_uuid, uuid_feature = uuid_feature, uuid_project = uuid_project,
    date = midnight, date_start = as.POSIXct(NA), datetime = sample_datetime,
    datetime_start = as.POSIXct(NA), organisation = organisation, person = person,
    purpose = NA_character_, comments = NA_character_
  )
  db_append(con, "sample", row, actor = .ct_actor, reason = reason)
  new_uuid
}

#' Resolve every `clean` row's sample uuid (step 2)
#'
#' Iterates the distinct `(uuid_feature, sample_date, sample_datetime)`
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

  key <- paste(
    clean$uuid_feature, as.character(clean$sample_date),
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
        uuid_feature = clean$uuid_feature[[i]],
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

#' Insert (or supersede-update) an analysis row for every `clean` row
#' (step 3). Rows with `supersedes` NA are inserted fresh; rows with a
#' non-NA `supersedes` update the existing analysis in place instead - with
#' `value` first in `changes` so it is the row DuckDB returns for
#' `ORDER BY "at" DESC LIMIT 1` ties within the one `db_update()` call.
#' @keywords internal
#' @noRd
.ct_commit_analyses <- function(con, clean, actor, reason) {
  n <- nrow(clean)
  if (n == 0) {
    return(invisible(NULL))
  }

  for (i in seq_len(n)) {
    quantified <- !isTRUE(clean$below_detection[[i]])
    source_hash <- clean$source_hash[[i]]

    if (is.na(clean$supersedes[[i]])) {
      new_uuid <- uuid::UUIDgenerate()
      new_row <- tibble::tibble(
        uuid = new_uuid, uuid_sample = clean$uuid_sample[[i]], uuid_lab = clean$uuid_lab[[i]],
        value = clean$value_converted[[i]], value_chr = clean$value_chr[[i]],
        quantified = quantified, rl_low = clean$rl_converted[[i]], comments = clean$comments[[i]]
      )
      db_append(con, "analysis", new_row, actor = actor, reason = reason, source_hash = source_hash)
    } else {
      changes <- list(
        value = clean$value_converted[[i]], value_chr = clean$value_chr[[i]],
        quantified = quantified, rl_low = clean$rl_converted[[i]]
      )
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
#' Prefers an `existing_uuid` column (the plan-09 unit-test shape). Falls
#' back to parsing it out of `payload` for the real `reconcile_event()`
#' shape - which for `already_present` rows sets `payload` to the bare
#' existing analysis uuid, so the `existing_uuid=` regex is a harmless
#' pass-through there (no match -> `sub()` returns `payload` unchanged) and
#' also handles a future payload that does embed `existing_uuid=<uuid>`.
#' @keywords internal
#' @noRd
.ct_skip_existing_uuid <- function(skipped, i) {
  if ("existing_uuid" %in% names(skipped)) {
    val <- skipped$existing_uuid[[i]]
    if (!is.na(val)) {
      return(val)
    }
  }
  payload <- if ("payload" %in% names(skipped)) skipped$payload[[i]] else NA_character_
  if (is.na(payload)) {
    return(NA_character_)
  }
  sub(".*existing_uuid=([^,}]+).*", "\\1", payload)
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
#' @keywords internal
#' @noRd
.ct_commit_review <- function(con, review, event, actor, reason) {
  n <- nrow(review)
  if (n == 0) {
    return(invisible(NULL))
  }
  for (i in seq_len(n)) {
    source_hash <- if ("source_hash" %in% names(review)) review$source_hash[[i]] else NA_character_
    row <- tibble::tibble(
      uuid = uuid::UUIDgenerate(), created_at = Sys.time(), kind = review$kind[[i]],
      work_order = event$work_order, source_hash = source_hash,
      payload = review$payload[[i]], status = "open"
    )
    db_append(con, "review_queue", row, actor = actor, reason = reason, source_hash = source_hash)
  }
  invisible(NULL)
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
    if (nrow(clean) > 0) {
      clean$uuid_sample <- .ct_resolve_samples(con, clean, uuid_project, reason)
    }
    .ct_commit_analyses(con, clean, .ct_actor, reason)

    .ct_archive_files(con, event)
    .ct_record_already_present(con, resolved$skipped, .ct_actor, reason)

    .ct_commit_review(con, resolved$review, event, .ct_actor, reason)

    .ct_set_file_states(con, event$files, nrow(clean), nrow(resolved$review), reason)

    invisible(NULL)
  })

  invisible(NULL)
}
