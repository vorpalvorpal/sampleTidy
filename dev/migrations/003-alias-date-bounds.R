# PLAN-15 E (B-15.E1, B-15.E5, R-15.10, R-15.19) - operator-run migration:
# add `date_start`/`date_end` to `feature_alias`, resettle `auto_assign`
# under R1's universal self-arm flip, and apply E.5's 9 curated bounds.
#
# NEVER invoked by package code (A50) - no `ensure_schema()`, `ingest_dir()`
# or other package entry point sources this file. An operator runs it
# directly, e.g.:
#   env <- new.env()
#   sys.source("dev/migrations/003-alias-date-bounds.R", envir = env)
#   env$mig003_run(db = "/path/to/monitoring.duckdb",
#                   snapshot_dir = "/path/to/snapshots", dry_run = TRUE)
#
# Reuses `with_db_write()` / `st_connect()` (R/db-connect.R), and
# `db_transaction()` / `db_update()` (R/mutate.R) for the itemised bounds
# UPDATEs, so each carries a real `change_log` provenance row (A32) rather
# than a raw, unaudited `UPDATE` - matching the "reuse, don't re-derive"
# rule for the one part of this migration (E.5's curated data) that is a
# targeted, itemised, auditable correction rather than a bulk table-wide fix.
#
# THE SPLIT (PLAN-15 B-15.E5, adjudicated 2026-07-24). E.5 itemises its
# bounds against LIVE `feature_alias` keys (`b.s01`, `k.e02`, ...); none of
# those exist on any `T.*`/`TH.*` test fixture. So the bounds table is an
# ARGUMENT, not a hard-coded literal inside the entry point:
#   mig003_run(db, snapshot_dir, dry_run = FALSE, .now = NULL,
#              bounds = .mig003_e5_bounds())
#   .mig003_apply_bounds(con, bounds)
# `bounds = .mig003_e5_bounds()` keeps the production default unchanged (no
# real caller ever passes `bounds`); tests inject a fixture-scoped table (see
# `tests/testthat/helper-migration-003-db.R`) at the `mig003_run()` level,
# exercising the real entry point rather than only the internal applier.
#
# S-15.9: plain `ALTER TABLE feature_alias ADD COLUMN` only - NEVER a
# TEMP-copy rebuild. `DROP TABLE feature_alias` is refused live (`Catalog
# Error: ... main key table of the table "sample"`), so the rebuild pattern
# 001 uses elsewhere is not merely unnecessary here, it is impossible without
# cascading into `sample`/`analysis`. Verified 001:501-510.

.mig003_marker_version <- 1003L

.mig003_default <- function(x, default) if (is.null(x)) default else x

# ---- E.5: the real curated bounds table (production default) --------------
#
# Robin's 2026-07-23 rulings, FROZEN as data - not re-derived (PLAN-15 E.5:
# "THE LITERALS IN THIS TABLE ARE FROZEN ... An implementer transcribes them;
# a later run of any derivation script does NOT get to overwrite them").
# Sydney-LOCAL calendar dates (E.5's own correction, +1 day from
# `sample.date`'s stored UTC-naive Sydney-midnight convention). `b.s22`
# appears twice (->B.S06 and ->B.TS18): the alias key alone is ambiguous,
# resolved by the (alias_key, target feature name) pair (E.5 "Row identity
# for the UPDATEs").
#
# Rule shape, matching R5/R1's restatement:
#  - b.s01->B.TS41, b.ts02->B.TS27, b.ts41->B.TMW15: EXACT rule-1 (one-off) -
#    POINT bound, date_start == date_end.
#  - b.s04->B.S01, b.s22->B.TS18: PROXY rule-1 (target's-last-sample proxy) -
#    date_end only, date_start stays NULL (unruled for proxies).
#  - b.s22->B.S06, k.e02->K.S06: rule-2 (recurring, Robin reviews every
#    time) - stays NULL/NULL. `k.e02`->K.S06 is RECLASSIFIED from rule 1 to
#    rule 2 under R5 (K.E02 and K.S06 coexist for their entire lifespans and
#    both end on the same day, so no `date_end` can separate them).
#  - b.ts18->B.S30, b.ts40->B.TS39: rule-3 (decommissioned/renamed) -
#    date_end only, the earlier of the two features' last-sample dates.
# 7 of the 9 get a non-NULL `date_end` (all but the two rule-2 rows); 3 of
# those (the exact rule-1 rows) additionally get `date_start == date_end`
# (R5's point bound - a `date_end`-only bound is live back to the beginning
# of time, and B.TS41's single sample would otherwise shadow 24 years of
# B.S01 history).
#
# @return data.frame(alias_key, target_name, date_start, date_end).
.mig003_e5_bounds <- function() {
  data.frame(
    alias_key = c(
      "b.s01", "b.ts02", "b.ts41",
      "b.s22", "b.s04", "b.s22",
      "k.e02",
      "b.ts18", "b.ts40"
    ),
    target_name = c(
      "B.TS41", "B.TS27", "B.TMW15",
      "B.S06", "B.S01", "B.TS18",
      "K.S06",
      "B.S30", "B.TS39"
    ),
    date_start = as.Date(c(
      "2026-01-21", "2021-11-12", "2024-04-08",
      NA, NA, NA,
      NA,
      NA, NA
    )),
    date_end = as.Date(c(
      "2026-01-21", "2021-11-12", "2024-04-08",
      NA, "2026-05-04", "2021-11-12",
      NA,
      "2021-11-12", "2024-04-08"
    )),
    stringsAsFactors = FALSE
  )
}

