# Plan 03 - R-3.4 ignore_rule(file_meta), R-3.5 route_files(paths, con),
# R-3.6 router_matrix(paths).

# --- R-3.4 ignore rules ------------------------------------------------

.st_ignore_extensions <- c("bak", "tmp", "ds_store")

#' Decide whether a file should be routed straight to `ignored`
#'
#' Evaluated before adapter matching (R-3.4). Pinned rules: extension in
#' `bak`/`tmp`/`ds_store`; filename `.DS_Store`; zero-byte files. A `[N]`
#' duplicate-download marker in the filename is deliberately **not**
#' ignored here - content-hash dedup (R-3.5/A20) handles those.
#'
#' @param fm a `file_meta()` list.
#' @return a reason string, or `NA_character_` if the file is not ignored.
#' @keywords internal
#' @noRd
ignore_rule <- function(fm) {
  if (fm$ext %in% .st_ignore_extensions) {
    return(paste0("ignored_extension:", fm$ext))
  }
  if (identical(fm$filename, ".DS_Store")) {
    return("ds_store_file")
  }
  if (identical(fm$size, 0) || isTRUE(fm$size == 0)) {
    return("empty_file")
  }
  NA_character_
}

# --- R-3.5 route_files() ------------------------------------------------

# Tier precedence, highest first (DESIGN §5): never "pick a winner" between
# two adapters claiming the same tier - that's a quarantine (adapter_tie).
.st_adapter_tier_precedence <- c("exact", "format", "fallback")

#' Route files to adapters (or ignore/quarantine them), persisting state
#'
#' For each path: builds [file_meta()]; applies [ignore_rule()]; upserts an
#' `ingest_file` row (R-1.6) and records a sighting if this hash has been
#' seen at a different path before (A20/A21). A hash already routed (i.e.
#' its `ingest_file.state` is not `"seen"`) is not re-decided - only its
#' sighting bookkeeping is updated, and the file's stored state/adapter/tier
#' is returned unchanged (this makes re-routing a no-op and keeps every
#' re-route call idempotent against `ingest_file`'s state-transition
#' guards). Otherwise, every registered adapter's `match()` is evaluated:
#' the highest tier with exactly one claimant wins (`claimed`); a tie at
#' the winning tier quarantines with reason `adapter_tie` and a
#' `review_queue` item listing every tied adapter id; no claims at all
#' quarantines with reason `unclaimed`. A `match()` that throws marks only
#' that file `failed` (the error message becomes `state_reason`) and
#' routing continues with the remaining files.
#'
#' @param paths character vector of file paths to route.
#' @param con an open read-write DBI connection (R-3.5/A21).
#' @return a tibble `(path, hash, filename, state, adapter, tier, reason)`.
#' @keywords internal
#' @noRd
route_files <- function(paths, con) {
  checkmate::assert_character(paths, any.missing = FALSE)

  rows <- lapply(paths, function(path) {
    tryCatch(
      .st_route_one_file(path, con),
      error = function(e) {
        tibble::tibble(
          path = path, hash = NA_character_, filename = basename(path),
          state = "failed", adapter = NA_character_, tier = NA_character_,
          reason = conditionMessage(e)
        )
      }
    )
  })

  dplyr::bind_rows(rows)
}

