# Plan 09 - R/snapshot.R: `snapshot_db()` / `prune_snapshots()` (R-9.4,
# DESIGN Sec9.1). Maintenance helpers, not part of the ingest pipeline itself.

#' Take a checkpointed snapshot of the live database
#'
#' Opens `db` via `with_db_write()`, runs `CHECKPOINT` to flush WAL contents
#' into the main file, then copies the file to
#' `dest_dir/monitoring_YYYY-MM-DD.duckdb.tmp`, verifies the copy actually
#' contains tables, and only then atomically `file.rename()`s it to the final
#' dated name. A same-day re-call overwrites the existing snapshot (the
#' destination filename is date-only, so it is identical for repeat calls on
#' the same day).
#'
#' Two refusal layers guard against a good snapshot being replaced by a
#' worthless one:
#'
#' - **`db` must already exist.** `with_db_write()` opens read-write, and
#'   DuckDB silently *creates* a missing file on connect - so a mistyped `db`
#'   path used to conjure a brand-new, empty database, checkpoint it (trivially
#'   valid), and copy it over the dated snapshot the operator actually wanted,
#'   with no error. A snapshot of a database that did not exist a moment ago
#'   is never what anyone meant, so this is refused outright before any
#'   connection is opened.
#' - **The copy is verified before it replaces anything.** After copying to
#'   `tmp_path`, the copy is opened read-only and checked for at least one
#'   table. Because the *existing* dated snapshot is only ever touched by the
#'   final `file.rename()`, a degenerate or truncated copy is deleted in place
#'   and the function aborts - the good snapshot on disk is never overwritten
#'   with it. This also covers an interrupted copy: `file.rename()` only runs
#'   after `file.copy()` reports success AND the copy passes verification, so
#'   a copy that dies partway (returns `FALSE`, or leaves a truncated/
#'   unreadable file) is caught before touching `final_path`.
#'
#' @param db path to the live DuckDB file.
#' @param dest_dir directory to write the snapshot into.
#' @return the path to the final (non-`.tmp`) snapshot file.
#' @export
snapshot_db <- function(db = st_config("live_db"), dest_dir = st_config("snapshot_dir")) {
  checkmate::assert_string(db)
  checkmate::assert_string(dest_dir)

  if (!fs::file_exists(db)) {
    cli::cli_abort(
      paste0(
        "snapshot_db(): source database {.path {db}} does not exist. Opening ",
        "it read-write would silently CREATE an empty database and snapshot ",
        "that instead - refusing rather than overwrite an existing snapshot ",
        "with one that was never real. Check {.arg db} for a typo."
      ),
      class = "sampletidy_error"
    )
  }

  final_name <- sprintf("monitoring_%s.duckdb", format(Sys.Date(), "%Y-%m-%d"))
  final_path <- file.path(dest_dir, final_name)
  tmp_path <- paste0(final_path, ".tmp")

  with_db_write(
    function(con) {
      DBI::dbExecute(con, "CHECKPOINT")
      copied <- file.copy(db, tmp_path, overwrite = TRUE)
      if (!isTRUE(copied)) {
        cli::cli_abort(
          "Failed to snapshot {.path {db}} to {.path {tmp_path}}.",
          class = "sampletidy_error"
        )
      }
    },
    db = db
  )

  # Verify the copy before it can ever replace an existing, presumably-good
  # snapshot at `final_path`. A copy that is unreadable or has zero tables
  # (e.g. `db` existed but held an empty/degenerate database) is deleted here,
  # never renamed into place.
  verify_con <- tryCatch(
    DBI::dbConnect(duckdb::duckdb(), tmp_path, read_only = TRUE),
    error = function(e) e
  )
  if (inherits(verify_con, "error")) {
    unlink(tmp_path)
    cli::cli_abort(
      paste0(
        "snapshot_db(): the copy at {.path {tmp_path}} could not be opened ",
        "as a database ({conditionMessage(verify_con)}); refusing to finalize ",
        "it over {.path {final_path}}."
      ),
      class = "sampletidy_error"
    )
  }
  tables <- DBI::dbListTables(verify_con)
  DBI::dbDisconnect(verify_con, shutdown = TRUE)
  if (length(tables) == 0) {
    unlink(tmp_path)
    cli::cli_abort(
      paste0(
        "snapshot_db(): the copy of {.path {db}} has zero tables; refusing ",
        "to finalize it over the existing snapshot at {.path {final_path}}."
      ),
      class = "sampletidy_error"
    )
  }

  renamed <- file.rename(tmp_path, final_path)
  if (!isTRUE(renamed)) {
    cli::cli_abort(
      "Failed to finalize snapshot from {.path {tmp_path}} to {.path {final_path}}.",
      class = "sampletidy_error"
    )
  }

  final_path
}

#' Prune old dated snapshots, thinning them by day, then week, then month
#'
#' Thins dated `monitoring_YYYY-MM-DD.duckdb` snapshots in `dest_dir`. Files
#' that don't match the dated-snapshot naming pattern are left untouched.
#'
#' Retention (age is today's date minus the file's date): every snapshot up to
#' `keep_days` old is kept; from there up to `keep_days + 7 * keep_weeks` days
#' old, only the newest snapshot of each ISO week (`%G-W%V`) is kept; older
#' than that, only the newest snapshot of each calendar month, indefinitely.
#' Each week or month is judged among that age zone's files only.
#' [ingest_dir()] calls this after each snapshot it takes.
#'
#' @param dest_dir directory containing dated snapshot files.
#' @param keep_days snapshots this many days old or younger are all kept.
#' @param keep_weeks number of weeks beyond `keep_days` during which one
#'   snapshot per ISO week is kept.
#' @return `NULL`, invisibly.
#' @export
prune_snapshots <- function(dest_dir = st_config("snapshot_dir"),
                            keep_days = 7, keep_weeks = 8) {
  checkmate::assert_string(dest_dir)
  checkmate::assert_number(keep_days, lower = 0)
  checkmate::assert_number(keep_weeks, lower = 0)

  files <- list.files(dest_dir, pattern = "^monitoring_\\d{4}-\\d{2}-\\d{2}\\.duckdb$")
  if (length(files) == 0) {
    return(invisible(NULL))
  }

  dates <- as.Date(sub("^monitoring_(\\d{4}-\\d{2}-\\d{2})\\.duckdb$", "\\1", files))
  age <- as.numeric(Sys.Date() - dates)

  weekly <- age > keep_days & age <= keep_days + 7 * keep_weeks
  monthly <- age > keep_days + 7 * keep_weeks

  # Keep the newest file per group; non-members of a zone get NA group.
  newest_per <- function(zone, group) {
    idx <- which(zone)
    keep <- tapply(idx, group[idx], function(i) i[which.max(dates[i])])
    as.integer(unlist(keep))
  }
  keep <- c(
    which(age <= keep_days),
    newest_per(weekly, format(dates, "%G-W%V")),
    newest_per(monthly, format(dates, "%Y-%m"))
  )

  to_remove <- setdiff(seq_along(files), keep)
  if (length(to_remove) > 0) {
    file.remove(file.path(dest_dir, files[to_remove]))
  }

  invisible(NULL)
}
