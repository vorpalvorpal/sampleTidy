# Operator-run migration: merge the legacy `asset` rows that share a content hash,
# keeping one canonical row per hash. Marker 1057. Requires 1056.
#
# Authority: Robin, 2026-10-20 (archive audit phase 2: "Legacy asset rows sharing a
# hash -> merge in the DB via a rehearsed migration"; canonical = the row whose
# processed/<uuid>/ dir exists, else the earliest).
#
# ---- WHAT ----------------------------------------------------------------------
#   The 149 rows of `057-merge-duplicate-hash-assets-INPUT.csv` (beside this file;
#   columns uuid, filename, hash, merged_into, merged_into_filename) are merged into
#   143 kept rows. The table was generated on a copy of live at 1052 + 053/054/055
#   (scratch dedupe2/gen057.R) from the 148 hash groups that remain after 055:
#     * every group member's own file processed/<uuid>/<filename> exists, so the
#       kept row is the EARLIEST archive copy (file mtime); 70 groups tie on mtime
#       to the second and are broken by: has a lab_qc_report, filename without a
#       "[n]" suffix, more of type/date/organisation/person filled, uuid;
#     * 5 groups (12 rows) are NOT merged and are left for Robin: 4 whose rows sit
#       in different projects (merging would drop a project link: 2400-7430-02
#       Lawson Landfill ES2439045/ES2439394, 2400-7399-04 April 2024, 2400-7400-09-01,
#       2400-7286-12-1) and 1 of three 0-byte files (ES2607384 QC/QCI/XTAB: empty
#       placeholders of different documents, not duplicates).
#   For each kept row (in one transaction):
#     * NULL fields are filled from its merged rows where those agree: date, type,
#       file_format, purpose, uuid_feature (any merged non-NULL values all equal);
#       person only from merged rows with the SAME organisation (the pair
#       describes one source);
#     * comments <- existing comments (if any), then
#       "2026-10-20 057: merged N duplicate asset row(s) with identical bytes
#       (hash H) into this one: <uuid> "<filename>" (<type>, <org> / <person>,
#       <date>); ...[; filled <fields> from them]; their archive copies under
#       processed/<uuid>/ are quarantined after this migration";
#   For each merged row:
#     * lab_qc_report rows on it: if the kept row already has a report of the same
#       kind, the merged row's report (and its lab_qc_outlier rows) is deleted (the
#       same bytes parsed twice); otherwise the report is re-pointed
#       (uuid_asset <- kept uuid);
#     * ingest_file rows with uuid_asset = it are re-pointed to the kept uuid
#       (none at generation time; checked again at run time);
#     * the asset row is deleted.
#   References found by scanning every VARCHAR column of every table for asset
#   uuids (2026-10-20): lab_qc_report.uuid_asset, ingest_file.uuid_asset (R/), and
#   change_log (history: deliberately NOT rewritten). Files are not touched: the
#   merged rows' archive copies become byte duplicates of the kept rows' files and
#   are quarantined AFTER this migration by
#     Rscript dev/processed-dedupe.R --post-import ... --merged dev/migrations/057-merge-duplicate-hash-assets-INPUT.csv
#
# ---- PRECONDITIONS (any failure aborts; nothing is written) ---------------------
#   * marker 1056 present;
#   * every INPUT row: the merged and the kept asset rows each exist exactly once
#     with that uuid, filename and hash, in the same project (or both NULL);
#   * per hash, the asset rows are exactly {kept} + its merged rows (no other row
#     shares the hash, so the table is not stale);
#   * no kept uuid is also a merged uuid; uuids distinct.
#
# Writes, in one transaction: field updates + comments on the kept rows, the
# lab_qc_report/lab_qc_outlier deletes or re-points, ingest_file re-points and
# 149 asset deletes, each with its change_log row (actor
# "057-merge-duplicate-hash-assets"), and the marker; every other table, row and
# column is checksummed before and after. Backups: verified whole-file snapshot,
# plus BACKUP CSVs of the asset rows (kept + merged, before), lab_qc_report and
# lab_qc_outlier rows touched, and ingest_file rows re-pointed.
#
# Idempotent: marker present -> re-verify, no-op.
#
#   devtools::load_all(".")
#   env <- new.env()
#   sys.source("dev/migrations/057-merge-duplicate-hash-assets.R", envir = env)
#   env$mig057_run(db = st_config("live_db"),
#                  snapshot_dir = st_config("snapshot_dir"), dry_run = TRUE)

