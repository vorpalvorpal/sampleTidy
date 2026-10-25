# REHEARSED, NOT APPLIED (rehearsed 2026-10-25 on a plain-cp copy of live at marker 1079). See
# dev/MIGRATIONS.md row 1080.
# Operator-run migration: re-file the two amended ACIRL reports under their original reports,
# as 062 did, and delete the two empty "Amended 01" shell projects. Marker 1080. Requires 1079.
#
# Authority: Robin, 2026-10-25: amended ACIRL reports are re-filed under their original
# report (the 062 precedent). Supersedes the note 066 (decision 13) left on the two shells.
#
# ---- WHY ------------------------------------------------------------------------------
# Two ACIRL report projects exist only because an amended workbook carried its own report
# number: "2400-7453-03 Amended 01" (76b672cd) and "2400-7286-05-01 Amended 01" (5b58ace4).
# Each is an ACIRL report with no parent, no samples and no child projects; between them
# they hold three assets. The amendments, compared value by value with the originals
# (parsed with the acirl_field_xlsx adapter, and cell by cell) and with live:
#   * 2400-7453-03 Amended 01 (re-issued 19/10/26): the Dust Results month label of B.D07
#     and B.D08 is changed from "Feb" to "Mar" (its Amendment History: "Amended Dust month
#     from Feb to Mar, page 16"); the report number is suffixed throughout. Every parsed
#     sample and result is identical to the original's. The dust block (exposure
#     01/02/2025 - 01/03/2025 in both versions) is already stored on ES2506846's
#     Feb 2025 samples, values and observation text identical; 065 closed the amended
#     file's two A77 date_conflict items as duplicates of those samples. The water field
#     data match live (ES2608464, 16/03/2026) value for value.
#   * 2400-7286-05-01 Amended 01 (re-issued 18/05/2023): "Metals reported in total and not
#     dissolved": the ALS metals copied into the workbook are relabelled Dissolved and
#     replaced by the dissolved values (ALS report ES2314728-1). The adapter drops those
#     copies (lab_data_dropped); live holds both fractions from ALS ES2314728, and the
#     amended values equal the stored dissolved ones. The field data are identical and
#     match live (the B.TS40 label's readings are on B.TS39, 065 FIX-A).
#   So no stored value changes here.
#
# ---- WHAT (frozen in 080-refile-amended-reports-INPUT.csv; two groups, one per shell) --
# Each amended asset goes to the project holding the same kind of original report asset
# (062: the amended asset joins the original report asset):
#   G1  asset a227e454 "2400-7453-03 Amended 01 Annual March 2026 Blaxland WMF  .xls"
#         76b672cd -> f9e26959 "2400-7453-03"   (original workbook 8b54651b sits there)
#       asset 22cb10ae "2400-7453-03 Amended 01 Annual March 2026 Blaxland WMF  .pdf"
#         76b672cd -> 212e78a9 "ES2608464"      (original PDF fb9a4dc2 sits there)
#       ingest_file 4ecde9b381cc81a7edf59d744f88ada4 (the amended .xls): needs_review ->
#         archived (its 4 review items are all resolved, by 065/066)
#       delete project 76b672cd
#   G2  asset 32c1215b "2400-7286-05-01 Amended 01 3rd May 2023 Weekly Special Wednesday
#         Blaxland WMF.xls"  5b58ace4 -> 9c3f4b85 "2400-7286-05-01" (original 18b10b4b)
#       ingest_file 254630ab98f86c58cea4eb2b746bc7a9 (the amended .xls): needs_review ->
#         archived (its 2 review items are resolved, by 065/066)
#       delete project 5b58ace4
#   (The amended 2400-7286-05-01 PDF, asset 0dcff987, is already under ES2314728: untouched.)
# Each moved asset's comments get the old text plus "; " plus the 080 note (or the note
# alone). No file moves: an archived file lives at <archive_dir>/<asset uuid>/<filename>
# (A70), which does not depend on the project.
# The ingest_file transition is the terminal one a clean commit takes (commit.R
# .ct_set_file_states: needs_review -> committed -> archived), written as one db_update of
# state, state_reason and updated_at (as 077/079), so change_log records it.
#
# ---- CHECKS ---------------------------------------------------------------------------
# Per group (a failing group is SKIPPED whole and listed in the SKIPPED CSV): every row the
# group touches (assets, ingest_file rows, shell project) and its anchors (the original
# report assets and target projects) is byte for byte as frozen (row sha1); the shell has
# no samples, no child projects (uuid_parent) and holds exactly the planned assets; no
# VARCHAR column of any base table other than change_log names the shell uuid outside the
# planned asset rows and the shell's own uuid/uuid_root; each planned ingest_file row has
# no open review_queue item.
# In the one write transaction: db_checks("migration") baseline and an all-tier baseline;
# after: every planned row as planned (verify), whole-table checksums of everything else,
# counts (project -n_groups, change_log +2 per move +3 per transition +1 per delete,
# schema_version +1), mig_db_checks_gate(), and no all-tier check gains an offender.
#
# Backups: verified whole-file snapshot; BACKUP CSVs of the asset, ingest_file and project
# rows, and the SKIPPED CSV, written at run time (untracked).
# Idempotent: marker present -> re-verify against the SKIPPED CSV, no-op.
#
#   Rscript dev/migrations/apply-080-refile-amended-reports.R

