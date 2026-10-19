# Operator-run migration: let the ACIRL workbook win over the PDF's rounded values
# for the Blaxland September 2025 quarterly (ACIRL report 2400-7453-09, ALS
# ES2528155, visit 2025-09-09). Marker 1043. Requires 1041. Does NOT require 1042
# (042 is independent: it touches other dust rows and no review item); 043 and 042
# may be applied in either order.
#
# Authority: Robin's standing ruling "workbook wins" (DECISIONS-FOR-ROBIN.md, the
# 029 EC entry; applied the same way in 029 and 036).
#
# THE SITUATION. Migration 038 (dust) and 039 (standing water levels) entered
# these 8 values from the ACIRL PDF, which prints them rounded to one decimal
# place. The workbook `2400-7453-09 September 2025 Quarterly Blaxland WMF.xls`
# (hash 81a092027df1cc7976f5c932eaea7e20) was then imported and carries the
# precise values, so the importer opened 8 open value_conflict / measurement
# review items (created 2026-10-19 01:13 UTC), each naming the stored analysis
# as uuid_existing and carrying value_existing / value_incoming in its payload.
# The incoming row was not inserted (a conflict adds nothing).
#
#   feature  analyte                existing -> workbook
#   B.D07    dust-total                 0.2  -> 0.21
#   B.D08    dust-total                 0.6  -> 0.57
#   B.MW02   Standing water level       4.0  -> 3.96
#   B.MW04   Standing water level      10.4  -> 10.41
#   B.MW07   Standing water level       4.6  -> 4.58
#   B.MW08   Standing water level       2.8  -> 2.84
#   B.MW09   Standing water level       3.1  -> 3.05
#   B.MW11   Standing water level       0.9  -> 0.93
#
# ROUNDING CHECK (a precondition, not just a claim). Each workbook value must
# round, half-up at the PDF's one printed decimal, to the stored value
# (|incoming - existing| <= 0.05). All 8 do; a pair that does not is a real
# disagreement, not a rounding difference, and this migration refuses to touch it.
#
# WHAT CHANGES, per pair, in one transaction:
#   - analysis.value: existing -> workbook value (db_update + change_log; the other
#     columns - value_chr, quantified, rl, purpose, comments - stay: value_chr and
#     rl are NULL, quantified TRUE, so nothing needs keeping consistent). The
#     SWL comments "Entered by migration 039 ..." are kept as history; the
#     change_log row records the supersession.
#   - the review item is resolved (status resolved, resolution "superseded: ...",
#     resolved_by "R. Shannon", resolved_at now), via db_update.
# change_log source_hash = the workbook's hash on the analysis rows.
# A re-import of the workbook then finds value == value and raises nothing.
#
# Preconditions refuse unless every item is exactly as above (open, subkind,
# uuid_existing, payload values, source_hash) and every analysis holds the
# stored value, so a partly-changed database stops with nothing written.
# Backups: whole-file snapshot in `snapshot_dir`, plus
# `043-sep-2025-workbook-supersedes-pdf-BACKUP-{analysis,review_queue}.csv`.
# Idempotent: marker present -> re-verify, no-op.
#
#   devtools::load_all(".")
#   env <- new.env()
#   sys.source("dev/migrations/043-sep-2025-workbook-supersedes-pdf.R", envir = env)
#   env$mig043_run(db = st_config("live_db"),
#                  snapshot_dir = st_config("snapshot_dir"), dry_run = TRUE)

.mig043_marker_version <- 1043L
.mig043_requires <- 1041L
.mig043_name <- "043-sep-2025-workbook-supersedes-pdf"
.mig043_actor <- .mig043_name
.mig043_by <- "R. Shannon"
.mig043_hash <- "81a092027df1cc7976f5c932eaea7e20"

.mig043_plan <- data.frame(
  review = c("de39c901-a6b9-4009-aeb1-71508d357fcd", "b302cdda-656c-4a39-b7f9-4ce7ac96fcec",
             "c2b9a155-93f3-49dc-a48c-acf306b305ce", "1f35032a-3810-4643-9fac-3a217b03ae39",
             "6b8b434a-acc2-4fa1-9980-1ed626f4130a", "06273a37-d70b-4de9-9969-04dbe064dde7",
             "ace2a985-abd5-46bd-bd96-76be024276ce", "9ba2c720-a348-48c9-aab1-910a92fa9590"),
  analysis = c("9a4087b8-d256-4bb5-8016-a1756ad6d004", "f412c2be-79fc-4ea9-beeb-74167c06b441",
               "df12aec8-c0d3-486d-a35e-4d9fc1cbbeaf", "be1beeb1-3547-4c1c-9dfe-70f5a47e85bb",
               "b2e0ddb7-9d9f-4d94-a60b-35b81cc12a26", "0c702670-c296-4ac7-9128-da6898c6087f",
               "66e5d679-46c6-4f43-855f-de288d74023d", "5ee183d4-196e-48c8-be2f-9634fd6f0bf6"),
  feature = c("B.D07", "B.D08", "B.MW02", "B.MW08", "B.MW09", "B.MW04", "B.MW07", "B.MW11"),
  analyte = c("dust-total", "dust-total", rep("Standing water level", 6)),
  old = c(0.2, 0.6, 4.0, 2.8, 3.1, 10.4, 4.6, 0.9),
  new = c(0.21, 0.57, 3.96, 2.84, 3.05, 10.41, 4.58, 0.93),
  stringsAsFactors = FALSE)

