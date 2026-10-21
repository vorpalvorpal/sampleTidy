# Operator-run migration: fold the empty duplicate Mar-2024 dust project into its
# twin. Marker 1063. Requires 1062.
#
# **DRAFT, AWAITING ROBIN.** Rehearsed only; not wired into
# dev/corpus-import/apply-corpus-import.sh. Do not apply until Robin confirms.
#
# ---- WHY -----------------------------------------------------------------------
# Problem 2 (2026-10-21; Robin: "check what is actually in the files"). Under
# "Dust monitoring" (230bd429) there are two unnamed legacy projects for the
# March 2024 exposure (date_start 2024-03-01, date_end 2024-04-01, same type and
# parent, no change_log insert for either):
#   ff6f23db-4676-48e1-a253-162c316e22db: the 2 samples (B.D07, B.D08), PDF asset
#     5aa0c6df (hash 5998a793...) and xls asset 22b84f84 (hash 800b663f...);
#   c7b61e56-aacb-4a37-a296-828ead07566e: 0 samples, PDF asset 91a9c2de (the same
#     PDF bytes, 5998a793...) and xls asset 138d83b1 (hash 5655aa40...).
# The two xls files ("2400-7399-04 April 2024  Monthly Blaxland WMF .xls") are
# cell-for-cell identical on all 9 sheets and share 11 of 11 core OLE streams
# (Workbook, SummaryInformation, DocumentSummaryInformation included); 5655aa40
# only adds two SharePoint MsoDataStore items (content-type schema and
# FormTemplates) - the same SharePoint-rewrite pattern 055 handled. Both report
# ACIRL 2400-7399-04 (April 2024 monthly, Blaxland), whose Dust Results sheet
# holds exactly what ff6f23db's samples store: B.D07 insoluble 2.6 / combustible
# 0.8 / incombustible 1.8, B.D08 0.6 / 0.4 / 0.2 g/m2/month, exposed 1 Mar 2024,
# collected 1 Apr 2024. So c7b61e56 is a duplicate holding no data. Neither 057
# (different projects, so not merged) nor 061 (kept the three PDF rows as "one
# report under more than one project"; projects not changed) resolved it.
#
# ---- WHAT ----------------------------------------------------------------------
#   * assets 138d83b1 (xls) and 91a9c2de (pdf): uuid_project c7b61e56 -> ff6f23db,
#     comments <- existing; note. Both rows are KEPT (no file is touched or
#     quarantined; archived files live at <archive_dir>/<asset uuid>/<filename>):
#     91a9c2de becomes a second row for the same PDF bytes in ff6f23db, which a
#     later 057-style merge may fold into 5aa0c6df if Robin prefers.
#   * assets 5aa0c6df and f59d7ed9 (the other two rows of that PDF, whose 061
#     comments name c7b61e56): comments <- existing; a pointer note.
#   * project c7b61e56 deleted (it has no samples, child projects or other
#     references; the row is in the BACKUP CSV and change_log).
#   7 change_log rows: 2 uuid_project + 4 comments updates on asset, 1 project delete.
#
# ---- PRECONDITIONS (any failure aborts; nothing is written) ---------------------
#   * marker 1062 present;
#   * both projects exist as described (same parent, type, dates; name NULL);
#   * c7b61e56 is referenced by exactly the two asset rows and nothing else
#     (sample, project parent/root/project columns, any other asset);
#   * the four asset rows exist with the stated uuid, hash and project.
#
# Writes in one transaction under actor "063-merge-dup-dust-project-mar-2024", plus
# the marker; every other table, row and column is checksummed before and after.
# Backups: verified whole-file snapshot, plus BACKUP CSVs of the 4 asset rows and
# the deleted project row.
#
# Idempotent: marker present -> re-verify, no-op.

