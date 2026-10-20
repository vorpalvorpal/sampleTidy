# PLAN-20 phase 1 (P20.4): completed_work(). Spec:
# dev/plans/PLAN-20-phase1-spec.md section P20.4.

.cw_asset_cols <- c("uuid", "path", "filename", "hash", "file_format", "type")

.cw_empty_assets <- function() {
  tibble::tibble(uuid = character(0), path = character(0), filename = character(0),
                 hash = character(0), file_format = character(0), type = character(0))
}

# `since` as a UTC SQL timestamp literal, or NULL.
.cw_since_literal <- function(since) {
  if (is.null(since)) return(NULL)
  ok <- length(since) == 1 && !is.na(since) && (inherits(since, "POSIXct") || inherits(since, "Date"))
  if (!ok) {
    cli::cli_abort("{.arg since} must be NULL or a length-1 Date or POSIXct.",
                   class = "sampletidy_error")
  }
  if (inherits(since, "Date")) {
    return(sprintf("TIMESTAMP '%s 00:00:00'", format(since, "%Y-%m-%d")))
  }
  sprintf("TIMESTAMP '%s'", format(since, "%Y-%m-%d %H:%M:%OS6", tz = "UTC"))
}

# review_queue column as SQL: the column itself, or a typed NULL when this DB's
# review_queue predates it.
.cw_col <- function(have, col) if (col %in% have) col else sprintf("CAST(NULL AS VARCHAR) AS %s", col)