.mig043_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = list(...))[[1]][[1]])
.mig043_fail <- function(msg) cli::cli_abort(paste0(.mig043_name, ": ", msg), class = "sampletidy_error")
.mig043_num_eq <- function(a, b) !is.na(a) && !is.na(b) && abs(a - b) < 1e-9
.mig043_inlist <- function(x) paste0("(", paste0("'", x, "'", collapse = ", "), ")")
.mig043_resolution <- function(i) {
  p <- .mig043_plan[i, ]
  sprintf(paste0("superseded: the ACIRL workbook value wins over the rounded PDF value (Robin's standing 'workbook wins' ruling, ",
                 "as 029/036); %s %s %s -> %s, workbook 2400-7453-09 Sep 2025 (hash %s); migration 043"),
          p$feature, p$analyte, format(p$old), format(p$new), .mig043_hash)
}
.mig043_reason <- function(i) {
  p <- .mig043_plan[i, ]
  sprintf("043 (workbook wins): %s %s 2025-09 PDF value %s is the rounding of the workbook's %s; value %s -> %s",
          p$feature, p$analyte, format(p$old), format(p$new), format(p$old), format(p$new))
}

# PDF's one-decimal rounding (half-up with float tolerance) of the workbook value.
.mig043_rounds_to <- function(new, old) abs(new - old) <= 0.05 + 1e-9

