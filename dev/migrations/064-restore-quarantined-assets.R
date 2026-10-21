# Operator-run migration: restore the asset rows that F.18 wrongly deleted, and
# register the other quarantined files whose owning project is unambiguous, moving
# each file from the 20261020 dedupe quarantine back to processed/<uuid>/<filename>.
# Marker 1064. Requires 1061. Runs AFTER the historical corpus import
# (dev/corpus-import/apply-corpus-import.sh); it is not part of that script.
#
# ---- WHY -----------------------------------------------------------------------
# F.18 (2026-07-23) deleted asset rows whose `<uuid>/<filename>` file test failed.
# 109 of them were ACIRL monthly gas monitoring assets (Apr 2023 - Sep 2025:
# workbooks, report PDFs, scanned field sheets) whose rows had a NULL filename and
# hash, so the test could never pass although the files were there
# (dev/asset-rows-deleted-2026-07-23.csv). The 2026-10-20 processed/ dedupe then
# moved those files, with 12 other never-recorded files, into
# assets/_dedupe_quarantine/20261020/processed/ as orphans. 121 unique files remain.
#
# ---- WHAT (78 rows, 78 file moves; dev/migrations/064-...-INPUT.csv) ------------
#   f18_pdf (70), f18_workbook (2): the F.18 row comes back with its original uuid
#     and every column from the pre-F.18 backup
#     (migration-backups/monitoring_pre-001-alias-indirection_20260723T041715.979Z.duckdb),
#     plus filename and hash (xxHash128, rlang::hash_file(), as asset.hash) of the
#     actual file, and a comments note.
#   coc_copy (3): ALS chain-of-custody PDFs for ES2417442, ES2304200, ES2414680:
#     a second copy (same scan, different bytes) of the COC each work order already
#     holds; name/date/type/organisation/person copied from that COC row.
#   field_sheet (1): "Quarterly 14-12.pdf", the scanned Blaxland quarterly field
#     sheet of 14/12/2022, which prints ALS report no. ES2245792 -> under ES2245792.
#   acirl_report_pdf (1): the PDF of ACIRL report 2400-7222-12-04 -> that project,
#     where its workbook already is.
#   legacy_pdf (1): extension-less legacy file processed/def543d7-... is the PDF of
#     ACIRL report 2400-7286-10-02 -> that project, as processed/<uuid>/<uuid>.pdf.
#   New registrations reuse the uuid of the quarantine dir/file they came from.
#   Projects: a frozen uuid where the project exists in live before the import; by
#   unique name for the two that the import creates (2400-7222-12-04, 2400-7286-10-02).
#
# NOT restored (43; dev/migrations/064-...-SKIPPED.csv, files left in quarantine):
#   37 F.18 workbooks that the historical import re-archives as new assets under the
#   same project (their 2026-10-19 copies: same cells in every sheet; only Office
#   metadata bytes differ, the SharePoint rewrite of 055); the Aug 2024 workbook copy
#   in 112e82b9 (a later rewrite, not e2f78ed5's original bytes); the two ES2245792
#   rev-1 XTAB files (byte-identical to assets the import archives); three legacy
#   workbooks whose cells equal an existing asset's. 064 checks each is represented.
#
# ---- PRECONDITIONS (any failure aborts; nothing is written or moved) ------------
#   * marker 1061 present, 1064 absent;
#   * every target project exists (frozen uuid with the expected name, or exactly one
#     project of that name);
#   * none of the 121 uuids is already an asset uuid; no restore file's hash is
#     already an asset hash;
#   * every SKIPPED item is represented (asset with that hash, or that uuid);
#   * every restore file is in the quarantine, a regular file, with the frozen size,
#     and the frozen hash (an .xls whose hash drifted is accepted only if its cell
#     content digest is unchanged: SharePoint rewrites Office metadata; the row then
#     takes the file's current hash);
#   * no target processed/<uuid>/<filename> exists, processed/<uuid> is not a file,
#     and if it is a directory it is empty;
#   * the row count is 78.
#   `mig064_check()` runs exactly these checks read-only (064-...-CHECK.R).
#
# ---- APPLY ----------------------------------------------------------------------
# Under the write lock, in one transaction: 78 db_append(asset) inserts (one
# change_log insert row each, actor "064-restore-quarantined-assets"), then for each
# file: create processed/<uuid>/ if absent, file.rename() it from the quarantine
# (same volume; never copies over, refuses an existing target), re-hash the moved
# file and require the planned hash. A failure rolls the transaction back, and the
# rollback hooks move every already-moved file back to the quarantine and remove any
# directory 064 created. Then the marker; verify; counts; every other table, row and
# column checksummed before and after. Backups: verified whole-file snapshot, plus
# `064-...-BACKUP-moves.csv` (the planned rows, source and target paths, hashes:
# the undo map) written before anything moves.
# Undo: cp the snapshot back over the DB, and move each target in BACKUP-moves.csv
# back to its source.
#
# Dry run reports what it would insert and move; nothing written or moved.
# Idempotent: marker present -> re-verify (rows, change_log, files), no-op.
#
#   devtools::load_all(".")
#   env <- new.env()
#   sys.source("dev/migrations/064-restore-quarantined-assets.R", envir = env)
#   env$mig064_run(db = st_config("live_db"), snapshot_dir = <dir>,
#                  archive_dir = <assets/processed>, dry_run = TRUE)