.mig057_marker_version <- 1057L
.mig057_requires <- 1056L
.mig057_name <- "057-merge-duplicate-hash-assets"
.mig057_actor <- .mig057_name
.mig057_date <- "2026-10-20"
.mig057_reason <- "057 (Robin, 2026-10-20): legacy asset rows with identical bytes (same content hash) merged into one canonical row; references re-pointed"
.mig057_input_default <- file.path("dev", "migrations", "057-merge-duplicate-hash-assets-INPUT.csv")
.mig057_fill_fields <- c("date", "type", "file_format", "purpose", "uuid_feature")

.mig057_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = list(...))[[1]][[1]])
.mig057_fail <- function(msg) cli::cli_abort(paste0(.mig057_name, ": ", msg), class = "sampletidy_error")
.mig057_inlist <- function(x) if (!length(x)) "('')" else paste0("(", paste0("'", gsub("'", "''", x), "'", collapse = ","), ")")

.mig057_read_input <- function(path = .mig057_input_default) {
  if (!file.exists(path)) .mig057_fail(sprintf("input %s not found (run from the repo root).", path))
  x <- utils::read.csv(path, colClasses = "character", na.strings = "", encoding = "UTF-8", check.names = FALSE)
  need <- c("uuid", "filename", "hash", "merged_into", "merged_into_filename")
  if (!all(need %in% names(x))) .mig057_fail("input lacks columns uuid, filename, hash, merged_into, merged_into_filename")
  x[need]
}

.mig057_fmt_date <- function(d) if (is.na(d)) "no date" else format(as.POSIXct(d, tz = "UTC") + 11 * 3600, "%Y-%m-%d")
.mig057_desc <- function(r) {
  who <- paste(c(if (!is.na(r$organisation)) r$organisation, if (!is.na(r$person)) r$person), collapse = " / ")
  sprintf("%s \"%s\" (%s, %s, %s)", r$uuid, r$filename, if (is.na(r$type)) "no type" else r$type,
          if (nzchar(who)) who else "no organisation", .mig057_fmt_date(r$date))
}
.mig057_append <- function(old, note) if (is.na(old) || !nzchar(old)) note else paste0(old, "; ", note)

# The full write plan, computed from the DB as it is (deterministic for a given state).
.mig057_plan <- function(con, x) {
  ids <- unique(c(x$uuid, x$merged_into))
  A <- DBI::dbGetQuery(con, sprintf("SELECT * FROM asset WHERE uuid IN %s", .mig057_inlist(ids)))
  R <- DBI::dbGetQuery(con, sprintf("SELECT uuid, uuid_asset, kind FROM lab_qc_report WHERE uuid_asset IN %s", .mig057_inlist(ids)))
  I <- DBI::dbGetQuery(con, sprintf("SELECT hash, uuid_asset FROM ingest_file WHERE uuid_asset IN %s", .mig057_inlist(x$uuid)))
  updates <- list(); qc_delete <- character(); qc_repoint <- data.frame(uuid = character(), to = character())
  for (k in unique(x$merged_into)) {
    keep <- A[A$uuid == k, , drop = FALSE]
    mg <- A[A$uuid %in% x$uuid[x$merged_into == k], , drop = FALSE]
    mg <- mg[order(mg$uuid), , drop = FALSE]
    ch <- list(); filled <- character()
    for (f in .mig057_fill_fields) {
      v <- mg[[f]][!is.na(mg[[f]])]
      if (is.na(keep[[f]][[1]]) && length(v) && length(unique(.st_changelog_str(v))) == 1L) {
        ch[[f]] <- v[[1]]; filled <- c(filled, f)
      }
    }
    if (is.na(keep$person[[1]])) {
      same <- mg[!is.na(mg$organisation) & !is.na(keep$organisation[[1]]) &
                   mg$organisation == keep$organisation[[1]] & !is.na(mg$person), , drop = FALSE]
      if (nrow(same) && length(unique(same$person)) == 1L) { ch$person <- same$person[[1]]; filled <- c(filled, "person") }
    }
    descs <- vapply(seq_len(nrow(mg)), function(i) .mig057_desc(mg[i, , drop = FALSE]), "")
    note <- sprintf("%s 057: merged %d duplicate asset row(s) with identical bytes (hash %s) into this one: %s%s; their archive copies under processed/<uuid>/ are quarantined after this migration",
                    .mig057_date, nrow(mg), keep$hash[[1]], paste(descs, collapse = "; "),
                    if (length(filled)) sprintf("; filled %s from them", paste(filled, collapse = ", ")) else "")
    ch$comments <- .mig057_append(keep$comments[[1]], note)
    updates[[k]] <- ch
    kinds_keep <- R$kind[R$uuid_asset == k]
    for (m in mg$uuid) for (r in R$uuid[R$uuid_asset == m]) {
      kd <- R$kind[R$uuid == r]
      if (kd %in% kinds_keep) qc_delete <- c(qc_delete, r) else {
        qc_repoint[nrow(qc_repoint) + 1, ] <- list(r, k); kinds_keep <- c(kinds_keep, kd)
      }
    }
  }
  outl <- if (length(qc_delete)) DBI::dbGetQuery(con, sprintf("SELECT uuid FROM lab_qc_outlier WHERE uuid_report IN %s ORDER BY uuid",
                                                              .mig057_inlist(qc_delete)))$uuid else character()
  ing <- data.frame(hash = I$hash, to = x$merged_into[match(I$uuid_asset, x$uuid)], stringsAsFactors = FALSE)
  n_upd <- sum(vapply(updates, length, 0L))
  list(updates = updates, qc_delete = qc_delete, qc_outlier_delete = outl, qc_repoint = qc_repoint,
       ingest_repoint = ing, asset_delete = x$uuid,
       n_change_log = n_upd + length(outl) + length(qc_delete) + nrow(qc_repoint) + nrow(ing) + nrow(x))
}

