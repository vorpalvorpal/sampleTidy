# Plan 09 - R/ingest.R: `ingest_dir()` (R-9.5), the top-level pipeline
# orchestrator, and the `remove_ingested` switch (R-9.6, A13).
#
# Wires together already-implemented, already-green modules: route_files()
# (router.R), adapter parse() (adapter-*.R), assemble_events() (assemble.R),
# reconcile_event() (reconcile.R), commit_event() (commit.R), snapshot_db()
# (snapshot.R). This file makes NO raw table-write calls (A32/A40): every
# `ingest_file` state change goes through db-schema.R's
# ingest_file_set_state(), and every core-table write happens inside
# commit_event() (which itself uses the mutation layer). This file's own
# direct DB access is limited to read-only DBI::dbGetQuery() SELECTs (the
# remove-switch's asset lookups).

# ---- small shared helpers ---------------------------------------------------

#' NA-safe "is this event file row kept" test (mirrors commit.R's
#' `.ct_kept_rows()` - duplicated locally rather than reused across files
#' since `kept` is always a clean logical here, but kept NA-safe for
#' consistency).
#' @keywords internal
#' @noRd
.ig_kept_rows <- function(files) {
  kept <- files$kept
  !is.na(kept) & kept
}

# ---- parse stage --------------------------------------------------------

#' Parse every `claimed` row of a routed batch (R-9.5 step c)
#'
#' For each row in state `claimed`, looks up its adapter, builds
#' `file_meta()`, and calls the adapter's `parse()`. A thrown
#' `sampletidy_parse_error` (or any other error) is caught: the file is
#' marked `failed` with the error message as `state_reason` and parsing
#' continues with the remaining files (A27) - a parse crash never aborts
#' `ingest_dir()`. A successful parse is marked `parsed` and added to the
#' returned list.
#'
#' @param con an open read-write DBI connection.
#' @param routed the tibble returned by [route_files()].
#' @return `list(<hash> = list(ir = list(results, samples), report, meta))`,
#'   one entry per successfully parsed file.
#' @keywords internal
#' @noRd
.ig_parse_claimed <- function(con, routed) {
  parsed <- list()

  claimed_idx <- which(routed$state == "claimed")

  # Content-hash dedup (A20/A46): two paths in ONE run can carry identical
  # bytes - `ignore_rule()` deliberately passes `[N]` duplicate-download
  # markers through so that hash dedup, not filename guesswork, handles
  # them. `route_files()` re-decides nothing for a hash it has already
  # routed: it records a sighting and returns the *stored* `claimed` state,
  # so both rows arrive here. Parsing per-row would parse the same content
  # twice and drive an illegal `parsed -> parsed` transition, aborting the
  # whole run. Parse once per distinct hash.
  claimed_idx <- claimed_idx[!duplicated(routed$hash[claimed_idx])]

  for (i in claimed_idx) {
    hash <- routed$hash[[i]]
    path <- routed$path[[i]]
    adapter_id <- routed$adapter[[i]]

    fm <- file_meta(path)

    # Belt-and-braces (R-12.1/F6): a stray/invalid `adapter_id` here (e.g.
    # from a routed row that predates the router's match()-validation fix,
    # or any other unexpected state) must fail only this file, not abort
    # the whole run - so the registry lookup lives INSIDE the tryCatch.
    out <- tryCatch(
      {
        ad <- adapter_registry()[[adapter_id]]
        if (is.null(ad)) {
          stop(sprintf("no registered adapter with id '%s'", adapter_id))
        }
        ad$parse(path, fm)
      },
      error = function(e) e
    )

    if (inherits(out, "error")) {
      ingest_file_set_state(con, hash, "failed", conditionMessage(out))
      next
    }

    ingest_file_set_state(con, hash, "parsed")
    parsed[[hash]] <- list(
      ir = list(results = out$results, samples = out$samples),
      report = out$report,
      meta = fm
    )
  }

  parsed
}

# ---- assemble-state application -----------------------------------------

#' Apply every `assemble_events()` state-transition row (R-9.5 step d)
#' @keywords internal
#' @noRd
.ig_apply_assemble_states <- function(con, states) {
  if (nrow(states) == 0) {
    return(invisible(NULL))
  }
  for (i in seq_len(nrow(states))) {
    ingest_file_set_state(con, states$hash[[i]], states$state[[i]], reason = states$reason[[i]])
  }
  invisible(NULL)
}

