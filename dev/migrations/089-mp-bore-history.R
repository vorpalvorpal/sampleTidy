# Operator-run migration: import the historical Katoomba "MP #1-4" bore results
# (Nov 2012 - May 2020) from ACIRL's PDF reports, which no package adapter reads.
# Marker 1089. Requires 1088. Authority: Robin, 2026-10-28 (approved the import
# of the MP bore history from the reports held in Council's records system).
#
# ---- BACKGROUND ----------------------------------------------------------------
# K.MW01-K.MW04 are the bores ACIRL's reports call "MP # 1".."MP # 4" (also
# "MP#1", "MP1", "MP 1"; installed Sep 2010, first sampled Nov 2012). The
# database holds them only from 2020-08-11 (ACIRL 24006990-08 / ALS ES2028249,
# imported from the workbook and ESdat). Everything earlier exists only as ACIRL
# PDF reports: the quarterly "Additional MP Bores" reports of 2012-2015 and the
# whole-site quarterly/annual reports of 2015-2020. The bore identity (MP n =
# K.MW0n) was checked against ACIRL 24006990-08, whose 11 Aug 2020 MP values
# equal the stored K.MW0n values bore by bore, and the report coordinates of
# MP1-4 (MGA56) equal the stored K.MW01-04 coordinates.
#
# ---- WHAT NO ADAPTER COVERS, AND HOW THIS IMPORTS IT ---------------------------
# sampleTidy has no PDF adapter (acirl_field_xlsx reads only the ACIRL workbooks,
# which do not exist for these reports). The tables were transcribed from each
# PDF's text layer (pdftotext -layout; every token assigned to the nearest site
# column) into 089-mp-bore-history-INPUT-values.csv: one row per printed cell of
# an MP column, value as printed. That transcription is frozen with the source
# file's hash, and checked against the rendered pages.
#
# The import itself goes through the package's own pipeline, unchanged: an
# OPERATOR adapter (`acirl_pdf_089`, defined here, registered for this run
# only, never in R/) claims exactly the frozen PDFs by hash at the `exact` tier
# and returns, as its parse(), the frozen rows in the IR shape the ACIRL
# workbook adapter emits for the same table:
#   * org "ACIRL", work_order = the front-page report number, method_raw NA;
#   * field rows (pH, Electrical Conductivity, Water Height, Temperature) and
#     the observation, split by .st_acirl_split_observation() into Comments
#     (Appearance) / Flow observation (Stage) as the workbook adapter does;
#   * the ALS analytes ACIRL copied into its tables (alkalinity, anions,
#     cations, ammonia, TOC, TDS ...) as ACIRL TRANSCRIPTIONS (A79/A83: org
#     ACIRL, method NULL, resolved through 006's transcription lab_methods),
#     because the ALS originals are not held. If an ALS file for one of the
#     cited work orders is ever imported, A79 supersession replaces them.
#   * report$header$report_no and report$als_work_orders, so A80 files each
#     report as an `ACIRL report` project with its cited ALS work order as a
#     child, exactly as for a workbook.
# Everything else - alias resolution, analyte and unit resolution, the sample
# identity and duplicate checks, review items, archive_file() of the PDF as the
# event's asset, ingest_file - is ingest_dir()'s ordinary behaviour.
#
# Only MP columns are transcribed. The whole-site reports also carry the other
# Katoomba points (Bore 8, 10A, 11B, 12, LB12, surface and leachate points);
# those are NOT imported here (none of them is in the database for these
# dates either; a separate decision).
#
# ---- PHASES --------------------------------------------------------------------
# A (one transaction): feature_alias arms for every MP spelling the reports use,
#   -> K.MW0n through ONE mapping table (.mig089_bores; change it there if the
#   mapping is ever ruled otherwise), bounded to the history window
#   (INPUT-alias.csv) so they never overlap the existing dated arms from
#   2020-08-11 on; and K.MW01-04 feature.date_start moved back from 2020-08-11
#   to the first imported sample day, with a note appended to comments.
# B: ingest_dir() of a staging inbox holding exactly the frozen PDFs (copied
#   from the FILES dir, hashes verified), with the operator adapter registered,
#   remove_ingested FALSE. Verified after: every PDF archived with one asset;
#   every new sample is at K.MW01-04 on a frozen day; new analyses = the
#   adapter's emitted result rows; no new sample at any other feature; no
#   existing sample or analysis changed.
# C (one transaction): the PDFs are already in TRIM, so each new asset gets an
#   asset_filing row (system 'trim', external_id = the TRIM record number,
#   external_uri = its URI, container = its folder, title = its TRIM title,
#   filed_at = the record's date) through register_filing(): the BMCC filer
#   treats an asset with a 'trim' filing row as filed and never uploads it
#   again. The record numbers are NOT in this public repo: they are read from
#   the untracked 089-mp-bore-history-TRIM.csv. Then marker 1089.
#
# Idempotent: marker present -> re-verify, no-op. A run that stops after A or B
# can be re-run: A skips arms already present exactly as planned, B's ingest is
# a no-op for archived files, C's register_filing() is "unchanged".
#
#   devtools::load_all(".")
#   env <- new.env()
#   sys.source("dev/migrations/089-mp-bore-history.R", envir = env)
#   env$mig089_run(db = st_config("live_db"), snapshot_dir = ..., archive_dir = st_config("archive_dir"),
#                  work_dir = ..., files_dir = "dev/migrations/089-mp-bore-history-FILES",
#                  trim_csv = "dev/migrations/089-mp-bore-history-TRIM.csv", dry_run = TRUE)

