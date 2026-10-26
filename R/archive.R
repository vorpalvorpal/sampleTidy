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
# with a missing archive copy. A failed copy also removes the per-asset
# directory just created. Inside a `db_transaction()` the new directory is
# registered (`.st_on_rollback()`, R/mutate.R) so a rollback unlinks it too -
# otherwise an aborted commit leaves an orphan directory with no asset row and
# a retry copies the file again under a new uuid. Commit keeps it; the
# dedupe-reuse path creates nothing so a rollback never touches an existing
# directory; cleanup errors are swallowed so the original error propagates.

# Seam for tests: the single place the file copy happens.
#' @keywords internal
#' @noRd
.ar_copy_file <- function(from, to) {
  isTRUE(file.copy(from, to))
}

#' Archive one ingested source file as an `asset` row
#'
#' Resolves the event's project via `event$work_order` (`.ct_ensure_project()`,
#' R/commit.R - find-or-create, so an orphan (NA) work order and a genuinely
#' new one both resolve to a real project row rather than `NA`), or, when the
#' event carries an ACIRL report number, via that report's own project row
#' (R-9.14/A80 - see the call site), copies
#' `path` to
#' `file.path(st_config("archive_dir"), <new asset uuid>, basename(path))`
#' (directory-per-asset, A70), and inserts the `asset` row through
#' `db_append()`. If an `asset` row already holds these bytes - found through
#' the `ingest_file` row's `uuid_asset` for `hash`, else by `asset.hash` - the
#' copy and insert are both skipped and the existing row's uuid is returned
#' instead. Both paths record the link in `ingest_file.uuid_asset` (when an
#' `ingest_file` row exists for `hash`), since `asset.hash` is the stored
#' copy's settled hash and may stop matching the as-received one
#' ([archive_settle()]). If the per-asset directory cannot be created or the copy fails,
#' aborts `sampletidy_error` (R-12.4) before inserting the `asset` row.
#'
#' `con` is passed straight through to `db_append()` so this participates in
#' the caller's open mutation-layer transaction (`commit_event()` calls this
#' from inside one `db_transaction()`); no transaction is opened here.
#'
#' Round-2 audit item 6: `type` is now an explicit argument, default
#' `"Chemical analysis"` (unchanged default behaviour for every existing
#' caller/test - `.ct_archive_files()`, R/commit.R, archives the event's own
#' tabular deliverables and never passes `type`). PLAN-15 F.17 pins that a
#' retained non-tabular sibling is "evidence, not `Chemical analysis` data";
#' `.ig_retain_siblings()` (R/ingest.R) is the one caller that passes a
#' non-default `type`.
#'
#' That "do NOT widen `Certificate of analysis` without a separate ruling"
#' note used to end here. The ruling exists: R-15.36b (PLAN-15) maps each
#' retained deliverable kind to its own `asset.type` - `_COA` ->
#' `"Certificate of analysis"`, `_QC`/`_QCI` -> `"QC"`, `_COC` -> `"QA"`,
#' `_XTAB` and an ACIRL-shaped report -> `"Chemical analysis"` - and
#' `.ig_retained_asset_type()` is the single place that decides it. Widen
#' nothing here; change the lookup table there.
#'
#' @param con an open read-write DBI connection.
#' @param path path to the source file to archive.
#' @param hash the file's xxHash128 content hash (R-1.2 `hash_file()`).
#' @param event minimally `list(work_order = <work order id>)`.
#' @param type `asset.type` for a NEWLY-inserted row (ignored on the
#'   dedup-reuse path, since an existing row's `type` is never overwritten).
#'   Default `"Chemical analysis"`.
#' @return the asset row's uuid (new or reused), visibly.
#' @keywords internal
#' @noRd
archive_file <- function(con, path, hash, event, type = "Chemical analysis") {
  checkmate::assert_string(path)
  checkmate::assert_string(hash)
  checkmate::assert_string(type)

  # Dedup on the AS-RECEIVED hash: `ingest_file.uuid_asset` first (an asset
  # whose stored copy was settled to a new hash by `archive_settle()` no
  # longer matches on `asset.hash`), then `asset.hash` (legacy rows, and a
  # file whose bytes equal a settled copy's). The reuse path links the
  # `ingest_file` row too, so the next lookup finds it the first way.
  existing <- .ar_asset_for_hash(con, hash)
  if (nrow(existing) > 0) {
    ingest_file_set_uuid_asset(con, hash, existing$uuid[[1]], size = .ar_file_size(path))
    return(existing$uuid[[1]])
  }

  # `.ct_ensure_project()` (R/commit.R) is the ONE place that resolves a
  # work_order to its project row, orphan (NA) work_order included - reused
  # here rather than duplicated, which is how this lookup and that one first
  # drifted apart (a plain `WHERE name = ?` here never matched an orphan's
  # `name IS NULL` project row, so every orphan asset landed with
  # `uuid_project = NA` even once `.ct_ensure_project()`'s own orphan branch
  # started minting a real anonymous row for it - `name = ?` bound to NA is
  # never TRUE in SQL's three-valued logic, for ANY row).
  #
  # Also find-OR-CREATE, not find-only: `commit_event()`'s blocked-event
  # branch calls `.ct_archive_files()` (hence this) BEFORE it ever calls
  # `.ct_ensure_project()` (that call sits on the non-blocked path only), so
  # a still-orphaned event's very first archive can run before any project
  # row exists at all. Delegating the create half here too means the shared
  # anonymous project row exists by the time it is needed either way,
  # instead of only on a later, non-blocked retry.
  #
  # R-9.14/A80: an ACIRL workbook HAS no work order (its header carries a
  # report number, and `2400-*` is never parsed from a filename), so the line
  # above would file every ACIRL asset under the shared anonymous orphan
  # project. Its real home is the ACIRL report project - the asset IS that
  # report, not a lab job - so an event carrying a report number resolves to it
  # instead. Only the report row is find-or-created here; the child ALS work
  # orders are NOT re-parented from this path, because `.ct_archive_files()`
  # also runs on `commit_event()`'s BLOCKED branch and a blocked event must not
  # rewrite the parent of a project row it never committed to.
  # `.ct_ensure_report_project()` fills an empty parent only, so a report row
  # minted here and completed by the later real commit is the same row.
  # C8/D14: it is handed the same year set and gas campaign/type as
  # `.ct_ensure_project_tree()`, so both resolve one (report number, year) key
  # to one row - a reused number's "(yyyy)" row included.
  report_no <- .ct_event_report_no(event)
  uuid_project <- if (is.na(report_no)) {
    .ct_ensure_project(con, event$work_order, "archive source file")
  } else {
    gas <- .ct_event_is_gas(event)
    .ct_ensure_report_project(
      con, report_no, .ct_event_als_work_orders(event), "archive source file",
      campaign = if (gas) "Monthly gas monitoring" else NA_character_,
      type = if (gas) "Monthly gas monitoring" else "ACIRL report",
      years = .ct_event_report_years(event)
    )$uuid
  }

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
  copied <- isTRUE(dir_created) && .ar_copy_file(path, dest)
  if (isTRUE(dir_created)) {
    if (copied) {
      .st_on_rollback(con, function() unlink(uuid_dir, recursive = TRUE))
    } else {
      unlink(uuid_dir, recursive = TRUE)
    }
  }
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
    type = type,
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
  ingest_file_set_uuid_asset(con, hash, new_uuid, size = .ar_file_size(path))

  new_uuid
}