.mig080_marker_version <- 1080L
.mig080_requires <- 1079L
.mig080_name <- "080-refile-amended-reports"
.mig080_actor <- .mig080_name
.mig080_reason <- "080 (Robin 2026-10-25: amended ACIRL reports are re-filed under their original report)"
.mig080_cols <- c("gid", "op", "tbl", "id", "label", "from_value", "to_value", "anchor", "row_sha1")
.mig080_pk <- c(asset = "uuid", ingest_file = "hash", project = "uuid")
.mig080_state_reason <- "080: amended report re-filed under its original; review items resolved (065/066), data already stored"

.mig080_note_7453 <- paste0(
  "2026-10-25 080: moved from the empty shell project '2400-7453-03 Amended 01' (76b672cd, deleted by 080) to %s, ",
  "where the original report (asset %s) sits; amended reports are re-filed under their original (Robin, 2026-10-25; ",
  "as 062). Amendment 01 (re-issued 19/10/26) only changes the B.D07/B.D08 Dust Results month label Feb -> Mar; ",
  "its dust block (exposure 01/02/2025 - 01/03/2025) is already stored on ES2506846 (065), so no value changes")
.mig080_note_7286 <- paste0(
  "2026-10-25 080: moved from the empty shell project '2400-7286-05-01 Amended 01' (5b58ace4, deleted by 080) to %s, ",
  "where the original report (asset %s) sits; amended reports are re-filed under their original (Robin, 2026-10-25; ",
  "as 062). Amendment 01 (re-issued 18/05/2023) relabels the ALS metals copied into the workbook as dissolved, not ",
  "total (ALS ES2314728-1); those copies are not stored from the workbook and live holds both fractions from ALS ",
  "ES2314728, so no value changes")