.mig089_marker_version <- 1089L
.mig089_requires <- 1088L
.mig089_name <- "089-mp-bore-history"
.mig089_actor <- .mig089_name
.mig089_adapter_id <- "acirl_pdf_089"
.mig089_adapter_version <- "1"
.mig089_confirmed_by <- "R. Shannon"
.mig089_trim_system <- "trim"

# THE bore mapping (one table): MP n in ACIRL's reports -> feature.
.mig089_bores <- data.frame(mp = 1:4, feature = c("K.MW01", "K.MW02", "K.MW03", "K.MW04"),
                            stringsAsFactors = FALSE)

# Printed row label -> analyte_raw the IR carries (an ACIRL lab_method name), or
# "" for a label that is deliberately not imported, or "<obs>" for the
# observation row. A label not listed aborts the run (re-check the table).
.mig089_labels <- utils::read.csv(text = 'printed,analyte_raw,note
Observations,<obs>,
General Comments/ Observations,<obs>,
General Comments / Observations,<obs>,
pH,pH,field
Electrical Conductivity,Electrical Conductivity,field
Temperature,Temperature,field
Water Height,Water Height,field (depth to water from the collar)
Standing Water Level,Standing Water Level,field
Total Dissolved Solids,Total Dissolved Solids,transcription
Hydroxide Alkalinity as CaCO3,Hydroxide Alkalinity as CaCO3,transcription
Carbonate Alkalinity as CaCO3,Carbonate Alkalinity as CaCO3,transcription
Bicarbonate Alkalinity as CaCO3,Bicarbonate Alkalinity as CaCO3,transcription
Total Alkalinity as CaCO3,Total Alkalinity as CaCO3,transcription
Sulfate as SO4 - Turbidimetric,Sulfate as SO4 - Turbidimetric,transcription
Chloride,Chloride,transcription
Calcium,Calcium,transcription
Magnesium,Magnesium,transcription
Sodium,Sodium,transcription
Potassium,Potassium,transcription
Ammonia as N,Ammonia as N,transcription
Total Organic Carbon,Total Organic Carbon,transcription
Electrical Conducivity,Electrical Conductivity,field (misspelt in the May 2014 report)
Phenols (Total),Phenols (Total),transcription (annual suite)
Volume of Water Purged,,not a water-quality result (purge volume); no lab_method
Volume of Water Purge,,as above
Volumen of Water Purge,,as above (misspelt)
Total Suspended Solids,,never reported for the MP bores (----)',
  stringsAsFactors = FALSE, colClasses = "character", na.strings = "NA_")

.mig089_files_cols <- c("hash", "staged_name", "report_no", "als_work_order", "sample_days", "n_values", "note")
.mig089_values_cols <- c("hash", "source_ref", "mp", "feature_raw", "sample_datetime_raw", "label", "units_raw",
                         "value_raw")
.mig089_alias_cols <- c("name", "mp", "date_start", "date_end")
.mig089_corr_cols <- c("hash", "mp", "label", "field", "printed", "corrected", "reason")
.mig089_trim_cols <- c("hash", "trim_record", "trim_uri", "container", "title", "record_date")
.mig089_not_reported <- c("_", "-", "--", "---", "----", "")

.mig089_fail <- function(msg) cli::cli_abort(paste0(.mig089_name, ": ", msg), class = "sampletidy_error")
.mig089_scalar <- function(con, sql, ...) {
  as.integer(DBI::dbGetQuery(con, sql, params = if (length(list(...))) list(...) else NULL)[[1]][[1]])
}
.mig089_inlist <- function(x) if (!length(x)) "('')" else paste0("(", paste0("'", gsub("'", "''", unique(x)), "'", collapse = ","), ")")
.mig089_syd <- function(col) sprintf("CAST((%s AT TIME ZONE 'UTC') AT TIME ZONE 'Australia/Sydney' AS DATE)", col)
.mig089_csv_path <- function(dir, what) file.path(dir, sprintf("%s-%s.csv", .mig089_name, what))
.mig089_read <- function(p, cols) {
  if (!file.exists(p)) .mig089_fail(sprintf("input %s not found.", p))
  x <- utils::read.csv(p, colClasses = "character", na.strings = "", encoding = "UTF-8")
  if (!identical(names(x), cols)) .mig089_fail(sprintf("%s: columns are not as planned.", basename(p)))
  x
}

# ---- inputs ----------------------------------------------------------------------