.mig057_counts <- function(con) {
  tabs <- c("ingest_file", "ingest_sighting", "project", "sample", "analysis", "asset", "lab_qc_report",
            "lab_qc_outlier", "review_queue", "change_log", "schema_version")
  stats::setNames(lapply(tabs, function(t) .mig057_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
}

.mig057_problems <- function(con, x) {
  probs <- character(0)
  if (anyDuplicated(x$uuid)) probs <- c(probs, "merged uuids repeat in the input")
  if (any(x$uuid %in% x$merged_into)) probs <- c(probs, "a kept uuid is also listed as merged")
  if (any(tapply(x$merged_into, x$hash, function(v) length(unique(v))) != 1L))
    probs <- c(probs, "a hash maps to more than one kept uuid")
  A <- DBI::dbGetQuery(con, sprintf("SELECT uuid, filename, hash, uuid_project FROM asset WHERE hash IN %s",
                                    .mig057_inlist(unique(x$hash))))
  chk <- function(u, fn, h) {
    r <- A[A$uuid == u, , drop = FALSE]
    if (nrow(r) != 1L || !identical(r$filename[[1]], fn) || !identical(r$hash[[1]], h))
      sprintf("asset %s (%s, %s): not exactly one row with that uuid/filename/hash", u, fn, h) else NULL
  }
  for (i in seq_len(nrow(x))) {
    probs <- c(probs, chk(x$uuid[[i]], x$filename[[i]], x$hash[[i]]),
               chk(x$merged_into[[i]], x$merged_into_filename[[i]], x$hash[[i]]))
    p1 <- A$uuid_project[A$uuid == x$uuid[[i]]]; p2 <- A$uuid_project[A$uuid == x$merged_into[[i]]]
    if (length(p1) == 1L && length(p2) == 1L && !identical(p1, p2))
      probs <- c(probs, sprintf("asset %s and %s are in different projects", x$uuid[[i]], x$merged_into[[i]]))
  }
  for (h in unique(x$hash)) {
    want <- sort(unique(c(x$uuid[x$hash == h], x$merged_into[x$hash == h])))
    got <- sort(A$uuid[A$hash == h])
    if (!identical(want, got)) probs <- c(probs, sprintf("hash %s: asset rows are {%s}, the input expects {%s}",
                                                         h, paste(got, collapse = " "), paste(want, collapse = " ")))
  }
  unique(probs)
}

.mig057_check_preconditions <- function(con, x) {
  if (.mig057_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig057_requires) == 0L)
    .mig057_fail(sprintf("marker %d (056) is required first.", .mig057_requires))
  probs <- .mig057_problems(con, x)
  if (length(probs)) .mig057_fail(sprintf("%d problem(s): %s. Nothing written.", length(probs),
                                          paste(utils::head(probs, 10), collapse = " | ")))
  invisible(TRUE)
}

.mig057_checksum <- function(con, x, plan) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  tabs <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  touched <- c("asset", "lab_qc_report", "lab_qc_outlier", "ingest_file", "change_log", "schema_version")
  out <- lapply(setdiff(tabs, touched), function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- setdiff(tabs, touched)
  ids <- .mig057_inlist(unique(c(x$uuid, x$merged_into)))
  keep <- .mig057_inlist(unique(x$merged_into))
  out$asset_rest <- q(sprintf("SELECT * FROM asset WHERE uuid NOT IN %s ORDER BY uuid", ids))
  out$asset_kept <- q(sprintf("SELECT uuid, name, filename, hash, organisation, uuid_project FROM asset WHERE uuid IN %s ORDER BY uuid", keep))
  out$qc_report <- q(sprintf("SELECT * EXCLUDE (uuid_asset) FROM lab_qc_report WHERE uuid NOT IN %s ORDER BY uuid",
                             .mig057_inlist(plan$qc_delete)))
  out$qc_report_ptr <- q(sprintf("SELECT uuid, uuid_asset FROM lab_qc_report WHERE uuid NOT IN %s ORDER BY uuid",
                                 .mig057_inlist(c(plan$qc_delete, plan$qc_repoint$uuid))))
  out$qc_outlier <- q(sprintf("SELECT * FROM lab_qc_outlier WHERE uuid NOT IN %s ORDER BY uuid", .mig057_inlist(plan$qc_outlier_delete)))
  out$ingest_file <- q("SELECT * EXCLUDE (uuid_asset) FROM ingest_file ORDER BY hash")
  out$ingest_ptr <- q(sprintf("SELECT hash, uuid_asset FROM ingest_file WHERE hash NOT IN %s ORDER BY hash",
                              .mig057_inlist(plan$ingest_repoint$hash)))
  out$change_log_rest <- q(sprintf("SELECT * FROM change_log WHERE actor <> '%s' ORDER BY ALL", .mig057_actor))
  out$schema_version_rest <- q(sprintf("SELECT * FROM schema_version WHERE version <> %d ORDER BY ALL", .mig057_marker_version))
  out$views <- q("SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
  out$indexes <- q("SELECT index_name, sql FROM duckdb_indexes() ORDER BY index_name")
  out
}

.mig057_done_problem <- function(con, x) {
  if (.mig057_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig057_marker_version) != 1L)
    return("marker 1057 missing")
  n <- .mig057_scalar(con, sprintf("SELECT COUNT(*) FROM asset WHERE uuid IN %s", .mig057_inlist(x$uuid)))
  if (n != 0L) return(sprintf("%d merged asset row(s) still present", n))
  K <- DBI::dbGetQuery(con, sprintf("SELECT uuid, filename, hash, comments FROM asset WHERE uuid IN %s",
                                    .mig057_inlist(unique(x$merged_into))))
  if (nrow(K) != length(unique(x$merged_into))) return("a kept asset row is missing")
  for (k in K$uuid) {
    r <- K[K$uuid == k, ]; xi <- x[x$merged_into == k, , drop = FALSE]
    if (!identical(r$filename, xi$merged_into_filename[[1]]) || !identical(r$hash, xi$hash[[1]]))
      return(sprintf("kept asset %s renamed or re-hashed", k))
    if (is.na(r$comments) || !grepl(paste0(.mig057_date, " 057: merged ", nrow(xi), " duplicate"), r$comments, fixed = TRUE) ||
        !all(vapply(xi$uuid, function(u) grepl(u, r$comments, fixed = TRUE), TRUE)))
      return(sprintf("kept asset %s comments lack the 057 note naming its merged rows", k))
  }
  dup <- .mig057_scalar(con, sprintf("SELECT COUNT(*) FROM (SELECT hash FROM asset WHERE hash IN %s GROUP BY hash HAVING count(*) > 1)",
                                     .mig057_inlist(unique(x$hash))))
  if (dup != 0L) return(sprintf("%d merged hash(es) still have more than one asset row", dup))
  n <- .mig057_scalar(con, sprintf("SELECT COUNT(*) FROM lab_qc_report WHERE uuid_asset IN %s", .mig057_inlist(x$uuid)))
  if (n != 0L) return(sprintf("%d lab_qc_report row(s) still point at a merged asset", n))
  n <- .mig057_scalar(con, sprintf("SELECT COUNT(*) FROM ingest_file WHERE uuid_asset IN %s", .mig057_inlist(x$uuid)))
  if (n != 0L) return(sprintf("%d ingest_file row(s) still point at a merged asset", n))
  n <- .mig057_scalar(con, "SELECT COUNT(*) FROM lab_qc_outlier o WHERE NOT EXISTS (SELECT 1 FROM lab_qc_report r WHERE r.uuid = o.uuid_report)")
  if (n != 0L) return(sprintf("%d lab_qc_outlier row(s) are orphaned", n))
  cl <- DBI::dbGetQuery(con, "SELECT tbl, action, field, uuid_row, old, new FROM change_log WHERE actor = ?",
                        params = list(.mig057_actor))
  del <- cl[cl$tbl == "asset" & cl$action == "delete", , drop = FALSE]
  if (nrow(del) != nrow(x) || !setequal(del$uuid_row, x$uuid)) return("asset delete change_log rows do not match the input")
  up <- cl[cl$tbl == "asset" & cl$action == "update", , drop = FALSE]
  if (!setequal(up$uuid_row[up$field == "comments"], unique(x$merged_into)) || sum(up$field == "comments") != length(unique(x$merged_into)))
    return("comments change_log rows do not match the kept rows")
  for (i in seq_len(nrow(up))) {
    cur <- DBI::dbGetQuery(con, sprintf('SELECT "%s" AS v FROM asset WHERE uuid = ?', up$field[[i]]), params = list(up$uuid_row[[i]]))$v
    if (!identical(.st_changelog_str(cur[[1]]), up$new[[i]])) return(sprintf("asset %s %s is not the logged new value", up$uuid_row[[i]], up$field[[i]]))
    if (up$field[[i]] != "comments" && !is.na(up$old[[i]])) return(sprintf("asset %s %s fill overwrote a value", up$uuid_row[[i]], up$field[[i]]))
  }
  NULL
}

.mig057_verify <- function(con, x) {
  p <- .mig057_done_problem(con, x)
  if (!is.null(p)) cli::cli_abort(paste0("057 verify failed: ", p), class = "sampletidy_error")
  invisible(TRUE)
}

mig057_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- if (is.null(.now)) Sys.time() else .now
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig057_name, ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig057_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig057_counts(verify_con)))
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  dest
}

