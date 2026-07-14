# Plan 01 - R-1.3 with_db_write() and R-1.4 st_connect().

#' Open a DBI connection to the sampleTidy DuckDB file
#'
#' Thin wrapper around `DBI::dbConnect(duckdb::duckdb(), ...)`. Read-only
#' connections abort if the file does not exist (DuckDB would otherwise
#' silently create it); read-write connections create the file if absent.
#'
#' @param db path to the DuckDB file.
#' @param read_only if `TRUE` (default), open read-only.
#' @return an open DBI connection; caller is responsible for disconnecting.
#' @export
st_connect <- function(db, read_only = TRUE) {
  checkmate::assert_string(db)
  checkmate::assert_flag(read_only)

  if (read_only && !fs::file_exists(db)) {
    cli::cli_abort(
      "Cannot open database read-only: {.path {db}} does not exist.",
      class = "sampletidy_error"
    )
  }

  tryCatch(
    DBI::dbConnect(duckdb::duckdb(), db, read_only = read_only),
    error = function(e) {
      cli::cli_abort(
        "Failed to connect to database at {.path {db}}: {conditionMessage(e)}",
        class = "sampletidy_error",
        parent = e
      )
    }
  )
}

#' Run a function against a read-write DuckDB connection, retrying on lock
#'
#' Opens a read-write connection to `db`, retrying every `every` seconds (up
#' to `max_wait` seconds total) while the connect error looks like a lock
#' conflict. A non-lock connect error (e.g. a bad path) aborts immediately.
#' The connection is always closed on exit, whether `fn` succeeds or throws.
#' Reference implementation: DESIGN.md §9.2.
#'
#' @param fn function of one argument (the connection); its return value is
#'   returned by `with_db_write()`.
#' @param db path to the DuckDB file to open read-write.
#' @param max_wait maximum total seconds to retry a busy lock before aborting.
#' @param every seconds to sleep between retries.
#' @return `fn(con)`'s return value.
#' @export
with_db_write <- function(fn, db = st_config("live_db"), max_wait = 60, every = 2) {
  checkmate::assert_function(fn)
  checkmate::assert_string(db)
  checkmate::assert_number(max_wait, lower = 0)
  checkmate::assert_number(every, lower = 0)

  waited <- 0
  last_err <- NULL

  repeat {
    con <- tryCatch(
      DBI::dbConnect(duckdb::duckdb(), db, read_only = FALSE),
      error = function(e) {
        last_err <<- e
        NULL
      }
    )
    if (!is.null(con)) {
      break
    }

    if (!grepl("lock", conditionMessage(last_err), ignore.case = TRUE)) {
      cli::cli_abort(
        "Failed to connect to database at {.path {db}}: {conditionMessage(last_err)}",
        class = "sampletidy_error",
        parent = last_err
      )
    }

    if (waited >= max_wait) {
      cli::cli_abort(
        "DB busy after {max_wait}s: {conditionMessage(last_err)}",
        class = "sampletidy_error",
        parent = last_err
      )
    }

    Sys.sleep(every)
    waited <- waited + every
  }

  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  fn(con)
}