mig089_read_inputs <- function(input_dir = "dev/migrations") {
  files <- .mig089_read(.mig089_csv_path(input_dir, "INPUT-files"), .mig089_files_cols)
  values <- .mig089_read(.mig089_csv_path(input_dir, "INPUT-values"), .mig089_values_cols)
  alias <- .mig089_read(.mig089_csv_path(input_dir, "INPUT-alias"), .mig089_alias_cols)
  corr <- .mig089_read(.mig089_csv_path(input_dir, "INPUT-corrections"), .mig089_corr_cols)
  values <- .mig089_correct(values, corr)
  if (anyNA(files$hash) || anyDuplicated(files$hash) || anyNA(files$staged_name) || anyDuplicated(files$staged_name) ||
      anyNA(files$report_no))
    .mig089_fail("INPUT-files misses or repeats a hash, name or report number.")
  wo <- unlist(strsplit(stats::na.omit(files$als_work_order), ";", fixed = TRUE))
  if (!all(grepl("^ES[0-9]{7}$", wo))) .mig089_fail("INPUT-files holds an ALS work order that is not ES + 7 digits.")
  if (!all(grepl("^[0-9]{8}(-[0-9A-Z]+)?$", files$report_no))) .mig089_fail("INPUT-files holds a malformed report number.")
  if (!all(values$hash %in% files$hash)) .mig089_fail("INPUT-values names a file not in INPUT-files.")
  if (!all(files$hash %in% values$hash)) .mig089_fail("INPUT-files lists a file with no values.")
  if (anyNA(values[, c("hash", "source_ref", "mp", "feature_raw", "sample_datetime_raw", "label")]))
    .mig089_fail("INPUT-values misses a required value.")
  if (anyDuplicated(values[, c("hash", "source_ref")])) .mig089_fail("INPUT-values repeats a source_ref.")
  if (!all(values$mp %in% as.character(.mig089_bores$mp))) .mig089_fail("INPUT-values names a bore outside MP 1-4.")
  unknown <- setdiff(unique(values$label), .mig089_labels$printed)
  if (length(unknown)) .mig089_fail(sprintf("unlisted label(s): %s", paste(unknown, collapse = "; ")))
  n_by_file <- table(factor(values$hash, levels = files$hash))
  if (!identical(as.integer(n_by_file), as.integer(files$n_values)))
    .mig089_fail("INPUT-files n_values does not match INPUT-values.")
  if (anyNA(alias) || anyDuplicated(alias$name)) .mig089_fail("INPUT-alias misses or repeats a value.")
  if (!all(alias$mp %in% as.character(.mig089_bores$mp))) .mig089_fail("INPUT-alias names a bore outside MP 1-4.")
  if (any(as.Date(alias$date_start) > as.Date(alias$date_end))) .mig089_fail("INPUT-alias has start > end.")
  # every feature_raw spelling is covered by an alias row of the same bore
  fr <- unique(values[, c("feature_raw", "mp")])
  key <- paste(.rc_feature_key(fr$feature_raw), fr$mp)
  if (!all(key %in% paste(.rc_feature_key(alias$name), alias$mp)))
    .mig089_fail("a printed MP spelling has no INPUT-alias row for its bore.")
  list(files = files, values = values, alias = alias, corrections = corr)
}

# INPUT-values holds each cell as printed; INPUT-corrections lists the few printed
# units/dates that are evidently wrong, each with its reason (Robin to confirm). A
# correction applies to the cells of one file, bore (mp, or "*" for all) and label
# (or "*") whose `field` (units_raw or sample_datetime_raw) equals `printed`; one
# that matches no cell aborts the run.
.mig089_correct <- function(values, corr) {
  if (anyNA(corr[, c("hash", "mp", "label", "field", "corrected", "reason")]))
    .mig089_fail("INPUT-corrections misses a value.")
  if (!all(corr$field %in% c("units_raw", "sample_datetime_raw")))
    .mig089_fail("INPUT-corrections may change only units_raw or sample_datetime_raw.")
  for (i in seq_len(nrow(corr))) {
    c1 <- corr[i, ]
    cur <- values[[c1$field]]
    hit <- values$hash == c1$hash & (c1$mp == "*" | values$mp == c1$mp) & (c1$label == "*" | values$label == c1$label) &
      (if (is.na(c1$printed)) is.na(cur) else (!is.na(cur) & cur == c1$printed))
    if (!any(hit)) .mig089_fail(sprintf("INPUT-corrections row %d matches no cell.", i))
    values[[c1$field]][hit] <- c1$corrected
  }
  values
}

mig089_read_trim <- function(trim_csv, files) {
  t <- .mig089_read(trim_csv, .mig089_trim_cols)
  if (anyNA(t[, c("hash", "trim_record", "trim_uri", "container", "title", "record_date")]))
    .mig089_fail("the TRIM CSV misses a value.")
  if (anyDuplicated(t$hash) || !setequal(t$hash, files$hash))
    .mig089_fail("the TRIM CSV must hold exactly one row per imported file.")
  t
}

# ---- the operator adapter ---------------------------------------------------------

.mig089_day_of <- function(raw) {
  d <- as.Date(raw, format = "%d %b %Y")
  if (anyNA(d)) .mig089_fail(sprintf("unparseable sample_datetime_raw: %s", paste(raw[is.na(d)], collapse = ", ")))
  d
}

