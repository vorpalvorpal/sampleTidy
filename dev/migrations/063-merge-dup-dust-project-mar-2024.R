# Operator-run migration: fold the empty duplicate Mar-2024 dust project into its
# twin, then merge the two rows that now hold the same PDF bytes in that project.
# Marker 1063. Requires 1064 (so: corpus import chain -> 062 -> import -> 064 -> 063).
#
# Authority: Robin, 2026-10-21 (problem 2, "check what is actually in the files";
# approved 2026-10-21 with one addition: merge the two same-bytes PDF rows the move
# leaves in ff6f23db "in the same way migration 057 merges duplicate-hash asset
# groups").
#
# ---- WHY -----------------------------------------------------------------------
# Under "Dust monitoring" (230bd429) there are two unnamed legacy projects for the
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
#   1. Move: assets 138d83b1 (xls) and 91a9c2de (pdf): uuid_project c7b61e56 ->
#      ff6f23db, comments <- existing; a "moved" note.
#   2. Merge the PDF pair now in ff6f23db (91a9c2de, 5aa0c6df: same bytes, hash
#      5998a793...) exactly as 057 merges a duplicate-hash group:
#        * survivor = the earliest archive copy (057's first rule, file mtime):
#          processed/91a9c2de-.../<filename> 2024-10-16 05:50:57 vs
#          processed/5aa0c6df-.../<filename> 2024-10-16 06:14:29 (local time; stat
#          of the OneDrive copies, 2026-10-21; no tie, so 057's tie-breaks are not
#          reached). KEPT 91a9c2de, MERGED 5aa0c6df;
#        * NULL fields of the survivor (date, type, file_format, purpose,
#          uuid_feature; person only from the same organisation) filled from the
#          merged row (the two rows agree on every field, so nothing is expected);
#        * survivor comments <- existing; the moved note; then 057's note
#          "2026-10-21 063: merged 1 duplicate asset row(s) with identical bytes
#          (hash H) into this one: <uuid> "<filename>" (<type>, <org> / <person>,
#          <date>)[; filled ...]; its archive copy processed/5aa0c6df-.../<filename>
#          is left in place (not moved or deleted)";
#        * lab_qc_report rows on 5aa0c6df: deleted (with their lab_qc_outlier
#          rows) when the survivor already has a report of that kind, else
#          re-pointed; ingest_file rows with uuid_asset 5aa0c6df re-pointed;
#        * asset row 5aa0c6df deleted.
#      References: every VARCHAR column of every table is scanned at run time for
#      the merged uuid and for c7b61e56; only asset.uuid, asset.uuid_project,
#      lab_qc_report.uuid_asset, ingest_file.uuid_asset and change_log (history,
#      deliberately not rewritten) may hold them.
#   3. xls pair (22b84f84 = 800b663f..., 138d83b1 = 5655aa40...): BOTH KEPT, each
#      with a comment naming the other. They are not a 057 duplicate: 057 merges
#      only identical bytes (its precondition rejects a group whose hashes differ),
#      and 055, the SharePoint-rewrite precedent, re-hashed the rewritten rows and
#      kept them rather than deleting any. Keeping 138d83b1 also keeps its archive
#      file processed/138d83b1-.../ owned by a row: merged away it would be an
#      orphan that is NOT a byte duplicate of anything, which processed-dedupe
#      cannot classify, and a re-drop of the 5655aa40 bytes would no longer find
#      an asset by hash.
#   4. f59d7ed9 (the third row of that PDF, in c91a1238, whose 061 comment names
#      c7b61e56 and 5aa0c6df): comments <- existing; a pointer note.
#   5. Project c7b61e56 deleted (no samples, child projects or other references
#      by then; the row is in the BACKUP CSV and change_log).
#   change_log: 2 uuid_project + 4 comments updates on asset, 1 asset delete,
#   1 project delete = 8, plus one row per survivor field filled, lab_qc_outlier
#   / lab_qc_report delete or re-point, and ingest_file re-point (0 of each
#   found in the rehearsals).
#
# FILES: none is moved, copied or deleted. Archived files live at
# <archive_dir>/<asset uuid>/<filename>; moving a row between projects does not
# move its file. processed/5aa0c6df-4.../2400-7399-04 April 2024  Monthly
# Blaxland WMF .pdf is left in place as a byte duplicate of the survivor's file,
# as 057 left its merged rows' files. 057 then had processed-dedupe quarantine
# them; for 063 that is optional and is NOT done: if wanted later, pass
# dev/migrations/063-merge-dup-dust-project-mar-2024-INPUT.csv (057's --merged
# format) to dev/processed-dedupe.R --merged.
#
# ---- PRECONDITIONS (any failure aborts; nothing is written) ---------------------
#   * markers 1064 and 1062 present;
#   * both projects exist as described (same parent, type, dates; name NULL);
#   * c7b61e56 is referenced by exactly the two asset rows and nothing else;
#   * the five asset rows exist with the stated uuid, filename, hash and project;
#     the PDF hash is on exactly those three rows, each xls hash on one;
#   * the merged uuid is referenced only where listed above; no 063 note yet.
#
# Writes in one transaction under actor "063-merge-dup-dust-project-mar-2024", plus
# the marker; every other table, row and column is checksummed before and after.
# Backups: verified whole-file snapshot, plus BACKUP CSVs of the 5 asset rows, the
# deleted project row, and the lab_qc_report / lab_qc_outlier / ingest_file rows
# touched (empty files when none).
#
# Idempotent: marker present -> re-verify, no-op.

