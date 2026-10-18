# Operator-run migration: enter the Blaxland dust block for exposure August
# 2025 (exposed 2025-08-01, collected 2025-09-01, 31 days) from ACIRL's PDF
# report 2400-7453-09, because no workbook for that report was ever received.
# Marker 1038. Requires 1037. Authority: Robin, 2026-10-18 ("enter Sep 2025
# dust from the PDF").
#
# ---- SOURCE --------------------------------------------------------------------
# "2400-7453-09 September 2025 Quarterly Blaxland WMF.pdf" (rlang::hash_file
# 20ddfc1bdfda152b87cabcda5fa10fc5 - the same file is already asset 4bfcb924
# under ES2528155). Page 9 "DUST DEPOSITION RESULTS (g/m2/month)", Month
# "August", Exposure Days 31:
#   B.D07  DG #1  INSOLUBLE SOLIDS 0.2  *COMBUSTIBLE MATTER <0.1  INCOMBUSTIBLE MATTER 0.2
#   B.D08  DG #2  INSOLUBLE SOLIDS 0.6  *COMBUSTIBLE MATTER <0.1  INCOMBUSTIBLE MATTER 0.6
# Page 10 "DEPOSITIONAL DUST GAUGE OBSERVATIONS": both gauges exposed
# 1/08/2025, collected 1/09/2025, 31 days, "Clear, insects, organic matter,
# fine brown dusts, coarse black dust." Page 2: ALS Sydney Report No.
# ES2528155; page 1: SAMPLED BY "B.Collins & B. Appleyard".
#
# ---- WHAT IS WRITTEN: what the workbook's import would have produced ---------
# Two sample rows and eight analysis rows, shaped exactly as the released
# 2400-7538-07 dust in 037 (e.g. sample d9ba5932):
#   sample    uuid_feature_alias = the B.D07 / B.D08 self alias;
#             date = 2025-09-01 00:00:00, date_start = 2025-08-01 00:00:00
#             (commit.R's naive-midnight form); datetime = date and
#             datetime_start = date_start (021's invariant);
#             organisation "ACIRL"; person "B.Collins" (the adapter keeps
#             SAMPLED BY up to the "&", squished); purpose NULL.
#   analysis  the ACIRL dust lab_methods INSOLUBLE SOLIDS (dust-total),
#             *COMBUSTIBLE MATTER (dust-combustible), INCOMBUSTIBLE MATTER
#             (dust-incombustible), each value/quantified TRUE; "<0.1" stored
#             as value 0.1, quantified FALSE (as 037's 02c08995); plus
#             ANALYSIS OBSERVATIONS (Appearance) with the text in value_chr.
#             value_chr/rl_low/rl_high/purpose/comments NULL on the numbers.
# The one deliberate difference, for provenance: sample.comments carries
# "Entered by migration 038 from ACIRL PDF 2400-7453-09 (no workbook
# received)" (the 020 precedent: provenance on the sample, not the analyses).
# change_log: one insert row per sample and analysis (db_append), actor
# "038-dust-sep-2025-from-pdf", source_hash = the PDF's hash.
#
# ---- FILING -------------------------------------------------------------------
# A80 files ACIRL samples under the CITED ALS work order, as 035/037 did:
# ES2528155 (5075e630), the 2025-09-09 Blaxland quarterly, which already holds
# this visit's 14 ACIRL field samples and the PDF asset. No project named
# 2400-7453-09 exists. A real import would ALSO have created an "ACIRL report"
# project 2400-7453-09 under EPL quarterly and re-parented ES2528155 under it
# (.ct_ensure_project_tree). 038 does not: the samples' uuid_project is
# ES2528155 either way, the extra level carries no data, and inserting it means
# re-parenting a legacy-loaded work order that every other legacy quarterly
# (e.g. ES2525054, 7453-08's dust) does without. If the workbook ever arrives,
# its import builds that level itself and finds this dust already present
# (same gauge, day and values). Asserted: no 2400-7453-09 project exists.
#
# Preconditions: marker 1037; ES2528155 as above under EPL quarterly; the PDF
# asset; the 4 lab_methods and 2 aliases as named; NO sample of any kind at
# B.D07/B.D08 on Sydney day 2025-09-01, and no dust sample there exposed
# 2025-08-01; none of the planned uuids exists; 009's ux_sample_identity
# intact; 021's invariant holds on every dust sample. INSERT is safe under
# ux_sample_identity (the delete+insert quirk is UPDATE-only), so the index is
# not touched; the new (alias, datetime, project) keys are proven free.
#
# Writes: one transaction (2 sample + 8 analysis inserts, 10 change_log rows,
# marker 1038), counts and checksums of everything else checked inside it.
# Nothing pre-existing changes, so there is no BACKUP CSV; rows created:
# 038-dust-sep-2025-from-pdf-INSERTED-{sample,analysis}.csv. Plus the
# verified whole-file backup in snapshot_dir.
#
# Idempotent: marker present -> re-verify, no-op.
#
#   devtools::load_all(".")
#   env <- new.env()
#   sys.source("dev/migrations/038-dust-sep-2025-from-pdf.R", envir = env)
#   env$mig038_run(db = st_config("live_db"),
#                  snapshot_dir = st_config("snapshot_dir"), dry_run = TRUE)