.mig057_write_csv <- function(df, path, key) {
  out <- df
  for (f in names(out)) if (inherits(out[[f]], c("POSIXct", "Date"))) out[[f]] <- .st_changelog_str(out[[f]])
  utils::write.csv(out, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8", colClasses = "character")
  if (nrow(back) != nrow(df) || !identical(back[[key]], as.character(out[[key]])))
    cli::cli_abort("057: CSV {basename(path)} did not round-trip.", class = "sampletidy_error")
}

.mig057_apply <- function(con, x, recorded_at) {
  plan <- .mig057_plan(con, x)
  sums_before <- .mig057_checksum(con, x, plan)
  want <- .mig057_counts(con)
  want$asset <- want$asset - nrow(x)
  want$lab_qc_report <- want$lab_qc_report - length(plan$qc_delete)
  want$lab_qc_outlier <- want$lab_qc_outlier - length(plan$qc_outlier_delete)
  want$change_log <- want$change_log + plan$n_change_log
  want$schema_version <- want$schema_version + 1L
  db_transaction(con, function(con) {
    for (k in names(plan$updates))
      db_update(con, "asset", uuid = k, changes = plan$updates[[k]], actor = .mig057_actor, reason = .mig057_reason)
    for (o in plan$qc_outlier_delete) db_delete(con, "lab_qc_outlier", uuid = o, actor = .mig057_actor, reason = .mig057_reason)
    for (r in plan$qc_delete) db_delete(con, "lab_qc_report", uuid = r, actor = .mig057_actor,
                                        reason = paste(.mig057_reason, "- the kept asset already has a report of this kind for the same bytes"))
    for (i in seq_len(nrow(plan$qc_repoint)))
      db_update(con, "lab_qc_report", uuid = plan$qc_repoint$uuid[[i]], changes = list(uuid_asset = plan$qc_repoint$to[[i]]),
                actor = .mig057_actor, reason = .mig057_reason)
    for (i in seq_len(nrow(plan$ingest_repoint)))
      db_update(con, "ingest_file", key = list(hash = plan$ingest_repoint$hash[[i]]),
                changes = list(uuid_asset = plan$ingest_repoint$to[[i]]), actor = .mig057_actor, reason = .mig057_reason)
    for (u in plan$asset_delete)
      db_delete(con, "asset", uuid = u, actor = .mig057_actor,
                reason = sprintf("%s - merged into %s", .mig057_reason, x$merged_into[x$uuid == u]))
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig057_marker_version, recorded_at))
    .mig057_verify(con, x)
    got <- .mig057_counts(con)
    if (!identical(got, want))
      .mig057_fail(sprintf("counts are not as planned: %s",
                           paste(names(got), unlist(got), unlist(want), sep = ":", collapse = ", ")))
    if (!identical(sums_before, .mig057_checksum(con, x, plan))) .mig057_fail("something outside the planned rows/columns moved.")
    NULL
  })
  invisible(plan)
}

