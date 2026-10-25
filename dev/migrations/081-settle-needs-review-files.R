# REHEARSED, NOT APPLIED (rehearsed 2026-10-25 on a plain-cp copy of live at marker 1080). See
# dev/MIGRATIONS.md row 1081.
# Operator-run migration: settle the ingest_file rows left in needs_review after every review
# item of their delivery was resolved. Marker 1081. Requires 1080.
#
# Authority: Robin, 2026-10-25 ("fix"): files whose review items are all resolved are moved on
# from needs_review, as 080 did for its two amended workbooks.
#
# ---- WHY ------------------------------------------------------------------------------
# A delivery whose rows were all withheld (commit.R .ct_set_file_states: review items and no
# clean row, or the F.10 re-ingest guard) parks every kept file of the event on needs_review.
# Nothing ever moves it on: resolve_review(), release_review() and review_queue_close() write
# review_queue only, and the triage migrations (065: "NOT DONE: ingest_file.state is left as it
# is"; 066; 067) closed or released the items without touching ingest_file. The inbox hides it
# (inbox.R counts needs_review-with-asset as done). At marker 1080, 302 rows sat there.
#
# ---- WHAT (frozen in 081-settle-needs-review-files-INPUT.csv: one row per file) ----------
# A file is settled with its delivery (gid = the event: an ESdat Header/Sample2e/Chemistry2e
# set by name stem, any other file alone). A delivery's governing items are those raised on
# any of its files (review_queue.source_hash) plus, for an ALS work order, every item of that
# work order (review_queue.work_order). A delivery with ANY open governing item is left.
# Every planned file has its asset row (archived bytes), is a kept rendering (superseded ones
# are already `ignored`), and its rows are stored in live or were ruled not to be (closed as
# duplicate, released, inserted by 065/066, or dismissed): so its end state is the one a clean
# commit reaches, needs_review -> committed -> archived (.ct_set_file_states), written as one
# db_update of state, state_reason and updated_at (as 077/079/080), so change_log records it.
#   G1  ACIRL field workbooks; own items resolved (065/066/067, 2026-10-20 import review)  32
#   G2  ACIRL gas workbooks, re-sent copies; own items closed per the 032/034 ruling         2
#   G3  ALS XTAB.XLS (the event's kept rendering); own items resolved (065/066)             50
#   G4  ALS ENMRG.CSV; own items resolved (065/066)                                          12
#   G5  ESdat deliveries (with their Header/Sample2e parts); the delivery's items resolved 192
#   G6  ESdat deliveries blocked by F.10 under an EARLIER delivery's still-open
#       work_order_reingest item (no item of their own; commit.R dedupes the guard row):
#       ES2235936, ES2314145, ES2314369, ES2314728, ES2314928. The 065 triage judged only the
#       earlier XTAB/ENMRG, so their own rows were rebuilt from the archived files and
#       reconciled against live: every row is already_present or equal to a stored value    13
#   Evidence for G3-G6 (all 151 ALS deliveries): each was rebuilt from its archived files
#   (adapter parse, assemble_events, reconcile_event against a copy of live at 1080): 0 rows
#   absent from live; 36 Naphthalene non-detects (VOC <5 ug/L, "Ex SVOC" <1.0 ug/L) differ only
#   by method/RL from the stored PAH Naphthalene <0.001 mg/L. Lab-QC-only Chemistry2e files carry
#   no sampling point (065 "held"), so nothing of theirs is stored, as for any clean commit.
#   Left at needs_review (not in the INPUT): 8e8d23b4636b7e04b2a48a8eca5481d3
#     "2400-7399-12-01 December 2024 Monthly Gas Monitoring Blaxland WMF.xls": its
#     report_no_mismatch item 2ecc2295 is open (a copy of November; ask ACIRL).
#
# ---- CHECKS ---------------------------------------------------------------------------
# Per delivery (a failing delivery is SKIPPED whole and listed in the SKIPPED CSV): each file's
# ingest_file row is byte for byte as frozen (row sha1; so still needs_review), has an asset row
# with its hash, and no governing review item is open.
# In the one write transaction: db_checks("migration") baseline and an all-tier baseline;
# after: every planned row as planned (verify), whole-table checksums of everything else,
# counts (change_log +3 per file, schema_version +1), mig_db_checks_gate(), and no all-tier
# check gains an offender.
#
# Backups: verified whole-file snapshot; BACKUP CSV of the ingest_file rows and the SKIPPED
# CSV, written at run time (untracked).
# Idempotent: marker present -> re-verify against the SKIPPED CSV, no-op.
#
#   Rscript dev/migrations/apply-081-settle-needs-review-files.R

