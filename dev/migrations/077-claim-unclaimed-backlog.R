# REHEARSED, NOT APPLIED (rehearsed 2026-10-25 on a plain-cp copy of live at marker 1076). See
# dev/MIGRATIONS.md row 1077.
# Operator-run migration: claim the backlog of unclaimed ingest_file rows under the CURRENT
# importer's retention rules (R-22.G1 stem match, R-22.G2 SRNs / scanned field sheets /
# folder fallback). Marker 1077. Requires 1076.
#
# Authority: Robin, 2026-10-25 (R-22.G1, R-22.G2; "ignore preliminary reports once the final
# is in").
#
# ---- WHY ------------------------------------------------------------------------------
# Before R-22.G1/G2 the importer left every gas-report PDF, ALS SRN and scanned field sheet
# quarantined/unclaimed with no `asset` row. The inbox then filed each delivery folder to
# <archive_dir>/_emails/<folder>/, so the files are no longer in the input tree and the
# importer will never see them again. This applies the importer's retention to them once.
#
# ---- WHAT (frozen in 077-claim-unclaimed-backlog-INPUT.csv; one group per file) --------
# Every ingest_file row in state 'quarantined', reason 'unclaimed' gets ONE planned outcome:
#   retain  archive_file() (R/archive.R, unchanged: copies the bytes to
#           <archive_dir>/<new uuid>/<filename>, writes the asset row via db_append) and
#           ingest_file -> state 'archived', reason 'retained_sibling' (db_update, so
#           change_log records it). Both in ONE db_transaction, as .ig_retain_siblings().
#   ignore  a "Prelim <name>" PDF whose final "<name>" is already an asset (Robin: ignore the
#           preliminary once the final is in): ingest_file -> 'ignored', 'superseded_prelim'.
#   leave   untouched, with the reason (not a candidate / no work order / ambiguous / no
#           project / file missing / prelim without a final).
# The decision is the importer's own, made by its internals, not a re-implementation:
#   * candidate gate: the exact `gated` / `extra_pdf` expressions of .ig_retain_siblings()
#     (inline there, so copied verbatim in .mig077_gate(); .ig_is_acirl_shaped() reused);
#   * work order, in order: .st_guess_work_order_revision(filename) (what file_meta()
#     returns; no byte read); .ig_folder_work_order(con, routed, path_first_seen); and, for a
#     gated (non-"extra") file only, .ig_stem_work_order(con, path, hash);
#   * iterated to a FIXPOINT (mig077_plan_con()): each further pass treats the planned retains
#     so far as committed assets (a temp.asset overlay), so a scanned sheet whose folder-mate
#     is a retained gas PDF resolves to that PDF's project (split deliveries, where the
#     workbook arrived via another path, defeat the importer's single pass);
#   * a project row must exist by that name (find-only: never minted - archive_file()'s
#     .ct_ensure_project() then finds it); type = "QA" for an extra PDF, otherwise
#     .ig_retained_asset_type(filename).
# For folder inference the "folder" is the ORIGINAL delivery folder, dirname(path_first_seen),
# and `routed` is built from every ingest_file row with that same dirname (any state):
# path = path_first_seen, filename, hash, state, reason - the columns .ig_folder_work_order()
# reads (path, filename, hash).
# Out of scope by ruling (left, "not a candidate"): `_email.eml*` (round R-22.E records them),
# images, and the corpus-import leftovers (CSV/XLS/UUID-named files first seen under the
# 2026-10-21 corpus run directory).
#
# Where the file is: path_first_seen ("orig") or <assets>/processed/_emails/<folder>/<filename>
# ("emails"; the inbox's own filing, .inbox_file_folder(), " (n)" suffixes included); neither
# -> "missing" (left). Only stat() is used to locate files; bytes are read only for files
# that are retained (hash check + archive_file()'s copy).
#
# ---- CHECKS ---------------------------------------------------------------------------
#   Before, per file group (a failing guard SKIPS that file, SKIPPED CSV): the ingest_file
#   row is byte for byte as frozen (sha1); a re-derived plan equals the frozen one; for a
#   retain: the file is where the INPUT says, its xxHash128 equals ingest_file.hash, the
#   project exists exactly once by name and no asset holds the hash; for an ignore: the final
#   is still an asset. Around the writes (one transaction): baseline <- db_checks(con,
#   "migration") and an all-tier baseline; afterwards every planned row is as planned and
#   every retained file is at <archive_dir>/<uuid>/<filename> with its hash; nothing else
#   moved (whole-table checksums: project and every table but asset / ingest_file /
#   change_log / schema_version whole, those four outside the planned rows); counts (asset
#   +n_retain, change_log +n_retain +3 per transition, schema_version +1);
#   mig_db_checks_gate(con, baseline); no all-tier check gains an offender key.
#
# archive_file() writes its change_log row as actor 'ingest', reason 'archive source file'
# (it is reused as-is); those rows are identified by source_hash. The transitions are actor
# '077-claim-unclaimed-backlog'.
#
# Backups: verified whole-file snapshot; BACKUP CSV of every touched ingest_file row (full
# row). The byte copies are undone by deleting <archive_dir>/<uuid>/ for each asset in
# 077-...-BACKUP-copies.csv (written after the commit). Idempotent: marker present ->
# re-verify, no-op.
#
# Use:
#   env <- new.env(); sys.source("dev/migrations/077-claim-unclaimed-backlog.R", envir = env)
#   env$mig077_plan(db = ...)          # prints/returns the plan (read-only)
#   env$mig077_freeze(db = ...)        # writes the INPUT csv from the plan
#   env$mig077_run(db = ..., snapshot_dir = ..., archive_dir = ..., dry_run = TRUE)

