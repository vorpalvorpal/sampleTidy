# REHEARSED, NOT APPLIED (rehearsed 2026-10-25 on a plain-cp copy of live at marker 1077). See
# dev/MIGRATIONS.md row 1078.
# Operator-run migration: record the delivery emails of past imports (R-22.E backfill).
# Marker 1078. Requires 1077.
#
# Authority: Robin, 2026-10-25 (R-22.E: the delivering email is recorded in `ingest_email`,
# not attached as an asset; `ingest_file.message_id` links each file to it).
#
# ---- WHY ------------------------------------------------------------------------------
# Before R-22.E every delivery folder's `_email.eml` was routed like any other file and
# (having no adapter) sat in quarantined/unclaimed. R-22.E records the email's identity at
# import time; this does the same once for the imports that already happened.
#
# ---- WHAT (frozen in 078-record-delivery-emails-INPUT.csv) ------------------------------
# For every ingest_file row whose path_first_seen basename is `_email.eml` (the stored
# `filename` may carry a `__dupN` suffix; the path is what counts), any state:
#   * locate the file with stat() only: at path_first_seen, else at
#     <assets>/processed/_emails/<basename(dirname(path_first_seen))>[ (n)]/_email.eml
#     (the inbox's own filing, .inbox_file_folder()). Neither -> LEAVE, "email file missing".
#   * read ONLY the header block, with email_headers() (R/ingest-email.R; never the body).
#     No header block / no Message-ID -> LEAVE, "email unreadable".
#   * a readable email RECORDS, as R-22.E's .ig_record_delivery_email() does for a live import:
#       - one `ingest_email` row (db_append; folder = basename of the delivery folder,
#         first_seen_at = the _email.eml row's first_seen_at, the header fields as
#         email_headers() returns them). First sighting wins: when several rows name the
#         same Message-ID the earliest first_seen_at (then hash) inserts it, the rest do
#         not; a Message-ID already in ingest_email is never inserted again.
#       - ingest_file.message_id set (db_update) on every row whose dirname(path_first_seen)
#         is that delivery folder, WHERE it is still NULL (fills NULL only, as
#         ingest_file_set_message_id()).
#       - the `_email.eml` row -> state 'ignored', reason 'delivery_email' (what the router's
#         ignore_rule() decides for it today; R-22.E's reconsider path reaches the same
#         verdict through ingest_file_set_state(reset = TRUE)). A terminal-state change, so
#         done through db_update (as 077 did quarantined -> archived/ignored) and logged. A
#         row already ignored/delivery_email is not changed; one in a state other than
#         quarantined/seen/failed/ignored is LEFT ("not re-decided").
#   * two DIFFERENT _email.eml hashes in one delivery folder -> both LEFT and REPORTED.
#   * an `_email.eml` row whose message_id is already set to a different email -> LEFT.
# The INPUT holds ingest_file hashes, folder basenames and Message-IDs ONLY. The sender,
# sender name and subject exist in the DB (ingest_email) and nowhere in this repo.
#
# change_log: ingest_email inserts are actor '078-record-delivery-emails', reason
# "R-22.E: delivering email <message_id>" (exactly R-22.E's); ingest_file updates carry the
# 078 reason and the group id.
#
# ---- SCHEMA ---------------------------------------------------------------------------
# Live may still be at ensure_schema version 8 (no ingest_email, no ingest_file.message_id)
# until its next import. The run calls ensure_schema(con) itself, AFTER the verified
# snapshot, so it works whether or not an import ran first. The planner/dry run are
# read-only and work on either schema (a missing column reads as all-NULL, a missing table
# as empty); the row sha1 covers the version-8 ingest_file columns only, so it is the same
# before and after ensure_schema.
#
# ---- CHECKS ---------------------------------------------------------------------------
#   Before, per group (a failing guard SKIPS the group, SKIPPED CSV): marker 1077 present;
#   every touched ingest_file row byte for byte as frozen (sha1); a re-derived plan (the
#   headers are re-read) equals the frozen one; the Message-ID in the file is the frozen one.
#   Inside ONE transaction: baseline <- db_checks(con, "migration"); all-tier checks before;
#   whole-table checksums of everything outside the planned rows; the writes; marker 1078;
#   verify (rows, change_log, counts); the checksums again; mig_db_checks_gate(con,
#   baseline); no all-tier check gains an offender key; ingest_file_email_dangling passes.
# Backups: verified whole-file snapshot (before ensure_schema); BACKUP CSV of every touched
# ingest_file row (full version-8 row). Idempotent: marker present -> re-verify, no-op.
#
# Use:
#   env <- new.env(); sys.source("dev/migrations/078-record-delivery-emails.R", envir = env)
#   env$mig078_plan(db = ...)          # prints/returns the plan (read-only)
#   env$mig078_freeze(db = ...)        # writes the INPUT csv from the plan
#   env$mig078_run(db = ..., snapshot_dir = ..., dry_run = TRUE)