.mig081_marker_version <- 1081L
.mig081_requires <- 1080L
.mig081_name <- "081-settle-needs-review-files"
.mig081_actor <- .mig081_name
.mig081_reason <- "081 (Robin 2026-10-25: files whose review items are all resolved leave needs_review)"
.mig081_cols <- c("gid", "grp", "hash", "filename", "from_state", "to_state", "state_reason", "row_sha1")
.mig081_groups <- c("G1", "G2", "G3", "G4", "G5", "G6")
.mig081_grp_reason <- c(
  G1 = "081: review items resolved (065/066/067, 2026-10-20 import review); ACIRL field workbook archived as a clean commit leaves it",
  G2 = "081: review items closed (065, 032/034 ruling: re-sent copy, rows never committed); ACIRL gas workbook archived as a clean commit leaves it",
  G3 = "081: review items resolved (065/066); ALS XTAB archived as a clean commit leaves it",
  G4 = "081: review items resolved (065/066); ALS ENMRG archived as a clean commit leaves it",
  G5 = "081: review items of this ESdat delivery resolved (065/066/067); archived as a clean commit leaves it",
  G6 = "081: blocked under %s's earlier work_order_reingest item (resolved by 065/066); every row is in live; archived as a clean commit leaves it")
# The one file 081 leaves, with why (checked at freeze: still needs_review with an open item).
.mig081_left <- c("8e8d23b4636b7e04b2a48a8eca5481d3" = "report_no_mismatch item 2ecc2295 is open")
.mig081_esdat_parts <- "\\.(Header\\.XML|Sample2e\\.CSV|Chemistry2e\\.CSV)$"

.mig081_fail <- function(msg) cli::cli_abort(paste0(.mig081_name, ": ", msg), class = "sampletidy_error")
.mig081_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = if (length(list(...))) list(...) else NULL)[[1]][[1]])
.mig081_inlist <- function(x) if (!length(x)) "('')" else paste0("(", paste0("'", gsub("'", "''", unique(x)), "'", collapse = ","), ")")
.mig081_wo <- function(state_reason) {
  w <- trimws(sub("^commit_event: ", "", state_reason))
  ifelse(grepl("^ES[0-9]{7}$", w), w, NA_character_)
}

# ---- rows, sha1 -------------------------------------------------------------------------

.mig081_sha <- function(df) {
  if (nrow(df) != 1L) return(NA_character_)
  cols <- names(df)
  v <- vapply(cols, function(f) { s <- .st_changelog_str(df[[f]][1]); if (is.na(s)) "<NA>" else s }, "")
  digest::digest(paste(cols, v, sep = "=", collapse = "\u001f"), algo = "sha1", serialize = FALSE)
}

.mig081_rows <- function(con, hashes) {
  DBI::dbGetQuery(con, sprintf("SELECT * FROM ingest_file WHERE hash IN %s ORDER BY hash", .mig081_inlist(hashes)))
}

.mig081_shas <- function(con, hashes) {
  r <- .mig081_rows(con, hashes)
  s <- vapply(seq_len(nrow(r)), function(i) .mig081_sha(r[i, , drop = FALSE]), "")
  stats::setNames(s[match(hashes, r$hash)], hashes)
}

# ---- plan (classification), freeze, inputs -----------------------------------------------

# Governing review items of each delivery: raised on one of its files, or (ALS) on its work order.
.mig081_governing <- function(con, x) {
  rq <- DBI::dbGetQuery(con, "SELECT uuid, kind, status, work_order, source_hash, created_at FROM review_queue")
  lapply(split(x, x$gid), function(e) {
    wo <- unique(stats::na.omit(.mig081_wo(e$state_reason)))
    rq[rq$source_hash %in% e$hash | (length(wo) > 0 & rq$work_order %in% wo), , drop = FALSE]
  })
}