# ---- archive settling ------------------------------------------------------
#
# Some file stores change a file after it has been archived. SharePoint, for
# one, rewrites an embedded metadata block inside old-format Office files
# (.xls/.doc/.ppt) some seconds or hours after upload: same size, same
# content, different bytes - so `asset.hash` stops matching the stored copy.
# The design:
#
#   * `asset.hash` is the STORED file's current, settled hash.
#   * `ingest_file(hash, uuid_asset)` is the as-received lookup. Every
#     consumer that starts from a received file's hash resolves its asset
#     through `uuid_asset` first and falls back to `asset.hash`
#     (`.ar_asset_for_hash()`). De-duplication stays on the as-received hash:
#     a rewritten hash is not a content identity (a later rewrite changes it
#     again).
#   * `archive_settle()` re-hashes recently archived copies of configured
#     extensions and accepts a same-size rewrite into `asset.hash`, with a
#     `change_log` row keeping the old hash.
#   * The inbox source of a configured extension is kept for `hold_secs`
#     after archiving, so a rewrite has time to land before the source goes.

.ar_settle_fields <- c("ext", "hold_secs", "window_hours", "accept")

#' The validated `archive_settle` configuration, or `NULL` when it is off
#'
#' Reads `st_config("archive_settle")`. `NULL` (the default) is off. A list
#' turns it on; missing fields take their defaults (`ext = c("xls", "doc",
#' "ppt")`, `hold_secs = 900`, `window_hours = 72`, no `accept`). Anything
#' else - a non-list, an unknown field, a bad field value - aborts
#' `sampletidy_error`. `ext` is returned lower-cased without a leading dot.
#' @keywords internal
#' @noRd
.ar_settle_config <- function() {
  cfg <- st_config("archive_settle")
  if (is.null(cfg)) {
    return(NULL)
  }
  bad <- function(msg) {
    cli::cli_abort(
      c("Invalid {.code st_config(\"archive_settle\")}.", x = msg,
        i = "Use {.code NULL} (off) or a list with fields {.field {(.ar_settle_fields)}}."),
      class = "sampletidy_error", .envir = parent.frame()
    )
  }
  if (!is.list(cfg) || is.data.frame(cfg)) {
    bad("It must be a list, not {.cls {class(cfg)}}.")
  }
  nms <- names(cfg)
  if (length(cfg) > 0 && (is.null(nms) || any(is.na(nms) | !nzchar(nms)) || anyDuplicated(nms))) {
    bad("Every field must be named, once.")
  }
  unknown <- setdiff(nms, .ar_settle_fields)
  if (length(unknown) > 0) {
    bad("Unknown field{?s} {.field {unknown}}.")
  }

  ext <- if (is.null(cfg$ext)) c("xls", "doc", "ppt") else cfg$ext
  if (!is.character(ext) || length(ext) == 0 || anyNA(ext) ||
      !all(nzchar(sub("^\\.", "", ext)))) {
    bad("{.field ext} must be a non-empty character vector of extensions with no NA.")
  }
  num_ok <- function(x, lower, strict) {
    is.numeric(x) && length(x) == 1 && !is.na(x) && is.finite(x) &&
      (if (strict) x > lower else x >= lower)
  }
  hold <- if (is.null(cfg$hold_secs)) 900 else cfg$hold_secs
  if (!num_ok(hold, 0, strict = FALSE)) {
    bad("{.field hold_secs} must be one non-negative number.")
  }
  window <- if (is.null(cfg$window_hours)) 72 else cfg$window_hours
  if (!num_ok(window, 0, strict = TRUE)) {
    bad("{.field window_hours} must be one positive number.")
  }
  if (!is.null(cfg$accept) && !is.function(cfg$accept)) {
    bad("{.field accept} must be a function {.code function(path, old_hash, asset)}.")
  }

  list(
    ext = unique(tolower(sub("^\\.", "", ext))),
    hold_secs = as.numeric(hold),
    window_hours = as.numeric(window),
    accept = cfg$accept
  )
}