.mig063_marker_version <- 1063L
.mig063_requires <- c(1064L, 1062L)
.mig063_name <- "063-merge-dup-dust-project-mar-2024"
.mig063_actor <- .mig063_name
.mig063_date <- "2026-10-21"
.mig063_keep <- "ff6f23db-4676-48e1-a253-162c316e22db"
.mig063_drop <- "c7b61e56-aacb-4a37-a296-828ead07566e"
.mig063_parent <- "230bd429-7ba5-4f95-b688-d01d47367723"
.mig063_pdf_hash <- "5998a79383ebfd2b6727d9792b6b022b"
.mig063_xls_name <- "2400-7399-04 April 2024  Monthly Blaxland WMF .xls"
.mig063_pdf_name <- "2400-7399-04 April 2024  Monthly Blaxland WMF .pdf"
.mig063_survivor <- "91a9c2de-55ff-4846-8a74-13ec0f78e6c9"
.mig063_merged <- "5aa0c6df-2c1b-4347-8094-052b8e727dfa"
.mig063_fill_fields <- c("date", "type", "file_format", "purpose", "uuid_feature")
# role: move (to ff6f23db), merge (deleted into the survivor), note (comment only)
.mig063_assets <- data.frame(
  uuid = c("138d83b1-432a-49b2-a861-d0e3bb29535b", .mig063_survivor, .mig063_merged,
           "22b84f84-b36e-4ae6-9ee9-7ebf7286f214", "f59d7ed9-e6b0-4ec3-8a01-75f612dd2a72"),
  filename = c(.mig063_xls_name, .mig063_pdf_name, .mig063_pdf_name, .mig063_xls_name, .mig063_pdf_name),
  hash = c("5655aa4002922c7620d50ed1c3d2a88f", .mig063_pdf_hash, .mig063_pdf_hash,
           "800b663f337223a9a541ea98e7e0ad79", .mig063_pdf_hash),
  project = c(.mig063_drop, .mig063_drop, .mig063_keep, .mig063_keep, "c91a1238-63f9-489b-863a-f5471e97c3e6"),
  role = c("move", "move", "merge", "note", "note"),
  stringsAsFactors = FALSE)
.mig063_moved <- paste0("2026-10-21 063: moved from the empty duplicate Dust monitoring project c7b61e56 (deleted) to ff6f23db, ",
                        "the Mar-2024 dust project holding the B.D07/B.D08 samples")
.mig063_notes <- c(
  "138d83b1-432a-49b2-a861-d0e3bb29535b" = paste0(.mig063_moved, "; this xls has the same cells as asset 22b84f84 ",
    "(hash 800b663f337223a9a541ea98e7e0ad79) and differs only in SharePoint MsoDataStore metadata; kept as a separate ",
    "asset row (different bytes, so not a duplicate-hash merge)"),
  "22b84f84-b36e-4ae6-9ee9-7ebf7286f214" = paste0("2026-10-21 063: asset 138d83b1 (hash 5655aa4002922c7620d50ed1c3d2a88f), ",
    "moved here from the deleted duplicate project c7b61e56, is the same workbook (same cells) with SharePoint ",
    "MsoDataStore metadata added; both rows kept (different bytes)"),
  "f59d7ed9-e6b0-4ec3-8a01-75f612dd2a72" = paste0("2026-10-21 063: the Dust monitoring project c7b61e56 named above was an ",
    "empty duplicate of ff6f23db and has been deleted; asset 91a9c2de now sits in ff6f23db, and asset 5aa0c6df ",
    "(same bytes, same project) was merged into it"))