.mig089_parse_one <- function(fh, files, v, tag) {
  f <- files[files$hash == fh, , drop = FALSE]
  v <- v[order(v$mp, v$sample_datetime_raw, as.integer(sub("^b[0-9]+!r([0-9]+)!.*$", "\\1", v$source_ref))), , drop = FALSE]
  v$lab_sample_id <- sprintf("%s!MP%s!%s", f$report_no, v$mp, gsub("[^0-9A-Za-z]", "", v$sample_datetime_raw))
  lab <- .mig089_labels$analyte_raw[match(v$label, .mig089_labels$printed)]
  rows <- list(); skipped <- list(); obs <- list()
  for (i in seq_len(nrow(v))) {
    val <- if (is.na(v$value_raw[[i]])) "" else trimws(v$value_raw[[i]])
    if (identical(lab[[i]], "<obs>")) {
      if (!val %in% .mig089_not_reported) obs[[v$lab_sample_id[[i]]]] <- list(ref = v$source_ref[[i]], text = val)
      next
    }
    if (val %in% .mig089_not_reported) {
      skipped[[length(skipped) + 1]] <- tibble::tibble(source_ref = v$source_ref[[i]], reason = "not_reported")
      next
    }
    if (!nzchar(lab[[i]])) {
      skipped[[length(skipped) + 1]] <- tibble::tibble(source_ref = v$source_ref[[i]], reason = "label_not_imported")
      next
    }
    pv <- parse_value(val)
    rows[[length(rows) + 1]] <- tibble::tibble(
      source_hash = fh, source_ref = v$source_ref[[i]], work_order = f$report_no, revision = 0L, org = "ACIRL",
      adapter = tag, lab_sample_id = v$lab_sample_id[[i]], sample_type = "Normal", feature_raw = v$feature_raw[[i]],
      analyte_raw = lab[[i]], cas_number = NA_character_, method_raw = NA_character_,
      total_or_filtered = NA_character_, units_raw = .st_acirl_repair_units(lab[[i]], v$units_raw[[i]]),
      value_raw = val, value_num = pv$value_num, value_chr = pv$value_chr, below_detection = grepl("^<", val),
      rl = NA_real_, lab_qualifier = NA_character_, analysed_date = as.Date(NA_character_),
      comments = NA_character_, confidence = 1)
  }
  for (id in names(obs)) {
    o <- obs[[id]]; sp <- .st_acirl_split_observation(o$text)
    k <- match(id, v$lab_sample_id)
    for (part in c("stage", "appearance")) {
      if (is.na(sp[[part]])) next
      rows[[length(rows) + 1]] <- tibble::tibble(
        source_hash = fh, source_ref = paste0(o$ref, "!", part), work_order = f$report_no, revision = 0L,
        org = "ACIRL", adapter = tag, lab_sample_id = id, sample_type = "Normal", feature_raw = v$feature_raw[[k]],
        analyte_raw = if (part == "stage") "Flow observation" else "Comments", cas_number = NA_character_,
        method_raw = NA_character_, total_or_filtered = NA_character_, units_raw = NA_character_, value_raw = o$text,
        value_num = NA_real_, value_chr = sp[[part]], below_detection = FALSE, rl = NA_real_,
        lab_qualifier = NA_character_, analysed_date = as.Date(NA_character_), comments = NA_character_,
        confidence = 1)
    }
  }
  ids <- unique(v$lab_sample_id)
  has_result <- ids %in% vapply(rows, function(r) r$lab_sample_id, "")
  smp <- lapply(ids[has_result], function(id) {
    k <- match(id, v$lab_sample_id)
    tibble::tibble(
      source_hash = fh, source_ref = id, work_order = f$report_no, org = "ACIRL", adapter = tag, lab_sample_id = id,
      feature_raw = v$feature_raw[[k]], sample_datetime_raw = v$sample_datetime_raw[[k]],
      sample_date_start_raw = NA_character_, sample_type = "Normal", parent_sample = NA_character_,
      matrix_raw = "Water", sampler = NA_character_,
      comments = if (is.null(obs[[id]])) NA_character_ else obs[[id]]$text, confidence = 1)
  })
  results <- if (length(rows)) do.call(ir_results, as.list(dplyr::bind_rows(rows))) else ir_results()
  samples <- if (length(smp)) do.call(ir_samples, as.list(dplyr::bind_rows(smp))) else ir_samples()
  wo <- if (is.na(f$als_work_order)) character(0) else strsplit(f$als_work_order, ";", fixed = TRUE)[[1]]
  list(
    results = results, samples = samples,
    report = list(
      n_rows = nrow(results) + nrow(samples), n_by_sample_type = table(results$sample_type),
      skipped = if (length(skipped)) dplyr::bind_rows(skipped) else
        tibble::tibble(source_ref = character(0), reason = character(0)),
      header = list(report_no = f$report_no, sampled_by = NA_character_,
                    sample_date = strsplit(f$sample_days, ";", fixed = TRUE)[[1]][[1]]),
      warnings = character(0), als_work_orders = wo, n_water_sheets = 1L,
      als_candidates = tibble::tibble(source_ref = character(0), feature_raw = character(0),
                                      analyte_raw = character(0), units_raw = character(0),
                                      value_raw = character(0), transcription_label = logical(0)),
      feature_aliases = tibble::tibble(source_ref = character(0), feature_raw = character(0),
                                       label = character(0), alias = character(0))))
}

mig089_adapter <- function(inp) {
  tag <- paste0(.mig089_adapter_id, "/", .mig089_adapter_version)
  by_hash <- split(inp$values, inp$values$hash)
  list(id = .mig089_adapter_id, version = .mig089_adapter_version,
       match = function(file_meta) if (isTRUE(file_meta$hash %in% inp$files$hash)) "exact" else "no",
       parse = function(path, file_meta) {
         if (!isTRUE(file_meta$hash %in% inp$files$hash)) .mig089_fail("parse() called on an unplanned file.")
         .mig089_parse_one(file_meta$hash, inp$files, by_hash[[file_meta$hash]], tag)
       })
}