# Derive the plan from the DB: every needs_review row, classified per delivery.
mig081_plan_con <- function(con) {
  f <- DBI::dbGetQuery(con, "SELECT hash, filename, adapter, state, state_reason, updated_at FROM ingest_file
                              WHERE state = 'needs_review' ORDER BY hash")
  esd <- f$adapter %in% "esdat"
  f$ev <- ifelse(esd, paste0("esdat:", sub(.mig081_esdat_parts, "", f$filename, ignore.case = TRUE)), paste0("file:", f$hash))
  if (any(esd & !grepl(.mig081_esdat_parts, f$filename, ignore.case = TRUE))) .mig081_fail("an ESdat file is not a Header/Sample2e/Chemistry2e part.")
  rq <- DBI::dbGetQuery(con, "SELECT uuid, kind, status, work_order, source_hash, created_at FROM review_queue")
  has_asset <- f$hash %in% DBI::dbGetQuery(con, "SELECT DISTINCT hash FROM asset WHERE hash IS NOT NULL")$hash
  out <- list(); left <- character()
  for (ev in unique(f$ev)) {
    e <- f[f$ev == ev, , drop = FALSE]
    wo <- unique(stats::na.omit(.mig081_wo(e$state_reason)))
    own <- rq[rq$source_hash %in% e$hash, , drop = FALSE]
    gov <- rq[rq$source_hash %in% e$hash | (length(wo) > 0 & rq$work_order %in% wo), , drop = FALSE]
    prior <- rq[rq$kind == "work_order_reingest" & rq$work_order %in% wo & !(rq$source_hash %in% e$hash) &
                  rq$created_at <= max(e$updated_at), , drop = FALSE]
    if (any(gov$status == "open")) { left <- c(left, e$hash); next }
    if (!all(has_asset[f$ev == ev])) .mig081_fail(sprintf("delivery %s has a file with no asset row.", ev))
    ad <- unique(e$adapter)
    if (length(ad) != 1L) .mig081_fail(sprintf("delivery %s mixes adapters.", ev))
    g <- switch(ad,
      acirl_field_xlsx = "G1", acirl_gas_xlsx = "G2", als_xtab = "G3", als_enmrg = "G4",
      esdat = if (nrow(own) > 0) "G5" else if (nrow(prior) > 0) "G6" else NA_character_,
      NA_character_)
    if (is.na(g) || (g != "G6" && nrow(own) == 0)) .mig081_fail(sprintf("delivery %s has no governing review item; not classified.", ev))
    reason <- if (g == "G6") sprintf(.mig081_grp_reason[["G6"]], wo) else .mig081_grp_reason[[g]]
    out[[ev]] <- data.frame(ev = ev, grp = g, hash = e$hash, filename = e$filename, from_state = "needs_review",
                            to_state = "archived", state_reason = reason, stringsAsFactors = FALSE)
  }
  if (!setequal(left, names(.mig081_left)))
    .mig081_fail(sprintf("the files left at needs_review are not as ruled: %s", paste(left, collapse = ", ")))
  p <- do.call(rbind, out)
  p <- p[order(match(p$grp, .mig081_groups), p$ev, p$filename), , drop = FALSE]
  evs <- unique(p$ev)
  p$gid <- sprintf("D%03d", match(p$ev, evs))
  p$row_sha1 <- unname(.mig081_shas(con, p$hash))
  rownames(p) <- NULL
  p[, .mig081_cols]
}

mig081_freeze <- function(db, input_dir = "dev/migrations") {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  p <- mig081_plan_con(con)
  pr <- .mig081_problems(con, p)
  if (length(pr)) .mig081_fail(sprintf("plan does not hold at freeze: %s", paste(names(pr), unlist(pr), collapse = "; ")))
  utils::write.csv(p, file.path(input_dir, sprintf("%s-INPUT.csv", .mig081_name)), row.names = FALSE, na = "",
                   fileEncoding = "UTF-8")
  invisible(p)
}

.mig081_read_inputs <- function(input_dir = "dev/migrations") {
  p <- file.path(input_dir, sprintf("%s-INPUT.csv", .mig081_name))
  if (!file.exists(p)) .mig081_fail(sprintf("input %s not found.", p))
  x <- utils::read.csv(p, colClasses = "character", na.strings = "", encoding = "UTF-8")
  if (!identical(names(x), .mig081_cols)) .mig081_fail("INPUT columns are not as planned.")
  if (anyNA(x$row_sha1) || anyNA(x$hash) || anyDuplicated(x$hash)) .mig081_fail("INPUT misses or repeats a row.")
  if (!all(x$grp %in% .mig081_groups) || !all(x$from_state == "needs_review") || !all(x$to_state == "archived"))
    .mig081_fail("INPUT groups or states are not as ruled.")
  if (any(x$hash %in% names(.mig081_left))) .mig081_fail("INPUT plans a file the ruling leaves.")
  want <- ifelse(x$grp == "G6", NA_character_, unname(.mig081_grp_reason[x$grp]))
  if (any(x$grp != "G6" & x$state_reason != want) ||
      any(x$grp == "G6" & !grepl("^081: blocked under ES[0-9]{7}'s earlier work_order_reingest item", x$state_reason)))
    .mig081_fail("INPUT state_reason does not match its group.")
  if (any(vapply(split(x$grp, x$gid), function(g) length(unique(g)), 1L) != 1L)) .mig081_fail("INPUT delivery spans groups.")
  x
}

# ---- preconditions -----------------------------------------------------------------------

# Named list gid -> problems.
.mig081_problems <- function(con, x) {
  have <- DBI::dbGetQuery(con, "SELECT version FROM schema_version")$version
  miss <- setdiff(.mig081_requires, have)
  if (length(miss)) .mig081_fail(sprintf("marker(s) %s required first.", paste(miss, collapse = ", ")))
  pr <- list()
  add <- function(g, m) pr[[g]] <<- c(pr[[g]], m)
  s <- .mig081_shas(con, x$hash)
  bad <- is.na(s) | s != x$row_sha1
  for (i in which(bad)) add(x$gid[[i]], sprintf("ingest_file %s missing or not as frozen", x$hash[[i]]))
  assets <- DBI::dbGetQuery(con, sprintf("SELECT DISTINCT hash FROM asset WHERE hash IN %s", .mig081_inlist(x$hash)))$hash
  for (i in which(!x$hash %in% assets)) add(x$gid[[i]], sprintf("ingest_file %s has no asset row", x$hash[[i]]))
  gov <- .mig081_governing(con, x)
  for (g in names(gov)) {
    o <- gov[[g]][gov[[g]]$status != "resolved", , drop = FALSE]
    if (nrow(o)) add(g, sprintf("review item(s) %s not resolved", paste(substr(o$uuid, 1, 8), collapse = ", ")))
  }
  pr
}

.mig081_skipped_df <- function(pr) {
  if (!length(pr)) return(data.frame(gid = character(), problem = character(), stringsAsFactors = FALSE))
  data.frame(gid = names(pr), problem = vapply(pr, function(p) paste(unique(p), collapse = "; "), ""),
             stringsAsFactors = FALSE)
}

# ---- verify ------------------------------------------------------------------------------

.mig081_done_problem <- function(con, x) {
  if (.mig081_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig081_marker_version) != 1L)
    return("marker 1081 missing")
  L <- DBI::dbGetQuery(con, "SELECT tbl, action, uuid_row, field, old, new, source_hash FROM change_log WHERE actor = ?",
                       params = list(.mig081_actor))
  if (nrow(L) != 3L * nrow(x)) return(sprintf("081 change_log has %d row(s), not %d", nrow(L), 3L * nrow(x)))
  if (!all(L$tbl == "ingest_file") || !all(L$source_hash %in% x$hash)) return("081 change_log rows outside the planned files")
  r <- .mig081_rows(con, x$hash)
  r <- r[match(x$hash, r$hash), , drop = FALSE]
  bad <- which(is.na(r$hash) | r$state != x$to_state | r$state_reason != x$state_reason)
  if (length(bad)) return(sprintf("ingest_file %s is not as planned", x$hash[[bad[1]]]))
  for (i in seq_len(nrow(x))) {
    l <- L[L$source_hash == x$hash[[i]], , drop = FALSE]
    if (!setequal(l$field, c("state", "state_reason", "updated_at")) || nrow(l) != 3L)
      return(sprintf("ingest_file %s change_log rows not as planned", x$hash[[i]]))
    ls <- l[l$field == "state", ]
    if (!identical(c(ls$old, ls$new), c(x$from_state[[i]], x$to_state[[i]])))
      return(sprintf("ingest_file %s state change_log old/new not as planned", x$hash[[i]]))
  }
  NULL
}