# The ruling. op: move (asset uuid_project from -> to; anchor = original report asset that
# must sit under `to`), state (ingest_file needs_review -> archived), delete (project).
.mig080_plan_rows <- data.frame(
  gid = c("G1", "G1", "G1", "G1", "G2", "G2", "G2"),
  op = c("move", "move", "state", "delete", "move", "state", "delete"),
  tbl = c("asset", "asset", "ingest_file", "project", "asset", "ingest_file", "project"),
  id = c("a227e454-e6ee-4ba4-802e-8fb42d809d82", "22cb10ae-79db-44a4-9269-a4876c1f51ed",
         "4ecde9b381cc81a7edf59d744f88ada4", "76b672cd-2a96-4e63-a400-1530f1aaa987",
         "32c1215b-b286-443b-845b-803a41444200", "254630ab98f86c58cea4eb2b746bc7a9",
         "5b58ace4-4542-4843-940f-cd3fabac2bc4"),
  label = c("2400-7453-03 Amended 01 Annual March 2026 Blaxland WMF  .xls",
            "2400-7453-03 Amended 01 Annual March 2026 Blaxland WMF  .pdf",
            "2400-7453-03 Amended 01 Annual March 2026 Blaxland WMF  .xls",
            "2400-7453-03 Amended 01",
            "2400-7286-05-01 Amended 01 3rd May 2023 Weekly Special Wednesday Blaxland WMF.xls",
            "2400-7286-05-01 Amended 01 3rd May 2023 Weekly Special Wednesday Blaxland WMF.xls",
            "2400-7286-05-01 Amended 01"),
  from_value = c("76b672cd-2a96-4e63-a400-1530f1aaa987", "76b672cd-2a96-4e63-a400-1530f1aaa987", "needs_review", NA,
                 "5b58ace4-4542-4843-940f-cd3fabac2bc4", "needs_review", NA),
  to_value = c("f9e26959-5a05-4d9b-8b2e-22cb092edda9", "212e78a9-1f18-4b5c-8503-ed521d21556b", "archived", NA,
               "9c3f4b85-de82-4b17-a739-907146bc4a4b", "archived", NA),
  anchor = c("8b54651b-77f2-4f0a-b6ec-ff6ac58d802e", "fb9a4dc2-577b-46a1-8f84-fe7c1c7aa5e3", NA, NA,
             "18b10b4b-f698-4040-b5e2-44b5a2561c79", NA, NA),
  stringsAsFactors = FALSE)
.mig080_project_names <- c("76b672cd-2a96-4e63-a400-1530f1aaa987" = "2400-7453-03 Amended 01",
                           "5b58ace4-4542-4843-940f-cd3fabac2bc4" = "2400-7286-05-01 Amended 01",
                           "f9e26959-5a05-4d9b-8b2e-22cb092edda9" = "2400-7453-03",
                           "212e78a9-1f18-4b5c-8503-ed521d21556b" = "ES2608464",
                           "9c3f4b85-de82-4b17-a739-907146bc4a4b" = "2400-7286-05-01")

.mig080_fail <- function(msg) cli::cli_abort(paste0(.mig080_name, ": ", msg), class = "sampletidy_error")
.mig080_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = if (length(list(...))) list(...) else NULL)[[1]][[1]])
.mig080_inlist <- function(x) if (!length(x)) "('')" else paste0("(", paste0("'", gsub("'", "''", unique(x)), "'", collapse = ","), ")")

.mig080_note <- function(r) {
  tmpl <- if (r$gid == "G1") .mig080_note_7453 else .mig080_note_7286
  sprintf(tmpl, .mig080_project_names[[r$to_value]], r$anchor)
}
.mig080_append <- function(old, note) if (is.na(old) || !nzchar(trimws(old))) note else paste0(old, "; ", note)

# ---- rows, sha1 -------------------------------------------------------------------------

.mig080_row <- function(con, tbl, id) {
  DBI::dbGetQuery(con, sprintf('SELECT * FROM "%s" WHERE "%s" = ?', tbl, .mig080_pk[[tbl]]), params = list(id))
}

.mig080_sha <- function(df) {
  if (nrow(df) != 1L) return(NA_character_)
  cols <- names(df)
  v <- vapply(cols, function(f) { s <- .st_changelog_str(df[[f]][1]); if (is.na(s)) "<NA>" else s }, "")
  digest::digest(paste(cols, v, sep = "=", collapse = "\u001f"), algo = "sha1", serialize = FALSE)
}

# Every row a group touches or leans on: the planned rows plus anchors and target projects.
.mig080_frozen_keys <- function(x) {
  k <- data.frame(tbl = x$tbl, id = x$id, stringsAsFactors = FALSE)
  mv <- x[x$op == "move", , drop = FALSE]
  k <- rbind(k, data.frame(tbl = "asset", id = mv$anchor), data.frame(tbl = "project", id = mv$to_value))
  k$gid <- c(x$gid, mv$gid, mv$gid)
  k[!duplicated(k[, c("tbl", "id")]), , drop = FALSE]
}