# What the adapter emits for every file (no DB): the parse dry run.
mig089_parse_all <- function(inp) {
  ad <- mig089_adapter(inp)
  out <- lapply(inp$files$hash, function(h) ad$parse(NA_character_, list(hash = h)))
  names(out) <- inp$files$hash
  out
}

# ---- phase A: aliases + feature date_start ---------------------------------------

.mig089_uuid <- function(...) {
  d <- digest::digest(paste(c(.mig089_marker_version, ...), collapse = "\u001f"), algo = "md5", serialize = FALSE)
  paste(substr(d, 1, 8), substr(d, 9, 12), paste0("4", substr(d, 14, 16)),
        paste0("8", substr(d, 18, 20)), substr(d, 21, 32), sep = "-")
}

mig089_plan_registry <- function(con, inp) {
  feat <- DBI::dbGetQuery(con, sprintf("SELECT uuid, name, date_start, comments FROM feature WHERE name IN %s",
                                       .mig089_inlist(.mig089_bores$feature)))
  if (nrow(feat) != nrow(.mig089_bores)) .mig089_fail("K.MW01-04 do not all exist exactly once.")
  a <- inp$alias
  a$feature <- .mig089_bores$feature[match(as.integer(a$mp), .mig089_bores$mp)]
  a$uuid_feature <- feat$uuid[match(a$feature, feat$name)]
  a$alias_key <- .rc_feature_key(a$name)
  a$uuid <- mapply(.mig089_uuid, a$alias_key, a$feature, a$date_start, a$date_end, USE.NAMES = FALSE)
  a$comments <- sprintf("089: ACIRL MP bore history %s..%s (MP %s = %s, checked against ACIRL 24006990-08)",
                        a$date_start, a$date_end, a$mp, a$feature)
  first <- tapply(.mig089_day_of(inp$values$sample_datetime_raw), inp$values$mp, min)
  fd <- data.frame(feature = .mig089_bores$feature, mp = .mig089_bores$mp, stringsAsFactors = FALSE)
  fd$uuid <- feat$uuid[match(fd$feature, feat$name)]
  fd$old_start <- as.Date(feat$date_start[match(fd$feature, feat$name)])
  fd$new_start <- as.Date(unname(first[as.character(fd$mp)]), origin = "1970-01-01")
  fd$old_comments <- feat$comments[match(fd$feature, feat$name)]
  fd$new_comments <- paste0(fd$old_comments, sprintf(
    "; 089: date_start moved back from %s to %s for the ACIRL MP bore history (first sampled Nov 2012; installed Sep 2010).",
    fd$old_start, fd$new_start))
  list(alias = a, feature = fd)
}

.mig089_alias_rows <- function(a) {
  tibble::tibble(
    uuid = a$uuid, uuid_feature = a$uuid_feature, name = a$name, alias_key = a$alias_key, kind = "descriptive",
    n_seen = 0L, auto_assign = TRUE,
    first_seen = as.POSIXct(rep(NA_real_, nrow(a)), origin = "1970-01-01", tz = "UTC"),
    last_seen = as.POSIXct(rep(NA_real_, nrow(a)), origin = "1970-01-01", tz = "UTC"),
    confirmed_by = .mig089_confirmed_by, comments = a$comments,
    date_start = as.Date(a$date_start), date_end = as.Date(a$date_end))
}

# Problems that stop phase A: an arm of the same key overlapping the window to
# another feature, or an existing row with the planned uuid that differs.
mig089_registry_problems <- function(con, plan) {
  pr <- character(0)
  a <- plan$alias
  for (i in seq_len(nrow(a))) {
    hit <- DBI::dbGetQuery(con, "SELECT uuid, uuid_feature, date_start, date_end, auto_assign FROM feature_alias
      WHERE alias_key = ? AND (date_start IS NULL OR date_start <= ?) AND (date_end IS NULL OR date_end >= ?)",
      params = list(a$alias_key[[i]], as.Date(a$date_end[[i]]), as.Date(a$date_start[[i]])))
    hit <- hit[hit$uuid != a$uuid[[i]], , drop = FALSE]
    if (nrow(hit)) pr <- c(pr, sprintf("alias '%s' %s..%s overlaps existing arm(s) %s", a$name[[i]], a$date_start[[i]],
                                       a$date_end[[i]], paste(substr(hit$uuid, 1, 8), collapse = ",")))
  }
  fd <- plan$feature
  if (any(is.na(fd$new_start))) pr <- c(pr, "a bore has no imported day")
  pr
}

