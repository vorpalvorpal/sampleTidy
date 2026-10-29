# Operator-run migration: import the Katoomba WMF landfill-gas readings (CH4 % v/v)
# printed in the same ACIRL PDF reports that 089 and 090 imported the water
# results from (Nov 2012 - May 2020), which no package adapter reads. Marker 1092.
# Requires 1090.
# Authority: Robin, 2026-10-29 ("Import the gas data too", after 090).
#
# ---- WHAT THE REPORTS PRINT -----------------------------------------------------
# Every reading is methane only, "CH4 Reading % v/v", taken in the field by ACIRL
# (the reports list "CH4 Readings" among the tests NATA does not cover). No CO2,
# O2, H2S, CO, balance gas, pressure or flow is printed anywhere in these PDFs.
#   * 16 whole-site reports (Aug 2015 - May 2020: the 15 that 089 holds and that
#     090 re-imported, plus the Nov 2016 quarterly 090 added) print four gas
#     tables on 4-5 pages after the water tables:
#       - "Landfill | Site Reference G1..G25" (the landfill surface grid);
#       - "Location | Building Reference" (95 points in the site buildings);
#       - "BIOFILTER CH4 Reading" - two 2 x 3 grids, the first beside "North
#         Corner", the second beside "Front of Buildings";
#       - "GAS MONITORING BORES": Gas Bore MP1..MP4.
#   * 8 MP bore reports (Nov 2012 - May 2015; held by 089 only) print "AIR
#     EMISSIONS / MONITORING-SURFACE METHANE %(v/v)" at MP1..MP4, and four of
#     them a biofilter table (Nov 2012 a 3 x 3 grid, Sep 2014 four named corners,
#     Nov 2014 and May 2015 a 4 x 3 grid beside "North Corner" over "Building").
#   * The Nov 2016 "Additional" report (24005840-02) prints no gas; not used.
# 10 whole-site reports and all 8 MP reports have a text layer (pdftotext -layout,
# each chunk assigned to the nearest header column). Six whole-site reports are
# scanned; their 29 gas pages were each read twice, independently, from 200 dpi
# images and the two readings reconciled (INPUT-files `note`).
#
# ---- POINT IDENTITY (one table, INPUT-points: printed name -> feature) ----------
# The adapter names each point exactly as the package's ACIRL gas-workbook adapter
# (acirl_gas_xlsx) does for the same template, so the existing registry resolves it:
#   * G1..G24 -> "K.G1".."K.G24" -> the old Katoomba surface grid K.G01..K.G24
#     (date_end 2022-01-01, the day before the successor grid K.G026+ starts).
#     K.G1..K.G9 resolve through 041's transcription_error aliases (window ends
#     2022-01-01), K.G10..K.G24 through their self aliases. The registry holds no
#     K.G15, K.G19, K.G20 or K.G25: those readings are transcribed but NOT
#     imported (feature blank in INPUT-points; no feature is invented). G25 prints
#     "NP" ("No point on map") in most reports.
#   * Building rows -> "K.<Location> - <Reference>" (a repeated reference within a
#     report gets " #2", as the workbook adapter numbers it) -> K.G379..K.G473,
#     the 95 points 028 registered from the same ACIRL template with exactly these
#     descriptive aliases. One printed spelling differs ("Toilet 1 - Drair near
#     lockers" for "Drain near lockers"): INPUT-alias gives it a bounded arm to
#     K.G395, as 090 added arms for its printed names.
#   * Biofilter -> "K.Biofilter North Corner R<r>C<c>" / "K.Front of Buildings
#     R<r>C<c>" -> K.G367..K.G378 (014's aliases; the workbook adapter's grid
#     naming: first grid North Corner, second Front of Buildings, columns left to
#     right). The Nov 2014 and May 2015 4 x 3 tables (North Corner over Building)
#     are read as the same two grids, rows 1-2 and 3-4. The Nov 2012 3 x 3 grid
#     and the Sep 2014 named corners fit no registered point: transcribed, not
#     imported.
#   * Gas Bore MP<n> and the 2012-15 "surface methane" at MP<n> -> "K.MP_<n>" ->
#     K.MW0<n> through the existing historical_code aliases K.MP_1..K.MP_4, which
#     the live ACIRL gas workbooks already use for the same bores (CH4 at
#     K.MW01-04 from 2023). The Nov 2012 report gives MP1-4 coordinates that are
#     K.MW01-04's (089).
#
# ---- WHAT THIS IMPORTS, AND HOW ----------------------------------------------------
# One sample per point per report: matrix Gas, organisation ACIRL, the report's
# project (made by 089/090, found again), dated the report's sampling day (the
# gas pages print no date; INPUT-files `sample_day` is the day 089/090 used for
# the same report, the main round for the Aug 2018 report). One analysis each:
# lab_method "CH4 Reading % v/v" (field, ACIRL), units %, value as printed
# ("<x" censored; ">x" censored high), stored in L/L (CH4's canonical unit) as
# every acirl_gas_xlsx reading is. A bare zero ("0", "0.00", "0.0000") is emitted
# as "0" with the method's limit (0.01 % = lab_method rl_low 1e-4 L/L) and the
# adapter declares zero_is_nondetect, exactly as acirl_gas_xlsx zeros are stored
# (A89 / PLAN-17 ruling 1: the analyser's zero is "below what it can see").
# Text cells (NP, No Access, NA, Padlocked, NO ACCESS, a machine note) and blank
# cells are not reported and make no sample.
#
# The import goes through ingest_dir() as 089 and 090 did: an OPERATOR adapter
# (`acirl_pdf_092`, defined here, registered for this run only) claims exactly the
# frozen PDFs by hash. The 24 PDFs are `archived` (16 by acirl_pdf_090, 8 by
# acirl_pdf_089), a terminal state; Phase B0 resets each to `seen` with
# ingest_file_set_state(reset = TRUE) - the router's own reset, as 040 and 090 did -
# writing two change_log rows each. archive_file() dedupes on hash, so each PDF
# keeps its asset and its TRIM filing; nothing is copied or filed again (Phase C
# only verifies that every asset already has its trim filing). 089's and 090's
# samples and analyses are untouched.
#
# Scope rules: only readings NOT already in the database. The CHECK and the run
# refuse if a planned point already holds a CH4 reading on a planned day
# (092-kat-gas-DISCREPANCIES.csv compares any such overlap). INPUT-corrections holds
# the printed cells changed before parsing, each with its reason; a value may
# only be withheld ("_"), never replaced.
#
# ---- PHASES --------------------------------------------------------------------
# A (one transaction): the INPUT-alias arms (bounded to the history window, so
#   they never overlap another feature's arm) and date_start moved back on any
#   mapped feature that starts after its first imported day (none at the time of
#   writing).
# B0 (one transaction): reset the 24 PDFs' ingest_file rows archived -> seen.
# B: ingest_dir() of a staging inbox holding exactly the frozen PDFs, adapter
#   registered, remove_ingested FALSE. Verified after: every PDF archived by
#   acirl_pdf_092 with exactly one asset; new samples only at mapped features on
#   planned days; new analyses = the adapter's emitted result rows; no existing
#   sample or analysis changed.
# C (one transaction): every PDF's asset already has a trim filing (089/090);
#   marker 1092.
#
# Idempotent: marker present -> re-verify, no-op. A run stopped after A, B0 or B
# can be re-run: A skips arms already present, B0 resets only rows still archived
# by 089's or 090's adapter, B is a no-op for archived files.
#
#   devtools::load_all(".")
#   env <- new.env()
#   sys.source("dev/migrations/092-kat-gas.R", envir = env)
#   env$mig092_run(db = st_config("live_db"), snapshot_dir = ..., archive_dir = st_config("archive_dir"),
#                  work_dir = ..., files_root = "dev/migrations", dry_run = TRUE)