.mig064_marker_version <- 1064L
.mig064_requires <- 1061L
.mig064_name <- "064-restore-quarantined-assets"
.mig064_actor <- .mig064_name
.mig064_n_rows <- 78L
.mig064_n_skipped <- 43L
.mig064_reason <- "064 (2026-10-21): restore asset rows F.18 deleted (NULL filename/hash) and register unambiguous quarantined files"
.mig064_cols <- c("uuid", "name", "date", "file_format", "type", "purpose", "organisation", "person",
                  "uuid_project", "uuid_feature", "filename", "hash", "comments")

.mig064_fail <- function(msg) cli::cli_abort(paste0(.mig064_name, ": ", msg), class = "sampletidy_error")
.mig064_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = list(...))[[1]][[1]])

.mig064_default_quarantine <- function(archive_dir)
  file.path(dirname(archive_dir), "_dedupe_quarantine", "20261020", "processed")

.mig064_read_inputs <- function(input_dir = "dev/migrations") {
  rd <- function(suffix) {
    p <- file.path(input_dir, sprintf("%s-%s.csv", .mig064_name, suffix))
    if (!file.exists(p)) .mig064_fail(sprintf("input %s not found.", p))
    utils::read.csv(p, colClasses = "character", na.strings = "", encoding = "UTF-8")
  }
  inp <- rd("INPUT"); sk <- rd("SKIPPED")
  inp$size <- as.numeric(inp$size); sk$size <- as.numeric(sk$size)
  if (nrow(inp) != .mig064_n_rows || anyDuplicated(inp$uuid) || anyDuplicated(inp$hash))
    .mig064_fail(sprintf("INPUT has %d rows (planned %d) or duplicate uuids/hashes.", nrow(inp), .mig064_n_rows))
  if (nrow(sk) != .mig064_n_skipped || any(sk$uuid %in% inp$uuid))
    .mig064_fail(sprintf("SKIPPED has %d rows (planned %d) or overlaps INPUT.", nrow(sk), .mig064_n_skipped))
  list(input = inp, skipped = sk)
}

.mig064_note <- function(r) if (is.na(r$comments_before) || !nzchar(trimws(r$comments_before))) r$note else paste0(r$comments_before, "; ", r$note)

# Cell content of every sheet, read as text: unchanged by SharePoint's Office
# metadata rewrite, so an .xls whose bytes drifted can be recognised as the same file.
.mig064_content_digest <- function(path) {
  sh <- readxl::excel_sheets(path)
  digest::digest(stats::setNames(lapply(sh, function(s) suppressMessages(as.data.frame(
    readxl::read_excel(path, s, col_names = FALSE, col_types = "text")))), sh), algo = "sha1")
}

# Does `path` hold the planned file? Returns list(ok, hash, how).
.mig064_file_matches <- function(path, hash, content_digest) {
  h <- rlang::hash_file(path)
  if (identical(h, hash)) return(list(ok = TRUE, hash = h, how = "hash"))
  if (!is.na(content_digest) && grepl("\\.xls$", path, ignore.case = TRUE)) {
    d <- tryCatch(.mig064_content_digest(path), error = function(e) NA_character_)
    if (identical(d, content_digest)) return(list(ok = TRUE, hash = h, how = "content (bytes rewritten)"))
  }
  list(ok = FALSE, hash = h, how = "mismatch")
}