.mig078_marker_version <- 1078L
.mig078_requires <- 1077L
.mig078_name <- "078-record-delivery-emails"
.mig078_actor <- .mig078_name
.mig078_reason <- "078 (Robin 2026-10-25: R-22.E delivering emails backfilled for past imports)"
.mig078_assets_default <- "/Users/rjs/Library/CloudStorage/OneDrive-BlueMountainsCityCouncil/Sharepoint/waste_data - Environmental monitoring/assets"
.mig078_cols <- c("gid", "hash", "role", "folder", "location", "message_id", "eml_hash", "outcome",
                  "stamp", "transition", "reason", "row_sha1")
# The version-8 ingest_file columns: the row sha1 must not move when ensure_schema adds message_id.
.mig078_v8_cols <- c("hash", "filename", "path_first_seen", "size", "first_seen_at", "updated_at", "state",
                     "state_reason", "adapter", "tier", "work_order", "revision", "org", "uuid_asset",
                     "registry_fingerprint")
.mig078_terminal_ok <- c("quarantined", "seen", "failed", "ignored")

.mig078_fail <- function(msg) cli::cli_abort(paste0(.mig078_name, ": ", msg), class = "sampletidy_error")
.mig078_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = if (length(list(...))) list(...) else NULL)[[1]][[1]])
.mig078_inlist <- function(x) if (!length(x)) "('')" else paste0("(", paste0("'", gsub("'", "''", unique(x)), "'", collapse = ","), ")")
.mig078_assets <- function() Sys.getenv("SAMPLETIDY_MIG078_ASSETS_DIR", unset = .mig078_assets_default)

.mig078_ensure_icu <- function(con) {
  DBI::dbExecute(con, "INSTALL icu")
  DBI::dbExecute(con, "LOAD icu")
  invisible(NULL)
}

.mig078_has_message_id <- function(con) "message_id" %in% DBI::dbListFields(con, "ingest_file")
.mig078_has_email_tbl <- function(con) DBI::dbExistsTable(con, "ingest_email")

# ---- rows, sha1 -------------------------------------------------------------------------

.mig078_rows <- function(con, hashes) {
  DBI::dbGetQuery(con, sprintf('SELECT hash AS ".id", %s FROM ingest_file WHERE hash IN %s ORDER BY hash',
                               paste(.mig078_v8_cols, collapse = ", "), .mig078_inlist(hashes)))
}

.mig078_df_sha <- function(df) {
  out <- character(nrow(df))
  cols <- setdiff(names(df), ".id")
  for (i in seq_len(nrow(df))) {
    v <- vapply(cols, function(f) { s <- .st_changelog_str(df[[f]][i]); if (is.na(s)) "<NA>" else s }, "")
    out[[i]] <- digest::digest(paste(cols, v, sep = "=", collapse = "\u001f"), algo = "sha1", serialize = FALSE)
  }
  stats::setNames(out, df[[".id"]])
}

.mig078_row_sha <- function(con, hashes) {
  out <- stats::setNames(rep(NA_character_, length(hashes)), hashes)
  if (!length(hashes)) return(out)
  s <- .mig078_df_sha(.mig078_rows(con, hashes))
  out[names(s)] <- s
  out[hashes]
}

# ---- locating a file (stat only) ---------------------------------------------------------

.mig078_locate <- function(path_first_seen) {
  if (file.exists(path_first_seen)) return(list(location = "orig", path = path_first_seen))
  root <- file.path(.mig078_assets(), "processed", "_emails")
  base <- basename(dirname(path_first_seen))
  for (n in 1:20) {
    p <- file.path(root, if (n == 1L) base else sprintf("%s (%d)", base, n), "_email.eml")
    if (file.exists(p)) return(list(location = "emails", path = p))
  }
  list(location = "missing", path = NA_character_)
}