.mig092_marker_version <- 1092L
.mig092_requires <- 1090L
.mig092_name <- "092-kat-gas"
.mig092_actor <- .mig092_name
.mig092_adapter_id <- "acirl_pdf_092"
.mig092_adapter_version <- "1"
.mig092_prior_adapters <- c("acirl_pdf_089", "acirl_pdf_090")
.mig092_confirmed_by <- "R. Shannon"
.mig092_trim_system <- "trim"
.mig092_analyte_raw <- "CH4 Reading % v/v"
.mig092_units_raw <- "%"
# CH4's canonical unit is L/L (analyte.units), so the pipeline stores a % v/v
# reading divided by 100, as it does every acirl_gas_xlsx reading.
.mig092_to_canonical <- 0.01
# A zero's limit, in % v/v: lab_method "CH4 Reading % v/v" rl_low 1e-4 L/L. The
# commit step gives acirl_gas_xlsx zeros exactly this limit (PLAN-17 ruling 1,
# keyed on that adapter's id); the operator adapter states it so these zeros are
# stored as the existing 17,400 are (quantified FALSE, rl_low 1e-4).
.mig092_zero_rl <- 0.01

.mig092_files_cols <- c("hash", "staged_name", "source_dir", "report_no", "sample_day", "prior_adapter", "pages",
                        "n_values", "note")
.mig092_values_cols <- c("hash", "source_ref", "section", "location", "reference", "value_raw")
.mig092_points_cols <- c("feature_raw", "feature", "evidence")
.mig092_alias_cols <- c("name", "feature", "date_start", "date_end")
.mig092_corr_cols <- c("hash", "source_ref", "field", "printed", "corrected", "reason")
.mig092_sections <- c("grid", "building", "biofilter", "biofilter_other", "bore")

.mig092_fail <- function(msg) cli::cli_abort(paste0(.mig092_name, ": ", msg), class = "sampletidy_error")
.mig092_scalar <- function(con, sql, ...) {
  as.integer(DBI::dbGetQuery(con, sql, params = if (length(list(...))) list(...) else NULL)[[1]][[1]])
}
.mig092_inlist <- function(x) if (!length(x)) "('')" else paste0("(", paste0("'", gsub("'", "''", unique(x)), "'", collapse = ","), ")")
.mig092_syd <- function(col) sprintf("CAST((%s AT TIME ZONE 'UTC') AT TIME ZONE 'Australia/Sydney' AS DATE)", col)
.mig092_csv_path <- function(dir, what) file.path(dir, sprintf("%s-%s.csv", .mig092_name, what))
.mig092_read <- function(p, cols) {
  if (!file.exists(p)) .mig092_fail(sprintf("input %s not found.", p))
  x <- utils::read.csv(p, colClasses = "character", na.strings = "", encoding = "UTF-8")
  if (!identical(names(x), cols)) .mig092_fail(sprintf("%s: columns are not as planned.", basename(p)))
  x
}

# The name the adapter emits for a printed cell: acirl_gas_xlsx's naming for the
# same ACIRL template (site prefix K.). `values` must be in source_ref order
# within each file, so a repeated building reference gets " #2" on its second
# printing, as the workbook adapter numbers it.
.mig092_feature_raw <- function(values) {
  fr <- with(values, ifelse(
    section == "grid", paste0("K.", reference), ifelse(
    section == "bore", paste0("K.MP_", sub("^MP\\s*", "", reference)), ifelse(
    section == "biofilter", paste0("K.", location, " ", reference), ifelse(
    section == "biofilter_other", paste0("K.Biofilter ", location, " ", reference),
    paste0("K.", location, " - ", reference))))))
  b <- values$section == "building"
  n <- stats::ave(seq_along(fr), values$hash, fr, FUN = seq_along)
  fr[b & n > 1] <- paste0(fr[b & n > 1], " #", n[b & n > 1])
  fr
}

# source_ref "p<page>!r<row>" (row = printed order on the page)
.mig092_ref_order <- function(ref) {
  pg <- as.integer(sub("^p([0-9]+)!.*$", "\\1", ref))
  rw <- as.integer(sub("^p[0-9]+!r([0-9]+)$", "\\1", ref))
  order(pg, rw)
}

# ---- inputs ----------------------------------------------------------------------