.mig038_marker_version <- 1038L
.mig038_requires <- 1037L
.mig038_name <- "038-dust-sep-2025-from-pdf"
.mig038_actor <- .mig038_name
.mig038_index_name <- "ux_sample_identity"
.mig038_index_sql <- 'CREATE UNIQUE INDEX ux_sample_identity ON "sample"(uuid_feature_alias, datetime, uuid_project);'

.mig038_comment <- "Entered by migration 038 from ACIRL PDF 2400-7453-09 (no workbook received)"
.mig038_pdf_hash <- "20ddfc1bdfda152b87cabcda5fa10fc5"
.mig038_pdf_asset <- "4bfcb924-7f94-4ac3-bded-32fb00088ea2"
.mig038_pdf_name <- "2400-7453-09 September 2025 Quarterly Blaxland WMF.pdf"
.mig038_proj <- list(uuid = "5075e630-aed0-429c-b05d-4df81ea9fda3", name = "ES2528155",
                     parent = "a8ce3eff-e293-401c-8225-6d0c57d06993", parent_name = "EPL quarterly")
.mig038_report <- "2400-7453-09"
.mig038_date <- "2025-09-01"
.mig038_date_start <- "2025-08-01"
.mig038_obs <- "Clear, insects, organic matter, fine brown dusts, coarse black dust."

.mig038_methods <- utils::read.csv(text = "key,uuid,name,analyte
total,83282ca2-596d-43f5-ac3e-4d01412c167b,INSOLUBLE SOLIDS,dust-total
comb,734a6092-0af8-4019-841d-86f529109d86,*COMBUSTIBLE MATTER,dust-combustible
incomb,e6019d73-d6d8-4b64-806a-d4a647a1da9d,INCOMBUSTIBLE MATTER,dust-incombustible
obs,fb774416-e0ef-4210-87e5-97ab8e045427,ANALYSIS OBSERVATIONS,Appearance",
  stringsAsFactors = FALSE, colClasses = "character")

.mig038_samples <- utils::read.csv(text = "uuid,gauge,alias
8c97f7f4-4fac-4f6b-83a0-81092023cbc8,B.D07,75e593a3-134b-4097-8ad9-e1e65ddc8f17
dab8ba98-68bd-4272-9bad-2f3bf7261c62,B.D08,22b50a74-b596-4cac-97f7-534d881ec98d",
  stringsAsFactors = FALSE, colClasses = "character")

# value NA + value_chr = the Appearance row; quantified FALSE = "<0.1".
.mig038_analyses <- utils::read.csv(text = "uuid,gauge,key,value,quantified
9a4087b8-d256-4bb5-8016-a1756ad6d004,B.D07,total,0.2,TRUE
3cc4f2dc-b35b-44fd-8d25-d182519f0f51,B.D07,comb,0.1,FALSE
19e84be9-7449-4800-af04-f724d4c2baa4,B.D07,incomb,0.2,TRUE
fbb182e4-fbcb-462c-a668-e88a00e826a7,B.D07,obs,,
f412c2be-79fc-4ea9-beeb-74167c06b441,B.D08,total,0.6,TRUE
eaa58d02-e8fa-480b-8c2b-2e9e3086942b,B.D08,comb,0.1,FALSE
c60f8243-e4e5-4c50-be0e-cfe62ea16586,B.D08,incomb,0.6,TRUE
a8781e6e-84e6-450a-b2d4-c4cd38942b06,B.D08,obs,,",
  stringsAsFactors = FALSE, colClasses = "character")