.mig080_frozen_sha <- function(con, x) {
  k <- .mig080_frozen_keys(x)
  k$row_sha1 <- vapply(seq_len(nrow(k)), function(i) .mig080_sha(.mig080_row(con, k$tbl[[i]], k$id[[i]])), "")
  k
}

# ---- plan, freeze, inputs ----------------------------------------------------------------

# The frozen INPUT: one row per planned row, then one "anchor" row per anchor/target.
mig080_plan_con <- function(con) {
  x <- .mig080_plan_rows
  k <- .mig080_frozen_sha(con, x)
  if (anyNA(k$row_sha1)) .mig080_fail(sprintf("row(s) missing at freeze: %s", paste(k$id[is.na(k$row_sha1)], collapse = ", ")))
  x$row_sha1 <- k$row_sha1[match(paste(x$tbl, x$id), paste(k$tbl, k$id))]
  extra <- k[!paste(k$tbl, k$id) %in% paste(x$tbl, x$id), , drop = FALSE]
  ex <- data.frame(gid = extra$gid, op = "anchor", tbl = extra$tbl, id = extra$id, label = NA_character_,
                   from_value = NA_character_, to_value = NA_character_, anchor = NA_character_,
                   row_sha1 = extra$row_sha1, stringsAsFactors = FALSE)
  out <- rbind(x[, .mig080_cols], ex)
  rownames(out) <- NULL
  out
}

mig080_freeze <- function(db, input_dir = "dev/migrations") {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  p <- mig080_plan_con(con)
  pr <- .mig080_problems(con, p)
  if (length(pr)) .mig080_fail(sprintf("plan does not hold at freeze: %s", paste(names(pr), unlist(pr), collapse = "; ")))
  utils::write.csv(p, file.path(input_dir, sprintf("%s-INPUT.csv", .mig080_name)), row.names = FALSE, na = "",
                   fileEncoding = "UTF-8")
  invisible(p)
}

.mig080_read_inputs <- function(input_dir = "dev/migrations") {
  p <- file.path(input_dir, sprintf("%s-INPUT.csv", .mig080_name))
  if (!file.exists(p)) .mig080_fail(sprintf("input %s not found.", p))
  x <- utils::read.csv(p, colClasses = "character", na.strings = "", encoding = "UTF-8")
  if (!identical(names(x), .mig080_cols)) .mig080_fail("INPUT columns are not as planned.")
  if (anyNA(x$row_sha1) || anyDuplicated(paste(x$tbl, x$id))) .mig080_fail("INPUT misses or repeats a row.")
  pl <- x[x$op != "anchor", setdiff(.mig080_cols, "row_sha1")]
  rownames(pl) <- NULL
  if (!identical(pl, .mig080_plan_rows)) .mig080_fail("INPUT does not match Robin's ruling.")
  x
}

.mig080_planned <- function(x) x[x$op != "anchor", , drop = FALSE]

# ---- preconditions -----------------------------------------------------------------------

