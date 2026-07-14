# Plan 01 - R-1.5 ensure_schema() (ops tables & migrations, A2/A7) and
# R-1.6 state transitions (ingest_file_upsert() / ingest_file_set_state()).

# Ordered, additive-only migrations for the ops tables (A2, A7). Each is
# applied at most once per database, tracked in `schema_version`. DDL is
# pinned exactly by PLAN-01 R-1.5 - do not reorder or alter existing entries;
# append new migrations instead.
.st_schema_migrations <- list(
  list(
    version = 1L,
    ddl = "
      CREATE TABLE IF NOT EXISTS ingest_file (
        hash VARCHAR PRIMARY KEY,
        filename VARCHAR,
        path_first_seen VARCHAR,
        size BIGINT,
        first_seen_at TIMESTAMP,
        updated_at TIMESTAMP,
        state VARCHAR,
        state_reason VARCHAR,
        adapter VARCHAR,
        tier VARCHAR,
        work_order VARCHAR,
        revision INTEGER,
        org VARCHAR,
        uuid_asset VARCHAR
      )"
  ),
  list(
    version = 2L,
    ddl = "
      CREATE TABLE IF NOT EXISTS ingest_sighting (
        hash VARCHAR,
        path VARCHAR,
        seen_at TIMESTAMP
      )"
  ),
  list(
    version = 3L,
    ddl = "
      CREATE TABLE IF NOT EXISTS review_queue (
        uuid VARCHAR PRIMARY KEY,
        created_at TIMESTAMP,
        kind VARCHAR,
        work_order VARCHAR,
        source_hash VARCHAR,
        payload VARCHAR,
        status VARCHAR DEFAULT 'open',
        resolution VARCHAR,
        resolved_by VARCHAR,
        resolved_at TIMESTAMP
      )"
  ),
  list(
    version = 4L,
    ddl = "
      CREATE TABLE IF NOT EXISTS change_log (
        uuid VARCHAR PRIMARY KEY,
        \"at\" TIMESTAMP,
        actor VARCHAR,
        action VARCHAR,
        tbl VARCHAR,
        uuid_row VARCHAR,
        field VARCHAR,
        old VARCHAR,
        new VARCHAR,
        reason VARCHAR,
        source_hash VARCHAR
      )"
  )
)

#' Idempotently create/upgrade the sampleTidy ops tables (A2, A7)
#'
#' Creates `ingest_file`, `ingest_sighting`, `review_queue`, `change_log` and
#' the `schema_version` bookkeeping table if missing, then applies any
#' not-yet-applied migration from `.st_schema_migrations` in a transaction,
#' recording its version. Never touches core (pre-existing) business tables.
#' Safe to call repeatedly.
#'
#' @param con an open read-write DBI connection.
#' @return `con`, invisibly.
#' @export
ensure_schema <- function(con) {
  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS schema_version (
      version INTEGER,
      applied_at TIMESTAMP
    )")

  applied <- DBI::dbGetQuery(con, "SELECT version FROM schema_version")$version

  for (m in .st_schema_migrations) {
    if (m$version %in% applied) {
      next
    }

    DBI::dbExecute(con, "BEGIN TRANSACTION")
    tryCatch(
      {
        DBI::dbExecute(con, m$ddl)
        DBI::dbExecute(
          con,
          "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
          params = list(m$version, Sys.time())
        )
        DBI::dbExecute(con, "COMMIT")
      },
      error = function(e) {
        try(DBI::dbExecute(con, "ROLLBACK"), silent = TRUE)
        cli::cli_abort(
          "Failed to apply ops-schema migration {m$version}: {conditionMessage(e)}",
          class = "sampletidy_error",
          parent = e
        )
      }
    )
  }

  invisible(con)
}

# --- R-1.6 state transitions ------------------------------------------------

# Legal outgoing states per current `ingest_file.state` (PLAN-01 R-1.6).
# `claimed -> ignored` is included alongside the plan's literal
# `{parsed,failed,quarantined}` set: test-db-schema.R's terminal-state test
# exercises exactly this edge (claimed -> ignored, then asserts the
# now-terminal row rejects a further transition), which only makes sense if
# that edge is legal. See final report for this discrepancy.
.st_ingest_transitions <- list(
  seen          = c("claimed", "ignored", "quarantined"),
  claimed       = c("parsed", "failed", "quarantined", "ignored"),
  parsed        = c("assembled", "ignored", "failed"),
  assembled     = c("reconciled", "failed"),
  reconciled    = c("needs_review", "committed"),
  needs_review  = c("committed"),
  committed     = c("archived")
)

# States with no legal outgoing transition except via `reset = TRUE`.
.st_ingest_terminal_states <- c("archived", "ignored", "quarantined", "failed")