.mig038_default <- function(x, default) if (is.null(x)) default else x
.mig038_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = list(...))[[1]][[1]])
.mig038_fail <- function(msg) cli::cli_abort(paste0(.mig038_name, ": ", msg), class = "sampletidy_error")
.mig038_in <- function(x) paste0("('", paste(x, collapse = "','"), "')")
.mig038_syd <- function(col) sprintf("(%s AT TIME ZONE 'UTC' AT TIME ZONE 'Australia/Sydney')::DATE", col)
.mig038_midnight <- function(d) as.POSIXct(paste(d, "00:00:00"), tz = "UTC")

.mig038_dust_uuid_sql <- "SELECT DISTINCT a.uuid_sample FROM analysis a JOIN lab_method lm ON lm.uuid = a.uuid_lab
  JOIN analyte an ON an.uuid = lm.uuid_analyte WHERE an.name LIKE 'dust-%'"

# 021's invariant over every dust sample: datetime = date, datetime_start = date_start.
.mig038_invariant_bad <- function(con) {
  .mig038_scalar(con, sprintf("SELECT COUNT(*) FROM \"sample\" WHERE uuid IN (%s) AND
    (datetime IS DISTINCT FROM date OR datetime_start IS DISTINCT FROM date_start)", .mig038_dust_uuid_sql))
}

.mig038_counts <- function(con) {
  tabs <- c("feature", "feature_alias", "analyte", "lab_method", "analysis", "sample", "project", "asset",
            "review_queue", "review_queue_candidate", "ingest_file", "change_log", "schema_version")
  stats::setNames(lapply(tabs, function(t) .mig038_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
}

.mig038_index_def <- function(con) {
  DBI::dbGetQuery(con, "SELECT sql FROM duckdb_indexes() WHERE index_name = ?", params = list(.mig038_index_name))$sql
}

# Every sample at B.D07/B.D08 on the Sydney collection day, and every dust
# sample there exposed on the Sydney exposure day.
.mig038_at_gauges <- function(con) {
  DBI::dbGetQuery(con, sprintf("
    SELECT s.uuid, f.name AS gauge, s.uuid_project,
           %s AS syd_date, %s AS syd_start,
           s.uuid IN (%s) AS is_dust
    FROM \"sample\" s
    JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
    JOIN feature f ON f.uuid = fa.uuid_feature
    WHERE f.name IN ('B.D07', 'B.D08')
      AND (%s = DATE '%s' OR (%s = DATE '%s' AND s.uuid IN (%s)))
    ORDER BY f.name, s.uuid",
    .mig038_syd("COALESCE(s.datetime, s.date)"), .mig038_syd("s.date_start"), .mig038_dust_uuid_sql,
    .mig038_syd("COALESCE(s.datetime, s.date)"), .mig038_date,
    .mig038_syd("s.date_start"), .mig038_date_start, .mig038_dust_uuid_sql))
}

# The rows exactly as they will be inserted.
.mig038_sample_rows <- function() {
  n <- nrow(.mig038_samples)
  data.frame(
    uuid = .mig038_samples$uuid, uuid_feature_alias = .mig038_samples$alias,
    uuid_project = rep(.mig038_proj$uuid, n),
    date = rep(.mig038_midnight(.mig038_date), n), date_start = rep(.mig038_midnight(.mig038_date_start), n),
    datetime = rep(.mig038_midnight(.mig038_date), n), datetime_start = rep(.mig038_midnight(.mig038_date_start), n),
    organisation = rep("ACIRL", n), person = rep("B.Collins", n),
    purpose = rep(NA_character_, n), comments = rep(.mig038_comment, n),
    stringsAsFactors = FALSE)
}

.mig038_analysis_rows <- function() {
  a <- .mig038_analyses
  is_obs <- a$key == "obs"
  data.frame(
    uuid = a$uuid,
    uuid_sample = .mig038_samples$uuid[match(a$gauge, .mig038_samples$gauge)],
    uuid_lab = .mig038_methods$uuid[match(a$key, .mig038_methods$key)],
    value = ifelse(is_obs, NA_real_, suppressWarnings(as.numeric(a$value))),
    value_chr = ifelse(is_obs, .mig038_obs, NA_character_),
    quantified = ifelse(is_obs, NA, as.logical(a$quantified)),
    rl_low = NA_real_, rl_high = NA_real_, purpose = NA_character_, comments = NA_character_,
    stringsAsFactors = FALSE)
}

.mig038_check_preconditions <- function(con) {
  if (.mig038_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig038_requires) == 0L) {
    .mig038_fail(sprintf("marker %d (037) is required first.", .mig038_requires))
  }
  def <- .mig038_index_def(con)
  if (length(def) != 1L || !identical(def, .mig038_index_sql)) {
    .mig038_fail(sprintf("index %s is %s, not 009's definition.", .mig038_index_name, if (length(def)) def else "MISSING"))
  }
  p <- DBI::dbGetQuery(con, "SELECT c.name, c.type, c.uuid_parent, p.name AS parent_name FROM project c
    LEFT JOIN project p ON p.uuid = c.uuid_parent WHERE c.uuid = ?", params = list(.mig038_proj$uuid))
  if (nrow(p) != 1L || !identical(p$name, .mig038_proj$name) || !identical(p$type, "Work order") ||
      !identical(p$uuid_parent, .mig038_proj$parent) || !identical(p$parent_name, .mig038_proj$parent_name)) {
    .mig038_fail("ES2528155 is missing, not a Work order, or no longer directly under EPL quarterly.")
  }
  if (.mig038_scalar(con, "SELECT COUNT(*) FROM project WHERE name = ?", .mig038_report) != 0L) {
    .mig038_fail("a project named 2400-7453-09 now exists (an import?); the filing decision must be revisited.")
  }
  as <- DBI::dbGetQuery(con, "SELECT uuid_project, filename, hash FROM asset WHERE uuid = ?", params = list(.mig038_pdf_asset))
  if (nrow(as) != 1L || !identical(as$uuid_project, .mig038_proj$uuid) || !identical(as$hash, .mig038_pdf_hash) ||
      !identical(as$filename, .mig038_pdf_name)) {
    .mig038_fail("the 2400-7453-09 PDF asset is missing or changed.")
  }
  lm <- DBI::dbGetQuery(con, sprintf("SELECT lm.uuid, lm.name, an.name AS analyte FROM lab_method lm
    JOIN analyte an ON an.uuid = lm.uuid_analyte WHERE lm.uuid IN %s", .mig038_in(.mig038_methods$uuid)))
  lm <- lm[match(.mig038_methods$uuid, lm$uuid), ]
  if (anyNA(lm$uuid) || !identical(lm$name, .mig038_methods$name) || !identical(lm$analyte, .mig038_methods$analyte)) {
    .mig038_fail("an ACIRL dust lab_method is missing or not the planned one.")
  }
  fa <- DBI::dbGetQuery(con, sprintf("SELECT fa.uuid, fa.name, f.name AS feat FROM feature_alias fa
    JOIN feature f ON f.uuid = fa.uuid_feature WHERE fa.uuid IN %s", .mig038_in(.mig038_samples$alias)))
  fa <- fa[match(.mig038_samples$alias, fa$uuid), ]
  if (anyNA(fa$uuid) || !identical(fa$name, .mig038_samples$gauge) || !identical(fa$feat, .mig038_samples$gauge)) {
    .mig038_fail("a B.D07/B.D08 self alias is missing or not the planned one.")
  }
  if (.mig038_scalar(con, sprintf("SELECT COUNT(*) FROM \"sample\" WHERE uuid IN %s", .mig038_in(.mig038_samples$uuid))) +
      .mig038_scalar(con, sprintf("SELECT COUNT(*) FROM analysis WHERE uuid IN %s", .mig038_in(.mig038_analyses$uuid))) != 0L) {
    .mig038_fail("a planned uuid already exists.")
  }
  g <- .mig038_at_gauges(con)
  if (nrow(g) != 0L) {
    .mig038_fail(sprintf("B.D07/B.D08 already have a sample on %s or dust exposed %s: %s.",
                         .mig038_date, .mig038_date_start, paste(g$uuid, collapse = ", ")))
  }
  key_taken <- .mig038_scalar(con, sprintf("SELECT COUNT(*) FROM \"sample\" WHERE uuid_feature_alias IN %s
    AND datetime = ? AND uuid_project = ?", .mig038_in(.mig038_samples$alias)),
    .mig038_midnight(.mig038_date), .mig038_proj$uuid)
  if (key_taken != 0L) .mig038_fail("a planned (alias, datetime, project) key is taken.")
  bad <- .mig038_invariant_bad(con)
  if (bad != 0L) .mig038_fail(sprintf("%d dust samples break 021's invariant before the run.", bad))
  invisible(TRUE)
}

# Compare the stored rows to the planned ones, column by column, as text.
.mig038_rows_as_text <- function(df) {
  out <- df
  for (f in names(out)) {
    out[[f]] <- if (inherits(out[[f]], "POSIXct")) format(out[[f]], "%Y-%m-%d %H:%M:%S", tz = "UTC") else as.character(out[[f]])
  }
  out <- out[order(out$uuid), , drop = FALSE]
  rownames(out) <- NULL
  out
}

.mig038_done_problem <- function(con) {
  if (.mig038_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig038_marker_version) != 1L) return("marker 1038 missing")
  s <- DBI::dbGetQuery(con, sprintf("SELECT * FROM \"sample\" WHERE uuid IN %s", .mig038_in(.mig038_samples$uuid)))
  if (!identical(.mig038_rows_as_text(s), .mig038_rows_as_text(.mig038_sample_rows()))) return("the 2 samples are missing or differ from the plan")
  a <- DBI::dbGetQuery(con, sprintf("SELECT * FROM analysis WHERE uuid_sample IN %s", .mig038_in(.mig038_samples$uuid)))
  if (!identical(.mig038_rows_as_text(a), .mig038_rows_as_text(.mig038_analysis_rows()))) return("the 8 analyses are missing or differ from the plan")
  g <- .mig038_at_gauges(con)
  if (nrow(g) != 2L || !setequal(g$uuid, .mig038_samples$uuid)) return("B.D07/B.D08 on 2025-09-01 are not exactly the 2 entered samples")
  cl <- .mig038_scalar(con, "SELECT COUNT(*) FROM change_log WHERE actor = ? AND action = 'insert' AND source_hash = ?",
                       .mig038_actor, .mig038_pdf_hash)
  if (cl != 10L) return(sprintf("%d change_log insert rows under 038, expected 10", cl))
  bad <- .mig038_invariant_bad(con)
  if (bad > 0L) return(sprintf("%d dust samples break 021's datetime = date / datetime_start = date_start", bad))
  def <- .mig038_index_def(con)
  if (length(def) != 1L || !identical(def, .mig038_index_sql)) return("ux_sample_identity is missing or changed")
  NULL
}

.mig038_verify <- function(con) {
  p <- .mig038_done_problem(con)
  if (!is.null(p)) cli::cli_abort(paste0("038 verify failed: ", p), class = "sampletidy_error")
  invisible(TRUE)
}

mig038_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- .mig038_default(.now, Sys.time())
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig038_name, ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig038_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig038_counts(verify_con))) {
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  }
  dest
}

.mig038_write_csv <- function(df, path) {
  out <- df
  for (f in names(out)) if (inherits(out[[f]], c("POSIXct", "Date"))) out[[f]] <- .st_changelog_str(out[[f]])
  utils::write.csv(out, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8", colClasses = "character")
  if (nrow(back) != nrow(df) || !identical(back$uuid, as.character(out$uuid))) {
    cli::cli_abort("038: CSV {basename(path)} did not round-trip.", class = "sampletidy_error")
  }
}

# Checksums of everything 038 may not touch.
.mig038_checksums <- function(con) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  tabs <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  whole <- setdiff(tabs, c("sample", "analysis", "change_log", "schema_version"))
  out <- lapply(whole, function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- whole
  out$sample_rest <- q(sprintf("SELECT * FROM \"sample\" WHERE uuid NOT IN %s ORDER BY uuid", .mig038_in(.mig038_samples$uuid)))
  out$analysis_rest <- q(sprintf("SELECT * FROM analysis WHERE uuid NOT IN %s ORDER BY uuid", .mig038_in(.mig038_analyses$uuid)))
  out$change_log_rest <- q(sprintf("SELECT * FROM change_log WHERE actor <> '%s' ORDER BY ALL", .mig038_actor))
  out$schema_version_rest <- q(sprintf("SELECT * FROM schema_version WHERE version <> %d ORDER BY ALL", .mig038_marker_version))
  out$views <- q("SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
  out$indexes <- q("SELECT index_name, sql FROM duckdb_indexes() ORDER BY index_name")
  out
}

.mig038_write <- function(con, recorded_at, logf) {
  .mig038_check_preconditions(con)   # re-read under the write lock
  counts_before <- .mig038_counts(con)
  sums_before <- .mig038_checksums(con)
  reason <- sprintf("038: Blaxland dust exposed %s collected %s entered from ACIRL PDF %s (no workbook received); filed under its cited ALS work order %s (A80)",
                    .mig038_date_start, .mig038_date, .mig038_report, .mig038_proj$name)
  db_transaction(con, function(con) {
    db_append(con, "sample", .mig038_sample_rows(), actor = .mig038_actor, reason = reason, source_hash = .mig038_pdf_hash)
    db_append(con, "analysis", .mig038_analysis_rows(), actor = .mig038_actor, reason = reason, source_hash = .mig038_pdf_hash)
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig038_marker_version, recorded_at))
    want <- counts_before
    want$sample <- want$sample + 2L
    want$analysis <- want$analysis + 8L
    want$change_log <- want$change_log + 10L
    want$schema_version <- want$schema_version + 1L
    got <- .mig038_counts(con)
    if (!identical(got, want)) {
      .mig038_fail(sprintf("counts are not before + 2 samples + 8 analyses + 10 change_log + 1 marker: %s",
                           paste(names(got), unlist(got), unlist(want), sep = ":", collapse = ", ")))
    }
    if (!identical(sums_before, .mig038_checksums(con))) .mig038_fail("the write changed something outside the 10 new rows.")
    .mig038_verify(con)
    NULL
  })
  logf("Inserted 2 samples + 8 analyses under %s, marker %d (committed).", .mig038_proj$name, .mig038_marker_version)
  .mig038_verify(con)
}

mig038_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(
    DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                    params = list(.mig038_marker_version)),
    finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch(.mig038_verify(check_con), finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("038 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  tryCatch(.mig038_check_preconditions(pre_con), finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  logf("Plan: insert B.D07/B.D08 dust exposed %s collected %s from ACIRL PDF %s under %s (2 samples, 8 analyses).",
       .mig038_date_start, .mig038_date, .mig038_report, .mig038_proj$name)
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition passed. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = NA)))
  }

  backup_path <- mig038_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- .mig038_default(.now, Sys.time())

  with_db_write(function(con) .mig038_write(con, recorded_at, logf), db = db)

  ins_con <- st_connect(db, read_only = TRUE)
  tryCatch({
    .mig038_write_csv(DBI::dbGetQuery(ins_con, sprintf("SELECT * FROM \"sample\" WHERE uuid IN %s ORDER BY uuid", .mig038_in(.mig038_samples$uuid))),
                      file.path(csv_dir, sprintf("%s-INSERTED-sample.csv", .mig038_name)))
    .mig038_write_csv(DBI::dbGetQuery(ins_con, sprintf("SELECT * FROM analysis WHERE uuid_sample IN %s ORDER BY uuid", .mig038_in(.mig038_samples$uuid))),
                      file.path(csv_dir, sprintf("%s-INSERTED-analysis.csv", .mig038_name)))
  }, finally = DBI::dbDisconnect(ins_con, shutdown = TRUE))

  logf("%s migrated successfully (marker %d).", .mig038_name, .mig038_marker_version)
  invisible(list(status = "migrated", backup_path = backup_path,
                 restore_command = restore_command, recorded_at = recorded_at))
}
