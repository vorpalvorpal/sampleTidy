# PLAN-16 (B-16.migration) - operator-run migration: convert the 96 legacy
# review_queue.payload rows into the version-6 typed shape (R-16.12, R-16.13
# ONLY - the v6 DDL itself, 6a's three columns + 6b's `review_queue_candidate`
# table, is the SEPARATE auto migration at `.st_schema_migrations` version 6
# in R/db-schema.R, applied by `ensure_schema()` on open; this file is only
# the DATA half, run deliberately by an operator, because it is lossy).
#
# NEVER invoked by package code (A50, mirroring 001/002) - an operator runs
# it directly, e.g.:
#   env <- new.env()
#   sys.source("dev/migrations/006-review-queue-payload.R", envir = env)
#   env$mig006_run(db = "/path/to/monitoring.duckdb",
#                   snapshot_dir = "/path/to/snapshots", dry_run = TRUE)
#
# Depends on schema version 6 already being applied to `db` (R/db-schema.R's
# `ensure_schema()` on open, or the fixture-local hand-apply in this test's
# own helper) - `review_queue.subkind`/`uuid_existing`/`uuid_alias` and the
# `review_queue_candidate` table must already exist before this file's rows
# can be written.
#
# ---- schema_version marker ---------------------------------------------
# Same representation choice as `001-alias-indirection.R`: an INTEGER version
# reserved well outside the 1-6 ladder `.st_schema_migrations` (R/db-schema.R)
# tracks in the SAME `schema_version` table, following the "script number ->
# 1000 + N" convention 001 established (1001 for 001; 1006 for 006 here) so
# the two numbering spaces cannot collide.
.mig006_marker_version <- 1006L

.mig006_default <- function(x, default) if (is.null(x)) default else x

# ---- Row-count invariant: review_queue never gains or loses a row here -----
# (only fields are UPDATEd; `review_queue_candidate` GAINS rows, tracked
# separately). Mirrors 001/002's own hard-verify-gate style.
.mig006_rq_count <- function(con) DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM review_queue")$n[[1]]

# =============================================================================
# format (b): asset_content_unverified -> subkind = 'hash_mismatch' +
#             uuid_existing + a single-key `filename` JSON remainder
# =============================================================================

#' Parse one hand-rolled `asset_content_unverified` JSON payload
#'
#' The exact live shape (evidence file Sec1, `scratchpad/f18_apply.R:86`):
#' `{"uuid_asset":..., "filename":..., "state":...}`, unescaped `sprintf` JSON.
#' Pure - no DB access.
#'
#' @param payload the raw `review_queue.payload` string.
#' @return `list(uuid_asset, filename, state)`.
#' @keywords internal
#' @noRd
.mig006_parse_asset_payload <- function(payload, review_uuid) {
  parsed <- tryCatch(
    jsonlite::fromJSON(payload),
    error = function(e) {
      cli::cli_abort(
        "006-review-queue-payload: review_queue {review_uuid}'s asset_content_unverified payload is not valid JSON: {conditionMessage(e)}",
        class = "sampletidy_error"
      )
    }
  )
  list(
    uuid_asset = parsed[["uuid_asset"]],
    filename = parsed[["filename"]],
    state = parsed[["state"]]
  )
}

