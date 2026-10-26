# Operator-run migration: merge the misnamed ACIRL report project "2400-7430-01 (2025)" into
# 2400-7483-01, the May 2025 Lawson Landfill report it duplicates. Marker 1086. Requires 1084
# (085 was not applied; see MIGRATIONS.md).
#
# Authority: Robin, 2026-10-26 (approved re-parenting the May 2025 Lawson samples).
#
# ---- WHY ------------------------------------------------------------------------------
# The live corpus import (2026-10-21) read two workbooks of the same May 2025 Lawson round:
#   * "2400-7430-01 May 2024 Lawson Landfill[1].xls" (asset b9977731) at 07:26 UTC: a first
#     issue built on the 2024 workbook. It names work order ES2515829 but still carries the 2024
#     report number 2400-7430-01 and the 2024 date (29/05/2024). The import found 2400-7430-01
#     taken (the real May 2024 report, b9e39b4f, with ES2417748), so it made a new ACIRL report
#     project "2400-7430-01 (2025)" (ab341469) under Post-closure monitoring and moved
#     ES2515829 (d6b48438, 12 samples, 27 May 2025) from Post-closure monitoring to it.
#   * "2400-7483-01 May 2025 Lawson Landfill.xls" (asset 1d94bd5b) at 07:29 UTC: the corrected
#     issue (report 2400-7483-01, date 27/05/2025; the work-order cell is blank "ES"). Every
#     sheet is cell-for-cell the same as the first issue except those header cells, the field
#     names and comment wording on Front Page / Groundwater Sites, and one value (Groundwater
#     Sites r15c10, 292 -> 262, already settled to 262 by 065). With ES2515829 already claimed,
#     the import made 2400-7483-01 (477bfaa3) a parentless shell with no children, so the report
#     is blocked.
# "2400-7430-01 (2025)" is therefore a misnamed duplicate of 2400-7483-01, not a separate
# report: merge it into 2400-7483-01 (the precedent is 063, which merged a duplicate project
# and deleted the empty one).
#
# ---- WHAT (frozen in 086-merge-misnamed-lawson-may-2025-report-INPUT.csv) ---------------
#   G1 project d6b48438 ES2515829            uuid_parent ab341469 -> 477bfaa3
#   G1 asset   b9977731 "...[1].xls"         uuid_project ab341469 -> 477bfaa3, + 086 note
#              (kept as its own row: different bytes, the first issue; as 063 kept xls pairs)
#   G1 project 477bfaa3 2400-7483-01         uuid_parent NULL -> 6739ee9c (Post-closure
#              monitoring, where the duplicate and 2400-7430-01 / -02 sit), uuid_root
#              477bfaa3 -> 6739ee9c, + 086 note
#   G1 project ab341469 "2400-7430-01 (2025)" deleted (empty after the moves)
# Untouched: the real 2400-7430-01 (b9e39b4f, its xls e3923caf and ES2417748); the 12 samples
# (their uuid_project stays ES2515829); ES2515829's 6 assets, including the report PDF
# "2400-7430-01 May 2024 Lawson Landfill[1].pdf" (report PDFs sit with the work order); no
# review_queue / asset_filing / lab_qc_report row refers to the projects. No file moves.
#
# ---- CHECKS ---------------------------------------------------------------------------
# Row sha1 of every touched and anchor row as frozen (anchors: 6739ee9c, b9e39b4f, e3923caf,
# 1d94bd5b). The duplicate holds exactly the planned child and asset, no sample, and no other
# reference in any VARCHAR column of any base table but change_log; the survivor has no child,
# no sample and only its own workbook. db_checks("migration") baseline, all-tier checks and
# whole-table checksums of everything else are taken first; then TWO transactions, because
# duckdb cannot delete a project in the transaction that moved its child (the FK check does not
# see the in-transaction update; the FK pattern of 029/031/056): step A commits the three
# updates (survivor first: once ES2515829 points at it, duckdb refuses to update it); step B
# deletes the duplicate, writes the marker, verifies, compares counts (project -1, change_log +7,
# schema_version +1) and checksums, runs mig_db_checks_gate() and requires that no all-tier
# check gains an offender. A run that stopped after step A resumes at step B (post-A state is
# verified: exactly the 6 step-A change_log rows, the duplicate empty and unreferenced). Backups: verified
# whole-file snapshot; BACKUP CSVs of the projects and assets touched, and SKIPPED (untracked).
# Idempotent: marker present -> re-verify, no-op.
#
#   Rscript dev/migrations/apply-086-merge-misnamed-lawson-may-2025-report.R