.mig063_reason <- "063 (Robin, 2026-10-21): fold the empty duplicate Mar-2024 dust project c7b61e56 into ff6f23db and merge the two same-bytes PDF rows there (057 rules)"

.mig063_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = list(...))[[1]][[1]])
.mig063_fail <- function(msg) cli::cli_abort(paste0(.mig063_name, ": ", msg), class = "sampletidy_error")
.mig063_inlist <- function(x) if (!length(x)) "('')" else paste0("(", paste0("'", gsub("'", "''", x), "'", collapse = ","), ")")
.mig063_append <- function(old, note) if (is.na(old) || !nzchar(trimws(old))) note else paste0(old, "; ", note)
.mig063_fmt_date <- function(d) if (is.na(d)) "no date" else format(as.POSIXct(d, tz = "UTC") + 11 * 3600, "%Y-%m-%d")
.mig063_desc <- function(r) {   # 057's description of a merged row
  who <- paste(c(if (!is.na(r$organisation)) r$organisation, if (!is.na(r$person)) r$person), collapse = " / ")
  sprintf("%s \"%s\" (%s, %s, %s)", r$uuid, r$filename, if (is.na(r$type)) "no type" else r$type,
          if (nzchar(who)) who else "no organisation", .mig063_fmt_date(r$date))
}

