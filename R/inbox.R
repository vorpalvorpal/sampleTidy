# Auto-import: the hourly inbox sweep, the run log and the standing status
# (status.json). The core writes no markdown: a deployment renders the status and
# the day digest through hooks (register_hook(renderer = TRUE)).
#
# The sweep does NOTHING unless something in `input_dir` changed since the last
# check (or the last check left a folder still arriving), or the live DB file
# changed (status refresh only). Every decision up to that point is made from
# file metadata alone - reading a Files-On-Demand file downloads it.

# ---- small helpers ----------------------------------------------------------

.inbox_fmt_utc <- function(x) format(x, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")

.inbox_parse_utc <- function(x) {
  as.POSIXct(x, format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
}

# Formats in the configured time zone (`.st_tz()`, read at call time).
.inbox_local <- function(x, fmt) format(x, fmt, tz = .st_tz())

.inbox_state_path <- function(report_dir) file.path(report_dir, ".imports.state")
.inbox_log_path <- function(report_dir) file.path(report_dir, ".imports.log")
.inbox_events_path <- function(report_dir) file.path(report_dir, "events.jsonl")

.inbox_db_stat <- function(db) {
  if (!file.exists(db)) return(list(db_size = NA_real_, db_mtime = NA_real_))
  list(db_size = as.numeric(file.size(db)),
       db_mtime = round(as.numeric(file.mtime(db)), 3))
}

.inbox_num_same <- function(a, b) {
  a <- suppressWarnings(as.numeric(a))
  b <- suppressWarnings(as.numeric(b))
  if (length(a) != 1 || length(b) != 1) return(FALSE)
  if (is.na(a) || is.na(b)) return(is.na(a) && is.na(b))
  abs(a - b) < 0.002
}

# ---- section 0: signature and check -------------------------------------------

#' Metadata-only signature of an inbox directory
#'
#' Every entry under `input_dir` to depth 2 (relative path, size, mtime),
#' sorted and hashed. Only `stat` is used - never file contents - because
#' reading a Files-On-Demand file downloads it.
#'
#' @param input_dir the inbox directory.
#' @return a single string.
#' @export
inbox_signature <- function(input_dir) {
  checkmate::assert_string(input_dir)
  top <- list.files(input_dir, all.files = TRUE, no.. = TRUE)
  top <- top[top != ".DS_Store"]
  rel <- top
  for (t in top) {
    p <- file.path(input_dir, t)
    if (dir.exists(p)) {
      sub <- list.files(p, all.files = TRUE, no.. = TRUE)
      sub <- sub[sub != ".DS_Store"]
      rel <- c(rel, file.path(t, sub))
    }
  }
  rel <- sort(rel, method = "radix")
  lines <- character(0)
  if (length(rel) > 0) {
    info <- file.info(file.path(input_dir, rel))
    lines <- paste(rel, info$size,
                   format(as.numeric(info$mtime), nsmall = 3, scientific = FALSE),
                   sep = "\t")
  }
  digest::digest(paste(lines, collapse = "\n"), algo = "sha256", serialize = FALSE)
}

#' Should the hourly sweep do anything?
#'
#' Read-only: writes nothing, not even a `checked_at`.
#'
#' @param input_dir the inbox directory.
#' @param report_dir directory holding `.imports.state`.
#' @param now current time; a local day other than that of the state's
#'   `checked_at` is a `"status"` reason (ruling R14).
#' @param db the live database file, stat-ed for the second trigger.
#' @return `"run"` (inbox changed, nothing recorded yet, or a folder was left
#'   arriving), `"status"` (the database file changed, or this is the first
#'   check of a new local day) or `"none"`.
#' @export
inbox_check <- function(input_dir, report_dir, now = Sys.time(),
                        db = st_config("live_db")) {
  checkmate::assert_string(input_dir)
  checkmate::assert_string(report_dir)
  checkmate::assert_string(db)
  sp <- .inbox_state_path(report_dir)
  if (!file.exists(sp)) return("run")
  st <- tryCatch(jsonlite::fromJSON(sp, simplifyVector = TRUE),
                 error = function(e) NULL)
  if (is.null(st) || is.null(st$signature)) return("run")
  if (!identical(as.character(st$signature), inbox_signature(input_dir))) return("run")
  if (isTRUE(st$pending)) return("run")
  # Ruling R14: the first check of each local day refreshes the status
  # (dates and ages in it move on even when nothing else did).
  last <- if (is.character(st$checked_at) && length(st$checked_at) == 1)
    .inbox_parse_utc(st$checked_at) else NA
  if (is.na(last) || .inbox_local(last, "%Y-%m-%d") != .inbox_local(now, "%Y-%m-%d")) {
    return("status")
  }
  cur <- .inbox_db_stat(db)
  if (!.inbox_num_same(st$db_size, cur$db_size) ||
      !.inbox_num_same(st$db_mtime, cur$db_mtime)) {
    return("status")
  }
  "none"
}

.inbox_write_state <- function(report_dir, input_dir, db, now, pending) {
  dir.create(report_dir, recursive = TRUE, showWarnings = FALSE)
  st <- c(list(signature = inbox_signature(input_dir),
               pending = isTRUE(pending),
               checked_at = .inbox_fmt_utc(now)),
          .inbox_db_stat(db))
  jsonlite::write_json(st, .inbox_state_path(report_dir), auto_unbox = TRUE,
                       digits = NA, na = "null")
  invisible(st)
}

# ---- lock -----------------------------------------------------------------------

.inbox_lock_path <- function(db) paste0(db, ".inbox.lock")

.inbox_pid_alive <- function(pid) {
  pid <- suppressWarnings(as.integer(pid))
  if (length(pid) != 1 || is.na(pid) || pid <= 0L) return(FALSE)
  isTRUE(tools::pskill(pid, 0L))
}

# Returns list(acquired, stale).
.inbox_lock_acquire <- function(db, now) {
  lp <- .inbox_lock_path(db)
  stale <- FALSE
  if (file.exists(lp)) {
    lk <- tryCatch(jsonlite::fromJSON(lp, simplifyVector = TRUE),
                   error = function(e) NULL)
    started <- if (!is.null(lk$started_at)) .inbox_parse_utc(lk$started_at) else NA
    old <- is.na(started) ||
      as.numeric(difftime(now, started, units = "secs")) > 2 * 3600
    live <- !is.null(lk) && .inbox_pid_alive(lk$pid) && !old
    if (live) return(list(acquired = FALSE, stale = FALSE))
    stale <- TRUE
  }
  jsonlite::write_json(
    list(pid = as.integer(Sys.getpid()), started_at = .inbox_fmt_utc(now)),
    lp, auto_unbox = TRUE
  )
  list(acquired = TRUE, stale = stale)
}

# ---- which folders are batches --------------------------------------------------

#' Which folders of the inbox are batches, and what happens to their leftovers
#'
#' A recogniser for [inbox_run()] and [import_status()]: which top-level
#' folders of the input directory are batches (one delivery each), how long a
#' batch must be quiet before it is imported, and what happens to the files an
#' import leaves behind. A deployment sets one with
#' `st_config("inbox_batches", inbox_batches(...))`.
#'
#' @param pattern `NULL` (every non-hidden subfolder of the input directory is
#'   a batch) or one non-empty regular expression (extended, as for [grepl()])
#'   matched against the names of the top-level folders. Hidden folders
#'   (names starting with a dot) never match.
#' @param settle_minutes one number, 0 or more. A batch is settled when it
#'   holds at least one file and no file changed in the last `settle_minutes`.
#' @param leftovers `NULL` (the default) leaves a batch's folder in place once
#'   its data is done; the status lists it as `"done"` and does not count it as
#'   waiting. A string is the name of a subfolder of `st_config("archive_dir")`:
#'   a settled folder with no unfinished data file is moved to
#'   `<archive_dir>/<leftovers>/<name>` (`<name> (2)` and so on if that
#'   exists). It must be one path component.
#' @return an object of class `sampletidy_inbox_batches`: a list of `pattern`,
#'   `settle_minutes` and `leftovers`.
#' @export
inbox_batches <- function(pattern = NULL, settle_minutes = 0, leftovers = NULL) {
  bad <- function(what) cli::cli_abort(what, class = "sampletidy_error", call = NULL)
  if (!is.null(pattern)) {
    if (!is.character(pattern) || length(pattern) != 1L || is.na(pattern) || !nzchar(pattern)) {
      bad("{.arg pattern} must be {.code NULL} or one non-empty string.")
    }
    ok <- tryCatch({ suppressWarnings(grepl(pattern, "x")); TRUE }, error = function(e) FALSE)
    if (!ok) bad("{.arg pattern} is not a valid regular expression.")
  }
  if (!is.numeric(settle_minutes) || length(settle_minutes) != 1L ||
      !is.finite(settle_minutes) || settle_minutes < 0) {
    bad("{.arg settle_minutes} must be one finite number, 0 or more.")
  }
  if (!is.null(leftovers)) {
    if (!is.character(leftovers) || length(leftovers) != 1L || is.na(leftovers) ||
        !nzchar(leftovers) || grepl("[/\\\\]", leftovers) || leftovers %in% c(".", "..")) {
      bad("{.arg leftovers} must be {.code NULL} or the name of one subfolder of the archive directory.")
    }
  }
  structure(list(pattern = pattern, settle_minutes = as.numeric(settle_minutes),
                 leftovers = leftovers),
            class = "sampletidy_inbox_batches")
}

# The batch recogniser in force: the option, else the generic default.
.inbox_default_batch <- function() {
  b <- st_config("inbox_batches")
  if (is.null(b)) inbox_batches() else b
}

# Validates `batch` and applies the `settle_minutes` override (NULL = keep).
.inbox_resolve_batch <- function(batch, settle_minutes = NULL) {
  if (!inherits(batch, "sampletidy_inbox_batches")) {
    cli::cli_abort("{.arg batch} must be made by {.fn inbox_batches}.",
                   class = "sampletidy_error", call = NULL)
  }
  if (!is.null(settle_minutes)) {
    checkmate::assert_number(settle_minutes, lower = 0)
    batch$settle_minutes <- settle_minutes
  }
  batch
}

# ---- scanning the inbox (metadata only) -------------------------------------------

.inbox_scan <- function(input_dir, now, settle_minutes, pattern = NULL) {
  top <- list.files(input_dir, no.. = TRUE)
  is_dir <- dir.exists(file.path(input_dir, top))
  is_batch <- if (is.null(pattern)) rep(TRUE, length(top)) else grepl(pattern, top)
  cand_names <- sort(top[is_dir & is_batch], method = "radix")
  cutoff <- as.numeric(now) - settle_minutes * 60
  cands <- lapply(cand_names, function(nm) {
    p <- file.path(input_dir, nm)
    f <- list.files(p, full.names = TRUE)
    f <- f[!dir.exists(f)]
    mt <- if (length(f)) as.numeric(file.info(f)$mtime) else numeric(0)
    list(name = nm, path = p, files = basename(f), file_paths = f, mtimes = mt,
         settled = length(f) > 0 && all(mt <= cutoff))
  })
  names(cands) <- cand_names
  list(candidates = cands,
       other_dirs = sort(setdiff(top[is_dir], cand_names), method = "radix"),
       loose = sort(top[!is_dir], method = "radix"))
}

# ---- database reads ---------------------------------------------------------------

.inbox_read_con <- function(db) {
  if (!file.exists(db)) return(NULL)
  tryCatch(DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE),
           error = function(e) NULL)
}

.inbox_open_reviews <- function(db) {
  empty <- data.frame(kind = character(), subkind = character(),
                      work_order = character(), created_at = numeric(),
                      stringsAsFactors = FALSE)
  con <- .inbox_read_con(db)
  if (is.null(con)) return(empty)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  has_sub <- "subkind" %in% DBI::dbListFields(con, "review_queue")
  q <- sprintf(
    "SELECT kind, %s AS subkind, work_order, created_at FROM review_queue
      WHERE COALESCE(status, 'open') = 'open'",
    if (has_sub) "subkind" else "CAST(NULL AS VARCHAR)"
  )
  r <- DBI::dbGetQuery(con, q)
  r$created_at <- as.numeric(r$created_at)
  r
}

# PLAN-22 A3: the hourly standing DB checks, on a read-only connection of
# their own. Returns NULL when there is no DB to read, the db_checks() result,
# or the error it raised - it never raises itself (status must always write).
.inbox_db_checks <- function(db) {
  con <- tryCatch(.inbox_read_con(db), error = function(e) NULL)
  if (is.null(con)) return(NULL)
  on.exit(try(DBI::dbDisconnect(con, shutdown = TRUE), silent = TRUE), add = TRUE)
  tryCatch(db_checks(con, tier = "hourly"), error = function(e) e)
}

# Problems lines from a db_checks() result: error-severity failures, and any
# check that could not run. Warn-severity failures are not problems.
.inbox_db_check_problems <- function(dbc) {
  if (is.null(dbc)) return(character(0))
  if (inherits(dbc, "error")) {
    return(sprintf("DB checks could not run: %s", gsub("\\s+", " ", conditionMessage(dbc))))
  }
  out <- character(0)
  for (i in seq_len(nrow(dbc))) {
    if (dbc$status[[i]] == "error") {
      out <- c(out, sprintf("DB check %s could not run: %s", dbc$name[[i]], dbc$message[[i]]))
    } else if (dbc$status[[i]] == "fail" && dbc$severity[[i]] == "error") {
      k <- as.character(dbc$sample[[i]]$key)
      out <- c(out, sprintf("DB check %s failed: %d offending row(s)%s", dbc$name[[i]], dbc$n[[i]],
                            if (length(k)) paste0(", e.g. ", paste(utils::head(k, 3), collapse = ", ")) else ""))
    }
  }
  out
}

.inbox_db_check_json <- function(dbc) {
  if (is.null(dbc) || inherits(dbc, "error")) return(list())
  lapply(seq_len(nrow(dbc)), function(i) list(
    name = dbc$name[[i]], tier = dbc$tier[[i]], severity = dbc$severity[[i]],
    status = dbc$status[[i]], n = dbc$n[[i]], ms = round(dbc$ms[[i]], 1),
    message = dbc$message[[i]], sample_keys = as.list(as.character(dbc$sample[[i]]$key))))
}

# Pre/post image of samples and per-work-order analysis counts.
.inbox_image <- function(db) {
  con <- .inbox_read_con(db)
  if (is.null(con)) return(NULL)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  samples <- DBI::dbGetQuery(con, "
    SELECT s.uuid AS uuid, p.name AS wo, COALESCE(s.datetime, s.date) AS dt, f.site AS site
      FROM \"sample\" s
      JOIN project p ON p.uuid = s.uuid_project
      LEFT JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
      LEFT JOIN feature f ON f.uuid = fa.uuid_feature")
  an <- DBI::dbGetQuery(con, "
    SELECT p.name AS wo, count(*) AS n
      FROM analysis a
      JOIN \"sample\" s ON s.uuid = a.uuid_sample
      JOIN project p ON p.uuid = s.uuid_project
     GROUP BY 1")
  list(samples = samples, an = an)
}

.inbox_adapters_of <- function(db, hashes) {
  con <- .inbox_read_con(db)
  if (is.null(con)) return(character(0))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  h <- unname(hashes)
  h <- h[!is.na(h)]
  if (length(h) == 0) return(character(0))
  DBI::dbGetQuery(con, sprintf(
    "SELECT adapter FROM ingest_file WHERE hash IN (%s)",
    paste0("'", gsub("'", "", h), "'", collapse = ",")))$adapter
}

.inbox_kind_of_adapters <- function(adapters) {
  k <- vapply(unique(stats::na.omit(adapters)), function(a) {
    if (a %in% c("esdat", "als_xtab", "als_enmrg")) "ALS lab"
    else if (grepl("gas", a)) "ACIRL gas"
    else if (grepl("dust", a)) "dust"
    else if (grepl("acirl", a)) "ACIRL water"
    else a
  }, character(1))
  if (length(k) == 0) "unknown" else paste(sort(unique(k)), collapse = " + ")
}

.inbox_work_orders <- function(pre, post, kind) {
  if (is.null(pre) || is.null(post)) return(list())
  new_s <- post$samples[!(post$samples$uuid %in% pre$samples$uuid), , drop = FALSE]
  # Unnamed projects exist in the live DB; they cannot be reported by work order.
  an_pre <- with(pre$an[!is.na(pre$an$wo), , drop = FALSE], stats::setNames(n, wo))
  an_post <- with(post$an[!is.na(post$an$wo), , drop = FALSE], stats::setNames(n, wo))
  wos <- sort(unique(c(stats::na.omit(new_s$wo), names(an_post)[vapply(names(an_post), function(w) {
    an_post[[w]] - (if (w %in% names(an_pre)) an_pre[[w]] else 0) > 0
  }, logical(1))])), method = "radix")
  lapply(wos, function(w) {
    d_an <- an_post[[w]] - (if (w %in% names(an_pre)) an_pre[[w]] else 0)
    ns <- new_s[new_s$wo == w, , drop = FALSE]
    basis <- if (nrow(ns) > 0) ns else post$samples[post$samples$wo == w, , drop = FALSE]
    sites <- stats::na.omit(basis$site)
    site <- if (length(sites)) names(sort(table(sites), decreasing = TRUE))[[1]] else NA_character_
    # local calendar days (the LOCAL_DATE rule; gas/dust/field rows carry only `date`).
    dts <- .flags_local_date(basis$dt[!is.na(basis$dt)])
    list(name = w, kind = kind, site = site,
         date_start = if (length(dts)) format(min(dts)) else NA_character_,
         date_end = if (length(dts)) format(max(dts)) else NA_character_,
         samples = nrow(ns), analyses = as.integer(d_an))
  })
}

# ---- backup -------------------------------------------------------------------------

.inbox_backup_copy <- function(from, to) {
  isTRUE(file.copy(from, to, overwrite = TRUE))
}

.inbox_sha <- function(p) digest::digest(file = p, algo = "sha256")

# Returns list(path, error).
.inbox_backup <- function(db, backup_dir, now, keep) {
  dir.create(backup_dir, recursive = TRUE, showWarnings = FALSE)
  to <- file.path(backup_dir, sprintf(
    "monitoring_pre-auto-import_%s.duckdb",
    format(now, "%Y%m%dT%H%M%SZ", tz = "UTC")
  ))
  fail <- function(msg) {
    unlink(to)
    list(path = NA_character_, error = msg)
  }
  ok <- tryCatch(.inbox_backup_copy(db, to), error = function(e) e)
  if (inherits(ok, "error")) return(fail(paste("backup copy failed:", conditionMessage(ok))))
  if (!isTRUE(ok) || !file.exists(to)) return(fail("backup copy failed"))
  same <- tryCatch(identical(.inbox_sha(db), .inbox_sha(to)), error = function(e) FALSE)
  if (!same) return(fail("backup verification failed (SHA-256 mismatch); import aborted"))

  all_b <- list.files(backup_dir, pattern = "^monitoring_pre-auto-import_.*\\.duckdb$",
                      full.names = TRUE)
  if (length(all_b) > keep) {
    mt <- file.mtime(all_b)
    ord <- order(mt, basename(all_b), decreasing = TRUE)
    # The backup just taken is always kept.
    drop <- setdiff(all_b[ord][-seq_len(keep)], to)
    unlink(drop)
  }
  list(path = to, error = NULL)
}

# ---- is there anything new for the DB? -------------------------------------------------

# Returns list(work = named logical by folder, hashes = list of folder -> hash by file).
.inbox_find_work <- function(cands, db) {
  register_builtin_adapters()
  fp <- registry_fingerprint()
  rm_on <- isTRUE(as.logical(st_config("remove_ingested")))
  con <- .inbox_read_con(db)
  if (!is.null(con)) on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  known <- if (is.null(con)) NULL else tryCatch(
    DBI::dbGetQuery(con, "SELECT hash, state, state_reason, adapter,
                                 registry_fingerprint FROM ingest_file"),
    error = function(e) NULL
  )
  hashes <- list()
  work <- vapply(cands, function(cd) {
    h <- vapply(cd$file_paths, function(f) tryCatch(hash_file(f), error = function(e) NA_character_),
                character(1))
    hashes[[cd$name]] <<- stats::setNames(h, cd$files)
    any(vapply(h, function(x) {
      if (is.na(x)) return(TRUE)
      if (is.null(known)) return(TRUE)
      r <- known[known$hash == x, , drop = FALSE]
      if (nrow(r) == 0) return(TRUE)
      st <- r$state[[1]]
      if (st %in% c("seen", "claimed")) return(TRUE)
      if (identical(st, "archived")) return(rm_on)
      .st_is_router_verdict(st, r$state_reason[[1]], r$adapter[[1]]) &&
        !identical(r$registry_fingerprint[[1]], fp)
    }, logical(1)))
  }, logical(1))
  list(work = work, hashes = hashes)
}

# ---- filing a batch folder's leftovers ----------------------------------------------

.inbox_data_exts <- c("csv", "tsv", "txt", "json", "xml", "xls", "xlsx", "xlsm",
                      "xlsb", "zip")
.inbox_done_states <- c("archived", "ignored", "retained_sibling")

# Classify files given their ingest_file facts (NA = not in the DB).
# Returns data.frame(file, data, unfinished, state).
.inbox_classify <- function(files, state, adapter, has_asset) {
  ext <- tolower(tools::file_ext(files))
  claimed <- !is.na(adapter) & nzchar(adapter)
  data <- ext %in% .inbox_data_exts | claimed
  has_asset <- !is.na(has_asset) & has_asset
  # R-22.N (2026-10-25): needs_review is never done, asset or not. The
  # old exemption (needs_review WITH an asset counted as done) hid 302 files
  # parked after their review items were settled; resolving the last covering
  # review item now moves the file on to archived (.st_settle_resolved_files).
  done <- !is.na(state) & state %in% .inbox_done_states
  data.frame(file = files, data = data, unfinished = data & !done,
             state = ifelse(is.na(state), "not yet imported", state),
             stringsAsFactors = FALSE)
}

# ingest_file facts for hashes -> aligned vectors.
.inbox_facts_by_hash <- function(db, hashes) {
  n <- length(hashes)
  out <- list(state = rep(NA_character_, n), adapter = rep(NA_character_, n),
              has_asset = rep(NA, n))
  con <- .inbox_read_con(db)
  if (is.null(con) || n == 0) return(out)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  r <- tryCatch(DBI::dbGetQuery(con, "SELECT hash, state, adapter, uuid_asset FROM ingest_file"),
                error = function(e) NULL)
  if (is.null(r)) return(out)
  m <- match(hashes, r$hash)
  out$state <- r$state[m]
  out$adapter <- r$adapter[m]
  out$has_asset <- ifelse(is.na(m), NA, !is.na(r$uuid_asset[m]) & nzchar(r$uuid_asset[m]))
  out
}

# Same, keyed by filename (latest row): metadata-only, for the status.
.inbox_facts_by_name <- function(db, files) {
  n <- length(files)
  out <- list(state = rep(NA_character_, n), adapter = rep(NA_character_, n),
              has_asset = rep(NA, n))
  con <- .inbox_read_con(db)
  if (is.null(con) || n == 0) return(out)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  r <- tryCatch(DBI::dbGetQuery(con, "SELECT filename, state, adapter, uuid_asset, updated_at
                                        FROM ingest_file WHERE filename IS NOT NULL"),
                error = function(e) NULL)
  if (is.null(r) || nrow(r) == 0) return(out)
  r <- r[order(as.numeric(r$updated_at), decreasing = TRUE, na.last = TRUE), , drop = FALSE]
  r <- r[!duplicated(r$filename), , drop = FALSE]
  m <- match(files, r$filename)
  out$state <- r$state[m]
  out$adapter <- r$adapter[m]
  out$has_asset <- ifelse(is.na(m), NA, !is.na(r$uuid_asset[m]) & nzchar(r$uuid_asset[m]))
  out
}

# Everything in a folder that would be filed (hidden files included, except a
# replay batch's hint file, which is dropped rather than filed).
.inbox_folder_entries <- function(path) {
  f <- list.files(path, all.files = TRUE, no.. = TRUE, full.names = TRUE)
  f[basename(f) != .rp_hint_name]
}

# Judge a settled folder: list(fileable, unfinished = data.frame, n_other, files).
# `dry_rep` is the dry-run ingest report for the folder (or NULL).
.inbox_folder_verdict <- function(path, db, dry_rep = NULL, dry_run = FALSE) {
  ent <- .inbox_folder_entries(path)
  if (length(ent) == 0 || any(dir.exists(ent))) {
    return(list(fileable = FALSE, unfinished = data.frame(), n_other = 0L, files = character(0)))
  }
  files <- basename(ent)
  hashes <- vapply(ent, function(f) tryCatch(hash_file(f), error = function(e) NA_character_),
                   character(1))
  fa <- .inbox_facts_by_hash(db, unname(hashes))
  cl <- .inbox_classify(files, fa$state, fa$adapter, fa$has_asset)
  if (dry_run && !is.null(dry_rep)) {
    # a dry run writes no ingest_file rows: judge new data files from the
    # dry-run report's file states instead.
    fbs <- unlist(dry_rep$files_by_state)
    cnt <- function(k) if (k %in% names(fbs)) as.integer(fbs[[k]]) else 0L
    n_nondata <- sum(!cl$data)
    bad <- cnt("failed") + cnt("needs_review") + max(0L, cnt("quarantined") - n_nondata)
    new_data <- cl$data & is.na(fa$state)
    cl$unfinished <- cl$unfinished & !new_data
    if (bad > 0 || isTRUE(dry_rep$failed)) cl$unfinished <- cl$unfinished | new_data
  }
  list(fileable = !any(cl$unfinished), unfinished = cl[cl$unfinished, , drop = FALSE],
       n_other = sum(!cl$unfinished), files = files)
}

# Move every file of `path` into <archive_dir>/<subdir>/<basename>[ (n)].
# Never overwrites, never deletes a file that was not first verified at the
# destination. Returns list(to, files, error).
.inbox_file_folder <- function(path, archive_dir, subdir) {
  root <- file.path(archive_dir, subdir)
  dir.create(root, recursive = TRUE, showWarnings = FALSE)
  base <- basename(path)
  dest <- NULL
  n <- 1L
  repeat {
    cand <- file.path(root, if (n == 1L) base else sprintf("%s (%d)", base, n))
    if (!file.exists(cand) && dir.create(cand, showWarnings = FALSE)) {
      dest <- cand
      break
    }
    n <- n + 1L
    if (n > 1000L) return(list(to = NA_character_, files = character(0),
                               error = sprintf("no free destination name under %s", subdir)))
  }
  moved <- character(0)
  fail <- function(msg) list(to = normalizePath(dest, mustWork = FALSE), files = moved, error = msg)
  for (f in .inbox_folder_entries(path)) {
    to <- file.path(dest, basename(f))
    if (file.exists(to)) return(fail(paste("destination exists:", to)))
    ok <- suppressWarnings(file.rename(f, to))
    if (!ok) {
      sz <- file.size(f)
      mt <- file.mtime(f)
      cp <- file.copy(f, to, overwrite = FALSE, copy.date = TRUE)
      same <- isTRUE(cp) && file.exists(to) && identical(file.size(to), sz) &&
        identical(unname(tools::md5sum(f)), unname(tools::md5sum(to)))
      if (!same) {
        if (file.exists(to)) unlink(to)
        return(fail(paste("could not move", basename(f))))
      }
      Sys.setFileTime(to, mt)
      file.remove(f)
    }
    moved <- c(moved, basename(f))
  }
  if (length(.inbox_folder_entries(path)) == 0) unlink(file.path(path, .rp_hint_name))
  if (length(.inbox_folder_entries(path)) == 0) unlink(path, recursive = FALSE, force = FALSE)
  if (dir.exists(path) && length(.inbox_folder_entries(path)) == 0) file.remove(path)
  list(to = normalizePath(dest, mustWork = FALSE), files = moved, error = NULL)
}

# ---- the run log ------------------------------------------------------------------------

.inbox_read_log <- function(report_dir) {
  p <- .inbox_events_path(report_dir)
  if (!file.exists(p)) p <- .inbox_log_path(report_dir)
  if (!file.exists(p)) return(list())
  l <- readLines(p, warn = FALSE, encoding = "UTF-8")
  l <- l[nzchar(trimws(l))]
  out <- lapply(l, function(x) tryCatch(jsonlite::fromJSON(x, simplifyVector = FALSE),
                                        error = function(e) NULL))
  # A writer-check refusal is recorded in events.jsonl but is not a run: it
  # never supplies the last run's problems, a recent import or a digest run.
  Filter(function(x) !is.null(x) && !identical(x$action, "writer_check"), out)
}

.inbox_log_json <- function(res) {
  asis <- function(x) I(as.character(x))
  lg <- res
  lg$folders_seen <- asis(res$folders_seen)
  lg$folders_settled <- asis(res$folders_settled)
  lg$folders_processed <- asis(res$folders_processed)
  lg$folders_arriving <- asis(res$folders_arriving)
  lg$errors <- asis(res$errors)
  lg$folders <- lapply(res$folders, function(f) {
    f$files_left <- asis(f$files_left)
    f$work_orders <- lapply(f$work_orders, as.list)
    if (!is.null(f$files_filed)) f$files_filed$files <- asis(f$files_filed$files)
    f
  })
  if (length(lg$folders) == 0) lg$folders <- stats::setNames(list(), character(0))
  as.character(jsonlite::toJSON(lg, auto_unbox = TRUE, null = "null", na = "null",
                                digits = NA))
}

.inbox_line_date <- function(l) .inbox_local(.inbox_parse_utc(l$started_at), "%Y-%m-%d")
.inbox_line_time <- function(l) .inbox_local(.inbox_parse_utc(l$started_at), "%H:%M")

# Problem strings for one log line.
.inbox_line_problems <- function(l) {
  p <- character(0)
  if (isTRUE(l$stale_lock)) {
    p <- c(p, "stale lock taken over (a previous run did not finish cleanly)")
  }
  for (e in unlist(l$errors)) p <- c(p, e)
  for (nm in names(l$folders)) {
    f <- l$folders[[nm]]
    if (isTRUE(f$failed)) {
      p <- c(p, sprintf("%s failed: %s", nm, as.character(.inbox_or(f$error, "unknown error"))))
    }
  }
  p
}

# ---- the writer check -------------------------------------------------------------------

.inbox_refused_prefix <- "Import refused by the writer check: "

.inbox_one_string <- function(x) is.character(x) && length(x) == 1 && !is.na(x) && nzchar(x)

# NULL when this run may write the database, else the refusal reason. Calls
# st_config("writer_check") as fn(db); only exactly TRUE allows, and an error
# inside it refuses (fail safe).
.inbox_writer_check <- function(db) {
  fn <- st_config("writer_check")
  if (is.null(fn)) return(NULL)
  if (!is.function(fn)) return("writer check failed: st_config(\"writer_check\") is not a function")
  err <- NULL
  v <- tryCatch(fn(db), error = function(e) {
    err <<- conditionMessage(e)
    NULL
  })
  if (!is.null(err)) return(paste0("writer check failed: ", err))
  if (isTRUE(v)) return(NULL)
  if (.inbox_one_string(v)) return(as.character(v))
  r <- attr(v, "reason", exact = TRUE)
  if (.inbox_one_string(r)) return(as.character(r))
  "writer check refused"
}

# A refused run: one events.jsonl line, and the refusal put into an existing
# status.json. Nothing else (no .imports.log, state, lock, hooks or DB).
.inbox_writer_refused <- function(res, reason, report_dir) {
  res$action <- "writer_check"
  res$writer_check <- reason
  res$ended_at <- .inbox_fmt_utc(Sys.time())
  dir.create(report_dir, recursive = TRUE, showWarnings = FALSE)
  # Seed events.jsonl from the legacy log first, as a real run does.
  if (!file.exists(.inbox_events_path(report_dir)) && file.exists(.inbox_log_path(report_dir))) {
    file.copy(.inbox_log_path(report_dir), .inbox_events_path(report_dir))
  }
  cat(paste0(.inbox_log_json(res), "\n"), file = .inbox_events_path(report_dir), sep = "",
      append = TRUE)

  sp <- file.path(report_dir, "status.json")
  js <- if (file.exists(sp)) {
    tryCatch(jsonlite::read_json(sp, simplifyVector = FALSE), error = function(e) NULL)
  }
  if (is.list(js) && !is.null(names(js))) {
    old <- js$problems
    old <- Filter(function(p) !(is.character(p) && startsWith(p, .inbox_refused_prefix)), old)
    js$problems <- c(list(paste0(.inbox_refused_prefix, reason)), old)
    js$writer_check <- reason
    .inbox_write_status_json(js, report_dir)
  }
  res
}

# TRUE when status.json carries a writer-check refusal.
.inbox_status_refused <- function(report_dir) {
  sp <- file.path(report_dir, "status.json")
  if (!file.exists(sp)) return(FALSE)
  js <- tryCatch(jsonlite::read_json(sp, simplifyVector = FALSE), error = function(e) NULL)
  is.list(js) && !is.null(js$writer_check)
}

# ---- section 1: inbox_run() -----------------------------------------------------------------

#' Hourly auto-import sweep of the inbox
#'
#' Does nothing unless [inbox_check()] says something changed. See the
#' auto-import spec for the rules (settled gate, backup first, one
#' [ingest_dir()] per folder oldest first, lock, run log, status). It writes
#' `status.json` (and the identical `.import-status.json`) and the run log, and
#' fires the hooks ([register_hook()]); it writes no markdown.
#'
#' @param input_dir the inbox directory (one subdirectory per delivery).
#' @param db the live database.
#' @param backup_dir where pre-import backups go.
#' @param report_dir where the status, state and log live.
#' @param now current time.
#' @param settle_minutes `NULL` (use `batch$settle_minutes`) or a number that
#'   replaces it: a folder is settled when no file changed this recently.
#' @param keep_backups how many `monitoring_pre-auto-import_*.duckdb` to keep.
#' @param dry_run if `TRUE`: no backup, no live-DB write, no removal, no state.
#'   The status records what would be done in `dry_run_plan`.
#' @param checks `NULL` (no flags in the status), the check inputs for
#'   [import_flags()], or a zero-argument function returning them. A function
#'   is called on every status refresh, so a deployment can re-read its
#'   tables each time; if it fails, the status says so and keeps the previous
#'   status's flags, marked with `flags_carried_forward` and `flags_checked_at`.
#' @param batch which folders are batches, how long they settle and what
#'   happens to their leftovers: an [inbox_batches()] object. The default is
#'   `st_config("inbox_batches")`, or `inbox_batches()` when that is unset.
#' @section Writer check:
#' If `st_config("writer_check")` is a function, it is called first, right
#' after argument validation, as `fn(db)`. Exactly `TRUE` allows the run, which
#' then proceeds as usual. Anything else refuses it (dry runs too): the run
#' never opens, creates, locks, backs up or snapshots the database, writes no
#' state, fires no hooks and leaves the input alone. The reason is the value
#' itself if it is one non-empty string, else its `"reason"` attribute if that
#' is one, else `"writer check refused"`; an error inside `fn` refuses with
#' `"writer check failed: <message>"`. A refusal appends one line to
#' `events.jsonl` (never to the day digest or a later status) and, if
#' `status.json` exists, adds a top-level `writer_check` field and puts
#' `"Import refused by the writer check: <reason>"` first in its problems,
#' leaving every other field as it was. The next allowed run rebuilds the
#' status without them. `NULL` (the default) never refuses.
#'
#' @return (invisibly) a list: action, ran, locked, dry_run, started_at,
#'   ended_at, folders_seen, folders_settled, folders_processed,
#'   folders_arriving, folders, backup_path, errors, stale_lock. A refused
#'   run has `action = "writer_check"`, `ran = FALSE` and the reason in
#'   `writer_check`.
#' @export
inbox_run <- function(input_dir = st_config("input_dir"),
                      db = st_config("live_db"),
                      backup_dir, report_dir, now = Sys.time(),
                      settle_minutes = NULL, keep_backups = 10, dry_run = FALSE,
                      checks = NULL, batch = .inbox_default_batch()) {
  checkmate::assert_string(input_dir)
  checkmate::assert_string(db)
  checkmate::assert_string(backup_dir)
  checkmate::assert_string(report_dir)
  checkmate::assert_count(keep_backups)
  checkmate::assert_flag(dry_run)
  checkmate::assert(checkmate::check_list(checks, null.ok = TRUE),
                    checkmate::check_function(checks))
  batch <- .inbox_resolve_batch(batch, settle_minutes)
  # The writer check comes before anything that stats, opens, locks or creates
  # the DB, the state file or the backup dir. NULL (the default) allows.
  refused <- .inbox_writer_check(db)

  res <- list(
    action = NA_character_, ran = FALSE, locked = FALSE, dry_run = dry_run,
    started_at = .inbox_fmt_utc(now), ended_at = NA_character_,
    folders_seen = character(0), folders_settled = character(0),
    folders_processed = character(0), folders_arriving = character(0),
    folders = list(), backup_path = NA_character_, errors = character(0),
    stale_lock = FALSE
  )
  if (!is.null(refused)) {
    return(invisible(.inbox_writer_refused(res, refused, report_dir)))
  }

  action <- inbox_check(input_dir, report_dir, now = now, db = db)
  # A status left by a refusal is rebuilt by the first allowed run, even when
  # nothing else changed.
  if (action == "none" && .inbox_status_refused(report_dir)) action <- "status"
  res$action <- action
  if (action == "none") {
    return(invisible(res))
  }
  dir.create(report_dir, recursive = TRUE, showWarnings = FALSE)
  if (action == "status") {
    .inbox_refresh_status(db, input_dir, report_dir, now, batch, checks = checks)
    .inbox_write_state(report_dir, input_dir, db, now, pending = FALSE)
    return(invisible(res))
  }

  lk <- .inbox_lock_acquire(db, now)
  if (!lk$acquired) {
    res$locked <- TRUE
    return(invisible(res))
  }
  on.exit(unlink(.inbox_lock_path(db)), add = TRUE)
  res$ran <- TRUE
  res$stale_lock <- lk$stale

  # Guard: a test helper that leaked into a live run points archive_dir at the
  # temp area while the live db is elsewhere. Refuse before touching anything.
  guard_arch <- tryCatch(st_config("archive_dir"), error = function(e) NULL)
  if (is.character(guard_arch) && length(guard_arch) == 1 && !is.na(guard_arch) &&
      nzchar(guard_arch)) {
    tmp_root <- normalizePath(dirname(tempdir()), mustWork = FALSE)
    in_tmp <- function(p) startsWith(paste0(normalizePath(p, mustWork = FALSE), "/"),
                                     paste0(tmp_root, "/"))
    if (in_tmp(guard_arch) && !in_tmp(db)) {
      res$errors <- c(res$errors, sprintf(
        "archive_dir %s is in the temp area but the db is not; refusing to run (a test helper leaked into a live run?)",
        guard_arch))
      res$ended_at <- .inbox_fmt_utc(Sys.time())
      if (!dry_run) {
        line <- paste0(.inbox_log_json(res), "\n")
        cat(line, file = .inbox_events_path(report_dir), sep = "", append = TRUE)
        cat(line, file = .inbox_log_path(report_dir), sep = "", append = TRUE)
      }
      return(invisible(res))
    }
  }

  scan <- .inbox_scan(input_dir, now, batch$settle_minutes, batch$pattern)
  cands <- scan$candidates
  settled <- Filter(function(cd) cd$settled, cands)
  res$folders_seen <- names(cands)
  res$folders_settled <- names(settled)
  res$folders_arriving <- setdiff(names(cands), names(settled))

  found <- if (length(settled) > 0) .inbox_find_work(settled, db) else
    list(work = logical(0), hashes = list())
  todo <- settled[found$work[names(settled)]]
  aborted <- FALSE
  reps <- list()
  hook_problems <- character(0)
  cw_before <- NULL
  cw_failed <- FALSE
  n_ingested <- 0L
  want_cw <- !dry_run && length(.hook_env$work_complete) > 0

  if (length(todo) > 0) {
    tmp_db <- NULL
    work_db <- db
    if (dry_run) {
      tmp_db <- tempfile(fileext = ".duckdb")
      file.copy(db, tmp_db)
      work_db <- tmp_db
      on.exit(unlink(tmp_db), add = TRUE)
    } else {
      bk <- .inbox_backup(db, backup_dir, now, keep_backups)
      if (is.null(bk$error)) {
        res$backup_path <- bk$path
      } else {
        res$errors <- c(res$errors, bk$error)
        aborted <- TRUE
      }
    }

    if (!aborted) {
      for (nm in names(todo)) {
        cd <- todo[[nm]]
        if (want_cw && n_ingested == 0L) {
          cw_before <- tryCatch(completed_work(db), error = function(e) {
            cw_failed <<- TRUE
            hook_problems <<- c(hook_problems, sprintf(
              "hook work_complete[snapshot] failed: %s", conditionMessage(e)))
            NULL
          })
        }
        n_ingested <- n_ingested + 1L
        res$folders_processed <- c(res$folders_processed, nm)
        pre <- if (dry_run) NULL else .inbox_image(db)
        rep <- tryCatch(ingest_dir(cd$path, db = work_db, dry_run = dry_run),
                        error = function(e) e)
        failed <- inherits(rep, "error")
        if (!failed) reps[[nm]] <- rep
        fres <- function(k) if (failed) 0L else as.integer(.inbox_or(rep[[k]], 0L))
        wos <- list()
        if (!failed && !dry_run) {
          post <- tryCatch(.inbox_image(db), error = function(e) NULL)
          adapters <- tryCatch(.inbox_adapters_of(db, found$hashes[[nm]]),
                               error = function(e) character(0))
          wos <- .inbox_work_orders(pre, post, .inbox_kind_of_adapters(adapters))
        }
        if (!failed && !dry_run) {
          tryCatch(.ig_remove_spent_folder(input_dir, cd$path, rep),
                   error = function(e) FALSE)
        }
        left <- if (dir.exists(cd$path)) {
          f <- list.files(cd$path, full.names = TRUE)
          basename(f[!dir.exists(f)])
        } else character(0)
        res$folders[[nm]] <- list(
          events_committed = fres("n_events_committed"),
          rows_new = fres("rows_new"),
          rows_already_present = fres("rows_already_present"),
          rows_superseded = fres("rows_superseded"),
          review_items_opened = fres("review_items_opened"),
          failed = failed,
          error = if (failed) conditionMessage(rep) else NA_character_,
          files_left = left,
          folder_path = normalizePath(file.path(input_dir, nm), mustWork = FALSE),
          work_orders = wos
        )
      }
    }
  }

  # Filing: every settled folder, not only those imported this run. Under
  # leftovers = NULL nothing is filed and the folder stays where it is.
  would_file <- list()
  archive_dir <- tryCatch(st_config("archive_dir"), error = function(e) NULL)
  if (!aborted && !is.null(batch$leftovers) && length(settled) > 0 && is.character(archive_dir) &&
      length(archive_dir) == 1 && nzchar(archive_dir)) {
    for (nm in names(settled)) {
      cd <- settled[[nm]]
      if (!dir.exists(cd$path)) next
      entry <- res$folders[[nm]]
      if (!is.null(entry) && isTRUE(entry$failed)) next
      v <- .inbox_folder_verdict(cd$path, db, dry_rep = reps[[nm]], dry_run = dry_run)
      if (!v$fileable || length(v$files) == 0) next
      if (dry_run) {
        would_file[[length(would_file) + 1]] <- list(
          folder = nm, to = file.path(archive_dir, batch$leftovers, nm),
          files = length(v$files))
        next
      }
      mv <- tryCatch(.inbox_file_folder(cd$path, archive_dir, batch$leftovers),
                     error = function(e) list(to = NA_character_, files = character(0),
                                              error = conditionMessage(e)))
      if (!is.null(mv$error)) {
        res$errors <- c(res$errors, sprintf("filing %s failed: %s", nm, mv$error))
      }
      if (is.null(entry)) {
        entry <- list(events_committed = 0L, rows_new = 0L, rows_already_present = 0L,
                      rows_superseded = 0L, review_items_opened = 0L, failed = FALSE,
                      error = NA_character_, files_left = character(0),
                      folder_path = normalizePath(cd$path, mustWork = FALSE),
                      work_orders = list())
      }
      entry$files_filed <- list(to = mv$to, files = mv$files)
      entry$files_left <- if (dir.exists(cd$path)) {
        f <- list.files(cd$path, full.names = TRUE)
        basename(f[!dir.exists(f)])
      } else character(0)
      res$folders[[nm]] <- entry
    }
  }
  for (nm in names(res$folders)) {
    if (is.null(res$folders[[nm]]$files_filed)) {
      res$folders[[nm]]$files_filed <- list(to = NA_character_, files = character(0))
    }
  }

  res$ended_at <- .inbox_fmt_utc(Sys.time())

  if (dry_run) {
    plan <- list(would_import = as.list(res$folders_processed), would_file = would_file)
    .inbox_refresh_status(db, input_dir, report_dir, now, batch, dry_run = TRUE, plan = plan,
                          checks = checks)
    return(invisible(res))
  }

  line <- paste0(.inbox_log_json(res), "\n")
  # events.jsonl is the log; .imports.log is kept for one release. Seed events.jsonl
  # from the legacy log the first time, then append the same line to both.
  if (!file.exists(.inbox_events_path(report_dir)) && file.exists(.inbox_log_path(report_dir))) {
    file.copy(.inbox_log_path(report_dir), .inbox_events_path(report_dir))
  }
  cat(line, file = .inbox_events_path(report_dir), sep = "", append = TRUE)
  cat(line, file = .inbox_log_path(report_dir), sep = "", append = TRUE)

  ctx <- .hook_context("inbox_run", report_dir, input_dir, db, now)
  if (length(.hook_env$after_run) > 0) {
    ctx_run <- ctx
    if (.inbox_day_has_news(report_dir, now)) ctx_run$day <- .inbox_day_digest(report_dir, db, now)
    hook_problems <- c(hook_problems, .hooks_run("after_run", res, ctx_run))
  }
  if (want_cw && n_ingested > 0L && !aborted && !cw_failed) {
    done <- tryCatch(completed_work(db), error = function(e) {
      hook_problems <<- c(hook_problems, sprintf(
        "hook work_complete[snapshot] failed: %s", conditionMessage(e)))
      NULL
    })
    if (!is.null(done) && !is.null(cw_before)) {
      fresh <- done[!done$uuid %in% cw_before$uuid, , drop = FALSE]
      if (nrow(fresh) > 0) {
        hook_problems <- c(hook_problems, .hooks_run("work_complete", fresh, ctx))
      }
    }
  }
  .inbox_refresh_status(db, input_dir, report_dir, now, batch, checks = checks,
                        extra_problems = hook_problems)
  if (!aborted) {
    .inbox_write_state(report_dir, input_dir, db, now,
                       pending = length(res$folders_arriving) > 0)
  }
  invisible(res)
}

.inbox_or <- function(a, b) if (is.null(a) || (length(a) == 1 && is.na(a))) b else a

.inbox_today_lines <- function(report_dir, now) {
  d <- .inbox_local(now, "%Y-%m-%d")
  Filter(function(l) identical(.inbox_line_date(l), d) && !isTRUE(l$dry_run),
         .inbox_read_log(report_dir))
}

.inbox_line_imports <- function(l) {
  out <- list()
  for (nm in names(l$folders)) {
    f <- l$folders[[nm]]
    for (w in f$work_orders) {
      w$folder <- nm
      w$folder_path <- f$folder_path
      out[[length(out) + 1]] <- w
    }
  }
  out
}

.inbox_line_filed <- function(l) {
  out <- list()
  for (nm in names(l$folders)) {
    ff <- l$folders[[nm]]$files_filed
    fl <- as.character(unlist(ff$files))
    if (length(fl) > 0) out[[length(out) + 1]] <- list(folder = nm, to = ff$to, files = fl)
  }
  out
}

.inbox_day_has_news <- function(report_dir, now) {
  any(vapply(.inbox_today_lines(report_dir, now), function(l) {
    length(.inbox_line_imports(l)) > 0 || length(.inbox_line_problems(l)) > 0 ||
      length(.inbox_line_filed(l)) > 0
  }, logical(1)))
}

# The day digest a renderer gets (and the deprecated import_report() builds):
# the non-dry-run log lines of the local day of `now`, times in the local zone.
.inbox_day_digest <- function(report_dir, db, now) {
  runs <- lapply(.inbox_today_lines(report_dir, now), function(l) {
    list(started_at = l$started_at, time = .inbox_line_time(l),
         imports = .inbox_line_imports(l), filed = .inbox_line_filed(l),
         problems = .inbox_line_problems(l))
  })
  list(date = .inbox_local(now, "%Y-%m-%d"), time = .inbox_local(now, "%H:%M"),
       review_items_open = nrow(.inbox_open_reviews(db)), runs = runs)
}

# ---- section 2: import_report() ---------------------------------------------------------------

#' Render the dated import note (deprecated)
#'
#' @description
#' Deprecated: the core no longer writes markdown. [inbox_run()] hands the day
#' digest to the `"after_run"` hooks as `context$day`. This wrapper builds the
#' same digest for the local date of `now` and calls only the `"after_run"`
#' hooks registered with `renderer = TRUE` ([register_hook()]), as
#' `fn(NULL, context)` with `context$source == "import_report"`. With none
#' registered it warns (class `sampletidy_deprecated`) and writes nothing; a
#' failing renderer is a warning of class `sampletidy_hook_failed`. Read-only
#' on the DB.
#'
#' @param db the live database.
#' @param report_dir where `events.jsonl` lives.
#' @param now current time.
#' @return `<report_dir>/<YYYY-MM-DD>-imports.md` for the local date of `now`,
#'   invisibly. The core does not write it; a renderer does.
#' @export
import_report <- function(db = st_config("live_db"), report_dir, now = Sys.time()) {
  checkmate::assert_string(db)
  checkmate::assert_string(report_dir)
  day <- .inbox_day_digest(report_dir, db, now)
  path <- file.path(report_dir, paste0(day$date, "-imports.md"))
  if (!.hooks_have_renderer("after_run")) {
    cli::cli_warn(
      c("{.fn import_report} is deprecated and no {.val after_run} renderer is registered, so nothing was written.",
        i = "Register one with {.code register_hook(\"after_run\", fn, renderer = TRUE)}."),
      class = "sampletidy_deprecated")
    return(invisible(path))
  }
  ctx <- .hook_context("import_report", report_dir, NA_character_, db, now, day)
  for (msg in .hooks_run("after_run", NULL, ctx, only_renderers = TRUE)) {
    cli::cli_warn("{msg}", class = "sampletidy_hook_failed")
  }
  invisible(path)
}

# ---- section 2a: import_status() ----------------------------------------------------------------

.inbox_meanings <- c(
  "date_conflict/a77" = "dust block dates disagree; held until released",
  "work_order_reingest/blocked" = "lab file for a work order already in the database; held",
  "unknown_feature" = "sampling point not recognised",
  "unknown_analyte" = "analyte not recognised",
  "unknown_unit" = "unit not recognised",
  "sample_collision" = "two samples claim the same point and time",
  "value_conflict" = "a value disagrees with one already stored",
  "duplicate_report_number" = "report number already used by another delivery",
  "project_parent_conflict" = "work order's parent project disagrees",
  "other/foreign_work_order" = "file belongs to a different work order",
  "adapter_tie" = "two readers claimed the same file",
  "parse_error" = "file could not be read",
  "qc_label_conflict" = "lab's second sample ID names a QC type, but the point is not a QC code"
)

.inbox_meaning <- function(kind, subkind) {
  key <- if (is.na(subkind)) kind else paste0(kind, "/", subkind)
  m <- unname(.inbox_meanings[key])
  if (is.na(m)) m <- unname(.inbox_meanings[kind])
  if (is.na(m)) m <- "needs a decision; see the review queue"
  m
}

.inbox_is_note <- function(rv) {
  (!is.na(rv$subkind) & rv$subkind == "self_precedence_note") |
    (!is.na(rv$kind) & rv$kind == "self_precedence_note")
}

.inbox_review_groups <- function(rv, now) {
  # Self-precedence notes are kind 'unknown_feature', subkind
  # 'self_precedence_note' (2026-10-21, FIXES item E); the old bare-kind shape
  # is still accepted, harmlessly.
  rv <- rv[!.inbox_is_note(rv), , drop = FALSE]
  if (nrow(rv) == 0) return(data.frame())
  key <- paste(rv$kind, ifelse(is.na(rv$subkind), "", rv$subkind),
               ifelse(is.na(rv$work_order), "", rv$work_order), sep = "\r")
  keys <- sort(unique(key), method = "radix")
  rows <- lapply(keys, function(k) {
    r <- rv[key == k, , drop = FALSE]
    data.frame(
      kind = r$kind[[1]], subkind = r$subkind[[1]], work_order = r$work_order[[1]],
      n = nrow(r), oldest = .inbox_oldest_fmt(min(r$created_at)),
      new = any(as.numeric(now) - r$created_at < 86400),
      meaning = .inbox_meaning(r$kind[[1]], r$subkind[[1]]),
      stringsAsFactors = FALSE
    )
  })
  do.call(rbind, rows)
}

.inbox_oldest_fmt <- function(secs) {
  .inbox_local(as.POSIXct(secs, origin = "1970-01-01", tz = "UTC"), "%Y-%m-%d")
}

#' Write the standing import status (deprecated as a note writer)
#'
#' @description
#' Deprecated: the core no longer writes markdown. This wrapper builds the
#' status exactly as [inbox_run()] does, writes `status.json` and
#' `.import-status.json` (the two are identical), and calls only the
#' `"after_status"` hooks registered with `renderer = TRUE`
#' ([register_hook()]), with `context$source == "import_status"`. A failing
#' renderer is added to the status `problems` and the json files are rewritten.
#' With no renderer registered it warns (class `sampletidy_deprecated`) after
#' writing the json.
#'
#' The status holds, as json: the open review items, the folders waiting in the
#' inbox and the loose files, the latest run's problems, the last 14 days of
#' imports, and the hourly standing DB checks ([db_checks()]: error-level
#' failures and checks that could not run are problems; the full result is in
#' `db_checks`; they never block anything). Read-only on the DB. With `checks`,
#' also the flags from [import_flags()], their `flag_checks` (each check with its
#' meaning) and `site_names`, each flag's `first_seen` carried over by key from
#' the previous `status.json` (else `.import-status.json`). If the `checks`
#' function fails, the previous flags are kept unchanged and marked with
#' `flags_carried_forward` and `flags_checked_at` (when they were last checked).
#'
#' @param db the live database.
#' @param input_dir the inbox directory.
#' @param report_dir where the status lives.
#' @param now current time.
#' @param settle_minutes `NULL` (use `batch$settle_minutes`) or a number that
#'   replaces it; the settle window used to tell arriving from waiting.
#' @param dry_run `NULL`, or any value to mark the status as a dry run (its
#'   `dry_run_plan` stays `null`).
#' @param checks `NULL` (no flags), the `checks` list of [import_flags()], or a
#'   zero-argument function returning it (called on every build).
#' @param batch an [inbox_batches()] object; the default is
#'   `st_config("inbox_batches")`, or `inbox_batches()` when that is unset.
#' @return `<report_dir>/Import status.md`, invisibly. The core does not write
#'   it; a renderer does.
#' @export
import_status <- function(db = st_config("live_db"), input_dir, report_dir,
                          now = Sys.time(), settle_minutes = NULL, dry_run = NULL,
                          checks = NULL, batch = .inbox_default_batch()) {
  checkmate::assert_string(db)
  checkmate::assert_string(input_dir)
  checkmate::assert_string(report_dir)
  checkmate::assert(checkmate::check_list(checks, null.ok = TRUE),
                    checkmate::check_function(checks))
  batch <- .inbox_resolve_batch(batch, settle_minutes)
  dir.create(report_dir, recursive = TRUE, showWarnings = FALSE)
  .inbox_refresh_status(db, input_dir, report_dir, now, batch, dry_run = !is.null(dry_run),
                        checks = checks, source = "import_status", only_renderers = TRUE)
  if (!.hooks_have_renderer("after_status")) {
    cli::cli_warn(
      c("{.fn import_status} is deprecated and no {.val after_status} renderer is registered, so no markdown was written; {.file status.json} was written.",
        i = "Register one with {.code register_hook(\"after_status\", fn, renderer = TRUE)}."),
      class = "sampletidy_deprecated")
  }
  invisible(file.path(report_dir, "Import status.md"))
}

# The status json: status.json and the legacy .import-status.json, identical.
.inbox_write_status_json <- function(js, report_dir) {
  for (f in c(".import-status.json", "status.json")) {
    jsonlite::write_json(js, file.path(report_dir, f),
                         auto_unbox = TRUE, pretty = TRUE, na = "null", null = "null",
                         digits = NA)
  }
  invisible(NULL)
}

# The status refresh: build, write the json files, then the after_status hooks
# (only the renderers for the deprecated wrapper). A failing hook is added to the
# problems and the json files are rewritten with it.
.inbox_refresh_status <- function(db, input_dir, report_dir, now, batch, dry_run = FALSE,
                                  plan = NULL, checks = NULL, extra_problems = character(0),
                                  source = "inbox_run", only_renderers = FALSE) {
  st <- .inbox_status_build(db, input_dir, report_dir, now, batch, dry_run, plan, checks,
                            extra_problems = extra_problems)
  .inbox_write_status_json(st, report_dir)
  ctx <- .hook_context(source, report_dir, input_dir, db, now)
  failed <- .hooks_run("after_status", st, ctx, only_renderers = only_renderers)
  if (length(failed) > 0) {
    st$problems <- c(st$problems, as.list(failed))
    .inbox_write_status_json(st, report_dir)
  }
  invisible(st)
}

# Builds the status list serialised to status.json. Writes nothing.
.inbox_status_build <- function(db, input_dir, report_dir, now, batch, dry_run, plan,
                                checks, extra_problems = character(0)) {
  # Read before the json files are overwritten (first_seen carry-over).
  fs <- if (is.null(checks)) NULL else .flags_for_status(db, now, checks, report_dir)

  rv <- .inbox_open_reviews(db)
  rv$created_at <- as.numeric(rv$created_at)
  n_open <- nrow(rv)
  groups <- .inbox_review_groups(rv, now)
  n_notes <- sum(.inbox_is_note(rv))

  scan <- .inbox_scan(input_dir, now, batch$settle_minutes, batch$pattern)
  waiting_json <- list()
  n_waiting <- 0L
  for (cd in scan$candidates) {
    path <- file.path(input_dir, cd$name)
    if (!cd$settled) {
      last <- if (length(cd$mtimes)) .inbox_fmt_utc(as.POSIXct(max(cd$mtimes), origin = "1970-01-01", tz = "UTC")) else NA_character_
      waiting_json[[length(waiting_json) + 1]] <- list(folder = cd$name, status = "arriving",
                                                       files = as.list(cd$files), path = path,
                                                       last_written = last)
      n_waiting <- n_waiting + 1L
    } else {
      fa <- .inbox_facts_by_name(db, cd$files)
      cl <- .inbox_classify(cd$files, fa$state, fa$adapter, fa$has_asset)
      if (any(cl$unfinished)) {
        un <- cl[cl$unfinished, , drop = FALSE]
        waiting_json[[length(waiting_json) + 1]] <- list(
          folder = cd$name, status = "left", other_files = sum(!cl$unfinished),
          files = lapply(seq_len(nrow(un)), function(i) list(file = un$file[[i]], state = un$state[[i]])),
          path = path, unfinished = TRUE)
        n_waiting <- n_waiting + 1L
      } else {
        st <- cl$state
        # Left in place (leftovers = NULL) and nothing unfinished: done, not waiting.
        done <- is.null(batch$leftovers)
        waiting_json[[length(waiting_json) + 1]] <- list(
          folder = cd$name, status = if (done) "done" else "left",
          files = lapply(seq_along(cd$files), function(i) list(file = cd$files[[i]], state = unname(st[[i]]))),
          path = path, unfinished = FALSE)
        if (!done) n_waiting <- n_waiting + 1L
      }
    }
  }
  # Directories outside the batch pattern are not sampleTidy's business and are
  # not listed; loose files may be misfiled reports.
  loose <- lapply(scan$loose, function(f) list(file = f, path = file.path(input_dir, f)))

  log <- .inbox_read_log(report_dir)
  problems <- character(0)
  if (length(log) > 0) problems <- .inbox_line_problems(log[[length(log)]])
  dbc <- .inbox_db_checks(db)
  problems <- c(problems, .inbox_db_check_problems(dbc))
  # R-22.H: the wrapper passes the previous failed/unfinished run (2026-10-25).
  prev_fail <- Sys.getenv("SAMPLETIDY_AUTOIMPORT_PREV_FAILURE", "")
  if (nzchar(prev_fail)) problems <- c(prev_fail, problems)
  # PLAN-20 P20.2: a hooks-file problem (session state), then hook failures of
  # this run, after the log-derived problems.
  problems <- c(problems, .hook_env$file_problems, extra_problems)

  # Recent imports: last 14 days, newest first (log order is chronological).
  recent <- list()
  cutoff <- as.numeric(now) - 14 * 86400
  for (l in rev(log)) {
    if (isTRUE(l$dry_run)) next
    t <- as.numeric(.inbox_parse_utc(l$started_at))
    if (is.na(t) || t < cutoff) next
    for (w in rev(.inbox_line_imports(l))) {
      recent[[length(recent) + 1]] <- list(
        date = .inbox_line_date(l), work_order = w$name, kind = w$kind,
        site = .inbox_or(w$site, NA_character_), folder = w$folder, analyses = w$analyses)
    }
  }

  js <- list(
    updated = .inbox_local(now, "%Y-%m-%d %H:%M"),
    host = unname(Sys.info()[["nodename"]]),
    dry_run = isTRUE(dry_run),
    review_items_open = n_open,
    folders_waiting = n_waiting,
    needs_review = if (nrow(groups) > 0) groups else list(),
    non_blocking_notes = n_notes,
    waiting = waiting_json,
    problems = as.list(problems),
    recent_imports = recent,
    db_checks = .inbox_db_check_json(dbc)
  )
  if (!is.null(fs)) js <- c(js, .flags_json(fs))
  js <- c(js, list(timezone = .st_tz(), loose = loose, dry_run_plan = plan))
  if (!is.null(fs)) {
    # What a renderer needs to lay the flags out: the checks in order with their
    # meanings, and the site code -> name map ({} when there is none).
    names_map <- if (length(fs$site_names)) as.list(fs$site_names) else
      stats::setNames(list(), character(0))
    js <- c(js, list(
      flag_checks = lapply(.flags_checks, function(ck) {
        list(check = ck, meaning = unname(.flags_meanings[ck]))
      }),
      site_names = names_map))
  }
  js
}
