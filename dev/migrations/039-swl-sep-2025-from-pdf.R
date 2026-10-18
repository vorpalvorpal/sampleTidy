# Operator-run migration: enter the Blaxland standing water levels of the
# September 2025 quarterly (ACIRL report 2400-7453-09, ALS ES2528155, sampled
# 2025-09-09 Sydney) from ACIRL's PDF, because no workbook for that report was
# ever received. Marker 1039. Requires 1038. Authority: Robin, 2026-10-18
# ("enter Sep 2025 SWL from the PDF").
#
# ---- SOURCE --------------------------------------------------------------------
# "2400-7453-09 September 2025 Quarterly Blaxland WMF.pdf" (rlang::hash_file
# 20ddfc1bdfda152b87cabcda5fa10fc5 = asset 4bfcb924 under ES2528155, the file
# 038 entered the Aug 2025 dust from). Page 2, row "Standing Water Level",
# units "m", Date of Sample 9/09/2025 (checked on the rendered page, not only
# the text layer):
#   B.MW02 4.0   B.MW08 2.8   B.MW09 3.1   B.MW04 10.4   B.MW07 4.6   B.MW11 0.9
#   B.MW06 blank ("Grass too long coud not find" - not sampled)
#   B.CW02 blank ("Dry"), B.L01 blank; page 3 (leachate/surface) all "_".
# Those six are every SWL the PDF reports for the visit.
#
# ---- CONVENTION (proved, not assumed) ------------------------------------------
# The workbook-imported ACIRL SWL rows store the printed number unchanged:
# metres, positive, depth to water (B.MW04 11.04 Dec 2025, 12.96 Mar 2026,
# 11.90 Jun 2026 - not mAHD, which would be ~hundreds of m). The Dec 2025
# quarterly has BOTH a PDF (asset d50c0e4c) and a workbook (asset 6461237a,
# imported as ES2538342): the PDF's "Standing Water Level  m" row prints
# 5.12 / 2.71 / 2.8 / 11.04 / 2.47 / 2.11 for MW02/08/09/04/07/11 and the DB
# holds exactly 5.12 / 2.71 / 2.80 / 11.04 / 2.47 / 2.11. So PDF value = DB
# value, same sign, same unit; no conversion. The one caveat: the Sep 2025 PDF
# prints this row to one decimal place ("4.0", where Dec's General format
# printed "2.8"), so the workbook cell may carry a second decimal the PDF
# rounds away. The value entered is the printed one.
#
# ---- WHAT IS WRITTEN ------------------------------------------------------------
# Six analysis rows, one per bore, each on the EXISTING legacy-loaded ACIRL
# field sample for that bore and visit (ES2528155001..006: same feature, Sydney
# day 2025-09-09, project ES2528155, organisation ACIRL; asserted to be the
# only sample of that feature on that day in any project). Shaped as the
# workbook-imported SWL rows (e.g. 4d4ea4d7, B.MW04 Dec 2025) and the legacy
# Aug 2025 ones (263ae47d): uuid_lab = 68484c79 (ACIRL "Standing Water Level",
# method field, analyte "Standing water level", m), value as printed,
# quantified TRUE, value_chr/rl_low/rl_high/purpose NULL. The one deliberate
# difference, for provenance: analysis.comments = "Entered by migration 039
# from ACIRL PDF 2400-7453-09 (no workbook received)". 038 put its provenance
# on sample.comments because it created the samples; here the samples are
# pre-existing legacy rows whose comments carry the field observation
# ("Clear."), so the provenance goes on the new analyses themselves (the
# column exists and is NULL on every other SWL row), and the samples are not
# touched. change_log: one insert row per analysis (db_append), actor
# "039-swl-sep-2025-from-pdf", source_hash = the PDF's hash.
#
# Nothing existing is overwritten: precondition = NO standing-water-level
# analysis (any lab_method of that analyte) on any sample of these six bores on
# Sydney day 2025-09-09. If one appears, 039 refuses rather than skip.
#
# Preconditions: marker 1038; ES2528155 under EPL quarterly; the PDF asset;
# the lab_method as named; each of the six samples exists as planned and is the
# only sample of its bore on that Sydney day; no SWL there; none of the planned
# uuids exists. analysis has no unique index, so nothing else to prove.
#
# Writes: one transaction (6 analysis inserts, 6 change_log rows, marker
# 1039), counts and checksums of everything else checked inside it. Nothing
# pre-existing changes, so there is no BACKUP CSV; rows created:
# 039-swl-sep-2025-from-pdf-INSERTED-analysis.csv. Plus the verified
# whole-file backup in snapshot_dir.
#
# Idempotent: marker present -> re-verify, no-op.
#
#   devtools::load_all(".")
#   env <- new.env()
#   sys.source("dev/migrations/039-swl-sep-2025-from-pdf.R", envir = env)
#   env$mig039_run(db = st_config("live_db"),
#                  snapshot_dir = st_config("snapshot_dir"), dry_run = TRUE)

