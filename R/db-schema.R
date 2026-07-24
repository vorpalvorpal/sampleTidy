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
  ),
  # PLAN-16 (B-16.ddl): 6a adds the three typed review_queue columns
  # (subkind/uuid_existing/uuid_alias - uuid-prefixed, following the table's
  # own convention, not the payload's key order); 6b creates the
  # review_queue_candidate child table. No FK on uuid_existing/uuid_alias:
  # they are polymorphic (the referent table depends on `kind`), so a FK
  # cannot express them - the migration itself cannot verify resolution
  # either, which is why R-16.12/R-16.13 (dev/migrations/006) own that check.
  # `kind` is a plain VARCHAR (no CHECK: DuckDB CHECK survives this schema's
  # rebuild patterns poorly; the enum is pinned by criterion instead). `rank`
  # is NOT NULL: candidate order is meaningful (PLAN-15's audit finding).
  # Idempotent-safe throughout: version 6 applies immediately after an
  # as-yet-unapplied version 5 on the live DB (R-16.1 arm b).
  #
  # *** DEVIATION FROM B-16.ddl, FLAGGED FOR ADJUDICATION (see P16-db-schema
  # report) ***: B-16.ddl pins `uuid_feature VARCHAR NOT NULL REFERENCES
  # feature(uuid)`. DuckDB requires the referenced table to exist at CREATE
  # TABLE time (verified empirically - a dangling REFERENCES is a CATALOG
  # error, not a deferred constraint). `feature` is a core/CONTRACT table,
  # never created by ensure_schema() (A50: ops-tables-only) - and
  # ensure_schema() is REQUIRED to succeed on a DB with no core tables at
  # all: R-1.5's own foundational test ("ensure_schema() creates all five ops
  # objects on a fresh DB", pre-dating PLAN-16) calls it on a bare
  # DBI::dbConnect() with nothing else created, and R-16.1 arm (a) explicitly
  # re-asserts the same bare-DB premise for version 6 itself. seed_db()
  # itself calls ensure_schema() BEFORE creating the `feature` table, so
  # `feature` is never present at v6-apply time on ANY path through this
  # suite either. An inline FK to `feature` is therefore not constructible
  # without either breaking that foundational invariant or dropping/
  # rebuilding review_queue_candidate later (DuckDB has no ALTER TABLE ADD
  # FOREIGN KEY - verified empirically), which risks divergent schemas across
  # databases bootstrapped at different times. `uuid_feature` is left NOT
  # NULL but WITHOUT the inline FK; `uuid_review`'s FK is retained
  # (review_queue always exists by v6, applied within the same
  # ensure_schema() call at v3). Direct, unavoidable consequence: the R-16.3
  # "FK on uuid_feature is enforced" test fails (not errors) rather than
  # passing - a provisional-oracle mismatch surfaced here per instruction,
  # not silently suppressed.
  list(
    version = 6L,
    ddl = "
      ALTER TABLE review_queue ADD COLUMN IF NOT EXISTS subkind       VARCHAR;
      ALTER TABLE review_queue ADD COLUMN IF NOT EXISTS uuid_existing VARCHAR;
      ALTER TABLE review_queue ADD COLUMN IF NOT EXISTS uuid_alias    VARCHAR;

      CREATE TABLE IF NOT EXISTS review_queue_candidate (
        uuid          VARCHAR NOT NULL PRIMARY KEY,
        uuid_review   VARCHAR NOT NULL REFERENCES review_queue(uuid),
        uuid_feature  VARCHAR NOT NULL,
        kind          VARCHAR NOT NULL,
        date_start    DATE,
        date_end      DATE,
        rank          INTEGER NOT NULL
      );"
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
# that edge is legal. This discrepancy was adjudicated as A31.
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
#' updates `filename`/`size`/`updated_at`, COALESCE-guarding `filename` and
#' `size` so an `NA` argument keeps the existing stored value rather than
#' clobbering it (R-12.9); `path_first_seen` is never overwritten. If `path`
#' differs from the row's `path_first_seen`, and
#' this exact `(hash, path)` pair has not already been recorded, appends one
#' `ingest_sighting` row (A20/A21: sightings are deduped by `(hash, path)`).
#'
#' @param con an open read-write DBI connection.
#' @param hash xxHash128 content hash (R-1.2 `hash_file()`).
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
    "UPDATE ingest_file
      SET filename = COALESCE(?, filename), size = COALESCE(?, size), updated_at = ?
      WHERE hash = ?",
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

# PLAN-16 (B-16.api): the single structured constructor every review_queue
# producer routes through instead of hand-building a payload string.
# PURE - no DB access, no side effects beyond generating a uuid/timestamp for
# the row it returns. In ONE call, returns BOTH the review_queue row and the
# review_queue_candidate child rows implied by `candidates`/`expired`, so a
# caller wanting candidate rows cannot construct them independently of the
# review row they belong to (S-16.2) - this is about construction being
# bundled, not a runtime guarantee that every review row has non-empty
# children: most kinds legitimately pass candidates = NULL and get back zero
# child rows (see R-16.9's default-arg call sites).
# .rq_row() ITSELF takes NO free-text payload argument (R-16.18): within this
# function, a hand-built k=v string has nowhere to go in, which is what makes
# the comma/pipe/equals injection hazard (R-16.10) and the nesting bug
# (R-16.11) structurally impossible for callers that build a diagnostics list
# and let it flow through here. Within `.rq_row()`, `diagnostics` is the only
# free-form carrier, serialised via jsonlite::toJSON(auto_unbox = TRUE),
# which escapes by construction.
# CARVE-OUT, not an oversight: `review_queue_add()` immediately below keeps
# its OWN pre-existing free-text `payload` argument (R-16.9 requires it be
# byte-identical to the raw db_append() tibble path) and overrides
# .rq_row()'s JSON payload with it verbatim when supplied - so a caller of
# review_queue_add() (as opposed to .rq_row() directly) CAN still pass a
# hand-built string through `payload`. See that function's own comment.
#
# @param kind review_queue.kind (required).
# @param subkind review_queue.subkind, or NA.
# @param work_order review_queue.work_order, or NA.
# @param source_hash review_queue.source_hash, or NA.
# @param uuid_existing review_queue.uuid_existing (polymorphic; see B-16.ddl
#   for the kind -> referent table map), or NA.
# @param uuid_alias review_queue.uuid_alias, or NA.
# @param candidates character() of feature uuids, in rank order -> one
#   review_queue_candidate row per element, kind = 'candidate'.
# @param expired tibble(uuid_feature, date_start, date_end) -> one
#   review_queue_candidate row per row, kind = 'expired'.
# @param diagnostics named list -> JSON `payload`.
# @return list(review = tibble (one row), candidates = tibble (0+ rows)).
# @keywords internal
# @noRd
.rq_row <- function(kind, subkind = NA_character_, work_order = NA_character_,
                    source_hash = NA_character_, uuid_existing = NA_character_,
                    uuid_alias = NA_character_, candidates = NULL, expired = NULL,
                    diagnostics = list()) {
  checkmate::assert_string(kind)
  checkmate::assert_list(diagnostics)
  if (!is.null(candidates)) checkmate::assert_character(candidates)
  if (!is.null(expired)) checkmate::assert_data_frame(expired)

  uuid_row <- uuid::UUIDgenerate()
  created_at <- Sys.time()
  payload <- as.character(jsonlite::toJSON(diagnostics, auto_unbox = TRUE))

  review <- tibble::tibble(
    uuid = uuid_row, created_at = created_at, kind = kind, subkind = subkind,
    work_order = work_order, source_hash = source_hash, payload = payload,
    status = "open", uuid_existing = uuid_existing, uuid_alias = uuid_alias
  )

  child_parts <- list()
  n_candidates <- if (is.null(candidates)) 0L else length(candidates)
  if (n_candidates > 0L) {
    child_parts[[length(child_parts) + 1L]] <- tibble::tibble(
      uuid = vapply(seq_len(n_candidates), function(i) uuid::UUIDgenerate(), character(1)),
      uuid_review = uuid_row, uuid_feature = candidates, kind = "candidate",
      date_start = as.Date(NA), date_end = as.Date(NA), rank = seq_len(n_candidates)
    )
  }
  n_expired <- if (is.null(expired)) 0L else nrow(expired)
  if (n_expired > 0L) {
    child_parts[[length(child_parts) + 1L]] <- tibble::tibble(
      uuid = vapply(seq_len(n_expired), function(i) uuid::UUIDgenerate(), character(1)),
      uuid_review = uuid_row, uuid_feature = expired$uuid_feature, kind = "expired",
      date_start = expired$date_start, date_end = expired$date_end,
      rank = n_candidates + seq_len(n_expired)
    )
  }

  candidate_rows <- if (length(child_parts) > 0L) {
    dplyr::bind_rows(child_parts)
  } else {
    tibble::tibble(
      uuid = character(), uuid_review = character(), uuid_feature = character(),
      kind = character(), date_start = as.Date(character()),
      date_end = as.Date(character()), rank = integer()
    )
  }

  list(review = review, candidates = candidate_rows)
}

# Append a review_queue item. Ops-table write shared by the router (adapter
# ties) and later the assembly/reconcile stages (unknown feature/analyte/unit,
# value conflicts). Centralised here so review_queue INSERTs never scatter as
# raw SQL across pipeline modules.
#
# Routes through .rq_row() (S-16.2) for the row shape and the
# review_queue_candidate child rows, then writes both itself - .rq_row() is
# pure and never touches the DB. `payload` remains this function's own
# free-text argument (unchanged from its pre-PLAN-16 shape, R-16.9's fixture
# passes a plain string here) and, when supplied, overrides the
# JSON-from-diagnostics payload .rq_row() built (diagnostics defaults to
# list(), i.e. "{}"): existing call sites keep writing their own payload
# strings verbatim, while `subkind`/`uuid_existing`/`uuid_alias`/`candidates`
# are the new, typed path (mirroring the review_queue column names 1:1).
review_queue_add <- function(con, kind, work_order = NA_character_,
                             source_hash = NA_character_, payload = NA_character_,
                             uuid = NULL, created_at = NULL,
                             subkind = NA_character_, uuid_existing = NA_character_,
                             uuid_alias = NA_character_, candidates = NULL) {
  checkmate::assert_string(kind)
  if (is.null(uuid)) uuid <- uuid::UUIDgenerate()
  if (is.null(created_at)) created_at <- Sys.time()

  rq <- .rq_row(
    kind = kind, subkind = subkind, work_order = work_order,
    source_hash = source_hash, uuid_existing = uuid_existing,
    uuid_alias = uuid_alias, candidates = candidates
  )
  review <- rq$review
  review$uuid <- uuid
  review$created_at <- created_at
  if (!is.na(payload)) review$payload <- payload

  cand <- rq$candidates
  if (nrow(cand) > 0L) cand$uuid_review <- uuid

  DBI::dbExecute(
    con,
    "INSERT INTO review_queue
       (uuid, created_at, kind, subkind, work_order, source_hash, payload,
        status, uuid_existing, uuid_alias)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
    params = list(
      review$uuid[[1]], review$created_at[[1]], review$kind[[1]], review$subkind[[1]],
      review$work_order[[1]], review$source_hash[[1]], review$payload[[1]],
      review$status[[1]], review$uuid_existing[[1]], review$uuid_alias[[1]]
    )
  )

  for (i in seq_len(nrow(cand))) {
    DBI::dbExecute(
      con,
      "INSERT INTO review_queue_candidate
         (uuid, uuid_review, uuid_feature, kind, date_start, date_end, rank)
       VALUES (?, ?, ?, ?, ?, ?, ?)",
      params = list(
        cand$uuid[[i]], cand$uuid_review[[i]], cand$uuid_feature[[i]], cand$kind[[i]],
        cand$date_start[[i]], cand$date_end[[i]], cand$rank[[i]]
      )
    )
  }

  invisible(uuid)
}