.mig077_marker_version <- 1077L
.mig077_requires <- 1076L
.mig077_name <- "077-claim-unclaimed-backlog"
.mig077_actor <- .mig077_name
.mig077_reason <- "077 (Robin 2026-10-25: R-22.G1/G2 retention applied to the unclaimed backlog)"
.mig077_assets_default <- "/Users/rjs/Library/CloudStorage/OneDrive-BlueMountainsCityCouncil/Sharepoint/waste_data - Environmental monitoring/assets"
.mig077_corpus_run <- "/2026-10-21-corpus-live/work/run/"
.mig077_cols <- c("gid", "hash", "filename", "folder", "location", "outcome", "project", "type", "reason", "row_sha1")

.mig077_fail <- function(msg) cli::cli_abort(paste0(.mig077_name, ": ", msg), class = "sampletidy_error")
.mig077_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = if (length(list(...))) list(...) else NULL)[[1]][[1]])
.mig077_inlist <- function(x) if (!length(x)) "('')" else paste0("(", paste0("'", gsub("'", "''", unique(x)), "'", collapse = ","), ")")
.mig077_assets <- function() Sys.getenv("SAMPLETIDY_MIG077_ASSETS_DIR", unset = .mig077_assets_default)

.mig077_ensure_icu <- function(con) {
  DBI::dbExecute(con, "INSTALL icu")
  DBI::dbExecute(con, "LOAD icu")
  invisible(NULL)
}

# ---- rows, sha1 -------------------------------------------------------------------------

.mig077_rows <- function(con, hashes) {
  DBI::dbGetQuery(con, sprintf('SELECT hash AS ".id", * FROM ingest_file WHERE hash IN %s ORDER BY hash',
                               .mig077_inlist(hashes)))
}

.mig077_df_sha <- function(df) {
  out <- character(nrow(df))
  cols <- setdiff(names(df), ".id")
  for (i in seq_len(nrow(df))) {
    v <- vapply(cols, function(f) { s <- .st_changelog_str(df[[f]][i]); if (is.na(s)) "<NA>" else s }, "")
    out[[i]] <- digest::digest(paste(cols, v, sep = "=", collapse = "\u001f"), algo = "sha1", serialize = FALSE)
  }
  stats::setNames(out, df[[".id"]])
}

.mig077_row_sha <- function(con, hashes) {
  out <- stats::setNames(rep(NA_character_, length(hashes)), hashes)
  if (!length(hashes)) return(out)
  s <- .mig077_df_sha(.mig077_rows(con, hashes))
  out[names(s)] <- s
  out[hashes]
}

# ---- locating a file (stat only) ---------------------------------------------------------

# "orig" | "emails" | "missing", and the path. The inbox files a folder to
# <archive_dir>/_emails/<basename>[ (n)] (.inbox_file_folder()).
.mig077_locate <- function(path_first_seen, filename) {
  if (file.exists(path_first_seen)) return(list(location = "orig", path = path_first_seen))
  root <- file.path(.mig077_assets(), "processed", "_emails")
  base <- basename(dirname(path_first_seen))
  for (n in 1:20) {
    p <- file.path(root, if (n == 1L) base else sprintf("%s (%d)", base, n), filename)
    if (file.exists(p)) return(list(location = "emails", path = p))
  }
  list(location = "missing", path = NA_character_)
}