mig092_read_inputs <- function(input_dir = "dev/migrations") {
  files <- .mig092_read(.mig092_csv_path(input_dir, "INPUT-files"), .mig092_files_cols)
  values <- .mig092_read(.mig092_csv_path(input_dir, "INPUT-values"), .mig092_values_cols)
  points <- .mig092_read(.mig092_csv_path(input_dir, "INPUT-points"), .mig092_points_cols)
  alias <- .mig092_read(.mig092_csv_path(input_dir, "INPUT-alias"), .mig092_alias_cols)
  corr <- .mig092_read(.mig092_csv_path(input_dir, "INPUT-corrections"), .mig092_corr_cols)
  if (anyNA(files[, c("hash", "staged_name", "source_dir", "report_no", "sample_day", "prior_adapter")]) ||
      anyDuplicated(files$hash) || anyDuplicated(files$staged_name))
    .mig092_fail("INPUT-files misses or repeats a hash, name, directory, report number, day or prior adapter.")
  if (!all(files$prior_adapter %in% .mig092_prior_adapters)) .mig092_fail("INPUT-files names an unexpected prior adapter.")
  if (!all(grepl("^[0-9]{8}(-[0-9A-Z]+)?$", files$report_no))) .mig092_fail("INPUT-files holds a malformed report number.")
  if (anyNA(as.Date(files$sample_day, format = "%Y-%m-%d"))) .mig092_fail("INPUT-files holds a malformed sample_day.")
  if (anyNA(values[, c("hash", "source_ref", "section", "location", "reference")]))
    .mig092_fail("INPUT-values misses a required value.")
  if (!all(grepl("^p[0-9]+!r[0-9]+$", values$source_ref))) .mig092_fail("INPUT-values holds a malformed source_ref.")
  if (!all(values$section %in% .mig092_sections)) .mig092_fail("INPUT-values holds an unknown section.")
  if (!all(values$hash %in% files$hash) || !all(files$hash %in% values$hash))
    .mig092_fail("INPUT-values and INPUT-files do not name the same files.")
  if (anyDuplicated(values[, c("hash", "source_ref")])) .mig092_fail("INPUT-values repeats a source_ref.")
  # printed order within each file, files in INPUT-files order
  values <- do.call(rbind, lapply(split(values, factor(values$hash, levels = files$hash)), function(v)
    v[.mig092_ref_order(v$source_ref), , drop = FALSE]))
  rownames(values) <- NULL
  values <- .mig092_correct(values, corr)
  values$feature_raw <- .mig092_feature_raw(values)
  n_by_file <- table(factor(values$hash, levels = files$hash))
  if (!identical(as.integer(n_by_file), as.integer(files$n_values)))
    .mig092_fail("INPUT-files n_values does not match INPUT-values.")
  points$feature[is.na(points$feature)] <- ""
  if (anyNA(points$feature_raw) || anyDuplicated(points$feature_raw) || anyNA(points$evidence))
    .mig092_fail("INPUT-points misses or repeats a printed name.")
  unmapped <- setdiff(unique(values$feature_raw), points$feature_raw)
  if (length(unmapped)) .mig092_fail(sprintf("printed name(s) not in INPUT-points: %s", paste(unmapped, collapse = "; ")))
  if (any(grepl("^(K|B)\\.J", points$feature))) .mig092_fail("INPUT-points names an excluded point.")
  if (any(nzchar(points$feature) & !grepl("^K\\.", points$feature))) .mig092_fail("INPUT-points maps outside Katoomba.")
  if (anyNA(alias) || anyDuplicated(paste(.rc_feature_key(alias$name), alias$date_start)))
    .mig092_fail("INPUT-alias misses or repeats a value.")
  if (!identical(alias$feature, points$feature[match(alias$name, points$feature_raw)]))
    .mig092_fail("INPUT-alias maps a name to a feature other than INPUT-points does.")
  if (any(as.Date(alias$date_start) > as.Date(alias$date_end))) .mig092_fail("INPUT-alias has start > end.")
  list(files = files, values = values, points = points, alias = alias, corrections = corr)
}

# A correction applies to the one cell (hash, source_ref) whose `field` equals
# `printed` (NA = empty); one that matches no cell aborts the run. A value may only
# be withheld (value_raw -> "_"), never replaced.
.mig092_correct <- function(values, corr) {
  if (anyNA(corr[, c("hash", "source_ref", "field", "corrected", "reason")])) .mig092_fail("INPUT-corrections misses a value.")
  if (!all(corr$field == "value_raw") || any(corr$corrected != "_"))
    .mig092_fail("INPUT-corrections may only withhold a printed value (value_raw -> _).")
  for (i in seq_len(nrow(corr))) {
    c1 <- corr[i, ]
    cur <- values[[c1$field]]
    hit <- values$hash == c1$hash & values$source_ref == c1$source_ref &
      (if (is.na(c1$printed)) is.na(cur) else (!is.na(cur) & cur == c1$printed))
    if (sum(hit) != 1) .mig092_fail(sprintf("INPUT-corrections row %d matches %d cells, not 1.", i, sum(hit)))
    values[[c1$field]][hit] <- c1$corrected
  }
  values
}

.mig092_point_of <- function(inp, feature_raw) {
  f <- inp$points$feature[match(feature_raw, inp$points$feature_raw)]
  f[!is.na(f) & !nzchar(f)] <- NA_character_
  f
}

# ---- the operator adapter ---------------------------------------------------------

# Printed value -> list(kind, value_raw): "num" (to import; a bare zero becomes "0",
# A89), "withheld" (INPUT-corrections), or "not_reported" (blank or text).
.mig092_value <- function(v) {
  v <- if (is.na(v)) "" else trimws(v)
  if (identical(v, "_")) return(list(kind = "withheld", value_raw = v))
  if (!grepl("^[<>]?[0-9]+(\\.[0-9]+)?$", v)) return(list(kind = "not_reported", value_raw = v))
  if (grepl("^[0-9]", v) && as.numeric(v) == 0) v <- "0"
  list(kind = "num", value_raw = v)
}

