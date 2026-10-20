# Operator-run migration: resolve the 12 legacy duplicate-hash asset rows that 057
# left for a ruling. Marker 1061. Requires 1059.
#
# Authority: Robin, 2026-10-20 ("YES, apply your recommendation for each, and leave
# a comment on each affected asset/project row"), on the recommendations in the
# phase-2 dedupe (scratch dedupe2/ask_robin_remaining.csv).
#
# ---- WHAT ----------------------------------------------------------------------
#   Input: `061-resolve-ask-robin-assets-INPUT.csv` beside this file (columns uuid,
#   filename, hash, uuid_project, merged_into (empty), action, migration). It is
#   also a --merged input for dev/processed-dedupe.R.
#   A. action "keep" (9 rows, 4 hash groups): one ACIRL report PDF filed under two
#      (or three) projects - 2400-7430-02 Nov 2024 Lawson Landfill (ES2439045 /
#      ES2439394), 2400-7399-04 April 2024 Monthly Blaxland (ES2412736 + two Dust
#      monitoring projects), 2400-7400-09-01 September 2024 Quarterly Katoomba
#      (ES2434371 / ES2436938), 2400-7286-12-1 December 2023 Quarterly Blaxland
#      (Water & Dust) (ES2344024 + a Dust monitoring project). asset has one
#      uuid_project, so a report that belongs to two projects needs two rows: these
#      are NOT duplicates. Each row is kept and gets
#        comments <- existing; "2026-10-20 061: same bytes (hash H) as asset(s) <uuid>
#        (project <name>) ...; kept as a separate asset row: one report filed under
#        more than one project, not a duplicate (Robin, 2026-10-20)".
#      Projects are not changed (nothing about them changes).
#   B. action "retire" (3 rows, project ES2607384): ES2607384_0_QC.pdf, _0_QCI.pdf
#      and _0_XTAB.XLS are 0-byte files (their shared hash is the hash of nothing):
#      failed downloads of three different documents, holding no evidence. The 3
#      asset rows are deleted, with their lab_qc_report rows (status 'unreadable',
#      "the file is empty") and any lab_qc_outlier rows; any ingest_file row
#      pointing at them gets uuid_asset NULL. The project ES2607384 gets
#        comments <- existing; "2026-10-20 061: deleted 3 asset rows whose archived
#        files were 0 bytes (...); the QC and QCI reports need re-fetching from ALS
#        (the results are in ES2607384_0_XTAB.csv)".
#   Files are not touched. The 3 empty files become orphans and are quarantined after
#   this migration by dev/processed-dedupe.R --post-import --merged <057 INPUT>,<061 INPUT>.
#
# ---- PRECONDITIONS (any failure aborts; nothing is written) ---------------------
#   * marker 1059 present;
#   * every INPUT row exists exactly once with its uuid, filename, hash, uuid_project;
#   * per hash, the asset rows are exactly the listed rows (the input is not stale);
#   * retire rows all carry the empty-file hash.
#
# Writes, in one transaction: 9 asset comments, the deletes / NULLings of part B,
# 1 project comment, each with its change_log row (actor
# "061-resolve-ask-robin-assets"), and the marker; every other table, row and column
# is checksummed before and after. Backups: verified whole-file snapshot, plus BACKUP
# CSVs of the 12 asset rows, the project row, and the lab_qc_report / lab_qc_outlier /
# ingest_file rows touched.
#
# Idempotent: marker present -> re-verify, no-op.

.mig061_marker_version <- 1061L
.mig061_requires <- 1059L
.mig061_name <- "061-resolve-ask-robin-assets"
.mig061_actor <- .mig061_name
.mig061_date <- "2026-10-20"
.mig061_reason <- "061 (Robin, 2026-10-20): resolve the legacy duplicate-hash asset rows 057 left for a ruling"
.mig061_input_default <- file.path("dev", "migrations", "061-resolve-ask-robin-assets-INPUT.csv")
.mig061_empty_hash <- "99aa06d3014798d86001c324468d497f"   # rlang::hash_file() of a 0-byte file

.mig061_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = list(...))[[1]][[1]])
.mig061_fail <- function(msg) cli::cli_abort(paste0(.mig061_name, ": ", msg), class = "sampletidy_error")
.mig061_inlist <- function(x) if (!length(x)) "('')" else paste0("(", paste0("'", gsub("'", "''", x), "'", collapse = ","), ")")
.mig061_append <- function(old, note) if (is.na(old) || !nzchar(old)) note else paste0(old, "; ", note)