.mig063_marker_version <- 1063L
.mig063_requires <- 1062L
.mig063_name <- "063-merge-dup-dust-project-mar-2024"
.mig063_actor <- .mig063_name
.mig063_keep <- "ff6f23db-4676-48e1-a253-162c316e22db"
.mig063_drop <- "c7b61e56-aacb-4a37-a296-828ead07566e"
.mig063_parent <- "230bd429-7ba5-4f95-b688-d01d47367723"
.mig063_pdf_hash <- "5998a79383ebfd2b6727d9792b6b022b"
.mig063_assets <- data.frame(
  uuid = c("138d83b1-432a-49b2-a861-d0e3bb29535b", "91a9c2de-55ff-4846-8a74-13ec0f78e6c9",
           "5aa0c6df-2c1b-4347-8094-052b8e727dfa", "f59d7ed9-e6b0-4ec3-8a01-75f612dd2a72"),
  hash = c("5655aa4002922c7620d50ed1c3d2a88f", .mig063_pdf_hash, .mig063_pdf_hash, .mig063_pdf_hash),
  project = c(.mig063_drop, .mig063_drop, .mig063_keep, "c91a1238-63f9-489b-863a-f5471e97c3e6"),
  move = c(TRUE, TRUE, FALSE, FALSE),
  stringsAsFactors = FALSE)
.mig063_note_moved <- c(
  paste0("2026-10-21 063: moved from the empty duplicate Dust monitoring project c7b61e56 (deleted) to ff6f23db, ",
         "the Mar-2024 dust project holding the B.D07/B.D08 samples; this xls has the same cells as asset 22b84f84 ",
         "(hash 800b663f337223a9a541ea98e7e0ad79) and differs only in SharePoint MsoDataStore metadata"),
  paste0("2026-10-21 063: moved from the empty duplicate Dust monitoring project c7b61e56 (deleted) to ff6f23db, ",
         "the Mar-2024 dust project holding the B.D07/B.D08 samples; same bytes as asset 5aa0c6df in that project"))
.mig063_note_pointer <- paste0("2026-10-21 063: the Dust monitoring project c7b61e56 named above was an empty duplicate ",
                               "of ff6f23db and has been deleted; asset 91a9c2de now sits in ff6f23db")
.mig063_note <- function(i) if (.mig063_assets$move[[i]]) .mig063_note_moved[[i]] else .mig063_note_pointer
.mig063_append <- function(old, note) if (is.na(old) || !nzchar(trimws(old))) note else paste0(old, "; ", note)
.mig063_reason <- "063 (problem 2, 2026-10-21; awaiting Robin): fold the empty duplicate Mar-2024 dust project c7b61e56 into ff6f23db"

.mig063_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = list(...))[[1]][[1]])
.mig063_fail <- function(msg) cli::cli_abort(paste0(.mig063_name, ": ", msg), class = "sampletidy_error")
.mig063_inlist <- function(x) paste0("(", paste0("'", x, "'", collapse = ","), ")")

