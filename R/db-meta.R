# PLAN-21 phase (a): the `db_meta` key/value table (ops-schema v11).
#
# A deployment records facts about the database itself here. The core knows
# two keys, `writer_generation` (an integer written as a string) and
# `writer_label`, but never writes either: snapshot_db() only reads the
# generation to name the snapshot.

.dm_check_key <- function(key) {
  if (!is.character(key) || length(key) != 1 || is.na(key)) {
    cli::cli_abort("{.arg key} must be one non-NA string.", class = "sampletidy_error")
  }
}

.dm_has_table <- function(con) "db_meta" %in% DBI::dbListTables(con)

#' Read, write and list the database's own metadata
#'
#' `db_meta` is a key/value table (ops-schema version 11) holding facts about
#' the database itself. The core knows the keys `writer_generation` (an
#' integer written as a string; [snapshot_db()] puts it in the snapshot name)
#' and `writer_label`, but never writes them: a deployment does.
#'
#' - `db_meta_get()` returns the value of `key` as one string, or
#'   `NA_character_` if the key or the table is absent. It creates nothing,
#'   so it works on a read-only connection.
#' - `db_meta_set()` inserts or replaces one key, storing `as.character(value)`
#'   and setting `updated_at`. On a database without the table it runs
#'   [ensure_schema()] first. Inside an open mutation-layer transaction it
#'   joins it, so it commits or rolls back with the caller.
#' - `db_meta_read()` opens the database file `db` read-only and returns every
#'   key. It aborts if the file does not exist, and never creates one.
#'
#' @param con an open DBI connection (read-write for `db_meta_set()`).
#' @param key one non-NA string.
#' @param value one non-NA scalar (character, number or logical).
#' @param db path to an existing DuckDB file.
#' @return `db_meta_get()`: a string or `NA_character_`. `db_meta_set()`:
#'   `value`, invisibly. `db_meta_read()`: a named character vector, empty if
#'   the table is absent or empty.
#' @export
db_meta_get <- function(con, key) {
  .dm_check_key(key)
  if (!.dm_has_table(con)) return(NA_character_)
  v <- DBI::dbGetQuery(con, "SELECT value FROM db_meta WHERE key = ?",
                       params = list(key))$value
  if (length(v) == 0) NA_character_ else as.character(v[[1]])
}

#' @rdname db_meta_get
#' @export
db_meta_set <- function(con, key, value) {
  .dm_check_key(key)
  if (!is.atomic(value) || length(value) != 1 || is.na(value)) {
    cli::cli_abort("{.arg value} must be one non-NA scalar.", class = "sampletidy_error")
  }
  if (!.dm_has_table(con)) ensure_schema(con)
  db_transaction(con, function(con) {
    DBI::dbExecute(
      con,
      "INSERT INTO db_meta (key, value, updated_at) VALUES (?, ?, ?)
       ON CONFLICT (key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at",
      params = list(key, as.character(value), Sys.time())
    )
  })
  invisible(value)
}

#' @rdname db_meta_get
#' @export
db_meta_read <- function(db) {
  checkmate::assert_string(db)
  con <- st_connect(db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  .dm_read_con(con)
}

# Every db_meta key of an open connection, as a named character vector.
.dm_read_con <- function(con) {
  if (!.dm_has_table(con)) return(stats::setNames(character(0), character(0)))
  rows <- DBI::dbGetQuery(con, "SELECT key, value FROM db_meta ORDER BY key")
  stats::setNames(as.character(rows$value), as.character(rows$key))
}