.mig061_read_input <- function(path = .mig061_input_default) {
  if (!file.exists(path)) .mig061_fail(sprintf("input %s not found (run from the repo root).", path))
  x <- utils::read.csv(path, colClasses = "character", na.strings = "", encoding = "UTF-8", check.names = FALSE)
  need <- c("uuid", "filename", "hash", "uuid_project", "action")
  if (!all(need %in% names(x))) .mig061_fail("input lacks columns uuid, filename, hash, uuid_project, action")
  if (!all(x$action %in% c("keep", "retire"))) .mig061_fail("input action must be keep or retire")
  x[need]
}

.mig061_pname <- function(P, u) {
  n <- P$name[match(u, P$uuid)]
  ifelse(is.na(n), paste0("unnamed ", P$type[match(u, P$uuid)], " project ", u), n)
}

.mig061_plan <- function(con, x) {
  P <- DBI::dbGetQuery(con, sprintf("SELECT uuid, name, type, comments FROM project WHERE uuid IN %s",
                                    .mig061_inlist(unique(x$uuid_project))))
  A <- DBI::dbGetQuery(con, sprintf("SELECT uuid, filename, hash, comments FROM asset WHERE uuid IN %s", .mig061_inlist(x$uuid)))
  keep <- x[x$action == "keep", , drop = FALSE]; ret <- x[x$action == "retire", , drop = FALSE]
  asset_comments <- list()
  for (i in seq_len(nrow(keep))) {
    sib <- keep[keep$hash == keep$hash[[i]] & keep$uuid != keep$uuid[[i]], , drop = FALSE]
    note <- sprintf("%s 061: same bytes (hash %s) as asset(s) %s; kept as a separate asset row: one report filed under more than one project (this row: %s), not a duplicate (Robin, %s)",
                    .mig061_date, keep$hash[[i]],
                    paste(sprintf("%s (project %s)", sib$uuid, .mig061_pname(P, sib$uuid_project)), collapse = ", "),
                    .mig061_pname(P, keep$uuid_project[[i]]), .mig061_date)
    asset_comments[[keep$uuid[[i]]]] <- .mig061_append(A$comments[A$uuid == keep$uuid[[i]]], note)
  }
  project_comments <- list()
  for (p in unique(ret$uuid_project)) {
    r <- ret[ret$uuid_project == p, , drop = FALSE]
    note <- sprintf("%s 061: deleted %d asset row(s) whose archived files were 0 bytes (%s) and their 'unreadable' lab QC report rows; the QC and QCI reports need re-fetching from ALS (the results are in %s_0_XTAB.csv) (Robin, %s)",
                    .mig061_date, nrow(r), paste(sprintf("%s %s", r$filename, r$uuid), collapse = ", "),
                    .mig061_pname(P, p), .mig061_date)
    project_comments[[p]] <- .mig061_append(P$comments[P$uuid == p], note)
  }
  qc <- DBI::dbGetQuery(con, sprintf("SELECT uuid FROM lab_qc_report WHERE uuid_asset IN %s ORDER BY uuid", .mig061_inlist(ret$uuid)))$uuid
  outl <- if (length(qc)) DBI::dbGetQuery(con, sprintf("SELECT uuid FROM lab_qc_outlier WHERE uuid_report IN %s ORDER BY uuid",
                                                       .mig061_inlist(qc)))$uuid else character()
  ing <- DBI::dbGetQuery(con, sprintf("SELECT hash FROM ingest_file WHERE uuid_asset IN %s ORDER BY hash", .mig061_inlist(ret$uuid)))$hash
  list(asset_comments = asset_comments, project_comments = project_comments, qc_delete = qc,
       qc_outlier_delete = outl, ingest_null = ing, asset_delete = ret$uuid,
       n_change_log = length(asset_comments) + length(project_comments) + length(qc) + length(outl) +
         length(ing) + nrow(ret))
}