.mig086_marker_version <- 1086L
.mig086_requires <- 1084L
.mig086_name <- "086-merge-misnamed-lawson-may-2025-report"
.mig086_actor <- .mig086_name
.mig086_reason <- "086 (Robin 2026-10-26: '2400-7430-01 (2025)' is a misnamed duplicate of 2400-7483-01, May 2025 Lawson)"
.mig086_cols <- c("gid", "op", "tbl", "id", "label", "from_value", "to_value", "row_sha1")
.mig086_pk <- c(asset = "uuid", project = "uuid")
.mig086_dup <- "ab341469-278d-44c4-a0a0-0d944204b236"
.mig086_keep <- "477bfaa3-1644-4848-b7cf-dce95e4b645f"
.mig086_wo <- "d6b48438-bfeb-4ba1-a8df-c88ba7e8f121"
.mig086_xls <- "b9977731-9406-4f3a-a590-a0d7036b7746"
.mig086_parent <- "6739ee9c-747c-4bb4-bd26-7ad526aed3dc"
.mig086_real_7430 <- "b9e39b4f-f87d-46eb-8389-dc1079899beb"
.mig086_keep_xls <- "1d94bd5b-a3fd-4f6f-a761-198cdd920f41"
.mig086_note_asset <- paste0(
  "2026-10-26 086: moved from '2400-7430-01 (2025)' (deleted, a misnamed duplicate) to 2400-7483-01. ",
  "A first issue of the May 2025 Lawson report (ES2515829) built on the 2024 workbook: it still carries ",
  "the 2024 report number 2400-7430-01 and date 29/05/2024; '2400-7483-01 May 2025 Lawson Landfill.xls' ",
  "is the corrected issue (Robin, 2026-10-26)")
.mig086_note_project <- paste0(
  "2026-10-26 086: merged '2400-7430-01 (2025)' (a misnamed duplicate of this report, from the first-issue ",
  "workbook '2400-7430-01 May 2024 Lawson Landfill[1].xls') into this project: placed under Post-closure ",
  "monitoring, took work order ES2515829 (May 2025 Lawson, 12 samples) and that workbook (Robin, 2026-10-26)")

.mig086_plan_rows <- data.frame(
  gid = "G1",
  op = c("move", "move", "attach", "delete", "anchor", "anchor", "anchor", "anchor"),
  tbl = c("project", "asset", "project", "project", "project", "project", "asset", "asset"),
  id = c(.mig086_wo, .mig086_xls, .mig086_keep, .mig086_dup, .mig086_parent, .mig086_real_7430,
         "e3923caf-8f37-4473-835a-d2b6f9dfa3a7", .mig086_keep_xls),
  label = c("ES2515829", "2400-7430-01 May 2024 Lawson Landfill[1].xls", "2400-7483-01", "2400-7430-01 (2025)",
            "Post-closure monitoring", "2400-7430-01", "2400-7430-01 May 2024 Lawson Landfill.xls",
            "2400-7483-01 May 2025 Lawson Landfill.xls"),
  from_value = c(.mig086_dup, .mig086_dup, NA, NA, NA, NA, NA, NA),
  to_value = c(.mig086_keep, .mig086_keep, .mig086_parent, NA, NA, NA, NA, NA),
  stringsAsFactors = FALSE)

.mig086_fail <- function(msg) cli::cli_abort(paste0(.mig086_name, ": ", msg), class = "sampletidy_error")
.mig086_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = if (length(list(...))) list(...) else NULL)[[1]][[1]])
.mig086_inlist <- function(x) if (!length(x)) "('')" else paste0("(", paste0("'", gsub("'", "''", unique(x)), "'", collapse = ","), ")")
.mig086_append <- function(old, note) if (is.na(old) || !nzchar(trimws(old))) note else paste0(old, "; ", note)