#' Insert or update an `ingest_file` row for a content hash
#'
#' On first sight of `hash`, inserts a new row in state `"seen"` with
#' `path_first_seen` set to `path`. On a later sight of the same hash,
#' updates `filename`/`size`/`updated_at` but never overwrites
#' `path_first_seen`; if `path` differs from the row's `path_first_seen`, and
#' this exact `(hash, path)` pair has not already been recorded, appends one
#' `ingest_sighting` row (A20/A21: sightings are deduped by `(hash, path)`).
#'
#' @param con an open read-write DBI connection.
#' @param hash SHA-256 content hash (R-1.2 `hash_file()`).
#' @param path the file path currently being observed.
#' @param filename basename of the file (optional).
#' @param size file size in bytes (optional).
#' @return `NULL`, invisibly.
#' @keywords internal
#' @noRd
ingest_file_upsert <- function(con, hash, path, filename = NA_character_, size = NA_integer_) {
  checkmate::assert_string(hash)
  checkmate::assert_string(path)

  now <- Sys.time()

  existing <- DBI::dbGetQuery(
    con,
    "SELECT path_first_seen FROM ingest_file WHERE hash = ?",
    params = list(hash)
  )

  if (nrow(existing) == 0) {
    DBI::dbExecute(
      con,
      "INSERT INTO ingest_file
        (hash, filename, path_first_seen, size, first_seen_at, updated_at, state)
       VALUES (?, ?, ?, ?, ?, ?, 'seen')",
      params = list(hash, filename, path, size, now, now)
    )
    return(invisible(NULL))
  }

  DBI::dbExecute(
    con,
    "UPDATE ingest_file SET filename = ?, size = ?, updated_at = ? WHERE hash = ?",
    params = list(filename, size, now, hash)
  )

  path_first_seen <- existing$path_first_seen[[1]]
  if (!identical(path, path_first_seen)) {
    already_sighted <- DBI::dbGetQuery(
      con,
      "SELECT COUNT(*) AS n FROM ingest_sighting WHERE hash = ? AND path = ?",
      params = list(hash, path)
    )$n
    if (identical(as.numeric(already_sighted), 0)) {
      DBI::dbExecute(
        con,
        "INSERT INTO ingest_sighting (hash, path, seen_at) VALUES (?, ?, ?)",
        params = list(hash, path, now)
      )
    }
  }

  invisible(NULL)
}

#' Transition an `ingest_file` row's state (R-1.6)
#'
#' Enforces the legal-transition graph in `.st_ingest_transitions`; any
#' non-terminal state may additionally move to `"failed"`. Terminal states
#' (`archived`, `ignored`, `quarantined`, `failed`) reject every transition
#' unless `reset = TRUE`.
#'
#' @param con an open read-write DBI connection.
#' @param hash content hash identifying the `ingest_file` row.
#' @param state the target state.
#' @param reason optional free-text reason, stored in `state_reason`.
#' @param reset if `TRUE`, bypass the legal-transition check (explicit
#'   re-ingest of a changed policy).
#' @return `NULL`, invisibly.
#' @keywords internal
#' @noRd
ingest_file_set_state <- function(con, hash, state, reason = NA_character_, reset = FALSE) {
  checkmate::assert_string(hash)
  checkmate::assert_string(state)
  checkmate::assert_flag(reset)

  row <- DBI::dbGetQuery(
    con,
    "SELECT state FROM ingest_file WHERE hash = ?",
    params = list(hash)
  )
  if (nrow(row) == 0) {
    cli::cli_abort(
      "No ingest_file row found for hash {.val {hash}}.",
      class = "sampletidy_error"
    )
  }
  current <- row$state[[1]]

  if (!isTRUE(reset)) {
    if (current %in% .st_ingest_terminal_states) {
      cli::cli_abort(
        "Illegal ingest_file state transition: {current} -> {state}
         ({current} is terminal; pass reset = TRUE to override).",
        class = "sampletidy_error"
      )
    }

    legal_targets <- .st_ingest_transitions[[current]]
    is_legal <- identical(state, "failed") || isTRUE(state %in% legal_targets)
    if (!is_legal) {
      cli::cli_abort(
        "Illegal ingest_file state transition: {current} -> {state}.",
        class = "sampletidy_error"
      )
    }
  }

  DBI::dbExecute(
    con,
    "UPDATE ingest_file SET state = ?, state_reason = ?, updated_at = ? WHERE hash = ?",
    params = list(state, reason, Sys.time(), hash)
  )

  invisible(NULL)
}

# Record the routing outcome (adapter id + winning tier) on an ingest_file row.
# An ops-table write, kept here so all raw ingest_file SQL lives in one place
# (db-schema.R) rather than leaking into the router/pipeline modules.
ingest_file_set_route <- function(con, hash, adapter = NA_character_, tier = NA_character_) {
  checkmate::assert_string(hash)
  DBI::dbExecute(
    con,
    "UPDATE ingest_file SET adapter = ?, tier = ?, updated_at = ? WHERE hash = ?",
    params = list(adapter, tier, Sys.time(), hash)
  )
  invisible(NULL)
}

# Append a review_queue item. Ops-table write shared by the router (adapter
# ties) and later the assembly/reconcile stages (unknown feature/analyte/unit,
# value conflicts). Centralised here so review_queue INSERTs never scatter as
# raw SQL across pipeline modules.
review_queue_add <- function(con, kind, work_order = NA_character_,
                             source_hash = NA_character_, payload = NA_character_,
                             uuid = NULL, created_at = NULL) {
  checkmate::assert_string(kind)
  if (is.null(uuid)) uuid <- uuid::UUIDgenerate()
  if (is.null(created_at)) created_at <- Sys.time()
  DBI::dbExecute(
    con,
    "INSERT INTO review_queue
       (uuid, created_at, kind, work_order, source_hash, payload, status)
     VALUES (?, ?, ?, ?, ?, ?, 'open')",
    params = list(uuid, created_at, kind, work_order, source_hash, payload)
  )
  invisible(uuid)
}