.mig043_counts <- function(con) {
  tabs <- c("analysis", "sample", "feature", "feature_alias", "analyte", "lab_method", "project",
            "review_queue", "change_log", "schema_version")
  stats::setNames(lapply(tabs, function(t) .mig043_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
}

.mig043_checksum <- function(con) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  tabs <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  touched <- c("analysis", "review_queue", "change_log", "schema_version")
  out <- lapply(setdiff(tabs, touched), function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- setdiff(tabs, touched)
  a <- .mig043_inlist(.mig043_plan$analysis); r <- .mig043_inlist(.mig043_plan$review)
  out$analysis_rest <- q(sprintf("SELECT * FROM analysis WHERE uuid NOT IN %s ORDER BY uuid", a))
  out$analysis_fixed <- q(sprintf("SELECT * EXCLUDE (value) FROM analysis WHERE uuid IN %s ORDER BY uuid", a))
  out$review_rest <- q(sprintf("SELECT * FROM review_queue WHERE uuid NOT IN %s ORDER BY uuid", r))
  out$review_fixed <- q(sprintf("SELECT * EXCLUDE (status, resolution, resolved_by, resolved_at) FROM review_queue WHERE uuid IN %s ORDER BY uuid", r))
  out$change_log_rest <- q(sprintf("SELECT * FROM change_log WHERE actor <> '%s' ORDER BY ALL", .mig043_actor))
  out$schema_version_rest <- q(sprintf("SELECT * FROM schema_version WHERE version <> %d ORDER BY ALL", .mig043_marker_version))
  out$views <- q("SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
  out$indexes <- q("SELECT index_name, sql FROM duckdb_indexes() ORDER BY index_name")
  out
}

.mig043_state <- function(con) {
  DBI::dbGetQuery(con, sprintf(
    "SELECT r.uuid AS review, r.status, r.kind, r.subkind, r.source_hash, r.uuid_existing, r.payload,
            r.resolution, r.resolved_by, r.resolved_at,
            a.uuid AS analysis, a.value, a.value_chr, a.quantified, a.rl_low, a.rl_high, a.purpose,
            f.name AS feature, an.name AS analyte
     FROM review_queue r
     LEFT JOIN analysis a ON a.uuid = r.uuid_existing
     LEFT JOIN \"sample\" s ON s.uuid = a.uuid_sample
     LEFT JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
     LEFT JOIN feature f ON f.uuid = fa.uuid_feature
     LEFT JOIN lab_method lm ON lm.uuid = a.uuid_lab
     LEFT JOIN analyte an ON an.uuid = lm.uuid_analyte
     WHERE r.uuid IN %s", .mig043_inlist(.mig043_plan$review)))
}

# NULL if everything is as planned for `phase` ("before": open, old value; "after":
# resolved, new value), else the first problem.
.mig043_problem <- function(con, phase) {
  st <- .mig043_state(con)
  if (nrow(st) != nrow(.mig043_plan)) return(sprintf("%d of %d planned review items exist", nrow(st), nrow(.mig043_plan)))
  for (i in seq_len(nrow(.mig043_plan))) {
    p <- .mig043_plan[i, ]
    r <- st[st$review == p$review, , drop = FALSE]
    if (nrow(r) != 1L) return(sprintf("review %s missing", p$review))
    if (r$kind != "value_conflict" || !identical(r$subkind, "measurement") || !identical(r$source_hash, .mig043_hash) ||
        !identical(r$uuid_existing, p$analysis))
      return(sprintf("review %s (%s) is not the planned value_conflict/measurement item from the workbook", p$review, p$feature))
    pl <- jsonlite::fromJSON(r$payload)
    if (!.mig043_num_eq(pl$value_existing, p$old) || !.mig043_num_eq(pl$value_incoming, p$new))
      return(sprintf("review %s (%s) payload values %s -> %s are not the planned %s -> %s", p$review, p$feature,
                     format(pl$value_existing), format(pl$value_incoming), format(p$old), format(p$new)))
    if (!isTRUE(.mig043_rounds_to(p$new, p$old)))
      return(sprintf("%s: %s does not round to %s at the PDF's precision - not a rounding difference", p$feature, format(p$new), format(p$old)))
    if (!identical(r$feature, p$feature) || !identical(r$analyte, p$analyte))
      return(sprintf("analysis %s is %s/%s, expected %s/%s", p$analysis, r$feature, r$analyte, p$feature, p$analyte))
    if (!is.na(r$value_chr) || !isTRUE(r$quantified) || !is.na(r$rl_low) || !is.na(r$rl_high))
      return(sprintf("analysis %s (%s) carries a value_chr / rl / not-quantified this migration did not plan for", p$analysis, p$feature))
    if (identical(phase, "before")) {
      if (r$status != "open" || !is.na(r$resolution)) return(sprintf("review %s (%s) is not open", p$review, p$feature))
      if (!.mig043_num_eq(r$value, p$old)) return(sprintf("%s value is %s, expected %s", p$feature, format(r$value), format(p$old)))
    } else {
      if (r$status != "resolved" || !identical(r$resolved_by, .mig043_by) || is.na(r$resolved_at) ||
          !identical(r$resolution, .mig043_resolution(i)))
        return(sprintf("review %s (%s) is not resolved as planned", p$review, p$feature))
      if (!.mig043_num_eq(r$value, p$new)) return(sprintf("%s value is %s, expected %s", p$feature, format(r$value), format(p$new)))
    }
  }
  NULL
}

.mig043_done_problem <- function(con) {
  p <- .mig043_problem(con, "after")
  if (!is.null(p)) return(p)
  cl <- DBI::dbGetQuery(con, "SELECT tbl, action, field, uuid_row, new, source_hash FROM change_log WHERE actor = ?",
                        params = list(.mig043_actor))
  a <- cl[cl$tbl == "analysis", , drop = FALSE]
  if (nrow(a) != nrow(.mig043_plan) || any(a$action != "update") || any(a$field != "value") ||
      !setequal(a$uuid_row, .mig043_plan$analysis) || any(a$source_hash != .mig043_hash, na.rm = FALSE))
    return("043 analysis change_log is not one value update per planned analysis")
  rv <- cl[cl$tbl == "review_queue", , drop = FALSE]
  if (nrow(rv) != 4L * nrow(.mig043_plan) || !setequal(rv$uuid_row, .mig043_plan$review) ||
      !all(table(rv$field)[c("status", "resolution", "resolved_by", "resolved_at")] == nrow(.mig043_plan)))
    return("043 review_queue change_log is not status/resolution/resolved_by/resolved_at per planned item")
  if (nrow(cl) != nrow(a) + nrow(rv)) return("043 change_log names another table")
  NULL
}

.mig043_verify <- function(con) {
  p <- .mig043_done_problem(con)
  if (!is.null(p)) cli::cli_abort(paste0("043 verify failed: ", p), class = "sampletidy_error")
  invisible(TRUE)
}

.mig043_check_preconditions <- function(con) {
  if (.mig043_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig043_requires) == 0L)
    .mig043_fail(sprintf("marker %d (041) is required first.", .mig043_requires))
  p <- .mig043_problem(con, "before")
  if (!is.null(p)) .mig043_fail(sprintf("%s. Nothing written.", p))
  # No other open item may cite these analyses.
  n <- .mig043_scalar(con, sprintf("SELECT COUNT(*) FROM review_queue WHERE status = 'open' AND uuid_existing IN %s AND uuid NOT IN %s",
                                   .mig043_inlist(.mig043_plan$analysis), .mig043_inlist(.mig043_plan$review)))
  if (n) .mig043_fail("another open review item cites one of the planned analyses. Nothing written.")
  invisible(TRUE)
}

mig043_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- if (is.null(.now)) Sys.time() else .now
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig043_name, ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig043_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig043_counts(verify_con)))
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  dest
}

.mig043_write_csv <- function(df, path, key) {
  utils::write.csv(df, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8", colClasses = "character")
  if (nrow(back) != nrow(df) || !identical(back[[key]], as.character(df[[key]])))
    cli::cli_abort("043: CSV {basename(path)} did not round-trip.", class = "sampletidy_error")
}

.mig043_apply <- function(con, recorded_at, logf) {
  sums_before <- .mig043_checksum(con)
  want <- .mig043_counts(con)
  want$schema_version <- want$schema_version + 1L
  want$change_log <- want$change_log + 5L * nrow(.mig043_plan)
  db_transaction(con, function(con) {
    at <- Sys.time()
    for (i in seq_len(nrow(.mig043_plan))) {
      p <- .mig043_plan[i, ]
      db_update(con, "analysis", uuid = p$analysis, changes = list(value = p$new),
                actor = .mig043_actor, reason = .mig043_reason(i), source_hash = .mig043_hash)
      db_update(con, "review_queue", uuid = p$review,
                changes = list(status = "resolved", resolution = .mig043_resolution(i),
                               resolved_by = .mig043_by, resolved_at = at),
                actor = .mig043_actor, reason = sprintf("043: workbook wins; uuid=%s", p$review))
    }
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig043_marker_version, recorded_at))
    .mig043_verify(con)
    got <- .mig043_counts(con)
    if (!identical(got, want))
      cli::cli_abort(sprintf("043 verify failed: counts are %s, expected %s.",
                             paste(names(got), unlist(got), sep = "=", collapse = " "),
                             paste(names(want), unlist(want), sep = "=", collapse = " ")), class = "sampletidy_error")
    if (!identical(sums_before, .mig043_checksum(con)))
      cli::cli_abort("043 verify failed: something outside the planned rows moved.", class = "sampletidy_error")
    NULL
  })
  logf("Updated %d analysis values, resolved %d review items, marker %d (committed).",
       nrow(.mig043_plan), nrow(.mig043_plan), .mig043_marker_version)
  invisible(NULL)
}