#' Does `filename` carry one of the configured settle extensions?
#' @keywords internal
#' @noRd
.ar_settle_ext_match <- function(filename, cfg) {
  !is.null(cfg) & !is.na(filename) & tolower(tools::file_ext(filename)) %in% cfg$ext
}

#' Size of a file in bytes, `NA` when it cannot be read
#' @keywords internal
#' @noRd
.ar_file_size <- function(path) {
  out <- suppressWarnings(file.size(path))
  if (length(out) != 1) NA_real_ else as.numeric(out)
}

#' The `asset` row(s) holding a received file's bytes
#'
#' Resolves the as-received `hash` through `ingest_file.uuid_asset` first,
#' then falls back to `asset.hash` (legacy rows with no link). Columns
#' `uuid`, `filename`, `hash` (the stored copy's current hash) and
#' `uuid_project`; zero rows when nothing holds the bytes.
#' @keywords internal
#' @noRd
.ar_asset_for_hash <- function(con, hash) {
  if (is.na(hash)) {
    return(data.frame(uuid = character(0), filename = character(0),
                      hash = character(0), uuid_project = character(0)))
  }
  if (DBI::dbExistsTable(con, "ingest_file")) {
    linked <- DBI::dbGetQuery(
      con,
      "SELECT a.uuid, a.filename, a.hash, a.uuid_project
         FROM ingest_file i JOIN asset a ON a.uuid = i.uuid_asset
        WHERE i.hash = ?",
      params = list(hash)
    )
    if (nrow(linked) > 0) {
      return(linked)
    }
  }
  DBI::dbGetQuery(
    con,
    "SELECT uuid, filename, hash, uuid_project FROM asset WHERE hash = ?",
    params = list(hash)
  )
}

