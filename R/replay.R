# PLAN-21 phase (d) - R/replay.R: `replay_archive()`.
#
# A deployment that moves its importer to another machine from a snapshot can
# lose the imports made after that snapshot. Their inputs survive in the
# archive (`<archive_dir>/<asset uuid>/<original name>`, archive_file()), so
# this lists the archived files a database does not know and, on request,
# copies them into a batch of the input folder for the normal import.
#
# The copies keep their ORIGINAL asset uuids: the batch holds a hidden hint
# file (`.rp_hint_name`) mapping each copy to the archive folder it came from,
# and archive_file() consults it before minting a uuid (`.rp_hint_uuid()`).
# The hint is invisible to the rest of the inbox: ingest_dir() does not route
# it, a folder holding nothing else is spent (`.ig_folder_is_spent()`), and
# filing a batch's leftovers drops it rather than archiving it.

# The hidden bookkeeping file of a replay batch.
.rp_hint_name <- ".sampletidy-replay.json"

.rp_uuid_re <- "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"

#' Re-import archived files that a database does not know
#'
#' For a deployment that moves its importer to another machine from a
#' snapshot: the imports made after that snapshot are missing from it, but
#' every imported file was copied into the archive first. This lists the
#' archived files `db` does not know and, with `dry_run = FALSE`, copies them
#' into a batch of the input folder so the next [inbox_run()] imports them
#' again, under their original asset uuids (the archive folder each came
#' from), without making new archive folders.
#'
#' `db` is opened read-only and never written. Known to it are its asset
#' uuids (`asset.uuid`, `ingest_file.uuid_asset`), byte hashes
#' (`ingest_file.hash`, `asset.hash`) and content hashes
#' (`asset.content_hash`); a table or column it lacks is simply not known.
#'
#' Only top-level folders of `archive_dir` named like a UUID are walked
#' (leftovers folders, loose and hidden files are ignored). A folder named by
#' a known uuid is skipped without reading its files, since the archive may
#' be a cloud folder that downloads on read. Every other non-hidden file is
#' hashed; a known byte hash, or a known content hash (an Office file a file
#' store rewrote, see [content_fingerprint()]), is not listed.
#'
#' With `dry_run = FALSE` each listed file is copied (through a temporary
#' name and a rename) into `file.path(input_dir, batch)`, which is created if
#' needed. Of files with equal bytes only the first is copied. A file already
#' in the batch with the same bytes is not copied again, so a second replay
#' before the import copies nothing; a name taken by other content gets the
#' first 8 characters of its archive folder's name as a prefix. The batch's
#' only visible files are the copies; its bookkeeping is a hidden file the
#' import removes with the batch.
#'
#' @param db path to the database to compare against (an existing file).
#' @param archive_dir the archive directory (an existing folder).
#' @param input_dir the input folder the import reads. Must exist when
#'   `dry_run = FALSE`; not used by a dry run.
#' @param batch the name of the batch folder to copy into. `NULL` (the
#'   default) is `replay-g<N>`, `N` being `db`'s `db_meta`
#'   `writer_generation`, or `replay` when it has none. It must be one path
#'   component that the configured `st_config("inbox_batches")` pattern
#'   matches, or the import would never see it.
#' @param dry_run `TRUE` (the default) only lists; `FALSE` also copies.
#' @return a data frame, one row per listed file, ordered by folder then file:
#'   `path`, `folder` (the archive folder name, the original asset uuid),
#'   `file`, `size`, `hash`, `content_hash` (`NA` when none), `duplicate`
#'   (`TRUE` for all but the first of equal bytes) and `copied_to` (the copy
#'   in the batch, `NA` in a dry run or when not copied). Invisibly when
#'   `dry_run = FALSE`.
#' @export
replay_archive <- function(db = st_config("live_db"), archive_dir = st_config("archive_dir"),
                           input_dir = st_config("input_dir"), batch = NULL, dry_run = TRUE) {
  checkmate::assert_flag(dry_run)
  checkmate::assert_string(db)
  checkmate::assert_string(archive_dir)
  checkmate::assert_string(batch, null.ok = TRUE)
  bad <- function(msg, .envir = parent.frame()) {
    cli::cli_abort(msg, class = "sampletidy_error", call = NULL, .envir = .envir)
  }
  if (!file.exists(db)) bad("Database {.path {db}} does not exist.")
  if (!dir.exists(archive_dir)) bad("Archive directory {.path {archive_dir}} does not exist.")

  known <- .rp_known(db)

  if (!dry_run) {
    checkmate::assert_string(input_dir)
    if (!dir.exists(input_dir)) bad("Input directory {.path {input_dir}} does not exist.")
    if (is.null(batch)) {
      gen <- known$generation
      batch <- if (!is.na(gen) && grepl("^[0-9]+$", gen)) paste0("replay-g", gen) else "replay"
    }
    if (!nzchar(batch) || grepl("[/\\\\]", batch) || startsWith(batch, ".")) {
      bad("{.arg batch} must be the name of one non-hidden folder, not {.val {batch}}.")
    }
    pattern <- .inbox_default_batch()$pattern
    if (!is.null(pattern) && !grepl(pattern, batch)) {
      bad(c("The import would not see batch {.val {batch}}.",
            "i" = "The configured {.code inbox_batches} pattern is {.val {pattern}}; pass a {.arg batch} it matches."))
    }
  }

  out <- .rp_list(archive_dir, known)

  if (dry_run) {
    cli::cli_inform("{nrow(out)} archived file{?s} not known to the database.")
    return(out)
  }
  out <- .rp_copy(out, file.path(input_dir, batch))
  n_copied <- sum(!is.na(out$copied_to))
  cli::cli_inform("{nrow(out)} archived file{?s} not known to the database; {n_copied} in {.path {file.path(input_dir, batch)}}.")
  invisible(out)
}

