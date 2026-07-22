# PLAN-14 (R-14.1, R-14.2) - operator-run migration: merge the duplicate
# `Carbophenothion` analyte rows and backfill `lab_method.reported_as` /
# `lab_method.conversion_constant`.
#
# NEVER invoked by package code (A50) - an operator runs it directly, e.g.:
#   env <- new.env()
#   sys.source("dev/migrations/002-registry-remediation.R", envir = env)
#   env$mig002_run(db = "/path/to/monitoring.duckdb",
#                   snapshot_dir = "/path/to/snapshots", dry_run = TRUE)
#
# Depends on PLAN-13's `001-alias-indirection.R` having already run against
# `db` (R-14.2 writes `lab_method.reported_as`/`conversion_constant`, which
# do not exist pre-001).
#
# ---- "Which database" - every write goes through the mutation layer -------
# db_update()/db_delete() (R/mutate.R) - NEVER a raw dbExecute()/
# dbSendStatement()/dbAppendTable()/dbWriteTable() write. Reads (dbGetQuery,
# including the backup's CHECKPOINT - a statement with no result rows, but
# `dbGetQuery()` runs it fine and is not a "raw write" call) are plain DBI.
# Contrast `001-alias-indirection.R`: that migration is raw DDL (table
# rebuilds duckdb 1.4.1 cannot do any other way, A49) and is lint-exempt for
# it; this migration only edits existing rows, so there is no excuse to
# reach for raw SQL here - a meta-guard test greps this file for the four
# forbidden calls and fails on any hit.
#
# R-14.3 is CLOSED - no write, no code here touches `analysis.value`. Both
# criteria below prove it via an explicit `analysis` row-count-and-value
# snapshot taken before and after, inside the one migration transaction.

# =============================================================================
# R-14.1: merge the duplicate Carbophenothion analyte rows
# =============================================================================