# Resolve every row's project; returns list(input = <with uuid_project>, problems = chr).
.mig064_resolve_projects <- function(con, inp) {
  pr <- DBI::dbGetQuery(con, "SELECT uuid, name FROM project")
  probs <- character()
  for (i in seq_len(nrow(inp))) {
    if (!is.na(inp$uuid_project[i])) {
      nm <- pr$name[match(inp$uuid_project[i], pr$uuid)]
      if (!inp$uuid_project[i] %in% pr$uuid) {
        probs <- c(probs, sprintf("%s: project %s (%s) missing", inp$uuid[i], inp$uuid_project[i], inp$project_name[i]))
      } else if (!is.na(inp$project_name[i]) && !identical(nm, inp$project_name[i])) {
        probs <- c(probs, sprintf("%s: project %s is named %s, not %s", inp$uuid[i], inp$uuid_project[i], nm, inp$project_name[i]))
      }
    } else {
      hit <- pr$uuid[!is.na(pr$name) & pr$name == inp$project_name[i]]
      if (length(hit) != 1L) probs <- c(probs, sprintf("%s: %d projects named %s (need exactly 1)", inp$uuid[i], length(hit), inp$project_name[i]))
      else inp$uuid_project[i] <- hit
    }
  }
  list(input = inp, problems = probs)
}

.mig064_db_problems <- function(con, inp, sk) {
  probs <- character()
  if (.mig064_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig064_requires) == 0L)
    probs <- c(probs, sprintf("marker %d (061) is required first", .mig064_requires))
  if (.mig064_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig064_marker_version) > 0L)
    probs <- c(probs, sprintf("marker %d already present", .mig064_marker_version))
  res <- .mig064_resolve_projects(con, inp)
  probs <- c(probs, res$problems)
  a <- DBI::dbGetQuery(con, "SELECT uuid, hash FROM asset")
  taken <- intersect(c(inp$uuid, sk$uuid), a$uuid)
  if (length(taken)) probs <- c(probs, sprintf("already an asset uuid: %s", paste(taken, collapse = ", ")))
  dup <- inp$uuid[inp$hash %in% a$hash]
  if (length(dup)) probs <- c(probs, sprintf("restore file hash already an asset hash: %s", paste(dup, collapse = ", ")))
  for (i in seq_len(nrow(sk))) {
    ok <- if (!is.na(sk$represented_by_uuid[i])) sk$represented_by_uuid[i] %in% a$uuid else sk$represented_by_hash[i] %in% a$hash
    if (!ok) probs <- c(probs, sprintf("skipped %s (%s) is not represented: no asset %s", sk$uuid[i], sk$category[i],
                                       if (!is.na(sk$represented_by_uuid[i])) sk$represented_by_uuid[i] else paste("with hash", sk$represented_by_hash[i])))
  }
  list(input = res$input, problems = probs)
}

# File checks. Returns list(input = <with src, dest, actual hash>, problems, notes, skipped_notes).
.mig064_file_problems <- function(inp, sk, archive_dir, quarantine_dir) {
  probs <- character(); notes <- character(); sknotes <- character()
  if (!dir.exists(archive_dir)) probs <- c(probs, sprintf("archive_dir %s does not exist", archive_dir))
  if (!dir.exists(quarantine_dir)) probs <- c(probs, sprintf("quarantine dir %s does not exist", quarantine_dir))
  inp$src <- file.path(quarantine_dir, inp$source_relpath)
  inp$dest_dir <- file.path(archive_dir, inp$uuid)
  inp$dest <- file.path(inp$dest_dir, inp$filename)
  inp$actual_hash <- NA_character_
  if (length(probs)) return(list(input = inp, problems = probs, notes = notes, skipped_notes = sknotes))
  for (i in seq_len(nrow(inp))) {
    s <- inp$src[i]
    if (!file.exists(s) || dir.exists(s)) { probs <- c(probs, sprintf("%s: quarantine file missing: %s", inp$uuid[i], s)); next }
    if (file.size(s) != inp$size[i]) { probs <- c(probs, sprintf("%s: size %s, planned %s", inp$uuid[i], file.size(s), inp$size[i])); next }
    m <- .mig064_file_matches(s, inp$hash[i], inp$content_digest[i])
    if (!m$ok) { probs <- c(probs, sprintf("%s: hash %s, planned %s", inp$uuid[i], m$hash, inp$hash[i])); next }
    if (m$how != "hash") notes <- c(notes, sprintf("%s: %s; row takes hash %s", inp$uuid[i], m$how, m$hash))
    inp$actual_hash[i] <- m$hash
    if (file.exists(inp$dest[i])) probs <- c(probs, sprintf("%s: target already occupied: %s", inp$uuid[i], inp$dest[i]))
    else if (file.exists(inp$dest_dir[i]) && !dir.exists(inp$dest_dir[i])) probs <- c(probs, sprintf("%s: %s is a file", inp$uuid[i], inp$dest_dir[i]))
    else if (dir.exists(inp$dest_dir[i]) && length(list.files(inp$dest_dir[i], all.files = TRUE, no.. = TRUE)))
      probs <- c(probs, sprintf("%s: target dir %s is not empty", inp$uuid[i], inp$dest_dir[i]))
  }
  # Skipped files are not touched by 064: reported, never blocking.
  for (i in seq_len(nrow(sk))) {
    s <- file.path(quarantine_dir, sk$source_relpath[i])
    if (!file.exists(s) || dir.exists(s)) sknotes <- c(sknotes, sprintf("skipped %s: file no longer in quarantine", sk$uuid[i]))
    else if (!identical(rlang::hash_file(s), sk$hash[i])) sknotes <- c(sknotes, sprintf("skipped %s: hash changed since frozen", sk$uuid[i]))
  }
  list(input = inp, problems = probs, notes = notes, skipped_notes = sknotes)
}