# ---- reconcile + commit stage --------------------------------------------

#' Reconcile and (unless `dry_run`) commit every assembled event
#' (R-9.5 step e)
#'
#' For each event: reconciles (read-only) via [reconcile_event()], moves the
#' event's kept files from `assembled` to `reconciled` (guarded - only a
#' file currently in state `assembled` is transitioned), then commits via
#' [commit_event()] unless `dry_run` (in which case reconciliation still
#' happens but nothing is committed).
#'
#' @return a list with `committed_any` (logical), `n_events`, `n_committed`,
#'   `events_failed`, and `tally` (named list of row/review counts summed
#'   across events).
#' @keywords internal
#' @noRd
.ig_reconcile_and_commit <- function(con, events, dry_run) {
  committed_any <- FALSE
  n_committed <- 0L
  events_failed <- 0L
  tally <- list(new = 0L, superseded = 0L, already_present = 0L, skipped = 0L, review_opened = 0L)

  for (event in events) {
    kept_hashes <- event$files$hash[.ig_kept_rows(event$files)]

    # R-12.2/A60: contain a per-event reconcile/commit failure so it never
    # kills every later event (was: both calls ran bare in this loop). The
    # event's kept files are marked `failed` with the error message and a
    # `cli_warn` names it; the loop then continues to the next event. If
    # EVERY event in the run fails (a systemic wipe-out, e.g. schema/disk/
    # DB), that is surfaced loudly AFTER the loop finishes (see below) - not
    # swallowed into a quiet all-`failed` report and not a bare abort on the
    # first throw (committed events keep their own transactions, so a
    # re-run cleanly no-ops on them and re-attempts only the failed one).
    step <- tryCatch(
      {
        resolved <- reconcile_event(event, con)

        for (h in kept_hashes) {
          row <- DBI::dbGetQuery(con, "SELECT state FROM ingest_file WHERE hash = ?", params = list(h))
          if (nrow(row) > 0 && identical(row$state[[1]], "assembled")) {
            ingest_file_set_state(con, h, "reconciled")
          }
        }

        if (!dry_run) {
          commit_event(event, resolved, con)
        }

        list(resolved = resolved)
      },
      error = function(e) e
    )

    if (inherits(step, "error")) {
      events_failed <- events_failed + 1L
      msg <- conditionMessage(step)
      for (h in kept_hashes) {
        ingest_file_set_state(con, h, "failed", msg)
      }
      cli::cli_warn(
        "ingest_dir(): event containing {.val {kept_hashes}} failed during
         reconcile/commit and was skipped: {msg}"
      )
      next
    }

    resolved <- step$resolved

    clean <- resolved$clean
    if (nrow(clean) > 0 && "supersedes" %in% names(clean)) {
      tally$new <- tally$new + sum(is.na(clean$supersedes))
      tally$superseded <- tally$superseded + sum(!is.na(clean$supersedes))
    } else {
      tally$new <- tally$new + nrow(clean)
    }

    skipped <- resolved$skipped
    if (nrow(skipped) > 0 && "reason" %in% names(skipped)) {
      tally$already_present <- tally$already_present + sum(skipped$reason == "already_present")
    }
    tally$skipped <- tally$skipped + nrow(skipped)
    tally$review_opened <- tally$review_opened + nrow(resolved$review)

    if (!dry_run) {
      committed_any <- TRUE
      n_committed <- n_committed + 1L
    }
  }

  # A total wipe-out (every event in the run failed) is systemic, not a
  # per-event fluke - surface it loudly AFTER the loop has contained every
  # event (not on the first throw), rather than returning a quiet
  # all-`failed` report.
  if (length(events) > 0 && events_failed == length(events)) {
    cli::cli_abort(
      "ingest_dir(): every event in this run failed during reconcile/commit
       ({events_failed} of {length(events)}); aborting - this looks systemic
       (e.g. schema/disk/DB), not a per-event fluke. Each event's kept files
       have been marked failed; a re-run will re-attempt them.",
      class = "sampletidy_error"
    )
  }

  list(
    committed_any = committed_any, n_events = length(events), n_committed = n_committed,
    events_failed = events_failed, tally = tally
  )
}