.mig092_parse_one <- function(fh, inp, v, tag) {
  f <- inp$files[inp$files$hash == fh, , drop = FALSE]
  day <- as.Date(f$sample_day)
  day_raw <- format(day, "%d %b %Y")
  v$feature <- .mig092_point_of(inp, v$feature_raw)
  rows <- list(); smp <- list(); skipped <- list()
  skip <- function(i, why) skipped[[length(skipped) + 1]] <<- tibble::tibble(source_ref = v$source_ref[[i]], reason = why)
  for (i in seq_len(nrow(v))) {
    pv <- .mig092_value(v$value_raw[[i]])
    if (pv$kind != "num") { skip(i, pv$kind); next }
    if (is.na(v$feature[[i]])) { skip(i, "no_registered_point"); next }
    id <- sprintf("%s!%s!%s", f$report_no, v$feature[[i]], format(day, "%Y%m%d"))
    p <- parse_value(pv$value_raw)
    rows[[length(rows) + 1]] <- tibble::tibble(
      source_hash = fh, source_ref = v$source_ref[[i]], work_order = f$report_no, revision = 0L, org = "ACIRL",
      adapter = tag, lab_sample_id = id, sample_type = "Normal", feature_raw = v$feature_raw[[i]],
      analyte_raw = .mig092_analyte_raw, cas_number = NA_character_, method_raw = NA_character_,
      total_or_filtered = NA_character_, units_raw = .mig092_units_raw, value_raw = pv$value_raw,
      value_num = p$value_num, value_chr = NA_character_,
      below_detection = grepl("^<", pv$value_raw) || identical(pv$value_raw, "0"),
      rl = if (identical(pv$value_raw, "0")) .mig092_zero_rl else NA_real_,
      lab_qualifier = NA_character_, analysed_date = as.Date(NA_character_),
      comments = NA_character_, confidence = 1)
    smp[[length(smp) + 1]] <- tibble::tibble(
      source_hash = fh, source_ref = v$source_ref[[i]], work_order = f$report_no, org = "ACIRL", adapter = tag,
      lab_sample_id = id, feature_raw = v$feature_raw[[i]], sample_datetime_raw = day_raw,
      sample_date_start_raw = NA_character_, sample_type = "Normal", parent_sample = NA_character_,
      matrix_raw = "Gas", sampler = NA_character_, comments = NA_character_, confidence = 1)
  }
  results <- if (length(rows)) do.call(ir_results, as.list(dplyr::bind_rows(rows))) else ir_results()
  samples <- if (length(smp)) do.call(ir_samples, as.list(dplyr::bind_rows(smp))) else ir_samples()
  if (anyDuplicated(samples$lab_sample_id)) .mig092_fail(sprintf("%s: a point is printed twice.", f$staged_name))
  list(
    results = results, samples = samples,
    report = list(
      n_rows = nrow(results) + nrow(samples), n_by_sample_type = table(results$sample_type),
      skipped = if (length(skipped)) dplyr::bind_rows(skipped) else
        tibble::tibble(source_ref = character(0), reason = character(0)),
      header = list(report_no = f$report_no, sampled_by = NA_character_, sample_date = format(day, "%d/%m/%Y")),
      warnings = character(0), als_work_orders = character(0), n_water_sheets = 0L,
      campaign = "Landfill gas (ACIRL report)", site = "K",
      als_candidates = tibble::tibble(source_ref = character(0), feature_raw = character(0),
                                      analyte_raw = character(0), units_raw = character(0),
                                      value_raw = character(0), transcription_label = logical(0)),
      feature_aliases = tibble::tibble(source_ref = character(0), feature_raw = character(0),
                                       label = character(0), alias = character(0))))
}

mig092_adapter <- function(inp) {
  tag <- paste0(.mig092_adapter_id, "/", .mig092_adapter_version)
  by_hash <- split(inp$values, inp$values$hash)
  list(id = .mig092_adapter_id, version = .mig092_adapter_version,
       # A89, as acirl_gas_xlsx: the analyser's bare 0 is a non-detect
       zero_is_nondetect = TRUE,
       match = function(file_meta) if (isTRUE(file_meta$hash %in% inp$files$hash)) "exact" else "no",
       parse = function(path, file_meta) {
         if (!isTRUE(file_meta$hash %in% inp$files$hash)) .mig092_fail("parse() called on an unplanned file.")
         .mig092_parse_one(file_meta$hash, inp, by_hash[[file_meta$hash]], tag)
       })
}

# What the adapter emits for every file (no DB): the parse dry run.
mig092_parse_all <- function(inp) {
  ad <- mig092_adapter(inp)
  out <- lapply(inp$files$hash, function(h) ad$parse(NA_character_, list(hash = h)))
  names(out) <- inp$files$hash
  out
}

# The point-days the adapter creates samples for (feature, day), from the parse.
mig092_planned_point_days <- function(inp, parsed) {
  s <- dplyr::bind_rows(lapply(parsed, function(p) p$samples))
  unique(data.frame(feature = .mig092_point_of(inp, s$feature_raw), feature_raw = s$feature_raw,
                    day = as.Date(s$sample_datetime_raw, format = "%d %b %Y"), stringsAsFactors = FALSE))
}

# ---- preconditions shared by CHECK and run ---------------------------------------------

# Stored CH4 readings at the planned point-days (Robin: import only what is not
# already in the database; list any, never change the stored value).
mig092_overlap <- function(con, inp, parsed) {
  pd <- mig092_planned_point_days(inp, parsed)
  DBI::dbExecute(con, "CREATE OR REPLACE TEMP TABLE m092_pd (feature VARCHAR, day DATE)")
  DBI::dbAppendTable(con, "m092_pd", unique(pd[, c("feature", "day")]))
  DBI::dbGetQuery(con, sprintf("
    SELECT f.name AS feature, %s AS day, s.uuid AS sample, s.organisation, p.name AS project, lm.name AS lab_method,
           a.value, a.quantified
    FROM sample s JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias JOIN feature f ON f.uuid = fa.uuid_feature
    JOIN m092_pd pd ON pd.feature = f.name AND pd.day = %s
    JOIN analysis a ON a.uuid_sample = s.uuid JOIN lab_method lm ON lm.uuid = a.uuid_lab
    LEFT JOIN project p ON p.uuid = s.uuid_project
    WHERE lm.name = '%s' ORDER BY 1, 2", .mig092_syd("coalesce(s.date, s.datetime)"),
    .mig092_syd("coalesce(s.date, s.datetime)"), .mig092_analyte_raw))
}

mig092_discrepancies <- function(overlap, inp, parsed) {
  empty <- data.frame(feature = character(0), day = character(0), report_no = character(0),
                      report_value = character(0), stored_value = character(0), status = character(0))
  if (!nrow(overlap)) return(empty)
  r <- dplyr::bind_rows(lapply(parsed, function(p) p$results))
  r$feature <- .mig092_point_of(inp, r$feature_raw)
  r$day <- format(as.Date(sub("^.*!", "", r$lab_sample_id), format = "%Y%m%d"))
  ov <- overlap; ov$day <- format(as.Date(ov$day))
  r <- merge(r, unique(ov[, c("feature", "day")]))
  if (!nrow(r)) return(empty)
  do.call(rbind, lapply(seq_len(nrow(r)), function(i) {
    st <- ov[ov$feature == r$feature[[i]] & ov$day == r$day[[i]], ]
    same <- any(!is.na(st$value) & !is.na(r$value_num[[i]]) & abs(st$value - r$value_num[[i]]) < 1e-9)
    data.frame(feature = r$feature[[i]], day = r$day[[i]], report_no = r$work_order[[i]],
               report_value = r$value_raw[[i]], stored_value = paste(format(st$value), collapse = "; "),
               status = if (same) "equal" else "differs")
  }))
}

