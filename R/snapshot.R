# Plan 09 - R/snapshot.R: `snapshot_db()` / `prune_snapshots()` (R-9.4,
# DESIGN Sec9.1). Maintenance helpers, not part of the ingest pipeline itself.

#' Take a checkpointed snapshot of the live database
#'
#' Opens `db` via `with_db_write()`, runs `CHECKPOINT` to flush WAL contents
#' into the main file, then copies the file to
#' `dest_dir/monitoring_YYYY-MM-DD.duckdb.tmp` and atomically `file.rename()`s
#' it to the final dated name. A same-day re-call overwrites the existing
#' snapshot (the destination filename is date-only, so it is identical for
#' repeat calls on the same day).
#'
#' @param db path to the live DuckDB file.
#' @param dest_dir directory to write the snapshot into.
#' @return the path to the final (non-`.tmp`) snapshot file.
#' @export
snapshot_db <- function(db = st_config("live_db"), dest_dir = st_config("snapshot_dir")) {
  checkmate::assert_string(db)
  checkmate::assert_string(dest_dir)

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

  renamed <- file.rename(tmp_path, final_path)
  if (!isTRUE(renamed)) {
    cli::cli_abort(
      "Failed to finalize snapshot from {.path {tmp_path}} to {.path {final_path}}.",
      class = "sampletidy_error"
    )
  }

  final_path
}

#' Prune old dated snapshots, keeping each month's last one indefinitely
#'
#' Deletes dated `monitoring_YYYY-MM-DD.duckdb` snapshots in `dest_dir` older
#' than `keep_days`, except that the most recent snapshot within each
#' calendar month (`YYYY-MM`) is always kept, regardless of age. Files that
#' don't match the dated-snapshot naming pattern are left untouched.
#'
#' @param dest_dir directory containing dated snapshot files.
#' @param keep_days snapshots this many days old or younger are always kept.
#' @return `NULL`, invisibly.
#' @export
prune_snapshots <- function(dest_dir = st_config("snapshot_dir"), keep_days = 60) {
  checkmate::assert_string(dest_dir)
  checkmate::assert_number(keep_days, lower = 0)

  files <- list.files(dest_dir, pattern = "^monitoring_\\d{4}-\\d{2}-\\d{2}\\.duckdb$")
  if (length(files) == 0) {
    return(invisible(NULL))
  }

  dates <- as.Date(sub("^monitoring_(\\d{4}-\\d{2}-\\d{2})\\.duckdb$", "\\1", files))
  age <- as.numeric(Sys.Date() - dates)

  old_idx <- which(age > keep_days)
  if (length(old_idx) == 0) {
    return(invisible(NULL))
  }

  months <- format(dates[old_idx], "%Y-%m")
  last_per_month <- tapply(dates[old_idx], months, max)
  keep_old_dates <- as.Date(unlist(last_per_month), origin = "1970-01-01")

  to_remove <- old_idx[!dates[old_idx] %in% keep_old_dates]
  if (length(to_remove) > 0) {
    file.remove(file.path(dest_dir, files[to_remove]))
  }

  invisible(NULL)
}
