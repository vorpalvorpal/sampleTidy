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
  # PLAN-15 F.15 "THE PINNED DESIGN" (ruling (a), 2026-07-24, D1): the
  # linkage column a review item needs to be closeable
  # (review_queue_close(), D4 below) once the confirmation that raised it
  # resolves. Generic (`kind` says which table it points at - see D1's
  # kind -> table map in the plan); nullable, no FK (review_queue is an ops
  # table observing the registry, not owning it - a FK here would block
  # deletes on the table it only observes). MUST be inserted here, BEFORE
  # the version-6 entry below: version 6's own comment records that it
  # "applies immediately after an as-yet-unapplied version 5 on the live
  # DB" - version 5 is a deliberately reserved, not-yet-applied slot, and
  # `ensure_schema()` applies migrations in list order, so this entry must
  # sit before version 6 in this list, not merely have a lower `version`
  # number. Do NOT retro-edit the version = 3L CREATE TABLE above: a
  # database already at version >= 3 never re-runs it, so editing it in
  # place would make fresh and already-migrated databases diverge.
  list(
    version = 5L,
    ddl = "ALTER TABLE review_queue ADD COLUMN IF NOT EXISTS uuid_target VARCHAR"
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
  #
  # Round-2 audit FD10(b): `rank NOT NULL` alone did not stop two candidate
  # rows sharing one `(uuid_review, rank)` pair (a rank tie makes `ORDER BY
  # rank` nondeterministic, defeating R-16.4's whole point). Added
  # `UNIQUE (uuid_review, rank)` below. This AMENDS the existing version-6
  # DDL in place rather than shipping a version 7 or a migration - safe ONLY
  # because schema v6 has never been applied to any real database yet (every
  # test database in this suite is built fresh, so there is nothing to
  # migrate); do NOT take this as licence to hand-edit an already-applied
  # migration version elsewhere in this ladder.
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
        rank          INTEGER NOT NULL,
        UNIQUE (uuid_review, rank)
      );"
  ),
  # PLAN-11 R-11.10 / Robin's ruling 2 (2026-07-26, Phase 7b round-2 item B):
  # the alias merge's `value_conflict` review item must name BOTH analysis
  # uuids - the code only ever emitted `uuid_existing`. Robin ruled the plan
  # wins and the second uuid is a TYPED column (consistent with PLAN-16
  # moving uuids out of the payload), not a payload key. A NEW ladder entry,
  # not an amendment of version 6: v6's own comment permits in-place
  # amendment only while it has never been applied to a real database, and
  # that is not worth re-verifying when a fresh entry costs nothing. Plain
  # `ADD COLUMN` (footgun sheet: DuckDB 1.4.1 allows ADD COLUMN, not
  # ALTER/DROP COLUMN, on a table any FK references - review_queue is
  # review_queue_candidate's FK parent by v6, so this must stay ADD COLUMN
  # only). For `subkind = "measurement"` (R/reconcile.R) the incoming side
  # genuinely has no uuid - NA there is correct and is NOT a gap this column
  # needs to fill.
  list(
    version = 7L,
    ddl = "ALTER TABLE review_queue ADD COLUMN IF NOT EXISTS uuid_incoming VARCHAR"
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
#' S13 (Phase 7b round 3): each migration PARTICIPATES in an already-open
#' mutation-layer transaction rather than always committing independently
#' (see the `db_transaction()` comment inside the loop below) - so if this
#' function is called from INSIDE a caller's own `db_transaction()`, the ops
#' schema it creates/upgrades is durable only if that OUTER transaction goes
#' on to commit. A caller failure after `ensure_schema()` but before its own
#' commit rolls the schema changes back too (reproduced: a bare DB left with
#' zero tables). Called standalone (the common case, and the only way it is
#' invoked in this package today), it still commits (or rolls back) each
#' migration independently exactly as before.
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

    # Phase 7b round-2 item D: participate in an already-open mutation-layer
    # transaction rather than nesting a second BEGIN (DuckDB errors on a
    # nested transaction). `db_transaction()` is the SAME participation
    # helper `db_append()`/`db_update()`/`review_queue_add()` all use
    # (`.st_in_txn()`, R/mutate.R) - this used to be the only writer in this
    # file with its own raw BEGIN/COMMIT/ROLLBACK, issued OUTSIDE its own
    # tryCatch, so a caller running ensure_schema() inside an open
    # db_transaction() (latent today - R/ingest.R:518 calls it unwrapped)
    # would hit "cannot start a transaction within a transaction" before the
    # tryCatch could even see the error. Wrapping db_transaction()'s call
    # itself in tryCatch preserves this function's own, more specific error
    # message (naming the migration version) while db_transaction() owns the
    # actual BEGIN/COMMIT/ROLLBACK (or participation) mechanics.
    tryCatch(
      db_transaction(con, function(con) {
        DBI::dbExecute(con, m$ddl)
        DBI::dbExecute(
          con,
          "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
          params = list(m$version, Sys.time())
        )
        invisible(NULL)
      }),
      error = function(e) {
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
  # `parsed` has no `quarantined` target: no stage after parse withholds a
  # file. A74's ALS-source gate briefly did, and this edge was added for it;
  # A79 withdrew the gate, so the edge went with it rather than being left as
  # a legal-but-unreachable transition.
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

# PLAN-16 Phase-7b (FB1/FB2/FB3): the ONE place a diagnostics list becomes a
# JSON payload string, shared by BOTH review_queue carriers - `.rq_row()`
# just below and `.rq_skip()` (R/reconcile.R) - so the serialisation POLICY
# cannot drift between the two copies again (that duplication was itself the
# defect vector: all three bugs below were present in both copies).
#  - `digits = NA`: full numeric precision. jsonlite's default is
#    `digits = 4`, meaning 4 DECIMAL PLACES, so a real lab measurement near
#    1e-4 (the normal case for this data) is silently rounded away (~19%
#    error observed).
#  - `na = "null"`: `NA_real_`/`NA_integer_` must serialise to JSON `null`.
#    jsonlite's default instead emits the JSON STRING `"NA"`, indistinguishable
#    from a genuine text result and flipping numeric -> character across the
#    boundary; this lands on the DOMINANT branch (R/reconcile.R's
#    `value_conflict` producer reaches review precisely when a revision is NA).
#  - an empty diagnostics list emits `"{}"` (a JSON OBJECT), never
#    `toJSON()`'s own default `"[]"` (a JSON ARRAY): migration 006's
#    `startsWith(payload, "{")` legacy-row guard relies on this to tell a
#    correctly-written structured row from a legacy k=v row apart.
# Also validates: `diagnostics` must be a list with UNIQUE NAMES (R-16.18/
# FA7) - an unnamed list (e.g. a hand-built k=v string wrapped in `list()`)
# would otherwise serialise straight through, defeating the whole point of
# routing through a typed carrier instead of free text.
#
# Round-2 audit FF8 + policy ruling: with `auto_unbox = TRUE`, a diagnostics
# key's JSON SHAPE changes with its length - a length-1 value serialises as
# a scalar (`"candidates":"f-0001"`) but length>=2 serialises as an array
# (`"candidates":["f-0001","f-0002"]`). Every consumer would have to handle
# both shapes, and the length-1 case (the COMMON one - e.g. PLAN-15 R-15.27's
# "exactly ONE suggestion candidate") is exactly the one most likely to be
# got wrong. `.RQ_PLURAL_DIAGNOSTIC_KEYS` is an explicit, greppable registry
# of keys that are semantically plural regardless of how many elements they
# happen to carry right now; any registered key is wrapped in `I()` before
# serialisation so it ALWAYS emits a JSON array, at length 0, 1 and N alike.
# Keys not in the registry keep auto_unbox's scalar-at-length-1 behaviour -
# this does not disable auto_unbox globally, only overrides it for the
# registered keys. A caller that has already wrapped its own value in `I()`
# is honoured as-is (not double-wrapped).
#
# Seeded with the two keys Robin named directly: `candidates` (R-16.4's
# multi-candidate review producers) and `source_ref` (`.rc_review_row()`,
# R/reconcile.R - one element per folded source row, frequently exactly one).
#
# Round-2 remediation (worker W-G, 2026-07-25): two more keys registered by
# policy ("semantically-PLURAL diagnostics keys always serialise as JSON
# ARRAYS, at length 0 and 1 too"), reported when first found (round-2 audit)
# and now added on Robin's instruction -
#   - `adapters` (R/router.R, `adapter_tie` producer) - in practice always
#     length>=2 (only reached when >1 adapter ties at the winning tier).
#   - `units` (R/feature-alias.R, `units_drift` producer) - only reached when
#     `length(drift_units) > 1`, so always length>=2 there too.
# NEITHER PRODUCER CAN EMIT LENGTH 1 TODAY, so registering them changes no
# current output (this is provably true for `adapters`/`units` right now,
# unlike `candidates`/`source_ref` which do hit length 1 routinely). They are
# registered anyway so that the day one of them CAN emit a single element,
# the JSON shape does not silently flip from array to scalar under a
# consumer that was never written to handle both.
.RQ_PLURAL_DIAGNOSTIC_KEYS <- c("candidates", "source_ref", "adapters", "units")

#' @keywords internal
#' @noRd
.rq_serialise_diagnostics <- function(diagnostics) {
  checkmate::assert_list(diagnostics, names = "unique")
  if (length(diagnostics) == 0L) return("{}")
  for (key in intersect(names(diagnostics), .RQ_PLURAL_DIAGNOSTIC_KEYS)) {
    val <- diagnostics[[key]]
    if (is.null(val)) {
      # Round-3 audit H4, RULING (pinned here, not silently patched around):
      # a NULL value for a REGISTERED plural key serialises as "[]", the
      # length-0 case - NOT an abort. This is the reading the plural-key
      # design above already commits to ("ALWAYS emits a JSON array, at
      # length 0, 1 and N alike"): NULL is semantically "no elements", the
      # same as character(0), and an UNregistered NULL key already serialises
      # without error (as jsonlite's own "{}" for a NULL list element) - so a
      # registered key erroring on the identical input would make the
      # registry actively worse than no registry at all, exactly the
      # regression the finding describes (STAGE-0's review_payload
      # pass-through hits this, aborting the whole transaction and losing the
      # review row). `I(NULL)` itself raises ("attempt to set an attribute on
      # NULL"); substituting list() first avoids that and reuses the
      # already-verified I(list()) -> "[]" path instead of a NULL special
      # case. The alternative (abort with a sampletidy_error) was rejected: a
      # NULL diagnostics value is a normal "nothing to report" case for a
      # pass-through producer, not caller error, so aborting the whole
      # review-queue write over it is disproportionate.
      val <- list()
    }
    if (!inherits(val, "AsIs")) val <- I(val)
    diagnostics[[key]] <- val
  }
  as.character(jsonlite::toJSON(diagnostics, auto_unbox = TRUE, digits = NA, na = "null"))
}

# Round-3 audit H9: `checkmate::assert_string(x, na.ok = TRUE)` only checks
# `is.na(x)`, not that the NA is CHARACTER-typed - a bare logical `NA` (as
# opposed to `NA_character_`) satisfies it unchanged (verified empirically:
# `checkmate::assert_string(NA, na.ok = TRUE)` raises no error), so a scalar
# typed argument passed a bare `NA` flows straight into `tibble::tibble()`
# and comes back a *logical* column instead of character (proved for
# `uuid_existing`). Reject bare logical NA explicitly here; `NA_character_`
# and real strings are unaffected.
#' @keywords internal
#' @noRd
.rq_assert_char_scalar <- function(x, what) {
  checkmate::assert_string(x, na.ok = TRUE)
  if (is.na(x) && !is.character(x)) {
    cli::cli_abort(
      "{what} must be a length-1 character string or NA_character_; a bare
       logical NA is rejected (it silently produces a logical column instead
       of character) - got class {.cls {class(x)}}.",
      class = "sampletidy_error"
    )
  }
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
# free-form carrier, serialised through `.rq_serialise_diagnostics()` (the one
# shared policy point, see its own comment just above).
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
# @param uuid_incoming review_queue.uuid_incoming (ladder version 7, PLAN-11
#   R-11.10 / Robin's ruling 2, 2026-07-26): the SECOND analysis uuid a
#   `value_conflict` merge names, alongside `uuid_existing`. Follows
#   `uuid_existing`'s own pattern exactly (typed column, NA default,
#   `.rq_assert_char_scalar()` guard). For `subkind = "measurement"`
#   (R/reconcile.R) the incoming side genuinely has no uuid - NA there is
#   correct, not a gap.
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
                    uuid_alias = NA_character_, uuid_incoming = NA_character_,
                    candidates = NULL, expired = NULL,
                    diagnostics = list()) {
  checkmate::assert_string(kind)
  # Round-2 audit FD12: every scalar typed argument is validated, not just
  # `kind`. Before this fix, a length>1 value (e.g. a caller accidentally
  # handing a vector to `uuid_existing`) silently RECYCLED into a multi-row
  # `review` tibble sharing one uuid/PK - a duplicate-PK expansion (proved:
  # `uuid_existing = c("an-1","an-2")` produced a 2-row tibble with one
  # `uuid`), not a truncation. A length-1-string check on every scalar makes
  # that shape impossible to construct.
  .rq_assert_char_scalar(subkind, "subkind")
  .rq_assert_char_scalar(work_order, "work_order")
  .rq_assert_char_scalar(source_hash, "source_hash")
  .rq_assert_char_scalar(uuid_existing, "uuid_existing")
  .rq_assert_char_scalar(uuid_alias, "uuid_alias")
  .rq_assert_char_scalar(uuid_incoming, "uuid_incoming")
  # Round-3 audit H8/FG-6: the DDL declares review_queue_candidate.uuid_feature
  # NOT NULL, so `candidates` (which becomes that column 1:1) must reject NA
  # and "" HERE, at the constructor, rather than letting either kind reach
  # INSERT and fail there - a DB-level failure takes the whole review row down
  # with it (the transaction rolls back). Before this fix, `candidates = NA`
  # aborted at INSERT (constraint violation) while `candidates = ""` was
  # silently ACCEPTED and stored - two kinds of junk treated inconsistently;
  # both now fail early and identically, right here.
  if (!is.null(candidates)) {
    checkmate::assert_character(candidates, any.missing = FALSE, min.chars = 1L)
  }
  if (!is.null(expired)) {
    checkmate::assert_data_frame(expired)
    checkmate::assert_names(
      names(expired), must.include = c("uuid_feature", "date_start", "date_end")
    )
    # Round-3 audit H9 (second half): `expired$uuid_feature` feeds the same
    # NOT NULL `review_queue_candidate.uuid_feature` column as `candidates`
    # does, but was entirely unvalidated - apply the identical H8/FG-6 rule.
    checkmate::assert_character(
      expired$uuid_feature, any.missing = FALSE, min.chars = 1L
    )
    # Round-2 audit FD9: REJECT a non-Date bound rather than coercing it.
    # Reproduced end to end through the real DuckDB driver: a POSIXct
    # `date_start` looks plausible but is silently DATE-truncated at the
    # driver boundary IN UTC, so a local Australia/Sydney timestamp before
    # 10:00 stores the PREVIOUS day (`as.POSIXct("2022-03-04 09:00:00", tz =
    # "Australia/Sydney")` -> stored `2022-03-03`). RULING (Robin,
    # 2026-07-25), followed exactly: do NOT "fix" this by calling as.Date()
    # on the incoming value here, because as.Date.POSIXct() is ITSELF
    # timezone-dependent - that is the very bug, one layer up. Coercing
    # would make this function silently PICK a day instead of storing the
    # wrong one; rejecting forces the caller to convert deliberately, in a
    # timezone the caller (not this generic constructor) actually knows.
    for (expired_col in c("date_start", "date_end")) {
      val <- expired[[expired_col]]
      if (!inherits(val, "Date")) {
        # Round-3 audit H5, RULING (this worker): behaviour is correct as
        # written - `inherits(val, "Date")` is FALSE for a bare logical NA,
        # so bare NA is (and must stay) rejected; only a typed `NA_Date_`
        # (e.g. `as.Date(NA)`) inherits class Date and passes. The BUG was
        # the message text: "(NA allowed)" read as "any NA is fine", which
        # contradicts that behaviour. Fixed the message, not the check - the
        # surrounding Date-required/POSIXct-rejected rule is deliberate (see
        # comment above) and a permissive bare-NA carve-out here would be the
        # same class of silent-type-drift bug H9 exists to prevent.
        cli::cli_abort(
          "expired${expired_col} must be class Date (NA_Date_, e.g.
           as.Date(NA), is allowed - a bare logical NA is NOT, since it is
           not typed as a date); got class {.cls {class(val)}}. Not
           auto-converted: as.Date() on a POSIXct bound is itself
           timezone-dependent (the exact silent-corruption bug this check
           exists to prevent) - convert explicitly with as.Date() before
           calling .rq_row(), choosing the timezone deliberately.",
          class = "sampletidy_error"
        )
      }
    }
  }

  uuid_row <- uuid::UUIDgenerate()
  created_at <- Sys.time()
  payload <- .rq_serialise_diagnostics(diagnostics)

  review <- tibble::tibble(
    uuid = uuid_row, created_at = created_at, kind = kind, subkind = subkind,
    work_order = work_order, source_hash = source_hash, payload = payload,
    status = "open", uuid_existing = uuid_existing, uuid_alias = uuid_alias,
    uuid_incoming = uuid_incoming
  )

  # Round-2 audit FD10(a): dedup `candidates`, preserving FIRST-SEEN order
  # (base R's unique() already does this), before rank is assigned. Without
  # this, the same feature uuid could appear twice with different ranks -
  # a fan-out inflation any count-only check would miss. `n_candidates`
  # below is computed AFTER this dedup, so the `expired` block's rank offset
  # (`n_candidates + seq_len(n_expired)`) stays a dense 1..n sequence.
  if (!is.null(candidates)) candidates <- unique(candidates)

  # Round-3 audit FG-5: `expired` gets the identical FD10(a) dedup, on the
  # (uuid_feature, date_start, date_end) tuple - "two identical expired rows"
  # means identical across all three, not merely the same feature (an
  # expired row's date range is part of its identity; two DIFFERENT date
  # ranges for the same feature are two genuinely distinct expired periods,
  # not a duplicate). First-seen order preserved via `!duplicated()`, same as
  # `unique()` does for `candidates` above. Done here (not up in validation)
  # so it runs after the Date-type/NA checks and before `n_expired`/rank are
  # computed from it, mirroring the candidates dedup's own placement.
  if (!is.null(expired)) {
    expired <- expired[
      !duplicated(expired[c("uuid_feature", "date_start", "date_end")]), ,
      drop = FALSE
    ]
  }

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

# Actor recorded on the change_log rows review_queue_add() now writes via
# db_append() (round-2 FD6). Mirrors R/commit.R's `.ct_actor <- "pipeline"`
# convention - this file cannot see that private binding (different file),
# so it gets its own copy rather than exporting one across a plan boundary.
.rq_actor <- "pipeline"

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
#
# Round-2 audit FD6/FF9: this used to write both tables with raw
# DBI::dbExecute() INSERTs, so it produced ZERO change_log rows while every
# other writer of these two tables (db_append()'s tibble path,
# .ct_commit_review() in R/commit.R) produced one change_log row per record
# - two audit behaviours on the same tables. CONTRACT A32 requires writes to
# go through the mutation layer, so both inserts below now call
# `db_append()` (R/mutate.R) instead. `review_queue`/`review_queue_candidate`
# are both already on `.st_mutate_allowlist`. Both calls stay inside the
# SAME `db_transaction()` as before (FB4's atomicity, a round-1 fix) - the
# outer `db_transaction(con, fn)` tags `con` before calling `fn`, and
# `db_append()`'s own internal `db_transaction()` call detects that tag
# (`.st_in_txn()`) and just runs inline instead of opening a second
# transaction, exactly the hazard `.ct_ensure_project()` (R/commit.R)
# already handles the same way for `add_project()`'s db_append() sibling.
review_queue_add <- function(con, kind, work_order = NA_character_,
                             source_hash = NA_character_, payload = NA_character_,
                             uuid = NULL, created_at = NULL,
                             subkind = NA_character_, uuid_existing = NA_character_,
                             uuid_alias = NA_character_, uuid_incoming = NA_character_,
                             candidates = NULL,
                             diagnostics = list(), uuid_target = NA_character_) {
  checkmate::assert_string(kind)
  # PLAN-15 F.15 D3: `uuid_target` is the generic linkage column
  # (review_queue_close() closes on it). Existing callers pass nothing and
  # keep working: when NA (the default), the column is left OUT of the
  # INSERT entirely (mirrors the `payload` override below) rather than
  # written as an explicit NULL - so a caller running against a
  # pre-migration-5 database (no `uuid_target` column yet) never trips a
  # "column does not exist" error merely by NOT asking for the new
  # behaviour.
  #
  # RESIDUAL RISK, RECORDED DELIBERATELY (Robin's ruling 3, Phase 7b round 3,
  # 2026-07-26): S8 found that this omit-when-NA carve-out no longer protects
  # what it claims to - `.rq_row()` (above) emits `subkind`, `uuid_existing`,
  # `uuid_alias` (ladder v6) and `uuid_incoming` (v7) into the `review`
  # tibble UNCONDITIONALLY, and `db_append()` validates every column against
  # the live table, so a caller on a database behind v6/v7 fails on THOSE
  # columns regardless of what it did or did not ask for - the one column
  # this carve-out actually guards (`uuid_target`, v5) is no longer the
  # binding constraint. Robin's ruling: the live DB has already been
  # migrated by hand (ladder v5/v6/v7, zero row delta, backup retained), so
  # this asymmetry is left AS-IS rather than fixed - do NOT extend the
  # omit-when-NA treatment to `subkind`/`uuid_existing`/`uuid_alias`/
  # `uuid_incoming`, and do NOT delete this `uuid_target` carve-out either.
  # This is now a DELIBERATE, RECORDED decision, not an oversight: any OTHER
  # database that is behind the ladder (a fresh clone, a test fixture built
  # by hand, a future second deployment) will fail `review_queue_add()` with
  # a "column does not exist" error until `ensure_schema()` runs against it
  # first. `ensure_schema()` is therefore a HARD PRECONDITION for
  # `review_queue_add()` on any database that has not already been through
  # the full migration ladder - not merely a convenience. Recorded here so
  # round 4 does not re-file this as a new finding.
  .rq_assert_char_scalar(uuid_target, "uuid_target")
  # Round-3 audit H10: `payload`/`created_at`/`uuid` were the one untyped
  # door left in this function - every other argument already routes through
  # `.rq_row()`'s checkmate guards, but these three are consumed BEFORE that
  # call (or never reach it at all, in `payload`'s case). Before this fix,
  # `payload = 1.5` was silently coerced to the string "1.5" by
  # `tibble::tibble()`, and `payload = c("a","b")` reached the bare
  # `if (!is.na(payload))` below and died with R's own "the condition has
  # length > 1" rather than a `sampletidy_error`. Give all three the same
  # checkmate treatment as every other typed argument here.
  checkmate::assert_string(payload, na.ok = TRUE)
  checkmate::assert_string(uuid, null.ok = TRUE)
  checkmate::assert_posixct(created_at, len = 1L, null.ok = TRUE)
  if (is.null(uuid)) uuid <- uuid::UUIDgenerate()
  if (is.null(created_at)) created_at <- Sys.time()

  # `diagnostics` is the structured path a direct writer (e.g. R/router.R) uses
  # to hand this function a diagnostics list and let .rq_row() JSON-serialise it
  # -- so no caller builds a payload string itself (R-16.8). The legacy `payload`
  # argument still overrides below for back-compat (R-16.9's raw-shape parity).
  rq <- .rq_row(
    kind = kind, subkind = subkind, work_order = work_order,
    source_hash = source_hash, uuid_existing = uuid_existing,
    uuid_alias = uuid_alias, uuid_incoming = uuid_incoming,
    candidates = candidates, diagnostics = diagnostics
  )
  review <- rq$review
  review$uuid <- uuid
  review$created_at <- created_at
  if (!is.na(payload)) review$payload <- payload
  if (!is.na(uuid_target)) review$uuid_target <- uuid_target

  cand <- rq$candidates
  if (nrow(cand) > 0L) cand$uuid_review <- uuid

  # FB4: the parent review_queue row and its N review_queue_candidate child
  # rows are one atomic unit (B-16.api: a caller of .rq_row() cannot end up
  # with one but not the other) - so both db_append() calls run inside ONE
  # db_transaction(). A failing child (e.g. a NOT NULL violation) still rolls
  # the whole write back instead of leaving a truncated, mis-ranked candidate
  # list committed.
  db_transaction(con, function(con) {
    db_append(
      con, "review_queue", review, actor = .rq_actor,
      reason = sprintf("review_queue_add(): kind=%s", kind),
      source_hash = source_hash
    )

    if (nrow(cand) > 0L) {
      db_append(
        con, "review_queue_candidate", cand, actor = .rq_actor,
        reason = sprintf("review_queue_add(): kind=%s candidates", kind)
      )
    }

    invisible(NULL)
  })

  invisible(uuid)
}

#' Close every OPEN `review_queue` row pointing at `uuid_target` (PLAN-15
#' F.15 D4)
#'
#' Symmetric with `review_queue_add()` and for the same reason: so
#' `review_queue` UPDATEs never scatter as raw SQL across the package.
#' `UPDATE`s every row with `status = 'open'` and the given `uuid_target`
#' (optionally narrowed to a single `kind`, see below) to `status =
#' 'resolved'`, stamping `resolution`/`resolved_by`/`resolved_at`.
#' `'resolved'` is the pinned terminal status (D4) - nothing wrote
#' `review_queue.status` before this function existed, so there is no other
#' value to honour, and `'resolved'` is what `resolution`/`resolved_by`/
#' `resolved_at` were named for. Idempotent: a row already `resolved` no
#' longer matches `status = 'open'`, so a second identical call closes zero
#' rows.
#'
#' `kind` (Phase 7b round-2 item A): `uuid_target` is a POLYMORPHIC key - the
#' version-5 ladder comment above says so explicitly ("`kind` says which
#' table it points at"). Without a `kind` filter, closing on `uuid_target`
#' alone closes EVERY open row on that target regardless of what kind raised
#' it, which is wrong the moment two different review kinds can legitimately
#' share one target uuid (reproduced: `confirm_feature_aliases()` opening a
#' `sample_collision`/`same_alias` row and then its own close call silently
#' resolving it in the same transaction).
#'
#' STALE-DOCSTRING CORRECTION (S7, Phase 7b round 3): `kind` is REQUIRED, not
#' optional - it has NO default (see the signature below), and `missing(kind)`
#' aborts with a classed error (round-2 item A's fix, verified by the "OMITTING
#' kind is a classed caller error" test). The one caller live today,
#' `.fa_confirm_one_alias()` (`R/feature-alias.R`), DOES now pass it
#' (`kind = "unknown_feature"`) - it was NOT touched by round-2's fix but WAS
#' updated in the same round to keep working. A previous version of this
#' paragraph said the opposite of both facts (`kind` optional-with-`NULL`-
#' default, and the caller not passing it), directly contradicting the
#' `@param kind` block below and inviting a reader to write a call that
#' aborts at runtime. `kind = NULL` remains a valid, EXPLICIT escape hatch
#' (see the `@param kind` block) - only silent omission is refused.
#'
#' D6 (the NA trap): an `NA`/zero-length `uuid_target` returns early
#' and closes NOTHING, without erroring. This is NOT relying on SQL's own
#' `= NULL` semantics (which never match) - it is a deliberate R-side guard,
#' because the moment anything ever writes the literal string `"NA"` into
#' `uuid_target`, an interpolated `NA_character_` would stop being safely
#' unmatched by accident.
#'
#' Audit trail (Phase 7b round-2 item C): every closed row is written through
#' `db_update()` (R/mutate.R), the SAME mutation-layer helper
#' `review_queue_add()` routes through via `db_append()` - not a raw
#' `DBI::dbExecute()` UPDATE - so closing a review item now produces
#' `change_log` rows exactly as adding one already does (round-2 FD6/FF9
#' fixed the add side; this closes the matching gap on the close side rather
#' than leaving the two writers with two different audit behaviours). All
#' matched rows are closed inside ONE `db_transaction()`, mirroring
#' `review_queue_add()`'s own FB4 atomicity.
#'
#' @param con an open read-write DBI connection.
#' @param uuid_target the `review_queue.uuid_target` value to close; an
#'   `NA`/zero-length value closes nothing (D6).
#' @param resolution free-text resolution stored on every closed row.
#' @param resolved_by who resolved it.
#' @param kind the `review_queue.kind` to narrow the close to. REQUIRED - it
#'   has no default, so omitting it is a caller error rather than a silent
#'   close across every kind. Pass `kind = NULL` EXPLICITLY for the rare
#'   "resolve everything open on this entity" case; that spelling makes the
#'   choice visible in the diff, which a defaulted `NULL` did not.
#'
#'   **`kind = NULL` is the hazardous option, and it was the default only
#'   until the last caller passed a kind.** `uuid_target` is a POLYMORPHIC key - the
#'   version-5 ladder comment above says so ("`kind` says which table it points
#'   at"), so two rows of different kinds legitimately share one target. A
#'   close that omits `kind` therefore means "resolve everything anyone has
#'   ever opened about this entity", which is almost never what a caller
#'   resolving its OWN item means. The round-2 rank-1 finding was exactly this:
#'   `confirm_feature_aliases()` opened a `sample_collision` row and then its
#'   own close - aimed at the alias's `unknown_feature` row - resolved the
#'   collision row too, in the same transaction, so `review_queue(con, "open")`
#'   returned nothing and the operator was never told that two same-date
#'   samples had been accepted. Pass a `kind`.
#' @return integer count of rows closed, invisibly.
#'
#' NOT EXPORTED, deliberately - symmetric with `review_queue_add()`, which is
#' internal too. An `@export` tag here would be a booby trap: NAMESPACE does
#' not list it today, so the package builds fine, but the next
#' `devtools::document()` would add the export and turn R-10.6 ("NAMESPACE
#' exports equal the CONTRACT-pinned public API exactly") red for a reason
#' that has nothing to do with whatever that run was about.
#' @keywords internal
#' @noRd
review_queue_close <- function(con, uuid_target, resolution, resolved_by, kind) {
  # No default: `kind` is required. Documentation alone did not prevent the
  # round-2 rank-1 defect (a close that swept a different-kind row on the same
  # polymorphic target), so the omission is made impossible rather than merely
  # warned about. `missing()` rather than a default sentinel, so that an
  # explicit `kind = NULL` still reaches the close-across-kinds path.
  if (missing(kind)) {
    cli::cli_abort(
      "review_queue_close() requires `kind`: `uuid_target` is a polymorphic
       key, so a close that does not name a kind resolves every OTHER
       producer's open row on the same target too. Pass the kind you are
       resolving, or `kind = NULL` explicitly to close across all kinds.",
      class = "sampletidy_error"
    )
  }
  # A length-0 or NA target closes nothing (D6). A LONGER vector is neither -
  # it falls through to `assert_string()` and fails loudly, which is the
  # honest outcome; guarding it with `||` alone would raise R >= 4.3's
  # "invalid length argument" from the `is.na()` vector instead of a message
  # naming the argument.
  if (length(uuid_target) == 0L || (length(uuid_target) == 1L && is.na(uuid_target))) {
    return(invisible(0L))
  }
  checkmate::assert_string(uuid_target)
  checkmate::assert_string(resolution)
  checkmate::assert_string(resolved_by)
  if (!is.null(kind)) checkmate::assert_string(kind)

  select_sql <- "SELECT uuid FROM review_queue WHERE uuid_target = ? AND status = 'open'"
  select_params <- list(uuid_target)
  if (!is.null(kind)) {
    select_sql <- paste0(select_sql, " AND kind = ?")
    select_params <- c(select_params, list(kind))
  }

  resolved_at <- Sys.time()
  reason <- sprintf(
    "review_queue_close(): kind=%s", if (is.null(kind)) "ANY" else kind
  )

  # S14 (Phase 7b round 3): the matching SELECT used to run BEFORE
  # db_transaction() opened, so on a standalone (untagged) `con` the matched
  # set was read in autocommit and the UPDATEs ran in a LATER transaction - a
  # non-repeatable-read window between the two. Not reachable today (DuckDB
  # single-writer; the one live caller already passes a tagged `con` from
  # confirm_feature_aliases()'s own db_transaction()), but cheap to close
  # outright: the SELECT now runs INSIDE the same db_transaction() body as
  # the UPDATEs, so the whole read-then-write sequence is one atomic unit
  # regardless of what state `con` arrives in.
  n_closed <- db_transaction(con, function(con) {
    matching <- DBI::dbGetQuery(con, select_sql, params = select_params)$uuid

    # D6's two zero-row cases (the NA/zero-length early return above, and no
    # matching row here) must return the SAME type: the early return already
    # returns invisible(0L) (integer), and length() below is integer too -
    # never DBI::dbExecute()'s native `numeric` (double) count.
    if (length(matching) == 0L) {
      return(0L)
    }

    for (row_uuid in matching) {
      db_update(
        con, "review_queue", uuid = row_uuid,
        changes = list(
          status = "resolved", resolution = resolution,
          resolved_by = resolved_by, resolved_at = resolved_at
        ),
        # S6 (Phase 7b round 3): this used to write actor = .rq_actor
        # ("pipeline"), discarding `resolved_by` and disagreeing with its own
        # sibling `db_update()` in the SAME transaction
        # (`.fa_confirm_one_alias()`, R/feature-alias.R, which uses
        # actor = confirmed_by) - one human confirmation wrote `actor =
        # "robin"` on feature_alias and `actor = "pipeline"` on review_queue.
        # `resolved_by` IS the actor who performed this close; record them,
        # not a generic pipeline placeholder.
        actor = resolved_by, reason = reason
      )
    }
    length(matching)
  })

  invisible(as.integer(n_closed))
}

#' Resolve (close) a single `review_queue` row by its own uuid - the operator
#' API for ANY review kind (Robin's ruling 2, Phase 7b round 3)
#'
#' Before this function existed, NOTHING could close a `sample_collision`
#' review row (Tier-3 finding A4): `review_queue_close()` (D4, above) is
#' unexported, and its one production call site
#' (`.fa_confirm_one_alias()`, `R/feature-alias.R`) hard-filters to
#' `kind = "unknown_feature"` - so every OTHER review kind
#' (`sample_collision`, `value_conflict`, `adapter_tie`, ...) accumulated in
#' the queue with no operator path to drain it, and the only other
#' review-facing exports (`review_queue()`, `review_queue_candidates()`) are
#' read-only.
#'
#' `resolve_review()` targets a review row by its own PRIMARY KEY
#' (`review_queue.uuid`), not the polymorphic `uuid_target`
#' `review_queue_close()` closes on - so there is no `kind` ambiguity to
#' resolve here at all: exactly one row (or none) can ever match a given
#' `uuid`, regardless of what kind raised it. This is deliberately a
#' DIFFERENT, simpler contract from `review_queue_close()` (which stays
#' internal, for the specific "close everything this confirmation raised"
#' shape `.fa_confirm_one_alias()` needs) rather than a public wrapper around
#' it.
#'
#' Writes through the mutation layer (`db_update()`, inside a
#' `db_transaction()`), so the close carries a real `change_log` provenance
#' row with `actor = resolved_by` - the SAME S6 fix `review_queue_close()`
#' above just received, not the `"pipeline"` placeholder.
#'
#' Idempotent: resolving an already-`resolved` (or nonexistent) uuid closes
#' nothing and does not error - mirrors D6's "closes zero rows, never
#' errors" contract on `review_queue_close()`.
#'
#' @param uuid the `review_queue.uuid` to resolve (the row's own primary key
#'   - NOT `uuid_target`).
#' @param resolution free-text resolution stored on the closed row.
#' @param resolved_by who resolved it - mandatory, no default (A55: every
#'   operator write names who performed it).
#' @param db path to the DuckDB file; defaults to `st_config("live_db")`.
#' @return `invisible(TRUE)` if a row was resolved, `invisible(FALSE)` if
#'   `uuid` did not match an open row (already resolved, or does not exist).
#' @export
resolve_review <- function(uuid, resolution, resolved_by, db = st_config("live_db")) {
  checkmate::assert_string(uuid)
  checkmate::assert_string(resolution)
  checkmate::assert_string(resolved_by)
  checkmate::assert_string(db)

  result <- with_db_write(
    function(con) {
      db_transaction(con, function(con) {
        matching <- DBI::dbGetQuery(
          con, "SELECT uuid FROM review_queue WHERE uuid = ? AND status = 'open'",
          params = list(uuid)
        )$uuid
        if (length(matching) == 0L) {
          return(FALSE)
        }
        db_update(
          con, "review_queue", uuid = uuid,
          changes = list(
            status = "resolved", resolution = resolution,
            resolved_by = resolved_by, resolved_at = Sys.time()
          ),
          actor = resolved_by,
          reason = sprintf("resolve_review(): uuid=%s", uuid)
        )
        TRUE
      })
    },
    db = db
  )

  invisible(result)
}
