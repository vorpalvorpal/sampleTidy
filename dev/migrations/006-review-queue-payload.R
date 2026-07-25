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

# Phase-7b audit (slice C) escape hatch: several abort messages below embed
# raw, untrusted payload text into a `cli_abort()` message, and `cli_abort()`
# glue-interpolates its message - a literal `{`/`}` inside that text (a
# legitimate character in JSON, or in an analyte name) would otherwise be
# read as a glue expression and error out instead of reporting cleanly. Used
# wherever a raw payload/JSON string is interpolated for an operator to read.
.mig006_glue_escape <- function(x) {
  x <- gsub("{", "{{", x, fixed = TRUE)
  gsub("}", "}}", x, fixed = TRUE)
}

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
#' Phase-7b audit (FC5/FC7): a payload missing `filename` (or any of the
#' three keys) is refused rather than silently converted - without this
#' gate, a missing `filename` serialises as the JSON *object* `{}` in the
#' remainder (a NULL passed through `toJSON()`), a 4th key is silently
#' dropped, and a missing `uuid_asset` reaches an unnamed, unreachable-abort
#' R error two lines below (`argument is of length zero`) instead of the
#' named `cli_abort()` this function's caller was written to raise. Requiring
#' the key SET to equal exactly the three known keys, each a non-NULL,
#' length-1 string, subsumes all three failure modes in one gate.
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

  expected_keys <- c("uuid_asset", "filename", "state")
  is_ok_string <- function(x) is.character(x) && length(x) == 1L && !is.na(x)
  ok <- is.list(parsed) &&
    setequal(names(parsed), expected_keys) &&
    all(vapply(parsed[expected_keys], is_ok_string, logical(1)))

  if (!isTRUE(ok)) {
    cli::cli_abort(
      sprintf(
        "006-review-queue-payload: review_queue %s's asset_content_unverified payload does not have exactly the three expected keys (uuid_asset, filename, state), each a non-NULL single string - refusing to guess. payload: %s",
        review_uuid, .mig006_glue_escape(payload)
      ),
      class = "sampletidy_error"
    )
  }

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