.mig063_counts <- function(con) {
  tabs <- c("ingest_file", "project", "sample", "analysis", "asset", "review_queue", "change_log", "schema_version")
  stats::setNames(lapply(tabs, function(t) .mig063_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
}

.mig063_refs <- function(con) {
  c(sample = .mig063_scalar(con, "SELECT COUNT(*) FROM sample WHERE uuid_project = ?", .mig063_drop),
    project = .mig063_scalar(con, "SELECT COUNT(*) FROM project WHERE uuid_parent = ? OR uuid_root = ? OR uuid_project = ?",
                             .mig063_drop, .mig063_drop, .mig063_drop),
    asset = .mig063_scalar(con, "SELECT COUNT(*) FROM asset WHERE uuid_project = ?", .mig063_drop))
}

.mig063_problems <- function(con) {
  P <- DBI::dbGetQuery(con, "SELECT uuid, name, type, uuid_parent, date_start, date_end FROM project WHERE uuid IN (?, ?)",
                       params = list(.mig063_keep, .mig063_drop))
  if (nrow(P) != 2L) return("the two Mar-2024 dust projects are not both present")
  if (any(!is.na(P$name)) || any(P$uuid_parent != .mig063_parent) || length(unique(P$type)) != 1L ||
      length(unique(format(P$date_start))) != 1L || length(unique(format(P$date_end))) != 1L)
    return("the two dust projects are not the unnamed twins described")
  r <- .mig063_refs(con)
  if (r[["sample"]] != 0L || r[["project"]] != 0L || r[["asset"]] != 2L)
    return(sprintf("c7b61e56 references are sample %d / project %d / asset %d, not 0 / 0 / 2", r[["sample"]], r[["project"]], r[["asset"]]))
  A <- DBI::dbGetQuery(con, sprintf("SELECT uuid, hash, uuid_project, comments FROM asset WHERE uuid IN %s",
                                    .mig063_inlist(.mig063_assets$uuid)))
  A <- A[match(.mig063_assets$uuid, A$uuid), , drop = FALSE]
  if (anyNA(A$uuid) || any(A$hash != .mig063_assets$hash) || any(A$uuid_project != .mig063_assets$project))
    return("the four asset rows are not as planned")
  if (any(!is.na(A$comments) & grepl("2026-10-21 063:", A$comments, fixed = TRUE))) return("an asset already carries a 063 note")
  if (.mig063_scalar(con, "SELECT COUNT(*) FROM asset WHERE hash = ?", .mig063_pdf_hash) != 3L)
    return("the PDF hash is not on exactly three asset rows")
  NULL
}

.mig063_check_preconditions <- function(con) {
  if (.mig063_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig063_requires) == 0L)
    .mig063_fail(sprintf("marker %d (062) is required first.", .mig063_requires))
  p <- .mig063_problems(con)
  if (!is.null(p)) .mig063_fail(sprintf("%s. Nothing written.", p))
  invisible(TRUE)
}

.mig063_checksum <- function(con) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  tabs <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  touched <- c("asset", "project", "change_log", "schema_version")
  out <- lapply(setdiff(tabs, touched), function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- setdiff(tabs, touched)
  u <- .mig063_inlist(.mig063_assets$uuid)
  out$asset_rest <- q(sprintf("SELECT * FROM asset WHERE uuid NOT IN %s ORDER BY ALL", u))
  out$asset_cols <- q(sprintf("SELECT * EXCLUDE (uuid_project, comments) FROM asset WHERE uuid IN %s ORDER BY uuid", u))
  out$project_rest <- q(sprintf("SELECT * FROM project WHERE uuid <> '%s' ORDER BY ALL", .mig063_drop))
  out$change_log_rest <- q(sprintf("SELECT * FROM change_log WHERE actor <> '%s' ORDER BY ALL", .mig063_actor))
  out$schema_version_rest <- q(sprintf("SELECT * FROM schema_version WHERE version <> %d ORDER BY ALL", .mig063_marker_version))
  out$views <- q("SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
  out$indexes <- q("SELECT index_name, sql FROM duckdb_indexes() ORDER BY index_name")
  out
}

.mig063_done_problem <- function(con) {
  if (.mig063_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig063_marker_version) != 1L)
    return("marker 1063 missing")
  if (.mig063_scalar(con, "SELECT COUNT(*) FROM project WHERE uuid = ?", .mig063_drop) != 0L) return("project c7b61e56 still exists")
  r <- .mig063_refs(con)
  if (any(r != 0L)) return("something still references c7b61e56")
  cl <- DBI::dbGetQuery(con, "SELECT tbl, action, uuid_row, field, old, new FROM change_log WHERE actor = ?",
                        params = list(.mig063_actor))
  if (nrow(cl) != 7L || sum(cl$tbl == "project" & cl$action == "delete" & cl$uuid_row == .mig063_drop) != 1L)
    return(sprintf("063 change_log is %d row(s), not the 7 planned", nrow(cl)))
  A <- DBI::dbGetQuery(con, sprintf("SELECT uuid, uuid_project, comments FROM asset WHERE uuid IN %s",
                                    .mig063_inlist(.mig063_assets$uuid)))
  for (i in seq_len(nrow(.mig063_assets))) {
    a <- A[A$uuid == .mig063_assets$uuid[[i]], , drop = FALSE]
    want_p <- if (.mig063_assets$move[[i]]) .mig063_keep else .mig063_assets$project[[i]]
    cc <- cl[cl$tbl == "asset" & cl$uuid_row == .mig063_assets$uuid[[i]] & cl$field == "comments", , drop = FALSE]
    if (nrow(a) != 1L || !identical(a$uuid_project[[1]], want_p) || nrow(cc) != 1L ||
        !identical(a$comments[[1]], .mig063_append(cc$old[[1]], .mig063_note(i))))
      return(sprintf("asset %s is not as planned", substr(.mig063_assets$uuid[[i]], 1, 8)))
  }
  NULL
}

.mig063_verify <- function(con) {
  p <- .mig063_done_problem(con)
  if (!is.null(p)) cli::cli_abort(paste0("063 verify failed: ", p), class = "sampletidy_error")
  invisible(TRUE)
}

mig063_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- if (is.null(.now)) Sys.time() else .now
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig063_name, ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig063_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig063_counts(verify_con)))
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  dest
}