# What `db` knows: uuids, byte hashes, content hashes and its generation.
.rp_known <- function(db) {
  con <- st_connect(db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  col <- function(table, column) {
    if (!DBI::dbExistsTable(con, table) || !column %in% DBI::dbListFields(con, table)) {
      return(character(0))
    }
    v <- DBI::dbGetQuery(con, sprintf("SELECT DISTINCT %s AS v FROM %s WHERE %s IS NOT NULL",
                                      column, table, column))$v
    as.character(v)
  }
  meta <- .dm_read_con(con)
  list(
    uuids = tolower(c(col("asset", "uuid"), col("ingest_file", "uuid_asset"))),
    hashes = c(col("ingest_file", "hash"), col("asset", "hash")),
    content = col("asset", "content_hash"),
    generation = if ("writer_generation" %in% names(meta)) meta[["writer_generation"]] else NA_character_
  )
}

# The archive walk: one row per unknown file, ordered by folder then file.
.rp_list <- function(archive_dir, known) {
  top <- list.files(archive_dir, no.. = TRUE)
  folders <- top[grepl(.rp_uuid_re, top) & dir.exists(file.path(archive_dir, top))]
  folders <- sort(folders[!tolower(folders) %in% known$uuids], method = "radix")
  rows <- list()
  for (fd in folders) {
    files <- sort(list.files(file.path(archive_dir, fd), no.. = TRUE), method = "radix")
    for (fn in files) {
      p <- file.path(archive_dir, fd, fn)
      if (!utils::file_test("-f", p)) next
      h <- hash_file(p)
      if (h %in% known$hashes) next
      ch <- content_fingerprint(p)$content_hash
      if (!is.na(ch) && ch %in% known$content) next
      rows[[length(rows) + 1L]] <- data.frame(
        path = p, folder = fd, file = fn, size = as.numeric(file.size(p)), hash = h,
        content_hash = as.character(ch), stringsAsFactors = FALSE
      )
    }
  }
  out <- if (length(rows)) do.call(rbind, rows) else
    data.frame(path = character(0), folder = character(0), file = character(0),
               size = numeric(0), hash = character(0), content_hash = character(0),
               stringsAsFactors = FALSE)
  out$duplicate <- duplicated(out$hash)
  out$copied_to <- rep(NA_character_, nrow(out))
  rownames(out) <- NULL
  out
}

# Copy each non-duplicate row into `dest`, recording the hint before each copy
# becomes visible. Returns `rows` with `copied_to` filled.
.rp_copy <- function(rows, dest) {
  todo <- which(!rows$duplicate)
  if (!length(todo)) return(rows)
  dir.create(dest, showWarnings = FALSE)
  if (!dir.exists(dest)) {
    cli::cli_abort("Could not create the batch folder {.path {dest}}.",
                   class = "sampletidy_error", call = NULL)
  }
  hints <- .rp_hint_read(dest)
  present <- list.files(dest, no.. = TRUE, full.names = TRUE)
  present <- present[utils::file_test("-f", present)]
  present_hash <- vapply(present, function(f) tryCatch(hash_file(f), error = function(e) NA_character_),
                         character(1), USE.NAMES = FALSE)
  add_hint <- function(file, i) {
    entry <- list(file = file, uuid = rows$folder[[i]], source = rows$file[[i]], hash = rows$hash[[i]])
    same <- vapply(hints, function(h) identical(h[c("file", "uuid", "source", "hash")], entry), logical(1))
    if (any(same)) return(invisible())
    hints <<- c(Filter(function(h) !identical(h$file, file), hints), list(entry))
    .rp_hint_write(dest, hints)
  }
  for (i in todo) {
    have <- which(present_hash %in% rows$hash[[i]])
    if (length(have)) {
      rows$copied_to[[i]] <- present[[have[[1]]]]
      add_hint(basename(present[[have[[1]]]]), i)
      next
    }
    fd <- rows$folder[[i]]
    fn <- rows$file[[i]]
    names_ok <- c(fn, paste0(substr(fd, 1, 8), "_", fn), paste0(fd, "_", fn))
    target <- names_ok[!file.exists(file.path(dest, names_ok))][1]
    if (is.na(target)) {
      cli::cli_warn("Not copied: every name for {.path {rows$path[[i]]}} is taken in {.path {dest}}.")
      next
    }
    final <- file.path(dest, target)
    tmp <- file.path(dest, paste0(".", target, ".copying"))
    ok <- isTRUE(file.copy(rows$path[[i]], tmp, overwrite = TRUE)) &&
      identical(tryCatch(hash_file(tmp), error = function(e) NA_character_), rows$hash[[i]])
    if (!ok) {
      unlink(tmp)
      cli::cli_abort("Could not copy {.path {rows$path[[i]]}} to {.path {final}}.",
                     class = "sampletidy_error", call = NULL)
    }
    add_hint(target, i)
    if (!isTRUE(file.rename(tmp, final))) {
      unlink(tmp)
      cli::cli_abort("Could not rename the copy of {.path {rows$path[[i]]}} to {.path {final}}.",
                     class = "sampletidy_error", call = NULL)
    }
    rows$copied_to[[i]] <- final
    present <- c(present, final)
    present_hash <- c(present_hash, rows$hash[[i]])
  }
  rows
}

# ---- the hint file ---------------------------------------------------------------------------

.rp_hint_read <- function(dir) {
  p <- file.path(dir, .rp_hint_name)
  if (!file.exists(p)) return(list())
  h <- tryCatch(jsonlite::read_json(p, simplifyVector = FALSE), error = function(e) NULL)
  entries <- if (is.list(h)) h$files else NULL
  if (!is.list(entries)) return(list())
  Filter(function(e) is.list(e) && all(vapply(c("file", "uuid", "source", "hash"), function(k) {
    is.character(e[[k]]) && length(e[[k]]) == 1L
  }, logical(1))), entries)
}

.rp_hint_write <- function(dir, entries) {
  p <- file.path(dir, .rp_hint_name)
  tmp <- paste0(p, ".new")
  jsonlite::write_json(list(format = "sampletidy-replay-hint", files = entries), tmp,
                       auto_unbox = TRUE, pretty = TRUE)
  if (!isTRUE(file.rename(tmp, p))) {
    unlink(tmp)
    cli::cli_abort("Could not write {.path {p}}.", class = "sampletidy_error", call = NULL)
  }
  invisible(p)
}

# For archive_file(): the original asset of a replayed file, or NULL. Used
# only when the batch's hint names `path` with these bytes, the archive copy
# `<archive_dir>/<uuid>/<source>` is a regular file with the same bytes, and
# no asset row has that uuid yet. Returns list(uuid, filename). Never throws.
.rp_hint_uuid <- function(con, path, hash, archive_dir) {
  hint <- file.path(dirname(path), .rp_hint_name)
  if (!file.exists(hint)) return(NULL)
  tryCatch({
    entries <- .rp_hint_read(dirname(path))
    hit <- Filter(function(e) identical(e$file, basename(path)) && identical(e$hash, hash) &&
                    grepl(.rp_uuid_re, e$uuid) && !grepl("[/\\\\]", e$source) &&
                    !e$source %in% c("", ".", ".."), entries)
    if (!length(hit)) return(NULL)
    e <- hit[[1]]
    copy <- file.path(archive_dir, e$uuid, e$source)
    if (!utils::file_test("-f", copy) || !identical(hash_file(copy), hash)) return(NULL)
    taken <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM asset WHERE uuid = ?",
                             params = list(e$uuid))$n
    if (taken > 0) return(NULL)
    list(uuid = e$uuid, filename = e$source)
  }, error = function(e) NULL)
}