mig092_file_states <- function(con, inp) {
  st <- DBI::dbGetQuery(con, sprintf("SELECT hash, state, state_reason, adapter FROM ingest_file WHERE hash IN %s",
                                     .mig092_inlist(inp$files$hash)))
  st[match(inp$files$hash, st$hash), , drop = FALSE]
}

# ---- phase A: aliases + feature date_start ---------------------------------------

.mig092_uuid <- function(...) {
  d <- digest::digest(paste(c(.mig092_marker_version, ...), collapse = "\u001f"), algo = "md5", serialize = FALSE)
  paste(substr(d, 1, 8), substr(d, 9, 12), paste0("4", substr(d, 14, 16)),
        paste0("8", substr(d, 18, 20)), substr(d, 21, 32), sep = "-")
}

mig092_plan_registry <- function(con, inp, parsed) {
  v <- mig092_planned_point_days(inp, parsed)
  feats <- unique(v$feature)
  feat <- DBI::dbGetQuery(con, sprintf("SELECT uuid, name, date_start, date_end, comments FROM feature WHERE name IN %s",
                                       .mig092_inlist(feats)))
  if (nrow(feat) != length(feats) || anyDuplicated(feat$name)) .mig092_fail("a mapped feature does not exist exactly once.")
  a <- inp$alias
  a$uuid_feature <- feat$uuid[match(a$feature, feat$name)]
  if (anyNA(a$uuid_feature)) .mig092_fail("INPUT-alias names a feature with no imported reading.")
  a$alias_key <- .rc_feature_key(a$name)
  a$uuid <- mapply(.mig092_uuid, a$alias_key, a$feature, a$date_start, a$date_end, USE.NAMES = FALSE)
  a$comments <- sprintf("092: printed spelling in the ACIRL whole-site report gas pages %s..%s (%s = %s)",
                        a$date_start, a$date_end, a$name, a$feature)
  first <- tapply(v$day, v$feature, min)
  fd <- data.frame(feature = names(first), stringsAsFactors = FALSE)
  fd$uuid <- feat$uuid[match(fd$feature, feat$name)]
  fd$first <- as.Date(unname(first), origin = "1970-01-01")
  fd$old_start <- as.Date(feat$date_start[match(fd$feature, feat$name)])
  fd$old_comments <- feat$comments[match(fd$feature, feat$name)]
  fd <- fd[!is.na(fd$old_start) & fd$old_start > fd$first, , drop = FALSE]
  fd$new_comments <- paste0(ifelse(is.na(fd$old_comments), "", paste0(fd$old_comments, "; ")), sprintf(
    "092: date_start moved back from %s to %s for the ACIRL report gas history.", fd$old_start, fd$first))
  list(alias = a, feature = fd, values = v[, c("feature_raw", "feature", "day")],
       date_end = feat[, c("name", "date_end")])
}

.mig092_alias_rows <- function(a) {
  tibble::tibble(
    uuid = a$uuid, uuid_feature = a$uuid_feature, name = a$name, alias_key = a$alias_key, kind = "descriptive",
    n_seen = 0L, auto_assign = TRUE,
    first_seen = as.POSIXct(rep(NA_real_, nrow(a)), origin = "1970-01-01", tz = "UTC"),
    last_seen = as.POSIXct(rep(NA_real_, nrow(a)), origin = "1970-01-01", tz = "UTC"),
    confirmed_by = .mig092_confirmed_by, comments = a$comments,
    date_start = as.Date(a$date_start), date_end = as.Date(a$date_end))
}