.mig063_write_csv <- function(df, path, key) {
  out <- df
  for (f in names(out)) if (inherits(out[[f]], c("POSIXct", "Date"))) out[[f]] <- .st_changelog_str(out[[f]])
  utils::write.csv(out, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8", colClasses = "character")
  if (nrow(back) != nrow(df) || !identical(back[[key]], as.character(out[[key]])))
    cli::cli_abort("063: CSV {basename(path)} did not round-trip.", class = "sampletidy_error")
}

.mig063_apply <- function(con, recorded_at) {
  sums_before <- .mig063_checksum(con)
  want <- .mig063_counts(con)
  want$project <- want$project - 1L
  want$change_log <- want$change_log + 7L
  want$schema_version <- want$schema_version + 1L
  db_transaction(con, function(con) {
    for (i in seq_len(nrow(.mig063_assets))) {
      u <- .mig063_assets$uuid[[i]]
      old <- DBI::dbGetQuery(con, "SELECT comments FROM asset WHERE uuid = ?", params = list(u))$comments[[1]]
      ch <- list(comments = .mig063_append(old, .mig063_note(i)))
      if (.mig063_assets$move[[i]]) ch <- c(list(uuid_project = .mig063_keep), ch)
      db_update(con, "asset", uuid = u, changes = ch, actor = .mig063_actor, reason = .mig063_reason,
                source_hash = .mig063_assets$hash[[i]])
    }
    db_delete(con, "project", uuid = .mig063_drop, actor = .mig063_actor, reason = .mig063_reason)
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig063_marker_version, recorded_at))
    .mig063_verify(con)
    got <- .mig063_counts(con)
    if (!identical(got, want))
      .mig063_fail(sprintf("counts are not before - 1 project, + 7 change_log, + 1 marker: %s",
                           paste(names(got), unlist(got), unlist(want), sep = ":", collapse = ", ")))
    if (!identical(sums_before, .mig063_checksum(con))) .mig063_fail("something outside the planned rows moved.")
    NULL
  })
  invisible(NULL)
}

mig063_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(
    DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                    params = list(.mig063_marker_version)),
    finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch(.mig063_verify(check_con), finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("063 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  tryCatch(.mig063_check_preconditions(pre_con), finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  for (i in seq_len(nrow(.mig063_assets)))
    logf("asset %s%s; append: %s", .mig063_assets$uuid[[i]],
         if (.mig063_assets$move[[i]]) " -> project ff6f23db" else "", .mig063_note(i))
  logf("delete empty project %s", .mig063_drop)
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition passed. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_, restore_command = NA_character_,
                          recorded_at = NA)))
  }

  bk_con <- st_connect(db, read_only = TRUE)
  tryCatch({
    .mig063_write_csv(DBI::dbGetQuery(bk_con, sprintf("SELECT * FROM asset WHERE uuid IN %s ORDER BY uuid",
                                                      .mig063_inlist(.mig063_assets$uuid))),
                      file.path(csv_dir, sprintf("%s-BACKUP-asset.csv", .mig063_name)), "uuid")
    .mig063_write_csv(DBI::dbGetQuery(bk_con, "SELECT * FROM project WHERE uuid = ?", params = list(.mig063_drop)),
                      file.path(csv_dir, sprintf("%s-BACKUP-project.csv", .mig063_name)), "uuid")
  }, finally = DBI::dbDisconnect(bk_con, shutdown = TRUE))
  logf("Row backups written to %s", csv_dir)
  backup_path <- mig063_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- if (is.null(.now)) Sys.time() else .now

  with_db_write(function(con) {
    .mig063_check_preconditions(con)   # re-read under the write lock
    .mig063_apply(con, recorded_at)
  }, db = db)

  logf("%s migrated successfully (marker %d): 2 assets moved to ff6f23db, project c7b61e56 deleted.",
       .mig063_name, .mig063_marker_version)
  invisible(list(status = "migrated", backup_path = backup_path,
                 restore_command = restore_command, recorded_at = recorded_at))
}
