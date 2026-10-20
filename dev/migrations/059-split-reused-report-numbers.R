# Operator-run migration: split the one LIVE report project that holds two
# years of a reused ACIRL report number, so that live matches what C8 (TRIAGE
# D14, "key the ACIRL report project by year") would have produced. Marker
# 1059. Requires 1058.
#
# Authority: Robin, 2026-10-20 (TRIAGE D14 accepted: "Reused ACIRL report
# numbers - key the project by year"; the year already holding the bare name
# keeps it; never rename an existing project). Spec: D14-SPEC.md, "Data repair".
#
# ---- WHAT IS IN LIVE (measured on a copy of live at marker 1052) ---------------
#   Of the report projects (type 'ACIRL report' / 'Monthly gas monitoring')
#   whose own + child-work-order samples span more than one Sydney year, live
#   has exactly two:
#     * 2400-7453-03-01 (Monthly gas monitoring, Blaxland): 202 samples of
#       2025-03-10 and 120 of 2026-03-16 - ACIRL reused the report number for
#       the Mar 2026 round, and the workbook "2400-7453-03-01 Mar 2026 Gas
#       Monitoring Blaxland WMF.xls" (hash e0097856...) merged silently into the
#       Mar 2025 project; it raised the open duplicate_report_number/acirl_gas
#       item fc453ccd. -> REPAIRED here.
#     * 2400-7454-12-01 (gas): 2025-12-10 + 2026-01-05 from ONE workbook (a
#       December report carrying January readings). Not reuse; C8 keys it by
#       year SET, so it stays one project. -> untouched.
#   The other measured D14 cases are NOT merged in live; they arise only when
#   the historical corpus is imported, where the C8 code keys them by year:
#     * 2400-7453-03: live holds the bare report with child ES2608464 (Mar 2026)
#       only; ES2506846 (Mar 2025) sits directly under 'EPL annual'. The corpus's
#       Mar 2025 report therefore gets "2400-7453-03 (2025)" (live's 2026 keeps
#       the bare name).
#     * 2400-7430-01: no such project in live (ES2417748 and ES2515829 both sit
#       under 'Post-closure monitoring'); both reports come from the corpus.
#     * 2400-7399-04: live holds the bare Apr 2026 report (ES2610538); the
#       corpus's Apr 2024 file gets "2400-7399-04 (2024)".
#
# ---- WRITES (one transaction) ---------------------------------------------------
#   * project eddd50ca-7cb2-4ad0-9979-6277d756e48c "2400-7453-03-01 (2026)",
#     type 'Monthly gas monitoring', parent/root 'Monthly gas monitoring'
#     (8e9e28a0, as the bare row), date_start = date_end = 2026-03-16 (the bare
#     row's convention), comments = the 059 note. A NEW row: the bare row is not
#     renamed (duckdb 1.4.1 self-FK, Bug D in R/commit.R; and C8 never renames).
#   * the 120 samples of 2400-7453-03-01 dated 2026 (Sydney) -> uuid_project
#     = the new row; comments <- "<existing>; 2026-10-20 corpus import (D14):
#     ...". Their analyses are untouched (they follow the sample).
#   * asset 48bfbeee (the Mar 2026 workbook) -> uuid_project = the new row,
#     comments appended.
#   * the bare 2400-7453-03-01 keeps its 202 Mar 2025 samples; comments
#     appended (it is referenced by no project row, so the UPDATE is legal).
#   * review_queue fc453ccd (duplicate_report_number/acirl_gas, open) ->
#     resolved, with the resolution naming the split.
#   Every field change is a change_log row (actor "059-split-reused-report-numbers").
#
# ---- HOW (the FK step; 056's pattern) -------------------------------------------
#   ux_sample_identity covers (uuid_feature_alias, datetime, uuid_project), so a
#   sample.uuid_project UPDATE is delete + insert in duckdb 1.4.1, which the
#   analysis -> sample FK refuses. The index is dropped (autocommit) around the
#   transaction and re-created in a finally (inside a function: a top-level
#   on.exit() is inert under Rscript). A run interrupted between the drop and
#   the re-create leaves no marker; a re-run accepts the missing index and
#   re-creates it.
#
# ---- PRECONDITIONS (any failure aborts; nothing is written) ---------------------
#   * marker 1058 present;
#   * the bare project 470ece70 exists as described (name, type, parent, root),
#     referenced by no project row; no project named "2400-7453-03-01 (2026)"
#     and no row with the new uuid;
#   * it holds exactly 120 samples on Sydney 2026-03-16 and 202 on 2025-03-10,
#     nothing else; no child project holds samples;
#   * asset 48bfbeee is the Mar 2026 workbook, on the bare project;
#   * review item fc453ccd is open, kind duplicate_report_number/acirl_gas.
#
# Checksums: every other table in full, and the untouched rows/columns of
# project, sample, asset and review_queue, before and after. BACKUPS: verified
# whole-file snapshot, plus BACKUP CSVs of every project / sample / asset /
# review_queue row written, as it was before.
#
# Idempotent: marker present -> re-verify, no-op.
#
#   devtools::load_all(".")
#   env <- new.env()
#   sys.source("dev/migrations/059-split-reused-report-numbers.R", envir = env)
#   env$mig059_run(db = st_config("live_db"),
#                  snapshot_dir = st_config("snapshot_dir"), dry_run = TRUE)