# Named list gid -> problems.
.mig080_problems <- function(con, x) {
  have <- DBI::dbGetQuery(con, "SELECT version FROM schema_version")$version
  miss <- setdiff(.mig080_requires, have)
  if (length(miss)) .mig080_fail(sprintf("marker(s) %s required first.", paste(miss, collapse = ", ")))
  pr <- list()
  add <- function(g, m) pr[[g]] <<- c(pr[[g]], m)
  for (i in seq_len(nrow(x))) {
    s <- .mig080_sha(.mig080_row(con, x$tbl[[i]], x$id[[i]]))
    if (is.na(s) || s != x$row_sha1[[i]]) add(x$gid[[i]], sprintf("%s %s missing or not as frozen", x$tbl[[i]], x$id[[i]]))
  }
  cols <- DBI::dbGetQuery(con, "SELECT c.table_name, c.column_name FROM information_schema.columns c
    JOIN information_schema.tables t ON t.table_name = c.table_name AND t.table_schema = c.table_schema
    WHERE c.table_schema = 'main' AND t.table_type = 'BASE TABLE' AND c.data_type = 'VARCHAR'
      AND c.table_name <> 'change_log' ORDER BY ALL")
  pl <- .mig080_planned(x)
  for (d in which(pl$op == "delete")) {
    g <- pl$gid[[d]]; shell <- pl$id[[d]]
    moved <- pl$id[pl$gid == g & pl$op == "move"]
    if (.mig080_scalar(con, "SELECT COUNT(*) FROM sample WHERE uuid_project = ?", shell) > 0L) add(g, "shell project has samples")
    if (.mig080_scalar(con, "SELECT COUNT(*) FROM project WHERE uuid_parent = ? OR (uuid_root = ? AND uuid <> ?)",
                       shell, shell, shell) > 0L) add(g, "shell project has child projects")
    held <- DBI::dbGetQuery(con, "SELECT uuid FROM asset WHERE uuid_project = ?", params = list(shell))$uuid
    if (!setequal(held, moved)) add(g, "shell project does not hold exactly the planned assets")
    for (j in seq_len(nrow(cols))) {
      tb <- cols$table_name[[j]]; cl <- cols$column_name[[j]]
      sql <- sprintf('SELECT COUNT(*) FROM "%s" WHERE "%s" LIKE ?', tb, cl)
      if (tb == "project") sql <- paste(sql, sprintf("AND NOT (uuid = '%s' AND '%s' IN ('uuid', 'uuid_root'))", shell, cl))
      if (tb == "asset" && cl == "uuid_project") sql <- paste(sql, sprintf("AND uuid NOT IN %s", .mig080_inlist(moved)))
      n <- .mig080_scalar(con, sql, paste0("%", shell, "%"))
      if (n > 0L) add(g, sprintf("%s.%s references the shell (%d row(s))", tb, cl, n))
    }
  }
  for (k in which(pl$op == "move")) {
    a <- DBI::dbGetQuery(con, "SELECT uuid_project FROM asset WHERE uuid = ?", params = list(pl$anchor[[k]]))
    if (nrow(a) != 1L || !identical(a$uuid_project[[1]], pl$to_value[[k]]))
      add(pl$gid[[k]], sprintf("original report asset %s is not under %s", pl$anchor[[k]], pl$to_value[[k]]))
    m <- DBI::dbGetQuery(con, "SELECT uuid_project, comments FROM asset WHERE uuid = ?", params = list(pl$id[[k]]))
    if (nrow(m) != 1L || !identical(m$uuid_project[[1]], pl$from_value[[k]])) add(pl$gid[[k]], sprintf("asset %s not under the shell", pl$id[[k]]))
  }
  for (k in which(pl$op == "state")) {
    st <- DBI::dbGetQuery(con, "SELECT state FROM ingest_file WHERE hash = ?", params = list(pl$id[[k]]))$state
    if (!identical(st, pl$from_value[[k]])) add(pl$gid[[k]], sprintf("ingest_file %s is not %s", pl$id[[k]], pl$from_value[[k]]))
    if (.mig080_scalar(con, "SELECT COUNT(*) FROM review_queue WHERE source_hash = ? AND status = 'open'", pl$id[[k]]) > 0L)
      add(pl$gid[[k]], sprintf("ingest_file %s has open review items", pl$id[[k]]))
  }
  pr
}

.mig080_skipped_df <- function(pr) {
  if (!length(pr)) return(data.frame(gid = character(), problem = character(), stringsAsFactors = FALSE))
  data.frame(gid = names(pr), problem = vapply(pr, function(p) paste(unique(p), collapse = "; "), ""),
             stringsAsFactors = FALSE)
}

# ---- verify ------------------------------------------------------------------------------

.mig080_done_problem <- function(con, x) {
  if (.mig080_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig080_marker_version) != 1L)
    return("marker 1080 missing")
  pl <- .mig080_planned(x)
  L <- DBI::dbGetQuery(con, "SELECT tbl, action, uuid_row, field, old, new, reason FROM change_log WHERE actor = ?",
                       params = list(.mig080_actor))
  want <- 2L * sum(pl$op == "move") + 3L * sum(pl$op == "state") + sum(pl$op == "delete")
  if (nrow(L) != want) return(sprintf("080 change_log has %d row(s), not %d", nrow(L), want))
  for (i in seq_len(nrow(pl))) {
    r <- pl[i, , drop = FALSE]
    if (r$op == "move") {
      a <- DBI::dbGetQuery(con, "SELECT uuid_project, comments FROM asset WHERE uuid = ?", params = list(r$id))
      if (nrow(a) != 1L || !identical(a$uuid_project[[1]], r$to_value)) return(sprintf("asset %s is not under %s", r$id, r$to_value))
      lc <- L[L$tbl == "asset" & L$uuid_row %in% r$id & L$field %in% "comments", , drop = FALSE]
      lp <- L[L$tbl == "asset" & L$uuid_row %in% r$id & L$field %in% "uuid_project", , drop = FALSE]
      if (nrow(lc) != 1L || nrow(lp) != 1L) return(sprintf("asset %s change_log rows not as planned", r$id))
      if (!identical(lp$old[[1]], r$from_value) || !identical(lp$new[[1]], r$to_value))
        return(sprintf("asset %s uuid_project change_log old/new not as planned", r$id))
      if (!identical(a$comments[[1]], .mig080_append(lc$old[[1]], .mig080_note(r))) || !identical(lc$new[[1]], a$comments[[1]]))
        return(sprintf("asset %s comments are not the old text plus the 080 note", r$id))
      o <- DBI::dbGetQuery(con, "SELECT uuid_project FROM asset WHERE uuid = ?", params = list(r$anchor))$uuid_project
      if (!identical(o, r$to_value)) return(sprintf("original report asset %s is not under %s", r$anchor, r$to_value))
    } else if (r$op == "state") {
      st <- DBI::dbGetQuery(con, "SELECT state, state_reason FROM ingest_file WHERE hash = ?", params = list(r$id))
      if (!identical(c(st$state, st$state_reason), c(r$to_value, .mig080_state_reason)))
        return(sprintf("ingest_file %s is not %s", r$id, r$to_value))
      li <- L[L$tbl == "ingest_file", , drop = FALSE]
      if (sum(grepl(r$id, li$reason, fixed = TRUE)) != 3L) return(sprintf("ingest_file %s change_log rows not as planned", r$id))
    } else {
      if (.mig080_scalar(con, "SELECT COUNT(*) FROM project WHERE uuid = ?", r$id) != 0L) return(sprintf("project %s still exists", r$id))
      ld <- L[L$tbl == "project" & L$action == "delete" & L$uuid_row %in% r$id, , drop = FALSE]
      if (nrow(ld) != 1L) return(sprintf("project %s delete change_log row missing", r$id))
    }
  }
  NULL
}