mig043_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(
    DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                    params = list(.mig043_marker_version)),
    finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch(.mig043_verify(check_con), finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("043 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  tryCatch(.mig043_check_preconditions(pre_con), finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  for (i in seq_len(nrow(.mig043_plan))) {
    p <- .mig043_plan[i, ]
    logf("Plan: %s %s %s -> %s (analysis %s, review %s).", p$feature, p$analyte, format(p$old), format(p$new), p$analysis, p$review)
  }
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition passed (all 8 pairs are rounding differences). No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = NA)))
  }

  bk_con <- st_connect(db, read_only = TRUE)
  tryCatch({
    .mig043_write_csv(DBI::dbGetQuery(bk_con, sprintf("SELECT * FROM analysis WHERE uuid IN %s ORDER BY uuid", .mig043_inlist(.mig043_plan$analysis))),
                      file.path(csv_dir, sprintf("%s-BACKUP-analysis.csv", .mig043_name)), "uuid")
    .mig043_write_csv(DBI::dbGetQuery(bk_con, sprintf("SELECT * FROM review_queue WHERE uuid IN %s ORDER BY uuid", .mig043_inlist(.mig043_plan$review))),
                      file.path(csv_dir, sprintf("%s-BACKUP-review_queue.csv", .mig043_name)), "uuid")
  }, finally = DBI::dbDisconnect(bk_con, shutdown = TRUE))
  logf("Row backups written to %s", csv_dir)
  backup_path <- mig043_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- if (is.null(.now)) Sys.time() else .now

  with_db_write(function(con) {
    .mig043_check_preconditions(con)   # re-read under the write lock
    .mig043_apply(con, recorded_at, logf)
  }, db = db)

  logf("%s migrated successfully (marker %d).", .mig043_name, .mig043_marker_version)
  invisible(list(status = "migrated", backup_path = backup_path,
                 restore_command = restore_command, recorded_at = recorded_at))
}