#' The complete legacy k=v key vocabulary (evidence file Sec3/Sec4) - the
#' two keys that promote to real columns (`subkind`, `work_order`), the one
#' that becomes `review_queue_candidate` rows (`candidates`), and the
#' diagnostics-only keys observed in the live 4 rows. Phase-7b audit (D1/FC8):
#' any key outside this list makes the row `suspect` rather than silently
#' folding the unrecognised key into the JSON remainder.
.mig006_kv_vocabulary <- c(
  "subkind", "work_order", "candidates",
  "analyte_raw", "feature_raw", "n_rows", "org"
)

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
#' Phase-7b audit (DIAGNOSIS D1): the grammar's ONLY delimiter, `,`, is never
#' escaped by the producer (`R/reconcile.R:817` joins `source_ref` with `,`
#' too), so a comma *inside* a value (routine for `analyte_raw` - e.g.
#' `1,2-Dichloroethane`) is genuinely AMBIGUOUS, not merely awkward: no
#' algorithm can tell "value `1,2-Dichloroethane`" from "value `1` followed by
#' an unkeyed `2-Dichloroethane`". A cleverer parser would still be guessing,
#' silently. So this function does not attempt one - it parses optimistically
#' AND flags `suspect = TRUE` (with `reasons`) whenever the input could not
#' possibly have come from an honest instance of the grammar: an unkeyed
#' token appears after the first `k=v` token (what a comma-split value always
#' produces - the live grammar always emits the unkeyed `source_ref` prefix
#' first, so this alone catches every corruption case the audit could
#' construct), a key repeats, a key falls outside the known vocabulary, a
#' token or a key is empty, or `candidates=` is malformed (empty, or a
#' leading/double/trailing `|`, all silently lossy under `strsplit()`). The
#' caller aborts the whole run rather than convert a `suspect` row.
#'
#' @param payload the raw `review_queue.payload` string.
#' @return `list(source_ref, subkind, work_order, candidates, remainder,
#'   suspect, reasons)` - `remainder` a named list of leftover key/value
#'   pairs (character), for JSON encoding; `reasons` a character vector
#'   describing every grammar violation found (empty when `suspect` is
#'   `FALSE`).
#' @keywords internal
#' @noRd
.mig006_parse_kv_payload <- function(payload) {
  tokens <- strsplit(payload, ",", fixed = TRUE)[[1]]
  is_kv <- grepl("=", tokens, fixed = TRUE)

  reasons <- character(0)

  if (length(tokens) == 0 || any(tokens == "")) {
    reasons <- c(reasons, "an empty token (adjacent/leading/trailing comma)")
  }

  first_kv_idx <- which(is_kv)[1]
  if (!is.na(first_kv_idx) && any(!is_kv[seq_along(tokens) > first_kv_idx])) {
    reasons <- c(
      reasons,
      "an unkeyed token after the first k=v token - an unescaped comma inside a value (D1)"
    )
  }

  source_ref <- tokens[!is_kv]
  kv_tokens <- tokens[is_kv]
  keys <- sub("=.*$", "", kv_tokens)
  vals <- sub("^[^=]*=", "", kv_tokens)

  if (any(keys == "")) {
    reasons <- c(reasons, "an empty key (a token starting with '=')")
  }
  if (anyDuplicated(keys) > 0) {
    reasons <- c(
      reasons,
      sprintf("a repeated key (%s)", paste(unique(keys[duplicated(keys)]), collapse = ", "))
    )
  }
  unknown_keys <- unique(setdiff(keys[keys != ""], .mig006_kv_vocabulary))
  if (length(unknown_keys) > 0) {
    reasons <- c(
      reasons,
      sprintf("key(s) outside the known vocabulary (%s)", paste(unknown_keys, collapse = ", "))
    )
  }

  get1 <- function(k) {
    hit <- vals[keys == k]
    if (length(hit) == 0) NA_character_ else hit[[1]]
  }

  subkind <- get1("subkind")
  work_order <- get1("work_order")
  candidates_raw <- get1("candidates")
  candidates_malformed <- !is.na(candidates_raw) &&
    (candidates_raw == "" || grepl("^\\||\\|\\||\\|$", candidates_raw))
  if (candidates_malformed) {
    reasons <- c(reasons, sprintf("a malformed candidates= value (%s)", candidates_raw))
  }
  candidates <- if (is.na(candidates_raw) || candidates_raw == "") {
    NULL
  } else {
    strsplit(candidates_raw, "|", fixed = TRUE)[[1]]
  }

  remainder_keys <- setdiff(keys, c("subkind", "work_order", "candidates"))
  remainder <- stats::setNames(as.list(vals[match(remainder_keys, keys)]), remainder_keys)

  list(
    source_ref = source_ref, subkind = subkind, work_order = work_order,
    candidates = candidates, remainder = remainder,
    suspect = length(reasons) > 0, reasons = reasons
  )
}

#' Select the un-migrated legacy k=v `review_queue` rows out of `rows`
#'
#' `rows` must have already been read with columns `uuid`, `payload` (and
#' whatever else the caller needs). A k=v payload is never valid JSON at its
#' start, while every already-typed producer (post Phase-6, `.rq_row()`
#' onward) writes a JSON payload starting with `{`, so filtering on
#' `!startsWith(payload, "{")` never re-touches an already-structured row
#' even though it shares `kind` with the legacy shape (R-16.6: the
#' payload-shape decision is made in R, never in SQL).
#'
#' Phase-7b audit (FC6): `payload` is a nullable column
#' (`R/db-schema.R`), and `startsWith(NA, "{")` is `NA`, not `FALSE` - so the
#' naive filter above ADMITS a NULL-payload row (as a phantom all-NA row,
#' since `NA` is neither `TRUE` nor `FALSE` in `[`) while the row it was
#' filtering FOR is unaffected, silently letting a real row's payload be lost
#' downstream and making the actual `mig006_run()` abort message (deep inside
#' checkmate, on `uuid`, naming no row) undiagnosable. Refuse up front,
#' naming the offending `uuid`, instead.
#'
#' @param rows a data frame with `uuid`, `payload` columns.
#' @return `rows`, filtered to just the legacy k=v candidates.
#' @keywords internal
#' @noRd
.mig006_filter_kv_candidates <- function(rows) {
  na_payload <- rows$uuid[is.na(rows$payload)]
  if (length(na_payload) > 0) {
    cli::cli_abort(
      sprintf(
        "006-review-queue-payload: review_queue row(s) %s have a NULL payload - refusing to guess whether they are legacy k=v text or already-migrated JSON.",
        paste(na_payload, collapse = ", ")
      ),
      class = "sampletidy_error"
    )
  }
  rows[!startsWith(rows$payload, "{"), , drop = FALSE]
}