#' When each asset was archived: its `insert` row in `change_log`
#'
#' Returns a POSIXct vector aligned with `uuids`, `NA` for an asset with no
#' insert row (a legacy asset loaded outside the mutation layer).
#' @keywords internal
#' @noRd
.ar_archived_at <- function(con, uuids) {
  out <- rep(as.POSIXct(NA, tz = "UTC"), length(uuids))
  if (length(uuids) == 0 || !DBI::dbExistsTable(con, "change_log")) {
    return(out)
  }
  r <- DBI::dbGetQuery(
    con,
    paste0("SELECT uuid_row, min(\"at\") AS at FROM change_log
             WHERE tbl = 'asset' AND action = 'insert' AND uuid_row IN (",
           paste(rep("?", length(uuids)), collapse = ","), ")
             GROUP BY uuid_row"),
    params = as.list(uuids)
  )
  m <- match(uuids, r$uuid_row)
  out[!is.na(m)] <- r$at[m[!is.na(m)]]
  out
}

#' Is the inbox source of this asset still inside its settle hold?
#'
#' `TRUE` only when settling is on, the asset's filename has a configured
#' extension, and fewer than `hold_secs` have passed since it was archived.
#' An asset with no recorded archive time is not held.
#' @keywords internal
#' @noRd
.ar_settle_held <- function(con, uuid, filename, cfg, now = Sys.time()) {
  if (is.null(cfg) || !isTRUE(.ar_settle_ext_match(filename, cfg))) {
    return(FALSE)
  }
  at <- .ar_archived_at(con, uuid)
  if (is.na(at)) {
    return(FALSE)
  }
  as.numeric(difftime(now, at, units = "secs")) < cfg$hold_secs
}

#' Accept file-store rewrites of recently archived files into `asset.hash`
#'
#' Some file stores rewrite a file after it has been archived - SharePoint,
#' for one, rewrites an embedded metadata block inside old-format Office
#' files some time after upload. The content and size are unchanged, but the
#' bytes differ, so `asset.hash` stops matching the stored copy. This pass
#' brings `asset.hash` back in line with the stored file, under tight
#' conditions.
#'
#' It is off unless `st_config("archive_settle")` is set (see Configuration).
#' It looks at every asset whose filename has a configured extension
#' (case-insensitive) and that was archived within `window_hours` of `now`
#' (the archive time is the asset's `insert` row in `change_log`). It
#' re-hashes each stored copy, and when the hash differs from `asset.hash`:
#'
#' * the size must equal the as-received size (`ingest_file.size`);
#' * `accept(path, old_hash, asset)`, when configured, must return `TRUE`.
#'
#' A rewrite that passes is settled: `asset.hash` is updated through
#' [db_update()], with a `change_log` row that keeps the old hash and the
#' reason "storage rewrite". Each asset is its own transaction, so a failure
#' part-way through keeps the settles already made. A size change, an
#' unknown as-received size or an `accept` veto is warned about, naming the
#' file, and not accepted. `ingest_file.hash`, the as-received record, is
#' never changed; de-duplication stays on it.
#'
#' [ingest_dir()] runs this at the start of every write phase, so it rarely
#' needs calling by hand.
#'
#' @section Configuration:
#' `st_config("archive_settle")` is `NULL` (off) by default. A list turns it
#' on; `list()` takes every default. It cannot be set from an environment
#' variable. Fields:
#'
#' * `ext`: extensions to settle, default `c("xls", "doc", "ppt")`.
#' * `hold_secs`: how long an inbox source with a configured extension is
#'   kept after archiving before it may be deleted, default `900`. Settling
#'   itself is not delayed by the hold.
#' * `window_hours`: how long after archiving a rewrite is accepted, default
#'   `72`. A later change is left alone, and the removal step keeps the
#'   source and warns.
#' * `accept`: optional predicate `function(path, old_hash, asset)` that can
#'   veto a rewrite; `asset` is the one-row `asset` table row.
#'
#' An unknown field or a bad value aborts with a `sampletidy_error`.
#'
#' @param db path to the DuckDB file (opened read-write), or an open
#'   read-write DBI connection, which is used as is and left open.
#' @param now the clock the archive window is measured against.
#' @return invisibly, a tibble with one row per asset settled by this call:
#'   `uuid`, `old_hash`, `new_hash`. Zero rows when nothing settled or the
#'   setting is off.
#' @export
archive_settle <- function(db = st_config("live_db"), now = Sys.time()) {
  checkmate::assert_posixct(now, len = 1, any.missing = FALSE)
  cfg <- .ar_settle_config()
  empty <- tibble::tibble(uuid = character(0), old_hash = character(0),
                          new_hash = character(0))
  if (is.null(cfg)) {
    return(invisible(empty))
  }
  if (inherits(db, "DBIConnection")) {
    return(invisible(.ar_settle_con(db, cfg, now, empty)))
  }
  checkmate::assert_string(db)
  invisible(with_db_write(function(con) .ar_settle_con(con, cfg, now, empty), db = db))
}

#' @keywords internal
#' @noRd
.ar_settle_con <- function(con, cfg, now, empty) {
  if (!DBI::dbExistsTable(con, "asset") || !DBI::dbExistsTable(con, "change_log")) {
    return(empty)
  }
  cand <- DBI::dbGetQuery(
    con,
    "SELECT a.uuid, a.filename, a.hash, c.at AS archived_at
       FROM asset a
       JOIN (SELECT uuid_row, min(\"at\") AS at FROM change_log
              WHERE tbl = 'asset' AND action = 'insert' GROUP BY uuid_row) c
         ON c.uuid_row = a.uuid
      WHERE a.filename IS NOT NULL AND a.hash IS NOT NULL"
  )
  if (nrow(cand) == 0) {
    return(empty)
  }
  age <- as.numeric(difftime(now, cand$archived_at, units = "secs"))
  keep <- .ar_settle_ext_match(cand$filename, cfg) & !is.na(age) &
    age <= cfg$window_hours * 3600
  cand <- cand[keep, , drop = FALSE]
  if (nrow(cand) == 0) {
    return(empty)
  }

  archive_dir <- st_config("archive_dir")
  settled <- list()
  for (i in seq_len(nrow(cand))) {
    uuid <- cand$uuid[[i]]
    fn <- cand$filename[[i]]
    old_hash <- cand$hash[[i]]
    path <- file.path(archive_dir, uuid, fn)
    if (!utils::file_test("-f", path)) {
      next   # a missing copy is the removal step's and db_checks()' concern
    }
    new_hash <- tryCatch(hash_file(path), error = function(e) NA_character_)
    if (is.na(new_hash) || identical(new_hash, old_hash)) {
      next
    }

    sizes <- if (DBI::dbExistsTable(con, "ingest_file")) {
      DBI::dbGetQuery(
        con,
        "SELECT DISTINCT size FROM ingest_file
          WHERE size IS NOT NULL AND (uuid_asset = ? OR (uuid_asset IS NULL AND hash = ?))",
        params = list(uuid, old_hash)
      )$size
    } else {
      numeric(0)
    }
    stored_size <- .ar_file_size(path)
    if (length(sizes) == 0) {
      cli::cli_warn(
        "archive_settle(): the archived copy of {.file {fn}} ({.path {path}}) no
         longer matches its recorded hash, and its as-received size is unknown,
         so the change is not accepted; {.field asset.hash} is unchanged."
      )
      next
    }
    if (is.na(stored_size) || !all(as.numeric(sizes) == stored_size)) {
      cli::cli_warn(
        "archive_settle(): the archived copy of {.file {fn}} ({.path {path}})
         changed size ({sizes[[1]]} -> {stored_size} bytes) after archiving, so
         the change is not accepted as a storage rewrite; {.field asset.hash} is
         unchanged."
      )
      next
    }

    if (is.function(cfg$accept)) {
      asset_row <- DBI::dbGetQuery(con, "SELECT * FROM asset WHERE uuid = ?",
                                   params = list(uuid))
      verdict <- tryCatch(
        isTRUE(cfg$accept(path, old_hash, asset_row)),
        error = function(e) {
          cli::cli_warn("archive_settle(): {.code accept()} failed for {.file {fn}}: {conditionMessage(e)}")
          FALSE
        }
      )
      if (!verdict) {
        cli::cli_warn(
          "archive_settle(): {.code accept()} vetoed the rewrite of {.file {fn}}
           ({.path {path}}); {.field asset.hash} is unchanged."
        )
        next
      }
    }

    ok <- tryCatch(
      {
        db_transaction(con, function(con) {
          db_update(con, table = "asset", uuid = uuid,
                    changes = list(hash = new_hash), actor = "archive_settle",
                    reason = "storage rewrite: the file store rewrote the archived copy (same size)",
                    source_hash = old_hash)
        })
        TRUE
      },
      error = function(e) {
        cli::cli_warn(
          "archive_settle(): could not settle {.file {fn}}: {conditionMessage(e)}"
        )
        FALSE
      }
    )
    if (ok) {
      settled[[length(settled) + 1L]] <- tibble::tibble(
        uuid = uuid, old_hash = old_hash, new_hash = new_hash
      )
    }
  }

  if (length(settled) == 0) empty else dplyr::bind_rows(settled)
}