.mig089_registry_done <- function(con, plan) {
  a <- plan$alias
  have <- DBI::dbGetQuery(con, sprintf("SELECT uuid, uuid_feature, alias_key, date_start, date_end FROM feature_alias
                                        WHERE uuid IN %s", .mig089_inlist(a$uuid)))
  feat_ok <- DBI::dbGetQuery(con, sprintf("SELECT name, date_start FROM feature WHERE name IN %s",
                                          .mig089_inlist(plan$feature$feature)))
  list(n_alias = nrow(have),
       feature_moved = all(as.Date(feat_ok$date_start[match(plan$feature$feature, feat_ok$name)]) <=
                             plan$feature$new_start))
}

mig089_apply_registry <- function(con, plan, logf) {
  db_transaction(con, function(con) {
    done <- .mig089_registry_done(con, plan)
    todo <- plan$alias[!plan$alias$uuid %in% DBI::dbGetQuery(con, sprintf(
      "SELECT uuid FROM feature_alias WHERE uuid IN %s", .mig089_inlist(plan$alias$uuid)))$uuid, , drop = FALSE]
    if (nrow(todo)) db_append(con, "feature_alias", .mig089_alias_rows(todo), actor = .mig089_actor,
                              reason = "089: MP bore history aliases")
    fd <- plan$feature
    for (i in seq_len(nrow(fd))) {
      cur <- as.Date(DBI::dbGetQuery(con, "SELECT date_start FROM feature WHERE uuid = ?", params = list(fd$uuid[[i]]))[[1]])
      if (!is.na(cur) && cur <= fd$new_start[[i]]) next
      db_update(con, "feature", uuid = fd$uuid[[i]],
                changes = list(date_start = fd$new_start[[i]], comments = fd$new_comments[[i]]),
                actor = .mig089_actor, reason = "089: MP bore history - date_start covers the imported samples")
    }
    logf("Phase A: %d alias arm(s) inserted (%d already present); feature date_start set.", nrow(todo),
         nrow(plan$alias) - nrow(todo))
    NULL
  })
}

# ---- phase B: the import --------------------------------------------------------

mig089_stage <- function(inp, files_dir, inbox) {
  if (dir.exists(inbox) && length(list.files(inbox, all.files = TRUE, no.. = TRUE)))
    .mig089_fail(sprintf("staging inbox %s is not empty.", inbox))
  dir.create(inbox, recursive = TRUE, showWarnings = FALSE)
  for (i in seq_len(nrow(inp$files))) {
    src <- file.path(files_dir, inp$files$staged_name[[i]])
    if (!file.exists(src)) .mig089_fail(sprintf("source file %s not found.", src))
    if (!identical(hash_file(src), inp$files$hash[[i]])) .mig089_fail(sprintf("%s: hash differs from INPUT.", src))
    dest <- file.path(inbox, inp$files$staged_name[[i]])
    if (!file.copy(src, dest, copy.date = TRUE)) .mig089_fail(sprintf("could not stage %s.", src))
    if (!identical(hash_file(dest), inp$files$hash[[i]])) .mig089_fail(sprintf("%s: staged copy differs.", dest))
  }
  invisible(inbox)
}

mig089_import <- function(db, inp, inbox, archive_dir, snapshot_dir, logf, dry_run = FALSE) {
  withr::local_options(sampletidy.archive_dir = archive_dir, sampletidy.snapshot_dir = snapshot_dir,
                       sampletidy.remove_ingested = FALSE, sampletidy.input_dir = inbox)
  if (!identical(st_config("archive_dir"), archive_dir) || isTRUE(as.logical(st_config("remove_ingested"))))
    .mig089_fail("the import configuration did not take.")
  register_adapter(mig089_adapter(inp))
  on.exit({ clear_adapters(); register_builtin_adapters() }, add = TRUE)
  rep <- ingest_dir(inbox, db = db, dry_run = dry_run)
  logf("Phase B: ingest_dir(dry_run = %s): events %s, committed %s, failed %s, rows new %s, already %s, skipped %s, review %s",
       dry_run, rep$n_events, rep$n_events_committed, rep$events_failed, rep$rows_new, rep$rows_already_present,
       rep$rows_skipped, rep$review_items_opened)
  rep
}

# ---- phase C: TRIM filing adoption + marker ---------------------------------------

mig089_filing_plan <- function(con, inp, trim) {
  a <- DBI::dbGetQuery(con, sprintf("SELECT a.uuid, a.hash, a.filename FROM asset a WHERE a.hash IN %s",
                                    .mig089_inlist(inp$files$hash)))
  if (nrow(a) != nrow(inp$files) || anyDuplicated(a$hash)) .mig089_fail("each imported PDF must be exactly one asset.")
  x <- merge(trim, a, by = "hash")
  x[match(inp$files$hash, x$hash), , drop = FALSE]
}

mig089_apply_filing <- function(con, plan, recorded_at, logf) {
  db_transaction(con, function(con) {
    res <- vapply(seq_len(nrow(plan)), function(i) {
      register_filing(con, uuid_asset = plan$uuid[[i]], system = .mig089_trim_system,
                      external_id = plan$trim_record[[i]], external_uri = plan$trim_uri[[i]],
                      container = plan$container[[i]],
                      filed_at = as.POSIXct(paste(plan$record_date[[i]], "00:00:00"), tz = "Australia/Sydney"),
                      title = plan$title[[i]],
                      comments = "089: already in TRIM before the import (adopted; never file again)")
    }, character(1))
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig089_marker_version, recorded_at))
    logf("Phase C: filings %s; marker %d.", paste(names(table(res)), table(res), sep = "=", collapse = ", "),
         .mig089_marker_version)
    res
  })
}

# ---- verification -------------------------------------------------------------------

.mig089_counts <- function(con) {
  tabs <- c("feature", "feature_alias", "analyte", "lab_method", "analysis", "sample", "project", "asset",
            "review_queue", "ingest_file", "change_log", "schema_version")
  if ("asset_filing" %in% DBI::dbListTables(con)) tabs <- c(tabs, "asset_filing")
  stats::setNames(vapply(tabs, function(t) .mig089_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t)), 0L), tabs)
}