# ---- rows, sha1 -------------------------------------------------------------------------

.mig086_row <- function(con, tbl, id) {
  DBI::dbGetQuery(con, sprintf('SELECT * FROM "%s" WHERE "%s" = ?', tbl, .mig086_pk[[tbl]]), params = list(id))
}

.mig086_sha <- function(df) {
  if (nrow(df) != 1L) return(NA_character_)
  cols <- names(df)
  v <- vapply(cols, function(f) { s <- .st_changelog_str(df[[f]][1]); if (is.na(s)) "<NA>" else s }, "")
  digest::digest(paste(cols, v, sep = "=", collapse = "\u001f"), algo = "sha1", serialize = FALSE)
}

# Every VARCHAR column of every base table but change_log that holds `id`: "table.column" -> n.
.mig086_refs <- function(con, id) {
  cols <- DBI::dbGetQuery(con, "SELECT c.table_name, c.column_name FROM information_schema.columns c
    JOIN information_schema.tables t ON t.table_name = c.table_name AND t.table_schema = c.table_schema
    WHERE c.table_schema = 'main' AND t.table_type = 'BASE TABLE' AND c.data_type = 'VARCHAR'
      AND c.table_name <> 'change_log' ORDER BY 1, 2")
  out <- integer()
  for (i in seq_len(nrow(cols))) {
    n <- .mig086_scalar(con, sprintf('SELECT COUNT(*) FROM "%s" WHERE "%s" = ?', cols$table_name[[i]], cols$column_name[[i]]), id)
    if (n > 0L) out[[paste(cols$table_name[[i]], cols$column_name[[i]], sep = ".")]] <- n
  }
  out
}

# ---- plan, freeze, inputs ----------------------------------------------------------------

mig086_plan_con <- function(con) {
  x <- .mig086_plan_rows
  x$row_sha1 <- vapply(seq_len(nrow(x)), function(i) .mig086_sha(.mig086_row(con, x$tbl[[i]], x$id[[i]])), "")
  if (anyNA(x$row_sha1)) .mig086_fail(sprintf("row(s) missing at freeze: %s", paste(x$id[is.na(x$row_sha1)], collapse = ", ")))
  x[, .mig086_cols]
}

mig086_freeze <- function(db, input_dir = "dev/migrations") {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  p <- mig086_plan_con(con)
  pr <- .mig086_problems(con, p)
  if (length(pr)) .mig086_fail(sprintf("plan does not hold at freeze: %s", paste(names(pr), unlist(pr), collapse = "; ")))
  utils::write.csv(p, file.path(input_dir, sprintf("%s-INPUT.csv", .mig086_name)), row.names = FALSE, na = "",
                   fileEncoding = "UTF-8")
  invisible(p)
}

.mig086_read_inputs <- function(input_dir = "dev/migrations") {
  p <- file.path(input_dir, sprintf("%s-INPUT.csv", .mig086_name))
  if (!file.exists(p)) .mig086_fail(sprintf("input %s not found.", p))
  x <- utils::read.csv(p, colClasses = "character", na.strings = "", encoding = "UTF-8")
  if (!identical(names(x), .mig086_cols)) .mig086_fail("INPUT columns are not as planned.")
  if (anyNA(x$row_sha1) || anyDuplicated(paste(x$tbl, x$id))) .mig086_fail("INPUT misses or repeats a row.")
  pl <- x[, setdiff(.mig086_cols, "row_sha1")]
  rownames(pl) <- NULL
  if (!identical(pl, .mig086_plan_rows)) .mig086_fail("INPUT does not match Robin's ruling.")
  x
}

# ---- preconditions -----------------------------------------------------------------------

# Named list gid -> problems.
.mig086_problems <- function(con, x) {
  have <- DBI::dbGetQuery(con, "SELECT version FROM schema_version")$version
  miss <- setdiff(.mig086_requires, have)
  if (length(miss)) .mig086_fail(sprintf("marker(s) %s required first.", paste(miss, collapse = ", ")))
  pr <- list()
  add <- function(m) pr[["G1"]] <<- c(pr[["G1"]], m)
  for (i in seq_len(nrow(x))) {
    s <- .mig086_sha(.mig086_row(con, x$tbl[[i]], x$id[[i]]))
    if (is.na(s) || s != x$row_sha1[[i]]) add(sprintf("%s %s missing or not as frozen", x$tbl[[i]], x$id[[i]]))
  }
  p <- function(id) DBI::dbGetQuery(con, "SELECT name, type, uuid_parent, uuid_root FROM project WHERE uuid = ?", params = list(id))
  wo <- p(.mig086_wo); dup <- p(.mig086_dup); keep <- p(.mig086_keep); par <- p(.mig086_parent); real <- p(.mig086_real_7430)
  if (nrow(wo) != 1L || !identical(wo$uuid_parent[[1]], .mig086_dup)) add("ES2515829 is not under the duplicate")
  if (nrow(dup) != 1L || !identical(dup$name[[1]], "2400-7430-01 (2025)") || !identical(dup$uuid_parent[[1]], .mig086_parent))
    add("the duplicate is not '2400-7430-01 (2025)' under Post-closure monitoring")
  if (nrow(keep) != 1L || !identical(keep$name[[1]], "2400-7483-01") || !is.na(keep$uuid_parent[[1]]) ||
      !identical(keep$uuid_root[[1]], .mig086_keep)) add("2400-7483-01 is not a parentless root")
  if (nrow(par) != 1L || !is.na(par$uuid_parent[[1]]) || !identical(par$uuid_root[[1]], .mig086_parent))
    add("Post-closure monitoring is not a root project")
  if (nrow(real) != 1L || !identical(real$name[[1]], "2400-7430-01") || !identical(real$uuid_parent[[1]], .mig086_parent))
    add("the real 2400-7430-01 is not as expected")
  cnt <- function(sql, id) .mig086_scalar(con, sql, id)
  if (cnt("SELECT COUNT(*) FROM sample WHERE uuid_project = ?", .mig086_dup) != 0L) add("the duplicate holds samples")
  if (!identical(DBI::dbGetQuery(con, "SELECT uuid FROM project WHERE uuid_parent = ?", params = list(.mig086_dup))$uuid, .mig086_wo))
    add("the duplicate's children are not exactly ES2515829")
  if (!identical(DBI::dbGetQuery(con, "SELECT uuid FROM asset WHERE uuid_project = ?", params = list(.mig086_dup))$uuid, .mig086_xls))
    add("the duplicate's assets are not exactly the first-issue workbook")
  r <- .mig086_refs(con, .mig086_dup)
  want <- c(asset.uuid_project = 1L, project.uuid = 1L, project.uuid_parent = 1L)
  if (!identical(r[order(names(r))], want[order(names(want))]))
    add(sprintf("the duplicate is referenced elsewhere: %s", paste(names(r), r, collapse = ", ")))
  if (cnt("SELECT COUNT(*) FROM project WHERE uuid_parent = ?", .mig086_keep) != 0L) add("2400-7483-01 already has children")
  if (cnt("SELECT COUNT(*) FROM sample WHERE uuid_project = ?", .mig086_keep) != 0L) add("2400-7483-01 holds samples")
  if (!identical(DBI::dbGetQuery(con, "SELECT uuid FROM asset WHERE uuid_project = ?", params = list(.mig086_keep))$uuid, .mig086_keep_xls))
    add("2400-7483-01's assets are not exactly its workbook")
  h <- DBI::dbGetQuery(con, "SELECT hash FROM asset WHERE uuid IN (?, ?)", params = list(.mig086_xls, .mig086_keep_xls))$hash
  if (.mig086_scalar(con, sprintf("SELECT COUNT(*) FROM review_queue WHERE status = 'open' AND source_hash IN %s", .mig086_inlist(h))) > 0L)
    add("a workbook has open review items")
  if (DBI::dbExistsTable(con, "asset_filing") &&
      .mig086_scalar(con, sprintf("SELECT COUNT(*) FROM asset_filing WHERE uuid_asset IN %s", .mig086_inlist(c(.mig086_xls, .mig086_keep_xls)))) > 0L)
    add("a workbook has a filing record")
  pr
}

.mig086_skipped_df <- function(pr) {
  if (!length(pr)) return(data.frame(gid = character(), problem = character(), stringsAsFactors = FALSE))
  data.frame(gid = names(pr), problem = vapply(pr, function(p) paste(unique(p), collapse = "; "), ""),
             stringsAsFactors = FALSE)
}

# ---- verify ------------------------------------------------------------------------------

.mig086_done_problem <- function(con, x) {
  if (.mig086_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig086_marker_version) != 1L)
    return("marker 1086 missing")
  L <- DBI::dbGetQuery(con, "SELECT tbl, action, uuid_row, field, old, new FROM change_log WHERE actor = ?",
                       params = list(.mig086_actor))
  if (nrow(L) != 7L) return(sprintf("086 change_log has %d row(s), not 7", nrow(L)))
  one <- function(tb, id, fld, old, new) {
    r <- L[L$tbl == tb & L$uuid_row == id & L$field %in% fld, , drop = FALSE]
    nrow(r) == 1L && identical(r$action[[1]], "update") && identical(r$old[[1]], old) && identical(r$new[[1]], new)
  }
  if (!one("project", .mig086_wo, "uuid_parent", .mig086_dup, .mig086_keep)) return("ES2515829 uuid_parent change_log not as planned")
  if (!one("asset", .mig086_xls, "uuid_project", .mig086_dup, .mig086_keep)) return("workbook uuid_project change_log not as planned")
  if (!one("project", .mig086_keep, "uuid_parent", NA_character_, .mig086_parent)) return("2400-7483-01 uuid_parent change_log not as planned")
  if (!one("project", .mig086_keep, "uuid_root", .mig086_keep, .mig086_parent)) return("2400-7483-01 uuid_root change_log not as planned")
  if (sum(L$tbl == "project" & L$uuid_row == .mig086_dup & L$action == "delete") != 1L) return("no delete row for the duplicate")
  wo <- DBI::dbGetQuery(con, "SELECT uuid_parent FROM project WHERE uuid = ?", params = list(.mig086_wo))
  if (nrow(wo) != 1L || !identical(wo$uuid_parent[[1]], .mig086_keep)) return("ES2515829 is not under 2400-7483-01")
  k <- DBI::dbGetQuery(con, "SELECT uuid_parent, uuid_root, comments FROM project WHERE uuid = ?", params = list(.mig086_keep))
  if (nrow(k) != 1L || !identical(k$uuid_parent[[1]], .mig086_parent) || !identical(k$uuid_root[[1]], .mig086_parent))
    return("2400-7483-01 is not under Post-closure monitoring")
  lk <- L[L$tbl == "project" & L$uuid_row == .mig086_keep & L$field %in% "comments", , drop = FALSE]
  if (nrow(lk) != 1L || !identical(k$comments[[1]], .mig086_append(lk$old[[1]], .mig086_note_project)))
    return("2400-7483-01 comments are not the old text plus the 086 note")
  a <- DBI::dbGetQuery(con, "SELECT uuid_project, comments FROM asset WHERE uuid = ?", params = list(.mig086_xls))
  la <- L[L$tbl == "asset" & L$uuid_row == .mig086_xls & L$field %in% "comments", , drop = FALSE]
  if (nrow(a) != 1L || !identical(a$uuid_project[[1]], .mig086_keep)) return("the workbook is not under 2400-7483-01")
  if (nrow(la) != 1L || !identical(a$comments[[1]], .mig086_append(la$old[[1]], .mig086_note_asset)))
    return("the workbook comments are not the old text plus the 086 note")
  if (.mig086_scalar(con, "SELECT COUNT(*) FROM project WHERE uuid = ?", .mig086_dup) != 0L) return("the duplicate still exists")
  if (length(.mig086_refs(con, .mig086_dup))) return("something still references the duplicate")
  if (.mig086_scalar(con, "SELECT COUNT(*) FROM sample WHERE uuid_project = ?", .mig086_wo) != 12L) return("ES2515829 no longer has 12 samples")
  NULL
}