.mig081_counts <- function(con) {
  tabs <- c("analysis", "sample", "feature", "lab_method", "analyte", "asset", "ingest_file", "ingest_sighting",
            "project", "review_queue", "lab_qc_report", "change_log", "schema_version")
  stats::setNames(lapply(tabs, function(t) .mig081_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
}

.mig081_checksum <- function(con, x) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  tabs <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  touched <- c("ingest_file", "change_log", "schema_version")
  out <- lapply(setdiff(tabs, touched), function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- setdiff(tabs, touched)
  out$ingest_file_rest <- q(sprintf("SELECT * FROM ingest_file WHERE hash NOT IN %s ORDER BY ALL", .mig081_inlist(x$hash)))
  out$ingest_file_cols <- q(sprintf("SELECT * EXCLUDE (state, state_reason, updated_at) FROM ingest_file WHERE hash IN %s ORDER BY hash",
                                    .mig081_inlist(x$hash)))
  out$change_log_rest <- q(sprintf("SELECT * FROM change_log WHERE actor <> '%s' ORDER BY uuid", .mig081_actor))
  out$schema_version_rest <- q(sprintf("SELECT * FROM schema_version WHERE version <> %d ORDER BY ALL", .mig081_marker_version))
  out$indexes <- q("SELECT index_name, sql FROM duckdb_indexes() ORDER BY index_name")
  out$views <- q("SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
  out
}

.mig081_checks_problem <- function(before, after) {
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

.mig081_apply <- function(con, x, recorded_at, logf) {
  db_transaction(con, function(con) {
    baseline <- db_checks(con, tier = "migration")
    before_all <- db_checks(con, tier = "all")
    sums_before <- .mig081_checksum(con, x)
    want <- .mig081_counts(con)
    want$change_log <- want$change_log + 3L * nrow(x)
    want$schema_version <- want$schema_version + 1L
    for (i in seq_len(nrow(x))) {
      db_update(con, "ingest_file", key = list(hash = x$hash[[i]]),
                changes = list(state = x$to_state[[i]], state_reason = x$state_reason[[i]], updated_at = recorded_at),
                actor = .mig081_actor,
                reason = sprintf("%s [%s %s]: ingest_file %s", .mig081_reason, x$grp[[i]], x$gid[[i]], x$hash[[i]]),
                source_hash = x$hash[[i]])
    }
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig081_marker_version, recorded_at))
    pr <- .mig081_done_problem(con, x)
    if (!is.null(pr)) .mig081_fail(paste0("verify failed: ", pr))
    got <- .mig081_counts(con)
    if (!identical(got, want))
      .mig081_fail(sprintf("table counts are not as planned: %s",
                           paste(names(got), unlist(got), unlist(want), sep = ":", collapse = ", ")))
    if (!identical(sums_before, .mig081_checksum(con, x))) .mig081_fail("something outside the planned rows moved.")
    mig_db_checks_gate(con, baseline)
    after_all <- db_checks(con, tier = "all")
    pr <- .mig081_checks_problem(before_all, after_all)
    if (!is.null(pr)) .mig081_fail(paste0("standing checks: ", pr))
    logf("Archived %d ingest_file row(s) in %d deliveries: %s.", nrow(x), length(unique(x$gid)),
         paste(names(table(x$grp)), table(x$grp), sep = " ", collapse = ", "))
    NULL
  })
  invisible(NULL)
}

# ---- backups, files ----------------------------------------------------------------------

mig081_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- if (is.null(.now)) Sys.time() else .now
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig081_name, ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig081_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig081_counts(verify_con)))
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  dest
}