#' Projects whose work is complete
#'
#' A project is complete when it has at least one `sample` row and no
#' blocking open review item references it. An open review item is blocking
#' unless its `kind` or `subkind` is `self_precedence_note`. An item references
#' a project through its work order, any of its uuid columns, its
#' `source_hash` (via the project's assets, `ingest_file` rows and the
#' change log of its samples and analyses), or its `payload` text. Read-only.
#'
#' @param db a path to the DuckDB file (opened read-only) or an open
#'   `DBIConnection` (used as is, left open).
#' @param since `NULL` (every complete project) or a length-1 `Date` (midnight
#'   UTC) or `POSIXct`: keep projects with `COALESCE(date_end, date_start) >=
#'   since`.
#' @return a tibble, one row per complete project ordered by `date_start`,
#'   `name`, `uuid`: `uuid`, `name`, `type`, `site`, `date_start`, `date_end`,
#'   `uuid_root`, `root_name` and a list-column `assets` of per-project tibbles
#'   (`uuid`, `path`, `filename`, `hash`, `file_format`, `type`; `path` is
#'   relative to `st_config("archive_dir")`).
#' @export
completed_work <- function(db = st_config("live_db"), since = NULL) {
  since_sql <- .cw_since_literal(since)
  if (inherits(db, "DBIConnection")) {
    con <- db
  } else {
    checkmate::assert_string(db)
    con <- st_connect(db, read_only = TRUE)
    on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  }

  have <- DBI::dbListFields(con, "review_queue")
  rq <- paste(
    c("uuid", .cw_col(have, "kind"), .cw_col(have, "subkind"), .cw_col(have, "work_order"),
      .cw_col(have, "source_hash"), .cw_col(have, "payload"), .cw_col(have, "status"),
      .cw_col(have, "uuid_target"), .cw_col(have, "uuid_existing"),
      .cw_col(have, "uuid_incoming"), .cw_col(have, "uuid_alias")),
    collapse = ", ")

  sql <- sprintf("
    WITH rq AS (SELECT %s FROM review_queue),
    oi AS (
      SELECT * FROM rq
       WHERE COALESCE(status, 'open') = 'open'
         AND COALESCE(kind, '') <> 'self_precedence_note'
         AND COALESCE(subkind, '') <> 'self_precedence_note'
    ),
    core_ids AS (
      SELECT uuid AS pid, uuid AS id FROM project
      UNION ALL SELECT uuid_project, uuid FROM \"sample\" WHERE uuid_project IS NOT NULL
      UNION ALL SELECT uuid_project, uuid FROM asset WHERE uuid_project IS NOT NULL
    ),
    all_ids AS (
      SELECT pid, id FROM core_ids
      UNION ALL
      SELECT s.uuid_project, a.uuid FROM analysis a JOIN \"sample\" s ON a.uuid_sample = s.uuid
       WHERE s.uuid_project IS NOT NULL
    ),
    hashes AS (
      SELECT uuid_project AS pid, hash FROM asset WHERE hash IS NOT NULL AND uuid_project IS NOT NULL
      UNION ALL
      SELECT a.uuid_project, i.hash FROM ingest_file i JOIN asset a ON i.uuid_asset = a.uuid
       WHERE a.uuid_project IS NOT NULL
      UNION ALL
      SELECT p.uuid, i.hash FROM ingest_file i JOIN project p ON i.work_order = p.name
      UNION ALL
      SELECT s.uuid_project, c.source_hash FROM change_log c JOIN \"sample\" s ON c.uuid_row = s.uuid
       WHERE c.tbl = 'sample' AND c.source_hash IS NOT NULL AND s.uuid_project IS NOT NULL
      UNION ALL
      SELECT s.uuid_project, c.source_hash FROM change_log c
        JOIN analysis a ON c.uuid_row = a.uuid JOIN \"sample\" s ON a.uuid_sample = s.uuid
       WHERE c.tbl = 'analysis' AND c.source_hash IS NOT NULL AND s.uuid_project IS NOT NULL
    ),
    tokens AS (
      SELECT uuid AS pid, '\"' || name || '\"' AS tok FROM project WHERE name IS NOT NULL
      UNION ALL SELECT pid, id FROM core_ids
    ),
    blocked AS (
      SELECT p.uuid AS pid FROM oi JOIN project p ON oi.work_order = p.name
      UNION SELECT i.pid FROM oi JOIN all_ids i ON oi.uuid_target = i.id
      UNION SELECT i.pid FROM oi JOIN all_ids i ON oi.uuid_existing = i.id
      UNION SELECT i.pid FROM oi JOIN all_ids i ON oi.uuid_incoming = i.id
      UNION SELECT i.pid FROM oi JOIN all_ids i ON oi.uuid_alias = i.id
      UNION SELECT h.pid FROM oi JOIN hashes h ON oi.source_hash = h.hash
      UNION SELECT t.pid FROM (SELECT payload FROM oi WHERE payload IS NOT NULL) x
              JOIN tokens t ON contains(x.payload, t.tok)
    )
    SELECT p.uuid, p.name, p.type, p.site, p.date_start, p.date_end,
           COALESCE(p.uuid_root, p.uuid) AS uuid_root, r.name AS root_name
      FROM project p
      LEFT JOIN project r ON r.uuid = COALESCE(p.uuid_root, p.uuid)
     WHERE EXISTS (SELECT 1 FROM \"sample\" s WHERE s.uuid_project = p.uuid)
       AND NOT EXISTS (SELECT 1 FROM blocked b WHERE b.pid = p.uuid)
       %s
     ORDER BY p.date_start ASC NULLS LAST, p.name ASC NULLS LAST, p.uuid ASC",
    rq,
    if (is.null(since_sql)) "" else
      sprintf("AND COALESCE(p.date_end, p.date_start) >= %s", since_sql))

  out <- tibble::as_tibble(DBI::dbGetQuery(con, sql))
  for (col in c("uuid", "name", "type", "site", "uuid_root", "root_name")) {
    out[[col]] <- as.character(out[[col]])
  }
  for (col in c("date_start", "date_end")) {
    if (!inherits(out[[col]], "POSIXct")) {
      out[[col]] <- as.POSIXct(out[[col]], tz = "UTC")
    }
  }

  assets <- DBI::dbGetQuery(con, "
    SELECT uuid_project, uuid, filename, hash, file_format, type FROM asset
     WHERE uuid_project IS NOT NULL
     ORDER BY filename ASC NULLS LAST, uuid ASC")
  assets <- assets[assets$uuid_project %in% out$uuid, , drop = FALSE]
  by_project <- split(assets, factor(assets$uuid_project, levels = out$uuid))
  out$assets <- lapply(out$uuid, function(u) {
    a <- by_project[[u]]
    if (is.null(a) || nrow(a) == 0) return(.cw_empty_assets())
    tibble::tibble(
      uuid = as.character(a$uuid),
      path = ifelse(is.na(a$filename), NA_character_, paste0(a$uuid, "/", a$filename)),
      filename = as.character(a$filename),
      hash = as.character(a$hash),
      file_format = as.character(a$file_format),
      type = as.character(a$type))
  })
  out
}
