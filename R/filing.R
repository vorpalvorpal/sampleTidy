# PLAN-20 phase 1 (P20.5): external filing records. Spec:
# dev/plans/PLAN-20-phase1-spec.md section P20.5.

.af_cols <- c("uuid_asset", "system", "external_id", "external_uri", "container",
              "filed_at", "title", "comments")

.af_empty <- function() {
  tibble::tibble(uuid_asset = character(0), system = character(0),
                 external_id = character(0), external_uri = character(0),
                 container = character(0),
                 filed_at = as.POSIXct(character(0), tz = "UTC"),
                 title = character(0), comments = character(0))
}

.af_abort <- function(msg, ...) {
  cli::cli_abort(msg, class = "sampletidy_error", .envir = parent.frame())
}

.af_nonempty_string <- function(x, what) {
  if (!is.character(x) || length(x) != 1 || is.na(x) || !nzchar(x)) {
    .af_abort("{.arg {what}} must be a non-empty string.")
  }
}

.af_string_or_na <- function(x, what) {
  if (!(is.character(x) || (is.logical(x) && all(is.na(x)))) || length(x) != 1) {
    .af_abort("{.arg {what}} must be a single string or NA.")
  }
  as.character(x)
}

#' Record that an asset was filed in an external system
#'
#' Inserts, or updates, the `asset_filing` row for `(uuid_asset, system)`.
#' The core never interprets `system`. Writes go through the mutation layer
#' (`change_log` rows with `actor = "register_filing"`). Re-registering the
#' same filing writes nothing.
#'
#' @param db a path to the DuckDB file (opened read-write) or an open
#'   read-write `DBIConnection`.
#' @param uuid_asset,system,external_id non-empty strings.
#' @param external_uri,container,title,comments a string or `NA`.
#' @param filed_at `NULL` (now, on insert; keep the stored value on update) or
#'   a length-1 `POSIXct`.
#' @return `"inserted"`, `"updated"` or `"unchanged"`, invisibly.
#' @export
register_filing <- function(db = st_config("live_db"), uuid_asset, system, external_id,
                            external_uri = NA_character_, container = NA_character_,
                            filed_at = NULL, title = NA_character_,
                            comments = NA_character_) {
  .af_nonempty_string(uuid_asset, "uuid_asset")
  .af_nonempty_string(system, "system")
  .af_nonempty_string(external_id, "external_id")
  external_uri <- .af_string_or_na(external_uri, "external_uri")
  container <- .af_string_or_na(container, "container")
  title <- .af_string_or_na(title, "title")
  comments <- .af_string_or_na(comments, "comments")
  if (!is.null(filed_at) && !(inherits(filed_at, "POSIXct") && length(filed_at) == 1 &&
                              !is.na(filed_at))) {
    .af_abort("{.arg filed_at} must be NULL or a length-1 POSIXct.")
  }

  work <- function(con) {
    if (!"asset_filing" %in% DBI::dbListTables(con)) {
      .af_abort("The {.field asset_filing} table does not exist; apply operator migration 060 (dev/migrations/060-asset-filing.R).")
    }
    n_asset <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM asset WHERE uuid = ?",
                               params = list(uuid_asset))$n
    if (n_asset == 0) {
      .af_abort("No asset with uuid {.val {uuid_asset}}.")
    }
    cur <- DBI::dbGetQuery(
      con, "SELECT * FROM asset_filing WHERE uuid_asset = ? AND system = ?",
      params = list(uuid_asset, system))
    if (nrow(cur) == 0) {
      row <- data.frame(uuid_asset = uuid_asset, system = system, external_id = external_id,
                        external_uri = external_uri, container = container,
                        filed_at = if (is.null(filed_at)) Sys.time() else filed_at,
                        title = title, comments = comments, stringsAsFactors = FALSE)
      db_append(con, "asset_filing", row, actor = "register_filing",
                reason = "register_filing: new external filing")
      return("inserted")
    }
    same <- function(a, b) (is.na(a) && is.na(b)) || (!is.na(a) && !is.na(b) && identical(a, b))
    want <- list(external_id = external_id, external_uri = external_uri,
                 container = container, title = title, comments = comments)
    changes <- list()
    for (f in names(want)) {
      if (!same(as.character(cur[[f]][[1]]), want[[f]])) changes[[f]] <- want[[f]]
    }
    if (!is.null(filed_at) && !isTRUE(as.numeric(cur$filed_at[[1]]) == as.numeric(filed_at))) {
      changes$filed_at <- filed_at
    }
    if (length(changes) == 0) return("unchanged")
    db_update(con, "asset_filing", changes = changes, actor = "register_filing",
              reason = "register_filing: updated external filing",
              key = list(uuid_asset = uuid_asset, system = system))
    "updated"
  }

  res <- if (inherits(db, "DBIConnection")) work(db) else {
    checkmate::assert_string(db)
    with_db_write(work, db = db)
  }
  invisible(res)
}

#' External filing records of assets
#'
#' Read-only view of the `asset_filing` table (see [register_filing()]).
#'
#' @param db a path to the DuckDB file (opened read-only) or an open
#'   `DBIConnection` (left open).
#' @param system `NULL` (every row) or a character vector of systems to keep.
#' @return a tibble with the `asset_filing` columns, ordered by `system`,
#'   `filed_at`, `uuid_asset`; 0 rows when the table does not exist.
#' @export
filed_assets <- function(db = st_config("live_db"), system = NULL) {
  checkmate::assert_character(system, null.ok = TRUE, any.missing = FALSE)
  if (inherits(db, "DBIConnection")) {
    con <- db
  } else {
    checkmate::assert_string(db)
    con <- st_connect(db, read_only = TRUE)
    on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  }
  if (!"asset_filing" %in% DBI::dbListTables(con)) return(.af_empty())
  out <- DBI::dbGetQuery(con, sprintf(
    "SELECT %s FROM asset_filing ORDER BY system, filed_at, uuid_asset",
    paste(.af_cols, collapse = ", ")))
  if (!is.null(system)) out <- out[out$system %in% system, , drop = FALSE]
  out <- tibble::as_tibble(out)
  if (!inherits(out$filed_at, "POSIXct")) out$filed_at <- as.POSIXct(out$filed_at, tz = "UTC")
  out
}