.mig059_marker_version <- 1059L
.mig059_requires <- 1058L
.mig059_name <- "059-split-reused-report-numbers"
.mig059_actor <- .mig059_name
.mig059_date <- "2026-10-20"
.mig059_reason <- "059 (Robin, 2026-10-20, TRIAGE D14): reused ACIRL report number keyed by year; Mar 2026 split from 2400-7453-03-01 (Mar 2025)"
.mig059_index_name <- "ux_sample_identity"
.mig059_index_sql <- 'CREATE UNIQUE INDEX ux_sample_identity ON "sample"(uuid_feature_alias, datetime, uuid_project);'

.mig059_report_no <- "2400-7453-03-01"
.mig059_bare <- "470ece70-7c62-4fbf-9a5c-cf75f1ca4f03"
.mig059_campaign <- "8e9e28a0-39f5-4c9e-a47c-0a7c1c1fca60"   # 'Monthly gas monitoring'
.mig059_new <- "eddd50ca-7cb2-4ad0-9979-6277d756e48c"        # fixed literal
.mig059_new_name <- "2400-7453-03-01 (2026)"
.mig059_type <- "Monthly gas monitoring"
.mig059_asset <- "48bfbeee-3aba-4a94-8865-8cdfbf6c9b30"
.mig059_asset_file <- "2400-7453-03-01 Mar 2026 Gas Monitoring Blaxland WMF.xls"
.mig059_review <- "fc453ccd-6fa3-4044-b500-2e4b2119607a"
.mig059_resolved_by <- "R. Shannon"
.mig059_n_move <- 120L
.mig059_n_keep <- 202L
.mig059_day_move <- "2026-03-16"
.mig059_day_keep <- "2025-03-10"

.mig059_syd <- "cast(coalesce(s.date, s.datetime) + interval 11 hour as date)"
.mig059_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = list(...))[[1]][[1]])
.mig059_fail <- function(msg) cli::cli_abort(paste0(.mig059_name, ": ", msg), class = "sampletidy_error")
.mig059_inlist <- function(x) if (!length(x)) "('')" else paste0("(", paste0("'", gsub("'", "''", x), "'", collapse = ","), ")")
.mig059_append <- function(old, note) {
  n <- sprintf("%s corpus import (D14): %s", .mig059_date, note)
  if (is.na(old) || !nzchar(trimws(old))) n else paste0(old, "; ", n)
}
.mig059_note_sample <- sprintf(
  "moved from report project %s (Mar 2025) to %s - ACIRL reused report number %s for the 16 Mar 2026 gas round (workbook '%s'), which had merged into the Mar 2025 project; migration 059",
  .mig059_report_no, .mig059_new_name, .mig059_report_no, .mig059_asset_file)