.mig039_marker_version <- 1039L
.mig039_requires <- 1038L
.mig039_name <- "039-swl-sep-2025-from-pdf"
.mig039_actor <- .mig039_name

.mig039_comment <- "Entered by migration 039 from ACIRL PDF 2400-7453-09 (no workbook received)"
.mig039_pdf_hash <- "20ddfc1bdfda152b87cabcda5fa10fc5"
.mig039_pdf_asset <- "4bfcb924-7f94-4ac3-bded-32fb00088ea2"
.mig039_pdf_name <- "2400-7453-09 September 2025 Quarterly Blaxland WMF.pdf"
.mig039_proj <- list(uuid = "5075e630-aed0-429c-b05d-4df81ea9fda3", name = "ES2528155",
                     parent = "a8ce3eff-e293-401c-8225-6d0c57d06993", parent_name = "EPL quarterly")
.mig039_report <- "2400-7453-09"
.mig039_day <- "2025-09-09"
.mig039_lab <- list(uuid = "68484c79-cb5f-46a4-bb30-ecc64bea163e", name = "Standing Water Level",
                    method = "field", organisation = "ACIRL")
.mig039_analyte <- list(uuid = "e4a4002c-ea26-4517-aca6-2706f609343d", name = "Standing water level", units = "m")

# One row per bore: planned analysis uuid, existing sample, its alias, PDF value.
.mig039_plan <- utils::read.csv(text = "uuid,bore,sample,alias,value
df12aec8-c0d3-486d-a35e-4d9fc1cbbeaf,B.MW02,ES2528155001,04ac10f3-d1f4-4b2e-9e3e-3e46d2437305,4.0
be1beeb1-3547-4c1c-9dfe-70f5a47e85bb,B.MW08,ES2528155002,10bcbd5f-163f-4ca9-b459-5ae58a93fe98,2.8
b2e0ddb7-9d9f-4d94-a60b-35b81cc12a26,B.MW09,ES2528155003,3938bc8c-db2b-4fb9-9c53-ad29e3b35d12,3.1
0c702670-c296-4ac7-9128-da6898c6087f,B.MW04,ES2528155004,99d7b84c-c8e3-4ec7-b304-36e523e9f782,10.4
66e5d679-46c6-4f43-855f-de288d74023d,B.MW07,ES2528155005,c7fe0c38-ae5f-4e74-93e4-44d5e06d0e52,4.6
5ee183d4-196e-48c8-be2f-9634fd6f0bf6,B.MW11,ES2528155006,4296f2a2-cb43-4f4c-8386-a3bd7d45175d,0.9",
  stringsAsFactors = FALSE, colClasses = "character")

.mig039_default <- function(x, default) if (is.null(x)) default else x
.mig039_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = list(...))[[1]][[1]])
.mig039_fail <- function(msg) cli::cli_abort(paste0(.mig039_name, ": ", msg), class = "sampletidy_error")
.mig039_in <- function(x) paste0("('", paste(x, collapse = "','"), "')")
.mig039_syd <- function(col) sprintf("(%s AT TIME ZONE 'UTC' AT TIME ZONE 'Australia/Sydney')::DATE", col)