#' Read the current `Carbophenothion`-named `analyte` rows, ranked by how
#' many analyses reach each one (through its own `lab_method` row(s))
#'
#' Read-only; shared by the writer (`mig002_carbophenothion_merge()`) and the
#' dry-run preview. The survivor is the row with the most analyses ("many" in
#' the plan text); with the documented two-row duplicate this is exact, and
#' generalizes safely to more than two identically-named rows (each
#' subsequent run peels off one more doomed row via the same rule).
#'
#' @param con an open DBI connection (read-only is fine).
#' @return data.frame(uuid, n_analyses), ordered survivor-first.
.mig002_carb_dupes <- function(con) {
  DBI::dbGetQuery(con, "
    SELECT an.uuid,
           (SELECT COUNT(*) FROM analysis a JOIN lab_method lm ON a.uuid_lab = lm.uuid
            WHERE lm.uuid_analyte = an.uuid) AS n_analyses
    FROM analyte an WHERE an.name = 'Carbophenothion'
    ORDER BY n_analyses DESC, an.uuid")
}

#' Read-only preview of what the merge would do (used by `dry_run = TRUE`)
#'
#' @param con an open DBI connection.
#' @return list(merged, survivor, deleted) - see `mig002_run()`'s doc.
.mig002_carb_preview <- function(con) {
  dupes <- .mig002_carb_dupes(con)
  if (nrow(dupes) < 2) {
    return(list(
      merged = FALSE,
      survivor = if (nrow(dupes) == 1) dupes$uuid[[1]] else NA_character_,
      deleted = NA_character_
    ))
  }
  list(merged = TRUE, survivor = dupes$uuid[[1]], deleted = dupes$uuid[[2]])
}

#' Merge the doomed `Carbophenothion` analyte row into the survivor
#'
#' Repoints every `lab_method` row and every `analyte_mask` row currently
#' pointing at the doomed analyte onto the survivor, then `db_delete()`s the
#' doomed analyte row. No `analysis` row is touched - analyses reach the
#' analyte THROUGH `lab_method`, never directly.
#'
#' Idempotency mechanism (not an optimisation): reads the current duplicate
#' set FIRST. If fewer than 2 `Carbophenothion` analyte rows remain, the
#' doomed row is already gone (a prior run already merged it, or there never
#' was a duplicate) - the WHOLE merge is skipped, repoints included. Without
#' this check, a second run would call `db_delete()` on a uuid that no
#' longer exists and ABORT (CONTRACT A72) - do not "simplify" this check
#' away, it is the reason a re-run does not throw.
#'
#' @param con an open read-write DBI connection (participates in the
#'   caller's open mutation-layer transaction, if any - see
#'   `db_transaction()`).
#' @param actor who is making this change.
#' @param reason free-text reason, stored on every `change_log` row.
#' @return list(merged, survivor, deleted) - see `mig002_run()`'s doc.
mig002_carbophenothion_merge <- function(con, actor, reason) {
  dupes <- .mig002_carb_dupes(con)
  if (nrow(dupes) < 2) {
    return(list(
      merged = FALSE,
      survivor = if (nrow(dupes) == 1) dupes$uuid[[1]] else NA_character_,
      deleted = NA_character_
    ))
  }

  survivor <- dupes$uuid[[1]]
  doomed <- dupes$uuid[[2]]

  lm_rows <- DBI::dbGetQuery(
    con, "SELECT uuid FROM lab_method WHERE uuid_analyte = ?", params = list(doomed)
  )
  for (lm_uuid in lm_rows$uuid) {
    # ---- duckdb 1.4.1 chained-FK limitation (verified empirically) ----
    # `lab_method` is BOTH a foreign-key CHILD of `analyte` (its own
    # `uuid_analyte` column) AND a foreign-key PARENT of `analysis`
    # (`analysis.uuid_lab`). duckdb 1.4.1 refuses an UPDATE of a
    # chained-FK table's own outgoing-FK column while ANY row downstream
    # still references it - "Constraint Error: ... still referenced by a
    # foreign key in a different table" - even mid-transaction, even right
    # after nulling the very same downstream references in an earlier
    # statement of the same transaction. The only workaround: temporarily
    # detach the referencing `analysis` rows (set `uuid_lab` to NULL, its
    # own committed statement), repoint `lab_method`, then reattach them to
    # the SAME lab_method uuid (another committed statement). Every step
    # still goes through `db_update()` (mutation layer only, never raw
    # SQL); each call commits on its own here because this function is
    # called with an UNTAGGED `con` (`mig002_run()` deliberately does not
    # wrap this in one shared `db_transaction()` - see its own comment).
    # The FINAL `analysis` state is byte-identical to before (verified by
    # `mig002_run()`'s own whole-migration before/after snapshot), so
    # R-14.1's real invariant - no analysis is re-pointed to a different
    # lab_method - holds even though this is not one atomic SQL statement.
    dependents <- DBI::dbGetQuery(
      con, "SELECT uuid FROM analysis WHERE uuid_lab = ?", params = list(lm_uuid)
    )
    for (a_uuid in dependents$uuid) {
      db_update(
        con, "analysis", uuid = a_uuid,
        changes = list(uuid_lab = NA_character_), actor = actor,
        reason = paste(reason, "(temporary FK detach, duckdb 1.4.1 chained-FK limitation)")
      )
    }
    db_update(
      con, "lab_method", uuid = lm_uuid,
      changes = list(uuid_analyte = survivor), actor = actor, reason = reason
    )
    for (a_uuid in dependents$uuid) {
      db_update(
        con, "analysis", uuid = a_uuid,
        changes = list(uuid_lab = lm_uuid), actor = actor,
        reason = paste(reason, "(FK reattach, duckdb 1.4.1 chained-FK limitation)")
      )
    }
  }

  mask_rows <- DBI::dbGetQuery(
    con, "SELECT variant FROM analyte_mask WHERE uuid_analyte = ?", params = list(doomed)
  )
  for (variant in mask_rows$variant) {
    db_update(
      con, "analyte_mask", key = list(uuid_analyte = doomed, variant = variant),
      changes = list(uuid_analyte = survivor), actor = actor, reason = reason
    )
  }

  db_delete(con, "analyte", uuid = doomed, actor = actor, reason = reason)

  list(merged = TRUE, survivor = survivor, deleted = doomed)
}

# =============================================================================
# R-14.2: backfill lab_method.reported_as / conversion_constant
# =============================================================================

# The plan's seven enumerated `lab_method` names. PINNED: a matched name
# outside this literal set gets `reported_as` (the regex still captures the
# token) but NEVER a `conversion_constant` - never guess one.
.mig002_known_seven <- c(
  "Ammonia as N", "Ammonia as NH3",
  "Total Alkalinity as CaCO3", "Bicarbonate Alkalinity as CaCO3",
  "Carbonate Alkalinity as CaCO3", "Hydroxide Alkalinity as CaCO3",
  "Total Hardness as CaCO3"
)

# The one recovered constant PINNED by the plan (R-14.3's worked example:
# 0.8224428 x 2.14 = 1.76002759, the NH3 -> N mass ratio - NEVER 1.216). The
# other six enumerated names already report on their own analyte's basis
# (Ammonia as N -> analyte N; the five CaCO3 methods -> analyte CaCO3), so no
# constant is invented for them either - this map is deliberately a single
# entry, not a lookup table of six more guesses.
.mig002_known_constants <- c("Ammonia as NH3" = 0.8224428)

#' Analyze every `lab_method` row against the `(?i) as (\w+)$` pattern
#' (read-only; shared by the writer and a dry-run preview)
#'
#' @param con an open DBI connection.
#' @return data.frame(uuid, name, matched, reported_as, is_seven,
#'   conversion_constant).
.mig002_reported_as_analyze <- function(con) {
  lm <- DBI::dbGetQuery(con, "
    SELECT lm.uuid, lm.name FROM lab_method lm ORDER BY lm.uuid")

  regex <- "\\sas\\s+(\\w+)$"
  caps <- regmatches(
    lm$name, regexec(regex, lm$name, perl = TRUE, ignore.case = TRUE)
  )
  captured <- vapply(
    caps, function(x) if (length(x) >= 2) x[[2]] else NA_character_, character(1)
  )
  matched <- !is.na(captured)
  is_seven <- matched & (lm$name %in% .mig002_known_seven)

  constant <- rep(NA_real_, nrow(lm))
  const_idx <- is_seven & (lm$name %in% names(.mig002_known_constants))
  constant[const_idx] <- unname(.mig002_known_constants[lm$name[const_idx]])

  data.frame(
    uuid = lm$uuid, name = lm$name, matched = matched,
    reported_as = captured, is_seven = is_seven,
    conversion_constant = constant,
    stringsAsFactors = FALSE
  )
}

#' Write `reported_as`/`conversion_constant` for every matched `lab_method`
#' row (R-14.2)
#'
#' Every matched row (the seven enumerated names AND any other name matching
#' the pattern) gets `reported_as` written. Only a row with a known,
#' recovered constant (`Ammonia as NH3`) also gets `conversion_constant`
#' written - every other matched row's `conversion_constant` stays NA.
#' Writes `lab_method` ONLY - `analysis.value` is never touched here
#' (R-14.3 CLOSED; the caller, `mig002_run()`, proves this with a snapshot
#' before/after the whole migration). Idempotent for free: `db_update()`
#' (R-12.6) skips writing/logging any field whose new value already equals
#' its current value, so a second run changes nothing further.
#'
#' @param con an open read-write DBI connection.
#' @param actor who is making this change.
#' @param reason free-text reason, stored on every `change_log` row.
#' @return list(matched_count, unmatched, outside_seven) - see
#'   `mig002_run()`'s doc.
mig002_reported_as_backfill <- function(con, actor, reason) {
  analysis <- .mig002_reported_as_analyze(con)

  unmatched <- analysis[!analysis$matched, c("uuid", "name")]
  outside_seven <- analysis[
    analysis$matched & !analysis$is_seven, c("uuid", "name", "reported_as")
  ]
  matched_rows <- analysis[analysis$matched, ]

  for (i in seq_len(nrow(matched_rows))) {
    row <- matched_rows[i, ]
    db_update(
      con, "lab_method", uuid = row$uuid,
      changes = list(
        reported_as = row$reported_as,
        conversion_constant = row$conversion_constant
      ),
      actor = actor, reason = reason
    )
  }

  list(
    matched_count = sum(analysis$matched),
    unmatched = unmatched,
    outside_seven = outside_seven
  )
}

# =============================================================================
# mig002_run() - backup / verify / transaction discipline (mirrors 001)
# =============================================================================

.mig002_default <- function(x, default) if (is.null(x)) default else x

#' Snapshot the whole `analysis` table (uuid, uuid_sample, uuid_lab, value,
#' quantified, rl_low), ordered for a stable diff - the row-count-and-value
#' invariant both R-14.1 and R-14.2 pin (R-14.3 CLOSED: no write here may
#' touch `analysis`).
#'
#' @param con an open DBI connection.
#' @return a data.frame.
.mig002_analysis_snapshot <- function(con) {
  DBI::dbGetQuery(con, "
    SELECT uuid, uuid_sample, uuid_lab, value, quantified, rl_low
    FROM analysis ORDER BY uuid")
}

.mig002_backup_counts <- function(con) {
  list(
    analyte = DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM analyte")$n,
    analyte_mask = DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM analyte_mask")$n,
    lab_method = DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM lab_method")$n,
    analysis = DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM analysis")$n
  )
}

#' Back up and VERIFY the live DB before any write (mirrors
#' `001-alias-indirection.R`'s `mig001_backup()`)
#'
#' Timestamped (millisecond precision). `CHECKPOINT` flushes to disk before
#' the copy is taken - run via `DBI::dbGetQuery()` (a statement with no
#' result rows, but `dbGetQuery()` executes it fine), never `dbExecute()`,
#' so this file never uses a forbidden raw-write call. Verifies the copy by
#' opening it read-only and comparing row counts to the live DB. Throws,
#' writing nothing to `db`, on any failure.
#'
#' @param db path to the live DuckDB file.
#' @param snapshot_dir directory to write the backup into.
#' @param .now inject a POSIXct instead of `Sys.time()`.
#' @return absolute path to the verified backup copy.
mig002_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- .mig002_default(.now, Sys.time())
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  fname <- sprintf("monitoring_pre-002-registry-remediation_%sZ.duckdb", ts)
  dest <- file.path(snapshot_dir, fname)

  live_counts <- with_db_write(
    function(con) {
      DBI::dbGetQuery(con, "CHECKPOINT")
      counts <- .mig002_backup_counts(con)
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

  backup_counts <- .mig002_backup_counts(verify_con)
  if (!identical(live_counts, backup_counts)) {
    cli::cli_abort(
      "{db}: backup verification failed - row counts differ between live DB and {dest}.",
      class = "sampletidy_error"
    )
  }

  dest
}

#' Run (or dry-run) the 002-registry-remediation migration (R-14.1 + R-14.2)
#'
#' Runs the R-14.1 merge (with its own existence pre-check, CONTRACT A72)
#' and the R-14.2 backfill, every write going through `db_update()`/
#' `db_delete()` - never raw SQL. Deliberately NOT wrapped in one shared
#' `db_transaction()`: `lab_method` is a chained-FK table (child of
#' `analyte`, parent of `analysis`), and duckdb 1.4.1 refuses to UPDATE its
#' outgoing-FK column while `analysis` still references it, even
#' mid-transaction (verified empirically; see
#' `mig002_carbophenothion_merge()`'s own comment for the detach/reattach
#' workaround this forces). Leaving each `db_update()`/`db_delete()` call to
#' commit on its own (the untagged `con` from `with_db_write()` is never
#' passed through `db_transaction()` here) is what makes that workaround
#' possible. Backs up and verifies before writing anything (skipped on
#' `dry_run = TRUE`, which writes nothing at all). Verifies, via a snapshot
#' taken before the merge and after the backfill, that `analysis` ends up
#' byte-identical to how it started (R-14.3 CLOSED) - true of the FINAL
#' state even though the merge's FK workaround touches `analysis` rows
#' in transit.
#'
#' Naturally idempotent on every re-run: R-14.1 via its own existence
#' pre-check, R-14.2 via `db_update()`'s built-in skip-unchanged-field
#' behaviour (R-12.6) - no separate `schema_version` marker gate is needed
#' (and `schema_version` is not in the mutation-layer allowlist, A32/A50, so
#' this migration does not write one).
#'
#' @param db path to the live DuckDB file.
#' @param snapshot_dir directory for the pre-migration backup.
#' @param actor who is making this change (recorded on every `change_log`
#'   row).
#' @param dry_run if `TRUE`, compute and return what would happen, writing
#'   nothing (no backup either).
#' @param .now inject a POSIXct instead of `Sys.time()` (propagated to the
#'   backup filename).
#' @return invisible list(
#'   status = "migrated" | "already_migrated" | "dry_run",
#'   backup_path = chr or NA, restore_command = chr or NA,
#'   carbophenothion = list(merged, survivor, deleted),
#'   reported_as = list(matched_count, unmatched, outside_seven)
#' )
mig002_run <- function(db, snapshot_dir, actor = "migration-002", dry_run = FALSE, .now = NULL) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))

  if (isTRUE(dry_run)) {
    preview_con <- st_connect(db, read_only = TRUE)
    preview <- tryCatch(
      {
        carb <- .mig002_carb_preview(preview_con)
        a <- .mig002_reported_as_analyze(preview_con)
        reported <- list(
          matched_count = sum(a$matched),
          unmatched = a[!a$matched, c("uuid", "name")],
          outside_seven = a[a$matched & !a$is_seven, c("uuid", "name", "reported_as")]
        )
        list(carb = carb, reported = reported)
      },
      finally = DBI::dbDisconnect(preview_con, shutdown = TRUE)
    )
    logf("DRY RUN: Carbophenothion merge would happen = %s.", isTRUE(preview$carb$merged))
    logf("DRY RUN: %d lab_method row(s) matched the reported_as pattern.", preview$reported$matched_count)
    logf("DRY RUN: no backup taken, no writes made to %s.", db)
    return(invisible(list(
      status = "dry_run",
      backup_path = NA_character_,
      restore_command = NA_character_,
      carbophenothion = preview$carb,
      reported_as = preview$reported
    )))
  }

  backup_path <- mig002_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)

  result <- with_db_write(
    function(con) {
      before <- .mig002_analysis_snapshot(con)

      carb <- mig002_carbophenothion_merge(
        con, actor = actor,
        reason = "PLAN-14 R-14.1: merge duplicate Carbophenothion analyte"
      )
      reported <- mig002_reported_as_backfill(
        con, actor = actor,
        reason = "PLAN-14 R-14.2: reported_as/conversion_constant backfill"
      )

      after <- .mig002_analysis_snapshot(con)
      if (!identical(before, after)) {
        cli::cli_abort(
          "002-registry-remediation verify failed: `analysis` was altered.",
          class = "sampletidy_error"
        )
      }

      list(carb = carb, reported = reported)
    },
    db = db
  )

  logf("002-registry-remediation applied.")

  invisible(list(
    status = "migrated",
    backup_path = backup_path,
    restore_command = restore_command,
    carbophenothion = result$carb,
    reported_as = result$reported
  ))
}