.mig059_note_bare <- sprintf(
  "ACIRL reused report number %s for the 16 Mar 2026 gas round; its %d samples were moved to the new project '%s' (this project keeps the %d Mar 2025 samples and the bare name); migration 059",
  .mig059_report_no, .mig059_n_move, .mig059_new_name, .mig059_n_keep)
.mig059_note_new <- sprintf(
  "created for the 16 Mar 2026 gas round, which ACIRL issued under the reused report number %s; its %d samples and workbook moved here from the Mar 2025 project '%s' (which keeps the bare name); migration 059",
  .mig059_report_no, .mig059_n_move, .mig059_report_no)
.mig059_note_asset <- sprintf("moved from project %s to %s (the Mar 2026 round of reused report number %s); migration 059",
                              .mig059_report_no, .mig059_new_name, .mig059_report_no)
.mig059_resolution <- sprintf(
  "059 (D14, Robin 2026-10-20): resolved by keying the report by year - the Mar 2026 samples moved to the new project '%s'; '%s' keeps Mar 2025",
  .mig059_new_name, .mig059_report_no)

.mig059_new_row <- function() {
  data.frame(uuid = .mig059_new, uuid_parent = .mig059_campaign, uuid_root = .mig059_campaign,
             uuid_project = NA_character_, name = .mig059_new_name, type = .mig059_type, purpose = NA_character_,
             date_start = as.POSIXct(paste(.mig059_day_move, "00:00:00"), tz = "UTC"),
             date_end = as.POSIXct(paste(.mig059_day_move, "00:00:00"), tz = "UTC"),
             regulated_by = NA_character_, cypher = NA_character_, site = NA_character_, value = NA_real_,
             comments = .mig059_append(NA, .mig059_note_new), stringsAsFactors = FALSE)
}