# Content digest of everything that existed before the import: existing samples
# and analyses must not change (no merge into, no supersession of, old rows).
.mig089_existing_digest <- function(con, sample_uuids) {
  s <- DBI::dbGetQuery(con, sprintf("SELECT * FROM sample WHERE uuid IN (SELECT uuid FROM sample) AND uuid IN %s ORDER BY uuid",
                                    .mig089_inlist(sample_uuids)))
  digest::digest(s, algo = "sha1")
}

# After the import: the new rows, by content (uuids differ run to run).
mig089_new_rows <- function(con, before_samples) {
  DBI::dbExecute(con, "CREATE OR REPLACE TEMP TABLE m089_old (uuid VARCHAR)")
  DBI::dbAppendTable(con, "m089_old", data.frame(uuid = before_samples, stringsAsFactors = FALSE))
  DBI::dbGetQuery(con, sprintf("
    SELECT f.name AS feature, fa.name AS alias, %s AS day, s.datetime, s.organisation, p.name AS project,
           pp.name AS parent, lm.name AS lab_method, lm.method, an.name AS analyte, a.value, a.value_chr,
           a.quantified, s.comments AS sample_comments
    FROM sample s JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias LEFT JOIN feature f ON f.uuid = fa.uuid_feature
    LEFT JOIN project p ON p.uuid = s.uuid_project LEFT JOIN project pp ON pp.uuid = p.uuid_parent
    LEFT JOIN analysis a ON a.uuid_sample = s.uuid LEFT JOIN lab_method lm ON lm.uuid = a.uuid_lab
    LEFT JOIN analyte an ON an.uuid = lm.uuid_analyte
    WHERE s.uuid NOT IN (SELECT uuid FROM m089_old)
    ORDER BY feature, day, lab_method, a.value, a.value_chr", .mig089_syd("coalesce(s.date, s.datetime)")))
}

mig089_verify_import <- function(con, inp, parsed, before_samples) {
  pr <- character(0)
  st <- DBI::dbGetQuery(con, sprintf("SELECT hash, state, state_reason, adapter, uuid_asset FROM ingest_file WHERE hash IN %s",
                                     .mig089_inlist(inp$files$hash)))
  if (nrow(st) != nrow(inp$files) || !all(st$state == "archived"))
    pr <- c(pr, sprintf("not every PDF is archived: %s", paste(unique(paste(st$state, st$state_reason)), collapse = "; ")))
  na <- .mig089_scalar(con, sprintf("SELECT COUNT(*) FROM asset WHERE hash IN %s", .mig089_inlist(inp$files$hash)))
  if (na != nrow(inp$files)) pr <- c(pr, sprintf("%d asset rows for %d PDFs", na, nrow(inp$files)))
  nr <- mig089_new_rows(con, before_samples)
  bad_feat <- setdiff(unique(nr$feature), .mig089_bores$feature)
  if (length(bad_feat)) pr <- c(pr, sprintf("new samples at other features: %s", paste(bad_feat, collapse = ", ")))
  want_days <- unique(format(.mig089_day_of(inp$values$sample_datetime_raw)))
  if (!all(format(nr$day) %in% want_days)) pr <- c(pr, "a new sample is on a day not in INPUT")
  n_emitted <- sum(vapply(parsed, function(p) nrow(p$results), 0L))
  n_new <- sum(!is.na(nr$lab_method))
  if (n_new != n_emitted) pr <- c(pr, sprintf("%d new analyses, %d rows emitted", n_new, n_emitted))
  list(problems = pr, new_rows = nr)
}

# ---- backup ------------------------------------------------------------------------

mig089_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- if (is.null(.now)) Sys.time() else .now
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig089_name,
                                          format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")))
  n0 <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    n <- .mig089_counts(con)
    if (!isTRUE(file.copy(db, dest, overwrite = FALSE))) .mig089_fail(sprintf("could not write backup %s", dest))
    n
  }, db = db)
  v <- DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE)
  on.exit(DBI::dbDisconnect(v, shutdown = TRUE), add = TRUE)
  if (!identical(n0, .mig089_counts(v))) .mig089_fail("backup verification failed: counts differ.")
  dest
}

.mig089_write_csv <- function(df, path) {
  utils::write.csv(df, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, colClasses = "character", na.strings = "", encoding = "UTF-8")
  if (nrow(back) != nrow(df)) .mig089_fail(sprintf("CSV %s did not round-trip.", basename(path)))
}

# ---- run -------------------------------------------------------------------------------