.mig080_counts <- function(con) {
  tabs <- c("analysis", "sample", "feature", "lab_method", "analyte", "asset", "ingest_file", "ingest_sighting",
            "project", "review_queue", "lab_qc_report", "change_log", "schema_version")
  stats::setNames(lapply(tabs, function(t) .mig080_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
}

.mig080_checksum <- function(con, pl) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  tabs <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  touched <- c("asset", "ingest_file", "project", "change_log", "schema_version")
  out <- lapply(setdiff(tabs, touched), function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- setdiff(tabs, touched)
  mv <- pl$id[pl$op == "move"]
  out$asset_rest <- q(sprintf("SELECT * FROM asset WHERE uuid NOT IN %s ORDER BY ALL", .mig080_inlist(mv)))
  out$asset_cols <- q(sprintf("SELECT * EXCLUDE (uuid_project, comments) FROM asset WHERE uuid IN %s ORDER BY uuid", .mig080_inlist(mv)))
  out$ingest_file_rest <- q(sprintf("SELECT * FROM ingest_file WHERE hash NOT IN %s ORDER BY ALL",
                                    .mig080_inlist(pl$id[pl$op == "state"])))
  out$ingest_file_cols <- q(sprintf("SELECT * EXCLUDE (state, state_reason, updated_at) FROM ingest_file WHERE hash IN %s ORDER BY hash",
                                    .mig080_inlist(pl$id[pl$op == "state"])))
  out$project_rest <- q(sprintf("SELECT * FROM project WHERE uuid NOT IN %s ORDER BY ALL", .mig080_inlist(pl$id[pl$op == "delete"])))
  out$change_log_rest <- q(sprintf("SELECT * FROM change_log WHERE actor <> '%s' ORDER BY uuid", .mig080_actor))
  out$schema_version_rest <- q(sprintf("SELECT * FROM schema_version WHERE version <> %d ORDER BY ALL", .mig080_marker_version))
  out$indexes <- q("SELECT index_name, sql FROM duckdb_indexes() ORDER BY index_name")
  out$views <- q("SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
  out
}

.mig080_checks_problem <- function(before, after) {
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

.mig080_apply <- function(con, x, recorded_at, logf) {
  pl <- .mig080_planned(x)
  db_transaction(con, function(con) {
    baseline <- db_checks(con, tier = "migration")
    before_all <- db_checks(con, tier = "all")
    sums_before <- .mig080_checksum(con, pl)
    want <- .mig080_counts(con)
    want$project <- want$project - sum(pl$op == "delete")
    want$change_log <- want$change_log + 2L * sum(pl$op == "move") + 3L * sum(pl$op == "state") + sum(pl$op == "delete")
    want$schema_version <- want$schema_version + 1L
    for (i in seq_len(nrow(pl))) {
      r <- pl[i, , drop = FALSE]
      why <- sprintf("%s [%s]", .mig080_reason, r$gid)
      if (r$op == "move") {
        old <- DBI::dbGetQuery(con, "SELECT comments, hash FROM asset WHERE uuid = ?", params = list(r$id))
        db_update(con, "asset", uuid = r$id,
                  changes = list(uuid_project = r$to_value, comments = .mig080_append(old$comments[[1]], .mig080_note(r))),
                  actor = .mig080_actor, reason = why, source_hash = old$hash[[1]])
      } else if (r$op == "state") {
        db_update(con, "ingest_file", key = list(hash = r$id),
                  changes = list(state = r$to_value, state_reason = .mig080_state_reason, updated_at = recorded_at),
                  actor = .mig080_actor, reason = sprintf("%s: ingest_file %s", why, r$id), source_hash = r$id)
      } else {
        db_delete(con, "project", uuid = r$id, actor = .mig080_actor,
                  reason = sprintf("%s: empty shell project '%s'", why, r$label))
      }
    }
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig080_marker_version, recorded_at))
    pr <- .mig080_done_problem(con, x)
    if (!is.null(pr)) .mig080_fail(paste0("verify failed: ", pr))
    got <- .mig080_counts(con)
    if (!identical(got, want))
      .mig080_fail(sprintf("table counts are not as planned: %s",
                           paste(names(got), unlist(got), unlist(want), sep = ":", collapse = ", ")))
    if (!identical(sums_before, .mig080_checksum(con, pl))) .mig080_fail("something outside the planned rows moved.")
    mig_db_checks_gate(con, baseline)
    after_all <- db_checks(con, tier = "all")
    pr <- .mig080_checks_problem(before_all, after_all)
    if (!is.null(pr)) .mig080_fail(paste0("standing checks: ", pr))
    logf("Moved %d asset(s), archived %d ingest_file row(s), deleted %d shell project(s).",
         sum(pl$op == "move"), sum(pl$op == "state"), sum(pl$op == "delete"))
    NULL
  })
  invisible(NULL)
}

# ---- backups, files ----------------------------------------------------------------------

mig080_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- if (is.null(.now)) Sys.time() else .now
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig080_name, ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig080_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig080_counts(verify_con)))
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  dest
}