.st_route_one_file <- function(path, con) {
  fm <- file_meta(path)
  hash <- fm$hash

  existing <- DBI::dbGetQuery(
    con,
    "SELECT state, state_reason, adapter, tier FROM ingest_file WHERE hash = ?",
    params = list(hash)
  )
  already_routed <- nrow(existing) > 0 && !identical(existing$state[[1]], "seen")

  ingest_file_upsert(con, hash, path, filename = fm$filename, size = fm$size)

  if (already_routed) {
    return(tibble::tibble(
      path = path, hash = hash, filename = fm$filename,
      state = existing$state[[1]], adapter = existing$adapter[[1]],
      tier = existing$tier[[1]], reason = existing$state_reason[[1]]
    ))
  }

  reason <- ignore_rule(fm)
  if (!is.na(reason)) {
    ingest_file_set_state(con, hash, "ignored", reason)
    return(tibble::tibble(
      path = path, hash = hash, filename = fm$filename, state = "ignored",
      adapter = NA_character_, tier = NA_character_, reason = reason
    ))
  }

  registry <- adapter_registry()
  claims <- character(0)
  for (ad in registry) {
    tier <- tryCatch(ad$match(fm), error = function(e) e)
    if (inherits(tier, "error")) {
      msg <- conditionMessage(tier)
      ingest_file_set_state(con, hash, "failed", msg)
      return(tibble::tibble(
        path = path, hash = hash, filename = fm$filename, state = "failed",
        adapter = NA_character_, tier = NA_character_, reason = msg
      ))
    }
    # R-12.1: a match() that RETURNS (rather than throws) something outside
    # the tier vocabulary must be treated exactly like a thrown match() -
    # this file fails, routing of the others continues (S-12/A59).
    if (!(is.character(tier) && length(tier) == 1 && !is.na(tier) &&
      tier %in% c("exact", "format", "fallback", "no"))) {
      bad_display <- if (length(tier) == 1 && is.character(tier) && is.na(tier)) {
        "NA"
      } else if (length(tier) == 1 && is.character(tier)) {
        tier
      } else {
        paste(deparse(tier), collapse = " ")
      }
      msg <- sprintf(
        "adapter '%s' match() returned an invalid tier value: %s",
        ad$id, bad_display
      )
      ingest_file_set_state(con, hash, "failed", msg)
      return(tibble::tibble(
        path = path, hash = hash, filename = fm$filename, state = "failed",
        adapter = NA_character_, tier = NA_character_, reason = msg
      ))
    }
    claims[[ad$id]] <- tier
  }

  winning_tier <- NA_character_
  winners <- character(0)
  for (t in .st_adapter_tier_precedence) {
    ids_at_t <- names(claims)[claims == t]
    if (length(ids_at_t) > 0) {
      winning_tier <- t
      winners <- ids_at_t
      break
    }
  }

  if (length(winners) == 0) {
    ingest_file_set_state(con, hash, "quarantined", "unclaimed")
    return(tibble::tibble(
      path = path, hash = hash, filename = fm$filename, state = "quarantined",
      adapter = NA_character_, tier = NA_character_, reason = "unclaimed"
    ))
  }

  if (length(winners) == 1) {
    ingest_file_set_state(con, hash, "claimed")
    ingest_file_set_route(con, hash, adapter = winners, tier = winning_tier)
    return(tibble::tibble(
      path = path, hash = hash, filename = fm$filename, state = "claimed",
      adapter = winners, tier = winning_tier, reason = NA_character_
    ))
  }

  # Tie at the winning tier: quarantine, never pick a winner (DESIGN §5).
  ingest_file_set_state(con, hash, "quarantined", "adapter_tie")
  ingest_file_set_route(con, hash, adapter = NA_character_, tier = winning_tier)
  payload <- sprintf(
    '{"tier":"%s","adapters":[%s]}',
    winning_tier, paste(sprintf('"%s"', winners), collapse = ",")
  )
  review_queue_add(
    con, kind = "adapter_tie", work_order = fm$work_order_guess,
    source_hash = hash, payload = payload
  )
  tibble::tibble(
    path = path, hash = hash, filename = fm$filename, state = "quarantined",
    adapter = NA_character_, tier = winning_tier, reason = "adapter_tie"
  )
}

# --- R-3.6 router_matrix() ------------------------------------------------

#' Cross-match every registered adapter against every path
#'
#' No state changes - a read-only harness used to sanity-check adapter
#' coverage over a fixture corpus (plan 10 uses it over the full golden
#' corpus; R-3.6 pins the shape here with a two-adapter smoke test).
#'
#' @param paths character vector of file paths.
#' @return a tibble `(path, adapter, tier)`, one row per adapter x path.
#' @keywords internal
#' @noRd
router_matrix <- function(paths) {
  checkmate::assert_character(paths, any.missing = FALSE)
  registry <- adapter_registry()

  rows <- list()
  for (path in paths) {
    fm <- file_meta(path)
    for (ad in registry) {
      tier <- ad$match(fm)
      rows[[length(rows) + 1]] <- tibble::tibble(path = path, adapter = ad$id, tier = tier)
    }
  }

  dplyr::bind_rows(rows)
}