#' Convert every un-migrated `asset_content_unverified` row (R-16.12)
#'
#' Per row (keyed by the row's OWN `uuid`, never by position or a re-sort):
#' parses the JSON payload, VERIFIES `uuid_asset` resolves to a live `asset`
#' row (load-bearing - `review_queue_candidate.uuid_feature` and this column
#' both carry no FK, D1, so the migration is the only thing that will ever
#' catch a bad reference), then writes `subkind = 'hash_mismatch'`,
#' `uuid_existing = uuid_asset`, and a JSON remainder holding ONLY `filename`
#' (`state` is a one-member enum -> `subkind`; `uuid_asset` -> `uuid_existing`;
#' both are promoted OUT of the remainder, per B-16.formats). Every write goes
#' through `db_update()` (mutation layer, `review_queue` is allowlisted) -
#' never raw SQL - so each conversion gets its own `change_log` row.
#'
#' @param con an open read-write DBI connection (participates in the
#'   caller's open mutation-layer transaction).
#' @param actor who is making this change.
#' @param reason free-text reason, stored on every `change_log` row.
#' @return integer count of rows converted.
#' @keywords internal
#' @noRd
mig006_convert_asset_rows <- function(con, actor, reason) {
  rows <- DBI::dbGetQuery(
    con,
    "SELECT uuid, payload FROM review_queue
       WHERE kind = 'asset_content_unverified' AND subkind IS NULL
       ORDER BY uuid"
  )

  for (i in seq_len(nrow(rows))) {
    review_uuid <- rows$uuid[[i]]
    parsed <- .mig006_parse_asset_payload(rows$payload[[i]], review_uuid)

    # ---- VERIFY resolution: uuid_existing carries NO FK (D1) -------------
    # the database will not catch a bad uuid_asset here, so this migration
    # must, and must do it PER ROW keyed on the row's OWN payload value -
    # never positionally and never by re-sorting on filename/asset-uuid
    # (the mis-JOIN R-16.12 exists to catch).
    resolved <- DBI::dbGetQuery(
      con, "SELECT COUNT(*) n FROM asset WHERE uuid = ?", params = list(parsed$uuid_asset)
    )$n[[1]]
    if (resolved == 0) {
      cli::cli_abort(
        "006-review-queue-payload: review_queue {review_uuid}'s uuid_asset {parsed$uuid_asset} does not resolve to a live asset row - refusing to write an unverifiable uuid_existing.",
        class = "sampletidy_error"
      )
    }

    remainder <- as.character(jsonlite::toJSON(list(filename = parsed$filename), auto_unbox = TRUE))

    db_update(
      con, "review_queue", uuid = review_uuid,
      changes = list(subkind = "hash_mismatch", uuid_existing = parsed$uuid_asset, payload = remainder),
      actor = actor, reason = reason
    )
  }

  nrow(rows)
}

# =============================================================================
# format (a): legacy k=v grammar -> typed columns + review_queue_candidate
# =============================================================================

#' Parse one legacy `k=v` review_queue payload (evidence file Sec3)
#'
#' Grammar: comma-separated tokens; a token containing `=` is a `key=value`
#' pair (split on the FIRST `=` only, so a value may itself contain `=`); a
#' token with no `=` is an unkeyed positional entry, collected in order into
#' `source_ref`. `subkind=`/`work_order=` are the two keys that promote to
#' real `review_queue` columns; `candidates=` is a `|`-separated list of
#' feature uuids: one `review_queue_candidate` row per entry, in list order
#' (`rank`). Everything else (`analyte_raw=`, `feature_raw=`, `n_rows=`,
#' `org=`, ...) is diagnostics, not an entity reference, and stays in the JSON
#' remainder verbatim (B-16.formats: "not exempted", but these keys were
#' never a real column either). Pure - no DB access.
#'
#' @param payload the raw `review_queue.payload` string.
#' @return `list(source_ref, subkind, candidates, remainder)` - `remainder`
#'   a named list of leftover key/value pairs (character), for JSON encoding.
#' @keywords internal
#' @noRd
.mig006_parse_kv_payload <- function(payload) {
  tokens <- strsplit(payload, ",", fixed = TRUE)[[1]]
  is_kv <- grepl("=", tokens, fixed = TRUE)

  source_ref <- tokens[!is_kv]
  kv_tokens <- tokens[is_kv]
  keys <- sub("=.*$", "", kv_tokens)
  vals <- sub("^[^=]*=", "", kv_tokens)

  get1 <- function(k) {
    hit <- vals[keys == k]
    if (length(hit) == 0) NA_character_ else hit[[1]]
  }

  subkind <- get1("subkind")
  candidates_raw <- get1("candidates")
  candidates <- if (is.na(candidates_raw)) NULL else strsplit(candidates_raw, "|", fixed = TRUE)[[1]]

  remainder_keys <- setdiff(keys, c("subkind", "work_order", "candidates"))
  remainder <- stats::setNames(as.list(vals[match(remainder_keys, keys)]), remainder_keys)

  list(source_ref = source_ref, subkind = subkind, candidates = candidates, remainder = remainder)
}