# Every (printed name, day) must resolve, through the arms in force on that day
# (the existing ones plus the planned ones), to its mapped feature and to no other.
mig092_resolution <- function(con, plan) {
  pv <- unique(plan$values)
  pv$key <- .rc_feature_key(pv$feature_raw)
  arms <- DBI::dbGetQuery(con, sprintf("SELECT fa.uuid, fa.alias_key, f.name AS feature, fa.date_start, fa.date_end
    FROM feature_alias fa JOIN feature f ON f.uuid = fa.uuid_feature WHERE fa.alias_key IN %s", .mig092_inlist(pv$key)))
  new <- plan$alias[!plan$alias$uuid %in% arms$uuid, , drop = FALSE]
  if (nrow(new)) arms <- rbind(arms, data.frame(uuid = new$uuid, alias_key = new$alias_key, feature = new$feature,
                                                date_start = as.Date(new$date_start), date_end = as.Date(new$date_end)))
  pv$resolves_to <- vapply(seq_len(nrow(pv)), function(i) {
    hit <- arms[arms$alias_key == pv$key[[i]] & (is.na(arms$date_start) | arms$date_start <= pv$day[[i]]) &
                  (is.na(arms$date_end) | arms$date_end >= pv$day[[i]]), , drop = FALSE]
    paste(sort(unique(hit$feature)), collapse = "|")
  }, "")
  pv
}

mig092_registry_problems <- function(con, plan) {
  pr <- character(0)
  a <- plan$alias
  for (i in seq_len(nrow(a))) {
    hit <- DBI::dbGetQuery(con, "SELECT fa.uuid, f.name AS feature FROM feature_alias fa JOIN feature f ON f.uuid = fa.uuid_feature
      WHERE alias_key = ? AND (fa.date_start IS NULL OR fa.date_start <= ?) AND (fa.date_end IS NULL OR fa.date_end >= ?)",
      params = list(a$alias_key[[i]], as.Date(a$date_end[[i]]), as.Date(a$date_start[[i]])))
    hit <- hit[hit$uuid != a$uuid[[i]] & hit$feature != a$feature[[i]], , drop = FALSE]
    if (nrow(hit)) pr <- c(pr, sprintf("alias '%s' %s..%s overlaps arm(s) to %s", a$name[[i]], a$date_start[[i]],
                                       a$date_end[[i]], paste(unique(hit$feature), collapse = ",")))
  }
  res <- mig092_resolution(con, plan)
  bad <- res[res$resolves_to != res$feature, , drop = FALSE]
  if (nrow(bad)) pr <- c(pr, sprintf("'%s' on %s resolves to '%s', not %s", bad$feature_raw, bad$day, bad$resolves_to,
                                     bad$feature))
  last <- tapply(plan$values$day, plan$values$feature, max)
  de <- plan$date_end[!is.na(plan$date_end$date_end), , drop = FALSE]
  late <- de$name[as.Date(de$date_end) < as.Date(unname(last[de$name]), origin = "1970-01-01")]
  late <- late[!is.na(late)]
  if (length(late)) pr <- c(pr, sprintf("feature(s) retired before an imported day: %s", paste(late, collapse = ", ")))
  unique(pr)
}

mig092_apply_registry <- function(con, plan, logf) {
  db_transaction(con, function(con) {
    todo <- plan$alias[!plan$alias$uuid %in% DBI::dbGetQuery(con, sprintf(
      "SELECT uuid FROM feature_alias WHERE uuid IN %s", .mig092_inlist(plan$alias$uuid)))$uuid, , drop = FALSE]
    if (nrow(todo)) db_append(con, "feature_alias", .mig092_alias_rows(todo), actor = .mig092_actor,
                              reason = "092: Katoomba report gas history - printed spelling")
    fd <- plan$feature
    for (i in seq_len(nrow(fd))) {
      cur <- as.Date(DBI::dbGetQuery(con, "SELECT date_start FROM feature WHERE uuid = ?", params = list(fd$uuid[[i]]))[[1]])
      if (is.na(cur) || cur <= fd$first[[i]]) next
      db_update(con, "feature", uuid = fd$uuid[[i]],
                changes = list(date_start = fd$first[[i]], comments = fd$new_comments[[i]]),
                actor = .mig092_actor, reason = "092: Katoomba gas history - date_start covers the imported samples")
    }
    logf("Phase A: %d alias arm(s) inserted (%d already present); %d feature date_start(s) moved.", nrow(todo),
         nrow(plan$alias) - nrow(todo), nrow(fd))
    NULL
  })
}

# ---- phase B0: reset the held PDFs ----------------------------------------------------

mig092_apply_reset <- function(con, inp, recorded_at, logf) {
  db_transaction(con, function(con) {
    st <- mig092_file_states(con, inp)
    todo <- st[!is.na(st$hash) & st$state == "archived" & !is.na(st$adapter) & st$adapter %in% .mig092_prior_adapters, ,
               drop = FALSE]
    for (i in seq_len(nrow(todo))) {
      ingest_file_set_state(con, todo$hash[[i]], "seen", reason = NA_character_, reset = TRUE)
      old <- list(state = todo$state[[i]], state_reason = todo$state_reason[[i]])
      for (f in c("state", "state_reason")) {
        .st_write_change_log(con, at = recorded_at, actor = .mig092_actor, action = "update", tbl = "ingest_file",
                             uuid_row = NA_character_, field = f, old = old[[f]],
                             new = if (f == "state") "seen" else NA_character_,
                             reason = "092: re-route the ACIRL report so its gas pages are imported (reset = TRUE)",
                             source_hash = todo$hash[[i]])
      }
    }
    logf("Phase B0: %d ingest_file row(s) reset archived -> seen.", nrow(todo))
    NULL
  })
}

# ---- phase B: the import --------------------------------------------------------

mig092_stage <- function(inp, files_root, inbox) {
  if (dir.exists(inbox) && length(list.files(inbox, all.files = TRUE, no.. = TRUE)))
    .mig092_fail(sprintf("staging inbox %s is not empty.", inbox))
  dir.create(inbox, recursive = TRUE, showWarnings = FALSE)
  for (i in seq_len(nrow(inp$files))) {
    src <- file.path(files_root, inp$files$source_dir[[i]], inp$files$staged_name[[i]])
    if (!file.exists(src)) .mig092_fail(sprintf("source file %s not found.", src))
    if (!identical(hash_file(src), inp$files$hash[[i]])) .mig092_fail(sprintf("%s: hash differs from INPUT.", src))
    dest <- file.path(inbox, inp$files$staged_name[[i]])
    if (!file.copy(src, dest, copy.date = TRUE)) .mig092_fail(sprintf("could not stage %s.", src))
    if (!identical(hash_file(dest), inp$files$hash[[i]])) .mig092_fail(sprintf("%s: staged copy differs.", dest))
  }
  invisible(inbox)
}

mig092_import <- function(db, inp, inbox, archive_dir, snapshot_dir, logf, dry_run = FALSE) {
  withr::local_options(sampletidy.archive_dir = archive_dir, sampletidy.snapshot_dir = snapshot_dir,
                       sampletidy.remove_ingested = FALSE, sampletidy.input_dir = inbox)
  if (!identical(st_config("archive_dir"), archive_dir) || isTRUE(as.logical(st_config("remove_ingested"))))
    .mig092_fail("the import configuration did not take.")
  register_adapter(mig092_adapter(inp))
  on.exit({ clear_adapters(); register_builtin_adapters() }, add = TRUE)
  rep <- ingest_dir(inbox, db = db, dry_run = dry_run)
  logf("Phase B: ingest_dir(dry_run = %s): events %s, committed %s, failed %s, rows new %s, already %s, skipped %s, review %s",
       dry_run, rep$n_events, rep$n_events_committed, rep$events_failed, rep$rows_new, rep$rows_already_present,
       rep$rows_skipped, rep$review_items_opened)
  rep
}

# ---- phase C: filings verified + marker ------------------------------------------------

mig092_filing_state <- function(con, inp) {
  a <- DBI::dbGetQuery(con, sprintf("SELECT a.uuid, a.hash FROM asset a WHERE a.hash IN %s", .mig092_inlist(inp$files$hash)))
  f <- DBI::dbGetQuery(con, sprintf("SELECT uuid_asset, count(*) AS n FROM asset_filing WHERE system = '%s' AND uuid_asset IN %s
                                     GROUP BY 1", .mig092_trim_system, .mig092_inlist(a$uuid)))
  a$n_filed <- f$n[match(a$uuid, f$uuid_asset)]
  a$n_filed[is.na(a$n_filed)] <- 0L
  a[match(inp$files$hash, a$hash), , drop = FALSE]
}

mig092_apply_marker <- function(con, inp, recorded_at, logf) {
  db_transaction(con, function(con) {
    fs <- mig092_filing_state(con, inp)
    if (anyNA(fs$uuid) || anyDuplicated(fs$hash) || any(fs$n_filed != 1))
      .mig092_fail("every PDF must be exactly one asset with exactly one trim filing (made by 089/090).")
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig092_marker_version, recorded_at))
    logf("Phase C: %d asset(s) already filed in TRIM (none filed again); marker %d.", nrow(fs), .mig092_marker_version)
    NULL
  })
}

# ---- verification -------------------------------------------------------------------

.mig092_counts <- function(con) {
  tabs <- c("feature", "feature_alias", "analyte", "lab_method", "analysis", "sample", "project", "asset",
            "review_queue", "ingest_file", "change_log", "schema_version")
  if ("asset_filing" %in% DBI::dbListTables(con)) tabs <- c(tabs, "asset_filing")
  stats::setNames(vapply(tabs, function(t) .mig092_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t)), 0L), tabs)
}

