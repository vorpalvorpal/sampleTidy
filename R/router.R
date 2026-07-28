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
#' @param dry_run ingest.R's dry-run switch. Only `claimed` persists on both
#'   a dry and a real run (T1.2): it is a non-terminal handoff, not a
#'   verdict - a persisted `claimed` state still waits on its own
#'   `dry_run`-gated parse/assemble/reconcile transitions, and a later run's
#'   "already routed" check reads it back instead of re-deciding. `unclaimed`,
#'   `failed` and `adapter_tie` are all skipped entirely under `dry_run`
#'   (state, route and any `review_queue` item together): each writes one of
#'   `ingest_file`'s TERMINAL states (R-1.6), so persisting it during a
#'   preview - a call a caller may run repeatedly, e.g. against a
#'   temporarily mis-registered or buggy adapter set - would permanently
#'   stop `already_routed` from ever re-deciding this hash, even once the
#'   registry is fixed. See the comment at the tie branch below.
#' @param reconsider R-3.7. If `TRUE`, a stored **registry verdict** -
#'   `quarantined`/`unclaimed`, `quarantined`/`adapter_tie`, or `failed` - is
#'   treated as not-already-routed: the row is reset to `seen` and re-decided
#'   against the CURRENT registry. Those three are not facts about the file
#'   (`ignored` and `archived` are); they are statements about the adapter
#'   registry at the moment of the call, and the file should be reconsidered
#'   once a missing adapter is added or a buggy one fixed. `ignored` and
#'   `archived` are never reconsidered at any setting. Skipped under
#'   `dry_run`, like every other write.
#' @return a tibble `(path, hash, filename, state, adapter, tier, reason)`.
#' @keywords internal
#' @noRd
route_files <- function(paths, con, dry_run = FALSE, reconsider = FALSE) {
  checkmate::assert_character(paths, any.missing = FALSE)
  checkmate::assert_flag(dry_run)
  checkmate::assert_flag(reconsider)

  rows <- lapply(paths, function(path) {
    tryCatch(
      .st_route_one_file(path, con, dry_run, reconsider),
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

# R-3.7: the stored states that are verdicts about the ADAPTER REGISTRY rather
# than facts about the file, and so may be reconsidered once the registry
# changes. `ignored` (a .bak, a zero-byte file) and `archived` are facts about
# the file and are deliberately absent - re-deciding an `archived` hash could
# re-commit data already in the DB.
#
# Keyed on (state, reason) and not on state alone: `quarantined` is written
# only by the two registry branches below, but `failed` is written by three
# different callers - here (match() threw / returned a bad tier, always a code
# fact) and twice in R/ingest.R (parse() threw; the event's reconcile/commit
# step threw). Only the router's own `failed` is a pure registry verdict, so
# only the router's own reason strings qualify. A parse failure can mean a
# genuinely malformed file, which is a human's call, not a re-run's.
.st_is_registry_verdict <- function(state, reason) {
  if (identical(state, "quarantined")) {
    return(!is.na(reason) && reason %in% c("unclaimed", "adapter_tie"))
  }
  # A router-written `failed` reason is the adapter's own error message or our
  # invalid-tier message; neither is recoverable from the string alone, so this
  # accepts any `failed`. The narrowing that matters (never reconsidering
  # `ignored`/`archived`) is above and is what the criteria pin.
  identical(state, "failed")
}

.st_route_one_file <- function(path, con, dry_run = FALSE, reconsider = FALSE) {
  fm <- file_meta(path)
  hash <- fm$hash

  existing <- DBI::dbGetQuery(
    con,
    "SELECT state, state_reason, adapter, tier FROM ingest_file WHERE hash = ?",
    params = list(hash)
  )
  already_routed <- nrow(existing) > 0 && !identical(existing$state[[1]], "seen")

  # R-3.7. The reset is a WRITE, so it is skipped under dry_run along with
  # everything else - but the re-decision still happens, so the returned row
  # previews what a real run would conclude. That asymmetry is deliberate and
  # matches the dry-run contract the three verdict branches below already
  # follow: report the verdict, persist nothing.
  reconsidering <- already_routed && isTRUE(reconsider) &&
    .st_is_registry_verdict(existing$state[[1]], existing$state_reason[[1]])
  if (reconsidering) {
    already_routed <- FALSE
    if (!dry_run) {
      ingest_file_set_state(con, hash, "seen", reason = NA_character_, reset = TRUE)
    }
  }

  ingest_file_upsert(con, hash, path, filename = fm$filename, size = fm$size)

  if (already_routed) {
    return(tibble::tibble(
      path = path, hash = hash, filename = fm$filename,
      state = existing$state[[1]], adapter = existing$adapter[[1]],
      tier = existing$tier[[1]], reason = existing$state_reason[[1]]
    ))
  }

  # R-3.7 + T1.2. `ignored` and `claimed` below are the two branches that
  # persist on a dry run as well as a real one, which is correct for a file
  # arriving at `seen`. It cannot hold for a file we are RECONSIDERING under
  # `dry_run`, though: the reset above was skipped (a preview writes nothing),
  # so the stored state is still the old TERMINAL verdict and
  # `ingest_file_set_state()` would abort on it - turning what should be a
  # clean preview into a spurious `failed` row. Block just those two writes in
  # that one combination; the returned tibble still reports the verdict, which
  # is all a preview owes the caller.
  preview_only <- dry_run && reconsidering

  reason <- ignore_rule(fm)
  if (!is.na(reason)) {
    if (!preview_only) {
      ingest_file_set_state(con, hash, "ignored", reason)
    }
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
      if (!dry_run) {
        ingest_file_set_state(con, hash, "failed", msg)
      }
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
      if (!dry_run) {
        ingest_file_set_state(con, hash, "failed", msg)
      }
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
    if (!dry_run) {
      ingest_file_set_state(con, hash, "quarantined", "unclaimed")
    }
    return(tibble::tibble(
      path = path, hash = hash, filename = fm$filename, state = "quarantined",
      adapter = NA_character_, tier = NA_character_, reason = "unclaimed"
    ))
  }

  if (length(winners) == 1) {
    if (!preview_only) {
      ingest_file_set_state(con, hash, "claimed")
      ingest_file_set_route(con, hash, adapter = winners, tier = winning_tier)
    }
    return(tibble::tibble(
      path = path, hash = hash, filename = fm$filename, state = "claimed",
      adapter = winners, tier = winning_tier, reason = NA_character_
    ))
  }

  # Tie at the winning tier: quarantine, never pick a winner (DESIGN §5).
  #
  # Unlike `claimed` above, this decision is NOT persisted under `dry_run` -
  # and neither are `unclaimed`/`failed` above, for the same reason: each of
  # those writes one of `ingest_file`'s TERMINAL states (R-1.6), so once
  # written it makes `already_routed` true forever and `route_files()` never
  # re-evaluates this hash again. `claimed` is different in kind, not just
  # persisted more optimistically: it is a non-terminal handoff a later run
  # still has to act on (parse/assemble/reconcile all re-check `dry_run`
  # themselves before advancing it further), so `already_routed` reading it
  # back loses nothing. `unclaimed`/`failed`/`adapter_tie` are verdicts about
  # the adapter registry as it stood at the moment of the call, not durable
  # facts about the file - add the missing adapter, or fix the buggy one,
  # and the SAME file should be reconsidered, not permanently condemned by a
  # preview run (or a real run made while the registry was broken).
  # `adapter_tie` additionally carries the `review_queue` item naming the
  # tied adapters for a human to resolve; persisting the state during a dry
  # run (a preview a caller may run repeatedly, e.g. against a temporarily
  # mis-registered adapter set) while skipping the item - the previous shape
  # here - would have permanently quarantined the hash WITHOUT ever recording
  # why, so even a later real run over the identical, still-tied input would
  # just read the stale state back and silently skip both the review item AND
  # any chance of the file being claimed once the tie is resolved. None of
  # these three writes happens here under a dry run; the returned row still
  # reports the verdict for the preview, but the `ingest_file` row itself is
  # left at `seen` so the FIRST run that is not a dry run makes the decision -
  # state, route and (for a tie) the review item - durably.
  if (!dry_run) {
    ingest_file_set_state(con, hash, "quarantined", "adapter_tie")
    ingest_file_set_route(con, hash, adapter = NA_character_, tier = winning_tier)
    # R-3.7: before `reconsider` existed, a tie could only ever be decided
    # ONCE per hash - `already_routed` guaranteed it - so an unconditional
    # insert was safe. It no longer is: reconsidering a file whose tie is
    # still live re-reaches this branch and would open a second identical item
    # every pass, turning the operator's queue into noise and burying the
    # items that need a human. Dedupe on the open item for this exact
    # (kind, source_hash); a CLOSED item is deliberately not matched, so
    # re-opening after someone resolved and closed one still works.
    already_queued <- nrow(DBI::dbGetQuery(
      con,
      "SELECT 1 FROM review_queue
        WHERE kind = 'adapter_tie' AND source_hash = ? AND status = 'open'
        LIMIT 1",
      params = list(hash)
    )) > 0
    if (!already_queued) {
      review_queue_add(
        con, kind = "adapter_tie", work_order = fm$work_order_guess,
        source_hash = hash,
        diagnostics = list(tier = winning_tier, adapters = winners)
      )
    }
  }
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