#' Convert every un-migrated legacy k=v row (R-16.13)
#'
#' Selects candidate rows by `kind` in SQL, then filters in R on
#' `!startsWith(payload, "{")` - a k=v payload is never valid JSON at its
#' start, while every already-typed producer (post Phase-6, `.rq_row()`
#' onward) writes a JSON payload starting with `{`, so this selection never
#' re-touches an already-structured row even though it shares `kind` with the
#' legacy shape (R-16.6: the payload-shape decision is made in R, never in
#' SQL). `work_order` is left untouched - it is ALREADY a real column
#' (set at the original `review_queue_add()` call, duplicated in the payload
#' text too, the live shape) - this migration only removes the duplicate text
#' from the remainder, never rewrites the column. `subkind` and `candidates`
#' are read from the payload text (the column starts NULL, per R-16.13's own
#' positive control) and promoted. Each `candidates=` uuid is VERIFIED against
#' `feature` before any `review_queue_candidate` row is written (D1: no FK)
#' -  per entry, never assuming the live-evidence "all 4 resolve" fact holds
#' for an arbitrary future row. Every write goes through `db_update()`/
#' `db_append()` (mutation layer) - never raw SQL.
#'
#' @param con an open read-write DBI connection.
#' @param actor who is making this change.
#' @param reason free-text reason, stored on every `change_log` row.
#' @return `list(n_kv, n_candidates)`.
#' @keywords internal
#' @noRd
mig006_convert_kv_rows <- function(con, actor, reason) {
  rows <- DBI::dbGetQuery(
    con,
    "SELECT uuid, payload FROM review_queue
       WHERE kind IN ('unknown_analyte', 'unknown_feature')
       ORDER BY uuid"
  )
  rows <- rows[!startsWith(rows$payload, "{"), , drop = FALSE]

  n_candidates <- 0L

  for (i in seq_len(nrow(rows))) {
    review_uuid <- rows$uuid[[i]]
    parsed <- .mig006_parse_kv_payload(rows$payload[[i]])

    if (!is.null(parsed$candidates) && length(parsed$candidates) > 0) {
      # ---- VERIFY resolution: uuid_feature carries NO FK (D1, R-16.3) -----
      for (cand_uuid in parsed$candidates) {
        resolved <- DBI::dbGetQuery(
          con, "SELECT COUNT(*) n FROM feature WHERE uuid = ?", params = list(cand_uuid)
        )$n[[1]]
        if (resolved == 0) {
          cli::cli_abort(
            "006-review-queue-payload: review_queue {review_uuid}'s candidate {cand_uuid} does not resolve to a live feature row - refusing to write an unverifiable uuid_feature.",
            class = "sampletidy_error"
          )
        }
      }

      n <- length(parsed$candidates)
      cand_df <- data.frame(
        uuid = vapply(seq_len(n), function(x) uuid::UUIDgenerate(), character(1)),
        uuid_review = review_uuid,
        uuid_feature = parsed$candidates,
        kind = "candidate",
        date_start = as.Date(rep(NA, n)),
        date_end = as.Date(rep(NA, n)),
        rank = seq_len(n),
        stringsAsFactors = FALSE
      )
      db_append(con, "review_queue_candidate", cand_df, actor = actor, reason = reason)
      n_candidates <- n_candidates + n
    }

    remainder_body <- c(list(source_ref = parsed$source_ref), parsed$remainder)
    remainder <- as.character(jsonlite::toJSON(remainder_body, auto_unbox = TRUE))

    db_update(
      con, "review_queue", uuid = review_uuid,
      changes = list(subkind = parsed$subkind, payload = remainder),
      actor = actor, reason = reason
    )
  }

  list(n_kv = nrow(rows), n_candidates = n_candidates)
}