# Post-step-A state (no marker yet): NULL if it is exactly what step A leaves.
.mig086_post_a_problem <- function(con, x) {
  if (.mig086_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig086_marker_version) != 0L)
    return("marker present")
  L <- DBI::dbGetQuery(con, "SELECT tbl, action, uuid_row, field FROM change_log WHERE actor = ?", params = list(.mig086_actor))
  if (nrow(L) != 6L || any(L$action != "update")) return(sprintf("086 change_log has %d row(s), not the 6 step-A updates", nrow(L)))
  for (i in seq_len(nrow(x))) if (x$op[[i]] == "anchor") {
    s <- .mig086_sha(.mig086_row(con, x$tbl[[i]], x$id[[i]]))
    if (is.na(s) || s != x$row_sha1[[i]]) return(sprintf("anchor %s %s not as frozen", x$tbl[[i]], x$id[[i]]))
  }
  p <- DBI::dbGetQuery(con, "SELECT uuid_parent, uuid_root FROM project WHERE uuid = ?", params = list(.mig086_keep))
  if (nrow(p) != 1L || !identical(p$uuid_parent[[1]], .mig086_parent)) return("2400-7483-01 is not under Post-closure monitoring")
  w <- DBI::dbGetQuery(con, "SELECT uuid_parent FROM project WHERE uuid = ?", params = list(.mig086_wo))$uuid_parent
  if (!identical(w, .mig086_keep)) return("ES2515829 is not under 2400-7483-01")
  a <- DBI::dbGetQuery(con, "SELECT uuid_project FROM asset WHERE uuid = ?", params = list(.mig086_xls))$uuid_project
  if (!identical(a, .mig086_keep)) return("the workbook is not under 2400-7483-01")
  if (.mig086_scalar(con, "SELECT COUNT(*) FROM project WHERE uuid = ?", .mig086_dup) != 1L) return("the duplicate is missing")
  r <- .mig086_refs(con, .mig086_dup)
  if (!identical(r, c(project.uuid = 1L))) return(sprintf("the duplicate is still referenced: %s", paste(names(r), r, collapse = ", ")))
  NULL
}