.mig078_path_for <- function(path_first_seen, location) {
  if (identical(location, "orig")) return(path_first_seen)
  if (!identical(location, "emails")) return(NA_character_)
  .mig078_locate(path_first_seen)$path
}

# ---- the plan ----------------------------------------------------------------------------

# One row per touched ingest_file row (the _email.eml row, role "eml", and each other row of
# its delivery folder still lacking a message_id, role "member"). Read-only; stat() and header
# reads only. Works on a version-8 or version-9 schema.
mig078_plan_con <- function(con) {
  has_mid <- .mig078_has_message_id(con)
  all_if <- DBI::dbGetQuery(con, sprintf(
    "SELECT hash, path_first_seen, state, state_reason, first_seen_at, %s AS message_id FROM ingest_file",
    if (has_mid) "message_id" else "CAST(NULL AS VARCHAR)"))
  all_if$dir <- dirname(all_if$path_first_seen)
  have_ids <- if (.mig078_has_email_tbl(con)) DBI::dbGetQuery(con, "SELECT message_id FROM ingest_email")$message_id else character()

  eml <- all_if[basename(all_if$path_first_seen) == "_email.eml", , drop = FALSE]
  eml <- eml[order(eml$first_seen_at, eml$hash), , drop = FALSE]
  out <- list()
  k <- 0L
  for (d in unique(eml$dir)) {
    k <- k + 1L
    gid <- sprintf("E%02d", k)
    e <- eml[eml$dir == d, , drop = FALSE]
    mk <- function(r, role, loc, mid, eh, outcome, stamp, tr, why) {
      data.frame(gid = gid, hash = r$hash, role = role, folder = basename(d), location = loc,
                 message_id = mid, eml_hash = eh, outcome = outcome, stamp = stamp, transition = tr,
                 reason = why, stringsAsFactors = FALSE)
    }
    leave <- function(why, loc = NA_character_) {
      do.call(rbind, lapply(seq_len(nrow(e)), function(i) mk(e[i, ], "eml", loc, NA_character_, e$hash[[i]], "leave", FALSE, FALSE, why)))
    }
    if (nrow(e) > 1L) {
      out[[length(out) + 1L]] <- leave(sprintf("two different _email.eml hashes in the delivery folder (%d)", nrow(e)))
      next
    }
    e <- e[1, , drop = FALSE]
    loc <- .mig078_locate(e$path_first_seen)
    if (loc$location == "missing") {
      out[[length(out) + 1L]] <- leave("email file missing", "missing")
      next
    }
    h <- email_headers(loc$path)
    if (is.null(h)) {
      out[[length(out) + 1L]] <- leave("email unreadable: no header block or no Message-ID", loc$location)
      next
    }
    if (!is.na(e$message_id) && !identical(e$message_id, h$message_id)) {
      out[[length(out) + 1L]] <- leave("ingest_file.message_id already names a different email", loc$location)
      next
    }
    if (!(e$state %in% .mig078_terminal_ok)) {
      out[[length(out) + 1L]] <- leave(sprintf("state %s is not re-decided", e$state), loc$location)
      next
    }
    already <- identical(e$state, "ignored") && identical(e$state_reason, "delivery_email")
    rows <- list(mk(e, "eml", loc$location, h$message_id, e$hash, "record", is.na(e$message_id), !already, "record"))
    m <- all_if[all_if$dir == d & all_if$hash != e$hash & is.na(all_if$message_id), , drop = FALSE]
    m <- m[order(m$hash), , drop = FALSE]
    for (i in seq_len(nrow(m))) {
      rows[[length(rows) + 1L]] <- mk(m[i, ], "member", loc$location, h$message_id, e$hash, "record", TRUE, FALSE, "record")
    }
    out[[length(out) + 1L]] <- do.call(rbind, rows)
  }
  p <- if (length(out)) do.call(rbind, out) else
    stats::setNames(data.frame(matrix(character(), 0, length(.mig078_cols) - 1L)), setdiff(.mig078_cols, "row_sha1"))
  p$row_sha1 <- unname(.mig078_row_sha(con, p$hash))
  rownames(p) <- NULL
  attr(p, "have_ids") <- have_ids
  p[, .mig078_cols]
}

mig078_plan <- function(db) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  .mig078_ensure_icu(con)
  mig078_plan_con(con)
}

