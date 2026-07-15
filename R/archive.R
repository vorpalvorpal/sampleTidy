# Plan 09 - R/archive.R: `archive_file()` (R-9.3, A1, A13).
#
# Copies a single source file into the archive directory under a fresh asset
# uuid (no extension - matches the existing `processed/` convention) and
# writes the corresponding `asset` row via the mutation layer (A32: no raw
# table-write calls in this file). Dedupes on content hash: a file whose hash
# already has an asset row is not copied or inserted again - the existing
# uuid is reused. The source file is never touched (no move/delete here).

#' Archive one ingested source file as an `asset` row
#'
#' Resolves the event's project via `event$work_order` (`SELECT uuid FROM
#' project WHERE name = <work_order>`), copies `path` to
#' `file.path(st_config("archive_dir"), <new asset uuid>)` (extensionless),
#' and inserts the `asset` row through `db_append()`. If an `asset` row with
#' the same `hash` already exists, the copy and insert are both skipped and
#' the existing row's uuid is returned instead.
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
  dest <- file.path(st_config("archive_dir"), new_uuid)
  file.copy(path, dest)

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
