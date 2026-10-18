# Auto-import: the hourly inbox sweep, the dated import note and the standing
# status note (scratchpad/2026-10-18-autoimport/SPEC.md sections 0, 1, 2, 2a).
#
# The sweep does NOTHING unless something in `input_dir` changed since the last
# check (or the last check left a folder still arriving), or the live DB file
# changed (status refresh only). Every decision up to that point is made from
# file metadata alone - reading a Files-On-Demand file downloads it.

.inbox_tz <- "Australia/Sydney"

# ---- small helpers ----------------------------------------------------------

.inbox_fmt_utc <- function(x) format(x, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")

.inbox_parse_utc <- function(x) {
  as.POSIXct(x, format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
}

.inbox_syd <- function(x, fmt) format(x, fmt, tz = .inbox_tz)

.inbox_state_path <- function(report_dir) file.path(report_dir, ".imports.state")
.inbox_log_path <- function(report_dir) file.path(report_dir, ".imports.log")

.inbox_file_url <- function(path) {
  p <- utils::URLencode(path)
  p <- gsub("(", "%28", p, fixed = TRUE)
  p <- gsub(")", "%29", p, fixed = TRUE)
  paste0("file://", p)
}

.inbox_md_link <- function(text, path) {
  paste0("[", text, "](", .inbox_file_url(path), ")")
}

.inbox_site_label <- function(site) {
  ifelse(is.na(site), "Other",
         ifelse(site == "B", "Blaxland", ifelse(site == "K", "Katoomba", "Other")))
}

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
#' @param now current time (unused by the rule; kept for symmetry).
#' @param db the live database file, stat-ed for the second trigger.
#' @return `"run"` (inbox changed, nothing recorded yet, or a folder was left
#'   arriving), `"status"` (only the database file changed) or `"none"`.
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

# ---- scanning the inbox (metadata only) -------------------------------------------

.inbox_scan <- function(input_dir, now, settle_minutes) {
  top <- list.files(input_dir, no.. = TRUE)
  is_dir <- dir.exists(file.path(input_dir, top))
  cand_names <- sort(top[is_dir & startsWith(top, "input") & top != "input"],
                     method = "radix")
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

# Pre/post image of samples and per-work-order analysis counts.
.inbox_image <- function(db) {
  con <- .inbox_read_con(db)
  if (is.null(con)) return(NULL)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  samples <- DBI::dbGetQuery(con, "
    SELECT s.uuid AS uuid, p.name AS wo, s.datetime AS dt, f.site AS site
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
    dts <- basis$dt[!is.na(basis$dt)]
    list(name = w, kind = kind, site = .inbox_site_label(site),
         date_start = if (length(dts)) format(min(dts), "%Y-%m-%d", tz = "UTC") else NA_character_,
         date_end = if (length(dts)) format(max(dts), "%Y-%m-%d", tz = "UTC") else NA_character_,
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

# ---- filing an email folder's leftovers ----------------------------------------------

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
  done <- !is.na(state) &
    (state %in% .inbox_done_states | (state == "needs_review" & has_asset))
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

# Same, keyed by filename (latest row): metadata-only, for the status note.
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

# Everything in a folder that would be filed (hidden files included).
.inbox_folder_entries <- function(path) {
  list.files(path, all.files = TRUE, no.. = TRUE, full.names = TRUE)
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

# Move every file of `path` into <archive_dir>/_emails/<basename>[ (n)].
# Never overwrites, never deletes a file that was not first verified at the
# destination. Returns list(to, files, error).
.inbox_file_folder <- function(path, archive_dir) {
  root <- file.path(archive_dir, "_emails")
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
                               error = "no free destination name under _emails"))
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
  if (length(.inbox_folder_entries(path)) == 0) unlink(path, recursive = FALSE, force = FALSE)
  if (dir.exists(path) && length(.inbox_folder_entries(path)) == 0) file.remove(path)
  list(to = normalizePath(dest, mustWork = FALSE), files = moved, error = NULL)
}

# ---- the run log ------------------------------------------------------------------------

.inbox_read_log <- function(report_dir) {
  p <- .inbox_log_path(report_dir)
  if (!file.exists(p)) return(list())
  l <- readLines(p, warn = FALSE, encoding = "UTF-8")
  l <- l[nzchar(trimws(l))]
  out <- lapply(l, function(x) tryCatch(jsonlite::fromJSON(x, simplifyVector = FALSE),
                                        error = function(e) NULL))
  Filter(Negate(is.null), out)
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

.inbox_line_date <- function(l) .inbox_syd(.inbox_parse_utc(l$started_at), "%Y-%m-%d")
.inbox_line_time <- function(l) .inbox_syd(.inbox_parse_utc(l$started_at), "%H:%M")

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

# ---- section 1: inbox_run() -----------------------------------------------------------------

#' Hourly auto-import sweep of the inbox
#'
#' Does nothing unless [inbox_check()] says something changed. See the
#' auto-import spec for the rules (settled gate, backup first, one
#' [ingest_dir()] per folder oldest first, lock, run log, notes).
#'
#' @param input_dir the inbox directory (one `input*` subdirectory per email).
#' @param db the live database.
#' @param backup_dir where pre-import backups go.
#' @param report_dir where the notes, state and log live.
#' @param now current time.
#' @param settle_minutes a folder is settled when no file changed this recently.
#' @param keep_backups how many `monitoring_pre-auto-import_*.duckdb` to keep.
#' @param dry_run if `TRUE`: no backup, no live-DB write, no removal, no state.
#' @return (invisibly) a list: action, ran, locked, dry_run, started_at,
#'   ended_at, folders_seen, folders_settled, folders_processed,
#'   folders_arriving, folders, backup_path, errors, stale_lock.
#' @export
inbox_run <- function(input_dir = st_config("input_dir"),
                      db = st_config("live_db"),
                      backup_dir, report_dir, now = Sys.time(),
                      settle_minutes = 10, keep_backups = 10, dry_run = FALSE) {
  checkmate::assert_string(input_dir)
  checkmate::assert_string(db)
  checkmate::assert_string(backup_dir)
  checkmate::assert_string(report_dir)
  checkmate::assert_number(settle_minutes, lower = 0)
  checkmate::assert_count(keep_backups)
  checkmate::assert_flag(dry_run)

  res <- list(
    action = NA_character_, ran = FALSE, locked = FALSE, dry_run = dry_run,
    started_at = .inbox_fmt_utc(now), ended_at = NA_character_,
    folders_seen = character(0), folders_settled = character(0),
    folders_processed = character(0), folders_arriving = character(0),
    folders = list(), backup_path = NA_character_, errors = character(0),
    stale_lock = FALSE
  )

  action <- inbox_check(input_dir, report_dir, now = now, db = db)
  res$action <- action
  if (action == "none") {
    return(invisible(res))
  }
  dir.create(report_dir, recursive = TRUE, showWarnings = FALSE)
  if (action == "status") {
    import_status(db, input_dir, report_dir, now = now, settle_minutes = settle_minutes)
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

  scan <- .inbox_scan(input_dir, now, settle_minutes)
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

  # Filing: every settled folder, not only those imported this run.
  would_file <- character(0)
  archive_dir <- tryCatch(st_config("archive_dir"), error = function(e) NULL)
  if (!aborted && length(settled) > 0 && is.character(archive_dir) &&
      length(archive_dir) == 1 && nzchar(archive_dir)) {
    for (nm in names(settled)) {
      cd <- settled[[nm]]
      if (!dir.exists(cd$path)) next
      entry <- res$folders[[nm]]
      if (!is.null(entry) && isTRUE(entry$failed)) next
      v <- .inbox_folder_verdict(cd$path, db, dry_rep = reps[[nm]], dry_run = dry_run)
      if (!v$fileable || length(v$files) == 0) next
      if (dry_run) {
        would_file <- c(would_file, sprintf(
          "Would file %s to %s (%d file(s)).", nm,
          file.path(archive_dir, "_emails", nm), length(v$files)))
        next
      }
      mv <- tryCatch(.inbox_file_folder(cd$path, archive_dir),
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
    banner <- c(
      "**DRY RUN** - nothing was imported, backed up or removed.",
      if (length(res$folders_processed) > 0)
        paste0("Would import: ", paste(res$folders_processed, collapse = "; "), ".")
      else "Nothing new to import.",
      would_file
    )
    import_status(db, input_dir, report_dir, now = now,
                  settle_minutes = settle_minutes, dry_run = banner)
    return(invisible(res))
  }

  cat(.inbox_log_json(res), "\n", file = .inbox_log_path(report_dir),
      sep = "", append = TRUE)
  if (.inbox_day_has_news(report_dir, now)) {
    import_report(db, report_dir, now = now)
  }
  import_status(db, input_dir, report_dir, now = now, settle_minutes = settle_minutes)
  if (!aborted) {
    .inbox_write_state(report_dir, input_dir, db, now,
                       pending = length(res$folders_arriving) > 0)
  }
  invisible(res)
}

.inbox_or <- function(a, b) if (is.null(a) || (length(a) == 1 && is.na(a))) b else a

.inbox_today_lines <- function(report_dir, now) {
  d <- .inbox_syd(now, "%Y-%m-%d")
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

# ---- section 2: import_report() ---------------------------------------------------------------

#' Write the dated import note
#'
#' Writes `<report_dir>/<YYYY-MM-DD>-imports.md` for the Sydney date of `now`:
#' what was imported that day and that day's problems. Read-only on the DB.
#'
#' @param db the live database.
#' @param report_dir where the note and `.imports.log` live.
#' @param now current time.
#' @return the note's path, invisibly.
#' @export
import_report <- function(db = st_config("live_db"), report_dir, now = Sys.time()) {
  checkmate::assert_string(db)
  checkmate::assert_string(report_dir)
  dir.create(report_dir, recursive = TRUE, showWarnings = FALSE)
  lines_today <- .inbox_today_lines(report_dir, now)
  last_time <- if (length(lines_today)) .inbox_line_time(lines_today[[length(lines_today)]]) else
    .inbox_syd(now, "%H:%M")

  imports <- unlist(lapply(lines_today, .inbox_line_imports), recursive = FALSE)
  n_folders <- length(unique(vapply(imports, function(w) w$folder, character(1))))
  n_open <- nrow(.inbox_open_reviews(db))

  out <- c(sprintf("*Imports · %s · %d folder(s) imported today, %d review item(s) open*",
                   last_time, n_folders, n_open),
           "", "## Imported today", "")
  if (length(imports) == 0) {
    out <- c(out, "Nothing imported today.", "")
  } else {
    sites <- vapply(imports, function(w) .inbox_or(w$site, "Other"), character(1))
    for (s in c("Blaxland", "Katoomba", "Other")) {
      idx <- which(sites == s)
      if (length(idx) == 0) next
      out <- c(out, paste0("### ", s), "")
      for (i in idx) out <- c(out, .inbox_import_line(imports[[i]]))
      out <- c(out, "")
    }
  }
  filed <- unlist(lapply(lines_today, .inbox_line_filed), recursive = FALSE)
  if (length(filed) > 0) {
    out <- c(out, "## Filed", "")
    for (e in filed) {
      dest <- as.character(.inbox_or(e$to, NA_character_))
      head <- if (is.na(dest)) e$folder else paste0(e$folder, " · ", .inbox_md_link(basename(dest), dest))
      out <- c(out, paste0("- ", head), paste0("  - ", e$files))
    }
    out <- c(out, "")
  }
  probs <- unlist(lapply(lines_today, function(l) {
    p <- .inbox_line_problems(l)
    if (length(p)) paste0("- ", .inbox_line_time(l), " · ", p) else character(0)
  }))
  if (length(probs) > 0) out <- c(out, "## Problems", "", probs, "")
  out <- c(out, sprintf("*Last run %s; next within the hour. Log: .imports.log*", last_time))

  path <- file.path(report_dir, paste0(.inbox_syd(now, "%Y-%m-%d"), "-imports.md"))
  writeLines(out, path, useBytes = TRUE)
  invisible(path)
}

.inbox_import_line <- function(w) {
  dates <- if (is.null(w$date_start) || is.na(w$date_start)) "no sample dates" else if (identical(w$date_start, w$date_end))
    w$date_start else paste0(w$date_start, " to ", w$date_end)
  src <- if (is.null(w$folder_path)) w$folder else .inbox_md_link(w$folder, w$folder_path)
  sprintf("- %s · %s · %s · %d sample%s, %d analys%s · from %s",
          w$name, w$kind, dates, as.integer(w$samples),
          if (as.integer(w$samples) == 1L) "" else "s",
          as.integer(w$analyses), if (as.integer(w$analyses) == 1L) "is" else "es", src)
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
  "parse_error" = "file could not be read"
)

.inbox_meaning <- function(kind, subkind) {
  key <- if (is.na(subkind)) kind else paste0(kind, "/", subkind)
  m <- unname(.inbox_meanings[key])
  if (is.na(m)) m <- unname(.inbox_meanings[kind])
  if (is.na(m)) m <- "needs a decision; see the review queue"
  m
}

.inbox_review_groups <- function(rv, now) {
  rv <- rv[rv$kind != "self_precedence_note" | is.na(rv$kind), , drop = FALSE]
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
  .inbox_syd(as.POSIXct(secs, origin = "1970-01-01", tz = "UTC"), "%Y-%m-%d")
}

#' Write the standing import status note
#'
#' Rewrites `<report_dir>/Import status.md` and `.import-status.json`: open
#' review items, folders waiting in the inbox, the latest run's problems and
#' the last 14 days of imports. Read-only on the DB.
#'
#' @param db the live database.
#' @param input_dir the inbox directory.
#' @param report_dir where the notes live.
#' @param now current time.
#' @param settle_minutes settle window used to tell arriving from waiting.
#' @param dry_run optional banner lines (a dry run).
#' @return the note's path, invisibly.
#' @export
import_status <- function(db = st_config("live_db"), input_dir, report_dir,
                          now = Sys.time(), settle_minutes = 10, dry_run = NULL) {
  checkmate::assert_string(db)
  checkmate::assert_string(input_dir)
  checkmate::assert_string(report_dir)
  dir.create(report_dir, recursive = TRUE, showWarnings = FALSE)

  rv <- .inbox_open_reviews(db)
  rv$created_at <- as.numeric(rv$created_at)
  n_open <- nrow(rv)
  groups <- .inbox_review_groups(rv, now)
  n_notes <- sum(rv$kind == "self_precedence_note", na.rm = TRUE)

  scan <- .inbox_scan(input_dir, now, settle_minutes)
  waiting <- character(0)
  waiting_json <- list()
  n_waiting <- 0L
  for (cd in scan$candidates) {
    url <- .inbox_md_link(cd$name, cd$path)
    if (!cd$settled) {
      last <- if (length(cd$mtimes)) .inbox_syd(as.POSIXct(max(cd$mtimes), origin = "1970-01-01", tz = "UTC"), "%H:%M") else NA
      desc <- if (length(cd$files) == 0) "arriving: no files yet" else
        sprintf("arriving: %d file(s), last written %s; imported once settled", length(cd$files), last)
      waiting <- c(waiting, sprintf("- %s — %s", url, desc))
      waiting_json[[length(waiting_json) + 1]] <- list(folder = cd$name, status = "arriving",
                                                       files = as.list(cd$files))
      n_waiting <- n_waiting + 1L
    } else {
      fa <- .inbox_facts_by_name(db, cd$files)
      cl <- .inbox_classify(cd$files, fa$state, fa$adapter, fa$has_asset)
      if (any(cl$unfinished)) {
        un <- cl[cl$unfinished, , drop = FALSE]
        n_other <- sum(!cl$unfinished)
        waiting <- c(waiting, sprintf("- %s — %d unfinished data file(s)", url, nrow(un)),
                     sprintf("  - %s — %s", un$file, un$state),
                     if (n_other > 0) sprintf("  - %d other file(s) (email, images, ...) filed with it once the data is done", n_other))
        waiting_json[[length(waiting_json) + 1]] <- list(
          folder = cd$name, status = "left", other_files = n_other,
          files = lapply(seq_len(nrow(un)), function(i) list(file = un$file[[i]], state = un$state[[i]])))
      } else {
        st <- cl$state
        waiting <- c(waiting, sprintf("- %s — %d file(s) left", url, length(cd$files)),
                     sprintf("  - %s — %s", cd$files, st))
        waiting_json[[length(waiting_json) + 1]] <- list(
          folder = cd$name, status = "left",
          files = lapply(seq_along(cd$files), function(i) list(file = cd$files[[i]], state = unname(st[[i]]))))
      }
      n_waiting <- n_waiting + 1L
    }
  }
  # Non-input* directories (archive, bare input, the user's own folders) are not
  # sampleTidy's business and are not listed; loose files may be misfiled reports.
  for (f in scan$loose) {
    waiting <- c(waiting, sprintf("- %s — loose file; left for you",
                                  .inbox_md_link(f, file.path(input_dir, f))))
  }

  log <- .inbox_read_log(report_dir)
  problems <- character(0)
  if (length(log) > 0) problems <- .inbox_line_problems(log[[length(log)]])

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
        site = w$site, folder = w$folder, analyses = w$analyses)
    }
  }

  out <- c(sprintf("*Import status · updated %s · %d review item(s) open, %d folder(s) waiting*",
                   .inbox_syd(now, "%Y-%m-%d %H:%M"), n_open, n_waiting), "")
  if (!is.null(dry_run)) out <- c(out, dry_run, "")

  out <- c(out, "## Needs review", "")
  if (n_open == 0) {
    out <- c(out, "Nothing open.", "")
  } else {
    if (nrow(groups) > 0) {
      gk <- unique(groups[, c("kind", "subkind", "meaning")])
      for (i in seq_len(nrow(gk))) {
        g <- groups[groups$kind == gk$kind[[i]] &
                      ((is.na(groups$subkind) & is.na(gk$subkind[[i]])) |
                         (!is.na(groups$subkind) & groups$subkind %in% gk$subkind[[i]])), ,
                    drop = FALSE]
        lab <- if (is.na(gk$subkind[[i]])) gk$kind[[i]] else paste0(gk$kind[[i]], " / ", gk$subkind[[i]])
        out <- c(out, sprintf("**%s** — %s", lab, gk$meaning[[i]]))
        for (j in seq_len(nrow(g))) {
          out <- c(out, sprintf("- %s · %d item(s) · oldest %s%s",
                                if (is.na(g$work_order[[j]])) "(no work order)" else g$work_order[[j]],
                                g$n[[j]], g$oldest[[j]], if (g$new[[j]]) " · **new**" else ""))
        }
        out <- c(out, "")
      }
    }
    if (n_notes > 0) {
      out <- c(out, sprintf("%d non-blocking self-precedence note(s), not itemised.", n_notes), "")
    }
  }

  out <- c(out, "## Waiting", "")
  out <- c(out, if (length(waiting)) waiting else "Nothing waiting.", "")

  if (length(problems) > 0) out <- c(out, "## Problems", "", paste0("- ", problems), "")

  out <- c(out, "## Recent imports", "")
  if (length(recent) == 0) {
    out <- c(out, "Nothing imported in the last 14 days.", "")
  } else {
    out <- c(out, vapply(recent, function(r) {
      sprintf("- %s · %s (%s) · %s · [[%s-imports]]", r$date, r$work_order, r$kind, r$site, r$date)
    }, character(1)), "")
  }
  out <- c(out, "*Written by sampleTidy; log: .imports.log*")

  path <- file.path(report_dir, "Import status.md")
  writeLines(out, path, useBytes = TRUE)

  js <- list(
    updated = .inbox_syd(now, "%Y-%m-%d %H:%M"),
    host = unname(Sys.info()[["nodename"]]),
    dry_run = !is.null(dry_run),
    review_items_open = n_open,
    folders_waiting = n_waiting,
    needs_review = if (nrow(groups) > 0) groups else list(),
    non_blocking_notes = n_notes,
    waiting = waiting_json,
    problems = as.list(problems),
    recent_imports = recent
  )
  jsonlite::write_json(js, file.path(report_dir, ".import-status.json"),
                       auto_unbox = TRUE, pretty = TRUE, na = "null", digits = NA)
  invisible(path)
}