.mig077_path_for <- function(path_first_seen, filename, location) {
  if (identical(location, "orig")) return(path_first_seen)
  if (!identical(location, "emails")) return(NA_character_)
  .mig077_locate(path_first_seen, filename)$path
}

# ---- the importer's decision -------------------------------------------------------------

# VERBATIM from .ig_retain_siblings() (R/ingest.R), which computes it inline.
.mig077_gate <- function(filename) {
  gated <- grepl("(?i)_(coa|coc|qc|qci|xtab)\\b|_srn_[0-9]", filename, perl = TRUE) |
    .ig_is_acirl_shaped(filename)
  extra_pdf <- grepl("\\.pdf$", filename, ignore.case = TRUE) & !gated
  list(gated = gated, extra_pdf = extra_pdf)
}

# Why a folder / stem did not resolve (for the reason text only; the decision is the helpers').
.mig077_why_unresolved <- function(con, routed, path, is_extra) {
  same <- which(dirname(routed$path) == dirname(path))
  wos <- unique(stats::na.omit(vapply(routed$filename[same], function(fn) .st_guess_work_order_revision(fn)$work_order_guess,
                                      character(1), USE.NAMES = FALSE)))
  if (length(wos) > 1) return(sprintf("ambiguous: folder holds %d ALS work orders%s", length(wos),
                                      if (is_extra) "" else "; no archived workbook shares the stem"))
  if (length(wos) == 1) return(sprintf("no work order: folder's %s has no project", wos[[1]]))
  h <- unique(stats::na.omit(routed$hash[same]))
  pj <- if (length(h)) unique(stats::na.omit(DBI::dbGetQuery(con, sprintf(
    "SELECT DISTINCT p.name FROM asset a JOIN project p ON p.uuid = a.uuid_project WHERE a.hash IN %s",
    .mig077_inlist(h)))$name)) else character()
  f <- if (length(pj) > 1) sprintf("folder ambiguous (%d projects)", length(pj)) else "folder resolves to no project"
  if (is_extra) return(paste0("no work order: scanned PDF, ", f))
  stem <- function(x) tolower(trimws(tools::file_path_sans_ext(basename(x))))
  a <- DBI::dbGetQuery(con, "SELECT a.filename, p.name FROM asset a JOIN project p ON p.uuid = a.uuid_project
                               WHERE a.filename IS NOT NULL")
  sp <- unique(a$name[vapply(a$filename, stem, "", USE.NAMES = FALSE) == stem(path)])
  if (length(sp) > 1) return(sprintf("ambiguous: stem matches %d projects; %s", length(sp), f))
  paste0("no work order: no ES token, ", f, ", no archived workbook shares the stem")
}

# One pass: one plan row per unclaimed ingest_file row, against whatever `asset` resolves to
# (main.asset, or the temp.asset overlay mig077_plan_con() builds). Read-only; stat() only.
.mig077_plan_pass <- function(con) {
  all_if <- DBI::dbGetQuery(con, "SELECT hash, filename, path_first_seen, state, state_reason FROM ingest_file")
  all_if$dir <- dirname(all_if$path_first_seen)
  x <- DBI::dbGetQuery(con, "SELECT hash, filename, path_first_seen FROM ingest_file
                              WHERE state = 'quarantined' AND state_reason = 'unclaimed'
                              ORDER BY path_first_seen, filename")
  assets <- DBI::dbGetQuery(con, "SELECT filename FROM asset WHERE filename IS NOT NULL")$filename
  out <- vector("list", nrow(x))
  for (i in seq_len(nrow(x))) {
    fn <- x$filename[[i]]; pfs <- x$path_first_seen[[i]]; h <- x$hash[[i]]
    loc <- .mig077_locate(pfs, fn)
    r <- list(hash = h, filename = fn, folder = basename(dirname(pfs)), location = loc$location,
              outcome = "leave", project = NA_character_, type = NA_character_, reason = NA_character_)
    g <- .mig077_gate(fn)
    if (grepl(.mig077_corpus_run, pfs, fixed = TRUE)) {
      r$reason <- "not a candidate: corpus-import leftover (data-shaped)"
    } else if (grepl("^_email\\.eml", fn)) {
      r$reason <- "not a candidate: email (R-22.E records it)"
    } else if (grepl("^Prelim ", fn)) {
      final <- sub("^Prelim ", "", fn)
      if (any(trimws(assets) == trimws(final))) {
        r$outcome <- "ignore"; r$reason <- sprintf("superseded_prelim: final '%s' is an asset", final)
      } else {
        r$reason <- "prelim: no final asset yet"
      }
    } else if (!(g$gated || g$extra_pdf)) {
      r$reason <- "not a candidate: not a deliverable shape (image/other)"
    } else {
      routed <- tibble::tibble(path = all_if$path_first_seen, filename = all_if$filename, hash = all_if$hash,
                               state = all_if$state, reason = all_if$state_reason)[all_if$dir == dirname(pfs), ]
      is_extra <- isTRUE(g$extra_pdf)
      wo <- .st_guess_work_order_revision(fn)$work_order_guess
      if (is.na(wo)) wo <- .ig_folder_work_order(con, routed, pfs)
      if (is.na(wo) && !is_extra) wo <- suppressWarnings(.ig_stem_work_order(con, pfs, h))
      if (is.na(wo)) {
        r$reason <- .mig077_why_unresolved(con, routed, pfs, is_extra)
      } else {
        n_proj <- .mig077_scalar(con, "SELECT COUNT(*) FROM project WHERE name = ?", wo)
        if (n_proj == 0L) {
          r$project <- wo; r$reason <- "no project: work order has no project row (never minted)"
          if (loc$location == "missing") r$reason <- paste0(r$reason, "; file missing")
        } else if (n_proj > 1L) {
          r$project <- wo; r$reason <- sprintf("ambiguous: %d project rows named %s", n_proj, wo)
        } else if (loc$location == "missing") {
          r$project <- wo; r$reason <- "file missing"
          if (.mig077_scalar(con, "SELECT COUNT(*) FROM asset WHERE hash = ?", h) > 0L)
            r$reason <- "file missing (its bytes are already an asset; the importer skips a missing file)"
        } else {
          r$outcome <- "retain"; r$project <- wo
          r$type <- if (is_extra) "QA" else .ig_retained_asset_type(fn)
          r$reason <- if (is_extra) "scanned PDF: folder inference" else "deliverable"
          if (.mig077_scalar(con, "SELECT COUNT(*) FROM asset WHERE hash = ?", h) > 0L)
            r$reason <- paste0(r$reason, "; asset with this hash already exists")
        }
      }
    }
    out[[i]] <- r
  }
  do.call(rbind, lapply(out, as.data.frame, stringsAsFactors = FALSE))
}

# The plan, iterated to a FIXPOINT (coordinator 2026-10-25). The importer's single pass misses
# a scanned sheet whose folder's only resolvable file is a PDF retained in the same pass (a
# split delivery: the workbook was ingested from another path, so the folder holds no
# committed file). Each further pass treats every planned retain so far as committed - a
# TEMP `asset` row (shadowing main.asset for the unqualified queries the importer's helpers
# make) carrying the file's hash, filename, type and planned project - and adopts any row
# that now resolves; it stops when a pass adds nothing. Earlier decisions are never revised.
# temp.asset is dropped on exit, before anything writes.
mig077_plan_con <- function(con) {
  on.exit(DBI::dbExecute(con, "DROP TABLE IF EXISTS temp.asset"), add = TRUE)
  p <- .mig077_plan_pass(con)
  k <- 1L
  repeat {
    r <- p[p$outcome == "retain", , drop = FALSE]
    DBI::dbExecute(con, "DROP TABLE IF EXISTS temp.asset")
    DBI::dbExecute(con, "CREATE TEMP TABLE asset AS SELECT * FROM main.asset")
    for (i in seq_len(nrow(r))) {
      n <- DBI::dbExecute(con, "INSERT INTO temp.asset (uuid, filename, hash, type, uuid_project)
                                SELECT ?, ?, ?, ?, uuid FROM main.project WHERE name = ?",
                          params = list(paste0("mig077-overlay-", r$hash[[i]]), r$filename[[i]], r$hash[[i]],
                                        r$type[[i]], r$project[[i]]))
      if (n != 1L) .mig077_fail(sprintf("fixpoint overlay: project %s does not resolve once.", r$project[[i]]))
    }
    k <- k + 1L
    q <- .mig077_plan_pass(con)
    q <- q[match(p$hash, q$hash), , drop = FALSE]
    new <- which(p$outcome == "leave" & q$outcome != "leave")
    if (!length(new)) break
    q$reason[new] <- paste0(q$reason[new], sprintf(" (fixpoint pass %d: resolved via a planned retain)", k))
    p[new, ] <- q[new, ]
  }
  p$gid <- sprintf("F%02d", seq_len(nrow(p)))
  p$row_sha1 <- unname(.mig077_row_sha(con, p$hash))
  p[, .mig077_cols]
}

mig077_plan <- function(db) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  .mig077_ensure_icu(con)
  mig077_plan_con(con)
}

mig077_freeze <- function(db, input_dir = "dev/migrations") {
  p <- mig077_plan(db)
  utils::write.csv(p, file.path(input_dir, sprintf("%s-INPUT.csv", .mig077_name)), row.names = FALSE, na = "",
                   fileEncoding = "UTF-8")
  invisible(p)
}

.mig077_read_inputs <- function(input_dir = "dev/migrations") {
  p <- file.path(input_dir, sprintf("%s-INPUT.csv", .mig077_name))
  if (!file.exists(p)) .mig077_fail(sprintf("input %s not found.", p))
  x <- utils::read.csv(p, colClasses = "character", na.strings = "", encoding = "UTF-8")
  if (!identical(names(x), .mig077_cols)) .mig077_fail("INPUT columns are not as planned.")
  if (anyNA(x$hash) || anyNA(x$gid) || anyNA(x$row_sha1) || anyDuplicated(x$hash) || anyDuplicated(x$gid))
    .mig077_fail("INPUT misses or repeats a hash / gid / sha.")
  if (!all(x$outcome %in% c("retain", "ignore", "leave"))) .mig077_fail("INPUT has an unknown outcome.")
  r <- x$outcome == "retain"
  if (anyNA(x$project[r]) || anyNA(x$type[r]) || !all(x$location[r] %in% c("orig", "emails")))
    .mig077_fail("INPUT retain row lacks a project / type / location.")
  if (any(x$type[r] == "QC")) .mig077_fail("INPUT retains a QC report: lab_qc_ingest() is not wired into this migration.")
  x
}

# ---- preconditions -----------------------------------------------------------------------

# Named list gid -> problems; the touched (retain/ignore) groups only. Reads the bytes of the
# files to be retained (hash check) and of nothing else.
.mig077_problems <- function(con, x) {
  have <- DBI::dbGetQuery(con, "SELECT version FROM schema_version")$version
  miss <- setdiff(.mig077_requires, have)
  if (length(miss)) .mig077_fail(sprintf("marker(s) %s required first.", paste(miss, collapse = ", ")))
  t <- x[x$outcome != "leave", , drop = FALSE]
  s <- .mig077_row_sha(con, t$hash)
  now <- mig077_plan_con(con)
  pr <- list()
  add <- function(g, m) pr[[g]] <<- c(pr[[g]], m)
  for (i in seq_len(nrow(t))) {
    g <- t$gid[[i]]; h <- t$hash[[i]]
    if (is.na(s[[h]]) || s[[h]] != t$row_sha1[[i]]) { add(g, "ingest_file row missing or not as frozen"); next }
    n <- now[now$hash == h, , drop = FALSE]
    keep <- setdiff(.mig077_cols, c("gid", "row_sha1"))
    same <- nrow(n) == 1 && identical(vapply(keep, function(k) paste(n[[k]][[1]]), ""),
                                      vapply(keep, function(k) paste(t[[k]][[i]]), ""))
    if (!same) { add(g, "re-derived plan differs from the frozen plan"); next }
    if (t$outcome[[i]] == "retain") {
      row <- DBI::dbGetQuery(con, "SELECT path_first_seen FROM ingest_file WHERE hash = ?", params = list(h))
      p <- .mig077_path_for(row$path_first_seen[[1]], t$filename[[i]], t$location[[i]])
      if (is.na(p) || !file.exists(p)) { add(g, "file not where the INPUT says"); next }
      if (!identical(hash_file(p), h)) add(g, "file bytes no longer hash to ingest_file.hash")
      if (.mig077_scalar(con, "SELECT COUNT(*) FROM project WHERE name = ?", t$project[[i]]) != 1L)
        add(g, "project does not exist exactly once")
      # archive_file()'s dedupe path (reuse an existing asset) is not planned for: the counts
      # assume one new asset per retain, so an existing asset skips the group.
      if (.mig077_scalar(con, "SELECT COUNT(*) FROM asset WHERE hash = ?", h) > 0L)
        add(g, "an asset already holds this hash")
    }
  }
  pr
}

.mig077_skipped_df <- function(pr) {
  if (!length(pr)) return(data.frame(gid = character(), problem = character(), stringsAsFactors = FALSE))
  data.frame(gid = names(pr), problem = vapply(pr, function(p) paste(unique(p), collapse = "; "), ""),
             stringsAsFactors = FALSE)
}

# ---- verify ------------------------------------------------------------------------------

.mig077_done_problem <- function(con, x, archive_dir, n_retain, n_ignore) {
  if (.mig077_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig077_marker_version) != 1L)
    return("marker 1077 missing")
  r <- x[x$outcome == "retain", , drop = FALSE]
  for (i in seq_len(nrow(r))) {
    a <- DBI::dbGetQuery(con, "SELECT a.uuid, a.filename, a.type, p.name FROM asset a JOIN project p ON p.uuid = a.uuid_project
                                WHERE a.hash = ?", params = list(r$hash[[i]]))
    if (nrow(a) != 1L || a$name[[1]] != r$project[[i]] || a$type[[1]] != r$type[[i]] || a$filename[[1]] != r$filename[[i]])
      return(sprintf("%s: asset row not as planned", r$gid[[i]]))
    f <- file.path(archive_dir, a$uuid[[1]], a$filename[[1]])
    if (!file.exists(f) || !identical(hash_file(f), r$hash[[i]])) return(sprintf("%s: archived copy missing or wrong", r$gid[[i]]))
    st <- DBI::dbGetQuery(con, "SELECT state, state_reason FROM ingest_file WHERE hash = ?", params = list(r$hash[[i]]))
    if (!identical(c(st$state, st$state_reason), c("archived", "retained_sibling"))) return(sprintf("%s: state not archived", r$gid[[i]]))
  }
  g <- x[x$outcome == "ignore", , drop = FALSE]
  for (i in seq_len(nrow(g))) {
    st <- DBI::dbGetQuery(con, "SELECT state, state_reason FROM ingest_file WHERE hash = ?", params = list(g$hash[[i]]))
    if (!identical(c(st$state, st$state_reason), c("ignored", "superseded_prelim"))) return(sprintf("%s: state not ignored", g$gid[[i]]))
  }
  L <- DBI::dbGetQuery(con, "SELECT tbl, action, field, count(*) AS n FROM change_log WHERE actor = ? GROUP BY ALL ORDER BY ALL",
                       params = list(.mig077_actor))
  want <- (n_retain + n_ignore)
  if (!all(L$tbl == "ingest_file") || !all(L$action == "update") || !setequal(L$field, c("state", "state_reason", "updated_at")) ||
      !all(L$n == want)) return("077 change_log transition rows are not as planned")
  ah <- .mig077_scalar(con, sprintf("SELECT COUNT(*) FROM change_log WHERE actor = 'ingest' AND tbl = 'asset' AND action = 'insert'
                                     AND reason = 'archive source file' AND source_hash IN %s", .mig077_inlist(r$hash)))
  if (nrow(r) && ah != n_retain) return(sprintf("%d asset insert change_log rows, not %d", ah, n_retain))
  NULL
}

.mig077_counts <- function(con) {
  tabs <- c("analysis", "sample", "feature", "lab_method", "analyte", "asset", "ingest_file", "ingest_sighting",
            "project", "review_queue", "lab_qc_report", "change_log", "schema_version")
  stats::setNames(lapply(tabs, function(t) .mig077_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
}

.mig077_checksum <- function(con, touched_hashes) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  tabs <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  touched <- c("asset", "ingest_file", "change_log", "schema_version")
  out <- lapply(setdiff(tabs, touched), function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- setdiff(tabs, touched)
  h <- .mig077_inlist(touched_hashes)
  out$asset_rest <- q(sprintf("SELECT * FROM asset WHERE hash IS NULL OR hash NOT IN %s ORDER BY ALL", h))
  out$ingest_file_rest <- q(sprintf("SELECT * FROM ingest_file WHERE hash NOT IN %s ORDER BY ALL", h))
  out$change_log_rest <- q(sprintf("SELECT * FROM change_log WHERE actor <> '%s' AND NOT (actor = 'ingest' AND tbl = 'asset'
                                    AND source_hash IN %s) ORDER BY uuid", .mig077_actor, h))
  out$schema_version_rest <- q(sprintf("SELECT * FROM schema_version WHERE version <> %d ORDER BY ALL", .mig077_marker_version))
  out$indexes <- q("SELECT index_name, sql FROM duckdb_indexes() ORDER BY index_name")
  out$views <- q("SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
  out
}

.mig077_checks_problem <- function(before, after) {
  for (i in seq_len(nrow(after))) {
    nm <- after$name[[i]]
    b <- before[before$name == nm, , drop = FALSE]
    if (after$status[[i]] == "error") {
      if (!nrow(b) || b$status[[1]] != "error") return(sprintf("check %s now errors: %s", nm, after$message[[i]]))
      next
    }
    added <- setdiff(after$keys[[i]], if (nrow(b)) b$keys[[1]] else character())
    if (length(added)) return(sprintf("check %s gains offender(s) %s", nm, paste(utils::head(added, 3), collapse = ", ")))
  }
  NULL
}

# ---- apply -------------------------------------------------------------------------------

.mig077_apply <- function(con, x, archive_dir, recorded_at, logf) {
  r <- x[x$outcome == "retain", , drop = FALSE]
  g <- x[x$outcome == "ignore", , drop = FALSE]
  copies <- data.frame(gid = character(), hash = character(), uuid_asset = character(), filename = character(),
                       stringsAsFactors = FALSE)
  db_transaction(con, function(con) {
    baseline <- db_checks(con, tier = "migration")
    before_all <- db_checks(con, tier = "all")
    sums_before <- .mig077_checksum(con, c(r$hash, g$hash))
    counts_want <- .mig077_counts(con)
    counts_want$asset <- counts_want$asset + nrow(r)
    counts_want$change_log <- counts_want$change_log + nrow(r) + 3L * (nrow(r) + nrow(g))
    counts_want$schema_version <- counts_want$schema_version + 1L
    transition <- function(h, state, why, gid) {
      db_update(con, "ingest_file", key = list(hash = h),
                changes = list(state = state, state_reason = why, updated_at = recorded_at),
                actor = .mig077_actor, reason = sprintf("%s [%s]", .mig077_reason, gid))
    }
    for (i in seq_len(nrow(r))) {
      pfs <- DBI::dbGetQuery(con, "SELECT path_first_seen FROM ingest_file WHERE hash = ?", params = list(r$hash[[i]]))$path_first_seen
      p <- .mig077_path_for(pfs, r$filename[[i]], r$location[[i]])
      # .ig_retain_siblings()'s inner transaction: archive_file() + the terminal transition.
      db_transaction(con, function(con) {
        u <- archive_file(con, p, r$hash[[i]], event = list(work_order = r$project[[i]]), type = r$type[[i]])
        transition(r$hash[[i]], "archived", "retained_sibling", r$gid[[i]])
        copies[nrow(copies) + 1L, ] <<- list(r$gid[[i]], r$hash[[i]], u, r$filename[[i]])
      })
    }
    for (i in seq_len(nrow(g))) transition(g$hash[[i]], "ignored", "superseded_prelim", g$gid[[i]])
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig077_marker_version, recorded_at))
    pr <- .mig077_done_problem(con, x, archive_dir, nrow(r), nrow(g))
    if (!is.null(pr)) .mig077_fail(paste0("verify failed: ", pr))
    if (!identical(.mig077_counts(con), counts_want)) .mig077_fail("table counts are not as planned.")
    if (!identical(sums_before, .mig077_checksum(con, c(r$hash, g$hash)))) .mig077_fail("something outside the planned rows moved.")
    mig_db_checks_gate(con, baseline)
    after_all <- db_checks(con, tier = "all")
    pr <- .mig077_checks_problem(before_all, after_all)
    if (!is.null(pr)) .mig077_fail(paste0("standing checks: ", pr))
    logf("Retained %d file(s) as assets, ignored %d prelim(s); %d left untouched.", nrow(r), nrow(g),
         sum(x$outcome == "leave"))
    NULL
  })
  copies
}

# ---- backups, files ----------------------------------------------------------------------

mig077_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- if (is.null(.now)) Sys.time() else .now
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig077_name, ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig077_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig077_counts(verify_con)))
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  dest
}

.mig077_write_csv <- function(df, path, key) {
  utils::write.csv(df, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8", colClasses = "character")
  if (nrow(back) != nrow(df) || (nrow(df) && !identical(back[[key]], as.character(df[[key]]))))
    cli::cli_abort("077: CSV {basename(path)} did not round-trip.", class = "sampletidy_error")
}

.mig077_csv <- function(csv_dir, what) file.path(csv_dir, sprintf("%s-%s.csv", .mig077_name, what))

.mig077_read_skipped <- function(csv_dir) {
  f <- .mig077_csv(csv_dir, "SKIPPED")
  if (!file.exists(f)) return(NULL)
  utils::read.csv(f, colClasses = "character", na.strings = "", encoding = "UTF-8")
}

# ---- run ---------------------------------------------------------------------------------

mig077_run <- function(db, snapshot_dir, archive_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL,
                       input_dir = "dev/migrations") {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  checkmate::assert_directory_exists(archive_dir)
  withr::local_options(sampletidy.archive_dir = archive_dir)
  if (!identical(st_config("archive_dir"), archive_dir)) .mig077_fail("archive_dir did not take.")
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir
  x0 <- .mig077_read_inputs(input_dir)

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                                   params = list(.mig077_marker_version)),
                   finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    sk <- .mig077_read_skipped(csv_dir)
    if (is.null(sk)) .mig077_fail(sprintf("marker present but %s is missing: cannot re-verify.", .mig077_csv(csv_dir, "SKIPPED")))
    x <- x0[!x0$gid %in% sk$gid, , drop = FALSE]
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch({
      pr <- .mig077_done_problem(check_con, x, archive_dir, sum(x$outcome == "retain"), sum(x$outcome == "ignore"))
      if (!is.null(pr)) .mig077_fail(paste0("re-verify: ", pr))
    }, finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("077 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_, restore_command = NA_character_,
                          recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  problems <- tryCatch({
    if (.mig077_scalar(pre_con, "SELECT COUNT(*) FROM change_log WHERE actor = ?", .mig077_actor) > 0L)
      .mig077_fail("change_log already holds 077 rows but the marker is absent; refusing.")
    .mig077_ensure_icu(pre_con)
    .mig077_problems(pre_con, x0)
  }, finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  skipped <- .mig077_skipped_df(problems)
  x <- x0[!x0$gid %in% skipped$gid, , drop = FALSE]
  logf("Plan: retain %d, ignore %d, leave %d; %d group(s) skipped.", sum(x$outcome == "retain"),
       sum(x$outcome == "ignore"), sum(x0$outcome == "leave"), nrow(skipped))
  for (i in seq_len(nrow(skipped))) logf("SKIP %s: %s", skipped$gid[[i]], skipped$problem[[i]])
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition checked. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_, restore_command = NA_character_, recorded_at = NA)))
  }

  bk_con <- st_connect(db, read_only = TRUE)
  tryCatch({
    .mig077_write_csv(.mig077_rows(bk_con, x$hash[x$outcome != "leave"]), .mig077_csv(csv_dir, "BACKUP-ingest_file"), ".id")
    .mig077_write_csv(skipped, .mig077_csv(csv_dir, "SKIPPED"), "gid")
  }, finally = DBI::dbDisconnect(bk_con, shutdown = TRUE))
  logf("Row backup and the SKIPPED plan written to %s", csv_dir)
  backup_path <- mig077_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s (and delete the <archive_dir>/<uuid_asset>/ dirs in the BACKUP-copies CSV)", restore_command)
  recorded_at <- if (is.null(.now)) Sys.time() else .now

  copies <- with_db_write(function(con) {
    .mig077_ensure_icu(con)
    again <- .mig077_problems(con, x)
    if (length(again)) .mig077_fail("a precondition changed since the dry check; re-run.")
    .mig077_apply(con, x, archive_dir, recorded_at, logf)
  }, db = db)
  .mig077_write_csv(copies, .mig077_csv(csv_dir, "BACKUP-copies"), "gid")

  logf("%s migrated successfully (marker %d).", .mig077_name, .mig077_marker_version)
  invisible(list(status = "migrated", backup_path = backup_path, restore_command = restore_command,
                 recorded_at = recorded_at))
}
