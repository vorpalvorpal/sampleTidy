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
#' @param dry_run T1.2 (Robin's ruling): a dry run makes NO `ingest_file`
#'   state transitions at all, not just no core-table writes. Parsing itself
#'   still runs (so a dry-run preview can be built), but the `parsed`/
#'   `failed` transition below is skipped - the file stays at whatever state
#'   [route_files()] left it in (`claimed`), so the NEXT run (dry or real)
#'   parses it again instead of `.ig_parse_claimed()`'s own `claimed`-only
#'   filter silently skipping it forever (the T1.2 defect).
#' @return `list(<hash> = list(ir = list(results, samples), report, meta))`,
#'   one entry per successfully parsed file.
#' @keywords internal
#' @noRd
.ig_parse_claimed <- function(con, routed, dry_run = FALSE) {
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
      if (!dry_run) {
        ingest_file_set_state(con, hash, "failed", conditionMessage(out))
      }
      next
    }

    if (!dry_run) {
      ingest_file_set_state(con, hash, "parsed")
    }
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
#' @param dry_run T1.2 (Robin's ruling): skip every `ingest_file` write - a
#'   dry run leaves no state trace for a later run to trip over.
#' @keywords internal
#' @noRd
.ig_apply_assemble_states <- function(con, states, dry_run = FALSE) {
  if (nrow(states) == 0 || dry_run) {
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
#' For each event: reconciles (read-only) via [reconcile_event()], then
#' either commits via [commit_event()] (real run) or, under `dry_run`,
#' previews the F.10 guard verdict read-only via
#' [.ct_reingest_guard_preview()] (T1.2 item 7) - so the report's
#' `rows_new`/`review_items_opened` tell the truth about what a following
#' real run would do, instead of assuming reconcile's proposed `clean` rows
#' would all commit.
#'
#' T1.2 (Robin's ruling): a dry run makes ZERO `ingest_file` state
#' transitions, full stop - not just no core-table writes. Before this fix,
#' the event's kept files were moved `assembled -> reconciled`
#' UNCONDITIONALLY (even under `dry_run`), which permanently poisoned the
#' input directory: a following REAL run found those files already past
#' `claimed` and silently ingested nothing (reproduced, probe P7,
#' `dev/tdd-run/probes/p7-r3-commit-probes.R`). The `reconciled` transition
#' (and the error-path `failed` transition below) are now both skipped
#' entirely when `dry_run`.
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

        if (!dry_run) {
          for (h in kept_hashes) {
            row <- DBI::dbGetQuery(con, "SELECT state FROM ingest_file WHERE hash = ?", params = list(h))
            if (nrow(row) > 0 && identical(row$state[[1]], "assembled")) {
              ingest_file_set_state(con, h, "reconciled")
            }
          }
        }

        commit_result <- NULL
        if (!dry_run) {
          commit_result <- commit_event(event, resolved, con)
        } else {
          # T1.2 item 7: preview the F.10 verdict read-only (never writes),
          # mirroring commit_event()'s own guard/find-or-create logic exactly
          # (R/commit.R's .ct_reingest_guard_preview()) - so a dry run's
          # report is not silently derived from resolved$clean/review (what
          # reconcile WOULD have committed), which lies for a guard-blocked
          # event (reproduced, probe P6: dry run reported rows_new = 1 where
          # a real run over the identical fixture reports rows_new = 0).
          preview <- .ct_reingest_guard_preview(con, event, resolved)
          commit_result <- if (isTRUE(preview$blocked)) {
            list(blocked = TRUE, n_review = preview$n_review)
          } else {
            NULL
          }
        }

        list(resolved = resolved, commit_result = commit_result)
      },
      error = function(e) e
    )

    if (inherits(step, "error")) {
      events_failed <- events_failed + 1L
      msg <- conditionMessage(step)
      if (!dry_run) {
        for (h in kept_hashes) {
          ingest_file_set_state(con, h, "failed", msg)
        }
      }
      cli::cli_warn(
        "ingest_dir(): event containing {.val {kept_hashes}} failed during
         reconcile/commit and was skipped: {msg}"
      )
      next
    }

    resolved <- step$resolved
    # Phase-7b item 2: commit_event() now returns a guard verdict
    # (list(blocked = ..., ...)) distinguishing a PLAN-15 F.10 guard-blocked
    # call (no sample/analysis row written; resolved$clean was never
    # committed) from a real commit. Before this, both branches returned
    # invisible(NULL), so a blocked event's tally was derived from
    # resolved$clean - what reconcile WOULD have committed, not what
    # commit_event() actually wrote - and committed_any/n_committed were set
    # unconditionally. T1.2 item 7: under dry_run, `commit_result` now comes
    # from the read-only preview above (not NULL), so the SAME `isTRUE(...)`
    # test applies uniformly to both real and previewed verdicts.
    blocked <- isTRUE(step$commit_result$blocked)

    skipped <- resolved$skipped
    if (nrow(skipped) > 0 && "reason" %in% names(skipped)) {
      tally$already_present <- tally$already_present + sum(skipped$reason == "already_present")
    }
    tally$skipped <- tally$skipped + nrow(skipped)

    if (blocked) {
      # resolved$clean was never committed - it contributes zero rows. The
      # review items ACTUALLY written are commit_event()'s own count
      # (resolved$review plus the guard's own blocking row), not
      # nrow(resolved$review) alone.
      tally$review_opened <- tally$review_opened + step$commit_result$n_review
    } else {
      clean <- resolved$clean
      if (nrow(clean) > 0 && "supersedes" %in% names(clean)) {
        tally$new <- tally$new + sum(is.na(clean$supersedes))
        tally$superseded <- tally$superseded + sum(!is.na(clean$supersedes))
      } else {
        tally$new <- tally$new + nrow(clean)
      }
      tally$review_opened <- tally$review_opened + nrow(resolved$review)
    }

    if (!dry_run) {
      # committed_any still reflects "this run made writes worth snapshotting"
      # - a blocked event still writes review_queue/asset/ingest_file rows -
      # but n_committed (a distinct, event-tally figure) counts only events
      # that actually committed clean rows.
      committed_any <- TRUE
      if (!blocked) {
        n_committed <- n_committed + 1L
      }
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

# ---- retain non-tabular deliverables (R-15.36, B-15.F17) -----------------

#' Retain a work order's non-tabular deliverables (COA/COC/QC/QCI PDFs,
#' `XTAB.XLS`, ...) that no adapter claims (R-15.36, B-15.F17)
#'
#' No adapter parses a PDF or a real (SpreadsheetML) `XTAB.XLS` (F.17), so
#' `route_files()` quarantines every such sibling with reason `unclaimed` and
#' gives it no `asset` row - harmless while `remove_ingested` defaulted
#' `FALSE` (nothing was ever deleted), now load-bearing because it defaults
#' `TRUE` (A13): the source would otherwise sit in the input directory
#' forever with no archived copy and no link back to its work order, which
#' is exactly the setup for a later manual "clean up the leftovers" sweep
#' that deletes the only copy of a certificate of analysis.
#'
#' For every routed row still `quarantined`/`unclaimed` (deduped by hash),
#' guesses the file's work order from its filename ([file_meta()]'s
#' `work_order_guess` - NEVER inferred from a bare `2400-*` filename, which
#' cannot be parsed reliably; only `ES#######`-shaped tokens are used, per
#' `file_meta()`). A file whose work order cannot be guessed, or whose work
#' order has no `project` row, is left alone - retaining a file with nothing
#' to hang it off would satisfy "the bytes are kept" while failing "the file
#' is discoverably attached to its work order" (B-15.F17's second,
#' easy-to-miss obligation).
#'
#' The `project` lookup is **not** run-scoped, and this comment used to say it
#' was ("no event for that work order committed in THIS run"), which was never
#' what the SQL did. `project` is a persistent table (559 rows in the live DB),
#' so a COA arriving in its own email a day after the data attaches to the work
#' order the earlier run committed - Robin ruled on 2026-07-28 that it must
#' (R-15.36a, PLAN-09 R-9.10). Equally binding is the other half of that
#' ruling: this stays **find-only** and must never become
#' `.ct_ensure_project()`'s find-or-create. A work order we have never seen
#' data for is a guess, and attaching evidence to a guess is worse than the
#' warning we emit instead.
#'
#' Otherwise the file is archived via [archive_file()] (reused as-is: it
#' already resolves the event's project from `event$work_order`, dedupes on
#' content hash, and writes the `asset` row through the mutation layer) and
#' its `ingest_file` row is force-transitioned (`reset = TRUE`, since
#' `quarantined` is otherwise terminal) to `archived` - the same terminal
#' state a tabular asset's source file reaches after commit, so
#' `.ig_remove_verified()` picks it up unmodified and the run's
#' `files_by_state` report no longer shows it as `quarantined`.
#'
#' Round-2 audit item 6: is `filename` a COA (Certificate of Analysis) PDF,
#' the one retained kind PLAN-15 F.17 + Robin's ruling name an explicit
#' `asset.type` for? Real-corpus shape "<work order>_<revision>_COA.<ext>"
#' (e.g. "ES2617126_0_COA.pdf"): a literal `_COA.` token, case-insensitive,
#' immediately before the extension, with an OPTIONAL `[N]` duplicate-
#' download marker (round-3 item 9) - `ignore_rule()` (R/router.R)
#' DELIBERATELY passes a `[N]` browser-redownload twin through rather than
#' filtering it, so hash dedup (not filename guesswork) handles the ordinary
#' case where both copies are present; but when the `[1]` copy is the ONLY
#' copy on disk (the original was moved/deleted between downloads), it must
#' still be recognised as a COA, not silently typed `"Chemical analysis"`
#' (reproduced: `ES2617126_0_COA[1].pdf` was typed `"Chemical analysis"`
#' pre-fix). Otherwise deliberately narrow - `.ig_retain_
#' siblings()` also retains COC/QC/QCI PDFs and `XTAB.XLS`, none of which are
#' COAs; widening `"Certificate of analysis"` to cover them needs a separate
#' ruling (see the round-2 report's enumerated list), not a guess here.
#' @keywords internal
#' @noRd
.ig_is_coa_deliverable <- function(filename) {
  grepl("(?i)_coa(\\[[0-9]+\\])?\\.[a-z0-9]+$", filename, perl = TRUE)
}

# R-15.36b (Robin, 2026-07-28): the separate ruling the note above asks for.
#
# Mapped onto the vocabulary the live `asset` table ALREADY uses - 938
# "Chemical analysis", 272 "QA", 222 "QC" - rather than onto new strings,
# because the point of `type` is that Robin's existing queries keep working.
# Order matters: the first matching token wins, and `_QCI` must be tested
# before `_QC` would otherwise swallow it. ("Certificate of analysis" is the
# one value not already in the live vocabulary; it was ruled separately on
# 2026-07-23 and is left as it stands.)
#
# ONE table, not four scattered branches, so re-ruling any row is a one-line
# edit rather than a hunt.
.ST_RETAINED_ASSET_TYPES <- list(
  list(pattern = "(?i)_coa(\\[[0-9]+\\])?\\.[a-z0-9]+$", type = "Certificate of analysis"),
  list(pattern = "(?i)_qci(\\[[0-9]+\\])?\\.[a-z0-9]+$", type = "QC"),
  list(pattern = "(?i)_qc(\\[[0-9]+\\])?\\.[a-z0-9]+$",  type = "QC"),
  # A chain of custody is a QA record - who took the sample, when, and who
  # handled it - not a result.
  list(pattern = "(?i)_coc(\\[[0-9]+\\])?\\.[a-z0-9]+$", type = "QA"),
  # XTAB.XLS genuinely IS results: an ALS crosstab rendering of the same
  # chemistry its `.csv` twin carries, which we merely cannot read yet
  # (SpreadsheetML, parked post-MVP - R/adapter-crosstab.R).
  list(pattern = "(?i)_xtab(\\[[0-9]+\\])?\\.[a-z0-9]+$", type = "Chemical analysis")
)

#' `asset.type` for one retained non-tabular deliverable (R-15.36b)
#'
#' Falls back to `"Chemical analysis"` for anything the table does not name,
#' preserving the pre-ruling default for a kind nobody has ruled on. That
#' fallback is unreachable from `.ig_retain_siblings()` today, whose selection
#' gate admits only the five tokens above - but the gate and this table are
#' separate lists, and a widened gate must not silently start typing a new
#' kind by accident.
#' @keywords internal
#' @noRd
.ig_retained_asset_type <- function(filename) {
  for (entry in .ST_RETAINED_ASSET_TYPES) {
    if (grepl(entry$pattern, filename, perl = TRUE)) {
      return(entry$type)
    }
  }
  "Chemical analysis"
}

# R-9.8: does this filename carry an ACIRL-shaped work-order token?
#
# `2400-7538-02` and friends CANNOT be parsed from a filename (false merges AND
# false splits - see the ACIRL work-order trap in R/commit.R), and that refusal
# stays. A file carrying one is not merely "unidentifiable": it POSITIVELY
# DECLARES a work order of its own, one we decline to name, so this treats that
# as a reason to leave the file alone rather than adopt it onto a folder-mate's
# work order.
#
# PROVISIONAL, and say so plainly. This guard is INERT against the real corpus
# (the selection gate in .ig_retain_siblings() requires a
# _(coa|coc|qc|qci|xtab) token and zero of the 272 real ACIRL files carry one),
# so today it costs nothing and proves nothing. It becomes live only if that
# gate is widened to retain the 137 ACIRL PDFs - and at that moment it is an
# OPEN QUESTION whether it is still right, because Robin's 2026-07-28
# correction says an ACIRL email almost always carries the underlying ALS work
# order's files too, i.e. the ACIRL report and the ALS work order describe the
# same sampling event. Filing the report under that work order may be exactly
# what is wanted. Do not widen the gate without re-deciding this.
#
# Deliberately loose (`\d{4}-\d{4}` anywhere in the name): this gate decides
# whether to STAY OUT of a file's business, so over-matching costs one warning
# and a file left safely quarantined, while under-matching costs a wrong
# attachment in the database. Those are not symmetric.
.ig_is_acirl_shaped <- function(filename) {
  grepl("[0-9]{4}-[0-9]{4}", filename)
}

#' The work order a folder unambiguously belongs to, or `NA` (R-9.8)
#'
#' PowerAutomate drops one lab email's attachments into their own folder, so
#' folder membership is an association that needs no filename parsing: if the
#' *other* files here resolved to a work order, a token-less deliverable
#' belongs to it.
#'
#' Returns a work order only when the folder resolves to **exactly one** that
#' also has a `project` row. The exactly-one guard is load-bearing, not
#' defensive padding: the real `batch-2026-07-23` folder held **eight** work
#' orders, and any first-wins or majority-wins rule would have attached each
#' COA to an arbitrary one of them.
#'
#' Never creates a project row - candidates are filtered to work orders that
#' already have one, so an inferred target is by construction a work order we
#' have really seen data for (R-15.36a's ruling, applied here too).
#' @keywords internal
#' @noRd
.ig_folder_work_order <- function(con, routed, path) {
  folder <- dirname(path)
  same_folder <- which(!is.na(routed$path) & dirname(routed$path) == folder)
  if (length(same_folder) == 0) {
    return(NA_character_)
  }

  # Parse from the stored FILENAME, via the same helper file_meta() uses -
  # never a relaxed regex, so ACIRL work orders stay unparsed here exactly as
  # they are everywhere else.
  guesses <- vapply(
    routed$filename[same_folder],
    function(fn) .st_guess_work_order_revision(fn)$work_order_guess,
    character(1), USE.NAMES = FALSE
  )
  candidates <- unique(guesses[!is.na(guesses)])
  if (length(candidates) == 0) {
    return(NA_character_)
  }

  known <- candidates[vapply(candidates, function(wo) {
    nrow(DBI::dbGetQuery(
      con, "SELECT 1 FROM project WHERE name = ? LIMIT 1", params = list(wo)
    )) > 0
  }, logical(1))]

  if (length(known) == 1) known[[1]] else NA_character_
}

#' @param con an open read-write DBI connection (already past
#'   `.ig_reconcile_and_commit()`, so any committed event's `project` row
#'   exists).
#' @param routed the tibble returned by [route_files()].
#' @return character vector of retained hashes. `ingest_dir()` uses this to
#'   decide whether the run did anything worth snapshotting (R-9.10): a
#'   retain-only run is a run that wrote `asset` rows, so it earns a snapshot
#'   on the same reasoning a commit does - and without one,
#'   `.ig_remove_verified()` never runs and the source sits in the input
#'   directory forever.
#' @keywords internal
#' @noRd
.ig_retain_siblings <- function(con, routed) {
  retained <- character(0)

  # commit-5 (round-3): `state == "quarantined" & reason == "unclaimed"`
  # matches ANY file no adapter claims - `ignore_rule()` (R/router.R) only
  # diverts bak/tmp/ds_store/.DS_Store/zero-byte files, so an ordinary
  # README.md, a photo.jpg or a stray notes.docx in the input directory each
  # drew the loop's "looks like a non-tabular lab deliverable" warning below,
  # every run, forever (nothing removes an un-retainable file from the input
  # directory) - reproduced, probe P3b: 3 cruft files, 3 warnings on run 1,
  # 3 again on run 2. Gate the SELECTION itself on a positive deliverable
  # shape (the COA/COC/QC/QCI/XTAB.XLS kinds this function's own roxygen
  # enumerates), not merely on "unclaimed" - a genuine deliverable always
  # carries one of these tokens (verified against the real corpus: every one
  # of the 19 real quarantined files matches), so this narrows the loop to
  # files actually worth naming in a warning, silencing it for ordinary
  # cruft instead of retraining an operator to ignore the warning that
  # matters.
  idx <- which(routed$state == "quarantined" &
    !is.na(routed$reason) & routed$reason == "unclaimed" &
    grepl("(?i)_(coa|coc|qc|qci|xtab)\\b", routed$filename, perl = TRUE))
  if (length(idx) == 0) {
    return(retained)
  }

  # Same hash-dedup discipline as `.ig_parse_claimed()` (A20/A46): a
  # duplicate-download of the SAME bytes at a second path must not be
  # archived/transitioned twice.
  idx <- idx[!duplicated(routed$hash[idx])]

  for (i in idx) {
    path <- routed$path[[i]]
    hash <- routed$hash[[i]]
    if (is.na(hash) || !file.exists(path)) {
      next
    }

    # Round-2 item 5: contain a per-file failure here, mirroring
    # .ig_parse_claimed() (A27). archive_file() cli_abort()s on a
    # dir.create()/file.copy() failure (a dehydrated OneDrive placeholder, a
    # permission error, a rejected filename), and this loop previously had NO
    # tryCatch at all - reproduced: one unarchivable retained sibling threw
    # ingest_dir() out AFTER commits had already landed (6 samples committed,
    # 0 snapshots produced, no report, remove_ingested never run). Every
    # OTHER sibling stage in this file is contained per A27/R-12.1/R-12.2;
    # this later-added F.17 sweep was not.
    result <- tryCatch(
      {
        fm <- file_meta(path)
        work_order <- fm$work_order_guess

        # R-9.8: the filename is the primary source and always wins. Folder
        # inference is a FALLBACK for a name that carries no work order at
        # all - it must never override a name that does, or one work order's
        # certificate gets filed under another whenever a folder happens to
        # look tidier than the filename.
        if (is.na(work_order) && !.ig_is_acirl_shaped(fm$filename)) {
          work_order <- .ig_folder_work_order(con, routed, path)
        }

        if (is.na(work_order)) {
          # Round-2 item 7: refusing to filename-parse a `2400-*` ACIRL work
          # order is CORRECT (see the ACIRL work-order trap, R/commit.R) and
          # must stay - staying silent about the residual exposure is not.
          # Every such file's COA/COC/QC/QCI PDFs and XTAB.XLS stay
          # quarantined, unarchived, and in the input directory forever (the
          # realised-loss shape PLAN-CHANGE-REQUESTS records for 13 files),
          # with no report field naming them - `retained` is returned then
          # discarded by the caller. Name it loudly instead.
          #
          # R-9.8 does NOT close this gap for ACIRL. The reason is NOT the
          # one first written here ("an ACIRL email's folder contains ACIRL
          # files only") - Robin corrected that on 2026-07-28: an ACIRL email
          # almost always carries the underlying ALS work order's files too,
          # which matches this package's own ACIRL adapter header (the workbook
          # is field data PLUS copies of ALS lab results, i.e. the same
          # sampling event under two identifiers).
          #
          # The real reason is the SELECTION gate above: it requires a
          # _(coa|coc|qc|qci|xtab) token, and zero of the 272 real ACIRL files
          # carry one (they are named descriptively - "2400-7454-05 May 2025
          # Monthly Katoomba WMF.pdf"). Nothing ACIRL reaches this branch at
          # all. The 13 files PLAN-CHANGE-REQUESTS records as lost were ALS,
          # not ACIRL - every one carries an ES####### token.
          #
          # What R-9.8 does fix is the token-less name (a renamed attachment)
          # in an unambiguous folder. Retaining the 137 ACIRL PDFs is a
          # separate, still-open question - see PLAN-09 R-9.8.
          cli::cli_warn(
            "ingest_dir(): {.path {path}} looks like a non-tabular lab
             deliverable but its work order could not be recovered from its
             filename (no {.val ES#######}-shaped token) nor inferred from its
             folder - F.17 retention is skipped for it; it stays quarantined
             and unarchived."
          )
          NA_character_
        } else {
          project_row <- DBI::dbGetQuery(
            con, "SELECT uuid FROM project WHERE name = ?",
            params = list(work_order)
          )
          if (nrow(project_row) == 0) {
            NA_character_
          } else {
            # Round-2 item 6 asked for an appropriate asset.type rather than
            # the blanket "Chemical analysis" every other archived file gets -
            # a retained sibling is evidence, not chemistry data (PLAN-15
            # F.17) - and typed only the COA, parking the rest pending a
            # ruling. Robin ruled the remaining kinds on 2026-07-28
            # (R-15.36b), so all five now route through one pinned lookup.
            sibling_type <- .ig_retained_asset_type(basename(path))
            # commit-3 (round-3): `archive_file()` (writes the `asset` row)
            # and `ingest_file_set_state()` (the terminal transition) used to
            # run as two independent DB writes with no `db_transaction()`
            # around them. If the transition failed AFTER the archive write,
            # the `asset` row landed but the `ingest_file` row stayed
            # `quarantined` forever (the next run's `file.exists(path) ==
            # FALSE` `next`s before it can repair the state) - reproduced,
            # probe P3. Wrapping both writes in ONE `db_transaction()` makes
            # them land or roll back together (the byte COPY inside
            # `archive_file()` itself stays outside transaction scope, a
            # separate, deliberately-deferred issue - see the byte-copy note
            # in this file's header). This inner `db_transaction()` detects
            # the OUTER one already tagging `con` (this whole function runs
            # inside `with_db_write()`'s connection, not its own nested
            # transaction) and just runs inline, same as `.ct_ensure_project()`
            # (R/commit.R) already relies on for `add_project()`.
            db_transaction(con, function(con) {
              archive_file(con, path, hash, event = list(work_order = work_order),
                           type = sibling_type)
              ingest_file_set_state(con, hash, "archived", reason = "retained_sibling", reset = TRUE)
            })
            hash
          }
        }
      },
      error = function(e) {
        cli::cli_warn(
          "ingest_dir(): failed to retain non-tabular deliverable
           {.path {path}}: {conditionMessage(e)} - the archive write (if any)
           was rolled back with the state transition, so it stays quarantined
           and in the input directory; already-committed events in this run
           are unaffected."
        )
        NA_character_
      }
    )

    if (!is.na(result)) {
      retained <- c(retained, result)
    }
  }

  retained
}

# ---- R-9.9 empty-folder cleanup -------------------------------------------

#' Is this directory empty *for our purposes*? (R-9.9)
#'
#' Not `length(dir(f)) == 0`. That literal test essentially never fires in
#' production: the real `batch-2026-07-23` folder is "empty" and still on disk
#' today purely because Finder left a `.DS_Store` in it. A folder holding
#' nothing but files `ignore_rule()` would ignore is empty in every sense that
#' matters, and leaving it behind means the inbox silently accumulates one
#' husk per email forever.
#'
#' Conversely a folder holding ANY non-ignorable file is not empty, whatever
#' its state - a quarantined deliverable, a `failed` file, a source whose
#' removal was refused for a missing archive copy. Those are precisely the
#' files a human still has to look at, so the folder stays.
#' @keywords internal
#' @noRd
.ig_folder_is_spent <- function(folder) {
  entries <- list.files(folder, all.files = TRUE, no.. = TRUE, full.names = TRUE)
  if (length(entries) == 0) {
    return(TRUE)
  }
  # A subdirectory always keeps the folder alive: we did not route its contents
  # (ingest is non-recursive) so we know nothing about what is in it.
  if (any(dir.exists(entries))) {
    return(FALSE)
  }
  all(vapply(entries, function(p) {
    # ignore_rule() takes a file_meta() list; build one defensively, since a
    # file that vanished mid-sweep must not abort the cleanup of the rest.
    keep_it <- tryCatch(is.na(ignore_rule(file_meta(p))), error = function(e) TRUE)
    !isTRUE(keep_it)
  }, logical(1)))
}

#' Delete one per-email folder if this run spent it (R-9.9)
#'
#' Called from [ingest_inbox()], never from [ingest_dir()]. That placement is
#' the whole design constraint, not an implementation detail: the folder to
#' delete is the directory `ingest_dir()` was *called on*, and a function must
#' not delete its own root - the first attempt at this did exactly that and the
#' guard below (correctly) refused every folder, so nothing was ever cleaned
#' up. `ingest_inbox()` is the only layer that can see both the inbox root and
#' the folder as distinct things.
#'
#' @param root the inbox root. Never deleted, empty or not.
#' @param folder the per-email folder just ingested.
#' @param report that folder's `ingest_report`. Cleanup requires the run to
#'   have actually removed something: a folder still holding a quarantined
#'   deliverable is not spent, and a folder we merely previewed must be
#'   untouched.
#' @return `TRUE` if the folder was deleted.
#' @keywords internal
#' @noRd
.ig_remove_spent_folder <- function(root, folder, report) {
  if (isTRUE(report$failed) || isTRUE(report$dry_run)) {
    return(FALSE)
  }
  if (length(report$removed_files) == 0) {
    return(FALSE)
  }
  if (!isTRUE(as.logical(st_config("remove_ingested")))) {
    return(FALSE)
  }
  if (!dir.exists(folder)) {
    return(FALSE)
  }

  root_real <- normalizePath(root, mustWork = FALSE)
  folder_real <- normalizePath(folder, mustWork = FALSE)

  # Strictly BELOW the root. `identical()` catches the root itself; the prefix
  # test catches anything outside the tree, however it was spelled. Anything
  # failing either is skipped outright rather than trusted.
  if (identical(folder_real, root_real)) {
    return(FALSE)
  }
  if (!startsWith(folder_real, paste0(root_real, .Platform$file.sep))) {
    return(FALSE)
  }
  if (!.ig_folder_is_spent(folder_real)) {
    return(FALSE)
  }

  # `recursive = TRUE` takes the ignorable cruft with the folder - deliberate,
  # and safe only because `.ig_folder_is_spent()` has already established that
  # cruft is ALL that remains.
  ok <- unlink(folder_real, recursive = TRUE, force = FALSE)
  if (!identical(as.integer(ok), 0L)) {
    cli::cli_warn(
      "ingest_inbox(): could not remove the emptied input folder
       {.path {folder_real}}; it is left in place."
    )
    return(FALSE)
  }
  TRUE
}

# ---- remove switch (R-9.6, A13) ------------------------------------------

#' Delete input files whose content hash has a *verified* archive copy
#' (R-9.6, A13)
#'
#' Opens a fresh read-only connection (the pipeline's read-write connection
#' must already be closed - DuckDB is single-writer, but a read-only
#' connection can coexist). For each routed input path/hash the source is
#' deleted only when ALL of the following hold:
#'
#' * an `asset` row exists for that hash;
#' * the archive copy exists on disk as a REGULAR FILE (not merely its uuid
#'   directory);
#' * re-hashing the archived bytes reproduces the same xxHash128; and
#' * the source file still exists.
#'
#' The content check is not redundant with the existence check: the archive
#' lives on OneDrive/SharePoint, where a dehydrated placeholder, a truncated
#' upload or a conflicted rewrite all present as a regular file of the right
#' name. Deletion is irreversible, so "a file is there" is not sufficient
#' evidence that "the data is there".
#'
#' Any failed check keeps the source and emits a warning - files are never
#' deleted without a verified copy. Files with no `asset` row (cruft,
#' failed, quarantined) are left untouched.
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

    # EXISTENCE IS NOT ENOUGH. The archive lives on OneDrive/SharePoint, where a
    # copy can be a dehydrated placeholder, a truncated upload, or a conflicted
    # rewrite - all of which are regular files of the right name. Re-hash the
    # archived bytes and require them to equal the hash we are about to delete
    # the source for. This is the difference between "a file is there" and "the
    # data is there", and deletion is irreversible.
    copy_hash <- tryCatch(hash_file(copy_path), error = function(e) NA_character_)
    if (is.na(copy_hash) || !identical(copy_hash, hash)) {
      cli::cli_warn(
        "ingest_dir(): archive copy at {.path {copy_path}} does NOT match the
         source {.path {path}} (expected hash {.val {hash}}, archived copy
         hashes to {.val {copy_hash}}); keeping the source file."
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
#' produces no snapshot file. T1.2 (Robin's ruling, 2026-07-26): a dry run
#' ALSO makes zero `ingest_file` STATE writes - parsing/assembly/reconcile
#' still run in memory to build the preview, but none of it is persisted, so
#' a following run (dry or real) re-discovers the same files at the same
#' `route_files()`-assigned state and re-processes them for real. Before
#' this fix, the parse/assemble/reconcile stages silently advanced
#' `ingest_file.state` regardless of `dry_run`, so a dry run followed by a
#' real run over the SAME directory committed nothing - the exact
#' consequence of the cautious habit of dry-running first.
#'
#' [route_files()] gets the same `dry_run` treatment for every decision it
#' makes that is NOT safe to persist unconditionally: `unclaimed`, `failed`
#' and `adapter_tie` are all skipped under `dry_run` (state, route and, for
#' a tie, its `review_queue` item, all together) because each writes one of
#' `ingest_file`'s TERMINAL states, and that state is a verdict about the
#' adapter registry as it stood at that moment - not a durable fact about
#' the file - so persisting it during a preview would permanently stop the
#' hash from ever being re-decided once the registry is fixed (see the tie
#' branch in `R/router.R` for the full reasoning). Only `claimed` persists on
#' a dry run: it is a non-terminal handoff still re-visited by the
#' `dry_run`-gated stages above, not a verdict.
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
#' @param reconsider R-3.7. Passed to [route_files()]: re-decide files whose
#'   stored state is an adapter-registry verdict (`unclaimed`, `adapter_tie`,
#'   router-`failed`) instead of reading it back. Use after adding a missing
#'   adapter or fixing a buggy one. `ignored` and `archived` are never
#'   reconsidered.
#' @return an `ingest_report` (a named list) summarising the run: file
#'   counts by terminal state, events processed/committed, row tallies
#'   (new/already_present/superseded/skipped), review items opened, the
#'   snapshot path (or `NA`), and any removed files.
#' @export
ingest_dir <- function(path, db = st_config("live_db"), dry_run = FALSE,
                       reconsider = FALSE) {
  checkmate::assert_string(path)
  checkmate::assert_string(db)
  checkmate::assert_flag(dry_run)
  checkmate::assert_flag(reconsider)

  register_builtin_adapters()

  paths <- as.character(fs::dir_ls(path, type = "file", all = TRUE, recurse = FALSE))

  pipeline <- with_db_write(
    function(con) {
      ensure_schema(con)

      routed <- route_files(paths, con, dry_run, reconsider)

      parsed <- .ig_parse_claimed(con, routed, dry_run)

      events <- list()
      if (length(parsed) > 0) {
        asm <- assemble_events(parsed)
        .ig_apply_assemble_states(con, asm$states, dry_run)
        events <- asm$events
      }

      outcome <- .ig_reconcile_and_commit(con, events, dry_run)

      # R-15.36/B-15.F17: retain the non-tabular deliverables of a work order
      # that has a `project` row. NOT "committed in this run", which is what
      # this comment used to say and what the SQL never did - `project` is
      # persistent, so a COA arriving in its own email a day later attaches to
      # the work order an EARLIER run committed (Robin's ruling, R-15.36a).
      # Skipped on `dry_run` - archiving is a core-table write, and
      # `ingest_dir()`'s own contract is that a dry run makes ZERO core-table
      # writes (see roxygen above).
      retained <- character(0)
      if (!dry_run) {
        retained <- .ig_retain_siblings(con, routed)
      }

      # Capture the live terminal states now, while `con` is still open -
      # `with_db_write()` closes it on return (R-12.7/F13; see
      # `.ig_current_states()`).
      file_states <- .ig_current_states(con, routed$hash)

      list(routed = routed, events = events, outcome = outcome,
           file_states = file_states, retained = retained)
    },
    db = db
  )

  # Snapshot AFTER the pipeline connection has closed (DuckDB is
  # single-writer) - and let a snapshot error propagate uncaught.
  #
  # R-9.10: retention counts as well as commits. `.ig_retain_siblings()` writes
  # `asset` rows and moves `ingest_file` states, so a retain-only run has
  # changed the database exactly as much as a committing one has - and gating
  # only on `committed_any` meant the COA arriving in its own email got
  # archived and then never removed, because `.ig_remove_verified()` below
  # requires a snapshot. The folder consequently never emptied and R-9.9 never
  # fired. The strict commit -> archive -> snapshot -> remove ORDER of R-9.6 is
  # untouched; this only widens what counts as "something happened".
  did_something <- isTRUE(pipeline$outcome$committed_any) ||
    length(pipeline$retained) > 0
  snapshot_path <- NA_character_
  if (did_something && !dry_run) {
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

# ---- R-9.7 ingest_inbox(): one batch per email folder ---------------------

#' Ingest an inbox of per-email folders, one batch per folder
#'
#' PowerAutomate saves the attachments of a single lab email into their own
#' folder under the inbox root, so a folder is the durable record of "these
#' files arrived together". [ingest_dir()] is deliberately non-recursive (A8,
#' R-9.5) and stays that way; this walks the root's immediate subdirectories
#' and calls it once per folder, in sorted order.
#'
#' Per-folder rather than a `recurse = TRUE` flag on `ingest_dir()`, for three
#' reasons each independently sufficient:
#'
#' * it keeps one email's files as one batch, which is what makes R-9.8's
#'   "does this folder belong to exactly one work order?" a meaningful
#'   question - flattened into a single batch it would be asking about the
#'   whole inbox, and the real `batch-2026-07-23` folder held eight work
#'   orders;
#' * a folder that throws is contained, and the rest of the inbox still
#'   commits (the same A27/R-12.1 containment discipline every other per-item
#'   stage in this file follows);
#' * it gives R-9.9 a well-defined unit to delete once emptied.
#'
#' Files sitting loose in `root` are deliberately NOT ingested: mixing them
#' into the sweep would make the batch boundary ambiguous, and they are
#' `ingest_dir(root)`'s job if you want them. They are never deleted either,
#' since nothing here routes them.
#'
#' @param root directory holding one subdirectory per email.
#' @param db path to the DuckDB file to ingest into.
#' @param dry_run passed through to each [ingest_dir()] call.
#' @param reconsider passed through to each [ingest_dir()] call (R-3.7).
#' @return a list with `n_folders`, `n_folders_failed`, and `folders`: a named
#'   list (folder basename -> that folder's `ingest_report`, or a
#'   `list(failed = TRUE, error = <message>)` for one that threw).
#' @export
ingest_inbox <- function(root, db = st_config("live_db"), dry_run = FALSE,
                         reconsider = FALSE) {
  checkmate::assert_string(root)
  checkmate::assert_string(db)
  checkmate::assert_flag(dry_run)
  checkmate::assert_flag(reconsider)

  if (!dir.exists(root)) {
    cli::cli_abort(
      "ingest_inbox(): {.path {root}} is not an existing directory.",
      class = "sampletidy_error"
    )
  }

  folders <- sort(list.dirs(root, full.names = TRUE, recursive = FALSE))

  reports <- list()
  n_failed <- 0L
  n_folded <- 0L
  for (folder in folders) {
    name <- basename(folder)
    reports[[name]] <- tryCatch(
      ingest_dir(folder, db = db, dry_run = dry_run, reconsider = reconsider),
      error = function(e) {
        # Contained per folder, and NAMED - a silently-skipped email folder is
        # indistinguishable from one that had nothing in it, which is exactly
        # the ambiguity that lets a delivery go missing unnoticed.
        cli::cli_warn(
          "ingest_inbox(): folder {.path {name}} failed and was skipped:
           {conditionMessage(e)} - the other folders in this inbox are
           unaffected."
        )
        list(failed = TRUE, error = conditionMessage(e))
      }
    )
    if (isTRUE(reports[[name]]$failed)) {
      n_failed <- n_failed + 1L
    }

    # R-9.9. Contained: failing to tidy up a folder must never lose the report
    # of the ingest that succeeded, nor stop the remaining folders.
    folded <- tryCatch(
      .ig_remove_spent_folder(root, folder, reports[[name]]),
      error = function(e) {
        cli::cli_warn(
          "ingest_inbox(): folder {.path {name}} ingested successfully but
           could not be cleaned up: {conditionMessage(e)}"
        )
        FALSE
      }
    )
    if (isTRUE(folded)) {
      n_folded <- n_folded + 1L
    }
  }

  cli::cli_inform(
    "ingest_inbox({.path {root}}): {length(folders)} folder(s),
     {n_failed} failed, {n_folded} emptied folder(s) removed."
  )

  list(
    n_folders = length(folders),
    n_folders_failed = n_failed,
    n_folders_removed = n_folded,
    folders = reports
  )
}

# ---- R-9.11 quarantine_report() -------------------------------------------

#' Report the files ingest could not place (R-9.11)
#'
#' Every `ingest_file` row in a terminal state that is NOT `archived`: today
#' that means `quarantined` (no adapter claimed it, or two tied) and `failed`
#' (an adapter threw, or its event's reconcile/commit did). `ignored` is
#' excluded - a `.bak` or a zero-byte file is a decision, not a backlog.
#'
#' Nothing in the package surfaced these rows before this function existed,
#' which is how 19 of them sat unnoticed in the live DB from 2026-07-23 until
#' someone went looking by hand.
#'
#' `work_order_guess` is derived from the STORED filename, never by re-reading
#' the file: by the time anyone runs this report the input folder is routinely
#' gone, and a report that errors on a missing file is a report nobody runs.
#' It uses the same helper [file_meta()] does, so an ACIRL `2400-*` name yields
#' `NA` here exactly as it does everywhere else - the report must not become
#' the one place that guesses.
#'
#' Read-only: opens a read-only connection and closes it before returning.
#'
#' @param db path to the DuckDB file to report on.
#' @return a tibble `(hash, filename, path_first_seen, state, state_reason,
#'   work_order_guess, first_seen_at)`, newest first. Zero rows (with every
#'   column present) when there is nothing to report.
#' @export
quarantine_report <- function(db = st_config("live_db")) {
  checkmate::assert_string(db)

  con <- st_connect(db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  rows <- DBI::dbGetQuery(
    con,
    "SELECT hash, filename, path_first_seen, state, state_reason, first_seen_at
       FROM ingest_file
      WHERE state IN ('quarantined', 'failed')
      ORDER BY first_seen_at DESC, filename"
  )

  # Build the column set explicitly rather than relying on dplyr::mutate over a
  # zero-row frame: the empty case is the one downstream code is most likely to
  # hit first (a clean DB) and least likely to be tested against.
  tibble::tibble(
    hash = as.character(rows$hash),
    filename = as.character(rows$filename),
    path_first_seen = as.character(rows$path_first_seen),
    state = as.character(rows$state),
    state_reason = as.character(rows$state_reason),
    work_order_guess = vapply(
      as.character(rows$filename),
      function(fn) {
        if (is.na(fn)) return(NA_character_)
        .st_guess_work_order_revision(fn)$work_order_guess
      },
      character(1), USE.NAMES = FALSE
    ),
    first_seen_at = rows$first_seen_at
  )
}