# All checks, read-only. Returns list(ok, problems, notes, skipped_notes, input).
.mig064_all_checks <- function(con, archive_dir, quarantine_dir, input_dir) {
  x <- .mig064_read_inputs(input_dir)
  d <- .mig064_db_problems(con, x$input, x$skipped)
  f <- .mig064_file_problems(d$input, x$skipped, archive_dir, quarantine_dir)
  probs <- c(d$problems, f$problems)
  if (nrow(f$input) != .mig064_n_rows) probs <- c(probs, sprintf("%d rows to restore, rehearsed %d", nrow(f$input), .mig064_n_rows))
  list(ok = !length(probs), problems = probs, notes = f$notes, skipped_notes = f$skipped_notes, input = f$input)
}

#' Read-only pre-flight for live: PASS/FAIL. Writes nothing.
mig064_check <- function(db, archive_dir, quarantine_dir = .mig064_default_quarantine(archive_dir),
                         input_dir = "dev/migrations") {
  cat(sprintf("064 CHECK\n  db          %s\n  archive_dir %s\n  quarantine  %s\n", db, archive_dir, quarantine_dir))
  con <- st_connect(db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  r <- .mig064_all_checks(con, archive_dir, quarantine_dir, input_dir)
  cat(sprintf("  rows to restore/register: %d (rehearsed %d)\n", sum(!is.na(r$input$actual_hash)), .mig064_n_rows))
  print(table(category = r$input$category))
  for (n in r$notes) cat("  NOTE ", n, "\n")
  for (n in r$skipped_notes) cat("  WARN ", n, " (not blocking: 064 does not touch skipped files)\n")
  for (p in r$problems) cat("  FAIL ", p, "\n")
  cat(if (r$ok) "\nRESULT: PASS - live matches the rehearsal assumptions; 064 may be applied.\n"
      else sprintf("\nRESULT: FAIL - %d problem(s); do NOT apply 064.\n", length(r$problems)))
  invisible(r)
}

.mig064_counts <- function(con) {
  tabs <- c("ingest_file", "project", "sample", "analysis", "asset", "review_queue", "change_log", "schema_version")
  stats::setNames(lapply(tabs, function(t) .mig064_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
}

.mig064_checksum <- function(con, uuids) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  tabs <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  touched <- c("asset", "change_log", "schema_version")
  out <- lapply(setdiff(tabs, touched), function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- setdiff(tabs, touched)
  inlist <- paste0("'", uuids, "'", collapse = ",")
  out$asset_rest <- q(sprintf("SELECT * FROM asset WHERE uuid NOT IN (%s) ORDER BY ALL", inlist))
  out$change_log_rest <- q(sprintf("SELECT * FROM change_log WHERE actor <> '%s' ORDER BY ALL", .mig064_actor))
  out$schema_version_rest <- q(sprintf("SELECT * FROM schema_version WHERE version <> %d ORDER BY ALL", .mig064_marker_version))
  out$views <- q("SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
  out$indexes <- q("SELECT index_name, sql FROM duckdb_indexes() ORDER BY index_name")
  out
}

.mig064_rows <- function(inp) {
  tibble::tibble(
    uuid = inp$uuid, name = inp$name,
    date = as.POSIXct(inp$date, tz = "UTC", format = "%Y-%m-%d %H:%M:%S"),
    file_format = inp$file_format, type = inp$type, purpose = inp$purpose,
    organisation = inp$organisation, person = inp$person, uuid_project = inp$uuid_project,
    uuid_feature = inp$uuid_feature, filename = inp$filename, hash = inp$actual_hash,
    comments = vapply(seq_len(nrow(inp)), function(i) .mig064_note(inp[i, ]), character(1)))
}

# Post-state problems (NULL when 064 is fully and correctly applied).
.mig064_done_problem <- function(con, archive_dir, input_dir) {
  if (.mig064_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig064_marker_version) != 1L)
    return("marker 1064 missing")
  inp <- .mig064_read_inputs(input_dir)$input
  a <- DBI::dbGetQuery(con, sprintf("SELECT * FROM asset WHERE uuid IN (%s)", paste0("'", inp$uuid, "'", collapse = ",")))
  if (nrow(a) != .mig064_n_rows) return(sprintf("%d of the %d rows present", nrow(a), .mig064_n_rows))
  a <- a[match(inp$uuid, a$uuid), ]
  res <- .mig064_resolve_projects(con, inp)
  if (length(res$problems)) return(paste(res$problems, collapse = "; "))
  inp <- res$input
  want <- .mig064_rows(transform(inp, actual_hash = a$hash))
  for (f in setdiff(.mig064_cols, "hash")) {
    w <- want[[f]]; g <- a[[f]]
    if (inherits(w, "POSIXct")) { w <- .st_changelog_str(w); g <- .st_changelog_str(g) }
    if (!identical(as.character(w), as.character(g))) return(sprintf("asset column %s differs from the plan", f))
  }
  cl <- DBI::dbGetQuery(con, "SELECT tbl, action, uuid_row FROM change_log WHERE actor = ?", params = list(.mig064_actor))
  if (nrow(cl) != .mig064_n_rows || any(cl$tbl != "asset") || any(cl$action != "insert") || !setequal(cl$uuid_row, inp$uuid))
    return(sprintf("064 change_log is %d row(s), not the %d planned asset inserts", nrow(cl), .mig064_n_rows))
  for (i in seq_len(nrow(inp))) {
    p <- file.path(archive_dir, a$uuid[i], a$filename[i])
    if (!file.exists(p)) return(sprintf("asset %s does not resolve to a file: %s", a$uuid[i], p))
    m <- .mig064_file_matches(p, a$hash[i], inp$content_digest[i])
    if (!m$ok) return(sprintf("asset %s: file hash %s, row hash %s", a$uuid[i], m$hash, a$hash[i]))
  }
  NULL
}

.mig064_verify <- function(con, archive_dir, input_dir) {
  p <- .mig064_done_problem(con, archive_dir, input_dir)
  if (!is.null(p)) cli::cli_abort(paste0("064 verify failed: ", p), class = "sampletidy_error")
  invisible(TRUE)
}

mig064_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- if (is.null(.now)) Sys.time() else .now
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig064_name, ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig064_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig064_counts(verify_con)))
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  dest
}