mig089_run <- function(db, snapshot_dir, archive_dir, work_dir, files_dir, trim_csv, dry_run = FALSE,
                       csv_dir = "dev/migrations", input_dir = "dev/migrations", requires = .mig089_requires,
                       .now = NULL) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", basename(db), sprintf(fmt, ...)))
  checkmate::assert_directory_exists(archive_dir)
  checkmate::assert_directory_exists(snapshot_dir)
  checkmate::assert_directory_exists(csv_dir)
  inp <- mig089_read_inputs(input_dir)
  trim <- mig089_read_trim(trim_csv, inp$files)
  parsed <- mig089_parse_all(inp)
  logf("Inputs: %d PDF(s), %d transcribed cell(s), %d alias arm(s); adapter emits %d result row(s), %d sample(s).",
       nrow(inp$files), nrow(inp$values), nrow(inp$alias), sum(vapply(parsed, function(p) nrow(p$results), 0L)),
       sum(vapply(parsed, function(p) nrow(p$samples), 0L)))

  con <- st_connect(db, read_only = TRUE)
  st <- tryCatch({
    have <- DBI::dbGetQuery(con, "SELECT version FROM schema_version")$version
    if (!all(requires %in% have)) .mig089_fail(sprintf("marker %s required first.", paste(requires, collapse = ", ")))
    list(done = .mig089_marker_version %in% have, plan = mig089_plan_registry(con, inp),
         before_samples = DBI::dbGetQuery(con, "SELECT uuid FROM sample")$uuid,
         assets = DBI::dbGetQuery(con, sprintf("SELECT hash FROM asset WHERE hash IN %s", .mig089_inlist(inp$files$hash)))$hash,
         counts = .mig089_counts(con))
  }, finally = DBI::dbDisconnect(con, shutdown = TRUE))

  if (st$done) {
    con <- st_connect(db, read_only = TRUE)
    on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
    fp <- mig089_filing_plan(con, inp, trim)
    f <- DBI::dbGetQuery(con, sprintf("SELECT uuid_asset, external_id FROM asset_filing WHERE system = '%s' AND uuid_asset IN %s",
                                      .mig089_trim_system, .mig089_inlist(fp$uuid)))
    if (nrow(f) != nrow(fp) || !identical(f$external_id[match(fp$uuid, f$uuid_asset)], fp$trim_record))
      .mig089_fail("re-verify: filing rows are not as planned.")
    logf("089 already applied; re-verified; nothing to do.")
    return(invisible(list(status = "already_migrated")))
  }

  con <- st_connect(db, read_only = TRUE)
  pr <- tryCatch(mig089_registry_problems(con, st$plan), finally = DBI::dbDisconnect(con, shutdown = TRUE))
  if (length(pr)) .mig089_fail(paste(pr, collapse = "; "))
  if (length(st$assets)) logf("note: %d of the PDFs are already assets (a re-run after phase B).", length(st$assets))
  logf("Plan: %d alias arm(s); date_start %s.", nrow(st$plan$alias),
       paste(sprintf("%s %s->%s", st$plan$feature$feature, st$plan$feature$old_start, st$plan$feature$new_start), collapse = ", "))
  if (isTRUE(dry_run)) {
    logf("DRY RUN: inputs, parse and registry preconditions checked. Nothing written.")
    return(invisible(list(status = "dry_run", parsed = parsed, plan = st$plan)))
  }

  # backups: the alias/feature rows that change, then the whole-file backup
  con <- st_connect(db, read_only = TRUE)
  tryCatch({
    .mig089_write_csv(DBI::dbGetQuery(con, sprintf("SELECT * FROM feature WHERE name IN %s",
                                                   .mig089_inlist(.mig089_bores$feature))),
                      .mig089_csv_path(csv_dir, "BACKUP-feature"))
  }, finally = DBI::dbDisconnect(con, shutdown = TRUE))
  backup_path <- mig089_backup(db, snapshot_dir, .now)
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: cp %s %s (and remove the new <archive_dir>/<uuid>/ dirs listed in the BACKUP-assets CSV)",
       shQuote(backup_path), shQuote(db))
  recorded_at <- if (is.null(.now)) Sys.time() else .now

  with_db_write(function(con) mig089_apply_registry(con, st$plan, logf), db = db)
  .mig089_write_csv(as.data.frame(.mig089_alias_rows(st$plan$alias)), .mig089_csv_path(csv_dir, "INSERTED-feature_alias"))

  inbox <- file.path(work_dir, "inbox")
  unlink(inbox, recursive = TRUE)
  mig089_stage(inp, files_dir, inbox)
  rep <- mig089_import(db, inp, inbox, archive_dir, snapshot_dir, logf)

  con <- st_connect(db, read_only = TRUE)
  ver <- tryCatch(mig089_verify_import(con, inp, parsed, st$before_samples),
                  finally = DBI::dbDisconnect(con, shutdown = TRUE))
  .mig089_write_csv(ver$new_rows, file.path(work_dir, sprintf("%s-NEW-rows.csv", .mig089_name)))
  if (length(ver$problems)) .mig089_fail(paste0("import verify: ", paste(ver$problems, collapse = "; "),
                                                ". Restore from ", backup_path))

  res <- with_db_write(function(con) {
    fp <- mig089_filing_plan(con, inp, trim)
    out <- mig089_apply_filing(con, fp, recorded_at, logf)
    fp$result <- out
    fp
  }, db = db)
  con <- st_connect(db, read_only = TRUE)
  tryCatch(.mig089_write_csv(DBI::dbGetQuery(con, sprintf(
    "SELECT a.uuid, a.filename, a.hash, p.name AS project FROM asset a LEFT JOIN project p ON p.uuid = a.uuid_project
      WHERE a.hash IN %s ORDER BY a.filename", .mig089_inlist(inp$files$hash))), .mig089_csv_path(csv_dir, "BACKUP-assets")),
    finally = DBI::dbDisconnect(con, shutdown = TRUE))
  logf("%s migrated successfully (marker %d).", .mig089_name, .mig089_marker_version)
  invisible(list(status = "migrated", backup_path = backup_path, report = rep, new_rows = ver$new_rows,
                 filings = res))
}