#' Convert every un-migrated legacy k=v row (R-16.13)
#'
#' Selects candidate rows by `kind` in SQL, then narrows to the legacy shape
#' with `.mig006_filter_kv_candidates()`. `work_order` is ALREADY a real
#' column (set at the original `review_queue_add()` call, duplicated in the
#' payload text too, the live shape); Phase-7b audit (FC3) - rather than
#' silently discard the payload's copy on the assumption the column agrees,
#' this reads the column and ABORTS on any row where both are present and
#' disagree, and back-fills the column from the payload when the column is
#' NULL (a legacy row whose column was never set would otherwise lose the
#' payload's copy, the only surviving one, with no trace). `subkind` and
#' `candidates` are read from the payload text (the column starts NULL, per
#' R-16.13's own positive control) and promoted. Each `candidates=` uuid is
#' VERIFIED against `feature` before any `review_queue_candidate` row is
#' written (D1: no FK) - per entry, never assuming the live-evidence "all 4
#' resolve" fact holds for an arbitrary future row.
#'
#' Phase-7b audit (DIAGNOSIS D1, FC1/FC4/FC8/FC12): the legacy grammar's only
#' delimiter is unescaped and genuinely ambiguous (see
#' `.mig006_parse_kv_payload()`), so before converting ANYTHING this parses
#' every candidate row and, if ANY is `suspect`, aborts the WHOLE run naming
#' every suspect `(uuid, payload)` - refusing to convert is recoverable;
#' guessing wrong is not, and after the completion marker is written the
#' source text is gone for good.
#'
#' Every write goes through `db_update()`/`db_append()` (mutation layer) -
#' never raw SQL.
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
    "SELECT uuid, payload, work_order FROM review_queue
       WHERE kind IN ('unknown_analyte', 'unknown_feature')
       ORDER BY uuid"
  )
  rows <- .mig006_filter_kv_candidates(rows)

  parsed_list <- lapply(rows$payload, .mig006_parse_kv_payload)

  # ---- D1 refusal gate: check EVERY row before converting ANY row --------
  suspect_idx <- which(vapply(parsed_list, function(p) p$suspect, logical(1)))
  if (length(suspect_idx) > 0) {
    detail <- vapply(suspect_idx, function(i) {
      sprintf(
        "  - review_queue %s: %s | payload: %s",
        rows$uuid[[i]],
        paste(parsed_list[[i]]$reasons, collapse = "; "),
        .mig006_glue_escape(rows$payload[[i]])
      )
    }, character(1))
    cli::cli_abort(
      paste0(
        sprintf(
          "006-review-queue-payload: %d legacy k=v row(s) do not match the migration's known grammar - refusing to guess (the comma delimiter is unescaped and ambiguous, D1). Fix or hand-convert these rows, then re-run:\n",
          length(suspect_idx)
        ),
        paste(detail, collapse = "\n")
      ),
      class = "sampletidy_error"
    )
  }

  n_candidates <- 0L

  for (i in seq_len(nrow(rows))) {
    review_uuid <- rows$uuid[[i]]
    parsed <- parsed_list[[i]]

    # ---- FC3: work_order column vs payload text must agree -----------------
    changes <- list(subkind = parsed$subkind)
    kv_work_order <- parsed$work_order
    row_work_order <- rows$work_order[[i]]
    if (!is.na(kv_work_order)) {
      if (is.na(row_work_order)) {
        changes$work_order <- kv_work_order
      } else if (!identical(row_work_order, kv_work_order)) {
        cli::cli_abort(
          "006-review-queue-payload: review_queue {review_uuid}'s work_order column ({row_work_order}) disagrees with its payload's work_order= ({kv_work_order}) - refusing to guess which is authoritative.",
          class = "sampletidy_error"
        )
      }
    }

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

    # ---- FC9: source_ref is ALWAYS a JSON array, never a bare string or {} -
    remainder_body <- c(list(source_ref = I(parsed$source_ref)), parsed$remainder)
    remainder <- as.character(jsonlite::toJSON(remainder_body, auto_unbox = TRUE))
    changes$payload <- remainder

    db_update(
      con, "review_queue", uuid = review_uuid,
      changes = changes,
      actor = actor, reason = reason
    )
  }

  list(n_kv = nrow(rows), n_candidates = n_candidates)
}

