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
#' If the database's `db_meta.writer_generation` (see [db_meta_get()]) is a
#' non-negative integer string `N`, the name is
#' `monitoring_YYYY-MM-DD_gN.duckdb`, so machines writing different
#' generations never overwrite each other's snapshots. Beside the snapshot it
#' writes a manifest, `<name without .duckdb>.manifest.json`, last and through
#' a rename: the copy's sha256 and size and facts read from the copy (see
#' [read_snapshot_manifest()]). The manifest of a snapshot about to be
#' replaced is deleted just before the replacing rename, so a manifest never
#' describes a different file.
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

  date <- format(Sys.Date(), "%Y-%m-%d")
  final_path <- NULL
  tmp_path <- NULL

  with_db_write(
    function(con) {
      DBI::dbExecute(con, "CHECKPOINT")
      # The generation is read inside the write connection, after CHECKPOINT,
      # so the name matches the bytes copied.
      gen <- .sn_generation(con)
      final_name <- if (is.na(gen)) sprintf("monitoring_%s.duckdb", date) else
        sprintf("monitoring_%s_g%s.duckdb", date, gen)
      final_path <<- file.path(dest_dir, final_name)
      tmp_path <<- paste0(final_path, ".tmp")
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
  facts <- if (length(tables) > 0) {
    tryCatch(.sn_facts(verify_con), error = function(e) e)
  }
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
  if (inherits(facts, "error")) {
    unlink(tmp_path)
    cli::cli_abort(
      "snapshot_db(): could not read the copy at {.path {tmp_path}} for its manifest: {conditionMessage(facts)}",
      class = "sampletidy_error"
    )
  }

  manifest <- c(
    list(format = .sn_manifest_format, manifest_version = 1L, file = basename(final_path),
         sha256 = digest::digest(file = tmp_path, algo = "sha256"),
         size = as.numeric(file.size(tmp_path))),
    facts,
    list(duckdb_version = as.character(utils::packageVersion("duckdb")),
         created_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"))
  )

  # The manifest of the snapshot about to be replaced goes first, so a
  # manifest never describes a different file; the new one is written last.
  manifest_path <- .sn_manifest_path(final_path)
  unlink(manifest_path)
  renamed <- file.rename(tmp_path, final_path)
  if (!isTRUE(renamed)) {
    cli::cli_abort(
      "Failed to finalize snapshot from {.path {tmp_path}} to {.path {final_path}}.",
      class = "sampletidy_error"
    )
  }
  .sn_write_manifest(manifest, manifest_path)

  final_path
}

.sn_manifest_format <- "sampleTidy-snapshot-manifest"

# The snapshot file name pattern, old (date only) and new (with _g<N>).
.sn_snapshot_re <- "^monitoring_(\\d{4}-\\d{2}-\\d{2})(_g(\\d+))?\\.duckdb$"

.sn_manifest_path <- function(snapshot) sub("\\.duckdb$", ".manifest.json", snapshot)

# db_meta.writer_generation if it is a non-negative integer string, else NA.
.sn_generation <- function(con) {
  g <- tryCatch(db_meta_get(con, "writer_generation"), error = function(e) NA_character_)
  if (!is.na(g) && grepl("^[0-9]+$", g)) g else NA_character_
}

# The manifest facts read from a connection to the copy.
.sn_facts <- function(con) {
  tbls <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
                                WHERE table_schema = 'main' AND table_type = 'BASE TABLE'
                                ORDER BY table_name")$table_name
  counts <- stats::setNames(lapply(tbls, function(t) {
    as.integer(DBI::dbGetQuery(con, sprintf("SELECT count(*) AS n FROM %s",
                                            DBI::dbQuoteIdentifier(con, t)))$n)
  }), tbls)
  sv <- if ("schema_version" %in% tbls) {
    DBI::dbGetQuery(con, "SELECT max(version) AS v FROM schema_version")$v
  }
  sv <- if (length(sv) == 1 && !is.na(sv)) as.integer(sv) else NULL
  mx <- if ("ingest_file" %in% tbls) {
    DBI::dbGetQuery(con, "SELECT strftime(max(updated_at), '%Y-%m-%dT%H:%M:%SZ') AS m FROM ingest_file")$m
  }
  mx <- if (length(mx) == 1 && !is.na(mx)) as.character(mx) else NULL
  meta <- as.list(.dm_read_con(con))
  if (length(meta) == 0) meta <- stats::setNames(list(), character(0))
  if (length(counts) == 0) counts <- stats::setNames(list(), character(0))
  list(schema_version = sv, db_meta = meta, row_counts = counts, max_ingest_updated_at = mx)
}

# Written through a tmp file and a rename, so a reader never sees half of one.
.sn_write_manifest <- function(m, path) {
  tmp <- paste0(path, ".tmp")
  txt <- jsonlite::toJSON(m, auto_unbox = TRUE, pretty = TRUE, null = "null", na = "null",
                          digits = NA)
  writeLines(txt, tmp, useBytes = TRUE)
  if (!isTRUE(file.rename(tmp, path))) {
    unlink(tmp)
    cli::cli_abort("Failed to write the snapshot manifest {.path {path}}.",
                   class = "sampletidy_error")
  }
  invisible(path)
}

#' Read, check and list snapshot manifests
#'
#' [snapshot_db()] writes `<snapshot name without .duckdb>.manifest.json` beside
#' each snapshot, last: its sha256 and size, the schema version, `db_meta`,
#' the row count of every table, the newest `ingest_file.updated_at`, the duckdb
#' version and when it was made. Choose snapshots by manifest, never by mtime.
#'
#' - `read_snapshot_manifest()` reads the manifest of `path`, which is the
#'   manifest itself or its snapshot. It aborts if the manifest is missing or
#'   is not a sampleTidy snapshot manifest.
#' - `verify_snapshot()` checks a snapshot against its manifest: `TRUE` if the
#'   size and sha256 match, otherwise a character vector of problems (a missing
#'   snapshot or manifest, a size or sha256 mismatch). It does not error for
#'   those.
#' - `list_snapshots()` lists the snapshots in `dir` that have a manifest,
#'   newest first: generation descending (none last), then date, then
#'   `created_at`. It reads only the manifests, never snapshot bytes, so it is
#'   cheap on a cloud folder that downloads files on demand.
#'
#' @param path a manifest or a snapshot path.
#' @param snapshot a snapshot path.
#' @param dir the snapshot folder.
#' @return `read_snapshot_manifest()`: the parsed manifest, a list.
#'   `verify_snapshot()`: `TRUE` or a character vector. `list_snapshots()`: a
#'   tibble with `file`, `path`, `manifest`, `date`, `generation`, `created_at`
#'   (UTC), `size` and `sha256`, zero rows if there is none.
#' @export
read_snapshot_manifest <- function(path) {
  checkmate::assert_string(path)
  mp <- if (grepl("\\.manifest\\.json$", path)) path else .sn_manifest_path(path)
  if (!file.exists(mp)) {
    cli::cli_abort("No snapshot manifest at {.path {mp}}.", class = "sampletidy_error")
  }
  m <- tryCatch(jsonlite::read_json(mp, simplifyVector = FALSE), error = function(e) NULL)
  if (!is.list(m) || is.null(names(m)) || !identical(m$format, .sn_manifest_format)) {
    cli::cli_abort("{.path {mp}} is not a sampleTidy snapshot manifest.",
                   class = "sampletidy_error")
  }
  m
}

#' @rdname read_snapshot_manifest
#' @export
verify_snapshot <- function(snapshot) {
  checkmate::assert_string(snapshot)
  problems <- character(0)
  if (!file.exists(snapshot)) problems <- c(problems, sprintf("snapshot %s is missing", snapshot))
  m <- tryCatch(read_snapshot_manifest(snapshot), error = function(e) e)
  if (inherits(m, "error")) {
    return(c(problems, sprintf("manifest of %s is missing or unreadable: %s", basename(snapshot),
                               conditionMessage(m))))
  }
  if (length(problems) > 0) return(problems)
  size <- file.size(snapshot)
  if (!isTRUE(as.numeric(m$size) == size)) {
    problems <- c(problems, sprintf("size %s does not match the manifest's %s", size,
                                    format(m$size, scientific = FALSE)))
  }
  sha <- digest::digest(file = snapshot, algo = "sha256")
  if (!identical(sha, m$sha256)) {
    problems <- c(problems, sprintf("sha256 %s does not match the manifest's %s", sha,
                                    as.character(m$sha256)))
  }
  if (length(problems) == 0) TRUE else problems
}

#' @rdname read_snapshot_manifest
#' @export
list_snapshots <- function(dir = st_config("snapshot_dir")) {
  checkmate::assert_string(dir)
  out <- tibble::tibble(file = character(0), path = character(0), manifest = character(0),
                        date = as.Date(character(0)), generation = integer(0),
                        created_at = as.POSIXct(character(0), tz = "UTC"),
                        size = numeric(0), sha256 = character(0))
  mps <- list.files(dir, pattern = "^monitoring_.*\\.manifest\\.json$", full.names = TRUE)
  rows <- lapply(mps, function(mp) {
    snap <- sub("\\.manifest\\.json$", ".duckdb", basename(mp))
    if (!grepl(.sn_snapshot_re, snap)) return(NULL)
    m <- tryCatch(read_snapshot_manifest(mp), error = function(e) NULL)
    if (is.null(m)) return(NULL)
    g <- m$db_meta$writer_generation
    g <- if (is.character(g) && length(g) == 1 && grepl("^[0-9]+$", g)) as.integer(g) else NA_integer_
    ca <- if (is.character(m$created_at) && length(m$created_at) == 1) m$created_at else NA_character_
    tibble::tibble(
      file = snap, path = file.path(dir, snap), manifest = mp,
      date = as.Date(sub(.sn_snapshot_re, "\\1", snap)), generation = g,
      created_at = as.POSIXct(ca, format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
      size = as.numeric(if (is.null(m$size)) NA else m$size),
      sha256 = if (is.character(m$sha256)) m$sha256 else NA_character_)
  })
  rows <- Filter(Negate(is.null), rows)
  if (length(rows) == 0) return(out)
  x <- dplyr::bind_rows(c(list(out), rows))
  ord <- order(is.na(x$generation), -x$generation, -as.numeric(x$date),
               -as.numeric(x$created_at), na.last = TRUE)
  x[ord, , drop = FALSE]
}

#' Prune old dated snapshots, thinning them by day, then week, then month
#'
#' Thins dated snapshots in `dest_dir`: `monitoring_YYYY-MM-DD.duckdb` and
#' `monitoring_YYYY-MM-DD_g<N>.duckdb` (a writer generation, see
#' [snapshot_db()]). Files that match neither pattern are left untouched.
#'
#' One snapshot per date: when several share a date, only the highest
#' generation is kept (a name without one ranks below any `_g<N>`) and the
#' others are deleted, at any age. The survivor is then the date's only file in
#' the retention below.
#'
#' Retention (age is today's date minus the file's date): every snapshot up to
#' `keep_days` old is kept; from there up to `keep_days + 7 * keep_weeks` days
#' old, only the newest snapshot of each ISO week (`%G-W%V`) is kept; older
#' than that, only the newest snapshot of each calendar month, indefinitely.
#' Each week or month is judged among that age zone's files only.
#' A deleted snapshot's manifest (`<name without .duckdb>.manifest.json`) is
#' deleted with it; a manifest whose snapshot is absent is left alone.
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

  files <- list.files(dest_dir, pattern = .sn_snapshot_re)
  if (length(files) == 0) {
    return(invisible(NULL))
  }

  all_dates <- as.Date(sub(.sn_snapshot_re, "\\1", files))
  gen_txt <- sub(.sn_snapshot_re, "\\3", files)
  # -1 ranks a name without a generation below every _g<N>.
  gen <- ifelse(nzchar(gen_txt), suppressWarnings(as.numeric(gen_txt)), -1)

  # One candidate per date: the highest generation. The others are removed.
  cand <- as.integer(unlist(tapply(seq_along(files), as.character(all_dates),
                                   function(i) i[which.max(gen[i])])))
  dates <- all_dates[cand]
  age <- as.numeric(Sys.Date() - dates)

  weekly <- age > keep_days & age <= keep_days + 7 * keep_weeks
  monthly <- age > keep_days + 7 * keep_weeks

  # Keep the newest file per group; non-members of a zone get NA group.
  newest_per <- function(zone, group) {
    idx <- which(zone)
    keep <- tapply(idx, group[idx], function(i) i[which.max(dates[i])])
    as.integer(unlist(keep))
  }
  keep <- cand[c(
    which(age <= keep_days),
    newest_per(weekly, format(dates, "%G-W%V")),
    newest_per(monthly, format(dates, "%Y-%m"))
  )]

  to_remove <- setdiff(seq_along(files), keep)
  if (length(to_remove) > 0) {
    gone <- files[to_remove]
    file.remove(file.path(dest_dir, gone))
    mf <- file.path(dest_dir, .sn_manifest_path(gone))
    mf <- mf[file.exists(mf)]
    if (length(mf) > 0) file.remove(mf)
  }

  invisible(NULL)
}