# =============================================================================
# mig006_backup() - snapshot-FIRST, because the data conversion is lossy
# =============================================================================

.mig006_backup_counts <- function(con) {
  list(
    review_queue = DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM review_queue")$n,
    review_queue_candidate = DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM review_queue_candidate")$n
  )
}

#' Back up and VERIFY the live DB before any write (mirrors 001/002's own
#' `migNNN_backup()`) - this migration is one-way and lossy (B-16.migration:
#' the unkeyed `source_ref` prefix becomes a JSON array), so it snapshots
#' first, per the standing DB-changing-session rule.
#'
#' @param db path to the live DuckDB file.
#' @param snapshot_dir directory to write the backup into.
#' @param .now inject a POSIXct instead of `Sys.time()`.
#' @return absolute path to the verified backup copy.
mig006_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- .mig006_default(.now, Sys.time())
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  fname <- sprintf("monitoring_pre-006-review-queue-payload_%sZ.duckdb", ts)
  dest <- file.path(snapshot_dir, fname)

  live_counts <- with_db_write(
    function(con) {
      DBI::dbExecute(con, "CHECKPOINT")
      counts <- .mig006_backup_counts(con)
      ok <- tryCatch(
        suppressWarnings(file.copy(db, dest, overwrite = FALSE)),
        error = function(e) FALSE
      )
      if (!isTRUE(ok)) {
        cli::cli_abort(
          "{db}: failed to write backup copy to {dest}.",
          class = "sampletidy_error"
        )
      }
      counts
    },
    db = db
  )

  verify_con <- tryCatch(
    DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE),
    error = function(e) NULL
  )
  if (is.null(verify_con)) {
    cli::cli_abort(
      "{db}: backup verification failed - cannot open {dest} read-only.",
      class = "sampletidy_error"
    )
  }
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)

  backup_counts <- .mig006_backup_counts(verify_con)
  if (!identical(live_counts, backup_counts)) {
    cli::cli_abort(
      "{db}: backup verification failed - row counts differ between live DB and {dest}.",
      class = "sampletidy_error"
    )
  }

  dest
}

# =============================================================================
# mig006_run() - backup / verify / transaction discipline (mirrors 001/002)
# =============================================================================