mig078_freeze <- function(db, input_dir = "dev/migrations") {
  p <- mig078_plan(db)
  attr(p, "have_ids") <- NULL
  utils::write.csv(p, file.path(input_dir, sprintf("%s-INPUT.csv", .mig078_name)), row.names = FALSE, na = "",
                   fileEncoding = "UTF-8")
  invisible(p)
}

.mig078_read_inputs <- function(input_dir = "dev/migrations") {
  p <- file.path(input_dir, sprintf("%s-INPUT.csv", .mig078_name))
  if (!file.exists(p)) .mig078_fail(sprintf("input %s not found.", p))
  x <- utils::read.csv(p, colClasses = "character", na.strings = "", encoding = "UTF-8")
  if (!identical(names(x), .mig078_cols)) .mig078_fail("INPUT columns are not as planned.")
  if (anyNA(x$hash) || anyNA(x$gid) || anyNA(x$row_sha1) || anyDuplicated(x$hash))
    .mig078_fail("INPUT misses or repeats a hash / gid / sha.")
  if (!all(x$outcome %in% c("record", "leave"))) .mig078_fail("INPUT has an unknown outcome.")
  r <- x$outcome == "record"
  if (anyNA(x$message_id[r]) || !all(x$location[r] %in% c("orig", "emails")))
    .mig078_fail("INPUT record row lacks a message_id / location.")
  x$stamp <- x$stamp == "TRUE"
  x$transition <- x$transition == "TRUE"
  x
}

# Who inserts which ingest_email row: the earliest first_seen_at (then hash) eml row among the
# given groups. Returns the eml hashes that insert, given the Message-IDs already present.
.mig078_owners <- function(con, x, have_ids) {
  e <- x[x$outcome == "record" & x$role == "eml", , drop = FALSE]
  if (!nrow(e)) return(character())
  fs <- DBI::dbGetQuery(con, sprintf("SELECT hash, first_seen_at FROM ingest_file WHERE hash IN %s", .mig078_inlist(e$hash)))
  e <- e[order(fs$first_seen_at[match(e$hash, fs$hash)], e$hash), , drop = FALSE]
  e <- e[!duplicated(e$message_id) & !(e$message_id %in% have_ids), , drop = FALSE]
  e$hash
}

# ---- preconditions -----------------------------------------------------------------------

.mig078_problems <- function(con, x) {
  have <- DBI::dbGetQuery(con, "SELECT version FROM schema_version")$version
  miss <- setdiff(.mig078_requires, have)
  if (length(miss)) .mig078_fail(sprintf("marker(s) %s required first.", paste(miss, collapse = ", ")))
  t <- x[x$outcome == "record", , drop = FALSE]
  s <- .mig078_row_sha(con, t$hash)
  now <- mig078_plan_con(con)
  pr <- list()
  add <- function(g, m) pr[[g]] <<- c(pr[[g]], m)
  keep <- setdiff(.mig078_cols, "row_sha1")
  for (g in unique(t$gid)) {
    tg <- t[t$gid == g, , drop = FALSE]
    if (any(is.na(s[tg$hash])) || any(s[tg$hash] != tg$row_sha1)) { add(g, "ingest_file row missing or not as frozen"); next }
    ng <- now[now$gid %in% now$gid[now$hash %in% tg$hash], , drop = FALSE]
    # re-derived plan for these hashes equals the frozen one (gid labels may shift; compare rows)
    nn <- ng[match(tg$hash, ng$hash), setdiff(keep, "gid"), drop = FALSE]
    ft <- tg[, setdiff(keep, "gid"), drop = FALSE]
    same <- nrow(ng) == nrow(tg) && !anyNA(nn$hash) &&
      identical(vapply(ft, function(c) paste(c, collapse = "\u001f"), ""), vapply(nn, function(c) paste(c, collapse = "\u001f"), ""))
    if (!same) { add(g, "re-derived plan differs from the frozen plan"); next }
    ee <- tg[tg$role == "eml", , drop = FALSE]
    p <- DBI::dbGetQuery(con, "SELECT path_first_seen FROM ingest_file WHERE hash = ?", params = list(ee$hash[[1]]))$path_first_seen
    f <- .mig078_path_for(p, ee$location[[1]])
    if (is.na(f) || !file.exists(f)) add(g, "email file not where the INPUT says")
  }
  pr
}