.mig039_counts <- function(con) {
  tabs <- c("feature", "feature_alias", "analyte", "lab_method", "analysis", "sample", "project", "asset",
            "review_queue", "review_queue_candidate", "ingest_file", "change_log", "schema_version")
  stats::setNames(lapply(tabs, function(t) .mig039_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
}

# Every sample of the six bores on the Sydney day, any project, with its SWL count.
.mig039_at_bores <- function(con) {
  DBI::dbGetQuery(con, sprintf("
    SELECT s.uuid, f.name AS bore, s.uuid_feature_alias, s.uuid_project, s.organisation,
           (SELECT COUNT(*) FROM analysis a JOIN lab_method lm ON lm.uuid = a.uuid_lab
             WHERE a.uuid_sample = s.uuid AND lm.uuid_analyte = '%s') AS n_swl
    FROM \"sample\" s
    JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
    JOIN feature f ON f.uuid = fa.uuid_feature
    WHERE f.name IN %s AND %s = DATE '%s'
    ORDER BY f.name, s.uuid",
    .mig039_analyte$uuid, .mig039_in(.mig039_plan$bore), .mig039_syd("COALESCE(s.datetime, s.date)"), .mig039_day))
}

# The rows exactly as they will be inserted.
.mig039_analysis_rows <- function() {
  n <- nrow(.mig039_plan)
  data.frame(
    uuid = .mig039_plan$uuid, uuid_sample = .mig039_plan$sample, uuid_lab = rep(.mig039_lab$uuid, n),
    value = as.numeric(.mig039_plan$value), value_chr = rep(NA_character_, n), quantified = rep(TRUE, n),
    rl_low = rep(NA_real_, n), rl_high = rep(NA_real_, n), purpose = rep(NA_character_, n),
    comments = rep(.mig039_comment, n), stringsAsFactors = FALSE)
}

.mig039_check_preconditions <- function(con) {
  if (.mig039_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig039_requires) == 0L) {
    .mig039_fail(sprintf("marker %d (038) is required first.", .mig039_requires))
  }
  p <- DBI::dbGetQuery(con, "SELECT c.name, c.type, c.uuid_parent, p.name AS parent_name FROM project c
    LEFT JOIN project p ON p.uuid = c.uuid_parent WHERE c.uuid = ?", params = list(.mig039_proj$uuid))
  if (nrow(p) != 1L || !identical(p$name, .mig039_proj$name) || !identical(p$type, "Work order") ||
      !identical(p$uuid_parent, .mig039_proj$parent) || !identical(p$parent_name, .mig039_proj$parent_name)) {
    .mig039_fail("ES2528155 is missing, not a Work order, or no longer directly under EPL quarterly.")
  }
  as <- DBI::dbGetQuery(con, "SELECT uuid_project, filename, hash FROM asset WHERE uuid = ?", params = list(.mig039_pdf_asset))
  if (nrow(as) != 1L || !identical(as$uuid_project, .mig039_proj$uuid) || !identical(as$hash, .mig039_pdf_hash) ||
      !identical(as$filename, .mig039_pdf_name)) {
    .mig039_fail("the 2400-7453-09 PDF asset is missing or changed.")
  }
  lm <- DBI::dbGetQuery(con, "SELECT lm.name, lm.method, lm.organisation, an.uuid AS an_uuid, an.name AS analyte, an.units
    FROM lab_method lm JOIN analyte an ON an.uuid = lm.uuid_analyte WHERE lm.uuid = ?", params = list(.mig039_lab$uuid))
  if (nrow(lm) != 1L || !identical(lm$name, .mig039_lab$name) || !identical(lm$method, .mig039_lab$method) ||
      !identical(lm$organisation, .mig039_lab$organisation) || !identical(lm$an_uuid, .mig039_analyte$uuid) ||
      !identical(lm$analyte, .mig039_analyte$name) || !identical(lm$units, .mig039_analyte$units)) {
    .mig039_fail("the ACIRL Standing Water Level lab_method is missing or not the planned one.")
  }
  s <- DBI::dbGetQuery(con, sprintf("SELECT s.uuid, s.uuid_feature_alias, s.uuid_project, s.organisation, f.name AS bore
    FROM \"sample\" s JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias JOIN feature f ON f.uuid = fa.uuid_feature
    WHERE s.uuid IN %s", .mig039_in(.mig039_plan$sample)))
  s <- s[match(.mig039_plan$sample, s$uuid), ]
  if (anyNA(s$uuid) || !identical(s$uuid_feature_alias, .mig039_plan$alias) || !identical(s$bore, .mig039_plan$bore) ||
      !all(s$uuid_project == .mig039_proj$uuid) || !all(s$organisation == "ACIRL")) {
    .mig039_fail("a planned ES2528155 bore sample is missing or not the planned one.")
  }
  g <- .mig039_at_bores(con)
  if (nrow(g) != nrow(.mig039_plan) || !setequal(g$uuid, .mig039_plan$sample)) {
    .mig039_fail(sprintf("the six bores on %s are not exactly the six planned samples: %s.",
                         .mig039_day, paste(g$bore, g$uuid, collapse = ", ")))
  }
  if (any(g$n_swl != 0L)) {
    .mig039_fail(sprintf("a standing water level already exists on %s at %s - nothing may be overwritten.",
                         .mig039_day, paste(g$bore[g$n_swl != 0L], collapse = ", ")))
  }
  if (.mig039_scalar(con, sprintf("SELECT COUNT(*) FROM analysis WHERE uuid IN %s", .mig039_in(.mig039_plan$uuid))) != 0L) {
    .mig039_fail("a planned uuid already exists.")
  }
  invisible(TRUE)
}

.mig039_rows_as_text <- function(df) {
  out <- df
  for (f in names(out)) out[[f]] <- as.character(out[[f]])
  out <- out[order(out$uuid), , drop = FALSE]
  rownames(out) <- NULL
  out
}

.mig039_done_problem <- function(con) {
  if (.mig039_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig039_marker_version) != 1L) return("marker 1039 missing")
  a <- DBI::dbGetQuery(con, sprintf("SELECT * FROM analysis WHERE uuid IN %s", .mig039_in(.mig039_plan$uuid)))
  if (!identical(.mig039_rows_as_text(a), .mig039_rows_as_text(.mig039_analysis_rows()))) return("the 6 analyses are missing or differ from the plan")
  g <- .mig039_at_bores(con)
  if (nrow(g) != nrow(.mig039_plan) || !setequal(g$uuid, .mig039_plan$sample) || any(g$n_swl != 1L)) {
    return("the six bores on 2025-09-09 are not exactly the six samples with one SWL each")
  }
  cl <- .mig039_scalar(con, "SELECT COUNT(*) FROM change_log WHERE actor = ? AND action = 'insert' AND tbl = 'analysis' AND source_hash = ?",
                       .mig039_actor, .mig039_pdf_hash)
  if (cl != 6L) return(sprintf("%d change_log insert rows under 039, expected 6", cl))
  if (.mig039_scalar(con, "SELECT COUNT(*) FROM change_log WHERE actor = ?", .mig039_actor) != 6L) return("change_log has rows under 039 other than the 6 inserts")
  NULL
}

.mig039_verify <- function(con) {
  p <- .mig039_done_problem(con)
  if (!is.null(p)) cli::cli_abort(paste0("039 verify failed: ", p), class = "sampletidy_error")
  invisible(TRUE)
}

mig039_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- .mig039_default(.now, Sys.time())
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig039_name, ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig039_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig039_counts(verify_con))) {
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  }
  dest
}

.mig039_write_csv <- function(df, path) {
  out <- df
  for (f in names(out)) if (inherits(out[[f]], c("POSIXct", "Date"))) out[[f]] <- .st_changelog_str(out[[f]])
  utils::write.csv(out, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8", colClasses = "character")
  if (nrow(back) != nrow(df) || !identical(back$uuid, as.character(out$uuid))) {
    cli::cli_abort("039: CSV {basename(path)} did not round-trip.", class = "sampletidy_error")
  }
}

# Checksums of everything 039 may not touch.
.mig039_checksums <- function(con) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  tabs <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  whole <- setdiff(tabs, c("analysis", "change_log", "schema_version"))
  out <- lapply(whole, function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- whole
  out$analysis_rest <- q(sprintf("SELECT * FROM analysis WHERE uuid NOT IN %s ORDER BY uuid", .mig039_in(.mig039_plan$uuid)))
  out$change_log_rest <- q(sprintf("SELECT * FROM change_log WHERE actor <> '%s' ORDER BY ALL", .mig039_actor))
  out$schema_version_rest <- q(sprintf("SELECT * FROM schema_version WHERE version <> %d ORDER BY ALL", .mig039_marker_version))
  out$views <- q("SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
  out$indexes <- q("SELECT index_name, sql FROM duckdb_indexes() ORDER BY index_name")
  out
}

.mig039_write <- function(con, recorded_at, logf) {
  .mig039_check_preconditions(con)   # re-read under the write lock
  counts_before <- .mig039_counts(con)
  sums_before <- .mig039_checksums(con)
  reason <- sprintf("039: Blaxland standing water levels of %s (ALS %s, sampled %s) entered from ACIRL PDF %s (no workbook received), on the existing ACIRL field samples",
                    .mig039_report, .mig039_proj$name, .mig039_day, .mig039_report)
  db_transaction(con, function(con) {
    db_append(con, "analysis", .mig039_analysis_rows(), actor = .mig039_actor, reason = reason, source_hash = .mig039_pdf_hash)
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig039_marker_version, recorded_at))
    want <- counts_before
    want$analysis <- want$analysis + 6L
    want$change_log <- want$change_log + 6L
    want$schema_version <- want$schema_version + 1L
    got <- .mig039_counts(con)
    if (!identical(got, want)) {
      .mig039_fail(sprintf("counts are not before + 6 analyses + 6 change_log + 1 marker: %s",
                           paste(names(got), unlist(got), unlist(want), sep = ":", collapse = ", ")))
    }
    if (!identical(sums_before, .mig039_checksums(con))) .mig039_fail("the write changed something outside the 6 new rows.")
    .mig039_verify(con)
    NULL
  })
  logf("Inserted 6 SWL analyses on the ES2528155 bore samples, marker %d (committed).", .mig039_marker_version)
  .mig039_verify(con)
}

mig039_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(
    DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                    params = list(.mig039_marker_version)),
    finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch(.mig039_verify(check_con), finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("039 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  tryCatch(.mig039_check_preconditions(pre_con), finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  logf("Plan: insert SWL %s on the ES2528155 samples of %s (6 analyses) from ACIRL PDF %s.",
       paste(.mig039_plan$value, collapse = "/"), paste(.mig039_plan$bore, collapse = "/"), .mig039_report)
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition passed. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = NA)))
  }

  backup_path <- mig039_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- .mig039_default(.now, Sys.time())

  with_db_write(function(con) .mig039_write(con, recorded_at, logf), db = db)

  ins_con <- st_connect(db, read_only = TRUE)
  tryCatch({
    .mig039_write_csv(DBI::dbGetQuery(ins_con, sprintf("SELECT * FROM analysis WHERE uuid IN %s ORDER BY uuid", .mig039_in(.mig039_plan$uuid))),
                      file.path(csv_dir, sprintf("%s-INSERTED-analysis.csv", .mig039_name)))
  }, finally = DBI::dbDisconnect(ins_con, shutdown = TRUE))

  logf("%s migrated successfully (marker %d).", .mig039_name, .mig039_marker_version)
  invisible(list(status = "migrated", backup_path = backup_path,
                 restore_command = restore_command, recorded_at = recorded_at))
}