.mig059_samples_by_day <- function(con, project) {
  DBI::dbGetQuery(con, sprintf('SELECT s.uuid, s.comments, CAST(%s AS VARCHAR) AS d FROM "sample" s
    WHERE s.uuid_project = ? ORDER BY s.uuid', .mig059_syd), params = list(project))
}

.mig059_counts <- function(con) {
  tabs <- c("project", "sample", "analysis", "asset", "ingest_file", "review_queue", "feature_alias",
            "change_log", "schema_version")
  stats::setNames(lapply(tabs, function(t) .mig059_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
}

# The plan, from the DB as it is (pre-059).
.mig059_plan <- function(con) {
  S <- .mig059_samples_by_day(con, .mig059_bare)
  mv <- S[S$d == .mig059_day_move, , drop = FALSE]
  asset_c <- DBI::dbGetQuery(con, "SELECT comments FROM asset WHERE uuid = ?", params = list(.mig059_asset))$comments
  bare_c <- DBI::dbGetQuery(con, "SELECT comments FROM project WHERE uuid = ?", params = list(.mig059_bare))$comments
  list(move = mv$uuid, move_comments = stats::setNames(mv$comments, mv$uuid),
       keep = S$uuid[S$d == .mig059_day_keep],
       asset_comments = if (length(asset_c)) asset_c[[1]] else NA_character_,
       bare_comments = if (length(bare_c)) bare_c[[1]] else NA_character_,
       # 1 project insert + 2 per sample + bare comments + asset 2 + review 4
       n_change_log = 1L + 2L * nrow(mv) + 1L + 2L + 4L)
}

.mig059_pre_problems <- function(con) {
  probs <- character(0)
  P <- DBI::dbGetQuery(con, "SELECT * FROM project WHERE uuid = ?", params = list(.mig059_bare))
  if (nrow(P) != 1L || !identical(P$name, .mig059_report_no) || !identical(P$type, .mig059_type) ||
      !identical(P$uuid_parent, .mig059_campaign) || !identical(P$uuid_root, .mig059_campaign))
    probs <- c(probs, sprintf("project %s is not the bare gas report %s under 'Monthly gas monitoring'", .mig059_bare, .mig059_report_no))
  if (.mig059_scalar(con, "SELECT COUNT(*) FROM project WHERE uuid_parent = ? OR uuid_project = ?", .mig059_bare, .mig059_bare) != 0L)
    probs <- c(probs, "the bare project is referenced by another project row")
  if (.mig059_scalar(con, "SELECT COUNT(*) FROM project WHERE uuid = ? OR name = ?", .mig059_new, .mig059_new_name) != 0L)
    probs <- c(probs, sprintf("a project '%s' (or uuid %s) already exists", .mig059_new_name, .mig059_new))
  C <- DBI::dbGetQuery(con, "SELECT uuid, name FROM project WHERE uuid = ?", params = list(.mig059_campaign))
  if (nrow(C) != 1L || !identical(C$name, "Monthly gas monitoring")) probs <- c(probs, "campaign 'Monthly gas monitoring' (8e9e28a0) missing")
  S <- .mig059_samples_by_day(con, .mig059_bare)
  tab <- table(S$d)
  want <- stats::setNames(c(.mig059_n_keep, .mig059_n_move), c(.mig059_day_keep, .mig059_day_move))
  if (!identical(sort(names(tab)), sort(names(want))) || any(as.integer(tab[names(want)]) != want))
    probs <- c(probs, sprintf("the bare project's samples by Sydney day are {%s}, expected {%s}",
                              paste(names(tab), tab, sep = ":", collapse = " "), paste(names(want), want, sep = ":", collapse = " ")))
  A <- DBI::dbGetQuery(con, "SELECT filename, uuid_project FROM asset WHERE uuid = ?", params = list(.mig059_asset))
  if (nrow(A) != 1L || !identical(A$filename, .mig059_asset_file) || !identical(A$uuid_project, .mig059_bare))
    probs <- c(probs, sprintf("asset %s is not the Mar 2026 workbook on the bare project", .mig059_asset))
  R <- DBI::dbGetQuery(con, "SELECT kind, subkind, status, work_order FROM review_queue WHERE uuid = ?", params = list(.mig059_review))
  if (nrow(R) != 1L || !identical(R$kind, "duplicate_report_number") || !identical(R$subkind, "acirl_gas") ||
      !identical(R$status, "open") || !identical(R$work_order, .mig059_report_no))
    probs <- c(probs, sprintf("review item %s is not the open duplicate_report_number/acirl_gas item", .mig059_review))
  probs
}

.mig059_check_preconditions <- function(con) {
  if (.mig059_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig059_requires) == 0L)
    .mig059_fail(sprintf("marker %d (058) is required first.", .mig059_requires))
  probs <- .mig059_pre_problems(con)
  if (length(probs)) .mig059_fail(sprintf("%d problem(s): %s. Nothing written.", length(probs), paste(probs, collapse = " | ")))
  invisible(TRUE)
}

.mig059_checksum <- function(con, plan) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  tabs <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  touched <- c("project", "sample", "asset", "review_queue", "change_log", "schema_version")
  out <- lapply(setdiff(tabs, touched), function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- setdiff(tabs, touched)
  out$project_rest <- q(sprintf("SELECT * FROM project WHERE uuid NOT IN %s ORDER BY uuid", .mig059_inlist(c(.mig059_bare, .mig059_new))))
  out$project_bare <- q(sprintf("SELECT * EXCLUDE (comments) FROM project WHERE uuid = '%s'", .mig059_bare))
  out$sample_rest <- q(sprintf('SELECT * FROM "sample" WHERE uuid NOT IN %s ORDER BY uuid', .mig059_inlist(plan$move)))
  out$sample_moved <- q(sprintf('SELECT * EXCLUDE (uuid_project, comments) FROM "sample" WHERE uuid IN %s ORDER BY uuid', .mig059_inlist(plan$move)))
  out$asset_rest <- q(sprintf("SELECT * FROM asset WHERE uuid <> '%s' ORDER BY uuid", .mig059_asset))
  out$asset_row <- q(sprintf("SELECT * EXCLUDE (uuid_project, comments) FROM asset WHERE uuid = '%s'", .mig059_asset))
  out$review_rest <- q(sprintf("SELECT * FROM review_queue WHERE uuid <> '%s' ORDER BY uuid", .mig059_review))
  out$review_row <- q(sprintf("SELECT * EXCLUDE (status, resolution, resolved_by, resolved_at) FROM review_queue WHERE uuid = '%s'", .mig059_review))
  out$change_log_rest <- q(sprintf("SELECT * FROM change_log WHERE actor <> '%s' ORDER BY ALL", .mig059_actor))
  out$schema_version_rest <- q(sprintf("SELECT * FROM schema_version WHERE version <> %d ORDER BY ALL", .mig059_marker_version))
  out$views <- q("SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
  out$indexes <- q("SELECT index_name, sql FROM duckdb_indexes() ORDER BY index_name")
  out
}

# NULL when the post-059 state holds; otherwise the first problem. `index` FALSE
# skips the ux_sample_identity check (it is dropped inside the transaction).
.mig059_done_problem <- function(con, index = TRUE) {
  if (.mig059_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig059_marker_version) != 1L)
    return("marker 1059 missing")
  if (index && .mig059_scalar(con, "SELECT COUNT(*) FROM duckdb_indexes() WHERE index_name = ?", .mig059_index_name) != 1L)
    return("ux_sample_identity is missing")
  N <- DBI::dbGetQuery(con, "SELECT * FROM project WHERE uuid = ?", params = list(.mig059_new))
  want <- .mig059_new_row()
  if (nrow(N) != 1L) return("the new project row is missing")
  for (f in setdiff(names(want), "comments"))
    if (!identical(.st_changelog_str(N[[f]]), .st_changelog_str(want[[f]]))) return(sprintf("new project field %s is not as planned", f))
  if (is.na(N$comments) || !grepl(.mig059_note_new, N$comments, fixed = TRUE)) return("new project comments lack the 059 note")
  if (.mig059_scalar(con, "SELECT COUNT(*) FROM project WHERE name = ?", .mig059_new_name) != 1L) return("the new project name is not unique")
  B <- DBI::dbGetQuery(con, "SELECT name, comments FROM project WHERE uuid = ?", params = list(.mig059_bare))
  if (nrow(B) != 1L || !identical(B$name, .mig059_report_no)) return("the bare project is missing or renamed")
  if (is.na(B$comments) || !grepl(.mig059_note_bare, B$comments, fixed = TRUE)) return("the bare project's comments lack the 059 note")
  SB <- .mig059_samples_by_day(con, .mig059_bare)
  if (nrow(SB) != .mig059_n_keep || any(SB$d != .mig059_day_keep)) return("the bare project does not hold exactly its 202 Mar 2025 samples")
  SN <- .mig059_samples_by_day(con, .mig059_new)
  if (nrow(SN) != .mig059_n_move || any(SN$d != .mig059_day_move)) return("the new project does not hold exactly the 120 Mar 2026 samples")
  if (any(is.na(SN$comments)) || !all(grepl(.mig059_note_sample, SN$comments, fixed = TRUE)))
    return("a moved sample's comments lack the 059 note")
  A <- DBI::dbGetQuery(con, "SELECT uuid_project, comments FROM asset WHERE uuid = ?", params = list(.mig059_asset))
  if (nrow(A) != 1L || !identical(A$uuid_project, .mig059_new) || is.na(A$comments) || !grepl(.mig059_note_asset, A$comments, fixed = TRUE))
    return("the Mar 2026 workbook asset is not on the new project with the 059 note")
  R <- DBI::dbGetQuery(con, "SELECT status, resolution FROM review_queue WHERE uuid = ?", params = list(.mig059_review))
  if (nrow(R) != 1L || !identical(R$status, "resolved") || !identical(R$resolution, .mig059_resolution))
    return("review item fc453ccd is not resolved by 059")
  cl <- DBI::dbGetQuery(con, "SELECT tbl, action, field, uuid_row, new FROM change_log WHERE actor = ?", params = list(.mig059_actor))
  if (nrow(cl) != 1L + 2L * .mig059_n_move + 1L + 2L + 4L) return(sprintf("%d change_log rows by 059, expected %d", nrow(cl), 248L))
  mvl <- cl[cl$tbl == "sample" & cl$field == "uuid_project", , drop = FALSE]
  if (!setequal(mvl$uuid_row, SN$uuid) || any(mvl$new != .mig059_new)) return("sample move change_log rows do not match the moved samples")
  NULL
}

.mig059_verify <- function(con, index = TRUE) {
  p <- .mig059_done_problem(con, index = index)
  if (!is.null(p)) cli::cli_abort(paste0("059 verify failed: ", p), class = "sampletidy_error")
  invisible(TRUE)
}

mig059_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- if (is.null(.now)) Sys.time() else .now
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig059_name, ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig059_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig059_counts(verify_con)))
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  dest
}