.mig078_skipped_df <- function(pr, x) {
  lv <- x[x$outcome == "leave", , drop = FALSE]
  gid <- c(names(pr), lv$gid)
  why <- c(vapply(pr, function(p) paste(unique(p), collapse = "; "), ""), lv$reason)
  keep <- !duplicated(gid)
  data.frame(gid = unname(gid[keep]), problem = unname(why[keep]), stringsAsFactors = FALSE)
}

# ---- verify ------------------------------------------------------------------------------

.mig078_done_problem <- function(con, x) {
  if (.mig078_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig078_marker_version) != 1L)
    return("marker 1078 missing")
  r <- x[x$outcome == "record", , drop = FALSE]
  for (i in seq_len(nrow(r))) {
    mid <- DBI::dbGetQuery(con, "SELECT message_id FROM ingest_file WHERE hash = ?", params = list(r$hash[[i]]))
    if (nrow(mid) != 1L || !identical(mid$message_id[[1]], r$message_id[[i]])) return(sprintf("%s %s: message_id not set", r$gid[[i]], r$role[[i]]))
  }
  e <- r[r$role == "eml", , drop = FALSE]
  for (i in seq_len(nrow(e))) {
    st <- DBI::dbGetQuery(con, "SELECT state, state_reason FROM ingest_file WHERE hash = ?", params = list(e$hash[[i]]))
    if (!identical(c(st$state, st$state_reason), c("ignored", "delivery_email"))) return(sprintf("%s: _email.eml row not ignored/delivery_email", e$gid[[i]]))
    n <- .mig078_scalar(con, "SELECT COUNT(*) FROM ingest_email WHERE message_id = ?", e$message_id[[i]])
    if (n != 1L) return(sprintf("%s: ingest_email holds %d rows for its message_id", e$gid[[i]], n))
  }
  # rows this migration inserted: folder and first_seen_at are the owner's
  ins <- DBI::dbGetQuery(con, "SELECT reason FROM change_log WHERE actor = ? AND tbl = 'ingest_email' AND action = 'insert'",
                         params = list(.mig078_actor))$reason
  for (rs in ins) {
    mid <- sub("^R-22\\.E: delivering email ", "", rs)
    if (!identical(rs, paste0("R-22.E: delivering email ", mid))) return("an ingest_email change_log reason is not R-22.E's")
    own <- e[e$message_id == mid, , drop = FALSE]
    if (!nrow(own)) return("an inserted ingest_email row is not in the INPUT")
    ok <- .mig078_scalar(con, sprintf("SELECT COUNT(*) FROM ingest_email i JOIN ingest_file f ON f.hash IN %s
                                       WHERE i.message_id = ? AND i.first_seen_at = f.first_seen_at
                                         AND i.folder = ?", .mig078_inlist(own$hash)), mid, own$folder[[1]])
    if (ok < 1L) return("an inserted ingest_email row's folder / first_seen_at is not its _email.eml row's")
  }
  L <- DBI::dbGetQuery(con, "SELECT tbl, action, field, count(*) AS n FROM change_log WHERE actor = ? GROUP BY ALL", params = list(.mig078_actor))
  n <- function(tb, f) { v <- L$n[L$tbl == tb & (if (is.na(f)) is.na(L$field) else (!is.na(L$field) & L$field == f))]; if (length(v)) sum(v) else 0L }
  if (n("ingest_file", "message_id") != sum(r$stamp) ||
      n("ingest_file", "state") != sum(e$transition) || n("ingest_file", "state_reason") != sum(e$transition) ||
      n("ingest_file", "updated_at") != sum(e$transition) || n("ingest_email", NA) != length(ins) ||
      nrow(L) > 5L) return("078 change_log rows are not as planned")
  NULL
}

.mig078_counts <- function(con) {
  tabs <- c("analysis", "sample", "feature", "lab_method", "analyte", "asset", "ingest_file", "ingest_sighting",
            "project", "review_queue", "lab_qc_report", "change_log", "schema_version")
  out <- stats::setNames(lapply(tabs, function(t) .mig078_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
  out$ingest_email <- if (.mig078_has_email_tbl(con)) .mig078_scalar(con, "SELECT COUNT(*) FROM ingest_email") else 0L
  out
}

.mig078_checksum <- function(con, touched_hashes, inserted_ids) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  tabs <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  touched <- c("ingest_file", "ingest_email", "change_log", "schema_version")
  out <- lapply(setdiff(tabs, touched), function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- setdiff(tabs, touched)
  out$ingest_file_rest <- q(sprintf("SELECT * FROM ingest_file WHERE hash NOT IN %s ORDER BY ALL", .mig078_inlist(touched_hashes)))
  # the touched ingest_file rows: every version-8 column except the four the migration moves
  out$ingest_file_touched_fixed <- q(sprintf(
    "SELECT hash, filename, path_first_seen, size, first_seen_at, adapter, tier, work_order, revision, org, uuid_asset,
            registry_fingerprint FROM ingest_file WHERE hash IN %s ORDER BY hash", .mig078_inlist(touched_hashes)))
  out$ingest_email_rest <- q(sprintf("SELECT * FROM ingest_email WHERE message_id NOT IN %s ORDER BY ALL", .mig078_inlist(inserted_ids)))
  out$change_log_rest <- q(sprintf("SELECT * FROM change_log WHERE actor <> '%s' ORDER BY uuid", .mig078_actor))
  out$schema_version_rest <- q(sprintf("SELECT * FROM schema_version WHERE version <> %d ORDER BY ALL", .mig078_marker_version))
  out$indexes <- q("SELECT index_name, sql FROM duckdb_indexes() ORDER BY index_name")
  out$views <- q("SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
  out
}

.mig078_checks_problem <- function(before, after) {
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

.mig078_apply <- function(con, x, have_ids, recorded_at, logf) {
  r <- x[x$outcome == "record", , drop = FALSE]
  e <- r[r$role == "eml", , drop = FALSE]
  owners <- .mig078_owners(con, x, have_ids)
  ins <- e[e$hash %in% owners, , drop = FALSE]
  db_transaction(con, function(con) {
    baseline <- db_checks(con, tier = "migration")
    before_all <- db_checks(con, tier = "all")
    sums_before <- .mig078_checksum(con, r$hash, ins$message_id)
    want <- .mig078_counts(con)
    want$ingest_email <- want$ingest_email + nrow(ins)
    want$change_log <- want$change_log + nrow(ins) + sum(r$stamp) + 3L * sum(e$transition)
    want$schema_version <- want$schema_version + 1L
    for (i in seq_len(nrow(ins))) {
      h <- email_headers(.mig078_path_for(
        DBI::dbGetQuery(con, "SELECT path_first_seen FROM ingest_file WHERE hash = ?", params = list(ins$hash[[i]]))$path_first_seen,
        ins$location[[i]]))
      fs <- DBI::dbGetQuery(con, "SELECT first_seen_at FROM ingest_file WHERE hash = ?", params = list(ins$hash[[i]]))$first_seen_at
      if (is.null(h) || !identical(h$message_id, ins$message_id[[i]])) .mig078_fail(sprintf("%s: header changed under the run.", ins$gid[[i]]))
      db_append(con, "ingest_email",
                data.frame(message_id = h$message_id, sent_at = h$sent_at, sender = h$sender,
                           sender_name = h$sender_name, subject = h$subject, in_reply_to = h$in_reply_to,
                           folder = ins$folder[[i]], first_seen_at = fs, stringsAsFactors = FALSE),
                actor = .mig078_actor, reason = paste0("R-22.E: delivering email ", h$message_id))
    }
    for (i in seq_len(nrow(r))) {
      ch <- list()
      if (r$stamp[[i]]) ch$message_id <- r$message_id[[i]]
      if (r$transition[[i]]) {
        ch$state <- "ignored"; ch$state_reason <- "delivery_email"; ch$updated_at <- recorded_at
      }
      if (length(ch))
        db_update(con, "ingest_file", key = list(hash = r$hash[[i]]), changes = ch, actor = .mig078_actor,
                  reason = sprintf("%s [%s]", .mig078_reason, r$gid[[i]]))
    }
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig078_marker_version, recorded_at))
    pr <- .mig078_done_problem(con, x)
    if (!is.null(pr)) .mig078_fail(paste0("verify failed: ", pr))
    if (!identical(.mig078_counts(con), want)) .mig078_fail("table counts are not as planned.")
    if (!identical(sums_before, .mig078_checksum(con, r$hash, ins$message_id))) .mig078_fail("something outside the planned rows moved.")
    mig_db_checks_gate(con, baseline)
    after_all <- db_checks(con, tier = "all")
    pr <- .mig078_checks_problem(before_all, after_all)
    if (!is.null(pr)) .mig078_fail(paste0("standing checks: ", pr))
    if (!identical(after_all$status[after_all$name == "ingest_file_email_dangling"], "pass"))
      .mig078_fail("ingest_file_email_dangling does not pass.")
    logf("Recorded %d email(s); gave %d ingest_file row(s) a message_id; transitioned %d _email.eml row(s).",
         nrow(ins), sum(r$stamp), sum(e$transition))
    NULL
  })
  invisible(NULL)
}

# ---- backups, files ----------------------------------------------------------------------

mig078_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- if (is.null(.now)) Sys.time() else .now
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig078_name, ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig078_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig078_counts(verify_con)))
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  dest
}

.mig078_write_csv <- function(df, path, key) {
  utils::write.csv(df, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8", colClasses = "character")
  if (nrow(back) != nrow(df) || (nrow(df) && !identical(back[[key]], as.character(df[[key]]))))
    cli::cli_abort("078: CSV {basename(path)} did not round-trip.", class = "sampletidy_error")
}

.mig078_csv <- function(csv_dir, what) file.path(csv_dir, sprintf("%s-%s.csv", .mig078_name, what))

.mig078_read_skipped <- function(csv_dir) {
  f <- .mig078_csv(csv_dir, "SKIPPED")
  if (!file.exists(f)) return(NULL)
  utils::read.csv(f, colClasses = "character", na.strings = "", encoding = "UTF-8")
}

# ---- run ---------------------------------------------------------------------------------

mig078_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL, input_dir = "dev/migrations") {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir
  x0 <- .mig078_read_inputs(input_dir)

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                                   params = list(.mig078_marker_version)),
                   finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    sk <- .mig078_read_skipped(csv_dir)
    if (is.null(sk)) .mig078_fail(sprintf("marker present but %s is missing: cannot re-verify.", .mig078_csv(csv_dir, "SKIPPED")))
    x <- x0[!x0$gid %in% sk$gid, , drop = FALSE]
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch({
      pr <- .mig078_done_problem(check_con, x)
      if (!is.null(pr)) .mig078_fail(paste0("re-verify: ", pr))
    }, finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("078 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_, restore_command = NA_character_,
                          recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  problems <- tryCatch({
    if (.mig078_scalar(pre_con, "SELECT COUNT(*) FROM change_log WHERE actor = ?", .mig078_actor) > 0L)
      .mig078_fail("change_log already holds 078 rows but the marker is absent; refusing.")
    .mig078_ensure_icu(pre_con)
    .mig078_problems(pre_con, x0)
  }, finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  skipped <- .mig078_skipped_df(problems, x0)
  x <- x0[x0$outcome == "record" & !x0$gid %in% names(problems), , drop = FALSE]
  logf("Plan: %d email group(s) to record (%d ingest_file row(s)); %d group(s) skipped.",
       length(unique(x$gid)), nrow(x), nrow(skipped))
  for (i in seq_len(nrow(skipped))) logf("SKIP %s: %s", skipped$gid[[i]], skipped$problem[[i]])
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition checked. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_, restore_command = NA_character_, recorded_at = NA)))
  }

  bk_con <- st_connect(db, read_only = TRUE)
  tryCatch({
    .mig078_write_csv(.mig078_rows(bk_con, x$hash), .mig078_csv(csv_dir, "BACKUP-ingest_file"), ".id")
    .mig078_write_csv(skipped, .mig078_csv(csv_dir, "SKIPPED"), "gid")
  }, finally = DBI::dbDisconnect(bk_con, shutdown = TRUE))
  logf("Row backup and the SKIPPED plan written to %s", csv_dir)
  backup_path <- mig078_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- if (is.null(.now)) Sys.time() else .now

  with_db_write(function(con) {
    .mig078_ensure_icu(con)
    # AFTER the verified snapshot: bring the ops schema to the version that has ingest_email and
    # ingest_file.message_id (a no-op when an import already did).
    ensure_schema(con)
    again <- .mig078_problems(con, x)
    if (length(again)) .mig078_fail("a precondition changed since the dry check; re-run.")
    have_ids <- DBI::dbGetQuery(con, "SELECT message_id FROM ingest_email")$message_id
    .mig078_apply(con, x, have_ids, recorded_at, logf)
  }, db = db)

  logf("%s migrated successfully (marker %d).", .mig078_name, .mig078_marker_version)
  invisible(list(status = "migrated", backup_path = backup_path, restore_command = restore_command,
                 recorded_at = recorded_at))
}