.mig064_write_moves_csv <- function(inp, path) {
  out <- inp[, c("uuid", "category", "uuid_project", "project_name", "filename", "hash", "actual_hash", "src", "dest")]
  utils::write.csv(out, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, colClasses = "character", na.strings = "", encoding = "UTF-8")
  if (nrow(back) != nrow(out) || !identical(back$uuid, out$uuid) || !identical(back$dest, out$dest))
    .mig064_fail(sprintf("CSV %s did not round-trip.", basename(path)))
}

.mig064_apply <- function(con, inp, archive_dir, input_dir, recorded_at) {
  sums_before <- .mig064_checksum(con, inp$uuid)
  want <- .mig064_counts(con)
  want$asset <- want$asset + .mig064_n_rows
  want$change_log <- want$change_log + .mig064_n_rows
  want$schema_version <- want$schema_version + 1L
  rows <- .mig064_rows(inp)
  db_transaction(con, function(con) {
    for (i in seq_len(nrow(rows)))
      db_append(con, "asset", rows[i, ], actor = .mig064_actor, reason = .mig064_reason, source_hash = rows$hash[[i]])
    for (i in seq_len(nrow(inp))) {
      src <- inp$src[i]; dd <- inp$dest_dir[i]; dest <- inp$dest[i]
      if (file.exists(dest)) .mig064_fail(sprintf("refusing to overwrite %s", dest))
      if (!dir.exists(dd)) {
        if (!dir.create(dd, recursive = FALSE, showWarnings = FALSE)) .mig064_fail(sprintf("cannot create %s", dd))
        # hooks run in reverse order: the file goes back first, then this (now empty) dir
        local({ d <- dd; .st_on_rollback(con, function()
          if (dir.exists(d) && !length(list.files(d, all.files = TRUE, no.. = TRUE))) unlink(d, recursive = TRUE)) })
      }
      if (!isTRUE(file.rename(src, dest))) .mig064_fail(sprintf("move failed: %s -> %s", src, dest))
      local({ s <- src; d <- dest; .st_on_rollback(con, function() if (!file.exists(s)) file.rename(d, s)) })
      h <- rlang::hash_file(dest)
      if (!identical(h, inp$actual_hash[i])) .mig064_fail(sprintf("%s: hash after move %s, planned %s", inp$uuid[i], h, inp$actual_hash[i]))
    }
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig064_marker_version, recorded_at))
    .mig064_verify(con, archive_dir, input_dir)
    got <- .mig064_counts(con)
    if (!identical(got, want))
      .mig064_fail(sprintf("counts are not before + %d asset, + %d change_log, + 1 marker: %s", .mig064_n_rows, .mig064_n_rows,
                           paste(names(got), unlist(got), unlist(want), sep = ":", collapse = ", ")))
    if (!identical(sums_before, .mig064_checksum(con, inp$uuid))) .mig064_fail("something outside the planned rows moved.")
    NULL
  })
  invisible(NULL)
}