mig057_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL,
                       input = .mig057_input_default) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir
  x <- .mig057_read_input(input)

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(
    DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                    params = list(.mig057_marker_version)),
    finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch(.mig057_verify(check_con, x), finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("057 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  plan <- tryCatch({ .mig057_check_preconditions(pre_con, x); .mig057_plan(pre_con, x) },
                   finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  nf <- table(unlist(lapply(plan$updates, function(u) setdiff(names(u), "comments"))))
  logf("Plan: merge %d asset rows into %d kept rows (%d hashes); fills %s; lab_qc_report: %d deleted (+%d outliers), %d re-pointed; ingest_file re-pointed: %d; change_log rows: %d.",
       nrow(x), length(plan$updates), length(unique(x$hash)),
       if (length(nf)) paste(names(nf), nf, sep = " x", collapse = ", ") else "none",
       length(plan$qc_delete), length(plan$qc_outlier_delete), nrow(plan$qc_repoint), nrow(plan$ingest_repoint),
       plan$n_change_log)
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition passed. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_, restore_command = NA_character_,
                          recorded_at = NA, plan = plan)))
  }

  bk_con <- st_connect(db, read_only = TRUE)
  tryCatch({
    ids <- .mig057_inlist(unique(c(x$uuid, x$merged_into)))
    .mig057_write_csv(DBI::dbGetQuery(bk_con, sprintf("SELECT * FROM asset WHERE uuid IN %s ORDER BY uuid", ids)),
                      file.path(csv_dir, sprintf("%s-BACKUP-asset.csv", .mig057_name)), "uuid")
    .mig057_write_csv(DBI::dbGetQuery(bk_con, sprintf("SELECT * FROM lab_qc_report WHERE uuid_asset IN %s ORDER BY uuid", ids)),
                      file.path(csv_dir, sprintf("%s-BACKUP-lab_qc_report.csv", .mig057_name)), "uuid")
    .mig057_write_csv(DBI::dbGetQuery(bk_con, sprintf("SELECT * FROM lab_qc_outlier WHERE uuid IN %s ORDER BY uuid",
                                                      .mig057_inlist(plan$qc_outlier_delete))),
                      file.path(csv_dir, sprintf("%s-BACKUP-lab_qc_outlier.csv", .mig057_name)), "uuid")
    .mig057_write_csv(DBI::dbGetQuery(bk_con, sprintf("SELECT * FROM ingest_file WHERE uuid_asset IN %s ORDER BY hash",
                                                      .mig057_inlist(x$uuid))),
                      file.path(csv_dir, sprintf("%s-BACKUP-ingest_file.csv", .mig057_name)), "hash")
  }, finally = DBI::dbDisconnect(bk_con, shutdown = TRUE))
  logf("Row backups written to %s", csv_dir)
  backup_path <- mig057_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- if (is.null(.now)) Sys.time() else .now

  with_db_write(function(con) {
    .mig057_check_preconditions(con, x)   # re-read under the write lock
    .mig057_apply(con, x, recorded_at)
  }, db = db)

  logf("%s migrated successfully (marker %d): %d asset rows merged into %d.",
       .mig057_name, .mig057_marker_version, nrow(x), length(unique(x$merged_into)))
  invisible(list(status = "migrated", backup_path = backup_path,
                 restore_command = restore_command, recorded_at = recorded_at))
}