#' Run (or dry-run) the 006-review-queue-payload data migration
#' (R-16.12 + R-16.13)
#'
#' The DATA half of PLAN-16's migration (B-16.migration) - the v6 DDL itself
#' (6a's three `review_queue` columns, 6b's `review_queue_candidate` table)
#' is a SEPARATE, auto migration applied by `ensure_schema()` on open; this
#' function assumes it already ran. Converts every un-migrated
#' `asset_content_unverified` row (`mig006_convert_asset_rows()`) and every
#' un-migrated legacy k=v row (`mig006_convert_kv_rows()`) inside ONE
#' mutation-layer transaction (`db_transaction()`), so a verification failure
#' on any single row - a `uuid_asset`/candidate that fails to resolve, since
#' neither carries a database-level FK (D1) - rolls back the WHOLE run rather
#' than leaving a half-converted table. Backs up and verifies first (skipped
#' on `dry_run = TRUE`, which writes nothing at all). Records completion as a
#' `schema_version` marker (1006L, the 001-precedent "1000 + script number"
#' representation) so a re-run is a fast, read-only no-op.
#'
#' @param db path to the live DuckDB file.
#' @param snapshot_dir directory for the pre-migration backup.
#' @param dry_run if `TRUE`, print what would happen and write nothing.
#' @param .now inject a POSIXct instead of `Sys.time()` (propagated to the
#'   backup filename and the schema_version marker).
#' @return invisible list(status = "migrated" | "already_migrated" | "dry_run",
#'   backup_path, restore_command, n_asset, n_kv, n_candidates, recorded_at).
mig006_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))

  # ---- idempotency guard - read-only, writes nothing. ----
  marker_con <- st_connect(db, read_only = TRUE)
  marker <- tryCatch(
    DBI::dbGetQuery(
      marker_con, "SELECT applied_at FROM schema_version WHERE version = ?",
      params = list(.mig006_marker_version)
    ),
    finally = DBI::dbDisconnect(marker_con, shutdown = TRUE)
  )

  if (nrow(marker) > 0) {
    recorded_at <- marker$applied_at[[1]]
    logf("006-review-queue-payload already applied at %s; nothing to do.", format(recorded_at))
    return(invisible(list(
      status = "already_migrated",
      backup_path = NA_character_,
      restore_command = NA_character_,
      n_asset = NA_integer_,
      n_kv = NA_integer_,
      n_candidates = NA_integer_,
      recorded_at = recorded_at
    )))
  }

  # ---- dry-run: preview only, write nothing (no backup either). ----
  if (isTRUE(dry_run)) {
    preview_con <- st_connect(db, read_only = TRUE)
    preview <- tryCatch(
      {
        asset_rows <- DBI::dbGetQuery(
          preview_con,
          "SELECT COUNT(*) n FROM review_queue WHERE kind = 'asset_content_unverified' AND subkind IS NULL"
        )$n[[1]]
        kv_rows <- DBI::dbGetQuery(
          preview_con,
          "SELECT payload FROM review_queue
             WHERE kind IN ('unknown_analyte', 'unknown_feature')"
        )
        kv_rows <- kv_rows[!startsWith(kv_rows$payload, "{"), , drop = FALSE]
        n_candidates <- sum(vapply(kv_rows$payload, function(p) {
          length(.mig006_parse_kv_payload(p)$candidates)
        }, integer(1)))
        list(n_asset = asset_rows, n_kv = nrow(kv_rows), n_candidates = n_candidates)
      },
      finally = DBI::dbDisconnect(preview_con, shutdown = TRUE)
    )
    logf("DRY RUN: %d asset_content_unverified row(s) would convert.", preview$n_asset)
    logf("DRY RUN: %d legacy k=v row(s) would convert (%d candidate row(s)).", preview$n_kv, preview$n_candidates)
    logf("DRY RUN: no backup taken, no writes made to %s.", db)
    return(invisible(list(
      status = "dry_run",
      backup_path = NA_character_,
      restore_command = NA_character_,
      n_asset = preview$n_asset,
      n_kv = preview$n_kv,
      n_candidates = preview$n_candidates,
      recorded_at = NA
    )))
  }

  # ---- back up and verify, before any write. ----
  backup_path <- mig006_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)

  recorded_at <- .mig006_default(.now, Sys.time())

  result <- with_db_write(
    function(con) {
      db_transaction(con, function(con) {
        rq_before <- .mig006_rq_count(con)

        n_asset <- mig006_convert_asset_rows(
          con, actor = "migration-006",
          reason = "PLAN-16 B-16.migration: asset_content_unverified payload to typed columns"
        )
        kv <- mig006_convert_kv_rows(
          con, actor = "migration-006",
          reason = "PLAN-16 B-16.migration: legacy k=v payload to typed columns + candidate rows"
        )

        # ---- hard verify gate: review_queue never gains/loses a row here ----
        rq_after <- .mig006_rq_count(con)
        if (!identical(rq_before, rq_after)) {
          cli::cli_abort(
            "006-review-queue-payload verify failed: review_queue row count changed (before {rq_before}, after {rq_after}).",
            class = "sampletidy_error"
          )
        }

        DBI::dbExecute(
          con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
          params = list(.mig006_marker_version, recorded_at)
        )

        list(n_asset = n_asset, n_kv = kv$n_kv, n_candidates = kv$n_candidates)
      })
    },
    db = db
  )

  logf(
    "006-review-queue-payload migrated: %d asset_content_unverified row(s), %d k=v row(s), %d candidate row(s).",
    result$n_asset, result$n_kv, result$n_candidates
  )

  invisible(list(
    status = "migrated",
    backup_path = backup_path,
    restore_command = restore_command,
    n_asset = result$n_asset,
    n_kv = result$n_kv,
    n_candidates = result$n_candidates,
    recorded_at = recorded_at
  ))
}