.mig061_counts <- function(con) {
  tabs <- c("ingest_file", "ingest_sighting", "project", "sample", "analysis", "asset", "lab_qc_report",
            "lab_qc_outlier", "review_queue", "change_log", "schema_version")
  stats::setNames(lapply(tabs, function(t) .mig061_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
}

.mig061_problems <- function(con, x) {
  probs <- character(0)
  if (anyDuplicated(x$uuid)) probs <- c(probs, "uuids repeat in the input")
  if (any(x$hash[x$action == "retire"] != .mig061_empty_hash)) probs <- c(probs, "a retire row does not carry the empty-file hash")
  A <- DBI::dbGetQuery(con, sprintf("SELECT uuid, filename, hash, uuid_project FROM asset WHERE hash IN %s",
                                    .mig061_inlist(unique(x$hash))))
  for (i in seq_len(nrow(x))) {
    r <- A[A$uuid == x$uuid[[i]], , drop = FALSE]
    if (nrow(r) != 1L || !identical(r$filename[[1]], x$filename[[i]]) || !identical(r$hash[[1]], x$hash[[i]]) ||
        !identical(r$uuid_project[[1]], x$uuid_project[[i]]))
      probs <- c(probs, sprintf("asset %s (%s): not exactly one row with that uuid/filename/hash/project", x$uuid[[i]], x$filename[[i]]))
  }
  for (h in unique(x$hash)) {
    want <- sort(x$uuid[x$hash == h]); got <- sort(A$uuid[A$hash == h])
    if (!identical(want, got)) probs <- c(probs, sprintf("hash %s: asset rows are {%s}, the input expects {%s}",
                                                         h, paste(got, collapse = " "), paste(want, collapse = " ")))
  }
  n <- .mig061_scalar(con, sprintf("SELECT COUNT(*) FROM project WHERE uuid IN %s", .mig061_inlist(unique(x$uuid_project))))
  if (n != length(unique(x$uuid_project))) probs <- c(probs, "a project of the input is missing")
  unique(probs)
}

.mig061_check_preconditions <- function(con, x) {
  if (.mig061_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig061_requires) == 0L)
    .mig061_fail(sprintf("marker %d (059) is required first.", .mig061_requires))
  probs <- .mig061_problems(con, x)
  if (length(probs)) .mig061_fail(sprintf("%d problem(s): %s. Nothing written.", length(probs), paste(probs, collapse = " | ")))
  invisible(TRUE)
}

.mig061_checksum <- function(con, x, plan) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  tabs <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  touched <- c("asset", "project", "lab_qc_report", "lab_qc_outlier", "ingest_file", "change_log", "schema_version")
  out <- lapply(setdiff(tabs, touched), function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- setdiff(tabs, touched)
  out$asset_rest <- q(sprintf("SELECT * FROM asset WHERE uuid NOT IN %s ORDER BY uuid", .mig061_inlist(x$uuid)))
  out$asset_kept <- q(sprintf("SELECT * EXCLUDE (comments) FROM asset WHERE uuid IN %s ORDER BY uuid",
                              .mig061_inlist(x$uuid[x$action == "keep"])))
  pc <- names(plan$project_comments)
  out$project_rest <- q(sprintf("SELECT * FROM project WHERE uuid NOT IN %s ORDER BY uuid", .mig061_inlist(pc)))
  out$project_cmt <- q(sprintf("SELECT * EXCLUDE (comments) FROM project WHERE uuid IN %s ORDER BY uuid", .mig061_inlist(pc)))
  out$qc_report <- q(sprintf("SELECT * FROM lab_qc_report WHERE uuid NOT IN %s ORDER BY uuid", .mig061_inlist(plan$qc_delete)))
  out$qc_outlier <- q(sprintf("SELECT * FROM lab_qc_outlier WHERE uuid NOT IN %s ORDER BY uuid", .mig061_inlist(plan$qc_outlier_delete)))
  out$ingest_file <- q("SELECT * EXCLUDE (uuid_asset) FROM ingest_file ORDER BY hash")
  out$ingest_ptr <- q(sprintf("SELECT hash, uuid_asset FROM ingest_file WHERE hash NOT IN %s ORDER BY hash", .mig061_inlist(plan$ingest_null)))
  out$change_log_rest <- q(sprintf("SELECT * FROM change_log WHERE actor <> '%s' ORDER BY ALL", .mig061_actor))
  out$schema_version_rest <- q(sprintf("SELECT * FROM schema_version WHERE version <> %d ORDER BY ALL", .mig061_marker_version))
  out$views <- q("SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
  out$indexes <- q("SELECT index_name, sql FROM duckdb_indexes() ORDER BY index_name")
  out
}

.mig061_done_problem <- function(con, x) {
  if (.mig061_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig061_marker_version) != 1L)
    return("marker 1061 missing")
  ret <- x[x$action == "retire", , drop = FALSE]; keep <- x[x$action == "keep", , drop = FALSE]
  if (.mig061_scalar(con, sprintf("SELECT COUNT(*) FROM asset WHERE uuid IN %s", .mig061_inlist(ret$uuid))) != 0L)
    return("a retired asset row is still present")
  if (.mig061_scalar(con, sprintf("SELECT COUNT(*) FROM lab_qc_report WHERE uuid_asset IN %s", .mig061_inlist(ret$uuid))) != 0L)
    return("a lab_qc_report row still points at a retired asset")
  if (.mig061_scalar(con, sprintf("SELECT COUNT(*) FROM ingest_file WHERE uuid_asset IN %s", .mig061_inlist(ret$uuid))) != 0L)
    return("an ingest_file row still points at a retired asset")
  if (.mig061_scalar(con, "SELECT COUNT(*) FROM lab_qc_outlier o WHERE NOT EXISTS (SELECT 1 FROM lab_qc_report r WHERE r.uuid = o.uuid_report)") != 0L)
    return("orphaned lab_qc_outlier rows")
  K <- DBI::dbGetQuery(con, sprintf("SELECT uuid, filename, hash, uuid_project, comments FROM asset WHERE uuid IN %s", .mig061_inlist(keep$uuid)))
  if (nrow(K) != nrow(keep)) return("a kept asset row is missing")
  for (i in seq_len(nrow(keep))) {
    r <- K[K$uuid == keep$uuid[[i]], ]
    sib <- setdiff(keep$uuid[keep$hash == keep$hash[[i]]], keep$uuid[[i]])
    if (!identical(r$hash, keep$hash[[i]]) || !identical(r$uuid_project, keep$uuid_project[[i]])) return(sprintf("kept asset %s changed", r$uuid))
    if (is.na(r$comments) || !grepl(paste0(.mig061_date, " 061: same bytes"), r$comments, fixed = TRUE) ||
        !all(vapply(sib, function(u) grepl(u, r$comments, fixed = TRUE), TRUE)))
      return(sprintf("kept asset %s comments lack the 061 note naming its sibling rows", r$uuid))
  }
  for (p in unique(ret$uuid_project)) {
    cm <- DBI::dbGetQuery(con, "SELECT comments FROM project WHERE uuid = ?", params = list(p))$comments
    if (length(cm) != 1L || is.na(cm) || !grepl(paste0(.mig061_date, " 061: deleted"), cm, fixed = TRUE))
      return(sprintf("project %s comments lack the 061 note", p))
  }
  cl <- DBI::dbGetQuery(con, "SELECT tbl, action, field, uuid_row FROM change_log WHERE actor = ?", params = list(.mig061_actor))
  if (!setequal(cl$uuid_row[cl$tbl == "asset" & cl$action == "delete"], ret$uuid) || sum(cl$tbl == "asset" & cl$action == "delete") != nrow(ret))
    return("asset delete change_log rows do not match the input")
  if (!setequal(cl$uuid_row[cl$tbl == "asset" & cl$action == "update"], keep$uuid) || sum(cl$tbl == "asset" & cl$action == "update") != nrow(keep))
    return("asset comment change_log rows do not match the input")
  NULL
}

.mig061_verify <- function(con, x) {
  p <- .mig061_done_problem(con, x)
  if (!is.null(p)) cli::cli_abort(paste0("061 verify failed: ", p), class = "sampletidy_error")
  invisible(TRUE)
}

mig061_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- if (is.null(.now)) Sys.time() else .now
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig061_name, ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig061_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig061_counts(verify_con)))
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  dest
}

