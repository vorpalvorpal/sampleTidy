# REHEARSED, NOT APPLIED. See dev/MIGRATIONS.md row 1082.
# Operator-run migration: add the R-22.S sample-receipt schema to the live database and
# backfill it. Marker 1082. Requires 1081 (081 was applied to live 2026-10-25).
#
# Authority: Robin, 2026-10-25 ("include all the temp, etc data as their own columns"; the
# SRN parser and receipt schema are R-22.S, R/lab-receipt.R and R/qci.R).
#
# ---- WHAT IT DOES ---------------------------------------------------------------------
# 1. `.lab_receipt_create_schema(con)`: 12 new lab_qc_report columns (received_at, ...) and
#    the tables lab_receipt_temperature / lab_receipt_holding_breach / lab_receipt_comment.
#    Schema DDL is not logged in change_log (as 048); the marker records it.
# 2. Re-parses, with `lab_qc_reparse()` (force = TRUE, inside the migration's one outer
#    transaction), every frozen asset:
#      * each stored QC / QCI report (220 at freeze) -> parser version "2"; a QCI front page
#        prints "Date Samples Received", so received_at is filled;
#      * each stored SRN asset (type QA, `_SRN_` token; ES2631587's at freeze) -> a kind-SRN
#        lab_qc_report row with its receipt columns and child rows.
#    Re-parse deletes the old report and its outliers and inserts new ones with NEW uuids,
#    through db_delete / db_append (lab_qc_ingest), so every row is in change_log.
# 3. The re-parse must change nothing else (one exception, counted and logged: a lab_qc_outlier
#    whose uuid_sample was NULL may become a sample of the report's OWN work order, the sample
#    having been imported since the first parse; any other uuid_sample change aborts): for every previously stored report the
#    work_order, kind, issue_date, n_received, n_analysed, summary, status and message, and
#    the lab_qc_outlier rows (every column but uuid / uuid_report / that link), must be identical before
#    and after. ANY difference aborts the whole transaction (rolls back) and writes the
#    differences to 082-...-DIFFS.csv.
#
# ---- GUARDS ---------------------------------------------------------------------------
# INPUT (committed, frozen: asset uuids, file names, kinds, work orders, sha1 only) is
# checked per asset (a failure SKIPS that asset): the asset row, the stored report row
# (its 12 pre-082 columns) and its outlier rows are as frozen; the archived PDF exists.
# The set of assets eligible now must equal INPUT's (else refuse: re-freeze with
# `mig082_freeze(db)` and review). In the transaction: migration-tier db_checks baseline,
# whole-table checksums of everything outside lab_qc_report / lab_qc_outlier / lab_receipt_* /
# change_log / schema_version, counts, the before/after equality above, then
# `mig_db_checks_gate(allow = "lab_receipt_warm")` and an all-tier no-new-offender
# comparison that also allows only lab_receipt_warm: it newly flags a warm SRN BY DESIGN.
#
# ---- UNDO -----------------------------------------------------------------------------
# Restore the verified snapshot (printed at run time). The run-time BACKUP CSVs hold the
# full before-rows of lab_qc_report and lab_qc_outlier (the rows a re-parse replaces).
#
# Env (apply script): SAMPLETIDY_MIG082_DB / _SNAPSHOT_DIR / _CSV_DIR / _ARCHIVE_DIR.
# PDFs are only READ (Files-On-Demand hydrates them); nothing is written to the archive.

.mig082_marker_version <- 1082L
.mig082_requires <- 1081L
.mig082_name <- "082-srn-receipt-schema"
.mig082_actor <- .mig082_name
.mig082_gate_allow <- "lab_receipt_warm"
.mig082_cols <- c("gid", "op", "filename", "kind", "work_order", "n_outliers",
                  "asset_sha1", "report_sha1", "outlier_sha1")
.mig082_report_cols <- c("uuid", "uuid_asset", "work_order", "kind", "issue_date", "n_received",
                         "n_analysed", "summary", "status", "message", "parser_version", "parsed_at")
.mig082_same_cols <- c("work_order", "kind", "issue_date", "n_received", "n_analysed", "summary",
                       "status", "message")