.mig086_counts <- function(con) {
  tabs <- c("analysis", "sample", "feature", "lab_method", "analyte", "asset", "ingest_file", "ingest_sighting",
            "project", "review_queue", "lab_qc_report", "change_log", "schema_version")
  stats::setNames(lapply(tabs, function(t) .mig086_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
}

.mig086_checksum <- function(con) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  tabs <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  touched <- c("asset", "project", "change_log", "schema_version")
  out <- lapply(setdiff(tabs, touched), function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- setdiff(tabs, touched)
  pj <- c(.mig086_wo, .mig086_keep, .mig086_dup)
  out$asset_rest <- q(sprintf("SELECT * FROM asset WHERE uuid <> '%s' ORDER BY ALL", .mig086_xls))
  out$asset_cols <- q(sprintf("SELECT * EXCLUDE (uuid_project, comments) FROM asset WHERE uuid = '%s'", .mig086_xls))
  out$project_rest <- q(sprintf("SELECT * FROM project WHERE uuid NOT IN %s ORDER BY ALL", .mig086_inlist(pj)))
  out$project_wo <- q(sprintf("SELECT * EXCLUDE (uuid_parent) FROM project WHERE uuid = '%s'", .mig086_wo))
  out$project_keep <- q(sprintf("SELECT * EXCLUDE (uuid_parent, uuid_root, comments) FROM project WHERE uuid = '%s'", .mig086_keep))
  out$change_log_rest <- q(sprintf("SELECT * FROM change_log WHERE actor <> '%s' ORDER BY uuid", .mig086_actor))
  out$schema_version_rest <- q(sprintf("SELECT * FROM schema_version WHERE version <> %d ORDER BY ALL", .mig086_marker_version))
  out$indexes <- q("SELECT index_name, sql FROM duckdb_indexes() ORDER BY index_name")
  out$views <- q("SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
  out
}

.mig086_checks_problem <- function(before, after) {
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

.mig086_apply <- function(con, x, recorded_at, logf, resume = FALSE) {
  rs <- function(what) sprintf("%s [%s]", .mig086_reason, what)
  baseline <- db_checks(con, tier = "migration")
  before_all <- db_checks(con, tier = "all")
  sums_before <- .mig086_checksum(con)
  want <- .mig086_counts(con)
  want$project <- want$project - 1L
  want$change_log <- want$change_log + if (resume) 1L else 7L
  want$schema_version <- want$schema_version + 1L
  if (!resume) {
    # Step A (committed): survivor first, then the work order, then the workbook.
    db_transaction(con, function(con) {
      k <- DBI::dbGetQuery(con, "SELECT comments FROM project WHERE uuid = ?", params = list(.mig086_keep))
      db_update(con, "project", uuid = .mig086_keep,
                changes = list(uuid_parent = .mig086_parent, uuid_root = .mig086_parent,
                               comments = .mig086_append(k$comments[[1]], .mig086_note_project)),
                actor = .mig086_actor, reason = rs("2400-7483-01 under Post-closure monitoring"))
      db_update(con, "project", uuid = .mig086_wo, changes = list(uuid_parent = .mig086_keep),
                actor = .mig086_actor, reason = rs("ES2515829 to 2400-7483-01"))
      a <- DBI::dbGetQuery(con, "SELECT comments FROM asset WHERE uuid = ?", params = list(.mig086_xls))
      db_update(con, "asset", uuid = .mig086_xls,
                changes = list(uuid_project = .mig086_keep, comments = .mig086_append(a$comments[[1]], .mig086_note_asset)),
                actor = .mig086_actor, reason = rs("first-issue workbook to 2400-7483-01"))
      pa <- .mig086_post_a_problem(con, x)
      if (!is.null(pa)) .mig086_fail(paste0("step A verify failed: ", pa))
      NULL
    })
    logf("Step A committed: 2400-7483-01 placed, ES2515829 and the first-issue workbook moved.")
  }
  # Step B: delete the empty duplicate, marker, verify, gate.
  db_transaction(con, function(con) {
    db_delete(con, "project", uuid = .mig086_dup, actor = .mig086_actor, reason = rs("empty duplicate deleted"))
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig086_marker_version, recorded_at))
    pr <- .mig086_done_problem(con, x)
    if (!is.null(pr)) .mig086_fail(paste0("verify failed: ", pr))
    got <- .mig086_counts(con)
    if (!identical(got, want))
      .mig086_fail(sprintf("table counts are not as planned: %s",
                           paste(names(got), unlist(got), unlist(want), sep = ":", collapse = ", ")))
    if (!identical(sums_before, .mig086_checksum(con))) .mig086_fail("something outside the planned rows moved.")
    mig_db_checks_gate(con, baseline)
    after_all <- db_checks(con, tier = "all")
    pr <- .mig086_checks_problem(before_all, after_all)
    if (!is.null(pr)) .mig086_fail(paste0("standing checks: ", pr))
    logf("Merged '2400-7430-01 (2025)' into 2400-7483-01.")
    NULL
  })
  invisible(NULL)
}

# ---- backups -----------------------------------------------------------------------------

mig086_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- if (is.null(.now)) Sys.time() else .now
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig086_name, ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig086_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig086_counts(verify_con)))
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  dest
}