# ---- mig003_counts_checksum() -----------------------------------------------

#' Row counts + a value checksum over the tables this migration never
#' writes to, plus `feature_alias`'s own row-count/uuid-set invariant
#'
#' Deliberately EXCLUDES `analysis`: 003 never touches it (unlike 001, which
#' rebuilds it, or 004, whose fixture inherits 001's full schema), and the
#' `feature_alias`-only seed this migration's own tests run on
#' (`tests/testthat/helper-migration-003-db.R`, S-15.9's dedicated FK-parent
#' fixture) has no `analysis` table at all - a fixture built to prove the
#' `DROP TABLE feature_alias` refusal, not a full-schema clone. Every table
#' selected here IS guaranteed present on both that fixture and the live
#' registry.
#'
#' `feature_alias` itself is EXPECTED to change (auto_assign flips, bounds
#' written) - so unlike the other tables, only its ROW COUNT and its uuid
#' SET are checked here (S-15.9: a plain `ADD COLUMN` never inserts, deletes
#' or regenerates a uuid; a forbidden rebuild would). Its changed COLUMN
#' VALUES are not part of this checksum.
#'
#' @param con an open DBI connection.
#' @return named list(feature, feature_mask, analyte, lab_method, project,
#'   sample, feature_alias_n, feature_alias_uuids, checksum).
mig003_counts_checksum <- function(con) {
  feature_n <- DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM feature")$n
  mask_n <- DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM feature_mask")$n
  analyte_n <- DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM analyte")$n
  lab_method_n <- DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM lab_method")$n
  project_n <- DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM project")$n
  sample_n <- DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM \"sample\"")$n
  alias_n <- DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM feature_alias")$n
  alias_uuids <- DBI::dbGetQuery(con, "SELECT uuid FROM feature_alias ORDER BY uuid")$uuid

  feature_vals <- DBI::dbGetQuery(
    con, "SELECT uuid, name, site, date_end, lon, lat FROM feature ORDER BY uuid"
  )
  mask_vals <- DBI::dbGetQuery(
    con, "SELECT uuid_feature, variant, name FROM feature_mask ORDER BY uuid_feature, variant, name"
  )
  analyte_vals <- DBI::dbGetQuery(con, "SELECT uuid, name FROM analyte ORDER BY uuid")
  lab_method_vals <- DBI::dbGetQuery(
    con, "SELECT uuid, uuid_analyte, name FROM lab_method ORDER BY uuid"
  )
  project_vals <- DBI::dbGetQuery(con, "SELECT uuid, name FROM project ORDER BY uuid")
  sample_vals <- DBI::dbGetQuery(
    con, "SELECT uuid, uuid_feature_alias, \"date\", datetime FROM \"sample\" ORDER BY uuid"
  )

  checksum <- digest::digest(
    list(feature_vals, mask_vals, analyte_vals, lab_method_vals, project_vals, sample_vals),
    algo = "sha1"
  )

  list(
    feature = as.integer(feature_n),
    feature_mask = as.integer(mask_n),
    analyte = as.integer(analyte_n),
    lab_method = as.integer(lab_method_n),
    project = as.integer(project_n),
    sample = as.integer(sample_n),
    feature_alias_n = as.integer(alias_n),
    feature_alias_uuids = alias_uuids,
    checksum = checksum
  )
}