.mig061_write_csv <- function(df, path, key) {
  out <- df
  for (f in names(out)) if (inherits(out[[f]], c("POSIXct", "Date"))) out[[f]] <- .st_changelog_str(out[[f]])
  utils::write.csv(out, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8", colClasses = "character")
  if (nrow(back) != nrow(df) || !identical(back[[key]], as.character(out[[key]])))
    cli::cli_abort("061: CSV {basename(path)} did not round-trip.", class = "sampletidy_error")
}

.mig061_apply <- function(con, x, recorded_at) {
  plan <- .mig061_plan(con, x)
  sums_before <- .mig061_checksum(con, x, plan)
  want <- .mig061_counts(con)
  want$asset <- want$asset - length(plan$asset_delete)
  want$lab_qc_report <- want$lab_qc_report - length(plan$qc_delete)
  want$lab_qc_outlier <- want$lab_qc_outlier - length(plan$qc_outlier_delete)
  want$change_log <- want$change_log + plan$n_change_log
  want$schema_version <- want$schema_version + 1L
  db_transaction(con, function(con) {
    for (u in names(plan$asset_comments))
      db_update(con, "asset", uuid = u, changes = list(comments = plan$asset_comments[[u]]),
                actor = .mig061_actor, reason = paste(.mig061_reason, "- one report filed under more than one project: kept"))
    for (o in plan$qc_outlier_delete) db_delete(con, "lab_qc_outlier", uuid = o, actor = .mig061_actor, reason = .mig061_reason)
    for (r in plan$qc_delete) db_delete(con, "lab_qc_report", uuid = r, actor = .mig061_actor,
                                        reason = paste(.mig061_reason, "- report row of a 0-byte file"))
    for (h in plan$ingest_null)
      db_update(con, "ingest_file", key = list(hash = h), changes = list(uuid_asset = NA_character_),
                actor = .mig061_actor, reason = .mig061_reason)
    for (u in plan$asset_delete)
      db_delete(con, "asset", uuid = u, actor = .mig061_actor, reason = paste(.mig061_reason, "- the archived file is 0 bytes"))
    for (p in names(plan$project_comments))
      db_update(con, "project", uuid = p, changes = list(comments = plan$project_comments[[p]]),
                actor = .mig061_actor, reason = .mig061_reason)
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig061_marker_version, recorded_at))
    .mig061_verify(con, x)
    got <- .mig061_counts(con)
    if (!identical(got, want))
      .mig061_fail(sprintf("counts are not as planned: %s", paste(names(got), unlist(got), unlist(want), sep = ":", collapse = ", ")))
    if (!identical(sums_before, .mig061_checksum(con, x, plan))) .mig061_fail("something outside the planned rows/columns moved.")
    NULL
  })
  invisible(plan)
}