# =============================================================================
# mig006_backup() - snapshot-FIRST, because the data conversion is lossy
# =============================================================================

# Phase-7b audit (FC10): the original version compared ONLY the two
# review-table COUNTs, so a snapshot copy that lost every `asset` (or
# `feature`/`analysis`/`sample`/`change_log`) row still passed as "Backup
# verified" - even though this migration's own per-row VERIFY steps
# (`mig006_convert_asset_rows()`'s `uuid_asset` resolution,
# `mig006_convert_kv_rows()`'s `candidates=` resolution) depend on `asset`
# and `feature` being intact, and this snapshot is the restore point for a
# one-way, lossy rewrite. Extended to COUNT every table the migration reads
# or could plausibly need to restore, plus a content digest over
# `review_queue` itself (mirrors `001-alias-indirection.R:56-82`
# `mig001_counts_checksum()`, which hashes actual row content, not just
# counts).
.mig006_backup_counts <- function(con) {
  list(
    review_queue = DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM review_queue")$n,
    review_queue_candidate = DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM review_queue_candidate")$n,
    asset = DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM asset")$n,
    feature = DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM feature")$n,
    analysis = DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM analysis")$n,
    sample = DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM \"sample\"")$n,
    change_log = DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM change_log")$n,
    review_queue_digest = digest::digest(
      DBI::dbGetQuery(con, "SELECT uuid, kind, payload FROM review_queue ORDER BY uuid"),
      algo = "sha1"
    )
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
#' Phase-7b audit (FC2): the hard verify gate below only ever checked that
#' `review_queue`'s row COUNT was unchanged - true even when `n_asset` and
#' `n_kv` are both 0, e.g. a run against the wrong DB, or a re-run whose
#' marker was wiped after a prior real run - so that a zero-row run reported
#' `status = "migrated"` and wrote the permanent completion marker, locking
#' the real run out forever as `already_migrated`. `expect_asset`/`expect_kv`
#' pin the population this migration was written for (92 `asset_content_unverified`
#' rows, 4 legacy k=v rows, per the live evidence); the run aborts before the
#' marker INSERT unless the counts actually converted match exactly.
#'
#' @param db path to the live DuckDB file.
#' @param snapshot_dir directory for the pre-migration backup.
#' @param dry_run if `TRUE`, print what would happen and write nothing.
#' @param expect_asset the exact number of `asset_content_unverified` rows
#'   this run must convert (FC2); the marker is not written otherwise.
#' @param expect_kv the exact number of legacy k=v rows this run must convert
#'   (FC2); the marker is not written otherwise.
#' @param .now inject a POSIXct instead of `Sys.time()` (propagated to the
#'   backup filename and the schema_version marker).
#' @return invisible list(status = "migrated" | "already_migrated" | "dry_run",
#'   backup_path, restore_command, n_asset, n_kv, n_candidates, recorded_at).
mig006_run <- function(db, snapshot_dir, dry_run = FALSE,
                        expect_asset = 92L, expect_kv = 4L, .now = NULL) {
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
          "SELECT uuid, payload FROM review_queue
             WHERE kind IN ('unknown_analyte', 'unknown_feature')"
        )
        # FC6: same NULL-payload guard as the real conversion path - without
        # it, a dry-run rehearsal silently COUNTS a phantom all-NA row in
        # place of the real one and reports "fine", and the real run then
        # dies deep in checkmate, naming no row.
        kv_rows <- .mig006_filter_kv_candidates(kv_rows)
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

        # ---- FC2: refuse to write the permanent marker on an unexpected
        # population - this is the ONLY gate in this function that can
        # actually catch a wrong-DB / zero-row run, since rq_before/rq_after
        # above are equal by construction (review_queue never gains or loses
        # a row here; only review_queue_candidate gains rows).
        if (!identical(as.integer(n_asset), as.integer(expect_asset)) ||
            !identical(as.integer(kv$n_kv), as.integer(expect_kv))) {
          cli::cli_abort(
            "006-review-queue-payload verify failed: converted {n_asset} asset_content_unverified row(s) and {kv$n_kv} legacy k=v row(s), expected {expect_asset} and {expect_kv} - refusing to write the completion marker (pass expect_asset/expect_kv to override).",
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