# ---- mig003_verify() --------------------------------------------------------

#' Step hard verify gate
#'
#' Every table this migration never writes to is byte-identical before/after
#' (checksum + counts); `feature_alias`'s row count and uuid SET are
#' unchanged (S-15.9 - no INSERT/DELETE, ever, only ALTER/UPDATE). Its
#' column values are deliberately NOT compared here - the whole point of
#' this migration is to change some of them.
#'
#' @param before,after `mig003_counts_checksum()`-shaped lists.
#' @return invisible(TRUE) if every invariant holds; throws otherwise.
mig003_verify <- function(before, after) {
  scalar_fields <- c(
    "feature", "feature_mask", "analyte", "lab_method", "project", "sample",
    "feature_alias_n", "checksum"
  )
  bad <- Filter(function(f) !identical(before[[f]], after[[f]]), scalar_fields)
  if (!setequal(before$feature_alias_uuids, after$feature_alias_uuids)) {
    bad <- c(bad, "feature_alias_uuids")
  }
  if (length(bad) > 0) {
    cli::cli_abort(
      "003-alias-date-bounds verify failed: mismatch in {paste(bad, collapse = ', ')}.",
      class = "sampletidy_error"
    )
  }
  invisible(TRUE)
}

# ---- mig003_backup() --------------------------------------------------------

.mig003_backup_counts <- function(con) {
  list(
    feature = DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM feature")$n,
    feature_mask = DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM feature_mask")$n,
    analyte = DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM analyte")$n,
    lab_method = DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM lab_method")$n,
    project = DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM project")$n,
    sample = DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM \"sample\"")$n,
    feature_alias = DBI::dbGetQuery(con, "SELECT COUNT(*) n FROM feature_alias")$n
  )
}