.mig059_write_csv <- function(df, path, key) {
  out <- df
  for (f in names(out)) if (inherits(out[[f]], c("POSIXct", "Date"))) out[[f]] <- .st_changelog_str(out[[f]])
  utils::write.csv(out, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8", colClasses = "character")
  if (nrow(back) != nrow(df) || !identical(back[[key]], as.character(out[[key]])))
    cli::cli_abort("059: CSV {basename(path)} did not round-trip.", class = "sampletidy_error")
}

.mig059_transaction <- function(con, plan, recorded_at, sums_before, want) {
  db_transaction(con, function(con) {
    act <- .mig059_actor
    db_append(con, "project", .mig059_new_row(), actor = act,
              reason = paste(.mig059_reason, "- new year-keyed report project (the bare row is never renamed)"))
    for (u in plan$move) {
      db_update(con, "sample", uuid = u,
                changes = list(uuid_project = .mig059_new,
                               comments = .mig059_append(plan$move_comments[[u]], .mig059_note_sample)),
                actor = act, reason = paste(.mig059_reason, "- 16 Mar 2026 sample re-filed to", .mig059_new_name))
    }
    db_update(con, "project", uuid = .mig059_bare,
              changes = list(comments = .mig059_append(plan$bare_comments, .mig059_note_bare)),
              actor = act, reason = paste(.mig059_reason, "- note on the Mar 2025 project"))
    db_update(con, "asset", uuid = .mig059_asset,
              changes = list(uuid_project = .mig059_new, comments = .mig059_append(plan$asset_comments, .mig059_note_asset)),
              actor = act, reason = paste(.mig059_reason, "- the Mar 2026 workbook follows its samples"))
    db_update(con, "review_queue", uuid = .mig059_review,
              changes = list(status = "resolved", resolution = .mig059_resolution,
                             resolved_by = .mig059_resolved_by, resolved_at = recorded_at),
              actor = act, reason = paste(.mig059_reason, "- the duplicate_report_number item is answered by the split"))
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig059_marker_version, recorded_at))
    .mig059_verify(con, index = FALSE)
    got <- .mig059_counts(con)
    if (!identical(got, want))
      .mig059_fail(sprintf("counts are not as planned: %s", paste(names(got), unlist(got), unlist(want), sep = ":", collapse = ", ")))
    sums_after <- .mig059_checksum(con, plan)
    sums_after$indexes <- sums_before$indexes   # the index is dropped inside; compared after the re-create
    if (!identical(sums_before, sums_after)) {
      bad <- names(sums_before)[!vapply(names(sums_before), function(n) identical(sums_before[[n]], sums_after[[n]]), TRUE)]
      .mig059_fail(sprintf("something outside the planned rows/columns moved: %s", paste(bad, collapse = ", ")))
    }
    NULL
  })
}