mig064_run <- function(db, snapshot_dir, archive_dir, quarantine_dir = .mig064_default_quarantine(archive_dir),
                       dry_run = FALSE, .now = NULL, csv_dir = NULL, input_dir = "dev/migrations") {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(
    DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                    params = list(.mig064_marker_version)),
    finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch(.mig064_verify(check_con, archive_dir, input_dir), finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("064 already applied at %s; re-verified (rows, change_log, files); nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  run_checks <- function(con) {
    r <- .mig064_all_checks(con, archive_dir, quarantine_dir, input_dir)
    if (!r$ok) .mig064_fail(sprintf("%d precondition(s) failed; nothing written or moved:\n  %s",
                                    length(r$problems), paste(r$problems, collapse = "\n  ")))
    r
  }
  pre_con <- st_connect(db, read_only = TRUE)
  r <- tryCatch(run_checks(pre_con), finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  for (n in r$notes) logf("NOTE %s", n)
  for (n in r$skipped_notes) logf("WARN %s (not blocking)", n)
  tab <- table(r$input$category)
  logf("Insert %d asset rows (%s) and move %d files from %s to %s/<uuid>/<filename>.", nrow(r$input),
       paste(names(tab), tab, sep = " ", collapse = ", "), nrow(r$input), quarantine_dir, archive_dir)
  if (isTRUE(dry_run)) {
    for (i in seq_len(nrow(r$input))) logf("  would move %s -> %s", r$input$source_relpath[i], file.path(r$input$uuid[i], r$input$filename[i]))
    logf("DRY RUN: every precondition passed. No backup taken, nothing written or moved.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_, restore_command = NA_character_,
                          recorded_at = NA)))
  }

  .mig064_write_moves_csv(r$input, file.path(csv_dir, sprintf("%s-BACKUP-moves.csv", .mig064_name)))
  logf("Undo map written to %s", file.path(csv_dir, sprintf("%s-BACKUP-moves.csv", .mig064_name)))
  backup_path <- mig064_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s (and move each dest in the BACKUP-moves CSV back to its src)", restore_command)
  recorded_at <- if (is.null(.now)) Sys.time() else .now

  with_db_write(function(con) {
    r2 <- run_checks(con)   # re-read under the write lock
    .mig064_apply(con, r2$input, archive_dir, input_dir, recorded_at)
  }, db = db)

  logf("%s migrated successfully (marker %d): %d asset rows restored/registered, %d files moved and re-hashed.",
       .mig064_name, .mig064_marker_version, .mig064_n_rows, .mig064_n_rows)
  invisible(list(status = "migrated", backup_path = backup_path,
                 restore_command = restore_command, recorded_at = recorded_at))
}