#' Step 1 - back up and VERIFY the live DB before any write (mirrors
#' `mig001_backup()` / `mig004_backup()`)
#'
#' Timestamped (millisecond precision). `CHECKPOINT` flushes to disk before
#' the copy is taken. Verifies the copy by opening it read-only and
#' comparing row counts to the live DB. Throws, writing nothing to `db`, on
#' any failure.
#'
#' @param db path to the live DuckDB file.
#' @param snapshot_dir directory to write the backup into.
#' @param .now inject a POSIXct instead of `Sys.time()`.
#' @return absolute path to the verified backup copy.
mig003_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- .mig003_default(.now, Sys.time())
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  fname <- sprintf("monitoring_pre-003-alias-date-bounds_%sZ.duckdb", ts)
  dest <- file.path(snapshot_dir, fname)

  live_counts <- with_db_write(
    function(con) {
      DBI::dbExecute(con, "CHECKPOINT")
      counts <- .mig003_backup_counts(con)
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

  backup_counts <- .mig003_backup_counts(verify_con)
  if (!identical(live_counts, backup_counts)) {
    cli::cli_abort(
      "{db}: backup verification failed - row counts differ between live DB and {dest}.",
      class = "sampletidy_error"
    )
  }

  dest
}

# ---- .mig003_apply_bounds() -------------------------------------------------

#' Apply an itemised date-bounds table to `feature_alias` (E.5)
#'
#' For each row of `bounds`: match the ONE `feature_alias` row where
#' `alias_key` equals `bounds$alias_key[i]`, `kind != 'self'`, and whose
#' `uuid_feature` resolves to a `feature` named `bounds$target_name[i]` -
#' E.5's "row identity for the UPDATEs", `kind`-qualified so the confirmed
#' `transcription_error` duplicate (E.8) never collides with the curated
#' non-self arm. THROWS (`sampletidy_error`, catchable) if that match is not
#' EXACTLY one row - zero (a stale/mistyped target) and two (an unmerged
#' duplicate) are both wrong. Sets `date_start`, `date_end` AND
#' `auto_assign = TRUE` on the matched row via `db_update()` (R/mutate.R),
#' so each write carries a real `change_log` provenance row and participates
#' in the caller's open mutation-layer transaction if there is one.
#'
#' The whole loop runs inside one `db_transaction()`: an abort partway
#' through (row 5 of 9, say) rolls back every row this call already wrote,
#' not just the one that failed - "writes nothing" is a property of the
#' WHOLE call, not of the one bad row.
#'
#' @param con an open read-write DBI connection.
#' @param bounds data.frame(alias_key, target_name, date_start, date_end)
#'   (`date_start`/`date_end` are `Date` or `NA`).
#' @return integer(1), the number of bounds rows applied.
.mig003_apply_bounds <- function(con, bounds) {
  n <- nrow(bounds)
  if (n == 0) {
    return(invisible(0L))
  }

  db_transaction(con, function(con) {
    for (i in seq_len(n)) {
      alias_key <- bounds$alias_key[[i]]
      target_name <- bounds$target_name[[i]]

      matched <- DBI::dbGetQuery(
        con,
        "SELECT fa.uuid FROM feature_alias fa
         JOIN feature f ON fa.uuid_feature = f.uuid
         WHERE fa.alias_key = ? AND fa.kind != 'self' AND f.name = ?",
        params = list(alias_key, target_name)
      )
      if (nrow(matched) != 1) {
        cli::cli_abort(
          paste0(
            "003-alias-date-bounds: bounds row {i} (alias_key = {.val {alias_key}}, ",
            "target_name = {.val {target_name}}) matched {nrow(matched)} non-self ",
            "feature_alias row(s); expected exactly 1."
          ),
          class = "sampletidy_error"
        )
      }

      db_update(
        con, "feature_alias", uuid = matched$uuid[[1]],
        changes = list(
          date_start = bounds$date_start[[i]],
          date_end = bounds$date_end[[i]],
          auto_assign = TRUE
        ),
        actor = "003-alias-date-bounds",
        reason = sprintf(
          "PLAN-15 E.5: itemised date bound applied by migration 003 (%s -> %s).",
          alias_key, target_name
        )
      )
    }
  })

  invisible(n)
}

# ---- mig003_run() -----------------------------------------------------------

#' Run (or dry-run) the 003-alias-date-bounds migration (B-15.E1/E.5,
#' R-15.10/R-15.19)
#'
#' Steps, all inside one transaction:
#'  1. `ALTER TABLE feature_alias ADD COLUMN date_start DATE`,
#'     `ADD COLUMN date_end DATE` (S-15.9: plain ADD COLUMN only).
#'  2. R1's universal self flip, TABLE-WIDE and unconditional:
#'     `auto_assign = TRUE` on every `kind = 'self'` row whose flag is not
#'     already TRUE - a bulk, migration-level correction (like 001's own
#'     bulk self-alias seeding), not an itemised curator action, so it is
#'     one raw `UPDATE`, not 895 individual `change_log` rows.
#'  3. `.mig003_apply_bounds()` with `bounds` (E.5's curated table, or an
#'     injected fixture-scoped one - see the file header).
#'
#' Never invoked by package code (A50). An operator runs it directly.
#'
#' @param db path to the live DuckDB file.
#' @param snapshot_dir directory for the pre-migration backup.
#' @param dry_run if `TRUE`, print what would happen and write nothing.
#' @param .now inject a POSIXct instead of `Sys.time()` (propagated to the
#'   backup filename and the schema_version marker).
#' @param bounds data.frame(alias_key, target_name, date_start, date_end) -
#'   defaults to `.mig003_e5_bounds()` (the real curated table), so the
#'   production default is unchanged and no production caller passes it;
#'   injectable for tests.
#' @return invisible list(status, backup_path, restore_command,
#'   counts_before, counts_after, recorded_at).
mig003_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL,
                        bounds = .mig003_e5_bounds()) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))

  # ---- Step 0: idempotency guard - read-only, writes nothing. ----
  marker_con <- st_connect(db, read_only = TRUE)
  marker <- tryCatch(
    DBI::dbGetQuery(
      marker_con, "SELECT applied_at FROM schema_version WHERE version = ?",
      params = list(.mig003_marker_version)
    ),
    finally = DBI::dbDisconnect(marker_con, shutdown = TRUE)
  )

  if (nrow(marker) > 0) {
    recorded_at <- marker$applied_at[[1]]
    logf("003-alias-date-bounds already applied at %s; nothing to do.", format(recorded_at))
    read_con <- st_connect(db, read_only = TRUE)
    counts <- tryCatch(
      mig003_counts_checksum(read_con),
      finally = DBI::dbDisconnect(read_con, shutdown = TRUE)
    )
    return(invisible(list(
      status = "already_migrated",
      backup_path = NA_character_,
      restore_command = NA_character_,
      counts_before = counts,
      counts_after = counts,
      recorded_at = recorded_at
    )))
  }

  # ---- dry-run: preview only, write nothing (no backup either). ----
  if (isTRUE(dry_run)) {
    preview_con <- st_connect(db, read_only = TRUE)
    counts_before <- tryCatch(
      mig003_counts_checksum(preview_con),
      finally = DBI::dbDisconnect(preview_con, shutdown = TRUE)
    )
    logf("DRY RUN: would ADD COLUMN date_start/date_end on feature_alias.")
    logf("DRY RUN: would flip every FALSE 'self' arm to auto_assign = TRUE (R1).")
    logf("DRY RUN: would apply %d itemised date bound(s) (E.5).", nrow(bounds))
    logf("DRY RUN: no backup taken, no writes made to %s.", db)
    return(invisible(list(
      status = "dry_run",
      backup_path = NA_character_,
      restore_command = NA_character_,
      counts_before = counts_before,
      counts_after = NA,
      recorded_at = NA
    )))
  }

  # ---- Step 1: back up and verify, before any write. ----
  backup_path <- mig003_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)

  recorded_at <- .mig003_default(.now, Sys.time())

  result <- with_db_write(
    function(con) {
      counts_before <- mig003_counts_checksum(con)

      # ---- One transaction for the whole migration (ALTER + R1 flip +
      # bounds + marker), via the mutation-layer's db_transaction() rather
      # than a raw SQL BEGIN/COMMIT: db_update() (called from
      # .mig003_apply_bounds()) detects an already-open mutation-layer
      # transaction via db_transaction()'s own tag and PARTICIPATES in it
      # instead of nesting a second BEGIN (DuckDB errors on that) - a raw
      # `DBI::dbExecute(con, "BEGIN TRANSACTION")` wrapper here would not
      # set that tag and would break this. Any error anywhere in the body -
      # including a `.mig003_apply_bounds()` row-identity abort - rolls back
      # EVERYTHING: the ALTER, the R1 flip, and any bounds rows already
      # applied. ----
      body <- db_transaction(con, function(con) {
        # ---- Step: additive columns only (S-15.9). ----
        DBI::dbExecute(con, "ALTER TABLE feature_alias ADD COLUMN date_start DATE")
        DBI::dbExecute(con, "ALTER TABLE feature_alias ADD COLUMN date_end DATE")

        # ---- R1: universal self-arm flip, table-wide, unconditional -
        # every feature must be reachable by its own name, regardless of
        # whether it is one of E.5's curated keys. ----
        DBI::dbExecute(
          con,
          "UPDATE feature_alias SET auto_assign = TRUE
           WHERE kind = 'self' AND auto_assign IS NOT TRUE"
        )

        # ---- E.5: itemised curated bounds. ----
        n_bounds_applied <- .mig003_apply_bounds(con, bounds)

        DBI::dbExecute(
          con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
          params = list(.mig003_marker_version, recorded_at)
        )

        # ---- hard verify gate, before COMMIT (read-your-own-writes). ----
        counts_after <- mig003_counts_checksum(con)
        mig003_verify(counts_before, counts_after)

        list(counts_after = counts_after, n_bounds_applied = n_bounds_applied)
      })

      logf(
        "Verify passed: %d bound row(s) applied; self arms flipped; other tables unchanged.",
        body$n_bounds_applied
      )

      list(counts_before = counts_before, counts_after = body$counts_after)
    },
    db = db
  )

  logf("003-alias-date-bounds migrated successfully.")

  invisible(list(
    status = "migrated",
    backup_path = backup_path,
    restore_command = restore_command,
    counts_before = result$counts_before,
    counts_after = result$counts_after,
    recorded_at = recorded_at
  ))
}
