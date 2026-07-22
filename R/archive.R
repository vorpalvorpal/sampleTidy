# Plan 09/12 - R/archive.R: `archive_file()` (R-9.3, R-12.4, R-12.17, A1,
# A13, A70, F10).
#
# Copies a single source file into a directory-per-asset layout under the
# archive directory (`<archive_dir>/<new asset uuid>/<original filename>`,
# A70) and writes the corresponding `asset` row via the mutation layer (A32:
# no raw table-write calls in this file). Dedupes on content hash: a file
# whose hash already has an asset row is not copied or inserted again - the
# existing uuid is reused. The source file is never touched (no move/delete
# here). The directory-create and copy are both checked (R-12.4/F10): a
# failure aborts `sampletidy_error` before the `asset` row is inserted, so
# the surrounding commit transaction rolls back rather than "succeeding"
# with a missing archive copy.

#' Archive one ingested source file as an `asset` row
#'
#' Resolves the event's project via `event$work_order` (`SELECT uuid FROM
#' project WHERE name = <work_order>`), copies `path` to
#' `file.path(st_config("archive_dir"), <new asset uuid>, basename(path))`
#' (directory-per-asset, A70), and inserts the `asset` row through
#' `db_append()`. If an `asset` row with the same `hash` already exists, the
#' copy and insert are both skipped and the existing row's uuid is returned
#' instead. If the per-asset directory cannot be created or the copy fails,
#' aborts `sampletidy_error` (R-12.4) before inserting the `asset` row.
#'
#' `con` is passed straight through to `db_append()` so this participates in
#' the caller's open mutation-layer transaction (`commit_event()` calls this
#' from inside one `db_transaction()`); no transaction is opened here.
#'
#' @param con an open read-write DBI connection.
#' @param path path to the source file to archive.
#' @param hash the file's SHA-256 content hash (R-1.2 `hash_file()`).
#' @param event minimally `list(work_order = <work order id>)`.
#' @return the asset row's uuid (new or reused), visibly.
#' @keywords internal
#' @noRd
archive_file <- function(con, path, hash, event) {
  checkmate::assert_string(path)
  checkmate::assert_string(hash)

  existing <- DBI::dbGetQuery(
    con,
    "SELECT uuid FROM asset WHERE hash = ?",
    params = list(hash)
  )
  if (nrow(existing) > 0) {
    return(existing$uuid[[1]])
  }

  project_row <- DBI::dbGetQuery(
    con,
    "SELECT uuid FROM project WHERE name = ?",
    params = list(event$work_order)
  )
  uuid_project <- if (nrow(project_row) > 0) project_row$uuid[[1]] else NA_character_

  new_uuid <- uuid::UUIDgenerate()
  archive_dir <- st_config("archive_dir")
  uuid_dir <- file.path(archive_dir, new_uuid)
  # recursive = FALSE deliberately: this only ever creates the one new
  # per-asset uuid directory. If `archive_dir` itself does not already
  # exist, dir.create() fails (returns FALSE) rather than silently
  # creating it - a missing archive_dir is a real misconfiguration (R-12.4)
  # and must abort, not be papered over.
  dir_created <- dir.create(uuid_dir, recursive = FALSE, showWarnings = FALSE)
  dest <- file.path(uuid_dir, basename(path))
  copied <- isTRUE(dir_created) && isTRUE(file.copy(path, dest))
  if (!copied) {
    cli::cli_abort(
      "Failed to archive source file {.path {path}} to {.path {dest}}.",
      class = "sampletidy_error"
    )
  }

  row <- tibble::tibble(
    uuid = new_uuid,
    name = NA_character_,
    date = as.POSIXct(NA),
    file_format = tools::file_ext(path),
    type = "Chemical analysis",
    purpose = NA_character_,
    organisation = NA_character_,
    person = NA_character_,
    uuid_project = uuid_project,
    uuid_feature = NA_character_,
    filename = basename(path),
    hash = hash,
    comments = NA_character_
  )

  db_append(con, "asset", row, actor = "ingest", reason = "archive source file", source_hash = hash)

  new_uuid
}