.mig082_kids <- c("lab_receipt_temperature", "lab_receipt_holding_breach", "lab_receipt_comment")

.mig082_fail <- function(msg) cli::cli_abort(paste0(.mig082_name, ": ", msg), class = "sampletidy_error")
.mig082_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = if (length(list(...))) list(...) else NULL)[[1]][[1]])
.mig082_inlist <- function(x) if (!length(x)) "('')" else paste0("(", paste0("'", gsub("'", "''", unique(x)), "'", collapse = ","), ")")
.mig082_tables <- function(con) {
  DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
}

.mig082_str <- function(v) vapply(v, function(z) { s <- .st_changelog_str(z); if (is.na(s)) "<NA>" else s }, "")
.mig082_row_str <- function(df) {
  if (!nrow(df)) return(character())
  m <- vapply(names(df), function(f) .mig082_str(df[[f]]), character(nrow(df)))
  if (nrow(df) == 1L) m <- matrix(m, nrow = 1L)
  apply(m, 1, paste, collapse = "\u001f")
}
.mig082_sha1 <- function(x) digest::digest(paste(x, collapse = "\u001e"), algo = "sha1", serialize = FALSE)

# ---- the eligible assets (the backfill's own selection) -------------------------------------

.mig082_eligible <- function(con) {
  a <- DBI::dbGetQuery(con, "SELECT uuid, filename, type, hash FROM asset WHERE type IN ('QC', 'QA')
                              ORDER BY filename, uuid")
  srn <- !is.na(a$filename) & vapply(a$filename, function(f) identical(.lab_qc_kind(f), "SRN"), logical(1))
  a <- a[a$type == "QC" | srn, , drop = FALSE]
  a$kind <- vapply(a$filename, function(f) if (is.na(f)) NA_character_ else .lab_qc_kind(f), "")
  rownames(a) <- NULL
  a
}

.mig082_asset_sha <- function(con, uuid) {
  a <- DBI::dbGetQuery(con, "SELECT uuid, filename, type, hash FROM asset WHERE uuid = ?", params = list(uuid))
  if (nrow(a) != 1L) return(NA_character_)
  .mig082_sha1(.mig082_row_str(a))
}
.mig082_report <- function(con, uuid) {
  DBI::dbGetQuery(con, sprintf("SELECT %s FROM lab_qc_report WHERE uuid_asset = ? ORDER BY uuid",
                               paste(.mig082_report_cols, collapse = ", ")), params = list(uuid))
}
.mig082_outliers <- function(con, uuid_report) {
  if (!length(uuid_report)) return(DBI::dbGetQuery(con, "SELECT * FROM lab_qc_outlier WHERE FALSE"))
  DBI::dbGetQuery(con, sprintf("SELECT * FROM lab_qc_outlier WHERE uuid_report IN %s ORDER BY uuid",
                               .mig082_inlist(uuid_report)))
}

.mig082_plan_con <- function(con) {
  a <- .mig082_eligible(con)
  rows <- lapply(seq_len(nrow(a)), function(i) {
    r <- .mig082_report(con, a$uuid[[i]])
    o <- .mig082_outliers(con, r$uuid)
    wo <- if (nrow(r) == 1L) r$work_order[[1]] else {
      m <- regmatches(a$filename[[i]], regexpr("E[A-Z][0-9]{7}", a$filename[[i]]))
      if (length(m)) m else NA_character_
    }
    data.frame(gid = a$uuid[[i]], op = if (nrow(r)) "reparse" else "parse", filename = a$filename[[i]],
               kind = a$kind[[i]], work_order = wo, n_outliers = nrow(o),
               asset_sha1 = .mig082_asset_sha(con, a$uuid[[i]]),
               report_sha1 = if (nrow(r)) .mig082_sha1(.mig082_row_str(r)) else NA_character_,
               outlier_sha1 = if (nrow(r)) .mig082_sha1(.mig082_row_str(o)) else NA_character_,
               stringsAsFactors = FALSE)
  })
  out <- do.call(rbind, rows)
  rownames(out) <- NULL
  out[, .mig082_cols]
}

mig082_freeze <- function(db, input_dir = "dev/migrations") {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  p <- .mig082_plan_con(con)
  if (anyNA(p$kind)) .mig082_fail("an eligible asset's file name carries neither _QCI, _QC nor _SRN_.")
  utils::write.csv(p, file.path(input_dir, sprintf("%s-INPUT.csv", .mig082_name)), row.names = FALSE,
                   na = "", fileEncoding = "UTF-8")
  invisible(p)
}

.mig082_read_inputs <- function(input_dir = "dev/migrations") {
  p <- file.path(input_dir, sprintf("%s-INPUT.csv", .mig082_name))
  if (!file.exists(p)) .mig082_fail(sprintf("input %s not found.", p))
  x <- utils::read.csv(p, colClasses = "character", na.strings = "", encoding = "UTF-8")
  if (!identical(names(x), .mig082_cols)) .mig082_fail("INPUT columns are not as planned.")
  if (anyDuplicated(x$gid) || anyNA(x$asset_sha1) || anyNA(x$kind)) .mig082_fail("INPUT repeats or misses an asset.")
  x$n_outliers <- as.integer(x$n_outliers)
  x
}

# ---- preconditions (read-only; no PDF is read) -----------------------------------------------

.mig082_problems <- function(con, x, archive_dir) {
  have <- DBI::dbGetQuery(con, "SELECT version FROM schema_version")$version
  miss <- setdiff(.mig082_requires, have)
  if (length(miss)) .mig082_fail(sprintf("marker(s) %s required first.", paste(miss, collapse = ", ")))
  if (!dir.exists(archive_dir)) .mig082_fail(sprintf("archive_dir %s does not exist.", archive_dir))
  for (t in c("lab_qc_report", "lab_qc_outlier", "asset"))
    if (!t %in% .mig082_tables(con)) .mig082_fail(sprintf("table %s does not exist (apply 048).", t))
  pr <- list()
  add <- function(g, m) pr[[g]] <<- c(pr[[g]], m)
  for (i in seq_len(nrow(x))) {
    g <- x$gid[[i]]
    if (!identical(.mig082_asset_sha(con, g), x$asset_sha1[[i]])) add(g, "asset row missing or not as frozen")
    r <- .mig082_report(con, g)
    if (x$op[[i]] == "parse") {
      if (nrow(r)) add(g, "a report is stored but INPUT froze none")
    } else {
      if (nrow(r) != 1L || !identical(.mig082_sha1(.mig082_row_str(r)), x$report_sha1[[i]])) {
        add(g, "stored report missing or not as frozen")
      } else if (!identical(.mig082_sha1(.mig082_row_str(.mig082_outliers(con, r$uuid))), x$outlier_sha1[[i]])) {
        add(g, "stored outlier rows not as frozen")
      }
    }
    if (!file.exists(file.path(archive_dir, g, x$filename[[i]]))) add(g, "archived PDF not found")
  }
  pr
}

.mig082_eligible_problem <- function(con, x) {
  a <- .mig082_eligible(con)
  extra <- setdiff(a$uuid, x$gid)
  gone <- setdiff(x$gid, a$uuid)
  if (length(extra) || length(gone))
    return(sprintf("the eligible QC/QCI/SRN assets are not INPUT's (%d new, %d gone): re-freeze with mig082_freeze() and review",
                   length(extra), length(gone)))
  NULL
}

.mig082_skipped_df <- function(pr) {
  if (!length(pr)) return(data.frame(gid = character(), problem = character(), stringsAsFactors = FALSE))
  data.frame(gid = names(pr), problem = vapply(pr, function(p) paste(unique(p), collapse = "; "), ""),
             stringsAsFactors = FALSE)
}

# ---- verification -----------------------------------------------------------------------------

.mig082_done_problem <- function(con, x) {
  if (.mig082_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig082_marker_version) != 1L)
    return("marker 1082 missing")
  if (!.lab_receipt_ready(con)) return("the receipt schema is not complete")
  for (i in seq_len(nrow(x))) {
    r <- .mig082_report(con, x$gid[[i]])
    if (nrow(r) != 1L) return(sprintf("asset %s has %d report(s), not 1", x$gid[[i]], nrow(r)))
    if (!identical(r$parser_version[[1]], .qci_parser_version))
      return(sprintf("asset %s report is at parser version %s", x$gid[[i]], r$parser_version[[1]]))
    if (!identical(r$kind[[1]], x$kind[[i]])) return(sprintf("asset %s report kind is %s", x$gid[[i]], r$kind[[1]]))
  }
  o <- .mig082_scalar(con, "SELECT COUNT(*) FROM lab_qc_outlier o
                             WHERE NOT EXISTS (SELECT 1 FROM lab_qc_report r WHERE r.uuid = o.uuid_report)")
  if (o) return(sprintf("%d lab_qc_outlier row(s) with no report", o))
  for (t in .mig082_kids) {
    k <- .mig082_scalar(con, sprintf("SELECT COUNT(*) FROM %s c WHERE NOT EXISTS
                                       (SELECT 1 FROM lab_qc_report r WHERE r.uuid = c.uuid_report)", t))
    if (k) return(sprintf("%d %s row(s) with no report", k, t))
  }
  d <- .mig082_scalar(con, "SELECT COUNT(*) FROM (SELECT uuid_asset FROM lab_qc_report GROUP BY 1 HAVING COUNT(*) > 1)")
  if (d) return(sprintf("%d asset(s) with more than one report", d))
  L <- .mig082_scalar(con, "SELECT COUNT(*) FROM change_log WHERE actor = ?", .mig082_actor)
  if (L == 0L) return("no 082 change_log rows")
  NULL
}

.mig082_counts <- function(con) {
  tabs <- .mig082_tables(con)
  stats::setNames(lapply(tabs, function(t) .mig082_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
}

.mig082_touched <- c("lab_qc_report", "lab_qc_outlier", .mig082_kids, "change_log", "schema_version")

.mig082_checksum <- function(con) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  tabs <- setdiff(.mig082_tables(con), .mig082_touched)
  out <- lapply(tabs, function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- tabs
  out$change_log_rest <- q(sprintf("SELECT * FROM change_log WHERE actor <> '%s' ORDER BY uuid", .mig082_actor))
  out$schema_version_rest <- q(sprintf("SELECT * FROM schema_version WHERE version <> %d ORDER BY ALL", .mig082_marker_version))
  out$views <- q("SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
  out
}

.mig082_checks_problem <- function(before, after, allow = .mig082_gate_allow) {
  for (i in seq_len(nrow(after))) {
    nm <- after$name[[i]]
    if (nm %in% allow) next
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

# What a re-parse must NOT change, per previously stored report. Returns a data.frame of
# differences (empty when none).
.mig082_diffs <- function(con, x, before_reports, before_outliers) {
  d <- list(); links <- list()
  for (i in which(x$op == "reparse")) {
    g <- x$gid[[i]]
    b <- before_reports[before_reports$uuid_asset == g, , drop = FALSE]
    a <- .mig082_report(con, g)
    if (nrow(a) != 1L) { d[[length(d) + 1L]] <- data.frame(gid = g, what = "report", before = nrow(b), after = nrow(a)); next }
    for (f in .mig082_same_cols) {
      bv <- .mig082_str(b[[f]]); av <- .mig082_str(a[[f]])
      if (!identical(unname(bv), unname(av))) d[[length(d) + 1L]] <- data.frame(gid = g, what = f, before = bv, after = av)
    }
    keep <- setdiff(names(before_outliers), c("uuid", "uuid_report", "uuid_sample"))
    bo <- before_outliers[before_outliers$uuid_report %in% b$uuid, , drop = FALSE]
    ao <- .mig082_outliers(con, a$uuid)
    bk <- .mig082_row_str(bo[, keep, drop = FALSE]); ak <- .mig082_row_str(ao[, keep, drop = FALSE])
    bs <- sort(bk); as <- sort(ak)
    if (!identical(bs, as)) {
      d[[length(d) + 1L]] <- data.frame(gid = g, what = "lab_qc_outlier rows",
                                        before = paste(length(bs), "row(s)"), after = paste(length(as), "row(s)"))
      for (s in setdiff(bs, as)) d[[length(d) + 1L]] <- data.frame(gid = g, what = "outlier only before", before = s, after = NA_character_)
      for (s in setdiff(as, bs)) d[[length(d) + 1L]] <- data.frame(gid = g, what = "outlier only after", before = NA_character_, after = s)
    } else {
      # The one allowed change: uuid_sample NULL -> a sample of this work order (a link the
      # first parse could not make, the sample not yet being imported). Anything else is a diff.
      for (k in unique(bk)) {
        bu <- bo$uuid_sample[bk == k]; au <- ao$uuid_sample[ak == k]
        rem <- au[!is.na(au)]; ok <- TRUE
        for (s in bu[!is.na(bu)]) { i <- match(s, rem); if (is.na(i)) { ok <- FALSE; break }; rem <- rem[-i] }
        if (!ok) {
          d[[length(d) + 1L]] <- data.frame(gid = g, what = "uuid_sample changed or lost", before = paste(sort(bu), collapse = ","),
                                            after = paste(sort(au), collapse = ","))
        } else {
          for (s in rem) {
            own <- .mig082_scalar(con, "SELECT COUNT(*) FROM (
                SELECT s.uuid FROM \"sample\" s JOIN project p ON p.uuid = s.uuid_project
                 WHERE s.uuid = ? AND (p.name = ? OR p.uuid_parent IN (SELECT uuid FROM project WHERE name = ?))
                UNION ALL SELECT uuid_sample FROM sample_lab_id WHERE uuid_sample = ? AND work_order = ?)",
                                  s, a$work_order[[1]], a$work_order[[1]], s, a$work_order[[1]])
            if (own < 1L) d[[length(d) + 1L]] <- data.frame(gid = g, what = "new link outside the report's work order",
                                                            before = NA_character_, after = s)
            links[[length(links) + 1L]] <- data.frame(gid = g, work_order = a$work_order[[1]], uuid_sample = s)
          }
        }
      }
    }
  }
  out <- if (!length(d)) data.frame(gid = character(), what = character(), before = character(), after = character())
         else do.call(rbind, d)
  attr(out, "links") <- if (length(links)) do.call(rbind, links) else data.frame(gid = character(), work_order = character(), uuid_sample = character())
  out
}

# Summary of what the migration did (also used by the apply script).
.mig082_summary <- function(con) {
  list(
    srn = DBI::dbGetQuery(con, "SELECT status, COUNT(*) AS n FROM lab_qc_report WHERE kind = 'SRN' GROUP BY ALL ORDER BY ALL"),
    reparsed = DBI::dbGetQuery(con, "SELECT kind, status, parser_version, COUNT(*) AS n,
                                            COUNT(received_at) AS received_filled,
                                            COUNT(*) - COUNT(received_at) AS received_null
                                       FROM lab_qc_report WHERE kind IN ('QC', 'QCI') GROUP BY ALL ORDER BY ALL"),
    kids = vapply(.mig082_kids, function(t) .mig082_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t)), 1L))
}

# ---- apply --------------------------------------------------------------------------------------

.mig082_apply <- function(con, x, archive_dir, recorded_at, logf, csv_dir) {
  db_transaction(con, function(con) {
    baseline <- db_checks(con, tier = "migration")
    before_all <- db_checks(con, tier = "all")
    sums_before <- .mig082_checksum(con)
    before <- .mig082_counts(con)
    rp <- x[x$op == "reparse", , drop = FALSE]
    before_reports <- DBI::dbGetQuery(con, sprintf("SELECT %s FROM lab_qc_report WHERE uuid_asset IN %s ORDER BY uuid",
                                                   paste(.mig082_report_cols, collapse = ", "), .mig082_inlist(rp$gid)))
    before_outliers <- .mig082_outliers(con, before_reports$uuid)
    if (nrow(before_reports) != nrow(rp)) .mig082_fail("the stored reports are not the planned ones.")

    .lab_receipt_create_schema(con)
    if (!.lab_receipt_ready(con)) .mig082_fail("the receipt schema is incomplete after create.")

    for (i in seq_len(nrow(x))) {
      st <- lab_qc_reparse(con, x$gid[[i]], path = file.path(archive_dir, x$gid[[i]], x$filename[[i]]),
                           actor = .mig082_actor)
      if (is.null(st)) .mig082_fail(sprintf("re-parse of %s did nothing.", x$filename[[i]]))
    }

    df <- .mig082_diffs(con, x, before_reports, before_outliers)
    if (nrow(df)) {
      utils::write.csv(df, .mig082_csv(csv_dir, "DIFFS"), row.names = FALSE, na = "", fileEncoding = "UTF-8")
      .mig082_fail(sprintf("a re-parse changed something other than received_at (%d difference(s), see %s); rolled back.",
                           nrow(df), basename(.mig082_csv(csv_dir, "DIFFS"))))
    }
    links <- attr(df, "links")
    logf("lab_qc_outlier.uuid_sample linked NULL -> own-work-order sample: %d row(s) on %d report(s).",
         nrow(links), length(unique(links$gid)))
    bad_v <- .mig082_scalar(con, "SELECT COUNT(*) FROM lab_qc_report WHERE parser_version IS DISTINCT FROM ?", .qci_parser_version)
    if (bad_v) .mig082_fail(sprintf("%d report(s) not at parser version %s.", bad_v, .qci_parser_version))
    sp <- x$op == "parse"
    got_kind <- DBI::dbGetQuery(con, sprintf("SELECT uuid_asset, kind FROM lab_qc_report WHERE uuid_asset IN %s",
                                             .mig082_inlist(x$gid[sp])))
    if (nrow(got_kind) != sum(sp) || any(got_kind$kind != "SRN")) .mig082_fail("an SRN asset has no kind-SRN report.")

    after <- .mig082_counts(con)
    n_kids <- sum(vapply(.mig082_kids, function(t) after[[t]], 1L))
    want_cl <- before$change_log + nrow(before_reports) + nrow(before_outliers) +   # deletes
      nrow(x) + nrow(before_outliers) + n_kids                                      # inserts
    if (after$lab_qc_report != before$lab_qc_report + sum(sp) || after$lab_qc_outlier != before$lab_qc_outlier ||
        after$change_log != want_cl)
      .mig082_fail(sprintf("table counts are not as planned (report %d, outlier %d, change_log %d; wanted %d, %d, %d).",
                           after$lab_qc_report, after$lab_qc_outlier, after$change_log,
                           before$lab_qc_report + sum(sp), before$lab_qc_outlier, want_cl))
    for (t in setdiff(names(before), .mig082_touched)) {
      if (!identical(before[[t]], after[[t]])) .mig082_fail(sprintf("table %s changed count.", t))
    }
    if (!identical(sums_before, .mig082_checksum(con))) .mig082_fail("something outside the planned tables moved.")

    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig082_marker_version, recorded_at))
    pr <- .mig082_done_problem(con, x)
    if (!is.null(pr)) .mig082_fail(paste0("verify failed: ", pr))
    mig_db_checks_gate(con, baseline, allow = .mig082_gate_allow)
    after_all <- db_checks(con, tier = "all")
    pr <- .mig082_checks_problem(before_all, after_all)
    if (!is.null(pr)) .mig082_fail(paste0("standing checks: ", pr))
    sm <- .mig082_summary(con)
    logf("SRN assets parsed: %s", paste(sprintf("%s %d", sm$srn$status, sm$srn$n), collapse = ", "))
    logf("QC/QCI re-parsed: %d (received_at filled %d, NULL %d); no summary, status, message or outlier row changed, bar the uuid_sample links above.",
         nrow(rp), sum(sm$reparsed$received_filled), sum(sm$reparsed$received_null))
    logf("Receipt child rows: %s", paste(sprintf("%s %d", names(sm$kids), sm$kids), collapse = ", "))
    NULL
  })
  invisible(NULL)
}

mig082_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- if (is.null(.now)) Sys.time() else .now
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig082_name, ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig082_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig082_counts(verify_con)))
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  dest
}

.mig082_write_csv <- function(df, path, key) {
  out <- df
  for (f in names(out)) if (inherits(out[[f]], c("POSIXct", "Date"))) out[[f]] <- .st_changelog_str(out[[f]])
  utils::write.csv(out, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8", colClasses = "character")
  if (nrow(back) != nrow(df) || (nrow(df) && !identical(back[[key]], as.character(out[[key]]))))
    cli::cli_abort("082: CSV {basename(path)} did not round-trip.", class = "sampletidy_error")
}
.mig082_csv <- function(csv_dir, what) file.path(csv_dir, sprintf("%s-%s.csv", .mig082_name, what))
.mig082_read_skipped <- function(csv_dir) {
  f <- .mig082_csv(csv_dir, "SKIPPED")
  if (!file.exists(f)) return(NULL)
  utils::read.csv(f, colClasses = "character", na.strings = "", encoding = "UTF-8")
}

# Full before-rows of everything a re-parse replaces (reversible with the snapshot or by hand).
.mig082_write_backups <- function(con, x, csv_dir) {
  rp <- x[x$op == "reparse", , drop = FALSE]
  r <- DBI::dbGetQuery(con, sprintf("SELECT * FROM lab_qc_report WHERE uuid_asset IN %s ORDER BY uuid", .mig082_inlist(rp$gid)))
  .mig082_write_csv(r, .mig082_csv(csv_dir, "BACKUP-lab_qc_report"), "uuid")
  o <- .mig082_outliers(con, r$uuid)
  .mig082_write_csv(o, .mig082_csv(csv_dir, "BACKUP-lab_qc_outlier"), "uuid")
}

mig082_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL, input_dir = "dev/migrations",
                       archive_dir = st_config("archive_dir")) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir
  x0 <- .mig082_read_inputs(input_dir)

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                                   params = list(.mig082_marker_version)),
                   finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    sk <- .mig082_read_skipped(csv_dir)
    if (is.null(sk)) .mig082_fail(sprintf("marker present but %s is missing: cannot re-verify.", .mig082_csv(csv_dir, "SKIPPED")))
    x <- x0[!x0$gid %in% sk$gid, , drop = FALSE]
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch({
      pr <- .mig082_done_problem(check_con, x)
      if (!is.null(pr)) .mig082_fail(paste0("re-verify: ", pr))
    }, finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("082 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_, restore_command = NA_character_,
                          recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  problems <- tryCatch({
    if (.mig082_scalar(pre_con, "SELECT COUNT(*) FROM change_log WHERE actor = ?", .mig082_actor) > 0L)
      .mig082_fail("change_log already holds 082 rows but the marker is absent; refusing.")
    pe <- .mig082_eligible_problem(pre_con, x0)
    if (!is.null(pe)) .mig082_fail(pe)
    .mig082_problems(pre_con, x0, archive_dir)
  }, finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  skipped <- .mig082_skipped_df(problems)
  x <- x0[!x0$gid %in% skipped$gid, , drop = FALSE]
  logf("Plan: %d asset(s) of %d (%d re-parse, %d new SRN); %d skipped.", nrow(x), nrow(x0),
       sum(x$op == "reparse"), sum(x$op == "parse"), nrow(skipped))
  for (i in seq_len(nrow(skipped))) logf("SKIP %s: %s", skipped$gid[[i]], skipped$problem[[i]])
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition checked (no PDF read). No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_, restore_command = NA_character_, recorded_at = NA)))
  }
  if (!nrow(x)) .mig082_fail("every asset is skipped; nothing to do (no marker written).")

  bk_con <- st_connect(db, read_only = TRUE)
  tryCatch({
    .mig082_write_backups(bk_con, x, csv_dir)
    .mig082_write_csv(skipped, .mig082_csv(csv_dir, "SKIPPED"), "gid")
  }, finally = DBI::dbDisconnect(bk_con, shutdown = TRUE))
  logf("Row backups and the SKIPPED plan written to %s", csv_dir)
  backup_path <- mig082_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- if (is.null(.now)) Sys.time() else .now

  with_db_write(function(con) {
    again <- .mig082_problems(con, x, archive_dir)
    if (length(again)) .mig082_fail("a precondition changed since the dry check; re-run.")
    .mig082_apply(con, x, archive_dir, recorded_at, logf, csv_dir)
  }, db = db)

  logf("%s migrated successfully (marker %d).", .mig082_name, .mig082_marker_version)
  invisible(list(status = "migrated", backup_path = backup_path, restore_command = restore_command,
                 recorded_at = recorded_at))
}