.mig059_apply <- function(con, plan, recorded_at, logf) {
  if (.mig059_scalar(con, "SELECT COUNT(*) FROM duckdb_indexes() WHERE index_name = ?", .mig059_index_name) == 0L) {
    DBI::dbExecute(con, .mig059_index_sql)    # an earlier run was interrupted between drop and re-create
    logf("Re-created %s left missing by an interrupted run.", .mig059_index_name)
  }
  sums_before <- .mig059_checksum(con, plan)
  want <- .mig059_counts(con)
  want$project <- want$project + 1L
  want$change_log <- want$change_log + plan$n_change_log
  want$schema_version <- want$schema_version + 1L
  DBI::dbExecute(con, sprintf("DROP INDEX %s", .mig059_index_name))
  logf("Dropped %s (committed).", .mig059_index_name)
  tryCatch({
    .mig059_transaction(con, plan, recorded_at, sums_before, want)
    logf("Transaction committed.")
  }, finally = {
    if (.mig059_scalar(con, "SELECT COUNT(*) FROM duckdb_indexes() WHERE index_name = ?", .mig059_index_name) == 0L) {
      DBI::dbExecute(con, .mig059_index_sql)
      logf("Re-created %s.", .mig059_index_name)
    }
  })
  if (!identical(sums_before$indexes, .mig059_checksum(con, plan)$indexes)) .mig059_fail("indexes differ after the re-create.")
  .mig059_verify(con)
  invisible(TRUE)
}