.mig086_write_csv <- function(df, path, key) {
  out <- df
  for (f in names(out)) if (inherits(out[[f]], c("POSIXct", "Date"))) out[[f]] <- .st_changelog_str(out[[f]])
  utils::write.csv(out, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8", colClasses = "character")
  if (nrow(back) != nrow(df) || (nrow(df) && !identical(back[[key]], as.character(out[[key]]))))
    cli::cli_abort("086: CSV {basename(path)} did not round-trip.", class = "sampletidy_error")
}

.mig086_csv <- function(csv_dir, what) file.path(csv_dir, sprintf("%s-%s.csv", .mig086_name, what))

.mig086_read_skipped <- function(csv_dir) {
  f <- .mig086_csv(csv_dir, "SKIPPED")
  if (!file.exists(f)) return(NULL)
  utils::read.csv(f, colClasses = "character", na.strings = "", encoding = "UTF-8")
}

# BACKUP CSVs: the three projects touched and both workbooks (before).
.mig086_write_backups <- function(con, csv_dir) {
  ids <- list(project = c(.mig086_wo, .mig086_keep, .mig086_dup), asset = c(.mig086_xls, .mig086_keep_xls))
  for (tb in names(ids)) {
    df <- DBI::dbGetQuery(con, sprintf('SELECT * FROM "%s" WHERE "%s" IN %s ORDER BY 1', tb, .mig086_pk[[tb]], .mig086_inlist(ids[[tb]])))
    .mig086_write_csv(df, .mig086_csv(csv_dir, paste0("BACKUP-", tb)), .mig086_pk[[tb]])
  }
}

# ---- run ---------------------------------------------------------------------------------

mig086_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL, input_dir = "dev/migrations") {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir
  x <- .mig086_read_inputs(input_dir)

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                                   params = list(.mig086_marker_version)),
                   finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    if (is.null(.mig086_read_skipped(csv_dir))) .mig086_fail(sprintf("marker present but %s is missing: cannot re-verify.", .mig086_csv(csv_dir, "SKIPPED")))
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch({
      pr <- .mig086_done_problem(check_con, x)
      if (!is.null(pr)) .mig086_fail(paste0("re-verify: ", pr))
    }, finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("086 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_, restore_command = NA_character_,
                          recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  resume <- FALSE
  problems <- tryCatch({
    if (.mig086_scalar(pre_con, "SELECT COUNT(*) FROM change_log WHERE actor = ?", .mig086_actor) > 0L) {
      pa <- .mig086_post_a_problem(pre_con, x)
      if (!is.null(pa)) .mig086_fail(paste0("change_log holds 086 rows, no marker, and the state is not post-step-A: ", pa))
      resume <- TRUE
      list()
    } else .mig086_problems(pre_con, x)
  }, finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  if (resume) logf("Resuming after step A (verified post-A state).")
  skipped <- .mig086_skipped_df(problems)
  pl <- x[x$op != "anchor", , drop = FALSE]
  logf("Plan: %d group(s); %d skipped.", length(unique(x$gid)), nrow(skipped))
  for (i in seq_len(nrow(pl))) logf("  %s %s %s %s: %s -> %s", pl$gid[[i]], pl$op[[i]], pl$tbl[[i]], pl$label[[i]],
                                    pl$from_value[[i]], pl$to_value[[i]])
  for (i in seq_len(nrow(skipped))) logf("SKIP %s: %s", skipped$gid[[i]], skipped$problem[[i]])
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition checked. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_, restore_command = NA_character_, recorded_at = NA)))
  }
  if (nrow(skipped)) .mig086_fail("the only group is skipped; nothing to do (no marker written).")

  bk_con <- st_connect(db, read_only = TRUE)
  tryCatch({
    if (!resume || !file.exists(.mig086_csv(csv_dir, "BACKUP-project"))) .mig086_write_backups(bk_con, csv_dir)
    .mig086_write_csv(skipped, .mig086_csv(csv_dir, "SKIPPED"), "gid")
  }, finally = DBI::dbDisconnect(bk_con, shutdown = TRUE))
  logf("Row backups and the SKIPPED plan written to %s", csv_dir)
  backup_path <- mig086_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- if (is.null(.now)) Sys.time() else .now

  with_db_write(function(con) {
    again <- if (resume) .mig086_post_a_problem(con, x) else .mig086_problems(con, x)
    if (length(again)) .mig086_fail("a precondition changed since the dry check; re-run.")
    .mig086_apply(con, x, recorded_at, logf, resume = resume)
  }, db = db)

  logf("%s migrated successfully (marker %d).", .mig086_name, .mig086_marker_version)
  invisible(list(status = "migrated", backup_path = backup_path, restore_command = restore_command,
                 recorded_at = recorded_at))
}