.mig092_existing_digest <- function(con) {
  s <- DBI::dbGetQuery(con, "SELECT * FROM sample ORDER BY uuid")
  a <- DBI::dbGetQuery(con, "SELECT * FROM analysis ORDER BY uuid")
  c(sample = digest::digest(s, algo = "sha1"), analysis = digest::digest(a, algo = "sha1"))
}

mig092_new_rows <- function(con, before_samples) {
  DBI::dbExecute(con, "CREATE OR REPLACE TEMP TABLE m092_old (uuid VARCHAR)")
  DBI::dbAppendTable(con, "m092_old", data.frame(uuid = before_samples, stringsAsFactors = FALSE))
  DBI::dbGetQuery(con, sprintf("
    SELECT f.name AS feature, fa.name AS alias, %s AS day, s.datetime, s.organisation, p.name AS project,
           lm.name AS lab_method, lm.method, an.name AS analyte, a.value, a.quantified, a.rl_low, a.rl_high
    FROM sample s JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias LEFT JOIN feature f ON f.uuid = fa.uuid_feature
    LEFT JOIN project p ON p.uuid = s.uuid_project
    LEFT JOIN analysis a ON a.uuid_sample = s.uuid LEFT JOIN lab_method lm ON lm.uuid = a.uuid_lab
    LEFT JOIN analyte an ON an.uuid = lm.uuid_analyte
    WHERE s.uuid NOT IN (SELECT uuid FROM m092_old)
    ORDER BY feature, day, lab_method, a.value", .mig092_syd("coalesce(s.date, s.datetime)")))
}

mig092_verify_import <- function(con, inp, parsed, before) {
  pr <- character(0)
  st <- mig092_file_states(con, inp)
  if (anyNA(st$hash) || !all(st$state == "archived") || !all(st$adapter == .mig092_adapter_id))
    pr <- c(pr, sprintf("not every PDF is archived by %s: %s", .mig092_adapter_id,
                        paste(unique(paste(st$state, st$state_reason, st$adapter)), collapse = "; ")))
  na <- .mig092_scalar(con, sprintf("SELECT COUNT(*) FROM asset WHERE hash IN %s", .mig092_inlist(inp$files$hash)))
  if (na != nrow(inp$files)) pr <- c(pr, sprintf("%d asset rows for %d PDFs", na, nrow(inp$files)))
  nr <- mig092_new_rows(con, before$samples)
  pd <- mig092_planned_point_days(inp, parsed)
  got <- unique(data.frame(feature = nr$feature, day = as.Date(nr$day)))
  if (nrow(merge(got, pd[, c("feature", "day")])) != nrow(got) || anyNA(got$feature))
    pr <- c(pr, "a new sample is at a feature or on a day the adapter did not plan")
  n_emitted <- sum(vapply(parsed, function(p) nrow(p$results), 0L))
  n_new <- sum(!is.na(nr$lab_method))
  if (n_new != n_emitted) pr <- c(pr, sprintf("%d new analyses, %d rows emitted", n_new, n_emitted))
  if (any(nr$lab_method != .mig092_analyte_raw, na.rm = TRUE)) pr <- c(pr, "a new analysis is not a CH4 reading")
  n_smp <- sum(vapply(parsed, function(p) nrow(p$samples), 0L))
  n_new_smp <- nrow(unique(nr[, c("feature", "day", "datetime", "project")]))
  if (n_new_smp != n_smp) pr <- c(pr, sprintf("%d new samples, %d emitted", n_new_smp, n_smp))
  old <- DBI::dbGetQuery(con, "SELECT * FROM sample WHERE uuid IN (SELECT uuid FROM m092_old) ORDER BY uuid")
  if (!identical(digest::digest(old, algo = "sha1"), before$digest[["sample"]])) pr <- c(pr, "an existing sample changed")
  olda <- DBI::dbGetQuery(con, "SELECT * FROM analysis WHERE uuid IN (SELECT uuid FROM m092_olda) ORDER BY uuid")
  if (!identical(digest::digest(olda, algo = "sha1"), before$digest[["analysis"]])) pr <- c(pr, "an existing analysis changed")
  list(problems = pr, new_rows = nr)
}

# ---- backup ------------------------------------------------------------------------

mig092_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- if (is.null(.now)) Sys.time() else .now
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig092_name,
                                          format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")))
  n0 <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    n <- .mig092_counts(con)
    if (!isTRUE(file.copy(db, dest, overwrite = FALSE))) .mig092_fail(sprintf("could not write backup %s", dest))
    n
  }, db = db)
  v <- DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE)
  on.exit(DBI::dbDisconnect(v, shutdown = TRUE), add = TRUE)
  if (!identical(n0, .mig092_counts(v))) .mig092_fail("backup verification failed: counts differ.")
  dest
}

.mig092_write_csv <- function(df, path) {
  utils::write.csv(df, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, colClasses = "character", na.strings = "", encoding = "UTF-8")
  if (nrow(back) != nrow(df)) .mig092_fail(sprintf("CSV %s did not round-trip.", basename(path)))
}

# ---- run -------------------------------------------------------------------------------