mig059_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(
    DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                    params = list(.mig059_marker_version)),
    finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch(.mig059_verify(check_con), finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("059 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  plan <- tryCatch({ .mig059_check_preconditions(pre_con); .mig059_plan(pre_con) },
                   finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  logf("Plan: create project '%s' (%s); move %d samples (Sydney %s) from '%s' (keeps %d of %s); move asset %s; resolve review %s; change_log rows: %d.",
       .mig059_new_name, substr(.mig059_new, 1, 8), length(plan$move), .mig059_day_move, .mig059_report_no,
       length(plan$keep), .mig059_day_keep, substr(.mig059_asset, 1, 8), substr(.mig059_review, 1, 8), plan$n_change_log)
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition passed. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_, restore_command = NA_character_,
                          recorded_at = NA, plan = plan)))
  }

  bk_con <- st_connect(db, read_only = TRUE)
  tryCatch({
    .mig059_write_csv(DBI::dbGetQuery(bk_con, sprintf("SELECT * FROM project WHERE uuid IN %s ORDER BY uuid",
                                                      .mig059_inlist(c(.mig059_bare, .mig059_new)))),
                      file.path(csv_dir, sprintf("%s-BACKUP-project.csv", .mig059_name)), "uuid")
    .mig059_write_csv(DBI::dbGetQuery(bk_con, sprintf('SELECT * FROM "sample" WHERE uuid IN %s ORDER BY uuid', .mig059_inlist(plan$move))),
                      file.path(csv_dir, sprintf("%s-BACKUP-sample.csv", .mig059_name)), "uuid")
    .mig059_write_csv(DBI::dbGetQuery(bk_con, "SELECT * FROM asset WHERE uuid = ?", params = list(.mig059_asset)),
                      file.path(csv_dir, sprintf("%s-BACKUP-asset.csv", .mig059_name)), "uuid")
    .mig059_write_csv(DBI::dbGetQuery(bk_con, "SELECT * FROM review_queue WHERE uuid = ?", params = list(.mig059_review)),
                      file.path(csv_dir, sprintf("%s-BACKUP-review_queue.csv", .mig059_name)), "uuid")
  }, finally = DBI::dbDisconnect(bk_con, shutdown = TRUE))
  logf("Row backups written to %s", csv_dir)
  backup_path <- mig059_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- if (is.null(.now)) Sys.time() else .now

  with_db_write(function(con) {
    .mig059_check_preconditions(con)   # re-read under the write lock
    plan <- .mig059_plan(con)
    .mig059_apply(con, plan, recorded_at, logf)
  }, db = db)

  logf("%s migrated successfully (marker %d): %d samples moved to '%s'.",
       .mig059_name, .mig059_marker_version, length(plan$move), .mig059_new_name)
  invisible(list(status = "migrated", backup_path = backup_path,
                 restore_command = restore_command, recorded_at = recorded_at))
}