.mig063_counts <- function(con) {
  tabs <- c("ingest_file", "ingest_sighting", "project", "sample", "analysis", "asset", "lab_qc_report",
            "lab_qc_outlier", "review_queue", "change_log", "schema_version")
  stats::setNames(lapply(tabs, function(t) .mig063_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
}

.mig063_refs <- function(con) {
  c(sample = .mig063_scalar(con, "SELECT COUNT(*) FROM sample WHERE uuid_project = ?", .mig063_drop),
    project = .mig063_scalar(con, "SELECT COUNT(*) FROM project WHERE uuid_parent = ? OR uuid_root = ? OR uuid_project = ?",
                             .mig063_drop, .mig063_drop, .mig063_drop),
    asset = .mig063_scalar(con, "SELECT COUNT(*) FROM asset WHERE uuid_project = ?", .mig063_drop))
}

# Every VARCHAR column of every base table that holds one of `ids` (change_log excluded).
.mig063_scan <- function(con, ids) {
  cols <- DBI::dbGetQuery(con, "SELECT table_name, column_name FROM information_schema.columns c
    WHERE table_schema = 'main' AND data_type = 'VARCHAR' AND table_name <> 'change_log'
      AND table_name IN (SELECT table_name FROM information_schema.tables WHERE table_schema = 'main' AND table_type = 'BASE TABLE')
    ORDER BY table_name, column_name")
  hit <- character(0)
  for (i in seq_len(nrow(cols))) {
    n <- .mig063_scalar(con, sprintf('SELECT COUNT(*) FROM "%s" WHERE "%s" IN %s', cols$table_name[[i]],
                                     cols$column_name[[i]], .mig063_inlist(ids)))
    if (n > 0L) hit <- c(hit, sprintf("%s.%s", cols$table_name[[i]], cols$column_name[[i]]))
  }
  hit
}

# The full write plan, computed from the DB as it is (deterministic for a given state).
.mig063_plan <- function(con) {
  A <- DBI::dbGetQuery(con, sprintf("SELECT * FROM asset WHERE uuid IN %s", .mig063_inlist(.mig063_assets$uuid)))
  R <- DBI::dbGetQuery(con, sprintf("SELECT uuid, uuid_asset, kind FROM lab_qc_report WHERE uuid_asset IN %s ORDER BY uuid",
                                    .mig063_inlist(c(.mig063_survivor, .mig063_merged))))
  I <- DBI::dbGetQuery(con, "SELECT hash FROM ingest_file WHERE uuid_asset = ? ORDER BY hash", params = list(.mig063_merged))
  keep <- A[A$uuid == .mig063_survivor, , drop = FALSE]
  mg <- A[A$uuid == .mig063_merged, , drop = FALSE]
  ch <- list(); filled <- character()
  for (f in .mig063_fill_fields)
    if (is.na(keep[[f]][[1]]) && !is.na(mg[[f]][[1]])) { ch[[f]] <- mg[[f]][[1]]; filled <- c(filled, f) }
  if (is.na(keep$person[[1]]) && !is.na(mg$person[[1]]) && !is.na(mg$organisation[[1]]) &&
      !is.na(keep$organisation[[1]]) && mg$organisation[[1]] == keep$organisation[[1]]) {
    ch$person <- mg$person[[1]]; filled <- c(filled, "person")
  }
  merge_note <- sprintf("%s 063: merged 1 duplicate asset row(s) with identical bytes (hash %s) into this one: %s%s; its archive copy processed/%s/%s is left in place (not moved or deleted)",
                        .mig063_date, .mig063_pdf_hash, .mig063_desc(mg),
                        if (length(filled)) sprintf("; filled %s from them", paste(filled, collapse = ", ")) else "",
                        .mig063_merged, mg$filename[[1]])
  notes <- .mig063_notes
  notes[[.mig063_survivor]] <- paste0(.mig063_moved, "; ", merge_note)
  updates <- list()
  for (i in seq_len(nrow(.mig063_assets))) {
    u <- .mig063_assets$uuid[[i]]; role <- .mig063_assets$role[[i]]
    if (role == "merge") next
    cu <- list()
    if (role == "move") cu$uuid_project <- .mig063_keep
    if (u == .mig063_survivor) cu <- c(cu, ch)
    cu$comments <- .mig063_append(A$comments[A$uuid == u][[1]], notes[[u]])
    updates[[u]] <- cu
  }
  qc_delete <- character(); qc_repoint <- character()
  kinds_keep <- R$kind[R$uuid_asset == .mig063_survivor]
  for (r in R$uuid[R$uuid_asset == .mig063_merged]) {
    kd <- R$kind[R$uuid == r]
    if (kd %in% kinds_keep) qc_delete <- c(qc_delete, r) else { qc_repoint <- c(qc_repoint, r); kinds_keep <- c(kinds_keep, kd) }
  }
  outl <- if (length(qc_delete)) DBI::dbGetQuery(con, sprintf("SELECT uuid FROM lab_qc_outlier WHERE uuid_report IN %s ORDER BY uuid",
                                                              .mig063_inlist(qc_delete)))$uuid else character()
  n_upd <- sum(vapply(updates, length, 0L))
  list(updates = updates, filled = filled, qc_delete = qc_delete, qc_outlier_delete = outl, qc_repoint = qc_repoint,
       ingest_repoint = I$hash,
       n_change_log = n_upd + length(outl) + length(qc_delete) + length(qc_repoint) + length(I$hash) + 2L)
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
  A <- DBI::dbGetQuery(con, sprintf("SELECT uuid, filename, hash, uuid_project, comments FROM asset WHERE uuid IN %s",
                                    .mig063_inlist(.mig063_assets$uuid)))
  A <- A[match(.mig063_assets$uuid, A$uuid), , drop = FALSE]
  if (anyNA(A$uuid) || any(A$filename != .mig063_assets$filename) || any(A$hash != .mig063_assets$hash) ||
      any(A$uuid_project != .mig063_assets$project))
    return("the five asset rows are not as planned")
  if (any(!is.na(A$comments) & grepl("2026-10-21 063:", A$comments, fixed = TRUE))) return("an asset already carries a 063 note")
  if (.mig063_scalar(con, "SELECT COUNT(*) FROM asset WHERE hash = ?", .mig063_pdf_hash) != 3L)
    return("the PDF hash is not on exactly three asset rows")
  for (h in .mig063_assets$hash[.mig063_assets$filename == .mig063_xls_name])
    if (.mig063_scalar(con, "SELECT COUNT(*) FROM asset WHERE hash = ?", h) != 1L)
      return(sprintf("xls hash %s is not on exactly one asset row", h))
  hit <- setdiff(.mig063_scan(con, c(.mig063_merged, .mig063_drop)),
                 c("asset.uuid", "asset.uuid_project", "lab_qc_report.uuid_asset", "ingest_file.uuid_asset", "project.uuid"))
  if (length(hit)) return(sprintf("5aa0c6df or c7b61e56 is referenced from %s", paste(hit, collapse = ", ")))
  NULL
}

.mig063_check_preconditions <- function(con) {
  for (m in .mig063_requires)
    if (.mig063_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", m) == 0L)
      .mig063_fail(sprintf("marker %d is required first (063 runs after the corpus import chain and 064).", m))
  p <- .mig063_problems(con)
  if (!is.null(p)) .mig063_fail(sprintf("%s. Nothing written.", p))
  invisible(TRUE)
}

.mig063_checksum <- function(con, plan) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  tabs <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  touched <- c("asset", "project", "lab_qc_report", "lab_qc_outlier", "ingest_file", "change_log", "schema_version")
  out <- lapply(setdiff(tabs, touched), function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- setdiff(tabs, touched)
  u <- .mig063_inlist(.mig063_assets$uuid)
  out$asset_rest <- q(sprintf("SELECT * FROM asset WHERE uuid NOT IN %s ORDER BY ALL", u))
  out$asset_cols <- q(sprintf("SELECT * EXCLUDE (uuid_project, comments) FROM asset WHERE uuid IN %s ORDER BY uuid",
                              .mig063_inlist(setdiff(.mig063_assets$uuid, c(.mig063_survivor, .mig063_merged)))))
  out$asset_survivor <- q(sprintf("SELECT uuid, name, filename, hash, organisation FROM asset WHERE uuid = '%s'", .mig063_survivor))
  out$project_rest <- q(sprintf("SELECT * FROM project WHERE uuid <> '%s' ORDER BY ALL", .mig063_drop))
  out$qc_report <- q(sprintf("SELECT * EXCLUDE (uuid_asset) FROM lab_qc_report WHERE uuid NOT IN %s ORDER BY uuid",
                             .mig063_inlist(plan$qc_delete)))
  out$qc_report_ptr <- q(sprintf("SELECT uuid, uuid_asset FROM lab_qc_report WHERE uuid NOT IN %s ORDER BY uuid",
                                 .mig063_inlist(c(plan$qc_delete, plan$qc_repoint))))
  out$qc_outlier <- q(sprintf("SELECT * FROM lab_qc_outlier WHERE uuid NOT IN %s ORDER BY uuid", .mig063_inlist(plan$qc_outlier_delete)))
  out$ingest_file <- q("SELECT * EXCLUDE (uuid_asset) FROM ingest_file ORDER BY hash")
  out$ingest_ptr <- q(sprintf("SELECT hash, uuid_asset FROM ingest_file WHERE hash NOT IN %s ORDER BY hash",
                              .mig063_inlist(plan$ingest_repoint)))
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
  if (any(.mig063_refs(con) != 0L)) return("something still references c7b61e56")
  if (.mig063_scalar(con, "SELECT COUNT(*) FROM asset WHERE uuid = ?", .mig063_merged) != 0L) return("asset 5aa0c6df still exists")
  hit <- setdiff(.mig063_scan(con, c(.mig063_merged, .mig063_drop)), character(0))
  if (length(hit)) return(sprintf("5aa0c6df or c7b61e56 is still referenced from %s", paste(hit, collapse = ", ")))
  if (.mig063_scalar(con, "SELECT COUNT(*) FROM lab_qc_outlier o WHERE NOT EXISTS (SELECT 1 FROM lab_qc_report r WHERE r.uuid = o.uuid_report)") != 0L)
    return("orphaned lab_qc_outlier rows")
  H <- DBI::dbGetQuery(con, "SELECT uuid, uuid_project FROM asset WHERE hash = ? ORDER BY uuid", params = list(.mig063_pdf_hash))
  if (!identical(H$uuid, sort(c(.mig063_survivor, "f59d7ed9-e6b0-4ec3-8a01-75f612dd2a72"))))
    return("the PDF hash is not on exactly 91a9c2de and f59d7ed9")
  A <- DBI::dbGetQuery(con, sprintf("SELECT * FROM asset WHERE uuid IN %s", .mig063_inlist(.mig063_assets$uuid)))
  cl <- DBI::dbGetQuery(con, "SELECT tbl, action, uuid_row, field, old, new FROM change_log WHERE actor = ?",
                        params = list(.mig063_actor))
  if (sum(cl$tbl == "project" & cl$action == "delete" & cl$uuid_row == .mig063_drop) != 1L ||
      sum(cl$tbl == "asset" & cl$action == "delete" & cl$uuid_row == .mig063_merged) != 1L ||
      sum(cl$tbl %in% c("project", "asset") & cl$action == "delete") != 2L)
    return("063 delete change_log rows are not the asset 5aa0c6df and project c7b61e56 deletes")
  up <- cl[cl$tbl == "asset" & cl$action == "update", , drop = FALSE]
  kept <- .mig063_assets[.mig063_assets$role != "merge", , drop = FALSE]
  for (i in seq_len(nrow(kept))) {
    u <- kept$uuid[[i]]; a <- A[A$uuid == u, , drop = FALSE]
    want_p <- if (kept$role[[i]] == "move") .mig063_keep else kept$project[[i]]
    cc <- up[up$uuid_row == u & up$field == "comments", , drop = FALSE]
    if (nrow(a) != 1L || !identical(a$uuid_project[[1]], want_p) || nrow(cc) != 1L ||
        !identical(a$comments[[1]], cc$new[[1]]))
      return(sprintf("asset %s is not as planned", substr(u, 1, 8)))
    note <- if (u == .mig063_survivor) NULL else .mig063_notes[[u]]
    if (!is.null(note) && !identical(cc$new[[1]], .mig063_append(cc$old[[1]], note)))
      return(sprintf("asset %s comments are not the planned note", substr(u, 1, 8)))
    if (u == .mig063_survivor && !grepl(paste0(.mig063_moved, "; ", .mig063_date, " 063: merged 1 duplicate asset row(s) with identical bytes (hash ",
                                               .mig063_pdf_hash, ") into this one: ", .mig063_merged), cc$new[[1]], fixed = TRUE))
      return("survivor 91a9c2de comments lack the 063 merge note")
  }
  if (sum(up$field == "uuid_project") != 2L || !setequal(up$uuid_row[up$field == "uuid_project"], kept$uuid[kept$role == "move"]))
    return("uuid_project change_log rows are not the two moves")
  if (sum(up$field == "comments") != 4L) return("comments change_log rows are not the four planned")
  for (i in seq_len(nrow(up))) {
    cur <- A[A$uuid == up$uuid_row[[i]], up$field[[i]]]
    if (!identical(.st_changelog_str(cur[[1]]), up$new[[i]])) return(sprintf("asset %s %s is not the logged new value", up$uuid_row[[i]], up$field[[i]]))
    if (!(up$field[[i]] %in% c("comments", "uuid_project")) && (!is.na(up$old[[i]]) || up$uuid_row[[i]] != .mig063_survivor))
      return(sprintf("asset %s %s fill is not a survivor NULL fill", up$uuid_row[[i]], up$field[[i]]))
  }
  if (any(!(cl$tbl %in% c("asset", "project", "lab_qc_report", "lab_qc_outlier", "ingest_file"))))
    return("063 change_log touches an unplanned table")
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
  plan <- .mig063_plan(con)
  sums_before <- .mig063_checksum(con, plan)
  want <- .mig063_counts(con)
  want$asset <- want$asset - 1L
  want$project <- want$project - 1L
  want$lab_qc_report <- want$lab_qc_report - length(plan$qc_delete)
  want$lab_qc_outlier <- want$lab_qc_outlier - length(plan$qc_outlier_delete)
  want$change_log <- want$change_log + plan$n_change_log
  want$schema_version <- want$schema_version + 1L
  db_transaction(con, function(con) {
    for (u in names(plan$updates))
      db_update(con, "asset", uuid = u, changes = plan$updates[[u]], actor = .mig063_actor, reason = .mig063_reason,
                source_hash = .mig063_assets$hash[.mig063_assets$uuid == u])
    for (o in plan$qc_outlier_delete) db_delete(con, "lab_qc_outlier", uuid = o, actor = .mig063_actor, reason = .mig063_reason)
    for (r in plan$qc_delete) db_delete(con, "lab_qc_report", uuid = r, actor = .mig063_actor,
                                        reason = paste(.mig063_reason, "- the kept asset already has a report of this kind for the same bytes"))
    for (r in plan$qc_repoint)
      db_update(con, "lab_qc_report", uuid = r, changes = list(uuid_asset = .mig063_survivor),
                actor = .mig063_actor, reason = .mig063_reason)
    for (h in plan$ingest_repoint)
      db_update(con, "ingest_file", key = list(hash = h), changes = list(uuid_asset = .mig063_survivor),
                actor = .mig063_actor, reason = .mig063_reason)
    db_delete(con, "asset", uuid = .mig063_merged, actor = .mig063_actor,
              reason = sprintf("%s - merged into %s", .mig063_reason, .mig063_survivor))
    db_delete(con, "project", uuid = .mig063_drop, actor = .mig063_actor, reason = .mig063_reason)
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig063_marker_version, recorded_at))
    .mig063_verify(con)
    got <- .mig063_counts(con)
    if (!identical(got, want))
      .mig063_fail(sprintf("counts are not as planned: %s",
                           paste(names(got), unlist(got), unlist(want), sep = ":", collapse = ", ")))
    if (!identical(sums_before, .mig063_checksum(con, plan))) .mig063_fail("something outside the planned rows moved.")
    NULL
  })
  invisible(plan)
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
  plan <- tryCatch({ .mig063_check_preconditions(pre_con); .mig063_plan(pre_con) },
                   finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  for (u in names(plan$updates))
    logf("asset %s: %s", u, paste(vapply(names(plan$updates[[u]]), function(f)
      sprintf("%s <- %s", f, .st_changelog_str(plan$updates[[u]][[f]])), ""), collapse = " | "))
  logf("merge asset %s into %s (fills: %s); lab_qc_report: %d deleted (+%d outliers), %d re-pointed; ingest_file re-pointed: %d",
       .mig063_merged, .mig063_survivor, if (length(plan$filled)) paste(plan$filled, collapse = ", ") else "none",
       length(plan$qc_delete), length(plan$qc_outlier_delete), length(plan$qc_repoint), length(plan$ingest_repoint))
  logf("delete empty project %s; change_log rows: %d; no file is moved or deleted", .mig063_drop, plan$n_change_log)
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition passed. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_, restore_command = NA_character_,
                          recorded_at = NA, plan = plan)))
  }

  bk_con <- st_connect(db, read_only = TRUE)
  tryCatch({
    pdf <- .mig063_inlist(c(.mig063_survivor, .mig063_merged))
    .mig063_write_csv(DBI::dbGetQuery(bk_con, sprintf("SELECT * FROM asset WHERE uuid IN %s ORDER BY uuid",
                                                      .mig063_inlist(.mig063_assets$uuid))),
                      file.path(csv_dir, sprintf("%s-BACKUP-asset.csv", .mig063_name)), "uuid")
    .mig063_write_csv(DBI::dbGetQuery(bk_con, "SELECT * FROM project WHERE uuid = ?", params = list(.mig063_drop)),
                      file.path(csv_dir, sprintf("%s-BACKUP-project.csv", .mig063_name)), "uuid")
    .mig063_write_csv(DBI::dbGetQuery(bk_con, sprintf("SELECT * FROM lab_qc_report WHERE uuid_asset IN %s ORDER BY uuid", pdf)),
                      file.path(csv_dir, sprintf("%s-BACKUP-lab_qc_report.csv", .mig063_name)), "uuid")
    .mig063_write_csv(DBI::dbGetQuery(bk_con, sprintf("SELECT * FROM lab_qc_outlier WHERE uuid IN %s ORDER BY uuid",
                                                      .mig063_inlist(plan$qc_outlier_delete))),
                      file.path(csv_dir, sprintf("%s-BACKUP-lab_qc_outlier.csv", .mig063_name)), "uuid")
    .mig063_write_csv(DBI::dbGetQuery(bk_con, "SELECT * FROM ingest_file WHERE uuid_asset = ? ORDER BY hash",
                                      params = list(.mig063_merged)),
                      file.path(csv_dir, sprintf("%s-BACKUP-ingest_file.csv", .mig063_name)), "hash")
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

  logf("%s migrated successfully (marker %d): 2 assets moved to ff6f23db, 5aa0c6df merged into 91a9c2de, project c7b61e56 deleted.",
       .mig063_name, .mig063_marker_version)
  invisible(list(status = "migrated", backup_path = backup_path,
                 restore_command = restore_command, recorded_at = recorded_at))
}