# ---- remove switch (R-9.6, A13) ------------------------------------------

#' Delete input files whose content hash has a *verified* archive copy
#' (R-9.6, A13)
#'
#' Opens a fresh read-only connection (the pipeline's read-write connection
#' must already be closed - DuckDB is single-writer, but a read-only
#' connection can coexist). For each routed input path/hash: if an `asset`
#' row exists for that hash AND its archive copy exists on disk AND the
#' source file still exists, the source is deleted. If an `asset` row
#' exists but the archive copy is missing, the source is kept and a warning
#' is emitted - files are never deleted without a verified copy. Files with
#' no `asset` row (cruft, failed, quarantined) are left untouched.
#'
#' @param db path to the DuckDB file.
#' @param routed the tibble returned by [route_files()].
#' @return character vector of removed paths.
#' @keywords internal
#' @noRd
.ig_remove_verified <- function(db, routed) {
  con <- st_connect(db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  archive_dir <- st_config("archive_dir")
  removed <- character(0)

  for (i in seq_len(nrow(routed))) {
    path <- routed$path[[i]]
    hash <- routed$hash[[i]]
    if (is.na(hash) || !file.exists(path)) {
      next
    }

    asset_row <- DBI::dbGetQuery(con, "SELECT uuid, filename FROM asset WHERE hash = ?", params = list(hash))
    if (nrow(asset_row) == 0) {
      next
    }

    fn <- asset_row$filename[[1]]
    copy_path <- if (is.na(fn)) NA_character_ else file.path(archive_dir, asset_row$uuid[[1]], fn)
    # file_test("-f", ...) requires a REGULAR FILE - file.exists() is TRUE for the
    # uuid directory even when the archived bytes are gone (the A13/R-9.6 data-loss
    # bug this guard exists to prevent).
    if (is.na(copy_path) || !utils::file_test("-f", copy_path)) {
      cli::cli_warn(
        "ingest_dir(): archive copy for {.path {path}} (hash {.val {hash}}) is
         missing at {.path {copy_path}}; keeping the source file (never
         deleting without a verified copy)."
      )
      next
    }

    file.remove(path)
    removed <- c(removed, path)
  }

  removed
}

# ---- report assembly -----------------------------------------------------

#' Look up the CURRENT (terminal, post reconcile/commit) `ingest_file.state`
#' for a set of routed hashes (R-12.7/F13)
#'
#' `routed$state` only reflects the state at *route time* (`claimed`,
#' `ignored`, `quarantined`, ...) - by the time the report is built, a
#' `claimed` file may since have been parsed/assembled/reconciled/committed
#' (or failed/needs_review). Re-querying the live table, one row per input
#' `hashes` entry (preserving duplicates/order so a `table()` over the
#' result matches the previous `table(routed$state)` shape), gives the
#' report the run's real terminal states instead.
#' @keywords internal
#' @noRd
.ig_current_states <- function(con, hashes) {
  if (length(hashes) == 0) {
    return(character(0))
  }
  live <- DBI::dbGetQuery(con, "SELECT hash, state FROM ingest_file")
  live$state[match(hashes, live$hash)]
}

#' Build the `ingest_report` returned to the caller (R-9.5 step 6)
#' @keywords internal
#' @noRd
.ig_build_report <- function(pipeline, dry_run, snapshot_path, removed) {
  routed <- pipeline$routed
  states <- pipeline$file_states
  files_by_state <- if (length(states) > 0) as.list(table(states)) else list()

  list(
    dry_run = dry_run,
    n_files_routed = nrow(routed),
    files_by_state = files_by_state,
    n_events = pipeline$outcome$n_events,
    n_events_committed = pipeline$outcome$n_committed,
    events_failed = as.integer(pipeline$outcome$events_failed),
    rows_new = as.integer(pipeline$outcome$tally$new),
    rows_already_present = as.integer(pipeline$outcome$tally$already_present),
    rows_superseded = as.integer(pipeline$outcome$tally$superseded),
    rows_skipped = as.integer(pipeline$outcome$tally$skipped),
    review_items_opened = as.integer(pipeline$outcome$tally$review_opened),
    snapshot_path = snapshot_path,
    removed_files = removed
  )
}

# ---- top-level entry point -----------------------------------------------

#' Ingest every file in a flat directory into the sampleTidy database
#'
#' The top-level pipeline (DESIGN Sec1): route -> parse -> assemble ->
#' reconcile -> commit, run once over every file directly inside `path`.
#' Listing is non-recursive (A8) - subdirectories and their contents are
#' never touched. Adapters self-register defensively at the start of every
#' call (A33), so a prior `clear_adapters()` can never leave the pipeline
#' with no adapters.
#'
#' The whole route/parse/assemble/reconcile/commit sequence runs inside one
#' [with_db_write()] call, using a single read-write connection; that
#' connection is closed (by `with_db_write()`, on return) before
#' [snapshot_db()] is called - DuckDB is single-writer, so overlapping the
#' pipeline connection with `snapshot_db()`'s own `with_db_write()` would
#' lock-wait and fail.
#'
#' `dry_run = TRUE` still routes, parses, assembles and reconciles (so the
#' returned report reflects what the run *would* do), but skips
#' `commit_event()` and the snapshot entirely - the only two core-table/
#' snapshot writers - so a dry run makes zero core-table writes and
#' produces no snapshot file.
#'
#' When `st_config("remove_ingested")` is `TRUE` (default `FALSE`, A13) and
#' this run produced a successful snapshot, every input file whose content
#' hash has a *verified* archive copy (an `asset` row whose archive file
#' actually exists on disk) is deleted from `path`. Cruft/ignored files with
#' no archive copy, `failed`/`quarantined` files, and any file whose archive
#' copy is missing are never deleted. A snapshot failure propagates as an
#' error (it is not swallowed) and nothing is removed.
#'
#' @param path directory to ingest (non-recursive, A8).
#' @param db path to the DuckDB file to ingest into.
#' @param dry_run if `TRUE`, reconcile but do not commit, snapshot, or
#'   remove anything.
#' @return an `ingest_report` (a named list) summarising the run: file
#'   counts by terminal state, events processed/committed, row tallies
#'   (new/already_present/superseded/skipped), review items opened, the
#'   snapshot path (or `NA`), and any removed files.
#' @export
ingest_dir <- function(path, db = st_config("live_db"), dry_run = FALSE) {
  checkmate::assert_string(path)
  checkmate::assert_string(db)
  checkmate::assert_flag(dry_run)

  register_builtin_adapters()

  paths <- as.character(fs::dir_ls(path, type = "file", all = TRUE, recurse = FALSE))

  pipeline <- with_db_write(
    function(con) {
      ensure_schema(con)

      routed <- route_files(paths, con)

      parsed <- .ig_parse_claimed(con, routed)

      events <- list()
      if (length(parsed) > 0) {
        asm <- assemble_events(parsed)
        .ig_apply_assemble_states(con, asm$states)
        events <- asm$events
      }

      outcome <- .ig_reconcile_and_commit(con, events, dry_run)

      # Capture the live terminal states now, while `con` is still open -
      # `with_db_write()` closes it on return (R-12.7/F13; see
      # `.ig_current_states()`).
      file_states <- .ig_current_states(con, routed$hash)

      list(routed = routed, events = events, outcome = outcome, file_states = file_states)
    },
    db = db
  )

  # Snapshot AFTER the pipeline connection has closed (DuckDB is
  # single-writer) - and let a snapshot error propagate uncaught.
  snapshot_path <- NA_character_
  if (isTRUE(pipeline$outcome$committed_any) && !dry_run) {
    snapshot_path <- snapshot_db(db = db, dest_dir = st_config("snapshot_dir"))
  }

  removed <- character(0)
  snapshot_happened <- !is.na(snapshot_path)
  if (isTRUE(as.logical(st_config("remove_ingested"))) && !dry_run && snapshot_happened) {
    removed <- .ig_remove_verified(db, pipeline$routed)
  }

  report <- .ig_build_report(pipeline, dry_run, snapshot_path, removed)

  cli::cli_inform(
    "ingest_dir({.path {path}}): {report$n_files_routed} file(s) routed,
     {report$n_events} event(s) ({report$n_events_committed} committed),
     {report$review_items_opened} review item(s) opened,
     {length(report$removed_files)} file(s) removed."
  )

  report
}