mig092_run <- function(db, snapshot_dir, archive_dir, work_dir, files_root = "dev/migrations", dry_run = FALSE,
                       csv_dir = "dev/migrations", input_dir = "dev/migrations", requires = .mig092_requires,
                       .now = NULL) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", basename(db), sprintf(fmt, ...)))
  checkmate::assert_directory_exists(archive_dir)
  checkmate::assert_directory_exists(snapshot_dir)
  checkmate::assert_directory_exists(csv_dir)
  inp <- mig092_read_inputs(input_dir)
  parsed <- mig092_parse_all(inp)
  logf("Inputs: %d PDF(s), %d transcribed cell(s), %d alias arm(s); adapter emits %d result row(s), %d sample(s).",
       nrow(inp$files), nrow(inp$values), nrow(inp$alias), sum(vapply(parsed, function(p) nrow(p$results), 0L)),
       sum(vapply(parsed, function(p) nrow(p$samples), 0L)))

  con <- st_connect(db, read_only = TRUE)
  st <- tryCatch({
    have <- DBI::dbGetQuery(con, "SELECT version FROM schema_version")$version
    if (!all(requires %in% have)) .mig092_fail(sprintf("marker %s required first.", paste(requires, collapse = ", ")))
    list(done = .mig092_marker_version %in% have, plan = mig092_plan_registry(con, inp, parsed))
  }, finally = DBI::dbDisconnect(con, shutdown = TRUE))

  if (st$done) {
    con <- st_connect(db, read_only = TRUE)
    on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
    fs <- mig092_file_states(con, inp)
    if (anyNA(fs$hash) || !all(fs$state == "archived")) .mig092_fail("re-verify: a PDF is not archived.")
    fl <- mig092_filing_state(con, inp)
    if (anyNA(fl$uuid) || any(fl$n_filed != 1)) .mig092_fail("re-verify: assets or filings are not as planned.")
    logf("092 already applied; re-verified; nothing to do.")
    return(invisible(list(status = "already_migrated")))
  }

  con <- st_connect(db, read_only = TRUE)
  pre <- tryCatch({
    pr <- mig092_registry_problems(con, st$plan)
    ov <- mig092_overlap(con, inp, parsed)
    fs <- mig092_file_states(con, inp)
    fl <- mig092_filing_state(con, inp)
    list(problems = pr, overlap = ov, states = fs, filings = fl,
         before_samples = DBI::dbGetQuery(con, "SELECT uuid FROM sample")$uuid,
         before_analyses = DBI::dbGetQuery(con, "SELECT uuid FROM analysis")$uuid,
         digest = .mig092_existing_digest(con))
  }, finally = DBI::dbDisconnect(con, shutdown = TRUE))
  disc <- mig092_discrepancies(pre$overlap, inp, parsed)
  .mig092_write_csv(disc, .mig092_csv_path(csv_dir, "DISCREPANCIES"))
  if (length(pre$problems)) .mig092_fail(paste(pre$problems, collapse = "; "))
  if (nrow(pre$overlap)) .mig092_fail(sprintf("%d stored CH4 reading(s) at planned point-days (see DISCREPANCIES CSV); resolve first.",
                                              nrow(pre$overlap)))
  if (anyNA(pre$states$hash)) .mig092_fail("a PDF is not in ingest_file: 089 and 090 must be applied first.")
  odd <- pre$states[!(pre$states$state %in% c("archived", "seen")) |
                      (pre$states$state == "archived" & !pre$states$adapter %in% c(.mig092_prior_adapters, .mig092_adapter_id)), ,
                    drop = FALSE]
  if (nrow(odd)) .mig092_fail(sprintf("unexpected ingest_file state(s): %s", paste(unique(paste(odd$state, odd$adapter)), collapse = ", ")))
  if (anyNA(pre$filings$uuid) || any(pre$filings$n_filed != 1))
    .mig092_fail("every PDF must already be one asset with one trim filing (089/090).")
  logf("Plan: %d alias arm(s); %d date_start move(s); %d ingest_file reset(s); %d point-day(s).",
       nrow(st$plan$alias), nrow(st$plan$feature),
       sum(pre$states$state == "archived" & pre$states$adapter %in% .mig092_prior_adapters),
       nrow(unique(st$plan$values[, c("feature", "day")])))
  if (isTRUE(dry_run)) {
    logf("DRY RUN: inputs, parse, overlap and registry preconditions checked. Nothing written.")
    return(invisible(list(status = "dry_run", parsed = parsed, plan = st$plan)))
  }

  con <- st_connect(db, read_only = TRUE)
  tryCatch({
    .mig092_write_csv(DBI::dbGetQuery(con, sprintf("SELECT * FROM ingest_file WHERE hash IN %s ORDER BY hash",
                                                   .mig092_inlist(inp$files$hash))),
                      .mig092_csv_path(csv_dir, "BACKUP-ingest_file"))
    .mig092_write_csv(DBI::dbGetQuery(con, sprintf("SELECT * FROM feature WHERE name IN %s ORDER BY name",
                                                   .mig092_inlist(st$plan$feature$feature))),
                      .mig092_csv_path(csv_dir, "BACKUP-feature"))
  }, finally = DBI::dbDisconnect(con, shutdown = TRUE))
  backup_path <- mig092_backup(db, snapshot_dir, .now)
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: cp %s %s", shQuote(backup_path), shQuote(db))
  recorded_at <- if (is.null(.now)) Sys.time() else .now

  with_db_write(function(con) mig092_apply_registry(con, st$plan, logf), db = db)
  .mig092_write_csv(as.data.frame(.mig092_alias_rows(st$plan$alias)), .mig092_csv_path(csv_dir, "INSERTED-feature_alias"))
  with_db_write(function(con) mig092_apply_reset(con, inp, recorded_at, logf), db = db)

  inbox <- file.path(work_dir, "inbox")
  unlink(inbox, recursive = TRUE)
  mig092_stage(inp, files_root, inbox)
  rep <- mig092_import(db, inp, inbox, archive_dir, snapshot_dir, logf)

  con <- st_connect(db, read_only = TRUE)
  ver <- tryCatch({
    DBI::dbExecute(con, "CREATE OR REPLACE TEMP TABLE m092_olda (uuid VARCHAR)")
    DBI::dbAppendTable(con, "m092_olda", data.frame(uuid = pre$before_analyses, stringsAsFactors = FALSE))
    mig092_verify_import(con, inp, parsed, list(samples = pre$before_samples, digest = pre$digest))
  }, finally = DBI::dbDisconnect(con, shutdown = TRUE))
  .mig092_write_csv(ver$new_rows, file.path(work_dir, sprintf("%s-NEW-rows.csv", .mig092_name)))
  if (length(ver$problems)) .mig092_fail(paste0("import verify: ", paste(ver$problems, collapse = "; "),
                                                ". Restore from ", backup_path))

  with_db_write(function(con) mig092_apply_marker(con, inp, recorded_at, logf), db = db)
  logf("%s migrated successfully (marker %d).", .mig092_name, .mig092_marker_version)
  invisible(list(status = "migrated", backup_path = backup_path, report = rep, new_rows = ver$new_rows))
}