mig061_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL,
                       input = .mig061_input_default) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir
  x <- .mig061_read_input(input)

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(
    DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                    params = list(.mig061_marker_version)),
    finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch(.mig061_verify(check_con, x), finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("061 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  plan <- tryCatch({ .mig061_check_preconditions(pre_con, x); .mig061_plan(pre_con, x) },
                   finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  logf("Plan: keep + comment %d asset rows (%d hash groups); delete %d 0-byte asset rows, %d lab_qc_report (+%d outliers), %d ingest_file pointers NULLed; comment %d project(s); change_log rows: %d.",
       length(plan$asset_comments), length(unique(x$hash[x$action == "keep"])), length(plan$asset_delete),
       length(plan$qc_delete), length(plan$qc_outlier_delete), length(plan$ingest_null),
       length(plan$project_comments), plan$n_change_log)
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition passed. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_, restore_command = NA_character_,
                          recorded_at = NA, plan = plan)))
  }

  bk_con <- st_connect(db, read_only = TRUE)
  tryCatch({
    w <- function(sql, tbl, key) .mig061_write_csv(DBI::dbGetQuery(bk_con, sql),
                                                   file.path(csv_dir, sprintf("%s-BACKUP-%s.csv", .mig061_name, tbl)), key)
    w(sprintf("SELECT * FROM asset WHERE uuid IN %s ORDER BY uuid", .mig061_inlist(x$uuid)), "asset", "uuid")
    w(sprintf("SELECT * FROM project WHERE uuid IN %s ORDER BY uuid", .mig061_inlist(names(plan$project_comments))), "project", "uuid")
    w(sprintf("SELECT * FROM lab_qc_report WHERE uuid IN %s ORDER BY uuid", .mig061_inlist(plan$qc_delete)), "lab_qc_report", "uuid")
    w(sprintf("SELECT * FROM lab_qc_outlier WHERE uuid IN %s ORDER BY uuid", .mig061_inlist(plan$qc_outlier_delete)), "lab_qc_outlier", "uuid")
    w(sprintf("SELECT * FROM ingest_file WHERE hash IN %s ORDER BY hash", .mig061_inlist(plan$ingest_null)), "ingest_file", "hash")
  }, finally = DBI::dbDisconnect(bk_con, shutdown = TRUE))
  logf("Row backups written to %s", csv_dir)
  backup_path <- mig061_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- if (is.null(.now)) Sys.time() else .now

  with_db_write(function(con) {
    .mig061_check_preconditions(con, x)   # re-read under the write lock
    .mig061_apply(con, x, recorded_at)
  }, db = db)

  logf("%s migrated successfully (marker %d).", .mig061_name, .mig061_marker_version)
  invisible(list(status = "migrated", backup_path = backup_path,
                 restore_command = restore_command, recorded_at = recorded_at))
}