.mig080_write_csv <- function(df, path, key) {
  out <- df
  for (f in names(out)) if (inherits(out[[f]], c("POSIXct", "Date"))) out[[f]] <- .st_changelog_str(out[[f]])
  utils::write.csv(out, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8", colClasses = "character")
  if (nrow(back) != nrow(df) || (nrow(df) && !identical(back[[key]], as.character(out[[key]]))))
    cli::cli_abort("080: CSV {basename(path)} did not round-trip.", class = "sampletidy_error")
}

.mig080_csv <- function(csv_dir, what) file.path(csv_dir, sprintf("%s-%s.csv", .mig080_name, what))

.mig080_read_skipped <- function(csv_dir) {
  f <- .mig080_csv(csv_dir, "SKIPPED")
  if (!file.exists(f)) return(NULL)
  utils::read.csv(f, colClasses = "character", na.strings = "", encoding = "UTF-8")
}

.mig080_write_backups <- function(con, x, csv_dir) {
  pl <- .mig080_planned(x)
  for (tb in c("asset", "ingest_file", "project")) {
    ids <- pl$id[pl$tbl == tb]
    df <- DBI::dbGetQuery(con, sprintf('SELECT * FROM "%s" WHERE "%s" IN %s ORDER BY 1', tb, .mig080_pk[[tb]], .mig080_inlist(ids)))
    .mig080_write_csv(df, .mig080_csv(csv_dir, paste0("BACKUP-", tb)), .mig080_pk[[tb]])
  }
}

# ---- run ---------------------------------------------------------------------------------

mig080_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL, input_dir = "dev/migrations") {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir
  x0 <- .mig080_read_inputs(input_dir)

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                                   params = list(.mig080_marker_version)),
                   finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    sk <- .mig080_read_skipped(csv_dir)
    if (is.null(sk)) .mig080_fail(sprintf("marker present but %s is missing: cannot re-verify.", .mig080_csv(csv_dir, "SKIPPED")))
    x <- x0[!x0$gid %in% sk$gid, , drop = FALSE]
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch({
      pr <- .mig080_done_problem(check_con, x)
      if (!is.null(pr)) .mig080_fail(paste0("re-verify: ", pr))
    }, finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("080 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_, restore_command = NA_character_,
                          recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  problems <- tryCatch({
    if (.mig080_scalar(pre_con, "SELECT COUNT(*) FROM change_log WHERE actor = ?", .mig080_actor) > 0L)
      .mig080_fail("change_log already holds 080 rows but the marker is absent; refusing.")
    .mig080_problems(pre_con, x0)
  }, finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  skipped <- .mig080_skipped_df(problems)
  x <- x0[!x0$gid %in% skipped$gid, , drop = FALSE]
  pl <- .mig080_planned(x)
  logf("Plan: %d group(s) of %d; %d skipped.", length(unique(x$gid)), length(unique(x0$gid)), nrow(skipped))
  for (i in seq_len(nrow(pl))) logf("  %s %s %s %s: %s -> %s", pl$gid[[i]], pl$op[[i]], pl$tbl[[i]], pl$label[[i]],
                                    pl$from_value[[i]], pl$to_value[[i]])
  for (i in seq_len(nrow(skipped))) logf("SKIP %s: %s", skipped$gid[[i]], skipped$problem[[i]])
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition checked. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_, restore_command = NA_character_, recorded_at = NA)))
  }
  if (!nrow(pl)) .mig080_fail("every group is skipped; nothing to do (no marker written).")

  bk_con <- st_connect(db, read_only = TRUE)
  tryCatch({
    .mig080_write_backups(bk_con, x, csv_dir)
    .mig080_write_csv(skipped, .mig080_csv(csv_dir, "SKIPPED"), "gid")
  }, finally = DBI::dbDisconnect(bk_con, shutdown = TRUE))
  logf("Row backups and the SKIPPED plan written to %s", csv_dir)
  backup_path <- mig080_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- if (is.null(.now)) Sys.time() else .now

  with_db_write(function(con) {
    again <- .mig080_problems(con, x)
    if (length(again)) .mig080_fail("a precondition changed since the dry check; re-run.")
    .mig080_apply(con, x, recorded_at, logf)
  }, db = db)

  logf("%s migrated successfully (marker %d).", .mig080_name, .mig080_marker_version)
  invisible(list(status = "migrated", backup_path = backup_path, restore_command = restore_command,
                 recorded_at = recorded_at))
}