.mig081_write_csv <- function(df, path, key) {
  out <- df
  for (f in names(out)) if (inherits(out[[f]], c("POSIXct", "Date"))) out[[f]] <- .st_changelog_str(out[[f]])
  utils::write.csv(out, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8", colClasses = "character")
  if (nrow(back) != nrow(df) || (nrow(df) && !identical(back[[key]], as.character(out[[key]]))))
    cli::cli_abort("081: CSV {basename(path)} did not round-trip.", class = "sampletidy_error")
}

.mig081_csv <- function(csv_dir, what) file.path(csv_dir, sprintf("%s-%s.csv", .mig081_name, what))

.mig081_read_skipped <- function(csv_dir) {
  f <- .mig081_csv(csv_dir, "SKIPPED")
  if (!file.exists(f)) return(NULL)
  utils::read.csv(f, colClasses = "character", na.strings = "", encoding = "UTF-8")
}

# ---- run ---------------------------------------------------------------------------------

mig081_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL, input_dir = "dev/migrations") {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir
  x0 <- .mig081_read_inputs(input_dir)

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                                   params = list(.mig081_marker_version)),
                   finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    sk <- .mig081_read_skipped(csv_dir)
    if (is.null(sk)) .mig081_fail(sprintf("marker present but %s is missing: cannot re-verify.", .mig081_csv(csv_dir, "SKIPPED")))
    x <- x0[!x0$gid %in% sk$gid, , drop = FALSE]
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch({
      pr <- .mig081_done_problem(check_con, x)
      if (!is.null(pr)) .mig081_fail(paste0("re-verify: ", pr))
    }, finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("081 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_, restore_command = NA_character_,
                          recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  problems <- tryCatch({
    if (.mig081_scalar(pre_con, "SELECT COUNT(*) FROM change_log WHERE actor = ?", .mig081_actor) > 0L)
      .mig081_fail("change_log already holds 081 rows but the marker is absent; refusing.")
    .mig081_problems(pre_con, x0)
  }, finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  skipped <- .mig081_skipped_df(problems)
  x <- x0[!x0$gid %in% skipped$gid, , drop = FALSE]
  logf("Plan: %d delivery(ies) of %d (%d file(s)); %d skipped.", length(unique(x$gid)), length(unique(x0$gid)),
       nrow(x), nrow(skipped))
  tg <- table(factor(x$grp, levels = .mig081_groups))
  logf("  by group: %s", paste(names(tg), tg, sep = " ", collapse = ", "))
  for (i in seq_len(nrow(skipped))) logf("SKIP %s: %s", skipped$gid[[i]], skipped$problem[[i]])
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition checked. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_, restore_command = NA_character_, recorded_at = NA)))
  }
  if (!nrow(x)) .mig081_fail("every delivery is skipped; nothing to do (no marker written).")

  bk_con <- st_connect(db, read_only = TRUE)
  tryCatch({
    .mig081_write_csv(.mig081_rows(bk_con, x$hash), .mig081_csv(csv_dir, "BACKUP-ingest_file"), "hash")
    .mig081_write_csv(skipped, .mig081_csv(csv_dir, "SKIPPED"), "gid")
  }, finally = DBI::dbDisconnect(bk_con, shutdown = TRUE))
  logf("Row backups and the SKIPPED plan written to %s", csv_dir)
  backup_path <- mig081_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- if (is.null(.now)) Sys.time() else .now

  with_db_write(function(con) {
    again <- .mig081_problems(con, x)
    if (length(again)) .mig081_fail("a precondition changed since the dry check; re-run.")
    .mig081_apply(con, x, recorded_at, logf)
  }, db = db)

  logf("%s migrated successfully (marker %d).", .mig081_name, .mig081_marker_version)
  invisible(list(status = "migrated", backup_path = backup_path, restore_command = restore_command,
                 recorded_at = recorded_at))
}
